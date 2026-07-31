#!/bin/bash
################################################################################
# servers/sites1/demo/install-box.sh — install the restricted demo-reset
# wrapper + forced-command key on the git.nwpcode.org box (ops#133).
#
# Run FROM the dev workstation (it needs the admin gitlab_linode key to install
# root-owned files). Idempotent: safe to re-run after editing the wrapper or
# recapturing the golden image.
#
#   bash servers/sites1/demo/install-box.sh [--stage-golden] [--stage-codes]
#
#   --stage-golden   also (re)upload sites/nwd/demo-golden-live/* to the box
#   --stage-codes    also (re)upload the hashed invite-code payload
#   --no-key         skip the authorized_keys edit (wrapper/golden only)
#
# The authorized_keys edit is backed up first and verified afterwards: the
# pre-existing entries (met-stick-backup-pull, nwp-dr-pull@met) must survive
# byte-identical or the script restores the backup and aborts.
################################################################################
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# sites/ is gitignored, so a git worktree has no sites/nwd/. The golden and the
# code registry always live in the main checkout — override with NWP_ROOT.
NWP_ROOT="${NWP_ROOT:-$([[ -d "${REPO_ROOT}/sites/nwd" ]] && echo "$REPO_ROOT" || echo "$HOME/nwp")}"
BOX_HOST="${BOX_HOST:-git.nwpcode.org}"
BOX_USER="${BOX_USER:-gitlab}"
ADMIN_KEY="${ADMIN_KEY:-$HOME/.ssh/gitlab_linode}"
DEMO_KEY="${DEMO_KEY:-$HOME/.ssh/nwd_demo_reset}"
WRAPPER_SRC="${REPO_ROOT}/servers/sites1/demo/nwd-demo-reset-restricted"
WRAPPER_DST="/usr/local/bin/nwd-demo-reset-restricted"
GOLDEN_SRC="${NWP_ROOT}/sites/nwd/demo-golden-live"
CODES_SRC="${NWP_ROOT}/sites/nwd/demo-codes.json"
STATE_DIR="/var/lib/nwp-demo/nwd"
KEY_COMMENT="nwd-demo-reset@met"
RESTRICTIONS='command="/usr/local/bin/nwd-demo-reset-restricted",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding'

stage_golden=false; stage_codes=false; do_key=true
for a in "$@"; do
    case "$a" in
        --stage-golden) stage_golden=true ;;
        --stage-codes)  stage_codes=true ;;
        --no-key)       do_key=false ;;
        *) echo "Unknown option: $a" >&2; exit 1 ;;
    esac
done

box() { ssh -i "$ADMIN_KEY" -o BatchMode=yes -o ConnectTimeout=20 "${BOX_USER}@${BOX_HOST}" "$@"; }
say() { printf '\n== %s\n' "$*"; }

[[ -f "$WRAPPER_SRC" ]] || { echo "Missing $WRAPPER_SRC" >&2; exit 1; }
bash -n "$WRAPPER_SRC" || { echo "Wrapper failed bash -n — refusing to install" >&2; exit 1; }

################################################################################
say "1/5  Wrapper → ${WRAPPER_DST} (root:root 0755)"
################################################################################
scp -i "$ADMIN_KEY" -q "$WRAPPER_SRC" "${BOX_USER}@${BOX_HOST}:/tmp/nwd-demo-reset-restricted.new"
box "sudo install -o root -g root -m 0755 /tmp/nwd-demo-reset-restricted.new '${WRAPPER_DST}' && rm -f /tmp/nwd-demo-reset-restricted.new && ls -l '${WRAPPER_DST}'"

################################################################################
say "2/5  State + log dirs"
################################################################################
# State is root-owned; the wrapper only reads the golden. The log and the
# stamp/harvest paths must be writable by the ssh user that runs the wrapper.
box "sudo mkdir -p '${STATE_DIR}/golden' '${STATE_DIR}/harvest' /var/log/nwp-demo \
     && sudo chown root:root '${STATE_DIR}' '${STATE_DIR}/golden' \
     && sudo chmod 0755 '${STATE_DIR}' '${STATE_DIR}/golden' \
     && sudo chown ${BOX_USER}:${BOX_USER} '${STATE_DIR}/harvest' /var/log/nwp-demo \
     && sudo touch /var/log/nwp-demo/nwd-demo-reset.log \
     && sudo chown ${BOX_USER}:${BOX_USER} /var/log/nwp-demo/nwd-demo-reset.log"

# The stamp file lives in the root-owned state dir but must be writable by the
# runner; create it owned by the ssh user.
box "sudo touch '${STATE_DIR}/last-reset' && sudo chown ${BOX_USER}:${BOX_USER} '${STATE_DIR}/last-reset'"

# logrotate: the box is small, keep the reset log bounded.
box "printf '%s\n' '/var/log/nwp-demo/*.log {' '    weekly' '    rotate 8' '    compress' '    missingok' '    notifempty' '    copytruncate' '}' | sudo tee /etc/logrotate.d/nwp-demo >/dev/null && sudo chmod 0644 /etc/logrotate.d/nwp-demo"

################################################################################
if [[ "$stage_golden" == "true" ]]; then
    say "3/5  Staging golden image → ${STATE_DIR}/golden"
    for f in golden.db.sql.gz golden.db.sql.gz.sha256 golden.files.tar.gz golden.files.tar.gz.sha256 golden.manifest.json; do
        [[ -f "${GOLDEN_SRC}/${f}" ]] || { echo "Missing ${GOLDEN_SRC}/${f} — run: pl demo golden nwd --tier=live" >&2; exit 1; }
        scp -i "$ADMIN_KEY" -q "${GOLDEN_SRC}/${f}" "${BOX_USER}@${BOX_HOST}:/tmp/${f}"
        box "sudo install -o root -g root -m 0644 /tmp/${f} '${STATE_DIR}/golden/${f}' && rm -f /tmp/${f}"
    done
    box "cd '${STATE_DIR}/golden' && sha256sum -c golden.db.sql.gz.sha256 golden.files.tar.gz.sha256"
else
    say "3/5  Golden staging SKIPPED (pass --stage-golden)"
fi

################################################################################
if [[ "$stage_codes" == "true" ]]; then
    say "4/5  Staging hashed invite-code payload (hashes only — never plaintext)"
    payload="$(cd "$NWP_ROOT" && jq -c --argjson now "$(date +%s)" \
        '{version:1, codes:[.codes[] | select(.revoked == false and .expires > $now) | {bundle, hash, expires}]}' \
        "$CODES_SRC")"
    printf '%s' "$payload" | box "cat > /tmp/codes-payload.json && sudo install -o root -g root -m 0644 /tmp/codes-payload.json '${STATE_DIR}/codes-payload.json' && rm -f /tmp/codes-payload.json && jq -e '.codes|length' '${STATE_DIR}/codes-payload.json'"
else
    say "4/5  Code payload staging SKIPPED (pass --stage-codes)"
fi

################################################################################
if [[ "$do_key" == "true" ]]; then
    say "5/5  Forced-command key in ${BOX_USER}@${BOX_HOST}:~/.ssh/authorized_keys"
    [[ -f "${DEMO_KEY}.pub" ]] || { echo "Missing ${DEMO_KEY}.pub — generate it first (see docs/guides/demo-nightly-on-met.md)" >&2; exit 1; }
    pubkey="$(awk '{print $1" "$2}' "${DEMO_KEY}.pub")"
    entry="${RESTRICTIONS} ${pubkey} ${KEY_COMMENT}"

    # Backup, then rewrite: drop any prior entry with our comment, append ours.
    printf '%s\n' "$entry" | box "
        set -e
        cd ~/.ssh
        stamp=\$(date -u +%Y%m%d-%H%M%S)
        cp -a authorized_keys authorized_keys.bak-\$stamp
        before=\$(grep -c . authorized_keys)
        new=\$(cat)
        grep -v '${KEY_COMMENT}' authorized_keys > authorized_keys.tmp || true
        printf '%s\n' \"\$new\" >> authorized_keys.tmp
        # every pre-existing non-nwd-demo line must survive byte-identical
        grep -v '${KEY_COMMENT}' authorized_keys      > /tmp/ak.old.\$\$ || true
        grep -v '${KEY_COMMENT}' authorized_keys.tmp  > /tmp/ak.new.\$\$ || true
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
    say "5/5  authorized_keys edit SKIPPED (--no-key)"
fi

say "Done. Verify with:"
echo "  ssh -i ${DEMO_KEY} ${BOX_USER}@${BOX_HOST} status"
echo "  ssh -i ${DEMO_KEY} ${BOX_USER}@${BOX_HOST} dry-run"
echo "  ssh -i ${DEMO_KEY} ${BOX_USER}@${BOX_HOST} 'id'    # must be REFUSED"
