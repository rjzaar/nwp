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

# ---------------------------------------------------------------------------
# ops#196 — this script is now a BLOCKING dependency of boundary:classify, so
# every way it can misreport wedges unrelated merge requests. Each case below
# was observed on the pre-fix script.
# ---------------------------------------------------------------------------

@test "NEGATIVE CONTROL: a refusal exits NON-ZERO through the flock wrapper" {
    # The serialising wrapper must PROPAGATE the child's status. Written as
    # `if flock …; then exit 0; fi; rc=$?` it does not: bash reports 0 for an
    # if-statement whose branch was not taken, so every REFUSED bootstrap
    # became exit 0 — the silent-non-provisioning failure this guards.
    _run_bootstrap "file://${FAKEBIN}" \
        "0000000000000000000000000000000000000000000000000000000000000000"
    [ "$status" -ne 0 ]
}

@test "an unreachable artifact is a NAMED runner-side fault, not a bare curl code" {
    # Pre-fix: `curl: (7) Failed to connect` and exit 7, which reads to the MR
    # author as "my branch broke CI".
    _run_bootstrap "https://127.0.0.1:1/no-such-yq" "$FAKESHA"
    [ "$status" -eq 1 ]
    [[ "$output" == *"RUNNER-SIDE fault"* ]]
}

@test "a GOOD cache still provisions with the network down (no destroy-then-fetch)" {
    mkdir -p "${CACHE}/yq-vtest"
    cp "$FAKEBIN" "${CACHE}/yq-vtest/yq"
    chmod +x "${CACHE}/yq-vtest/yq"
    _run_bootstrap "https://127.0.0.1:1/no-such-yq" "$FAKESHA"
    [ "$status" -eq 0 ]
    [ -x "${CACHE}/yq-vtest/yq" ]
}

@test "a concurrent REFUSED bootstrap does not delete a verified cache" {
    # Pre-fix the bootstrap path began with `rm -rf "$CACHE_DIR"`, so a job
    # that refused an artifact took a sibling job's working binary with it.
    # Reproduced with a slow-curl shim 2026-08-02: "yq: command not found" in
    # a job whose own ensure-yq had reported ready.
    mkdir -p "${CACHE}/yq-vtest"
    cp "$FAKEBIN" "${CACHE}/yq-vtest/yq"
    chmod +x "${CACHE}/yq-vtest/yq"
    _run_bootstrap "file://${FAKEBIN}" \
        "0000000000000000000000000000000000000000000000000000000000000000"
    [ "$status" -ne 0 ]
    [ -x "${CACHE}/yq-vtest/yq" ]
    [ "$(sha256sum "${CACHE}/yq-vtest/yq" | cut -d' ' -f1)" = "$FAKESHA" ]
}

@test "four concurrent bootstraps all succeed and all leave a working binary" {
    local pids=() i rc=0
    for i in 1 2 3 4; do
        env PATH=/usr/bin:/bin \
            NWP_ENSURE_YQ_VER=vtest \
            NWP_ENSURE_YQ_URL="file://${FAKEBIN}" \
            NWP_ENSURE_YQ_SHA256="$FAKESHA" \
            NWP_ENSURE_YQ_CACHE="$CACHE" \
            bash "$SCRIPT" > "${BATS_TEST_TMPDIR}/conc.$i.log" 2>&1 &
        pids+=($!)
    done
    for i in "${pids[@]}"; do wait "$i" || rc=1; done
    [ "$rc" -eq 0 ]
    [ -x "${CACHE}/yq-vtest/yq" ]
    [ "$(sha256sum "${CACHE}/yq-vtest/yq" | cut -d' ' -f1)" = "$FAKESHA" ]
}

@test "the version .gitlab-ci.yml hardcodes on PATH matches the version this script installs" {
    # Every yq-needing job does:
    #   - ./scripts/ci/ensure-yq.sh
    #   - export PATH="${HOME}/.cache/nwp-ci/yq-v4.44.1:${PATH}"
    # The cache path is spelled out in FOUR jobs. Bump YQ_VER without bumping
    # them and the bootstrap succeeds while PATH points at an empty directory:
    # boundary:classify then fails closed on every MR for a reason no one can
    # see in the job log. Pin the two together.
    ver="$(grep -oE 'NWP_ENSURE_YQ_VER:-v[0-9.]+' "$SCRIPT" | head -1 | sed 's/.*:-//')"
    [ -n "$ver" ]
    n="$(grep -c "yq-${ver}:\\\${PATH}" "${REAL_ROOT}/.gitlab-ci.yml")"
    total="$(grep -c 'nwp-ci/yq-' "${REAL_ROOT}/.gitlab-ci.yml")"
    [ "$n" -eq "$total" ]
    [ "$total" -ge 1 ]
}

@test "the pin here matches the pin pl setup installs" {
    # One version of the truth: setup.sh install_yq and ensure-yq.sh must not
    # drift apart, or CI verifies different bytes than workstations run.
    script_ver="$(grep -oE 'NWP_ENSURE_YQ_VER:-v[0-9.]+' "$SCRIPT" | head -1 | cut -d- -f2-)"
    grep -q "${script_ver#v}\|${script_ver}" "${REAL_ROOT}/scripts/commands/setup.sh"
}
