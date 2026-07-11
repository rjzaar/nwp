#!/usr/bin/env bats
# P74 Phase 3 — pair_schema_verify + pair_guard schema-pin fail-closed.
#
# pair_guard now fails closed when a surface's declared schema_sha256 no longer
# matches the on-disk schema file (the wire shape drifted from the pinned/signed
# contract). Off-unless-declared. Self-contained fixtures; no network/secrets.

setup() {
  TMP="$(mktemp -d)"
  export PROJECT_ROOT="${TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}/contracts" "${PROJECT_ROOT}/pairs" "${PROJECT_ROOT}/private/pairs"
  export NWP_YML="${PROJECT_ROOT}/nwp.yml"
  export NWP_PAIR_CONTRACT_DIR="${PROJECT_ROOT}/pairs"
  export NWP_PAIR_STATE_DIR="${PROJECT_ROOT}/private/pairs"

  cat > "${NWP_YML}" <<'EOF'
sites:
  prov:
    recipe: d
  cons:
    recipe: d
    paired_with: prov
EOF

  # A real schema file + its true sha256.
  printf '{"type":"object","properties":{"sub":{"type":"string"}}}\n' \
    > "${PROJECT_ROOT}/contracts/oauth.schema.json"
  GOOD_SHA="$(sha256sum "${PROJECT_ROOT}/contracts/oauth.schema.json" | awk '{print $1}')"

  cat > "${NWP_PAIR_CONTRACT_DIR}/cons.pair-contract.yml" <<EOF
pair: cons-prov
contract_version: 1
provider: prov
consumer: cons
surfaces:
  oauth_sso:
    schema: "contracts/oauth.schema.json"
    schema_sha256: "${GOOD_SHA}"
identity:
  uid_lock: false
  coupled_tiers: []
EOF

  source "${BATS_TEST_DIRNAME}/../../lib/ui.sh"
  source "${BATS_TEST_DIRNAME}/../../lib/pair.sh"
  CONTRACT="${NWP_PAIR_CONTRACT_DIR}/cons.pair-contract.yml"
}

teardown() { rm -rf "$TMP"; unset NWP_YML PROJECT_ROOT NWP_PAIR_CONTRACT_DIR NWP_PAIR_STATE_DIR NWP_PAIR_GATE_SOFT; }

@test "pair_schema_verify: passes when the pin matches the on-disk schema" {
  run pair_schema_verify "$CONTRACT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pair_schema_verify: FAILS on a sha256 mismatch (wire shape drifted)" {
  echo '{"changed":true}' > "${PROJECT_ROOT}/contracts/oauth.schema.json"
  run pair_schema_verify "$CONTRACT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema_sha256 mismatch"* ]]
}

@test "pair_schema_verify: FAILS when the declared schema file is missing" {
  rm -f "${PROJECT_ROOT}/contracts/oauth.schema.json"
  run pair_schema_verify "$CONTRACT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema file missing"* ]]
}

@test "pair_schema_verify: no-op when a contract declares no schema pins" {
  cat > "${NWP_PAIR_CONTRACT_DIR}/cons.pair-contract.yml" <<'EOF'
pair: cons-prov
contract_version: 1
provider: prov
consumer: cons
identity:
  uid_lock: false
  coupled_tiers: []
EOF
  run pair_schema_verify "$CONTRACT"
  [ "$status" -eq 0 ]
}

@test "pair_guard: REFUSES a deploy when a schema pin no longer matches" {
  # schema check (step 2b) runs BEFORE the D5 ordering check, so it fires first.
  echo '{"changed":true}' > "${PROJECT_ROOT}/contracts/oauth.schema.json"
  run pair_guard cons live stg2live true false
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema pin"* ]]
}

@test "pair_guard: schema mismatch is bypassable with --override-pair (ledgered)" {
  echo '{"changed":true}' > "${PROJECT_ROOT}/contracts/oauth.schema.json"
  # override = 5th arg true; code_only true so the D6 rule doesn't independently block.
  run pair_guard cons live stg2live true true
  [ "$status" -eq 0 ]
}

@test "pair_guard: intact schema pin proceeds (uncoupled tier, code-only)" {
  # Record provider state so the pre-existing D5 provider-first rule is satisfied
  # — isolates this assertion to the schema pin (which is intact ⇒ must proceed).
  pair_guard_record cons provider live 1
  run pair_guard cons live stg2live true false
  [ "$status" -eq 0 ]
}
