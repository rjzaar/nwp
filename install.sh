#!/bin/bash
set -euo pipefail

################################################################################
# NWP Installation Script
#
# Reads cnwp.yml and installs sites based on the specified recipe.
# Supports Drupal/OpenSocial, Moodle, GitLab, and Podcast (Castopod) installations.
#
# Usage: ./install.sh <recipe_name> [target_name] [options]
#
# Arguments:
#   recipe_name                  - Name of recipe from cnwp.yml
#   target_name                  - Optional: custom directory/site name
#
# Examples:
#   ./install.sh nwp              - Install using 'nwp' recipe in 'nwp' directory
#   ./install.sh nwp client1      - Install using 'nwp' recipe in 'client1' directory
#   ./install.sh nwp mysite s=3   - Resume 'mysite' installation from step 3
#   ./install.sh nwp site1 c      - Install 'nwp' recipe as 'site1' with test content
#
# Options:
#   c, --create-content          - Create test content (5 users, 5 docs, 5 workflow assignments)
#   s=N, --step=N                - Resume installation from step N
#
# Environment Variables:
#   TEST_PASSWORD                - Password for test users (default: test123)
#
# Installation Steps:
#   1  - Initialize project with Composer (includes Drush installation)
#   2  - Generate environment configuration (.env files)
#   3  - Configure DDEV
#   4  - Configure memory settings
#   5  - Start DDEV services
#   6  - Verify Drush is available
#   7  - Configure private file system
#   8  - Install Drupal profile
#   9  - Install additional modules and export config
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

################################################################################
# Source Required Libraries
################################################################################

# Core UI library (colors, status messages)
source "$SCRIPT_DIR/lib/ui.sh"

# Common utilities (validation, secrets)
source "$SCRIPT_DIR/lib/common.sh"

# Installation common functions (YAML parsing, options, utilities)
source "$SCRIPT_DIR/lib/install-common.sh"

# Optional: YAML write library for site registration
if [ -f "$SCRIPT_DIR/lib/yaml-write.sh" ]; then
    source "$SCRIPT_DIR/lib/yaml-write.sh"
fi

# Optional: Interactive checkbox library
if [ -f "$SCRIPT_DIR/lib/checkbox.sh" ]; then
    source "$SCRIPT_DIR/lib/checkbox.sh"
fi

# Optional: Linode library for DNS registration
if [ -f "$SCRIPT_DIR/lib/linode.sh" ]; then
    source "$SCRIPT_DIR/lib/linode.sh"
fi

# Optional: Install steps tracking
if [ -f "$SCRIPT_DIR/lib/install-steps.sh" ]; then
    source "$SCRIPT_DIR/lib/install-steps.sh"
fi

# Source TUI library
if [ -f "$SCRIPT_DIR/lib/tui.sh" ]; then
    source "$SCRIPT_DIR/lib/tui.sh"
fi

################################################################################
# Lazy Installer Loading
################################################################################

# Load type-specific installer on demand
# This avoids parsing unused code and improves startup time
load_installer() {
    local install_type="$1"
    local installer_file=""

    case "$install_type" in
        drupal|opensocial)
            installer_file="$SCRIPT_DIR/lib/install-drupal.sh"
            ;;
        moodle)
            installer_file="$SCRIPT_DIR/lib/install-moodle.sh"
            ;;
        gitlab)
            installer_file="$SCRIPT_DIR/lib/install-gitlab.sh"
            ;;
        podcast)
            installer_file="$SCRIPT_DIR/lib/install-podcast.sh"
            ;;
        *)
            print_error "Unknown install type: $install_type"
            print_info "Supported types: drupal, moodle, gitlab, podcast"
            return 1
            ;;
    esac

    if [ -f "$installer_file" ]; then
        source "$installer_file"
        return 0
    else
        print_error "Installer not found: $installer_file"
        return 1
    fi
}

################################################################################
# Migration Stub Handler
################################################################################

# Handle migration purpose - creates a stub directory for importing sites
handle_migration() {
    local recipe="$1"
    local target="$2"
    local config_file="${3:-cnwp.yml}"

    print_header "Migration Site Setup"

    # Determine target name
    local migration_name=""
    if [ -n "$target" ]; then
        migration_name="$target"
    else
        migration_name="${recipe}_pre"
    fi

    # Check if directory already exists
    if [ -d "$migration_name" ]; then
        print_error "Directory '$migration_name' already exists"
        exit 1
    fi

    # Create migration directory structure
    print_info "Creating migration stub directory: $migration_name"
    mkdir -p "$migration_name"

    # Create placeholder README
    cat > "$migration_name/README.md" << 'MIGRATION_README'
# Migration Site

This directory is prepared for site migration.

## Next Steps

1. Copy/extract your source site files into this directory
2. Run `./migration.sh analyze <sitename>` to analyze the source
3. Run `./migration.sh prepare <sitename>` to set up target Drupal
4. Run `./migration.sh run <sitename>` to execute migration
5. Run `./migration.sh verify <sitename>` to verify success

## Directory Structure

Place your source site here:
- For Drupal sites: Copy the entire Drupal root
- For static HTML: Create an `html/` subdirectory with your files
- For database dumps: Place SQL files in `database/` subdirectory

## Source Types Supported

- drupal7: Drupal 7 sites (uses Migrate API)
- drupal8/9: Drupal 8/9 sites (upgrade path)
- html: Static HTML sites (uses migrate_source_html)
- wordpress: WordPress sites (uses migrate_wordpress)
- other: Custom migration needed

MIGRATION_README

    # Create subdirectories for source content
    mkdir -p "$migration_name/database"
    mkdir -p "$migration_name/source"

    print_status "OK" "Created migration stub directory"

    # Register in cnwp.yml
    if command -v yaml_add_migration_stub &> /dev/null; then
        print_info "Registering migration site in cnwp.yml..."
        local site_dir="$SCRIPT_DIR/$migration_name"

        # Prompt for source type
        local source_type="other"
        echo ""
        echo "Select source type:"
        echo "  1) drupal7  - Drupal 7 site"
        echo "  2) drupal8  - Drupal 8 site"
        echo "  3) drupal9  - Drupal 9 site"
        echo "  4) html     - Static HTML site"
        echo "  5) wordpress - WordPress site"
        echo "  6) joomla   - Joomla site"
        echo "  7) other    - Other/custom"
        echo ""
        read -p "Enter choice [1-7, default=7]: " source_choice
        case "$source_choice" in
            1) source_type="drupal7" ;;
            2) source_type="drupal8" ;;
            3) source_type="drupal9" ;;
            4) source_type="html" ;;
            5) source_type="wordpress" ;;
            6) source_type="joomla" ;;
            *) source_type="other" ;;
        esac

        if yaml_add_migration_stub "$migration_name" "$site_dir" "$source_type" "" "$SCRIPT_DIR/cnwp.yml" 2>/dev/null; then
            print_status "OK" "Migration site registered in cnwp.yml"
        else
            print_warning "Could not register site in cnwp.yml"
        fi
    fi

    print_header "Migration Stub Complete"
    echo ""
    echo -e "${GREEN}Migration directory created: $migration_name${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Copy your source site files into: $migration_name/source/"
    echo "  2. Place database dumps in: $migration_name/database/"
    echo "  3. Run: ./migration.sh analyze $migration_name"
    echo ""
    exit 0
}

################################################################################
# Main Script
################################################################################

main() {
    local recipe=""
    local target=""
    local start_step=""
    local create_content="n"
    local config_file="cnwp.yml"
    local purpose="indefinite"
    local positional_args=()

    # Parse arguments
    for arg in "$@"; do
        if [[ "$arg" == "-l" ]] || [[ "$arg" == "--list" ]]; then
            list_recipes "$config_file"
            exit 0
        elif [[ "$arg" == "-h" ]] || [[ "$arg" == "--help" ]]; then
            show_help "$config_file"
            exit 0
        elif [[ "$arg" =~ ^s=([0-9]+)$ ]]; then
            start_step="${BASH_REMATCH[1]}"
        elif [[ "$arg" =~ ^--step=([0-9]+)$ ]]; then
            start_step="${BASH_REMATCH[1]}"
        elif [[ "$arg" == "c" ]] || [[ "$arg" == "--create-content" ]]; then
            create_content="y"
        elif [[ "$arg" =~ ^-p=(.+)$ ]] || [[ "$arg" =~ ^--purpose=(.+)$ ]]; then
            local purpose_arg="${BASH_REMATCH[1]}"
            # Map short codes to full values
            case "$purpose_arg" in
                t|testing) purpose="testing" ;;
                i|indefinite) purpose="indefinite" ;;
                p|permanent) purpose="permanent" ;;
                m|migration) purpose="migration" ;;
                *)
                    print_error "Invalid purpose: $purpose_arg"
                    echo "Valid values: t(esting), i(ndefinite), p(ermanent), m(igration)"
                    exit 1
                    ;;
            esac
        else
            positional_args+=("$arg")
        fi
    done

    # Extract recipe and optional target from positional arguments
    if [ ${#positional_args[@]} -ge 1 ]; then
        recipe="${positional_args[0]}"
    fi
    if [ ${#positional_args[@]} -ge 2 ]; then
        target="${positional_args[1]}"
    fi

    # Default recipe if not specified
    if [ -z "$recipe" ]; then
        show_help "$config_file"
        exit 1
    fi

    print_header "NWP OpenSocial Installation"

    if [ -n "$start_step" ]; then
        print_info "Resuming from step $start_step"
    fi

    # Check if config file exists
    if [ ! -f "$config_file" ]; then
        print_error "Configuration file '$config_file' not found"
        exit 1
    fi

    # Check if recipe exists
    if ! recipe_exists "$recipe" "$config_file"; then
        print_error "Recipe '$recipe' not found in $config_file"
        echo ""
        echo "Available recipes:"
        awk '
            /^recipes:/ { in_recipes = 1; next }
            /^[a-zA-Z]/ { in_recipes = 0 }
            in_recipes && /^  [a-zA-Z0-9_-]+:/ {
                match($0, /^  ([a-zA-Z0-9_-]+):/, arr)
                if (arr[1]) print "  - " arr[1]
            }
        ' "$config_file"
        echo ""
        echo "Use './install.sh --list' to see detailed recipe information"
        exit 1
    fi

    # Validate recipe configuration
    print_info "Validating recipe configuration..."
    if ! validate_recipe "$recipe" "$config_file"; then
        print_error "Recipe '$recipe' has missing or invalid configuration"
        echo ""
        echo "Please check your $config_file and ensure all required fields are present:"
        echo "  For Drupal recipes: source, profile, webroot"
        echo "  For Moodle recipes: source, branch, webroot"
        exit 1
    fi
    print_status "OK" "Recipe configuration is valid"

    # Check prerequisites
    print_info "Checking prerequisites..."

    local missing_deps=0

    if ! command -v composer &> /dev/null; then
        print_status "FAIL" "composer is not installed"
        missing_deps=1
    fi

    if ! command -v ddev &> /dev/null; then
        print_status "FAIL" "ddev is not installed"
        missing_deps=1
    fi

    if [ $missing_deps -eq 1 ]; then
        print_error "Missing required dependencies. Please run setup.sh first."
        exit 1
    fi

    print_status "OK" "All prerequisites satisfied"

    # Handle migration purpose - create stub only
    if [ "$purpose" == "migration" ]; then
        handle_migration "$recipe" "$target" "$config_file"
        # handle_migration calls exit, so we won't reach here
    fi

    # Determine base name for installation directory
    local base_name=""
    if [ -n "$target" ]; then
        # Use custom target name if provided
        base_name="$target"
    else
        # Use recipe name as default
        base_name="$recipe"
    fi

    # Determine installation directory based on whether we're resuming
    local install_dir=""
    if [ -n "$start_step" ]; then
        # When resuming, use base name directly (no auto-increment)
        install_dir="$base_name"
    else
        # Fresh install - find available directory with auto-increment
        install_dir=$(get_available_dirname "$base_name")
    fi

    # Read configuration values to display
    local recipe_type=$(get_recipe_value "$recipe" "type" "$config_file")
    local source=$(get_recipe_value "$recipe" "source" "$config_file")
    local profile=$(get_recipe_value "$recipe" "profile" "$config_file")
    local webroot=$(get_recipe_value "$recipe" "webroot" "$config_file")
    local database=$(get_settings_value "database" "$config_file")
    local php_version=$(get_settings_value "php" "$config_file")
    local auto_mode=$(get_recipe_value "$recipe" "auto" "$config_file")

    # Default to drupal if type not specified
    if [ -z "$recipe_type" ]; then
        recipe_type="drupal"
    fi

    # Set defaults for display
    if [ -z "$webroot" ]; then
        webroot="html"
    fi
    if [ -z "$php_version" ]; then
        php_version="8.3"
    fi
    if [ -z "$database" ]; then
        database="mysql"
    fi

    # Confirm installation
    echo ""
    if [ -n "$start_step" ]; then
        echo -e "${YELLOW}${BOLD}This will resume installation from step $start_step.${NC}"
    else
        echo -e "${YELLOW}${BOLD}This will install OpenSocial in a new directory.${NC}"
    fi
    echo ""
    echo -e "${BOLD}Installation Details:${NC}"
    echo -e "  Base directory:    ${BLUE}$(pwd)${NC}"
    echo -e "  Install directory: ${BLUE}$install_dir${NC}"
    echo -e "  Full path:         ${BLUE}$(pwd)/$install_dir${NC}"
    if [ -n "$start_step" ]; then
        echo -e "  Resume from step:  ${BLUE}$start_step${NC}"
    fi
    echo ""
    echo -e "${BOLD}Recipe Configuration: ${GREEN}$recipe${NC}"
    echo -e "  Type:     ${BLUE}$recipe_type${NC}"
    echo -e "  Source:   ${BLUE}$source${NC}"
    if [ "$recipe_type" == "drupal" ]; then
        echo -e "  Profile:  ${BLUE}$profile${NC}"
    fi
    echo -e "  Webroot:  ${BLUE}$webroot${NC}"
    echo -e "  Database: ${BLUE}$database${NC}"
    echo -e "  PHP:      ${BLUE}$php_version${NC}"
    echo ""

    # Check auto mode
    if [ "$auto_mode" == "y" ]; then
        print_status "OK" "Auto mode enabled - proceeding automatically"
        confirm="y"
    else
        read -p "Continue with installation? [Y/n]: " confirm

        # Default to 'y' if empty
        if [ -z "$confirm" ]; then
            confirm="y"
        fi

        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "Installation cancelled"
            exit 0
        fi
    fi

    # Run interactive option selection (always show TUI)
    run_interactive_options "$recipe" "$install_dir" "$recipe_type" "$config_file"

    # Load the appropriate installer (lazy loading)
    if ! load_installer "$recipe_type"; then
        print_error "Failed to load installer for type: $recipe_type"
        exit 1
    fi

    # Run installation based on recipe type
    case "$recipe_type" in
        moodle)
            if install_moodle "$recipe" "$install_dir" "$start_step" "$purpose"; then
                exit 0
            else
                print_error "Installation failed"
                exit 1
            fi
            ;;
        gitlab)
            if install_gitlab "$recipe" "$install_dir" "$start_step" "$purpose"; then
                exit 0
            else
                print_error "Installation failed"
                exit 1
            fi
            ;;
        podcast)
            if install_podcast "$recipe" "$install_dir" "$start_step" "$purpose"; then
                exit 0
            else
                print_error "Installation failed"
                exit 1
            fi
            ;;
        drupal|opensocial|*)
            # Default to Drupal/OpenSocial installation
            if install_drupal "$recipe" "$install_dir" "$start_step" "$create_content" "$purpose"; then
                exit 0
            else
                print_error "Installation failed"
                exit 1
            fi
            ;;
    esac
}

# Run main
main "$@"
