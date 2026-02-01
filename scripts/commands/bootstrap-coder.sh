#!/bin/bash

################################################################################
# NWP Coder Identity Bootstrap
#
# Automatically configures a new coder's NWP installation with:
#   - Coder identity detection and validation
#   - nwp.yml configuration from example
#   - Git user configuration
#   - SSH key setup for GitLab
#   - DNS and infrastructure verification
#
# Usage:
#   ./bootstrap-coder.sh              # Interactive mode
#   ./bootstrap-coder.sh --coder john # With known identity
#   ./bootstrap-coder.sh --help       # Show help
################################################################################

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/cli-register.sh"

# Configuration files
CONFIG_FILE="$PROJECT_ROOT/nwp.yml"
EXAMPLE_CONFIG="$PROJECT_ROOT/example.nwp.yml"
SECRETS_FILE="$PROJECT_ROOT/.secrets.yml"
EXAMPLE_SECRETS="$PROJECT_ROOT/.secrets.example.yml"

################################################################################
# Helper Functions
################################################################################

# Print usage
usage() {
    cat << EOF
NWP Coder Identity Bootstrap

Usage: $(basename "$0") [OPTIONS]

Automatically configures your NWP installation with your coder identity.

OPTIONS:
    --coder NAME       Use specified coder name (skip detection)
    --dry-run          Show what would be done without making changes
    -h, --help         Show this help message

DESCRIPTION:
    This script automates the configuration of a new coder's NWP installation by:

    1. Detecting or prompting for your coder identity
    2. Validating your identity against GitLab and DNS
    3. Configuring nwp.yml with your subdomain
    4. Setting up git configuration
    5. Verifying SSH keys for GitLab
    6. Checking infrastructure readiness
    7. Registering CLI command

EXAMPLES:
    # Interactive mode (recommended)
    ./bootstrap-coder.sh

    # With known identity
    ./bootstrap-coder.sh --coder john

    # Dry run to see what would happen
    ./bootstrap-coder.sh --dry-run

SEE ALSO:
    docs/guides/coder-onboarding.md
    docs/proposals/CODER_IDENTITY_BOOTSTRAP.md

EOF
}

# Get base domain from example.nwp.yml
get_base_domain_from_example() {
    if [ ! -f "$EXAMPLE_CONFIG" ]; then
        echo "nwpcode.org"
        return 1
    fi

    local domain
    domain=$(awk '
        /^settings:/ { in_settings = 1; next }
        in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
        in_settings && /^  url:/ {
            sub(/^  url: */, "")
            sub(/#.*/, "")
            gsub(/["'"'"']/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if (length($0) > 0) print
            exit
        }
    ' "$EXAMPLE_CONFIG")

    echo "${domain:-nwpcode.org}"
}

# Simple confirmation prompt
confirm() {
    local prompt="$1"
    local response
    read -p "$prompt [y/N]: " response
    [[ "$response" =~ ^[yY]$ ]]
}

################################################################################
# Identity Detection Functions
################################################################################

# Detect coder from GitLab SSH (if they added their key already)
detect_from_gitlab_ssh() {
    local base_domain="$1"
    local gitlab_url="git.${base_domain}"

    # Test SSH connection
    local ssh_response
    ssh_response=$(ssh -T -o BatchMode=yes -o ConnectTimeout=5 \
        "git@${gitlab_url}" 2>&1 || true)

    # GitLab responds with: "Welcome to GitLab, @username!"
    if echo "$ssh_response" | grep -q "Welcome to GitLab"; then
        local username
        username=$(echo "$ssh_response" | sed -n 's/.*@\([a-zA-Z0-9_-]*\).*/\1/p' | head -1)
        if [ -n "$username" ]; then
            echo "$username"
            return 0
        fi
    fi

    return 1
}

# Detect coder from DNS (which subdomain points to this server)
detect_from_dns() {
    local base_domain="$1"

    # Get this server's public IP
    local server_ip
    server_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || \
                curl -s --max-time 5 icanhazip.com 2>/dev/null || \
                curl -s --max-time 5 ipecho.net/plain 2>/dev/null)

    if [ -z "$server_ip" ]; then
        return 1
    fi

    info "Server IP detected: $server_ip"

    # Note: Full DNS reverse lookup would require querying all registered coders
    # or pattern matching common names. This is a placeholder for future enhancement.
    # For now, we'll rely on GitLab SSH or interactive prompt.

    return 1
}

# Detect coder identity using multiple methods
detect_coder_identity() {
    local base_domain="$1"
    local coder_name=""

    # Method 1: Try GitLab SSH authentication
    info "Attempting GitLab SSH authentication..."
    coder_name=$(detect_from_gitlab_ssh "$base_domain")
    if [ -n "$coder_name" ]; then
        pass "Detected from GitLab SSH: $coder_name"
        if confirm "Use identity '$coder_name'?"; then
            echo "$coder_name"
            return 0
        fi
    else
        info "Could not detect identity from GitLab SSH"
        info "(This is normal if you haven't added your SSH key yet)"
    fi

    # Method 2: Try DNS reverse lookup
    info "Attempting DNS-based detection..."
    coder_name=$(detect_from_dns "$base_domain")
    if [ -n "$coder_name" ]; then
        pass "Detected from DNS: $coder_name"
        if confirm "Use identity '$coder_name'?"; then
            echo "$coder_name"
            return 0
        fi
    fi

    # Method 3: Interactive prompt
    echo ""
    print_header "Enter Your Coder Identity"
    info "Please enter your registered coder name"
    info "This should match the name the administrator registered for you"
    info "Example: If your subdomain is john.nwpcode.org, enter 'john'"
    echo ""
    read -p "Coder name: " coder_name

    # Validate format
    if [[ -z "$coder_name" ]]; then
        print_error "Coder name cannot be empty"
        return 1
    fi

    if [[ ! "$coder_name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        print_error "Invalid coder name format"
        print_error "Must start with a letter and contain only alphanumeric, underscore, or hyphen"
        return 1
    fi

    echo "$coder_name"
}

################################################################################
# Validation Functions
################################################################################

# Check if GitLab user exists
check_gitlab_user_exists() {
    local username="$1"
    local gitlab_url="$2"

    # Try SSH test first
    local ssh_response
    ssh_response=$(ssh -T -o BatchMode=yes -o ConnectTimeout=5 \
        "git@${gitlab_url}" 2>&1 || true)

    if echo "$ssh_response" | grep -q "Welcome to GitLab.*@${username}"; then
        return 0
    fi

    # Try HTTPS API (public endpoint, no auth needed)
    local api_response
    api_response=$(curl -sf --max-time 5 "https://${gitlab_url}/api/v4/users?username=${username}" 2>/dev/null || echo "[]")

    if echo "$api_response" | grep -q "\"username\":\"${username}\""; then
        return 0
    fi

    return 1
}

# Check NS delegation
check_ns_delegation() {
    local name="$1"
    local base_domain="$2"
    local subdomain="${name}.${base_domain}"

    local ns
    ns=$(dig NS "$subdomain" +short +time=2 +tries=1 2>/dev/null | head -1)

    if [ -n "$ns" ]; then
        return 0
    fi

    return 1
}

# Check DNS A record
check_dns_a_record() {
    local name="$1"
    local base_domain="$2"
    local subdomain="${name}.${base_domain}"

    local ip
    ip=$(dig A "$subdomain" +short +time=2 +tries=1 2>/dev/null | head -1)

    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    fi

    return 1
}

# Validate coder identity against GitLab and admin registration
validate_coder_identity() {
    local coder_name="$1"
    local base_domain="$2"
    local gitlab_url="git.${base_domain}"
    local has_warnings=false

    echo ""
    print_header "Validating Identity: $coder_name"

    # Check 1: GitLab user exists
    info "Checking GitLab account..."
    if check_gitlab_user_exists "$coder_name" "$gitlab_url"; then
        pass "GitLab account exists for '$coder_name'"
    else
        warn "GitLab account not found for '$coder_name'"
        info "You may need to:"
        info "  - Add your SSH key to GitLab: https://$gitlab_url/-/profile/keys"
        info "  - Contact administrator to verify your account was created"
        has_warnings=true
    fi

    # Check 2: DNS delegation exists
    info "Checking NS delegation..."
    if check_ns_delegation "$coder_name" "$base_domain"; then
        pass "NS delegation configured for ${coder_name}.${base_domain}"
    else
        warn "NS delegation not found for ${coder_name}.${base_domain}"
        warn "Contact administrator to run: ./coder-setup.sh add $coder_name"
        info "DNS propagation can take 24-48 hours"
        has_warnings=true
    fi

    # Check 3: DNS A records (if delegation exists)
    info "Checking DNS A records..."
    if check_dns_a_record "$coder_name" "$base_domain"; then
        local ip
        ip=$(dig A "${coder_name}.${base_domain}" +short | head -1)
        pass "DNS A record configured: ${coder_name}.${base_domain} -> $ip"
    else
        warn "DNS A records not configured"
        info "You'll need to add these in Linode DNS Manager"
        info "See: docs/guides/coder-onboarding.md Step 6"
        has_warnings=true
    fi

    if $has_warnings; then
        echo ""
        warn "Identity validation completed with warnings"
        info "You can still proceed - warnings are informational only"
        echo ""
        if ! confirm "Continue with bootstrap?"; then
            print_error "Bootstrap cancelled by user"
            exit 1
        fi
    fi

    echo ""
}

################################################################################
# Configuration Functions
################################################################################

# Configure nwp.yml with detected identity
configure_nwp() {
    local coder_name="$1"
    local base_domain="$2"
    local dry_run="$3"

    print_header "Configuring NWP Installation"

    local subdomain="${coder_name}.${base_domain}"

    # Check if nwp.yml already exists
    if [ -f "$CONFIG_FILE" ]; then
        warn "Existing nwp.yml found"

        # Check if it already has the correct identity
        local existing_url
        existing_url=$(awk '
            /^settings:/ { in_settings = 1; next }
            in_settings && /^[a-zA-Z]/ && !/^  / { in_settings = 0 }
            in_settings && /^  url:/ {
                sub(/^  url: */, "")
                sub(/#.*/, "")
                gsub(/["'"'"']/, "")
                gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                print
                exit
            }
        ' "$CONFIG_FILE")

        if [ "$existing_url" == "$subdomain" ]; then
            pass "nwp.yml already configured with correct identity: $subdomain"
            return 0
        fi

        if ! confirm "Overwrite with new configuration for '$coder_name'?"; then
            info "Skipping nwp.yml configuration"
            return 0
        fi

        if [ "$dry_run" != "true" ]; then
            local backup_file="nwp.yml.backup.$(date +%Y%m%d_%H%M%S)"
            mv "$CONFIG_FILE" "$PROJECT_ROOT/$backup_file"
            pass "Backed up existing config to: $backup_file"
        else
            info "[DRY-RUN] Would backup existing nwp.yml"
        fi
    fi

    # Copy example and configure
    if [ "$dry_run" != "true" ]; then
        cp "$EXAMPLE_CONFIG" "$CONFIG_FILE"

        # Set identity in nwp.yml
        if command -v yq &>/dev/null; then
            yq -i ".settings.url = \"$subdomain\"" "$CONFIG_FILE"
            yq -i ".settings.email.domain = \"$subdomain\"" "$CONFIG_FILE"
            yq -i ".settings.email.admin_email = \"admin@${subdomain}\"" "$CONFIG_FILE"
        else
            # Fallback: sed
            sed -i "s|url: nwpcode.org|url: $subdomain|" "$CONFIG_FILE"
            sed -i "s|domain: nwpcode.org|domain: $subdomain|" "$CONFIG_FILE"
            sed -i "s|admin_email: admin@example.com|admin_email: admin@$subdomain|" "$CONFIG_FILE"
        fi

        pass "Configured nwp.yml with identity: $coder_name"
        info "  Domain: $subdomain"
    else
        info "[DRY-RUN] Would create nwp.yml from example"
        info "[DRY-RUN] Would set settings.url to: $subdomain"
    fi

    # Setup .secrets.yml
    if [ ! -f "$SECRETS_FILE" ]; then
        if [ "$dry_run" != "true" ]; then
            cp "$EXAMPLE_SECRETS" "$SECRETS_FILE"
            pass "Created .secrets.yml from example"
        else
            info "[DRY-RUN] Would create .secrets.yml from example"
        fi
        warn "You'll need to add your Linode API token to .secrets.yml"
        info "Get token from: https://cloud.linode.com/profile/tokens"
    else
        info ".secrets.yml already exists"
    fi

    echo ""
}

# Setup git global config
setup_git_config() {
    local coder_name="$1"
    local base_domain="$2"
    local dry_run="$3"

    print_header "Configuring Git"

    local subdomain="${coder_name}.${base_domain}"

    # Check if git user is already configured
    local current_name
    local current_email
    current_name=$(git config --global user.name 2>/dev/null || echo "")
    current_email=$(git config --global user.email 2>/dev/null || echo "")

    if [ -n "$current_name" ] && [ -n "$current_email" ]; then
        info "Git already configured as: $current_name <$current_email>"
        if confirm "Keep existing git configuration?"; then
            pass "Keeping existing git configuration"
            return 0
        fi
    fi

    # Set git config
    if [ "$dry_run" != "true" ]; then
        git config --global user.name "$coder_name"
        git config --global user.email "git@${subdomain}"
        pass "Configured git as: $coder_name <git@${subdomain}>"
    else
        info "[DRY-RUN] Would set git config:"
        info "  user.name: $coder_name"
        info "  user.email: git@${subdomain}"
    fi

    echo ""
}

################################################################################
# Verification Functions
################################################################################

# Verify infrastructure readiness
verify_infrastructure() {
    local coder_name="$1"
    local base_domain="$2"

    print_header "Infrastructure Verification"

    local subdomain="${coder_name}.${base_domain}"
    local gitlab_url="git.${base_domain}"

    # DNS checks
    info "DNS Status:"
    if dig NS "$subdomain" +short 2>/dev/null | grep -q .; then
        local ns_servers
        ns_servers=$(dig NS "$subdomain" +short 2>/dev/null | tr '\n' ' ')
        pass "  NS delegation: $ns_servers"
    else
        warn "  NS delegation: Not propagated (may take 24-48 hours)"
    fi

    local server_ip
    server_ip=$(dig A "$subdomain" +short 2>/dev/null | head -1)
    if [ -n "$server_ip" ]; then
        pass "  A record: $subdomain -> $server_ip"
    else
        warn "  A record: Not configured yet"
        info "  Configure in Linode: https://cloud.linode.com/domains"
    fi

    echo ""

    # GitLab checks
    info "GitLab Status:"
    if curl -sf --max-time 5 "https://${gitlab_url}" >/dev/null 2>&1; then
        pass "  GitLab reachable: https://$gitlab_url"
    else
        warn "  GitLab not reachable: https://$gitlab_url"
        info "  Check your network connection or DNS configuration"
    fi

    echo ""

    # SSH key check
    info "SSH Keys:"
    local has_key=false
    if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
        pass "  ED25519 key exists: $HOME/.ssh/id_ed25519.pub"
        has_key=true
    elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
        pass "  RSA key exists: $HOME/.ssh/id_rsa.pub"
        has_key=true
    fi

    if $has_key; then
        warn "  Make sure to add your public key to GitLab!"
        info "  GitLab SSH Keys: https://$gitlab_url/-/profile/keys"
    else
        warn "  No SSH key found"
        if confirm "Generate SSH key pair now?"; then
            ssh-keygen -t ed25519 -C "git@${subdomain}" -f "$HOME/.ssh/id_ed25519" -N ""
            pass "  Generated SSH key: $HOME/.ssh/id_ed25519"
            echo ""
            info "  Add this public key to GitLab:"
            info "  https://$gitlab_url/-/profile/keys"
            echo ""
            cat "$HOME/.ssh/id_ed25519.pub"
            echo ""
        fi
    fi

    echo ""
}

# Register CLI command for this NWP installation
register_cli_for_coder() {
    local coder_name="$1"
    local dry_run="$2"

    print_header "Registering CLI Command"

    # Try to register a command named after the coder first
    local cli_command="$coder_name"

    # Check if that command is available
    if command -v "$cli_command" &>/dev/null; then
        info "Command '$cli_command' already exists, finding alternative..."
        cli_command=$(find_available_cli_command)
    fi

    if [ "$dry_run" != "true" ]; then
        if register_cli_command "$PROJECT_ROOT" "$cli_command" 2>/dev/null; then
            pass "Registered CLI command: $cli_command"
            info "Use '$cli_command' to run NWP commands from anywhere"

            # Update nwp.yml with the CLI command
            if command -v yq &>/dev/null && [ -f "$CONFIG_FILE" ]; then
                yq -i ".settings.cli_command = \"$cli_command\"" "$CONFIG_FILE"
            fi
        else
            warn "Could not register CLI command (requires sudo)"
            info "You can still use ./pl from the NWP directory"
        fi
    else
        info "[DRY-RUN] Would register CLI command: $cli_command"
    fi

    echo ""
}

################################################################################
# Claude API Setup
################################################################################

# Setup Claude API key for coder (F14)
setup_claude_api() {
    local coder_name="$1"
    local dry_run="$2"

    # Check if Claude integration is enabled
    if ! is_claude_enabled "$CONFIG_FILE" 2>/dev/null; then
        info "Claude API integration not enabled (set settings.claude.enabled: true to enable)"
        return 0
    fi

    print_header "Claude API Setup"

    source "$PROJECT_ROOT/lib/claude-api.sh"

    # Get or create workspace
    local workspace_id
    workspace_id=$(awk '/^settings:/{found=1} found && /claude:/{in_claude=1} in_claude && /workspace_id:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null)

    if [[ -z "$workspace_id" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            info "[DRY-RUN] Would create Claude workspace 'nwp'"
            info "[DRY-RUN] Would provision API key for ${coder_name}"
            return 0
        fi

        workspace_id=$(create_nwp_workspace "nwp")
        if [[ -z "$workspace_id" ]]; then
            warn "Could not create Claude workspace - skipping API setup"
            info "You can configure Claude API manually later"
            return 0
        fi
    fi

    # Provision coder API key
    if [[ "$dry_run" == "true" ]]; then
        info "[DRY-RUN] Would provision Claude API key for ${coder_name}"
        return 0
    fi

    local api_key
    api_key=$(provision_coder_api_key "$coder_name" "$workspace_id")

    if [[ -n "$api_key" ]]; then
        # Write ANTHROPIC_API_KEY to coder's environment
        local env_file="$HOME/.nwp_env"
        if [[ -f "$env_file" ]]; then
            # Remove existing ANTHROPIC_API_KEY if present
            sed -i '/^export ANTHROPIC_API_KEY=/d' "$env_file"
        fi
        echo "export ANTHROPIC_API_KEY=\"${api_key}\"" >> "$env_file"
        pass "Claude API key written to ${env_file}"
        info "Source it with: source ${env_file}"
    else
        warn "Could not provision Claude API key - you can set it up manually later"
    fi

    echo ""
}

################################################################################
# Next Steps Display
################################################################################

# Show next steps after bootstrap
show_next_steps() {
    local coder_name="$1"
    local base_domain="$2"

    local subdomain="${coder_name}.${base_domain}"
    local gitlab_url="git.${base_domain}"

    print_header "Bootstrap Complete!"

    pass "Your NWP installation is configured as: $coder_name"
    info "Subdomain: $subdomain"
    echo ""

    print_header "Next Steps"
    echo ""
    echo "1. Add Linode API Token"
    echo "   Edit: .secrets.yml"
    echo "   Get token: https://cloud.linode.com/profile/tokens"
    echo "   Permissions needed: Domains (Read/Write), Linodes (Read/Write)"
    echo ""

    echo "2. Add SSH Key to GitLab"
    echo "   Go to: https://$gitlab_url/-/profile/keys"
    if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
        echo "   Your public key:"
        echo "   $(cat $HOME/.ssh/id_ed25519.pub)"
    elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
        echo "   Your public key:"
        echo "   $(cat $HOME/.ssh/id_rsa.pub)"
    fi
    echo ""

    echo "3. Configure DNS A Records in Linode"
    echo "   Go to: https://cloud.linode.com/domains"
    echo "   Domain: $subdomain"
    echo "   Add A records:"
    echo "     @ (root)    -> Your server IP"
    echo "     git         -> Your server IP"
    echo "     * (wildcard)-> Your server IP"
    echo "   See: docs/guides/coder-onboarding.md Step 6"
    echo ""

    echo "4. Test Your Setup"
    echo "   SSH to GitLab: ssh -T git@$gitlab_url"
    echo "   Should see: Welcome to GitLab, @$coder_name!"
    echo ""

    echo "5. Create Your First Site"
    echo "   ./pl install d mysite"
    echo "   Access: https://mysite.${subdomain}"
    echo ""

    echo "Documentation:"
    echo "  Onboarding: docs/guides/coder-onboarding.md"
    echo "  Commands:   docs/reference/commands/README.md"
    echo ""
}

################################################################################
# Main Function
################################################################################

main() {
    local provided_coder=""
    local dry_run=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --coder)
                provided_coder="$2"
                shift 2
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Welcome
    clear
    print_header "NWP Coder Identity Bootstrap"
    echo ""
    info "This script will configure your NWP installation with your coder identity"
    echo ""

    if $dry_run; then
        warn "DRY-RUN MODE: No changes will be made"
        echo ""
    fi

    # Get base domain from example config
    local base_domain
    base_domain=$(get_base_domain_from_example)
    info "Base domain: $base_domain"
    echo ""

    # Step 1: Detect or use provided identity
    local coder_name
    if [ -n "$provided_coder" ]; then
        coder_name="$provided_coder"
        info "Using provided identity: $coder_name"
    else
        coder_name=$(detect_coder_identity "$base_domain")
        if [ -z "$coder_name" ]; then
            print_error "Could not determine coder identity"
            exit 1
        fi
    fi

    # Step 2: Validate identity
    validate_coder_identity "$coder_name" "$base_domain"

    # Step 3: Configure NWP
    configure_nwp "$coder_name" "$base_domain" "$dry_run"

    # Step 4: Setup git
    setup_git_config "$coder_name" "$base_domain" "$dry_run"

    # Step 5: Verify infrastructure
    verify_infrastructure "$coder_name" "$base_domain"

    # Step 6: Register CLI command
    register_cli_for_coder "$coder_name" "$dry_run"

    # Step 7: Setup Claude API (F14)
    setup_claude_api "$coder_name" "$dry_run"

    # Step 8: Show next steps
    show_next_steps "$coder_name" "$base_domain"

    if $dry_run; then
        echo ""
        warn "DRY-RUN completed - no changes were made"
        info "Run without --dry-run to apply configuration"
    fi
}

# Run main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
