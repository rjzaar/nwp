#!/usr/bin/env bats
#
# test-verify-ci-requires.bats — `test:verification` must be HONEST about what
# a shell-executor build slot can and cannot run.               (nwp/ops#159)
#
# WHY THIS FILE EXISTS
#   The CI job runs `verify.sh ci --depth=basic` over the full 569-item
#   registry. A large subset of those checks need ddev, docker, or a live site
#   — things a shell-runner build slot does not have — so the job sat at ~72%
#   "pass" where most of the red was really "this machine cannot run this
#   check". A check that CANNOT run here is not evidence of failure, and it is
#   not evidence of success either. It must be reported as SKIPPED, with the
#   reason, and it must not dilute the pass rate of the checks that DID run.
#
# CONTRACT PINNED HERE
#   1. verify_infer_requirement maps a check command string to the capability
#      it needs (live > ddev > docker > network > none) — pure and table-like;
#   2. capability detection is a PROBE of the runner (overridable via
#      NWP_VERIFY_CAPS for tests/operators), and `live` is NEVER auto-granted:
#      CI must not probe production, only NWP_VERIFY_LIVE=1 unlocks it;
#   3. an explicit `machine.requires:` key in the registry beats inference;
#   4. in ci mode an unmet requirement means SKIP — with reason, distinct from
#      pass and from fail — and the pass rate + 98% verdict are computed over
#      the RUNNABLE subset only;
#   5. the registry path is overridable via NWP_VERIFICATION_FILE so tests can
#      exercise the real engine against a tiny fixture.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    VERIFY="$REPO_ROOT/scripts/commands/verify.sh"
    MINI="$BATS_TEST_TMPDIR/repo"
    SHIM="$BATS_TEST_TMPDIR/shim"
}

# Call one function from the sourced (not dispatched) verify.sh.
# Extra env goes in as `VAR=value` pairs before the function call string.
_vfn() {
    run bash -c "source '$VERIFY' && $1"
}

################################################################################
# 1. Requirement inference — pure function over the command string
################################################################################

@test "infer: ddev commands need ddev" {
    _vfn "verify_infer_requirement 'ddev exec drush status'"
    [ "$status" -eq 0 ]
    [ "$output" = "ddev" ]
}

@test "infer: the {site} placeholder means a test site, which means ddev" {
    _vfn "verify_infer_requirement 'pl backup {site} --dry-run'"
    [ "$output" = "ddev" ]
}

@test "infer: site creation (pl init / pl install) needs ddev" {
    _vfn "verify_infer_requirement 'pl install d verify-x --auto'"
    [ "$output" = "ddev" ]
    _vfn "verify_infer_requirement 'pl init sitename'"
    [ "$output" = "ddev" ]
}

@test "infer: docker commands need docker" {
    _vfn "verify_infer_requirement 'docker ps -a'"
    [ "$output" = "docker" ]
}

@test "infer: probing a live nwpcode.org site needs live" {
    _vfn "verify_infer_requirement 'curl -fsS https://ss.nwpcode.org/login'"
    [ "$output" = "live" ]
}

@test "infer: ssh to a server needs live" {
    _vfn "verify_infer_requirement 'ssh gitlab@avc.nwpcode.org uptime'"
    [ "$output" = "live" ]
}

@test "infer: an ssh/scp REMOTE TARGET is what makes it live, with no estate domain" {
    _vfn "verify_infer_requirement 'ssh deploy@buildhost uptime'"
    [ "$output" = "live" ]
    _vfn "verify_infer_requirement 'scp report.txt deploy@buildhost:/tmp/'"
    [ "$output" = "live" ]
    _vfn "verify_infer_requirement 'ssh box.example.net systemctl is-active cron'"
    [ "$output" = "live" ]
}

# --- false-positive pins: NAMING ssh is not USING it ------------------------
#
# Measured regression. A bare ` ssh ` token classified live:4 ("Test SSH access
# to provisioned server", whose basic commands are `which ssh` and a `test -f`)
# as needing production: it went from PASSED on main to SKIPPED, i.e. coverage
# silently removed from the denominator. These are the real command strings
# from .verification.yml; every one of them must stay runnable.

@test "REGRESSION live:4 — 'which ssh' is a binary probe, not production access" {
    _vfn "verify_infer_requirement \"which ssh 2>&1 || echo 'ssh not found'\""
    [ "$output" = "none" ]
}

@test "REGRESSION — 'ssh -V', grepping for ssh, and ~/.ssh are all local" {
    _vfn "verify_infer_requirement 'ssh -V 2>&1 | head -1'"
    [ "$output" = "none" ]
    _vfn "verify_infer_requirement \"grep -qE 'ssh|SSH|server_ip' scripts/commands/live.sh\""
    [ "$output" = "none" ]
    _vfn "verify_infer_requirement 'test -d ~/.ssh && ls ~/.ssh/*.pub 2>/dev/null | head -1'"
    [ "$output" = "none" ]
    _vfn "verify_infer_requirement 'which rsync ssh curl 2>&1'"
    [ "$output" = "none" ]
    _vfn "verify_infer_requirement 'bash -n scripts/commands/setup-ssh.sh'"
    [ "$output" = "none" ]
}

@test "REGRESSION — the whole live:4 item resolves runnable against the REAL registry" {
    # The end-to-end form of the pin above: whatever the manifest says today,
    # this item must not be classified into a capability a CI slot lacks.
    run bash -c "source '$VERIFY' && verify_resolve_item_requirement live 4 basic"
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

@test "infer: generic outbound http is network, not live" {
    _vfn "verify_infer_requirement 'curl -s https://api.github.com/zen'"
    [ "$output" = "network" ]
}

@test "infer: plain local commands need nothing" {
    _vfn "verify_infer_requirement 'pl todo check --json'"
    [ "$output" = "none" ]
    _vfn "verify_infer_requirement 'bash -n scripts/commands/setup.sh'"
    [ "$output" = "none" ]
}

@test "infer: highest requirement wins inside one command" {
    # live outranks ddev outranks docker outranks network
    _vfn "verify_infer_requirement 'ddev exec curl https://example.com/'"
    [ "$output" = "ddev" ]
    _vfn "verify_infer_requirement 'docker ps && curl -fsS https://git.nwpcode.org/'"
    [ "$output" = "live" ]
}

################################################################################
# 2. Capability detection — a probe of THIS runner, overridable, live opt-in
################################################################################

@test "caps: NWP_VERIFY_CAPS set-but-empty means the runner has nothing" {
    _vfn "NWP_VERIFY_CAPS= ; verify_detect_capabilities
          verify_cap_met none || exit 1
          verify_cap_met ddev && exit 1
          verify_cap_met docker && exit 1
          verify_cap_met live && exit 1
          verify_cap_met network && exit 1
          exit 0"
    [ "$status" -eq 0 ]
}

@test "caps: an explicit NWP_VERIFY_CAPS list is authoritative" {
    _vfn "NWP_VERIFY_CAPS=ddev,docker ; verify_detect_capabilities
          verify_cap_met ddev || exit 1
          verify_cap_met docker || exit 1
          verify_cap_met live && exit 1
          verify_cap_met network && exit 1
          exit 0"
    [ "$status" -eq 0 ]
}

@test "caps: detection probes PATH — a failing docker shim yields no docker and no ddev" {
    mkdir -p "$SHIM"
    printf '#!/bin/sh\nexit 1\n' > "$SHIM/docker"
    printf '#!/bin/sh\nexit 0\n' > "$SHIM/ddev"
    chmod +x "$SHIM/docker" "$SHIM/ddev"
    run bash -c "export PATH='$SHIM:/usr/bin:/bin'
                 source '$VERIFY' && verify_detect_capabilities
                 verify_cap_met docker && exit 1
                 verify_cap_met ddev && exit 1   # ddev without usable docker is not a capability
                 verify_cap_met live && exit 1
                 exit 0"
    [ "$status" -eq 0 ]
}

@test "caps: working docker+ddev shims yield both caps — live stays absent" {
    mkdir -p "$SHIM"
    printf '#!/bin/sh\nexit 0\n' > "$SHIM/docker"
    printf '#!/bin/sh\nexit 0\n' > "$SHIM/ddev"
    chmod +x "$SHIM/docker" "$SHIM/ddev"
    run bash -c "export PATH='$SHIM:/usr/bin:/bin'
                 source '$VERIFY' && verify_detect_capabilities
                 verify_cap_met docker || exit 1
                 verify_cap_met ddev || exit 1
                 verify_cap_met live && exit 1   # live is NEVER auto-detected
                 exit 0"
    [ "$status" -eq 0 ]
}

@test "caps: live is granted only by the NWP_VERIFY_LIVE=1 opt-in" {
    mkdir -p "$SHIM"
    printf '#!/bin/sh\nexit 1\n' > "$SHIM/docker"
    chmod +x "$SHIM/docker"
    run bash -c "export PATH='$SHIM:/usr/bin:/bin' NWP_VERIFY_LIVE=1
                 source '$VERIFY' && verify_detect_capabilities
                 verify_cap_met live || exit 1
                 exit 0"
    [ "$status" -eq 0 ]
}

################################################################################
# 3. Explicit `requires:` in the registry beats inference
################################################################################

_requires_fixture() {
    cat > "$BATS_TEST_TMPDIR/req.yml" <<'EOF'
version: 3
config:
  freshness_days: 90
statistics:
  total_items: 2
features:
  demo:
    name: Demo feature
    description: fixture
    files:
    - pl
    checklist:
    - text: trivial command but explicitly tagged as needing ddev
      completed: false
      machine:
        automatable: true
        requires: ddev
        checks:
          basic:
            commands:
            - cmd: 'true'
              expect_exit: 0
              timeout: 10
        state:
          verified: false
    - text: untagged item whose commands span docker and ddev
      completed: false
      machine:
        automatable: true
        checks:
          basic:
            commands:
            - cmd: docker ps
              expect_exit: 0
              timeout: 10
            - cmd: ddev list
              expect_exit: 0
              timeout: 10
        state:
          verified: false
EOF
}

@test "explicit machine.requires wins over inference" {
    _requires_fixture
    run bash -c "export NWP_VERIFICATION_FILE='$BATS_TEST_TMPDIR/req.yml'
                 source '$VERIFY' && verify_resolve_item_requirement demo 0 basic"
    [ "$status" -eq 0 ]
    [ "$output" = "ddev" ]
}

@test "without an explicit tag, resolution takes the max over the item's commands" {
    _requires_fixture
    run bash -c "export NWP_VERIFICATION_FILE='$BATS_TEST_TMPDIR/req.yml'
                 source '$VERIFY' && verify_resolve_item_requirement demo 1 basic"
    [ "$status" -eq 0 ]
    [ "$output" = "ddev" ]
}

# --- the yq reader's own edges (get_item_requires is yq, not awk: ADR-0015) ---

@test "get_item_requires prints NOTHING for an item with no requires: key" {
    _requires_fixture
    run bash -c "export NWP_VERIFICATION_FILE='$BATS_TEST_TMPDIR/req.yml'
                 source '$VERIFY' && get_item_requires demo 1"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "get_item_requires reads the tagged item and only that item" {
    _requires_fixture
    run bash -c "export NWP_VERIFICATION_FILE='$BATS_TEST_TMPDIR/req.yml'
                 source '$VERIFY' && get_item_requires demo 0"
    [ "$output" = "ddev" ]
}

@test "get_item_requires is silent for an unknown feature or out-of-range index" {
    _requires_fixture
    run bash -c "export NWP_VERIFICATION_FILE='$BATS_TEST_TMPDIR/req.yml'
                 source '$VERIFY' && get_item_requires no_such_feature 0; get_item_requires demo 99"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a LIST requires: value emits one requirement per line and the strictest wins" {
    cat > "$BATS_TEST_TMPDIR/list.yml" <<'EOF'
version: 3
config:
  freshness_days: 90
features:
  demo:
    name: Demo feature
    description: fixture
    files:
    - pl
    checklist:
    - text: needs a ddev site AND a live probe
      completed: false
      machine:
        automatable: true
        requires: [ddev, live]
        checks:
          basic:
            commands:
            - cmd: 'true'
              expect_exit: 0
              timeout: 10
        state:
          verified: false
EOF
    run bash -c "export NWP_VERIFICATION_FILE='$BATS_TEST_TMPDIR/list.yml'
                 source '$VERIFY' && get_item_requires demo 0"
    [ "${lines[0]}" = "ddev" ]
    [ "${lines[1]}" = "live" ]
    # live outranks ddev, so a ddev-capable runner must still skip this check.
    run bash -c "export NWP_VERIFICATION_FILE='$BATS_TEST_TMPDIR/list.yml'
                 source '$VERIFY' && verify_resolve_item_requirement demo 0 basic"
    [ "$output" = "live" ]
}

@test "get_item_requires survives the REAL 33k-line registry (no tags today, no noise)" {
    # Guards against a yq path that only works on tiny fixtures: the production
    # registry carries no requires: keys yet, so every read must be EMPTY and
    # quiet — not an error message, not a stray 'null'.
    run bash -c "source '$VERIFY' && get_item_requires setup 0"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

################################################################################
# 4. Integration: real verify.sh ci against a tiny fixture registry
#
# Same disposable-mini-repo pattern as test-verify-ci-bootstrap.bats: real
# verify.sh + real verify-runner.sh, throwaway PROJECT_ROOT, create_test_site
# shimmed to fail deterministically (which is what a clean runner does anyway).
################################################################################

_mini_repo() {
    mkdir -p "$MINI/scripts/commands" "$MINI/lib"

    cp "$VERIFY" "$MINI/scripts/commands/verify.sh"
    chmod +x "$MINI/scripts/commands/verify.sh"

    local f b
    for f in "$REPO_ROOT"/lib/*.sh; do
        b="$(basename "$f")"
        [[ "$b" == "verify-runner.sh" ]] && continue
        ln -sf "$f" "$MINI/lib/$b"
    done

    # Real runner, with exactly one function made deterministic: a clean CI
    # slot cannot create a test site, and this test must never create a real
    # one on a developer machine either.
    cat > "$MINI/lib/verify-runner.sh" <<EOF
source "$REPO_ROOT/lib/verify-runner.sh"
create_test_site() { return 1; }
EOF

    cp "$REPO_ROOT/example.nwp.yml" "$MINI/example.nwp.yml"

    # Three items: one runnable anywhere, one needing ddev (inferred), one
    # trivially-runnable but explicitly tagged live.
    cat > "$MINI/.verification.yml" <<'EOF'
version: 3
config:
  machine_engine: verify.sh
  freshness_days: 90
  test_site:
    prefix: bats-test-req
    cleanup_on_success: true
    preserve_on_failure: false
statistics:
  total_items: 3
  machine:
    verified: 0
    coverage_percent: 0.0
  human:
    verified: 0
    coverage_percent: 0.0
  fully_verified: 0
features:
  demo:
    name: Demo feature
    description: fixture
    files:
    - pl
    checklist:
    - text: a check any machine can run
      completed: false
      machine:
        automatable: true
        checks:
          basic:
            commands:
            - cmd: 'true'
              expect_exit: 0
              timeout: 10
        state:
          verified: false
          verified_at: ''
          depth: basic
          duration_seconds: 0
    - text: a check that needs a ddev runtime
      completed: false
      machine:
        automatable: true
        checks:
          basic:
            commands:
            - cmd: ddev --version
              expect_exit: 0
              timeout: 10
        state:
          verified: false
          verified_at: ''
          depth: basic
          duration_seconds: 0
    - text: a trivial command explicitly tagged as needing a live site
      completed: false
      machine:
        automatable: true
        requires: live
        checks:
          basic:
            commands:
            - cmd: 'true'
              expect_exit: 0
              timeout: 10
        state:
          verified: false
          verified_at: ''
          depth: basic
          duration_seconds: 0
EOF
}

# $1 = value for NWP_VERIFY_CAPS (empty string = "runner has nothing")
# $@ from $2 = extra args to `verify.sh ci`
_run_ci_caps() {
    local caps="$1"; shift
    run env NO_COLOR=1 NWP_VERIFY_CAPS="$caps" \
        bash "$MINI/scripts/commands/verify.sh" ci --depth=basic "$@"
}

@test "CORE: an unrunnable check is SKIPPED with its reason, not FAILED" {
    _mini_repo
    _run_ci_caps ""

    [[ "$output" == *"requires ddev"* ]] || {
        echo "--- verify.sh ci output ---" >&2
        echo "$output" >&2
        echo "---------------------------" >&2
        echo "The ddev-needing check was not skipped-with-reason. On a runner" >&2
        echo "without ddev it must read as 'cannot run here', never as red and" >&2
        echo "never as silent green." >&2
        return 1
    }
    [[ "$output" == *"requires live"* ]]
    [[ "$output" != *"[FAIL]"* ]]
}

@test "CORE: pass rate and the 98% verdict are computed over the runnable subset" {
    _mini_repo
    _run_ci_caps ""

    # 1 of 3 items is runnable here; it passes; the job must be green at 100%.
    [ "$status" -eq 0 ] || {
        echo "$output" >&2
        echo "status=$status — two structurally-unrunnable checks dragged the" >&2
        echo "verdict below threshold; the denominator must be the runnable set." >&2
        return 1
    }
    [[ "$output" == *"100%"* ]]
}

@test "the ci summary reports total, runnable, passed, failed, and unrunnable-skips distinctly" {
    _mini_repo
    _run_ci_caps ""

    [[ "$output" == *"Runnable"* ]]
    [[ "$output" == *"Skipped (unrunnable)"* ]]
}

@test "granting the capability makes the same check execute instead of skip" {
    _mini_repo
    mkdir -p "$SHIM"
    printf '#!/bin/sh\necho "ddev shim v0"\nexit 0\n' > "$SHIM/ddev"
    chmod +x "$SHIM/ddev"

    run env NO_COLOR=1 NWP_VERIFY_CAPS="ddev" PATH="$SHIM:$PATH" \
        bash "$MINI/scripts/commands/verify.sh" ci --depth=basic

    # The ddev item ran (and passed via the shim); the live item still skipped.
    [[ "$output" != *"requires ddev"* ]]
    [[ "$output" == *"requires live"* ]]
    [ "$status" -eq 0 ]
}

@test "with no ddev capability, ci does not attempt to create a test site" {
    _mini_repo
    _run_ci_caps ""
    # The old path burned time calling create_test_site just to fail; with no
    # ddev there is nothing a test site could run.
    [[ "$output" != *"Creating test site"* ]]
}

@test "NWP_VERIFICATION_FILE points the whole engine at an alternate registry" {
    _mini_repo
    cat > "$BATS_TEST_TMPDIR/alt.yml" <<'EOF'
version: 3
config:
  freshness_days: 90
statistics:
  total_items: 1
features:
  altfeat:
    name: Alternate registry feature
    description: fixture
    files:
    - pl
    checklist:
    - text: alt check
      completed: false
      machine:
        automatable: true
        checks:
          basic:
            commands:
            - cmd: 'true'
              expect_exit: 0
              timeout: 10
        state:
          verified: false
EOF
    run env NO_COLOR=1 NWP_VERIFY_CAPS="" \
        NWP_VERIFICATION_FILE="$BATS_TEST_TMPDIR/alt.yml" \
        bash "$MINI/scripts/commands/verify.sh" ci --depth=basic
    [[ "$output" == *"[altfeat]"* ]]
    [[ "$output" != *"[demo]"* ]]
}

@test "junit output reports unrunnable checks as <skipped>, not <failure>" {
    _mini_repo
    _run_ci_caps "" --junit
    [ "$status" -eq 0 ]

    local junit="$MINI/.logs/verification/junit.xml"
    [ -f "$junit" ] || {
        echo "$output" >&2
        echo "junit.xml not found at $junit" >&2
        return 1
    }
    grep -q '<skipped' "$junit"
    ! grep -q '<failure' "$junit"
}
