#!/bin/bash
################################################################################
# rag-sync.sh — cron wrapper for `pl rag --sync-issues --execute` (ops#6 §6).
#
# Stage 1 of the self-healing loop: turn the live RAG state into tracked
# nwp/ops issues (create/update/close), idempotently. Runs daily, just AFTER
# the audit-awareness refresh (~04:00 UTC) so the security signal is current.
#
# This is the dev-side, NON-prod-touching half of §6: it only files/updates
# GitLab issues (via the least-privilege gitlab.ops_note_token in .secrets.yml).
# It does NOT bump packages, deploy, or mark anything agent-eligible.
#
# Pause without uninstalling:  touch ~/nwp/.rag-sync-paused
# Resume:                      rm    ~/nwp/.rag-sync-paused
################################################################################
set -uo pipefail

# Cron has a minimal PATH; yq lives in ~/.local/bin, ddev in /usr/local/bin.
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

NWP_DIR="${NWP_DIR:-$HOME/nwp}"
LOG_DIR="$NWP_DIR/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/rag-sync.log"

ts(){ date -u +%FT%TZ; }

if [ -f "$NWP_DIR/.rag-sync-paused" ]; then
  echo "$(ts) paused (.rag-sync-paused present) — skipping" >> "$LOG"
  exit 0
fi

cd "$NWP_DIR" || { echo "$(ts) ERROR: cannot cd $NWP_DIR" >> "$LOG"; exit 1; }

echo "$(ts) rag-sync start" >> "$LOG"
# `pl rag` exits 3 when any site is RED — that's expected here, not a failure.
./pl rag --sync-issues --execute >> "$LOG" 2>&1
rc=$?
echo "$(ts) rag-sync done (pl rag exit=$rc)" >> "$LOG"
# Treat only a usage/plumbing failure (1) as a cron error; 0 and 3 are normal.
[ "$rc" = "1" ] && exit 1
exit 0
