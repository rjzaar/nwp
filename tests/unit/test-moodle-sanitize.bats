#!/usr/bin/env bats
################################################################################
# Unit tests for lib/sanitizers/moodle.sh — the prod-native Moodle sanitizer.
#
# These are DOCKER-FREE structural / fail-closed tests (mirroring
# test-sanitize-dispatch.bats' "runs with NO ddev/drush" contract). The full
# anonymisation is exercised end-to-end against a synthetic Moodle DB by
# tests/integration/test-moodle-sanitize-synthetic.sh, which needs a running
# database container and self-skips without one.
#
# HARD RULE: no real Moodle DB, no secrets. Where a salt is needed we export a
# synthetic OIDC_SANITIZER_SALT (never read .secrets.data.yml).
################################################################################

SANITIZER="${BATS_TEST_DIRNAME}/../../lib/sanitizers/moodle.sh"

setup() {
    TMP="$(mktemp -d)"
    export OIDC_SANITIZER_SALT="test-salt-0123456789abcdef0123456789"
}

teardown() {
    rm -rf "$TMP"
}

# ── fail-closed on shape ──────────────────────────────────────────────────────

@test "moodle.sh: requires --site-dir" {
    run bash "$SANITIZER"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--site-dir"* ]]
}

@test "moodle.sh: refuses a dir with no version.php (not a Moodle root)" {
    run bash "$SANITIZER" --site-dir "$TMP"
    [ "$status" -ne 0 ]
    [[ "$output" == *"version.php"* ]]
}

@test "moodle.sh: refuses a Moodle root with no config.php (fail-closed)" {
    touch "$TMP/version.php"
    run bash "$SANITIZER" --site-dir "$TMP"
    [ "$status" -ne 0 ]
    [[ "$output" == *"config.php"* ]]
}

@test "moodle.sh: refuses when \$CFG->prefix is empty (never guesses mdl_)" {
    touch "$TMP/version.php"
    # A config.php that sets creds but leaves prefix empty, and a stub setup.php
    # so the ABORT_AFTER_CONFIG require resolves without a full Moodle tree.
    cat > "$TMP/config.php" <<'EOF'
<?php
$CFG = new stdClass();
$CFG->dbname = 'x';
$CFG->dbuser = 'y';
$CFG->dbpass = 'z';
$CFG->dbhost = '127.0.0.1';
$CFG->prefix = '';
require_once(__DIR__ . '/lib/setup.php');
EOF
    mkdir -p "$TMP/lib"
    echo '<?php return;' > "$TMP/lib/setup.php"
    run bash "$SANITIZER" --site-dir "$TMP"
    [ "$status" -ne 0 ]
    [[ "$output" == *"prefix"* ]]
}

@test "moodle.sh: refuses a prefix with illegal chars (identifier-injection guard)" {
    touch "$TMP/version.php"
    cat > "$TMP/config.php" <<'EOF'
<?php
$CFG = new stdClass();
$CFG->dbname = 'x';
$CFG->dbuser = 'y';
$CFG->dbpass = 'z';
$CFG->dbhost = '127.0.0.1';
$CFG->prefix = 'mdl`;DROP';
require_once(__DIR__ . '/lib/setup.php');
EOF
    mkdir -p "$TMP/lib"
    echo '<?php return;' > "$TMP/lib/setup.php"
    run bash "$SANITIZER" --site-dir "$TMP"
    [ "$status" -ne 0 ]
    [[ "$output" == *"identifier-injection guard"* || "$output" == *"unexpected characters"* ]]
}

# ── --verify PII sweep (reads an artifact; no DB) ─────────────────────────────

@test "moodle.sh --verify: passes a clean dump (sanitized emails only)" {
    dump="$TMP/clean.sql.gz"
    printf "INSERT INTO mdl_user VALUES (2,'abcdef0123456789@sanitized.test');\n" | gzip > "$dump"
    run bash "$SANITIZER" --verify --output "$dump"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PII sweep: clean"* ]]
}

@test "moodle.sh --verify: FAILS a dump that still holds a real email" {
    dump="$TMP/dirty.sql.gz"
    printf "INSERT INTO mdl_user VALUES (2,'teacher.real@school.example.test');\n" | gzip > "$dump"
    # school.example.test is not an allowlisted sanitized form → must fail.
    run bash "$SANITIZER" --verify --output "$dump"
    [ "$status" -ne 0 ]
    [[ "$output" == *"PII sweep FAIL"* ]]
}

@test "moodle.sh --verify: missing artifact is fail-closed (exit 2)" {
    run bash "$SANITIZER" --verify --output "$TMP/nope.sql.gz"
    [ "$status" -eq 2 ]
}
