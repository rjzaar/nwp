#!/bin/bash

################################################################################
# NWP SSH Library
#
# Provides SSH connection helpers with security controls
# Source this file: source "$PROJECT_ROOT/lib/ssh.sh"
#
# Security Features:
# - NWP_SSH_STRICT environment variable for host key verification
# - User warnings about MITM vulnerabilities
# - Standardized SSH options across all connections
################################################################################

# Get SSH host key checking mode based on NWP_SSH_STRICT setting
# Returns: "yes" for strict mode, "accept-new" for convenient mode
get_ssh_host_key_checking() {
    if [ "${NWP_SSH_STRICT:-0}" = "1" ]; then
        echo "yes"
    else
        echo "accept-new"
    fi
}

# Display warning about SSH host key verification mode
# Call this before establishing first SSH connection
show_ssh_security_warning() {
    if [ "${NWP_SSH_STRICT:-0}" != "1" ]; then
        echo "⚠️  SSH Host Key Verification: Using 'accept-new' mode"
        echo "    First connection will accept server fingerprint automatically"
        echo "    This is convenient but vulnerable to MITM on first connection"
        echo ""
        echo "    For strict mode: export NWP_SSH_STRICT=1"
        echo ""
    fi
}

# Get standard SSH options array for NWP connections
# Usage: get_ssh_options
# Returns array via stdout (use mapfile or read -a to capture)
#
# IdentitiesOnly=yes is critical: without it, ssh offers every key in ~/.ssh/
# (and every key in the agent) on every connection. With ~10+ keys this trips
# fail2ban (default maxretry=3) and locks the user out. See lib/ssh.sh
# nwp_ssh() / nwp_scp() / nwp_rsync() wrappers for the recommended way to
# build commands; this function is kept for backwards compatibility.
get_ssh_options() {
    local host_key_mode
    host_key_mode=$(get_ssh_host_key_checking)

    # Return options as newline-separated list
    echo "-o"
    echo "IdentitiesOnly=yes"
    echo "-o"
    echo "StrictHostKeyChecking=$host_key_mode"
    echo "-o"
    echo "ConnectTimeout=10"
}

# Build SSH command with standard security options
# Usage: ssh_cmd=($(build_ssh_command))
#        "${ssh_cmd[@]}" user@host "command"
build_ssh_command() {
    local host_key_mode
    host_key_mode=$(get_ssh_host_key_checking)

    echo "ssh"
    echo "-o"
    echo "IdentitiesOnly=yes"
    echo "-o"
    echo "StrictHostKeyChecking=$host_key_mode"
    echo "-o"
    echo "ConnectTimeout=10"
}

# NWP_SSH_HARDENING_OPTS: inline options string for scripts that can't
# easily migrate to nwp_ssh(). Splice into existing ssh/scp commands:
#   ssh $NWP_SSH_HARDENING_OPTS -o BatchMode=yes "user@host" "..."
# IdentitiesOnly=yes prevents ssh from offering every key in ~/.ssh/ on
# every connection (the root cause of the fail2ban lockout bug).
# shellcheck disable=SC2034  # used by sourcing scripts
NWP_SSH_HARDENING_OPTS="-o IdentitiesOnly=yes"

# nwp_ssh_opts: returns ssh hardening options as a single space-separated
# string suitable for inline expansion in existing ssh/scp commands. This is
# the main migration helper — splice the result into a bare ssh/scp call:
#
#   ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "..."
#
# What it adds:
#   1. -o IdentitiesOnly=yes  (always — prevents the fail2ban lockout)
#   2. -i <key>               (when nwp.yml has an ssh_key for this site)
#   3. ControlMaster/ControlPath/ControlPersist multiplexing (unless
#      disabled — see _nwp_ssh_multiplex_enabled below)
#
# Why both: IdentitiesOnly alone is not enough for users whose key has a
# non-default filename (e.g. ~/.ssh/nwp). Without -i, ssh would skip their
# key entirely and try only id_rsa / id_ed25519 / etc.
#
# If $1 is empty or unset, only the IdentitiesOnly option is returned —
# safe to use even when there's no site context.
# Reap stale ControlMaster sockets left behind by a killed/timed-out deploy.
#
# A dead `~/.ssh/nwp-cm-*` socket (e.g. after `stg2live` was SIGKILLed mid-run)
# makes the NEXT `ssh -o ControlMaster=auto` HANG indefinitely trying to reuse
# it — the failure that stalled a live deploy at "Testing SSH connection"
# (2026-07-22). For each socket, ask the master if it is alive (`ssh -O check`,
# bounded by `timeout` so even a wedged socket can't hang us); remove any that
# do not answer. Idempotent, safe to run repeatedly, no-op when no sockets exist.
nwp_ssh_reap_stale_masters() {
    local sock
    for sock in "$HOME"/.ssh/nwp-cm-*; do
        [ -S "$sock" ] || continue
        if ! timeout 5 ssh -O check -o ControlPath="$sock" nwp-reap-probe >/dev/null 2>&1; then
            rm -f "$sock"
        fi
    done
    return 0
}

nwp_ssh_opts() {
    local name="${1:-}"
    # ConnectTimeout bounds a wedged connection (incl. a half-open multiplex
    # master) so a bad socket fails fast instead of hanging the deploy.
    local opts="-o IdentitiesOnly=yes -o ConnectTimeout=10"
    if [ -n "$name" ]; then
        local key
        key=$(get_ssh_key "$name" 2>/dev/null)
        # Only add -i when the file actually exists. ssh errors out if -i
        # points at a missing file, and the default get_ssh_key fallback
        # (~/.ssh/nwp) does not exist on most users' machines.
        if [ -n "$key" ] && [ -f "$key" ]; then
            opts="$opts -i $key"
        fi
    fi
    # 3. Connection multiplexing (touch economy for sk-key transport, ops#79
    #    design 1). When the transport key is hardware-backed (ed25519-sk on
    #    a Solo), every NEW ssh connection needs a physical touch. A deploy
    #    session makes dozens of ssh/scp calls; ControlMaster reuses one
    #    authenticated connection for all of them, so the session costs ~1
    #    transport touch instead of dozens. ControlPersist=600 bounds the
    #    reuse window to 10 idle minutes; %C hashes host+port+user so
    #    sockets never collide across servers or users. Harmless for
    #    non-hardware keys (just faster).
    if _nwp_ssh_multiplex_enabled; then
        # Clear any dead master sockets once per process before the first
        # multiplexed connection, so a socket orphaned by a killed run can't
        # hang us. Guarded so the reap runs once, not on every ssh call.
        if [ -z "${_NWP_SSH_REAPED:-}" ]; then
            nwp_ssh_reap_stale_masters
            export _NWP_SSH_REAPED=1
        fi
        opts="$opts -o ControlMaster=auto -o ControlPath=$HOME/.ssh/nwp-cm-%C -o ControlPersist=600"
    fi
    echo "$opts"
}

# Should nwp_ssh_opts add ControlMaster multiplexing options?
# Kill-switches (either disables):
#   - env: NWP_SSH_NO_MULTIPLEX=1
#   - nwp.yml: settings.ssh.multiplex: false (read via get_setting when
#     lib/common.sh is in scope; env-only otherwise)
_nwp_ssh_multiplex_enabled() {
    if [ "${NWP_SSH_NO_MULTIPLEX:-0}" = "1" ]; then
        return 1
    fi
    if declare -F get_setting &>/dev/null; then
        local v
        v=$(get_setting "ssh.multiplex" "true" 2>/dev/null)
        if [ "$v" = "false" ]; then
            return 1
        fi
    fi
    return 0
}

# Check if strict SSH mode is enabled
# Returns: 0 if strict, 1 if not
is_ssh_strict_mode() {
    [ "${NWP_SSH_STRICT:-0}" = "1" ]
}

################################################################################
# Security Documentation
################################################################################

# SSH Host Key Verification Modes:
#
# accept-new (default):
#   - Automatically accepts new host keys on first connection
#   - Subsequent connections verify against saved key
#   - Vulnerable to MITM on first connection only
#   - Convenient for development and testing
#
# yes (strict mode, NWP_SSH_STRICT=1):
#   - Only connects to hosts with known keys in known_hosts
#   - Rejects any unknown host key
#   - Maximum security, prevents MITM attacks
#   - Requires manual key management
#
# For production deployments, consider using NWP_SSH_STRICT=1 and
# pre-populating ~/.ssh/known_hosts with verified host keys.
#
# See docs/SECURITY.md for complete SSH security documentation.
#

################################################################################
# SSH User Resolution
################################################################################

# Get the SSH user for a server or site
# Resolution chain:
#   1. sites.<name>.live.ssh_user (explicit per-site)
#   2. linode.servers.<ref>.ssh_user (server config)
#   3. Parse user from ssh_host if user@host format
#   4. Recipe default ssh_user
#   5. Fallback to root
# Usage: get_ssh_user <site_or_server_name> [config_file]
get_ssh_user() {
    local name="$1"
    local config_file="${2:-${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/nwp.yml}"
    local user=""

    # F23: try per-site .nwp.yml first (via get_site_config_value if available)
    if declare -F get_site_config_value &>/dev/null; then
        user=$(get_site_config_value "$name" '.live.ssh_user' "")
        if [[ -n "$user" ]]; then
            echo "$user"
            return
        fi
        # Also try resolving via server name → server config
        local server_name
        server_name=$(get_site_config_value "$name" '.live.server' "")
        if [[ -n "$server_name" ]] && declare -F get_server_config &>/dev/null; then
            user=$(get_server_config "$server_name" "ssh_user" "")
            if [[ -n "$user" ]]; then
                echo "$user"
                return
            fi
        fi
    fi

    if [[ ! -f "$config_file" ]]; then
        echo "root"
        return
    fi

    # Legacy: Check sites.<name>.live.ssh_user in root nwp.yml
    user=$(awk -v site="$name" '
        /^sites:/{in_sites=1; next}
        in_sites && /^  [a-zA-Z]/{
            s=$1; sub(/:$/, "", s)
            current_site=s
        }
        in_sites && current_site==site && /^    live:/{in_live=1; next}
        in_live && /^      ssh_user:/{print $2; exit}
        in_live && /^    [a-zA-Z]/{in_live=0}
        in_sites && /^[a-zA-Z]/{in_sites=0}
    ' "$config_file" 2>/dev/null)

    if [[ -n "$user" ]]; then
        echo "$user"
        return
    fi

    # 2. Check linode.servers.<name>.ssh_user
    user=$(awk -v srv="$name" '
        /^linode:/{in_linode=1; next}
        in_linode && /^  servers:/{in_servers=1; next}
        in_servers && /^    [a-zA-Z]/{
            s=$1; sub(/:$/, "", s)
            current_srv=s
        }
        in_servers && current_srv==srv && /^      ssh_user:/{print $2; exit}
        in_servers && /^[a-zA-Z]/{in_servers=0}
    ' "$config_file" 2>/dev/null)

    if [[ -n "$user" ]]; then
        echo "$user"
        return
    fi

    # 3. Parse user@host format from ssh_host
    local ssh_host=""
    ssh_host=$(awk -v srv="$name" '
        /^linode:/{in_linode=1; next}
        in_linode && /^  servers:/{in_servers=1; next}
        in_servers && /^    [a-zA-Z]/{
            s=$1; sub(/:$/, "", s)
            current_srv=s
        }
        in_servers && current_srv==srv && /^      ssh_host:/{print $2; exit}
    ' "$config_file" 2>/dev/null)

    if [[ "$ssh_host" == *"@"* ]]; then
        echo "${ssh_host%%@*}"
        return
    fi

    # 4. Check recipe default (if site has a recipe)
    local recipe=""
    recipe=$(awk -v site="$name" '
        /^sites:/{in_sites=1; next}
        in_sites && /^  [a-zA-Z]/{
            s=$1; sub(/:$/, "", s)
            current_site=s
        }
        in_sites && current_site==site && /^    recipe:/{print $2; exit}
    ' "$config_file" 2>/dev/null)

    if [[ -n "$recipe" ]]; then
        user=$(awk -v r="$recipe" '
            /^recipes:/{in_recipes=1; next}
            in_recipes && /^  [a-zA-Z]/{
                s=$1; sub(/:$/, "", s)
                current_recipe=s
            }
            in_recipes && current_recipe==r && /^    ssh_user:/{print $2; exit}
        ' "$config_file" 2>/dev/null)

        if [[ -n "$user" ]]; then
            echo "$user"
            return
        fi
    fi

    # 5. Default to root
    echo "root"
}

# Get SSH connection string for a server
# Usage: get_ssh_connection <site_or_server_name> [config_file]
# Returns: user@host
get_ssh_connection() {
    local name="$1"
    local config_file="${2:-${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/nwp.yml}"
    local user host

    user=$(get_ssh_user "$name" "$config_file")

    # Get host from server config
    host=$(awk -v srv="$name" '
        /^linode:/{in_linode=1; next}
        in_linode && /^  servers:/{in_servers=1; next}
        in_servers && /^    [a-zA-Z]/{
            s=$1; sub(/:$/, "", s)
            current_srv=s
        }
        in_servers && current_srv==srv && /^      ssh_host:/{
            val=$2
            # Strip user@ prefix if present
            sub(/.*@/, "", val)
            print val
            exit
        }
    ' "$config_file" 2>/dev/null)

    if [[ -z "$host" ]]; then
        # Try sites.<name>.live.server_ip or ssh_host
        host=$(awk -v site="$name" '
            /^sites:/{in_sites=1; next}
            in_sites && /^  [a-zA-Z]/{
                s=$1; sub(/:$/, "", s)
                current_site=s
            }
            in_sites && current_site==site && /^    live:/{in_live=1; next}
            in_live && /^      ssh_host:/{
                val=$2; sub(/.*@/, "", val); print val; exit
            }
            in_live && /^      server_ip:/{print $2; exit}
            in_live && /^      server:/{print $2; exit}
            in_live && /^    [a-zA-Z]/{in_live=0}
        ' "$config_file" 2>/dev/null)
    fi

    echo "${user}@${host}"
}

# Get SSH key path for a server or site
# Resolution chain:
#   1. sites/<name>/.nwp.yml live.ssh_key (per-site config, F23)
#   2. servers/<ref>/.nwp-server.yml ssh_key (via site's live.server)
#   3. sites.<name>.live.ssh_key (legacy root nwp.yml)
#   4. linode.servers.<ref>.ssh_key (legacy root nwp.yml)
#   5. Default to ~/.ssh/nwp
# Arbitrary paths are honored (with ~ expansion) — e.g. pointing a site or
# server at a hardware-backed key (~/.ssh/id_ed25519_sk) is pure config.
# Usage: get_ssh_key <site_or_server_name> [config_file]
get_ssh_key() {
    local name="$1"
    local config_file="${2:-${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/nwp.yml}"
    local key=""

    # F23: try per-site .nwp.yml first (mirrors get_ssh_user above)
    if declare -F get_site_config_value &>/dev/null; then
        key=$(get_site_config_value "$name" '.live.ssh_key' "")
        if [[ -n "$key" ]]; then
            echo "${key/#\~/$HOME}"
            return
        fi
        # Also try resolving via server name → server config
        local server_name
        server_name=$(get_site_config_value "$name" '.live.server' "")
        if [[ -n "$server_name" ]] && declare -F get_server_config &>/dev/null; then
            key=$(get_server_config "$server_name" "ssh_key" "")
            if [[ -n "$key" ]]; then
                echo "${key/#\~/$HOME}"
                return
            fi
        fi
    fi

    if [[ ! -f "$config_file" ]]; then
        echo "$HOME/.ssh/nwp"
        return
    fi

    # 1. Check sites.<name>.live.ssh_key
    key=$(awk -v site="$name" '
        /^sites:/{in_sites=1; next}
        in_sites && /^  [a-zA-Z]/{
            s=$1; sub(/:$/, "", s)
            current_site=s
        }
        in_sites && current_site==site && /^    live:/{in_live=1; next}
        in_live && /^      ssh_key:/{print $2; exit}
        in_live && /^    [a-zA-Z]/{in_live=0}
        in_sites && /^[a-zA-Z]/{in_sites=0}
    ' "$config_file" 2>/dev/null)

    if [[ -n "$key" ]]; then
        echo "${key/#\~/$HOME}"
        return
    fi

    # 2. Check linode.servers.<name>.ssh_key
    key=$(awk -v srv="$name" '
        /^linode:/{in_linode=1; next}
        in_linode && /^  servers:/{in_servers=1; next}
        in_servers && /^    [a-zA-Z]/{
            s=$1; sub(/:$/, "", s)
            current_srv=s
        }
        in_servers && current_srv==srv && /^      ssh_key:/{print $2; exit}
        in_servers && /^[a-zA-Z]/{in_servers=0}
    ' "$config_file" 2>/dev/null)

    if [[ -n "$key" ]]; then
        echo "${key/#\~/$HOME}"
        return
    fi

    # 3. Default to ~/.ssh/nwp
    echo "$HOME/.ssh/nwp"
}

# Build the standard NWP ssh argument list for a given site/server name.
# Resolves the right key from nwp.yml (via get_ssh_key) and prepends the
# IdentitiesOnly hardening option. The resulting array can be spliced into
# any ssh-style command:
#
#   local args
#   read -ra args < <(_nwp_ssh_args_for "$base_name")
#   ssh "${args[@]}" -o BatchMode=yes "${ssh_user}@${server_ip}" "..."
#
# This is the building block for nwp_ssh / nwp_scp; most callers should use
# those wrappers instead.
_nwp_ssh_args_for() {
    local name="$1"
    local key=""

    # IdentitiesOnly is always safe to add — it only restricts which keys
    # ssh will OFFER. The fix for fail2ban lockouts depends on it.
    printf '%s\n' "-o" "IdentitiesOnly=yes"

    if [ -n "$name" ]; then
        key=$(get_ssh_key "$name" 2>/dev/null)
        # Only add -i if the file actually exists, otherwise ssh errors out.
        # When no explicit key file exists, IdentitiesOnly still permits the
        # default identity files (~/.ssh/id_rsa, id_ed25519, etc.).
        if [ -n "$key" ] && [ -f "$key" ]; then
            printf '%s\n' "-i" "$key"
        fi
    fi
}

# nwp_ssh: drop-in replacement for `ssh` that resolves the right key from
# nwp.yml and forces IdentitiesOnly. The first argument is the NWP site or
# server name; remaining arguments are passed through to ssh unchanged.
#
#   nwp_ssh "$base_name" -o BatchMode=yes "${ssh_user}@${server_ip}" "command"
#
# This is the recommended way to ssh from NWP scripts. It avoids the
# fail2ban lockout bug where bare `ssh` would offer every key in ~/.ssh/.
nwp_ssh() {
    local name="$1"; shift
    local args=()
    while IFS= read -r line; do
        args+=("$line")
    done < <(_nwp_ssh_args_for "$name")
    ssh "${args[@]}" "$@"
}

# nwp_scp: drop-in replacement for `scp`. Same calling convention as
# nwp_ssh — first arg is the site/server name.
#
#   nwp_scp "$base_name" -o BatchMode=yes "$local_file" "${ssh_user}@${server_ip}:/tmp/"
nwp_scp() {
    local name="$1"; shift
    local args=()
    while IFS= read -r line; do
        args+=("$line")
    done < <(_nwp_ssh_args_for "$name")
    scp "${args[@]}" "$@"
}

# nwp_rsync: drop-in replacement for `rsync` over ssh. The first arg is
# the site/server name; remaining args are passed to rsync. The wrapper
# constructs an `-e "ssh -o IdentitiesOnly=yes [-i key]"` argument so the
# inner ssh also avoids the lockout bug.
#
#   nwp_rsync "$base_name" -av "$src" "${ssh_user}@${server_ip}:$dst"
nwp_rsync() {
    local name="$1"; shift
    local key=""
    local ssh_cmd="ssh -o IdentitiesOnly=yes"

    if [ -n "$name" ]; then
        key=$(get_ssh_key "$name" 2>/dev/null)
        if [ -n "$key" ] && [ -f "$key" ]; then
            ssh_cmd="$ssh_cmd -i $key"
        fi
    fi

    rsync -e "$ssh_cmd" "$@"
}

# Execute a command on a remote server via SSH (legacy helper, kept for
# backwards compatibility). Prefer nwp_ssh() in new code.
# Usage: ssh_exec <site_or_server_name> <command>
ssh_exec() {
    local name="$1"
    shift
    local connection key
    connection=$(get_ssh_connection "$name")
    key=$(get_ssh_key "$name")

    if [ -f "$key" ]; then
        ssh -o IdentitiesOnly=yes -i "$key" "$connection" "$@"
    else
        ssh -o IdentitiesOnly=yes "$connection" "$@"
    fi
}
