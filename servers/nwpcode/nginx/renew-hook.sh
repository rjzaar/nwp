#!/usr/bin/env bash
#
# certbot renew deploy-hook — reload GitLab's bundled nginx after a cert renews.
#
# WHY THIS EXISTS (DR gap, see memory git-box-nginx-mechanism):
#   On the git.nwpcode.org box (97.107.137.88) the nginx that serves every
#   vhost is GitLab's BUNDLED nginx, not the system nginx.service. `certbot
#   renew` renews the cert files under /etc/letsencrypt/live/<host>/ but does
#   NOT know how to reload GitLab nginx, so renewed certs are not picked up
#   until something HUPs it. Without this hook, every cert on the box silently
#   keeps serving the OLD cert until it expires -> outage. This affects ALL
#   certs on the box, not just new ones.
#
# WHAT IT DOES:
#   certbot runs every executable in /etc/letsencrypt/renewal-hooks/deploy/
#   ONCE per successful renewal. This hook reloads GitLab nginx via
#   `gitlab-ctl hup nginx` (a graceful reload — NOT `systemctl reload nginx`,
#   which would target the inert/disabled system nginx and do nothing here).
#
# INSTALL (run ON the box, as root — see nginx/README.md):
#   sudo install -m 0755 renew-hook.sh \
#     /etc/letsencrypt/renewal-hooks/deploy/reload-gitlab-nginx.sh
#
# TEST (dry run, no reload actually fires unless a cert is due):
#   sudo certbot renew --dry-run
#
set -euo pipefail

log() { echo "[renew-hook $(date -u +%FT%TZ)] $*"; }

# gitlab-ctl is the only supported way to signal the bundled nginx on this box.
if ! command -v gitlab-ctl >/dev/null 2>&1; then
    log "ERROR: gitlab-ctl not found — cannot reload GitLab-bundled nginx." >&2
    log "       Renewed certificate(s) are NOT yet live. Reload manually:" >&2
    log "         sudo gitlab-ctl hup nginx" >&2
    exit 1
fi

# certbot exports RENEWED_DOMAINS on a deploy hook; log it for the audit trail.
log "certbot deploy-hook fired for: ${RENEWED_DOMAINS:-<all due certs>}"

# HUP = graceful reload: nginx re-reads config + certs without dropping conns.
if gitlab-ctl hup nginx; then
    log "GitLab nginx reloaded — renewed certificate(s) now live."
else
    log "ERROR: 'gitlab-ctl hup nginx' failed — renewed cert(s) NOT live." >&2
    exit 1
fi
