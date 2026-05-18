#!/usr/bin/env bats
################################################################################
# Unit tests for lib/ci-stats.sh
#
# Run:
#   bats tests/unit/test-ci-stats.bats
################################################################################

load ../helpers/test-helpers

setup() {
    test_setup
    export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
    # Each test gets its own isolated stats directory
    export CI_STATS_DIR="${BATS_TEST_TMPDIR}/.ci-stats"
    mkdir -p "${CI_STATS_DIR}"
    # Lower the bootstrap floor so individual tests don't have to write 5+ samples
    export CI_STATS_BOOTSTRAP_MIN=5
    export CI_STATS_WINDOW=20
    export CI_STATS_REGRESSION_FACTOR=1.5
    # Source under test
    source "${PROJECT_ROOT}/lib/ci-stats.sh"
}

teardown() {
    test_teardown
}

################################################################################
# ci_stats_record
################################################################################

@test "record: appends a sample to the metric TSV" {
    run ci_stats_record "test.metric" "42"
    [ "$status" -eq 0 ]
    [ -f "${CI_STATS_DIR}/test.metric.tsv" ]
    lines=$(wc -l < "${CI_STATS_DIR}/test.metric.tsv")
    [ "$lines" -eq 1 ]
}

@test "record: accepts decimal values" {
    run ci_stats_record "test.metric" "3.14"
    [ "$status" -eq 0 ]
    grep -q $'\t3.14\t' "${CI_STATS_DIR}/test.metric.tsv"
}

@test "record: rejects non-numeric values" {
    run ci_stats_record "test.metric" "not-a-number"
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be numeric"* ]]
}

@test "record: rejects invalid metric names" {
    run ci_stats_record "Test Metric!" "42"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid metric name"* ]]
}

@test "record: rejects empty metric name" {
    run ci_stats_record "" "42"
    [ "$status" -eq 1 ]
    [[ "$output" == *"required"* ]]
}

@test "record: accepts outcome=success (default)" {
    run ci_stats_record "test.metric" "42"
    [ "$status" -eq 0 ]
    grep -q $'\tsuccess$' "${CI_STATS_DIR}/test.metric.tsv"
}

@test "record: accepts outcome=failure" {
    run ci_stats_record "test.metric" "42" "failure"
    [ "$status" -eq 0 ]
    grep -q $'\tfailure$' "${CI_STATS_DIR}/test.metric.tsv"
}

@test "record: rejects invalid outcome" {
    run ci_stats_record "test.metric" "42" "borked"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid outcome"* ]]
}

@test "record: trims to CI_STATS_WINDOW successful samples" {
    export CI_STATS_WINDOW=5
    for i in 1 2 3 4 5 6 7 8 9 10; do
        ci_stats_record "test.metric" "$i" >/dev/null
    done
    local n
    n=$(ci_stats_n "test.metric")
    [ "$n" -eq 5 ]
}

################################################################################
# ci_stats_n
################################################################################

@test "n: returns 0 for unknown metric" {
    run ci_stats_n "nonexistent"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "n: counts only successful samples" {
    ci_stats_record "test.metric" "1" "success" >/dev/null
    ci_stats_record "test.metric" "2" "failure" >/dev/null
    ci_stats_record "test.metric" "3" "skip" >/dev/null
    ci_stats_record "test.metric" "4" "success" >/dev/null
    run ci_stats_n "test.metric"
    [ "$output" = "2" ]
}

################################################################################
# ci_stats_p95
################################################################################

@test "p95: returns empty for unknown metric" {
    run ci_stats_p95 "nonexistent"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "p95: returns single value when only one sample" {
    ci_stats_record "test.metric" "42" >/dev/null
    run ci_stats_p95 "test.metric"
    [ "$output" = "42" ]
}

@test "p95: ignores non-success samples" {
    ci_stats_record "test.metric" "1" "success" >/dev/null
    ci_stats_record "test.metric" "999" "failure" >/dev/null
    run ci_stats_p95 "test.metric"
    [ "$output" = "1" ]
}

@test "p95: 20 samples 1..20 yields ~19" {
    for i in $(seq 1 20); do
        ci_stats_record "test.metric" "$i" >/dev/null
    done
    run ci_stats_p95 "test.metric"
    # p95 of 1..20 is index 19 (rounded from 19.0)
    [ "$output" = "19" ]
}

@test "p95: trims a single extreme outlier" {
    # 9 samples around 10, one outlier at 1000 (>3× median should be dropped)
    for v in 10 11 10 12 10 11 12 10 11; do
        ci_stats_record "test.metric" "$v" >/dev/null
    done
    ci_stats_record "test.metric" "1000" >/dev/null
    run ci_stats_p95 "test.metric"
    # With outlier trimmed, p95 of remaining 9 values 10..12 should be 12
    [ "$output" = "12" ]
}

################################################################################
# ci_stats_check — bootstrap mode (n < CI_STATS_BOOTSTRAP_MIN)
################################################################################

@test "check: returns 0 with warning when no history and no bootstrap config" {
    run ci_stats_check "unseen.metric" "100"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no history"* ]]
}

@test "check: uses bootstrap threshold when n<5 and config exists" {
    cat > "${CI_STATS_DIR}/bootstrap.yml" <<EOF
metrics:
  test.metric: 50
EOF
    # In-band
    run ci_stats_check "test.metric" "40"
    [ "$status" -eq 0 ]
    [[ "$output" != *"exceeds"* ]]
    # Out of band, warn mode
    run ci_stats_check "test.metric" "100" "warn"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exceeds threshold"* ]]
    [[ "$output" == *"bootstrap"* ]]
}

@test "check: fail mode returns 1 on bootstrap regression" {
    cat > "${CI_STATS_DIR}/bootstrap.yml" <<EOF
metrics:
  test.metric: 50
EOF
    run ci_stats_check "test.metric" "100" "fail"
    [ "$status" -eq 1 ]
    [[ "$output" == *"exceeds threshold"* ]]
}

################################################################################
# ci_stats_check — adaptive mode (n >= CI_STATS_BOOTSTRAP_MIN)
################################################################################

@test "check: adaptive band — value within 1.5×p95 returns 0" {
    for i in 10 10 10 10 10 10 10; do
        ci_stats_record "test.metric" "$i" >/dev/null
    done
    # p95=10, threshold=15; value=12 is in-band
    run ci_stats_check "test.metric" "12"
    [ "$status" -eq 0 ]
    [[ "$output" != *"exceeds"* ]]
}

@test "check: adaptive band — value beyond 1.5×p95 warns" {
    for i in 10 10 10 10 10 10 10; do
        ci_stats_record "test.metric" "$i" >/dev/null
    done
    # p95=10, threshold=15; value=20 is out-of-band
    run ci_stats_check "test.metric" "20" "warn"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exceeds threshold"* ]]
    [[ "$output" == *"adaptive"* ]]
}

@test "check: adaptive band — fail mode returns 1 on regression" {
    for i in 10 10 10 10 10 10 10; do
        ci_stats_record "test.metric" "$i" >/dev/null
    done
    run ci_stats_check "test.metric" "20" "fail"
    [ "$status" -eq 1 ]
}

@test "check: invalid mode is rejected" {
    run ci_stats_check "test.metric" "10" "borked"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid mode"* ]]
}

################################################################################
# ci_stats_band
################################################################################

@test "band: echoes low and high tuple" {
    for i in 10 10 10 10 10 10 10; do
        ci_stats_record "test.metric" "$i" >/dev/null
    done
    run ci_stats_band "test.metric"
    [ "$status" -eq 0 ]
    # p95=10, factor=1.5, so high=15
    [ "$output" = "0 15" ]
}

@test "band: bootstrap mode echoes bootstrap value as high" {
    cat > "${CI_STATS_DIR}/bootstrap.yml" <<EOF
metrics:
  test.metric: 50
EOF
    run ci_stats_band "test.metric"
    [ "$output" = "0 50" ]
}

@test "band: shows (none) when no history and no bootstrap" {
    run ci_stats_band "unseen.metric"
    [[ "$output" == *"(none)"* ]]
}

################################################################################
# CLI dispatch
################################################################################

@test "CLI: record + p95 round-trip via subcommand interface" {
    run "${PROJECT_ROOT}/lib/ci-stats.sh" record "cli.test" "42"
    [ "$status" -eq 0 ]
    run "${PROJECT_ROOT}/lib/ci-stats.sh" p95 "cli.test"
    [ "$status" -eq 0 ]
    [ "$output" = "42" ]
}

@test "CLI: unknown subcommand exits non-zero" {
    run "${PROJECT_ROOT}/lib/ci-stats.sh" frobnicate
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown subcommand"* ]]
}

@test "CLI: help subcommand exits 0 and prints usage" {
    run "${PROJECT_ROOT}/lib/ci-stats.sh" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"USAGE:"* ]]
    [[ "$output" == *"record"* ]]
}
