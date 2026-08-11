#!/usr/bin/env bats
# The private-site-name lint must run at COMMIT time, not only in CI.
#
# WHY (measured 2026-08-11). Five separate merge requests were tripped by
# lint:site-names in a single day — !421, !424, !425, !428 and the P75 proposal
# — every one for the same reason: a real private site name in PROSE. Comments
# citing a worked example, a fixture using a real site as an arbitrary label, a
# proposal naming the site it discusses. Nobody thinks of a comment as a
# disclosure; on a publicly mirrored repo it is exactly that.
#
# Each cost a push, a pipeline, a diagnosis and a second push. The gate was
# right every time and late every time. gitleaks and the review-mode projection
# already run pre-commit for the same reason: the cheapest place to catch a
# leak is before it leaves the machine.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CFG="${REPO_ROOT}/.pre-commit-config.yaml"
  LINT="${REPO_ROOT}/scripts/ci/lint-site-names.sh"
}

@test "the site-name lint is registered as a pre-commit hook" {
  run grep -q 'lint-site-names.sh' "$CFG"
  [ "$status" -eq 0 ]
}

@test "it runs on every commit, not only on the files that changed" {
  # a name can be introduced in a file the commit does not touch (a baseline
  # row going stale, a rename elsewhere), so the hook must not pass_filenames
  run bash -c "awk '/lint-site-names/,/^\$/' '$CFG' | grep -q 'pass_filenames: false'"
  [ "$status" -eq 0 ]
}

@test "the hook is fast enough to run every time (< 5s on this tree)" {
  local start end
  start=$(date +%s%N)
  NWP_SITE_NAME_DENYLIST="${REPO_ROOT}/private/site-names.deny" bash "$LINT" >/dev/null 2>&1 || true
  end=$(date +%s%N)
  [ $(( (end - start) / 1000000 )) -lt 5000 ]
}

@test "with NO readable deny-list it FAILS CLOSED — a commit is blocked, not waved through" {
  # NOTE: the first draft of this case passed `--root`, a flag this script does
  # not accept — it printed "unknown argument" and the assertion measured the
  # wrong thing. Invoke it the way the hook will.
  run env NWP_SITE_NAME_DENYLIST=/nonexistent/nope bash "$LINT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "the pre-commit config stays valid YAML" {
  run bash -c "yq -e '.repos' '$CFG' >/dev/null"
  [ "$status" -eq 0 ]
}
