#!/bin/bash
set -euo pipefail
################################################################################
# nwp-server status — LOCAL health as JSON (ADR-0024 "status (local JSON)").
#
# This is the prod-agent's status verb. Unlike the fleet `pl status`/`pl rag`
# (which read the whole fleet and, for server stats, call a distrusted SaaS API),
# this reports ONLY what can be read from THIS host, with no outbound network
# call at all. The control plane pulls this JSON; the prod host never pushes and
# never reaches another host to produce it.
#
# Everything here is local: hostname, kernel, load, uptime, disk headroom, and —
# for each --site-dir given — the checked-out git ref, DB reachability, Drupal
# bootstrap state, and maintenance mode (all best-effort via the site's own
# drush; a missing/down site degrades a field to null, never aborts).
#
# Usage:
#   nwp-server status [--site-dir DIR]... [--drush BIN] [--disk PATH]
#
#   --site-dir DIR   a deployed site root to inspect (repeatable)
#   --drush BIN      drush binary to use (default: <site-dir>/vendor/bin/drush)
#   --disk PATH      filesystem to report headroom for (default: /var/www, else /)
#   -h, --help       show this help
#
# Exit: 0 always (status is observational; a red field is data, not an error).
################################################################################
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

SITE_DIRS=()
DRUSH_OVERRIDE=""
DISK_PATH=""

while [ $# -gt 0 ]; do
    case "$1" in
        --site-dir)   SITE_DIRS+=("$2"); shift 2 ;;
        --site-dir=*) SITE_DIRS+=("${1#*=}"); shift ;;
        --drush)      DRUSH_OVERRIDE="$2"; shift 2 ;;
        --drush=*)    DRUSH_OVERRIDE="${1#*=}"; shift ;;
        --disk)       DISK_PATH="$2"; shift 2 ;;
        --disk=*)     DISK_PATH="${1#*=}"; shift ;;
        -h|--help)    sed -n '3,/^###/{/^###/d;p}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
    esac
done

# Pick a disk to report if not told.
if [ -z "$DISK_PATH" ]; then
    if [ -d /var/www ]; then DISK_PATH=/var/www; else DISK_PATH=/; fi
fi

NWP_SERVER_VERSION="${NWP_SERVER_VERSION:-0.1.0}"

# ── tiny JSON helpers (no jq dependency — prod-minimal) ──────────────────────
# Escape a bare string for embedding in JSON.
json_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '"%s"' "$s"
}
# Emit a JSON value: quote unless it is a bare number, boolean, or null.
json_val() {
    local v="$1"
    case "$v" in
        null|true|false) printf '%s' "$v" ;;
        ''|*[!0-9.-]*)   json_str "$v" ;;
        *)               printf '%s' "$v" ;;
    esac
}

# ── host-level facts (all local) ─────────────────────────────────────────────
HOST="$(hostname 2>/dev/null || echo unknown)"
KERNEL="$(uname -r 2>/dev/null || echo unknown)"
GENERATED="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
LOAD1="null"
[ -r /proc/loadavg ] && LOAD1="$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo null)"
UPTIME_S="null"
[ -r /proc/uptime ] && UPTIME_S="$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1 || echo null)"

# Disk headroom (kB free + used percent) for DISK_PATH.
DISK_FREE_KB="null"; DISK_USED_PCT="null"
if df_out="$(df -Pk "$DISK_PATH" 2>/dev/null | tail -1)"; then
    DISK_FREE_KB="$(awk '{print $4}' <<<"$df_out" 2>/dev/null || echo null)"
    DISK_USED_PCT="$(awk '{gsub(/%/,"",$5); print $5}' <<<"$df_out" 2>/dev/null || echo null)"
fi

# ── per-site inspection (best-effort, never fatal) ───────────────────────────
# Echoes one JSON object for the given site dir.
site_json() {
    local dir="$1"
    local name ref="null" db="null" bootstrap="null" maint="null"
    name="$(basename "$dir")"

    if [ ! -d "$dir" ]; then
        printf '{"name":%s,"path":%s,"present":false}' \
            "$(json_str "$name")" "$(json_str "$dir")"
        return 0
    fi

    # Checked-out git ref (short) if this is a repo.
    if git -C "$dir" rev-parse --short HEAD >/dev/null 2>&1; then
        ref="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)"
    fi

    # Best-effort drush probes. A short timeout keeps a hung site from stalling
    # the whole status report.
    local drush="$DRUSH_OVERRIDE"
    [ -z "$drush" ] && [ -x "$dir/vendor/bin/drush" ] && drush="$dir/vendor/bin/drush"
    if [ -n "$drush" ] && [ -x "$drush" ]; then
        local st
        if st="$(cd "$dir" && timeout 20 "$drush" status --fields=bootstrap,db-status --format=json 2>/dev/null)"; then
            # Parse without jq: presence of the strings is enough for a status probe.
            grep -qi 'Successful' <<<"$st" && bootstrap="true" || bootstrap="false"
            grep -qi 'Connected'  <<<"$st" && db="true" || db="false"
        fi
        local mm
        if mm="$(cd "$dir" && timeout 20 "$drush" state:get system.maintenance_mode 2>/dev/null | tr -d '[:space:]')"; then
            case "$mm" in 1) maint="true" ;; 0|'') maint="false" ;; *) maint="null" ;; esac
        fi
    fi

    printf '{"name":%s,"path":%s,"present":true,"git_ref":%s,"drupal_bootstrap":%s,"db_connected":%s,"maintenance_mode":%s}' \
        "$(json_str "$name")" "$(json_str "$dir")" \
        "$(json_val "$ref")" "$(json_val "$bootstrap")" "$(json_val "$db")" "$(json_val "$maint")"
}

# ── assemble the document ────────────────────────────────────────────────────
sites_arr=""
for d in "${SITE_DIRS[@]:-}"; do
    [ -z "$d" ] && continue
    obj="$(site_json "$d")"
    if [ -z "$sites_arr" ]; then sites_arr="$obj"; else sites_arr="$sites_arr,$obj"; fi
done

cat <<EOF
{
  "agent": "nwp-server",
  "version": $(json_str "$NWP_SERVER_VERSION"),
  "generated": $(json_str "$GENERATED"),
  "host": $(json_str "$HOST"),
  "kernel": $(json_str "$KERNEL"),
  "load1": $(json_val "$LOAD1"),
  "uptime_seconds": $(json_val "$UPTIME_S"),
  "disk": {
    "path": $(json_str "$DISK_PATH"),
    "free_kb": $(json_val "$DISK_FREE_KB"),
    "used_percent": $(json_val "$DISK_USED_PCT")
  },
  "sites": [${sites_arr}]
}
EOF
