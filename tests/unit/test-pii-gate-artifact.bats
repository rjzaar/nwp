#!/usr/bin/env bats
################################################################################
# Unit tests for lib/pii-gate.sh :: pii_gate_scan_artifact — the bundle-aware
# independent gate (ops#111 / ADR-0032 Flow A). Verifies it:
#   - transparently delegates to pii_gate_scan for a plain .sql.gz (Drupal path),
#   - for a moodle-full bundle, extracts + scans the INNER db.sql.gz and asserts
#     the manifest attests an EMPTY filedir,
#   - is FAIL-CLOSED on every broken-bundle shape.
# Bundles are built by hand so the gate is tested independently of the sanitiser.
################################################################################

source "${BATS_TEST_DIRNAME}/../../lib/pii-gate.sh"

setup() { TMP="$(mktemp -d)"; }
teardown() { rm -rf "$TMP"; }

# _mk_bundle <out.tar.gz> <db-sql-or-empty> <manifest-or-empty>
# An empty ("") db or manifest arg omits that member (to test broken bundles).
_mk_bundle() {
    local out="$1" db="$2" man="$3" d; d="$(mktemp -d)"; local -a files=()
    [ -n "$db" ]  && { printf '%s\n' "$db"  | gzip > "$d/db.sql.gz"; files+=(db.sql.gz); }
    [ -n "$man" ] && { printf '%s\n' "$man" > "$d/dataroot-manifest.txt"; files+=(dataroot-manifest.txt); }
    ( cd "$d" && tar -czf "$out" "${files[@]}" )
    rm -rf "$d"
}

CLEAN_SQL="INSERT INTO user VALUES('user2@sanitized.test','user3@example.com');"
DIRTY_SQL="INSERT INTO user VALUES('realperson@gmail.com');"
GOOD_MAN="strategy: omit-and-placeholder
filedir: EMPTY (all 3 user upload(s) omitted; no bytes copied off prod)"
BAD_MAN="strategy: copied
filedir: present"

# ── bundle happy path ─────────────────────────────────────────────────────────

@test "artifact: a clean moodle-full bundle passes (inner db clean + manifest attests empty filedir)" {
    _mk_bundle "$TMP/b.tar.gz" "$CLEAN_SQL" "$GOOD_MAN"
    run pii_gate_scan_artifact "$TMP/b.tar.gz"
    [ "$status" -eq 0 ]
}

# ── bundle fail-closed shapes ─────────────────────────────────────────────────

@test "artifact: bundle with PII in the inner db FAILS" {
    _mk_bundle "$TMP/b.tar.gz" "$DIRTY_SQL" "$GOOD_MAN"
    run pii_gate_scan_artifact "$TMP/b.tar.gz"
    [ "$status" -eq 1 ]
}

@test "artifact: bundle whose manifest does NOT attest empty filedir FAILS" {
    _mk_bundle "$TMP/b.tar.gz" "$CLEAN_SQL" "$BAD_MAN"
    run pii_gate_scan_artifact "$TMP/b.tar.gz"
    [ "$status" -eq 1 ]
    [[ "$output" == *"filedir: EMPTY"* ]]   # names the missing attestation
}

@test "artifact: bundle missing the manifest FAILS" {
    _mk_bundle "$TMP/b.tar.gz" "$CLEAN_SQL" ""
    run pii_gate_scan_artifact "$TMP/b.tar.gz"
    [ "$status" -eq 1 ]
}

# (a tar with no db.sql.gz is not detected as a bundle → falls through to the
#  plain-file path, which fails to read it as a gzipped SQL dump → non-zero)
@test "artifact: a tar without db.sql.gz does not pass as clean" {
    _mk_bundle "$TMP/b.tar.gz" "" "$GOOD_MAN"
    run pii_gate_scan_artifact "$TMP/b.tar.gz"
    [ "$status" -ne 0 ]
}

# ── plain .sql.gz delegation (Drupal path unchanged) ──────────────────────────

@test "artifact: a plain clean .sql.gz delegates to pii_gate_scan and passes" {
    printf '%s\n' "$CLEAN_SQL" | gzip > "$TMP/d.sql.gz"
    run pii_gate_scan_artifact "$TMP/d.sql.gz"
    [ "$status" -eq 0 ]
}

@test "artifact: a plain dirty .sql.gz delegates and FAILS" {
    printf '%s\n' "$DIRTY_SQL" | gzip > "$TMP/d.sql.gz"
    run pii_gate_scan_artifact "$TMP/d.sql.gz"
    [ "$status" -eq 1 ]
}

@test "artifact: missing / unreadable file is fail-closed (exit 2)" {
    run pii_gate_scan_artifact "$TMP/does-not-exist.tar.gz"
    [ "$status" -eq 2 ]
}
