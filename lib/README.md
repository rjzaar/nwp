# NWP Libraries Reference

**Last Updated:** 2026-01-14
**Version:** 0.20.0+

This directory contains reusable bash libraries for NWP. All libraries follow consistent patterns for security, error handling, and documentation.

## Table of Contents

- [Usage](#usage)
- [Security Patterns](#security-patterns)
- [Library Index](#library-index)
- [Creating New Libraries](#creating-new-libraries)

---

## Usage

All scripts should source required libraries from `$PROJECT_ROOT/lib/`:

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source required libraries
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/ssh.sh"
```

### Common Library Loading Pattern

```bash
# Check if library is already loaded (for libraries that source other libraries)
if [ -z "$(type -t function_name)" ]; then
    source "$PROJECT_ROOT/lib/library.sh"
fi
```

---

## Security Patterns

All NWP libraries follow these security patterns to prevent vulnerabilities.

### 1. Always Quote Variables

Variables must be quoted to prevent word splitting and globbing.

**Bad (vulnerable to word splitting):**
```bash
cmd="ssh $host"
$cmd  # Breaks if $host contains spaces
```

**Good (safe):**
```bash
cmd=(ssh "$host")
"${cmd[@]}"
```

### 2. Use Arrays for Commands

Build commands as arrays, not strings.

**Bad (vulnerable to injection):**
```bash
rsync_cmd="rsync -av $source $dest"
$rsync_cmd  # Unsafe expansion
```

**Good (safe):**
```bash
rsync_cmd=(rsync -av "$source" "$dest")
"${rsync_cmd[@]}"  # Safe array expansion
```

**Example from lib/remote.sh:**
```bash
# Build SSH command as array
local ssh_cmd=(ssh)
ssh_cmd+=(-o "StrictHostKeyChecking=$host_key_mode")
if [ -n "$ssh_port" ]; then
    ssh_cmd+=(-p "$ssh_port")
fi
"${ssh_cmd[@]}" user@host "command"
```

### 3. Validate All Input

Validate user input before use in commands.

**Pattern:**
```bash
# Validate sitename - only alphanumeric, dots, hyphens, underscores
if [[ ! "$sitename" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    print_error "Invalid sitename: contains unsafe characters"
    return 1
fi
```

**Common validation patterns:**
```bash
# Site/environment names
[[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]]

# Absolute paths only
[[ "$path" =~ ^/ ]] && [[ ! "$path" =~ \.\. ]]

# Email addresses
[[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]

# URLs
[[ "$url" =~ ^https?:// ]]
```

**Example from lib/remote.sh:**
```bash
remote_exec() {
    local sitename="$1"
    local environment="$2"

    # Input validation - prevent path traversal and injection
    if [[ "$sitename" =~ [^a-zA-Z0-9._-] ]]; then
        print_error "Invalid sitename: contains unsafe characters"
        return 1
    fi
    if [[ "$environment" =~ [^a-zA-Z0-9._-] ]]; then
        print_error "Invalid environment: contains unsafe characters"
        return 1
    fi

    # ... rest of function
}
```

### 4. Pass Untrusted Data via stdin

Never embed untrusted data in command strings. Use stdin instead.

**Bad (command injection vulnerability):**
```bash
ssh user@host "echo $untrusted_data >> file"
# If $untrusted_data contains "; rm -rf /", you're in trouble
```

**Good (safe):**
```bash
echo "$untrusted_data" | ssh user@host "cat >> file"
# Data is treated as data, not commands
```

**Example from scripts/commands/setup-ssh.sh:**
```bash
# Read public key from file
local public_key
public_key=$(cat "$public_key_file")

# Push key via stdin (safe from injection)
echo "$public_key" | "${ssh_cmd[@]}" "$ssh_user@$ssh_host" \
    "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

### 5. Use set -euo pipefail

All libraries and scripts should use strict error handling.

```bash
#!/bin/bash
set -euo pipefail

# -e: Exit on error
# -u: Exit on undefined variable
# -o pipefail: Exit on pipe failure
```

**Note:** Some functions may need `set +e` temporarily:
```bash
# Try optional operation
set +e
optional_command
result=$?
set -e

if [ $result -eq 0 ]; then
    print_status "Optional operation succeeded"
fi
```

### 6. SSH Security Controls

All SSH connections must use the security controls from `lib/ssh.sh`:

```bash
source "$PROJECT_ROOT/lib/ssh.sh"

# Show security warning on first connection
show_ssh_security_warning

# Get host key checking mode (respects NWP_SSH_STRICT)
host_key_mode=$(get_ssh_host_key_checking)

# Build SSH command with security options
ssh_cmd=(ssh -o "StrictHostKeyChecking=$host_key_mode")
"${ssh_cmd[@]}" user@host "command"
```

**Benefits:**
- Centralized security configuration
- User warnings about MITM risks
- Optional strict mode via `NWP_SSH_STRICT=1`
- Consistent behavior across all SSH operations

### 7. Path Validation

Always validate paths to prevent traversal attacks.

```bash
validate_path() {
    local path="$1"

    # Must be absolute path
    if [[ ! "$path" =~ ^/ ]]; then
        print_error "Path must be absolute: $path"
        return 1
    fi

    # No .. components
    if [[ "$path" =~ \.\. ]]; then
        print_error "Path contains .. component: $path"
        return 1
    fi

    # Only safe characters
    if [[ ! "$path" =~ ^/[a-zA-Z0-9./_-]+$ ]]; then
        print_error "Path contains unsafe characters: $path"
        return 1
    fi

    return 0
}
```

**Example from lib/remote.sh:**
```bash
# Validate site_path - must be absolute path without dangerous characters
if [[ ! "$site_path" =~ ^/[a-zA-Z0-9./_-]+$ ]]; then
    print_error "Invalid site_path: must be absolute path with safe characters"
    return 1
fi
```

### 8. Never Log Secrets

Secrets should never appear in logs, error messages, or debug output.

**Bad:**
```bash
db_pass=$(get_secret "db.password")
echo "Connecting with password: $db_pass"  # NEVER DO THIS
```

**Good:**
```bash
db_pass=$(get_secret "db.password")
if [ -z "$db_pass" ]; then
    print_error "Database password not configured"  # No secret in error
    return 1
fi
# Use $db_pass without logging it
```

**Pattern for debugging:**
```bash
# Show that secret exists without revealing value
if [ -n "$db_pass" ]; then
    print_debug "Database password: [SET]"
else
    print_debug "Database password: [NOT SET]"
fi
```

---

## Library Index

### Core Libraries

#### common.sh
**Purpose:** Common utility functions used by all scripts

**Key Functions:**
- `get_project_root()` - Find NWP project root
- `get_infra_secret()` - Get infrastructure secret from .secrets.yml
- `get_data_secret()` - Get data secret from .secrets.data.yml
- `require_file()` - Check file exists, exit if not
- `is_development()` - Check if running in development mode

**Dependencies:** None (base library)

**Example:**
```bash
source "$PROJECT_ROOT/lib/common.sh"

project_root=$(get_project_root)
token=$(get_infra_secret "linode.api_token" "")
```

#### ui.sh
**Purpose:** User interface functions for output formatting

**Key Functions:**
- `print_header()` - Print section header
- `print_info()` - Print informational message
- `print_status()` - Print status message with icon
- `print_error()` - Print error message
- `print_warning()` - Print warning message
- `print_success()` - Print success message
- Color constants: `$RED`, `$GREEN`, `$YELLOW`, `$BLUE`, `$NC`

**Dependencies:** None

**Example:**
```bash
source "$PROJECT_ROOT/lib/ui.sh"

print_header "Deployment Started"
print_info "Deploying to production..."
print_success "Deployment complete!"
```

#### ssh.sh
**Purpose:** SSH security controls and connection helpers

**Key Functions:**
- `get_ssh_host_key_checking()` - Get host key checking mode
- `show_ssh_security_warning()` - Display security warning
- `is_ssh_strict_mode()` - Check if strict mode enabled

**Dependencies:** None

**Security Features:**
- Respects `NWP_SSH_STRICT` environment variable
- Displays warnings about MITM risks
- Centralizes SSH security configuration

**Example:**
```bash
source "$PROJECT_ROOT/lib/ssh.sh"

# Show warning before SSH operations
show_ssh_security_warning

# Get security mode
host_key_mode=$(get_ssh_host_key_checking)
ssh -o "StrictHostKeyChecking=$host_key_mode" user@host
```

### Specialized Libraries

#### remote.sh
**Purpose:** Remote server operations via SSH

**Key Functions:**
- `remote_exec()` - Execute command on remote server
- `remote_drush()` - Run drush on remote server
- `remote_backup()` - Backup remote site
- `remote_test()` - Test remote connection

**Dependencies:** ui.sh, common.sh, ssh.sh

**Security:**
- Input validation on sitename/environment
- Path validation for site paths
- Proper variable quoting in all SSH commands

**Example:**
```bash
source "$PROJECT_ROOT/lib/remote.sh"

remote_exec "mysite" "prod" "drush status"
remote_backup "mysite" "prod" "./backups"
```

#### cloudflare.sh
**Purpose:** Cloudflare DNS management via API

**Key Functions:**
- `cf_create_dns_record()` - Create DNS record
- `cf_delete_dns_record()` - Delete DNS record
- `cf_list_dns_records()` - List DNS records
- `verify_cloudflare_auth()` - Verify API credentials

**Dependencies:** common.sh

**Example:**
```bash
source "$PROJECT_ROOT/lib/cloudflare.sh"

token=$(get_infra_secret "cloudflare.api_token")
zone_id=$(get_infra_secret "cloudflare.zone_id")

cf_create_dns_record "$token" "$zone_id" "A" "www" "1.2.3.4"
```

#### linode.sh
**Purpose:** Linode server management via API

**Key Functions:**
- `create_linode_server()` - Create new Linode instance
- `delete_linode_server()` - Delete Linode instance
- `get_linode_ip()` - Get server IP address
- `verify_linode_dns()` - Verify DNS configuration

**Dependencies:** common.sh, ui.sh, ssh.sh

**Example:**
```bash
source "$PROJECT_ROOT/lib/linode.sh"

token=$(get_infra_secret "linode.api_token")
create_linode_server "$token" "us-east" "g6-nanode-1" "myserver"
```

#### yaml-write.sh
**Purpose:** Consolidated YAML parsing and modification library

**Comprehensive Documentation:** See [docs/YAML_API.md](../docs/YAML_API.md) for full API reference

**Key Read Functions:**
- `yaml_get_setting()` - Read settings with dot notation (e.g., "settings.stack")
- `yaml_get_array()` - Read array values (e.g., "sites.mysite.tags")
- `yaml_get_recipe_field()` - Read recipe fields (e.g., "recipe_name" "webroot")
- `yaml_get_secret()` - Read from .secrets.yml with dot notation

**Key Write Functions:**
- `yaml_write_site()` - Write entire site definition
- `yaml_update_site_field()` - Update single site field
- `yaml_delete_site()` - Remove site from nwp.yml
- `yaml_write_coder()` - Write coder definition
- `yaml_update_coder_field()` - Update coder field

**Helper Functions:**
- `yaml_get_all_sites()` - List all site names
- `yaml_get_coder_list()` - List all coder names
- `yaml_get_recipe_list()` - Get recipe list array

**Dependencies:** ui.sh (for error messages), yq (YAML processor)

**Security Features:**
- 5-layer protection for nwp.yml modifications (see docs/SECURITY.md)
- Line count tracking prevents data loss
- mktemp for atomic writes
- Empty output detection
- Sanity checks against large deletions
- Atomic move operations

**Example:**
```bash
source "$PROJECT_ROOT/lib/yaml-write.sh"

# Read setting
stack=$(yaml_get_setting "settings.stack" "ddev")

# Read site field
directory=$(yaml_get_site_field "mysite" "directory")

# Update site field
yaml_update_site_field "mysite" "install_step" "5"
```

**Testing:** 34 comprehensive BATS tests in tests/yaml-functions.bats

#### checkbox.sh
**Purpose:** TUI checkbox/multi-select interface library

**Functions (23 total):**
- `draw_checkbox_list()` - Render checkbox list with current selection
- `checkbox_handle_input()` - Process keyboard input (arrows, space, enter)
- `checkbox_get_selected()` - Get array of selected items
- `checkbox_init()` - Initialize checkbox state
- `checkbox_cleanup()` - Clean up terminal state

**Key Features:**
- Arrow key navigation (up/down)
- Space bar to toggle selection
- Visual indicators: [x] selected, [ ] unselected
- Highlighted current line
- Support for long lists with scrolling
- Minimum terminal size detection

**Dependencies:** ui.sh, terminal.sh

**Usage Pattern:**
```bash
source "$PROJECT_ROOT/lib/checkbox.sh"

# Define items
items=("Option 1" "Option 2" "Option 3")

# Show checkbox list
checkbox_init "${items[@]}"
selected=$(checkbox_get_selected)

# Process selections
for item in $selected; do
    echo "Selected: $item"
done
```

**Used By:**
- coders.sh - Multi-coder selection for bulk actions
- dev2stg-tui.sh - Select sites for deployment
- import-tui.sh - Select import options

**Terminal Requirements:**
- Minimum 80x24 terminal
- ANSI color support
- Cursor positioning support

#### tui.sh
**Purpose:** Terminal User Interface framework library

**Core Functions (13 total):**
- `tui_init()` - Initialize TUI with title and status bar
- `tui_draw()` - Render TUI frame (header, content, footer)
- `tui_update_status()` - Update status bar text
- `tui_clear()` - Clear TUI and restore terminal
- `tui_get_dimensions()` - Get terminal width/height
- `tui_handle_resize()` - Handle terminal resize events

**Navigation Functions:**
- `tui_cursor_up()` - Move cursor up
- `tui_cursor_down()` - Move cursor down
- `tui_cursor_home()` - Jump to first item
- `tui_cursor_end()` - Jump to last item

**Input Functions:**
- `tui_read_key()` - Read single keypress
- `tui_confirm()` - Show yes/no prompt
- `tui_message()` - Display message box

**Dependencies:** ui.sh, terminal.sh

**Features:**
- Full-screen TUI with header/content/footer layout
- Keyboard navigation (arrows, home, end, pgup, pgdn)
- Status updates without full refresh
- Terminal resize handling
- Color support with fallback

**Example:**
```bash
source "$PROJECT_ROOT/lib/tui.sh"

# Initialize TUI
tui_init "My Application" "Ready"

# Main loop
while true; do
    tui_draw "$content"
    key=$(tui_read_key)

    case "$key" in
        up) tui_cursor_up ;;
        down) tui_cursor_down ;;
        q) break ;;
    esac
done

# Cleanup
tui_clear
```

**Used By:**
- coders.sh - Interactive coder management console
- verify.sh - Interactive verification console
- dev2stg-tui.sh - Deployment selection interface
- status.sh - Interactive site status dashboard

**Terminal Requirements:**
- ANSI escape sequence support
- Minimum 80x24 terminal
- Cursor positioning support

---

## Creating New Libraries

When creating a new library, follow this template:

```bash
#!/bin/bash

################################################################################
# NWP [Library Name] Library
#
# [Brief description of library purpose]
# Source this file: source "$PROJECT_ROOT/lib/library-name.sh"
#
# Dependencies: [list required libraries]
################################################################################

# Source dependencies
if [ -z "$(type -t function_from_dependency)" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/dependency.sh"
fi

# Public function: Brief description
# Usage: function_name "arg1" "arg2"
# Returns: 0 on success, 1 on failure
function_name() {
    local arg1="$1"
    local arg2="$2"

    # Input validation
    if [[ -z "$arg1" ]]; then
        print_error "arg1 is required"
        return 1
    fi

    # Function implementation
    # ...

    return 0
}

# Another function
# ...
```

### Library Guidelines

1. **Naming:**
   - Use lowercase with hyphens: `library-name.sh`
   - Function names use underscores: `function_name()`

2. **Documentation:**
   - Header comment with purpose and dependencies
   - Function comments with usage and return values
   - Security notes for any sensitive operations

3. **Error Handling:**
   - Use `set -euo pipefail` (or document why not)
   - Return 0 for success, non-zero for errors
   - Use `print_error()` for user-facing errors

4. **Security:**
   - Validate all inputs
   - Quote all variables
   - Use arrays for commands
   - Follow patterns from this document

5. **Testing:**
   - Add machine checks to `.verification.yml` for automated testing
   - Run tests with `pl verify --run --feature=<feature>`
   - Test with valid and invalid inputs
   - Test error conditions

---

## Code Review Checklist

When reviewing library code, verify:

- [ ] All variables are quoted: `"$var"`
- [ ] Commands use arrays: `cmd=(...)`
- [ ] Input validation on all user-provided data
- [ ] Return codes: 0 for success, non-zero for failure
- [ ] Error messages use `print_error()`
- [ ] No secrets logged or echoed
- [ ] SSH uses security controls from ssh.sh
- [ ] Paths validated against traversal
- [ ] Dependencies documented in header
- [ ] Functions have usage comments

---

## Security Review

For security-sensitive libraries (auth, secrets, remote, etc.):

- [ ] All security patterns followed
- [ ] No command injection vulnerabilities
- [ ] No path traversal vulnerabilities
- [ ] Secrets never logged
- [ ] Input validation comprehensive
- [ ] shellcheck passes with no warnings
- [ ] Reviewed by second developer
- [ ] Security implications documented

---

## Additional Resources

- [Bash Security Best Practices](https://mywiki.wooledge.org/BashGuide/Practices)
- [NWP Security Documentation](../docs/SECURITY.md)
- [shellcheck Documentation](https://www.shellcheck.net/)

---

**Last Review:** 2026-01-14
**Next Review:** 2026-04-14 (quarterly)
