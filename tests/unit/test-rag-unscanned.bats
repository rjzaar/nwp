#!/usr/bin/env bats
# Item 2 (oversight-honesty): `pl rag` must have an "I am blind" state.
#
# Defect this locks down: rag rendered a site with NO audit record, and a site
# whose audit record says "I could not scan you", identically to an audited-clean
# site — `security: 0`, grade GREEN. Adding a site to the fleet therefore made the
# fleet look SAFER. dir/hidden/ssc1 and every Moodle site sat in exactly that hole.
#
# Contract now:
#   - a site with no audit record, or a record with `scanned: false`, is UNSCANNED
#   - UNSCANNED renders `-` in the SEC column, never `0`
#   - UNSCANNED can never grade GREEN (AMBER floor)
#   - the JSON envelope carries scanned:false so `pl rag --sync-issues` can file it

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  TMP="$BATS_TEST_TMPDIR/rag"
  mkdir -p "$TMP/audit" "$TMP/state"
  TODO_JSON="$TMP/todo.json"
  echo '{"items":[]}' > "$TODO_JSON"
}

_audit_record() { # $1=site $2=scanned(true|false) [$3=security_count]
  local site="$1" scanned="$2" seccount="${3:-0}"
  python3 - "$TMP/audit/$site.json" "$site" "$scanned" "$seccount" <<'PY'
import sys, json
path, site, scanned, seccount = sys.argv[1:5]
scanned = (scanned == "true")
json.dump({"site": site, "checked": "2026-07-26T00:00:00Z",
           "security_count": int(seccount), "ignored_count": 0, "outdated_count": 0,
           "cache_stale": (not scanned), "scanned": scanned,
           "stale_reason": ("" if scanned else "ddev not running")},
          open(path, "w"), indent=2)
PY
}

# Run only rag's rendering core, with the audit/todo inputs under our control.
_run_rag() {
  RED=$'\e[31m' YEL=$'\e[33m' GRN=$'\e[32m' NC=$'\e[0m' BOLD=$'\e[1m' \
  AUDIT_DIR="$TMP/audit" STATE_DIR="$TMP/state" TODO_JSON="$TODO_JSON" \
  SITE="" JSON="${1:-}" PHASES="" MATURITIES="" \
  python3 "$ROOT/lib/rag-render.py"
}

@test "an audited-clean site grades GREEN and shows 0" {
  _audit_record clean true
  run _run_rag
  echo "$output"
  [[ "$output" =~ clean ]]
  run python3 -c "
import json;d=json.load(open('$TMP/state/state.json'))
r=[x for x in d['sites'] if x['site']=='clean'][0]
print(r['rag'], r['security'], r.get('scanned'))"
  [ "$output" = "GREEN 0 True" ]
}

@test "a site whose record says scanned:false must NOT grade GREEN and must render '-'" {
  _audit_record blind false
  run _run_rag
  echo "$output"
  run python3 -c "
import json;d=json.load(open('$TMP/state/state.json'))
r=[x for x in d['sites'] if x['site']=='blind'][0]
print(r['rag'], r.get('scanned'))"
  [ "$output" = "AMBER False" ]

  run _run_rag
  # SEC column must be a dash, not a zero
  [[ "$output" =~ blind[^$'\n']*[[:space:]]-[[:space:]] ]]
}

@test "a site with todo work but no audit record at all is UNSCANNED, not GREEN" {
  cat > "$TODO_JSON" <<'EOF'
{"items":[{"site":"neveraudited","priority":"low","category":"GWK","title":"drift"}]}
EOF
  run _run_rag
  run python3 -c "
import json;d=json.load(open('$TMP/state/state.json'))
r=[x for x in d['sites'] if x['site']=='neveraudited'][0]
print(r['rag'], r.get('scanned'))"
  [ "$output" = "AMBER False" ]
}

@test "the fleet summary counts unscanned sites separately" {
  _audit_record clean true
  _audit_record blind false
  run _run_rag
  echo "$output"
  [[ "$output" == *"unscanned"* ]]
  run python3 -c "
import json;print(json.load(open('$TMP/state/state.json'))['summary']['UNSCANNED'])"
  [ "$output" = "1" ]
}

@test "a legacy Moodle record poisoned by the greedy-sed bug is UNSCANNED, not GREEN" {
  # These records are on disk RIGHT NOW for ss / ss2 / ssc / ssd. They claim
  # cache_stale:false and security_count:0, but both version fields hold the
  # literal comment fragment the old parser produced — proof that no comparison
  # ever happened. They must not keep grading GREEN until someone re-audits.
  python3 - "$TMP/audit/ss.json" <<'PY'
import sys, json
json.dump({"site":"ss","checked":"2026-07-25T17:50:01Z","platform":"moodle",
  "security_count":0,"ignored_count":0,"outdated_count":0,"cache_stale":False,
  "moodle_branch":"404","moodle_installed":"4.4.12+(Build:20251212)",
  "moodle_latest":"4.4.12+(Build:20251212)",
  "moodle_installed_version":"branchingdateYYYYMMDD-donotmodify!",
  "moodle_latest_version":"branchingdateYYYYMMDD-donotmodify!"},
  open(sys.argv[1],"w"), indent=2)
PY
  run _run_rag
  echo "$output"
  run python3 -c "
import json;d=json.load(open('$TMP/state/state.json'))
r=[x for x in d['sites'] if x['site']=='ss'][0]
print(r['rag'], r['scanned'])"
  [ "$output" = "AMBER False" ]
}

@test "a Moodle record with real numeric versions is trusted" {
  python3 - "$TMP/audit/ok.json" <<'PY'
import sys, json
json.dump({"site":"ok","checked":"2026-07-25T17:50:01Z","platform":"moodle",
  "security_count":0,"ignored_count":0,"outdated_count":0,"cache_stale":False,
  "scanned":True,"moodle_branch":"404",
  "moodle_installed_version":"2024042212.01",
  "moodle_latest_version":"2024042212.01"},
  open(sys.argv[1],"w"), indent=2)
PY
  run _run_rag
  run python3 -c "
import json;d=json.load(open('$TMP/state/state.json'))
r=[x for x in d['sites'] if x['site']=='ok'][0]
print(r['rag'], r['scanned'])"
  [ "$output" = "GREEN True" ]
}

@test "an unreadable/corrupt audit record is UNSCANNED, not an absent site" {
  printf 'this is not json' > "$TMP/audit/broken.json"
  run _run_rag
  run python3 -c "
import json;d=json.load(open('$TMP/state/state.json'))
r=[x for x in d['sites'] if x['site']=='broken'][0]
print(r['rag'], r['scanned'])"
  [ "$output" = "AMBER False" ]
}

@test "an unknown todo item (UNK-*) forces AMBER even with a clean audit" {
  _audit_record probe true
  cat > "$TODO_JSON" <<'EOF'
{"items":[{"site":"probe","priority":"medium","category":"UNK","unknown":true,"title":"could not reach host"}]}
EOF
  run _run_rag
  run python3 -c "
import json;d=json.load(open('$TMP/state/state.json'))
r=[x for x in d['sites'] if x['site']=='probe'][0]
print(r['rag'], r['unknown'])"
  [ "$output" = "AMBER 1" ]
}
