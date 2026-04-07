#!/bin/bash
set -euo pipefail

################################################################################
# NWP Cloud Storage Management (Backblaze B2)
#
# Manages Backblaze B2 cloud storage for backups and podcast media
#
# Usage: pl storage <command> [options]
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/b2.sh"

show_help() {
    cat << EOF
${BOLD}NWP Cloud Storage Management (Backblaze B2)${NC}

${BOLD}USAGE:${NC}
    pl storage <command> [options]

${BOLD}COMMANDS:${NC}
    auth                         Authenticate with B2
    list                         List all buckets
    info <bucket>                Show bucket details
    files <bucket> [prefix]      List files in bucket
    upload <file> <bucket>       Upload file to bucket
    delete <bucket> <file>       Delete file from bucket
    keys                         List application keys
    key-delete <key_id>          Delete an application key

${BOLD}EXAMPLES:${NC}
    pl storage auth                          # Authenticate with B2
    pl storage list                          # Show all buckets
    pl storage files podcast-media           # List podcast files
    pl storage upload backup.sql.gz mybackups  # Upload backup

${BOLD}CONFIGURATION:${NC}
    Add to .secrets.yml:
      b2:
        account_id: "your-account-id"
        app_key: "your-application-key"

EOF
}

cmd_auth() {
    print_info "Authenticating with Backblaze B2..."
    if b2_authorize "$PROJECT_ROOT"; then
        print_status "OK" "B2 authentication successful"
    else
        print_error "B2 authentication failed"
        exit 1
    fi
}

cmd_list() {
    print_header "B2 Buckets"
    b2_list_buckets
}

cmd_info() {
    local bucket="$1"
    if [ -z "$bucket" ]; then
        print_error "Bucket name required"
        exit 1
    fi
    print_header "Bucket: $bucket"
    b2_get_bucket_info "$bucket"
    echo ""
    print_info "Public URL: $(b2_get_bucket_url "$bucket")"
}

cmd_files() {
    local bucket="$1"
    local prefix="${2:-}"
    if [ -z "$bucket" ]; then
        print_error "Bucket name required"
        exit 1
    fi
    print_header "Files in $bucket"
    b2_list_files "$bucket" "$prefix"
}

cmd_upload() {
    local file="$1"
    local bucket="$2"
    local remote_name="${3:-$(basename "$file")}"

    if [ -z "$file" ] || [ -z "$bucket" ]; then
        print_error "Usage: pl storage upload <file> <bucket> [remote_name]"
        exit 1
    fi

    if [ ! -f "$file" ]; then
        print_error "File not found: $file"
        exit 1
    fi

    print_info "Uploading $file to $bucket..."
    if b2_upload_file "$bucket" "$file" "$remote_name"; then
        print_status "OK" "Upload complete: $remote_name"
    else
        print_error "Upload failed"
        exit 1
    fi
}

cmd_delete() {
    local bucket="$1"
    local file="$2"

    if [ -z "$bucket" ] || [ -z "$file" ]; then
        print_error "Usage: pl storage delete <bucket> <file>"
        exit 1
    fi

    print_warning "Deleting $file from $bucket..."
    if b2_delete_file "$bucket" "$file"; then
        print_status "OK" "File deleted"
    else
        print_error "Delete failed"
        exit 1
    fi
}

cmd_keys() {
    print_header "B2 Application Keys"
    b2_list_keys
}

cmd_key_delete() {
    local key_id="$1"
    if [ -z "$key_id" ]; then
        print_error "Key ID required"
        exit 1
    fi

    print_warning "Deleting application key: $key_id"
    if b2_delete_app_key "$key_id"; then
        print_status "OK" "Key deleted"
    else
        print_error "Delete failed"
        exit 1
    fi
}

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    auth) cmd_auth ;;
    list) cmd_list ;;
    info) cmd_info "$@" ;;
    files) cmd_files "$@" ;;
    upload) cmd_upload "$@" ;;
    delete) cmd_delete "$@" ;;
    keys) cmd_keys ;;
    key-delete) cmd_key_delete "$@" ;;
    -h|--help|help|"") show_help ;;
    *) print_error "Unknown command: $COMMAND"; show_help; exit 1 ;;
esac
