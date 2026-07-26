#!/usr/bin/env bats
#
# Acceptance tests for the CI gates that could not fail (item 5, ci-gate-honesty).
#
# Every case here was run against the PRE-FIX tree first and observed RED. The
# recorded pre-fix behaviour is quoted in each test. The tests deliberately
# exercise *the same scripts .gitlab-ci.yml calls* — never a copy of the command
# — and the last group asserts that .gitlab-ci.yml really does call them, so the
# job and its test cannot drift apart.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CI_DIR="$PROJECT_ROOT/scripts/ci"
  FIX="$(mktemp -d)"
}

teardown() {
  [ -n "${FIX:-}" ] && rm -rf "$FIX"
}

# --------------------------------------------------------------- lint:bash ---
# PRE-FIX: `find scripts/commands lib -name "*.sh" -type f -exec bash -n {} \;`
# printed "lib/broken.sh: line 4: syntax error: unexpected end of file" and then
# EXIT=0, because find reports its own status, not the command's.

@test "lint-bash: a shell file with a syntax error makes the gate FAIL" {
  mkdir -p "$FIX/lib" "$FIX/scripts/commands"
  printf '#!/bin/bash\nif true; then\n  echo hi\n' > "$FIX/lib/broken.sh"
  printf '#!/bin/bash\necho ok\n' > "$FIX/scripts/commands/good.sh"
  cd "$FIX"
  run bash "$CI_DIR/lint-bash.sh" scripts lib
  [ "$status" -eq 1 ]
  [[ "$output" == *"SYNTAX ERROR"* ]]
  [[ "$output" == *"broken.sh"* ]]
}

@test "lint-bash: a clean tree passes" {
  mkdir -p "$FIX/lib"
  printf '#!/bin/bash\nif true; then\n  echo hi\nfi\n' > "$FIX/lib/fine.sh"
  cd "$FIX"
  run bash "$CI_DIR/lint-bash.sh" lib
  [ "$status" -eq 0 ]
  [[ "$output" == *"parse cleanly"* ]]
}

@test "lint-bash: an EMPTY corpus is 'cannot verify' (exit 2), never a silent pass" {
  mkdir -p "$FIX/lib"
  cd "$FIX"
  run bash "$CI_DIR/lint-bash.sh" lib
  [ "$status" -eq 2 ]
  [[ "$output" == *"no shell files"* ]]
}

@test "lint-bash: the real repo parses cleanly" {
  cd "$PROJECT_ROOT"
  run bash "$CI_DIR/lint-bash.sh"
  [ "$status" -eq 0 ]
}

# ----------------------------------------------------------- lint:yq-first ---
# PRE-FIX (both directions wrong, proven on a probe tree):
#   * multi-line `awk '…' "$CFG_FILE"` where CFG_FILE=".verification.yml"
#     → "OK — no AWK YAML parsers found", EXIT=0   (FALSE NEGATIVE)
#   * a COMMENT reading "we used to awk nwp.yml here"
#     → "ERROR: AWK YAML parser detected", EXIT=1  (FALSE POSITIVE)

_yq_fixture_multiline() {
  mkdir -p "$FIX/scripts/commands"
  cat > "$FIX/scripts/commands/multiline-awk.sh" <<'EOF'
#!/bin/bash
CFG_FILE="${PROJECT_ROOT}/.verification.yml"
count_things() {
    local count
    count=$(awk '
    BEGIN { c = 0 }
    /^      machine:/ { c++ }
    END { print c }
    ' "$CFG_FILE" 2>/dev/null)
    echo "${count:-0}"
}
EOF
  : > "$FIX/.yq-baseline"
}

@test "lint-yq-first: a MULTI-LINE awk YAML parser is detected (was a false negative)" {
  _yq_fixture_multiline
  run bash "$CI_DIR/lint-yq-first.sh" --baseline="$FIX/.yq-baseline" "$FIX/scripts/commands"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NEW AWK YAML PARSER"* ]]
  [[ "$output" == *"count_things"* ]]
}

@test "lint-yq-first: a variable holding a .yml path is resolved, not just literals" {
  # The offender names \$CFG_FILE on the closing line, never ".yml" — this is
  # exactly how the five verify.sh parsers hid behind \$VERIFICATION_FILE.
  _yq_fixture_multiline
  run bash "$CI_DIR/lint-yq-first.sh" --baseline="$FIX/.yq-baseline" "$FIX/scripts/commands"
  [ "$status" -eq 1 ]
  [[ "$output" != *".yml"*"literal"* ]]
}

@test "lint-yq-first: a COMMENT mentioning awk and nwp.yml is NOT flagged (was a false positive)" {
  mkdir -p "$FIX/scripts/commands"
  printf '#!/bin/bash\n# historical note: we used to awk nwp.yml here, now we use yq\necho hi\n' \
    > "$FIX/scripts/commands/comment-only.sh"
  : > "$FIX/.yq-baseline"
  run bash "$CI_DIR/lint-yq-first.sh" --baseline="$FIX/.yq-baseline" "$FIX/scripts/commands"
  [ "$status" -eq 0 ]
}

@test "lint-yq-first: non-YAML awk (du output, arithmetic) is left alone" {
  mkdir -p "$FIX/scripts/commands"
  cat > "$FIX/scripts/commands/nonyaml.sh" <<'EOF'
#!/bin/bash
size=$(du -sk /tmp | awk '{print $1}')
pct=$(awk "BEGIN {printf \"%.1f\", 3 * 100 / 7}")
ports=$(ss -ltn | awk '
  NR > 1 { print $4 }
')
EOF
  : > "$FIX/.yq-baseline"
  run bash "$CI_DIR/lint-yq-first.sh" --baseline="$FIX/.yq-baseline" "$FIX/scripts/commands"
  [ "$status" -eq 0 ]
}

@test "lint-yq-first: the baseline is SHRINK-ONLY — a stale entry fails" {
  mkdir -p "$FIX/scripts/commands"
  printf '#!/bin/bash\necho clean\n' > "$FIX/scripts/commands/clean.sh"
  echo "scripts/commands/gone.sh::vanished" > "$FIX/.yq-baseline"
  run bash "$CI_DIR/lint-yq-first.sh" --baseline="$FIX/.yq-baseline" "$FIX/scripts/commands"
  [ "$status" -eq 1 ]
  [[ "$output" == *"STALE BASELINE ENTRY"* ]]
}

@test "lint-yq-first: a baselined offender does not fail the gate" {
  _yq_fixture_multiline
  bash "$CI_DIR/lint-yq-first.sh" --baseline="$FIX/.yq-baseline" --update-baseline "$FIX/scripts/commands"
  run bash "$CI_DIR/lint-yq-first.sh" --baseline="$FIX/.yq-baseline" "$FIX/scripts/commands"
  [ "$status" -eq 0 ]
}

@test "lint-yq-first: an EMPTY corpus is 'cannot verify' (exit 2)" {
  mkdir -p "$FIX/scripts/commands"
  run bash "$CI_DIR/lint-yq-first.sh" --baseline="$FIX/.yq-baseline" "$FIX/scripts/commands"
  [ "$status" -eq 2 ]
}

@test "lint-yq-first: the repo matches its committed baseline exactly" {
  cd "$PROJECT_ROOT"
  run bash "$CI_DIR/lint-yq-first.sh"
  [ "$status" -eq 0 ]
}

# ------------------------------------------------------------ security:meta ---
# PRE-FIX: the whole `security` stage was gated on `exists: [composer.json]`,
# and /home/rob/nwp/composer.json does not exist, so it never ran at all.

@test "security-meta: a planted AWS key shape is a NEW FINDING and fails" {
  cd "$FIX"
  git init -q .
  git config user.email t@t; git config user.name t
  mkdir -p lib
  # Assembled at runtime on purpose: a literal AWS-key-shaped string committed
  # to this repo would (correctly) be flagged by this very gate and by gitleaks.
  # The gate found it when this test was first written — which is the gate
  # working, so the fixture moved rather than the baseline growing.
  akia_prefix="AKI"; akia_body="OSFODNN7EXAMPLE1"
  printf 'key = "%sA%s"\n' "$akia_prefix" "$akia_body" > lib/leak.sh
  git add -A
  : > "$FIX/.sec-baseline"
  run bash "$CI_DIR/security-meta.sh" --root="$FIX" --baseline="$FIX/.sec-baseline"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NEW FINDING: aws-key:lib/leak.sh"* ]]
}

@test "security-meta: a non-git directory is 'cannot verify' (exit 2)" {
  run bash "$CI_DIR/security-meta.sh" --root="$FIX" --baseline="$FIX/.sec-baseline"
  [ "$status" -eq 2 ]
}

@test "security-meta: the repo matches its committed baseline exactly" {
  cd "$PROJECT_ROOT"
  run bash "$CI_DIR/security-meta.sh"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------- security:review ---
# PRE-FIX: the job's finale was `echo "Red flags:"` + four more echoes, and
# allow_failure: true. It asserted nothing.

_mkrepo_with_change() {
  # _mkrepo_with_change <path-to-touch> <commit-subject>
  cd "$FIX"
  git init -q -b main .
  git config user.email t@t; git config user.name t
  echo base > README.md
  git add -A && git commit -qm "base"
  git branch -q base-ref
  mkdir -p "$(dirname "$1")"
  echo change >> "$1"
  git add -A && git commit -qm "$2"
}

@test "review-marker: a sensitive path with NO REVIEW: marker fails" {
  _mkrepo_with_change ".gitlab-ci.yml" "ci: tweak a job"
  run bash "$CI_DIR/review-marker-gate.sh" --base=base-ref --title="ci: tweak a job"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REVIEW:"*"marker"* ]]
  [[ "$output" == *"two-person approval"* ]]
}

@test "review-marker: the same change WITH a REVIEW: marker passes" {
  _mkrepo_with_change ".gitlab-ci.yml" "REVIEW: ci: tweak a job"
  run bash "$CI_DIR/review-marker-gate.sh" --base=base-ref --title="REVIEW: ci: tweak a job"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REVIEW: marker"* ]]
}

@test "review-marker: a non-sensitive change needs no marker" {
  _mkrepo_with_change "docs/notes.md" "docs: add a note"
  run bash "$CI_DIR/review-marker-gate.sh" --base=base-ref --title="docs: add a note"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no CLAUDE.md sensitive path touched"* ]]
}

@test "review-marker: an unresolvable base fails CLOSED (exit 2), never green" {
  _mkrepo_with_change "docs/notes.md" "docs: add a note"
  run bash "$CI_DIR/review-marker-gate.sh" --base=refs/heads/does-not-exist --title="x"
  [ "$status" -eq 2 ]
}

# ------------------------------------------------------------- bats runner ---
# PRE-FIX: `bats tests/unit/` with `junit: tests/unit/results.xml` declared.
# That file has never existed; GitLab warns on a missing junit artifact and
# passes the job, so the MR Test panel stayed empty across ~1085 cases.

@test "run-bats: a missing required tool is 'cannot verify' (exit 2), not a skip" {
  mkdir -p "$FIX/t"
  printf '@test "a" { true; }\n' > "$FIX/t/x.bats"
  NWP_BATS_REQUIRED_TOOLS="bats zzz-definitely-not-installed" \
    run bash "$CI_DIR/run-bats.sh" "$FIX/out" "$FIX/t/x.bats"
  [ "$status" -eq 2 ]
  [[ "$output" == *"missing"* ]]
}

@test "run-bats: writes a JUnit report with testcases in it" {
  mkdir -p "$FIX/t"
  printf '@test "a" { true; }\n@test "b" { true; }\n' > "$FIX/t/x.bats"
  run bash "$CI_DIR/run-bats.sh" "$FIX/out" "$FIX/t/x.bats"
  [ "$status" -eq 0 ]
  [ -s "$FIX/out/report.xml" ]
  [ "$(grep -c '<testcase' "$FIX/out/report.xml")" -eq 2 ]
}

@test "run-bats: an unexpected SKIP fails the job (a skip reports as 'ok')" {
  mkdir -p "$FIX/t"
  printf '@test "a" { true; }\n@test "b" { skip "no dep"; }\n' > "$FIX/t/x.bats"
  run bash "$CI_DIR/run-bats.sh" "$FIX/out" "$FIX/t/x.bats"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skipped-test count is 1"* ]]
}

@test "test-auth-logic no longer SKIPS when php is missing" {
  # The two cases in that file guard the SSO uid-lock decision and the ops#81
  # erasure Bearer/IP/issuer guard. They used to `skip` without php — and bats
  # reports a skip as `ok`, so migrating from the current runner (has php) to
  # the registered fallback runner (no php) would have dropped both silently.
  run grep -c 'command -v php >/dev/null || skip' "$PROJECT_ROOT/tests/unit/test-auth-logic.bats"
  [ "$output" = "0" ]
  grep -q 'require_php' "$PROJECT_ROOT/tests/unit/test-auth-logic.bats"
  grep -q 'NWP_ALLOW_MISSING_PHP' "$PROJECT_ROOT/tests/unit/test-auth-logic.bats"
}

# ------------------------------------------------------- verify-signature ----

@test "verify-signature: report-only tells the truth and exits 0" {
  _mkrepo_with_change "docs/notes.md" "docs: add a note"
  run bash "$CI_DIR/verify-signature.sh" --base=base-ref
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNSIGNED:"* ]]
  [[ "$output" == *"REPORT-ONLY"* ]]
}

@test "verify-signature: --require actually fails on unsigned commits" {
  _mkrepo_with_change "docs/notes.md" "docs: add a note"
  run bash "$CI_DIR/verify-signature.sh" --base=base-ref --require
  [ "$status" -eq 1 ]
}

# --------------------------------------------------- .gitlab-ci.yml wiring ---
# These stop the job and its acceptance test drifting apart, and stop the
# pre-fix shapes coming back.

@test "CI: lint:bash calls scripts/ci/lint-bash.sh, not find -exec bash -n" {
  run grep -F 'scripts/ci/lint-bash.sh' "$PROJECT_ROOT/.gitlab-ci.yml"
  [ "$status" -eq 0 ]
  # the exit-status-swallowing form must not come back
  run grep -E '^\s+- find .*-exec bash -n' "$PROJECT_ROOT/.gitlab-ci.yml"
  [ "$status" -ne 0 ]
}

@test "CI: the lint jobs run on MERGE REQUESTS, not only on push" {
  # A gate that cannot run on the change being merged is decoration. Extract
  # each job's rules and assert merge_request_event is among them.
  run yq -r '."lint:bash".rules[].if, ."lint:yq-first".rules[].if' "$PROJECT_ROOT/.gitlab-ci.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"merge_request_event"* ]]
  run yq -r '[."lint:bash".rules[].if] | map(select(test("merge_request_event"))) | length' "$PROJECT_ROOT/.gitlab-ci.yml"
  [ "$output" = "1" ]
}

@test "CI: the bats jobs go through run-bats.sh and declare the report it writes" {
  run grep -c 'scripts/ci/run-bats.sh' "$PROJECT_ROOT/.gitlab-ci.yml"
  [ "$output" -ge 2 ]
  # the phantom junit paths must be gone from the ACTIVE config (the
  # tombstone comments quote the old shapes on purpose, so strip comments)
  run bash -c "grep -v '^[[:space:]]*#' '$PROJECT_ROOT/.gitlab-ci.yml' | grep -F 'results.xml'"
  [ "$status" -ne 0 ]
  run grep -F '.logs/junit/unit/report.xml' "$PROJECT_ROOT/.gitlab-ci.yml"
  [ "$status" -eq 0 ]
}

@test "CI: security:meta exists, is ungated by composer.json, and can fail" {
  run yq -r '."security:meta".allow_failure' "$PROJECT_ROOT/.gitlab-ci.yml"
  [ "$output" = "false" ]
  run yq -r '."security:meta".rules | tojson' "$PROJECT_ROOT/.gitlab-ci.yml"
  [[ "$output" != *"exists"* ]]
}

@test "CI: security:review asserts the REVIEW marker instead of echoing a checklist" {
  run grep -F 'scripts/ci/review-marker-gate.sh' "$PROJECT_ROOT/.gitlab-ci.yml"
  [ "$status" -eq 0 ]
  run bash -c "grep -v '^[[:space:]]*#' '$PROJECT_ROOT/.gitlab-ci.yml' | grep -F 'echo \"Red flags:\"'"
  [ "$status" -ne 0 ]
  run yq -r '."security:review".allow_failure' "$PROJECT_ROOT/.gitlab-ci.yml"
  [ "$output" = "false" ]
}

@test "CI: verify-signature runs a real check, not an echo placeholder" {
  run grep -F 'scripts/ci/verify-signature.sh' "$PROJECT_ROOT/.gitlab-ci.yml"
  [ "$status" -eq 0 ]
  run bash -c "grep -v '^[[:space:]]*#' '$PROJECT_ROOT/.gitlab-ci.yml' | grep -F 'placeholder until signing is configured'"
  [ "$status" -ne 0 ]
}

@test "CI: the gitleaks download is sha256-pinned, not piped straight into tar" {
  # NB: asserting merely that 'sha256sum -c -' appears somewhere is too weak —
  # the yq bootstrap has been pinned for a while, so that assertion passed on
  # the PRE-FIX file too. Assert the specific unverified-pipe shape is gone and
  # that a sha is checked for the gitleaks tarball specifically.
  run bash -c "grep -E 'gitleaks_.*linux_x64.tar.gz\" *\| *tar' '$PROJECT_ROOT/.gitlab-ci.yml'"
  [ "$status" -ne 0 ]
  run bash -c "grep -A12 -F 'ver=8.30.0' '$PROJECT_ROOT/.gitlab-ci.yml' | grep -E '^ *sha=[0-9a-f]{64}'"
  [ "$status" -eq 0 ]
  run bash -c "grep -A12 -F 'ver=8.30.0' '$PROJECT_ROOT/.gitlab-ci.yml' | grep -F 'sha256sum -c -'"
  [ "$status" -eq 0 ]
}

@test "CI: the decoupled badge machinery is gone from CI and README" {
  run yq -r 'has("update-badges")' "$PROJECT_ROOT/.gitlab-ci.yml"
  [ "$output" = "false" ]
  run grep -F 'img.shields.io/badge/dynamic/json' "$PROJECT_ROOT/README.md"
  [ "$status" -ne 0 ]
}

@test "CI: the console pytest suite is wired to a job" {
  run yq -r 'has("test:console")' "$PROJECT_ROOT/.gitlab-ci.yml"
  [ "$output" = "true" ]
  [ -f "$PROJECT_ROOT/scripts/console/requirements-dev.txt" ]
  grep -q '^pytest' "$PROJECT_ROOT/scripts/console/requirements-dev.txt"
}
