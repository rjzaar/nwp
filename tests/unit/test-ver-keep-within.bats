#!/usr/bin/env bats
# nwp/ops#127 — ver-backup-pull gains a --keep-within erasure ceiling so RAW
# (unsanitised) DR snapshots cannot outlive the 30-day erasure promise.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/commands/ver-backup-pull.sh"

@test "ver-backup-pull accepts --keep-within" {
  grep -Eq -- '--keep-within' "$SCRIPT"
  grep -Eq 'KEEP_WITHIN=' "$SCRIPT"
}

@test "keep-within uses restic forget --keep-within --prune (hard ceiling)" {
  grep -Eq 'forget --keep-within "\$KEEP_WITHIN" --prune' "$SCRIPT"
}

@test "legacy tiered policy still available when keep-within is unset" {
  grep -Eq 'forget --keep-daily "\$KEEP_DAILY"' "$SCRIPT"
  grep -Eq 'if \[ -n "\$KEEP_WITHIN" \]' "$SCRIPT"
}

@test "help documents the erasure-window usage" {
  run bash "$SCRIPT" --help
  [[ "$output" == *"keep-within"* ]]
  [[ "$output" == *"erasure"* ]]
}

# ── ops#127 wiring: --kind fail-closed gate ──────────────────────────────────

@test "--kind raw WITHOUT --keep-within is refused (fail-closed)" {
  run bash "$SCRIPT" --from x --to y --kind raw --skip-restic-verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"RAW"* ]]
  [[ "$output" == *"erasure ceiling"* ]]
}

@test "--kind raw WITH --keep-within proceeds (dry-run) and uses the ceiling" {
  run bash "$SCRIPT" --from x --to y --kind raw --keep-within 30d --skip-restic-verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"forget --keep-within 30d --prune"* ]]
}

@test "--kind sanitized is allowed without a ceiling (tiered policy)" {
  run bash "$SCRIPT" --from x --to y --kind sanitized --skip-restic-verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"forget --keep-daily"* ]]
}

@test "an unknown --kind is refused" {
  run bash "$SCRIPT" --from x --to y --kind bogus --skip-restic-verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"--kind must be raw or sanitized"* ]]
}

@test "help documents the --kind data class" {
  run bash "$SCRIPT" --help
  [[ "$output" == *"--kind"* ]]
  [[ "$output" == *"sanitized"* ]]
}
