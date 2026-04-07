#!/usr/bin/env bash
# scripts/commands/proposals.sh
#
# `pl proposals` — aggregate proposal documents across NWP root and all sites
# (F23 §7.4 / Phase 10).
#
# Usage:
#   pl proposals                       List all proposals
#   pl proposals --site=<name>         Only list proposals for one site
#   pl proposals --status=<status>     Filter by status (proposed/in-progress/complete)
#   pl proposals --root                Only list root NWP proposals
#   pl proposals --sites               Only list per-site proposals

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

site_filter=""
status_filter=""
scope="all"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --site=*)    site_filter="${1#--site=}" ;;
        --status=*)  status_filter="${1#--status=}" ;;
        --root)      scope="root" ;;
        --sites)     scope="sites" ;;
        -h|--help)
            cat <<EOF
Usage: pl proposals [options]

Options:
  --site=<name>      Show only proposals from a specific site
  --status=<state>   Filter by status field (proposed, in-progress, complete)
  --root             Only show root NWP docs/proposals/
  --sites            Only show per-site sites/*/docs/proposals/
EOF
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

# Print one proposal in tabular form: "scope  id  title  status  file"
_print_proposal() {
    local scope_label="$1" file="$2"
    local id title status
    id=$(basename "$file" .md)

    # Title: first markdown H1, fallback to filename
    title=$(grep -m1 '^# ' "$file" 2>/dev/null | sed 's/^# *//' || true)
    [[ -z "$title" ]] && title="$id"

    # Status: look for **Status:** or "status:" in YAML frontmatter
    status=$(grep -m1 -iE '^\s*\*?\*?status\*?\*?\s*[:=]' "$file" 2>/dev/null \
        | sed -E 's/^[^:=]*[:=]\s*//; s/[*_`]+//g; s/\s*$//' || true)
    [[ -z "$status" ]] && status="(unknown)"

    if [[ -n "$status_filter" ]]; then
        # Case-insensitive substring match
        local lc_status lc_filter
        lc_status=$(echo "$status" | tr '[:upper:]' '[:lower:]')
        lc_filter=$(echo "$status_filter" | tr '[:upper:]' '[:lower:]')
        [[ "$lc_status" == *"$lc_filter"* ]] || return 0
    fi

    printf "%-12s  %-30s  %-12s  %s\n" "$scope_label" "${id:0:30}" "${status:0:12}" "$title"
}

printf "%-12s  %-30s  %-12s  %s\n" "SCOPE" "ID" "STATUS" "TITLE"
printf "%-12s  %-30s  %-12s  %s\n" "-----" "--" "------" "-----"

# Root NWP proposals
if [[ "$scope" == "all" || "$scope" == "root" ]]; then
    if [[ -z "$site_filter" && -d "$PROJECT_ROOT/docs/proposals" ]]; then
        for f in "$PROJECT_ROOT"/docs/proposals/*.md; do
            [[ -f "$f" ]] || continue
            _print_proposal "nwp-root" "$f"
        done
    fi
fi

# Per-site proposals
if [[ "$scope" == "all" || "$scope" == "sites" ]]; then
    for site_dir in "$PROJECT_ROOT"/sites/*/; do
        [[ -d "$site_dir" ]] || continue
        local_name=$(basename "$site_dir")
        if [[ -n "$site_filter" && "$local_name" != "$site_filter" ]]; then
            continue
        fi
        if [[ -d "$site_dir/docs/proposals" ]]; then
            for f in "$site_dir/docs/proposals"/*.md; do
                [[ -f "$f" ]] || continue
                _print_proposal "$local_name" "$f"
            done
        fi
    done
fi
