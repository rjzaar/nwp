#!/bin/bash
set -euo pipefail

################################################################################
# mayo1 Blue-Green Swap
#
# F21 Phase 8: Atomic swap between blue and green slots.
#
# Flow:
#   1. Detect which slot is currently live
#   2. Run database updates on the inactive slot (drush updb)
#   3. Brief read-only lock (maintenance mode)
#   4. Atomic symlink swap
#   5. Clear caches
#   6. Smoke test
#   7. If smoke fails -> rollback (swap back)
#
# Usage: sudo ./bluegreen-swap.sh [OPTIONS]
#
# Options:
#   --webroot DIR    Web root parent (default: /var/www)
#   --site SITE      Site name (default: mayostudios.org)
#   --skip-updb      Skip drush updb on inactive slot
#   --skip-smoke     Skip post-swap smoke test
#   --rollback       Swap back to previous slot (undo last swap)
#   -y, --yes        Skip confirmation prompt
#   -h, --help       Show help
#
# Error Reporting:
#   If a step fails, the script prints a mons-say command and a
#   message you can paste into the dev Claude session.
################################################################################

WEBROOT="/var/www"
SITE="mayostudios.org"
WEB_USER="www-data"
SKIP_UPDB=false
SKIP_SMOKE=false
ROLLBACK=false
AUTO_YES=false
LOG_DIR="/var/log/nwp"

while [[ $# -gt 0 ]]; do
    case $1 in
        --webroot) WEBROOT="$2"; shift 2 ;;
        --site) SITE="$2"; shift 2 ;;
        --skip-updb) SKIP_UPDB=true; shift ;;
        --skip-smoke) SKIP_SMOKE=true; shift ;;
        --rollback) ROLLBACK=true; shift ;;
        -y|--yes) AUTO_YES=true; shift ;;
        -h|--help)
            grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 2 ;;
    esac
done

SITE_LINK="${WEBROOT}/${SITE}"
BLUE_DIR="${WEBROOT}/${SITE}-blue"
GREEN_DIR="${WEBROOT}/${SITE}-green"

mkdir -p "$LOG_DIR"

################################################################################
# Error reporting
################################################################################

report_error() {
    local step="$1"
    local detail="$2"
    echo ""
    echo "================================================================"
    echo "  SWAP STEP ${step} FAILED"
    echo "================================================================"
    echo ""
    echo "  Error: ${detail}"
    echo ""
    echo "  To report from mons:"
    echo "    mons-say \"bluegreen-swap step ${step} failed on ${SITE}: ${detail}\""
    echo ""
    echo "  Or paste this to the dev Claude session:"
    echo "    ---"
    echo "    bluegreen-swap.sh failed at step ${step}."
    echo "    Site: ${SITE}"
    echo "    Error: ${detail}"
    echo "    Current live: $(readlink -f "${SITE_LINK}" 2>/dev/null || echo 'UNKNOWN')"
    echo "    Blue: ${BLUE_DIR}"
    echo "    Green: ${GREEN_DIR}"
    echo "    ---"
    echo ""
    echo "================================================================"
}

################################################################################
# Validation
################################################################################

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must run as root (sudo)."
    exit 1
fi

# Determine current and target slots
if [[ ! -L "$SITE_LINK" ]]; then
    report_error 0 "${SITE_LINK} is not a symlink — run bluegreen-setup.sh first"
    exit 2
fi

CURRENT_SLOT=$(readlink -f "$SITE_LINK")

if [[ "$CURRENT_SLOT" == "$BLUE_DIR" ]]; then
    CURRENT_NAME="blue"
    TARGET_DIR="$GREEN_DIR"
    TARGET_NAME="green"
elif [[ "$CURRENT_SLOT" == "$GREEN_DIR" ]]; then
    CURRENT_NAME="green"
    TARGET_DIR="$BLUE_DIR"
    TARGET_NAME="blue"
else
    report_error 0 "Symlink points to unexpected target: ${CURRENT_SLOT} (expected blue or green)"
    exit 2
fi

if [[ "$ROLLBACK" == true ]]; then
    echo "ROLLBACK: Swapping back to ${TARGET_NAME} slot"
fi

echo "=== Blue-Green Swap: ${SITE} ==="
echo "  Current (live): ${CURRENT_NAME} (${CURRENT_SLOT})"
echo "  Target:         ${TARGET_NAME} (${TARGET_DIR})"
echo ""

# Verify target slot has a working Drupal installation
if [[ ! -f "${TARGET_DIR}/html/index.php" ]]; then
    report_error 0 "Target slot ${TARGET_NAME} does not have html/index.php — deploy code to ${TARGET_DIR} before swapping"
    exit 2
fi

if [[ ! -f "${TARGET_DIR}/vendor/bin/drush" ]]; then
    report_error 0 "Target slot ${TARGET_NAME} does not have vendor/bin/drush"
    exit 2
fi

# Confirmation
if [[ "$AUTO_YES" != true ]]; then
    echo "This will swap the live site from ${CURRENT_NAME} to ${TARGET_NAME}."
    echo "There will be a brief maintenance window during the swap."
    read -p "Continue? [y/N]: " response
    case "$response" in
        [yY][eE][sS]|[yY]) ;;
        *) echo "Cancelled."; exit 0 ;;
    esac
fi

################################################################################
# Step 1: Database updates
################################################################################

if [[ "$SKIP_UPDB" != true && "$ROLLBACK" != true ]]; then
    echo "[1/5] Running database updates on ${TARGET_NAME}..."
    cd "$TARGET_DIR"
    if sudo -u "$WEB_USER" ./vendor/bin/drush updb -y 2>&1; then
        echo "  Database updates applied"
    else
        echo "WARNING: drush updb returned non-zero. Proceeding anyway."
        echo "  (This is often OK if there are no pending updates)"
    fi
else
    echo "[1/5] Skipping database updates"
fi

################################################################################
# Step 1b: Stamp deployment identifier on target
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$SCRIPT_DIR/stamp-deployment-identifier.sh" ]]; then
    echo "[1b/5] Stamping deployment identifier on ${TARGET_NAME}..."
    "$SCRIPT_DIR/stamp-deployment-identifier.sh" "${TARGET_DIR}/html"
else
    echo "[1b/5] stamp-deployment-identifier.sh not found, skipping"
fi

################################################################################
# Step 2: Maintenance mode
################################################################################

echo "[2/5] Enabling maintenance mode..."
cd "$CURRENT_SLOT"
if ! sudo -u "$WEB_USER" ./vendor/bin/drush state:set system.maintenance_mode 1 -y 2>/dev/null; then
    echo "  WARNING: Could not set maintenance mode (proceeding)"
fi

################################################################################
# Step 3: Atomic swap
################################################################################

echo "[3/5] Swapping symlink..."
# Use ln -sfn with a temp symlink for atomicity
TEMP_LINK="${SITE_LINK}.tmp.$$"
if ! ln -sfn "$TARGET_DIR" "$TEMP_LINK"; then
    report_error 3 "Failed to create temporary symlink ${TEMP_LINK} -> ${TARGET_DIR}"
    # Try to disable maintenance mode before exiting
    cd "$CURRENT_SLOT"
    sudo -u "$WEB_USER" ./vendor/bin/drush state:set system.maintenance_mode 0 -y 2>/dev/null || true
    exit 1
fi

if ! mv -Tf "$TEMP_LINK" "$SITE_LINK"; then
    report_error 3 "Failed to atomically replace ${SITE_LINK} (mv -Tf failed)"
    rm -f "$TEMP_LINK"
    cd "$CURRENT_SLOT"
    sudo -u "$WEB_USER" ./vendor/bin/drush state:set system.maintenance_mode 0 -y 2>/dev/null || true
    exit 1
fi
echo "  ${SITE} -> ${TARGET_DIR}"

################################################################################
# Step 4: Post-swap cache clear
################################################################################

echo "[4/5] Post-swap: deploy hooks, cache clear, maintenance mode off..."
cd "$TARGET_DIR"
# Run deploy hooks (updates content, runs hook_deploy_N).
if sudo -u "$WEB_USER" ./vendor/bin/drush deploy -y 2>&1; then
    echo "  drush deploy: OK"
else
    echo "  WARNING: drush deploy returned non-zero (site may still work)"
fi
if ! sudo -u "$WEB_USER" ./vendor/bin/drush cr 2>/dev/null; then
    echo "  WARNING: cache clear failed (site may still work)"
fi
sudo -u "$WEB_USER" ./vendor/bin/drush state:set system.maintenance_mode 0 -y 2>/dev/null || true
echo "  Site is live on ${TARGET_NAME}"

################################################################################
# Step 5: Smoke test
################################################################################

if [[ "$SKIP_SMOKE" != true ]]; then
    echo "[5/5] Smoke test..."
    SMOKE_OK=true

    # Test 1: Drush bootstrap
    if sudo -u "$WEB_USER" ./vendor/bin/drush status --format=json > /dev/null 2>&1; then
        echo "  Drush bootstrap: OK"
    else
        echo "  Drush bootstrap: FAILED"
        SMOKE_OK=false
    fi

    # Test 2: HTTP check (if curl available and nginx running)
    if command -v curl &>/dev/null; then
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://127.0.0.1" -H "Host: ${SITE}" 2>/dev/null || echo "000")
        if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "301" || "$HTTP_CODE" == "302" ]]; then
            echo "  HTTP check: OK (${HTTP_CODE})"
        else
            echo "  HTTP check: FAILED (${HTTP_CODE})"
            SMOKE_OK=false
        fi
    fi

    if [[ "$SMOKE_OK" != true ]]; then
        echo ""
        echo "SMOKE TEST FAILED -- rolling back!"
        # Swap back
        TEMP_LINK="${SITE_LINK}.tmp.$$"
        ln -sfn "$CURRENT_SLOT" "$TEMP_LINK"
        mv -Tf "$TEMP_LINK" "$SITE_LINK"
        cd "$CURRENT_SLOT"
        sudo -u "$WEB_USER" ./vendor/bin/drush cr 2>/dev/null || true
        sudo -u "$WEB_USER" ./vendor/bin/drush state:set system.maintenance_mode 0 -y 2>/dev/null || true

        echo "$(date -Iseconds) SWAP FAILED: ${CURRENT_NAME}->${TARGET_NAME} (smoke test failed, rolled back)" >> "${LOG_DIR}/deployments.log"

        report_error 5 "Smoke test failed after swap — auto-rolled back to ${CURRENT_NAME}. Investigate the ${TARGET_NAME} slot: ${TARGET_DIR}"
        exit 1
    fi
else
    echo "[5/5] Skipping smoke test"
fi

# Log the swap
echo "$(date -Iseconds) SWAP: ${CURRENT_NAME}->${TARGET_NAME} (success)" >> "${LOG_DIR}/deployments.log"

echo ""
echo "=== Swap Complete ==="
echo "  Live: ${TARGET_NAME} (${TARGET_DIR})"
echo "  Previous: ${CURRENT_NAME} (${CURRENT_SLOT})"
echo ""
echo "To rollback: sudo ./bluegreen-swap.sh --site ${SITE} --rollback -y"
echo ""
echo "To report success from mons:"
echo "  mons-say \"swap ${SITE} ${CURRENT_NAME}->${TARGET_NAME} complete\""
echo ""
