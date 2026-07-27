#!/usr/bin/env bash
################################################################################
# ensure-bats.sh — bootstrap a pinned bats-core onto a runner that has none
################################################################################
#
# WHY: the `nwp`-tagged runners are SHELL executors, so the `apt-get install
# bats` line in before_script is a permission-denied no-op unless the host was
# provisioned by hand. The primary runner was; the fallback runner (registered 2026-07-27) was
# not, and every bats-needing job that landed there died in preflight —
# main pipeline 1224 (test:integration) and MR !221 (lint:secrets) went red on
# runner ASSIGNMENT, not on the change under test.
#
# This is the same idiom as the pinned yq bootstrap in test:unit: fetch once
# into a per-runner cache, verify against a hash recorded HERE, fail closed on
# mismatch. bats-core runs straight from its git checkout (bin/bats), so no
# root and no install step are needed. Verification is the TAG'S COMMIT SHA —
# equivalent to the yq sha256 pin: the bytes you run are addressed by hash,
# not by whatever the tag points at today.
#
# Jobs add the fixed cache path to PATH themselves (a nonexistent PATH entry
# is harmless when the host already has bats):
#   - ./scripts/ci/ensure-bats.sh
#   - export PATH="${HOME}/.cache/nwp-ci/bats-v1.11.0/bin:${PATH}"
#
# Overrides exist ONLY so the unit test can prove the sha check can fail
# (tests/unit/test-ensure-bats.bats) — CI never sets them.
################################################################################

set -euo pipefail

BATS_VER="${NWP_ENSURE_BATS_VER:-v1.11.0}"
BATS_COMMIT="${NWP_ENSURE_BATS_COMMIT:-5da66876b8b619235aee1eb3e54954eaca88059b}"
BATS_REPO="${NWP_ENSURE_BATS_REPO:-https://github.com/bats-core/bats-core}"
CACHE_DIR="${NWP_ENSURE_BATS_CACHE:-${HOME}/.cache/nwp-ci}/bats-${BATS_VER}"

# Host already provisioned (the primary runner): nothing to do, and say so — a silent exit
# reads as "did something" in a CI trace.
if command -v bats >/dev/null 2>&1; then
    echo "ensure-bats: host bats $(bats --version 2>/dev/null || true) present — no bootstrap"
    exit 0
fi

# Cached AND verified from a previous run: reuse. Verify every time — a cache
# poisoned or half-written by a killed job must not pass as provisioned.
if [[ -x "${CACHE_DIR}/bin/bats" ]] \
   && [[ "$(git -C "$CACHE_DIR" rev-parse HEAD 2>/dev/null)" == "$BATS_COMMIT" ]]; then
    echo "ensure-bats: cached ${BATS_VER} verified at ${CACHE_DIR}"
    exit 0
fi

echo "ensure-bats: bootstrapping bats-core ${BATS_VER} into ${CACHE_DIR}"
rm -rf "$CACHE_DIR"
mkdir -p "$(dirname "$CACHE_DIR")"
git clone --quiet --depth 1 --branch "$BATS_VER" "$BATS_REPO" "$CACHE_DIR"

got="$(git -C "$CACHE_DIR" rev-parse HEAD)"
if [[ "$got" != "$BATS_COMMIT" ]]; then
    # Fail CLOSED and leave nothing behind: a tag that moved is exactly the
    # supply-chain event this pin exists to catch.
    rm -rf "$CACHE_DIR"
    echo "ensure-bats: REFUSED — ${BATS_VER} resolved to ${got}, pinned ${BATS_COMMIT}" >&2
    exit 1
fi

[[ -x "${CACHE_DIR}/bin/bats" ]] || {
    rm -rf "$CACHE_DIR"
    echo "ensure-bats: REFUSED — verified checkout has no executable bin/bats" >&2
    exit 1
}

echo "ensure-bats: ${BATS_VER} ready (${got})"
