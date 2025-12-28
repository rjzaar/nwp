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

# Get Linode API token
get_linode_token() {
    local token=""
    local script_dir="${1:-.}"

    # Check .secrets.yml first
    if [ -f "$script_dir/.secrets.yml" ]; then
        token=$(awk '/^linode:/{f=1} f && /api_token:/{print $2; exit}' "$script_dir/.secrets.yml" | tr -d '"' | tr -d "'")
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
# Usage: create_linode_instance "TOKEN" "LABEL" "SSH_KEY_ID" "REGION" "TYPE"
# Returns: Instance ID
create_linode_instance() {
    local token=$1
    local label=$2
    local ssh_key_id=$3
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
            \"authorized_keys\": [$ssh_key_id],
            \"booted\": true,
            \"backups_enabled\": false,
            \"private_ip\": false
        }")

    if echo "$response" | grep -q '"id"'; then
        echo "$response" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2
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

        local status=$(echo "$response" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)

        if [ "$status" = "running" ]; then
            echo "Instance is running" >&2
            return 0
        fi

        echo -n "." >&2
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
    echo "$response" | grep -o '"ipv4":\["[^"]*"' | cut -d'"' -f4
}

# Wait for SSH to be available on instance
# Usage: wait_for_ssh "IP_ADDRESS" "SSH_KEY_PATH" "MAX_WAIT_SECONDS"
wait_for_ssh() {
    local ip=$1
    local ssh_key=${2:-~/.ssh/nwp}
    local max_wait=${3:-180}
    local elapsed=0

    echo "Waiting for SSH to be available on $ip..." >&2

    while [ $elapsed -lt $max_wait ]; do
        if ssh -i "$ssh_key" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
            -o BatchMode=yes root@$ip "exit" 2>/dev/null; then
            echo "SSH is ready" >&2
            return 0
        fi

        echo -n "." >&2
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo "ERROR: SSH did not become available within $max_wait seconds" >&2
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
# Usage: provision_test_linode "TOKEN" "LABEL_PREFIX"
# Returns: "INSTANCE_ID IP_ADDRESS" on success
provision_test_linode() {
    local token=$1
    local label_prefix=${2:-nwp-test}
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local label="${label_prefix}-${timestamp}"

    # Get first SSH key from account
    local ssh_key_id=$(get_first_ssh_key_id "$token")
    if [ -z "$ssh_key_id" ]; then
        echo "ERROR: No SSH keys found in Linode account" >&2
        echo "Please add your SSH key manually at https://cloud.linode.com/profile/keys" >&2
        return 1
    fi

    echo "Using SSH key ID: $ssh_key_id" >&2

    # Create instance
    local instance_id=$(create_linode_instance "$token" "$label" "$ssh_key_id")
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
