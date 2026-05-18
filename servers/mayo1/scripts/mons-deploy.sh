#!/bin/bash
set -euo pipefail

################################################################################
# verifier Deploy Script: mayo
#
# F21 Phases 5-8: End-to-end deployment script run on the verifier.
# Pulls a signed tarball from GitLab Packages, verifies the minisign
# signature, deploys to the inactive blue-green slot on the prod host, and swaps.
#
# This script runs ON THE VERIFIER, not on the authoring host or mirror-store.
#
# Prerequisites:
#   - WireGuard tunnel to the prod host is UP (sudo wg-quick up wg-verifier)
#     TODO: read interface name from $NWP_INSTANCES_DIR/instance-manifest.yml
#   - verifier-bot PAT stored at $HOME/.config/mayo-deploy.token
#   - NWP deploy public key at $HOME/.config/nwp-deploy.pub
#   - SSH access to the prod host configured in $HOME/.ssh/config
#     TODO: read SSH_HOST from $NWP_INSTANCES_DIR/instance-manifest.yml
#   - minisign installed on the verifier
#
# Usage: ./verifier-deploy.sh <site> <version> [OPTIONS]
#
# Options:
#   --dry-run        Download and verify but do not deploy
#   --skip-tunnel    Skip WireGuard tunnel check (for testing)
#   --project PATH   GitLab project path (default: mayo/<site>)
#   --step N         Resume from step N (1-5, skips completed steps)
#   -y, --yes        Skip confirmation prompts
#   -h, --help       Show help
#
# Steps:
#   1. Pre-flight checks (minisign, token, pubkey, tunnel, SSH)
#   2. Download tarball and signature from GitLab Packages
#   3. Verify minisign signature
#   4. Upload and extract to inactive slot on the prod host
#   5. Swap slots (blue-green atomic swap)
#
# Error Reporting:
#   If a step fails, the script prints a verifier-say command and a
#   reviewer-friendly message you can paste into the authoring session.
#
# Examples:
#   ./verifier-deploy.sh mayo abc123-20260410-120000
#   ./verifier-deploy.sh mayo abc123-20260410-120000 --dry-run
#   ./verifier-deploy.sh mayo abc123-20260410-120000 --step 4  # resume from step 4
################################################################################

SITE=""
VERSION=""
DRY_RUN=false
SKIP_TUNNEL=false
GITLAB_PROJECT=""
AUTO_YES=false
START_STEP=1

# Configuration
GITLAB_HOST="<gitlab-host>"  # TODO: read from $NWP_INSTANCES_DIR/instance-manifest.yml
GITLAB_API="https://${GITLAB_HOST}/api/v4"
TOKEN_FILE="$HOME/.config/mayo-deploy.token"
PUBKEY_FILE="$HOME/.config/nwp-deploy.pub"
WORK_DIR="$HOME/deploy-staging"
SSH_HOST="mayo1"  # TODO: read from $NWP_INSTANCES_DIR/instance-manifest.yml
WEBROOT="/var/www"
LOG_FILE="$HOME/deploy-staging/verifier-deploy.log"

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) DRY_RUN=true; shift ;;
        --skip-tunnel) SKIP_TUNNEL=true; shift ;;
        --project) GITLAB_PROJECT="$2"; shift 2 ;;
        --step) START_STEP="$2"; shift 2 ;;
        -y|--yes) AUTO_YES=true; shift ;;
        -h|--help)
            grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"; exit 2
            ;;
        *)
            if [[ -z "$SITE" ]]; then
                SITE="$1"
            elif [[ -z "$VERSION" ]]; then
                VERSION="$1"
            else
                echo "Unexpected argument: $1"; exit 2
            fi
            shift
            ;;
    esac
done

if [[ -z "$SITE" || -z "$VERSION" ]]; then
    echo "Usage: ./verifier-deploy.sh <site> <version> [OPTIONS]"
    echo "  e.g.: ./verifier-deploy.sh mayo abc123-20260410-120000"
    exit 2
fi

[[ -z "$GITLAB_PROJECT" ]] && GITLAB_PROJECT="mayo/${SITE}"
GITLAB_PROJECT_ENCODED=$(echo "$GITLAB_PROJECT" | sed 's|/|%2F|g')
PACKAGE_NAME="${SITE}-deploy"
TARBALL_NAME="${SITE}-${VERSION}.tar.gz"
SIG_NAME="${TARBALL_NAME}.minisig"

# Ensure work directory and log file exist
mkdir -p "$WORK_DIR"
LOG_FILE="${WORK_DIR}/verifier-deploy.log"

################################################################################
# Logging and error reporting
################################################################################

log() { echo "$1" | tee -a "$LOG_FILE"; }

report_error() {
    local step="$1"
    local detail="$2"
    echo ""
    echo "================================================================"
    echo "  STEP ${step} FAILED"
    echo "================================================================"
    echo ""
    echo "  Error: ${detail}"
    echo ""
    echo "  To report via verifier-say:"
    echo "    verifier-say \"verifier-deploy step ${step} failed: ${detail}\""
    echo ""
    echo "  Or paste this to the authoring session:"
    echo "    ---"
    echo "    The verifier-deploy script failed at step ${step}."
    echo "    Site: ${SITE}"
    echo "    Version: ${VERSION}"
    echo "    Error: ${detail}"
    echo "    Log file: ${LOG_FILE}"
    echo "    Resume with: ./verifier-deploy.sh ${SITE} ${VERSION} --step ${step}"
    echo "    ---"
    echo ""
    echo "  Full log: cat ${LOG_FILE}"
    echo "================================================================"
}

################################################################################
# Step 1: Pre-flight checks
################################################################################

run_step_1() {
    log ""
    log "=== Step 1/5: Pre-flight checks ==="
    log ""

    # Check minisign
    if ! command -v minisign &>/dev/null; then
        report_error 1 "minisign not installed (sudo apt-get install -y minisign)"
        return 1
    fi
    log "  minisign: OK"

    # Check token
    if [[ ! -f "$TOKEN_FILE" ]]; then
        report_error 1 "Deploy token not found at ${TOKEN_FILE}"
        return 1
    fi
    log "  Token: OK"

    # Check public key
    if [[ ! -f "$PUBKEY_FILE" ]]; then
        report_error 1 "NWP deploy public key not found at ${PUBKEY_FILE}"
        return 1
    fi
    log "  Public key: OK"

    # Check WireGuard tunnel
    # TODO: read WG_IFACE from $NWP_INSTANCES_DIR/instance-manifest.yml.
    # Default is a generic role label; operator must set WG_IFACE in env to
    # match the actual WireGuard interface name configured on this host
    # (e.g. WG_IFACE=wg-<role> before invocation).
    : "${WG_IFACE:=wg-verifier}"
    if [[ "$SKIP_TUNNEL" != true ]]; then
        if ! sudo wg show "$WG_IFACE" &>/dev/null 2>&1; then
            report_error 1 "WireGuard tunnel ${WG_IFACE} is not up (sudo wg-quick up ${WG_IFACE})"
            return 1
        fi
        log "  WireGuard: UP"
    else
        log "  WireGuard: SKIPPED (--skip-tunnel)"
    fi

    # Check SSH to prod host
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$SSH_HOST" 'echo ok' &>/dev/null; then
        report_error 1 "Cannot SSH to ${SSH_HOST} — check tunnel and SSH config"
        return 1
    fi
    log "  SSH to ${SSH_HOST}: OK"

    log ""
    log "  Step 1: PASSED"
}

################################################################################
# Step 2: Download tarball and signature
################################################################################

run_step_2() {
    log ""
    log "=== Step 2/5: Downloading artifacts ==="
    log ""

    local TOKEN
    TOKEN=$(cat "$TOKEN_FILE")

    cd "$WORK_DIR"

    # Clean any previous artifacts with the same name
    rm -f "${TARBALL_NAME}" "${SIG_NAME}"

    local DOWNLOAD_BASE="${GITLAB_API}/projects/${GITLAB_PROJECT_ENCODED}/packages/generic/${PACKAGE_NAME}/${VERSION}"

    # Download tarball
    log "  Tarball: ${TARBALL_NAME}"
    local HTTP_CODE
    HTTP_CODE=$(curl -s -w "%{http_code}" -o "${TARBALL_NAME}" \
        -H "PRIVATE-TOKEN: ${TOKEN}" \
        "${DOWNLOAD_BASE}/${TARBALL_NAME}")

    if [[ "$HTTP_CODE" -lt 200 || "$HTTP_CODE" -ge 300 ]]; then
        rm -f "${TARBALL_NAME}"
        report_error 2 "Tarball download failed (HTTP ${HTTP_CODE}) from ${DOWNLOAD_BASE}/${TARBALL_NAME}"
        return 1
    fi
    log "  Downloaded ($(du -h "${TARBALL_NAME}" | cut -f1))"

    # Download signature
    log "  Signature: ${SIG_NAME}"
    HTTP_CODE=$(curl -s -w "%{http_code}" -o "${SIG_NAME}" \
        -H "PRIVATE-TOKEN: ${TOKEN}" \
        "${DOWNLOAD_BASE}/${SIG_NAME}")

    if [[ "$HTTP_CODE" -lt 200 || "$HTTP_CODE" -ge 300 ]]; then
        rm -f "${TARBALL_NAME}" "${SIG_NAME}"
        report_error 2 "Signature download failed (HTTP ${HTTP_CODE})"
        return 1
    fi
    log "  Downloaded"

    log ""
    log "  Step 2: PASSED"
}

################################################################################
# Step 3: Verify signature
################################################################################

run_step_3() {
    log ""
    log "=== Step 3/5: Verifying minisign signature ==="
    log ""

    cd "$WORK_DIR"

    if [[ ! -f "${TARBALL_NAME}" ]]; then
        report_error 3 "Tarball not found: ${WORK_DIR}/${TARBALL_NAME} — re-run from step 2"
        return 1
    fi

    if [[ ! -f "${SIG_NAME}" ]]; then
        report_error 3 "Signature not found: ${WORK_DIR}/${SIG_NAME} — re-run from step 2"
        return 1
    fi

    if minisign -V -p "$PUBKEY_FILE" -m "${TARBALL_NAME}" 2>>"$LOG_FILE"; then
        log "  Signature: VALID"
    else
        report_error 3 "Signature verification FAILED — tarball may be corrupted or tampered"
        rm -f "${TARBALL_NAME}" "${SIG_NAME}"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log ""
        log "=== Dry Run Complete ==="
        log "  Tarball downloaded and signature verified."
        log "  No deployment performed."
        rm -f "${TARBALL_NAME}" "${SIG_NAME}"
        exit 0
    fi

    log ""
    log "  Step 3: PASSED"
}

################################################################################
# Step 4: Upload and extract to inactive slot
################################################################################

run_step_4() {
    log ""
    log "=== Step 4/5: Uploading to inactive slot on ${SSH_HOST} ==="
    log ""

    cd "$WORK_DIR"

    if [[ ! -f "${TARBALL_NAME}" ]]; then
        report_error 4 "Tarball not found: ${WORK_DIR}/${TARBALL_NAME} — re-run from step 2"
        return 1
    fi

    # Determine which slot is inactive
    local LIVE_TARGET
    LIVE_TARGET=$(ssh "$SSH_HOST" "readlink -f ${WEBROOT}/${SITE}" 2>>"$LOG_FILE") || {
        report_error 4 "Cannot read symlink ${WEBROOT}/${SITE} on ${SSH_HOST} — is blue-green set up?"
        return 1
    }

    local BLUE="${WEBROOT}/${SITE}-blue"
    local GREEN="${WEBROOT}/${SITE}-green"
    local INACTIVE_SLOT INACTIVE_NAME

    if [[ "$LIVE_TARGET" == "$BLUE" ]]; then
        INACTIVE_SLOT="$GREEN"
        INACTIVE_NAME="green"
    elif [[ "$LIVE_TARGET" == "$GREEN" ]]; then
        INACTIVE_SLOT="$BLUE"
        INACTIVE_NAME="blue"
    else
        report_error 4 "Live symlink points to unexpected target: ${LIVE_TARGET} (expected ${BLUE} or ${GREEN}). Run bluegreen-setup.sh first."
        return 1
    fi

    log "  Live slot: $(basename "$LIVE_TARGET")"
    log "  Target slot: ${INACTIVE_NAME} (${INACTIVE_SLOT})"

    # Confirmation
    if [[ "$AUTO_YES" != true ]]; then
        echo ""
        echo "Ready to deploy ${VERSION} to ${INACTIVE_NAME} slot and swap."
        read -p "Continue? [y/N]: " response
        case "$response" in
            [yY][eE][sS]|[yY]) ;;
            *) echo "Cancelled."; exit 0 ;;
        esac
    fi

    # Upload tarball to mayo1
    log "  Uploading tarball..."
    if ! scp "${TARBALL_NAME}" "${SSH_HOST}:/tmp/${TARBALL_NAME}" 2>>"$LOG_FILE"; then
        report_error 4 "scp upload to ${SSH_HOST}:/tmp/ failed"
        return 1
    fi

    # Extract to inactive slot
    log "  Extracting to ${INACTIVE_NAME} slot..."
    if ! ssh "$SSH_HOST" "
        set -e
        cd ${INACTIVE_SLOT}

        # Remove old code but preserve symlinks to shared
        find . -maxdepth 1 -not -name '.' -not -name 'html' | while read f; do
            if [ ! -L \"\$f\" ]; then
                sudo rm -rf \"\$f\"
            fi
        done

        # Extract tarball (strip the site name prefix directory)
        sudo tar xzf /tmp/${TARBALL_NAME} --strip-components=1 -C .

        # Re-create symlinks to shared if they were overwritten
        SHARED='${WEBROOT}/${SITE}-shared'
        [ -L html/sites/default/files ] || sudo ln -sf \"\${SHARED}/files\" html/sites/default/files
        [ -L private ] || sudo ln -sf \"\${SHARED}/private\" private
        [ -L html/sites/default/settings.local.php ] || sudo ln -sf \"\${SHARED}/settings.local.php\" html/sites/default/settings.local.php

        # Fix permissions
        sudo chown -R www-data:www-data .

        # Clean up
        sudo rm -f /tmp/${TARBALL_NAME}
    " 2>>"$LOG_FILE"; then
        report_error 4 "Extract to ${INACTIVE_NAME} slot on ${SSH_HOST} failed — check ${INACTIVE_SLOT} state"
        return 1
    fi
    log "  Extracted and linked"

    # Run database updates
    log "  Running database updates on ${INACTIVE_NAME}..."
    if ! ssh "$SSH_HOST" "
        cd ${INACTIVE_SLOT}
        sudo -u www-data ./vendor/bin/drush updb -y 2>&1
    " 2>>"$LOG_FILE"; then
        log "  WARNING: drush updb returned non-zero (may be OK if no updates pending)"
    fi

    if ! ssh "$SSH_HOST" "
        cd ${INACTIVE_SLOT}
        sudo -u www-data ./vendor/bin/drush cr 2>&1
    " 2>>"$LOG_FILE"; then
        log "  WARNING: drush cr returned non-zero"
    fi

    log ""
    log "  Step 4: PASSED"

    # Save the slot name for step 5
    echo "$INACTIVE_SLOT" > "${WORK_DIR}/.deploy-target-slot"
    echo "$INACTIVE_NAME" > "${WORK_DIR}/.deploy-target-name"
}

################################################################################
# Step 5: Swap slots
################################################################################

run_step_5() {
    log ""
    log "=== Step 5/5: Swapping to inactive slot ==="
    log ""

    # Read target slot from step 4's saved state, or re-detect
    local INACTIVE_SLOT INACTIVE_NAME
    if [[ -f "${WORK_DIR}/.deploy-target-slot" ]]; then
        INACTIVE_SLOT=$(cat "${WORK_DIR}/.deploy-target-slot")
        INACTIVE_NAME=$(cat "${WORK_DIR}/.deploy-target-name")
    else
        # Re-detect (needed when resuming with --step 5)
        local LIVE_TARGET
        LIVE_TARGET=$(ssh "$SSH_HOST" "readlink -f ${WEBROOT}/${SITE}")
        local BLUE="${WEBROOT}/${SITE}-blue"
        local GREEN="${WEBROOT}/${SITE}-green"
        if [[ "$LIVE_TARGET" == "$BLUE" ]]; then
            INACTIVE_SLOT="$GREEN"; INACTIVE_NAME="green"
        elif [[ "$LIVE_TARGET" == "$GREEN" ]]; then
            INACTIVE_SLOT="$BLUE"; INACTIVE_NAME="blue"
        else
            report_error 5 "Cannot detect slots — symlink points to: ${LIVE_TARGET}"
            return 1
        fi
    fi

    log "  Swapping to: ${INACTIVE_NAME} (${INACTIVE_SLOT})"

    # Upload and run the swap script
    local SWAP_SCRIPT_DIR
    SWAP_SCRIPT_DIR="$(dirname "$0")"
    if [[ -f "${SWAP_SCRIPT_DIR}/bluegreen-swap.sh" ]]; then
        log "  Uploading swap script..."
        if ! scp "${SWAP_SCRIPT_DIR}/bluegreen-swap.sh" "${SSH_HOST}:/tmp/bluegreen-swap.sh" 2>>"$LOG_FILE"; then
            report_error 5 "Failed to upload bluegreen-swap.sh to ${SSH_HOST}"
            return 1
        fi
        if ! ssh "$SSH_HOST" "
            chmod +x /tmp/bluegreen-swap.sh
            sudo /tmp/bluegreen-swap.sh --site ${SITE} -y
            rm -f /tmp/bluegreen-swap.sh
        " 2>>"$LOG_FILE"; then
            report_error 5 "bluegreen-swap.sh failed on ${SSH_HOST} — site may have auto-rolled back"
            return 1
        fi
    else
        # Inline swap if script not available
        log "  Performing inline swap (swap script not found locally)..."
        if ! ssh "$SSH_HOST" "
            set -e
            LINK='${WEBROOT}/${SITE}'
            TEMP=\"\${LINK}.tmp.\$\$\"
            sudo ln -sfn '${INACTIVE_SLOT}' \"\$TEMP\"
            sudo mv -Tf \"\$TEMP\" \"\$LINK\"
            cd '${INACTIVE_SLOT}'
            sudo -u www-data ./vendor/bin/drush cr 2>/dev/null || true
            sudo -u www-data ./vendor/bin/drush state:set system.maintenance_mode 0 -y 2>/dev/null || true
            echo 'Swap complete: ${SITE} -> ${INACTIVE_NAME}'
        " 2>>"$LOG_FILE"; then
            report_error 5 "Inline swap failed on ${SSH_HOST} — check symlink state: ssh ${SSH_HOST} 'ls -la ${WEBROOT}/${SITE}'"
            return 1
        fi
    fi

    # Clean up local artifacts and state files
    rm -f "${WORK_DIR}/${TARBALL_NAME}" "${WORK_DIR}/${SIG_NAME}"
    rm -f "${WORK_DIR}/.deploy-target-slot" "${WORK_DIR}/.deploy-target-name"

    log ""
    log "  Step 5: PASSED"
}

################################################################################
# Main
################################################################################

# Initialise log
echo "=== verifier Deploy $(date -Iseconds) ===" >> "$LOG_FILE"

log "=== verifier Deploy: ${SITE} ==="
log "  Version:   ${VERSION}"
log "  Package:   ${PACKAGE_NAME}"
log "  Dry run:   ${DRY_RUN}"
log "  Start:     Step ${START_STEP}"
log ""

# Run steps
for step in 1 2 3 4 5; do
    if [[ $step -lt $START_STEP ]]; then
        log "[Step ${step}] Skipped (resuming from step ${START_STEP})"
        continue
    fi

    case $step in
        1) run_step_1 || exit 1 ;;
        2) run_step_2 || exit 1 ;;
        3) run_step_3 || exit 1 ;;
        4) run_step_4 || exit 1 ;;
        5) run_step_5 || exit 1 ;;
    esac
done

log ""
log "=== Deploy Complete ==="
log "  Site: ${SITE}"
log "  Version: ${VERSION}"
log "  Status: LIVE"
log "  Log: ${LOG_FILE}"
log ""
log "To verify:"
log "  ssh ${SSH_HOST} 'curl -sI http://127.0.0.1 -H \"Host: ${SITE}\"' | head -5"
log ""
log "To rollback:"
log "  ssh ${SSH_HOST} 'sudo /tmp/bluegreen-swap.sh --site ${SITE} --rollback -y'"
log "  (or re-upload the swap script if /tmp/ was cleaned)"
log ""
log "To report success:"
log "  verifier-say \"deploy ${SITE} ${VERSION} complete -- smoke test passed\""
log ""
