#!/bin/bash
set -euo pipefail

################################################################################
# NWP Production Server Provisioning Script
#
# Provisions production servers with custom domains, SSL, and backups
#
# Usage: ./produce.sh [OPTIONS] <sitename>
################################################################################

# Get script directory (resolve symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

# Source shared libraries
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/common.sh"

################################################################################
# Helper Functions
################################################################################

get_base_name() {
    local site=$1
    echo "$site" | sed -E 's/_(stg|prod)$//'
}

get_prod_name() {
    local site=$1
    local base=$(get_base_name "$site")
    echo "${base}_prod"
}

get_prod_config() {
    local sitename="$1"
    local field="$2"

    awk -v site="$sitename" -v field="$field" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
        in_site && /^    prod:/ { in_prod = 1; next }
        in_prod && /^    [a-zA-Z]/ && !/^      / { in_prod = 0 }
        in_prod && $0 ~ "^      " field ":" {
            sub("^      " field ": *", "")
            gsub(/["'"'"']/, "")
            print
            exit
        }
    ' "$SCRIPT_DIR/cnwp.yml"
}

show_help() {
    cat << EOF
${BOLD}NWP Production Server Provisioning${NC}

${BOLD}USAGE:${NC}
    ./produce.sh [OPTIONS] <sitename>

    Provisions a production server for the site.

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    --delete                Remove production server
    --type TYPE             Linode type (default: g6-standard-2)
    --domain DOMAIN         Custom domain for production

${BOLD}EXAMPLES:${NC}
    ./produce.sh mysite                    # Provision production server
    ./produce.sh --domain mysite.com mysite   # With custom domain
    ./produce.sh --type g6-standard-4 mysite  # Larger server
    ./produce.sh --delete mysite           # Remove production server

${BOLD}WORKFLOW:${NC}
    1. Provision production server:  pl produce mysite
    2. Deploy to production:         pl stg2prod mysite
    3. View production site:         https://mysite.com

${BOLD}NOTE:${NC}
    Production servers include:
    - Dedicated Linode instance
    - Custom domain support
    - Let's Encrypt SSL
    - Automated backups enabled

EOF
}

################################################################################
# Main
################################################################################

main() {
    local DELETE=false
    local LINODE_TYPE="g6-standard-2"
    local CUSTOM_DOMAIN=""
    local SITENAME=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) show_help; exit 0 ;;
            --delete) DELETE=true; shift ;;
            --type) LINODE_TYPE="$2"; shift 2 ;;
            --domain) CUSTOM_DOMAIN="$2"; shift 2 ;;
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
    local PROD_NAME=$(get_prod_name "$SITENAME")
    local existing_ip=$(get_prod_config "$BASE_NAME" "server_ip")

    if [ "$DELETE" == "true" ]; then
        print_header "Remove Production Server"

        if [ -z "$existing_ip" ]; then
            print_error "No production server configured for $BASE_NAME"
            exit 1
        fi

        local linode_id=$(get_prod_config "$BASE_NAME" "linode_id")
        if [ -n "$linode_id" ]; then
            print_warning "Would delete Linode $linode_id ($existing_ip)"
            print_info "Manual deletion required via Linode dashboard"
            print_info "Then remove prod: section from cnwp.yml"
        fi
        exit 0
    fi

    if [ -n "$existing_ip" ]; then
        print_header "Production Server Status"
        local domain=$(get_prod_config "$BASE_NAME" "domain")
        echo -e "${BOLD}Site:${NC}    $BASE_NAME"
        echo -e "${BOLD}IP:${NC}      $existing_ip"
        echo -e "${BOLD}Domain:${NC} ${domain:-not configured}"
        echo ""
        print_info "Production server already provisioned"
        print_info "Deploy with: pl stg2prod $BASE_NAME"
        exit 0
    fi

    print_header "Production Server Provisioning"
    print_warning "Production servers require dedicated resources"
    echo ""
    echo -e "${BOLD}Site:${NC}   $BASE_NAME"
    echo -e "${BOLD}Type:${NC}   $LINODE_TYPE"
    echo -e "${BOLD}Domain:${NC} ${CUSTOM_DOMAIN:-to be configured}"
    echo ""

    # Production server provisioning would go here
    # This is a stub - full implementation would:
    # 1. Create Linode instance
    # 2. Configure DNS (if domain uses Linode)
    # 3. Setup SSL via Let's Encrypt
    # 4. Enable Linode backups
    # 5. Store config in cnwp.yml

    print_info "Production server provisioning not yet implemented"
    print_info "For now, use 'pl live' for shared hosting or provision manually"
    echo ""
    print_info "Manual setup steps:"
    echo "  1. Create Linode at dashboard.linode.com"
    echo "  2. Add prod: section to cnwp.yml with server_ip"
    echo "  3. Use 'pl stg2prod $BASE_NAME' to deploy"

    exit 0
}

main "$@"
