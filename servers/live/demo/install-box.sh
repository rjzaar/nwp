#!/bin/bash
################################################################################
# servers/live/demo/install-box.sh — install the restricted demo-reset
# wrapper + forced-command key on the demo box (ops#133, ops#170). The box is
# resolved from the demo site's .live.server, so this follows the site when it
# moves.
#
# Run FROM the dev workstation (it needs the admin gitlab_linode key to install
# root-owned files). Idempotent: safe to re-run after editing the wrapper or
# recapturing the golden image.
#
#   bash servers/live/demo/install-box.sh [site] [--stage-golden] [--stage-codes]
#
#   site             which half of the demo pair — `nwd` (Drupal, the default)
#                    or `ssd` (Moodle). Each has its OWN wrapper, its own key
#                    and its own forced command; there is deliberately no way to
#                    install one wrapper and aim it at the other site ([G2]).
#   --stage-golden   also (re)upload sites/<site>/demo-golden-live/* to the box
#   --stage-codes    also (re)upload the hashed invite-code payload. Provider-
#                    side only — invite codes are an nwc_demo_access concept and
#                    the Moodle half has none, so this REFUSES on ssd rather
#                    than quietly doing nothing.
#   --no-key         skip the authorized_keys edit (wrapper/golden only)
#
# The authorized_keys edit is backed up first and verified afterwards: the
# pre-existing entries (met-stick-backup-pull, nwp-dr-pull@met, and the OTHER
# half's demo key) must survive byte-identical or the script restores the backup
# and aborts.
#
# TOKEN (ops#315) — WHAT THIS SCRIPT DELIBERATELY DOES NOT DO. The wrapper's
# feedback-sync / harvest-post action words read ONE walled api token from
# /etc/nwp-demo/feedback.token (root:root 0600) on the box. This script only
# REPORTS whether that file is present: minting the token and staging its
# value is an OPERATOR / `pl secrets` step (registry entry
# demo_box_feedback_token — `pl secrets steps demo_box_feedback_token`),
# because an installer that writes secrets is an installer whose transcript
# holds secrets. Until the file exists those two words answer exit 2
# CANNOT VERIFY, and the nightly reports the gap without failing the reset.
################################################################################
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# --- which half of the pair -------------------------------------------------
# A leading bare word is the site; everything else is a flag. Defaulting to nwd
# keeps every existing invocation (and every runbook line) working unchanged.
DEMO_SITE="${DEMO_SITE:-nwd}"
if [[ "${1:-}" == [a-z]* ]]; then DEMO_SITE="$1"; shift; fi
case "$DEMO_SITE" in
    nwd|ssd) ;;
    *) echo "ERROR: unknown demo site '${DEMO_SITE}' (expected nwd or ssd)" >&2; exit 1 ;;
esac

# sites/ is gitignored, so a git worktree has no sites/<site>/. The golden and
# the code registry always live in the main checkout — override with NWP_ROOT.
NWP_ROOT="${NWP_ROOT:-$([[ -d "${REPO_ROOT}/sites/${DEMO_SITE}" ]] && echo "$REPO_ROOT" || echo "$HOME/nwp")}"
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
    local srv; srv="$(get_site_server "${DEMO_SITE}" 2>/dev/null)" || return 1
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
ADMIN_KEY="${ADMIN_KEY:-$HOME/.ssh/gitlab_linode}"
DEMO_KEY="${DEMO_KEY:-$HOME/.ssh/${DEMO_SITE}_demo_reset}"
WRAPPER_NAME="${DEMO_SITE}-demo-reset-restricted"
WRAPPER_SRC="${REPO_ROOT}/servers/live/demo/${WRAPPER_NAME}"
WRAPPER_DST="/usr/local/bin/${WRAPPER_NAME}"
GOLDEN_SRC="${NWP_ROOT}/sites/${DEMO_SITE}/demo-golden-live"
CODES_SRC="${NWP_ROOT}/sites/${DEMO_SITE}/demo-codes.json"
STATE_DIR="/var/lib/nwp-demo/${DEMO_SITE}"
LOG_FILE="/var/log/nwp-demo/${DEMO_SITE}-demo-reset.log"
KEY_COMMENT="${DEMO_SITE}-demo-reset@met"
# The forced command names the WRAPPER, and each wrapper hard-wires its own
# site. That is what makes one key unable to reach the other half.
RESTRICTIONS="command=\"${WRAPPER_DST}\",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding"

stage_golden=false; stage_codes=false; do_key=true
for a in "$@"; do
    case "$a" in
        --stage-golden) stage_golden=true ;;
        --stage-codes)  stage_codes=true ;;
        --no-key)       do_key=false ;;
        *) echo "Unknown option: $a" >&2; exit 1 ;;
    esac
done

# Invite codes are a provider-side (nwc_demo_access) concept: testers redeem a
# code on nwd and reach ssd over SSO. Accepting the flag here and silently
# skipping it would let an operator believe codes had been staged for a site
# that has no such thing.
if [[ "$stage_codes" == "true" && "$DEMO_SITE" != "nwd" ]]; then
    echo "ERROR: --stage-codes is provider-side only; '${DEMO_SITE}' has no invite-code registry" >&2
    exit 1
fi

box() { ssh -i "$ADMIN_KEY" -o BatchMode=yes -o ConnectTimeout=20 "${BOX_USER}@${BOX_HOST}" "$@"; }
say() { printf '\n== %s\n' "$*"; }

[[ -f "$WRAPPER_SRC" ]] || { echo "Missing $WRAPPER_SRC" >&2; exit 1; }
bash -n "$WRAPPER_SRC" || { echo "Wrapper failed bash -n — refusing to install" >&2; exit 1; }

################################################################################
say "1/5  Wrapper → ${WRAPPER_DST} (root:root 0755)"
################################################################################
scp -i "$ADMIN_KEY" -q "$WRAPPER_SRC" "${BOX_USER}@${BOX_HOST}:/tmp/${WRAPPER_NAME}.new"
box "sudo install -o root -g root -m 0755 /tmp/${WRAPPER_NAME}.new '${WRAPPER_DST}' && rm -f /tmp/${WRAPPER_NAME}.new && ls -l '${WRAPPER_DST}'"

################################################################################
say "2/5  State + log dirs"
################################################################################
# State is root-owned; the wrapper only reads the golden. The log and the
# stamp/harvest paths must be writable by the ssh user that runs the wrapper —
# RECURSIVELY for the harvest spool: posted/ inside it was once created
# root-owned (by a sudo-run drain), which made every post-then-move fail its
# second half and double-post the digest on the next run (found live
# 2026-08-09). chown -R repairs any such residue on every re-run.
box "sudo mkdir -p '${STATE_DIR}/golden' '${STATE_DIR}/harvest/posted' /var/log/nwp-demo \
     && sudo chown root:root '${STATE_DIR}' '${STATE_DIR}/golden' \
     && sudo chmod 0755 '${STATE_DIR}' '${STATE_DIR}/golden' \
     && sudo chown -R ${BOX_USER}:${BOX_USER} '${STATE_DIR}/harvest' \
     && sudo chown ${BOX_USER}:${BOX_USER} /var/log/nwp-demo \
     && sudo touch '${LOG_FILE}' \
     && sudo chown ${BOX_USER}:${BOX_USER} '${LOG_FILE}'"

# The stamp file lives in the root-owned state dir but must be writable by the
# runner; create it owned by the ssh user.
box "sudo touch '${STATE_DIR}/last-reset' && sudo chown ${BOX_USER}:${BOX_USER} '${STATE_DIR}/last-reset'"

# logrotate: the box is small, keep the reset log bounded.
box "printf '%s\n' '/var/log/nwp-demo/*.log {' '    weekly' '    rotate 8' '    compress' '    missingok' '    notifempty' '    copytruncate' '}' | sudo tee /etc/logrotate.d/nwp-demo >/dev/null && sudo chmod 0644 /etc/logrotate.d/nwp-demo"

# ops#315 — REPORT (never provision) the walled-token state. Read-only on
# purpose: see the TOKEN paragraph in the header. `stat` over sudo so the
# 0600 root file is visible without reading a byte of its value.
TOKEN_FILE_BOX="/etc/nwp-demo/feedback.token"
if box "sudo test -s '${TOKEN_FILE_BOX}'"; then
    tok_mode="$(box "sudo stat -c '%a %U:%G' '${TOKEN_FILE_BOX}'" 2>/dev/null || echo '?')"
    echo "   token: ${TOKEN_FILE_BOX} PRESENT (${tok_mode}; want 600 root:root)"
    [[ "$tok_mode" == "600 root:root" ]] \
        || echo "   WARN  token file is not 600 root:root — fix on the box: sudo chown root:root '${TOKEN_FILE_BOX}' && sudo chmod 600 '${TOKEN_FILE_BOX}'"
else
    echo "   token: ${TOKEN_FILE_BOX} ABSENT — feedback-sync/harvest-post will answer CANNOT VERIFY (exit 2)."
    echo "          Provision it (OPERATOR step, not this script): pl secrets steps demo_box_feedback_token"
fi

################################################################################
if [[ "$stage_golden" == "true" ]]; then
    say "3/5  Staging golden image → ${STATE_DIR}/golden"
    for f in golden.db.sql.gz golden.db.sql.gz.sha256 golden.files.tar.gz golden.files.tar.gz.sha256 golden.manifest.json; do
        [[ -f "${GOLDEN_SRC}/${f}" ]] || { echo "Missing ${GOLDEN_SRC}/${f} — run: pl demo golden ${DEMO_SITE} --tier=live" >&2; exit 1; }
        scp -i "$ADMIN_KEY" -q "${GOLDEN_SRC}/${f}" "${BOX_USER}@${BOX_HOST}:/tmp/${f}"
        box "sudo install -o root -g root -m 0644 /tmp/${f} '${STATE_DIR}/golden/${f}' && rm -f /tmp/${f}"
    done
    box "cd '${STATE_DIR}/golden' && sha256sum -c golden.db.sql.gz.sha256 golden.files.tar.gz.sha256"
    # Staging the WRONG half's golden would put an image the wrapper refuses
    # ([G3] checks manifest.site) into the place it reads from — a nightly that
    # then fails every night. Cheaper to catch it here, once.
    box "test \"\$(jq -r '.site' '${STATE_DIR}/golden/golden.manifest.json')\" = '${DEMO_SITE}'" \
        || { echo "REFUSING: the staged golden manifest does not name ${DEMO_SITE}" >&2; exit 1; }
else
    say "3/5  Golden staging SKIPPED (pass --stage-golden)"
fi

################################################################################
if [[ "$stage_codes" == "true" ]]; then
    say "4/5  Staging hashed invite-code payload (hashes only — never plaintext)"
    payload="$(cd "$NWP_ROOT" && jq -c --argjson now "$(date +%s)" \
        '{version:1, codes:[.codes[] | select(.revoked == false and .expires > $now) | {bundle, hash, expires}]}' \
        "$CODES_SRC")"
    local_n="$(printf '%s' "$payload" | jq '.codes|length')"

    # This payload IS what the 01:00 reset restores, so a staging that quietly
    # lands nothing wipes every live invite code overnight with nothing saying
    # so. The old ending — a remote `jq -e '.codes|length'` — could not catch
    # that: `jq -e` fails only on null/false, and 0 is neither, so an empty or
    # truncated payload printed a bare number and exited 0. The count was
    # measured and then thrown away. Compare it instead.
    if [[ "$local_n" -eq 0 ]]; then
        echo "ERROR: refusing to stage 0 codes — tonight's reset would leave the box with no invite codes." >&2
        echo "       If revoking everything is genuinely intended, do that explicitly rather than staging an empty payload." >&2
        exit 1
    fi
    staged_n="$(printf '%s' "$payload" | box "cat > /tmp/codes-payload.json && sudo install -o root -g root -m 0644 /tmp/codes-payload.json '${STATE_DIR}/codes-payload.json' && rm -f /tmp/codes-payload.json && jq '.codes|length' '${STATE_DIR}/codes-payload.json'" | tr -d '\r\n')"
    if [[ "$staged_n" != "$local_n" ]]; then
        echo "ERROR: MISMATCH — sent ${local_n} code(s), the box reports '${staged_n:-<nothing>}'." >&2
        echo "       The staged payload is what tonight's reset restores; not trusting a partial write." >&2
        exit 1
    fi
    printf '   %s code(s) staged and read back from the box (sent %s)\n' "$staged_n" "$local_n"
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
        # every pre-existing line that is not OUR key must survive byte-identical
        # (that includes the OTHER half of the demo pair, whose comment differs)
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
echo "  ssh -i ${DEMO_KEY} ${BOX_USER}@${BOX_HOST} harvest-post   # exit 2 CANNOT VERIFY until the token is staged"
if [[ "$DEMO_SITE" == "nwd" ]]; then
    echo "  ssh -i ${DEMO_KEY} ${BOX_USER}@${BOX_HOST} feedback-status   # the ops#219 return leg; exit 2 CANNOT VERIFY until the token is staged"
fi
echo ""
echo "Then schedule it on met:"
echo "  pl demo schedule ${DEMO_SITE} --tier=live --via-key"
if [[ "$DEMO_SITE" == "nwd" ]]; then
    echo "  pl demo schedule ${DEMO_SITE} --feedback-status --via-key   # hourly return leg (ops#219)"
fi
