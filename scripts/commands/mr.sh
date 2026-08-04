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
    2) print_warning "!$iid — sensitive-path status CANNOT BE VERIFIED; treat it as held." ;;
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
  local iid="" approver="" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --approved-by)   approver="${2:-}"; shift 2 ;;
      --approved-by=*) approver="${1#*=}"; shift ;;
      --reason)        reason="${2:-}"; shift 2 ;;
      --reason=*)      reason="${1#*=}"; shift ;;
      -h|--help) printf 'usage: pl mr release <iid> --approved-by=<handle> [--reason="..."]\n'; return 0 ;;
      -*) die "unknown option: $1 (usage: pl mr release <iid> --approved-by=<handle>)" ;;
      *) [ -z "$iid" ] && { iid="$1"; shift; } || die "unexpected arg: $1" ;;
    esac
  done
  [[ "$iid" =~ ^[0-9]+$ ]] || die "usage: pl mr release <iid> --approved-by=<handle> [--reason=\"...\"]"
  approver="${approver#@}"
  [ -n "$approver" ] || die "--approved-by=<handle> is required — a release names the second pair of eyes"

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
  local _appr_file="${NWP_SECRETS_REGISTRY:-$HOME/nwp/private/secrets-registry.yml}"
  local _appr_n=0
  if [ -r "$_appr_file" ] && [ -n "$YQ" ]; then
    _appr_n=$("$YQ" e '.approvers // [] | length' "$_appr_file" 2>/dev/null || echo 0)
    [[ "$_appr_n" =~ ^[0-9]+$ ]] || _appr_n=0
  fi
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

  print_hint "merging is still a human action — this only removed the hold."
  print_hint "Wait for the pipeline to go green, then merge here:"
  print_hint "  $(_mr_web_url "$iid")"
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
  if [ -z "$files" ] && [ -n "$iid" ] && _mr_have_token; then
    files=$(_mr_changed_files "$iid") || files=""
    source="GitLab !$iid"
  fi
  if [ -z "$files" ]; then
    if [ -n "$iid" ]; then
      echo "ERROR: the change set for !$iid came back EMPTY (tried: ${source:-no usable source})."
      echo "       A merge request with no changed files is not a thing, so this is"
      echo "       'could not look', NOT 'nothing sensitive'. Failing closed."
      echo "       Usual causes: a shallow clone, a stale origin/${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-main},"
      echo "       or a HEAD identical to the target."
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
    *) die "unknown subcommand: $sub (try: pl mr --help)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
