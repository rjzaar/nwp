#!/bin/bash

################################################################################
# NWP CLI Registration Library
#
# Manages CLI command registration for multiple NWP installations.
# Allows multiple NWP instances to coexist with unique command names
# (pl, pl1, pl2, etc.)
#
# Functions:
#   - register_cli_command <project_root>
#   - unregister_cli_command
#   - get_cli_command
################################################################################

# Get the directory where this script is located
SCRIPT_DIR_CLI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT_CLI="$(cd "$SCRIPT_DIR_CLI/.." && pwd)"

# Source required libraries
if [ -f "$PROJECT_ROOT_CLI/lib/ui.sh" ]; then
    source "$PROJECT_ROOT_CLI/lib/ui.sh"
fi

if [ -f "$PROJECT_ROOT_CLI/lib/yaml-write.sh" ]; then
    source "$PROJECT_ROOT_CLI/lib/yaml-write.sh"
fi

#######################################
# Get the current CLI command name from cnwp.yml
# Outputs:
#   CLI command name (default: pl)
# Returns:
#   0 on success
#######################################
get_cli_command() {
    local config_file="${PROJECT_ROOT_CLI}/cnwp.yml"
    local cli_command=""

    # Try to read from cnwp.yml settings.cli_command
    if [ -f "$config_file" ]; then
        cli_command=$(awk '
            /^settings:/ { in_settings = 1; next }
            in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
            in_settings && /^  cli_command:/ {
                sub("^  cli_command: *", "")
                gsub(/["'"'"']/, "")
                print
                exit
            }
        ' "$config_file")
    fi

    # Default to 'pl' if not found
    echo "${cli_command:-pl}"
}

#######################################
# Find the next available CLI command name
# Checks pl, pl1, pl2, etc. and returns the first available
# Arguments:
#   $1 - Project root to check against
# Outputs:
#   Available command name
# Returns:
#   0 on success
#######################################
find_available_cli_name() {
    local project_root="$1"
    local base_name="pl"
    local counter=0
    local test_name="$base_name"

    while true; do
        if [ ! -e "/usr/local/bin/$test_name" ]; then
            # Command doesn't exist, it's available
            echo "$test_name"
            return 0
        fi

        # Check if it's a symlink pointing to this project
        if [ -L "/usr/local/bin/$test_name" ]; then
            local target=$(readlink -f "/usr/local/bin/$test_name")
            local this_pl=$(readlink -f "$project_root/pl")

            if [ "$target" = "$this_pl" ]; then
                # Points to this project, we can use it
                echo "$test_name"
                return 0
            fi
        fi

        # Try next number
        counter=$((counter + 1))
        test_name="${base_name}${counter}"

        # Safety check - don't go too high
        if [ $counter -gt 99 ]; then
            print_error "Could not find available CLI command name (tried up to ${base_name}99)"
            return 1
        fi
    done
}

#######################################
# Register CLI command for this NWP installation
# Creates symlink in /usr/local/bin/ and stores name in cnwp.yml
# Arguments:
#   $1 - Project root directory (optional, defaults to detected root)
#   $2 - Preferred command name (optional, will use this if available)
# Returns:
#   0 on success, 1 on failure
#######################################
register_cli_command() {
    local project_root="${1:-$PROJECT_ROOT_CLI}"
    local preferred_name="${2:-}"
    local config_file="$project_root/cnwp.yml"
    local pl_script="$project_root/pl"

    # Verify project structure
    if [ ! -f "$pl_script" ]; then
        print_error "NWP pl script not found at: $pl_script"
        return 1
    fi

    if [ ! -f "$config_file" ]; then
        print_warning "Config file not found, will create cli_command setting when available"
    fi

    # Check if already registered (but allow switching to a different preferred name)
    local existing_command=$(get_cli_command)
    if [ -n "$existing_command" ] && [ -L "/usr/local/bin/$existing_command" ]; then
        local target=$(readlink -f "/usr/local/bin/$existing_command")
        local this_pl=$(readlink -f "$pl_script")

        if [ "$target" = "$this_pl" ]; then
            # Already registered - check if user wants a different name
            if [ -z "$preferred_name" ] || [ "$preferred_name" = "$existing_command" ]; then
                print_status "OK" "CLI command '$existing_command' already registered"
                return 0
            else
                # User wants to switch to a different name - remove old symlink first
                print_status "INFO" "Switching CLI command from '$existing_command' to '$preferred_name'"
                if sudo rm -f "/usr/local/bin/$existing_command"; then
                    print_status "OK" "Removed old symlink: /usr/local/bin/$existing_command"
                else
                    print_warning "Could not remove old symlink, continuing anyway"
                fi
            fi
        fi
    fi

    # Determine command name: use preferred if available, otherwise find next available
    local cli_command=""
    if [ -n "$preferred_name" ]; then
        # Check if preferred name is available
        if [ ! -e "/usr/local/bin/$preferred_name" ]; then
            cli_command="$preferred_name"
        elif [ -L "/usr/local/bin/$preferred_name" ]; then
            local target=$(readlink -f "/usr/local/bin/$preferred_name")
            local this_pl=$(readlink -f "$pl_script")
            if [ "$target" = "$this_pl" ]; then
                cli_command="$preferred_name"
            else
                print_warning "Preferred name '$preferred_name' is in use by another installation"
                cli_command=$(find_available_cli_name "$project_root")
            fi
        else
            print_warning "Preferred name '$preferred_name' exists but is not a symlink"
            cli_command=$(find_available_cli_name "$project_root")
        fi
    else
        cli_command=$(find_available_cli_name "$project_root")
    fi

    if [ -z "$cli_command" ]; then
        return 1
    fi

    # Check if /usr/local/bin/<command> exists but is not a symlink
    if [ -e "/usr/local/bin/$cli_command" ] && [ ! -L "/usr/local/bin/$cli_command" ]; then
        print_warning "/usr/local/bin/$cli_command exists but is not a symlink"
        print_warning "Please manually remove or rename it before continuing"
        return 1
    fi

    # Create symlink
    print_status "INFO" "Registering CLI command: $cli_command"

    if sudo ln -sf "$pl_script" "/usr/local/bin/$cli_command"; then
        print_status "OK" "Created symlink: /usr/local/bin/$cli_command -> $pl_script"
    else
        print_error "Failed to create symlink (requires sudo)"
        return 1
    fi

    # Update cnwp.yml with cli_command setting
    if [ -f "$config_file" ]; then
        # Check if settings section exists
        if ! grep -q "^settings:" "$config_file"; then
            print_warning "No settings section found in cnwp.yml"
        else
            # Check if cli_command already exists
            if grep -q "^  cli_command:" "$config_file"; then
                # Update existing value
                sed -i "s/^  cli_command:.*/  cli_command: $cli_command/" "$config_file"
                print_status "OK" "Updated cli_command in cnwp.yml"
            else
                # Add cli_command to settings section
                # Insert after settings: line
                awk -v cmd="$cli_command" '
                    /^settings:/ {
                        print
                        print "  # CLI command name for this NWP installation"
                        print "  cli_command: " cmd
                        next
                    }
                    { print }
                ' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
                print_status "OK" "Added cli_command to cnwp.yml"
            fi
        fi
    fi

    print_status "OK" "CLI registration complete. Use '$cli_command' to run NWP commands."

    return 0
}

#######################################
# Unregister CLI command for this NWP installation
# Removes symlink from /usr/local/bin/ and clears cnwp.yml setting
# Returns:
#   0 on success, 1 on failure
#######################################
unregister_cli_command() {
    local config_file="${PROJECT_ROOT_CLI}/cnwp.yml"

    # Get current CLI command name
    local cli_command=$(get_cli_command)

    if [ -z "$cli_command" ]; then
        print_status "INFO" "No CLI command registered"
        return 0
    fi

    # Remove symlink if it exists
    if [ -L "/usr/local/bin/$cli_command" ]; then
        local target=$(readlink -f "/usr/local/bin/$cli_command")
        local this_pl=$(readlink -f "${PROJECT_ROOT_CLI}/pl")

        if [ "$target" = "$this_pl" ]; then
            print_status "INFO" "Removing CLI command: $cli_command"
            if sudo rm -f "/usr/local/bin/$cli_command"; then
                print_status "OK" "Removed symlink: /usr/local/bin/$cli_command"
            else
                print_error "Failed to remove symlink (requires sudo)"
                return 1
            fi
        else
            print_warning "/usr/local/bin/$cli_command points to different NWP installation"
            print_status "INFO" "Skipping symlink removal"
        fi
    else
        print_status "INFO" "CLI command symlink not found"
    fi

    # Clear cli_command from cnwp.yml
    if [ -f "$config_file" ]; then
        if grep -q "^  cli_command:" "$config_file"; then
            # Remove the cli_command line and any comment line immediately before it
            sed -i '/^  # CLI command name for this NWP installation$/,/^  cli_command:/d' "$config_file"
            print_status "OK" "Removed cli_command from cnwp.yml"
        fi
    fi

    return 0
}

# Export functions for use in other scripts
export -f get_cli_command
export -f find_available_cli_name
export -f register_cli_command
export -f unregister_cli_command
