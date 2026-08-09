#!/bin/bash
set -uo pipefail
################################################################################
# nwp-server publish — snapshot → sanitize → fail-closed PII gate → publish the
# sanitized artifact to THIS host's OWN repo (ADR-0024 "publish" capability).
#
# This REPLACES the old wiring where the `publish` verb pointed at the build-tier
# registry uploader (scripts/commands/publish.sh) — which required a full-`api`
# GitLab PAT on prod and never ran the PII gate, violating the ADR-0024 three-key
# ledger. This capability instead:
#   1. runs the site's sanitizer (lib/sanitizers/<site>.sh, mayo.sh model): dumps
#      the LIVE DB read-only into a throwaway scratch copy, sanitises the scratch
#      copy, exports a sanitized dump. Raw user data never leaves this host.
#   2. runs the INDEPENDENT fail-closed PII gate (lib/pii-gate.sh) over the dump —
#      ANY residual PII (or any error) ABORTS the publish. Defence in depth.
#   3. uploads the sanitized dump to this host's OWN package registry using a
#      WRITE-ONLY deploy token (ledger key #2) — never an `api` PAT, never a key
#      that reaches another host or the control plane.
#
# Credentials used: ONLY a write-only deploy token (read from a 0600 file). No
# PAT. No control-plane creds.
#
# Usage:
#   nwp-server publish --site NAME --site-dir DIR \
#       --publish-url URL --publish-token-file FILE \
#       [--sanitizer PATH] [--allowlist FILE] [--drush PATH] [--execute]
#
#   --site NAME             logical site name (resolves lib/sanitizers/<site>.sh)
#   --site-dir DIR          deployed Drupal root the sanitizer reads
#   --publish-url URL       HTTPS base URL of the generic package to PUT into
#                           (…/packages/generic/<pkg>/<version>/) — the artifact
#                           filename is appended automatically
#   --publish-token-file F  0600 file holding the WRITE-ONLY deploy token
#   --sanitizer PATH        override the sanitizer (default: lib/sanitizers/<site>.sh)
#   --allowlist FILE        extra per-site PII allowlist for the gate
#   --drush PATH            drush binary (default: <site-dir>/vendor/bin/drush)
#   --execute               actually sanitize + publish (default: dry-run plan only)
#   -h, --help              show this help
#
# Exit: 0 = published (or dry-run OK); non-zero on any sanitize / PII-gate / upload
#       failure. FAIL-CLOSED: an unsanitized or unverifiable dump is never published.
################################################################################
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$( cd "$SCRIPT_DIR/../.." && pwd )}"
NWP_ROOT="${NWP_ROOT:-$PROJECT_ROOT}"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/ui.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/pii-gate.sh"

die() { print_error "$*"; exit 1; }

SITE="" SITE_DIR="" PUBLISH_URL="" TOKEN_FILE="" SANITIZER="" ALLOWLIST="" DRUSH="" EXECUTE=n
while [ $# -gt 0 ]; do
    case "$1" in
        --site) SITE="$2"; shift 2 ;;             --site=*) SITE="${1#*=}"; shift ;;
        --site-dir) SITE_DIR="$2"; shift 2 ;;     --site-dir=*) SITE_DIR="${1#*=}"; shift ;;
        --publish-url) PUBLISH_URL="$2"; shift 2 ;; --publish-url=*) PUBLISH_URL="${1#*=}"; shift ;;
        --publish-token-file) TOKEN_FILE="$2"; shift 2 ;; --publish-token-file=*) TOKEN_FILE="${1#*=}"; shift ;;
        --sanitizer) SANITIZER="$2"; shift 2 ;;   --sanitizer=*) SANITIZER="${1#*=}"; shift ;;
        --allowlist) ALLOWLIST="$2"; shift 2 ;;   --allowlist=*) ALLOWLIST="${1#*=}"; shift ;;
        --drush) DRUSH="$2"; shift 2 ;;           --drush=*) DRUSH="${1#*=}"; shift ;;
        --execute|-y) EXECUTE=y; shift ;;         --dry-run) EXECUTE=n; shift ;;
        -h|--help) sed -n '3,/^###/{/^###/d;p}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

[ -n "$SITE" ]     || die "--site NAME is required"
[ -n "$SITE_DIR" ] || die "--site-dir DIR is required"
[ -n "$PUBLISH_URL" ]  || die "--publish-url URL is required"
[ -n "$TOKEN_FILE" ]   || die "--publish-token-file FILE is required"
case "$PUBLISH_URL" in https://*) : ;; *) die "refusing non-HTTPS --publish-url: $PUBLISH_URL" ;; esac

# Resolve the sanitizer, fail-closed: never publish a site with no reviewed sanitizer.
# ops#326: per-instance sanitizers live in the PRIVATE OVERLAY repo
# (private/sanitizers/), searched after the shipped lib/sanitizers/.
SANITIZER_OVERLAY_DIR="${NWP_SANITIZER_OVERLAY_DIR:-$NWP_ROOT/private/sanitizers}"
if [ -z "$SANITIZER" ]; then
  SANITIZER="$NWP_ROOT/lib/sanitizers/${SITE}.sh"
  if [ ! -f "$SANITIZER" ] && [ -f "$SANITIZER_OVERLAY_DIR/${SITE}.sh" ]; then
    SANITIZER="$SANITIZER_OVERLAY_DIR/${SITE}.sh"
  fi
fi
[ -f "$SANITIZER" ] || die "no sanitizer for '$SITE' (looked at $NWP_ROOT/lib/sanitizers/${SITE}.sh and $SANITIZER_OVERLAY_DIR/${SITE}.sh). Supply --sanitizer PATH (e.g. lib/sanitizers/standard.sh). Refusing to publish unsanitized data."

# Token file must exist; warn if it is looser than 0600/0400.
[ -f "$TOKEN_FILE" ] || die "publish token file not found: $TOKEN_FILE"
perms="$(stat -c '%a' "$TOKEN_FILE" 2>/dev/null || echo '')"
case "$perms" in 600|400|'') : ;; *) print_warning "token file $TOKEN_FILE is $perms — expected 600/400" ;; esac

# Stack detection (ADR-0032 Flow A): a Moodle root carries version.php and its
# sanitizer (<site>.sh → moodle-full.sh) emits a .tar.gz BUNDLE {db.sql.gz, manifest};
# a Drupal site emits a plain .sql.gz dump. The extension + gate method follow.
if [ -f "$SITE_DIR/version.php" ]; then
    STACK="moodle"; ARTIFACT_EXT="tar.gz"
else
    STACK="drupal"; ARTIFACT_EXT="sql.gz"
fi
ARTIFACT_NAME="${SITE}-sanitized-$(date -u +%Y%m%dT%H%M%SZ).${ARTIFACT_EXT}"
DEST_URL="${PUBLISH_URL%/}/${ARTIFACT_NAME}"

print_header "nwp-server publish — $SITE"
print_info "site-dir:  $SITE_DIR"
print_info "sanitizer: $SANITIZER"
print_info "stack:     $STACK"
print_info "artifact:  $ARTIFACT_NAME"
print_info "dest:      $DEST_URL"

if [ "$EXECUTE" != y ]; then
    print_header "Dry run — no snapshot, no publish"
    echo "Would, in order:"
    if [ "$STACK" = moodle ]; then
        echo "  1. run the sanitizer → bundle {db.sql.gz (scratch DB), dataroot-manifest}"
        echo "  2. gate the INNER db.sql.gz (abort on ANY PII) + assert manifest attests empty filedir"
    else
        echo "  1. run the sanitizer (live DB read-only → scratch → sanitized dump)"
        echo "  2. run the fail-closed PII gate over the dump (abort on ANY PII)"
    fi
    echo "  3. PUT the artifact to $DEST_URL using the write-only deploy token"
    print_hint "re-run with --execute to publish"
    exit 0
fi

command -v curl >/dev/null 2>&1 || die "curl not found — required to publish"
TMP="$(mktemp --suffix=".${ARTIFACT_EXT}")"
cleanup(){ [ -f "$TMP" ] && { shred -u "$TMP" 2>/dev/null || rm -f "$TMP"; }; }
trap cleanup EXIT

# ── Step 1: sanitize (raw data stays on this host) ────────────────────────────
print_header "Step 1/3 — sanitize (scratch-DB model)"
SAN_ARGS=(--output "$TMP" --site-dir "$SITE_DIR")
[ -n "$DRUSH" ] && SAN_ARGS+=(--drush "$DRUSH")
if ! bash "$SANITIZER" "${SAN_ARGS[@]}"; then
    die "sanitizer FAILED — nothing published (fail-closed)"
fi
[ -s "$TMP" ] || die "sanitizer produced no output — nothing published"

# ── Step 2: independent fail-closed PII gate ──────────────────────────────────
# pii_gate_scan_artifact handles BOTH a plain .sql.gz (Drupal, unchanged) and a
# moodle-full bundle (Moodle): for a bundle it extracts the inner db.sql.gz and
# scans THAT + asserts the manifest attests an empty filedir — independently of
# the sanitizer's own --verify, preserving the two-gate model.
print_header "Step 2/3 — fail-closed PII gate"
if pii_gate_scan_artifact "$TMP" "$ALLOWLIST"; then
    print_success "PII gate PASSED — no unsanitized PII"
else
    die "PII gate FAILED (exit $?) — refusing to publish (fail-closed)"
fi

# ── Step 3: publish with the write-only deploy token (never an api PAT) ────────
print_header "Step 3/3 — publish (write-only deploy token)"
token="$(tr -d '\r\n' < "$TOKEN_FILE")"
[ -n "$token" ] || die "publish token file is empty: $TOKEN_FILE"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 120 \
    --header "Deploy-Token: $token" --upload-file "$TMP" "$DEST_URL")"
if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
    print_success "published $ARTIFACT_NAME (HTTP $code)"
    print_info "$DEST_URL"
else
    die "publish upload failed (HTTP $code) — the sanitized dump was NOT published"
fi
