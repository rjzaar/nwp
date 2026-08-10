#!/usr/bin/env bats
# THREE GUARDS THAT FAILED OPEN WHEN THEY COULD NOT READ THEIR CONFIG
# (found by the sweep during MR !211, fixed 2026-07-27)
#
# THE INVERSION THIS FILE PINS
#   A guard reads a value from a config file. The READ fails — file missing,
#   YAML unparseable, artifact corrupt. The empty result maps to the WEAKEST
#   setting, and the guard silently permits the thing it exists to prevent.
#   "I couldn't read it" became "there's nothing to enforce" instead of
#   "I can't tell, refuse."
#
#   1. lib/canonical.sh   an unparseable nwp.yml turned every `canonical: live`
#                         site into `dev` (so the dev→live CONTENT overwrite was
#                         permitted) and every `maturity: production` site into
#                         `incubating` (so prod stopped routing through the
#                         signed-bundle path — a refusal with NO override by
#                         design, making this fail-open the only way past it).
#   2. lib/sanitizers/    reported "PASS: No PII patterns detected" on a dump
#      mayo.sh            zgrep could not read. Its sibling moodle.sh:177 already
#                         did the right thing; this copies that shape.
#   3. lib/moodle-        returned zero core-patch ids from an unparseable
#      deploy.sh          declaration, emptying a gate whose own refusal message
#                         says "Override is deliberately NOT provided."
#
# Vocabulary is lib/boundary.sh's and lib/pair.sh's, not a new one: rc 2 /
# "cannot-verify" = CANNOT VERIFY, which is NOT a clean result.
#
# EVERY SECTION CARRIES A NEGATIVE CONTROL so this suite cannot be satisfied by
# a guard that simply refuses everything: a correctly configured site must still
# be permitted to do the normal thing.

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  export NWP_YML="${PROJECT_ROOT}/nwp.yml"
  mkdir -p "${PROJECT_ROOT}/sites"
  LIB="${BATS_TEST_DIRNAME}/../../lib"
}

teardown() {
  rm -rf "${TEST_TMP}"
  unset NWP_YML PROJECT_ROOT NWP_CANONICAL_GATE_SOFT
}

################################################################################
# 1. lib/canonical.sh — canonical phase + maturity class
################################################################################

_canon_load() {
  source "${LIB}/ui.sh"
  source "${LIB}/yaml-write.sh"
  source "${LIB}/canonical.sh"
}

# A site that is genuinely protected: live content source, production code class.
_canon_good_config() {
  mkdir -p "${PROJECT_ROOT}/sites/beta" "${PROJECT_ROOT}/sites/alpha"
  cat > "${NWP_YML}" <<'EOF'
sites:
  alpha:
    recipe: d
    canonical: dev
    maturity: incubating
  beta:
    recipe: d
    canonical: live
    maturity: production
EOF
}

# The same config, then corrupted — a truncated / half-written nwp.yml, which is
# exactly what an interrupted `pl canonical set` or a bad merge leaves behind.
_canon_corrupt_config() {
  _canon_good_config
  printf '    canonical: [unclosed\n\t\tbad: tab\n' >> "${NWP_YML}"
}

@test "canonical: fixture check — the corrupt config really is unparseable" {
  _canon_corrupt_config
  run yq e '.' "${NWP_YML}"
  [ "$status" -ne 0 ]
}

@test "canonical: unparseable nwp.yml yields cannot-verify, not the dev default" {
  _canon_load; _canon_corrupt_config
  run canonical_get_phase beta
  [ "$status" -eq 0 ]
  [[ "$output" == cannot-verify:* ]]
  [[ "$output" != "dev" ]]
}

@test "canonical: unparseable nwp.yml yields cannot-verify, not the incubating default" {
  _canon_load; _canon_corrupt_config
  run maturity_get_class beta
  [[ "$output" == cannot-verify:* ]]
  [[ "$output" != "incubating" ]]
}

@test "canonical: content push to live is REFUSED when the config cannot be read" {
  _canon_load; _canon_corrupt_config
  run canonical_guard_content_push beta live false stg2live
  [ "$status" -eq 1 ]
  [[ "$output" == *"CANNOT VERIFY"* ]] || [[ "$output" == *"cannot verify"* ]]
}

@test "canonical: --override-canonical does NOT buy past an unreadable config" {
  # The override is a decision to clobber a phase you KNOW. It must not double
  # as a licence to deploy past a config nobody can read.
  _canon_load; _canon_corrupt_config
  run canonical_guard_content_push beta live true stg2live
  [ "$status" -eq 1 ]
}

@test "canonical: maturity deploy guard is REFUSED when the config cannot be read" {
  # This is the worse half: maturity: production has no override by design, so
  # collapsing to 'incubating' was the ONLY way past it.
  _canon_load; _canon_corrupt_config
  run maturity_guard_deploy beta stg2live
  [ "$status" -eq 1 ]
}

@test "canonical: the unconditional branch-policy guard also refuses" {
  # canonical_enforce_branch_policy runs on EVERY stg2live/stg2prod/live2prod,
  # including --code-only, so it is the choke point that stops the whole deploy.
  _canon_load; _canon_corrupt_config
  run canonical_enforce_branch_policy beta deploy
  [ "$status" -eq 1 ]
}

@test "canonical: a MISSING config with the site on disk still defaults — but LOUDLY" {
  # The line is drawn at PARSEABILITY, not presence. Refusing here was
  # implemented and withdrawn: `pl moodle plugin deploy` legitimately runs
  # against a tree whose only config is sites/<site>/.nwp.yml (see
  # tests/unit/test-moodle-ops-verbs.bats c4), and no evidence exists to
  # distinguish that from a vanished registry. So the default stands and the
  # condition is announced — silence was half the original defect.
  _canon_load; _canon_good_config; rm -f "${NWP_YML}"
  run canonical_get_phase beta
  [ "$output" = "dev" ]
  run maturity_guard_deploy beta stg2live
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"not being gated"* ]] || [[ "$output" == *"NOT being gated"* ]]
}

@test "canonical: the loud warning does NOT fire in a fresh clone / CI / worktree" {
  # sites/* is gitignored, so a tree with no nwp.yml also has an empty sites/.
  # Warning on every worktree run would be noise that trains people to ignore it.
  _canon_load
  rm -f "${NWP_YML}"; rm -rf "${PROJECT_ROOT}/sites"
  run maturity_guard_deploy beta stg2live
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING"* ]]
}

@test "canonical: NWP_CANONICAL_GATE_SOFT downgrades to a warning and ledgers it" {
  _canon_load; _canon_corrupt_config
  NWP_CANONICAL_GATE_SOFT=true run maturity_guard_deploy beta stg2live
  [ "$status" -eq 0 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
  grep -q "cannot-verify-soft-skip" "${PROJECT_ROOT}/private/canonical/beta.log"
}

# --- NEGATIVE CONTROLS: the ordinary paths must still work --------------------

@test "canonical (negative control): a healthy config still refuses for the RIGHT reason" {
  # Not "refuses everything": it refuses because beta is canonical: live, and it
  # says so — no cannot-verify anywhere in the message.
  _canon_load; _canon_good_config
  run canonical_guard_content_push beta live false stg2live
  [ "$status" -eq 1 ]
  [[ "$output" == *"canonical: live"* ]]
  [[ "$output" != *"CANNOT VERIFY"* ]]
}

@test "canonical (negative control): a canonical:dev site still pushes content to live" {
  _canon_load; _canon_good_config
  run canonical_guard_content_push alpha live false stg2live
  [ "$status" -eq 0 ]
}

@test "canonical (negative control): an incubating site still deploys" {
  _canon_load; _canon_good_config
  run maturity_guard_deploy alpha stg2live
  [ "$status" -eq 0 ]
}

@test "canonical (negative control): no config AND no site dir keeps today's defaults" {
  # A fresh clone, a CI job, or one of the ~40 linked worktrees (sites/* is
  # gitignored, so those trees have an empty sites/). There is no registry and
  # no site to protect. Refusing here would break ordinary work and get
  # reverted, which leaves us worse off than the bug.
  _canon_load
  rm -f "${NWP_YML}"; rm -rf "${PROJECT_ROOT}/sites"
  run canonical_get_phase beta
  [ "$output" = "dev" ]
  run maturity_get_class beta
  [ "$output" = "incubating" ]
  run canonical_guard_content_push beta live false stg2live
  [ "$status" -eq 0 ]
  run maturity_guard_deploy beta stg2live
  [ "$status" -eq 0 ]
}

@test "canonical (negative control): an explicitly INVALID value still fails closed" {
  # The pre-existing contract must survive the fix, and must not be mistaken
  # for the new cannot-verify state.
  _canon_load
  mkdir -p "${PROJECT_ROOT}/sites/gamma"
  printf 'sites:\n  gamma:\n    canonical: bogus\n' > "${NWP_YML}"
  run canonical_get_phase gamma
  [ "$output" = "invalid:bogus" ]
  run canonical_guard_content_push gamma live false stg2live
  [ "$status" -eq 1 ]
}

################################################################################
# 2. per-site PII sweeps — ops#326: the per-INSTANCE sanitizers (mayo.sh,
#    ssc.sh) moved to the private overlay repo (private/sanitizers/), so their
#    fail-closed sweep properties are asserted here against the SHIPPED generic
#    sanitizers that implement the same sweep (standard.sh below, moodle.sh as
#    the sibling cross-check). The overlay repo carries the per-instance
#    copies; the properties proven here are the ones they inherit.
################################################################################

################################################################################
# 2b. lib/sanitizers/standard.sh — the SAME bug, found by finishing the sweep.
#
# standard.sh is the generic DEFAULT Drupal sanitizer (resolved for any site
# with no bespoke lib/sanitizers/<site>.sh), so this was the widest-reach copy
# of the mayo.sh inversion. Its pii_sweep() reported "PII sweep: clean" on a
# corrupt dump seeded with real PII, and the main flow's final gate
# (`pii_sweep "$OUTPUT" || … exit 1`) then handed the artifact off as sanitised.
################################################################################

STD() { bash "${LIB}/sanitizers/standard.sh" --verify --output "$1"; }

@test "standard PII sweep: a CORRUPT gzip is refused, not swept clean" {
  printf "INSERT INTO users VALUES ('victim@realdomain.example');\n" \
    | gzip > "${TEST_TMP}/corrupt.sql.gz"
  head -c 12 "${TEST_TMP}/corrupt.sql.gz" > "${TEST_TMP}/t" && mv "${TEST_TMP}/t" "${TEST_TMP}/corrupt.sql.gz"
  run STD "${TEST_TMP}/corrupt.sql.gz"
  [ "$status" -eq 2 ]
  [[ "$output" != *"PII sweep: clean"* ]]
  [[ "$output" == *"fail-closed"* ]]
}

@test "standard PII sweep: an EMPTY artifact is refused, not swept clean" {
  : > "${TEST_TMP}/empty.sql.gz"
  run STD "${TEST_TMP}/empty.sql.gz"
  [ "$status" -ne 0 ]
  [[ "$output" != *"PII sweep: clean"* ]]
}

@test "standard PII sweep: matches its sibling moodle.sh on the same corrupt input" {
  # One vocabulary, not two — the Drupal and Moodle sweeps refuse identically.
  printf 'x' | gzip > "${TEST_TMP}/c.sql.gz"
  head -c 12 "${TEST_TMP}/c.sql.gz" > "${TEST_TMP}/t" && mv "${TEST_TMP}/t" "${TEST_TMP}/c.sql.gz"
  run bash "${LIB}/sanitizers/moodle.sh" --verify --output "${TEST_TMP}/c.sql.gz"
  [ "$status" -ne 0 ]
  run STD "${TEST_TMP}/c.sql.gz"
  [ "$status" -ne 0 ]
}

@test "standard PII sweep: an artifact that decompresses to nothing is refused" {
  printf '' | gzip > "${TEST_TMP}/hollow.sql.gz"
  run STD "${TEST_TMP}/hollow.sql.gz"
  [ "$status" -eq 2 ]
  [[ "$output" != *"PII sweep: clean"* ]]
}

@test "standard (negative control): a well-formed sanitized dump still sweeps clean" {
  printf "INSERT INTO users VALUES ('user1@example.com');\n" \
    | gzip > "${TEST_TMP}/ok.sql.gz"
  run STD "${TEST_TMP}/ok.sql.gz"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PII sweep: clean"* ]]
}

@test "standard (negative control): a readable dump WITH PII still FAILS for that reason" {
  printf "INSERT INTO users VALUES ('victim@realdomain.example');\n" \
    | gzip > "${TEST_TMP}/pii.sql.gz"
  run STD "${TEST_TMP}/pii.sql.gz"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PII sweep FAIL"* ]]
}

################################################################################
# 3. lib/moodle-deploy.sh — declared core patches
################################################################################

_cp_load() {
  source "${LIB}/moodle-promote.sh" >/dev/null 2>&1 || true
  source "${LIB}/moodle-deploy.sh"
  CPF="${TEST_TMP}/core-patches.yml"
}

# The real ssc declaration: the live guest front door, a one-line change to
# Moodle CORE index.php that existed only as an uncommitted working-tree diff.
_cp_good() {
  cat > "${CPF}" <<'EOF'
core_patches:
  - id:     ssc-index-browse-frontdoor
    file:   index.php
    assert: "local/browse"
    why:    "guest front door redirects to local_browse"
EOF
}

@test "core patches: an unparseable declaration is cannot-verify, not zero patches" {
  _cp_load; _cp_good
  printf '  - id: [unclosed\n\tbad: y\n' >> "${CPF}"
  run moodle_core_patch_ids "${CPF}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not parse"* ]]
}

@test "core patches: a declaration filed under the wrong key is cannot-verify" {
  _cp_load
  printf 'core_patchez:\n  - id: ssc-index-browse-frontdoor\n    file: index.php\n' > "${CPF}"
  run moodle_core_patch_ids "${CPF}"
  [ "$status" -eq 2 ]
}

@test "core patches: a mis-shaped core_patches: is cannot-verify" {
  _cp_load
  printf 'core_patches:\n  id: ssc-index-browse-frontdoor\n' > "${CPF}"
  run moodle_core_patch_ids "${CPF}"
  [ "$status" -eq 2 ]
}

@test "core patches: an entry with no id: is cannot-verify (no verifying a subset)" {
  _cp_load
  printf 'core_patches:\n  - file: index.php\n    assert: local/browse\n' > "${CPF}"
  run moodle_core_patch_ids "${CPF}"
  [ "$status" -eq 2 ]
}

# --- NEGATIVE CONTROLS --------------------------------------------------------

@test "core patches (negative control): a healthy declaration still yields its ids" {
  _cp_load; _cp_good
  run moodle_core_patch_ids "${CPF}"
  [ "$status" -eq 0 ]
  [ "$output" = "ssc-index-browse-frontdoor" ]
}

@test "core patches (negative control): an ABSENT declaration is still a clean no-op" {
  # Sites without core patches must be unaffected — the common case, and the
  # thing a naive fail-closed would break. Asserted as "no ids AND not
  # cannot-verify" so this control holds under the pre-fix code too and cannot
  # be satisfied by a reader that refuses everything.
  _cp_load
  run moodle_core_patch_ids "${TEST_TMP}/nope.yml"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "core patches (negative control): an EXPLICITLY empty declaration is a clean no-op" {
  _cp_load
  printf 'core_patches: []\n' > "${CPF}"
  run moodle_core_patch_ids "${CPF}"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
  printf 'core_patches:\n' > "${CPF}"
  run moodle_core_patch_ids "${CPF}"
  [ "$status" -ne 2 ]
  [ -z "$output" ]
}

@test "core patches (negative control): field reads still work on a healthy file" {
  _cp_load; _cp_good
  run moodle_core_patch_field "${CPF}" ssc-index-browse-frontdoor file
  [ "$output" = "index.php" ]
  run moodle_core_patch_field "${CPF}" ssc-index-browse-frontdoor assert
  [ "$output" = "local/browse" ]
}
