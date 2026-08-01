#!/usr/bin/env bats
# `pl backup replicate` — the fail-closed half. The transfer+sha256 half was
# proven live (2026-07-28: 28 artifacts to two peers, all verified); what a
# unit test can pin is the refusal: no declared replica may ever be guessed.
#
# NWP_DIR is the DECLARATION root (nwp.yml, sites/) — PROJECT_ROOT only
# locates lib/ code and is derived from the script's own path, so it cannot
# be overridden from the environment. Before ops#163 the replicate config
# read used PROJECT_ROOT, which meant these tests silently read the real
# checkout's nwp.yml on any machine that has one (and passed only on trees
# without one, e.g. CI — exactly the wrong way round).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TEST_TMP"; }

@test "replicate with no targets configured REFUSES (rc 1, says why)" {
  # Point NWP_DIR at a bare fixture: no nwp.yml, so no replicas key.
  mkdir -p "${TEST_TMP}/root/sites"
  run env NWP_DIR="${TEST_TMP}/root" bash "${REPO_ROOT}/scripts/commands/backup.sh" replicate --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"No replication targets"* ]]
  [[ "$output" == *"Refusing to guess"* ]]
}

@test "replicate refuses via NWP_DIR even when PROJECT_ROOT's nwp.yml declares replicas" {
  # Regression pin for ops#163. Build a decoy PROJECT_ROOT-shaped tree whose
  # nwp.yml DOES declare a replica, with the real lib/ symlinked in so the
  # copied script still sources code, then point NWP_DIR at a bare fixture.
  # Pre-fix, the config read used PROJECT_ROOT and found the decoy's replicas
  # (rc 0, no refusal); the fix makes NWP_DIR authoritative for declarations.
  mkdir -p "${TEST_TMP}/decoy/scripts/commands" "${TEST_TMP}/bare/sites"
  ln -s "${REPO_ROOT}/lib" "${TEST_TMP}/decoy/lib"
  cp "${REPO_ROOT}/scripts/commands/backup.sh" "${TEST_TMP}/decoy/scripts/commands/backup.sh"
  cat > "${TEST_TMP}/decoy/nwp.yml" <<'EOF'
settings:
  backup:
    replicas:
      - decoy@should-never-be-read
EOF
  run env NWP_DIR="${TEST_TMP}/bare" bash "${TEST_TMP}/decoy/scripts/commands/backup.sh" replicate --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"No replication targets"* ]]
  [[ "$output" != *"should-never-be-read"* ]]
}

@test "replicate honours replicas declared in NWP_DIR's nwp.yml" {
  # Positive companion: a replicas entry under NWP_DIR is found and used.
  command -v yq >/dev/null 2>&1 || skip "yq not available"
  mkdir -p "${TEST_TMP}/rootb/sites"
  cat > "${TEST_TMP}/rootb/nwp.yml" <<'EOF'
settings:
  backup:
    replicas:
      - fixture-b@example-target
EOF
  run env NWP_DIR="${TEST_TMP}/rootb" bash "${REPO_ROOT}/scripts/commands/backup.sh" replicate --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"No replication targets"* ]]
  [[ "$output" == *"fixture-b@example-target"* ]]
}

@test "replicate rejects a non-numeric --newest" {
  run env NWP_DIR="${TEST_TMP}" bash "${REPO_ROOT}/scripts/commands/backup.sh" replicate --newest=lots --to=nowhere
  [ "$status" -eq 1 ]
  [[ "$output" == *"--newest must be a positive integer"* ]]
}
