#!/usr/bin/env bats
# =============================================================================
# tests/unit/test-erasure.bats — `pl erasure` (ops#81 / fix-programme item 5)
# =============================================================================
# BEFORE THIS ITEM there was no erasure verb at all: `grep -rE
# 'dataprivacy|data_request|DSAR' scripts/commands lib` returned zero hits, and
# docs/guides/ops83-dr-restore.md serviced a right-to-be-forgotten request with
# hand-written SQL against mdl_user over ssh. Every case below was run against
# the pre-fix tree and observed RED (`No such file or directory`).
#
# The cases that matter are NOT "the file now exists". They are the four ways a
# naive erasure verb would be VACUOUS:
#
#   1. `verify` with no probe wired reports "0 residual rows — clean".
#      -> must be CANNOT-VERIFY and non-zero. (A probe that cannot run is not
#         a probe that found nothing.)
#   2. `verify` green while the consumer half still holds rows.
#      -> must be RESIDUAL and non-zero.
#   3. `execute` "succeeds" against a channel (local_nwc_erase) that has never
#      been deployed. -> must be CHANNEL-NOT-DEPLOYED and non-zero.
#   4. `plan` accepts a command shape the signed contract schema forbids.
#      -> must be SCHEMA-INVALID and non-zero.
#
# Self-contained fixtures; no network, no live site, no secrets.
# =============================================================================

ERASURE_SH="${BATS_TEST_DIRNAME}/../../scripts/commands/erasure.sh"

setup() {
  TMP="$(mktemp -d)"
  export PROJECT_ROOT="${TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}/pairs" "${PROJECT_ROOT}/contracts" "${PROJECT_ROOT}/private"
  export NWP_PAIR_CONTRACT_DIR="${PROJECT_ROOT}/pairs"
  export NWP_PAIR_STATE_DIR="${PROJECT_ROOT}/private/pairs"
  export NWP_ERASURE_STATE_DIR="${PROJECT_ROOT}/private/erasure"

  # The real signed schema — copied, not stubbed, so the test exercises the
  # shape the provider actually promises the consumer.
  cp "${BATS_TEST_DIRNAME}/../../contracts/erasure.command.schema.json" \
     "${PROJECT_ROOT}/contracts/erasure.command.schema.json"

  SUB="8f14e45f-ceea-467a-9e2b-2c3b0a1d4e5f"

  # --- fixture pair contract (consumer=cons, provider=prov) ------------------
  # Deliberately WITHOUT erasure.semantics_approved and WITHOUT a deployed
  # channel: that is the real state of the estate today.
  cat > "${PROJECT_ROOT}/pairs/cons.pair-contract.yml" <<YML
pair: cons-prov
contract_version: 2
provider: prov
consumer: cons
surfaces:
  erasure:
    provider_min: "0.6.0"
    consumer_min: "1.0.0"
    schema: "contracts/erasure.command.schema.json"
identity:
  uid_lock: true
  coupled_tiers: [live, prod]
  sub_stability: uuid
boundary:
  erasure:
    direction: "prov->cons"
    provider_paths:
      - "sites/prov/dev/html/profiles/custom/prov/modules/prov_erase/**"
    consumer_paths:
      - "moodle/local/nwc_erase/**"
crossref:
  provider_roots:
    - "sites/prov/dev/html/profiles/custom/prov"
  consumer_roots:
    - "sites/cons/.plugin-src/ss-moodle-plugins"
endpoints:
  dev:
    issuer: "https://prov-dev.ddev.site"
  live:
    issuer: "https://prov.example.test"
erasure:
  receiver_path: "local/nwc_erase/erase.php"
  sender_path: "modules/prov_erase"
YML

  # Provider + consumer trees exist but the erasure channel does NOT.
  mkdir -p "${PROJECT_ROOT}/sites/prov/dev/html/profiles/custom/prov/modules/prov_sync"
  mkdir -p "${PROJECT_ROOT}/sites/cons/.plugin-src/ss-moodle-plugins/local/feedback"

  # --- probe fixtures -------------------------------------------------------
  # A residual-row probe is a COMMAND that receives the sub as $1 and prints one
  # integer. Writing them as real scripts (rather than inline `echo N`) keeps
  # that contract honest: an inline `echo 0` would silently echo the sub too.
  PROBES="${TMP}/probes"; mkdir -p "$PROBES"
  _mkprobe() { # <name> <body>
    printf '#!/bin/bash\nprintf "%%s" "$1" > "%s/$(basename "$0").arg"\n%s\n' "$PROBES" "$2" \
      > "${PROBES}/$1"
    chmod +x "${PROBES}/$1"
  }
  _mkprobe clean   'echo 0'
  _mkprobe dirty1  'echo 1'
  _mkprobe dirty3  'echo 3'
  _mkprobe broken  'exit 7'
  _mkprobe garbage 'echo none'
}

teardown() { rm -rf "${TMP}"; }

# Deploy both halves of the channel into the fixture (what P1/P2 of ops#81 will do).
_deploy_channel() {
  mkdir -p "${PROJECT_ROOT}/sites/cons/.plugin-src/ss-moodle-plugins/local/nwc_erase"
  echo "<?php // receiver" > "${PROJECT_ROOT}/sites/cons/.plugin-src/ss-moodle-plugins/local/nwc_erase/erase.php"
  mkdir -p "${PROJECT_ROOT}/sites/prov/dev/html/profiles/custom/prov/modules/prov_erase"
  echo "<?php // sender" > "${PROJECT_ROOT}/sites/prov/dev/html/profiles/custom/prov/modules/prov_erase/prov_erase.module"
}

# =============================================================================
# plan
# =============================================================================

@test "erasure plan: builds a schema-valid command and records it" {
  run bash "$ERASURE_SH" plan cons --sub="$SUB" --request-id=req-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"req-1"* ]]
  [[ "$output" == *"$SUB"* ]]
  [ -f "${NWP_ERASURE_STATE_DIR}/cons/req-1.json" ]
  # The recorded command must be exactly the contract shape.
  run jq -r '.command.action' "${NWP_ERASURE_STATE_DIR}/cons/req-1.json"
  [ "$output" = "delete" ]
}

@test "erasure plan: an action the signed schema forbids is SCHEMA-INVALID" {
  run bash "$ERASURE_SH" plan cons --sub="$SUB" --action=purge --request-id=req-bad
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCHEMA-INVALID"* ]]
  [ ! -f "${NWP_ERASURE_STATE_DIR}/cons/req-bad.json" ]
}

@test "erasure plan: an empty sub is refused (the UID-lock join key)" {
  run bash "$ERASURE_SH" plan cons --sub= --request-id=req-nosub
  [ "$status" -ne 0 ]
}

@test "erasure plan: an unknown pair fails closed, it does not invent a contract" {
  run bash "$ERASURE_SH" plan nosuchpair --sub="$SUB"
  [ "$status" -ne 0 ]
  [[ "$output" == *"NO-CONTRACT"* ]]
}

@test "erasure plan: anonymise is accepted (the contract enum has two values)" {
  run bash "$ERASURE_SH" plan cons --sub="$SUB" --action=anonymise --request-id=req-anon
  [ "$status" -eq 0 ]
  run jq -r '.command.action' "${NWP_ERASURE_STATE_DIR}/cons/req-anon.json"
  [ "$output" = "anonymise" ]
}

# =============================================================================
# execute — the fail-closed half
# =============================================================================

@test "erasure execute: refuses while the channel is not deployed" {
  bash "$ERASURE_SH" plan cons --sub="$SUB" --request-id=req-x >/dev/null
  run bash "$ERASURE_SH" execute cons --request-id=req-x
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHANNEL-NOT-DEPLOYED"* ]]
}

@test "erasure execute: with the channel deployed, still refuses unapproved semantics" {
  _deploy_channel
  bash "$ERASURE_SH" plan cons --sub="$SUB" --request-id=req-y >/dev/null
  run bash "$ERASURE_SH" execute cons --request-id=req-y
  [ "$status" -ne 0 ]
  [[ "$output" == *"SEMANTICS-UNAPPROVED"* ]]
}

@test "erasure execute: approved + deployed still needs a transport, never a silent no-op" {
  _deploy_channel
  # Operator approval recorded in the contract (the gate the programme reserves
  # to the operator: anonymise-vs-delete, what "verified erased" means).
  printf '  semantics_approved: true\n' >> "${PROJECT_ROOT}/pairs/cons.pair-contract.yml"
  bash "$ERASURE_SH" plan cons --sub="$SUB" --request-id=req-z >/dev/null
  run bash "$ERASURE_SH" execute cons --request-id=req-z
  [ "$status" -ne 0 ]
  [[ "$output" == *"NO-TRANSPORT"* ]]
}

@test "erasure execute: a request id that was never planned is refused" {
  _deploy_channel
  run bash "$ERASURE_SH" execute cons --request-id=never-planned
  [ "$status" -ne 0 ]
  [[ "$output" == *"NO-SUCH-REQUEST"* ]]
}

# =============================================================================
# verify — the vacuity guards
# =============================================================================

@test "erasure verify: NO probe wired is CANNOT-VERIFY, not clean" {
  bash "$ERASURE_SH" plan cons --sub="$SUB" --request-id=req-v >/dev/null
  run bash "$ERASURE_SH" verify cons --sub="$SUB"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
  # The failure must NOT be dressed up as a pass anywhere in the output.
  [[ "$output" != *"ERASURE VERIFIED"* ]]
}

@test "erasure verify: residual rows on the CONSUMER half are RESIDUAL and non-zero" {
  bash "$ERASURE_SH" plan cons --sub="$SUB" --request-id=req-v2 >/dev/null
  run bash "$ERASURE_SH" verify cons --sub="$SUB" \
      --provider-probe-cmd="${PROBES}/clean" \
      --consumer-probe-cmd="${PROBES}/dirty3" \
      --backup-ceiling=30d
  [ "$status" -ne 0 ]
  [[ "$output" == *"RESIDUAL"* ]]
  [[ "$output" == *"consumer"* ]]
}

@test "erasure verify: residual rows on the PROVIDER half are RESIDUAL and non-zero" {
  run bash "$ERASURE_SH" verify cons --sub="$SUB" \
      --provider-probe-cmd="${PROBES}/dirty1" \
      --consumer-probe-cmd="${PROBES}/clean" \
      --backup-ceiling=30d
  [ "$status" -ne 0 ]
  [[ "$output" == *"RESIDUAL"* ]]
  [[ "$output" == *"provider"* ]]
}

@test "erasure verify: a probe that ERRORS is CANNOT-VERIFY, never 0" {
  run bash "$ERASURE_SH" verify cons --sub="$SUB" \
      --provider-probe-cmd="${PROBES}/broken" \
      --consumer-probe-cmd="${PROBES}/clean" \
      --backup-ceiling=30d
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "erasure verify: a probe printing non-numeric output is CANNOT-VERIFY" {
  run bash "$ERASURE_SH" verify cons --sub="$SUB" \
      --provider-probe-cmd="${PROBES}/garbage" \
      --consumer-probe-cmd="${PROBES}/clean" \
      --backup-ceiling=30d
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "erasure verify: zero rows both sides but NO backup ceiling is not verified" {
  # Residual PII inside a backup repo with no --keep-within ceiling outlives the
  # erasure promise. Both live halves clean is NOT erasure.
  run bash "$ERASURE_SH" verify cons --sub="$SUB" \
      --provider-probe-cmd="${PROBES}/clean" \
      --consumer-probe-cmd="${PROBES}/clean"
  [ "$status" -ne 0 ]
  [[ "$output" == *"NO-BACKUP-CEILING"* ]]
}

@test "erasure verify: zero rows both sides + a declared ceiling verifies" {
  run bash "$ERASURE_SH" verify cons --sub="$SUB" \
      --provider-probe-cmd="${PROBES}/clean" \
      --consumer-probe-cmd="${PROBES}/clean" \
      --backup-ceiling=30d
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERASURE VERIFIED"* ]]
}

@test "erasure verify: the probe is actually handed the sub as \$1" {
  # Without this, a probe could count residual rows for the WRONG subject (or
  # for none) and the verb would still print a confident answer.
  run bash "$ERASURE_SH" verify cons --sub="$SUB" \
      --provider-probe-cmd="${PROBES}/clean" \
      --consumer-probe-cmd="${PROBES}/clean" \
      --backup-ceiling=30d
  [ "$status" -eq 0 ]
  [ "$(cat "${PROBES}/clean.arg")" = "$SUB" ]
}

@test "erasure verify: the sub is never resolved by email" {
  # Guard against the ops#81 §3 rule (resolve by idnumber==sub, NEVER by email)
  # being softened later: no --email option may exist.
  run bash "$ERASURE_SH" verify cons --email=someone@example.test
  [ "$status" -ne 0 ]
}

# =============================================================================
# status / list
# =============================================================================

@test "erasure status: reports a planned request and its state" {
  bash "$ERASURE_SH" plan cons --sub="$SUB" --request-id=req-s >/dev/null
  run bash "$ERASURE_SH" status req-s
  [ "$status" -eq 0 ]
  [[ "$output" == *"planned"* ]]
}

@test "erasure status: an unknown request id is an error, not an empty pass" {
  run bash "$ERASURE_SH" status no-such-request
  [ "$status" -ne 0 ]
  [[ "$output" == *"NO-SUCH-REQUEST"* ]]
}

@test "erasure list: lists planned requests" {
  bash "$ERASURE_SH" plan cons --sub="$SUB" --request-id=req-l1 >/dev/null
  bash "$ERASURE_SH" plan cons --sub="$SUB" --request-id=req-l2 >/dev/null
  run bash "$ERASURE_SH" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"req-l1"* ]]
  [[ "$output" == *"req-l2"* ]]
}
