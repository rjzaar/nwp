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
#   bash scripts/ops/migrate-oversight-cron.sh --execute
#
#   --user-crontab   force the user-crontab route explicitly.
#
# WHICH ROUTE YOU GET, AND WHY IT MATTERS
#   `pl loop schedule install` has TWO code paths and they land in different
#   places:
#     * invoked remotely as `--host <role>`  → writes /etc/cron.d/<name> (NEEDS ROOT)
#     * invoked ON the host                  → writes that user's crontab (no root)
#   This script runs the verb ON the ai-host over `ssh -t`, so the normal outcome
#   is the USER CRONTAB and there is NO sudo prompt. That works — cron fires it as
#   that user — but `pl host schedule` reads system cron.d, so a user crontab is
#   LESS VISIBLE to the tooling.
#
#   The first version of this script announced "sudo will prompt" and then took a
#   path where sudo was never involved. The operator noticed the missing prompt
#   and asked why. That is the estate's recurring defect in miniature: a message
#   stating the INTENTION of a command rather than the CONSEQUENCE of the state.
#   Step 3 now REPORTS which route actually took effect.
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
    info "re-run with --execute."
    info "NOTE: normally there is NO sudo prompt — the verb runs ON the ai-host and"
    info "writes that user's crontab. Step 3 reports which route actually took effect."
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
    info "running the verb ON the ai-host (writes that user's crontab; sudo only if"
    info "  the verb chooses the /etc/cron.d route)"
    # -t so the remote sudo can prompt. The verb does the writing.
    ssh -t "$AI_HOST" "cd ~/nwp && ./pl loop schedule install --execute" \
        || { bad "install on the ai-host failed — nothing removed locally"; exit 1; }
fi

say "3/5  VERIFY the ai-host actually has it (before removing anything)"
sleep 2
# Count the two possible homes SEPARATELY, so the report says WHERE it landed
# rather than only that something exists somewhere.
read -r USER_N SYS_N < <(ssh -o BatchMode=yes -o ConnectTimeout=10 "$AI_HOST" \
    'printf "%s %s\n" "$(crontab -l 2>/dev/null | grep -c rag-sync)" "$(sudo -n cat /etc/cron.d/nwp-rag-sync 2>/dev/null | grep -c rag-sync)"' \
    2>/dev/null | tail -1)
USER_N=${USER_N:-0}; SYS_N=${SYS_N:-0}
AFTER_N=$(( USER_N + SYS_N ))
info "ai-host: ${USER_N} in the USER crontab, ${SYS_N} in /etc/cron.d"
if [ "$SYS_N" -gt 0 ]; then
    good "landed in /etc/cron.d — visible to \`pl host schedule\`"
elif [ "$USER_N" -gt 0 ]; then
    info "landed in the USER crontab (no root was needed, hence no sudo prompt)."
    info "It WILL run. But \`pl host schedule\` reads system cron.d, so this"
    info "schedule is less visible to the tooling — \`pl loop schedule status\`"
    info "on the ai-host is the reliable reader."
fi
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
echo ""
bad  "A VERIFIED SCHEDULE IS NOT A VERIFIED JOB."
info "The ai-host may never have RUN this sweep. `pl loop schedule status` there"
info "will say UNKNOWN while no log exists — and absence of a log is not evidence"
info "of health. Prove it once, now, rather than discovering it at 04:30:"
info "  ssh <ai-host> 'cd ~/nwp && git pull --ff-only && NWP_RAG_TODO_BUDGET=600 ./scripts/agent-loop/rag-sync.sh'"
info "Also declare the delegation so this host stops reporting NOSCHEDULE:"
info "  yq -i '.settings.loop.oversight_host = \"<ai-host short hostname>\"' nwp.yml"
echo ""
info "confirm any time:  pl reconcile   (the oversight-cron row)"
echo ""
info "Record it: add a rollback row noting the move, and that reversing it is"
info "  pl loop schedule install --execute   on the workstation."
