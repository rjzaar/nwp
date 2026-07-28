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

  # --- fixture MOODLE CORE tree (ops#152) ----------------------------------
  # Until ops#152 the gate scanned ONLY the plugin tree above, so nothing
  # planted in core could ever go red. Core is now a declared, scanned root.
  # The default fixture core is BENIGN and mirrors the real shape: core's
  # oauth2 client fetches userinfo and never parses an id_token signature.
  CORE_REL="sites/cons/dev"
  CORE="${PROJECT_ROOT}/${CORE_REL}"
  mkdir -p "${CORE}/lib/classes/oauth2"
  cat > "${CORE}/lib/classes/oauth2/client.php" <<'PHP'
<?php
// Core auth_oauth2: claims come from the USERINFO endpoint, not the id_token.
class client extends \oauth2_client {
    public function get_userinfo() {
        return $this->get($this->get_issuer()->get_endpoint_url('userinfo'));
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
# ops#152: `core` (arg 11) is the consumer_core_roots BLOCK BODY, so a test can
# omit the key entirely ("") or declare a root that does not exist.
write_contract() {
  local verifies="${1:-false}" mode="${2:-hard_swap}" kid="${3:-false}" \
        overlap="${4:-false}" announce="${5:-0}" window="${6:-0}" \
        retire="${7:-0}" refetch="${8:-null}" exempt="${9:-[]}" \
        runbook="${10:-docs/guides/ops82-key-rotation.md}" \
        core="${11-      - \"${CORE_REL}\"}"   # `-` not `:-`: "" means "omit the key"
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
    consumer_core_roots:
${core}
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

# =============================================================================
# ops#152 — the scanned corpus was the CUSTOM PLUGIN TREES ONLY.
#
# `crossref.consumer_roots` names ~105 PHP files. The claim under test —
# "the consumer does not verify the id_token signature" — is a claim about the
# CONSUMER, and the consumer is Moodle: core (~16,500 PHP files) plus plugins.
# Scanning the plugins and printing OK was fail-open, and it was fail-open at
# the worst possible spot: JWT verification planted at
# `sites/ssc/dev/lib/classes/oauth2/client.php` — the very file the contract's
# comment cited as hand-verified — did NOT trip CLAIM-DRIFT.
#
# Every test below was watched RED against the pre-fix gate.
# =============================================================================

# Write a file into the fixture CORE tree.
_core_file() { # <core-relative path> <heredoc body on stdin>
  local p="${CORE}/$1"
  mkdir -p "$(dirname "$p")"
  cat > "$p"
}

# The legitimate LTI 1.3 JWS path, as it exists in every real Moodle. This code
# genuinely verifies JWS signatures — against LTI *platform* keys, a different
# issuer with its own JWKS and its own rotation story. Nothing here reads an
# nwc token.
_plant_lti() {
  _core_file lib/lti1p3/src/LtiMessageLaunch.php <<'PHP'
<?php
class LtiMessageLaunch {
    public function validateJwtSignature() {
        return JWT::decode($this->request['id_token'], $this->getPublicKey(), ['RS256']);
    }
}
PHP
  _core_file enrol/lti/jwks.php <<'PHP'
<?php
$jwks = JwksEndpoint::new()->getPublicJwks();
openssl_verify($payload, $sig, $pub);
PHP
  _core_file mod/lti/token.php <<'PHP'
<?php
$claims = JWT::decode($assertion, jwks_helper::get_jwks(), ['RS256']);
PHP
}

_lti_exemptions='["lib/lti1p3/**", "enrol/lti/**", "mod/lti/**"]'

# --- THE POSITIVE CONTROL ----------------------------------------------------
# A gate that greps the wrong tree passes forever. This is the test that proves
# the corpus is the right one.

@test "ops#152 POSITIVE CONTROL: JWT verification planted in Moodle CORE trips CLAIM-DRIFT" {
  write_contract
  # The exact file the ssc contract's comment cites as hand-verified.
  _core_file lib/classes/oauth2/client.php <<'PHP'
<?php
class client extends \oauth2_client {
    public function verify_id_token($idtoken, $issuer) {
        $keys = \Firebase\JWT\JWT::parseKeySet($this->fetch_jwks($issuer));
        $claims = \Firebase\JWT\JWT::decode($idtoken, $keys, ['RS256']);
        if (!openssl_verify($idtoken, $sig, $pub, OPENSSL_ALGO_SHA256)) {
            throw new \moodle_exception('badsignature');
        }
        return $claims;
    }
}
PHP
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLAIM-DRIFT"* ]]
  # The offending path is NAMED, so a human can adjudicate it.
  [[ "$output" == *"lib/classes/oauth2/client.php"* ]]
}

@test "ops#152 POSITIVE CONTROL: verification planted anywhere else in core also trips" {
  # Directory-level, not a list of today's filenames — the same fail-closed
  # reasoning the agent-loop gate uses for scripts/console/app/.
  write_contract
  _core_file login/token_helper.php <<'PHP'
<?php
function nwc_check($t) { return \Firebase\JWT\JWT::decode($t, $k, ['RS256']); }
PHP
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLAIM-DRIFT"* ]]
  [[ "$output" == *"login/token_helper.php"* ]]
}

# --- the LTI exemption -------------------------------------------------------

@test "ops#152: the LTI 1.3 JWS paths do NOT trip the gate when declared exempt" {
  write_contract false hard_swap false false 0 0 0 null "$_lti_exemptions"
  _plant_lti
  run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"no executable signature/JWKS code"* ]]
}

@test "ops#152: the LTI paths DO trip when NOT exempt (the waiver is doing the work, not blindness)" {
  # Without this, the test above would pass on a gate that simply cannot see
  # lib/lti1p3 at all — which is exactly the bug being fixed, wearing a
  # different hat.
  write_contract
  _plant_lti
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLAIM-DRIFT"* ]]
  [[ "$output" == *"LtiMessageLaunch.php"* ]]
}

@test "ops#152: an exemption is a GLOB and is anchored at the scanned root, not just PROJECT_ROOT" {
  # `mod/lti/**` must waive sites/cons/dev/mod/lti/token.php — the waiver is a
  # property of Moodle, so it is written the way Moodle names its paths and
  # does not have to repeat wherever an estate mounts the core tree.
  write_contract false hard_swap false false 0 0 0 null '["mod/lti/**"]'
  _core_file mod/lti/token.php <<'PHP'
<?php
$claims = JWT::decode($assertion, jwks_helper::get_jwks(), ['RS256']);
PHP
  run_gate
  [ "$status" -eq 0 ]
}

@test "ops#152: a PROJECT_ROOT-anchored exact path still waives (backward compatible)" {
  # The pre-ops#152 semantics were `grep -qxF` on the PROJECT_ROOT-relative
  # path. Entries written that way must keep working.
  write_contract false hard_swap false false 0 0 0 null \
    "[\"${CORE_REL}/mod/lti/token.php\"]"
  _core_file mod/lti/token.php <<'PHP'
<?php
$claims = JWT::decode($assertion, jwks_helper::get_jwks(), ['RS256']);
PHP
  run_gate
  [ "$status" -eq 0 ]
}

# --- fail-closed on an undeclared / absent core tree -------------------------

@test "ops#152 CANNOT-VERIFY: a contract that does not declare consumer_core_roots is not a pass" {
  # A gate that silently narrows its own corpus is how the hand verification
  # became folklore. If the contract will not say where core is, the claim
  # cannot be checked.
  write_contract false hard_swap false false 0 0 0 null '[]' \
    docs/guides/ops82-key-rotation.md ''
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
  [[ "$output" == *"consumer_core_roots"* ]]
}

@test "ops#152 CANNOT-VERIFY: a declared-but-absent core tree is not a silent green" {
  write_contract false hard_swap false false 0 0 0 null '[]' \
    docs/guides/ops82-key-rotation.md '      - "sites/cons/nope"'
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
  [[ "$output" == *"sites/cons/nope"* ]]
}

@test "ops#152 CANNOT-VERIFY: a core root that EXISTS but holds no PHP is a vacuous corpus, not a pass" {
  # The [ -d ] existence check cannot distinguish a real checkout from an empty
  # mount point (or a tree this user cannot read — find reports nothing either
  # way). "No hits across zero files" must refuse, not go green.
  write_contract false hard_swap false false 0 0 0 null '[]' \
    docs/guides/ops82-key-rotation.md '      - "sites/cons/hollow"'
  mkdir -p "${PROJECT_ROOT}/sites/cons/hollow/lib"   # exists, zero PHP files
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
  [[ "$output" == *"no PHP files"* ]]
  [[ "$output" == *"sites/cons/hollow"* ]]
}

# --- the comment-stripper false negative -------------------------------------
#
# `_guards_strip_comments` treated `//` and `#` inside a STRING LITERAL as
# comment openers, so
#     $u = "https://nwc.example.org/.well-known/jwks.json";
# became
#     $u = "https:
# and the `jwks` token was destroyed BEFORE the grep ran. A fail-closed gate
# that deletes its own evidence is worse than one that merely misses it.

@test "ops#152 STRIPPER: a JWKS URL inside a string literal is SEEN, not eaten by '//'" {
  write_contract
  _core_file lib/classes/oauth2/urls.php <<'PHP'
<?php
class urls {
    public function endpoint() {
        return "https://nwc.example.org/.well-known/jwks.json";
    }
}
PHP
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLAIM-DRIFT"* ]]
  [[ "$output" == *"jwks.json"* ]]
}

@test "ops#152 STRIPPER: a '#' inside a string literal does not truncate the line either" {
  write_contract
  _core_file lib/classes/oauth2/frag.php <<'PHP'
<?php
$anchor = "#jwks";
$x = 1;
PHP
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLAIM-DRIFT"* ]]
}

@test "ops#152 STRIPPER NEGATIVE CONTROL: real // and # and /* */ comments are STILL stripped" {
  # The whole value of the stripper is that a trust-model comment naming jwks
  # does not spam the gate. Widening it to respect strings must not turn every
  # comment back into a finding — otherwise the gate is unusable noise and
  # someone will disable it.
  write_contract
  _core_file lib/classes/oauth2/notes.php <<'PHP'
<?php
// If we ever call JWT::decode() here, openssl_verify() would follow.
# A hash-style comment naming jwks and id_token too.
/* A block comment
   spanning lines and naming jwks, id_token and validateSignature. */
class notes {}
PHP
  run_gate
  [ "$status" -eq 0 ]
}

@test "ops#152 STRIPPER: an escaped quote inside a string does not desynchronise the scanner" {
  # $s = 'it\'s'; must not leave the scanner believing it is still in a string,
  # which would swallow the rest of the line and hide real code.
  write_contract
  _core_file lib/classes/oauth2/esc.php <<'PHP'
<?php
$s = 'it\'s fine';
$t = JWT::decode($x, $k, ['RS256']);
PHP
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLAIM-DRIFT"* ]]
  [[ "$output" == *"JWT::decode"* ]]
}

# --- performance -------------------------------------------------------------

@test "ops#152 PERFORMANCE: a wide core tree stays well under a 60s budget" {
  # Measured on the REAL ssc tree (16,517 core PHP/inc files): the grep -rlE
  # prefilter costs ~0.5s and narrows to ~80 candidates; only those are
  # comment-stripped. `key-rotation --all` over BOTH real pairs = 5.9s.
  # This test pins the shape rather than the machine: 2,000 synthetic core
  # files must not push one pair anywhere near the budget.
  write_contract
  local i
  mkdir -p "${CORE}/local/bulk"
  for i in $(seq 1 2000); do
    printf '<?php\nclass bulk%s { public function run() { return %s; } }\n' "$i" "$i" \
      > "${CORE}/local/bulk/f${i}.php"
  done
  local start end
  start="$(date +%s)"
  run_gate
  end="$(date +%s)"
  [ "$status" -eq 0 ]
  [ "$((end - start))" -lt 60 ]
}
