#!/usr/bin/env bats
# scripts/ci/ensure-yq.sh — the pinned yq bootstrap (ops#165).
#
# Same contract as ensure-bats.sh, proven the same way: the sha pin must be
# shown ABLE TO FAIL (a gate that can't go red is decoration), and a refused
# artifact must leave no cache behind for a later job to trust. Uses the
# NWP_ENSURE_YQ_* overrides that exist for exactly this test; the "download"
# is a local file:// fixture so no network is touched.

setup() {
    REAL_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
    SCRIPT="${REAL_ROOT}/scripts/ci/ensure-yq.sh"
    CACHE="${BATS_TEST_TMPDIR}/cache"
    FAKEBIN="${BATS_TEST_TMPDIR}/fake-yq"
    printf '#!/bin/sh\necho fake-yq\n' > "$FAKEBIN"
    FAKESHA="$(sha256sum "$FAKEBIN" | awk '{print $1}')"
}

# Run the script with no yq on PATH so the bootstrap path is exercised.
_run_bootstrap() {  # $1=url $2=sha
    run env PATH=/usr/bin:/bin \
        NWP_ENSURE_YQ_VER=vtest \
        NWP_ENSURE_YQ_URL="$1" \
        NWP_ENSURE_YQ_SHA256="$2" \
        NWP_ENSURE_YQ_CACHE="$CACHE" \
        bash "$SCRIPT"
}

@test "host with yq: no bootstrap, no cache created" {
    command -v yq >/dev/null || skip "needs host yq for the no-op path"
    NWP_ENSURE_YQ_CACHE="$CACHE" run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no bootstrap"* ]]
    [ ! -d "$CACHE" ]
}

@test "bootstrap from a correctly-pinned artifact succeeds and yields an executable yq" {
    _run_bootstrap "file://${FAKEBIN}" "$FAKESHA"
    [ "$status" -eq 0 ]
    [ -x "${CACHE}/yq-vtest/yq" ]
}

@test "NEGATIVE CONTROL: a sha mismatch is REFUSED and leaves no cache behind" {
    _run_bootstrap "file://${FAKEBIN}" \
        "0000000000000000000000000000000000000000000000000000000000000000"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSED"* ]]
    [ ! -e "${CACHE}/yq-vtest/yq" ]
}

@test "a poisoned cache is re-verified, not trusted" {
    mkdir -p "${CACHE}/yq-vtest"
    printf '#!/bin/sh\necho poisoned\n' > "${CACHE}/yq-vtest/yq"
    chmod +x "${CACHE}/yq-vtest/yq"
    _run_bootstrap "file://${FAKEBIN}" "$FAKESHA"
    [ "$status" -eq 0 ]
    # The poisoned file must have been replaced by the verified one.
    [ "$(sha256sum "${CACHE}/yq-vtest/yq" | awk '{print $1}')" = "$FAKESHA" ]
}

@test "the pin here matches the pin pl setup installs" {
    # One version of the truth: setup.sh install_yq and ensure-yq.sh must not
    # drift apart, or CI verifies different bytes than workstations run.
    script_ver="$(grep -oE 'NWP_ENSURE_YQ_VER:-v[0-9.]+' "$SCRIPT" | head -1 | cut -d- -f2-)"
    grep -q "${script_ver#v}\|${script_ver}" "${REAL_ROOT}/scripts/commands/setup.sh"
}
