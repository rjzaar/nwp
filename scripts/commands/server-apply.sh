#!/bin/bash
set -euo pipefail
################################################################################
# nwp-server apply — verify a signed bundle and apply it on THIS host (ADR-0024).
#
# Orchestration (nothing here is bespoke deploy logic — the bundle carries its
# own signed, idempotent apply):
#   1. VERIFY the bundle fail-closed (lib/bundle-verify.sh) — signature + payload
#      and scripts SHA-256 against the manifest. A bundle that does not verify is
#      never applied.
#   2. (opt-in) take a pre-apply restic DR snapshot for the offline custodian
#      (--snapshot -> scripts/commands/server-backup.sh, ADR-0025).
#   3. Run the bundle's OWN scripts in order: pre-deploy.sh -> apply.sh ->
#      post-deploy.sh (F28 §3.3/§3.5). These are signed as part of the bundle,
#      are required to be idempotent, and fail loud (writing a marker that the
#      next deploy's pre-deploy.sh checks).
#
# Rollback model (F28 §3.4): rollback is "apply the PREVIOUS bundle" — because
# apply.sh is idempotent, roll-forward and roll-back are the same operation with a
# different bundle id. This agent therefore does NOT perform an unreviewed DB/code
# restore on failure; it fails loud, leaves the DR snapshot (if taken) for the
# custodian, and tells the operator/loop exactly how to recover.
#
# Dry-run by DEFAULT. Nothing on this host is mutated without --execute.
#
# Usage:
#   nwp-server apply BUNDLE --site NAME [--site-dir DIR] [--execute]
#                    [--pubkey FILE] [--snapshot] [-- <server-backup opts>]
#
#   BUNDLE           path to the signed .tar.gz bundle (already pulled+verified)
#   --site NAME      logical site name (for logging/context)
#   --site-dir DIR   deployed site root the bundle scripts operate on
#   --execute        actually run the bundle scripts (default: dry-run plan only)
#   --pubkey FILE    minisign public key (default: keys/minisign/nwp-deploy.pub)
#   --snapshot       take a pre-apply restic DR snapshot first (needs --execute);
#                    fail-closed — a failed snapshot aborts the apply
#   -- ...           everything after `--` is passed to server-backup.sh
#   -h, --help       show this help
#
# The bundle scripts run with CWD at the bundle root and this context exported:
#   NWP_BUNDLE_DIR, NWP_PAYLOAD_DIR, NWP_SITE, NWP_SITE_DIR.
#
# Exit: 0 = verified and (if --execute) applied cleanly; non-zero on verification
#       failure or any apply-script failure (prod left for the loud-fail marker).
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

BUNDLE=""
SITE=""
SITE_DIR=""
EXECUTE=n
SNAPSHOT=n
PUBKEY="${MINISIGN_PUBLIC_KEY:-$NWP_ROOT/keys/minisign/nwp-deploy.pub}"
BACKUP_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --site)       SITE="$2"; shift 2 ;;
        --site=*)     SITE="${1#*=}"; shift ;;
        --site-dir)   SITE_DIR="$2"; shift 2 ;;
        --site-dir=*) SITE_DIR="${1#*=}"; shift ;;
        --pubkey)     PUBKEY="$2"; shift 2 ;;
        --pubkey=*)   PUBKEY="${1#*=}"; shift ;;
        --execute|-y) EXECUTE=y; shift ;;
        --dry-run)    EXECUTE=n; shift ;;
        --snapshot)   SNAPSHOT=y; shift ;;
        --)           shift; BACKUP_ARGS=("$@"); break ;;
        -h|--help)    sed -n '3,/^###/{/^###/d;p}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)           die "unknown option: $1 (try --help)" ;;
        *)            [ -z "$BUNDLE" ] && BUNDLE="$1" || die "unexpected argument: $1"; shift ;;
    esac
done

[ -n "$BUNDLE" ] || die "no bundle given (usage: nwp-server apply BUNDLE --site NAME)"
[ -f "$BUNDLE" ] || die "bundle not found: $BUNDLE"
[ -n "$SITE" ]   || die "--site NAME is required"

# ── Step 1: verify fail-closed (never skip the signature on prod) ────────────
[ -f "$PUBKEY" ] || die "minisign public key not found: $PUBKEY — cannot verify, refusing to apply"
print_header "Verifying bundle"
if ! BUNDLE_VERIFY_NO_SIG="" bundle_verify "$BUNDLE" "$PUBKEY"; then
    die "bundle FAILED verification — not applying: $BUNDLE"
fi
print_success "bundle verified"

# Extract into a private staging dir we control (own tar; verification already
# confirmed structure + hashes, so this tree is exactly what was signed).
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/nwp-server-apply.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT
tar -xzf "$BUNDLE" -C "$STAGE" || die "failed to extract verified bundle"
ROOT="$(find "$STAGE" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -n "$ROOT" ] && [ -d "$ROOT/scripts" ] || die "unexpected bundle layout after extract"
[ -f "$ROOT/scripts/apply.sh" ] || die "bundle has no scripts/apply.sh"

BUNDLE_ID="$(basename "$ROOT")"
print_info "bundle:   $BUNDLE_ID"
print_info "site:     $SITE"
print_info "site-dir: ${SITE_DIR:-<none given>}"

# ── Dry-run: show the plan and stop ──────────────────────────────────────────
if [ "$EXECUTE" != y ]; then
    print_header "Dry run — no changes will be made"
    echo "Would, in order:"
    [ "$SNAPSHOT" = y ] && echo "  0. take a pre-apply restic DR snapshot (server-backup.sh)"
    for s in pre-deploy.sh apply.sh post-deploy.sh; do
        if [ -f "$ROOT/scripts/$s" ]; then echo "  - run scripts/$s"; else echo "  - (no scripts/$s in bundle — skipped)"; fi
    done
    echo
    print_hint "re-run with --execute to apply on this host"
    exit 0
fi

# ── Step 2 (opt-in): pre-apply DR snapshot, fail-closed ──────────────────────
if [ "$SNAPSHOT" = y ]; then
    [ -n "$SITE_DIR" ] || die "--snapshot needs --site-dir DIR (what to snapshot)"
    print_header "Pre-apply DR snapshot"
    if ! bash "$SCRIPT_DIR/server-backup.sh" --site-dir "$SITE_DIR" --execute "${BACKUP_ARGS[@]}"; then
        die "pre-apply snapshot FAILED — aborting apply (fail-closed; nothing on this host was changed)"
    fi
    print_success "pre-apply snapshot taken"
fi

# ── Step 3: run the bundle's own signed, idempotent scripts, in order ────────
export NWP_BUNDLE_DIR="$ROOT"
export NWP_PAYLOAD_DIR="$ROOT/payload"
export NWP_SITE="$SITE"
export NWP_SITE_DIR="$SITE_DIR"

run_stage() { # $1 = script name
    local s="$ROOT/scripts/$1"
    [ -f "$s" ] || { print_info "no $1 in bundle — skipping"; return 0; }
    print_header "Running $1"
    if ( cd "$ROOT" && bash "$s" ); then
        print_success "$1 OK"
        return 0
    fi
    return 1
}

apply_failed() {
    echo >&2
    print_error "APPLY FAILED at: $1 — this host may be mid-deploy"
    print_hint  "F28 rollback = re-apply the PREVIOUS good bundle:"
    print_hint  "    nwp-server apply <previous-bundle> --site $SITE --site-dir $SITE_DIR --execute"
    [ "$SNAPSHOT" = y ] && print_hint "a pre-apply restic DR snapshot was taken; the custodian (ver) can restore it."
    print_hint  "the bundle's apply.sh is required to fail loud and leave a marker (F28 §3.5)."
    exit 1
}

run_stage pre-deploy.sh  || apply_failed pre-deploy.sh
run_stage apply.sh       || apply_failed apply.sh
run_stage post-deploy.sh || apply_failed post-deploy.sh

print_success "apply complete: $BUNDLE_ID on $SITE"
