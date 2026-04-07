#!/bin/bash

################################################################################
# NWP Error Reporter
#
# Wrapper script that runs NWP commands and offers to report errors to GitLab.
# Captures command output and generates pre-filled issue URLs.
#
# Usage (wrapper mode):
#   ./report.sh backup.sh mysite          # Run backup.sh, offer to report on failure
#   ./report.sh ./install.sh d mysite     # Run install.sh with args
#   ./report.sh -c backup.sh mysite       # Copy URL instead of opening browser
#
# Usage (direct report mode):
#   ./report.sh --report "Error message"  # Report without running a command
#   ./report.sh --report -a logfile       # Report with log attachment
#
################################################################################

set -uo pipefail
# Note: -e is NOT set so we can capture command failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
source "$PROJECT_ROOT/lib/ui.sh"

# GitLab project URL
GITLAB_URL="https://git.nwpcode.org/root/nwp"

# Temp file for capturing output
OUTPUT_FILE=""

################################################################################
# Utility Functions
################################################################################

# Cleanup temp files on exit
cleanup() {
    [[ -n "$OUTPUT_FILE" && -f "$OUTPUT_FILE" ]] && rm -f "$OUTPUT_FILE"
}
trap cleanup EXIT

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
        local ddev_version=$(ddev --version 2>/dev/null | head -1 | sed 's/ddev version //' || echo "unknown")
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

# Open issue URL in browser or copy to clipboard
open_issue_url() {
    local issue_url="$1"
    local copy_mode="${2:-false}"

    if [[ "$copy_mode" == "true" ]]; then
        # Copy to clipboard
        if command -v xclip &>/dev/null; then
            echo -n "$issue_url" | xclip -selection clipboard
            print_status "OK" "URL copied to clipboard"
        elif command -v xsel &>/dev/null; then
            echo -n "$issue_url" | xsel --clipboard --input
            print_status "OK" "URL copied to clipboard"
        elif command -v pbcopy &>/dev/null; then
            echo -n "$issue_url" | pbcopy
            print_status "OK" "URL copied to clipboard"
        elif command -v wl-copy &>/dev/null; then
            echo -n "$issue_url" | wl-copy
            print_status "OK" "URL copied to clipboard"
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
}

# Build and open GitLab issue
create_issue() {
    local script_name="$1"
    local exit_code="$2"
    local command_output="$3"
    local copy_mode="$4"

    print_info "Gathering system information..."
    local system_info=$(gather_system_info)

    # Sanitize command output
    local sanitized_output=$(sanitize_text "$command_output")

    # Truncate if too long (URL length limits)
    local max_output=3000
    if [[ ${#sanitized_output} -gt $max_output ]]; then
        sanitized_output="[Output truncated - showing last $max_output characters]\n\n...${sanitized_output: -$max_output}"
    fi

    # Build issue title
    local title="Error in ${script_name}: exit code ${exit_code}"

    # Build issue body
    local body="## Description

Command \`${script_name}\` failed with exit code ${exit_code}.

## Environment

${system_info}

## Command Output

\`\`\`
${sanitized_output}
\`\`\`

## Steps to Reproduce

1. Run: \`./report.sh ${script_name} [args]\`
2.
3.

## Additional Context

<!-- Add any additional context about the problem here -->

---
*Reported via \`./report.sh\` wrapper*"

    # URL encode parameters
    local encoded_title=$(url_encode "$title")
    local encoded_body=$(url_encode "$body")
    local encoded_labels=$(url_encode "bug")

    # Build the issue URL
    local issue_url="${GITLAB_URL}/-/issues/new?issue[title]=${encoded_title}&issue[description]=${encoded_body}&issue[label_names][]=${encoded_labels}"

    open_issue_url "$issue_url" "$copy_mode"

    echo ""
    print_info "Review and submit the issue on GitLab"
}

################################################################################
# Show Help
################################################################################

show_help() {
    cat << 'EOF'
NWP Error Reporter - Wrapper for error reporting

USAGE (Wrapper Mode):
    ./report.sh [options] <script> [script arguments...]

    Runs the specified script and offers to report errors to GitLab if it fails.

OPTIONS:
    -c, --copy          Copy issue URL to clipboard instead of opening browser
    -h, --help          Show this help message
    --report            Switch to direct report mode (see below)

EXAMPLES:
    ./report.sh backup.sh mysite              # Run backup, report on failure
    ./report.sh install.sh d mysite           # Run install with args
    ./report.sh -c backup.sh mysite           # Copy URL instead of browser
    ./report.sh ./dev2stg.sh mysite           # Can use ./ prefix

WRAPPER BEHAVIOR:
    When a command fails, you'll be prompted:
        Report this error? [y/N/c]

    y = Yes, open GitLab issue
    N = No, just exit (default)
    c = Continue (don't exit, useful for batch operations)

DIRECT REPORT MODE:
    ./report.sh --report "Error description"
    ./report.sh --report -s backup.sh "Error message"

    Use --report to manually create an issue without running a command.

EOF
    exit 0
}

################################################################################
# Direct Report Mode (manual issue creation)
################################################################################

direct_report() {
    shift  # Remove --report

    local copy_mode=false
    local description=""
    local script_name=""

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
            --help|-h)
                show_help
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

    create_issue "${script_name:-unknown}" "N/A" "$description" "$copy_mode"
}

################################################################################
# Wrapper Mode (run command and catch errors)
################################################################################

wrapper_mode() {
    local copy_mode=false
    local command_args=()

    # Parse our options (before the command)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --copy|-c)
                copy_mode=true
                shift
                ;;
            --help|-h)
                show_help
                ;;
            --report)
                direct_report "$@"
                exit $?
                ;;
            -*)
                # Unknown option - might be for the wrapped command
                command_args+=("$1")
                shift
                ;;
            *)
                # First non-option is the command
                command_args+=("$1")
                shift
                # Rest are command arguments
                command_args+=("$@")
                break
                ;;
        esac
    done

    if [[ ${#command_args[@]} -eq 0 ]]; then
        print_error "No command specified"
        echo ""
        echo "Usage: ./report.sh [options] <script> [arguments...]"
        echo "       ./report.sh --help for more information"
        exit 1
    fi

    # Resolve the command
    local cmd="${command_args[0]}"
    local cmd_display="$cmd"

    # If it's just a script name (no path), look in SCRIPT_DIR and PROJECT_ROOT/sites/
    if [[ ! "$cmd" =~ / ]]; then
        if [[ -x "$SCRIPT_DIR/$cmd" ]]; then
            command_args[0]="$SCRIPT_DIR/$cmd"
            cmd_display="$cmd"
        elif [[ -x "$SCRIPT_DIR/${cmd}.sh" ]]; then
            command_args[0]="$SCRIPT_DIR/${cmd}.sh"
            cmd_display="${cmd}.sh"
        elif [[ -x "$PROJECT_ROOT/sites/$cmd" ]]; then
            command_args[0]="$PROJECT_ROOT/sites/$cmd"
            cmd_display="$cmd"
        elif [[ -x "$PROJECT_ROOT/sites/${cmd}.sh" ]]; then
            command_args[0]="$PROJECT_ROOT/sites/${cmd}.sh"
            cmd_display="${cmd}.sh"
        fi
    fi

    # Check if command exists
    if [[ ! -x "${command_args[0]}" ]]; then
        print_error "Command not found or not executable: ${command_args[0]}"
        exit 1
    fi

    # Display what we're running
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  Running: ${cmd_display} ${command_args[*]:1}${NC}"
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    # Create temp file for output
    OUTPUT_FILE=$(mktemp)

    # Run the command, capturing output while also displaying it
    # Use script or unbuffer if available for proper terminal handling
    local exit_code=0

    if command -v script &>/dev/null && [[ "$(uname)" != "Darwin" ]]; then
        # Linux: use script for proper terminal handling
        # -q = quiet, -e = return child exit code, -c = command
        script -q -e -c "${command_args[*]}" "$OUTPUT_FILE"
        exit_code=$?
    else
        # Fallback: tee to capture output
        "${command_args[@]}" 2>&1 | tee "$OUTPUT_FILE"
        exit_code=${PIPESTATUS[0]}
    fi

    echo ""

    # Check if command succeeded
    if [[ $exit_code -eq 0 ]]; then
        # Success - no need to report
        exit 0
    fi

    # Command failed
    echo -e "${RED}───────────────────────────────────────────────────────────────${NC}"
    echo -e "${RED}${BOLD}Command failed with exit code $exit_code${NC}"
    echo -e "${RED}───────────────────────────────────────────────────────────────${NC}"
    echo ""

    # Only prompt if interactive
    if [[ ! -t 0 ]]; then
        exit $exit_code
    fi

    # Prompt for action
    echo -n "Report this error? [y/N/c] (c=continue): "
    read -r response

    case "$response" in
        [Yy]|[Yy][Ee][Ss])
            echo ""
            local output_content=""
            if [[ -f "$OUTPUT_FILE" ]]; then
                output_content=$(cat "$OUTPUT_FILE")
            fi
            create_issue "$cmd_display ${command_args[*]:1}" "$exit_code" "$output_content" "$copy_mode"
            exit $exit_code
            ;;
        [Cc]|[Cc][Oo][Nn][Tt][Ii][Nn][Uu][Ee])
            echo "Continuing..."
            exit 0  # Exit 0 to allow batch operations to continue
            ;;
        *)
            exit $exit_code
            ;;
    esac
}

################################################################################
# Main
################################################################################

# Only run when executed directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -gt 0 && "$1" == "--report" ]]; then
        direct_report "$@"
    else
        wrapper_mode "$@"
    fi
fi
