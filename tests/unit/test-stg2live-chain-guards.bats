#!/usr/bin/env bats
# ops#157 / register D17+D18 — the two deploy-chain guards derived from the
# 2026-07-29 live incidents:
#   D17  refuse a drush-less staging tree BEFORE maintenance mode
#   D18  resolve remote_path from remote_dir when no explicit remote_path
# The pure helpers are exercised functionally; the wiring is asserted
# statically (same style as test-stg2live-hardening.bats), because the wiring
# is what turns a helper into a guard.

CMD="${BATS_TEST_DIRNAME}/../../scripts/commands/stg2live.sh"

setup() {
  TEST_TMP="$(mktemp -d)"
  # Source ONLY the two pure helpers, without running main(). The file guards
  # its own dispatch behind a `main "$@"` at the bottom that we never call.
  # shellcheck disable=SC1090
  source <(sed -n '/^stg2live_stg_has_drush() {/,/^}/p' "$CMD")
}
teardown() { rm -rf "$TEST_TMP"; }

# ---------------------------------------------------------------------------
# D17 — stg2live_stg_has_drush
# ---------------------------------------------------------------------------

@test "D17: a staging tree with vendor/bin/drush is accepted" {
  mkdir -p "${TEST_TMP}/vendor/bin"
  printf '#!/bin/sh\n' > "${TEST_TMP}/vendor/bin/drush"; chmod +x "${TEST_TMP}/vendor/bin/drush"
  run stg2live_stg_has_drush "$TEST_TMP"
  [ "$status" -eq 0 ]
}

@test "D17: a staging tree with web/vendor/bin/drush is accepted (docroot layout)" {
  mkdir -p "${TEST_TMP}/web/vendor/bin"
  printf '#!/bin/sh\n' > "${TEST_TMP}/web/vendor/bin/drush"; chmod +x "${TEST_TMP}/web/vendor/bin/drush"
  run stg2live_stg_has_drush "$TEST_TMP"
  [ "$status" -eq 0 ]
}

@test "D17: a drush-less staging tree is REJECTED (the incident shape)" {
  mkdir -p "${TEST_TMP}/vendor/bin"    # vendor exists, no drush in it
  run stg2live_stg_has_drush "$TEST_TMP"
  [ "$status" -ne 0 ]
}

@test "D17: a NON-EXECUTABLE drush does not count (would fail on live too)" {
  mkdir -p "${TEST_TMP}/vendor/bin"
  printf '#!/bin/sh\n' > "${TEST_TMP}/vendor/bin/drush"   # not chmod +x
  run stg2live_stg_has_drush "$TEST_TMP"
  [ "$status" -ne 0 ]
}

@test "D17: empty arg is rejected, not silently true" {
  run stg2live_stg_has_drush ""
  [ "$status" -ne 0 ]
}

# --- D17 wiring: the guard runs before maintenance, and can be overridden ---

@test "D17 wiring: the drush check aborts (return 1) and cites ops#157" {
  run bash -c "grep -n 'stg2live_stg_has_drush \"\$stg_site\"' '$CMD'"
  [ "$status" -eq 0 ]
  run bash -c "sed -n '/if ! stg2live_stg_has_drush/,/return 1/p' '$CMD'"
  [[ "$output" == *"ops#157"* ]]
  [[ "$output" == *"return 1"* ]]
}

@test "D17 wiring: the check sits BEFORE the first maintenance-ON call" {
  # line of the drush guard must be smaller than the first live_maintenance_set ... 1
  guard_line="$(grep -n 'if ! stg2live_stg_has_drush' "$CMD" | head -1 | cut -d: -f1)"
  maint_line="$(grep -n 'live_maintenance_set .* 1$' "$CMD" | head -1 | cut -d: -f1)"
  [ -n "$guard_line" ] && [ -n "$maint_line" ]
  [ "$guard_line" -lt "$maint_line" ]
}

@test "D17 wiring: honours NWP_ALLOW_NO_DRUSH override and skips on dry-run" {
  run bash -c "sed -n '/D17 (ops#157): REFUSE now/,/print_status \"OK\" \"Staging carries drush/p' '$CMD'"
  [[ "$output" == *'NWP_ALLOW_NO_DRUSH'* ]]
  [[ "$output" == *'DRY_RUN'* ]]
}

# ---------------------------------------------------------------------------
# D18 — remote_path resolves from remote_dir. get_live_config reads real config
# via get_site_config_value, so we assert the resolution ORDER statically (the
# behaviour is: explicit remote_path wins; else /var/www/<remote_dir>; else "").
# ---------------------------------------------------------------------------

@test "D18: get_live_config's remote_path arm prefers explicit path, then remote_dir" {
  run bash -c "sed -n '/remote_path)/,/;;/p' '$CMD' | sed -n '1,20p'"
  [[ "$output" == *".live.remote_path"* ]]
  [[ "$output" == *".live.remote_dir"* ]]
  [[ "$output" == *'/var/www/${rd}'* ]]
}

@test "D18: explicit remote_path is returned before remote_dir is even read" {
  # rp is read first and short-circuits with `return`; rd only reached if empty.
  run bash -c "sed -n '/remote_path)/,/;;/p' '$CMD'"
  # the rp branch returns before the rd line appears
  rp_ret="$(printf '%s' "$output" | grep -n 'if \[ -n "\$rp" \]; then echo "\$rp"; return' | head -1 | cut -d: -f1)"
  rd_read="$(printf '%s' "$output" | grep -n "rd=" | head -1 | cut -d: -f1)"
  [ -n "$rp_ret" ] && [ -n "$rd_read" ]
  [ "$rp_ret" -lt "$rd_read" ]
}
