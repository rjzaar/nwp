#!/usr/bin/env bats
# ops#157 item 1, the POLICY half — drush must be a PROD dep on live-enabled
# sites, checked across the fleet rather than one site at a time.
#
# WHY THIS EXISTS SEPARATELY FROM THE D17 DEPLOY GATE.
#
# stg2live_stg_has_drush() (tests/unit/test-stg2live-chain-guards.bats) already
# refuses a deploy whose STAGING VENDOR has no drush, which is what stops the
# outage. It fires late by design: at deploy time, against a built vendor.
#
# The incident it came from was a DECLARATION bug, not a vendor bug. dev2stg
# runs `composer install --no-dev`; a site with drush in require-dev ships a
# drush-less vendor; stg2live §3.6 then runs `drush updatedb` on live from it
# and aborts AFTER maintenance mode is on. mt was down ~25 minutes on
# 2026-07-29. The issue asked for the sweep — "every live-enabled site's
# composer.json should be checked for this" — and it was never run.
#
# It matters that it was never run: sweeping the fleet on 2026-08-02 found
# THREE live-enabled sites still declaring drush in require-dev only (avc,
# mayo, saintschool). The deploy gate would have caught each of them one
# 25-minute window at a time.
#
# So this gate reads composer.json, not vendor/. A tree that has never had
# `composer install` run has no vendor and is not thereby a policy violation;
# grading it RED would train operators to ignore the check.

setup() {
  PROJECT_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  CMD="${PROJECT_ROOT}/scripts/commands/doctor.sh"
  # Source the two pure helpers only — doctor.sh's top level parses args and
  # would run the whole tool.
  source <(sed -n '/^doctor_composer_drush_placement() {/,/^}/p' "$CMD")
  source <(sed -n '/^doctor_site_composer() {/,/^}/p' "$CMD")
  TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TMP"; }

_composer() { printf '%s\n' "$2" > "$TMP/$1.json"; printf '%s\n' "$TMP/$1.json"; }

# ---------------------------------------------------------------------------
# doctor_composer_drush_placement — the classifier
# ---------------------------------------------------------------------------

@test "drush in require is the compliant placement" {
  f="$(_composer ok '{"require":{"drush/drush":"^12"},"require-dev":{"phpunit/phpunit":"^9"}}')"
  [ "$(doctor_composer_drush_placement "$f")" = "require" ]
}

@test "drush in require-dev ONLY is the 2026-07-29 outage shape" {
  # RED condition: this is exactly mt's composer.json before the incident fix.
  f="$(_composer bad '{"require":{"drupal/core":"^10"},"require-dev":{"drush/drush":"^12"}}')"
  [ "$(doctor_composer_drush_placement "$f")" = "require-dev" ]
}

@test "drush in BOTH counts as compliant (require is what survives --no-dev)" {
  f="$(_composer both '{"require":{"drush/drush":"^12"},"require-dev":{"drush/drush":"^12"}}')"
  [ "$(doctor_composer_drush_placement "$f")" = "require" ]
}

@test "no drush anywhere is 'none', not a false alarm" {
  # A Composer site may legitimately not use drush — stg2live has
  # NWP_ALLOW_NO_DRUSH=1 for that path. Flagging it would be crying wolf.
  f="$(_composer nodrush '{"require":{"drupal/core":"^10"}}')"
  [ "$(doctor_composer_drush_placement "$f")" = "none" ]
}

@test "a package merely CONTAINING 'drush' is not drush" {
  # The naive `grep drush composer.json` spelling of this check passes a site
  # that has drupal/drush_language and no drush — a green light straight into
  # the outage.
  f="$(_composer lang '{"require":{"drupal/drush_language":"^1","drupal/core":"^10"}}')"
  [ "$(doctor_composer_drush_placement "$f")" = "none" ]
}

@test "a non-drush/ vendor still counts (anchored on the package name)" {
  # The fleet is on drush/drush today, but hardcoding one vendor would make the
  # check silently blind to a fork or a mirror.
  f="$(_composer vendor '{"require":{"someorg/drush":"^12"}}')"
  [ "$(doctor_composer_drush_placement "$f")" = "require" ]
}

# ---------------------------------------------------------------------------
# FAIL-CLOSED — "I could not look" must never read as "nothing found"
# ---------------------------------------------------------------------------

@test "MALFORMED composer.json is 'unreadable', NOT a confident 'none'" {
  # ops#214: a gate that returns green on a corrupt input is not a gate. A
  # truncated or half-written composer.json must be reported as unverifiable.
  f="$(_composer broken '{"require": {"drush/drush": ')"
  [ "$(doctor_composer_drush_placement "$f")" = "unreadable" ]
}

@test "an ABSENT composer.json is 'unreadable', not 'none'" {
  [ "$(doctor_composer_drush_placement "$TMP/does-not-exist.json")" = "unreadable" ]
}

@test "an EMPTY file is 'unreadable', not 'none'" {
  : > "$TMP/empty.json"
  [ "$(doctor_composer_drush_placement "$TMP/empty.json")" = "unreadable" ]
}

@test "no argument at all is 'unreadable'" {
  [ "$(doctor_composer_drush_placement)" = "unreadable" ]
}

@test "the classifier is not a yes-machine (its verdicts actually differ)" {
  # Negative control on the whole table: if a refactor collapsed the function
  # to a single constant, every test above could still be written to pass.
  local a b c d
  a="$(doctor_composer_drush_placement "$(_composer y1 '{"require":{"drush/drush":"^12"}}')")"
  b="$(doctor_composer_drush_placement "$(_composer y2 '{"require-dev":{"drush/drush":"^12"}}')")"
  c="$(doctor_composer_drush_placement "$(_composer y3 '{"require":{}}')")"
  d="$(doctor_composer_drush_placement "$TMP/absent.json")"
  [ "$a" != "$b" ] && [ "$b" != "$c" ] && [ "$c" != "$d" ]
}

# ---------------------------------------------------------------------------
# doctor_site_composer — which composer.json governs the deploy
# ---------------------------------------------------------------------------

@test "dev/composer.json wins: it is the tree dev2stg builds staging from" {
  mkdir -p "$TMP/site/dev"
  echo '{}' > "$TMP/site/composer.json"
  echo '{}' > "$TMP/site/dev/composer.json"
  [ "$(doctor_site_composer "$TMP/site")" = "$TMP/site/dev/composer.json" ]
}

@test "falls back to the site-root composer.json (v1 layout)" {
  mkdir -p "$TMP/site2"
  echo '{}' > "$TMP/site2/composer.json"
  [ "$(doctor_site_composer "$TMP/site2")" = "$TMP/site2/composer.json" ]
}

@test "a Moodle/static site with no composer.json yields nothing (not an error)" {
  mkdir -p "$TMP/moodle"
  [ -z "$(doctor_site_composer "$TMP/moodle")" ]
}

# ---------------------------------------------------------------------------
# Wiring — an unreferenced check is not a check
# ---------------------------------------------------------------------------

@test "check_live_drush_dependency is DEFINED and CALLED from main()" {
  grep -q '^check_live_drush_dependency() {' "$CMD"
  # Exactly one call site: ops#204 found a pl todo check registered twice and
  # therefore run twice, so assert the count, not just the presence.
  local calls
  calls="$(grep -c '^ *check_live_drush_dependency || total_errors' "$CMD")"
  [ "$calls" -eq 1 ]
}

@test "the check reads composer.json, not vendor/ (declaration, not build state)" {
  # An unbuilt tree must not be graded RED — see the header. If someone
  # 'strengthens' this to probe vendor/bin/drush, that is the D17 gate's job
  # and this test should stop them.
  local body
  body="$(sed -n '/^check_live_drush_dependency() {/,/^}/p' "$CMD")"
  [[ "$body" != *"vendor/bin/drush"* ]]
  [[ "$body" == *"composer"* ]]
}

@test "live.enabled is read with a BARE path, not yq's // fallback" {
  # `.live.enabled // "false"` returns the FALLBACK on a real `enabled: false`,
  # because yq's alternative operator treats false as absent. Here that would
  # merely skip a site, but the same spelling on a safety-critical toggle is how
  # this trap bites — lib/project-resolver.sh documents it for this exact key.
  local body
  body="$(sed -n '/^check_live_drush_dependency() {/,/^}/p' "$CMD")"
  [[ "$body" == *"yq eval '.live.enabled'"* ]]
  [[ "$body" != *".live.enabled //"* ]]
}
