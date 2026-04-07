#!/bin/bash

################################################################################
# NWP Frontend Tooling Library
#
# Provides unified frontend build tool management supporting multiple tools:
# - Gulp (OpenSocial, legacy Drupal)
# - Grunt (Vortex, Drupal community standard)
# - Webpack (Varbase, modern Drupal)
# - Vite (greenfield projects)
#
# Detection Priority: Site config → Auto-detect → Recipe default → Global default
################################################################################

# Get the directory where this script is located
FRONTEND_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_PROJECT_ROOT="$(cd "$FRONTEND_LIB_DIR/.." && pwd)"

# Source required libraries
if [ -f "$FRONTEND_LIB_DIR/ui.sh" ]; then
    source "$FRONTEND_LIB_DIR/ui.sh"
fi

################################################################################
# Theme Directory Detection
################################################################################

# Find the active custom theme directory for a site
# Arguments:
#   $1 - Site name or site directory path
# Returns:
#   Path to the theme directory, or empty if not found
find_theme_dir() {
    local site="$1"
    local site_dir=""

    # Handle both sitename and full path
    if [ -d "$site" ]; then
        site_dir="$site"
    elif [ -d "$FRONTEND_PROJECT_ROOT/sites/$site" ]; then
        site_dir="$FRONTEND_PROJECT_ROOT/sites/$site"
    else
        return 1
    fi

    # Common theme locations in order of preference
    local theme_paths=(
        # OpenSocial themes
        "$site_dir/html/themes/custom"
        "$site_dir/html/profiles/contrib/social/themes/socialblue"
        "$site_dir/html/profiles/contrib/social/themes/socialbase"
        # Standard Drupal
        "$site_dir/web/themes/custom"
        "$site_dir/html/web/themes/custom"
        # Varbase
        "$site_dir/docroot/themes/custom"
        # Legacy
        "$site_dir/themes/custom"
    )

    for path in "${theme_paths[@]}"; do
        if [ -d "$path" ]; then
            # Return first custom theme with package.json, or just the directory
            local first_theme=$(find "$path" -maxdepth 2 -name "package.json" -type f 2>/dev/null | head -1)
            if [ -n "$first_theme" ]; then
                dirname "$first_theme"
                return 0
            elif [ -d "$path" ] && [ "$(ls -A "$path" 2>/dev/null)" ]; then
                # Return first subdirectory as theme
                local first_dir=$(find "$path" -maxdepth 1 -type d ! -path "$path" 2>/dev/null | head -1)
                [ -n "$first_dir" ] && echo "$first_dir" && return 0
            fi
        fi
    done

    # Fallback: check for socialbase/socialblue directly
    for theme in socialblue socialbase; do
        local found=$(find "$site_dir" -type d -name "$theme" 2>/dev/null | head -1)
        [ -n "$found" ] && echo "$found" && return 0
    done

    return 1
}

# List all theme directories for a site
# Arguments:
#   $1 - Site name or site directory path
list_theme_dirs() {
    local site="$1"
    local site_dir=""

    if [ -d "$site" ]; then
        site_dir="$site"
    elif [ -d "$FRONTEND_PROJECT_ROOT/sites/$site" ]; then
        site_dir="$FRONTEND_PROJECT_ROOT/sites/$site"
    else
        return 1
    fi

    # Find all directories with package.json (potential themes)
    find "$site_dir" -name "package.json" -type f 2>/dev/null | while read pkg; do
        local dir=$(dirname "$pkg")
        # Exclude node_modules
        if [[ "$dir" != *"node_modules"* ]]; then
            echo "$dir"
        fi
    done
}

################################################################################
# Frontend Tool Detection
################################################################################

# Detect the frontend build tool from project files
# Arguments:
#   $1 - Theme directory path
# Returns:
#   Tool name: gulp, grunt, webpack, vite, or none
detect_frontend_tool() {
    local theme_dir="$1"

    [ ! -d "$theme_dir" ] && echo "none" && return

    # Check for specific config files (most reliable)
    [ -f "$theme_dir/gulpfile.js" ] && echo "gulp" && return
    [ -f "$theme_dir/gulpfile.babel.js" ] && echo "gulp" && return
    [ -f "$theme_dir/Gruntfile.js" ] && echo "grunt" && return
    [ -f "$theme_dir/webpack.config.js" ] && echo "webpack" && return
    [ -f "$theme_dir/vite.config.js" ] && echo "vite" && return
    [ -f "$theme_dir/vite.config.ts" ] && echo "vite" && return

    # Check package.json for clues
    if [ -f "$theme_dir/package.json" ]; then
        local pkg="$theme_dir/package.json"

        # Check devDependencies and dependencies
        if grep -qE '"gulp":|"gulp-' "$pkg" 2>/dev/null; then
            echo "gulp" && return
        elif grep -qE '"grunt":|"grunt-' "$pkg" 2>/dev/null; then
            echo "grunt" && return
        elif grep -qE '"webpack":|"webpack-' "$pkg" 2>/dev/null; then
            echo "webpack" && return
        elif grep -qE '"vite"' "$pkg" 2>/dev/null; then
            echo "vite" && return
        fi

        # Check scripts section
        if grep -q '"gulp' "$pkg" 2>/dev/null; then
            echo "gulp" && return
        elif grep -q '"grunt' "$pkg" 2>/dev/null; then
            echo "grunt" && return
        elif grep -q '"webpack' "$pkg" 2>/dev/null; then
            echo "webpack" && return
        elif grep -q '"vite' "$pkg" 2>/dev/null; then
            echo "vite" && return
        fi
    fi

    echo "none"
}

# Detect the package manager from project files
# Arguments:
#   $1 - Theme directory path
# Returns:
#   Package manager: yarn, npm, or pnpm
detect_package_manager() {
    local theme_dir="$1"

    [ ! -d "$theme_dir" ] && echo "npm" && return

    # Check for lock files (most reliable)
    [ -f "$theme_dir/yarn.lock" ] && echo "yarn" && return
    [ -f "$theme_dir/pnpm-lock.yaml" ] && echo "pnpm" && return
    [ -f "$theme_dir/package-lock.json" ] && echo "npm" && return

    # Check for .yarnrc or similar
    [ -f "$theme_dir/.yarnrc" ] && echo "yarn" && return
    [ -f "$theme_dir/.yarnrc.yml" ] && echo "yarn" && return
    [ -f "$theme_dir/.npmrc" ] && echo "npm" && return

    # Check package.json for packageManager field
    if [ -f "$theme_dir/package.json" ]; then
        local pm=$(grep -o '"packageManager":\s*"[^"]*"' "$theme_dir/package.json" 2>/dev/null | cut -d'"' -f4)
        if [[ "$pm" == yarn* ]]; then
            echo "yarn" && return
        elif [[ "$pm" == pnpm* ]]; then
            echo "pnpm" && return
        elif [[ "$pm" == npm* ]]; then
            echo "npm" && return
        fi
    fi

    # Default to npm
    echo "npm"
}

################################################################################
# Configuration Retrieval
################################################################################

# Get frontend configuration for a site (hybrid approach)
# Priority: Site config → Auto-detect → Recipe default → Global default
# Arguments:
#   $1 - Site name
#   $2 - Config key (build_tool, package_manager, node_version, watch_command, build_command)
# Returns:
#   Configuration value
get_frontend_config() {
    local sitename="$1"
    local config_key="$2"
    local config_file="$FRONTEND_PROJECT_ROOT/nwp.yml"

    # 1. Check site-level override in nwp.yml
    local site_value=$(awk -v site="$sitename" -v key="$config_key" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
        in_site && /^    frontend:/ { in_frontend = 1; next }
        in_frontend && /^    [a-zA-Z]/ && !/^      / { in_frontend = 0 }
        in_frontend && $0 ~ "^      " key ":" {
            sub("^      " key ": *", "")
            gsub(/["'"'"']/, "")
            print
            exit
        }
    ' "$config_file" 2>/dev/null)

    [ -n "$site_value" ] && echo "$site_value" && return

    # 2. Auto-detect from files (for build_tool and package_manager)
    if [ "$config_key" = "build_tool" ] || [ "$config_key" = "package_manager" ]; then
        local theme_dir=$(find_theme_dir "$sitename")
        if [ -n "$theme_dir" ]; then
            if [ "$config_key" = "build_tool" ]; then
                local detected=$(detect_frontend_tool "$theme_dir")
                [ "$detected" != "none" ] && echo "$detected" && return
            else
                local detected=$(detect_package_manager "$theme_dir")
                echo "$detected" && return
            fi
        fi
    fi

    # 3. Recipe default
    local recipe=$(awk -v site="$sitename" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { exit }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { exit }
        in_site && /^    recipe:/ {
            sub("^    recipe: *", "")
            gsub(/["'"'"']/, "")
            print
            exit
        }
    ' "$config_file" 2>/dev/null)

    if [ -n "$recipe" ]; then
        local recipe_file="$FRONTEND_PROJECT_ROOT/recipes/$recipe/recipe.yml"
        if [ -f "$recipe_file" ]; then
            local recipe_value=$(awk -v key="$config_key" '
                /^frontend:/ { in_frontend = 1; next }
                in_frontend && /^[a-zA-Z]/ && !/^  / { in_frontend = 0 }
                in_frontend && $0 ~ "^  " key ":" {
                    sub("^  " key ": *", "")
                    gsub(/["'"'"']/, "")
                    print
                    exit
                }
            ' "$recipe_file" 2>/dev/null)
            [ -n "$recipe_value" ] && echo "$recipe_value" && return
        fi
    fi

    # 4. Global defaults
    case "$config_key" in
        build_tool)      echo "gulp" ;;
        package_manager) echo "npm" ;;
        node_version)    echo "20" ;;
        watch_command)   echo "" ;;  # Determined by build tool
        build_command)   echo "" ;;  # Determined by build tool
        *)               echo "" ;;
    esac
}

# Get the watch command for a build tool
# Arguments:
#   $1 - Build tool name
#   $2 - Theme directory (optional, to check package.json scripts)
get_watch_command() {
    local tool="$1"
    local theme_dir="$2"

    # Check package.json scripts first
    if [ -n "$theme_dir" ] && [ -f "$theme_dir/package.json" ]; then
        # Look for common watch script names
        for script in "watch" "dev" "start" "serve"; do
            if grep -q "\"$script\":" "$theme_dir/package.json" 2>/dev/null; then
                local pm=$(detect_package_manager "$theme_dir")
                echo "$pm run $script"
                return
            fi
        done
    fi

    # Default commands by tool
    case "$tool" in
        gulp)    echo "gulp watch" ;;
        grunt)   echo "grunt watch" ;;
        webpack) echo "npm run watch" ;;
        vite)    echo "npm run dev" ;;
        *)       echo "" ;;
    esac
}

# Get the build command for a build tool
# Arguments:
#   $1 - Build tool name
#   $2 - Theme directory (optional, to check package.json scripts)
get_build_command() {
    local tool="$1"
    local theme_dir="$2"

    # Check package.json scripts first
    if [ -n "$theme_dir" ] && [ -f "$theme_dir/package.json" ]; then
        for script in "build" "production" "prod" "dist"; do
            if grep -q "\"$script\":" "$theme_dir/package.json" 2>/dev/null; then
                local pm=$(detect_package_manager "$theme_dir")
                echo "$pm run $script"
                return
            fi
        done
    fi

    # Default commands by tool
    case "$tool" in
        gulp)    echo "gulp build" ;;
        grunt)   echo "grunt" ;;
        webpack) echo "npm run build" ;;
        vite)    echo "npm run build" ;;
        *)       echo "" ;;
    esac
}

################################################################################
# DDEV Integration
################################################################################

# Get the DDEV URL for a site
# Arguments:
#   $1 - Site name
get_ddev_url() {
    local sitename="$1"
    local site_dir="$FRONTEND_PROJECT_ROOT/sites/$sitename"

    if [ -d "$site_dir" ]; then
        # Try to get from DDEV
        local url=$(cd "$site_dir" && ddev describe -j 2>/dev/null | grep -o '"primary_url":"[^"]*"' | cut -d'"' -f4)
        [ -n "$url" ] && echo "$url" && return
    fi

    # Fallback to standard DDEV URL
    echo "https://${sitename}.ddev.site"
}

# Check if DDEV is running for a site
# Arguments:
#   $1 - Site name
is_ddev_running() {
    local sitename="$1"
    local site_dir="$FRONTEND_PROJECT_ROOT/sites/$sitename"

    [ ! -d "$site_dir" ] && return 1

    cd "$site_dir" && ddev describe -j 2>/dev/null | grep -q '"status":"running"'
}

################################################################################
# Node.js Version Management
################################################################################

# Check if the required Node.js version is available
# Arguments:
#   $1 - Required version (e.g., "20" or "20.11.0")
check_node_version() {
    local required="$1"

    if ! command -v node &>/dev/null; then
        return 1
    fi

    local current=$(node -v | sed 's/^v//')
    local current_major=$(echo "$current" | cut -d. -f1)
    local required_major=$(echo "$required" | cut -d. -f1)

    [ "$current_major" -ge "$required_major" ]
}

# Get Node.js version from theme directory
# Arguments:
#   $1 - Theme directory
get_theme_node_version() {
    local theme_dir="$1"

    # Check .nvmrc
    if [ -f "$theme_dir/.nvmrc" ]; then
        cat "$theme_dir/.nvmrc" | tr -d 'v'
        return
    fi

    # Check .node-version
    if [ -f "$theme_dir/.node-version" ]; then
        cat "$theme_dir/.node-version" | tr -d 'v'
        return
    fi

    # Check package.json engines
    if [ -f "$theme_dir/package.json" ]; then
        local engines=$(grep -A1 '"engines"' "$theme_dir/package.json" 2>/dev/null | grep '"node"' | grep -oE '[0-9]+' | head -1)
        [ -n "$engines" ] && echo "$engines" && return
    fi

    # Default
    echo "20"
}

################################################################################
# Installation Helpers
################################################################################

# Install Node.js dependencies for a theme
# Arguments:
#   $1 - Theme directory
#   $2 - Package manager (optional, auto-detected)
install_theme_deps() {
    local theme_dir="$1"
    local pm="${2:-$(detect_package_manager "$theme_dir")}"

    [ ! -d "$theme_dir" ] && return 1
    [ ! -f "$theme_dir/package.json" ] && return 1

    cd "$theme_dir" || return 1

    case "$pm" in
        yarn)
            if [ -f "yarn.lock" ]; then
                yarn install
            else
                yarn
            fi
            ;;
        pnpm)
            pnpm install
            ;;
        npm|*)
            npm install
            ;;
    esac
}

# Install global CLI tools if missing
# Arguments:
#   $1 - Build tool name
install_global_tools() {
    local tool="$1"

    case "$tool" in
        gulp)
            if ! command -v gulp &>/dev/null; then
                print_status "INFO" "Installing gulp-cli globally..."
                npm install -g gulp-cli
            fi
            ;;
        grunt)
            if ! command -v grunt &>/dev/null; then
                print_status "INFO" "Installing grunt-cli globally..."
                npm install -g grunt-cli
            fi
            ;;
        webpack)
            # Webpack typically runs via npx or npm scripts, no global install needed
            ;;
        vite)
            # Vite typically runs via npx or npm scripts, no global install needed
            ;;
    esac
}

################################################################################
# Export Functions
################################################################################

export -f find_theme_dir
export -f list_theme_dirs
export -f detect_frontend_tool
export -f detect_package_manager
export -f get_frontend_config
export -f get_watch_command
export -f get_build_command
export -f get_ddev_url
export -f is_ddev_running
export -f check_node_version
export -f get_theme_node_version
export -f install_theme_deps
export -f install_global_tools
