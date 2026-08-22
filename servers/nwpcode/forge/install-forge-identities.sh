#!/bin/bash
################################################################################
# servers/nwpcode/forge/install-forge-identities.sh — install the two NAMED
# forge-box identities (ops#331, NWP-ADR-0038).
#
#   bash servers/nwpcode/forge/install-forge-identities.sh [--execute]
#        [--only=ops|probe] [--no-wrapper]
#
# WHAT IT INSTALLS
#   1. /usr/local/bin/forge-probe-restricted  (root:root 0755) — the read-only
#      forced command, plus its log dir and a logrotate rule.
#   2. ~gitlab/.ssh/authorized_keys entries for the two keys:
#
#        nwp-forge-ops    NO forced command — shell as `gitlab`, which has
#                         NOPASSWD sudo. This is the "control the whole box"
#                         identity the 2026-08-10 ruling grants. It is named, so
#                         `pl forge keys` and sshd's auth log can say WHICH
#                         credential did a thing — the property the old
#                         "NWP Backup Key" entry did not have.
#        nwp-forge-probe  command="/usr/local/bin/forge-probe-restricted" plus
#                         no-agent-forwarding,no-port-forwarding,no-pty,
#                         no-user-rc,no-X11-forwarding — read-only action words
#                         and nothing else.
#
# DRY-RUN BY DEFAULT. Nothing is written without --execute; the dry run prints
# the exact authorized_keys diff it would make.
#
# WHAT IT DELIBERATELY DOES NOT DO
#   * It never touches, rewrites or removes any pre-existing authorized_keys
#     entry — including `gitlab@nwpcode.org` (the dev workstation's
#     ~/.ssh/gitlab_linode). The workstation keeps working through the cutover
#     BY DESIGN; retiring that entry is a separate, later, operator-visible step
#     (`pl forge retire-legacy-key`, NWP-ADR-0038 §Migration). An installer that
#     could cut the workstation's own access is an installer nobody should run.
#     The check is enforced, not intended: every pre-existing line that is not
#     one of OUR two comments must survive byte-identical or the box restores
#     the backup and the script aborts.
#   * It never mints, reads, stages or prints a GitLab token. The application
#     plane (NWP-ADR-0038 plane 2) is an OPERATOR mint; this script is the Linux
#     plane only.
#   * It never generates a keypair. Generation happens on the machine that will
#     HOLD the private half, so no private key ever crosses a wire:
#         ssh-keygen -t ed25519 -N '' -C nwp-forge-ops@authoring   -f ~/.ssh/nwp-forge-ops
#         ssh-keygen -t ed25519 -N '' -C nwp-forge-probe@authoring -f ~/.ssh/nwp-forge-probe
#
# BOOTSTRAP CREDENTIAL. This runs from the dev workstation over the EXISTING
# admin key (ADMIN_KEY, default ~/.ssh/gitlab_linode), because installing
# root-owned files is exactly what that key is for. Once nwp-forge-ops is
# installed and verified, re-runs can use it instead: ADMIN_KEY=~/.ssh/nwp-forge-ops.
################################################################################
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

BOX_USER="${BOX_USER:-gitlab}"
ADMIN_KEY="${ADMIN_KEY:-$HOME/.ssh/gitlab_linode}"
OPS_KEY="${OPS_KEY:-$HOME/.ssh/nwp-forge-ops}"
PROBE_KEY="${PROBE_KEY:-$HOME/.ssh/nwp-forge-probe}"

WRAPPER_NAME="forge-probe-restricted"
WRAPPER_SRC="${REPO_ROOT}/servers/nwpcode/system/${WRAPPER_NAME}"
WRAPPER_DST="/usr/local/bin/${WRAPPER_NAME}"
LOG_DIR="/var/log/nwp-forge"
LOG_FILE="${LOG_DIR}/forge-probe.log"

OPS_COMMENT="nwp-forge-ops@authoring"
PROBE_COMMENT="nwp-forge-probe@authoring"
PROBE_RESTRICTIONS="command=\"${WRAPPER_DST}\",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding"

execute=false; only=""; do_wrapper=true
for a in "$@"; do
    case "$a" in
        --execute)     execute=true ;;
        --only=ops)    only=ops ;;
        --only=probe)  only=probe ;;
        --no-wrapper)  do_wrapper=false ;;
        -h|--help)     sed -n '2,50p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "Unknown option: $a" >&2; exit 1 ;;
    esac
done

# The box is resolved from the tracked server identity, never hardcoded, so this
# follows the forge if it moves.
_resolve_box_host() {
    local ip
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/common.sh" 2>/dev/null || return 1
    declare -F get_server_ip >/dev/null || return 1
    ip="$(get_server_ip nwpcode 2>/dev/null)" || return 1
    [[ -n "$ip" ]] || return 1
    printf '%s' "$ip"
}
BOX_HOST="${BOX_HOST:-$(_resolve_box_host || true)}"
[[ -n "$BOX_HOST" ]] || { echo "ERROR: cannot resolve the forge box from servers/nwpcode/.nwp-server.yml — set BOX_HOST=<host>" >&2; exit 1; }

box() { ssh -i "$ADMIN_KEY" -o BatchMode=yes -o ConnectTimeout=20 "${BOX_USER}@${BOX_HOST}" "$@"; }
say() { printf '\n== %s\n' "$*"; }

[[ -f "$WRAPPER_SRC" ]] || { echo "Missing $WRAPPER_SRC" >&2; exit 1; }
bash -n "$WRAPPER_SRC" || { echo "Wrapper failed bash -n — refusing to install" >&2; exit 1; }

# Build the entries we intend to add, from the PUBLIC halves only.
declare -a WANT_COMMENTS=() WANT_ENTRIES=()
_want() { # comment  pubkeyfile  restrictions-or-empty
    local comment="$1" pub="$2" restr="${3:-}" blob
    [[ -f "$pub" ]] || { echo "ERROR: missing ${pub} — generate the keypair first (see header)" >&2; exit 1; }
    blob="$(awk '{print $1" "$2}' "$pub")"
    WANT_COMMENTS+=("$comment")
    WANT_ENTRIES+=("${restr:+${restr} }${blob} ${comment}")
}
[[ "$only" == "probe" ]] || _want "$OPS_COMMENT"   "${OPS_KEY}.pub"   ""
[[ "$only" == "ops"   ]] || _want "$PROBE_COMMENT" "${PROBE_KEY}.pub" "$PROBE_RESTRICTIONS"

################################################################################
say "Target: ${BOX_USER}@${BOX_HOST}   (bootstrap key: ${ADMIN_KEY})"
say "Mode:   $([[ "$execute" == true ]] && echo EXECUTE || echo 'DRY RUN — nothing will be written (--execute to apply)')"
################################################################################

if [[ "$do_wrapper" == "true" ]]; then
    say "1/3  Wrapper → ${WRAPPER_DST} (root:root 0755) + ${LOG_DIR}"
    if [[ "$execute" == "true" ]]; then
        scp -i "$ADMIN_KEY" -q "$WRAPPER_SRC" "${BOX_USER}@${BOX_HOST}:/tmp/${WRAPPER_NAME}.new"
        box "sudo install -o root -g root -m 0755 /tmp/${WRAPPER_NAME}.new '${WRAPPER_DST}' && rm -f /tmp/${WRAPPER_NAME}.new && ls -l '${WRAPPER_DST}'"
        # The log must be writable by the account the forced command runs as.
        box "sudo mkdir -p '${LOG_DIR}' \
             && sudo touch '${LOG_FILE}' \
             && sudo chown ${BOX_USER}:${BOX_USER} '${LOG_DIR}' '${LOG_FILE}' \
             && sudo chmod 0755 '${LOG_DIR}'"
        # The box is small — keep the probe log bounded from day one.
        box "printf '%s\n' '${LOG_DIR}/*.log {' '    weekly' '    rotate 8' '    compress' '    missingok' '    notifempty' '    copytruncate' '}' | sudo tee /etc/logrotate.d/nwp-forge >/dev/null && sudo chmod 0644 /etc/logrotate.d/nwp-forge"
    else
        echo "   would scp ${WRAPPER_SRC} → ${WRAPPER_DST} (root:root 0755)"
        echo "   would create ${LOG_DIR}, ${LOG_FILE} (${BOX_USER}:${BOX_USER}) and /etc/logrotate.d/nwp-forge"
    fi
else
    say "1/3  Wrapper install SKIPPED (--no-wrapper)"
fi

################################################################################
say "2/3  authorized_keys entries in ${BOX_USER}@${BOX_HOST}:~/.ssh/authorized_keys"
################################################################################
for e in "${WANT_ENTRIES[@]}"; do
    # Print the ENTRY SHAPE, not the blob: the reader needs to see the
    # restrictions, and the public blob is noise that hides them.
    printf '   + %s\n' "$(printf '%s' "$e" | sed 's/\(AAAA[A-Za-z0-9+/]\{10\}\)[A-Za-z0-9+/=]*/\1…/')"
done

# One grep -v per comment; built here so the remote side stays a fixed string.
FILTER=""
for c in "${WANT_COMMENTS[@]}"; do FILTER="${FILTER} | grep -v '${c}'"; done
FILTER="${FILTER# | }"

if [[ "$execute" == "true" ]]; then
    printf '%s\n' "${WANT_ENTRIES[@]}" | box "
        set -e
        cd ~/.ssh
        stamp=\$(date -u +%Y%m%d-%H%M%S)
        cp -a authorized_keys authorized_keys.bak-\$stamp
        before=\$(grep -c . authorized_keys)
        new=\$(cat)
        cat authorized_keys | ${FILTER} > authorized_keys.tmp || true
        printf '%s\n' \"\$new\" >> authorized_keys.tmp
        # EVERY pre-existing line that is not one of OURS must survive
        # byte-identical — that explicitly includes the dev workstation's
        # gitlab@nwpcode.org entry and the three met forced-command keys.
        cat authorized_keys     | ${FILTER} > /tmp/ak.old.\$\$ || true
        cat authorized_keys.tmp | ${FILTER} > /tmp/ak.new.\$\$ || true
        if ! diff /tmp/ak.old.\$\$ /tmp/ak.new.\$\$ >/dev/null; then
            echo 'REFUSING: pre-existing authorized_keys entries would change' >&2
            rm -f authorized_keys.tmp /tmp/ak.old.\$\$ /tmp/ak.new.\$\$; exit 1
        fi
        rm -f /tmp/ak.old.\$\$ /tmp/ak.new.\$\$
        mv authorized_keys.tmp authorized_keys
        chmod 600 authorized_keys
        echo \"authorized_keys: \$before -> \$(grep -c . authorized_keys) entries (backup: authorized_keys.bak-\$stamp)\"
    "
else
    echo "   (dry run) pre-existing entries that would be preserved byte-identical:"
    box "cat ~/.ssh/authorized_keys | ${FILTER} | sed 's/\(AAAA[A-Za-z0-9+\/]\{10\}\)[A-Za-z0-9+\/=]*/\1…/' | sed 's/^/     /'" || true
fi

################################################################################
say "3/3  Verify"
################################################################################
# ⚠️ THE ISOLATION FLAGS BELOW ARE LOAD-BEARING, NOT NOISE.
# ~/.ssh/config supplies `IdentityFile ~/.ssh/gitlab_linode` for this host, and
# `IdentitiesOnly=yes` does NOT exclude config-supplied identity files — it only
# excludes extra AGENT keys. So the obvious command
#     ssh -o IdentitiesOnly=yes -i ~/.ssh/nwp-forge-probe gitlab@<box> id
# authenticates with gitlab_linode and prints `uid=1000(gitlab) … 27(sudo)` —
# i.e. it reports a SHELL where the jail is working, and reports success for a
# key that is not installed at all. Measured 2026-08-10, NWP-ADR-0038 §"the trap
# that nearly produced a fake green". Never print a verify recipe without them.
ISO="-F /dev/null -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"
cat <<EOF
  ISO="${ISO}"

  # in-scope reads must WORK (exit 0)
  ssh \$ISO -i ${PROBE_KEY} ${BOX_USER}@${BOX_HOST} status
  ssh \$ISO -i ${PROBE_KEY} ${BOX_USER}@${BOX_HOST} health

  # the jail must REFUSE (each exit 2, and NOTHING executed — check for uid=)
  ssh \$ISO -i ${PROBE_KEY} ${BOX_USER}@${BOX_HOST} 'id'
  ssh \$ISO -i ${PROBE_KEY} ${BOX_USER}@${BOX_HOST} 'sudo -n id'
  ssh \$ISO -i ${PROBE_KEY} ${BOX_USER}@${BOX_HOST} 'logs-nginx; id'
  ssh \$ISO -i ${PROBE_KEY} ${BOX_USER}@${BOX_HOST} 'cat ../../etc/shadow'
  ssh \$ISO -i ${PROBE_KEY} ${BOX_USER}@${BOX_HOST} -N   # no shell either

  # full control must WORK on the ops key
  ssh \$ISO -i ${OPS_KEY} ${BOX_USER}@${BOX_HOST} 'id && sudo -n id'

  # all of the above, as a gate:
  bats tests/unit/test-forge-identities.bats     # offline jail logic, 19 tests
  pl forge doctor --live                         # the same, over the wire
EOF
