#!/usr/bin/env bats
# get_site_server — "which server does this site deploy to?"
#
# THE DEFECT THIS GUARDS (found during the 2026-07-31 box split): the function
# read "$(resolve_project <site>)/.nwp.yml", but resolve_project returns the
# working CHECKOUT (sites/nwd/dev) while the declaration lives at the SITE root
# (sites/nwd/.nwp.yml). So it returned empty for every site laid out that way —
# silently. Callers that use it to choose a deployment target were therefore
# taking their fallback branch 100% of the time, which is how a script whose
# job is to wipe and rebuild the demo site could be aimed at the wrong box.
#
# Empty must never be a quiet "use the default": these tests pin that the
# canonical location is read, and that an undeclared site FAILS rather than
# returning something a caller could mistake for an answer.

setup() {
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  TEST_ROOT="$(mktemp -d)"
  export NWP_DIR="${TEST_ROOT}"
  export PROJECT_ROOT="${TEST_ROOT}"

  # A site laid out the way the real fleet is: declaration at the site root,
  # working checkout in an environment subdirectory below it.
  mkdir -p "${TEST_ROOT}/sites/demosite/dev"
  cat > "${TEST_ROOT}/sites/demosite/.nwp.yml" <<'EOF'
schema_version: 2
project:
  name: demosite
  type: drupal
live:
  enabled: true
  server: boxtwo
EOF

  # A site with no live declaration at all.
  mkdir -p "${TEST_ROOT}/sites/orphan/dev"
  cat > "${TEST_ROOT}/sites/orphan/.nwp.yml" <<'EOF'
schema_version: 2
project:
  name: orphan
  type: drupal
EOF
}

teardown() { rm -rf "${TEST_ROOT}"; unset NWP_DIR PROJECT_ROOT; }

@test "reads .live.server from the SITE root, not the environment checkout" {
  run bash -c "source '${REPO_ROOT}/lib/server-resolver.sh'; get_site_server demosite"
  [ "$status" -eq 0 ]
  [ "$output" = "boxtwo" ]
}

@test "a site with no .live.server FAILS instead of returning an empty answer" {
  run bash -c "source '${REPO_ROOT}/lib/server-resolver.sh'; get_site_server orphan"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "an unknown site FAILS" {
  run bash -c "source '${REPO_ROOT}/lib/server-resolver.sh'; get_site_server nosuchsite"
  [ "$status" -ne 0 ]
}

@test "get_site_server and get_server_sites agree on the same declarations" {
  # The two directions of the same mapping must not disagree — that split is
  # what let a site be 'on' a server for one gate and invisible to another.
  run bash -c "source '${REPO_ROOT}/lib/server-resolver.sh'; get_server_sites boxtwo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"demosite"* ]]
  [[ "$output" != *"orphan"* ]]
}
