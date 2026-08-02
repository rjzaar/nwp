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
#
# NO `command -v yq || skip` GUARDS HERE (removed 2026-08-03, MR !317)
#   Two cases below used to guard on yq and skip when it was absent: the
#   manifest-parse case, and the one that runs the site-name rejection checks
#   against a deliberately PERMISSIVE validator to prove they can go red. bats
#   scores a skip as `ok`, so on a yq-less machine the vacuity proof for !297
#   itself reported green having asserted nothing — H3 in
#   scripts/ci/lint-test-honesty.sh, in the suite that exists to catch vacuity.
#
#   The guards were also dead in the only place they claimed to help. test:unit
#   provisions a pinned, sha256-verified yq (scripts/ci/ensure-yq.sh), declares
#   `NWP_BATS_REQUIRED_TOOLS: "bats git php yq"`, and scripts/ci/run-bats.sh
#   exits 2 — "cannot verify" — before running a single case if any of those is
#   missing. The skip budget is an exact-equality contract on top of that. So a
#   yq-less runner is ALREADY a red pipeline; the guard could only ever fire on
#   a workstation, where silently not running these is exactly wrong.
#
#   If you land here because a case failed with "yq: command not found": that is
#   the intended report. Install yq (`pl setup`), do not re-add the guard.

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

@test "no site-name rejection check depends on a recipe being ABSENT (vacuity guard)" {
    # These checks are of the form `! pl install <recipe> '<hostile name>'`.
    # In CI the bootstrapped nwp.yml (from example.nwp.yml) ships only the
    # `pod` recipe, so `pl install d …` exits 1 on "Recipe 'd' not found" and
    # the leading `!` turns THAT into a green — the check passed while proving
    # nothing about name validation. Measured 2026-08-02: all 7 such checks
    # passed on a tree whose install.sh had no validation at all.
    #
    # They now assert the shared predicate directly (the idiom items 0-1
    # always used), which behaves identically on a runner and a workstation.
    # If someone reintroduces the `! pl install <recipe>` shape, this fails.
    run grep -nE "cmd: '?! pl install [a-z]" "$MANIFEST"
    [ "$status" -ne 0 ]
}

@test "the site-name rejection checks pass on the real validator and FAIL on a permissive one" {
    local cmds
    cmds="$(yq e '.features.security_validation.checklist[]
                  | select(.machine.checks.basic.commands[0].cmd | test("validate_sitename"))
                  | .machine.checks.basic.commands[0].cmd' "$MANIFEST")"
    [ -n "$cmds" ]
    [ "$(printf '%s\n' "$cmds" | wc -l)" -ge 7 ]

    # A stub tree whose validator accepts EVERYTHING: every check must go red.
    local stub="${BATS_TEST_TMPDIR}/permissive"
    mkdir -p "$stub/lib"
    printf 'validate_sitename() { return 0; }\n' > "$stub/lib/common.sh"
    : > "$stub/lib/ui.sh"

    local c
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        # real validator in the real tree: rejects ⇒ check passes
        ( cd "$REAL_ROOT" && bash -c "$c" >/dev/null 2>&1 )
        # permissive stub: accepts ⇒ check must fail (proves non-vacuity)
        ! ( cd "$stub" && bash -c "$c" >/dev/null 2>&1 )
    done <<< "$cmds"
}
