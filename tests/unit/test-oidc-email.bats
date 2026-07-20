#!/usr/bin/env bats
################################################################################
# Unit tests for lib/sanitizers/oidc-email.sh
#
# Exercises the deterministic email hash used by F26's AVC↔SS sanitizer
# coupling. Tests never read a real .secrets.data.yml — they set
# OIDC_SANITIZER_SALT directly in the environment.
################################################################################

load ../helpers/test-helpers

setup() {
    test_setup
    export NWP_ROOT="${PROJECT_ROOT}"
    # shellcheck source=/dev/null
    source "${PROJECT_ROOT}/lib/sanitizers/oidc-email.sh"
    # Stable 32-byte test salt (not a real secret)
    export OIDC_SANITIZER_SALT="test-salt-0123456789abcdef0123456789"
}

teardown() {
    test_teardown
}

################################################################################
# oidc_email_sanitize — determinism and shape
################################################################################

@test "oidc_email_sanitize: same input → same output (determinism)" {
    a=$(oidc_email_sanitize "alice@example.com")
    b=$(oidc_email_sanitize "alice@example.com")
    [ "$a" = "$b" ]
}

@test "oidc_email_sanitize: different inputs → different outputs" {
    a=$(oidc_email_sanitize "alice@example.com")
    b=$(oidc_email_sanitize "bob@example.com")
    [ "$a" != "$b" ]
}

@test "oidc_email_sanitize: output has @sanitized.test suffix" {
    a=$(oidc_email_sanitize "alice@example.com")
    [[ "$a" == *"@sanitized.test" ]]
}

@test "oidc_email_sanitize: output prefix is exactly 16 hex chars" {
    a=$(oidc_email_sanitize "alice@example.com")
    prefix="${a%@sanitized.test}"
    [ "${#prefix}" -eq 16 ]
    [[ "$prefix" =~ ^[0-9a-f]{16}$ ]]
}

@test "oidc_email_sanitize: empty input → empty output (not salt hash)" {
    a=$(oidc_email_sanitize "")
    [ -z "$a" ]
}

@test "oidc_email_sanitize: whitespace-only input → empty output" {
    a=$(oidc_email_sanitize "   ")
    [ -z "$a" ]
}

@test "oidc_email_sanitize: different salts → different outputs" {
    a=$(OIDC_SANITIZER_SALT="test-salt-0000000000000000000000aaaa" \
        oidc_email_sanitize "alice@example.com")
    b=$(OIDC_SANITIZER_SALT="test-salt-0000000000000000000000bbbb" \
        oidc_email_sanitize "alice@example.com")
    [ "$a" != "$b" ]
}

@test "oidc_email_sanitize: refuses too-short salt (<16 bytes)" {
    run bash -c 'unset OIDC_SANITIZER_SALT; export OIDC_SANITIZER_SALT="short"; source "'"${PROJECT_ROOT}"'/lib/sanitizers/oidc-email.sh"; oidc_email_sanitize alice@example.com'
    [ "$status" -ne 0 ]
    [[ "$output" == *"too short"* ]]
}

@test "oidc_email_sanitize: does not leak salt to stdout" {
    out=$(oidc_email_sanitize "alice@example.com")
    [[ "$out" != *"$OIDC_SANITIZER_SALT"* ]]
}

################################################################################
# Cross-site consistency (the actual F26 property)
################################################################################

@test "oidc_email_sanitize: AVC and SS sanitizers produce matching output for same real email" {
    # Simulate two separate sanitizer runs, both with the same shared salt
    # (F26 § 3.3 — this is the invariant the OIDC preview coupling relies on)
    salt="test-salt-0123456789abcdef0123456789"

    avc_out=$(OIDC_SANITIZER_SALT="$salt" oidc_email_sanitize "jane@real.example.org")
    ss_out=$(OIDC_SANITIZER_SALT="$salt" oidc_email_sanitize "jane@real.example.org")

    [ "$avc_out" = "$ss_out" ]
    [[ "$avc_out" == *"@sanitized.test" ]]
}

################################################################################
# oidc_email_salt_load — .secrets.data.yml parser
################################################################################

@test "oidc_email_salt_load: reads dotted key from fixture file" {
    unset OIDC_SANITIZER_SALT
    fixture="${TEST_TEMP_DIR}/secrets.data.yml"
    cat > "$fixture" <<'EOF'
other:
  unused: ignore-me
oidc:
  sanitizer_salt: deterministic-fixture-salt-abcdef0123456789
database:
  password: not-the-salt
EOF
    export OIDC_SANITIZER_SALT_FILE="$fixture"
    run oidc_email_salt_load
    [ "$status" -eq 0 ]
    # The salt should now be exported (test in a follow-up call)
    unset OIDC_SANITIZER_SALT
    oidc_email_salt_load
    [ "$OIDC_SANITIZER_SALT" = "deterministic-fixture-salt-abcdef0123456789" ]
}

@test "oidc_email_salt_load: refuses when salt file missing" {
    unset OIDC_SANITIZER_SALT
    export OIDC_SANITIZER_SALT_FILE="/nonexistent/secrets.data.yml"
    run oidc_email_salt_load
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "oidc_email_salt_load: refuses short salt from file" {
    unset OIDC_SANITIZER_SALT
    fixture="${TEST_TEMP_DIR}/secrets.data.yml"
    cat > "$fixture" <<'EOF'
oidc:
  sanitizer_salt: tooshort
EOF
    export OIDC_SANITIZER_SALT_FILE="$fixture"
    run oidc_email_salt_load
    [ "$status" -ne 0 ]
    [[ "$output" == *"shorter than 16"* ]]
}

################################################################################
# oidc_email_batch — TSV column rewrite
################################################################################

@test "oidc_email_batch: rewrites email column in a TSV file" {
    input="${TEST_TEMP_DIR}/users.tsv"
    printf '1\talice@example.com\tAlice\n2\tbob@example.com\tBob\n' > "$input"

    run oidc_email_batch "$input" 2
    [ "$status" -eq 0 ]
    [ -f "${input}.orig" ]

    # Real emails gone
    grep -q "alice@example.com" "$input" && fail "real email leaked"
    grep -q "bob@example.com" "$input" && fail "real email leaked"

    # Sanitized form present
    grep -q "@sanitized.test" "$input"

    # Row count preserved
    [ "$(wc -l < "$input")" = "2" ]

    # Non-email columns untouched
    grep -q $'\tAlice$' "$input"
    grep -q $'\tBob$' "$input"
}

@test "oidc_email_batch: leaves non-email columns alone" {
    input="${TEST_TEMP_DIR}/data.tsv"
    printf 'id\tname\tnote\n1\tAlice\thello\n' > "$input"

    run oidc_email_batch "$input" 2
    [ "$status" -eq 0 ]

    # Column 2 is a name (no @), so should not be hashed
    grep -q $'\tAlice\t' "$input"
}

################################################################################
# oidc_email_rewrite_sql — SQL-column rewrite (ops#116; stubbed DB runners)
################################################################################

_q_stub() { printf '2\tjohn@gmail.com\n3\tmary@yahoo.com\n'; }
_apply_cap() { cat >> "${OIDC_CAP:-/dev/null}"; }

@test "oidc_email_rewrite_sql: writes UPDATEs using the deterministic hash" {
    export OIDC_CAP="$(mktemp)"
    run oidc_email_rewrite_sql _q_stub _apply_cap users_field_data uid mail "uid>1"
    [ "$status" -eq 0 ]
    exp=$(oidc_email_sanitize "john@gmail.com")
    grep -qF "SET \`mail\`='${exp}' WHERE \`uid\`=2;" "$OIDC_CAP"
    grep -qF "WHERE \`uid\`=3;" "$OIDC_CAP"
    rm -f "$OIDC_CAP"
}

@test "oidc_email_rewrite_sql: cross-stack determinism (matches direct sanitize)" {
    export OIDC_CAP="$(mktemp)"
    oidc_email_rewrite_sql _q_stub _apply_cap t id mail
    direct=$(oidc_email_sanitize "mary@yahoo.com")
    grep -qF "'${direct}'" "$OIDC_CAP"
    rm -f "$OIDC_CAP"
}

@test "oidc_email_rewrite_sql: non-numeric id is fail-closed" {
    _q_bad() { printf 'notanum\tjohn@gmail.com\n'; }
    export OIDC_CAP="$(mktemp)"
    run oidc_email_rewrite_sql _q_bad _apply_cap t id mail
    [ "$status" -ne 0 ]
    [[ "$output" == *"non-numeric id"* ]]
    rm -f "$OIDC_CAP"
}

@test "oidc_email_rewrite_sql: missing salt is fail-closed" {
    unset OIDC_SANITIZER_SALT
    export OIDC_SANITIZER_SALT_FILE=/nonexistent-salt-xyz
    run oidc_email_rewrite_sql _q_stub _apply_cap t id mail
    [ "$status" -ne 0 ]
}
