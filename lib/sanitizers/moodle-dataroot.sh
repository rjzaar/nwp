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
# (NWP-ADR-0031 plane 5b: "absolutely not — PII, minors' records").
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
#   moodle_scrub_dataroot <src_dataroot> <dst_dataroot>      # positional form
#     --dataroot DIR   Live Moodle moodledata (source, READ-ONLY).  REQUIRED.
#     --output   DIR   Destination for the scrubbed dev/preview moodledata.
#                      Must NOT be, contain, or sit inside --dataroot.  REQUIRED.
#     --verify         READ-ONLY: assert an ALREADY-PRODUCED --output is scrubbed
#                      (filedir/ empty, no sessions/temp/trash/cache content,
#                      marker present) and REPORT byte counts. Writes nothing;
#                      needs no --dataroot. Mirrors moodle.sh's --verify.
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

# Total bytes of regular files under a dir (0 when absent/empty). Read-only.
_bytes_under() {
    [ -d "$1" ] || { echo 0; return 0; }
    find "$1" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}'
}

# Count of regular files under a dir (0 when absent). Read-only.
_files_under() {
    [ -d "$1" ] || { echo 0; return 0; }
    find "$1" -type f 2>/dev/null | wc -l | tr -d ' '
}

# The tree's audited scratch-removal primitive, when it is reachable. Sourced
# best-effort: this library is also copied to the Moodle prod host standalone.
_IMPACT_SH="$(dirname -- "${BASH_SOURCE[0]}")/../impact.sh"
# shellcheck source=/dev/null
[ -f "$_IMPACT_SH" ] && . "$_IMPACT_SH" 2>/dev/null || true

################################################################################
# _rm_prior_scrub <dir> — audited removal of a PRIOR SCRUB OUTPUT.
#
# WHY NOT `rm -rf` DIRECTLY. This is the only destructive line in a
# SECURITY-CRITICAL sanitizer that legitimately runs on the Moodle prod host,
# where the wrong variable would delete live student uploads. A bare `rm -rf`
# here is indistinguishable — to a reviewer and to the impact-contract scanner —
# from that catastrophe.
#
# WHY NOT lib/impact.sh's impact_rm_scratch ALONE. That primitive proves
# ownership by LOCATION (the target must sit under a temp root). A scrub
# --output legitimately lives outside /tmp (a staging area, a backup volume), so
# location alone cannot decide this. We therefore prove ownership by EVIDENCE:
#   • the directory must carry OUR scrub marker, with OUR signature line, and
#   • its filedir/ must be EMPTY.
# The second is the load-bearing one: a directory holding real user uploads can
# never be removed by this path even if a marker were planted in it. When the
# target IS under a temp root we still hand off to impact_rm_scratch, so the
# common case goes through the tree's audited primitive.
#
# Returns 0 when the directory is gone, 1 (with a message on stderr) otherwise.
################################################################################
_rm_prior_scrub() {
    local dir="${1:-}"
    [ -n "$dir" ] || { log_error "refusing to remove: empty path"; return 1; }
    case "$dir" in
        /*) ;;
        *) log_error "refusing to remove non-absolute path: $dir"; return 1 ;;
    esac
    [ -L "$dir" ] && { log_error "refusing to remove a symlink: $dir"; return 1; }
    [ -d "$dir" ] || return 0   # already gone is success

    local real
    real="$(cd "$dir" 2>/dev/null && pwd -P)" || {
        log_error "refusing unresolvable path: $dir"; return 1; }
    # At least two levels deep: a slip resolving to "/" or "/var" must refuse.
    case "$real" in
        */*/*) ;;
        *) log_error "refusing shallow path '$real' — too close to the root (fail-closed)"; return 1 ;;
    esac
    # Evidence of ownership: our marker, with our signature line.
    if [ ! -f "$real/$SCRUB_MARKER" ]; then
        log_error "refusing '$real' — no $SCRUB_MARKER (not a prior scrub of ours; fail-closed)"; return 1
    fi
    if ! grep -q '^scrubbed-by: lib/sanitizers/moodle-dataroot.sh' "$real/$SCRUB_MARKER" 2>/dev/null; then
        log_error "refusing '$real' — $SCRUB_MARKER is not ours (fail-closed)"; return 1
    fi
    # The load-bearing guard: never delete a tree that holds user content.
    if [ -d "$real/filedir" ] && [ -n "$(find "$real/filedir" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        log_error "refusing '$real' — filedir/ is NOT empty (real user content?); fail-closed"; return 1
    fi

    # Prefer the tree's audited primitive when the target sits under a temp root;
    # it refuses anything else, so a non-temp target falls through to the
    # evidence-guarded removal above.
    if declare -F impact_rm_scratch >/dev/null 2>&1; then
        if impact_rm_scratch "$real" 2>/dev/null && [ ! -d "$real" ]; then
            return 0
        fi
    fi
    rm -rf "$real"
    [ ! -d "$real" ]
}

################################################################################
# moodle_verify_dataroot <dir> — READ-ONLY assertion over a PRODUCED output.
#
# The counterpart to lib/sanitizers/moodle.sh's `--verify` (which PII-sweeps an
# existing dump and writes nothing). This sweeps an existing scrubbed dataroot
# and writes nothing. It exists so a downstream step — or a reviewer, or CI —
# can re-assert the omission property on an artifact it did not itself produce,
# without trusting the producing run's own say-so.
#
# ASSERTS (all must hold):
#   - filedir/ exists and holds ZERO files and ZERO bytes.
#   - none of FORBIDDEN_COPY_DIRS holds any file (sessions/temp/trash/cache/...).
#   - the scrub marker is present (this really is an omit-and-placeholder copy).
# REPORTS byte counts for every checked dir, pass or fail, so the operator sees
# the magnitude of a leak rather than just its existence.
#
# Exit: 0 verified clean · 1 verification FAILED · 2 nothing to verify.
################################################################################
moodle_verify_dataroot() {
    local out="${1:-}"
    [ -n "$out" ] || { log_error "--verify requires --output DIR (the produced dataroot)"; return 2; }
    [ -d "$out" ] || { log_error "no scrubbed dataroot to verify: $out"; return 2; }

    log "verifying scrubbed dataroot (read-only): $out"
    local rc=0 n bytes d total=0

    # ── filedir must exist and be EMPTY — the whole point of the scrub ─────────
    if [ ! -d "$out/filedir" ]; then
        log_error "verify FAIL: filedir/ is missing — not a scrubbed dataroot (fail-closed)"
        rc=1
    else
        n="$(_files_under "$out/filedir")"
        bytes="$(_bytes_under "$out/filedir")"
        total=$((total + bytes))
        log "  filedir/            files=$n bytes=$bytes"
        if [ "$n" -ne 0 ] || [ "$bytes" -ne 0 ]; then
            log_error "verify FAIL: filedir/ holds $n file(s) / $bytes byte(s) — USER UPLOADS PRESENT"
            rc=1
        fi
    fi

    # ── nothing may have been copied into the transient/derived dirs ───────────
    for d in "${FORBIDDEN_COPY_DIRS[@]}"; do
        n="$(_files_under "$out/$d")"
        bytes="$(_bytes_under "$out/$d")"
        total=$((total + bytes))
        log "  $(printf '%-18s' "$d/") files=$n bytes=$bytes"
        if [ "$n" -ne 0 ] || [ "$bytes" -ne 0 ]; then
            log_error "verify FAIL: '$d/' holds $n file(s) / $bytes byte(s) — content was copied"
            rc=1
        fi
    done

    # ── provenance: this must be a declared omit-and-placeholder copy ──────────
    if [ ! -f "$out/$SCRUB_MARKER" ]; then
        log_error "verify FAIL: no $SCRUB_MARKER — provenance unproven (fail-closed)"
        rc=1
    fi

    log "  TOTAL bytes in scrubbed/omitted dirs: $total"
    if [ "$rc" -eq 0 ]; then
        log "verify: CLEAN — filedir/ empty, no sessions/temp/trash/cache content"
    else
        log_error "verify: FAILED — this dataroot is NOT safe to treat as scrubbed"
    fi
    return "$rc"
}

# ── moodle_scrub_dataroot — the sibling step ──────────────────────────────────
moodle_scrub_dataroot() {
    local dataroot="" output="" verify_only=false
    local -a positional=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --dataroot)   dataroot="$2"; shift 2 ;;
            --dataroot=*) dataroot="${1#*=}"; shift ;;
            --output)     output="$2"; shift 2 ;;
            --output=*)   output="${1#*=}"; shift ;;
            --verify)     verify_only=true; shift ;;
            -h|--help)    usage; return 0 ;;
            -*) log_error "unknown arg: $1"; return 2 ;;
            # Positional form named by ops#84: <src_dataroot> <dst_dataroot>.
            *) positional+=("$1"); shift ;;
        esac
    done
    # Positional operands fill whichever of the two is still unset, in order.
    if [ "${#positional[@]}" -gt 0 ]; then
        if [ "${#positional[@]}" -gt 2 ]; then
            log_error "too many positional args (expected <src_dataroot> <dst_dataroot>)"; return 2
        fi
        # --verify takes a single operand: the produced dst.
        if [ "$verify_only" = true ] && [ "${#positional[@]}" -eq 1 ]; then
            [ -n "$output" ] || output="${positional[0]}"
        else
            [ -n "$dataroot" ] || dataroot="${positional[0]}"
            [ "${#positional[@]}" -ge 2 ] && { [ -n "$output" ] || output="${positional[1]}"; }
        fi
    fi

    # ── --verify is a read-only sweep of an existing artifact; it writes nothing
    #    and needs no --dataroot (mirrors lib/sanitizers/moodle.sh --verify). ───
    if [ "$verify_only" = true ]; then
        moodle_verify_dataroot "$output"
        return $?
    fi

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
        # Audited removal: proves the target is OUR prior scrub AND that its
        # filedir/ is empty before anything is deleted. Never a bare rm -rf.
        _rm_prior_scrub "$oc" || { log_error "could not clear prior scrub target (fail-closed)"; return 1; }
    fi
    log "scrubbing moodledata (omit-and-placeholder): '$rc' → '$output'"
    log "  source is READ-ONLY; no user file bytes are read or copied"
    mkdir -p -- "$output" || { log_error "cannot create output dir: $output"; return 1; }

    local d
    for d in "${SCAFFOLD_DIRS[@]}"; do
        mkdir -p -- "$output/$d" || { log_error "cannot scaffold $output/$d"; return 1; }
    done
    # An NWP provenance note (empty of PII). NOTE: this is OURS, at the dataroot
    # root — it is NOT Moodle's own `filedir/warning.txt`, which Moodle writes
    # itself the moment it (re)creates filedir (lib/filestorage/file_system_filedir.php:86-92).
    # We deliberately do not write into filedir/: the emitted filedir must stay
    # byte-empty for the post-condition and --verify to mean anything.
    printf '%s\n' \
        'This directory contains Moodle data files.' \
        'It is an NWP SCRUBBED (omit-and-placeholder) dev/preview copy:' \
        'filedir/ is empty and no user-uploaded files were copied from prod.' \
        > "$output/warning.txt"

    # ── the protective .htaccess, exactly as Moodle's own installer writes it ──
    # Moodle's install_init_dataroot() (lib/installlib.php:140-147) drops a
    # "deny from all" .htaccess into dataroot, and protect_directory()
    # (lib/setuplib.php:1715-1725) re-writes it for every dir the
    # make_*_directory family creates. It is defence-in-depth against a
    # misconfigured Apache serving dataroot directly. Emitting the scaffold
    # WITHOUT it would hand the operator a dataroot LESS protected than one
    # Moodle built itself — so we reproduce it rather than rely on first boot.
    printf '%s\n' \
        'deny from all' \
        'AllowOverride None' \
        'Note: this file is broken intentionally, we do not want anybody to undo it' \
        > "$output/.htaccess"

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
