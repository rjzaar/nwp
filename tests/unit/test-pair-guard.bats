#!/usr/bin/env bats
# ADR-0031 Phase C / nwp/ops#75 — pair_guard decision-path coverage.
#
# Exercises EVERY pair_guard branch with self-contained fixtures (a fake
# nwp.yml with `paired_with:`, fake pair contracts, and fake deployed-version /
# RAG state under scratch dirs). Touches no network, no real site, no secrets.
#
# Pairs modelled by the fixtures (pair id == consumer site key):
#   prov     ↔ cons        coupled contract (uid_lock, coupled_tiers [live,prod]), cv=2
#   demoprov ↔ democons    UNcoupled contract (uid_lock:false, coupled_tiers []), cv=1
#   badprov  ↔ nocontract  declared paired but NO contract file on disk
#   solo                   unpaired (off-unless-configured)

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}"
  export NWP_YML="${PROJECT_ROOT}/nwp.yml"
  export NWP_PAIR_CONTRACT_DIR="${PROJECT_ROOT}/pairs"
  export NWP_PAIR_STATE_DIR="${PROJECT_ROOT}/private/pairs"
  mkdir -p "${NWP_PAIR_CONTRACT_DIR}" "${NWP_PAIR_STATE_DIR}"

  cat > "${NWP_YML}" <<'EOF'
sites:
  prov:
    recipe: d
  cons:
    recipe: d
    paired_with: prov
  demoprov:
    recipe: d
  democons:
    recipe: d
    paired_with: demoprov
  badprov:
    recipe: d
  nocontract:
    recipe: d
    paired_with: badprov
  solo:
    recipe: d
EOF

  # Coupled pair contract: prov (provider) ↔ cons (consumer), contract_version 2.
  cat > "${NWP_PAIR_CONTRACT_DIR}/cons.pair-contract.yml" <<'EOF'
pair: cons-prov
contract_version: 2
provider: prov
consumer: cons
identity:
  uid_lock: true
  coupled_tiers: [live, prod]
EOF

  # Uncoupled (demo) pair contract: demoprov ↔ democons, contract_version 1.
  cat > "${NWP_PAIR_CONTRACT_DIR}/democons.pair-contract.yml" <<'EOF'
pair: democons-demoprov
contract_version: 1
provider: demoprov
consumer: democons
identity:
  uid_lock: false
  coupled_tiers: []
EOF
  # NOTE: pairs/nocontract.pair-contract.yml deliberately absent.

  source "${BATS_TEST_DIRNAME}/../../lib/ui.sh"
  source "${BATS_TEST_DIRNAME}/../../lib/pair.sh"
}

teardown() {
  rm -rf "${TEST_TMP}"
  unset NWP_YML PROJECT_ROOT NWP_PAIR_CONTRACT_DIR NWP_PAIR_STATE_DIR NWP_PAIR_GATE_SOFT
}

# --- role resolution sanity (feeds every guard path) -------------------------

@test "role resolution: consumer, provider, and unpaired" {
  [ "$(pair_role_of cons)" = "consumer cons" ]
  [ "$(pair_role_of prov)" = "provider cons" ]
  [ "$(pair_role_of demoprov)" = "provider democons" ]
  [ -z "$(pair_role_of solo)" ]
}

# --- (a) unpaired site → no-op (returns 0) -----------------------------------

@test "(a) unpaired site is a no-op — returns 0" {
  run pair_guard solo live stg2live false false
  [ "$status" -eq 0 ]
}

# --- (b) declared-paired but missing/invalid contract → fail closed ----------

@test "(b) declared paired but missing contract → REFUSE (fail closed)" {
  run pair_guard nocontract live stg2live false false
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"missing or invalid"* ]]
}

@test "(b) NWP_PAIR_GATE_SOFT=true softens missing contract to a skip (0)" {
  NWP_PAIR_GATE_SOFT=true run pair_guard nocontract live stg2live false false
  [ "$status" -eq 0 ]
  [[ "$output" == *"SOFT"* ]] || [[ "$output" == *"without pair checks"* ]]
  grep -q "action=soft-skip" "${NWP_PAIR_STATE_DIR}/nocontract.log"
}

# --- (c) red pair at target → refuse; --override-pair → ledgered pass --------

@test "(c) red pair at target → REFUSE" {
  pair_rag_set cons live red
  run pair_guard cons live stg2live true false
  [ "$status" -ne 0 ]
  [[ "$output" == *"RED"* ]]
}

@test "(c) red pair + --override-pair → ledgered PASS" {
  pair_rag_set cons live red
  run pair_guard cons live stg2live true true
  [ "$status" -eq 0 ]
  [[ "$output" == *"OVERRIDE"* ]]
  grep -q "action=override" "${NWP_PAIR_STATE_DIR}/cons.log"
}

# --- (d) consumer with no provider deployment record → refuse (D5) -----------

@test "(d) consumer promotion with no provider record → REFUSE (provider-first)" {
  pair_rag_set cons live green            # not red, so we reach the ordering check
  run pair_guard cons live stg2live true false
  [ "$status" -ne 0 ]
  [[ "$output" == *"no"* ]]
  [[ "$output" == *"recorded deployment"* ]]
  [[ "$output" == *"provider must promote first"* ]]
}

# --- (e) consumer ahead of provider contract_version → refuse (D5) -----------

@test "(e) consumer contract_version ahead of provider → REFUSE" {
  pair_rag_set cons live green
  pair_guard_record cons provider live 1  # provider only reached cv=1; contract is cv=2
  run pair_guard cons live stg2live true false
  [ "$status" -ne 0 ]
  [[ "$output" == *"wants contract_version 2"* ]]
  [[ "$output" == *"provider"* ]]
}

# --- (f) provider full-DB on identity-coupled pair → refuse; --code-only pass -

@test "(f) provider full-DB push to identity-coupled tier → REFUSE" {
  pair_rag_set cons live green
  run pair_guard prov live stg2live false false   # code_only=false = full DB
  [ "$status" -ne 0 ]
  [[ "$output" == *"identity-coupled PROVIDER"* ]]
  [[ "$output" == *"renumber Drupal uids"* ]]
}

@test "(f) provider --code-only on identity-coupled tier → PASS" {
  pair_rag_set cons live green
  run pair_guard prov live stg2live true false    # code_only=true
  [ "$status" -eq 0 ]
}

@test "(f-bonus) provider full-DB on UNcoupled (demo) pair → PASS" {
  pair_rag_set democons live green
  run pair_guard demoprov live stg2live false false
  [ "$status" -eq 0 ]
}

# --- consumer coupled full-DB (D6 consumer half) → refuse; --code-only pass ---

@test "(f-consumer) consumer full-DB on identity-coupled tier → REFUSE" {
  pair_rag_set cons live green
  pair_guard_record cons provider live 2   # provider up-to-date so ordering passes
  run pair_guard cons live stg2live false false   # code_only=false = full DB
  [ "$status" -ne 0 ]
  [[ "$output" == *"identity-coupled CONSUMER"* ]]
}

# --- (g) all-good → PASS, and record_success writes the deployed cv -----------

@test "(g) all invariants satisfied → PASS" {
  pair_rag_set cons live green
  pair_guard_record cons provider live 2   # provider reached cv=2 (== contract)
  run pair_guard cons live stg2live true false   # code_only → coupling ok
  [ "$status" -eq 0 ]
}

@test "(g) pair_guard_record_success writes the consumer's deployed cv" {
  run pair_guard_record_success cons live
  [ "$status" -eq 0 ]
  [ "$(pair_state_get cons consumer live)" = "2" ]
}

@test "(g) record_success is a no-op for an unpaired site" {
  run pair_guard_record_success solo live
  [ "$status" -eq 0 ]
  [ -z "$(pair_state_get solo consumer live)" ]
}
