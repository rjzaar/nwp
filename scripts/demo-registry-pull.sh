#!/bin/bash
################################################################################
# scripts/demo-registry-pull.sh — pull the invite-code registry OFF its home
# (ops#328 D1).
#
# The registry has exactly ONE writable home (servers/live/demo/
# registry-home.yml), which is deliberately a small always-on box — so this
# script exists to make sure the registry SURVIVES that box dying. It runs on
# the backup puller machine (the same box that runs the demo nightly crons; see
# servers/live/demo/install-registry-pull-on-met.sh, which installs it) and
# mirrors the home's registry files into a local backup dir, keeping dated
# snapshots.
#
# What it copies, and what it deliberately does NOT:
#   * demo-codes.json               the working registry (hashes only)
#   * demo-codes-purged.json        the purge archive (audit trail)
#   * demo-codes*.pre-reconcile-*   reconcile-time backups
#   * demo-reset.log                the ledger (issue/revoke/reconcile/override)
#   * NOT demo-invites/             invitation drafts hold PLAINTEXT codes;
#                                   plaintext never leaves the home.
#
# Fail-closed: any rsync failure exits non-zero (cron surfaces it). An
# UNREACHABLE home is a failed backup, never a quiet no-op.
#
# No secrets: the transport key is the puller's existing one, referenced by
# path only. Everything here is overridable for tests (NWP_* knobs — an
# untestable host-specific script is a check nobody has seen fail).
################################################################################
set -euo pipefail

SITE="${NWP_DEMO_REGISTRY_PULL_SITE:-nwd}"
# The registry home's ssh endpoint (user@addr). The default is the home
# declared in servers/live/demo/registry-home.yml, by its mesh address.
SRC="${NWP_DEMO_REGISTRY_PULL_SRC:-rob@100.64.0.2}"
KEY="${NWP_DEMO_REGISTRY_PULL_KEY:-$HOME/.ssh/id_ed25519_remote}"
DEST="${NWP_DEMO_REGISTRY_PULL_DEST:-$HOME/backups/demo-registry-home/$SITE}"
SNAP_KEEP_DAYS="${NWP_DEMO_REGISTRY_PULL_KEEP:-60}"
RSYNC="${NWP_DEMO_REGISTRY_PULL_RSYNC:-rsync}"

[[ -r "$KEY" ]] || { echo "ERROR: transport key $KEY not readable — CANNOT PULL" >&2; exit 2; }

mkdir -p "$DEST/snapshots"

"$RSYNC" -a --timeout=60 \
    --include='demo-codes*' --include='demo-reset.log' --exclude='*' \
    -e "ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20" \
    "${SRC}:nwp/sites/${SITE}/" "$DEST/" \
    || { echo "ERROR: pull from ${SRC} failed — the registry home is NOT backed up" >&2; exit 1; }

# Dated snapshot of the working registry (only when it changed), pruned.
if [[ -f "$DEST/demo-codes.json" ]]; then
    snap="$DEST/snapshots/demo-codes.json.$(date -u '+%Y%m%d')"
    if [[ ! -f "$snap" ]] || ! cmp -s "$DEST/demo-codes.json" "$snap"; then
        cp -p "$DEST/demo-codes.json" "$snap"
    fi
    find "$DEST/snapshots" -name 'demo-codes.json.*' -mtime "+${SNAP_KEEP_DAYS}" -delete
fi

echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') pulled ${SITE} registry from ${SRC} -> ${DEST}"
