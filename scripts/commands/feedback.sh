#!/bin/bash
set -uo pipefail

################################################################################
# pl feedback — close the tester-feedback loop: file → fix → APPROVE → live → tell them.
#
# THE ASK THIS SERVES (operator, 2026-08-02)
#   "I'd like to be able to approve it in nwpconsole so it auto merges or I have
#    the option to check it first, it's then integrated into the build for the
#    next day so is then live that day. I'd also like it to be visible in a set
#    of links so the person can see if the work has been done to satisfaction
#    and reopen it with a clarification if needed."
#
# WHAT WAS ALREADY BUILT, AND WHAT THIS ADDS
#   Built: the tester's form, the Feedback entity, `/my/feedback` with its
#   "✓ Yes, sorted" / "✗ Not quite" buttons, `nwc-feedback:sync-to-gitlab`
#   (Drupal → GitLab, on a 15-minute cron), the agent loop behind
#   `agent-eligible`, and — on branch feat/mr-hold-gate — `pl mr hold/release`,
#   a hold the FORGE enforces.
#   Missing, and added here:
#     * `sync-status`  — the RETURN leg. `nwc-feedback:sync-status` reads issue
#       and MR state back into the entity and is what makes `/my/feedback` show
#       anything other than "Sent to the team". It was implemented and wired to
#       no scheduler at all. Now it is a verb, so it can be scheduled and so a
#       run that could not happen SAYS SO.
#     * `arm`          — the operator's "have a fix drafted", with the
#       `needs-human` refusal enforced in code rather than in a convention.
#     * `approve`      — the operator's approval, in the operator's two modes,
#       expressed through `pl mr hold` / `pl mr release`.
#     * `status`       — the end-to-end ladder for ONE item, including the rung
#       nobody had: merged-but-not-deployed.
#     * `deploy-check` — the phase guard for the (staged) daily auto-deploy,
#       visible and testable before it ever has anything to gate.
#
# STANDING ORDER COMPLIANCE
#   Every write here goes through an existing verb or the shared GitLab
#   plumbing: `pl mr hold|release` for MR state, lib/gitlab-issues.sh for issue
#   labels and notes, `pl drush` for the Drupal side. Nothing shells to a raw
#   `ssh … drush`, and nothing invents a second approval mechanism beside the
#   forge-enforced Draft hold.
#
# NOTHING SILENT
#   Every subcommand distinguishes three outcomes, never two: it worked, it
#   refused (and why), or IT COULD NOT LOOK (rc 3). A blind check is not a pass.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
NWP_SRC_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$NWP_SRC_ROOT}"

# shellcheck source=/dev/null
source "$NWP_SRC_ROOT/lib/ui.sh"
# shellcheck source=/dev/null
source "$NWP_SRC_ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$NWP_SRC_ROOT/lib/yaml-write.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$NWP_SRC_ROOT/lib/canonical.sh"
# shellcheck source=/dev/null
source "$NWP_SRC_ROOT/lib/feedback-loop.sh"

# The GitLab plumbing. PROJECT_ID is per-call here (feedback issues live on
# nwp/nwc = 16, not on nwp/ops = 21), so it is set before each _api_* call.
YQ="${YQ:-$(command -v yq || true)}"
SECRETS_FILE="${NWP_SECRETS_FILE:-$PROJECT_ROOT/.secrets.yml}"
PROJECT_ID="${FB_DEFAULT_PROJECT_ID}"
# shellcheck source=/dev/null
source "$NWP_SRC_ROOT/lib/gitlab-issues.sh"

RC_OK=0; RC_REFUSED=1; RC_USAGE=2; RC_BLIND=3

die(){ print_error "$*"; exit "$RC_USAGE"; }

show_help() {
    cat << EOF
${BOLD}pl feedback${NC} — close the tester-feedback loop: file → fix → approve → live → tell them

${BOLD}USAGE:${NC}
    pl feedback status <ref> [--site=<s>] [--json]
                              Full end-to-end state of ONE feedback item:
                              issue, labels, MR, hold, and whether the fix is
                              actually ON the site yet.
    pl feedback list [--project=<id>] [--stuck] [--json]
                              Every open feedback issue with its derived rung.
                              --stuck shows only the ones waiting on YOU.
    pl feedback arm <ref> [--yes]
                              Hand the item to the agent loop (adds
                              'agent-eligible'). REFUSES 'needs-human'.
    pl feedback approve <ref> --mode=review|auto [--approved-by=<handle>]
                              Your approval, in your two modes:
                                review  (default) hold the MR — you check first
                                auto              release + merge when CI is green
    pl feedback sync-status <site> [--tier=dev|live] [--dry-run]
                              Run the RETURN leg: pull issue/MR state back into
                              the site so /my/feedback tells the reporter the
                              truth. This is the leg that had no scheduler.
    pl feedback deploy-check [<site>...] [--json]
                              Would the daily auto-deploy be allowed to touch
                              this site? (canonical-phase guard, ops#33.)

${BOLD}REF FORMATS:${NC}
    16#42     project#issue-iid, exactly as nwc_feedback stores it
    #42, 42   bare iid on nwp/nwc (project ${FB_DEFAULT_PROJECT_ID})

${BOLD}EXIT CODES:${NC}
    0 ok · 1 refused (a guard said no) · 2 usage · 3 CANNOT VERIFY (never a pass)

${BOLD}THE REPORTER'S VIEW:${NC}
    https://<community-site>/my/feedback
    …/my/feedback/<id>/confirm      "✓ Yes, sorted"
    …/my/feedback/<id>/follow-up    "✗ Not quite" — reopen with a clarification
EOF
}

################################################################################
# Shared readers. Each one distinguishes "no" from "could not look".
################################################################################

# _fb_issue <pid> <iid> — the issue JSON, or "" with rc 3.
_fb_issue() {
    local pid="$1" iid="$2" out
    PROJECT_ID="$pid"
    out="$(_api_get "/projects/${pid}/issues/${iid}" 2>/dev/null)" || return "$RC_BLIND"
    [ -n "$out" ] || return "$RC_BLIND"
    printf '%s' "$out" | "$YQ" e -p=json '.iid // ""' - >/dev/null 2>&1 || return "$RC_BLIND"
    printf '%s' "$out"
}

# _fb_labels_csv <issue-json>
_fb_labels_csv() {
    printf '%s' "$1" | "$YQ" e -p=json '[.labels[]?] | join(",")' - 2>/dev/null | grep -v '^null$'
}

# _fb_related_mr <pid> <iid> — the FIRST non-closed related MR as JSON, or "".
# Preference order: opened, then merged. A closed MR is not the story.
_fb_related_mr() {
    local pid="$1" iid="$2" out
    out="$(_api_get "/projects/${pid}/issues/${iid}/related_merge_requests" 2>/dev/null)" || return "$RC_BLIND"
    [ -n "$out" ] || { printf ''; return 0; }
    printf '%s' "$out" | "$YQ" e -p=json -o=json \
        '[.[] | select(.state == "opened")] + [.[] | select(.state == "merged")] | .[0] // ""' - 2>/dev/null \
        | grep -v '^""$' | grep -v '^null$'
}

# _fb_mr_field <mr-json> <path>
_fb_mr_field(){ printf '%s' "${1:-}" | "$YQ" e -p=json ".${2} // \"\"" - 2>/dev/null | grep -v '^null$'; }

# _fb_mr_is_draft <mr-json> — GitLab's own boolean, with the title as a fallback
# for older API versions. Same test `pl mr` uses.
_fb_mr_is_draft() {
    local j="${1:-}" d t
    d="$(_fb_mr_field "$j" draft)"
    [ "$d" = "true" ] && { echo yes; return; }
    t="$(_fb_mr_field "$j" title)"
    case "$t" in Draft:*|draft:*|DRAFT:*|WIP:*|wip:*) echo yes ;; *) echo no ;; esac
}

# _fb_epoch <iso8601> — "" when unparseable, never a guessed 0.
_fb_epoch(){ [ -n "${1:-}" ] || { echo ""; return; }; date -u -d "$1" +%s 2>/dev/null || echo ""; }

# _fb_mr_cmd — path to the `pl mr` implementation, or "" if it is not here yet.
# `pl mr hold|release` lands with MR !314 / branch feat/mr-hold-gate. Until that
# merges, `approve` refuses with a message that NAMES the dependency instead of
# reimplementing a second, weaker hold beside it.
_fb_mr_cmd() {
    local p="${NWP_MR_CMD:-$NWP_SRC_ROOT/scripts/commands/mr.sh}"
    [ -x "$p" ] && printf '%s' "$p"
}

################################################################################
# pl feedback status <ref>
################################################################################
cmd_status() {
    local ref="" site="" as_json=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --site=*) site="${1#*=}"; shift ;;
            --site)   site="${2:-}"; shift 2 ;;
            --json)   as_json=true; shift ;;
            -h|--help) show_help; return 0 ;;
            -*) die "unknown option: $1" ;;
            *) [ -z "$ref" ] && { ref="$1"; shift; } || die "unexpected arg: $1" ;;
        esac
    done
    [ -n "$ref" ] || die "usage: pl feedback status <ref> [--site=<s>] [--json]"

    local parsed pid iid
    parsed="$(fb_parse_issue_ref "$ref")" || die "unrecognised ref '$ref' (try 16#42, #42 or 42)"
    read -r pid iid <<<"$parsed"

    _token_present || {
        print_status "FAIL" "CANNOT VERIFY: no GitLab token in $SECRETS_FILE — this is not 'nothing to report'."
        return "$RC_BLIND"
    }

    local issue rc=0
    issue="$(_fb_issue "$pid" "$iid")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        print_status "FAIL" "CANNOT VERIFY: could not read ${pid}#${iid} from GitLab."
        return "$RC_BLIND"
    fi

    local labels issue_state title web_url
    labels="$(_fb_labels_csv "$issue")"
    issue_state="$(printf '%s' "$issue" | _jget state)"
    title="$(printf '%s' "$issue" | _jget title)"
    web_url="$(printf '%s' "$issue" | _jget web_url)"

    local mr mr_state="none" mr_draft="no" mr_url="" merged_at="" mr_iid=""
    mr="$(_fb_related_mr "$pid" "$iid" 2>/dev/null)" || mr=""
    if [ -n "$mr" ]; then
        mr_state="$(_fb_mr_field "$mr" state)"; [ -n "$mr_state" ] || mr_state="none"
        mr_draft="$(_fb_mr_is_draft "$mr")"
        mr_url="$(_fb_mr_field "$mr" web_url)"
        mr_iid="$(_fb_mr_field "$mr" iid)"
        merged_at="$(_fb_mr_field "$mr" merged_at)"
    fi

    # The deploy half. Without a --site we cannot ask "is it on the site?", and
    # we say so rather than leaving the rung looking finished.
    local deploy="unknown" last_epoch="" merged_epoch=""
    if [ -n "$site" ] && [ "$mr_state" = "merged" ]; then
        last_epoch="$(fb_last_deploy_epoch "$site")"
        merged_epoch="$(_fb_epoch "$merged_at")"
        deploy="$(fb_deploy_verdict "$last_epoch" "$merged_epoch")"
    fi

    local rung; rung="$(fb_derive_rung "$issue_state" "$labels" "$mr_state" "$mr_draft" "$deploy" "")"
    local plain; plain="$(fb_plain_rung "$rung")"

    if [ "$as_json" = true ]; then
        REF="${pid}#${iid}" T="$title" S="$issue_state" L="$labels" \
        MS="$mr_state" MD="$mr_draft" MU="$mr_url" MI="$mr_iid" \
        D="$deploy" R="$rung" P="$plain" U="$web_url" SITE="$site" \
        "$YQ" -n -o=json '{
            "ref": strenv(REF), "title": strenv(T), "issue_state": strenv(S),
            "labels": strenv(L), "issue_url": strenv(U), "site": strenv(SITE),
            "mr_state": strenv(MS), "mr_draft": strenv(MD),
            "mr_iid": strenv(MI), "mr_url": strenv(MU),
            "deploy": strenv(D), "rung": strenv(R), "plain": strenv(P)
        }'
        return 0
    fi

    print_header "feedback ${pid}#${iid}"
    echo "  ${BOLD}${title}${NC}"
    echo ""
    printf '  %-16s %s\n' "issue"  "${issue_state} — ${web_url}"
    printf '  %-16s %s\n' "labels" "${labels:-（none)}"
    if [ -n "$mr" ]; then
        printf '  %-16s !%s %s%s\n' "merge request" "$mr_iid" "$mr_state" \
            "$( [ "$mr_draft" = yes ] && echo "  ${YELLOW}[HELD — draft]${NC}" )"
        printf '  %-16s %s\n' "" "$mr_url"
    else
        printf '  %-16s %s\n' "merge request" "none yet"
    fi
    echo ""
    printf '  %-16s %s%s%s\n' "STATE" "$BOLD" "$rung" "$NC"
    printf '  %-16s %s\n' "reporter sees" "$plain"
    echo ""

    # The loud bits. Each of these is a thing the estate has silently missed.
    case "$rung" in
        merged-not-deployed)
            print_status "WARN" "MERGED IS NOT LIVE. The fix is on main; the last recorded code deploy to '${site}' predates it."
            print_hint "put it on the site:  pl stg2live ${site} --code-only" ;;
        merged-deploy-unknown)
            if [ -z "$site" ]; then
                print_status "WARN" "Merged. Pass --site=<name> to check whether it has actually been deployed."
            else
                print_status "WARN" "CANNOT VERIFY whether this is on '${site}' — no readable deploy record."
            fi ;;
        "deployed?")
            print_status "WARN" "A deploy to '${site}' ran after the merge, but nothing records WHICH commit the site runs."
            print_hint "'deployed?' is as far as the evidence goes — see ops issue for the deploy stamp that would close this." ;;
        conflict)
            print_status "FAIL" "This issue carries BOTH 'needs-human' and 'agent-eligible'. One of them is wrong; a human must decide which." ;;
        refused)
            print_status "WARN" "The agent loop stood down on this one — a person needs to write the fix." ;;
        held)
            print_hint "you held this for review. Approve it to merge:  pl feedback approve ${pid}#${iid} --mode=auto --approved-by=<you>" ;;
        mr-open)
            print_hint "approve it:  pl feedback approve ${pid}#${iid} --mode=review   (check it first)"
            print_hint "         or:  pl feedback approve ${pid}#${iid} --mode=auto --approved-by=<you>" ;;
        needs-human)
            print_hint "this one is yours to write — 'pl feedback arm' will refuse it, by design." ;;
        filed)
            print_hint "have a fix drafted:  pl feedback arm ${pid}#${iid}" ;;
    esac
    return 0
}

################################################################################
# pl feedback list
################################################################################
cmd_list() {
    local pid="$FB_DEFAULT_PROJECT_ID" as_json=false stuck=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --project=*) pid="${1#*=}"; shift ;;
            --json)  as_json=true; shift ;;
            --stuck) stuck=true; shift ;;
            -h|--help) show_help; return 0 ;;
            -*) die "unknown option: $1" ;;
            *) die "unexpected arg: $1" ;;
        esac
    done
    case "$pid" in *[!0-9]*) die "--project must be a numeric project id" ;; esac

    _token_present || { print_status "FAIL" "CANNOT VERIFY: no GitLab token."; return "$RC_BLIND"; }

    PROJECT_ID="$pid"
    local body
    body="$(_api_get "/projects/${pid}/issues?state=opened&labels=${FB_LABEL_FEEDBACK}&per_page=100&order_by=updated_at")" \
        || { print_status "FAIL" "CANNOT VERIFY: issue list failed."; return "$RC_BLIND"; }
    [ -n "$body" ] || { print_status "FAIL" "CANNOT VERIFY: empty response."; return "$RC_BLIND"; }

    local rows n=0
    rows="$(printf '%s' "$body" | "$YQ" e -p=json -o=tsv \
        '[.[] | [.iid, .state, ([.labels[]?] | join("|")), .title]] | .[]' - 2>/dev/null)" || rows=""

    [ "$as_json" = false ] && print_header "open feedback on project ${pid}"
    local out=""
    while IFS=$'\t' read -r iid state lbl title; do
        [ -n "$iid" ] || continue
        local labels="${lbl//|/,}"
        local rung; rung="$(fb_derive_rung "$state" "$labels" none no unknown "")"
        if [ "$stuck" = true ] && ! fb_rung_needs_operator "$rung"; then continue; fi
        n=$((n+1))
        if [ "$as_json" = true ]; then
            out+="$(REF="${pid}#${iid}" R="$rung" T="$title" L="$labels" "$YQ" -n -o=json -I=0 \
                '{"ref":strenv(REF),"rung":strenv(R),"labels":strenv(L),"title":strenv(T)}')"$'\n'
        else
            printf '  %-22s %-22s %s\n' "${pid}#${iid}" "$rung" "${title:0:70}"
        fi
    done <<<"$rows"

    if [ "$as_json" = true ]; then
        printf '%s' "$out" | "$YQ" e -p=json -o=json '[.]' - 2>/dev/null || echo '[]'
        return 0
    fi
    echo ""
    print_info "${n} item(s)$( [ "$stuck" = true ] && echo " waiting on you" )"
    print_hint "NOTE: rungs here are issue-level only (no MR lookup, to keep the list one API call)."
    print_hint "for the full end-to-end state of one item:  pl feedback status <ref> --site=<s>"
    return 0
}

################################################################################
# pl feedback arm <ref>
################################################################################
cmd_arm() {
    local ref="" assume_yes=false
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes) assume_yes=true; shift ;;
            -h|--help) show_help; return 0 ;;
            -*) die "unknown option: $1" ;;
            *) [ -z "$ref" ] && { ref="$1"; shift; } || die "unexpected arg: $1" ;;
        esac
    done
    [ -n "$ref" ] || die "usage: pl feedback arm <ref> [--yes]"

    local parsed pid iid
    parsed="$(fb_parse_issue_ref "$ref")" || die "unrecognised ref '$ref'"
    read -r pid iid <<<"$parsed"

    _token_present || { print_status "FAIL" "CANNOT VERIFY: no GitLab token."; return "$RC_BLIND"; }

    local issue rc=0
    issue="$(_fb_issue "$pid" "$iid")" || rc=$?
    [ "$rc" -eq 0 ] || { print_status "FAIL" "CANNOT VERIFY: could not read ${pid}#${iid}."; return "$RC_BLIND"; }

    local labels; labels="$(_fb_labels_csv "$issue")"

    # Is the loop actually running? Arming into a paused loop queues work that
    # nothing will pick up — and the reporter would then see "a fix is being
    # drafted" forever. That is the "nothing silent" rule applied to hope.
    local killed="no"
    if [ -f "$NWP_SRC_ROOT/lib/loop-parts.sh" ]; then
        # shellcheck source=/dev/null
        source "$NWP_SRC_ROOT/lib/loop-parts.sh"
        declare -F loop_global_killed >/dev/null 2>&1 && { loop_global_killed && killed="yes"; }
    fi

    local has_mr="no" mr
    mr="$(_fb_related_mr "$pid" "$iid" 2>/dev/null)" || mr=""
    [ -n "$mr" ] && [ "$(_fb_mr_field "$mr" state)" = "opened" ] && has_mr="yes"

    local verdict; verdict="$(fb_arm_verdict "$labels" "$killed" "$has_mr")"
    if [ "$verdict" != "allow" ]; then
        print_status "FAIL" "REFUSED (${verdict#refuse:}) — $(fb_arm_refusal_text "$verdict")"
        return "$RC_REFUSED"
    fi

    if [ "$assume_yes" != true ]; then
        print_warning "This hands ${pid}#${iid} to the AGENT loop, which will write code and open an MR."
        printf '  Continue? [y/N] '
        local ans; read -r ans || ans=""
        case "$ans" in y|Y|yes|YES) ;; *) print_info "no change"; return "$RC_REFUSED" ;; esac
    fi

    PROJECT_ID="$pid"
    local body resp
    body="$(L="$FB_LABEL_AGENT_ELIGIBLE" "$YQ" -n -o=json '{"add_labels": strenv(L)}')"
    resp="$(_api_send PUT "/projects/${pid}/issues/${iid}" "$body")"
    _require_ok "$resp" iid "arm ${pid}#${iid}" >/dev/null

    # Re-read and ASSERT. "I sent a PUT" is not "it is armed" — the same lesson
    # `pl mr hold` learned the hard way.
    issue="$(_fb_issue "$pid" "$iid")" || {
        print_status "FAIL" "label sent but could not verify it — check by hand."; return "$RC_BLIND"; }
    if fb_has_label "$(_fb_labels_csv "$issue")" "$FB_LABEL_AGENT_ELIGIBLE"; then
        print_success "${pid}#${iid} is ARMED — the agent loop may pick it up"
    else
        print_status "FAIL" "arm did NOT take: 'agent-eligible' is not on the issue. Do not rely on it."
        return "$RC_BLIND"
    fi
    [ "$killed" = "yes" ] && print_warning "the loop is paused; nothing will act on this until 'pl loop resume'"
    print_info "$(printf '%s' "$issue" | _jget web_url)"
    return 0
}

################################################################################
# pl feedback approve <ref> --mode=review|auto
################################################################################
cmd_approve() {
    local ref="" mode="review" approver="" reason="" assume_yes=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --mode=*) mode="${1#*=}"; shift ;;
            --mode)   mode="${2:-}"; shift 2 ;;
            --approved-by=*) approver="${1#*=}"; shift ;;
            --approved-by)   approver="${2:-}"; shift 2 ;;
            --reason=*) reason="${1#*=}"; shift ;;
            --reason)   reason="${2:-}"; shift 2 ;;
            -y|--yes) assume_yes=true; shift ;;
            -h|--help) show_help; return 0 ;;
            -*) die "unknown option: $1" ;;
            *) [ -z "$ref" ] && { ref="$1"; shift; } || die "unexpected arg: $1" ;;
        esac
    done
    [ -n "$ref" ] || die "usage: pl feedback approve <ref> --mode=review|auto [--approved-by=<handle>]"
    case " $FB_APPROVE_MODES " in
        *" $mode "*) ;;
        *) die "--mode must be 'review' (check it first) or 'auto' (merge on green)" ;;
    esac

    local parsed pid iid
    parsed="$(fb_parse_issue_ref "$ref")" || die "unrecognised ref '$ref'"
    read -r pid iid <<<"$parsed"

    # The approval PRIMITIVE is `pl mr hold` / `pl mr release`. If it is not in
    # this checkout, refuse and name it — do not grow a second, weaker hold.
    local mrcmd; mrcmd="$(_fb_mr_cmd)"
    if [ -z "$mrcmd" ]; then
        print_status "FAIL" "CANNOT ACT: 'pl mr' is not in this checkout."
        print_info "The approval primitive is \`pl mr hold\` / \`pl mr release\` (MR !314, branch feat/mr-hold-gate)."
        print_info "It must be merged to main before \`pl feedback approve\` can work. Deliberately NOT reimplemented here:"
        print_info "a second hold mechanism beside a forge-enforced one is how the 2026-08-01 self-merge happened."
        return "$RC_BLIND"
    fi

    _token_present || { print_status "FAIL" "CANNOT VERIFY: no GitLab token."; return "$RC_BLIND"; }

    local issue rc=0
    issue="$(_fb_issue "$pid" "$iid")" || rc=$?
    [ "$rc" -eq 0 ] || { print_status "FAIL" "CANNOT VERIFY: could not read ${pid}#${iid}."; return "$RC_BLIND"; }
    local labels; labels="$(_fb_labels_csv "$issue")"

    local mr mr_state="none" mr_draft="no" mr_iid=""
    mr="$(_fb_related_mr "$pid" "$iid" 2>/dev/null)" || mr=""
    if [ -n "$mr" ]; then
        mr_state="$(_fb_mr_field "$mr" state)"; [ -n "$mr_state" ] || mr_state="none"
        mr_draft="$(_fb_mr_is_draft "$mr")"
        mr_iid="$(_fb_mr_field "$mr" iid)"
    fi

    local verdict; verdict="$(fb_approve_verdict "$mode" "$labels" "$mr_state" "$mr_draft")"
    if [ "$verdict" != "allow" ]; then
        print_status "FAIL" "REFUSED (${verdict#refuse:}) — $(fb_approve_refusal_text "$verdict")"
        return "$RC_REFUSED"
    fi

    if [ "$mode" = "auto" ] && [ -z "$approver" ]; then
        die "--approved-by=<handle> is required for --mode=auto: a release names who approved it"
    fi

    if [ "$assume_yes" != true ]; then
        if [ "$mode" = "auto" ]; then
            print_warning "This RELEASES !${mr_iid} and lets it merge as soon as CI is green."
        else
            print_warning "This HOLDS !${mr_iid} as a draft so nothing can merge it until you release it."
        fi
        printf '  Continue? [y/N] '
        local ans; read -r ans || ans=""
        case "$ans" in y|Y|yes|YES) ;; *) print_info "no change"; return "$RC_REFUSED" ;; esac
    fi

    # NWP_MR_PROJECT points `pl mr` at the project the FEEDBACK issue lives on
    # (nwp/nwc = 16), not at whatever repo the operator's cwd happens to be.
    local mr_rc=0
    if [ "$mode" = "review" ]; then
        NWP_MR_PROJECT="$pid" "$mrcmd" hold "$mr_iid" \
            --reason="operator will review before merge (feedback ${pid}#${iid})${reason:+ — $reason}" || mr_rc=$?
        [ "$mr_rc" -eq 0 ] || { print_status "FAIL" "pl mr hold failed — nothing approved."; return "$RC_BLIND"; }
        _fb_label_issue "$pid" "$iid" "$FB_LABEL_APPROVED_REVIEW" "$FB_LABEL_APPROVED_AUTO"
        print_success "approved for REVIEW: !${mr_iid} is held; it cannot merge until you release it"
        print_hint "when you are happy:  pl feedback approve ${pid}#${iid} --mode=auto --approved-by=<you>"
    else
        NWP_MR_PROJECT="$pid" "$mrcmd" release "$mr_iid" --approved-by="$approver" \
            --reason="operator approved via pl feedback (feedback ${pid}#${iid})${reason:+ — $reason}" || mr_rc=$?
        [ "$mr_rc" -eq 0 ] || { print_status "FAIL" "pl mr release failed — nothing approved."; return "$RC_BLIND"; }
        _fb_label_issue "$pid" "$iid" "$FB_LABEL_APPROVED_AUTO" "$FB_LABEL_APPROVED_REVIEW"
        print_success "approved for AUTO-MERGE: !${mr_iid} released by @${approver}"
        print_warning "MERGED IS NOT LIVE. Nothing deploys this automatically yet."
        print_hint "after it merges:  pl feedback status ${pid}#${iid} --site=<site>   (tells you if it is actually on the site)"
    fi
    return 0
}

# _fb_label_issue <pid> <iid> <add> <remove> — one PUT, then say what happened.
_fb_label_issue() {
    local pid="$1" iid="$2" add="$3" rm="$4" body resp
    PROJECT_ID="$pid"
    body="$(A="$add" R="$rm" "$YQ" -n -o=json '{"add_labels": strenv(A), "remove_labels": strenv(R)}')"
    resp="$(_api_send PUT "/projects/${pid}/issues/${iid}" "$body")" || true
    printf '%s' "$resp" | _jget iid >/dev/null 2>&1 \
        || print_warning "could not record the approval label on ${pid}#${iid} (the MR state is authoritative)"
}

################################################################################
# pl feedback sync-status <site> — THE RETURN LEG
#
# Runs `drush nwc-feedback:sync-status`, which for every signal with a GitLab
# ref in an open state:
#   * captures the linked MR + preview URL onto the entity, and
#   * when the issue has CLOSED, moves the entity fixed → poster_invited and
#     emails the reporter the "please check this" invitation.
# That is what turns /my/feedback from a static "Sent to the team" into the
# link set the operator asked for. It existed and had no scheduler.
################################################################################
cmd_sync_status() {
    local site="" tier="dev" dry=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --tier=*) tier="${1#*=}"; shift ;;
            --tier)   tier="${2:-}"; shift 2 ;;
            --dry-run|-n) dry=true; shift ;;
            -h|--help) show_help; return 0 ;;
            -*) die "unknown option: $1" ;;
            *) [ -z "$site" ] && { site="$1"; shift; } || die "unexpected arg: $1" ;;
        esac
    done
    [ -n "$site" ] || die "usage: pl feedback sync-status <site> [--tier=dev|live] [--dry-run]"
    case "$tier" in dev|live) ;; *) die "--tier must be dev or live" ;; esac

    print_header "feedback return leg: ${site} (${tier})"

    # The token the Drupal command needs is passed as GITLAB_TOKEN. It is read
    # here and handed to `pl drush` in the ENVIRONMENT only — never in argv, so
    # it cannot land in ps or shell history.
    if ! _token_present; then
        print_status "FAIL" "CANNOT RUN: no GitLab token in ${SECRETS_FILE}."
        print_info "Nothing was changed. This is NOT 'no feedback to sync' — it is 'I could not ask'."
        print_hint "reporters will keep seeing a stale status until this runs."
        return "$RC_BLIND"
    fi

    if [ "$dry" = true ]; then
        print_info "[dry-run] would run: pl drush ${site} --tier=${tier} --execute -- nwc-feedback:sync-status"
        print_info "[dry-run] a real run advances entities whose GitLab issue has CLOSED to 'poster_invited' and emails the reporter."
        return 0
    fi

    local out rc=0
    out="$(GITLAB_TOKEN="$(_token)" "$PROJECT_ROOT/pl" drush "$site" --tier="$tier" --execute -- \
            nwc-feedback:sync-status 2>&1)" || rc=$?
    # Belt: never let a token echoed by a verbose drush reach the terminal.
    out="$(printf '%s' "$out" | sed "s/$(_token)/«redacted»/g" 2>/dev/null || printf '%s' "$out")"
    printf '%s\n' "$out"
    if [ "$rc" -ne 0 ]; then
        print_status "FAIL" "sync-status failed (rc=${rc}) — reporters are seeing stale state on ${site}."
        return "$RC_BLIND"
    fi
    print_success "return leg complete on ${site}"
    print_hint "the reporter's view: https://<${site} domain>/my/feedback"
    return 0
}

################################################################################
# pl feedback deploy-check [<site>...]
#
# The auto-deploy guard, made visible BEFORE there is an auto-deploy. Today it
# allows every site, because today no site is prod. Its whole value is that the
# day `pl canonical set <site> prod` runs, this flips to REFUSE for that site
# with no code change — and the operator can see, in advance, exactly what will
# stop and why.
################################################################################
cmd_deploy_check() {
    local as_json=false; local -a sites=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) as_json=true; shift ;;
            -h|--help) show_help; return 0 ;;
            -*) die "unknown option: $1" ;;
            *) sites+=("$1"); shift ;;
        esac
    done
    if [ "${#sites[@]}" -eq 0 ]; then
        local d
        for d in "$PROJECT_ROOT"/sites/*/.nwp.yml; do
            [ -e "$d" ] || continue
            d="${d%/.nwp.yml}"; sites+=("$(basename "$d")")
        done
    fi
    [ "${#sites[@]}" -gt 0 ] || { print_status "FAIL" "CANNOT VERIFY: no sites found under ${PROJECT_ROOT}/sites."; return "$RC_BLIND"; }

    local worst=0 s phase verdict out=""
    [ "$as_json" = false ] && print_header "auto-deploy guard (canonical phase, ops#33)"
    for s in "${sites[@]}"; do
        phase="$(canonical_get_phase "$s")"
        verdict="$(fb_autodeploy_phase_verdict "$phase")" || worst=1
        if [ "$as_json" = true ]; then
            out+="$(S="$s" P="$phase" V="$verdict" "$YQ" -n -o=json -I=0 \
                '{"site":strenv(S),"canonical":strenv(P),"verdict":strenv(V)}')"$'\n'
        else
            if [ "$verdict" = "allow" ]; then
                printf '  %-12s %-18s %sALLOW%s\n' "$s" "$phase" "$GREEN" "$NC"
            else
                printf '  %-12s %-18s %sREFUSE%s  %s\n' "$s" "$phase" "$RED" "$NC" \
                    "$(fb_autodeploy_refusal_text "$verdict")"
            fi
        fi
    done
    if [ "$as_json" = true ]; then
        printf '%s' "$out" | "$YQ" e -p=json -o=json '[.]' - 2>/dev/null || echo '[]'
        return "$worst"
    fi
    echo ""
    if [ "$worst" -eq 0 ]; then
        print_info "The guard refuses nothing today — no site is canonical: prod. That is correct, not a bug."
        print_info "It arms itself for a site the moment:  pl canonical set <site> prod"
        print_info "…which is how Phase 2 starts. From then on this loop will not target that site, and will say so."
    fi
    return "$worst"
}

main() {
    local sub="${1:-}"
    [ $# -gt 0 ] && shift
    case "$sub" in
        status)       cmd_status "$@" ;;
        list|ls)      cmd_list "$@" ;;
        arm)          cmd_arm "$@" ;;
        approve)      cmd_approve "$@" ;;
        sync-status)  cmd_sync_status "$@" ;;
        deploy-check) cmd_deploy_check "$@" ;;
        ""|-h|--help|help) show_help ;;
        *) print_error "Unknown subcommand: $sub"; show_help; exit "$RC_USAGE" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
