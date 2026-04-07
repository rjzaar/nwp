#!/bin/bash

################################################################################
# NWP Grunt Frontend Support
#
# Grunt-specific commands for Vortex and standard Drupal themes.
################################################################################

# Get the directory where this script is located
GRUNT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRUNT_PROJECT_ROOT="$(cd "$GRUNT_LIB_DIR/../.." && pwd)"

# Source parent library if not already loaded
if ! declare -f detect_frontend_tool &>/dev/null; then
    source "$GRUNT_LIB_DIR/../frontend.sh"
fi

################################################################################
# Grunt Commands
################################################################################

# Run grunt watch (development mode)
# Arguments:
#   $1 - Site name
#   $2 - Theme directory (optional, auto-detected)
grunt_watch() {
    local sitename="$1"
    local theme_dir="${2:-$(find_theme_dir "$sitename")}"

    if [ -z "$theme_dir" ] || [ ! -d "$theme_dir" ]; then
        print_error "Theme directory not found for site: $sitename"
        return 1
    fi

    if [ ! -f "$theme_dir/Gruntfile.js" ]; then
        print_error "No Gruntfile.js found in: $theme_dir"
        return 1
    fi

    # Check for node_modules
    if [ ! -d "$theme_dir/node_modules" ]; then
        print_status "INFO" "Installing dependencies..."
        install_theme_deps "$theme_dir"
    fi

    # Ensure grunt-cli is available
    install_global_tools "grunt"

    # Determine watch task
    local watch_task="watch"

    # Check package.json for npm script
    if [ -f "$theme_dir/package.json" ]; then
        if grep -q '"watch-dev"' "$theme_dir/package.json" 2>/dev/null; then
            local pm=$(detect_package_manager "$theme_dir")
            print_status "INFO" "Running $pm run watch-dev..."
            cd "$theme_dir" && $pm run watch-dev
            return $?
        elif grep -q '"watch"' "$theme_dir/package.json" 2>/dev/null; then
            local pm=$(detect_package_manager "$theme_dir")
            print_status "INFO" "Running $pm run watch..."
            cd "$theme_dir" && $pm run watch
            return $?
        fi
    fi

    # Fall back to direct grunt command
    print_status "INFO" "Running grunt watch..."
    print_info "Theme: $theme_dir"
    echo ""

    cd "$theme_dir" && grunt watch
}

# Run grunt build (production)
# Arguments:
#   $1 - Site name
#   $2 - Theme directory (optional, auto-detected)
grunt_build() {
    local sitename="$1"
    local theme_dir="${2:-$(find_theme_dir "$sitename")}"

    if [ -z "$theme_dir" ] || [ ! -d "$theme_dir" ]; then
        print_error "Theme directory not found for site: $sitename"
        return 1
    fi

    if [ ! -f "$theme_dir/Gruntfile.js" ]; then
        print_error "No Gruntfile.js found in: $theme_dir"
        return 1
    fi

    # Check for node_modules
    if [ ! -d "$theme_dir/node_modules" ]; then
        print_status "INFO" "Installing dependencies..."
        install_theme_deps "$theme_dir"
    fi

    # Ensure grunt-cli is available
    install_global_tools "grunt"

    # Check package.json for npm script
    if [ -f "$theme_dir/package.json" ]; then
        if grep -q '"build"' "$theme_dir/package.json" 2>/dev/null; then
            local pm=$(detect_package_manager "$theme_dir")
            print_status "INFO" "Running $pm run build..."
            cd "$theme_dir" && $pm run build
            return $?
        fi
    fi

    # Fall back to direct grunt command (default task)
    print_status "INFO" "Running grunt (production build)..."
    cd "$theme_dir" && grunt
}

# Run grunt development build
# Arguments:
#   $1 - Site name
#   $2 - Theme directory (optional, auto-detected)
grunt_dev() {
    local sitename="$1"
    local theme_dir="${2:-$(find_theme_dir "$sitename")}"

    if [ -z "$theme_dir" ] || [ ! -d "$theme_dir" ]; then
        print_error "Theme directory not found for site: $sitename"
        return 1
    fi

    # Check for node_modules
    if [ ! -d "$theme_dir/node_modules" ]; then
        print_status "INFO" "Installing dependencies..."
        install_theme_deps "$theme_dir"
    fi

    install_global_tools "grunt"

    # Check package.json for npm script
    if [ -f "$theme_dir/package.json" ]; then
        if grep -q '"build-dev"' "$theme_dir/package.json" 2>/dev/null; then
            local pm=$(detect_package_manager "$theme_dir")
            print_status "INFO" "Running $pm run build-dev..."
            cd "$theme_dir" && $pm run build-dev
            return $?
        fi
    fi

    # Fall back to grunt dev task
    print_status "INFO" "Running grunt dev..."
    cd "$theme_dir" && grunt dev
}

# Run grunt lint
# Arguments:
#   $1 - Site name
#   $2 - Theme directory (optional, auto-detected)
grunt_lint() {
    local sitename="$1"
    local theme_dir="${2:-$(find_theme_dir "$sitename")}"

    if [ -z "$theme_dir" ] || [ ! -d "$theme_dir" ]; then
        print_error "Theme directory not found for site: $sitename"
        return 1
    fi

    # Check for node_modules
    if [ ! -d "$theme_dir/node_modules" ]; then
        print_status "INFO" "Installing dependencies..."
        install_theme_deps "$theme_dir"
    fi

    install_global_tools "grunt"

    # Check package.json for npm script
    if [ -f "$theme_dir/package.json" ]; then
        if grep -q '"lint"' "$theme_dir/package.json" 2>/dev/null; then
            local pm=$(detect_package_manager "$theme_dir")
            print_status "INFO" "Running $pm run lint..."
            cd "$theme_dir" && $pm run lint
            return $?
        fi
    fi

    # Fall back to grunt lint task
    print_status "INFO" "Running grunt lint..."
    cd "$theme_dir" && grunt lint
}

# Run grunt with a specific task
# Arguments:
#   $1 - Site name
#   $2 - Task name
#   $3 - Theme directory (optional, auto-detected)
grunt_task() {
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

    install_global_tools "grunt"

    print_status "INFO" "Running grunt $task..."
    cd "$theme_dir" && grunt "$task"
}

################################################################################
# Export Functions
################################################################################

export -f grunt_watch
export -f grunt_build
export -f grunt_dev
export -f grunt_lint
export -f grunt_task
