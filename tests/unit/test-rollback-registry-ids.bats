#!/usr/bin/env bats
#
# The rollback registry's checkpoint ids must resolve to exactly one row.
#
# Context: on 2026-07-26 the arc registry held CP19 x3, CP20 x4, CP21 x3,
# CP22 x2, because three agents each read the file, each saw CP18 as the
# highest, and each allocated the next four. CP19 named BOTH "item 2
# recovery-path-repair" AND "item 3 nested-repo-containment" — two different
# restore procedures under one name, in the document an operator reaches for
# during an incident.
#
# Every case below drives the real script over a real file. There is no case
# here that asserts on the script's SOURCE TEXT.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    GATE="$REPO_ROOT/scripts/ci/lint-rollback-registry-ids.sh"
    TMP="$(mktemp -d)"
    # The gate walks docs/reports/**/rollback-registry.md relative to its own
    # ../.., so a sandbox needs that shape plus a copy of the script.
    mkdir -p "$TMP/scripts/ci" "$TMP/docs/reports/arc"
    cp "$GATE" "$TMP/scripts/ci/"
    SANDBOX_GATE="$TMP/scripts/ci/lint-rollback-registry-ids.sh"
    REG="$TMP/docs/reports/arc/rollback-registry.md"
}

teardown() { rm -rf "$TMP"; }

_row() { printf '| %s | 2026-07-26 | %s | — | — | git revert |\n' "$1" "$2"; }

_header() {
    printf '# Rollback registry\n\n| ID | Date | What | Backup | Where | How |\n|---|---|---|---|---|---|\n'
}

@test "a registry with unique ids passes" {
    { _header; _row CP0 a; _row CP1 b; _row CP-I3 c; } > "$REG"
    run "$SANDBOX_GATE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"all ids unique"* ]]
}

@test "a duplicated id FAILS and names both rows" {
    { _header; _row CP19 "item 2 recovery-path-repair"; _row CP20 x; _row CP19 "item 3 containment"; } > "$REG"
    run "$SANDBOX_GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"DUPLICATE CHECKPOINT IDS"* ]]
    [[ "$output" == *"CP19"* ]]
    # both conflicting rows must be shown — naming only one is how you fix the
    # wrong one
    [[ "$output" == *"recovery-path-repair"* ]]
    [[ "$output" == *"containment"* ]]
}

@test "three rows under one id are all reported" {
    { _header; _row CP20 a; _row CP20 b; _row CP20 c; } > "$REG"
    run "$SANDBOX_GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"used by 3 rows"* ]]
}

@test "item-scoped ids are NOT required to be contiguous or numeric" {
    # Deliberate: demanding a dense integer sequence pushes authors back onto
    # the shared counter that caused the collisions in the first place.
    { _header; _row CP0 a; _row CP-nwc b; _row CP-I8b c; _row CP31 d; } > "$REG"
    run "$SANDBOX_GATE"
    [ "$status" -eq 0 ]
}

@test "FAIL-CLOSED: a registry with no recognisable rows is CANNOT VERIFY, not a pass" {
    { printf '# Rollback registry\n\nNothing here yet.\n'; } > "$REG"
    run "$SANDBOX_GATE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "FAIL-CLOSED: no registry at all is CANNOT VERIFY, not a pass" {
    rm -rf "$TMP/docs"
    run "$SANDBOX_GATE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "a duplicate in ANY registry fails, not just the first" {
    mkdir -p "$TMP/docs/reports/arc2"
    { _header; _row CP0 a; } > "$REG"
    { _header; _row CP5 a; _row CP5 b; } > "$TMP/docs/reports/arc2/rollback-registry.md"
    run "$SANDBOX_GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"arc2"* ]]
}

@test "an id that merely CONTAINS another id is not a false duplicate" {
    { _header; _row CP2 a; _row CP20 b; _row CP2b c; } > "$REG"
    run "$SANDBOX_GATE"
    [ "$status" -eq 0 ]
}

@test "prose mentioning a CP id outside a table row does not trigger it" {
    { _header; _row CP1 a; printf '\nSee CP1 above; CP1 is the baseline.\n'; } > "$REG"
    run "$SANDBOX_GATE"
    [ "$status" -eq 0 ]
}

@test "THE REAL REGISTRY in this repo has unique checkpoint ids" {
    # The regression case. This is the assertion that would have caught the
    # 2026-07-26 collision, and it runs against the tree, not a fixture.
    run "$GATE"
    [ "$status" -eq 0 ]
}
