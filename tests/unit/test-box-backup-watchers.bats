#!/usr/bin/env bats
# nwp/ops#332 — SOMETHING MUST WATCH the nightly box backup producer.
#
# The producer now states a per-run verdict (backup-verdict.json). That is only
# worth writing if a surface that already runs on its own grades it, so two
# existing surfaces were taught to read it rather than a third being invented:
#
#   * scripts/met-dr-pull.sh  — the nightly off-box pull (covers `live`).
#     Its arms are proven in tests/unit/test-dev-backup.bats.
#   * lib/todo-checks.sh check_live_backup_freshness — the daily fleet check
#     behind `pl todo` / `pl rag` (covers the configured live_backup.server,
#     i.e. the FORGE box, which is where ops#332 actually happened). Proven
#     here.
#
# And the DEPLOY path, `pl host apply <host> --kind=backup`, is proven here too,
# because a producer that only one session knows how to install is how the two
# boxes came to be running a script the repo could not diff.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  TMP="$BATS_TEST_TMPDIR/bkv"
  mkdir -p "$TMP/bin" "$TMP/private"
  export TODO_CHECKS_PROJECT_ROOT="$TMP"
  export TODO_CACHE_DIR="$TMP/cache"
  cat > "$TMP/nwp.yml" <<'EOF'
settings:
  todo:
    categories: {}
    thresholds: {}
EOF
  export TODO_CONFIG_FILE="$TMP/nwp.yml"
  touch "$TMP/fake_key"
}

# Run check_live_backup_freshness against a fake box whose single ssh
# round-trip returns <mtime-epoch> then VERDICT=<verdict>.
_lbk() { # <mtime-epoch> <verdict-line>
  local mtime="$1" vline="$2"
  bash -c '
    set +e
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CHECKS_PROJECT_ROOT="'"$TMP"'"
    TODO_CONFIG_FILE="'"$TMP"'/nwp.yml"
    todo_clear_items
    get_server_ip()   { echo 192.0.2.1; }
    get_server_user() { echo nobody; }
    get_todo_setting() {
      case "$1" in
        live_backup.ssh_key) echo "'"$TMP"'/fake_key" ;;
        live_backup.server)  echo testbox ;;
        live_backup.path)    echo /var/backups/nwp-pull ;;
        thresholds.live_backup_warn_days) echo 2 ;;
        *) echo "${2:-}" ;;
      esac
    }
    ssh() { printf "%s\n" "'"$mtime"'"; printf "%s\n" "'"$vline"'"; return 0; }
    check_live_backup_freshness
    printf "%s\n" "${TODO_ITEMS[@]}"
  '
}

################################################################################
# 1. pl todo grades the producer's stated verdict
################################################################################

@test "LBK: a FRESH directory whose producer says FAILED is a HIGH finding, not silence" {
  # This is the exact ops#332 shape: gitlab/ and nginx/ kept writing fresh files
  # every night, so freshness alone stayed green over a db/ with nothing in it.
  run _lbk "$(date +%s)" "VERDICT=failed"
  echo "$output"
  [[ "$output" == *'"id":"BKV'* ]]
  [[ "$output" == *'"priority":"high"'* ]]
  [[ "$output" == *"FAILED"* ]]
}

@test "LBK: a producer verdict of CANNOT-VERIFY is a HIGH finding" {
  run _lbk "$(date +%s)" "VERDICT=cannot-verify"
  [[ "$output" == *'"id":"BKV'* ]]
  [[ "$output" == *'"priority":"high"'* ]]
}

@test "LBK: NO verdict at all emits UNK — a pre-ops#332 producer's success is not evidence" {
  run _lbk "$(date +%s)" "VERDICT=none"
  echo "$output"
  [ "$(grep -c '"id":"UNK-' <<<"$output")" -eq 1 ]
  [[ "$output" == *"pre-ops#332"* ]]
}

@test "LBK: an unreadable verdict is UNK, never a pass" {
  run _lbk "$(date +%s)" "VERDICT=probably-fine"
  [ "$(grep -c '"id":"UNK-' <<<"$output")" -eq 1 ]
}

@test "LBK: verdict=ok on a fresh directory files NOTHING (the check can be quiet)" {
  # A check that is permanently red is a check everybody learns to ignore, so
  # the positive control matters as much as the negatives.
  run _lbk "$(date +%s)" "VERDICT=ok"
  echo "$output"
  [[ "$output" != *'"id":"BKV'* ]]
  [[ "$output" != *'"id":"UNK-'* ]]
}

@test "LBK: verdict=ok does NOT suppress the pre-existing staleness finding" {
  run _lbk "$(( $(date +%s) - 9 * 86400 ))" "VERDICT=ok"
  [[ "$output" == *'"id":"LBK'* ]]
}

################################################################################
# 2. pl host apply --kind=backup — the deploy path
################################################################################

HOSTSH() { printf '%s/scripts/commands/host.sh' "$ROOT"; }

@test "the backup kind is a known capture kind and is listed in the help" {
  run bash -c 'source "'"$ROOT"'/lib/host-capture.sh"; host_kind_is_known backup && printf "%s\n" "${HOST_CAPTURE_KINDS[@]}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup"* ]]
}

@test "the backup capture probe reads the producer, the DECLARATION and the cron" {
  run bash -c 'source "'"$ROOT"'/lib/host-capture.sh"; host_kind_probe backup'
  [ "$status" -eq 0 ]
  [[ "$output" == *"/usr/local/sbin/nwp-box-backup.sh"* ]]
  [[ "$output" == *"/etc/nwp-box-backup.conf"* ]]
  [[ "$output" == *"/etc/cron.d/nwp-box-backup"* ]]
}

@test "the backup capture probe does NOT capture the verdict (it changes nightly; always-drift is ignorable)" {
  run bash -c 'source "'"$ROOT"'/lib/host-capture.sh"; host_kind_probe backup'
  [[ "$output" != *"backup-verdict.json"* ]]
}

@test "apply --kind=backup REFUSES a host with no DECLARED legs (fail closed)" {
  # An undeclared host is precisely the one that cannot tell "no leg here" from
  # "the leg is broken", so it must not receive the producer at all.
  run bash -c '
    source "'"$ROOT"'/lib/ui.sh"
    source "'"$ROOT"'/lib/host-capture.sh"
    NWP_BP_PROJECT_ROOT="'"$ROOT"'"
    source "'"$ROOT"'/lib/backup-producer.sh"
    host_resolve_name() { echo nosuchhost; }
    host_resolve_dest() { echo LOCAL; }
    backup_producer_run nosuchhost
  '
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" == *"DECLARED"* ]]
}

@test "apply --kind=backup REFUSES a declaration that is not none|required" {
  mkdir -p "$TMP/repo/servers/bogus/backup" "$TMP/repo/servers/nwpcode/backup"
  cp "$ROOT/servers/nwpcode/backup/nwp-box-backup.sh" "$TMP/repo/servers/nwpcode/backup/"
  printf 'SITE_DB_LEG=maybe\nGITLAB_LEG=none\n' > "$TMP/repo/servers/bogus/backup/nwp-box-backup.conf"
  run bash -c '
    source "'"$ROOT"'/lib/ui.sh"
    source "'"$ROOT"'/lib/host-capture.sh"
    NWP_BP_PROJECT_ROOT="'"$TMP"'/repo"
    source "'"$ROOT"'/lib/backup-producer.sh"
    host_resolve_name() { echo bogus; }
    host_resolve_dest() { echo LOCAL; }
    backup_producer_run bogus
  '
  [ "$status" -eq 2 ]
  [[ "$output" == *"SITE_DB_LEG='maybe'"* ]]
}

@test "apply --kind=backup treats an unreadable host as UNREACHABLE, never as in sync" {
  run bash -c '
    source "'"$ROOT"'/lib/ui.sh"
    source "'"$ROOT"'/lib/host-capture.sh"
    NWP_BP_PROJECT_ROOT="'"$ROOT"'"
    source "'"$ROOT"'/lib/backup-producer.sh"
    host_resolve_name() { echo nwpcode; }
    host_resolve_dest() { echo LOCAL; }
    host_run() { return 255; }
    backup_producer_run nwpcode
  '
  [ "$status" -eq 3 ]
  [[ "$output" == *"UNREACHABLE"* ]]
  [[ "$output" == *"NOT 'in sync'"* ]]
}

@test "the wire format carries the producer VERBATIM (no base64, nothing to un-hide)" {
  run bash -c '
    source "'"$ROOT"'/lib/ui.sh"
    NWP_BP_PROJECT_ROOT="'"$ROOT"'"
    source "'"$ROOT"'/lib/backup-producer.sh"
    _bp_put_script "'"$ROOT"'/servers/nwpcode/backup/nwp-box-backup.sh" /tmp/x 0755
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"nwp-box-backup.sh — LOCAL backup producer"* ]]
  [[ "$output" == *"install -m 0755 -o root -g root"* ]]
}

@test "both boxes' declarations exist, parse, and disagree — which is the whole point" {
  local f_forge="$ROOT/servers/nwpcode/backup/nwp-box-backup.conf"
  local f_live="$ROOT/servers/live/backup/nwp-box-backup.conf"
  [ -r "$f_forge" ]; [ -r "$f_live" ]
  grep -qx 'SITE_DB_LEG=none'     "$f_forge"
  grep -qx 'GITLAB_LEG=required'  "$f_forge"
  grep -qx 'SITE_DB_LEG=required' "$f_live"
  grep -qx 'GITLAB_LEG=none'      "$f_live"
}
