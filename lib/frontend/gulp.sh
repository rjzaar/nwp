#!/bin/bash

################################################################################
# NWP Gulp Frontend Support
#
# Gulp-specific commands for OpenSocial and legacy Drupal themes.
# Handles browser-sync integration with DDEV URLs.
################################################################################

# Get the directory where this script is located
GULP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GULP_PROJECT_ROOT="$(cd "$GULP_LIB_DIR/../.." && pwd)"

# Source parent library if not already loaded
if ! declare -f detect_frontend_tool &>/dev/null; then
    source "$GULP_LIB_DIR/../frontend.sh"
fi

################################################################################
# Gulp Configuration
################################################################################

# Update gulpfile.js with the correct DDEV URL for browser-sync
# Arguments:
#   $1 - Theme directory
#   $2 - DDEV URL
configure_browsersync_url() {
    local theme_dir="$1"
    local ddev_url="$2"
    local gulpfile="$theme_dir/gulpfile.js"

    [ ! -f "$gulpfile" ] && return 1

    # Backup original if not already backed up
    [ ! -f "${gulpfile}.original" ] && cp "$gulpfile" "${gulpfile}.original"

    # Common patterns for drupalURL in OpenSocial themes
    # Pattern 1: options.drupalURL = 'http://social.local'
    if grep -q "options.drupalURL" "$gulpfile"; then
        sed -i "s|options.drupalURL = '[^']*'|options.drupalURL = '$ddev_url'|g" "$gulpfile"
        return 0
    fi

    # Pattern 2: drupalURL: 'http://social.local'
    if grep -q "drupalURL:" "$gulpfile"; then
        sed -i "s|drupalURL: '[^']*'|drupalURL: '$ddev_url'|g" "$gulpfile"
        return 0
    fi

    # Pattern 3: proxy: 'http://social.local'
    if grep -q "proxy:" "$gulpfile"; then
        sed -i "s|proxy: '[^']*'|proxy: '$ddev_url'|g" "$gulpfile"
        return 0
    fi

    return 1
}

# Restore original gulpfile.js
# Arguments:
#   $1 - Theme directory
restore_gulpfile() {
    local theme_dir="$1"
    local gulpfile="$theme_dir/gulpfile.js"

    if [ -f "${gulpfile}.original" ]; then
        mv "${gulpfile}.original" "$gulpfile"
        return 0
    fi
    return 1
}

################################################################################
# Gulp Commands
################################################################################

# Run gulp watch with browser-sync configured for DDEV
# Arguments:
#   $1 - Site name
#   $2 - Theme directory (optional, auto-detected)
#   $3 - DDEV URL (optional, auto-detected)
gulp_watch() {
    local sitename="$1"
    local theme_dir="${2:-$(find_theme_dir "$sitename")}"
    local ddev_url="${3:-$(get_ddev_url "$sitename")}"

    if [ -z "$theme_dir" ] || [ ! -d "$theme_dir" ]; then
        print_error "Theme directory not found for site: $sitename"
        return 1
    fi

    if [ ! -f "$theme_dir/gulpfile.js" ]; then
        print_error "No gulpfile.js found in: $theme_dir"
        return 1
    fi

    # Check if DDEV is running
    if ! is_ddev_running "$sitename"; then
        print_warning "DDEV is not running for $sitename"
        print_info "Starting DDEV..."
        (cd "$GULP_PROJECT_ROOT/sites/$sitename" && ddev start)
    fi

    # Configure browser-sync URL
    print_status "INFO" "Configuring browser-sync for: $ddev_url"
    configure_browsersync_url "$theme_dir" "$ddev_url"

    # Check for node_modules
    if [ ! -d "$theme_dir/node_modules" ]; then
        print_status "INFO" "Installing dependencies..."
        install_theme_deps "$theme_dir"
    fi

    # Ensure gulp-cli is available
    install_global_tools "gulp"

    # Run gulp watch
    print_status "INFO" "Starting gulp watch..."
    print_info "Theme: $theme_dir"
    print_info "URL: $ddev_url"
    echo ""

    cd "$theme_dir" && gulp watch
}

# Run gulp build (production)
# Arguments:
#   $1 - Site name
#   $2 - Theme directory (optional, auto-detected)
gulp_build() {
    local sitename="$1"
    local theme_dir="${2:-$(find_theme_dir "$sitename")}"

    if [ -z "$theme_dir" ] || [ ! -d "$theme_dir" ]; then
        print_error "Theme directory not found for site: $sitename"
        return 1
    fi

    if [ ! -f "$theme_dir/gulpfile.js" ]; then
        print_error "No gulpfile.js found in: $theme_dir"
        return 1
    fi

    # Check for node_modules
    if [ ! -d "$theme_dir/node_modules" ]; then
        print_status "INFO" "Installing dependencies..."
        install_theme_deps "$theme_dir"
    fi

    # Ensure gulp-cli is available
    install_global_tools "gulp"

    # Determine build task
    local build_task="build"

    # Check if 'build' task exists, otherwise try 'default' or just 'gulp'
    if ! grep -q "'build'" "$theme_dir/gulpfile.js" 2>/dev/null; then
        if grep -q "'default'" "$theme_dir/gulpfile.js" 2>/dev/null; then
            build_task="default"
        else
            build_task=""
        fi
    fi

    print_status "INFO" "Running gulp build..."
    cd "$theme_dir" && gulp $build_task
}

# Run gulp with a specific task
# Arguments:
#   $1 - Site name
#   $2 - Task name
#   $3 - Theme directory (optional, auto-detected)
gulp_task() {
    local sitename="$1"
    local task="$2"
    local theme_dir="${3:-$(find_theme_dir "$sitename")}"

    if [ -z "$theme_dir" ] || [ ! -d "$theme_dir" ]; then
        print_error "Theme directory not found for site: $sitename"
        return 1
    fi

    # Check for node_modules
    if [ ! -d "$theme_dir/node_modules" ]; then
        print_status "INFO" "Installing dependencies..."
        install_theme_deps "$theme_dir"
    fi

    install_global_tools "gulp"

    print_status "INFO" "Running gulp $task..."
    cd "$theme_dir" && gulp "$task"
}

# List available gulp tasks
# Arguments:
#   $1 - Site name
#   $2 - Theme directory (optional, auto-detected)
gulp_list_tasks() {
    local sitename="$1"
    local theme_dir="${2:-$(find_theme_dir "$sitename")}"

    if [ -z "$theme_dir" ] || [ ! -d "$theme_dir" ]; then
        print_error "Theme directory not found for site: $sitename"
        return 1
    fi

    install_global_tools "gulp"

    cd "$theme_dir" && gulp --tasks
}

################################################################################
# Export Functions
################################################################################

export -f configure_browsersync_url
export -f restore_gulpfile
export -f gulp_watch
export -f gulp_build
export -f gulp_task
export -f gulp_list_tasks
