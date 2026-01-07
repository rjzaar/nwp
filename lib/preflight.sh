#!/bin/bash

################################################################################
# NWP Preflight/Doctor Library
#
# Pre-deployment validation inspired by Vortex's doctor.sh
# Source this file: source "$SCRIPT_DIR/lib/preflight.sh"
#
# Requires: lib/ui.sh, lib/state.sh to be sourced first
################################################################################

################################################################################
# Main Preflight Check
################################################################################

# Run comprehensive preflight checks before deployment
# Usage: preflight_check "sitename" ["target_sitename"]
# Returns: 0 if all critical checks pass, 1 if any critical check fails
preflight_check() {
    local sitename="$1"
    local target_site="${2:-$(get_staging_name "$sitename")}"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    local errors=0
    local warnings=0

    print_header "Preflight Checks: $sitename -> $target_site"

    # 1. DDEV availability
    check_ddev || ((errors++))

    # 2. Source site checks
    check_source_site "$sitename" || ((errors++))

    # 3. Target site checks (may not exist yet)
    check_target_site "$target_site"
    # Don't count as error - we can create it

    # 4. Required tools
    check_required_tools || ((errors++))

    # 5. Disk space
    check_disk_space || ((warnings++))

    # 6. Network/Production (optional)
    if has_live_config "$sitename" 2>/dev/null; then
        check_production_access "$sitename"
        # Don't count as error - production access is optional
    fi

    # 7. Git status
    check_git_status "$sitename" || ((warnings++))

    # Summary
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ "$errors" -eq 0 ]; then
        pass "All critical preflight checks passed"
        if [ "$warnings" -gt 0 ]; then
            warn "$warnings warning(s) - review above"
        fi
        return 0
    else
        fail "$errors critical check(s) failed"
        note "Fix the issues above before proceeding"
        return 1
    fi
}

################################################################################
# Individual Check Functions
################################################################################

# Check DDEV installation and status
check_ddev() {
    task "Checking DDEV installation..."

    if ! command -v ddev &>/dev/null; then
        fail "DDEV not found"
        note "Install DDEV: https://ddev.readthedocs.io/en/stable/"
        return 1
    fi

    local version=$(ddev version 2>/dev/null | grep "DDEV version" | awk '{print $3}')
    pass "DDEV installed: $version"

    # Check if Docker is running
    task "Checking Docker..."
    if ! docker info &>/dev/null; then
        fail "Docker is not running"
        note "Start Docker Desktop or the Docker daemon"
        return 1
    fi
    pass "Docker is running"

    return 0
}

# Check source site
check_source_site() {
    local sitename="$1"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    task "Checking source site ($sitename)..."

    # Check directory exists
    if [ ! -d "$script_dir/sites/$sitename" ]; then
        fail "Source site directory not found: $sitename"
        return 1
    fi

    # Check DDEV config
    if [ ! -f "$script_dir/sites/$sitename/.ddev/config.yaml" ]; then
        fail "Source site is not a DDEV project"
        note "Run: cd $sitename && ddev config"
        return 1
    fi

    pass "Source site directory exists"

    # Check if running
    task "Checking source DDEV status..."
    local original_dir=$(pwd)
    cd "$script_dir/sites/$sitename" || return 1

    if ddev describe &>/dev/null; then
        local status=$(ddev describe 2>/dev/null | grep -o "running\|stopped" | head -1)
        if [ "$status" = "running" ]; then
            pass "Source DDEV is running"
        else
            warn "Source DDEV is stopped"
            note "Will start automatically during deployment"
        fi
    else
        warn "Could not check DDEV status"
    fi

    # Check database connectivity
    task "Checking database connectivity..."
    if ddev drush sql:query "SELECT 1" &>/dev/null; then
        pass "Database is accessible"
    else
        fail "Cannot connect to database"
        note "Ensure DDEV is running: ddev start"
        cd "$original_dir"
        return 1
    fi

    # Check Drupal bootstrap
    task "Checking Drupal bootstrap..."
    if ddev drush status --field=bootstrap 2>/dev/null | grep -q "Successful"; then
        pass "Drupal bootstrap successful"
    else
        warn "Drupal may not be fully bootstrapped"
    fi

    cd "$original_dir"
    return 0
}

# Check target site
check_target_site() {
    local target_site="$1"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    task "Checking target site ($target_site)..."

    if [ ! -d "$script_dir/sites/$target_site" ]; then
        warn "Target site does not exist (will be created)"
        return 0
    fi

    if [ ! -f "$script_dir/sites/$target_site/.ddev/config.yaml" ]; then
        warn "Target exists but is not a DDEV project"
        return 0
    fi

    pass "Target site exists"

    # Check if running
    local original_dir=$(pwd)
    cd "$script_dir/sites/$target_site" || return 0

    if ddev describe &>/dev/null; then
        local status=$(ddev describe 2>/dev/null | grep -o "running\|stopped" | head -1)
        if [ "$status" = "running" ]; then
            pass "Target DDEV is running"
        else
            note "Target DDEV is stopped (will start during deployment)"
        fi
    fi

    cd "$original_dir"
    return 0
}

# Check required tools
check_required_tools() {
    task "Checking required tools..."

    local missing=0

    for tool in rsync composer git; do
        if command -v "$tool" &>/dev/null; then
            pass "$tool available"
        else
            fail "$tool not found"
            ((missing++))
        fi
    done

    # Optional tools
    task "Checking optional tools..."
    for tool in yq jq; do
        if command -v "$tool" &>/dev/null; then
            pass "$tool available"
        else
            note "$tool not found (optional)"
        fi
    done

    return $missing
}

# Check disk space
check_disk_space() {
    task "Checking disk space..."

    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local free_kb=$(df -k "$script_dir" 2>/dev/null | awk 'NR==2 {print $4}')
    local free_gb=$((free_kb / 1024 / 1024))

    if [ "$free_gb" -ge 10 ]; then
        pass "Disk space: ${free_gb}GB free"
        return 0
    elif [ "$free_gb" -ge 5 ]; then
        warn "Disk space: ${free_gb}GB free (recommend 10GB+)"
        return 0
    else
        warn "Low disk space: ${free_gb}GB free (recommend 10GB+)"
        note "Consider freeing up space before deployment"
        return 1
    fi
}

# Check production access
check_production_access() {
    local sitename="$1"

    task "Checking production access..."

    if ! has_live_config "$sitename" 2>/dev/null; then
        note "No production configuration found"
        return 0
    fi

    local domain=$(get_live_domain "$sitename" 2>/dev/null)
    if [ -n "$domain" ]; then
        note "Production domain: $domain"
    fi

    if check_prod_ssh "$sitename" 2>/dev/null; then
        pass "Production SSH accessible"
        return 0
    else
        warn "Production SSH not accessible"
        note "Fresh production backups will not be available"
        return 0
    fi
}

# Check git status
check_git_status() {
    local sitename="$1"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    task "Checking git status..."

    local original_dir=$(pwd)
    cd "$script_dir/sites/$sitename" || return 0

    if [ ! -d ".git" ]; then
        note "Not a git repository"
        cd "$original_dir"
        return 0
    fi

    # Check for uncommitted changes
    local changes=$(git status --porcelain 2>/dev/null | wc -l)
    if [ "$changes" -gt 0 ]; then
        warn "Uncommitted changes: $changes file(s)"
        note "Consider committing changes before deployment"
        cd "$original_dir"
        return 1
    fi

    # Check branch
    local branch=$(git branch --show-current 2>/dev/null)
    pass "On branch: $branch (clean)"

    cd "$original_dir"
    return 0
}

################################################################################
# Quick Check Mode
################################################################################

# Run minimal checks (faster, for use with -y flag)
# Usage: quick_preflight "sitename"
quick_preflight() {
    local sitename="$1"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    info "Running quick preflight checks..."

    # DDEV
    if ! command -v ddev &>/dev/null; then
        fail "DDEV not found"
        return 1
    fi

    # Source site exists
    if [ ! -d "$script_dir/sites/$sitename" ]; then
        fail "Site not found: $sitename"
        return 1
    fi

    # Docker running
    if ! docker info &>/dev/null; then
        fail "Docker not running"
        return 1
    fi

    pass "Quick preflight passed"
    return 0
}

################################################################################
# System Info Mode
################################################################################

# Display system information (like doctor --info)
# Usage: show_system_info
show_system_info() {
    print_header "System Information"

    info "Operating System"
    echo "  $(uname -s) $(uname -r)"
    echo "  $(cat /etc/os-release 2>/dev/null | grep "PRETTY_NAME" | cut -d= -f2 | tr -d '"' || echo "Unknown")"

    echo ""
    info "Docker"
    if command -v docker &>/dev/null; then
        echo "  Version: $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
        echo "  Status: $(docker info &>/dev/null && echo "Running" || echo "Not running")"
    else
        echo "  Not installed"
    fi

    echo ""
    info "DDEV"
    if command -v ddev &>/dev/null; then
        echo "  Version: $(ddev version 2>/dev/null | grep "DDEV version" | awk '{print $3}')"
    else
        echo "  Not installed"
    fi

    echo ""
    info "PHP (host)"
    if command -v php &>/dev/null; then
        echo "  Version: $(php -v 2>/dev/null | head -1 | awk '{print $2}')"
    else
        echo "  Not installed on host"
    fi

    echo ""
    info "Disk Space"
    df -h . 2>/dev/null | awk 'NR==1 || NR==2'

    echo ""
    info "Memory"
    free -h 2>/dev/null | head -2 || echo "  Unable to determine"
}

################################################################################
# Validation Functions for Specific Operations
################################################################################

# Validate before database operations
# Usage: validate_db_operation "sitename"
validate_db_operation() {
    local sitename="$1"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    # Check site exists and has DDEV
    if [ ! -f "$script_dir/sites/$sitename/.ddev/config.yaml" ]; then
        fail "Site is not a DDEV project: $sitename"
        return 1
    fi

    # Check DDEV is running
    local original_dir=$(pwd)
    cd "$script_dir/sites/$sitename" || return 1

    if ! ddev describe &>/dev/null; then
        task "Starting DDEV..."
        if ! ddev start; then
            fail "Could not start DDEV"
            cd "$original_dir"
            return 1
        fi
    fi

    # Check database connectivity
    if ! ddev drush sql:query "SELECT 1" &>/dev/null; then
        fail "Database not accessible"
        cd "$original_dir"
        return 1
    fi

    cd "$original_dir"
    return 0
}

# Validate before rsync operations
# Usage: validate_rsync_operation "source" "target"
validate_rsync_operation() {
    local source="$1"
    local target="$2"

    # Check rsync exists
    if ! command -v rsync &>/dev/null; then
        fail "rsync not found"
        return 1
    fi

    # Check source exists
    if [ ! -d "$source" ]; then
        fail "Source directory not found: $source"
        return 1
    fi

    # Check target parent exists
    local target_parent=$(dirname "$target")
    if [ ! -d "$target_parent" ]; then
        fail "Target parent directory not found: $target_parent"
        return 1
    fi

    return 0
}
