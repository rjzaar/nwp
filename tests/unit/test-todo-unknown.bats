#!/usr/bin/env bats
# Item 2 (oversight-honesty): `pl todo` must have an "I could not check" state.
#
# Defect this locks down: ~15 checks in lib/todo-checks.sh returned 0 (== CLEAN)
# on transport or tool failure. `check_live_backup_freshness` returned clean
# against an unroutable IP; `check_secret_expiry` returned clean when yq was
# missing; `check_token_liveness` kept a stale cache when the audit could not
# reach the host. Every one of those is "we did not look", rendered as "we
# looked and it was fine" — the exact shape of every vacuous pass in this repo.
#
# Contract now: a check that cannot complete emits exactly one UNK-* item.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  TMP="$BATS_TEST_TMPDIR/todo-unknown"
  mkdir -p "$TMP/bin" "$TMP/private"
  export TODO_CHECKS_PROJECT_ROOT="$TMP"
  export TODO_CACHE_DIR="$TMP/cache"
  # Minimal nwp.yml so is_category_enabled/get_todo_setting resolve.
  cat > "$TMP/nwp.yml" <<'EOF'
settings:
  todo:
    categories: {}
    thresholds: {}
EOF
  export TODO_CONFIG_FILE="$TMP/nwp.yml"
}

# Count UNK items produced by running one check function.
_unk_items() { # $1 = check function name, rest = shell prelude
  local fn="$1"; shift
  bash -c '
    set +e
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CHECKS_PROJECT_ROOT="'"$TMP"'"
    TODO_CONFIG_FILE="'"$TMP"'/nwp.yml"
    todo_clear_items
    '"$*"'
    '"$fn"'
    printf "%s\n" "${TODO_ITEMS[@]}"
  '
}

@test "todo_add_unknown produces an item flagged unknown:true in category UNK" {
  run bash -c '
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CHECKS_PROJECT_ROOT="'"$TMP"'"; TODO_CONFIG_FILE="'"$TMP"'/nwp.yml"
    todo_clear_items
    todo_add_unknown "live_backup" "ssh to 192.0.2.1 timed out"
    printf "%s\n" "${TODO_ITEMS[@]}"
  '
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == *'"id":"UNK-live_backup"'* ]]
  [[ "$output" == *'"unknown":true'* ]]
  [[ "$output" == *'"category":"UNK"'* ]]
}

@test "check_live_backup_freshness against an unroutable IP emits UNK, not silence" {
  # TEST-NET-1 (RFC 5737) — guaranteed not to route anywhere.
  run _unk_items check_live_backup_freshness '
    get_server_ip() { echo 192.0.2.1; }
    get_server_user() { echo nobody; }
    get_todo_setting() {
      case "$1" in
        live_backup.ssh_key) echo "'"$TMP"'/fake_key" ;;
        live_backup.server) echo testbox ;;
        live_backup.path) echo /var/backups/nwp-pull ;;
        thresholds.live_backup_warn_days) echo 2 ;;
        *) echo "${2:-}" ;;
      esac
    }
    ssh() { sleep 0; return 255; }   # transport failure
    touch "'"$TMP"'/fake_key"
  '
  echo "$output"
  [ "$(grep -c '"id":"UNK-' <<<"$output")" -eq 1 ]
  [[ "$output" == *"live-backup"* ]] || [[ "$output" == *"live_backup"* ]]
}

@test "check_live_backup_freshness with no ssh key emits UNK, not clean" {
  run _unk_items check_live_backup_freshness '
    get_server_ip() { echo 192.0.2.1; }
    get_server_user() { echo nobody; }
    get_todo_setting() {
      case "$1" in
        live_backup.ssh_key) echo "'"$TMP"'/definitely_absent_key" ;;
        live_backup.server) echo testbox ;;
        *) echo "${2:-}" ;;
      esac
    }
  '
  echo "$output"
  [ "$(grep -c '"id":"UNK-' <<<"$output")" -eq 1 ]
}

@test "check_live_backup_freshness with no resolvable server IP emits UNK" {
  run _unk_items check_live_backup_freshness '
    get_server_ip() { echo ""; }
    get_server_user() { echo ""; }
  '
  echo "$output"
  [ "$(grep -c '"id":"UNK-' <<<"$output")" -eq 1 ]
}

@test "check_secret_expiry without yq emits UNK, not clean" {
  mkdir -p "$TMP/private"
  printf 'secrets: []\n' > "$TMP/private/secrets-registry.yml"
  run _unk_items check_secret_expiry '
    command() { if [ "$2" = "yq" ]; then return 1; fi; builtin command "$@"; }
  '
  echo "$output"
  [ "$(grep -c '"id":"UNK-' <<<"$output")" -eq 1 ]
}

@test "check_secret_expiry with no registry at all emits UNK, not clean" {
  run _unk_items check_secret_expiry ''
  echo "$output"
  [ "$(grep -c '"id":"UNK-' <<<"$output")" -eq 1 ]
}

@test "check_token_liveness with an unreachable probe host emits UNK, not a silent stale cache" {
  mkdir -p "$TMP/scripts/commands" "$TMP/private"
  cat > "$TMP/scripts/commands/secrets.sh" <<'EOF'
#!/bin/bash
exit 2   # the documented "host unreachable" code
EOF
  run _unk_items check_token_liveness ''
  echo "$output"
  [ "$(grep -c '"id":"UNK-' <<<"$output")" -eq 1 ]
}

@test "check_agent_loop_cap with no API token emits UNK, not clean" {
  run _unk_items check_agent_loop_cap ''
  echo "$output"
  [ "$(grep -c '"id":"UNK-' <<<"$output")" -eq 1 ]
}

@test "check_ghost_sites without ddev emits UNK, not clean" {
  run _unk_items check_ghost_sites '
    command() { if [ "$2" = "ddev" ]; then return 1; fi; builtin command "$@"; }
  '
  echo "$output"
  [ "$(grep -c '"id":"UNK-' <<<"$output")" -eq 1 ]
}

@test "pl todo --json exposes the unknown flag and an unknown summary count" {
  run bash -c '
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CHECKS_PROJECT_ROOT="'"$TMP"'"; TODO_CONFIG_FILE="'"$TMP"'/nwp.yml"
    todo_clear_items
    todo_add_unknown "probe" "no transport"
    todo_output_items
  '
  [ "$status" -eq 0 ]
  run python3 -c "
import json,sys
d=json.loads(open('/dev/stdin').read())
print(d[0]['unknown'], d[0]['category'])" <<<"$output"
  [ "$output" = "True UNK" ]
}
