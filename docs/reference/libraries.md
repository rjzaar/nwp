# NWP Library Reference

API documentation for the NWP bash library functions.

**Version:** 1.0 | **Last Updated:** January 2026

---

## Table of Contents

1. [Usage](#usage)
2. [UI Library (ui.sh)](#ui-library-uish)
3. [Common Library (common.sh)](#common-library-commonsh)
4. [YAML Library (yaml-write.sh)](#yaml-library-yaml-writesh)
5. [TUI Library (tui.sh)](#tui-library-tuish)
6. [Checkbox Library (checkbox.sh)](#checkbox-library-checkboxsh)
7. [Git Library (git.sh)](#git-library-gitsh)
8. [Cloudflare Library (cloudflare.sh)](#cloudflare-library-cloudflaresh)
9. [Linode Library (linode.sh)](#linode-library-linodesh)
10. [Install Libraries](#install-libraries)
11. [State Library (state.sh)](#state-library-statesh)
12. [Database Router Library (database-router.sh)](#database-router-library-database-routersh)
13. [Testing Library (testing.sh)](#testing-library-testingsh)
14. [Preflight Library (preflight.sh)](#preflight-library-preflightsh)
15. [Dev2Stg TUI Library (dev2stg-tui.sh)](#dev2stg-tui-library-dev2stg-tuish)
16. [CLI Registration Library (cli-register.sh)](#cli-registration-library-cli-registersh)
17. [Frontend Library (frontend.sh)](#frontend-library-frontendsh)
18. [Frontend Tool Libraries](#frontend-tool-libraries)

---

# Usage

Libraries are sourced from the `lib/` directory:

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source required libraries (order matters)
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/yaml-write.sh"
```

**Source Order:**
1. `ui.sh` - No dependencies
2. `common.sh` - Requires `ui.sh`
3. `yaml-write.sh` - Standalone
4. Other libraries as needed

---

# UI Library (ui.sh)

Consistent output formatting and color support.

## Color Variables

```bash
$RED      # Red text
$GREEN    # Green text
$YELLOW   # Yellow text
$BLUE     # Blue text
$CYAN     # Cyan text
$NC       # No color (reset)
$BOLD     # Bold text
```

Colors are automatically disabled when not outputting to a terminal.

## Functions

### print_header

Prints a prominent section header.

```bash
print_header "message"

# Example
print_header "Installing Site"
# Output:
# ═══════════════════════════════════════════════════════════════
#   Installing Site
# ═══════════════════════════════════════════════════════════════
```

### print_status

Prints a status message with an icon.

```bash
print_status "STATUS" "message"

# Status values: OK, WARN, FAIL, INFO
print_status "OK" "Site created"      # [✓] Site created
print_status "WARN" "Check config"    # [!] Check config
print_status "FAIL" "Not found"       # [✗] Not found
print_status "INFO" "Running tests"   # [i] Running tests
```

### print_error

Prints an error message to stderr.

```bash
print_error "message"

# Example
print_error "Site not found"
# Output: ERROR: Site not found
```

### print_info

Prints an informational message.

```bash
print_info "message"

# Example
print_info "Starting backup"
# Output: INFO: Starting backup
```

### print_warning

Prints a warning message.

```bash
print_warning "message"

# Example
print_warning "Config file missing"
# Output: WARNING: Config file missing
```

### show_elapsed_time

Displays time since START_TIME was set.

```bash
START_TIME=$(date +%s)
# ... do work ...
show_elapsed_time "Operation"

# Output: [✓] Operation completed in 00:01:23
```

## Vortex-Style Output Functions

Standardized output formatting inspired by Vortex.

### info

Prints an informational message with [INFO] prefix.

```bash
info "Starting deployment..."
# Output: [INFO] Starting deployment...
```

### pass

Prints a success message with [ OK ] prefix.

```bash
pass "Site created successfully"
# Output: [ OK ] Site created successfully
```

### fail

Prints a failure message with [FAIL] prefix.

```bash
fail "Could not connect to database"
# Output: [FAIL] Could not connect to database
```

### warn

Prints a warning message with [WARN] prefix.

```bash
warn "Configuration may need updating"
# Output: [WARN] Configuration may need updating
```

### task

Prints a task message (indented with >).

```bash
task "Syncing files..."
# Output:   > Syncing files...
```

### note

Prints a note message (double indented).

```bash
note "This may take a few minutes"
# Output:     This may take a few minutes
```

### step

Prints a step progress indicator.

```bash
step 3 10 "Running database updates"
# Output: [3/10] Running database updates
```

---

# Common Library (common.sh)

Shared utilities for all NWP scripts.

## Functions

### debug_msg / ocmsg

Debug output (only shows when DEBUG=true).

```bash
DEBUG=true
debug_msg "Variable value: $var"
ocmsg "Same as debug_msg"  # Alias
```

### validate_sitename

Validates a site name for safety.

```bash
if validate_sitename "$name" "site name"; then
    echo "Valid"
else
    echo "Invalid"
fi

# Checks:
# - Not empty
# - No absolute paths (/)
# - No path traversal (..)
# - Only alphanumeric, hyphen, underscore, dot
```

### ask_yes_no

Prompts for yes/no confirmation.

```bash
if ask_yes_no "Continue?" "y"; then
    echo "User said yes"
fi

# Parameters:
# $1 - Question text
# $2 - Default: "y" or "n" (default: "n")
# Returns: 0=yes, 1=no
```

### get_secret / get_infra_secret / get_data_secret

Retrieves secrets from `.secrets.yml` or `.secrets.data.yml`.

```bash
# Infrastructure secrets (API tokens, dev credentials)
token=$(get_infra_secret "linode.api_token" "")

# Data secrets (production credentials) - blocked for AI
password=$(get_data_secret "production.db_password" "")

# Generic (checks both files)
value=$(get_secret "some.path" "default_value")
```

### get_yaml_value

Reads a value from a YAML file.

```bash
value=$(get_yaml_value "settings.php" "nwp.yml")
```

---

# YAML Library (yaml-write.sh)

YAML file manipulation without external dependencies.

## Configuration

```bash
YAML_CONFIG_FILE="nwp.yml"  # Default config file
```

## Functions

### yaml_validate_sitename

Validates site name for YAML operations.

```bash
if yaml_validate_sitename "mysite"; then
    echo "Valid"
fi

# Checks:
# - Not empty
# - Max 64 characters
# - No path traversal
# - Starts with letter
# - Only alphanumeric, underscore, hyphen
```

### yaml_validate

Validates YAML file structure.

```bash
if yaml_validate "nwp.yml"; then
    echo "Valid YAML"
fi
```

### yaml_add_site

Adds a new site entry.

```bash
yaml_add_site "mysite" "nwp" "/path/to/site" "nwp.yml"

# Parameters:
# $1 - Site name
# $2 - Recipe name
# $3 - Directory path
# $4 - Config file (optional)
```

### yaml_remove_site

Removes a site entry.

```bash
yaml_remove_site "mysite" "nwp.yml"
```

### yaml_get_value

Reads a value from YAML.

```bash
value=$(yaml_get_value "sites.mysite.recipe" "nwp.yml")
```

### yaml_update_value

Updates an existing value.

```bash
yaml_update_value "sites.mysite.environment" "staging" "nwp.yml"
```

### yaml_site_exists

Checks if a site exists.

```bash
if yaml_site_exists "mysite" "nwp.yml"; then
    echo "Site exists"
fi
```

---

# TUI Library (tui.sh)

Terminal User Interface components.

## Functions

### tui_select_menu

Displays an interactive selection menu.

```bash
options=("Option 1" "Option 2" "Option 3")
selected=$(tui_select_menu "Choose an option:" "${options[@]}")
```

### tui_progress_bar

Shows a progress bar.

```bash
tui_progress_bar 50 100 "Processing"
# Output: Processing [████████████████████░░░░░░░░░░░░░░░░░░] 50%
```

### tui_confirm

Shows a confirmation dialog.

```bash
if tui_confirm "Are you sure?"; then
    echo "Confirmed"
fi
```

---

# Checkbox Library (checkbox.sh)

Multi-select checkbox interface with dependencies.

## Functions

### checkbox_select

Interactive multi-select with dependency handling.

```bash
# Define options with dependencies
declare -A options
options["devel"]="Enable development modules"
options["redis"]="Enable Redis caching (requires: devel)"
options["solr"]="Enable Solr search"

# Show selector
selected=$(checkbox_select "Select features:" "${!options[@]}")
```

### checkbox_with_deps

Checkbox with automatic dependency resolution.

```bash
# Dependencies are automatically enabled when selecting an option
# Conflicts are automatically prevented
```

---

# Git Library (git.sh)

Git operations and GitLab API integration.

## Functions

### git_init

Initializes git in a directory.

```bash
git_init "/path/to/site"
```

### git_commit_backup

Creates a backup commit.

```bash
git_commit_backup "mysite" "Backup before deployment"
```

### gitlab_api_call

Makes a GitLab API request.

```bash
result=$(gitlab_api_call "GET" "projects" "")
```

### gitlab_create_project

Creates a new GitLab project.

```bash
gitlab_create_project "myproject" "private"
```

### gitlab_composer_publish

Publishes a package to GitLab Composer Registry.

```bash
gitlab_composer_publish "/path/to/package" "v1.0.0" "namespace/project"
```

---

# Cloudflare Library (cloudflare.sh)

DNS and CDN management via Cloudflare API.

## Functions

### cf_get_zone_id

Gets zone ID for a domain.

```bash
zone_id=$(cf_get_zone_id "example.com")
```

### cf_create_dns_record

Creates a DNS record.

```bash
cf_create_dns_record "$zone_id" "A" "subdomain" "192.168.1.1"
```

### cf_update_dns_record

Updates an existing DNS record.

```bash
cf_update_dns_record "$zone_id" "$record_id" "A" "subdomain" "192.168.1.2"
```

### cf_purge_cache

Purges CDN cache.

```bash
cf_purge_cache "$zone_id"
```

---

# Linode Library (linode.sh)

Linode server provisioning and management.

## Functions

### linode_api_call

Makes a Linode API request.

```bash
result=$(linode_api_call "GET" "linode/instances")
```

### linode_create_instance

Creates a new Linode instance.

```bash
linode_create_instance "my-server" "g6-standard-2" "us-east" "linode/ubuntu22.04"
```

### wait_for_ssh

Waits for SSH to become available.

```bash
if wait_for_ssh "$ip_address" 600; then
    echo "SSH ready"
fi
```

### linode_delete_instance

Deletes a Linode instance.

```bash
linode_delete_instance "$instance_id"
```

---

# Install Libraries

## install-common.sh

Shared installation logic and option definitions.

### Key Functions

```bash
get_recipe_value()      # Get a value from recipe config
check_prerequisites()   # Verify installation requirements
install_composer_deps() # Run composer install
run_drush_command()     # Execute drush safely
```

## install-drupal.sh

Drupal-specific installation.

### Key Functions

```bash
install_drupal()        # Main Drupal installation
configure_drupal()      # Apply Drupal settings
enable_dev_modules()    # Enable development modules
```

## install-moodle.sh

Moodle-specific installation.

### Key Functions

```bash
install_moodle()        # Main Moodle installation
configure_moodle()      # Apply Moodle settings
```

## install-steps.sh

Step tracking for resumable installations.

### Key Functions

```bash
start_step()            # Begin a named step
complete_step()         # Mark step complete
should_run_step()       # Check if step should run
get_last_completed()    # Get last completed step number
```

---

# Error Handling

## Best Practices

```bash
#!/bin/bash
set -euo pipefail

source lib/ui.sh
source lib/common.sh

# Use validation
if ! validate_sitename "$1"; then
    exit 1
fi

# Check return values
if ! some_function; then
    print_error "Function failed"
    exit 1
fi

# Use traps for cleanup
cleanup() {
    # Cleanup code here
    rm -f "$temp_file"
}
trap cleanup EXIT
```

---

# State Library (state.sh)

Intelligent state detection for sites, backups, and production access.

## Functions

### site_exists

Checks if a site directory exists and is valid.

```bash
if site_exists "mysite"; then
    echo "Site exists"
fi
```

### site_running

Checks if a site's DDEV container is running.

```bash
if site_running "mysite"; then
    echo "Site is running"
fi
```

### find_recent_backup

Finds recent backups within specified hours.

```bash
# Find backup less than 24 hours old
backup=$(find_recent_backup "mysite" 24)
if [ -n "$backup" ]; then
    echo "Found: $backup"
fi
```

### find_sanitized_backup

Finds recent sanitized backups.

```bash
# Find sanitized backup less than 24 hours old
backup=$(find_sanitized_backup "mysite" 24)
```

### check_prod_ssh

Checks if production server is SSH accessible.

```bash
if check_prod_ssh "mysite"; then
    echo "Production accessible"
fi
```

### detect_test_suites

Detects available test suites for a site.

```bash
available=$(detect_test_suites "mysite")
# Returns: phpunit,phpcs,phpstan
```

### get_site_state

Returns comprehensive state information for a site.

```bash
state=$(get_site_state "mysite")
# JSON with: exists, running, has_stg, has_backup, prod_accessible
```

### get_staging_name

Returns the staging name for a site.

```bash
stg_name=$(get_staging_name "mysite")  # Returns: mysite-stg
```

---

# Database Router Library (database-router.sh)

Multi-source database download and management.

## Database Sources

| Source | Description |
|--------|-------------|
| `auto` | Intelligent source selection |
| `production` | Fresh from production server |
| `backup:/path` | Specific backup file |
| `development` | Clone from dev site |
| `url:https://...` | Download from URL |

## Functions

### download_database

Routes database operations to appropriate handler.

```bash
# Auto-select best source
download_database "mysite" "auto" "mysite-stg"

# From production
download_database "mysite" "production" "mysite-stg"

# From specific backup
download_database "mysite" "backup:/path/to/backup.sql.gz" "mysite-stg"

# From development site
download_database "mysite" "development" "mysite-stg"

# From URL
download_database "mysite" "url:https://example.com/db.sql.gz" "mysite-stg"
```

### download_db_auto

Intelligent source selection priority:
1. Recent sanitized backup (< 24 hours)
2. Recent regular backup (< 24 hours)
3. Production (if SSH accessible)
4. Development clone

```bash
download_db_auto "mysite" "mysite-stg"
```

### sanitize_staging_db

Sanitizes database after import.

```bash
sanitize_staging_db "mysite-stg"
```

Actions:
- Truncates cache, session, and log tables
- Anonymizes user data (email, name)
- Resets admin password to 'admin'
- Clears sensitive configuration
- Rebuilds cache

### create_sanitized_backup

Creates a sanitized backup file.

```bash
backup_file=$(create_sanitized_backup "mysite")
```

### list_backups

Lists available backups for a site.

```bash
list_backups "mysite" 10  # Show 10 most recent
```

### get_recommended_db_source

Returns recommended source based on current state.

```bash
source=$(get_recommended_db_source "mysite")
# Returns: sanitized_backup, recent_backup, production, or development
```

---

# Testing Library (testing.sh)

Multi-tier testing system with 8 test types and 5 presets.

## Test Types

| Type | Description |
|------|-------------|
| `phpunit` | PHPUnit unit/integration tests |
| `behat` | Behat BDD scenario tests |
| `phpstan` | PHPStan static analysis |
| `phpcs` | PHP CodeSniffer style checks |
| `eslint` | JavaScript/TypeScript linting |
| `stylelint` | CSS/SCSS linting |
| `security` | Security vulnerability scan |
| `accessibility` | WCAG accessibility checks |

## Test Presets

| Preset | Tests Included | Est. Duration |
|--------|---------------|---------------|
| `quick` | phpcs, eslint | ~1 min |
| `essential` | phpunit, phpstan, phpcs | ~4 min |
| `functional` | behat | ~10 min |
| `full` | All except accessibility | ~15 min |
| `security-only` | security, phpstan | ~2 min |

## Functions

### run_tests

Main test runner function.

```bash
# Run a preset
run_tests "mysite" "essential"

# Run specific tests
run_tests "mysite" "phpunit,phpstan"

# Stop on first failure
run_tests "mysite" "full" "true"

# Skip tests
run_tests "mysite" "skip"
```

### list_test_types

Lists available test types.

```bash
list_test_types
# Output:
#   phpunit - PHPUnit unit/integration tests
#   behat - Behat BDD scenario tests
#   ...
```

### list_test_presets

Lists available presets with durations.

```bash
list_test_presets
# Output:
#   quick (~1min) - phpcs,eslint
#   essential (~4min) - phpunit,phpstan,phpcs
#   ...
```

### estimate_test_duration

Estimates duration for a selection.

```bash
minutes=$(estimate_test_duration "full")
echo "Estimated: $minutes minutes"
```

### check_available_tests

Checks which tests are available for a site.

```bash
available=$(check_available_tests "mysite")
# Returns: phpunit,phpcs,security
```

### validate_test_selection

Validates a test selection string.

```bash
if validate_test_selection "phpunit,phpcs"; then
    echo "Valid selection"
fi
```

---

# Preflight Library (preflight.sh)

Pre-deployment validation inspired by Vortex's doctor.sh.

## Functions

### preflight_check

Runs comprehensive preflight checks.

```bash
if preflight_check "mysite" "mysite-stg"; then
    echo "All critical checks passed"
else
    echo "Some checks failed"
fi
```

Checks performed:
1. DDEV installation and status
2. Docker availability
3. Source site validation
4. Target site status
5. Required tools (rsync, composer, git)
6. Disk space
7. Production access (optional)
8. Git status

### quick_preflight

Minimal checks for automated runs (use with -y flag).

```bash
if quick_preflight "mysite"; then
    echo "Quick checks passed"
fi
```

Checks: DDEV, source site exists, Docker running.

### show_system_info

Displays system information (like doctor --info).

```bash
show_system_info
# Output:
# Operating System: Linux 6.x
# Docker: Version x.x, Running
# DDEV: Version x.x
# PHP (host): Version x.x
# Disk Space: ...
# Memory: ...
```

### validate_db_operation

Validates before database operations.

```bash
if validate_db_operation "mysite"; then
    # Safe to proceed with database ops
fi
```

### validate_rsync_operation

Validates before rsync operations.

```bash
if validate_rsync_operation "/source/path" "/target/path"; then
    # Safe to rsync
fi
```

### Individual Check Functions

```bash
check_ddev                # Check DDEV installation
check_source_site "site"  # Check source site validity
check_target_site "site"  # Check target site status
check_required_tools      # Check rsync, composer, git
check_disk_space          # Check available disk space
check_production_access   # Check production SSH access
check_git_status "site"   # Check for uncommitted changes
```

---

# Dev2Stg TUI Library (dev2stg-tui.sh)

Interactive Terminal User Interface for dev2stg deployment.

## Functions

### run_dev2stg_tui

Launches the interactive TUI.

```bash
run_dev2stg_tui "mysite"

# After completion, variables are set:
echo "$TUI_DB_SOURCE"      # Selected database source
echo "$TUI_TEST_SELECTION" # Selected test configuration
```

### TUI Features

The TUI provides:

1. **State Overview**
   - Source site status
   - Staging site status
   - Available backups
   - Production accessibility

2. **Database Source Menu**
   - Auto (intelligent selection)
   - Fresh from production
   - Recent backup
   - Development clone
   - Custom URL

3. **Test Selection Menu**
   - Quick preset (~1 min)
   - Essential preset (~4 min)
   - Full preset (~15 min)
   - Custom selection
   - Skip tests

4. **Plan Review**
   - Shows selected options
   - Allows modifications
   - Confirms before proceeding

### Navigation

| Key | Action |
|-----|--------|
| ↑/↓ | Navigate options |
| Enter | Select option |
| q | Quit/Cancel |
| b | Go back |
| ? | Show help |

### Output Variables

After running the TUI, these variables are set:

```bash
TUI_DB_SOURCE       # "auto", "production", "backup:/path", "development", "url:..."
TUI_TEST_SELECTION  # "quick", "essential", "full", "skip", or comma-separated types
```

---

# CLI Registration Library (cli-register.sh)

Manages NWP CLI command registration for multiple installations.

## Functions

### register_cli_command

Registers or updates a CLI command symlink.

```bash
source lib/cli-register.sh

# Register with auto-detected name (pl, pl1, pl2, etc.)
register_cli_command "/home/user/nwp"

# Register with preferred name
register_cli_command "/home/user/nwp" "mypl"
```

### unregister_cli_command

Removes a CLI command registration.

```bash
unregister_cli_command "/home/user/nwp"
```

### get_cli_command

Gets the current CLI command for an installation.

```bash
cmd=$(get_cli_command "/home/user/nwp")
echo "Current command: $cmd"  # e.g., "pl" or "pl1"
```

### find_available_cli_name

Finds an available CLI command name.

```bash
# Find next available (pl, pl1, pl2, etc.)
name=$(find_available_cli_name "pl")

# Returns "pl" if available, or "pl1", "pl2", etc.
```

---

# Frontend Library (frontend.sh)

Core frontend build tool detection and configuration.

## Functions

### find_theme_dir

Finds the theme directory for a site.

```bash
theme_dir=$(find_theme_dir "mysite")
echo "Theme: $theme_dir"
```

### detect_frontend_tool

Detects the frontend build tool from config files.

```bash
tool=$(detect_frontend_tool "/path/to/theme")
# Returns: gulp, grunt, webpack, vite, or none
```

Detection priority:
1. Site config in nwp.yml (`frontend.build_tool`)
2. Auto-detect from files (gulpfile.js, Gruntfile.js, etc.)
3. Recipe default
4. Global default

### detect_package_manager

Detects the package manager from lock files.

```bash
pm=$(detect_package_manager "/path/to/theme")
# Returns: yarn, npm, or pnpm
```

Detection order:
1. `yarn.lock` → yarn
2. `package-lock.json` → npm
3. `pnpm-lock.yaml` → pnpm

### get_ddev_url

Gets the DDEV URL for a site.

```bash
url=$(get_ddev_url "mysite")
echo "URL: $url"  # e.g., https://mysite.ddev.site
```

### get_theme_node_version

Gets the required Node.js version for a theme.

```bash
version=$(get_theme_node_version "/path/to/theme")
echo "Node: $version"  # e.g., 20
```

### install_theme_deps

Installs Node.js dependencies for a theme.

```bash
install_theme_deps "/path/to/theme" "yarn"
```

### list_theme_dirs

Lists all theme directories for a site.

```bash
list_theme_dirs "mysite" | while read dir; do
    echo "Found theme: $dir"
done
```

---

# Frontend Tool Libraries

Tool-specific implementations in `lib/frontend/`.

## Gulp Library (lib/frontend/gulp.sh)

### gulp_watch

Starts Gulp watch mode with browser-sync.

```bash
source lib/frontend/gulp.sh
gulp_watch "mysite" "/path/to/theme"
```

### gulp_build

Runs production build.

```bash
gulp_build "mysite" "/path/to/theme"
```

### gulp_task

Runs a specific Gulp task.

```bash
gulp_task "mysite" "lint" "/path/to/theme"
```

### configure_browsersync_url

Configures browser-sync with DDEV URL.

```bash
configure_browsersync_url "/path/to/theme" "https://mysite.ddev.site"
```

## Grunt Library (lib/frontend/grunt.sh)

### grunt_watch

Starts Grunt watch mode.

```bash
source lib/frontend/grunt.sh
grunt_watch "mysite" "/path/to/theme"
```

### grunt_build

Runs production build.

```bash
grunt_build "mysite" "/path/to/theme"
```

### grunt_lint

Runs Grunt linting.

```bash
grunt_lint "mysite" "/path/to/theme"
```

## Webpack Library (lib/frontend/webpack.sh)

### webpack_watch

Starts Webpack dev server.

```bash
source lib/frontend/webpack.sh
webpack_watch "mysite" "/path/to/theme"
```

### webpack_build

Runs production build.

```bash
webpack_build "mysite" "/path/to/theme"
```

### webpack_dev

Runs development build.

```bash
webpack_dev "mysite" "/path/to/theme"
```

## Vite Library (lib/frontend/vite.sh)

### vite_watch

Starts Vite dev server.

```bash
source lib/frontend/vite.sh
vite_watch "mysite" "/path/to/theme"
```

### vite_build

Runs production build.

```bash
vite_build "mysite" "/path/to/theme"
```

---

# Testing Libraries

Unit tests are available in `tests/`:

```bash
./tests/test-yaml-write.sh    # YAML library tests
./tests/test-integration.sh   # Integration tests
```

---

*For script usage documentation, see [Features Reference](features.md)*
