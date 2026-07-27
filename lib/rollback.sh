#!/bin/bash

################################################################################
# NWP Rollback Library
#
# Automatic recovery from failed deployments
# Source this file: source "$SCRIPT_DIR/lib/rollback.sh"
#
# Dependencies: lib/ui.sh, lib/common.sh
################################################################################

# Rollback data directory.
#
# HISTORY: this was `${SCRIPT_DIR}/.rollback` — i.e. inside whatever checkout
# happened to run the command. The standing rule mandates deploying from a
# `pl issue work` worktree, and worktrees are deleted when the issue closes, so
# the ledger pointing at a snapshot on a live host died with the worktree. At
# the time of this change 33 such `.rollback` directories existed across the
# tree. The problem got WORSE as worktree discipline improved.
#
# The ledger is machine state, not checkout state, so it now lives in the
# XDG state dir and is resolved checkout-independently. Entries written by
# older checkouts are still READ (see rollback_legacy_dirs) for one release,
# and rollback_init migrates them forward idempotently without deleting the
# originals.
ROLLBACK_DIR="${NWP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/nwp}/rollback"

# Legacy per-checkout ledger locations, read-only, for one release.
# Emits one path per line; may be empty.
rollback_legacy_dirs() {
    local d
    # The caller's own checkout (SCRIPT_DIR is set by each command script).
    [ -n "${SCRIPT_DIR:-}" ] && [ -d "${SCRIPT_DIR}/.rollback" ] && printf '%s\n' "${SCRIPT_DIR}/.rollback"
    # This library's repo, whether we are in a worktree or the main checkout.
    local here repo_root
    here="$(dirname "${BASH_SOURCE[0]}")"
    if repo_root=$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
        repo_root="$(dirname "$repo_root")"
        for d in "${repo_root}/scripts/commands/.rollback" "${repo_root}/.rollback"; do
            [ -d "$d" ] && printf '%s\n' "$d"
        done
    fi
}

# Copy legacy entries forward into the canonical ledger. Idempotent, and
# non-destructive: the originals are left in place so a revert of this change
# loses nothing.
rollback_migrate_legacy() {
    local dir f base
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        [ "$dir" = "$ROLLBACK_DIR" ] && continue
        for f in "$dir"/*.json; do
            [ -f "$f" ] || continue
            base="$(basename "$f")"
            [ "$base" = "history.json" ] && continue
            if [ ! -f "${ROLLBACK_DIR}/${base}" ]; then
                cp -p "$f" "${ROLLBACK_DIR}/${base}" 2>/dev/null || true
            fi
        done
    done < <(rollback_legacy_dirs | sort -u)
}

# Remote rollback subsystem (registers snapshots written by pl stg2live
# on the live host so they show up in pl rollback list and can be
# restored via pl rollback execute).
# This file lives at PROJECT_ROOT/lib/rollback.sh; the sibling lives
# next to us regardless of what SCRIPT_DIR is set to by the caller.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/rollback-remote.sh"

# deploy-gate.sh: hardware+signature gate on prod-writes (ADR-0028); no-op
# unless configured (ver) — the AI test tier (A14) is unaffected. Needed here
# because a REMOTE rollback restores DBs + nginx on the live/prod host — a
# prod write that must pass the same gate as a deploy (ops#79 finding 7).
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/deploy-gate.sh"

# pair.sh: ops#83 both-or-forward RESTORE choke-point. A remote rollback at a
# coupled tier (live/prod) restores the provider/consumer DB — which can orphan
# UID-locks. pair_guard_restore refuses a restore that would move one member
# behind the other's identity anchor unless a typed, ledgered --override-pair is
# given. No-op for unpaired sites / uncoupled tiers.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/pair.sh"

################################################################################
# Deployment History
################################################################################

# Initialize rollback storage
rollback_init() {
    if [ ! -d "$ROLLBACK_DIR" ]; then
        mkdir -p "$ROLLBACK_DIR"
        echo "[]" > "${ROLLBACK_DIR}/history.json"
    fi
    # Pull forward anything a pre-relocation checkout wrote. Cheap, idempotent.
    rollback_migrate_legacy
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
                elif [ "$type" = "moodle-remote" ]; then
                    # Different key names to the generic remote shape; rendering
                    # them as "Backup:" printed an empty path and made a usable
                    # recovery point look broken.
                    local mroot mplug
                    host=$(grep -m1 '"host"' "$entry" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
                    snap_dbs=$(grep -m1 '"snapshot_db"' "$entry" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
                    mplug=$(grep -m1 '"snapshot_plugins"' "$entry" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
                    mroot=$(grep -m1 '"moodle_root"' "$entry" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
                    echo "    Host:    $host"
                    echo "    DB:      $snap_dbs"
                    echo "    Plugins: $mplug"
                    echo "    Root:    $mroot"
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

# Rollback entry types this build knows how to execute. An entry whose type is
# not in this table is a FAIL-CLOSED error: we must never hand an artifact to a
# code path written for a different artifact shape. That is precisely the bug
# this table replaces — `moodle-remote` entries fell through an
# `if type = remote` test into the legacy local-DDEV branch, which then read a
# `backup_path` key that a moodle-remote entry does not have, and reported
# "Backup not found:" for a snapshot that was sitting on the live host.
ROLLBACK_KNOWN_TYPES=(local remote moodle-remote)

# Resolve the tier to roll back. Never guess "prod": no site in this fleet has
# a prod tier, so the old default made every real recovery point invisible.
# Prefers an explicit argument, else the tier of the most recent entry that
# actually exists for the site.
rollback_default_env() {
    local sitename="$1"
    local f base env latest=""
    rollback_init
    for f in "${ROLLBACK_DIR}/${sitename}_"*.json; do
        [ -f "$f" ] || continue
        base="$(basename "$f" .json)"
        # <site>_<env>[_<ts>]
        env="${base#"${sitename}_"}"
        env="${env%%_*}"
        [ -n "$env" ] && latest="$env"
    done
    printf '%s' "$latest"
}

# Which tiers DO have entries for this site (for a useful error message).
rollback_available_envs() {
    local sitename="$1" f base env
    for f in "${ROLLBACK_DIR}/${sitename}_"*.json; do
        [ -f "$f" ] || continue
        base="$(basename "$f" .json)"
        env="${base#"${sitename}_"}"
        env="${env%%_*}"
        [ -n "$env" ] && printf '%s\n' "$env"
    done | sort -u
}

rollback_execute() {
    local sitename="$1"
    local environment="${2:-}"
    local dry_run="${3:-}"

    rollback_init

    # Default the tier from reality rather than a hardcoded "prod".
    if [ -z "$environment" ]; then
        environment="$(rollback_default_env "$sitename")"
        if [ -z "$environment" ]; then
            print_error "No rollback points found for ${sitename}"
            print_info "Try: pl rollback list ${sitename}"
            print_info "Hint: pl rollback backfill ${sitename}   # discover snapshots already on the live host"
            return 1
        fi
        print_info "No tier given; using '${environment}' (the tier that has recovery points)."
    fi

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
        # Say which tiers DO have points — the operator almost always chose the
        # wrong word (live vs prod vs stg), not the wrong site.
        local other_envs
        other_envs=$(rollback_available_envs "$sitename" | grep -v "^${environment}$" | paste -sd', ' - || true)
        if [ -n "$other_envs" ]; then
            print_info "Recovery points DO exist for ${sitename} at: ${other_envs}"
            print_info "Try: pl rollback execute ${sitename} <tier> --dry-run"
        fi
        print_info "Try: pl rollback list ${sitename}"
        return 1
    fi

    # Dispatch on type (legacy entries have no type → "local").
    local type
    type=$(grep -m1 '"type"' "$entry_file" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/')
    [ -z "$type" ] && type="local"

    # FAIL CLOSED on an unrecognised type. Do not fall through to any branch.
    local _known _t_ok=false
    for _known in "${ROLLBACK_KNOWN_TYPES[@]}"; do
        [ "$_known" = "$type" ] && _t_ok=true && break
    done
    if [ "$_t_ok" != "true" ]; then
        print_error "unknown rollback type: '${type}'"
        print_info "Entry: ${entry_file}"
        print_info "Known types: ${ROLLBACK_KNOWN_TYPES[*]}"
        print_info "Refusing to guess — an entry of an unknown shape must not be"
        print_info "handed to a restore path written for a different shape."
        return 1
    fi

    # Both remote shapes restore on a live/prod host and share the same gates.
    if [ "$type" = "remote" ] || [ "$type" = "moodle-remote" ]; then
        # Hardware+signature gate (ADR-0028/ops#79): a remote rollback writes
        # DBs + nginx config on the live/prod host. Gate it exactly like a
        # deploy. Local-DDEV rollbacks (below) never prompt; dry runs write
        # nothing so they are exempt.
        if [ "$dry_run" != "--dry-run" ]; then
            # ops#83 both-or-forward RESTORE gate (BEFORE the hardware gate, same
            # order pair_guard sits before deploy_gate_require on deploys). Maps
            # the rollback environment to a coupled tier; a no-op for unpaired
            # sites / uncoupled tiers. The backup's identity anchor comes from the
            # entry (identity_anchor) or NWP_RESTORE_ANCHOR; unknown ⇒ fail-closed.
            local _pg_tier="$environment"
            [ "$_pg_tier" = "stage" ] && _pg_tier="stg"
            local _pg_anchor _pg_override
            _pg_anchor=$(grep -m1 '"identity_anchor"' "$entry_file" 2>/dev/null | sed 's/.*: *"\{0,1\}\([0-9]*\)"\{0,1\}.*/\1/' || true)
            [ -z "$_pg_anchor" ] && _pg_anchor="${NWP_RESTORE_ANCHOR:-}"
            _pg_override="${PL_OVERRIDE_PAIR:-false}"
            if command -v pair_guard_restore >/dev/null 2>&1; then
                pair_guard_restore "$sitename" "$_pg_tier" "rollback" "$_pg_anchor" "$_pg_override" || return 1
            fi
            deploy_gate_require "$sitename" "$environment" \
                "rollback: restore DBs + nginx on the production host" || return 1
        fi
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

        # ops#83: pass the TIER through. Without it restore.sh falls back to its
        # `TIER=dev` default (scripts/commands/restore.sh), so pair_guard_restore
        # evaluates an UNCOUPLED tier and no-ops — the gate is called, asks the
        # wrong question, and answers "fine". A guard defeated by an unset
        # argument is not a guard. The entry's identity_anchor goes with it, for
        # the same reason: fail-closed needs the real inputs, not defaults.
        local _rb_tier="$environment"
        [ "$_rb_tier" = "stage" ] && _rb_tier="stg"
        local _rb_anchor
        _rb_anchor=$(grep -m1 '"identity_anchor"' "${ROLLBACK_DIR}/${sitename}_${environment}.json" 2>/dev/null \
            | sed 's/.*: *"\{0,1\}\([0-9]*\)"\{0,1\}.*/\1/' || true)
        [ -z "$_rb_anchor" ] && _rb_anchor="${NWP_RESTORE_ANCHOR:-}"
        restore_opts="$restore_opts --tier $_rb_tier"
        [ -n "$_rb_anchor" ] && restore_opts="$restore_opts --anchor $_rb_anchor"
        [ "${PL_OVERRIDE_PAIR:-false}" = "true" ] && restore_opts="$restore_opts --override-pair"
        [ -n "${PL_PAIRED_RESTORE_ACK:-}" ] && restore_opts="$restore_opts --paired-restore-ack ${PL_PAIRED_RESTORE_ACK}"

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
    # Empty means "let rollback_execute pick the tier that actually has points".
    # Do NOT default to prod — no site in this fleet has a prod tier.
    local environment="${2:-}"
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
