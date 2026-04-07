#!/bin/bash
# lib/migrations/global/001-initial.sh
#
# Baseline global schema migration for ~/nwp/nwp.yml.
#
# Does nothing except stamp schema_version=1 and the version fields on
# files that pre-date the schema framework.

# shellcheck disable=SC2034

migrate_000_to_001() {
    local nwp_dir="$1"
    local config="$2"

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
