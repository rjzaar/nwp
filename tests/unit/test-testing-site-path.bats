#!/usr/bin/env bats
# resolve_test_site_path must map site identifiers to the correct DDEV dir for
# BOTH the flat v1 layout (sites/<name>) and the v2 nested layout
# (sites/<tenant>/<env>). Regression guard: dev2stg passed basename "$stg_site"
# ("stg"), so lib/testing.sh built sites/stg and every test runner failed with
# "cd: .../sites/stg: No such file or directory", silently skipping the
# stg-verify gate for all v2 sites.

setup() {
  LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export PROJECT_ROOT="${BATS_TEST_TMPDIR}/root"
  mkdir -p "$PROJECT_ROOT/sites/nwc/stg/.ddev" "$PROJECT_ROOT/sites/nwc/dev/.ddev" \
           "$PROJECT_ROOT/sites/flatsite/.ddev"
  : > "$PROJECT_ROOT/sites/nwc/stg/.ddev/config.yaml"
  : > "$PROJECT_ROOT/sites/nwc/dev/.ddev/config.yaml"
  : > "$PROJECT_ROOT/sites/flatsite/.ddev/config.yaml"
  # only source the function; ui.sh may not be present in isolation
  source "$LIB_DIR/testing.sh"
}

@test "full path to a v2 stg dir resolves to itself" {
  run resolve_test_site_path "$PROJECT_ROOT/sites/nwc/stg"
  [ "$output" = "$PROJECT_ROOT/sites/nwc/stg" ]
}

@test "env-suffixed name (nwc-stg) resolves to the nested v2 dir" {
  run resolve_test_site_path "nwc-stg"
  [ "$output" = "$PROJECT_ROOT/sites/nwc/stg" ]
}

@test "bare tenant name defaults to the dev env" {
  run resolve_test_site_path "nwc"
  [ "$output" = "$PROJECT_ROOT/sites/nwc/dev" ]
}

@test "flat v1 site name resolves to sites/<name>" {
  run resolve_test_site_path "flatsite"
  [ "$output" = "$PROJECT_ROOT/sites/flatsite" ]
}

@test "empty name preserves legacy sites/ fallback (CI cwd behaviour)" {
  run resolve_test_site_path ""
  [ "$output" = "$PROJECT_ROOT/sites/" ]
}
