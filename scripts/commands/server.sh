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
#   pl server health [name|--all]     Load / memory / disk headroom (the OOM guard)
#   pl server forge status <name>     Forge package version, apt key expiry, pending upgrades
#
# `status` answers "can I reach it". `health` answers "should I start work on
# it" — the question nobody could answer with a `pl` verb on 2026-07-25, when a
# heavy op OOM-killed the 3.8 GB forge box (GitLab + 5 live sites) for 5-8 min.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NWP_DIR="$PROJECT_ROOT"

# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/migrate-schema.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/host-capture.sh"

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
# Subcommand: health [name|--all]
#
# The OOM guard. `pl server status` says whether sshd answers; this says
# whether the box can survive what you were about to start.
#
# Exit codes:  0 healthy · 1 no headroom · 3 UNKNOWN (unreachable/unparseable)
# UNKNOWN is deliberately NOT 0. A box you cannot measure is not a box you
# should start a heavy op on.
################################################################################
_resolve_probe_prefix() {
    local name="$1"
    if [[ -n "${PROBE_CMD:-}" ]]; then printf '%s\n' "$PROBE_CMD"; return 0; fi
    host_resolve_dest "$name"
}

cmd_health() {
    local raw_out=0 target="" arg
    PROBE_CMD=""
    for arg in "$@"; do
        case "$arg" in
            --raw)         raw_out=1 ;;
            --probe-cmd=*) PROBE_CMD="${arg#--probe-cmd=}" ;;
            --all)         target="--all" ;;
            -*)            echo "Unknown option: $arg" >&2; return 2 ;;
            *)             target="$arg" ;;
        esac
    done

    if [[ "$target" == "--all" ]]; then
        local servers worst=0
        servers=$(discover_servers)
        [[ -z "$servers" ]] && { echo "No servers configured."; return 0; }
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            echo "$name:"
            cmd_health "$name" || { local rc=$?; [[ $rc -gt $worst ]] && worst=$rc; }
        done <<< "$servers"
        return $worst
    fi

    local prefix
    prefix=$(_resolve_probe_prefix "$target") || {
        echo "UNKNOWN: cannot resolve a destination for '${target:-<none>}'" >&2; return 3; }

    local raw
    if ! raw=$(host_health_probe "$prefix"); then
        printf '%s\n' "$raw"
        return 3
    fi
    [[ $raw_out -eq 1 ]] && printf '%s\n' "$raw"
    host_health_eval "$raw"
}

################################################################################
# Subcommand: forge status <name>
#
# The forge holds the entire trust root and NOT ONE of pl todo's checks covered
# it. This reads the PACKAGE MANAGER only — dpkg, apt-mark, gpg, apt-get -s.
# It must never invoke gitlab-rails or gitlab-rake: that is what OOM-killed the
# 3.8 GB box on 2026-07-25.
################################################################################
cmd_forge() {
    local sub="${1:-status}"; shift || true
    [[ "$sub" == "status" ]] || { echo "Usage: pl server forge status <name>" >&2; return 2; }

    local raw_out=0 target="" arg
    PROBE_CMD=""
    for arg in "$@"; do
        case "$arg" in
            --raw)         raw_out=1 ;;
            --probe-cmd=*) PROBE_CMD="${arg#--probe-cmd=}" ;;
            -*)            echo "Unknown option: $arg" >&2; return 2 ;;
            *)             target="$arg" ;;
        esac
    done

    local prefix
    prefix=$(_resolve_probe_prefix "$target") || {
        echo "UNKNOWN: cannot resolve a destination for '${target:-<none>}'" >&2; return 3; }

    local raw
    if ! raw=$(host_forge_probe "$prefix"); then
        printf '%s\n' "$raw"
        return 3
    fi
    [[ $raw_out -eq 1 ]] && printf '%s\n' "$raw"

    local pkg="" version="" held="" key_expiry="" upgradable="" line
    while IFS= read -r line; do
        case "$line" in
            pkg=*)        pkg="${line#pkg=}" ;;
            version=*)    version="${line#version=}" ;;
            held=*)       held="${line#held=}" ;;
            key_expiry=*) key_expiry="${line#key_expiry=}" ;;
            upgradable=*) upgradable="${line#upgradable=}" ;;
        esac
    done <<< "$raw"

    printf '  package    %s\n' "${pkg:-unknown}"
    printf '  version    %s\n' "${version:-unknown}"
    printf '  held       %s\n' "${held:-unknown}"
    printf '  apt key    expiry=%s\n' "${key_expiry:-unknown}"
    printf '  upgradable %s package(s)\n' "${upgradable:-unknown}"

    # An expired repo signing key silently stops security updates — it happened
    # here on 2026-07-11 and nothing noticed.
    if [[ -n "$key_expiry" && "$key_expiry" =~ ^[0-9]+$ ]]; then
        local now; now=$(date +%s)
        if [[ "$key_expiry" -lt "$now" ]]; then
            echo "  WARNING: the apt signing key has EXPIRED — updates are not arriving" >&2
            return 1
        fi
    fi
    return 0
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
    health)  cmd_health "$@" ;;
    forge)   cmd_forge "$@" ;;
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
  health [name|--all]   Load / memory / disk HEADROOM — the preflight every
                        heavy op must pass. Exit 1 = no headroom,
                        3 = UNKNOWN (never treated as healthy).
  forge status <name>   Forge package version, apt signing-key expiry and
                        pending upgrades — package manager only, never the
                        Rails console (that OOM-killed the box on 2026-07-25).
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
