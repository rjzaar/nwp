#!/bin/bash
# lib/verify-issues.sh - Bug report and issue management
# Part of NWP (Narrow Way Project)

if [[ "${_VERIFY_ISSUES_LOADED:-}" == "1" ]]; then
    return 0
fi
_VERIFY_ISSUES_LOADED=1

ISSUES_DIR="${PROJECT_ROOT:-.}/.logs/issues"

# Create a bug report from a failed verification
# Usage: create_bug_report <command_name> <item_text>
create_bug_report() {
    local cmd_name="$1"
    local item_text="$2"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local issue_id="NWP-${timestamp}"

    mkdir -p "$ISSUES_DIR"

    # Collect diagnostics
    local report_file="${ISSUES_DIR}/${issue_id}.yml"

    cat > "$report_file" << EOF
# NWP Issue Report
id: ${issue_id}
status: open
created: $(date -Iseconds)
reporter: $(whoami)
command: ${cmd_name}
verification_item: "${item_text}"

environment:
  os: $(uname -s) $(uname -r)
  bash: ${BASH_VERSION}
  nwp_version: ${NWP_VERSION:-unknown}
  ddev: $(ddev version 2>/dev/null | head -1 || echo "not installed")
  docker: $(docker --version 2>/dev/null || echo "not installed")

description: |
  # What happened?
  (To be filled by reporter)

  # What was expected?
  (To be filled by reporter)

  # Steps to reproduce:
  1. Run: pl ${cmd_name}
  2. Observe the issue

diagnostics:
  git_branch: $(git -C "${PROJECT_ROOT:-.}" branch --show-current 2>/dev/null || echo "unknown")
  git_commit: $(git -C "${PROJECT_ROOT:-.}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  git_dirty: $(git -C "${PROJECT_ROOT:-.}" diff --quiet 2>/dev/null && echo "no" || echo "yes")
EOF

    # Open in editor for description
    local editor
    editor="${EDITOR:-nano}"

    print_info "Bug report created: ${issue_id}"
    print_info "File: ${report_file}"
    echo ""
    read -p "Edit report now? [Y/n] " -n 1 -r edit_response
    echo ""

    if [[ "${edit_response,,}" != "n" ]]; then
        $editor "$report_file"
    fi

    print_success "Issue ${issue_id} saved to ${report_file}"
}

# List all issues
# Usage: list_issues [--status open|fixed|all]
list_issues() {
    local status_filter="${1:-open}"

    if [[ ! -d "$ISSUES_DIR" ]]; then
        print_info "No issues found"
        return
    fi

    local count=0

    printf "%-25s %-10s %-12s %-10s %s\n" "Issue ID" "Status" "Reporter" "Command" "Description"
    printf "%-25s %-10s %-12s %-10s %s\n" "--------" "------" "--------" "-------" "-----------"

    for issue_file in "$ISSUES_DIR"/*.yml; do
        [[ ! -f "$issue_file" ]] && continue

        local id status reporter cmd
        id=$(awk '/^id:/{print $2}' "$issue_file")
        status=$(awk '/^status:/{print $2}' "$issue_file")
        reporter=$(awk '/^reporter:/{print $2}' "$issue_file")
        cmd=$(awk '/^command:/{print $2}' "$issue_file")

        if [[ "$status_filter" == "all" || "$status" == "$status_filter" ]]; then
            printf "%-25s %-10s %-12s %-10s\n" "$id" "$status" "$reporter" "$cmd"
            ((count++))
        fi
    done

    echo ""
    print_info "${count} issue(s) found"
}

# Show a specific issue
# Usage: show_issue <issue_id>
show_issue() {
    local issue_id="$1"
    local issue_file="${ISSUES_DIR}/${issue_id}.yml"

    if [[ ! -f "$issue_file" ]]; then
        print_error "Issue not found: ${issue_id}"
        return 1
    fi

    cat "$issue_file"
}

# Update issue status
# Usage: resolve_issue <issue_id> <new_status> [fix_commit]
resolve_issue() {
    local issue_id="$1"
    local new_status="$2"
    local fix_commit="${3:-}"
    local issue_file="${ISSUES_DIR}/${issue_id}.yml"

    if [[ ! -f "$issue_file" ]]; then
        print_error "Issue not found: ${issue_id}"
        return 1
    fi

    # Update status
    sed -i "s/^status: .*/status: ${new_status}/" "$issue_file"

    # Add resolution info
    echo "" >> "$issue_file"
    echo "resolution:" >> "$issue_file"
    echo "  resolved_at: $(date -Iseconds)" >> "$issue_file"
    echo "  resolved_by: $(whoami)" >> "$issue_file"
    [[ -n "$fix_commit" ]] && echo "  fix_commit: ${fix_commit}" >> "$issue_file"

    print_success "Issue ${issue_id} marked as ${new_status}"
}
