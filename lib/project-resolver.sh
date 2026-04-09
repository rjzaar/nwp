#!/bin/bash
# lib/project-resolver.sh
#
# Per-site project resolution helpers (F17 Phase 6, updated F23).
#
# Supports two layout versions:
#   v1 (flat):  sites/<name>/.nwp.yml + .ddev/ + web/ all in one dir
#   v2 (nested): sites/<name>/.nwp.yml (site-level) + dev/ + stg/ subdirs
#
# All helpers accept either a bare site name or a path to a site directory.
# Assumes PROJECT_ROOT or NWP_DIR is set by the caller (common.sh does).

# Fallback to PROJECT_ROOT if NWP_DIR not already set.
: "${NWP_DIR:=${PROJECT_ROOT:-}}"

# Return the absolute path to a site's DDEV project root (where web/ and
# .ddev/ live). For v2 sites, returns the requested env subdir (default:
# dev). For v1 sites, returns the flat directory.
#
# Usage: resolve_project <name> [env]
#   resolve_project ba        → sites/ba/dev/  (v2) or sites/ba/ (v1)
#   resolve_project ba stg    → sites/ba/stg/  (v2 only)
#   resolve_project ba site   → sites/ba/      (always — the site container)
resolve_project() {
    local identifier="${1:-}"
    local env="${2:-dev}"
    [[ -z "$identifier" ]] && return 1

    local root="${NWP_DIR:-${PROJECT_ROOT:-$HOME/nwp}}"
    local site_dir="$root/sites/$identifier"

    # "site" env always returns the site container dir.
    if [[ "$env" == "site" ]]; then
        if [[ -d "$site_dir" ]]; then
            echo "$site_dir"
            return 0
        fi
        return 1
    fi

    if [[ -d "$site_dir" ]]; then
        # v2 layout: dev/ subdir exists
        if [[ -d "$site_dir/dev" ]]; then
            if [[ -d "$site_dir/$env" ]]; then
                echo "$site_dir/$env"
            else
                echo "$site_dir/dev"
            fi
            return 0
        fi

        # v1 layout: flat directory with .nwp.yml or .ddev/
        if [[ -f "$site_dir/.nwp.yml" || -d "$site_dir/.ddev" ]]; then
            echo "$site_dir"
            return 0
        fi

        # Directory exists but no config — return it, callers decide.
        echo "$site_dir"
        return 0
    fi

    # Absolute path or ./path passed in.
    if [[ -d "$identifier" && -f "$identifier/.nwp.yml" ]]; then
        cd "$identifier" && pwd
        return 0
    fi

    return 1
}

# Return the site container directory (sites/<name>/) regardless of layout.
# For site-level operations (backups, identity config).
resolve_site_dir() {
    resolve_project "${1:-}" "site"
}

# Return the site name given a directory (or cwd).
# Works by walking up until we find sites/<name>/.nwp.yml.
# For v2, the env dir (dev/, stg/) is inside sites/<name>/, so we walk
# up through it to reach the site container.
find_project_from_cwd() {
    local dir="${1:-$PWD}"
    dir=$(cd "$dir" 2>/dev/null && pwd) || return 1

    while [[ "$dir" != "/" && -n "$dir" ]]; do
        local parent
        parent=$(dirname "$dir")
        # v1: sites/<name>/.nwp.yml — parent is sites/
        if [[ -f "$dir/.nwp.yml" && "$parent" == */sites ]]; then
            basename "$dir"
            return 0
        fi
        # v2: sites/<name>/dev/ or sites/<name>/stg/ — grandparent is sites/
        local grandparent
        grandparent=$(dirname "$parent")
        if [[ -f "$parent/.nwp.yml" && "$grandparent" == */sites ]]; then
            basename "$parent"
            return 0
        fi
        dir="$parent"
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
# Resolution order:
#   v2: site-level .nwp.local.yml → site-level .nwp.yml → nwp.yml (global)
#   v1: .nwp.local.yml → .nwp.yml → nwp.yml (global)
#
# For v2, "site_dir" is sites/<name>/ (the container), not the env subdir.
# This means identity/live config is always read from the site level.
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

    # Always read from site container dir (not env subdir).
    local site_dir
    site_dir=$(resolve_project "$site" "site") || { echo "$default"; return 1; }

    local value=""
    local found=0

    # 1. .nwp.local.yml (per-developer override)
    if [[ -f "$site_dir/.nwp.local.yml" ]]; then
        value=$("$yq_bin" eval "$path // \"\"" "$site_dir/.nwp.local.yml" 2>/dev/null || echo "")
        [[ -n "$value" && "$value" != "null" ]] && found=1
    fi

    # 2. .nwp.yml (site-level config)
    if [[ "$found" == "0" && -f "$site_dir/.nwp.yml" ]]; then
        value=$("$yq_bin" eval "$path // \"\"" "$site_dir/.nwp.yml" 2>/dev/null || echo "")
        [[ -n "$value" && "$value" != "null" ]] && found=1
    fi

    # 3. Global nwp.yml (legacy: .sites.<name>.<path>)
    if [[ "$found" == "0" ]]; then
        local global_config="${NWP_DIR:-${PROJECT_ROOT:-$HOME/nwp}}/nwp.yml"
        if [[ -f "$global_config" ]]; then
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

# Read a value from a specific environment's .nwp.yml.
# Usage: get_env_config_value <site> <env> <yq-path> [default]
get_env_config_value() {
    local site="$1"
    local env="$2"
    local path="$3"
    local default="${4:-}"

    local yq_bin
    if command -v yq &>/dev/null; then
        yq_bin=yq
    elif [[ -x "$HOME/.local/bin/yq" ]]; then
        yq_bin="$HOME/.local/bin/yq"
    else
        echo "$default"
        return 1
    fi

    local env_dir
    env_dir=$(resolve_project "$site" "$env") || { echo "$default"; return 1; }

    if [[ -f "$env_dir/.nwp.yml" ]]; then
        local value
        value=$("$yq_bin" eval "$path // \"\"" "$env_dir/.nwp.yml" 2>/dev/null || echo "")
        if [[ -n "$value" && "$value" != "null" ]]; then
            echo "$value"
            return 0
        fi
    fi
    echo "$default"
}

# Check if a site uses the v2 (nested env) layout.
is_v2_layout() {
    local site="$1"
    local root="${NWP_DIR:-${PROJECT_ROOT:-$HOME/nwp}}"
    [[ -d "$root/sites/$site/dev" ]]
}

# List environments available for a site.
# v2: lists subdirs that contain .nwp.yml with an environment field.
# v1: returns "flat" (no env subdirs).
list_site_envs() {
    local site="$1"
    local root="${NWP_DIR:-${PROJECT_ROOT:-$HOME/nwp}}"
    local site_dir="$root/sites/$site"

    if is_v2_layout "$site"; then
        for d in "$site_dir"/*/; do
            local name
            name=$(basename "$d")
            [[ -f "$d/.nwp.yml" ]] && echo "$name"
        done
    else
        echo "flat"
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
