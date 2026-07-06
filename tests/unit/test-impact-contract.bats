#!/usr/bin/env bats
# nwp/ops#47 — the impact-report contract, mechanically enforced.
#
# CONTRACT: no destructive verb acts on inferred scope. Any command script
# performing destructive operations (rm -rf, ddev delete, DB drops, rsync
# --delete overwrites) must adopt lib/impact.sh — print a computed fate
# manifest before acting; -y skips the prompt, never the report.
#
# The allowlist below is SHRINK-ONLY: it freezes the scripts that predate
# the contract (tracked in nwp/ops#47, converted by risk order — restore,
# copy, rollback first). Removing entries as verbs convert is expected;
# ADDING an entry requires an explicit decision recorded on an ops issue.
# A NEW destructive script fails this test until it adopts the contract.

COMMANDS_DIR="${BATS_TEST_DIRNAME}/../../scripts/commands"

DESTRUCTIVE_PATTERN='rm -rf|ddev delete|DROP DATABASE|sql-drop|sql:drop|rsync .*--delete|--delete.*rsync'

# Scripts that predate the contract (2026-07-06 snapshot). Shrink only.
ALLOWLIST=(
  copy.sh
  dev2stg.sh
  install.sh
  live2prod.sh
  live2stg.sh
  live.sh
  modify.sh
  prod2stg.sh
  restore.sh
  server-apply.sh
  stg2live.sh
  stg2prod.sh
  uninstall_nwp.sh
  vrt.sh
)

_in_allowlist() {
  local name="$1" a
  for a in "${ALLOWLIST[@]}"; do
    [ "$a" = "$name" ] && return 0
  done
  return 1
}

@test "every destructive command script adopts lib/impact.sh or is on the frozen allowlist" {
  local violations=()
  local f name
  for f in "$COMMANDS_DIR"/*.sh; do
    name=$(basename "$f")
    if grep -qE "$DESTRUCTIVE_PATTERN" "$f"; then
      if ! grep -q 'lib/impact.sh' "$f" && ! _in_allowlist "$name"; then
        violations+=("$name")
      fi
    fi
  done
  if [ ${#violations[@]} -gt 0 ]; then
    echo "New destructive verb(s) without the impact contract: ${violations[*]}" >&2
    echo "Adopt lib/impact.sh (fate manifest + impact_confirm) — see delete.sh for the reference consumer." >&2
    return 1
  fi
}

@test "allowlist is shrink-only: no stale entries for converted/removed scripts" {
  local stale=()
  local a f
  for a in "${ALLOWLIST[@]}"; do
    f="$COMMANDS_DIR/$a"
    if [ ! -f "$f" ]; then
      stale+=("$a (script removed)")
    elif ! grep -qE "$DESTRUCTIVE_PATTERN" "$f"; then
      stale+=("$a (no longer destructive)")
    elif grep -q 'lib/impact.sh' "$f"; then
      stale+=("$a (converted — remove from allowlist)")
    fi
  done
  if [ ${#stale[@]} -gt 0 ]; then
    echo "Stale allowlist entries — delete them so the list only shrinks: ${stale[*]}" >&2
    return 1
  fi
}

@test "converted verbs stay converted: delete.sh sources lib/impact.sh" {
  grep -q 'lib/impact.sh' "$COMMANDS_DIR/delete.sh"
}

@test "TUI delete stays a delegation, not a fourth implementation" {
  # status.sh must not reimplement deletion: no rm -rf of site trees there
  ! grep -qE 'rm -rf "\$directory"|rm -rf "\$site_dir"' "$COMMANDS_DIR/status.sh"
  grep -q 'delete.sh' "$COMMANDS_DIR/status.sh"
}
