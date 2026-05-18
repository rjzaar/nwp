#!/usr/bin/env bats
# F33 §4.2 — unit tests for the instance-dir resolver.

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

@test "falls back to ./sites when nwp-instances doesn't exist and sites has real content" {
  unset NWP_INSTANCES_DIR
  rm -rf "${HOME}/nwp-instances"
  mkdir -p "${SCRIPT_DIR}/sites/somereal"
  touch "${SCRIPT_DIR}/sites/somereal/nwp.yml"
  result=$(find_instance_dir 2>/dev/null)
  [[ "${result}" == "${SCRIPT_DIR}/sites" ]]
}

@test "does NOT fall back to ./sites when only README and example templates present" {
  unset NWP_INSTANCES_DIR
  rm -rf "${HOME}/nwp-instances"
  rm -rf "${SCRIPT_DIR}/sites"
  mkdir -p "${SCRIPT_DIR}/sites"
  touch "${SCRIPT_DIR}/sites/README.md"
  touch "${SCRIPT_DIR}/sites/example-site.example.yml"
  result=$(find_instance_dir 2>/dev/null)
  [[ -z "${result}" ]]
}

@test "prints deprecation warning to stderr when falling back to ./sites" {
  unset NWP_INSTANCES_DIR
  rm -rf "${HOME}/nwp-instances"
  mkdir -p "${SCRIPT_DIR}/sites/somereal"
  err=$(find_instance_dir 2>&1 >/dev/null)
  [[ "${err}" == *DEPRECATION* ]]
}

@test "returns empty when no overlay is configured at all" {
  unset NWP_INSTANCES_DIR
  rm -rf "${HOME}/nwp-instances"
  rm -rf "${SCRIPT_DIR}/sites"
  result=$(find_instance_dir 2>/dev/null)
  [[ -z "${result}" ]]
}
