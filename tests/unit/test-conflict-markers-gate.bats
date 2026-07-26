#!/usr/bin/env bats
# =============================================================================
# tests/unit/test-conflict-markers-gate.bats — scripts/ci/lint-conflict-markers.sh
# =============================================================================
# On 2026-07-26 commit 3c4c631 was pushed with an unresolved merge in
# docs/reports/consolidation-arc-2026-07/decision-log.md and its MR went GREEN:
# lint:bash, lint:yq-first, lint:leakage, lint:doc-truth, the unit suite and the
# integration suite all passed over a file containing `<<<<<<< HEAD`. Nothing in
# the pipeline looked for conflict markers. This file pins the gate that now does.
#
# Fixtures are real git repos and the markers are ASSEMBLED at runtime, so this
# test file does not itself contain a conflict marker (which would make the gate
# fail on the repo that ships it).

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    GATE="$REPO_ROOT/scripts/ci/lint-conflict-markers.sh"

    OPEN="$(printf '<%.0s' 1 2 3 4 5 6 7)"
    CLOSE="$(printf '>%.0s' 1 2 3 4 5 6 7)"
    BASE="$(printf '|%.0s' 1 2 3 4 5 6 7)"
    MID="$(printf '=%.0s' 1 2 3 4 5 6 7)"

    FIX="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$FIX"
    cp "$GATE" "$BATS_TEST_TMPDIR/gate.sh"
    mkdir -p "$FIX/scripts/ci"
    cp "$GATE" "$FIX/scripts/ci/lint-conflict-markers.sh"
    cd "$FIX" || return 1
    git init -q .
    git config user.email a@b.c
    git config user.name t
    echo "hello" > README.md
    git add -A
    git commit -q -m base
}

run_gate() { ( cd "$FIX" && ./scripts/ci/lint-conflict-markers.sh ); }

@test "gate is green on a clean tracked tree" {
    run run_gate
    [ "$status" -eq 0 ]
    [[ "$output" == OK* ]]
}

@test "gate REDDENS on the exact shape that reached main (open/mid/close)" {
    { echo "before"; echo "${OPEN} HEAD"; echo "ours"; echo "$MID"
      echo "theirs"; echo "${CLOSE} abc123 (some commit)"; echo "after"; } > doc.md
    git add -A && git commit -q -m c
    run run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"CONFLICT MARKERS: doc.md"* ]]
    [[ "$output" == *"keep BOTH sides"* ]]
}

@test "gate REDDENS on a diff3 base-section marker" {
    { echo "${OPEN} HEAD"; echo "a"; echo "${BASE} base"; echo "b"; } > d3.md
    git add -A && git commit -q -m c
    run run_gate
    [ "$status" -eq 1 ]
}

# The append-only arc docs are the ones that actually got corrupted.
@test "gate REDDENS on a corrupted decision log specifically" {
    mkdir -p docs/reports/consolidation-arc-2026-07
    { echo "## entry"; echo "${OPEN} HEAD"; echo "x"; echo "$MID"; echo "y"
      echo "${CLOSE} deadbee (msg)"; } \
      > docs/reports/consolidation-arc-2026-07/decision-log.md
    git add -A && git commit -q -m c
    run run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"decision-log.md"* ]]
}

# --------------------------------------------------------------------------
# NEGATIVE CONTROLS — a gate that reddens on ordinary docs gets deleted.
# --------------------------------------------------------------------------

@test "NEGATIVE CONTROL: a Markdown setext H1 underline is NOT a conflict" {
    { echo "A Heading"; echo "$MID"; echo ""; echo "prose"; } > setext.md
    git add -A && git commit -q -m c
    run run_gate
    [ "$status" -eq 0 ]
}

@test "NEGATIVE CONTROL: prose that mentions the markers inline is NOT a conflict" {
    { echo "Resolve the ${OPEN} HEAD and ${CLOSE} lines by keeping both sides."; } > prose.md
    git add -A && git commit -q -m c
    run run_gate
    [ "$status" -eq 0 ]      # not at line start
}

@test "NEGATIVE CONTROL: an UNTRACKED file with markers does not fail the build" {
    { echo "${OPEN} HEAD"; echo "$MID"; echo "${CLOSE} abc (m)"; } > scratch.md
    run run_gate
    [ "$status" -eq 0 ]
}

# --------------------------------------------------------------------------
# Fail-closed + self-scan.
# --------------------------------------------------------------------------

@test "gate CANNOT-VERIFY (exit 2) outside a git repository" {
    mkdir -p "$BATS_TEST_TMPDIR/bare/scripts/ci"
    cp "$GATE" "$BATS_TEST_TMPDIR/bare/scripts/ci/lint-conflict-markers.sh"
    run bash -c "cd '$BATS_TEST_TMPDIR/bare' && ./scripts/ci/lint-conflict-markers.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "the gate does not flag ITSELF (patterns are repetition-form, not literals)" {
    run bash -c "grep -cE '^(<{7}|>{7}|\|{7}) ' '$GATE' || true"
    [ "$output" -eq 0 ]
}

@test "the REAL repo is clean under this gate" {
    run bash -c "cd '$REPO_ROOT' && ./scripts/ci/lint-conflict-markers.sh"
    [ "$status" -eq 0 ]
}
