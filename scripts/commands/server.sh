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
# Respect a caller-supplied NWP_DIR. lib/project-resolver.sh and
# lib/server-resolver.sh already read declarations from ${NWP_DIR:-PROJECT_ROOT}
# (see discover_sites / get_server_sites), so forcing it here made this one
# command the odd one out and left `pl server roots` unable to be pointed at a
# fixture inventory. Unset in production, this is exactly the old behaviour.
NWP_DIR="${NWP_DIR:-$PROJECT_ROOT}"

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

    # D33/ops#80: record that a forge check ran, so `pl todo`'s cadence check
    # (check_forge_freshness) can nag when nobody has looked in a while — WITHOUT
    # doing this remote probe on every `pl todo` (it must stay cheap and never
    # touch the OOM-prone box unprompted). One line per server: ISO date +
    # version + upgradable count + key expiry epoch, so the check reads truth
    # without re-probing. Best-effort: a failure to write never fails the verb.
    if [ -n "${target:-}" ]; then
        local _fdir="${PROJECT_ROOT:-$HOME/nwp}/private/forge"
        mkdir -p "$_fdir" 2>/dev/null && \
            printf '%s version=%s upgradable=%s key_expiry=%s\n' \
                "$(date -u +%FT%TZ)" "${version:-unknown}" "${upgradable:-unknown}" "${key_expiry:-unknown}" \
                > "${_fdir}/${target}.last-check" 2>/dev/null || true
    fi

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
# Subcommand: roots <name>            (nwp/ops#149)
#
# Enumerates what the box ACTUALLY SERVES and reconciles it against what NWP
# DECLARES. See lib/served-roots.sh for the full rationale; the short version
# is that the `rgs` live site served stored XSS for eleven days while being both
# reachable and invisible to every `pl` gate, because the corpus of every check
# was a hand-maintained list.
#
# This verb is LIGHT and SERIAL by design — one ssh round trip, a few greps
# over config files, no gitlab-rails/gitlab-rake, no nginx -t. It is safe on
# the 3.8 GB forge box. `pl server health <name>` remains the required
# preflight for anything heavy; this is not that.
#
# Exit codes:
#   0  reconciled — every served root is declared and every declaration gated
#      (WARN lines may still be present: retirement is legitimate)
#   1  UNDECLARED-ROOT and/or UNGATED-DECLARATION found
#   2  usage error
#   3  CANNOT-VERIFY — blindness. Transport dead, config unreadable, no nginx
#      master, or zero roots enumerated. NEVER conflated with 0.
################################################################################
# pl server conf-drift <server> — flag nginx vhost files on the box that are
# not in the tracked server repo (strays, armed by the next reload), and tracked
# ones absent on the box (undeployed). ops#157/#92/#106, register D19.
cmd_conf_drift() {
    local target="" arg
    PROBE_CMD=""
    for arg in "$@"; do
        case "$arg" in
            --probe-cmd=*) PROBE_CMD="${arg#--probe-cmd=}" ;;
            -*)            echo "Unknown option: $arg" >&2; return 2 ;;
            *)             target="$arg" ;;
        esac
    done
    if [[ -z "$target" ]]; then
        echo "Usage: pl server conf-drift <name>" >&2
        return 2
    fi
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/lib/host-capture.sh"
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/lib/nginx-conf-parity.sh"

    local prefix
    prefix=$(_resolve_probe_prefix "$target") || {
        echo "CANNOT-VERIFY: cannot resolve a destination for '${target}'" >&2; return 3; }

    echo "nginx conf.d parity — ${target}"
    nginx_parity_check "$target" "$PROJECT_ROOT" "$prefix"
}

cmd_roots() {
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
    if [[ -z "$target" ]]; then
        echo "Usage: pl server roots <name> [--raw]" >&2
        return 2
    fi

    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/lib/served-roots.sh"

    local prefix
    prefix=$(_resolve_probe_prefix "$target") || {
        echo "CANNOT-VERIFY: cannot resolve a destination for '${target}'" >&2; return 3; }

    local capture
    if ! capture=$(served_roots_probe "$prefix"); then
        printf '%s\n' "$capture"
        return 3
    fi
    [[ $raw_out -eq 1 ]] && printf '%s\n' "$capture"

    served_roots_parse "$capture"

    ############################################################################
    # BLINDNESS GATE — runs BEFORE any reconciliation. A partial corpus is not
    # graded at all; it is reported as unverifiable. This ordering is the whole
    # point of the verb: the incident happened because an incomplete corpus was
    # allowed to produce a confident answer.
    ############################################################################
    if [[ "$SR_MASTER" != "yes" ]]; then
        echo "CANNOT-VERIFY: no running nginx master on '$target' — cannot know what is served"
        return 3
    fi
    if [[ ${#SR_UNREADABLE[@]} -gt 0 ]]; then
        echo "CANNOT-VERIFY: the config include graph is not fully readable, so the"
        echo "               enumeration is INCOMPLETE and must not be graded:"
        local u
        for u in "${SR_UNREADABLE[@]}"; do
            printf '                 unreadable: %s\n' "$u"
        done
        return 3
    fi
    if [[ ${#SR_SERVER_ROOTS[@]} -eq 0 ]]; then
        echo "CANNOT-VERIFY: zero served roots enumerated from ${SR_CONFIG:-<no config>}"
        echo "               An empty enumeration is NOT 'nothing undeclared'."
        return 3
    fi

    # Distinct served roots, and the names that reach each.
    local -A root_names=()
    local entry path names
    for entry in "${SR_SERVER_ROOTS[@]}"; do
        path="${entry%%|*}"; names="${entry#*|}"
        path="${path%/}"
        root_names["$path"]="${root_names[$path]:+${root_names[$path]} }${names}"
    done
    local -A loc_names=()
    for entry in "${SR_LOC_ROOTS[@]:-}"; do
        [[ -z "$entry" ]] && continue
        path="${entry%%|*}"; names="${entry#*|}"
        path="${path%/}"
        loc_names["$path"]="${loc_names[$path]:+${loc_names[$path]} }${names}"
    done

    local all_names=""
    for path in "${!root_names[@]}"; do all_names="$all_names ${root_names[$path]}"; done
    for path in "${!loc_names[@]}"; do all_names="$all_names ${loc_names[$path]}"; done

    served_roots_declarations "$target" "$NWP_DIR" "$all_names"
    # Infrastructure roots (ACME webroots, proxy vhosts) are declared in the
    # SERVER inventory rather than as sites — see lib/served-roots.sh. Read
    # separately so a site declaration can never be mistaken for one, or vice
    # versa.
    served_roots_infra "$target" "$NWP_DIR"

    printf 'served roots on %s: %d (from %d config file(s), corpus=%s)\n' \
        "$target" "${#root_names[@]}" "$SR_FILES" "${SR_CONFIG:-?}"
    printf 'declarations attributed to %s: %d (+%d infrastructure)\n\n' \
        "$target" "${#SR_DECL[@]}" "${#SR_INFRA[@]}"

    ############################################################################
    # (1) UNDECLARED-ROOT — the ops#149 class. RED.
    ############################################################################
    local fails=0 warns=0 d dpath dname dgated dsrc covered
    local -a undeclared=()
    local infra_hit isvc idom
    for path in $(printf '%s\n' "${!root_names[@]}" | sort); do
        covered=0
        for d in "${SR_DECL[@]:-}"; do
            [[ -z "$d" ]] && continue
            IFS='|' read -r dname dpath _ dgated dsrc <<< "$d"
            if served_roots_covered_by "$path" "$dpath"; then covered=1; break; fi
        done
        # An INFRASTRUCTURE declaration also covers a root — but it is reported
        # on its own line rather than silently absorbed, because "served by a
        # service that owns no site" is a distinct and interesting answer, and
        # the operator should be able to see at a glance that the mesh
        # controller's ACME stub is not an undeclared Drupal.
        if [[ $covered -eq 0 ]] && infra_hit="$(served_roots_infra_match "$path")"; then
            isvc="${infra_hit%%|*}"; idom="${infra_hit#*|}"
            printf '  INFRA-ROOT            %-28s service: %-12s %s\n' \
                "$path" "$isvc" "${idom:-—}"
            printf '                        declared in servers/%s/.nwp-server.yml (not a site)\n' "$target"
            covered=1
        fi
        if [[ $covered -eq 0 ]]; then
            undeclared+=("$path")
            printf '  UNDECLARED-ROOT       %-28s served as: %s\n' "$path" "${root_names[$path]:-?}"
            fails=$((fails + 1))
        fi
    done

    ############################################################################
    # (2) UNGATED-DECLARATION — the rgs shape. RED.
    #     Declared in the inventory, therefore believed covered; but with no
    #     sites/<name>/.nwp.yml it is refused by name by every `pl` gate.
    ############################################################################
    for d in "${SR_DECL[@]:-}"; do
        [[ -z "$d" ]] && continue
        IFS='|' read -r dname dpath _ dgated dsrc <<< "$d"
        if [[ "$dgated" != "yes" ]]; then
            printf '  UNGATED-DECLARATION   %-28s declared in %s; MISSING sites/%s/.nwp.yml\n' \
                "$dname" "$dsrc" "$dname"
            printf '                        → every `pl` gate refuses this site by name\n'
            fails=$((fails + 1))
        fi
    done

    ############################################################################
    # (3) UNREACHABLE-DECLARATION — WARN, not red.
    #     Retiring a site is legitimate and routine (/var/www/_retired_ss_*,
    #     ss.archived-*). Reddening it would make this gate noisy, and a noisy
    #     gate is an ignored gate — which is how we got here. It is still worth
    #     a line: a declaration nothing serves is a declaration that will
    #     silently no-op the next time someone deploys through it.
    ############################################################################
    for d in "${SR_DECL[@]:-}"; do
        [[ -z "$d" ]] && continue
        IFS='|' read -r dname dpath _ dgated dsrc <<< "$d"
        [[ -z "$dpath" ]] && continue
        covered=0
        for path in "${!root_names[@]}"; do
            if served_roots_covered_by "$path" "$dpath"; then covered=1; break; fi
        done
        if [[ $covered -eq 0 ]]; then
            printf '  WARN UNREACHABLE-DECLARATION  %-22s %s — no vhost serves it\n' "$dname" "$dpath"
            warns=$((warns + 1))
        fi
    done

    ############################################################################
    # (4) STALE-TREE — WARN. An unserved tree still on disk is unreachable
    #     today, but it is still code: /var/www/ss.archived-20260522 is a
    #     second copy of the very mod_depthcontent that caused this issue, with
    #     no vhost in front of it. Restoring a vhost, or any local include,
    #     makes it live again. Worth a distinct line, not a failure.
    ############################################################################
    local dir base
    for dir in $(printf '%s\n' "${SR_DIRS[@]:-}" | sort -u); do
        [[ -z "$dir" ]] && continue
        base="$(basename "$dir")"
        # Moodle data dirs live beside their docroot BY DESIGN and must never
        # be served; the same convention discover_sites() already uses.
        case "$base" in *_moodledata*|html) continue ;; esac
        covered=0
        for path in "${!root_names[@]}"; do
            if served_roots_covered_by "$path" "$dir" || served_roots_covered_by "$dir" "$path"; then
                covered=1; break
            fi
        done
        for path in "${!loc_names[@]}"; do
            [[ $covered -eq 1 ]] && break
            served_roots_covered_by "$path" "$dir" && covered=1
        done
        if [[ $covered -eq 0 ]]; then
            printf '  WARN STALE-TREE       %-28s on disk, served by nothing\n' "$dir"
            warns=$((warns + 1))
        fi
    done

    ############################################################################
    # (5) LOCATION-ROOT — informational. An ACME stub is not a site docroot.
    ############################################################################
    if [[ ${#loc_names[@]} -gt 0 ]]; then
        for path in $(printf '%s\n' "${!loc_names[@]}" | sort); do
            [[ -z "$path" ]] && continue
            printf '  LOCATION-ROOT         %-28s location-scoped (ACME stub or similar)\n' "$path"
        done
    fi

    echo
    if [[ $fails -gt 0 ]]; then
        printf 'RESULT: %d finding(s) requiring action, %d warning(s) — FAIL\n' "$fails" "$warns"
        return 1
    fi
    printf 'RESULT: every served root is declared and every declaration is gated (%d warning(s))\n' "$warns"
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
# Subcommand: add — onboard a NEW server by command (create servers/<name>/
# .nwp-server.yml from flags) instead of hand-authoring it. Future-proofs the
# estate for N servers (multi-server audit 2026-07-31).
################################################################################
cmd_add() {
    local name="" ip="" ssh_user="gitlab" ssh_key='~/.ssh/nwp' domain="nwpcode.org"
    local provider="linode" region="" linode_id="" linode_label="" force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ip=*)           ip="${1#*=}" ;;
            --ssh-user=*)     ssh_user="${1#*=}" ;;
            --ssh-key=*)      ssh_key="${1#*=}" ;;
            --domain=*)       domain="${1#*=}" ;;
            --provider=*)     provider="${1#*=}" ;;
            --region=*)       region="${1#*=}" ;;
            --linode-id=*)    linode_id="${1#*=}" ;;
            --linode-label=*) linode_label="${1#*=}" ;;
            --force)          force=true ;;
            -h|--help)        echo "Usage: pl server add <name> --ip=<ipv4> [--ssh-user=gitlab] [--ssh-key=~/.ssh/nwp] [--domain=nwpcode.org] [--provider=linode] [--region=] [--linode-id=] [--linode-label=] [--force]"; return 0 ;;
            -*)               echo "Unknown option: $1" >&2; return 1 ;;
            *)                if [[ -z "$name" ]]; then name="$1"; else echo "Unexpected argument: $1" >&2; return 1; fi ;;
        esac
        shift
    done
    [[ -n "$name" ]] || { echo "Usage: pl server add <name> --ip=<ipv4> [...]" >&2; return 1; }
    [[ "$name" =~ ^[a-z][a-z0-9_-]*$ ]] || { echo "Invalid server name '$name' (lowercase letter, then [a-z0-9_-])." >&2; return 1; }
    [[ -n "$ip" ]] || { echo "--ip=<ipv4> is required." >&2; return 1; }
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "Invalid --ip '$ip' (expected IPv4)." >&2; return 1; }
    # Servers base is overridable (NWP_SERVERS_DIR) so tests stay isolated while
    # lib/ still loads from the real repo root.
    local base="${NWP_SERVERS_DIR:-$PROJECT_ROOT/servers}" dir cfg
    dir="$base/$name"
    cfg="$dir/.nwp-server.yml"
    if [[ -e "$cfg" && "$force" != true ]]; then
        echo "Refusing to overwrite $cfg (use --force)." >&2
        return 1
    fi
    mkdir -p "$dir"
    {
        echo "---"
        echo "# $name — server identity (created by \`pl server add\`)."
        echo "# Read by NWP via lib/server-resolver.sh; schema-versioned (lib/migrate-schema.sh)."
        echo "schema_version: $CURRENT_SERVER_SCHEMA"
        echo "nwp_version_created: \"$NWP_VERSION\""
        echo "nwp_version_updated: \"$NWP_VERSION\""
        echo ""
        echo "server:"
        echo "  name: $name"
        echo "  ip: $ip"
        echo "  domain: $domain"
        echo "  ssh_user: $ssh_user"
        echo "  ssh_key: $ssh_key"
        [[ -n "$linode_id" ]]    && echo "  linode_id: $linode_id"
        [[ -n "$linode_label" ]] && echo "  linode_label: $linode_label"
        echo "  provider: $provider"
        [[ -n "$region" ]]       && echo "  region: $region"
        echo ""
        echo "services:"
        echo "  nginx: true"
        echo "  postfix: true"
        echo "  certbot: true"
        echo "  fail2ban: true"
        echo "  ufw: true"
        echo ""
        echo "# Authoritative site mapping is derived from sites/*/.nwp.yml (.live.server == $name)."
        echo "hosted_sites: []"
    } > "$cfg"
    echo "Created $cfg"
    echo "Next: point sites at it — set '.live.server: $name' in each sites/<name>/.nwp.yml"
    echo "Verify: pl server show $name  &&  pl server status $name"
}

################################################################################
# Dispatcher
################################################################################
sub="${1:-}"
shift || true

case "$sub" in
    list)    cmd_list "$@" ;;
    add)     cmd_add "$@" ;;
    show)    cmd_show "$@" ;;
    status)  cmd_status "$@" ;;
    health)  cmd_health "$@" ;;
    forge)   cmd_forge "$@" ;;
    roots)   cmd_roots "$@" ;;
    conf-drift) cmd_conf_drift "$@" ;;
    sites)   cmd_sites "$@" ;;
    schema)  cmd_schema "$@" ;;
    migrate) cmd_migrate "$@" ;;
    ""|help|--help|-h)
        cat <<EOF
Usage: pl server <subcommand> [args]

Subcommands:
  list                  List all servers under servers/
  add <name> --ip=IPV4  Onboard a new server: write servers/<name>/.nwp-server.yml
                        [--ssh-user= --ssh-key= --domain= --provider= --region=
                        --linode-id= --linode-label= --force]
  show <name>           Print .nwp-server.yml for a server
  status [name|--all]   Check SSH reachability for one or all servers
  health [name|--all]   Load / memory / disk HEADROOM — the preflight every
                        heavy op must pass. Exit 1 = no headroom,
                        3 = UNKNOWN (never treated as healthy).
  forge status <name>   Forge package version, apt signing-key expiry and
                        pending upgrades — package manager only, never the
                        Rails console (that OOM-killed the box on 2026-07-25).
  roots <name>          Enumerate what nginx ACTUALLY SERVES and reconcile it
                        against what NWP declares. Exit 1 = an undeclared root
                        or a declaration no gate can see (the ops#149 shape),
                        3 = CANNOT-VERIFY (never treated as clean).
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
