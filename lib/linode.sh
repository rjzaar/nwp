#!/bin/bash

################################################################################
# Linode API Helper Functions
#
# Provides functions for provisioning and managing Linode instances via API
# Used primarily for automated testing of production deployment scripts
#
# Requirements:
# - LINODE_API_TOKEN environment variable or .secrets.yml
# - SSH key added to Linode account (via Cloud Manager)
# - curl and jq installed
################################################################################

# Source yaml-write.sh for consolidated YAML functions
LINODE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$LINODE_LIB_DIR/yaml-write.sh" ]; then
    source "$LINODE_LIB_DIR/yaml-write.sh"
fi

# DEPRECATED: Wrapper for backward compatibility
# Use yaml_get_secret directly for new code
# Parse a YAML value from a simple YAML file
# Usage: parse_yaml_value "file.yml" "section" "key"
parse_yaml_value() {
    local file="$1"
    local section="$2"
    local key="$3"

    # Use consolidated yaml_get_secret function
    yaml_get_secret "${section}.${key}" "$file"
}

# Get Linode API token
get_linode_token() {
    local token=""
    local script_dir="${1:-.}"

    # Check .secrets.yml first using consolidated yaml_get_secret
    if [ -f "$script_dir/.secrets.yml" ]; then
        token=$(yaml_get_secret "linode.api_token" "$script_dir/.secrets.yml")
    fi

    # Fall back to environment variable
    if [ -z "$token" ] && [ -n "${LINODE_API_TOKEN:-}" ]; then
        token="$LINODE_API_TOKEN"
    fi

    echo "$token"
}

# Get SSH key ID from Linode account by label
# Usage: get_ssh_key_id "TOKEN" "nwp-deployment"
get_ssh_key_id() {
    local token=$1
    local label=$2

    local response=$(curl -s -H "Authorization: Bearer $token" \
        "https://api.linode.com/v4/profile/sshkeys")

    # Extract key ID matching label
    echo "$response" | grep -o "\"id\":[0-9]*,\"label\":\"$label\"" | grep -o "[0-9]*" | head -1
}

# Get first SSH key ID from Linode account
# Usage: get_first_ssh_key_id "TOKEN"
get_first_ssh_key_id() {
    local token=$1

    local response=$(curl -s -H "Authorization: Bearer $token" \
        "https://api.linode.com/v4/profile/sshkeys")

    # Extract first key ID
    echo "$response" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2
}

# Create a Linode instance
# Usage: create_linode_instance "TOKEN" "LABEL" "SSH_PUBLIC_KEY" "REGION" "TYPE"
# Returns: Instance ID
create_linode_instance() {
    local token=$1
    local label=$2
    local ssh_public_key=$3
    local region="${4:-us-east}"
    local type="${5:-g6-nanode-1}"
    local image="${6:-linode/ubuntu22.04}"

    local root_pass=$(openssl rand -base64 32 | tr -d /=+ | cut -c -25)

    local response=$(curl -s -X POST "https://api.linode.com/v4/linode/instances" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{
            \"label\": \"$label\",
            \"region\": \"$region\",
            \"type\": \"$type\",
            \"image\": \"$image\",
            \"root_pass\": \"$root_pass\",
            \"authorized_keys\": [\"$ssh_public_key\"],
            \"booted\": true,
            \"backups_enabled\": false,
            \"private_ip\": false
        }")

    if echo "$response" | grep -q '"id"'; then
        echo "$response" | grep -o '"id"[: ]*[0-9]*' | head -1 | grep -o '[0-9]*'
    else
        echo "ERROR: Failed to create Linode instance" >&2
        echo "$response" >&2
        return 1
    fi
}

# Wait for Linode instance to be running
# Usage: wait_for_linode "TOKEN" "INSTANCE_ID" "MAX_WAIT_SECONDS"
wait_for_linode() {
    local token=$1
    local instance_id=$2
    local max_wait=${3:-300}
    local elapsed=0

    echo "Waiting for instance $instance_id to boot..." >&2

    while [ $elapsed -lt $max_wait ]; do
        local response=$(curl -s -H "Authorization: Bearer $token" \
            "https://api.linode.com/v4/linode/instances/$instance_id")

        local status=$(echo "$response" | grep -o '"status"[: ]*"[^"]*"' | cut -d'"' -f4)

        if [ "$status" = "running" ]; then
            echo "Instance is running" >&2
            return 0
        fi

        # Show status periodically for debugging
        if [ $((elapsed % 30)) -eq 0 ] && [ $elapsed -gt 0 ]; then
            echo " [status: $status]" >&2
        else
            echo -n "." >&2
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo "ERROR: Instance did not start within $max_wait seconds" >&2
    return 1
}

# Get Linode instance IP address
# Usage: get_linode_ip "TOKEN" "INSTANCE_ID"
get_linode_ip() {
    local token=$1
    local instance_id=$2

    local response=$(curl -s -H "Authorization: Bearer $token" \
        "https://api.linode.com/v4/linode/instances/$instance_id")

    # Extract IPv4 address
    echo "$response" | grep -o '"ipv4"[: ]*\["[^"]*"' | cut -d'"' -f4
}

# Wait for SSH to be available on instance
# Usage: wait_for_ssh "IP_ADDRESS" "SSH_KEY_PATH" "MAX_WAIT_SECONDS"
wait_for_ssh() {
    local ip=$1
    local ssh_key=${2:-~/.ssh/nwp}
    local max_wait=${3:-600}  # Increased to 10 minutes for cloud-init
    local elapsed=0
    local last_progress=0

    echo "Waiting for SSH to be available on $ip..." >&2
    echo "This may take 5-10 minutes for cloud-init to configure the instance..." >&2

    while [ $elapsed -lt $max_wait ]; do
        # Try SSH connection with verbose error capturing
        if ssh -i "$ssh_key" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
            -o BatchMode=yes root@$ip "exit" 2>/dev/null; then
            echo "" >&2  # New line after dots
            echo "SSH is ready (took $elapsed seconds)" >&2
            return 0
        fi

        # Show progress message every 60 seconds
        if [ $((elapsed - last_progress)) -ge 60 ]; then
            echo "" >&2  # New line after dots
            echo "Still waiting... ($elapsed/${max_wait}s elapsed)" >&2
            last_progress=$elapsed
        else
            echo -n "." >&2
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo "" >&2  # New line after dots
    echo "ERROR: SSH did not become available within $max_wait seconds" >&2
    echo "The instance may still be completing cloud-init setup" >&2
    echo "You can check instance console via Linode Cloud Manager" >&2
    return 1
}

# Delete a Linode instance
# Usage: delete_linode_instance "TOKEN" "INSTANCE_ID"
delete_linode_instance() {
    local token=$1
    local instance_id=$2

    local response=$(curl -s -X DELETE \
        -H "Authorization: Bearer $token" \
        "https://api.linode.com/v4/linode/instances/$instance_id")

    if echo "$response" | grep -q '"errors"'; then
        echo "ERROR: Failed to delete instance $instance_id" >&2
        echo "$response" >&2
        return 1
    fi

    echo "Instance $instance_id deleted" >&2
    return 0
}

# Provision a test Linode instance and wait for it to be ready
# Usage: provision_test_linode "TOKEN" "LABEL_PREFIX" "SSH_PUBLIC_KEY_PATH"
# Returns: "INSTANCE_ID IP_ADDRESS" on success
provision_test_linode() {
    local token=$1
    local label_prefix=${2:-nwp-test}
    local ssh_key_path=${3:-}
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local label="${label_prefix}-${timestamp}"

    # Auto-detect SSH public key location if not specified
    if [ -z "$ssh_key_path" ]; then
        if [ -f "keys/nwp.pub" ]; then
            ssh_key_path="keys/nwp.pub"
        elif [ -f "$HOME/.ssh/nwp.pub" ]; then
            ssh_key_path="$HOME/.ssh/nwp.pub"
        fi
    fi

    # Read SSH public key from filesystem
    if [ ! -f "$ssh_key_path" ]; then
        echo "ERROR: SSH public key not found at: $ssh_key_path" >&2
        echo "Please run ./setup-ssh.sh to generate SSH keys" >&2
        return 1
    fi

    local ssh_public_key=$(cat "$ssh_key_path")
    if [ -z "$ssh_public_key" ]; then
        echo "ERROR: SSH public key file is empty: $ssh_key_path" >&2
        return 1
    fi

    echo "Using SSH public key from: $ssh_key_path" >&2

    # Create instance
    local instance_id=$(create_linode_instance "$token" "$label" "$ssh_public_key")
    if [ -z "$instance_id" ]; then
        return 1
    fi

    echo "Created instance: $instance_id (label: $label)" >&2

    # Wait for instance to boot
    if ! wait_for_linode "$token" "$instance_id"; then
        delete_linode_instance "$token" "$instance_id"
        return 1
    fi

    # Get IP address
    local ip=$(get_linode_ip "$token" "$instance_id")
    if [ -z "$ip" ]; then
        echo "ERROR: Could not get IP address for instance $instance_id" >&2
        delete_linode_instance "$token" "$instance_id"
        return 1
    fi

    echo "Instance IP: $ip" >&2

    # Wait for SSH
    if ! wait_for_ssh "$ip"; then
        delete_linode_instance "$token" "$instance_id"
        return 1
    fi

    # Return instance ID and IP
    echo "$instance_id $ip"
}

# List all test instances (with nwp-test prefix)
# Usage: list_test_linodes "TOKEN"
list_test_linodes() {
    local token=$1

    local response=$(curl -s -H "Authorization: Bearer $token" \
        "https://api.linode.com/v4/linode/instances")

    echo "$response" | grep -o '"id":[0-9]*,"label":"nwp-test[^"]*"' | \
        sed 's/"id":\([0-9]*\),"label":"\([^"]*\)"/\1 \2/'
}

# Cleanup all test instances
# Usage: cleanup_test_linodes "TOKEN"
cleanup_test_linodes() {
    local token=$1
    local instances=$(list_test_linodes "$token")

    if [ -z "$instances" ]; then
        echo "No test instances to clean up" >&2
        return 0
    fi

    echo "Cleaning up test instances..." >&2
    echo "$instances" | while read instance_id label; do
        echo "Deleting $label ($instance_id)..." >&2
        delete_linode_instance "$token" "$instance_id"
    done
}

################################################################################
# Linode DNS Functions
################################################################################

# Get domain ID by domain name
# Usage: linode_get_domain_id "TOKEN" "example.com"
# Returns: Domain ID or empty string
linode_get_domain_id() {
    local token=$1
    local domain=$2

    local response=$(curl -s -H "Authorization: Bearer $token" \
        "https://api.linode.com/v4/domains")

    # Extract domain ID using grep (handle JSON with or without spaces after colons)
    # Pattern matches: "id": 123456 or "id":123456, with domain matching
    echo "$response" | grep -oE "\"id\":[[:space:]]*[0-9]+,[^}]*\"domain\":[[:space:]]*\"$domain\"" | \
        grep -oE "\"id\":[[:space:]]*[0-9]+" | grep -o "[0-9]*" | head -1
}

# Create a DNS NS record
# Usage: linode_create_dns_ns "TOKEN" "DOMAIN_ID" "subdomain" "nameserver"
# Returns: Record ID on success
linode_create_dns_ns() {
    local token=$1
    local domain_id=$2
    local name=$3
    local target=$4

    local response=$(curl -s -X POST \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{
            \"type\": \"NS\",
            \"name\": \"$name\",
            \"target\": \"$target\",
            \"ttl_sec\": 300
        }" \
        "https://api.linode.com/v4/domains/$domain_id/records")

    if echo "$response" | grep -q '"id"'; then
        local record_id=$(echo "$response" | grep -oE '"id":[[:space:]]*[0-9]+' | grep -oE '[0-9]+')
        echo "$record_id"
        return 0
    else
        echo "ERROR: Failed to create NS record for $name -> $target" >&2
        echo "$response" >&2
        return 1
    fi
}

# Create multiple NS records for subdomain delegation
# Usage: linode_create_ns_delegation "TOKEN" "DOMAIN" "subdomain" "ns1.example.com" "ns2.example.com" ...
# Returns: 0 on success, 1 on failure
linode_create_ns_delegation() {
    local token=$1
    local base_domain=$2
    local subdomain=$3
    shift 3
    local nameservers=("$@")

    # Get domain ID
    local domain_id=$(linode_get_domain_id "$token" "$base_domain")
    if [ -z "$domain_id" ]; then
        echo "ERROR: Domain not found: $base_domain" >&2
        echo "Ensure $base_domain exists in Linode DNS Manager" >&2
        return 1
    fi

    local success=0
    local created_ids=()

    echo "Creating NS delegation for $subdomain.$base_domain..." >&2

    for ns in "${nameservers[@]}"; do
        echo "  Adding NS record: $subdomain -> $ns" >&2
        local record_id=$(linode_create_dns_ns "$token" "$domain_id" "$subdomain" "$ns")
        if [ -n "$record_id" ] && [ "$record_id" != "ERROR:"* ]; then
            created_ids+=("$record_id")
        else
            echo "  Failed to create NS record for $ns" >&2
            success=1
        fi
    done

    if [ $success -eq 0 ]; then
        echo "NS delegation created successfully (${#created_ids[@]} records)" >&2
        echo "${created_ids[*]}"
        return 0
    else
        echo "NS delegation partially failed" >&2
        return 1
    fi
}

# Delete all NS records for a subdomain
# Usage: linode_delete_ns_delegation "TOKEN" "DOMAIN" "subdomain"
linode_delete_ns_delegation() {
    local token=$1
    local base_domain=$2
    local subdomain=$3

    # Get domain ID
    local domain_id=$(linode_get_domain_id "$token" "$base_domain")
    if [ -z "$domain_id" ]; then
        echo "ERROR: Domain not found: $base_domain" >&2
        return 1
    fi

    echo "Removing NS delegation for $subdomain.$base_domain..." >&2

    # Get all NS records for this subdomain
    local response=$(curl -s -H "Authorization: Bearer $token" \
        "https://api.linode.com/v4/domains/$domain_id/records")

    # Extract record IDs for NS records matching the subdomain
    local record_ids=$(echo "$response" | grep -o "\"id\":[0-9]*,\"type\":\"NS\",\"name\":\"$subdomain\"" | \
        grep -o "\"id\":[0-9]*" | grep -o "[0-9]*")

    if [ -z "$record_ids" ]; then
        echo "No NS records found for $subdomain" >&2
        return 0
    fi

    local deleted=0
    for record_id in $record_ids; do
        if linode_delete_dns_record "$token" "$domain_id" "$record_id"; then
            ((deleted++))
        fi
    done

    echo "Deleted $deleted NS records for $subdomain" >&2
    return 0
}

# Delete a DNS record
# Usage: linode_delete_dns_record "TOKEN" "DOMAIN_ID" "RECORD_ID"
linode_delete_dns_record() {
    local token=$1
    local domain_id=$2
    local record_id=$3

    local response=$(curl -s -X DELETE \
        -H "Authorization: Bearer $token" \
        "https://api.linode.com/v4/domains/$domain_id/records/$record_id")

    # Linode returns empty response on successful delete
    if [ -z "$response" ] || echo "$response" | grep -q '"id":[0-9]*'; then
        echo "DNS record $record_id deleted" >&2
        return 0
    else
        echo "ERROR: Failed to delete DNS record $record_id" >&2
        return 1
    fi
}

# List NS records for a subdomain
# Usage: linode_list_ns_records "TOKEN" "DOMAIN" "subdomain"
linode_list_ns_records() {
    local token=$1
    local base_domain=$2
    local subdomain=$3

    # Get domain ID
    local domain_id=$(linode_get_domain_id "$token" "$base_domain")
    if [ -z "$domain_id" ]; then
        echo "ERROR: Domain not found: $base_domain" >&2
        return 1
    fi

    local response=$(curl -s -H "Authorization: Bearer $token" \
        "https://api.linode.com/v4/domains/$domain_id/records")

    # Parse and display NS records for the subdomain
    echo "$response" | grep "\"type\":\"NS\",\"name\":\"$subdomain\"" | \
        grep -o "\"target\":\"[^\"]*\"" | cut -d'"' -f4
}

# Verify Linode DNS API access
# Usage: verify_linode_dns "TOKEN" "DOMAIN"
# Returns: 0 on success, 1 on failure
verify_linode_dns() {
    local token=$1
    local domain=$2

    local domain_id=$(linode_get_domain_id "$token" "$domain")

    if [ -n "$domain_id" ]; then
        echo "Authenticated for domain: $domain (ID: $domain_id)" >&2
        return 0
    else
        echo "ERROR: Domain not found in Linode DNS: $domain" >&2
        echo "Create the domain in Linode DNS Manager first" >&2
        return 1
    fi
}

# Create or update DNS A record
# Usage: linode_upsert_dns_a "TOKEN" "DOMAIN_ID" "name" "target_ip" "ttl"
# Returns: Record ID on success
linode_upsert_dns_a() {
    local token=$1
    local domain_id=$2
    local name=$3
    local target=$4
    local ttl=${5:-300}

    # Check if record exists
    local response=$(curl -s -H "Authorization: Bearer $token" \
        "https://api.linode.com/v4/domains/$domain_id/records")

    # Look for existing A record with this name (handle JSON with spaces after colons)
    local existing_id=$(echo "$response" | grep -oE "\"id\":[[:space:]]*[0-9]+,[^}]*\"type\":[[:space:]]*\"A\",[^}]*\"name\":[[:space:]]*\"$name\"" | \
        grep -oE "\"id\":[[:space:]]*[0-9]+" | grep -o "[0-9]*" | head -1)

    if [ -n "$existing_id" ]; then
        # Update existing record
        local update_response=$(curl -s -X PUT \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "{
                \"target\": \"$target\",
                \"ttl_sec\": $ttl
            }" \
            "https://api.linode.com/v4/domains/$domain_id/records/$existing_id")

        if echo "$update_response" | grep -qE '"id":[[:space:]]*[0-9]+'; then
            echo "$existing_id"
            return 0
        else
            echo "ERROR: Failed to update A record for $name" >&2
            echo "$update_response" | grep -oE '"errors":[[:space:]]*\[.*\]' >&2
            return 1
        fi
    else
        # Create new record
        local create_response=$(curl -s -X POST \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "{
                \"type\": \"A\",
                \"name\": \"$name\",
                \"target\": \"$target\",
                \"ttl_sec\": $ttl
            }" \
            "https://api.linode.com/v4/domains/$domain_id/records")

        if echo "$create_response" | grep -qE '"id":[[:space:]]*[0-9]+'; then
            local record_id=$(echo "$create_response" | grep -oE '"id":[[:space:]]*[0-9]+' | head -1 | grep -o '[0-9]*')
            echo "$record_id"
            return 0
        else
            echo "ERROR: Failed to create A record for $name -> $target" >&2
            echo "$create_response" | grep -oE '"errors":[[:space:]]*\[.*\]' >&2
            return 1
        fi
    fi
}

# Create A record for full domain (e.g., podcast.example.com)
# Usage: linode_create_dns_a_for_domain "TOKEN" "podcast.example.com" "IP"
# Returns: Record ID on success
linode_create_dns_a_for_domain() {
    local token=$1
    local fqdn=$2
    local target_ip=$3

    # Extract base domain and subdomain
    local base_domain="${fqdn#*.}"
    local subdomain="${fqdn%%.*}"

    # Handle case where fqdn has more than two parts (e.g., gm.opencat.org)
    # We need to find the actual registered domain in Linode
    local domain_id=""
    local test_domain="$fqdn"

    # Try progressively shorter domains until we find one that exists
    while [[ "$test_domain" == *.* ]]; do
        domain_id=$(linode_get_domain_id "$token" "$test_domain")
        if [ -n "$domain_id" ]; then
            # Found the base domain, now calculate the subdomain part
            if [ "$test_domain" = "$fqdn" ]; then
                subdomain=""  # It's the root domain
            else
                subdomain="${fqdn%.$test_domain}"
            fi
            break
        fi
        test_domain="${test_domain#*.}"
    done

    if [ -z "$domain_id" ]; then
        echo "ERROR: Could not find domain in Linode DNS for: $fqdn" >&2
        echo "Ensure the base domain exists in Linode DNS Manager" >&2
        return 1
    fi

    echo "Creating A record: $subdomain.$test_domain -> $target_ip" >&2
    linode_upsert_dns_a "$token" "$domain_id" "$subdomain" "$target_ip"
}

# Export functions for use in other scripts
export -f get_linode_token
export -f get_ssh_key_id
export -f get_first_ssh_key_id
export -f create_linode_instance
export -f wait_for_linode
export -f get_linode_ip
export -f wait_for_ssh
export -f delete_linode_instance
export -f provision_test_linode
export -f list_test_linodes
export -f cleanup_test_linodes
export -f linode_get_domain_id
export -f linode_create_dns_ns
export -f linode_create_ns_delegation
export -f linode_delete_ns_delegation
export -f linode_delete_dns_record
export -f linode_list_ns_records
export -f verify_linode_dns
export -f linode_upsert_dns_a
export -f linode_create_dns_a_for_domain
