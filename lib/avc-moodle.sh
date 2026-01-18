#!/bin/bash

################################################################################
# NWP AVC-Moodle Integration Library
#
# Shared functions for AVC-Moodle SSO, role synchronization, and data display
# integration between AV Commons (Drupal/OpenSocial) sites and Moodle LMS.
#
# Source this file: source "$PROJECT_ROOT/lib/avc-moodle.sh"
################################################################################

################################################################################
# Helper Functions
################################################################################

# Get site directory path
# Usage: get_site_directory "sitename"
# Returns: Full path to site directory
get_site_directory() {
    local site=$1
    local site_dir="${PROJECT_ROOT}/sites/${site}"

    if [[ -d "$site_dir" ]]; then
        echo "$site_dir"
        return 0
    else
        return 1
    fi
}

# Get site recipe from nwp.yml or by detection
# Usage: get_site_recipe "sitename"
# Returns: Recipe name (avc, m, os, etc.)
get_site_recipe() {
    local site=$1
    local cnwp_file="${PROJECT_ROOT}/nwp.yml"
    local recipe=""

    # Try to get from nwp.yml first
    if [[ -f "$cnwp_file" && -s "$cnwp_file" ]]; then
        if command -v yq &> /dev/null; then
            recipe=$(yq eval ".sites.${site}.recipe // empty" "$cnwp_file" 2>/dev/null)
        else
            # Fallback: simple grep
            recipe=$(grep -A 5 "^  ${site}:" "$cnwp_file" | grep "recipe:" | awk '{print $2}' | tr -d '"' | head -1)
        fi
    fi

    # If not found in nwp.yml, try to detect from directory structure
    if [[ -z "$recipe" ]]; then
        local site_dir
        if site_dir=$(get_site_directory "$site" 2>/dev/null); then
            # Check for Moodle
            if [[ -f "$site_dir/config.php" ]] && grep -q "moodle" "$site_dir/config.php" 2>/dev/null; then
                recipe="m"
            # Check for Drupal/OpenSocial
            elif [[ -f "$site_dir/composer.json" ]]; then
                if grep -q "goalgorilla/social" "$site_dir/composer.json" 2>/dev/null; then
                    recipe="os"
                elif grep -q "nwp/avc" "$site_dir/composer.json" 2>/dev/null; then
                    recipe="avc"
                elif grep -q "drupal/core" "$site_dir/composer.json" 2>/dev/null; then
                    recipe="d"
                fi
            fi
        fi
    fi

    if [[ -n "$recipe" ]]; then
        echo "$recipe"
        return 0
    fi

    return 1
}

################################################################################
# Validation Functions
################################################################################

# Validate that a site is an AVC or OpenSocial site
# Usage: avc_moodle_validate_avc_site "sitename"
# Returns: 0 if valid, 1 if invalid
avc_moodle_validate_avc_site() {
    local site=$1
    local site_dir

    # Validate sitename first
    if ! validate_sitename "$site" "AVC site name"; then
        return 1
    fi

    # Get site directory
    if ! site_dir=$(get_site_directory "$site" 2>/dev/null); then
        print_error "AVC site '$site' not found"
        return 1
    fi

    # Check if directory exists
    if [[ ! -d "$site_dir" ]]; then
        print_error "AVC site directory does not exist: $site_dir"
        return 1
    fi

    # Get recipe
    local recipe
    recipe=$(get_site_recipe "$site" 2>/dev/null)

    # Check if recipe is AVC or OpenSocial
    if [[ "$recipe" != "avc" && "$recipe" != "avc-dev" && "$recipe" != "os" ]]; then
        print_error "Site '$site' is not an AVC/OpenSocial site (recipe: ${recipe:-unknown})"
        return 1
    fi

    pass "Validated AVC site: $site (recipe: $recipe)"
    return 0
}

# Validate that a site is a Moodle site
# Usage: avc_moodle_validate_moodle_site "sitename"
# Returns: 0 if valid, 1 if invalid
avc_moodle_validate_moodle_site() {
    local site=$1
    local site_dir

    # Validate sitename first
    if ! validate_sitename "$site" "Moodle site name"; then
        return 1
    fi

    # Get site directory
    if ! site_dir=$(get_site_directory "$site" 2>/dev/null); then
        print_error "Moodle site '$site' not found"
        return 1
    fi

    # Check if directory exists
    if [[ ! -d "$site_dir" ]]; then
        print_error "Moodle site directory does not exist: $site_dir"
        return 1
    fi

    # Get recipe
    local recipe
    recipe=$(get_site_recipe "$site" 2>/dev/null)

    # Check if recipe is Moodle
    if [[ "$recipe" != "m" ]]; then
        print_error "Site '$site' is not a Moodle site (recipe: ${recipe:-unknown})"
        return 1
    fi

    # Verify Moodle installation (check for config.php)
    if [[ ! -f "$site_dir/config.php" ]]; then
        print_warning "Moodle config.php not found - site may not be fully installed"
    fi

    pass "Validated Moodle site: $site (recipe: $recipe)"
    return 0
}

################################################################################
# OAuth2 Key Management
################################################################################

# Generate OAuth2 RSA key pair for AVC site
# Usage: avc_moodle_generate_keys "avc_sitename"
# Returns: 0 on success, 1 on failure
avc_moodle_generate_keys() {
    local site=$1
    local site_dir
    local key_dir

    # Get site directory
    if ! site_dir=$(get_site_directory "$site" 2>/dev/null); then
        print_error "Cannot find site directory for: $site"
        return 1
    fi

    # Create keys directory in private location (not in webroot)
    key_dir="$site_dir/private/keys"

    print_info "Creating keys directory: $key_dir"
    mkdir -p "$key_dir"

    # Generate 2048-bit RSA private key
    print_info "Generating 2048-bit RSA key pair..."

    if ! openssl genrsa -out "$key_dir/oauth_private.key" 2048 2>/dev/null; then
        print_error "Failed to generate private key"
        return 1
    fi

    # Extract public key from private key
    if ! openssl rsa -in "$key_dir/oauth_private.key" -pubout -out "$key_dir/oauth_public.key" 2>/dev/null; then
        print_error "Failed to generate public key"
        return 1
    fi

    # Set secure permissions
    chmod 600 "$key_dir/oauth_private.key"
    chmod 644 "$key_dir/oauth_public.key"

    pass "OAuth2 keys generated successfully"
    print_info "  Private key: $key_dir/oauth_private.key (600)"
    print_info "  Public key:  $key_dir/oauth_public.key (644)"

    return 0
}

# Check if OAuth2 keys exist for a site
# Usage: avc_moodle_keys_exist "avc_sitename"
# Returns: 0 if keys exist, 1 if they don't
avc_moodle_keys_exist() {
    local site=$1
    local site_dir
    local key_dir

    if ! site_dir=$(get_site_directory "$site" 2>/dev/null); then
        return 1
    fi

    key_dir="$site_dir/private/keys"

    if [[ -f "$key_dir/oauth_private.key" && -f "$key_dir/oauth_public.key" ]]; then
        return 0
    fi

    return 1
}

################################################################################
# URL and Endpoint Functions
################################################################################

# Get the base URL for a site (DDEV or production)
# Usage: avc_moodle_get_site_url "sitename"
# Returns: URL string (e.g., https://avc.ddev.site)
avc_moodle_get_site_url() {
    local site=$1
    local site_dir
    local url

    if ! site_dir=$(get_site_directory "$site" 2>/dev/null); then
        echo ""
        return 1
    fi

    cd "$site_dir" || return 1

    # Check if DDEV site
    if [[ -f ".ddev/config.yaml" ]]; then
        # DDEV environment - use ddev describe
        if command -v ddev &> /dev/null; then
            url=$(ddev describe -j 2>/dev/null | jq -r '.raw.primary_url // empty')
            if [[ -n "$url" ]]; then
                echo "$url"
                return 0
            fi
        fi

        # Fallback: parse DDEV config directly
        local ddev_name
        ddev_name=$(grep "^name:" .ddev/config.yaml | awk '{print $2}')
        if [[ -n "$ddev_name" ]]; then
            echo "https://${ddev_name}.ddev.site"
            return 0
        fi
    fi

    # Production environment - try Drupal config
    if [[ -f "html/sites/default/settings.php" ]]; then
        # Drupal site - use drush
        if command -v drush &> /dev/null; then
            url=$(drush status --field=uri 2>/dev/null)
            if [[ -n "$url" ]]; then
                echo "$url"
                return 0
            fi
        fi
    fi

    # Moodle site - check config.php
    if [[ -f "config.php" ]]; then
        url=$(grep "^\$CFG->wwwroot" config.php | sed -E "s/.*=\s*'([^']+)'.*/\1/")
        if [[ -n "$url" ]]; then
            echo "$url"
            return 0
        fi
    fi

    # Could not determine URL
    echo ""
    return 1
}

# Get OAuth2 issuer URL for AVC site
# Usage: avc_moodle_get_issuer_url "avc_sitename"
# Returns: Issuer URL (base site URL)
avc_moodle_get_issuer_url() {
    local site=$1
    avc_moodle_get_site_url "$site"
}

# Test if an OAuth2 endpoint is accessible
# Usage: avc_moodle_test_oauth_endpoint "https://avc.ddev.site" "/oauth/authorize"
# Returns: 0 if accessible, 1 if not
avc_moodle_test_oauth_endpoint() {
    local base_url=$1
    local endpoint=$2
    local full_url="${base_url}${endpoint}"
    local status

    # Use curl to check HTTP status
    # We consider these codes successful:
    # - 200: OK (endpoint exists)
    # - 302: Redirect (normal for /authorize endpoint)
    # - 401: Unauthorized (expected without credentials, but endpoint exists)
    # - 403: Forbidden (endpoint exists but blocked)
    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$full_url" 2>/dev/null)

    if [[ "$status" == "200" || "$status" == "302" || "$status" == "401" || "$status" == "403" ]]; then
        return 0
    else
        return 1
    fi
}

################################################################################
# Status and Health Check Functions
################################################################################

# Display integration status dashboard
# Usage: avc_moodle_display_status "avc_sitename" "moodle_sitename"
avc_moodle_display_status() {
    local avc_site=$1
    local moodle_site=$2
    local avc_dir
    local moodle_dir
    local avc_url
    local moodle_url

    # Get site directories
    avc_dir=$(get_site_directory "$avc_site" 2>/dev/null)
    moodle_dir=$(get_site_directory "$moodle_site" 2>/dev/null)

    # Get site URLs
    avc_url=$(avc_moodle_get_site_url "$avc_site")
    moodle_url=$(avc_moodle_get_site_url "$moodle_site")

    # Check if integration is enabled in nwp.yml
    local enabled="unknown"
    if [[ -f "$PROJECT_ROOT/nwp.yml" ]]; then
        enabled=$(yq eval ".sites.$avc_site.moodle_integration.enabled // false" "$PROJECT_ROOT/nwp.yml" 2>/dev/null)
    fi

    # Get sync statistics from Drupal state (if available)
    local last_sync="Never"
    local synced_users="0"
    local synced_cohorts="0"
    local failed_syncs="0"

    if [[ -d "$avc_dir" ]]; then
        cd "$avc_dir" || return 1

        # Try to get state values using drush
        if command -v ddev &> /dev/null && [[ -f ".ddev/config.yaml" ]]; then
            last_sync=$(ddev drush state:get avc_moodle_sync.last_sync 2>/dev/null || echo "Never")
            synced_users=$(ddev drush state:get avc_moodle_sync.synced_users 2>/dev/null || echo "0")
            synced_cohorts=$(ddev drush state:get avc_moodle_sync.synced_cohorts 2>/dev/null || echo "0")
            failed_syncs=$(ddev drush state:get avc_moodle_sync.failed_syncs 2>/dev/null || echo "0")
        fi
    fi

    # Get cache statistics
    local cache_hits="0"
    local cache_misses="0"
    local cache_rate="0"

    if [[ -d "$avc_dir" ]]; then
        cd "$avc_dir" || return 1

        if command -v ddev &> /dev/null && [[ -f ".ddev/config.yaml" ]]; then
            cache_hits=$(ddev drush state:get avc_moodle_data.cache_hits 2>/dev/null || echo "0")
            cache_misses=$(ddev drush state:get avc_moodle_data.cache_misses 2>/dev/null || echo "0")

            # Calculate cache hit rate
            local cache_total=$((cache_hits + cache_misses))
            if [[ $cache_total -gt 0 ]]; then
                cache_rate=$((cache_hits * 100 / cache_total))
            fi
        fi
    fi

    # Test OAuth2 endpoints
    local oauth_status="✗ Not Reachable"
    if avc_moodle_test_oauth_endpoint "$avc_url" "/oauth/authorize"; then
        oauth_status="✓ Reachable"
    fi

    # Display status dashboard
    echo ""
    echo "┌─────────────────────────────────────────────────────────┐"
    echo "│ AVC-Moodle Integration Status                           │"
    echo "├─────────────────────────────────────────────────────────┤"
    echo "│ AVC Site:             $avc_site"
    echo "│ Moodle Site:          $moodle_site"
    echo "│"

    if [[ "$enabled" == "true" ]]; then
        echo "│ SSO Status:           ✓ Active                          │"
    else
        echo "│ SSO Status:           ✗ Disabled                        │"
    fi

    echo "│ OAuth2 Endpoints:     $oauth_status"
    echo "│"
    echo "│ AVC URL:              $avc_url"
    echo "│ Moodle URL:           $moodle_url"
    echo "│"
    echo "│ Last Sync:            $last_sync"
    echo "│ Synced Users:         $synced_users"
    echo "│ Synced Cohorts:       $synced_cohorts"
    echo "│ Failed Syncs:         $failed_syncs"
    echo "│ Cache Hit Rate:       $cache_rate%"
    echo "└─────────────────────────────────────────────────────────┘"
    echo ""
}

################################################################################
# Helper Functions
################################################################################


################################################################################
# Export Functions
################################################################################

export -f avc_moodle_validate_avc_site
export -f avc_moodle_validate_moodle_site
export -f avc_moodle_generate_keys
export -f avc_moodle_keys_exist
export -f avc_moodle_get_site_url
export -f avc_moodle_get_issuer_url
export -f avc_moodle_test_oauth_endpoint
export -f avc_moodle_display_status
export -f get_site_directory
export -f get_site_recipe
