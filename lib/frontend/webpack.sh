#!/bin/bash

################################################################################
# NWP Webpack Frontend Support
#
# Webpack-specific commands for Varbase and modern Drupal themes.
################################################################################

# Get the directory where this script is located
WEBPACK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBPACK_PROJECT_ROOT="$(cd "$WEBPACK_LIB_DIR/../.." && pwd)"

# Source parent library if not already loaded
if ! declare -f detect_frontend_tool &>/dev/null; then
    source "$WEBPACK_LIB_DIR/../frontend.sh"
fi

################################################################################
# Webpack Commands
################################################################################

# Run webpack watch (development mode with hot reload)
# Arguments:
#   $1 - Site name
#   $2 - Theme directory (optional, auto-detected)
webpack_watch() {
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

    local pm=$(detect_package_manager "$theme_dir")

    # Check package.json for available scripts
    if [ -f "$theme_dir/package.json" ]; then
        # Prefer 'watch' or 'dev' scripts
        for script in "watch" "dev" "start" "serve"; do
            if grep -q "\"$script\":" "$theme_dir/package.json" 2>/dev/null; then
                print_status "INFO" "Running $pm run $script..."
                print_info "Theme: $theme_dir"
                echo ""
                cd "$theme_dir" && $pm run "$script"
                return $?
            fi
        done
    fi

    # Fall back to npx webpack watch
    print_status "INFO" "Running npx webpack --watch..."
    cd "$theme_dir" && npx webpack --watch --mode development
}

# Run webpack build (production)
# Arguments:
#   $1 - Site name
#   $2 - Theme directory (optional, auto-detected)
webpack_build() {
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

    local pm=$(detect_package_manager "$theme_dir")

    # Check package.json for build script
    if [ -f "$theme_dir/package.json" ]; then
        for script in "build" "production" "prod" "dist"; do
            if grep -q "\"$script\":" "$theme_dir/package.json" 2>/dev/null; then
                print_status "INFO" "Running $pm run $script..."
                cd "$theme_dir" && $pm run "$script"
                return $?
            fi
        done
    fi

    # Fall back to npx webpack
    print_status "INFO" "Running npx webpack (production)..."
    cd "$theme_dir" && npx webpack --mode production
}

# Run webpack development build (one-time, not watching)
# Arguments:
#   $1 - Site name
#   $2 - Theme directory (optional, auto-detected)
webpack_dev() {
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

    local pm=$(detect_package_manager "$theme_dir")

    # Check package.json for dev build script
    if [ -f "$theme_dir/package.json" ]; then
        if grep -q '"build-dev"' "$theme_dir/package.json" 2>/dev/null; then
            print_status "INFO" "Running $pm run build-dev..."
            cd "$theme_dir" && $pm run build-dev
            return $?
        fi
    fi

    # Fall back to npx webpack in development mode
    print_status "INFO" "Running npx webpack (development)..."
    cd "$theme_dir" && npx webpack --mode development
}

# Run linting via npm scripts
# Arguments:
#   $1 - Site name
#   $2 - Theme directory (optional, auto-detected)
webpack_lint() {
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

    local pm=$(detect_package_manager "$theme_dir")
    local ran_lint=false

    # Run all available lint scripts
    if [ -f "$theme_dir/package.json" ]; then
        for script in "lint" "lint:js" "lint:css" "lint:scss"; do
            if grep -q "\"$script\":" "$theme_dir/package.json" 2>/dev/null; then
                print_status "INFO" "Running $pm run $script..."
                cd "$theme_dir" && $pm run "$script"
                ran_lint=true
            fi
        done
    fi

    if [ "$ran_lint" = false ]; then
        print_warning "No lint scripts found in package.json"
        return 1
    fi
}

################################################################################
# Export Functions
################################################################################

export -f webpack_watch
export -f webpack_build
export -f webpack_dev
export -f webpack_lint
