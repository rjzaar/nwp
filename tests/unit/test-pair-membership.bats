#!/usr/bin/env bats
# ADR-0031 D6 — pair MEMBERSHIP resolution, and the inversion that made the
# UID-lock guard inert.
#
# THE DEFECT THIS FILE PINS (2026-07-27)
#   `pl pair check ssc live` — a full-DB push to the tier whose UID-locks D6
#   exists to protect — answered ALLOW. Not because an invariant was wrong, but
#   because membership was resolved from ONE file (global nwp.yml) in ONE shape
#   (scalar `paired_with:`), while the real ssc↔nwc pair was declared in the
#   per-site file in a DIFFERENT shape (`paired_with: {nwc_canonical: <url>}`).
#   The reader returned nothing, and "nothing" fell through the
#   `not paired ⇒ return 0` door. Unreadable read as unpaired; unpaired read as
#   consent.
#
#   So these fixtures reproduce the REAL topology, including the part that
#   caused it: the global nwp.yml does NOT mention ssc at all. The pair binds
#   from the committed contract, which is the only declaration git can see.
#
# Fixtures (pair id == consumer site key):
#   nwc  ↔ ssc   coupled: uid_lock true, coupled_tiers [live,prod], cv 2
#   lone         genuinely unpaired — the NEGATIVE CONTROL, so this suite
#                cannot be satisfied by a guard that refuses everything.

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  export NWP_YML="${PROJECT_ROOT}/nwp.yml"
  export NWP_PAIR_CONTRACT_DIR="${PROJECT_ROOT}/pairs"
  export NWP_PAIR_STATE_DIR="${PROJECT_ROOT}/private/pairs"
  mkdir -p "${NWP_PAIR_CONTRACT_DIR}" "${NWP_PAIR_STATE_DIR}" \
           "${PROJECT_ROOT}/sites/ssc" "${PROJECT_ROOT}/sites/nwc" \
           "${PROJECT_ROOT}/sites/lone"

  # The global file as it ACTUALLY was: no pairing for ssc anywhere in it.
  cat > "${NWP_YML}" <<'EOF'
sites:
  nwc:
    canonical: dev
  ssc:
    canonical: dev
  lone:
    recipe: d
EOF

  # The committed contract — the source of truth, and the only declaration of
  # this pair that a reviewer or CI can see.
  cat > "${NWP_PAIR_CONTRACT_DIR}/ssc.pair-contract.yml" <<'EOF'
pair: ssc-nwc
contract_version: 2
provider: nwc
consumer: ssc
identity:
  uid_lock: true
  coupled_tiers: [live, prod]
EOF

  # Per-site operator config, canonical shape.
  cat > "${PROJECT_ROOT}/sites/ssc/.nwp.yml" <<'EOF'
schema_version: 2
project:
  name: ssc
  type: moodle
paired_with: nwc
EOF
  cat > "${PROJECT_ROOT}/sites/nwc/.nwp.yml" <<'EOF'
schema_version: 2
project:
  name: nwc
  type: drupal
EOF
  cat > "${PROJECT_ROOT}/sites/lone/.nwp.yml" <<'EOF'
schema_version: 2
project:
  name: lone
  type: drupal
EOF

  source "${BATS_TEST_DIRNAME}/../../lib/ui.sh"
  source "${BATS_TEST_DIRNAME}/../../lib/pair.sh"

  # Green pair + provider already at the contract version, so the red-pair block
  # and the D5 provider-first rule are both satisfied and the D6 --code-only
  # rule is the thing under test.
  pair_rag_set ssc live green
  pair_guard_record ssc provider live 2
}

teardown() {
  rm -rf "${TEST_TMP}"
  unset NWP_YML PROJECT_ROOT NWP_PAIR_CONTRACT_DIR NWP_PAIR_STATE_DIR NWP_PAIR_GATE_SOFT
}

# --- the regression itself ---------------------------------------------------

@test "REGRESSION: ssc binds to nwc even though the global nwp.yml never names the pair" {
  run grep -c 'paired_with' "${NWP_YML}"
  [ "$output" = "0" ]                      # the file that USED to be the only source
  [ "$(pair_membership_of ssc)" = "consumer ssc" ]
  [ "$(pair_membership_of nwc)" = "provider ssc" ]
}

@test "CASE 1: full-DB promotion to ssc live is REFUSED (D6 consumer half)" {
  run pair_guard ssc live stg2live false false
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"identity-coupled CONSUMER"* ]]
}

@test "CASE 2: --code-only promotion to ssc live is ALLOWED" {
  run pair_guard ssc live stg2live true false
  [ "$status" -eq 0 ]
}

@test "CASE 1b: full-DB promotion to the PROVIDER nwc live is REFUSED (the standing rule)" {
  run pair_guard nwc live stg2live false false
  [ "$status" -ne 0 ]
  [[ "$output" == *"identity-coupled PROVIDER"* ]]
  [[ "$output" == *"sever every 'ssc' SSO identity"* ]]
}

@test "CASE 1b: --code-only promotion to nwc live is ALLOWED" {
  run pair_guard nwc live stg2live true false
  [ "$status" -eq 0 ]
}

# --- CASE 3: unreadable declarations REFUSE, they do not read as "unpaired" ---

@test "CASE 3: the original map-shaped paired_with is CANNOT-VERIFY, not unpaired" {
  cat > "${PROJECT_ROOT}/sites/ssc/.nwp.yml" <<'EOF'
schema_version: 2
paired_with:
  nwc_canonical: https://nwc.nwpcode.org
EOF
  run pair_membership_of ssc
  [ "$status" -eq 2 ]                      # NOT 1 ("unpaired") — that is the bug
  run pair_guard ssc live stg2live true false     # even --code-only is refused
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
  [[ "$output" == *"is a map, not a provider site name"* ]]
}

@test "CASE 3: a URL where a site key belongs is CANNOT-VERIFY" {
  printf 'paired_with: https://nwc.nwpcode.org\n' > "${PROJECT_ROOT}/sites/ssc/.nwp.yml"
  run pair_guard ssc live stg2live true false
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
  [[ "$output" == *"not a bare provider site key"* ]]
}

@test "CASE 3: a per-site file that is not valid YAML is CANNOT-VERIFY" {
  printf 'paired_with: [\n  broken\n' > "${PROJECT_ROOT}/sites/ssc/.nwp.yml"
  run pair_guard ssc live stg2live true false
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "CASE 3: declarations that DISAGREE are CANNOT-VERIFY, not last-one-wins" {
  printf 'paired_with: someone-else\n' > "${PROJECT_ROOT}/sites/ssc/.nwp.yml"
  run pair_guard ssc live stg2live true false
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
  [[ "$output" == *"conflicting pairing"* ]]
}

@test "CASE 3: a contract filed under the wrong name is CANNOT-VERIFY" {
  # pair_guard resolves a contract by pair id == consumer name, so a contract
  # declaring `consumer: ssc` but filed as wrong.pair-contract.yml would never
  # be found — silently, before this check.
  mv "${NWP_PAIR_CONTRACT_DIR}/ssc.pair-contract.yml" \
     "${NWP_PAIR_CONTRACT_DIR}/wrong.pair-contract.yml"
  run pair_guard ssc live stg2live true false
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
  [[ "$output" == *"would not find it"* ]]
}

@test "CASE 3: blindness is escapable ONLY by the audited NWP_PAIR_GATE_SOFT" {
  cat > "${PROJECT_ROOT}/sites/ssc/.nwp.yml" <<'EOF'
paired_with:
  nwc_canonical: https://nwc.nwpcode.org
EOF
  # --override-pair is a per-invariant override and must NOT buy a pass here.
  run pair_guard ssc live stg2live false true
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]

  NWP_PAIR_GATE_SOFT=true run pair_guard ssc live stg2live true false
  [ "$status" -eq 0 ]
  grep -q "action=blind-refuse"    "${NWP_PAIR_STATE_DIR}/_unresolved.log"
  grep -q "action=blind-soft-skip" "${NWP_PAIR_STATE_DIR}/_unresolved.log"
}

# --- CASE 4: NEGATIVE CONTROL ------------------------------------------------
# Without these, every assertion above is satisfied by a guard that refuses
# unconditionally.

@test "CASE 4 (negative control): an unpaired site still promotes full-DB" {
  run pair_membership_of lone
  [ "$status" -eq 1 ]                      # 1 = genuinely unpaired, not 2
  [ -z "$output" ]
  run pair_guard lone live stg2live false false
  [ "$status" -eq 0 ]
}

@test "CASE 4 (negative control): an unpaired site promotes to prod too" {
  run pair_guard lone prod live2prod false false
  [ "$status" -eq 0 ]
}

@test "CASE 4 (negative control): a coupled pair still promotes full-DB at an UNCOUPLED tier" {
  # stg is not in coupled_tiers, so D6 has nothing to say — only live/prod do.
  pair_guard_record ssc provider stg 2      # satisfy D5 ordering for the consumer
  run pair_guard ssc stg stg2live false false
  [ "$status" -eq 0 ]
  run pair_guard nwc stg stg2live false false
  [ "$status" -eq 0 ]
}

# --- scan-level shape assertions ---------------------------------------------

@test "pair_scan reports the pair from the committed contract, with its file" {
  run pair_scan
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"*"ssc"*"nwc"*"ssc.pair-contract.yml"* ]]
}

@test "pair_scan_problems is empty when every declaration is legible" {
  [ -z "$(pair_scan_problems)" ]
}

@test "a paired_with in the GLOBAL file alone still binds (back-compat)" {
  rm -f "${PROJECT_ROOT}/sites/ssc/.nwp.yml" "${NWP_PAIR_CONTRACT_DIR}/ssc.pair-contract.yml"
  cat > "${NWP_YML}" <<'EOF'
sites:
  nwc:
    canonical: dev
  ssc:
    paired_with: nwc
EOF
  [ "$(pair_membership_of ssc)" = "consumer ssc" ]
  [ "$(pair_membership_of nwc)" = "provider ssc" ]
}

# --- the SHIPPED contracts, so CI notices if the real pair stops binding ------

@test "SHIPPED: the committed pairs/ bind ssc↔nwc and ssd↔nwd with no operator config" {
  # No sites/, no nwp.yml — only what git carries. This is the property the old
  # resolver could not have: a pair that CI itself can see.
  export PROJECT_ROOT="${TEST_TMP}/bare"; mkdir -p "${PROJECT_ROOT}"
  export NWP_YML="${PROJECT_ROOT}/nwp.yml"
  export NWP_PAIR_CONTRACT_DIR="${BATS_TEST_DIRNAME}/../../pairs"

  [ -z "$(pair_scan_problems)" ]
  [ "$(pair_membership_of ssc)" = "consumer ssc" ]
  [ "$(pair_membership_of nwc)" = "provider ssc" ]
  [ "$(pair_membership_of ssd)" = "consumer ssd" ]
  [ "$(pair_membership_of nwd)" = "provider ssd" ]

  # And the ssc pair really does couple live — the fact D6 hangs off.
  run pair_contract_couples_tier "${NWP_PAIR_CONTRACT_DIR}/ssc.pair-contract.yml" live
  [ "$status" -eq 0 ]
}

@test "SHIPPED: a full-DB push to ssc live is REFUSED using the real contract" {
  export PROJECT_ROOT="${TEST_TMP}/bare"; mkdir -p "${PROJECT_ROOT}"
  export NWP_YML="${PROJECT_ROOT}/nwp.yml"
  export NWP_PAIR_CONTRACT_DIR="${BATS_TEST_DIRNAME}/../../pairs"
  # The real contract carries schema_sha256 pins against repo-relative paths, so
  # the schema-pin gate needs contracts/ reachable from PROJECT_ROOT — otherwise
  # it refuses first and we would never reach the D6 branch under test.
  ln -s "$(cd "${BATS_TEST_DIRNAME}/../../contracts" && pwd)" "${PROJECT_ROOT}/contracts"
  pair_rag_set ssc live green
  pair_guard_record ssc provider live 99      # ordering satisfied; isolate D6
  run pair_guard ssc live stg2live false false
  [ "$status" -ne 0 ]
  [[ "$output" == *"identity-coupled CONSUMER"* ]]
  run pair_guard nwc live stg2live false false
  [ "$status" -ne 0 ]
  [[ "$output" == *"identity-coupled PROVIDER"* ]]
}

@test "a map-shaped paired_with in the GLOBAL file is also CANNOT-VERIFY" {
  cat > "${NWP_YML}" <<'EOF'
sites:
  lone:
    paired_with:
      some_label: https://example.invalid
EOF
  run pair_membership_of lone
  [ "$status" -eq 2 ]
}
