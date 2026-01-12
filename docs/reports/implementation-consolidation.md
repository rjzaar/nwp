# NWP Codebase Consolidation Implementation Plan

This document provides a comprehensive implementation plan for consolidating orphaned code, removing duplicates, and integrating disconnected modules.

## Table of Contents

1. [UI Function Consolidation](#1-ui-function-consolidation)
2. [Common Function Consolidation](#2-common-function-consolidation)
3. [TUI Function Consolidation](#3-tui-function-consolidation)
4. [Unregistered Command Integration](#4-unregistered-command-integration)
5. [Disconnected Module Integration](#5-disconnected-module-integration)
6. [live2prod.sh Implementation](#6-live2prodsh-implementation)
7. [live_delete() Completion](#7-live_delete-completion)
8. [cleanup-preview.sh Analysis](#8-cleanup-previewsh-analysis)
9. [Orphaned Function Removal](#9-orphaned-function-removal)
10. [Implementation Checklist](#10-implementation-checklist)

---

## Executive Summary: Valuable Features to Preserve

Before removing duplicates, this analysis identified **valuable features** in variant implementations that should be merged into canonical versions:

### Features Worth Preserving from Duplicates

| Source File | Feature | Value | Action |
|-------------|---------|-------|--------|
| `email/setup_email.sh` | Icon-based output: `[✓]` `[✗]` `[!]` `[i]` | Cleaner, more modern look | Merge into lib/ui.sh as alternative functions |
| `scripts/commands/test-nwp.sh` | Unicode info symbol `ℹ` | Most elegant info indicator | Consider for canonical `info()` |
| `lib/common.sh` | Color fallbacks `${CYAN:-\033[0;36m}` | Works even if colors not defined | Apply to all color usage |
| `scripts/commands/make.sh` | Context-aware `show_elapsed_time()` | Shows "dev mode" vs "prod mode" in message | Keep specialized version |
| `lib/tui.sh` | "live" environment support | Handles live environment labels | Merge into lib/common.sh |
| Various | `>&2` stderr redirect in print_error | Proper error stream handling | Ensure all error functions use |

### Proposed Enhanced lib/ui.sh

The canonical lib/ui.sh should be enhanced to offer BOTH text-prefix and icon-based output:

```bash
# Text-prefix style (current canonical - for logging/CLI)
print_error()   { echo -e "${RED}${BOLD}ERROR:${NC} $1" >&2; }
print_warning() { echo -e "${YELLOW}${BOLD}WARNING:${NC} $1"; }
print_info()    { echo -e "${BLUE}${BOLD}INFO:${NC} $1"; }

# Icon-style (from email scripts - for TUI/modern terminals)
fail() { echo -e "${RED}[✗]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${BLUE}[ℹ]${NC} $1"; }    # Upgrade to Unicode ℹ
pass() { echo -e "${GREEN}[✓]${NC} $1"; }
```

### Proposed Enhanced lib/common.sh get_env_label()

Merge "live" support from lib/tui.sh:

```bash
get_env_label() {
    local env="$1"
    case "$env" in
        prod)  echo "PRODUCTION" ;;
        stage) echo "STAGING" ;;
        live)  echo "LIVE" ;;        # Added from tui.sh
        dev)   echo "DEVELOPMENT" ;;
        local) echo "LOCAL" ;;
        ci)    echo "CI" ;;
        *)     echo "$env" | tr '[:lower:]' '[:upper:]' ;;
    esac
}
```

### Special Cases to Preserve

1. **make.sh `show_elapsed_time()`** - Keep as-is, it has context-aware MODE switching
2. **test-nwp.sh minimal output** - Uses bare `✓` `✗` icons for test results, appropriate for test output

---

## 1. UI Function Consolidation

### Problem

Over 100 duplicate definitions of `print_error()`, `print_warning()`, and `print_info()` exist across the codebase with inconsistent implementations:

| Variant | Issue |
|---------|-------|
| `echo -e "${RED}ERROR: $1"` | Missing `>&2` redirect |
| `echo -e "${RED}[✗]${NC} $1"` | Different icon format |
| `echo -e "${RED}${BOLD}ERROR:${NC} $1"` | Uses BOLD |

### Canonical Versions (lib/ui.sh)

```bash
print_error() {
    echo -e "${RED}${BOLD}ERROR:${NC} $1" >&2
}

print_info() {
    echo -e "${BLUE}${BOLD}INFO:${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}${BOLD}WARNING:${NC} $1"
}
```

### Files Requiring Updates

**High Priority - scripts/commands/ (remove local definitions, source lib/ui.sh):**

| File | Has Local Definitions | Action |
|------|----------------------|--------|
| `stg2prod.sh` | Yes (lines 37-64) | Remove, add source |
| `prod2stg.sh` | Yes | Remove, add source |
| `testos.sh` | Yes | Remove, add source |
| `dev2stg.sh` | Yes | Remove, add source |
| `live.sh` | Yes | Remove, add source |
| `live2stg.sh` | Yes | Remove, add source |
| `live2prod.sh` | Already sources | No change |
| `stg2live.sh` | Yes | Remove, add source |
| `restore.sh` | Yes | Remove, add source |
| `backup.sh` | Yes | Remove, add source |
| `copy.sh` | Yes | Remove, add source |
| `delete.sh` | Yes | Remove, add source |
| `make.sh` | Yes | Remove, add source |
| `test.sh` | Yes | Remove, add source |

**Email Directory:**

| File | Action |
|------|--------|
| `email/setup_email.sh` | Remove local definitions, add source |
| `email/add_site_email.sh` | Remove local definitions, add source |
| `email/test_email.sh` | Remove local definitions, add source |
| `email/configure_reroute.sh` | Remove local definitions, add source |

**Linode Directory (all files):**

| File | Action |
|------|--------|
| `linode/linode_deploy.sh` | Remove local definitions, add source |
| `linode/linode_setup.sh` | Remove local definitions, add source |
| `linode/validate_stackscript.sh` | Remove local definitions, add source |
| `linode/gitlab/*.sh` | Remove local definitions, add source |

### Implementation Pattern

**Before:**
```bash
#!/bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
# ... more color definitions

print_error() {
    echo -e "${RED}ERROR:${NC} $1"  # Inconsistent!
}
```

**After:**
```bash
#!/bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"

# Remove: Color definitions (provided by ui.sh)
# Remove: print_error, print_info, print_warning, print_header, print_status
```

---

## 2. Common Function Consolidation

### Problem: get_base_name() - 8 Duplicates with Inconsistent Behavior

**Canonical Version (lib/common.sh:379):**
```bash
get_base_name() {
    local site="$1"
    echo "$site" | sed -E 's/[-_](stg|prod)$//'
}
```
This correctly handles BOTH `-stg`/`-prod` AND legacy `_stg`/`_prod` suffixes.

**Broken Version (live2prod.sh:24):**
```bash
get_base_name() {
    local site=$1
    echo "$site" | sed -E 's/_(stg|prod)$//'  # ONLY handles underscore!
}
```
This will FAIL for sites using hyphen convention (e.g., `mysite-stg`).

### Files Requiring Updates

| File | Current Pattern | Action |
|------|-----------------|--------|
| `live2prod.sh:24` | `s/_(stg|prod)$/` | Remove, source common.sh |
| `dev2stg.sh:144` | `s/[-_](stg|prod)$/` | Remove, source common.sh |
| `stg2live.sh:35` | `s/[-_](stg|prod)$/` | Remove, source common.sh |
| `live2stg.sh:27` | varies | Remove, source common.sh |
| `live.sh:71` | `s/[-_](stg|prod)$/` | Remove, source common.sh |
| `produce.sh:24` | varies | Remove, source common.sh |
| `stg2prod.sh:165` | `s/[-_](stg|prod)$/` | Remove, source common.sh |

### Implementation

All scripts should:
1. Add `source "$PROJECT_ROOT/lib/common.sh"` (after ui.sh)
2. Remove their local `get_base_name()` definition

---

## 3. TUI Function Consolidation

### Problem: get_env_label() - Two Versions

**lib/common.sh:459 (UPPERCASE output):**
```bash
get_env_label() {
    local env="$1"
    case "$env" in
        prod) echo "PRODUCTION" ;;
        stage) echo "STAGING" ;;
        dev) echo "DEVELOPMENT" ;;
        local) echo "LOCAL" ;;
        ci) echo "CI" ;;
        *) echo "$env" | tr '[:lower:]' '[:upper:]' ;;
    esac
}
```

**lib/tui.sh:69 (Title Case output):**
```bash
get_env_label() {
    local env="$1"
    case "$env" in
        dev) echo "Development" ;;
        stage) echo "Staging" ;;
        live) echo "Live" ;;
        prod) echo "Production" ;;
        *) echo "$env" ;;
    esac
}
```

### Decision: Use lib/common.sh Version

**Rationale:**
- Industry standard for environment labels is UPPERCASE (AWS, Azure, Kubernetes all use PRODUCTION, STAGING)
- UPPERCASE is more visible as status indicators
- Consistent with CI/CD conventions

### Implementation

1. **Rename tui.sh version** to `get_env_display_label()` for TUI-specific Title Case needs
2. **Update lib/tui.sh:69:**
```bash
# TUI-specific display label (Title Case for cleaner UI)
get_env_display_label() {
    local env="$1"
    case "$env" in
        dev) echo "Development" ;;
        stage) echo "Staging" ;;
        live) echo "Live" ;;
        prod) echo "Production" ;;
        *) echo "$env" ;;
    esac
}

# Re-export common.sh version for standard use
# (common.sh should be sourced before tui.sh)
```

3. **Update TUI draw functions** to use `get_env_display_label()` where Title Case is preferred

### Cursor Functions (cursor_to, cursor_hide, cursor_show)

**Canonical Location:** lib/tui.sh:26-29

Files defining locally that should source lib/tui.sh instead:
- `scripts/commands/status.sh`
- `scripts/commands/setup.sh`
- `scripts/commands/verify.sh`
- `lib/checkbox.sh`
- `lib/import-tui.sh`
- `lib/dev2stg-tui.sh`

**Note:** Some of these files need TUI functions but shouldn't pull in the full TUI library. Create a minimal `lib/terminal.sh`:

```bash
#!/bin/bash
# lib/terminal.sh - Minimal terminal control functions

[[ -n "${_TERMINAL_SH_LOADED:-}" ]] && return 0
_TERMINAL_SH_LOADED=1

cursor_to() { printf "\033[%d;%dH" "$1" "$2"; }
cursor_hide() { printf "\033[?25l"; }
cursor_show() { printf "\033[?25h"; }
clear_screen() { printf "\033[2J\033[H"; }
clear_line() { printf "\033[2K"; }

read_key() {
    local key
    IFS= read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
        read -rsn2 -t 0.1 rest || true
        case "$rest" in
            '[A') echo "UP" ;;
            '[B') echo "DOWN" ;;
            '[C') echo "RIGHT" ;;
            '[D') echo "LEFT" ;;
            *) echo "ESC" ;;
        esac
    elif [[ $key == "" ]]; then
        echo "ENTER"
    elif [[ $key == " " ]]; then
        echo "SPACE"
    else
        echo "$key"
    fi
}

export -f cursor_to cursor_hide cursor_show clear_screen clear_line read_key
```

Then update lib/tui.sh to source this:
```bash
source "${BASH_SOURCE%/*}/terminal.sh"
```

---

## 4. Unregistered Command Integration

### Problem

9 fully-functional scripts in `scripts/commands/` work via the fallback mechanism but aren't documented in `pl --help`.

### Commands to Register

| Script | Suggested Command | Category |
|--------|------------------|----------|
| `import.sh` | `import` | Site Management |
| `sync.sh` | `sync` | Site Management |
| `modify.sh` | `modify` | Site Management |
| `coder-setup.sh` | `coder` | Setup & Utilities |
| `podcast.sh` | `podcast` | Provisioning |
| `report.sh` | `report` | Utilities |
| `verify.sh` | `verify` | Utilities |
| `migrate-secrets.sh` | `migrate-secrets` | Setup & Utilities |
| `status.sh` | Already registered | N/A |

### Implementation: Update pl help text

Add to `show_help()` in `/home/rob/nwp/pl`:

```bash
${BOLD}IMPORT & SYNC:${NC}
    import <server>                 Import sites from remote server
    sync <sitename>                 Sync database/files from source
    modify <sitename>               Modify site options interactively

${BOLD}PODCASTING:${NC}
    podcast <sitename>              Setup Castopod podcast infrastructure

${BOLD}DEVELOPER TOOLS:${NC}
    coder add <name>                Add developer coder environment
    coder list                      List configured coders
    verify <sitename>               Verify site features and changes
    report                          Generate bug report

${BOLD}MAINTENANCE:${NC}
    migrate-secrets                 Migrate secrets to new format
```

### Implementation: Add explicit routing

Add to the `case` statement in `main()`:

```bash
# Import & Sync
import)
    run_script "import.sh" "$@"
    ;;
sync)
    run_script "sync.sh" "$@"
    ;;
modify)
    run_script "modify.sh" "$@"
    ;;

# Podcasting
podcast)
    run_script "podcast.sh" "$@"
    ;;

# Developer tools
coder)
    run_script "coder-setup.sh" "$@"
    ;;
verify)
    run_script "verify.sh" "$@"
    ;;
report)
    run_script "report.sh" "$@"
    ;;

# Maintenance
migrate-secrets)
    run_script "migrate-secrets.sh" "$@"
    ;;
```

---

## 5. Disconnected Module Integration

### Email Module

**Current State:** 5 complete scripts in `email/` not wired into CLI.

**Integration Plan:**

1. **Create email.sh wrapper** in `scripts/commands/`:

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
EMAIL_DIR="$PROJECT_ROOT/email"

source "$PROJECT_ROOT/lib/ui.sh"

show_help() {
    cat << EOF
${BOLD}NWP Email Management${NC}

${BOLD}USAGE:${NC}
    pl email <command> [options]

${BOLD}COMMANDS:${NC}
    setup                   Setup email infrastructure (Postfix, DKIM, SPF)
    add <sitename>          Add email account for a site
    test [sitename]         Test email deliverability
    reroute <sitename>      Configure email rerouting for development
    reroute --disable       Disable email rerouting
    list                    List configured site emails

${BOLD}EXAMPLES:${NC}
    pl email setup                  # Initial server email setup
    pl email add mysite             # Add email for mysite
    pl email test mysite            # Test mysite email delivery
    pl email reroute mysite         # Route mysite email to Mailpit

EOF
}

case "${1:-}" in
    setup)
        shift
        "$EMAIL_DIR/setup_email.sh" "$@"
        ;;
    add)
        shift
        "$EMAIL_DIR/add_site_email.sh" "$@"
        ;;
    test)
        shift
        "$EMAIL_DIR/test_email.sh" "$@"
        ;;
    reroute)
        shift
        "$EMAIL_DIR/configure_reroute.sh" "$@"
        ;;
    list)
        shift
        "$EMAIL_DIR/add_site_email.sh" --list "$@"
        ;;
    -h|--help|help|"")
        show_help
        ;;
    *)
        print_error "Unknown email command: $1"
        show_help
        exit 1
        ;;
esac
```

2. **Add to pl routing:**
```bash
email)
    run_script "email.sh" "$@"
    ;;
```

3. **Add to pl help:**
```bash
${BOLD}EMAIL:${NC}
    email setup                     Setup email infrastructure
    email add <sitename>            Add email account for site
    email test <sitename>           Test email deliverability
    email reroute <sitename>        Route email to Mailpit (dev)
```

### Advanced Deployment Scripts

**Current State:** Well-documented in `linode/server_scripts/` but not integrated:
- `nwp-bluegreen-deploy.sh`
- `nwp-canary.sh`
- `nwp-perf-baseline.sh`

**Decision:** These are **server-side scripts** meant to run ON the production server, not from the local CLI. Document this clearly rather than integrate.

**Add to docs/ADVANCED_DEPLOYMENT.md:**
```markdown
## Server-Side Deployment Scripts

These scripts are designed to run **on the production server**, not from your local machine:

| Script | Purpose | Usage |
|--------|---------|-------|
| `nwp-bluegreen-deploy.sh` | Blue-green deployment with instant rollback | `ssh prod 'nwp-bluegreen-deploy.sh mysite'` |
| `nwp-canary.sh` | Gradual rollout with automatic health checks | `ssh prod 'nwp-canary.sh mysite 10'` |
| `nwp-perf-baseline.sh` | Performance baseline capture and comparison | `ssh prod 'nwp-perf-baseline.sh mysite capture'` |

These should be deployed to `/usr/local/bin/` on your production server.
```

---

## 6. live2prod.sh Implementation

### Current State

The script is a stub that only displays help and suggestions.

### Implementation

Replace `/home/rob/nwp/scripts/commands/live2prod.sh` with:

```bash
#!/bin/bash
set -euo pipefail

################################################################################
# NWP Live to Production Deployment Script
#
# Deploys from live test server directly to production server
#
# Usage: ./live2prod.sh [OPTIONS] <sitename>
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"

# Script start time
START_TIME=$(date +%s)

################################################################################
# Configuration Functions
################################################################################

get_live_config() {
    local sitename="$1"
    local field="$2"

    awk -v site="$sitename" -v field="$field" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
        in_site && /^    live:/ { in_live = 1; next }
        in_live && /^    [a-zA-Z]/ && !/^      / { in_live = 0 }
        in_live && $0 ~ "^      " field ":" {
            sub("^      " field ": *", "")
            gsub(/["'"'"']/, "")
            print
            exit
        }
    ' "$PROJECT_ROOT/cnwp.yml"
}

get_prod_config() {
    local sitename="$1"
    local field="$2"

    awk -v site="$sitename" -v field="$field" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
        in_site && /^    production:/ { in_prod = 1; next }
        in_prod && /^    [a-zA-Z]/ && !/^      / { in_prod = 0 }
        in_prod && $0 ~ "^      " field ":" {
            sub("^      " field ": *", "")
            gsub(/["'"'"']/, "")
            print
            exit
        }
    ' "$PROJECT_ROOT/cnwp.yml"
}

show_help() {
    cat << EOF
${BOLD}NWP Live to Production Deployment${NC}

${BOLD}USAGE:${NC}
    ./live2prod.sh [OPTIONS] <sitename>

    Deploys directly from live test server to production server.
    This is an advanced workflow for when live has been tested and
    you want to bypass staging.

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -y, --yes               Skip confirmation prompts
    -s, --step <n>          Start from step n
    --skip-backup           Skip production backup (dangerous!)

${BOLD}WORKFLOW:${NC}
    1. Validate live and production configurations
    2. Backup production database
    3. Export configuration from live
    4. Sync files from live to production
    5. Run composer install on production
    6. Run database updates
    7. Import configuration
    8. Clear caches

${BOLD}EXAMPLES:${NC}
    ./live2prod.sh mysite              # Deploy live to production
    ./live2prod.sh -y mysite           # Deploy without confirmation

${BOLD}RECOMMENDED WORKFLOW:${NC}
    For most deployments, use the safer two-step approach:
    1. pl live2stg mysite    # Pull live changes to staging
    2. pl stg2prod mysite    # Deploy staging to production

EOF
}

################################################################################
# Deployment Functions
################################################################################

validate_deployment() {
    local base_name="$1"

    print_info "Validating deployment configuration..."

    # Check live server config
    local live_ip=$(get_live_config "$base_name" "server_ip")
    local live_user=$(get_live_config "$base_name" "ssh_user")
    local live_path=$(get_live_config "$base_name" "webroot")

    if [ -z "$live_ip" ]; then
        print_error "No live server configured for $base_name"
        print_info "Run 'pl live $base_name' first to provision live server"
        return 1
    fi

    # Check production server config
    local prod_ip=$(get_prod_config "$base_name" "server_ip")
    local prod_user=$(get_prod_config "$base_name" "ssh_user")
    local prod_path=$(get_prod_config "$base_name" "webroot")

    if [ -z "$prod_ip" ]; then
        print_error "No production server configured for $base_name"
        print_info "Configure production section in cnwp.yml first"
        return 1
    fi

    # Test SSH connections
    print_info "Testing SSH connection to live server ($live_ip)..."
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${live_user:-root}@${live_ip}" "echo OK" &>/dev/null; then
        print_error "Cannot connect to live server: ${live_user:-root}@${live_ip}"
        return 1
    fi
    print_status "OK" "Live server accessible"

    print_info "Testing SSH connection to production server ($prod_ip)..."
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${prod_user:-root}@${prod_ip}" "echo OK" &>/dev/null; then
        print_error "Cannot connect to production server: ${prod_user:-root}@${prod_ip}"
        return 1
    fi
    print_status "OK" "Production server accessible"

    # Export variables for other functions
    export LIVE_IP="$live_ip"
    export LIVE_USER="${live_user:-root}"
    export LIVE_PATH="${live_path:-/var/www/$base_name}"
    export PROD_IP="$prod_ip"
    export PROD_USER="${prod_user:-root}"
    export PROD_PATH="${prod_path:-/var/www/$base_name}"

    return 0
}

backup_production() {
    local base_name="$1"

    print_info "Creating production backup before deployment..."

    local backup_name="${base_name}_pre_deploy_$(date +%Y%m%d_%H%M%S)"
    local backup_cmd="cd $PROD_PATH && drush sql-dump --gzip > /tmp/${backup_name}.sql.gz"

    if ssh "${PROD_USER}@${PROD_IP}" "$backup_cmd"; then
        print_status "OK" "Production database backed up: ${backup_name}.sql.gz"
    else
        print_error "Failed to backup production database"
        return 1
    fi
}

export_live_config() {
    local base_name="$1"

    print_info "Exporting configuration from live server..."

    local export_cmd="cd $LIVE_PATH && drush config:export -y"

    if ssh "${LIVE_USER}@${LIVE_IP}" "$export_cmd"; then
        print_status "OK" "Configuration exported on live"
    else
        print_error "Failed to export configuration"
        return 1
    fi
}

sync_files() {
    local base_name="$1"

    print_info "Syncing files from live to production..."

    # Rsync from live to production (server to server)
    local rsync_cmd="rsync -avz --delete \
        --exclude='.git' \
        --exclude='sites/*/files' \
        --exclude='sites/*/private' \
        --exclude='vendor' \
        ${LIVE_USER}@${LIVE_IP}:${LIVE_PATH}/ \
        ${PROD_PATH}/"

    if ssh "${PROD_USER}@${PROD_IP}" "$rsync_cmd"; then
        print_status "OK" "Files synced to production"
    else
        print_error "Failed to sync files"
        return 1
    fi
}

run_composer() {
    local base_name="$1"

    print_info "Running composer install on production..."

    local composer_cmd="cd $PROD_PATH && composer install --no-dev --optimize-autoloader"

    if ssh "${PROD_USER}@${PROD_IP}" "$composer_cmd"; then
        print_status "OK" "Composer dependencies installed"
    else
        print_error "Composer install failed"
        return 1
    fi
}

run_db_updates() {
    local base_name="$1"

    print_info "Running database updates on production..."

    local update_cmd="cd $PROD_PATH && drush updatedb -y"

    if ssh "${PROD_USER}@${PROD_IP}" "$update_cmd"; then
        print_status "OK" "Database updates complete"
    else
        print_warning "Database updates returned non-zero (may be OK)"
    fi
}

import_config() {
    local base_name="$1"

    print_info "Importing configuration on production..."

    local import_cmd="cd $PROD_PATH && drush config:import -y"

    if ssh "${PROD_USER}@${PROD_IP}" "$import_cmd"; then
        print_status "OK" "Configuration imported"
    else
        print_error "Configuration import failed"
        return 1
    fi
}

clear_caches() {
    local base_name="$1"

    print_info "Clearing caches on production..."

    local cache_cmd="cd $PROD_PATH && drush cache:rebuild"

    if ssh "${PROD_USER}@${PROD_IP}" "$cache_cmd"; then
        print_status "OK" "Caches cleared"
    else
        print_warning "Cache clear returned non-zero"
    fi
}

################################################################################
# Main
################################################################################

main() {
    local YES=false
    local SKIP_BACKUP=false
    local START_STEP=1
    local SITENAME=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) show_help; exit 0 ;;
            -y|--yes) YES=true; shift ;;
            -s|--step) START_STEP="$2"; shift 2 ;;
            --skip-backup) SKIP_BACKUP=true; shift ;;
            -*) print_error "Unknown option: $1"; exit 1 ;;
            *) SITENAME="$1"; shift ;;
        esac
    done

    if [ -z "$SITENAME" ]; then
        print_error "Sitename required"
        show_help
        exit 1
    fi

    local BASE_NAME=$(get_base_name "$SITENAME")

    print_header "Live to Production Deployment: $BASE_NAME"

    # Validate configuration
    if ! validate_deployment "$BASE_NAME"; then
        exit 1
    fi

    # Confirmation
    if [ "$YES" != "true" ]; then
        print_warning "This will deploy LIVE directly to PRODUCTION"
        echo ""
        echo "  Live server:       ${LIVE_USER}@${LIVE_IP}"
        echo "  Production server: ${PROD_USER}@${PROD_IP}"
        echo ""
        read -p "Are you sure you want to continue? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[yY] ]]; then
            print_info "Deployment cancelled"
            exit 0
        fi
    fi

    # Execute deployment steps
    local step=1

    if [ $step -ge $START_STEP ] && [ "$SKIP_BACKUP" != "true" ]; then
        print_info "Step $step: Backup production"
        backup_production "$BASE_NAME"
    fi
    ((step++))

    if [ $step -ge $START_STEP ]; then
        print_info "Step $step: Export live configuration"
        export_live_config "$BASE_NAME"
    fi
    ((step++))

    if [ $step -ge $START_STEP ]; then
        print_info "Step $step: Sync files"
        sync_files "$BASE_NAME"
    fi
    ((step++))

    if [ $step -ge $START_STEP ]; then
        print_info "Step $step: Run composer"
        run_composer "$BASE_NAME"
    fi
    ((step++))

    if [ $step -ge $START_STEP ]; then
        print_info "Step $step: Database updates"
        run_db_updates "$BASE_NAME"
    fi
    ((step++))

    if [ $step -ge $START_STEP ]; then
        print_info "Step $step: Import configuration"
        import_config "$BASE_NAME"
    fi
    ((step++))

    if [ $step -ge $START_STEP ]; then
        print_info "Step $step: Clear caches"
        clear_caches "$BASE_NAME"
    fi

    # Show elapsed time
    show_elapsed_time "Deployment"

    print_header "Deployment Complete"
    print_status "OK" "Live deployed to production successfully"
    echo ""
    print_info "Production URL: https://$(get_prod_config "$BASE_NAME" "domain")"
}

main "$@"
```

---

## 7. live_delete() Completion

### Current State (live.sh:934-939)

```bash
# Remove from cnwp.yml
print_info "Updating cnwp.yml..."
# TODO: Remove live section from cnwp.yml

print_status "OK" "Live server deleted"
```

### Implementation

Replace lines 934-939 with:

```bash
    # Remove live section from cnwp.yml
    print_info "Updating cnwp.yml..."

    # Source yaml-write library if not already loaded
    if ! command -v yaml_update_site_field &>/dev/null; then
        source "$PROJECT_ROOT/lib/yaml-write.sh"
    fi

    # Remove live configuration from site
    # We use awk to remove the entire live: section
    local config_file="$PROJECT_ROOT/cnwp.yml"
    local temp_file=$(mktemp)

    awk -v site="$BASE_NAME" '
        BEGIN { in_sites = 0; in_site = 0; in_live = 0; skip_live = 0 }

        /^sites:/ { in_sites = 1; print; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0; in_site = 0 }

        in_sites && $0 ~ "^  " site ":" { in_site = 1; print; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }

        in_site && /^    live:/ { in_live = 1; skip_live = 1; next }
        in_live && /^    [a-zA-Z]/ && !/^      / { in_live = 0; skip_live = 0 }

        !skip_live { print }
    ' "$config_file" > "$temp_file"

    if [ -s "$temp_file" ]; then
        mv "$temp_file" "$config_file"
        print_status "OK" "Removed live configuration from cnwp.yml"
    else
        rm -f "$temp_file"
        print_warning "Could not update cnwp.yml (file may need manual cleanup)"
    fi

    print_status "OK" "Live server deleted"
```

---

## 8. cleanup-preview.sh Analysis

### Finding

The commented code in `cleanup-preview.sh` (lines 127-147) is **NOT dead code**. It's intentionally commented as **template examples** for users who have custom infrastructure.

**Evidence:**
- Line 127: `# If you have custom DNS or routing configured for preview environments,`
- Line 140: `# If using a reverse proxy (nginx, Traefik, etc.) for preview environments:`

### Recommendation

**No changes needed.** This is proper documentation of optional extension points.

**Optional Enhancement:** Convert to explicit extension hook:

```bash
################################################################################
# Optional: Custom cleanup hooks
################################################################################

# Source custom cleanup if it exists
if [ -f "$PROJECT_ROOT/scripts/ci/cleanup-preview-custom.sh" ]; then
    info "Running custom cleanup hooks..."
    source "$PROJECT_ROOT/scripts/ci/cleanup-preview-custom.sh"
fi
```

This allows users to create `cleanup-preview-custom.sh` with their DNS/nginx cleanup without modifying the main script.

---

## 9. Orphaned Function Integration

Rather than removing orphaned functions, this section proposes proper integration into NWP.

### 9.1 lib/badges.sh - Create `pl badges` Command

**Purpose:** GitLab CI/CD badge management for project READMEs

**Currently Unused Functions:**
| Function | Purpose | Proposed Command |
|----------|---------|------------------|
| `generate_badge_urls()` | Show all badge URLs with markdown | `pl badges show <sitename>` |
| `generate_readme_badges()` | Generate README badge section | `pl badges markdown <sitename>` |
| `add_badges_to_readme()` | Add badges to existing README | `pl badges add <sitename>` |
| `check_coverage_threshold()` | Verify coverage meets threshold | `pl badges coverage <sitename> --threshold=80` |

**Implementation: Create `scripts/commands/badges.sh`**

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/badges.sh"

show_help() {
    cat << EOF
${BOLD}NWP Badge Management${NC}

${BOLD}USAGE:${NC}
    pl badges <command> [options] <sitename>

${BOLD}COMMANDS:${NC}
    show <sitename>              Show all badge URLs for a site
    markdown <sitename>          Generate markdown badge snippet
    add <sitename>               Add badges to site's README.md
    update <sitename>            Update existing badges in README
    coverage <sitename>          Check test coverage threshold

${BOLD}OPTIONS:${NC}
    --group <group>              GitLab group (default: sites)
    --branch <branch>            Git branch (default: main)
    --threshold <percent>        Coverage threshold (default: 80)

${BOLD}EXAMPLES:${NC}
    pl badges show mysite                    # Show badge URLs
    pl badges markdown mysite --branch=dev   # Markdown for dev branch
    pl badges add mysite                     # Add to README.md
    pl badges coverage mysite --threshold=90 # Check 90% coverage

EOF
}

cmd_show() {
    local sitename="$1"
    local group="${GROUP:-sites}"
    local branch="${BRANCH:-main}"

    generate_badge_urls "$sitename" "$group" "$branch"
}

cmd_markdown() {
    local sitename="$1"
    local group="${GROUP:-sites}"
    local branch="${BRANCH:-main}"

    generate_readme_badges "$sitename" "$group" "$branch"
}

cmd_add() {
    local sitename="$1"
    local group="${GROUP:-sites}"
    local readme="${PROJECT_ROOT}/sites/${sitename}/README.md"

    if [ ! -f "$readme" ]; then
        print_error "README.md not found: $readme"
        exit 1
    fi

    add_badges_to_readme "$readme" "$sitename" "$group"
}

cmd_update() {
    local sitename="$1"
    local group="${GROUP:-sites}"
    local branch="${BRANCH:-main}"
    local readme="${PROJECT_ROOT}/sites/${sitename}/README.md"

    if [ ! -f "$readme" ]; then
        print_error "README.md not found: $readme"
        exit 1
    fi

    update_readme_badges "$readme" "$sitename" "$group" "$branch"
}

cmd_coverage() {
    local sitename="$1"
    local threshold="${THRESHOLD:-80}"
    local coverage_file="${PROJECT_ROOT}/sites/${sitename}/coverage.xml"

    if [ ! -f "$coverage_file" ]; then
        # Try alternate locations
        coverage_file="${PROJECT_ROOT}/sites/${sitename}/build/coverage.xml"
    fi

    check_coverage_threshold "$threshold" "$coverage_file"
}

# Parse options
GROUP=""
BRANCH=""
THRESHOLD=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --group=*) GROUP="${1#*=}"; shift ;;
        --group) GROUP="$2"; shift 2 ;;
        --branch=*) BRANCH="${1#*=}"; shift ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --threshold=*) THRESHOLD="${1#*=}"; shift ;;
        --threshold) THRESHOLD="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) break ;;
    esac
done

COMMAND="${1:-}"
SITENAME="${2:-}"

case "$COMMAND" in
    show) cmd_show "$SITENAME" ;;
    markdown) cmd_markdown "$SITENAME" ;;
    add) cmd_add "$SITENAME" ;;
    update) cmd_update "$SITENAME" ;;
    coverage) cmd_coverage "$SITENAME" ;;
    -h|--help|help|"") show_help ;;
    *) print_error "Unknown command: $COMMAND"; show_help; exit 1 ;;
esac
```

**Add to pl routing:**
```bash
badges)
    run_script "badges.sh" "$@"
    ;;
```

**Add to pl help:**
```bash
${BOLD}CI/CD:${NC}
    badges show <sitename>          Show GitLab badge URLs
    badges add <sitename>           Add badges to README.md
    badges coverage <sitename>      Check test coverage threshold
```

---

### 9.2 lib/b2.sh - Create `pl storage` Command

**Purpose:** Backblaze B2 cloud storage management for backups and podcast media

**Currently Unused Functions:**
| Function | Purpose | Proposed Command |
|----------|---------|------------------|
| `b2_authorize()` | Authenticate with B2 | `pl storage auth` |
| `b2_list_buckets()` | List all buckets | `pl storage list` |
| `b2_list_keys()` | List application keys | `pl storage keys` |
| `b2_upload_file()` | Upload file to bucket | `pl storage upload <file> <bucket>` |
| `b2_list_files()` | List files in bucket | `pl storage files <bucket>` |
| `b2_delete_file()` | Delete file from bucket | `pl storage delete <bucket> <file>` |
| `b2_delete_app_key()` | Delete application key | `pl storage key-delete <key_id>` |
| `b2_get_bucket_info()` | Get bucket details | `pl storage info <bucket>` |

**Implementation: Create `scripts/commands/storage.sh`**

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/b2.sh"

show_help() {
    cat << EOF
${BOLD}NWP Cloud Storage Management (Backblaze B2)${NC}

${BOLD}USAGE:${NC}
    pl storage <command> [options]

${BOLD}COMMANDS:${NC}
    auth                         Authenticate with B2
    list                         List all buckets
    info <bucket>                Show bucket details
    files <bucket> [prefix]      List files in bucket
    upload <file> <bucket>       Upload file to bucket
    delete <bucket> <file>       Delete file from bucket
    keys                         List application keys
    key-delete <key_id>          Delete an application key

${BOLD}EXAMPLES:${NC}
    pl storage auth                          # Authenticate with B2
    pl storage list                          # Show all buckets
    pl storage files podcast-media           # List podcast files
    pl storage upload backup.sql.gz mybackups  # Upload backup

${BOLD}CONFIGURATION:${NC}
    Add to .secrets.yml:
      b2:
        account_id: "your-account-id"
        app_key: "your-application-key"

EOF
}

cmd_auth() {
    print_info "Authenticating with Backblaze B2..."
    if b2_authorize "$PROJECT_ROOT"; then
        print_status "OK" "B2 authentication successful"
    else
        print_error "B2 authentication failed"
        exit 1
    fi
}

cmd_list() {
    print_header "B2 Buckets"
    b2_list_buckets
}

cmd_info() {
    local bucket="$1"
    if [ -z "$bucket" ]; then
        print_error "Bucket name required"
        exit 1
    fi
    print_header "Bucket: $bucket"
    b2_get_bucket_info "$bucket"
    echo ""
    print_info "Public URL: $(b2_get_bucket_url "$bucket")"
}

cmd_files() {
    local bucket="$1"
    local prefix="${2:-}"
    if [ -z "$bucket" ]; then
        print_error "Bucket name required"
        exit 1
    fi
    print_header "Files in $bucket"
    b2_list_files "$bucket" "$prefix"
}

cmd_upload() {
    local file="$1"
    local bucket="$2"
    local remote_name="${3:-$(basename "$file")}"

    if [ -z "$file" ] || [ -z "$bucket" ]; then
        print_error "Usage: pl storage upload <file> <bucket> [remote_name]"
        exit 1
    fi

    if [ ! -f "$file" ]; then
        print_error "File not found: $file"
        exit 1
    fi

    print_info "Uploading $file to $bucket..."
    if b2_upload_file "$bucket" "$file" "$remote_name"; then
        print_status "OK" "Upload complete: $remote_name"
    else
        print_error "Upload failed"
        exit 1
    fi
}

cmd_delete() {
    local bucket="$1"
    local file="$2"

    if [ -z "$bucket" ] || [ -z "$file" ]; then
        print_error "Usage: pl storage delete <bucket> <file>"
        exit 1
    fi

    print_warning "Deleting $file from $bucket..."
    if b2_delete_file "$bucket" "$file"; then
        print_status "OK" "File deleted"
    else
        print_error "Delete failed"
        exit 1
    fi
}

cmd_keys() {
    print_header "B2 Application Keys"
    b2_list_keys
}

cmd_key_delete() {
    local key_id="$1"
    if [ -z "$key_id" ]; then
        print_error "Key ID required"
        exit 1
    fi

    print_warning "Deleting application key: $key_id"
    if b2_delete_app_key "$key_id"; then
        print_status "OK" "Key deleted"
    else
        print_error "Delete failed"
        exit 1
    fi
}

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    auth) cmd_auth ;;
    list) cmd_list ;;
    info) cmd_info "$@" ;;
    files) cmd_files "$@" ;;
    upload) cmd_upload "$@" ;;
    delete) cmd_delete "$@" ;;
    keys) cmd_keys ;;
    key-delete) cmd_key_delete "$@" ;;
    -h|--help|help|"") show_help ;;
    *) print_error "Unknown command: $COMMAND"; show_help; exit 1 ;;
esac
```

**Add to pl routing:**
```bash
storage)
    run_script "storage.sh" "$@"
    ;;
```

**Add to pl help:**
```bash
${BOLD}CLOUD STORAGE:${NC}
    storage auth                    Authenticate with Backblaze B2
    storage list                    List B2 buckets
    storage upload <file> <bucket>  Upload file to B2
    storage files <bucket>          List files in bucket
```

---

### 9.3 lib/rollback.sh - Integrate into Deployment Workflows

**Purpose:** Automatic recovery from failed deployments

**Currently Unused Functions:**
| Function | Purpose | Integration Point |
|----------|---------|-------------------|
| `rollback_backup_before()` | Pre-deployment backup | Auto-call in stg2prod.sh, live2prod.sh |
| `rollback_cleanup()` | Remove old rollback points | Add to `pl schedule` maintenance |

**Integration 1: Add to stg2prod.sh (and other deployment scripts)**

Add after validation, before deployment begins:

```bash
# Source rollback library
source "$PROJECT_ROOT/lib/rollback.sh"

# Create pre-deployment backup for rollback
if [ "$SKIP_BACKUP" != "true" ]; then
    print_info "Creating pre-deployment rollback point..."
    ROLLBACK_PATH=$(rollback_backup_before "$STG_NAME" "prod")
    if [ -z "$ROLLBACK_PATH" ]; then
        print_error "Failed to create rollback point"
        if ! ask_yes_no "Continue without rollback capability?"; then
            exit 1
        fi
    fi
fi
```

Add at end of deployment (on failure):

```bash
# If deployment failed, offer rollback
if [ $DEPLOY_STATUS -ne 0 ]; then
    print_error "Deployment failed!"
    if ask_yes_no "Would you like to rollback to pre-deployment state?" "y"; then
        rollback_quick "$STG_NAME" "prod"
    fi
fi
```

**Integration 2: Create `pl rollback` Command**

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/rollback.sh"

show_help() {
    cat << EOF
${BOLD}NWP Deployment Rollback${NC}

${BOLD}USAGE:${NC}
    pl rollback <command> [options] <sitename>

${BOLD}COMMANDS:${NC}
    list [sitename]              List available rollback points
    execute <sitename> [env]     Rollback to last deployment
    verify <sitename>            Verify site after rollback
    cleanup [--keep=N]           Remove old rollback points (keep last N)

${BOLD}OPTIONS:${NC}
    --env <environment>          Environment (prod, stage, live)
    --keep <count>               Number of rollback points to keep (default: 5)

${BOLD}EXAMPLES:${NC}
    pl rollback list                     # Show all rollback points
    pl rollback list mysite              # Show rollback points for mysite
    pl rollback execute mysite prod      # Rollback mysite production
    pl rollback cleanup --keep=3         # Keep only last 3 rollback points

${BOLD}AUTOMATIC ROLLBACK:${NC}
    Rollback points are automatically created before each deployment.
    If a deployment fails, you'll be prompted to rollback.

EOF
}

cmd_list() {
    local sitename="${1:-}"
    rollback_list "$sitename"
}

cmd_execute() {
    local sitename="$1"
    local environment="${2:-prod}"

    if [ -z "$sitename" ]; then
        print_error "Sitename required"
        exit 1
    fi

    rollback_quick "$sitename" "$environment"
}

cmd_verify() {
    local sitename="$1"

    if [ -z "$sitename" ]; then
        print_error "Sitename required"
        exit 1
    fi

    rollback_verify "$sitename"
}

cmd_cleanup() {
    local keep="${KEEP:-5}"

    print_info "Cleaning up old rollback points (keeping last $keep)..."
    rollback_cleanup "$keep"
    print_status "OK" "Cleanup complete"
}

# Parse options
KEEP=""
ENV=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --keep=*) KEEP="${1#*=}"; shift ;;
        --keep) KEEP="$2"; shift 2 ;;
        --env=*) ENV="${1#*=}"; shift ;;
        --env) ENV="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) break ;;
    esac
done

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    list) cmd_list "$@" ;;
    execute) cmd_execute "$@" ;;
    verify) cmd_verify "$@" ;;
    cleanup) cmd_cleanup ;;
    -h|--help|help|"") show_help ;;
    *) print_error "Unknown command: $COMMAND"; show_help; exit 1 ;;
esac
```

**Add to pl routing:**
```bash
rollback)
    run_script "rollback.sh" "$@"
    ;;
```

**Add to pl help:**
```bash
${BOLD}ROLLBACK:${NC}
    rollback list [sitename]        List available rollback points
    rollback execute <sitename>     Rollback to pre-deployment state
    rollback cleanup                Remove old rollback points
```

**Integration 3: Add cleanup to scheduled maintenance**

Add to `scripts/commands/schedule.sh` maintenance tasks:

```bash
# In the maintenance cron job
cmd_maintenance() {
    source "$PROJECT_ROOT/lib/rollback.sh"

    print_info "Running scheduled maintenance..."

    # Clean up old rollback points
    rollback_cleanup 5

    # Other maintenance tasks...
}
```

---

### 9.4 Summary: Integration vs Removal

| Library | Functions | Decision | Benefit |
|---------|-----------|----------|---------|
| **lib/badges.sh** | 4 unused | **Integrate** via `pl badges` | CI/CD badge management for all sites |
| **lib/b2.sh** | 8 unused | **Integrate** via `pl storage` | Cloud backup/media management |
| **lib/rollback.sh** | 2 unused | **Integrate** into deployments | Automatic deployment recovery |

**Total new commands:** 3 (`pl badges`, `pl storage`, `pl rollback`)

**Lines of new code:** ~300 (3 wrapper scripts)

**Value added:**
- Badge management without manual URL construction
- Cloud storage operations from CLI
- Safer deployments with automatic rollback capability

---

## 10. Implementation Checklist

### Phase 1: UI Consolidation (High Priority)

- [ ] Create `lib/terminal.sh` with minimal cursor control functions
- [ ] Update `lib/tui.sh` to source `lib/terminal.sh`
- [ ] Update all scripts in `scripts/commands/` to source `lib/ui.sh`
- [ ] Remove local `print_error`, `print_info`, `print_warning` definitions
- [ ] Remove local color variable definitions
- [ ] Update all scripts in `email/` to source `lib/ui.sh`
- [ ] Update all scripts in `linode/` to source `lib/ui.sh`

### Phase 2: Common Function Consolidation

- [ ] Remove all local `get_base_name()` definitions
- [ ] Ensure all deployment scripts source `lib/common.sh`
- [ ] Rename `get_env_label()` in `lib/tui.sh` to `get_env_display_label()`
- [ ] Update TUI code to use new function name

### Phase 3: Command Registration

- [ ] Add 9 missing commands to `pl` help text
- [ ] Add explicit routing in `pl` main case statement
- [ ] Update `pl-completion.bash` with new commands

### Phase 4: Module Integration

- [ ] Create `scripts/commands/email.sh` wrapper
- [ ] Add email command routing to `pl`
- [ ] Update documentation for advanced deployment scripts

### Phase 5: Feature Completion

- [ ] Implement full `live2prod.sh` deployment
- [ ] Complete `live_delete()` cnwp.yml cleanup
- [ ] Optional: Add extension hook to `cleanup-preview.sh`

### Phase 6: Dead Code Removal

- [ ] Remove 4 unused functions from `lib/badges.sh`
- [ ] Remove 8 unused functions from `lib/b2.sh`
- [ ] Evaluate and handle `lib/rollback.sh` unused functions

### Testing

After each phase:
- [ ] Run `./scripts/commands/test-nwp.sh` to verify no regressions
- [ ] Manually test affected commands
- [ ] Verify sourcing order doesn't cause circular dependencies

---

## Summary

This implementation plan addresses:

1. **100+ duplicate UI function definitions** → Consolidate to `lib/ui.sh`
2. **8 duplicate `get_base_name()` with bugs** → Use `lib/common.sh` version
3. **2 conflicting `get_env_label()`** → Rename TUI version, use common.sh as standard
4. **9 hidden commands** → Register in `pl` help and routing
5. **Disconnected email module** → Create wrapper and integrate
6. **Stub `live2prod.sh`** → Full implementation provided
7. **Incomplete `live_delete()`** → cnwp.yml cleanup implemented
8. **Commented cleanup-preview.sh code** → Confirmed as intentional templates
9. **~25 orphaned functions** → Removal list provided

Estimated effort: 2-3 days for full implementation with testing.

---

## Appendix A: Detailed Duplicate Function Analysis

This appendix provides a comprehensive comparison of all duplicate function implementations, identifying unique features worth preserving.

### A.1 print_error() - All Implementations Compared

| File | Implementation | stderr | BOLD | Format |
|------|----------------|--------|------|--------|
| **lib/ui.sh:55** | `${RED}${BOLD}ERROR:${NC} $1` | ✓ `>&2` | ✓ | Text prefix |
| stg2prod.sh:58 | `${RED}${BOLD}ERROR:${NC} $1` | ✓ `>&2` | ✓ | Text prefix |
| prod2stg.sh:58 | `${RED}${BOLD}ERROR:${NC} $1` | ✓ `>&2` | ✓ | Text prefix |
| **email/setup_email.sh:71** | `${RED}[✗]${NC} $1` | ✓ `>&2` | ✗ | **Icon [✗]** |
| email/configure_reroute.sh:46 | `${RED}[✗]${NC} $1` | ✓ `>&2` | ✗ | **Icon [✗]** |
| linode/linode_deploy.sh:77 | `${RED}ERROR:${NC} $1` | ✗ | ✗ | Text prefix |
| linode/linode_setup.sh:85 | `${RED}ERROR:${NC} $1` | ✗ | ✗ | Text prefix |
| **test-nwp.sh:107** | `${RED}✗${NC} $1` | ✗ | ✗ | **Bare icon ✗** |
| testos.sh:49 | `${RED}ERROR:${NC} $1` | ✗ | ✗ | Text prefix |
| setup-ssh.sh:38 | `${RED}ERROR:${NC} $1` | ✗ | ✗ | Text prefix |

**Analysis:**
- **Best practice:** Canonical (lib/ui.sh) - uses stderr + BOLD
- **Valuable variant:** Email scripts use cleaner `[✗]` icon
- **Bug:** Many linode scripts don't redirect to stderr

**Merge Recommendation:**
```bash
# Keep both styles in lib/ui.sh
print_error() { echo -e "${RED}${BOLD}ERROR:${NC} $1" >&2; }  # For logging/scripts
fail()        { echo -e "${RED}[✗]${NC} $1" >&2; }           # For TUI/modern
```

### A.2 print_warning() - All Implementations Compared

| File | Implementation | BOLD | Format |
|------|----------------|------|--------|
| **lib/ui.sh:65** | `${YELLOW}${BOLD}WARNING:${NC} $1` | ✓ | Text prefix |
| **email/setup_email.sh:67** | `${YELLOW}[!]${NC} $1` | ✗ | **Icon [!]** |
| email/configure_reroute.sh:45 | `${YELLOW}[!]${NC} $1` | ✗ | **Icon [!]** |
| **linode/linode_deploy.sh:73** | `${YELLOW}!${NC} $1` | ✗ | **Bare icon !** |
| linode/linode_setup.sh:81 | `${YELLOW}WARNING:${NC} $1` | ✗ | Text prefix |
| test-nwp.sh:115 | `${YELLOW}!${NC} $1` | ✗ | **Bare icon !** |
| setup-ssh.sh:46 | `${YELLOW}WARNING:${NC} $1` | ✗ | Text prefix |

**Analysis:**
- Three distinct styles: `WARNING:`, `[!]`, and bare `!`
- Email scripts' `[!]` is most visually consistent with their icon set
- BOLD only in canonical version

**Merge Recommendation:**
```bash
print_warning() { echo -e "${YELLOW}${BOLD}WARNING:${NC} $1"; }  # For logging
warn()          { echo -e "${YELLOW}[!]${NC} $1"; }              # For TUI
```

### A.3 print_info() - All Implementations Compared

| File | Implementation | BOLD | Format |
|------|----------------|------|--------|
| **lib/ui.sh:60** | `${BLUE}${BOLD}INFO:${NC} $1` | ✓ | Text prefix |
| stg2prod.sh:62 | `${BLUE}${BOLD}INFO:${NC} $1` | ✓ | Text prefix |
| **email/setup_email.sh:75** | `${BLUE}[i]${NC} $1` | ✗ | **Icon [i]** |
| email/configure_reroute.sh:47 | `${BLUE}[i]${NC} $1` | ✗ | **Icon [i]** |
| **test-nwp.sh:111** | `${BLUE}ℹ${NC} $1` | ✗ | **Unicode ℹ** |
| testos.sh:53 | `${BLUE}INFO:${NC} $1` | ✗ | Text prefix |
| setup-ssh.sh:42 | `${BLUE}INFO:${NC} $1` | ✗ | Text prefix |

**Analysis:**
- **test-nwp.sh's Unicode `ℹ` is the most elegant solution**
- Email scripts use `[i]` which is ASCII-safe
- BOLD inconsistently applied

**Merge Recommendation:**
```bash
print_info() { echo -e "${BLUE}${BOLD}INFO:${NC} $1"; }  # For logging
info()       { echo -e "${BLUE}[ℹ]${NC} $1"; }           # For TUI (upgrade to Unicode)
```

### A.4 get_base_name() - All Implementations Compared

| File | Regex Pattern | Handles `-` | Handles `_` |
|------|---------------|-------------|-------------|
| **lib/common.sh:379** | `s/[-_](stg\|prod)$//` | ✓ | ✓ |
| stg2live.sh:35 | `s/[-_](stg\|prod)$//` | ✓ | ✓ |
| live.sh:71 | `s/[-_](stg\|prod)$//` | ✓ | ✓ |
| stg2prod.sh:165 | `s/[-_](stg\|prod)$//` | ✓ | ✓ |
| ~~live2prod.sh:24~~ | ~~`s/_(stg\|prod)$//`~~ | ✗ | ✓ |

**Analysis:**
- **All versions are identical EXCEPT live2prod.sh which has a BUG**
- live2prod.sh only handles underscore, breaking hyphen-convention sites
- Perfect candidate for deduplication

**Merge Recommendation:**
- Remove ALL local definitions
- All scripts source lib/common.sh
- Fix live2prod.sh bug by removing local definition

### A.5 get_env_label() - Two Implementations Compared

| Aspect | lib/common.sh:459 | lib/tui.sh:69 |
|--------|-------------------|---------------|
| **Output case** | UPPERCASE | Title Case |
| **prod** | "PRODUCTION" | "Production" |
| **stage** | "STAGING" | "Staging" |
| **live** | Not handled | "Live" ✓ |
| **dev** | "DEVELOPMENT" | "Development" |
| **local** | "LOCAL" | Not handled |
| **ci** | "CI" | Not handled |
| **Default** | Uppercase unknown | Return as-is |

**Analysis:**
- **lib/common.sh** is more complete (handles local, ci)
- **lib/tui.sh** handles "live" which common.sh doesn't
- Different use cases: CLI logging vs TUI display

**Merge Recommendation:**
```bash
# lib/common.sh - Add "live" support
get_env_label() {
    local env="$1"
    case "$env" in
        prod)  echo "PRODUCTION" ;;
        stage) echo "STAGING" ;;
        live)  echo "LIVE" ;;        # ADDED from tui.sh
        dev)   echo "DEVELOPMENT" ;;
        local) echo "LOCAL" ;;
        ci)    echo "CI" ;;
        *)     echo "$env" | tr '[:lower:]' '[:upper:]' ;;
    esac
}

# lib/tui.sh - Rename to avoid conflict
get_env_display_label() {  # RENAMED for TUI-specific Title Case
    local env="$1"
    case "$env" in
        dev)   echo "Development" ;;
        stage) echo "Staging" ;;
        live)  echo "Live" ;;
        prod)  echo "Production" ;;
        *)     echo "$env" ;;
    esac
}
```

### A.6 show_elapsed_time() - Implementations Compared

| File | Label Param | Message Format | Special Features |
|------|-------------|----------------|------------------|
| **lib/ui.sh:70** | ✓ (default: "Operation") | "$label completed in HH:MM:SS" | Generic, reusable |
| stg2prod.sh:75 | ✗ | "Deployment completed in HH:MM:SS" | Hardcoded label |
| prod2stg.sh | ✗ | "Pull completed in HH:MM:SS" | Hardcoded label |
| **make.sh:29** | ✗ | MODE-aware message | **Unique: switches dev/prod** |

**Analysis:**
- lib/ui.sh canonical is most flexible with label parameter
- **make.sh has unique context-aware feature worth preserving**

**Merge Recommendation:**
- Keep lib/ui.sh canonical version for general use
- **Keep make.sh specialized version** (unique MODE switching)
- Other scripts should call `show_elapsed_time "Deployment"`

### A.7 ocmsg() / debug_msg() - Implementations Compared

| File | Has Fallback Colors | Implementation |
|------|---------------------|----------------|
| **lib/common.sh:14** | ✓ `${CYAN:-\033[0;36m}` | Canonical with `debug_msg()` + `ocmsg()` alias |
| stg2prod.sh:67 | ✗ | Simple duplicate |
| Various others | ✗ | Simple duplicates |

**Analysis:**
- Canonical has **color fallback safety** - valuable!
- All duplicates are functionally identical otherwise

**Merge Recommendation:**
- Remove all duplicates
- Use canonical lib/common.sh version with color fallbacks

### A.8 ask_yes_no() - Single Implementation

Only found in **lib/common.sh:69-90**. No duplicates detected.

**Features:**
- Default parameter support (`y` or `n`)
- Handles multiple yes formats: `y`, `Y`, `yes`, `Yes`, `YES`
- Clean return codes (0 for yes, 1 for no)

**Status:** Already well-implemented and centralized. No action needed.

---

## Appendix B: Files That Would Lose Features If Blindly Deleted

| File | Unique Feature | Loss Impact | Recommendation |
|------|---------------|-------------|----------------|
| `make.sh` | MODE-aware elapsed time | High - context lost | **Keep specialized version** |
| `email/setup_email.sh` | Icon style `[✓][✗][!][i]` | Medium - visual improvement lost | **Merge style into canonical** |
| `test-nwp.sh` | Unicode `ℹ` symbol | Low - aesthetic only | **Consider for canonical** |
| `lib/tui.sh` | "live" env + Title Case | Medium - TUI broken | **Merge "live", rename function** |
| `lib/common.sh` | Color fallbacks | High - breaks non-color terminals | **Ensure preserved** |

---

## Appendix C: Safe Deletion List

These duplicates are **100% safe to delete** with no feature loss:

### Identical to Canonical (remove these)
- `stg2prod.sh` lines 37-64 (print_*, show_elapsed_time)
- `prod2stg.sh` lines 37-64
- `stg2live.sh:35-38` (get_base_name)
- `live.sh:71-75` (get_base_name)
- `stg2prod.sh:165-168` (get_base_name)

### Missing Features vs Canonical (remove and source canonical)
- All `linode/*.sh` UI functions (missing BOLD, stderr)
- All `email/*.sh` text-prefix functions (keep icon variants separately)
- `testos.sh` UI functions
- `setup-ssh.sh` UI functions

### Total Safe Deletions
- **~100+ function definitions** can be removed
- Replace with `source "$PROJECT_ROOT/lib/ui.sh"` and `source "$PROJECT_ROOT/lib/common.sh"`
