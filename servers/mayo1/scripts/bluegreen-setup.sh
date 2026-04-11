#!/bin/bash
set -euo pipefail

################################################################################
# mayo1 Blue-Green Slot Setup
#
# F21 Phase 8: Creates the blue-green directory layout on mayo1.
# Run ONCE on mayo1 to convert from single-directory to slotted deployment.
#
# Layout after setup:
#   /var/www/mayostudios.org          -> symlink to active slot
#   /var/www/mayostudios.org-blue/    -> slot A (codebase)
#   /var/www/mayostudios.org-green/   -> slot B (codebase)
#   /var/www/mayostudios.org-shared/  -> shared state (files, private, config)
#
# The shared directory holds:
#   - sites/default/files/   (user uploads -- shared between slots)
#   - private/               (private file system -- shared)
#   - sites/default/settings.local.php  (DB creds -- shared, not in git)
#
# Usage: sudo ./bluegreen-setup.sh [--webroot /var/www] [--site mayostudios.org]
#
# This script is idempotent -- safe to run multiple times.
#
# Error Reporting:
#   If a step fails, the script prints a message you can report via mons-say
#   or paste into the dev Claude session.
################################################################################

WEBROOT="/var/www"
SITE="mayostudios.org"
WEB_USER="www-data"

while [[ $# -gt 0 ]]; do
    case $1 in
        --webroot) WEBROOT="$2"; shift 2 ;;
        --site) SITE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: sudo ./bluegreen-setup.sh [--webroot /var/www] [--site mayostudios.org]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 2 ;;
    esac
done

SITE_DIR="${WEBROOT}/${SITE}"
BLUE_DIR="${WEBROOT}/${SITE}-blue"
GREEN_DIR="${WEBROOT}/${SITE}-green"
SHARED_DIR="${WEBROOT}/${SITE}-shared"

################################################################################
# Error reporting
################################################################################

report_error() {
    local step="$1"
    local detail="$2"
    echo ""
    echo "================================================================"
    echo "  SETUP STEP ${step} FAILED"
    echo "================================================================"
    echo ""
    echo "  Error: ${detail}"
    echo ""
    echo "  This script is idempotent -- fix the issue and re-run it."
    echo ""
    echo "  To report from mons:"
    echo "    mons-say \"bluegreen-setup step ${step} failed on ${SITE}: ${detail}\""
    echo ""
    echo "  Or paste this to the dev Claude session:"
    echo "    ---"
    echo "    bluegreen-setup.sh failed at step ${step}."
    echo "    Site: ${SITE}, Webroot: ${WEBROOT}"
    echo "    Error: ${detail}"
    echo "    State: blue=${BLUE_DIR} green=${GREEN_DIR} shared=${SHARED_DIR}"
    echo "    Fix and re-run: sudo ./bluegreen-setup.sh --site ${SITE}"
    echo "    ---"
    echo ""
    echo "================================================================"
}

################################################################################
# Validation
################################################################################

echo "=== Blue-Green Slot Setup: ${SITE} ==="
echo "  Site dir:   ${SITE_DIR}"
echo "  Blue slot:  ${BLUE_DIR}"
echo "  Green slot: ${GREEN_DIR}"
echo "  Shared:     ${SHARED_DIR}"
echo ""

# Must run as root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must run as root (sudo)."
    exit 1
fi

################################################################################
# Step 1: Create shared directory
################################################################################

echo "[1/6] Creating shared directory..."
if ! mkdir -p "${SHARED_DIR}/files" "${SHARED_DIR}/private"; then
    report_error 1 "Cannot create ${SHARED_DIR} -- check disk space and permissions"
    exit 1
fi

# Move existing files to shared if they exist in the current site dir
if [[ -d "${SITE_DIR}/html/sites/default/files" && ! -L "${SITE_DIR}/html/sites/default/files" ]]; then
    echo "  Moving existing files/ to shared..."
    if ! rsync -a "${SITE_DIR}/html/sites/default/files/" "${SHARED_DIR}/files/"; then
        report_error 1 "rsync of files/ to shared failed"
        exit 1
    fi
fi

if [[ -d "${SITE_DIR}/private" && ! -L "${SITE_DIR}/private" ]]; then
    echo "  Moving existing private/ to shared..."
    if ! rsync -a "${SITE_DIR}/private/" "${SHARED_DIR}/private/"; then
        report_error 1 "rsync of private/ to shared failed"
        exit 1
    fi
fi

# Copy settings.local.php if it exists (DB creds, not in git)
if [[ -f "${SITE_DIR}/html/sites/default/settings.local.php" ]]; then
    cp "${SITE_DIR}/html/sites/default/settings.local.php" "${SHARED_DIR}/settings.local.php"
    echo "  Copied settings.local.php to shared"
elif [[ -f "${SITE_DIR}/html/sites/default/settings.php" ]]; then
    cp "${SITE_DIR}/html/sites/default/settings.php" "${SHARED_DIR}/settings.local.php"
    echo "  Copied settings.php to shared as settings.local.php"
fi

chown -R "${WEB_USER}:${WEB_USER}" "${SHARED_DIR}"
echo "  Done"

################################################################################
# Step 2: Create blue slot from current site
################################################################################

echo "[2/6] Creating blue slot..."
if [[ -d "$BLUE_DIR" ]]; then
    echo "  Blue slot already exists, skipping"
else
    if [[ -L "$SITE_DIR" ]]; then
        echo "  Site is already a symlink -- blue slot must exist"
    elif [[ -d "$SITE_DIR" ]]; then
        # Copy current site to blue slot
        if ! cp -a "${SITE_DIR}" "${BLUE_DIR}"; then
            report_error 2 "Failed to copy ${SITE_DIR} to ${BLUE_DIR} -- check disk space"
            exit 1
        fi
        echo "  Copied current site to blue slot"
    else
        mkdir -p "${BLUE_DIR}/html/sites/default"
        echo "  Created empty blue slot"
    fi
fi

################################################################################
# Step 3: Create green slot
################################################################################

echo "[3/6] Creating green slot..."
if [[ -d "$GREEN_DIR" ]]; then
    echo "  Green slot already exists, skipping"
else
    mkdir -p "${GREEN_DIR}/html/sites/default"
    echo "  Created empty green slot"
fi

################################################################################
# Step 4: Symlink shared assets into both slots
################################################################################

echo "[4/6] Symlinking shared assets..."
for SLOT in "$BLUE_DIR" "$GREEN_DIR"; do
    SLOT_NAME=$(basename "$SLOT")

    # Symlink files/
    SLOT_FILES="${SLOT}/html/sites/default/files"
    if [[ -d "$SLOT_FILES" && ! -L "$SLOT_FILES" ]]; then
        rm -rf "$SLOT_FILES"
    fi
    if [[ ! -L "$SLOT_FILES" ]]; then
        mkdir -p "$(dirname "$SLOT_FILES")"
        ln -sf "${SHARED_DIR}/files" "$SLOT_FILES"
        echo "  ${SLOT_NAME}: files/ -> shared"
    fi

    # Symlink private/
    SLOT_PRIVATE="${SLOT}/private"
    if [[ -d "$SLOT_PRIVATE" && ! -L "$SLOT_PRIVATE" ]]; then
        rm -rf "$SLOT_PRIVATE"
    fi
    if [[ ! -L "$SLOT_PRIVATE" ]]; then
        ln -sf "${SHARED_DIR}/private" "$SLOT_PRIVATE"
        echo "  ${SLOT_NAME}: private/ -> shared"
    fi

    # Symlink or copy settings.local.php
    SLOT_SETTINGS="${SLOT}/html/sites/default/settings.local.php"
    if [[ -f "${SHARED_DIR}/settings.local.php" && ! -L "$SLOT_SETTINGS" ]]; then
        ln -sf "${SHARED_DIR}/settings.local.php" "$SLOT_SETTINGS"
        echo "  ${SLOT_NAME}: settings.local.php -> shared"
    fi
done

################################################################################
# Step 5: Convert site directory to symlink
################################################################################

echo "[5/6] Converting site directory to symlink..."
if [[ -L "$SITE_DIR" ]]; then
    CURRENT_TARGET=$(readlink -f "$SITE_DIR")
    echo "  Already a symlink -> ${CURRENT_TARGET}"
else
    # Remove the original directory (we already copied to blue)
    if ! rm -rf "${SITE_DIR}"; then
        report_error 5 "Failed to remove original ${SITE_DIR} -- is a process using it?"
        exit 1
    fi
    if ! ln -sf "${BLUE_DIR}" "${SITE_DIR}"; then
        report_error 5 "Failed to create symlink ${SITE_DIR} -> ${BLUE_DIR}"
        echo ""
        echo "  CRITICAL: The site directory has been removed but the symlink was not created."
        echo "  Manually fix: sudo ln -sf ${BLUE_DIR} ${SITE_DIR}"
        exit 1
    fi
    echo "  ${SITE} -> ${BLUE_DIR} (blue is now live)"
fi

################################################################################
# Step 6: Set permissions
################################################################################

echo "[6/6] Setting permissions..."
chown -R "${WEB_USER}:${WEB_USER}" "${BLUE_DIR}" "${GREEN_DIR}" "${SHARED_DIR}"
# The symlink itself should be owned by root
chown -h root:root "${SITE_DIR}" 2>/dev/null || true
echo "  Done"

echo ""
echo "=== Blue-Green Setup Complete ==="
echo ""
echo "Current state:"
echo "  Live: $(readlink -f "${SITE_DIR}")"
echo "  Blue: ${BLUE_DIR}"
echo "  Green: ${GREEN_DIR}"
echo "  Shared: ${SHARED_DIR}"
echo ""
echo "To deploy new code:"
echo "  1. Unpack tarball into the INACTIVE slot"
echo "  2. Run drush updb + cr on the inactive slot"
echo "  3. Run the swap script: ./bluegreen-swap.sh"
echo ""
echo "To report success from mons:"
echo "  mons-say \"bluegreen-setup complete on ${SITE}\""
echo ""
