#!/bin/bash

################################################################################
# NWP UI Library
#
# Shared UI functions for consistent output across all NWP scripts
# Source this file: source "$SCRIPT_DIR/lib/ui.sh"
################################################################################

# Colors for output
# Only use colors if outputting to a terminal
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    NC=$'\033[0m'
    BOLD=$'\033[1m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    NC=''
    BOLD=''
fi

# Print a header banner
print_header() {
    echo -e "\n${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
}

# Print a status message with icon
# Usage: print_status "OK|WARN|FAIL|INFO" "message"
print_status() {
    local status=$1
    local message=$2

    if [ "$status" == "OK" ]; then
        echo -e "[${GREEN}✓${NC}] $message"
    elif [ "$status" == "WARN" ]; then
        echo -e "[${YELLOW}!${NC}] $message"
    elif [ "$status" == "FAIL" ]; then
        echo -e "[${RED}✗${NC}] $message"
    else
        echo -e "[${BLUE}i${NC}] $message"
    fi
}

# Print an error message to stderr
print_error() {
    echo -e "${RED}${BOLD}ERROR:${NC} $1" >&2
}

# Print an info message
print_info() {
    echo -e "${BLUE}${BOLD}INFO:${NC} $1"
}

# Print a warning message
print_warning() {
    echo -e "${YELLOW}${BOLD}WARNING:${NC} $1"
}

# Display elapsed time since START_TIME
# Requires START_TIME to be set before calling
show_elapsed_time() {
    local label="${1:-Operation}"
    local end_time=$(date +%s)
    local elapsed=$((end_time - ${START_TIME:-$end_time}))
    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))
    local seconds=$((elapsed % 60))

    echo ""
    print_status "OK" "$label completed in $(printf "%02d:%02d:%02d" $hours $minutes $seconds)"
}

# Offer to report an error to GitLab
# Usage: offer_error_report "Error message" [script_name] [log_file]
# Returns: 0 if user chose to report (report.sh was launched), 1 otherwise
#
# Example in a script:
#   ddev export-db --file="$temp_db" || {
#       print_error "Failed to export database"
#       offer_error_report "Database export failed" "backup.sh"
#       exit 1
#   }
offer_error_report() {
    local error_message="${1:-An error occurred}"
    local script_name="${2:-}"
    local log_file="${3:-}"

    # Only prompt if running interactively
    if [[ ! -t 0 ]]; then
        return 1
    fi

    # Skip if NWP_NO_REPORT is set (for automated/test environments)
    if [[ "${NWP_NO_REPORT:-}" == "true" ]]; then
        return 1
    fi

    echo ""
    echo -e "${YELLOW}Would you like to report this error to the NWP project?${NC}"
    echo -n "Report issue? [y/N]: "
    read -r response

    case "$response" in
        [Yy]|[Yy][Ee][Ss])
            # Find report.sh relative to this library
            local report_script
            local lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            report_script="$(dirname "$lib_dir")/report.sh"

            if [[ ! -x "$report_script" ]]; then
                print_warning "report.sh not found or not executable"
                return 1
            fi

            # Build arguments
            local args=()
            [[ -n "$script_name" ]] && args+=(-s "$script_name")
            [[ -n "$log_file" ]] && args+=(--attach-log "$log_file")
            args+=("$error_message")

            # Run report script
            "$report_script" "${args[@]}"
            return 0
            ;;
        *)
            echo "Skipping error report."
            return 1
            ;;
    esac
}
