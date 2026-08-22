#!/bin/bash

################################################################################
# NWP Database Router Library
#
# Multi-source database download and management inspired by Vortex
# Source this file: source "$SCRIPT_DIR/lib/database-router.sh"
#
# Requires: lib/ui.sh, lib/state.sh, lib/sanitize.sh to be sourced first
################################################################################

# Database source types
DB_SOURCE_AUTO="auto"
DB_SOURCE_PRODUCTION="production"
DB_SOURCE_BACKUP="backup"
DB_SOURCE_DEVELOPMENT="development"
DB_SOURCE_URL="url"

################################################################################
# Helpers
################################################################################

# Normalise a site identifier to an absolute DDEV project directory.
# Accepts:
#   - absolute path to a v2 project dir (e.g. /home/.../sites/nwc/dev)
#   - name of a v1 flat site (e.g. "avc-dev" → sites/avc-dev/)
#   - name with v2 env suffix (e.g. "nwc-stg" → sites/nwc/stg/)
#
# Echoes the resolved absolute path; returns 0 on success, 1 if no
# directory could be found.
_db_router_resolve_dir() {
    local id="$1"
    local script_dir="${2:-${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}}"

    # Absolute path passed in.
    if [ -d "$id" ] && [ -f "$id/.ddev/config.yaml" ]; then
        (cd "$id" && pwd)
        return 0
    fi
    # v1 flat: sites/<id>/.ddev/
    if [ -d "$script_dir/sites/$id" ] && [ -f "$script_dir/sites/$id/.ddev/config.yaml" ]; then
        (cd "$script_dir/sites/$id" && pwd)
        return 0
    fi
    # v2 nested with env suffix: <tenant>-<env> → sites/<tenant>/<env>/
    if [[ "$id" =~ ^(.+)-(dev|stg|live|test)$ ]]; then
        local tenant="${BASH_REMATCH[1]}"
        local env="${BASH_REMATCH[2]}"
        if [ -f "$script_dir/sites/$tenant/$env/.ddev/config.yaml" ]; then
            (cd "$script_dir/sites/$tenant/$env" && pwd)
            return 0
        fi
    fi
    # v2 nested bare tenant name → default to dev/
    if [ -f "$script_dir/sites/$id/dev/.ddev/config.yaml" ]; then
        (cd "$script_dir/sites/$id/dev" && pwd)
        return 0
    fi
    return 1
}

################################################################################
# Main Router Function
################################################################################

# Download/restore database from various sources
# Usage: download_database "sitename" "source" ["target_site"]
#   source can be:
#     auto                  - Intelligent source selection
#     production            - Fresh from production server
#     backup:/path/to/file  - Specific backup file
#     development           - Clone from dev site
#     url:https://...       - Download from URL
#
# Returns: 0 on success, 1 on failure
download_database() {
    local sitename="$1"
    local source="$2"
    local target_site="${3:-$sitename}"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    case "$source" in
        auto|"")
            download_db_auto "$sitename" "$target_site"
            ;;
        production)
            download_db_production "$sitename" "$target_site"
            ;;
        backup:*)
            local file="${source#backup:}"
            download_db_backup "$file" "$target_site"
            ;;
        development)
            download_db_development "$sitename" "$target_site"
            ;;
        url:*)
            local url="${source#url:}"
            download_db_url "$url" "$target_site"
            ;;
        *)
            # Assume it's a file path
            if [ -f "$source" ]; then
                download_db_backup "$source" "$target_site"
            else
                fail "Unknown database source: $source"
                return 1
            fi
            ;;
    esac
}

################################################################################
# Source-Specific Handlers
################################################################################

# Auto-select best database source
download_db_auto() {
    local sitename="$1"
    local target_site="$2"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    info "Auto-selecting database source for $sitename..."

    # Priority 1: Recent sanitized backup (< 24 hours)
    local sanitized_backup=$(find_sanitized_backup "$sitename" 24)
    if [ -n "$sanitized_backup" ]; then
        task "Found recent sanitized backup"
        note "$(basename "$sanitized_backup") - $(backup_age_human "$sanitized_backup")"
        download_db_backup "$sanitized_backup" "$target_site"
        return $?
    fi

    # Priority 2: Recent regular backup (< 24 hours)
    local recent_backup=$(find_recent_backup "$sitename" 24)
    if [ -n "$recent_backup" ]; then
        task "Found recent backup (will sanitize)"
        note "$(basename "$recent_backup") - $(backup_age_human "$recent_backup")"
        download_db_backup "$recent_backup" "$target_site"
        sanitize_staging_db "$target_site"
        return $?
    fi

    # Priority 3: Production (if accessible)
    if has_live_config "$sitename" && check_prod_ssh "$sitename"; then
        task "Production accessible - creating fresh backup"
        download_db_production "$sitename" "$target_site"
        return $?
    fi

    # Priority 4: Clone from development. Use the v1/v2-aware resolver
    # rather than site_exists (which only handles v1 flat names and would
    # reject a v2 absolute path passed in by dev2stg, causing the auto
    # selector to fail for every fresh nwt/nwc/nwd stg deploy).
    local source_dir target_dir
    source_dir=$(_db_router_resolve_dir "$sitename" "$script_dir" 2>/dev/null || true)
    target_dir=$(_db_router_resolve_dir "$target_site" "$script_dir" 2>/dev/null || true)
    if [ -n "$source_dir" ] && [ "$source_dir" != "$target_dir" ]; then
        task "Using development database"
        download_db_development "$sitename" "$target_site"
        return $?
    fi

    fail "No database source available"
    note "Options: Create a backup, configure production SSH, or use --dev-db"
    return 1
}

# Download from production server
download_db_production() {
    local sitename="$1"
    local target_site="$2"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"
    local config_file="$script_dir/nwp.yml"

    info "Downloading database from production..."

    # Get SSH details from config
    local server_ip=$(grep -A 30 "^  $sitename:" "$config_file" 2>/dev/null | \
        grep -A 10 "live:" | grep "server_ip:" | head -1 | awk '{print $2}')
    local domain=$(grep -A 30 "^  $sitename:" "$config_file" 2>/dev/null | \
        grep -A 10 "live:" | grep "domain:" | head -1 | awk '{print $2}')

    if [ -z "$server_ip" ]; then
        fail "No server_ip configured for $sitename"
        return 1
    fi

    # Create backup directory (F23 Phase 4: sites/<site>/backups/)
    local backup_dir
    backup_dir=$(get_backup_dir "$sitename")
    mkdir -p "$backup_dir"

    local timestamp=$(date +%Y%m%dT%H%M%S)
    local backup_file="$backup_dir/prod-${timestamp}.sql.gz"

    task "Connecting to $server_ip..."

    # Try to dump database from production
    # Assumes drush is available on production server
    local remote_path="/var/www/$sitename"

    if ssh -o IdentitiesOnly=yes -o ConnectTimeout=10 "$server_ip" "cd $remote_path && drush sql:dump --gzip" > "$backup_file" 2>/dev/null; then
        pass "Database downloaded from production"
        note "Saved to: $backup_file"

        # Import to target
        download_db_backup "$backup_file" "$target_site"

        # Sanitize after import — FAIL-CLOSED: a failed sanitize must not report
        # success (raw production PII would otherwise remain in the target DB).
        if ! sanitize_staging_db "$target_site"; then
            fail "Sanitization failed after production import — target may hold PII"
            return 1
        fi

        return 0
    else
        fail "Could not download database from production"
        rm -f "$backup_file"
        return 1
    fi
}

# Restore from backup file
download_db_backup() {
    local backup_file="$1"
    local target_site="$2"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    if [ ! -f "$backup_file" ]; then
        fail "Backup file not found: $backup_file"
        return 1
    fi

    info "Restoring database from backup..."
    task "File: $(basename "$backup_file")"

    local original_dir=$(pwd)
    cd "$script_dir/sites/$target_site" || {
        fail "Cannot access target site: $target_site"
        return 1
    }

    # Ensure DDEV is running
    if ! ddev describe &>/dev/null; then
        task "Starting DDEV..."
        ddev start || {
            fail "Could not start DDEV"
            cd "$original_dir"
            return 1
        }
    fi

    # Drop existing database
    task "Dropping existing database..."
    ddev drush sql:drop -y &>/dev/null

    # Import based on file type
    task "Importing database..."
    if [[ "$backup_file" == *.gz ]]; then
        if gunzip -c "$backup_file" | ddev drush sql:cli 2>/dev/null; then
            pass "Database restored from backup"
        else
            fail "Database import failed"
            cd "$original_dir"
            return 1
        fi
    else
        if ddev drush sql:cli < "$backup_file" 2>/dev/null; then
            pass "Database restored from backup"
        else
            fail "Database import failed"
            cd "$original_dir"
            return 1
        fi
    fi

    cd "$original_dir"
    return 0
}

# Clone from development site.
#
# Accepts either a site name or an absolute directory path for both
# source and target arguments. v2 (nested) layouts pass directories;
# v1 (flat) layouts pass names. The helper below normalises either form.
download_db_development() {
    local source_site="$1"
    local target_site="$2"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    # Resolve to absolute project dirs (handles both v1 name + v2 path).
    local source_dir target_dir
    source_dir=$(_db_router_resolve_dir "$source_site" "$script_dir") || {
        fail "Cannot access source site: $source_site"
        return 1
    }
    target_dir=$(_db_router_resolve_dir "$target_site" "$script_dir") || {
        fail "Cannot access target site: $target_site"
        return 1
    }

    if [ "$source_dir" = "$target_dir" ]; then
        fail "Source and target cannot be the same directory: $source_dir"
        return 1
    fi

    info "Cloning database from $source_dir to $target_dir..."

    local original_dir=$(pwd)

    # Ensure source is running
    cd "$source_dir" || {
        fail "Cannot access source site: $source_site"
        return 1
    }

    if ! ddev describe &>/dev/null; then
        task "Starting source DDEV..."
        ddev start || {
            fail "Could not start source DDEV"
            cd "$original_dir"
            return 1
        }
    fi

    # Create temporary dump. Try drush first (Drupal); fall back to
    # ddev export-db (Moodle and anything else that doesn't ship drush).
    # ddev export-db produces a gzipped dump, so reserve a .sql.gz path
    # — extension matters because ddev import-db infers compression
    # from the suffix.
    local temp_dump_uncompressed=$(mktemp --suffix=.sql)
    local temp_dump_gz=$(mktemp --suffix=.sql.gz)
    local temp_dump
    task "Exporting from $source_site..."

    if ddev drush sql:dump > "$temp_dump_uncompressed" 2>/dev/null && [ -s "$temp_dump_uncompressed" ]; then
        temp_dump="$temp_dump_uncompressed"
        rm -f "$temp_dump_gz"
    elif ddev export-db --file="$temp_dump_gz" >/dev/null 2>&1 && [ -s "$temp_dump_gz" ]; then
        temp_dump="$temp_dump_gz"
        rm -f "$temp_dump_uncompressed"
    else
        fail "Could not export database from $source_site (tried drush + ddev export-db)"
        rm -f "$temp_dump_uncompressed" "$temp_dump_gz"
        cd "$original_dir"
        return 1
    fi

    # Ensure target is running
    cd "$target_dir" || {
        fail "Cannot access target site: $target_site"
        rm -f "$temp_dump"
        cd "$original_dir"
        return 1
    }

    if ! ddev describe &>/dev/null; then
        task "Starting target DDEV..."
        ddev start || {
            fail "Could not start target DDEV"
            rm -f "$temp_dump"
            cd "$original_dir"
            return 1
        }
    fi

    # Drop and import. Drush variant for Drupal; ddev import-db otherwise.
    task "Dropping target database..."
    ddev drush sql:drop -y &>/dev/null || ddev mysql -e "DROP DATABASE IF EXISTS db; CREATE DATABASE db;" 2>/dev/null || true

    task "Importing to $target_site..."
    if [[ "$temp_dump" == *.sql ]] && ddev drush sql:cli < "$temp_dump" 2>/dev/null; then
        pass "Database cloned from development (via drush)"
    else
        # ddev import-db reads the file from the container's namespace,
        # so copy it into the project dir. Preserve the extension —
        # ddev import-db infers compression from .sql vs .sql.gz vs etc.
        local in_project_name=".ddev/import-tmp${temp_dump##*/import-tmp}"
        # Simpler: just use the suffix from temp_dump.
        local suffix=".sql"
        [[ "$temp_dump" == *.gz ]] && suffix=".sql.gz"
        in_project_name=".ddev/import-tmp${suffix}"
        local in_project_dump="$target_dir/${in_project_name}"
        cp "$temp_dump" "$in_project_dump"
        if ddev import-db --file="$in_project_name" >/dev/null 2>&1; then
            pass "Database cloned from development (via ddev import-db)"
        else
            fail "Database import failed (tried drush + ddev import-db)"
            rm -f "$temp_dump" "$in_project_dump"
            cd "$original_dir"
            return 1
        fi
        rm -f "$in_project_dump"
    fi

    rm -f "$temp_dump"
    cd "$original_dir"
    return 0
}

# Download from URL
download_db_url() {
    local url="$1"
    local target_site="$2"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    info "Downloading database from URL..."
    task "URL: $url"

    # Create temp file
    local temp_file=$(mktemp --suffix=.sql.gz)

    # Download
    if command -v curl &>/dev/null; then
        if ! curl -sL -o "$temp_file" "$url"; then
            fail "Download failed"
            rm -f "$temp_file"
            return 1
        fi
    elif command -v wget &>/dev/null; then
        if ! wget -q -O "$temp_file" "$url"; then
            fail "Download failed"
            rm -f "$temp_file"
            return 1
        fi
    else
        fail "Neither curl nor wget available"
        rm -f "$temp_file"
        return 1
    fi

    pass "Download complete"

    # Import
    download_db_backup "$temp_file" "$target_site"
    local result=$?

    rm -f "$temp_file"
    return $result
}

################################################################################
# Database Sanitization
################################################################################

# Run one PII-critical sanitize mutation, FAIL-CLOSED.
# Unlike the volatile cache/session truncations (which are best-effort hygiene),
# a failure here means PII may remain, so the error must NOT be swallowed.
# Returns the drush exit code.
_san_critical_query() {
    ddev drush sql:query "$1" >/dev/null 2>&1
}

################################################################################
# NWP-ADR-0031 Phase D (ops#76): promotion-pipeline TYPE DISPATCH
#
# The sanitize path below was Drupal-only: every statement in
# _sanitize_staging_db_drupal (users_field_data, drush upwd, cache_* truncation)
# assumes a Drupal schema and fails on a Moodle DB. D8 requires a per-stack
# dispatch so a Moodle target routes to a Moodle-specific handler instead of
# silently running Drupal SQL against Moodle tables.
#
# This layer is PLUMBING ONLY. The Moodle handler is a FAIL-CLOSED STUB — the
# operator authors the actual mdl_user* / consent anonymisation under
# human-review (CLAUDE.md: the sanitizer is security-critical; plane 5b is
# students' learning records + tool_policy consent rows).
################################################################################

# Map a config `project.type` value to a sanitizer stack.
# Only an explicit `moodle` routes to the Moodle handler; every other value
# (drupal, podcast, utility, shared, empty/unknown) keeps the existing Drupal
# path unchanged — i.e. the dispatch is OFF unless a Moodle target is hit.
# Echoes: "drupal" | "moodle"
_stack_from_type() {
    case "$1" in
        moodle|Moodle|MOODLE) echo "moodle" ;;
        *)                    echo "drupal" ;;
    esac
}

# Runtime schema probe fallback, used only when config gives no answer.
# Kept as its own function so the config-driven dispatch can be unit-tested
# with no ddev/drush available (tests never invoke this).
# Echoes: "drupal" | "moodle" | "unknown"
#
# Detection rule (defensive, prefix-agnostic — Moodle's table prefix is
# configurable, default `mdl_`):
#   - Drupal  → a `users_field_data` table exists
#   - Moodle  → a `*config` table coexists with a `*course` table AND there is
#               NO `users_field_data` (Moodle has `<prefix>config`/`<prefix>course`)
_stack_schema_probe() {
    # Requires a DDEV project in CWD. Never invoked by the unit tests.
    local has_drupal has_moodle
    has_drupal=$(ddev drush sql:query \
        "SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'users_field_data' LIMIT 1" \
        2>/dev/null | tr -d '[:space:]')
    if [ "$has_drupal" = "1" ]; then
        echo "drupal"; return 0
    fi
    has_moodle=$(ddev drush sql:query \
        "SELECT 1 FROM information_schema.tables t1 WHERE t1.table_schema = DATABASE() AND t1.table_name LIKE '%config' AND EXISTS (SELECT 1 FROM information_schema.tables t2 WHERE t2.table_schema = DATABASE() AND t2.table_name LIKE '%course') LIMIT 1" \
        2>/dev/null | tr -d '[:space:]')
    if [ "$has_moodle" = "1" ]; then
        echo "moodle"; return 0
    fi
    echo "unknown"
}

# Detect the promotion stack for a target site.
# Precedence:
#   1. Site config `project.type` (authoritative; unit-testable, no ddev).
#      The tenant is derived by stripping a -dev/-stg/-live/-test env suffix.
#   2. If config yields nothing usable, fall back to the runtime schema probe
#      (only reached on a live DDEV site).
# Echoes: "drupal" | "moodle"  (never "unknown" — unknown resolves to the
# existing Drupal path, whose own schema probe then fail-closes if wrong).
detect_site_stack() {
    local target_site="$1"

    # Derive tenant name for config lookup (nwc-stg → nwc, ss2-live → ss2).
    local tenant="$target_site"
    if [[ "$tenant" =~ ^(.+)-(dev|stg|live|test)$ ]]; then
        tenant="${BASH_REMATCH[1]}"
    fi

    # 1. Config-driven (authoritative). get_site_config_value is provided by
    #    lib/project-resolver.sh (auto-sourced via lib/common.sh).
    local cfg_type=""
    if declare -F get_site_config_value >/dev/null 2>&1; then
        cfg_type=$(get_site_config_value "$tenant" '.project.type' '' 2>/dev/null || echo '')
    fi
    if [ -n "$cfg_type" ] && [ "$cfg_type" != "null" ]; then
        _stack_from_type "$cfg_type"
        return 0
    fi

    # 2. Runtime schema probe fallback (never hit by unit tests).
    local probed
    probed=$(_stack_schema_probe 2>/dev/null || echo "unknown")
    case "$probed" in
        moodle) echo "moodle" ;;
        *)      echo "drupal" ;;   # drupal OR unknown → existing Drupal path
    esac
}

# Moodle sanitize handler — FAIL-CLOSED (ops#76 plumbing; ops#110 routing).
# This DDEV in-place path deliberately REFUSES to proceed. Moodle sanitisation
# is IMPLEMENTED (lib/sanitizers/moodle.sh) but routed via PATH A — the
# prod-native scratch-DB model in scripts/commands/server-publish.sh
# (lib/sanitizers/<site>.sh → moodle.sh), which honours the threat model
# (sanitise on prod, raw data never leaves prod). This in-place path (Path B)
# runs `ddev drush`, a different execution context, and is intentionally NOT
# wired to moodle.sh (see ops#110 for the decision). It returns non-zero so
# every caller (prod2stg/live2stg/download_db_*) that fail-closes on sanitize
# will abort rather than promote a Moodle DB un-sanitized.
_sanitize_staging_db_moodle() {
    local target_site="$1"
    fail "Moodle DDEV in-place sanitize (Path B) is intentionally not wired — use Path A"
    note "Target '$target_site' is a Moodle stack (NWP-ADR-0031 plane 5b: student learning records + tool_policy consent)."
    note "Moodle sanitisation runs prod-native: scripts/commands/server-publish.sh with"
    note "  lib/sanitizers/${target_site}.sh or private/sanitizers/${target_site}.sh (→ lib/sanitizers/moodle.sh). See ops#110/#326."
    note "Refusing to promote a Moodle DB un-sanitized via the DDEV path (fail-closed)."
    return 1
}

# Sanitize database on staging site — TYPE-DISPATCHING entrypoint (ops#76).
# Usage: sanitize_staging_db "target_site"
#
# Detects the target stack and routes to the matching handler:
#   drupal → _sanitize_staging_db_drupal (existing path, unchanged)
#   moodle → _sanitize_staging_db_moodle (fail-closed stub; operator authors it)
# Drupal remains the default for every non-Moodle/unknown target, so existing
# Drupal flows are byte-for-byte unchanged.
sanitize_staging_db() {
    local target_site="$1"
    local stack
    stack=$(detect_site_stack "$target_site")
    case "$stack" in
        moodle)
            _sanitize_staging_db_moodle "$target_site"
            return $?
            ;;
        drupal|*)
            _sanitize_staging_db_drupal "$target_site"
            return $?
            ;;
    esac
}

# Drupal sanitize handler (formerly sanitize_staging_db).
# Usage: _sanitize_staging_db_drupal "target_site"
#
# FAIL-CLOSED contract (hardened): this used to run every mutation with
# `2>/dev/null` and then `return 0` unconditionally, always printing
# "sanitized" — even when the lone anonymize query hit a non-existent table
# (e.g. a Moodle schema has no users_field_data), so PII silently survived while
# the function reported success. It now:
#   1. DETECTS the schema first and REFUSES ("no sanitizer for this schema")
#      rather than falsely reporting sanitized on a non-Drupal DB;
#   2. hard-checks the exit code of each PII-critical mutation and returns 1 on
#      failure (cache/session truncations stay best-effort);
#   3. asserts a POST-CONDITION — zero user rows (uid > 0, incl. admin) retain a
#      non-example mail or init — and returns 1 if any PII remains.
# The independent lib/pii-gate.sh scan remains the outer backstop.
_sanitize_staging_db_drupal() {
    local target_site="$1"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

    info "Sanitizing database..."

    local original_dir=$(pwd)
    cd "$script_dir/sites/$target_site" || {
        fail "Cannot access target site: $target_site"
        return 1
    }

    # ── Step 0: DETECT the schema before mutating. This generic pass only
    #    understands the core Drupal user schema (users_field_data). On any other
    #    schema (Moodle, a bespoke app, an empty DB) the anonymize query is a
    #    silent no-op, so we must REFUSE rather than falsely report "sanitized".
    task "Detecting schema..."
    local schema_probe
    schema_probe=$(ddev drush sql:query \
        "SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'users_field_data' LIMIT 1" \
        2>/dev/null | tr -d '[:space:]')
    if [ "$schema_probe" != "1" ]; then
        fail "No sanitizer for this schema: '$target_site' has no Drupal users_field_data table"
        note "This generic sanitizer only handles a standard Drupal schema."
        note "Refusing to report 'sanitized' on an unknown schema (fail-closed)."
        cd "$original_dir"
        return 1
    fi

    # ── Volatile / cache tables: best-effort hygiene (not PII-critical). A
    #    missing table here is harmless, so these stay tolerant.
    task "Truncating cache tables..."
    local t
    for t in cache_bootstrap cache_config cache_container cache_data cache_default \
             cache_discovery cache_dynamic_page_cache cache_entity cache_menu \
             cache_page cache_render; do
        ddev drush sql:query "TRUNCATE TABLE $t" 2>/dev/null || true
    done

    task "Truncating session and log tables..."
    for t in sessions watchdog flood; do
        ddev drush sql:query "TRUNCATE TABLE $t" 2>/dev/null || true
    done

    # ── PII-critical mutation: FAIL-CLOSED on error. Emails (mail + init) are
    #    anonymized for ALL real users INCLUDING admin (uid > 0), matching the
    #    prod-native lib/sanitizers/standard.sh. The USERNAME rename stays scoped
    #    to uid > 1 so the admin account keeps its 'admin' name — required for the
    #    `drush upwd admin` reset below and for staging login. (Usernames are not
    #    PII; the real email is. `init` is Drupal's registration-email field —
    #    previously left untouched, so real PII survived there.)
    task "Anonymizing user emails (incl. admin)..."
    if ! _san_critical_query "UPDATE users_field_data SET mail = CONCAT('user', uid, '@example.com'), init = CONCAT('user', uid, '@example.com') WHERE uid > 0"; then
        fail "User email anonymization query failed — PII may remain (fail-closed)"
        cd "$original_dir"
        return 1
    fi
    task "Anonymizing non-admin usernames..."
    if ! _san_critical_query "UPDATE users_field_data SET name = CONCAT('user', uid) WHERE uid > 1"; then
        fail "Username anonymization query failed — PII may remain (fail-closed)"
        cd "$original_dir"
        return 1
    fi

    task "Resetting admin password..."
    if ! ddev drush upwd admin admin >/dev/null 2>&1; then
        fail "Admin password reset failed (fail-closed)"
        cd "$original_dir"
        return 1
    fi

    task "Clearing sensitive config..."
    ddev drush cdel system.mail --quiet 2>/dev/null || true
    ddev drush cdel smtp.settings --quiet 2>/dev/null || true

    # ── POST-CONDITION assertion: no real emails may survive. A count of user
    #    rows (uid > 0, incl. admin) whose mail OR init is NOT an @example.com
    #    address must be 0. A non-numeric result (query failed) is also a failure
    #    — fail-closed.
    task "Verifying no PII remains..."
    local residual
    residual=$(ddev drush sql:query \
        "SELECT COUNT(*) FROM users_field_data WHERE uid > 0 AND (mail NOT LIKE '%@example.com' OR init NOT LIKE '%@example.com')" \
        2>/dev/null | tr -d '[:space:]')
    if ! [[ "$residual" =~ ^[0-9]+$ ]]; then
        fail "Could not verify sanitization (post-condition query failed) — fail-closed"
        cd "$original_dir"
        return 1
    fi
    if [ "$residual" != "0" ]; then
        fail "Sanitization incomplete: $residual user row(s) still hold a non-example email (PII remains)"
        cd "$original_dir"
        return 1
    fi

    task "Rebuilding cache..."
    ddev drush cr 2>/dev/null || true

    pass "Database sanitized (verified: 0 residual PII rows for uid > 0, incl. admin)"

    cd "$original_dir"
    return 0
}

# Create sanitized backup
# Usage: create_sanitized_backup "sitename"
create_sanitized_backup() {
    local sitename="$1"
    local script_dir="${PROJECT_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"
    # F23 Phase 4: sanitized backups live alongside regular ones inside the site.
    local backup_dir
    backup_dir="$(get_backup_dir "$sitename")/sanitized"

    mkdir -p "$backup_dir"

    local timestamp=$(date +%Y%m%dT%H%M%S)
    local branch=$(cd "$script_dir/sites/$sitename" && git branch --show-current 2>/dev/null || echo "main")
    local commit=$(cd "$script_dir/sites/$sitename" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    local backup_file="$backup_dir/${timestamp}-${branch}-${commit}.sql.gz"

    info "Creating sanitized backup..."

    local original_dir=$(pwd)
    cd "$script_dir/sites/$sitename" || {
        fail "Cannot access site: $sitename"
        return 1
    }

    task "Exporting database..."
    if ddev drush sql:dump --gzip > "$backup_file" 2>/dev/null; then
        pass "Sanitized backup created"
        note "File: $backup_file"
        echo "$backup_file"
        cd "$original_dir"
        return 0
    else
        fail "Could not create backup"
        cd "$original_dir"
        return 1
    fi
}

################################################################################
# Utility Functions
################################################################################

# List available backups for a site
# Usage: list_backups "sitename" [limit]
list_backups() {
    local sitename="$1"
    local limit="${2:-10}"
    local backup_dir
    backup_dir=$(get_backup_dir "$sitename")

    if [ ! -d "$backup_dir" ]; then
        echo "No backups found for $sitename"
        return 1
    fi

    info "Available backups for $sitename:"
    find "$backup_dir" -name "*.sql*" -type f 2>/dev/null | \
        xargs -r ls -lt 2>/dev/null | \
        head -"$limit" | \
        while read -r line; do
            local file=$(echo "$line" | awk '{print $NF}')
            local size=$(echo "$line" | awk '{print $5}')
            local date=$(echo "$line" | awk '{print $6, $7, $8}')
            echo "  $(basename "$file") - $date - $(numfmt --to=iec $size 2>/dev/null || echo "${size}B")"
        done
}

# Get recommended database source based on state
# Usage: get_recommended_db_source "sitename"
# Returns: recommended source type
get_recommended_db_source() {
    local sitename="$1"

    # Check for recent sanitized backup first
    if find_sanitized_backup "$sitename" 24 &>/dev/null; then
        echo "sanitized_backup"
        return 0
    fi

    # Check for recent regular backup
    if find_recent_backup "$sitename" 24 &>/dev/null; then
        echo "recent_backup"
        return 0
    fi

    # Check production accessibility
    if has_live_config "$sitename" && check_prod_ssh "$sitename" 2>/dev/null; then
        echo "production"
        return 0
    fi

    # Default to development
    echo "development"
}
