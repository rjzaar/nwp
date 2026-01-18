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
# Password Generation Functions
################################################################################

# Generate a cryptographically secure random password
# Uses OpenSSL for high-quality entropy
# Usage: generate_secure_password [length]
# Default length: 24 characters
# Returns: Alphanumeric password (no special chars that might cause escaping issues)
generate_secure_password() {
    local length=${1:-24}
    openssl rand -base64 48 | tr -d '/=+' | cut -c -"$length"
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
    local secrets_file="${PROJECT_ROOT}/.secrets.yml"

    if [ ! -f "$secrets_file" ]; then
        echo "$default"
        return
    fi

    # Use consolidated YAML function
    local value=""
    if command -v yaml_get_secret &>/dev/null; then
        value=$(yaml_get_secret "$path" "$secrets_file" 2>/dev/null || true)
    else
        # Fallback to inline AWK if yaml-write.sh not available
        local section="${path%%.*}"
        local key="${path#*.}"

        value=$(awk -v section="$section" -v key="$key" '
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
    fi

    if [ -n "$value" ] && [ "$value" != "" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# Get infrastructure secret (from .secrets.yml - safe for AI assistants)
# Usage: get_infra_secret "section.key" "default_value"
# These secrets are for provisioning/automation, NOT user data access
get_infra_secret() {
    local path="$1"
    local default="$2"
    # Uses standard .secrets.yml (infrastructure secrets)
    get_secret "$path" "$default"
}

# Get data secret (from .secrets.data.yml - NEVER share with AI)
# Usage: get_data_secret "section.key" "default_value"
# These secrets provide access to user data (production DB, SSH, etc.)
get_data_secret() {
    local path="$1"
    local default="$2"
    local data_secrets_file="${PROJECT_ROOT}/.secrets.data.yml"

    # Warn if we're in an AI-accessible context (optional env var)
    if [ "${AI_CONTEXT:-}" = "true" ]; then
        echo "[SECURITY WARNING] Data secret accessed in AI context: $path" >&2
    fi

    if [ ! -f "$data_secrets_file" ]; then
        # Fall back to default if no data secrets file
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
            sub(/ *#.*$/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
    ' "$data_secrets_file")

    if [ -n "$value" ] && [ "$value" != "" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# Get nested data secret (from .secrets.data.yml)
# Usage: get_data_secret_nested "section.subsection.key" "default_value"
get_data_secret_nested() {
    local path="$1"
    local default="$2"
    local data_secrets_file="${PROJECT_ROOT}/.secrets.data.yml"

    if [ "${AI_CONTEXT:-}" = "true" ]; then
        echo "[SECURITY WARNING] Data secret accessed in AI context: $path" >&2
    fi

    if [ ! -f "$data_secrets_file" ]; then
        echo "$default"
        return
    fi

    local depth=$(echo "$path" | tr -cd '.' | wc -c)

    if [ "$depth" -eq 1 ]; then
        get_data_secret "$path" "$default"
        return
    fi

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
    ' "$data_secrets_file")

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
    local secrets_file="${PROJECT_ROOT}/.secrets.yml"

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

# Get setting value from nwp.yml with fallback
# Usage: get_setting "section.key" "default_value"
# Example: get_setting "php_settings.memory_limit" "512M"
get_setting() {
    local path="$1"
    local default="$2"
    local config_file="${PROJECT_ROOT}/nwp.yml"

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

################################################################################
# Environment Detection Functions
################################################################################

# Get environment type from site name (NWP naming convention)
# Usage: get_env_type_from_name "sitename"
# Returns: local, dev, stage, prod
get_env_type_from_name() {
    local site="$1"

    if [[ "$site" =~ -stg$ ]]; then
        echo "stage"
    elif [[ "$site" =~ _prod$ ]]; then
        echo "prod"
    else
        echo "local"
    fi
}

# Get base site name (without environment suffix)
# Usage: get_base_name "sitename-stg" -> "sitename"
get_base_name() {
    local site="$1"
    echo "$site" | sed -E 's/[-_](stg|prod)$//'
}

# Get Drupal environment from a running DDEV site
# Usage: get_drupal_environment "sitename"
# Returns: local, dev, stage, prod, ci, or "unknown"
get_drupal_environment() {
    local site="$1"
    local site_path=""

    # Determine site path
    if [ -d "$site" ]; then
        site_path="$site"
    elif [ -d "${PROJECT_ROOT}/sites/${site}" ]; then
        site_path="${PROJECT_ROOT}/sites/${site}"
    else
        # Fallback to name-based detection
        get_env_type_from_name "$site"
        return
    fi

    # Check if DDEV is running for this site
    local ddev_status=$(cd "$site_path" && ddev describe 2>/dev/null | grep -c "OK" || echo "0")

    if [ "$ddev_status" -gt 0 ]; then
        # Get environment from Drupal settings
        local drupal_env=$(cd "$site_path" && ddev drush php-eval "echo \Drupal\Core\Site\Settings::get('environment', 'unknown');" 2>/dev/null || echo "")
        if [ -n "$drupal_env" ] && [ "$drupal_env" != "unknown" ]; then
            echo "$drupal_env"
            return
        fi
    fi

    # Fallback to name-based detection
    get_env_type_from_name "$(basename "$site_path")"
}

# Get environment indicator color for terminal output
# Usage: get_env_color "environment"
# Returns: ANSI color code
get_env_color() {
    local env="$1"

    case "$env" in
        prod|production)
            echo "\033[0;31m"  # Red
            ;;
        stage|staging)
            echo "\033[1;33m"  # Yellow
            ;;
        dev|development)
            echo "\033[0;32m"  # Green
            ;;
        local)
            echo "\033[0;34m"  # Blue
            ;;
        ci)
            echo "\033[0;35m"  # Purple
            ;;
        *)
            echo "\033[0;37m"  # Gray
            ;;
    esac
}

# Print environment status with color coding
# Usage: print_env_status "sitename" "environment"
print_env_status() {
    local site="$1"
    local env="$2"
    local color=$(get_env_color "$env")
    local NC=$'\033[0m'

    printf "  %-20s ${color}[%s]${NC}\n" "$site" "$env"
}

# Get environment label for display (uppercase, formatted)
# Usage: get_env_label "stage" -> "STAGING"
get_env_label() {
    local env="$1"

    case "$env" in
        prod)
            echo "PRODUCTION"
            ;;
        stage|stg)
            echo "STAGING"
            ;;
        live)
            echo "LIVE"
            ;;
        dev)
            echo "DEVELOPMENT"
            ;;
        local)
            echo "LOCAL"
            ;;
        ci)
            echo "CI"
            ;;
        *)
            echo "$env" | tr '[:lower:]' '[:upper:]'
            ;;
    esac
}

# Get environment display label (Title Case, formatted)
# Usage: get_env_display_label "prod" -> "Production"
get_env_display_label() {
    local env="$1"

    case "$env" in
        prod)
            echo "Production"
            ;;
        stage|stg)
            echo "Staging"
            ;;
        live)
            echo "Live"
            ;;
        dev)
            echo "Development"
            ;;
        local)
            echo "Local"
            ;;
        ci)
            echo "CI"
            ;;
        *)
            # Capitalize first letter
            echo "${env^}"
            ;;
    esac
}

################################################################################
# Migration Functions
################################################################################

# Setup migration folder structure for a site
# Usage: setup_migration_folder "/path/to/site" ["source_type"]
# Creates: migration/source/, migration/database/, migration/README.md
setup_migration_folder() {
    local site_dir="$1"
    local source_type="${2:-other}"
    local migration_dir="$site_dir/migration"

    # Check if site directory exists
    if [ ! -d "$site_dir" ]; then
        print_error "Site directory does not exist: $site_dir"
        return 1
    fi

    # Check if migration folder already exists
    if [ -d "$migration_dir" ]; then
        print_warning "Migration folder already exists: $migration_dir"
        return 0
    fi

    # Create migration directory structure
    print_info "Creating migration folder structure..."
    mkdir -p "$migration_dir/source"
    mkdir -p "$migration_dir/database"

    # Create README with instructions
    cat > "$migration_dir/README.md" << 'MIGRATION_README'
# Migration Folder

This folder is prepared for importing content from an existing site.

## Directory Structure

- `source/` - Place your source site files here
- `database/` - Place SQL database dumps here

## Next Steps

1. **Copy source files**: Copy your existing site into `source/`
   - For Drupal: Copy the entire Drupal root
   - For WordPress: Copy wp-content and wp-config.php
   - For static HTML: Copy all HTML/CSS/JS files

2. **Copy database**: Place SQL dump in `database/`
   - Name the file: `database.sql` or `source.sql`

3. **Analyze**: Run migration analysis
   ```bash
   ./migration.sh analyze <sitename>
   ```

4. **Prepare**: Set up migration modules
   ```bash
   ./migration.sh prepare <sitename>
   ```

5. **Run**: Execute the migration
   ```bash
   ./migration.sh run <sitename>
   ```

6. **Verify**: Check migration results
   ```bash
   ./migration.sh verify <sitename>
   ```

## Supported Source Types

| Type | Detection | Migration Method |
|------|-----------|------------------|
| drupal7 | `includes/bootstrap.inc` | Migrate Drupal module |
| drupal8/9/10 | `core/lib/Drupal.php` | Upgrade path |
| wordpress | `wp-config.php` | WordPress Migrate module |
| joomla | `configuration.php` | Custom migration |
| html | `index.html` | migrate_source_html |
| other | Manual | Custom migration needed |

## Tips

- Always backup your source before migrating
- Test migrations on a development copy first
- Check `/admin/reports/dblog` for migration errors
- Use `drush migrate:status` to monitor progress

MIGRATION_README

    print_status "OK" "Migration folder created: $migration_dir"
    return 0
}

# Check if a site has a migration folder
# Usage: has_migration_folder "/path/to/site"
# Returns: 0 if exists, 1 if not
has_migration_folder() {
    local site_dir="$1"
    [ -d "$site_dir/migration" ] && return 0
    return 1
}

# Remove migration folder from a site
# Usage: remove_migration_folder "/path/to/site"
remove_migration_folder() {
    local site_dir="$1"
    local migration_dir="$site_dir/migration"

    if [ ! -d "$migration_dir" ]; then
        print_info "No migration folder to remove"
        return 0
    fi

    # Check if migration folder has content
    if [ -n "$(ls -A "$migration_dir/source" 2>/dev/null)" ] || \
       [ -n "$(ls -A "$migration_dir/database" 2>/dev/null)" ]; then
        print_warning "Migration folder contains files. Remove manually if needed: $migration_dir"
        return 1
    fi

    rm -rf "$migration_dir"
    print_status "OK" "Migration folder removed"
    return 0
}

# Export functions for use in subshells
export -f get_secret
export -f get_secret_nested
export -f get_infra_secret
export -f get_data_secret
export -f get_data_secret_nested
export -f get_setting
export -f get_env_type_from_name
export -f get_base_name
export -f get_drupal_environment
export -f get_env_color
export -f print_env_status
export -f get_env_label
export -f setup_migration_folder
export -f has_migration_folder
export -f remove_migration_folder
