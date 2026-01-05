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
# Validate a site name for safe use in YAML operations
# Arguments:
#   $1 - Site name to validate
# Returns:
#   0 if valid, 1 if invalid
#######################################
yaml_validate_sitename() {
    local name="$1"

    # Check if empty
    if [[ -z "$name" ]]; then
        echo -e "${RED}Error: Site name cannot be empty${NC}" >&2
        return 1
    fi

    # Check length (reasonable limit)
    if [[ ${#name} -gt 64 ]]; then
        echo -e "${RED}Error: Site name too long (max 64 characters)${NC}" >&2
        return 1
    fi

    # Check for path traversal
    if [[ "$name" == *".."* ]] || [[ "$name" == *"/"* ]]; then
        echo -e "${RED}Error: Site name cannot contain path components${NC}" >&2
        return 1
    fi

    # Check for valid characters (alphanumeric, underscore, hyphen)
    if [[ ! "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        echo -e "${RED}Error: Site name must start with a letter and contain only alphanumeric, underscore, or hyphen${NC}" >&2
        return 1
    fi

    # Check for YAML special characters that could cause injection
    if [[ "$name" == *":"* ]] || [[ "$name" == *"#"* ]] || [[ "$name" == *"["* ]] || [[ "$name" == *"]"* ]]; then
        echo -e "${RED}Error: Site name contains invalid YAML characters${NC}" >&2
        return 1
    fi

    return 0
}

#######################################
# Validate YAML file structure
# Arguments:
#   $1 - Config file path (optional, defaults to YAML_CONFIG_FILE)
# Returns:
#   0 if valid, 1 if invalid
#######################################
yaml_validate() {
    local config_file="${1:-$YAML_CONFIG_FILE}"

    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}Error: Config file not found: $config_file${NC}" >&2
        return 1
    fi

    # Try yq first if available (most robust)
    if command -v yq &>/dev/null; then
        if yq eval '.' "$config_file" >/dev/null 2>&1; then
            return 0
        else
            echo -e "${RED}Error: Invalid YAML syntax in $config_file${NC}" >&2
            return 1
        fi
    fi

    # Fall back to basic structural validation with awk
    local validation_result
    validation_result=$(awk '
        BEGIN {
            errors = 0
            prev_indent = 0
            line_num = 0
        }

        # Skip empty lines and comments
        /^[[:space:]]*$/ || /^[[:space:]]*#/ { line_num++; next }

        {
            line_num++

            # Calculate indentation (number of leading spaces)
            match($0, /^[[:space:]]*/)
            indent = RLENGTH

            # Check for tabs (YAML should use spaces)
            if (/^\t/) {
                print "Line " line_num ": Tabs not allowed (use spaces)"
                errors++
                next
            }

            # Check indentation is multiple of 2
            if (indent > 0 && indent % 2 != 0) {
                print "Line " line_num ": Inconsistent indentation (should be multiple of 2)"
                errors++
            }

            # Check for lines that look malformed
            # A key should have format: key: or key: value
            if (/^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*[^:]*$/ && !/^[[:space:]]*-/) {
                # Line with alphanumeric content but no colon - could be malformed
                # Skip if it is a list item
                if (!/^[[:space:]]*-/) {
                    # Only warn if it does not look like a continuation
                    # This is a weak check - just looking for obvious issues
                }
            }

            prev_indent = indent
        }

        END {
            if (errors > 0) {
                exit 1
            }
        }
    ' "$config_file" 2>&1)

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Error: YAML validation failed:${NC}" >&2
        echo "$validation_result" >&2
        return 1
    fi

    return 0
}

#######################################
# Validate YAML and restore from backup if invalid
# Arguments:
#   $1 - Config file path
#   $2 - Backup file path
# Returns:
#   0 if valid (or restored), 1 if restore also failed
#######################################
yaml_validate_or_restore() {
    local config_file="$1"
    local backup_file="$2"

    if yaml_validate "$config_file"; then
        return 0
    fi

    echo -e "${YELLOW}Warning: YAML validation failed, restoring from backup${NC}" >&2

    if [[ -f "$backup_file" ]] && cp "$backup_file" "$config_file"; then
        echo -e "${GREEN}Restored from backup: $backup_file${NC}" >&2
        return 0
    else
        echo -e "${RED}Error: Failed to restore from backup${NC}" >&2
        return 1
    fi
}

#######################################
# Backup cnwp.yml before modifications
# Arguments:
#   $1 - Config file path (optional, defaults to YAML_CONFIG_FILE)
# Returns:
#   0 on success, 1 on failure
#######################################
yaml_backup() {
    local config_file="${1:-$YAML_CONFIG_FILE}"
    local config_dir=$(dirname "$config_file")
    local config_name=$(basename "$config_file")
    local backup_dir="${config_dir}/.backups"
    local backup_file="${backup_dir}/${config_name}.backup-$(date +%Y%m%d-%H%M%S)"
    local max_backups=10

    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}Error: Config file not found: $config_file${NC}" >&2
        return 1
    fi

    # Ensure backup directory exists
    mkdir -p "$backup_dir"

    if cp "$config_file" "$backup_file"; then
        echo -e "${GREEN}Backup created: $backup_file${NC}" >&2

        # Retention: keep only the last N backups
        local backup_count=$(ls -1 "${backup_dir}/${config_name}.backup-"* 2>/dev/null | wc -l)
        if [[ $backup_count -gt $max_backups ]]; then
            ls -1t "${backup_dir}/${config_name}.backup-"* 2>/dev/null | tail -n +$((max_backups + 1)) | xargs rm -f
            echo -e "${DIM}Cleaned up old backups (keeping last $max_backups)${NC}" >&2
        fi
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
# Validate a purpose value
# Arguments:
#   $1 - Purpose value to validate
# Returns:
#   0 if valid, 1 if invalid
#######################################
yaml_validate_purpose() {
    local purpose="$1"
    case "$purpose" in
        testing|indefinite|permanent|migration)
            return 0
            ;;
        *)
            echo -e "${RED}Error: Invalid purpose '$purpose'. Must be: testing, indefinite, permanent, or migration${NC}" >&2
            return 1
            ;;
    esac
}

#######################################
# Add a new site entry to cnwp.yml
# Arguments:
#   $1 - Site name
#   $2 - Directory path
#   $3 - Recipe name
#   $4 - Environment type (development/staging/production)
#   $5 - Purpose (testing/indefinite/permanent/migration)
#   $6 - Config file path (optional)
# Returns:
#   0 on success, 1 on failure
#######################################
yaml_add_site() {
    local site_name="$1"
    local directory="$2"
    local recipe="$3"
    local environment="${4:-development}"
    local purpose="${5:-indefinite}"
    local config_file="${6:-$YAML_CONFIG_FILE}"

    # Validate required parameters
    if [[ -z "$site_name" || -z "$directory" || -z "$recipe" ]]; then
        echo -e "${RED}Error: Site name, directory, and recipe are required${NC}" >&2
        return 1
    fi

    # Validate site name for safe YAML operations
    if ! yaml_validate_sitename "$site_name"; then
        return 1
    fi

    # Validate purpose
    if ! yaml_validate_purpose "$purpose"; then
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
    purpose: $purpose
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

    # Validate site name for safe YAML operations
    if ! yaml_validate_sitename "$site_name"; then
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

    # Validate site name for safe YAML operations
    if ! yaml_validate_sitename "$site_name"; then
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

    # Validate site name for safe YAML operations
    if ! yaml_validate_sitename "$site_name"; then
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

    # Validate site name for safe YAML operations
    if ! yaml_validate_sitename "$site_name"; then
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

#######################################
# Add/update live server configuration to a site entry
# Checks existing values and only adds missing ones
# Arguments:
#   $1 - Site name
#   $2 - Domain
#   $3 - Server IP
#   $4 - Linode ID (or "shared")
#   $5 - Server type (dedicated/shared)
#   $6 - Config file path (optional)
# Returns:
#   0 on success, 1 on failure
#######################################
yaml_add_site_live() {
    local site_name="$1"
    local new_domain="$2"
    local new_server_ip="$3"
    local new_linode_id="$4"
    local new_server_type="$5"
    local config_file="${6:-$YAML_CONFIG_FILE}"

    if [[ -z "$site_name" ]]; then
        echo -e "${RED}Error: Site name is required${NC}" >&2
        return 1
    fi

    # Validate site name for safe YAML operations
    if ! yaml_validate_sitename "$site_name"; then
        return 1
    fi

    # Check if site exists
    if ! yaml_site_exists "$site_name" "$config_file"; then
        echo -e "${RED}Error: Site '$site_name' not found in $config_file${NC}" >&2
        return 1
    fi

    # Read existing live values from config
    local existing_values=$(awk -v site="$site_name" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
        in_site && /^    live:/ { in_live = 1; next }
        in_live && /^    [a-zA-Z]/ && !/^      / { in_live = 0 }
        in_live && /^      [a-zA-Z_]+:/ {
            key = $0
            sub(/^      /, "", key)
            sub(/:.*/, "", key)
            val = $0
            sub(/^[^:]+: */, "", val)
            gsub(/["'"'"']/, "", val)
            print key "=" val
        }
    ' "$config_file")

    # Parse existing values
    local existing_enabled="" existing_domain="" existing_server_ip="" existing_linode_id="" existing_type=""
    while IFS='=' read -r key val; do
        case "$key" in
            enabled) existing_enabled="$val" ;;
            domain) existing_domain="$val" ;;
            server_ip) existing_server_ip="$val" ;;
            linode_id) existing_linode_id="$val" ;;
            type) existing_type="$val" ;;
        esac
    done <<< "$existing_values"

    # Merge: new values override, but keep existing if new is empty
    local final_enabled="${existing_enabled:-true}"
    local final_domain="${new_domain:-$existing_domain}"
    local final_server_ip="${new_server_ip:-$existing_server_ip}"
    local final_linode_id="${new_linode_id:-$existing_linode_id}"
    local final_type="${new_server_type:-$existing_type}"

    # Check if anything changed
    if [[ "$final_enabled" == "$existing_enabled" && \
          "$final_domain" == "$existing_domain" && \
          "$final_server_ip" == "$existing_server_ip" && \
          "$final_linode_id" == "$existing_linode_id" && \
          "$final_type" == "$existing_type" && \
          -n "$existing_server_ip" ]]; then
        echo -e "${GREEN}Live config already up to date for '$site_name'${NC}" >&2
        return 0
    fi

    # Create backup
    if ! yaml_backup "$config_file"; then
        return 1
    fi

    # Build live config with merged values
    local live_config="    live:\n"
    live_config="${live_config}      enabled: ${final_enabled:-true}\n"
    [[ -n "$final_domain" ]] && live_config="${live_config}      domain: $final_domain\n"
    [[ -n "$final_server_ip" ]] && live_config="${live_config}      server_ip: $final_server_ip\n"
    [[ -n "$final_linode_id" ]] && live_config="${live_config}      linode_id: $final_linode_id\n"
    [[ -n "$final_type" ]] && live_config="${live_config}      type: $final_type\n"

    # Add/replace live section in site
    awk -v site="$site_name" -v live_config="$live_config" '
        BEGIN { in_site = 0; in_sites = 0; in_live = 0; added = 0 }

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

        # Check for existing live section
        in_site && /^    live:/ {
            in_live = 1
            next  # Skip old live: line
        }

        # Skip contents of old live section
        in_live && /^      / {
            next
        }

        # End of live section
        in_live && !/^      / {
            in_live = 0
        }

        # In our site, check if we hit the next site or end of sites section
        in_site && (/^  [a-zA-Z0-9_-]+:/ || (/^[a-zA-Z]/ && !/^  / && !/^#/)) {
            # End of our site entry, add live config before next site/section
            if (!added) {
                printf "%s", live_config
                added = 1
            }
            in_site = 0
        }

        # Print the line
        { print }

        # At end of file, if still in site, add live config
        END {
            if (in_site && !added) {
                printf "%s", live_config
            }
        }
    ' "$config_file" > "${config_file}.tmp"

    # Move temp file to original
    if mv "${config_file}.tmp" "$config_file"; then
        echo -e "${GREEN}Live config updated for site '$site_name'${NC}" >&2
        return 0
    else
        echo -e "${RED}Error: Failed to update $config_file${NC}" >&2
        return 1
    fi
}

#######################################
# Add a migration stub entry to cnwp.yml
# Creates minimal entry for a site pending migration
# Arguments:
#   $1 - Site name
#   $2 - Directory path
#   $3 - Source type (drupal7/drupal8/drupal9/html/wordpress/joomla/other)
#   $4 - Source path or URL (optional)
#   $5 - Config file path (optional)
# Returns:
#   0 on success, 1 on failure
#######################################
yaml_add_migration_stub() {
    local site_name="$1"
    local directory="$2"
    local source_type="${3:-other}"
    local source_path="${4:-}"
    local config_file="${5:-$YAML_CONFIG_FILE}"

    # Validate required parameters
    if [[ -z "$site_name" || -z "$directory" ]]; then
        echo -e "${RED}Error: Site name and directory are required${NC}" >&2
        return 1
    fi

    # Validate site name for safe YAML operations
    if ! yaml_validate_sitename "$site_name"; then
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

    # Create migration stub entry
    local site_entry="  $site_name:
    directory: $directory
    recipe: migration
    environment: development
    purpose: migration
    created: $timestamp
    migration:
      status: pending
      source_type: $source_type"

    # Add source_path if provided
    if [[ -n "$source_path" ]]; then
        site_entry="$site_entry
      source_path: $source_path"
    fi

    # Add site entry to sites: section
    awk -v site_entry="$site_entry" '
        BEGIN { in_sites = 0; sites_found = 0; entry_added = 0 }

        /^sites:/ {
            sites_found = 1
            in_sites = 1
            print
            next
        }

        # If in sites section and we hit a non-indented line, end of sites section
        in_sites && /^[a-zA-Z]/ && !/^  / {
            if (!entry_added) {
                print site_entry
                entry_added = 1
            }
            in_sites = 0
            print
            next
        }

        in_sites {
            print
            next
        }

        { print }

        END {
            if (in_sites && !entry_added) {
                print site_entry
            }
        }
    ' "$config_file" > "${config_file}.tmp"

    if mv "${config_file}.tmp" "$config_file"; then
        echo -e "${GREEN}Migration stub '$site_name' added to $config_file${NC}" >&2
        return 0
    else
        echo -e "${RED}Error: Failed to update $config_file${NC}" >&2
        return 1
    fi
}

#######################################
# Get site purpose from cnwp.yml
# Arguments:
#   $1 - Site name
#   $2 - Config file path (optional)
# Outputs:
#   Purpose value (testing/indefinite/permanent/migration)
# Returns:
#   0 on success, 1 on failure
#######################################
yaml_get_site_purpose() {
    local site_name="$1"
    local config_file="${2:-$YAML_CONFIG_FILE}"

    local purpose=$(yaml_get_site_field "$site_name" "purpose" "$config_file")

    # Default to indefinite if not set (for backward compatibility)
    if [[ -z "$purpose" ]]; then
        echo "indefinite"
    else
        echo "$purpose"
    fi
}

# Export functions for use in other scripts
export -f yaml_validate_sitename
export -f yaml_validate_purpose
export -f yaml_validate
export -f yaml_validate_or_restore
export -f yaml_backup
export -f yaml_site_exists
export -f yaml_get_site_field
export -f yaml_get_site_list
export -f yaml_get_site_purpose
export -f yaml_add_site
export -f yaml_add_migration_stub
export -f yaml_remove_site
export -f yaml_update_site_field
export -f yaml_add_site_modules
export -f yaml_add_site_production
