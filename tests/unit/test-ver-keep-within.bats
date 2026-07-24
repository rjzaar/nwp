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
