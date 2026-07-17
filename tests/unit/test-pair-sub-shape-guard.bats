#!/usr/bin/env bats
# nwp/ops#75 / ops#83 — pair_provider_sub_shape_guard.
#
# The static sub-shape check that would have caught the ops#83 branch-drift: a
# --code-only deploy of a provider tree emitting sub=$account->id() (serial uid)
# instead of sub=$user->uuid() severs every consumer UID-lock, and the D6 rule
# (which only blocks full-DB) does not catch it.
#
# Self-contained: fake coupled + uncoupled contracts, good + bad code trees.
# No network, no real site, no secrets.

setup() {
  TEST_TMP=$(mktemp -d)
  export NWP_PAIR_CONTRACT_DIR="${TEST_TMP}/pairs"
  mkdir -p "${NWP_PAIR_CONTRACT_DIR}"

  # Minimal deps pair.sh expects at source time.
  yaml_get_site_field() { :; }
  export -f yaml_get_site_field

  # Coupled contract that declares + enforces uuid sub-stability.
  cat > "${TEST_TMP}/coupled.yml" <<'EOF'
identity:
  uid_lock: true
  coupled_tiers: [live, prod]
  sub_stability: uuid
  sub_source: 'src/claims.module'
  sub_assert: '\$claims\["sub"\]\s*=\s*\$user->uuid\(\)'
EOF

  # Coupled but declares stability with NO enforcement fields (advisory only).
  cat > "${TEST_TMP}/advisory.yml" <<'EOF'
identity:
  uid_lock: true
  coupled_tiers: [live, prod]
  sub_stability: uuid
EOF

  # A GOOD provider tree: emits the UUID sub.
  export GOOD="${TEST_TMP}/good"
  mkdir -p "${GOOD}/src"
  echo '  $claims["sub"] = $user->uuid();' > "${GOOD}/src/claims.module"

  # A BAD provider tree: reverted to the serial uid (the drift).
  export BAD="${TEST_TMP}/bad"
  mkdir -p "${BAD}/src"
  echo '  $claims["sub"] = $account->id();' > "${BAD}/src/claims.module"

  source "${BATS_TEST_DIRNAME}/../../lib/pair.sh"
}

teardown() { rm -rf "${TEST_TMP}"; }

@test "good code at a coupled tier passes" {
  run pair_provider_sub_shape_guard "${TEST_TMP}/coupled.yml" "${GOOD}" live
  [ "$status" -eq 0 ]
}

@test "bad code at a coupled tier is REFUSED" {
  run pair_provider_sub_shape_guard "${TEST_TMP}/coupled.yml" "${BAD}" live
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not emit the contracted sub shape"* ]]
}

@test "uncoupled tier is a no-op even with bad code" {
  run pair_provider_sub_shape_guard "${TEST_TMP}/coupled.yml" "${BAD}" dev
  [ "$status" -eq 0 ]
}

@test "advisory contract (no sub_source/sub_assert) never blocks" {
  run pair_provider_sub_shape_guard "${TEST_TMP}/advisory.yml" "${BAD}" live
  [ "$status" -eq 0 ]
}

@test "missing source file is a diagnosable misconfig (rc 2), not a silent pass" {
  run pair_provider_sub_shape_guard "${TEST_TMP}/coupled.yml" "${TEST_TMP}/empty" live
  [ "$status" -eq 2 ]
}

@test "no contract file is a no-op" {
  run pair_provider_sub_shape_guard "${TEST_TMP}/does-not-exist.yml" "${GOOD}" live
  [ "$status" -eq 0 ]
}
