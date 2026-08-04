#!/usr/bin/env bash
################################################################################
# migrate-oversight-cron.sh — move the oversight (rag-sync) schedule from the
# authoring workstation to the ai-host, verifying before it removes anything.
#
# WHY THIS SCRIPT EXISTS, AND WHY IT IS NOT A VERB
#   `pl loop schedule install --host <role> --execute` already does the install
#   correctly. It cannot COMPLETE on the ai-host because writing
#   /etc/cron.d/nwp-rag-sync needs root there, and this estate deliberately has
#   no passwordless sudo on that host. The only missing ingredient is a human
#   typing a password — so this is an OPERATOR RUNBOOK that calls the verb, not a
#   second implementation of it. Every write below is `pl`; the script contributes
#   ordering, verification and a refusal.
#
#   R4 of ~/central/OPERATING-ANALYSIS-2026-08-04.md: one schedule owner. The
#   oversight cron landed on the workstation only because the ai-host was
#   mid-provision, and a laptop that sleeps is the wrong home for the fleet's
#   only health sweep.
#
# THE SAFETY PROPERTY THAT MATTERS
#   It will NOT remove the workstation's copy until the ai-host's copy is
#   verified present. Oversight has already been silently dark once for 15 days
#   (2026-07-17 → 2026-08-02) because a schedule existed nowhere; a migration
#   that removes before it confirms is how that happens again. If verification
#   fails, BOTH copies remain — duplicate oversight is noisy, absent oversight is
#   invisible, and noisy is the better failure.
#
# USAGE
#   bash scripts/ops/migrate-oversight-cron.sh            # dry run (default)
#   bash scripts/ops/migrate-oversight-cron.sh --execute  # asks for the ai-host sudo
#
#   --user-crontab   install into the ai-host user's crontab instead of
#                    /etc/cron.d (no root needed). Works, but `pl host schedule`
#                    reads system cron.d, so a user crontab is LESS VISIBLE to
#                    the tooling. Prefer the root install; this is the fallback.
#
# EXIT  0 migrated (or dry run) · 1 refused/failed, nothing removed · 2 usage
################################################################################
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 2

EXECUTE=false
USER_CRONTAB=false
for a in "$@"; do
    case "$a" in
        --execute)      EXECUTE=true ;;
        --user-crontab) USER_CRONTAB=true ;;
        -h|--help)      sed -n '3,40p' "$0"; exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
bad()  { printf '  \033[0;31m%s\033[0m\n' "$*"; }
good() { printf '  \033[0;32m%s\033[0m\n' "$*"; }

# The ai-host is resolved from the instance manifest — never a bare hostname,
# per docs/reference/role-vocabulary.md (gitleaks enforces this).
AI_HOST="$(./pl host ai-host 2>/dev/null | tail -1 | tr -d ' ')"
if [ -z "$AI_HOST" ]; then
    bad "cannot resolve role 'ai-host' from the instance manifest — nothing attempted"
    exit 1
fi

say "1/5  Where is oversight scheduled RIGHT NOW?"
LOCAL_N=$(crontab -l 2>/dev/null | grep -c 'rag-sync' || true)
REMOTE_N=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$AI_HOST" \
    'crontab -l 2>/dev/null | grep -c rag-sync; sudo -n cat /etc/cron.d/nwp-rag-sync 2>/dev/null | grep -c rag-sync' \
    2>/dev/null | awk '{s+=$1} END{print s+0}')
info "authoring workstation : ${LOCAL_N} rag-sync line(s)"
info "ai-host              : ${REMOTE_N} rag-sync line(s)"
if [ "${LOCAL_N:-0}" -eq 0 ] && [ "${REMOTE_N:-0}" -eq 0 ]; then
    bad "oversight is scheduled NOWHERE — this script migrates, it does not create."
    info "install it first:  pl loop schedule install --execute"
    exit 1
fi

if [ "$EXECUTE" != true ]; then
    say "DRY RUN — nothing will be changed."
    info "would install on the ai-host, verify it, and only then remove the local copy."
    info "re-run with --execute (you will be asked for the ai-host sudo password)."
    exit 0
fi

say "2/5  Install on the ai-host (via pl, with an interactive sudo)"
if [ "$USER_CRONTAB" = true ]; then
    info "using the USER crontab fallback — less visible to pl host schedule"
    # Read the canonical line from the verb's own dry-run so this script never
    # invents a schedule of its own.
    LINE="$(./pl loop schedule install --host ai-host 2>/dev/null \
            | grep -oE '[0-9*/, ]+ *(root )?/usr/bin/env .*rag-sync\.sh.*' | tail -1 \
            | sed 's/ root / /')"
    if [ -z "$LINE" ]; then bad "could not read the canonical schedule line from pl — refusing to guess"; exit 1; fi
    info "line: ${LINE:0:72}…"
    ssh -t "$AI_HOST" "( crontab -l 2>/dev/null | grep -v 'rag-sync'; echo '$LINE' ) | crontab -" \
        || { bad "user-crontab install failed — nothing removed locally"; exit 1; }
else
    info "running: pl loop schedule install --host ai-host --execute   (sudo will prompt)"
    # -t so the remote sudo can prompt. The verb does the writing.
    ssh -t "$AI_HOST" "cd ~/nwp && ./pl loop schedule install --execute" \
        || { bad "install on the ai-host failed — nothing removed locally"; exit 1; }
fi

say "3/5  VERIFY the ai-host actually has it (before removing anything)"
sleep 2
AFTER_N=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$AI_HOST" \
    'crontab -l 2>/dev/null | grep -c rag-sync; sudo -n cat /etc/cron.d/nwp-rag-sync 2>/dev/null | grep -c rag-sync' \
    2>/dev/null | awk '{s+=$1} END{print s+0}')
info "ai-host now has ${AFTER_N} rag-sync line(s)"
if [ "${AFTER_N:-0}" -lt 1 ]; then
    bad "REFUSING to remove the local copy: the ai-host copy is NOT verified."
    bad "Both copies remain. Duplicate oversight is noisy; absent oversight is invisible."
    exit 1
fi
good "verified"

say "4/5  Remove the workstation copy (now safe)"
if [ "${LOCAL_N:-0}" -gt 0 ]; then
    ./pl loop schedule remove --execute \
        || { bad "removal failed — BOTH copies remain, which is the safe direction"; exit 1; }
else
    info "workstation had none — nothing to remove"
fi

say "5/5  Final state"
info "authoring workstation : $(crontab -l 2>/dev/null | grep -c 'rag-sync' || true) rag-sync line(s)"
info "ai-host              : ${AFTER_N} rag-sync line(s)"
good "oversight now has ONE owner: the ai-host."
info "confirm any time:  pl reconcile   (the oversight-cron row)"
echo ""
info "Record it: add a rollback row noting the move, and that reversing it is"
info "  pl loop schedule install --execute   on the workstation."
