#!/usr/bin/env bats
#
# ops#236 — `pl audit` could certify a site CLEAN while vulnerable code sat on
# disk, because `composer audit --locked` reads composer.lock and the code that
# executes is vendor/.
#
# WHAT HAPPENED, 2026-08-02, during the guzzle remediation (ops#231). nwc's
# html/core was a dirty SOURCE install. composer refused to replace it, ABORTED
# mid-operation, and left composer.lock recording guzzle 7.15.2 while vendor/
# still held the vulnerable 7.12.3. `pl audit` would have read the lock and
# reported nwc clean while the vulnerable library was the running code.
#
# THE SHAPE. Not a missing check — a PASSING check over the WRONG ARTIFACT. Same
# family as the max_input_vars remedy applied to a SAPI Moodle never uses, and
# the stick backup that faithfully captured the wrong host. A red result gets
# investigated; a green one ends the conversation. And it matters more now: an
# auto-fix loop consuming this signal would close security findings on sites
# still running vulnerable code.
#
# The nwc incident has since been remediated, so the live tree AGREES today —
# which is exactly why the reproduction lives in a fixture rather than in a
# pointer at a site. Measured on the real fleet while writing this (read-only):
# 13 Drupal trees agree; the four Moodle sites have a lock and no vendor/ and
# never reach this code path (audit_site routes `type: moodle` to
# moodle_audit_site first — asserted below so that stays true).
#
# Per ops#214 every case is proven to discriminate: the divergence fixture must
# go RED, and an agreeing fixture must stay GREEN, or the check is decoration.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  source "$ROOT/lib/composer-truth.sh"
  T="$BATS_TEST_TMPDIR/ct"
  mkdir -p "$T/vendor/composer"
  LOCK="$T/composer.lock"
  INST="$T/vendor/composer/installed.json"
}

_lock() { cat > "$LOCK"; }
_inst() { cat > "$INST"; }

_agree() {
  _lock <<'J'
{"packages":[{"name":"guzzlehttp/guzzle","version":"7.15.2"},
             {"name":"drupal/core","version":"10.3.1"}],
 "packages-dev":[{"name":"phpunit/phpunit","version":"10.5.0"}]}
J
  _inst <<'J'
{"packages":[{"name":"guzzlehttp/guzzle","version":"7.15.2"},
             {"name":"drupal/core","version":"10.3.1"},
             {"name":"phpunit/phpunit","version":"10.5.0"}]}
J
}

################################################################################
# THE INCIDENT, reproduced.
################################################################################

@test "THE nwc CASE: lock says guzzle 7.15.2, vendor still holds 7.12.3 -> DIVERGES" {
  _agree
  python3 - "$INST" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["packages"][0]["version"]="7.12.3"
json.dump(d, open(p,"w"))
PY
  run composer_truth_compare "$LOCK" "$INST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VERSION"* ]]
  [[ "$output" == *"guzzlehttp/guzzle"* ]]
  [[ "$output" == *"lock=7.15.2"* ]]
  [[ "$output" == *"vendor=7.12.3"* ]]
}

@test "NEGATIVE CONTROL: an agreeing tree is clean and SILENT" {
  # Without this the case above is satisfied by a comparator that always
  # diverges, which would turn every site red and teach people to ignore it.
  _agree
  run composer_truth_compare "$LOCK" "$INST"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

################################################################################
# The other two ways lock and vendor disagree.
################################################################################

@test "a package in the lock but ABSENT from vendor is a finding" {
  _agree
  python3 - "$INST" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["packages"]=[x for x in d["packages"] if x["name"]!="drupal/core"]
json.dump(d, open(p,"w"))
PY
  run composer_truth_compare "$LOCK" "$INST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING"* ]]
  [[ "$output" == *"drupal/core"* ]]
}

@test "a package in vendor that the lock does not know about is a finding" {
  # Hand-edited vendor/, or a half-finished removal. Either way the running code
  # is not the declared code.
  _agree
  python3 - "$INST" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["packages"].append({"name":"evil/backdoor","version":"1.0.0"})
json.dump(d, open(p,"w"))
PY
  run composer_truth_compare "$LOCK" "$INST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"EXTRA"* ]]
  [[ "$output" == *"evil/backdoor"* ]]
}

@test "packages-dev is compared too — a dev tool is still executing code" {
  _agree
  python3 - "$INST" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
for x in d["packages"]:
    if x["name"]=="phpunit/phpunit": x["version"]="9.0.0"
json.dump(d, open(p,"w"))
PY
  run composer_truth_compare "$LOCK" "$INST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"phpunit/phpunit"* ]]
}

################################################################################
# CANNOT VERIFY is its own answer. Three answers, never two.
################################################################################

@test "a missing vendor tree is rc 2 CANNOT VERIFY — never rc 0" {
  _agree
  rm -f "$INST"
  run composer_truth_compare "$LOCK" "$INST"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
  [[ "$output" == *"NOT 'nothing wrong'"* ]]
}

@test "a missing lock is rc 2 CANNOT VERIFY" {
  _agree
  rm -f "$LOCK"
  run composer_truth_compare "$LOCK" "$INST"
  [ "$status" -eq 2 ]
}

@test "UNPARSEABLE json is rc 2, not a crash and not a pass" {
  _agree
  printf 'not json at all' > "$INST"
  run composer_truth_compare "$LOCK" "$INST"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "composer 1.x installed.json (a bare list) is understood, not misread as empty" {
  # A bare list read as "no packages installed" would report every locked
  # package MISSING — a wall of false findings, which is its own way of making
  # the check useless.
  _agree
  python3 - "$INST" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
json.dump(d["packages"], open(p,"w"))     # composer 1.x shape
PY
  run composer_truth_compare "$LOCK" "$INST"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "composer_truth_paths gives the standard layout" {
  run composer_truth_paths /some/root
  [ "$output" = "/some/root/composer.lock /some/root/vendor/composer/installed.json" ]
}

################################################################################
# The audit command actually uses it, and grades on it.
################################################################################

@test "pl audit sources the truth lib and calls the comparator" {
  A="$ROOT/scripts/commands/audit.sh"
  run grep -c 'composer-truth.sh' "$A";        [ "$output" -ge 1 ]
  run grep -c 'composer_truth_compare' "$A";   [ "$output" -ge 1 ]
}

@test "a DIVERGED site sets the fleet security exit, like an advisory does" {
  # The advisory count above a divergence was computed about a tree that is not
  # the one on disk, so a clean count means nothing. It must not exit 0.
  A="$ROOT/scripts/commands/audit.sh"
  run grep -c 'vendor_state" = "DIVERGES" \] && had_sec=1' "$A"
  [ "$output" -ge 1 ]
}

@test "'unverified' is recorded as NOT SCANNED, not as clean" {
  A="$ROOT/scripts/commands/audit.sh"
  run grep -c 'vendor_state != "unverified"' "$A"
  [ "$output" -ge 1 ]
}

@test "the per-site record carries vendor_state and the divergence text" {
  A="$ROOT/scripts/commands/audit.sh"
  run grep -c '"vendor_state": vendor_state' "$A";       [ "$output" -ge 1 ]
  run grep -c '"vendor_divergence_text"' "$A";           [ "$output" -ge 1 ]
}

@test "Moodle sites never reach this path — they have a lock and no vendor tree" {
  # Measured on the real fleet: ss/ss2/ssc/ssd each carry a composer.lock with no
  # vendor/composer/installed.json, so if audit_site did not route them away
  # first they would all report 'unverified' forever and the signal would be
  # noise. audit_site checks _site_is_moodle BEFORE resolving the webroot.
  A="$ROOT/scripts/commands/audit.sh"
  moodle_line=$(grep -n '_site_is_moodle "$site"' "$A" | head -1 | cut -d: -f1)
  truth_line=$(grep -n 'composer_truth_compare' "$A" | head -1 | cut -d: -f1)
  [ -n "$moodle_line" ] && [ -n "$truth_line" ]
  [ "$moodle_line" -lt "$truth_line" ]
}
