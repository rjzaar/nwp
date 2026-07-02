#!/bin/bash
set -euo pipefail

################################################################################
# pl canonical — site canonicality phases (nwp/ops#33)
#
# A site's canonical phase (dev|live|prod) records WHICH HOST owns its
# content, and the deploy commands enforce the matching content-flow rules
# (see lib/canonical.sh). Transitions are explicit operator actions: this
# verb flips the flag, records who/when in nwp.yml, and appends to the
# append-only ledger private/canonical/<site>.log. Flipping the flag IS the
# lock on the prior source — every guarded command re-reads it.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/yaml-write.sh"
source "$PROJECT_ROOT/lib/canonical.sh"
source "$PROJECT_ROOT/lib/git.sh" 2>/dev/null || true   # get_gitlab_url/token (best-effort protected-main check)

show_help() {
    cat << EOF
${BOLD}pl canonical${NC} — site canonicality phases (dev|live|prod)

${BOLD}USAGE:${NC}
    pl canonical show [site]          Show phase(s) + who/when they were set
    pl canonical set <site> <phase>   Explicit phase transition (records who/when,
                                      locks the prior content source)
    pl canonical check <site>         What the guards will enforce for this site
    pl canonical log <site>           Print the transition/override ledger

${BOLD}PHASES (who owns the content):${NC}
    dev   dev DB is the source of truth; dev→live pushes allowed (overwrite live)
    live  content changes on live ONLY; dev gets sanitized live→dev copies;
          dev→live CONTENT pushes are refused (--code-only deploys still flow)
    prod  prod is the source; live/dev are downstream sanitized copies;
          code work is branch-only with a protected CI-gated main (ADR-0024)

${BOLD}OPTIONS:${NC}
    -y, --yes    Skip the confirmation prompt (transition is still ledgered)
    -h, --help   This help

Default when the field is absent from nwp.yml: dev. Unparseable values make
every guard fail closed. Enforcement points: stg2live, stg2prod, live2prod
(content-push guard), dev2stg (throwaway-content warning + branch policy),
backup/deploy manifests (phase stamp).
EOF
}

# Best-effort: is <branch> protected on the site's GitLab project?
# Prints a status line; never fails the caller (API/token optional).
check_protected_main() {
    local site="$1"
    local branch="${2:-main}"

    if ! command -v get_gitlab_token >/dev/null 2>&1; then
        print_warning "protected-main: lib/git.sh unavailable — verify manually on GitLab."
        return 0
    fi
    local gitlab_url token
    gitlab_url=$(get_gitlab_url 2>/dev/null || true)
    token=$(get_gitlab_token 2>/dev/null || true)
    if [ -z "$gitlab_url" ] || [ -z "$token" ]; then
        print_warning "protected-main: no GitLab URL/token configured — verify manually:"
        print_warning "  GitLab → sites/${site} → Settings → Repository → Protected branches (${branch})."
        return 0
    fi

    local group; group=$(get_gitlab_default_group 2>/dev/null || echo "sites")
    local encoded="${group}%2F${site}"
    local resp
    resp=$(curl -s --max-time 10 --header "PRIVATE-TOKEN: $token" \
        "https://${gitlab_url}/api/v4/projects/${encoded}/protected_branches/${branch}" 2>/dev/null || true)

    if echo "$resp" | grep -q "\"name\":\"${branch}\""; then
        print_status "OK" "protected-main: '${branch}' IS protected on ${group}/${site}"
    elif echo "$resp" | grep -q '404'; then
        print_warning "protected-main: '${branch}' is NOT protected on ${group}/${site} (or project not found)."
        print_warning "canonical: prod expects a protected, CI-gated main — protect it before relying on this phase."
    else
        print_warning "protected-main: could not query GitLab (${gitlab_url}) — verify manually."
    fi
    return 0
}

cmd_show() {
    local one_site="${1:-}"
    local config; config=$(canonical_config_file)
    [ -f "$config" ] || { print_error "No nwp.yml found at $config"; return 1; }

    local sites
    if [ -n "$one_site" ]; then
        sites="$one_site"
    else
        sites=$(yaml_get_all_sites "$config")
    fi
    [ -n "$sites" ] || { print_info "No sites configured"; return 0; }

    print_header "Canonicality phases"
    printf "  ${BOLD}%-16s %-10s %-22s %s${NC}\n" "SITE" "PHASE" "SET BY" "SET AT"
    printf "  %-16s %-10s %-22s %s\n" "----------------" "----------" "----------------------" "------"
    local site phase disp set_by set_at
    while read -r site; do
        [ -z "$site" ] && continue
        phase=$(canonical_get_phase "$site" "$config")
        if canonical_phase_is_explicit "$site" "$config"; then
            disp="$phase"
        elif [[ "$phase" == invalid:* ]]; then
            disp="$phase"
        else
            disp="(dev)"
        fi
        set_by=$(yaml_get_site_field "$site" "canonical_set_by" "$config" 2>/dev/null || true)
        set_at=$(yaml_get_site_field "$site" "canonical_set_at" "$config" 2>/dev/null || true)
        printf "  %-16s %-10s %-22s %s\n" "$site" "$disp" "${set_by:--}" "${set_at:--}"
    done <<< "$sites"
    echo ""
    print_info "(dev) = default, not explicitly set. Transition: pl canonical set <site> <phase>"
}

cmd_set() {
    local site="${1:-}"
    local new_phase="${2:-}"
    local auto_yes="${3:-false}"
    local config; config=$(canonical_config_file)

    [ -n "$site" ] && [ -n "$new_phase" ] || { print_error "Usage: pl canonical set <site> <dev|live|prod>"; return 1; }
    case "$new_phase" in
        dev|live|prod) ;;
        *) print_error "Invalid phase '$new_phase' — must be one of: $CANONICAL_PHASES"; return 1 ;;
    esac
    [ -f "$config" ] || { print_error "No nwp.yml found at $config"; return 1; }
    if ! yaml_site_exists "$site" "$config"; then
        print_error "Site '$site' not found in $config"
        return 1
    fi

    local cur; cur=$(canonical_get_phase "$site" "$config")
    if [ "$cur" = "$new_phase" ] && canonical_phase_is_explicit "$site" "$config"; then
        print_info "'$site' is already canonical: $new_phase — nothing to do."
        return 0
    fi

    print_header "Canonical phase transition: $site"
    echo -e "  ${BOLD}$cur${NC} → ${BOLD}$new_phase${NC}"
    echo ""
    case "$new_phase" in
        live)
            print_info "live becomes the content source of truth:"
            print_info "  • dev/stg content is now LOCKED OUT of live — dev→live content pushes will be REFUSED"
            print_info "  • dev receives sanitized live→dev copies (pl live2stg / pl import)"
            print_info "  • code/config-only deploys still flow: pl stg2live --code-only"
            ;;
        prod)
            print_info "prod becomes the content source of truth:"
            print_info "  • content changes on prod ONLY; live/dev are downstream sanitized copies"
            print_info "  • content pushes toward live AND prod will be REFUSED"
            print_info "  • code work is branch-only; deploys only from a clean, CI-gated main (ADR-0024)"
            ;;
        dev)
            print_warning "dev becomes the content source of truth — the NEXT dev→live push OVERWRITES live content."
            print_warning "Only do this if content on $cur is disposable or has been pulled back to dev."
            ;;
    esac
    # Downgrades hand authority back to a host that may be stale — extra noise.
    case "$cur:$new_phase" in
        live:dev|prod:dev|prod:live)
            echo ""
            print_warning "This is a DOWNGRADE ($cur → $new_phase). Content authored on $cur since the"
            print_warning "last sync to $new_phase will be clobbered by the next push. Make sure it was pulled back."
            ;;
    esac
    echo ""

    if [ "$auto_yes" != "true" ]; then
        read -r -p "Proceed with $site: $cur → $new_phase? [y/N] " reply
        case "$reply" in
            y|Y|yes|YES) ;;
            *) print_info "Aborted — no change."; return 1 ;;
        esac
    fi

    local who at
    who=$(canonical_actor)
    at=$(date -u +%FT%TZ)
    yaml_set_site_field "$site" "canonical" "$new_phase" "$config" >/dev/null
    yaml_set_site_field "$site" "canonical_set_by" "$who" "$config" >/dev/null
    yaml_set_site_field "$site" "canonical_set_at" "$at" "$config" >/dev/null
    canonical_ledger_append "$site" "action=set from=$cur to=$new_phase"

    print_status "OK" "'$site' is now canonical: $new_phase (by $who at $at)"
    print_info "Ledger: $(canonical_ledger_dir)/${site}.log"
    if [ "$new_phase" = "prod" ]; then
        echo ""
        check_protected_main "$site" "main"
    fi
    return 0
}

cmd_check() {
    local site="${1:-}"
    [ -n "$site" ] || { print_error "Usage: pl canonical check <site>"; return 1; }
    local config; config=$(canonical_config_file)

    local phase; phase=$(canonical_get_phase "$site" "$config")
    print_header "Canonicality check: $site"
    if canonical_phase_is_explicit "$site" "$config"; then
        echo -e "  ${BOLD}Phase:${NC} $phase (explicit)"
    else
        echo -e "  ${BOLD}Phase:${NC} $phase (default — not set in nwp.yml)"
    fi
    echo ""
    echo -e "  ${BOLD}Guards in force:${NC}"
    case "$phase" in
        dev)
            echo "  • dev→live content push (stg2live): ALLOWED — dev overwrites live"
            echo "  • live→prod content push:           ALLOWED (cutover/seed path)"
            ;;
        live)
            echo "  • dev→live content push (stg2live): REFUSED (--code-only or --override-canonical to bypass)"
            echo "  • live→prod content push:           ALLOWED (cutover path)"
            echo "  • dev content:                      throwaway — warned on dev2stg"
            ;;
        prod)
            echo "  • dev→live content push (stg2live): REFUSED"
            echo "  • live/stg→prod content push:       REFUSED"
            echo "  • dev content:                      throwaway — warned on dev2stg"
            echo "  • code work:                        branch-only; deploys from clean CI-gated main"
            ;;
        invalid:*)
            print_error "Unparseable phase '${phase#invalid:}' in nwp.yml — ALL content pushes fail closed."
            print_error "Fix: pl canonical set $site <dev|live|prod>"
            ;;
    esac
    if [ "$phase" = "prod" ]; then
        echo ""
        canonical_enforce_branch_policy "$site" "deploy" \
            && print_status "OK" "branch policy: site dev repo is deployable (clean main)"
        check_protected_main "$site" "main"
    fi
    return 0
}

cmd_log() {
    local site="${1:-}"
    [ -n "$site" ] || { print_error "Usage: pl canonical log <site>"; return 1; }
    local ledger="$(canonical_ledger_dir)/${site}.log"
    if [ ! -f "$ledger" ]; then
        print_info "No canonical transitions/overrides recorded yet for '$site' ($ledger)"
        return 0
    fi
    print_header "Canonical ledger: $site"
    cat "$ledger"
}

main() {
    local AUTO_YES=false
    local args=()
    local a
    for a in "$@"; do
        case "$a" in
            -h|--help) show_help; exit 0 ;;
            -y|--yes)  AUTO_YES=true ;;
            *)         args+=("$a") ;;
        esac
    done
    set -- "${args[@]:-}"

    local sub="${1:-show}"
    case "$sub" in
        show)  cmd_show "${2:-}" ;;
        set)   cmd_set "${2:-}" "${3:-}" "$AUTO_YES" ;;
        check) cmd_check "${2:-}" ;;
        log)   cmd_log "${2:-}" ;;
        *)
            # bare `pl canonical <site>` reads naturally as show
            if [ -f "$(canonical_config_file)" ] && yaml_site_exists "$sub" "$(canonical_config_file)" 2>/dev/null; then
                cmd_show "$sub"
            else
                print_error "Unknown subcommand: $sub"
                show_help
                exit 1
            fi
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
