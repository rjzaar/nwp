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
# Pause without uninstalling:  pl loop disable rag-sync   (or touch ~/nwp/.rag-sync-paused)
# Resume:                      pl loop enable  rag-sync   (or rm    ~/nwp/.rag-sync-paused)
# Install/remove the schedule: pl loop schedule install|remove --execute
#
# NOTE the WRITE kill (`pl loop disable all` / ~/nwp/.loop-paused) does NOT stop
# this script — see the gate block below and ops#230.
################################################################################
set -uo pipefail

# Cron has a minimal PATH; yq lives in ~/.local/bin, ddev in /usr/local/bin.
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

NWP_DIR="${NWP_DIR:-$HOME/nwp}"
LOG_DIR="$NWP_DIR/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/rag-sync.log"

ts(){ date -u +%FT%TZ; }

# Wrapper-enforced part gate (lib/loop-parts.sh, deep-audit C0). rag-sync is a
# distinct part of the self-healing loop; an operator can disable it on its own
# via `pl loop disable rag-sync` or the legacy .rag-sync-paused sentinel. If the
# library is absent (older checkout) we fall back to the legacy sentinel only,
# which is fail-safe.
#
# SPLIT GATES ARE NOW THE BEHAVIOUR, NOT A FLAG (ops#230)
# -------------------------------------------------------
# The WRITE kill (`.loop-paused` / parts.state all=disabled) exists to stop the
# loop CHANGING things — opening MRs, deploying. rag-sync does neither: it reads
# fleet state and files/updates nwp/ops issues. Lumping it under the same switch
# cost 8 nights of oversight blackout in July 2026 — and then, because the fix
# shipped as an opt-in flag that defaulted to OFF, it happened AGAIN and ran to
# 16 nights (2026-07-18 → 2026-08-02), during which guzzle advisories landed,
# three sites flipped AMBER→RED, and no issue was ever updated.
#
# lib/loop-parts.sh now classifies rag-sync as an `observe` part, so the write
# kill structurally cannot reach it: only the separate OVERSIGHT kill
# (`.oversight-paused` / parts.state oversight=disabled) or rag-sync's own
# switch stop it. NWP_LOOP_UNIFIED_GATES=1 restores the old conflation, and this
# wrapper says so in the log when it does.
#
# Either way the skip is recorded with a REASON, so `pl todo`'s
# check_rag_sync_freshness and `pl rag`'s LOOP banner can tell "switched off"
# from "broken" — for 16 nights both looked identical from outside.
export NWP_ROOT="$NWP_DIR"
LOOP_PARTS_LIB="$NWP_DIR/lib/loop-parts.sh"
if [ -f "$LOOP_PARTS_LIB" ]; then
  # shellcheck source=/dev/null
  . "$LOOP_PARTS_LIB"
  if ! loop_part_enabled rag-sync; then
    echo "$(ts) rag-sync DISABLED — skipping. Reason: $(loop_part_disabled_reason rag-sync). While this holds the fleet's RAG grade does not reach nwp/ops; 'pl rag' says LOOP DARK and 'pl todo' files an RSY item." >> "$LOG"
    exit 0
  fi
  if loop_write_killed; then
    echo "$(ts) WRITE kill is set ($(loop_write_kill_reason)) — rag-sync is an 'observe' part and CONTINUES (ops#230: a write-kill must not stop oversight)" >> "$LOG"
  fi
  if loop_gates_unified; then
    echo "$(ts) WARNING: NWP_LOOP_UNIFIED_GATES=1 — the pre-ops#230 conflation is armed on this host; a write-kill CAN blind oversight here" >> "$LOG"
  fi
elif [ -f "$NWP_DIR/.rag-sync-paused" ]; then
  echo "$(ts) paused (.rag-sync-paused present) — skipping" >> "$LOG"
  exit 0
fi

# Single-instance guard (ops#37): a slow `pl rag` run must not overlap the next
# cron tick and double-file issues. Non-blocking; a second instance exits clean.
LOCK="$NWP_DIR/.rag-sync.lock"
exec 201>"$LOCK"
if ! flock -n 201; then
  echo "$(ts) another rag-sync is running (lock=$LOCK) — skipping" >> "$LOG"
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
