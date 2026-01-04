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

################################################################################
# Vortex-Style Output Functions (for standardized output across all scripts)
################################################################################

# Info - Blue section headers
# Usage: info "Starting deployment"
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Pass - Green success messages
# Usage: pass "Configuration exported"
pass() {
    echo -e "${GREEN}[ OK ]${NC} $1"
}

# Fail - Red error messages
# Usage: fail "Could not connect to database"
fail() {
    echo -e "${RED}[FAIL]${NC} $1"
}

# Warn - Yellow warning messages
# Usage: warn "Low disk space"
warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Task - Step indicator for sub-operations
# Usage: task "Exporting configuration..."
task() {
    echo -e "  > $1"
}

# Note - Additional details or hints
# Usage: note "Hint: Check disk space"
note() {
    echo -e "    $1"
}

# Progress indicator with step count
# Usage: step 3 10 "Running database updates"
step() {
    local current=$1
    local total=$2
    local message=$3
    local pct=$((current * 100 / total))
    echo -e "${CYAN}[${current}/${total}]${NC} ${BOLD}${message}${NC} (${pct}%)"
}
