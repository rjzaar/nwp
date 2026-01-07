#!/bin/bash
set -euo pipefail

################################################################################
# NWP Live to Production Deployment Script
#
# Deploys from live test server to production server
#
# Usage: ./live2prod.sh [OPTIONS] <sitename>
################################################################################

# Get script directory (from symlink location, not resolved target)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"

################################################################################
# Helper Functions
################################################################################

get_base_name() {
    local site=$1
    echo "$site" | sed -E 's/_(stg|prod)$//'
}

get_live_config() {
    local sitename="$1"
    local field="$2"

    awk -v site="$sitename" -v field="$field" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
        in_site && /^    live:/ { in_live = 1; next }
        in_live && /^    [a-zA-Z]/ && !/^      / { in_live = 0 }
        in_live && $0 ~ "^      " field ":" {
            sub("^      " field ": *", "")
            gsub(/["'"'"']/, "")
            print
            exit
        }
    ' "$PROJECT_ROOT/cnwp.yml"
}

show_help() {
    cat << EOF
${BOLD}NWP Live to Production Deployment${NC}

${BOLD}USAGE:${NC}
    ./live2prod.sh [OPTIONS] <sitename>

    Deploys from live test server directly to production.

${BOLD}NOTE:${NC}
    This is an advanced workflow. The recommended workflow is:
    1. pl stg2prod mysite  (deploy staging to production)

    Use this only when you've tested on live and want to
    deploy directly without going through staging again.

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -y, --yes               Skip confirmation prompts

${BOLD}EXAMPLES:${NC}
    ./live2prod.sh mysite              # Deploy live to production
    ./live2prod.sh -y mysite           # Deploy without confirmation

EOF
}

################################################################################
# Main
################################################################################

main() {
    local YES=false
    local SITENAME=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) show_help; exit 0 ;;
            -y|--yes) YES=true; shift ;;
            -*) print_error "Unknown option: $1"; exit 1 ;;
            *) SITENAME="$1"; shift ;;
        esac
    done

    if [ -z "$SITENAME" ]; then
        print_error "Sitename required"
        show_help
        exit 1
    fi

    local BASE_NAME=$(get_base_name "$SITENAME")
    local live_ip=$(get_live_config "$BASE_NAME" "server_ip")

    if [ -z "$live_ip" ]; then
        print_error "No live server configured for $BASE_NAME"
        print_info "Run 'pl live $BASE_NAME' first"
        exit 1
    fi

    print_header "Live to Production Deployment"
    print_warning "This deploys directly from live to production"
    print_info "Recommended workflow: pl stg2prod $BASE_NAME"
    echo ""

    # This is essentially: pull live to staging, then stg2prod
    # For now, suggest the safer workflow
    print_info "To deploy live to production:"
    echo ""
    echo "  1. Pull live to staging:  pl live2stg $BASE_NAME"
    echo "  2. Deploy to production:  pl stg2prod $BASE_NAME"
    echo ""
    print_info "Or run stg2prod directly if staging is up to date"

    # TODO: Implement direct live-to-prod rsync if needed
    # This would require production server config similar to stg2prod

    exit 0
}

main "$@"
