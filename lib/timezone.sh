#!/bin/bash
# lib/timezone.sh - Timezone configuration helpers
# Part of NWP (Narrow Way Project)

# Double-source guard
if [[ "${_TIMEZONE_SH_LOADED:-}" == "1" ]]; then
    return 0
fi
_TIMEZONE_SH_LOADED=1

# Get the default timezone from settings
# Falls back to UTC if not configured
# Usage: get_default_timezone [config_file]
get_default_timezone() {
    local config_file="${1:-${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/nwp.yml}"
    local tz=""

    if [[ -f "$config_file" ]]; then
        tz=$(awk '/^settings:/{found=1} found && /^  timezone:/{print $2; exit}' "$config_file" 2>/dev/null)
    fi

    echo "${tz:-UTC}"
}

# Get timezone for a specific site (with fallback to default)
# Usage: get_site_timezone <sitename> [config_file]
get_site_timezone() {
    local site_name="$1"
    local config_file="${2:-${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/nwp.yml}"
    local tz=""

    if [[ -f "$config_file" ]]; then
        # Check site-specific timezone first
        tz=$(awk -v site="$site_name" '
            /^sites:/{in_sites=1; next}
            in_sites && /^  [a-zA-Z]/ && $1 == site":"{in_site=1; next}
            in_sites && /^  [a-zA-Z]/ && $1 != site":"{in_site=0}
            in_site && /^    timezone:/{print $2; exit}
        ' "$config_file" 2>/dev/null)
    fi

    # Fall back to default timezone
    if [[ -z "$tz" ]]; then
        tz=$(get_default_timezone "$config_file")
    fi

    echo "$tz"
}

# Validate a timezone string
# Usage: validate_timezone "Australia/Sydney"
# Returns: 0 if valid, 1 if invalid
validate_timezone() {
    local tz="$1"
    if [[ -f "/usr/share/zoneinfo/$tz" ]]; then
        return 0
    fi
    return 1
}
