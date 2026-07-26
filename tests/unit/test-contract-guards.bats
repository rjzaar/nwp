#!/usr/bin/env bats
# =============================================================================
# tests/unit/test-contract-guards.bats — `pl contracts guards` (ops#138 / item 5)
# =============================================================================
# ops#138: the Drupal-side Art.9 hard write-gate (`Art9ConsentGate::
# assertMayWriteArt9()` / `writeFormation()`) has ZERO production call sites.
# Re-verified 2026-07-26 against sites/nwc/dev: every reference outside the
# defining file is a doc comment, a @deprecated note, an exception docblock —
# or a string in `nwc_privacy/tests/src/PrivacySweep.php:83`, a sweep that
# greps for the NAME and reports the control present. A capability nothing
# calls is not a control, and the sweep that "verified" it is the exact
# vacuous-pass shape this programme exists to remove.
#
# This gate answers the only question that matters about a declared guard:
# does anything CALL it? Not "is the string present" — `->guard(`, `::guard(`
# or `guard(` in executable position, with comment lines and the guard's own
# defining file excluded.
#
# Shipped as a SEPARATE verb rather than folded into `pl contracts crossref`
# on purpose: crossref is a blocking pre-flight inside `pl pair-smoke`, and
# ops#138 is red on the real estate today. Turning a true, known, operator-owned
# finding into a surprise promotion block is a different decision from making it
# visible, and only the second one is an agent's to take.
#
# Self-contained fixtures; no network, no live site.
# =============================================================================

CONTRACTS_SH="${BATS_TEST_DIRNAME}/../../scripts/commands/contracts.sh"

setup() {
  TMP="$(mktemp -d)"
  export PROJECT_ROOT="${TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}/pairs"
  export NWP_PAIR_CONTRACT_DIR="${PROJECT_ROOT}/pairs"

  SRC="${PROJECT_ROOT}/sites/prov/dev/html/profiles/custom/prov"
  mkdir -p "${SRC}/src/Service" "${SRC}/src/Controller" "${SRC}/tests/src"

  # The guard itself — declared, documented, and (so far) never called.
  cat > "${SRC}/src/Service/Art9ConsentGate.php" <<'PHP'
<?php
/**
 * The Art.9 hard write-gate. Callers MUST call assertMayWriteArt9() first.
 */
class Art9ConsentGate {
  public function assertMayWriteArt9(int $uid): void {
    // throws when consent is absent
  }
}
PHP

  # A sweep that greps for the NAME and calls the control present — the
  # vacuous pass ops#138 hid behind.
  cat > "${SRC}/tests/src/PrivacySweep.php" <<'PHP'
<?php
$controls = [
  'assertMayWriteArt9' => 'Drupal Art. 9 hard write-gate (README §B)',
];
PHP

  cat > "${PROJECT_ROOT}/pairs/cons.pair-contract.yml" <<'YML'
pair: cons-prov
contract_version: 2
provider: prov
consumer: cons
crossref:
  provider_roots:
    - "sites/prov/dev/html/profiles/custom/prov"
  consumer_roots:
    - "sites/cons/.plugin-src/plugins"
guards:
  - symbol: assertMayWriteArt9
    side: provider
    why: "Art.9 hard write-gate (ops#138)"
    defined_in: "src/Service/Art9ConsentGate.php"
YML
  mkdir -p "${PROJECT_ROOT}/sites/cons/.plugin-src/plugins"
}

teardown() { rm -rf "${TMP}"; }

_add_real_caller() {
  cat > "${SRC}/src/Controller/FormationController.php" <<'PHP'
<?php
class FormationController {
  public function save($uid, $value) {
    $this->gate->assertMayWriteArt9($uid);
    return $this->store->write($uid, $value);
  }
}
PHP
}

@test "contracts guards: a declared guard with ZERO call sites is UNCALLED-GUARD" {
  run bash "$CONTRACTS_SH" guards cons
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNCALLED-GUARD"* ]]
  [[ "$output" == *"assertMayWriteArt9"* ]]
}

@test "contracts guards: a NAME-only mention in a sweep list is not a call site" {
  # PrivacySweep.php mentions the symbol as an array key. If that counted, the
  # gate would be green today and ops#138 would still be invisible.
  run bash "$CONTRACTS_SH" guards cons
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNCALLED-GUARD"* ]]
}

@test "contracts guards: a COMMENTED-OUT call is not a call site" {
  cat > "${SRC}/src/Controller/Commented.php" <<'PHP'
<?php
class Commented {
  public function save($uid) {
    // $this->gate->assertMayWriteArt9($uid);
    # $this->gate->assertMayWriteArt9($uid);
    /* $this->gate->assertMayWriteArt9($uid); */
    return TRUE;
  }
}
PHP
  run bash "$CONTRACTS_SH" guards cons
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNCALLED-GUARD"* ]]
}

@test "contracts guards: a MULTI-LINE docblock mention is not a call site" {
  # Caught by running the gate against the real nwc tree: the first
  # implementation stripped //, # and single-line /* */ but not a /** */
  # docblock, so this exact file (nwc_privacy Art9ConsentRequiredException.php)
  # made the ops#138 guard report ADOPTED. A gate that goes green on a comment
  # is the failure it was written to detect.
  cat > "${SRC}/src/Service/Art9ConsentRequiredException.php" <<'PHP'
<?php
/**
 * Thrown by the write gate. Callers should call
 * Art9ConsentGate::assertMayWriteArt9($uid) first; this exception is the
 * hard stop when they did not.
 */
class Art9ConsentRequiredException extends \RuntimeException {}
PHP
  run bash "$CONTRACTS_SH" guards cons
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNCALLED-GUARD"* ]]
}

@test "contracts guards: the defining file is excluded under EVERY root, not just the first" {
  # dev/ and stg/ are both declared provider roots and both hold the definition.
  # Excluding only the first-matching root let the stg copy of the guard's own
  # definition count as a call site.
  SRC2="${PROJECT_ROOT}/sites/prov/stg/html/profiles/custom/prov"
  mkdir -p "${SRC2}/src/Service"
  cp "${SRC}/src/Service/Art9ConsentGate.php" "${SRC2}/src/Service/Art9ConsentGate.php"
  cat >> "${SRC2}/src/Service/Art9ConsentGate.php" <<'PHP'
<?php
class SelfRef { public function x($uid) { $this->assertMayWriteArt9($uid); } }
PHP
  python3 - "$PROJECT_ROOT/pairs/cons.pair-contract.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace(
    '    - "sites/prov/dev/html/profiles/custom/prov"\n',
    '    - "sites/prov/dev/html/profiles/custom/prov"\n    - "sites/prov/stg/html/profiles/custom/prov"\n')
open(p, 'w').write(s)
PY
  run bash "$CONTRACTS_SH" guards cons
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNCALLED-GUARD"* ]]
}

@test "contracts guards: the reported call-site count matches the listed files" {
  # A single call site was reported as "0 call site(s)" (wc -l on output with no
  # trailing newline). A gate whose own arithmetic is wrong teaches people to
  # skim it.
  _add_real_caller
  run bash "$CONTRACTS_SH" guards cons
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 call site(s)"* ]]
  [[ "$output" != *"0 call site(s)"* ]]
}

@test "contracts guards: a real call site makes the guard adopted" {
  _add_real_caller
  run bash "$CONTRACTS_SH" guards cons
  [ "$status" -eq 0 ]
  [[ "$output" == *"adopted"* ]]
  [[ "$output" == *"FormationController.php"* ]]
}

@test "contracts guards: the guard's own defining file never counts as adoption" {
  # Give the definition a self-reference; it must not satisfy the gate.
  cat >> "${SRC}/src/Service/Art9ConsentGate.php" <<'PHP'
<?php
class Helper { public function x($uid) { $this->assertMayWriteArt9($uid); } }
PHP
  run bash "$CONTRACTS_SH" guards cons
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNCALLED-GUARD"* ]]
}

@test "contracts guards: an absent provider root is CANNOT-VERIFY, not clean" {
  rm -rf "${PROJECT_ROOT}/sites/prov"
  run bash "$CONTRACTS_SH" guards cons
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "contracts guards: a contract with no guards: block reports NONE-DECLARED, not OK" {
  sed -i '/^guards:/,$d' "${PROJECT_ROOT}/pairs/cons.pair-contract.yml"
  run bash "$CONTRACTS_SH" guards cons
  [ "$status" -eq 0 ]
  [[ "$output" == *"NONE-DECLARED"* ]]
  [[ "$output" != *"adopted"* ]]
}

@test "contracts guards: an unknown pair fails closed" {
  run bash "$CONTRACTS_SH" guards nosuchpair
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}
