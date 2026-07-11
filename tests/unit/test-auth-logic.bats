#!/usr/bin/env bats
# ID-TESTS Rung 0 (audit §5) — CI-gate the two load-bearing, plain-PHP logic
# tests that were runnable but ran in NO job:
#   * auth_nwc\uid_lock::decide()  — the F26 SSO UID-lock decision (create/lock/
#     deny/suspend), the runnable core of the otherwise Moodle-dependent client.
#   * local_nwc_erase\erase_guard  — the ops#81 destructive-path guards +
#     CLOSED erasure-command validation (fail-closed Bearer/IP/issuer, enum,
#     non-empty fields, idempotency).
# Both run with plain `php` (no Moodle), so they belong in the fast blocking tier.
# Requires php-cli (added to the test:unit job).

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

# NOTE: these skip (not fail) when php-cli is absent, so merging this file does
# not red CI before the one-line `php-cli` addition to the test:unit job lands
# (that .gitlab-ci.yml change is a sensitive-path MR held for human review).

@test "auth_nwc uid_lock: F26 UID-lock decision branches all pass" {
  command -v php >/dev/null || skip "php-cli not installed — add it to the test:unit job to activate"
  run php "$PROJECT_ROOT/scripts/f26/moodle/auth_nwc/tests/uid_lock_logic_test.php"
  [ "$status" -eq 0 ]
  [[ "$output" != *FAIL* ]]
  [[ "$output" == *"0 failed"* ]]
}

@test "local_nwc_erase erase_guard: destructive-path guards fail-closed" {
  command -v php >/dev/null || skip "php-cli not installed — add it to the test:unit job to activate"
  run php "$PROJECT_ROOT/scripts/moodle/local_nwc_erase/tests/erase_guard_logic_test.php"
  [ "$status" -eq 0 ]
  [[ "$output" != *FAIL* ]]
  [[ "$output" == *"0 failed"* ]]
}
