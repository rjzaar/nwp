#!/usr/bin/env bats
# scripts/commands/class.sh — the `pl class` CLI surface.
#
# WHY THIS FILE EXISTS: the 2026-07-28 pre-merge review found the CLI had zero
# test coverage, and that under `set -e` the pattern `x="$(cmd)"; rc=$?` exits
# the script the moment cmd returns non-zero — so every code path whose JOB was
# reporting a non-zero condition (undeclared, contradictory, expired) was
# unreachable: `pl class show` printed an empty table on an estate of
# undeclared sites, and `pl class check <expired>` exited 1 having printed no
# failure token at all. These tests run the script AS A SCRIPT, the way `pl`
# does, against fixtures exercising exactly those paths.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  CLASS_SH="${REPO_ROOT}/scripts/commands/class.sh"

  export PROJECT_ROOT="${TEST_TMP}/root"
  mkdir -p "${PROJECT_ROOT}/sites/undecl" "${PROJECT_ROOT}/pairs"
  echo "schema_version: 3" > "${PROJECT_ROOT}/sites/undecl/.nwp.yml"

  export NWP_SITECLASS_DIR="${PROJECT_ROOT}/classes"
  mkdir -p "${NWP_SITECLASS_DIR}"
  cp "${REPO_ROOT}/classes/registry.yml" "${NWP_SITECLASS_DIR}/registry.yml"

  # an EXPIRED none-stored exemption — the case `check` must report loudly
  cat > "${NWP_SITECLASS_DIR}/expired.class.yml" <<'EOF'
site: expired
class: member-standalone
art9:
  posture: none-stored
  evidence:
    probe_cmd: "true"
    max_members: 1
    max_age_days: 365000
    attestation:
      at: "2020-01-01"
      by: "tester@bats"
      member_count: 0
      formation_rows: 0
  expires: "2020-06-01"
EOF
}

teardown() { rm -rf "$TEST_TMP"; }

@test "class show lists an undeclared site AS undeclared (not an empty table, not a crash)" {
  rm -f "${NWP_SITECLASS_DIR}/expired.class.yml"   # undeclared ALONE this time
  run bash "$CLASS_SH" show
  [ "$status" -eq 0 ]                       # undeclared alone is not 'broken'
  [[ "$output" == *"undecl"* ]]
  [[ "$output" == *"undeclared"* ]]
  [[ "$output" == *"pl class set"* ]]       # the remediation prompt must appear
}

@test "class show flags a broken declaration and exits non-zero" {
  run bash "$CLASS_SH" show
  [ "$status" -eq 1 ]                        # 'expired' is declared+broken
  [[ "$output" == *"expired"* ]]
  [[ "$output" == *"FAIL"* ]]
}

@test "class check on an undeclared site prints the remediation block, rc 1" {
  run bash "$CLASS_SH" check undecl
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNDECLARED"* ]]
  [[ "$output" == *"pl class set undecl"* ]]
}

@test "class check on an expired exemption PRINTS the failure token, rc 1" {
  run bash "$CLASS_SH" check expired
  [ "$status" -eq 1 ]
  [[ "$output" == *EXEMPTION-EXPIRED* ]]
}

@test "class check on a contradictory declaration is rc 2 with both values named" {
  mkdir -p "${PROJECT_ROOT}/sites/expired"
  printf 'schema_version: 3\nclass: demo\n' > "${PROJECT_ROOT}/sites/expired/.nwp.yml"
  run bash "$CLASS_SH" check expired
  [ "$status" -eq 2 ]
  [[ "$output" == *CONTRADICTORY* ]]
}

@test "class evidence on an expired exemption reports FAIL with the token, rc 1" {
  run bash "$CLASS_SH" evidence expired
  [ "$status" -eq 1 ]
  [[ "$output" == *EXEMPTION-EXPIRED* ]]
  [[ "$output" == *"does NOT hold"* ]]
}

@test "class evidence --refresh refuses and prints the declared probe instead" {
  run bash "$CLASS_SH" evidence expired --refresh
  [ "$status" -eq 2 ]
  [[ "$output" == *"NOT IMPLEMENTED"* ]]
}

@test "class set writes NO user@hostname into the tracked declaration" {
  run bash "$CLASS_SH" set newsite demo
  [ "$status" -eq 0 ]
  grep -q 'classified_by: "operator"' "${NWP_SITECLASS_DIR}/newsite.class.yml"
  # a hostname-shaped actor in a tracked file is what the leakage gate exists
  # to stop — the ledger (private/, untracked) is where user@host belongs
  run grep -E "classified_by: .*@\S+" "${NWP_SITECLASS_DIR}/newsite.class.yml"
  [ "$status" -ne 0 ]
}
