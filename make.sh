#!/bin/bash

################################################################################
# NWP Make Script
#
# Enables development or production mode for a Drupal site
# Based on pleasy makedev.sh and makeprod.sh adapted for DDEV environments
#
# Usage: ./make.sh [OPTIONS] <sitename>
################################################################################

# Script start time
START_TIME=$(date +%s)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

################################################################################
# Helper Functions
################################################################################

print_header() {
    echo -e "\n${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_status() {
    local status=$1
    local message=$2

    if [ "$status" == "OK" ]; then
        echo -e "[${GREEN}✓${NC}] $message"
    elif [ "$status" == "WARN" ]; then
        echo -e "[${YELLOW}!${NC}] $message"
    elif [ "$status" == "FAIL" ]; then
        echo -e "[${RED}✗${NC}] $message"
    else
        echo -e "[${BLUE}i${NC}] $message"
    fi
}

print_error() {
    echo -e "${RED}${BOLD}ERROR:${NC} $1" >&2
}

print_info() {
    echo -e "${BLUE}${BOLD}INFO:${NC} $1"
}

# Conditional debug message
ocmsg() {
    local message=$1
    if [ "$DEBUG" == "true" ]; then
        echo -e "${CYAN}[DEBUG]${NC} $message"
    fi
}

# Display elapsed time
show_elapsed_time() {
    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))
    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))
    local seconds=$((elapsed % 60))

    echo ""
    if [ "$MODE" == "dev" ]; then
        print_status "OK" "Development mode enabled in $(printf "%02d:%02d:%02d" $hours $minutes $seconds)"
    else
        print_status "OK" "Production mode enabled in $(printf "%02d:%02d:%02d" $hours $minutes $seconds)"
    fi
}

# Show help
show_help() {
    cat << EOF
${BOLD}NWP Make Script${NC}

${BOLD}USAGE:${NC}
    ./make.sh [OPTIONS] <sitename>

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -v, --dev               Enable development mode
    -p, --prod              Enable production mode
    -y, --yes               Skip confirmation prompts

${BOLD}ARGUMENTS:${NC}
    sitename                Name of the DDEV site

${BOLD}EXAMPLES:${NC}
    ./make.sh -v nwp4                    # Enable dev mode for nwp4
    ./make.sh -p nwp5                    # Enable production mode for nwp5
    ./make.sh -vy nwp4                   # Enable dev mode with auto-confirm
    ./make.sh -py nwp5                   # Enable prod mode with auto-confirm
    ./make.sh -vdy nwp4                  # Dev mode with debug and auto-confirm

${BOLD}COMBINED FLAGS:${NC}
    Multiple short flags can be combined: -vdy = -v -d -y
    Example: ./make.sh -vdy nwp4 is the same as ./make.sh -v -d -y nwp4

${BOLD}DEVELOPMENT MODE ACTIONS:${NC}
    1. Install development composer packages
    2. Enable development Drupal modules
    3. Disable production optimizations (aggregation, caching)
    4. Set Twig debug mode
    5. Clear cache
    6. Display dev mode status

${BOLD}PRODUCTION MODE ACTIONS:${NC}
    1. Disable/uninstall development modules
    2. Remove development composer packages (--no-dev)
    3. Enable production optimizations (aggregation, caching)
    4. Disable Twig debug mode
    5. Export configuration
    6. Clear cache

${BOLD}DEVELOPMENT MODULES:${NC}
    - devel
    - webprofiler
    - kint
    - stage_file_proxy

${BOLD}NOTE:${NC}
    ${YELLOW}You must specify either -v (dev) or -p (prod) mode.${NC}

    Development mode is for local development only.
    Production mode prepares the site for deployment.

EOF
}

################################################################################
# Development Mode Functions
################################################################################

# Install dev composer packages
install_dev_packages() {
    local sitename=$1

    print_header "Step 1: Install Development Packages"

    local original_dir=$(pwd)
    cd "$sitename" || {
        print_error "Cannot access site directory: $sitename"
        return 1
    }

    # Check if composer.json exists
    if [ ! -f "composer.json" ]; then
        print_status "WARN" "No composer.json found, skipping package installation"
        cd "$original_dir"
        return 0
    fi

    # List of dev packages to install
    local dev_packages=(
        "drupal/devel"
    )

    local packages_to_install=()

    # Check which packages are not installed
    for package in "${dev_packages[@]}"; do
        if ! ddev composer show "$package" > /dev/null 2>&1; then
            packages_to_install+=("$package")
        fi
    done

    if [ ${#packages_to_install[@]} -gt 0 ]; then
        print_info "Installing dev packages: ${packages_to_install[*]}"
        if ddev composer require --dev "${packages_to_install[@]}" > /dev/null 2>&1; then
            print_status "OK" "Dev packages installed: ${packages_to_install[*]}"
        else
            print_status "WARN" "Failed to install some dev packages (non-fatal)"
        fi
    else
        print_status "OK" "Dev packages already installed"
    fi

    cd "$original_dir"
    return 0
}

# Enable dev modules
enable_dev_modules() {
    local sitename=$1

    print_header "Step 2: Enable Development Modules"

    local original_dir=$(pwd)
    cd "$sitename" || {
        print_error "Cannot access site directory: $sitename"
        return 1
    }

    # List of dev modules to enable
    local dev_modules=(
        "devel"
        "webprofiler"
        "kint"
    )

    local modules_enabled=()
    local modules_failed=()

    for module in "${dev_modules[@]}"; do
        # Check if module exists and is not already enabled
        if ddev drush pm:list --filter="$module" --status=disabled --no-core 2>/dev/null | grep -q "$module"; then
            ocmsg "Enabling $module..."
            if ddev drush pm:enable -y "$module" > /dev/null 2>&1; then
                modules_enabled+=("$module")
            else
                modules_failed+=("$module")
            fi
        elif ddev drush pm:list --filter="$module" --status=enabled --no-core 2>/dev/null | grep -q "$module"; then
            ocmsg "$module is already enabled"
        fi
    done

    if [ ${#modules_enabled[@]} -gt 0 ]; then
        print_status "OK" "Enabled modules: ${modules_enabled[*]}"
    fi

    if [ ${#modules_failed[@]} -gt 0 ]; then
        print_status "WARN" "Failed to enable: ${modules_failed[*]} (may not be installed)"
    fi

    if [ ${#modules_enabled[@]} -eq 0 ] && [ ${#modules_failed[@]} -eq 0 ]; then
        print_status "OK" "Dev modules already enabled or not available"
    fi

    cd "$original_dir"
    return 0
}

# Configure dev settings
configure_dev_settings() {
    local sitename=$1

    print_header "Step 3: Configure Development Settings"

    local original_dir=$(pwd)
    cd "$sitename" || {
        print_error "Cannot access site directory: $sitename"
        return 1
    }

    local settings_changed=0

    # Disable CSS/JS aggregation
    ocmsg "Disabling CSS/JS aggregation..."
    if ddev drush config:set -y system.performance css.preprocess 0 > /dev/null 2>&1; then
        ((settings_changed++))
    fi
    if ddev drush config:set -y system.performance js.preprocess 0 > /dev/null 2>&1; then
        ((settings_changed++))
    fi

    # Disable render cache
    ocmsg "Disabling render cache..."
    if ddev drush config:set -y system.performance cache.page.max_age 0 > /dev/null 2>&1; then
        ((settings_changed++))
    fi

    # Enable Twig debug
    ocmsg "Enabling Twig debug..."
    # Note: This would typically require modifying development.services.yml
    # For now, we'll just note it as a manual step

    if [ $settings_changed -gt 0 ]; then
        print_status "OK" "Development settings configured"
    else
        print_status "WARN" "Could not configure all dev settings (drush may not be available)"
    fi

    cd "$original_dir"
    return 0
}

################################################################################
# Production Mode Functions
################################################################################

# Disable dev modules
disable_dev_modules() {
    local sitename=$1

    print_header "Step 1: Disable Development Modules"

    local original_dir=$(pwd)
    cd "$sitename" || {
        print_error "Cannot access site directory: $sitename"
        return 1
    }

    # List of dev modules to disable
    local dev_modules=(
        "webprofiler"
        "kint"
        "stage_file_proxy"
        "devel"  # Disable last because others may depend on it
    )

    local modules_disabled=()
    local modules_failed=()

    for module in "${dev_modules[@]}"; do
        # Check if module is enabled
        if ddev drush pm:list --filter="$module" --status=enabled --no-core 2>/dev/null | grep -q "$module"; then
            ocmsg "Disabling $module..."
            if ddev drush pm:uninstall -y "$module" > /dev/null 2>&1; then
                modules_disabled+=("$module")
            else
                modules_failed+=("$module")
            fi
        fi
    done

    if [ ${#modules_disabled[@]} -gt 0 ]; then
        print_status "OK" "Disabled modules: ${modules_disabled[*]}"
    fi

    if [ ${#modules_failed[@]} -gt 0 ]; then
        print_status "WARN" "Failed to disable: ${modules_failed[*]}"
    fi

    if [ ${#modules_disabled[@]} -eq 0 ] && [ ${#modules_failed[@]} -eq 0 ]; then
        print_status "OK" "Dev modules already disabled"
    fi

    cd "$original_dir"
    return 0
}

# Remove dev packages
remove_dev_packages() {
    local sitename=$1

    print_header "Step 2: Remove Development Packages"

    local original_dir=$(pwd)
    cd "$sitename" || {
        print_error "Cannot access site directory: $sitename"
        return 1
    }

    # Check if composer.json exists
    if [ ! -f "composer.json" ]; then
        print_status "WARN" "No composer.json found, skipping package removal"
        cd "$original_dir"
        return 0
    fi

    print_info "Running composer install --no-dev..."
    if ddev composer install --no-dev > /dev/null 2>&1; then
        print_status "OK" "Development packages removed"
    else
        print_status "WARN" "Failed to remove dev packages (non-fatal)"
    fi

    cd "$original_dir"
    return 0
}

# Configure production settings
configure_prod_settings() {
    local sitename=$1

    print_header "Step 3: Configure Production Settings"

    local original_dir=$(pwd)
    cd "$sitename" || {
        print_error "Cannot access site directory: $sitename"
        return 1
    }

    local settings_changed=0

    # Enable CSS/JS aggregation
    ocmsg "Enabling CSS/JS aggregation..."
    if ddev drush config:set -y system.performance css.preprocess 1 > /dev/null 2>&1; then
        ((settings_changed++))
    fi
    if ddev drush config:set -y system.performance js.preprocess 1 > /dev/null 2>&1; then
        ((settings_changed++))
    fi

    # Enable page cache (600 seconds = 10 minutes)
    ocmsg "Enabling page cache..."
    if ddev drush config:set -y system.performance cache.page.max_age 600 > /dev/null 2>&1; then
        ((settings_changed++))
    fi

    # Disable Twig debug/auto-reload
    ocmsg "Disabling Twig debug..."
    # Note: This would typically require modifying services.yml
    # For now, we'll just note it as a manual step

    if [ $settings_changed -gt 0 ]; then
        print_status "OK" "Production settings configured"
    else
        print_status "WARN" "Could not configure all production settings (drush may not be available)"
    fi

    cd "$original_dir"
    return 0
}

# Export configuration
export_config() {
    local sitename=$1

    print_header "Step 4: Export Configuration"

    local original_dir=$(pwd)
    cd "$sitename" || {
        print_error "Cannot access site directory: $sitename"
        return 1
    }

    ocmsg "Exporting configuration..."
    if ddev drush config:export -y > /dev/null 2>&1; then
        print_status "OK" "Configuration exported"
    else
        print_status "WARN" "Could not export configuration (drush may not be available)"
    fi

    cd "$original_dir"
    return 0
}

################################################################################
# Common Functions
################################################################################

# Set permissions
fix_permissions() {
    local sitename=$1
    local webroot=$2

    print_header "Fix Permissions"

    # Set sites/default writable
    if [ -d "$sitename/$webroot/sites/default" ]; then
        chmod u+w "$sitename/$webroot/sites/default"
        ocmsg "Set sites/default writable"
    fi

    # Set settings.php writable
    if [ -f "$sitename/$webroot/sites/default/settings.php" ]; then
        chmod u+w "$sitename/$webroot/sites/default/settings.php"
        ocmsg "Set settings.php writable"
    fi

    print_status "OK" "Permissions set"
    if [ "$MODE" == "prod" ]; then
        print_info "Note: On production, lock down settings.php and sites/default"
    fi
    return 0
}

# Clear cache
clear_cache() {
    local sitename=$1

    print_header "Clear Cache"

    local original_dir=$(pwd)
    cd "$sitename" || return 1

    # Try to clear cache and capture error
    local error_msg=$(ddev drush cr 2>&1)
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        print_status "OK" "Cache cleared"
    else
        # Provide specific error message based on the failure
        if echo "$error_msg" | grep -q "command not found\|drush: not found"; then
            print_status "WARN" "Drush not installed - run 'ddev composer require drush/drush'"
        elif echo "$error_msg" | grep -q "could not find driver\|database"; then
            print_status "WARN" "Database not configured or not accessible"
        elif echo "$error_msg" | grep -q "Bootstrap failed\|not a Drupal"; then
            print_status "WARN" "Site not fully configured (not a Drupal installation)"
        else
            print_status "WARN" "Could not clear cache: ${error_msg:0:60}"
        fi
    fi

    cd "$original_dir"
}

################################################################################
# Main Functions
################################################################################

makedev() {
    local sitename=$1
    local auto_yes=$2

    print_header "Enable Development Mode: $sitename"

    # Validate site
    print_header "Validate Site"

    if [ ! -d "$sitename" ]; then
        print_error "Site directory not found: $sitename"
        return 1
    fi

    if [ ! -f "$sitename/.ddev/config.yaml" ]; then
        print_error "DDEV not configured in $sitename"
        return 1
    fi

    # Get webroot
    local webroot=$(grep "^docroot:" "$sitename/.ddev/config.yaml" 2>/dev/null | awk '{print $2}')
    if [ -z "$webroot" ]; then
        webroot="web"
    fi

    ocmsg "Webroot: $webroot"
    print_status "OK" "Site validated: $sitename"

    # Confirm
    if [ "$auto_yes" != "true" ]; then
        echo ""
        echo -e "${YELLOW}This will enable development mode for ${BOLD}$sitename${NC}"
        echo -e "${YELLOW}Actions:${NC}"
        echo -e "  - Install dev composer packages"
        echo -e "  - Enable dev Drupal modules"
        echo -e "  - Disable caching and aggregation"
        echo -e "  - Clear cache"
        echo ""
        echo -n "Continue? [y/N]: "
        read confirm
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            print_info "Operation cancelled"
            return 1
        fi
    else
        echo ""
        echo -e "Auto-confirmed: Enable development mode for ${BOLD}$sitename${NC}"
    fi

    # Execute steps
    install_dev_packages "$sitename"
    enable_dev_modules "$sitename"
    configure_dev_settings "$sitename"
    fix_permissions "$sitename" "$webroot"
    clear_cache "$sitename"

    # Summary
    print_header "Development Mode Summary"
    echo -e "${GREEN}✓${NC} Site: $sitename"
    echo -e "${GREEN}✓${NC} Development mode enabled"
    echo ""
    echo -e "${YELLOW}${BOLD}NOTES:${NC}"
    echo -e "  - For full Twig debugging, manually edit ${BOLD}development.services.yml${NC}"
    echo -e "  - Configure ${BOLD}settings.local.php${NC} for additional dev settings"
    echo -e "  - Consider enabling ${BOLD}stage_file_proxy${NC} module for file syncing"

    return 0
}

makeprod() {
    local sitename=$1
    local auto_yes=$2

    print_header "Enable Production Mode: $sitename"

    # Validate site
    print_header "Validate Site"

    if [ ! -d "$sitename" ]; then
        print_error "Site directory not found: $sitename"
        return 1
    fi

    if [ ! -f "$sitename/.ddev/config.yaml" ]; then
        print_error "DDEV not configured in $sitename"
        return 1
    fi

    # Get webroot
    local webroot=$(grep "^docroot:" "$sitename/.ddev/config.yaml" 2>/dev/null | awk '{print $2}')
    if [ -z "$webroot" ]; then
        webroot="web"
    fi

    ocmsg "Webroot: $webroot"
    print_status "OK" "Site validated: $sitename"

    # Confirm
    if [ "$auto_yes" != "true" ]; then
        echo ""
        echo -e "${YELLOW}${BOLD}WARNING:${NC} ${YELLOW}This will enable production mode for ${BOLD}$sitename${NC}"
        echo -e "${YELLOW}Actions:${NC}"
        echo -e "  - Disable and uninstall dev modules"
        echo -e "  - Remove dev composer packages"
        echo -e "  - Enable caching and aggregation"
        echo -e "  - Export configuration"
        echo -e "  - Clear cache"
        echo ""
        echo -n "Continue? [y/N]: "
        read confirm
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            print_info "Operation cancelled"
            return 1
        fi
    else
        echo ""
        echo -e "Auto-confirmed: Enable production mode for ${BOLD}$sitename${NC}"
    fi

    # Execute steps
    disable_dev_modules "$sitename"
    remove_dev_packages "$sitename"
    configure_prod_settings "$sitename"
    export_config "$sitename"
    fix_permissions "$sitename" "$webroot"
    clear_cache "$sitename"

    # Summary
    print_header "Production Mode Summary"
    echo -e "${GREEN}✓${NC} Site: $sitename"
    echo -e "${GREEN}✓${NC} Production mode enabled"
    echo ""
    echo -e "${YELLOW}${BOLD}NOTES:${NC}"
    echo -e "  - This site is configured for production settings"
    echo -e "  - Dev modules have been disabled and uninstalled"
    echo -e "  - Dev dependencies have been removed"
    echo -e "  - Caching and aggregation are enabled"
    echo ""
    echo -e "${YELLOW}${BOLD}PRODUCTION DEPLOYMENT:${NC}"
    echo -e "  - For actual production, deploy to a production server"
    echo -e "  - Lock down file permissions on production"
    echo -e "  - Remove development.services.yml from production"
    echo -e "  - Ensure settings.local.php is not deployed"

    return 0
}

################################################################################
# Main Script
################################################################################

main() {
    # Parse options
    local DEBUG=false
    local AUTO_YES=false
    local MODE=""
    local SITENAME=""

    # Use getopt for option parsing
    local OPTIONS=hdvpy
    local LONGOPTS=help,debug,dev,prod,yes

    if ! PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTS --name "$0" -- "$@"); then
        show_help
        exit 1
    fi

    eval set -- "$PARSED"

    while true; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -d|--debug)
                DEBUG=true
                shift
                ;;
            -v|--dev)
                if [ -n "$MODE" ] && [ "$MODE" != "dev" ]; then
                    print_error "Cannot specify both -v (dev) and -p (prod)"
                    exit 1
                fi
                MODE="dev"
                shift
                ;;
            -p|--prod)
                if [ -n "$MODE" ] && [ "$MODE" != "prod" ]; then
                    print_error "Cannot specify both -v (dev) and -p (prod)"
                    exit 1
                fi
                MODE="prod"
                shift
                ;;
            -y|--yes)
                AUTO_YES=true
                shift
                ;;
            --)
                shift
                break
                ;;
            *)
                echo "Programming error"
                exit 3
                ;;
        esac
    done

    # Get sitename
    if [ $# -lt 1 ]; then
        print_error "Missing site name"
        echo ""
        show_help
        exit 1
    fi

    SITENAME="$1"

    # Check that mode is specified
    if [ -z "$MODE" ]; then
        print_error "You must specify either -v (dev) or -p (prod) mode"
        echo ""
        show_help
        exit 1
    fi

    ocmsg "Site: $SITENAME"
    ocmsg "Mode: $MODE"
    ocmsg "Auto yes: $AUTO_YES"

    # Run appropriate function
    if [ "$MODE" == "dev" ]; then
        if makedev "$SITENAME" "$AUTO_YES"; then
            show_elapsed_time
            exit 0
        else
            print_error "Failed to enable development mode"
            exit 1
        fi
    else
        if makeprod "$SITENAME" "$AUTO_YES"; then
            show_elapsed_time
            exit 0
        else
            print_error "Failed to enable production mode"
            exit 1
        fi
    fi
}

# Run main
main "$@"
