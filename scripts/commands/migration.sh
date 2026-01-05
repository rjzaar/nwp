#!/bin/bash
set -euo pipefail

################################################################################
# NWP Migration Script
#
# Handles site migrations from various sources to Drupal 11
# Supports: Drupal 7/8/9, Static HTML, WordPress, Joomla, and custom sources
#
# Usage: ./migration.sh <command> <sitename> [options]
#
# Commands:
#   analyze   - Analyze source site structure and content
#   prepare   - Set up target Drupal site for migration
#   run       - Execute the migration
#   verify    - Verify migration success
#   status    - Show migration status
#
# Based on Drupal Migrate API best practices
# References:
#   - https://www.drupal.org/docs/upgrading-drupal
#   - https://www.drupal.org/project/migrate_upgrade
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source shared libraries
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/common.sh"

# Source YAML library
if [ -f "$SCRIPT_DIR/lib/yaml-write.sh" ]; then
    source "$SCRIPT_DIR/lib/yaml-write.sh"
fi

# Script start time
START_TIME=$(date +%s)

################################################################################
# Help Functions
################################################################################

show_help() {
    cat << 'EOF'
NWP Migration Script

Handles site migrations from various sources to Drupal 11.

USAGE:
    ./migration.sh <command> <sitename> [options]

COMMANDS:
    analyze <sitename>    Analyze source site structure and recommend migration path
    prepare <sitename>    Set up target Drupal 11 site with migration modules
    run <sitename>        Execute the migration (may run multiple times)
    verify <sitename>     Verify migration completeness and integrity
    status <sitename>     Show current migration status

OPTIONS:
    -h, --help            Show this help message
    -d, --debug           Enable debug output
    -y, --yes             Auto-confirm prompts
    --dry-run             Show what would be done without making changes

SUPPORTED SOURCE TYPES:
    drupal7     Drupal 7 sites (uses core Migrate Drupal)
    drupal8     Drupal 8 sites (upgrade path)
    drupal9     Drupal 9 sites (upgrade path)
    html        Static HTML sites (uses migrate_source_html)
    wordpress   WordPress sites (uses migrate_wordpress)
    joomla      Joomla sites (custom migration)
    other       Custom migration (requires manual configuration)

WORKFLOW:
    1. Create migration stub:  ./install.sh d mysite -p=m
    2. Copy source files to:   mysite/source/
    3. Place DB dump in:       mysite/database/
    4. Analyze source:         ./migration.sh analyze mysite
    5. Prepare target:         ./migration.sh prepare mysite
    6. Run migration:          ./migration.sh run mysite
    7. Verify results:         ./migration.sh verify mysite

DRUPAL 7 MIGRATION NOTES:
    - Drupal 7 reached EOL on January 5, 2025
    - No direct upgrade path - content must be migrated
    - Uses Migrate API with migrate_drupal module
    - Custom modules may need manual migration

EXAMPLES:
    ./migration.sh analyze oldsite
    ./migration.sh prepare oldsite
    ./migration.sh run oldsite --dry-run
    ./migration.sh run oldsite
    ./migration.sh verify oldsite

EOF
}

################################################################################
# Analysis Functions
################################################################################

# Detect Drupal version from source files
detect_drupal_version() {
    local source_dir="$1"

    # Check for Drupal 7
    if [ -f "$source_dir/includes/bootstrap.inc" ]; then
        if grep -q "VERSION.*'7\." "$source_dir/includes/bootstrap.inc" 2>/dev/null; then
            echo "drupal7"
            return 0
        fi
    fi

    # Check for Drupal 8/9/10/11 (composer-based)
    if [ -f "$source_dir/core/lib/Drupal.php" ]; then
        local version=$(grep -o "VERSION = '[0-9]*\." "$source_dir/core/lib/Drupal.php" 2>/dev/null | grep -o "[0-9]*")
        case "$version" in
            8) echo "drupal8" ;;
            9) echo "drupal9" ;;
            10) echo "drupal10" ;;
            11) echo "drupal11" ;;
            *) echo "drupal_unknown" ;;
        esac
        return 0
    fi

    # Check for WordPress
    if [ -f "$source_dir/wp-config.php" ] || [ -f "$source_dir/wp-includes/version.php" ]; then
        echo "wordpress"
        return 0
    fi

    # Check for Joomla
    if [ -f "$source_dir/configuration.php" ] && grep -q "JConfig" "$source_dir/configuration.php" 2>/dev/null; then
        echo "joomla"
        return 0
    fi

    # Check for static HTML
    if [ -f "$source_dir/index.html" ] || [ -f "$source_dir/index.htm" ]; then
        echo "html"
        return 0
    fi

    echo "unknown"
}

# Count content items in source
analyze_content() {
    local source_dir="$1"
    local source_type="$2"

    echo ""
    print_info "Content Analysis:"

    case "$source_type" in
        drupal7|drupal8|drupal9|drupal10)
            # Count PHP files
            local php_count=$(find "$source_dir" -name "*.php" 2>/dev/null | wc -l)
            echo "  PHP files: $php_count"

            # Check for custom modules
            if [ -d "$source_dir/sites/all/modules/custom" ]; then
                local custom_modules=$(ls -1 "$source_dir/sites/all/modules/custom" 2>/dev/null | wc -l)
                echo "  Custom modules: $custom_modules"
            fi

            # Check for custom themes
            if [ -d "$source_dir/sites/all/themes" ]; then
                local themes=$(ls -1 "$source_dir/sites/all/themes" 2>/dev/null | wc -l)
                echo "  Custom themes: $themes"
            fi

            # Check for files
            if [ -d "$source_dir/sites/default/files" ]; then
                local files_count=$(find "$source_dir/sites/default/files" -type f 2>/dev/null | wc -l)
                local files_size=$(du -sh "$source_dir/sites/default/files" 2>/dev/null | cut -f1)
                echo "  Files: $files_count ($files_size)"
            fi
            ;;

        html)
            local html_count=$(find "$source_dir" -name "*.html" -o -name "*.htm" 2>/dev/null | wc -l)
            local css_count=$(find "$source_dir" -name "*.css" 2>/dev/null | wc -l)
            local js_count=$(find "$source_dir" -name "*.js" 2>/dev/null | wc -l)
            local img_count=$(find "$source_dir" -name "*.jpg" -o -name "*.png" -o -name "*.gif" 2>/dev/null | wc -l)

            echo "  HTML pages: $html_count"
            echo "  CSS files: $css_count"
            echo "  JavaScript files: $js_count"
            echo "  Images: $img_count"
            ;;

        wordpress)
            echo "  WordPress installation detected"
            if [ -d "$source_dir/wp-content/themes" ]; then
                local themes=$(ls -1 "$source_dir/wp-content/themes" 2>/dev/null | wc -l)
                echo "  Themes: $themes"
            fi
            if [ -d "$source_dir/wp-content/plugins" ]; then
                local plugins=$(ls -1 "$source_dir/wp-content/plugins" 2>/dev/null | wc -l)
                echo "  Plugins: $plugins"
            fi
            ;;

        *)
            echo "  Unable to analyze content for type: $source_type"
            ;;
    esac
}

# Analyze database dump
analyze_database() {
    local db_dir="$1"

    echo ""
    print_info "Database Analysis:"

    # Find SQL files
    local sql_files=$(find "$db_dir" -name "*.sql" -o -name "*.sql.gz" 2>/dev/null)

    if [ -z "$sql_files" ]; then
        echo "  No database dumps found in $db_dir"
        return 1
    fi

    for sql_file in $sql_files; do
        local filename=$(basename "$sql_file")
        local filesize=$(du -h "$sql_file" | cut -f1)
        echo "  Found: $filename ($filesize)"

        # Try to extract table count from uncompressed SQL
        if [[ "$sql_file" == *.sql ]]; then
            local table_count=$(grep -c "CREATE TABLE" "$sql_file" 2>/dev/null || echo "0")
            echo "    Tables: ~$table_count"
        fi
    done
}

# Main analyze command
cmd_analyze() {
    local sitename="$1"
    local site_dir="$SCRIPT_DIR/sites/$sitename"

    print_header "Analyzing Migration Source: $sitename"

    # Check if site exists
    if [ ! -d "$site_dir" ]; then
        print_error "Site directory not found: $site_dir"
        echo ""
        echo "Create a migration stub first with:"
        echo "  ./install.sh d $sitename -p=m"
        return 1
    fi

    # Check source directory
    local source_dir="$site_dir/source"
    if [ ! -d "$source_dir" ] || [ -z "$(ls -A "$source_dir" 2>/dev/null)" ]; then
        print_warning "Source directory is empty: $source_dir"
        echo ""
        echo "Copy your source site files to: $source_dir"
        return 1
    fi

    # Detect source type
    print_info "Detecting source type..."
    local detected_type=$(detect_drupal_version "$source_dir")
    echo "  Detected: $detected_type"

    # Get configured type from cnwp.yml
    local configured_type=""
    if command -v yaml_get_site_field &> /dev/null; then
        configured_type=$(yaml_get_site_field "$sitename" "source_type" "$SCRIPT_DIR/cnwp.yml" 2>/dev/null || echo "")
    fi

    if [ -n "$configured_type" ] && [ "$configured_type" != "$detected_type" ]; then
        print_warning "Configured type ($configured_type) differs from detected ($detected_type)"
    fi

    # Analyze content
    analyze_content "$source_dir" "$detected_type"

    # Analyze database
    local db_dir="$site_dir/database"
    if [ -d "$db_dir" ]; then
        analyze_database "$db_dir"
    else
        print_warning "No database directory found"
    fi

    # Provide recommendations
    echo ""
    print_header "Migration Recommendations"

    case "$detected_type" in
        drupal7)
            echo "Source: Drupal 7 (EOL: January 5, 2025)"
            echo ""
            echo "Recommended approach:"
            echo "  1. Create fresh Drupal 11 site with: ./migration.sh prepare $sitename"
            echo "  2. Install migration modules: migrate_drupal, migrate_drupal_ui"
            echo "  3. Configure source database connection"
            echo "  4. Run migration via UI at /upgrade or drush migrate commands"
            echo ""
            echo "Key modules needed:"
            echo "  - migrate (core)"
            echo "  - migrate_drupal (core)"
            echo "  - migrate_drupal_ui (core)"
            echo "  - migrate_plus (contrib - for advanced migrations)"
            echo "  - migrate_tools (contrib - for drush commands)"
            ;;

        drupal8|drupal9)
            echo "Source: Drupal $detected_type"
            echo ""
            echo "Recommended approach:"
            echo "  1. Use composer to upgrade in place if possible"
            echo "  2. Or create fresh site and migrate content"
            echo ""
            echo "Commands:"
            echo "  composer require drupal/core-recommended:^11"
            echo "  drush updb"
            echo "  drush cr"
            ;;

        html)
            echo "Source: Static HTML"
            echo ""
            echo "Recommended approach:"
            echo "  1. Create fresh Drupal 11 site"
            echo "  2. Install migrate_source_html module"
            echo "  3. Create migration configuration for HTML structure"
            echo "  4. Map HTML elements to Drupal fields"
            echo ""
            echo "Key modules needed:"
            echo "  - migrate_source_html"
            echo "  - migrate_plus"
            echo "  - migrate_tools"
            ;;

        wordpress)
            echo "Source: WordPress"
            echo ""
            echo "Recommended approach:"
            echo "  1. Create fresh Drupal 11 site"
            echo "  2. Install WordPress migration module"
            echo "  3. Configure WordPress database connection"
            echo "  4. Run migration"
            echo ""
            echo "Key modules needed:"
            echo "  - wordpress_migrate"
            echo "  - migrate_plus"
            echo "  - migrate_tools"
            ;;

        *)
            echo "Source: $detected_type (custom migration required)"
            echo ""
            echo "You will need to create custom migration configuration."
            echo "See: https://www.drupal.org/docs/drupal-apis/migrate-api"
            ;;
    esac

    # Update cnwp.yml with analysis results
    if command -v yaml_update_site_field &> /dev/null; then
        yaml_update_site_field "$sitename" "source_type" "$detected_type" "$SCRIPT_DIR/cnwp.yml" 2>/dev/null || true

        # Update migration status
        local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        # Note: Would need nested field support for migration.analyzed_at
    fi

    echo ""
    print_status "OK" "Analysis complete"
}

################################################################################
# Prepare Functions
################################################################################

cmd_prepare() {
    local sitename="$1"
    local site_dir="$SCRIPT_DIR/sites/$sitename"

    print_header "Preparing Target Site: $sitename"

    # Check if migration site exists
    if [ ! -d "$site_dir" ]; then
        print_error "Migration site not found: $site_dir"
        return 1
    fi

    # Get source type
    local source_type=""
    if command -v yaml_get_site_field &> /dev/null; then
        source_type=$(yaml_get_site_field "$sitename" "source_type" "$SCRIPT_DIR/cnwp.yml" 2>/dev/null || echo "other")
    fi

    if [ -z "$source_type" ]; then
        print_error "Source type not set. Run analyze first:"
        echo "  ./migration.sh analyze $sitename"
        return 1
    fi

    print_info "Source type: $source_type"

    # Create target Drupal site
    local target_name="${sitename}_target"

    if [ -d "$SCRIPT_DIR/sites/$target_name" ]; then
        print_warning "Target site already exists: $target_name"
        read -p "Continue with existing site? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 1
        fi
    else
        print_info "Creating target Drupal 11 site: $target_name"
        if ! "$SCRIPT_DIR/install.sh" d "$target_name" -p=m; then
            print_error "Failed to create target site"
            return 1
        fi
    fi

    # Install migration modules
    print_info "Installing migration modules..."
    cd "$SCRIPT_DIR/sites/$target_name"

    # Enable core migrate modules
    ddev drush en migrate migrate_drupal migrate_drupal_ui -y 2>/dev/null || true

    # Install contrib modules based on source type
    case "$source_type" in
        drupal7|drupal8|drupal9)
            ddev composer require drupal/migrate_plus drupal/migrate_tools 2>/dev/null || true
            ddev drush en migrate_plus migrate_tools -y 2>/dev/null || true
            ;;
        html)
            ddev composer require drupal/migrate_source_html drupal/migrate_plus drupal/migrate_tools 2>/dev/null || true
            ddev drush en migrate_source_html migrate_plus migrate_tools -y 2>/dev/null || true
            ;;
        wordpress)
            ddev composer require drupal/wordpress_migrate drupal/migrate_plus drupal/migrate_tools 2>/dev/null || true
            ddev drush en wordpress_migrate migrate_plus migrate_tools -y 2>/dev/null || true
            ;;
    esac

    cd "$SCRIPT_DIR"

    # Update status
    if command -v yaml_update_site_field &> /dev/null; then
        yaml_update_site_field "$sitename" "status" "prepared" "$SCRIPT_DIR/cnwp.yml" 2>/dev/null || true
    fi

    print_status "OK" "Target site prepared: $target_name"
    echo ""
    echo "Next steps:"
    echo "  1. Configure source database in sites/$target_name/web/sites/default/settings.php"
    echo "  2. Run: ./migration.sh run $sitename"
}

################################################################################
# Run Migration Functions
################################################################################

cmd_run() {
    local sitename="$1"
    local dry_run="${2:-false}"
    local site_dir="$SCRIPT_DIR/sites/$sitename"
    local target_name="${sitename}_target"

    print_header "Running Migration: $sitename"

    if [ "$dry_run" == "true" ]; then
        print_warning "DRY RUN - No changes will be made"
    fi

    # Check target site
    if [ ! -d "$SCRIPT_DIR/sites/$target_name" ]; then
        print_error "Target site not found. Run prepare first:"
        echo "  ./migration.sh prepare $sitename"
        return 1
    fi

    cd "$SCRIPT_DIR/sites/$target_name"

    # Get source type
    local source_type=""
    if command -v yaml_get_site_field &> /dev/null; then
        source_type=$(yaml_get_site_field "$sitename" "source_type" "$SCRIPT_DIR/cnwp.yml" 2>/dev/null || echo "other")
    fi

    print_info "Migration type: $source_type"

    case "$source_type" in
        drupal7)
            echo ""
            echo "For Drupal 7 migration, use the UI at:"
            echo "  $(ddev describe 2>/dev/null | grep "Primary URL" | awk '{print $3}')/upgrade"
            echo ""
            echo "Or use drush commands:"
            echo "  ddev drush migrate:upgrade --legacy-db-key=migrate"
            echo "  ddev drush migrate:import --all"
            ;;
        *)
            echo ""
            echo "Run migration commands in target site:"
            echo "  cd $target_name"
            echo "  ddev drush migrate:status"
            echo "  ddev drush migrate:import --all"
            ;;
    esac

    cd "$SCRIPT_DIR"

    # Update status
    if command -v yaml_update_site_field &> /dev/null; then
        yaml_update_site_field "$sitename" "status" "migrating" "$SCRIPT_DIR/cnwp.yml" 2>/dev/null || true
    fi
}

################################################################################
# Verify Functions
################################################################################

cmd_verify() {
    local sitename="$1"
    local target_name="${sitename}_target"

    print_header "Verifying Migration: $sitename"

    if [ ! -d "$SCRIPT_DIR/sites/$target_name" ]; then
        print_error "Target site not found: $target_name"
        return 1
    fi

    cd "$SCRIPT_DIR/sites/$target_name"

    # Check migration status
    print_info "Checking migration status..."
    ddev drush migrate:status 2>/dev/null || echo "Migration status unavailable"

    # Check for errors
    print_info "Checking for migration errors..."
    ddev drush watchdog:show --type=migrate 2>/dev/null | head -20 || echo "No migration logs found"

    # Basic site health check
    print_info "Checking site health..."
    ddev drush status 2>/dev/null | grep -E "Drupal|Database|PHP" || true

    cd "$SCRIPT_DIR"

    print_status "OK" "Verification complete"
    echo ""
    echo "Manual verification recommended:"
    echo "  1. Browse the target site and verify content"
    echo "  2. Check user accounts migrated correctly"
    echo "  3. Verify media and files are accessible"
    echo "  4. Test site functionality"
}

################################################################################
# Status Functions
################################################################################

cmd_status() {
    local sitename="$1"
    local site_dir="$SCRIPT_DIR/sites/$sitename"

    print_header "Migration Status: $sitename"

    # Get info from cnwp.yml
    if command -v yaml_get_site_field &> /dev/null; then
        local source_type=$(yaml_get_site_field "$sitename" "source_type" "$SCRIPT_DIR/cnwp.yml" 2>/dev/null)
        local status=$(yaml_get_site_field "$sitename" "status" "$SCRIPT_DIR/cnwp.yml" 2>/dev/null)
        local created=$(yaml_get_site_field "$sitename" "created" "$SCRIPT_DIR/cnwp.yml" 2>/dev/null)

        echo "Site: $sitename"
        echo "Source type: ${source_type:-unknown}"
        echo "Status: ${status:-pending}"
        echo "Created: ${created:-unknown}"
    fi

    # Check directories
    echo ""
    echo "Directories:"
    [ -d "$site_dir" ] && echo "  Migration stub: EXISTS" || echo "  Migration stub: MISSING"
    [ -d "$site_dir/source" ] && echo "  Source files: EXISTS" || echo "  Source files: MISSING"
    [ -d "$site_dir/database" ] && echo "  Database dumps: EXISTS" || echo "  Database dumps: MISSING"
    [ -d "$SCRIPT_DIR/sites/${sitename}_target" ] && echo "  Target site: EXISTS" || echo "  Target site: MISSING"
}

################################################################################
# Main
################################################################################

main() {
    local command=""
    local sitename=""
    local debug=false
    local auto_yes=false
    local dry_run=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -d|--debug)
                debug=true
                shift
                ;;
            -y|--yes)
                auto_yes=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            analyze|prepare|run|verify|status)
                command="$1"
                shift
                ;;
            *)
                if [ -z "$sitename" ]; then
                    sitename="$1"
                fi
                shift
                ;;
        esac
    done

    # Validate inputs
    if [ -z "$command" ]; then
        print_error "No command specified"
        echo ""
        echo "Usage: ./migration.sh <command> <sitename>"
        echo "Commands: analyze, prepare, run, verify, status"
        exit 1
    fi

    if [ -z "$sitename" ]; then
        print_error "No sitename specified"
        echo ""
        echo "Usage: ./migration.sh $command <sitename>"
        exit 1
    fi

    # Validate sitename
    if ! validate_sitename "$sitename" "site name"; then
        exit 1
    fi

    # Run command
    case "$command" in
        analyze)
            cmd_analyze "$sitename"
            ;;
        prepare)
            cmd_prepare "$sitename"
            ;;
        run)
            cmd_run "$sitename" "$dry_run"
            ;;
        verify)
            cmd_verify "$sitename"
            ;;
        status)
            cmd_status "$sitename"
            ;;
        *)
            print_error "Unknown command: $command"
            exit 1
            ;;
    esac

    show_elapsed_time "Migration"
}

main "$@"
