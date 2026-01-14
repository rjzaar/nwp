#!/bin/bash

################################################################################
# NWP UI Library
#
# Shared UI functions for consistent output across all NWP scripts
# Source this file: source "$SCRIPT_DIR/lib/ui.sh"
################################################################################

# Determine if color output should be used
# Respects NO_COLOR standard (https://no-color.org/)
# Returns 0 (true) if colors should be used, 1 (false) otherwise
should_use_color() {
    # NO_COLOR standard - if set (any value), disable color
    if [ -n "${NO_COLOR:-}" ]; then
        return 1
    fi
    # Also disable if not a terminal
    if [ ! -t 1 ]; then
        return 1
    fi
    return 0
}

# Colors for output
# Only use colors if outputting to a terminal and NO_COLOR is not set
if should_use_color; then
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

# Print a success message
print_success() {
    echo -e "${GREEN}${BOLD}SUCCESS:${NC} $1"
}

# Print a hint message
print_hint() {
    echo -e "${CYAN}${BOLD}HINT:${NC} $1"
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
# Progress Indicator Functions
################################################################################

# Simple spinner for background operations
# Usage: start_spinner "Installing Drupal..."
#        do_something
#        stop_spinner
start_spinner() {
    local msg="${1:-Working...}"
    # Only show spinner if we have a terminal
    [ ! -t 1 ] && return
    (
        local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local i=0
        while true; do
            printf "\r%s %s" "${spin:i++%${#spin}:1}" "$msg"
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
}

stop_spinner() {
    [ -n "${SPINNER_PID:-}" ] && kill "$SPINNER_PID" 2>/dev/null
    printf "\r\033[K"  # Clear line
    unset SPINNER_PID
}

# Step indicator for multi-step operations
# Usage: show_step 1 5 "Installing dependencies"
show_step() {
    local current=$1
    local total=$2
    local message=$3
    printf "[%d/%d] %s\n" "$current" "$total" "$message"
}

# Progress bar for known-length operations
# Usage: show_progress 45 100 "Downloading"
show_progress() {
    local current=$1
    local total=$2
    local message="${3:-Progress}"
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))
    printf "\r%s [%-50s] %d%%" "$message" "$(printf '#%.0s' $(seq 1 $filled 2>/dev/null))" "$percent"
}

# Complete a progress bar
finish_progress() {
    printf "\n"
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
export -f print_success
export -f print_hint
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

# Progress indicator functions
export -f start_spinner
export -f stop_spinner
export -f show_step
export -f show_progress
export -f finish_progress
