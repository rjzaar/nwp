#!/bin/bash
################################################################################
# NWP Drupal/OpenSocial Installation Library
#
# Handles Drupal-based installations including OpenSocial
# This file is lazy-loaded by install.sh when recipe type is "drupal"
################################################################################

# Guard against multiple sourcing
if [ "${_INSTALL_DRUPAL_LOADED:-}" = "1" ]; then
    return 0
fi
_INSTALL_DRUPAL_LOADED=1

################################################################################
# Main Drupal Installation Function
################################################################################

install_drupal() {
    local recipe=$1
    local install_dir=$2
    local start_step=$3
    local create_content=$4
    local purpose=${5:-indefinite}
    local base_dir=$(pwd)
    local site_name=$(basename "$install_dir")
    local config_file="$base_dir/cnwp.yml"

    # Clean up spinner on exit/error
    trap 'stop_spinner' EXIT INT TERM

    # Helper to track installation progress
    track_step() {
        local step_num="$1"
        if command -v set_install_step &>/dev/null; then
            set_install_step "$site_name" "$step_num" "$config_file"
        fi
    }

    print_header "Installing OpenSocial using recipe: $recipe"

    if [ -n "$start_step" ]; then
        print_info "Starting from step $start_step (skipping earlier steps)"
        echo ""
    fi

    # Setup installation directory
    local project_dir=""

    if [ -n "$start_step" ]; then
        # When resuming, directory must already exist
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
        # Fresh installation - create directory
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

        # Register site stub for progress tracking (fresh install only)
        if type yaml_add_site_stub &>/dev/null; then
            yaml_add_site_stub "$site_name" "$project_dir" "$recipe" "$config_file" 2>/dev/null
        fi
    fi

    # Extract configuration values from YAML
    local source=$(get_recipe_value "$recipe" "source" "$base_dir/cnwp.yml")
    local source_git=$(get_recipe_value "$recipe" "source_git" "$base_dir/cnwp.yml")
    local profile=$(get_recipe_value "$recipe" "profile" "$base_dir/cnwp.yml")
    local profile_source=$(get_recipe_value "$recipe" "profile_source" "$base_dir/cnwp.yml")
    local webroot=$(get_recipe_value "$recipe" "webroot" "$base_dir/cnwp.yml")
    local install_modules=$(get_recipe_value "$recipe" "install_modules" "$base_dir/cnwp.yml")
    local post_install_modules=$(get_recipe_list_value "$recipe" "post_install_modules" "$base_dir/cnwp.yml")
    local post_install_scripts=$(get_recipe_list_value "$recipe" "post_install_scripts" "$base_dir/cnwp.yml")
    local default_theme=$(get_recipe_value "$recipe" "default_theme" "$base_dir/cnwp.yml")

    # Get PHP and database: recipe overrides settings, settings overrides defaults
    local php_version=$(get_recipe_value "$recipe" "php" "$base_dir/cnwp.yml")
    local database=$(get_recipe_value "$recipe" "database" "$base_dir/cnwp.yml")

    # Fall back to settings if not in recipe
    if [ -z "$php_version" ]; then
        php_version=$(get_settings_value "php" "$base_dir/cnwp.yml")
    fi
    if [ -z "$database" ]; then
        database=$(get_settings_value "database" "$base_dir/cnwp.yml")
    fi

    # Set defaults if still not specified
    if [ -z "$php_version" ]; then
        php_version="8.3"  # Default
        print_info "No PHP version specified, using default: 8.3"
    fi
    if [ -z "$database" ]; then
        database="mysql"  # Default
        print_info "No database specified, using default: mysql"
    fi

    # Validate required values - need either source or source_git
    if [ -z "$source" ] && [ -z "$source_git" ]; then
        print_error "Recipe '$recipe' does not specify 'source' or 'source_git'"
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
    if [ -n "$source_git" ]; then
        echo "  Source:   $source_git (git clone)"
    else
        echo "  Source:   $source (composer)"
    fi
    echo "  Profile:  $profile"
    echo "  Webroot:  $webroot"
    echo "  Database: $database"
    echo "  PHP:      $php_version"
    echo ""

    # Step 1: Initialize Project
    if should_run_step 1 "$start_step"; then
        show_step 1 9 "Initializing project"
        if [ -n "$source_git" ]; then
            print_header "Step 1: Clone Project from Git"
            print_info "Cloning project repository..."

            if ! git clone "$source_git" .; then
                print_error "Failed to clone project from $source_git"
                return 1
            fi
            print_status "OK" "Project cloned from git"

            # Set up GitLab authentication for composer
            local composer_auth=""
            local gitlab_url=$(get_gitlab_url)
            local gitlab_token=$(get_gitlab_token)
            if [ -n "$gitlab_url" ] && [ -n "$gitlab_token" ]; then
                composer_auth="COMPOSER_AUTH={\"gitlab-token\":{\"${gitlab_url}\":\"${gitlab_token}\"}}"
                print_info "Using GitLab authentication for composer"
            fi

            # Install composer dependencies
            print_info "Installing dependencies (this will take 10-15 minutes)..."
            start_spinner "Installing composer dependencies..."
            if ! env $composer_auth composer install --no-interaction; then
                stop_spinner
                print_error "Failed to install project dependencies"
                return 1
            fi
            stop_spinner
            print_status "OK" "Dependencies installed"
        else
            print_header "Step 1: Initialize Project with Composer"
            print_info "This will take 10-15 minutes..."

            # Extract project without installing dependencies
            print_info "Extracting project template..."

            # Check if source is from GitLab registry (nwp/ prefix)
            local gitlab_repo_opt=""
            local composer_auth=""
            if [[ "$source" == nwp/* ]]; then
                local gitlab_url=$(get_gitlab_url)
                local gitlab_token=$(get_gitlab_token)
                if [ -n "$gitlab_url" ]; then
                    local repo_url="https://${gitlab_url}/api/v4/group/nwp/-/packages/composer/packages.json"
                    gitlab_repo_opt="--repository=${repo_url}"
                    print_info "Using GitLab Composer registry: $gitlab_url"
                    if [ -n "$gitlab_token" ]; then
                        composer_auth="COMPOSER_AUTH={\"gitlab-token\":{\"${gitlab_url}\":\"${gitlab_token}\"}}"
                    fi
                fi
            fi

            if ! env $composer_auth composer create-project "$source" . --no-install --no-interaction $gitlab_repo_opt; then
                print_error "Failed to extract project template"
                return 1
            fi

            # Add Asset Packagist repository to project composer.json
            print_info "Configuring repositories..."
            composer config repositories.asset-packagist composer https://asset-packagist.org
            composer config repositories.drupal composer https://packages.drupal.org/8

            # Allow required composer plugins
            print_info "Configuring composer plugins..."
            composer config --no-plugins allow-plugins.cweagans/composer-patches true
            composer config --no-plugins allow-plugins.composer/installers true
            composer config --no-plugins allow-plugins.drupal/core-composer-scaffold true
            composer config --no-plugins allow-plugins.oomphinc/composer-installers-extender true
            composer config --no-plugins allow-plugins.zaporylie/composer-drupal-optimizations true

            # Install dependencies with Asset Packagist available
            print_info "Installing dependencies (this will take 10-15 minutes)..."
            start_spinner "Installing composer dependencies..."
            if ! env $composer_auth composer install --no-interaction; then
                stop_spinner
                print_error "Failed to install project dependencies"
                return 1
            fi
            stop_spinner
            print_status "OK" "Dependencies installed"
        fi  # End source vs source_git

        # Configure GitLab composer authentication if available
        local gitlab_url=$(get_gitlab_url)
        local gitlab_token=$(get_gitlab_token)
        if [ -n "$gitlab_url" ] && [ -n "$gitlab_token" ]; then
            print_info "Configuring GitLab composer authentication..."
            if composer config --auth gitlab-token."${gitlab_url}" "${gitlab_token}" 2>/dev/null; then
                print_status "OK" "GitLab authentication configured"
            else
                print_status "WARN" "Could not configure GitLab authentication (will use cached packages)"
            fi
        fi

        # Install Drush
        print_info "Installing Drush..."
        if composer require drush/drush --dev --no-interaction; then
            print_status "OK" "Drush installed"
        else
            print_status "WARN" "Drush installation failed, but may already be available"
        fi

        # Install environment_indicator for environment awareness
        print_info "Installing environment indicator module..."
        if composer require drupal/environment_indicator --no-interaction; then
            print_status "OK" "Environment indicator module installed"
        else
            print_status "WARN" "Environment indicator installation failed (non-critical)"
        fi

        print_status "OK" "Dependencies installed successfully"

        # Install additional modules if specified
        if [ -n "$install_modules" ]; then
            # Separate git modules from composer modules
            local git_modules=""
            local composer_modules=""

            for module in $install_modules; do
                if is_git_url "$module"; then
                    git_modules="$git_modules $module"
                else
                    composer_modules="$composer_modules $module"
                fi
            done

            # Install composer modules
            if [ -n "$composer_modules" ]; then
                # Configure dworkflow repository only when needed
                print_info "Configuring custom repositories for additional modules..."
                composer config repositories.dworkflow vcs https://github.com/rjzaar/dworkflow

                print_info "Installing composer modules:$composer_modules"
                if ! composer require $composer_modules --no-interaction; then
                    print_error "Failed to install composer modules"
                    return 1
                fi
                print_status "OK" "Composer modules installed"
            fi

            # Install git modules
            if [ -n "$git_modules" ]; then
                if ! install_git_modules "$git_modules" "$webroot"; then
                    print_error "Failed to install git modules"
                    return 1
                fi
                print_status "OK" "Git modules installed"
            fi
        fi

        # Install profile from git repository if specified
        # This clones the profile to profiles/custom/ for active development
        if [ -n "$profile_source" ]; then
            if is_git_url "$profile_source"; then
                print_info "Installing profile from git: $profile_source"
                if ! install_git_profile "$profile_source" "$profile" "$webroot"; then
                    print_error "Failed to install profile from git"
                    return 1
                fi
            else
                print_status "WARN" "profile_source is not a git URL: $profile_source"
            fi
        fi

        print_status "OK" "Project initialized"
        track_step 1
    else
        print_status "INFO" "Skipping Step 1: Project already initialized"
    fi

    # Step 2: Generate Environment Configuration
    if should_run_step 2 "$start_step"; then
        show_step 2 9 "Generating environment configuration"
        print_header "Step 2: Generate Environment Configuration"

        # Use base_dir (NWP root) to find env generation script
        local env_script="$base_dir/lib/env-generate.sh"

        if [ ! -f "$env_script" ]; then
            print_error "Environment generation script not found at $env_script"
            return 1
        fi

        # Generate .env file
        # Note: env-generate.sh expects sitename (not path), so use basename
        print_info "Generating .env file from cnwp.yml..."
        if ! "$env_script" "$recipe" "$(basename "$install_dir")" .; then
            print_error "Failed to generate environment configuration"
            return 1
        fi

        print_status "OK" "Environment configuration generated"

        # Load environment variables
        if [ -f ".env" ]; then
            print_info "Loading environment variables..."
            set -a
            source ".env"
            set +a
            print_status "OK" "Environment variables loaded"
        fi
        track_step 2
    else
        print_status "INFO" "Skipping Step 2: Environment already configured"
    fi

    # Step 3: Configure DDEV
    if should_run_step 3 "$start_step"; then
        show_step 3 9 "Configuring DDEV"
        print_header "Step 3: Configure DDEV"

        # Use base_dir (NWP root) to find DDEV generation script
        local ddev_script="$base_dir/lib/ddev-generate.sh"

        if [ -f "$ddev_script" ]; then
            # Generate DDEV config from .env
            print_info "Generating DDEV configuration from .env..."
            if ! "$ddev_script" .; then
                print_error "Failed to generate DDEV configuration"
                return 1
            fi
            print_status "OK" "DDEV configuration generated"
        else
            # Fallback to manual DDEV config
            print_warning "Vortex DDEV script not found, using manual configuration"

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
        fi
        track_step 3
    else
        print_status "INFO" "Skipping Step 3: DDEV already configured"
    fi

    # Step 4: Memory Configuration
    if should_run_step 4 "$start_step"; then
        show_step 4 9 "Configuring memory settings"
        print_header "Step 4: Memory Configuration"

        # Get PHP settings from cnwp.yml (with defaults)
        local php_memory=$(get_setting "php_settings.memory_limit" "512M")
        local php_max_exec=$(get_setting "php_settings.max_execution_time" "600")
        local php_upload_max=$(get_setting "php_settings.upload_max_filesize" "100M")
        local php_post_max=$(get_setting "php_settings.post_max_size" "100M")

        mkdir -p .ddev/php
        cat > .ddev/php/memory.ini << EOF
memory_limit = ${php_memory}
max_execution_time = ${php_max_exec}
post_max_size = ${php_post_max}
upload_max_filesize = ${php_upload_max}
EOF
        print_status "OK" "Memory limits configured"
        track_step 4
    else
        print_status "INFO" "Skipping Step 4: Memory already configured"
    fi

    # Step 5: Launch Services
    if should_run_step 5 "$start_step"; then
        show_step 5 9 "Launching DDEV services"
        print_header "Step 5: Launch DDEV Services"

        # Get project name from DDEV config
        local ddev_project_name=""
        if [ -f ".ddev/config.yaml" ]; then
            ddev_project_name=$(grep "^name:" .ddev/config.yaml | sed 's/^name: *//')
        fi

        # Check for and clean up stale DDEV project registration
        if [ -n "$ddev_project_name" ]; then
            local current_dir=$(pwd)
            # Use JSON output for reliable parsing - extract approot for matching project name
            local registered_path=""
            if command -v jq &>/dev/null; then
                registered_path=$(ddev list -j 2>/dev/null | jq -r --arg name "$ddev_project_name" '.raw[]? | select(.name == $name) | .approot // empty' 2>/dev/null || true)
            else
                # Fallback: parse JSON with grep/sed if jq not available
                registered_path=$(ddev list -j 2>/dev/null | grep -o "\"name\":\"$ddev_project_name\"[^}]*\"approot\":\"[^\"]*\"" | sed 's/.*"approot":"\([^"]*\)".*/\1/' 2>/dev/null || true)
            fi
            if [ -n "$registered_path" ] && [ "$registered_path" != "$current_dir" ]; then
                print_info "Cleaning up stale DDEV registration for '$ddev_project_name'..."
                print_info "  Registered at: $registered_path"
                print_info "  Current dir:   $current_dir"
                ddev stop --unlist "$ddev_project_name" 2>/dev/null || true
            fi
        fi

        if ! ddev start; then
            print_error "Failed to start DDEV"
            return 1
        fi
        print_status "OK" "DDEV services started"

        # Configure GitLab composer authentication in DDEV container
        local gitlab_url=$(get_gitlab_url)
        local gitlab_token=$(get_gitlab_token)
        if [ -n "$gitlab_url" ] && [ -n "$gitlab_token" ]; then
            print_info "Configuring GitLab composer authentication..."
            if ddev composer config --auth gitlab-token."${gitlab_url}" "${gitlab_token}" 2>/dev/null; then
                print_status "OK" "GitLab authentication configured"
            else
                print_status "WARN" "Could not configure GitLab authentication"
            fi
        fi

        track_step 5
    else
        print_status "INFO" "Skipping Step 5: DDEV already started"
    fi

    # Step 6: Verify Drush is Available
    if should_run_step 6 "$start_step"; then
        show_step 6 9 "Verifying Drush availability"
        print_header "Step 6: Verify Drush is Available"

        # Check if Drush is available
        if [ -f "vendor/bin/drush" ]; then
            print_status "OK" "Drush is available"
            track_step 6
        else
            print_error "Drush not found - installation may have failed in Step 1"
            print_info "Try manually installing with: composer require drush/drush --dev"
        fi
    else
        print_status "INFO" "Skipping Step 6: Drush verification"
    fi

    # Step 7: Configure Private File System and Environment Detection
    if should_run_step 7 "$start_step"; then
        show_step 7 9 "Configuring file system and environment"
        print_header "Step 7: Configure File System and Environment Detection"

        # Create private files directory
        mkdir -p private

        # Ensure sites/default directory exists and is writable
        mkdir -p "${webroot}/sites/default"
        chmod 755 "${webroot}/sites/default"

        # Create includes/modules directory for environment-specific settings
        mkdir -p "${webroot}/sites/default/includes/modules"

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

        # Append private file path, environment detection, and includes to settings.php
        cat >> "${webroot}/sites/default/settings.php" << 'SETTINGS_EOF'

/**
 * Private file system configuration.
 * Required for OpenSocial installation.
 */
$settings['file_private_path'] = '../private';

////////////////////////////////////////////////////////////////////////////////
///                       ENVIRONMENT TYPE DETECTION                         ///
////////////////////////////////////////////////////////////////////////////////
// NWP environment detection based on site naming convention and env variables.
// @see https://www.drupal.org/project/environment_indicator

// Define environment constants for use throughout the application.
if (!defined('ENVIRONMENT_LOCAL')) {
  define('ENVIRONMENT_LOCAL', 'local');
}
if (!defined('ENVIRONMENT_CI')) {
  define('ENVIRONMENT_CI', 'ci');
}
if (!defined('ENVIRONMENT_DEV')) {
  define('ENVIRONMENT_DEV', 'dev');
}
if (!defined('ENVIRONMENT_STAGE')) {
  define('ENVIRONMENT_STAGE', 'stage');
}
if (!defined('ENVIRONMENT_PROD')) {
  define('ENVIRONMENT_PROD', 'prod');
}

// Default environment type is 'local' for DDEV sites.
$settings['environment'] = ENVIRONMENT_LOCAL;

// NWP naming convention detection:
// - sitename-stg = staging environment
// - sitename_prod = production environment
// - sitename (no suffix) = development environment
$nwp_site_dir = basename(dirname(dirname(dirname(__DIR__))));
if (preg_match('/-stg$/', $nwp_site_dir)) {
  $settings['environment'] = ENVIRONMENT_STAGE;
}
elseif (preg_match('/_prod$/', $nwp_site_dir)) {
  $settings['environment'] = ENVIRONMENT_PROD;
}

// Allow override via environment variable (takes precedence).
if (!empty(getenv('DRUPAL_ENVIRONMENT'))) {
  $settings['environment'] = getenv('DRUPAL_ENVIRONMENT');
}

// CI detection (GitHub Actions, GitLab CI, etc.).
if (!empty(getenv('CI')) || !empty(getenv('GITHUB_ACTIONS')) || !empty(getenv('GITLAB_CI'))) {
  $settings['environment'] = ENVIRONMENT_CI;
}

////////////////////////////////////////////////////////////////////////////////
///                       PER-MODULE OVERRIDES                               ///
////////////////////////////////////////////////////////////////////////////////
// Load module-specific settings from includes/modules directory.
// This allows environment-aware configuration for modules like
// environment_indicator, config_split, shield, etc.

if (file_exists($app_root . '/' . $site_path . '/includes/modules')) {
  $files = glob($app_root . '/' . $site_path . '/includes/modules/settings.*.php');
  if ($files) {
    foreach ($files as $file) {
      require $file;
    }
  }
}

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
SETTINGS_EOF

        chmod 644 "${webroot}/sites/default/settings.php"
        print_status "OK" "Settings.php configured with environment detection"

        # Create environment_indicator settings file
        cat > "${webroot}/sites/default/includes/modules/settings.environment_indicator.php" << 'ENV_INDICATOR_EOF'
<?php

/**
 * @file
 * Environment indicator module settings.
 *
 * Provides visual feedback in the Drupal admin toolbar showing which
 * environment (local, dev, staging, production) the site is running in.
 *
 * @see https://www.drupal.org/project/environment_indicator
 */

declare(strict_types=1);

// Only configure if environment is set.
if (!empty($settings['environment'])) {
  $config['environment_indicator.indicator']['name'] = strtoupper($settings['environment']);
  $config['environment_indicator.indicator']['bg_color'] = '#006600';
  $config['environment_indicator.indicator']['fg_color'] = '#ffffff';
  $config['environment_indicator.settings']['toolbar_integration'] = [TRUE];
  $config['environment_indicator.settings']['favicon'] = TRUE;

  switch ($settings['environment']) {
    case ENVIRONMENT_PROD:
      $config['environment_indicator.indicator']['bg_color'] = '#ef5350';
      $config['environment_indicator.indicator']['fg_color'] = '#000000';
      $config['environment_indicator.indicator']['name'] = 'PRODUCTION';
      break;

    case ENVIRONMENT_STAGE:
      $config['environment_indicator.indicator']['bg_color'] = '#fff176';
      $config['environment_indicator.indicator']['fg_color'] = '#000000';
      $config['environment_indicator.indicator']['name'] = 'STAGING';
      break;

    case ENVIRONMENT_DEV:
      $config['environment_indicator.indicator']['bg_color'] = '#4caf50';
      $config['environment_indicator.indicator']['fg_color'] = '#000000';
      $config['environment_indicator.indicator']['name'] = 'DEVELOPMENT';
      break;

    case ENVIRONMENT_LOCAL:
      $config['environment_indicator.indicator']['bg_color'] = '#2196f3';
      $config['environment_indicator.indicator']['fg_color'] = '#ffffff';
      $config['environment_indicator.indicator']['name'] = 'LOCAL';
      break;

    case ENVIRONMENT_CI:
      $config['environment_indicator.indicator']['bg_color'] = '#9c27b0';
      $config['environment_indicator.indicator']['fg_color'] = '#ffffff';
      $config['environment_indicator.indicator']['name'] = 'CI';
      break;
  }
}
ENV_INDICATOR_EOF

        print_status "OK" "Environment indicator settings created"

        # Create config_split settings file
        cat > "${webroot}/sites/default/includes/modules/settings.config_split.php" << 'CONFIG_SPLIT_EOF'
<?php

/**
 * @file
 * Config split module settings.
 *
 * Enables environment-specific configuration splits based on the detected
 * environment. This allows different modules and settings per environment.
 *
 * @see https://www.drupal.org/project/config_split
 */

declare(strict_types=1);

// Only configure if environment is set.
if (!empty($settings['environment'])) {
  switch ($settings['environment']) {
    case ENVIRONMENT_PROD:
      $config['config_split.config_split.dev']['status'] = FALSE;
      $config['config_split.config_split.local']['status'] = FALSE;
      $config['config_split.config_split.stage']['status'] = FALSE;
      $config['config_split.config_split.ci']['status'] = FALSE;
      break;

    case ENVIRONMENT_STAGE:
      $config['config_split.config_split.stage']['status'] = TRUE;
      $config['config_split.config_split.dev']['status'] = FALSE;
      $config['config_split.config_split.local']['status'] = FALSE;
      $config['config_split.config_split.ci']['status'] = FALSE;
      break;

    case ENVIRONMENT_DEV:
      $config['config_split.config_split.dev']['status'] = TRUE;
      $config['config_split.config_split.local']['status'] = FALSE;
      $config['config_split.config_split.stage']['status'] = FALSE;
      $config['config_split.config_split.ci']['status'] = FALSE;
      break;

    case ENVIRONMENT_CI:
      $config['config_split.config_split.ci']['status'] = TRUE;
      $config['config_split.config_split.dev']['status'] = FALSE;
      $config['config_split.config_split.local']['status'] = FALSE;
      $config['config_split.config_split.stage']['status'] = FALSE;
      break;

    case ENVIRONMENT_LOCAL:
    default:
      $config['config_split.config_split.dev']['status'] = TRUE;
      $config['config_split.config_split.local']['status'] = TRUE;
      $config['config_split.config_split.stage']['status'] = FALSE;
      $config['config_split.config_split.ci']['status'] = FALSE;
      break;
  }
}
CONFIG_SPLIT_EOF

        print_status "OK" "Config split settings created"
        track_step 7
    else
        print_status "INFO" "Skipping Step 7: File system already configured"
    fi

    # Step 8: Install Drupal Profile
    if should_run_step 8 "$start_step"; then
        show_step 8 9 "Installing Drupal profile"
        print_header "Step 8: Install Drupal Profile"
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

        # Generate secure admin password
        local admin_password
        admin_password=$(generate_secure_password 16)

        # Get site email address (sitename@domain)
        local email_domain
        email_domain=$(get_settings_value "email.domain" "" "$config_file" 2>/dev/null)
        if [ -z "$email_domain" ]; then
            email_domain=$(get_settings_value "url" "nwpcode.org" "$config_file" 2>/dev/null)
        fi
        local site_email="${site_name}@${email_domain}"

        if ! ddev drush site:install "$profile" \
            --db-url="${db_driver}://db:db@db:3306/db" \
            --account-name=admin \
            --account-pass="$admin_password" \
            --site-name="${site_name}" \
            --site-mail="$site_email" \
            -y; then
            print_error "Failed to install Drupal site"
            return 1
        fi
        print_status "OK" "Drupal site installed"
        echo ""
        print_status "INFO" "Admin credentials:"
        echo -e "  ${CYAN:-}Username:${NC:-} admin"
        echo -e "  ${CYAN:-}Password:${NC:-} $admin_password"
        echo -e "  ${YELLOW:-}(Save this password - it will not be shown again)${NC:-}"
        echo ""
        track_step 8
    else
        print_status "INFO" "Skipping Step 8: Drupal already installed"
    fi

    # Step 9: Additional modules and configuration
    if should_run_step 9 "$start_step"; then
        show_step 9 9 "Enabling modules and finalizing configuration"
        print_header "Step 9: Enable Core Modules"

        # Enable environment_indicator module (installed via composer in Step 1)
        print_info "Enabling environment indicator module..."
        if ddev drush pm:enable environment_indicator -y 2>/dev/null; then
            print_status "OK" "Environment indicator enabled"
        else
            print_status "WARN" "Environment indicator not available (install with: composer require drupal/environment_indicator)"
        fi

        # Enable post-install modules from recipe (e.g., AVC modules)
        if [ -n "$post_install_modules" ]; then
            print_info "Enabling post-install modules: $post_install_modules"
            if ddev drush pm:enable $post_install_modules -y; then
                print_status "OK" "Post-install modules enabled"
            else
                print_error "Failed to enable some post-install modules"
                print_status "INFO" "You may need to enable modules manually with: ddev drush pm:enable <module>"
            fi
        fi

        # Run post-install scripts from recipe (e.g., seed scripts)
        if [ -n "$post_install_scripts" ]; then
            print_info "Running post-install scripts..."
            for script in $post_install_scripts; do
                local script_path=""
                if [ -f "$webroot/$script" ]; then
                    script_path="$webroot/$script"
                elif [ -f "$script" ]; then
                    script_path="$script"
                else
                    print_status "WARN" "Script not found: $script"
                    continue
                fi

                print_info "  Running: $script"

                # Detect script type by extension
                if [[ "$script" == *.sh ]]; then
                    # Shell script - run with bash in DDEV container
                    if ddev exec bash "$script_path"; then
                        print_status "OK" "Script completed: $(basename "$script")"
                    else
                        print_status "WARN" "Script failed: $script"
                    fi
                else
                    # PHP script - run with drush php:script
                    if ddev drush php:script "$script_path"; then
                        print_status "OK" "Script completed: $(basename "$script")"
                    else
                        print_status "WARN" "Script failed: $script"
                    fi
                fi
            done
        fi

        # Set default theme if specified in recipe
        if [ -n "$default_theme" ]; then
            print_info "Setting default theme: $default_theme"
            # First install the theme if not already installed
            if ddev drush theme:enable "$default_theme" -y 2>/dev/null; then
                # Set as default theme
                if ddev drush config:set system.theme default "$default_theme" -y; then
                    print_status "OK" "Default theme set to $default_theme"
                else
                    print_status "WARN" "Failed to set $default_theme as default theme"
                fi
            else
                print_status "WARN" "Theme $default_theme not available"
            fi
        fi

        # Dev modules installation if dev mode enabled
        local dev=$(get_recipe_value "$recipe" "dev" "$base_dir/cnwp.yml")
        if [ "$dev" == "y" ]; then
            local dev_modules=$(get_recipe_value "$recipe" "dev_modules" "$base_dir/cnwp.yml")
            if [ -n "$dev_modules" ]; then
                print_header "Installing Development Modules"
                print_info "Modules: $dev_modules"

                # Install dev modules via composer first
                local composer_packages=""
                for module in $dev_modules; do
                    # Convert module name to composer package (e.g., devel -> drupal/devel)
                    if [[ ! "$module" =~ ^drupal/ ]]; then
                        composer_packages="$composer_packages drupal/$module"
                    else
                        composer_packages="$composer_packages $module"
                    fi
                done

                print_info "Installing via composer: $composer_packages"
                if ! ddev composer require $composer_packages --dev --no-interaction; then
                    print_error "Failed to install dev modules via composer"
                else
                    print_status "OK" "Dev modules installed via composer"

                    # Now enable the modules
                    if ! ddev drush pm:enable $dev_modules -y; then
                        print_error "Failed to enable dev modules: $dev_modules"
                    else
                        print_status "OK" "Development modules enabled"
                    fi
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
        track_step 9
    else
        print_status "INFO" "Skipping Step 9: Additional configuration"
    fi

    # Apply selected options from interactive checkbox
    apply_drupal_options

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

    # Complete site registration in cnwp.yml (stub was created at install start)
    if command -v yaml_complete_site_stub &> /dev/null; then
        print_info "Completing site registration in cnwp.yml..."

        # Get full directory path
        local site_dir=$(pwd)
        local site_name=$(basename "$site_dir")

        # Determine environment type from directory suffix
        local environment="development"
        if [[ "$site_name" =~ -stg$ ]]; then
            environment="staging"
        elif [[ "$site_name" =~ _prod$ ]]; then
            environment="production"
        elif [[ "$site_name" =~ _dev$ ]]; then
            environment="development"
        fi

        # Get installed modules from install_modules if any
        local installed_modules=""
        if [ -n "$install_modules" ]; then
            installed_modules="$install_modules"
        fi

        # Complete the stub entry (adds environment, purpose, marks install_step=-1)
        if yaml_complete_site_stub "$site_name" "$environment" "$purpose" "$PROJECT_ROOT/cnwp.yml" 2>/dev/null; then
            print_status "OK" "Site registered in cnwp.yml (purpose: $purpose)"

            # Add installed modules if any
            if [ -n "$installed_modules" ] && command -v yaml_add_site_modules &> /dev/null; then
                yaml_add_site_modules "$site_name" "$installed_modules" "$PROJECT_ROOT/cnwp.yml" 2>/dev/null
            fi

            # Update site with selected options
            update_site_options "$site_name" "$PROJECT_ROOT/cnwp.yml"
        else
            # Stub didn't exist (legacy install?) - try full yaml_add_site
            if command -v yaml_add_site &> /dev/null; then
                if yaml_add_site "$site_name" "$site_dir" "$recipe" "$environment" "$purpose" "$PROJECT_ROOT/cnwp.yml" 2>/dev/null; then
                    print_status "OK" "Site registered in cnwp.yml (purpose: $purpose)"
                fi
            fi

            # Still try to update options if site exists
            if yaml_site_exists "$site_name" "$PROJECT_ROOT/cnwp.yml" 2>/dev/null; then
                update_site_options "$site_name" "$PROJECT_ROOT/cnwp.yml"
            fi
        fi
    elif command -v yaml_add_site &> /dev/null; then
        # Fallback for when yaml_complete_site_stub isn't available
        print_info "Registering site in cnwp.yml..."

        local site_dir=$(pwd)
        local site_name=$(basename "$site_dir")
        local environment="development"
        if [[ "$site_name" =~ -stg$ ]]; then
            environment="staging"
        elif [[ "$site_name" =~ _prod$ ]]; then
            environment="production"
        fi

        if yaml_add_site "$site_name" "$site_dir" "$recipe" "$environment" "$purpose" "$PROJECT_ROOT/cnwp.yml" 2>/dev/null; then
            print_status "OK" "Site registered in cnwp.yml (purpose: $purpose)"
            update_site_options "$site_name" "$PROJECT_ROOT/cnwp.yml"
        fi
    fi

    # Pre-register DNS for live site (if shared server is configured)
    pre_register_live_dns "$site_name"

    # Show manual steps guide for selected options
    show_installation_guide "$site_name" "$environment"

    # Mark installation as complete
    if command -v mark_install_complete &>/dev/null; then
        mark_install_complete "$site_name" "$config_file"
    fi

    return 0
}

# Alias for backward compatibility
install_opensocial() {
    install_drupal "$@"
}
