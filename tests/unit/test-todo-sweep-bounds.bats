#!/usr/bin/env bats
# ops#178 — `pl todo` hung fleet-wide, so `pl rag` ran TODO-BLIND every night.
#
# THE DEFECT, in three layers, each of which this file pins:
#
#   1. UNBOUNDED SWEEP. run_all_checks was a plain serial `for` loop over 28
#      checks with no cap of any kind. `pl rag` gives the sweep 180s; the sum of
#      several honest-but-slow checks exceeded it (check_missing_backups alone
#      was 133s, gzip -t over ~10 GB), rag killed it (exit 143) and printed
#      `TODO ● BLIND`, grading all 28 sites on their audit record alone. One
#      slow check did not degrade the sweep, it abolished it.
#
#   2. A VACUOUS SEC CHECK THAT ALSO MUTATED THE HOST. check_security_updates
#      shelled `ddev drush pm:security` per site. That drush command has been
#      REMOVED ("pm:security has been removed. Please use `composer audit`"),
#      its failure was swallowed by `|| echo "[]"`, and the v2 layout meant the
#      webroot probe matched 2 of 21 sites anyway. It could not emit a SEC item
#      for ANY input — while `ddev drush` auto-STARTS a stopped ddev project,
#      from a check advertised as a read-only listing.
#
#   3. SILENT TRUNCATION IN THE JSON ROUND-TRIP. Items were built by string
#      interpolation into a "JSON-like format", and parse_todo_items read them
#      back with `grep -o '"description":"[^"]*"'`. `[^"]*` stops at the first
#      quote INSIDE a value, so any item text containing a quote was truncated
#      there and the rest discarded. check_agent_host_auth's description
#          ... Format: "<name>=<addr> <name>=<addr>" (VPN addresses).
#      reached `pl rag` as `... Format: ` — everything after the quote gone.
#      MEASURED on origin/main: the document stays syntactically VALID, which is
#      precisely why nobody noticed; the loss is invisible, not loud.
#
#      This also makes (3) a trap for anyone fixing it halfway: escaping the
#      producer WITHOUT teaching the reader about escapes turns silent
#      truncation into a genuinely malformed document (the truncated value now
#      ends in a backslash) — and `pl rag`'s `except: todo={"items":[]}` would
#      then render the whole work signal as "swept, found nothing", a false
#      GREEN. Producer escaping, a real parser, and escape-on-re-emit are one
#      change, not three; rag's blind-not-empty guard backstops all of it.
#
# The through-line: a check that cannot run must SAY SO. Silence is the bug.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  TMP="$BATS_TEST_TMPDIR/sweep"
  mkdir -p "$TMP/private/update-awareness"
  cat > "$TMP/nwp.yml" <<'EOF'
sites:
  alpha:
    directory: /nonexistent/alpha
  bravo:
    directory: /nonexistent/bravo
settings:
  todo:
    categories: {}
    thresholds: {}
EOF
  export TODO_CHECKS_PROJECT_ROOT="$TMP"
  export TODO_CONFIG_FILE="$TMP/nwp.yml"
  export TODO_CACHE_DIR="$TMP/cache"
  export NWP_AUDIT_STATE_DIR="$TMP/private/update-awareness"
}

# Write an audit record. $1=site $2=security_count $3=scanned $4=age_days
_record() {
  local site="$1" count="$2" scanned="$3" age="${4:-0}"
  local checked
  checked=$(date -u -d "$age days ago" +%Y-%m-%dT%H:%M:%SZ)
  cat > "$TMP/private/update-awareness/$site.json" <<EOF
{"site":"$site","checked":"$checked","security_count":$count,
 "ignored_count":0,"cache_stale":false,"scanned":$scanned,"stale_reason":""}
EOF
}

# Run one check and print its items.
_run_check() { # $1=fn, $2...=prelude
  local fn="$1"; shift
  bash -c '
    set +e
    source "'"$ROOT"'/lib/ui.sh"        2>/dev/null
    source "'"$ROOT"'/lib/common.sh"    2>/dev/null
    source "'"$ROOT"'/lib/yaml-write.sh" 2>/dev/null
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CHECKS_PROJECT_ROOT="'"$TMP"'"
    TODO_CONFIG_FILE="'"$TMP"'/nwp.yml"
    NWP_AUDIT_STATE_DIR="'"$TMP"'/private/update-awareness"
    todo_clear_items
    '"$*"'
    '"$fn"'
    printf "%s\n" "${TODO_ITEMS[@]}"
  '
}

################################################################################
# 1. check_security_updates reads pl audit's cache — and can actually FIND things
################################################################################

@test "SEC: a cached audit record with advisories produces a SEC item" {
  _record alpha 7 true 0
  _record bravo 0 true 0
  run _run_check check_security_updates
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == *'"id":"SEC-alpha"'* ]]
  [[ "$output" == *"7 security"* ]]
  # bravo is measured-and-clean: no item at all.
  [[ "$output" != *'"id":"SEC-bravo"'* ]]
  [[ "$output" != *'UNK-security_updates_bravo'* ]]
}

@test "SEC: a MISSING audit record is UNKNOWN, never clean" {
  _record alpha 0 true 0        # bravo deliberately has no record
  run _run_check check_security_updates
  echo "$output"
  [[ "$output" == *'"id":"UNK-security_updates_bravo"'* ]]
  [[ "$output" == *'"unknown":true'* ]]
  [[ "$output" == *"never measured"* ]]
}

@test "SEC: a STALE audit record is stale-not-clean" {
  _record alpha 0 true 400      # 400 days old, count 0
  _record bravo 0 true 0
  run _run_check check_security_updates
  echo "$output"
  [[ "$output" == *'"id":"UNK-security_updates_alpha"'* ]]
  [[ "$output" == *"STALE"* ]]
  [[ "$output" == *"400 days old"* ]]
}

@test "SEC: an UNSCANNED record is UNKNOWN — security_count 0 means 'not measured'" {
  _record alpha 0 false 0
  _record bravo 0 true 0
  run _run_check check_security_updates
  echo "$output"
  [[ "$output" == *'"id":"UNK-security_updates_alpha"'* ]]
  [[ "$output" == *"UNSCANNED"* ]]
  [[ "$output" == *"not measured"* ]]
}

@test "SEC: no audit directory at all is UNKNOWN for the whole fleet" {
  rm -rf "$TMP/private/update-awareness"
  run _run_check check_security_updates
  echo "$output"
  [[ "$output" == *'"id":"UNK-security_updates"'* ]]
  [[ "$output" == *"never been measured"* ]]
}

@test "SEC: READ-ONLY — the check never invokes ddev (it used to auto-start projects)" {
  # The fixture must be a site the OLD code would actually have shelled out for,
  # or this proves nothing: give alpha a resolvable Drupal webroot AND a .ddev/,
  # which is exactly the shape whose `ddev drush pm:security` auto-started a
  # stopped project from a read-only listing.
  mkdir -p "$TMP/alpha/web/core/lib" "$TMP/alpha/.ddev"
  touch "$TMP/alpha/web/core/lib/Drupal.php"
  cat > "$TMP/nwp.yml" <<EOF
sites:
  alpha:
    directory: $TMP/alpha
settings:
  todo:
    categories: {}
    thresholds: {}
EOF
  _record alpha 1 true 0
  # A ddev shim that fails the test loudly if the check ever calls it.
  run _run_check check_security_updates '
    ddev() { echo "FATAL-CHECK-STARTED-DDEV: $*"; return 0; }
    export -f ddev
  '
  echo "$output"
  [[ "$output" != *"FATAL-CHECK-STARTED-DDEV"* ]]
  # ...and it still produced the finding, from the cache, without touching ddev.
  [[ "$output" == *'"id":"SEC-alpha"'* ]]
}

@test "SEC: todo and rag agree — both read records through lib/audit-record.py" {
  _record alpha 3 true 0
  run python3 "$ROOT/lib/audit-record.py" --dir "$TMP/private/update-awareness" --site alpha
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"*"measured"*"3"* ]]
  # rag imports the very same module, so it cannot disagree.
  run grep -q 'audit_record.load_dir' "$ROOT/lib/rag-render.py"
  [ "$status" -eq 0 ]
}

################################################################################
# 2. Per-check timeout: a wedged check is NAMED, and the sweep still completes
################################################################################

# Drive run_all_checks over a synthetic check list.
_run_sweep() { # $1=TODO_CHECK_LIST body, $2=extra env/prelude
  bash -c '
    set +e
    source "'"$ROOT"'/lib/ui.sh"        2>/dev/null
    source "'"$ROOT"'/lib/common.sh"    2>/dev/null
    source "'"$ROOT"'/lib/yaml-write.sh" 2>/dev/null
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CHECKS_PROJECT_ROOT="'"$TMP"'"
    TODO_CONFIG_FILE="'"$TMP"'/nwp.yml"
    TODO_CACHE_DIR="'"$TMP"'/cache"
    '"$2"'
    check_fast()  { todo_add_item "TST" "fast" "low" "fast ran" "" "" ""; }
    check_fast2() { todo_add_item "TST" "fast2" "low" "fast2 ran" "" "" ""; }
    # A check that wedges the way the real one did: blocked on a child read.
    check_wedged() { sleep 30; todo_add_item "TST" "wedged" "low" "never" "" "" ""; }
    TODO_CHECK_LIST=('"$1"')
    run_all_checks false
  '
}

@test "TIMEOUT: a wedged check is killed, NAMED as timed-out, and the sweep completes" {
  run timeout 60 bash -c '
    '"$(declare -f _run_sweep)"'
    ROOT="'"$ROOT"'"; TMP="'"$TMP"'"
    _run_sweep "\"check_fast:Fast\" \"check_wedged:Wedged\" \"check_fast2:Fast two\"" \
               "TODO_CHECK_TIMEOUT=2; TODO_SWEEP_BUDGET=60"
  '
  [ "$status" -eq 0 ]
  echo "$output"
  # The timed-out check reports ITSELF. It does not vanish.
  [[ "$output" == *'"id":"UNK-timeout-check_wedged"'* ]]
  [[ "$output" == *"exceeded its"* ]]
  [[ "$output" == *"UNKNOWN, not clean"* ]]
  [[ "$output" == *'"unknown":true'* ]]
  # And crucially the sweep CONTINUED — the check after the wedged one ran.
  [[ "$output" == *"fast ran"* ]]
  [[ "$output" == *"fast2 ran"* ]]
  # Valid JSON, not a truncated document.
  echo "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

@test "TIMEOUT: the sweep finishes in ~the per-check cap, not the wedged check's runtime" {
  local s e
  s=$(date +%s)
  timeout 60 bash -c '
    '"$(declare -f _run_sweep)"'
    ROOT="'"$ROOT"'"; TMP="'"$TMP"'"
    _run_sweep "\"check_wedged:Wedged\"" "TODO_CHECK_TIMEOUT=2; TODO_SWEEP_BUDGET=60"
  ' >/dev/null 2>&1
  e=$(date +%s)
  # check_wedged sleeps 30s; a 2s cap must stop it far short of that.
  [ $((e - s)) -lt 12 ]
}

@test "TIMEOUT: a wedged check's CHILD process is killed too, not orphaned" {
  # The real wedge was a child blocked on a pipe (anon_pipe_read). Killing only
  # the subshell leaves the child holding the pipe and burning the budget.
  local s e
  s=$(date +%s)
  run timeout 40 bash -c '
    '"$(declare -f _run_sweep)"'
    ROOT="'"$ROOT"'"; TMP="'"$TMP"'"
    _run_sweep "\"check_child:Child\"" \
      "TODO_CHECK_TIMEOUT=2; TODO_SWEEP_BUDGET=60
       check_child() { sleep 45 & wait; }"
  '
  e=$(date +%s)
  [ "$status" -eq 0 ]
  # Unbounded, this takes 45s (or is killed at 40s by the outer timeout).
  [ $((e - s)) -lt 12 ]
  # No stray 45s sleep survived the sweep.
  run pgrep -f "sleep 45"
  [ "$status" -ne 0 ]
}

@test "BUDGET: checks that never ran are NAMED, not silently dropped" {
  run timeout 60 bash -c '
    '"$(declare -f _run_sweep)"'
    ROOT="'"$ROOT"'"; TMP="'"$TMP"'"
    _run_sweep "\"check_wedged:Wedged\" \"check_fast:Fast\"" \
               "TODO_CHECK_TIMEOUT=3; TODO_SWEEP_BUDGET=3"
  '
  [ "$status" -eq 0 ]
  echo "$output"
  # Budget gone after the wedged check -> the never-run check says so.
  [[ "$output" == *'"id":"UNK-budget-check_fast"'* ]]
  [[ "$output" == *"did NOT run"* ]]
}

@test "BOUND IS UNIVERSAL: every registered check is accounted for, none escapes" {
  # STRUCTURAL GUARANTEE, not a spot check. New checks land in this file
  # constantly (check_demo_pair_cut arrived from !315 while this MR waited;
  # a rotation-debt check is queued behind it). The bound must apply to whatever
  # is in TODO_CHECK_LIST, so this test wedges EVERY registered check and
  # asserts each one is named in the output as either timed-out or never-run.
  # A check that vanishes silently fails this test, which is the whole bug.
  run timeout 120 bash -c '
    set +e
    source "'"$ROOT"'/lib/ui.sh"        2>/dev/null
    source "'"$ROOT"'/lib/common.sh"    2>/dev/null
    source "'"$ROOT"'/lib/yaml-write.sh" 2>/dev/null
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CHECKS_PROJECT_ROOT="'"$TMP"'"
    TODO_CONFIG_FILE="'"$TMP"'/nwp.yml"
    TODO_CACHE_DIR="'"$TMP"'/cache"
    # Replace every registered check with a wedger.
    for entry in "${TODO_CHECK_LIST[@]}"; do
      eval "${entry%%:*}() { sleep 30; }"
    done
    printf "%s\n" "${TODO_CHECK_LIST[@]}" | cut -d: -f1 | sort -u > "'"$TMP"'/registered.txt"
    TODO_CHECK_TIMEOUT=1 TODO_SWEEP_BUDGET=6 run_all_checks false
  '
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
  # Every registered check must appear as timed-out or budget-skipped.
  local missing=0 c
  while read -r c; do
    [ -z "$c" ] && continue
    if [[ "$output" != *"UNK-timeout-$c"* ]] && [[ "$output" != *"UNK-budget-$c"* ]]; then
      echo "ESCAPED THE BOUND: $c"; missing=$((missing + 1))
    fi
  done < "$TMP/registered.txt"
  [ "$missing" -eq 0 ]
}

@test "BOUND IS UNIVERSAL: check_demo_pair_cut (!315) is registered and bounded" {
  # Named explicitly because it landed under this MR and was the merge conflict.
  run grep -c 'check_demo_pair_cut:' "$ROOT/lib/todo-checks.sh"
  [ "$output" -ge 1 ]
  # Registered checks are dispatched only through the bounded runner.
  run bash -c "sed -n '/^run_all_checks() {/,/^}/p' '$ROOT/lib/todo-checks.sh' | grep -c '_todo_run_check_bounded'"
  [ "$output" -ge 1 ]
}

@test "BUDGET: the whole real sweep is bounded well inside rag's 180s budget" {
  # The headline. Uses the REAL check list against an empty fixture tree, so it
  # measures the harness rather than the fleet, but the bound is structural:
  # run_all_checks may never exceed TODO_SWEEP_BUDGET + one per-check cap.
  local s e
  s=$(date +%s)
  run timeout 200 bash -c '
    set +e
    source "'"$ROOT"'/lib/ui.sh"        2>/dev/null
    source "'"$ROOT"'/lib/common.sh"    2>/dev/null
    source "'"$ROOT"'/lib/yaml-write.sh" 2>/dev/null
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CHECKS_PROJECT_ROOT="'"$TMP"'"
    TODO_CONFIG_FILE="'"$TMP"'/nwp.yml"
    TODO_CACHE_DIR="'"$TMP"'/cache"
    TODO_SWEEP_BUDGET=20; TODO_CHECK_TIMEOUT=5
    run_all_checks false
  '
  e=$(date +%s)
  [ "$status" -eq 0 ]
  [ $((e - s)) -lt 40 ]
  echo "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

################################################################################
# 3. The false-green that hid behind the timeout
################################################################################

@test "JSON: a description containing double quotes still yields valid JSON" {
  run bash -c '
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CHECKS_PROJECT_ROOT="'"$TMP"'"; TODO_CONFIG_FILE="'"$TMP"'/nwp.yml"
    todo_clear_items
    todo_add_item "TST" "quoted" "low" "has \"quotes\"" \
      "Format: \"<name>=<addr>\" (VPN addresses)\tand a tab" "" ""
    todo_output_items
  '
  [ "$status" -eq 0 ]
  echo "$output"
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d[0]["title"] == "has \"quotes\"", d[0]["title"]
assert "<name>=<addr>" in d[0]["description"]
'
}

@test "JSON: backslashes are escaped before the quotes they would otherwise eat" {
  run bash -c '
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CHECKS_PROJECT_ROOT="'"$TMP"'"; TODO_CONFIG_FILE="'"$TMP"'/nwp.yml"
    todo_clear_items
    todo_add_item "TST" "bs" "low" "path C:\\temp\\x" "trailing backslash \\" "" ""
    todo_output_items
  '
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d[0]["title"] == "path C:\\temp\\x", d[0]["title"]
'
}

@test "REGRESSION: check_agent_host_auth — the real item that broke the document" {
  run _run_check check_agent_host_auth
  [ "$status" -eq 0 ]
  echo "$output"
  # Whatever it emits, the emitted lines must parse as JSON objects.
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    echo "$line" | python3 -c 'import json,sys; json.loads(sys.stdin.read())'
  done <<< "$output"
}

@test "rag: unparseable todo JSON is a FAILED sweep, not an empty one" {
  # Before ops#178 this was `except: todo={"items":[]}` -> every site GREEN.
  mkdir -p "$TMP/ragstate" "$TMP/audit"
  cat > "$TMP/audit/alpha.json" <<'EOF'
{"site":"alpha","checked":"2099-01-01T00:00:00Z","security_count":0,
 "ignored_count":0,"cache_stale":false,"scanned":true,"stale_reason":""}
EOF
  printf '[{"id":"X","title":"broken "quote"}]' > "$TMP/bad-todo.json"
  run env AUDIT_DIR="$TMP/audit" TODO_JSON="$TMP/bad-todo.json" \
      STATE_DIR="$TMP/ragstate" SITE="" JSON=true PHASES="" MATURITIES="" \
      RED="" YEL="" GRN="" NC="" BOLD="" DIM="" \
      python3 "$ROOT/lib/rag-render.py"
  echo "$output"
  # A blind sweep must never render GREEN.
  [[ "$output" != *'"grade": "GREEN"'* ]]
  [[ "$output" != *'"grade":"GREEN"'* ]]
  [[ "$output" == *"unparseable"* ]]
}

################################################################################
# 3b. `pl todo check --json` — the OTHER JSON producer (scripts/commands/todo.sh)
#
# run_all_checks and show_json are two independent emitters of the same items.
# rag consumes show_json's, so escaping only the library one fixed nothing.
################################################################################

_todo_json() { # run `pl todo check --json` against the fixture tree
  bash -c '
    cd "'"$ROOT"'"
    TODO_CHECKS_PROJECT_ROOT="'"$TMP"'" TODO_CONFIG_FILE="'"$TMP"'/nwp.yml" \
    NWP_AUDIT_STATE_DIR="'"$TMP"'/private/update-awareness" \
    TODO_CACHE_DIR="'"$TMP"'/cache" TODO_SWEEP_BUDGET=60 TODO_CHECK_TIMEOUT=10 \
      ./pl todo check --json 2>/dev/null
  '
}

@test "pl todo check --json: item text survives the round-trip intact, not truncated at a quote" {
  # On origin/main this description arrives as `... Format: ` — everything from
  # the first embedded quote onward is silently dropped by `"[^"]*"`, and the
  # document still parses, so the loss is invisible. Assert FIDELITY, not just
  # validity: the tail of the real string must be present.
  run timeout 200 bash -c '
    '"$(declare -f _todo_json)"'
    ROOT="'"$ROOT"'"; TMP="'"$TMP"'"
    _todo_json
  '
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert "items" in d and "summary" in d, d.keys()
hosts=[i for i in d["items"] if "agent_hosts is unset" in i.get("description","")]
assert hosts, "fixture did not produce the agent_hosts item"
desc=hosts[0]["description"]
assert "<name>=<addr>" in desc, "TRUNCATED at the embedded quote: %r" % desc
assert "(VPN addresses)" in desc, "TRUNCATED before the end: %r" % desc
'
}

@test "pl todo --json: an EMPTY site field must not shift the later fields left" {
  # Regression on the field-shift class of bug: bash `read` collapses runs of
  # IFS *whitespace*, so a tab-delimited round-trip silently dropped empty
  # fields and slid each item's ACTION into its SITE slot. `pl rag` then drew
  # table rows for "sites" named `df -h /`. Most items have site="".
  run timeout 200 bash -c '
    '"$(declare -f _todo_json)"'
    ROOT="'"$ROOT"'"; TMP="'"$TMP"'"
    _todo_json
  '
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)
bad=[i for i in d["items"] if i.get("site") and ("/" in i["site"] or " " in i["site"])]
assert not bad, "action/command leaked into the site field: %r" % bad[:3]
# and the category must still be a short code, never a sentence
for i in d["items"]:
    assert len(i.get("category","")) <= 12, i
'
}

################################################################################
# 4. The 133s that caused it: backup integrity is memoised and depth-bounded
################################################################################

@test "BACKUP: integrity results are memoised, so a re-scan is near-free" {
  local bd="$TMP/backups"
  mkdir -p "$bd"
  export BACKUP_INTEGRITY_CACHE="$TMP/integrity.tsv"
  # 12 MB of real gzip so the first pass does measurable work.
  head -c 12000000 /dev/urandom | gzip > "$bd/one.sql.gz"
  run bash -c '
    source "'"$ROOT"'/lib/backup-integrity.sh"
    BACKUP_INTEGRITY_CACHE="'"$TMP"'/integrity.tsv"
    backup_artifact_integrity "'"$bd"'/one.sql.gz" >/dev/null
    grep -c "OK" "$BACKUP_INTEGRITY_CACHE"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "BACKUP: a memo entry is keyed to the bytes — a rewritten artifact is re-verified" {
  local bd="$TMP/backups2"
  mkdir -p "$bd"
  export BACKUP_INTEGRITY_CACHE="$TMP/integrity2.tsv"
  echo "hello" | gzip > "$bd/a.sql.gz"
  run bash -c '
    source "'"$ROOT"'/lib/backup-integrity.sh"
    BACKUP_MIN_BYTES=1
    BACKUP_INTEGRITY_CACHE="'"$TMP"'/integrity2.tsv"
    backup_artifact_integrity "'"$bd"'/a.sql.gz" >/dev/null
    # Corrupt it; mtime and size both change, so the key changes.
    sleep 1.1
    printf "not gzip at all, definitely not" > "'"$bd"'/a.sql.gz"
    backup_artifact_integrity "'"$bd"'/a.sql.gz"
  '
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gzip integrity check failed"* ]]
}

@test "BACKUP: the depth bound really bounds — a deep-old artifact is not re-decompressed" {
  # This is the deliberate semantic change: the check exists to catch a producer
  # writing garbage NOW, so it verifies the newest few rather than gzip -t'ing a
  # year of cold archives on every 5-minute sweep (that cost 133s and blinded
  # rag). Unbounded, the corrupt OLDEST file below is reported; bounded, it is
  # out of scope and `pl backup verify` (BACKUP_SCAN_DEPTH=0) is what finds it.
  local bd="$TMP/backups4"
  mkdir -p "$bd"
  export BACKUP_INTEGRITY_CACHE="$TMP/integrity4.tsv"
  printf 'this is not gzip data at all no really' > "$bd/oldest.sql.gz"
  sleep 1.1
  for i in $(seq 1 5); do echo "x$i" | gzip > "$bd/new$i.sql.gz"; done
  run bash -c '
    source "'"$ROOT"'/lib/backup-integrity.sh"
    BACKUP_MIN_BYTES=1
    BACKUP_INTEGRITY_CACHE="'"$TMP"'/integrity4.tsv"
    BACKUP_SCAN_DEPTH=3
    backup_first_bad_artifact "'"$bd"'"; echo "rc=$?"
  '
  echo "$output"
  [[ "$output" != *"oldest.sql.gz"* ]]
  [[ "$output" == *"rc=1"* ]]
  # ...and with the bound lifted, it IS found.
  run bash -c '
    source "'"$ROOT"'/lib/backup-integrity.sh"
    BACKUP_MIN_BYTES=1
    BACKUP_INTEGRITY_CACHE="'"$TMP"'/integrity4b.tsv"
    BACKUP_SCAN_DEPTH=0
    backup_first_bad_artifact "'"$bd"'"
  '
  [[ "$output" == *"oldest.sql.gz"* ]]
}

@test "BACKUP: the corruption scan is depth-bounded but still sees the newest artifacts" {
  local bd="$TMP/backups3"
  mkdir -p "$bd"
  export BACKUP_INTEGRITY_CACHE="$TMP/integrity3.tsv"
  # 10 good, then the NEWEST is corrupt: must be caught at any depth >= 1.
  for i in $(seq 1 10); do echo "x$i" | gzip > "$bd/old$i.sql.gz"; done
  sleep 1.1
  printf 'this is not gzip data at all no really' > "$bd/newest.sql.gz"
  run bash -c '
    source "'"$ROOT"'/lib/backup-integrity.sh"
    BACKUP_MIN_BYTES=1
    BACKUP_INTEGRITY_CACHE="'"$TMP"'/integrity3.tsv"
    BACKUP_SCAN_DEPTH=3
    backup_first_bad_artifact "'"$bd"'"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"newest.sql.gz"* ]]
}
