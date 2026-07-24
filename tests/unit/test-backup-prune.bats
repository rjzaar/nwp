#!/usr/bin/env bats
# nwp/ops#124 — `pl backup prune`: a real retention window on LOCAL backups so
# deleted user data does not survive the erasure promise in local dev backups.
# SAFETY invariant: the newest backup set per site is ALWAYS kept.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/commands/backup.sh"

@test "backup.sh dispatches the prune subcommand" {
  grep -Eq '\[\[ "\$\{1:-\}" == "prune" \]\]' "$SCRIPT"
  grep -Eq 'prune_main "\$@"' "$SCRIPT"
}

@test "prune defaults to a 30-day retention window" {
  # flag > setting > 30; the hard default and the setting key are both present
  grep -Eq 'DAYS=30' "$SCRIPT"
  grep -Eq 'backup_retention_days' "$SCRIPT"
}

@test "prune ALWAYS keeps the newest set per site (never zero backups)" {
  grep -Eq 'newest_stem' "$SCRIPT"
  # the keep branch fires for the newest stem
  grep -Eq 'stem" = "\$newest_stem' "$SCRIPT"
}

@test "prune deletes the whole set incl. .sha256/.manifest sidecars" {
  # deletion globs every file sharing the stem, not just the .sql.gz/.tar.gz
  grep -Eq 'name "\$\{(victim_stems\[\$i\]|stem)\}\.\*"' "$SCRIPT"
}

@test "prune uses a two-pass confirm (collect victims, then delete)" {
  grep -Eq 'PASS 1' "$SCRIPT"
  grep -Eq 'PASS 2' "$SCRIPT"
  grep -Eq 'read -r -p' "$SCRIPT"
}

@test "prune --help renders and exits 0" {
  run bash "$SCRIPT" prune --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"retention window"* ]]
}

@test "prune rejects a non-numeric --days" {
  run bash "$SCRIPT" prune --days abc --dry-run
  [ "$status" -ne 0 ]
}
