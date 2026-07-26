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

# php-cli IS now installed by the test:unit job, so a missing php means the
# runner is under-provisioned, not that the tests are optional.
#
# These two used to `skip` when php was absent. bats reports a skip as `ok`, and
# with no JUnit report nobody could see the skip count — so a runner migration
# (the current runner has php; the registered fallback does not) would have silently
# dropped the SSO uid-lock decision test AND the ops#81 erasure Bearer/IP/issuer
# guard test while the pipeline stayed green. That is the "ALL 13 passed / 18
# Art.9 cases skipped" shape.
#
# They now FAIL closed. Set NWP_ALLOW_MISSING_PHP=1 to fall back to skipping —
# a deliberate, greppable act, not an accident of provisioning.
require_php() {
  if command -v php >/dev/null 2>&1; then return 0; fi
  if [ "${NWP_ALLOW_MISSING_PHP:-0}" = "1" ]; then
    skip "php-cli absent and NWP_ALLOW_MISSING_PHP=1 was set deliberately"
  fi
  echo "php-cli is NOT installed on this runner." >&2
  echo "This test cannot verify anything, so it FAILS rather than reporting 'ok'." >&2
  echo "Provision php-cli (the test:unit job installs it), or set" >&2
  echo "NWP_ALLOW_MISSING_PHP=1 to downgrade to a visible skip." >&2
  return 1
}

@test "auth_nwc uid_lock: F26 UID-lock decision branches all pass" {
  require_php
  run php "$PROJECT_ROOT/scripts/f26/moodle/auth_nwc/tests/uid_lock_logic_test.php"
  [ "$status" -eq 0 ]
  [[ "$output" != *FAIL* ]]
  [[ "$output" == *"0 failed"* ]]
}

@test "local_nwc_erase erase_guard: destructive-path guards fail-closed" {
  require_php
  run php "$PROJECT_ROOT/scripts/moodle/local_nwc_erase/tests/erase_guard_logic_test.php"
  [ "$status" -eq 0 ]
  [[ "$output" != *FAIL* ]]
  [[ "$output" == *"0 failed"* ]]
}
