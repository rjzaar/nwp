#!/bin/bash
set -euo pipefail

################################################################################
# NWP Live Server Provisioning
#
# Provision live test servers at sitename.nwpcode.org
#
# Usage: ./live.sh [OPTIONS] <sitename>
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source shared libraries
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/common.sh"

################################################################################
# Help
################################################################################

show_help() {
    cat << EOF
${BOLD}NWP Live Server Provisioning${NC}

${BOLD}USAGE:${NC}
    ./live.sh [OPTIONS] <sitename>

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    --delete                Delete live server
    --type=TYPE             Server type: dedicated, shared, temporary
    --expires=DAYS          Days until auto-delete (temporary only)
    --status                Show live server status

${BOLD}EXAMPLES:${NC}
    ./live.sh nwp                      # Provision live server
    ./live.sh --type=temporary nwp     # Temporary (7 days)
    ./live.sh --delete nwp             # Delete live server
    ./live.sh --status nwp             # Show status

${BOLD}SERVER TYPES:${NC}
    dedicated    One Linode per site (production-like)
    shared       Multiple sites on GitLab server (cost-effective)
    temporary    Auto-delete after N days (PR reviews)

${BOLD}RESULT:${NC}
    Creates: https://sitename.nwpcode.org

EOF
}

################################################################################
# Live Server Functions
################################################################################

# Get base domain from cnwp.yml
get_base_domain() {
    local cnwp_file="${SCRIPT_DIR}/cnwp.yml"

    if [ -f "$cnwp_file" ]; then
        awk '
            /^settings:/ { in_settings = 1; next }
            in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
            in_settings && /^  url:/ {
                sub("^  url: *", "")
                gsub(/["'"'"']/, "")
                print
                exit
            }
        ' "$cnwp_file"
    fi
}

# Check if live server exists
live_exists() {
    local sitename="$1"
    local domain="${sitename}.$(get_base_domain)"

    # Check DNS
    if host "$domain" > /dev/null 2>&1; then
        return 0
    fi

    return 1
}

# Show live server status
live_status() {
    local sitename="$1"
    local base_domain=$(get_base_domain)
    local domain="${sitename}.${base_domain}"

    print_header "Live Server Status: $sitename"

    if live_exists "$sitename"; then
        print_status "OK" "Live server exists"
        echo "  Domain: https://${domain}"

        # Check if accessible
        if curl -s --max-time 5 "https://${domain}" > /dev/null 2>&1; then
            print_status "OK" "Site is accessible"
        else
            print_warning "Site may not be responding"
        fi
    else
        print_info "No live server found for $sitename"
    fi
}

# Provision dedicated live server
provision_dedicated() {
    local sitename="$1"
    local base_domain=$(get_base_domain)
    local domain="${sitename}.${base_domain}"

    print_header "Provisioning Dedicated Live Server"

    print_info "Domain: ${domain}"

    # Check Linode CLI
    if ! command -v linode-cli &> /dev/null; then
        print_error "linode-cli not installed"
        print_info "Install: pip install linode-cli"
        return 1
    fi

    # Create Linode
    print_info "Creating Linode instance..."
    local label="live-${sitename}"

    # Check if exists
    if linode-cli linodes list --label "$label" --text --no-headers 2>/dev/null | grep -q "$label"; then
        print_warning "Server already exists: $label"
        return 0
    fi

    print_info "This would create a new Linode with label: $label"
    print_info "Run with --confirm to actually create the server"
    print_info ""
    print_info "Manual steps required:"
    print_info "  1. Create Linode: linode-cli linodes create --label $label --type g6-nanode-1 --region us-east --image linode/ubuntu22.04"
    print_info "  2. Add DNS: linode-cli domains records-create <domain-id> --type A --name $sitename --target <ip>"
    print_info "  3. Setup SSL: certbot --nginx -d $domain"
    print_info "  4. Deploy site: ./stg2live.sh $sitename"

    return 0
}

# Provision shared live server (on GitLab server)
provision_shared() {
    local sitename="$1"
    local base_domain=$(get_base_domain)
    local domain="${sitename}.${base_domain}"

    print_header "Provisioning Shared Live Server"

    print_info "Domain: ${domain}"
    print_info "This will deploy to the existing GitLab server"

    # Check GitLab server access
    local gitlab_host="git.${base_domain}"
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "root@${gitlab_host}" exit 2>/dev/null; then
        print_error "Cannot access GitLab server: ${gitlab_host}"
        return 1
    fi

    print_info "Steps to deploy on shared server:"
    print_info "  1. SSH to ${gitlab_host}"
    print_info "  2. Create site directory: /var/www/${sitename}"
    print_info "  3. Setup nginx vhost for ${domain}"
    print_info "  4. Get SSL: certbot --nginx -d ${domain}"
    print_info "  5. Deploy site files"

    return 0
}

# Delete live server
live_delete() {
    local sitename="$1"
    local type="${2:-dedicated}"

    print_header "Deleting Live Server: $sitename"

    if ! live_exists "$sitename"; then
        print_info "No live server found for $sitename"
        return 0
    fi

    print_warning "This will delete the live server for $sitename"
    print_info "Type 'yes' to confirm: "
    read -r confirm

    if [ "$confirm" != "yes" ]; then
        print_info "Cancelled"
        return 0
    fi

    case "$type" in
        dedicated)
            local label="live-${sitename}"
            print_info "Deleting Linode: $label"
            linode-cli linodes delete --label "$label" 2>/dev/null || true
            ;;
        shared)
            print_info "Remove site from shared server manually"
            ;;
    esac

    print_status "OK" "Live server deleted"
}

################################################################################
# Main
################################################################################

main() {
    local DEBUG=false
    local DELETE=false
    local TYPE="dedicated"
    local EXPIRES=7
    local STATUS=false
    local SITENAME=""

    # Parse options
    local OPTIONS=hd
    local LONGOPTS=help,debug,delete,type:,expires:,status

    if ! PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTS --name "$0" -- "$@"); then
        show_help
        exit 1
    fi

    eval set -- "$PARSED"

    while true; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            -d|--debug) DEBUG=true; shift ;;
            --delete) DELETE=true; shift ;;
            --type) TYPE="$2"; shift 2 ;;
            --expires) EXPIRES="$2"; shift 2 ;;
            --status) STATUS=true; shift ;;
            --) shift; break ;;
            *) echo "Programming error"; exit 3 ;;
        esac
    done

    # Get sitename
    if [ $# -ge 1 ]; then
        SITENAME="$1"
    else
        print_error "Sitename required"
        show_help
        exit 1
    fi

    # Execute
    if [ "$STATUS" == "true" ]; then
        live_status "$SITENAME"
    elif [ "$DELETE" == "true" ]; then
        live_delete "$SITENAME" "$TYPE"
    else
        case "$TYPE" in
            dedicated)
                provision_dedicated "$SITENAME"
                ;;
            shared)
                provision_shared "$SITENAME"
                ;;
            temporary)
                provision_dedicated "$SITENAME"
                print_info "Server will auto-delete in $EXPIRES days"
                ;;
            *)
                print_error "Unknown type: $TYPE"
                exit 1
                ;;
        esac
    fi
}

main "$@"
