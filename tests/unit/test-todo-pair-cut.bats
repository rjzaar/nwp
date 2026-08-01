#!/usr/bin/env bats
#
# test-todo-pair-cut.bats — check_demo_pair_cut (D17).
#
# THE DEFECT THIS PINS (observed, 2026-08-02)
#   ops#170 shipped the paired LIVE erasure: both halves of the demo pair are
#   restored to ONE cut, a mis-tiered cut is refused, and a half-failed reset
#   writes sites/<provider>/demo-pair-INCONSISTENT.json. Measured state of the
#   real fleet on the day this was written:
#
#     $ ls -1 /home/rob/nwp/sites/*/demo-golden-live/pair.cut.json
#     (none)
#
#   Both nwd and ssd hold live goldens; neither shares a cut. So the paired live
#   path will REFUSE the first time anyone reaches for it — which will be during
#   an incident. And the SPLIT record was read by exactly one thing: `pl demo
#   status`, if a human ran it, for the right site, at the right tier.
#
#   Neither fact reached `pl todo` or `pl rag`. This check is what makes them
#   visible without anyone running a verb by hand.
#
# NEGATIVE CONTROLS are load-bearing here: a monitor that fires on a healthy
# pair is a monitor that gets ignored, and one that fires on the REAL ssc<->nwc
# pair would be reporting on production students.

setup() {
  ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  TMP="$BATS_TEST_TMPDIR/paircut"
  mkdir -p "$TMP/pairs" "$TMP/sites"
  cat > "$TMP/nwp.yml" <<'EOF'
settings:
  todo:
    categories: {}
    thresholds: {}
EOF
  export TODO_CONFIG_FILE="$TMP/nwp.yml"
  export TODO_CACHE_DIR="$TMP/cache"
}

# A demo-enabled contract, the shape pairs/ssd.pair-contract.yml has.
_contract() { # $1=provider $2=consumer
  cat > "$TMP/pairs/$2.pair-contract.yml" <<EOF
pair: $2-$1
provider: $1
consumer: $2
demo:
  enabled: true
  paired_golden: true
  paired_reset: true
EOF
}

_golden() { # $1=site $2=db-sha $3=files-sha  → a live golden with a manifest
  local d="$TMP/sites/$1/demo-golden-live"
  mkdir -p "$d"
  printf '{"site":"%s","db_sha256":"%s","files_sha256":"%s"}\n' "$1" "$2" "$3" \
    > "$d/golden.manifest.json"
  : > "$d/golden.db.sql.gz"
}

_cut() { # $1=prov $2=cons $3=tier $4..$7 = pdb pfiles cdb cfiles
  cat > "$TMP/sites/$1/demo-golden-live/pair.cut.json" <<EOF
{
  "type": "demo-golden-pair-cut",
  "pair": "$2-$1",
  "tier": "$3",
  "cut_id": "20260802T000000Z-deadbeef",
  "provider": { "site": "$1", "db_sha256": "$4", "files_sha256": "$5" },
  "consumer": { "site": "$2", "db_sha256": "$6", "files_sha256": "$7" }
}
EOF
}

A=$(printf 'a%.0s' {1..64}); B=$(printf 'b%.0s' {1..64})
C=$(printf 'c%.0s' {1..64}); D=$(printf 'd%.0s' {1..64})
X=$(printf 'x%.0s' {1..64})

_run_check() {
  bash -c '
    set +e
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CHECKS_PROJECT_ROOT="'"$TMP"'"
    TODO_CONFIG_FILE="'"$TMP"'/nwp.yml"
    todo_clear_items
    check_demo_pair_cut
    printf "%s\n" "${TODO_ITEMS[@]}"
  '
}

# ─────────────────────────────────────────────────────────────────────────────

@test "no live goldens on this host: silent no-op (CI runners must stay quiet)" {
  _contract prov cons
  run _run_check
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s' "$output" | tr -d '[:space:]')" ]
}

@test "THE REAL STATE TODAY: both halves have a live golden, neither has a cut" {
  _contract prov cons
  _golden prov "$A" "$B"
  _golden cons "$C" "$D"
  run _run_check
  [ "$status" -eq 0 ]
  [[ "$output" == *'"category":"PCUT"'* ]]
  [[ "$output" == *'"id":"PCUT-nocut-prov"'* ]]
  [[ "$output" == *"the paired live path has never run"* ]]
  [[ "$output" == *"will REFUSE"* ]]
  [[ "$output" == *'"site":"prov"'* ]]
}

@test "NEGATIVE CONTROL: a valid, binding live cut produces NO finding" {
  _contract prov cons
  _golden prov "$A" "$B"
  _golden cons "$C" "$D"
  _cut prov cons live "$A" "$B" "$C" "$D"
  run _run_check
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s' "$output" | tr -d '[:space:]')" ]
}

@test "a SPLIT is SEC/high — the grade that turns pl rag RED and opens an issue" {
  _contract prov cons
  _golden prov "$A" "$B"
  _golden cons "$C" "$D"
  _cut prov cons live "$A" "$B" "$C" "$D"
  cat > "$TMP/sites/prov/demo-pair-INCONSISTENT.json" <<'EOF'
{"type":"demo-pair-inconsistent","provider":"prov","consumer":"cons",
 "cut_id":"cut-live-1","failed_half":"consumer","detail":"cmd_reset_live rc=1",
 "recorded_utc":"2026-08-02T03:00:00Z",
 "repair":"pl demo reset prov --with-pair --tier=live"}
EOF
  run _run_check
  [ "$status" -eq 0 ]
  [[ "$output" == *'"category":"SEC"'* ]]
  [[ "$output" == *'"priority":"high"'* ]]
  [[ "$output" == *"PAIR SPLIT"* ]]
  [[ "$output" == *"consumer"* ]]
  [[ "$output" == *"cut-live-1"* ]]
  [[ "$output" == *"2026-08-02T03:00:00Z"* ]]
}

@test "a DEV cut sitting in the live golden dir is reported high, not accepted" {
  _contract prov cons
  _golden prov "$A" "$B"
  _golden cons "$C" "$D"
  _cut prov cons dev "$A" "$B" "$C" "$D"
  run _run_check
  [[ "$output" == *'"id":"PCUT-wrongtier-prov"'* ]]
  [[ "$output" == *'"priority":"high"'* ]]
  [[ "$output" == *"'dev' pair cut"* ]]
}

@test "sha drift: one half re-captured alone breaks the binding" {
  _contract prov cons
  _golden prov "$A" "$B"
  _golden cons "$X" "$D"      # consumer db re-captured on its own
  _cut prov cons live "$A" "$B" "$C" "$D"
  run _run_check
  [[ "$output" == *'"id":"PCUT-drift-prov"'* ]]
  [[ "$output" == *'"priority":"high"'* ]]
  [[ "$output" == *"cons db"* ]]
}

@test "a cut naming another pair binds nothing here" {
  _contract prov cons
  _golden prov "$A" "$B"
  _golden cons "$C" "$D"
  # A cut for a DIFFERENT pair, copied into prov's live golden dir.
  mkdir -p "$TMP/sites/other/demo-golden-live"
  _cut other someone live "$A" "$B" "$C" "$D"
  cp "$TMP/sites/other/demo-golden-live/pair.cut.json" \
     "$TMP/sites/prov/demo-golden-live/pair.cut.json"
  run _run_check
  [[ "$output" == *'"id":"PCUT-wrongpair-prov"'* ]]
}

@test "only one half has a live golden: says so rather than demanding a cut" {
  _contract prov cons
  _golden prov "$A" "$B"
  run _run_check
  [[ "$output" == *'"id":"PCUT-half-cons"'* ]]
  [[ "$output" == *'"priority":"medium"'* ]]
}

@test "NEGATIVE CONTROL: the REAL ssc<->nwc pair (no demo: block) stays invisible" {
  # Verbatim shape of pairs/ssc.pair-contract.yml: real students, no demo block.
  cat > "$TMP/pairs/ssc.pair-contract.yml" <<'EOF'
pair: ssc-nwc
provider: nwc
consumer: ssc
identity:
  coupled_tiers: [live, prod]
EOF
  _golden nwc "$A" "$B"
  _golden ssc "$C" "$D"
  run _run_check
  [ "$status" -eq 0 ]
  # It must NOT produce a pair-cut finding for a pair that never opted in...
  [[ "$output" != *"PCUT-nocut-nwc"* ]]
  # ...but it must not go quiet either: goldens with no demo pair is UNKNOWN.
  [[ "$output" == *'"category":"UNK"'* ]]
  [[ "$output" == *"unenforced"* ]]
}

@test "UNKNOWN, not silence, when a cut cannot be parsed" {
  _contract prov cons
  _golden prov "$A" "$B"
  _golden cons "$C" "$D"
  printf 'not json at all\n' > "$TMP/sites/prov/demo-golden-live/pair.cut.json"
  run _run_check
  [[ "$output" == *'"unknown":true'* ]]
  [[ "$output" == *"will not parse"* ]]
}

@test "UNKNOWN when jq is unavailable — a blind check never reports clean" {
  _contract prov cons
  _golden prov "$A" "$B"
  _golden cons "$C" "$D"
  mkdir -p "$TMP/bin"
  run bash -c '
    set +e
    export PATH="'"$TMP"'/nojq:/usr/bin:/bin"
    mkdir -p "'"$TMP"'/nojq"
    # a PATH with no jq
    source "'"$ROOT"'/lib/todo-checks.sh"
    TODO_CHECKS_PROJECT_ROOT="'"$TMP"'"
    TODO_CONFIG_FILE="'"$TMP"'/nwp.yml"
    command -v jq >/dev/null 2>&1 && { echo "SKIP: jq still on PATH"; exit 0; }
    todo_clear_items
    check_demo_pair_cut
    printf "%s\n" "${TODO_ITEMS[@]}"
  '
  [[ "$output" == *"SKIP:"* ]] || {
    [[ "$output" == *'"unknown":true'* ]]
    [[ "$output" == *"jq is not installed"* ]]
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Registration — an unregistered check is a check that never runs
# ─────────────────────────────────────────────────────────────────────────────

@test "the check is registered in TODO_CHECK_LIST and exported" {
  run grep -c '"check_demo_pair_cut:' "$ROOT/lib/todo-checks.sh"
  [ "$output" = "1" ]
  run grep -c '^export -f check_demo_pair_cut$' "$ROOT/lib/todo-checks.sh"
  [ "$output" = "1" ]
}

@test "the registry can dispatch it by index (the TUI/progressive path)" {
  run bash -c '
    source "'"$ROOT"'/lib/todo-checks.sh"
    for i in $(seq 0 $(( ${#TODO_CHECK_LIST[@]} - 1 ))); do
      case "${TODO_CHECK_LIST[$i]}" in check_demo_pair_cut:*) echo "FOUND $i"; exit 0 ;; esac
    done
    echo MISSING
  '
  [[ "$output" == FOUND* ]]
}
