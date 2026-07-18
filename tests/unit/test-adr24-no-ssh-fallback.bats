#!/usr/bin/env bats
# ADR-0024: no lib/ code may SSH+sudo to the GitLab box to create projects.
# The token path (gitlab_api_create_project) is the only sanctioned creator.

LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"

@test "git.sh has no SSH+sudo gitlab-rails project-creation bypass (code, not comments)" {
  # strip comment lines first — a historical mention in a comment is fine; a live call is not
  run bash -c "grep -vE '^[[:space:]]*#' '$LIB_DIR/git.sh' | grep -E 'sudo gitlab-rails runner' || true"
  [ -z "$output" ]
}

@test "gitlab_create_project is a fail-closed ADR-0024 stub (no ssh escalation)" {
  run bash -c "sed -n '/^gitlab_create_project() {/,/^}/p' '$LIB_DIR/git.sh'"
  [[ "$output" == *"ADR-0024"* ]]
  [[ "$output" != *"ssh "* ]]
}

@test "git_push does not auto-invoke gitlab_create_project on push failure" {
  run bash -c "sed -n '/^git_push() {/,/^}/p' '$LIB_DIR/git.sh'"
  [[ "$output" != *"gitlab_create_project"* ]]
}
