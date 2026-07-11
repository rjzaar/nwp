#!/bin/bash
set -euo pipefail
################################################################################
# lib/sanitizers/moodle-dataroot.sh — Moodle *moodledata* scrubber (ops#84).
#
# THE SIBLING STEP to lib/sanitizers/moodle.sh. That DB sanitizer scrubs the
# Moodle *database*; it explicitly DEFERS the on-disk file surface (moodledata)
# to "a sibling step" and cannot satisfy its own POST-CONDITION #4
# ("moodledata scrubbing/omission is confirmed") without one. THIS is that step.
# Run the two together on the Moodle prod host to produce a fully-sanitized
# Moodle backup/copy: `moodle_sanitize` (DB) + `moodle_scrub_dataroot` (files).
#
# ── WHAT LIVES IN MOODLEDATA / WHY WE OMIT IT ─────────────────────────────────
# The real residual PII in moodledata is USER-UPLOADED FILES — assignment
# submissions and forum attachments — NOT profile photos (NWP sites use
# avatars, not real photos, per the mayo_avatars policy, so `filedir` profile
# pictures are largely moot). Those uploads are minors'/students' plane-5b PII
# (ADR-0031 plane 5b: "absolutely not — PII, minors' records").
#
# You CANNOT anonymise a binary upload (an assignment PDF, a photo) — you can
# only DROP it. So "selective scrub" collapses to "omit the user content".
# Hence the strategy is OMIT-AND-PLACEHOLDER:
#   - `filedir/`  → recreated EMPTY (the content-addressed store of ALL uploads).
#   - `sessions/` → NEVER copied (live PHP session files leak logged-in users).
#   - `temp/ trashdir/ cache/ localcache/ muc/ lock/ repository/ models/`
#                 → NEVER copied (transient/derived; Moodle regenerates them).
# The scrubber literally never reads a single user file byte off prod — it
# *omits* rather than *copies* — so raw filedir never leaves the prod host.
#
# ── !!  mdl_files  ↔  filedir CONSISTENCY — READ THIS  !! ─────────────────────
# `filedir/` is Moodle's git-style content-addressable store: file BYTES live
# only at `filedir/<sha1[0:2]>/<sha1[2:4]>/<sha1>`; the DB table `mdl_files`
# holds only metadata + the `contenthash` pointer. When you ship an EMPTY
# filedir alongside the sanitized DB (which KEEPS `mdl_files` rows), those rows
# become dangling pointers and Moodle renders "file missing / Missing from
# filedir" PLACEHOLDERS in the dev/preview copy.
#
#   >>> THIS IS EXPECTED AND ACCEPTED, NOT CORRUPTION. <<<
#
# It is the standard industry default for a dev clone: you keep working
# navigation, quizzes, and structure; only user-uploaded binaries show as
# missing. This omit-and-placeholder behaviour is precisely what makes
# lib/sanitizers/moodle.sh's POST-CONDITION #4 SATISFIABLE.
#
# To get clean "no submission" instead of error placeholders, an operator MAY
# prune the orphaned DB rows ON THE DEV COPY with moosh:
#     moosh file-dbcheck      # list mdl_files rows with no file on disk
#     moosh file-datacheck    # verify sha1 integrity of what IS present
# Default = leave the rows, accept placeholders. We do NOT touch the DB here.
#
# ── SECURITY MODEL (mirrors lib/sanitizers/moodle.sh + standard.sh) ───────────
#   - Runs ON the Moodle prod host. The SOURCE moodledata is treated as
#     strictly READ-ONLY — we stat/scaffold, never read file contents, never
#     write into the live dataroot.
#   - FAIL-CLOSED: any precondition failure exits non-zero and produces NO
#     "scrubbed" dataroot a downstream step could mistake for clean — the same
#     "produce no clean artifact on failure" contract as lib/pii-gate.sh.
#   - No secrets are read or needed (this is a filesystem-shape operation).
#
# ── INTERFACE ─────────────────────────────────────────────────────────────────
#   moodle_scrub_dataroot --dataroot DIR --output DIR
#     --dataroot DIR   Live Moodle moodledata (source, READ-ONLY).  REQUIRED.
#     --output   DIR   Destination for the scrubbed dev/preview moodledata.
#                      Must NOT be, contain, or sit inside --dataroot.  REQUIRED.
#     -h | --help      Usage.
#
# PRECONDITIONS asserted (fail-closed if any is false):
#   - --dataroot exists and looks like a moodledata (has a `filedir` OR `muc`
#     marker) — refuse an arbitrary directory.
#   - --output is not prod-in-place: not equal to, not nested in, and does not
#     contain --dataroot. Never write into the live dataroot.
#   - --output does not already hold real content (a populated filedir) unless
#     it carries our own scrub marker — refuse to clobber a real dataroot.
#
# POST-CONDITION (asserted before returning success):
#   - The emitted `filedir/` exists and is EMPTY.
#   - None of sessions/ temp/ trashdir/ were copied (they contain no files).
#   - A scrub marker records that this dataroot is an omit-and-placeholder copy.
#
# Exit: 0 scrubbed dataroot written; non-zero on any failure — fail-closed.
################################################################################

DATAROOT=""
OUTPUT=""

# Scrub marker dropped at the dest root; also the allow-listed "safe to reuse as
# an --output" sentinel (so a re-run may target a prior scrub, never a real one).
SCRUB_MARKER=".nwp-moodledata-scrubbed"

# Dirs recreated EMPTY in the dest. filedir is the user-content store (the point
# of the whole exercise); the rest are transient/derived and Moodle regenerates
# them — we scaffold empty copies so the dataroot is structurally valid.
SCAFFOLD_DIRS=(filedir temp cache localcache muc sessions lock trashdir models)

# Dirs that must NEVER carry copied files in the output (post-condition check).
FORBIDDEN_COPY_DIRS=(sessions temp trashdir cache localcache muc lock repository models)

log()       { echo "[moodle-dataroot] $*"; }
log_error() { echo "[moodle-dataroot] ERROR: $*" >&2; }

usage() { sed -n '3,/^###/{/^###/d;p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# Canonicalise a path without requiring it to exist (output may be new).
_canon() { realpath -m -- "$1"; }

# ── moodle_scrub_dataroot — the sibling step ──────────────────────────────────
moodle_scrub_dataroot() {
    local dataroot="" output=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dataroot)   dataroot="$2"; shift 2 ;;
            --dataroot=*) dataroot="${1#*=}"; shift ;;
            --output)     output="$2"; shift 2 ;;
            --output=*)   output="${1#*=}"; shift ;;
            -h|--help)    usage; return 0 ;;
            *) log_error "unknown arg: $1"; return 2 ;;
        esac
    done

    [ -n "$dataroot" ] || { log_error "--dataroot DIR is required"; return 2; }
    [ -n "$output" ]   || { log_error "--output DIR is required"; return 2; }

    # ── precondition: source really is a moodledata (READ-ONLY, never mutated) ─
    [ -d "$dataroot" ] || { log_error "--dataroot is not a directory: $dataroot"; return 1; }
    if [ ! -d "$dataroot/filedir" ] && [ ! -d "$dataroot/muc" ]; then
        log_error "'$dataroot' has no filedir/ or muc/ marker — not a moodledata; refusing (fail-closed)"
        return 1
    fi

    local rc oc
    rc="$(_canon "$dataroot")"
    oc="$(_canon "$output")"

    # ── precondition: refuse prod-in-place / writing into the live dataroot ────
    if [ "$oc" = "$rc" ]; then
        log_error "--output equals --dataroot ('$rc') — refusing to scrub prod in place (fail-closed)"
        return 1
    fi
    case "$oc" in
        "$rc"/*) log_error "--output '$oc' is INSIDE the live dataroot — refusing to write into prod (fail-closed)"; return 1 ;;
    esac
    case "$rc" in
        "$oc"/*) log_error "--output '$oc' CONTAINS the live dataroot — refusing (would risk the source; fail-closed)"; return 1 ;;
    esac

    # ── precondition: don't clobber an existing REAL dataroot ──────────────────
    # A populated filedir in the output with no scrub marker means we are almost
    # certainly pointed at a real moodledata → refuse. A prior scrub (marker
    # present) is fine to overwrite.
    if [ -e "$output" ] && [ ! -f "$output/$SCRUB_MARKER" ]; then
        if [ -d "$output/filedir" ] && [ -n "$(find "$output/filedir" -mindepth 1 -print -quit 2>/dev/null)" ]; then
            log_error "--output '$output' already holds a populated filedir and is not a prior scrub — refusing to clobber (fail-closed)"
            return 1
        fi
        if [ -d "$output" ] && [ -n "$(find "$output" -mindepth 1 -print -quit 2>/dev/null)" ]; then
            log_error "--output '$output' is a non-empty dir without a scrub marker — refusing to clobber (fail-closed)"
            return 1
        fi
    fi

    # ── build: OMIT-AND-PLACEHOLDER. Create empty scaffolding only. ────────────
    # If overwriting a prior scrub, clear it first so the post-condition is clean.
    if [ -f "$output/$SCRUB_MARKER" ]; then
        log "reusing prior scrub target '$output' — clearing it"
        rm -rf -- "$output"
    fi
    log "scrubbing moodledata (omit-and-placeholder): '$rc' → '$output'"
    log "  source is READ-ONLY; no user file bytes are read or copied"
    mkdir -p -- "$output" || { log_error "cannot create output dir: $output"; return 1; }

    local d
    for d in "${SCAFFOLD_DIRS[@]}"; do
        mkdir -p -- "$output/$d" || { log_error "cannot scaffold $output/$d"; return 1; }
    done
    # Preserve the source's warning file convention (empty, no PII) so Moodle and
    # web crawlers still see the standard moodledata guard.
    printf '%s\n' \
        'This directory contains Moodle data files.' \
        'It is an NWP SCRUBBED (omit-and-placeholder) dev/preview copy:' \
        'filedir/ is empty and no user-uploaded files were copied from prod.' \
        > "$output/warning.txt"

    # ── scrub marker (records provenance; also the reuse sentinel) ─────────────
    {
        echo "scrubbed-by: lib/sanitizers/moodle-dataroot.sh (ops#84)"
        echo "strategy: omit-and-placeholder"
        echo "source-dataroot: $rc"
        echo "filedir: EMPTY (all user uploads omitted)"
        echo "note: kept mdl_files DB rows will render 'file missing' placeholders (expected)"
        echo "prune-hint: moosh file-dbcheck   # on the dev copy, to drop orphaned rows"
    } > "$output/$SCRUB_MARKER"

    # ── post-condition (fail-closed) ──────────────────────────────────────────
    if [ ! -d "$output/filedir" ]; then
        log_error "post-condition FAIL: emitted filedir/ missing"; return 1
    fi
    if [ -n "$(find "$output/filedir" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        log_error "post-condition FAIL: emitted filedir/ is NOT empty — refusing (fail-closed)"; return 1
    fi
    for d in "${FORBIDDEN_COPY_DIRS[@]}"; do
        if [ -d "$output/$d" ] && [ -n "$(find "$output/$d" -mindepth 1 -print -quit 2>/dev/null)" ]; then
            log_error "post-condition FAIL: '$d/' in output is not empty — a user file was copied (fail-closed)"; return 1
        fi
    done
    log "post-condition: filedir/ empty; no sessions/temp/trashdir content copied"
    log "NOTE: with an empty filedir, kept mdl_files rows show 'file missing' in dev —"
    log "      this is EXPECTED (see header); run 'moosh file-dbcheck' to prune if desired."
    log "done: scrubbed moodledata at $output"
    return 0
}

# ── main (guarded so the file can be sourced by unit tests without executing) ──
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    moodle_scrub_dataroot "$@"
    exit $?
fi
