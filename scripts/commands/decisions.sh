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
# impact_rm_scratch: the tree's single audited primitive for removing a
# throwaway directory this process created (lib/impact.sh). The MR-fetch dir
# below is a `mktemp -d` made a few lines earlier — not scope a human cares
# about — but a bare `rm -rf` is indistinguishable from the real thing to any
# scanner, so it goes through the audited primitive instead.
source "$PROJECT_ROOT/lib/impact.sh"

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

# Latest note for one queued issue, written to $2. Why: ops#143 sat FOUR DAYS
# in this queue as the sole blocks-prod item after two comments on it said
# "recommend close" — the verb rendered the stale ## Decision block and never
# looked at the conversation. The renderer flags a decision whose newest
# comment reads as a resolution, so a solved problem cannot silently keep
# claiming to block a phase.
_dec_fetch_note_one(){
    local iid="$1" out="$2" tok cfg host rc
    tok=$(yq e '.gitlab.ops_note_token // .gitlab.api_token // ""' "$PROJECT_ROOT/.secrets.yml" 2>/dev/null | grep -v '^null$')
    [ -n "$tok" ] || return 2
    host="$(_dec_host)"
    [ -n "$host" ] || return 3
    cfg=$(mktemp); chmod 600 "$cfg"
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok" > "$cfg"
    curl -sS -f -K "$cfg" --get \
        --data-urlencode "sort=desc" \
        --data-urlencode "order_by=created_at" \
        --data-urlencode "per_page=1" \
        "https://${host}/api/v4/projects/${DECISIONS_PROJECT}/issues/${iid}/notes" > "$out" 2>/dev/null
    rc=$?
    rm -f "$cfg"
    return $rc
}

# One latest-note file per queued issue, in a dir the renderer reads.
# Best-effort per issue: a note fetch that fails simply leaves no file, and the
# renderer treats no-file as "no staleness signal", never as an error.
_dec_fetch_notes(){
    local json="$1" notesdir iid
    notesdir=$(mktemp -d)
    for iid in $(printf '%s' "$json" | python3 -c 'import json,sys
try:
    for i in json.load(sys.stdin): print(i["iid"])
except Exception: pass' 2>/dev/null); do
        _dec_fetch_note_one "$iid" "$notesdir/$iid.json" || rm -f "$notesdir/$iid.json"
    done
    printf '%s\n' "$notesdir"
}

# ── THE TWO DECISION LABELS, DECLARED ─────────────────────────────────────────
# This queue renders `needs-decision` = "the operator must answer NOW to
# unblock the current phase". A second vocabulary exists: `decision::wanted`
# (the 2026-08-03 triage), marking decision-SHAPED backlog — ~50 open issues,
# including go-live prerequisites. Rendering all of them would drown the queue;
# hiding their existence made the queue lie by omission (the operator read "5
# decisions waiting" as the whole decision surface — audit 2026-08-06). So the
# split is deliberate and DECLARED: this verb counts the others and says so in
# the footer, and promoting one is a label edit, not new machinery.
_dec_fetch_outside_count(){
    local tok cfg host total
    tok=$(yq e '.gitlab.ops_note_token // .gitlab.api_token // ""' "$PROJECT_ROOT/.secrets.yml" 2>/dev/null | grep -v '^null$')
    [ -n "$tok" ] || return 2
    host="$(_dec_host)"
    [ -n "$host" ] || return 3
    cfg=$(mktemp); chmod 600 "$cfg"
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok" > "$cfg"
    total=$(curl -sS -f -K "$cfg" --get -o /dev/null -D - \
        --data-urlencode "labels=decision::wanted" \
        --data-urlencode "not[labels]=${DECISIONS_LABEL}" \
        --data-urlencode "state=opened" \
        --data-urlencode "per_page=1" \
        "https://${host}/api/v4/projects/${DECISIONS_PROJECT}/issues" 2>/dev/null \
        | tr -d '\r' | awk -F': ' 'tolower($1)=="x-total"{print $2}')
    rm -f "$cfg"
    [ -n "$total" ] || return 1
    printf '%s\n' "$total"
}

# ── AMBER: the decision::wanted tier, fetched IN FULL (ops#279) ───────────────
#
# Counting them was the previous step (the footer stopped the queue lying by
# omission). Rendering them is this one: the operator asked for RED = decision
# NEEDED and AMBER = decision WANTED, red always first, ambers in a sequence.
#
# A count told the operator a number and left them no way to act on it; a list
# they can read in order is the difference between "55 somewhere" and a queue.
# Rendered COMPACTLY — one line each — because 55 full ## Decision blocks would
# drown the red tier, which is the one thing that must stay readable.
#
# Writes the issue JSON to the path given in $1; empty output means "could not
# read", which the renderer reports rather than showing an empty amber tier.
_dec_fetch_outside(){
    local out="$1" tok cfg host rc
    tok=$(yq e '.gitlab.ops_note_token // .gitlab.api_token // ""' "$PROJECT_ROOT/.secrets.yml" 2>/dev/null | grep -v '^null$')
    [ -n "$tok" ] || return 2
    host="$(_dec_host)"
    [ -n "$host" ] || return 3
    cfg=$(mktemp); chmod 600 "$cfg"
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok" > "$cfg"
    # -f so a 404 from a walled token is an ERROR, never an empty list parsed as
    # "no ambers" — the unreadable-renders-as-clean failure this repo keeps
    # re-learning (ops#281).
    curl -sS -f -K "$cfg" --get \
        --data-urlencode "labels=decision::wanted" \
        --data-urlencode "not[labels]=${DECISIONS_LABEL}" \
        --data-urlencode "state=opened" \
        --data-urlencode "per_page=100" \
        "https://${host}/api/v4/projects/${DECISIONS_PROJECT}/issues" > "$out" 2>/dev/null
    rc=$?
    rm -f "$cfg"
    return $rc
}

# The parser + renderer live in python3, not yq: this reads prose out of markdown
# bodies, which is string work, and python3 is already this repo's fallback for
# JSON (lib/gitlab-mr.sh) and present wherever Drupal runs. ops#281 is the standing
# reminder that reaching for yq on a host that lacks it fails SILENTLY.
_dec_render(){
    python3 "$PROJECT_ROOT/scripts/lib/decisions-render.py" "$1" "$2" "$3" "${4:-}" "${5:-}" "${6:-}" "${7:-}"
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

    # A single-decision view (`pl decisions <iid>`) omits the MR section and
    # the footer, so only fetch MRs / notes / the outside count for the full
    # queue. The outside count is best-effort: "" renders no footer number —
    # but the renderer still prints the label-split line, because the SPLIT is
    # a fact about the queue even when the count could not be read.
    local manifest="" mrdir="" notesdir="" outside="" amberdir="" amberfile=""
    if [ -z "$only" ]; then
        manifest=$(_dec_fetch_mrs)
        mrdir=$(dirname "$manifest")
        notesdir=$(_dec_fetch_notes "$json")
        outside=$(_dec_fetch_outside_count) || outside=""
        # The AMBER tier itself (ops#279). Best-effort and INDEPENDENT of the
        # count above: if the list fetch fails the renderer still prints the
        # count-only footer, so a broken amber fetch degrades to the previous
        # behaviour instead of silently showing an empty amber tier.
        amberdir=$(mktemp -d); amberfile="$amberdir/amber.json"
        _dec_fetch_outside "$amberfile" || amberfile=""
    fi
    printf '%s' "$json" | _dec_render "$mode" "$only" "$(_dec_host)" "$manifest" "$notesdir" "$outside" "$amberfile"
    local rc=$?
    [ -n "$mrdir" ] && impact_rm_scratch "$mrdir" >/dev/null
    [ -n "$notesdir" ] && impact_rm_scratch "$notesdir" >/dev/null
    [ -n "$amberdir" ] && impact_rm_scratch "$amberdir" >/dev/null
    return $rc
}

cmd_decisions "$@"
