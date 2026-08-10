#!/usr/bin/env bats
#
# `pl decisions sweep-approved` — the backlog half of the ops#327 fix.
#
# WHY. The console Review pane's Approve button posted a `[console-review]
# APPROVED` note that NOTHING consumed: the decision labels stayed on the
# issue, the issue stayed in the queue, and the operator re-approved #139
# FOUR times. #74 / #101 / #139 all sat in the exact state these tests
# construct: an approving note on the record, `decision::wanted` /
# `needs-decision` still on the issue. The Approve action now discharges
# (console side, pytest-covered); this verb finds and clears the residue.
#
# The classifier is pure (scripts/lib/decisions-sweep.py, files in → report
# out) exactly like decisions-render.py, so the failing state is a FIXTURE
# here and the network shell stays thin.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SWEEP="$REPO_ROOT/scripts/lib/decisions-sweep.py"
    TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/decsweep.XXXXXX")"
    mkdir -p "$TMP/notes"
}
teardown() { rm -rf "$TMP"; }

# Issues file: one row per spec "iid|labels-csv[|title]" ("|" because the
# labels themselves contain colons: decision::wanted).
_issues() { # file spec...
    local out="$1"; shift
    python3 - "$out" "$@" <<'PY'
import json, sys
out = sys.argv[1]
rows = []
for spec in sys.argv[2:]:
    parts = spec.split("|", 2)
    iid, labels = parts[0], parts[1]
    title = parts[2] if len(parts) > 2 else f"Issue {iid}"
    rows.append({"iid": int(iid), "title": title,
                 "web_url": f"https://h/nwp/ops/-/issues/{iid}",
                 "labels": [l for l in labels.split(",") if l]})
json.dump(rows, open(out, "w"))
PY
}

# Notes file for one issue: each arg is one note body; "SYSTEM:" prefix marks
# a system note (label events etc. — the API returns those too).
_notes() { # iid body...
    local iid="$1"; shift
    python3 - "$TMP/notes/$iid.json" "$@" <<'PY'
import json, sys
out = sys.argv[1]
notes = []
for i, body in enumerate(sys.argv[2:]):
    system = body.startswith("SYSTEM:")
    notes.append({"body": body.removeprefix("SYSTEM:"), "system": system,
                  "author": {"username": "project_21_bot_x"},
                  "created_at": f"2026-08-07T0{i}:00:00Z"})
json.dump(notes, open(out, "w"))
PY
}

CONSOLE_APPROVE='**[console-review]** APPROVED — proceed with the recommendation as written in the `## Decision` block of this issue.'

@test "RED-PROOF: an approved issue still carrying decision labels is LISTED (the #74/#101/#139 state)" {
    _issues "$TMP/issues.json" "139|decision::wanted,console|Voice loop decision"
    _notes 139 "$CONSOLE_APPROVE"
    run python3 "$SWEEP" text "$TMP/issues.json" "$TMP/notes"
    [ "$status" -eq 0 ]
    [[ "$output" == *"#139"* ]]
    [[ "$output" == *"Voice loop decision"* ]]
    [[ "$output" == *"decision::wanted"* ]]
}

@test "approved-times counts REPEAT approvals — the #139 re-approved-four-times evidence" {
    _issues "$TMP/issues.json" "139|needs-decision"
    _notes 139 "$CONSOLE_APPROVE" "$CONSOLE_APPROVE" "$CONSOLE_APPROVE" "$CONSOLE_APPROVE"
    run python3 "$SWEEP" text "$TMP/issues.json" "$TMP/notes"
    [ "$status" -eq 0 ]
    # 4 approvals, and the LATEST one's timestamp is the approved-when shown
    [[ "$output" == *"4"* ]]
    [[ "$output" == *"2026-08-07T03:00:00Z"* ]]
}

@test "an operator reply that says 'Approved.' counts, even without the console tag" {
    _issues "$TMP/issues.json" "74|decision::wanted"
    _notes 74 "Approved. Go with option B."
    run python3 "$SWEEP" text "$TMP/issues.json" "$TMP/notes"
    [ "$status" -eq 0 ]
    [[ "$output" == *"#74"* ]]
}

@test "a note that merely DISCUSSES approval does not count" {
    _issues "$TMP/issues.json" "101|decision::wanted"
    _notes 101 "Should we get this approved before Phase 2?" "The approver list is stale."
    run python3 "$SWEEP" text "$TMP/issues.json" "$TMP/notes"
    [ "$status" -eq 0 ]
    [[ "$output" != *"#101"* ]]
    [[ "$output" == *"0 undischarged"* ]]
}

@test "a SYSTEM note never counts as an approval" {
    # Label-event system notes can quote note text; a machine event is not an
    # operator ruling.
    _issues "$TMP/issues.json" "88|needs-decision"
    _notes 88 "SYSTEM:${CONSOLE_APPROVE}"
    run python3 "$SWEEP" text "$TMP/issues.json" "$TMP/notes"
    [ "$status" -eq 0 ]
    [[ "$output" != *"#88"* ]]
}

@test "an issue with no approving note is not listed" {
    _issues "$TMP/issues.json" "50|decision::wanted"
    _notes 50 "Adding context."
    run python3 "$SWEEP" text "$TMP/issues.json" "$TMP/notes"
    [ "$status" -eq 0 ]
    [[ "$output" != *"#50"* ]]
}

@test "FAIL-CLOSED: unreadable issues input is CANNOT-VERIFY exit 2, never empty-looks-clean" {
    printf 'not json' > "$TMP/issues.json"
    run python3 "$SWEEP" text "$TMP/issues.json" "$TMP/notes"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT-VERIFY"* ]]
    [[ "$output" != *"0 undischarged"* ]]
}

@test "FAIL-CLOSED: an issue whose notes could not be read is UNKNOWN + exit 2, not silently clean" {
    _issues "$TMP/issues.json" "60|decision::wanted" "61|decision::wanted"
    _notes 60 "$CONSOLE_APPROVE"
    # no notes file for 61 — the fetch failed; its approval state is unknowable
    run python3 "$SWEEP" text "$TMP/issues.json" "$TMP/notes"
    [ "$status" -eq 2 ]
    [[ "$output" == *"#60"* ]]
    [[ "$output" == *"#61"* ]]
    [[ "$output" == *"UNKNOWN"* ]]
    [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "--json carries the rows the discharger acts on" {
    _issues "$TMP/issues.json" "139|decision::wanted,needs-decision"
    _notes 139 "$CONSOLE_APPROVE" "$CONSOLE_APPROVE"
    run bash -c "python3 '$SWEEP' json '$TMP/issues.json' '$TMP/notes' | python3 -c \"
import json, sys
d = json.load(sys.stdin)
r = d['rows'][0]
print(r['iid'], r['approved_times'], sorted(r['decision_labels']), d['unknown'])\""
    [ "$status" -eq 0 ]
    [[ "$output" == "139 2 ['decision::wanted', 'needs-decision'] []" ]]
}

# ── the shell wiring: thin, but its guarantees are pinned in the source ──────

@test "the verb exists and fails closed at exit 2 when it cannot read the tracker" {
    grep -q 'sweep-approved' "$REPO_ROOT/scripts/commands/decisions.sh"
    # no token / no host / failed fetch => exit 2 CANNOT-VERIFY, never 'clean'
    grep -q 'CANNOT-VERIFY.*sweep' "$REPO_ROOT/scripts/commands/decisions.sh" \
        || grep -A3 'cmd_sweep_approved' "$REPO_ROOT/scripts/commands/decisions.sh" | grep -q 'CANNOT-VERIFY'
    grep -q 'return 2' "$REPO_ROOT/scripts/commands/decisions.sh"
}

@test "--discharge writes a ledger line per discharge" {
    grep -q 'decisions-discharge.log' "$REPO_ROOT/scripts/commands/decisions.sh"
}

@test "default mode REPORTS and does not mutate: no PUT outside the --discharge branch" {
    # The report path must be read-only; the single label-removing PUT lives
    # behind the --discharge flag.
    local puts
    puts=$(sed -n '/^cmd_sweep_approved/,/^}/p' "$REPO_ROOT/scripts/commands/decisions.sh" | grep -c 'X PUT')
    [ "$puts" -eq 1 ]
    sed -n '/^cmd_sweep_approved/,/^}/p' "$REPO_ROOT/scripts/commands/decisions.sh" \
        | grep -B8 'X PUT' | grep -q 'discharge'
}
