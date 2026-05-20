#!/bin/bash
################################################################################
# NWP Remote Rollback Library
#
# Bridges the gap between:
#   - `pl stg2live`'s on-live-host snapshot mechanism (mysqldump +
#     nginx tarball saved to ~ on the remote)
#   - `pl rollback list/execute`'s registry (originally local-DDEV only)
#
# Each remote snapshot writes a JSON entry to ${ROLLBACK_DIR}/. The
# entries are timestamped, so multiple snapshots accumulate as history.
# `rollback_list` and `rollback_execute` (in lib/rollback.sh) read these
# entries; this file adds the "type=remote" code paths.
#
# Source AFTER lib/rollback.sh. Depends on lib/ui.sh, lib/common.sh.
################################################################################

# Filename pattern for remote entries:
#   <sitename>_<env>_<YYYYMMDD-HHMMSS>.json
# This keeps history (existing scheme overwrote on each deploy) and lets
# rollback_cleanup prune old ones by sorted timestamp.

# Record a remote snapshot as a rollback point.
# Usage:
#   rollback_record_remote <sitename> <env> <ssh_user> <server_ip> \
#       <ts:YYYYMMDD-HHMMSS> <dbs_remote_path> <nginx_remote_path> [<commit_sha>]
rollback_record_remote() {
    local sitename="$1"
    local environment="$2"
    local ssh_user="$3"
    local server_ip="$4"
    local ts="$5"
    local dbs_path="$6"
    local nginx_path="$7"
    local commit_sha="${8:-}"

    rollback_init

    local entry_file="${ROLLBACK_DIR}/${sitename}_${environment}_${ts}.json"
    local iso_ts
    # Convert YYYYMMDD-HHMMSS -> YYYY-MM-DDTHH:MM:SS+ZZ for the JSON `timestamp` field
    iso_ts=$(rollback_remote_iso "$ts")

    cat > "$entry_file" << EOF
{
    "sitename": "${sitename}",
    "environment": "${environment}",
    "timestamp": "${iso_ts}",
    "type": "remote",
    "remote": {
        "host": "${server_ip}",
        "ssh_user": "${ssh_user}",
        "snapshot_dbs": "${dbs_path}",
        "snapshot_nginx": "${nginx_path}"
    },
    "commit": "${commit_sha}",
    "status": "active"
}
EOF

    print_status "OK" "Rollback point registered: ${sitename}@${environment} (remote, ${ts})"
    return 0
}

# Convert YYYYMMDD-HHMMSS -> ISO-8601 with local TZ.
rollback_remote_iso() {
    local raw="$1"  # e.g. 20260520-132046
    local d="${raw%%-*}"
    local t="${raw##*-}"
    # YYYYMMDD -> YYYY-MM-DD; HHMMSS -> HH:MM:SS
    local d_iso="${d:0:4}-${d:4:2}-${d:6:2}"
    local t_iso="${t:0:2}:${t:2:2}:${t:4:2}"
    # Use the local TZ offset (matches what `date -Iseconds` would do).
    local tz_off
    tz_off=$(date +%z)
    # %z is +HHMM; ISO wants +HH:MM
    tz_off="${tz_off:0:3}:${tz_off:3:2}"
    echo "${d_iso}T${t_iso}${tz_off}"
}

# Backfill registry entries from existing on-live snapshots that pre-date
# this fix. Discovers files matching nwp-snapshot-<site>-dbs-*.sql.gz on
# the remote and writes one registry entry per. Safe to run repeatedly.
#
# Usage: rollback_backfill_remote <sitename> [<ssh_user>] [<server_ip>]
# If user/host not given, resolves them from the site's .nwp.yml.
rollback_backfill_remote() {
    local sitename="$1"
    local ssh_user="${2:-}"
    local server_ip="${3:-}"

    # Auto-resolve from .nwp.yml if not given.
    if [ -z "$ssh_user" ] || [ -z "$server_ip" ]; then
        if command -v get_site_config_value >/dev/null 2>&1; then
            [ -z "$ssh_user" ] && ssh_user=$(get_site_config_value "$sitename" "live.ssh_user" 2>/dev/null || true)
            [ -z "$server_ip" ] && server_ip=$(get_site_config_value "$sitename" "live.server" 2>/dev/null || true)
        fi
        # Defaults.
        [ -z "$ssh_user" ] && ssh_user="gitlab"
        [ -z "$server_ip" ] && server_ip="git.nwpcode.org"
    fi

    print_header "Backfilling rollback registry from remote snapshots"
    print_info "Site: ${sitename}, SSH: ${ssh_user}@${server_ip}"

    # List snapshot pairs on the remote, sorted oldest -> newest.
    local listing
    listing=$(ssh -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "ls -1 ~/nwp-snapshot-${sitename}-dbs-*.sql.gz 2>/dev/null | sort" 2>/dev/null || true)

    if [ -z "$listing" ]; then
        print_info "No remote snapshots found for ${sitename}."
        return 0
    fi

    local count=0
    while IFS= read -r dbs_path; do
        [ -z "$dbs_path" ] && continue
        # Parse timestamp from the filename.
        local base ts nginx_path
        base=$(basename "$dbs_path")
        # Strip prefix and suffix to extract YYYYMMDD-HHMMSS.
        ts="${base#nwp-snapshot-${sitename}-dbs-}"
        ts="${ts%.sql.gz}"
        nginx_path=$(dirname "$dbs_path")"/nwp-snapshot-${sitename}-nginx-${ts}.tar.gz"

        # Verify nginx tar exists too (warn if not — DB-only restore is still possible).
        if ! ssh -o BatchMode=yes "${ssh_user}@${server_ip}" "test -f '$nginx_path'" 2>/dev/null; then
            print_status "WARN" "DB snapshot ${ts} has no matching nginx tar; registering DB-only."
            nginx_path=""
        fi

        # Skip if we already have an entry for this exact timestamp.
        if [ -f "${ROLLBACK_DIR}/${sitename}_prod_${ts}.json" ]; then
            continue
        fi

        rollback_record_remote "$sitename" "prod" "$ssh_user" "$server_ip" \
            "$ts" "$dbs_path" "$nginx_path" "(backfilled)"
        count=$((count + 1))
    done <<< "$listing"

    print_status "OK" "Backfilled ${count} entries for ${sitename}"
}

# Restore from a remote rollback point.
# Usage: rollback_execute_remote_from_entry <entry_file> [--dry-run]
rollback_execute_remote_from_entry() {
    local entry_file="$1"
    local dry_run="${2:-}"

    if [ ! -f "$entry_file" ]; then
        print_error "Rollback entry not found: $entry_file"
        return 1
    fi

    # Parse the entry — `|| true` keeps us alive under set -euo pipefail
    # when an entry is partial (e.g. DB-only snapshots have no nginx tar).
    local site env ts host user dbs nginx
    site=$(grep -m1 '"sitename"'        "$entry_file" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
    env=$(grep  -m1 '"environment"'     "$entry_file" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
    ts=$(grep   -m1 '"timestamp"'       "$entry_file" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
    host=$(grep -m1 '"host"'            "$entry_file" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
    user=$(grep -m1 '"ssh_user"'        "$entry_file" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
    dbs=$(grep  -m1 '"snapshot_dbs"'    "$entry_file" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
    nginx=$(grep -m1 '"snapshot_nginx"' "$entry_file" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || true)

    local sudo_prefix=""
    [ "$user" = "gitlab" ] && sudo_prefix="sudo "

    print_header "Remote Rollback: ${site}@${env}"
    print_info "  Snapshot timestamp: $ts"
    print_info "  Live host:          ${user}@${host}"
    print_info "  DB dump:            ${dbs}"
    print_info "  Nginx tar:          ${nginx:-(none — DB-only restore)}"

    # Verify the snapshot files still exist on the remote.
    if [ "$dry_run" != "--dry-run" ]; then
        if ! ssh -o BatchMode=yes "${user}@${host}" "test -f '${dbs}'" 2>/dev/null; then
            print_error "DB snapshot missing on remote: ${dbs}"
            print_error "(Was it pruned? Run `pl rollback list ${site}` to see other points.)"
            return 1
        fi
    fi

    # Build the commands so we can dry-run-print them or execute them.
    local restore_dbs_cmd="gunzip -c '${dbs}' | ${sudo_prefix}mysql"
    local restore_nginx_cmd=""
    if [ -n "$nginx" ]; then
        restore_nginx_cmd="${sudo_prefix}tar xzf '${nginx}' -C / && ${sudo_prefix}nginx -t && ${sudo_prefix}systemctl reload nginx"
    fi

    if [ "$dry_run" = "--dry-run" ]; then
        print_warning "DRY RUN — commands not executed."
        echo ""
        echo "  ssh ${user}@${host} \\"
        echo "    \"${restore_dbs_cmd}\""
        if [ -n "$restore_nginx_cmd" ]; then
            echo ""
            echo "  ssh ${user}@${host} \\"
            echo "    \"${restore_nginx_cmd}\""
        fi
        echo ""
        print_info "Re-run without --dry-run to execute. (You will be prompted before destructive steps.)"
        return 0
    fi

    # Real execution path: prompt operator before destruction.
    echo ""
    print_warning "ABOUT TO RESTORE THE LIVE DATABASE FROM SNAPSHOT ${ts}."
    print_warning "This will OVERWRITE current data on ${host} for site ${site}."
    read -rp "Type the snapshot timestamp (${ts}) to confirm: " confirm
    if [ "$confirm" != "$ts" ]; then
        print_error "Confirmation mismatch — aborting."
        return 1
    fi

    print_info "Restoring DB from ${dbs}..."
    if ssh -o BatchMode=yes "${user}@${host}" "${restore_dbs_cmd}"; then
        print_status "OK" "Database restored."
    else
        print_error "DB restore FAILED. Live state is now indeterminate. INVESTIGATE IMMEDIATELY."
        return 2
    fi

    if [ -n "$restore_nginx_cmd" ]; then
        print_info "Restoring nginx confs from ${nginx}..."
        if ssh -o BatchMode=yes "${user}@${host}" "${restore_nginx_cmd}"; then
            print_status "OK" "Nginx restored + validated + reloaded."
        else
            print_error "Nginx restore failed. Site may still be serving (old config in memory), but config-on-disk is now inconsistent."
            return 3
        fi
    fi

    # Mark entry as used.
    sed -i 's/"status": "active"/"status": "rolled_back"/' "$entry_file" 2>/dev/null || true
    print_status "OK" "Remote rollback complete: ${site}@${env} restored from ${ts}."
    return 0
}

# Resolve "execute" intent against the registry — picks the latest remote
# entry for a site/env unless an explicit timestamp is given.
# Usage: rollback_execute_remote <sitename> [<env>] [<timestamp>] [--dry-run]
rollback_execute_remote() {
    local sitename="$1"
    local environment="${2:-prod}"
    local explicit_ts="${3:-}"
    local dry_run="${4:-}"

    # Accept --dry-run as second-or-third arg too (operator convenience).
    if [ "$environment" = "--dry-run" ]; then
        dry_run="--dry-run"; environment="prod"; explicit_ts=""
    fi
    if [ "$explicit_ts" = "--dry-run" ]; then
        dry_run="--dry-run"; explicit_ts=""
    fi

    rollback_init

    local entry_file
    if [ -n "$explicit_ts" ]; then
        entry_file="${ROLLBACK_DIR}/${sitename}_${environment}_${explicit_ts}.json"
    else
        # Latest remote entry for site+env.
        # `|| true` keeps us alive under set -euo pipefail when no matches.
        entry_file=$(ls -1 "${ROLLBACK_DIR}/${sitename}_${environment}_"*.json 2>/dev/null \
            | xargs -I{} grep -l '"type": "remote"' {} 2>/dev/null \
            | sort | tail -1 || true)
    fi

    if [ -z "$entry_file" ] || [ ! -f "$entry_file" ]; then
        print_error "No remote rollback point found for ${sitename}@${environment}."
        print_info "Try: pl rollback list ${sitename}"
        return 1
    fi

    rollback_execute_remote_from_entry "$entry_file" "$dry_run"
}
