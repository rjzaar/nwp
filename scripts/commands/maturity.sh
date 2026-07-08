#!/bin/bash
set -euo pipefail

################################################################################
# pl maturity — per-site code-flow workflow classes (P67 / nwp/ops#48)
#
# The maturity class (incubating|stabilizing|production) records WHO may
# deploy the site's CODE and past what gate, and the deploy commands enforce
# it (lib/canonical.sh: maturity_guard_deploy). The sibling axis is
# `pl canonical` (content flow). Transitions are explicit operator actions:
# ledgered in private/canonical/<site>.log. Graduation is one-way by default
# (08 Part IV): upgrades are routine; downgrades widen the blast radius and
# require the typed-name confirmation tier.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/yaml-write.sh"
source "$PROJECT_ROOT/lib/canonical.sh"
source "$PROJECT_ROOT/lib/impact.sh"

show_help() {
    cat << EOF
${BOLD}pl maturity${NC} — per-site code-flow workflow classes (incubating|stabilizing|production)

${BOLD}USAGE:${NC}
    pl maturity show [site]           Show class(es) + who/when they were set
    pl maturity set <site> <class>    Explicit transition (ledgered; downgrades
                                      need typed-name confirmation)
    pl maturity check <site>          What the guards will enforce for this site
    pl maturity log <site>            Transition ledger (shared with canonical)

${BOLD}CLASSES (who may deploy code, past what gate):${NC}
    incubating   direct 'pl stg2live' allowed (A14 test tier); today's default
    stabilizing  deploys only from a clean checkout of main, fully merged to
                 origin/main; branch/dirty-tree pushes refused
    production   direct SSH/rsync deploys refused — signed-bundle path
                 (ADR-0026) or the ADR-0024 protected runner only

${BOLD}OPTIONS:${NC}
    -y, --yes    Skip confirmation (transitions are still ledgered)
    -h, --help   This help

Default when absent from nwp.yml: incubating. Unparseable values fail closed.
The content-flow sibling is 'pl canonical'; invalid pairs are refused
(incubating+prod-content, production+dev-content). Enforcement points:
stg2live, stg2prod, live2prod.
EOF
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

    print_header "Maturity classes (code flow)"
    printf "  ${BOLD}%-16s %-14s %-8s %-22s %s${NC}\n" "SITE" "MATURITY" "PHASE" "SET BY" "SET AT"
    printf "  %-16s %-14s %-8s %-22s %s\n" "----------------" "--------------" "--------" "----------------------" "------"
    local site class disp phase set_by set_at
    while read -r site; do
        [ -z "$site" ] && continue
        class=$(maturity_get_class "$site" "$config")
        if maturity_class_is_explicit "$site" "$config"; then
            disp="$class"
        elif [[ "$class" == invalid:* ]]; then
            disp="$class"
        else
            disp="(incubating)"
        fi
        phase=$(canonical_get_phase "$site" "$config")
        set_by=$(yaml_get_site_field "$site" "maturity_set_by" "$config" 2>/dev/null || true)
        set_at=$(yaml_get_site_field "$site" "maturity_set_at" "$config" 2>/dev/null || true)
        printf "  %-16s %-14s %-8s %-22s %s\n" "$site" "$disp" "$phase" "${set_by:--}" "${set_at:--}"
    done <<< "$sites"
    echo ""
    print_info "(incubating) = default, not explicitly set. Transition: pl maturity set <site> <class>"
}

# Rank for one-way-graduation detection
_class_rank() {
    case "$1" in
        incubating) echo 0 ;;
        stabilizing) echo 1 ;;
        production) echo 2 ;;
        *) echo 0 ;;
    esac
}

cmd_set() {
    local site="${1:-}"
    local new_class="${2:-}"
    local auto_yes="${3:-false}"
    local config; config=$(canonical_config_file)

    [ -n "$site" ] && [ -n "$new_class" ] || { print_error "Usage: pl maturity set <site> <incubating|stabilizing|production>"; return 1; }
    case "$new_class" in
        incubating|stabilizing|production) ;;
        *) print_error "Invalid class '$new_class' — must be one of: $MATURITY_CLASSES"; return 1 ;;
    esac
    [ -f "$config" ] || { print_error "No nwp.yml found at $config"; return 1; }
    if ! yaml_site_exists "$site" "$config"; then
        print_error "Site '$site' not found in $config"
        return 1
    fi

    local phase; phase=$(canonical_get_phase "$site" "$config")
    if ! maturity_validate_pair "$new_class" "$phase"; then
        print_info "Change the canonical phase first (pl canonical set), or pick a compatible class."
        return 1
    fi

    local cur; cur=$(maturity_get_class "$site" "$config")
    if [ "$cur" = "$new_class" ] && maturity_class_is_explicit "$site" "$config"; then
        print_info "'$site' is already maturity: $new_class — nothing to do."
        return 0
    fi

    print_header "Maturity transition: $site"
    echo -e "  ${BOLD}$cur${NC} → ${BOLD}$new_class${NC}   (canonical: $phase)"
    echo ""
    case "$new_class" in
        incubating)
            print_info "Direct 'pl stg2live' deploys allowed (A14 test tier); agent-loop may work promoted issues."
            ;;
        stabilizing)
            print_info "Deploys now require a clean checkout of main, fully merged to origin/main."
            print_info "Branch or dirty-tree pushes to live will be REFUSED."
            ;;
        production)
            print_info "Direct SSH/rsync deploys will be REFUSED for this site."
            print_info "Code ships via the signed-bundle path (ADR-0026) or the ADR-0024 protected runner."
            ;;
    esac
    echo ""

    local cur_rank new_rank
    cur_rank=$(_class_rank "$cur")
    new_rank=$(_class_rank "$new_class")
    if [ "$new_rank" -lt "$cur_rank" ]; then
        # Downgrade: one-way-by-default graduation (08 Part IV) — widening the
        # blast radius gets the typed-name tier even though nothing is deleted.
        print_warning "This is a DOWNGRADE ($cur → $new_class): it WIDENS who/what may deploy this site."
        impact_confirm typed "$site" "$auto_yes" || { print_info "Aborted — no change."; return 1; }
    elif [ "$auto_yes" != "true" ]; then
        if [ ! -t 0 ]; then
            print_error "No terminal for confirmation and -y not given — aborting."
            return 1
        fi
        read -r -p "Proceed with $site: $cur → $new_class? [y/N] " reply
        case "$reply" in
            y|Y|yes|YES) ;;
            *) print_info "Aborted — no change."; return 1 ;;
        esac
    fi

    local who at
    who=$(canonical_actor)
    at=$(date -u +%FT%TZ)
    yaml_set_site_field "$site" "maturity" "$new_class" "$config" >/dev/null
    yaml_set_site_field "$site" "maturity_set_by" "$who" "$config" >/dev/null
    yaml_set_site_field "$site" "maturity_set_at" "$at" "$config" >/dev/null
    canonical_ledger_append "$site" "action=maturity-set from=$cur to=$new_class"

    print_status "OK" "'$site' is now maturity: $new_class (by $who at $at)"
    print_info "Ledger: $(canonical_ledger_dir)/${site}.log"
    return 0
}

cmd_check() {
    local site="${1:-}"
    [ -n "$site" ] || { print_error "Usage: pl maturity check <site>"; return 1; }
    local config; config=$(canonical_config_file)

    local class phase
    class=$(maturity_get_class "$site" "$config")
    phase=$(canonical_get_phase "$site" "$config")
    print_header "Maturity check: $site"
    if maturity_class_is_explicit "$site" "$config"; then
        echo -e "  ${BOLD}Class:${NC} $class (explicit)    ${BOLD}Canonical:${NC} $phase"
    else
        echo -e "  ${BOLD}Class:${NC} $class (default — not set in nwp.yml)    ${BOLD}Canonical:${NC} $phase"
    fi
    echo ""
    echo -e "  ${BOLD}Code-deploy gate in force:${NC}"
    case "$class" in
        incubating)
            echo "  • direct pl stg2live: ALLOWED (A14 test tier)" ;;
        stabilizing)
            echo "  • deploys only from clean main, fully merged to origin/main"
            if maturity_guard_deploy "$site" "check" >/dev/null 2>&1; then
                print_status "OK" "site dev repo currently satisfies the rule"
            else
                print_warning "site dev repo currently FAILS the rule — a deploy would be refused:"
                maturity_guard_deploy "$site" "check" || true
            fi
            ;;
        production)
            echo "  • direct SSH/rsync deploys: REFUSED — signed-bundle / protected-runner only" ;;
        invalid:*)
            print_error "Unparseable class '${class#invalid:}' — ALL deploys fail closed."
            print_error "Fix: pl maturity set $site <incubating|stabilizing|production>"
            ;;
    esac
    echo ""
    print_info "Content-flow axis: pl canonical check $site"
    return 0
}

cmd_log() {
    local site="${1:-}"
    [ -n "$site" ] || { print_error "Usage: pl maturity log <site>"; return 1; }
    local ledger="$(canonical_ledger_dir)/${site}.log"
    if [ ! -f "$ledger" ]; then
        print_info "No transitions recorded yet for '$site' ($ledger)"
        return 0
    fi
    print_header "Site ledger: $site (canonical + maturity)"
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
