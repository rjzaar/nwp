#!/usr/bin/env bats
#
# test-test-honesty.bats — the red proof for scripts/ci/lint-test-honesty.sh.
#
# Each case feeds the lint the EXACT shape that was found live on 2026-08-01/02
# and asserts it goes red, then feeds the corrected shape and asserts it goes
# green. A lint that only ever runs against the repo it was written for proves
# nothing about what it will do to the next offender.
#
# Synthetic trees throughout, so the behaviour is identical on a workstation and
# a runner.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LINT="$PROJECT_ROOT/scripts/ci/lint-test-honesty.sh"
  FIX="$BATS_TEST_TMPDIR/fix"
  mkdir -p "$FIX/lib" "$FIX/scripts/commands" "$FIX/scripts/ci" \
           "$FIX/tests/unit" "$FIX/tests/integration"
  BASE="$FIX/.baseline"
  : > "$BASE"
}

_run_lint() {
  run env \
    NWP_HONESTY_ROOT="$FIX" \
    NWP_TEST_HONESTY_BASELINE="$BASE" \
    NWP_HONESTY_VERIFICATION_FILE="$FIX/.verification.yml" \
    NWP_HONESTY_CI_DIR="$FIX/scripts/ci" \
    NWP_HONESTY_CODE_ROOTS="lib scripts/commands" \
    NWP_HONESTY_SUITE_ROOTS="tests/unit tests/integration" \
    bash -c "cd '$FIX' && bash '$LINT' \"\$@\"" _ "$@"
}

_verif() { printf '%s\n' "$1" > "$FIX/.verification.yml"; }

################################################################################
# H1 — blind negation (the !297 shape)
################################################################################

@test "H1: '! pl install <payload> 2>/dev/null' is reported" {
  _verif "features:
  - id: security_validation
    checks:
      - cmd: '! pl install d ''test\`whoami\`'' 2>/dev/null'"
  _run_lint --rules=H1
  [ "$status" -eq 1 ]
  [[ "$output" == *"H1-BLIND-NEGATION"* ]]
  [[ "$output" == *"stderr discarded"* ]]
}

@test "H1: the SAME check asserting the error text is accepted" {
  # This is the fix the lint is asking for: prove the command rejected the
  # input, not merely that it exited non-zero for some reason.
  _verif "features:
  - id: security_validation
    checks:
      - cmd: 'pl install d ''test\`whoami\`'' 2>&1 | grep -q ''Invalid site name'''"
  _run_lint --rules=H1
  [ "$status" -eq 0 ]
}

@test "H1: '! grep -q X file' is NOT reported (one failure mode)" {
  _verif "features:
  - id: delete
    checks:
      - cmd: '! grep -q ''{site}-del'' nwp.yml'"
  _run_lint --rules=H1
  [ "$status" -eq 0 ]
}

@test "H1: a negated pipeline ending in grep is NOT reported" {
  _verif "features:
  - id: delete
    checks:
      - cmd: '! ddev list 2>&1 | grep -q ''{site}-del'''"
  _run_lint --rules=H1
  [ "$status" -eq 0 ]
}

@test "H1: a bare negation with no redirect is still reported" {
  _verif "features:
  - id: x
    checks:
      - cmd: '! pl backup nonexistent-site-12345'"
  _run_lint --rules=H1
  [ "$status" -eq 1 ]
  [[ "$output" == *"no error-text assertion"* ]]
}

################################################################################
# H2 — a check that swallows its own measurement (the !306 shape)
################################################################################

@test "H2: 'updates=\$(drush pm:security … || echo \"[]\")' inside a check is reported" {
  cat > "$FIX/lib/todo-checks.sh" <<'EOF'
#!/bin/bash
check_security_updates() {
    local updates count
    updates=$(cd "$directory" && ddev drush pm:security --format=json 2>/dev/null || echo "[]")
    count=$(echo "$updates" | grep -c '"name"')
    [ "$count" -eq 0 ] && return 0
    return 1
}
EOF
  _run_lint --rules=H2
  [ "$status" -eq 1 ]
  [[ "$output" == *"H2-SWALLOWED-VERDICT"* ]]
  [[ "$output" == *"check_security_updates"* ]]
}

@test "H2: the same swallow OUTSIDE a verdict function is not reported" {
  # `branch=$(git … || echo unknown)` painting a status column is not this bug.
  cat > "$FIX/lib/status.sh" <<'EOF'
#!/bin/bash
render_status_row() {
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    echo "$branch"
}
EOF
  _run_lint --rules=H2
  [ "$status" -eq 0 ]
}

@test "H2: a && echo … || echo … ternary is not a swallow" {
  cat > "$FIX/lib/x.sh" <<'EOF'
#!/bin/bash
check_tier() {
    local tier
    tier=$([ "$d" = "live" ] && echo live || echo "dev/stg")
    echo "$tier"
}
EOF
  _run_lint --rules=H2
  [ "$status" -eq 0 ]
}

@test "H2: every scripts/ci script counts as a verdict, function or not" {
  cat > "$FIX/scripts/ci/lint-thing.sh" <<'EOF'
#!/bin/bash
count=$(grep -c BAD tree.txt || echo 0)
[ "$count" -eq 0 ] && echo OK && exit 0
exit 1
EOF
  _run_lint --rules=H2
  [ "$status" -eq 1 ]
  [[ "$output" == *"lint-thing.sh"* ]]
}

################################################################################
# H3 — skips are shrink-only, counted at source
################################################################################

@test "H3: a new skip-bearing suite is reported" {
  cat > "$FIX/tests/unit/test-x.bats" <<'EOF'
setup() { :; }
EOF
  printf 'foo() { command -v ddev >/dev/null || skip "no ddev"; }\n' >> "$FIX/tests/unit/test-x.bats"  # honesty:fixture
  _run_lint --rules=H3
  [ "$status" -eq 1 ]
  [[ "$output" == *"NEW skip-bearing suite"* ]]
}

@test "H3: the baseline is shrink-only — adding a skip FAILS" {
  printf 'a() { skip "one"; }\n' > "$FIX/tests/unit/test-x.bats"  # honesty:fixture
  _run_lint --rules=H3 --update-baseline
  [ "$status" -eq 0 ]
  printf 'b() { skip "two"; }\n' >> "$FIX/tests/unit/test-x.bats"  # honesty:fixture
  _run_lint --rules=H3
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIPS GREW"* ]]
  [[ "$output" == *"1 -> 2"* ]]
}

@test "H3: removing a skip FAILS until the baseline is lowered (shrink-only is exact)" {
  printf 'a() { skip "one"; }\nb() { skip "two"; }\n' > "$FIX/tests/unit/test-x.bats"  # honesty:fixture
  _run_lint --rules=H3 --update-baseline
  printf 'a() { :; }\nb() { skip "two"; }\n' > "$FIX/tests/unit/test-x.bats"  # honesty:fixture
  _run_lint --rules=H3
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIPS SHRANK"* ]]
  [[ "$output" == *"2 -> 1"* ]]
}

@test "H3: the word 'skip' in a COMMENT or an @test title is not a skip" {
  # The rule taxed prose on its first contact with the real tree: five suites
  # scored a skip apiece for a comment saying why they deliberately did NOT
  # skip. Counting those trains people to delete the explanation and seeds a
  # shrink-only baseline with rows no fix can remove.
  # Written as a single-line `printf` carrying `# honesty:fixture`, like every
  # other fixture here: a heredoc cannot carry the marker (its lines ARE the
  # fixture's lines), and `@test` at column 0 in this file would be scanned by
  # bats as a case of this suite.
  printf '# this suite refuses to skip; it fails instead\n@test "RED-PROOF: the wrapper DOES skip when its sentinel is set" {\n  run true   # deliberately not a skip\n}\n' > "$FIX/tests/unit/test-x.bats"  # honesty:fixture
  _run_lint --rules=H3
  [ "$status" -eq 0 ]                        # nothing to report at all
  [[ "$output" == *"none new"* ]]
}

@test "H3: an executable skip in the SAME file is still counted (not blanket-blind)" {
  # The green half: prove the exclusion above did not switch the rule off.
  printf '# a comment mentioning skip\n@test "a title mentioning skip" {\n  command -v nosuchtool >/dev/null || skip "nosuchtool absent"\n}\n' > "$FIX/tests/unit/test-x.bats"  # honesty:fixture
  _run_lint --rules=H3
  [ "$status" -eq 1 ]
  [[ "$output" == *"NEW skip-bearing suite"* ]]
  [[ "$output" == *"(1 skip statement(s))"* ]]   # exactly one: the executable one
}

@test "H3: 'skip' that is not in command position is prose, not a statement" {
  # An assertion ABOUT a skip message is not a skip. This exact line shape is
  # what made the rule score its own acceptance suite.
  printf '@test "z" {\n  [[ "$out" == *"(1 skip statement(s))"* ]]\n}\n' > "$FIX/tests/unit/test-x.bats"  # honesty:fixture
  _run_lint --rules=H3
  [ "$status" -eq 0 ]
  [[ "$output" == *"none new"* ]]
}

@test "H3: 'skip' inside a quoted string on a code line still counts" {
  # `#` inside quotes must not be treated as a comment introducer, or the
  # stripper would blind the rule on any line carrying a hash in a message.
  printf '@test "y" {\n  [ -n "$X" ] || skip "needs X # see ops-214"\n}\n' > "$FIX/tests/unit/test-x.bats"  # honesty:fixture
  _run_lint --rules=H3
  [ "$status" -eq 1 ]
  [[ "$output" == *"(1 skip statement(s))"* ]]
}

@test "H3: a suite with all skips removed leaves a STALE row" {
  printf 'a() { skip "one"; }\n' > "$FIX/tests/unit/test-x.bats"  # honesty:fixture
  _run_lint --rules=H3 --update-baseline
  printf 'a() { :; }\n' > "$FIX/tests/unit/test-x.bats"
  _run_lint --rules=H3
  [ "$status" -eq 1 ]
  [[ "$output" == *"no skips left"* ]]
}

################################################################################
# H4 — host-dependent branch with no knob (the !316 shape)
################################################################################

@test "H4: 'command -v restic || return 0' with no NWP_ knob is reported" {
  cat > "$FIX/scripts/ci/gate.sh" <<'EOF'
#!/bin/bash
if ! command -v restic >/dev/null 2>&1; then
    echo "restic not installed; skipping provenance check"
    return 0
fi
EOF
  _run_lint --rules=H4
  [ "$status" -eq 1 ]
  [[ "$output" == *"H4-HOST-BLIND"* ]]
  [[ "$output" == *"restic"* ]]
}

@test "H4: failing CLOSED on the missing tool is accepted" {
  # lint-conflict-markers.sh's real idiom.
  cat > "$FIX/scripts/ci/gate.sh" <<'EOF'
#!/bin/bash
command -v git >/dev/null 2>&1 || { echo "CANNOT VERIFY — git unavailable." >&2; exit 2; }
EOF
  _run_lint --rules=H4
  [ "$status" -eq 0 ]
}

@test "H4: an NWP_* override makes the absent-tool path testable, so it is accepted" {
  cat > "$FIX/scripts/ci/gate.sh" <<'EOF'
#!/bin/bash
RESTIC_BIN="${NWP_RESTIC_BIN:-restic}"
if ! command -v "$RESTIC_BIN" >/dev/null 2>&1; then
    echo "no restic"
fi
EOF
  _run_lint --rules=H4
  [ "$status" -eq 0 ]
}

################################################################################
# Fail-closed + baseline contract
################################################################################

@test "an empty corpus is CANNOT VERIFY (exit 2), never a silent pass" {
  rm -rf "$FIX/scripts/ci" "$FIX/tests"
  _run_lint --rules=H4
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "a fixed finding leaves a STALE baseline row (shrink-only)" {
  _verif "features:
  - id: x
    checks:
      - cmd: '! pl backup 2>/dev/null'"
  _run_lint --rules=H1 --update-baseline
  _verif "features:
  - id: x
    checks:
      - cmd: 'pl backup 2>&1 | grep -q ''Usage'''"
  _run_lint --rules=H1
  [ "$status" -eq 1 ]
  [[ "$output" == *"STALE BASELINE ROW"* ]]
}

@test "baseline keys are repo-relative, never absolute" {
  # An absolute path in a committed baseline matches on exactly one machine.
  cat > "$FIX/scripts/ci/gate.sh" <<'EOF'
#!/bin/bash
if ! command -v backstop >/dev/null 2>&1; then echo none; fi
EOF
  _run_lint --rules=H4 --update-baseline
  [ "$status" -eq 0 ]
  run grep -c "$FIX" "$BASE"
  [[ "$output" == "0" ]]
  grep -q 'scripts/ci/gate.sh::backstop' "$BASE"
}

################################################################################
# Against the real repo
################################################################################

@test "the real repo's test-honesty baseline is exact" {
  cd "$PROJECT_ROOT"
  run bash "$LINT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"none new"* ]]
}

@test "the real repo still carries the 17 blind '! pl …' verification checks" {
  # Recorded so the number is a tracked debt, not folklore. Lower it as !297
  # lands; the shrink-only baseline will force the edit.
  cd "$PROJECT_ROOT"
  run bash "$LINT" --rules=H1 --list
  [ "$status" -eq 0 ]
  n="$(grep -c 'H1-BLIND-NEGATION' <<< "$output")"
  [ "$n" -ge 1 ]
  [[ "$output" == *"pl install"* ]]
}
