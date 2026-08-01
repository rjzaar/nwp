#!/usr/bin/env bats
# .verification.yml manifest hygiene + the verify.sh site-skip contract (ops#165).
#
# test:verification was red on main forever, and the failures decomposed into
# exactly the shapes these cases pin:
#
#   1. Manifest commands hardcoded `~/nwp/…`, so the gate measured the
#      OPERATOR'S clone (or nothing at all on a runner user with no ~/nwp —
#      whole lib_* feature clusters failed 127 on the fallback runner)
#      instead of the checkout under test.
#   2. Manifest commands invoked bare `pl`, which resolved through the
#      caller's PATH to the same wrong place; verify.sh now pins PATH to
#      PROJECT_ROOT (see source_verify_runner).
#   3. Checks for RETIRED code stayed in the manifest (lib/safe-ops.sh,
#      retired 2026-07-26 with zero callers, still had 3 `bash -n` checks —
#      guaranteed red). The manifest must not assert files the tree lost.
#   4. {site}-parameterised checks ran with {site} substituted to "" when no
#      test site existed, failing on garbage commands like
#      `cd sites/ && ddev drush uli`. They are now SKIPPED, visibly.

setup() {
    REAL_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
    MANIFEST="${REAL_ROOT}/.verification.yml"
}

@test "no machine-check command reaches outside the checkout via ~/nwp" {
    # cmd lines only — how_to_verify prose may talk about ~/nwp to a human.
    run grep -nE '^\s*-?\s*cmd:.*~/nwp' "$MANIFEST"
    [ "$status" -ne 0 ]
}

@test "every 'bash -n <file>' target in the manifest exists in the tree" {
    # This is the check that would have flagged lib/safe-ops.sh the day it was
    # retired, instead of leaving 3 permanently-red items for five weeks.
    local missing=0 f
    while IFS= read -r f; do
        if [ ! -f "${REAL_ROOT}/${f}" ]; then
            echo "MISSING: $f" >&3
            missing=$((missing + 1))
        fi
    done < <(grep -oE 'cmd: bash -n [^ ]+' "$MANIFEST" | awk '{print $4}' | sort -u)
    [ "$missing" -eq 0 ]
}

@test "the retired lib/safe-ops.sh has no manifest feature" {
    run grep -c 'safe-ops\|safe_ops' "$MANIFEST"
    [ "$output" = "0" ]
}

@test "manifest still parses and keeps its feature count" {
    command -v yq >/dev/null || skip "needs yq"
    run yq e '.features | keys | length' "$MANIFEST"
    [ "$status" -eq 0 ]
    [ "$output" -ge 90 ]
}

@test "item_machine_checks_need_site: {site} checks are detected, others are not" {
    source "${REAL_ROOT}/scripts/commands/verify.sh"
    VERIFICATION_FILE="$MANIFEST"
    # copy:2 is `test -d sites/{site}-copy` — needs a site.
    item_machine_checks_need_site "copy" 2 "basic"
    # install:0 is a pure `pl install --help` shape check — does not.
    ! item_machine_checks_need_site "install" 0 "basic"
}

@test "verify.sh pins pl to the checkout under test (PATH prepend)" {
    source "${REAL_ROOT}/scripts/commands/verify.sh"
    source_verify_runner
    [ "$(command -v pl)" = "${REAL_ROOT}/pl" ]
}
