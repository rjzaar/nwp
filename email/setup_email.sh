#!/bin/bash

################################################################################
# setup_email.sh - Set up complete email infrastructure on NWP GitLab server
#
# This script implements proposals E01-E05 from EMAIL_POSTFIX_PROPOSAL.md:
#   E01: Configure Postfix MTA
#   E02: Configure SPF record
#   E03: Install and configure OpenDKIM
#   E04: Configure DMARC record
#   E05: Configure reverse DNS (PTR)
#
# Usage:
#   ./setup_email.sh                    # Run on GitLab server
#   ./setup_email.sh --check            # Check current status
#   ./setup_email.sh --dns-only         # Only configure DNS records
#   ./setup_email.sh --help             # Show this help
#
# Prerequisites:
#   - Run as root on the GitLab server
#   - Domain DNS managed by Linode
#   - Linode API token in .secrets.yml or environment
#
################################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NWP_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
DOMAIN="${DOMAIN:-nwpcode.org}"
MAIL_HOSTNAME="${MAIL_HOSTNAME:-git.${DOMAIN}}"
MAIL_IP="${MAIL_IP:-97.107.137.88}"
DKIM_SELECTOR="${DKIM_SELECTOR:-default}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN}}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Flags
CHECK_ONLY=false
DNS_ONLY=false
SKIP_DNS=false

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
    sed -n '3,20p' "$0" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

# Get secret from .secrets.yml
get_secret() {
    local path="$1"
    local default="${2:-}"
    local secrets_file="${NWP_DIR}/.secrets.yml"

    if [ ! -f "$secrets_file" ]; then
        echo "$default"
        return
    fi

    local section="${path%%.*}"
    local key="${path#*.}"

    local value=$(awk -v section="$section" -v key="$key" '
        $0 ~ "^" section ":" { in_section = 1; next }
        in_section && /^[a-zA-Z]/ && !/^  / { in_section = 0 }
        in_section && $0 ~ "^  " key ":" {
            sub("^  " key ": *", "")
            gsub(/["'"'"']/, "")
            sub(/ *#.*$/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
    ' "$secrets_file")

    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        echo "Try: sudo $0"
        exit 1
    fi
}

################################################################################
# E01: Postfix Configuration
################################################################################

setup_postfix() {
    print_header "E01: Configuring Postfix"

    # Check if already installed
    if ! command -v postfix &> /dev/null; then
        print_info "Installing Postfix..."
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y postfix mailutils libsasl2-modules
    else
        print_ok "Postfix already installed"
    fi

    # Backup existing config
    if [ -f /etc/postfix/main.cf ] && [ ! -f /etc/postfix/main.cf.backup ]; then
        cp /etc/postfix/main.cf /etc/postfix/main.cf.backup
        print_info "Backed up existing config"
    fi

    # Configure main.cf
    print_info "Configuring /etc/postfix/main.cf..."

    postconf -e "myhostname = ${MAIL_HOSTNAME}"
    postconf -e "mydomain = ${DOMAIN}"
    postconf -e "myorigin = \$mydomain"
    postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost"
    postconf -e "inet_interfaces = all"
    postconf -e "inet_protocols = ipv4"

    # TLS settings (use Let's Encrypt certs if available)
    if [ -f "/etc/letsencrypt/live/${MAIL_HOSTNAME}/fullchain.pem" ]; then
        postconf -e "smtpd_tls_cert_file = /etc/letsencrypt/live/${MAIL_HOSTNAME}/fullchain.pem"
        postconf -e "smtpd_tls_key_file = /etc/letsencrypt/live/${MAIL_HOSTNAME}/privkey.pem"
        postconf -e "smtpd_use_tls = yes"
        postconf -e "smtpd_tls_security_level = may"
        postconf -e "smtp_tls_security_level = may"
        print_ok "TLS configured with Let's Encrypt certificates"
    else
        print_warning "No Let's Encrypt certs found - TLS not configured"
    fi

    # Submission port (587) for authenticated sending
    if ! grep -q "^submission" /etc/postfix/master.cf; then
        print_info "Enabling submission port (587)..."
        cat >> /etc/postfix/master.cf << 'EOF'

# Submission port for authenticated email sending
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_tls_auth_only=yes
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
EOF
    fi

    # Restart Postfix
    systemctl restart postfix
    systemctl enable postfix

    print_ok "Postfix configured and running"
}

check_postfix() {
    echo -n "E01 Postfix: "
    if systemctl is-active postfix &> /dev/null; then
        local hostname=$(postconf -h myhostname 2>/dev/null)
        echo -e "${GREEN}RUNNING${NC} (hostname: $hostname)"
        return 0
    else
        echo -e "${RED}NOT RUNNING${NC}"
        return 1
    fi
}

################################################################################
# E02: SPF Record
################################################################################

setup_spf() {
    print_header "E02: Configuring SPF Record"

    if $SKIP_DNS; then
        print_warning "Skipping DNS configuration (--skip-dns)"
        return 0
    fi

    local linode_token=$(get_secret "linode.api_token" "${LINODE_API_TOKEN:-}")
    if [ -z "$linode_token" ]; then
        print_error "No Linode API token found"
        print_info "Set LINODE_API_TOKEN or add to .secrets.yml"
        return 1
    fi

    # Get domain ID
    local domain_id=$(curl -s -H "Authorization: Bearer $linode_token" \
        "https://api.linode.com/v4/domains" | \
        python3 -c "import sys,json; domains=json.load(sys.stdin)['data']; print(next((d['id'] for d in domains if d['domain']=='${DOMAIN}'), ''))" 2>/dev/null)

    if [ -z "$domain_id" ]; then
        print_error "Domain ${DOMAIN} not found in Linode DNS"
        return 1
    fi

    print_info "Domain ID: $domain_id"

    # Check for existing SPF record
    local existing_spf=$(curl -s -H "Authorization: Bearer $linode_token" \
        "https://api.linode.com/v4/domains/${domain_id}/records" | \
        python3 -c "import sys,json; records=json.load(sys.stdin)['data']; print(next((r['id'] for r in records if r['type']=='TXT' and 'v=spf1' in r.get('target','')), ''))" 2>/dev/null)

    local spf_value="v=spf1 ip4:${MAIL_IP} a mx -all"

    if [ -n "$existing_spf" ]; then
        print_info "Updating existing SPF record..."
        curl -s -X PUT -H "Authorization: Bearer $linode_token" \
            -H "Content-Type: application/json" \
            -d "{\"target\": \"${spf_value}\"}" \
            "https://api.linode.com/v4/domains/${domain_id}/records/${existing_spf}" > /dev/null
    else
        print_info "Creating SPF record..."
        curl -s -X POST -H "Authorization: Bearer $linode_token" \
            -H "Content-Type: application/json" \
            -d "{\"type\": \"TXT\", \"name\": \"\", \"target\": \"${spf_value}\", \"ttl_sec\": 300}" \
            "https://api.linode.com/v4/domains/${domain_id}/records" > /dev/null
    fi

    print_ok "SPF record configured: ${spf_value}"

    # Store domain_id for other functions
    LINODE_DOMAIN_ID="$domain_id"
    LINODE_TOKEN="$linode_token"
}

check_spf() {
    echo -n "E02 SPF: "
    local spf=$(dig TXT "${DOMAIN}" +short 2>/dev/null | grep -i "v=spf1" | tr -d '"')
    if [ -n "$spf" ]; then
        echo -e "${GREEN}OK${NC} ($spf)"
        return 0
    else
        echo -e "${RED}MISSING${NC}"
        return 1
    fi
}

################################################################################
# E03: OpenDKIM
################################################################################

setup_opendkim() {
    print_header "E03: Configuring OpenDKIM"

    # Install OpenDKIM
    if ! command -v opendkim &> /dev/null; then
        print_info "Installing OpenDKIM..."
        apt-get update
        apt-get install -y opendkim opendkim-tools
    else
        print_ok "OpenDKIM already installed"
    fi

    # Add postfix user to opendkim group
    usermod -aG opendkim postfix

    # Create directories
    mkdir -p /etc/opendkim/keys/${DOMAIN}

    # Generate DKIM keys if not exist
    if [ ! -f "/etc/opendkim/keys/${DOMAIN}/${DKIM_SELECTOR}.private" ]; then
        print_info "Generating DKIM keys..."
        cd /etc/opendkim/keys/${DOMAIN}
        opendkim-genkey -s ${DKIM_SELECTOR} -d ${DOMAIN} -b 2048
        chown opendkim:opendkim ${DKIM_SELECTOR}.private
        chmod 600 ${DKIM_SELECTOR}.private
        print_ok "DKIM keys generated"
    else
        print_ok "DKIM keys already exist"
    fi

    # Configure opendkim.conf
    print_info "Configuring /etc/opendkim.conf..."
    cat > /etc/opendkim.conf << EOF
# OpenDKIM configuration for ${DOMAIN}
AutoRestart             Yes
AutoRestartRate         10/1h
UMask                   002
Syslog                  yes
SyslogSuccess           Yes
LogWhy                  Yes

Canonicalization        relaxed/simple
ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
Mode                    sv
SignatureAlgorithm      rsa-sha256
Socket                  inet:8891@localhost
PidFile                 /run/opendkim/opendkim.pid
OversignHeaders         From

# Multi-domain support
SubDomains              yes
EOF

    # Create TrustedHosts
    cat > /etc/opendkim/TrustedHosts << EOF
127.0.0.1
localhost
${MAIL_HOSTNAME}
*.${DOMAIN}
EOF

    # Create KeyTable
    cat > /etc/opendkim/KeyTable << EOF
${DKIM_SELECTOR}._domainkey.${DOMAIN} ${DOMAIN}:${DKIM_SELECTOR}:/etc/opendkim/keys/${DOMAIN}/${DKIM_SELECTOR}.private
EOF

    # Create SigningTable
    cat > /etc/opendkim/SigningTable << EOF
*@${DOMAIN} ${DKIM_SELECTOR}._domainkey.${DOMAIN}
*@*.${DOMAIN} ${DKIM_SELECTOR}._domainkey.${DOMAIN}
EOF

    # Set permissions
    chown -R opendkim:opendkim /etc/opendkim
    chmod -R go-rwx /etc/opendkim/keys

    # Create run directory
    mkdir -p /run/opendkim
    chown opendkim:opendkim /run/opendkim

    # Configure Postfix to use OpenDKIM
    postconf -e "milter_protocol = 6"
    postconf -e "milter_default_action = accept"
    postconf -e "smtpd_milters = inet:localhost:8891"
    postconf -e "non_smtpd_milters = inet:localhost:8891"

    # Restart services
    systemctl restart opendkim
    systemctl enable opendkim
    systemctl restart postfix

    print_ok "OpenDKIM configured and running"

    # Add DKIM DNS record
    if ! $SKIP_DNS && [ -n "${LINODE_TOKEN:-}" ]; then
        print_info "Adding DKIM DNS record..."
        # Extract full public key from multi-line DKIM file
        # The key file has format: ( "v=DKIM1; ..." "p=KEY" "KEYCONTINUED" )
        local dkim_record=$(cat /etc/opendkim/keys/${DOMAIN}/${DKIM_SELECTOR}.txt | \
            tr -d '\n\t' | sed 's/.*p=/p=/' | sed 's/).*//' | tr -d ' "' | sed 's/^p=//')
        local dkim_value="v=DKIM1; h=sha256; k=rsa; p=${dkim_record}"

        # Check for existing DKIM record
        local existing_dkim=$(curl -s -H "Authorization: Bearer $LINODE_TOKEN" \
            "https://api.linode.com/v4/domains/${LINODE_DOMAIN_ID}/records" | \
            python3 -c "import sys,json; records=json.load(sys.stdin)['data']; print(next((r['id'] for r in records if r['type']=='TXT' and r.get('name','')=='${DKIM_SELECTOR}._domainkey'), ''))" 2>/dev/null)

        if [ -n "$existing_dkim" ]; then
            curl -s -X PUT -H "Authorization: Bearer $LINODE_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"target\": \"${dkim_value}\"}" \
                "https://api.linode.com/v4/domains/${LINODE_DOMAIN_ID}/records/${existing_dkim}" > /dev/null
        else
            curl -s -X POST -H "Authorization: Bearer $LINODE_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"type\": \"TXT\", \"name\": \"${DKIM_SELECTOR}._domainkey\", \"target\": \"${dkim_value}\", \"ttl_sec\": 300}" \
                "https://api.linode.com/v4/domains/${LINODE_DOMAIN_ID}/records" > /dev/null
        fi
        print_ok "DKIM DNS record added"
    else
        print_warning "Add this DKIM record to DNS manually:"
        echo ""
        cat /etc/opendkim/keys/${DOMAIN}/${DKIM_SELECTOR}.txt
        echo ""
    fi
}

check_opendkim() {
    echo -n "E03 OpenDKIM: "
    if systemctl is-active opendkim &> /dev/null; then
        local dkim=$(dig TXT "${DKIM_SELECTOR}._domainkey.${DOMAIN}" +short 2>/dev/null | tr -d '"')
        if [ -n "$dkim" ]; then
            echo -e "${GREEN}RUNNING + DNS OK${NC}"
            return 0
        else
            echo -e "${YELLOW}RUNNING (no DNS record)${NC}"
            return 1
        fi
    else
        echo -e "${RED}NOT RUNNING${NC}"
        return 1
    fi
}

################################################################################
# E04: DMARC Record
################################################################################

setup_dmarc() {
    print_header "E04: Configuring DMARC Record"

    if $SKIP_DNS; then
        print_warning "Skipping DNS configuration (--skip-dns)"
        return 0
    fi

    if [ -z "${LINODE_TOKEN:-}" ]; then
        print_error "No Linode API token - run setup_spf first"
        return 1
    fi

    local dmarc_value="v=DMARC1; p=quarantine; sp=quarantine; rua=mailto:dmarc@${DOMAIN}; ruf=mailto:dmarc@${DOMAIN}; adkim=r; aspf=r; pct=100"

    # Check for existing DMARC record
    local existing_dmarc=$(curl -s -H "Authorization: Bearer $LINODE_TOKEN" \
        "https://api.linode.com/v4/domains/${LINODE_DOMAIN_ID}/records" | \
        python3 -c "import sys,json; records=json.load(sys.stdin)['data']; print(next((r['id'] for r in records if r['type']=='TXT' and r.get('name','')=='_dmarc'), ''))" 2>/dev/null)

    if [ -n "$existing_dmarc" ]; then
        print_info "Updating existing DMARC record..."
        curl -s -X PUT -H "Authorization: Bearer $LINODE_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"target\": \"${dmarc_value}\"}" \
            "https://api.linode.com/v4/domains/${LINODE_DOMAIN_ID}/records/${existing_dmarc}" > /dev/null
    else
        print_info "Creating DMARC record..."
        curl -s -X POST -H "Authorization: Bearer $LINODE_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"type\": \"TXT\", \"name\": \"_dmarc\", \"target\": \"${dmarc_value}\", \"ttl_sec\": 300}" \
            "https://api.linode.com/v4/domains/${LINODE_DOMAIN_ID}/records" > /dev/null
    fi

    print_ok "DMARC record configured"
}

check_dmarc() {
    echo -n "E04 DMARC: "
    local dmarc=$(dig TXT "_dmarc.${DOMAIN}" +short 2>/dev/null | tr -d '"')
    if [ -n "$dmarc" ]; then
        echo -e "${GREEN}OK${NC} ($dmarc)"
        return 0
    else
        echo -e "${RED}MISSING${NC}"
        return 1
    fi
}

################################################################################
# E05: Reverse DNS (PTR)
################################################################################

setup_ptr() {
    print_header "E05: Configuring Reverse DNS (PTR)"

    if $SKIP_DNS; then
        print_warning "Skipping DNS configuration (--skip-dns)"
        return 0
    fi

    local linode_token=$(get_secret "linode.api_token" "${LINODE_API_TOKEN:-}")
    if [ -z "$linode_token" ]; then
        print_error "No Linode API token found"
        return 1
    fi

    # Get Linode ID for the IP
    local linode_id=$(curl -s -H "Authorization: Bearer $linode_token" \
        "https://api.linode.com/v4/networking/ips/${MAIL_IP}" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('linode_id',''))" 2>/dev/null)

    if [ -z "$linode_id" ]; then
        print_error "Could not find Linode for IP ${MAIL_IP}"
        print_info "Configure PTR manually in Linode Cloud Manager"
        return 1
    fi

    print_info "Setting rDNS for IP ${MAIL_IP} to ${MAIL_HOSTNAME}..."

    # Update rDNS
    local result=$(curl -s -X PUT -H "Authorization: Bearer $linode_token" \
        -H "Content-Type: application/json" \
        -d "{\"rdns\": \"${MAIL_HOSTNAME}\"}" \
        "https://api.linode.com/v4/networking/ips/${MAIL_IP}" 2>/dev/null)

    if echo "$result" | grep -q "rdns"; then
        print_ok "Reverse DNS configured: ${MAIL_IP} → ${MAIL_HOSTNAME}"
    else
        print_error "Failed to set rDNS"
        echo "$result"
        return 1
    fi
}

check_ptr() {
    echo -n "E05 PTR: "
    local ptr=$(dig -x "${MAIL_IP}" +short 2>/dev/null | sed 's/\.$//')
    if [ "$ptr" = "$MAIL_HOSTNAME" ]; then
        echo -e "${GREEN}OK${NC} (${MAIL_IP} → ${ptr})"
        return 0
    elif [ -n "$ptr" ]; then
        echo -e "${YELLOW}MISMATCH${NC} (${ptr}, expected ${MAIL_HOSTNAME})"
        return 1
    else
        echo -e "${RED}MISSING${NC}"
        return 1
    fi
}

################################################################################
# E08: MX Record
################################################################################

setup_mx() {
    print_header "E08: Configuring MX Record"

    if $SKIP_DNS; then
        print_warning "Skipping DNS configuration (--skip-dns)"
        return 0
    fi

    if [ -z "${LINODE_TOKEN:-}" ]; then
        print_error "No Linode API token - run setup_spf first"
        return 1
    fi

    # Check for existing MX record
    local existing_mx=$(curl -s -H "Authorization: Bearer $LINODE_TOKEN" \
        "https://api.linode.com/v4/domains/${LINODE_DOMAIN_ID}/records" | \
        python3 -c "import sys,json; records=json.load(sys.stdin)['data']; print(next((r['id'] for r in records if r['type']=='MX'), ''))" 2>/dev/null)

    if [ -n "$existing_mx" ]; then
        print_info "Updating existing MX record..."
        curl -s -X PUT -H "Authorization: Bearer $LINODE_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"target\": \"${MAIL_HOSTNAME}\", \"priority\": 10}" \
            "https://api.linode.com/v4/domains/${LINODE_DOMAIN_ID}/records/${existing_mx}" > /dev/null
    else
        print_info "Creating MX record..."
        curl -s -X POST -H "Authorization: Bearer $LINODE_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"type\": \"MX\", \"name\": \"\", \"target\": \"${MAIL_HOSTNAME}\", \"priority\": 10, \"ttl_sec\": 300}" \
            "https://api.linode.com/v4/domains/${LINODE_DOMAIN_ID}/records" > /dev/null
    fi

    print_ok "MX record configured: ${DOMAIN} → ${MAIL_HOSTNAME} (priority 10)"
}

check_mx() {
    echo -n "E08 MX: "
    local mx=$(dig MX "${DOMAIN}" +short 2>/dev/null)
    if [ -n "$mx" ]; then
        echo -e "${GREEN}OK${NC} ($mx)"
        return 0
    else
        echo -e "${RED}MISSING${NC}"
        return 1
    fi
}

################################################################################
# E09: GitLab Email Configuration
################################################################################

setup_gitlab_email() {
    print_header "E09: Configuring GitLab Email"

    if [ ! -f /etc/gitlab/gitlab.rb ]; then
        print_warning "GitLab not found on this server"
        return 0
    fi

    print_info "Updating GitLab email configuration..."

    # Backup
    cp /etc/gitlab/gitlab.rb /etc/gitlab/gitlab.rb.backup.$(date +%Y%m%d_%H%M%S)

    # Update email settings
    gitlab_config="/etc/gitlab/gitlab.rb"

    # Email from address
    sed -i "s|^# gitlab_rails\['gitlab_email_from'\].*|gitlab_rails['gitlab_email_from'] = 'git@${DOMAIN}'|" "$gitlab_config"
    sed -i "s|^gitlab_rails\['gitlab_email_from'\].*|gitlab_rails['gitlab_email_from'] = 'git@${DOMAIN}'|" "$gitlab_config"

    # Email display name
    if ! grep -q "gitlab_email_display_name" "$gitlab_config"; then
        echo "gitlab_rails['gitlab_email_display_name'] = 'NWP GitLab'" >> "$gitlab_config"
    fi

    # Reply-to address
    sed -i "s|^# gitlab_rails\['gitlab_email_reply_to'\].*|gitlab_rails['gitlab_email_reply_to'] = 'noreply@${DOMAIN}'|" "$gitlab_config"
    sed -i "s|^gitlab_rails\['gitlab_email_reply_to'\].*|gitlab_rails['gitlab_email_reply_to'] = 'noreply@${DOMAIN}'|" "$gitlab_config"

    # SMTP settings (local Postfix)
    cat >> "$gitlab_config" << EOF

# SMTP settings for local Postfix (added by setup_email.sh)
gitlab_rails['smtp_enable'] = true
gitlab_rails['smtp_address'] = "localhost"
gitlab_rails['smtp_port'] = 25
gitlab_rails['smtp_domain'] = "${DOMAIN}"
gitlab_rails['smtp_tls'] = false
gitlab_rails['smtp_openssl_verify_mode'] = 'none'
gitlab_rails['smtp_enable_starttls_auto'] = false
EOF

    print_info "Reconfiguring GitLab (this may take a few minutes)..."
    gitlab-ctl reconfigure

    print_ok "GitLab email configured"
}

################################################################################
# Status Check
################################################################################

check_all() {
    print_header "Email Configuration Status"

    local issues=0

    check_postfix || issues=$((issues + 1))
    check_spf || issues=$((issues + 1))
    check_opendkim || issues=$((issues + 1))
    check_dmarc || issues=$((issues + 1))
    check_ptr || issues=$((issues + 1))
    check_mx || issues=$((issues + 1))

    echo ""
    if [ $issues -eq 0 ]; then
        print_ok "All checks passed! Ready for mail-tester.com verification"
    else
        print_warning "$issues issue(s) found"
        echo ""
        echo "Run: $0 --help for setup options"
    fi

    return $issues
}

################################################################################
# Main
################################################################################

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --check|-c)
                CHECK_ONLY=true
                shift
                ;;
            --dns-only)
                DNS_ONLY=true
                shift
                ;;
            --skip-dns)
                SKIP_DNS=true
                shift
                ;;
            --help|-h)
                show_help
                ;;
            *)
                print_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    echo "════════════════════════════════════════════════════════════════"
    echo "  NWP Email Infrastructure Setup"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    echo "Domain:       ${DOMAIN}"
    echo "Mail Host:    ${MAIL_HOSTNAME}"
    echo "Mail IP:      ${MAIL_IP}"
    echo "DKIM Selector: ${DKIM_SELECTOR}"
    echo ""

    if $CHECK_ONLY; then
        check_all
        exit $?
    fi

    if $DNS_ONLY; then
        setup_spf
        setup_dmarc
        setup_ptr
        setup_mx
        echo ""
        print_ok "DNS records configured"
        exit 0
    fi

    # Full setup
    check_root

    setup_postfix
    setup_spf
    setup_opendkim
    setup_dmarc
    setup_ptr
    setup_mx
    setup_gitlab_email

    echo ""
    print_header "Setup Complete"
    check_all

    echo ""
    echo "Next steps:"
    echo "  1. Wait 5-10 minutes for DNS propagation"
    echo "  2. Test with: echo 'Test' | mail -s 'Test' your@email.com"
    echo "  3. Check score at: https://www.mail-tester.com/"
    echo ""
}

main "$@"
