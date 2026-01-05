#!/bin/bash

################################################################################
# Cloudflare API Helper Functions
#
# Provides functions for managing DNS records, transform rules, and cache rules
# via the Cloudflare API for podcast hosting setup.
#
# Requirements:
# - CF_API_TOKEN environment variable or .secrets.yml with cloudflare.api_token
# - CF_ZONE_ID environment variable or .secrets.yml with cloudflare.zone_id
# - curl and jq installed
################################################################################

# Source linode.sh for parse_yaml_value if not already available
if ! declare -f parse_yaml_value &>/dev/null; then
    CLOUDFLARE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$CLOUDFLARE_LIB_DIR/linode.sh" ]; then
        source "$CLOUDFLARE_LIB_DIR/linode.sh"
    fi
fi

# Get Cloudflare API token
# Usage: get_cloudflare_token [script_dir]
get_cloudflare_token() {
    local token=""
    local script_dir="${1:-.}"

    # Check .secrets.yml first
    if [ -f "$script_dir/.secrets.yml" ]; then
        token=$(parse_yaml_value "$script_dir/.secrets.yml" "cloudflare" "api_token")
    fi

    # Fall back to environment variable
    if [ -z "$token" ] && [ -n "${CF_API_TOKEN:-}" ]; then
        token="$CF_API_TOKEN"
    fi

    echo "$token"
}

# Get Cloudflare Zone ID
# Usage: get_cloudflare_zone_id [script_dir]
get_cloudflare_zone_id() {
    local zone_id=""
    local script_dir="${1:-.}"

    # Check .secrets.yml first
    if [ -f "$script_dir/.secrets.yml" ]; then
        zone_id=$(parse_yaml_value "$script_dir/.secrets.yml" "cloudflare" "zone_id")
    fi

    # Fall back to environment variable
    if [ -z "$zone_id" ] && [ -n "${CF_ZONE_ID:-}" ]; then
        zone_id="$CF_ZONE_ID"
    fi

    echo "$zone_id"
}

# Verify Cloudflare API credentials
# Usage: verify_cloudflare_auth "TOKEN" "ZONE_ID"
# Returns: 0 on success, 1 on failure
verify_cloudflare_auth() {
    local token=$1
    local zone_id=$2

    local response=$(curl -s "https://api.cloudflare.com/client/v4/zones/$zone_id" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json")

    if echo "$response" | grep -q '"success":true'; then
        local zone_name=$(echo "$response" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)
        echo "Authenticated for zone: $zone_name" >&2
        return 0
    else
        echo "ERROR: Cloudflare authentication failed" >&2
        echo "$response" | grep -o '"message":"[^"]*"' | cut -d'"' -f4 >&2
        return 1
    fi
}

# Create a DNS A record
# Usage: cf_create_dns_a "TOKEN" "ZONE_ID" "subdomain" "IP" [proxied: true/false]
# Returns: Record ID on success
cf_create_dns_a() {
    local token=$1
    local zone_id=$2
    local name=$3
    local ip=$4
    local proxied=${5:-true}

    local response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{
            \"type\": \"A\",
            \"name\": \"$name\",
            \"content\": \"$ip\",
            \"ttl\": 1,
            \"proxied\": $proxied
        }")

    if echo "$response" | grep -q '"success":true'; then
        local record_id=$(echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        echo "$record_id"
        return 0
    else
        echo "ERROR: Failed to create DNS A record for $name" >&2
        echo "$response" | grep -o '"message":"[^"]*"' | cut -d'"' -f4 >&2
        return 1
    fi
}

# Create a DNS CNAME record
# Usage: cf_create_dns_cname "TOKEN" "ZONE_ID" "subdomain" "target" [proxied: true/false]
# Returns: Record ID on success
cf_create_dns_cname() {
    local token=$1
    local zone_id=$2
    local name=$3
    local target=$4
    local proxied=${5:-true}

    local response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{
            \"type\": \"CNAME\",
            \"name\": \"$name\",
            \"content\": \"$target\",
            \"ttl\": 1,
            \"proxied\": $proxied
        }")

    if echo "$response" | grep -q '"success":true'; then
        local record_id=$(echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        echo "$record_id"
        return 0
    else
        echo "ERROR: Failed to create DNS CNAME record for $name" >&2
        echo "$response" | grep -o '"message":"[^"]*"' | cut -d'"' -f4 >&2
        return 1
    fi
}

# Get DNS record ID by name and type
# Usage: cf_get_dns_record_id "TOKEN" "ZONE_ID" "name" "type"
cf_get_dns_record_id() {
    local token=$1
    local zone_id=$2
    local name=$3
    local type=$4

    local response=$(curl -s "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?name=$name&type=$type" \
        -H "Authorization: Bearer $token")

    if echo "$response" | grep -q '"success":true'; then
        local record_id=$(echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        echo "$record_id"
    fi
}

# Update a DNS record
# Usage: cf_update_dns_record "TOKEN" "ZONE_ID" "RECORD_ID" "type" "name" "content" [proxied]
cf_update_dns_record() {
    local token=$1
    local zone_id=$2
    local record_id=$3
    local type=$4
    local name=$5
    local content=$6
    local proxied=${7:-true}

    local response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{
            \"type\": \"$type\",
            \"name\": \"$name\",
            \"content\": \"$content\",
            \"ttl\": 1,
            \"proxied\": $proxied
        }")

    if echo "$response" | grep -q '"success":true'; then
        return 0
    else
        echo "ERROR: Failed to update DNS record $record_id" >&2
        echo "$response" | grep -o '"message":"[^"]*"' | cut -d'"' -f4 >&2
        return 1
    fi
}

# Create a DNS NS record (for subdomain delegation)
# Usage: cf_create_dns_ns "TOKEN" "ZONE_ID" "subdomain" "nameserver"
# Returns: Record ID on success
cf_create_dns_ns() {
    local token=$1
    local zone_id=$2
    local name=$3
    local nameserver=$4

    local response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{
            \"type\": \"NS\",
            \"name\": \"$name\",
            \"content\": \"$nameserver\",
            \"ttl\": 3600
        }")

    if echo "$response" | grep -q '"success":true'; then
        local record_id=$(echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        echo "$record_id"
        return 0
    else
        echo "ERROR: Failed to create DNS NS record for $name -> $nameserver" >&2
        echo "$response" | grep -o '"message":"[^"]*"' | cut -d'"' -f4 >&2
        return 1
    fi
}

# Create multiple NS records for subdomain delegation
# Usage: cf_create_ns_delegation "TOKEN" "ZONE_ID" "subdomain" "ns1.example.com ns2.example.com ..."
# Returns: 0 on success, 1 on failure
cf_create_ns_delegation() {
    local token=$1
    local zone_id=$2
    local subdomain=$3
    shift 3
    local nameservers=("$@")

    local success=0
    local created_ids=()

    echo "Creating NS delegation for $subdomain..." >&2

    for ns in "${nameservers[@]}"; do
        echo "  Adding NS record: $subdomain -> $ns" >&2
        local record_id=$(cf_create_dns_ns "$token" "$zone_id" "$subdomain" "$ns")
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
# Usage: cf_delete_ns_delegation "TOKEN" "ZONE_ID" "subdomain"
cf_delete_ns_delegation() {
    local token=$1
    local zone_id=$2
    local subdomain=$3

    echo "Removing NS delegation for $subdomain..." >&2

    # Get all NS records for this subdomain
    local response=$(curl -s "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=NS&name=$subdomain" \
        -H "Authorization: Bearer $token")

    if ! echo "$response" | grep -q '"success":true'; then
        echo "ERROR: Failed to list NS records" >&2
        return 1
    fi

    # Extract record IDs
    local record_ids=$(echo "$response" | jq -r '.result[].id' 2>/dev/null || \
        echo "$response" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$record_ids" ]; then
        echo "No NS records found for $subdomain" >&2
        return 0
    fi

    local deleted=0
    for record_id in $record_ids; do
        if cf_delete_dns_record "$token" "$zone_id" "$record_id"; then
            ((deleted++))
        fi
    done

    echo "Deleted $deleted NS records for $subdomain" >&2
    return 0
}

# List NS records for a subdomain
# Usage: cf_list_ns_records "TOKEN" "ZONE_ID" "subdomain"
cf_list_ns_records() {
    local token=$1
    local zone_id=$2
    local subdomain=$3

    local response=$(curl -s "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=NS&name=$subdomain" \
        -H "Authorization: Bearer $token")

    if echo "$response" | grep -q '"success":true'; then
        echo "$response" | jq -r '.result[] | "\(.name)\t\(.content)"' 2>/dev/null || \
        echo "$response" | grep -o '"content":"[^"]*"' | cut -d'"' -f4
    else
        echo "ERROR: Failed to list NS records" >&2
        return 1
    fi
}

# Delete a DNS record
# Usage: cf_delete_dns_record "TOKEN" "ZONE_ID" "RECORD_ID"
cf_delete_dns_record() {
    local token=$1
    local zone_id=$2
    local record_id=$3

    local response=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
        -H "Authorization: Bearer $token")

    if echo "$response" | grep -q '"success":true'; then
        echo "DNS record $record_id deleted" >&2
        return 0
    else
        echo "ERROR: Failed to delete DNS record $record_id" >&2
        return 1
    fi
}

# List all DNS records for a zone
# Usage: cf_list_dns_records "TOKEN" "ZONE_ID" [type_filter]
cf_list_dns_records() {
    local token=$1
    local zone_id=$2
    local type_filter=${3:-}

    local url="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?per_page=100"
    if [ -n "$type_filter" ]; then
        url="${url}&type=$type_filter"
    fi

    local response=$(curl -s "$url" \
        -H "Authorization: Bearer $token")

    if echo "$response" | grep -q '"success":true'; then
        echo "$response" | jq -r '.result[] | "\(.type)\t\(.name)\t\(.content)\t\(.id)"' 2>/dev/null || \
        echo "$response" | grep -o '"type":"[^"]*","name":"[^"]*","content":"[^"]*"' | \
            sed 's/"type":"//g; s/","name":"/\t/g; s/","content":"/\t/g; s/"$//g'
    else
        echo "ERROR: Failed to list DNS records" >&2
        return 1
    fi
}

# Create or update DNS record (upsert)
# Usage: cf_upsert_dns_a "TOKEN" "ZONE_ID" "subdomain" "IP" [proxied]
cf_upsert_dns_a() {
    local token=$1
    local zone_id=$2
    local name=$3
    local ip=$4
    local proxied=${5:-true}

    # Check if record exists
    local existing_id=$(cf_get_dns_record_id "$token" "$zone_id" "$name" "A")

    if [ -n "$existing_id" ]; then
        echo "Updating existing A record for $name" >&2
        cf_update_dns_record "$token" "$zone_id" "$existing_id" "A" "$name" "$ip" "$proxied"
        echo "$existing_id"
    else
        echo "Creating new A record for $name" >&2
        cf_create_dns_a "$token" "$zone_id" "$name" "$ip" "$proxied"
    fi
}

# Create a Transform Rule for URL rewriting (e.g., B2 media proxy)
# Usage: cf_create_transform_rule "TOKEN" "ZONE_ID" "rule_name" "expression" "rewrite_uri"
# Note: This creates a URI Path rewrite rule
cf_create_transform_rule() {
    local token=$1
    local zone_id=$2
    local rule_name=$3
    local expression=$4
    local rewrite_uri=$5

    # Get existing rules first
    local existing=$(curl -s "https://api.cloudflare.com/client/v4/zones/$zone_id/rulesets?phase=http_request_transform" \
        -H "Authorization: Bearer $token")

    local ruleset_id=$(echo "$existing" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -z "$ruleset_id" ]; then
        # Create new ruleset with the rule
        local response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/rulesets" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "{
                \"name\": \"NWP Transform Rules\",
                \"kind\": \"zone\",
                \"phase\": \"http_request_transform\",
                \"rules\": [{
                    \"expression\": \"$expression\",
                    \"description\": \"$rule_name\",
                    \"action\": \"rewrite\",
                    \"action_parameters\": {
                        \"uri\": {
                            \"path\": {
                                \"expression\": \"$rewrite_uri\"
                            }
                        }
                    }
                }]
            }")
    else
        # Add rule to existing ruleset
        local response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/rulesets/$ruleset_id/rules" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "{
                \"expression\": \"$expression\",
                \"description\": \"$rule_name\",
                \"action\": \"rewrite\",
                \"action_parameters\": {
                    \"uri\": {
                        \"path\": {
                            \"expression\": \"$rewrite_uri\"
                        }
                    }
                }
            }")
    fi

    if echo "$response" | grep -q '"success":true' || echo "$response" | grep -q '"id"'; then
        echo "Transform rule created: $rule_name" >&2
        return 0
    else
        echo "ERROR: Failed to create transform rule" >&2
        echo "$response" >&2
        return 1
    fi
}

# Create a Cache Rule
# Usage: cf_create_cache_rule "TOKEN" "ZONE_ID" "rule_name" "expression" "cache_ttl"
cf_create_cache_rule() {
    local token=$1
    local zone_id=$2
    local rule_name=$3
    local expression=$4
    local cache_ttl=${5:-86400}  # Default 24 hours

    # Get existing rules first
    local existing=$(curl -s "https://api.cloudflare.com/client/v4/zones/$zone_id/rulesets?phase=http_request_cache_settings" \
        -H "Authorization: Bearer $token")

    local ruleset_id=$(echo "$existing" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    local rule_data="{
        \"expression\": \"$expression\",
        \"description\": \"$rule_name\",
        \"action\": \"set_cache_settings\",
        \"action_parameters\": {
            \"cache\": true,
            \"edge_ttl\": {
                \"mode\": \"override_origin\",
                \"default\": $cache_ttl
            },
            \"browser_ttl\": {
                \"mode\": \"override_origin\",
                \"default\": $cache_ttl
            }
        }
    }"

    if [ -z "$ruleset_id" ]; then
        # Create new ruleset with the rule
        local response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/rulesets" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "{
                \"name\": \"NWP Cache Rules\",
                \"kind\": \"zone\",
                \"phase\": \"http_request_cache_settings\",
                \"rules\": [$rule_data]
            }")
    else
        # Add rule to existing ruleset
        local response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/rulesets/$ruleset_id/rules" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "$rule_data")
    fi

    if echo "$response" | grep -q '"success":true' || echo "$response" | grep -q '"id"'; then
        echo "Cache rule created: $rule_name" >&2
        return 0
    else
        echo "ERROR: Failed to create cache rule" >&2
        echo "$response" >&2
        return 1
    fi
}

# Purge cache for a zone
# Usage: cf_purge_cache "TOKEN" "ZONE_ID" [files_array_json]
cf_purge_cache() {
    local token=$1
    local zone_id=$2
    local files=${3:-}

    local data
    if [ -n "$files" ]; then
        data="{\"files\": $files}"
    else
        data='{"purge_everything": true}'
    fi

    local response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/purge_cache" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$data")

    if echo "$response" | grep -q '"success":true'; then
        echo "Cache purged successfully" >&2
        return 0
    else
        echo "ERROR: Failed to purge cache" >&2
        return 1
    fi
}

# Get zone details
# Usage: cf_get_zone "TOKEN" "ZONE_ID"
cf_get_zone() {
    local token=$1
    local zone_id=$2

    curl -s "https://api.cloudflare.com/client/v4/zones/$zone_id" \
        -H "Authorization: Bearer $token"
}

# Export functions
export -f get_cloudflare_token
export -f get_cloudflare_zone_id
export -f verify_cloudflare_auth
export -f cf_create_dns_a
export -f cf_create_dns_cname
export -f cf_create_dns_ns
export -f cf_create_ns_delegation
export -f cf_delete_ns_delegation
export -f cf_list_ns_records
export -f cf_get_dns_record_id
export -f cf_update_dns_record
export -f cf_delete_dns_record
export -f cf_list_dns_records
export -f cf_upsert_dns_a
export -f cf_create_transform_rule
export -f cf_create_cache_rule
export -f cf_purge_cache
export -f cf_get_zone
