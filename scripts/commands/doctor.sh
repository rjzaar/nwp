#!/usr/bin/env bash
# NWP Doctor - Diagnostic and troubleshooting command
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/ui.sh"

################################################################################
# Help Function
################################################################################

show_help() {
    cat << 'EOF'
Usage: pl doctor [OPTIONS]

Diagnose common issues and verify NWP configuration.

Options:
    -v, --verbose    Show detailed output for all checks
    -q, --quiet      Only show errors
    -h, --help       Show this help message

Checks performed:
    - System prerequisites (Docker, DDEV, PHP, Composer, yq, git)
    - Configuration files (cnwp.yml, .secrets.yml)
    - Network connectivity (Linode API, Cloudflare API, drupal.org)
    - Common issues (Docker daemon, DDEV sites, disk space, memory)

Exit codes:
    0 - All checks passed
    1 - One or more issues found

Examples:
    pl doctor              # Run all diagnostics
    pl doctor --verbose    # Show detailed output
    NO_COLOR=1 pl doctor   # Disable color output

EOF
}

################################################################################
# Check Functions
################################################################################

check_prerequisites() {
    local errors=0

    print_header "Checking Prerequisites"

    # Docker (required)
    if command -v docker &>/dev/null; then
        local docker_version=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
        print_success "Docker: $docker_version"

        # Check if Docker daemon is running
        if ! docker info &>/dev/null; then
            print_error "Docker daemon is not running"
            print_hint "Start Docker Desktop or run: sudo systemctl start docker"
            ((errors++))
        fi
    else
        print_error "Docker: NOT INSTALLED"
        print_hint "Install from: https://docs.docker.com/get-docker/"
        ((errors++))
    fi

    # DDEV (required)
    if command -v ddev &>/dev/null; then
        local ddev_version=$(ddev version 2>/dev/null | grep "DDEV version" | grep -oP 'v\d+\.\d+\.\d+' || echo "unknown")
        print_success "DDEV: $ddev_version"
    else
        print_error "DDEV: NOT INSTALLED"
        print_hint "Install from: https://ddev.readthedocs.io/en/stable/"
        ((errors++))
    fi

    # PHP (optional)
    if command -v php &>/dev/null; then
        local php_version=$(php -v 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
        print_success "PHP: $php_version (optional)"
    else
        print_warning "PHP: NOT INSTALLED (optional for local development)"
    fi

    # Composer (optional)
    if command -v composer &>/dev/null; then
        local composer_version=$(composer --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
        print_success "Composer: $composer_version (optional)"
    else
        print_warning "Composer: NOT INSTALLED (optional, DDEV includes it)"
    fi

    # yq (recommended)
    if command -v yq &>/dev/null; then
        local yq_version=$(yq --version 2>&1 | head -1 | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
        print_success "yq: $yq_version (recommended)"
    else
        print_warning "yq: NOT INSTALLED (recommended for faster YAML parsing)"
        print_hint "Install from: https://github.com/mikefarah/yq"
    fi

    # git (required)
    if command -v git &>/dev/null; then
        local git_version=$(git --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
        print_success "Git: $git_version"
    else
        print_error "Git: NOT INSTALLED"
        print_hint "Install git from your package manager: sudo apt install git"
        ((errors++))
    fi

    return $errors
}

check_configuration() {
    local errors=0

    print_header "Checking Configuration"

    # cnwp.yml exists
    if [ -f "$PROJECT_ROOT/cnwp.yml" ]; then
        print_success "cnwp.yml: Found"

        # Validate YAML syntax
        if command -v yq &>/dev/null; then
            if yq eval '.' "$PROJECT_ROOT/cnwp.yml" &>/dev/null; then
                print_success "cnwp.yml: Valid YAML syntax"
            else
                print_error "cnwp.yml: Invalid YAML syntax"
                print_hint "Check for syntax errors: yq eval . cnwp.yml"
                ((errors++))
            fi
        fi

        # Check for sites defined
        local site_count=0
        if grep -q "^sites:" "$PROJECT_ROOT/cnwp.yml" 2>/dev/null; then
            # Count site entries (lines that start with 2 spaces followed by a word and colon)
            site_count=$(awk '/^sites:/{flag=1;next}/^[a-zA-Z]/{flag=0}flag && /^  [a-zA-Z]/ && /:$/{count++}END{print count+0}' "$PROJECT_ROOT/cnwp.yml")
        fi

        if [ "$site_count" -gt 0 ]; then
            print_success "Sites configured: $site_count"
        else
            print_warning "No sites configured in cnwp.yml"
            print_hint "Create a site with: pl install <sitename> <recipe>"
        fi
    else
        print_error "cnwp.yml: NOT FOUND"
        print_hint "Copy example.cnwp.yml to cnwp.yml and configure"
        ((errors++))
    fi

    # .secrets.yml exists (infrastructure secrets)
    if [ -f "$PROJECT_ROOT/.secrets.yml" ]; then
        print_success ".secrets.yml: Found (infrastructure secrets)"
    else
        print_warning ".secrets.yml: NOT FOUND (needed for Linode/Cloudflare)"
        print_hint "Copy .secrets.example.yml to .secrets.yml and add your API tokens"
    fi

    # Check sites directory
    if [ -d "$PROJECT_ROOT/sites" ]; then
        local installed_count=$(find "$PROJECT_ROOT/sites" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        if [ "$installed_count" -gt 0 ]; then
            print_success "Sites directory: $installed_count site(s) installed"
        else
            print_info "Sites directory: exists but empty"
        fi
    else
        print_info "Sites directory: NOT FOUND (will be created on first install)"
    fi

    return $errors
}

check_network() {
    local errors=0

    print_header "Checking Network Connectivity"

    # Linode API
    if curl -sf --max-time 5 "https://api.linode.com/v4/regions" -o /dev/null 2>&1; then
        print_success "Linode API: Reachable"
    else
        print_warning "Linode API: Unreachable (may affect server commands)"
        print_hint "Check your internet connection or firewall settings"
    fi

    # Cloudflare API
    if curl -sf --max-time 5 "https://api.cloudflare.com/client/v4" -o /dev/null 2>&1; then
        print_success "Cloudflare API: Reachable"
    else
        print_warning "Cloudflare API: Unreachable (may affect DNS commands)"
        print_hint "Check your internet connection or firewall settings"
    fi

    # drupal.org
    if curl -sf --max-time 5 "https://www.drupal.org/" -o /dev/null 2>&1; then
        print_success "drupal.org: Reachable"
    else
        print_warning "drupal.org: Unreachable (may affect Drupal downloads)"
        print_hint "Check your internet connection"
    fi

    return $errors
}

check_common_issues() {
    local errors=0

    print_header "Checking for Common Issues"

    # Docker daemon running (already checked in prerequisites, but good to confirm)
    if docker info &>/dev/null; then
        print_success "Docker daemon: Running"
    else
        print_error "Docker daemon: NOT RUNNING"
        print_hint "Start Docker Desktop or run: sudo systemctl start docker"
        ((errors++))
    fi

    # DDEV running sites
    if command -v ddev &>/dev/null; then
        # Use JSON output for reliable counting (avoids ANSI color code issues)
        local running_sites=$(ddev list --json-output 2>/dev/null | jq '[.raw[] | select(.status=="running")] | length' 2>/dev/null || echo "0")
        # Ensure we have a valid integer
        running_sites="${running_sites:-0}"
        if [ "$running_sites" -gt 0 ] 2>/dev/null; then
            print_info "DDEV sites running: $running_sites"
        else
            print_info "DDEV sites running: 0"
        fi
    fi

    # Disk space
    local disk_usage=$(df -h "$PROJECT_ROOT" 2>/dev/null | tail -1 || echo "")
    if [ -n "$disk_usage" ]; then
        local disk_free=$(echo "$disk_usage" | awk '{print $4}')
        local disk_percent=$(echo "$disk_usage" | awk '{print $5}' | tr -d '%')

        if [ "$disk_percent" -gt 90 ]; then
            print_warning "Disk space: ${disk_free} free (${disk_percent}% used)"
            print_hint "Consider freeing up disk space - DDEV and Docker can use significant storage"
        else
            print_success "Disk space: ${disk_free} free (${disk_percent}% used)"
        fi
    else
        print_warning "Disk space: Unable to check"
    fi

    # Memory (Linux only)
    if command -v free &>/dev/null; then
        local mem_available=$(free -h 2>/dev/null | grep "Mem:" | awk '{print $7}')
        if [ -n "$mem_available" ]; then
            print_info "Memory available: $mem_available"
        fi
    fi

    return $errors
}

################################################################################
# Main Function
################################################################################

main() {
    local verbose=0
    local quiet=0
    local total_errors=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                verbose=1
                shift
                ;;
            -q|--quiet)
                quiet=1
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo ""
                show_help
                exit 1
                ;;
        esac
    done

    # Print banner
    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║          NWP Doctor v0.20.0            ║"
    echo "╚════════════════════════════════════════╝"
    echo ""

    # Run all checks
    check_prerequisites || total_errors=$((total_errors + $?))
    echo ""

    check_configuration || total_errors=$((total_errors + $?))
    echo ""

    check_network || total_errors=$((total_errors + $?))
    echo ""

    check_common_issues || total_errors=$((total_errors + $?))
    echo ""

    # Print summary
    print_header "Summary"

    if [ "$total_errors" -eq 0 ]; then
        print_success "All checks passed! NWP is ready to use."
        exit 0
    else
        print_error "$total_errors issue(s) found"
        print_hint "Fix the issues above and run 'pl doctor' again"
        exit 1
    fi
}

# Run main function
main "$@"
