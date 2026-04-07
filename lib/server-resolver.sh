#!/bin/bash
# lib/server-resolver.sh
#
# Server resolution helpers (F23 Phase 8).
#
# Reads server identity from servers/<name>/.nwp-server.yml. Falls back
# to the legacy nwp.yml linode.servers.<name>.* block during transition.
#
# Assumes PROJECT_ROOT or NWP_DIR is set by the caller (common.sh does).

: "${NWP_DIR:=${PROJECT_ROOT:-}}"

# Locate yq once.
_server_resolver_yq() {
    if command -v yq &>/dev/null; then
        echo yq
    elif [[ -x "$HOME/.local/bin/yq" ]]; then
        echo "$HOME/.local/bin/yq"
    else
        return 1
    fi
}

# Resolve a server directory by name. Echoes absolute path on success.
# Returns 0 if a .nwp-server.yml exists, 1 otherwise.
resolve_server() {
    local server_name="${1:-}"
    [[ -z "$server_name" ]] && return 1

    local root="${NWP_DIR:-${PROJECT_ROOT:-$HOME/nwp}}"
    local server_dir="$root/servers/$server_name"

    if [[ -f "$server_dir/.nwp-server.yml" ]]; then
        echo "$server_dir"
        return 0
    fi
    return 1
}

# Read a single field from .nwp-server.yml, with fallback to legacy
# nwp.yml linode.servers.<name>.<field>.
#
# Usage: get_server_config <server> <field> [default]
# Field names follow the new schema: ip, ssh_user, ssh_key, domain,
# linode_id, etc.  Mapping for legacy compatibility:
#   ip       <- linode.servers.<name>.ssh_host (host portion)
#   ssh_user <- linode.servers.<name>.ssh_host (user portion)
#   ssh_key  <- linode.servers.<name>.ssh_key
#   domain   <- linode.servers.<name>.domain
#   linode_id<- linode.servers.<name>.linode_id
get_server_config() {
    local server_name="$1"
    local field="$2"
    local default="${3:-}"

    local yq_bin
    yq_bin=$(_server_resolver_yq) || { echo "$default"; return 1; }

    local server_dir
    if server_dir=$(resolve_server "$server_name"); then
        local value
        value=$("$yq_bin" eval ".server.$field // \"\"" "$server_dir/.nwp-server.yml" 2>/dev/null || echo "")
        if [[ -n "$value" && "$value" != "null" ]]; then
            echo "$value"
            return 0
        fi
    fi

    # Legacy fallback
    local global_config="${NWP_DIR:-${PROJECT_ROOT:-$HOME/nwp}}/nwp.yml"
    if [[ -f "$global_config" ]]; then
        local legacy_path
        case "$field" in
            ip)
                # ssh_host is "user@ip" in legacy format; strip the user.
                legacy_path=".linode.servers.\"$server_name\".ssh_host"
                local raw
                raw=$("$yq_bin" eval "$legacy_path // \"\"" "$global_config" 2>/dev/null || echo "")
                if [[ "$raw" == *"@"* ]]; then
                    echo "${raw#*@}"
                else
                    echo "${raw:-$default}"
                fi
                return 0
                ;;
            ssh_user)
                legacy_path=".linode.servers.\"$server_name\".ssh_host"
                local raw
                raw=$("$yq_bin" eval "$legacy_path // \"\"" "$global_config" 2>/dev/null || echo "")
                if [[ "$raw" == *"@"* ]]; then
                    echo "${raw%@*}"
                else
                    echo "$default"
                fi
                return 0
                ;;
            *)
                legacy_path=".linode.servers.\"$server_name\".$field"
                ;;
        esac
        local raw
        raw=$("$yq_bin" eval "$legacy_path // \"\"" "$global_config" 2>/dev/null || echo "")
        if [[ -n "$raw" && "$raw" != "null" ]]; then
            echo "$raw"
            return 0
        fi
    fi

    echo "$default"
    return 1
}

# Convenience wrappers.
get_server_ip()       { get_server_config "$1" ip ""; }
get_server_user()     { get_server_config "$1" ssh_user "gitlab"; }
get_server_domain()   { get_server_config "$1" domain ""; }
get_server_linode_id(){ get_server_config "$1" linode_id ""; }

# Resolve the SSH private key path for a server. Expands ~ to $HOME.
get_server_ssh_key() {
    local server_name="$1"
    local key
    key=$(get_server_config "$server_name" ssh_key "$HOME/.ssh/nwp")
    # Expand leading ~ to $HOME
    echo "${key/#\~/$HOME}"
}

# Build an `ssh -i KEY USER@IP` command string. Caller may append flags.
# IdentitiesOnly=yes prevents fail2ban lockouts: without it, ssh would offer
# every key in ~/.ssh/ on every connection and trip the 3-attempt limit.
get_server_ssh_command() {
    local server_name="$1"
    local ip user key
    ip=$(get_server_ip "$server_name")
    user=$(get_server_user "$server_name")
    key=$(get_server_ssh_key "$server_name")
    [[ -z "$ip" || -z "$user" || -z "$key" ]] && return 1
    echo "ssh -o IdentitiesOnly=yes -i $key $user@$ip"
}

# Discover all servers on disk. Echoes one name per line.
discover_servers() {
    local root="${NWP_DIR:-${PROJECT_ROOT:-$HOME/nwp}}"
    local servers_dir="$root/servers"
    [[ -d "$servers_dir" ]] || return 0
    for dir in "$servers_dir"/*/; do
        [[ -d "$dir" ]] || continue
        local name
        name=$(basename "$dir")
        # Skip placeholders
        case "$name" in
            .gitkeep|tmp) continue ;;
        esac
        if [[ -f "$dir/.nwp-server.yml" ]]; then
            echo "$name"
        fi
    done
}

# List sites configured to deploy to a given server. Reads each
# sites/*/.nwp.yml live.server field.
get_server_sites() {
    local target_server="$1"
    local yq_bin
    yq_bin=$(_server_resolver_yq) || return 1

    local root="${NWP_DIR:-${PROJECT_ROOT:-$HOME/nwp}}"
    for cfg in "$root"/sites/*/.nwp.yml; do
        [[ -f "$cfg" ]] || continue
        local server
        server=$("$yq_bin" eval '.live.server // ""' "$cfg" 2>/dev/null)
        if [[ "$server" == "$target_server" ]]; then
            basename "$(dirname "$cfg")"
        fi
    done
}

# Find which server a site is configured for, by reading its .nwp.yml.
get_site_server() {
    local site="$1"
    local site_dir
    site_dir=$(resolve_project "$site" 2>/dev/null) || return 1
    local cfg="$site_dir/.nwp.yml"
    [[ -f "$cfg" ]] || return 1
    local yq_bin
    yq_bin=$(_server_resolver_yq) || return 1
    "$yq_bin" eval '.live.server // ""' "$cfg" 2>/dev/null
}
