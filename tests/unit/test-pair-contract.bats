#!/usr/bin/env bats
# =============================================================================
# tests/unit/test-pair-contract.bats — item 8 `art9-cross-repo-contract`
# =============================================================================
# The pair contract is a CROSS-REPO promise: nwp/nwp declares endpoints and web
# service functions that live in a DIFFERENT repository (nwp/ss-moodle-plugins,
# checked out at sites/<consumer>/.plugin-src/). Nothing checked that the other
# repo actually honours the promise, so:
#
#   * nwc production code calls the Moodle WS function `auth_nwc_set_consent`
#     which origin/main of ss-moodle-plugins DOES NOT DEFINE (the Art.9
#     withdrawal push fails gracefully — forever, invisibly);
#   * both pair contracts declared smoke probes at
#     /local/nwc_copyright_sync/status.php and /local/feedback/api.php —
#     neither file has ever existed (the real entrypoints are policy_set.php
#     and submit.php).
#
# `pl contracts crossref` is the gate. These are its acceptance tests. Every
# case below was run against the PRE-FIX tree and observed RED first.
#
# Self-contained fixtures; no network, no secrets, no live site.
# =============================================================================

CONTRACTS_SH="${BATS_TEST_DIRNAME}/../../scripts/commands/contracts.sh"

setup() {
  TMP="$(mktemp -d)"
  export PROJECT_ROOT="${TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}/pairs" "${PROJECT_ROOT}/contracts"
  export NWP_PAIR_CONTRACT_DIR="${PROJECT_ROOT}/pairs"

  # --- fixture PROVIDER tree (Drupal side, a separate repo in real life) -----
  PROV="${PROJECT_ROOT}/sites/prov/dev/html/profiles/custom/prov"
  mkdir -p "${PROV}/modules/svc"
  cat > "${PROV}/modules/svc/MoodleConsentPush.php" <<'PHP'
<?php
class MoodleConsentPush {
  public const WS_FUNCTION = 'auth_nwc_set_consent';
  public function pushWithdrawal(string $sub): array {
    $q = ['wsfunction' => self::WS_FUNCTION];
    return $q;
  }
}
PHP

  # --- fixture CONSUMER tree (Moodle plugin repo checkout) -------------------
  CONS="${PROJECT_ROOT}/sites/cons/.plugin-src/moodle-plugins"
  mkdir -p "${CONS}/local/nwc_copyright_sync" "${CONS}/local/feedback" "${CONS}/auth/nwc/db"
  : > "${CONS}/local/nwc_copyright_sync/policy_set.php"
  : > "${CONS}/local/feedback/submit.php"

  write_contract  # default: the BROKEN shape (undefined WS fn + phantom paths)
}

# Emit the fixture pair contract. Args are optional overrides:
#   $1 = consumer smoke path      (default: the phantom status.php)
#   $2 = extra yaml appended under crossref: (e.g. core_paths)
write_contract() {
  local smoke_path="${1:-/local/nwc_copyright_sync/status.php}"
  local extra="${2:-}"
  cat > "${NWP_PAIR_CONTRACT_DIR}/cons.pair-contract.yml" <<EOF
pair: cons-prov
contract_version: 1
provider: prov
consumer: cons
crossref:
  provider_roots:
    - "sites/prov/dev/html/profiles/custom/prov"
  consumer_roots:
    - "sites/cons/.plugin-src/moodle-plugins"
${extra}
smoke_urls:
  - name: provider_health
    side: provider
    path: "/user/login"
    method: GET
    expect_status: "200"
  - name: copyright_status
    side: consumer
    path: "${smoke_path}"
    method: GET
    expect_status: "200"
EOF
}

# Give the consumer tree the WS function definition Moodle really uses.
define_ws_function() {
  cat > "${CONS}/auth/nwc/db/services.php" <<'PHP'
<?php
$functions = [
    'auth_nwc_set_consent' => [
        'classname'   => 'auth_nwc\external\set_consent',
        'description' => 'Push a consent withdrawal from the provider.',
        'type'        => 'write',
    ],
];
PHP
}

teardown() {
  rm -rf "$TMP"
  unset PROJECT_ROOT NWP_PAIR_CONTRACT_DIR
}

# =============================================================================
# (a) cross-repo WS-function gate — the auth_nwc_set_consent defect
# =============================================================================

@test "crossref: FAILS when provider code calls a WS function the consumer does not define" {
  define_ws_function_never() { :; }   # deliberately not defined
  run bash "$CONTRACTS_SH" crossref cons
  [ "$status" -ne 0 ]
  [[ "$output" == *"auth_nwc_set_consent"* ]]
  [[ "$output" == *"UNDEFINED-WS"* ]]
}

@test "crossref: passes the WS gate once the consumer declares it in db/services.php" {
  define_ws_function
  write_contract "/local/nwc_copyright_sync/policy_set.php"
  run bash "$CONTRACTS_SH" crossref cons
  [ "$status" -eq 0 ]
  [[ "$output" == *"auth_nwc_set_consent"* ]]
  [[ "$output" != *"UNDEFINED-WS"* ]]
}

@test "crossref: a core_ws_functions declaration is an explicit, recorded exemption" {
  write_contract "/local/nwc_copyright_sync/policy_set.php" \
    '  core_ws_functions:
    - auth_nwc_set_consent'
  run bash "$CONTRACTS_SH" crossref cons
  [ "$status" -eq 0 ]
  [[ "$output" == *"core-exempt"* ]]
}

# =============================================================================
# (b) smoke_urls consumer-path gate — the status.php / api.php defect
# =============================================================================

@test "crossref: FAILS when a consumer smoke_url names a path that does not exist" {
  define_ws_function
  run bash "$CONTRACTS_SH" crossref cons
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING-PATH"* ]]
  [[ "$output" == *"status.php"* ]]
}

@test "crossref: passes when the consumer smoke_url path really exists" {
  define_ws_function
  write_contract "/local/feedback/submit.php"
  run bash "$CONTRACTS_SH" crossref cons
  [ "$status" -eq 0 ]
  [[ "$output" != *"MISSING-PATH"* ]]
}

@test "crossref: a core_paths entry exempts a Moodle-core endpoint" {
  define_ws_function
  write_contract "/auth/oauth2/login.php" \
    '  core_paths:
    - "auth/oauth2/login.php"'
  run bash "$CONTRACTS_SH" crossref cons
  [ "$status" -eq 0 ]
  [[ "$output" == *"core-exempt"* ]]
}

@test "crossref: a query string / fragment does not defeat the path check" {
  define_ws_function
  write_contract "/local/feedback/submit.php?id=1"
  run bash "$CONTRACTS_SH" crossref cons
  [ "$status" -eq 0 ]
}

# =============================================================================
# (c) empty corpus must say "cannot verify" — never a silent green
# =============================================================================

@test "crossref: CANNOT-VERIFY (non-zero) when no consumer root is checked out" {
  define_ws_function
  rm -rf "${PROJECT_ROOT}/sites/cons"
  run bash "$CONTRACTS_SH" crossref cons
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "crossref: CANNOT-VERIFY (non-zero) when no provider root is checked out" {
  define_ws_function
  rm -rf "${PROJECT_ROOT}/sites/prov"
  run bash "$CONTRACTS_SH" crossref cons
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "crossref: a contract with NO crossref block is a declared gap, not a pass" {
  cat > "${NWP_PAIR_CONTRACT_DIR}/bare.pair-contract.yml" <<'EOF'
pair: bare-prov
contract_version: 1
provider: prov
consumer: bare
EOF
  run bash "$CONTRACTS_SH" crossref bare
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

# =============================================================================
# (d) trust anchor — exactly one signature file
# =============================================================================

@test "contracts verify: FAILS when two *.minisig files sit in contracts/" {
  printf '{"a":1}\n' > "${PROJECT_ROOT}/contracts/x.schema.json"
  ( cd "${PROJECT_ROOT}/contracts" && sha256sum x.schema.json > SHA256SUMS )
  : > "${PROJECT_ROOT}/contracts/SHA256SUMS.minisig"
  : > "${PROJECT_ROOT}/contracts/SHA256SUMS.minisig.local-untracked-bak"
  run bash "$CONTRACTS_SH" verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"AMBIGUOUS TRUST ANCHOR"* ]]
}

@test "contracts verify: names every candidate signature file it found" {
  printf '{"a":1}\n' > "${PROJECT_ROOT}/contracts/x.schema.json"
  ( cd "${PROJECT_ROOT}/contracts" && sha256sum x.schema.json > SHA256SUMS )
  : > "${PROJECT_ROOT}/contracts/SHA256SUMS.minisig"
  : > "${PROJECT_ROOT}/contracts/SHA256SUMS.minisig.bak"
  run bash "$CONTRACTS_SH" verify
  [[ "$output" == *"SHA256SUMS.minisig.bak"* ]]
}

# =============================================================================
# (e) shipped contracts — regression pins on the real files
# =============================================================================
# These read the REAL pairs/*.pair-contract.yml out of the repo. They are the
# pins that stop the phantom probe URLs coming back.

@test "shipped ssc contract: no consumer smoke_url points at a phantom endpoint" {
  run grep -E 'nwc_copyright_sync/status\.php|local/feedback/api\.php' \
      "${BATS_TEST_DIRNAME}/../../pairs/ssc.pair-contract.yml"
  [ "$status" -ne 0 ]
}

@test "shipped ssd contract: no consumer smoke_url points at a phantom endpoint" {
  run grep -E 'nwc_copyright_sync/status\.php|local/feedback/api\.php' \
      "${BATS_TEST_DIRNAME}/../../pairs/ssd.pair-contract.yml"
  [ "$status" -ne 0 ]
}

@test "shipped ssc contract: the ops#116 sanitizer boundary entries are intact" {
  local f="${BATS_TEST_DIRNAME}/../../pairs/ssc.pair-contract.yml"
  grep -q 'oidc_email_rewrite_sql' "$f"
  grep -q 'lib/sanitizers/standard.sh' "$f"
  grep -q 'lib/sanitizers/mayo.sh' "$f"
}

@test "shipped contracts: every pair contract declares a crossref corpus" {
  local f
  for f in "${BATS_TEST_DIRNAME}"/../../pairs/*.pair-contract.yml; do
    grep -q '^crossref:' "$f" || {
      echo "no crossref: block in $f"
      return 1
    }
  done
}
