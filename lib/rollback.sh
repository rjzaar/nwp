#!/bin/bash

################################################################################
# NWP Rollback Library
#
# Automatic recovery from failed deployments
# Source this file: source "$SCRIPT_DIR/lib/rollback.sh"
#
# Dependencies: lib/ui.sh, lib/common.sh
################################################################################

# Rollback data directory
ROLLBACK_DIR="${SCRIPT_DIR}/.rollback"

# Remote rollback subsystem (registers snapshots written by pl stg2live
# on the live host so they show up in pl rollback list and can be
# restored via pl rollback execute).
# This file lives at PROJECT_ROOT/lib/rollback.sh; the sibling lives
# next to us regardless of what SCRIPT_DIR is set to by the caller.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/rollback-remote.sh"

################################################################################
# Deployment History
################################################################################

# Initialize rollback storage
rollback_init() {
    if [ ! -d "$ROLLBACK_DIR" ]; then
        mkdir -p "$ROLLBACK_DIR"
        echo "[]" > "${ROLLBACK_DIR}/history.json"
    fi
}

# Record a deployment for potential rollback
# Usage: rollback_record "sitename" "environment" "backup_path"
rollback_record() {
    local sitename="$1"
    local environment="$2"
    local backup_path="$3"
    local timestamp=$(date -Iseconds)
    local commit_hash=""

    # Get git commit if available
    if [ -d "${sitename}/.git" ]; then
        commit_hash=$(cd "$sitename" && git rev-parse --short HEAD 2>/dev/null || echo "")
    fi

    rollback_init

    local history_file="${ROLLBACK_DIR}/history.json"
    local entry_file="${ROLLBACK_DIR}/${sitename}_${environment}.json"

    # Create rollback entry
    cat > "$entry_file" << EOF
{
    "sitename": "${sitename}",
    "environment": "${environment}",
    "timestamp": "${timestamp}",
    "backup_path": "${backup_path}",
    "commit": "${commit_hash}",
    "status": "active"
}
EOF

    print_status "OK" "Rollback point created: ${sitename}@${environment}"
    return 0
}

# Get last rollback point for a site/environment
# Usage: rollback_get_last "sitename" "environment"
rollback_get_last() {
    local sitename="$1"
    local environment="$2"
    local entry_file="${ROLLBACK_DIR}/${sitename}_${environment}.json"

    if [ -f "$entry_file" ]; then
        cat "$entry_file"
        return 0
    fi

    return 1
}

# List available rollback points
# Usage: rollback_list ["sitename"]
rollback_list() {
    local sitename="${1:-}"

    rollback_init

    print_header "Available Rollback Points"

    local found=0
    # Sort so the most recent shows last (operators tend to scan from the bottom).
    # `|| true` keeps us alive under set -euo pipefail when the glob is empty.
    local entries
    entries=$(ls -1 "${ROLLBACK_DIR}"/*.json 2>/dev/null | sort || true)
    for entry in $entries; do
        if [ -f "$entry" ] && [ "$(basename "$entry")" != "history.json" ]; then
            if [ -z "$sitename" ] || grep -q "\"sitename\": \"${sitename}\"" "$entry"; then
                local site env ts type backup host snap_dbs
                # `|| true` on each field extract: under `set -euo pipefail`, a
                # legacy entry lacking the "type" key would otherwise crash here.
                site=$(grep -m1 '"sitename"' "$entry" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
                env=$(grep -m1 '"environment"' "$entry" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
                ts=$(grep -m1 '"timestamp"' "$entry" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
                type=$(grep -m1 '"type"' "$entry" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
                # Legacy entries lack `type`; default to "local".
                [ -z "$type" ] && type="local"

                echo "  ${site}@${env} (${type})"
                echo "    Time: $ts"
                if [ "$type" = "remote" ]; then
                    host=$(grep -m1 '"host"' "$entry" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
                    snap_dbs=$(grep -m1 '"snapshot_dbs"' "$entry" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
                    echo "    Host: $host"
                    echo "    DB:   $snap_dbs"
                else
                    backup=$(grep -m1 '"backup_path"' "$entry" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
                    echo "    Backup: $backup"
                fi
                echo "    Entry: $(basename "$entry")"
                echo ""
                found=1
            fi
        fi
    done

    if [ $found -eq 0 ]; then
        print_info "No rollback points available"
        print_info "Hint: pl rollback backfill <sitename>   # discover existing remote snapshots"
    fi
}

# Clear old rollback points (keep last N)
# Usage: rollback_cleanup [keep_count]
rollback_cleanup() {
    local keep="${1:-5}"

    rollback_init

    # Group by site+env, keep only last N per group
    for prefix in $(ls "${ROLLBACK_DIR}"/*.json 2>/dev/null | xargs -I{} basename {} | grep -v history | sed 's/_[0-9]*\.json$//' | sort -u); do
        local files=$(ls -t "${ROLLBACK_DIR}/${prefix}"*.json 2>/dev/null | tail -n +$((keep + 1)))
        for f in $files; do
            rm -f "$f"
            ocmsg "Removed old rollback: $(basename "$f")"
        done
    done
}

################################################################################
# Backup Before Deployment
################################################################################

# Create pre-deployment backup
# Usage: rollback_backup_before "sitename" "environment"
rollback_backup_before() {
    local sitename="$1"
    local environment="${2:-prod}"

    print_header "Pre-Deployment Backup"

    # Create backup
    local backup_dir="${ROLLBACK_DIR}/backups/${sitename}/${environment}"
    local timestamp=$(date +%Y%m%dT%H%M%S)
    local backup_name="pre-deploy-${timestamp}"

    mkdir -p "$backup_dir"

    # Use existing backup script
    if [ -x "${SCRIPT_DIR}/backup.sh" ]; then
        "${SCRIPT_DIR}/backup.sh" -b -e="${backup_dir}/${backup_name}" "$sitename" "Pre-deployment backup" > /dev/null 2>&1

        if [ $? -eq 0 ]; then
            local backup_path="${backup_dir}/${backup_name}"
            rollback_record "$sitename" "$environment" "$backup_path"
            echo "$backup_path"
            return 0
        fi
    fi

    print_error "Failed to create pre-deployment backup"
    return 1
}

################################################################################
# Rollback Execution
################################################################################

# Perform rollback
# Usage: rollback_execute "sitename" "environment" [--dry-run]
rollback_execute() {
    local sitename="$1"
    local environment="${2:-prod}"
    local dry_run="${3:-}"

    print_header "Executing Rollback: ${sitename}@${environment}"

    # Find the latest entry — prefer the timestamped naming (new), fall
    # back to the legacy `<site>_<env>.json` (old, single-history).
    # `|| true` keeps us alive under set -euo pipefail when the glob is empty.
    local entry_file
    entry_file=$(ls -1 "${ROLLBACK_DIR}/${sitename}_${environment}_"*.json 2>/dev/null | sort | tail -1 || true)
    if [ -z "$entry_file" ]; then
        entry_file="${ROLLBACK_DIR}/${sitename}_${environment}.json"
    fi

    if [ ! -f "$entry_file" ]; then
        print_error "No rollback point found for ${sitename}@${environment}"
        print_info "Try: pl rollback list ${sitename}"
        return 1
    fi

    # Dispatch on type (legacy entries have no type → "local").
    local type
    type=$(grep -m1 '"type"' "$entry_file" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/')
    [ -z "$type" ] && type="local"

    if [ "$type" = "remote" ]; then
        rollback_execute_remote_from_entry "$entry_file" "$dry_run"
        return $?
    fi

    # ---- Legacy local-DDEV path below (unchanged) ----
    local entry
    entry=$(cat "$entry_file")
    local backup_path=$(echo "$entry" | grep '"backup_path"' | sed 's/.*: *"\([^"]*\)".*/\1/')
    local timestamp=$(echo "$entry" | grep '"timestamp"' | sed 's/.*: *"\([^"]*\)".*/\1/')

    print_info "Rolling back to: $timestamp"
    print_info "Backup path: $backup_path"

    # Verify backup exists
    if [ ! -d "$backup_path" ] && [ ! -f "${backup_path}.sql" ]; then
        print_error "Backup not found: $backup_path"
        return 1
    fi

    # Use restore script
    if [ -x "${SCRIPT_DIR}/restore.sh" ]; then
        local restore_opts=""

        # Check if this is a database-only backup
        if [ -f "${backup_path}.sql" ] && [ ! -f "${backup_path}.tar.gz" ]; then
            restore_opts="-b"
        fi

        print_info "Restoring from backup..."
        if "${SCRIPT_DIR}/restore.sh" $restore_opts "$sitename" "$backup_path"; then
            print_status "OK" "Rollback completed successfully"

            # Mark rollback as used
            local entry_file="${ROLLBACK_DIR}/${sitename}_${environment}.json"
            if [ -f "$entry_file" ]; then
                sed -i 's/"status": "active"/"status": "rolled_back"/' "$entry_file"
            fi

            return 0
        else
            print_error "Restore failed"
            return 1
        fi
    fi

    print_error "Restore script not found"
    return 1
}

# Verify site is functional after rollback
# Usage: rollback_verify "sitename"
rollback_verify() {
    local sitename="$1"

    print_info "Verifying site functionality..."

    # Check if DDEV is running
    if [ -d "${sitename}/.ddev" ]; then
        cd "$sitename" || return 1

        # Check status
        if ddev describe > /dev/null 2>&1; then
            print_status "OK" "DDEV is running"
        else
            print_warning "DDEV not running, starting..."
            ddev start
        fi

        # Check Drupal
        if ddev drush status > /dev/null 2>&1; then
            print_status "OK" "Drupal is responding"
        else
            print_error "Drupal is not responding"
            cd - > /dev/null
            return 1
        fi

        # Clear cache
        ddev drush cr > /dev/null 2>&1

        cd - > /dev/null
        return 0
    fi

    print_warning "Cannot verify - not a DDEV site"
    return 0
}

################################################################################
# Quick Rollback Wrapper
################################################################################

# One-command rollback with verification
# Usage: rollback_quick "sitename" "environment"
rollback_quick() {
    local sitename="$1"
    local environment="${2:-prod}"
    local start_time=$(date +%s)

    print_header "Quick Rollback: ${sitename}@${environment}"

    # Execute rollback
    if ! rollback_execute "$sitename" "$environment"; then
        return 1
    fi

    # Verify
    if ! rollback_verify "$sitename"; then
        print_warning "Verification failed - manual check required"
    fi

    # Report time
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    print_status "OK" "Rollback completed in ${duration} seconds"
    return 0
}
