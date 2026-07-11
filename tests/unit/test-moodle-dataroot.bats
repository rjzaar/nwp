#!/usr/bin/env bats
################################################################################
# Unit tests for lib/sanitizers/moodle-dataroot.sh — the moodledata scrubber,
# the on-disk sibling to lib/sanitizers/moodle.sh (ops#84).
#
# DOCKER-FREE, secret-free, filesystem-shape tests. We build a SYNTHETIC
# moodledata (fake filedir with a fake upload + sessions/temp files) and assert
# the omit-and-placeholder contract: empty filedir out, no transient content
# copied, and fail-closed refusals for non-moodledata / prod-in-place targets.
################################################################################

SCRUBBER="${BATS_TEST_DIRNAME}/../../lib/sanitizers/moodle-dataroot.sh"

# Build a synthetic live moodledata with realistic user content to omit.
_make_dataroot() { # $1 = path
    local dr="$1"
    mkdir -p "$dr/filedir/ab/cd" "$dr/sessions" "$dr/temp" "$dr/trashdir" \
             "$dr/cache" "$dr/localcache" "$dr/muc" "$dr/lock"
    # A fake content-addressed upload (an "assignment submission").
    echo "REAL STUDENT ASSIGNMENT PDF BYTES" > "$dr/filedir/ab/cd/abcd0123456789deadbeef"
    # A live session file (leaks a logged-in user) + a staged temp upload.
    echo "sess_realuser_token" > "$dr/sessions/sess_abc123"
    echo "staged upload" > "$dr/temp/upload.tmp"
    echo "deleted user file" > "$dr/trashdir/old.bin"
    echo "Moodle data files warning." > "$dr/warning.txt"
}

setup() {
    TMP="$(mktemp -d)"
    SRC="$TMP/moodledata"
    OUT="$TMP/scrubbed"
    _make_dataroot "$SRC"
}

teardown() {
    rm -rf "$TMP"
}

# ── happy path: omit-and-placeholder ─────────────────────────────────────────

@test "dataroot: scrubs a synthetic moodledata → empty filedir, no transient content" {
    run bash "$SCRUBBER" --dataroot "$SRC" --output "$OUT"
    [ "$status" -eq 0 ]
    # filedir exists but is empty
    [ -d "$OUT/filedir" ]
    [ -z "$(find "$OUT/filedir" -mindepth 1)" ]
    # no sessions / temp / trashdir content was copied
    [ -z "$(find "$OUT/sessions" -mindepth 1 2>/dev/null)" ]
    [ -z "$(find "$OUT/temp" -mindepth 1 2>/dev/null)" ]
    [ -z "$(find "$OUT/trashdir" -mindepth 1 2>/dev/null)" ]
    # the real upload never left the source
    [ -z "$(grep -rl 'REAL STUDENT ASSIGNMENT' "$OUT" 2>/dev/null)" ]
}

@test "dataroot: source moodledata is left untouched (READ-ONLY)" {
    run bash "$SCRUBBER" --dataroot "$SRC" --output "$OUT"
    [ "$status" -eq 0 ]
    # the real upload + session file must still be present in the SOURCE
    [ -f "$SRC/filedir/ab/cd/abcd0123456789deadbeef" ]
    [ -f "$SRC/sessions/sess_abc123" ]
}

@test "dataroot: emits a scrub marker documenting omit-and-placeholder" {
    run bash "$SCRUBBER" --dataroot "$SRC" --output "$OUT"
    [ "$status" -eq 0 ]
    [ -f "$OUT/.nwp-moodledata-scrubbed" ]
    grep -q "omit-and-placeholder" "$OUT/.nwp-moodledata-scrubbed"
    grep -q "moosh file-dbcheck" "$OUT/.nwp-moodledata-scrubbed"
}

@test "dataroot: emits a structurally valid, empty scaffold (filedir + system dirs)" {
    run bash "$SCRUBBER" --dataroot "$SRC" --output "$OUT"
    [ "$status" -eq 0 ]
    for d in filedir temp cache localcache muc sessions lock trashdir; do
        [ -d "$OUT/$d" ]
    done
    # nothing but the scaffold + marker + warning is present (no copied files)
    [ -z "$(find "$OUT" -type f ! -name '.nwp-moodledata-scrubbed' ! -name 'warning.txt' -print -quit)" ]
}

@test "dataroot: output header flags the mdl_files placeholder behaviour" {
    run bash "$SCRUBBER" --dataroot "$SRC" --output "$OUT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"file missing"* ]]
    [[ "$output" == *"EXPECTED"* ]]
}

# ── fail-closed refusals ─────────────────────────────────────────────────────

@test "dataroot: requires --dataroot and --output" {
    run bash "$SCRUBBER"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--dataroot"* ]]

    run bash "$SCRUBBER" --dataroot "$SRC"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--output"* ]]
}

@test "dataroot: refuses a directory that is not a moodledata (no filedir/muc marker)" {
    mkdir -p "$TMP/notmoodle/random"
    run bash "$SCRUBBER" --dataroot "$TMP/notmoodle" --output "$OUT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a moodledata"* ]]
}

@test "dataroot: refuses prod-in-place (output == dataroot)" {
    run bash "$SCRUBBER" --dataroot "$SRC" --output "$SRC"
    [ "$status" -ne 0 ]
    [[ "$output" == *"prod in place"* ]]
}

@test "dataroot: refuses writing INTO the live dataroot" {
    run bash "$SCRUBBER" --dataroot "$SRC" --output "$SRC/subdir"
    [ "$status" -ne 0 ]
    [[ "$output" == *"INSIDE the live dataroot"* ]]
}

@test "dataroot: refuses an output that CONTAINS the live dataroot" {
    run bash "$SCRUBBER" --dataroot "$SRC" --output "$TMP"
    [ "$status" -ne 0 ]
    [[ "$output" == *"CONTAINS the live dataroot"* ]]
}

@test "dataroot: refuses clobbering an existing real dataroot (populated filedir, no marker)" {
    _make_dataroot "$OUT"   # OUT is itself a populated real dataroot, no scrub marker
    run bash "$SCRUBBER" --dataroot "$SRC" --output "$OUT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to clobber"* ]]
}

@test "dataroot: a prior scrub target CAN be re-scrubbed (marker present)" {
    run bash "$SCRUBBER" --dataroot "$SRC" --output "$OUT"
    [ "$status" -eq 0 ]
    # second run over the prior scrub succeeds and stays clean
    run bash "$SCRUBBER" --dataroot "$SRC" --output "$OUT"
    [ "$status" -eq 0 ]
    [ -z "$(find "$OUT/filedir" -mindepth 1)" ]
}

# ── sourced-function contract (no execution on source) ───────────────────────

@test "dataroot: sourcing the file defines moodle_scrub_dataroot without running" {
    run bash -c "source '$SCRUBBER'; type moodle_scrub_dataroot"
    [ "$status" -eq 0 ]
    [[ "$output" == *"function"* ]]
}
