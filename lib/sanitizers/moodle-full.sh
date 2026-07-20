#!/bin/bash
set -euo pipefail
################################################################################
# lib/sanitizers/moodle-full.sh — the ATOMIC "full Moodle sanitised artifact"
# orchestrator (ops#111 / ADR-0032 Flow A).
#
# Composes the two prod-native Moodle scrubbers into ONE clean artifact, or
# produces NOTHING (fail-closed):
#
#   1. lib/sanitizers/moodle.sh          — DB (scratch model, plane-5b tables,
#                                           oidc-email shared salt)          → db.sql.gz
#   2. lib/pii-gate.sh :: pii_gate_scan  — independent backstop over the dump
#   3. lib/sanitizers/moodle-dataroot.sh — moodledata omit-and-placeholder    → empty scaffold
#   4. manifest                          — audit proof (filedir EMPTY, N files omitted)
#   5. bundle                            → <site>-sanitized-<ts>.tar.gz { db.sql.gz, dataroot-manifest }
#
# WHY a bundle and not two artifacts: ADR-0032's file-store decision is
# OMIT-AND-PLACEHOLDER, so the "sanitised moodledata" carries ~zero real bytes —
# it is a manifest/proof, not data. The dev/stg loader rebuilds the empty
# scaffold locally from the manifest, then prunes orphaned mdl_files rows
# (`moosh file-dbcheck`) so uploads render as clean "no submission", not errors.
# No moodledata byte transport is needed for a dev copy.
#
# SECURITY MODEL — identical to the sub-scrubbers it drives:
#   - Runs ON the Moodle prod host. The live DB and live moodledata are treated
#     as strictly READ-ONLY (moodle.sh dumps to a scratch DB; moodle-dataroot.sh
#     omits rather than copies — it never reads a user file byte). Raw user data
#     never leaves this host.
#   - FAIL-CLOSED end to end: any step's non-zero exit aborts, the work dir is
#     shredded, and NO artifact is produced. A failed/partial run can never yield
#     a bundle a downstream step would treat as clean.
#   - Reuses the INDEPENDENT lib/pii-gate.sh over the DB dump before bundling, so
#     the bundle is only ever built from a gate-passed dump. server-publish.sh
#     (Flow A increment 2) re-scans after the artifact crosses the boundary —
#     two gates, defence in depth.
#
# TESTABILITY / DI: the two sub-tools are resolved via env overrides so the
# composition/fail-closed/bundling logic is unit-testable without a live DB
# (the DB step is stubbed; the dataroot scrub + gate run for real against
# synthetic fixtures). These also let a bespoke site swap the DB sanitiser:
#   NWP_MOODLE_DB_SANITIZER        (default: lib/sanitizers/moodle.sh)
#   NWP_MOODLE_DATAROOT_SCRUBBER   (default: lib/sanitizers/moodle-dataroot.sh)
#
# INTERFACE:
#   moodle-full.sh --site-dir DIR --output FILE.tar.gz [--dataroot DIR]
#                  [--allowlist FILE] [--verify] [-h|--help]
#     --site-dir DIR   Moodle root (config.php + version.php). REQUIRED.
#     --output FILE    Path for the sanitised bundle (.tar.gz).
#     --dataroot DIR   Live moodledata (READ-ONLY source). Default: resolved from
#                      $CFG->dataroot in config.php, else <site-dir>/moodledata.
#     --allowlist FILE Extra per-site PII-gate allowlist (public-contact addresses).
#     --verify         Re-verify an existing --output bundle only; write nothing
#                      (extracts db.sql.gz, re-runs the gate, asserts the manifest
#                      records an EMPTY filedir).
#
# POST-CONDITION (asserted before success): the bundle exists, is non-empty, and
# contains exactly a gate-passed db.sql.gz plus a manifest that records filedir
# EMPTY. Any failure ⇒ non-zero, no artifact.
#
# SECURITY: per CLAUDE.md the sanitiser chain is security-critical — this file
# and the tools it drives change only under human review.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve the gate via our OWN location (lib/sanitizers/../pii-gate.sh), not a
# mutable PROJECT_ROOT — mirrors how moodle.sh sources oidc-email.sh, and keeps
# this robust when a caller/test overrides PROJECT_ROOT.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../pii-gate.sh"

DB_SANITIZER="${NWP_MOODLE_DB_SANITIZER:-$SCRIPT_DIR/moodle.sh}"
DATAROOT_SCRUBBER="${NWP_MOODLE_DATAROOT_SCRUBBER:-$SCRIPT_DIR/moodle-dataroot.sh}"

SITE_DIR=""
OUTPUT="/tmp/moodle-full-sanitized.tar.gz"
DATAROOT=""
ALLOWLIST=""
VERIFY_ONLY=false
WORKDIR=""

log()       { echo "[moodle-full] $*"; }
log_error() { echo "[moodle-full] ERROR: $*" >&2; }

_cleanup() { [ -n "${WORKDIR:-}" ] && [ -d "${WORKDIR:-}" ] && rm -rf -- "$WORKDIR"; return 0; }

# Resolve $CFG->dataroot from config.php WITHOUT bootstrapping Moodle (mirrors
# moodle.sh's ABORT_AFTER_CONFIG trick). Falls back to <site-dir>/moodledata.
_resolve_dataroot() {
    local site_dir="$1" cfg="$site_dir/config.php" dr=""
    if [ -f "$cfg" ] && command -v php >/dev/null 2>&1; then
        dr=$(php -d error_reporting=0 -d display_errors=0 -r '
            define("CLI_SCRIPT", true);
            define("ABORT_AFTER_CONFIG", true);
            require($argv[1]);
            echo isset($CFG->dataroot) ? $CFG->dataroot : "";
        ' "$cfg" 2>/dev/null || true)
    fi
    [ -n "$dr" ] || dr="${site_dir%/}/moodledata"
    printf '%s' "$dr"
}

# Extract db.sql.gz from a bundle to stdout-path; used by --verify.
_bundle_extract_db() { # $1 bundle  $2 destdir
    tar -xzf "$1" -C "$2" db.sql.gz 2>/dev/null
}

# ── --verify: re-check an existing bundle (read-only, safe to run anywhere) ────
_verify_bundle() {
    local bundle="$1"
    [ -f "$bundle" ] || { log_error "no bundle to verify: $bundle"; return 2; }
    command -v tar >/dev/null 2>&1 || { log_error "tar missing"; return 2; }
    WORKDIR="$(mktemp -d)"
    _bundle_extract_db "$bundle" "$WORKDIR" || { log_error "bundle has no db.sql.gz — refusing (fail-closed)"; return 1; }
    [ -s "$WORKDIR/db.sql.gz" ] || { log_error "extracted db.sql.gz is empty — fail-closed"; return 1; }
    pii_gate_scan "$WORKDIR/db.sql.gz" "$ALLOWLIST" || { log_error "PII gate FAILED on bundled dump"; return 1; }
    # Manifest must record an EMPTY filedir (the omit-and-placeholder contract).
    if ! tar -xzf "$bundle" -C "$WORKDIR" dataroot-manifest.txt 2>/dev/null; then
        log_error "bundle has no dataroot-manifest.txt — refusing (fail-closed)"; return 1
    fi
    grep -q 'filedir: EMPTY' "$WORKDIR/dataroot-manifest.txt" || {
        log_error "manifest does not attest 'filedir: EMPTY' — refusing (fail-closed)"; return 1; }
    log "verify: bundle clean (gate passed; manifest attests empty filedir)"
    return 0
}

# ── the orchestrator ──────────────────────────────────────────────────────────
moodle_sanitize_full() {
    local site_dir="${1:-$SITE_DIR}" output="${2:-$OUTPUT}"
    [ -n "$site_dir" ] || { log_error "--site-dir DIR is required"; return 2; }
    [ -f "$site_dir/version.php" ] || {
        log_error "not a Moodle root (version.php missing): $site_dir — refusing (fail-closed)"; return 1; }

    local dataroot="${DATAROOT:-}"
    [ -n "$dataroot" ] || dataroot="$(_resolve_dataroot "$site_dir")"
    log "site-dir: $site_dir"
    log "dataroot (READ-ONLY source): $dataroot"

    WORKDIR="$(mktemp -d)"
    local db="$WORKDIR/db.sql.gz"
    local scaffold="$WORKDIR/moodledata"
    local manifest="$WORKDIR/dataroot-manifest.txt"

    # ── 1. DB sanitiser (scratch model; raw DB never leaves this host) ─────────
    log "step 1/5 — Moodle DB sanitiser ($DB_SANITIZER)"
    bash "$DB_SANITIZER" --site-dir "$site_dir" --output "$db" \
        || { log_error "DB sanitiser FAILED — no artifact (fail-closed)"; return 1; }
    [ -s "$db" ] || { log_error "DB sanitiser produced no output — fail-closed"; return 1; }

    # ── 2. independent PII gate over the dump BEFORE it enters the bundle ──────
    log "step 2/5 — independent PII gate over the sanitised dump"
    pii_gate_scan "$db" "$ALLOWLIST" \
        || { log_error "PII gate FAILED — refusing to bundle (fail-closed)"; return 1; }

    # ── 3. moodledata omit-and-placeholder scrub (never reads a user file byte) ─
    log "step 3/5 — moodledata omit-and-placeholder scrub ($DATAROOT_SCRUBBER)"
    bash "$DATAROOT_SCRUBBER" --dataroot "$dataroot" --output "$scaffold" \
        || { log_error "moodledata scrub FAILED — no artifact (fail-closed)"; return 1; }
    # The scaffold's filedir MUST be empty (defence-in-depth re-assert here too).
    if [ -n "$(find "$scaffold/filedir" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        log_error "scrubbed filedir is NOT empty — refusing (fail-closed)"; return 1
    fi

    # ── 4. manifest (audit proof; counts source files OMITTED, reads no bytes) ─
    log "step 4/5 — dataroot manifest"
    local omitted="unknown"
    if [ -d "$dataroot/filedir" ]; then
        omitted="$(find "$dataroot/filedir" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
    fi
    {
        echo "artifact: moodle-full sanitised bundle (ADR-0032 Flow A)"
        echo "site-dir: $site_dir"
        echo "source-dataroot: $dataroot"
        echo "strategy: omit-and-placeholder"
        echo "filedir: EMPTY (all $omitted user upload(s) omitted; no bytes copied off prod)"
        echo "loader-hint: rebuild empty scaffold locally; run 'moosh file-dbcheck' to prune orphaned mdl_files rows"
        echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$manifest"

    # ── 5. bundle (db + manifest only; the scaffold is content-free by design) ─
    log "step 5/5 — bundle → $output"
    mkdir -p "$(dirname "$output")"
    tar -czf "$output" -C "$WORKDIR" db.sql.gz dataroot-manifest.txt \
        || { log_error "bundle failed"; return 1; }

    # ── post-condition ────────────────────────────────────────────────────────
    [ -s "$output" ] || { log_error "bundle is empty — fail-closed"; return 1; }
    tar -tzf "$output" 2>/dev/null | grep -qx 'db.sql.gz' \
        || { log_error "post-condition FAIL: bundle missing db.sql.gz"; return 1; }
    tar -tzf "$output" 2>/dev/null | grep -qx 'dataroot-manifest.txt' \
        || { log_error "post-condition FAIL: bundle missing manifest"; return 1; }
    log "done: $output (sanitised DB + omit-and-placeholder dataroot manifest)"
    return 0
}

# ── arg parse ─────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --site-dir)   SITE_DIR="$2"; shift 2 ;;   --site-dir=*)   SITE_DIR="${1#*=}"; shift ;;
        --output)     OUTPUT="$2"; shift 2 ;;     --output=*)     OUTPUT="${1#*=}"; shift ;;
        --dataroot)   DATAROOT="$2"; shift 2 ;;   --dataroot=*)   DATAROOT="${1#*=}"; shift ;;
        --allowlist)  ALLOWLIST="$2"; shift 2 ;;  --allowlist=*)  ALLOWLIST="${1#*=}"; shift ;;
        --verify)     VERIFY_ONLY=true; shift ;;
        -h|--help)    sed -n '3,/^###/{/^###/d;p}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) log_error "unknown arg: $1"; exit 2 ;;
    esac
done

# ── main (guarded so the file can be sourced by unit tests without executing) ──
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap _cleanup EXIT
    if [ "$VERIFY_ONLY" = true ]; then
        _verify_bundle "$OUTPUT"; exit $?
    fi
    [ -n "$SITE_DIR" ] || { log_error "--site-dir DIR is required"; exit 2; }
    moodle_sanitize_full "$SITE_DIR" "$OUTPUT"
    exit $?
fi
