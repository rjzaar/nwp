#!/usr/bin/env bats
# `pl backup replicate` — the fail-closed half. The transfer+sha256 half was
# proven live (2026-07-28: 28 artifacts to two peers, all verified); what a
# unit test can pin is the refusal: no declared replica may ever be guessed.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TEST_TMP"; }

@test "replicate with no targets configured REFUSES (rc 1, says why)" {
  # Point PROJECT_ROOT at a bare fixture: no nwp.yml, so no replicas key.
  mkdir -p "${TEST_TMP}/root/sites"
  run env PROJECT_ROOT="${TEST_TMP}/root" bash "${REPO_ROOT}/scripts/commands/backup.sh" replicate --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"No replication targets"* ]]
  [[ "$output" == *"Refusing to guess"* ]]
}

@test "replicate rejects a non-numeric --newest" {
  run env PROJECT_ROOT="${TEST_TMP}" bash "${REPO_ROOT}/scripts/commands/backup.sh" replicate --newest=lots --to=nowhere
  [ "$status" -eq 1 ]
  [[ "$output" == *"--newest must be a positive integer"* ]]
}
