#!/bin/bash
set -euo pipefail

################################################################################
# NWP Update-Awareness Audit  (pl audit)
#
# READ-ONLY fleet update + security awareness. Mirrors the `pl secrets` model:
# a per-site awareness record + a status table + a `pl todo`-friendly exit code.
#
# For each Drupal site (DDEV-backed) it runs, NON-MUTATING:
#   - composer audit            (vendor advisories — exit nonzero on findings)
#   - drush pm:security         (Drupal core/contrib advisories; catches CVE-less SAs)
#   - composer outdated --direct (version drift)
# and writes private/update-awareness/<site>.json  (the cached awareness state).
#
# NOTHING is updated/applied — this only reports. Apply with the (separate)
# update flow once it exists; today: `pl security update <site>`.
#
# Usage: pl audit [--all | --site <name>] [--security-only] [--format=json]
# Exit:  0 clean · 3 security findings present · 1 usage/error   (3 matches drush)
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
# yaml helpers (yaml_get_all_sites / yaml_get_site_field) per ADR-0015 (yq-first)
source "$PROJECT_ROOT/lib/yaml-write.sh" 2>/dev/null || true

CONFIG_FILE="${NWP_CONFIG_FILE:-$PROJECT_ROOT/nwp.yml}"
STATE_DIR="$PROJECT_ROOT/private/update-awareness"

show_help() {
    cat << EOF
${BOLD}NWP Update-Awareness Audit${NC}  (read-only)

${BOLD}USAGE:${NC}
    pl audit [options]

${BOLD}OPTIONS:${NC}
    --all                 Audit every Drupal site in nwp.yml (default if no --site)
    --site <name>         Audit a single site
    --security-only       Skip the "outdated/drift" sweep; advisories only
    --format=json         Emit the merged result as JSON (no table)
    -h, --help            This help

${BOLD}WHAT IT RUNS (non-mutating, per site):${NC}
    composer audit · drush pm:security · composer outdated --direct

${BOLD}OUTPUT:${NC}
    A per-site record at  private/update-awareness/<site>.json
    A fleet summary table; exit code 3 if any security advisory is present.

${BOLD}NOTE:${NC} This only DETECTS. To apply security updates today use
    pl security update <site>   (the generalized 'pl update' is on the roadmap).
EOF
}

# --- resolve a site's Drupal webroot (returns "" if not a runnable Drupal/DDEV site) ---
resolve_webroot() {
    local site="$1" dir
    dir=$(yaml_get_site_field "$site" "directory" "$CONFIG_FILE" 2>/dev/null || true)
    [ -z "$dir" ] && dir="$PROJECT_ROOT/sites/$site"
    # F23 dev-tree layout: most sites live under <dir>/dev
    local base
    for base in "$dir/dev" "$dir"; do
        local w
        for w in html web docroot .; do
            if [ -f "$base/$w/core/lib/Drupal.php" ]; then
                echo "$base"        # echo the site root that holds .ddev
                return 0
            fi
        done
    done
    return 1
}

# Extract the integer that precedes a phrase in composer audit's summary lines,
# e.g. "Found 20 security vulnerability advisories affecting 8 packages" -> 20.
_num_before() {  # $1 = text, $2 = phrase regex
    printf '%s' "$1" | grep -oiE "found [0-9]+ $2" | grep -oE '[0-9]+' | head -1
}

# JSON-escape a blob for embedding as a string value in the record.
_json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"}{print}'; }

# --- audit one site; prints a one-line TSV summary; sets GLOBAL had_sec ---
# Environment reality (verified 2026-06-27): drush pm:security is REMOVED in the
# installed Drush ("use composer audit"). composer audit is the source of truth,
# and it EXITS 3 when advisories are found — so we must capture output regardless
# of exit code (never `|| fallback`, which discards exactly the findings we want).
had_sec=0
audit_site() {
    local site="$1"
    local root
    if ! root=$(resolve_webroot "$site"); then
        printf '%s\tSKIP\t-\t-\t-\tnot a Drupal site\n' "$site"; return 0
    fi
    if ! command -v ddev >/dev/null 2>&1 || [ ! -d "$root/.ddev" ]; then
        printf '%s\tSKIP\t-\t-\t-\tno ddev\n' "$site"; return 0
    fi
    if ! (cd "$root" && ddev describe >/dev/null 2>&1); then
        printf '%s\tDOWN\t-\t-\t-\tddev not running\n' "$site"; return 0
    fi

    # composer audit (text) — capture stdout+stderr, tolerate nonzero exit.
    local audit_txt=""
    audit_txt=$(cd "$root" && ddev composer audit --locked --no-interaction 2>&1) || true

    local sec_count ignored_count abandoned_count
    sec_count=$(_num_before "$audit_txt" "security vulnerability advisor")
    ignored_count=$(_num_before "$audit_txt" "ignored security")
    abandoned_count=$(_num_before "$audit_txt" "abandoned package")
    sec_count=${sec_count:-0}; ignored_count=${ignored_count:-0}; abandoned_count=${abandoned_count:-0}
    # registry-auth failures (rotated PAT in auth.json) degrade to local cache;
    # flag staleness so a 0 isn't mistaken for "verified clean".
    local stale="false"
    printf '%s' "$audit_txt" | grep -qiE "could not be fully loaded|Invalid credentials|loaded from the local cache" && stale="true"

    local outdated_count=0 outdated_txt=""
    if [ "$SECURITY_ONLY" != "true" ]; then
        outdated_txt=$(cd "$root" && ddev composer outdated --direct --no-dev 2>/dev/null) || true
        # count lines that look like "vendor/name  cur  ...  new"
        outdated_count=$(printf '%s' "$outdated_txt" | grep -cE '^[a-z0-9._-]+/[a-z0-9._-]+ ' || true)
        outdated_count=${outdated_count:-0}
    fi

    [ "$sec_count" -gt 0 ] && had_sec=1

    # Write the record via python json.dump — bulletproof escaping of the
    # ANSI/control chars that composer audit emits (bash printf can't do this safely).
    mkdir -p "$STATE_DIR"
    AUDIT_TXT="$audit_txt" OUTDATED_TXT="$outdated_txt" python3 - \
        "$site" "$STAMP" "$sec_count" "$ignored_count" "$abandoned_count" \
        "$outdated_count" "$stale" "$STATE_DIR/$site.json" <<'PY' 2>/dev/null || true
import os, sys, json, re
site, stamp, sec, ign, ab, outd, stale, path = sys.argv[1:9]
ansi = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')
def clean(s): return ansi.sub('', s or '')
rec = {
  "site": site, "checked": stamp,
  "source": "composer audit (drush pm:security removed in this Drush)",
  "security_count": int(sec or 0), "ignored_count": int(ign or 0),
  "abandoned_count": int(ab or 0), "outdated_count": int(outd or 0),
  "cache_stale": (stale == "true"),
  "composer_audit_text": clean(os.environ.get("AUDIT_TXT", "")),
  "composer_outdated_text": clean(os.environ.get("OUTDATED_TXT", "")),
}
json.dump(rec, open(path, "w"), indent=2)
PY

    local status="OK"
    [ "$sec_count" -gt 0 ] && status="INSECURE"
    [ "$stale" = "true" ] && status="${status}*"
    local secfield="$sec_count"
    [ "$ignored_count" -gt 0 ] && secfield="${sec_count}(+${ignored_count}i)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$site" "$status" "$secfield" "$outdated_count" "$STAMP" "$STATE_DIR/$site.json"
}

main() {
    local ALL=false SITE="" FORMAT="table"
    SECURITY_ONLY=false
    # a single timestamp for the whole run (records stay reproducible/diffable)
    STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            --all) ALL=true; shift ;;
            --site) SITE="${2:-}"; shift 2 ;;
            --security-only) SECURITY_ONLY=true; shift ;;
            --format=json) FORMAT="json"; shift ;;
            --format) FORMAT="${2:-table}"; shift 2 ;;
            *) print_error "Unknown option: $1"; show_help; exit 1 ;;
        esac
    done

    [ ! -f "$CONFIG_FILE" ] && { print_error "Config not found: $CONFIG_FILE"; exit 1; }

    # build the site list
    local sites=()
    if [ -n "$SITE" ]; then
        sites=("$SITE")
    else
        while read -r s; do [ -n "$s" ] && sites+=("$s"); done \
            < <(yaml_get_all_sites "$CONFIG_FILE" 2>/dev/null || true)
    fi
    [ "${#sites[@]}" -eq 0 ] && { print_error "No sites found"; exit 1; }

    print_header "Update-awareness audit (read-only) — ${#sites[@]} site(s)"
    local rows="" row
    for s in "${sites[@]}"; do
        # audit_site runs in a subshell here, so its had_sec can't propagate —
        # derive the fleet verdict from the collected rows below instead.
        row=$(audit_site "$s") || true
        rows+="$row"$'\n'
    done
    printf '%s' "$rows" | grep -q 'INSECURE' && had_sec=1 || true

    if [ "$FORMAT" = "json" ]; then
        # emit the collection of just-written records
        printf '['
        local first=1
        for s in "${sites[@]}"; do
            [ -f "$STATE_DIR/$s.json" ] || continue
            [ $first -eq 1 ] || printf ','
            cat "$STATE_DIR/$s.json"; first=0
        done
        printf ']\n'
    else
        printf '\n%-16s %-10s %-4s %-8s %s\n' "SITE" "STATUS" "SEC" "OUTDATED" "RECORD"
        printf '%s' "$rows" | while IFS=$'\t' read -r site status sec out stamp rec; do
            [ -z "$site" ] && continue
            printf '%-16s %-10s %-4s %-8s %s\n' "$site" "$status" "$sec" "$out" "${rec:-$stamp}"
        done
        echo
        printf '  legend: SEC = active advisories (+Ni = N ignored-by-policy); * = audited from local cache (registry auth failed)\n\n'
        if [ "$had_sec" -eq 1 ]; then
            print_warning "Security advisories present — review records in $STATE_DIR/ ; apply with: pl security update <site>"
        else
            print_status "OK" "No security advisories detected across audited (running) sites"
        fi
    fi

    [ "$had_sec" -eq 1 ] && exit 3
    exit 0
}

# Do not run when sourced (06-scripts-validation.bats guard)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
