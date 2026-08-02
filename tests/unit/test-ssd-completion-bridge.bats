#!/usr/bin/env bats
# ssd -> nwd completion bridge: the two provisioners' guards.
#
# Static + pure-logic only. Neither script is ever allowed to reach a Moodle in
# these tests: `demo_moodle_php_run` is the single transport both use, and it is
# stubbed. What is asserted here is the part that must never regress — the tier
# boundary (demo-enabled pair contract required), the dry-run default, the
# required-argument refusals, and the read-only shape of the web-service
# surface the PHP half declares.

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}/pairs"
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  export REPO_ROOT TEST_TMP
  WS_SH="${REPO_ROOT}/scripts/demo/ssd-completion-ws-provision.sh"
  WS_PHP="${REPO_ROOT}/scripts/demo/ssd-completion-ws-provision.php"
  CR_SH="${REPO_ROOT}/scripts/demo/ssd-completion-criteria.sh"
  CR_PHP="${REPO_ROOT}/scripts/demo/ssd-completion-criteria.php"
  export WS_SH WS_PHP CR_SH CR_PHP

  # A demo-ENABLED contract for 'cons', and a demo-LESS one for 'real' — the
  # latter stands in for the ssc<->nwc pair, whose contract has no demo: block.
  cat > "${PROJECT_ROOT}/pairs/cons.pair-contract.yml" <<'YML'
pair: cons-prov
contract_version: 1
provider: prov
consumer: cons
demo:
  enabled: true
oidc:
  cli_php_version: "8.3"
YML
  cat > "${PROJECT_ROOT}/pairs/real.pair-contract.yml" <<'YML'
pair: real-realprov
contract_version: 1
provider: realprov
consumer: real
oidc:
  cli_php_version: "8.3"
YML

  # Stub the ONE transport both scripts use, so nothing can reach a host.
  STUB="${TEST_TMP}/stub.sh"
  cat > "$STUB" <<'STUBEOF'
demo_moodle_php_run() { echo "STUB-RAN: $*"; return 0; }
STUBEOF
  export STUB
}

teardown() { rm -rf "${TEST_TMP}"; }

run_ws() { run env PROJECT_ROOT="$PROJECT_ROOT" NWP_DEMO_TEST_STUB="$STUB" bash "$WS_SH" "$@"; }
run_cr() { run env PROJECT_ROOT="$PROJECT_ROOT" NWP_DEMO_TEST_STUB="$STUB" bash "$CR_SH" "$@"; }

# --- the tier boundary ------------------------------------------------------

@test "ws provisioner REFUSES a site with no demo-enabled pair contract" {
  run_ws --site=real --tier=dev --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"no demo-enabled pair contract"* ]]
}

@test "ws provisioner REFUSES a site with no contract at all" {
  run_ws --site=nosuch --tier=dev --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"no demo-enabled pair contract"* ]]
}

@test "criteria script REFUSES a site with no demo-enabled pair contract" {
  run_cr --site=real --tier=dev --courses=B1 --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"no demo-enabled pair contract"* ]]
}

@test "both scripts REFUSE tier=prod" {
  run_ws --site=cons --tier=prod --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"dev|stg|live only"* ]]
  run_cr --site=cons --tier=prod --courses=B1 --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"dev|stg|live only"* ]]
}

# --- required arguments -----------------------------------------------------

@test "criteria script REFUSES without --courses (no 'all' shortcut)" {
  run_cr --site=cons --tier=dev --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"--courses is required"* ]]
}

@test "ws provisioner REFUSES --token-out without --apply" {
  run_ws --site=cons --tier=dev --check --token-out="${TEST_TMP}/t"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--token-out requires --apply"* ]]
}

# --- dry-run default --------------------------------------------------------

@test "ws provisioner defaults to --check, never --apply" {
  grep -q 'MODE="--check"' "$WS_SH"
  # No code path may default MODE to apply.
  ! grep -qE '^MODE="--apply"' "$WS_SH"
}

@test "criteria script defaults to --check" {
  grep -q 'MODE="--check"' "$CR_SH"
}

@test "a live --apply is gated by a typed confirm" {
  grep -q 'impact_confirm typed' "$WS_SH"
  grep -q 'impact_confirm typed' "$CR_SH"
}

# --- the surface must stay READ-ONLY ---------------------------------------

@test "the declared web-service function list is exactly three READ functions" {
  local fns
  fns=$(sed -n '/^const WS_FUNCTIONS/,/^];/p' "$WS_PHP" | grep -oE "'[a-z_]+'" | tr -d "'")
  [ "$(echo "$fns" | grep -c .)" -eq 3 ]
  echo "$fns" | grep -qx 'core_webservice_get_site_info'
  echo "$fns" | grep -qx 'core_user_get_users_by_field'
  echo "$fns" | grep -qx 'core_enrol_get_users_courses'
}

@test "every declared web-service function is read-shaped" {
  # A bridge that acquires a mutating function has stopped being
  # one-directional. Assert the positive shape (every name contains _get_)
  # rather than blocklisting verbs: `core_enrol_get_users_courses` contains
  # the substring "_enrol_" and a naive blocklist flags it, which is how a
  # guard like this ends up disabled.
  local fns f
  fns=$(sed -n '/^const WS_FUNCTIONS/,/^];/p' "$WS_PHP" | grep -oE "'[a-z_]+'" | tr -d "'")
  [ -n "$fns" ]
  for f in $fns; do
    [[ "$f" == *_get_* ]] || {
      echo "not read-shaped: $f"
      return 1
    }
    [[ "$f" != *_create_* && "$f" != *_update_* && "$f" != *_delete_* ]] || {
      echo "mutating: $f"
      return 1
    }
  done
}

@test "the capability set is closed and PREVENTs the hidden-data caps" {
  grep -q "'moodle/course:viewhiddencourses' => CAP_PREVENT" "$WS_PHP"
  grep -q "'moodle/course:viewhiddenuserfields' => CAP_PREVENT" "$WS_PHP"
  # An unexpected capability on the role must be REPORTED, not ignored.
  grep -q 'UNEXPECTED capability' "$WS_PHP"
  grep -q 'UNEXPECTED function' "$WS_PHP"
}

@test "the external service is restricted to its authorised user" {
  grep -q 'restrictedusers  = 1' "$WS_PHP"
  grep -q "DRIFT restrictedusers != 1" "$WS_PHP"
}

@test "the service account cannot log in interactively" {
  grep -q "auth        = 'webservice'" "$WS_PHP"
}

# --- the token must never be printed ---------------------------------------

@test "the provisioner never echoes a token except on the marked capture line" {
  # Exactly one emission point, and it is behind --emit-token.
  [ "$(grep -c 'NWP-WS-TOKEN:' "$WS_PHP")" -eq 1 ]
  grep -q "emit-token" "$WS_PHP"
  # The wrapper strips that line before showing anything.
  grep -q "grep -v '\^NWP-WS-TOKEN:'" "$WS_SH"
  # And the capture file is created 0600.
  grep -q 'chmod 600 "\$TOKEN_OUT"' "$WS_SH"
}

@test "the mint path reports without the value" {
  grep -q "minted (value NOT printed)" "$WS_PHP"
}

# --- criteria script scope --------------------------------------------------

@test "criteria script only ever adds ACTIVITY criteria, aggregated ALL" {
  grep -q 'COMPLETION_CRITERIA_TYPE_ACTIVITY' "$CR_PHP"
  grep -q 'COMPLETION_AGGREGATION_ALL' "$CR_PHP"
  # It must not delete anything.
  ! grep -qE 'delete_records|->delete\(' "$CR_PHP"
}
