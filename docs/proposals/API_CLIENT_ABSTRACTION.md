# API Client Abstraction Layer - Implementation Plan

**Status:** PROPOSAL
**Created:** 2026-01-13
**Problem:** Direct curl + grep API calls are brittle, untestable, and break silently on API changes
**Solution:** Phased migration to abstraction layer with validation, error handling, and optional SDK integration

---

## Executive Summary

NWP currently uses direct `curl` commands with `grep`/`jq` parsing throughout the codebase. This creates:

- **Silent failures** when APIs change (Brittleness: 6-8/10)
- **No type safety** or structural validation
- **Scattered error handling** (or none at all)
- **Difficult testing** (requires mocking HTTP calls)
- **Version lock-in** (no API version tracking)

This plan migrates to a layered architecture:

```
┌─────────────────────────────────────────────────────────┐
│  Application Code (coder-setup.sh, live-deploy.sh)     │
└────────────────────┬────────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────────┐
│  API Abstraction Layer (lib/api/*.sh)                   │
│  - Validates responses                                  │
│  - Handles errors consistently                          │
│  - Logs API versions                                    │
│  - Provides clear error messages                        │
└────────────────────┬────────────────────────────────────┘
                     │
        ┌────────────┴────────────┐
        │                         │
┌───────▼──────┐         ┌────────▼─────────┐
│  curl + jq   │         │  Official CLI    │
│  (default)   │         │  (when better)   │
└──────────────┘         └──────────────────┘
```

---

## Phase 1: Foundation (Week 1-2)

### 1.1 Create API Abstraction Layer Structure

**Goal:** Establish the foundational library structure

#### 1.1.1 Create Core API Library
```bash
mkdir -p lib/api
touch lib/api/common.sh      # Shared API utilities
touch lib/api/linode.sh      # Linode API wrapper
touch lib/api/cloudflare.sh  # Cloudflare API wrapper
touch lib/api/gitlab.sh      # GitLab API wrapper
```

#### 1.1.2 Implement `lib/api/common.sh`

**File:** `lib/api/common.sh`

```bash
#!/bin/bash
################################################################################
# API Common Utilities
#
# Shared functions for all API clients:
#   - Response validation
#   - Error handling
#   - Logging
#   - Retry logic
################################################################################

# API response validation
api_validate_response() {
    local response="$1"
    local expected_field="$2"
    local api_name="${3:-API}"

    # Check if response is valid JSON
    if ! echo "$response" | jq empty 2>/dev/null; then
        log_error "$api_name returned invalid JSON"
        return 1
    fi

    # Check for API error fields
    if echo "$response" | jq -e '.errors[]?' >/dev/null 2>&1; then
        local error_msg=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "$api_name error: $error_msg"
        return 1
    fi

    # Check for expected field (if provided)
    if [ -n "$expected_field" ]; then
        if ! echo "$response" | jq -e "$expected_field" >/dev/null 2>&1; then
            log_error "$api_name response missing expected field: $expected_field"
            return 1
        fi
    fi

    return 0
}

# Execute API call with retry logic
api_call_with_retry() {
    local max_retries="${1:-3}"
    local retry_delay="${2:-5}"
    shift 2
    local cmd=("$@")

    local attempt=1
    while [ $attempt -le $max_retries ]; do
        local response
        response=$("${cmd[@]}" 2>&1)
        local exit_code=$?

        if [ $exit_code -eq 0 ]; then
            echo "$response"
            return 0
        fi

        log_warn "API call failed (attempt $attempt/$max_retries)"

        if [ $attempt -lt $max_retries ]; then
            log_info "Retrying in ${retry_delay}s..."
            sleep "$retry_delay"
        fi

        ((attempt++))
    done

    log_error "API call failed after $max_retries attempts"
    return 1
}

# Extract field from JSON response
api_extract_field() {
    local response="$1"
    local field_path="$2"
    local default="${3:-}"

    local value
    value=$(echo "$response" | jq -r "$field_path // empty" 2>/dev/null)

    if [ -z "$value" ]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Log API call (for debugging)
api_log_call() {
    local api_name="$1"
    local endpoint="$2"
    local method="${3:-GET}"

    if [ "${API_DEBUG:-0}" = "1" ]; then
        log_debug "[$api_name] $method $endpoint"
    fi
}

# Check if API credentials are available
api_check_credentials() {
    local api_name="$1"
    local token_var="$2"

    if [ -z "${!token_var}" ]; then
        log_error "$api_name credentials not found (${token_var})"
        return 1
    fi

    return 0
}
```

**Tasks:**
- [ ] Create `lib/api/common.sh` with core utilities
- [ ] Add response validation function
- [ ] Add retry logic with exponential backoff
- [ ] Add JSON field extraction helpers
- [ ] Add API call logging for debugging
- [ ] Add credential checking

---

### 1.2 Implement Linode API Wrapper

**Goal:** Create complete Linode API abstraction

#### 1.2.1 Core Linode Functions

**File:** `lib/api/linode.sh`

```bash
#!/bin/bash
################################################################################
# Linode API Wrapper
#
# Abstraction layer for Linode API v4
# API Docs: https://www.linode.com/docs/api/
################################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

LINODE_API_VERSION="v4"
LINODE_API_BASE="https://api.linode.com/${LINODE_API_VERSION}"

# Initialize Linode API client
linode_init() {
    local token="$1"

    if ! api_check_credentials "Linode" "token"; then
        return 1
    fi

    export LINODE_TOKEN="$token"
    log_info "Linode API initialized (v4)"
}

# Execute Linode API call
linode_api_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    api_log_call "Linode" "$endpoint" "$method"

    local curl_opts=(
        -s
        -X "$method"
        -H "Authorization: Bearer ${LINODE_TOKEN}"
        -H "Content-Type: application/json"
    )

    if [ -n "$data" ]; then
        curl_opts+=(-d "$data")
    fi

    local response
    response=$(api_call_with_retry 3 5 curl "${curl_opts[@]}" "${LINODE_API_BASE}${endpoint}")
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        return 1
    fi

    if ! api_validate_response "$response" "" "Linode"; then
        return 1
    fi

    echo "$response"
}

# List domains
linode_domains_list() {
    local response
    response=$(linode_api_call GET "/domains")

    if [ $? -ne 0 ]; then
        return 1
    fi

    echo "$response" | jq -r '.data[]'
}

# Get domain by name
linode_domain_get() {
    local domain_name="$1"

    local response
    response=$(linode_domains_list)

    echo "$response" | jq -r --arg domain "$domain_name" \
        'select(.domain == $domain)'
}

# Get domain ID by name
linode_domain_get_id() {
    local domain_name="$1"

    local domain
    domain=$(linode_domain_get "$domain_name")

    if [ -z "$domain" ]; then
        log_error "Domain not found: $domain_name"
        return 1
    fi

    echo "$domain" | jq -r '.id'
}

# Create domain
linode_domain_create() {
    local domain_name="$1"
    local soa_email="$2"

    local data
    data=$(jq -n \
        --arg domain "$domain_name" \
        --arg email "$soa_email" \
        '{
            domain: $domain,
            type: "master",
            soa_email: $email
        }')

    local response
    response=$(linode_api_call POST "/domains" "$data")

    if [ $? -ne 0 ]; then
        return 1
    fi

    log_info "Created domain: $domain_name"
    echo "$response"
}

# List domain records
linode_domain_records_list() {
    local domain_id="$1"

    local response
    response=$(linode_api_call GET "/domains/${domain_id}/records")

    if [ $? -ne 0 ]; then
        return 1
    fi

    echo "$response" | jq -r '.data[]'
}

# Create domain record
linode_domain_record_create() {
    local domain_id="$1"
    local record_type="$2"
    local name="$3"
    local target="$4"
    local ttl="${5:-3600}"

    local data
    data=$(jq -n \
        --arg type "$record_type" \
        --arg name "$name" \
        --arg target "$target" \
        --argjson ttl "$ttl" \
        '{
            type: $type,
            name: $name,
            target: $target,
            ttl_sec: $ttl
        }')

    local response
    response=$(linode_api_call POST "/domains/${domain_id}/records" "$data")

    if [ $? -ne 0 ]; then
        return 1
    fi

    log_info "Created $record_type record: $name -> $target"
    echo "$response"
}

# Update domain record
linode_domain_record_update() {
    local domain_id="$1"
    local record_id="$2"
    local target="$3"

    local data
    data=$(jq -n --arg target "$target" '{target: $target}')

    local response
    response=$(linode_api_call PUT "/domains/${domain_id}/records/${record_id}" "$data")

    if [ $? -ne 0 ]; then
        return 1
    fi

    log_info "Updated record ID $record_id"
    echo "$response"
}

# Delete domain record
linode_domain_record_delete() {
    local domain_id="$1"
    local record_id="$2"

    linode_api_call DELETE "/domains/${domain_id}/records/${record_id}"

    if [ $? -ne 0 ]; then
        return 1
    fi

    log_info "Deleted record ID $record_id"
}

# Create NS delegation
linode_create_ns_delegation() {
    local domain_name="$1"
    local subdomain="$2"
    shift 2
    local nameservers=("$@")

    # Get domain ID
    local domain_id
    domain_id=$(linode_domain_get_id "$domain_name")

    if [ -z "$domain_id" ]; then
        return 1
    fi

    # Create NS records for each nameserver
    local success=true
    for ns in "${nameservers[@]}"; do
        if ! linode_domain_record_create "$domain_id" "NS" "$subdomain" "$ns"; then
            success=false
            break
        fi
    done

    if $success; then
        log_info "NS delegation created: ${subdomain}.${domain_name}"
        return 0
    else
        log_error "Failed to create NS delegation"
        return 1
    fi
}
```

**Tasks:**
- [ ] Create `lib/api/linode.sh` with complete wrapper
- [ ] Implement domain management functions
- [ ] Implement DNS record management
- [ ] Implement NS delegation helper
- [ ] Add error handling for all operations
- [ ] Add input validation

#### 1.2.2 Test Linode API Wrapper

**File:** `tests/api/test-linode.sh`

```bash
#!/bin/bash
################################################################################
# Linode API Wrapper Tests
################################################################################

source "lib/api/linode.sh"
source "lib/test-helpers.sh"

test_linode_api_init() {
    local token="test-token-123"

    linode_init "$token"
    assert_equals "$LINODE_TOKEN" "$token" "Token should be set"
}

test_linode_domain_get_id() {
    # Mock API response
    mock_linode_response '{
        "data": [
            {"id": 12345, "domain": "example.com"},
            {"id": 67890, "domain": "test.com"}
        ]
    }'

    local domain_id
    domain_id=$(linode_domain_get_id "example.com")

    assert_equals "$domain_id" "12345" "Should return correct domain ID"
}

test_linode_create_ns_delegation() {
    mock_linode_response '{"id": 999, "type": "NS"}'

    local result
    result=$(linode_create_ns_delegation "example.com" "sub" "ns1.linode.com" "ns2.linode.com")

    assert_success "$?" "NS delegation should succeed"
}

run_tests
```

**Tasks:**
- [ ] Create test suite for Linode API
- [ ] Add mock response helpers
- [ ] Test all domain operations
- [ ] Test error handling
- [ ] Test retry logic
- [ ] Document test coverage

---

### 1.3 Implement Cloudflare API Wrapper

**Goal:** Create Cloudflare API abstraction

#### 1.3.1 Core Cloudflare Functions

**File:** `lib/api/cloudflare.sh`

```bash
#!/bin/bash
################################################################################
# Cloudflare API Wrapper
#
# Abstraction layer for Cloudflare API v4
# API Docs: https://developers.cloudflare.com/api/
################################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CLOUDFLARE_API_VERSION="v4"
CLOUDFLARE_API_BASE="https://api.cloudflare.com/client/${CLOUDFLARE_API_VERSION}"

# Initialize Cloudflare API client
cloudflare_init() {
    local token="$1"

    if ! api_check_credentials "Cloudflare" "token"; then
        return 1
    fi

    export CLOUDFLARE_TOKEN="$token"
    log_info "Cloudflare API initialized (v4)"
}

# Execute Cloudflare API call
cloudflare_api_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    api_log_call "Cloudflare" "$endpoint" "$method"

    local curl_opts=(
        -s
        -X "$method"
        -H "Authorization: Bearer ${CLOUDFLARE_TOKEN}"
        -H "Content-Type: application/json"
    )

    if [ -n "$data" ]; then
        curl_opts+=(-d "$data")
    fi

    local response
    response=$(api_call_with_retry 3 5 curl "${curl_opts[@]}" "${CLOUDFLARE_API_BASE}${endpoint}")
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        return 1
    fi

    # Cloudflare has a different response structure
    if ! echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
        local error_msg=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "Cloudflare error: $error_msg"
        return 1
    fi

    echo "$response"
}

# Get zone ID by domain name
cloudflare_zone_get_id() {
    local domain_name="$1"

    local response
    response=$(cloudflare_api_call GET "/zones?name=${domain_name}")

    if [ $? -ne 0 ]; then
        return 1
    fi

    local zone_id
    zone_id=$(echo "$response" | jq -r '.result[0].id // empty')

    if [ -z "$zone_id" ]; then
        log_error "Zone not found: $domain_name"
        return 1
    fi

    echo "$zone_id"
}

# Create DNS record
cloudflare_dns_record_create() {
    local zone_id="$1"
    local record_type="$2"
    local name="$3"
    local content="$4"
    local ttl="${5:-3600}"

    local data
    data=$(jq -n \
        --arg type "$record_type" \
        --arg name "$name" \
        --arg content "$content" \
        --argjson ttl "$ttl" \
        '{
            type: $type,
            name: $name,
            content: $content,
            ttl: $ttl
        }')

    local response
    response=$(cloudflare_api_call POST "/zones/${zone_id}/dns_records" "$data")

    if [ $? -ne 0 ]; then
        return 1
    fi

    log_info "Created $record_type record: $name -> $content"
    echo "$response"
}

# Create NS delegation
cloudflare_create_ns_delegation() {
    local domain_name="$1"
    local subdomain="$2"
    shift 2
    local nameservers=("$@")

    # Get zone ID
    local zone_id
    zone_id=$(cloudflare_zone_get_id "$domain_name")

    if [ -z "$zone_id" ]; then
        return 1
    fi

    # Create NS records
    local success=true
    for ns in "${nameservers[@]}"; do
        if ! cloudflare_dns_record_create "$zone_id" "NS" "${subdomain}.${domain_name}" "$ns"; then
            success=false
            break
        fi
    done

    if $success; then
        log_info "NS delegation created: ${subdomain}.${domain_name}"
        return 0
    else
        log_error "Failed to create NS delegation"
        return 1
    fi
}
```

**Tasks:**
- [ ] Create `lib/api/cloudflare.sh` with complete wrapper
- [ ] Implement zone management functions
- [ ] Implement DNS record management
- [ ] Implement NS delegation helper
- [ ] Add Cloudflare-specific error handling
- [ ] Add tests

---

### 1.4 Implement GitLab API Wrapper

**Goal:** Create GitLab API abstraction

#### 1.4.1 Core GitLab Functions

**File:** `lib/api/gitlab.sh`

```bash
#!/bin/bash
################################################################################
# GitLab API Wrapper
#
# Abstraction layer for GitLab API v4
# API Docs: https://docs.gitlab.com/ee/api/
################################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

GITLAB_API_VERSION="v4"

# Initialize GitLab API client
gitlab_init() {
    local gitlab_url="$1"
    local token="$2"

    if ! api_check_credentials "GitLab" "token"; then
        return 1
    fi

    export GITLAB_URL="$gitlab_url"
    export GITLAB_TOKEN="$token"
    export GITLAB_API_BASE="https://${gitlab_url}/api/${GITLAB_API_VERSION}"

    log_info "GitLab API initialized ($gitlab_url)"
}

# Execute GitLab API call
gitlab_api_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    api_log_call "GitLab" "$endpoint" "$method"

    local curl_opts=(
        -s
        -X "$method"
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}"
        -H "Content-Type: application/json"
    )

    if [ -n "$data" ]; then
        curl_opts+=(-d "$data")
    fi

    local response
    response=$(api_call_with_retry 3 5 curl "${curl_opts[@]}" "${GITLAB_API_BASE}${endpoint}")
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        return 1
    fi

    if ! api_validate_response "$response" "" "GitLab"; then
        return 1
    fi

    echo "$response"
}

# Get user by username
gitlab_user_get() {
    local username="$1"

    local response
    response=$(gitlab_api_call GET "/users?username=${username}")

    if [ $? -ne 0 ]; then
        return 1
    fi

    echo "$response" | jq -r '.[0]'
}

# Create user
gitlab_user_create() {
    local username="$1"
    local email="$2"
    local name="$3"
    local password="$4"

    local data
    data=$(jq -n \
        --arg username "$username" \
        --arg email "$email" \
        --arg name "$name" \
        --arg password "$password" \
        '{
            username: $username,
            email: $email,
            name: $name,
            password: $password,
            skip_confirmation: true
        }')

    local response
    response=$(gitlab_api_call POST "/users" "$data")

    if [ $? -ne 0 ]; then
        return 1
    fi

    log_info "Created GitLab user: $username"
    echo "$response"
}

# Get group by path
gitlab_group_get() {
    local group_path="$1"

    local response
    response=$(gitlab_api_call GET "/groups/${group_path}")

    if [ $? -ne 0 ]; then
        return 1
    fi

    echo "$response"
}

# Add user to group
gitlab_group_add_member() {
    local group_id="$1"
    local user_id="$2"
    local access_level="${3:-30}"  # 30 = Developer

    local data
    data=$(jq -n \
        --argjson user_id "$user_id" \
        --argjson access_level "$access_level" \
        '{
            user_id: $user_id,
            access_level: $access_level
        }')

    local response
    response=$(gitlab_api_call POST "/groups/${group_id}/members" "$data")

    if [ $? -ne 0 ]; then
        return 1
    fi

    log_info "Added user $user_id to group $group_id"
    echo "$response"
}
```

**Tasks:**
- [ ] Create `lib/api/gitlab.sh` with complete wrapper
- [ ] Implement user management functions
- [ ] Implement group management functions
- [ ] Add error handling
- [ ] Add tests

---

## Phase 2: Migration (Week 3-4)

### 2.1 Audit Existing API Usage

**Goal:** Identify all direct curl + grep usage

#### 2.1.1 Scan Codebase for API Calls

```bash
#!/bin/bash
# Audit script: scripts/audit-api-calls.sh

echo "=== Linode API Calls ==="
grep -rn "api.linode.com" scripts/ lib/ --include="*.sh"

echo ""
echo "=== Cloudflare API Calls ==="
grep -rn "api.cloudflare.com" scripts/ lib/ --include="*.sh"

echo ""
echo "=== GitLab API Calls ==="
grep -rn "/api/v4/" scripts/ lib/ --include="*.sh"

echo ""
echo "=== curl + grep patterns ==="
grep -rn "curl.*grep" scripts/ lib/ --include="*.sh"
grep -rn "curl.*jq" scripts/ lib/ --include="*.sh"
```

**Output to file for tracking:**
```bash
./scripts/audit-api-calls.sh > docs/reports/api-audit-$(date +%Y%m%d).txt
```

**Tasks:**
- [ ] Run audit script
- [ ] Document all API call locations
- [ ] Categorize by API (Linode/Cloudflare/GitLab)
- [ ] Prioritize migration order
- [ ] Create migration checklist

---

### 2.2 Migrate Core Functions

**Goal:** Replace direct API calls with abstraction layer

#### 2.2.1 Migrate DNS Management in `lib/linode.sh`

**Before:**
```bash
linode_create_ns_delegation() {
    local token="$1"
    local base_domain="$2"
    local subdomain="$3"
    shift 3
    local nameservers=("$@")

    # Get domain ID
    local response=$(curl -s -H "Authorization: Bearer $token" \
        "https://api.linode.com/v4/domains")

    local domain_id=$(echo "$response" | jq -r \
        --arg domain "$base_domain" \
        '.data[] | select(.domain == $domain) | .id')

    # Create NS records
    for ns in "${nameservers[@]}"; do
        curl -s -X POST \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "{\"type\":\"NS\",\"name\":\"$subdomain\",\"target\":\"$ns\"}" \
            "https://api.linode.com/v4/domains/$domain_id/records"
    done
}
```

**After:**
```bash
source "$(dirname "${BASH_SOURCE[0]}")/api/linode.sh"

linode_create_ns_delegation() {
    local token="$1"
    local base_domain="$2"
    local subdomain="$3"
    shift 3
    local nameservers=("$@")

    # Initialize API client
    linode_init "$token"

    # Use abstraction layer
    linode_create_ns_delegation "$base_domain" "$subdomain" "${nameservers[@]}"
}
```

**Tasks:**
- [ ] Update `lib/linode.sh` to use API wrapper
- [ ] Update `lib/cloudflare.sh` to use API wrapper
- [ ] Update `lib/git.sh` to use GitLab API wrapper
- [ ] Test all updated functions
- [ ] Update documentation

#### 2.2.2 Migrate coder-setup.sh

**File:** `scripts/commands/coder-setup.sh`

**Before:**
```bash
# Get Linode token
local linode_token=$(get_infra_secret "linode.api_token" "")

# Create NS delegation (direct curl)
local domain_id=$(curl -s -H "Authorization: Bearer $linode_token" \
    "https://api.linode.com/v4/domains" | \
    jq -r --arg domain "$base_domain" \
    '.data[] | select(.domain == $domain) | .id')
```

**After:**
```bash
source "$PROJECT_ROOT/lib/api/linode.sh"

# Get Linode token
local linode_token=$(get_infra_secret "linode.api_token" "")

# Initialize API
linode_init "$linode_token"

# Use abstraction layer
local domain_id=$(linode_domain_get_id "$base_domain")
```

**Tasks:**
- [ ] Update coder-setup.sh to use API wrappers
- [ ] Update live-deploy.sh to use API wrappers
- [ ] Update dns-update.sh to use API wrappers
- [ ] Test all command scripts
- [ ] Update help text if needed

---

### 2.3 Add Integration Tests

**Goal:** Ensure API wrappers work correctly

#### 2.3.1 Create Integration Test Suite

**File:** `tests/integration/test-api-linode-integration.sh`

```bash
#!/bin/bash
################################################################################
# Linode API Integration Tests
#
# CAUTION: These tests use real API calls and may incur charges.
# Only run with TEST_LINODE_TOKEN set to a test account.
################################################################################

source "lib/api/linode.sh"
source "lib/test-helpers.sh"

# Skip if no test token
if [ -z "$TEST_LINODE_TOKEN" ]; then
    echo "Skipping Linode integration tests (no TEST_LINODE_TOKEN)"
    exit 0
fi

test_linode_domains_list() {
    linode_init "$TEST_LINODE_TOKEN"

    local domains
    domains=$(linode_domains_list)

    assert_success "$?" "Should list domains"
    assert_not_empty "$domains" "Should have at least one domain"
}

test_linode_create_and_delete_record() {
    linode_init "$TEST_LINODE_TOKEN"

    local domain_id="$TEST_DOMAIN_ID"
    local test_name="api-test-$(date +%s)"

    # Create record
    local record
    record=$(linode_domain_record_create "$domain_id" "A" "$test_name" "192.0.2.1")
    assert_success "$?" "Should create record"

    local record_id
    record_id=$(echo "$record" | jq -r '.id')
    assert_not_empty "$record_id" "Should return record ID"

    # Delete record
    linode_domain_record_delete "$domain_id" "$record_id"
    assert_success "$?" "Should delete record"
}

run_integration_tests
```

**Tasks:**
- [ ] Create integration test suite for Linode
- [ ] Create integration test suite for Cloudflare
- [ ] Create integration test suite for GitLab
- [ ] Add to CI pipeline (with opt-in flag)
- [ ] Document how to run integration tests

---

## Phase 3: Enhancement (Week 5-6)

### 3.1 Add Official CLI Support (Optional)

**Goal:** Integrate official CLIs where beneficial

#### 3.1.1 Evaluate Official CLIs

**Linode CLI:**
- Installation: `pip install linode-cli`
- Benefits: Official support, auto-pagination, better error messages
- Drawbacks: Python dependency, slower startup

**Cloudflare CLI:**
- Installation: `npm install -g cloudflare`
- Benefits: Official support, better auth handling
- Drawbacks: Node.js dependency

**Decision Matrix:**

| CLI | Install Complexity | Startup Time | Maintenance | Use? |
|-----|-------------------|--------------|-------------|------|
| linode-cli | Medium (pip) | Slow (~500ms) | Low | Optional |
| cloudflare | Medium (npm) | Slow (~300ms) | Low | Optional |
| gitlab | N/A | N/A | N/A | No (curl is fine) |

**Recommendation:** Keep curl-based implementation as default, add CLI support as opt-in.

**Tasks:**
- [ ] Research official CLI capabilities
- [ ] Create performance benchmarks
- [ ] Decide which CLIs to support
- [ ] Document decision rationale

#### 3.1.2 Add CLI Detection and Fallback

**File:** `lib/api/linode.sh`

```bash
# Detect if Linode CLI is available
linode_cli_available() {
    command -v linode-cli &>/dev/null
}

# Use CLI if available, otherwise fall back to curl
linode_api_call() {
    if [ "${USE_LINODE_CLI:-0}" = "1" ] && linode_cli_available; then
        linode_api_call_cli "$@"
    else
        linode_api_call_curl "$@"
    fi
}

# CLI implementation
linode_api_call_cli() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    # Convert to linode-cli command
    # e.g., GET /domains -> linode-cli domains list
    # Implementation depends on endpoint mapping
}

# Curl implementation (existing)
linode_api_call_curl() {
    # ... existing curl code ...
}
```

**Tasks:**
- [ ] Add CLI detection
- [ ] Implement CLI fallback logic
- [ ] Add USE_*_CLI environment variables
- [ ] Test both paths
- [ ] Document CLI usage

---

### 3.2 Add Monitoring and Metrics

**Goal:** Track API health and usage

#### 3.2.1 Add API Call Logging

**File:** `lib/api/common.sh`

```bash
# Log API call metrics
api_log_metrics() {
    local api_name="$1"
    local endpoint="$2"
    local method="$3"
    local duration="$4"
    local status="$5"

    local log_file="${API_METRICS_LOG:-/var/log/nwp/api-metrics.log}"

    if [ -w "$(dirname "$log_file")" ]; then
        local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        echo "$timestamp|$api_name|$method|$endpoint|$duration|$status" >> "$log_file"
    fi
}

# Wrapper that measures call duration
api_call_with_metrics() {
    local api_name="$1"
    local endpoint="$2"
    local method="$3"
    shift 3
    local cmd=("$@")

    local start=$(date +%s%N)
    local response
    response=$("${cmd[@]}")
    local exit_code=$?
    local end=$(date +%s%N)

    local duration=$(( (end - start) / 1000000 ))  # Convert to ms
    local status="success"
    [ $exit_code -ne 0 ] && status="failure"

    api_log_metrics "$api_name" "$endpoint" "$method" "$duration" "$status"

    echo "$response"
    return $exit_code
}
```

**Tasks:**
- [ ] Add API metrics logging
- [ ] Create log rotation for metrics
- [ ] Add metrics dashboard script
- [ ] Monitor for API rate limits
- [ ] Alert on repeated failures

#### 3.2.2 Create Metrics Dashboard

**File:** `scripts/commands/api-status.sh`

```bash
#!/bin/bash
################################################################################
# API Status Dashboard
#
# Shows API health metrics from logs
################################################################################

show_api_metrics() {
    local log_file="/var/log/nwp/api-metrics.log"

    if [ ! -f "$log_file" ]; then
        echo "No metrics available"
        return 1
    fi

    echo "=== API Call Statistics (Last 24 Hours) ==="

    # Total calls per API
    echo ""
    echo "Calls by API:"
    awk -F'|' '{print $2}' "$log_file" | sort | uniq -c | sort -rn

    # Success rate
    echo ""
    echo "Success Rate:"
    awk -F'|' '
        {total[$2]++; if($6=="success") success[$2]++}
        END {
            for(api in total) {
                rate = (success[api]/total[api])*100
                printf "%s: %.1f%% (%d/%d)\n", api, rate, success[api], total[api]
            }
        }
    ' "$log_file"

    # Average latency
    echo ""
    echo "Average Latency (ms):"
    awk -F'|' '
        {sum[$2]+=$5; count[$2]++}
        END {
            for(api in sum) {
                printf "%s: %.0f ms\n", api, sum[api]/count[api]
            }
        }
    ' "$log_file"

    # Recent failures
    echo ""
    echo "Recent Failures:"
    grep "failure" "$log_file" | tail -10
}

show_api_metrics
```

**Tasks:**
- [ ] Create api-status.sh command
- [ ] Add to `pl` CLI
- [ ] Create alerting for high failure rates
- [ ] Document metrics format

---

## Phase 4: Hardening (Week 7-8)

### 4.1 Add Comprehensive Error Handling

**Goal:** Never fail silently

#### 4.1.1 Add Error Context

**File:** `lib/api/common.sh`

```bash
# API error with context
api_error() {
    local api_name="$1"
    local operation="$2"
    local context="$3"
    local http_code="${4:-unknown}"

    log_error "[$api_name] $operation failed"
    log_error "  Context: $context"
    log_error "  HTTP Code: $http_code"

    # Log to dedicated error log
    local error_log="/var/log/nwp/api-errors.log"
    if [ -w "$(dirname "$error_log")" ]; then
        local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        echo "$timestamp|$api_name|$operation|$context|$http_code" >> "$error_log"
    fi
}

# Enhanced API call with full error context
api_call_with_error_context() {
    local api_name="$1"
    local operation="$2"
    shift 2
    local cmd=("$@")

    local response
    local http_code

    response=$(curl -w "\n%{http_code}" "${cmd[@]}")
    local exit_code=$?

    http_code=$(echo "$response" | tail -1)
    response=$(echo "$response" | sed '$d')

    if [ $exit_code -ne 0 ] || [ "$http_code" -ge 400 ]; then
        api_error "$api_name" "$operation" "$(echo "$response" | head -c 200)" "$http_code"
        return 1
    fi

    echo "$response"
}
```

**Tasks:**
- [ ] Add error context logging
- [ ] Add HTTP status code tracking
- [ ] Add error aggregation
- [ ] Create error dashboard
- [ ] Add alerting for critical errors

---

### 4.2 Add API Version Tracking

**Goal:** Detect breaking API changes early

#### 4.2.1 Add Version Headers

**File:** `lib/api/common.sh`

```bash
# Check API version compatibility
api_check_version() {
    local api_name="$1"
    local expected_version="$2"
    local actual_version="$3"

    if [ "$expected_version" != "$actual_version" ]; then
        log_warn "[$api_name] API version mismatch"
        log_warn "  Expected: $expected_version"
        log_warn "  Actual: $actual_version"
        log_warn "  This may cause issues - check for breaking changes"
    fi
}

# Extract API version from response headers
api_get_version() {
    local response_headers="$1"

    # Different APIs use different headers
    # Linode: X-Linode-API-Version
    # Cloudflare: CF-Ray contains version info
    # GitLab: No version header (uses /api/v4 in URL)

    grep -i "api-version" <<< "$response_headers" | cut -d: -f2 | tr -d ' '
}
```

**Tasks:**
- [ ] Add version checking
- [ ] Store known good versions
- [ ] Alert on version changes
- [ ] Document version compatibility

---

### 4.3 Add Rate Limit Handling

**Goal:** Respect API rate limits

#### 4.3.1 Implement Rate Limit Detection

**File:** `lib/api/common.sh`

```bash
# Check if rate limited
api_check_rate_limit() {
    local response_headers="$1"
    local http_code="$2"

    # Rate limit status codes
    if [ "$http_code" = "429" ]; then
        local retry_after=$(grep -i "retry-after" <<< "$response_headers" | cut -d: -f2 | tr -d ' ')

        if [ -n "$retry_after" ]; then
            log_warn "Rate limited - retry after ${retry_after}s"
            return "$retry_after"
        else
            return 60  # Default 60s
        fi
    fi

    return 0
}

# API call with rate limit handling
api_call_with_rate_limit() {
    local max_retries="${1:-3}"
    shift
    local cmd=("$@")

    local attempt=1
    while [ $attempt -le $max_retries ]; do
        local response
        response=$("${cmd[@]}")
        local exit_code=$?

        if [ $exit_code -eq 0 ]; then
            echo "$response"
            return 0
        fi

        # Check if rate limited
        local retry_after
        retry_after=$(api_check_rate_limit "$response" "$(get_http_code)")

        if [ $? -ne 0 ]; then
            log_info "Waiting ${retry_after}s for rate limit..."
            sleep "$retry_after"
            ((attempt++))
            continue
        fi

        return 1
    done

    return 1
}
```

**Tasks:**
- [ ] Add rate limit detection
- [ ] Add exponential backoff
- [ ] Add rate limit metrics
- [ ] Document rate limits per API

---

## Phase 5: Documentation & Training (Week 9)

### 5.1 Update Documentation

**Goal:** Complete migration documentation

#### 5.1.1 Update Developer Docs

**Files to update:**
- [ ] `docs/reference/api-wrappers.md` - Complete API reference
- [ ] `docs/guides/api-migration.md` - Migration guide for developers
- [ ] `docs/architecture/api-layer.md` - Architecture overview
- [ ] `CONTRIBUTING.md` - API usage guidelines

**Content:**
```markdown
# API Usage Guidelines

## Using API Wrappers

Always use the abstraction layer in `lib/api/` instead of direct curl:

❌ **Don't:**
```bash
curl -H "Authorization: Bearer $token" \
    "https://api.linode.com/v4/domains"
```

✅ **Do:**
```bash
source "lib/api/linode.sh"
linode_init "$token"
linode_domains_list
```

## Error Handling

Always check return codes:

```bash
if ! linode_domain_create "example.com" "admin@example.com"; then
    log_error "Failed to create domain"
    return 1
fi
```

## Testing

Use mocks for unit tests:

```bash
mock_linode_response '{"id": 123, "domain": "test.com"}'
```

Use integration tests for real API calls:

```bash
TEST_LINODE_TOKEN="xxx" ./tests/integration/test-linode.sh
```
```

**Tasks:**
- [ ] Write API wrapper reference docs
- [ ] Write migration guide
- [ ] Update architecture docs
- [ ] Update contributing guidelines
- [ ] Add code examples

---

### 5.2 Create Training Materials

**Goal:** Help contributors adopt new patterns

#### 5.2.1 Create Examples

**File:** `examples/api-usage-examples.sh`

```bash
#!/bin/bash
################################################################################
# API Usage Examples
################################################################################

# Example 1: Create DNS record
example_create_dns_record() {
    source "lib/api/linode.sh"

    local token=$(get_infra_secret "linode.api_token")
    linode_init "$token"

    local domain_id=$(linode_domain_get_id "example.com")
    linode_domain_record_create "$domain_id" "A" "www" "192.0.2.1"
}

# Example 2: Create GitLab user
example_create_gitlab_user() {
    source "lib/api/gitlab.sh"

    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    gitlab_init "$gitlab_url" "$token"
    gitlab_user_create "john" "john@example.com" "John Doe" "SecurePass123"
}

# Example 3: Error handling
example_with_error_handling() {
    source "lib/api/linode.sh"

    local token=$(get_infra_secret "linode.api_token")

    if ! linode_init "$token"; then
        log_error "Failed to initialize Linode API"
        return 1
    fi

    local domain_id=$(linode_domain_get_id "example.com")
    if [ -z "$domain_id" ]; then
        log_error "Domain not found"
        return 1
    fi

    if ! linode_domain_record_create "$domain_id" "A" "test" "192.0.2.1"; then
        log_error "Failed to create record"
        return 1
    fi

    log_info "Record created successfully"
}
```

**Tasks:**
- [ ] Create example scripts
- [ ] Create video tutorial (optional)
- [ ] Hold training session for contributors
- [ ] Answer questions in documentation

---

## Success Metrics

### Phase 1-2 (Foundation & Migration)
- [ ] 100% of Linode API calls use abstraction layer
- [ ] 100% of Cloudflare API calls use abstraction layer
- [ ] 100% of GitLab API calls use abstraction layer
- [ ] All API calls have error handling
- [ ] All API calls have retry logic
- [ ] 90%+ test coverage on API wrappers

### Phase 3-4 (Enhancement & Hardening)
- [ ] API metrics dashboard operational
- [ ] <1% API call failure rate (excluding external issues)
- [ ] Mean API latency <500ms
- [ ] Zero silent failures
- [ ] API version tracking active
- [ ] Rate limit handling tested

### Phase 5 (Documentation)
- [ ] Complete API reference documentation
- [ ] Migration guide written
- [ ] Contributors trained
- [ ] Code examples published

---

## Rollback Plan

If issues arise during migration:

1. **Immediate Rollback:**
   ```bash
   git revert <migration-commit>
   ```

2. **Partial Rollback:**
   - Keep abstraction layer but revert specific functions
   - Add feature flag to switch between old/new implementations

3. **Feature Flag Pattern:**
   ```bash
   if [ "${USE_API_WRAPPER:-1}" = "1" ]; then
       linode_domains_list  # New way
   else
       curl -s ...          # Old way
   fi
   ```

---

## Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| API wrapper bugs | Medium | High | Extensive testing, gradual rollout |
| Performance regression | Low | Medium | Benchmark before/after |
| Breaking changes during migration | Low | High | Feature flags, quick rollback |
| Increased complexity | Medium | Low | Good docs, training |
| CI/CD disruption | Low | High | Test in staging first |

---

## Timeline Summary

| Phase | Duration | Deliverables |
|-------|----------|--------------|
| 1. Foundation | 2 weeks | API abstraction libraries |
| 2. Migration | 2 weeks | All calls migrated |
| 3. Enhancement | 2 weeks | CLI support, metrics |
| 4. Hardening | 2 weeks | Error handling, rate limits |
| 5. Documentation | 1 week | Docs, training |
| **Total** | **9 weeks** | Production-ready API layer |

---

## Next Steps

1. **Week 1:** Start Phase 1.1 - Create `lib/api/common.sh`
2. Review this plan with team
3. Get approval for approach
4. Begin implementation

---

## References

- [Linode API v4 Documentation](https://www.linode.com/docs/api/)
- [Cloudflare API v4 Documentation](https://developers.cloudflare.com/api/)
- [GitLab API v4 Documentation](https://docs.gitlab.com/ee/api/)
- NWP API Brittleness Analysis (Section 8.3.4)
