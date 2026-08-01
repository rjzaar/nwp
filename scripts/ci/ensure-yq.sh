#!/usr/bin/env bash
################################################################################
# ensure-yq.sh — bootstrap a pinned yq v4 onto a runner that has none
################################################################################
#
# WHY: the `nwp`-tagged runners are SHELL executors, so `image:` is ignored and
# apt-get in before_script is a permission-denied no-op. yq v4 is the sanctioned
# YAML reader (ADR-0015); jobs that read YAML fail closed without it — which is
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

echo "ensure-yq: bootstrapping yq ${YQ_VER} into ${CACHE_DIR}"
rm -rf "$CACHE_DIR"
mkdir -p "$CACHE_DIR"
curl -fsSL -o "${CACHE_DIR}/yq" "$YQ_URL"

if ! echo "${YQ_SHA256}  ${CACHE_DIR}/yq" | sha256sum -c - >/dev/null 2>&1; then
    # Fail CLOSED and leave nothing behind: a release artifact whose bytes
    # moved is exactly the supply-chain event this pin exists to catch.
    got="$(sha256sum "${CACHE_DIR}/yq" 2>/dev/null | awk '{print $1}')"
    rm -rf "$CACHE_DIR"
    echo "ensure-yq: REFUSED — download sha256 ${got:-<unreadable>} does not match pinned ${YQ_SHA256}" >&2
    exit 1
fi

chmod +x "${CACHE_DIR}/yq"
echo "ensure-yq: ${YQ_VER} ready (${YQ_SHA256})"
