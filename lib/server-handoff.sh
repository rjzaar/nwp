#!/usr/bin/env bash
# lib/server-handoff.sh — make a server migration atomic at the HTTP layer.
#
# THE PROBLEM THIS SOLVES
# A DNS cutover is not a switch, it is a fade. Resolvers hold the old A record
# for up to its TTL — and for records that were sitting on a 24-hour TTL when
# the migration started, "up to its TTL" can mean a full day after the change.
# During that fade BOTH boxes answer for the same hostname, each against its
# own database. Every write that lands on the old box in that window is lost at
# prune time, silently, and nothing in the estate would ever report it.
#
# So the traffic switch is done at the OLD box, not in DNS:
#
#   drain    — old box answers 503 for the migrated names. Nothing writes
#              anywhere. This is the only window with downtime, and it exists
#              so the database copy has a still target.
#   front    — old box PROXIES the migrated names to the new box. Stale-DNS
#              clients still reach the real, single, live copy of the site.
#              Traffic has now moved regardless of what DNS says.
#   restore  — put the old box's original vhosts back (the rollback).
#
# DNS is then flipped at leisure, and prune only happens once the old box is
# provably taking no traffic of its own.
#
# Every mode is reversible from the on-box backup taken before the first change.

[[ -n "${_NWP_SERVER_HANDOFF_LOADED:-}" ]] && return 0
_NWP_SERVER_HANDOFF_LOADED=1

# The vhost include directory is the same on both boxes; the backup lives
# beside it so a rollback never depends on the workstation being reachable.
HANDOFF_CONF_DIR="${HANDOFF_CONF_DIR:-/etc/nginx/conf.d}"
HANDOFF_BACKUP_DIR="${HANDOFF_BACKUP_DIR:-/etc/nginx/conf.d-handoff-original}"

# handoff_server_names <ssh-prefix>
# Every server_name nginx actually serves on the box, one per line. Read from
# the running configuration, not from a list someone maintained by hand.
handoff_server_names() {
    local prefix="$1"
    $prefix "sudo grep -rhE '^[[:space:]]*server_name' ${HANDOFF_CONF_DIR}/*.conf 2>/dev/null" </dev/null \
        | sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/;.*$//' \
        | tr ' ' '\n' | sed '/^$/d; /^_$/d' | sort -u
}

# handoff_render_drain <name> <has-cert:0|1>
# A maintenance vhost. 503 with Retry-After is the honest status: the service
# exists and is coming back. ACME is left reachable so a renewal that happens
# to fall in the window is not collateral damage.
#
# The 443 block is emitted only when a certificate exists. Not every vhost is
# HTTPS (avctest is plain HTTP), and referencing a missing certificate makes
# nginx refuse to load the WHOLE configuration — taking every other site down
# with it. Skipping such a name instead is not an option: it would keep serving
# from the old box's database while everything else had moved, which is the
# split-brain this command exists to prevent.
handoff_render_drain() {
    local n="$1" has_cert="${2:-1}"
    cat <<EOF
# ${n} — MIGRATION DRAIN (pl server handoff drain). Restore with:
#   pl server handoff restore <server>
server {
    listen 80;
    server_name ${n};
    location ^~ /.well-known/acme-challenge/ { root /var/www/html; allow all; }
    location / { return 503; }
}
EOF
    [[ "$has_cert" == "1" ]] || return 0
    cat <<EOF
server {
    listen 443 ssl http2;
    server_name ${n};
    ssl_certificate /etc/letsencrypt/live/${n}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${n}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header Retry-After 900 always;
    location / { return 503; }
}
EOF
}

# handoff_render_front <name> <target-ip>
# Proxy to the new box over TLS with SNI, so the upstream presents the
# certificate for the ORIGINAL hostname and the application still sees its own
# Host header — anything else and Drupal/Moodle generate links to the wrong
# site. X-Forwarded-* are set so the app sees the real client, not this box.
handoff_render_front() {
    local n="$1" ip="$2" has_cert="${3:-1}"
    cat <<EOF
# ${n} — MIGRATION FRONT (pl server handoff front -> ${ip}).
# Serves clients whose resolver still holds this box's A record. Restore with:
#   pl server handoff restore <server>
server {
    listen 80;
    server_name ${n};
    location / {
        proxy_pass http://${ip};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
    }
}
EOF
    [[ "$has_cert" == "1" ]] || return 0
    cat <<EOF
server {
    listen 443 ssl http2;
    server_name ${n};
    ssl_certificate /etc/letsencrypt/live/${n}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${n}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 256M;

    location / {
        proxy_pass https://${ip};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_ssl_server_name on;
        proxy_ssl_name \$host;
        proxy_http_version 1.1;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_buffering off;
    }
}
EOF
}
