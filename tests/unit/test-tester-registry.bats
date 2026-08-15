#!/usr/bin/env bats
# The TESTER REGISTRY — lib/tester-registry.sh.
#
# WHY THIS FILE EXISTS
#   The registry is the authority for WHO SURVIVES THE NIGHTLY RESET. The reset
#   leg preserves exactly the accounts named here (identity now; the password
#   hash is harvested from the live sites at reset time and is deliberately NOT
#   stored here — a hash at rest in a file this code writes would be a
#   credential this code is responsible for). Everything else on the demo pair
#   is wiped.
#
#   That makes two failure directions wildly asymmetric:
#
#     * a tester in the registry who has no account  — recoverable, harmless;
#     * an account whose tester is NOT in the registry — the person was told
#       "you're approved" and is silently wiped tonight.
#
#   So every write here is fail-closed, and `tester_registry_add` is the FIRST
#   step of an approval, never the last. A registry write that cannot be proven
#   to have landed must return non-zero so the caller never goes on to create
#   the account.
#
# RED-THEN-GREEN
#   Written against a tree with no lib/tester-registry.sh at all and observed
#   RED (all 24 tests failing: "no such file"). Counts quoted in the commit.

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}/sites/demo1"
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  source "${REPO_ROOT}/lib/tester-registry.sh"

  # The registry home declaration (ops#328 D1) is reused verbatim — the tester
  # registry has the SAME one-writable-home property as the code registry, and
  # a second declaration would be a second policy to drift.
  export NWP_DEMO_REGISTRY_HOME_FILE="${TEST_TMP}/registry-home.yml"
  printf 'registry_home: %s\n' "$(hostname -s)" > "$NWP_DEMO_REGISTRY_HOME_FILE"
}

teardown() {
  rm -rf "${TEST_TMP}"
  unset PROJECT_ROOT NWP_DEMO_REGISTRY_HOME_FILE
}

_reg() { echo "${PROJECT_ROOT}/sites/demo1/demo-testers.json"; }

# --- paths --------------------------------------------------------------------

@test "registry file sits beside the code registry, per site" {
  run tester_registry_file demo1
  [ "$status" -eq 0 ]
  [ "$output" = "${PROJECT_ROOT}/sites/demo1/demo-testers.json" ]
}

@test "registry file requires a site" {
  run tester_registry_file
  [ "$status" -ne 0 ]
}

# --- input validation ---------------------------------------------------------
#
# The registry is the authority for who survives a reset, so a typo here costs
# somebody their login. Every validator asserts its REASON, never just non-zero
# (blind negation is the recorded failure shape — CLAUDE.md).

@test "account name accepts the shapes the site actually mints" {
  for ok in Francis-1234 demo_writer nwcdemo_consenting a.b-c_9; do
    run tester_valid_account "$ok"
    [ "$status" -eq 0 ] || { echo "rejected legitimate account '$ok'"; false; }
  done
}

@test "account name refuses shell metacharacters, spaces and emptiness BY NAME" {
  run tester_valid_account 'a;rm -rf /'
  [ "$status" -ne 0 ]
  [[ "$output" == *"account"* ]]
  run tester_valid_account ''
  [ "$status" -ne 0 ]
  [[ "$output" == *"account"* ]]
  run tester_valid_account 'two words'
  [ "$status" -ne 0 ]
  run tester_valid_account '../../etc/passwd'
  [ "$status" -ne 0 ]
}

@test "account name refuses an over-long value rather than truncating it" {
  run tester_valid_account "$(printf 'a%.0s' {1..200})"
  [ "$status" -ne 0 ]
  [[ "$output" == *"long"* ]]
}

@test "display name accepts ordinary human names including unicode and apostrophes" {
  for ok in "Rob Zaar" "Máire O'Brien" "Jean-Luc"; do
    run tester_valid_display "$ok"
    [ "$status" -eq 0 ] || { echo "rejected legitimate display name '$ok'"; false; }
  done
}

@test "display name refuses control characters and markup, stating why" {
  run tester_valid_display '<script>alert(1)</script>'
  [ "$status" -ne 0 ]
  [[ "$output" == *"display name"* ]]
  run tester_valid_display "$(printf 'a\nb')"
  [ "$status" -ne 0 ]
  run tester_valid_display ''
  [ "$status" -ne 0 ]
}

@test "bundle must be one of the real tester bundles — an apply bundle is refused" {
  run tester_valid_bundle tester-member
  [ "$status" -eq 0 ]
  run tester_valid_bundle apply-auto
  [ "$status" -ne 0 ]
  [[ "$output" == *"bundle"* ]]
  run tester_valid_bundle tester-sitemanager
  [ "$status" -ne 0 ]
}

@test "level is a small non-negative integer, not arbitrary text" {
  run tester_valid_level 2
  [ "$status" -eq 0 ]
  run tester_valid_level 0
  [ "$status" -eq 0 ]
  run tester_valid_level -1
  [ "$status" -ne 0 ]
  run tester_valid_level 99
  [ "$status" -ne 0 ]
  run tester_valid_level "2; drop"
  [ "$status" -ne 0 ]
}

# --- reads: absent vs unreadable ----------------------------------------------
#
# ops#281: a broken registry must NEVER render as an empty clean list. These two
# cases are the whole reason the console can trust the pane.

@test "an ABSENT registry reads as ok:true registry:absent with zero testers" {
  run tester_registry_list_json demo1
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'"registry":"absent"'* ]]
  [[ "$output" == *'"testers":[]'* ]]
}

@test "an UNREADABLE registry is exit 2 CANNOT VERIFY, never an empty list" {
  printf '{ this is not json' > "$(_reg)"
  run tester_registry_list_json demo1
  [ "$status" -eq 2 ]
  [[ "$output" == *'"ok":false'* ]]
  [[ "$output" == *'"registry":"unreadable"'* ]]
  [[ "$output" != *'"testers":[]'* ]]
}

# --- the home guard -----------------------------------------------------------

@test "a write REFUSES on a host that is not the declared registry home" {
  printf 'registry_home: some-other-host\n' > "$NWP_DEMO_REGISTRY_HOME_FILE"
  run tester_registry_add demo1 Francis-1234 "Rob Zaar" tester-member
  [ "$status" -ne 0 ]
  [[ "$output" == *"home"* ]]
  [ ! -f "$(_reg)" ]
}

@test "a write REFUSES when the home is UNDECLARED — fail closed, not open" {
  : > "$NWP_DEMO_REGISTRY_HOME_FILE"
  run tester_registry_add demo1 Francis-1234 "Rob Zaar" tester-member
  [ "$status" -ne 0 ]
  [[ "$output" == *"undeclared"* || "$output" == *"home"* ]]
  [ ! -f "$(_reg)" ]
}

# --- writes -------------------------------------------------------------------

@test "add creates the registry, records the tester, and is readable immediately" {
  run tester_registry_add demo1 Francis-1234 "Rob Zaar" tester-member
  [ "$status" -eq 0 ]
  [ -f "$(_reg)" ]

  run tester_registry_list_json demo1
  [ "$status" -eq 0 ]
  [[ "$output" == *'"registry":"present"'* ]]
  [[ "$output" == *'Francis-1234'* ]]
  [[ "$output" == *'Rob Zaar'* ]]
  [[ "$output" == *'tester-member'* ]]
  [[ "$output" == *'"count":1'* ]]
}

@test "the registry file is 0600 — it names people, and it is not world-readable" {
  tester_registry_add demo1 Francis-1234 "Rob Zaar" tester-member
  run stat -c '%a' "$(_reg)"
  [ "$output" = "600" ]
}

@test "add REFUSES a duplicate account rather than silently making a second row" {
  tester_registry_add demo1 Francis-1234 "Rob Zaar" tester-member
  run tester_registry_add demo1 Francis-1234 "Someone Else" tester-member
  [ "$status" -ne 0 ]
  [[ "$output" == *"already"* ]]
  run tester_registry_list_json demo1
  [[ "$output" == *'"count":1'* ]]
}

@test "add REFUSES invalid input BEFORE touching the file" {
  run tester_registry_add demo1 'bad;name' "Rob Zaar" tester-member
  [ "$status" -ne 0 ]
  [ ! -f "$(_reg)" ]
}

@test "add REFUSES an apply-route bundle — those are never instant testers" {
  run tester_registry_add demo1 Francis-1234 "Rob Zaar" apply-auto
  [ "$status" -ne 0 ]
  [[ "$output" == *"bundle"* ]]
  [ ! -f "$(_reg)" ]
}

@test "a second tester is APPENDED, never clobbering the first" {
  tester_registry_add demo1 Francis-1234 "Rob Zaar" tester-member
  tester_registry_add demo1 Cecilia-99 "Ann Other" tester-content-manager
  run tester_registry_list_json demo1
  [ "$status" -eq 0 ]
  [[ "$output" == *'Francis-1234'* ]]
  [[ "$output" == *'Cecilia-99'* ]]
  [[ "$output" == *'"count":2'* ]]
}

@test "optional attributes round-trip: guild, level, admin, provenance" {
  run tester_registry_add demo1 Francis-1234 "Rob Zaar" tester-member \
      --guild=writers --level=2 --admin --source=join-request --request=r-abc123
  [ "$status" -eq 0 ]
  run tester_registry_list_json demo1
  [[ "$output" == *'"guild":"writers"'* ]]
  [[ "$output" == *'"level":2'* ]]
  [[ "$output" == *'"admin":true'* ]]
  [[ "$output" == *'"source":"join-request"'* ]]
  [[ "$output" == *'"request_id":"r-abc123"'* ]]
}

@test "admin defaults to FALSE — approval rights are granted, never inherited" {
  tester_registry_add demo1 Francis-1234 "Rob Zaar" tester-member
  run tester_registry_list_json demo1
  [[ "$output" == *'"admin":false'* ]]
}

@test "every row carries approved_at and approved_by — an unattributed row is a defect" {
  NWP_TESTER_ACTOR=rob tester_registry_add demo1 Francis-1234 "Rob Zaar" tester-member
  run tester_registry_list_json demo1
  [[ "$output" == *'"approved_by":"rob"'* ]]
  [[ "$output" =~ \"approved_at\":[0-9]{9,} ]]
}

# --- fail-closed on an unprovable write ---------------------------------------
#
# THE test this file exists for. An approval that cannot be written to the
# registry must fail VISIBLY. If add() ever returns 0 without the row being
# readable, the caller goes on to create the account and the person is told
# they are approved — then wiped tonight.

@test "add REFUSES (non-zero) when the registry directory cannot be written" {
  chmod 500 "${PROJECT_ROOT}/sites/demo1"
  run tester_registry_add demo1 Francis-1234 "Rob Zaar" tester-member
  chmod 700 "${PROJECT_ROOT}/sites/demo1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not"* || "$output" == *"CANNOT"* ]]
}

@test "add REFUSES when the existing registry is corrupt — never overwrites it blind" {
  printf '{ corrupt' > "$(_reg)"
  run tester_registry_add demo1 Francis-1234 "Rob Zaar" tester-member
  [ "$status" -ne 0 ]
  [[ "$output" == *"unreadable"* || "$output" == *"CANNOT"* ]]
  # The corrupt file is left EXACTLY as found: clobbering it would destroy the
  # only copy of everyone who was already approved.
  run cat "$(_reg)"
  [ "$output" = '{ corrupt' ]
}

@test "add VERIFIES the readback and reports success only when the row is really there" {
  run tester_registry_add demo1 Francis-1234 "Rob Zaar" tester-member
  [ "$status" -eq 0 ]
  run tester_registry_has demo1 Francis-1234
  [ "$status" -eq 0 ]
  run tester_registry_has demo1 Nobody-1
  [ "$status" -ne 0 ]
}

# --- THE INTERFACE CONTRACT WITH THE RESET LEG --------------------------------
#
# The file this library writes IS the payload the reset leg stages and reads
# (servers/live/demo/install-box.sh <site> --stage-testers copies it to
# /var/lib/nwp-demo/<site>/testers-payload.json). Its shape is therefore not
# ours to choose freely — it is a contract with the sibling leg, agreed
# 2026-08-16 and pinned here so a well-meant refactor goes RED instead of
# silently un-preserving everybody.
#
# REQUIRED per entry: `account` only, matching ^[A-Za-z0-9][A-Za-z0-9_.@-]{0,79}$.
# Everything else we write is OPTIONAL and IGNORED by the reader — which is what
# lets the console carry display names, guilds and provenance in the same file.

@test "the on-disk registry IS the reset leg's payload shape" {
  tester_registry_add demo1 Francis-1234 "Rob Zaar" tester-member
  run cat "$(_reg)"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"version":1'* ]]
  [[ "$output" == *'"site":"demo1"'* ]]
  [[ "$output" == *'"generated_utc":'* ]]
  [[ "$output" == *'"testers":'* ]]
  [[ "$output" == *'"account":"Francis-1234"'* ]]
}

@test "generated_utc is refreshed on every write — the leg flags a stale roster" {
  tester_registry_add demo1 Francis-1234 "Rob Zaar" tester-member
  first="$(grep -o '"generated_utc":"[^"]*"' "$(_reg)")"
  sleep 1
  tester_registry_add demo1 Cecilia-99 "Ann Other" tester-member
  second="$(grep -o '"generated_utc":"[^"]*"' "$(_reg)")"
  [ "$first" != "$second" ]
}

@test "the account regex is EXACTLY the reset leg's — the boundary cases both ways" {
  # 80 chars is the leg's ceiling (1 + 79); 81 is over it.
  run tester_valid_account "$(printf 'a%.0s' {1..80})"
  [ "$status" -eq 0 ]
  run tester_valid_account "$(printf 'a%.0s' {1..81})"
  [ "$status" -ne 0 ]
  # Leading character must be alphanumeric — the leg refuses a leading dot.
  run tester_valid_account '.hidden'
  [ "$status" -ne 0 ]
  run tester_valid_account '_leading'
  [ "$status" -ne 0 ]
  # @ and . ARE legal inside (the fence mints user123@demo.invalid-style names).
  run tester_valid_account 'user123@demo.invalid'
  [ "$status" -eq 0 ]
}

@test "the registry NEVER contains a pending row — the leg refuses those by contract" {
  # There is deliberately no way to add one: pending join requests live in the
  # request store, which the reset leg never reads. This test pins the ABSENCE
  # of the field, because an entry carrying approved:false would be refused and
  # named by the leg — a loud failure, but one nobody should be able to cause.
  tester_registry_add demo1 Francis-1234 "Rob Zaar" tester-member
  run cat "$(_reg)"
  [[ "$output" != *'"approved":false'* ]]
  [[ "$output" != *'"status":"pending"'* ]]
}
