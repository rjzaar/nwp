#!/usr/bin/env bats
# nwp/ops#33 — canonicality phases: yaml set-field helper + lib/canonical.sh guards.

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}"
  export NWP_YML="${PROJECT_ROOT}/nwp.yml"
  cat > "${NWP_YML}" <<'EOF'
settings:
  url: example.org

sites:
  alpha:
    recipe: os
    purpose: permanent
  beta:
    recipe: d
    canonical: live
    purpose: testing
  gamma:
    recipe: d
    canonical: bogus
EOF
  source "${BATS_TEST_DIRNAME}/../../lib/ui.sh"
  source "${BATS_TEST_DIRNAME}/../../lib/yaml-write.sh"
  source "${BATS_TEST_DIRNAME}/../../lib/canonical.sh"
}

teardown() {
  rm -rf "${TEST_TMP}"
  unset NWP_YML PROJECT_ROOT
}

# --- yaml_set_site_field (update-or-insert) ---

@test "yaml_set_site_field inserts a missing field under the site header" {
  run yaml_set_site_field "alpha" "canonical" "dev" "${NWP_YML}"
  [ "$status" -eq 0 ]
  run yaml_get_site_field "alpha" "canonical" "${NWP_YML}"
  [ "$output" = "dev" ]
  # sibling site untouched
  run yaml_get_site_field "beta" "canonical" "${NWP_YML}"
  [ "$output" = "live" ]
}

@test "yaml_set_site_field updates an existing field in place (no duplicate key)" {
  yaml_set_site_field "beta" "canonical" "prod" "${NWP_YML}"
  run yaml_get_site_field "beta" "canonical" "${NWP_YML}"
  [ "$output" = "prod" ]
  [ "$(grep -c '^    canonical:' "${NWP_YML}")" -eq 2 ]  # beta + gamma only
}

@test "yaml_set_site_field fails for an unknown site" {
  run yaml_set_site_field "nosuch" "canonical" "dev" "${NWP_YML}"
  [ "$status" -ne 0 ]
}

# --- canonical_get_phase ---

@test "phase defaults to dev when field absent" {
  run canonical_get_phase "alpha"
  [ "$output" = "dev" ]
  ! canonical_phase_is_explicit "alpha"
}

@test "explicit phase is read back" {
  run canonical_get_phase "beta"
  [ "$output" = "live" ]
  canonical_phase_is_explicit "beta"
}

@test "unparseable phase surfaces as invalid (fail-closed input)" {
  run canonical_get_phase "gamma"
  [ "$output" = "invalid:bogus" ]
  ! canonical_phase_is_explicit "gamma"
}

@test "unregistered site defaults to dev" {
  run canonical_get_phase "never-heard-of-it"
  [ "$output" = "dev" ]
}

# --- canonical_guard_content_push ---

@test "guard allows dev→live push when canonical: dev" {
  run canonical_guard_content_push "alpha" "live" "false" "stg2live"
  [ "$status" -eq 0 ]
}

@test "guard refuses dev→live push when canonical: live" {
  run canonical_guard_content_push "beta" "live" "false" "stg2live"
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
}

@test "guard fails closed on an invalid phase" {
  run canonical_guard_content_push "gamma" "live" "false" "stg2live"
  [ "$status" -ne 0 ]
}

@test "override allows the push, warns loudly, and writes the ledger" {
  run canonical_guard_content_push "beta" "live" "true" "stg2live"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CANONICAL OVERRIDE"* ]]
  ledger="${PROJECT_ROOT}/private/canonical/beta.log"
  [ -f "$ledger" ]
  grep -q "action=override cmd=stg2live target=live phase=live" "$ledger"
  grep -q "who=" "$ledger"
}

@test "prod-target push allowed under live-canonical (cutover path), refused under prod-canonical" {
  run canonical_guard_content_push "beta" "prod" "false" "live2prod"
  [ "$status" -eq 0 ]
  yaml_set_site_field "beta" "canonical" "prod" "${NWP_YML}"
  run canonical_guard_content_push "beta" "prod" "false" "live2prod"
  [ "$status" -ne 0 ]
}

# --- canonical_warn_dev_content ---

@test "dev-content warning is silent under dev, loud otherwise" {
  run canonical_warn_dev_content "alpha"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run canonical_warn_dev_content "beta"
  [ "$status" -eq 0 ]
  [[ "$output" == *"THROWAWAY"* ]]
}

# --- canonical_enforce_branch_policy (canonical: prod) ---

_make_prod_site_repo() {
  # register site delta as canonical: prod with a real dev git repo
  cat >> "${NWP_YML}" <<'EOF'
  delta:
    recipe: d
    canonical: prod
EOF
  DEV_DIR="${PROJECT_ROOT}/sites/delta/dev"
  mkdir -p "${DEV_DIR}"
  git -C "${DEV_DIR}" init -q -b main
  git -C "${DEV_DIR}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  # canonical_enforce_branch_policy resolves the repo via resolve_project
  resolve_project() { echo "${PROJECT_ROOT}/sites/delta/dev"; }
}

@test "branch policy is a no-op unless canonical: prod" {
  run canonical_enforce_branch_policy "beta" "deploy"
  [ "$status" -eq 0 ]
}

@test "prod deploy allowed from clean main, refused from a branch or dirty tree" {
  _make_prod_site_repo
  run canonical_enforce_branch_policy "delta" "deploy"
  [ "$status" -eq 0 ]

  git -C "${DEV_DIR}" switch -q -c feature-x
  run canonical_enforce_branch_policy "delta" "deploy"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CI-gated main"* ]]

  git -C "${DEV_DIR}" switch -q main
  touch "${DEV_DIR}/dirty.txt"
  run canonical_enforce_branch_policy "delta" "deploy"
  [ "$status" -ne 0 ]
}

@test "prod work mode refuses only uncommitted changes on main" {
  _make_prod_site_repo
  run canonical_enforce_branch_policy "delta" "work"
  [ "$status" -eq 0 ]

  touch "${DEV_DIR}/wip.txt"
  run canonical_enforce_branch_policy "delta" "work"
  [ "$status" -ne 0 ]
  [[ "$output" == *"branches only"* ]]

  git -C "${DEV_DIR}" switch -q -c feature-y
  run canonical_enforce_branch_policy "delta" "work"
  [ "$status" -eq 0 ]
}

# --- canonical_deploy_manifest ---

@test "deploy manifest stamps the canonical phase + extras" {
  run canonical_deploy_manifest "beta" "stg2live" "code_only=true" "override=false"
  [ "$status" -eq 0 ]
  manifest="$output"
  [ -f "$manifest" ]
  command -v python3 >/dev/null || skip "python3 unavailable"
  run python3 -c "
import json,sys
d=json.load(open('$manifest'))
assert d['site']=='beta' and d['action']=='stg2live'
assert d['canonical_phase']=='live'
assert d['code_only']=='true' and d['override']=='false'
assert d['by'] and d['timestamp']
"
  [ "$status" -eq 0 ]
}
