#!/usr/bin/env bats
# =============================================================================
# tests/unit/test-deploy-on-merge-fanout.bats — ops#326 Phase 1 tranche 2
#
# scripts/agent-loop/deploy-on-merge.sh used to hardcode a literal two-site
# fan-out loop — the operator's topology, one half of it a REAL private site,
# shipped in engine code. The fan-out list is now ESTATE CONFIGURATION:
#
#   1. NWP_MOODLE_PLUGIN_FANOUT        (env, whitespace-separated)
#   2. NWP_MOODLE_PLUGIN_FANOUT_FILE   (file path override)
#   3. $NWP_ROOT/private/agent-loop/moodle-plugin-fanout (one site per line,
#      '#' comments — lives in the private overlay repo)
#
# Unconfigured ⇒ LOUD no-op: nothing is rsynced and the log says exactly why.
# `--print-fanout` resolves and prints the list without touching git or any
# site tree, which is what makes this contract testable.
# =============================================================================

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/agent-loop/deploy-on-merge.sh"

setup() {
  TEST_TMP="$(mktemp -d)"
  export NWP_ROOT="${TEST_TMP}/estate"
  mkdir -p "${NWP_ROOT}"
  unset NWP_MOODLE_PLUGIN_FANOUT NWP_MOODLE_PLUGIN_FANOUT_FILE
}

teardown() { rm -rf "$TEST_TMP"; }

@test "ops#326: unconfigured fan-out is a LOUD no-op (exit 0, says why)" {
  run bash "$SCRIPT" --print-fanout
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO MOODLE PLUGIN FAN-OUT CONFIGURED"* ]]
  [[ "$output" == *"moodle-plugin-fanout"* ]]
}

@test "ops#326: NWP_MOODLE_PLUGIN_FANOUT env supplies the site list" {
  export NWP_MOODLE_PLUGIN_FANOUT="fxa fxb"
  run bash "$SCRIPT" --print-fanout
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "fxa" ]
  [ "${lines[1]}" = "fxb" ]
}

@test "ops#326: the estate file supplies the site list (comments/blanks skipped)" {
  mkdir -p "${NWP_ROOT}/private/agent-loop"
  cat > "${NWP_ROOT}/private/agent-loop/moodle-plugin-fanout" <<'EOF'
# local site trees that receive merged Moodle plugins
fxc

fxd  # trailing comments are NOT stripped — one bare site name per line
EOF
  # the file above deliberately includes a trailing-comment line: it must be
  # passed through as-is (the estate owns its hygiene), so only assert the
  # clean line and the comment/blank skipping.
  run bash "$SCRIPT" --print-fanout
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "fxc" ]
  [[ "${lines[1]}" == fxd* ]]
}

@test "ops#326: the engine no longer hardcodes a literal fan-out site list" {
  # No `for site in <literal names>` loop remains — the only iteration source
  # is moodle_fanout_sites (estate config). Written without naming any site:
  # the name-lint (lint:site-names) forbids the denied names in this file too.
  ! grep -qE 'for site in [a-z]' "$SCRIPT"
  grep -q 'moodle_fanout_sites' "$SCRIPT"
}
