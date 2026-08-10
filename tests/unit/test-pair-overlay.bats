#!/usr/bin/env bats
# =============================================================================
# tests/unit/test-pair-overlay.bats — ops#326 Phase 1 tranche 2
#
# Engine/site separation: REAL pair contracts live in the PRIVATE OVERLAY repo
# (private/pairs/, remote nwp/private), searched AFTER the shipped pairs/
# (which carries only the sample pair, ssd↔nwd). Three properties:
#
#   1. SEARCH PATH — pair_contract_file / boundary_contract_file resolve
#      shipped first, then the overlay. Default overlay path is
#      $PROJECT_ROOT/private/pairs; NWP_PAIR_OVERLAY_DIR overrides (worktrees
#      shadow private/, so tests and CI must never rely on the literal path).
#   2. DUPLICATE = FAIL CLOSED — a pair declared in BOTH dirs is ambiguity
#      about the authority itself. No silent precedence: the resolver refuses
#      (echoes a path that cannot exist) and membership reads as blind.
#   3. NO ENGINE DEFAULT PAIR — boundary_contract_file/`pl impact` no longer
#      default to a real site's pair id. The pair id is estate configuration
#      (--pair / NWP_BOUNDARY_PAIR); its absence is a refusal that names the
#      knobs, never a silent classification against somebody else's estate.
#
# Self-contained fixtures; no network, no secrets, no live site.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  export PROJECT_ROOT="${TEST_TMP}/root"
  mkdir -p "${PROJECT_ROOT}/pairs" "${PROJECT_ROOT}/private/pairs"

  # Never inherit the operator's estate into a fixture run.
  unset NWP_PAIR_CONTRACT_DIR NWP_PAIR_OVERLAY_DIR NWP_BOUNDARY_PAIR
  export NWP_YML="${PROJECT_ROOT}/nwp.yml"

  source "${REPO_ROOT}/lib/ui.sh"
  source "${REPO_ROOT}/lib/pair.sh"
}

teardown() { rm -rf "$TEST_TMP"; }

_contract() { # <dir> <consumer> <provider>
  cat > "${1}/${2}.pair-contract.yml" <<EOF
pair: ${2}-${3}
contract_version: "1.0.0"
provider: ${3}
consumer: ${2}
EOF
}

# --- 1. search path ----------------------------------------------------------

@test "pair_contract_file resolves the shipped dir first (unchanged behaviour)" {
  _contract "${PROJECT_ROOT}/pairs" shipcons shipprov
  run pair_contract_file shipcons
  [ "$status" -eq 0 ]
  [ "$output" = "${PROJECT_ROOT}/pairs/shipcons.pair-contract.yml" ]
}

@test "ops#326: pair_contract_file falls back to the private overlay" {
  _contract "${PROJECT_ROOT}/private/pairs" ovlcons ovlprov
  run pair_contract_file ovlcons
  [ "$status" -eq 0 ]
  [ "$output" = "${PROJECT_ROOT}/private/pairs/ovlcons.pair-contract.yml" ]
}

@test "ops#326: NWP_PAIR_OVERLAY_DIR overrides the overlay location" {
  local alt="${TEST_TMP}/elsewhere"
  mkdir -p "$alt"
  _contract "$alt" altcons altprov
  export NWP_PAIR_OVERLAY_DIR="$alt"
  run pair_contract_file altcons
  [ "$status" -eq 0 ]
  [ "$output" = "${alt}/altcons.pair-contract.yml" ]
}

@test "ops#326: pair membership resolves from an overlay contract" {
  _contract "${PROJECT_ROOT}/private/pairs" ovlcons ovlprov
  run pair_membership_of ovlcons
  [ "$status" -eq 0 ]
  [ "$output" = "consumer ovlcons" ]
}

# --- 2. duplicate = fail closed ---------------------------------------------

@test "ops#326: a contract in BOTH dirs resolves to a path that cannot exist" {
  _contract "${PROJECT_ROOT}/pairs" dup dprov
  _contract "${PROJECT_ROOT}/private/pairs" dup dprov
  local p
  p="$(pair_contract_file dup 2>/dev/null)" || true
  [ -n "$p" ]
  [ ! -f "$p" ]   # every `[ -f ]` / pair_contract_valid caller now refuses
}

@test "ops#326: a contract in BOTH dirs makes membership BLIND (refuse), not resolved" {
  _contract "${PROJECT_ROOT}/pairs" dup dprov
  _contract "${PROJECT_ROOT}/private/pairs" dup dprov
  run pair_membership_of dup
  [ "$status" -eq 2 ]
  [[ "$output" == *"BOTH"* ]]
}

# --- 3. no engine default pair ----------------------------------------------

@test "ops#326: boundary_contract_file has NO default pair id" {
  source "${REPO_ROOT}/lib/boundary.sh"
  run boundary_contract_file
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "ops#326: boundary_contract_file resolves an overlay contract by id" {
  source "${REPO_ROOT}/lib/boundary.sh"
  _contract "${PROJECT_ROOT}/private/pairs" bcons bprov
  run boundary_contract_file bcons
  [ "$status" -eq 0 ]
  [ "$output" = "${PROJECT_ROOT}/private/pairs/bcons.pair-contract.yml" ]
}

@test "ops#326: NWP_BOUNDARY_PAIR supplies the pair id when no argument is given" {
  source "${REPO_ROOT}/lib/boundary.sh"
  _contract "${PROJECT_ROOT}/pairs" envcons envprov
  export NWP_BOUNDARY_PAIR=envcons
  run boundary_contract_file
  [ "$status" -eq 0 ]
  [ "$output" = "${PROJECT_ROOT}/pairs/envcons.pair-contract.yml" ]
}

@test "ops#326: pl impact with no pair id refuses and names the knobs" {
  run bash "${REPO_ROOT}/scripts/commands/impact.sh" --base=main
  [ "$status" -eq 2 ]
  [[ "$output" == *"--pair"* ]]
  [[ "$output" == *"NWP_BOUNDARY_PAIR"* ]]
}
