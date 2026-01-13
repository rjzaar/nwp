#!/bin/bash

################################################################################
# Backblaze B2 Helper Functions
#
# Provides functions for managing B2 buckets and application keys
# for podcast media storage.
#
# Requirements:
# - b2 CLI tool installed (pip install b2)
# - B2 account authorized (b2 account authorize)
# - OR .secrets.yml with b2.account_id and b2.app_key
################################################################################

# Source yaml-write.sh for consolidated YAML functions
if ! declare -f yaml_get_secret &>/dev/null; then
    B2_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$B2_LIB_DIR/yaml-write.sh" ]; then
        source "$B2_LIB_DIR/yaml-write.sh"
    fi
fi

# Check if b2 CLI is installed
# Usage: b2_check_installed
b2_check_installed() {
    if ! command -v b2 &>/dev/null; then
        echo "ERROR: b2 CLI not installed. Install with: pip install b2" >&2
        return 1
    fi
    return 0
}

# Check if b2 is authenticated
# Usage: b2_check_auth
b2_check_auth() {
    if ! b2 account get &>/dev/null; then
        echo "ERROR: b2 not authenticated. Run: b2 account authorize" >&2
        return 1
    fi
    return 0
}

# Get B2 credentials from secrets file
# Usage: get_b2_account_id [script_dir]
get_b2_account_id() {
    local account_id=""
    local script_dir="${1:-.}"

    if [ -f "$script_dir/.secrets.yml" ]; then
        account_id=$(yaml_get_secret "b2.account_id" "$script_dir/.secrets.yml" 2>/dev/null || true)
    fi

    if [ -z "$account_id" ] && [ -n "${B2_ACCOUNT_ID:-}" ]; then
        account_id="$B2_ACCOUNT_ID"
    fi

    echo "$account_id"
}

# Get B2 application key from secrets file
# Usage: get_b2_app_key [script_dir]
get_b2_app_key() {
    local app_key=""
    local script_dir="${1:-.}"

    if [ -f "$script_dir/.secrets.yml" ]; then
        app_key=$(yaml_get_secret "b2.app_key" "$script_dir/.secrets.yml" 2>/dev/null || true)
    fi

    if [ -z "$app_key" ] && [ -n "${B2_APP_KEY:-}" ]; then
        app_key="$B2_APP_KEY"
    fi

    echo "$app_key"
}

# Authorize B2 from secrets file if not already authorized
# Usage: b2_authorize [script_dir]
b2_authorize() {
    local script_dir="${1:-.}"

    # Check if already authorized
    if b2 account get &>/dev/null; then
        echo "B2 already authorized" >&2
        return 0
    fi

    local account_id=$(get_b2_account_id "$script_dir")
    local app_key=$(get_b2_app_key "$script_dir")

    if [ -z "$account_id" ] || [ -z "$app_key" ]; then
        echo "ERROR: B2 credentials not found in .secrets.yml or environment" >&2
        echo "Run 'b2 account authorize' manually or add credentials to .secrets.yml" >&2
        return 1
    fi

    b2 account authorize "$account_id" "$app_key"
}

# Create a B2 bucket
# Usage: b2_create_bucket "bucket_name" [bucket_type: allPublic|allPrivate]
# Returns: bucket ID on success
b2_create_bucket() {
    local bucket_name=$1
    local bucket_type=${2:-allPublic}

    b2_check_installed || return 1
    b2_check_auth || return 1

    # Check if bucket already exists
    local existing=$(b2 bucket list 2>/dev/null | grep -w "$bucket_name")
    if [ -n "$existing" ]; then
        echo "Bucket $bucket_name already exists" >&2
        local bucket_id=$(echo "$existing" | awk '{print $1}')
        echo "$bucket_id"
        return 0
    fi

    # Create bucket
    local output=$(b2 bucket create "$bucket_name" "$bucket_type" 2>&1)
    if [ $? -eq 0 ]; then
        local bucket_id=$(echo "$output" | grep -o 'bucket_[a-f0-9]*' | head -1)
        if [ -z "$bucket_id" ]; then
            # Try to get bucket ID from list
            bucket_id=$(b2 bucket list | grep -w "$bucket_name" | awk '{print $1}')
        fi
        echo "Bucket created: $bucket_name" >&2
        echo "$bucket_id"
        return 0
    else
        echo "ERROR: Failed to create bucket $bucket_name" >&2
        echo "$output" >&2
        return 1
    fi
}

# Delete a B2 bucket (must be empty)
# Usage: b2_delete_bucket "bucket_name"
b2_delete_bucket() {
    local bucket_name=$1

    b2_check_installed || return 1
    b2_check_auth || return 1

    b2 bucket delete "$bucket_name" 2>&1
}

# List all B2 buckets
# Usage: b2_list_buckets
b2_list_buckets() {
    b2_check_installed || return 1
    b2_check_auth || return 1

    b2 bucket list 2>/dev/null
}

# Get bucket ID by name
# Usage: b2_get_bucket_id "bucket_name"
b2_get_bucket_id() {
    local bucket_name=$1

    b2_check_installed || return 1
    b2_check_auth || return 1

    b2 bucket list 2>/dev/null | grep -w "$bucket_name" | awk '{print $1}'
}

# Create an application key for a specific bucket
# Usage: b2_create_app_key "bucket_name" "key_name" [capabilities]
# Returns: key_id and application_key (space-separated)
b2_create_app_key() {
    local bucket_name=$1
    local key_name=$2
    local capabilities=${3:-"listBuckets,listFiles,readFiles,writeFiles,deleteFiles"}

    b2_check_installed || return 1
    b2_check_auth || return 1

    # Get bucket ID
    local bucket_id=$(b2_get_bucket_id "$bucket_name")
    if [ -z "$bucket_id" ]; then
        echo "ERROR: Bucket $bucket_name not found" >&2
        return 1
    fi

    # Create application key
    local output=$(b2 key create --bucket "$bucket_name" "$key_name" "$capabilities" 2>&1)
    if [ $? -eq 0 ]; then
        # Output format: keyId applicationKey
        local key_id=$(echo "$output" | awk '{print $1}')
        local app_key=$(echo "$output" | awk '{print $2}')
        echo "Application key created: $key_name" >&2
        echo "$key_id $app_key"
        return 0
    else
        echo "ERROR: Failed to create application key" >&2
        echo "$output" >&2
        return 1
    fi
}

# Delete an application key
# Usage: b2_delete_app_key "key_id"
b2_delete_app_key() {
    local key_id=$1

    b2_check_installed || return 1
    b2_check_auth || return 1

    b2 key delete "$key_id" 2>&1
}

# List application keys
# Usage: b2_list_keys
b2_list_keys() {
    b2_check_installed || return 1
    b2_check_auth || return 1

    b2 key list 2>/dev/null
}

# Upload a file to B2
# Usage: b2_upload_file "bucket_name" "local_file" "remote_name"
b2_upload_file() {
    local bucket_name=$1
    local local_file=$2
    local remote_name=$3

    b2_check_installed || return 1
    b2_check_auth || return 1

    b2 file upload "$bucket_name" "$local_file" "$remote_name" 2>&1
}

# List files in a bucket
# Usage: b2_list_files "bucket_name" [prefix]
b2_list_files() {
    local bucket_name=$1
    local prefix=${2:-}

    b2_check_installed || return 1
    b2_check_auth || return 1

    if [ -n "$prefix" ]; then
        b2 ls "$bucket_name" "$prefix" 2>/dev/null
    else
        b2 ls "$bucket_name" 2>/dev/null
    fi
}

# Delete a file from B2
# Usage: b2_delete_file "bucket_name" "file_name"
b2_delete_file() {
    local bucket_name=$1
    local file_name=$2

    b2_check_installed || return 1
    b2_check_auth || return 1

    b2 file delete "$bucket_name" "$file_name" 2>&1
}

# Get B2 bucket URL for public access
# Usage: b2_get_bucket_url "bucket_name"
# Returns: URL like https://f000.backblazeb2.com/file/bucket_name
b2_get_bucket_url() {
    local bucket_name=$1

    b2_check_installed || return 1
    b2_check_auth || return 1

    # Get account info to determine the download URL
    local account_info=$(b2 account get 2>/dev/null)
    local download_url=$(echo "$account_info" | grep -o 'downloadUrl.*' | cut -d' ' -f2 | tr -d ',')

    if [ -n "$download_url" ]; then
        echo "${download_url}/file/${bucket_name}"
    else
        # Fallback to standard format
        echo "https://f000.backblazeb2.com/file/${bucket_name}"
    fi
}

# Enable CORS on a bucket for web access
# Usage: b2_enable_cors "bucket_name" [allowed_origins]
b2_enable_cors() {
    local bucket_name=$1
    local allowed_origins=${2:-"*"}

    b2_check_installed || return 1
    b2_check_auth || return 1

    # Create CORS rules JSON
    local cors_rules='[{
        "corsRuleName": "allowAll",
        "allowedOrigins": ["'"$allowed_origins"'"],
        "allowedHeaders": ["*"],
        "allowedOperations": ["b2_download_file_by_name", "b2_download_file_by_id"],
        "exposeHeaders": ["x-bz-content-sha1"],
        "maxAgeSeconds": 3600
    }]'

    # Update bucket with CORS rules
    b2 bucket update --cors-rules "$cors_rules" "$bucket_name" allPublic 2>&1
}

# Get bucket info including friendly URL
# Usage: b2_get_bucket_info "bucket_name"
b2_get_bucket_info() {
    local bucket_name=$1

    b2_check_installed || return 1
    b2_check_auth || return 1

    b2 bucket get "$bucket_name" 2>/dev/null
}

# Export functions
export -f b2_check_installed
export -f b2_check_auth
export -f get_b2_account_id
export -f get_b2_app_key
export -f b2_authorize
export -f b2_create_bucket
export -f b2_delete_bucket
export -f b2_list_buckets
export -f b2_get_bucket_id
export -f b2_create_app_key
export -f b2_delete_app_key
export -f b2_list_keys
export -f b2_upload_file
export -f b2_list_files
export -f b2_delete_file
export -f b2_get_bucket_url
export -f b2_enable_cors
export -f b2_get_bucket_info
