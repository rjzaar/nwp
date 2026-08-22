#!/usr/bin/env bats
################################################################################
# Unit tests for lib/moodle-fixture-load.sh — the dev/stg fixture LOADER core
# (ops#111 / NWP-ADR-0032 Flow A, increment 2b). Docker-free, secret-free.
#   - moodle_fixture_verify_extract: gate + extract the inner db.sql.gz, fail-closed
#   - moodle_scaffold_empty_dataroot: rebuild an EMPTY moodledata, never clobber
#     a populated real dataroot.
################################################################################

source "${BATS_TEST_DIRNAME}/../../lib/moodle-fixture-load.sh"

setup() { TMP="$(mktemp -d)"; WORK="$TMP/work"; }
teardown() { rm -rf "$TMP"; }

# _mk_bundle <out.tar.gz> <db-sql-or-empty> <manifest-or-empty>
_mk_bundle() {
    local out="$1" db="$2" man="$3" d; d="$(mktemp -d)"; local -a files=()
    [ -n "$db" ]  && { printf '%s\n' "$db"  | gzip > "$d/db.sql.gz"; files+=(db.sql.gz); }
    [ -n "$man" ] && { printf '%s\n' "$man" > "$d/dataroot-manifest.txt"; files+=(dataroot-manifest.txt); }
    ( cd "$d" && tar -czf "$out" "${files[@]}" )
    rm -rf "$d"
}

CLEAN_SQL="INSERT INTO user VALUES('user2@sanitized.test');"
DIRTY_SQL="INSERT INTO user VALUES('realperson@gmail.com');"
GOOD_MAN="filedir: EMPTY (all 2 user upload(s) omitted; no bytes copied off prod)"

# ── moodle_fixture_verify_extract ─────────────────────────────────────────────

@test "verify_extract: a clean bundle gates + yields db.sql.gz" {
    _mk_bundle "$TMP/b.tar.gz" "$CLEAN_SQL" "$GOOD_MAN"
    run moodle_fixture_verify_extract "$TMP/b.tar.gz" "$WORK"
    [ "$status" -eq 0 ]
    [ -s "$WORK/db.sql.gz" ]
    [[ "$output" == *"$WORK/db.sql.gz"* ]]
}

@test "verify_extract: a bundle with PII in the inner db is REFUSED (no load)" {
    _mk_bundle "$TMP/b.tar.gz" "$DIRTY_SQL" "$GOOD_MAN"
    run moodle_fixture_verify_extract "$TMP/b.tar.gz" "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"PII gate FAILED"* ]]
}

@test "verify_extract: a bundle whose manifest lacks 'filedir: EMPTY' is REFUSED" {
    _mk_bundle "$TMP/b.tar.gz" "$CLEAN_SQL" "filedir: present"
    run moodle_fixture_verify_extract "$TMP/b.tar.gz" "$WORK"
    [ "$status" -eq 1 ]
}

@test "verify_extract: a plain .sql.gz (not a bundle) is REFUSED (loader expects a bundle)" {
    printf '%s\n' "$CLEAN_SQL" | gzip > "$TMP/plain.sql.gz"
    run moodle_fixture_verify_extract "$TMP/plain.sql.gz" "$WORK"
    [ "$status" -ne 0 ]
}

@test "verify_extract: a missing bundle is fail-closed (exit 2)" {
    run moodle_fixture_verify_extract "$TMP/nope.tar.gz" "$WORK"
    [ "$status" -eq 2 ]
}

# ── moodle_scaffold_empty_dataroot ────────────────────────────────────────────

@test "scaffold: builds an empty, structurally-valid dataroot + marker" {
    dr="$TMP/moodledata"
    run moodle_scaffold_empty_dataroot "$dr"
    [ "$status" -eq 0 ]
    [ -d "$dr/filedir" ]
    [ -z "$(find "$dr/filedir" -mindepth 1)" ]      # empty
    [ -d "$dr/sessions" ] && [ -d "$dr/temp" ] && [ -d "$dr/muc" ]
    [ -f "$dr/$MFL_SCRUB_MARKER" ]
}

@test "scaffold: refuses to clobber a POPULATED real dataroot (no marker)" {
    dr="$TMP/realdata"
    mkdir -p "$dr/filedir/ab/cd"
    echo "REAL UPLOAD" > "$dr/filedir/ab/cd/deadbeef"
    run moodle_scaffold_empty_dataroot "$dr"
    [ "$status" -eq 1 ]
    [[ "$output" == *"refusing to clobber"* ]]
    # the real upload must be untouched
    [ -f "$dr/filedir/ab/cd/deadbeef" ]
}

@test "scaffold: a prior scaffold (marker present) can be reused" {
    dr="$TMP/moodledata"
    moodle_scaffold_empty_dataroot "$dr"            # first run drops the marker
    run moodle_scaffold_empty_dataroot "$dr"        # second run must succeed
    [ "$status" -eq 0 ]
    [ -z "$(find "$dr/filedir" -mindepth 1)" ]
}

@test "scaffold: requires a target path (fail-closed)" {
    run moodle_scaffold_empty_dataroot ""
    [ "$status" -eq 2 ]
}

# ── moodle_fixture_load (orchestration; importer injected as a stub) ───────────

# A stub importer that records the db path it was handed (proves ordering).
_stub_import()      { echo "$1" > "$TMP/imported"; return 0; }
_stub_import_fail() { echo "$1" > "$TMP/imported"; return 1; }

@test "load: clean bundle → gate, import (with db path), then empty scaffold" {
    _mk_bundle "$TMP/b.tar.gz" "$CLEAN_SQL" "$GOOD_MAN"
    dr="$TMP/moodledata"
    run moodle_fixture_load "$TMP/b.tar.gz" "$dr" _stub_import
    [ "$status" -eq 0 ]
    [ -f "$TMP/imported" ]                          # importer ran
    [[ "$(cat "$TMP/imported")" == *db.sql.gz ]]    # ...with the extracted db
    [ -d "$dr/filedir" ] && [ -z "$(find "$dr/filedir" -mindepth 1)" ]  # scaffold built
}

@test "load: a dirty bundle is REFUSED and the importer is NEVER called" {
    _mk_bundle "$TMP/b.tar.gz" "$DIRTY_SQL" "$GOOD_MAN"
    dr="$TMP/moodledata"
    run moodle_fixture_load "$TMP/b.tar.gz" "$dr" _stub_import
    [ "$status" -ne 0 ]
    [ ! -f "$TMP/imported" ]                        # gate blocked the import
    [ ! -d "$dr/filedir" ]                          # and no scaffold was built
}

@test "load: an import failure is fail-closed (non-zero, no scaffold)" {
    _mk_bundle "$TMP/b.tar.gz" "$CLEAN_SQL" "$GOOD_MAN"
    dr="$TMP/moodledata"
    run moodle_fixture_load "$TMP/b.tar.gz" "$dr" _stub_import_fail
    [ "$status" -eq 1 ]
    [ ! -d "$dr/filedir" ]                          # scaffold not reached after import failure
}

@test "load: requires bundle, dataroot, and import command" {
    run moodle_fixture_load "" "$TMP/dr" _stub_import
    [ "$status" -eq 2 ]
    run moodle_fixture_load "$TMP/b.tar.gz" "" _stub_import
    [ "$status" -eq 2 ]
    run moodle_fixture_load "$TMP/b.tar.gz" "$TMP/dr" ""
    [ "$status" -eq 2 ]
}
