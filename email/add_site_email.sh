#!/bin/bash

################################################################################
# add_site_email.sh - Add email account for an NWP site
#
# This script implements E07 from EMAIL_POSTFIX_PROPOSAL.md:
#   E07: Virtual Mailboxes for Sites
#
# Usage:
#   ./add_site_email.sh <sitename>                    # Add email for site
#   ./add_site_email.sh <sitename> --forward <email>  # Add with forwarding
#   ./add_site_email.sh <sitename> --forward-only <email>  # Forwarding only (no mailbox)
#   ./add_site_email.sh <sitename> --receive          # Enable receiving (Dovecot)
#   ./add_site_email.sh <sitename> -y                 # Non-interactive (skip prompts)
#   ./add_site_email.sh --list                        # List all site emails
#   ./add_site_email.sh --delete <sitename>           # Remove site email
#   ./add_site_email.sh --help                        # Show this help
#
# Prerequisites:
#   - Run setup_email.sh first to configure base email infrastructure
#   - Run as root on the GitLab server
#
################################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NWP_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
DOMAIN="${DOMAIN:-nwpcode.org}"
VIRTUAL_MAILBOX_BASE="/var/mail/vhosts"
VIRTUAL_UID="${VIRTUAL_UID:-5000}"
VIRTUAL_GID="${VIRTUAL_GID:-5000}"

# Colors
# Respects NO_COLOR standard (https://no-color.org/)
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
fi

################################################################################
# Helper Functions
################################################################################

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_ok() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1" >&2
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

show_help() {
    sed -n '3,17p' "$0" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        echo "Try: sudo $0 $*"
        exit 1
    fi
}

################################################################################
# Virtual Mailbox Setup
################################################################################

setup_virtual_users() {
    # Create vmail user/group if not exists
    if ! getent group vmail > /dev/null 2>&1; then
        print_info "Creating vmail group..."
        groupadd -g ${VIRTUAL_GID} vmail
    fi

    if ! getent passwd vmail > /dev/null 2>&1; then
        print_info "Creating vmail user..."
        useradd -u ${VIRTUAL_UID} -g vmail -d ${VIRTUAL_MAILBOX_BASE} -s /sbin/nologin vmail
    fi

    # Create mailbox base directory
    mkdir -p ${VIRTUAL_MAILBOX_BASE}/${DOMAIN}
    chown -R vmail:vmail ${VIRTUAL_MAILBOX_BASE}
    chmod -R 770 ${VIRTUAL_MAILBOX_BASE}

    # Configure Postfix for virtual mailboxes (if not already)
    if ! postconf virtual_mailbox_base 2>/dev/null | grep -q "${VIRTUAL_MAILBOX_BASE}"; then
        print_info "Configuring Postfix virtual mailbox support..."

        postconf -e "virtual_mailbox_domains = ${DOMAIN}"
        postconf -e "virtual_mailbox_base = ${VIRTUAL_MAILBOX_BASE}"
        postconf -e "virtual_mailbox_maps = hash:/etc/postfix/vmailbox"
        postconf -e "virtual_alias_maps = hash:/etc/postfix/virtual"
        postconf -e "virtual_uid_maps = static:${VIRTUAL_UID}"
        postconf -e "virtual_gid_maps = static:${VIRTUAL_GID}"

        # Create empty files if not exist
        touch /etc/postfix/vmailbox /etc/postfix/virtual
        postmap /etc/postfix/vmailbox
        postmap /etc/postfix/virtual

        systemctl reload postfix
    fi
}

################################################################################
# Add Site Email
################################################################################

add_site_email() {
    local sitename="$1"
    local forward_to="${2:-}"
    local enable_receive="${3:-false}"
    local forward_only="${4:-false}"
    local noninteractive="${5:-false}"

    local email="${sitename}@${DOMAIN}"

    print_header "Adding Email: ${email}"

    # For forward-only mode, we just need the virtual alias
    if [ "$forward_only" = "true" ]; then
        if [ -z "$forward_to" ]; then
            print_error "Forward-only mode requires a forward address"
            exit 1
        fi

        # Check if alias already exists
        if grep -q "^${email}" /etc/postfix/virtual 2>/dev/null; then
            print_warning "Email alias ${email} already exists"
            if [ "$noninteractive" != "true" ]; then
                read -p "Replace it? [y/N] " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    exit 0
                fi
            fi
            sed -i "/^${email}/d" /etc/postfix/virtual
        fi

        # Add forwarding alias only
        echo "${email}    ${forward_to}" >> /etc/postfix/virtual
        postmap /etc/postfix/virtual
        systemctl reload postfix

        print_ok "Forwarding alias created: ${email} → ${forward_to}"
        return 0
    fi

    # Full mailbox mode
    # Ensure virtual mailbox infrastructure exists
    setup_virtual_users

    # Check if email already exists
    if grep -q "^${email}" /etc/postfix/vmailbox 2>/dev/null; then
        print_warning "Email ${email} already exists"
        if [ "$noninteractive" != "true" ]; then
            read -p "Replace it? [y/N] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 0
            fi
        fi
        # Remove existing entry
        sed -i "/^${email}/d" /etc/postfix/vmailbox
        sed -i "/^${email}/d" /etc/postfix/virtual
    fi

    # Create mailbox directory
    local mailbox_dir="${VIRTUAL_MAILBOX_BASE}/${DOMAIN}/${sitename}"
    mkdir -p "${mailbox_dir}/new" "${mailbox_dir}/cur" "${mailbox_dir}/tmp"
    chown -R vmail:vmail "${mailbox_dir}"
    chmod -R 770 "${mailbox_dir}"

    # Add to vmailbox
    echo "${email}    ${DOMAIN}/${sitename}/" >> /etc/postfix/vmailbox
    postmap /etc/postfix/vmailbox

    print_ok "Mailbox created: ${mailbox_dir}"

    # Add forwarding if specified
    if [ -n "$forward_to" ]; then
        # Add to virtual aliases
        echo "${email}    ${email}, ${forward_to}" >> /etc/postfix/virtual
        postmap /etc/postfix/virtual
        print_ok "Forwarding enabled: ${email} → ${forward_to}"
    fi

    # Enable receiving via Dovecot if specified
    if [ "$enable_receive" = "true" ]; then
        setup_dovecot_user "${sitename}" "${email}"
    fi

    # Reload Postfix
    systemctl reload postfix

    echo ""
    print_ok "Email ${email} is now active"
    echo ""
    echo "Test sending:"
    echo "  echo 'Test message' | mail -s 'Test from ${sitename}' -r ${email} your@email.com"
    echo ""
}

################################################################################
# Dovecot User Setup (for receiving email via IMAP)
################################################################################

setup_dovecot_user() {
    local sitename="$1"
    local email="$2"

    # Check if Dovecot is installed
    if ! command -v dovecot &> /dev/null; then
        print_warning "Dovecot not installed - skipping IMAP setup"
        print_info "Install with: apt-get install dovecot-imapd dovecot-lmtpd"
        return 0
    fi

    # Create password file if not exists
    local passwd_file="/etc/dovecot/users"
    touch "${passwd_file}"
    chmod 600 "${passwd_file}"

    # Generate random password
    local password=$(openssl rand -base64 12)
    local hashed_password=$(doveadm pw -s SHA512-CRYPT -p "$password")

    # Check for existing user
    if grep -q "^${email}:" "${passwd_file}" 2>/dev/null; then
        print_info "Updating Dovecot user..."
        sed -i "/^${email}:/d" "${passwd_file}"
    fi

    # Add user to passwd file
    # Format: user:password:uid:gid:gecos:home:shell:extra_fields
    echo "${email}:${hashed_password}:${VIRTUAL_UID}:${VIRTUAL_GID}::${VIRTUAL_MAILBOX_BASE}/${DOMAIN}/${sitename}::" >> "${passwd_file}"

    print_ok "Dovecot user created for ${email}"

    # Save password to site's secrets file
    local site_dir="${NWP_DIR}/${sitename}"
    if [ -d "$site_dir" ]; then
        local secrets_file="${site_dir}/.secrets.yml"
        if [ -f "$secrets_file" ]; then
            # Append email credentials
            if ! grep -q "email:" "$secrets_file"; then
                cat >> "$secrets_file" << EOF

# Email credentials (added by add_site_email.sh)
email:
  address: ${email}
  imap_password: ${password}
  imap_server: ${DOMAIN}
  imap_port: 993
  smtp_server: ${DOMAIN}
  smtp_port: 587
EOF
                print_ok "Credentials saved to ${secrets_file}"
            fi
        fi
    fi

    echo ""
    print_info "IMAP Credentials for ${email}:"
    echo "  Server: ${DOMAIN}"
    echo "  Port: 993 (IMAPS) or 143 (IMAP+STARTTLS)"
    echo "  Username: ${email}"
    echo "  Password: ${password}"
    echo ""
    print_warning "Save this password - it cannot be recovered!"
}

################################################################################
# List Site Emails
################################################################################

list_site_emails() {
    print_header "Site Email Accounts"

    if [ ! -f /etc/postfix/vmailbox ]; then
        print_warning "No virtual mailboxes configured"
        exit 0
    fi

    local count=0
    echo "Email Address                       Mailbox Path                   Forward To"
    echo "─────────────────────────────────────────────────────────────────────────────────"

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        [[ "$line" =~ ^# ]] && continue

        local email=$(echo "$line" | awk '{print $1}')
        local mailbox=$(echo "$line" | awk '{print $2}')

        # Check for forwarding
        local forward=""
        if grep -q "^${email}" /etc/postfix/virtual 2>/dev/null; then
            forward=$(grep "^${email}" /etc/postfix/virtual | sed "s/${email}[ ]*${email},[ ]*//" | sed "s/${email}[ ]*//")
        fi

        printf "%-35s %-30s %s\n" "$email" "$mailbox" "$forward"
        count=$((count + 1))
    done < /etc/postfix/vmailbox

    echo ""
    print_info "Total: ${count} email account(s)"
}

################################################################################
# Delete Site Email
################################################################################

delete_site_email() {
    local sitename="$1"
    local email="${sitename}@${DOMAIN}"

    print_header "Deleting Email: ${email}"

    # Check if exists
    if ! grep -q "^${email}" /etc/postfix/vmailbox 2>/dev/null; then
        print_error "Email ${email} not found"
        exit 1
    fi

    # Confirm
    print_warning "This will delete the mailbox and all emails!"
    read -p "Are you sure? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
    fi

    # Remove from vmailbox
    sed -i "/^${email}/d" /etc/postfix/vmailbox
    postmap /etc/postfix/vmailbox

    # Remove from virtual aliases
    sed -i "/^${email}/d" /etc/postfix/virtual 2>/dev/null || true
    postmap /etc/postfix/virtual 2>/dev/null || true

    # Remove from Dovecot
    if [ -f /etc/dovecot/users ]; then
        sed -i "/^${email}:/d" /etc/dovecot/users 2>/dev/null || true
    fi

    # Remove mailbox directory
    local mailbox_dir="${VIRTUAL_MAILBOX_BASE}/${DOMAIN}/${sitename}"
    if [ -d "$mailbox_dir" ]; then
        rm -rf "$mailbox_dir"
        print_ok "Mailbox directory removed"
    fi

    systemctl reload postfix

    print_ok "Email ${email} deleted"
}

################################################################################
# Setup from cnwp.yml
################################################################################

setup_from_config() {
    local sitename="$1"
    local config_file="${NWP_DIR}/${sitename}/cnwp.yml"

    if [ ! -f "$config_file" ]; then
        print_error "Config file not found: ${config_file}"
        exit 1
    fi

    print_info "Reading email configuration from ${config_file}..."

    # Parse email settings (using basic awk)
    local email_enabled=$(awk '/^[[:space:]]*email:/{found=1} found && /enabled:/{print $2; exit}' "$config_file" | tr -d ' ')
    local email_address=$(awk '/^[[:space:]]*email:/{found=1} found && /address:/{print $2; exit}' "$config_file" | tr -d ' ')
    local email_direction=$(awk '/^[[:space:]]*email:/{found=1} found && /direction:/{print $2; exit}' "$config_file" | tr -d ' ')
    local email_forward=$(awk '/^[[:space:]]*email:/{found=1} found && /forward:/{print $2; exit}' "$config_file" | tr -d ' ')

    if [ "$email_enabled" != "true" ]; then
        print_warning "Email not enabled for ${sitename}"
        exit 0
    fi

    # Extract sitename from email address if not standard
    if [ -n "$email_address" ]; then
        local extracted_name="${email_address%%@*}"
        if [ "$extracted_name" != "$sitename" ]; then
            sitename="$extracted_name"
        fi
    fi

    # Determine flags
    local forward_arg=""
    local receive_arg="false"

    if [ -n "$email_forward" ]; then
        forward_arg="$email_forward"
    fi

    if [ "$email_direction" = "all" ]; then
        receive_arg="true"
    fi

    # Add the email
    add_site_email "$sitename" "$forward_arg" "$receive_arg"
}

################################################################################
# Main
################################################################################

main() {
    if [ $# -eq 0 ]; then
        show_help
    fi

    local action=""
    local sitename=""
    local forward_to=""
    local enable_receive="false"
    local forward_only="false"
    local noninteractive="false"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help
                ;;
            --list|-l)
                action="list"
                shift
                ;;
            --delete|-d)
                action="delete"
                sitename="$2"
                shift 2
                ;;
            --forward|-f)
                forward_to="$2"
                shift 2
                ;;
            --forward-only|-fo)
                forward_only="true"
                forward_to="$2"
                shift 2
                ;;
            --receive|-r)
                enable_receive="true"
                shift
                ;;
            --yes|-y)
                noninteractive="true"
                shift
                ;;
            --from-config)
                action="config"
                sitename="$2"
                shift 2
                ;;
            -*)
                print_error "Unknown option: $1"
                exit 1
                ;;
            *)
                if [ -z "$sitename" ]; then
                    sitename="$1"
                    action="${action:-add}"
                fi
                shift
                ;;
        esac
    done

    # Check root for most operations
    if [ "$action" != "list" ] || [ ! -f /etc/postfix/vmailbox ]; then
        check_root
    fi

    case "$action" in
        list)
            list_site_emails
            ;;
        delete)
            delete_site_email "$sitename"
            ;;
        config)
            setup_from_config "$sitename"
            ;;
        add)
            add_site_email "$sitename" "$forward_to" "$enable_receive" "$forward_only" "$noninteractive"
            ;;
        *)
            show_help
            ;;
    esac
}

main "$@"
