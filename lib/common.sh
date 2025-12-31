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

################################################################################
# Configuration Reading Functions
################################################################################

# Get secret value from .secrets.yml with fallback
# Usage: get_secret "section.key" "default_value"
# Example: get_secret "moodle.admin_password" "Admin123!"
get_secret() {
    local path="$1"
    local default="$2"
    local secrets_file="${SCRIPT_DIR}/.secrets.yml"

    if [ ! -f "$secrets_file" ]; then
        echo "$default"
        return
    fi

    # Parse section.key format
    local section="${path%%.*}"
    local key="${path#*.}"

    local value=$(awk -v section="$section" -v key="$key" '
        $0 ~ "^" section ":" { in_section = 1; next }
        in_section && /^[a-zA-Z]/ && !/^  / { in_section = 0 }
        in_section && $0 ~ "^  " key ":" {
            sub("^  " key ": *", "")
            gsub(/["'"'"']/, "")
            # Remove inline comments
            sub(/ *#.*$/, "")
            # Trim whitespace
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
    ' "$secrets_file")

    if [ -n "$value" ] && [ "$value" != "" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# Get nested secret value from .secrets.yml (for deeper nesting like gitlab.server.ip)
# Usage: get_secret_nested "section.subsection.key" "default_value"
get_secret_nested() {
    local path="$1"
    local default="$2"
    local secrets_file="${SCRIPT_DIR}/.secrets.yml"

    if [ ! -f "$secrets_file" ]; then
        echo "$default"
        return
    fi

    # Count depth
    local depth=$(echo "$path" | tr -cd '.' | wc -c)

    if [ "$depth" -eq 1 ]; then
        # Simple section.key
        get_secret "$path" "$default"
        return
    fi

    # For section.subsection.key format
    local section="${path%%.*}"
    local rest="${path#*.}"
    local subsection="${rest%%.*}"
    local key="${rest#*.}"

    local value=$(awk -v section="$section" -v subsection="$subsection" -v key="$key" '
        $0 ~ "^" section ":" { in_section = 1; next }
        in_section && /^[a-zA-Z]/ && !/^  / { in_section = 0 }
        in_section && $0 ~ "^  " subsection ":" { in_subsection = 1; next }
        in_subsection && /^  [a-zA-Z]/ && !/^    / { in_subsection = 0 }
        in_subsection && $0 ~ "^    " key ":" {
            sub("^    " key ": *", "")
            gsub(/["'"'"']/, "")
            sub(/ *#.*$/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
    ' "$secrets_file")

    if [ -n "$value" ] && [ "$value" != "" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# Get setting value from cnwp.yml with fallback
# Usage: get_setting "section.key" "default_value"
# Example: get_setting "php_settings.memory_limit" "512M"
get_setting() {
    local path="$1"
    local default="$2"
    local config_file="${SCRIPT_DIR}/cnwp.yml"

    if [ ! -f "$config_file" ]; then
        echo "$default"
        return
    fi

    # Parse section.key format
    local section="${path%%.*}"
    local key="${path#*.}"

    # Special handling for settings section
    if [ "$section" == "settings" ] || [ "$section" == "$key" ]; then
        # Direct settings lookup
        local value=$(awk -v key="$key" '
            /^settings:/ { in_settings = 1; next }
            in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
            in_settings && $0 ~ "^  " key ":" {
                sub("^  " key ": *", "")
                gsub(/["'"'"']/, "")
                sub(/ *#.*$/, "")
                gsub(/^[ \t]+|[ \t]+$/, "")
                print
                exit
            }
        ' "$config_file")
    else
        # Nested settings lookup (e.g., php_settings.memory_limit)
        local value=$(awk -v section="$section" -v key="$key" '
            /^settings:/ { in_settings = 1; next }
            in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
            in_settings && $0 ~ "^  " section ":" { in_section = 1; next }
            in_section && /^  [a-zA-Z]/ && !/^    / { in_section = 0 }
            in_section && $0 ~ "^    " key ":" {
                sub("^    " key ": *", "")
                gsub(/["'"'"']/, "")
                sub(/ *#.*$/, "")
                gsub(/^[ \t]+|[ \t]+$/, "")
                print
                exit
            }
        ' "$config_file")
    fi

    if [ -n "$value" ] && [ "$value" != "" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# Export functions for use in subshells
export -f get_secret
export -f get_secret_nested
export -f get_setting
