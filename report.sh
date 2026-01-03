#!/bin/bash

################################################################################
# NWP Error Reporter
#
# Generates a pre-filled GitLab issue URL for reporting errors.
# Opens the URL in your browser or copies it to clipboard.
#
# Usage:
#   ./report.sh                     # Interactive mode
#   ./report.sh "Error description" # Quick report
#   ./report.sh --copy "Error"      # Copy URL instead of opening browser
#   ./report.sh --attach-log FILE   # Include log file contents
#
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ui.sh"

# GitLab project URL
GITLAB_URL="https://git.nwpcode.org/root/nwp"

# Gather system information
gather_system_info() {
    local info=""

    # NWP version (git commit)
    local nwp_version
    if git -C "$SCRIPT_DIR" rev-parse --short HEAD &>/dev/null; then
        nwp_version=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD)
        local branch=$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || echo "unknown")
        info+="- **NWP Version:** \`$nwp_version\` (branch: \`$branch\`)\n"
    else
        info+="- **NWP Version:** unknown\n"
    fi

    # OS info
    if [[ -f /etc/os-release ]]; then
        local os_name=$(grep "^PRETTY_NAME=" /etc/os-release | cut -d'"' -f2)
        info+="- **OS:** $os_name\n"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        info+="- **OS:** macOS $(sw_vers -productVersion 2>/dev/null || echo "unknown")\n"
    fi

    # DDEV version
    if command -v ddev &>/dev/null; then
        local ddev_version=$(ddev version --json 2>/dev/null | grep -o '"DDEV version"[^,]*' | cut -d'"' -f4 || ddev --version 2>/dev/null | head -1 || echo "unknown")
        info+="- **DDEV:** $ddev_version\n"
    else
        info+="- **DDEV:** not installed\n"
    fi

    # Docker version
    if command -v docker &>/dev/null; then
        local docker_version=$(docker --version 2>/dev/null | sed 's/Docker version //' | cut -d',' -f1 || echo "unknown")
        info+="- **Docker:** $docker_version\n"
    fi

    # Bash version
    info+="- **Bash:** ${BASH_VERSION}\n"

    echo -e "$info"
}

# Sanitize text to remove sensitive information
sanitize_text() {
    local text="$1"

    # Replace home directory with ~
    text="${text//$HOME/\~}"

    # Remove common sensitive patterns
    # IP addresses (keep localhost patterns)
    text=$(echo "$text" | sed -E 's/[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[IP_REDACTED]/g')

    # Passwords in URLs
    text=$(echo "$text" | sed -E 's/(:[^:@\/]+)@/:[PASS_REDACTED]@/g')

    # API tokens/keys (common patterns)
    text=$(echo "$text" | sed -E 's/([Tt]oken|[Kk]ey|[Ss]ecret)[=:]["'"'"']?[A-Za-z0-9_-]{20,}["'"'"']?/\1=[REDACTED]/g')

    echo "$text"
}

# URL encode a string
url_encode() {
    local string="$1"
    local encoded=""
    local i char

    for ((i = 0; i < ${#string}; i++)); do
        char="${string:i:1}"
        case "$char" in
            [a-zA-Z0-9.~_-]) encoded+="$char" ;;
            ' ') encoded+="%20" ;;
            $'\n') encoded+="%0A" ;;
            *) encoded+=$(printf '%%%02X' "'$char") ;;
        esac
    done

    echo "$encoded"
}

# Get the command that failed (if run from another script)
get_recent_error() {
    # Check if there's a log file from schedule.sh
    local log_dir="/var/log/nwp"
    [[ -d "$log_dir" ]] || log_dir="/tmp/nwp"

    if [[ -d "$log_dir" ]]; then
        local recent_log=$(ls -t "$log_dir"/*.log 2>/dev/null | head -1)
        if [[ -n "$recent_log" ]]; then
            # Get last error lines
            local errors=$(grep -i "error\|fail\|exception" "$recent_log" 2>/dev/null | tail -5)
            if [[ -n "$errors" ]]; then
                echo "Recent log errors from $(basename "$recent_log"):"
                echo "$errors"
            fi
        fi
    fi
}

# Read and format a log file for inclusion in the issue
# Usage: read_log_file "/path/to/log" [max_lines]
read_log_file() {
    local log_path="$1"
    local max_lines="${2:-100}"

    if [[ ! -f "$log_path" ]]; then
        echo "[Log file not found: $log_path]"
        return 1
    fi

    local total_lines=$(wc -l < "$log_path")
    local output=""

    # Add file info header
    output+="File: $(basename "$log_path")\n"
    output+="Size: $(du -h "$log_path" | cut -f1)\n"
    output+="Lines: $total_lines\n"
    output+="---\n"

    if [[ $total_lines -le $max_lines ]]; then
        # Small file - include everything
        output+=$(cat "$log_path")
    else
        # Large file - show last N lines with note
        output+="[Showing last $max_lines of $total_lines lines]\n\n"
        output+=$(tail -n "$max_lines" "$log_path")
    fi

    echo -e "$output"
}

# Find recent NWP log files
find_recent_logs() {
    local log_dirs=("/var/log/nwp" "/tmp/nwp" "$SCRIPT_DIR")
    local found_logs=()

    for dir in "${log_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            while IFS= read -r -d '' log; do
                found_logs+=("$log")
            done < <(find "$dir" -maxdepth 1 -name "*.log" -mmin -60 -print0 2>/dev/null | head -z -n 5)
        fi
    done

    # Return unique sorted by modification time
    printf '%s\n' "${found_logs[@]}" | head -5
}

# Interactive log selection
select_log_file() {
    local logs
    mapfile -t logs < <(find_recent_logs)

    if [[ ${#logs[@]} -eq 0 ]]; then
        return 1
    fi

    echo "Recent log files found:"
    echo ""
    local i=1
    for log in "${logs[@]}"; do
        local age=$(( ($(date +%s) - $(stat -c %Y "$log" 2>/dev/null || stat -f %m "$log" 2>/dev/null)) / 60 ))
        echo "  $i) $(basename "$log") (${age}m ago)"
        ((i++))
    done
    echo "  0) Skip - don't attach log"
    echo ""
    echo -n "Select log to attach [0]: "
    read -r selection

    if [[ -z "$selection" || "$selection" == "0" ]]; then
        return 1
    fi

    if [[ "$selection" =~ ^[0-9]+$ ]] && [[ $selection -ge 1 ]] && [[ $selection -le ${#logs[@]} ]]; then
        echo "${logs[$((selection-1))]}"
        return 0
    fi

    return 1
}

# Main function
main() {
    local copy_mode=false
    local description=""
    local script_name=""
    local labels="bug"
    local log_file=""
    local attach_log=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --copy|-c)
                copy_mode=true
                shift
                ;;
            --script|-s)
                script_name="$2"
                shift 2
                ;;
            --label|-l)
                labels="$2"
                shift 2
                ;;
            --attach-log|-a)
                attach_log=true
                # Check if next arg is a file path (not another flag)
                if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
                    log_file="$2"
                    shift
                fi
                shift
                ;;
            --help|-h)
                echo "Usage: ./report.sh [options] [error description]"
                echo ""
                echo "Options:"
                echo "  --copy, -c           Copy URL to clipboard instead of opening browser"
                echo "  --script, -s NAME    Specify which script had the error"
                echo "  --attach-log, -a [FILE]  Attach log file (prompts if no file specified)"
                echo "  --label, -l LABEL    GitLab label(s) to add (default: bug)"
                echo "  --help, -h           Show this help message"
                echo ""
                echo "Examples:"
                echo "  ./report.sh                              # Interactive mode"
                echo "  ./report.sh \"Database export failed\"     # Quick report"
                echo "  ./report.sh -s backup.sh \"Error msg\"     # Specify script"
                echo "  ./report.sh -a /tmp/nwp/backup.log \"msg\" # Attach specific log"
                echo "  ./report.sh -a \"Error during backup\"     # Select from recent logs"
                echo "  ./report.sh -c \"Error msg\"               # Copy URL to clipboard"
                exit 0
                ;;
            *)
                description="$1"
                shift
                ;;
        esac
    done

    print_header "NWP Error Reporter"

    # Get error description if not provided
    if [[ -z "$description" ]]; then
        echo "Describe the error you encountered:"
        echo "(Press Enter twice when done)"
        echo ""

        local line
        while IFS= read -r line; do
            [[ -z "$line" ]] && break
            description+="$line"$'\n'
        done

        # Remove trailing newline
        description="${description%$'\n'}"
    fi

    if [[ -z "$description" ]]; then
        print_error "No error description provided"
        exit 1
    fi

    # Get script name if not provided
    if [[ -z "$script_name" ]]; then
        echo ""
        echo "Which script were you running? (e.g., install.sh, backup.sh)"
        echo "Press Enter to skip:"
        read -r script_name
    fi

    # Handle log attachment
    local log_content=""
    if $attach_log; then
        if [[ -z "$log_file" ]]; then
            # No file specified, offer to select from recent logs
            echo ""
            local selected_log
            if selected_log=$(select_log_file); then
                log_file="$selected_log"
            fi
        fi

        if [[ -n "$log_file" ]]; then
            print_info "Reading log file: $log_file"
            log_content=$(read_log_file "$log_file" 80)
            log_content=$(sanitize_text "$log_content")
        fi
    fi

    # Sanitize the description
    description=$(sanitize_text "$description")

    # Build issue title
    local title
    if [[ -n "$script_name" ]]; then
        title="Error in ${script_name}: ${description:0:60}"
    else
        title="Error: ${description:0:60}"
    fi
    # Truncate if needed
    [[ ${#title} -gt 100 ]] && title="${title:0:97}..."

    # Gather system info
    print_info "Gathering system information..."
    local system_info=$(gather_system_info)

    # Check for recent errors in logs
    local recent_errors=$(get_recent_error)

    # Build issue body
    local body="## Description

${description}

## Environment

${system_info}
## Steps to Reproduce

1.
2.
3.

## Expected Behavior

<!-- What did you expect to happen? -->

## Actual Behavior

<!-- What actually happened? -->"

    # Add script info if provided
    if [[ -n "$script_name" ]]; then
        body+="

## Script

\`\`\`
$script_name
\`\`\`"
    fi

    # Add attached log content (full log from --attach-log)
    if [[ -n "$log_content" ]]; then
        body+="

## Attached Log

\`\`\`
$log_content
\`\`\`"
    # Add recent log errors if found (fallback when no log attached)
    elif [[ -n "$recent_errors" ]]; then
        recent_errors=$(sanitize_text "$recent_errors")
        body+="

## Recent Log Output

\`\`\`
$recent_errors
\`\`\`"
    fi

    body+="

---
*Reported via \`./report.sh\`*"

    # URL encode parameters
    local encoded_title=$(url_encode "$title")
    local encoded_body=$(url_encode "$body")
    local encoded_labels=$(url_encode "$labels")

    # Build the issue URL
    local issue_url="${GITLAB_URL}/-/issues/new?issue[title]=${encoded_title}&issue[description]=${encoded_body}&issue[label_names][]=${encoded_labels}"

    echo ""
    print_status "OK" "Issue prepared"
    echo ""

    if $copy_mode; then
        # Copy to clipboard
        if command -v xclip &>/dev/null; then
            echo -n "$issue_url" | xclip -selection clipboard
            print_status "OK" "URL copied to clipboard (xclip)"
        elif command -v xsel &>/dev/null; then
            echo -n "$issue_url" | xsel --clipboard --input
            print_status "OK" "URL copied to clipboard (xsel)"
        elif command -v pbcopy &>/dev/null; then
            echo -n "$issue_url" | pbcopy
            print_status "OK" "URL copied to clipboard (pbcopy)"
        elif command -v wl-copy &>/dev/null; then
            echo -n "$issue_url" | wl-copy
            print_status "OK" "URL copied to clipboard (wl-copy)"
        else
            print_warning "No clipboard tool found. URL:"
            echo ""
            echo "$issue_url"
        fi
    else
        # Open in browser
        print_info "Opening browser..."

        if command -v xdg-open &>/dev/null; then
            xdg-open "$issue_url" 2>/dev/null &
        elif command -v open &>/dev/null; then
            open "$issue_url"
        elif command -v wslview &>/dev/null; then
            wslview "$issue_url"
        else
            print_warning "Could not detect browser. URL:"
            echo ""
            echo "$issue_url"
        fi
    fi

    echo ""
    print_info "Review and submit the issue on GitLab"
    print_info "Add any additional context or log output before submitting"
}

main "$@"
