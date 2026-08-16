#!/usr/bin/env bash
# scripts/commands/proposals.sh
#
# `pl proposals` — aggregate proposal documents across NWP root and all sites
# (F23 §7.4 / Phase 10).
#
# WHERE PER-SITE PROPOSALS ACTUALLY LIVE
# --------------------------------------
# Until 2026-08-16 this verb looked in `sites/<name>/docs/proposals/`. That
# directory exists for NO site and never has. `pl proposals --sites` therefore
# printed a header and nothing else, and exited 0 — 200 files across six sites,
# 55 distinct proposals, invisible to the only verb that aggregates them, with
# no hint that anything was wrong. docs/proposals/README.md described the same
# wrong path; CLAUDE.md had it right all along:
#
#   "Per-site proposals live inside each site's profile repo (e.g.
#    sites/<site>/dev/html/profiles/custom/<profile>/docs/proposals/)"
#
# The real shapes, measured:
#
#   sites/<site>/<env>/html/profiles/custom/<profile>/docs/proposals/**.md
#   sites/<site>/<env>/docs/proposals/**.md          (sites with no profile repo)
#   sites/<site>/docs/proposals/**.md                (the historical path; kept
#                                                     so a site that ever adopts
#                                                     it is not dropped)
#
# The globs are ENUMERATED rather than found by walking sites/, because sites/
# contains full Drupal/Moodle trees: a bare `find sites -name proposals` also
# turns up `*/node_modules/core-js/proposals` and `*/mod/data/preset/proposals`
# (a Moodle preset data directory), neither of which holds a proposal. Listing
# the shapes means the verb can also NAME what it searched when it finds
# nothing, which is the other half of the fix.
#
# DEV/STG DUPLICATION
# -------------------
# A site's dev and stg trees are copies, so every proposal was present twice
# (200 files -> 124 site-unique). Rows are deduplicated on the path with the
# environment segment removed, and dev wins, so a 33-proposal site lists 33
# rows and not 66.
#
# FINDING NOTHING IS A RESULT, AND IT IS REPORTED
# -----------------------------------------------
# An empty result exits 2 and names every path it searched. Exit 0 with no rows
# is precisely how this bug survived; the estate rule is that an empty input is
# never a silent pass.
#
# Usage:
#   pl proposals                       List all proposals
#   pl proposals --site=<name>         Only list proposals for one site
#   pl proposals --status=<status>     Filter by status (proposed/in-progress/complete)
#   pl proposals --root                Only list root NWP proposals
#   pl proposals --sites               Only list per-site proposals

set -uo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

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
  --sites            Only show per-site proposals

Per-site proposals are read from, in order:
  sites/<site>/<env>/html/profiles/custom/<profile>/docs/proposals/
  sites/<site>/<env>/docs/proposals/
  sites/<site>/docs/proposals/
where <env> is dev or stg. dev and stg hold copies of the same proposals, so
rows are deduplicated and dev wins.

Exit status:
  0  proposals were found and listed
  2  nothing found (or nothing matched the filters) — the paths searched are
     named on stderr. Finding nothing is reported, never a silent success.
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

# --- the per-site search space, enumerated ----------------------------------
# Printed verbatim when nothing is found, so "it searched the wrong place" can
# never again look the same as "there is nothing to find".
SITE_PATTERNS=(
    'sites/<site>/{dev,stg}/html/profiles/custom/<profile>/docs/proposals/**.md'
    'sites/<site>/{dev,stg}/docs/proposals/**.md'
    'sites/<site>/docs/proposals/**.md'
)

# Directories under a site that are code, not content. `mod/data/preset` is a
# Moodle preset bundle that genuinely contains a directory called `proposals`.
_is_excluded_path() {
    case "$1" in
        */node_modules/*|*/vendor/*|*/mod/data/preset/*) return 0 ;;
    esac
    return 1
}

# Every proposal directory for one site, in preference order (dev before stg).
_site_proposal_dirs() { # $1 = site dir
    local sd="$1" env d
    for env in dev stg; do
        for d in "$sd/$env"/html/profiles/custom/*/docs/proposals; do
            [[ -d "$d" ]] && printf '%s\n' "$d"
        done
        [[ -d "$sd/$env/docs/proposals" ]] && printf '%s\n' "$sd/$env/docs/proposals"
    done
    [[ -d "$sd/docs/proposals" ]] && printf '%s\n' "$sd/docs/proposals"
    return 0
}

# --- rendering ---------------------------------------------------------------
found_rows=0        # rows actually printed
found_files=0       # proposals discovered before --status filtering

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

    found_files=$((found_files + 1))

    if [[ -n "$status_filter" ]]; then
        local lc_status lc_filter
        lc_status=$(echo "$status" | tr '[:upper:]' '[:lower:]')
        lc_filter=$(echo "$status_filter" | tr '[:upper:]' '[:lower:]')
        [[ "$lc_status" == *"$lc_filter"* ]] || return 0
    fi

    printf "%-12s  %-30s  %-12s  %s\n" "$scope_label" "${id:0:30}" "${status:0:12}" "$title"
    found_rows=$((found_rows + 1))
}

printf "%-12s  %-30s  %-12s  %s\n" "SCOPE" "ID" "STATUS" "TITLE"
printf "%-12s  %-30s  %-12s  %s\n" "-----" "--" "------" "-----"

searched=()

# --- root NWP proposals ------------------------------------------------------
if [[ "$scope" == "all" || "$scope" == "root" ]]; then
    if [[ -z "$site_filter" ]]; then
        searched+=("$PROJECT_ROOT/docs/proposals")
        if [[ -d "$PROJECT_ROOT/docs/proposals" ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] || continue
                _print_proposal "nwp-root" "$f"
            done < <(find "$PROJECT_ROOT/docs/proposals" -type f -name '*.md' 2>/dev/null | sort)
        fi
    fi
fi

# --- per-site proposals ------------------------------------------------------
sites_with_rows=0
if [[ "$scope" == "all" || "$scope" == "sites" ]]; then
    for pat in "${SITE_PATTERNS[@]}"; do searched+=("$PROJECT_ROOT/$pat"); done

    for site_dir in "$PROJECT_ROOT"/sites/*/; do
        [[ -d "$site_dir" ]] || continue
        # The glob leaves a trailing slash. Strip it: every path below is built
        # as "$site_dir/…", and the doubled slash it otherwise produces survives
        # into the dedup key as a leading "/", which stopped the dev/stg prefix
        # from ever matching. That is how this printed 200 rows instead of 124.
        site_dir="${site_dir%/}"
        site_name=$(basename "$site_dir")
        if [[ -n "$site_filter" && "$site_name" != "$site_filter" ]]; then
            continue
        fi

        # Deduplicate dev against stg: the key is the path with the environment
        # segment stripped, so dev/.../P01.md and stg/.../P01.md collapse. dev is
        # visited first, so dev wins.
        declare -A _seen=()
        site_rows_before=$found_rows

        while IFS= read -r pdir; do
            [[ -n "$pdir" ]] || continue
            while IFS= read -r f; do
                [[ -f "$f" ]] || continue
                _is_excluded_path "$f" && continue
                rel="${f#"$site_dir"/}"
                key=$(printf '%s' "$rel" | sed -E 's#^(dev|stg)/##')
                [[ -n "${_seen[$key]:-}" ]] && continue
                _seen["$key"]=1
                _print_proposal "$site_name" "$f"
            done < <(find "$pdir" -type f -name '*.md' 2>/dev/null | sort)
        done < <(_site_proposal_dirs "$site_dir")

        unset _seen
        [[ "$found_rows" -gt "$site_rows_before" ]] && sites_with_rows=$((sites_with_rows + 1))
    done
fi

# --- the empty case is a result, and it is reported --------------------------
if [[ "$found_rows" -eq 0 ]]; then
    {
        echo
        if [[ "$found_files" -gt 0 && -n "$status_filter" ]]; then
            echo "No proposals matched --status='${status_filter}' (${found_files} proposal(s) were found and none carried that status)."
            echo "Run 'pl proposals' with no --status to see what statuses exist."
        else
            echo "No proposals found. Paths searched:"
            for p in "${searched[@]}"; do echo "  $p"; done
            [[ -n "$site_filter" ]] && echo "…restricted to --site='${site_filter}'."
            echo
            echo "An empty listing is reported, not returned as success: a verb that"
            echo "looks in the wrong place must not be indistinguishable from a tree"
            echo "that has nothing to list."
        fi
    } >&2
    exit 2
fi

if [[ "$scope" != "root" && "$sites_with_rows" -gt 0 ]]; then
    printf -- "-- %d proposal(s) listed across %d site(s), dev/stg duplicates collapsed --\n" \
        "$found_rows" "$sites_with_rows"
fi
exit 0
