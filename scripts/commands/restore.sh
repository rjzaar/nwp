#!/bin/bash
set -euo pipefail

################################################################################
# NWP Restore Script
#
# Restores DDEV sites from backups created by backup.sh
# Based on pleasy restore.sh adapted for DDEV environments
#
# Usage: ./restore.sh [FROM] [TO] [OPTIONS]
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
# ops#83: both-or-forward RESTORE choke-point (no-op for unpaired sites / uncoupled
# tiers; the default --tier=dev restore is never gated). pair.sh is not
# auto-sourced by common.sh, so pull it in explicitly.
source "$PROJECT_ROOT/lib/pair.sh"

# Script start time
START_TIME=$(date +%s)

################################################################################
# Script-specific Functions
################################################################################

# Ask yes/no with AUTO_YES support (script-specific override)
ask_yes_no() {
    local prompt=$1
    local default=${2:-n}

    if [ "$AUTO_YES" == "true" ]; then
        echo "Auto-confirmed: $prompt"
        return 0
    fi

    if [ "$default" == "y" ]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi

    read -p "$prompt" response
    response=${response:-$default}

    if [[ "$response" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

should_run_step() {
    local step_num=$1
    local start_step=${2:-1}

    if [ "$step_num" -ge "$start_step" ]; then
        return 0
    else
        return 1
    fi
}

show_help() {
    cat << EOF
${BOLD}NWP Restore Script${NC}

${BOLD}USAGE:${NC}
    ./restore.sh [OPTIONS] <from> [to]

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -b, --db-only           Database-only restore (skip files)
    -s, --step=N            Resume from step N
    -f, --first             Use latest backup without prompting
    -y, --yes               Auto-confirm deletion of existing content
    -o, --open              Generate login link after restoration
    -t, --tier=T            Tier being restored (dev|stg|live|prod; default dev).
                            A coupled tier (live/prod on an identity-paired site)
                            is gated by the ops#83 both-or-forward restore rule.
        --anchor=N          Identity anchor of the backup (ops#83; for coupled tiers)
        --override-pair     Ledgered escape past the ops#83 restore gate (typed)
        --remote            Restore a verified DR artifact back ONTO the live
                            host — the inverse of \`pl backup <site> --remote\`.
                            DRY RUN by default; --execute is required to write.
                            Sub-options: --artifact=<name>, --db-only,
                            --files-only, --tier=<t>, --execute.
        --skip-verify       Skip the pre-restore integrity check of the backup
                            artifact's .sha256 sidecar/manifest (NOT recommended;
                            off by default). When a sidecar IS present a mismatch
                            aborts; a sidecar-less legacy/local backup is allowed
                            through with a notice regardless of this flag.

${BOLD}ARGUMENTS:${NC}
    from                    Source site name (backup to restore from)
    to                      Destination site name (optional, defaults to 'from')

${BOLD}EXAMPLES:${NC}
    ./restore.sh nwp                         # Restore nwp from latest backup (full)
    ./restore.sh -b nwp                      # Database-only restore
    ./restore.sh nwp nwp2                    # Restore nwp backup to nwp2 site
    ./restore.sh -b nwp nwp2                 # Database-only restore to different site
    ./restore.sh -fy nwp                     # Auto-select latest + auto-confirm
    ./restore.sh -bfyo nwp                   # DB-only + auto-select + confirm + open
    ./restore.sh -s=5 nwp                    # Resume from step 5

${BOLD}COMBINED FLAGS:${NC}
    Multiple short flags can be combined: -bfyo = -b -f -y -o
    Example: ./restore.sh -bfyo nwp is the same as ./restore.sh -b -f -y -o nwp

${BOLD}RESTORATION STEPS:${NC}
    Full restore:
      1. Select backup
      2. Validate destination
      3. Extract files
      4. Fix settings
      5. Set permissions
      6. Restore database
      7. Clear cache
      8. Generate login link (if -o)

    Database-only restore (-b):
      1. Select backup
      2. Confirm restoration
      3. Restore database
      4. Clear cache
      5. Generate login link (if -o)

${BOLD}BACKUP LOCATION:${NC}
    Backups are read from: sites/<sitename>/backups/
    (Legacy location sitebackups/<sitename>/ is still honored for unmigrated sites.)

EOF
}

################################################################################
# Backup Selection Functions
################################################################################

list_backups() {
    local sitename=$1
    # F23 Phase 4: prefer sites/<name>/backups/, fall back to legacy sitebackups/<name>/
    local backup_dir
    backup_dir=$(get_backup_dir "$sitename")

    if [ ! -d "$backup_dir" ]; then
        return 1
    fi

    # List SQL files (sorted by date, newest first) - supports both .sql.gz and .sql
    find "$backup_dir" \( -name "*.sql.gz" -o -name "*.sql" \) -type f | sort -r
}

select_backup() {
    local sitename=$1
    local use_first=${2:-false}

    # F23 Phase 4: prefer sites/<name>/backups/, fall back to legacy sitebackups/<name>/
    local backup_dir
    backup_dir=$(get_backup_dir "$sitename")

    if [ ! -d "$backup_dir" ]; then
        print_error "No backups found for site: $sitename"
        echo "INFO: Backup directory does not exist: $backup_dir" >&2
        return 1
    fi

    # Get list of backups
    local backups=($(list_backups "$sitename"))

    if [ ${#backups[@]} -eq 0 ]; then
        print_error "No backups found in: $backup_dir"
        return 1
    fi

    # If --first flag, use latest backup
    if [ "$use_first" == "true" ]; then
        echo "${backups[0]}"
        return 0
    fi

    # Interactive selection
    print_header "Available Backups for $sitename"

    echo -e "${BOLD}Found ${#backups[@]} backup(s):${NC}\n"

    local i=1
    for backup in "${backups[@]}"; do
        local basename=$(basename "$backup" .sql.gz)
        basename=$(basename "$basename" .sql)
        local size_sql=$(du -h "$backup" 2>/dev/null | cut -f1)
        local tar_base="${backup%.sql.gz}"
        tar_base="${tar_base%.sql}"
        local tar_file="${tar_base}.tar.gz"
        local size_tar="N/A"
        if [ -f "$tar_file" ]; then
            size_tar=$(du -h "$tar_file" 2>/dev/null | cut -f1)
        fi

        echo -e "${BLUE}$i)${NC} $basename"
        echo -e "   DB: $size_sql | Files: $size_tar"
        echo ""
        ((i++))
    done

    echo -n "Select backup number [1]: "
    read selection
    selection=${selection:-1}

    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#backups[@]} ]; then
        print_error "Invalid selection"
        return 1
    fi

    local selected_backup="${backups[$((selection-1))]}"
    echo "$selected_backup"
    return 0
}

################################################################################
# Integrity Verification (report P2 gap)
#
# Remote-pull backups carry a `.sha256` sidecar next to every artifact (format:
# "<sha>  <basename>", so `sha256sum -c` validates it) and, for the whole set, a
# "<backup_name>.manifest.json" provenance file. Restore is destructive (it
# deletes/overwrites the destination), so when a sidecar IS present we FAIL-CLOSED:
# a mismatch/corruption aborts the restore before anything is touched.
# Legacy/local backups (local `pl backup`, the automated sweep) have no sidecar;
# those are allowed through with a notice — otherwise every local rollback breaks.
# --skip-verify (off by default) is the explicit, loud escape hatch.
################################################################################

# Set true after a successful up-front verification so the per-step guards in
# restore_files/restore_database don't re-print on the normal path.
INTEGRITY_VERIFIED=false

# Lightweight sanity-check of a manifest.json: it must exist, be non-empty, and
# parse as JSON (jq/python3 if available, else a structural smell test).
verify_backup_manifest() {
    local manifest=$1

    [ -s "$manifest" ] || return 1

    if command -v jq >/dev/null 2>&1; then
        jq -e . "$manifest" >/dev/null 2>&1 || return 1
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$manifest" >/dev/null 2>&1 || return 1
    else
        # No JSON parser available — structural smell test only.
        local first last
        first=$(head -c1 "$manifest" 2>/dev/null)
        last=$(tr -d '[:space:]' < "$manifest" 2>/dev/null | tail -c1)
        [ "$first" = "{" ] && [ "$last" = "}" ] || return 1
    fi

    return 0
}

# Verify one artifact's integrity before it is extracted/imported.
#
# Verification is opportunistic-but-fail-closed: it only applies when a `.sha256`
# sidecar EXISTS next to the artifact (as written by the remote-pull path). If a
# sidecar is present, a mismatch/corruption ABORTS the restore (keeps the
# tamper-detection property). If NO sidecar exists — legacy/local backups from
# `pl backup` (backup_database/backup_files) and the automated sweep never write
# one — there is nothing to verify against, so we proceed with a clear notice
# rather than fail-closed (otherwise every legacy local rollback would break).
#
# Returns 0 if the artifact is trustworthy, sidecar-less, or explicitly skipped;
# returns 1 (fail-closed) only on a present-but-mismatched sidecar / corrupt
# manifest so the caller aborts the restore.
verify_backup_artifact() {
    local artifact=$1

    if [ "${SKIP_VERIFY:-false}" == "true" ]; then
        print_status "WARN" "Integrity verification SKIPPED (--skip-verify): $(basename "$artifact")"
        return 0
    fi

    if [ ! -f "$artifact" ]; then
        print_error "Cannot verify integrity — artifact not found: $artifact"
        return 1
    fi

    local sidecar="${artifact}.sha256"
    if [ ! -f "$sidecar" ]; then
        # Legacy/local backup with no sidecar (local `pl backup`, automated
        # sweep). Nothing to verify against — proceed with a notice, do NOT abort.
        print_status "INFO" "No integrity sidecar for $(basename "$artifact") — skipping verification (legacy/local backup)."
        return 0
    fi

    # `sha256sum -c` resolves the filename recorded in the sidecar relative to
    # the current directory, so run it from the artifact's own directory.
    local art_dir art_base
    art_dir=$(cd "$(dirname "$artifact")" && pwd) || {
        print_error "Cannot access backup directory for: $artifact"
        return 1
    }
    art_base=$(basename "$artifact")
    if ( cd "$art_dir" && sha256sum -c "${art_base}.sha256" >/dev/null 2>&1 ); then
        print_status "OK" "Integrity verified: ${art_base}"
    else
        print_error "Integrity check FAILED (sha256 mismatch): ${art_base}"
        print_error "Backup is corrupt or has been tampered with — aborting restore."
        return 1
    fi

    # Optional manifest sanity-check for the whole backup set.
    local backup_name="$art_base"
    backup_name="${backup_name%.sql.gz}"
    backup_name="${backup_name%.sql}"
    backup_name="${backup_name%.tar.gz}"
    local manifest="${art_dir}/${backup_name}.manifest.json"
    if [ -f "$manifest" ]; then
        if verify_backup_manifest "$manifest"; then
            print_status "OK" "Manifest sane: $(basename "$manifest")"
        else
            print_error "Backup manifest failed sanity-check (not valid JSON): $(basename "$manifest")"
            print_error "Backup provenance is unreadable — aborting restore."
            return 1
        fi
    fi

    return 0
}

# Verify every artifact a restore is about to consume, up front, before any
# destructive step. For a DB-only restore that's just the .sql[.gz]; for a full
# restore it's the .sql[.gz] plus the .tar.gz files archive if present.
verify_backup_set() {
    local db_backup=$1
    local db_only=${2:-false}

    if ! verify_backup_artifact "$db_backup"; then
        return 1
    fi

    if [ "$db_only" != "true" ]; then
        local tar_base="${db_backup%.sql.gz}"
        tar_base="${tar_base%.sql}"
        local tar_file="${tar_base}.tar.gz"
        if [ -f "$tar_file" ]; then
            if ! verify_backup_artifact "$tar_file"; then
                return 1
            fi
        fi
    fi

    INTEGRITY_VERIFIED=true
    return 0
}

################################################################################
# Restore Functions
################################################################################

restore_files() {
    local backup_file=$1
    local dest_site=$2
    local webroot=$3

    print_header "Step 3: Restore Files"

    local tar_base="${backup_file%.sql.gz}"
    tar_base="${tar_base%.sql}"
    local tar_file="${tar_base}.tar.gz"

    if [ ! -f "$tar_file" ]; then
        print_error "Files backup not found: $tar_file"
        return 1
    fi

    # Fail-closed integrity gate for resume (--step) runs where the up-front
    # step-1 verification was skipped. No-op if already verified.
    if [ "${INTEGRITY_VERIFIED:-false}" != "true" ]; then
        if ! verify_backup_artifact "$tar_file"; then
            print_error "Refusing to extract an unverified files archive."
            return 1
        fi
    fi

    local dest_dir="sites/$dest_site"

    ocmsg "Extracting files from: $tar_file"
    ocmsg "Destination: $dest_dir"

    # Extract tar.gz to destination
    if tar -xzf "$tar_file" -C "$dest_dir" 2>/dev/null; then
        print_status "OK" "Files extracted successfully"
        return 0
    else
        print_error "Failed to extract files"
        return 1
    fi
}

restore_database() {
    local backup_file=$1
    local dest_site=$2

    print_header "Step 7: Restore Database"

    if [ ! -f "$backup_file" ]; then
        print_error "Database backup not found: $backup_file"
        return 1
    fi

    # Fail-closed integrity gate for resume (--step) runs where the up-front
    # step-1 verification was skipped. No-op if already verified.
    if [ "${INTEGRITY_VERIFIED:-false}" != "true" ]; then
        if ! verify_backup_artifact "$backup_file"; then
            print_error "Refusing to import an unverified database backup."
            return 1
        fi
    fi

    ocmsg "Importing database from: $backup_file"

    # Get absolute path to backup file
    local abs_backup=$(cd "$(dirname "$backup_file")" && pwd)/$(basename "$backup_file")

    local dest_dir="sites/$dest_site"

    # Change to destination site directory
    local original_dir=$(pwd)
    cd "$dest_dir" || {
        print_error "Cannot access site directory: $dest_dir"
        return 1
    }

    # Ensure .ddev directory exists
    mkdir -p .ddev

    # Copy backup to .ddev directory for import
    local temp_ext="sql"
    [[ "$abs_backup" == *.gz ]] && temp_ext="sql.gz"
    local temp_db=".ddev/import.${temp_ext}"
    cp "$abs_backup" "$temp_db"

    # Import database using DDEV (supports both .sql and .sql.gz)
    start_spinner "Importing database..."
    if ddev import-db --file="$temp_db" > /dev/null 2>&1; then
        stop_spinner
        rm -f "$temp_db"
        print_status "OK" "Database restored successfully"
        cd "$original_dir"
        return 0
    else
        stop_spinner
        rm -f "$temp_db"
        print_error "Failed to import database"
        cd "$original_dir"
        return 1
    fi
}

fix_site_settings() {
    local dest_site=$1
    local webroot=$2

    print_header "Step 5: Fix Site Settings"

    local dest_dir="sites/$dest_site"
    local settings_file="$dest_dir/$webroot/sites/default/settings.php"

    if [ ! -f "$settings_file" ]; then
        print_status "WARN" "No settings.php found, DDEV will handle configuration"
        return 0
    fi

    ocmsg "Settings file: $settings_file"

    # DDEV handles database settings automatically, so we just ensure file exists
    print_status "OK" "Settings verified (DDEV managed)"

    return 0
}

set_permissions() {
    local dest_site=$1
    local webroot=$2

    print_header "Step 6: Set Permissions"

    local dest_dir="sites/$dest_site"

    # Ensure sites/default is writable
    if [ -d "$dest_dir/$webroot/sites/default" ]; then
        chmod u+w "$dest_dir/$webroot/sites/default"
        ocmsg "Set sites/default writable"
    fi

    # Ensure settings.php is writable
    if [ -f "$dest_dir/$webroot/sites/default/settings.php" ]; then
        chmod u+w "$dest_dir/$webroot/sites/default/settings.php"
        ocmsg "Set settings.php writable"
    fi

    print_status "OK" "Permissions set"

    return 0
}

install_dependencies() {
    local dest_site=$1

    print_header "Step 4: Install Dependencies"

    local dest_dir="sites/$dest_site"
    local original_dir=$(pwd)
    cd "$dest_dir" || {
        print_error "Cannot access site directory: $dest_dir"
        return 1
    }

    # Install composer dependencies to rebuild vendor/
    ocmsg "Running composer install to rebuild vendor directory..."
    if ddev composer install --no-interaction > /dev/null 2>&1; then
        print_status "OK" "Dependencies installed"
    else
        print_status "WARN" "Could not install dependencies (may need manual intervention)"
    fi

    cd "$original_dir"
    return 0
}

clear_cache() {
    local dest_site=$1

    print_header "Step 8: Clear Cache"

    local dest_dir="sites/$dest_site"
    local original_dir=$(pwd)
    cd "$dest_dir" || {
        print_error "Cannot access site directory: $dest_dir"
        return 1
    }

    # Try to clear cache and capture error
    local error_msg=$(ddev drush cr 2>&1)
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        print_status "OK" "Cache cleared"
    else
        # Provide specific error message based on the failure
        if echo "$error_msg" | grep -q "command not found\|drush: not found"; then
            print_status "WARN" "Drush not installed - run 'ddev composer require drush/drush'"
        elif echo "$error_msg" | grep -q "could not find driver\|database"; then
            print_status "WARN" "Database not configured or not accessible"
        elif echo "$error_msg" | grep -q "Bootstrap failed\|not a Drupal"; then
            print_status "WARN" "Site not fully configured (not a Drupal installation)"
        else
            print_status "WARN" "Could not clear cache: ${error_msg:0:60}"
        fi
    fi

    cd "$original_dir"
    return 0
}

generate_login_link() {
    local dest_site=$1

    print_header "Step 9: Generate Login Link"

    local dest_dir="sites/$dest_site"
    local original_dir=$(pwd)
    cd "$dest_dir" || {
        print_error "Cannot access site directory: $dest_dir"
        return 1
    }

    # Generate one-time login URL
    local login_url=$(ddev drush uli 2>/dev/null | tail -1)

    if [ -n "$login_url" ]; then
        print_status "OK" "Login link generated"
        echo -e "\n${GREEN}${BOLD}Login URL:${NC} $login_url\n"

        # Try to open in browser
        if command -v xdg-open &> /dev/null; then
            xdg-open "$login_url" &>/dev/null &
        elif command -v open &> /dev/null; then
            open "$login_url" &>/dev/null &
        fi
    else
        print_status "WARN" "Could not generate login link"
    fi

    cd "$original_dir"
    return 0
}

################################################################################
# Main Restore Function
################################################################################

restore_site() {
    local from_site=$1
    local to_site=$2
    local use_first=$3
    local start_step=${4:-1}
    local open_after=${5:-false}
    local db_only=${6:-false}
    local tier=${7:-dev}
    local anchor=${8:-}
    local override_pair=${9:-false}
    local paired_ack=${11:-}
    # SKIP_VERIFY is read by verify_backup_artifact; keep it script-scoped (not
    # local) so the verification helpers see it.
    SKIP_VERIFY=${10:-false}

    # Clean up spinner on exit/error
    trap 'stop_spinner' EXIT INT TERM

    if [ "$db_only" == "true" ]; then
        print_header "NWP Database Restore: $from_site → $to_site"
    else
        print_header "NWP Site Restore: $from_site → $to_site"
    fi

    # ops#83: both-or-forward RESTORE gate — refuse a coupled-tier restore that
    # would move one paired member behind the other's identity anchor (orphaning
    # UID-locks) unless a typed, ledgered --override-pair is given. No-op for
    # unpaired sites and uncoupled tiers (the default dev restore). ⚠ A real
    # live/prod restore remains ver/Solo-gated (per the operator threat model); this is the logic gate.
    # code_only is hard-false here: every path below loads a DB (full or --db-only).
    if command -v pair_guard_restore >/dev/null 2>&1; then
        if ! pair_guard_restore "$to_site" "$tier" "restore" "$anchor" "$override_pair" "" false "$paired_ack"; then
            print_error "Restore refused by the ops#83 pair restore gate (see above)."
            return 1
        fi
    fi

    # Step 1: Select backup
    if should_run_step 1 "$start_step"; then
        print_header "Step 1: Select Backup"

        local selected_backup=$(select_backup "$from_site" "$use_first")
        if [ $? -ne 0 ] || [ -z "$selected_backup" ]; then
            print_error "No backup selected"
            return 1
        fi

        BACKUP_FILE="$selected_backup"
        local display_name=$(basename "$BACKUP_FILE" .sql.gz)
        display_name=$(basename "$display_name" .sql)
        print_info "Selected backup: ${BOLD}${display_name}${NC}"

        # Report P2 gap: verify integrity BEFORE anything destructive happens
        # (step 2 deletes the destination for a full restore). Fail-closed.
        print_header "Verify Backup Integrity"
        if ! verify_backup_set "$BACKUP_FILE" "$db_only"; then
            print_error "Backup integrity verification failed — nothing was restored."
            return 1
        fi
    else
        print_status "INFO" "Skipping Step 1: Using existing backup selection"
    fi

    # Step 2: Validate destination
    if should_run_step 2 "$start_step"; then
        print_header "Step 2: Validate Destination"

        local dest_dir="sites/$to_site"

        if [ "$db_only" == "true" ]; then
            # Database-only: destination must exist
            if [ ! -d "$dest_dir" ]; then
                print_error "Destination site not found: $dest_dir"
                print_info "Destination must already exist for database-only restore"
                return 1
            fi

            if [ ! -f "$dest_dir/.ddev/config.yaml" ]; then
                print_error "Destination is not a DDEV site: $dest_dir"
                print_info "Run 'ddev config' in the destination directory first"
                return 1
            fi

            if ! ask_yes_no "Replace database in $to_site with backup from $from_site?" "n"; then
                print_error "Restoration cancelled"
                return 1
            fi

            print_status "OK" "Destination validated: $dest_dir"
        else
            # Full restore: delete and recreate destination
            if [ -d "$dest_dir" ]; then
                print_status "WARN" "Destination site already exists: $dest_dir"

                if ! ask_yes_no "Delete existing site and restore from backup?" "n"; then
                    print_error "Restoration cancelled"
                    return 1
                fi

                # Validate before destructive operation
                if ! validate_sitename "$to_site" "destination site"; then
                    return 1
                fi

                # Stop DDEV if running
                ocmsg "Stopping DDEV for $to_site"
                cd "$dest_dir" && ddev stop > /dev/null 2>&1
                cd - > /dev/null

                # Remove existing site
                ocmsg "Removing existing site: $dest_dir"
                rm -rf "$dest_dir"
                print_status "OK" "Existing site removed"
            fi

            # Create destination directory
            mkdir -p "$dest_dir"
            print_status "OK" "Destination prepared: $dest_dir"
        fi
    else
        print_status "INFO" "Skipping Step 2: Destination already prepared"
    fi

    # Get webroot (skip for database-only)
    local webroot="html"
    if [ "$db_only" != "true" ]; then
        # Try to detect from backup archive
        local tar_base="${BACKUP_FILE%.sql.gz}"
        tar_base="${tar_base%.sql}"
        local tar_file="${tar_base}.tar.gz"
        if [ -f "$tar_file" ]; then
            if tar -tzf "$tar_file" | grep -q "^web/" 2>/dev/null; then
                webroot="web"
            fi
        fi
        ocmsg "Using webroot: $webroot"
    fi

    # Step 3: Restore files (skip for database-only)
    if [ "$db_only" != "true" ]; then
        if should_run_step 3 "$start_step"; then
            if ! restore_files "$BACKUP_FILE" "$to_site" "$webroot"; then
                print_error "File restoration failed"
                return 1
            fi
        else
            print_status "INFO" "Skipping Step 3: Files already restored"
        fi
    fi

    # Step 4: Install dependencies (skip for database-only)
    if [ "$db_only" != "true" ]; then
        if should_run_step 4 "$start_step"; then
            install_dependencies "$to_site"
        else
            print_status "INFO" "Skipping Step 4: Dependencies already installed"
        fi
    fi

    # Step 5: Fix settings (skip for database-only)
    if [ "$db_only" != "true" ]; then
        if should_run_step 5 "$start_step"; then
            fix_site_settings "$to_site" "$webroot"
        else
            print_status "INFO" "Skipping Step 5: Settings already fixed"
        fi
    fi

    # Step 6: Set permissions (skip for database-only)
    if [ "$db_only" != "true" ]; then
        if should_run_step 6 "$start_step"; then
            set_permissions "$to_site" "$webroot"
        else
            print_status "INFO" "Skipping Step 6: Permissions already set"
        fi
    fi

    # Configure and start DDEV if not already running (skip for database-only, already validated)
    local dest_dir="sites/$to_site"
    if [ "$db_only" != "true" ] && [ ! -f "$dest_dir/.ddev/config.yaml" ]; then
        print_info "Configuring DDEV for $to_site"
        cd "$dest_dir" || return 1

        # Get project name from directory (convert underscores to hyphens for valid hostname)
        local project_name=$(basename "$to_site" | tr '_' '-')

        ddev config --project-name="$project_name" --project-type=drupal --docroot="$webroot" --php-version="8.2" --database="mariadb:10.11" > /dev/null 2>&1
        ddev start > /dev/null 2>&1

        cd - > /dev/null
        print_status "OK" "DDEV configured and started"
    fi

    # Step 7: Restore database
    if should_run_step 7 "$start_step"; then
        if ! restore_database "$BACKUP_FILE" "$to_site"; then
            print_error "Database restoration failed"
            return 1
        fi
    else
        print_status "INFO" "Skipping Step 7: Database already restored"
    fi

    # Step 8: Clear cache
    if should_run_step 8 "$start_step"; then
        clear_cache "$to_site"
    else
        print_status "INFO" "Skipping Step 8: Cache already cleared"
    fi

    # Step 9: Generate login link (if requested)
    if [ "$open_after" == "true" ]; then
        if should_run_step 9 "$start_step"; then
            generate_login_link "$to_site"
        fi
    fi

    # Summary
    print_header "Restore Summary"
    echo -e "${GREEN}✓${NC} Source: $from_site"
    echo -e "${GREEN}✓${NC} Destination: $to_site"
    local restore_display=$(basename "$BACKUP_FILE" .sql.gz)
    restore_display=$(basename "$restore_display" .sql)
    echo -e "${GREEN}✓${NC} Backup: $restore_display"
    echo ""
    echo -e "${BOLD}Site URL:${NC}"
    local dest_dir="sites/$to_site"
    cd "$dest_dir" && ddev describe 2>/dev/null | grep "^https://" && cd - > /dev/null

    return 0
}

################################################################################
# Main Script
################################################################################

main() {
    local DEBUG=false
    local DB_ONLY=false
    local USE_FIRST=false
    local AUTO_YES=false
    local OPEN_AFTER=false
    local START_STEP=1
    local FROM_SITE=""
    local TO_SITE=""
    local TIER=dev
    local ANCHOR=""
    local OVERRIDE_PAIR=false
    local SKIP_VERIFY=false
    local PAIRED_ACK=""
    # NOTE: `pl restore` deliberately has NO --code-only flag. Every path in this
    # verb loads a database (a full restore, or --db-only), so the flag could only
    # ever silence the pair gate without changing what the restore does — a side
    # door wearing the name of a safety property. code_only is DERIVED from the
    # operation, never asserted by the operator: it is `true` only where the code
    # genuinely skips the DB (see lib/restore-remote.sh's files-only path).

    # --remote turns this into the inverse of `pl backup <site> --remote`:
    # push a verified local DR artifact back ONTO the live host. Handled by
    # lib/restore-remote.sh, which is dry-run by default and gated exactly like
    # a deploy. Parsed ahead of getopt because it changes which verb runs.
    local REMOTE=false REMOTE_ARGS=()
    local _a
    for _a in "$@"; do
        [ "$_a" = "--remote" ] && REMOTE=true
    done
    if [ "$REMOTE" = "true" ]; then
        for _a in "$@"; do
            [ "$_a" = "--remote" ] && continue
            REMOTE_ARGS+=("$_a")
        done
        source "$PROJECT_ROOT/lib/deploy-gate.sh"
        source "$PROJECT_ROOT/lib/ssh.sh"
        source "$PROJECT_ROOT/lib/rollback.sh"
        source "$PROJECT_ROOT/lib/moodle-deploy.sh"
        source "$PROJECT_ROOT/lib/restore-remote.sh"
        restore_remote_main "${REMOTE_ARGS[@]}"
        exit $?
    fi

    # Parse options
    local OPTIONS=hdbfyos:t:
    local LONGOPTS=help,debug,db-only,first,yes,open,step:,tier:,anchor:,override-pair,skip-verify,paired-restore-ack:,code-only

    if ! PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTS --name "$0" -- "$@"); then
        show_help
        exit 1
    fi

    eval set -- "$PARSED"

    while true; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -d|--debug)
                DEBUG=true
                shift
                ;;
            -b|--db-only)
                DB_ONLY=true
                shift
                ;;
            -f|--first)
                USE_FIRST=true
                shift
                ;;
            -y|--yes)
                AUTO_YES=true
                shift
                ;;
            -o|--open)
                OPEN_AFTER=true
                shift
                ;;
            -s|--step)
                START_STEP="$2"
                shift 2
                ;;
            -t|--tier)
                TIER="$2"
                shift 2
                ;;
            --anchor)
                ANCHOR="$2"
                shift 2
                ;;
            --override-pair)
                OVERRIDE_PAIR=true
                shift
                ;;
            --skip-verify)
                SKIP_VERIFY=true
                shift
                ;;
            --paired-restore-ack)
                PAIRED_ACK="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                echo "Programming error"
                exit 3
                ;;
        esac
    done

    # Get from/to sites
    if [ $# -ge 1 ]; then
        FROM_SITE="$1"
        shift
    else
        print_error "No source site specified"
        echo ""
        show_help
        exit 1
    fi

    # Default TO to FROM if not specified
    if [ $# -ge 1 ]; then
        TO_SITE="$1"
    else
        TO_SITE="$FROM_SITE"
    fi

    ocmsg "From: $FROM_SITE"
    ocmsg "To: $TO_SITE"
    ocmsg "Use first: $USE_FIRST"
    ocmsg "Auto yes: $AUTO_YES"
    ocmsg "Open after: $OPEN_AFTER"
    ocmsg "Database-only: $DB_ONLY"
    ocmsg "Start step: $START_STEP"
    ocmsg "Tier: $TIER"
    ocmsg "Skip verify: $SKIP_VERIFY"

    # Run restore
    if restore_site "$FROM_SITE" "$TO_SITE" "$USE_FIRST" "$START_STEP" "$OPEN_AFTER" "$DB_ONLY" "$TIER" "$ANCHOR" "$OVERRIDE_PAIR" "$SKIP_VERIFY"; then
        show_elapsed_time "Restore"
        exit 0
    else
        print_error "Restore failed: $FROM_SITE → $TO_SITE"
        exit 1
    fi
}

# Run main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
