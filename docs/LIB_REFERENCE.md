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
value=$(get_yaml_value "settings.php" "cnwp.yml")
```

---

# YAML Library (yaml-write.sh)

YAML file manipulation without external dependencies.

## Configuration

```bash
YAML_CONFIG_FILE="cnwp.yml"  # Default config file
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
if yaml_validate "cnwp.yml"; then
    echo "Valid YAML"
fi
```

### yaml_add_site

Adds a new site entry.

```bash
yaml_add_site "mysite" "nwp" "/path/to/site" "cnwp.yml"

# Parameters:
# $1 - Site name
# $2 - Recipe name
# $3 - Directory path
# $4 - Config file (optional)
```

### yaml_remove_site

Removes a site entry.

```bash
yaml_remove_site "mysite" "cnwp.yml"
```

### yaml_get_value

Reads a value from YAML.

```bash
value=$(yaml_get_value "sites.mysite.recipe" "cnwp.yml")
```

### yaml_update_value

Updates an existing value.

```bash
yaml_update_value "sites.mysite.environment" "staging" "cnwp.yml"
```

### yaml_site_exists

Checks if a site exists.

```bash
if yaml_site_exists "mysite" "cnwp.yml"; then
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

# Testing Libraries

Unit tests are available in `tests/`:

```bash
./tests/test-yaml-write.sh    # YAML library tests
./tests/test-integration.sh   # Integration tests
```

---

*For script usage documentation, see `docs/FEATURES.md`*
