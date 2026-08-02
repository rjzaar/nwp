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

# ---------------------------------------------------------------- ops#196 ---
# The variable-learning pass was FILE-SCOPED: one `f="…/x.yml"` anywhere in a
# file made every later `$f` in that file a YAML path. Both directions of the
# fix are pinned here, because a gate that stops crying wolf by going blind has
# not been fixed.

@test "lint-yq-first: a function-local .yml variable does NOT taint a same-named variable elsewhere" {
  # Reduced from scripts/commands/moodle.sh. `_decl` sets a LOCAL f to a .yml
  # path; 400 lines later a different function loops a LOCAL f over .mbz backups
  # and awks sha256sum output. PRE-FIX: "NEW AWK YAML PARSER: …::verify_backups".
  mkdir -p "$FIX/scripts/commands"
  cat > "$FIX/scripts/commands/scoped.sh" <<'EOF'
#!/bin/bash
_core_patches_decl() {
    local base="$1" cache f
    f="${cache}/core-patches/${base}.yml"
    printf '%s' "$f"
}

verify_backups() {
    local dir="$1" f sum
    for f in "$dir"/*.mbz; do
        sum="$(awk '{print $1}' "$f.sha256")"
        echo "$sum"
    done
}
EOF
  : > "$FIX/.yq-baseline"
  run bash "$CI_DIR/lint-yq-first.sh" --baseline="$FIX/.yq-baseline" "$FIX/scripts/commands"
  [ "$status" -eq 0 ]
  [[ "$output" != *"verify_backups"* ]]
}

@test "lint-yq-first: the OTHER direction — a real parser in the same file is still caught" {
  # Same file shape, but this function genuinely awks the .yml. Going quiet on
  # the .mbz loop must not go quiet on this.
  mkdir -p "$FIX/scripts/commands"
  cat > "$FIX/scripts/commands/scoped2.sh" <<'EOF'
#!/bin/bash
_core_patches_decl() {
    local base="$1" cache f
    f="${cache}/core-patches/${base}.yml"
    printf '%s' "$f"
}

read_patch_ids() {
    local base="$1" f
    f="$(_core_patches_decl "$base")"
    awk '
      /^  - id:/ { print $3 }
    ' "$f"
}

verify_backups() {
    local dir="$1" f sum
    for f in "$dir"/*.mbz; do
        sum="$(awk '{print $1}' "$f.sha256")"
        echo "$sum"
    done
}
EOF
  : > "$FIX/.yq-baseline"
  run bash "$CI_DIR/lint-yq-first.sh" --baseline="$FIX/.yq-baseline" "$FIX/scripts/commands"
  [ "$status" -eq 1 ]
  [[ "$output" == *"read_patch_ids"* ]]
  [[ "$output" != *"verify_backups"* ]]
}

@test "lint-yq-first: reachability — a local defaulted from a global YAML path is caught" {
  # lib/verify-runner.sh shape: `local file="${2:-$VERIFY_YAML_FILE}"`, then
  # `awk '…' "$file"`. The assignment line never says .yml, and PRE-FIX these
  # five real parsers were MISSED entirely (false negative).
  mkdir -p "$FIX/scripts/commands"
  cat > "$FIX/scripts/commands/reach.sh" <<'EOF'
#!/bin/bash
VERIFY_YAML_FILE="${PROJECT_ROOT}/.verification.yml"

get_feature_ids() {
    local feature="$1"
    local file="${2:-$VERIFY_YAML_FILE}"
    awk '
      /^  [a-z0-9_]+:$/ { print }
    ' "$file"
}
EOF
  : > "$FIX/.yq-baseline"
  run bash "$CI_DIR/lint-yq-first.sh" --baseline="$FIX/.yq-baseline" "$FIX/scripts/commands"
  [ "$status" -eq 1 ]
  [[ "$output" == *"get_feature_ids"* ]]
}

@test "lint-yq-first: reachability — a value returned by a same-file resolver is caught" {
  # lib/common.sh::get_secret shape: secrets_file="$(_resolve_infra_secrets_file)".
  mkdir -p "$FIX/scripts/commands"
  cat > "$FIX/scripts/commands/producer.sh" <<'EOF'
#!/bin/bash
_resolve_secrets_file() {
    local f="${PROJECT_ROOT}/.secrets.yml"
    printf '%s' "$f"
}

get_secret() {
    local secrets_file
    secrets_file="$(_resolve_secrets_file)"
    awk -F: '/^gitlab:/{print $2}' "$secrets_file"
}
EOF
  : > "$FIX/.yq-baseline"
  run bash "$CI_DIR/lint-yq-first.sh" --baseline="$FIX/.yq-baseline" "$FIX/scripts/commands"
  [ "$status" -eq 1 ]
  [[ "$output" == *"get_secret"* ]]
}

@test "lint-yq-first: reachability — a for-loop over *.yml taints the loop variable" {
  # lib/verify-issues.sh::list_issues shape.
  mkdir -p "$FIX/scripts/commands"
  cat > "$FIX/scripts/commands/loopvar.sh" <<'EOF'
#!/bin/bash
list_issues() {
    for issue_file in "$ISSUES_DIR"/*.yml; do
        [[ -f "$issue_file" ]] || continue
        awk '/^status:/{print $2}' "$issue_file"
    done
}
EOF
  : > "$FIX/.yq-baseline"
  run bash "$CI_DIR/lint-yq-first.sh" --baseline="$FIX/.yq-baseline" "$FIX/scripts/commands"
  [ "$status" -eq 1 ]
  [[ "$output" == *"list_issues"* ]]
}

@test "lint-yq-first: -v parameters are not file arguments (awk BEGIN arithmetic)" {
  # lib/ci-stats.sh::ci_stats_check — pure BEGIN{} arithmetic, no file at all.
  # It was reported as a YAML parser because the whole `awk …` text, including
  # `-v v="$value"`, was searched for tainted variables.
  mkdir -p "$FIX/scripts/commands"
  cat > "$FIX/scripts/commands/arith.sh" <<'EOF'
#!/bin/bash
CONFIG="${PROJECT_ROOT}/.ci-stats.yml"

ci_stats_check() {
    local value threshold
    value="$(awk '/^count:/{print $2}' "$CONFIG")"
    threshold="$(awk '/^max:/{print $2}' "$CONFIG")"
    within=$(awk -v v="$value" -v t="$threshold" 'BEGIN { print (v <= t) ? 1 : 0 }')
    echo "$within"
}
EOF
  : > "$FIX/.yq-baseline"
  # The two REAL parsers are caught; the BEGIN{} arithmetic is not a third hit.
  run bash "$CI_DIR/lint-yq-first.sh" --list "$FIX/scripts/commands"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c ci_stats_check)" -eq 2 ]
  [[ "$output" != *"BEGIN"* ]]
}

@test "lint-yq-first: the offender is attributed to its ENCLOSING function, not a nested helper" {
  # The tracker only ever ENTERED functions: after an indented `_inner() { … }`
  # every later hit was keyed to `_inner`, so baseline rows named a function
  # that does not contain the awk. Keys are the shrink-only contract's identity.
  mkdir -p "$FIX/scripts/commands"
  cat > "$FIX/scripts/commands/nested.sh" <<'EOF'
#!/bin/bash
CFG="${PROJECT_ROOT}/nwp.yml"

outer_reads_yaml() {
    _inner_helper() {
        echo "helper"
    }
    _inner_helper
    awk '
      /^sites:/ { print }
    ' "$CFG"
}
EOF
  : > "$FIX/.yq-baseline"
  run bash "$CI_DIR/lint-yq-first.sh" --baseline="$FIX/.yq-baseline" "$FIX/scripts/commands"
  [ "$status" -eq 1 ]
  [[ "$output" == *"nested.sh::outer_reads_yaml"* ]]
  [[ "$output" != *"_inner_helper"* ]]
}

@test "lint-yq-first: an awk YAML parser quoted inside a HEREDOC is documentation, not code" {
  mkdir -p "$FIX/scripts/commands"
  cat > "$FIX/scripts/commands/heredoc.sh" <<'OUTER'
#!/bin/bash
CFG="${PROJECT_ROOT}/nwp.yml"

show_help() {
    cat <<'EOF'
Historical idiom, now forbidden:
    awk '/^sites:/{print}' "$CFG"
EOF
}
OUTER
  : > "$FIX/.yq-baseline"
  run bash "$CI_DIR/lint-yq-first.sh" --baseline="$FIX/.yq-baseline" "$FIX/scripts/commands"
  [ "$status" -eq 0 ]
}

@test "lint-yq-first: --list reports path::function TAB line TAB args for every hit" {
  _yq_fixture_multiline
  run bash "$CI_DIR/lint-yq-first.sh" --list "$FIX/scripts/commands"
  [ "$status" -eq 0 ]
  [[ "$output" == *"count_things"* ]]
  [[ "$output" == *'$CFG_FILE'* ]]
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

# ---------------------------------------------------------------- ops#196 ----
# `--explain` — the remaining half of ops#196.
#
# The mechanism half (function-scoped variable learning, and the function
# attribution stack) already landed: the two false positives the issue named —
# scripts/commands/moodle.sh::cmd_course_restore's `.mbz` loop variable and
# lib/demo.sh::demo_push_verified's `awk '{print $1}'` over sha256sum output —
# are both absent from the current hit set, verified 2026-08-03.
#
# What was still open is the issue's other sentence: "the existing baseline was
# generated by the same heuristic, so an unknown number of its rows are NOT YAML
# parsers." That cannot be settled without seeing WHY each row was flagged, and
# nothing printed it. `--explain` does, and grades each hit by how much was
# inferred:
#
#   LITERAL  the awk argument itself is *.yml/*.yaml   — nothing inferred
#   DIRECT   the variable was assigned a literal path  — one hop
#   CHAINED  taint arrived via another variable or a producer command
#            — the only class where a false positive can realistically hide
#
# Measured on this tree: 153 hits — 8 LITERAL, 117 DIRECT, 28 CHAINED.

_yq_fixture_chained() {
  mkdir -p "$FIX/scripts/chain"
  cat > "$FIX/scripts/chain/chained.sh" <<'EOF'
#!/bin/bash
# Modelled on the real shape: lib/common.sh::get_secret does
#   secrets_file="$(_resolve_infra_secrets_file)"
# and the assignment line never says ".yml".
_where() {
    local base="/etc/nwp"
    echo "${base}/thing.yml"
}
read_it() {
    local f
    f="$(_where)"
    awk '
    /x/ { print }
    ' "$f"
}
EOF
}

@test "lint-yq-first --explain says WHY each hit was flagged" {
  _yq_fixture_multiline
  run bash "$CI_DIR/lint-yq-first.sh" --explain --baseline="$FIX/.yq-baseline" "$FIX/scripts/commands"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WHY:"* ]]
  [[ "$output" == *'$CFG_FILE'* ]]
  [[ "$output" == *"CFG_FILE=\"\${PROJECT_ROOT}/.verification.yml\""* ]]
}

@test "lint-yq-first --explain grades a DIRECT taint separately from a LITERAL one" {
  _yq_fixture_multiline
  run bash "$CI_DIR/lint-yq-first.sh" --explain --baseline="$FIX/.yq-baseline" "$FIX/scripts/commands"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DIRECT"* ]]
  [[ "$output" == *"DIRECT    1"* ]] || [[ "$output" == *"DIRECT   1"* ]] || [[ "$output" == *"DIRECT    1 "* ]]
}

@test "lint-yq-first --explain marks a producer-fed variable CHAINED (the audit class)" {
  # This is the shape that needs a human: the linter never saw a literal path,
  # it inferred one from a command substitution.
  _yq_fixture_chained
  run bash "$CI_DIR/lint-yq-first.sh" --explain --baseline="$FIX/.yq-baseline2" "$FIX/scripts/chain"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[CHAINED"* ]]
  [[ "$output" == *"_where"* ]]
}

@test "lint-yq-first --explain changes NO exit code and NO baseline behaviour" {
  # An inspection flag that could fail the build would make people avoid it.
  _yq_fixture_multiline
  run bash "$CI_DIR/lint-yq-first.sh" --explain --baseline="$FIX/.yq-nosuch" "$FIX/scripts/commands"
  [ "$status" -eq 0 ]
  [ ! -f "$FIX/.yq-nosuch" ]     # positively: it wrote nothing
}

@test "ops#196 REGRESSION: the two named false positives are gone from the real tree" {
  # These are the concrete examples in the issue. If either comes back, the
  # function-scoping fix has regressed and the tempting response would be a
  # baseline row, which would permanently bless a whole class of non-violations.
  run bash "$CI_DIR/lint-yq-first.sh" --list
  [ "$status" -eq 0 ]
  [[ "$output" != *"cmd_course_restore"* ]]
  [[ "$output" != *"demo_push_verified"* ]]
}

@test "ops#196 CONTROL: the real tree still HAS hits — the fix did not blind the gate" {
  # A scoping fix that quietly stopped detecting anything would look identical
  # to a scoping fix that works, from the two assertions above alone.
  run bash "$CI_DIR/lint-yq-first.sh" --list
  [ "$status" -eq 0 ]
  n=$(printf '%s\n' "$output" | grep -c 'lib/verify-runner.sh::')
  [ "$n" -ge 3 ]
}
