#!/usr/bin/env bats
# Unit tests for the instance-dir resolver (lib/common/find-instance-dir.sh).
#
# sites/ is the PRIMARY in-repo per-site location (F17/F23 layout). The
# ~/nwp-instances overlay is an OPTIONAL operator overlay (role manifest,
# _global, _servers) that takes precedence when present. F33/NWP-ADR-0021, which
# planned to deprecate sites/, were superseded/rejected — resolving to sites/
# must NOT print any deprecation warning.

setup() {
  TEST_TMP=$(mktemp -d)
  export HOME="${TEST_TMP}/home"
  mkdir -p "${HOME}"
  # Source under test
  SCRIPT_DIR="${TEST_TMP}/nwp"
  mkdir -p "${SCRIPT_DIR}/sites"
  source "${BATS_TEST_DIRNAME}/../../lib/common/find-instance-dir.sh"
}

teardown() {
  rm -rf "${TEST_TMP}"
  unset NWP_INSTANCES_DIR
}

@test "env var takes precedence" {
  export NWP_INSTANCES_DIR="${TEST_TMP}/some-other-dir"
  result=$(find_instance_dir)
  [[ "${result}" == "${TEST_TMP}/some-other-dir" ]]
}

@test "falls back to \$HOME/nwp-instances when env unset and dir exists" {
  unset NWP_INSTANCES_DIR
  mkdir -p "${HOME}/nwp-instances"
  result=$(find_instance_dir)
  [[ "${result}" == "${HOME}/nwp-instances" ]]
}

@test "resolves ./sites (primary in-repo location) when no overlay exists and sites has real content" {
  unset NWP_INSTANCES_DIR
  rm -rf "${HOME}/nwp-instances"
  mkdir -p "${SCRIPT_DIR}/sites/somereal"
  touch "${SCRIPT_DIR}/sites/somereal/nwp.yml"
  result=$(find_instance_dir 2>/dev/null)
  [[ "${result}" == "${SCRIPT_DIR}/sites" ]]
}

@test "does NOT resolve ./sites when only README and example templates present" {
  unset NWP_INSTANCES_DIR
  rm -rf "${HOME}/nwp-instances"
  rm -rf "${SCRIPT_DIR}/sites"
  mkdir -p "${SCRIPT_DIR}/sites"
  touch "${SCRIPT_DIR}/sites/README.md"
  touch "${SCRIPT_DIR}/sites/example-site.example.yml"
  result=$(find_instance_dir 2>/dev/null)
  [[ -z "${result}" ]]
}

@test "resolving ./sites is SILENT — no deprecation warning (F33 superseded, NWP-ADR-0021 rejected)" {
  unset NWP_INSTANCES_DIR
  rm -rf "${HOME}/nwp-instances"
  mkdir -p "${SCRIPT_DIR}/sites/somereal"
  err=$(find_instance_dir 2>&1 >/dev/null)
  [[ -z "${err}" ]]
}

@test "returns empty when no overlay is configured at all" {
  unset NWP_INSTANCES_DIR
  rm -rf "${HOME}/nwp-instances"
  rm -rf "${SCRIPT_DIR}/sites"
  result=$(find_instance_dir 2>/dev/null)
  [[ -z "${result}" ]]
}
