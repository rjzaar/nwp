#!/bin/bash
# lib/claude-api.sh - Claude API provisioning and management
# Part of NWP (Narrow Way Project)

# Double-source guard
if [[ "${_CLAUDE_API_SH_LOADED:-}" == "1" ]]; then
    return 0
fi
_CLAUDE_API_SH_LOADED=1

# Get Claude organization API key from infrastructure secrets
get_claude_org_key() {
    get_infra_secret "claude.org_api_key" ""
}

# Get Claude admin API key from infrastructure secrets
get_claude_admin_key() {
    get_infra_secret "claude.admin_api_key" ""
}

# Get default Claude model from settings
get_claude_default_model() {
    local config_file="${1:-${PROJECT_ROOT}/nwp.yml}"
    local model=""
    model=$(awk '/^settings:/{found=1} found && /claude:/{in_claude=1} in_claude && /default_model:/{print $2; exit}' "$config_file" 2>/dev/null)
    echo "${model:-claude-sonnet-4-5}"
}

# Get per-coder monthly spend limit
get_claude_coder_limit() {
    local config_file="${1:-${PROJECT_ROOT}/nwp.yml}"
    local limit=""
    limit=$(awk '/^settings:/{found=1} found && /claude:/{in_claude=1} in_claude && /per_coder_monthly_limit_usd:/{print $2; exit}' "$config_file" 2>/dev/null)
    echo "${limit:-100}"
}

# Check if Claude API integration is enabled
is_claude_enabled() {
    local config_file="${1:-${PROJECT_ROOT}/nwp.yml}"
    local enabled=""
    enabled=$(awk '/^settings:/{found=1} found && /claude:/{in_claude=1} in_claude && /enabled:/{print $2; exit}' "$config_file" 2>/dev/null)
    [[ "$enabled" == "true" ]]
}

# Create NWP workspace via Admin API
# Usage: create_nwp_workspace <workspace_name>
create_nwp_workspace() {
    local workspace_name="${1:-nwp}"
    local admin_key
    admin_key=$(get_claude_admin_key)

    if [[ -z "$admin_key" ]]; then
        print_error "Claude admin API key not configured in .secrets.yml"
        return 1
    fi

    print_info "Creating Claude workspace '${workspace_name}'..."

    local response
    response=$(curl -s -X POST "https://api.anthropic.com/v1/organizations/workspaces" \
        -H "x-api-key: ${admin_key}" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "{\"name\": \"${workspace_name}\"}" 2>&1)

    local workspace_id
    workspace_id=$(echo "$response" | awk -F'"' '/"id"/{print $4; exit}')

    if [[ -n "$workspace_id" ]]; then
        print_success "Workspace created: ${workspace_id}"
        echo "$workspace_id"
    else
        print_error "Failed to create workspace: ${response}"
        return 1
    fi
}

# Provision a workspace-scoped API key for a coder
# Usage: provision_coder_api_key <coder_name> <workspace_id>
provision_coder_api_key() {
    local coder_name="$1"
    local workspace_id="$2"
    local admin_key
    admin_key=$(get_claude_admin_key)

    if [[ -z "$admin_key" ]]; then
        print_error "Claude admin API key not configured"
        return 1
    fi

    print_info "Provisioning API key for ${coder_name}..."

    local response
    response=$(curl -s -X POST "https://api.anthropic.com/v1/organizations/api_keys" \
        -H "x-api-key: ${admin_key}" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "{\"name\": \"nwp-${coder_name}\", \"workspace_id\": \"${workspace_id}\"}" 2>&1)

    local api_key
    api_key=$(echo "$response" | awk -F'"' '/"api_key"/{print $4; exit}')

    if [[ -n "$api_key" ]]; then
        print_success "API key provisioned for ${coder_name}"
        echo "$api_key"
    else
        print_error "Failed to provision key: ${response}"
        return 1
    fi
}

# Set workspace spend limit
# Usage: set_workspace_spend_limit <workspace_id> <monthly_limit_usd>
set_workspace_spend_limit() {
    local workspace_id="$1"
    local monthly_limit="${2:-500}"
    local admin_key
    admin_key=$(get_claude_admin_key)

    print_info "Setting spend limit: \$${monthly_limit}/month for workspace ${workspace_id}"

    curl -s -X POST "https://api.anthropic.com/v1/organizations/workspaces/${workspace_id}/limits" \
        -H "x-api-key: ${admin_key}" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "{\"monthly_limit_usd\": ${monthly_limit}}" >/dev/null 2>&1

    print_success "Spend limit set"
}

# Get workspace usage summary
# Usage: get_workspace_usage [workspace_id]
get_workspace_usage() {
    local workspace_id="${1:-}"
    local admin_key
    admin_key=$(get_claude_admin_key)

    if [[ -z "$admin_key" ]]; then
        print_error "Claude admin API key not configured"
        return 1
    fi

    local url="https://api.anthropic.com/v1/organizations/usage"
    [[ -n "$workspace_id" ]] && url="${url}?workspace_id=${workspace_id}"

    curl -s "$url" \
        -H "x-api-key: ${admin_key}" \
        -H "anthropic-version: 2023-06-01"
}

# Display Claude usage summary
show_claude_usage_summary() {
    local usage
    usage=$(get_workspace_usage)

    if [[ -z "$usage" ]]; then
        print_warning "Could not retrieve usage data"
        return 1
    fi

    print_info "Claude API Usage Summary"
    echo "$usage" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(f\"  Input tokens:  {data.get('input_tokens', 'N/A'):>12,}\")
    print(f\"  Output tokens: {data.get('output_tokens', 'N/A'):>12,}\")
    print(f\"  Total cost:    \${data.get('total_cost_usd', 0):>11.2f}\")
except:
    print('  Unable to parse usage data')
" 2>/dev/null || echo "  (Install python3 for formatted output)"
}

# Rotate a coder's API key (disable old, provision new)
# Usage: rotate_coder_api_key <coder_name> <workspace_id> <old_key_id>
rotate_coder_api_key() {
    local coder_name="$1"
    local workspace_id="$2"
    local old_key_id="$3"
    local admin_key
    admin_key=$(get_claude_admin_key)

    print_info "Rotating API key for ${coder_name}..."

    # Disable old key
    curl -s -X POST "https://api.anthropic.com/v1/organizations/api_keys/${old_key_id}/disable" \
        -H "x-api-key: ${admin_key}" \
        -H "anthropic-version: 2023-06-01" >/dev/null 2>&1

    # Provision new key
    local new_key
    new_key=$(provision_coder_api_key "$coder_name" "$workspace_id")

    if [[ -n "$new_key" ]]; then
        print_success "Key rotated for ${coder_name}"
        echo "$new_key"
    else
        print_error "Failed to rotate key - old key disabled but new key failed"
        return 1
    fi
}

# Test Claude API connectivity without exposing credentials
# Usage: safe_claude_status
safe_claude_status() {
    local org_key
    org_key=$(get_claude_org_key)

    if [[ -z "$org_key" ]]; then
        print_warning "Claude API not configured"
        return 1
    fi

    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" "https://api.anthropic.com/v1/messages" \
        -H "x-api-key: ${org_key}" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d '{"model":"claude-haiku-3-5","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}' 2>&1)

    case "$response" in
        200) print_success "Claude API: Connected (key valid)" ;;
        401) print_error "Claude API: Invalid key" ; return 1 ;;
        429) print_warning "Claude API: Rate limited (but key valid)" ;;
        *) print_warning "Claude API: HTTP ${response}" ;;
    esac
}
