#!/usr/bin/env bats
# ADR-0036 / nwp/ops#153, ops#154 — per-site CLASS and the evidenced-N/A rule.
#
# THE DEFECT UNDER TEST
#   `pl moodle gate-status rgs` reports mod/depthcontent [UNGATED]. The gate
#   wants ">=1 may_keep_formation call delegating to auth_nwc"; rgs is unpaired
#   and has no auth_nwc, so the check can NEVER pass there and --allow-ungated
#   became permanent. A class lets a site declare that a gate is legitimately
#   N/A — which is only safe if "N/A" is itself checkable.
#
# THE TRAP THIS SUITE IS BUILT AROUND
#   A class must never become a quiet off-switch. So the exemption tests are
#   written as SABOTAGE: for every obligation of `none-stored`, break exactly
#   that one thing and assert the exemption FAILS with its own token. A suite
#   that only proved the happy path would be testing that the gate can be
#   switched off, not that it holds.
#
# Pure fixtures. NO ddev / ssh / network / secrets / live sites.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "${REPO_ROOT}/lib/ui.sh"

  export PROJECT_ROOT="${TEST_TMP}/root"
  mkdir -p "${PROJECT_ROOT}/sites" "${PROJECT_ROOT}/pairs"

  export NWP_SITECLASS_DIR="${PROJECT_ROOT}/classes"
  mkdir -p "${NWP_SITECLASS_DIR}"
  cp "${REPO_ROOT}/classes/registry.yml" "${NWP_SITECLASS_DIR}/registry.yml"

  source "${REPO_ROOT}/lib/siteclass.sh"

  TODAY="$(date -u +%F)"

  # --- fixture: a member-standalone site with a VALID none-stored exemption ---
  # (rgs's real shape: unpaired, live, single sample user, zero formation rows)
  cat > "${NWP_SITECLASS_DIR}/standalone.class.yml" <<EOF
site: standalone
class: member-standalone
art9:
  posture: none-stored
  evidence:
    probe_cmd: "pl moodle cli standalone --tier=live --execute -- probe.php"
    max_members: 1
    max_age_days: 30
    attestation:
      at: "${TODAY}"
      by: "tester@bats"
      member_count: 1
      formation_rows: 0
  expires: "2099-01-01"
EOF

  # --- fixture: a member-paired site, ordinary delegated posture -------------
  # This is the NEGATIVE CONTROL: properly classed, properly evidenced, and it
  # must keep passing with NO exemption of any kind.
  cat > "${NWP_SITECLASS_DIR}/paired.class.yml" <<'EOF'
site: paired
class: member-paired
art9:
  posture: delegated
  consent_source: provider1
  consent_source_class: auth_nwc
EOF
  cat > "${PROJECT_ROOT}/pairs/paired.pair-contract.yml" <<'EOF'
pair: paired-provider1
provider: provider1
consumer: paired
EOF

  # A helper to rewrite one field of the standalone declaration.
  sabotage() { yq eval -i "$1" "${NWP_SITECLASS_DIR}/standalone.class.yml"; }
}

teardown() { rm -rf "${TEST_TMP}"; }

# =============================================================================
# The closed set
# =============================================================================

@test "class set is CLOSED at exactly four classes" {
  # Widening the vocabulary must be a deliberate, reviewed act — not something
  # that happens because someone needed one more escape hatch.
  run bash -c 'echo "'"$SITECLASS_CLASSES"'" | tr " " "\n" | sort | tr "\n" " "'
  [ "$status" -eq 0 ]
  [ "$output" = "demo member-paired member-standalone service " ]
}

@test "every class in the registry is one of the four, and vice versa" {
  reg_classes="$(yq eval '.classes | keys | .[]' "${NWP_SITECLASS_DIR}/registry.yml" | sort | tr '\n' ' ')"
  code_classes="$(echo "$SITECLASS_CLASSES" | tr ' ' '\n' | sort | tr '\n' ' ')"
  [ "$reg_classes" = "$code_classes" ]
}

@test "an unknown class is rejected, not defaulted" {
  run siteclass_valid_class "sort-of-live"
  [ "$status" -ne 0 ]
}

# =============================================================================
# Resolution — fails closed
# =============================================================================

@test "an undeclared site is 'undeclared' and NON-zero (not a permissive default)" {
  mkdir -p "${PROJECT_ROOT}/sites/nodecl"
  echo "schema_version: 3" > "${PROJECT_ROOT}/sites/nodecl/.nwp.yml"
  run siteclass_of nodecl
  [ "$status" -eq 1 ]
  [ "$output" = "undeclared" ]
}

@test "a tracked declaration resolves to its class" {
  run siteclass_of standalone
  [ "$status" -eq 0 ]
  [ "$output" = "member-standalone" ]
}

@test "tracked declaration vs site config DISAGREEING is contradictory and fails closed" {
  mkdir -p "${PROJECT_ROOT}/sites/standalone"
  printf 'schema_version: 3\nclass: demo\n' > "${PROJECT_ROOT}/sites/standalone/.nwp.yml"
  run siteclass_of standalone
  [ "$status" -eq 2 ]
  [[ "$output" == contradictory:* ]]
}

@test "a class declared ONLY in gitignored config is not accepted (must be reviewable)" {
  # nwp.yml is never committed and sites/* is gitignored. A claim that decides
  # whether the Art.9 gate applies cannot live somewhere a reviewer never sees.
  mkdir -p "${PROJECT_ROOT}/sites/cfgonly"
  printf 'schema_version: 3\nclass: service\n' > "${PROJECT_ROOT}/sites/cfgonly/.nwp.yml"
  run siteclass_of cfgonly
  [ "$status" -eq 2 ]
  [[ "$output" == cannot-verify:config-only* ]]
}

@test "an invalid class value is invalid: not silently ignored" {
  cat > "${NWP_SITECLASS_DIR}/bogus.class.yml" <<'EOF'
site: bogus
class: whatever
EOF
  run siteclass_of bogus
  [ "$status" -eq 2 ]
  [[ "$output" == invalid:whatever ]]
}

# =============================================================================
# NEGATIVE CONTROL — a properly-classed, properly-evidenced site passes
# =============================================================================

@test "NEGATIVE CONTROL: a valid none-stored exemption PASSES" {
  run siteclass_art9_check standalone
  [ "$status" -eq 0 ]
}

@test "NEGATIVE CONTROL: a delegated paired site passes and claims NO exemption" {
  run siteclass_art9_check paired
  [ "$status" -eq 0 ]
  # The crucial half: passing the posture check must NOT make it exempt.
  run siteclass_art9_exempt paired
  [ "$status" -ne 0 ]
}

# =============================================================================
# SABOTAGE — every obligation of `none-stored` must be able to FAIL
# =============================================================================

@test "SABOTAGE probe_cmd removed -> NO-PROBE" {
  sabotage 'del(.art9.evidence.probe_cmd)'
  run siteclass_art9_check standalone
  [ "$status" -eq 1 ]
  [[ "$output" == *NO-PROBE* ]]
}

@test "SABOTAGE attestation removed -> NO-ATTESTATION" {
  sabotage 'del(.art9.evidence.attestation)'
  run siteclass_art9_check standalone
  [ "$status" -eq 1 ]
  [[ "$output" == *NO-ATTESTATION* ]]
}

@test "SABOTAGE attestation older than max_age_days -> STALE-ATTESTATION" {
  sabotage '.art9.evidence.attestation.at = "2020-01-01"'
  run siteclass_art9_check standalone
  [ "$status" -eq 1 ]
  [[ "$output" == *STALE-ATTESTATION* ]]
}

@test "SABOTAGE formation rows present -> EVIDENCE-CONTRADICTS (the vacuity trap)" {
  # The site claims it stores no formation data while its own evidence records
  # rows. If this passed, the class WOULD be an off-switch.
  sabotage '.art9.evidence.attestation.formation_rows = 12'
  run siteclass_art9_check standalone
  [ "$status" -eq 1 ]
  [[ "$output" == *EVIDENCE-CONTRADICTS* ]]
}

@test "SABOTAGE member count over cap -> MEMBER-CAP-EXCEEDED (ops#153's 'the day it takes a member')" {
  sabotage '.art9.evidence.attestation.member_count = 2'
  run siteclass_art9_check standalone
  [ "$status" -eq 1 ]
  [[ "$output" == *MEMBER-CAP-EXCEEDED* ]]
}

@test "SABOTAGE expiry in the past -> EXEMPTION-EXPIRED" {
  sabotage '.art9.expires = "2020-01-01"'
  run siteclass_art9_check standalone
  [ "$status" -eq 1 ]
  [[ "$output" == *EXEMPTION-EXPIRED* ]]
}

@test "SABOTAGE expiry removed entirely -> EXEMPTION-EXPIRED (no open-ended exemptions)" {
  sabotage 'del(.art9.expires)'
  run siteclass_art9_check standalone
  [ "$status" -eq 1 ]
  [[ "$output" == *EXEMPTION-EXPIRED* ]]
}

@test "SABOTAGE missing declaration -> CANNOT-VERIFY, never a pass" {
  rm -f "${NWP_SITECLASS_DIR}/standalone.class.yml"
  run siteclass_art9_check standalone
  [ "$status" -eq 2 ]
  [[ "$output" == *CANNOT-VERIFY* ]]
}

@test "SABOTAGE posture absent -> CANNOT-VERIFY (the load-bearing fact is not implicit)" {
  sabotage 'del(.art9.posture)'
  run siteclass_art9_check standalone
  [ "$status" -eq 2 ]
  [[ "$output" == *CANNOT-VERIFY* ]]
}

# =============================================================================
# THE ABUSE CASE — a class must not let a paired site buy its way out
# =============================================================================

@test "ABUSE: a member-paired site cannot claim a none-stored exemption, even with perfect evidence" {
  cat > "${NWP_SITECLASS_DIR}/paired.class.yml" <<EOF
site: paired
class: member-paired
art9:
  posture: none-stored
  evidence:
    probe_cmd: "true"
    max_members: 99999
    max_age_days: 3650
    attestation:
      at: "${TODAY}"
      by: "attacker"
      member_count: 0
      formation_rows: 0
  expires: "2099-01-01"
EOF
  run siteclass_art9_check paired
  [ "$status" -eq 1 ]
  [[ "$output" == *POSTURE-NOT-PERMITTED* ]]

  run siteclass_art9_exempt paired
  [ "$status" -ne 0 ]
}

@test "ABUSE: posture delegated on an UNPAIRED site is NO-CONSENT-SOURCE, not a pass" {
  # The inverse of the rgs bug: you cannot claim delegation where there is
  # nothing to delegate to.
  cat > "${NWP_SITECLASS_DIR}/lonely.class.yml" <<'EOF'
site: lonely
class: member-paired
art9:
  posture: delegated
  consent_source: ghost
EOF
  run siteclass_art9_check lonely
  [ "$status" -eq 1 ]
  [[ "$output" == *NO-CONSENT-SOURCE* ]]
}

@test "ABUSE: posture local pointing at a non-existent source is CANNOT-VERIFY" {
  cat > "${NWP_SITECLASS_DIR}/localsrc.class.yml" <<'EOF'
site: localsrc
class: member-standalone
art9:
  posture: local
  consent_source_plugin: local/consent
  consent_source_class: local_consent
  consent_source_root: does/not/exist
EOF
  run siteclass_art9_check localsrc
  [ "$status" -eq 2 ]
  [[ "$output" == *LOCAL-SOURCE-ABSENT* ]]
}

# =============================================================================
# Gate wiring — the class may reclassify a FAILURE, never suppress the SCAN
# =============================================================================

@test "GATE: an exempt site's ungated artifact is allowed, loudly, and ledgered" {
  source "${REPO_ROOT}/lib/moodle-gate.sh"
  UNGATED="${TEST_TMP}/ungated"; mkdir -p "$UNGATED"
  echo "<?php function depthcontent_store(\$x) { return true; }" > "${UNGATED}/lib.php"

  run moodle_gate_assert standalone live false mod/depthcontent "$UNGATED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EXEMPT BY EVIDENCE"* ]]

  # and the pass is recorded as an event, not just a setting
  grep -q "action=class-exempt" "${PROJECT_ROOT}/private/moodle-gate/standalone.log"
}

@test "GATE: the SAME ungated artifact is REFUSED on an undeclared site" {
  source "${REPO_ROOT}/lib/moodle-gate.sh"
  UNGATED="${TEST_TMP}/ungated"; mkdir -p "$UNGATED"
  echo "<?php function depthcontent_store(\$x) { return true; }" > "${UNGATED}/lib.php"

  run moodle_gate_assert nodecl live false mod/depthcontent "$UNGATED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ART.9 GATE MISSING"* ]]
}

@test "GATE: a class whose EVIDENCE has failed does NOT excuse the artifact" {
  source "${REPO_ROOT}/lib/moodle-gate.sh"
  sabotage '.art9.evidence.attestation.member_count = 5'   # took members
  UNGATED="${TEST_TMP}/ungated"; mkdir -p "$UNGATED"
  echo "<?php function depthcontent_store(\$x) { return true; }" > "${UNGATED}/lib.php"

  run moodle_gate_assert standalone live false mod/depthcontent "$UNGATED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ART.9 GATE MISSING"* ]]
  [[ "$output" == *MEMBER-CAP-EXCEEDED* ]]
}

@test "GATE: a GATED artifact still passes on a paired site (no regression)" {
  source "${REPO_ROOT}/lib/moodle-gate.sh"
  GATED="${TEST_TMP}/gated"; mkdir -p "$GATED"
  cat > "${GATED}/lib.php" <<'PHP'
<?php
function depthcontent_may_keep_formation($userid): bool {
    return \auth_nwc\consent::may_keep_formation((int) $userid);
}
PHP
  run moodle_gate_assert paired live false mod/depthcontent "$GATED"
  [ "$status" -eq 0 ]
  [[ "$output" != *"EXEMPT BY EVIDENCE"* ]]   # passed by DELEGATION, not exemption
}

# =============================================================================
# Real declarations shipped in this repo must themselves be valid
# =============================================================================

@test "the shipped rgs declaration is internally consistent" {
  export NWP_SITECLASS_DIR="${REPO_ROOT}/classes"
  run siteclass_of rgs
  [ "$status" -eq 0 ]
  [ "$output" = "member-standalone" ]
}

@test "the shipped ssc declaration is member-paired and DELEGATED (never exempt)" {
  export NWP_SITECLASS_DIR="${REPO_ROOT}/classes"
  run siteclass_art9_posture ssc
  [ "$output" = "delegated" ]
  run siteclass_art9_exempt ssc
  [ "$status" -ne 0 ]
}
