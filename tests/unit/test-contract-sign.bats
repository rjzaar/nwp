#!/usr/bin/env bats
# P74 Phase 3 — the signed schema bundle (pl contracts sums|verify|bundle).
#
# Runs against a THROWAWAY copy of contracts/ so the repo's committed SHA256SUMS
# is never mutated. Signing itself is interactive (minisign password) and is an
# operator step; these tests cover the non-interactive halves: sums regeneration,
# fail-closed verify, and bundle assembly. No network, no secrets.

setup() {
  REPO="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  TMP="$(mktemp -d)"
  export PROJECT_ROOT="${TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}/contracts" "${PROJECT_ROOT}/scripts/commands" "${PROJECT_ROOT}/lib"
  cp "${REPO}/contracts/"*.schema.json "${REPO}/contracts/"*.py "${REPO}/contracts/SHA256SUMS" "${PROJECT_ROOT}/contracts/"
  cp "${REPO}/scripts/commands/contracts.sh" "${PROJECT_ROOT}/scripts/commands/"
  cp "${REPO}/lib/minisign.sh" "${REPO}/lib/ui.sh" "${PROJECT_ROOT}/lib/"
  WRAP="${PROJECT_ROOT}/scripts/commands/contracts.sh"
}

teardown() { rm -rf "$TMP"; }

@test "sums: regenerated SHA256SUMS matches the committed one (schemas unchanged)" {
  cp "${PROJECT_ROOT}/contracts/SHA256SUMS" "${TMP}/committed.sums"
  run bash "$WRAP" sums
  [ "$status" -eq 0 ]
  # Compare only the checksum lines (LC_ALL=C sorted) — must be byte-identical.
  diff <(LC_ALL=C sort "${TMP}/committed.sums") \
       <(LC_ALL=C sort "${PROJECT_ROOT}/contracts/SHA256SUMS")
}

@test "verify: FAIL-CLOSED when SHA256SUMS.minisig is missing (unsigned bundle)" {
  # No .minisig in the throwaway copy.
  run bash "$WRAP" verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING"* ]] || [[ "$output" == *"UNSIGNED"* ]]
}

@test "verify: detects a CHECKSUM MISMATCH (schema tampered)" {
  # Fake a signature so we get past the sig gate to the checksum gate.
  printf 'FAKE\n' > "${PROJECT_ROOT}/contracts/SHA256SUMS.minisig"
  echo '  "tamper": true' >> "${PROJECT_ROOT}/contracts/oauth_sso.claims.schema.json"
  run bash "$WRAP" verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHECKSUM MISMATCH"* ]]
}

@test "bundle: assembles a tar of schemas + SHA256SUMS" {
  run bash "$WRAP" bundle --out="${TMP}/dist"
  [ "$status" -eq 0 ]
  tarball="$(ls "${TMP}/dist/"nwp-contracts-*.tar.gz 2>/dev/null | head -1)"
  [ -n "$tarball" ]
  run tar -tzf "$tarball"
  [[ "$output" == *"SHA256SUMS"* ]]
  [[ "$output" == *"oauth_sso.claims.schema.json"* ]]
}

@test "sync-plan: prints the provider->bot->consumer runbook" {
  run bash "$WRAP" sync-plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"minisign"* ]]
  [[ "$output" == *"CONSUMER"* ]]
}
