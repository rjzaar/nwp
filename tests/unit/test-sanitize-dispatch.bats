#!/usr/bin/env bats
# nwp/ops#76 — ADR-0031 Phase D: promotion-pipeline type dispatch.
# Verifies the Drupal-vs-Moodle sanitize dispatch is config-driven, off unless a
# Moodle target is hit, and that the Moodle handler fails closed. These tests run
# with NO ddev/drush available — they exercise the config path and stub only.

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  export NWP_DIR="${PROJECT_ROOT}"
  mkdir -p "${PROJECT_ROOT}/sites/drupsite" "${PROJECT_ROOT}/sites/moodsite" \
           "${PROJECT_ROOT}/sites/podsite"
  cat > "${PROJECT_ROOT}/sites/drupsite/.nwp.yml" <<'EOF'
schema_version: 2
project:
  name: drupsite
  type: drupal
EOF
  cat > "${PROJECT_ROOT}/sites/moodsite/.nwp.yml" <<'EOF'
schema_version: 2
project:
  name: moodsite
  type: moodle
EOF
  cat > "${PROJECT_ROOT}/sites/podsite/.nwp.yml" <<'EOF'
schema_version: 2
project:
  name: podsite
  type: podcast
EOF

  source "${BATS_TEST_DIRNAME}/../../lib/ui.sh"
  source "${BATS_TEST_DIRNAME}/../../lib/project-resolver.sh"
  source "${BATS_TEST_DIRNAME}/../../lib/database-router.sh"

  # Guard: if the schema probe is ever reached in these tests it means config
  # detection failed. Override it to a loud sentinel so such a bug is visible.
  _stack_schema_probe() { echo "PROBE_SHOULD_NOT_RUN"; }
}

teardown() {
  rm -rf "${TEST_TMP}"
  unset PROJECT_ROOT NWP_DIR
}

# ── _stack_from_type: only explicit moodle routes to moodle ──────────────────

@test "_stack_from_type maps moodle → moodle" {
  run _stack_from_type "moodle"
  [ "$status" -eq 0 ]
  [ "$output" = "moodle" ]
}

@test "_stack_from_type maps drupal → drupal" {
  run _stack_from_type "drupal"
  [ "$output" = "drupal" ]
}

@test "_stack_from_type maps unknown/empty types → drupal (default, dispatch off)" {
  run _stack_from_type "podcast"; [ "$output" = "drupal" ]
  run _stack_from_type "utility"; [ "$output" = "drupal" ]
  run _stack_from_type "";        [ "$output" = "drupal" ]
}

# ── detect_site_stack: config-driven, env-suffix aware ───────────────────────

@test "detect_site_stack reads project.type=drupal from config" {
  run detect_site_stack "drupsite"
  [ "$status" -eq 0 ]
  [ "$output" = "drupal" ]
}

@test "detect_site_stack reads project.type=moodle from config" {
  run detect_site_stack "moodsite"
  [ "$output" = "moodle" ]
}

@test "detect_site_stack strips -stg env suffix before config lookup" {
  run detect_site_stack "moodsite-stg"
  [ "$output" = "moodle" ]
}

@test "detect_site_stack strips -live env suffix before config lookup" {
  run detect_site_stack "drupsite-live"
  [ "$output" = "drupal" ]
}

@test "detect_site_stack: non-moodle type resolves to drupal (podcast)" {
  run detect_site_stack "podsite"
  [ "$output" = "drupal" ]
}

@test "detect_site_stack never falls through to the schema probe when config exists" {
  run detect_site_stack "moodsite"
  [ "$output" != "PROBE_SHOULD_NOT_RUN" ]
  run detect_site_stack "drupsite"
  [ "$output" != "PROBE_SHOULD_NOT_RUN" ]
}

# ── dispatch: sanitize_staging_db routes to the right handler ────────────────

@test "sanitize_staging_db routes a moodle target to the fail-closed stub" {
  # Stub the two handlers so we observe routing without touching ddev.
  _sanitize_staging_db_drupal() { echo "DRUPAL_HANDLER"; return 0; }
  _sanitize_staging_db_moodle()  { echo "MOODLE_HANDLER"; return 1; }
  run sanitize_staging_db "moodsite-stg"
  [ "$status" -eq 1 ]                       # fail-closed
  [ "$output" = "MOODLE_HANDLER" ]
}

@test "sanitize_staging_db routes a drupal target to the drupal handler (unchanged)" {
  _sanitize_staging_db_drupal() { echo "DRUPAL_HANDLER"; return 0; }
  _sanitize_staging_db_moodle()  { echo "MOODLE_HANDLER"; return 1; }
  run sanitize_staging_db "drupsite-stg"
  [ "$status" -eq 0 ]
  [ "$output" = "DRUPAL_HANDLER" ]
}

# ── the DDEV in-place Moodle handler stays fail-closed and points to Path A ───
# ops#110: Moodle sanitisation is IMPLEMENTED (lib/sanitizers/moodle.sh) but
# routed prod-native (Path A). This DDEV in-place path (Path B) is intentionally
# not wired to it, so it must still refuse (non-zero) and steer the operator to
# the prod-native route rather than claim the sanitizer is unauthored.

@test "_sanitize_staging_db_moodle refuses and returns non-zero (fail-closed)" {
  run _sanitize_staging_db_moodle "moodsite-stg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Path A"* ]]
  [[ "$output" == *"server-publish.sh"* ]]
}

# ── the standalone prod-native sanitizer fails closed on a non-Moodle dir ─────
# moodle_sanitize() is now IMPLEMENTED (see tests/unit/test-moodle-sanitize.bats
# and tests/integration/test-moodle-sanitize-synthetic.sh). Handed a directory
# that is not a Moodle root (no version.php), it must still refuse — fail-closed.

@test "lib/sanitizers/moodle.sh refuses a non-Moodle dir (no version.php, fail-closed)" {
  run bash "${BATS_TEST_DIRNAME}/../../lib/sanitizers/moodle.sh" --site-dir "${TEST_TMP}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"version.php"* ]]
}

# ── ssc.sh: the Path A per-site resolver delegates to moodle-full.sh (ops#110/#111) ─
# server-publish.sh resolves lib/sanitizers/<site>.sh; ssc's is a thin wrapper
# that must (a) delegate verbatim to moodle.sh, and (b) propagate its fail-closed
# non-zero exit unchanged.

@test "lib/sanitizers/ssc.sh delegates to moodle-full.sh (--verify on missing bundle fails closed)" {
  run bash "${BATS_TEST_DIRNAME}/../../lib/sanitizers/ssc.sh" --verify --output "${TEST_TMP}/nope.tar.gz"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no bundle to verify"* ]]   # message originates in moodle-full.sh
}

@test "lib/sanitizers/ssc.sh requires --site-dir (fail-closed, propagated from moodle-full.sh)" {
  run bash "${BATS_TEST_DIRNAME}/../../lib/sanitizers/ssc.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--site-dir"* ]]
}

@test "lib/sanitizers/ssc.sh refuses a non-Moodle dir (delegation reaches the version.php guard)" {
  run bash "${BATS_TEST_DIRNAME}/../../lib/sanitizers/ssc.sh" --site-dir "${TEST_TMP}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"version.php"* ]]
}
