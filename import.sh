#!/bin/bash
set -euo pipefail

################################################################################
# NWP Import Script
#
# Imports live Drupal sites from remote Linode servers into local NWP
# development environment using DDEV.
#
# Usage: ./import.sh [options]
#        ./import.sh <sitename> --server=<name> --source=<path> [options]
#
# Interactive Mode (default):
#   ./import.sh                          - Select server from cnwp.yml
#   ./import.sh --server=production      - Use specific server
#   ./import.sh --ssh=root@example.com   - Use custom SSH connection
#
# Non-Interactive Mode:
#   ./import.sh site1 --server=prod --source=/var/www/site1/web
#   ./import.sh --server=prod --all --yes
#
# Options:
#   --server=NAME           Use server from cnwp.yml linode.servers
#   --ssh=USER@HOST         Custom SSH connection string
#   --key=PATH              SSH private key path (default: ~/.ssh/nwp)
#   --source=PATH           Remote webroot path (skip discovery)
#   --all                   Import all discovered sites
#   --dry-run               Analyze only, don't import
#   --yes, -y               Auto-confirm all prompts
#   --sanitize              Enable database sanitization (default)
#   --no-sanitize           Disable database sanitization
#   --stage-file-proxy      Enable stage file proxy (default)
#   --full-files            Download all files instead of stage proxy
#   -s=N, --step=N          Resume from step N
#   --help, -h              Show this help message
#
# Examples:
#   ./import.sh                                    # Interactive TUI
#   ./import.sh --server=production                # Scan production server
#   ./import.sh site1 --server=prod --source=/var/www/site1/web
#   ./import.sh --server=prod --all --yes          # Import all sites
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

# Server scanning functions
source "$SCRIPT_DIR/lib/server-scan.sh"

# Import TUI components
source "$SCRIPT_DIR/lib/import-tui.sh"

# Import core functions
source "$SCRIPT_DIR/lib/import.sh"

################################################################################
# Configuration
################################################################################

CONFIG_FILE="$SCRIPT_DIR/cnwp.yml"

# Default options
OPT_SERVER=""
OPT_SSH=""
OPT_KEY="$HOME/.ssh/nwp"
OPT_SOURCE=""
OPT_SITE_NAME=""
OPT_ALL="n"
OPT_DRY_RUN="n"
OPT_YES="n"
OPT_SANITIZE="y"
OPT_STAGE_FILE_PROXY="y"
OPT_FULL_FILES="n"
OPT_STEP=""
OPT_HELP="n"

################################################################################
# Argument Parsing
################################################################################

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server=*)
                OPT_SERVER="${1#*=}"
                shift
                ;;
            --ssh=*)
                OPT_SSH="${1#*=}"
                shift
                ;;
            --key=*)
                OPT_KEY="${1#*=}"
                OPT_KEY="${OPT_KEY/#\~/$HOME}"
                shift
                ;;
            --source=*)
                OPT_SOURCE="${1#*=}"
                shift
                ;;
            --all)
                OPT_ALL="y"
                shift
                ;;
            --dry-run)
                OPT_DRY_RUN="y"
                shift
                ;;
            --yes|-y)
                OPT_YES="y"
                shift
                ;;
            --sanitize)
                OPT_SANITIZE="y"
                shift
                ;;
            --no-sanitize)
                OPT_SANITIZE="n"
                shift
                ;;
            --stage-file-proxy)
                OPT_STAGE_FILE_PROXY="y"
                OPT_FULL_FILES="n"
                shift
                ;;
            --full-files)
                OPT_FULL_FILES="y"
                OPT_STAGE_FILE_PROXY="n"
                shift
                ;;
            -s=*|--step=*)
                OPT_STEP="${1#*=}"
                shift
                ;;
            --help|-h)
                OPT_HELP="y"
                shift
                ;;
            -*)
                print_error "Unknown option: $1"
                exit 1
                ;;
            *)
                # Positional argument - site name
                if [ -z "$OPT_SITE_NAME" ]; then
                    OPT_SITE_NAME="$1"
                else
                    print_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done
}

show_help() {
    head -50 "$0" | tail -45 | sed 's/^# //' | sed 's/^#//'
    exit 0
}

################################################################################
# Validation
################################################################################

validate_prerequisites() {
    # Check for required commands
    if ! command -v ddev &>/dev/null; then
        print_error "DDEV is required but not installed"
        echo "Install DDEV: https://ddev.readthedocs.io/en/stable/users/install/"
        exit 1
    fi

    if ! command -v rsync &>/dev/null; then
        print_error "rsync is required but not installed"
        exit 1
    fi

    if ! command -v ssh &>/dev/null; then
        print_error "ssh is required but not installed"
        exit 1
    fi

    # Check SSH key exists
    if [ ! -f "$OPT_KEY" ]; then
        print_error "SSH key not found: $OPT_KEY"
        echo "Generate keys with: ./setup-ssh.sh"
        echo "Or specify a different key with: --key=/path/to/key"
        exit 1
    fi

    # Check config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        print_warning "Config file not found: $CONFIG_FILE"
        print_info "Using defaults. Copy example.cnwp.yml to cnwp.yml to configure servers."
    fi
}

################################################################################
# Non-Interactive Mode
################################################################################

run_non_interactive() {
    local ssh_target=""
    local ssh_key="$OPT_KEY"

    # Determine SSH target
    if [ -n "$OPT_SSH" ]; then
        ssh_target="$OPT_SSH"
    elif [ -n "$OPT_SERVER" ]; then
        eval "$(get_server_config "$OPT_SERVER" "$CONFIG_FILE")"
        if [ -z "$SERVER_SSH_HOST" ]; then
            print_error "Server not found in config: $OPT_SERVER"
            exit 1
        fi
        ssh_target="$SERVER_SSH_HOST"
        ssh_key="${SERVER_SSH_KEY:-$OPT_KEY}"
        SELECTED_SERVER_NAME="$OPT_SERVER"
    else
        print_error "No server specified. Use --server=NAME or --ssh=USER@HOST"
        exit 1
    fi

    SELECTED_SSH_HOST="$ssh_target"
    SELECTED_SSH_KEY="$ssh_key"

    # Test SSH connection
    print_info "Connecting to $ssh_target..."
    if ! test_ssh_connection "$ssh_target" "$ssh_key"; then
        print_error "Cannot connect to $ssh_target"
        exit 1
    fi

    # If specific source provided
    if [ -n "$OPT_SOURCE" ] && [ -n "$OPT_SITE_NAME" ]; then
        # Direct import of a single site
        local site_name="$OPT_SITE_NAME"
        local webroot="$OPT_SOURCE"
        local site_dir=$(dirname "$webroot")

        # Set options from command line
        IMPORT_OPTIONS["${site_name}:sanitize"]="$OPT_SANITIZE"
        IMPORT_OPTIONS["${site_name}:stage_file_proxy"]="$OPT_STAGE_FILE_PROXY"
        IMPORT_OPTIONS["${site_name}:full_file_sync"]="$OPT_FULL_FILES"

        # Apply defaults
        for opt in "${!IMPORT_DEFAULTS[@]}"; do
            if [ -z "${IMPORT_OPTIONS["${site_name}:${opt}"]:-}" ]; then
                IMPORT_OPTIONS["${site_name}:${opt}"]="${IMPORT_DEFAULTS[$opt]}"
            fi
        done

        if [ "$OPT_DRY_RUN" = "y" ]; then
            print_header "Dry Run - Analysis"
            print_info "Would import: $site_name"
            print_info "Source: $webroot"
            print_info "Options: sanitize=$OPT_SANITIZE, stage_file_proxy=$OPT_STAGE_FILE_PROXY"
            exit 0
        fi

        # Confirm
        if [ "$OPT_YES" != "y" ]; then
            if ! ask_yes_no "Import $site_name from $webroot?" "y"; then
                echo "Cancelled."
                exit 0
            fi
        fi

        # Import
        if import_site "$site_name" "$ssh_target" "$ssh_key" "$site_dir" "$webroot" ""; then
            print_status "OK" "Import complete: $site_name"
            echo ""
            echo "Next steps:"
            echo "  cd $site_name && ddev launch"
        else
            print_error "Import failed"
            exit 1
        fi
        exit 0
    fi

    # Scan for sites
    print_info "Scanning for Drupal sites..."
    DISCOVERED_SITES=()

    while IFS= read -r site_json; do
        if [ -n "$site_json" ]; then
            DISCOVERED_SITES+=("$site_json")
        fi
    done < <(scan_server_for_sites "$ssh_target" "$ssh_key")

    if [ ${#DISCOVERED_SITES[@]} -eq 0 ]; then
        print_error "No Drupal sites found on $ssh_target"
        exit 1
    fi

    print_status "OK" "Found ${#DISCOVERED_SITES[@]} site(s)"

    # List sites
    for site_json in "${DISCOVERED_SITES[@]}"; do
        eval "$(parse_site_json "$site_json")"
        echo "  - $SITE_NAME ($SITE_VERSION) DB: $SITE_DB_SIZE MB, Files: $SITE_FILES_SIZE"
    done

    if [ "$OPT_DRY_RUN" = "y" ]; then
        echo ""
        print_info "Dry run complete. Use --all --yes to import all sites."
        exit 0
    fi

    # Import all if --all specified
    if [ "$OPT_ALL" = "y" ]; then
        SELECTED_SITES=()
        for ((i = 0; i < ${#DISCOVERED_SITES[@]}; i++)); do
            SELECTED_SITES+=($i)

            eval "$(parse_site_json "${DISCOVERED_SITES[$i]}")"

            # Set options for each site
            IMPORT_OPTIONS["${SITE_NAME}:sanitize"]="$OPT_SANITIZE"
            IMPORT_OPTIONS["${SITE_NAME}:stage_file_proxy"]="$OPT_STAGE_FILE_PROXY"
            IMPORT_OPTIONS["${SITE_NAME}:full_file_sync"]="$OPT_FULL_FILES"

            for opt in "${!IMPORT_DEFAULTS[@]}"; do
                if [ -z "${IMPORT_OPTIONS["${SITE_NAME}:${opt}"]:-}" ]; then
                    IMPORT_OPTIONS["${SITE_NAME}:${opt}"]="${IMPORT_DEFAULTS[$opt]}"
                fi
            done
        done

        if [ "$OPT_YES" != "y" ]; then
            if ! ask_yes_no "Import all ${#SELECTED_SITES[@]} sites?" "y"; then
                echo "Cancelled."
                exit 0
            fi
        fi

        import_selected_sites
        exit 0
    fi

    print_info "Use --all to import all sites, or run without arguments for interactive mode."
    exit 0
}

################################################################################
# Interactive Mode
################################################################################

run_interactive() {
    print_header "NWP Import"

    # Step 1: Select server
    if [ -n "$OPT_SERVER" ]; then
        eval "$(get_server_config "$OPT_SERVER" "$CONFIG_FILE")"
        if [ -z "$SERVER_SSH_HOST" ]; then
            print_error "Server not found: $OPT_SERVER"
            exit 1
        fi
        SELECTED_SERVER_NAME="$OPT_SERVER"
        SELECTED_SSH_HOST="$SERVER_SSH_HOST"
        SELECTED_SSH_KEY="${SERVER_SSH_KEY:-$OPT_KEY}"
    elif [ -n "$OPT_SSH" ]; then
        SELECTED_SERVER_NAME="custom"
        SELECTED_SSH_HOST="$OPT_SSH"
        SELECTED_SSH_KEY="$OPT_KEY"
    else
        if ! select_server "$CONFIG_FILE"; then
            echo "Cancelled."
            exit 0
        fi
    fi

    # Step 2: Test connection
    print_info "Connecting to $SELECTED_SSH_HOST..."
    if ! test_ssh_connection "$SELECTED_SSH_HOST" "$SELECTED_SSH_KEY"; then
        print_error "Cannot connect to $SELECTED_SSH_HOST"
        print_info "Check SSH key and server accessibility"
        exit 1
    fi
    print_status "OK" "Connected"

    # Step 3: Scan for sites
    show_scanning_progress "$SELECTED_SERVER_NAME" "$SELECTED_SSH_HOST"

    DISCOVERED_SITES=()
    DISCOVERED_SITE_NAMES=()

    while IFS= read -r site_json; do
        if [ -n "$site_json" ]; then
            DISCOVERED_SITES+=("$site_json")
            eval "$(parse_site_json "$site_json")"
            DISCOVERED_SITE_NAMES+=("$SITE_NAME")
        fi
    done < <(scan_server_for_sites "$SELECTED_SSH_HOST" "$SELECTED_SSH_KEY")

    if [ ${#DISCOVERED_SITES[@]} -eq 0 ]; then
        print_error "No Drupal sites found on $SELECTED_SSH_HOST"
        exit 1
    fi

    # Step 4: Select sites to import
    if ! select_sites_to_import; then
        echo "Cancelled."
        exit 0
    fi

    if [ ${#SELECTED_SITES[@]} -eq 0 ]; then
        print_warning "No sites selected"
        exit 0
    fi

    # Step 5: Configure import options
    if ! configure_all_import_options; then
        echo "Cancelled."
        exit 0
    fi

    # Step 6: Confirm
    if ! confirm_import; then
        echo "Cancelled."
        exit 0
    fi

    # Step 7: Import sites
    import_selected_sites

    print_status "OK" "Import process complete"
}

################################################################################
# Main
################################################################################

main() {
    parse_arguments "$@"

    if [ "$OPT_HELP" = "y" ]; then
        show_help
    fi

    validate_prerequisites

    # Determine mode
    if [ -n "$OPT_SOURCE" ] || [ "$OPT_ALL" = "y" ] || [ "$OPT_DRY_RUN" = "y" ]; then
        run_non_interactive
    elif [ -n "$OPT_SERVER" ] || [ -n "$OPT_SSH" ]; then
        # If server specified but no source, run interactive from that server
        if [ -n "$OPT_SITE_NAME" ]; then
            print_error "Site name specified but no --source. Use: --source=/var/www/site/web"
            exit 1
        fi
        run_interactive
    else
        run_interactive
    fi
}

# Run main
main "$@"
