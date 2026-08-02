#!/usr/bin/env bats
# ops#230 — the estate's oversight was BLIND from 2026-07-17 to 2026-08-02 and
# nothing said so. Sixteen nights. Two independent causes, either alone enough:
#
#   1. `.loop-paused` — a WRITE kill — also stopped the READ-ONLY oversight half.
#      rag-sync.sh's own header comment described this exact failure costing 8
#      nights in July, the fix shipped as an opt-in flag defaulting to OFF, and
#      it promptly recurred.
#   2. the crontab went empty, so lifting the pause would have restarted nothing.
#
# Consequence: guzzle advisories published 2026-07-20 flipped three sites
# AMBER→RED and no issue was ever updated; a site (cccrdf) sat RED with 51
# advisories having never had an issue at all.
#
# Per ops#214 every guard here is proven able to FAIL, not merely to pass: each
# contract has a paired negative case that puts the system into the broken state
# and asserts the guard fires.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$BATS_TEST_TMPDIR/ovr"
  mkdir -p "$TMP/logs"
  export NWP_ROOT="$TMP"
  export NWP_LOOP_STATE="$TMP/parts.state"
  unset NWP_LOOP_UNIFIED_GATES NWP_OVERSIGHT_CRON NWP_OVERSIGHT_HOST
}

_done_line() { # $1 = "N days ago"
  printf '%s rag-sync done (pl rag exit=3)\n' "$(date -u -d "$1" +%FT%TZ)" >> "$TMP/logs/rag-sync.log"
}

_probe() { # runs oversight_probe in a subshell, echoes STATE GRADE
  bash -c '
    set -u
    NWP_ROOT="'"$TMP"'"; export NWP_ROOT
    NWP_LOOP_STATE="'"$TMP"'/parts.state"; export NWP_LOOP_STATE
    . "'"$ROOT"'/lib/loop-parts.sh"
    . "'"$ROOT"'/lib/oversight-freshness.sh"
    oversight_probe
    printf "%s %s\n" "$OVERSIGHT_STATE" "$OVERSIGHT_GRADE"
    printf "%s\n" "$OVERSIGHT_DETAIL"
  '
}

_parts() { # run an expression against lib/loop-parts.sh
  bash -c '
    set -u
    NWP_ROOT="'"$TMP"'"; export NWP_ROOT
    NWP_LOOP_STATE="'"$TMP"'/parts.state"; export NWP_LOOP_STATE
    . "'"$ROOT"'/lib/loop-parts.sh"
    '"$1"'
  '
}

################################################################################
# CONTRACT 1 — the write-kill does not silence oversight.
################################################################################

@test "capability table: rag-sync is observe, every other part is write" {
  run _parts 'for p in "${LOOP_PARTS[@]}"; do printf "%s=%s\n" "$p" "$(loop_part_capability "$p")"; done'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rag-sync=observe"* ]]
  [[ "$output" == *"fix-loop=write"* ]]
  [[ "$output" == *"respawn-drain=write"* ]]
  [[ "$output" == *"webhook=write"* ]]
}

@test "every declared part has a capability (an undeclared one must not slip in as observe)" {
  run _parts 'bad=0; for p in "${LOOP_PARTS[@]}"; do
      c="$(loop_part_capability "$p")"
      case "$c" in write|observe) ;; *) echo "UNDECLARED $p"; bad=1 ;; esac
    done; exit $bad'
  [ "$status" -eq 0 ]
}

@test "GREEN: .loop-paused stops fix-loop but NOT rag-sync" {
  touch "$TMP/.loop-paused"
  run _parts 'loop_part_enabled fix-loop && echo FIXLOOP-ON || echo FIXLOOP-OFF
              loop_part_enabled rag-sync && echo RAGSYNC-ON || echo RAGSYNC-OFF'
  [[ "$output" == *"FIXLOOP-OFF"* ]]
  [[ "$output" == *"RAGSYNC-ON"* ]]
}

@test "GREEN: parts.state all=disabled stops fix-loop but NOT rag-sync" {
  printf 'all=disabled\n' > "$TMP/parts.state"
  run _parts 'loop_part_enabled fix-loop && echo FIXLOOP-ON || echo FIXLOOP-OFF
              loop_part_enabled rag-sync && echo RAGSYNC-ON || echo RAGSYNC-OFF'
  [[ "$output" == *"FIXLOOP-OFF"* ]]
  [[ "$output" == *"RAGSYNC-ON"* ]]
}

@test "RED-PROOF: the pre-ops#230 conflation (NWP_LOOP_UNIFIED_GATES=1) DOES silence oversight" {
  # If this ever passes without the env var, the split has stopped being real.
  touch "$TMP/.loop-paused"
  run bash -c '
    NWP_ROOT="'"$TMP"'" NWP_LOOP_STATE="'"$TMP"'/parts.state" NWP_LOOP_UNIFIED_GATES=1 \
    bash -c ". \"'"$ROOT"'/lib/loop-parts.sh\"; loop_part_enabled rag-sync && echo ON || echo OFF"'
  [[ "$output" == *"OFF"* ]]
}

@test "the separate OVERSIGHT kill DOES stop rag-sync (the switch exists and works)" {
  touch "$TMP/.oversight-paused"
  run _parts 'loop_part_enabled rag-sync && echo ON || echo OFF; loop_part_disabled_reason rag-sync'
  [[ "$output" == *"OFF"* ]]
  [[ "$output" == *"OVERSIGHT kill"* ]]
}

@test "the oversight kill does NOT stop the write parts (the two switches are independent)" {
  touch "$TMP/.oversight-paused"
  run _parts 'loop_part_enabled fix-loop && echo ON || echo OFF'
  [[ "$output" == *"ON"* ]]
}

@test "rag-sync's own sentinel still stops it, and says which switch did it" {
  touch "$TMP/.rag-sync-paused"
  run _parts 'loop_part_enabled rag-sync && echo ON || echo OFF; loop_part_disabled_reason rag-sync'
  [[ "$output" == *"OFF"* ]]
  [[ "$output" == *".rag-sync-paused"* ]]
}

@test "the cron WRAPPER honours the split: .loop-paused present, rag-sync still runs" {
  # Build a fake runtime tree with a stub ./pl so the wrapper can complete.
  mkdir -p "$TMP/wrap/logs" "$TMP/wrap/lib" "$TMP/wrap/scripts/agent-loop"
  cp "$ROOT/lib/loop-parts.sh" "$TMP/wrap/lib/"
  cp "$ROOT/scripts/agent-loop/rag-sync.sh" "$TMP/wrap/scripts/agent-loop/"
  printf '#!/bin/bash\necho "stub pl $*"\nexit 3\n' > "$TMP/wrap/pl"; chmod +x "$TMP/wrap/pl"
  touch "$TMP/wrap/.loop-paused"
  NWP_DIR="$TMP/wrap" NWP_LOOP_STATE="$TMP/parts.state" \
    bash "$TMP/wrap/scripts/agent-loop/rag-sync.sh"
  run cat "$TMP/wrap/logs/rag-sync.log"
  [[ "$output" == *"rag-sync done"* ]]
  [[ "$output" == *"observe"* ]]        # it says WHY it continued
  [[ "$output" != *"DISABLED"* ]]
}

@test "RED-PROOF: the same wrapper DOES skip when its own sentinel is set, with a reason" {
  mkdir -p "$TMP/wrap2/logs" "$TMP/wrap2/lib" "$TMP/wrap2/scripts/agent-loop"
  cp "$ROOT/lib/loop-parts.sh" "$TMP/wrap2/lib/"
  cp "$ROOT/scripts/agent-loop/rag-sync.sh" "$TMP/wrap2/scripts/agent-loop/"
  printf '#!/bin/bash\nexit 0\n' > "$TMP/wrap2/pl"; chmod +x "$TMP/wrap2/pl"
  touch "$TMP/wrap2/.rag-sync-paused"
  NWP_DIR="$TMP/wrap2" NWP_LOOP_STATE="$TMP/parts.state" \
    bash "$TMP/wrap2/scripts/agent-loop/rag-sync.sh"
  run cat "$TMP/wrap2/logs/rag-sync.log"
  [[ "$output" == *"DISABLED"* ]]
  [[ "$output" == *"Reason:"* ]]
  [[ "$output" != *"rag-sync done"* ]]
}

################################################################################
# CONTRACT 2 — a stale or absent sync run is DETECTED and grades RED.
################################################################################

@test "GREEN: a run completed today with a schedule in place is LIVE/GREEN" {
  _done_line "2 hours ago"
  run bash -c 'NWP_OVERSIGHT_CRON=present NWP_ROOT="'"$TMP"'" NWP_LOOP_STATE="'"$TMP"'/parts.state" bash -c "
    . \"'"$ROOT"'/lib/loop-parts.sh\"; . \"'"$ROOT"'/lib/oversight-freshness.sh\"
    oversight_probe; printf \"%s %s\n\" \"\$OVERSIGHT_STATE\" \"\$OVERSIGHT_GRADE\""'
  [[ "$output" == "LIVE GREEN" ]]
}

@test "RED: the real ops#230 shape — last completed run 16 days ago — is STALE/RED" {
  _done_line "16 days ago"
  run bash -c 'NWP_OVERSIGHT_CRON=present NWP_ROOT="'"$TMP"'" NWP_LOOP_STATE="'"$TMP"'/parts.state" bash -c "
    . \"'"$ROOT"'/lib/loop-parts.sh\"; . \"'"$ROOT"'/lib/oversight-freshness.sh\"
    oversight_probe; printf \"%s %s\n%s\n\" \"\$OVERSIGHT_STATE\" \"\$OVERSIGHT_GRADE\" \"\$OVERSIGHT_DETAIL\""'
  [[ "$output" == *"STALE RED"* ]]
  [[ "$output" == *"16d ago"* ]]
}

@test "AMBER: 3 days is AGING, not yet RED (the threshold is a real boundary, not a constant)" {
  _done_line "3 days ago"
  run bash -c 'NWP_OVERSIGHT_CRON=present NWP_ROOT="'"$TMP"'" NWP_LOOP_STATE="'"$TMP"'/parts.state" bash -c "
    . \"'"$ROOT"'/lib/loop-parts.sh\"; . \"'"$ROOT"'/lib/oversight-freshness.sh\"
    oversight_probe; printf \"%s %s\n\" \"\$OVERSIGHT_STATE\" \"\$OVERSIGHT_GRADE\""'
  [[ "$output" == "AGING AMBER" ]]
}

@test "RED: the second ops#230 cause — an EMPTY crontab — is NOSCHEDULE/RED even with a log present" {
  _done_line "6 hours ago"     # it ran this morning; nothing will run it again
  run bash -c 'NWP_OVERSIGHT_CRON=absent NWP_ROOT="'"$TMP"'" NWP_LOOP_STATE="'"$TMP"'/parts.state" bash -c "
    . \"'"$ROOT"'/lib/loop-parts.sh\"; . \"'"$ROOT"'/lib/oversight-freshness.sh\"
    oversight_probe; printf \"%s %s\n%s\n\" \"\$OVERSIGHT_STATE\" \"\$OVERSIGHT_GRADE\" \"\$OVERSIGHT_DETAIL\""'
  [[ "$output" == *"NOSCHEDULE RED"* ]]
  [[ "$output" == *"NO cron entry"* ]]
}

@test "RED: a log full of 'skipping' and no completed run ever is NEVER/RED" {
  printf '%s rag-sync part disabled — skipping\n' "$(date -u +%FT%TZ)" > "$TMP/logs/rag-sync.log"
  run bash -c 'NWP_OVERSIGHT_CRON=present NWP_ROOT="'"$TMP"'" NWP_LOOP_STATE="'"$TMP"'/parts.state" bash -c "
    . \"'"$ROOT"'/lib/loop-parts.sh\"; . \"'"$ROOT"'/lib/oversight-freshness.sh\"
    oversight_probe; printf \"%s %s\n\" \"\$OVERSIGHT_STATE\" \"\$OVERSIGHT_GRADE\""'
  [[ "$output" == "NEVER RED" ]]
}

@test "RED: a WRITE kill reaching the read half is SILENCED/RED and names ops#230" {
  touch "$TMP/.loop-paused"
  _done_line "1 hour ago"
  run bash -c 'NWP_LOOP_UNIFIED_GATES=1 NWP_OVERSIGHT_CRON=present NWP_ROOT="'"$TMP"'" NWP_LOOP_STATE="'"$TMP"'/parts.state" bash -c "
    . \"'"$ROOT"'/lib/loop-parts.sh\"; . \"'"$ROOT"'/lib/oversight-freshness.sh\"
    oversight_probe; printf \"%s %s\n%s\n\" \"\$OVERSIGHT_STATE\" \"\$OVERSIGHT_GRADE\" \"\$OVERSIGHT_DETAIL\""'
  [[ "$output" == *"SILENCED RED"* ]]
  [[ "$output" == *"ops#230"* ]]
}

@test "AMBER: a deliberate switch-off is OFF/AMBER — recorded, never silent, never RED" {
  touch "$TMP/.oversight-paused"
  _done_line "1 hour ago"
  run bash -c 'NWP_OVERSIGHT_CRON=present NWP_ROOT="'"$TMP"'" NWP_LOOP_STATE="'"$TMP"'/parts.state" bash -c "
    . \"'"$ROOT"'/lib/loop-parts.sh\"; . \"'"$ROOT"'/lib/oversight-freshness.sh\"
    oversight_probe; printf \"%s %s\n%s\n\" \"\$OVERSIGHT_STATE\" \"\$OVERSIGHT_GRADE\" \"\$OVERSIGHT_DETAIL\""'
  [[ "$output" == *"OFF AMBER"* ]]
  [[ "$output" == *"switched off, not broken"* ]]
}

@test "AMBER: no log at all is UNKNOWN, never clean" {
  run bash -c 'NWP_OVERSIGHT_CRON=present NWP_ROOT="'"$TMP"'" NWP_LOOP_STATE="'"$TMP"'/parts.state" bash -c "
    . \"'"$ROOT"'/lib/loop-parts.sh\"; . \"'"$ROOT"'/lib/oversight-freshness.sh\"
    oversight_probe; printf \"%s %s\n\" \"\$OVERSIGHT_STATE\" \"\$OVERSIGHT_GRADE\""'
  [[ "$output" == "UNKNOWN AMBER" ]]
}

@test "AMBER: a host that does not own the schedule cannot assert GREEN about it" {
  _done_line "1 hour ago"
  run bash -c 'NWP_OVERSIGHT_HOST=some-other-host NWP_OVERSIGHT_CRON=absent NWP_ROOT="'"$TMP"'" NWP_LOOP_STATE="'"$TMP"'/parts.state" bash -c "
    . \"'"$ROOT"'/lib/loop-parts.sh\"; . \"'"$ROOT"'/lib/oversight-freshness.sh\"
    oversight_probe; printf \"%s %s\n\" \"\$OVERSIGHT_STATE\" \"\$OVERSIGHT_GRADE\""'
  [[ "$output" == "DELEGATED AMBER" ]]
}

################################################################################
# CONTRACT 3 — a RED oversight state reaches `pl rag` as RED, not as mild amber.
################################################################################

@test "lib/rag-render.py grades a high RSY item RED and exits 3" {
  mkdir -p "$TMP/audit" "$TMP/state"
  cat > "$TMP/todo.json" <<'EOF'
{"items":[{"id":"RSY-stale","category":"RSY","priority":"high",
           "title":"oversight STALE — rag-sync is not turning the fleet's RAG grade into issues",
           "description":"16d","site":"","unknown":false}]}
EOF
  run env AUDIT_DIR="$TMP/audit" TODO_JSON="$TMP/todo.json" STATE_DIR="$TMP/state" \
      SITE="" JSON=true PHASES="" MATURITIES="" RED="" YEL="" GRN="" NC="" BOLD="" DIM="" \
      python3 "$ROOT/lib/rag-render.py"
  [ "$status" -eq 3 ]
  [[ "$output" == *'"rag": "RED"'* ]] || [[ "$output" == *'"rag":"RED"'* ]]
}

@test "RED-PROOF: the same item at medium priority does NOT force RED (the rule is priority-scoped)" {
  mkdir -p "$TMP/audit" "$TMP/state"
  cat > "$TMP/todo.json" <<'EOF'
{"items":[{"id":"RSY-aging","category":"RSY","priority":"medium",
           "title":"oversight AGING","description":"3d","site":"","unknown":false}]}
EOF
  run env AUDIT_DIR="$TMP/audit" TODO_JSON="$TMP/todo.json" STATE_DIR="$TMP/state" \
      SITE="" JSON=true PHASES="" MATURITIES="" RED="" YEL="" GRN="" NC="" BOLD="" DIM="" \
      python3 "$ROOT/lib/rag-render.py"
  [ "$status" -eq 0 ]
}

@test "pl todo files a HIGH RSY item when the oversight loop is stale" {
  _done_line "16 days ago"
  cat > "$TMP/nwp.yml" <<'EOF'
settings:
  todo:
    categories: {}
    thresholds: {}
EOF
  run bash -c '
    set +e
    NWP_OVERSIGHT_CRON=present
    export NWP_OVERSIGHT_CRON NWP_ROOT NWP_LOOP_STATE
    NWP_ROOT="'"$TMP"'"; NWP_LOOP_STATE="'"$TMP"'/parts.state"
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CHECKS_PROJECT_ROOT="'"$TMP"'"
    TODO_CONFIG_FILE="'"$TMP"'/nwp.yml"
    todo_clear_items
    check_rag_sync_freshness
    printf "%s\n" "${TODO_ITEMS[@]:-}"
  '
  [[ "$output" == *'"category":"RSY"'* ]]
  [[ "$output" == *'"priority":"high"'* ]]
  [[ "$output" == *"STALE"* ]]
}

################################################################################
# CONTRACT 4 — ops#204: exactly ONE check definition survives, and we can say
#              which category gate controls it.
################################################################################

@test "check_rag_sync_freshness is defined exactly once" {
  run grep -c '^check_rag_sync_freshness() {' "$ROOT/lib/todo-checks.sh"
  [ "$output" = "1" ]
}

@test "check_rag_sync_freshness is listed exactly once in TODO_CHECK_LIST" {
  run grep -c '"check_rag_sync_freshness:' "$ROOT/lib/todo-checks.sh"
  [ "$output" = "1" ]
}

@test "check_rag_sync_freshness is exported exactly once" {
  run grep -c '^export -f check_rag_sync_freshness$' "$ROOT/lib/todo-checks.sh"
  [ "$output" = "1" ]
}

@test "the surviving body is gated on the rag_sync category (NOT loop_liveness)" {
  # Deleting the other definition would have silently swapped the gate. State it.
  run bash -c "sed -n '/^check_rag_sync_freshness() {/,/^}/p' \"$ROOT/lib/todo-checks.sh\" | head -3"
  [[ "$output" == *'is_category_enabled "rag_sync"'* ]]
}

@test "RED-PROOF: setting categories.rag_sync=false silences the check (proving that IS the gate)" {
  _done_line "16 days ago"
  cat > "$TMP/nwp.yml" <<'EOF'
settings:
  todo:
    categories:
      rag_sync: false
    thresholds: {}
EOF
  run bash -c '
    set +e
    export NWP_OVERSIGHT_CRON=present
    export NWP_ROOT="'"$TMP"'" NWP_LOOP_STATE="'"$TMP"'/parts.state"
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CHECKS_PROJECT_ROOT="'"$TMP"'"
    TODO_CONFIG_FILE="'"$TMP"'/nwp.yml"
    todo_clear_items
    check_rag_sync_freshness
    printf "%s\n" "${TODO_ITEMS[@]:-}"
  '
  [[ "$output" != *'"category":"RSY"'* ]]
}

@test "loop_liveness still gates its own live check (the deleted body left no orphan category)" {
  run grep -c 'is_category_enabled "loop_liveness"' "$ROOT/lib/todo-checks.sh"
  [ "$output" = "1" ]
}

################################################################################
# CONTRACT 5 — a site missing from a run is REPORTED, not skipped.
################################################################################

_plan() { # $1 = state json, $2 = existing issues json, $3 = eligible csv
  STATE="$1" EXISTING="$2" ELIGIBLE="$3" PID=21 NOW="2026-08-02T00:00:00Z" \
    python3 "$ROOT/lib/rag-sync-plan.py"
}

@test "an eligible site absent from the run yields an 'absent' action, not silence" {
  echo '{"sites":[{"site":"nwc","rag":"RED","security":3,"todo_high":1,"todo_med":0,"todo_low":0,"top":"x"}]}' > "$TMP/state.json"
  existing='[{"iid":42,"title":"[RAG] cccrdf: needs attention","labels":["rag-auto","site::cccrdf"],
              "description":"<!-- rag-auto:v1 grade=AMBER sec=0 site=cccrdf -->\nbody"}]'
  run _plan "$TMP/state.json" "$existing" "nwc,cccrdf"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"act": "absent"'* ]]
  [[ "$output" == *"cccrdf"* ]]
  [[ "$output" == *"STALE"* ]]
}

@test "the absence is recorded on the issue exactly once (idempotent via absent=1)" {
  echo '{"sites":[]}' > "$TMP/state.json"
  first='[{"iid":42,"title":"t","labels":["rag-auto","site::cccrdf"],
           "description":"<!-- rag-auto:v1 grade=AMBER sec=0 site=cccrdf -->\nbody"}]'
  run _plan "$TMP/state.json" "$first" "cccrdf"
  [[ "$output" == *"record the absence"* ]]
  [[ "$output" == *"absent=1"* ]]

  # second night: already stamped -> report it, but do not comment again
  again='[{"iid":42,"title":"t","labels":["rag-auto","site::cccrdf"],
           "description":"<!-- rag-auto:v1 absent=1 grade=AMBER sec=0 site=cccrdf -->\nbody"}]'
  run _plan "$TMP/state.json" "$again" "cccrdf"
  [[ "$output" == *'"act": "absent"'* ]]
  [[ "$output" == *"already recorded"* ]]
  [[ "$output" != *"record the absence"* ]]
}

@test "an absent site's issue is NOT auto-closed (absence is not evidence of clean)" {
  echo '{"sites":[]}' > "$TMP/state.json"
  existing='[{"iid":42,"title":"t","labels":["rag-auto","site::cccrdf"],
              "description":"<!-- rag-auto:v1 grade=RED sec=51 site=cccrdf -->\nbody"}]'
  run _plan "$TMP/state.json" "$existing" "cccrdf"
  [[ "$output" != *'"act": "close"'* ]]
}

@test "a site that RETURNS after an absence retracts the stale-grade warning" {
  echo '{"sites":[{"site":"cccrdf","rag":"RED","security":51,"todo_high":0,"todo_med":0,"todo_low":0,"top":"x"}]}' > "$TMP/state.json"
  existing='[{"iid":42,"title":"[RAG] cccrdf: security advisories","labels":["rag-auto","site::cccrdf","priority::high","security"],
              "description":"<!-- rag-auto:v1 absent=1 grade=RED sec=51 site=cccrdf -->\nbody"}]'
  run _plan "$TMP/state.json" "$existing" "cccrdf"
  [[ "$output" == *"back in the run"* ]]
}

@test "RED-PROOF: an eligible site PRESENT in the run produces no absent action" {
  echo '{"sites":[{"site":"nwc","rag":"AMBER","security":0,"todo_high":0,"todo_med":1,"todo_low":0,"top":"x"}]}' > "$TMP/state.json"
  run _plan "$TMP/state.json" '[]' "nwc"
  [[ "$output" != *'"act": "absent"'* ]]
  [[ "$output" == *'"act": "create"'* ]]
}

@test "an eligible site absent with NO open issue is still named in the plan" {
  echo '{"sites":[]}' > "$TMP/state.json"
  run _plan "$TMP/state.json" '[]' "cccrdf"
  [[ "$output" == *'"act": "absent"'* ]]
  [[ "$output" == *"no open rag-auto issue"* ]]
}

################################################################################
# CONTRACT 6 — the schedule is owned by a verb, not by hand.
################################################################################

@test "pl loop schedule install is dry-run by default and writes nothing" {
  before="$(crontab -l 2>/dev/null | md5sum)"
  run "$ROOT/scripts/commands/loop.sh" schedule install
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  after="$(crontab -l 2>/dev/null | md5sum)"
  [ "$before" = "$after" ]
}

@test "the managed block is delimited by markers so a re-install cannot duplicate" {
  run "$ROOT/scripts/commands/loop.sh" schedule install
  [[ "$output" == *">>> nwp loop schedule"* ]]
  [[ "$output" == *"<<< nwp loop schedule <<<"* ]]
  [[ "$output" == *"rag-sync.sh"* ]]
}

@test "pl loop schedule --host delegates to pl host schedule and does not touch local cron" {
  before="$(crontab -l 2>/dev/null | md5sum)"
  run "$ROOT/scripts/commands/loop.sh" schedule install --host nwpcode
  after="$(crontab -l 2>/dev/null | md5sum)"
  [ "$before" = "$after" ]
  [[ "$output" == *"pl host schedule"* ]] || [[ "$output" == *"DRY RUN"* ]]
}
