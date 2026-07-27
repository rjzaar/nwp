#!/usr/bin/env bats
# ensure-bats.sh — the runner bootstrap for bats-core (see that script's header).
#
# The bootstrap path is exercised against a LOCAL fixture repo (no network),
# via the NWP_ENSURE_BATS_* overrides that exist for exactly this test. The
# sha-pin test is the load-bearing one: it proves the supply-chain check can
# actually refuse, so a moved upstream tag cannot ride in on a green job.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/ci/ensure-bats.sh"

setup() {
    TESTDIR="$(mktemp -d "${BATS_TMPDIR}/ensure-bats.XXXXXX")"
    CACHE="${TESTDIR}/cache"

    # Fixture upstream: a repo shaped like bats-core (executable bin/bats).
    FIXTURE="${TESTDIR}/fixture"
    git init -q "$FIXTURE"
    mkdir -p "${FIXTURE}/bin"
    printf '#!/usr/bin/env bash\necho fixture-bats\n' > "${FIXTURE}/bin/bats"
    chmod +x "${FIXTURE}/bin/bats"
    git -C "$FIXTURE" -c user.email=t@t -c user.name=t add -A
    git -C "$FIXTURE" -c user.email=t@t -c user.name=t commit -qm fixture
    git -C "$FIXTURE" tag vtest
    FIXTURE_SHA="$(git -C "$FIXTURE" rev-parse HEAD)"

    # A PATH that has git and coreutils but NO bats, so the bootstrap branch
    # runs. Symlinks, not copies — we are hiding bats, not rebuilding an OS.
    NOBATS="${TESTDIR}/nobats-bin"
    mkdir -p "$NOBATS"
    local tool
    for tool in bash git rm mkdir dirname mktemp; do
        ln -s "$(command -v "$tool")" "${NOBATS}/${tool}"
    done
}

teardown() {
    rm -rf "$TESTDIR"
}

run_bootstrap() { # $1=repo $2=pinned-sha
    PATH="$NOBATS" \
    NWP_ENSURE_BATS_VER=vtest \
    NWP_ENSURE_BATS_COMMIT="$2" \
    NWP_ENSURE_BATS_REPO="$1" \
    NWP_ENSURE_BATS_CACHE="$CACHE" \
    run bash "$SCRIPT"
}

@test "host with bats: no bootstrap, no cache created" {
    NWP_ENSURE_BATS_CACHE="$CACHE" run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no bootstrap"* ]]
    [ ! -e "$CACHE" ]
}

@test "bootstrap from a correctly-pinned repo succeeds and yields bin/bats" {
    run_bootstrap "$FIXTURE" "$FIXTURE_SHA"
    [ "$status" -eq 0 ]
    [ -x "${CACHE}/bats-vtest/bin/bats" ]
    [ "$(git -C "${CACHE}/bats-vtest" rev-parse HEAD)" = "$FIXTURE_SHA" ]
}

@test "NEGATIVE CONTROL: a moved tag is REFUSED and leaves no cache behind" {
    run_bootstrap "$FIXTURE" "0000000000000000000000000000000000000000"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSED"* ]]
    [ ! -e "${CACHE}/bats-vtest" ]
}

@test "a verified checkout without bin/bats is REFUSED" {
    local bare="${TESTDIR}/no-bin"
    git init -q "$bare"
    echo x > "${bare}/README"
    git -C "$bare" -c user.email=t@t -c user.name=t add -A
    git -C "$bare" -c user.email=t@t -c user.name=t commit -qm x
    git -C "$bare" tag vtest
    run_bootstrap "$bare" "$(git -C "$bare" rev-parse HEAD)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no executable bin/bats"* ]]
    [ ! -e "${CACHE}/bats-vtest" ]
}
