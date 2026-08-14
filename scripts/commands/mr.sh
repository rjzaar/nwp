#!/bin/bash
set -uo pipefail
################################################################################
# pl mr — hold, release and guard merge requests. A hold the FORGE enforces.
#
# ── WHY THIS COMMAND EXISTS ───────────────────────────────────────────────────
#
# On 2026-08-01 an MR the operator had explicitly decided to HOLD was merged
# anyway. A background merge sweeper armed `merge_when_pipeline_succeeds=true`
# on every open MR, re-armed the held one AFTER the hold was recorded, and the
# MR self-merged the instant CI went green — bypassing the two-person review
# that `.gitlab-ci.yml` requires for its own path.
#
# The hold was real. It was written down. It was in a document. And a document
# is not a hold:
#
#       a hold expressed only in a document is not a hold —
#       it must be expressed in the automation.        (operator, D13)
#
# ── THE MECHANISM, AND WHY THE OTHERS WERE REJECTED ───────────────────────────
#
# CHOSEN: **Draft status** (`Draft:` title prefix / `draft: true`).
#   GitLab refuses `PUT /merge_requests/:iid/merge` with **405 Method Not
#   Allowed** while an MR is a draft, and reports `detailed_merge_status:
#   draft_status`. Crucially it refuses even when auto-merge is ARMED: arming
#   `merge_when_pipeline_succeeds` is not what merges an MR — leaving draft is.
#   So the exact failure mode of 2026-08-01 (a bot re-arming auto-merge, over
#   and over, and winning on green) cannot defeat it. Re-arm all you like; the
#   armed merge simply never fires. It is also the one mechanism below that
#   needs no paid GitLab tier and no project-settings change an agent could
#   quietly undo.
#
# REJECTED, and why — each of these was considered and is weaker:
#
#   * A `hold::` LABEL alone. GitLab consults no label at merge time. A label
#     is a document with a colour, and a document is what already failed. (We
#     still SET a label — for `pl mr list` and for humans — but it is
#     documentation sitting on top of the lock, never the lock.)
#
#   * MERGE-REQUEST APPROVAL RULES (`approvals_before_merge`, "N approvals
#     required"). The right tool in principle. But *required* approval rules
#     are a Premium/Ultimate feature; on a self-hosted Free instance the field
#     is accepted by the API and not enforced at merge time. A gate that the
#     tier silently ignores is worse than no gate, because it reads as covered.
#     `pl mr status` reports the instance's own `detailed_merge_status`, so if
#     this instance is ever licensed for it, the upgrade is visible there.
#
#   * CODEOWNERS required approval. Same problem: on Free, CODEOWNERS only
#     *suggests* reviewers. Nothing blocks.
#
#   * PROTECTED BRANCH / push rules on `main`. Stops direct pushes; does not
#     stop a Maintainer (or a bot holding a Maintainer token) merging an MR.
#     Orthogonal to this failure, and worth having for other reasons.
#
#   * "ALL THREADS MUST BE RESOLVED" project setting. Project-wide, not
#     per-MR, and a bot with the token can resolve threads. It converts a hold
#     into a chore.
#
#   * PERMANENTLY FAILING THE PIPELINE and nothing else. This does block
#     auto-merge (MWPS never fires on red) and it is kept as the SECOND layer
#     below, because it works with zero credentials. But as the only layer it
#     is bad: a red pipeline is indistinguishable from a broken build, it
#     trains people to retry until green, and one `allow_failure: true` ends
#     it. It is a backstop, not the lock.
#
# ── THE TWO LAYERS, STATED PLAINLY ────────────────────────────────────────────
#
#   Layer 1  Draft            forge-enforced, survives auto-merge re-arming,
#                             needs a token to apply
#   Layer 2  red pipeline     `pl mr guard` exits non-zero on an unreleased
#                             sensitive-path MR, so MWPS can never fire, and
#                             this works even with NO token in CI
#
# Both fail closed. If the guard cannot tell what an MR changed, it holds.
#
# ── USAGE ─────────────────────────────────────────────────────────────────────
#   pl mr status  <iid>                     hold state, merge state, sensitive paths
#   pl mr list                              every open MR: held? auto-merge armed?
#   pl mr hold    <iid> --reason="..."      HOLD it (draft + disarm + label + note)
#   pl mr release <iid> --approved-by=<h> [--reason="..."]
#                                           lift the hold, on the record
#   pl mr guard  [<iid>] [--apply]          the sensitive-path gate (CI + local)
#   pl mr rebase  <iid> [--wait=S] [--dry-run]
#                                           onto the tip of the target branch —
#                                           unsticks a red pipeline that is a
#                                           COMPLETED run on a stale head
#   pl mr note    <iid> "text" | - | stdin  comment on the MR (ops#356)
#
# Values-safe: the token is read from .secrets.yml by lib/gitlab-mr.sh and used
# only inside a 0600 curl config — never printed, never in argv/ps/history.
################################################################################
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh" 2>/dev/null || true

YQ="$(command -v yq || true)"
die(){ print_error "$*"; exit 1; }

source "$PROJECT_ROOT/lib/gitlab-mr.sh"

_need_yq(){ [ -n "$YQ" ] || die "yq required"; }

# The MR's web URL, for the project this repo actually IS.
#
# WAS hardcoded to /nwp/nwp/, so every link printed for any other project was a
# 404. `pl mr create` in the nwc profile repo announced
# ".../nwp/nwp/-/merge_requests/70" for an MR that lives in nwp/nwc, and the
# operator followed it to a Project Not Found — twice, because `pl mr status`
# repeats the same field. A verb that hands you a wrong link costs more time than
# one that hands you none.
#
# _mr_project() returns the path URL-ENCODED for the API (nwp%2Fnwc); a web URL
# needs it decoded back to a real slash. NWP_MR_PROJECT / CI_PROJECT_ID may make
# it a numeric id, which has no web path — GitLab redirects /projects/<id> so
# fall back to that rather than inventing a slug.
_mr_web_url(){
    local proj host
    host="$(_mr_host)"
    proj="$(_mr_project 2>/dev/null || true)"
    if [ -z "$proj" ]; then
        printf 'https://%s/-/merge_requests/%s (project unresolved)\n' "$host" "$1"
        return 0
    fi
    proj="${proj//%2F//}"
    case "$proj" in
        ''|*[!0-9]*) printf 'https://%s/%s/-/merge_requests/%s\n' "$host" "$proj" "$1" ;;
        *)           printf 'https://%s/projects/%s/-/merge_requests/%s\n' "$host" "$proj" "$1" ;;
    esac
}

################################################################################
# pl mr create — the other half of ops#216.
#
# WHY THIS IS A VERB AND NOT A CURL. Until now every session opened its own MR
# with a hand-rolled API call, which meant every session also re-decided, from
# memory, whether the thing it had just written was a sensitive-path change.
# `pl mr guard` exists precisely because remembering is what fails. Creating
# through the verb means the guard runs on the MR the moment it exists, in the
# same breath, rather than whenever CI gets round to it — and the token handling,
# host resolution and 0600-curl-config contract come from one place.
#
# Defaults are read off the work, not asked for: the source branch is the branch
# you are on, and the title/description default to the HEAD commit's subject and
# body — which is where the estate already requires the reasoning to live.
################################################################################
cmd_create(){
  _need_yq
  local src="" target="main" title="" desc="" desc_file="" draft=false remove_src=true
  local closes="" dry=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --source=*)  src="${1#*=}"; shift ;;
      --closes=*)  closes="${1#*=}"; shift ;;
      --dry-run)   dry=true; shift ;;
      --target=*)  target="${1#*=}"; shift ;;
      --title=*)   title="${1#*=}"; shift ;;
      --desc=*)    desc="${1#*=}"; shift ;;
      --desc-file=*) desc_file="${1#*=}"; shift ;;
      --draft)     draft=true; shift ;;
      --keep-branch) remove_src=false; shift ;;
      -h|--help)
        printf 'usage: pl mr create [--source=BRANCH] [--target=main] [--title=..] [--desc=..|--desc-file=F|-]\n'
        printf '                    [--closes=N] [--draft] [--keep-branch] [--dry-run]\n'
        return 0 ;;
      -)  desc="$(cat)"; shift ;;
      -*) die "unknown option: $1 (try: pl mr create --help)" ;;
      *)  die "unexpected arg: $1" ;;
    esac
  done
  # ARGUMENT VALIDATION HAPPENS BEFORE THE MACHINE IS INSPECTED.
  # `verify_restic` taught this the expensive way on 2026-08-02: it checked
  # `command -v restic` before it checked its own flag, so an illegal argument
  # was silently accepted on any host without restic. Whether these arguments
  # are legal is a property of the COMMAND; whether a token exists is a property
  # of the machine. Mixing the order lets one answer the other.
  [ -n "$src" ] || src="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [ -n "$src" ] && [ "$src" != "HEAD" ] || die "cannot resolve a source branch (detached HEAD?) — pass --source=BRANCH"
  [ "$src" != "$target" ] || die "source and target are both '$target' — an MR from a branch to itself is not a review"
  if [ -n "$closes" ]; then
    closes="${closes#\#}"; closes="${closes#nwp/ops#}"
    [[ "$closes" =~ ^[0-9]+$ ]] || die "--closes wants an issue number, got: $closes"
  fi

  # A branch that exists only locally produces an MR nobody else can fetch, and
  # GitLab reports that as a confusing 400. Refuse with the real reason.
  git rev-parse --verify --quiet "refs/remotes/origin/${src}" >/dev/null 2>&1 \
    || die "origin/${src} does not exist — push the branch first: git push -u origin ${src}"
  local local_sha remote_sha
  local_sha=$(git rev-parse --verify --quiet "refs/heads/${src}" 2>/dev/null || true)
  remote_sha=$(git rev-parse --verify --quiet "refs/remotes/origin/${src}" 2>/dev/null || true)
  if [ -n "$local_sha" ] && [ "$local_sha" != "$remote_sha" ]; then
    print_warning "origin/${src} is at ${remote_sha:0:12} but your local ${src} is at ${local_sha:0:12}"
    print_warning "the MR will review what is PUSHED, not what is in your worktree."
  fi

  if [ -n "$desc_file" ]; then
    [ -f "$desc_file" ] || die "no such --desc-file: $desc_file"
    desc="$(cat "$desc_file")"
  fi
  [ -n "$title" ] || title="$(git log -1 --format=%s "$src" 2>/dev/null || true)"
  [ -n "$title" ] || die "no --title given and the HEAD commit has no subject"
  [ -n "$desc" ]  || desc="$(git log -1 --format=%b "$src" 2>/dev/null || true)"
  [ "$draft" = "true" ] && case "$title" in Draft:*|WIP:*) ;; *) title="Draft: $title" ;; esac

  # THE TRACKER ONLY LEARNS FROM THE MR IF THE MR SAYS SO. Appended, never
  # invented, and idempotent: a description that already carries the reference
  # is left exactly as written. (Half the ops issues closed by hand this week
  # were closed by hand precisely because no MR ever named them.)
  if [ -n "$closes" ]; then
    grep -qiE "closes[[:space:]]+nwp/ops#$closes([^0-9]|\$)" <<<"$desc" \
      || desc="$desc"$'\n\n'"Closes nwp/ops#$closes"
  fi

  _mr_have_token || die "no usable token (NWP_MR_TOKEN or .secrets.yml:gitlab.api_token)"

  local proj payload json iid
  proj=$(_mr_project) || die "cannot resolve the project (no origin remote?)"

  # ONE MR PER BRANCH. A duplicate splits the review thread and the CI history,
  # and the second one is almost always a session that did not look. This is not
  # hypothetical: on 2026-08-02 two agents working the same ops queue opened
  # !339 and !341 for ops#216 fourteen minutes apart, and the second one — this
  # code's own author — only found out afterwards. Checking the SOURCE BRANCH
  # cannot catch that case (different branches), so this is the cheap half; the
  # expensive half is checking whether an open MR already says `Closes` the same
  # issue, done below when --closes is given.
  local existing eid
  existing=$(_mr_get "/projects/$proj/merge_requests?state=opened&source_branch=$src") || existing=""
  eid=$(printf '%s' "$existing" | "$YQ" e -p=json -r '.[0].iid // ""' - 2>/dev/null | grep -v '^null$' || true)
  if [ -n "$eid" ]; then
    print_warning "!$eid is already open for '$src' — not creating a second one"
    print_info "$(_mr_web_url "$eid")"
    return 1
  fi
  if [ -n "$closes" ]; then
    local dup_iid dup_title
    while IFS=$'\t' read -r dup_iid dup_title; do
      [ -n "$dup_iid" ] || continue
      print_warning "!$dup_iid already claims to close nwp/ops#$closes:"
      printf '    %s\n' "$dup_title"
      print_info "$(_mr_web_url "$dup_iid")"
      print_hint "if this is deliberate parallel work, say so in the description; otherwise rebase onto it"
      return 1
    done < <(_mr_get "/projects/$proj/merge_requests?state=opened&per_page=100" \
             | "$YQ" e -p=json -r \
               '.[] | select((.description // "") | test("(?i)closes\\s+nwp/ops#'"$closes"'([^0-9]|$)")) | [(.iid|tostring), .title] | @tsv' - 2>/dev/null || true)
  fi

  if [ "$dry" = true ]; then
    print_header "pl mr create — DRY RUN, nothing was sent"
    printf "  %-12s %s\n" "source:" "$src @ ${local_sha:0:12}"
    printf "  %-12s %s\n" "target:" "$target"
    printf "  %-12s %s\n" "title:"  "$title"
    echo; printf '%s\n' "$desc" | sed 's/^/  | /'
    return 0
  fi

  payload=$(_mr_json source_branch "$src" target_branch "$target" title "$title" \
                      description "$desc" remove_source_branch:bool "$remove_src")
  json=$(_mr_api POST "/projects/$proj/merge_requests" "$payload") \
    || die "could not create the merge request (HTTP $(_mr_http_status))"
  iid=$(printf '%s' "$json" | "$YQ" e -p=json '.iid // ""' - 2>/dev/null | grep -v '^null$')
  if [ -z "$iid" ]; then
    local msg; msg=$(printf '%s' "$json" | "$YQ" e -p=json '.message // .error // ""' - 2>/dev/null)
    die "GitLab refused the merge request (HTTP $(_mr_http_status)): ${msg:-no message}"
  fi

  print_success "created !$iid — $title"
  print_info "$(_mr_web_url "$iid")"

  # THE POINT OF DOING THIS THROUGH A VERB: the sensitive-path gate runs now,
  # on this MR, without anybody choosing to run it. Its exit code is reported
  # and deliberately does NOT fail the creation — the MR exists either way, and
  # a held MR is the correct outcome, not an error.
  echo
  local grc=0
  cmd_guard "$iid" --apply || grc=$?
  case "$grc" in
    1) print_warning "!$iid is HELD by the sensitive-path gate — that is the gate working." ;;
    2) print_warning "!$iid — sensitive-path status CANNOT BE VERIFIED; the gate held it." ;;
  esac
  return 0
}

################################################################################
# pl mr status <iid> — read-only. Says what the FORGE thinks, not what we hope.
################################################################################
# _mr_die_read <iid> — one honest explanation for "I could not read the MR".
#
# The old message was: "cannot read MR !350 (HTTP ) — token rejected, wrong
# project, or host unreachable". An EMPTY status with three guesses after it.
# Run outside a git checkout, `_mr_project` fails, no request is ever made, and
# the operator is told their token might be wrong. Name the actual cause.
_mr_die_read(){
  local iid="$1" st; st="$(_mr_http_status)"
  if ! _mr_project >/dev/null 2>&1; then
    die "cannot determine the GitLab project — \`pl mr\` derives it from the
  origin remote, so run it inside a checkout of the repo (cd ~/nwp), or set
  NWP_MR_PROJECT=<id>. No request was made; this is not a token problem."
  fi
  if ! _mr_have_token; then
    die "no usable token — set NWP_MR_TOKEN, or provide gitlab.api_token /
  gitlab.ai_host_token in \$MR_SECRETS_FILE. No request was made."
  fi
  case "$st" in
    ''|000) die "cannot reach the forge for MR !$iid (HTTP ${st:-none}) — a
  connection failure, not an authorisation one. Check the network and retry." ;;
    401)    die "cannot read MR !$iid — HTTP 401, the token was rejected." ;;
    403)    die "cannot read MR !$iid — HTTP 403, the token lacks rights here." ;;
    404)    die "cannot read MR !$iid — HTTP 404, no such MR in this project." ;;
    *)      die "cannot read MR !$iid (HTTP $st)." ;;
  esac
}

cmd_status(){
  _need_yq
  local iid="${1:-}"; [[ "$iid" =~ ^[0-9]+$ ]] || die "usage: pl mr status <iid>"
  _mr_have_token || die "no usable token (NWP_MR_TOKEN or .secrets.yml:gitlab.api_token)"
  local json; json=$(_mr_fetch "$iid") \
    || _mr_die_read "$iid"

  local title author state dms sha armed held labels
  title=$(_mr_title "$json"); author=$(_mr_author "$json"); state=$(_mr_state "$json")
  dms=$(_mr_detailed_merge_status "$json"); sha=$(_mr_head_sha "$json")
  labels=$(printf '%s' "$json" | "$YQ" e -p=json '.labels | join(", ")' - 2>/dev/null)
  _mr_is_draft "$json" && held="YES (draft — the forge will refuse a merge)" || held="no"
  _mr_auto_merge_armed "$json" && armed="ARMED" || armed="not armed"

  print_header "!$iid — $title"
  printf "  ${BOLD}%-16s${NC} %s\n" "state:"      "$state"
  printf "  ${BOLD}%-16s${NC} %s\n" "author:"     "${author:-?}"
  printf "  ${BOLD}%-16s${NC} %s\n" "HELD:"       "$held"
  printf "  ${BOLD}%-16s${NC} %s\n" "auto-merge:"  "$armed"
  printf "  ${BOLD}%-16s${NC} %s\n" "merge status:" "${dms:-?}"
  printf "  ${BOLD}%-16s${NC} %s\n" "head sha:"   "${sha:0:12}"
  printf "  ${BOLD}%-16s${NC} %s\n" "labels:"     "${labels:-—}"
  printf "  ${BOLD}%-16s${NC} %s\n" "url:"        "$(_mr_web_url "$iid")"

  # `draft_status` is GitLab telling us, in its own words, that it will not
  # merge this. Surfacing the raw value is the point: it is the forge's claim,
  # not ours.
  if [ "$dms" = "draft_status" ]; then
    echo
    print_success "GitLab reports detailed_merge_status=draft_status — a merge call returns 405."
  fi

  local sens rc=0
  sens=$(_mr_sensitive_paths "$iid") || rc=$?
  echo
  if [ "$rc" -eq 2 ]; then
    print_warning "could not read this MR's diff — sensitive-path status UNKNOWN (treated as held)"
  elif [ -z "$sens" ]; then
    print_info "touches no CLAUDE.md sensitive path"
  else
    print_warning "touches $(printf '%s\n' "$sens" | grep -c .) CLAUDE.md sensitive path(s) — two-person approval class:"
    printf '    %s\n' $sens
    local approver
    if approver=$(_mr_release_record "$iid" "$sha" "$author"); then
      print_success "released for THIS head sha by @$approver"
    else
      print_error "no valid release record for head ${sha:0:12} — this MR must stay held"
    fi
  fi
}

################################################################################
# pl mr ci — WHY is this pipeline red?
#
# THE GAP THIS CLOSES. The operator reports a pipeline by NUMBER ("#2254
# failed"). Until this verb there was no `pl` way to turn that number into a
# branch, a job, or a log line: `pl mr status` shows GitLab's merge verdict and
# says nothing about CI, and `pl mr merge` reads the job list only to decide
# whether to retry. Every triage session therefore hand-rolled a curl loop
# against /pipelines and /jobs/:id/trace — the exact "step around the verb"
# shape the pl-first standing order names, repeated from scratch, wrongly, each
# time. Recorded after a session did it again on 2026-08-11.
#
# WHAT IT REFUSES TO DO. It does not retry anything. A retry that goes green is
# not a diagnosis, and a verb that offers one next to the log invites the habit
# CLAUDE.md warns about ("it trains people to retry until green"). `pl mr merge`
# owns retrying, once, for the hold gate alone.
#
# EXIT CODES, fail-closed:
#   0 pipeline succeeded · 1 it failed · 2 CANNOT VERIFY · 3 not finished yet
# 3 is separate on purpose: `running` is not a verdict, and grading it 0 or 1
# would be substituting a literal for a measurement not yet takeable.
################################################################################
cmd_ci(){
  local iid="" pid="" log_n=40
  while [ $# -gt 0 ]; do
    case "$1" in
      --pipeline=*) pid="${1#*=}" ;;
      --log=*)      log_n="${1#*=}" ;;
      --no-log)     log_n=0 ;;
      -h|--help)    echo "usage: pl mr ci <iid> | pl mr ci --pipeline=<id> [--log=N|--no-log]"; return 0 ;;
      -*)           die "unknown flag: $1" ;;
      *)            iid="$1" ;;
    esac
    shift
  done
  [[ "$log_n" =~ ^[0-9]+$ ]] || die "--log wants a number of lines"
  [ -n "$iid$pid" ] || die "usage: pl mr ci <iid> | pl mr ci --pipeline=<id>"
  _mr_have_token || die "no usable token (NWP_MR_TOKEN or .secrets.yml:gitlab.api_token)"

  local pjson mr_iid=""
  if [ -n "$pid" ]; then
    [[ "$pid" =~ ^[0-9]+$ ]] || die "--pipeline wants a numeric id"
    pjson=$(_mr_pipeline "$pid") || {
      print_error "CANNOT VERIFY: cannot read pipeline #$pid (HTTP $(_mr_http_status))"
      return 2; }
    mr_iid=$(_mr_pipeline_ref_iid "$pjson") || true
  else
    [[ "$iid" =~ ^[0-9]+$ ]] || die "usage: pl mr ci <iid>"
    local mjson; mjson=$(_mr_fetch "$iid") || _mr_die_read "$iid"
    pid=$(_mr_head_pipeline_id "$mjson")
    if [ -z "$pid" ] || [ "$pid" = "null" ]; then
      print_error "CANNOT VERIFY: MR !$iid has no head pipeline. That is not a"
      print_error "  green tick — it is the absence of one."
      return 2
    fi
    mr_iid="$iid"
    pjson=$(_mr_pipeline "$pid") || {
      print_error "CANNOT VERIFY: cannot read pipeline #$pid (HTTP $(_mr_http_status))"
      return 2; }
  fi

  local pstatus pref psha pweb
  pstatus=$(printf '%s' "$pjson" | _mr_jget status)
  pref=$(printf '%s'    "$pjson" | _mr_jget ref)
  psha=$(printf '%s'    "$pjson" | _mr_jget sha)
  pweb=$(printf '%s'    "$pjson" | _mr_jget web_url)

  print_header "pipeline #$pid — $pstatus"
  printf "  ${BOLD}%-14s${NC} %s\n" "ref:"  "${pref:-?}"
  printf "  ${BOLD}%-14s${NC} %s\n" "head sha:" "${psha:0:12}"
  [ -n "$mr_iid" ] && printf "  ${BOLD}%-14s${NC} %s\n" "merge request:" "!$mr_iid"
  printf "  ${BOLD}%-14s${NC} %s\n" "url:"  "${pweb:-?}"

  local jobs
  jobs=$(_mr_pipeline_jobs "$pid") || {
    print_error "CANNOT VERIFY: the job list for pipeline #$pid could not be read."
    return 2; }
  if [ -z "$jobs" ]; then
    print_error "CANNOT VERIFY: pipeline #$pid reports no jobs at all. An empty"
    print_error "  job list is not a clean pipeline."
    return 2
  fi

  echo
  printf "  %-8s %-10s %-10s %s\n" "JOB" "STATUS" "STAGE" "NAME"
  local jid jst jstage jname jallow n_failed=0
  local -a failed_ids=() failed_names=()
  while IFS=$'\t' read -r jid jst jstage jname jallow; do
    [ -n "$jid" ] || continue
    local mark=""
    if [ "$jst" = "failed" ]; then
      if [ "$jallow" = "true" ]; then mark="  (allow_failure)"
      else n_failed=$((n_failed + 1)); failed_ids+=("$jid"); failed_names+=("$jname"); fi
    fi
    printf "  %-8s %-10s %-10s %s%s\n" "$jid" "$jst" "$jstage" "$jname" "$mark"
  done <<<"$jobs"

  if [ "$n_failed" -gt 0 ] && [ "$log_n" -gt 0 ]; then
    local i
    for i in "${!failed_ids[@]}"; do
      echo
      print_header "last $log_n lines — job ${failed_ids[$i]} (${failed_names[$i]})"
      local trace
      if trace=$(_mr_job_trace "${failed_ids[$i]}" "$log_n") && [ -n "$trace" ]; then
        printf '%s\n' "$trace"
      else
        print_warning "the trace for job ${failed_ids[$i]} could not be read"
      fi
    done
  fi

  echo
  case "$pstatus" in
    success)  print_success "pipeline #$pid succeeded"; return 0 ;;
    failed)   print_error   "pipeline #$pid FAILED — $n_failed blocking job(s)"
              print_hint "classify before you retry: a defect in this MR, a failure already on the target branch, or a flake with a NAMED mechanism"
              return 1 ;;
    running|pending|created|waiting_for_resource|preparing|scheduled|manual)
              print_warning "pipeline #$pid is $pstatus — not a verdict yet, ask again"
              return 3 ;;
    canceled|skipped)
              print_error "CANNOT VERIFY: pipeline #$pid is $pstatus — it never ran to a verdict"
              return 2 ;;
    *)        print_error "CANNOT VERIFY: unrecognised pipeline status '$pstatus'"
              return 2 ;;
  esac
}

################################################################################
# _mr_report_read_failure <iid> — one honest classification of "I could not read
# that MR", for the verbs that must RETURN a code rather than die(1).
#
# `_mr_die_read` above is the right shape for the read verbs, but it exits 1 for
# every cause, which collapses "there is no such MR" (a definite answer) into
# "the forge did not answer" (no answer at all). The verbs below distinguish
# them, because the operator's next action differs completely.
#
# Prints the explanation; returns 1 for a definite negative, 2 for CANNOT VERIFY.
################################################################################
_mr_report_read_failure(){
  local iid="$1" st; st="$(_mr_http_status)"
  if ! _mr_project >/dev/null 2>&1; then
    print_error "CANNOT VERIFY: cannot determine the GitLab project — \`pl mr\` derives"
    print_info  "  it from the origin remote, so run this inside a checkout of the repo,"
    print_info  "  or set NWP_MR_PROJECT=<id>. No request was made."
    return 2
  fi
  case "$st" in
    404) print_error "!$iid does not exist in $(_mr_project_human) — HTTP 404."
         print_info  "  MR numbers are PER PROJECT and this directory resolves to"
         print_info  "  $(_mr_project_human). You may mean another project's !$iid."
         return 1 ;;
    401) print_error "CANNOT VERIFY: HTTP 401 reading !$iid — the token was rejected."
         return 2 ;;
    403) print_error "CANNOT VERIFY: HTTP 403 reading !$iid — the token lacks rights here."
         return 2 ;;
    ''|000)
         print_error "CANNOT VERIFY: could not reach the forge for !$iid (HTTP ${st:-none})."
         print_info  "  A connection failure, not an authorisation one."
         return 2 ;;
    *)   print_error "CANNOT VERIFY: could not read !$iid (HTTP $st)."
         return 2 ;;
  esac
}

################################################################################
# pl mr note <iid> — leave a comment on a merge request.
#
# THE GAP THIS CLOSES. `pl issue comment` has existed for months; its MR
# equivalent did not, so a session that needed to record a correction ON THE MR
# — which is where the reviewer is looking — had three options: hand-roll a curl
# POST (the "step around the verb" the standing order forbids), put it in an ops
# issue nobody reading the MR would see, or say nothing. It bit twice in two
# days, on !431 and !441, and both times the correction went unrecorded.
#
# THE BODY COMES FROM STDIN. Deliberately the same idiom as `pl issue comment`,
# and for a reason with a scar attached: `pl issue create` accepted `--desc` and
# SILENTLY DISCARDED anything piped to it, so a heredoc-shaped description
# vanished with a success message on top. An asymmetry between two verbs that
# look alike is an invitation to lose text. A trailing argument still works for
# a one-liner; stdin is for the multi-paragraph case, which is most of them.
#
# EXIT  0 posted · 1 refused (empty body, no such MR) · 2 CANNOT VERIFY
################################################################################
cmd_note(){
  local iid="" body="" stdin_asked=false
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        printf 'usage: pl mr note <iid> "text"        (or pipe the body on stdin)\n'
        printf '       pl mr note <iid> -             read the body from stdin, explicitly\n'
        return 0 ;;
      -)  stdin_asked=true; shift ;;
      -*) die "unknown option: $1 (usage: pl mr note <iid> \"text\", or pipe it on stdin)" ;;
      *)  if [ -z "$iid" ]; then iid="$1"; else body="${body:+$body }$1"; fi; shift ;;
    esac
  done
  # ARGUMENT VALIDATION BEFORE THE MACHINE IS INSPECTED (the verify_restic
  # lesson): whether "$iid" is a number is a property of the command; whether a
  # token exists is a property of the host.
  [[ "$iid" =~ ^[0-9]+$ ]] || die "usage: pl mr note <iid> \"text\"   (or pipe the body on stdin)"

  # stdin wins only when no argument body was given, so `pl mr note 441 "x"` in a
  # pipeline does not silently prefer the pipe — and neither does it silently
  # discard it, which is the failure this idiom was copied to avoid.
  if [ "$stdin_asked" = true ] || { [ -z "$body" ] && [ ! -t 0 ]; }; then
    local piped; piped="$(cat)"
    [ -n "$piped" ] && body="${body:+$body$'\n'}$piped"
  fi
  # An all-whitespace body is an empty body. A note nobody can read is not a
  # record; posting it would put a green tick on a comment that says nothing.
  if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
    print_error "REFUSING: the note body is empty."
    print_info  "  Pass it as an argument, or pipe it:"
    print_info  "    pl mr note $iid \"one line\""
    print_info  "    printf '%%s\\n' 'many lines' | pl mr note $iid"
    return 1
  fi

  _mr_have_token || {
    print_error "CANNOT VERIFY: no usable token (NWP_MR_TOKEN, or gitlab.api_token /"
    print_error "  gitlab.ai_host_token in \$MR_SECRETS_FILE). No request was made."
    return 2; }

  # WHICH PROJECT, SAID OUT LOUD, BEFORE THE WRITE (ops#293). On 2026-08-06
  # `pl mr release 80` run from the wrong directory wrote to a different
  # project's !80 and printed SUCCESS. The MR is read first so a note can never
  # land on an MR that only coincidentally shares a number.
  local json; json=$(_mr_fetch "$iid") || { local rc=0; _mr_report_read_failure "$iid" || rc=$?; return "$rc"; }
  print_info "project: $(_mr_project_human)  (resolved from this directory's git remote)"
  print_info "!$iid — $(_mr_title "$json")"

  _mr_post_note "$iid" "$body" || {
    print_error "could not post the note (HTTP $(_mr_http_status)) — nothing was recorded."
    return 2; }
  print_success "note posted on !$iid ($(printf '%s' "$body" | grep -c '') line(s))"
  print_info "$(_mr_web_url "$iid")"
  return 0
}

################################################################################
# pl mr rebase <iid> — move an MR onto the current tip of its target branch.
#
# THE GAP THIS CLOSES. A merge request whose target branch has moved is stuck
# behind a COMPLETED pipeline, and a completed pipeline's result can never
# change. !441 failed `lint:pipefail-sigpipe` on a head predating the very fix
# for that lint, which had already merged to main; the same red result was
# reported three times because there was nothing to read but a stale one.
# Rebasing is a WRITE, so the read-only-reconnaissance exception does not cover
# it, and until now the only routes were a hand-rolled `PUT /rebase` or a local
# `git push --force` — both of them the shape the pl-first standing order exists
# to retire.
#
# THE TWO FACTS THIS VERB CARRIES, so no session has to re-derive them:
#
#   1. THIS INSTANCE'S `detailed_merge_status` GOES STALE. It reports `conflict`
#      for branches that merge cleanly, because it is a cached computation that
#      is not always recomputed when the target moves (CLAUDE.md, verified
#      2026-08-02). So a `conflict` here is never a refusal on its own: the
#      rebase IS the recompute, and a conflict is only believed once a real
#      local test-merge has REPRODUCED it. `checking` means ask again.
#
#   2. A REBASE CANCELS THE PIPELINE IT SUPERSEDES. It pushes a new head, which
#      starts a fresh pipeline and cancels the running one. Saying so, and
#      naming the NEW pipeline id rather than the old, is the whole difference
#      between a report an operator can act on and the three confusing ones that
#      preceded this verb.
#
# IT DOES NOT MERGE. Nothing here touches the merge endpoint; a bot may rebase
# (it is exactly what a bot should be doing) and may not merge, and
# `_mr_merge_actor_ok` in cmd_merge is untouched by this.
#
# EXIT  0 rebased (or already up to date) · 1 real failure (a REPRODUCED
#       conflict, no such MR) · 2 CANNOT VERIFY · 3 not finished — still
#       rebasing when the wait ran out
################################################################################
cmd_rebase(){
  local iid="" dry=false wait_s="${NWP_MR_REBASE_TIMEOUT:-180}"
  local poll="${NWP_MR_REBASE_POLL:-5}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=true; shift ;;
      --wait)    wait_s="${2:-}"; shift 2 ;;
      --wait=*)  wait_s="${1#*=}"; shift ;;
      -h|--help)
        cat <<'EOF'
usage: pl mr rebase <iid> [--wait=SECONDS] [--dry-run]

  Rebase a merge request onto the current tip of its target branch, which is
  what unsticks an MR whose red pipeline is a COMPLETED run on a stale head.

  Never believes a `conflict` verdict on its own — this instance's
  detailed_merge_status is a cached value that goes stale. A conflict is
  reported only once a real local test-merge has reproduced it.

  A rebase CANCELS the pipeline it supersedes; this reports the NEW pipeline id.

  exit 0 rebased · 1 reproduced conflict / no such MR · 2 cannot verify
       · 3 still rebasing when the wait ran out
EOF
        return 0 ;;
      -*) die "unknown option: $1 (try: pl mr rebase --help)" ;;
      *)  [ -z "$iid" ] && { iid="$1"; shift; } || die "unexpected arg: $1" ;;
    esac
  done
  [[ "$iid" =~ ^[0-9]+$ ]] || die "usage: pl mr rebase <iid> [--wait=SECONDS] [--dry-run]"
  [[ "$wait_s" =~ ^[0-9]+$ ]] || die "--wait wants a number of seconds"

  _mr_have_token || {
    print_error "CANNOT VERIFY: no usable token (NWP_MR_TOKEN, or gitlab.api_token /"
    print_error "  gitlab.ai_host_token in \$MR_SECRETS_FILE). No request was made."
    return 2; }
  local proj
  proj=$(_mr_project) || {
    print_error "CANNOT VERIFY: cannot resolve the project (no origin remote?)."
    return 2; }

  local json rc=0
  json=$(_mr_fetch "$iid") || { _mr_report_read_failure "$iid" || rc=$?; return "$rc"; }

  local title state dms old_sha old_pid src tgt
  title=$(_mr_title "$json");        state=$(_mr_state "$json")
  dms=$(_mr_detailed_merge_status "$json")
  old_sha=$(_mr_head_sha "$json");   old_pid=$(_mr_head_pipeline_id "$json")
  src=$(_mr_source_branch "$json");  tgt=$(_mr_target_branch "$json")

  print_header "!$iid — $title"
  printf "  ${BOLD}%-16s${NC} %s\n" "project:" "$(_mr_project_human)"
  printf "  ${BOLD}%-16s${NC} %s\n" "state:"   "$state"
  printf "  ${BOLD}%-16s${NC} %s\n" "branches:" "${src:-?} → ${tgt:-?}"
  printf "  ${BOLD}%-16s${NC} %s\n" "head sha:" "${old_sha:0:12}"
  printf "  ${BOLD}%-16s${NC} %s\n" "merge status:" "${dms:-?}  (CACHED — see below)"
  printf "  ${BOLD}%-16s${NC} %s\n" "pipeline now:" "${old_pid:-none}"

  if [ "$state" != "opened" ]; then
    echo
    print_error "!$iid is $state, not open — there is nothing to rebase."
    return 1
  fi
  [ -n "$src" ] && [ -n "$tgt" ] || {
    echo
    print_error "CANNOT VERIFY: could not read !$iid's source/target branches."
    return 2; }

  echo
  case "$dms" in
    conflict)
      print_info "GitLab says 'conflict'. That is NOT a refusal here: on this instance"
      print_info "  detailed_merge_status is a cached computation that goes stale, and"
      print_info "  reports 'conflict' for branches that merge cleanly. The rebase below"
      print_info "  IS the recompute; a conflict is believed only once REPRODUCED." ;;
    checking|unchecked|preparing)
      print_info "GitLab is still computing this MR's merge status ('$dms'). That means"
      print_info "  ask again, not no — the rebase proceeds and settles it." ;;
  esac
  if _mr_is_draft "$json" || _mr_has_hold_label "$json"; then
    print_warning "!$iid is HELD. A rebase does NOT release it, and it moves the head,"
    print_warning "  so any release record bound to ${old_sha:0:12} is invalidated by design."
  fi

  if [ "$dry" = true ]; then
    echo
    print_header "DRY RUN — nothing was sent"
    print_info "would: PUT /projects/$(_mr_project_human)/merge_requests/$iid/rebase"
    print_info "would move !$iid from ${old_sha:0:12} onto the tip of $tgt"
    print_info "would CANCEL pipeline #${old_pid:-none} and start a new one"
    return 0
  fi

  echo
  print_info "rebasing !$iid onto $tgt …"
  print_warning "this pushes a NEW head, which CANCELS pipeline #${old_pid:-none}."
  if ! _mr_api PUT "/projects/$proj/merge_requests/$iid/rebase" >/dev/null; then
    local st; st="$(_mr_http_status)"
    case "$st" in
      403|401)
        print_error "CANNOT VERIFY: HTTP $st — this token may not push to '$src', so the"
        print_error "  rebase did not happen and nothing about mergeability was settled."
        print_info  "  A rebase needs Developer with push access on the source branch." ;;
      409)
        print_error "CANNOT VERIFY: HTTP 409 — GitLab refused to start the rebase."
        print_info  "  Usually another rebase is already running on this MR. Ask again." ;;
      *)
        print_error "CANNOT VERIFY: the rebase request failed (HTTP ${st:-none})." ;;
    esac
    return 2
  fi

  # THE REBASE IS ASYNCHRONOUS. `PUT /rebase` returns 202 Accepted and a sidekiq
  # worker does the work, so the answer is in `rebase_in_progress`, not in the
  # response body. Bounded by ATTEMPTS rather than elapsed time so the tests can
  # drive it with poll=0 and no sleeping — a time-only bound turns poll=0 into
  # "give up immediately", which is a different knob (the _mr_diff_ready lesson).
  local max_rounds
  if [ "$poll" -gt 0 ]; then max_rounds=$(( wait_s / poll + 1 ));
  else max_rounds=$(( wait_s > 0 ? wait_s : 1 )); fi
  local rounds=0 rjson merr new_sha
  while :; do
    rounds=$((rounds + 1))
    rjson=$(_mr_fetch_rebase "$iid") || {
      print_error "CANNOT VERIFY: the rebase was accepted but !$iid could not be re-read"
      print_error "  (HTTP $(_mr_http_status)) — its state is now unknown, not unchanged."
      return 2; }
    _mr_rebase_in_progress "$rjson" || break
    if [ "$rounds" -ge "$max_rounds" ]; then
      printf '\n' >&2
      print_warning "!$iid is STILL rebasing after ${wait_s}s — not finished."
      print_info    "  This is 'ask again', not a failure. \`pl mr rebase $iid\` is safe to"
      print_info    "  re-run, or read the outcome with \`pl mr status $iid\`."
      return 3
    fi
    [ "$poll" -gt 0 ] && { sleep "$poll"; printf '.' >&2; }
  done
  [ "$rounds" -gt 1 ] && printf '\n' >&2

  merr=$(_mr_merge_error "$rjson")
  new_sha=$(_mr_head_sha "$rjson")

  # ── A CONFLICT CLAIM IS A HYPOTHESIS UNTIL IT IS REPRODUCED ────────────────
  if [ -n "$merr" ]; then
    echo
    print_warning "GitLab reports a rebase failure on !$iid:"
    printf '      %s\n' "$merr"
    print_info "Not believed on its own. Reproducing it with a real local test-merge of"
    print_info "  origin/$src into origin/$tgt …"
    local paths trc=0
    paths=$(_mr_local_testmerge "$tgt" "$src") || trc=$?
    case "$trc" in
      1) print_error "CONFLICT CONFIRMED — origin/$src does not merge into origin/$tgt."
         [ -n "$paths" ] && { print_info "conflicting path(s):"; printf '    %s\n' $paths; }
         print_hint "resolve it on the branch, push, and re-run: pl mr rebase $iid"
         return 1 ;;
      0) print_error "CANNOT VERIFY: the forge reports a conflict but a real local"
         print_error "  test-merge of origin/$src into origin/$tgt is CLEAN. The two"
         print_error "  disagree, which is exactly the stale-cache shape CLAUDE.md"
         print_error "  records — so this is neither a conflict nor a clean bill."
         print_hint "look by hand before acting: $(_mr_web_url "$iid")"
         return 2 ;;
      *) print_error "CANNOT VERIFY: the forge reports a conflict and the local"
         print_error "  test-merge could NOT be run (no git checkout, or origin/$tgt /"
         print_error "  origin/$src unfetchable). An unreproduced claim is not a verdict."
         return 2 ;;
    esac
  fi

  echo
  if [ -z "$new_sha" ]; then
    print_error "CANNOT VERIFY: the rebase finished but !$iid reports no head sha."
    return 2
  fi
  if [ "$new_sha" = "$old_sha" ]; then
    print_success "!$iid is already up to date with $tgt — head unchanged (${old_sha:0:12})."
    print_info "Nothing was pushed, so pipeline #${old_pid:-none} is NOT superseded and"
    print_info "stands as this MR's result. If it is red, the cause is on this branch."
    return 0
  fi
  print_success "!$iid rebased onto $tgt: ${old_sha:0:12} → ${new_sha:0:12}"

  # ── THE NEW PIPELINE, NOT THE OLD ONE ──────────────────────────────────────
  # Getting this wrong is what produced three confusing reports on !441. The old
  # pipeline is a completed run on a sha that no longer exists on this MR; its
  # result can never change, and re-reading it is how a fixed MR keeps looking
  # broken.
  local new_pid="" prounds=0
  while [ "$prounds" -lt 6 ]; do
    prounds=$((prounds + 1))
    local pjson; pjson=$(_mr_fetch "$iid") || break
    new_pid=$(_mr_head_pipeline_id "$pjson")
    [ -n "$new_pid" ] && [ "$new_pid" != "$old_pid" ] && break
    new_pid=""
    [ "$poll" -gt 0 ] && sleep "$poll"
  done

  echo
  if [ -n "$old_pid" ]; then
    print_warning "pipeline #$old_pid is SUPERSEDED — the rebase cancelled it. It is a"
    print_warning "  completed run on ${old_sha:0:12}, a sha this MR no longer has, so its"
    print_warning "  result can never change. Do not report it again."
  fi
  if [ -n "$new_pid" ]; then
    print_success "NEW pipeline #$new_pid — this is the one to watch."
    print_hint "  pl mr ci $iid"
  else
    print_warning "no new pipeline is visible yet. The rebase DID land (${new_sha:0:12});"
    print_warning "  GitLab has simply not created the pipeline yet, which is 'not yet',"
    print_warning "  not 'none'. Ask again: pl mr ci $iid"
  fi
  print_info "$(_mr_web_url "$iid")"
  return 0
}

################################################################################
# pl mr list — the one screen the 2026-08-01 sweep would have lit up red.
################################################################################
cmd_list(){
  _need_yq
  _mr_have_token || die "no usable token (NWP_MR_TOKEN or .secrets.yml:gitlab.api_token)"
  local proj json; proj=$(_mr_project) || die "cannot resolve the project (no origin remote?)"
  json=$(_mr_get "/projects/$proj/merge_requests?state=opened&per_page=100") \
    || die "cannot list merge requests (HTTP $(_mr_http_status))"
  print_header "open merge requests — hold state"
  printf "  %-5s %-6s %-11s %-14s %s\n" "!"  "HELD" "AUTO-MERGE" "MERGE STATUS" "TITLE"
  printf "  %-5s %-6s %-11s %-14s %s\n" "-----" "------" "-----------" "--------------" "-----"
  local armed_unheld=0
  while IFS=$'\t' read -r iid draft mwps dms title; do
    [ -n "$iid" ] || continue
    local h="no" a="-"
    [ "$draft" = "true" ] && h="HELD"
    if [ "$mwps" = "true" ]; then
      a="ARMED"
      [ "$draft" = "true" ] || armed_unheld=$((armed_unheld + 1))
    fi
    printf "  ${BOLD}%-5s${NC} %-6s %-11s %-14s %-52.52s\n" "$iid" "$h" "$a" "${dms:0:14}" "$title"
  done < <("$YQ" e -p=json -r \
      '.[] | [(.iid|tostring), (.draft|tostring), (.merge_when_pipeline_succeeds|tostring), (.detailed_merge_status // "?"), (.title|sub("\n";" "))] | @tsv' \
      - <<<"$json" 2>/dev/null)
  echo
  if [ "$armed_unheld" -gt 0 ]; then
    print_warning "$armed_unheld MR(s) will merge THEMSELVES the moment CI goes green."
    print_hint "hold one: pl mr hold <iid> --reason='...'"
  fi
}

################################################################################
# pl mr hold <iid> --reason="..."
################################################################################
cmd_hold(){
  _need_yq
  local iid="" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason)   reason="${2:-}"; shift 2 ;;
      --reason=*) reason="${1#*=}"; shift ;;
      -h|--help)  printf 'usage: pl mr hold <iid> --reason="why"\n'; return 0 ;;
      -*) die "unknown option: $1 (usage: pl mr hold <iid> --reason=\"why\")" ;;
      *) [ -z "$iid" ] && { iid="$1"; shift; } || die "unexpected arg: $1" ;;
    esac
  done
  [[ "$iid" =~ ^[0-9]+$ ]] || die "usage: pl mr hold <iid> --reason=\"why\""
  # A hold with no stated reason is the document-shaped failure all over again.
  [ -n "$reason" ] || die "--reason is required: a hold nobody can explain is a hold nobody will respect"
  _mr_have_token || die "no usable token (NWP_MR_TOKEN or .secrets.yml:gitlab.api_token)"

  local json; json=$(_mr_fetch "$iid") || _mr_die_read "$iid"
  [ "$(_mr_state "$json")" = "opened" ] || die "MR !$iid is $(_mr_state "$json") — nothing to hold"
  local was_armed="no"; _mr_auto_merge_armed "$json" && was_armed="yes"

  _mr_apply_hold "$iid" "$reason" "$MR_HOLD_LABEL_MANUAL" \
    || die "could not apply the hold (HTTP $(_mr_http_status))"

  # Re-read and ASSERT. "I sent a PUT" is not "it is held".
  json=$(_mr_fetch "$iid") || die "hold applied but could not verify it — check by hand: $(_mr_web_url "$iid")"
  if _mr_is_draft "$json"; then
    print_success "!$iid is HELD (draft) — GitLab will refuse a merge with 405"
  else
    die "hold did NOT take: !$iid is still not a draft. Do not rely on it. $(_mr_web_url "$iid")"
  fi
  [ "$was_armed" = "yes" ] && print_info "auto-merge was ARMED on this MR — disarmed"
  _mr_auto_merge_armed "$json" && print_warning "auto-merge is armed again — harmless: draft blocks the merge"
  print_info "$(_mr_web_url "$iid")"
  print_hint "release it: pl mr release $iid --approved-by=<handle> --reason='...'"
}

################################################################################
# pl mr release <iid> --approved-by=<handle>
#
# Releasing a SENSITIVE-PATH MR is the two-person moment. The checks below are
# the whole reason this is a verb and not a click:
#   * the approver may not be the author            (one pair of eyes ≠ two)
#   * the approver may not be a bot                 (a bot approving is not review)
#   * the record is bound to the current head sha   (push again ⇒ re-held)
################################################################################
cmd_release(){
  _need_yq
  local iid="" approver="" reason="" do_merge=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --approved-by)   approver="${2:-}"; shift 2 ;;
      --approved-by=*) approver="${1#*=}"; shift ;;
      --reason)        reason="${2:-}"; shift 2 ;;
      --reason=*)      reason="${1#*=}"; shift ;;
      --merge)         do_merge=true; shift ;;
      -h|--help) printf 'usage: pl mr release <iid> --approved-by=<handle> [--reason="..."] [--merge]\n'; return 0 ;;
      -*) die "unknown option: $1 (usage: pl mr release <iid> --approved-by=<handle>)" ;;
      *) [ -z "$iid" ] && { iid="$1"; shift; } || die "unexpected arg: $1" ;;
    esac
  done
  [[ "$iid" =~ ^[0-9]+$ ]] || die "usage: pl mr release <iid> --approved-by=<handle> [--reason=\"...\"]"
  approver="${approver#@}"
  [ -n "$approver" ] || die "--approved-by=<handle> is required — a release names the second pair of eyes"

  # WHICH PROJECT, SAID OUT LOUD, BEFORE ANY WRITE (ops#293).
  # MR numbers are per-project and this estate works two projects in the same
  # breath. On 2026-08-06 `pl mr release 80` run from ~/nwp released nwp/nwp!80 —
  # a long-merged MR — instead of the intended nwp/nwc!80, printed SUCCESS, and
  # left the real MR held. An ambiguous identifier that silently picks one is
  # worse than one that asks.
  local relstate
  relstate=$(_mr_assert_releasable "$iid") || {
    case "$relstate" in
      merged|closed)
        print_error "!$iid in $(_mr_project_human) is a ${relstate} MR — nothing to release."
        print_info  "MR numbers are PER PROJECT and this directory resolves to $(_mr_project_human)."
        print_info  "You almost certainly meant a different project's !$iid. cd there and re-run." ;;
      not-held)
        print_error "!$iid in $(_mr_project_human) is open but NOT held — nothing to release."
        print_info  "A release lifts a hold. This MR carries neither Draft nor a hold label." ;;
      missing)
        print_error "!$iid does not exist in $(_mr_project_human)." ;;
      *)
        print_error "could not determine whether !$iid is releasable — refusing to write." ;;
    esac
    print_info "Nothing was changed."
    return 1
  }
  print_info "project: $(_mr_project_human)  (resolved from this directory's git remote)"

  # ── ADR-0028 "Phase 1 dispensation": a trigger that arms itself ────────────
  #
  # While the registry's `approvers:` fact names exactly ONE human, an agent may
  # record that person's approval on their explicit instruction. That is a
  # record of INTENT, not authentication, and is accepted deliberately: a
  # two-person rule with only one available person is not two-person review, and
  # pretending otherwise is how real controls come to be ignored.
  #
  # The MOMENT a second name is added this refuses agent-recorded approvals —
  # a second human exists, so the approval must be authenticated (ed25519-sk
  # Solo touch, ADR-0028 "Signing"). Adding the name is the entire switch.
  #
  # Keyed off a DECLARED FACT, never a date or a phase name: inert today,
  # correct forever, and it arms without anyone remembering to arm it.
  # Via _mr_approver_count — ONE reader of this fact. This block used to count
  # `approvers:` itself with a local yq call, and _mr_review_mode now keys off the
  # same list, so a second counter here is precisely the duplication the operator
  # meant by "drift back into complexity": two places reading one fact, free to
  # disagree. The shared accessor also works without yq, which this did not.
  local _appr_n=0
  _appr_n=$(_mr_approver_count) || _appr_n=0
  if [ "$_appr_n" -gt 1 ] && [ -z "${NWP_MR_APPROVAL_SIGNATURE:-}" ]; then
    die "REFUSING: the registry declares $_appr_n approvers, so a second human
  can sign. Recording an approval on someone's behalf is sanctioned only while
  there is exactly one (ADR-0028, Phase 1 dispensation).

  @$approver must authenticate it themselves — ed25519-sk Solo touch, per
  ADR-0028 'Signing'. Set NWP_MR_APPROVAL_SIGNATURE once that path exists.

  Not a bug: adding the second name to approvers: is what turns the
  record-of-intent into a real two-person rule."
  fi

  _mr_have_token || die "no usable token (NWP_MR_TOKEN or .secrets.yml:gitlab.api_token)"

  local json; json=$(_mr_fetch "$iid") || _mr_die_read "$iid"
  local author sha proj
  author=$(_mr_author "$json"); sha=$(_mr_head_sha "$json"); proj=$(_mr_project)

  local sens rc=0
  sens=$(_mr_sensitive_paths "$iid") || rc=$?
  [ "$rc" -eq 2 ] && die "cannot read this MR's diff — refusing to release something I cannot inspect"

  # The two-person checks bind on a sensitive-path change AND on any MR carrying
  # a standing hold:: label — otherwise `pl mr hold` could be undone by the same
  # actor that ought to be waiting for a second opinion.
  if [ -n "$sens" ] || _mr_has_hold_label "$json"; then
    [ "$approver" != "$author" ] \
      || die "@$approver opened !$iid — the author cannot be the second pair of eyes on a held change"
    if _mr_handle_is_bot "$approver"; then
      die "@$approver looks like a bot account — a bot approving a held change is not two-person review"
    fi
  fi

  # Record FIRST, lift SECOND. If the note fails, nothing was released.
  local body
  body="$MR_RELEASE_MARKER
Approved-By: $approver
Commit: $sha
Reason: ${reason:-(none given)}

This release is bound to head ${sha:0:12}. Pushing another commit invalidates it
and the guard will re-hold this MR."
  local np; np=$(_mr_json body "$body")
  _mr_api POST "/projects/$proj/merge_requests/$iid/notes" "$np" >/dev/null \
    || die "could not record the release (HTTP $(_mr_http_status)) — nothing was lifted"

  _mr_lift_hold "$iid" || die "release recorded but the hold could not be lifted (HTTP $(_mr_http_status))"

  json=$(_mr_fetch "$iid") || die "released but could not verify — check by hand: $(_mr_web_url "$iid")"
  if _mr_is_draft "$json"; then
    die "still a draft after release — the title may carry an unusual prefix. $(_mr_web_url "$iid")"
  fi
  print_success "!$iid released by @$approver, bound to head ${sha:0:12}"
  [ -n "$sens" ] && print_info "sensitive paths: $(printf '%s\n' "$sens" | tr '\n' ' ')"

  # THE PIPELINE MUST BE TOLD. Lifting the Draft is only layer 1; layer 2 of the
  # hold is the gate job's own RED result, and a release does not re-run a job
  # that has already finished. Without this the MR is released and unmergeable at
  # the same time, and the web UI still says blocked with nothing explaining why.
  # That is exactly the catch-22 the operator hit on !350 (ops#283).
  #
  # This is not self-approval: the retried job re-runs the gate, which looks for a
  # release record bound to the CURRENT head. It passes on its own evidence or it
  # goes red again.
  local retried rc
  retried=$(_mr_retry_gate_job "$iid"); rc=$?
  case $rc in
    0) print_info "re-ran the held gate job (#$retried) so the pipeline re-evaluates the release" ;;
    2) print_warning "could not re-run the gate job (HTTP $(_mr_http_status)) — the release IS recorded," 
       print_warning "but the pipeline will stay red until that job is retried by hand." ;;
    *) print_info "no failed gate job to re-run (pipeline may not have run yet)" ;;
  esac

  if [ "$do_merge" != true ]; then
    print_hint "merging is still a human action — this only removed the hold."
    print_hint "Wait for the pipeline to go green, then merge here:"
    print_hint "  $(_mr_web_url "$iid")"
    return 0
  fi

  # --merge: the operator asked "why do I need to release and merge. Can't the
  # merge be the release?" (2026-08-05). The two-person property is that the
  # AUTHOR is not the approver — the approver merging is not a weakening of it,
  # it IS the approval. So this is one action with the same record.
  #
  # It must WAIT, not merge immediately: the release just re-ran the gate job, so
  # merging now would race a pipeline that is deliberately re-checking the release
  # we have only just recorded. Merging before that lands would defeat the point
  # of re-running it.
  # SOLO MODE: THE ONE APPROVAL POINT IS THE MR PAGE, so --merge is refused here.
  #
  # Operator ruling 2026-08-06: "I should be able to approve/merge once and only
  # in one spot which is the MR location." A second way to merge — from a shell,
  # by whoever holds the token — is a second spot, and it is the one an automation
  # would reach for. Refusing is not an inconvenience to the operator: in solo mode
  # nothing is held, so there is nothing to release and no reason to run this verb
  # before merging at all.
  if [ "$(_mr_review_mode)" = solo ]; then
    print_error "REFUSING --merge: this estate is in SOLO review mode."
    print_info  "The single approval point is the MR page — click Merge there, and that"
    print_info  "click IS the approval. In solo mode nothing is held, so there is no"
    print_info  "release to lift and no need to run this verb first."
    print_info  "  $(_mr_web_url "$iid")"
    print_info  "\`pl mr review-mode\` explains the modes; --merge becomes available in team"
    print_info  "mode, where it requires an identity distinct from the author."
    return 1
  fi

  # TWO-PERSON, RESTORED AS A CHECK. An existing guard in
  # tests/unit/test-mr-release-pipeline.bats forbade cmd_release from merging at
  # all — "the verb re-runs the CHECK, it never merges" — and it was right to:
  # dropping the human Merge click removes the only step whose actor the FORGE
  # can identify. `--approved-by` is a string the caller types.
  #
  # So --merge does not merely skip that step, it replaces it with a stronger
  # one: the token's own forge-verified user must not be the MR author. An author
  # can no longer release-and-merge their own MR in one command, under any handle
  # they care to type — which is more than the UI click guaranteed, since the UI
  # let an author merge their own MR once someone had left a release note.
  local mr_json mr_author tok_user
  mr_json=$(_mr_fetch "$iid") || {
    print_error "cannot re-read !$iid to check who authored it — NOT merging."
    print_info  "The release IS recorded. Merge by hand: $(_mr_web_url "$iid")"
    return 1
  }
  mr_author=$(_mr_author "$mr_json")
  if ! tok_user=$(_mr_token_user); then
    # "I could not establish who I am" is never "I am somebody else".
    print_error "could not establish this token's forge identity (GET /user) — NOT merging."
    print_info  "--merge requires a verified identity distinct from the author."
    print_info  "The release IS recorded. Merge by hand: $(_mr_web_url "$iid")"
    return 1
  fi
  if [ -z "$mr_author" ]; then
    print_error "could not read !$iid's author — NOT merging (cannot check two-person)."
    return 1
  fi
  if [ "$tok_user" = "$mr_author" ]; then
    print_error "REFUSING --merge: this token belongs to @$tok_user, who AUTHORED !$iid."
    print_info  "A release lifts a hold; it is not a second pair of eyes when the"
    print_info  "same person does both. --approved-by is a string you typed; this is"
    print_info  "the identity the forge sees, and it is the one that has to differ."
    print_info  "The release IS recorded. Have someone else merge: $(_mr_web_url "$iid")"
    return 1
  fi
  print_info "merging as @$tok_user (author is @$mr_author — distinct, so two-person holds)"
  print_info "waiting for the pipeline to re-evaluate the release before merging…"
  local waited=0 st
  while [ "$waited" -lt "${NWP_MR_MERGE_TIMEOUT:-600}" ]; do
    st=$(_mr_pipeline_status "$iid")
    case "$st" in
      success) break ;;
      failed|canceled)
        print_error "pipeline is $st — NOT merging."
        print_info  "The release is recorded; fix the pipeline and merge when it is green."
        return 1 ;;
    esac
    sleep 20; waited=$((waited + 20))
    printf '.' >&2
  done
  printf '\n' >&2
  if [ "$st" != "success" ]; then
    # Never merge on an unknown verdict. "I ran out of patience" is not "green".
    print_warning "pipeline still '$st' after ${waited}s — NOT merging."
    print_info    "The release IS recorded. Merge when it goes green: $(_mr_web_url "$iid")"
    return 1
  fi
  print_success "pipeline green after ${waited}s — merging"
  cmd_merge "$iid"
}

################################################################################
# pl mr merge <iid> — merge, with the merge-status knowledge that had nowhere
# to live (ops#216).
#
# THIS INSTANCE LIES ABOUT CONFLICTS. `detailed_merge_status` is computed
# asynchronously and goes stale: branches that merge cleanly report `conflict`
# for minutes at a time. Verified repeatedly on 2026-08-02 by local test-merge.
# `PUT /merge_requests/:iid/rebase` forces a recompute; `checking` means "ask
# again", not "no".
#
# AND THE COROLLARY THAT COST A NIGHT (report §11.11): a rebase pushes a new
# head, which starts a fresh pipeline and CANCELS the running one. A loop that
# re-requests a rebase every round therefore destroys the very work whose
# completion is its exit condition — ten cancelled pipelines on one MR, and from
# the log it looks like healthy activity. So: AT MOST ONE REBASE PER MR PER RUN.
#
#     a retry is only safe if retrying does not destroy the progress made
#     since the last attempt.
#
# EXIT
#   0 merged  ·  1 refused (held / not approved)  ·  2 genuine conflict
#   3 not ready (CI running, or still checking after the poke)
#   4 cannot verify
################################################################################
cmd_merge(){
  _need_yq
  local iid="" dry=false poke=true wait_s=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)   dry=true; shift ;;
      --no-rebase) poke=false; shift ;;
      --wait)      wait_s="${2:-0}"; shift 2 ;;
      --wait=*)    wait_s="${1#*=}"; shift ;;
      -h|--help)
        cat <<'EOF'
usage: pl mr merge <iid> [--dry-run] [--no-rebase] [--wait=SECONDS]

  Refuses a HELD MR. Never believes `conflict` without one recompute
  (PUT /rebase, at most once). Treats `checking` as retry, not failure.

  On ci_must_pass it re-runs `security:mr-hold` ONCE, and only when that is
  the only red job and the hold is already lifted for this head — the D13
  gate runs on push, so it is red by design until `pl mr release` exists.
  Any other red job stays a refusal, and --dry-run re-runs nothing.

  exit 0 merged · 1 refused · 2 conflict · 3 not ready · 4 cannot verify
EOF
        return 0 ;;
      -*) die "unknown option: $1 (try: pl mr merge --help)" ;;
      *)  [ -z "$iid" ] && { iid="$1"; shift; } || die "unexpected arg: $1" ;;
    esac
  done
  [[ "$iid" =~ ^[0-9]+$ ]] || die "usage: pl mr merge <iid>"
  [[ "$wait_s" =~ ^[0-9]+$ ]] || die "--wait wants seconds"
  _mr_have_token || die "no usable token (NWP_MR_TOKEN or .secrets.yml:gitlab.api_token)"
  local proj; proj=$(_mr_project) || die "cannot resolve the project"

  local json dms state rebased=false hold_rerun=false deadline rounds=0
  deadline=$(( $(date +%s) + wait_s ))

  # A HARD ROUND CAP, independent of --wait. Found by mutation-testing this very
  # function: removing the once-only rebase flag turned the loop into a
  # non-terminating one (the `conflict` branch `continue`s BEFORE the deadline
  # test, so the wall-clock bound never applies to it). The flag is the correct
  # fix and remains; this is the belt that means no future edit to the case
  # arms can wedge a merge command forever.
  local max_rounds=$(( 6 + wait_s / 10 ))

  while :; do
    rounds=$((rounds + 1))
    if [ "$rounds" -gt "$max_rounds" ]; then
      print_warning "!$iid: giving up after $max_rounds rounds (last status: ${dms:-?})"
      return 3
    fi
    json=$(_mr_fetch "$iid") || { print_error "cannot read !$iid (HTTP $(_mr_http_status))"; return 4; }
    state=$(_mr_state "$json"); dms=$(_mr_detailed_merge_status "$json")

    [ "$state" = "opened" ] || { print_error "!$iid is $state, not open"; return 1; }

    # THE HOLD IS CHECKED FIRST, and against the forge's own view. A held MR is
    # not a "not ready yet" to be waited out; it is a refusal.
    # A MACHINE NEVER MERGES. Checked before anything else, and in BOTH review
    # modes. Solo mode drops the Draft hold, so this becomes the thing standing
    # between an armed automation and a merged MR — which is exactly what went
    # wrong on 2026-08-01. Keyed on the token's forge-verified identity, not on a
    # name in a config or a handle somebody typed.
    local _actor_rc=0
    _mr_merge_actor_ok || _actor_rc=$?
    case "$_actor_rc" in
      1) print_error "REFUSING: this token is a BOT (@$(_mr_token_user 2>/dev/null)). A machine never merges."
         print_info  "A human merges, on the MR page. In solo review mode that click IS the approval."
         print_info  "  $(_mr_web_url "$iid")"
         return 1 ;;
      2) print_error "REFUSING: could not establish this token's forge identity (GET /user)."
         print_info  "\"I could not tell whether I am a bot\" is not \"I am a human\". Merge by hand:"
         print_info  "  $(_mr_web_url "$iid")"
         return 1 ;;
    esac
    if _mr_is_draft "$json"; then
      print_error "!$iid is HELD (draft) — refusing. pl mr status $iid"
      return 1
    fi
    local grc=0; cmd_guard "$iid" >/dev/null 2>&1 || grc=$?
    if [ "$grc" -ne 0 ]; then
      print_error "!$iid does not pass the sensitive-path gate (pl mr guard exit $grc) — refusing"
      print_hint "pl mr status $iid"
      return 1
    fi

    case "$dms" in
      mergeable)
        break ;;
      checking|unchecked|preparing)
        # NOT a failure. The forge has not finished thinking.
        ;;
      conflict)
        if [ "$poke" = true ] && [ "$rebased" = false ]; then
          print_info "!$iid reports 'conflict' — forcing ONE recompute (PUT /rebase) before believing it"
          _mr_api PUT "/projects/$proj/merge_requests/$iid/rebase" >/dev/null 2>&1 || true
          rebased=true
          sleep 5
          continue
        fi
        print_error "!$iid: conflict, confirmed after a recompute"
        return 2 ;;
      ci_still_running)
        print_warning "!$iid: pipeline still running"
        [ "$wait_s" -eq 0 ] && return 3 ;;
      draft_status)
        print_error "!$iid is HELD (draft_status) — refusing"; return 1 ;;
      ci_must_pass)
        # THE D13 HOLD IS RED BY DESIGN ON ITS FIRST RUN, AND ONLY IT MAY BE
        # RE-RUN HERE.
        #
        # `security:mr-hold` executes on push. The release it demands cannot
        # exist yet at that moment — `pl mr release` binds to the head commit,
        # so it is necessarily issued AFTER the pipeline starts. Every
        # sensitive-path MR therefore ends up released, un-held, and unmergeable
        # behind a job that failed for a reason that no longer holds. Observed
        # on !317: released and bound to the head, hold cleared, `pl mr merge`
        # refusing on ci_must_pass with `security:mr-hold` the only red job.
        #
        # Re-running it by hand is exactly the "step around the verb" this
        # estate keeps paying for, so the verb does it — under four bounds:
        #   * ONCE (hold_rerun), so a genuinely broken gate cannot be looped on;
        #   * only when EVERY failed job is the hold gate — one other red job
        #     and this stays a refusal, because "retry until green" is not a
        #     merge policy;
        #   * only after the draft check and `pl mr guard` above have already
        #     passed, i.e. the hold really is lifted for THIS head;
        #   * never with --dry-run: a dry run reports, it does not act.
        local failed names
        failed=$(_mr_failed_jobs "$(_mr_head_pipeline_id "$json")" 2>/dev/null)
        names=$(printf '%s\n' "$failed" | awk -F'\t' 'NF{print $2}' | sort -u)
        if [ "$hold_rerun" = false ] && [ "$dry" = false ] \
           && [ -n "$names" ] && [ "$names" = "security:mr-hold" ]; then
          print_info "!$iid: the only red job is security:mr-hold, and the hold is lifted for this head — re-running it once"
          printf '%s\n' "$failed" | awk -F'\t' 'NF{print $1}' | while read -r jid; do
            _mr_retry_job "$jid" || print_warning "could not retry job $jid"
          done
          hold_rerun=true
          sleep 10
          continue
        fi
        print_error "!$iid: not mergeable — detailed_merge_status=ci_must_pass"
        [ -n "$names" ] && print_info "failed job(s): $(printf '%s' "$names" | tr '\n' ' ')"
        return 1 ;;
      *)
        print_error "!$iid: not mergeable — detailed_merge_status=${dms:-unknown}"
        return 1 ;;
    esac

    [ "$(date +%s)" -lt "$deadline" ] || { print_warning "!$iid still ${dms:-?} after ${wait_s}s"; return 3; }
    sleep 10
  done

  if [ "$dry" = true ]; then
    print_success "DRY RUN: !$iid is mergeable and passes every gate — nothing was merged"
    return 0
  fi
  local resp; resp=$(_mr_api PUT "/projects/$proj/merge_requests/$iid/merge" '{"should_remove_source_branch":true}') \
    || { print_error "merge failed (HTTP $(_mr_http_status)): $(printf '%s' "$resp" | _mr_jget message)"; return 1; }
  print_success "!$iid merged"
  return 0
}

################################################################################
# pl mr guard [<iid>] [--apply] — the permanent, unremembering half of D13.
#
# An MR touching a CLAUDE.md sensitive path is HELD AUTOMATICALLY. Not
# labelled, not warned about, not "flagged for review" — held. Nobody has to
# remember, which is the entire point: the 2026-08-01 hold was remembered, was
# written down, and still lost.
#
# EXIT
#   0 — no sensitive path, or a valid release record for the current head
#   1 — held (or should be held): sensitive path with no valid release
#   2 — CANNOT VERIFY (no diff, unreadable CLAUDE.md). Fail closed.
################################################################################
# _mr_hold_unverifiable <iid> <apply> — hold an MR whose sensitivity could not be
# determined. Fail-closed's action half: saying "treat it as held" and holding
# nothing is not failing closed, it is failing open with a warning.
_mr_hold_unverifiable(){
  local iid="$1" apply="$2"
  if [ "$apply" != true ]; then
    echo "       (read-only: re-run with --apply to hold it, or hold it by hand)"
    return 0
  fi
  if [ -z "$iid" ] || ! _mr_have_token; then
    echo "NOT ENFORCED AS DRAFT: no MR-capable token here, so the hold could not be"
    echo "  applied. Nothing is holding this MR except this command's exit code."
    return 0
  fi
  # Same host check the sensitive-path hold does. Without it this would dial the
  # placeholder domain, take an HTTP 000, and report HOLD-MECHANISM-FAILED — true,
  # but blaming the mechanism for what is really "I do not know the address".
  if ! _mr_host_ok; then
    echo "NOT ENFORCED AS DRAFT: the forge host could not be determined (no"
    echo "  NWP_GITLAB_HOST, no CI_SERVER_HOST, no .secrets.yml), so no hold could"
    echo "  be applied. Nothing is holding this MR except this command's exit code."
    return 0
  fi
  echo ""
  if _mr_apply_hold "$iid" \
       "the sensitive-path gate could not determine what this MR changes, so it is held until someone can" \
       "$MR_HOLD_LABEL_MANUAL" ""; then
    local vjson
    if vjson=$(_mr_fetch "$iid") && _mr_is_draft "$vjson"; then
      echo "HELD: !$iid set to Draft because its sensitivity could NOT be verified."
      echo "  This is the gate failing closed. Re-run \`pl mr guard $iid\` once the"
      echo "  diff is readable; if it is clean, release it the ordinary way."
    else
      echo "HOLD-MECHANISM-FAILED: the Draft hold could not be CONFIRMED on !$iid,"
      echo "  and its sensitivity is ALSO unverified. Nothing is holding this MR."
      echo "  Do not merge it on the strength of a red pipeline alone."
    fi
  else
    echo "HOLD-MECHANISM-FAILED: could not apply the Draft hold (HTTP $(_mr_http_status)),"
    echo "  and the change set was unreadable too. Nothing is holding this MR."
    echo "  Fix the mechanism before merging — both layers are absent, not one."
  fi
}

################################################################################
# pl mr review-mode [sync] — report the estate's review policy, and regenerate the
# CI-readable projection of it.
#
# THERE IS DELIBERATELY NO `set` SUBCOMMAND. The mode is not a switch somebody
# flips; it is derived from `approvers:` in private/secrets-registry.yml. Adding the
# second name is the entire shift — simultaneously the operator approving it and
# the second human dev existing, which are the two conditions of the 2026-08-06
# ruling. A `set` verb would be a way to be in team mode with nobody to be the
# second reviewer, or in solo mode with two devs, and both are incoherent.
#
# `sync` only copies the derived value into .nwp-review-mode so CI can read it. It
# cannot change the answer.
################################################################################
cmd_review_mode(){
  local sub="${1:-show}"
  case "$sub" in
    show|"") ;;
    sync) ;;
    -h|--help) printf 'usage: pl mr review-mode [sync]\n'; return 0 ;;
    set) die "there is no 'set' — the mode is DERIVED from approvers: in
  private/secrets-registry.yml. Add or remove a name there and the mode follows;
  then run \`pl mr review-mode sync\` and commit .nwp-review-mode so CI agrees.
  A settable mode would let team mode exist with nobody to be the second pair of
  eyes, which is not a policy, it is a gap." ;;
    *) die "unknown: pl mr review-mode $sub (try: show | sync)" ;;
  esac

  local mode src proj file reg n
  mode=$(_mr_review_mode); src=$(_mr_review_mode_source)
  file=$(_mr_review_mode_file); reg=$(_mr_approver_registry)
  proj=$(_mr_review_mode_raw); [ -n "$proj" ] || proj="(none)"
  n=$(_mr_approver_count) || n="unreadable"

  if [ "$sub" = sync ]; then
    [ "$n" != unreadable ] || die "cannot read $reg — nothing to project.
  Run this where the registry is readable (it lives in the private repo);
  a CI job cannot, which is the reason the projection exists."
    local want; [ "$n" -eq 1 ] && want=solo || want=team
    if [ "$proj" = "$want" ]; then
      print_info "already in sync: $want ($n approver(s))"
      return 0
    fi
    local tmp; tmp=$(mktemp)
    if [ -r "$file" ]; then
      # Rewrite ONLY the value line — the file is mostly rationale and it must survive.
      awk -v want="$want" 'BEGIN{done=0}
        /^[[:space:]]*(#|$)/ { print; next }
        { if (!done) { print want; done=1 } else { print } }
        END { if (!done) print want }' "$file" > "$tmp"
    else
      printf '%s\n' "$want" > "$tmp"
    fi
    mv "$tmp" "$file"
    print_success "projection updated: ${proj} -> ${want}  (${n} approver(s) declared)"
    print_info "COMMIT ${file#$PROJECT_ROOT/} — CI reads it from the branch under test,"
    print_info "so an uncommitted change applies to your shell and not to the pipeline."
    return 0
  fi

  print_header "review mode: $mode"
  case "$src" in
    registry)   printf '  %-14s %s\n' "from:" "approvers: in ${reg/#$HOME/~} ($n declared)" ;;
    projection) printf '  %-14s %s\n' "from:" "${file#$PROJECT_ROOT/} — the registry was not readable here"
                print_info "(expected in CI: private/ is a separate repo)" ;;
    env)        printf '  %-14s %s\n' "from:" "NWP_REVIEW_MODE — an explicit override" ;;
    fallback)   print_warning "NOT DECLARED — no registry, no projection. This is the"
                print_warning "FAIL-CLOSED default, not a decision anyone made." ;;
  esac
  printf '  %-14s %s\n' "projection:" "$proj"
  echo
  if [ "$mode" = solo ]; then
    print_info "ONE reviewer. You approve by clicking Merge on the MR page — that click IS"
    print_info "the approval. \`pl mr release\` is not needed, and \`--merge\` is refused,"
    print_info "because a shell would be a second approval spot."
    print_info "Sensitive-path MRs are REPORTED (here and as a note on the MR), not held."
  else
    print_info "TWO reviewers. A sensitive-path MR is held as Draft until somebody who is"
    print_info "NOT its author records a release bound to the head commit:"
    print_info "  pl mr release <iid> --approved-by=<handle> --reason='...'"
  fi
  echo
  print_info "In BOTH modes: a machine never merges. Auto-merge is disarmed and every merge"
  print_info "verb refuses a bot token. Solo removes the SECOND human, not the human."
  echo
  if ! _mr_review_mode_drift; then
    print_error "DRIFT: the registry says $([ "$n" -eq 1 ] 2>/dev/null && echo solo || echo team) but the projection says $proj."
    print_error "CI reads the projection, so CI is enforcing the wrong policy right now."
    print_info  "  pl mr review-mode sync   # then commit ${file#$PROJECT_ROOT/}"
    return 1
  fi
  print_hint "To move to two-person review: add the second name to approvers: in"
  print_hint "${reg/#$HOME/~}, then \`pl mr review-mode sync\` and commit."
  return 0
}

cmd_guard(){
  local iid="${CI_MERGE_REQUEST_IID:-}" apply=false base="" head_ref="HEAD" ci=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply)  apply=true; shift ;;
      --ci)     ci=true; apply=true; shift ;;
      --base=*) base="${1#*=}"; shift ;;
      --head=*) head_ref="${1#*=}"; shift ;;
      -h|--help) printf 'usage: pl mr guard [<iid>] [--apply] [--base=<ref>] [--head=<ref>]\n'; return 0 ;;
      -*) echo "unknown option: $1" >&2; return 2 ;;
      *) iid="$1"; shift ;;
    esac
  done

  echo "=== sensitive-path hold gate ==="

  # 1. WHAT CHANGED. Prefer the git range (works with no credentials at all);
  #    fall back to the API when we only have an iid.
  local files="" source=""
  if [ -z "$base" ]; then
    base="${CI_MERGE_REQUEST_DIFF_BASE_SHA:-}"
    if [ -z "$base" ] && [ -n "${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-}" ]; then
      git fetch -q origin "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME" 2>/dev/null || true
      base="origin/${CI_MERGE_REQUEST_TARGET_BRANCH_NAME}"
    fi
  fi
  if [ -n "$base" ] && git rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
    files=$(git diff --name-only "${base}...${head_ref}" 2>/dev/null)
    source="git ${base}...${head_ref}"
  fi
  # AN EMPTY RANGE IS NOT "NOTHING SENSITIVE".
  #
  # The git range is preferred because it needs no credentials, but it is
  # computed against whatever refs this checkout happens to have. A shallow
  # clone, a stale `origin/main`, or a HEAD that IS the target all produce an
  # empty list — and the gate then printed "files changed: 0 / OK — nothing to
  # hold" and exited 0. For a real merge request that is a vacuous pass: a merge
  # request with no changed files is not a thing.
  #
  # So when the range comes back empty and there IS an MR to ask about, ask.
  local read_failed=false
  if [ -z "$files" ] && [ -n "$iid" ] && _mr_have_token; then
    source="GitLab !$iid"
    files=$(_mr_changed_files "$iid") || { files=""; read_failed=true; }
    # "NOT YET" IS NOT "CANNOT". GitLab prepares diffs asynchronously; for the
    # first seconds after creation it reports detailed_merge_status=preparing,
    # diff_refs null and an empty changeset. `pl mr create` runs this gate the
    # instant after the POST, so a single read made CANNOT VERIFY the NORMAL
    # outcome of creating an MR (measured on !368: empty at creation, three files
    # moments later, correct verdict from an unchanged gate — ops#293). So when
    # the answer is empty, wait for the diff to be ready and ask once more.
    if [ -z "$files" ] && [ "$read_failed" = false ]; then
      echo "changeset empty on first read — waiting for GitLab to finish preparing the diff…"
      if _mr_diff_ready "$iid"; then
        files=$(_mr_changed_files "$iid") || { files=""; read_failed=true; }
      fi
    fi
  fi
  if [ -z "$files" ]; then
    if [ -n "$iid" ]; then
      echo "ERROR: the change set for !$iid came back EMPTY (tried: ${source:-no usable source})."
      echo "       A merge request with no changed files is not a thing, so this is"
      echo "       'could not look', NOT 'nothing sensitive'. Failing closed."
      if [ "$read_failed" = true ]; then
        echo "       The diff pages could not be READ (parse or transport failure) —"
        echo "       distinct from an empty answer, and never treated as one."
      else
        echo "       Usual causes: GitLab has not finished preparing the diff (it is"
        echo "       still 'preparing' after the wait — retry in a moment), a shallow"
        echo "       clone, a stale origin/${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-main}, or a HEAD identical to the target."
      fi
      # FAIL CLOSED FOR REAL. This used to `return 2` here and leave the MR
      # untouched, while cmd_create printed "treat it as held" — an instruction to
      # a human in place of the action the verb could take itself. Measured on
      # !368: 'CANNOT BE VERIFIED; treat it as held' with draft:False, labels:[],
      # i.e. fully mergeable, with nothing on the forge recording that anything
      # was unverified. An MR whose sensitivity cannot be established is PRECISELY
      # the case a hold exists for (ops#293).
      _mr_hold_unverifiable "$iid" "$apply"
      return 2
    fi
    if [ -n "$base" ] && git rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
      # No MR context and a genuinely empty range: there is nothing to review,
      # and saying so is honest rather than vacuous.
      echo "diff source: $source"
      echo "files changed: 0 — this ref is identical to $base; nothing to review."
      return 0
    fi
    echo "ERROR: cannot determine what this change touches (no usable base ref, no MR iid + token)."
    echo "       Failing closed rather than reporting a vacuous pass."
    return 2
  fi
  echo "diff source: $source"
  echo "files changed: $(printf '%s\n' "$files" | grep -c .)"

  # 2. WHICH OF THEM ARE SENSITIVE. An unreadable CLAUDE.md is exit 2, never 0.
  local sens grc=0
  sens=$(printf '%s\n' "$files" | nwp_sensitive_filter) || grc=$?
  if [ "$grc" -ne 0 ]; then
    echo "ERROR: could not read CLAUDE.md's 'Sensitive File Paths' list — cannot verify. Failing closed."
    return 2
  fi
  # 2b. A STANDING MANUAL HOLD also binds here.
  #
  # Without this, `pl mr hold` would be a one-shot: anyone (or any agent) could
  # click "Mark as ready" and the hold would be gone with nothing to restore it.
  # The hold:: label is the record of intent; this is what re-applies the lock
  # on the next pipeline. It is why a manual hold survives being un-drafted.
  local manual_hold=false mr_json="" why="" hold_label="$MR_HOLD_LABEL_SENSITIVE"
  if [ -n "$iid" ] && _mr_have_token; then
    mr_json=$(_mr_fetch "$iid") || mr_json=""
    if [ -n "$mr_json" ] && _mr_has_hold_label "$mr_json"; then
      manual_hold=true
    fi
  fi

  if [ -z "$sens" ] && [ "$manual_hold" = false ]; then
    echo "OK — no CLAUDE.md sensitive path touched, no standing hold. Nothing to hold."
    return 0
  fi

  echo ""
  if [ -n "$sens" ]; then
    echo "Sensitive paths touched ($(printf '%s\n' "$sens" | grep -c .)) — two-person approval class:"
    printf '  %s\n' $sens
    why="touches a CLAUDE.md sensitive path (two-person approval class) with no release record for this head"
  else
    echo "No sensitive path — but a hold:: label is present: this MR is under a STANDING hold."
    why="a standing hold:: label is set on this MR and no release record exists for this head"
    hold_label="$MR_HOLD_LABEL_MANUAL"
  fi

  # 2b. SOLO REVIEW MODE — one reviewer, one approval, at the MR page.
  #
  # Operator ruling 2026-08-06: "We don't need the extra overhead of two checks
  # for now... I should be able to approve/merge once and only in one spot which
  # is the MR location."
  #
  # So in solo mode this job does NOT hold. Holding would set the MR to Draft,
  # and the operator would then have to un-draft AND merge — two actions in two
  # places, which is the friction being removed. The job still REPORTS which
  # CLAUDE.md paths are touched, both here and as a note ON THE MR, because "the
  # one spot" has to be where the information is.
  #
  # WHAT IS KEPT, and it is the part that actually fixed 2026-08-01: auto-merge is
  # disarmed, so nothing self-merges. The incident was a sweeper merging an MR no
  # person had approved. Solo mode removes the SECOND human, never the human —
  # `pl mr merge` and `pl mr release --merge` both refuse a bot caller in either
  # mode (_mr_merge_actor_ok).
  #
  # Placed BEFORE the release-record machinery on purpose: in solo mode there is
  # no release record to look for, so asking for one would fail closed for a
  # reason that no longer applies.
  if [ "$(_mr_review_mode)" = solo ]; then
    echo ""
    echo "SOLO REVIEW MODE — one reviewer. NOT held."
    echo "  The paths above are CLAUDE.md's two-person class, and you are being told"
    echo "  so you can decide. Clicking Merge on the MR page IS the approval; there"
    echo "  is no release step to run first."
    if [ "$apply" = true ] && [ -n "$iid" ] && _mr_have_token && _mr_host_ok; then
      _mr_disarm_automerge "$iid"
      echo "  auto-merge disarmed — nothing will merge this without you clicking it."
      local sbody
      sbody="$MR_SOLO_MARKER
**Sensitive paths touched** — CLAUDE.md lists these as the two-person approval
class. This estate is in **solo review mode** (\`.nwp-review-mode\`), so this MR
is **not held**: your Merge click here is the approval, and there is no
\`pl mr release\` step to run first.

$(printf '%s\n' "$sens" | sed 's/^/  - /')

Auto-merge has been disarmed, so nothing merges this without you. To arm
two-person review later — when there is a second human dev — run
\`pl mr review-mode set team --reason='...'\`; this MR would then be held as Draft
until somebody other than its author released it."
      _mr_note_once "$iid" "$MR_SOLO_MARKER" "$sbody" \
        && echo "  the paths are recorded as a note on the MR (posted once)." \
        || echo "  NOTE-FAILED: could not post the note; the paths are only in this log."
    elif [ "$apply" = true ]; then
      echo "  (no token/host here, so auto-merge could NOT be disarmed and no note"
      echo "   was posted — this log is the only record)"
    fi
    echo ""
    echo "  pl mr review-mode      # what this means, and how to arm two-person review"
    return 0
  fi

  # 3. IS IT RELEASED? Only a record bound to the CURRENT head counts.
  #
  # If the release check CANNOT RUN — no token, or the notes API errors — this
  # is "cannot verify" (exit 2), NOT "held because unreleased" (exit 1). Both
  # refuse, so the safety is identical; the difference is what the operator is
  # told to do next. Reporting "no release record" to someone who has already
  # released it sends them to re-run a command that cannot work, which is
  # exactly what happened on !314 on 2026-08-02.
  _mr_require_yq || return 2
  if [ -n "$iid" ] && ! _mr_host_ok; then
    echo ""
    echo "CANNOT VERIFY — the forge host could not be determined (no"
    echo "  NWP_GITLAB_HOST, no CI_SERVER_HOST, no .secrets.yml). Every API call"
    echo "  would dial a placeholder and return HTTP 000, which is a network"
    echo "  failure, not a policy decision. Refusing (fail closed)."
    return 2
  fi
  if [ -n "$iid" ] && ! _mr_have_token; then
    echo ""
    echo "CANNOT VERIFY — no MR-capable token in this environment, so this job"
    echo "  could not check whether a release record exists for this head."
    echo "  Refusing (fail closed), but note this is 'could not look', NOT"
    echo "  'no release exists'. Running \`pl mr release\` again will not clear it."
    echo ""
    echo "  To make this checkable, set the masked CI variable NWP_MR_TOKEN"
    echo "  (Settings > CI/CD > Variables; needs api scope on this project)."
    echo "  Until then EVERY sensitive-path MR is unmergeable, by design."
    return 2
  fi
  if [ -n "$iid" ] && _mr_have_token; then
    local sha author approver
    [ -n "$mr_json" ] || mr_json=$(_mr_fetch "$iid") || mr_json=""
    if [ -n "$mr_json" ]; then
      sha=$(_mr_head_sha "$mr_json"); author=$(_mr_author "$mr_json")
      local rr_rc=0
      approver=$(_mr_release_record "$iid" "$sha" "$author") || rr_rc=$?
      if [ "$rr_rc" -eq 0 ]; then
        echo ""
        echo "RELEASED by @$approver for head ${sha:0:12} — allowing."
        return 0
      elif [ "$rr_rc" -eq 2 ]; then
        echo ""
        echo "CANNOT VERIFY — the notes API could not be read (HTTP $(_mr_http_status)),"
        echo "  so the release record could not be checked. Refusing (fail closed)."
        echo "  This is 'could not look', not 'no release exists'."
        case "$(_mr_http_status)" in
          401) echo "  401 = the token was rejected. Check the NWP_MR_TOKEN value was"
               echo "        pasted whole, and that it has not expired or been revoked." ;;
          403) echo "  403 = the token is valid but lacks rights on this project."
               echo "        The gate needs 'api' scope at Developer or above." ;;
          404) echo "  404 = project or MR not visible to this token." ;;
          000) echo "  000 = no connection at all (DNS/TLS), not an auth problem." ;;
        esac
        return 2
      fi
    fi
  fi

  # 4. HOLD.
  echo ""
  if [ "$apply" = true ] && [ -n "$iid" ] && _mr_have_token; then
    if _mr_apply_hold "$iid" "$why" "$hold_label" "$sens"; then
      local vjson
      if vjson=$(_mr_fetch "$iid") && _mr_is_draft "$vjson"; then
        echo "HELD: !$iid set to Draft. GitLab will refuse a merge (405) even with auto-merge armed."
      else
        echo "HOLD-MECHANISM-FAILED: the Draft hold could not be CONFIRMED on !$iid."
        echo "  Layer 1 is NOT in force. This job's failure is the only hold, and the"
        echo "  module docblock is explicit that a red pipeline is the weaker layer:"
        echo "  it is indistinguishable from a broken build and one allow_failure ends it."
      fi
    else
      # NOT a warning. ops#281: for months this printed a WARNING while layer 1
      # silently never applied — $YQ is empty on the runner, so the payload was
      # empty and every PUT was a 400. A soft word for a failed security control
      # is how it stays failed; the reader skims "WARNING" and sees the job go red
      # for what looks like the intended reason.
      echo "HOLD-MECHANISM-FAILED: could not apply the Draft hold (HTTP $(_mr_http_status))."
      echo "  Layer 1 (forge-enforced Draft) is NOT in force. Only this job's failure"
      echo "  is holding the MR, which is the layer that survives neither an"
      echo "  allow_failure: true nor a habit of retrying until green."
      echo "  Fix the mechanism — do not merge on the strength of the red pipeline alone."
    fi
  elif [ "$apply" = true ]; then
    # The credential-free path. Say exactly what protection remains.
    echo "NOT ENFORCED AS DRAFT: no MR-capable token in this environment."
    echo "  The hold in force is this job's FAILURE: merge_when_pipeline_succeeds"
    echo "  cannot fire on a red pipeline. To get the stronger, forge-enforced"
    echo "  Draft hold as well, set the masked CI variable NWP_MR_TOKEN."
  else
    echo "(dry run — pass --apply to set the Draft hold)"
  fi

  cat <<EOF

This merge request is HELD ($why).
Release it deliberately, naming the second pair of eyes:

    pl mr release ${iid:-<iid>} --approved-by=<handle> --reason='...'

The release is bound to the current head commit: push again and it re-holds.
EOF
  return 1
}

main(){
  local sub="${1:-list}"; shift || true
  case "$sub" in
    create|new)  cmd_create "$@" ;;
    merge)       cmd_merge "$@" ;;
    status|show) cmd_status "$@" ;;
    ci)          cmd_ci "$@" ;;
    rebase)      cmd_rebase "$@" ;;
    note|comment) cmd_note "$@" ;;
    list|ls)     cmd_list "$@" ;;
    hold)        cmd_hold "$@" ;;
    release)     cmd_release "$@" ;;
    guard|gate)  cmd_guard "$@" ;;
    -h|--help|help)
      cat <<EOF
pl mr — create, merge, hold, release and guard merge requests

  pl mr create [--source=BRANCH] [--target=main] [--title=..]
               [--desc=.. | --desc-file=FILE | -] [--closes=N]
               [--draft] [--keep-branch] [--dry-run]
                                   open an MR for the current branch. Title and
                                   description default to the HEAD commit's
                                   subject and body. Refuses a duplicate — both
                                   for this branch AND for an issue another open
                                   MR already claims to close. The sensitive-path
                                   guard runs on it IMMEDIATELY, so nobody has to
                                   remember to run it (ops#216)
  pl mr merge <iid> [--dry-run] [--no-rebase] [--wait=SECS]
                                   merge. Refuses a HELD MR and an MR that fails
                                   the sensitive-path gate. Never believes
                                   'conflict' without ONE recompute (this
                                   instance's merge status goes stale); treats
                                   'checking' as retry. At most one rebase per
                                   run — a rebase cancels the pipeline it is
                                   waiting for.
                                   0 merged · 1 refused · 2 conflict · 3 not
                                   ready · 4 cannot verify
  pl mr ci <iid> | --pipeline=<id> [--log=N|--no-log]
                                   WHY is it red: the pipeline, every job, and
                                   the tail of each FAILED job's log. Takes a
                                   bare pipeline NUMBER — which is how a failure
                                   gets reported — and names the MR it belongs
                                   to. Never retries anything: a retry that goes
                                   green is not a diagnosis.
                                   0 success · 1 failed · 2 cannot verify ·
                                   3 not finished
  pl mr rebase <iid> [--wait=SECS] [--dry-run]
                                   move it onto the tip of its target branch —
                                   what unsticks an MR whose red pipeline is a
                                   COMPLETED run on a stale head. Never believes
                                   'conflict' on its own (this instance's merge
                                   status is a cached value that goes stale); a
                                   conflict is reported only once a real local
                                   test-merge REPRODUCES it. Says that the old
                                   pipeline is cancelled and names the NEW one.
                                   0 rebased · 1 reproduced conflict · 2 cannot
                                   verify · 3 still rebasing
  pl mr note <iid> "text"          leave a comment on the MR. Body from stdin
       (or pipe the body on stdin) when no argument is given, the same idiom as
                                   `pl issue comment` — piped text is never
                                   silently discarded.
                                   0 posted · 1 refused · 2 cannot verify
  pl mr list                       every open MR: held? auto-merge armed?
  pl mr status <iid>               hold state, GitLab's own merge status,
                                   sensitive paths, release record
  pl mr hold <iid> --reason="..."  HOLD it: sets Draft (GitLab then refuses a
                                   merge with 405 even if auto-merge is armed),
                                   disarms auto-merge, labels it, explains it
  pl mr release <iid> --approved-by=<handle> [--reason="..."]
                                   lift the hold, on the record. The approver
                                   may not be the author and may not be a bot;
                                   the release is bound to the head commit, so
                                   pushing again re-holds automatically
  pl mr guard [<iid>] [--apply]    the sensitive-path gate. An MR touching a
                                   CLAUDE.md sensitive path is held
                                   AUTOMATICALLY — nobody has to remember.
                                   Runs in CI as security:mr-hold.

Exit codes for guard:  0 clear/released · 1 held · 2 cannot verify (fail closed)
EOF
      ;;
    # NO `shift` here: main() already shifted the subcommand off. The other arms
    # do not shift either, and adding one ate `set` so that `review-mode set team`
    # arrived as `review-mode team`.
    review-mode) cmd_review_mode "$@" ;;
    *) die "unknown subcommand: $sub (try: pl mr --help)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
