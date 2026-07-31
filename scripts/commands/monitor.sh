#!/bin/bash
set -euo pipefail

################################################################################
# scripts/commands/monitor.sh — `pl monitor` (uptime + mail deliverability)
#
# A launch-gate prerequisite (PHASED-BUILD-PLAN P13 / nwp/ops#71): the
# registration launch is gated on PROVEN mail deliverability — onboarding that
# cannot email approvals fails silently. This command family gives one
# read-only, non-sending "is the fleet up and can it actually send mail?" view
# that a launch script (or `pl rag`) can gate on.
#
#   pl monitor uptime [--tier=live]   Fleet HTTP/TLS reachability (red/amber/green)
#   pl monitor mail <site>            Outbound mail readiness (SPF/DKIM/DMARC/PTR/MX)
#   pl monitor mail <site> --send-test <addr>   OPT-IN live probe (never default)
#   pl monitor --help
#
# HOUSE STYLE (matches drush.sh / rag.sh):
#   * READ-ONLY by default. `uptime` and `mail` only observe (curl/openssl/dig);
#     they never write, never provision, and never print a secret value.
#   * The only action that sends anything is `mail --send-test <addr>`, gated
#     behind the explicit flag and routed through the sanctioned `pl drush`
#     runner (which itself is dry-run-by-default + deploy-gated).
#   * Exit NON-ZERO when any check fails, so a launch script can gate on it.
#
# All external probes (curl / openssl / dig) are invoked as bare commands so a
# test can shadow them on PATH (see tests/unit/test-monitor.bats).
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
# Libs load from the repo; sites/config resolve from PROJECT_ROOT, which
# defaults to the repo but is honoured if pre-set (test isolation).
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"
CONFIG_FILE="${PROJECT_ROOT}/nwp.yml"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/common.sh" 2>/dev/null || true

# Timeouts kept short so a launch-gate run never hangs.
CURL_TIMEOUT="${NWP_MONITOR_CURL_TIMEOUT:-8}"
TLS_TIMEOUT="${NWP_MONITOR_TLS_TIMEOUT:-8}"
# Amber if the cert expires within this many days.
TLS_WARN_DAYS="${NWP_MONITOR_TLS_WARN_DAYS:-14}"

show_help() {
    cat <<EOF
${BOLD}pl monitor${NC} — fleet uptime + mail deliverability (launch gate)

${BOLD}USAGE:${NC}
    pl monitor uptime [--tier=live]
    pl monitor mail <site> [--selector <s>] [--send-test <addr> --execute]
    pl monitor --help

${BOLD}uptime${NC}  — for every configured live domain (nwp.yml), each distinct live
          server_ip, the git origin host (from 'git remote'), and any tailnet
          hosts you list in nwp.yml settings.monitor.tailnet_hosts (or
          \$NWP_MONITOR_TAILNET) that ping-reply: curl the endpoint and report
          HTTP status + TLS days-to-expiry, graded red/amber/green. Read-only.
          Exit 3 if any host is RED.
    --tier=live   Restrict to the live tier (default; only tier supported).

${BOLD}mail <site>${NC} — outbound mail READINESS for the site's live domain, all
          READ-ONLY / NON-SENDING by default. Checks:
            1. SPF     TXT <domain>            (v=spf1 present + has a mechanism)
            2. DKIM    <selector>._domainkey.<domain>  (discoverable selector)
            3. DMARC   TXT _dmarc.<domain>      (v=DMARC1 present)
            4. PTR     reverse DNS of live server_ip (dig -x) resolves
            5. MX / A  mail host + its A record resolve
          Summarises pass/warn/fail with the specific missing record.
    --selector <s>   DKIM selector to probe (default: a common-selector sweep)
    --send-test <addr> --execute   OPT-IN: actually send ONE probe email via the
                     live host's drush (pl drush <site> --tier=live --execute).
                     Never runs by default; requires BOTH flags. Deploy-gated.

${BOLD}GRADES:${NC}
    ${GREEN}●${NC} GREEN  reachable / all mail records present
    ${YELLOW}●${NC} AMBER  soft issue (auth-gated HTTP, cert expiring soon, DKIM/DMARC absent)
    ${RED}●${NC} RED    unreachable / 5xx / expired cert / SPF|PTR|MX missing

Exit non-zero when any check FAILS (so it can gate a launch script / pl rag).
EOF
}

################################################################################
# Shared helpers
################################################################################

# Is a domain a placeholder from the nwp.yml example blocks? (never probe those)
_is_placeholder_domain() {
    case "$1" in
        ""|null|YOUR_*|*.example.com|*.example.org|*example.*) return 0 ;;
        *) return 1 ;;
    esac
}

# Emit "site|domain" for every configured site that has a real live.domain.
#
# The separator is a literal "|", NOT a yq "\t" escape: yq only began expanding
# "\t" to a real tab in v4.45+. Under the v4.44.1 that CI pins, `.key + "\t" +
# .domain` emitted a literal backslash-t, `IFS=$'\t' read` split nothing, and
# every site fell out through the empty-domain placeholder test — so uptime
# monitored ZERO site domains while still exiting 0 and printing a healthy
# table. A plain "|" behaves identically on every yq 4.x, and matches the
# delimiter the rest of this file already uses for target rows. Neither a site
# key nor a DNS name can contain "|".
_monitor_configured_domains() {
    [ -f "$CONFIG_FILE" ] || return 0
    command -v yq >/dev/null 2>&1 || return 0
    yq eval '.sites // {} | to_entries | .[] | select(.value.live.domain) | .key + "|" + .value.live.domain' \
        "$CONFIG_FILE" 2>/dev/null | while IFS='|' read -r site domain; do
        _is_placeholder_domain "$domain" && continue
        printf '%s|%s\n' "$site" "$domain"
    done
}

# Emit "label|host|tailnet" for each configured tailnet host that ping-replies.
# Host names come from nwp.yml settings.monitor.tailnet_hosts (git-ignored, so
# operator infra never lands in source) or the $NWP_MONITOR_TAILNET env var
# (space-separated). Never fatal — a laptop off the tailnet just reports fewer
# hosts, and no hosts are probed at all when nothing is configured.
_monitor_tailnet_hosts() {
    local h
    { printf '%s\n' ${NWP_MONITOR_TAILNET:-}
      [ -f "$CONFIG_FILE" ] && command -v yq >/dev/null 2>&1 && \
        yq eval '.settings.monitor.tailnet_hosts // [] | .[]' "$CONFIG_FILE" 2>/dev/null
    } | awk 'NF' | sort -u | while read -r h; do
        if ping -c1 -W1 "$h" >/dev/null 2>&1; then
            printf '%s|%s|tailnet\n' "$h" "$h"
        fi
    done
}

# The git origin host, derived at runtime from `git remote` (never hardcoded in
# source). Handles git@host:path and scheme://host/path. Emits nothing when
# there is no origin remote.
_monitor_git_host() {
    local url="${NWP_MONITOR_GIT_HOST:-}"
    if [ -z "$url" ]; then
        url=$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)
    fi
    [ -z "$url" ] && return 0
    url="${url#*://}"      # drop any scheme
    url="${url#*@}"        # drop any user@
    printf '%s\n' "${url%%[:/]*}"   # host up to the first : or /
}

# Distinct, non-placeholder live server IPs across all configured sites — probed
# once each as bare-IP endpoints. Resolves each site's server the SAME way the
# deploy path does (.live.server named -> server registry ip, else
# .live.server_ip) so multi-server estates are covered and the IP is never a
# stale nwp.yml literal (H2, multi-server audit 2026-07-31).
_monitor_server_ips() {
    [ -f "$CONFIG_FILE" ] || return 0
    command -v yq >/dev/null 2>&1 || return 0
    yq eval '.sites // {} | keys | .[]' "$CONFIG_FILE" 2>/dev/null | while read -r site; do
        [ -n "$site" ] || continue
        local srv ip
        # Read from CONFIG_FILE (the source monitor is given): a named .live.server
        # resolves through the registry; else the bare .live.server_ip.
        srv=$(site="$site" yq eval '.sites[env(site)].live.server // ""' "$CONFIG_FILE" 2>/dev/null || true)
        if [ -n "$srv" ] && [ "$srv" != "null" ]; then
            ip=$(get_server_ip "$srv" 2>/dev/null || true)
        else
            ip=$(site="$site" yq eval '.sites[env(site)].live.server_ip // ""' "$CONFIG_FILE" 2>/dev/null || true)
        fi
        [ -n "$ip" ] && [ "$ip" != "null" ] || continue
        _is_placeholder_domain "$ip" && continue
        printf '%s\n' "$ip"
    done | sort -u
}

# HTTP status of https://<target>. IP targets skip cert host-verification (-k)
# because there is no SNI hostname to match. Echoes the 3-digit code (000 =
# unreachable/timeout).
_http_status() {
    local target="$1" kind="$2" insecure="" code=""
    [ "$kind" = "ip" ] && insecure="-k"
    # curl -w already emits "000" on a connection failure; capture it and only
    # substitute a default if curl produced nothing at all (never double it).
    code=$(curl -sS $insecure -o /dev/null -w '%{http_code}' \
        --max-time "$CURL_TIMEOUT" "https://${target}" 2>/dev/null) || true
    echo "${code:-000}"
}

# Days until the TLS cert on <host>:443 expires. Echoes an integer, or "" when
# it cannot be determined (no cert / unreachable / IP target we skip).
_tls_days_left() {
    local host="$1"
    local enddate
    enddate=$(echo | openssl s_client -servername "$host" -connect "${host}:443" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)
    [ -z "$enddate" ] && { echo ""; return 0; }
    local exp now
    exp=$(date -d "$enddate" +%s 2>/dev/null) || { echo ""; return 0; }
    now=$(date +%s)
    echo $(( (exp - now) / 86400 ))
}

################################################################################
# uptime
################################################################################

cmd_uptime() {
    local tier="live"
    while [ $# -gt 0 ]; do
        case "$1" in
            --tier=*) tier="${1#*=}" ;;
            --tier)   shift; tier="${1:-}" ;;
            -h|--help) show_help; return 0 ;;
            *) print_error "Unknown option: $1"; return 1 ;;
        esac
        shift
    done
    if [ "$tier" != "live" ]; then
        print_error "Unsupported tier: '$tier' — only --tier=live is supported"
        return 1
    fi

    print_header "Fleet uptime — HTTP + TLS (tier: $tier)"
    printf '  %-2s %-14s %-26s %-8s %s\n' "" "HOST" "TARGET" "HTTP" "TLS"

    local reds=0 ambers=0 greens=0 total=0

    # Build the full target list: configured live domains + each distinct live
    # server_ip + the git origin host + any reachable configured tailnet hosts.
    local -a rows=()
    local line site domain ip gh
    while IFS='|' read -r site domain; do
        # A row missing EITHER field means the emitter broke (as the yq "\t"
        # bug did) — drop it, but never let it masquerade as a real target.
        if [ -z "$site" ] || [ -z "$domain" ]; then continue; fi
        rows+=("${site}|${domain}|domain")
    done < <(_monitor_configured_domains)
    while IFS= read -r ip; do
        [ -n "$ip" ] && rows+=("live|${ip}|ip")
    done < <(_monitor_server_ips)
    gh=$(_monitor_git_host)
    [ -n "$gh" ] && rows+=("git|${gh}|domain")
    while IFS= read -r line; do [ -n "$line" ] && rows+=("$line"); done < <(_monitor_tailnet_hosts)

    if [ "${#rows[@]}" -eq 0 ]; then
        print_warning "No monitor targets found — configure sites.<name>.live.domain in nwp.yml"
        return 0
    fi

    local label target kind
    for line in "${rows[@]}"; do
        IFS='|' read -r label target kind <<<"$line"
        total=$((total+1))

        local http tls_days grade dot http_disp tls_disp
        http=$(_http_status "$target" "$kind")

        # TLS: only meaningful for a named HTTPS host. Bare IPs have no SNI
        # hostname; tailnet boxes are build/AI hosts, not web servers.
        if [ "$kind" = "ip" ]; then
            tls_days=""; tls_disp="(skipped: IP)"
        elif [ "$kind" = "tailnet" ]; then
            tls_days=""; tls_disp="(skipped: tailnet)"
        else
            tls_days=$(_tls_days_left "$target")
            if [ -z "$tls_days" ]; then tls_disp="n/a"
            elif [ "$tls_days" -lt 0 ]; then tls_disp="EXPIRED"
            else tls_disp="${tls_days}d"; fi
        fi

        # Grade. tailnet hosts are only in this list because ping reached them,
        # so reachability = GREEN; they serve no HTTPS, so HTTP 000 is expected
        # and must NOT flag RED (only a 5xx from one would). Web hosts grade on
        # HTTP reachability first, then TLS age.
        grade="GREEN"
        if [ "$kind" = "tailnet" ]; then
            case "$http" in 5*) grade="AMBER" ;; *) grade="GREEN" ;; esac
        else
            case "$http" in
                2*|3*) : ;;
                401|403|404) grade="AMBER" ;;
                000|5*) grade="RED" ;;
                *) grade="AMBER" ;;
            esac
        fi
        if [ -n "$tls_days" ]; then
            if [ "$tls_days" -lt 0 ]; then grade="RED"
            elif [ "$tls_days" -lt "$TLS_WARN_DAYS" ] && [ "$grade" = "GREEN" ]; then grade="AMBER"; fi
        fi
        # Show tailnet reachability rather than the (expected) empty HTTP.
        if [ "$kind" = "tailnet" ] && [ "$http" = "000" ]; then http="up"; fi

        case "$grade" in
            RED)   dot="${RED}●${NC}"; reds=$((reds+1)) ;;
            AMBER) dot="${YELLOW}●${NC}"; ambers=$((ambers+1)) ;;
            GREEN) dot="${GREEN}●${NC}"; greens=$((greens+1)) ;;
        esac
        [ "$http" = "000" ] && http_disp="down" || http_disp="$http"

        printf '  %b %-14s %-26s %-8s %s\n' "$dot" "$label" "$target" "$http_disp" "$tls_disp"
    done

    echo ""
    echo -e "  ${BOLD}Fleet:${NC} ${RED}● ${reds} red${NC}  ${YELLOW}● ${ambers} amber${NC}  ${GREEN}● ${greens} green${NC}   (${total} hosts)"
    if [ "$reds" -gt 0 ]; then return 3; fi
    return 0
}

################################################################################
# mail
################################################################################

# First TXT record for <name> matching a pattern, unquoted. Read-only.
_txt_match() {
    local name="$1" pattern="$2"
    dig +short TXT "$name" 2>/dev/null | tr -d '"' | grep -i "$pattern" | head -1 || true
}

cmd_mail() {
    local site="" selector="" send_test="" execute="false"
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)     show_help; return 0 ;;
            --selector)    shift; selector="${1:-}" ;;
            --selector=*)  selector="${1#*=}" ;;
            --send-test)   shift; send_test="${1:-}" ;;
            --send-test=*) send_test="${1#*=}" ;;
            --execute)     execute="true" ;;
            -*)            print_error "Unknown option: $1"; return 1 ;;
            *)             if [ -z "$site" ]; then site="$1"; else
                               print_error "Unexpected argument: $1"; return 1; fi ;;
        esac
        shift
    done

    if [ -z "$site" ]; then
        print_error "Site name required — pl monitor mail <site>"
        return 1
    fi

    local base domain server_ip srv
    base=$(get_base_name "$site" 2>/dev/null || echo "$site")
    # Domain from nwp.yml; server IP resolved per-site via the registry so a
    # named-server site isn't invisible and the IP is never stale (H2).
    domain=$(site="$base" yq eval '.sites[env(site)].live.domain // ""' "$CONFIG_FILE" 2>/dev/null || true)
    srv=$(site="$base" yq eval '.sites[env(site)].live.server // ""' "$CONFIG_FILE" 2>/dev/null || true)
    if [ -n "$srv" ] && [ "$srv" != "null" ]; then
        server_ip=$(get_server_ip "$srv" 2>/dev/null || true)
    else
        server_ip=$(site="$base" yq eval '.sites[env(site)].live.server_ip // ""' "$CONFIG_FILE" 2>/dev/null || true)
    fi
    [ "$server_ip" = "null" ] && server_ip=""
    if [ -z "$domain" ] || _is_placeholder_domain "$domain"; then
        print_error "No live domain configured for '$base' (sites.$base.live.domain in nwp.yml)"
        return 1
    fi

    # Mail authentication (SPF/DKIM/DMARC) applies to the FROM/send domain, which
    # is frequently the registrable parent, not the site's web subdomain. A site
    # served at app.example.org may send its mail as admin@example.org — checking
    # the subdomain then gives a false "no records" alarm while the parent has full
    # records. Prefer an explicit sites.<base>.live.mail_domain override; otherwise
    # fall back to the web domain.
    local mail_domain
    mail_domain=$(site="$base" yq eval '.sites[env(site)].live.mail_domain // ""' "$CONFIG_FILE" 2>/dev/null || true)
    if [ -n "$mail_domain" ] && ! _is_placeholder_domain "$mail_domain"; then
        domain="$mail_domain"
    fi

    print_header "Mail deliverability — $base ($domain)"

    local fails=0 warns=0

    # 1. SPF — TXT <domain> with v=spf1 and at least one mechanism/qualifier.
    local spf
    spf=$(_txt_match "$domain" "v=spf1")
    if [ -n "$spf" ]; then
        if echo "$spf" | grep -qiE '(\ball\b|[~?+-]all|include:|a:?|mx|ip4:|ip6:)'; then
            print_status "OK" "SPF: present — ${spf}"
        else
            print_status "WARN" "SPF: present but no usable mechanism (${spf})"; warns=$((warns+1))
        fi
    else
        print_status "FAIL" "SPF: MISSING — add a 'v=spf1 ... -all' TXT record on ${domain}"; fails=$((fails+1))
    fi

    # 2. DKIM — a discoverable selector. Sweep common selectors unless one given.
    local dkim="" sel found_sel=""
    local -a selectors
    if [ -n "$selector" ]; then selectors=("$selector")
    else selectors=(default mail google dkim selector1 selector2 s1 s2 k1 mandrill); fi
    for sel in "${selectors[@]}"; do
        dkim=$(_txt_match "${sel}._domainkey.${domain}" "v=DKIM1")
        [ -z "$dkim" ] && dkim=$(_txt_match "${sel}._domainkey.${domain}" "p=")
        if [ -n "$dkim" ]; then found_sel="$sel"; break; fi
    done
    if [ -n "$found_sel" ]; then
        print_status "OK" "DKIM: selector '${found_sel}' published"
    else
        print_status "WARN" "DKIM: no selector discoverable (tried: ${selectors[*]}) — pass --selector <s> if you use a custom one"
        warns=$((warns+1))
    fi

    # 3. DMARC — TXT _dmarc.<domain>.
    local dmarc
    dmarc=$(_txt_match "_dmarc.${domain}" "v=DMARC1")
    if [ -n "$dmarc" ]; then
        print_status "OK" "DMARC: present — ${dmarc}"
    else
        print_status "WARN" "DMARC: MISSING — add 'v=DMARC1; p=none; ...' TXT on _dmarc.${domain}"
        warns=$((warns+1))
    fi

    # 4. PTR / reverse DNS of the live server_ip.
    if [ -n "$server_ip" ] && ! _is_placeholder_domain "$server_ip"; then
        local ptr
        ptr=$(dig -x "$server_ip" +short 2>/dev/null | sed 's/\.$//' | head -1 || true)
        if [ -n "$ptr" ]; then
            print_status "OK" "PTR: ${server_ip} → ${ptr}"
        else
            print_status "FAIL" "PTR: ${server_ip} has NO reverse DNS — receivers will reject/greylist"
            fails=$((fails+1))
        fi
    else
        print_status "WARN" "PTR: no live server_ip configured for '${base}' — cannot check reverse DNS"
        warns=$((warns+1))
    fi

    # 5. MX / mail-host A record. Prefer an MX host; fall back to the domain A.
    local mx mailhost a
    mx=$(dig +short MX "$domain" 2>/dev/null | sort -n | awk '{print $2}' | sed 's/\.$//' | head -1 || true)
    if [ -n "$mx" ]; then
        mailhost="$mx"
        a=$(dig +short A "$mailhost" 2>/dev/null | head -1 || true)
        if [ -n "$a" ]; then
            print_status "OK" "MX: ${mailhost} → A ${a}"
        else
            print_status "FAIL" "MX: ${mailhost} has NO A record"; fails=$((fails+1))
        fi
    else
        a=$(dig +short A "$domain" 2>/dev/null | head -1 || true)
        if [ -n "$a" ]; then
            print_status "WARN" "MX: none for ${domain} — using domain A ${a} (send-only setups OK)"
            warns=$((warns+1))
        else
            print_status "FAIL" "MX: no MX and no A record for ${domain}"; fails=$((fails+1))
        fi
    fi

    # 6. OPT-IN live probe. Requires BOTH --send-test <addr> AND --execute.
    if [ -n "$send_test" ]; then
        _mail_send_test "$base" "$send_test" "$execute" || fails=$((fails+1))
    fi

    echo ""
    if [ "$fails" -gt 0 ]; then
        print_error "Mail readiness: ${fails} FAIL, ${warns} warn — NOT launch-ready"
        return 1
    elif [ "$warns" -gt 0 ]; then
        print_warning "Mail readiness: 0 fail, ${warns} warn — usable; review warnings before launch"
        return 0
    else
        print_success "Mail readiness: all checks passed for ${domain}"
        return 0
    fi
}

# OPT-IN send probe. Never runs unless --execute is also given. Routes through
# the sanctioned `pl drush` runner (deploy-gated, never prints secrets).
_mail_send_test() {
    local base="$1" addr="$2" execute="$3"
    echo ""
    print_header "Mail send-test (OPT-IN) → ${addr}"
    # A minimal, secret-free Drupal mail send via the core mail manager.
    local php='\Drupal::service("plugin.manager.mail")->mail("system","monitor_probe","'"$addr"'",\Drupal::languageManager()->getDefaultLanguage()->getId(),["context"=>["subject"=>"pl monitor probe","message"=>"pl monitor deliverability probe"]],NULL,TRUE);'
    if [ "$execute" != "true" ]; then
        print_warning "send-test is opt-in AND gated — add --execute to actually send."
        print_info "Would run: pl drush ${base} --tier=live --execute -- php:eval '<mail send to ${addr}>'"
        return 0
    fi
    print_info "Sending one probe via pl drush (${base}, live)…"
    "${PROJECT_ROOT}/pl" drush "$base" --tier=live --execute -- php:eval "$php"
}

################################################################################
# Dispatch
################################################################################

main() {
    case "${1:-}" in
        uptime)     shift; cmd_uptime "$@" ;;
        mail)       shift; cmd_mail "$@" ;;
        -h|--help|help|"") show_help ;;
        *) print_error "Unknown monitor command: $1"; show_help; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
