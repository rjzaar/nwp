#!/usr/bin/env bats
# P67 / nwp/ops#48 — maturity classes: lib functions + guard semantics.

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}"
  export NWP_YML="${PROJECT_ROOT}/nwp.yml"
  cat > "${NWP_YML}" <<'EOF'
sites:
  inc-site:
    recipe: d
  stab-site:
    recipe: d
    maturity: stabilizing
  prod-site:
    recipe: d
    maturity: production
    canonical: prod
  bad-site:
    recipe: d
    maturity: bogus
EOF
  source "${BATS_TEST_DIRNAME}/../../lib/ui.sh"
  source "${BATS_TEST_DIRNAME}/../../lib/yaml-write.sh"
  source "${BATS_TEST_DIRNAME}/../../lib/canonical.sh"
}

teardown() {
  rm -rf "${TEST_TMP}"
  unset NWP_YML PROJECT_ROOT
}

_make_repo() {
  # $1 = site name. Must be called directly (NOT in $(...) — a subshell would
  # lose the resolve_project shim). Sets global DIR.
  DIR="${PROJECT_ROOT}/sites/$1/dev"
  mkdir -p "$DIR"
  git -C "$DIR" init -q -b main
  git -C "$DIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  # simulate origin/main at current HEAD
  git -C "$DIR" update-ref refs/remotes/origin/main HEAD
  SITE_UNDER_TEST="$1"
  resolve_project() { echo "${PROJECT_ROOT}/sites/${SITE_UNDER_TEST}/dev"; }
}

@test "class defaults to incubating; explicit + invalid read back" {
  [ "$(maturity_get_class inc-site)" = "incubating" ]
  ! maturity_class_is_explicit inc-site
  [ "$(maturity_get_class stab-site)" = "stabilizing" ]
  maturity_class_is_explicit stab-site
  [ "$(maturity_get_class bad-site)" = "invalid:bogus" ]
  [ "$(maturity_get_class never-registered)" = "incubating" ]
}

@test "pair validation refuses the invalid corners" {
  run maturity_validate_pair incubating prod
  [ "$status" -ne 0 ]
  run maturity_validate_pair production dev
  [ "$status" -ne 0 ]
  run maturity_validate_pair stabilizing live
  [ "$status" -eq 0 ]
  run maturity_validate_pair production prod
  [ "$status" -eq 0 ]
}

@test "guard: incubating always allowed" {
  run maturity_guard_deploy inc-site stg2live
  [ "$status" -eq 0 ]
}

@test "guard: invalid class fails closed" {
  run maturity_guard_deploy bad-site stg2live
  [ "$status" -ne 0 ]
  [[ "$output" == *"fail closed"* ]]
}

@test "guard: production refuses with signed-path guidance" {
  run maturity_guard_deploy prod-site stg2live
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"signed-bundle"* ]]
}

@test "guard: stabilizing allows clean merged main" {
  _make_repo stab-site
  run maturity_guard_deploy stab-site stg2live
  [ "$status" -eq 0 ]
}

@test "guard: stabilizing refuses a feature branch" {
  _make_repo stab-site
  git -C "$DIR" switch -q -c feature-z
  run maturity_guard_deploy stab-site stg2live
  [ "$status" -ne 0 ]
  [[ "$output" == *"only from main"* ]]
}

@test "guard: stabilizing refuses a dirty tree" {
  _make_repo stab-site
  touch "$DIR/wip.txt"
  run maturity_guard_deploy stab-site stg2live
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted"* ]]
}

@test "guard: stabilizing refuses local commits not on origin/main" {
  _make_repo stab-site
  git -C "$DIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m local-only
  run maturity_guard_deploy stab-site stg2live
  [ "$status" -ne 0 ]
  [[ "$output" == *"not on origin/main"* ]]
}

@test "deploy manifest stamps maturity beside canonical_phase" {
  run canonical_deploy_manifest stab-site testaction
  [ "$status" -eq 0 ]
  command -v python3 >/dev/null || skip "python3 unavailable"
  python3 -c "
import json
d=json.load(open('$output'))
assert d['maturity']=='stabilizing'
assert d['canonical_phase']=='dev'
"
}
