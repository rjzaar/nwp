#!/bin/bash

################################################################################
# NWP OpenSocial Testing Script
#
# Comprehensive testing script for OpenSocial distributions
# Supports Behat, PHPUnit, PHPStan, and code quality tests
#
# Usage: ./testos.sh [OPTIONS] <sitename>
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
    print_status "OK" "Tests completed in $(printf "%02d:%02d:%02d" $hours $minutes $seconds)"
}

# Show help
show_help() {
    cat << EOF
${BOLD}NWP OpenSocial Testing Script${NC}

${BOLD}USAGE:${NC}
    ./testos.sh [OPTIONS] <sitename>

${BOLD}TEST TYPE OPTIONS:${NC}
    -b, --behat             Run Behat behavioral tests
    -u, --phpunit           Run all PHPUnit tests (unit + kernel)
    -U, --unit              Run PHPUnit unit tests only
    -k, --kernel            Run PHPUnit kernel tests only
    -s, --phpstan           Run PHPStan static analysis
    -c, --codesniff         Run PHP CodeSniffer (code standards)
    -a, --all               Run all tests (behat + phpunit + phpstan)

${BOLD}BEHAT-SPECIFIC OPTIONS:${NC}
    -f, --feature=NAME      Run specific feature/capability (e.g., groups, events)
    -t, --tag=TAG           Run tests with specific tag
    --list-features         List all available Behat features
    --headless              Run Behat in headless mode (default)
    --headed                Run Behat with visible browser

${BOLD}PHPUNIT-SPECIFIC OPTIONS:${NC}
    --group=NAME            Run specific PHPUnit test group
    --coverage              Generate code coverage report
    --testdox               Output results in testdox format

${BOLD}GENERAL OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -y, --yes               Skip confirmation prompts
    -v, --verbose           Verbose test output
    --stop-on-failure       Stop on first test failure

${BOLD}ARGUMENTS:${NC}
    sitename                Name of the OpenSocial site to test

${BOLD}EXAMPLES:${NC}
    # Run all Behat tests
    ./testos.sh -b nwp1

    # Run PHPUnit unit tests only
    ./testos.sh -U nwp1

    # Run specific Behat feature
    ./testos.sh -b -f groups nwp1

    # Run all tests
    ./testos.sh -a nwp1

    # Run tests with specific tag
    ./testos.sh -b -t @api nwp1

    # Run PHPStan static analysis
    ./testos.sh -s nwp1

    # List available features
    ./testos.sh --list-features nwp1

${BOLD}AVAILABLE BEHAT FEATURES:${NC}
    account                 Account management tests
    activity-stream         Activity stream functionality
    administration          Admin interface tests
    book                    Book functionality
    comment                 Comment system tests
    contentmanagement       Content management
    embed                   Embed functionality
    event                   Event creation and management
    event-an-enroll         Anonymous event enrollment
    event-management        Event management features
    follow-taxonomy         Follow taxonomy terms
    follow-users            Follow users functionality
    gdpr                    GDPR compliance tests
    groups                  Group functionality
    install                 Installation tests
    landing-page            Landing page tests
    language                Multilingual tests
    like                    Like functionality
    login                   Login/authentication
    ... and more

${BOLD}PHPUNIT TEST SUITES:${NC}
    unit                    Unit tests (isolated, no database)
    kernel                  Kernel tests (with database)
    phpstan                 PHPStan static analysis tests

${BOLD}NOTE:${NC}
    - Site must be a valid DDEV OpenSocial installation
    - Chrome browser required for Behat tests
    - Tests run inside DDEV container

EOF
}

################################################################################
# Validation Functions
################################################################################

# Get docroot from DDEV config
get_docroot() {
    local site=$1
    local docroot=$(grep '^docroot:' "$site/.ddev/config.yaml" | awk '{print $2}')

    if [ -z "$docroot" ]; then
        # Default to 'web' if not found
        docroot="web"
    fi

    echo "$docroot"
}

validate_site() {
    local site=$1

    print_header "Validating Site"

    # Check if site exists
    if [ ! -d "$site" ]; then
        print_error "Site not found: $site"
        return 1
    fi

    # Check if it's a DDEV site
    if [ ! -f "$site/.ddev/config.yaml" ]; then
        print_error "Not a DDEV site: $site"
        return 1
    fi

    print_status "OK" "Site validated: $site"

    # Get the docroot for this site
    local docroot=$(get_docroot "$site")
    ocmsg "Detected docroot: $docroot"

    # Check if it's OpenSocial
    if [ ! -d "$site/$docroot/profiles/contrib/social" ]; then
        print_status "WARN" "This may not be an OpenSocial site"
        print_info "OpenSocial profile not found at: $site/$docroot/profiles/contrib/social"

        if [ "$AUTO_YES" != "true" ]; then
            echo -n "Continue anyway? [y/N]: "
            read confirm
            if [[ ! "$confirm" =~ ^[Yy] ]]; then
                print_info "Testing cancelled"
                return 1
            fi
        fi
    else
        print_status "OK" "OpenSocial profile found"
    fi

    return 0
}

# Install testing dependencies
install_test_dependencies() {
    local site=$1

    print_header "Checking Testing Dependencies"

    local original_dir=$(pwd)
    cd "$site" || {
        print_error "Cannot access site: $site"
        return 1
    }

    # Check if Behat and required dependencies are installed
    if ddev exec 'test -f /var/www/html/vendor/bin/behat && test -d /var/www/html/vendor/dmore/behat-chrome-extension && test -d /var/www/html/vendor/friends-of-behat/mink-debug-extension' 2>/dev/null; then
        print_status "OK" "Testing dependencies already installed"
        cd "$original_dir"
        return 0
    fi

    print_status "WARN" "Testing dependencies not found"
    print_info "Installing Behat, PHPUnit, and other testing tools..."

    # Allow required Composer plugins first
    ddev composer config --no-plugins allow-plugins.dealerdirect/phpcodesniffer-composer-installer true > /dev/null 2>&1
    ddev composer config --no-plugins allow-plugins.phpstan/extension-installer true > /dev/null 2>&1

    # Install testing dependencies
    if ! ddev composer require --dev \
        "drupal/drupal-extension:*" \
        "behat/behat:*" \
        "dmore/behat-chrome-extension:*" \
        "friends-of-behat/mink-debug-extension:*" \
        "phpunit/phpunit:*" \
        "phpstan/phpstan:*" \
        "drupal/coder:*" 2>&1 | tail -20; then
        print_error "Failed to install testing dependencies"
        cd "$original_dir"
        return 1
    fi

    print_status "OK" "Testing dependencies installed successfully"
    cd "$original_dir"
    return 0
}

# Install and configure Selenium
install_selenium() {
    local site=$1

    print_header "Checking Selenium Chrome"

    local original_dir=$(pwd)
    cd "$site" || {
        print_error "Cannot access site: $site"
        return 1
    }

    # Check if Selenium addon is already installed
    if [ -d ".ddev/selenium-standalone-chrome" ]; then
        print_status "OK" "Selenium Chrome already installed"

        # Check if it's running
        if ddev exec 'curl -s http://chrome:4444/wd/hub/status' > /dev/null 2>&1; then
            print_status "OK" "Selenium Chrome is running"
        else
            print_status "WARN" "Selenium Chrome not running, restarting DDEV..."
            ddev restart > /dev/null 2>&1
        fi

        cd "$original_dir"
        return 0
    fi

    print_status "WARN" "Selenium Chrome not found"
    print_info "Installing Selenium Chrome addon for DDEV..."

    # Install the selenium addon
    if ! ddev get ddev/ddev-selenium-standalone-chrome 2>&1 | tail -10; then
        print_error "Failed to install Selenium Chrome addon"
        cd "$original_dir"
        return 1
    fi

    # Restart DDEV to apply changes
    print_info "Restarting DDEV to activate Selenium..."
    if ! ddev restart 2>&1 | tail -5; then
        print_error "Failed to restart DDEV"
        cd "$original_dir"
        return 1
    fi

    # Wait a moment for Selenium to start
    print_info "Waiting for Selenium to start..."
    sleep 5

    # Verify Selenium is running
    if ddev exec 'curl -s http://chrome:4444/wd/hub/status' > /dev/null 2>&1; then
        print_status "OK" "Selenium Chrome installed and running"
    else
        print_status "WARN" "Selenium installed but may not be fully ready"
    fi

    cd "$original_dir"
    return 0
}

# Configure Behat for the site
configure_behat() {
    local site=$1

    print_header "Configuring Behat"

    local original_dir=$(pwd)
    cd "$site" || {
        print_error "Cannot access site: $site"
        return 1
    }

    local docroot=$(get_docroot ".")
    local social_path="$docroot/profiles/contrib/social"
    local behat_dir="$social_path/tests/behat"
    local custom_behat="$behat_dir/behat.nwp.yml"

    # Check if custom config already exists
    if [ -f "$custom_behat" ]; then
        print_status "OK" "Custom Behat config already exists"
        cd "$original_dir"
        return 0
    fi

    print_info "Creating custom Behat configuration..."

    # Get the site URL from DDEV
    local site_url=$(ddev describe -j | grep -o '"https://[^"]*"' | head -1 | tr -d '"')
    if [ -z "$site_url" ]; then
        # Fallback to constructing URL from directory name
        site_url="https://$(basename $(pwd)).ddev.site"
    fi

    # Create custom behat.yml with correct paths and Selenium configuration
    cat > "$custom_behat" << 'BEHAT_EOF'
default:
  suites:
    default:
      paths:
        - '%paths.base%/features/capabilities'
      contexts:
        - Drupal\social\Behat\DatabaseContext:
            - '%paths.base%/fixture'
        - Drupal\DrupalExtension\Context\BatchContext
        - Drupal\social\Behat\AlbumContext
        - Drupal\social\Behat\BookContext
        - Drupal\social\Behat\CKEditorContext
        - Drupal\social\Behat\ConfigContext
        - Drupal\social\Behat\EmailContext
        - Drupal\social\Behat\EventContext
        - Drupal\social\Behat\GroupContext
        - Drupal\social\Behat\GDPRContext
        - Drupal\social\Behat\PostContext
        - Drupal\social\Behat\FeatureContext
        - Drupal\social\Behat\FileContext
        - Drupal\social\Behat\LogContext
        - Drupal\social\Behat\ModuleContext
        - Drupal\social\Behat\ProfileContext
        - Drupal\social\Behat\SearchContext
        - Drupal\social\Behat\SocialDrupalContext
        - Drupal\social\Behat\SocialMessageContext
        - Drupal\social\Behat\SocialMinkContext
        - Drupal\social\Behat\ThemeContext
        - Drupal\social\Behat\TopicContext
        - Drupal\social\Behat\UserContext
        - Drupal\social\Behat\TaggingContext
  extensions:
    FriendsOfBehat\MinkDebugExtension:
      directory: '%paths.base%/../../reports/behat'
      clean_start: false
      screenshot: true
    Drupal\MinkExtension:
      base_url: 'SITE_URL_PLACEHOLDER'
      files_path: '%paths.base%/fixtures/files'
      browser_name: chrome
      javascript_session: selenium2
      selenium2:
        wd_host: 'http://chrome:4444/wd/hub'
        capabilities:
          chrome:
            switches:
              - '--headless'
              - '--disable-gpu'
              - '--no-sandbox'
              - '--disable-dev-shm-usage'
              - '--disable-extensions'
              - '--disable-software-rasterizer'
    Drupal\DrupalExtension:
      api_driver: 'drupal'
      drupal:
        drupal_root: '/var/www/html/DOCROOT_PLACEHOLDER'
      selectors:
        message_selector: '.messages'
        error_message_selector: '.messages.error'
        success_message_selector: '.messages.success'
        warning_message_selector: '.messages.warning'
      region_map:
        left sidebar: ".region-sidebar-first"
        right sidebar: ".region-sidebar-second"
        navbar: ".navbar"
        hero: ".hero"
        page: ".page-wrapper"
BEHAT_EOF

    # Replace placeholders with actual values
    sed -i "s|SITE_URL_PLACEHOLDER|$site_url|g" "$custom_behat"
    sed -i "s|DOCROOT_PLACEHOLDER|$docroot|g" "$custom_behat"

    print_status "OK" "Behat configuration created at: $social_path/tests/behat/behat.nwp.yml"
    print_info "Base URL: $site_url"
    print_info "Drupal root: /var/www/html/$docroot"

    cd "$original_dir"
    return 0
}

################################################################################
# Test Execution Functions
################################################################################

# Run Behat tests
run_behat_tests() {
    local site=$1
    local feature=$2
    local tag=$3

    print_header "Running Behat Tests"

    local original_dir=$(pwd)
    cd "$site" || {
        print_error "Cannot access site: $site"
        return 1
    }

    # Ensure DDEV is running
    print_info "Ensuring DDEV is running..."
    ddev start > /dev/null 2>&1

    # Get docroot for this site
    local docroot=$(get_docroot ".")
    local social_path="$docroot/profiles/contrib/social"
    local behat_config="/var/www/html/$social_path/tests/behat/behat.nwp.yml"
    local features_path="/var/www/html/$social_path/tests/behat/features/capabilities"

    # Use custom config if it exists, otherwise fall back to original
    if [ ! -f "$social_path/tests/behat/behat.nwp.yml" ]; then
        behat_config="/var/www/html/$social_path/tests/behat/behat.yml"
        print_status "WARN" "Using original behat.yml (custom config not found)"
    else
        print_status "OK" "Using custom behat.nwp.yml configuration"
    fi

    # Build behat command (run from project root with config path)
    local behat_cmd="ddev exec 'cd /var/www/html && vendor/bin/behat -c $behat_config"

    if [ -n "$feature" ]; then
        behat_cmd="$behat_cmd --suite=default $features_path/$feature"
    else
        behat_cmd="$behat_cmd --suite=default"
    fi

    if [ -n "$tag" ]; then
        behat_cmd="$behat_cmd --tags=$tag"
    fi

    if [ "$VERBOSE" == "true" ]; then
        behat_cmd="$behat_cmd -v"
    fi

    if [ "$STOP_ON_FAILURE" == "true" ]; then
        behat_cmd="$behat_cmd --stop-on-failure"
    fi

    behat_cmd="$behat_cmd'"

    ocmsg "Executing: $behat_cmd"

    # Run behat
    print_status "INFO" "Running Behat tests..."
    if eval "$behat_cmd"; then
        print_status "OK" "Behat tests passed"
        cd "$original_dir"
        return 0
    else
        print_status "FAIL" "Behat tests failed"
        cd "$original_dir"
        return 1
    fi
}

# Run PHPUnit tests
run_phpunit_tests() {
    local site=$1
    local suite=$2
    local group=$3

    print_header "Running PHPUnit Tests: $suite"

    local original_dir=$(pwd)
    cd "$site" || {
        print_error "Cannot access site: $site"
        return 1
    }

    # Ensure DDEV is running
    print_info "Ensuring DDEV is running..."
    ddev start > /dev/null 2>&1

    # Get docroot for this site
    local docroot=$(get_docroot ".")
    local social_path="$docroot/profiles/contrib/social"
    local phpunit_config="/var/www/html/$social_path/phpunit.xml.dist"

    # Build phpunit command (run from project root with config path)
    local phpunit_cmd="ddev exec 'cd /var/www/html && vendor/bin/phpunit -c $phpunit_config"

    if [ -n "$suite" ]; then
        phpunit_cmd="$phpunit_cmd --testsuite=$suite"
    fi

    if [ -n "$group" ]; then
        phpunit_cmd="$phpunit_cmd --group=$group"
    fi

    if [ "$COVERAGE" == "true" ]; then
        phpunit_cmd="$phpunit_cmd --coverage-html=coverage"
    fi

    if [ "$TESTDOX" == "true" ]; then
        phpunit_cmd="$phpunit_cmd --testdox"
    fi

    if [ "$VERBOSE" == "true" ]; then
        phpunit_cmd="$phpunit_cmd -v"
    fi

    if [ "$STOP_ON_FAILURE" == "true" ]; then
        phpunit_cmd="$phpunit_cmd --stop-on-failure"
    fi

    phpunit_cmd="$phpunit_cmd'"

    ocmsg "Executing: $phpunit_cmd"

    # Run phpunit
    print_status "INFO" "Running PHPUnit tests..."
    if eval "$phpunit_cmd"; then
        print_status "OK" "PHPUnit tests passed"
        cd "$original_dir"
        return 0
    else
        print_status "FAIL" "PHPUnit tests failed"
        cd "$original_dir"
        return 1
    fi
}

# Run PHPStan
run_phpstan() {
    local site=$1

    print_header "Running PHPStan Static Analysis"

    local original_dir=$(pwd)
    cd "$site" || {
        print_error "Cannot access site: $site"
        return 1
    }

    # Ensure DDEV is running
    print_info "Ensuring DDEV is running..."
    ddev start > /dev/null 2>&1

    # Get docroot for this site
    local docroot=$(get_docroot ".")
    local container_path="/var/www/html/$docroot/profiles/contrib/social"

    local phpstan_cmd="ddev exec 'cd $container_path && vendor/bin/phpstan analyse'"

    ocmsg "Executing: $phpstan_cmd"

    print_status "INFO" "Running PHPStan..."
    if eval "$phpstan_cmd"; then
        print_status "OK" "PHPStan analysis passed"
        cd "$original_dir"
        return 0
    else
        print_status "FAIL" "PHPStan analysis failed"
        cd "$original_dir"
        return 1
    fi
}

# Run PHP CodeSniffer
run_codesniff() {
    local site=$1

    print_header "Running PHP CodeSniffer"

    local original_dir=$(pwd)
    cd "$site" || {
        print_error "Cannot access site: $site"
        return 1
    }

    # Ensure DDEV is running
    print_info "Ensuring DDEV is running..."
    ddev start > /dev/null 2>&1

    # Get docroot for this site
    local docroot=$(get_docroot ".")
    local container_path="/var/www/html/$docroot/profiles/contrib/social"

    local phpcs_cmd="ddev exec 'cd $container_path && vendor/bin/phpcs --standard=Drupal,DrupalPractice modules/'"

    ocmsg "Executing: $phpcs_cmd"

    print_status "INFO" "Running PHP CodeSniffer..."
    if eval "$phpcs_cmd"; then
        print_status "OK" "Code standards check passed"
        cd "$original_dir"
        return 0
    else
        print_status "WARN" "Code standards issues found"
        cd "$original_dir"
        return 1
    fi
}

# List available Behat features
list_features() {
    local site=$1

    print_header "Available Behat Features"

    # Get docroot for this site
    local docroot=$(get_docroot "$site")
    local features_path="$site/$docroot/profiles/contrib/social/tests/behat/features/capabilities"

    if [ ! -d "$features_path" ]; then
        print_error "Features directory not found at: $features_path"
        return 1
    fi

    print_info "Available test features:\n"

    for feature in "$features_path"/*; do
        if [ -d "$feature" ]; then
            local feature_name=$(basename "$feature")
            local feature_count=$(find "$feature" -name "*.feature" | wc -l)
            echo -e "  ${GREEN}●${NC} ${BOLD}$feature_name${NC} ($feature_count scenarios)"
        fi
    done

    return 0
}

################################################################################
# Main Test Function
################################################################################

run_tests() {
    local site=$1

    # Validate site first
    if ! validate_site "$site"; then
        return 1
    fi

    # Install testing dependencies if needed
    if ! install_test_dependencies "$site"; then
        print_error "Cannot proceed without testing dependencies"
        return 1
    fi

    # Install Selenium for browser testing
    if ! install_selenium "$site"; then
        print_error "Cannot proceed without Selenium"
        return 1
    fi

    # Configure Behat with proper settings
    if ! configure_behat "$site"; then
        print_error "Cannot proceed without Behat configuration"
        return 1
    fi

    local has_failures=0

    # Run requested tests
    if [ "$RUN_BEHAT" == "true" ]; then
        if ! run_behat_tests "$site" "$FEATURE" "$TAG"; then
            has_failures=1
        fi
    fi

    if [ "$RUN_PHPUNIT" == "true" ]; then
        if ! run_phpunit_tests "$site" "" "$GROUP"; then
            has_failures=1
        fi
    fi

    if [ "$RUN_UNIT" == "true" ]; then
        if ! run_phpunit_tests "$site" "unit" "$GROUP"; then
            has_failures=1
        fi
    fi

    if [ "$RUN_KERNEL" == "true" ]; then
        if ! run_phpunit_tests "$site" "kernel" "$GROUP"; then
            has_failures=1
        fi
    fi

    if [ "$RUN_PHPSTAN" == "true" ]; then
        if ! run_phpstan "$site"; then
            has_failures=1
        fi
    fi

    if [ "$RUN_CODESNIFF" == "true" ]; then
        if ! run_codesniff "$site"; then
            has_failures=1
        fi
    fi

    if [ "$RUN_ALL" == "true" ]; then
        if ! run_behat_tests "$site" "$FEATURE" "$TAG"; then
            has_failures=1
        fi
        if ! run_phpunit_tests "$site" "" "$GROUP"; then
            has_failures=1
        fi
        if ! run_phpstan "$site"; then
            has_failures=1
        fi
    fi

    return $has_failures
}

################################################################################
# Main Script
################################################################################

main() {
    # Parse options
    local DEBUG=false
    local AUTO_YES=false
    local VERBOSE=false
    local STOP_ON_FAILURE=false
    local RUN_BEHAT=false
    local RUN_PHPUNIT=false
    local RUN_UNIT=false
    local RUN_KERNEL=false
    local RUN_PHPSTAN=false
    local RUN_CODESNIFF=false
    local RUN_ALL=false
    local COVERAGE=false
    local TESTDOX=false
    local FEATURE=""
    local TAG=""
    local GROUP=""
    local LIST_FEATURES=false
    local SITENAME=""

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -d|--debug)
                DEBUG=true
                shift
                ;;
            -y|--yes)
                AUTO_YES=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --stop-on-failure)
                STOP_ON_FAILURE=true
                shift
                ;;
            -b|--behat)
                RUN_BEHAT=true
                shift
                ;;
            -u|--phpunit)
                RUN_PHPUNIT=true
                shift
                ;;
            -U|--unit)
                RUN_UNIT=true
                shift
                ;;
            -k|--kernel)
                RUN_KERNEL=true
                shift
                ;;
            -s|--phpstan)
                RUN_PHPSTAN=true
                shift
                ;;
            -c|--codesniff)
                RUN_CODESNIFF=true
                shift
                ;;
            -a|--all)
                RUN_ALL=true
                shift
                ;;
            -f|--feature)
                FEATURE="$2"
                shift 2
                ;;
            --feature=*)
                FEATURE="${1#*=}"
                shift
                ;;
            -t|--tag)
                TAG="$2"
                shift 2
                ;;
            --tag=*)
                TAG="${1#*=}"
                shift
                ;;
            --group)
                GROUP="$2"
                shift 2
                ;;
            --group=*)
                GROUP="${1#*=}"
                shift
                ;;
            --coverage)
                COVERAGE=true
                shift
                ;;
            --testdox)
                TESTDOX=true
                shift
                ;;
            --list-features)
                LIST_FEATURES=true
                shift
                ;;
            --headless)
                # Default, no action needed
                shift
                ;;
            --headed)
                # Would need implementation for non-headless
                shift
                ;;
            -*)
                print_error "Unknown option: $1"
                echo ""
                show_help
                exit 1
                ;;
            *)
                SITENAME="$1"
                shift
                ;;
        esac
    done

    # Get sitename
    if [ -z "$SITENAME" ]; then
        print_error "Missing site name"
        echo ""
        show_help
        exit 1
    fi

    ocmsg "Site: $SITENAME"
    ocmsg "Debug: $DEBUG"
    ocmsg "Auto yes: $AUTO_YES"

    # Handle list features
    if [ "$LIST_FEATURES" == "true" ]; then
        list_features "$SITENAME"
        exit 0
    fi

    # Check if at least one test type is selected
    if [ "$RUN_BEHAT" != "true" ] && [ "$RUN_PHPUNIT" != "true" ] && \
       [ "$RUN_UNIT" != "true" ] && [ "$RUN_KERNEL" != "true" ] && \
       [ "$RUN_PHPSTAN" != "true" ] && [ "$RUN_CODESNIFF" != "true" ] && \
       [ "$RUN_ALL" != "true" ]; then
        print_error "No test type specified"
        print_info "Use -b (behat), -u (phpunit), -s (phpstan), -c (codesniff), or -a (all)"
        echo ""
        show_help
        exit 1
    fi

    # Run tests
    if run_tests "$SITENAME"; then
        show_elapsed_time
        exit 0
    else
        print_error "Some tests failed"
        show_elapsed_time
        exit 1
    fi
}

# Run main
main "$@"
