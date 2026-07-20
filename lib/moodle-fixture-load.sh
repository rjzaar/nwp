#!/bin/bash
# NOTE: no `set -euo pipefail` here — this is a SOURCED library (like lib/pii-gate.sh).
# Forcing -e/-u onto the caller leaks into the bats runner, which older bats (as
# installed in CI) does not snapshot/restore around each test, breaking test:unit.
# Every function below does its own explicit error handling (`|| return`), so it
# does not depend on errexit.
################################################################################
# lib/moodle-fixture-load.sh — dev/stg CONSUMER of a sanitised Moodle fixture
# bundle (ADR-0032 Flow A, increment 2b).
#
# This is the reusable, testable CORE of the loader. It runs on the DEV/STG/CI
# tier (NEVER on the prod host — the prod agent nwp-server deliberately has no
# load verb, ADR-0026). It takes a `<site>-sanitized-<ts>.tar.gz` bundle
# produced by server-publish (moodle-full: {db.sql.gz, dataroot-manifest}) and:
#
#   1. moodle_fixture_verify_extract — re-runs the INDEPENDENT PII gate over the
#      bundle (defence in depth: the artifact just crossed the trust boundary),
#      then extracts the inner db.sql.gz for the caller to import.
#   2. moodle_scaffold_empty_dataroot — reconstitutes a structurally-valid, EMPTY
#      moodledata at the target (omit-and-placeholder: filedir empty + system
#      dirs). No moodledata bytes are transported — the bundle carried none.
#
# The thin command layer around this core (a `pl` command) supplies the parts
# that need a live environment and are therefore NOT in this library:
#   - FETCH the bundle over HTTPS with the read-only package token,
#   - IMPORT db.sql.gz into the target Moodle DB (ddev/drush/mysql),
#   - PRUNE orphaned mdl_files rows on the loaded copy: `moosh file-dbcheck`
#     (turns "file missing" placeholders into clean "no submission").
#
# FAIL-CLOSED: any gate/extraction/scaffold failure returns non-zero and leaves
# no half-loaded state a caller could mistake for a clean fixture. Security-
# critical (mirrors the sanitiser chain) — changes here require human review.
################################################################################

_MFL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_MFL_DIR/pii-gate.sh"

# The empty-scaffold dir set. CANONICAL list lives in
# lib/sanitizers/moodle-dataroot.sh (SCAFFOLD_DIRS) — kept in step with it.
MFL_SCAFFOLD_DIRS=(filedir temp cache localcache muc sessions lock trashdir models)
MFL_SCRUB_MARKER=".nwp-moodledata-scrubbed"

mfl_log() { echo "[moodle-fixture-load] $*"; }
mfl_err() { echo "[moodle-fixture-load] ERROR: $*" >&2; }

# ── moodle_fixture_verify_extract <bundle> <workdir> [allowlist] ───────────────
# Gate the bundle independently, then extract db.sql.gz into <workdir>. Echoes
# the db.sql.gz path on success (for the caller to import). Fail-closed.
moodle_fixture_verify_extract() {
    local bundle="${1:-}" work="${2:-}" allow="${3:-}"
    [ -n "$bundle" ] && [ -f "$bundle" ] || { mfl_err "bundle not found: ${bundle:-<none>}"; return 2; }
    [ -n "$work" ] || { mfl_err "workdir is required"; return 2; }

    # Independent gate — a sanitiser bug or truncated transfer must not let raw
    # PII land on dev. (pii_gate_scan_artifact extracts + scans the inner dump and
    # asserts the manifest attests an empty filedir.)
    pii_gate_scan_artifact "$bundle" "$allow" \
        || { mfl_err "PII gate FAILED on fixture — refusing to load (fail-closed)"; return 1; }

    mkdir -p "$work" || { mfl_err "cannot create workdir: $work"; return 1; }
    tar -xzf "$bundle" -C "$work" db.sql.gz 2>/dev/null \
        || { mfl_err "bundle has no extractable db.sql.gz — fail-closed"; return 1; }
    [ -s "$work/db.sql.gz" ] || { mfl_err "extracted db.sql.gz is empty — fail-closed"; return 1; }
    printf '%s\n' "$work/db.sql.gz"
    return 0
}

# ── moodle_scaffold_empty_dataroot <target_dataroot> ──────────────────────────
# Ensure the target is a structurally-valid, EMPTY moodledata (omit-and-
# placeholder). Refuses to clobber a POPULATED real dataroot (a filedir with
# content and no scrub marker) — the same guard as moodle-dataroot.sh. A prior
# scaffold (marker present) may be reused. Fail-closed.
moodle_scaffold_empty_dataroot() {
    local dr="${1:-}"
    [ -n "$dr" ] || { mfl_err "target dataroot is required"; return 2; }

    if [ -d "$dr/filedir" ] \
       && [ -n "$(find "$dr/filedir" -mindepth 1 -print -quit 2>/dev/null)" ] \
       && [ ! -f "$dr/$MFL_SCRUB_MARKER" ]; then
        mfl_err "target '$dr' holds a populated filedir with no scrub marker — refusing to clobber (fail-closed)"
        return 1
    fi

    mkdir -p "$dr" || { mfl_err "cannot create target dataroot: $dr"; return 1; }
    local d
    for d in "${MFL_SCAFFOLD_DIRS[@]}"; do
        mkdir -p "$dr/$d" || { mfl_err "cannot scaffold $dr/$d"; return 1; }
    done
    {
        echo "scrubbed-by: lib/moodle-fixture-load.sh (ADR-0032 Flow A loader)"
        echo "strategy: omit-and-placeholder (empty filedir, rebuilt on the dev/stg side)"
        echo "note: kept mdl_files rows render 'file missing' placeholders (expected)"
        echo "prune-hint: moosh file-dbcheck   # drop orphaned mdl_files rows on this copy"
    } > "$dr/$MFL_SCRUB_MARKER"

    # Post-condition: filedir exists and is EMPTY.
    [ -d "$dr/filedir" ] || { mfl_err "post-condition FAIL: filedir/ missing"; return 1; }
    if [ -n "$(find "$dr/filedir" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        mfl_err "post-condition FAIL: filedir/ is not empty"; return 1
    fi
    mfl_log "empty dataroot scaffold ready at $dr (run 'moosh file-dbcheck' after importing db.sql.gz)"
    return 0
}

# ── moodle_fixture_load <bundle> <target_dataroot> <import_cmd> [allowlist] ─────
# End-to-end orchestration of a LOCAL bundle into a target Moodle (the thin `pl`
# command supplies fetch + the real importer + the optional moosh prune):
#   verify+extract (independent gate) → <import_cmd> <db.sql.gz> → empty scaffold.
# <import_cmd> is a command/function NAME; the extracted db.sql.gz path is passed
# as its single argument (e.g. a wrapper around `ddev import-db --file=`). This
# indirection keeps the safety-critical sequencing unit-testable without ddev.
# Fail-closed: a gate/import/scaffold failure returns non-zero; the DB is never
# imported unless the bundle passed the gate first.
moodle_fixture_load() {
    local bundle="${1:-}" dataroot="${2:-}" import_cmd="${3:-}" allow="${4:-}"
    [ -n "$bundle" ]     || { mfl_err "bundle is required";          return 2; }
    [ -n "$dataroot" ]   || { mfl_err "target dataroot is required"; return 2; }
    [ -n "$import_cmd" ] || { mfl_err "import command is required";  return 2; }

    local work; work="$(mktemp -d)" || { mfl_err "mktemp failed"; return 2; }
    # shellcheck disable=SC2064
    trap "rm -rf -- '$work'" RETURN

    local db
    db="$(moodle_fixture_verify_extract "$bundle" "$work" "$allow")" || return 1

    mfl_log "importing sanitised DB into target Moodle (via ${import_cmd})"
    "$import_cmd" "$db" || { mfl_err "DB import failed — fail-closed"; return 1; }

    moodle_scaffold_empty_dataroot "$dataroot" || return 1

    mfl_log "fixture loaded. Prune orphaned mdl_files rows on the target: moosh file-dbcheck"
    return 0
}
