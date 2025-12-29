#!/bin/bash

################################################################################
# NWP Common Library
#
# Shared utility functions for all NWP scripts
# Source this file: source "$SCRIPT_DIR/lib/common.sh"
#
# Note: This library requires lib/ui.sh to be sourced first for print_error
################################################################################

# Debug message - only prints when DEBUG=true
# Usage: debug_msg "message"
debug_msg() {
    local message=$1
    if [ "$DEBUG" == "true" ]; then
        echo -e "${CYAN:-\033[0;36m}[DEBUG]${NC:-\033[0m} $message"
    fi
}

# Alias for backwards compatibility
ocmsg() {
    debug_msg "$@"
}

# Validate site name to prevent dangerous operations
# Returns 0 if valid, 1 if invalid
# Usage: validate_sitename "name" ["context"]
validate_sitename() {
    local name="$1"
    local context="${2:-site name}"

    # Check for empty name
    if [ -z "$name" ]; then
        print_error "Empty $context provided"
        return 1
    fi

    # Check for absolute paths
    if [[ "$name" == /* ]]; then
        print_error "Absolute paths not allowed for $context: $name"
        return 1
    fi

    # Check for path traversal
    if [[ "$name" == *".."* ]]; then
        print_error "Path traversal not allowed in $context: $name"
        return 1
    fi

    # Check for dangerous patterns (just dots, slashes only, etc.)
    if [[ "$name" =~ ^[./]+$ ]]; then
        print_error "Invalid $context: $name"
        return 1
    fi

    # Only allow safe characters: alphanumeric, hyphen, underscore, dot
    if [[ ! "$name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        print_error "Invalid characters in $context: $name (only alphanumeric, hyphen, underscore, dot allowed)"
        return 1
    fi

    return 0
}

# Ask a yes/no question
# Usage: ask_yes_no "question" "default" (y or n)
# Returns 0 for yes, 1 for no
ask_yes_no() {
    local question=$1
    local default=${2:-n}
    local response

    if [ "$default" == "y" ]; then
        read -p "$question [Y/n]: " response
        response=${response:-y}
    else
        read -p "$question [y/N]: " response
        response=${response:-n}
    fi

    case "$response" in
        [yY]|[yY][eE][sS])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
