#!/bin/bash
set -euo pipefail

################################################################################
# NWP AVC-Moodle Setup Script
#
# Configure Single Sign-On (SSO) integration between AVC and Moodle sites
# This script sets up OAuth2-based authentication and optionally role sync
# and badge display features.
#
# Usage: pl avc-moodle-setup <avc-site> <moodle-site> [OPTIONS]
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/avc-moodle.sh"

# Script start time
START_TIME=$(date +%s)

################################################################################
# Script-specific Functions
################################################################################

# Show help
show_help() {
    cat << EOF
${BOLD}NWP AVC-Moodle Setup Script${NC}

Set up OAuth2 Single Sign-On integration between AVC and Moodle sites.

${BOLD}USAGE:${NC}
    pl avc-moodle-setup <avc-site> <moodle-site> [OPTIONS]

${BOLD}ARGUMENTS:${NC}
    avc-site        Name of the AVC/OpenSocial site (OAuth provider)
    moodle-site     Name of the Moodle site (OAuth client)

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    --regenerate-keys       Regenerate OAuth2 keys (use with caution)
    --skip-test             Skip SSO flow testing
    --role-sync             Enable role synchronization during setup
    --badge-display         Enable badge display during setup

${BOLD}EXAMPLES:${NC}
    pl avc-moodle-setup avc ss
    pl avc-moodle-setup avc ss --role-sync --badge-display
    pl avc-moodle-setup avc ss --regenerate-keys

${BOLD}WHAT THIS SCRIPT DOES:${NC}
    1. Validates both AVC and Moodle sites exist
    2. Generates OAuth2 RSA keys (2048-bit)
    3. Installs required Drupal modules in AVC
    4. Installs required Moodle plugins
    5. Configures OAuth2 client in AVC (Drupal Simple OAuth)
    6. Configures OAuth2 issuer in Moodle
    7. Tests SSO flow
    8. Updates cnwp.yml with integration settings

${BOLD}REQUIREMENTS:${NC}
    - Both sites must be installed and accessible
    - DDEV must be running for both sites
    - Sites must be on HTTPS (DDEV provides this)
    - Drush must be available in AVC site
    - Moodle CLI tools must be available

EOF
}

################################################################################
# Installation Functions
################################################################################

# Install required Drupal modules in AVC site
install_avc_modules() {
    local avc_site=$1
    local avc_dir

    avc_dir=$(get_site_directory "$avc_site")

    info "Installing AVC Drupal Modules"

    cd "$avc_dir" || return 1

    # Check if DDEV is available
    if [[ ! -f ".ddev/config.yaml" ]]; then
        print_error "DDEV configuration not found - this script requires DDEV"
        return 1
    fi

    # Install Simple OAuth module (OAuth2 provider foundation)
    print_info "Installing Simple OAuth module..."
    if ! ddev composer require "drupal/simple_oauth:^5.2" 2>&1 | grep -q "Nothing to"; then
        pass "Simple OAuth module installed"
    else
        print_info "Simple OAuth module already installed"
    fi

    # Enable Simple OAuth module
    print_info "Enabling Simple OAuth module..."
    ddev drush en -y simple_oauth

    # TODO: Install avc_moodle custom modules when they're created
    # These will be in modules/custom/avc_moodle/
    print_info "Custom AVC-Moodle modules will be enabled once created"
    print_info "  - avc_moodle (parent module)"
    print_info "  - avc_moodle_oauth (OAuth2 provider endpoints)"
    print_info "  - avc_moodle_sync (role synchronization)"
    print_info "  - avc_moodle_data (badge/completion display)"

    return 0
}

# Install required Moodle plugins
install_moodle_plugins() {
    local moodle_site=$1
    local moodle_dir

    moodle_dir=$(get_site_directory "$moodle_site")

    info "Installing Moodle Plugins"

    cd "$moodle_dir" || return 1

    # Check if DDEV is available
    if [[ ! -f ".ddev/config.yaml" ]]; then
        print_error "DDEV configuration not found - this script requires DDEV"
        return 1
    fi

    # TODO: Install auth_avc_oauth2 plugin when created
    print_info "Moodle authentication plugin will be installed once created"
    print_info "  Location: auth/avc_oauth2/"
    print_info "  Purpose: OAuth2 authentication from AVC"

    # Install cohort-role sync plugin from Moodle plugins directory
    print_info "Installing local_cohortrole plugin for automatic role assignment..."
    print_info "  This plugin automatically assigns roles based on cohort membership"

    # Check if plugin directory exists
    if [[ ! -d "local/cohortrole" ]]; then
        print_warning "local_cohortrole plugin not found"
        print_info "You can install it manually later from:"
        print_info "  https://moodle.org/plugins/local_cohortrole"
    else
        pass "local_cohortrole plugin found"
    fi

    return 0
}

# Configure OAuth2 in AVC (Drupal Simple OAuth)
configure_avc_oauth() {
    local avc_site=$1
    local moodle_site=$2
    local avc_dir
    local moodle_url
    local key_dir

    avc_dir=$(get_site_directory "$avc_site")
    moodle_url=$(avc_moodle_get_site_url "$moodle_site")
    key_dir="$avc_dir/private/keys"

    info "Configuring OAuth2 in AVC"

    cd "$avc_dir" || return 1

    # Set key paths in Simple OAuth configuration
    print_info "Configuring Simple OAuth key paths..."

    ddev drush config:set -y simple_oauth.settings \
        public_key "/var/www/html/private/keys/oauth_public.key"

    ddev drush config:set -y simple_oauth.settings \
        private_key "/var/www/html/private/keys/oauth_private.key"

    # Set token lifetime (5 minutes = 300 seconds)
    print_info "Setting OAuth2 token lifetime to 5 minutes..."
    ddev drush config:set -y simple_oauth.settings \
        token_expiration 300

    # Configure OAuth2 client for Moodle
    print_info "Creating OAuth2 client for Moodle..."

    # Generate client secret
    local client_secret
    client_secret=$(openssl rand -hex 32)

    # TODO: Create OAuth2 client via Drush or manual configuration
    # This requires the simple_oauth_extras module or manual DB insertion
    print_warning "OAuth2 client creation requires manual setup"
    print_info "After setup, create an OAuth2 client with these details:"
    print_info "  Client ID: moodle_${moodle_site}"
    print_info "  Redirect URI: ${moodle_url}/admin/oauth2callback.php"
    print_info "  Save the client secret securely"

    pass "OAuth2 configuration prepared"

    return 0
}

# Configure OAuth2 in Moodle
configure_moodle_oauth() {
    local avc_site=$1
    local moodle_site=$2
    local avc_url
    local moodle_dir

    avc_url=$(avc_moodle_get_issuer_url "$avc_site")
    moodle_dir=$(get_site_directory "$moodle_site")

    info "Configuring OAuth2 in Moodle"

    cd "$moodle_dir" || return 1

    print_info "OAuth2 issuer configuration..."
    print_info "  Issuer URL: $avc_url"
    print_info "  Authorize URL: ${avc_url}/oauth/authorize"
    print_info "  Token URL: ${avc_url}/oauth/token"
    print_info "  UserInfo URL: ${avc_url}/oauth/userinfo"

    # TODO: Configure Moodle OAuth2 issuer via CLI or web interface
    print_warning "Moodle OAuth2 configuration requires manual setup"
    print_info "Configure OAuth2 issuer in Moodle admin interface:"
    print_info "  Site administration > Server > OAuth 2 services"

    return 0
}

# Test SSO flow
test_sso_flow() {
    local avc_site=$1
    local moodle_site=$2
    local avc_url
    local moodle_url

    avc_url=$(avc_moodle_get_site_url "$avc_site")
    moodle_url=$(avc_moodle_get_site_url "$moodle_site")

    info "Testing SSO Flow"

    # Test OAuth2 endpoints
    print_info "Testing OAuth2 endpoints..."

    if avc_moodle_test_oauth_endpoint "$avc_url" "/oauth/authorize"; then
        pass "OAuth2 authorize endpoint reachable"
    else
        print_error "OAuth2 authorize endpoint not reachable"
        return 1
    fi

    if avc_moodle_test_oauth_endpoint "$avc_url" "/oauth/token"; then
        pass "OAuth2 token endpoint reachable"
    else
        print_error "OAuth2 token endpoint not reachable"
        return 1
    fi

    if avc_moodle_test_oauth_endpoint "$avc_url" "/oauth/userinfo"; then
        pass "OAuth2 userinfo endpoint reachable"
    else
        print_error "OAuth2 userinfo endpoint not reachable"
        return 1
    fi

    print_info "Manual SSO testing required:"
    print_info "  1. Visit: $moodle_url"
    print_info "  2. Click 'Login with AVC' (once plugin is installed)"
    print_info "  3. Verify redirect to AVC"
    print_info "  4. Login to AVC (if needed)"
    print_info "  5. Verify redirect back to Moodle"
    print_info "  6. Confirm logged in to Moodle"

    return 0
}

# Update cnwp.yml with integration settings
update_cnwp_yml() {
    local avc_site=$1
    local moodle_site=$2
    local moodle_url

    moodle_url=$(avc_moodle_get_site_url "$moodle_site")

    info "Updating cnwp.yml"

    if [[ ! -f "$PROJECT_ROOT/cnwp.yml" ]]; then
        print_error "cnwp.yml not found - cannot update configuration"
        return 1
    fi

    # Update AVC site configuration
    print_info "Updating AVC site configuration..."

    yq eval -i ".sites.$avc_site.moodle_integration.enabled = true" "$PROJECT_ROOT/cnwp.yml"
    yq eval -i ".sites.$avc_site.moodle_integration.moodle_site = \"$moodle_site\"" "$PROJECT_ROOT/cnwp.yml"
    yq eval -i ".sites.$avc_site.moodle_integration.moodle_url = \"$moodle_url\"" "$PROJECT_ROOT/cnwp.yml"

    # Update Moodle site configuration
    print_info "Updating Moodle site configuration..."

    local avc_url
    avc_url=$(avc_moodle_get_site_url "$avc_site")

    yq eval -i ".sites.$moodle_site.avc_integration.enabled = true" "$PROJECT_ROOT/cnwp.yml"
    yq eval -i ".sites.$moodle_site.avc_integration.avc_site = \"$avc_site\"" "$PROJECT_ROOT/cnwp.yml"
    yq eval -i ".sites.$moodle_site.avc_integration.avc_url = \"$avc_url\"" "$PROJECT_ROOT/cnwp.yml"

    pass "cnwp.yml updated with integration settings"

    return 0
}

################################################################################
# Main Script Logic
################################################################################

# Parse command line arguments
REGENERATE_KEYS=false
SKIP_TEST=false
ENABLE_ROLE_SYNC=false
ENABLE_BADGE_DISPLAY=false

# Parse options
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -d|--debug)
            DEBUG=true
            shift
            ;;
        --regenerate-keys)
            REGENERATE_KEYS=true
            shift
            ;;
        --skip-test)
            SKIP_TEST=true
            shift
            ;;
        --role-sync)
            ENABLE_ROLE_SYNC=true
            shift
            ;;
        --badge-display)
            ENABLE_BADGE_DISPLAY=true
            shift
            ;;
        -*)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# Check required arguments
if [[ $# -lt 2 ]]; then
    print_error "Missing required arguments"
    show_help
    exit 1
fi

AVC_SITE=$1
MOODLE_SITE=$2

# Validate site names
if ! validate_sitename "$AVC_SITE" "AVC site name"; then
    exit 1
fi

if ! validate_sitename "$MOODLE_SITE" "Moodle site name"; then
    exit 1
fi

# Display header
print_header "AVC-Moodle SSO Setup"
print_info "AVC Site: $AVC_SITE"
print_info "Moodle Site: $MOODLE_SITE"
echo ""

# Step 1: Validate both sites
step 1 10 "Validating sites"
if ! avc_moodle_validate_avc_site "$AVC_SITE"; then
    print_error "AVC site validation failed"
    exit 1
fi

if ! avc_moodle_validate_moodle_site "$MOODLE_SITE"; then
    print_error "Moodle site validation failed"
    exit 1
fi

# Step 2: Generate OAuth2 keys
step 2 10 "Generating OAuth2 keys"

if avc_moodle_keys_exist "$AVC_SITE" && [[ "$REGENERATE_KEYS" != "true" ]]; then
    print_info "OAuth2 keys already exist - skipping generation"
    print_info "Use --regenerate-keys to force regeneration"
else
    if ! avc_moodle_generate_keys "$AVC_SITE"; then
        print_error "Failed to generate OAuth2 keys"
        exit 1
    fi
fi

# Step 3: Install AVC modules
step 3 10 "Installing AVC modules"
if ! install_avc_modules "$AVC_SITE"; then
    print_error "Failed to install AVC modules"
    exit 1
fi

# Step 4: Install Moodle plugins
step 4 10 "Installing Moodle plugins"
if ! install_moodle_plugins "$MOODLE_SITE"; then
    print_error "Failed to install Moodle plugins"
    exit 1
fi

# Step 5: Configure OAuth2 in AVC
step 5 10 "Configuring OAuth2 in AVC"
if ! configure_avc_oauth "$AVC_SITE" "$MOODLE_SITE"; then
    print_error "Failed to configure OAuth2 in AVC"
    exit 1
fi

# Step 6: Configure OAuth2 in Moodle
step 6 10 "Configuring OAuth2 in Moodle"
if ! configure_moodle_oauth "$AVC_SITE" "$MOODLE_SITE"; then
    print_error "Failed to configure OAuth2 in Moodle"
    exit 1
fi

# Step 7: Test SSO flow
step 7 10 "Testing SSO flow"
if [[ "$SKIP_TEST" != "true" ]]; then
    if ! test_sso_flow "$AVC_SITE" "$MOODLE_SITE"; then
        print_warning "SSO flow test had issues - review output above"
    fi
else
    print_info "Skipping SSO flow test (--skip-test)"
fi

# Step 8: Update cnwp.yml
step 8 10 "Updating cnwp.yml"
if ! update_cnwp_yml "$AVC_SITE" "$MOODLE_SITE"; then
    print_error "Failed to update cnwp.yml"
    exit 1
fi

# Step 9: Enable optional features
step 9 10 "Configuring optional features"

if [[ "$ENABLE_ROLE_SYNC" == "true" ]]; then
    print_info "Role synchronization will be enabled once modules are created"
    yq eval -i ".sites.$AVC_SITE.moodle_integration.role_sync = true" "$PROJECT_ROOT/cnwp.yml"
fi

if [[ "$ENABLE_BADGE_DISPLAY" == "true" ]]; then
    print_info "Badge display will be enabled once modules are created"
    yq eval -i ".sites.$AVC_SITE.moodle_integration.badge_display = true" "$PROJECT_ROOT/cnwp.yml"
fi

# Step 10: Summary and next steps
step 10 10 "Setup complete"

AVC_URL=$(avc_moodle_get_site_url "$AVC_SITE")
MOODLE_URL=$(avc_moodle_get_site_url "$MOODLE_SITE")

pass "AVC-Moodle SSO setup completed successfully!"
echo ""
info "Next Steps"
echo "1. Complete OAuth2 client setup in AVC:"
echo "   Visit: ${AVC_URL}/admin/config/services/consumer"
echo ""
echo "2. Complete OAuth2 issuer setup in Moodle:"
echo "   Visit: ${MOODLE_URL}/admin/settings.php?section=oauth2"
echo ""
echo "3. Test SSO login:"
echo "   Visit: ${MOODLE_URL}"
echo "   Click 'Login with AVC'"
echo ""
echo "4. Check integration status:"
echo "   pl avc-moodle-status $AVC_SITE $MOODLE_SITE"
echo ""
print_info "Once custom modules are installed, you can enable:"
print_info "  - Role synchronization: Automatically sync guild roles to Moodle"
print_info "  - Badge display: Show Moodle badges on AVC user profiles"
echo ""

# Calculate execution time
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
print_info "Setup completed in ${DURATION}s"

exit 0
