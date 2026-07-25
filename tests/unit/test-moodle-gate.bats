#!/usr/bin/env bats
# ops#137 — the Art.9 "ship-together" invariant guard.
#
# Covers BOTH halves of the fix:
#   (a) the REPOINT   — _moodle_resolve_source defaults to the canonical repo
#                       cache, not the stale ~/nwptoolkit snapshot;
#   (b) the ASSERTION — moodle_gate_assert REFUSES an artifact that does not
#                       carry the consent gate, and ledgers --allow-ungated.
# Plus gate-status reporting on gated/ungated fixtures.
#
# Pure fixtures. NO ddev / ssh / network / secrets / live sites.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "${REPO_ROOT}/lib/ui.sh"
  source "${REPO_ROOT}/lib/moodle-gate.sh"

  # Ledger + resolver both key off PROJECT_ROOT — sandbox it.
  export PROJECT_ROOT="${TEST_TMP}/root"
  mkdir -p "${PROJECT_ROOT}"

  # --- fixture: a GATED consumer (calls the symbol AND delegates to auth_nwc) --
  GATED="${TEST_TMP}/gated"
  mkdir -p "${GATED}"
  cat > "${GATED}/lib.php" <<'PHP'
<?php
function depthcontent_may_keep_formation($userid): bool {
    return \auth_nwc\consent::may_keep_formation((int) $userid);
}
PHP

  # --- fixture: an UNGATED consumer (the ~/nwptoolkit shape — no gate at all) --
  UNGATED="${TEST_TMP}/ungated"
  mkdir -p "${UNGATED}"
  echo "<?php function depthcontent_store(\$x) { return true; }" > "${UNGATED}/lib.php"

  # --- fixture: a DECOY consumer — calls the symbol but never reaches auth_nwc -
  DECOY="${TEST_TMP}/decoy"
  mkdir -p "${DECOY}"
  cat > "${DECOY}/lib.php" <<'PHP'
<?php
function depthcontent_may_keep_formation($userid): bool { return true; }
PHP

  # --- fixture: the PROVIDER (defines the gate) -------------------------------
  PROVIDER="${TEST_TMP}/provider"
  mkdir -p "${PROVIDER}/classes"
  cat > "${PROVIDER}/classes/consent.php" <<'PHP'
<?php
namespace auth_nwc;
class consent {
    public static function may_keep_formation(int $userid): bool { return false; }
}
PHP
}

teardown() { rm -rf "${TEST_TMP}"; }

################################################################################
# Classification — fail-closed by default, small explicit allowlist
################################################################################

@test "gate: mod/depthcontent and local/practice are consumers" {
  [ "$(moodle_gate_requirement mod/depthcontent)" = "consumer" ]
  [ "$(moodle_gate_requirement local/practice)"   = "consumer" ]
}

@test "gate: auth/nwc is the provider" {
  [ "$(moodle_gate_requirement auth/nwc)" = "provider" ]
}

@test "gate: allowlisted plugins are exempt" {
  [ "$(moodle_gate_requirement local/browse)"         = "exempt" ]
  [ "$(moodle_gate_requirement course/format/tabbed)" = "exempt" ]
}

@test "gate: an UNKNOWN plugin fails closed (treated as a consumer)" {
  [ "$(moodle_gate_requirement mod/brandnew)" = "consumer" ]
}

################################################################################
# Artifact scanning + reporting
################################################################################

@test "gate-status: reports GATED for an artifact carrying the gate" {
  [ "$(moodle_gate_report mod/depthcontent "$GATED")" = "GATED" ]
}

@test "gate-status: reports UNGATED for the ~/nwptoolkit-shaped artifact" {
  [ "$(moodle_gate_report mod/depthcontent "$UNGATED")" = "UNGATED" ]
}

@test "gate-status: a DECOY gate that never reaches auth_nwc is UNGATED" {
  [ "$(moodle_gate_report mod/depthcontent "$DECOY")" = "UNGATED" ]
}

@test "gate-status: provider is GATED only when it defines the symbol" {
  [ "$(moodle_gate_report auth/nwc "$PROVIDER")" = "GATED" ]
  [ "$(moodle_gate_report auth/nwc "$UNGATED")"  = "UNGATED" ]
}

@test "gate-status: exempt plugins report EXEMPT even from an empty dir" {
  [ "$(moodle_gate_report local/browse "$UNGATED")" = "EXEMPT" ]
}

@test "gate-status: a missing directory reports ABSENT (never GATED)" {
  [ "$(moodle_gate_report mod/depthcontent "${TEST_TMP}/nope")" = "ABSENT" ]
}

@test "gate scan counts calls, delegations and definitions" {
  run moodle_gate_scan "$GATED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"calls=2"*       ]]
  [[ "$output" == *"delegations=1"* ]]
  run moodle_gate_scan "$UNGATED"
  [[ "$output" == "calls=0 delegations=0 definitions=0 tests=0" ]]
}

# The Art.9 vendor merge silently deleted mod/depthcontent/tests/write_gate_test.php.
# A restored test file is a corroborating signal — it must NEVER by itself make a
# plugin whose production code lost the gate read as GATED.
@test "gate scan: tests/ are counted separately, never as production gate calls" {
  mkdir -p "${UNGATED}/tests"
  cat > "${UNGATED}/tests/write_gate_test.php" <<'PHP'
<?php
// Asserts the gate: \auth_nwc\consent::may_keep_formation() blocks writes.
class write_gate_test extends advanced_testcase {
    public function test_may_keep_formation() { $this->assertFalse(false); }
}
PHP
  run moodle_gate_scan "$UNGATED"
  [[ "$output" == *"calls=0"* ]]
  [[ "$output" == *"delegations=0"* ]]
  [[ "$output" == *"tests=1"* ]]
}

@test "gate-status: a plugin with ONLY a gate test (no production gate) is UNGATED" {
  mkdir -p "${UNGATED}/tests"
  cat > "${UNGATED}/tests/write_gate_test.php" <<'PHP'
<?php
class write_gate_test extends advanced_testcase {
    public function test_gate() { \auth_nwc\consent::may_keep_formation(1); }
}
PHP
  [ "$(moodle_gate_report mod/depthcontent "$UNGATED")" = "UNGATED" ]
}

@test "gate scan: a gated plugin still reports its test coverage" {
  mkdir -p "${GATED}/tests"
  echo "<?php // may_keep_formation coverage" > "${GATED}/tests/write_gate_test.php"
  run moodle_gate_scan "$GATED"
  [[ "$output" == *"calls=2"* ]]
  [[ "$output" == *"tests=1"* ]]
}

################################################################################
# The assertion — REFUSE an ungated artifact
################################################################################

@test "assert: a gated artifact is allowed through" {
  run moodle_gate_assert ssc live false mod/depthcontent "$GATED"
  [ "$status" -eq 0 ]
}

@test "assert: an UNGATED artifact REFUSES the deploy and names ops#137" {
  run moodle_gate_assert ssc live false mod/depthcontent "$UNGATED"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ART.9 GATE MISSING"* ]]
  [[ "$output" == *"DEPLOY REFUSED"*     ]]
  [[ "$output" == *"ops#137"*            ]]
  [[ "$output" == *"ss-moodle-plugins"*  ]]
}

@test "assert: the refusal names the offending plugin and its staged source" {
  run moodle_gate_assert ssc live false mod/depthcontent "$UNGATED"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mod/depthcontent"* ]]
  [[ "$output" == *"$UNGATED"*         ]]
}

@test "assert: a MISSING source directory refuses (never silently passes)" {
  run moodle_gate_assert ssc live false mod/depthcontent "${TEST_TMP}/nope"
  [ "$status" -ne 0 ]
}

@test "assert: one ungated plugin in a mixed set refuses the whole deploy" {
  run moodle_gate_assert ssc live false \
      mod/depthcontent "$GATED" local/practice "$UNGATED"
  [ "$status" -ne 0 ]
  [[ "$output" == *"local/practice"* ]]
}

@test "assert: exempt plugins are not checked" {
  run moodle_gate_assert ssc live false local/browse "$UNGATED"
  [ "$status" -eq 0 ]
}

@test "assert: an unknown plugin with no gate refuses (fail-closed default)" {
  run moodle_gate_assert ssc live false mod/brandnew "$UNGATED"
  [ "$status" -ne 0 ]
}

################################################################################
# --allow-ungated: proceeds, loudly, and ledgers
################################################################################

@test "assert: --allow-ungated proceeds on an ungated artifact" {
  run moodle_gate_assert ssc live true mod/depthcontent "$UNGATED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROCEEDING WITH AN UNGATED ARTIFACT"* ]]
}

@test "assert: --allow-ungated writes a ledger entry naming plugin, tier and ops#137" {
  moodle_gate_assert ssc live true mod/depthcontent "$UNGATED" >/dev/null 2>&1
  local log="${PROJECT_ROOT}/private/moodle-gate/ssc.log"
  [ -f "$log" ]
  grep -q "action=allow-ungated" "$log"
  grep -q "ref=ops#137"          "$log"
  grep -q "plugin=mod/depthcontent" "$log"
  grep -q "tier=live"            "$log"
}

@test "assert: --allow-ungated does NOT ledger when the gate is present" {
  moodle_gate_assert ssc live true mod/depthcontent "$GATED" >/dev/null 2>&1
  [ ! -f "${PROJECT_ROOT}/private/moodle-gate/ssc.log" ]
}

################################################################################
# The REPOINT — source resolution order (scripts/commands/moodle.sh)
################################################################################

# Build a fake site tree: canonical cache + dev tree + a fake ~/nwptoolkit.
_mk_site() {
  SITE_BASE="ssc"
  mkdir -p "${PROJECT_ROOT}/sites/${SITE_BASE}"
  CFG="${PROJECT_ROOT}/sites/${SITE_BASE}/.nwp.yml"
  cat > "$CFG" <<'YML'
schema_version: 2
project:
  name: ssc
  type: moodle
YML
  CACHE="${PROJECT_ROOT}/sites/${SITE_BASE}/.plugin-src/ss-moodle-plugins/mod/depthcontent"
  DEVP="${PROJECT_ROOT}/sites/${SITE_BASE}/dev/mod/depthcontent"
  mkdir -p "$CACHE" "$DEVP"
  cp "${GATED}/lib.php" "$CACHE/lib.php"
  cp "${GATED}/lib.php" "$DEVP/lib.php"

  export HOME="${TEST_TMP}/home"
  TOOLKIT="${HOME}/nwptoolkit/moodle/plugins/mod/depthcontent"
  mkdir -p "$TOOLKIT"
  cp "${UNGATED}/lib.php" "$TOOLKIT/lib.php"

  # Source the command file for its resolver (dispatch is skipped when sourced).
  source "${REPO_ROOT}/scripts/commands/moodle.sh"
}

# The dev tree stays the DEFAULT (it is the working promotion source for ssc and
# the ssd rebuild depends on it). Only the FALLBACK moved off ~/nwptoolkit.
@test "resolve: DEFAULT is the site dev tree (unchanged promotion source)" {
  _mk_site
  run bash -c "PROJECT_ROOT='${PROJECT_ROOT}' HOME='${TEST_TMP}/home' \
    source '${REPO_ROOT}/lib/ui.sh'; source '${REPO_ROOT}/scripts/commands/moodle.sh'; \
    _moodle_resolve_source '${CFG}' ssc mod/depthcontent '' false false >/dev/null 2>&1; \
    echo \"\$MOODLE_SRC_ORIGIN|\$MOODLE_SRC_DIR\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev-tree (default)"* ]]
  [[ "$output" == *"sites/ssc/dev/mod/depthcontent"* ]]
  [[ "$output" != *"nwptoolkit"* ]]
}

@test "resolve: FALLBACK with no dev tree is the canonical repo, NOT ~/nwptoolkit" {
  _mk_site
  rm -rf "${PROJECT_ROOT}/sites/ssc/dev"
  run bash -c "PROJECT_ROOT='${PROJECT_ROOT}' HOME='${TEST_TMP}/home' \
    source '${REPO_ROOT}/lib/ui.sh'; source '${REPO_ROOT}/scripts/commands/moodle.sh'; \
    _moodle_resolve_source '${CFG}' ssc mod/depthcontent '' false false >/dev/null 2>&1; \
    echo \"\$MOODLE_SRC_ORIGIN|\$MOODLE_SRC_DIR\""
  [[ "$output" == *"canonical-repo-cache"* ]]
  [[ "$output" == *".plugin-src/ss-moodle-plugins/mod/depthcontent"* ]]
  [[ "$output" != *"nwptoolkit"* ]]
}

@test "resolve: with no dev tree and no cache it REFUSES rather than fall back to ~/nwptoolkit" {
  _mk_site
  rm -rf "${PROJECT_ROOT}/sites/ssc/.plugin-src" "${PROJECT_ROOT}/sites/ssc/dev"
  run bash -c "PROJECT_ROOT='${PROJECT_ROOT}' HOME='${TEST_TMP}/home' \
    source '${REPO_ROOT}/lib/ui.sh'; source '${REPO_ROOT}/scripts/commands/moodle.sh'; \
    _moodle_resolve_source '${CFG}' ssc mod/depthcontent '' false false"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No source resolved"* ]]
  [[ "$output" == *"plugins sync"*       ]]
}

@test "resolve: --from-nwptoolkit FORCES its rung even when the dev tree exists" {
  _mk_site
  run bash -c "PROJECT_ROOT='${PROJECT_ROOT}' HOME='${TEST_TMP}/home' \
    source '${REPO_ROOT}/lib/ui.sh'; source '${REPO_ROOT}/scripts/commands/moodle.sh'; \
    _moodle_resolve_source '${CFG}' ssc mod/depthcontent '' true false >/dev/null 2>&1; \
    echo \"\$MOODLE_SRC_ORIGIN|\$MOODLE_SRC_DIR\""
  [[ "$output" == *"nwptoolkit"* ]]
  [[ "$output" != *"dev-tree"*   ]]
}

@test "resolve: --from-nwptoolkit opts in explicitly and warns it is stale" {
  _mk_site
  rm -rf "${PROJECT_ROOT}/sites/ssc/.plugin-src" "${PROJECT_ROOT}/sites/ssc/dev"
  run bash -c "PROJECT_ROOT='${PROJECT_ROOT}' HOME='${TEST_TMP}/home' \
    source '${REPO_ROOT}/lib/ui.sh'; source '${REPO_ROOT}/scripts/commands/moodle.sh'; \
    _moodle_resolve_source '${CFG}' ssc mod/depthcontent '' true false; \
    echo \"ORIGIN=\$MOODLE_SRC_ORIGIN\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"STALE"*            ]]
  [[ "$output" == *"ops#137"*          ]]
  [[ "$output" == *"local/practice"*   ]]
  [[ "$output" == *"ORIGIN=nwptoolkit"* ]]
}

@test "resolve: an explicit --from wins over every other rung" {
  _mk_site
  run bash -c "PROJECT_ROOT='${PROJECT_ROOT}' HOME='${TEST_TMP}/home' \
    source '${REPO_ROOT}/lib/ui.sh'; source '${REPO_ROOT}/scripts/commands/moodle.sh'; \
    _moodle_resolve_source '${CFG}' ssc mod/depthcontent '${GATED}' false false >/dev/null 2>&1; \
    echo \"\$MOODLE_SRC_ORIGIN|\$MOODLE_SRC_DIR\""
  [[ "$output" == *"flag:--from"* ]]
  [[ "$output" == *"${GATED}"*    ]]
}

@test "resolve: --from-canonical forces the repo cache over the dev tree" {
  _mk_site
  run bash -c "PROJECT_ROOT='${PROJECT_ROOT}' HOME='${TEST_TMP}/home' \
    source '${REPO_ROOT}/lib/ui.sh'; source '${REPO_ROOT}/scripts/commands/moodle.sh'; \
    _moodle_resolve_source '${CFG}' ssc mod/depthcontent '' false true >/dev/null 2>&1; \
    echo \"\$MOODLE_SRC_ORIGIN|\$MOODLE_SRC_DIR\""
  [[ "$output" == *"--from-canonical"* ]]
  [[ "$output" == *".plugin-src"*      ]]
}

# The real regression risk: an UNGATED dev tree (ss and ss2 carry one today).
# Source precedence cannot catch this — only the artifact assertion can.
@test "assert: an UNGATED DEV TREE is refused just like an ungated snapshot" {
  run moodle_gate_assert ss live false mod/depthcontent "$UNGATED"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ART.9 GATE MISSING"* ]]
}

################################################################################
# Command surface
################################################################################

@test "moodle.sh help documents the ops#137 resolution order and the override" {
  run bash "${REPO_ROOT}/scripts/commands/moodle.sh" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"ops#137"*          ]]
  [[ "$output" == *"plugins sync"*     ]]
  [[ "$output" == *"gate-status"*      ]]
  [[ "$output" == *"--allow-ungated"*  ]]
}

@test "moodle.sh rejects unknown plugins subcommands" {
  run bash "${REPO_ROOT}/scripts/commands/moodle.sh" plugins bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"sync|status"* ]]
}

@test "sourcing moodle.sh does not dispatch (unit-testable helpers)" {
  run bash -c "source '${REPO_ROOT}/scripts/commands/moodle.sh'; declare -F _moodle_resolve_source >/dev/null && echo DEFINED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEFINED"* ]]
  [[ "$output" != *"USAGE:"*  ]]
}
