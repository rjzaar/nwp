#!/bin/bash

################################################################################
# NWP Multi-Coder Setup Script
#
# Manages NS delegation for additional coders who have their own subdomains
# under nwpcode.org (or configured base domain).
#
# Each coder gets:
#   - NS delegation: <coder>.nwpcode.org -> Linode nameservers
#   - Full DNS autonomy via their own Linode account
#   - Ability to create: git.<coder>.nwpcode.org, nwp.<coder>.nwpcode.org, etc.
#
# Usage:
#   ./coder-setup.sh add <coder_name> [--notes "description"]
#   ./coder-setup.sh remove <coder_name>
#   ./coder-setup.sh list
#   ./coder-setup.sh verify <coder_name>
#
# Requirements:
#   - Cloudflare API token with DNS edit permissions (in .secrets.yml)
#   - Cloudflare zone ID for the base domain (in .secrets.yml)
#
# See docs/CODER_ONBOARDING.md for complete setup instructions.
################################################################################

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/cloudflare.sh"
source "$PROJECT_ROOT/lib/yaml-write.sh"
source "$PROJECT_ROOT/lib/git.sh"

# Configuration
CONFIG_FILE="${PROJECT_ROOT}/cnwp.yml"
EXAMPLE_CONFIG="${PROJECT_ROOT}/example.cnwp.yml"

################################################################################
# Helper Functions
################################################################################

# Print usage information
usage() {
    cat << EOF
Usage: $(basename "$0") <command> [options]

Commands:
  add <name>       Add NS delegation and optionally GitLab account for a new coder
  remove <name>    Remove NS delegation and revoke access for a coder
  provision <name> Provision Linode server and DNS for a coder
  list             List all configured coders
  verify <name>    Verify DNS delegation is working
  gitlab-users     List all GitLab users

Options for 'add':
  --notes "text"   Add a description when adding a coder
  --email "addr"   Email address for GitLab account (enables GitLab user creation)
  --fullname "nm"  Full name for GitLab account (default: coder name)
  --gitlab-group   GitLab group to add user to (default: nwp)
  --no-gitlab      Skip GitLab user creation even if email provided
  --dry-run        Show what would be done without making changes

Options for 'provision':
  --region         Linode region (default: us-east)
  --plan           Linode plan type (default: g6-nanode-1)
  --dry-run        Show what would be done without making changes

Options for 'remove':
  --keep-gitlab    Don't revoke GitLab access
  --archive        Archive contribution history before removal
  --dry-run        Show what would be done without making changes

General:
  -h, --help       Show this help message

Examples:
  $(basename "$0") add coder2 --notes "John's dev environment"
  $(basename "$0") add john --email "john@example.com" --fullname "John Smith"
  $(basename "$0") provision john --region us-west --plan g6-standard-1
  $(basename "$0") remove coder2
  $(basename "$0") list
  $(basename "$0") gitlab-users

EOF
}

# Validate coder name
validate_coder_name() {
    local name="$1"

    if [[ -z "$name" ]]; then
        print_error "Coder name is required"
        return 1
    fi

    # Must start with letter, alphanumeric/hyphen/underscore only
    if [[ ! "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        print_error "Coder name must start with a letter and contain only alphanumeric, underscore, or hyphen"
        return 1
    fi

    # Length limit
    if [[ ${#name} -gt 32 ]]; then
        print_error "Coder name too long (max 32 characters)"
        return 1
    fi

    # Reserved names
    local reserved=("www" "git" "mail" "smtp" "pop" "imap" "ftp" "api" "admin" "root" "ns1" "ns2")
    for r in "${reserved[@]}"; do
        if [[ "$name" == "$r" ]]; then
            print_error "Coder name '$name' is reserved"
            return 1
        fi
    done

    return 0
}

# Get base domain from settings.url
get_base_domain() {
    local result
    if command -v yq &>/dev/null; then
        result=$(yq -r '.settings.url // ""' "$CONFIG_FILE" 2>/dev/null)
    else
        result=$(awk '
            /^settings:/ { in_section = 1; next }
            in_section && /^[a-zA-Z]/ && !/^  / { in_section = 0 }
            in_section && /^  url:/ {
                sub(/^  url: */, "")
                sub(/#.*/, "")
                gsub(/["'"'"']/, "")
                gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                if (length($0) > 0) print
                exit
            }
        ' "$CONFIG_FILE" 2>/dev/null)
    fi
    echo "${result:-nwpcode.org}"
}

# Get nameservers from config
get_nameservers() {
    if command -v yq &>/dev/null; then
        yq -r '.other_coders.nameservers[]' "$CONFIG_FILE" 2>/dev/null
    else
        awk '
            /^other_coders:/ { in_other = 1; next }
            in_other && /^[a-zA-Z]/ && !/^  / { in_other = 0 }
            in_other && /^  nameservers:/ { in_ns = 1; next }
            in_ns && /^  [a-zA-Z]/ && !/^    / { in_ns = 0 }
            in_ns && /^    - / {
                sub(/^    - /, "")
                gsub(/["'"'"']/, "")
                print
            }
        ' "$CONFIG_FILE" 2>/dev/null
    fi
}

# Check if coder exists in config
coder_exists() {
    local name="$1"

    if command -v yq &>/dev/null; then
        local result=$(yq -r ".other_coders.coders.$name // empty" "$CONFIG_FILE" 2>/dev/null)
        [[ -n "$result" ]]
    else
        awk -v coder="$name" '
            /^other_coders:/ { in_other = 1; next }
            in_other && /^[a-zA-Z]/ && !/^  / { in_other = 0 }
            in_other && /^  coders:/ { in_coders = 1; next }
            in_coders && /^  [a-zA-Z]/ && !/^    / { in_coders = 0 }
            in_coders && $0 ~ "^    " coder ":" { found = 1; exit }
            END { exit !found }
        ' "$CONFIG_FILE" 2>/dev/null
    fi
}

# Add coder to cnwp.yml
add_coder_to_config() {
    local name="$1"
    local notes="${2:-}"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Create backup using yaml_backup (writes to .backups/ with retention)
    yaml_backup "$CONFIG_FILE"

    if command -v yq &>/dev/null; then
        # Use yq for reliable YAML editing
        yq -i ".other_coders.coders.$name = {\"added\": \"$timestamp\", \"status\": \"active\", \"notes\": \"$notes\"}" "$CONFIG_FILE"
    else
        # Fallback to awk
        local coder_entry="    $name:\n      added: $timestamp\n      status: active\n      notes: \"$notes\""

        awk -v coder_entry="$coder_entry" '
            BEGIN { in_coders = 0; added = 0 }
            /^other_coders:/ { in_other = 1 }
            in_other && /^  coders:/ {
                in_coders = 1
                print
                next
            }
            in_coders && /^  [a-zA-Z]/ && !/^    / {
                # End of coders section, add before next section
                if (!added) {
                    printf "%s\n", coder_entry
                    added = 1
                }
                in_coders = 0
            }
            in_coders && /^[a-zA-Z]/ && !/^  / {
                # End of other_coders section
                if (!added) {
                    printf "%s\n", coder_entry
                    added = 1
                }
                in_coders = 0
            }
            { print }
            END {
                if (in_coders && !added) {
                    printf "%s\n", coder_entry
                }
            }
        ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    fi
}

# Remove coder from cnwp.yml
remove_coder_from_config() {
    local name="$1"

    # Create backup using yaml_backup (writes to .backups/ with retention)
    yaml_backup "$CONFIG_FILE"

    if command -v yq &>/dev/null; then
        yq -i "del(.other_coders.coders.$name)" "$CONFIG_FILE"
    else
        awk -v coder="$name" '
            BEGIN { in_coder = 0 }
            /^other_coders:/ { in_other = 1 }
            in_other && /^  coders:/ { in_coders = 1 }
            in_coders && $0 ~ "^    " coder ":" { in_coder = 1; next }
            in_coder && /^    [a-zA-Z]/ && !/^      / { in_coder = 0 }
            in_coder && /^  [a-zA-Z]/ && !/^    / { in_coder = 0 }
            !in_coder { print }
        ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    fi
}

# List all coders from config
list_coders_from_config() {
    if command -v yq &>/dev/null; then
        yq -r '.other_coders.coders | keys[]' "$CONFIG_FILE" 2>/dev/null
    else
        awk '
            /^other_coders:/ { in_other = 1; next }
            in_other && /^[a-zA-Z]/ && !/^  / { in_other = 0 }
            in_other && /^  coders:/ { in_coders = 1; next }
            in_coders && /^  [a-zA-Z]/ && !/^    / { in_coders = 0 }
            in_coders && /^    [a-zA-Z][a-zA-Z0-9_-]*:/ {
                sub(/^    /, "")
                sub(/:.*/, "")
                print
            }
        ' "$CONFIG_FILE" 2>/dev/null
    fi
}

# Get coder details
get_coder_details() {
    local name="$1"

    if command -v yq &>/dev/null; then
        yq -r ".other_coders.coders.$name | to_entries | .[] | \"\(.key): \(.value)\"" "$CONFIG_FILE" 2>/dev/null
    else
        awk -v coder="$name" '
            /^other_coders:/ { in_other = 1; next }
            in_other && /^  coders:/ { in_coders = 1; next }
            in_coders && $0 ~ "^    " coder ":" { in_coder = 1; next }
            in_coder && /^    [a-zA-Z]/ && !/^      / { in_coder = 0 }
            in_coder && /^      [a-zA-Z_]+:/ {
                sub(/^      /, "")
                print
            }
        ' "$CONFIG_FILE" 2>/dev/null
    fi
}

################################################################################
# Main Commands
################################################################################

# Add a new coder
cmd_add() {
    local name="$1"
    local notes=""
    local email=""
    local fullname=""
    local gitlab_group="nwp"
    local no_gitlab=false
    local dry_run=false
    shift || true

    # Parse additional options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --notes)
                notes="$2"
                shift 2
                ;;
            --email)
                email="$2"
                shift 2
                ;;
            --fullname)
                fullname="$2"
                shift 2
                ;;
            --gitlab-group)
                gitlab_group="$2"
                shift 2
                ;;
            --no-gitlab)
                no_gitlab=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Default fullname to coder name if not provided
    [ -z "$fullname" ] && fullname="$name"

    # Validate name
    if ! validate_coder_name "$name"; then
        exit 1
    fi

    # Check if already exists
    if coder_exists "$name"; then
        print_error "Coder '$name' already exists"
        exit 1
    fi

    # Get configuration
    local base_domain=$(get_base_domain)
    local subdomain="${name}.${base_domain}"

    print_header "Adding Coder: $name"
    info "Base domain: $base_domain"
    info "Subdomain:   $subdomain"

    # Get Cloudflare credentials
    local cf_token=$(get_cloudflare_token "$PROJECT_ROOT")
    local cf_zone_id=$(get_cloudflare_zone_id "$PROJECT_ROOT")
    local skip_dns=false

    if [[ -z "$cf_token" || -z "$cf_zone_id" ]]; then
        warn "Cloudflare API credentials not configured - skipping DNS setup"
        info "DNS delegation can be configured manually later"
        skip_dns=true
    else
        # Verify Cloudflare auth
        info "Verifying Cloudflare authentication..."
        if ! verify_cloudflare_auth "$cf_token" "$cf_zone_id" 2>/dev/null; then
            warn "Cloudflare authentication failed - skipping DNS setup"
            skip_dns=true
        else
            pass "Cloudflare authenticated"
        fi
    fi

    # DNS delegation setup (only if Cloudflare is configured)
    if ! $skip_dns; then
        # Get nameservers
        local nameservers=($(get_nameservers))
        if [[ ${#nameservers[@]} -eq 0 ]]; then
            # Default to Linode nameservers
            nameservers=("ns1.linode.com" "ns2.linode.com" "ns3.linode.com" "ns4.linode.com" "ns5.linode.com")
        fi

        info "Nameservers to delegate to:"
        for ns in "${nameservers[@]}"; do
            task "$ns"
        done

        if $dry_run; then
            warn "DRY RUN - No changes will be made"
            echo ""
            info "Would create NS records:"
            for ns in "${nameservers[@]}"; do
                task "$name  NS  $ns"
            done
        else
            # Create NS delegation
            info "Creating NS delegation..."
            if cf_create_ns_delegation "$cf_token" "$cf_zone_id" "$name" "${nameservers[@]}"; then
                pass "NS delegation created for $subdomain"
            else
                fail "Failed to create NS delegation"
                exit 1
            fi
        fi
    fi

    if $dry_run; then
        info "Would add coder to cnwp.yml"
        if [ -n "$email" ] && ! $no_gitlab; then
            info "Would create GitLab user:"
            task "Username: $name"
            task "Email: $email"
            task "Name: $fullname"
            task "Group: $gitlab_group"
        fi
        exit 0
    fi

    # Add to config
    info "Adding coder to cnwp.yml..."
    add_coder_to_config "$name" "$notes"
    pass "Coder added to configuration"

    # Create GitLab user if email provided
    local gitlab_created=false
    if [ -n "$email" ] && ! $no_gitlab; then
        echo ""
        info "Creating GitLab user account..."
        if gitlab_create_user "$name" "$email" "$fullname"; then
            gitlab_created=true
            # Add to group
            if [ -n "$gitlab_group" ]; then
                gitlab_add_user_to_group "$name" "$gitlab_group" 30  # Developer access
            fi
        else
            warn "GitLab user creation failed - coder can request account manually"
        fi
    fi

    # Success message
    echo ""
    print_header "Setup Complete"
    pass "Coder '$name' has been set up"
    echo ""

    if $gitlab_created; then
        info "GitLab account created - credentials shown above"
        info "Login at: https://$(get_gitlab_url)"
        echo ""
    fi

    info "Next steps for $name:"
    if ! $gitlab_created && [ -z "$email" ]; then
        task "0. Request GitLab account from NWP administrator (provide email)"
    fi
    task "1. Create a Linode account at https://www.linode.com/"
    task "2. Generate an API token with Domains Read/Write permissions"
    task "3. Create a DNS zone for '$subdomain' in Linode DNS Manager"
    task "4. Add DNS records (A, CNAME) pointing to their server IP"
    task "5. Provision server and install NWP"
    echo ""
    info "See docs/CODER_ONBOARDING.md for detailed instructions"
    echo ""
    warn "DNS propagation may take 24-48 hours"
}

# Remove a coder with full offboarding
cmd_remove() {
    local name="$1"
    local dry_run=false
    local keep_gitlab=false
    local archive=false
    shift || true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                dry_run=true
                shift
                ;;
            --keep-gitlab)
                keep_gitlab=true
                shift
                ;;
            --archive)
                archive=true
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    if [[ -z "$name" ]]; then
        print_error "Coder name is required"
        usage
        exit 1
    fi

    # Check if exists
    if ! coder_exists "$name"; then
        print_error "Coder '$name' not found"
        exit 1
    fi

    local base_domain=$(get_base_domain)
    local subdomain="${name}.${base_domain}"

    print_header "Removing Coder: $name"
    info "This will perform full offboarding cleanup"
    echo ""

    # Get Cloudflare credentials
    local cf_token=$(get_cloudflare_token "$PROJECT_ROOT")
    local cf_zone_id=$(get_cloudflare_zone_id "$PROJECT_ROOT")
    local skip_dns=false

    if [[ -z "$cf_token" || -z "$cf_zone_id" ]]; then
        warn "Cloudflare API credentials not found - skipping DNS removal"
        skip_dns=true
    fi

    # Show what will be done
    info "Actions to be performed:"
    if ! $skip_dns; then
        task "1. Remove NS delegation for $subdomain"
    fi
    if ! $keep_gitlab; then
        task "2. Block GitLab user account"
        task "3. Remove from nwp group"
    else
        task "2. (Skipped) Keep GitLab access"
    fi
    task "4. Remove from cnwp.yml configuration"
    task "5. Log offboarding action"
    if $archive; then
        task "6. Archive contribution history"
    fi

    if $dry_run; then
        echo ""
        warn "DRY RUN - No changes will be made"
        exit 0
    fi

    # Confirm
    echo ""
    warn "This action cannot be fully undone"
    read -p "Are you sure you want to remove '$name'? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[yY] ]]; then
        info "Cancelled"
        exit 0
    fi

    echo ""

    # Step 1: Delete NS delegation
    if ! $skip_dns; then
        info "Removing NS delegation..."
        if cf_delete_ns_delegation "$cf_token" "$cf_zone_id" "$name"; then
            pass "NS delegation removed"
        else
            warn "Failed to remove NS delegation (may not exist)"
        fi
    fi

    # Step 2-3: GitLab cleanup
    if ! $keep_gitlab; then
        local gitlab_url=$(get_gitlab_url)
        local gitlab_token=$(get_gitlab_token)

        if [[ -n "$gitlab_url" && -n "$gitlab_token" ]]; then
            # Remove from group
            info "Removing from GitLab group..."
            if gitlab_remove_user_from_group "$name" "nwp" 2>/dev/null; then
                pass "Removed from nwp group"
            else
                warn "Could not remove from group (may not be a member)"
            fi

            # Block user account
            info "Blocking GitLab user account..."
            if gitlab_block_user "$name" 2>/dev/null; then
                pass "GitLab user blocked"
            else
                warn "Could not block GitLab user (may not exist)"
            fi
        else
            warn "GitLab credentials not configured - skipping GitLab cleanup"
        fi
    else
        info "Keeping GitLab access (--keep-gitlab specified)"
    fi

    # Step 4: Remove from config
    info "Removing from cnwp.yml..."
    remove_coder_from_config "$name"
    pass "Coder removed from configuration"

    # Step 5: Log offboarding
    local log_dir="${PROJECT_ROOT}/logs"
    local log_file="${log_dir}/offboarding.log"
    mkdir -p "$log_dir"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | REMOVED | $name | by $(whoami) | keep_gitlab=$keep_gitlab | archive=$archive" >> "$log_file"
    pass "Offboarding logged"

    # Step 6: Archive contributions (optional)
    if $archive; then
        info "Archiving contribution history..."
        local archive_dir="${PROJECT_ROOT}/archives/coders"
        mkdir -p "$archive_dir"
        local archive_file="${archive_dir}/${name}-$(date +%Y%m%d).json"

        # Try to get contribution stats from GitLab
        if [[ -n "$gitlab_url" && -n "$gitlab_token" ]]; then
            local user_id=$(curl -s -H "PRIVATE-TOKEN: $gitlab_token" \
                "https://${gitlab_url}/api/v4/users?username=${name}" | jq -r '.[0].id // empty')

            if [[ -n "$user_id" ]]; then
                # Get user events/contributions
                curl -s -H "PRIVATE-TOKEN: $gitlab_token" \
                    "https://${gitlab_url}/api/v4/users/${user_id}/events?per_page=100" > "$archive_file"
                pass "Contributions archived to $archive_file"
            else
                warn "Could not find user for archiving"
            fi
        else
            echo "{\"name\": \"$name\", \"removed\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"note\": \"No GitLab data available\"}" > "$archive_file"
            pass "Basic archive created"
        fi
    fi

    echo ""
    print_header "Offboarding Complete"
    pass "Coder '$name' has been removed"
    echo ""
    info "Summary:"
    task "DNS delegation: $(if $skip_dns; then echo 'skipped'; else echo 'removed'; fi)"
    task "GitLab access: $(if $keep_gitlab; then echo 'kept'; else echo 'revoked'; fi)"
    task "Configuration: removed"
    task "Log entry: created"
    if $archive; then
        task "Archive: created"
    fi
}

# Helper function to block GitLab user
gitlab_block_user() {
    local username="$1"
    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    if [[ -z "$gitlab_url" || -z "$token" ]]; then
        return 1
    fi

    # Get user ID
    local user_id=$(curl -s -H "PRIVATE-TOKEN: $token" \
        "https://${gitlab_url}/api/v4/users?username=${username}" | jq -r '.[0].id // empty')

    if [[ -z "$user_id" ]]; then
        return 1
    fi

    # Block user
    curl -s -X POST -H "PRIVATE-TOKEN: $token" \
        "https://${gitlab_url}/api/v4/users/${user_id}/block" >/dev/null

    return $?
}

# Helper function to remove user from group
gitlab_remove_user_from_group() {
    local username="$1"
    local group="$2"
    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    if [[ -z "$gitlab_url" || -z "$token" ]]; then
        return 1
    fi

    # Get user ID
    local user_id=$(curl -s -H "PRIVATE-TOKEN: $token" \
        "https://${gitlab_url}/api/v4/users?username=${username}" | jq -r '.[0].id // empty')

    if [[ -z "$user_id" ]]; then
        return 1
    fi

    # Get group ID
    local group_id=$(curl -s -H "PRIVATE-TOKEN: $token" \
        "https://${gitlab_url}/api/v4/groups?search=${group}" | jq -r '.[0].id // empty')

    if [[ -z "$group_id" ]]; then
        return 1
    fi

    # Remove from group
    curl -s -X DELETE -H "PRIVATE-TOKEN: $token" \
        "https://${gitlab_url}/api/v4/groups/${group_id}/members/${user_id}" >/dev/null

    return $?
}

# List all coders
cmd_list() {
    local base_domain=$(get_base_domain)

    print_header "Configured Coders"
    info "Base domain: $base_domain"
    echo ""

    local coders=$(list_coders_from_config)

    if [[ -z "$coders" ]]; then
        info "No coders configured"
        echo ""
        info "Add a coder with: $(basename "$0") add <name>"
        exit 0
    fi

    printf "%-20s %-12s %-25s %s\n" "NAME" "STATUS" "ADDED" "NOTES"
    printf "%-20s %-12s %-25s %s\n" "----" "------" "-----" "-----"

    while IFS= read -r name; do
        local details=$(get_coder_details "$name")
        local status=$(echo "$details" | grep "^status:" | cut -d: -f2 | tr -d ' "')
        local added=$(echo "$details" | grep "^added:" | cut -d: -f2- | tr -d ' "')
        local notes=$(echo "$details" | grep "^notes:" | cut -d: -f2- | tr -d '"' | sed 's/^ *//')

        # Format added date
        added="${added:0:10}"

        printf "%-20s %-12s %-25s %s\n" "$name" "$status" "$added" "$notes"
    done <<< "$coders"

    echo ""
}

# Provision Linode infrastructure for a coder
cmd_provision() {
    local name="$1"
    local region="us-east"
    local plan="g6-nanode-1"
    local dry_run=false
    shift || true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --region)
                region="$2"
                shift 2
                ;;
            --plan)
                plan="$2"
                shift 2
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    if [[ -z "$name" ]]; then
        print_error "Coder name is required"
        usage
        exit 1
    fi

    # Check if coder exists
    if ! coder_exists "$name"; then
        print_error "Coder '$name' not found. Run 'add' first."
        exit 1
    fi

    # Check for Linode CLI
    if ! command -v linode-cli &>/dev/null; then
        print_error "linode-cli not installed. Install with: pip install linode-cli"
        exit 1
    fi

    local base_domain=$(get_base_domain)
    local subdomain="${name}.${base_domain}"

    print_header "Provisioning Linode Infrastructure: $name"
    info "Subdomain: $subdomain"
    info "Region: $region"
    info "Plan: $plan"
    echo ""

    if $dry_run; then
        warn "DRY RUN - No changes will be made"
        echo ""
        info "Would create:"
        task "1. Linode server: ${name}-nwp"
        task "2. DNS zone: $subdomain"
        task "3. A records: @, git, *"
        exit 0
    fi

    # Step 1: Create Linode server
    info "Creating Linode server..."
    local ssh_key=""
    if [[ -f ~/.ssh/id_rsa.pub ]]; then
        ssh_key=$(cat ~/.ssh/id_rsa.pub)
    elif [[ -f ~/.ssh/id_ed25519.pub ]]; then
        ssh_key=$(cat ~/.ssh/id_ed25519.pub)
    fi

    local create_args=(
        --label "${name}-nwp"
        --region "$region"
        --type "$plan"
        --image "linode/ubuntu22.04"
    )

    if [[ -n "$ssh_key" ]]; then
        create_args+=(--authorized_keys "$ssh_key")
    fi

    if ! linode-cli linodes create "${create_args[@]}"; then
        fail "Failed to create Linode server"
        exit 1
    fi
    pass "Linode server created"

    # Wait for server to be running and get IP
    info "Waiting for server to boot..."
    sleep 10
    local ip=""
    local attempts=0
    while [[ -z "$ip" || "$ip" == "null" ]] && [[ $attempts -lt 30 ]]; do
        ip=$(linode-cli linodes list --label "${name}-nwp" --json 2>/dev/null | jq -r '.[0].ipv4[0]' 2>/dev/null)
        ((attempts++))
        sleep 2
    done

    if [[ -z "$ip" || "$ip" == "null" ]]; then
        fail "Could not get server IP address"
        exit 1
    fi
    pass "Server IP: $ip"

    # Step 2: Create DNS zone
    info "Creating DNS zone..."
    if ! linode-cli domains create --domain "$subdomain" --type master --soa_email "admin@${subdomain}" 2>/dev/null; then
        warn "DNS zone may already exist, continuing..."
    else
        pass "DNS zone created"
    fi

    # Get domain ID
    local domain_id=$(linode-cli domains list --json 2>/dev/null | jq -r ".[] | select(.domain==\"${subdomain}\") | .id")
    if [[ -z "$domain_id" ]]; then
        fail "Could not get domain ID"
        exit 1
    fi

    # Step 3: Create DNS records
    info "Creating DNS records..."

    # Root A record
    linode-cli domains records-create "$domain_id" --type A --name "" --target "$ip" --ttl_sec 300 2>/dev/null && \
        pass "A record for @ -> $ip" || warn "A record may already exist"

    # Git subdomain
    linode-cli domains records-create "$domain_id" --type A --name "git" --target "$ip" --ttl_sec 300 2>/dev/null && \
        pass "A record for git -> $ip" || warn "git A record may already exist"

    # Wildcard
    linode-cli domains records-create "$domain_id" --type A --name "*" --target "$ip" --ttl_sec 300 2>/dev/null && \
        pass "A record for * -> $ip" || warn "Wildcard A record may already exist"

    # Update coder config with server info
    if command -v yq &>/dev/null; then
        yq -i ".other_coders.coders.${name}.server_ip = \"$ip\"" "$CONFIG_FILE"
        yq -i ".other_coders.coders.${name}.linode_label = \"${name}-nwp\"" "$CONFIG_FILE"
        yq -i ".other_coders.coders.${name}.provisioned = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$CONFIG_FILE"
    fi

    echo ""
    print_header "Provisioning Complete"
    pass "Server and DNS configured for $name"
    echo ""
    info "Server details:"
    task "IP Address: $ip"
    task "SSH: ssh root@$ip"
    task "Domain: $subdomain"
    echo ""
    info "Next steps for $name:"
    task "1. Wait for DNS propagation (up to 48 hours)"
    task "2. SSH into server: ssh root@$ip"
    task "3. Run NWP bootstrap script"
    echo ""
    info "Bootstrap command:"
    echo "  curl -fsSL https://raw.githubusercontent.com/rjzaar/nwp/main/scripts/bootstrap-coder-server.sh | bash"
}

# Verify DNS delegation
cmd_verify() {
    local name="$1"

    if [[ -z "$name" ]]; then
        print_error "Coder name is required"
        usage
        exit 1
    fi

    local base_domain=$(get_base_domain)
    local subdomain="${name}.${base_domain}"

    print_header "Verifying DNS for: $name"
    info "Subdomain: $subdomain"
    echo ""

    # Check NS records
    info "Checking NS records..."
    local ns_records=$(dig NS "$subdomain" +short 2>/dev/null)

    if [[ -z "$ns_records" ]]; then
        fail "No NS records found for $subdomain"
        warn "DNS delegation may not be configured or propagated yet"
    else
        pass "NS records found:"
        echo "$ns_records" | while read -r ns; do
            task "$ns"
        done
    fi

    echo ""

    # Try to resolve the subdomain
    info "Testing DNS resolution..."
    local a_record=$(dig A "$subdomain" +short 2>/dev/null)

    if [[ -n "$a_record" ]]; then
        pass "A record resolves to: $a_record"
    else
        info "No A record (coder needs to create DNS zone and records)"
    fi

    # Test git subdomain
    local git_a=$(dig A "git.$subdomain" +short 2>/dev/null)
    if [[ -n "$git_a" ]]; then
        pass "git.$subdomain resolves to: $git_a"
    else
        info "No A record for git.$subdomain (expected if not yet configured)"
    fi

    echo ""

    # Check if in config
    if coder_exists "$name"; then
        pass "Coder is registered in cnwp.yml"
    else
        warn "Coder not found in cnwp.yml"
    fi
}

################################################################################
# Main Entry Point
################################################################################

main() {
    # Check for config file
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Config file not found: $CONFIG_FILE"
        print_info "Copy example.cnwp.yml to cnwp.yml first"
        exit 1
    fi

    # Parse command
    local command="${1:-}"
    shift || true

    case "$command" in
        add)
            cmd_add "$@"
            ;;
        remove)
            cmd_remove "$@"
            ;;
        provision)
            cmd_provision "$@"
            ;;
        list)
            cmd_list
            ;;
        verify)
            cmd_verify "$@"
            ;;
        gitlab-users)
            print_header "GitLab Users"
            gitlab_list_users
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        "")
            usage
            exit 1
            ;;
        *)
            print_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
