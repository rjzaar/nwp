#!/bin/bash
set -euo pipefail

################################################################################
# NWP Build Script
#
# Builds a signed deployment tarball from a site's dev environment.
# The tarball contains the production-ready codebase (composer install --no-dev,
# no .git, no .ddev, no dev tooling).
#
# F21 Phase 5/7: Part of the signed-artifact pipeline.
# Tarballs are signed with minisign and published to GitLab Packages
# via `pl publish`. mons pulls and verifies before deploying.
#
# Usage: pl build <sitename> [OPTIONS]
#
# Options:
#   --output DIR       Output directory (default: sites/<name>/backups/)
#   --no-sign          Skip minisign signing (not recommended)
#   --no-composer      Skip composer install --no-dev (use existing vendor/)
#   --tag TAG          Version tag for the tarball (default: git short hash)
#   --verbose          Verbose output
#   -h, --help         Show this help message
#
# Output:
#   <sitename>-<tag>-<timestamp>.tar.gz       The deployment tarball
#   <sitename>-<tag>-<timestamp>.tar.gz.minisig  Signature (unless --no-sign)
#
# Examples:
#   pl build mayo                    # Build from sites/mayo/dev/
#   pl build mayo --tag v1.0         # Tag as v1.0
#   pl build mayo --output /tmp/     # Output to /tmp/
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
    echo "  BUILD STEP ${step} FAILED"
    echo "================================================================"
    echo ""
    echo "  Error: ${detail}"
    echo ""
    echo "  Paste this to your Claude session for help:"
    echo "    ---"
    echo "    pl build ${SITE_NAME:-<site>} failed at step ${step}."
    echo "    Error: ${detail}"
    echo "    Dev dir: ${DEV_DIR:-unknown}"
    echo "    ---"
    echo ""
    echo "================================================================"
}

# Defaults
SITE_NAME=""
OUTPUT_DIR=""
DO_SIGN=true
DO_COMPOSER=true
VERSION_TAG=""
VERBOSE=false

show_help() {
    grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --no-sign)
            DO_SIGN=false
            shift
            ;;
        --no-composer)
            DO_COMPOSER=false
            shift
            ;;
        --tag)
            VERSION_TAG="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
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
    print_error "Usage: pl build <sitename> [OPTIONS]"
    exit 2
fi

################################################################################
# Resolve paths
################################################################################

SITE_DIR="${PROJECT_ROOT}/sites/${SITE_NAME}"
DEV_DIR="${SITE_DIR}/dev"

if [[ ! -d "$DEV_DIR" ]]; then
    print_error "Dev environment not found: ${DEV_DIR}"
    exit 2
fi

if [[ ! -f "${DEV_DIR}/composer.json" ]]; then
    print_error "No composer.json in ${DEV_DIR} — is this a Drupal site?"
    exit 2
fi

# Default output to site's backups directory
if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="${SITE_DIR}/backups"
fi
mkdir -p "$OUTPUT_DIR"

# Determine version tag
if [[ -z "$VERSION_TAG" ]]; then
    # Try git short hash from the site's dev directory
    if [[ -d "${DEV_DIR}/.git" ]]; then
        VERSION_TAG=$(cd "$DEV_DIR" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    else
        # Fall back to NWP repo hash
        VERSION_TAG=$(cd "$PROJECT_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    fi
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TARBALL_NAME="${SITE_NAME}-${VERSION_TAG}-${TIMESTAMP}.tar.gz"
TARBALL_PATH="${OUTPUT_DIR}/${TARBALL_NAME}"

################################################################################
# Build
################################################################################

print_header "Building deployment tarball: ${SITE_NAME}"

echo "  Source:  ${DEV_DIR}"
echo "  Output:  ${TARBALL_PATH}"
echo "  Tag:     ${VERSION_TAG}"
echo "  Sign:    ${DO_SIGN}"
echo ""

# Step 1: Composer install --no-dev (production dependencies only)
if [[ "$DO_COMPOSER" == true ]]; then
    print_step "Step 1: Installing production dependencies"

    # Check if DDEV is running for this site
    if command -v ddev &>/dev/null; then
        local_ddev_name="${SITE_NAME}-dev"
        if ddev describe "$local_ddev_name" &>/dev/null 2>&1; then
            echo "  Using DDEV: ${local_ddev_name}"
            (cd "$DEV_DIR" && ddev composer install --no-dev --optimize-autoloader --no-interaction 2>&1) || {
                report_error 1 "composer install --no-dev failed via DDEV ${local_ddev_name}"
                exit 1
            }
        else
            echo "  DDEV not running, using local composer"
            (cd "$DEV_DIR" && composer install --no-dev --optimize-autoloader --no-interaction 2>&1) || {
                report_error 1 "composer install --no-dev failed (local composer)"
                exit 1
            }
        fi
    else
        (cd "$DEV_DIR" && composer install --no-dev --optimize-autoloader --no-interaction 2>&1) || {
            report_error 1 "composer install --no-dev failed"
            exit 1
        }
    fi
    print_success "Production dependencies installed"
else
    print_warning "Skipping composer install (--no-composer)"
fi

# Step 2: Create the tarball
print_step "Step 2: Creating tarball"

# Build exclusion list — everything that shouldn't go to production
EXCLUDES=(
    "--exclude=.git"
    "--exclude=.ddev"
    "--exclude=.nwp.yml"
    "--exclude=auth.json"
    "--exclude=.env"
    "--exclude=.env.local"
    "--exclude=.env.local.example"
    "--exclude=.secrets.yml"
    "--exclude=.secrets.data.yml"
    "--exclude=.secrets.example.yml"
    "--exclude=*.sql"
    "--exclude=*.sql.gz"
    "--exclude=node_modules"
    "--exclude=.phpunit.result.cache"
    "--exclude=.phpcs-cache"
    "--exclude=html/sites/default/files"
    "--exclude=private"
)

# Create tarball from the dev directory
(cd "$DEV_DIR" && tar czf "$TARBALL_PATH" \
    "${EXCLUDES[@]}" \
    --transform="s|^./|${SITE_NAME}/|" \
    . 2>&1) || {
    report_error 2 "tar czf failed for ${DEV_DIR}"
    exit 1
}

TARBALL_SIZE=$(du -h "$TARBALL_PATH" | cut -f1)
print_success "Tarball created: ${TARBALL_NAME} (${TARBALL_SIZE})"

# Step 3: Sign the tarball
if [[ "$DO_SIGN" == true ]]; then
    print_step "Step 3: Signing tarball with minisign"

    if ! minisign_check; then
        report_error 3 "minisign not installed (sudo apt-get install -y minisign). Use --no-sign to skip."
        exit 1
    fi

    if ! minisign_keys_exist; then
        report_error 3 "No minisign keys found. Generate with: source lib/minisign.sh && minisign_generate_keys"
        exit 1
    fi

    minisign_sign "$TARBALL_PATH" "NWP deploy: ${SITE_NAME} ${VERSION_TAG} built $(date -Iseconds)" || {
        report_error 3 "minisign signing failed for ${TARBALL_PATH}"
        exit 1
    }
    print_success "Signature: ${TARBALL_NAME}.minisig"
else
    print_warning "Skipping signature (--no-sign)"
fi

# Step 4: Restore dev dependencies
if [[ "$DO_COMPOSER" == true ]]; then
    print_step "Step 4: Restoring dev dependencies"
    if command -v ddev &>/dev/null && ddev describe "${SITE_NAME}-dev" &>/dev/null 2>&1; then
        (cd "$DEV_DIR" && ddev composer install --no-interaction 2>&1) || true
    else
        (cd "$DEV_DIR" && composer install --no-interaction 2>&1) || true
    fi
    print_success "Dev dependencies restored"
fi

################################################################################
# Summary
################################################################################

print_header "Build Complete"

echo "  Tarball:   ${TARBALL_PATH}"
if [[ "$DO_SIGN" == true ]]; then
    echo "  Signature: ${TARBALL_PATH}.minisig"
fi
echo "  Size:      ${TARBALL_SIZE}"
echo "  Tag:       ${VERSION_TAG}"
echo ""
echo "Next steps:"
echo "  Publish:   pl publish ${SITE_NAME} --file ${TARBALL_PATH}"
echo "  Verify:    source lib/minisign.sh && minisign_verify ${TARBALL_PATH}"
echo ""

exit 0
