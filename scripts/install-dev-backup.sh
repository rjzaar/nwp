#!/bin/bash
################################################################################
# scripts/install-dev-backup.sh — wire the operator-approved backup topology
# (ops#330, ruling 2026-08-09): met→laptop pull route + three-host presence.
#
#   bash scripts/install-dev-backup.sh            # install / repair (idempotent)
#   bash scripts/install-dev-backup.sh --check    # verify only
#   bash scripts/install-dev-backup.sh --authorized-line <pubkey-file>
#                                                   # print the hardened line
#
# Run FROM the dev laptop (dev). What it wires:
#
#   laptop  ~/.nwp-backup-export hardlink farm (dev-backup-export.sh)
#           ~/.ssh/authorized_keys line jailing met's pull key to
#             `rrsync -ro <export>` with the full no-* hardening (the same
#             shape as the git/live boxes' tracked authorized-keys)
#           cron 02:30  pl backup replicate --to=rob@100.64.0.2   (refreshes the agent host's
#             ~/nwp-backup-set — it was 13 days stale, a manual one-off)
#           cron 02:45  dev-backup-export.sh --push   (farm → met staging,
#             core → agent host, until the pull leg is armed — and harmlessly after)
#
#   met     ~/.ssh/nwp-dev-pull keypair (minted here if absent)
#           ~/nwp-dr/{repo,staging-dev,staging-live} + restic init
#           ~/.nwp-dr-user-restic-pw (0600, generated, NEVER printed)
#           cron 03:35  met-dr-pull.sh all  (dev + LIVE box → restic)
#
# THE ONE OPERATOR STEP: the laptop has no sshd (openssh-server not
# installed) and this session has no sudo, so the PULL leg stays dark until
# the operator runs the printed install block. Until then the push leg
# carries the data (met-dr-pull falls back to FRESH pushed staging only).
# Re-run this installer after the operator step: it pins the laptop host key
# on met and proves the restricted key live (shell refused, in-scope pull
# green) — red-then-green on the real wire.
#
# Scripts referenced by cron run from the VERSIONED checkout paths; until the
# MR is merged and each host's checkout updates, tonight's data is already
# safe because this installer executes one real cycle NOW (piped, like
# install-registry-pull-on-met.sh before it).
################################################################################
set -euo pipefail

MET="${MET:-rob@100.64.0.3}"     # ci-host, headscale addr
AGENT="${AGENT:-rob@100.64.0.2}"  # agent host (registry home), headscale addr
LAPTOP_ADDR="${LAPTOP_ADDR:-100.64.0.1}"     # headscale 'dev'; stable, unlike DHCP LAN
EXPORT_DIR="${NWP_DEV_EXPORT_DIR:-$HOME/.nwp-backup-export}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANON_ROOT="${NWP_CANON_ROOT:-$HOME/nwp}"                    # cron runs the canonical checkout

MET_KEY='$HOME/.ssh/nwp-dev-pull'
MET_BASE='$HOME/nwp-dr'
MET_PW='$HOME/.nwp-dr-user-restic-pw'

M_EXPORT="# NWP Dev Backup Export+Push (ops#330)"
L_EXPORT="45 2 * * * ${CANON_ROOT}/scripts/dev-backup-export.sh --push >> \$HOME/nwp/logs/dev-backup-export.log 2>&1"
M_REPL="# NWP Backup Replicate to agent host (ops#330)"
L_REPL="30 2 * * * ${CANON_ROOT}/pl backup replicate --to=rob@100.64.0.2 >> \$HOME/nwp/logs/backup-replicate.log 2>&1"
# Operator identifiers (forge host, live box address) never appear in tracked
# content (leakage gate) — derive them at install time from this checkout's
# origin remote and the gitignored servers/live/.nwp-server.yml, and env-inject
# them into the met cron line (host state), the same pattern as the nightly
# audit cron.
FORGE_HOST="${NWP_GITLAB_HOST:-$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null | sed -n 's/^git@\([^:]*\):.*/\1/p')}"
M_PULL="# NWP met user DR pull - dev + live box (ops#330)"
# The live-box route is HOST STATE (gitignored .nwp-server.yml) — resolved only
# by the install path that wires the met cron, so pure-formatter modes
# (--authorized-line, --check) run on hosts without it (e.g. the CI runner).
resolve_live_route() {
    live_ip="$(sed -n 's/^[[:space:]]*ip:[[:space:]]*//p' "$CANON_ROOT/servers/live/.nwp-server.yml" 2>/dev/null | head -1)"
    live_user="$(sed -n 's/^[[:space:]]*ssh_user:[[:space:]]*//p' "$CANON_ROOT/servers/live/.nwp-server.yml" 2>/dev/null | head -1)"
    [[ -n "$live_ip" && -n "$live_user" ]] || { echo "ERROR: cannot read live box route from $CANON_ROOT/servers/live/.nwp-server.yml" >&2; exit 2; }
    L_PULL="35 3 * * * NWP_GITLAB_HOST=${FORGE_HOST} NWP_OPS_LOG_PROJECT=11 NWP_DR_LIVE_SRC=${live_user}@${live_ip}: \$HOME/nwp/scripts/met-dr-pull.sh all >> \$HOME/logs/met-dr-pull.log 2>&1"
}

say() { printf '\n== %s\n' "$*"; }

authorized_line() { # pubkey-file
    local pub
    pub="$(cat "$1")"
    printf 'command="rrsync -ro %s",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding %s\n' \
        "$EXPORT_DIR" "$pub"
}

cron_ensure() { # host('' = local) marker line
    local host="$1" marker="$2" line="$3" cur
    if [[ -z "$host" ]]; then
        cur="$(crontab -l 2>/dev/null || true)"
        if ! grep -qF "$marker" <<<"$cur"; then
            printf '%s\n%s\n%s\n' "$cur" "$marker" "$line" | crontab -
        fi
    else
        # shellcheck disable=SC2029
        ssh -o BatchMode=yes "$host" "
            set -e
            cur=\$(crontab -l 2>/dev/null || true)
            if ! printf '%s\n' \"\$cur\" | grep -qF '$marker'; then
                printf '%s\n%s\n%s\n' \"\$cur\" '$marker' '$line' | crontab -
            fi"
    fi
}

mode="install"
case "${1:-}" in
    --check) mode="check" ;;
    --authorized-line) authorized_line "${2:?pubkey file required}"; exit 0 ;;
    "") ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
esac

if [[ "$mode" == "check" ]]; then
    say "CHECK laptop"
    [[ -d "$EXPORT_DIR" ]] && echo "  export farm: present" || echo "  export farm: MISSING"
    grep -qF "rrsync -ro $EXPORT_DIR" "$HOME/.ssh/authorized_keys" 2>/dev/null \
        && echo "  authorized_keys jail: present" || echo "  authorized_keys jail: MISSING"
    systemctl is-active --quiet ssh && echo "  sshd: active (pull leg armed)" \
        || echo "  sshd: INACTIVE — pull leg dark, push leg carries (operator step pending)"
    crontab -l 2>/dev/null | grep -qF "$M_EXPORT" && echo "  cron export+push: present" || echo "  cron export+push: MISSING"
    crontab -l 2>/dev/null | grep -qF "$M_REPL" && echo "  cron replicate→agent-host: present" || echo "  cron replicate→agent-host: MISSING"
    say "CHECK met"
    ssh -o BatchMode=yes "$MET" "test -r ${MET_KEY}" && echo "  pull key: present" || echo "  pull key: MISSING"
    ssh -o BatchMode=yes "$MET" "test -f ${MET_BASE}/repo/config" && echo "  restic repo: present" || echo "  restic repo: MISSING"
    ssh -o BatchMode=yes "$MET" "crontab -l 2>/dev/null | grep -qF '$M_PULL'" && echo "  cron met-dr-pull: present" || echo "  cron met-dr-pull: MISSING"
    exit 0
fi

say "1/8  hosts reachable"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$MET" true
ssh -o BatchMode=yes -o ConnectTimeout=10 "$AGENT" true

say "2/8  met's pull keypair (minted if absent; private half never leaves met)"
ssh -o BatchMode=yes "$MET" "test -f ${MET_KEY} || ssh-keygen -q -t ed25519 -N '' -C nwp-dev-pull@met -f ${MET_KEY}"
pubfile="$(mktemp)"
ssh -o BatchMode=yes "$MET" "cat ${MET_KEY}.pub" > "$pubfile"

say "3/8  laptop: jail the key in ~/.ssh/authorized_keys (rrsync -ro, full hardening)"
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"
blob="$(awk '{print $2}' "$pubfile")"
if ! grep -qF "$blob" "$HOME/.ssh/authorized_keys"; then
    authorized_line "$pubfile" >> "$HOME/.ssh/authorized_keys"
    echo "  added (jailed to $EXPORT_DIR, read-only)"
else
    echo "  already present"
fi
rm -f "$pubfile"

say "4/8  laptop: build the export farm + first real push NOW"
bash "$REPO_ROOT/scripts/dev-backup-export.sh" --push

say "5/8  met: restic repo + password file (generated 0600; value never printed)"
ssh -o BatchMode=yes "$MET" "
    set -e
    mkdir -p ${MET_BASE}/staging-dev ${MET_BASE}/staging-live \$HOME/logs
    if [ ! -f ${MET_PW} ]; then
        umask 077
        head -c 48 /dev/urandom | base64 > ${MET_PW}
        echo '  password file created'
    fi
    if [ ! -f ${MET_BASE}/repo/config ]; then
        restic -r ${MET_BASE}/repo --password-file ${MET_PW} init >/dev/null
        echo '  restic repo initialised'
    fi"

say "6/8  pull leg: host key pinning + live red/green probe (needs laptop sshd)"
if systemctl is-active --quiet ssh && [[ -r /etc/ssh/ssh_host_ed25519_key.pub ]]; then
    hostkey="$(cat /etc/ssh/ssh_host_ed25519_key.pub)"
    # Pin by ADDRESS via ssh-keygen -F — met's known_hosts is hashed; a
    # blob-grep near-miss cost the registry-pull install its first run.
    ssh -o BatchMode=yes "$MET" "ssh-keygen -F '${LAPTOP_ADDR}' >/dev/null 2>&1 \
        || echo '${LAPTOP_ADDR} ${hostkey}' >> ~/.ssh/known_hosts"
    echo "  host key pinned"
    # RED: the jailed key must refuse a shell, by name.
    if out="$(ssh -o BatchMode=yes "$MET" "ssh -i ${MET_KEY} -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=15 rob@${LAPTOP_ADDR} 'echo pwned'" 2>&1)"; then
        echo "ERROR: jailed key returned a shell result: $out" >&2; exit 1
    fi
    grep -q "does not run rsync" <<<"$out" || { echo "ERROR: refusal was not rrsync's (got: $out)" >&2; exit 1; }
    echo "  live refusal proven: 'SSH_ORIGINAL_COMMAND does not run rsync'"
    # GREEN: an in-scope pull works.
    ssh -o BatchMode=yes "$MET" "NWP_DR_BASE=\$HOME/nwp-dr rsync -a --timeout=120 -e 'ssh -i ${MET_KEY} -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes' rob@${LAPTOP_ADDR}:secrets.yml \$HOME/nwp-dr/staging-dev/secrets.yml"
    echo "  live in-scope pull proven"
else
    cat <<'EOF'
  >>> OPERATOR STEP (the pull leg stays dark until this runs on the laptop):
      sudo apt-get install -y openssh-server
      printf 'PasswordAuthentication no\nPermitRootLogin no\nX11Forwarding no\n' | \
        sudo tee /etc/ssh/sshd_config.d/60-nwp-backup.conf
      sudo systemctl enable --now ssh
      bash ~/nwp/scripts/install-dev-backup.sh   # re-run: pins + proves
      (sshd is reachable from the home LAN and the headscale mesh only — the
       laptop sits behind NAT; no public exposure. The new inbound key is
       jailed to read-only rrsync either way.)
  Until then the 02:45 push leg carries the data; met-dr-pull uses it only
  while FRESH (<26 h) and fails loudly otherwise.
EOF
fi

say "7/8  crons (marker blocks; scripts run from the versioned checkouts)"
resolve_live_route
cron_ensure "" "$M_REPL" "$L_REPL"
cron_ensure "" "$M_EXPORT" "$L_EXPORT"
cron_ensure "$MET" "$M_PULL" "$L_PULL"
echo "  laptop 02:30 replicate→agent-host · 02:45 export+push · met 03:35 met-dr-pull all"

say "8/8  one real met-side cycle NOW (piped runner; cron picks up the versioned copy at merge)"
# Same env the cron line injects — the piped copy has no crontab to read it from.
# shellcheck disable=SC2029
ssh -o BatchMode=yes "$MET" "NWP_GITLAB_HOST='${FORGE_HOST}' NWP_OPS_LOG_PROJECT=11 NWP_DR_LIVE_SRC='${live_user}@${live_ip}:' bash -s all" < "$REPO_ROOT/scripts/met-dr-pull.sh"

say "spot-check: laptop file vs the restic snapshot on met (byte identity)"
lsha="$(sha256sum "$HOME/nwp/.secrets.yml" | cut -d' ' -f1)"
# paths inside a snapshot are the absolute staging paths; filter by tag so the
# live-pull snapshot (taken after dev's) cannot shadow it
rsha="$(ssh -o BatchMode=yes "$MET" "restic -r ${MET_BASE}/repo --password-file ${MET_PW} dump --tag dev-pull latest \$HOME/nwp-dr/staging-dev/secrets.yml 2>/dev/null | sha256sum" | cut -d' ' -f1)"
[[ -n "$lsha" && "$lsha" == "$rsha" ]] \
    && echo "  sha256 verified end-to-end: $lsha" \
    || { echo "ERROR: spot-check MISMATCH (laptop ${lsha:0:12}… vs snapshot ${rsha:0:12}…)" >&2; exit 1; }

say "DONE — run with --check any time; see the MR for the copy-count table"
