#!/usr/bin/env bats
# =============================================================================
# tests/unit/test-oidc-key-rotation.bats — ops#82 `pl contracts key-rotation`
# =============================================================================
# The nwc→ssc key-rotation runbook says a signing-key swap is safe. It is safe
# for exactly one reason: the Moodle consumer never verifies the id_token
# signature, so nothing it holds can be invalidated by a new key. Every leg of
# that argument lived in PROSE only — a comment in auth.php, a paragraph in the
# runbook, a `false` in the pair contract. Nothing failed when the code drifted
# out from under the prose, and the day a consumer starts verifying signatures
# the documented hard swap becomes a full SSO outage, silently.
#
# `pl contracts key-rotation` couples claim to code, fail-closed:
#
#     verifies=false → consumer tree must contain NO executable signature/JWKS
#                      code                                    (CLAIM-DRIFT)
#     verifies=true  → issuer must publish overlapping keys, tokens must carry
#                      a kid, announce/overlap/retire must be real durations,
#                      and a refetch-on-unknown-kid impl must exist
#                                              (OVERLAP-REQUIRED / NO-REFETCH)
#
# so the unsafe middle state — a verifying consumer on a single-key hard swap —
# is unreachable. Every case below was observed RED against a gate stubbed to
# `return 0` before the implementation landed.
#
# Self-contained fixtures; no network, no secrets, no live site, no Moodle.
# =============================================================================

CONTRACTS_SH="${BATS_TEST_DIRNAME}/../../scripts/commands/contracts.sh"

setup() {
  TMP="$(mktemp -d)"
  export PROJECT_ROOT="${TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}/pairs" "${PROJECT_ROOT}/docs/guides"
  export NWP_PAIR_CONTRACT_DIR="${PROJECT_ROOT}/pairs"

  # The runbook the contract points at must exist (a clause pointing at a
  # missing document is folklore).
  : > "${PROJECT_ROOT}/docs/guides/ops82-key-rotation.md"

  # --- fixture CONSUMER tree (the Moodle plugin repo checkout) --------------
  CONS_REL="sites/cons/.plugin-src/moodle-plugins"
  CONS="${PROJECT_ROOT}/${CONS_REL}"
  mkdir -p "${CONS}/auth/nwc/classes"

  # The real auth_nwc shape: JWKS/JWT appear ONLY in trust-model comments.
  # This must NOT trip the gate, or the gate is useless noise.
  cat > "${CONS}/auth/nwc/auth.php" <<'PHP'
<?php
// TRUST MODEL (ops#82): Moodle core auth_oauth2 does NOT verify the id_token
// RS256 signature against nwc's JWKS — it runs authorization-code + PKCE and
// reads claims from /oauth/userinfo. Trust = TLS + confidential client + PKCE.
/* A block comment mentioning jwks and JWT::decode must also be ignored. */
class auth_plugin_nwc {
    public function resolve_and_lock(array $claims) {
        return $claims['sub'] ?? '';
    }
}
PHP
}

teardown() {
  rm -rf "${TMP}"
  unset PROJECT_ROOT NWP_PAIR_CONTRACT_DIR
}

# Emit a pair contract. All fields overridable via env-style args:
#   write_contract [verifies] [mode] [kid] [overlap] [announce] [window] [retire] [refetch] [exempt] [runbook]
write_contract() {
  local verifies="${1:-false}" mode="${2:-hard_swap}" kid="${3:-false}" \
        overlap="${4:-false}" announce="${5:-0}" window="${6:-0}" \
        retire="${7:-0}" refetch="${8:-null}" exempt="${9:-[]}" \
        runbook="${10:-docs/guides/ops82-key-rotation.md}"
  cat > "${PROJECT_ROOT}/pairs/cons.pair-contract.yml" <<YML
pair: cons-prov
contract_version: 2
provider: prov
consumer: cons
oidc:
  issuer_name: "prov (F26)"
  key_rotation:
    consumer_verifies_signature: ${verifies}
    jwks_uri: "https://prov.<example-prod-domain>/.well-known/jwks.json"
    tokens_carry_kid: ${kid}
    provider_supports_overlap: ${overlap}
    mode: ${mode}
    cadence: annual
    announce_window: ${announce}
    overlap_window: ${window}
    retire_after: ${retire}
    refetch_impl: ${refetch}
    verification_exempt_paths: ${exempt}
    runbook: "${runbook}"
crossref:
  provider_roots:
    - "sites/prov"
  consumer_roots:
    - "${CONS_REL}"
YML
}

run_gate() { run bash "$CONTRACTS_SH" key-rotation cons; }

# --- the honest baseline -----------------------------------------------------

@test "hard_swap + non-verifying consumer + comment-only JWKS mentions: PASSES" {
  write_contract
  run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"no executable signature/JWKS code"* ]]
}

@test "comments are stripped: JWT::decode inside a comment does NOT trip the gate" {
  write_contract
  cat > "${CONS}/auth/nwc/classes/notes.php" <<'PHP'
<?php
// If we ever call JWT::decode() here, openssl_verify() would follow.
# And a hash-style comment naming jwks and id_token too.
class notes {}
PHP
  run_gate
  [ "$status" -eq 0 ]
}

# --- the drift check: the outage this whole issue exists to prevent ----------

@test "CLAIM-DRIFT: contract says verifies=false but the consumer really verifies" {
  write_contract
  cat > "${CONS}/auth/nwc/classes/verifier.php" <<'PHP'
<?php
class verifier {
    public function check($token, $keys) {
        return JWT::decode($token, $keys);
    }
}
PHP
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLAIM-DRIFT"* ]]
  [[ "$output" == *"verifier.php"* ]]
  # It must say WHY this matters, not just that a pattern matched.
  [[ "$output" == *"OUTAGE"* ]]
}

@test "CLAIM-DRIFT is waivable by an explicit, reviewable exemption" {
  write_contract false hard_swap false false 0 0 0 null \
    "[\"${CONS_REL}/auth/nwc/classes/verifier.php\"]"
  cat > "${CONS}/auth/nwc/classes/verifier.php" <<'PHP'
<?php
class verifier { public function check($t, $k) { return JWT::decode($t, $k); } }
PHP
  run_gate
  [ "$status" -eq 0 ]
}

# --- flipping verification on drags every overlap obligation with it ---------

@test "OVERLAP-REQUIRED: verifies=true on a single-key issuer is refused" {
  # The unsafe middle state: someone turns on verification and leaves the rest.
  write_contract true overlap false false 0 0 0 null
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"OVERLAP-REQUIRED"* ]]
  [[ "$output" == *"provider_supports_overlap"* ]]
}

@test "OVERLAP-REQUIRED: a verifier with no kid cannot select a key mid-overlap" {
  write_contract true overlap false true 7d 14d 30d "lib/jwks_cache.php"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"tokens_carry_kid"* ]]
}

@test "OVERLAP-REQUIRED: announce/overlap/retire may not stay zero once verifying" {
  write_contract true overlap true true 0 0 0 "lib/jwks_cache.php"
  : > "${PROJECT_ROOT}/lib_placeholder"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"announce_window"* ]]
  [[ "$output" == *"overlap_window"* ]]
  [[ "$output" == *"retire_after"* ]]
}

@test "NO-REFETCH: a verifying consumer must name a refetch-on-unknown-kid impl" {
  write_contract true overlap true true 7d 14d 30d "lib/does_not_exist.php"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"NO-REFETCH"* ]]
  [[ "$output" == *"unknown kid"* ]]
}

@test "a fully equipped overlap contract PASSES" {
  mkdir -p "${PROJECT_ROOT}/lib"
  : > "${PROJECT_ROOT}/lib/jwks_cache.php"
  write_contract true overlap true true 7d 14d 30d "lib/jwks_cache.php" \
    "[\"${CONS_REL}/auth/nwc/auth.php\"]"
  run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"overlap obligations satisfied"* ]]
}

@test "MODE-MISMATCH: overlap ceremony with nobody verifying is refused" {
  write_contract false overlap false false 0 0 0 null
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"MODE-MISMATCH"* ]]
}

# --- fail-closed: "I could not look" is never "all fine" --------------------

@test "CANNOT-VERIFY: a contract with no key_rotation clause is not a pass" {
  cat > "${PROJECT_ROOT}/pairs/cons.pair-contract.yml" <<'YML'
pair: cons-prov
contract_version: 2
provider: prov
consumer: cons
oidc:
  issuer_name: "prov (F26)"
crossref:
  consumer_roots:
    - "sites/cons/.plugin-src/moodle-plugins"
YML
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
  [[ "$output" == *"unwritten outage"* ]]
}

@test "CANNOT-VERIFY: an absent consumer checkout is not a silent green" {
  write_contract
  rm -rf "${PROJECT_ROOT}/sites/cons"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
  [[ "$output" == *"Absence of evidence is not a pass"* ]]
}

@test "CANNOT-VERIFY: the load-bearing fact may not be left implicit" {
  write_contract '"maybe"'
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
  [[ "$output" == *"load-bearing"* ]]
}

@test "MISSING-RUNBOOK: a clause pointing at a missing document fails" {
  write_contract false hard_swap false false 0 0 0 null "[]" "docs/guides/gone.md"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING-RUNBOOK"* ]]
}

# --- the real contracts in this repo ----------------------------------------

@test "the shipped ssc + ssd contracts satisfy the invariant" {
  unset NWP_PAIR_CONTRACT_DIR
  local repo; repo="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  # The consumer checkouts live in the working tree, not the git worktree, so
  # this asserts only when they are present — and says so when they are not.
  PROJECT_ROOT="$repo" run bash "$CONTRACTS_SH" key-rotation --all
  if [[ "$output" == *"CANNOT-VERIFY"* ]]; then
    skip "consumer checkout absent in this tree (gate correctly refused to pass)"
  fi
  [ "$status" -eq 0 ]
}
