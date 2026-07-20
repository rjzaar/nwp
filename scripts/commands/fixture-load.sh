#!/bin/bash
set -uo pipefail
################################################################################
# pl fixture-load — load a sanitised Moodle fixture bundle into a dev/stg site
# (ADR-0032 Flow A, consumer glue). Runs on the DEV/STG tier, NEVER on prod.
#
# Composes the tested loader core (lib/moodle-fixture-load.sh) with the
# environment steps it deliberately leaves out: FETCH the bundle over HTTPS with
# a read-only package token, IMPORT the inner db.sql.gz via `ddev import-db`, and
# (best-effort) PRUNE orphaned mdl_files rows with `moosh file-dbcheck`.
#
# Pipeline (fail-closed): fetch/locate bundle → INDEPENDENT PII gate + extract
# db.sql.gz → ddev import-db → rebuild EMPTY moodledata scaffold → moosh prune.
# The gate runs before the DB is imported, so raw PII can never land on dev.
#
# Usage:
#   pl fixture-load --site NAME  [--url URL | --bundle FILE] [--token-file FILE]
#                   [--project-dir DIR] [--dataroot DIR] [--allowlist FILE]
#                   [--dry-run]
#
#   --site NAME        target dev/stg Moodle site (resolves project-dir + dataroot)
#   --bundle FILE      use a local bundle instead of fetching
#   --url URL          HTTPS URL of the published <site>-sanitized-*.tar.gz bundle
#   --token-file FILE  0600 file with the READ-ONLY package token (for --url)
#   --project-dir DIR  DDEV project dir to run `ddev import-db` in (override)
#   --dataroot DIR     target moodledata to scaffold (override; else from config.php)
#   --allowlist FILE   extra per-site PII-gate allowlist
#   --dry-run          print the plan; fetch/import/scaffold nothing
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$( cd "$SCRIPT_DIR/../.." && pwd )}"
# ui.sh first (provides print_*); common.sh requires it, per lib/common.sh header.
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/ui.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/moodle-fixture-load.sh"

die() { print_error "$*"; exit 1; }

SITE="" URL="" BUNDLE="" TOKEN_FILE="" PROJECT_DIR="" DATAROOT="" ALLOWLIST="" DRY=n
while [ $# -gt 0 ]; do
    case "$1" in
        --site) SITE="$2"; shift 2 ;;                 --site=*) SITE="${1#*=}"; shift ;;
        --url) URL="$2"; shift 2 ;;                   --url=*) URL="${1#*=}"; shift ;;
        --bundle) BUNDLE="$2"; shift 2 ;;             --bundle=*) BUNDLE="${1#*=}"; shift ;;
        --token-file) TOKEN_FILE="$2"; shift 2 ;;     --token-file=*) TOKEN_FILE="${1#*=}"; shift ;;
        --project-dir) PROJECT_DIR="$2"; shift 2 ;;   --project-dir=*) PROJECT_DIR="${1#*=}"; shift ;;
        --dataroot) DATAROOT="$2"; shift 2 ;;         --dataroot=*) DATAROOT="${1#*=}"; shift ;;
        --allowlist) ALLOWLIST="$2"; shift 2 ;;       --allowlist=*) ALLOWLIST="${1#*=}"; shift ;;
        --dry-run) DRY=y; shift ;;
        -h|--help) sed -n '3,/^###/{/^###/d;p}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

# ── Resolve the target dev/stg site → project dir + Moodle root + dataroot ─────
# Explicit flags win; otherwise resolve from --site via the project resolver.
if [ -z "$PROJECT_DIR" ] && [ -n "$SITE" ]; then
    PROJECT_DIR="$(resolve_project "$SITE" 2>/dev/null || true)"
fi
[ -n "$PROJECT_DIR" ] || die "cannot resolve target project dir — pass --project-dir or a valid --site"
[ -d "$PROJECT_DIR" ] || die "project dir does not exist: $PROJECT_DIR"

# Confirm this is a Moodle target (version.php) so we never import a Moodle dump
# into a Drupal site or vice versa.
MOODLE_ROOT="$PROJECT_DIR"
[ -f "$MOODLE_ROOT/version.php" ] || [ -f "$MOODLE_ROOT/web/version.php" ] \
    || die "target is not a Moodle root (no version.php): $PROJECT_DIR — fixture-load is Moodle-only"
[ -f "$MOODLE_ROOT/web/version.php" ] && MOODLE_ROOT="$MOODLE_ROOT/web"

# Resolve the target dataroot: explicit → config.php $CFG->dataroot → sibling default.
if [ -z "$DATAROOT" ]; then
    if [ -f "$MOODLE_ROOT/config.php" ] && command -v php >/dev/null 2>&1; then
        DATAROOT="$(php -d error_reporting=0 -d display_errors=0 -r '
            define("CLI_SCRIPT", true); define("ABORT_AFTER_CONFIG", true);
            require($argv[1]); echo isset($CFG->dataroot) ? $CFG->dataroot : "";' \
            "$MOODLE_ROOT/config.php" 2>/dev/null || true)"
    fi
    [ -n "$DATAROOT" ] || DATAROOT="${PROJECT_DIR%/}/moodledata"
fi

print_header "pl fixture-load — ${SITE:-$PROJECT_DIR}"
print_info "project-dir: $PROJECT_DIR"
print_info "dataroot:    $DATAROOT"
print_info "source:      ${BUNDLE:-${URL:-<none>}}"

[ -n "$BUNDLE" ] || [ -n "$URL" ] || die "provide --bundle FILE or --url URL"

if [ "$DRY" = y ]; then
    print_header "Dry run — nothing fetched, imported, or scaffolded"
    echo "Would, in order:"
    [ -n "$URL" ] && echo "  0. fetch bundle from $URL (read-only token)"
    echo "  1. independent PII gate + extract db.sql.gz (fail-closed)"
    echo "  2. ddev import-db --file=db.sql.gz  (in $PROJECT_DIR)"
    echo "  3. rebuild EMPTY moodledata scaffold at $DATAROOT"
    echo "  4. moosh file-dbcheck (best-effort) to prune orphaned mdl_files rows"
    exit 0
fi

# ── Fetch (read-only token) if a URL was given ────────────────────────────────
TMP_DL=""
cleanup(){ [ -n "$TMP_DL" ] && [ -f "$TMP_DL" ] && rm -f "$TMP_DL"; }
trap cleanup EXIT
if [ -n "$URL" ]; then
    case "$URL" in https://*) : ;; *) die "refusing non-HTTPS --url: $URL" ;; esac
    command -v curl >/dev/null 2>&1 || die "curl not found — required to fetch"
    TMP_DL="$(mktemp --suffix=.tar.gz)"
    curl_auth=()
    if [ -n "$TOKEN_FILE" ]; then
        [ -f "$TOKEN_FILE" ] || die "token file not found: $TOKEN_FILE"
        tok="$(tr -d '\r\n' < "$TOKEN_FILE")"
        [ -n "$tok" ] || die "token file is empty: $TOKEN_FILE"
        curl_auth=(--header "Deploy-Token: $tok")
    fi
    print_info "fetching bundle…"
    code="$(curl -s -o "$TMP_DL" -w '%{http_code}' --max-time 300 "${curl_auth[@]}" "$URL")"
    [ "$code" -ge 200 ] && [ "$code" -lt 300 ] || die "fetch failed (HTTP $code)"
    BUNDLE="$TMP_DL"
fi
[ -f "$BUNDLE" ] || die "bundle not found: $BUNDLE"

# ── Import wrapper: the tested orchestrator calls this with the db.sql.gz path ─
_fixture_do_import() { ( cd "$PROJECT_DIR" && ddev import-db --file="$1" ); }

# ── Orchestrate: gate + extract → import → empty scaffold (all fail-closed) ────
if ! moodle_fixture_load "$BUNDLE" "$DATAROOT" _fixture_do_import "$ALLOWLIST"; then
    die "fixture load FAILED — target may be partially loaded; do not treat as clean"
fi

# ── Best-effort orphan prune (moosh is optional; else just hint) ──────────────
if ( cd "$PROJECT_DIR" && ddev exec which moosh ) >/dev/null 2>&1; then
    print_info "pruning orphaned mdl_files rows (moosh file-dbcheck)…"
    ( cd "$PROJECT_DIR" && ddev exec moosh file-dbcheck ) || \
        print_warning "moosh file-dbcheck reported issues — review manually"
else
    print_hint "moosh not found in the target — run 'moosh file-dbcheck' manually to prune orphaned mdl_files rows"
fi

print_success "fixture loaded into ${SITE:-$PROJECT_DIR} (sanitised DB + empty moodledata)"
