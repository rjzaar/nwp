#!/usr/bin/env bats
#
# `pl demo golden --tier=live` must STAGE what it captures — or say loudly that
# the nightly will not restore it (ops#269).
#
# THE INCIDENT THIS PINS. On 2026-08-03 two live fixes were captured and
# reported durable; the overnight reset REVERTED BOTH. Capture writes to
# sites/<site>/demo-golden-live/ in the repo; the nightly restores from
# /var/lib/nwp-demo/<site>/golden/ on the box. The verb even printed "Nightly
# restore will return <site> to exactly this state" — a claim about an artefact
# it had never touched. The operator's tester account regained three retired
# groups overnight, and ssd came up with versiondb behind versiondisk.
#
# The staging itself is delegated to install-box.sh --stage-golden, which
# sha256-verifies ON THE BOX; its exit code is therefore the box==local proof.
# These tests stub it via NWP_DEMO_INSTALL_BOX and pin the function's contract.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/goldstage.XXXXXX")"
    export PROJECT_ROOT="$REPO_ROOT"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/ui.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/demo.sh"
}
teardown() { rm -rf "$TMP"; }

_stub() { # exit-code
    cat > "$TMP/stub-install-box.sh" <<EOF
#!/usr/bin/env bash
echo "STUB-CALLED site=\$1 args=\$*" >> "$TMP/calls.log"
exit $1
EOF
    chmod +x "$TMP/stub-install-box.sh"
    export NWP_DEMO_INSTALL_BOX="$TMP/stub-install-box.sh"
}

@test "staging success returns 0 and passed the site + --stage-golden through" {
    _stub 0
    run demo_golden_stage_and_verify ssd
    [ "$status" -eq 0 ]
    grep -q 'STUB-CALLED site=ssd' "$TMP/calls.log"
    grep -q -- '--stage-golden' "$TMP/calls.log"
}

@test "RED-PROOF: staging failure returns non-zero and says the box holds the PREVIOUS golden" {
    # The whole point. A capture whose staging failed must never read as
    # durable — that is exactly the false claim that reverted two live fixes.
    _stub 1
    run demo_golden_stage_and_verify ssd
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'STAGING FAILED'
    echo "$output" | grep -q 'PREVIOUS golden'
    echo "$output" | grep -qi 'reset will restore THAT'
}

@test "a missing stager script is CANNOT-STAGE (3), not success" {
    export NWP_DEMO_INSTALL_BOX="$TMP/definitely-absent-$$.sh"
    run demo_golden_stage_and_verify ssd
    [ "$status" -eq 3 ]
    echo "$output" | grep -q 'PREVIOUS golden'
}

@test "the false unconditional survival claim is GONE from the verb" {
    # The old shape: the hint printed immediately after the capture OK, with no
    # staging in between. Pin its absence — if someone reintroduces an
    # unconditional "Nightly restore will return", this goes red.
    ! grep -A1 'Live golden image captured + verified' "$REPO_ROOT/scripts/commands/demo.sh" \
        | grep -q 'Nightly restore will return'
    # and the earned version exists, guarded by the staging call
    grep -q 'demo_golden_stage_and_verify "$site"' "$REPO_ROOT/scripts/commands/demo.sh"
    grep -q 'staged + sha256-verified on the box' "$REPO_ROOT/scripts/commands/demo.sh"
}

@test "--no-stage is a real flag and its warning names the consequence" {
    grep -q -- '--no-stage) DEMO_GOLDEN_NO_STAGE="true"' "$REPO_ROOT/scripts/commands/demo.sh"
    grep -q 'NOT STAGED (--no-stage)' "$REPO_ROOT/scripts/commands/demo.sh"
    grep -q 'reset will restore THAT image' "$REPO_ROOT/scripts/commands/demo.sh"
}
