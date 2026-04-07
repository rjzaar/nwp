#!/bin/bash

################################################################################
# NWP Vite Frontend Support
#
# Vite-specific commands for modern/greenfield Drupal themes.
################################################################################

# Get the directory where this script is located
VITE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VITE_PROJECT_ROOT="$(cd "$VITE_LIB_DIR/../.." && pwd)"

# Source parent library if not already loaded
if ! declare -f detect_frontend_tool &>/dev/null; then
    source "$VITE_LIB_DIR/../frontend.sh"
fi

################################################################################
# Vite Commands
################################################################################

# Run vite dev server (development mode with HMR)
# Arguments:
#   $1 - Site name
#   $2 - Theme directory (optional, auto-detected)
vite_watch() {
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
        for script in "dev" "serve" "start" "watch"; do
            if grep -q "\"$script\":" "$theme_dir/package.json" 2>/dev/null; then
                print_status "INFO" "Running $pm run $script..."
                print_info "Theme: $theme_dir"
                echo ""
                cd "$theme_dir" && $pm run "$script"
                return $?
            fi
        done
    fi

    # Fall back to npx vite
    print_status "INFO" "Running npx vite..."
    cd "$theme_dir" && npx vite
}

# Run vite build (production)
# Arguments:
#   $1 - Site name
#   $2 - Theme directory (optional, auto-detected)
vite_build() {
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
        if grep -q '"build"' "$theme_dir/package.json" 2>/dev/null; then
            print_status "INFO" "Running $pm run build..."
            cd "$theme_dir" && $pm run build
            return $?
        fi
    fi

    # Fall back to npx vite build
    print_status "INFO" "Running npx vite build..."
    cd "$theme_dir" && npx vite build
}

# Run vite preview (preview production build)
# Arguments:
#   $1 - Site name
#   $2 - Theme directory (optional, auto-detected)
vite_preview() {
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

    # Check package.json for preview script
    if [ -f "$theme_dir/package.json" ]; then
        if grep -q '"preview"' "$theme_dir/package.json" 2>/dev/null; then
            print_status "INFO" "Running $pm run preview..."
            cd "$theme_dir" && $pm run preview
            return $?
        fi
    fi

    # Fall back to npx vite preview
    print_status "INFO" "Running npx vite preview..."
    cd "$theme_dir" && npx vite preview
}

# Run linting via npm scripts
# Arguments:
#   $1 - Site name
#   $2 - Theme directory (optional, auto-detected)
vite_lint() {
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
        for script in "lint" "lint:js" "lint:css" "lint:scss" "typecheck"; do
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

export -f vite_watch
export -f vite_build
export -f vite_preview
export -f vite_lint
