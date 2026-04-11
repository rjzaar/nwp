#!/bin/bash
set -euo pipefail

################################################################################
# NWP Publish Script
#
# Publishes a signed deployment tarball to GitLab's Generic Packages registry.
# The tarball and its .minisig signature are uploaded as a versioned package
# that mons can pull for deployment.
#
# F21 Phase 7: Part of the fixture publication channel.
#
# Usage: pl publish <sitename> [OPTIONS]
#
# Options:
#   --file PATH        Path to the tarball (default: latest in backups/)
#   --version VER      Package version (default: extracted from filename)
#   --project ID       GitLab project path (default: from .nwp.yml git repo)
#   --dry-run          Show what would be uploaded without uploading
#   -h, --help         Show this help message
#
# Prerequisites:
#   - Tarball must be signed (tarball.minisig must exist alongside it)
#   - GitLab API token in .secrets.yml (gitlab.api_token)
#   - Site must have a GitLab project (configured in .nwp.yml or detected)
#
# Examples:
#   pl publish mayo                                   # Latest tarball
#   pl publish mayo --file backups/mayo-abc123.tar.gz # Specific file
#   pl publish mayo --dry-run                         # Preview only
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/minisign.sh"

# Error reporting — formatted for pasting into a Claude session
report_error() {
    local step="$1"
    local detail="$2"
    echo ""
    echo "================================================================"
    echo "  PUBLISH STEP ${step} FAILED"
    echo "================================================================"
    echo ""
    echo "  Error: ${detail}"
    echo ""
    echo "  Paste this to your Claude session for help:"
    echo "    ---"
    echo "    pl publish ${SITE_NAME:-<site>} failed at step ${step}."
    echo "    Error: ${detail}"
    echo "    Tarball: ${TARBALL_PATH:-unknown}"
    echo "    Project: ${GITLAB_PROJECT:-unknown}"
    echo "    ---"
    echo ""
    echo "================================================================"
}

# Defaults
SITE_NAME=""
TARBALL_PATH=""
PACKAGE_VERSION=""
GITLAB_PROJECT=""
DRY_RUN=false

# GitLab config
GITLAB_HOST="git.nwpcode.org"
GITLAB_API="https://${GITLAB_HOST}/api/v4"

show_help() {
    grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --file)
            TARBALL_PATH="$2"
            shift 2
            ;;
        --version)
            PACKAGE_VERSION="$2"
            shift 2
            ;;
        --project)
            GITLAB_PROJECT="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        -*)
            print_error "Unknown option: $1"
            exit 2
            ;;
        *)
            if [[ -z "$SITE_NAME" ]]; then
                SITE_NAME="$1"
            else
                print_error "Unexpected argument: $1"
                exit 2
            fi
            shift
            ;;
    esac
done

if [[ -z "$SITE_NAME" ]]; then
    print_error "Usage: pl publish <sitename> [OPTIONS]"
    exit 2
fi

################################################################################
# Resolve configuration
################################################################################

SITE_DIR="${PROJECT_ROOT}/sites/${SITE_NAME}"
BACKUPS_DIR="${SITE_DIR}/backups"

# Find tarball if not specified
if [[ -z "$TARBALL_PATH" ]]; then
    if [[ ! -d "$BACKUPS_DIR" ]]; then
        print_error "No backups directory: ${BACKUPS_DIR}"
        exit 2
    fi

    # Find latest tarball
    TARBALL_PATH=$(ls -t "${BACKUPS_DIR}"/${SITE_NAME}-*.tar.gz 2>/dev/null | head -1)

    if [[ -z "$TARBALL_PATH" ]]; then
        print_error "No tarballs found in ${BACKUPS_DIR}/"
        echo "Run: pl build ${SITE_NAME}"
        exit 2
    fi
fi

if [[ ! -f "$TARBALL_PATH" ]]; then
    print_error "Tarball not found: ${TARBALL_PATH}"
    exit 2
fi

# Verify signature exists
if [[ ! -f "${TARBALL_PATH}.minisig" ]]; then
    print_error "Signature not found: ${TARBALL_PATH}.minisig"
    echo "Unsigned tarballs cannot be published. Run: pl build ${SITE_NAME}"
    exit 2
fi

# Verify signature is valid before publishing
print_info "Verifying signature before upload..."
if ! minisign_verify "$TARBALL_PATH"; then
    print_error "Signature verification failed — refusing to publish"
    exit 1
fi
print_success "Signature verified"

# Extract version from filename if not specified
if [[ -z "$PACKAGE_VERSION" ]]; then
    # Pattern: sitename-tag-timestamp.tar.gz
    BASENAME=$(basename "$TARBALL_PATH" .tar.gz)
    # Remove the site name prefix and extract version + timestamp
    PACKAGE_VERSION="${BASENAME#${SITE_NAME}-}"
fi

# Resolve GitLab project
if [[ -z "$GITLAB_PROJECT" ]]; then
    # Default to mayo/<sitename> pattern
    GITLAB_PROJECT="mayo/${SITE_NAME}"
fi

# URL-encode the project path
GITLAB_PROJECT_ENCODED=$(echo "$GITLAB_PROJECT" | sed 's|/|%2F|g')

# Get GitLab API token from secrets
SECRETS_FILE="${PROJECT_ROOT}/.secrets.yml"
if [[ ! -f "$SECRETS_FILE" ]]; then
    print_error "Secrets file not found: ${SECRETS_FILE}"
    exit 2
fi

# Extract token using grep/sed (avoid yq dependency)
GITLAB_TOKEN=$(grep -A1 'api_token:' "$SECRETS_FILE" | tail -1 | sed 's/.*: *//' | tr -d '"' | tr -d "'" 2>/dev/null)
if [[ -z "$GITLAB_TOKEN" ]] || [[ "$GITLAB_TOKEN" == *"api_token"* ]]; then
    # Try direct single-line format
    GITLAB_TOKEN=$(grep 'api_token:' "$SECRETS_FILE" | head -1 | sed 's/.*: *//' | tr -d '"' | tr -d "'" 2>/dev/null)
fi

if [[ -z "$GITLAB_TOKEN" ]]; then
    report_error 0 "Could not extract GitLab API token from ${SECRETS_FILE} — check gitlab.api_token key"
    exit 2
fi

TARBALL_SIZE=$(du -h "$TARBALL_PATH" | cut -f1)
TARBALL_BASENAME=$(basename "$TARBALL_PATH")
SIG_BASENAME="${TARBALL_BASENAME}.minisig"

################################################################################
# Publish
################################################################################

print_header "Publishing ${SITE_NAME} to GitLab Packages"

echo "  Project:   ${GITLAB_PROJECT}"
echo "  Version:   ${PACKAGE_VERSION}"
echo "  Tarball:   ${TARBALL_BASENAME} (${TARBALL_SIZE})"
echo "  Signature: ${SIG_BASENAME}"
echo ""

if [[ "$DRY_RUN" == true ]]; then
    print_warning "DRY RUN — showing commands without executing"
    echo ""
    echo "Would upload:"
    echo "  PUT ${GITLAB_API}/projects/${GITLAB_PROJECT_ENCODED}/packages/generic/${SITE_NAME}-deploy/${PACKAGE_VERSION}/${TARBALL_BASENAME}"
    echo "  PUT ${GITLAB_API}/projects/${GITLAB_PROJECT_ENCODED}/packages/generic/${SITE_NAME}-deploy/${PACKAGE_VERSION}/${SIG_BASENAME}"
    echo ""
    exit 0
fi

# Upload tarball
print_step "Uploading tarball"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --upload-file "$TARBALL_PATH" \
    "${GITLAB_API}/projects/${GITLAB_PROJECT_ENCODED}/packages/generic/${SITE_NAME}-deploy/${PACKAGE_VERSION}/${TARBALL_BASENAME}")

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
    print_success "Tarball uploaded (HTTP ${HTTP_CODE})"
else
    report_error 1 "Tarball upload failed (HTTP ${HTTP_CODE}) to ${GITLAB_API}/projects/${GITLAB_PROJECT_ENCODED}/packages/generic/${SITE_NAME}-deploy/${PACKAGE_VERSION}/${TARBALL_BASENAME}"
    exit 1
fi

# Upload signature
print_step "Uploading signature"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --upload-file "${TARBALL_PATH}.minisig" \
    "${GITLAB_API}/projects/${GITLAB_PROJECT_ENCODED}/packages/generic/${SITE_NAME}-deploy/${PACKAGE_VERSION}/${SIG_BASENAME}")

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
    print_success "Signature uploaded (HTTP ${HTTP_CODE})"
else
    report_error 2 "Signature upload failed (HTTP ${HTTP_CODE}) — tarball was uploaded OK, signature was not"
    exit 1
fi

################################################################################
# Summary
################################################################################

print_header "Published Successfully"

DOWNLOAD_URL="${GITLAB_API}/projects/${GITLAB_PROJECT_ENCODED}/packages/generic/${SITE_NAME}-deploy/${PACKAGE_VERSION}"

echo "  Package:   ${SITE_NAME}-deploy"
echo "  Version:   ${PACKAGE_VERSION}"
echo "  Download:"
echo "    Tarball: ${DOWNLOAD_URL}/${TARBALL_BASENAME}"
echo "    Sig:     ${DOWNLOAD_URL}/${SIG_BASENAME}"
echo ""
echo "On mons, pull with:"
echo "  curl -H 'PRIVATE-TOKEN: \$TOKEN' -o ${TARBALL_BASENAME} '${DOWNLOAD_URL}/${TARBALL_BASENAME}'"
echo "  curl -H 'PRIVATE-TOKEN: \$TOKEN' -o ${SIG_BASENAME} '${DOWNLOAD_URL}/${SIG_BASENAME}'"
echo ""

exit 0
