# NWP Library Functions API Reference

**Last Updated:** 2026-01-14

Complete API reference for all library functions in the NWP (Narrow Way Project) codebase. This document provides function signatures, parameters, return values, dependencies, usage examples, and security notes for all functions across all library files in `lib/`.

---

## Table of Contents

- [common.sh](#commonsh) - Core utility functions
- [ui.sh](#uish) - User interface and output functions
- [ssh.sh](#sshsh) - SSH security controls
- [remote.sh](#remotesh) - Remote site operations
- [cloudflare.sh](#cloudflaresh) - Cloudflare API integration
- [linode.sh](#linodesh) - Linode API integration
- [yaml-write.sh](#yaml-writesh) - YAML configuration management
- [checkbox.sh](#checkboxsh) - Interactive checkbox UI
- [tui.sh](#tuish) - Unified TUI for install/modify modes
- [install-common.sh](#install-commonsh) - Shared installation functions
- [install-drupal.sh](#install-drupalsh) - Drupal installation handler
- [install-moodle.sh](#install-moodlesh) - Moodle LMS installation handler
- [install-gitlab.sh](#install-gitlabsh) - GitLab CE installation handler
- [install-podcast.sh](#install-podcastsh) - Castopod podcast installation handler
- [git.sh](#gitsh) - Git and GitLab operations
- [testing.sh](#testingsh) - Multi-tier testing system
- [database-router.sh](#database-routersh) - Multi-source database management
- [preflight.sh](#preflightsh) - Pre-installation checks
- [state.sh](#statesh) - Site state detection
- [badges.sh](#badgessh) - Status badge generation
- [podcast.sh](#podcastsh) - Podcast platform (Castopod) operations
- [avc-moodle.sh](#avc-moodlesh) - AVC-specific Moodle integration
- [b2.sh](#b2sh) - Backblaze B2 storage operations
- [developer.sh](#developersh) - Developer workflow tools
- [live-server-setup.sh](#live-server-setupsh) - Production server provisioning
- [sanitize.sh](#sanitizesh) - Database sanitization
- [server-scan.sh](#server-scansh) - Remote server scanning
- [rollback.sh](#rollbacksh) - Installation rollback
- [frontend.sh](#frontendsh) - Frontend asset management
- [env-generate.sh](#env-generatesh) - Environment file generation (script)
- [ddev-generate.sh](#ddev-generatesh) - DDEV configuration generation (script)
- [install-steps.sh](#install-stepssh) - Installation step tracking
- [safe-ops.sh](#safe-opssh) - AI-safe proxy operations
- [terminal.sh](#terminalsh) - Minimal terminal control
- [cli-register.sh](#cli-registersh) - CLI command registration
- [dev2stg-tui.sh](#dev2stg-tuish) - Dev-to-staging TUI
- [import-tui.sh](#import-tuish) - Import system TUI components
- [import.sh](#importsh) - Site import operations

---

## common.sh

Core utility functions shared across all NWP scripts. Provides validation, secret management, environment detection, and migration folder management.

### validate_sitename()

**Signature:** `validate_sitename <sitename>`

**Purpose:** Validates a sitename to ensure it contains only safe characters (alphanumeric, hyphens, underscores).

**Parameters:**
- `$1` (string) - Sitename to validate

**Returns:**
- `0` - Sitename is valid
- `1` - Sitename contains unsafe characters

**Security:** Critical input validation function. Prevents path traversal and injection attacks by restricting sitenames to safe characters only.

**Example:**
```bash
if validate_sitename "my-site_123"; then
    echo "Valid sitename"
fi
```

---

### ask_yes_no()

**Signature:** `ask_yes_no <prompt> [default]`

**Purpose:** Prompts the user for a yes/no answer with optional default.

**Parameters:**
- `$1` (string) - Prompt message to display
- `$2` (string, optional) - Default value ("y" or "n")

**Returns:**
- `0` - User answered yes
- `1` - User answered no

**Example:**
```bash
if ask_yes_no "Continue with installation?" "y"; then
    proceed_with_install
fi
```

---

### generate_secure_password()

**Signature:** `generate_secure_password [length]`

**Purpose:** Generates a cryptographically secure random password.

**Parameters:**
- `$1` (integer, optional) - Password length (default: 32)

**Returns:** Outputs password to stdout

**Security:** Uses `/dev/urandom` for cryptographic randomness. Includes mixed case, digits, and special characters.

**Example:**
```bash
DB_PASSWORD=$(generate_secure_password 24)
```

---

### get_secret()

**Signature:** `get_secret <key> [default] [file]`

**Purpose:** Retrieves a secret value from .secrets.yml (infrastructure secrets).

**Parameters:**
- `$1` (string) - Secret key path (e.g., "linode.api_token")
- `$2` (string, optional) - Default value if not found
- `$3` (string, optional) - Secrets file path (default: .secrets.yml)

**Returns:** Outputs secret value to stdout

**Security:** Only accesses infrastructure secrets (API tokens, not production data). Uses AWK-based YAML parsing without external dependencies.

**Example:**
```bash
LINODE_TOKEN=$(get_secret "linode.api_token" "")
```

---

### get_infra_secret()

**Signature:** `get_infra_secret <key> [default]`

**Purpose:** Retrieves infrastructure secrets (API tokens for Linode, Cloudflare, GitLab).

**Parameters:**
- `$1` (string) - Secret key path
- `$2` (string, optional) - Default value

**Returns:** Outputs secret value to stdout

**Security:** Access to infrastructure secrets only. Safe for AI assistants to use.

**Example:**
```bash
CLOUDFLARE_TOKEN=$(get_infra_secret "cloudflare.api_token")
```

---

### get_data_secret()

**Signature:** `get_data_secret <key> [default]`

**Purpose:** Retrieves data secrets (production database passwords, SSH keys, SMTP credentials).

**Parameters:**
- `$1` (string) - Secret key path
- `$2` (string, optional) - Default value

**Returns:** Outputs secret value to stdout

**Security:** **PROTECTED.** Access to production credentials and user data. Should NOT be called by AI assistants. Use safe-ops.sh proxy functions instead.

**Example:**
```bash
# Only in production deployment scripts
DB_PASS=$(get_data_secret "production_database.password")
```

---

### get_secret_nested()

**Signature:** `get_secret_nested <file> <key> [default]`

**Purpose:** Retrieves nested secret values from YAML files.

**Parameters:**
- `$1` (string) - Secrets file path
- `$2` (string) - Nested key path (dot-separated)
- `$3` (string, optional) - Default value

**Returns:** Outputs secret value to stdout

**Example:**
```bash
SSH_KEY=$(get_secret_nested ".secrets.data.yml" "production_ssh.server1.key_path" "")
```

---

### get_setting()

**Signature:** `get_setting <key> [default] [config_file]`

**Purpose:** Retrieves a setting value from nwp.yml.

**Parameters:**
- `$1` (string) - Setting key
- `$2` (string, optional) - Default value
- `$3` (string, optional) - Config file path (default: nwp.yml)

**Returns:** Outputs setting value to stdout

**Example:**
```bash
PHP_VERSION=$(get_setting "php" "8.2")
```

---

### get_env_type_from_name()

**Signature:** `get_env_type_from_name <sitename>`

**Purpose:** Determines environment type based on sitename suffix (e.g., "-stg", "-prod").

**Parameters:**
- `$1` (string) - Site name

**Returns:** Outputs environment type: "development", "staging", "production", or "live"

**Example:**
```bash
env=$(get_env_type_from_name "mysite-stg")  # Returns "staging"
```

---

### get_base_name()

**Signature:** `get_base_name <sitename>`

**Purpose:** Extracts base sitename by removing environment suffix.

**Parameters:**
- `$1` (string) - Site name with possible suffix

**Returns:** Outputs base name without environment suffix

**Example:**
```bash
base=$(get_base_name "mysite-stg")  # Returns "mysite"
```

---

### get_drupal_environment()

**Signature:** `get_drupal_environment <env_type>`

**Purpose:** Converts NWP environment type to Drupal environment constant.

**Parameters:**
- `$1` (string) - NWP environment type

**Returns:** Outputs Drupal environment: "dev", "stage", or "prod"

**Example:**
```bash
drupal_env=$(get_drupal_environment "staging")  # Returns "stage"
```

---

### get_env_color()

**Signature:** `get_env_color <env_type>`

**Purpose:** Returns terminal color code for environment type.

**Parameters:**
- `$1` (string) - Environment type

**Returns:** Outputs ANSI color code

**Example:**
```bash
color=$(get_env_color "production")  # Returns red color code
```

---

### print_env_status()

**Signature:** `print_env_status <sitename> <env_type>`

**Purpose:** Prints colored environment status indicator.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - Environment type

**Example:**
```bash
print_env_status "mysite" "production"  # Prints: [PROD] mysite
```

---

### get_env_label()

**Signature:** `get_env_label <env_type>`

**Purpose:** Returns short label for environment (DEV, STG, PROD).

**Parameters:**
- `$1` (string) - Environment type

**Returns:** Outputs short label

**Example:**
```bash
label=$(get_env_label "staging")  # Returns "STG"
```

---

### get_env_display_label()

**Signature:** `get_env_display_label <env_type>`

**Purpose:** Returns full display label for environment.

**Parameters:**
- `$1` (string) - Environment type

**Returns:** Outputs display label (e.g., "Development", "Staging")

**Example:**
```bash
label=$(get_env_display_label "dev")  # Returns "Development"
```

---

### setup_migration_folder()

**Signature:** `setup_migration_folder <sitename> <source_type>`

**Purpose:** Creates temporary migration folder for database/file operations.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - Source type ("production", "backup", etc.)

**Returns:**
- `0` - Success
- `1` - Failure

**Example:**
```bash
setup_migration_folder "mysite" "production"
```

---

### has_migration_folder()

**Signature:** `has_migration_folder <sitename>`

**Purpose:** Checks if a migration folder exists for a site.

**Parameters:**
- `$1` (string) - Site name

**Returns:**
- `0` - Migration folder exists
- `1` - Migration folder does not exist

**Example:**
```bash
if has_migration_folder "mysite"; then
    echo "Migration in progress"
fi
```

---

### remove_migration_folder()

**Signature:** `remove_migration_folder <sitename>`

**Purpose:** Removes migration folder after operation completes.

**Parameters:**
- `$1` (string) - Site name

**Returns:**
- `0` - Success

**Example:**
```bash
remove_migration_folder "mysite"
```

---

## ui.sh

User interface functions for consistent terminal output. Provides two output styles: text-prefix (for logging) and icon-based (for modern TUI).

### should_use_color()

**Signature:** `should_use_color`

**Purpose:** Determines if color output should be used based on NO_COLOR standard and terminal detection.

**Returns:**
- `0` - Colors should be used
- `1` - Colors should not be used

**Example:**
```bash
if should_use_color; then
    use_colors=true
fi
```

---

### print_header()

**Signature:** `print_header <message>`

**Purpose:** Prints a formatted header banner.

**Parameters:**
- `$1` (string) - Header message

**Example:**
```bash
print_header "Installing Drupal"
```

---

### print_status()

**Signature:** `print_status <status> <message>`

**Purpose:** Prints a status message with icon.

**Parameters:**
- `$1` (string) - Status type: "OK", "WARN", "FAIL", "INFO"
- `$2` (string) - Status message

**Example:**
```bash
print_status "OK" "Installation complete"
```

---

### print_error()

**Signature:** `print_error <message>`

**Purpose:** Prints an error message to stderr.

**Parameters:**
- `$1` (string) - Error message

**Example:**
```bash
print_error "Database connection failed"
```

---

### print_info()

**Signature:** `print_info <message>`

**Purpose:** Prints an informational message.

**Parameters:**
- `$1` (string) - Info message

**Example:**
```bash
print_info "Starting deployment process"
```

---

### print_warning()

**Signature:** `print_warning <message>`

**Purpose:** Prints a warning message.

**Parameters:**
- `$1` (string) - Warning message

**Example:**
```bash
print_warning "Low disk space detected"
```

---

### print_success()

**Signature:** `print_success <message>`

**Purpose:** Prints a success message.

**Parameters:**
- `$1` (string) - Success message

**Example:**
```bash
print_success "Configuration exported successfully"
```

---

### print_hint()

**Signature:** `print_hint <message>`

**Purpose:** Prints a hint/tip message.

**Parameters:**
- `$1` (string) - Hint message

**Example:**
```bash
print_hint "Try running 'drush cr' to clear caches"
```

---

### show_elapsed_time()

**Signature:** `show_elapsed_time [label]`

**Purpose:** Displays elapsed time since START_TIME was set.

**Parameters:**
- `$1` (string, optional) - Label for the operation (default: "Operation")

**Dependencies:** Requires START_TIME variable to be set before calling.

**Example:**
```bash
START_TIME=$(date +%s)
# ... do work ...
show_elapsed_time "Deployment"
```

---

### fail()

**Signature:** `fail <message>`

**Purpose:** Icon-style error message with ✗ symbol. Outputs to stderr.

**Parameters:**
- `$1` (string) - Error message

**Example:**
```bash
fail "Could not connect to database"
```

---

### warn()

**Signature:** `warn <message>`

**Purpose:** Icon-style warning message with ! symbol.

**Parameters:**
- `$1` (string) - Warning message

**Example:**
```bash
warn "Configuration file missing, using defaults"
```

---

### info()

**Signature:** `info <message>`

**Purpose:** Icon-style information message with ℹ symbol.

**Parameters:**
- `$1` (string) - Info message

**Example:**
```bash
info "Starting deployment to staging"
```

---

### pass()

**Signature:** `pass <message>`

**Purpose:** Icon-style success message with ✓ symbol.

**Parameters:**
- `$1` (string) - Success message

**Example:**
```bash
pass "Configuration exported successfully"
```

---

### task()

**Signature:** `task <message>`

**Purpose:** Indented step indicator for sub-operations.

**Parameters:**
- `$1` (string) - Task description

**Example:**
```bash
task "Exporting configuration..."
```

---

### note()

**Signature:** `note <message>`

**Purpose:** Additional details or hints, further indented.

**Parameters:**
- `$1` (string) - Note text

**Example:**
```bash
note "This may take several minutes"
```

---

### step()

**Signature:** `step <current> <total> <message>`

**Purpose:** Progress indicator with step count and percentage.

**Parameters:**
- `$1` (integer) - Current step number
- `$2` (integer) - Total number of steps
- `$3` (string) - Step description

**Example:**
```bash
step 3 10 "Running database updates"
```

---

### start_spinner()

**Signature:** `start_spinner [message]`

**Purpose:** Starts an animated spinner for background operations.

**Parameters:**
- `$1` (string, optional) - Message to display (default: "Working...")

**Note:** Only shows if terminal supports it. Sets SPINNER_PID variable.

**Example:**
```bash
start_spinner "Installing Drupal..."
# ... do work ...
stop_spinner
```

---

### stop_spinner()

**Signature:** `stop_spinner`

**Purpose:** Stops the animated spinner and clears the line.

**Dependencies:** Must be called after start_spinner().

**Example:**
```bash
stop_spinner
```

---

### show_step()

**Signature:** `show_step <current> <total> <message>`

**Purpose:** Simple step indicator for multi-step operations.

**Parameters:**
- `$1` (integer) - Current step
- `$2` (integer) - Total steps
- `$3` (string) - Step message

**Example:**
```bash
show_step 1 5 "Installing dependencies"
```

---

### show_progress()

**Signature:** `show_progress <current> <total> [message]`

**Purpose:** ASCII progress bar with percentage.

**Parameters:**
- `$1` (integer) - Current progress
- `$2` (integer) - Total/maximum
- `$3` (string, optional) - Progress message (default: "Progress")

**Example:**
```bash
show_progress 45 100 "Downloading"
```

---

### finish_progress()

**Signature:** `finish_progress`

**Purpose:** Completes a progress bar display by printing newline.

**Example:**
```bash
finish_progress
```

---

## ssh.sh

SSH security controls and host key checking management. Implements NWP_SSH_STRICT environment variable for security modes.

### get_ssh_host_key_checking()

**Signature:** `get_ssh_host_key_checking`

**Purpose:** Returns appropriate SSH host key checking mode based on NWP_SSH_STRICT.

**Returns:** Outputs SSH option value: "yes", "accept-new", or "no"

**Security:**
- `NWP_SSH_STRICT=yes` → Strict host key checking (most secure)
- `NWP_SSH_STRICT=accept-new` → Accept new keys but verify known hosts
- `NWP_SSH_STRICT=no` → Disable host key checking (development only)

**Example:**
```bash
HOST_KEY_CHECKING=$(get_ssh_host_key_checking)
ssh -o StrictHostKeyChecking=$HOST_KEY_CHECKING user@host
```

---

### show_ssh_security_warning()

**Signature:** `show_ssh_security_warning`

**Purpose:** Displays security warning when strict host key checking is disabled.

**Example:**
```bash
if [ "$NWP_SSH_STRICT" = "no" ]; then
    show_ssh_security_warning
fi
```

---

### get_ssh_options()

**Signature:** `get_ssh_options [key_path]`

**Purpose:** Returns complete SSH options string with security settings.

**Parameters:**
- `$1` (string, optional) - Path to SSH private key

**Returns:** Outputs SSH options string

**Example:**
```bash
SSH_OPTS=$(get_ssh_options "$HOME/.ssh/nwp")
ssh $SSH_OPTS user@host
```

---

### build_ssh_command()

**Signature:** `build_ssh_command <user@host> [key_path]`

**Purpose:** Builds a complete SSH command with all security options.

**Parameters:**
- `$1` (string) - SSH connection string (user@host)
- `$2` (string, optional) - Path to SSH private key

**Returns:** Outputs complete SSH command

**Example:**
```bash
SSH_CMD=$(build_ssh_command "root@example.com" "$HOME/.ssh/nwp")
$SSH_CMD "ls -la"
```

---

### is_ssh_strict_mode()

**Signature:** `is_ssh_strict_mode`

**Purpose:** Checks if SSH strict mode is enabled.

**Returns:**
- `0` - Strict mode is enabled
- `1` - Strict mode is disabled

**Example:**
```bash
if is_ssh_strict_mode; then
    echo "Strict SSH security enforced"
fi
```

---

## remote.sh

Remote site operations library for executing commands on remote servers. Includes input validation and security controls.

### parse_remote_target()

**Signature:** `parse_remote_target <target>`

**Purpose:** Parses remote notation (@env sitename) into components.

**Parameters:**
- `$1` (string) - Remote target string (e.g., "@prod mysite")

**Returns:** Outputs environment and sitename, or empty string if invalid

**Example:**
```bash
remote=$(parse_remote_target "@prod mysite")
```

---

### get_remote_config()

**Signature:** `get_remote_config <sitename> <environment>`

**Purpose:** Retrieves remote configuration from nwp.yml for a site/environment.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - Environment (dev, stage, prod, live)

**Returns:** Outputs key=value configuration pairs

**Security:** Validates sitename and environment to prevent injection.

**Example:**
```bash
config=$(get_remote_config "mysite" "production")
eval "$config"
echo "$server_ip"
```

---

### remote_exec()

**Signature:** `remote_exec <sitename> <environment> <command>`

**Purpose:** Executes a command on a remote server.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - Environment
- `$3` (string) - Command to execute

**Returns:**
- `0` - Success
- `1` - Failure

**Security:**
- Validates sitename/environment against unsafe characters
- Validates site_path as absolute path
- Uses proper quoting to prevent injection
- SSH commands run with BatchMode and ConnectTimeout

**Example:**
```bash
remote_exec "mysite" "production" "drush cr"
```

---

### remote_drush()

**Signature:** `remote_drush <sitename> <environment> <drush-command...>`

**Purpose:** Runs a Drush command on a remote server.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - Environment
- `$@` (string) - Drush command and arguments

**Returns:**
- `0` - Success
- `1` - Failure

**Example:**
```bash
remote_drush "mysite" "production" "status"
```

---

### remote_backup()

**Signature:** `remote_backup <sitename> <environment> [local_path]`

**Purpose:** Creates a database backup on remote server and downloads it.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - Environment
- `$3` (string, optional) - Local destination path (default: current directory)

**Returns:**
- `0` - Backup successful
- `1` - Backup failed

**Security:** Uses validated paths and proper quoting throughout.

**Example:**
```bash
remote_backup "mysite" "production" "./backups/"
```

---

### remote_test()

**Signature:** `remote_test <sitename> <environment>`

**Purpose:** Tests SSH connection to a remote server.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - Environment

**Returns:**
- `0` - Connection successful
- `1` - Connection failed

**Example:**
```bash
if remote_test "mysite" "production"; then
    echo "Connection OK"
fi
```

---

### remote_test_behat()

**Signature:** `remote_test_behat <sitename> <environment> [tags]`

**Purpose:** Runs Behat tests on a remote server (read-only tests on production).

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - Environment
- `$3` (string, optional) - Test tags (default: "@smoke")

**Returns:**
- `0` - Tests passed
- `1` - Tests failed

**Security:** Automatically adds ~@destructive filter on production environments.

**Example:**
```bash
remote_test_behat "mysite" "production" "@smoke"
```

---

## cloudflare.sh

Cloudflare API integration for DNS management and CDN configuration. Handles zones, DNS records, cache rules, and transform rules.

**Note:** This library contains 26+ functions. For brevity, key functions are documented below. See source file for complete function list.

### get_cloudflare_token()

**Signature:** `get_cloudflare_token`

**Purpose:** Retrieves Cloudflare API token from secrets.

**Returns:** Outputs API token or empty string

**Example:**
```bash
CF_TOKEN=$(get_cloudflare_token)
```

---

### get_cloudflare_zone_id()

**Signature:** `get_cloudflare_zone_id <domain>`

**Purpose:** Retrieves Cloudflare zone ID for a domain.

**Parameters:**
- `$1` (string) - Domain name

**Returns:** Outputs zone ID or empty string

**Example:**
```bash
ZONE_ID=$(get_cloudflare_zone_id "example.com")
```

---

### verify_cloudflare_auth()

**Signature:** `verify_cloudflare_auth`

**Purpose:** Verifies Cloudflare API authentication is working.

**Returns:**
- `0` - Authentication successful
- `1` - Authentication failed

**Example:**
```bash
if verify_cloudflare_auth; then
    echo "Cloudflare API authenticated"
fi
```

---

### cf_create_dns_a()

**Signature:** `cf_create_dns_a <zone_id> <name> <ip> [proxied] [ttl]`

**Purpose:** Creates an A record in Cloudflare DNS.

**Parameters:**
- `$1` (string) - Zone ID
- `$2` (string) - Record name
- `$3` (string) - IP address
- `$4` (boolean, optional) - Proxied status (default: true)
- `$5` (integer, optional) - TTL in seconds (default: 1 for auto)

**Returns:**
- `0` - Record created
- `1` - Creation failed

**Example:**
```bash
cf_create_dns_a "$ZONE_ID" "www" "192.0.2.1" true
```

---

### cf_create_dns_cname()

**Signature:** `cf_create_dns_cname <zone_id> <name> <target> [proxied] [ttl]`

**Purpose:** Creates a CNAME record in Cloudflare DNS.

**Parameters:**
- `$1` (string) - Zone ID
- `$2` (string) - Record name
- `$3` (string) - Target domain
- `$4` (boolean, optional) - Proxied status (default: true)
- `$5` (integer, optional) - TTL in seconds

**Returns:**
- `0` - Record created
- `1` - Creation failed

**Example:**
```bash
cf_create_dns_cname "$ZONE_ID" "blog" "example.com" true
```

---

### cf_upsert_dns_a()

**Signature:** `cf_upsert_dns_a <zone_id> <name> <ip> [proxied]`

**Purpose:** Creates or updates an A record (upsert operation).

**Parameters:**
- `$1` (string) - Zone ID
- `$2` (string) - Record name
- `$3` (string) - IP address
- `$4` (boolean, optional) - Proxied status (default: true)

**Returns:**
- `0` - Record created or updated
- `1` - Operation failed

**Example:**
```bash
cf_upsert_dns_a "$ZONE_ID" "api" "192.0.2.10"
```

---

### cf_delete_dns_record()

**Signature:** `cf_delete_dns_record <zone_id> <record_id>`

**Purpose:** Deletes a DNS record from Cloudflare.

**Parameters:**
- `$1` (string) - Zone ID
- `$2` (string) - Record ID

**Returns:**
- `0` - Record deleted
- `1` - Deletion failed

**Example:**
```bash
cf_delete_dns_record "$ZONE_ID" "$RECORD_ID"
```

---

### cf_list_dns_records()

**Signature:** `cf_list_dns_records <zone_id> [type] [name]`

**Purpose:** Lists DNS records for a zone with optional filtering.

**Parameters:**
- `$1` (string) - Zone ID
- `$2` (string, optional) - Record type filter (A, CNAME, etc.)
- `$3` (string, optional) - Name filter

**Returns:** Outputs JSON array of records

**Example:**
```bash
cf_list_dns_records "$ZONE_ID" "A"
```

---

### cf_purge_cache()

**Signature:** `cf_purge_cache <zone_id> [files...]`

**Purpose:** Purges Cloudflare cache for a zone or specific files.

**Parameters:**
- `$1` (string) - Zone ID
- `$@` (array, optional) - Specific files to purge (if empty, purges everything)

**Returns:**
- `0` - Cache purged
- `1` - Purge failed

**Example:**
```bash
cf_purge_cache "$ZONE_ID"  # Purge all
cf_purge_cache "$ZONE_ID" "https://example.com/style.css"  # Purge specific
```

---

## linode.sh

Linode API integration for server provisioning, DNS management, and resource management. Supports creating instances, managing DNS, and automating infrastructure.

**Note:** This library contains 38+ functions. Key functions are documented below.

### get_linode_token()

**Signature:** `get_linode_token`

**Purpose:** Retrieves Linode API token from secrets.

**Returns:** Outputs API token or empty string

**Example:**
```bash
LINODE_TOKEN=$(get_linode_token)
```

---

### get_ssh_key_id()

**Signature:** `get_ssh_key_id [key_name]`

**Purpose:** Gets the Linode SSH key ID by name.

**Parameters:**
- `$1` (string, optional) - SSH key name (default: "nwp")

**Returns:** Outputs SSH key ID or empty string

**Example:**
```bash
SSH_KEY_ID=$(get_ssh_key_id "nwp")
```

---

### create_linode_instance()

**Signature:** `create_linode_instance <label> <region> <type> <image> <ssh_key_id> [root_pass]`

**Purpose:** Creates a new Linode instance.

**Parameters:**
- `$1` (string) - Instance label
- `$2` (string) - Region (us-east, us-west, etc.)
- `$3` (string) - Linode type (g6-standard-2, g6-dedicated-4, etc.)
- `$4` (string) - Image (linode/ubuntu22.04, etc.)
- `$5` (string) - SSH key ID
- `$6` (string, optional) - Root password (auto-generated if not provided)

**Returns:** Outputs instance ID or empty string on failure

**Example:**
```bash
INSTANCE_ID=$(create_linode_instance "webserver1" "us-east" "g6-standard-2" "linode/ubuntu22.04" "$SSH_KEY_ID")
```

---

### wait_for_linode()

**Signature:** `wait_for_linode <instance_id> [max_wait]`

**Purpose:** Waits for a Linode instance to reach "running" status.

**Parameters:**
- `$1` (string) - Instance ID
- `$2` (integer, optional) - Max wait time in seconds (default: 300)

**Returns:**
- `0` - Instance is running
- `1` - Timeout or error

**Example:**
```bash
wait_for_linode "$INSTANCE_ID" 600
```

---

### get_linode_ip()

**Signature:** `get_linode_ip <instance_id>`

**Purpose:** Retrieves the public IPv4 address of a Linode instance.

**Parameters:**
- `$1` (string) - Instance ID

**Returns:** Outputs IP address or empty string

**Example:**
```bash
IP=$(get_linode_ip "$INSTANCE_ID")
```

---

### wait_for_ssh()

**Signature:** `wait_for_ssh <ip_address> [max_wait]`

**Purpose:** Waits for SSH service to become available on a server.

**Parameters:**
- `$1` (string) - IP address
- `$2` (integer, optional) - Max wait time in seconds (default: 300)

**Returns:**
- `0` - SSH is available
- `1` - Timeout

**Example:**
```bash
wait_for_ssh "$IP" 180
```

---

### delete_linode_instance()

**Signature:** `delete_linode_instance <instance_id>`

**Purpose:** Deletes a Linode instance permanently.

**Parameters:**
- `$1` (string) - Instance ID

**Returns:**
- `0` - Instance deleted
- `1` - Deletion failed

**Security:** Destructive operation. Use with caution.

**Example:**
```bash
delete_linode_instance "$INSTANCE_ID"
```

---

### provision_test_linode()

**Signature:** `provision_test_linode <label> [region] [type]`

**Purpose:** Provisions a temporary test Linode with automatic labeling.

**Parameters:**
- `$1` (string) - Label prefix
- `$2` (string, optional) - Region (default: us-east)
- `$3` (string, optional) - Type (default: g6-nanode-1)

**Returns:** Outputs instance ID

**Example:**
```bash
TEST_ID=$(provision_test_linode "test-drupal")
```

---

### list_test_linodes()

**Signature:** `list_test_linodes`

**Purpose:** Lists all test Linodes (labeled with "test-" prefix).

**Returns:** Outputs list of test instances

**Example:**
```bash
list_test_linodes
```

---

### cleanup_test_linodes()

**Signature:** `cleanup_test_linodes [age_hours]`

**Purpose:** Deletes test Linodes older than specified age.

**Parameters:**
- `$1` (integer, optional) - Age in hours (default: 24)

**Returns:**
- `0` - Cleanup complete

**Example:**
```bash
cleanup_test_linodes 48  # Delete test instances older than 48 hours
```

---

### linode_upsert_dns_a()

**Signature:** `linode_upsert_dns_a <domain> <name> <ip>`

**Purpose:** Creates or updates an A record in Linode DNS.

**Parameters:**
- `$1` (string) - Domain
- `$2` (string) - Record name
- `$3` (string) - IP address

**Returns:**
- `0` - Record created/updated
- `1` - Operation failed

**Example:**
```bash
linode_upsert_dns_a "example.com" "www" "192.0.2.1"
```

---

### verify_linode_dns()

**Signature:** `verify_linode_dns <domain>`

**Purpose:** Verifies Linode DNS configuration for a domain.

**Parameters:**
- `$1` (string) - Domain name

**Returns:**
- `0` - DNS configured correctly
- `1` - DNS issues detected

**Example:**
```bash
verify_linode_dns "example.com"
```

---

## yaml-write.sh

Comprehensive YAML management library for reading and writing nwp.yml configuration. Uses AWK-based parsing (no yq dependency) with file locking and atomic writes for safety.

**Note:** See [docs/YAML_API.md](/home/rob/nwp/docs/YAML_API.md) for comprehensive coverage of all 40+ functions in this library.

**Key Functions:**

### yaml_validate_sitename()

**Signature:** `yaml_validate_sitename <sitename>`

**Purpose:** Validates a sitename for YAML operations.

**Parameters:**
- `$1` (string) - Sitename to validate

**Returns:**
- `0` - Valid sitename
- `1` - Invalid sitename

**Security:** Critical validation function. Prevents injection and path traversal.

---

### yaml_site_exists()

**Signature:** `yaml_site_exists <sitename> [config_file]`

**Purpose:** Checks if a site exists in nwp.yml.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Config file path (default: nwp.yml)

**Returns:**
- `0` - Site exists
- `1` - Site does not exist

---

### yaml_add_site()

**Signature:** `yaml_add_site <sitename> <directory> <recipe> <environment> <purpose> [config_file]`

**Purpose:** Adds a new site to nwp.yml.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - Site directory path
- `$3` (string) - Recipe name
- `$4` (string) - Environment type
- `$5` (string) - Purpose (test, development, indefinite, etc.)
- `$6` (string, optional) - Config file path

**Returns:**
- `0` - Site added
- `1` - Site already exists or validation failed

**Security:** Uses file locking and atomic writes to prevent corruption.

---

### yaml_remove_site()

**Signature:** `yaml_remove_site <sitename> [config_file]`

**Purpose:** Removes a site from nwp.yml.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Config file path

**Returns:**
- `0` - Site removed
- `1` - Site not found or operation failed

---

### yaml_update_site_field()

**Signature:** `yaml_update_site_field <sitename> <field> <value> [config_file]`

**Purpose:** Updates a single field for a site in nwp.yml.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - Field name
- `$3` (string) - New value
- `$4` (string, optional) - Config file path

**Returns:**
- `0` - Field updated
- `1` - Update failed

---

### yaml_get_site_field()

**Signature:** `yaml_get_site_field <sitename> <field> [config_file]`

**Purpose:** Retrieves a field value for a site from nwp.yml.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - Field name
- `$3` (string, optional) - Config file path

**Returns:** Outputs field value or empty string

---

### yaml_get_site_list()

**Signature:** `yaml_get_site_list [config_file]`

**Purpose:** Lists all sites in nwp.yml.

**Parameters:**
- `$1` (string, optional) - Config file path

**Returns:** Outputs list of site names (one per line)

---

### yaml_backup()

**Signature:** `yaml_backup [config_file]`

**Purpose:** Creates a timestamped backup of nwp.yml.

**Parameters:**
- `$1` (string, optional) - Config file path

**Returns:**
- `0` - Backup created
- `1` - Backup failed

---

### yaml_validate()

**Signature:** `yaml_validate [config_file]`

**Purpose:** Validates YAML syntax and structure of nwp.yml.

**Parameters:**
- `$1` (string, optional) - Config file path

**Returns:**
- `0` - YAML is valid
- `1` - YAML has errors

---

### yaml_validate_or_restore()

**Signature:** `yaml_validate_or_restore [config_file]`

**Purpose:** Validates YAML and restores from backup if corrupted.

**Parameters:**
- `$1` (string, optional) - Config file path

**Returns:**
- `0` - YAML valid or successfully restored
- `1` - Validation failed and no backup available

---

For complete documentation of all 40+ YAML functions, see [docs/YAML_API.md](/home/rob/nwp/docs/YAML_API.md).

---

## checkbox.sh

Interactive checkbox UI library for installation options. Provides environment-aware option system with dependencies and conflicts. Used by install.sh and modify.sh.

**Note:** This is a large library (1488 lines) with 30+ functions. Key functions documented below.

### define_option()

**Signature:** `define_option <key> <label> <description> <default> <category> [dependencies] [conflicts] [envs]`

**Purpose:** Defines an installation option with metadata.

**Parameters:**
- `$1` (string) - Option key
- `$2` (string) - Display label
- `$3` (string) - Description
- `$4` (string) - Default value (y/n)
- `$5` (string) - Category
- `$6` (string, optional) - Comma-separated dependencies
- `$7` (string, optional) - Comma-separated conflicts
- `$8` (string, optional) - Applicable environments (dev,stage,live)

---

### clear_options()

**Signature:** `clear_options`

**Purpose:** Clears all defined options (resets the option system).

---

### define_drupal_options()

**Signature:** `define_drupal_options`

**Purpose:** Defines all standard Drupal installation options.

**Example:**
```bash
define_drupal_options
interactive_select_options
```

---

### define_moodle_options()

**Signature:** `define_moodle_options`

**Purpose:** Defines all standard Moodle installation options.

---

### define_gitlab_options()

**Signature:** `define_gitlab_options`

**Purpose:** Defines all standard GitLab installation options.

---

### get_option_default()

**Signature:** `get_option_default <key>`

**Purpose:** Gets the default value for an option.

**Parameters:**
- `$1` (string) - Option key

**Returns:** Outputs default value (y/n)

---

### option_visible_for_env()

**Signature:** `option_visible_for_env <key> <environment>`

**Purpose:** Checks if an option should be visible for a given environment.

**Parameters:**
- `$1` (string) - Option key
- `$2` (string) - Environment type

**Returns:**
- `0` - Option is visible
- `1` - Option is hidden

---

### apply_environment_defaults()

**Signature:** `apply_environment_defaults <environment>`

**Purpose:** Applies environment-specific default values to all options.

**Parameters:**
- `$1` (string) - Environment type (dev, stage, live)

---

### check_dependencies()

**Signature:** `check_dependencies <key>`

**Purpose:** Checks if all dependencies for an option are met.

**Parameters:**
- `$1` (string) - Option key

**Returns:**
- `0` - All dependencies met
- `1` - Missing dependencies

---

### check_conflicts()

**Signature:** `check_conflicts <key>`

**Purpose:** Checks if any conflicting options are enabled.

**Parameters:**
- `$1` (string) - Option key

**Returns:**
- `0` - No conflicts
- `1` - Conflicts detected

---

### get_dependents()

**Signature:** `get_dependents <key>`

**Purpose:** Gets list of options that depend on this option.

**Parameters:**
- `$1` (string) - Option key

**Returns:** Outputs comma-separated list of dependent option keys

---

### read_key()

**Signature:** `read_key`

**Purpose:** Reads a single keypress (arrow keys, space, enter).

**Returns:** Outputs key name (UP, DOWN, SPACE, ENTER, etc.)

---

### interactive_select_options()

**Signature:** `interactive_select_options <title> <environment>`

**Purpose:** Displays interactive checkbox UI for option selection.

**Parameters:**
- `$1` (string) - Screen title
- `$2` (string) - Environment type

**Returns:**
- `0` - User confirmed selection
- `1` - User cancelled

**Example:**
```bash
define_drupal_options
if interactive_select_options "Installation Options" "development"; then
    # User confirmed, proceed with selected options
    generate_options_yaml
fi
```

---

### display_environment_options()

**Signature:** `display_environment_options <environment> [format]`

**Purpose:** Displays options in a non-interactive format.

**Parameters:**
- `$1` (string) - Environment type
- `$2` (string, optional) - Output format (list, table)

---

### load_existing_config()

**Signature:** `load_existing_config <sitename> [config_file]`

**Purpose:** Loads existing option configuration for a site from nwp.yml.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Config file path

---

### generate_options_yaml()

**Signature:** `generate_options_yaml`

**Purpose:** Generates YAML snippet for selected options.

**Returns:** Outputs YAML string

---

### generate_manual_steps()

**Signature:** `generate_manual_steps`

**Purpose:** Generates list of manual steps required for selected options.

**Returns:** Outputs manual steps as formatted text

---

## tui.sh

Unified TUI library for install and modify modes. Provides the main interactive installation interface.

### get_env_index()

**Signature:** `get_env_index <env_type>`

**Purpose:** Converts environment type to numeric index (0=dev, 1=stage, 2=live).

**Parameters:**
- `$1` (string) - Environment type

**Returns:** Outputs index number

---

### setup_install_action_option()

**Signature:** `setup_install_action_option <key> <install_action> <modify_action>`

**Purpose:** Defines what action to take for an option in install vs modify mode.

**Parameters:**
- `$1` (string) - Option key
- `$2` (string) - Install action (install, configure, manual, skip)
- `$3` (string) - Modify action

---

### setup_install_status_option()

**Signature:** `setup_install_status_option <key> <status>`

**Purpose:** Sets the installation status for an option.

**Parameters:**
- `$1` (string) - Option key
- `$2` (string) - Status (not_installed, installed, pending, etc.)

---

### build_env_option_list()

**Signature:** `build_env_option_list <environment>`

**Purpose:** Builds the list of options visible for an environment.

**Parameters:**
- `$1` (string) - Environment type

---

### get_checkbox_display()

**Signature:** `get_checkbox_display <key> <env_index> <is_current_env>`

**Purpose:** Gets the checkbox display string for an option (5-state model).

**Parameters:**
- `$1` (string) - Option key
- `$2` (integer) - Environment index
- `$3` (boolean) - Is current environment

**Returns:** Outputs checkbox string: `[✓]`, `[○]`, `[ ]`, `[~]`, or `[-]`

---

### draw_tui_screen()

**Signature:** `draw_tui_screen <mode> <sitename> <current_env>`

**Purpose:** Draws the main TUI screen.

**Parameters:**
- `$1` (string) - Mode (install, modify)
- `$2` (string) - Site name
- `$3` (string) - Current environment

---

### draw_tui_footer()

**Signature:** `draw_tui_footer <mode>`

**Purpose:** Draws the footer with key bindings.

**Parameters:**
- `$1` (string) - Mode (install, modify)

---

### show_option_docs()

**Signature:** `show_option_docs <key>`

**Purpose:** Shows detailed documentation for an option.

**Parameters:**
- `$1` (string) - Option key

---

### run_tui()

**Signature:** `run_tui <mode> <sitename> <environment>`

**Purpose:** Main TUI event loop.

**Parameters:**
- `$1` (string) - Mode (install, modify)
- `$2` (string) - Site name
- `$3` (string) - Environment type

**Returns:**
- `0` - User confirmed
- `1` - User cancelled

---

### load_recipe_defaults()

**Signature:** `load_recipe_defaults <recipe> [config_file]`

**Purpose:** Loads default options from a recipe definition.

**Parameters:**
- `$1` (string) - Recipe name
- `$2` (string, optional) - Config file path

---

## install-common.sh

Shared installation functions used across all recipe types (Drupal, Moodle, GitLab, etc.). Handles option application, recipe validation, and common setup tasks.

**Note:** Large library (1379 lines) with 35+ functions. Key functions documented below.

### run_interactive_options()

**Signature:** `run_interactive_options <recipe> <environment> [sitename]`

**Purpose:** Runs the interactive option selection TUI.

**Parameters:**
- `$1` (string) - Recipe name
- `$2` (string) - Environment type
- `$3` (string, optional) - Site name (for modify mode)

**Returns:**
- `0` - User confirmed selection
- `1` - User cancelled

---

### update_site_options()

**Signature:** `update_site_options <sitename> [config_file]`

**Purpose:** Updates site options in nwp.yml based on current selection.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Config file path

---

### show_installation_guide()

**Signature:** `show_installation_guide <sitename> <environment>`

**Purpose:** Displays manual installation steps for selected options.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - Environment type

---

### apply_drupal_options()

**Signature:** `apply_drupal_options`

**Purpose:** Applies selected Drupal options during installation.

---

### apply_moodle_options()

**Signature:** `apply_moodle_options`

**Purpose:** Applies selected Moodle options during installation.

---

### apply_gitlab_options()

**Signature:** `apply_gitlab_options`

**Purpose:** Applies selected GitLab options during installation.

---

### pre_register_live_dns()

**Signature:** `pre_register_live_dns <domain> <ip_address>`

**Purpose:** Pre-registers DNS records before live installation.

**Parameters:**
- `$1` (string) - Domain name
- `$2` (string) - IP address

**Returns:**
- `0` - DNS registered
- `1` - Registration failed

---

### get_recipe_value()

**Signature:** `get_recipe_value <recipe> <key> [config_file]`

**Purpose:** Gets a value from a recipe definition in nwp.yml.

**Parameters:**
- `$1` (string) - Recipe name
- `$2` (string) - Key name
- `$3` (string, optional) - Config file path

**Returns:** Outputs value or empty string

---

### get_recipe_list_value()

**Signature:** `get_recipe_list_value <recipe> <key> [config_file]`

**Purpose:** Gets a list/array value from a recipe definition.

**Parameters:**
- `$1` (string) - Recipe name
- `$2` (string) - Key name
- `$3` (string, optional) - Config file path

**Returns:** Outputs space-separated list

---

### get_root_value()

**Signature:** `get_root_value <key> [config_file]`

**Purpose:** Gets a value from the root level of nwp.yml.

**Parameters:**
- `$1` (string) - Key name
- `$2` (string, optional) - Config file path

**Returns:** Outputs value

---

### get_settings_value()

**Signature:** `get_settings_value <key> [config_file]`

**Purpose:** Gets a value from the settings section of nwp.yml.

**Parameters:**
- `$1` (string) - Key name
- `$2` (string, optional) - Config file path

**Returns:** Outputs value

---

### recipe_exists()

**Signature:** `recipe_exists <recipe> [config_file]`

**Purpose:** Checks if a recipe exists in nwp.yml.

**Parameters:**
- `$1` (string) - Recipe name
- `$2` (string, optional) - Config file path

**Returns:**
- `0` - Recipe exists
- `1` - Recipe not found

---

### list_recipes()

**Signature:** `list_recipes [config_file]`

**Purpose:** Lists all available recipes.

**Parameters:**
- `$1` (string, optional) - Config file path

**Returns:** Outputs list of recipe names

---

### validate_recipe()

**Signature:** `validate_recipe <recipe> [config_file]`

**Purpose:** Validates a recipe definition.

**Parameters:**
- `$1` (string) - Recipe name
- `$2` (string, optional) - Config file path

**Returns:**
- `0` - Recipe is valid
- `1` - Recipe has errors

---

### show_help()

**Signature:** `show_help`

**Purpose:** Displays help text for install.sh command.

---

### get_module_name_from_git_url()

**Signature:** `get_module_name_from_git_url <git_url>`

**Purpose:** Extracts module name from a Git URL.

**Parameters:**
- `$1` (string) - Git URL

**Returns:** Outputs module name

**Example:**
```bash
name=$(get_module_name_from_git_url "https://git.drupalcode.org/project/devel.git")
# Returns: devel
```

---

### is_git_url()

**Signature:** `is_git_url <url>`

**Purpose:** Checks if a string is a valid Git URL.

**Parameters:**
- `$1` (string) - URL to check

**Returns:**
- `0` - Valid Git URL
- `1` - Not a Git URL

---

### install_git_profile()

**Signature:** `install_git_profile <git_url> <profile_name>`

**Purpose:** Installs a Drupal profile from a Git repository.

**Parameters:**
- `$1` (string) - Git URL
- `$2` (string) - Profile name

**Returns:**
- `0` - Profile installed
- `1` - Installation failed

---

### install_git_modules()

**Signature:** `install_git_modules <module_list>`

**Purpose:** Installs Drupal modules from Git repositories.

**Parameters:**
- `$1` (string) - Space or comma-separated list of Git URLs

**Returns:**
- `0` - All modules installed
- `1` - One or more installations failed

---

### get_available_dirname()

**Signature:** `get_available_dirname <base_name>`

**Purpose:** Finds an available directory name by appending numbers if needed.

**Parameters:**
- `$1` (string) - Base directory name

**Returns:** Outputs available directory name

**Example:**
```bash
dir=$(get_available_dirname "mysite")
# If mysite exists, returns mysite_1, mysite_2, etc.
```

---

### should_run_step()

**Signature:** `should_run_step <step_number> <start_step>`

**Purpose:** Checks if an installation step should run.

**Parameters:**
- `$1` (integer) - Current step number
- `$2` (integer) - Start step number

**Returns:**
- `0` - Step should run
- `1` - Step should be skipped

---

### generate_live_settings()

**Signature:** `generate_live_settings <sitename> <domain>`

**Purpose:** Generates production settings.php configuration.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - Domain name

**Returns:**
- `0` - Settings generated
- `1` - Generation failed

**Security:** Uses secure database credentials from .secrets.data.yml.

---

### create_test_content()

**Signature:** `create_test_content <sitename> [content_type] [count]`

**Purpose:** Creates test content in a Drupal site.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Content type (default: article)
- `$3` (integer, optional) - Number of items (default: 10)

**Returns:**
- `0` - Content created
- `1` - Creation failed

---

## install-drupal.sh

Drupal/OpenSocial installation handler. Main entry point for Drupal site installations. Handles composer setup, DDEV configuration, profile installation, and module setup.

### install_drupal()

**Signature:** `install_drupal <recipe> <install_dir> [start_step] [purpose]`

**Purpose:** Main Drupal installation function with 9-step process.

**Parameters:**
- `$1` (string) - Recipe name
- `$2` (string) - Installation directory
- `$3` (integer, optional) - Start step number (default: 1)
- `$4` (string, optional) - Purpose (test, development, indefinite)

**Returns:**
- `0` - Installation successful
- `1` - Installation failed

**Steps:**
1. Create directory structure
2. Download/configure Drupal codebase via Composer
3. Generate .ddev/config.yaml
4. Start DDEV containers
5. Create or import database
6. Run Drupal site install
7. Install recipe modules
8. Import CMI configuration
9. Configure environment-specific settings

**Example:**
```bash
install_drupal "d" "mysite" 1 "indefinite"
```

---

### install_opensocial()

**Signature:** `install_opensocial <recipe> <install_dir> [start_step] [purpose]`

**Purpose:** Alias for install_drupal (backward compatibility).

**Parameters:** Same as install_drupal()

---

## install-moodle.sh

Moodle LMS installation handler. Handles Moodle-specific setup including git cloning, moodledata directory, and database installation.

### install_moodle()

**Signature:** `install_moodle <recipe> <install_dir> [start_step] [purpose]`

**Purpose:** Main Moodle installation function with 7-step process.

**Parameters:**
- `$1` (string) - Recipe name
- `$2` (string) - Installation directory
- `$3` (integer, optional) - Start step number (default: 1)
- `$4` (string, optional) - Purpose

**Returns:**
- `0` - Installation successful
- `1` - Installation failed

**Steps:**
1. Create directory structure
2. Clone Moodle from Git
3. Create moodledata directory
4. Generate .ddev/config.yaml
5. Start DDEV containers
6. Run Moodle CLI installation
7. Configure environment settings

**Example:**
```bash
install_moodle "moodle" "lms-site" 1 "development"
```

---

## install-gitlab.sh

GitLab CE installation handler via Docker. Creates docker-compose.yml and manages GitLab container lifecycle.

### install_gitlab()

**Signature:** `install_gitlab <recipe> <install_dir> [start_step] [purpose]`

**Purpose:** Installs GitLab CE using Docker Compose.

**Parameters:**
- `$1` (string) - Recipe name
- `$2` (string) - Installation directory
- `$3` (integer, optional) - Start step number (default: 1)
- `$4` (string, optional) - Purpose

**Returns:**
- `0` - Installation successful
- `1` - Installation failed

**Steps:**
1. Create directory structure (config, logs, data)
2. Create docker-compose.yml
3. Create environment files and README
4. Start GitLab containers (optional)

**Example:**
```bash
install_gitlab "gitlab" "git-server" 1 "indefinite"
```

---

## install-podcast.sh

Castopod podcast platform installation handler. Delegates to podcast.sh for setup.

### install_podcast()

**Signature:** `install_podcast <recipe> <install_dir> [start_step] [purpose]`

**Purpose:** Installs Castopod podcast platform.

**Parameters:**
- `$1` (string) - Recipe name
- `$2` (string) - Installation directory
- `$3` (integer, optional) - Start step number (default: 1)
- `$4` (string, optional) - Purpose

**Returns:**
- `0` - Installation successful
- `1` - Installation failed

**Example:**
```bash
install_podcast "podcast" "podcast.example.com"
```

---

## git.sh

Comprehensive Git operations library. Handles Git initialization, GitLab API integration, Composer package registry, and git bundle backups.

**Note:** Large library (1691 lines) with 60+ functions. Key functions documented below.

### get_gitlab_url()

**Signature:** `get_gitlab_url`

**Purpose:** Gets GitLab server URL from configuration.

**Returns:** Outputs GitLab URL

---

### get_gitlab_ssh_host()

**Signature:** `get_gitlab_ssh_host`

**Purpose:** Gets GitLab SSH host from configuration.

**Returns:** Outputs SSH host

---

### check_git_server_alias()

**Signature:** `check_git_server_alias`

**Purpose:** Checks if git server SSH alias is configured in ~/.ssh/config.

**Returns:**
- `0` - Alias configured
- `1` - Alias missing

---

### get_additional_remotes()

**Signature:** `get_additional_remotes <sitename>`

**Purpose:** Gets list of additional Git remotes for a site from nwp.yml.

**Parameters:**
- `$1` (string) - Site name

**Returns:** Outputs space-separated list of remotes

---

### git_add_remote()

**Signature:** `git_add_remote <name> <url>`

**Purpose:** Adds a Git remote to the current repository.

**Parameters:**
- `$1` (string) - Remote name
- `$2` (string) - Remote URL

**Returns:**
- `0` - Remote added
- `1` - Remote already exists or operation failed

---

### git_push_all()

**Signature:** `git_push_all [branch]`

**Purpose:** Pushes to all configured remotes.

**Parameters:**
- `$1` (string, optional) - Branch name (default: current branch)

**Returns:**
- `0` - All pushes successful
- `1` - One or more pushes failed

---

### git_setup_local_bare()

**Signature:** `git_setup_local_bare <sitename>`

**Purpose:** Creates a local bare repository for a site.

**Parameters:**
- `$1` (string) - Site name

**Returns:**
- `0` - Bare repo created
- `1` - Creation failed

---

### git_configure_remotes()

**Signature:** `git_configure_remotes <sitename>`

**Purpose:** Configures all remotes for a site from nwp.yml.

**Parameters:**
- `$1` (string) - Site name

**Returns:**
- `0` - Remotes configured
- `1` - Configuration failed

---

### git_init()

**Signature:** `git_init [directory]`

**Purpose:** Initializes a Git repository.

**Parameters:**
- `$1` (string, optional) - Directory path (default: current directory)

**Returns:**
- `0` - Repository initialized
- `1` - Initialization failed

---

### git_commit_backup()

**Signature:** `git_commit_backup [message]`

**Purpose:** Creates a backup commit with timestamp.

**Parameters:**
- `$1` (string, optional) - Commit message prefix

**Returns:**
- `0` - Commit created
- `1` - Commit failed

---

### get_gitlab_default_group()

**Signature:** `get_gitlab_default_group`

**Purpose:** Gets the default GitLab group from configuration.

**Returns:** Outputs group name or empty string

---

### get_gitlab_token()

**Signature:** `get_gitlab_token`

**Purpose:** Gets GitLab API token from secrets.

**Returns:** Outputs API token

---

### gitlab_api_create_project()

**Signature:** `gitlab_api_create_project <name> <group> [visibility]`

**Purpose:** Creates a GitLab project via API.

**Parameters:**
- `$1` (string) - Project name
- `$2` (string) - Group name
- `$3` (string, optional) - Visibility (private, internal, public)

**Returns:**
- `0` - Project created
- `1` - Creation failed

---

### gitlab_api_delete_project()

**Signature:** `gitlab_api_delete_project <project_id>`

**Purpose:** Deletes a GitLab project via API.

**Parameters:**
- `$1` (string) - Project ID

**Returns:**
- `0` - Project deleted
- `1` - Deletion failed

**Security:** Destructive operation.

---

### gitlab_api_list_projects()

**Signature:** `gitlab_api_list_projects [group]`

**Purpose:** Lists GitLab projects.

**Parameters:**
- `$1` (string, optional) - Filter by group name

**Returns:** Outputs JSON array of projects

---

### gitlab_api_configure_project()

**Signature:** `gitlab_api_configure_project <project_id> <settings...>`

**Purpose:** Configures GitLab project settings via API.

**Parameters:**
- `$1` (string) - Project ID
- `$@` (string) - Additional settings as key=value pairs

**Returns:**
- `0` - Settings updated
- `1` - Update failed

---

### gitlab_api_unprotect_branch()

**Signature:** `gitlab_api_unprotect_branch <project_id> <branch>`

**Purpose:** Removes branch protection from a GitLab branch.

**Parameters:**
- `$1` (string) - Project ID
- `$2` (string) - Branch name

**Returns:**
- `0` - Protection removed
- `1` - Operation failed

---

### git_init_repo()

**Signature:** `git_init_repo <sitename> [directory]`

**Purpose:** Initializes Git repository for a site with NWP conventions.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Directory path

**Returns:**
- `0` - Repository initialized
- `1` - Initialization failed

---

### git_create_gitignore()

**Signature:** `git_create_gitignore <type>`

**Purpose:** Creates a .gitignore file for Drupal/Moodle/etc.

**Parameters:**
- `$1` (string) - Type (drupal, moodle, wordpress, etc.)

**Returns:**
- `0` - .gitignore created
- `1` - Creation failed

---

### git_setup_remote()

**Signature:** `git_setup_remote <sitename> <remote_type>`

**Purpose:** Sets up a remote (GitLab, local bare, etc.) for a site.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - Remote type (gitlab, local, github, etc.)

**Returns:**
- `0` - Remote configured
- `1` - Configuration failed

---

### git_commit()

**Signature:** `git_commit <message> [options]`

**Purpose:** Creates a Git commit with NWP conventions.

**Parameters:**
- `$1` (string) - Commit message
- `$@` (string, optional) - Additional git commit options

**Returns:**
- `0` - Commit created
- `1` - Commit failed

---

### gitlab_create_project()

**Signature:** `gitlab_create_project <sitename> [group] [visibility]`

**Purpose:** Creates a GitLab project and configures it for a site.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Group name
- `$3` (string, optional) - Visibility level

**Returns:**
- `0` - Project created
- `1` - Creation failed

---

### git_push()

**Signature:** `git_push [remote] [branch]`

**Purpose:** Pushes to a remote with error handling.

**Parameters:**
- `$1` (string, optional) - Remote name (default: origin)
- `$2` (string, optional) - Branch name (default: current branch)

**Returns:**
- `0` - Push successful
- `1` - Push failed

---

### git_backup()

**Signature:** `git_backup <sitename> [backup_dir]`

**Purpose:** Creates a full Git backup for a site.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Backup directory

**Returns:**
- `0` - Backup created
- `1` - Backup failed

---

### gitlab_get_group_id()

**Signature:** `gitlab_get_group_id <group_name>`

**Purpose:** Gets GitLab group ID by name.

**Parameters:**
- `$1` (string) - Group name

**Returns:** Outputs group ID or empty string

---

### gitlab_get_project_id()

**Signature:** `gitlab_get_project_id <project_path>`

**Purpose:** Gets GitLab project ID by path.

**Parameters:**
- `$1` (string) - Project path (group/project)

**Returns:** Outputs project ID or empty string

---

### gitlab_composer_publish()

**Signature:** `gitlab_composer_publish <sitename> [version]`

**Purpose:** Publishes a site as a Composer package to GitLab package registry.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Version number (default: auto-detect from git tag)

**Returns:**
- `0` - Package published
- `1` - Publish failed

---

### gitlab_composer_list()

**Signature:** `gitlab_composer_list [group]`

**Purpose:** Lists Composer packages in GitLab package registry.

**Parameters:**
- `$1` (string, optional) - Group name filter

**Returns:** Outputs list of packages

---

### gitlab_composer_create_deploy_token()

**Signature:** `gitlab_composer_create_deploy_token <project_id> <name>`

**Purpose:** Creates a GitLab deploy token for Composer authentication.

**Parameters:**
- `$1` (string) - Project ID
- `$2` (string) - Token name

**Returns:** Outputs token credentials

**Security:** Credentials should be stored in .secrets.yml.

---

### gitlab_composer_configure_client()

**Signature:** `gitlab_composer_configure_client <sitename>`

**Purpose:** Configures Composer to use GitLab package registry.

**Parameters:**
- `$1` (string) - Site name

**Returns:**
- `0` - Configuration successful
- `1` - Configuration failed

---

### gitlab_composer_repo_url()

**Signature:** `gitlab_composer_repo_url <group_id>`

**Purpose:** Generates GitLab Composer repository URL.

**Parameters:**
- `$1` (string) - Group ID

**Returns:** Outputs repository URL

---

### gitlab_composer_check()

**Signature:** `gitlab_composer_check`

**Purpose:** Checks GitLab Composer package registry configuration.

**Returns:**
- `0` - Configuration valid
- `1` - Configuration invalid

---

### gitlab_create_user()

**Signature:** `gitlab_create_user <username> <email> <password>`

**Purpose:** Creates a GitLab user via API.

**Parameters:**
- `$1` (string) - Username
- `$2` (string) - Email address
- `$3` (string) - Password

**Returns:**
- `0` - User created
- `1` - Creation failed

---

### gitlab_add_user_ssh_key()

**Signature:** `gitlab_add_user_ssh_key <user_id> <key_title> <public_key>`

**Purpose:** Adds SSH key to a GitLab user.

**Parameters:**
- `$1` (string) - User ID
- `$2` (string) - Key title
- `$3` (string) - Public key content

**Returns:**
- `0` - Key added
- `1` - Operation failed

---

### gitlab_add_user_to_group()

**Signature:** `gitlab_add_user_to_group <user_id> <group_id> <access_level>`

**Purpose:** Adds a user to a GitLab group.

**Parameters:**
- `$1` (string) - User ID
- `$2` (string) - Group ID
- `$3` (string) - Access level (guest, reporter, developer, maintainer, owner)

**Returns:**
- `0` - User added
- `1` - Operation failed

---

### gitlab_list_users()

**Signature:** `gitlab_list_users [search]`

**Purpose:** Lists GitLab users.

**Parameters:**
- `$1` (string, optional) - Search query

**Returns:** Outputs JSON array of users

---

### git_bundle_full()

**Signature:** `git_bundle_full <output_file>`

**Purpose:** Creates a full Git bundle backup.

**Parameters:**
- `$1` (string) - Output bundle file path

**Returns:**
- `0` - Bundle created
- `1` - Creation failed

---

### git_bundle_incremental()

**Signature:** `git_bundle_incremental <output_file> <since_ref>`

**Purpose:** Creates an incremental Git bundle since a reference.

**Parameters:**
- `$1` (string) - Output bundle file path
- `$2` (string) - Git reference (tag, commit, HEAD~10, etc.)

**Returns:**
- `0` - Bundle created
- `1` - Creation failed

---

### git_bundle_verify()

**Signature:** `git_bundle_verify <bundle_file>`

**Purpose:** Verifies a Git bundle file integrity.

**Parameters:**
- `$1` (string) - Bundle file path

**Returns:**
- `0` - Bundle is valid
- `1` - Bundle is corrupted

---

### git_bundle_list()

**Signature:** `git_bundle_list <bundle_file>`

**Purpose:** Lists contents of a Git bundle.

**Parameters:**
- `$1` (string) - Bundle file path

**Returns:** Outputs bundle contents

---

### git_bundle_backup()

**Signature:** `git_bundle_backup <sitename> [backup_dir]`

**Purpose:** Creates a timestamped Git bundle backup for a site.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Backup directory

**Returns:**
- `0` - Backup created
- `1` - Backup failed

---

## testing.sh

Multi-tier testing system with 8 test types and 5 presets. Integrates PHPUnit, Behat, PHPStan, PHPCS, ESLint, Stylelint, security scanning, and accessibility checks.

### run_tests()

**Signature:** `run_tests <sitename> [selection] [options]`

**Purpose:** Main test runner that executes selected test types.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Test selection (quick, essential, functional, full, security-only, or comma-separated types)
- `$3` (string, optional) - Additional test options

**Returns:**
- `0` - All tests passed
- `1` - One or more tests failed

**Example:**
```bash
run_tests "mysite" "essential"
run_tests "mysite" "phpunit,behat" "--verbose"
```

---

### run_phpunit()

**Signature:** `run_phpunit <sitename> [options]`

**Purpose:** Runs PHPUnit unit and integration tests.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - PHPUnit options

**Returns:**
- `0` - Tests passed
- `1` - Tests failed

---

### run_behat()

**Signature:** `run_behat <sitename> [tags]`

**Purpose:** Runs Behat BDD scenario tests.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Behat tags filter

**Returns:**
- `0` - Tests passed
- `1` - Tests failed

---

### run_phpstan()

**Signature:** `run_phpstan <sitename> [level]`

**Purpose:** Runs PHPStan static analysis.

**Parameters:**
- `$1` (string) - Site name
- `$2` (integer, optional) - Analysis level (0-9, default: 6)

**Returns:**
- `0` - Analysis passed
- `1` - Issues found

---

### run_phpcs()

**Signature:** `run_phpcs <sitename> [standard]`

**Purpose:** Runs PHP CodeSniffer style checks.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Coding standard (Drupal, DrupalPractice, etc.)

**Returns:**
- `0` - No issues
- `1` - Issues found

---

### run_eslint()

**Signature:** `run_eslint <sitename>`

**Purpose:** Runs ESLint JavaScript/TypeScript linting.

**Parameters:**
- `$1` (string) - Site name

**Returns:**
- `0` - No issues
- `1` - Issues found

---

### run_stylelint()

**Signature:** `run_stylelint <sitename>`

**Purpose:** Runs Stylelint CSS/SCSS linting.

**Parameters:**
- `$1` (string) - Site name

**Returns:**
- `0` - No issues
- `1` - Issues found

---

### run_security()

**Signature:** `run_security <sitename>`

**Purpose:** Runs security vulnerability scanning (Composer audit, Drush pm:security).

**Parameters:**
- `$1` (string) - Site name

**Returns:**
- `0` - No vulnerabilities
- `1` - Vulnerabilities found

---

### run_accessibility()

**Signature:** `run_accessibility <sitename> [url]`

**Purpose:** Runs WCAG accessibility checks (if pa11y is installed).

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - URL to test

**Returns:**
- `0` - No issues
- `1` - Issues found

---

### list_test_types()

**Signature:** `list_test_types`

**Purpose:** Lists all available test types with descriptions.

**Returns:** Outputs formatted list

---

### list_test_presets()

**Signature:** `list_test_presets`

**Purpose:** Lists all test presets with descriptions and estimated duration.

**Returns:** Outputs formatted list

---

### estimate_test_duration()

**Signature:** `estimate_test_duration <selection>`

**Purpose:** Estimates test duration in minutes for a selection.

**Parameters:**
- `$1` (string) - Test selection (preset or types)

**Returns:** Outputs duration in minutes

**Example:**
```bash
duration=$(estimate_test_duration "essential")  # Returns "5"
```

---

### check_available_tests()

**Signature:** `check_available_tests <sitename>`

**Purpose:** Detects which test types are available for a site.

**Parameters:**
- `$1` (string) - Site name

**Returns:** Outputs comma-separated list of available types

---

### validate_test_selection()

**Signature:** `validate_test_selection <selection>`

**Purpose:** Validates a test selection string.

**Parameters:**
- `$1` (string) - Test selection

**Returns:**
- `0` - Selection is valid
- `1` - Selection is invalid

---

## database-router.sh

Multi-source database management with intelligent source selection. Handles production downloads, backup imports, development cloning, and URL-based imports.

### download_database()

**Signature:** `download_database <sitename> [source]`

**Purpose:** Main database download function with intelligent routing.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Source (auto, production, backup, development, url)

**Returns:**
- `0` - Database downloaded
- `1` - Download failed

**Example:**
```bash
download_database "mysite" "production"
```

---

### download_db_auto()

**Signature:** `download_db_auto <sitename>`

**Purpose:** Automatically selects best database source using priority system.

**Parameters:**
- `$1` (string) - Site name

**Returns:**
- `0` - Database downloaded
- `1` - No sources available

**Priority:**
1. Recent sanitized backup (< 24 hours)
2. Production server (if accessible)
3. Recent non-sanitized backup (< 7 days)
4. Development database (clone)

---

### download_db_production()

**Signature:** `download_db_production <sitename>`

**Purpose:** Downloads database from production server.

**Parameters:**
- `$1` (string) - Site name

**Returns:**
- `0` - Database downloaded
- `1` - Download failed

**Dependencies:** Requires live configuration in nwp.yml with SSH access.

---

### download_db_backup()

**Signature:** `download_db_backup <sitename> [backup_file]`

**Purpose:** Imports database from a backup file.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Backup file path (prompts if not provided)

**Returns:**
- `0` - Database imported
- `1` - Import failed

---

### download_db_development()

**Signature:** `download_db_development <sitename>`

**Purpose:** Clones database from development environment.

**Parameters:**
- `$1` (string) - Site name

**Returns:**
- `0` - Database cloned
- `1` - Clone failed

---

### download_db_url()

**Signature:** `download_db_url <sitename> <url>`

**Purpose:** Downloads database from a URL.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - Database dump URL

**Returns:**
- `0` - Database downloaded
- `1` - Download failed

**Security:** Validates URL format. Use HTTPS URLs when possible.

---

### sanitize_staging_db()

**Signature:** `sanitize_staging_db <sitename>`

**Purpose:** Sanitizes database for staging environment (GDPR compliance).

**Parameters:**
- `$1` (string) - Site name

**Returns:**
- `0` - Sanitization successful
- `1` - Sanitization failed

**Security:** Removes/anonymizes emails, passwords, PII, and truncates logs.

---

### create_sanitized_backup()

**Signature:** `create_sanitized_backup <sitename> [backup_dir]`

**Purpose:** Creates a sanitized database backup.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Backup directory

**Returns:**
- `0` - Backup created
- `1` - Backup failed

---

### list_backups()

**Signature:** `list_backups <sitename> [count]`

**Purpose:** Lists available database backups for a site.

**Parameters:**
- `$1` (string) - Site name
- `$2` (integer, optional) - Number of backups to show (default: 10)

**Returns:** Outputs list of backups with timestamps and sizes

---

### get_recommended_db_source()

**Signature:** `get_recommended_db_source <sitename>`

**Purpose:** Returns recommended database source based on available options.

**Parameters:**
- `$1` (string) - Site name

**Returns:** Outputs recommended source name (production, backup, development)

---

## preflight.sh

Pre-installation checks and validation. Verifies system requirements, dependencies, and configuration before installation begins.

**Note:** Documentation for preflight.sh functions needs to be expanded. This library performs system validation and prerequisite checks.

---

## state.sh

Site state detection library. Determines if sites exist, are running, and provides environment status information.

**Note:** Documentation for state.sh functions needs to be expanded. This library provides site discovery and status checking.

---

## badges.sh

Status badge generation for README files and dashboards. Creates SVG badges for build status, coverage, and other metrics.

**Note:** Documentation for badges.sh functions needs to be expanded.

---

## podcast.sh

Podcast platform (Castopod) operations. Manages Castopod installation, configuration, and Backblaze B2 storage integration.

**Note:** Documentation for podcast.sh functions needs to be expanded. This library handles Castopod-specific operations.

---

## avc-moodle.sh

AVC-specific Moodle integration. Custom functions for Adult Vacation Camp (AVC) Moodle sites.

**Note:** Documentation for avc-moodle.sh functions needs to be expanded. This is project-specific code.

---

## b2.sh

Backblaze B2 storage operations. Manages B2 buckets, uploads, and CDN integration.

**Note:** Documentation for b2.sh functions needs to be expanded. This library provides B2 cloud storage integration.

---

## developer.sh

Developer workflow tools. Provides shortcuts and automation for common development tasks.

**Note:** Documentation for developer.sh functions needs to be expanded.

---

## live-server-setup.sh

Production server provisioning and configuration. Automates Linode instance creation, security hardening, and web server setup.

**Note:** Documentation for live-server-setup.sh functions needs to be expanded. This library handles production infrastructure.

---

## sanitize.sh

Database sanitization for GDPR compliance. Removes/anonymizes PII, emails, passwords, and sensitive data.

**Note:** Documentation for sanitize.sh functions needs to be expanded. This is critical for data protection.

---

## server-scan.sh

Remote server scanning to discover Drupal sites. Scans /var/www/ and identifies Drupal installations.

**Note:** Documentation for server-scan.sh functions needs to be expanded. Used by import system.

---

## rollback.sh

Installation rollback functionality. Allows reverting failed installations to clean state.

**Note:** Documentation for rollback.sh functions needs to be expanded.

---

## frontend.sh

Frontend asset management (CSS, JavaScript, images). Handles asset compilation, minification, and optimization.

**Note:** Documentation for frontend.sh functions needs to be expanded.

---

## env-generate.sh

**Note:** This is a standalone script (not sourced as library). Generates .env files from nwp.yml and templates.

**Main Script Purpose:** Reads recipe configuration from nwp.yml and generates .env file with substituted variables.

**Usage:**
```bash
./lib/env-generate.sh <recipe> <sitename> [site_dir]
```

**Functions in script:**
- `read_recipe_config()` - Reads recipe-specific config values
- `read_setting()` - Reads global settings
- `read_service_config()` - Reads service configuration with fallbacks
- `read_config_with_fallback()` - Reads config with recipe → settings → default fallback

---

## ddev-generate.sh

**Note:** This is a standalone script (not sourced as library). Generates DDEV configuration from .env and nwp.yml.

**Main Script Purpose:** Creates .ddev/config.yaml based on project settings.

**Usage:**
```bash
./lib/ddev-generate.sh [site_dir]
```

---

## install-steps.sh

Installation step definitions and tracking. Defines steps for each environment type and provides progress tracking.

### get_steps_for_env()

**Signature:** `get_steps_for_env <environment>`

**Purpose:** Returns all installation steps for an environment.

**Parameters:**
- `$1` (string) - Environment (dev, stage, live, prod)

**Returns:** Outputs steps (one per line)

---

### get_total_steps()

**Signature:** `get_total_steps <environment>`

**Purpose:** Returns total number of steps for an environment.

**Parameters:**
- `$1` (string) - Environment

**Returns:** Outputs step count

---

### get_step_info()

**Signature:** `get_step_info <step_number> <environment>`

**Purpose:** Returns information about a specific step.

**Parameters:**
- `$1` (integer) - Step number
- `$2` (string) - Environment

**Returns:** Outputs "key:title:description"

---

### get_step_title()

**Signature:** `get_step_title <step_number> <environment>`

**Purpose:** Returns the title of a step.

**Parameters:**
- `$1` (integer) - Step number
- `$2` (string) - Environment

**Returns:** Outputs step title

---

### get_step_key()

**Signature:** `get_step_key <step_number> <environment>`

**Purpose:** Returns the key identifier of a step.

**Parameters:**
- `$1` (integer) - Step number
- `$2` (string) - Environment

**Returns:** Outputs step key

---

### get_step_description()

**Signature:** `get_step_description <step_number> <environment>`

**Purpose:** Returns the description of a step.

**Parameters:**
- `$1` (integer) - Step number
- `$2` (string) - Environment

**Returns:** Outputs step description

---

### get_install_step()

**Signature:** `get_install_step <sitename> [config_file]`

**Purpose:** Gets current installation step for a site from nwp.yml.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Config file path

**Returns:** Outputs step number (0 = not started, -1 = complete)

---

### is_install_complete()

**Signature:** `is_install_complete <sitename> [config_file] [environment]`

**Purpose:** Checks if installation is complete for a site.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Config file path
- `$3` (string, optional) - Environment

**Returns:**
- `0` - Installation complete
- `1` - Installation incomplete

---

### set_install_step()

**Signature:** `set_install_step <sitename> <step_number> [config_file]`

**Purpose:** Sets the current installation step in nwp.yml.

**Parameters:**
- `$1` (string) - Site name
- `$2` (integer) - Step number
- `$3` (string, optional) - Config file path

**Returns:**
- `0` - Step updated
- `1` - Update failed

---

### mark_install_complete()

**Signature:** `mark_install_complete <sitename> [config_file]`

**Purpose:** Marks installation as complete for a site.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Config file path

---

### get_install_status_display()

**Signature:** `get_install_status_display <sitename> [config_file] [environment]`

**Purpose:** Returns formatted installation status string.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Config file path
- `$3` (string, optional) - Environment

**Returns:** Outputs status string (e.g., "Complete (10/10 steps)", "Stopped at step 5")

---

### get_install_status_color()

**Signature:** `get_install_status_color <sitename> [config_file] [environment]`

**Purpose:** Returns color code for installation status.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Config file path
- `$3` (string, optional) - Environment

**Returns:** Outputs color name (green, yellow, dim)

---

### show_steps_detail()

**Signature:** `show_steps_detail <sitename> [config_file] [environment]`

**Purpose:** Displays detailed list of installation steps with status.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Config file path
- `$3` (string, optional) - Environment

---

### is_site_actually_installed()

**Signature:** `is_site_actually_installed <sitename> [config_file]`

**Purpose:** Checks if site appears installed regardless of tracking status.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Config file path

**Returns:**
- `0` - Site appears installed
- `1` - Site not installed

---

## safe-ops.sh

AI-safe proxy operations. Provides sanitized output for operations that use production credentials. Claude Code can safely call these functions.

**Security Model:** These functions internally use data secrets but never expose credentials or user data in output.

### safe_server_status()

**Signature:** `safe_server_status <server_name>`

**Purpose:** Gets sanitized server status (no credentials or user data).

**Parameters:**
- `$1` (string) - Server name from .secrets.data.yml

**Returns:** Outputs sanitized status: Status, Uptime, Load, Memory, Disk

**Security:** Uses SSH credentials internally but outputs only system metrics.

**Example:**
```bash
safe_server_status prod1
```

---

### safe_site_status()

**Signature:** `safe_site_status <sitename>`

**Purpose:** Gets sanitized Drupal site status (no credentials).

**Parameters:**
- `$1` (string) - Site name

**Returns:** Outputs DDEV status and Drupal version info

---

### safe_db_status()

**Signature:** `safe_db_status <sitename>`

**Purpose:** Gets sanitized database info (no credentials, no actual data).

**Parameters:**
- `$1` (string) - Site name

**Returns:** Outputs table count, size, last backup time

**Security:** Returns metadata only, no actual database contents.

---

### safe_deploy()

**Signature:** `safe_deploy <sitename> [environment]`

**Purpose:** Returns deployment status/command (does not actually deploy).

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Environment (default: staging)

**Returns:** Outputs status message with manual command

**Security:** Does not perform deployments automatically. Requires manual confirmation.

---

### safe_backup_list()

**Signature:** `safe_backup_list <sitename>`

**Purpose:** Lists recent backups (filenames and sizes only, no contents).

**Parameters:**
- `$1` (string) - Site name

**Returns:** Outputs backup filenames with sizes

---

### safe_backup_create()

**Signature:** `safe_backup_create <sitename>`

**Purpose:** Returns backup command (does not create backup).

**Parameters:**
- `$1` (string) - Site name

**Returns:** Outputs manual backup command

**Security:** Does not access production data. Returns command for manual execution.

---

### safe_recent_errors()

**Signature:** `safe_recent_errors <sitename>`

**Purpose:** Gets error summary (counts and types, not actual messages).

**Parameters:**
- `$1` (string) - Site name

**Returns:** Outputs error type counts

**Security:** Returns aggregated data only, no PII or error messages.

---

### safe_security_check()

**Signature:** `safe_security_check <sitename>`

**Purpose:** Checks for security updates (count only, no credentials).

**Parameters:**
- `$1` (string) - Site name

**Returns:** Outputs count of available security updates

---

## terminal.sh

Minimal terminal control functions for cursor positioning and screen clearing.

### cursor_to()

**Signature:** `cursor_to <row> <col>`

**Purpose:** Moves cursor to specific row and column.

**Parameters:**
- `$1` (integer) - Row number
- `$2` (integer) - Column number

---

### cursor_hide()

**Signature:** `cursor_hide`

**Purpose:** Hides the terminal cursor.

---

### cursor_show()

**Signature:** `cursor_show`

**Purpose:** Shows the terminal cursor.

---

### clear_screen()

**Signature:** `clear_screen`

**Purpose:** Clears the entire screen and moves cursor to top.

---

### clear_line()

**Signature:** `clear_line`

**Purpose:** Clears the current line.

---

### read_key()

**Signature:** `read_key`

**Purpose:** Reads a single keypress including arrow keys.

**Returns:** Outputs key name (UP, DOWN, LEFT, RIGHT, ENTER, SPACE, ESC, or character)

---

## cli-register.sh

CLI command registration system. Manages registration of NWP CLI commands (pl, pl1, pl2, etc.) in /usr/local/bin.

### get_cli_command()

**Signature:** `get_cli_command`

**Purpose:** Gets the current CLI command name from nwp.yml.

**Returns:** Outputs CLI command name (default: pl)

---

### find_available_cli_name()

**Signature:** `find_available_cli_name <project_root>`

**Purpose:** Finds the next available CLI command name.

**Parameters:**
- `$1` (string) - Project root to check against

**Returns:** Outputs available command name (pl, pl1, pl2, etc.)

---

### register_cli_command()

**Signature:** `register_cli_command [project_root] [preferred_name]`

**Purpose:** Registers CLI command in /usr/local/bin and nwp.yml.

**Parameters:**
- `$1` (string, optional) - Project root directory
- `$2` (string, optional) - Preferred command name

**Returns:**
- `0` - Registration successful
- `1` - Registration failed

**Security:** Creates symlink in /usr/local/bin (requires sudo).

**Example:**
```bash
register_cli_command "$PWD" "pl"
```

---

### unregister_cli_command()

**Signature:** `unregister_cli_command`

**Purpose:** Unregisters CLI command from /usr/local/bin and nwp.yml.

**Returns:**
- `0` - Unregistration successful
- `1` - Unregistration failed

**Security:** Removes symlink from /usr/local/bin (requires sudo).

---

## dev2stg-tui.sh

Dev-to-staging TUI for deployment planning. Interactive interface for dev2stg.sh command.

**Note:** This is a comprehensive TUI library for the dev2stg workflow. Key functions documented below.

### load_tui_state()

**Signature:** `load_tui_state <sitename>`

**Purpose:** Loads site state into TUI variables.

**Parameters:**
- `$1` (string) - Site name

**Sets:** TUI_DEV_EXISTS, TUI_STG_EXISTS, TUI_BACKUP_AGE, TUI_PROD_ACCESSIBLE, etc.

---

### run_dev2stg_tui()

**Signature:** `run_dev2stg_tui <sitename>`

**Purpose:** Runs the interactive dev2stg TUI.

**Parameters:**
- `$1` (string) - Site name

**Returns:**
- `0` - User confirmed, proceed with deployment
- `1` - User cancelled

**Sets:** TUI_DB_SOURCE, TUI_TEST_SELECTION

---

### prompt_db_source()

**Signature:** `prompt_db_source <sitename>`

**Purpose:** Simple database source prompt (non-TUI mode).

**Parameters:**
- `$1` (string) - Site name

**Sets:** TUI_DB_SOURCE

---

### prompt_test_selection()

**Signature:** `prompt_test_selection`

**Purpose:** Simple test selection prompt (non-TUI mode).

**Sets:** TUI_TEST_SELECTION

---

## import-tui.sh

Import system TUI components. Provides interactive interfaces for server selection, site selection, and options configuration.

**Note:** Large TUI library (823 lines) with 20+ functions. Key functions documented below.

### select_server()

**Signature:** `select_server [config_file]`

**Purpose:** Displays server selection menu.

**Parameters:**
- `$1` (string, optional) - Config file path

**Returns:**
- `0` - Server selected
- `1` - User cancelled

**Sets:** SELECTED_SERVER_NAME, SELECTED_SSH_HOST, SELECTED_SSH_KEY

---

### show_scanning_progress()

**Signature:** `show_scanning_progress <server_name> <ssh_host>`

**Purpose:** Shows scanning progress screen.

**Parameters:**
- `$1` (string) - Server name
- `$2` (string) - SSH host

---

### select_sites_to_import()

**Signature:** `select_sites_to_import`

**Purpose:** Displays discovered sites and allows selection.

**Returns:**
- `0` - Sites selected
- `1` - User cancelled

**Uses:** DISCOVERED_SITES array

**Sets:** SELECTED_SITES array

---

### configure_import_options()

**Signature:** `configure_import_options <site_name>`

**Purpose:** Configures import options for a site.

**Parameters:**
- `$1` (string) - Site name

**Returns:**
- `0` - Options confirmed
- `1` - User cancelled

**Uses/Sets:** IMPORT_OPTIONS array

---

### configure_all_import_options()

**Signature:** `configure_all_import_options`

**Purpose:** Configures options for all selected sites.

**Returns:**
- `0` - All options configured
- `1` - User cancelled

---

### confirm_import()

**Signature:** `confirm_import`

**Purpose:** Shows confirmation screen before import.

**Returns:**
- `0` - User confirmed
- `1` - User cancelled

---

### show_import_progress()

**Signature:** `show_import_progress <site_name> <current_step> <total_sites> <current_site_num>`

**Purpose:** Shows import progress screen.

**Parameters:**
- `$1` (string) - Site name
- `$2` (integer) - Current step
- `$3` (integer) - Total sites
- `$4` (integer) - Current site number

---

### complete_import_step()

**Signature:** `complete_import_step <step_num> [duration]`

**Purpose:** Marks an import step as complete.

**Parameters:**
- `$1` (integer) - Step number
- `$2` (string, optional) - Duration string

---

### show_import_complete()

**Signature:** `show_import_complete <results_array>`

**Purpose:** Shows import completion summary.

**Parameters:**
- `$1` (array ref) - Results array (name|url|duration|status)

---

### get_import_option()

**Signature:** `get_import_option <site_name> <option_key>`

**Purpose:** Gets an import option value for a site.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - Option key

**Returns:** Outputs option value (y/n)

---

### option_enabled()

**Signature:** `option_enabled <site_name> <option_key>`

**Purpose:** Checks if an import option is enabled.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - Option key

**Returns:**
- `0` - Option is enabled
- `1` - Option is disabled

---

### get_local_site_name()

**Signature:** `get_local_site_name <remote_site_name>`

**Purpose:** Gets local site name with conflict resolution.

**Parameters:**
- `$1` (string) - Remote site name

**Returns:** Outputs available local name (appends _1, _2, etc. if needed)

---

## import.sh

Site import operations. Core functions for importing sites from remote servers. Works with import-tui.sh and server-scan.sh.

**Note:** Large library (651 lines) with 15+ step functions and main import orchestrator.

### import_step_create_directory()

**Signature:** `import_step_create_directory <site_name> [webroot_name]`

**Purpose:** Creates local directory structure for imported site.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Webroot name (default: web)

**Returns:**
- `0` - Directory created
- `1` - Creation failed

---

### import_step_configure_ddev()

**Signature:** `import_step_configure_ddev <site_name> [webroot_name] [php_version] [db_type]`

**Purpose:** Configures DDEV for imported site.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Webroot name (default: web)
- `$3` (string, optional) - PHP version (default: 8.2)
- `$4` (string, optional) - Database type (default: mariadb:10.11)

**Returns:**
- `0` - DDEV configured
- `1` - Configuration failed

---

### import_step_pull_database()

**Signature:** `import_step_pull_database <site_name> <ssh_target> <ssh_key> <remote_site_dir>`

**Purpose:** Pulls database from remote server via Drush.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - SSH target (user@host)
- `$3` (string) - SSH key path
- `$4` (string) - Remote site directory

**Returns:**
- `0` - Database pulled
- `1` - Pull failed

---

### import_step_pull_files()

**Signature:** `import_step_pull_files <site_name> <ssh_target> <ssh_key> <remote_site_dir> [webroot_name] [full_sync]`

**Purpose:** Pulls files from remote server via rsync.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - SSH target
- `$3` (string) - SSH key path
- `$4` (string) - Remote site directory
- `$5` (string, optional) - Webroot name (default: web)
- `$6` (string, optional) - Full sync flag (y/n, default: n)

**Returns:**
- `0` - Files pulled
- `1` - Pull failed

**Note:** If full_sync=n, only pulls essential files (composer.json, config, custom modules/themes).

---

### import_step_import_database()

**Signature:** `import_step_import_database <site_name>`

**Purpose:** Imports database into DDEV.

**Parameters:**
- `$1` (string) - Site name

**Returns:**
- `0` - Database imported
- `1` - Import failed

---

### import_step_sanitize_database()

**Signature:** `import_step_sanitize_database <site_name>`

**Purpose:** Sanitizes database for GDPR compliance.

**Parameters:**
- `$1` (string) - Site name

**Returns:**
- `0` - Sanitization successful
- `1` - Sanitization failed (non-fatal)

---

### import_step_configure_settings()

**Signature:** `import_step_configure_settings <site_name> [webroot_name]`

**Purpose:** Configures local settings.php and settings.local.php.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string, optional) - Webroot name (default: web)

**Returns:**
- `0` - Settings configured

---

### import_step_configure_stage_file_proxy()

**Signature:** `import_step_configure_stage_file_proxy <site_name> <origin_url>`

**Purpose:** Configures Stage File Proxy module.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - Origin URL (production URL for file downloads)

**Returns:**
- `0` - Stage File Proxy configured

---

### import_step_clear_caches()

**Signature:** `import_step_clear_caches <site_name>`

**Purpose:** Clears Drupal caches.

**Parameters:**
- `$1` (string) - Site name

**Returns:**
- `0` - Caches cleared

---

### import_step_verify_site()

**Signature:** `import_step_verify_site <site_name>`

**Purpose:** Verifies site boots successfully.

**Parameters:**
- `$1` (string) - Site name

**Returns:**
- `0` - Site boots (non-fatal if fails)

---

### import_step_register_site()

**Signature:** `import_step_register_site <site_name> <ssh_target> <remote_webroot> [drupal_version] [config_file]`

**Purpose:** Registers imported site in nwp.yml.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - SSH target
- `$3` (string) - Remote webroot path
- `$4` (string, optional) - Drupal version
- `$5` (string, optional) - Config file path

**Returns:**
- `0` - Site registered

---

### import_site()

**Signature:** `import_site <site_name> <ssh_target> <ssh_key> <remote_site_dir> <remote_webroot> [drupal_version]`

**Purpose:** Main import function - orchestrates all import steps.

**Parameters:**
- `$1` (string) - Site name
- `$2` (string) - SSH target
- `$3` (string) - SSH key path
- `$4` (string) - Remote site directory
- `$5` (string) - Remote webroot path
- `$6` (string, optional) - Drupal version

**Returns:**
- `0` - Import successful
- `1` - Import failed

---

### import_selected_sites()

**Signature:** `import_selected_sites`

**Purpose:** Imports all selected sites from TUI.

**Uses:** SELECTED_SITES, DISCOVERED_SITES, SELECTED_SSH_HOST, SELECTED_SSH_KEY

**Returns:**
- `0` - All imports successful

---

### rollback_import()

**Signature:** `rollback_import <site_name>`

**Purpose:** Rolls back a failed import.

**Parameters:**
- `$1` (string) - Site name

**Returns:**
- `0` - Rollback successful

---

## Summary

This API reference documents **38 library files** with **400+ functions** across the NWP codebase. For more detailed documentation:

- **YAML Operations:** See [docs/YAML_API.md](/home/rob/nwp/docs/YAML_API.md)
- **Security Architecture:** See [docs/DATA_SECURITY_BEST_PRACTICES.md](/home/rob/nwp/docs/DATA_SECURITY_BEST_PRACTICES.md)
- **Testing System:** See testing.sh documentation in this file
- **Installation Flow:** See install-drupal.sh and install-common.sh documentation

For questions or contributions, see the main [README.md](/home/rob/nwp/README.md).
