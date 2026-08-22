#!/usr/bin/env bats
################################################################################
# Unit tests for lib/sanitizers/moodle-full.sh — the atomic "full Moodle
# sanitised artifact" orchestrator (ops#111 / NWP-ADR-0032 Flow A).
#
# DOCKER-FREE, secret-free. The DB step (moodle.sh) needs a live DB, so we
# inject a STUB DB sanitiser via NWP_MOODLE_DB_SANITIZER; the moodledata scrub
# (moodle-dataroot.sh) and the PII gate (pii-gate.sh) run FOR REAL against
# synthetic fixtures. We assert the composition contract: one clean bundle out,
# or fail-closed with NO artifact.
################################################################################

ORCH="${BATS_TEST_DIRNAME}/../../lib/sanitizers/moodle-full.sh"

# A stub DB sanitiser matching moodle.sh's CLI (--site-dir/--output). Writes a
# gzipped SQL dump whose PII-cleanliness we control via STUB_DB_MODE.
_write_stub_db_sanitizer() { # $1 = path  $2 = clean|dirty|fail|empty
    local path="$1" mode="$2"
    cat > "$path" <<STUB
#!/bin/bash
out=""
while [ \$# -gt 0 ]; do case "\$1" in --output) out="\$2"; shift 2;; --output=*) out="\${1#*=}"; shift;; *) shift;; esac; done
case "$mode" in
  fail)  echo "stub: DB sanitiser failing on purpose" >&2; exit 1 ;;
  empty) : > "\$out" ;;                                   # zero-byte output
  dirty) printf "INSERT INTO user VALUES('realperson@gmail.com');\n" | gzip > "\$out" ;;
  *)     printf "INSERT INTO user VALUES('user2@sanitized.test');\n" | gzip > "\$out" ;;
esac
exit 0
STUB
    chmod +x "$path"
}

_make_dataroot() { # $1 = path
    local dr="$1"
    mkdir -p "$dr/filedir/ab/cd" "$dr/sessions" "$dr/temp"
    echo "REAL STUDENT ASSIGNMENT PDF BYTES" > "$dr/filedir/ab/cd/abcd0123456789deadbeef"
    echo "sess_realuser_token" > "$dr/sessions/sess_abc123"
}

setup() {
    TMP="$(mktemp -d)"
    SITE_DIR="$TMP/moodleroot"
    mkdir -p "$SITE_DIR"
    : > "$SITE_DIR/version.php"          # marks it a Moodle root
    : > "$SITE_DIR/config.php"           # present but empty → dataroot falls back
    DATAROOT="$TMP/moodledata"
    _make_dataroot "$DATAROOT"
    OUT="$TMP/bundle.tar.gz"
    STUB="$TMP/stub-db.sh"
    export NWP_MOODLE_DB_SANITIZER="$STUB"
}

teardown() { rm -rf "$TMP"; unset NWP_MOODLE_DB_SANITIZER; }

# ── happy path ────────────────────────────────────────────────────────────────

@test "moodle-full: composes a clean bundle (db + manifest); source files never copied" {
    _write_stub_db_sanitizer "$STUB" clean
    run bash "$ORCH" --site-dir "$SITE_DIR" --dataroot "$DATAROOT" --output "$OUT"
    [ "$status" -eq 0 ]
    [ -s "$OUT" ]
    tar -tzf "$OUT" | grep -qx 'db.sql.gz'
    tar -tzf "$OUT" | grep -qx 'dataroot-manifest.txt'
    # the real upload bytes must NOT be anywhere in the bundle
    tmpx="$(mktemp -d)"; tar -xzf "$OUT" -C "$tmpx"
    [ -z "$(grep -rl 'REAL STUDENT ASSIGNMENT' "$tmpx" 2>/dev/null)" ]
    grep -q 'filedir: EMPTY' "$tmpx/dataroot-manifest.txt"
    rm -rf "$tmpx"
}

@test "moodle-full: manifest counts the omitted source uploads" {
    _write_stub_db_sanitizer "$STUB" clean
    run bash "$ORCH" --site-dir "$SITE_DIR" --dataroot "$DATAROOT" --output "$OUT"
    [ "$status" -eq 0 ]
    tmpx="$(mktemp -d)"; tar -xzf "$OUT" -C "$tmpx" dataroot-manifest.txt
    grep -qE '1 user upload' "$tmpx/dataroot-manifest.txt"   # one file in synthetic filedir
    rm -rf "$tmpx"
}

@test "moodle-full: --verify passes a freshly built clean bundle" {
    _write_stub_db_sanitizer "$STUB" clean
    bash "$ORCH" --site-dir "$SITE_DIR" --dataroot "$DATAROOT" --output "$OUT"
    run bash "$ORCH" --verify --output "$OUT"
    [ "$status" -eq 0 ]
}

# ── fail-closed paths: NO artifact must survive ───────────────────────────────

@test "moodle-full: a dirty DB dump is caught by the gate → fail-closed, no bundle" {
    _write_stub_db_sanitizer "$STUB" dirty
    run bash "$ORCH" --site-dir "$SITE_DIR" --dataroot "$DATAROOT" --output "$OUT"
    [ "$status" -ne 0 ]
    [ ! -f "$OUT" ]
    [[ "$output" == *"PII gate FAILED"* ]]
}

@test "moodle-full: DB sanitiser failure → fail-closed, no bundle" {
    _write_stub_db_sanitizer "$STUB" fail
    run bash "$ORCH" --site-dir "$SITE_DIR" --dataroot "$DATAROOT" --output "$OUT"
    [ "$status" -ne 0 ]
    [ ! -f "$OUT" ]
}

@test "moodle-full: empty DB dump → fail-closed, no bundle" {
    _write_stub_db_sanitizer "$STUB" empty
    run bash "$ORCH" --site-dir "$SITE_DIR" --dataroot "$DATAROOT" --output "$OUT"
    [ "$status" -ne 0 ]
    [ ! -f "$OUT" ]
}

@test "moodle-full: a non-Moodle dataroot (no filedir/muc) → fail-closed, no bundle" {
    _write_stub_db_sanitizer "$STUB" clean
    baddr="$TMP/notdata"; mkdir -p "$baddr"
    run bash "$ORCH" --site-dir "$SITE_DIR" --dataroot "$baddr" --output "$OUT"
    [ "$status" -ne 0 ]
    [ ! -f "$OUT" ]
}

@test "moodle-full: refuses a non-Moodle site root (no version.php)" {
    _write_stub_db_sanitizer "$STUB" clean
    rm -f "$SITE_DIR/version.php"
    run bash "$ORCH" --site-dir "$SITE_DIR" --dataroot "$DATAROOT" --output "$OUT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"version.php"* ]]
    [ ! -f "$OUT" ]
}

@test "moodle-full: requires --site-dir" {
    run bash "$ORCH" --output "$OUT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--site-dir"* ]]
}
