#!/bin/bash

################################################################################
# NWP Installation Script
#
# Reads nwpc.yml and installs OpenSocial based on the specified recipe
# Usage: ./install.sh [recipe_name] [s=step_number] [c]
#
# Examples:
#   ./install.sh os              - Install using 'os' recipe
#   ./install.sh os s=3          - Resume 'os' installation from step 3
#   ./install.sh nwp --step=5    - Resume 'nwp' installation from step 5
#   ./install.sh nwp c           - Install 'nwp' recipe with test content
#
# Options:
#   c, --create-content          - Create test content (5 users, 5 docs, 5 workflow assignments)
#
# Installation Steps:
#   1  - Initialize project with Composer
#   2  - Configure DDEV
#   3  - Configure memory settings
#   4  - Start DDEV services
#   5  - Install Drush
#   6  - Configure private file system
#   7  - Install Drupal profile
#   8  - Install additional modules and export config
################################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

################################################################################
# YAML Parsing Functions
################################################################################

# Parse YAML file and extract value for a given recipe and key
get_recipe_value() {
    local recipe=$1
    local key=$2
    local config_file="${3:-nwpc.yml}"

    # Use awk to extract the value
    awk -v recipe="$recipe" -v key="$key" '
        BEGIN { in_recipe = 0; found = 0 }
        /^  [a-zA-Z0-9_-]+:/ {
            if ($1 == recipe":") {
                in_recipe = 1
            } else if (in_recipe && /^  [a-zA-Z0-9_-]+:/) {
                in_recipe = 0
            }
        }
        in_recipe && $0 ~ "^    " key ":" {
            sub("^    " key ": *", "")
            print
            found = 1
            exit
        }
    ' "$config_file"
}

# Parse YAML file and extract root-level value
get_root_value() {
    local key=$1
    local config_file="${2:-nwpc.yml}"

    # Use awk to extract root-level values (not indented)
    awk -v key="$key" '
        /^[a-zA-Z0-9_-]+:/ && $1 == key":" {
            sub("^" key ": *", "")
            print
            exit
        }
    ' "$config_file"
}

# Check if recipe exists in config file
recipe_exists() {
    local recipe=$1
    local config_file="${2:-nwpc.yml}"

    grep -q "^  ${recipe}:" "$config_file"
    return $?
}

# Find available directory name for recipe installation
get_available_dirname() {
    local recipe=$1
    local dirname="$recipe"
    local counter=1

    # If directory doesn't exist, return it
    if [ ! -d "$dirname" ]; then
        echo "$dirname"
        return 0
    fi

    # Otherwise, find the next available numbered directory
    while [ -d "${recipe}${counter}" ]; do
        counter=$((counter + 1))
    done

    echo "${recipe}${counter}"
    return 0
}

################################################################################
# Installation Functions (Following Part 2 of Guide - Method 1)
################################################################################

# Check if current step should be executed
should_run_step() {
    local current_step=$1
    local start_step=$2

    if [ -z "$start_step" ] || [ "$current_step" -ge "$start_step" ]; then
        return 0  # true - run this step
    else
        return 1  # false - skip this step
    fi
}

# Create test content for workflow_assignment module
# Create test content for workflow_assignment module
create_test_content() {
    print_header "Creating Test Content"

    print_info "Enabling workflow_assignment module..."
    if ! ddev drush pm:enable workflow_assignment -y 2>&1 | grep -v "Deprecated"; then
        print_error "Failed to enable workflow_assignment module"
        return 1
    fi

    print_info "Enabling page content type for workflow support and clearing cache..."
    ddev drush php:eval "
        \$config = \Drupal::configFactory()->getEditable('workflow_assignment.settings');
        \$enabled_types = \$config->get('enabled_content_types') ?: [];
        if (!in_array('page', \$enabled_types)) {
            \$enabled_types[] = 'page';
            \$config->set('enabled_content_types', \$enabled_types);
            \$config->save();
        }
        drupal_flush_all_caches();
    " >/dev/null 2>&1

    print_info "Creating 5 test users..."
    local users=()
    for i in {1..5}; do
        local username="testuser$i"
        local email="testuser$i@example.com"

        if ddev drush user:info "$username" &>/dev/null; then
            print_info "User $username already exists, skipping..."
        else
            ddev drush user:create "$username" --mail="$email" --password="test123" >/dev/null 2>&1
            print_info "Created user: $username"
        fi
        users+=("$username")
    done

    print_info "Creating 5 test documents..."
    local doc_nids=()
    for i in {1..5}; do
        local title="Test Document $i"
        local body="This is test document number $i for workflow assignment testing."

        local nid=$(ddev drush php:eval "
            \$node = \Drupal\node\Entity\Node::create([
                'type' => 'page',
                'title' => '$title',
                'body' => [
                    'value' => '$body',
                    'format' => 'basic_html',
                ],
                'uid' => 1,
                'status' => 1,
            ]);
            \$node->save();
            echo \$node->id();
        " 2>/dev/null | tail -1)

        if [ -n "$nid" ]; then
            doc_nids+=("$nid")
            print_info "Created document: $title (NID: $nid)"
        fi
    done

    print_info "Creating 5 workflow assignments..."
    local workflow_ids=()
    for i in {1..5}; do
        local user_index=$((i - 1))
        local username="${users[$user_index]}"
        local wf_id="test_workflow_$i"

        ddev drush php:eval "
            \$users = \Drupal::entityTypeManager()
                ->getStorage('user')
                ->loadByProperties(['name' => '$username']);
            \$user = reset(\$users);

            if (\$user) {
                \$workflow = \Drupal::entityTypeManager()
                    ->getStorage('workflow_list')
                    ->create([
                        'id' => '${wf_id}',
                        'label' => 'Workflow Task $i',
                        'description' => 'This is test workflow assignment $i for testing purposes.',
                        'assigned_type' => 'user',
                        'assigned_id' => \$user->id(),
                        'comments' => 'Test comment for workflow $i',
                    ]);
                \$workflow->save();
            }
        " >/dev/null 2>&1

        workflow_ids+=("$wf_id")
        print_info "Created workflow: Workflow Task $i (assigned to $username)"
    done

    # Link workflows to the first document
    if [ ${#doc_nids[@]} -gt 0 ] && [ ${#workflow_ids[@]} -gt 0 ]; then
        local target_nid="${doc_nids[0]}"

        print_info "Linking workflows to document (NID: $target_nid)..."
        ddev drush php:eval "
            \$node = \Drupal\node\Entity\Node::load($target_nid);
            if (\$node && \$node->hasField('field_workflow_list')) {
                \$workflow_ids = ['${workflow_ids[0]}', '${workflow_ids[1]}', '${workflow_ids[2]}', '${workflow_ids[3]}', '${workflow_ids[4]}'];
                \$node->set('field_workflow_list', \$workflow_ids);
                \$node->save();
            }
        " >/dev/null 2>&1

        print_status "OK" "Test content created successfully"

        # Get one-time login URL and append workflow tab destination
        local uli_url=$(ddev drush uli --uri=default 2>/dev/null | tail -n 1)
        local workflow_url="${uli_url%/login}/login?destination=/node/${target_nid}/workflow"

        echo ""
        echo -e "${BOLD}Test Content Summary:${NC}"
        echo -e "  ${GREEN}✓${NC} 5 users created (testuser1-5, password: test123)"
        echo -e "  ${GREEN}✓${NC} 5 documents created (NIDs: ${doc_nids[*]})"
        echo -e "  ${GREEN}✓${NC} 5 workflow assignments linked to document $target_nid"
        echo ""
        echo -e "${BOLD}Login and view workflow assignments:${NC}"
        echo -e "  ${BLUE}${workflow_url}${NC}"
        echo ""

        # Try to open in browser with login URL that redirects to workflow tab
        if command -v xdg-open &> /dev/null; then
            xdg-open "$workflow_url" &>/dev/null &
            print_status "OK" "Browser opened with login to workflow tab"
        elif command -v open &> /dev/null; then
            open "$workflow_url" &>/dev/null &
            print_status "OK" "Browser opened with login to workflow tab"
        fi
    else
        print_error "No documents or workflows were created"
        return 1
    fi

    return 0
}

install_opensocial() {
    local recipe=$1
    local start_step=$2
    local create_content=$3
    local base_dir=$(pwd)

    print_header "Installing OpenSocial using recipe: $recipe"

    if [ -n "$start_step" ]; then
        print_info "Starting from step $start_step (skipping earlier steps)"
        echo ""
    fi

    # Determine installation directory
    local install_dir=""
    local project_dir=""

    if [ -n "$start_step" ]; then
        # When resuming, use the recipe name directly (no auto-increment)
        install_dir="$recipe"

        if [ ! -d "$install_dir" ]; then
            print_error "Installation directory '$install_dir' does not exist. Cannot resume from step $start_step"
            print_info "To resume an installation, the directory must already exist"
            return 1
        fi

        if ! cd "$install_dir"; then
            print_error "Failed to enter directory: $install_dir"
            return 1
        fi

        project_dir=$(pwd)
        print_status "INFO" "Using existing directory: $project_dir"
    else
        # Fresh installation - find available directory name with auto-increment
        install_dir=$(get_available_dirname "$recipe")
        print_info "Installation directory: $install_dir"

        # Create and enter the installation directory using absolute path
        local abs_install_dir="$base_dir/$install_dir"
        if ! mkdir -p "$abs_install_dir"; then
            print_error "Failed to create directory: $abs_install_dir"
            return 1
        fi

        # Change to absolute path to avoid Docker mount issues
        if ! cd "$abs_install_dir"; then
            print_error "Failed to enter directory: $abs_install_dir"
            return 1
        fi

        project_dir=$(pwd)
        print_status "OK" "Created installation directory: $project_dir"
    fi

    # Extract configuration values from YAML
    local source=$(get_recipe_value "$recipe" "source" "$base_dir/nwpc.yml")
    local profile=$(get_recipe_value "$recipe" "profile" "$base_dir/nwpc.yml")
    local webroot=$(get_recipe_value "$recipe" "webroot" "$base_dir/nwpc.yml")
    local install_modules=$(get_recipe_value "$recipe" "install_modules" "$base_dir/nwpc.yml")

    # Get root-level database and PHP configuration
    local database=$(get_root_value "database" "$base_dir/nwpc.yml")
    local php_version=$(get_root_value "php" "$base_dir/nwpc.yml")

    # Set defaults if not specified
    if [ -z "$php_version" ]; then
        php_version="8.3"  # Default from guide
        print_info "No PHP version specified, using default: 8.3"
    fi

    if [ -z "$database" ]; then
        database="mysql"  # Default
        print_info "No database specified, using default: mysql"
    fi

    # Validate required values
    if [ -z "$source" ]; then
        print_error "Recipe '$recipe' does not specify 'source'"
        return 1
    fi

    if [ -z "$profile" ]; then
        print_error "Recipe '$recipe' does not specify 'profile'"
        return 1
    fi

    if [ -z "$webroot" ]; then
        webroot="html"  # Default from guide
        print_info "No webroot specified, using default: html"
    fi

    print_info "Configuration:"
    echo "  Source:   $source"
    echo "  Profile:  $profile"
    echo "  Webroot:  $webroot"
    echo "  Database: $database"
    echo "  PHP:      $php_version"
    echo ""

    # Step 1: Initialize Project with Composer
    if should_run_step 1 "$start_step"; then
        print_header "Step 1: Initialize Project with Composer"
        print_info "This will take 10-15 minutes..."

        # Extract project without installing dependencies
        print_info "Extracting project template..."
        if ! composer create-project "$source" . --no-install --no-interaction; then
            print_error "Failed to extract project template"
            return 1
        fi

        # Add Asset Packagist repository to project composer.json
        print_info "Configuring repositories..."
        composer config repositories.asset-packagist composer https://asset-packagist.org
        composer config repositories.drupal composer https://packages.drupal.org/8

        # Install dependencies with Asset Packagist available
        print_info "Installing dependencies (this will take 10-15 minutes)..."
        if ! composer install --no-interaction; then
            print_error "Failed to install project dependencies"
            return 1
        fi

        # Install Drush
        print_info "Installing Drush..."
        if composer require drush/drush --dev --no-interaction; then
            print_status "OK" "Drush installed"
        else
            print_status "WARN" "Drush installation failed, but may already be available"
        fi

        # Install additional modules if specified
        if [ -n "$install_modules" ]; then
            # Configure dworkflow repository only when needed
            print_info "Configuring custom repositories for additional modules..."
            composer config repositories.dworkflow vcs https://github.com/rjzaar/dworkflow

            print_info "Installing additional modules: $install_modules"
            if ! composer require $install_modules --no-interaction; then
                print_error "Failed to install additional modules"
                return 1
            fi
            print_status "OK" "Additional modules installed"
        fi

        print_status "OK" "Project initialized"
    else
        print_status "INFO" "Skipping Step 1: Project already initialized"
    fi

    # Step 2: Configure DDEV
    if should_run_step 2 "$start_step"; then
        print_header "Step 2: Configure DDEV"

        # Map database type to DDEV database type
        local ddev_database="$database"
        # DDEV uses mariadb as the database type
        if [ "$database" == "mysql" ]; then
            ddev_database="mysql:8.0"
        elif [ "$database" == "mariadb" ]; then
            ddev_database="mariadb:10.11"
        fi

        if ! ddev config --project-type=drupal --docroot="$webroot" --php-version="$php_version" --database="$ddev_database"; then
            print_error "Failed to configure DDEV"
            return 1
        fi
        print_status "OK" "DDEV configured (Database: $ddev_database)"
    else
        print_status "INFO" "Skipping Step 2: DDEV already configured"
    fi

    # Step 3: Memory Configuration
    if should_run_step 3 "$start_step"; then
        print_header "Step 3: Memory Configuration"

        mkdir -p .ddev/php
        cat > .ddev/php/memory.ini << 'EOF'
memory_limit = 512M
max_execution_time = 600
EOF
        print_status "OK" "Memory limits configured"
    else
        print_status "INFO" "Skipping Step 3: Memory already configured"
    fi

    # Step 4: Launch Services
    if should_run_step 4 "$start_step"; then
        print_header "Step 4: Launch DDEV Services"

        if ! ddev start; then
            print_error "Failed to start DDEV"
            return 1
        fi
        print_status "OK" "DDEV services started"
    else
        print_status "INFO" "Skipping Step 4: DDEV already started"
    fi

    # Step 5: Verify Drush is available
    if should_run_step 5 "$start_step"; then
        print_header "Step 5: Verify Drush is Available"

        # Check if Drush is available
        if [ -f "vendor/bin/drush" ]; then
            print_status "OK" "Drush is available"
        else
            print_error "Drush not found - installation may have failed in Step 1"
            print_info "Try manually installing with: ddev composer require drush/drush --dev"
        fi
    else
        print_status "INFO" "Skipping Step 5: Drush verification"
    fi

    # Step 6: Configure Private File System
    if should_run_step 6 "$start_step"; then
        print_header "Step 6: Configure Private File System"

        # Create private files directory
        mkdir -p private

        # Ensure sites/default directory exists and is writable
        mkdir -p "${webroot}/sites/default"
        chmod 755 "${webroot}/sites/default"

        # Copy default.settings.php to settings.php and add private file path
        if [ -f "${webroot}/sites/default/default.settings.php" ]; then
            cp "${webroot}/sites/default/default.settings.php" "${webroot}/sites/default/settings.php"
        else
            # Create a minimal settings.php if default doesn't exist
            cat > "${webroot}/sites/default/settings.php" << 'EOF'
<?php
/**
 * Drupal settings file.
 */

$databases = [];
$settings['hash_salt'] = '';
EOF
        fi

        # Append private file path configuration to settings.php
        cat >> "${webroot}/sites/default/settings.php" << 'EOF'

/**
 * Private file system configuration.
 * Required for OpenSocial installation.
 */
$settings['file_private_path'] = '../private';

/**
 * Include DDEV settings.
 */
if (file_exists(__DIR__ . '/settings.ddev.php')) {
  include __DIR__ . '/settings.ddev.php';
}

/**
 * Include local development settings.
 */
if (file_exists(__DIR__ . '/settings.local.php')) {
  include __DIR__ . '/settings.local.php';
}
EOF

        chmod 644 "${webroot}/sites/default/settings.php"

        print_status "OK" "Private file system configured in settings.php"
    else
        print_status "INFO" "Skipping Step 6: Private file system already configured"
    fi

    # Step 7: Install Drupal Profile
    if should_run_step 7 "$start_step"; then
        print_header "Step 7: Install Drupal Profile"
        print_info "This will take 5-10 minutes..."

        # Verify DDEV is running and restart to ensure proper mount
        print_info "Verifying DDEV status..."
        if ! ddev describe >/dev/null 2>&1; then
            print_error "DDEV is not running. Starting DDEV..."
            if ! ddev start; then
                print_error "Failed to start DDEV"
                return 1
            fi
        else
            # Restart DDEV to ensure proper container mount context
            print_info "Restarting DDEV to ensure proper container configuration..."
            if ! ddev restart >/dev/null 2>&1; then
                print_error "Failed to restart DDEV"
                return 1
            fi
        fi

        # Verify current directory is accessible
        print_info "Working directory: $(pwd)"
        print_info "Verifying container access..."
        if ! ddev exec pwd >/dev/null 2>&1; then
            print_error "Container cannot access current directory"
            print_error "This is likely a Docker AppArmor/SELinux issue"
            print_info "Try running: sudo aa-status | grep docker"
            return 1
        fi

        # Determine database driver based on database type
        local db_driver="$database"
        # MariaDB uses the mysql driver in Drupal
        if [ "$database" == "mariadb" ]; then
            db_driver="mysql"
        fi

        if ! ddev drush site:install "$profile" \
            --db-url="${db_driver}://db:db@db:3306/db" \
            --account-name=admin \
            --account-pass=admin \
            --site-name="My OpenSocial Site" \
            -y; then
            print_error "Failed to install Drupal site"
            return 1
        fi
        print_status "OK" "Drupal site installed"
    else
        print_status "INFO" "Skipping Step 7: Drupal already installed"
    fi

    # Step 8: Additional modules and configuration
    if should_run_step 8 "$start_step"; then
        # Dev modules installation if dev mode enabled
        local dev=$(get_recipe_value "$recipe" "dev" "$base_dir/nwpc.yml")
        if [ "$dev" == "y" ]; then
            local dev_modules=$(get_recipe_value "$recipe" "dev_modules" "$base_dir/nwpc.yml")
            if [ -n "$dev_modules" ]; then
                print_header "Installing Development Modules"
                print_info "Modules: $dev_modules"

                if ! ddev drush pm:enable $dev_modules -y; then
                    print_error "Failed to install dev modules: $dev_modules"
                else
                    print_status "OK" "Development modules installed"
                fi
            fi
        fi

        # Clear cache and export configuration
        print_info "Clearing cache..."
        ddev drush cr

        print_info "Exporting configuration..."
        if ! ddev drush config:export -y; then
            print_error "Failed to export configuration (non-critical)"
        else
            print_status "OK" "Configuration exported"
        fi

        # Verify installation
        print_info "Verifying installation..."
        ddev drush status
    else
        print_status "INFO" "Skipping Step 8: Additional configuration"
    fi

    # Create test content if requested
    if [ "$create_content" == "y" ]; then
        if ! create_test_content; then
            print_error "Test content creation failed, but installation is complete"
        fi
        echo ""
    fi

    # Success message
    print_header "Installation Complete!"

    echo -e "${GREEN}${BOLD}✓ OpenSocial has been successfully installed!${NC}\n"
    echo -e "${BOLD}Login credentials:${NC}"
    echo -e "  Username: ${GREEN}admin${NC}"
    echo -e "  Password: ${GREEN}admin${NC}\n"

    # Open site with one-time login link
    print_info "Opening site in browser with one-time login link..."

    # Get the one-time login URL
    local uli_url=$(ddev drush uli 2>/dev/null | tail -n 1)

    if [ -n "$uli_url" ]; then
        echo -e "${BOLD}One-time login URL:${NC} ${BLUE}$uli_url${NC}\n"

        # Open in browser (try xdg-open for Linux, open for Mac, or just display)
        if command -v xdg-open &> /dev/null; then
            xdg-open "$uli_url" &>/dev/null &
            print_status "OK" "Site opened in browser"
        elif command -v open &> /dev/null; then
            open "$uli_url" &>/dev/null &
            print_status "OK" "Site opened in browser"
        else
            print_status "WARN" "Could not auto-open browser. Please visit the URL above."
        fi
    else
        print_status "WARN" "Could not generate one-time login link. Use: ddev drush uli"
    fi

    echo ""
    echo -e "${BOLD}Useful commands:${NC}"
    echo -e "  ${BLUE}ddev launch${NC}      - Open site in browser"
    echo -e "  ${BLUE}ddev drush uli${NC}    - Get one-time login link"
    echo -e "  ${BLUE}ddev ssh${NC}          - SSH into container\n"

    return 0
}

################################################################################
# Moodle Installation Function
################################################################################

install_moodle() {
    local recipe=$1
    local start_step=$2
    local base_dir=$(pwd)

    print_header "Installing Moodle using recipe: $recipe"

    if [ -n "$start_step" ]; then
        print_info "Starting from step $start_step (skipping earlier steps)"
        echo ""
    fi

    # Determine installation directory
    local install_dir=""
    local project_dir=""

    if [ -n "$start_step" ]; then
        # When resuming, use the recipe name directly (no auto-increment)
        install_dir="$recipe"

        if [ ! -d "$install_dir" ]; then
            print_error "Installation directory '$install_dir' does not exist. Cannot resume from step $start_step"
            print_info "To resume an installation, the directory must already exist"
            return 1
        fi

        if ! cd "$install_dir"; then
            print_error "Failed to enter directory: $install_dir"
            return 1
        fi

        project_dir=$(pwd)
        print_status "INFO" "Using existing directory: $project_dir"
    else
        # Fresh installation - find available directory name with auto-increment
        install_dir=$(get_available_dirname "$recipe")
        print_info "Installation directory: $install_dir"

        # Create and enter the installation directory using absolute path
        local abs_install_dir="$base_dir/$install_dir"
        if ! mkdir -p "$abs_install_dir"; then
            print_error "Failed to create directory: $abs_install_dir"
            return 1
        fi

        # Change to absolute path to avoid Docker mount issues
        if ! cd "$abs_install_dir"; then
            print_error "Failed to enter directory: $abs_install_dir"
            return 1
        fi

        project_dir=$(pwd)
        print_status "OK" "Created installation directory: $project_dir"
    fi

    # Extract configuration values from YAML
    local source=$(get_recipe_value "$recipe" "source" "$base_dir/nwpc.yml")
    local branch=$(get_recipe_value "$recipe" "branch" "$base_dir/nwpc.yml")
    local webroot=$(get_recipe_value "$recipe" "webroot" "$base_dir/nwpc.yml")
    local sitename=$(get_recipe_value "$recipe" "sitename" "$base_dir/nwpc.yml")

    # Get root-level database and PHP configuration
    local database=$(get_root_value "database" "$base_dir/nwpc.yml")
    local php_version=$(get_root_value "php" "$base_dir/nwpc.yml")

    # Set defaults if not specified
    if [ -z "$php_version" ]; then
        php_version="8.1"  # Moodle 4.x default
        print_info "No PHP version specified, using default: 8.1"
    fi

    if [ -z "$database" ]; then
        database="mariadb"
        print_info "No database specified, using default: mariadb"
    fi

    if [ -z "$webroot" ]; then
        webroot="."
        print_info "No webroot specified, using default: . (current directory)"
    fi

    if [ -z "$sitename" ]; then
        sitename="My Moodle Site"
    fi

    if [ -z "$branch" ]; then
        branch="MOODLE_404_STABLE"
        print_info "No branch specified, using default: MOODLE_404_STABLE"
    fi

    # Validate required values
    if [ -z "$source" ]; then
        print_error "Recipe '$recipe' does not specify 'source'"
        return 1
    fi

    print_info "Configuration:"
    echo "  Source:   $source"
    echo "  Branch:   $branch"
    echo "  Webroot:  $webroot"
    echo "  Database: $database"
    echo "  PHP:      $php_version"
    echo "  Sitename: $sitename"
    echo ""

    # Step 1: Clone Moodle from Git
    if should_run_step 1 "$start_step"; then
        print_header "Step 1: Clone Moodle Repository"
        print_info "This may take several minutes..."

        if ! git clone --branch "$branch" --depth 1 "$source" .; then
            print_error "Failed to clone Moodle repository"
            return 1
        fi
        print_status "OK" "Moodle cloned successfully"
    else
        print_status "INFO" "Skipping Step 1: Moodle already cloned"
    fi

    # Step 2: Configure DDEV
    if should_run_step 2 "$start_step"; then
        print_header "Step 2: Configure DDEV"

        # Map database type to DDEV database type
        local ddev_database="$database"
        if [ "$database" == "mysql" ]; then
            ddev_database="mysql:8.0"
        elif [ "$database" == "mariadb" ]; then
            ddev_database="mariadb:10.11"
        fi

        # Moodle uses php project type
        if ! ddev config --project-type=php --docroot="$webroot" --php-version="$php_version" --database="$ddev_database"; then
            print_error "Failed to configure DDEV"
            return 1
        fi
        print_status "OK" "DDEV configured (Database: $ddev_database)"
    else
        print_status "INFO" "Skipping Step 2: DDEV already configured"
    fi

    # Step 3: Memory Configuration
    if should_run_step 3 "$start_step"; then
        print_header "Step 3: Memory Configuration"

        mkdir -p .ddev/php
        cat > .ddev/php/memory.ini << 'EOF'
memory_limit = 512M
max_execution_time = 600
post_max_size = 100M
upload_max_filesize = 100M
EOF
        print_status "OK" "Memory limits configured"
    else
        print_status "INFO" "Skipping Step 3: Memory already configured"
    fi

    # Step 4: Launch Services
    if should_run_step 4 "$start_step"; then
        print_header "Step 4: Launch DDEV Services"

        if ! ddev start; then
            print_error "Failed to start DDEV"
            return 1
        fi
        print_status "OK" "DDEV services started"
    else
        print_status "INFO" "Skipping Step 4: DDEV already started"
    fi

    # Step 5: Create Moodledata Directory
    if should_run_step 5 "$start_step"; then
        print_header "Step 5: Create Moodledata Directory"

        mkdir -p moodledata
        chmod 777 moodledata
        print_status "OK" "Moodledata directory created"
    else
        print_status "INFO" "Skipping Step 5: Moodledata already exists"
    fi

    # Step 6: Install Moodle
    if should_run_step 6 "$start_step"; then
        print_header "Step 6: Install Moodle"
        print_info "This will take 5-10 minutes..."

        # Verify DDEV is running and restart to ensure proper mount
        print_info "Verifying DDEV status..."
        if ! ddev describe >/dev/null 2>&1; then
            print_error "DDEV is not running. Starting DDEV..."
            if ! ddev start; then
                print_error "Failed to start DDEV"
                return 1
            fi
        else
            # Restart DDEV to ensure proper container mount context
            print_info "Restarting DDEV to ensure proper container configuration..."
            if ! ddev restart >/dev/null 2>&1; then
                print_error "Failed to restart DDEV"
                return 1
            fi
        fi

        # Verify current directory is accessible
        print_info "Working directory: $(pwd)"
        print_info "Verifying container access..."
        if ! ddev exec pwd >/dev/null 2>&1; then
            print_error "Container cannot access current directory"
            print_error "This is likely a Docker AppArmor/SELinux issue"
            print_info "Try running: sudo aa-status | grep docker"
            return 1
        fi

        # Determine database driver
        local db_driver="mariadb"
        if [ "$database" == "mysql" ]; then
            db_driver="mysqli"
        elif [ "$database" == "mariadb" ]; then
            db_driver="mariadb"
        fi

        # Get the site URL - try multiple methods
        local site_url=""

        # Method 1: Try to get primary_url from JSON
        site_url=$(ddev describe -j 2>/dev/null | grep -o '"primary_url":"[^"]*' | cut -d'"' -f4)

        # Method 2: If that fails, try httpurl
        if [ -z "$site_url" ]; then
            site_url=$(ddev describe -j 2>/dev/null | grep -o '"httpurl":"[^"]*' | cut -d'"' -f4)
        fi

        # Method 3: If that fails, try httpsurl
        if [ -z "$site_url" ]; then
            site_url=$(ddev describe -j 2>/dev/null | grep -o '"httpsurl":"[^"]*' | cut -d'"' -f4)
        fi

        # Method 4: Fallback to hostname-based URL
        if [ -z "$site_url" ]; then
            local hostname=$(ddev describe -j 2>/dev/null | grep -o '"hostname":"[^"]*' | cut -d'"' -f4)
            if [ -n "$hostname" ]; then
                site_url="https://$hostname"
            fi
        fi

        if [ -z "$site_url" ]; then
            print_error "Failed to get site URL from DDEV"
            ddev describe 2>&1 | head -10
            return 1
        fi

        print_info "Site URL: $site_url"

        # Run Moodle installation
        if ! ddev exec php admin/cli/install.php \
            --lang=en \
            --wwwroot="$site_url" \
            --dataroot=/var/www/html/moodledata \
            --dbtype="$db_driver" \
            --dbhost=db \
            --dbname=db \
            --dbuser=db \
            --dbpass=db \
            --fullname="$sitename" \
            --shortname=moodle \
            --adminuser=admin \
            --adminpass=Admin123! \
            --adminemail=admin@example.com \
            --non-interactive \
            --agree-license; then
            print_error "Failed to install Moodle"
            return 1
        fi
        print_status "OK" "Moodle site installed"
    else
        print_status "INFO" "Skipping Step 6: Moodle already installed"
    fi

    # Step 7: Post-installation configuration
    if should_run_step 7 "$start_step"; then
        print_header "Step 7: Post-Installation Configuration"

        # Set up cron (optional)
        print_info "Moodle installed successfully"
        print_status "OK" "Installation complete"
    else
        print_status "INFO" "Skipping Step 7: Already configured"
    fi

    # Success message
    print_header "Installation Complete!"

    echo -e "${GREEN}${BOLD}✓ Moodle has been successfully installed!${NC}\n"
    echo -e "${BOLD}Login credentials:${NC}"
    echo -e "  Username: ${GREEN}admin${NC}"
    echo -e "  Password: ${GREEN}Admin123!${NC}\n"

    # Open site
    print_info "Opening site in browser..."

    if command -v xdg-open &> /dev/null; then
        local site_url=$(ddev describe -j 2>/dev/null | grep -o '"url":"[^"]*' | cut -d'"' -f4)
        if [ -n "$site_url" ]; then
            xdg-open "$site_url" &>/dev/null &
            print_status "OK" "Site opened in browser: $site_url"
        fi
    elif command -v open &> /dev/null; then
        local site_url=$(ddev describe -j 2>/dev/null | grep -o '"url":"[^"]*' | cut -d'"' -f4)
        if [ -n "$site_url" ]; then
            open "$site_url" &>/dev/null &
            print_status "OK" "Site opened in browser: $site_url"
        fi
    fi

    echo ""
    echo -e "${BOLD}Useful commands:${NC}"
    echo -e "  ${BLUE}ddev launch${NC}      - Open site in browser"
    echo -e "  ${BLUE}ddev ssh${NC}          - SSH into container"
    echo -e "  ${BLUE}ddev exec php admin/cli/cron.php${NC} - Run Moodle cron\n"

    return 0
}

################################################################################
# Main Script
################################################################################

main() {
    local recipe=""
    local start_step=""
    local create_content="n"
    local config_file="nwpc.yml"

    # Parse arguments
    for arg in "$@"; do
        if [[ "$arg" =~ ^s=([0-9]+)$ ]]; then
            start_step="${BASH_REMATCH[1]}"
        elif [[ "$arg" =~ ^--step=([0-9]+)$ ]]; then
            start_step="${BASH_REMATCH[1]}"
        elif [[ "$arg" == "c" ]] || [[ "$arg" == "--create-content" ]]; then
            create_content="y"
        else
            recipe="$arg"
        fi
    done

    # Default recipe if not specified
    if [ -z "$recipe" ]; then
        recipe="default"
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
        grep "^  [a-zA-Z0-9_-]*:" "$config_file" | sed 's/://g' | sed 's/^  /  - /'
        exit 1
    fi

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

    # Determine installation directory based on whether we're resuming
    local install_dir=""
    if [ -n "$start_step" ]; then
        # When resuming, use recipe name directly
        install_dir="$recipe"
    else
        # Fresh install - find available directory with auto-increment
        install_dir=$(get_available_dirname "$recipe")
    fi

    # Read configuration values to display
    local recipe_type=$(get_recipe_value "$recipe" "type" "$config_file")
    local source=$(get_recipe_value "$recipe" "source" "$config_file")
    local profile=$(get_recipe_value "$recipe" "profile" "$config_file")
    local webroot=$(get_recipe_value "$recipe" "webroot" "$config_file")
    local database=$(get_root_value "database" "$config_file")
    local php_version=$(get_root_value "php" "$config_file")
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

    # Run installation based on recipe type
    if [ "$recipe_type" == "moodle" ]; then
        if install_moodle "$recipe" "$start_step"; then
            exit 0
        else
            print_error "Installation failed"
            exit 1
        fi
    else
        # Default to Drupal/OpenSocial installation
        if install_opensocial "$recipe" "$start_step" "$create_content"; then
            exit 0
        else
            print_error "Installation failed"
            exit 1
        fi
    fi
}

# Run main
main "$@"
