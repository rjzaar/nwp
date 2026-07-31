#!/usr/bin/env bats
# `pl server add` — onboard a new server by command (multi-server future-proofing).

setup() {
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  SERVER_SH="${REPO_ROOT}/scripts/commands/server.sh"
  TEST_ROOT="$(mktemp -d)"
  mkdir -p "${TEST_ROOT}/servers"
  # PROJECT_ROOT stays the real repo (so lib/common.sh loads); only the servers
  # write-dir is redirected so the test never touches the real servers/.
  export NWP_SERVERS_DIR="${TEST_ROOT}/servers"
}

teardown() { rm -rf "${TEST_ROOT}"; unset NWP_SERVERS_DIR; }

run_add() { run bash "$SERVER_SH" add "$@"; }

@test "add creates servers/<name>/.nwp-server.yml with the given identity" {
  run_add sites9 --ip=10.20.30.40 --region=us-east --linode-id=42
  [ "$status" -eq 0 ]
  local cfg="${TEST_ROOT}/servers/sites9/.nwp-server.yml"
  [ -f "$cfg" ]
  [ "$(yq eval '.server.name' "$cfg")" = "sites9" ]
  [ "$(yq eval '.server.ip' "$cfg")" = "10.20.30.40" ]
  [ "$(yq eval '.server.region' "$cfg")" = "us-east" ]
  [ "$(yq eval '.server.linode_id' "$cfg")" = "42" ]
  [ "$(yq eval '.server.ssh_user' "$cfg")" = "gitlab" ]
  [ "$(yq eval '.schema_version' "$cfg")" = "1" ]
  [ "$(yq eval '.hosted_sites | length' "$cfg")" = "0" ]
}

@test "add refuses to overwrite an existing server file without --force" {
  run_add sites9 --ip=10.20.30.40
  [ "$status" -eq 0 ]
  run_add sites9 --ip=10.20.30.99
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to overwrite"* ]]
  # original ip preserved
  [ "$(yq eval '.server.ip' "${TEST_ROOT}/servers/sites9/.nwp-server.yml")" = "10.20.30.40" ]
}

@test "add --force overwrites" {
  run_add sites9 --ip=10.20.30.40
  run_add sites9 --ip=10.20.30.99 --force
  [ "$status" -eq 0 ]
  [ "$(yq eval '.server.ip' "${TEST_ROOT}/servers/sites9/.nwp-server.yml")" = "10.20.30.99" ]
}

@test "add rejects a missing/invalid ip and an invalid name" {
  run_add sites9
  [ "$status" -ne 0 ]; [[ "$output" == *"--ip"* ]]
  run_add sites9 --ip=not-an-ip
  [ "$status" -ne 0 ]; [[ "$output" == *"Invalid --ip"* ]]
  run_add "Bad Name" --ip=1.2.3.4
  [ "$status" -ne 0 ]; [[ "$output" == *"Invalid server name"* ]]
  # nothing written on rejection
  [ ! -e "${TEST_ROOT}/servers/sites9/.nwp-server.yml" ]
}
