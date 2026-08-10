#!/usr/bin/env bats
# =============================================================================
# tests/unit/test-sanitizer-overlay.bats — ops#326 Phase 1 tranche 2
#
# Per-INSTANCE sanitizers (the reviewed, security-critical per-site wrappers)
# live in the PRIVATE OVERLAY repo (private/sanitizers/), searched after the
# shipped lib/sanitizers/ (which keeps only the generic, product-level ones:
# standard.sh, moodle*.sh, oidc-email.sh, files-secrets.sh).
#
# The resolution stays FAIL-CLOSED: no sanitizer found in either location ⇒
# refuse, naming both places looked. server-publish.sh is the resolver under
# test (NWP_ROOT-overridable, self-contained); onboard.sh's preflight carries
# the same rule and its refusal must name both locations too.
# =============================================================================

REPO_ROOT_S="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  TEST_TMP="$(mktemp -d)"
  export NWP_ROOT="${TEST_TMP}/estate"
  mkdir -p "${NWP_ROOT}/lib/sanitizers" "${NWP_ROOT}/private/sanitizers" "${TEST_TMP}/site"
  unset NWP_SANITIZER_OVERLAY_DIR
}

teardown() { rm -rf "$TEST_TMP"; }

_publish() { # <site>
  bash "${REPO_ROOT_S}/scripts/commands/server-publish.sh" \
    --site "$1" --site-dir "${TEST_TMP}/site" \
    --publish-url https://example.invalid/up \
    --publish-token-file "${TEST_TMP}/no-such-token"
}

@test "ops#326: server-publish refuses with NO sanitizer, naming BOTH locations" {
  run _publish fxnone
  [ "$status" -ne 0 ]
  [[ "$output" == *"lib/sanitizers/fxnone.sh"* ]]
  [[ "$output" == *"private/sanitizers/fxnone.sh"* ]]
}

@test "ops#326: server-publish resolves a sanitizer from the private overlay" {
  printf '#!/bin/bash\nexit 0\n' > "${NWP_ROOT}/private/sanitizers/fxovl.sh"
  run _publish fxovl
  # sanitizer resolution succeeded ⇒ the failure moves PAST it (token file).
  [ "$status" -ne 0 ]
  [[ "$output" == *"token file"* ]]
  [[ "$output" != *"no sanitizer"* ]]
}

@test "ops#326: shipped lib/sanitizers still wins when present (unchanged behaviour)" {
  printf '#!/bin/bash\nexit 0\n' > "${NWP_ROOT}/lib/sanitizers/fxship.sh"
  run _publish fxship
  [ "$status" -ne 0 ]
  [[ "$output" == *"token file"* ]]
  [[ "$output" != *"no sanitizer"* ]]
}

@test "ops#326: onboard's preflight refusal names both sanitizer locations" {
  # fxnone is not a registered site, so preflight reaches the sanitizer check
  # and must refuse naming shipped + overlay. (We never get near ssh/ddev.)
  run bash "${REPO_ROOT_S}/scripts/commands/onboard.sh" fxnoneon \
      --server=fxsrv --source=/var/www/fx --recipe=d
  [ "$status" -ne 0 ]
  [[ "$output" == *"lib/sanitizers/fxnoneon.sh"* ]]
  [[ "$output" == *"private/sanitizers/fxnoneon.sh"* ]]
}
