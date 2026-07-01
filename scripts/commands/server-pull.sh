#!/bin/bash
set -euo pipefail
################################################################################
# nwp-server pull — fetch a signed bundle over HTTPS, then verify it fail-closed.
#
# This is the "pull+verify" capability (ADR-0024). It reuses lib/minisign.sh and
# lib/bundle-verify.sh unchanged — the prod agent adds transport, not a second
# verification path. Verification is the SAME contract the build tier signs
# against: extract, validate structure, minisign-verify the manifest against the
# pinned public key, then recompute and match the payload/scripts SHA-256.
#
# Read-only by construction. It needs only two of the three ledger keys:
#   - the READ-ONLY deploy token (to GET the bundle from the artifact host), and
#   - the minisign PUBLIC key (to verify the signature).
# It never writes anywhere on prod and never holds a write credential.
#
# Usage:
#   nwp-server pull --url URL [--out DIR] [--token-file FILE] [--pubkey FILE]
#   nwp-server pull --verify-only BUNDLE [--pubkey FILE]
#
#   --url URL          full HTTPS URL of the .tar.gz bundle to download
#   --out DIR          directory to download into (default: current dir)
#   --token-file FILE  0600 file holding the read-only deploy token; sent as an
#                      Authorization header (never on argv/env/history)
#   --pubkey FILE      minisign public key (default: keys/minisign/nwp-deploy.pub)
#   --verify-only PATH verify an already-present local bundle; no download
#   -h, --help         show this help
#
# Exit: 0 = bundle downloaded (if requested) AND verified; non-zero on any
#       transport error or verification failure. Fail-closed: a bundle that does
#       not verify is left in place for inspection and NEVER reported as good.
################################################################################
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$( cd "$SCRIPT_DIR/../.." && pwd )}"
NWP_ROOT="${NWP_ROOT:-$PROJECT_ROOT}"

# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/ui.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/minisign.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/bundle-verify.sh"

die() { print_error "$*"; exit 1; }

URL=""
OUT_DIR="."
TOKEN_FILE=""
PUBKEY="${MINISIGN_PUBLIC_KEY:-$NWP_ROOT/keys/minisign/nwp-deploy.pub}"
VERIFY_ONLY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --url)          URL="$2"; shift 2 ;;
        --url=*)        URL="${1#*=}"; shift ;;
        --out)          OUT_DIR="$2"; shift 2 ;;
        --out=*)        OUT_DIR="${1#*=}"; shift ;;
        --token-file)   TOKEN_FILE="$2"; shift 2 ;;
        --token-file=*) TOKEN_FILE="${1#*=}"; shift ;;
        --pubkey)       PUBKEY="$2"; shift 2 ;;
        --pubkey=*)     PUBKEY="${1#*=}"; shift ;;
        --verify-only)  VERIFY_ONLY="$2"; shift 2 ;;
        --verify-only=*) VERIFY_ONLY="${1#*=}"; shift ;;
        -h|--help)      sed -n '3,/^###/{/^###/d;p}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              die "unknown argument: $1 (try --help)" ;;
    esac
done

# verify_bundle: run the shared fail-closed verification and report clearly.
verify_bundle() {
    local bundle="$1"
    [ -f "$bundle" ] || die "bundle not found: $bundle"
    [ -f "$PUBKEY" ] || die "minisign public key not found: $PUBKEY (need it to verify the signature; refusing to proceed)"
    print_info "verifying $bundle against $PUBKEY (fail-closed)"
    # NEVER skip the signature on a prod host.
    if BUNDLE_VERIFY_NO_SIG="" bundle_verify "$bundle" "$PUBKEY"; then
        print_success "bundle VERIFIED: $bundle"
        return 0
    fi
    print_error "bundle FAILED verification: $bundle — NOT applying"
    return 1
}

# ── verify-only path ─────────────────────────────────────────────────────────
if [ -n "$VERIFY_ONLY" ]; then
    verify_bundle "$VERIFY_ONLY"
    exit $?
fi

# ── pull path ────────────────────────────────────────────────────────────────
[ -n "$URL" ] || die "no --url given (and no --verify-only). Nothing to pull."
case "$URL" in
    https://*) : ;;
    *) die "refusing non-HTTPS URL: $URL (the pull transport is HTTPS + signature verification)" ;;
esac

command -v curl >/dev/null 2>&1 || die "curl not found — required to pull bundles"
mkdir -p "$OUT_DIR"
BASENAME="$(basename "${URL%%\?*}")"
DEST="$OUT_DIR/$BASENAME"

# Build curl auth args from the 0600 token file, if given. The token is passed
# via a header read from the file, never placed on the command line or in env.
CURL_AUTH=()
if [ -n "$TOKEN_FILE" ]; then
    [ -f "$TOKEN_FILE" ] || die "token file not found: $TOKEN_FILE"
    # Defence in depth: a deploy token file should be 0600/0400. Warn loudly if
    # the group or other bits are set (the last two octal digits are non-zero).
    perms="$(stat -c '%a' "$TOKEN_FILE" 2>/dev/null || echo '')"
    case "$perms" in
        600|400|'') : ;;
        *) print_warning "token file $TOKEN_FILE is $perms — expected 600/400; tighten with: chmod 600 $TOKEN_FILE" ;;
    esac
    token="$(tr -d '\r\n' < "$TOKEN_FILE")"
    [ -n "$token" ] || die "token file is empty: $TOKEN_FILE"
    CURL_AUTH=(--header "Authorization: Bearer $token")
fi

print_info "pulling $URL -> $DEST"
if ! curl -fsSL "${CURL_AUTH[@]}" -o "$DEST" "$URL"; then
    die "download failed: $URL"
fi
print_status "OK" "downloaded $(basename "$DEST")"

# Fail-closed: a downloaded bundle is worthless until it verifies.
verify_bundle "$DEST"
exit $?
