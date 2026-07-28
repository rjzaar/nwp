#!/usr/bin/env bats
#
# test-verify-ci-bootstrap.bats — `test:verification` must be ABLE to pass, and
# must never buy that ability with the operator's config.        (nwp/ops#148)
#
# WHY THIS FILE EXISTS
#   The CI job `test:verification` runs `verify.sh ci --depth=basic`. That path
#   reaches create_test_site → install.sh, whose first act is to require
#   `nwp.yml`. `nwp.yml` is gitignored on purpose — it is operator machine
#   state, never a commit artifact — so a FRESH build slot cannot have one and
#   the job was structurally incapable of passing. Its green history came from
#   an untracked leftover in a reused met build slot: the job was passing on a
#   file that was not in the commit under test. That is a vacuous pass in both
#   directions — it could not go green honestly, and when it did go green it was
#   measuring the runner rather than the code.
#
#   The second, independent bug: the intended graceful fallback
#       Warning: Could not create test site, some checks may be skipped
#   was DEAD CODE. verify.sh runs under `set -euo pipefail`, and
#       test_site=$(create_test_site …)
#   is a simple command whose status is the substitution's, so a failing
#   create_test_site aborted the script before the `if [[ -z "$test_site" ]]`
#   branch could run. The degradation the author wrote was unreachable.
#
# CONTRACT PINNED HERE
#   1. `ci` mode bootstraps a usable nwp.yml from example.nwp.yml when none is
#      present;
#   2. it NEVER touches an existing nwp.yml — the dangerous failure mode is a
#      CI convenience overwriting a real site inventory, which is worse than a
#      red job (no --force, ever);
#   3. NEGATIVE CONTROL: with a valid config present, nothing is bootstrapped
#      and behaviour is unchanged;
#   4. a create_test_site failure DEGRADES (warn + continue), it does not abort.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    VERIFY="$REPO_ROOT/scripts/commands/verify.sh"
    MINI="$BATS_TEST_TMPDIR/repo"
}

################################################################################
# A disposable copy of just enough NWP to run `verify.sh ci` for real.
#
# The point is to exercise the SHIPPING code path end to end (real verify.sh,
# real verify-runner.sh) while PROJECT_ROOT is a throwaway directory — so a test
# about creating/overwriting nwp.yml can never reach the operator's nwp.yml, and
# a test-site cleanup can never reach the real sites/.
#
# $1 (optional) = "sabotage" → shim create_test_site to fail, which is what a
# clean runner does anyway (no DDEV, no config) but deterministically.
################################################################################
_mini_repo() {
    local mode="${1:-normal}"
    mkdir -p "$MINI/scripts/commands" "$MINI/lib"

    cp "$VERIFY" "$MINI/scripts/commands/verify.sh"
    chmod +x "$MINI/scripts/commands/verify.sh"

    local f b
    for f in "$REPO_ROOT"/lib/*.sh; do
        b="$(basename "$f")"
        [[ "$b" == "verify-runner.sh" ]] && continue
        ln -sf "$f" "$MINI/lib/$b"
    done

    if [[ "$mode" == "sabotage" ]]; then
        # Source the REAL runner, then make exactly one function fail. Nothing
        # else about the run is faked.
        cat > "$MINI/lib/verify-runner.sh" <<EOF
source "$REPO_ROOT/lib/verify-runner.sh"
create_test_site() { return 1; }
EOF
    else
        ln -sf "$REPO_ROOT/lib/verify-runner.sh" "$MINI/lib/verify-runner.sh"
    fi

    cp "$REPO_ROOT/example.nwp.yml" "$MINI/example.nwp.yml"

    # One automatable item whose check is `true`, so the run measures the
    # plumbing and nothing else.
    cat > "$MINI/.verification.yml" <<'EOF'
version: 3
config:
  machine_engine: verify.sh
  freshness_days: 90
  test_site:
    prefix: bats-test-ci
    cleanup_on_success: true
    preserve_on_failure: false
statistics:
  total_items: 1
  machine:
    verified: 0
    coverage_percent: 0.0
  human:
    verified: 0
    coverage_percent: 0.0
  fully_verified: 0
features:
  demo:
    name: Demo feature
    description: fixture
    files:
    - pl
    checklist:
    - text: a trivially checkable thing
      completed: false
      machine:
        automatable: true
        checks:
          basic:
            commands:
            - cmd: 'true'
              expect_exit: 0
              timeout: 10
        state:
          verified: false
          verified_at: ''
          depth: basic
          duration_seconds: 0
EOF
}

_run_ci() {
    run env NO_COLOR=1 bash "$MINI/scripts/commands/verify.sh" ci --depth=basic
}

################################################################################
# 1. The bootstrap exists and produces a usable config
################################################################################

@test "ci mode bootstraps nwp.yml from example.nwp.yml when none is present" {
    _mini_repo
    [ ! -e "$MINI/nwp.yml" ]

    _run_ci

    [ -f "$MINI/nwp.yml" ] || {
        echo "--- verify.sh ci output ---" >&2
        echo "$output" >&2
        echo "---------------------------" >&2
        echo "No nwp.yml was created. On a clean runner install.sh aborts with" >&2
        echo "\"Configuration file 'nwp.yml' not found\", so test:verification" >&2
        echo "cannot pass on any build slot that does not already carry an" >&2
        echo "untracked leftover config." >&2
        return 1
    }
}

@test "the bootstrapped config is the template, and it parses" {
    _mini_repo
    _run_ci

    [ -f "$MINI/nwp.yml" ]
    run diff -q "$MINI/example.nwp.yml" "$MINI/nwp.yml"
    [ "$status" -eq 0 ]

    # "Usable" means a config reader can read it, not merely that bytes landed.
    run yq -r '.recipes | keys | .[]' "$MINI/nwp.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pod"* ]]
}

@test "the run says out loud that it bootstrapped a config" {
    _mini_repo
    _run_ci
    [[ "$output" == *"bootstrapped nwp.yml"* ]] || {
        echo "$output" >&2
        echo "A config appearing under the runner's feet with no log line is a" >&2
        echo "fact nobody can audit after the fact." >&2
        return 1
    }
}

################################################################################
# 2. THE DANGEROUS ONE — an existing nwp.yml is never touched
################################################################################

@test "an existing nwp.yml is not overwritten, not even byte-identically" {
    _mini_repo
    printf 'sites:\n  operator_only_site:\n    recipe: d\n# DO NOT CLOBBER\n' > "$MINI/nwp.yml"
    local before after
    before="$(sha256sum < "$MINI/nwp.yml")"

    _run_ci

    after="$(sha256sum < "$MINI/nwp.yml")"
    [ "$before" = "$after" ] || {
        echo "$output" >&2
        echo "verify.sh ci rewrote an existing nwp.yml. A CI convenience that can" >&2
        echo "overwrite the operator's site inventory is worse than a red job." >&2
        return 1
    }
    grep -q 'DO NOT CLOBBER' "$MINI/nwp.yml"
}

@test "NEGATIVE CONTROL: with a valid config present nothing is bootstrapped" {
    _mini_repo
    cp "$MINI/example.nwp.yml" "$MINI/nwp.yml"

    _run_ci

    [[ "$output" != *"bootstrapped nwp.yml"* ]] || {
        echo "$output" >&2
        echo "The bootstrap announced itself although a config was already there." >&2
        return 1
    }
    [[ "$output" == *"using the existing nwp.yml"* ]]
}

@test "the bootstrap has no force/overwrite flag to reach for" {
    # Guards the next change to this function as much as this one: the only safe
    # shape is create-if-absent.
    run grep -nE 'verify_ci_bootstrap_config.*(--force|force=1)' "$VERIFY"
    [ "$status" -ne 0 ]
}

################################################################################
# 3. The degrade path is REACHABLE — a failing create_test_site is not fatal
################################################################################

@test "a create_test_site failure warns and the run continues (not an abort)" {
    _mini_repo sabotage
    _run_ci

    [[ "$output" == *"Could not create test site"* ]] || {
        echo "--- verify.sh ci output ---" >&2
        echo "$output" >&2
        echo "---------------------------" >&2
        echo "The graceful fallback never printed. Under 'set -euo pipefail' a" >&2
        echo "bare test_site=\$(create_test_site …) aborts the script on failure," >&2
        echo "so the 'if [[ -z \"\$test_site\" ]]' branch is dead code." >&2
        return 1
    }

    # Continuing means the run actually went on to measure something and print
    # its summary — not that it printed a warning on the way out the door.
    [[ "$output" == *"[demo]"* ]]
    [[ "$output" == *"PASS:"* || "$output" == *"pass rate"* ]]
}

@test "a degraded run still exits 0 when every check it could run passed" {
    _mini_repo sabotage
    _run_ci
    [ "$status" -eq 0 ] || {
        echo "$output" >&2
        echo "status=$status — a run whose only casualty was an unavailable test" >&2
        echo "site should not fail the job; that is what 'some checks may be" >&2
        echo "skipped' means." >&2
        return 1
    }
}

@test "run_ci_mode does not abort before its own honesty gate and artifacts" {
    # run_machine_checks returns 1 when items failed; a bare call under set -e
    # would kill run_ci_mode before MACHINE_STATE_WRITES, .badges.json and the
    # pass-rate line — a real failure would then look like a broken runner.
    run grep -nF 'run_machine_checks --depth="$depth" --all || exit_code=$?' "$VERIFY"
    [ "$status" -eq 0 ]
}
