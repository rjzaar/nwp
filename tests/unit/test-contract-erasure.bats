#!/usr/bin/env bats
# =============================================================================
# tests/unit/test-contract-erasure.bats — `pl contracts erasure` (ops#81)
# =============================================================================
# ops#81: deleting a person on nwc (OIDC provider) left their Moodle account,
# grades, consent rows and moodledata intact — there was no OP→RP delete
# channel. The channel now exists (commit 272e352: `local_nwc_erase` receiver +
# `nwc_moodle_erase` sender, both staged and fail-closed), and `pl erasure`
# runs a single request against it.
#
# What NOTHING checked was the prior question: does this pair DECLARE a
# defined, pinned, CLOSED erasure channel at all? That is the question a
# release gate and a DPIA reviewer ask, and "read three files and a README"
# is not an answer either can re-run.
#
# The load-bearing assertion here is SCHEMA-NOT-CLOSED. An erasure command
# with additionalProperties:true is a data-minimisation hole in a DESTRUCTIVE
# cross-site message — unreviewed fields riding along to a delete endpoint.
# A gate that accepted an open schema would be green on exactly the shape it
# exists to refuse.
#
# Structural failures are fatal. Estate + operator findings (NOT-DEPLOYED,
# SEMANTICS-UNAPPROVED, NO-BACKUP-CEILING) are reported but fatal only under
# --strict, following the ops#138 precedent: turning a true, known,
# operator-owned state into a surprise block is a different decision from
# making it visible, and only the second is an agent's to take.
#
# Self-contained fixtures; no network, no live site.
# =============================================================================

CONTRACTS_SH="${BATS_TEST_DIRNAME}/../../scripts/commands/contracts.sh"

setup() {
  TMP="$(mktemp -d)"
  export PROJECT_ROOT="${TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}/pairs" "${PROJECT_ROOT}/contracts"
  export NWP_PAIR_CONTRACT_DIR="${PROJECT_ROOT}/pairs"

  PROV="${PROJECT_ROOT}/sites/prov/dev/html/profiles/custom/prov"
  CONS="${PROJECT_ROOT}/sites/cons/.plugin-src/plugins"
  mkdir -p "${PROV}" "${CONS}"

  # A CLOSED erasure command schema — the shape ops#81 actually ships.
  cat > "${PROJECT_ROOT}/contracts/erasure.command.schema.json" <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "provider → consumer erasure command",
  "type": "object",
  "additionalProperties": false,
  "required": ["sub", "request_id", "action", "issuer", "timestamp"],
  "properties": {
    "sub":        { "type": "string", "minLength": 1 },
    "request_id": { "type": "string", "minLength": 1 },
    "action":     { "type": "string", "enum": ["delete", "anonymise"] },
    "issuer":     { "type": "string", "format": "uri" },
    "timestamp":  { "type": "integer" }
  }
}
JSON

  cat > "${PROJECT_ROOT}/pairs/cons.pair-contract.yml" <<'YML'
pair: cons-prov
contract_version: 2
provider: prov
consumer: cons
crossref:
  provider_roots:
    - "sites/prov/dev/html/profiles/custom/prov"
  consumer_roots:
    - "sites/cons/.plugin-src/plugins"
surfaces:
  erasure:
    schema: "contracts/erasure.command.schema.json"
erasure:
  receiver_path: "local/nwc_erase/erase.php"
  sender_path: "modules/nwc_moodle/modules/nwc_moodle_erase"
  semantics_approved: false
  backup_ceiling: ""
YML
}

teardown() { rm -rf "${TMP}"; }

_deploy_both_ends() {
  mkdir -p "${CONS}/local/nwc_erase"
  echo '<?php // receiver' > "${CONS}/local/nwc_erase/erase.php"
  mkdir -p "${PROV}/modules/nwc_moodle/modules/nwc_moodle_erase"
}

_approve_operator_assertions() {
  python3 - "${PROJECT_ROOT}/pairs/cons.pair-contract.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("semantics_approved: false", "semantics_approved: true")
s = s.replace('backup_ceiling: ""', 'backup_ceiling: "30d"')
open(p, "w").write(s)
PY
}

# --- structural failures: always fatal --------------------------------------

@test "contracts erasure: a pair with NO surfaces.erasure block is CHANNEL-UNDEFINED" {
  # The ops#81 starting state: no declared OP→RP delete channel at all.
  python3 - "${PROJECT_ROOT}/pairs/cons.pair-contract.yml" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
s = re.sub(r"surfaces:\n  erasure:\n    schema:.*\n", "", s)
open(p, "w").write(s)
PY
  run bash "$CONTRACTS_SH" erasure cons
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHANNEL-UNDEFINED"* ]]
}

@test "contracts erasure: a surface with no schema: pointer is SCHEMA-UNPINNED" {
  sed -i 's|    schema: "contracts/erasure.command.schema.json"|    note: "no schema pinned"|' \
    "${PROJECT_ROOT}/pairs/cons.pair-contract.yml"
  run bash "$CONTRACTS_SH" erasure cons
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCHEMA-UNPINNED"* ]]
}

@test "contracts erasure: a pinned-but-absent schema is SCHEMA-MISSING, not clean" {
  rm -f "${PROJECT_ROOT}/contracts/erasure.command.schema.json"
  run bash "$CONTRACTS_SH" erasure cons
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCHEMA-MISSING"* ]]
}

@test "contracts erasure: an OPEN schema (additionalProperties true) is SCHEMA-NOT-CLOSED" {
  # THE test. additionalProperties:true on a destructive cross-site command
  # lets unreviewed fields ride along to a delete endpoint. If this passed,
  # the gate would be green on the exact shape it exists to refuse.
  sed -i 's/"additionalProperties": false/"additionalProperties": true/' \
    "${PROJECT_ROOT}/contracts/erasure.command.schema.json"
  run bash "$CONTRACTS_SH" erasure cons
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCHEMA-NOT-CLOSED"* ]]
}

@test "contracts erasure: a schema with an EMPTY required[] is SCHEMA-NOT-CLOSED" {
  # A closed object that requires nothing still accepts {} as a valid erase
  # command — no subject, no request id, no idempotency key.
  python3 - "${PROJECT_ROOT}/contracts/erasure.command.schema.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["required"] = []
json.dump(d, open(p, "w"), indent=2)
PY
  run bash "$CONTRACTS_SH" erasure cons
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCHEMA-NOT-CLOSED"* ]]
}

@test "contracts erasure: unparseable schema JSON is SCHEMA-MISSING, never green" {
  echo '{ this is not json' > "${PROJECT_ROOT}/contracts/erasure.command.schema.json"
  run bash "$CONTRACTS_SH" erasure cons
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCHEMA-MISSING"* ]]
}

@test "contracts erasure: a schema pinned but only ONE channel end declared is CHANNEL-UNDEFINED" {
  # Caught on the real estate: pairs/ssd.pair-contract.yml pins the shared
  # erasure schema but declares neither receiver_path nor sender_path, so the
  # surface looked present while the channel had no ends.
  sed -i '/^  receiver_path:/d' "${PROJECT_ROOT}/pairs/cons.pair-contract.yml"
  run bash "$CONTRACTS_SH" erasure cons
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHANNEL-UNDEFINED"* ]]
}

# --- estate + operator findings: reported, fatal only under --strict --------

@test "contracts erasure: an undeployed channel is reported NOT-DEPLOYED but not fatal" {
  run bash "$CONTRACTS_SH" erasure cons
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT-DEPLOYED"* ]]
}

@test "contracts erasure: --strict makes an undeployed channel fatal" {
  run bash "$CONTRACTS_SH" erasure cons --strict
  [ "$status" -ne 0 ]
  [[ "$output" == *"NOT-DEPLOYED"* ]]
}

@test "contracts erasure: unapproved Art.17 semantics are surfaced, never assumed" {
  # semantics_approved is an operator assertion about lawful basis. The gate
  # must never make it on their behalf, and must never stay quiet about it.
  run bash "$CONTRACTS_SH" erasure cons
  [[ "$output" == *"SEMANTICS-UNAPPROVED"* ]]
}

@test "contracts erasure: an unset backup ceiling is NO-BACKUP-CEILING" {
  # Erasing live rows while a raw backup still holds the person is the usual
  # way a retention schedule fails. Unset is the TRUE state today.
  run bash "$CONTRACTS_SH" erasure cons
  [[ "$output" == *"NO-BACKUP-CEILING"* ]]
}

@test "contracts erasure: a fully deployed + approved channel is green, incl. --strict" {
  _deploy_both_ends
  _approve_operator_assertions
  run bash "$CONTRACTS_SH" erasure cons --strict
  [ "$status" -eq 0 ]
  [[ "$output" == *"schema CLOSED"* ]]
  [[ "$output" == *"receiver DEPLOYED"* ]]
  [[ "$output" == *"sender   DEPLOYED"* ]]
  [[ "$output" == *"semantics APPROVED"* ]]
  [[ "$output" != *"NOT-DEPLOYED"* ]]
}

# --- fail-closed on an un-inspectable estate --------------------------------

@test "contracts erasure: an absent consumer root is NOT-DEPLOYED, not clean" {
  # A channel scanned over an empty corpus must not report deployed.
  rm -rf "${PROJECT_ROOT}/sites/cons"
  run bash "$CONTRACTS_SH" erasure cons --strict
  [ "$status" -ne 0 ]
  [[ "$output" == *"NOT-DEPLOYED"* ]]
}

@test "contracts erasure: an unknown pair fails closed" {
  run bash "$CONTRACTS_SH" erasure nosuchpair
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "contracts erasure: an unknown option is a usage error, not a silent pass" {
  run bash "$CONTRACTS_SH" erasure cons --wat
  [ "$status" -eq 2 ]
}
