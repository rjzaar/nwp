#!/bin/bash
# lib/project-resolver.sh
#
# Per-site project resolution helpers (F23 Phase 6).
#
# This library lets scripts transition from the old "global nwp.yml
# only" model to the new per-site .nwp.yml model without breaking
# either. All helpers accept either a bare site name or a path to a
# site directory.
#
# Assumes PROJECT_ROOT or NWP_DIR is set by the caller (common.sh does).

# Fallback to PROJECT_ROOT if NWP_DIR not already set.
: "${NWP_DIR:=${PROJECT_ROOT:-}}"

# Return the absolute path to a site's root directory, or empty + non-zero
# if the site does not exist. A site is considered to exist if the
# directory is present under $NWP_DIR/sites/ and either contains a
# .nwp.yml (new model) or a .ddev/ directory (legacy model).
resolve_project() {
    local identifier="${1:-}"
    [[ -z "$identifier" ]] && return 1

    local root="${NWP_DIR:-${PROJECT_ROOT:-$HOME/nwp}}"
    local site_dir="$root/sites/$identifier"

    # 1. Direct match in sites/ — new or legacy layout.
    if [[ -d "$site_dir" ]]; then
        if [[ -f "$site_dir/.nwp.yml" || -d "$site_dir/.ddev" ]]; then
            echo "$site_dir"
            return 0
        fi
        # Still return the dir if it exists — callers can decide.
        echo "$site_dir"
        return 0
    fi

    # 2. Absolute path or ./path passed in.
    if [[ -d "$identifier" && -f "$identifier/.nwp.yml" ]]; then
        cd "$identifier" && pwd
        return 0
    fi

    return 1
}

# Return the site name given a directory (or cwd).
# Works by walking up until we find sites/<name>/.nwp.yml.
find_project_from_cwd() {
    local dir="${1:-$PWD}"
    # Make absolute
    dir=$(cd "$dir" 2>/dev/null && pwd) || return 1

    while [[ "$dir" != "/" && -n "$dir" ]]; do
        if [[ -f "$dir/.nwp.yml" && "$(dirname "$dir")" == */sites ]]; then
            basename "$dir"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

# Resolve the per-site config file path (.nwp.yml), or empty if missing.
resolve_site_config() {
    local site="$1"
    local site_dir
    site_dir=$(resolve_project "$site") || return 1
    if [[ -f "$site_dir/.nwp.yml" ]]; then
        echo "$site_dir/.nwp.yml"
        return 0
    fi
    return 1
}

# Backup directory for a site. With F23, backups live inside the site
# (sites/<name>/backups/). Falls back to the legacy sitebackups/<name>/
# path ONLY if the new location doesn't exist AND the legacy one does
# — this keeps scripts running against sites that haven't been migrated
# in place yet.
get_backup_dir() {
    local site="$1"
    local root="${NWP_DIR:-${PROJECT_ROOT:-$HOME/nwp}}"
    local new_dir="$root/sites/$site/backups"
    local legacy_dir="$root/sitebackups/$site"

    if [[ -d "$new_dir" ]]; then
        echo "$new_dir"
        return 0
    fi
    if [[ -d "$legacy_dir" ]]; then
        echo "$legacy_dir"
        return 0
    fi
    # Neither exists yet — default to the new location so the caller
    # can mkdir -p it.
    echo "$new_dir"
    return 0
}

# Layered config reader for a site field.
#
# Resolution order: .nwp.local.yml → .nwp.yml → nwp.yml (global)
#
# Usage: get_site_config_value <site> <yq-path> [default]
# Example: get_site_config_value mt '.live.domain' ""
get_site_config_value() {
    local site="$1"
    local path="$2"
    local default="${3:-}"

    local yq_bin
    if command -v yq &>/dev/null; then
        yq_bin=yq
    elif [[ -x "$HOME/.local/bin/yq" ]]; then
        yq_bin="$HOME/.local/bin/yq"
    else
        echo "$default"
        return 1
    fi

    local site_dir
    site_dir=$(resolve_project "$site") || { echo "$default"; return 1; }

    local value=""
    local found=0

    # 1. .nwp.local.yml (per-developer override)
    if [[ -f "$site_dir/.nwp.local.yml" ]]; then
        value=$("$yq_bin" eval "$path // \"\"" "$site_dir/.nwp.local.yml" 2>/dev/null || echo "")
        [[ -n "$value" && "$value" != "null" ]] && found=1
    fi

    # 2. .nwp.yml (committed per-site)
    if [[ "$found" == "0" && -f "$site_dir/.nwp.yml" ]]; then
        value=$("$yq_bin" eval "$path // \"\"" "$site_dir/.nwp.yml" 2>/dev/null || echo "")
        [[ -n "$value" && "$value" != "null" ]] && found=1
    fi

    # 3. Global nwp.yml (legacy: .sites.<name>.<path>)
    if [[ "$found" == "0" ]]; then
        local global_config="${NWP_DIR:-${PROJECT_ROOT:-$HOME/nwp}}/nwp.yml"
        if [[ -f "$global_config" ]]; then
            # Strip leading dot from path and prefix with .sites.<name>
            local global_path=".sites.\"$site\"${path}"
            value=$("$yq_bin" eval "$global_path // \"\"" "$global_config" 2>/dev/null || echo "")
            [[ -n "$value" && "$value" != "null" ]] && found=1
        fi
    fi

    if [[ "$found" == "1" ]]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# List all sites discovered on disk (anything under sites/ with a
# .nwp.yml file). Filters out generated/scratch dirs.
discover_sites() {
    local root="${NWP_DIR:-${PROJECT_ROOT:-$HOME/nwp}}"
    local sites_dir="$root/sites"
    [[ -d "$sites_dir" ]] || return 0
    for dir in "$sites_dir"/*/; do
        [[ -d "$dir" ]] || continue
        local name
        name=$(basename "$dir")
        case "$name" in
            tmp|latest|vendor|ss_moodledata) continue ;;
            20260117T212337-no-git-no-git) continue ;;
        esac
        if [[ -f "$dir/.nwp.yml" ]]; then
            echo "$name"
        fi
    done
}
