#!/usr/bin/env bash
# scripts/commands/server.sh
#
# `pl server` subcommand family: lists and inspects server records under
# servers/<name>/.nwp-server.yml (F23 Phase 8).
#
# Usage:
#   pl server list                    List all servers
#   pl server show <name>             Print the .nwp-server.yml for a server
#   pl server status [name]           Show status (configured / SSH reachable)
#   pl server status --all            Status for every server
#   pl server sites <name>            List sites that target this server
#   pl server schema                  Print the current expected server schema
#   pl server migrate <name>          Migrate one server config
#   pl server migrate --all           Migrate every server config

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NWP_DIR="$PROJECT_ROOT"

# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/migrate-schema.sh"

if [[ -z "${NWP_VERSION:-}" ]]; then
    NWP_VERSION=$(grep -E '^VERSION=' "$PROJECT_ROOT/pl" | head -1 | sed 's/.*="\(.*\)"/\1/')
fi
export NWP_VERSION NWP_DIR

YQ="${YQ_BIN:-yq}"
if ! command -v "$YQ" &>/dev/null; then
    if [[ -x "$HOME/.local/bin/yq" ]]; then
        YQ="$HOME/.local/bin/yq"
    else
        echo "ERROR: yq is required but was not found." >&2
        exit 1
    fi
fi

################################################################################
# Subcommand: list
################################################################################
cmd_list() {
    local servers
    servers=$(discover_servers)
    if [[ -z "$servers" ]]; then
        echo "No servers configured under servers/."
        return 0
    fi

    printf "%-15s %-10s %-10s %-18s %s\n" "SERVER" "SCHEMA" "STATUS" "IP" "CONFIG"
    printf "%-15s %-10s %-10s %-18s %s\n" "------" "------" "------" "--" "------"
    while IFS= read -r name; do
        local cfg="$PROJECT_ROOT/servers/$name/.nwp-server.yml"
        local schema status ip
        schema=$("$YQ" eval '.schema_version // "?"' "$cfg" 2>/dev/null)
        ip=$("$YQ" eval '.server.ip // "-"' "$cfg" 2>/dev/null)
        if [[ "$schema" == "$CURRENT_SERVER_SCHEMA" ]]; then
            status="current"
        else
            status="stale"
        fi
        printf "%-15s %-10s %-10s %-18s %s\n" "$name" "$schema" "$status" "$ip" "servers/$name/.nwp-server.yml"
    done <<< "$servers"
}

################################################################################
# Subcommand: show <name>
################################################################################
cmd_show() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        echo "Usage: pl server show <name>" >&2
        return 1
    fi
    local cfg="$PROJECT_ROOT/servers/$name/.nwp-server.yml"
    if [[ ! -f "$cfg" ]]; then
        echo "ERROR: No config at $cfg" >&2
        return 1
    fi
    cat "$cfg"
}

################################################################################
# Subcommand: status [name|--all]
################################################################################
_status_one() {
    local name="$1"
    local cfg="$PROJECT_ROOT/servers/$name/.nwp-server.yml"
    if [[ ! -f "$cfg" ]]; then
        printf "%-15s %s\n" "$name" "MISSING (.nwp-server.yml not found)"
        return 1
    fi

    local ip user key
    ip=$(get_server_ip "$name")
    user=$(get_server_user "$name")
    key=$(get_server_ssh_key "$name")

    printf "%-15s ip=%s user=%s key=%s" "$name" "${ip:-?}" "${user:-?}" "${key:-?}"

    if [[ -n "$ip" && -n "$user" ]]; then
        if [[ -f "$key" ]]; then
            if ssh -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
                "${user}@${ip}" "true" 2>/dev/null; then
                printf "  SSH=ok\n"
            else
                printf "  SSH=unreachable\n"
            fi
        else
            printf "  SSH=key-missing\n"
        fi
    else
        printf "  SSH=incomplete-config\n"
    fi
}

cmd_status() {
    local arg="${1:-}"
    if [[ "$arg" == "--all" || -z "$arg" ]]; then
        local servers
        servers=$(discover_servers)
        if [[ -z "$servers" ]]; then
            echo "No servers configured."
            return 0
        fi
        while IFS= read -r name; do
            _status_one "$name"
        done <<< "$servers"
    else
        _status_one "$arg"
    fi
}

################################################################################
# Subcommand: sites <name>
################################################################################
cmd_sites() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        echo "Usage: pl server sites <name>" >&2
        return 1
    fi
    local sites
    sites=$(get_server_sites "$name")
    if [[ -z "$sites" ]]; then
        echo "No sites configured for server: $name"
        return 0
    fi
    echo "Sites on $name:"
    while IFS= read -r site; do
        local domain
        domain=$(get_site_config_value "$site" '.live.domain' '')
        printf "  %-12s %s\n" "$site" "${domain:-(no domain)}"
    done <<< "$sites"
}

################################################################################
# Subcommand: schema
################################################################################
cmd_schema() {
    echo "Server schema version: $CURRENT_SERVER_SCHEMA"
    echo "Migrations dir: lib/migrations/server/"
}

################################################################################
# Subcommand: migrate
################################################################################
cmd_migrate() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        echo "Usage: pl server migrate <name|--all>" >&2
        return 1
    fi
    if [[ "$target" == "--all" ]]; then
        local any=0
        local servers
        servers=$(discover_servers)
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            migrate_server "$name" || any=1
        done <<< "$servers"
        return $any
    else
        migrate_server "$target"
    fi
}

################################################################################
# Dispatcher
################################################################################
sub="${1:-}"
shift || true

case "$sub" in
    list)    cmd_list "$@" ;;
    show)    cmd_show "$@" ;;
    status)  cmd_status "$@" ;;
    sites)   cmd_sites "$@" ;;
    schema)  cmd_schema "$@" ;;
    migrate) cmd_migrate "$@" ;;
    ""|help|--help|-h)
        cat <<EOF
Usage: pl server <subcommand> [args]

Subcommands:
  list                  List all servers under servers/
  show <name>           Print .nwp-server.yml for a server
  status [name|--all]   Check SSH reachability for one or all servers
  sites <name>          List sites configured to deploy to this server
  schema                Print current server schema version
  migrate <name|--all>  Run schema migrations on a server config
EOF
        ;;
    *)
        echo "Unknown subcommand: $sub" >&2
        echo "Run 'pl server help' for usage." >&2
        exit 1
        ;;
esac
