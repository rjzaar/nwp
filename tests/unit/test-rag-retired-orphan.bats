#!/usr/bin/env bats
# A grade computed against a site that does not exist is not a grade.
#
# DEFECT THIS LOCKS DOWN (found 2026-08-11 on the live board).
#
# `pl rag` builds one row per file in private/update-awareness/. Nothing ever
# checks that the named site still EXISTS. Two real consequences on the fleet
# board that day:
#
#   1. ORPHAN. One site key in nwp.yml was a duplicate registration of ANOTHER
#      site's dev environment — same `directory:`, different key. It was removed
#      from nwp.yml, but its private/update-awareness/<name>.json survived. So
#      the board carried a permanent RED row whose 4 advisories were the other
#      site's, counted a second time under a second name: a red grade against a
#      site that had not existed for weeks, which no patching could ever clear.
#
#   2. RETIRED. A frozen, superseded site had its webroot renamed aside on the
#      host, no vhost served it, and its domain did not answer at all — yet it
#      graded RED on 13 dependency advisories exactly as if it were serving
#      traffic. A site that is RED forever, and is MEANT to be, teaches the
#      reader to ignore red — the ops#214 disease in another costume.
#
# CONTRACT NOW — three states, never two:
#   - a record whose site is in KNOWN_SITES              → graded as today
#   - a record whose site is NOT in KNOWN_SITES          → ORPHAN: CANNOT VERIFY,
#     never RED, counted apart from the fleet's R/A/G
#   - a record carrying `retired`                        → RETIRED: not graded at
#     all, counted apart, and its stale `security_count` is never rendered as a
#     live finding
#
# FAIL-CLOSED DIRECTION. KNOWN_SITES absent/empty means "the caller could not
# tell us what exists", which must NOT silently orphan the whole fleet. Absent
# ⇒ orphan detection is OFF and every record grades as before.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  TMP="$BATS_TEST_TMPDIR/rag"
  mkdir -p "$TMP/audit" "$TMP/state"
  TODO_JSON="$TMP/todo.json"
  echo '{"items":[]}' > "$TODO_JSON"
}

# A normal, measured record with N advisories.
_audit_record() { # $1=site $2=security_count
  python3 - "$TMP/audit/$1.json" "$1" "$2" <<'PY'
import sys, json
path, site, sec = sys.argv[1:4]
json.dump({"site": site, "checked": "2026-08-11T00:00:00Z",
           "security_count": int(sec), "ignored_count": 0, "outdated_count": 0,
           "cache_stale": False, "scanned": True, "stale_reason": ""},
          open(path, "w"), indent=2)
PY
}

# A record written by `pl audit` for a site declared retired.
_retired_record() { # $1=site $2=stale_security_count $3=retired-date
  python3 - "$TMP/audit/$1.json" "$1" "$2" "$3" <<'PY'
import sys, json
path, site, sec, when = sys.argv[1:5]
json.dump({"site": site, "checked": "2026-08-11T00:00:00Z",
           "security_count": int(sec), "ignored_count": 0, "outdated_count": 0,
           "cache_stale": False, "scanned": False, "retired": when,
           "retired_reason": "frozen 2026-07-01; webroot retired on the live box",
           "stale_reason": "site is RETIRED — not scanned"},
          open(path, "w"), indent=2)
PY
}

_run_rag() { # $1=JSON  $2=KNOWN_SITES
  RED=$'\e[31m' YEL=$'\e[33m' GRN=$'\e[32m' NC=$'\e[0m' BOLD=$'\e[1m' \
  AUDIT_DIR="$TMP/audit" STATE_DIR="$TMP/state" TODO_JSON="$TODO_JSON" \
  SITE="" JSON="${1:-}" PHASES="" MATURITIES="" KNOWN_SITES="${2-}" \
  python3 "$ROOT/lib/rag-render.py"
}

_grade_of() { # $1=site — read the grade out of the JSON envelope
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for r in d["sites"]:
    if r["site"]==sys.argv[2]: print(r["rag"]); break
else: print("ABSENT")' "$TMP/state/state.json" "$1"
}

################################################################################
# 1. ORPHAN — a record for a site that no longer exists
################################################################################

@test "orphan: a record whose site is absent from KNOWN_SITES does not grade RED" {
  _audit_record dev 4          # the real dev.json shape: 4 advisories, measured
  _audit_record nwc 0
  run _run_rag true "nwc sitea siteb"
  [ "$status" -eq 0 ] || [ "$status" -eq 3 ]
  # The precise defect: `dev` graded RED off a stale count for a deleted site.
  refute_grade_red dev
}

refute_grade_red() {
  local g; g=$(_grade_of "$1")
  if [ "$g" = "RED" ]; then
    echo "EXPECTED: '$1' must not grade RED (it does not exist); GOT: RED" >&2
    return 1
  fi
}

@test "orphan: the row is labelled ORPHAN and says CANNOT VERIFY, not a number" {
  _audit_record dev 4
  run _run_rag "" "nwc sitea siteb"
  echo "$output"
  [[ "$output" == *"ORPHAN"* ]]
  # It must name the reason rather than presenting 4 as a live finding.
  [[ "$output" == *"no such site"* ]]
}

@test "orphan: it is counted apart from the fleet R/A/G, not folded into amber" {
  _audit_record dev 4
  _audit_record nwc 0
  _run_rag true "nwc" || true
  run python3 -c '
import json
d=json.load(open("'"$TMP"'/state/state.json"))
print("ORPHANCOUNT", d["summary"].get("ORPHAN"))
print("RED", d["summary"]["RED"])'
  echo "$output"
  [[ "$output" == *"ORPHANCOUNT 1"* ]]
  [[ "$output" == *"RED 0"* ]]
}

@test "orphan: the envelope names the orphans so a consumer can act" {
  _audit_record dev 4
  _run_rag true "nwc" || true
  run python3 -c '
import json
d=json.load(open("'"$TMP"'/state/state.json"))
print(json.dumps(d.get("orphans","MISSING")))'
  echo "$output"
  [[ "$output" == *"dev"* ]]
}

@test "FAIL-CLOSED: no KNOWN_SITES means orphan detection is OFF, not everything orphaned" {
  _audit_record dev 4
  _audit_record nwc 0
  _run_rag true "" || true
  run python3 -c '
import json
d=json.load(open("'"$TMP"'/state/state.json"))
print("ORPHANCOUNT", d["summary"].get("ORPHAN",0))
print("RED", d["summary"]["RED"])'
  echo "$output"
  # Nothing is known, so nothing may be declared non-existent; dev grades RED
  # exactly as it did before, which is the honest answer to "I was not told".
  [[ "$output" == *"ORPHANCOUNT 0"* ]]
  [[ "$output" == *"RED 1"* ]]
}

################################################################################
# 2. RETIRED — a site declared out of service
################################################################################

@test "retired: a declared-retired site does not grade RED on its stale advisories" {
  _retired_record siteb 13 "2026-08-07"
  _audit_record nwc 0
  run _run_rag true "siteb nwc"
  echo "$output"
  refute_grade_red siteb
}

@test "retired: the row says RETIRED and carries the date, not a live SEC number" {
  _retired_record siteb 13 "2026-08-07"
  run _run_rag "" "siteb nwc"
  echo "$output"
  [[ "$output" == *"RETIRED"* ]]
  [[ "$output" == *"2026-08-07"* ]]
}

@test "retired: it is counted apart and does not inflate UNSCANNED" {
  _retired_record siteb 13 "2026-08-07"
  _audit_record nwc 0
  _run_rag true "siteb nwc" || true
  run python3 -c '
import json
d=json.load(open("'"$TMP"'/state/state.json"))
s=d["summary"]
print("RETIRED", s.get("RETIRED"), "RED", s["RED"], "UNSCANNED", s["UNSCANNED"])'
  echo "$output"
  [[ "$output" == *"RETIRED 1"* ]]
  [[ "$output" == *"RED 0"* ]]
  # A retired site is not a blind spot — we are not failing to look at it, we
  # have decided there is nothing to look at.
  [[ "$output" == *"UNSCANNED 0"* ]]
}

@test "retired: a retired site still present and serving would be a lie we can catch" {
  # A retirement is a CLAIM about the world. The record keeps the evidence
  # (retired_reason) so `pl rag --json` can be audited against reality later.
  _retired_record siteb 13 "2026-08-07"
  _run_rag true "siteb" || true
  run python3 -c '
import json
d=json.load(open("'"$TMP"'/state/state.json"))
r=[x for x in d["sites"] if x["site"]=="siteb"][0]
print(r.get("retired"), "|", r.get("retired_reason"))'
  echo "$output"
  [[ "$output" == *"2026-08-07"* ]]
  [[ "$output" == *"frozen 2026-07-01"* ]]
}

################################################################################
# 3. The two states must not be confused with each other, or with clean
################################################################################

@test "a retired site and an orphan record are distinguishable in the envelope" {
  _retired_record siteb 13 "2026-08-07"
  _audit_record dev 4
  _audit_record nwc 0
  _run_rag true "siteb nwc" || true
  run python3 -c '
import json
d=json.load(open("'"$TMP"'/state/state.json"))
for r in d["sites"]:
    print(r["site"], r["rag"], r.get("retired") or "-", r.get("orphan") or "-")'
  echo "$output"
  [[ "$output" == *"siteb RETIRED 2026-08-07 -"* ]]
  [[ "$output" == *"dev ORPHAN - True"* ]]
  [[ "$output" == *"nwc GREEN - -"* ]]
}

@test "neither state may be rendered as GREEN" {
  _retired_record siteb 13 "2026-08-07"
  _audit_record dev 4
  _run_rag true "siteb" || true
  run python3 -c '
import json
d=json.load(open("'"$TMP"'/state/state.json"))
print(d["summary"]["GREEN"])'
  echo "$output"
  # Retiring a site must not be a way to manufacture green.
  [ "${lines[0]}" = "0" ]
}

@test "the UNSCANNED count and the UNSCANNED list must describe the same set" {
  # Regression: the count excluded retired/orphan rows but the list printed
  # them, so the board said "8 site(s) could not be scanned" above a list of 12.
  # A summary number that does not describe the rows beneath it is the same
  # defect class as everything else in this file.
  _retired_record siteb 13 "2026-08-07"
  _audit_record dev 4
  python3 - "$TMP/audit/dir.json" <<'PY'
import sys, json
json.dump({"site":"dir","checked":"2026-08-11T00:00:00Z","security_count":0,
           "ignored_count":0,"cache_stale":True,"scanned":False,
           "stale_reason":"no ddev binary"}, open(sys.argv[1],"w"))
PY
  run _run_rag "" "siteb dir"
  echo "$output"
  n_claimed=$(echo "$output" | grep -oE '[0-9]+ site\(s\) could not be scanned' | grep -oE '^[0-9]+')
  n_listed=$(echo "$output" | sed -n '/site(s) could not be scanned/,/state →/p' | grep -cE '^    - ')
  echo "claimed=$n_claimed listed=$n_listed"
  [ "$n_claimed" = "$n_listed" ]
}
