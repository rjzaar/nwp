#!/bin/bash
set -euo pipefail

################################################################################
# NWP Theme Command
#
# Unified frontend build tool management for Drupal themes.
# Supports Gulp, Grunt, Webpack, and Vite with auto-detection.
#
# Usage: pl theme <subcommand> <sitename> [options]
################################################################################

# Get script directory and project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/frontend.sh"

################################################################################
# Help
################################################################################

show_help() {
    cat << EOF
${BOLD}NWP Theme Command${NC} - Frontend Build Tool Management

${BOLD}USAGE:${NC}
    pl theme <subcommand> <sitename> [options]

${BOLD}SUBCOMMANDS:${NC}
    setup <sitename>        Install Node.js dependencies for theme
    watch <sitename>        Start development mode with live reload
    build <sitename>        Production build (minified, optimized)
    dev <sitename>          Development build (one-time, with source maps)
    lint <sitename>         Run linting (ESLint, Stylelint)
    info <sitename>         Show theme and build tool information
    list <sitename>         List all themes for a site

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -t, --theme <path>      Specify theme directory (overrides auto-detection)
    -d, --debug             Enable debug output

${BOLD}AUTO-DETECTION:${NC}
    The build tool is automatically detected from project files:
    - gulpfile.js         -> Gulp (OpenSocial, legacy Drupal)
    - Gruntfile.js        -> Grunt (Vortex, Drupal standard)
    - webpack.config.js   -> Webpack (Varbase, modern Drupal)
    - vite.config.js      -> Vite (greenfield projects)

${BOLD}CONFIGURATION:${NC}
    Override auto-detection in cnwp.yml:

    sites:
      mysite:
        recipe: os
        frontend:
          build_tool: gulp
          package_manager: yarn
          node_version: "20"

${BOLD}EXAMPLES:${NC}
    pl theme setup avc              Install deps for avc site theme
    pl theme watch avc              Start gulp/webpack watch for avc
    pl theme build avc              Production build
    pl theme lint avc               Run linters
    pl theme info avc               Show detected build tool info
    pl theme watch avc -t /path     Use specific theme directory

${BOLD}SUPPORTED BUILD TOOLS:${NC}
    Gulp     - OpenSocial themes (socialbase, socialblue)
    Grunt    - Vortex/Drupal community standard
    Webpack  - Varbase and modern setups
    Vite     - Latest/fastest option

EOF
}

################################################################################
# Subcommands
################################################################################

# Install dependencies
cmd_setup() {
    local sitename="$1"
    local theme_dir="${THEME_DIR:-$(find_theme_dir "$sitename")}"

    if [ -z "$theme_dir" ]; then
        print_error "No theme directory found for site: $sitename"
        print_info "Use -t <path> to specify the theme directory"
        return 1
    fi

    print_header "Theme Setup: $sitename"

    local tool=$(detect_frontend_tool "$theme_dir")
    local pm=$(detect_package_manager "$theme_dir")
    local node_ver=$(get_theme_node_version "$theme_dir")

    print_status "INFO" "Theme: $theme_dir"
    print_status "INFO" "Build tool: $tool"
    print_status "INFO" "Package manager: $pm"
    print_status "INFO" "Node version: $node_ver"
    echo ""

    # Check Node.js version
    if ! check_node_version "$node_ver"; then
        print_warning "Node.js $node_ver+ required (current: $(node -v 2>/dev/null || echo 'not installed'))"
        print_info "Install with: nvm install $node_ver"
    fi

    # Install global tools if needed
    install_global_tools "$tool"

    # Install dependencies
    print_status "INFO" "Installing dependencies with $pm..."
    if install_theme_deps "$theme_dir" "$pm"; then
        print_status "OK" "Dependencies installed"
    else
        print_status "FAIL" "Failed to install dependencies"
        return 1
    fi
}

# Start watch/development mode
cmd_watch() {
    local sitename="$1"
    local theme_dir="${THEME_DIR:-$(find_theme_dir "$sitename")}"

    if [ -z "$theme_dir" ]; then
        print_error "No theme directory found for site: $sitename"
        return 1
    fi

    local tool=$(detect_frontend_tool "$theme_dir")

    print_header "Theme Watch: $sitename"
    print_status "INFO" "Build tool: $tool"

    case "$tool" in
        gulp)
            source "$PROJECT_ROOT/lib/frontend/gulp.sh"
            gulp_watch "$sitename" "$theme_dir"
            ;;
        grunt)
            source "$PROJECT_ROOT/lib/frontend/grunt.sh"
            grunt_watch "$sitename" "$theme_dir"
            ;;
        webpack)
            source "$PROJECT_ROOT/lib/frontend/webpack.sh"
            webpack_watch "$sitename" "$theme_dir"
            ;;
        vite)
            source "$PROJECT_ROOT/lib/frontend/vite.sh"
            vite_watch "$sitename" "$theme_dir"
            ;;
        none)
            print_error "No build tool detected in: $theme_dir"
            print_info "Ensure gulpfile.js, Gruntfile.js, webpack.config.js, or vite.config.js exists"
            return 1
            ;;
        *)
            print_error "Unknown build tool: $tool"
            return 1
            ;;
    esac
}

# Production build
cmd_build() {
    local sitename="$1"
    local theme_dir="${THEME_DIR:-$(find_theme_dir "$sitename")}"

    if [ -z "$theme_dir" ]; then
        print_error "No theme directory found for site: $sitename"
        return 1
    fi

    local tool=$(detect_frontend_tool "$theme_dir")

    print_header "Theme Build: $sitename"
    print_status "INFO" "Build tool: $tool"

    case "$tool" in
        gulp)
            source "$PROJECT_ROOT/lib/frontend/gulp.sh"
            gulp_build "$sitename" "$theme_dir"
            ;;
        grunt)
            source "$PROJECT_ROOT/lib/frontend/grunt.sh"
            grunt_build "$sitename" "$theme_dir"
            ;;
        webpack)
            source "$PROJECT_ROOT/lib/frontend/webpack.sh"
            webpack_build "$sitename" "$theme_dir"
            ;;
        vite)
            source "$PROJECT_ROOT/lib/frontend/vite.sh"
            vite_build "$sitename" "$theme_dir"
            ;;
        none)
            print_error "No build tool detected in: $theme_dir"
            return 1
            ;;
    esac
}

# Development build (one-time)
cmd_dev() {
    local sitename="$1"
    local theme_dir="${THEME_DIR:-$(find_theme_dir "$sitename")}"

    if [ -z "$theme_dir" ]; then
        print_error "No theme directory found for site: $sitename"
        return 1
    fi

    local tool=$(detect_frontend_tool "$theme_dir")

    print_header "Theme Dev Build: $sitename"
    print_status "INFO" "Build tool: $tool"

    case "$tool" in
        gulp)
            source "$PROJECT_ROOT/lib/frontend/gulp.sh"
            gulp_task "$sitename" "dev" "$theme_dir" 2>/dev/null || gulp_build "$sitename" "$theme_dir"
            ;;
        grunt)
            source "$PROJECT_ROOT/lib/frontend/grunt.sh"
            grunt_dev "$sitename" "$theme_dir"
            ;;
        webpack)
            source "$PROJECT_ROOT/lib/frontend/webpack.sh"
            webpack_dev "$sitename" "$theme_dir"
            ;;
        vite)
            source "$PROJECT_ROOT/lib/frontend/vite.sh"
            vite_build "$sitename" "$theme_dir"
            ;;
        none)
            print_error "No build tool detected in: $theme_dir"
            return 1
            ;;
    esac
}

# Run linting
cmd_lint() {
    local sitename="$1"
    local theme_dir="${THEME_DIR:-$(find_theme_dir "$sitename")}"

    if [ -z "$theme_dir" ]; then
        print_error "No theme directory found for site: $sitename"
        return 1
    fi

    local tool=$(detect_frontend_tool "$theme_dir")

    print_header "Theme Lint: $sitename"

    case "$tool" in
        gulp)
            source "$PROJECT_ROOT/lib/frontend/gulp.sh"
            gulp_task "$sitename" "lint" "$theme_dir" 2>/dev/null || {
                print_warning "No lint task in gulpfile.js"
                # Try npm scripts as fallback
                if [ -f "$theme_dir/package.json" ] && grep -q '"lint"' "$theme_dir/package.json"; then
                    local pm=$(detect_package_manager "$theme_dir")
                    cd "$theme_dir" && $pm run lint
                fi
            }
            ;;
        grunt)
            source "$PROJECT_ROOT/lib/frontend/grunt.sh"
            grunt_lint "$sitename" "$theme_dir"
            ;;
        webpack)
            source "$PROJECT_ROOT/lib/frontend/webpack.sh"
            webpack_lint "$sitename" "$theme_dir"
            ;;
        vite)
            source "$PROJECT_ROOT/lib/frontend/vite.sh"
            vite_lint "$sitename" "$theme_dir"
            ;;
        none)
            # Try npm lint script anyway
            if [ -f "$theme_dir/package.json" ] && grep -q '"lint"' "$theme_dir/package.json"; then
                local pm=$(detect_package_manager "$theme_dir")
                cd "$theme_dir" && $pm run lint
            else
                print_error "No lint configuration found"
                return 1
            fi
            ;;
    esac
}

# Show theme information
cmd_info() {
    local sitename="$1"
    local theme_dir="${THEME_DIR:-$(find_theme_dir "$sitename")}"

    print_header "Theme Info: $sitename"

    if [ -z "$theme_dir" ]; then
        print_status "WARN" "No theme directory found for site: $sitename"
        print_info "Use -t <path> to specify the theme directory"
        echo ""

        # Show all potential theme locations
        print_status "INFO" "Searching for themes..."
        list_theme_dirs "$sitename" 2>/dev/null | while read dir; do
            echo "  - $dir"
        done
        return 1
    fi

    local tool=$(detect_frontend_tool "$theme_dir")
    local pm=$(detect_package_manager "$theme_dir")
    local node_ver=$(get_theme_node_version "$theme_dir")
    local ddev_url=$(get_ddev_url "$sitename")

    echo ""
    echo -e "${BOLD}Theme Directory:${NC}"
    echo "  $theme_dir"
    echo ""

    echo -e "${BOLD}Build Configuration:${NC}"
    printf "  %-20s %s\n" "Build tool:" "$tool"
    printf "  %-20s %s\n" "Package manager:" "$pm"
    printf "  %-20s %s\n" "Node version:" "$node_ver"
    printf "  %-20s %s\n" "DDEV URL:" "$ddev_url"
    echo ""

    # Show config files
    echo -e "${BOLD}Config Files:${NC}"
    [ -f "$theme_dir/gulpfile.js" ] && echo "  - gulpfile.js"
    [ -f "$theme_dir/Gruntfile.js" ] && echo "  - Gruntfile.js"
    [ -f "$theme_dir/webpack.config.js" ] && echo "  - webpack.config.js"
    [ -f "$theme_dir/vite.config.js" ] && echo "  - vite.config.js"
    [ -f "$theme_dir/package.json" ] && echo "  - package.json"
    [ -f "$theme_dir/.eslintrc.json" ] && echo "  - .eslintrc.json"
    [ -f "$theme_dir/.stylelintrc.json" ] && echo "  - .stylelintrc.json"
    [ -f "$theme_dir/.prettierrc" ] && echo "  - .prettierrc"
    echo ""

    # Show npm scripts if available
    if [ -f "$theme_dir/package.json" ]; then
        # Extract script names from package.json scripts section
        local scripts=$(sed -n '/"scripts"/,/^\s*}/p' "$theme_dir/package.json" 2>/dev/null | \
            grep -oE '"[a-z][a-z0-9:-]*"\s*:' | \
            sed 's/"//g; s/://; s/^/  - /' | \
            grep -v "^  - scripts$" | head -10)

        if [ -n "$scripts" ]; then
            echo -e "${BOLD}Available npm Scripts:${NC}"
            echo "$scripts"
            echo ""
        fi
    fi

    # Dependencies status
    if [ -d "$theme_dir/node_modules" ]; then
        local mod_count=$(find "$theme_dir/node_modules" -maxdepth 1 -type d 2>/dev/null | wc -l)
        print_status "OK" "Dependencies installed ($mod_count packages)"
    else
        print_status "WARN" "Dependencies not installed (run: pl theme setup $sitename)"
    fi
}

# List all themes for a site
cmd_list() {
    local sitename="$1"

    print_header "Themes for: $sitename"

    local themes=$(list_theme_dirs "$sitename")

    if [ -z "$themes" ]; then
        print_status "INFO" "No themes with package.json found"
        return 0
    fi

    echo ""
    while read -r theme_dir; do
        local tool=$(detect_frontend_tool "$theme_dir")
        local name=$(basename "$theme_dir")
        printf "  ${BOLD}%s${NC}\n" "$name"
        printf "    Path: %s\n" "$theme_dir"
        printf "    Tool: %s\n" "$tool"
        echo ""
    done <<< "$themes"
}

################################################################################
# Main
################################################################################

main() {
    # Default values
    DEBUG=false
    THEME_DIR=""

    # Parse global options first
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
            -t|--theme)
                THEME_DIR="$2"
                shift 2
                ;;
            -*)
                # Unknown option - might be for subcommand
                break
                ;;
            *)
                break
                ;;
        esac
    done

    # Get subcommand
    local subcommand="${1:-}"
    shift || true

    # Get sitename
    local sitename="${1:-}"
    shift || true

    # Parse remaining options (after subcommand and sitename)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--theme)
                THEME_DIR="$2"
                shift 2
                ;;
            -d|--debug)
                DEBUG=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # Route to subcommand
    case "$subcommand" in
        setup|install)
            [ -z "$sitename" ] && { print_error "Site name required"; exit 1; }
            cmd_setup "$sitename"
            ;;
        watch|w)
            [ -z "$sitename" ] && { print_error "Site name required"; exit 1; }
            cmd_watch "$sitename"
            ;;
        build|b)
            [ -z "$sitename" ] && { print_error "Site name required"; exit 1; }
            cmd_build "$sitename"
            ;;
        dev|d)
            [ -z "$sitename" ] && { print_error "Site name required"; exit 1; }
            cmd_dev "$sitename"
            ;;
        lint|l)
            [ -z "$sitename" ] && { print_error "Site name required"; exit 1; }
            cmd_lint "$sitename"
            ;;
        info|i)
            [ -z "$sitename" ] && { print_error "Site name required"; exit 1; }
            cmd_info "$sitename"
            ;;
        list|ls)
            [ -z "$sitename" ] && { print_error "Site name required"; exit 1; }
            cmd_list "$sitename"
            ;;
        ""|help)
            show_help
            ;;
        *)
            print_error "Unknown subcommand: $subcommand"
            echo ""
            echo "Run 'pl theme --help' for usage information."
            exit 1
            ;;
    esac
}

main "$@"
