#!/usr/bin/env bats
#
# test-doctor-fleet-sync-blind.bats — doctor's check_fleet_sync must not
# return 0 when the instance manifest is unreadable.
#
# WHY THIS EXISTS (ops#383, measured 2026-08-15)
#   check_fleet_sync printed an honest sentence ("no readable instance
#   manifest on this machine…") and then returned 0 — the exit code asserted
#   the pass the sentence had just disclaimed. Anything summing doctor check
#   returns therefore graded "host currency: fine" on exactly the machines
#   that cannot measure it. Estate rule: exit 2 CANNOT VERIFY, never exit 0.
#
#   The truthful exit (ops#361) is the check itself: it clears on its own
#   terms wherever the manifest is readable — no override, no attribution.
#
# No skips: doctor.sh guards main() behind a BASH_SOURCE check, so sourcing it
# gives us the check function directly.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  DOCTOR="$PROJECT_ROOT/scripts/commands/doctor.sh"
}

# Run check_fleet_sync in a subshell with a controlled manifest path and an
# optionally-stubbed `pl` (check_fleet_sync invokes "$PROJECT_ROOT/pl", an
# absolute path, so the stub must come via a PROJECT_ROOT override).
_check() { # $1 manifest path, $2 stub-pl exit code or "" for none
  local stubroot="$BATS_TEST_TMPDIR/stubroot"
  if [ -n "${2:-}" ]; then
    mkdir -p "$stubroot"
    printf '#!/usr/bin/env bash\nexit %s\n' "$2" > "$stubroot/pl"
    chmod +x "$stubroot/pl"
  fi
  run bash -c '
    set -uo pipefail
    source "$1"
    if [ -n "${3:-}" ]; then PROJECT_ROOT="$3"; fi
    NWP_INSTANCE_MANIFEST="$2" check_fleet_sync
  ' _ "$DOCTOR" "$1" "${2:+$stubroot}"
}

@test "an unreadable manifest is return 2 CANNOT VERIFY, not return 0" {
  _check "$BATS_TEST_TMPDIR/does-not-exist.yml" ""
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "a readable manifest with every host current is still return 0" {
  # Green half of the mutation test: the check can still pass where it CAN
  # measure.
  touch "$BATS_TEST_TMPDIR/manifest.yml"
  _check "$BATS_TEST_TMPDIR/manifest.yml" 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"current"* ]]
}

@test "fleet-sync's own CANNOT VERIFY (exit 2) still grades as a doctor error" {
  touch "$BATS_TEST_TMPDIR/manifest.yml"
  _check "$BATS_TEST_TMPDIR/manifest.yml" 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}
