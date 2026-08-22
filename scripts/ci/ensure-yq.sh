#!/usr/bin/env bash
################################################################################
# ensure-yq.sh — bootstrap a pinned yq v4 onto a runner that has none
################################################################################
#
# WHY: the `nwp`-tagged runners are SHELL executors, so `image:` is ignored and
# apt-get in before_script is a permission-denied no-op. yq v4 is the sanctioned
# YAML reader (NWP-ADR-0015); jobs that read YAML fail closed without it — which is
# correct, but only if the job PROVISIONS yq rather than shipping permanently
# red. Four jobs (test:unit, test:verification, lint:secrets, and since ops#165
# boundary:classify) each carried their own copy-pasted inline bootstrap; a
# version/sha bump had to be repeated four times and boundary:classify simply
# never got the block at all — every MR pipeline since its introduction ran it
# without yq, parsed the pair contract to zero surfaces, and went red with
# "CANNOT-VERIFY: the pair contract declares no boundary surfaces at all".
#
# Same idiom as ensure-bats.sh: fetch once into a per-runner cache, verify the
# sha256 recorded HERE before every use, fail closed on mismatch. Same pinned
# release as `pl setup` (scripts/commands/setup.sh install_yq).
#
# Jobs add the fixed cache path to PATH themselves (harmless when the host
# already has yq):
#   - ./scripts/ci/ensure-yq.sh
#   - export PATH="${HOME}/.cache/nwp-ci/yq-v4.44.1:${PATH}"
#
# Overrides exist ONLY so the unit test can prove the sha check can fail —
# CI never sets them.
################################################################################

set -euo pipefail

YQ_VER="${NWP_ENSURE_YQ_VER:-v4.44.1}"
YQ_SHA256="${NWP_ENSURE_YQ_SHA256:-6dc2d0cd4e0caca5aeffd0d784a48263591080e4a0895abe69f3a76eb50d1ba3}"
YQ_URL="${NWP_ENSURE_YQ_URL:-https://github.com/mikefarah/yq/releases/download/${YQ_VER}/yq_linux_amd64}"
CACHE_DIR="${NWP_ENSURE_YQ_CACHE:-${HOME}/.cache/nwp-ci}/yq-${YQ_VER}"

# Host already provisioned: nothing to do, and say so — a silent exit reads as
# "did something" in a CI trace.
if command -v yq >/dev/null 2>&1; then
    echo "ensure-yq: host yq ($(yq --version 2>/dev/null || true)) present — no bootstrap"
    exit 0
fi

# Cached AND verified from a previous run: reuse. Verify every time — a cache
# poisoned or half-written by a killed job must not pass as provisioned.
if [[ -x "${CACHE_DIR}/yq" ]] \
   && echo "${YQ_SHA256}  ${CACHE_DIR}/yq" | sha256sum -c - >/dev/null 2>&1; then
    echo "ensure-yq: cached ${YQ_VER} verified at ${CACHE_DIR}"
    exit 0
fi

################################################################################
# Bootstrap. ops#196 hardening — three ways this used to wedge a legitimate MR:
#
#   1. CONCURRENCY. The `nwp` runners are SHELL executors: every job on the box
#      shares one $HOME, and four jobs bootstrap yq. The old code did
#      `rm -rf "$CACHE_DIR"` and only then downloaded, so a second job that had
#      already passed its cache verification could find the binary deleted
#      underneath it, and a third could download into a directory a fourth had
#      just removed. Reproduced 2026-08-02 with a 2-second curl shim: "cp:
#      cannot create regular file …/yq: No such file or directory", then
#      "yq: command not found" on a job whose provisioning had reported ready.
#      Now: an flock around the whole bootstrap, download to a UNIQUE temp file,
#      verify it there, and install with an atomic `mv`. A good cached binary is
#      never removed — the worst a failed bootstrap can do is leave the previous
#      good one in place.
#   2. NETWORK. `curl -fsSL` with no retry and no timeout turned one transient
#      DNS/TLS blip on the runner into a red gate on somebody's unrelated MR,
#      reported as the bare "curl: (7)". Now: bounded retries, a hard timeout,
#      and a diagnostic that names the runner-side cause.
#   3. SILENT NON-PROVISIONING. The script could exit 0 having not left a usable
#      binary on the cache path the jobs put on PATH. Now there is an explicit
#      post-condition check.
################################################################################

# Serialise concurrent bootstraps on a shared runner $HOME. flock is in
# util-linux and present on every runner we have; if it somehow is not, the
# atomic-install path below is still safe, just less polite.
LOCK_DIR="$(dirname "$CACHE_DIR")"
mkdir -p "$LOCK_DIR"
if command -v flock >/dev/null 2>&1 && [[ -z "${_ENSURE_YQ_LOCKED:-}" ]]; then
    export _ENSURE_YQ_LOCKED=1
    # `rc=$?` AFTER an `if flock …; then … fi` reads 0, not flock's status —
    # bash defines an if-statement with no taken branch as exiting 0. Written
    # that way this wrapper turned every REFUSED bootstrap into exit 0, i.e. it
    # re-created the silent-non-provisioning failure it exists to prevent.
    # Caught by the negative-control test, which is why that test exists.
    rc=0
    flock -w 300 "${LOCK_DIR}/.yq-bootstrap.lock" "$0" "$@" || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "ensure-yq: not provisioned (exit ${rc}) — see the reason above; if none is shown, the 300s bootstrap-lock wait timed out" >&2
        exit "$rc"
    fi
    exit 0
fi

# Another job may have won the lock and finished while we waited.
if [[ -x "${CACHE_DIR}/yq" ]] \
   && echo "${YQ_SHA256}  ${CACHE_DIR}/yq" | sha256sum -c - >/dev/null 2>&1; then
    echo "ensure-yq: ${YQ_VER} provisioned by a concurrent job at ${CACHE_DIR}"
    exit 0
fi

echo "ensure-yq: bootstrapping yq ${YQ_VER} into ${CACHE_DIR}"
mkdir -p "$CACHE_DIR"
tmp="${CACHE_DIR}/.yq.download.$$"
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT

if ! curl -fsSL --retry 3 --retry-delay 2 --retry-connrefused \
          --connect-timeout 15 --max-time 300 -o "$tmp" "$YQ_URL"; then
    echo "ensure-yq: REFUSED — could not download ${YQ_URL}" >&2
    echo "           This is a RUNNER-SIDE fault (no egress / DNS / TLS / rate limit)," >&2
    echo "           not a fault in the merge request. Provision yq ${YQ_VER} on the" >&2
    echo "           runner (pl setup install_yq) or restore its network, then retry." >&2
    exit 1
fi

if ! echo "${YQ_SHA256}  ${tmp}" | sha256sum -c - >/dev/null 2>&1; then
    # Fail CLOSED and install nothing: a release artifact whose bytes moved is
    # exactly the supply-chain event this pin exists to catch. The temp file
    # goes; any previously verified binary stays.
    got="$(sha256sum "$tmp" 2>/dev/null | cut -d' ' -f1)"
    rm -f "$tmp"
    echo "ensure-yq: REFUSED — download sha256 ${got:-<unreadable>} does not match pinned ${YQ_SHA256}" >&2
    [[ -e "${CACHE_DIR}/yq" ]] || rmdir "$CACHE_DIR" 2>/dev/null || true
    exit 1
fi

chmod +x "$tmp"
mv -f "$tmp" "${CACHE_DIR}/yq"      # atomic within one filesystem

# Post-condition: the jobs put ${CACHE_DIR} on PATH and then USE yq. Exiting 0
# without a working binary there is the one thing this script must never do.
if ! "${CACHE_DIR}/yq" --version >/dev/null 2>&1; then
    echo "ensure-yq: REFUSED — ${CACHE_DIR}/yq does not execute after install" >&2
    exit 1
fi
echo "ensure-yq: ${YQ_VER} ready (${YQ_SHA256})"
