#!/bin/bash
#
# nwp-daily-audit.sh — daily read-only dependency + upstream-drift audit for
#                      NWP-managed Drupal sites.
#
# WHAT THIS DOES (per site, strictly READ-ONLY — never attempts an update):
#   1. `composer audit  --no-dev --format=json`   — installed-package CVEs.
#   2. `composer outdated --direct --format=json` — direct deps with a newer
#      release available (regardless of CVE).
#   3. If the site declares an upstream package, fetch the upstream
#      `composer.json` (e.g. Open Social `main`) and compare its drupal/* and
#      webonyx/graphql-php constraints to ours (upstream-drift tracking).
#   4. Build a small "fingerprint" of the interesting findings.
#   5. Diff it against yesterday's baseline in $CACHE_DIR/baseline-<site>.txt.
#   6. If the fingerprint CHANGED: post one issue to the ops log queue (role
#      label ops/verifier-log; the real project is injected via
#      NWP_OPS_LOG_PROJECT). If UNCHANGED: stay silent (no "all clear" noise).
#   7. Log everything to $LOG_FILE.
#
# PROVENANCE: this script was pulled into version control from the build host's
# ~/bin/nwp-daily-audit (report P1 / ad-hoc gap). The build host was
# UNREACHABLE (kernel panic) at extraction time, so this file is a documented,
# lightly parameterised RECONSTRUCTION from the operator's `nwp-daily-audit`
# note (02:30 UTC; runs composer audit + outdated + upstream compare; posts to
# the ops log queue only on state change; configured 2026-05-22 as a P63
# follow-up). When the build host is back online, reconcile the on-host copy
# against this one (`ssh <build-host> cat ~/bin/nwp-daily-audit`) and keep this
# file canonical.
#
# NO HARDCODED SECRETS: the GitLab token is read from a 0600 token file (never
# passed on argv), exactly like the sibling verifier-say helper. Default token
# path and the GitLab host / project are all overridable via environment, and
# the built-in defaults are role-label placeholders (never a real host).
#
# CONFIGURATION (environment overrides; sensible defaults below):
#   NWP_ROOT                repo root            (default: resolved from script)
#   NWP_AUDIT_TOKEN_FILE    0600 file with the project-scoped PAT
#                                                (default: ~/.config/nwp-audit.token)
#   NWP_GITLAB_HOST         GitLab host          (default: <gitlab-host> placeholder)
#   NWP_OPS_LOG_PROJECT     namespace/project    (default: ops/verifier-log placeholder)
#   NWP_AUDIT_CACHE_DIR     baseline cache dir   (default: ~/.cache/nwp-daily-audit)
#   NWP_AUDIT_LOG           log file             (default: $NWP_ROOT/logs/daily-audit.log)
#   NWP_AUDIT_SITES         override the SITES array (space-separated entries,
#                           each "site-key:ddev-project-dir:upstream-pkg"; the
#                           third field is empty when there is no upstream)
#
# SITES ARRAY — the set of audited sites. Add a site by appending one entry of
# the form  site-key:ddev-project-dir:upstream-pkg  (upstream-pkg empty => no
# upstream comparison). The default matches what the build host audited at
# extraction time (nwc-dev, tracked against goalgorilla/open_social).
#
# WIRING (schedule it):
#   Run daily at 02:30 UTC on the CI/build host via `pl schedule`. The
#   `pl schedule` command manages NWP cron entries; add an audit entry with:
#
#     30 2 * * *  /path/to/nwp/scripts/nwp-daily-audit.sh >> /path/to/nwp/logs/daily-audit.log 2>&1
#
#   (See docs — "Wiring via pl schedule" — at the bottom of this file for the
#   canonical crontab line and the token/GitLab prerequisites.)
#
# THREAT MODEL: the audit token is scoped Developer/api on the ops-log project
# ONLY. It can post + close its own issues and cannot touch any other project
# or prod. This script performs NO writes to any site; it only reads composer
# state and fetches a public upstream composer.json over HTTPS.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths / config
# ---------------------------------------------------------------------------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
NWP_ROOT="${NWP_ROOT:-$( cd "$SCRIPT_DIR/.." && pwd )}"

# Defaults are role-label placeholders (mirrors the verifier-say helper): the real
# GitLab host and ops-log project are injected via NWP_GITLAB_HOST /
# NWP_OPS_LOG_PROJECT in the deployment's private config, never hardcoded here.
AUDIT_TOKEN_FILE="${NWP_AUDIT_TOKEN_FILE:-$HOME/.config/nwp-audit.token}"
GITLAB_HOST="${NWP_GITLAB_HOST:-<gitlab-host>}"
OPS_LOG_PROJECT="${NWP_OPS_LOG_PROJECT:-ops/verifier-log}"
CACHE_DIR="${NWP_AUDIT_CACHE_DIR:-$HOME/.cache/nwp-daily-audit}"
LOG_FILE="${NWP_AUDIT_LOG:-$NWP_ROOT/logs/daily-audit.log}"

# URL-encode the namespace/project slash for the GitLab API.
PROJECT_PATH="${OPS_LOG_PROJECT//\//%2F}"
API="https://${GITLAB_HOST}/api/v4/projects/${PROJECT_PATH}/issues"

# ---------------------------------------------------------------------------
# SITES array — "site-key:ddev-project-dir:upstream-pkg"
# ---------------------------------------------------------------------------
if [[ -n "${NWP_AUDIT_SITES:-}" ]]; then
    # shellcheck disable=SC2206
    SITES=( ${NWP_AUDIT_SITES} )
else
    SITES=(
        "nwc-dev:${NWP_ROOT}/sites/nwc/dev:goalgorilla/open_social"
    )
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s %s\n' "$ts" "$*" >> "$LOG_FILE"
    printf '%s %s\n' "$ts" "$*"
}

# Read a composer command's JSON output from inside a site dir. Echoes JSON (or
# empty on failure). Never fails the whole run for one site.
run_composer() {
    local dir="$1"; shift
    ( cd "$dir" 2>/dev/null && composer "$@" 2>/dev/null ) || true
}

# Fetch the upstream composer.json (public HTTPS, read-only) for drift compare.
# Echoes JSON body or empty.
fetch_upstream_composer() {
    local pkg="$1"
    [[ -n "$pkg" ]] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    # Packagist metadata gives the canonical composer constraints for a package.
    curl -fsSL --max-time 20 "https://repo.packagist.org/p2/${pkg}.json" 2>/dev/null || true
}

# Build the fingerprint of interesting findings for one site. Deterministic
# (sorted) so an unchanged state produces an identical baseline day-to-day.
site_fingerprint() {
    local dir="$1" upstream="$2"
    local audit_json outdated_json upstream_json

    audit_json="$(run_composer "$dir" audit --no-dev --format=json)"
    outdated_json="$(run_composer "$dir" outdated --direct --format=json)"
    upstream_json="$(fetch_upstream_composer "$upstream")"

    {
        # ADV <pkg> <advisory-id> — new composer audit findings.
        # NOTE: the JSON is passed via an env var, NOT stdin: `python3 -` already
        # consumes stdin to read the program from the heredoc, so a piped body
        # would be swallowed. Same discipline for OUTDATED and UPSTREAM below.
        if [[ -n "$audit_json" ]]; then
            AUDIT_JSON="$audit_json" python3 - <<'PY' 2>/dev/null || true
import json, os, sys
try:
    data = json.loads(os.environ["AUDIT_JSON"])
except Exception:
    sys.exit(0)
advs = data.get("advisories", {}) or {}
for pkg, items in sorted(advs.items()):
    if isinstance(items, dict):
        items = items.values()
    for a in items:
        aid = a.get("advisoryId") or a.get("cve") or a.get("title", "")
        print(f"ADV {pkg} {aid}")
PY
        fi

        # OUTDATED <pkg> <current> -> <latest> — newer releases available.
        if [[ -n "$outdated_json" ]]; then
            OUTDATED_JSON="$outdated_json" python3 - <<'PY' 2>/dev/null || true
import json, os, sys
try:
    data = json.loads(os.environ["OUTDATED_JSON"])
except Exception:
    sys.exit(0)
for p in data.get("installed", []):
    name = p.get("name", "")
    cur = p.get("version", "")
    latest = p.get("latest", "")
    if latest and latest != cur:
        print(f"OUTDATED {name} {cur} -> {latest}")
PY
        fi

        # UPSTREAM <pkg>: ours=X upstream=Y — Open Social main vs our constraint.
        if [[ -n "$upstream_json" && -f "$dir/composer.json" ]]; then
            UPSTREAM_JSON="$upstream_json" OUR_COMPOSER="$dir/composer.json" \
                python3 - <<'PY' 2>/dev/null || true
import json, os, sys
try:
    up = json.loads(os.environ["UPSTREAM_JSON"])
    with open(os.environ["OUR_COMPOSER"]) as fh:
        ours = json.load(fh)
except Exception:
    sys.exit(0)
# Packagist p2 payload: packages -> {name: [versions...]}; take the first
# (most recent) version's require map as "upstream".
up_req = {}
for _name, versions in (up.get("packages", {}) or {}).items():
    if versions:
        up_req = versions[0].get("require", {}) or {}
    break
our_req = ours.get("require", {}) or {}
watch = lambda k: k.startswith("drupal/") or k == "webonyx/graphql-php"
for k in sorted(set(our_req) | set(up_req)):
    if not watch(k):
        continue
    o = our_req.get(k)
    u = up_req.get(k)
    if o != u:
        print(f"UPSTREAM {k}: ours={o} upstream={u}")
PY
        fi
    } | sort -u
}

# Post an issue to the ops log queue. Token read from the 0600 file only — it
# never lands on argv/ps. Body carries the fingerprint diff.
post_issue() {
    local title="$1" body="$2"
    if [[ ! -r "$AUDIT_TOKEN_FILE" ]]; then
        log "WARN: cannot read audit token at $AUDIT_TOKEN_FILE — NOT posting (findings changed for: $title)"
        return 1
    fi
    command -v curl >/dev/null 2>&1 || { log "WARN: curl missing — cannot post"; return 1; }

    local host ts preamble
    host="$(hostname)"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    preamble="host: ${host}"$'\n'"time: ${ts}"$'\n\n'

    local token; token="$(cat "$AUDIT_TOKEN_FILE")"
    local resp
    resp="$(curl -sS --fail-with-body -X POST \
        -H "PRIVATE-TOKEN: ${token}" \
        --data-urlencode "title=${title}" \
        --data-urlencode "description=${preamble}${body}" \
        "${API}" 2>&1)" || { log "WARN: POST failed: $resp"; return 1; }
    token=""
    log "posted: $title"
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    mkdir -p "$CACHE_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null || true

    command -v composer >/dev/null 2>&1 || { log "ERROR: composer not found — aborting"; exit 1; }

    local entry site dir upstream fp baseline_file baseline diff
    for entry in "${SITES[@]}"; do
        IFS=':' read -r site dir upstream <<< "$entry"
        [[ -n "$site" && -n "$dir" ]] || { log "WARN: malformed SITES entry '$entry' — skipping"; continue; }

        if [[ ! -d "$dir" ]]; then
            log "WARN: site dir not found for '$site': $dir — skipping"
            continue
        fi

        log "auditing $site ($dir)${upstream:+ upstream=$upstream}"
        fp="$(site_fingerprint "$dir" "$upstream")"

        baseline_file="$CACHE_DIR/baseline-${site}.txt"
        baseline=""
        [[ -f "$baseline_file" ]] && baseline="$(cat "$baseline_file")"

        if [[ "$fp" == "$baseline" ]]; then
            log "$site: unchanged (silent)"
            continue
        fi

        log "$site: state CHANGED — posting"
        diff="$(diff <(printf '%s\n' "$baseline") <(printf '%s\n' "$fp") || true)"
        if post_issue "daily-audit: ${site} dependency/upstream state changed" \
            "Fingerprint diff (\`+\` = new, \`-\` = gone):"$'\n\n'"\`\`\`diff"$'\n'"${diff}"$'\n'"\`\`\`"; then
            # Only advance the baseline once the notification is out, so a
            # failed post is retried tomorrow rather than silently swallowed.
            printf '%s\n' "$fp" > "$baseline_file"
        else
            log "$site: post failed — baseline NOT advanced (will retry tomorrow)"
        fi
    done

    log "done"
}

main "$@"

# ===========================================================================
# Wiring via `pl schedule` + the SITES array
# ===========================================================================
#
# 1. TOKEN (dev side + host side)
#    - Registry key: gitlab.met_audit_token in the deployment's .secrets.yml
#      (Developer/api scoped to the ops-log project ONLY; consult `pl secrets
#      status`/`pl secrets steps` for the entry, and rotate via `pl secrets
#      rotate` before its recorded expiry).
#    - On the audit host, install it 0600:
#        umask 077 && printf '%s\n' <the-token> > ~/.config/nwp-audit.token
#      (or point NWP_AUDIT_TOKEN_FILE at another path).
#
# 2. SCHEDULE (02:30 UTC daily) — add a cron line. `pl schedule` owns NWP cron
#    entries; the canonical line this script wants is:
#
#        30 2 * * *  <nwp-root>/scripts/nwp-daily-audit.sh \
#            >> <nwp-root>/logs/daily-audit.log 2>&1
#
#    Substitute the deployment's repo root for <nwp-root>. (If/when
#    `pl schedule` grows a first-class audit verb, migrate this hand-added line
#    to it; today it is a plain user-crontab entry alongside the sweep entry.)
#
# 3. ADD A SITE — append one entry to the SITES array above, or set
#    NWP_AUDIT_SITES for a one-off run:
#        site-key:ddev-project-dir:upstream-pkg
#    e.g.  "avc-dev:${NWP_ROOT}/sites/avc/dev:"     # no upstream to compare
#
# 4. TRIAGE — when the ops log queue shows a `daily-audit:` issue, the body has
#    unified diff of the fingerprint:
#      ADV <pkg> <id>            new composer audit finding (cross-ref the
#                                dependency-refresh-cadence severity table)
#      OUTDATED <pkg> <a> -> <b> newer release exists (major bumps tracked apart)
#      UPSTREAM <pkg>: ...       Open Social main constraint differs from ours
# ===========================================================================
