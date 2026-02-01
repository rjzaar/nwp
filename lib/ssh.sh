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
get_ssh_options() {
    local host_key_mode
    host_key_mode=$(get_ssh_host_key_checking)

    # Return options as newline-separated list
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
    echo "StrictHostKeyChecking=$host_key_mode"
    echo "-o"
    echo "ConnectTimeout=10"
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

    if [[ ! -f "$config_file" ]]; then
        echo "root"
        return
    fi

    # 1. Check sites.<name>.live.ssh_user
    user=$(awk -v site="$name" '
        /^sites:/{in_sites=1; next}
        in_sites && /^  [a-zA-Z]/{
            gsub(/:$/, "", $1)
            current_site=$1
        }
        in_sites && current_site==site && /live:/{in_live=1; next}
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
            gsub(/:$/, "", $1)
            current_srv=$1
        }
        in_servers && current_srv==srv && /ssh_user:/{print $2; exit}
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
            gsub(/:$/, "", $1)
            current_srv=$1
        }
        in_servers && current_srv==srv && /ssh_host:/{print $2; exit}
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
            gsub(/:$/, "", $1)
            current_site=$1
        }
        in_sites && current_site==site && /recipe:/{print $2; exit}
    ' "$config_file" 2>/dev/null)

    if [[ -n "$recipe" ]]; then
        user=$(awk -v r="$recipe" '
            /^recipes:/{in_recipes=1; next}
            in_recipes && /^  [a-zA-Z]/{
                gsub(/:$/, "", $1)
                current_recipe=$1
            }
            in_recipes && current_recipe==r && /ssh_user:/{print $2; exit}
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
            gsub(/:$/, "", $1)
            current_srv=$1
        }
        in_servers && current_srv==srv && /ssh_host:/{
            val=$2
            # Strip user@ prefix if present
            sub(/.*@/, "", val)
            print val
            exit
        }
    ' "$config_file" 2>/dev/null)

    if [[ -z "$host" ]]; then
        # Try sites.<name>.live.server or ssh_host
        host=$(awk -v site="$name" '
            /^sites:/{in_sites=1; next}
            in_sites && /^  [a-zA-Z]/{
                gsub(/:$/, "", $1)
                current_site=$1
            }
            in_sites && current_site==site && /live:/{in_live=1; next}
            in_live && /ssh_host:/{
                val=$2; sub(/.*@/, "", val); print val; exit
            }
            in_live && /server:/{print $2; exit}
            in_live && /^    [a-zA-Z]/{in_live=0}
        ' "$config_file" 2>/dev/null)
    fi

    echo "${user}@${host}"
}

# Execute a command on a remote server via SSH
# Usage: ssh_exec <site_or_server_name> <command>
ssh_exec() {
    local name="$1"
    shift
    local connection
    connection=$(get_ssh_connection "$name")

    ssh "$connection" "$@"
}
