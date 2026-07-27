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
    # nothing but the scaffold + marker + warning + protective .htaccess is
    # present (no copied files)
    [ -z "$(find "$OUT" -type f ! -name '.nwp-moodledata-scrubbed' ! -name 'warning.txt' ! -name '.htaccess' -print -quit)" ]
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

################################################################################
# ops#84 follow-up: --verify mode, the protective .htaccess, the positional
# form, and the audited removal of a prior scrub.
################################################################################

# A DELIBERATELY BROKEN "scrubber": copies EVERYTHING (the naive `cp -a` a
# hurried operator would reach for) and stamps a valid-looking marker. This is
# the adversary --verify exists to catch; if --verify ever passes this, the
# verifier is worthless.
_make_copy_everything_variant() { # $1 = src, $2 = dst
    cp -a "$1" "$2"
    {
        echo "scrubbed-by: lib/sanitizers/moodle-dataroot.sh (ops#84)"
        echo "strategy: omit-and-placeholder"
    } > "$2/.nwp-moodledata-scrubbed"
}

# ── --verify: the read-only assertion over a produced dataroot ────────────────

@test "dataroot --verify: PASSES a genuinely scrubbed dataroot" {
    run bash "$SCRUBBER" --dataroot "$SRC" --output "$OUT"
    [ "$status" -eq 0 ]
    run bash "$SCRUBBER" --verify --output "$OUT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAN"* ]]
}

@test "dataroot --verify: REJECTS a copy-everything variant (real student upload present)" {
    _make_copy_everything_variant "$SRC" "$OUT"
    run bash "$SCRUBBER" --verify --output "$OUT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"USER UPLOADS PRESENT"* ]]
}

@test "dataroot --verify: REJECTS a single planted file in filedir" {
    run bash "$SCRUBBER" --dataroot "$SRC" --output "$OUT"
    [ "$status" -eq 0 ]
    mkdir -p "$OUT/filedir/ab/cd"
    echo "LEAKED SUBMISSION" > "$OUT/filedir/ab/cd/deadbeef"
    run bash "$SCRUBBER" --verify --output "$OUT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"USER UPLOADS PRESENT"* ]]
}

@test "dataroot --verify: REJECTS copied sessions content" {
    run bash "$SCRUBBER" --dataroot "$SRC" --output "$OUT"
    [ "$status" -eq 0 ]
    echo "sess_realuser_token" > "$OUT/sessions/sess_abc123"
    run bash "$SCRUBBER" --verify --output "$OUT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"sessions"* ]]
    [[ "$output" == *"content was copied"* ]]
}

@test "dataroot --verify: REPORTS byte counts for filedir and the omitted dirs" {
    run bash "$SCRUBBER" --dataroot "$SRC" --output "$OUT"
    [ "$status" -eq 0 ]
    run bash "$SCRUBBER" --verify --output "$OUT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"filedir/"*"files=0 bytes=0"* ]]
    [[ "$output" == *"TOTAL bytes"* ]]
}

@test "dataroot --verify: byte report shows the MAGNITUDE of a leak, not just its existence" {
    _make_copy_everything_variant "$SRC" "$OUT"
    run bash "$SCRUBBER" --verify --output "$OUT"
    [ "$status" -eq 1 ]
    # the leaked assignment is 34 bytes; the report must show a non-zero count
    [[ "$output" =~ filedir/[[:space:]]+files=1[[:space:]]bytes=[1-9] ]]
}

@test "dataroot --verify: REJECTS a dataroot with no scrub marker (provenance unproven)" {
    run bash "$SCRUBBER" --dataroot "$SRC" --output "$OUT"
    [ "$status" -eq 0 ]
    rm -f "$OUT/.nwp-moodledata-scrubbed"
    run bash "$SCRUBBER" --verify --output "$OUT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"provenance unproven"* ]]
}

@test "dataroot --verify: exits 2 when there is nothing to verify" {
    run bash "$SCRUBBER" --verify --output "$TMP/does-not-exist"
    [ "$status" -eq 2 ]
    [[ "$output" == *"no scrubbed dataroot to verify"* ]]
}

@test "dataroot --verify: is READ-ONLY — writes nothing into the target" {
    run bash "$SCRUBBER" --dataroot "$SRC" --output "$OUT"
    [ "$status" -eq 0 ]
    local before after
    before="$(find "$OUT" | sort | md5sum)"
    run bash "$SCRUBBER" --verify --output "$OUT"
    [ "$status" -eq 0 ]
    after="$(find "$OUT" | sort | md5sum)"
    [ "$before" = "$after" ]
}

# ── positional form named by the ops#84 issue text ────────────────────────────

@test "dataroot: accepts the positional <src> <dst> form" {
    run bash "$SCRUBBER" "$SRC" "$OUT"
    [ "$status" -eq 0 ]
    [ -d "$OUT/filedir" ]
    [ -z "$(find "$OUT/filedir" -mindepth 1)" ]
}

@test "dataroot: positional --verify takes the produced dst" {
    run bash "$SCRUBBER" "$SRC" "$OUT"
    [ "$status" -eq 0 ]
    run bash "$SCRUBBER" --verify "$OUT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAN"* ]]
}

# ── the protective .htaccess Moodle's own installer writes ────────────────────
# Evidence: lib/installlib.php:140-147 (install_init_dataroot) writes a
# "deny from all" .htaccess into dataroot as defence-in-depth, and
# lib/setuplib.php:1715-1725 (protect_directory) re-writes it for every dir the
# make_*_directory family creates. A scrubbed dataroot without it is LESS
# protected than one Moodle built itself.

@test "dataroot: emits the protective .htaccess (deny from all) like Moodle's installer" {
    run bash "$SCRUBBER" --dataroot "$SRC" --output "$OUT"
    [ "$status" -eq 0 ]
    [ -f "$OUT/.htaccess" ]
    grep -qi "deny from all" "$OUT/.htaccess"
}

# ── audited removal of a prior scrub (no bare rm -rf) ─────────────────────────

@test "dataroot: refuses to clear a marker-bearing target whose filedir is NOT empty" {
    # A planted marker must NOT be enough to get real user content deleted.
    _make_dataroot "$OUT"
    {
        echo "scrubbed-by: lib/sanitizers/moodle-dataroot.sh (ops#84)"
    } > "$OUT/.nwp-moodledata-scrubbed"
    run bash "$SCRUBBER" --dataroot "$SRC" --output "$OUT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"filedir/ is NOT empty"* ]]
    # the "real" content survived the refusal
    [ -f "$OUT/filedir/ab/cd/abcd0123456789deadbeef" ]
}

@test "dataroot: the removal helper refuses a target that is not ours" {
    run bash -c "source '$SCRUBBER'; mkdir -p '$TMP/notours'; _rm_prior_scrub '$TMP/notours'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a prior scrub of ours"* ]]
    [ -d "$TMP/notours" ]
}

@test "dataroot: the removal helper refuses a shallow path" {
    run bash -c "source '$SCRUBBER'; _rm_prior_scrub /tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"too close to the root"* ]]
}

@test "dataroot: the removal helper refuses a relative path" {
    run bash -c "source '$SCRUBBER'; _rm_prior_scrub 'relative/path'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"non-absolute"* ]]
}
