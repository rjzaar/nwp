#!/bin/bash
################################################################################
# servers/live/demo/install-registry-pull-on-met.sh — give the invite-code
# registry's home a survivor (ops#328 D1).
#
#   bash servers/live/demo/install-registry-pull-on-met.sh          # install
#   bash servers/live/demo/install-registry-pull-on-met.sh --check  # verify only
#
# D1 put the registry's ONE writable home on mini (registry-home.yml). mini is
# a small always-on box; if it dies, the registry — including the revoked/
# purged AUDIT rows that exist nowhere else — must not die with it. The active
# codes already survive twice over (live site state + the box's staged
# payload, which the box nightly backup covers); this route is for the rest.
#
# It reuses what already exists rather than minting anything:
#   * met already holds ~/.ssh/id_ed25519_remote, and mini already lists that
#     key in ~/.ssh/authorized_keys (verified 2026-08-09) — NO new credential.
#   * met already runs the demo nightly crons; this adds one marker-delimited
#     block alongside them, running the VERSIONED scripts/demo-registry-pull.sh
#     out of met's checkout (the ~/bin hand-placed-file mistake, once, was
#     enough — see nwp-daily-audit's header).
#   * mini's host key is taken from THIS workstation's known_hosts (a channel
#     verified long ago) and appended to met's — never trust-on-first-use on
#     the machine that will run unattended.
#
# Run FROM the dev workstation. Each step verifies before the next; a first
# pull is executed immediately so the route is proven, not hoped.
################################################################################
set -euo pipefail

MET="${MET:-metabox}"
MINI_ADDR="${MINI_ADDR:-100.64.0.2}"
MINI_SSH="${MINI_SSH:-mini}"          # workstation's alias for mini (verified channel)
SITE="${DEMO_SITE:-nwd}"
PULL_KEY='$HOME/.ssh/id_ed25519_remote'
RUNNER="/home/rob/nwp/scripts/demo-registry-pull.sh"
MARKER="# NWP Demo Registry Pull - ${SITE} (ops#328 D1)"
CRON_LINE="10 3 * * * ${RUNNER} >> \$HOME/logs/demo-registry-pull.log 2>&1"

check_only=false
for a in "$@"; do
    case "$a" in
        --check) check_only=true ;;
        *) echo "Unknown option: $a" >&2; exit 1 ;;
    esac
done

say() { printf '\n== %s\n' "$*"; }

say "1/5  met reachable, key present"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$MET" "test -r ${PULL_KEY}" \
    || { echo "ERROR: ${PULL_KEY} missing on ${MET}" >&2; exit 1; }

say "2/5  met's key is authorized on mini (no new credential is minted here)"
pub="$(ssh -o BatchMode=yes "$MET" "awk '{print \$2}' ${PULL_KEY}.pub")"
ssh -o BatchMode=yes "$MINI_SSH" "grep -qF '${pub}' ~/.ssh/authorized_keys" \
    || { echo "ERROR: met's id_ed25519_remote is NOT in mini's authorized_keys — refusing to invent a new key path here" >&2; exit 1; }

say "3/5  mini's host key on met (from this workstation's verified channel)"
# Keyed on the ADDRESS (ssh-keygen -F), not on the key blob: met's known_hosts
# is hashed, and the same key sitting under some OTHER hashed name does not
# authenticate a connection to ${MINI_ADDR} — that near-miss cost the first
# install run its pull (grep-by-blob matched, append skipped, rsync refused).
hostkey="$(ssh -o BatchMode=yes "$MINI_SSH" 'cat /etc/ssh/ssh_host_ed25519_key.pub')"
ssh -o BatchMode=yes "$MET" "ssh-keygen -F '${MINI_ADDR}' >/dev/null 2>&1 \
    || echo '${MINI_ADDR} ${hostkey}' >> ~/.ssh/known_hosts"

if [[ "$check_only" == "true" ]]; then
    say "CHECK  cron block present?"
    ssh -o BatchMode=yes "$MET" "crontab -l 2>/dev/null | grep -qF '${MARKER}'" \
        && echo "   cron: installed" || echo "   cron: MISSING"
    exit 0
fi

say "4/5  one real pull NOW (runner from this checkout, piped — met's checkout gets it at merge)"
# shellcheck disable=SC2029
ssh -o BatchMode=yes "$MET" "NWP_DEMO_REGISTRY_PULL_SITE='${SITE}' bash -s" \
    < "$(git rev-parse --show-toplevel)/scripts/demo-registry-pull.sh"
src_sha="$(ssh -o BatchMode=yes "$MINI_SSH" "sha256sum nwp/sites/${SITE}/demo-codes.json" | awk '{print $1}')"
dst_sha="$(ssh -o BatchMode=yes "$MET" "sha256sum \$HOME/backups/demo-registry-home/${SITE}/demo-codes.json" | awk '{print $1}')"
[[ "$src_sha" == "$dst_sha" ]] \
    || { echo "ERROR: pulled copy does not match the home registry (${src_sha} != ${dst_sha})" >&2; exit 1; }
echo "   sha256 verified: ${src_sha}"

say "5/5  cron block on met (daily 03:10, after the nightly resets; runner is the VERSIONED path)"
ssh -o BatchMode=yes "$MET" "
    set -e
    mkdir -p \$HOME/logs
    cur=\$(crontab -l 2>/dev/null || true)
    if ! printf '%s\n' \"\$cur\" | grep -qF '${MARKER}'; then
        printf '%s\n%s\n%s\n' \"\$cur\" '${MARKER}' '${CRON_LINE}' | crontab -
    fi
    crontab -l | grep -A1 -F '${MARKER}'
"
echo ""
echo "NOTE: the cron runs ${RUNNER} from met's checkout — it goes live once the"
echo "ops#328 D1 MR is merged and met's nightly audit pull (02:30) updates the tree."
echo "Until then the 03:10 run logs a missing-file error; today's data is already"
echo "safe (step 4 pulled and sha-verified it)."
