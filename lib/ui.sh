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
    DIM=$'\033[2m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    NC=''
    BOLD=''
    DIM=''
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
#
# NWP provides TWO output styles for different use cases:
#
# 1. TEXT-PREFIX STYLE (print_error, print_warning, print_info)
#    - Best for: Logging, CLI output, scripts that pipe to log files
#    - Format: "ERROR: message", "WARNING: message", "INFO: message"
#    - Features: Uses BOLD text, proper stderr redirection
#    - Example: print_error "Database connection failed"
#
# 2. ICON STYLE (fail, warn, info, pass)
#    - Best for: TUI applications, modern terminal output, interactive scripts
#    - Format: "[✗] message", "[!] message", "[ℹ] message", "[✓] message"
#    - Features: Clean visual indicators, compact output
#    - Example: fail "Database connection failed"
#
# Both styles are available and can be used based on your needs.
################################################################################

# Icon-style functions (modern terminal output with Unicode symbols)
# These use color with fallbacks to work even if colors aren't defined

# fail - Red error messages with X icon
# Usage: fail "Could not connect to database"
fail() {
    echo -e "${RED:-\033[0;31m}[✗]${NC:-\033[0m} $1" >&2
}

# warn - Yellow warning messages with exclamation icon
# Usage: warn "Low disk space"
warn() {
    echo -e "${YELLOW:-\033[1;33m}[!]${NC:-\033[0m} $1"
}

# info - Blue information messages with info icon
# Usage: info "Starting deployment"
info() {
    echo -e "${BLUE:-\033[0;34m}[ℹ]${NC:-\033[0m} $1"
}

# pass - Green success messages with checkmark icon
# Usage: pass "Configuration exported"
pass() {
    echo -e "${GREEN:-\033[0;32m}[✓]${NC:-\033[0m} $1"
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

################################################################################
# Export all functions for use in other scripts
################################################################################

# Text-prefix style functions
export -f print_header
export -f print_status
export -f print_error
export -f print_info
export -f print_warning
export -f show_elapsed_time

# Icon-style functions
export -f fail
export -f warn
export -f info
export -f pass

# Vortex-style helper functions
export -f task
export -f note
export -f step
