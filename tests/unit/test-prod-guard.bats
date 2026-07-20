#!/usr/bin/env bats
################################################################################
# Unit tests for lib/prod-guard.sh — the scratch-distinct sanitiser guard
# (ops#113 / ADR-0032). Docker-free, secret-free.
################################################################################

source "${BATS_TEST_DIRNAME}/../../lib/prod-guard.sh"

# ── happy path ────────────────────────────────────────────────────────────────

@test "scratch_distinct: allows a distinct scratch DB" {
    run prod_guard_scratch_distinct "ssmoodle" "ssmoodle_sanitize_scratch"
    [ "$status" -eq 0 ]
}

@test "scratch_distinct: allows when the suffix matches" {
    run prod_guard_scratch_distinct "ssmoodle" "ssmoodle_sanitize_scratch" "_sanitize_scratch"
    [ "$status" -eq 0 ]
}

# ── fail-closed: the catastrophic case (scratch == live) ─────────────────────

@test "scratch_distinct: REFUSES when scratch equals live (would mutate prod)" {
    run prod_guard_scratch_distinct "ssmoodle" "ssmoodle"
    [ "$status" -eq 1 ]
    [[ "$output" == *"equals the LIVE DB"* ]]
}

@test "scratch_distinct: REFUSES a case-only difference (MySQL may fold case)" {
    run prod_guard_scratch_distinct "ProdDB" "proddb"
    [ "$status" -eq 1 ]
    [[ "$output" == *"equals the LIVE DB"* ]]
}

# ── fail-closed: empty / missing names ────────────────────────────────────────

@test "scratch_distinct: REFUSES an empty scratch DB (blank suffix bug)" {
    run prod_guard_scratch_distinct "ssmoodle" ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"scratch DB name is empty"* ]]
}

@test "scratch_distinct: REFUSES an empty live DB" {
    run prod_guard_scratch_distinct "" "something_scratch"
    [ "$status" -eq 1 ]
    [[ "$output" == *"live DB name is empty"* ]]
}

# ── fail-closed: wrong suffix (scratch didn't come from our naming) ──────────

@test "scratch_distinct: REFUSES when the expected suffix is absent" {
    run prod_guard_scratch_distinct "ssmoodle" "some_other_db" "_sanitize_scratch"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not end with the expected suffix"* ]]
}

@test "scratch_distinct: sourcing the lib does not change shell flags" {
    before="$-"
    source "${BATS_TEST_DIRNAME}/../../lib/prod-guard.sh"
    [ "$-" = "$before" ]
}
