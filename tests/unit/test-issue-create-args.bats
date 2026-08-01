#!/usr/bin/env bats
# pl issue create — argument parsing must never turn a flag into an issue.
#
# On 2026-08-01 `pl issue create --help` filed a REAL nwp/ops issue titled
# "--help" (nwp/ops#186): the bare-arg fallback swallowed the unrecognised flag
# as the title. These tests pin the fix. They are hermetic: NWP_SECRETS_FILE
# points at a nonexistent path, so if parsing ever falls through to the API
# call again the run dies at token lookup instead of touching GitLab.

setup() {
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  export REPO_ROOT
  export NWP_SECRETS_FILE="/nonexistent/never-a-secrets-file.yml"
}

@test "pl issue create --help prints usage, exits 0, files nothing" {
  run bash "${REPO_ROOT}/scripts/commands/issue.sh" create --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: pl issue create --title"* ]]
}

@test "pl issue create -h behaves the same as --help" {
  run bash "${REPO_ROOT}/scripts/commands/issue.sh" create -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: pl issue create --title"* ]]
}

@test "an unknown flag is refused — it never becomes the title" {
  run bash "${REPO_ROOT}/scripts/commands/issue.sh" create --bogus-flag
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option: --bogus-flag"* ]]
}

@test "NEGATIVE CONTROL: a real bare title still parses (dies at token, not at parsing)" {
  # The fix must not break the documented bare-title form. With no secrets file
  # the run dies AFTER parsing, at token lookup — proving the title survived.
  run bash "${REPO_ROOT}/scripts/commands/issue.sh" create "a real title"
  [ "$status" -ne 0 ]
  [[ "$output" != *"unknown option"* ]]
  [[ "$output" != *"usage: pl issue create"* ]]
}
