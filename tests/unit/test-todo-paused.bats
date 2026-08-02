#!/usr/bin/env bats
# Item 2 (oversight-honesty): a paused automation must be visible, and a pause
# must be accountable.
#
# Defect this locks down: a `.loop-paused` sentinel sat on all three AI hosts for
# over a week and the rag-sync part was skipped for 8 consecutive nights. Every
# one of those nights the wrapper logged "skipping" and exited 0 — a green cron,
# a green exit code, and no `pl` surface anywhere saying the self-healing loop
# had been off since the middle of the month. The tracker's write half was dead
# and 14 rag-auto issues went un-regraded, invisibly.
#
# Contract now:
#   - every pause sentinel produces a HIGH item carrying its AGE
#   - a pause with no reason/until annotation is itself a finding
#   - a rag-sync log with no recent successful run produces a finding
#   - a MISSING rag-sync log is UNKNOWN, not clean

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  TMP="$BATS_TEST_TMPDIR/paused"
  mkdir -p "$TMP/logs"
  export TODO_CHECKS_PROJECT_ROOT="$TMP"
  cat > "$TMP/nwp.yml" <<'EOF'
settings:
  todo:
    categories: {}
    thresholds: {}
EOF
  export TODO_CONFIG_FILE="$TMP/nwp.yml"
  export NWP_LOOP_STATE="$TMP/parts.state"
}

_run() { # $1 = check fn
  bash -c '
    set +e
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CHECKS_PROJECT_ROOT="'"$TMP"'"
    TODO_CONFIG_FILE="'"$TMP"'/nwp.yml"
    NWP_LOOP_STATE="'"$TMP"'/parts.state"
    todo_clear_items
    '"$1"'
    printf "%s\n" "${TODO_ITEMS[@]:-}"
  '
}

@test "no pause sentinels => no PAUSE item" {
  run _run check_paused_automation
  echo "$output"
  [[ "$output" != *'"category":"PAU"'* ]]
}

@test ".loop-paused produces a HIGH item naming the pause age" {
  touch -d '9 days ago' "$TMP/.loop-paused"
  run _run check_paused_automation
  echo "$output"
  [[ "$output" == *'"category":"PAU"'* ]]
  [[ "$output" == *'"priority":"high"'* ]]
  [[ "$output" == *"9 day"* ]]
}

@test ".rag-sync-paused is reported independently of .loop-paused" {
  touch -d '3 days ago' "$TMP/.rag-sync-paused"
  run _run check_paused_automation
  echo "$output"
  [[ "$output" == *"rag-sync-paused"* ]]
}

@test "a pause with no reason/until annotation is itself flagged" {
  touch -d '2 days ago' "$TMP/.loop-paused"   # empty file, no annotation
  run _run check_paused_automation
  echo "$output"
  [[ "$output" == *"no reason"* ]] || [[ "$output" == *"unannotated"* ]]
}

@test "an annotated pause with a future 'until' is not flagged as unannotated" {
  {
    echo "reason: waiting on the operator to re-auth Claude on mini"
    echo "until: 2099-01-01"
  } > "$TMP/.loop-paused"
  touch -d '2 days ago' "$TMP/.loop-paused"
  run _run check_paused_automation
  echo "$output"
  [[ "$output" == *'"category":"PAU"'* ]]     # still reported — it IS paused
  [[ "$output" != *"no reason"* ]]
}

@test "an annotated pause whose 'until' has passed is escalated" {
  {
    echo "reason: short maintenance window"
    echo "until: 2020-01-01"
  } > "$TMP/.loop-paused"
  run _run check_paused_automation
  echo "$output"
  [[ "$output" == *"expired"* ]] || [[ "$output" == *"overdue"* ]]
}

@test "a disabled part in parts.state is reported" {
  printf 'fix-loop=disabled\n' > "$TMP/parts.state"
  run _run check_paused_automation
  echo "$output"
  [[ "$output" == *"fix-loop"* ]]
}

# --- rag-sync freshness -------------------------------------------------------
#
# ops#230 added a second assertion to this check: a rag-sync part that is
# enabled and unpaused but has NO CRON is RED, because nothing will ever wake
# it — that is the state this workstation was actually in on 2026-08-02, with a
# log that still looked recent. A fixture that only supplies a log therefore no
# longer describes a healthy host, so the fixtures below state the schedule too.
# NWP_OVERSIGHT_CRON exists for exactly this: the suite must not depend on
# whatever the machine running it happens to have in its crontab.

@test "a rag-sync log with a recent successful run is clean" {
  export NWP_OVERSIGHT_CRON=present
  { echo "$(date -u -d '2 hours ago' +%FT%TZ) rag-sync start"
    echo "$(date -u -d '2 hours ago' +%FT%TZ) rag-sync done (pl rag exit=0)"; } > "$TMP/logs/rag-sync.log"
  run _run check_rag_sync_freshness
  echo "$output"
  [[ "$output" != *'"category":"RSY"'* ]]
}

@test "a rag-sync log whose last success is 3 days old is reported" {
  { echo "$(date -u -d '3 days ago' +%FT%TZ) rag-sync done (pl rag exit=0)"; } > "$TMP/logs/rag-sync.log"
  run _run check_rag_sync_freshness
  echo "$output"
  [[ "$output" == *'"category":"RSY"'* ]]
}

@test "a rag-sync log that has ONLY been skipping for 8 nights is reported, not clean" {
  : > "$TMP/logs/rag-sync.log"
  for d in 8 7 6 5 4 3 2 1; do
    echo "$(date -u -d "$d days ago" +%FT%TZ) rag-sync part disabled (parts.state / global / .rag-sync-paused) — skipping" >> "$TMP/logs/rag-sync.log"
  done
  run _run check_rag_sync_freshness
  echo "$output"
  [[ "$output" == *'"category":"RSY"'* ]]
  [[ "$output" == *'"priority":"high"'* ]]
}

@test "a rag-sync log 8 days stale grades HIGH, not medium" {
  { echo "$(date -u -d '8 days ago' +%FT%TZ) rag-sync done (pl rag exit=0)"; } > "$TMP/logs/rag-sync.log"
  run _run check_rag_sync_freshness
  echo "$output"
  [[ "$output" == *'"priority":"high"'* ]]
}

@test "a MISSING rag-sync log is UNKNOWN, not clean" {
  export NWP_OVERSIGHT_CRON=present
  rm -f "$TMP/logs/rag-sync.log"
  run _run check_rag_sync_freshness
  echo "$output"
  [[ "$output" == *'"id":"UNK-rag_sync"'* ]]
}
