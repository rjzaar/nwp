#!/bin/bash

################################################################################
# NWP UI Library
#
# Shared UI functions for consistent output across all NWP scripts
# Source this file: source "$SCRIPT_DIR/lib/ui.sh"
################################################################################

# Colors for output (only set if not already defined)
: "${RED:=\033[0;31m}"
: "${GREEN:=\033[0;32m}"
: "${YELLOW:=\033[1;33m}"
: "${BLUE:=\033[0;34m}"
: "${CYAN:=\033[0;36m}"
: "${NC:=\033[0m}"
: "${BOLD:=\033[1m}"

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
