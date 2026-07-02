#!/bin/bash

################################################################################
# NWP nwptoolkit (vid) Deploy Library
#
# Deploys the nwptoolkit transcript-search app (the vid site, and every future
# <slug>v.<example-prod-domain> vid site) to ONE shared instance on the Linode.
#
# ONE nwptoolkit process listens on 127.0.0.1:8071; a per-vhost nginx reverse
# proxy (templates/nginx-vhost-nwptoolkit-proxy.conf.tmpl) forwards each set's
# domain with `proxy_set_header Host $host`, and the FastAPI Host->set
# middleware scopes the request to the matching set (public_surface.domain in
# sets/<slug>/set.yml).
#
# What ships (rsync): the nwptoolkit repo + build/index.db + sets/*/transcripts/
# What does NOT ship: sets/*/audio/ (huge, not needed to serve), .venv, .git,
#                     __pycache__ (venv is rebuilt remotely).
#
# Remote layout: /opt/nwptoolkit (code + index), /opt/nwptoolkit/.venv (venv),
#                /etc/systemd/system/nwptoolkit.service (one shared unit).
#
# Idempotent: safe to re-run (rsync deltas, venv reused, unit rewritten only
# when changed). --dry-run prints the full rsync/ssh plan and executes nothing.
#
# Dependencies: lib/ui.sh, lib/server-resolver.sh
# Usage:  source "$SCRIPT_DIR/lib/nwptoolkit-deploy.sh"; nwptoolkit_deploy [--dry-run]
#   or:   bash lib/nwptoolkit-deploy.sh [--dry-run] [--server NAME] [--source DIR]
################################################################################

# Guard against multiple sourcing
if [ "${_NWPTOOLKIT_DEPLOY_LOADED:-}" = "1" ]; then
    return 0 2>/dev/null || true
fi
_NWPTOOLKIT_DEPLOY_LOADED=1

# Resolve project root and source dependencies.
_NWPTK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NWP_DIR="${NWP_DIR:-${PROJECT_ROOT:-$(cd "$_NWPTK_LIB_DIR/.." && pwd)}}"

if [ -z "${_UI_LOADED:-}" ] && [ -f "$_NWPTK_LIB_DIR/ui.sh" ]; then
    # shellcheck source=/dev/null
    source "$_NWPTK_LIB_DIR/ui.sh"
fi
# shellcheck source=/dev/null
source "$_NWPTK_LIB_DIR/server-resolver.sh"

# --- deploy tunables (override via env) ---------------------------------------
: "${NWPTOOLKIT_SERVER:=nwpcode}"                 # server name (lib/server-resolver.sh)
: "${NWPTOOLKIT_SOURCE:=$HOME/nwptoolkit}"        # local repo to ship
: "${NWPTOOLKIT_REMOTE_DIR:=/opt/nwptoolkit}"     # remote install dir
: "${NWPTOOLKIT_PORT:=8071}"                      # shared bind port (127.0.0.1)
: "${NWPTOOLKIT_SERVICE:=nwptoolkit}"             # systemd unit name
: "${NWPTOOLKIT_PYTHON:=python3}"                 # remote interpreter for the venv

################################################################################
# Helpers
################################################################################

# Assemble the ssh option flags for the target server (IdentitiesOnly + key).
# Echoes flags on one line; empty if no key resolved (falls back to agent/default).
_nwptk_ssh_opts() {
    local server="$1"
    local key opts
    opts="-o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
    key="$(get_server_ssh_key "$server" 2>/dev/null || true)"
    if [ -n "$key" ] && [ -f "$key" ]; then
        opts="$opts -i $key"
    fi
    echo "$opts"
}

################################################################################
# Main entrypoint
################################################################################

# nwptoolkit_deploy [--dry-run] [--server NAME] [--source DIR]
# Returns 0 on success, non-zero on failure.
nwptoolkit_deploy() {
    local dry_run=0
    local server="$NWPTOOLKIT_SERVER"
    local source_dir="$NWPTOOLKIT_SOURCE"

    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry_run=1 ;;
            --server)  server="$2"; shift ;;
            --server=*) server="${1#*=}" ;;
            --source)  source_dir="$2"; shift ;;
            --source=*) source_dir="${1#*=}" ;;
            -h|--help)
                cat <<EOF
Usage: nwptoolkit_deploy [--dry-run] [--server NAME] [--source DIR]
  --dry-run       Print the rsync/ssh plan and exit (no changes made).
  --server NAME   Target server (default: $NWPTOOLKIT_SERVER; see servers/).
  --source DIR    Local nwptoolkit repo to ship (default: $NWPTOOLKIT_SOURCE).
Ships the repo + build/index.db + sets/*/transcripts/ (NOT audio, NOT .venv)
to $NWPTOOLKIT_REMOTE_DIR and installs one shared systemd unit on 127.0.0.1:$NWPTOOLKIT_PORT.
EOF
                return 0 ;;
            *) print_error "nwptoolkit_deploy: unknown argument: $1"; return 2 ;;
        esac
        shift
    done

    print_header "Deploy nwptoolkit (vid) -> $server"

    # --- resolve target ------------------------------------------------------
    local ip user ssh_key ssh_opts
    ip="$(get_server_ip "$server" 2>/dev/null || true)"
    user="$(get_server_user "$server" 2>/dev/null || true)"
    ssh_key="$(get_server_ssh_key "$server" 2>/dev/null || true)"
    [ -z "$user" ] && user="gitlab"
    if [ -z "$ip" ]; then
        print_error "Could not resolve IP for server '$server' (lib/server-resolver.sh)."
        return 1
    fi
    ssh_opts="$(_nwptk_ssh_opts "$server")"
    local target="${user}@${ip}"

    # --- validate local source ----------------------------------------------
    if [ ! -d "$source_dir" ]; then
        print_error "Source repo not found: $source_dir"
        return 1
    fi
    if [ ! -f "$source_dir/pyproject.toml" ]; then
        print_error "$source_dir does not look like the nwptoolkit repo (no pyproject.toml)."
        return 1
    fi
    if [ ! -f "$source_dir/build/index.db" ]; then
        print_warning "No build/index.db in $source_dir — the served index will be empty until one is built."
    fi

    # --- rsync spec ----------------------------------------------------------
    # Trailing slash on source => copy contents into remote dir.
    local -a rsync_excludes=(
        "--exclude=.venv/"
        "--exclude=.git/"
        "--exclude=__pycache__/"
        "--exclude=*.pyc"
        "--exclude=sets/*/audio/"          # audio never leaves the laptop
        "--exclude=.pytest_cache/"
        "--exclude=*.egg-info/"
    )
    local -a rsync_cmd=(
        rsync -az --delete --human-readable
        -e "ssh $ssh_opts"
        "${rsync_excludes[@]}"
        "${source_dir}/"
        "${target}:${NWPTOOLKIT_REMOTE_DIR}/"
    )

    # --- remote provisioning script (idempotent) -----------------------------
    # Rendered once so both --dry-run (print) and the real run (execute) agree.
    local remote_script
    remote_script="$(_nwptk_remote_script)"

    if [ "$dry_run" -eq 1 ]; then
        echo
        print_info "DRY RUN — no changes will be made."
        echo
        echo "Target server : $server ($target)"
        echo "SSH key       : ${ssh_key:-<agent/default>}"
        echo "SSH opts      : ssh $ssh_opts"
        echo "Local source  : $source_dir"
        echo "Remote dir    : $NWPTOOLKIT_REMOTE_DIR"
        echo "Bind          : 127.0.0.1:$NWPTOOLKIT_PORT (systemd unit: ${NWPTOOLKIT_SERVICE}.service)"
        echo
        echo "STEP 1/3 — rsync repo + index + transcripts (NOT audio, NOT .venv):"
        printf '  '; printf '%q ' "${rsync_cmd[@]}"; echo
        echo
        echo "  (add --dry-run to rsync to preview file deltas without transferring)"
        echo
        echo "STEP 2/3 — ssh remote provisioning ($target):"
        echo "  ssh $ssh_opts $target 'bash -s' <<'REMOTE'"
        echo "$remote_script" | sed 's/^/    /'
        echo "  REMOTE"
        echo
        echo "STEP 3/3 — verify: curl -sI http://127.0.0.1:$NWPTOOLKIT_PORT/ on $server (expect 200)."
        echo
        print_status "OK" "Dry-run plan printed; nothing executed."
        return 0
    fi

    # --- execute -------------------------------------------------------------
    print_info "STEP 1/3 — rsync -> ${target}:${NWPTOOLKIT_REMOTE_DIR}/"
    if ! "${rsync_cmd[@]}"; then
        print_error "rsync failed."
        return 1
    fi
    print_status "OK" "Repo + index + transcripts synced."

    print_info "STEP 2/3 — remote venv + pip install -e . + systemd unit"
    # shellcheck disable=SC2086
    if ! ssh $ssh_opts "$target" 'bash -s' <<REMOTE
$remote_script
REMOTE
    then
        print_error "Remote provisioning failed."
        return 1
    fi
    print_status "OK" "Remote venv built and ${NWPTOOLKIT_SERVICE}.service (re)started."

    print_info "STEP 3/3 — verify service on 127.0.0.1:$NWPTOOLKIT_PORT"
    # shellcheck disable=SC2086
    if ssh $ssh_opts "$target" "curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1:${NWPTOOLKIT_PORT}/ 2>/dev/null | grep -q 200"; then
        print_status "OK" "nwptoolkit responding on 127.0.0.1:$NWPTOOLKIT_PORT"
    else
        print_warning "Service did not answer 200 yet — check: journalctl -u ${NWPTOOLKIT_SERVICE} -n50"
    fi

    print_status "OK" "nwptoolkit deployed to $server."
    return 0
}

# Render the idempotent remote provisioning script (heredoc body).
# Kept in a function so --dry-run prints the exact same commands that run.
_nwptk_remote_script() {
    cat <<REMOTE_EOF
set -euo pipefail
REMOTE_DIR="${NWPTOOLKIT_REMOTE_DIR}"
SERVICE="${NWPTOOLKIT_SERVICE}"
PORT="${NWPTOOLKIT_PORT}"
PYTHON="${NWPTOOLKIT_PYTHON}"

# The rsync (step 1) creates \$REMOTE_DIR; make sure sudo-owned parents exist
# and the code dir is owned by the deploying user.
sudo mkdir -p "\$REMOTE_DIR"
sudo chown -R "\$(id -un):\$(id -gn)" "\$REMOTE_DIR"

# 1) Virtualenv (reused if present) + editable install of the package.
if [ ! -x "\$REMOTE_DIR/.venv/bin/python" ]; then
    "\$PYTHON" -m venv "\$REMOTE_DIR/.venv"
fi
"\$REMOTE_DIR/.venv/bin/pip" install --quiet --upgrade pip
"\$REMOTE_DIR/.venv/bin/pip" install --quiet -e "\$REMOTE_DIR"

# 2) One shared systemd unit on 127.0.0.1:\$PORT. Rewritten each run; systemd
#    only reloads/restarts when the content actually changed.
UNIT_PATH="/etc/systemd/system/\${SERVICE}.service"
NEW_UNIT="\$(cat <<UNIT
[Unit]
Description=nwptoolkit search (vid) — FastAPI serve over transcript sets (shared)
After=network.target

[Service]
Type=simple
User=\$(id -un)
WorkingDirectory=\$REMOTE_DIR
Environment=NWPTOOLKIT_ROOT=\$REMOTE_DIR
Environment=NWPTOOLKIT_DB=\$REMOTE_DIR/build/index.db
ExecStart=\$REMOTE_DIR/.venv/bin/nwptoolkit serve --host 127.0.0.1 --port \$PORT
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
)"

if ! sudo test -f "\$UNIT_PATH" || ! echo "\$NEW_UNIT" | sudo cmp -s - "\$UNIT_PATH"; then
    echo "\$NEW_UNIT" | sudo tee "\$UNIT_PATH" >/dev/null
    sudo systemctl daemon-reload
fi
sudo systemctl enable "\$SERVICE" >/dev/null 2>&1 || true
sudo systemctl restart "\$SERVICE"

# 3) Local readiness probe (nginx/certs handled separately by pl live).
sleep 2
curl -fsS -o /dev/null -w 'nwptoolkit http_code=%{http_code}\n' "http://127.0.0.1:\$PORT/" || true
REMOTE_EOF
}

# Allow direct execution: `bash lib/nwptoolkit-deploy.sh [--dry-run]`.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    nwptoolkit_deploy "$@"
    exit $?
fi
