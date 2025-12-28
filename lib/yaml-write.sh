#!/bin/bash
# YAML Writing Library for NWP
# Provides functions to add, remove, update, and read site entries in cnwp.yml
# Uses AWK for reading and sed for writing (no yq dependency)

# Default config file
YAML_CONFIG_FILE="${YAML_CONFIG_FILE:-cnwp.yml}"

# Color output for messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

#######################################
# Backup cnwp.yml before modifications
# Arguments:
#   $1 - Config file path (optional, defaults to YAML_CONFIG_FILE)
# Returns:
#   0 on success, 1 on failure
#######################################
yaml_backup() {
    local config_file="${1:-$YAML_CONFIG_FILE}"
    local backup_file="${config_file}.backup-$(date +%Y%m%d-%H%M%S)"

    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}Error: Config file not found: $config_file${NC}" >&2
        return 1
    fi

    if cp "$config_file" "$backup_file"; then
        echo -e "${GREEN}Backup created: $backup_file${NC}" >&2
        return 0
    else
        echo -e "${RED}Error: Failed to create backup${NC}" >&2
        return 1
    fi
}

#######################################
# Check if a site exists in cnwp.yml
# Arguments:
#   $1 - Site name
#   $2 - Config file path (optional)
# Returns:
#   0 if site exists, 1 if not
#######################################
yaml_site_exists() {
    local site_name="$1"
    local config_file="${2:-$YAML_CONFIG_FILE}"

    if [[ -z "$site_name" ]]; then
        echo -e "${RED}Error: Site name is required${NC}" >&2
        return 1
    fi

    awk -v site="$site_name" '
        BEGIN { found = 0 }
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { found = 1; exit }
        END { exit !found }
    ' "$config_file"
}

#######################################
# Get a field value from a site entry
# Arguments:
#   $1 - Site name
#   $2 - Field name (e.g., "directory", "recipe", "environment")
#   $3 - Config file path (optional)
# Outputs:
#   Field value
# Returns:
#   0 on success, 1 on failure
#######################################
yaml_get_site_field() {
    local site_name="$1"
    local field_name="$2"
    local config_file="${3:-$YAML_CONFIG_FILE}"

    if [[ -z "$site_name" || -z "$field_name" ]]; then
        echo -e "${RED}Error: Site name and field name are required${NC}" >&2
        return 1
    fi

    awk -v site="$site_name" -v field="$field_name" '
        BEGIN { in_site = 0; found = 0 }
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z_]+:/ && !/^    / { in_site = 0 }
        in_site && $0 ~ "^    " field ":" {
            sub("^    " field ": *", "")
            print
            found = 1
            exit
        }
        END { exit !found }
    ' "$config_file"
}

#######################################
# Get list field values from a site entry (e.g., installed_modules)
# Arguments:
#   $1 - Site name
#   $2 - List field name (e.g., "installed_modules")
#   $3 - Config file path (optional)
# Outputs:
#   List values, one per line
# Returns:
#   0 on success, 1 on failure
#######################################
yaml_get_site_list() {
    local site_name="$1"
    local list_name="$2"
    local config_file="${3:-$YAML_CONFIG_FILE}"

    if [[ -z "$site_name" || -z "$list_name" ]]; then
        echo -e "${RED}Error: Site name and list name are required${NC}" >&2
        return 1
    fi

    awk -v site="$site_name" -v list="$list_name" '
        BEGIN { in_site = 0; in_list = 0 }
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z_]+:/ && !/^    / { in_site = 0; in_list = 0 }
        in_site && $0 ~ "^    " list ":" { in_list = 1; next }
        in_list && /^    [a-zA-Z_]+:/ { in_list = 0 }
        in_list && /^      - / {
            sub("^      - ", "")
            print
        }
    ' "$config_file"
}

#######################################
# Add a new site entry to cnwp.yml
# Arguments:
#   $1 - Site name
#   $2 - Directory path
#   $3 - Recipe name
#   $4 - Environment type (development/staging/production)
#   $5 - Config file path (optional)
# Returns:
#   0 on success, 1 on failure
#######################################
yaml_add_site() {
    local site_name="$1"
    local directory="$2"
    local recipe="$3"
    local environment="${4:-development}"
    local config_file="${5:-$YAML_CONFIG_FILE}"

    # Validate required parameters
    if [[ -z "$site_name" || -z "$directory" || -z "$recipe" ]]; then
        echo -e "${RED}Error: Site name, directory, and recipe are required${NC}" >&2
        return 1
    fi

    # Check if site already exists
    if yaml_site_exists "$site_name" "$config_file"; then
        echo -e "${YELLOW}Warning: Site '$site_name' already exists in $config_file${NC}" >&2
        return 1
    fi

    # Create backup
    if ! yaml_backup "$config_file"; then
        return 1
    fi

    # Get ISO 8601 timestamp
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Create site entry
    local site_entry="  $site_name:
    directory: $directory
    recipe: $recipe
    environment: $environment
    created: $timestamp"

    # Add site entry to sites: section
    # Strategy: Find sites: line, then find where to insert (end of section or immediately if empty)
    awk -v site_entry="$site_entry" '
        BEGIN { in_sites = 0; sites_found = 0; entry_added = 0 }

        /^sites:/ {
            sites_found = 1
            in_sites = 1
            print
            next
        }

        # If in sites section and we hit a non-indented line (or comment at root level), end of sites section
        in_sites && /^[a-zA-Z]/ && !/^  / {
            # Add entry before this new section
            if (!entry_added) {
                print site_entry
                entry_added = 1
            }
            in_sites = 0
            print
            next
        }

        # In sites section, print all lines
        in_sites {
            print
            next
        }

        # Not in sites section, just print
        { print }

        # At EOF, if still in sites section, add entry
        END {
            if (in_sites && !entry_added) {
                print site_entry
            }
        }
    ' "$config_file" > "${config_file}.tmp"

    # Move temp file to original
    if mv "${config_file}.tmp" "$config_file"; then
        echo -e "${GREEN}Site '$site_name' added to $config_file${NC}" >&2
        return 0
    else
        echo -e "${RED}Error: Failed to update $config_file${NC}" >&2
        return 1
    fi
}

#######################################
# Remove a site entry from cnwp.yml
# Arguments:
#   $1 - Site name
#   $2 - Config file path (optional)
# Returns:
#   0 on success, 1 on failure
#######################################
yaml_remove_site() {
    local site_name="$1"
    local config_file="${2:-$YAML_CONFIG_FILE}"

    if [[ -z "$site_name" ]]; then
        echo -e "${RED}Error: Site name is required${NC}" >&2
        return 1
    fi

    # Check if site exists
    if ! yaml_site_exists "$site_name" "$config_file"; then
        echo -e "${YELLOW}Warning: Site '$site_name' not found in $config_file${NC}" >&2
        return 1
    fi

    # Create backup
    if ! yaml_backup "$config_file"; then
        return 1
    fi

    # Remove the site entry (the site line and all indented lines below it until next site or section)
    awk -v site="$site_name" '
        BEGIN { in_site = 0; in_sites = 0 }
        /^sites:/ { in_sites = 1; print; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && (/^  [a-zA-Z0-9_-]+:/ || (/^[a-zA-Z]/ && !/^    /)) {
            in_site = 0
        }
        !in_site { print }
    ' "$config_file" > "${config_file}.tmp"

    # Move temp file to original
    if mv "${config_file}.tmp" "$config_file"; then
        echo -e "${GREEN}Site '$site_name' removed from $config_file${NC}" >&2
        return 0
    else
        echo -e "${RED}Error: Failed to update $config_file${NC}" >&2
        return 1
    fi
}

#######################################
# Update a field value in a site entry
# Arguments:
#   $1 - Site name
#   $2 - Field name
#   $3 - New value
#   $4 - Config file path (optional)
# Returns:
#   0 on success, 1 on failure
#######################################
yaml_update_site_field() {
    local site_name="$1"
    local field_name="$2"
    local new_value="$3"
    local config_file="${4:-$YAML_CONFIG_FILE}"

    if [[ -z "$site_name" || -z "$field_name" ]]; then
        echo -e "${RED}Error: Site name and field name are required${NC}" >&2
        return 1
    fi

    # Check if site exists
    if ! yaml_site_exists "$site_name" "$config_file"; then
        echo -e "${RED}Error: Site '$site_name' not found in $config_file${NC}" >&2
        return 1
    fi

    # Create backup
    if ! yaml_backup "$config_file"; then
        return 1
    fi

    # Update the field value
    awk -v site="$site_name" -v field="$field_name" -v value="$new_value" '
        BEGIN { in_site = 0; in_sites = 0; field_updated = 0 }
        /^sites:/ { in_sites = 1; print; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; print; next }
        in_site && (/^  [a-zA-Z0-9_-]+:/ || (/^[a-zA-Z]/ && !/^    /)) {
            in_site = 0
        }
        in_site && $0 ~ "^    " field ":" {
            print "    " field ": " value
            field_updated = 1
            next
        }
        { print }
        END {
            if (!field_updated) {
                print "Warning: Field '" field "' not found in site '" site "'" > "/dev/stderr"
            }
        }
    ' "$config_file" > "${config_file}.tmp"

    # Move temp file to original
    if mv "${config_file}.tmp" "$config_file"; then
        echo -e "${GREEN}Field '$field_name' updated for site '$site_name'${NC}" >&2
        return 0
    else
        echo -e "${RED}Error: Failed to update $config_file${NC}" >&2
        return 1
    fi
}

#######################################
# Add installed modules to a site entry
# Arguments:
#   $1 - Site name
#   $2 - Space-separated list of modules
#   $3 - Config file path (optional)
# Returns:
#   0 on success, 1 on failure
#######################################
yaml_add_site_modules() {
    local site_name="$1"
    local modules="$2"
    local config_file="${3:-$YAML_CONFIG_FILE}"

    if [[ -z "$site_name" || -z "$modules" ]]; then
        echo -e "${RED}Error: Site name and modules are required${NC}" >&2
        return 1
    fi

    # Check if site exists
    if ! yaml_site_exists "$site_name" "$config_file"; then
        echo -e "${RED}Error: Site '$site_name' not found in $config_file${NC}" >&2
        return 1
    fi

    # Create backup
    if ! yaml_backup "$config_file"; then
        return 1
    fi

    # Convert space-separated modules to array
    local module_array=($modules)

    # Create module list entries
    local module_entries=""
    for module in "${module_array[@]}"; do
        module_entries="${module_entries}      - $module\n"
    done

    # Add installed_modules section to site
    awk -v site="$site_name" -v modules="$module_entries" '
        BEGIN { in_site = 0; in_sites = 0; added = 0 }

        /^sites:/ {
            in_sites = 1
            print
            next
        }

        # End of sites section
        in_sites && /^[a-zA-Z]/ && !/^  / && !/^#/ {
            in_sites = 0
        }

        # Found our site
        in_sites && $0 ~ "^  " site ":" {
            in_site = 1
            print
            next
        }

        # In our site, check if we hit the next site or end of sites section
        in_site && (/^  [a-zA-Z0-9_-]+:/ || (/^[a-zA-Z]/ && !/^  / && !/^#/)) {
            # End of our site entry, add modules before next site/section
            if (!added) {
                printf "    installed_modules:\n%s", modules
                added = 1
            }
            in_site = 0
        }

        # Print the line
        { print }

        # At end of file, if still in site, add modules
        END {
            if (in_site && !added) {
                printf "    installed_modules:\n%s", modules
            }
        }
    ' "$config_file" > "${config_file}.tmp"

    # Move temp file to original
    if mv "${config_file}.tmp" "$config_file"; then
        echo -e "${GREEN}Modules added to site '$site_name'${NC}" >&2
        return 0
    else
        echo -e "${RED}Error: Failed to update $config_file${NC}" >&2
        return 1
    fi
}

#######################################
# Add production config to a site entry
# Arguments:
#   $1 - Site name
#   $2 - Method (rsync/git/tar)
#   $3 - Server name (reference to linode.servers)
#   $4 - Remote path
#   $5 - Domain
#   $6 - Config file path (optional)
# Returns:
#   0 on success, 1 on failure
#######################################
yaml_add_site_production() {
    local site_name="$1"
    local method="$2"
    local server="$3"
    local remote_path="$4"
    local domain="$5"
    local config_file="${6:-$YAML_CONFIG_FILE}"

    if [[ -z "$site_name" || -z "$method" ]]; then
        echo -e "${RED}Error: Site name and method are required${NC}" >&2
        return 1
    fi

    # Check if site exists
    if ! yaml_site_exists "$site_name" "$config_file"; then
        echo -e "${RED}Error: Site '$site_name' not found in $config_file${NC}" >&2
        return 1
    fi

    # Create backup
    if ! yaml_backup "$config_file"; then
        return 1
    fi

    # Create production config entries
    local prod_config="    production_config:\n"
    prod_config="${prod_config}      method: $method\n"
    [[ -n "$server" ]] && prod_config="${prod_config}      server: $server\n"
    [[ -n "$remote_path" ]] && prod_config="${prod_config}      remote_path: $remote_path\n"
    [[ -n "$domain" ]] && prod_config="${prod_config}      domain: $domain\n"

    # Add production_config section to site
    awk -v site="$site_name" -v prod_config="$prod_config" '
        BEGIN { in_site = 0; in_sites = 0; added = 0 }

        /^sites:/ {
            in_sites = 1
            print
            next
        }

        # End of sites section
        in_sites && /^[a-zA-Z]/ && !/^  / && !/^#/ {
            in_sites = 0
        }

        # Found our site
        in_sites && $0 ~ "^  " site ":" {
            in_site = 1
            print
            next
        }

        # In our site, check if we hit the next site or end of sites section
        in_site && (/^  [a-zA-Z0-9_-]+:/ || (/^[a-zA-Z]/ && !/^  / && !/^#/)) {
            # End of our site entry, add production config before next site/section
            if (!added) {
                printf "%s", prod_config
                added = 1
            }
            in_site = 0
        }

        # Print the line
        { print }

        # At end of file, if still in site, add production config
        END {
            if (in_site && !added) {
                printf "%s", prod_config
            }
        }
    ' "$config_file" > "${config_file}.tmp"

    # Move temp file to original
    if mv "${config_file}.tmp" "$config_file"; then
        echo -e "${GREEN}Production config added to site '$site_name'${NC}" >&2
        return 0
    else
        echo -e "${RED}Error: Failed to update $config_file${NC}" >&2
        return 1
    fi
}

# Export functions for use in other scripts
export -f yaml_backup
export -f yaml_site_exists
export -f yaml_get_site_field
export -f yaml_get_site_list
export -f yaml_add_site
export -f yaml_remove_site
export -f yaml_update_site_field
export -f yaml_add_site_modules
export -f yaml_add_site_production
