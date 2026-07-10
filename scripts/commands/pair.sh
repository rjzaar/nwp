#!/bin/bash
set -euo pipefail
################################################################################
# scripts/commands/pair.sh — paired-site contract surface (ADR-0031 / ops#75)
#
# Read-only inspection + manual state management for the pair contract that
# lib/pair.sh (pair_guard) consumes. This command NEVER touches a live site.
#
#   pl pair list                      list configured pairs (from nwp.yml)
#   pl pair show <consumer>           print the resolved pair contract
#   pl pair status <consumer>         both sides' recorded versions vs contract
#   pl pair check <site> <tier> [--code-only]
#                                     dry-run the guard decision for a site/tier
#   pl pair record <consumer> <side> <tier> <cv>
#                                     manually record a deployed contract_version
#                                     (side = provider|consumer) — for bootstrap
#   pl pair rag <consumer> <tier> <green|amber|red>
#                                     manually set the pair RAG (testing/recovery)
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

source "$PROJECT_ROOT/lib/ui.sh"
[ -f "$PROJECT_ROOT/lib/common.sh" ] && source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/pair.sh"

show_help() {
    cat <<EOF
${BOLD}NWP Pair — paired-site contract surface (ADR-0031 / ops#75)${NC}

${BOLD}USAGE:${NC}
    pl pair <subcommand> [args]

${BOLD}SUBCOMMANDS:${NC}
    list                              List configured pairs (nwp.yml paired_with)
    show <consumer>                   Print the resolved pair contract
    status <consumer>                 Both sides' recorded versions vs the contract
    check <site> <tier> [--code-only] Dry-run pair_guard's decision (no deploy)
    record <consumer> <side> <tier> <cv>
                                      Record a deployed contract_version
                                      (side = provider|consumer)
    rag <consumer> <tier> <value>     Set the pair RAG (green|amber|red)

${BOLD}NOTES:${NC}
    * All subcommands are read-only w.r.t. sites; 'record'/'rag' only write the
      local private/pairs/ state that pair_guard reads.
    * A pair id is the CONSUMER site name (e.g. ssc, ssd).
EOF
}

cmd_list() {
    local config; config="$(pair_config_file)"
    if [ ! -f "$config" ]; then print_warning "No nwp.yml at $config"; return 0; fi
    print_header "Configured pairs"
    local found=0
    if command -v yq >/dev/null 2>&1; then
        while IFS=$'\t' read -r cons prov; do
            [ -z "$cons" ] && continue
            printf '  %-12s (consumer)  ↔  %-12s (provider)\n' "$cons" "$prov"
            found=1
        done < <(yq e -r '.sites | to_entries | .[] | select(.value.paired_with != null) | [.key, .value.paired_with] | @tsv' "$config" 2>/dev/null)
    fi
    [ "$found" -eq 0 ] && print_info "No sites declare 'paired_with:' in $config."
}

cmd_show() {
    local consumer="${1:?consumer required}"
    local contract; contract="$(pair_contract_file "$consumer")"
    if ! pair_contract_valid "$contract"; then
        print_error "No valid pair contract for '$consumer' at: $contract"
        return 1
    fi
    print_header "Pair contract: $consumer"
    echo "  file: $contract"
    echo ""
    cat "$contract"
}

cmd_status() {
    local consumer="${1:?consumer required}"
    local contract; contract="$(pair_contract_file "$consumer")"
    if ! pair_contract_valid "$contract"; then
        print_error "No valid pair contract for '$consumer' at: $contract"
        print_info  "Author it from pair-contract.example.yml (docs/guides/ops75-pair-contract-schema.md)."
        return 1
    fi
    local provider cv
    provider="$(pair_contract_get "$contract" '.provider')"
    cv="$(pair_contract_get "$contract" '.contract_version')"

    print_header "Pair status: ${consumer} ↔ ${provider}  (contract v${cv})"
    printf '  %-10s %-10s %-10s %-8s\n' "tier" "provider" "consumer" "RAG"
    printf '  %-10s %-10s %-10s %-8s\n' "----" "--------" "--------" "---"
    local tier pcv ccv rag
    for tier in dev stg live prod; do
        pcv="$(pair_state_get "$consumer" provider "$tier")"; [ -z "$pcv" ] && pcv="-"
        ccv="$(pair_state_get "$consumer" consumer "$tier")"; [ -z "$ccv" ] && ccv="-"
        rag="$(pair_rag_get "$consumer" "$tier")"
        printf '  %-10s v%-9s v%-9s %-8s\n' "$tier" "$pcv" "$ccv" "$rag"
    done
    echo ""
    print_info "Contract version = $cv. 'provider'/'consumer' columns = last recorded deployed contract_version per tier."
    print_info "A consumer promotion is refused while its provider column is behind (or '-') for that tier (ADR-0031 D5)."
}

cmd_check() {
    local site="${1:?site required}" tier="${2:?tier required}"; shift 2 || true
    local code_only=false
    for a in "$@"; do [ "$a" = "--code-only" ] && code_only=true; done
    print_header "pair_guard dry-run: site=$site tier=$tier code_only=$code_only"
    if pair_guard "$site" "$tier" "pair-check" "$code_only" "false"; then
        print_status "OK" "pair_guard would ALLOW this promotion."
    else
        print_status "FAIL" "pair_guard would REFUSE this promotion (see above)."
        return 1
    fi
}

cmd_record() {
    local consumer="${1:?consumer required}" side="${2:?side required}" tier="${3:?tier required}" cv="${4:?cv required}"
    case "$side" in provider|consumer) ;; *) print_error "side must be provider|consumer"; return 1 ;; esac
    pair_guard_record "$consumer" "$side" "$tier" "$cv"
    print_status "OK" "Recorded ${consumer} ${side}@${tier} = contract_version ${cv}"
}

cmd_rag() {
    local consumer="${1:?consumer required}" tier="${2:?tier required}" value="${3:?value required}"
    case "$value" in green|amber|red) ;; *) print_error "value must be green|amber|red"; return 1 ;; esac
    pair_rag_set "$consumer" "$tier" "$value"
    print_status "OK" "Set RAG ${consumer}@${tier} = ${value}"
}

main() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        -h|--help|"") show_help ;;
        list)   cmd_list "$@" ;;
        show)   cmd_show "$@" ;;
        status) cmd_status "$@" ;;
        check)  cmd_check "$@" ;;
        record) cmd_record "$@" ;;
        rag)    cmd_rag "$@" ;;
        *) print_error "Unknown subcommand: $sub"; show_help; exit 1 ;;
    esac
}

main "$@"
