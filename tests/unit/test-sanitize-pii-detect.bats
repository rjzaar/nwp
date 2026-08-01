#!/usr/bin/env bats
#
# test-sanitize-pii-detect.bats — the PII detector must be able to FIRE.
#
# WHY THIS FILE EXISTS
#   lib/sanitize.sh:check_for_pii() is the last-look check on an artifact that
#   is about to leave the tier that owns the data — a demo seed, a DR restore
#   rehearsal, a sanitised prod copy on its way to dev/stg. Until 2026-08-02 its
#   email arm was:
#
#       if grep -qE '<email>' "$sql_file" | grep -qvE '@example\.(com|org|net)'
#
#   `grep -q` PRINTS NOTHING — that is what -q means. The downstream
#   `grep -qv` therefore reads an empty stdin, finds no non-matching line, and
#   exits 1. The condition is UNSATISFIABLE: no input whatsoever, PII or not,
#   can make that branch taken. Measured on the pre-fix tree with a file
#   containing 3 real addresses (see the first case below): `found` stayed 0,
#   the function printed "OK — No obvious PII detected" and returned 0.
#
#   The credit-card arm right beneath it is a plain `grep -qE` and works. That
#   is the tell: one arm of a two-arm detector had been dead for its whole life
#   and the green tick from the working arm covered for it.
#
# CONTRACT PINNED HERE
#   1. real addresses in the file  -> reported, return 1
#   2. only @example.* addresses   -> clean, return 0   (the sanitiser's own output)
#   3. the detector is reachable   -> the email arm is not a `grep -q | grep`
#   4. a missing/unreadable file is NOT "clean" (cannot-verify, never a pass)
#   5. credit-card arm still fires (no regression while fixing its neighbour)

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    FIX="$BATS_TEST_TMPDIR"
}

# check_for_pii() calls print_info / print_status / print_warning from lib/ui.sh.
# Source the real UI so the test exercises the real code path, but neutralise
# colour so assertions are on plain text.
_load() {
    export NO_COLOR=1
    # shellcheck disable=SC1090
    source "$REPO_ROOT/lib/ui.sh" 2>/dev/null || true
    for f in print_info print_status print_warning print_error print_header; do
        declare -F "$f" >/dev/null 2>&1 || eval "$f() { echo \"\$*\"; }"
    done
    # shellcheck disable=SC1090
    source "$REPO_ROOT/lib/sanitize.sh"
}

################################################################################
# 1. The detector must be able to fire
################################################################################

@test "check_for_pii reports real email addresses (pre-fix: could not)" {
    _load
    # Synthetic addresses only. The first draft of this fixture used a real
    # operator address and the gitleaks pre-commit hook refused the commit —
    # which is that gate doing exactly what this MR is about, on this MR.
    cat > "$FIX/dirty.sql" <<'SQL'
INSERT INTO users_field_data VALUES (1,'a.person@mailhost-one.test','P1');
INSERT INTO users_field_data VALUES (2,'someone@parish-two.test','P2');
INSERT INTO webform_submission VALUES (3,'contact@realdomain-three.test','P3');
SQL
    run check_for_pii "$FIX/dirty.sql"
    if [ "$status" -eq 0 ]; then
        echo "--- output ---" >&2; echo "$output" >&2
        echo "3 real addresses in the file and check_for_pii returned CLEAN." >&2
        echo "The email arm is the grep -q | grep -qv pipeline: always false." >&2
        return 1
    fi
    [ "$status" -eq 1 ]
    [[ "$output" == *"email"* ]]
}

@test "check_for_pii is clean on sanitiser output (@example.* only)" {
    _load
    cat > "$FIX/clean.sql" <<'SQL'
INSERT INTO users_field_data VALUES (1,'user1@example.com','User 1');
INSERT INTO users_field_data VALUES (2,'user2@example.org','User 2');
INSERT INTO users_field_data VALUES (3,'noreply@example.net','User 3');
SQL
    run check_for_pii "$FIX/clean.sql"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No obvious PII"* ]]
}

@test "the email arm is not a 'grep -q piped into grep' pipeline" {
    # Structural pin: -q discards stdout, so any `grep -q … | grep …` is
    # unsatisfiable by construction. Keep this shape out of the detector.
    #
    # Comment lines are excluded: the fix's own header QUOTES the dead pipeline
    # so the next reader can see what was wrong, and a detector that cannot
    # tell code from a comment is the false-positive half of the same disease
    # (see lint-yq-first.sh's header for the same lesson).
    run bash -c "grep -vE '^[[:space:]]*#' '$REPO_ROOT/lib/sanitize.sh' \
                 | grep -nE 'grep -[a-zA-Z]*q[a-zA-Z]*[^|]*\|[[:space:]]*grep'"
    [ "$status" -ne 0 ]
}

################################################################################
# 2. Fail-closed on an artifact it cannot read
################################################################################

@test "a missing artifact is CANNOT-VERIFY (exit 2), never 'clean'" {
    _load
    run check_for_pii "$FIX/does-not-exist.sql"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "an empty artifact is CANNOT-VERIFY, never 'clean'" {
    _load
    : > "$FIX/empty.sql"
    run check_for_pii "$FIX/empty.sql"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "no argument is CANNOT-VERIFY, never 'clean'" {
    _load
    run check_for_pii
    [ "$status" -eq 2 ]
}

################################################################################
# 3. The arm that always worked keeps working
################################################################################

@test "check_for_pii still reports credit-card patterns" {
    _load
    printf "INSERT INTO orders VALUES (1,'4111 1111 1111 1111');\n" > "$FIX/cc.sql"
    run check_for_pii "$FIX/cc.sql"
    [ "$status" -eq 1 ]
    [[ "$output" == *"credit card"* ]]
}

@test "both arms can fire in one pass and both are named" {
    _load
    cat > "$FIX/both.sql" <<'SQL'
INSERT INTO users VALUES (1,'a.person@somewhere-else.test');
INSERT INTO orders VALUES (1,'4111-1111-1111-1111');
SQL
    run check_for_pii "$FIX/both.sql"
    [ "$status" -eq 1 ]
    [[ "$output" == *"email"* ]]
    [[ "$output" == *"credit card"* ]]
}

################################################################################
# 4. Domain allow-list is explicit, not accidental
################################################################################

@test "an address that merely CONTAINS example.com is still PII" {
    # `bob@example.com.attacker.ru` must not be waved through by a substring
    # match on '@example.com'. The pre-fix regex was unanchored.
    _load
    printf "INSERT INTO u VALUES (1,'bob@example.com.attacker.ru');\n" > "$FIX/sneaky.sql"
    run check_for_pii "$FIX/sneaky.sql"
    [ "$status" -eq 1 ]
    [[ "$output" == *"email"* ]]
}
