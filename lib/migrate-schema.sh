#!/bin/bash
# lib/migrate-schema.sh
#
# Schema migration framework for NWP config files.
#
# Handles per-site (.nwp.yml), global (nwp.yml), and server
# (servers/<name>/.nwp-server.yml) config schema versions. Each schema
# has an independent integer counter. When NWP code expects a higher
# schema_version than a file carries, this runner executes each
# lib/migrations/<scope>/NNN-*.sh step in sequence, taking a
# pre-migration backup first.
#
# See docs/proposals/F23-project-separation-v2.md §3.7 for the design.

# Current schema versions expected by the running NWP code.
# Bump these when adding a new migration under lib/migrations/<scope>/.
CURRENT_SITE_SCHEMA=2
CURRENT_GLOBAL_SCHEMA=1
CURRENT_SERVER_SCHEMA=1

# Require yq — all schema work uses YAML.
_migrate_require_yq() {
    if ! command -v yq &>/dev/null; then
        echo "ERROR: yq is required for schema migrations but was not found in PATH." >&2
        echo "Install yq (https://github.com/mikefarah/yq) and retry." >&2
        return 1
    fi
    return 0
}

# Read the schema_version field from a YAML file, defaulting to 0 if
# missing (pre-framework files).
read_schema_version() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "0"
        return 0
    fi
    local v
    v=$(yq eval '.schema_version // 0' "$file" 2>/dev/null || echo "0")
    # Normalize: empty or null → 0
    [[ -z "$v" || "$v" == "null" ]] && v="0"
    echo "$v"
}

# Shared migration runner.
#
# Args:
#   $1 - scope: "site" | "global" | "server"
#   $2 - label: human-readable identifier (e.g. site name)
#   $3 - config file path
#   $4 - target schema version
#   $5 - (optional) context dir passed to migration functions
_run_migrations() {
    local scope="$1"
    local label="$2"
    local config="$3"
    local target="$4"
    local context_dir="${5:-$(dirname "$config")}"

    _migrate_require_yq || return 1

    if [[ ! -f "$config" ]]; then
        echo "ERROR: No config file found at $config" >&2
        return 1
    fi

    local current
    current=$(read_schema_version "$config")

    if [[ "$current" -ge "$target" ]]; then
        echo "[$scope] $label is up to date (schema $current)"
        return 0
    fi

    echo "[$scope] Migrating $label from schema $current → $target"

    # Pre-migration backup
    local ts
    ts=$(date +%Y%m%dT%H%M%S)
    local backup="$config.pre-migration-$ts.bak"
    cp "$config" "$backup"
    echo "  Backup: $backup"

    local migration_dir="$NWP_DIR/lib/migrations/$scope"
    if [[ ! -d "$migration_dir" ]]; then
        echo "ERROR: Migration dir missing: $migration_dir" >&2
        return 1
    fi

    local from="$current" to
    while [[ "$from" -lt "$target" ]]; do
        to=$((from + 1))
        # Find the migration script for this step (NNN-description.sh)
        local script
        script=$(find "$migration_dir" -maxdepth 1 -type f -name "$(printf '%03d' "$to")-*.sh" 2>/dev/null | sort | head -n1)

        if [[ -z "$script" ]]; then
            echo "ERROR: Missing migration script for $scope schema $from → $to" >&2
            echo "  Expected: $migration_dir/$(printf '%03d' "$to")-*.sh" >&2
            echo "  Restoring backup and aborting." >&2
            mv "$backup" "$config"
            return 1
        fi

        echo "  Applying $(basename "$script")..."
        # shellcheck source=/dev/null
        source "$script"

        local fn_name
        fn_name="migrate_$(printf '%03d' "$from")_to_$(printf '%03d' "$to")"
        if ! declare -F "$fn_name" >/dev/null; then
            echo "ERROR: Migration script $script did not define $fn_name()" >&2
            mv "$backup" "$config"
            return 1
        fi

        if ! "$fn_name" "$context_dir" "$config"; then
            echo "ERROR: Migration $from → $to failed — restoring backup" >&2
            mv "$backup" "$config"
            return 1
        fi

        # Migration functions are expected to bump schema_version themselves,
        # but we enforce it defensively here in case they forgot.
        local new_version
        new_version=$(read_schema_version "$config")
        if [[ "$new_version" != "$to" ]]; then
            yq eval -i ".schema_version = $to" "$config"
        fi
        yq eval -i ".nwp_version_updated = \"${NWP_VERSION:-0.30.0}\"" "$config"

        from="$to"
    done

    echo "[$scope] $label migrated to schema $target"
    return 0
}

# Migrate a single site config.
# Usage: migrate_site <site_name>
migrate_site() {
    local site="$1"
    local site_dir="$NWP_DIR/sites/$site"
    local config="$site_dir/.nwp.yml"
    _run_migrations "site" "$site" "$config" "$CURRENT_SITE_SCHEMA" "$site_dir"
}

# Migrate the global nwp.yml.
migrate_global() {
    local config="$NWP_DIR/nwp.yml"
    _run_migrations "global" "nwp.yml" "$config" "$CURRENT_GLOBAL_SCHEMA" "$NWP_DIR"
}

# Migrate a server config.
# Usage: migrate_server <server_name>
migrate_server() {
    local server="$1"
    local server_dir="$NWP_DIR/servers/$server"
    local config="$server_dir/.nwp-server.yml"
    _run_migrations "server" "$server" "$config" "$CURRENT_SERVER_SCHEMA" "$server_dir"
}

# Migrate every site that has a .nwp.yml file.
migrate_all_sites() {
    local sites_dir="$NWP_DIR/sites"
    local any_failed=0
    [[ -d "$sites_dir" ]] || { echo "No sites/ directory found."; return 0; }
    for dir in "$sites_dir"/*/; do
        local name
        name=$(basename "$dir")
        # Skip well-known generated/scratch dirs
        case "$name" in
            tmp|latest|vendor|ss_moodledata) continue ;;
            20260117T212337-no-git-no-git) continue ;;
            *-stg) continue ;;  # F23: -stg siblings absorbed by parent migration
        esac
        if [[ -f "$dir/.nwp.yml" ]]; then
            if ! migrate_site "$name"; then
                any_failed=1
            fi
        fi
    done
    return "$any_failed"
}

# Check whether a site's .nwp.yml is at the current schema.
# Returns 0 if current, 1 if stale, 2 if missing or unreadable.
check_site_schema() {
    local site="$1"
    local config="$NWP_DIR/sites/$site/.nwp.yml"
    if [[ ! -f "$config" ]]; then
        return 2
    fi
    local v
    v=$(read_schema_version "$config")
    if [[ "$v" -lt "$CURRENT_SITE_SCHEMA" ]]; then
        return 1
    fi
    return 0
}
