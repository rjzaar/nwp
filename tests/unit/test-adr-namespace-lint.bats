#!/usr/bin/env bats
#
# Acceptance tests for scripts/ci/lint-adr-namespace.sh (ops#383).
#
# Every case here was written to FAIL against a tree without the gate, and each
# asserts the ERROR TEXT rather than merely "exited non-zero" — a blind `! cmd`
# proves only that something went wrong, which is the estate's recorded
# failure shape (CLAUDE.md, "blind negation").
#
# The gate's whole claim is that a bare `ADR-NNNN` is indistinguishable between
# three decision series, so the tests that matter are the COLLISION ones: the
# same number, present in the engine directory, referenced bare, must be
# reported — and reported WITH the document it would wrongly resolve into.

setup() {
    PROJECT_ROOT="$( cd "$( dirname "$BATS_TEST_FILENAME" )/../.." && pwd )"
    export PROJECT_ROOT
    LINT="$PROJECT_ROOT/scripts/ci/lint-adr-namespace.sh"

    FIX="$BATS_TEST_TMPDIR/fixture"
    mkdir -p "$FIX/docs/decisions" "$FIX/docs/onboarding"
    git -C "$FIX" init -q
    git -C "$FIX" config user.email t@example.com
    git -C "$FIX" config user.name  t

    # A real engine ADR, so a bare reference has something to wrongly resolve to.
    printf '# NWP-ADR-0020: Tiered architecture model\n' \
        > "$FIX/docs/decisions/0020-tiered-architecture-model.md"
}

run_lint() { PROJECT_ROOT="$FIX" run "$LINT" "$@"; }

# ---------------------------------------------------------------------------
# The defect this gate exists for
# ---------------------------------------------------------------------------

@test "a bare ADR-NNNN FAILS, and is named as bare" {
    printf 'See ADR-0020 for the editorial state machine.\n' > "$FIX/docs/onboarding/adrs.md"
    run_lint
    [ "$status" -eq 1 ]
    [[ "$output" == *"lint:adr-namespace — FAIL"* ]]
    [[ "$output" == *"docs/onboarding/adrs.md"* ]]
    [[ "$output" == *"ADR-0020"* ]]
    [[ "$output" == *"(bare)"* ]]
}

@test "the failure NAMES the document a bare reference would wrongly resolve into" {
    # This is the collision that went unnoticed since 2026-05-20: the onboarding
    # page's ADR-0020 meant "editorial state machine"; docs/decisions/0020-*.md
    # is the tiered architecture model. Asserting only "it failed" would not
    # prove the gate can tell anyone WHY.
    printf 'See ADR-0020 for the editorial state machine.\n' > "$FIX/docs/onboarding/adrs.md"
    run_lint
    [ "$status" -eq 1 ]
    [[ "$output" == *"resolves TODAY against docs/decisions/0020-"* ]]
    [[ "$output" == *"tiered architecture model"* ]]
}

@test "a bare reference to a number with NO engine ADR is reported too, and says so" {
    # docs/onboarding/adrs.md invented 0040/0050/0051/0060/0061/0070 — numbers
    # that named no file in any repo. Those must not read as "fine, nothing to
    # collide with"; an unresolvable reference is still a defective reference.
    printf 'See ADR-0050 for the deploy pipeline.\n' > "$FIX/docs/guides/g.md" 2>/dev/null \
        || { mkdir -p "$FIX/docs/guides"; printf 'See ADR-0050.\n' > "$FIX/docs/guides/g.md"; }
    run_lint
    [ "$status" -eq 1 ]
    [[ "$output" == *"ADR-0050"* ]]
    [[ "$output" == *"resolves against NO engine ADR"* ]]
}

# ---------------------------------------------------------------------------
# What the gate must ACCEPT — a gate that fails on everything is not a gate
# ---------------------------------------------------------------------------

@test "NWP-ADR-NNNN passes" {
    printf 'See NWP-ADR-0020.\n' > "$FIX/docs/onboarding/adrs.md"
    run_lint
    [ "$status" -eq 0 ]
    [[ "$output" == *"lint:adr-namespace — OK"* ]]
}

@test "NWC- and AVC- prefixes pass — profile series are citable, not resolvable here" {
    printf 'See NWC-ADR-0020 and AVC-ADR-0003.\n' > "$FIX/docs/onboarding/adrs.md"
    run_lint
    [ "$status" -eq 0 ]
}

@test "a prefixed reference is NOT re-flagged by the substring inside it" {
    # `NWP-ADR-0020` contains the substring `ADR-0020`. A naive scanner reports
    # every fixed reference as still broken, which would make the gate
    # unclearable — so this asserts the fix actually clears.
    printf 'NWP-ADR-0020 NWP-ADR-0020 NWP-ADR-0020\n' > "$FIX/docs/onboarding/adrs.md"
    run_lint
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# A typo'd prefix must not read as a new namespace
# ---------------------------------------------------------------------------

@test "an UNRECOGNISED prefix fails and is distinguished from bare" {
    printf 'See FOO-ADR-0020.\n' > "$FIX/docs/onboarding/adrs.md"
    run_lint
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown-prefix:FOO"* ]]
}

# ---------------------------------------------------------------------------
# The literal escape — a doc must be able to NAME the disease
# ---------------------------------------------------------------------------

@test "a line marked adr-namespace:literal is skipped" {
    printf 'The old bare form ADR-0020 is what this gate refuses. <!-- adr-namespace:literal -->\n' \
        > "$FIX/docs/onboarding/adrs.md"
    run_lint
    [ "$status" -eq 0 ]
}

@test "the literal marker is PER-LINE, not per-file" {
    printf 'quoted ADR-0020 <!-- adr-namespace:literal -->\nlive ADR-0020 reference\n' \
        > "$FIX/docs/onboarding/adrs.md"
    run_lint
    [ "$status" -eq 1 ]
    [[ "$output" == *"line 2"* ]]
    [[ "$output" != *"line 1"* ]]
}

# ---------------------------------------------------------------------------
# Fail-closed: an unreadable corpus is not a clean corpus
# ---------------------------------------------------------------------------

@test "CANNOT VERIFY (exit 2) when the tree is not a git checkout" {
    notgit="$BATS_TEST_TMPDIR/notgit"; mkdir -p "$notgit"
    PROJECT_ROOT="$notgit" run "$LINT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
    [[ "$output" == *"not a git checkout"* ]]
}

@test "CANNOT VERIFY (exit 2) when the corpus scans to ZERO markdown files" {
    empty="$BATS_TEST_TMPDIR/empty"; mkdir -p "$empty"; git -C "$empty" init -q
    PROJECT_ROOT="$empty" run "$LINT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
    [[ "$output" == *"ZERO markdown files"* ]]
}

@test "an unreadable corpus file is CANNOT VERIFY, never a pass" {
    # Skipped for root, which can read a 000 file — a skip that silently became
    # a pass is the exact honesty defect the estate lints for.
    [ "$(id -u)" -ne 0 ] || skip "running as root: chmod 000 does not deny access"
    printf 'NWP-ADR-0020\n' > "$FIX/docs/onboarding/adrs.md"
    git -C "$FIX" add -A >/dev/null 2>&1
    chmod 000 "$FIX/docs/onboarding/adrs.md"
    run_lint
    chmod 644 "$FIX/docs/onboarding/adrs.md"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unreadable"* ]]
}

# ---------------------------------------------------------------------------
# Scope: the profile repos are a SEPARATE MR, and this gate must not claim them
# ---------------------------------------------------------------------------

@test "gitignored trees are NOT scanned — profile repos are not this repo's to fix" {
    mkdir -p "$FIX/sites/nwc"
    printf 'sites/\n' > "$FIX/.gitignore"
    printf 'See ADR-0020 (profile series).\n' > "$FIX/sites/nwc/notes.md"
    printf 'See NWP-ADR-0020.\n' > "$FIX/docs/onboarding/adrs.md"
    run_lint
    [ "$status" -eq 0 ]
    [[ "$output" != *"sites/nwc/notes.md"* ]]
}

@test "an untracked-but-not-ignored markdown file IS scanned" {
    # A doc an MR has added but not committed is exactly when a bad reference is
    # cheapest to catch.
    printf 'See ADR-0020.\n' > "$FIX/docs/new-and-uncommitted.md"
    run_lint
    [ "$status" -eq 1 ]
    [[ "$output" == *"docs/new-and-uncommitted.md"* ]]
}

# ---------------------------------------------------------------------------
# Interfaces the estate depends on
# ---------------------------------------------------------------------------

@test "--list is machine-readable and carries the same verdict" {
    printf 'See ADR-0020.\n' > "$FIX/docs/onboarding/adrs.md"
    run_lint --list
    [ "$status" -eq 1 ]
    [[ "$output" == *"docs/onboarding/adrs.md:1|bare|ADR-0020|"* ]]
}

@test "an unknown argument is CANNOT VERIFY, not a silent pass" {
    run_lint --no-such-flag
    [ "$status" -eq 2 ]
}

@test "the gate is wired into CI" {
    grep -q 'scripts/ci/lint-adr-namespace.sh' "$PROJECT_ROOT/.gitlab-ci.yml"
}

@test "the REAL repo is clean — the gate is green on the tree it ships with" {
    run "$LINT"
    [ "$status" -eq 0 ]
}

@test "there is deliberately NO baseline file for this gate" {
    # A baseline here would bank "these references are still ambiguous, on
    # purpose", which is not a state anyone wants. If someone adds one, this
    # fails and they have to argue for it in review.
    [ ! -e "$PROJECT_ROOT/.adr-namespace-baseline" ]
    ! grep -q -- '--update-baseline' "$PROJECT_ROOT/scripts/ci/lint-adr-namespace.sh"
}
