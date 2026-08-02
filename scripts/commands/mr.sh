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

_mr_web_url(){ printf 'https://%s/nwp/nwp/-/merge_requests/%s\n' "$(_mr_host)" "$1"; }

################################################################################
# pl mr status <iid> — read-only. Says what the FORGE thinks, not what we hope.
################################################################################
cmd_status(){
  _need_yq
  local iid="${1:-}"; [[ "$iid" =~ ^[0-9]+$ ]] || die "usage: pl mr status <iid>"
  _mr_have_token || die "no usable token (NWP_MR_TOKEN or .secrets.yml:gitlab.api_token)"
  local json; json=$(_mr_fetch "$iid") \
    || die "cannot read MR !$iid (HTTP $(_mr_http_status)) — token rejected, wrong project, or host unreachable"

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

  local json; json=$(_mr_fetch "$iid") || die "cannot read MR !$iid (HTTP $(_mr_http_status))"
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
  _mr_have_token || die "no usable token (NWP_MR_TOKEN or .secrets.yml:gitlab.api_token)"

  local json; json=$(_mr_fetch "$iid") || die "cannot read MR !$iid (HTTP $(_mr_http_status))"
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
  local np; np=$(B="$body" "$YQ" -n -o=json '{"body": strenv(B)}')
  _mr_api POST "/projects/$proj/merge_requests/$iid/notes" "$np" >/dev/null \
    || die "could not record the release (HTTP $(_mr_http_status)) — nothing was lifted"

  _mr_lift_hold "$iid" || die "release recorded but the hold could not be lifted (HTTP $(_mr_http_status))"

  json=$(_mr_fetch "$iid") || die "released but could not verify — check by hand: $(_mr_web_url "$iid")"
  if _mr_is_draft "$json"; then
    die "still a draft after release — the title may carry an unusual prefix. $(_mr_web_url "$iid")"
  fi
  print_success "!$iid released by @$approver, bound to head ${sha:0:12}"
  [ -n "$sens" ] && print_info "sensitive paths: $(printf '%s\n' "$sens" | tr '\n' ' ')"
  print_hint "merging is still a human action — this only removed the hold"
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
  elif [ -n "$iid" ] && _mr_have_token; then
    files=$(_mr_changed_files "$iid") || files=""
    source="GitLab !$iid"
    [ -n "$files" ] || { echo "ERROR: could not read the diff for !$iid — failing closed."; return 2; }
  else
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
        echo "WARNING: the hold could not be CONFIRMED on !$iid — this job's failure is the only hold in place."
      fi
    else
      echo "WARNING: could not apply the Draft hold (HTTP $(_mr_http_status))."
      echo "         This job's failure is the only hold in place — auto-merge cannot fire on a red pipeline."
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
    status|show) cmd_status "$@" ;;
    list|ls)     cmd_list "$@" ;;
    hold)        cmd_hold "$@" ;;
    release)     cmd_release "$@" ;;
    guard|gate)  cmd_guard "$@" ;;
    -h|--help|help)
      cat <<EOF
pl mr — hold, release and guard merge requests (a hold the FORGE enforces)

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
