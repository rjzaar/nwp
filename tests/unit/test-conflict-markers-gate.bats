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

# --------------------------------------------------------------------------
# DOCUMENTING the markers must not be the same as HAVING them. The arc decision
# log records the 3c4c631 finding, and the natural write-up is a fenced example
# of exactly what the gate hunts for. The first version of this gate reddened on
# that — it blocked main on its own bug report.
# --------------------------------------------------------------------------

@test "NEGATIVE CONTROL: a doc that SHOWS a conflict in a fenced block is ALLOWED" {
    { echo "## Conflict markers reached main"; echo ""; echo '```'
      echo "${OPEN} HEAD"; echo "ours"; echo "$MID"; echo "theirs"
      echo "${CLOSE} c6ba428 (some commit)"; echo '```'; echo ""
      echo "Fixed by the gate."; } > writeup.md
    git add -A && git commit -q -m c
    run run_gate
    [ "$status" -eq 0 ]
}

@test "a fenced exemption is ANNOUNCED, never silent" {
    { echo '```'; echo "${OPEN} HEAD"; echo "$MID"; echo "${CLOSE} abc (m)"; echo '```'; } > ex.md
    git add -A && git commit -q -m c
    run run_gate
    [ "$status" -eq 0 ]
    [[ "$output" == *"note: ex.md"* ]]
    [[ "$output" == *"exempted inside fenced code block"* ]]
}

@test "tilde fences count too" {
    { echo '~~~'; echo "${OPEN} HEAD"; echo "$MID"; echo "${CLOSE} abc (m)"; echo '~~~'; } > tilde.md
    git add -A && git commit -q -m c
    run run_gate
    [ "$status" -eq 0 ]
}

# The exemption must not become a way to hide a real conflict.
@test "a marker OUTSIDE the fence still fails, even in a file that has fences" {
    { echo '```'; echo "code sample"; echo '```'; echo ""
      echo "${OPEN} HEAD"; echo "$MID"; echo "${CLOSE} abc (m)"; } > mixed.md
    git add -A && git commit -q -m c
    run run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"mixed.md"* ]]
}

@test "FAIL-CLOSED: an UNBALANCED fence exempts nothing" {
    # Open a fence and never close it — an obvious way to try to hide a merge.
    { echo '```'; echo "${OPEN} HEAD"; echo "$MID"; echo "${CLOSE} abc (m)"; } > unbalanced.md
    git add -A && git commit -q -m c
    run run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"unbalanced.md"* ]]
}

# The fence exemption is markdown-only: a .sh or .yml file has no such notion.
@test "fences do NOT exempt anything in a non-markdown file" {
    { echo '```'; echo "${OPEN} HEAD"; echo "$MID"; echo "${CLOSE} abc (m)"; echo '```'; } > thing.sh
    git add -A && git commit -q -m c
    run run_gate
    [ "$status" -eq 1 ]
}

@test "NEGATIVE CONTROL: markdown horizontal rules are NOT conflicts" {
    { echo "para one"; echo ""; echo "---"; echo ""; echo "***"; echo ""
      echo "___"; echo ""; echo "para two"; } > hr.md
    git add -A && git commit -q -m c
    run run_gate
    [ "$status" -eq 0 ]
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
