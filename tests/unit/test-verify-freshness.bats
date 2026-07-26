#!/usr/bin/env bats
#
# test-verify-freshness.bats — a verification result has an age.
#
# WHY THIS FILE EXISTS
#   `pl verify summary` reports
#
#       Automated Tests: 514/570 (90%)
#
#   and CLAUDE.md's release checklist tells the operator to gate a tag on that
#   number ("ensure 98%+ pass rate"). It is computed by counting
#   `machine.state.verified: true` in .verification.yml.
#
#   Every one of those 514 flags was written between 2026-01-11 and 2026-02-02.
#   Not one has been refreshed since. The repo has had hundreds of commits in
#   between. So the figure is not "90% of NWP is verified" — it is "90% of NWP
#   was verified against a tree that no longer exists", rendered in the same
#   green as a result from five minutes ago.
#
#   That is the vacuous-pass shape this programme keeps finding: a number that
#   cannot go red. Nothing decays. A verification run that never happens leaves
#   the coverage figure exactly where it was.
#
# CONTRACT
#   1. a machine verification carries a timestamp and that timestamp is READ;
#   2. `pl verify summary` distinguishes fresh evidence from stale evidence and
#      says so out loud when the stale share is material;
#   3. the freshness horizon is configuration, not a magic number;
#   4. `verify.sh ci` cannot report success over a run that wrote no results.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    VERIFY="$REPO_ROOT/scripts/commands/verify.sh"
    VFILE="$REPO_ROOT/.verification.yml"
}

# Build a .verification.yml fixture with one automatable item whose machine
# verification is $1 days old.
_fixture() {
    local age_days="$1" stamp
    stamp=$(date -u -d "-${age_days} days" +%Y-%m-%dT%H:%M:%S+00:00)
    cat > "$BATS_TEST_TMPDIR/.verification.yml" <<EOF
version: 3
config:
  machine_engine: verify.sh
  freshness_days: 90
statistics:
  total_items: 1
  machine:
    verified: 1
    coverage_percent: 100.0
  human:
    verified: 0
    coverage_percent: 0.0
  fully_verified: 0
features:
  demo:
    name: Demo
    description: fixture
    files:
    - pl
    checklist:
    - text: a thing that was verified once
      completed: false
      machine:
        basic:
          commands:
          - cmd: 'true'
            expect_exit: 0
        state:
          verified: true
          verified_at: '$stamp'
          depth: basic
          duration_seconds: 1
EOF
    printf '%s' "$BATS_TEST_TMPDIR/.verification.yml"
}

################################################################################
# 1. The timestamp must actually be read
################################################################################

@test "verify.sh can count machine verifications that are still fresh" {
    run bash -c "grep -q 'count_machine_verified_fresh_items' '$VERIFY'"
    [ "$status" -eq 0 ] || {
        echo "verify.sh counts machine.state.verified: true and nothing else." >&2
        echo "verified_at is written but never read, so a result from 2026-02-02" >&2
        echo "and a result from today are the same fact." >&2
        return 1
    }
}

@test "a verification older than the horizon does not count as fresh" {
    f="$(_fixture 400)"
    run env VERIFICATION_FILE="$f" bash -c "
        source '$VERIFY' --source-only 2>/dev/null || true
        VERIFICATION_FILE='$f' count_machine_verified_fresh_items
    "
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "0" ]
}

@test "a verification inside the horizon does count as fresh" {
    f="$(_fixture 3)"
    run env VERIFICATION_FILE="$f" bash -c "
        source '$VERIFY' --source-only 2>/dev/null || true
        VERIFICATION_FILE='$f' count_machine_verified_fresh_items
    "
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "1" ]
}

################################################################################
# 2. The operator-facing surface must say it
################################################################################

@test "pl verify summary reports the stale share of its own coverage figure" {
    run "$VERIFY" summary
    [ "$status" -eq 0 ]
    if [[ "$output" != *"STALE"* && "$output" != *"stale"* ]]; then
        echo "--- pl verify summary ---" >&2
        echo "$output" >&2
        echo "-------------------------" >&2
        echo "Every verified_at in .verification.yml is from Jan/Feb 2026, yet the" >&2
        echo "summary presents 90% coverage with no age at all. An operator gating" >&2
        echo "a release tag on this number is reading six-month-old evidence as if" >&2
        echo "it were current." >&2
        return 1
    fi
}

@test "pl verify summary names the date of the newest evidence it has" {
    run "$VERIFY" summary
    [ "$status" -eq 0 ]
    # Stronger than looking for a label: the actual newest verified_at date in
    # .verification.yml must appear in the output, so the reader can judge the
    # age themselves instead of trusting an adjective.
    newest=$(grep -oE "verified_at: '[0-9]{4}-[0-9]{2}-[0-9]{2}" "$VFILE" \
             | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort | tail -1)
    [ -n "$newest" ]
    [[ "$output" == *"$newest"* ]]
}

################################################################################
# 3. The horizon is configuration
################################################################################

@test "the freshness horizon is declared in .verification.yml, not hardcoded" {
    grep -qE '^[[:space:]]+freshness_days:[[:space:]]*[0-9]+' "$VFILE" || {
        echo "No config.freshness_days in .verification.yml — 'how old is too old'" >&2
        echo "would be a constant buried in a 3600-line script." >&2
        return 1
    }
}

################################################################################
# 4. A run that verified nothing is not a pass
################################################################################

@test "verify.sh ci refuses to report success when it wrote no results" {
    grep -q 'MACHINE_STATE_WRITES' "$VERIFY" || {
        echo "run_ci_mode does not count how many machine results it persisted," >&2
        echo "so a run whose every item was skipped (no machine block at that" >&2
        echo "depth, missing tool) exits 0 and republishes the previous numbers." >&2
        return 1
    }
}
