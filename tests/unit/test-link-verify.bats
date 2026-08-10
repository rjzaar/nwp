#!/usr/bin/env bats
# tests/unit/test-link-verify.bats — pl link verify (PL-STG2LIVE §5.5/§5.6)
#
# Covers: dispatch/help; tier validation; --round-trip skipped on prod; the §5.6
# sub-claim assertion logic (numeric uid ⇒ red, uuid ⇒ pass) via the extractable
# helpers; and no-secret-leak in the tokenless auth path. Offline throughout
# (--no-network) — uses the SAMPLE ssd pair contract shipped in pairs/
# (the real pair's contract lives in the private overlay; ops#326).

LINK_SH="${BATS_TEST_DIRNAME}/../../scripts/commands/link.sh"
PL="${BATS_TEST_DIRNAME}/../../pl"

setup() {
  export NO_COLOR=1
  TEST_TMP="$(mktemp -d)"
  export NWP_PAIR_STATE_DIR="${TEST_TMP}/state"
  mkdir -p "${NWP_PAIR_STATE_DIR}"
}
teardown() { rm -rf "${TEST_TMP}"; unset NWP_PAIR_STATE_DIR NO_COLOR; }

# --- dispatch / help --------------------------------------------------------

@test "help lists the verify + stub verbs" {
  run bash "$LINK_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"pl link verify"* ]]
  [[ "$output" == *"STUB"* ]]
}

@test "unknown subcommand is refused" {
  run bash "$LINK_SH" frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown subcommand"* ]]
}

@test "provision/token/keys are honest stubs (§5.7), exit 0" {
  run bash "$LINK_SH" provision ssd --tier=live
  [ "$status" -eq 0 ]
  [[ "$output" == *"not yet implemented"* ]]
  run bash "$LINK_SH" token rotate ssd --tier=live
  [ "$status" -eq 0 ]
  [[ "$output" == *"not yet implemented"* ]]
  run bash "$LINK_SH" keys rotate ssd --tier=live
  [ "$status" -eq 0 ]
  [[ "$output" == *"not yet implemented"* ]]
}

@test "routed through pl as 'pl link verify'" {
  run bash "$PL" link verify ssd --tier=live --no-network
  [ "$status" -eq 0 ]
  [[ "$output" == *"Link verify"* ]]
}

# --- tier validation --------------------------------------------------------

@test "missing --tier is refused" {
  run bash "$LINK_SH" verify ssd
  [ "$status" -ne 0 ]
  [[ "$output" == *"--tier is required"* ]]
}

@test "invalid --tier is refused (dev has no link gate)" {
  run bash "$LINK_SH" verify ssd --tier=dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --tier"* ]]
}

@test "missing pair is refused" {
  run bash "$LINK_SH" verify --tier=live
  [ "$status" -ne 0 ]
  [[ "$output" == *"pair is required"* ]]
}

# --- structural (offline) assertions pass on the real contract --------------

@test "offline structural verify is GREEN and writes the pair RAG" {
  run bash "$LINK_SH" verify ssd --tier=live --no-network
  [ "$status" -eq 0 ]
  [[ "$output" == *"Link verify GREEN"* ]]
  [ "$(cat "${NWP_PAIR_STATE_DIR}/ssd.live.rag")" = "green" ]
}

@test "hyphenated pair id 'nwd-ssd' resolves to the ssd contract" {
  run bash "$LINK_SH" verify nwd-ssd --tier=live --no-network
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssd ↔ nwd"* ]]
}

# --- --round-trip skipped on prod (§5.5) ------------------------------------

@test "--round-trip is SKIPPED on prod (read-only probe only)" {
  run bash "$LINK_SH" verify ssd --tier=prod --round-trip --no-network
  [ "$status" -eq 0 ]
  [[ "$output" == *"Round-trip SKIPPED on prod"* ]]
  # must NOT have attempted the channel 2/3 synthetic POSTs
  [[ "$output" != *"synthetic no-op policy"* ]]
}

# --- §5.6 sub-claim assertion: the extractable helper -----------------------

@test "link_sub_is_uuid: numeric uid is NOT a uuid" {
  source "$LINK_SH"
  run link_sub_is_uuid 42
  [ "$status" -ne 0 ]
}

@test "link_sub_is_uuid: a well-formed UUID passes" {
  source "$LINK_SH"
  run link_sub_is_uuid "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
  [ "$status" -eq 0 ]
}

@test "link_sub_verdict: numeric uid ⇒ red-numeric-uid (the §5.6 blocker)" {
  source "$LINK_SH"
  run link_sub_verdict 42
  [ "$status" -ne 0 ]
  [ "$output" = "red-numeric-uid" ]
}

@test "link_sub_verdict: uuid ⇒ pass" {
  source "$LINK_SH"
  run link_sub_verdict "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "link_sub_verdict: uuid that != expected idnumber ⇒ red-mismatch" {
  source "$LINK_SH"
  run link_sub_verdict "3f2504e0-4f89-41d3-9a0c-0305e82c3301" "deadbeef-0000-0000-0000-000000000000"
  [ "$status" -ne 0 ]
  [ "$output" = "red-mismatch" ]
}

# --- §5.6 assertion end-to-end via --observed-sub ---------------------------

@test "verify RED (exit + RAG red) when observed sub is a numeric uid" {
  run bash "$LINK_SH" verify ssd --tier=live --no-network --observed-sub=42
  [ "$status" -ne 0 ]
  [[ "$output" == *"NUMERIC Drupal uid"* ]]
  [[ "$output" == *"UserInfoController must emit sub => \$account->uuid()"* ]]
  [ "$(cat "${NWP_PAIR_STATE_DIR}/ssd.live.rag")" = "red" ]
}

@test "verify GREEN when observed sub is a UUID matching the expected idnumber" {
  local u="3f2504e0-4f89-41d3-9a0c-0305e82c3301"
  run bash "$LINK_SH" verify ssd --tier=live --no-network --observed-sub="$u" --expected-idnumber="$u"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Link verify GREEN"* ]]
  [ "$(cat "${NWP_PAIR_STATE_DIR}/ssd.live.rag")" = "green" ]
}

# --- structural endpoint / redirect helpers ---------------------------------

@test "link_endpoints_match_native rejects the /oauth/jwks 301 trap" {
  source "$LINK_SH"
  run link_endpoints_match_native "/oauth/authorize" "/oauth/token" "/oauth/userinfo" "/oauth/jwks"
  [ "$status" -ne 0 ]
  run link_endpoints_match_native "/oauth/authorize" "/oauth/token" "/oauth/userinfo" "/.well-known/jwks.json"
  [ "$status" -eq 0 ]
}

@test "link_redirect_ok requires the exact Moodle callback URL" {
  source "$LINK_SH"
  run link_redirect_ok "https://ssc.nwpcode.org/admin/oauth2callback.php" "https://ssc.nwpcode.org"
  [ "$status" -eq 0 ]
  run link_redirect_ok "https://evil.example/admin/oauth2callback.php" "https://ssc.nwpcode.org"
  [ "$status" -ne 0 ]
}

# --- no secret leak ---------------------------------------------------------

@test "link_probe_authed never prints the token (tokenless-read discipline)" {
  source "$LINK_SH"
  local sf="${TEST_TMP}/secrets.yml"
  printf 'test:\n  tok: SENTINEL_TOKEN_9f3\n' > "$sf"
  export NWP_SECRETS_FILE="$sf"
  # Point at a closed port so curl fails fast; the value must be read but never echoed.
  run link_probe_authed "http://127.0.0.1:9/none" "POST" "X-Cross-Site-Token" "test.tok" "x=1"
  [[ "$output" != *"SENTINEL_TOKEN_9f3"* ]]
  unset NWP_SECRETS_FILE
}

@test "a full verify run does not emit any secret value" {
  local sf="${TEST_TMP}/secrets.yml"
  printf 'link:\n  ssc:\n    stg:\n      admin_token: SENTINEL_ADMIN_7\n      bearer_token: SENTINEL_BEARER_7\n' > "$sf"
  export NWP_SECRETS_FILE="$sf"
  run bash "$LINK_SH" verify ssd --tier=stg --round-trip \
      --provider-base=http://127.0.0.1:9 --consumer-base=http://127.0.0.1:9
  [[ "$output" != *"SENTINEL_ADMIN_7"* ]]
  [[ "$output" != *"SENTINEL_BEARER_7"* ]]
  unset NWP_SECRETS_FILE
}
