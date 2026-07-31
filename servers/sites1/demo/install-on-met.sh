#!/bin/bash
################################################################################
# servers/sites1/demo/install-on-met.sh — hand the nwd nightly demo reset over
# to met (ops#133). Run FROM the dev workstation, once, when met is reachable.
#
#   bash servers/sites1/demo/install-on-met.sh            # full handover
#   bash servers/sites1/demo/install-on-met.sh --check    # verify only
#   bash servers/sites1/demo/install-on-met.sh --keep-laptop-cron
#
# What it does, in order (each step is verified before the next):
#   1. reach met
#   2. copy ~/.ssh/nwd_demo_reset (0600) + .pub to met
#   3. prove FROM MET that the key reaches the forced command and only that
#      (status + dry-run succeed; `id` is refused)
#   4. install met's crontab block (every 30 min, 01:00–03:30 Melbourne)
#   5. remove the INTERIM laptop cron
#   6. print both crontabs for the record
#
# The private key never touches the box and never leaves the two machines that
# need it. If any step fails the script stops BEFORE removing the laptop cron,
# so the nightly is never left unowned.
################################################################################
set -euo pipefail

MET="${MET:-metabox}"
DEMO_KEY="${DEMO_KEY:-$HOME/.ssh/nwd_demo_reset}"
# The demo box is derived from the site's OWN declaration, not hardcoded.
# It used to be a literal hostname, which was both wrong the moment the demo
# pair moved to another box (the 2026-07-31 split) and a live internal domain
# sitting in a tracked file. Override with BOX_HOST for a one-off.
_resolve_box_host() {
    local repo ip
    repo="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
    # shellcheck source=/dev/null
    source "${repo}/lib/common.sh" 2>/dev/null || return 1
    declare -F get_site_server >/dev/null || return 1
    local srv; srv="$(get_site_server "${DEMO_SITE:-nwd}" 2>/dev/null)" || return 1
    [[ -n "$srv" ]] || return 1
    ip="$(get_server_ip "$srv" 2>/dev/null)" || return 1
    [[ -n "$ip" ]] || return 1
    printf '%s' "$ip"
}
BOX_HOST="${BOX_HOST:-$(_resolve_box_host || true)}"
if [[ -z "$BOX_HOST" ]]; then
    echo "ERROR: cannot resolve the demo box from ${DEMO_SITE:-nwd}'s .live.server — set BOX_HOST=<host>" >&2
    exit 1
fi
BOX_USER="${BOX_USER:-gitlab}"
MET_LOG="${MET_LOG:-\$HOME/logs/demo-nightly-nwd.log}"
MARKER="# NWP Demo Reset - nwd"
TZ_MEL="Australia/Melbourne"

check_only=false; keep_laptop=false
for a in "$@"; do
    case "$a" in
        --check) check_only=true ;;
        --keep-laptop-cron) keep_laptop=true ;;
        *) echo "Unknown option: $a" >&2; exit 1 ;;
    esac
done

met() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$MET" "$@"; }
say() { printf '\n== %s\n' "$*"; }

# The exact command met's cron will run. IdentitiesOnly + IdentityAgent=none
# are load-bearing — without them ssh offers an agent-held admin key first and
# lands on the box's UNRESTRICTED gitlab entry instead of the forced command.
REMOTE_SSH="ssh -i \$HOME/.ssh/nwd_demo_reset -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=30 ${BOX_USER}@${BOX_HOST}"

################################################################################
say "1/6  Reaching met (${MET})"
################################################################################
met "hostname; uname -sr" || { echo "met is unreachable — try again when it is up." >&2; exit 1; }

################################################################################
say "2/6  Copying the restricted key to met (0600)"
################################################################################
if [[ "$check_only" == "false" ]]; then
    [[ -f "$DEMO_KEY" ]] || { echo "Missing $DEMO_KEY on this workstation." >&2; exit 1; }
    met "mkdir -p ~/.ssh ~/logs && chmod 700 ~/.ssh"
    scp -q "$DEMO_KEY"     "${MET}:.ssh/nwd_demo_reset"
    scp -q "${DEMO_KEY}.pub" "${MET}:.ssh/nwd_demo_reset.pub"
    met "chmod 600 ~/.ssh/nwd_demo_reset && chmod 644 ~/.ssh/nwd_demo_reset.pub && ls -l ~/.ssh/nwd_demo_reset*"
fi
met "ssh-keygen -lf ~/.ssh/nwd_demo_reset.pub"

################################################################################
say "3/6  Proving the restriction FROM met"
################################################################################
echo "-- status (must succeed) --"
met "$REMOTE_SSH status" | head -5
echo "-- dry-run (must succeed, changes nothing) --"
met "$REMOTE_SSH dry-run" | tail -3
echo "-- 'id' (must be REFUSED, exit 2, no uid= output) --"
if met "$REMOTE_SSH id" 2>&1 | grep -q 'uid='; then
    echo "FATAL: met can execute arbitrary commands on the box — STOP and investigate." >&2
    exit 1
fi
met "$REMOTE_SSH id" 2>&1 | head -3 || true
echo "   (refused as expected)"

if [[ "$check_only" == "true" ]]; then
    say "--check: stopping here. Nothing was changed."
    exit 0
fi

################################################################################
say "4/6  Installing met's crontab block (01:00–03:30 ${TZ_MEL}, every 30 min)"
################################################################################
# The wrapper is idempotent (one reset per Melbourne day) and returns 3 while
# sessions are active, so a plain every-30-min cron gives the 04:00-floor retry
# semantics without holding a 3-hour ssh session open against a 3.8 GB host.
met "
    set -e
    cur=\$(crontab -l 2>/dev/null || true)
    printf '%s\n' \"\$cur\" | awk -v m='${MARKER}' 'index(\$0, m) == 1 { skip = 3 } skip > 0 { skip--; next } { print }' | grep -v nwd_demo_reset > /tmp/cron.met.\$\$ || true
    {
        cat /tmp/cron.met.\$\$
        echo '${MARKER} (restricted key; docs/guides/demo-nightly-on-met.md)'
        echo 'CRON_TZ=${TZ_MEL}'
        echo '0,30 1-3 * * * ${REMOTE_SSH} nightly >> ${MET_LOG} 2>&1'
    } | crontab -
    rm -f /tmp/cron.met.\$\$
"
met "crontab -l | grep -A2 'NWP Demo Reset'"

################################################################################
if [[ "$keep_laptop" == "false" ]]; then
    say "5/6  Removing the INTERIM laptop cron"
    if command -v pl >/dev/null 2>&1; then
        pl demo schedule nwd --remove || true
    else
        cur="$(crontab -l 2>/dev/null || true)"
        printf '%s\n' "$cur" \
            | awk -v m="$MARKER" 'index($0, m) == 1 { skip = 3 } skip > 0 { skip--; next } { print }' \
            | grep -v nwd_demo_reset | crontab - || true
    fi
    crontab -l 2>/dev/null | grep -c "nwd_demo_reset" | sed 's/^/   laptop cron lines still referencing the key: /' || true
else
    say "5/6  Laptop cron KEPT (--keep-laptop-cron) — two schedulers now; remove one."
fi

################################################################################
say "6/6  Final state"
################################################################################
echo "--- met crontab ---"
met "crontab -l | grep -A2 'NWP Demo Reset' || echo '(none)'"
echo "--- laptop crontab ---"
crontab -l 2>/dev/null | grep -A2 'NWP Demo Reset' || echo "(none — correct)"
echo
echo "Watch the first met-owned run:  ssh ${MET} 'tail -f ${MET_LOG}'"
echo "Box-side log:                   ssh -i ${DEMO_KEY} -o IdentitiesOnly=yes -o IdentityAgent=none ${BOX_USER}@${BOX_HOST} status"
