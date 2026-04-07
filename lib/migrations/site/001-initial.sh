#!/bin/bash
# lib/migrations/site/001-initial.sh
#
# Baseline site schema migration.
#
# This is the "no-op" migration that exists so the framework has a
# starting point. Any file with schema_version 0 (or missing the field
# entirely) is treated as being "pre-framework" — we upgrade it to
# schema 1 by simply ensuring the required metadata fields exist.
#
# Schema 1 is the initial per-site .nwp.yml format introduced in F23.

# shellcheck disable=SC2034  # functions sourced by migrate-schema.sh

migrate_000_to_001() {
    local site_dir="$1"
    local config="$2"

    # If the file already has content but no schema_version, add the
    # metadata triple. Anything missing gets a safe default.
    local sv
    sv=$(yq eval '.schema_version // 0' "$config")
    if [[ "$sv" == "0" || "$sv" == "null" ]]; then
        yq eval -i '.schema_version = 1' "$config"
    fi

    local created
    created=$(yq eval '.nwp_version_created // ""' "$config")
    if [[ -z "$created" || "$created" == "null" ]]; then
        yq eval -i ".nwp_version_created = \"${NWP_VERSION:-0.30.0}\"" "$config"
    fi

    yq eval -i ".nwp_version_updated = \"${NWP_VERSION:-0.30.0}\"" "$config"

    return 0
}
