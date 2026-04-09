#!/bin/bash
# lib/migrations/site/002-env-layout.sh
#
# F23: Site Environment Layout migration.
#
# Restructures sites/<name>/ from flat (v1) to nested (v2):
#   v1: sites/<name>/{.nwp.yml, .ddev/, web/, composer.json, ...}
#   v2: sites/<name>/{.nwp.yml (site-level), dev/, stg/, backups/}
#
# For live-enabled sites, creates both dev/ and stg/.
# For non-live sites, creates dev/ only.
# Absorbs existing <name>-stg/ siblings into <name>/stg/.

# shellcheck disable=SC2034  # functions sourced by migrate-schema.sh

migrate_001_to_002() {
    local site_dir="$1"
    local config="$2"

    local site_name
    site_name=$(basename "$site_dir")
    local sites_parent
    sites_parent=$(dirname "$site_dir")

    # Already migrated? (dev/ subdir exists)
    if [[ -d "$site_dir/dev" ]]; then
        yq eval -i '.schema_version = 2' "$config"
        return 0
    fi

    echo "  Restructuring $site_name to v2 layout..."

    # Read live.enabled before we start moving things.
    local live_enabled
    live_enabled=$(yq eval '.live.enabled // false' "$config" 2>/dev/null)

    # 1. Create backups/ at site level if not present.
    mkdir -p "$site_dir/backups"

    # 2. Identify everything to move into dev/.
    #    Keep at site level: .nwp.yml, backups/, scripts/ (if exists)
    #    Move everything else into dev/.
    mkdir -p "$site_dir/dev"

    local item
    for item in "$site_dir"/*  "$site_dir"/.[!.]* "$site_dir"/..?*; do
        [[ -e "$item" ]] || continue
        local base
        base=$(basename "$item")
        case "$base" in
            .nwp.yml|.nwp.local.yml|backups|scripts|dev|stg)
                # Keep at site level
                continue
                ;;
            .nwp.yml.pre-migration-*.bak)
                # Keep migration backups at site level
                continue
                ;;
            *)
                mv "$item" "$site_dir/dev/"
                ;;
        esac
    done

    # 3. Create env-level .nwp.yml for dev/.
    cat > "$site_dir/dev/.nwp.yml" <<DEVEOF
schema_version: 2
environment: development
parent_site: $site_name
ddev_name: ${site_name}-dev
DEVEOF

    # 4. Update DDEV project name in dev/.
    local ddev_config="$site_dir/dev/.ddev/config.yaml"
    if [[ -f "$ddev_config" ]]; then
        # Stop current DDEV project before rename to avoid ghost containers.
        local old_ddev_name
        old_ddev_name=$(yq eval '.name' "$ddev_config" 2>/dev/null)
        if [[ -n "$old_ddev_name" && "$old_ddev_name" != "null" ]]; then
            (cd "$site_dir/dev" && ddev stop 2>/dev/null) || true
        fi
        yq eval -i ".name = \"${site_name}-dev\"" "$ddev_config"
    fi

    # 5. Handle stg/ — absorb -stg sibling or create from dev/.
    if [[ "$live_enabled" == "true" ]]; then
        local stg_sibling="$sites_parent/${site_name}-stg"

        if [[ -d "$stg_sibling" ]]; then
            echo "  Absorbing ${site_name}-stg/ into ${site_name}/stg/..."
            # Stop DDEV in sibling before moving.
            (cd "$stg_sibling" && ddev stop 2>/dev/null) || true
            mv "$stg_sibling" "$site_dir/stg"
        else
            echo "  Creating stg/ from dev/ (code only, no DB)..."
            mkdir -p "$site_dir/stg"

            # Copy code files from dev/, excluding heavy/env-specific dirs.
            rsync -a \
                --exclude='.ddev/' \
                --exclude='.git/' \
                --exclude='vendor/' \
                --exclude='node_modules/' \
                --exclude='web/sites/default/files/' \
                --exclude='private/' \
                "$site_dir/dev/" "$site_dir/stg/"
        fi

        # Create env-level .nwp.yml for stg/.
        cat > "$site_dir/stg/.nwp.yml" <<STGEOF
schema_version: 2
environment: staging
parent_site: $site_name
ddev_name: ${site_name}-stg
settings:
  stage_file_proxy: true
  database_sanitize: true
STGEOF

        # Create/update DDEV config for stg/.
        mkdir -p "$site_dir/stg/.ddev"
        local stg_ddev="$site_dir/stg/.ddev/config.yaml"
        if [[ -f "$stg_ddev" ]]; then
            # Existing config from -stg sibling — just rename.
            (cd "$site_dir/stg" && ddev stop 2>/dev/null) || true
            yq eval -i ".name = \"${site_name}-stg\"" "$stg_ddev"
        elif [[ -f "$ddev_config" ]]; then
            # Copy from dev's config, change name and ENV_TYPE.
            cp "$ddev_config" "$stg_ddev"
            yq eval -i ".name = \"${site_name}-stg\"" "$stg_ddev"
            # Update ENV_TYPE to staging in web_environment array.
            yq eval -i '(.web_environment[] | select(. == "ENV_TYPE=development")) = "ENV_TYPE=staging"' "$stg_ddev" 2>/dev/null || true
            yq eval -i '(.web_environment[] | select(. == "ENV_DEBUG=1")) = "ENV_DEBUG=0"' "$stg_ddev" 2>/dev/null || true
        fi

        # Add stg to environments list.
        yq eval -i '.environments = ["dev", "stg"]' "$config"
    else
        yq eval -i '.environments = ["dev"]' "$config"
    fi

    # 6. Clean up the site-level .nwp.yml — remove fields that are
    #    now env-specific (project.environment moves to env .nwp.yml).
    yq eval -i 'del(.project.environment)' "$config"

    # 7. Bump schema version.
    yq eval -i '.schema_version = 2' "$config"

    echo "  $site_name migrated to v2 layout"
    return 0
}
