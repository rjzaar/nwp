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

# lib/common.sh's own header says it requires lib/ui.sh to be sourced first
# (print_error and friends live there). This command got away without it until
# a subcommand actually used the print_* helpers.
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/ui.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/impact.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/migrate-schema.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/host-capture.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/server-sync.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/server-prune.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/server-handoff.sh"

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
        local cfg="${NWP_DIR:-$PROJECT_ROOT}/servers/$name/.nwp-server.yml"
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
    local cfg="${NWP_DIR:-$PROJECT_ROOT}/servers/$name/.nwp-server.yml"
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
    local cfg="${NWP_DIR:-$PROJECT_ROOT}/servers/$name/.nwp-server.yml"
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
            # -n is load-bearing: without it ssh slurps the caller's stdin, and
            # the `--all` loop (which feeds server names on stdin via <<<) lost
            # every server after the first — a truncated roster that read as a
            # complete, healthy fleet.
            if ssh -n -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
                "${user}@${ip}" "true" 2>/dev/null; then
                printf "  SSH=ok\n"
            else
                printf "  SSH=unreachable\n"
                return 1
            fi
        else
            printf "  SSH=key-missing\n"
            return 1
        fi
    else
        printf "  SSH=incomplete-config\n"
        return 1
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
        # One unreachable/misconfigured server must never hide the rest. Under
        # `set -e` a bare `_status_one` here aborted the loop mid-roster, so the
        # output looked like a complete fleet when it was a truncated one.
        # Report every server, then fail if any did.
        local worst=0
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            _status_one "$name" || worst=1
        done <<< "$servers"
        return $worst
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

        # THE CORPUS COMES FIRST. --all can only be as complete as
        # discover_servers(), which lists a host only if it has a
        # .nwp-server.yml. On 2026-08-11 servers/met/ held real captured host
        # state with no identity file, so this verb returned 0 over two hosts
        # while the CI/backup/demo-cron machine went unmeasured AND unmentioned.
        # An unmeasured host is not a healthy host: report it and return 3
        # UNKNOWN, the same code an unreachable host gets, because it is the
        # same fact — "I could not look".
        local unreg=""
        if unreg=$(host_check_servers_registered "${NWP_DIR:-$PROJECT_ROOT}" 2>&1); then
            unreg=""
        else
            printf '%s\n' "$unreg"
            worst=3
        fi

        if [[ -z "$servers" ]]; then
            [[ $worst -eq 0 ]] && { echo "No servers configured."; return 0; }
            return $worst
        fi
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

################################################################################
# Subcommand: vhost <server> <site> [--status|--restore] [--apply]  (ops#359)
#
# `pl server roots` DETECTS a site whose declared root no vhost serves
# (UNREACHABLE-DECLARATION) and cannot act on it. On 2026-08-13 that gap was
# closed by hand over ssh — a deliberate, recorded exception to the pl-first
# standing order. This verb is the repayment. See lib/server-vhost.sh.
################################################################################
cmd_vhost() {
    local target="" site="" mode="status" apply=0 arg
    PROBE_CMD=""
    for arg in "$@"; do
        case "$arg" in
            --status)      mode="status" ;;
            --restore)     mode="restore" ;;
            --apply)       apply=1 ;;
            --probe-cmd=*) PROBE_CMD="${arg#--probe-cmd=}" ;;
            -h|--help)     _vhost_usage; return 0 ;;
            -*)            echo "Unknown option: $arg" >&2; return 2 ;;
            *)             if [[ -z "$target" ]]; then target="$arg"
                           elif [[ -z "$site" ]]; then site="$arg"
                           else echo "Unexpected argument: $arg" >&2; return 2; fi ;;
        esac
    done
    if [[ -z "$target" || -z "$site" ]]; then _vhost_usage >&2; return 2; fi

    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/lib/served-roots.sh"
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/lib/server-vhost.sh"

    local prefix
    prefix=$(_resolve_probe_prefix "$target") || {
        echo "CANNOT VERIFY: cannot resolve a destination for '${target}'" >&2; return 3; }

    local capture
    capture=$(vhost_probe "$prefix") || return 3

    local dir; dir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$dir'" RETURN
    local incomplete=0
    printf '%s\n' "$capture" | vhost_split_stream "$dir" 2>/dev/null || incomplete=1

    # BLINDNESS GATE, before any verdict. A config directory we could not fully
    # read cannot produce "no vhost serves it" — that is the sentence this verb
    # exists to make actionable, and it must never be said blind.
    if [[ $incomplete -eq 1 ]]; then
        echo "CANNOT VERIFY: part of ${VHOST_CONF_DIR} on '${target}' was unreadable — refusing to grade"
        return 3
    fi
    if [[ -z "$(vhost_all_files "$dir")" ]]; then
        echo "CANNOT VERIFY: no nginx config files enumerated on '${target}' — this is NOT 'no vhosts'"
        return 3
    fi

    # The site's DECLARED root, from the same inventory `pl server roots` reads.
    local decl_path="" decl_domain="" entry n p d
    served_roots_declarations "$target" "$NWP_DIR" "" || true
    for entry in "${SR_DECL[@]:-}"; do
        IFS='|' read -r n p d _ _ <<<"$entry"
        if [[ "$n" == "$site" ]]; then decl_path="$p"; decl_domain="$d"; fi
    done
    if [[ -z "$decl_path" ]]; then
        echo "CANNOT VERIFY: '${site}' declares no live root attributed to '${target}'."
        echo "               Nothing to compare a vhost against. Check: pl server roots ${target}"
        return 3
    fi

    case "$mode" in
        status)  _vhost_status "$target" "$site" "$dir" "$decl_path" "$decl_domain" ;;
        restore) _vhost_restore "$target" "$site" "$dir" "$decl_path" "$decl_domain" "$prefix" "$apply" ;;
    esac
}

################################################################################
# host-guard — does this box serve the application to ANY Host header?
# nwp/ops#381. See lib/server-host-guard.sh for the incident this exists for.
################################################################################
cmd_host_guard() {
    local target="" apply=0 arg
    local -a extra_allow=()
    PROBE_CMD=""
    for arg in "$@"; do
        case "$arg" in
            --status)      apply=0 ;;
            --apply)       apply=1 ;;
            --allow=*)     extra_allow+=("${arg#--allow=}") ;;
            --probe-cmd=*) PROBE_CMD="${arg#--probe-cmd=}" ;;
            -h|--help)     _host_guard_usage; return 0 ;;
            -*)            echo "Unknown option: $arg" >&2; return 2 ;;
            *)             if [[ -z "$target" ]]; then target="$arg"
                           else echo "Unexpected argument: $arg" >&2; return 2; fi ;;
        esac
    done
    if [[ -z "$target" ]]; then _host_guard_usage >&2; return 2; fi

    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/lib/server-host-guard.sh"

    local prefix
    prefix=$(_resolve_probe_prefix "$target") || {
        echo "CANNOT VERIFY: cannot resolve a destination for '${target}'" >&2; return 3; }

    # The name the box is SUPPOSED to answer to, from the tracked inventory.
    local declared_domain
    declared_domain="$(get_server_domain "$target" 2>/dev/null || true)"

    local facts; facts="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$facts'" RETURN

    local probe_real="${declared_domain:-localhost}"
    if ! host_run "$prefix" "$(host_guard_probe_script "$probe_real")" > "$facts" 2>/dev/null; then
        echo "CANNOT VERIFY: the host-guard probe did not run on '${target}'"
        echo "               — this is NOT 'the box is guarded'."
        return 3
    fi

    # GitLab's own name is the allowlist's whole content: the guard sits INSIDE
    # GitLab's server block, reached only by requests that already failed to
    # match every other vhost's server_name. Prefer what the BOX says over what
    # the inventory says — the inventory is known to drift (ops#381 item 3).
    local ext_url ext_host
    ext_url="$(host_guard_fact "$facts" gitlab_external_url)"
    ext_host="$(host_guard_host_of_url "$ext_url")"

    echo "═══════════════════════════════════════════════════════════════"
    echo "  pl server host-guard — ${target}"
    echo "═══════════════════════════════════════════════════════════════"
    echo
    printf '  %-22s %s\n' "declared domain" "${declared_domain:-<none in inventory>}"
    printf '  %-22s %s\n' "gitlab external_url" "${ext_host:-<unreadable>}"
    printf '  %-22s %s\n' "guard declared" "$(host_guard_fact "$facts" guard_declared)"
    echo

    local verdict rc=0
    verdict="$(host_guard_verdict "$facts")" || rc=$?
    printf '%s\n' "$verdict" | sed 's/^/  /'
    echo

    if [[ $rc -eq 3 ]]; then
        return 3
    fi

    # STATUS mode stops here, whatever the verdict. Read-only is the default.
    if [[ $apply -eq 0 ]]; then
        if [[ $rc -eq 1 ]]; then
            echo "  To close it:  pl server host-guard ${target} --apply"
            echo "  (dry-run is the default; --apply is the only thing that writes)"
        fi
        return $rc
    fi

    ############################################################################
    # APPLY
    ############################################################################
    if [[ $rc -eq 0 ]]; then
        echo "  Already guarded — nothing to apply."
        return 0
    fi

    if [[ "$(host_guard_fact "$facts" gitlab_embedded)" != "yes" ]]; then
        echo "REFUSING: '${target}' has no /opt/gitlab. This verb seats the guard in"
        echo "          gitlab.rb's custom_gitlab_server_config, which does not exist"
        echo "          here. A plain-nginx box needs a default_server catch-all"
        echo "          instead — a different repair, not this one."
        return 2
    fi
    if [[ "$(host_guard_fact "$facts" gitlab_rb_readable)" != "yes" ]]; then
        echo "CANNOT VERIFY: /etc/gitlab/gitlab.rb is not readable on '${target}',"
        echo "               so the guard's seat cannot be inspected. Refusing to write"
        echo "               into a file whose current contents are unknown."
        return 3
    fi
    if [[ -z "$ext_host" ]]; then
        echo "CANNOT VERIFY: could not read external_url from gitlab.rb on '${target}'."
        echo "               Refusing to render an allowlist by guessing the hostname —"
        echo "               a wrong guess here 444s the box off the internet."
        return 3
    fi

    local snippet
    snippet="$(host_guard_render "$ext_host" "${extra_allow[@]}")" || return 2

    echo "  Guard to install (seat: /etc/gitlab/nwp-host-guard.conf):"
    echo "  ─────────────────────────────────────────────────────────"
    printf '%s\n' "$snippet" | sed 's/^/    /'
    echo "  ─────────────────────────────────────────────────────────"
    echo "  gitlab.rb: $(host_guard_gitlab_rb_line /etc/gitlab/nwp-host-guard.conf)"
    echo

    if ! _host_guard_confirm "$target"; then
        echo "  Aborted. Nothing was written."
        return 1
    fi

    local apply_script
    apply_script="$(_host_guard_apply_script "$snippet")"
    if ! host_run "$prefix" "$apply_script"; then
        echo "APPLY FAILED on '${target}'. nginx config was NOT reloaded if the"
        echo "syntax check failed — check the output above." >&2
        return 1
    fi

    # RE-PROBE. The apply is not believed because it exited 0; it is believed
    # because the box now refuses an unknown Host. ops#214: a check that has
    # never been proven to fail is not a check, and an apply that was never
    # re-measured is not an apply.
    echo
    echo "  Re-probing to PROVE the guard bites …"
    local facts2; facts2="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$facts' '$facts2'" RETURN
    if ! host_run "$prefix" "$(host_guard_probe_script "$probe_real")" > "$facts2" 2>/dev/null; then
        echo "  CANNOT VERIFY: the re-probe did not run. The guard may or may not be"
        echo "                 live — check by hand before believing this succeeded."
        return 3
    fi
    local rc2=0
    verdict="$(host_guard_verdict "$facts2")" || rc2=$?
    printf '%s\n' "$verdict" | sed 's/^/  /'
    return $rc2
}

# The apply, as a single remote script: write the seat, declare it in gitlab.rb
# (idempotently), syntax-check, and only then reconfigure.
_host_guard_apply_script() {
    local snippet="$1"
    cat <<EOF
set -eu
SEAT=/etc/gitlab/nwp-host-guard.conf
RB=/etc/gitlab/gitlab.rb
STAMP=\$(date -u +%Y%m%dT%H%M%SZ)

# Back up gitlab.rb before touching it. Old value recorded, rollback possible.
sudo -n cp -a "\$RB" "\${RB}.bak-hostguard-\${STAMP}"
printf 'backup=%s\n' "\${RB}.bak-hostguard-\${STAMP}"

sudo -n tee "\$SEAT" >/dev/null <<'GUARDEOF'
${snippet}
GUARDEOF
sudo -n chmod 0644 "\$SEAT"

# Declare it once. Re-running must not stack duplicate assignments.
if ! sudo -n grep -q 'nwp-host-guard.conf' "\$RB"; then
  printf '\n# NWP-HOST-GUARD v1 — nwp/ops#381. Managed by \`pl server host-guard\`.\n' | sudo -n tee -a "\$RB" >/dev/null
  printf "nginx['custom_gitlab_server_config'] = File.read('%s')\n" "\$SEAT" | sudo -n tee -a "\$RB" >/dev/null
fi

sudo -n gitlab-ctl reconfigure >/dev/null 2>&1 || {
  printf 'reconfigure_failed=yes\n'; exit 1; }

# Syntax-check the GENERATED config before it is trusted.
sudo -n /opt/gitlab/embedded/sbin/nginx -p /var/opt/gitlab/nginx -t 2>&1 | tail -3
printf 'applied=yes\n'
EOF
}

# The typed live confirm. Writing nginx config on a box serving real HTTP is not
# something to do on a y/N reflex.
_host_guard_confirm() {
    local target="$1" answer=""
    if [[ -n "${NWP_ASSUME_YES:-}" ]]; then return 0; fi
    echo "  This writes nginx config on '${target}' and runs gitlab-ctl reconfigure."
    printf "  Type the server name to proceed: "
    read -r answer </dev/tty 2>/dev/null || return 1
    [[ "$answer" == "$target" ]]
}

_host_guard_usage() {
    cat <<'USAGE'
Usage: pl server host-guard <server> [--status|--apply] [--allow=<host>]...

  Does this box serve the whole application to a Host header it has never
  heard of? If it does, every hostname on earth pointed at its IP gets an
  application to crawl — including a stranger's DANGLING DNS record.

  --status   (default) probe and grade. READ-ONLY.
             exit 0 = GUARDED · 1 = PROMISCUOUS · 3 = CANNOT VERIFY
  --apply    seat the guard, then RE-PROBE to prove it bites. An apply that
             was never re-measured is not an apply.
  --allow=   admit an extra Host beyond GitLab's own external_url. Repeatable.

WHERE THE GUARD SITS. In gitlab.rb's nginx['custom_gitlab_server_config'],
which chef splices into GitLab's server block. NOT in
/var/opt/gitlab/nginx/conf/ — that is generated, and the next
`gitlab-ctl reconfigure` silently reverts anything written there.

WHY NOT A default_server CATCH-ALL. nginx allows one default_server per
listen address and GitLab's block already claims it; taking it away means
editing chef-generated config. Guarding from inside the block avoids that,
and leaves sibling vhosts with explicit server_name untouched.

nwp/ops#381 — 2026-08-19/20, a vulnerability scan aimed at a third party's
dangling DNS record served 13.1 GB off our GitLab in one morning and tripped
the provider's outbound traffic-rate alarm.
USAGE
}

_vhost_usage() {
    cat <<'USAGE'
Usage: pl server vhost <server> <site> [--status|--restore] [--apply]

  --status   (default) is a vhost actually serving the site's declared root?
             which stashed copies exist? and which certificate would 443 fall
             through to if there is none? READ-ONLY.
  --restore  rebuild the vhost from a stashed copy, repairing GitLab-bundled
             includes and a missing ACME challenge location. DRY-RUN by
             default; --apply installs it, gated on `nginx -t`.
USAGE
}

# ── status ──────────────────────────────────────────────────────────────────
_vhost_status() {
    local target="$1" site="$2" dir="$3" decl="$4" domain="$5"
    local rel served=() stashes=() rc=0

    printf 'vhost status: %s on %s\n' "$site" "$target"
    printf '  declared root   %s\n' "$decl"
    [[ -n "$domain" ]] && printf '  declared domain %s\n' "$domain"
    printf '  nginx           %s (reload: %s)\n' \
        "$([[ "$(vhost_fact "$dir" gitlab_embedded)" == yes ]] && echo 'GitLab-bundled' || echo 'standalone')" \
        "$(vhost_reload_cmd "$dir")"

    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        vhost_serves_root "$dir/$rel" "$decl" && served+=("$rel")
    done < <(vhost_active_confs "$dir")

    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        stashes+=("$rel")
    done < <(vhost_stashes_for "$dir" "$site" "$decl")

    if [[ ${#served[@]} -gt 0 ]]; then
        for rel in "${served[@]}"; do
            printf '  OK   SERVED           %s\n' "$VHOST_CONF_DIR/$rel"
            printf '       serves           %s\n' "$(vhost_roots_of "$dir/$rel" | paste -sd' ' -)"
            if vhost_has_443 "$dir/$rel"; then
                printf '       443 cert         %s\n' "$(vhost_cert_of "$dir/$rel")"
            else
                printf '  WARN no 443 listener in this vhost — it serves plain HTTP only\n'
                rc=1
            fi
            vhost_needs_acme "$dir/$rel" && {
                printf '  WARN no ACME challenge location — certbot webroot renewal will fail,\n'
                printf '       and the site goes down when the certificate expires\n'
                rc=1
            }
        done
    else
        # THE INCIDENT SHAPE.
        printf '  RED  NO VHOST SERVES IT  nothing loaded from %s serves %s\n' "$VHOST_CONF_DIR" "$decl"
        local ft; ft="$(vhost_fallthrough_conf "$dir")"
        if [[ -n "$ft" ]]; then
            printf '       443 FALLS THROUGH to %s\n' "$VHOST_CONF_DIR/$ft"
            printf '       serving certificate  %s\n' "$(vhost_cert_of "$dir/$ft")"
            printf '       => a browser asking for %s is handed THAT certificate and refuses\n' \
                "${domain:-this site}"
        fi
        rc=1
    fi

    if [[ ${#stashes[@]} -gt 0 ]]; then
        for rel in "${stashes[@]}"; do
            printf '  INFO STASHED (inert)  %s\n' "$VHOST_CONF_DIR/$rel"
        done
        [[ ${#served[@]} -eq 0 ]] && \
            printf '       restore it with:  pl server vhost %s %s --restore\n' "$target" "$site"
    elif [[ ${#served[@]} -eq 0 ]]; then
        printf '       no stashed copy found — a restore has nothing to rebuild from\n'
    fi
    return $rc
}

# ── restore ─────────────────────────────────────────────────────────────────
_vhost_restore() {
    local target="$1" site="$2" dir="$3" decl="$4" domain="$5" prefix="$6" apply="$7"
    local rel served=() stashes=()

    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        vhost_serves_root "$dir/$rel" "$decl" && served+=("$rel")
    done < <(vhost_active_confs "$dir")
    if [[ ${#served[@]} -gt 0 ]]; then
        echo "REFUSED: ${VHOST_CONF_DIR}/${served[0]} already serves ${decl} — a restore never"
        echo "         overwrites a live config. Nothing to do."
        return 1
    fi

    while IFS= read -r rel; do [[ -n "$rel" ]] && stashes+=("$rel"); done \
        < <(vhost_stashes_for "$dir" "$site" "$decl")
    if [[ ${#stashes[@]} -eq 0 ]]; then
        echo "CANNOT VERIFY: no stashed vhost for '${site}' found in ${VHOST_CONF_DIR}"
        echo "               A restore rebuilds from a stash; there is nothing to rebuild from."
        return 3
    fi
    local src="${stashes[0]}"
    if [[ ${#stashes[@]} -gt 1 ]]; then
        echo "NOTE: ${#stashes[@]} stashed copies found; using the first: $src"
        for rel in "${stashes[@]}"; do printf '      %s\n' "$VHOST_CONF_DIR/$rel"; done
    fi

    local work="$dir/.restored" webroot
    # certbot validates into the docroot nginx serves, not the declared parent.
    read -r webroot < <(vhost_roots_of "$dir/$src") || true
    [[ -n "$webroot" ]] || webroot="$decl"

    local r1=0 r2=0
    vhost_repair_gitlab_includes "$dir/$src" > "$work.1" || r1=$?
    vhost_repair_acme "$work.1" "$webroot" > "$work" || r2=$?
    if [[ $r2 -eq 2 ]]; then
        echo "REFUSED: cannot safely add the ACME challenge location (see above)."
        echo "         Restore is not attempted — an edit made blind is how a config gets worse."
        return 1
    fi

    local target_conf="$VHOST_CONF_DIR/${site}.conf"
    printf 'vhost restore: %s on %s\n' "$site" "$target"
    printf '  from stash    %s\n' "$VHOST_CONF_DIR/$src"
    printf '  install as    %s\n' "$target_conf"
    printf '  repairs applied:\n'
    if [[ $r1 -eq 0 ]]; then
        printf '    [x] GitLab-bundled includes repointed to /etc/nginx/ (the box has no /opt/gitlab)\n'
    else
        printf '    [ ] no GitLab-bundled includes to repoint\n'
    fi
    if [[ $r2 -eq 0 ]]; then
        printf '    [x] ACME challenge location added to the port-80 block (root %s)\n' "$webroot"
    else
        printf '    [ ] ACME challenge location already present\n'
    fi
    printf '  diff (stash -> what would be installed):\n'
    diff -u "$dir/$src" "$work" | sed 's/^/    /' || true

    if [[ "$apply" -ne 1 ]]; then
        printf '\n  DRY RUN — nothing was changed. Re-run with --apply to install.\n'
        return 0
    fi

    local reload; reload="$(vhost_reload_cmd "$dir")"
    printf '\n  APPLYING (nginx -t must pass, or the file is removed again)\n'
    local script rc=0
    script="$(vhost_apply_script "$target_conf" "$reload")"
    if [[ "$prefix" == "LOCAL" ]]; then
        bash -c "$script" < "$work" || rc=$?
    else
        # shellcheck disable=SC2086
        $prefix "$script" < "$work" || rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        echo "FAILED (rc=$rc) — the box is unchanged."
        return 1
    fi
    printf '\n  ROLLBACK (the stash was copied, never moved, so this fully reverts it):\n'
    printf '    %s "sudo rm %s && sudo nginx -t && %s"\n' "${prefix}" "$target_conf" "$reload"
    return 0
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
# Subcommand: sync <from> <to>
#
# Move the LIVE data of every site declared on <from> onto <to>. This is the
# box-split primitive: `pl backup --remote` pulls a snapshot DOWN to the
# workstation (the DR shape), which is the wrong direction for a migration.
#
# Dry-run by default. The source is only ever read.
################################################################################
cmd_sync() {
    local from="" to="" only_sites="" do_db=1 do_files=0 execute=0 auto_yes=0 skip_missing=0 arg
    for arg in "$@"; do
        case "$arg" in
            --sites=*)  only_sites="${arg#--sites=}" ;;
            --skip-missing) skip_missing=1 ;;
            --db)       do_db=1 ;;
            --files)    do_files=1 ;;
            --files-only) do_files=1; do_db=0 ;;
            --execute)  execute=1 ;;
            -y|--yes)   auto_yes=1 ;;
            -*)         echo "Unknown option: $arg" >&2; return 2 ;;
            *)          if [[ -z "$from" ]]; then from="$arg"; elif [[ -z "$to" ]]; then to="$arg";
                        else echo "Unexpected argument: $arg" >&2; return 2; fi ;;
        esac
    done
    if [[ -z "$from" || -z "$to" ]]; then
        echo "Usage: pl server sync <from-server> <to-server> [--sites=a,b] [--files] [--execute]" >&2
        return 2
    fi
    if [[ "$from" == "$to" ]]; then
        echo "ERROR: source and target are the same server ('$from')." >&2
        return 2
    fi

    local sp dp
    sp=$(sync_ssh_prefix "$from") || { echo "ERROR: cannot resolve server '$from'" >&2; return 2; }
    dp=$(sync_ssh_prefix "$to")   || { echo "ERROR: cannot resolve server '$to'" >&2; return 2; }

    # Both endpoints must answer before anything is planned. A migration
    # half-planned against an unreachable box is worse than no plan.
    local s_ok t_ok
    s_ok=$($sp 'echo ok' </dev/null 2>/dev/null || true)
    t_ok=$($dp 'echo ok' </dev/null 2>/dev/null || true)
    if [[ "$s_ok" != "ok" ]]; then echo "ERROR: source '$from' unreachable over ssh." >&2; return 3; fi
    if [[ "$t_ok" != "ok" ]]; then echo "ERROR: target '$to' unreachable over ssh." >&2; return 3; fi

    # Which sites? Declarations and data move at DIFFERENT times during a
    # migration: the normal order is to repoint sites/<name>/.nwp.yml FIRST
    # (so deploys go to the new box) and move the data second. Enumerating only
    # `from` therefore finds nothing exactly when you need it most. Take the
    # union of both servers' declarations, deduplicated.
    local sites
    if [[ -n "$only_sites" ]]; then
        sites=$(printf '%s' "$only_sites" | tr ',' '\n')
    else
        sites=$(printf '%s\n%s\n' "$(get_server_sites "$from")" "$(get_server_sites "$to")" \
                | sed '/^$/d' | sort -u)
    fi
    if [[ -z "$sites" ]]; then
        echo "No sites declared on '$from'. Nothing to sync."
        return 0
    fi

    print_header "server sync: ${from} -> ${to}$( ((execute)) || echo '  (DRY RUN)')"

    # Collect the plan first, so an undeterminable DB name aborts BEFORE any
    # write rather than halfway through the fleet.
    # Explicit empty initialisers: under `set -u`, expanding an array that was
    # declared but never assigned is fatal, which turned "nothing to sync" into
    # an unbound-variable crash.
    local -a plan_site=() plan_type=() plan_db=() plan_path=()
    local -A seen_db=()
    local failures=0 name type path webroot sdb ddb enabled rc
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        local cfg="${NWP_DIR:-$PROJECT_ROOT}/sites/$name/.nwp.yml"
        if [[ ! -f "$cfg" ]]; then
            print_warning "$name: no sites/$name/.nwp.yml — skipped"
            continue
        fi
        enabled=$("$YQ" eval '.live.enabled // ""' "$cfg" 2>/dev/null)
        if [[ "$enabled" != "true" ]]; then
            print_info "$name: live.enabled is not true — skipped"
            continue
        fi
        type=$("$YQ" eval '.project.type // ""' "$cfg" 2>/dev/null)
        path=$("$YQ" eval '.live.remote_path // ""' "$cfg" 2>/dev/null)
        webroot=$("$YQ" eval '.project.webroot // ""' "$cfg" 2>/dev/null)
        if [[ -z "$type" || -z "$path" ]]; then
            print_error "$name: .project.type or .live.remote_path missing — cannot sync"
            failures=$((failures+1)); continue
        fi

        # A declared path that does not exist on the source holds no data to
        # migrate, and is nearly always a stale declaration. Say so out loud
        # rather than reporting an undeterminable DB name.
        if ! sync_path_exists "$sp" "$path"; then
            if (( skip_missing )); then
                print_warning "$name: declared live path '$path' does not exist on '${from}' — SKIPPED (--skip-missing)"
                continue
            fi
            print_error "$name: declared live path '$path' does not exist on '${from}' — stale declaration"
            failures=$((failures+1)); continue
        fi

        # `|| true` is load-bearing under `set -e`: a probe that legitimately
        # finds nothing (static site, missing config) must not abort the whole
        # plan and leave the rest of the fleet unexamined.
        sdb=$(sync_probe_dbname "$sp" "$type" "$path" "$webroot" || true); rc=$?
        if [[ "$type" == "static" ]]; then
            print_info "$name: static site (no database) — nothing to sync"
            continue
        fi
        ddb=$(sync_probe_dbname "$dp" "$type" "$path" "$webroot" || true)
        if [[ -z "$sdb" ]]; then
            print_error "$name: could not read the live DB name from ${type} config on '${from}' — refusing to guess"
            failures=$((failures+1)); continue
        fi
        if [[ -z "$ddb" ]]; then
            print_error "$name: could not read the DB name from ${type} config on '${to}' — refusing to guess"
            failures=$((failures+1)); continue
        fi
        if [[ "$sdb" != "$ddb" ]]; then
            print_error "$name: DB name differs (${from}='${sdb}' ${to}='${ddb}') — refusing to cross-write"
            failures=$((failures+1)); continue
        fi

        # Several site records can describe the SAME live install (nw1/nwc both
        # are /var/www/nwc; ss/ssc share a Moodle). Copying one database twice
        # is wasted time and a second chance to get it wrong.
        if [[ -n "${seen_db[$sdb]:-}" ]]; then
            print_info "$name: database '${sdb}' already planned via '${seen_db[$sdb]}' — deduplicated"
            continue
        fi
        seen_db[$sdb]="$name"

        plan_site+=("$name"); plan_type+=("$type"); plan_db+=("$sdb"); plan_path+=("$path")
        printf "  %-12s %-7s db=%-14s %s\n" "$name" "$type" "$sdb" "$path"
    done <<< "$sites"

    if (( failures > 0 )); then
        print_error "${failures} site(s) could not be planned. Nothing was written."
        print_info  "Fix the declaration, or re-run with --skip-missing to proceed without them."
        return 1
    fi
    if (( ${#plan_site[@]} == 0 )); then
        echo "Nothing to do."
        return 0
    fi

    if (( ! execute )); then
        echo
        print_info "DRY RUN — ${#plan_site[@]} database(s) would be overwritten on '${to}'."
        print_info "Re-run with --execute to perform the sync."
        return 0
    fi

    # Say exactly what is about to be destroyed BEFORE asking. The report is
    # unconditional; only the prompt is skippable with -y. A verb that
    # overwrites live databases must never be able to run without first naming
    # them (lib/impact.sh, the same contract `pl delete` follows).
    # The manifest and the prompt live with the destructive primitives, in
    # lib/server-sync.sh, so no other caller can drive them with no manifest.
    if ! sync_render_and_confirm "$from" "$to" "$do_files" "$auto_yes" plan_site plan_db; then
        print_info "Aborted."
        return 1
    fi

    local i rc_all=0
    if (( do_db )); then
    for i in "${!plan_site[@]}"; do
        local n="${plan_site[$i]}" db="${plan_db[$i]}"
        print_info "syncing ${n} (${db}) ..."

        if ! sync_db_stream "$sp" "$dp" "$db" "$db"; then
            print_error "${n}: dump/restore stream FAILED — target DB may be partial"
            rc_all=1; continue
        fi
        # Verify. Table count must match exactly; the row hash is reported but
        # a difference there is expected on a live source (sessions, logs,
        # watchdog all move while the dump runs) and is not treated as failure.
        local sfp tfp scount tcount
        sfp=$(sync_db_fingerprint "$sp" "$db"); tfp=$(sync_db_fingerprint "$dp" "$db")
        if [[ "$sfp" == UNKNOWN* || "$tfp" == UNKNOWN* ]]; then
            print_error "${n}: post-sync verification could not run — NOT treating as verified"
            rc_all=1; continue
        fi
        scount="${sfp%%:*}"; tcount="${tfp%%:*}"
        if [[ "$scount" != "$tcount" ]]; then
            print_error "${n}: table count differs after sync (src=${scount} dst=${tcount})"
            rc_all=1; continue
        fi
        if [[ "$sfp" == "$tfp" ]]; then
            print_status "OK" "${n}: ${scount} tables, row-for-row identical"
        else
            print_status "OK" "${n}: ${scount} tables match (row hash differs — live source moved during the dump)"
        fi
    done
    fi

    if (( do_files )); then
        print_header "file sync (mutable data trees)"
        local stage_root="${NWP_SYNC_STAGE:-$HOME/.cache/nwp/server-sync/${from}-to-${to}}"
        mkdir -p "$stage_root"
        print_info "staging through ${stage_root} (delta on both hops; safe to re-run)"
        for i in "${!plan_site[@]}"; do
            local n="${plan_site[$i]}" t="${plan_type[$i]}" p="${plan_path[$i]}"
            local dirs
            dirs=$(sync_probe_datadirs "$sp" "$t" "$p" "" || true)
            if [[ -z "${dirs//[[:space:]]/}" ]]; then
                print_warning "${n}: could not determine a data directory — NOT silently skipping, check by hand"
                rc_all=1; continue
            fi
            local d
            while IFS= read -r d; do
                [[ -z "${d//[[:space:]]/}" ]] && continue
                if ! sync_path_exists "$sp" "$d"; then
                    print_info "  ${n}: ${d} does not exist on ${from} — skipped"
                    continue
                fi
                if sync_dir_relay "$from" "$to" "$d" "$stage_root"; then
                    print_status "OK" "  ${n}: ${d}"
                else
                    print_error "  ${n}: ${d} — rsync FAILED"
                    rc_all=1
                fi
            done <<< "$dirs"
        done
    fi

    return $rc_all
}

################################################################################
# Subcommand: prune <server>
#
# The LAST step of a box migration: remove from <server> the artefacts of the
# sites that have moved off it. See lib/server-prune.sh for the gate set
# ([P1]-[P6]) and why each exists.
#
# Dry-run by default; --execute is required to delete anything.
################################################################################
cmd_prune() {
    local server="" execute=0 auto_yes=0 backup_within=24 do_certs=1 arg
    for arg in "$@"; do
        case "$arg" in
            --execute)                execute=1 ;;
            -y|--yes)                 auto_yes=1 ;;
            --require-backup-within=*) backup_within="${arg#--require-backup-within=}" ;;
            --no-backup-check)        backup_within="" ;;
            --no-certs)               do_certs=0 ;;
            -*)  echo "Unknown option: $arg" >&2; return 2 ;;
            *)   if [[ -z "$server" ]]; then server="$arg";
                 else echo "Unexpected argument: $arg" >&2; return 2; fi ;;
        esac
    done
    if [[ -z "$server" ]]; then
        echo "Usage: pl server prune <server> [--execute] [-y] [--require-backup-within=H] [--no-certs]" >&2
        return 2
    fi

    local prefix
    prefix=$(sync_ssh_prefix "$server") || { echo "ERROR: cannot resolve server '$server'" >&2; return 2; }
    local ok; ok=$($prefix 'echo ok' </dev/null 2>/dev/null || true)
    [[ "$ok" == "ok" ]] || { echo "ERROR: server '$server' unreachable over ssh." >&2; return 3; }

    print_header "server prune: ${server}$( ((execute)) || echo '  (DRY RUN)')"

    # --- [P6] a backup must exist ------------------------------------------
    if [[ -n "$backup_within" ]]; then
        local age
        if ! age=$(prune_backup_age_hours "$prefix"); then
            echo "REFUSING: no backup found on '$server' under /var/backups/nwp-pull." >&2
            echo "          Prune destroys the last non-backup copy. Take a backup first," >&2
            echo "          or pass --no-backup-check if you hold one elsewhere." >&2
            return 1
        fi
        if [[ "$age" -gt "$backup_within" ]]; then
            echo "REFUSING: newest backup on '$server' is ${age}h old (limit ${backup_within}h)." >&2
            return 1
        fi
        print_success "backup present on '$server' (newest ${age}h old)"
    fi

    # --- [P2] build the KEEP set from what is DECLARED to this box ---------
    # `|| true`: get_server_sites returns the exit status of its LAST loop
    # iteration, so it reports failure whenever the last site it happens to
    # inspect is not on this server — which is usually. Under the `set -e
    # pipefail` this file runs with, that silently killed the whole command
    # after the backup check. The keep-list must never be empty by accident,
    # so this is guarded rather than trusted.
    local kept_sites; kept_sites=$(get_server_sites "$server" 2>/dev/null | sed '/^$/d' || true)
    if [[ -z "$kept_sites" ]]; then
        echo "WARNING: no sites are declared to '$server' — the keep-list is empty." >&2
        echo "         Every /var/www tree will be treated as prunable. Check" >&2
        echo "         sites/*/.nwp.yml declares .live.server before continuing." >&2
    fi
    local -a keep_trees=() keep_names=()
    local s p
    # NB: every loop below ends in a plain statement, never a trailing
    # `[[ ... ]] && cmd`. A loop takes the exit status of its last command, so
    # a false test on the final iteration makes the LOOP fail, and under
    # `set -e` that aborts the command with no message at all.
    for s in $kept_sites; do
        keep_names+=("$s")
        p=$(get_site_remote_path "$s" 2>/dev/null || true)
        if [[ -n "$p" ]]; then keep_trees+=("$(basename "$p")"); fi
    done
    for s in $PRUNE_NEVER_TOUCH; do keep_trees+=("$s"); done

    # Infrastructure roots declared on the SERVER record are never site data —
    # ACME webroots, proxy vhosts, the headscale control server. They have no
    # sites/<n>/.nwp.yml by design, so the site-derived keep-list above cannot
    # see them, and "not a site" must never read as "prunable".
    #
    # The key is `infrastructure_roots[]` at the top level with .path/.domain
    # (see servers/<n>/.nwp-server.yml). Getting that path wrong fails SILENTLY
    # — an empty keep-list looks exactly like "no infrastructure declared" —
    # which is how the first cut of this put hs.<live-domain>'s certbot renewal
    # on the delete list.
    local srec="$NWP_DIR/servers/$server/.nwp-server.yml"
    local -a infra_domains=()
    local ipath idom
    while read -r ipath; do
        [[ -n "$ipath" ]] || continue
        # /var/www/hs/html is the ACME webroot; the tree that must survive is
        # /var/www/hs. Keep the FIRST component under /var/www, not the leaf.
        local itree
        if itree=$(prune_infra_tree "$ipath"); then keep_trees+=("$itree"); fi
    done < <($YQ e '.infrastructure_roots[]?.path // ""' "$srec" 2>/dev/null | sed '/^$/d' || true)
    while read -r idom; do
        if [[ -n "$idom" ]]; then infra_domains+=("$idom"); fi
    done < <($YQ e '.infrastructure_roots[]?.domain // ""' "$srec" 2>/dev/null | sed '/^$/d' || true)

    # --- [P1] candidates: ONLY what is positively attributable to a site
    #     that has MOVED. ------------------------------------------------------
    #
    # THE INVERSION THAT MATTERS. The obvious shape — "delete everything not on
    # the keep-list" — is wrong, and dangerously so. It makes UNDECLARED mean
    # PRUNABLE, when the whole point of [P2] is that unknown means keep. A
    # dry-run of that shape against the live sites box proposed to delete:
    #
    #   * every *_moodledata directory on the box. A Moodle declares
    #     remote_path: /var/www/ssc — its webroot — while its data lives in a
    #     SEPARATE, undeclared /var/www/ssc_moodledata. Deleting those destroys
    #     every Moodle on the host, irreversibly, while the webroot survives so
    #     the site merely 500s instead of obviously vanishing.
    #   * two live databases nothing happened to name.
    #   * the certificate for rgv.<live-domain> — a site that is SERVING (HTTP
    #     401, basic-auth gated) but has no sites/rgv/.nwp.yml at all.
    #
    # So the delete set is now BUILT UP from migrated sites rather than
    # SUBTRACTED from everything present. A tree, database or certificate that
    # cannot be traced to a specific site declared on another server is never a
    # candidate, no matter how orphaned it looks.
    local -a del_trees=() del_dbs=() del_vhosts=() del_certs=() keeps=()
    local -a moved_sites=() moved_trees=() moved_domains=() moved_verified=()
    local msrv
    # Needed by the [P1] DNS check below, before the cert block resolves it.
    local my_ip_early; my_ip_early=$(get_server_ip "$server" 2>/dev/null || true)
    for cfg in "$NWP_DIR"/sites/*/.nwp.yml; do
        [[ -f "$cfg" ]] || continue
        s="$(basename "$(dirname "$cfg")")"
        msrv="$($YQ e '.live.server // ""' "$cfg" 2>/dev/null || true)"
        # Declared HERE, or declared nowhere -> not a candidate. Only an
        # explicit declaration to a DIFFERENT server makes a site migrated.
        [[ -n "$msrv" && "$msrv" != "$server" ]] || continue
        p=$(get_site_remote_path "$s" 2>/dev/null || true)
        [[ -n "$p" ]] || continue

        # [P1] PROOF OF LIFE ELSEWHERE. A declaration states intent; DNS states
        # what users actually reach. `cccrdf` is declared to the live server yet
        # its A record still points at the OLD box — so on declarations alone
        # this would have authorised deleting the only copy of a site no new box
        # is serving. Require the site's own domain to resolve somewhere that is
        # not this box before treating any of its assets as prunable.
        local sdom sip
        sdom=$(get_site_domain "$s" 2>/dev/null || true)
        if [[ -z "$sdom" ]]; then
            keeps+=("${server}: site '${s}' — declared on '${msrv}' but has no domain to verify against, KEPT")
            continue
        fi
        sip=$(dig +short "$sdom" 2>/dev/null | tail -1)
        if ! prune_points_elsewhere "$sdom" "$sip" "$my_ip_early"; then
            keeps+=("${server}: site '${s}' — declared on '${msrv}' but ${sdom} still resolves ${sip:+to ${sip} }here (or not at all), KEPT")
            continue
        fi
        moved_sites+=("$s")
        moved_verified+=("${s}|${sdom}|${sip}")
        # Companion data directories are never declared but always paired —
        # see prune_companion_trees for why missing them is catastrophic.
        local ct
        while read -r ct; do
            if [[ -n "$ct" ]]; then moved_trees+=("$ct"); fi
        done < <(prune_companion_trees "$p")
        local d; d=$(get_site_domain "$s" 2>/dev/null || true)
        if [[ -n "$d" ]]; then moved_domains+=("$d"); fi
    done

    # Trees: present on disk AND attributable to a moved site AND not kept.
    local tree base sz
    while read -r sz base; do
        [[ -n "$base" ]] || continue
        if [[ " ${keep_trees[*]} " == *" $base "* ]]; then
            keeps+=("${server}: /var/www/${base} — declared to this server, kept")
            continue
        fi
        if [[ " ${moved_trees[*]:-} " != *" $base "* ]]; then
            keeps+=("${server}: /var/www/${base} — not attributable to any migrated site, KEPT")
            continue
        fi
        del_trees+=("/var/www/${base}|${sz} — belongs to a site now served from another box")
    done < <($prefix "sudo du -sh /var/www/*/ 2>/dev/null | sed 's#/var/www/##; s#/\$##'" </dev/null 2>/dev/null || true)

    # --- [P5] databases: only those a MOVED site's own config names ---------
    # Read the db name out of each moved site's config as it still exists on
    # THIS box. A database nothing points at is left alone: "orphaned" is a
    # guess, and a wrong guess here is unrecoverable.
    local -a moved_paths=()
    for s in "${moved_sites[@]:-}"; do
        p=$(get_site_remote_path "$s" 2>/dev/null || true)
        if [[ -n "$p" ]]; then moved_paths+=("$p"); fi
    done
    local moved_dbs
    moved_dbs=$(prune_probe_live_dbnames "$prefix" "${moved_paths[@]:-}" 2>/dev/null | sed '/^$/d' | sort -u || true)

    local db
    while read -r db sz; do
        [[ -n "$db" ]] || continue
        case "$db" in information_schema|performance_schema|mysql|sys) continue ;; esac
        if [[ -z "$moved_dbs" ]] || ! printf '%s\n' "$moved_dbs" | grep -qx "$db"; then
            keeps+=("${server}: database '${db}' — not named by any migrated site's config, KEPT")
            continue
        fi
        del_dbs+=("${db}|${sz:-?} MB — named by a site now served from another box")
    done < <($prefix "sudo mysql -N -e \"SELECT table_schema, ROUND(SUM(data_length+index_length)/1024/1024,1) FROM information_schema.tables GROUP BY table_schema;\" 2>/dev/null" </dev/null 2>/dev/null || true)

    # --- handoff fronts + migrated vhosts ----------------------------------
    # A handoff front is only removable when the name it fronts is one of the
    # sites [P1] just PROVED is being served elsewhere. Removing a front whose
    # site has not moved takes that site off the air instantly — the front is
    # the only thing still answering for it on this box.
    local v vname
    while read -r v; do
        [[ -n "$v" ]] || continue
        vname="${v#handoff-}"; vname="${vname%.conf}"
        if [[ " ${moved_domains[*]:-} " != *" $vname "* ]]; then
            keeps+=("${server}: vhost ${v} — fronts '${vname}', which is not a verified-moved site, KEPT")
            continue
        fi
        del_vhosts+=("${v}|proxy front for ${vname}, which is verified as served from another box")
    done < <($prefix "sudo ls -1 ${HANDOFF_CONF_DIR:-/etc/nginx/conf.d} 2>/dev/null | grep -E '^handoff-.*\.conf$'" </dev/null 2>/dev/null || true)

    # --- dead certbot renewals ---------------------------------------------
    if ((do_certs)); then
        # A certificate is only dead here if its name BOTH belongs to a site
        # that moved AND no longer resolves to this box. DNS is the ground
        # truth: a name still pointing here is still this box's to serve,
        # whatever any declaration says, and rgv.<live-domain> proved that
        # declarations can simply be missing for a site that is serving fine.
        #
        # A stale renewal is noise; deleting a live one takes a service off the
        # air at the next expiry — silently, weeks later, long after anyone
        # would connect it to this command.
        local my_ip="$my_ip_early"
        local c cip
        while read -r c; do
            [[ -n "$c" ]] || continue
            if [[ " ${moved_domains[*]:-} " != *" $c "* ]]; then
                keeps+=("${server}: certbot renewal ${c} — not a migrated site's name, KEPT")
                continue
            fi
            cip=$(dig +short "$c" 2>/dev/null | tail -1)
            if ! prune_cert_is_dead "$c" "$cip" "$my_ip"; then
                keeps+=("${server}: certbot renewal ${c} — still resolves here (or unresolvable), KEPT")
                continue
            fi
            del_certs+=("${c}|migrated site, and ${c} now resolves to ${cip}; renewal fails twice a day until removed")
        done < <($prefix "sudo ls ${PRUNE_RENEWAL_DIR:-/etc/letsencrypt/renewal}/*.conf 2>/dev/null" </dev/null 2>/dev/null | sed 's#.*/##; s#\.conf$##' || true)
    fi

    keeps+=("Everything under /var/www NOT listed above")
    keeps+=("GitLab, headscale and any service not derived from a site declaration")

    if [[ ${#del_trees[@]} -eq 0 && ${#del_dbs[@]} -eq 0 && ${#del_vhosts[@]} -eq 0 && ${#del_certs[@]} -eq 0 ]]; then
        print_success "nothing to prune on '$server'."
        return 0
    fi

    # --- [P3] fate manifest, then [P4] dry-run stops here -------------------
    if ! ((execute)); then
        prune_render_and_confirm "$server" 1 del_trees del_dbs del_vhosts del_certs keeps
        echo "DRY RUN — nothing was deleted. Re-run with --execute to apply."
        return 0
    fi
    prune_render_and_confirm "$server" "$auto_yes" del_trees del_dbs del_vhosts del_certs keeps || {
        echo "Aborted."; return 1; }

    # --- apply --------------------------------------------------------------
    local item rc=0
    for item in "${del_vhosts[@]}"; do
        v="${item%%|*}"
        $prefix "sudo rm -f ${HANDOFF_CONF_DIR:-/etc/nginx/conf.d}/$v" </dev/null || rc=1
        print_success "removed vhost $v"
    done
    if [[ ${#del_vhosts[@]} -gt 0 ]]; then
        if handoff_nginx_test "$prefix"; then handoff_nginx_reload "$prefix"; else
            echo "ERROR: nginx config test FAILED after vhost removal — not reloading." >&2; rc=1; fi
    fi
    for item in "${del_certs[@]}"; do
        c="${item%%|*}"
        $prefix "sudo rm -f /etc/letsencrypt/renewal/${c}.conf" </dev/null || rc=1
        print_success "removed dead certbot renewal $c"
    done
    for item in "${del_dbs[@]}"; do
        db="${item%%|*}"
        $prefix "sudo mysql -e 'DROP DATABASE \`$db\`;'" </dev/null || rc=1
        print_success "dropped database $db"
    done
    for item in "${del_trees[@]}"; do
        tree="${item%%|*}"
        # Belt and braces: refuse anything that is not a direct child of /var/www.
        case "$tree" in /var/www/*/*|/var/www|/var/www/) echo "REFUSING unexpected path: $tree" >&2; rc=1; continue ;; esac
        $prefix "sudo rm -rf '$tree'" </dev/null || rc=1
        print_success "removed $tree"
    done
    return $rc
}

################################################################################
# Subcommand: handoff <drain|front|restore|status> <server>
#
# Move traffic between boxes WITHOUT waiting for DNS. See lib/server-handoff.sh
# for why the switch belongs at the old box rather than in the A record.
################################################################################
cmd_handoff() {
    local mode="${1:-}" server="${2:-}"; shift 2 2>/dev/null || true
    local to_ip="" only="" exclude="" execute=0 auto_yes=0 arg
    for arg in "$@"; do
        case "$arg" in
            --to=*)      to_ip="${arg#--to=}" ;;
            --names=*)   only="${arg#--names=}" ;;
            --exclude=*) exclude="${arg#--exclude=}" ;;
            --execute)   execute=1 ;;
            -y|--yes)    auto_yes=1 ;;
            -*)          echo "Unknown option: $arg" >&2; return 2 ;;
        esac
    done
    case "$mode" in drain|front|restore|status) ;; *)
        echo "Usage: pl server handoff <drain|front|restore|status> <server> [--to=SERVER|IP] [--names=a,b] [--exclude=a,b] [--execute]" >&2
        return 2 ;;
    esac
    [[ -n "$server" ]] || { echo "ERROR: server name required" >&2; return 2; }

    local sp; sp=$(sync_ssh_prefix "$server") || { echo "ERROR: cannot resolve '$server'" >&2; return 2; }
    [[ "$($sp 'echo ok' </dev/null 2>/dev/null || true)" == "ok" ]] \
        || { echo "ERROR: '$server' unreachable over ssh." >&2; return 3; }

    # --to may name a server in the registry or be a literal address.
    local target_ip=""
    if [[ -n "$to_ip" ]]; then
        if [[ "$to_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then target_ip="$to_ip"
        else target_ip=$(get_server_ip "$to_ip" 2>/dev/null || true); fi
        [[ -n "$target_ip" ]] || { echo "ERROR: cannot resolve --to='$to_ip'" >&2; return 2; }
    fi

    if [[ "$mode" == "status" ]]; then
        print_header "handoff status — ${server}"
        $sp "sudo ls ${HANDOFF_BACKUP_DIR} 2>/dev/null | wc -l" </dev/null \
            | { read -r n; echo "  original vhosts backed up: ${n:-0} (${HANDOFF_BACKUP_DIR})"; }
        local d f
        d=$($sp "sudo grep -rl 'MIGRATION DRAIN' ${HANDOFF_CONF_DIR}/*.conf 2>/dev/null | wc -l" </dev/null)
        f=$($sp "sudo grep -rl 'MIGRATION FRONT' ${HANDOFF_CONF_DIR}/*.conf 2>/dev/null | wc -l" </dev/null)
        echo "  vhost files in DRAIN mode: ${d:-0}"
        echo "  vhost files in FRONT mode: ${f:-0}"
        return 0
    fi

    if [[ "$mode" == "restore" ]]; then
        if ! $sp "sudo test -d ${HANDOFF_BACKUP_DIR}" </dev/null; then
            print_error "no backup at ${HANDOFF_BACKUP_DIR} on '${server}' — nothing to restore"
            return 1
        fi
        if (( ! execute )); then
            print_info "DRY RUN — would restore the original vhosts on '${server}' from ${HANDOFF_BACKUP_DIR}"
            return 0
        fi
        $sp "sudo cp -a ${HANDOFF_BACKUP_DIR}/. ${HANDOFF_CONF_DIR}/" </dev/null \
            && handoff_nginx_test "$sp" && handoff_nginx_reload "$sp" \
            || { print_error "restore failed — nginx config NOT reloaded"; return 1; }
        print_status "OK" "original vhosts restored on '${server}'"
        return 0
    fi

    [[ "$mode" != "front" || -n "$target_ip" ]] || { echo "ERROR: front requires --to=<server|ip>" >&2; return 2; }

    # Which hostnames? Read what nginx actually serves, then subtract the ones
    # explicitly held back (git/hs and anything whose DNS we do not control).
    local names
    if [[ -n "$only" ]]; then names=$(printf '%s' "$only" | tr ',' '\n')
    else names=$(handoff_server_names "$sp"); fi
    if [[ -n "$exclude" ]]; then
        local pat; pat=$(printf '%s' "$exclude" | tr ',' '|')
        names=$(printf '%s\n' "$names" | grep -vE "^(${pat})$" || true)
    fi
    names=$(printf '%s\n' "$names" | sed '/^$/d')
    [[ -n "$names" ]] || { echo "No hostnames selected." >&2; return 1; }

    # Which names have a certificate on this box? A missing certificate is not
    # a reason to skip the name — that would leave it serving from the old
    # box's database while everything else moved — it just means the rewritten
    # vhost is HTTP-only, as the original was.
    local n; local -A has_cert=()
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        if $sp "sudo test -f /etc/letsencrypt/live/${n}/fullchain.pem" </dev/null; then
            has_cert[$n]=1
        else
            has_cert[$n]=0
        fi
    done <<< "$names"

    print_header "handoff ${mode} on ${server}$( [[ -n "$target_ip" ]] && echo " -> ${target_ip}")$( ((execute)) || echo '  (DRY RUN)')"
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        printf '  %-28s %s\n' "$n" "$( [[ "${has_cert[$n]}" == "1" ]] && echo 'http+https' || echo 'http only (no cert)' )"
    done <<< "$names"
    if (( ! execute )); then
        print_info "DRY RUN — $(printf '%s\n' "$names" | wc -l) hostname(s) would switch to ${mode}."
        return 0
    fi
    impact_reset
    if [[ "$mode" == "drain" ]]; then
        impact_overwrite "${server}: nginx vhosts for $(printf '%s\n' "$names" | wc -l) hostname(s)" \
                         "replaced with a 503 maintenance vhost — these sites STOP SERVING"
        impact_warn "This is user-visible downtime for every hostname listed above."
    else
        impact_overwrite "${server}: nginx vhosts for $(printf '%s\n' "$names" | wc -l) hostname(s)" \
                         "replaced with a proxy to ${target_ip} — traffic leaves this box"
    fi
    impact_keep "The original vhosts, copied to ${HANDOFF_BACKUP_DIR} on the box itself"
    impact_keep "Every hostname NOT listed above (git/hs and anything --exclude'd)"
    impact_keep "All site data on ${server} — this changes routing only, never content"
    impact_render

    if ! impact_confirm standard "switch $(printf '%s\n' "$names" | wc -l) hostname(s) on '${server}' to ${mode}" \
        "$( ((auto_yes)) && echo true || echo false )"; then
        print_info "Aborted."; return 1
    fi

    # Back up the ORIGINAL vhosts exactly once. A second drain/front must not
    # overwrite the backup with already-rewritten files — that would destroy
    # the rollback while appearing to succeed.
    $sp "sudo test -d ${HANDOFF_BACKUP_DIR} || sudo cp -a ${HANDOFF_CONF_DIR} ${HANDOFF_BACKUP_DIR}" </dev/null \
        || { print_error "could not back up the original vhosts — refusing to change anything"; return 1; }

    local tmp; tmp=$(mktemp -d)
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        if [[ "$mode" == "drain" ]]; then handoff_render_drain "$n" "${has_cert[$n]}" > "$tmp/handoff-${n}.conf"
        else handoff_render_front "$n" "$target_ip" "${has_cert[$n]}" > "$tmp/handoff-${n}.conf"; fi
    done <<< "$names"

    # Retire the originals for the selected names, then install the new ones.
    # Done in one remote shell so nginx is reloaded once, at the end.
    local ip user key
    ip=$(get_server_ip "$server"); user=$(get_server_user "$server"); key=$(get_server_ssh_key "$server")
    scp -q -i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
        "$tmp"/handoff-*.conf "${user}@${ip}:/tmp/" || { rm -rf "$tmp"; print_error "upload failed"; return 1; }
    rm -rf "$tmp"

    local retire=""
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        retire+="for f in \$(sudo grep -rlE '^[[:space:]]*server_name([[:space:]]|.*[[:space:]])${n}[[:space:]]*;' ${HANDOFF_CONF_DIR}/*.conf 2>/dev/null | grep -v '/handoff-'); do sudo mv \"\$f\" \"\$f.pre-handoff\"; done; "
    done <<< "$names"

    if ! { $sp "${retire} sudo mv /tmp/handoff-*.conf ${HANDOFF_CONF_DIR}/" </dev/null && handoff_nginx_test "$sp"; }; then
        print_error "nginx config test FAILED on '${server}' — rolling back, nothing reloaded"
        $sp "sudo rm -f ${HANDOFF_CONF_DIR}/handoff-*.conf; for f in ${HANDOFF_CONF_DIR}/*.pre-handoff; do [ -e \"\$f\" ] && sudo mv \"\$f\" \"\${f%.pre-handoff}\"; done" </dev/null || true
        handoff_nginx_test "$sp" || true
        return 1
    fi
    handoff_nginx_reload "$sp" || { print_error "reload failed"; return 1; }
    print_status "OK" "${server}: $(printf '%s\n' "$names" | wc -l) hostname(s) now in ${mode} mode"
    print_info "rollback: pl server handoff restore ${server} --execute"
}

################################################################################
# Subcommand: backup <name> — BOX-LEVEL disaster recovery (NWP-ADR-0025)
#
# THE GAP THIS CLOSES. On 2026-08-01 the estate had, for the box serving every
# live site: per-site logical snapshots (`pl backup <site> --remote`), host
# CONFIG state in git (`pl server-state capture`), and a nightly cron dumping
# databases to /var/backups/nwp-pull. It had NO box-level disaster-recovery
# backup — no files trees, no /etc, no grants, nothing verified, and (because
# met's stick pull still names the pre-split box) nothing leaving the host.
#
# WHAT THIS IS, ARCHITECTURALLY. It is NOT a new backup engine. It is the
# CONTROL-HOST FRONT DOOR to the NWP-ADR-0025 agent: this command never carries the
# data. It preflights headroom, installs/refreshes the AI-free `nwp-server`
# artifact, and invokes `nwp-server backup --host` ON the box, which writes a
# restic repo LOCAL to the box. The custodian (`ver`) later PULLS. Prod holds no
# credential that can delete the durable copy — the NWP-ADR-0025 invariant is
# preserved because the driver is a caller, not a courier.
#
# WHAT IT DELIBERATELY DOES NOT DO. It does not pull the archive to this
# workstation. This workstation is in the dev/AI tier and the archive is raw
# member data; NWP-ADR-0025 §"the two flows must stay separate" makes that a
# threat-model violation, not a convenience trade-off.
################################################################################
SRVBK_AGENT_DIR="/opt/nwp-server"
SRVBK_ETC="/etc/nwp-server"
SRVBK_PASS="/etc/nwp-server/restic.pass"

# _srvbk_repo <server> — the box-scope repo path.
#
# Named for the NWP SERVER RECORD, not `hostname -s`. The live box is a clone of
# the forge box and still answers `git` to `hostname -s`, so the agent's own
# default would put the live estate's disaster-recovery archive in a directory
# called `git-system` — one letter away from the box it is not. Every other verb
# in this file addresses that host as `live`; the archive does too.
_srvbk_repo() { printf '/var/backups/nwp-server/%s-system\n' "$1"; }
_srvbk_tag()  { printf '%s/system\n' "$1"; }

# _srvbk_installed <sp> — 0 if the agent + restic + password file are all present.
_srvbk_installed() {
    local sp="$1"
    $sp "test -x ${SRVBK_AGENT_DIR}/scripts/commands/server-backup.sh && command -v restic >/dev/null && sudo -n test -r ${SRVBK_PASS}" </dev/null 2>/dev/null
}

# _srvbk_install <sp> <server> — idempotent provisioning. Everything it does is
# listed in the rollback rows of docs/guides/box-level-dr-backup.md; --uninstall
# reverses all of it.
_srvbk_install() {
    local sp="$1" server="$2"
    local artifact="${PROJECT_ROOT}/build/out/nwp-server"

    print_header "Install · nwp-server agent on '${server}'"
    print_info "building the AI-free artifact (fail-closed deny-scan)"
    bash "${PROJECT_ROOT}/scripts/build-nwp-server.sh" --out "$artifact" >/dev/null \
        || { print_error "nwp-server artifact build failed — nothing was sent to the box"; return 1; }
    print_status "OK" "artifact built + deny-scan passed"

    # Host-side prerequisites. Written as a heredoc the box executes under sudo:
    # readable in full in any transcript, which a packed one-liner is not.
    local rc=0
    $sp "bash -s" <<'PREP' || rc=$?
set -eu
cat > /tmp/nwp-server-prep.sh <<'NWPPREP'
set -eu
export DEBIAN_FRONTEND=noninteractive
if ! command -v restic >/dev/null 2>&1; then
  # Only refresh the index when the cached one cannot satisfy us. `apt-get
  # update` on a live box with third-party PPAs is not free: the ondrej/php PPA
  # changed its Label and a blind refresh fails the whole install on a repo
  # metadata change that has nothing to do with restic. Never auto-accept a
  # release-info change on a box serving sites — that is an operator decision.
  if ! apt-cache policy restic 2>/dev/null | grep -qE 'Candidate: [0-9]'; then
    apt-get update -qq || { echo "apt-get update failed; not auto-accepting repo changes" >&2; exit 1; }
  fi
  apt-get install -y -qq --no-install-recommends restic
fi
install -d -m 700 /etc/nwp-server
install -d -m 700 /var/backups/nwp-server
if [ ! -f /etc/nwp-server/restic.pass ]; then
  umask 077
  head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n" > /etc/nwp-server/restic.pass
  chmod 600 /etc/nwp-server/restic.pass
  echo "generated /etc/nwp-server/restic.pass"
else
  echo "kept existing /etc/nwp-server/restic.pass"
fi
install -d -m 755 /opt/nwp-server
restic version
NWPPREP
sudo -n bash /tmp/nwp-server-prep.sh
prep_rc=$?
rm -f /tmp/nwp-server-prep.sh
exit $prep_rc
PREP
    [[ $rc -eq 0 ]] || { print_error "host prerequisites failed on '${server}'"; return 1; }
    print_status "OK" "restic + /etc/nwp-server + repo directory present"

    # Ship the artifact. The tar stream goes through the SAME resolved prefix as
    # every other call here, so there is one ssh route to audit, not two.
    if ! tar -C "$artifact" -czf - . | $sp "sudo -n tar -xzf - -C ${SRVBK_AGENT_DIR}"; then
        print_error "artifact push to '${server}' failed"; return 1
    fi
    print_status "OK" "nwp-server artifact → ${server}:${SRVBK_AGENT_DIR}"
    return 0
}

# _srvbk_agent <sp> <args...> — invoke the on-host backup verb.
_srvbk_agent() {
    local sp="$1"; shift
    $sp "sudo -n ${SRVBK_AGENT_DIR}/scripts/commands/server-backup.sh --host $*" </dev/null
}

cmd_backup() {
    local server="" action="plan" arg
    local scope="config,db,web" keep_last=3 min_free=2048 force_disk=0
    local check_subset="5%" sample=12 auto_yes=0 purge_repo=0
    # 04:20 box-local: after the legacy 01:30 nwp-box-backup and clear of the
    # 01:00-03:00 demo-reset window, so two heavy jobs never share the box.
    local cron_expr="20 4 * * *"
    local -a extra=()

    for arg in "$@"; do
        case "$arg" in
            --install)       action="install" ;;
            --execute)       action="execute" ;;
            --status)        action="status" ;;
            --verify)        action="verify" ;;
            --restore-test)  action="restore-test" ;;
            --schedule)      action="schedule" ;;
            --schedule=*)    action="schedule"; cron_expr="${arg#--schedule=}" ;;
            --unschedule)    action="unschedule" ;;
            --uninstall)     action="uninstall" ;;
            --scope=*)       scope="${arg#--scope=}" ;;
            --extra-path=*)  extra+=("${arg#--extra-path=}") ;;
            --keep-last=*)   keep_last="${arg#--keep-last=}" ;;
            --min-free-mb=*) min_free="${arg#--min-free-mb=}" ;;
            --check-subset=*) check_subset="${arg#--check-subset=}" ;;
            --sample=*)      sample="${arg#--sample=}" ;;
            --force-disk)    force_disk=1 ;;
            --purge-repo)    purge_repo=1 ;;
            -y|--yes)        auto_yes=1 ;;
            -*)              echo "Unknown option: $arg" >&2; return 2 ;;
            *)               server="$arg" ;;
        esac
    done
    [[ -n "$server" ]] || { echo "Usage: pl server backup <name> [--install|--execute|--status|--verify|--restore-test|--uninstall]" >&2; return 2; }

    local sp
    sp=$(sync_ssh_prefix "$server") || { echo "ERROR: cannot resolve server '$server'" >&2; return 2; }
    [[ "$($sp 'echo ok' </dev/null 2>/dev/null || true)" == "ok" ]] \
        || { echo "ERROR: '$server' unreachable over ssh." >&2; return 3; }

    # THE PREFLIGHT. Every action here either writes several GB or reads several
    # GB back off disk. `pl server health` exists because a heavy op OOM-killed
    # the 3.8 GB forge box on 2026-07-25; a backup verb that skips it is exactly
    # the shape of op that caused that outage. UNKNOWN is a refusal, not a pass.
    local prefix
    prefix=$(_resolve_probe_prefix "$server") || {
        echo "UNKNOWN: cannot resolve a health probe destination for '$server'" >&2; return 3; }
    # Capture the code BEFORE testing it. `if ! cmd; then return $?; fi` returns
    # the status of the `!`, which is always 0 — the preflight ran, refused, and
    # the verb carried on reporting success. Caught by the bats case
    # "a box with no memory headroom is refused before any work starts".
    local hrc=0
    host_health_require "$prefix" 512 "a box-level backup of '${server}'" || hrc=$?
    [[ $hrc -eq 0 ]] || return "$hrc"

    case "$action" in
      install)
        _srvbk_install "$sp" "$server" || return 1
        print_success "'${server}' is provisioned for box-level DR."
        print_hint "next:  pl server backup ${server}            # dry-run plan"
        print_hint "then:  pl server backup ${server} --execute"
        return 0
        ;;

      plan|execute)
        if ! _srvbk_installed "$sp"; then
            print_error "the nwp-server agent is not installed on '${server}'."
            print_hint "install it:  pl server backup ${server} --install"
            return 1
        fi
        local -a agent_args=(--repo "$(_srvbk_repo "$server")" --tag "$(_srvbk_tag "$server")"
                             --scope "$scope" --keep-last "$keep_last"
                             --min-free-mb "$min_free" --restic-provenance apt)
        local e; for e in ${extra[@]+"${extra[@]}"}; do agent_args+=(--extra-path "$e"); done
        (( force_disk )) && agent_args+=(--force-disk)

        if [[ "$action" == "plan" ]]; then
            print_header "Box-level DR plan · ${server}  (DRY RUN)"
            _srvbk_agent "$sp" "${agent_args[@]}" --dry-run
            echo
            print_info "This was a plan. Add --execute to take the backup."
            return 0
        fi

        # A backup writes; the fate manifest says what it touches even though
        # nothing user-visible is destroyed. `forget --keep-last` DOES delete
        # older staging snapshots, and an operator is entitled to see that
        # before it happens rather than in the output afterwards.
        impact_reset
        impact_archive "${server}: box-level restic snapshot" \
            "scope '${scope}' → $(_srvbk_repo "$server") ON THE BOX (encrypted, raw)"
        impact_delete "${server}: staging snapshots older than the newest ${keep_last}" \
            "restic forget --keep-last ${keep_last} --prune, inside that repo only"
        impact_keep "Every site, database and file on ${server} — this reads, it never modifies"
        impact_keep "The per-site repos under /var/backups/nwp-server/<site> (different repos)"
        impact_warn "The archive lands ON THE HOST IT BACKS UP. Until a pull tier drains it, it does not survive loss of that host."
        impact_render
        if ! impact_confirm standard "take a box-level backup of '${server}'" \
             "$( ((auto_yes)) && echo true || echo false )"; then
            print_info "Aborted."; return 1
        fi
        _srvbk_agent "$sp" "${agent_args[@]}" --execute || return 1
        print_hint "verify it:  pl server backup ${server} --verify && pl server backup ${server} --restore-test"
        return 0
        ;;

      status)
        local repo; repo=$(_srvbk_repo "$server")
        print_header "Box-level DR status · ${server}"
        print_info "repo: ${repo}"
        $sp "sudo -n test -d ${repo}" </dev/null 2>/dev/null || {
            print_warning "no box-level repo on '${server}' yet — run: pl server backup ${server} --install --execute"
            return 1; }
        $sp "sudo -n du -sh ${repo} 2>/dev/null; sudo -n restic -r ${repo} --password-file ${SRVBK_PASS} snapshots --compact" </dev/null
        return $?
        ;;

      verify)
        local repo; repo=$(_srvbk_repo "$server")
        print_header "Verify · ${server} (restic check --read-data-subset=${check_subset})"
        # `restic check` proves the repo's structure and re-reads a sample of the
        # actual pack files. It is the "0" in 3-2-1-1-0 for integrity — but NOT
        # for recoverability. That is what --restore-test is for.
        if $sp "sudo -n restic -r ${repo} --password-file ${SRVBK_PASS} check --read-data-subset=${check_subset}" </dev/null; then
            print_success "repo integrity verified (${check_subset} of pack data re-read)"
            return 0
        fi
        print_error "restic check FAILED on ${server}:${repo} — treat this repo as NOT a backup"
        return 1
        ;;

      restore-test)
        local repo; repo=$(_srvbk_repo "$server")
        print_header "Restore drill · ${server}"
        print_info "A backup that has not been test-restored is not a backup (NWP-ADR-0025)."
        # Restore a random SAMPLE of real files out of the newest box snapshot
        # into a scratch directory, then compare each one byte-for-byte with the
        # file still on disk. Sampling is deliberate: a full 7 GB restore on a
        # 46 GB box every run is how a verification step gets switched off.
        local rc=0
        $sp "sudo -n bash -s" <<RESTORETEST || rc=$?
set -u
REPO='${repo}'; PASS='${SRVBK_PASS}'; N='${sample}'
R() { restic -r "\$REPO" --password-file "\$PASS" "\$@"; }
TMP=\$(mktemp -d /var/tmp/nwp-restore-drill.XXXXXX) || exit 1
trap 'rm -rf "\$TMP"' EXIT

SNAP=\$(R snapshots --tag box --json 2>/dev/null | tr ',' '\n' | grep -o '"short_id":"[^"]*"' | tail -1 | cut -d'"' -f4)
[ -n "\$SNAP" ] || { echo "FAIL: no snapshot tagged 'box' in \$REPO"; exit 1; }
echo "snapshot: \$SNAP"

# Sample regular files from the snapshot's own listing (never from the live
# filesystem — the point is to prove the ARCHIVE holds them).
R ls -l "\$SNAP" 2>/dev/null | awk '\$1 ~ /^-/ && \$NF ~ /^\// {print \$NF}' > "\$TMP/all.txt"
TOTAL=\$(wc -l < "\$TMP/all.txt")
[ "\$TOTAL" -gt 0 ] || { echo "FAIL: snapshot \$SNAP lists no regular files"; exit 1; }

# STRATIFIED sample, not a uniform one. 96% of the files in this archive are
# /var/www/<site>/vendor, so a uniform draw of 8 proves the vendor directories
# restore and proves nothing about /etc, /root, or the moodledata trees — the
# parts a rebuild actually needs. Bucket by the second path component, pick one
# file from each of N randomly chosen distinct buckets, so every drill covers N
# different AREAS of the box and successive drills sweep the rest.
awk -F/ 'NF>=4 {print "/"\$2"/"\$3"\t"\$0; next} {print "/"\$2"\t"\$0}' "\$TMP/all.txt" \
  | sort -R 2>/dev/null | awk -F'\t' '!seen[\$1]++ {print \$2}' | head -n "\$N" > "\$TMP/sample.txt"
[ -s "\$TMP/sample.txt" ] || shuf -n "\$N" "\$TMP/all.txt" > "\$TMP/sample.txt"
echo "files in snapshot: \$TOTAL; sampling \$(wc -l < "\$TMP/sample.txt") from distinct areas"

INC=""
while IFS= read -r f; do INC="\$INC --include \$(printf '%q' "\$f")"; done < "\$TMP/sample.txt"
eval R restore "\$SNAP" --target "\$TMP/out" \$INC >/dev/null 2>&1 || { echo "FAIL: restic restore errored"; exit 1; }

PASSN=0; FAILN=0
while IFS= read -r f; do
  got="\$TMP/out\$f"
  if [ ! -f "\$got" ]; then echo "  MISS  \$f"; FAILN=\$((FAILN+1)); continue; fi
  a=\$(sha256sum "\$got" 2>/dev/null | awk '{print \$1}')
  b=\$(sha256sum "\$f"   2>/dev/null | awk '{print \$1}')
  if [ -z "\$b" ]; then echo "  GONE  \$f (restored ok; no longer on the box to compare)"; PASSN=\$((PASSN+1)); continue; fi
  if [ "\$a" = "\$b" ]; then echo "  OK    \$f"; PASSN=\$((PASSN+1));
  else echo "  DIFF  \$f (archive \$a != live \$b)"; FAILN=\$((FAILN+1)); fi
done < "\$TMP/sample.txt"

# The databases are the half a file-sample can miss entirely. Restore ONE dump
# out of the state snapshot and prove it is a complete mysqldump, not a
# truncated gzip stream that happens to decompress.
SSNAP=\$(R snapshots --tag state --json 2>/dev/null | tr ',' '\n' | grep -o '"short_id":"[^"]*"' | tail -1 | cut -d'"' -f4)
if [ -n "\$SSNAP" ]; then
  DB=\$(R ls -l "\$SSNAP" 2>/dev/null | awk '\$NF ~ /\.sql\.gz\$/ {print \$NF}' | head -1)
  if [ -n "\$DB" ]; then
    R restore "\$SSNAP" --target "\$TMP/state" --include "\$DB" >/dev/null 2>&1
    if gzip -t "\$TMP/state\$DB" 2>/dev/null && zcat "\$TMP/state\$DB" | tail -5 | grep -q 'Dump completed'; then
      echo "  OK    \$(basename "\$DB") — restored, gzip-valid, complete mysqldump"
      PASSN=\$((PASSN+1))
    else
      echo "  BAD   \$(basename "\$DB") — restored dump is truncated or corrupt"
      FAILN=\$((FAILN+1))
    fi
  else
    echo "  WARN  state snapshot holds no .sql.gz to test"
  fi
else
  echo "  WARN  no snapshot tagged 'state' — database coverage NOT proven"
fi

echo "restore drill: \$PASSN passed, \$FAILN failed"
[ "\$FAILN" -eq 0 ]
RESTORETEST
        if [[ $rc -eq 0 ]]; then
            print_success "restore drill PASSED on '${server}' — the archive gives back what it took"
            return 0
        fi
        print_error "restore drill FAILED on '${server}' — this repo has NOT been shown to restore"
        return 1
        ;;

      schedule|unschedule)
        # Delegates to `pl host schedule`, which owns remote cron. The point of
        # putting it behind this verb is that the ENTRY is derived, not typed: a
        # hand-written cron line is where the repo path, the tag, the retention
        # and the provenance flag silently drift away from what the verb does.
        local cron_id="server-backup-${server}"
        local cron_cmd="${SRVBK_AGENT_DIR}/scripts/commands/server-backup.sh --host"
        cron_cmd+=" --repo $(_srvbk_repo "$server") --tag $(_srvbk_tag "$server")"
        cron_cmd+=" --scope ${scope} --keep-last ${keep_last} --min-free-mb ${min_free}"
        cron_cmd+=" --restic-provenance apt --execute"
        cron_cmd+=" >> /var/log/nwp-server-backup.log 2>&1"
        if [[ "$action" == "unschedule" ]]; then
            "${PROJECT_ROOT}/scripts/commands/host.sh" schedule "$server" remove \
                --name="$cron_id" $( ((auto_yes)) && echo --execute )
            return $?
        fi
        if ! _srvbk_installed "$sp"; then
            print_error "refusing to schedule a backup on '${server}': the agent is not installed."
            print_hint "install it first:  pl server backup ${server} --install"
            return 1
        fi
        print_header "Schedule · box-level DR on '${server}'"
        print_info "A scheduled on-box archive protects against deletion, a bad deploy and"
        print_info "corruption. It does NOT protect against loss of the host — nothing does"
        print_info "until a pull tier drains this repo off the box (NWP-ADR-0025)."
        "${PROJECT_ROOT}/scripts/commands/host.sh" schedule "$server" install \
            --name="$cron_id" --schedule="$cron_expr" --command="$cron_cmd" \
            $( ((auto_yes)) && echo --execute )
        return $?
        ;;

      uninstall)
        print_header "Uninstall · nwp-server agent on '${server}'"
        impact_reset
        impact_delete "${server}:${SRVBK_AGENT_DIR}" "the AI-free nwp-server artifact"
        if (( purge_repo )); then
            impact_delete "${server}:/var/backups/nwp-server" "EVERY restic repo on the box, box-level AND per-site"
            impact_delete "${server}:${SRVBK_ETC}" "including restic.pass — WITHOUT IT NO EXISTING SNAPSHOT CAN EVER BE READ"
            impact_warn "Purging the password makes every snapshot in those repos permanently unreadable. There is no recovery."
        else
            impact_keep "/var/backups/nwp-server (the repos) and ${SRVBK_ETC}/restic.pass — pass --purge-repo to remove them too"
        fi
        impact_keep "restic itself (apt package) — remove with: apt-get remove restic"
        impact_keep "Every site, database and file on ${server}"
        impact_render
        local level="standard"; (( purge_repo )) && level="typed"
        if ! impact_confirm "$level" "uninstall the DR agent from '${server}'" \
             "$( ((auto_yes)) && echo true || echo false )"; then
            print_info "Aborted."; return 1
        fi
        $sp "sudo -n rm -rf ${SRVBK_AGENT_DIR}" </dev/null || return 1
        if (( purge_repo )); then
            $sp "sudo -n rm -rf /var/backups/nwp-server ${SRVBK_ETC}" </dev/null || return 1
        fi
        print_success "DR agent removed from '${server}'."
        return 0
        ;;
    esac
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
    vhost)   cmd_vhost "$@" ;;
    host-guard) cmd_host_guard "$@" ;;
    backup)  cmd_backup "$@" ;;
    conf-drift) cmd_conf_drift "$@" ;;
    sites)   cmd_sites "$@" ;;
    sync)    cmd_sync "$@" ;;
    prune)   cmd_prune "$@" ;;
    handoff) cmd_handoff "$@" ;;
    schema)  cmd_schema "$@" ;;
    migrate) cmd_migrate "$@" ;;
    ""|help|--help|-h)
        # Quoted delimiter: this block is documentation, not a template. With a
        # bare EOF a backtick in the help text was executed as a command.
        cat <<'EOF'
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
  vhost <name> <site>   Inspect or REBUILD one site's nginx vhost — the verb
                        `roots` needed when it reported UNREACHABLE-DECLARATION
                        and could only detect (ops#359).
                          --status    (default) is a vhost serving the site's
                                      declared root? which stashed copies exist?
                                      and WHICH CERTIFICATE would 443 fall
                                      through to if none does — the fall-through
                                      that served a wrong cert for twelve days.
                          --restore   rebuild from a stashed copy, repointing
                                      GitLab-bundled includes and adding a
                                      missing ACME challenge location.
                                      DRY-RUN unless --apply; --apply is gated
                                      on `nginx -t` and never overwrites an
                                      existing conf. Prints the rollback.
  backup <name>         BOX-LEVEL disaster recovery (NWP-ADR-0025). Drives the
                        AI-free nwp-server agent ON the box to write an
                        encrypted restic archive of /etc, /usr/local, /root,
                        /opt, every webroot and moodledata, every database, and
                        a generated manifest (packages, enabled units, crontabs,
                        `nginx -T`, replayable MySQL grants). The archive never
                        comes to this workstation: it is raw member data and
                        this is the dev/AI tier. Dry-run unless --execute.
                          --install       provision restic + the agent on the box
                          --execute       take the backup
                          --status        repo size + snapshot list
                          --verify        restic check --read-data-subset
                          --restore-test  restore a sample and byte-compare it
                          --schedule[=CRON] install the nightly on-box cron
                          --unschedule    remove it
                          --uninstall     remove the agent [--purge-repo]
                        [--scope=config,db,web --extra-path=P --keep-last=N
                         --min-free-mb=N --force-disk --check-subset=5%
                         --sample=N -y]
  sites <name>          List sites configured to deploy to this server
  sync <from> <to>      Move every declared site's LIVE DATABASE from one
                        server to another (the box-split primitive; the
                        opposite direction to 'pl backup --remote'). DB names
                        are read from each app's own config on BOTH boxes and
                        never guessed. Dry-run unless --execute.
                        [--sites=a,b --skip-missing --files --execute -y]
  prune <server>        The LAST step of a migration: remove from <server> the
                        webroots, databases, handoff fronts and dead certbot
                        renewals of sites that now live on another box. Refuses
                        unless a recent backup exists, keeps anything still
                        DECLARED to this server, and never drops a database an
                        app on this box still names. Dry-run unless --execute.
                        [--execute -y --require-backup-within=H --no-certs]
  handoff <mode> <srv>  Move traffic between boxes without waiting for DNS.
                        drain = 503 (the only window with downtime, so the DB
                        copy has a still target); front = proxy to the new box
                        so stale-DNS clients still reach the live copy;
                        restore = put the original vhosts back; status.
                        [--to=SERVER|IP --names=a,b --exclude=a,b --execute -y]
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
