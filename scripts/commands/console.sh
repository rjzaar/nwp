#!/bin/bash
set -euo pipefail
################################################################################
# scripts/commands/console.sh — NWP Console lifecycle (pl console)
#
# The mesh-only, passkey-only web console (scripts/console/) deployed to the
# operator's console host — never only-on-a-box (the nwp-daily-audit lesson).
# See scripts/console/README.md.
#
# Operator-specific values (host alias, FQDN, tailnet IP, headscale URL) live
# in the gitignored nwp.yml under settings.console — NOT in this script
# (P61 leakage gate). See example.nwp.yml for the schema.
#
#   pl console deploy [--host <ssh-host>] [--no-restart]   rsync + venv + unit + health
#   pl console status [--host <ssh-host>]                  systemd + /health over mesh
#   pl console user add <name> --role viewer|operator|owner
#   pl console user reset <name>                           break-glass re-enrol
#   pl console user list | role <name> <role> | rm <name>
#   pl console enroll                                      Headscale pre-auth key runbook
#   pl console dns                                         upsert console A record (Linode API)
#   pl console cert                                        LE cert via DNS-01 (issued HERE,
#                                                          only cert+key pushed to host)
#   pl console logs [--host <ssh-host>]                    tail the console log
#
# Security notes:
#   * deploy NEVER copies tokens. The GitLab pane token (walled ops_note_token
#     pattern) is provisioned manually — see README "token" section.
#   * the Linode DNS token stays on THIS machine (.secrets.yml, infra tier);
#     the console host only ever receives the issued certificate + key.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"

# Resolve operator config: env override > nwp.yml chain > public placeholder.
_console_cfg_file() {
    # Explicit override wins outright (set-but-missing => unconfigured, no chain).
    if [ -n "${NWP_CONSOLE_CONFIG:-}" ]; then
        [ -f "$NWP_CONSOLE_CONFIG" ] && printf '%s' "$NWP_CONSOLE_CONFIG"
        return 0
    fi
    local f
    for f in "$REPO_ROOT/nwp.yml" "$HOME/nwp-instances/_global/nwp.yml" "$HOME/nwp/nwp.yml"; do
        [ -f "$f" ] && { printf '%s' "$f"; return 0; }
    done
    return 0
}

_console_cfg() { # $1 key under settings.console, $2 default
    local f v=""
    f=$(_console_cfg_file)
    if [ -n "$f" ] && command -v yq >/dev/null 2>&1; then
        v=$(yq e ".settings.console.$1 // \"\"" "$f" 2>/dev/null | grep -v '^null$' || true)
    fi
    printf '%s' "${v:-$2}"
}

CONSOLE_HOST="${NWP_CONSOLE_HOST:-$(_console_cfg host console-host)}"   # ssh alias
CONSOLE_FQDN="${NWP_CONSOLE_FQDN:-$(_console_cfg fqdn console.example.com)}"
CONSOLE_TAILNET_IP="${NWP_CONSOLE_TAILNET_IP:-$(_console_cfg tailnet_ip 100.64.0.2)}"
CONSOLE_PORT="${NWP_CONSOLE_PORT:-$(_console_cfg port 8600)}"
HEADSCALE_URL="${NWP_CONSOLE_HEADSCALE_URL:-$(_console_cfg headscale_url "https://<headscale-host>")}"
CONSOLE_SRC="$REPO_ROOT/scripts/console"
SECRETS_FILE="${NWP_SECRETS_FILE:-$REPO_ROOT/.secrets.yml}"
LINODE_DOMAIN_NAME="${CONSOLE_FQDN#*.}"   # apex derived from the console FQDN

_require_configured() {
    if [ "$CONSOLE_FQDN" = "console.example.com" ]; then
        print_error "settings.console is not configured in nwp.yml (see example.nwp.yml)."
        print_hint "Needed keys: settings.console.{host,fqdn,tailnet_ip,port,headscale_url}"
        return 1
    fi
}

show_help() {
    cat <<EOF
${BOLD}pl console${NC} — NWP Console (mesh-only web console on ${CONSOLE_HOST})

${BOLD}USAGE:${NC}
    pl console deploy [--host <ssh-host>] [--no-restart]
    pl console status [--host <ssh-host>]
    pl console user add <name> --role viewer|operator|owner
    pl console user reset <name>       (break-glass: shell-only, revokes passkeys)
    pl console user list | role <name> <role> | rm <name>
    pl console enroll                  (Headscale pre-auth key runbook for a new device)
    pl console dns                     (upsert ${CONSOLE_FQDN} A -> ${CONSOLE_TAILNET_IP})
    pl console cert                    (issue/renew the LE cert, DNS-01, push to host)
    pl console logs [--host <ssh-host>]

First run: dns -> cert -> deploy -> user add <you> --role owner -> open the
printed one-time enrolment link on the device that holds your passkey.
URL: https://${CONSOLE_FQDN}:${CONSOLE_PORT}/  (resolves everywhere, reachable on-mesh only)
EOF
}

_ssh() { ssh -o ConnectTimeout=10 "$CONSOLE_HOST" "$@"; }

# 0600 curl-config pattern (never a token in argv) — mirrors lib/gitlab-issues.sh.
_linode_curl() { # $1 method, $2 path, [$3 json payload]
    local method="$1" path="$2" payload="${3:-}"
    local yq_bin; yq_bin=$(command -v yq) || { print_error "yq required"; return 1; }
    local token; token=$("$yq_bin" e '.linode.api_token // ""' "$SECRETS_FILE" | grep -v '^null$')
    [ -n "$token" ] || { print_error "no linode.api_token in $SECRETS_FILE"; return 1; }
    local cfg; cfg=$(mktemp); chmod 600 "$cfg"
    printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$token" > "$cfg"
    local rc=0
    if [ -n "$payload" ]; then
        curl -sS -K "$cfg" -X "$method" "https://api.linode.com/v4${path}" -d "$payload" || rc=$?
    else
        curl -sS -K "$cfg" -X "$method" "https://api.linode.com/v4${path}" || rc=$?
    fi
    rm -f "$cfg"
    return $rc
}

cmd_dns() {
    print_info "Upserting ${CONSOLE_FQDN} A -> ${CONSOLE_TAILNET_IP} (Linode DNS)"
    local sub="${CONSOLE_FQDN%.${LINODE_DOMAIN_NAME}}"
    local domain_id
    domain_id=$(_linode_curl GET "/domains" | jq -r ".data[] | select(.domain==\"$LINODE_DOMAIN_NAME\") | .id")
    [ -n "$domain_id" ] || { print_error "domain $LINODE_DOMAIN_NAME not found in Linode DNS"; return 1; }
    local rec_id
    rec_id=$(_linode_curl GET "/domains/$domain_id/records?page_size=500" \
        | jq -r ".data[] | select(.type==\"A\" and .name==\"$sub\") | .id" | head -1)
    local payload
    payload=$(jq -nc --arg n "$sub" --arg t "$CONSOLE_TAILNET_IP" '{type:"A",name:$n,target:$t,ttl_sec:300}')
    if [ -n "$rec_id" ]; then
        _linode_curl PUT "/domains/$domain_id/records/$rec_id" "$payload" | jq -r '"updated record id \(.id): \(.name) -> \(.target)"'
    else
        _linode_curl POST "/domains/$domain_id/records" "$payload" | jq -r '"created record id \(.id): \(.name) -> \(.target)"'
    fi
    print_success "DNS upsert done (TTL 300; propagation may take a few minutes)"
}

cmd_cert() {
    print_info "Issuing/renewing Let's Encrypt cert for ${CONSOLE_FQDN} (DNS-01, local certbot venv)"
    local certdir="$HOME/.config/nwp-console-certs"
    local venv="$certdir/venv"
    mkdir -p "$certdir"; chmod 700 "$certdir"
    [ -x "$venv/bin/certbot" ] || {
        python3 -m venv "$venv"
        "$venv/bin/pip" install -q --upgrade pip certbot certbot-dns-linode
    }
    local yq_bin; yq_bin=$(command -v yq) || { print_error "yq required"; return 1; }
    local token; token=$("$yq_bin" e '.linode.api_token // ""' "$SECRETS_FILE" | grep -v '^null$')
    [ -n "$token" ] || { print_error "no linode.api_token in $SECRETS_FILE"; return 1; }
    local creds="$certdir/linode.ini"
    ( umask 077; printf 'dns_linode_key = %s\ndns_linode_version = 4\n' "$token" > "$creds" )
    "$venv/bin/certbot" certonly --non-interactive --agree-tos \
        --email "admin@${LINODE_DOMAIN_NAME}" \
        --authenticator dns-linode --dns-linode-credentials "$creds" \
        --dns-linode-propagation-seconds 120 \
        -d "$CONSOLE_FQDN" \
        --config-dir "$certdir/config" --work-dir "$certdir/work" --logs-dir "$certdir/logs"
    local live="$certdir/config/live/$CONSOLE_FQDN"
    [ -f "$live/fullchain.pem" ] || { print_error "certbot did not produce $live/fullchain.pem"; return 1; }
    print_info "Pushing cert + key to ${CONSOLE_HOST}:~/.config/nwp-console/tls/"
    _ssh 'umask 077 && mkdir -p ~/.config/nwp-console/tls'
    # -L: dereference certbot's symlinks
    scp -q -o ConnectTimeout=10 "$(readlink -f "$live/fullchain.pem")" "$CONSOLE_HOST":.config/nwp-console/tls/fullchain.pem
    scp -q -o ConnectTimeout=10 "$(readlink -f "$live/privkey.pem")"   "$CONSOLE_HOST":.config/nwp-console/tls/privkey.pem
    _ssh 'chmod 600 ~/.config/nwp-console/tls/*.pem'
    _ssh 'systemctl --user try-restart nwp-console 2>/dev/null || true'
    print_success "cert deployed (valid ~90 days — re-run 'pl console cert' before expiry)"
}

_write_default_env() {
    # GitLab host for the issues/CI panes (never the token — that's manual).
    local gitlab_host=""
    if command -v yq >/dev/null 2>&1 && [ -f "$SECRETS_FILE" ]; then
        gitlab_host=$(yq e '.gitlab.server.domain // ""' "$SECRETS_FILE" 2>/dev/null | grep -v '^null$' || true)
    fi
    _ssh 'umask 077 && mkdir -p ~/.config/nwp-console && [ -f ~/.config/nwp-console/env ] || cat > ~/.config/nwp-console/env' <<EOF
# NWP Console runtime config (created by pl console deploy; edit + restart)
NWP_CONSOLE_BIND=${CONSOLE_TAILNET_IP}
NWP_CONSOLE_PORT=${CONSOLE_PORT}
NWP_CONSOLE_RP_ID=${CONSOLE_FQDN}
NWP_CONSOLE_ORIGIN=https://${CONSOLE_FQDN}:${CONSOLE_PORT}
NWP_CONSOLE_TLS_CERT=%h/.config/nwp-console/tls/fullchain.pem
NWP_CONSOLE_TLS_KEY=%h/.config/nwp-console/tls/privkey.pem
NWP_CONSOLE_ROOT=%h/nwp
NWP_CONSOLE_GITLAB_HOST=${gitlab_host}
NWP_CONSOLE_DEMO_SITES=nwd
NWP_CONSOLE_CI_PROJECTS=nwp/nwp
NWP_CONSOLE_OPS_PROJECT=nwp/ops
# Quokka (local-LLM chat tab) — loopback ollama on this host only.
NWP_CONSOLE_QUOKKA_URL=http://127.0.0.1:11434
NWP_CONSOLE_QUOKKA_MODEL=llama3.3:70b
EOF
    # systemd EnvironmentFile doesn't expand %h — replace with the real home dir.
    _ssh 'sed -i "s|%h|$HOME|g" ~/.config/nwp-console/env'
}

cmd_deploy() {
    local restart=true
    [ "${1:-}" = "--no-restart" ] && restart=false
    print_info "Deploying NWP Console -> ${CONSOLE_HOST}"

    print_info "1/5 rsync source"
    _ssh 'mkdir -p ~/nwp-console/src'
    rsync -az --delete \
        --exclude '__pycache__' --exclude '*.pyc' --exclude '.pytest_cache' \
        "$CONSOLE_SRC/" "$CONSOLE_HOST":nwp-console/src/

    print_info "2/5 venv + deps"
    _ssh 'python3 -m venv ~/nwp-console/venv 2>/dev/null || true;
          ~/nwp-console/venv/bin/pip install -q --upgrade pip;
          ~/nwp-console/venv/bin/pip install -q -r ~/nwp-console/src/requirements.txt'

    print_info "3/5 config + unit"
    _write_default_env
    _ssh 'mkdir -p ~/.config/systemd/user && cp ~/nwp-console/src/nwp-console.service ~/.config/systemd/user/ && systemctl --user daemon-reload'

    if ! _ssh 'test -f ~/.config/nwp-console/tls/fullchain.pem'; then
        print_warning "No TLS cert on ${CONSOLE_HOST} — run 'pl console dns' then 'pl console cert' first."
        print_warning "The service will fail to start until the cert exists (WebAuthn requires HTTPS)."
    fi

    print_info "4/5 enable + restart"
    _ssh 'systemctl --user enable nwp-console >/dev/null 2>&1 || true'
    if [ "$restart" = true ]; then
        _ssh 'systemctl --user restart nwp-console'
        sleep 2
    fi

    print_info "5/5 health check over the mesh"
    if curl -fsS --max-time 8 --resolve "${CONSOLE_FQDN}:${CONSOLE_PORT}:${CONSOLE_TAILNET_IP}" \
            "https://${CONSOLE_FQDN}:${CONSOLE_PORT}/health" | grep -q '"ok"'; then
        print_success "healthy: https://${CONSOLE_FQDN}:${CONSOLE_PORT}/ (mesh-only)"
    else
        print_error "health check failed — try: pl console status / pl console logs"
        return 1
    fi
}

cmd_status() {
    print_info "systemd on ${CONSOLE_HOST}:"
    _ssh 'systemctl --user --no-pager -n 5 status nwp-console' || true
    print_info "health over the mesh:"
    curl -fsS --max-time 8 --resolve "${CONSOLE_FQDN}:${CONSOLE_PORT}:${CONSOLE_TAILNET_IP}" \
        "https://${CONSOLE_FQDN}:${CONSOLE_PORT}/health" && echo || print_error "unreachable"
    print_info "users:"
    _ssh 'cd ~/nwp-console/src && ~/nwp-console/venv/bin/python -m app.manage user-list' || true
}

_name_ok() { # local hygiene guard; authoritative validation is in app/store.py
    [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || { print_error "invalid username: $1"; return 1; }
}

cmd_user() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        add)
            local name="${1:-}"; shift || true
            local role="viewer"
            while [ $# -gt 0 ]; do case "$1" in --role) role="${2:-}"; shift 2 ;; --role=*) role="${1#--role=}"; shift ;; *) shift ;; esac; done
            [ -n "$name" ] || { print_error "usage: pl console user add <name> --role viewer|operator|owner"; return 1; }
            _name_ok "$name" || return 1
            [[ "$role" =~ ^(viewer|operator|owner)$ ]] || { print_error "role must be viewer|operator|owner"; return 1; }
            _ssh "cd ~/nwp-console/src && ~/nwp-console/venv/bin/python -m app.manage user-add '$name' --role '$role'"
            print_hint "Their device must be on the mesh first — see: pl console enroll"
            ;;
        reset)
            [ -n "${1:-}" ] || { print_error "usage: pl console user reset <name>"; return 1; }
            _name_ok "$1" || return 1
            _ssh "cd ~/nwp-console/src && ~/nwp-console/venv/bin/python -m app.manage user-reset '$1'"
            ;;
        role)
            [ -n "${2:-}" ] || { print_error "usage: pl console user role <name> <role>"; return 1; }
            _name_ok "$1" || return 1
            [[ "$2" =~ ^(viewer|operator|owner)$ ]] || { print_error "role must be viewer|operator|owner"; return 1; }
            _ssh "cd ~/nwp-console/src && ~/nwp-console/venv/bin/python -m app.manage user-role '$1' '$2'"
            ;;
        rm)
            [ -n "${1:-}" ] || { print_error "usage: pl console user rm <name>"; return 1; }
            _name_ok "$1" || return 1
            _ssh "cd ~/nwp-console/src && ~/nwp-console/venv/bin/python -m app.manage user-rm '$1'"
            ;;
        list|"")
            _ssh 'cd ~/nwp-console/src && ~/nwp-console/venv/bin/python -m app.manage user-list'
            ;;
        *) print_error "unknown: pl console user $sub"; return 1 ;;
    esac
}

cmd_enroll() {
    cat <<EOF
${BOLD}Enrolling a NEW DEVICE onto the mesh (once per device):${NC}

 1. On ${CONSOLE_HOST} (headscale control host), create a pre-auth key:
      ssh ${CONSOLE_HOST} 'sudo headscale preauthkeys create --user <headscale-user> --expiration 1h'
    (For a second dev, also add an ACL restricting their node to
     ${CONSOLE_TAILNET_IP}:${CONSOLE_PORT} only — console port, not ssh/mesh-wide.)

 2. On the device: install the Tailscale app, set the custom control server to
      ${HEADSCALE_URL}
    and log in with the pre-auth key.

 3. Verify: open https://${CONSOLE_FQDN}:${CONSOLE_PORT}/health — expect {"ok":true}.

Then create their console account:  pl console user add <name> --role viewer
EOF
}

cmd_logs() {
    _ssh 'tail -n 100 ~/nwp-console/console.log'
}

main() {
    local sub="${1:-}"; shift || true
    # global --host override
    local args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --host)   CONSOLE_HOST="${2:-}"; shift 2 ;;
            --host=*) CONSOLE_HOST="${1#--host=}"; shift ;;
            *) args+=("$1"); shift ;;
        esac
    done
    case "$sub" in
        -h|--help|"") show_help ;;
        deploy)  _require_configured && cmd_deploy "${args[@]:-}" ;;
        status)  _require_configured && cmd_status ;;
        user)    _require_configured && cmd_user "${args[@]:-}" ;;
        enroll)  cmd_enroll ;;
        dns)     _require_configured && cmd_dns ;;
        cert)    _require_configured && cmd_cert ;;
        logs)    _require_configured && cmd_logs ;;
        *) print_error "Unknown subcommand: $sub"; show_help; return 1 ;;
    esac
}

main "$@"
