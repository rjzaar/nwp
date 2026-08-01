#!/bin/sh
# certbot deploy hook: reload the web server after a cert renews.
#
# WAS reload-gitlab-nginx.sh, which ran `/opt/gitlab/bin/gitlab-ctl hup nginx`.
# That was correct while this box served its sites from GitLab's bundled nginx.
# The 2026-07-31 box split moved GitLab away and purged /opt/gitlab entirely, so
# the hook could only fail — and because it is `set -e`, certbot counted the
# whole renewal as failed and the renewed certificate was never loaded. A hook
# written for a machine that no longer exists is worse than no hook: it turns a
# successful renewal into a reported failure and leaves the old cert serving.
#
# This box now runs the SYSTEM nginx under systemd.
#
# `nginx -t` first, deliberately: if the config is broken, a reload would fail
# anyway, and testing first puts the reason in the journal instead of a bare
# non-zero exit. (Exactly that happened on 2026-08-01 — conf.d/nwd.conf still
# included /opt/gitlab/embedded/conf/fastcgi_params, so nginx would not have
# come back from a restart at all.)
set -e
logger -t certbot-deploy "reloading nginx after renewal of ${RENEWED_LINEAGE:-unknown}"
nginx -t
systemctl reload nginx
logger -t certbot-deploy "nginx reloaded"
