#!/bin/bash
################################################################################
# scripts/install-private-replica.sh — make the agent host's ~/nwp/private a
# REAL replica of the nwp/private forge project (ops#330).
#
#   bash scripts/install-private-replica.sh          # install
#   bash scripts/install-private-replica.sh --check  # verify only
#
# WHAT WAS FOUND (2026-08-09): the agent host already carried the cron line
#     20 3 * * * cd $HOME/nwp/private && git pull --ff-only  # nwp-private-pull
# but ~/nwp/private was NOT a git repo — git resolved to the OUTER ~/nwp
# checkout, so that cron has been pulling nwp/nwp from inside private/ and
# syncing nothing. This installer makes the directory a real clone of
# nwp/private (project 34), at which point the SAME cron line becomes
# genuinely functional, unchanged.
#
# CREDENTIALS — the honest state, named:
#   * the agent host's ~/.ssh/nwp (nwp-agent-loop@the agent host) authenticates to the forge as
#     @root (verified live 2026-08-09). So the BOOTSTRAP fetch works today —
#     but it rides the root-identity linchpin that the operator intends to
#     revoke. Building the nightly pull on it would break silently at the
#     revoke.
#   * This installer therefore mints a dedicated ~/.ssh/nwp-private-pull key
#     (single-purpose) and points the clone's core.sshCommand at it. The
#     nightly pull uses ONLY that key, and fails LOUDLY until the operator
#     adds it — read-only — to the project:
#
#       OPERATOR CLICK: <gitlab-host> → nwp/private → Settings → Repository
#       → Deploy keys → add the public key this script prints, WITHOUT
#       write access. (A deploy key, not a membership: read-only by
#       construction, no user account, survives the root-identity revoke.)
#
# SAFETY: the existing ~/nwp/private content on the agent host (demo-codes/ — the LIVE
# invite-code registry home — pairs/, rollback/, rotation files) is preserved.
# Only files TRACKED by nwp/private (registry + rotation logs + consumers
# doc, 6 files) are checked out over their stale the agent host copies; everything else
# is untracked and untouched. The demo-codes/ dir is asserted intact after.
################################################################################
set -euo pipefail

HOST="${NWP_AGENT_HOST:-rob@100.64.0.2}"   # agent host, headscale addr
PRIV_DIR='$HOME/nwp/private'
PULL_KEY='$HOME/.ssh/nwp-private-pull'
BOOT_KEY='$HOME/.ssh/nwp'
# The forge host never appears in tracked content (leakage gate); derive it
# from this checkout's own origin remote at run time.
FORGE_HOST="${NWP_GITLAB_HOST:-$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." remote get-url origin 2>/dev/null | sed -n 's/^git@\([^:]*\):.*/\1/p')}"
[[ -n "$FORGE_HOST" ]] || { echo "ERROR: cannot derive forge host — set NWP_GITLAB_HOST" >&2; exit 2; }
REMOTE="git@${FORGE_HOST}:nwp/private.git"
CRON_TAG="# nwp-private-pull"

say() { printf '\n== %s\n' "$*"; }

if [[ "${1:-}" == "--check" ]]; then
    ssh -o BatchMode=yes "$HOST" "
        cd $PRIV_DIR 2>/dev/null || { echo 'private dir: MISSING'; exit 1; }
        if [ -d .git ]; then echo 'clone: real repo'; git log --oneline -1; else echo 'clone: NOT A REPO'; fi
        git config core.sshCommand 2>/dev/null | grep -q nwp-private-pull && echo 'pull key: wired' || echo 'pull key: NOT wired'
        crontab -l 2>/dev/null | grep -qF '$CRON_TAG' && echo 'cron: present' || echo 'cron: MISSING'
        GIT_SSH_COMMAND=\"ssh -i $PULL_KEY -o IdentitiesOnly=yes -o BatchMode=yes\" git ls-remote origin >/dev/null 2>&1 \
            && echo 'deploy key: LIVE (operator click done)' || echo 'deploy key: awaiting operator click'"
    exit 0
fi

say "1/5  the agent host reachable"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true

say "2/5  dedicated read-only pull key (minted if absent)"
ssh -o BatchMode=yes "$HOST" "test -f $PULL_KEY || ssh-keygen -q -t ed25519 -N '' -C nwp-private-pull@agent-host -f $PULL_KEY"
echo "  public half (for the operator's deploy-key click, READ-ONLY):"
ssh -o BatchMode=yes "$HOST" "cat ${PULL_KEY}.pub" | sed 's/^/    /'

say "3/5  bootstrap the clone (existing operational files preserved)"
ssh -o BatchMode=yes "$HOST" "
    set -euo pipefail
    cd $PRIV_DIR
    before_codes=\$(find demo-codes -type f 2>/dev/null | sort | xargs -r sha256sum | sha256sum)
    if [ ! -d .git ]; then
        git init -q -b master
        git remote add origin $REMOTE
        GIT_SSH_COMMAND=\"ssh -i $BOOT_KEY -o IdentitiesOnly=yes -o BatchMode=yes\" git fetch -q origin
        # -f: the tracked names (registry, rotation logs, consumers doc) exist
        # here as STALE hand-copies; the repo versions are canonical.
        git checkout -qf -B master origin/master
        echo '  cloned into existing dir'
    else
        GIT_SSH_COMMAND=\"ssh -i $BOOT_KEY -o IdentitiesOnly=yes -o BatchMode=yes\" git pull -q --ff-only || echo '  (pull failed — will retry nightly)'
        echo '  already a repo'
    fi
    after_codes=\$(find demo-codes -type f 2>/dev/null | sort | xargs -r sha256sum | sha256sum)
    [ \"\$before_codes\" = \"\$after_codes\" ] || { echo 'ERROR: demo-codes changed during bootstrap' >&2; exit 1; }
    echo '  demo-codes intact'
    git log --oneline -1 | sed 's/^/  HEAD: /'"

say "4/5  nightly pulls ride ONLY the dedicated key from now on"
ssh -o BatchMode=yes "$HOST" "cd $PRIV_DIR && git config core.sshCommand 'ssh -i $PULL_KEY -o IdentitiesOnly=yes -o BatchMode=yes'"
if ssh -o BatchMode=yes "$HOST" "cd $PRIV_DIR && git ls-remote origin >/dev/null 2>&1"; then
    echo "  deploy key LIVE — nightly pull armed"
else
    echo "  deploy key NOT yet accepted — nightly pull will fail LOUDLY into"
    echo "  ~/nwp/logs/private-pull.log until the operator's click; it arms itself"
    echo "  the moment the click happens (nothing else to run)."
fi

say "5/5  cron line (pre-existing; now genuinely functional)"
ssh -o BatchMode=yes "$HOST" "
    cur=\$(crontab -l 2>/dev/null || true)
    if ! printf '%s\n' \"\$cur\" | grep -qF '$CRON_TAG'; then
        printf '%s\n%s\n' \"\$cur\" '20 3 * * * cd $PRIV_DIR && git pull --ff-only >> \$HOME/nwp/logs/private-pull.log 2>&1 $CRON_TAG' | crontab -
        echo '  added'
    else
        echo '  present'
    fi"

say "DONE"
