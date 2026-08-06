#!/bin/bash
set -uo pipefail
################################################################################
# pl decisions — the operator's open decisions, in the order they should be taken
#
# ── WHY THIS IS A VERB AND NOT A DOCUMENT ─────────────────────────────────────
#
# The operator has been handed three decision documents in a week —
# DECISIONS-RESEARCH-2026-08-03.md, DECISIONS-LOG-2026-08-03.md,
# PICKUP-2026-08-05.md — and every one of them went stale. The last went stale
# TWICE IN ONE NIGHT, and the operator caught both, which is the wrong way round:
#
#     "PICKUP-2026-08-05.md is not up to date. 363 has been merged."
#
# A document is a COPY of the tracker's state. Copies drift, and the drift is
# invisible until someone acts on the stale half. This verb holds no state: it
# reads nwp/ops at the moment you ask, so there is nothing to go stale. The
# document stops existing, which is the only fix that lasts.
#
# ── WHAT MAKES A DECISION READABLE ────────────────────────────────────────────
#
# The operator's complaint was not that decisions were hidden, it was that
# finding the QUESTION meant wading through the diagnosis:
#
#     "can you add a clear explanation of what that decision entails rather than
#      having to wade through the jargon with a clear recommendation and why?"
#
# So a `needs-decision` issue must carry a `## Decision` block with four parts —
# WHAT you are choosing, the OPTIONS, the RECOMMENDATION and why, and what it
# UNBLOCKS. This verb renders that block and the issue link, and nothing else.
# The diagnosis stays in the issue for whoever needs it; it is not the operator's
# reading homework.
#
# An issue labelled needs-decision WITHOUT that block is reported as INCOMPLETE
# rather than skipped — a decision nobody can read is still a decision that is
# blocking, and hiding it would recreate the problem this verb exists to solve.
#
# ── ORDER AND GROUPING ────────────────────────────────────────────────────────
#
# Grouped by what the decision GATES, because that is what makes an order real:
#
#   1. BLOCKS TESTERS   — Phase 1 cannot finish until this is answered
#   2. BLOCKS PROD      — Phase 2 cannot start
#   3. SHAPES DESIGN    — nothing is stopped, but building first means rework
#   4. HOUSEKEEPING     — real, small, no downstream
#
# Within a group, an issue that another decision depends on sorts first, so the
# list reads as a sequence rather than a pile. Dependencies are declared in the
# block as `Depends-on: #N` — the flow-chart shape the operator found useful in
# DECISIONS-RESEARCH, expressed as data instead of a drawing that also drifts.
#
# ── OPEN MERGE REQUESTS ARE PART OF THE QUEUE ─────────────────────────────────
#
# Under solo review mode (ADR-0032) the merge click on the MR page IS the
# approval, so an open MR is an operator action exactly like a needs-decision
# issue. One queue, one verb: this verb lists both, and the Review pane of the
# NWP Console renders this verb's --json rather than growing a rival source.
# An MR project the token cannot read is reported CANNOT-READ, never as empty.
#
# ── USAGE ─────────────────────────────────────────────────────────────────────
#   pl decisions                 grouped, ordered, plain language (+ open MRs)
#   pl decisions --json          machine-readable (the NWP Console Review pane reads this)
#   pl decisions --all           include issues with no ## Decision block
#   pl decisions <iid>           one decision in full (MR section omitted)
#
# Exit: 0 decisions listed (or none) · 1 could not read the tracker
################################################################################
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh" 2>/dev/null || true

DECISIONS_PROJECT="${NWP_OPS_PROJECT_ID:-21}"
DECISIONS_LABEL="${NWP_DECISIONS_LABEL:-needs-decision}"

# NO LITERAL FALLBACK. The forge domain is operator-specific and the gitleaks
# ruleset bans it from tracked files — correctly: a default that names the real
# host is how a "generic" tool quietly hardcodes one estate. An unresolvable host
# is CANNOT-VERIFY, not a guess at where the tracker lives.
_dec_host(){
    yq e '.gitlab.server.domain // ""' "$PROJECT_ROOT/.secrets.yml" 2>/dev/null | grep -v '^null$'
}

# Values-safe: the token is used only inside a 0600 curl config, never in argv.
_dec_fetch(){
    local tok cfg host
    tok=$(yq e '.gitlab.ops_note_token // .gitlab.api_token // ""' "$PROJECT_ROOT/.secrets.yml" 2>/dev/null | grep -v '^null$')
    [ -n "$tok" ] || return 2
    host="$(_dec_host)"
    [ -n "$host" ] || return 3
    cfg=$(mktemp); chmod 600 "$cfg"
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok" > "$cfg"
    curl -sS -K "$cfg" --get \
        --data-urlencode "labels=${DECISIONS_LABEL}" \
        --data-urlencode "state=opened" \
        --data-urlencode "per_page=100" \
        "https://${host}/api/v4/projects/${DECISIONS_PROJECT}/issues" 2>/dev/null
    local rc=$?
    rm -f "$cfg"
    return $rc
}

# Open MRs for one project path, written to $2. Same token discipline as
# _dec_fetch. `-f` matters: the walled ops_note_token answers HTTP 404 for a
# project it cannot see, and without -f that 404 body would parse as an empty
# list — the exact "unreadable renders as clean" failure this repo keeps
# re-learning (ops#281 shape). With -f curl exits non-zero and the renderer
# says CANNOT-READ instead.
_dec_fetch_mrs_one(){
    local proj="$1" out="$2" tok cfg host rc
    # Precedence is REVERSED from _dec_fetch, deliberately: the ops_note_token
    # is walled to nwp/ops and 404s on the MR projects, while the group bot
    # (api_token) reads them. Each fetch leads with the token that can see its
    # target; the other stays as fallback for estates keyed differently.
    tok=$(yq e '.gitlab.api_token // .gitlab.ops_note_token // ""' "$PROJECT_ROOT/.secrets.yml" 2>/dev/null | grep -v '^null$')
    [ -n "$tok" ] || return 2
    host="$(_dec_host)"
    [ -n "$host" ] || return 3
    cfg=$(mktemp); chmod 600 "$cfg"
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok" > "$cfg"
    curl -sS -f -K "$cfg" --get \
        --data-urlencode "state=opened" \
        --data-urlencode "per_page=50" \
        "https://${host}/api/v4/projects/${proj//\//%2F}/merge_requests" > "$out" 2>/dev/null
    rc=$?
    rm -f "$cfg"
    return $rc
}

# The MR projects are overridable but default to where work actually lands.
DECISIONS_MR_PROJECTS="${NWP_DECISIONS_MR_PROJECTS:-nwp/nwp nwp/nwc}"

# Fetch every MR project into a manifest the renderer reads: one TSV row per
# project — path, body file, ok|unreadable. Prints the manifest path.
_dec_fetch_mrs(){
    local mrdir manifest p i=0
    mrdir=$(mktemp -d)
    manifest="$mrdir/manifest.tsv"
    : > "$manifest"
    for p in $DECISIONS_MR_PROJECTS; do
        i=$((i+1))
        if _dec_fetch_mrs_one "$p" "$mrdir/mrs$i.json"; then
            printf '%s\t%s\tok\n' "$p" "$mrdir/mrs$i.json" >> "$manifest"
        else
            printf '%s\t%s\tunreadable\n' "$p" "$mrdir/mrs$i.json" >> "$manifest"
        fi
    done
    printf '%s\n' "$manifest"
}

# The parser + renderer live in python3, not yq: this reads prose out of markdown
# bodies, which is string work, and python3 is already this repo's fallback for
# JSON (lib/gitlab-mr.sh) and present wherever Drupal runs. ops#281 is the standing
# reminder that reaching for yq on a host that lacks it fails SILENTLY.
_dec_render(){
    python3 "$PROJECT_ROOT/scripts/lib/decisions-render.py" "$1" "$2" "$3" "${4:-}"
}

cmd_decisions(){
    local mode="text" only="" all=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) mode="json"; shift ;;
            --all)  all=true; shift ;;
            -h|--help)
                sed -n '3,66p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
                return 0 ;;
            [0-9]*) only="$1"; shift ;;
            *) print_error "unknown option: $1"; return 1 ;;
        esac
    done

    local json rc
    json=$(_dec_fetch); rc=$?
    if [ $rc -eq 3 ]; then
        print_error "CANNOT-VERIFY: no gitlab.server.domain configured, so the tracker was not read."
        print_info  "Set it in .secrets.yml — this verb will not guess which forge is yours."
        return 1
    fi
    if [ $rc -eq 2 ]; then
        # "I could not look" is never "there is nothing to decide".
        print_error "CANNOT-VERIFY: no GitLab token available, so the tracker was not read."
        print_info  "This is not 'no decisions' — it is 'I could not look'."
        return 1
    fi
    # No decisions is NOT "nothing to render": open MRs are still the
    # operator's queue, so the renderer always runs (it handles []).
    [ -z "$json" ] && json="[]"

    # A single-decision view (`pl decisions <iid>`) omits the MR section, so
    # only fetch MRs when the whole queue is being rendered.
    local manifest="" mrdir=""
    if [ -z "$only" ]; then
        manifest=$(_dec_fetch_mrs)
        mrdir=$(dirname "$manifest")
    fi
    printf '%s' "$json" | _dec_render "$mode" "$only" "$(_dec_host)" "$manifest"
    local rc=$?
    [ -n "$mrdir" ] && rm -rf "$mrdir"
    return $rc
}

cmd_decisions "$@"
