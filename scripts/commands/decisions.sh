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
# Under solo review mode (ADR-0037) the merge click on the MR page IS the
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
#   pl decisions promote <iid> [--gate=blocks-testers|blocks-prod|shapes-design|housekeeping]
#                              [--block-file=FILE] [--dry-run]
#                                promote a decision::wanted issue into the red
#                                tier: adds needs-decision AND scaffolds the
#                                ## Decision block if the issue has none, so a
#                                promoted issue is readable the moment it
#                                appears (ops#305, ruling A). An existing block
#                                is never rewritten; --block-file supplies a
#                                real block instead of the TODO scaffold.
#   pl decisions sweep-approved [--discharge] [--json]
#                                the ops#327 backlog sweep: list issues that
#                                carry an approving note ([console-review]
#                                APPROVED, or an operator reply saying
#                                Approved) yet STILL wear needs-decision /
#                                decision::wanted — the state #74/#101/#139
#                                sat in while the operator re-approved them.
#                                Default REPORTS; --discharge removes the
#                                labels and writes a ledger line per issue.
#
# Exit: 0 decisions listed (or none) · 1 could not read the tracker
#       (sweep-approved: 2 = CANNOT-VERIFY, the tracker or an issue's notes
#        could not be read — never rendered as a clean sweep)
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

# Values-safe: the token is fed to curl as a config on STDIN — never in argv, and
# (ops#374) never as a file that could outlive a killed process. See lib/http.sh.
_dec_fetch(){
    local tok host
    tok=$(yq e '.gitlab.ops_note_token // .gitlab.api_token // ""' "$PROJECT_ROOT/.secrets.yml" 2>/dev/null | grep -v '^null$')
    [ -n "$tok" ] || return 2
    host="$(_dec_host)"
    [ -n "$host" ] || return 3
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok" | curl -sS -K - --get \
        --data-urlencode "labels=${DECISIONS_LABEL}" \
        --data-urlencode "state=opened" \
        --data-urlencode "per_page=100" \
        "https://${host}/api/v4/projects/${DECISIONS_PROJECT}/issues" 2>/dev/null
    local rc=$?
    return $rc
}

# Open MRs for one project path, written to $2. Same token discipline as
# _dec_fetch. `-f` matters: the walled ops_note_token answers HTTP 404 for a
# project it cannot see, and without -f that 404 body would parse as an empty
# list — the exact "unreadable renders as clean" failure this repo keeps
# re-learning (ops#281 shape). With -f curl exits non-zero and the renderer
# says CANNOT-READ instead.
_dec_fetch_mrs_one(){
    local proj="$1" out="$2" tok host rc
    # Precedence is REVERSED from _dec_fetch, deliberately: the ops_note_token
    # is walled to nwp/ops and 404s on the MR projects, while the group bot
    # (api_token) reads them. Each fetch leads with the token that can see its
    # target; the other stays as fallback for estates keyed differently.
    tok=$(yq e '.gitlab.api_token // .gitlab.ops_note_token // ""' "$PROJECT_ROOT/.secrets.yml" 2>/dev/null | grep -v '^null$')
    [ -n "$tok" ] || return 2
    host="$(_dec_host)"
    [ -n "$host" ] || return 3
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok" | curl -sS -f -K - --get \
        --data-urlencode "state=opened" \
        --data-urlencode "per_page=50" \
        "https://${host}/api/v4/projects/${proj//\//%2F}/merge_requests" > "$out" 2>/dev/null
    rc=$?
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
    local iid="$1" out="$2" tok host rc
    tok=$(yq e '.gitlab.ops_note_token // .gitlab.api_token // ""' "$PROJECT_ROOT/.secrets.yml" 2>/dev/null | grep -v '^null$')
    [ -n "$tok" ] || return 2
    host="$(_dec_host)"
    [ -n "$host" ] || return 3
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok" | curl -sS -f -K - --get \
        --data-urlencode "sort=desc" \
        --data-urlencode "order_by=created_at" \
        --data-urlencode "per_page=1" \
        "https://${host}/api/v4/projects/${DECISIONS_PROJECT}/issues/${iid}/notes" > "$out" 2>/dev/null
    rc=$?
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
    local tok host total
    tok=$(yq e '.gitlab.ops_note_token // .gitlab.api_token // ""' "$PROJECT_ROOT/.secrets.yml" 2>/dev/null | grep -v '^null$')
    [ -n "$tok" ] || return 2
    host="$(_dec_host)"
    [ -n "$host" ] || return 3
    total=$(printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok" | curl -sS -f -K - --get -o /dev/null -D - \
        --data-urlencode "labels=decision::wanted" \
        --data-urlencode "not[labels]=${DECISIONS_LABEL}" \
        --data-urlencode "state=opened" \
        --data-urlencode "per_page=1" \
        "https://${host}/api/v4/projects/${DECISIONS_PROJECT}/issues" 2>/dev/null \
        | tr -d '\r' | awk -F': ' 'tolower($1)=="x-total"{print $2}')
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
#
# PAGINATED (ops#292): a single per_page=100 request silently drops amber #101
# onward — exactly the truncated-renders-as-whole failure, just deferred until
# the tier grows. So this follows pages until a short page. The loop is bounded
# (20 pages = 2000 issues, a size at which the tier is a different problem);
# hitting the bound is LOGGED and the partial fetch still ships, because the
# renderer compares the list against the tracker's X-Total and declares
# "PARTIAL: showing N of M" rather than trimming silently.
_dec_fetch_outside(){
    local out="$1" tok host rc=0 page=1 pagedir n
    tok=$(yq e '.gitlab.ops_note_token // .gitlab.api_token // ""' "$PROJECT_ROOT/.secrets.yml" 2>/dev/null | grep -v '^null$')
    [ -n "$tok" ] || return 2
    host="$(_dec_host)"
    [ -n "$host" ] || return 3
    pagedir=$(mktemp -d)
    while :; do
        # -f so a 404 from a walled token is an ERROR, never an empty list
        # parsed as "no ambers" — the unreadable-renders-as-clean failure this
        # repo keeps re-learning (ops#281).
        printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok" | curl -sS -f -K - --get \
            --data-urlencode "labels=decision::wanted" \
            --data-urlencode "not[labels]=${DECISIONS_LABEL}" \
            --data-urlencode "state=opened" \
            --data-urlencode "per_page=100" \
            --data-urlencode "page=${page}" \
            "https://${host}/api/v4/projects/${DECISIONS_PROJECT}/issues" \
            > "$pagedir/page-$(printf '%03d' "$page").json" 2>/dev/null || { rc=$?; break; }
        n=$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
print(len(d) if isinstance(d, list) else -1)' \
            "$pagedir/page-$(printf '%03d' "$page").json" 2>/dev/null) || n=-1
        # An unparseable page fails the WHOLE fetch: a half-merged list would
        # render as a complete tier.
        [ "$n" -ge 0 ] 2>/dev/null || { rc=1; break; }
        [ "$n" -lt 100 ] && break
        page=$((page+1))
        if [ "$page" -gt 20 ]; then
            echo "WARNING: decision::wanted fetch stopped at 20 pages (2000 issues); the rest were dropped and the renderer will mark the tier PARTIAL" >&2
            break
        fi
    done
    if [ $rc -eq 0 ]; then
        python3 -c 'import glob, json, sys
merged = []
for p in sorted(glob.glob(sys.argv[1] + "/page-*.json")):
    merged.extend(json.load(open(p)))
json.dump(merged, open(sys.argv[2], "w"))' "$pagedir" "$out" 2>/dev/null || rc=1
    fi
    rm -f "$pagedir"/page-*.json
    rmdir "$pagedir" 2>/dev/null || true
    return $rc
}

# The parser + renderer live in python3, not yq: this reads prose out of markdown
# bodies, which is string work, and python3 is already this repo's fallback for
# JSON (lib/gitlab-mr.sh) and present wherever Drupal runs. ops#281 is the standing
# reminder that reaching for yq on a host that lacks it fails SILENTLY.
_dec_render(){
    python3 "$PROJECT_ROOT/scripts/lib/decisions-render.py" "$1" "$2" "$3" "${4:-}" "${5:-}" "${6:-}" "${7:-}"
}

# ── promote (ops#305, ruling A) ───────────────────────────────────────────────
#
# The 2026-08-07 audit found 55 decision::wanted issues that never became
# needs-decision — not a considered backlog, an ACCUMULATION at a manual label
# edit. Only 4 of the 55 carried a ## Decision block, so promoting one bare
# produced an INCOMPLETE red entry the operator still had to open. This verb
# makes promotion one command that leaves the entry READABLE: label + block in
# a single tracker write. The planner is pure (decisions-promote-plan.py) and
# unit-tested; this function is the thin API shell around it.
cmd_promote(){
    local iid="" gate="shapes-design" blockfile="" dryrun=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --gate=*)       gate="${1#*=}"; shift ;;
            --block-file=*) blockfile="${1#*=}"; shift ;;
            --dry-run)      dryrun=true; shift ;;
            [0-9]*)         iid="$1"; shift ;;
            *) print_error "unknown option: $1"; return 1 ;;
        esac
    done
    [ -n "$iid" ] || { print_error "usage: pl decisions promote <iid> [--gate=…] [--block-file=FILE] [--dry-run]"; return 1; }
    case "$gate" in
        blocks-testers|blocks-prod|shapes-design|housekeeping|phase1|phase2) ;;
        *) print_error "unknown gate '$gate' (blocks-testers|blocks-prod|shapes-design|housekeeping)"; return 1 ;;
    esac
    [ -n "$blockfile" ] && [ ! -f "$blockfile" ] && { print_error "no such file: $blockfile"; return 1; }

    local tok host
    tok=$(yq e '.gitlab.ops_note_token // .gitlab.api_token // ""' "$PROJECT_ROOT/.secrets.yml" 2>/dev/null | grep -v '^null$')
    [ -n "$tok" ] || { print_error "CANNOT-VERIFY: no GitLab token — nothing was promoted."; return 1; }
    host="$(_dec_host)"
    [ -n "$host" ] || { print_error "CANNOT-VERIFY: no gitlab.server.domain — nothing was promoted."; return 1; }

    local issue plan
    issue=$(printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok" | curl -sS -f -K - \
        "https://${host}/api/v4/projects/${DECISIONS_PROJECT}/issues/${iid}" 2>/dev/null) \
        || { print_error "could not read nwp/ops#${iid} — nothing was promoted."; return 1; }

    plan=$(printf '%s' "$issue" | python3 -c '
import json,sys
i = json.load(sys.stdin)
print(json.dumps({"description": i.get("description") or "",
                  "labels": i.get("labels") or [],
                  "gate": sys.argv[1]}))' "$gate" \
        | python3 "$PROJECT_ROOT/scripts/lib/decisions-promote-plan.py" \
            ${blockfile:+--block-file="$blockfile"}) \
        || { print_error "planner refused — nothing was promoted."; return 1; }

    local already needs_label has_new scaffolded
    already=$(printf '%s' "$plan" | python3 -c 'import json,sys; print(json.load(sys.stdin)["already_promoted"])')
    needs_label=$(printf '%s' "$plan" | python3 -c 'import json,sys; print(json.load(sys.stdin)["needs_label"])')
    has_new=$(printf '%s' "$plan" | python3 -c 'import json,sys; print(json.load(sys.stdin)["new_description"] is not None)')
    scaffolded=$(printf '%s' "$plan" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("scaffolded") is True)')

    if [ "$already" = "True" ]; then
        print_status "OK" "nwp/ops#${iid} is already promoted (label + block present) — nothing to do."
        return 0
    fi
    if [ "$dryrun" = true ]; then
        print_header "promote nwp/ops#${iid} — dry run"
        [ "$needs_label" = "True" ] && print_info "would add label: ${DECISIONS_LABEL}"
        if [ "$has_new" = "True" ]; then
            print_info "would prepend this block (original description kept below):"
            printf '%s' "$plan" | python3 -c 'import json,sys
d = json.load(sys.stdin)["new_description"]
print("\n".join("    " + l for l in d.splitlines()[:14]))'
        else
            print_info "issue already carries a ## Decision block — description untouched."
        fi
        print_status "OK" "[dry-run] nothing written."
        return 0
    fi

    # One PUT carries both halves; a payload file keeps the body off argv.
    local payload resp
    payload=$(mktemp); chmod 600 "$payload"
    printf '%s' "$plan" | python3 -c '
import json,sys
plan = json.load(sys.stdin)
out = {}
if plan["needs_label"]:
    out["add_labels"] = sys.argv[1]
if plan["new_description"] is not None:
    out["description"] = plan["new_description"]
print(json.dumps(out))' "$DECISIONS_LABEL" > "$payload"
    resp=$(printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok" | curl -sS -f -K - -X PUT \
        -H "Content-Type: application/json" --data @"$payload" \
        "https://${host}/api/v4/projects/${DECISIONS_PROJECT}/issues/${iid}" 2>/dev/null)
    local rc=$?
    rm -f "$payload"
    if [ $rc -ne 0 ] || ! printf '%s' "$resp" | python3 -c '
import json,sys
i = json.load(sys.stdin)
sys.exit(0 if "needs-decision" in (i.get("labels") or []) else 1)'; then
        print_error "promotion write FAILED for nwp/ops#${iid} — check the issue before retrying."
        return 1
    fi
    print_status "OK" "promoted nwp/ops#${iid}: label added$( [ "$has_new" = "True" ] && echo ", ## Decision block scaffolded" )."
    # Only the TODO scaffold needs filling — a --block-file block is already real.
    [ "$scaffolded" = "True" ] && print_info "the block carries TODOs — fill them (or re-run with --block-file) before the operator reads it."
    return 0
}

# ── sweep-approved (ops#327) ──────────────────────────────────────────────────
#
# The console's Approve button posted `[console-review] APPROVED` notes that
# NOTHING consumed: the decision labels stayed on, the issue stayed in the
# queue, and the operator re-approved — #139 four times. The Approve action
# now discharges at the moment of approval (scripts/console/app/main.py); this
# verb finds and clears the RESIDUE that accumulated before that fix, and is
# the recovery path whenever a console discharge fails (403, network).
#
# Default is a REPORT (read-only). --discharge removes needs-decision +
# decision::wanted from each listed issue, verifies the removal from the PUT
# response, and appends one line per discharge to the ledger
# private/decisions-discharge.log. The classifier is pure
# (scripts/lib/decisions-sweep.py) and unit-tested; this shell stays thin.
#
# Fail-closed: no token, no host, a failed issue fetch, or ANY issue whose
# notes could not be read => exit 2 CANNOT-VERIFY. An unreadable tracker must
# never render as "no undischarged approvals".
_sweep_fetch_notes_one(){ # iid out — ALL notes (100 cap), unlike _dec_fetch_note_one's latest-1
    local iid="$1" out="$2" tok host rc
    tok=$(yq e '.gitlab.ops_note_token // .gitlab.api_token // ""' "$PROJECT_ROOT/.secrets.yml" 2>/dev/null | grep -v '^null$')
    [ -n "$tok" ] || return 2
    host="$(_dec_host)"
    [ -n "$host" ] || return 3
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok" | curl -sS -f -K - --get \
        --data-urlencode "sort=asc" \
        --data-urlencode "order_by=created_at" \
        --data-urlencode "per_page=100" \
        "https://${host}/api/v4/projects/${DECISIONS_PROJECT}/issues/${iid}/notes" > "$out" 2>/dev/null
    rc=$?
    return $rc
}

cmd_sweep_approved(){
    local discharge=false mode="text"
    while [ $# -gt 0 ]; do
        case "$1" in
            --discharge) discharge=true; shift ;;
            --json)      mode="json"; shift ;;
            *) print_error "unknown option: $1 (usage: pl decisions sweep-approved [--discharge] [--json])"; return 1 ;;
        esac
    done

    local tok host
    tok=$(yq e '.gitlab.ops_note_token // .gitlab.api_token // ""' "$PROJECT_ROOT/.secrets.yml" 2>/dev/null | grep -v '^null$')
    if [ -z "$tok" ]; then
        print_error "CANNOT-VERIFY: no GitLab token, so the sweep could not look."
        print_info  "This is not 'no undischarged approvals' — the tracker was not read."
        return 2
    fi
    host="$(_dec_host)"
    if [ -z "$host" ]; then
        print_error "CANNOT-VERIFY: no gitlab.server.domain configured, so the sweep could not look."
        return 2
    fi

    # The union of both decision labels, each paginated to a short page (same
    # bound + rationale as _dec_fetch_outside). Any failed page fails the WHOLE
    # sweep: a half-fetched list would sweep clean over the missing half.
    local swdir label page n li=0
    swdir=$(mktemp -d)
    for label in "$DECISIONS_LABEL" "decision::wanted"; do
        li=$((li+1)); page=1
        while :; do
            if ! printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok" | curl -sS -f -K - --get \
                --data-urlencode "labels=${label}" \
                --data-urlencode "state=opened" \
                --data-urlencode "per_page=100" \
                --data-urlencode "page=${page}" \
                "https://${host}/api/v4/projects/${DECISIONS_PROJECT}/issues" \
                > "$swdir/l${li}-p$(printf '%03d' "$page").json" 2>/dev/null; then
                impact_rm_scratch "$swdir" >/dev/null
                print_error "CANNOT-VERIFY: the '${label}' issue fetch failed — the sweep could not look."
                return 2
            fi
            n=$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
print(len(d) if isinstance(d, list) else -1)' \
                "$swdir/l${li}-p$(printf '%03d' "$page").json" 2>/dev/null) || n=-1
            if [ "$n" -lt 0 ] 2>/dev/null; then
                impact_rm_scratch "$swdir" >/dev/null
                print_error "CANNOT-VERIFY: unparseable page from the tracker — the sweep could not look."
                return 2
            fi
            [ "$n" -lt 100 ] && break
            page=$((page+1))
            [ "$page" -gt 20 ] && break
        done
    done
    python3 -c 'import glob, json, sys
merged, seen = [], set()
for p in sorted(glob.glob(sys.argv[1] + "/l*-p*.json")):
    for i in json.load(open(p)):
        if i.get("iid") not in seen:
            seen.add(i.get("iid")); merged.append(i)
json.dump(merged, open(sys.argv[2], "w"))' "$swdir" "$swdir/issues.json" 2>/dev/null || {
        impact_rm_scratch "$swdir" >/dev/null
        print_error "CANNOT-VERIFY: could not merge the fetched pages."
        return 2
    }

    # Full notes per candidate issue. A failed fetch leaves no file, which the
    # classifier declares UNKNOWN and grades the whole run exit 2 — an issue
    # whose conversation is unreadable might carry an approval.
    local notesdir iid
    notesdir="$swdir/notes"; mkdir -p "$notesdir"
    for iid in $(python3 -c 'import json,sys
for i in json.load(open(sys.argv[1])): print(i["iid"])' "$swdir/issues.json" 2>/dev/null); do
        _sweep_fetch_notes_one "$iid" "$notesdir/$iid.json" || rm -f "$notesdir/$iid.json"
    done

    local sweep_rc
    python3 "$PROJECT_ROOT/scripts/lib/decisions-sweep.py" "$mode" "$swdir/issues.json" "$notesdir"
    sweep_rc=$?

    if [ "$discharge" != true ]; then
        impact_rm_scratch "$swdir" >/dev/null
        return $sweep_rc
    fi

    # ── the discharge half ────────────────────────────────────────────────────
    # One PUT per listed issue; the removal is believed only when the PUT's
    # response no longer shows either label (same verify-from-response shape as
    # cmd_promote). Every verified discharge gets a ledger line — an
    # unledgered label drop is indistinguishable from drift.
    local rows ledger now dfail=0
    rows=$(python3 "$PROJECT_ROOT/scripts/lib/decisions-sweep.py" json "$swdir/issues.json" "$notesdir" \
        | python3 -c 'import json,sys
for r in json.load(sys.stdin)["rows"]:
    print("%s\t%s\t%s\t%s" % (r["iid"], r["approved_times"], r["approved_when"], ",".join(r["decision_labels"])))')
    ledger="$PROJECT_ROOT/private/decisions-discharge.log"
    mkdir -p "$PROJECT_ROOT/private"
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local d_iid d_times d_when d_labels resp
    while IFS=$'\t' read -r d_iid d_times d_when d_labels; do
        [ -n "$d_iid" ] || continue
        resp=$(printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok" | curl -sS -f -K - -X PUT \
            -H "Content-Type: application/json" \
            --data '{"remove_labels":"needs-decision,decision::wanted"}' \
            "https://${host}/api/v4/projects/${DECISIONS_PROJECT}/issues/${d_iid}" 2>/dev/null)
        if [ $? -ne 0 ] || ! printf '%s' "$resp" | python3 -c '
import json,sys
i = json.load(sys.stdin)
labels = i.get("labels") or []
sys.exit(1 if ("needs-decision" in labels or "decision::wanted" in labels) else 0)'; then
            print_error "discharge FAILED for nwp/ops#${d_iid} — labels left as they were; it stays in the queue."
            dfail=$((dfail+1))
            continue
        fi
        printf '%s iid=%s removed=%s approved_times=%s approved_when=%s by=sweep-approved ref=ops#327\n' \
            "$now" "$d_iid" "$d_labels" "$d_times" "$d_when" >> "$ledger"
        print_status "OK" "discharged nwp/ops#${d_iid}: removed ${d_labels} (approved ${d_times}x, last ${d_when})"
    done <<< "$rows"
    impact_rm_scratch "$swdir" >/dev/null
    [ "$dfail" -gt 0 ] && return 1
    return $sweep_rc
}

cmd_decisions(){
    local mode="text" only="" all=false
    if [ "${1:-}" = "promote" ]; then shift; cmd_promote "$@"; return $?; fi
    if [ "${1:-}" = "sweep-approved" ]; then shift; cmd_sweep_approved "$@"; return $?; fi
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) mode="json"; shift ;;
            --all)  all=true; shift ;;
            -h|--help)
                sed -n '3,86p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
