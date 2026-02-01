#!/bin/bash
# fix.sh - AI-assisted issue fixing
# Part of NWP (Narrow Way Project)
#
# Usage: pl fix [issue_id]
#   Lists open issues and helps fix them one by one

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/verify-issues.sh"

show_help() {
    cat << 'EOF'
Usage: pl fix [issue_id]

AI-assisted issue fixing workflow.

Without arguments, shows a list of open issues to work through.
With an issue ID, shows details for that specific issue.

Options:
  -h, --help       Show this help
  --list           List all open issues
  --resolve ID     Mark an issue as fixed
  --reopen ID      Reopen a resolved issue

Examples:
  pl fix                          # Interactive issue picker
  pl fix NWP-20260201-143052      # View specific issue
  pl fix --resolve NWP-20260201-143052   # Mark as fixed
  pl fix --list                   # List all open issues
EOF
}

cmd_interactive() {
    local issues_dir="${PROJECT_ROOT}/.logs/issues"

    if [[ ! -d "$issues_dir" ]] || [[ -z "$(ls -A "$issues_dir" 2>/dev/null)" ]]; then
        print_success "No open issues found!"
        return 0
    fi

    echo ""
    print_info "Open Issues"
    echo ""

    local i=1
    local issue_ids=()

    for issue_file in "$issues_dir"/*.yml; do
        [[ ! -f "$issue_file" ]] && continue

        local status
        status=$(awk '/^status:/{print $2}' "$issue_file")
        [[ "$status" != "open" ]] && continue

        local id cmd item
        id=$(awk '/^id:/{print $2}' "$issue_file")
        cmd=$(awk '/^command:/{print $2}' "$issue_file")
        item=$(awk '/^verification_item:/{$1=""; print substr($0,2)}' "$issue_file")

        printf "  [%d] %-25s %-12s %s\n" "$i" "$id" "$cmd" "$item"
        issue_ids+=("$id")
        ((i++))
    done

    if [[ ${#issue_ids[@]} -eq 0 ]]; then
        print_success "No open issues!"
        return 0
    fi

    echo ""
    echo "  [Enter] View & Fix   [q] Quit"
    echo ""
    read -p "Select issue number: " -r selection

    if [[ "$selection" == "q" ]]; then
        return 0
    fi

    if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le ${#issue_ids[@]} ]]; then
        local selected_id="${issue_ids[$((selection-1))]}"
        echo ""
        show_issue "$selected_id"
        echo ""
        print_info "Review the issue above and implement a fix."
        print_hint "When done: pl fix --resolve ${selected_id}"
    fi
}

main() {
    case "${1:-}" in
        -h|--help)
            show_help
            ;;
        --list)
            list_issues "open"
            ;;
        --resolve)
            resolve_issue "${2:-}" "fixed" "${3:-}"
            ;;
        --reopen)
            resolve_issue "${2:-}" "open"
            ;;
        NWP-*)
            show_issue "$1"
            ;;
        "")
            cmd_interactive
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
