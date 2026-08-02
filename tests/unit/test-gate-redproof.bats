#!/usr/bin/env bats
#
# test-gate-redproof.bats — the red proof FOR the red-proof gate.
#
# lint-gate-redproof.sh asserts that every CI gate has been observed failing on
# a known-bad input. It lives in scripts/ci/, so it is inside its own corpus and
# is held to its own rule. Without this file it would report itself as
# NO-RED-PROOF — which is the correct answer, and also the reason this file has
# to exist before the gate is worth anything.
#
# Every case drives the REAL script against a SYNTHETIC .gitlab-ci.yml and a
# synthetic tests/ tree, so the behaviour is identical on a workstation and on a
# runner with a different pipeline definition. Cases that depended on the real
# .gitlab-ci.yml would degrade into "whatever main happens to look like today".

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  GATE="$PROJECT_ROOT/scripts/ci/lint-gate-redproof.sh"
  FIX="$BATS_TEST_TMPDIR/fix"
  mkdir -p "$FIX/scripts/ci" "$FIX/tests/unit"
  BASE="$FIX/.baseline"
}

# Run the gate against the fixture tree.
_run_gate() {
  run env \
    NWP_GATE_CI_FILE="$FIX/.gitlab-ci.yml" \
    NWP_GATE_CI_DIR="$FIX/scripts/ci" \
    NWP_GATE_TEST_ROOTS="$FIX/tests" \
    NWP_GATE_REDPROOF_BASELINE="$BASE" \
    bash "$GATE" "$@"
}

_ci() { printf '%s\n' "$1" > "$FIX/.gitlab-ci.yml"; }

# Append one @test block to a fixture .bats file.
#
# Written with printf rather than a heredoc on purpose: bats scans EVERY line of
# this file for a `@test` at column 0, heredoc bodies included, so a fixture
# whose case name matched a real one aborted the suite with "Duplicate test
# name(s)" before a single assertion ran. Building the marker from '%s' with
# '@' as the argument keeps it out of bats' line scan while producing a byte-
# identical fixture. (Found the hard way, first run of this file.)
_mk_bats() {   # _mk_bats <file> <case-name> <body-line>...
  local f="$1" name="$2"; shift 2
  { printf '%stest "%s" {\n' '@' "$name"
    printf '  %s\n' "$@"
    printf '}\n'
  } >> "$f"
}

################################################################################
# 1. It goes RED on the thing it exists to catch
################################################################################

@test "a gate with no red proof and no baseline row FAILS" {
  _ci 'stages: [lint]
lint:thing:
  stage: lint
  script:
    - ./scripts/ci/thing.sh'
  printf '#!/bin/bash\nexit 0\n' > "$FIX/scripts/ci/thing.sh"
  : > "$BASE"
  _run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNPROVEN GATE"* ]]
  [[ "$output" == *"thing.sh"* ]]
}

@test "a job whose every verdict is swallowed is CANNOT-FAIL" {
  _ci 'stages: [security]
security:advisory:
  stage: security
  script:
    - echo "=== audit ==="
    - composer audit || echo "ADVISORY: vulnerabilities found"
    - npm audit --audit-level=high || echo "ADVISORY: npm"'
  : > "$BASE"
  _run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"CANNOT-FAIL"* ]]
  [[ "$output" == *"swallowed"* ]]
}

@test "allow_failure:true is CANNOT-FAIL however real the script is" {
  _ci 'stages: [test]
e2e:placeholder:
  stage: test
  allow_failure: true
  script:
    - ./tests/e2e/test-fresh-install.sh'
  : > "$BASE"
  _run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"allow_failure:true"* ]]
}

@test "an echo-only job wearing a gate's name is CANNOT-FAIL" {
  _ci 'stages: [e2e]
e2e:production:
  stage: e2e
  script:
    - echo "E2E production tests not yet implemented"
    - echo "Future: test staging -> production"'
  : > "$BASE"
  _run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"echo-only"* ]]
}

################################################################################
# 2. It goes GREEN only on real evidence
################################################################################

@test "a gate WITH a bats case asserting non-zero exit is PROVEN-RED" {
  _ci 'stages: [lint]
lint:thing:
  stage: lint
  script:
    - ./scripts/ci/thing.sh'
  printf '#!/bin/bash\nexit 0\n' > "$FIX/scripts/ci/thing.sh"
  _mk_bats "$FIX/tests/unit/test-thing.bats" "thing fails on a known-bad input" \
      'run bash "$CI_DIR/thing.sh" --bad' \
      '[ "$status" -eq 1 ]'
  : > "$BASE"
  _run_gate
  [ "$status" -eq 0 ]
  # two rows: the job and the script it runs
  [[ "$output" == *"2 PROVEN-RED"* ]]
  [[ "$output" == *"0 NO-RED-PROOF"* ]]
}

@test "a suite that only ever asserts SUCCESS does not count as a red proof" {
  # This is the whole thesis. `[ "$status" -eq 0 ]` proves the gate can say
  # yes. A gate exists to say no.
  _ci 'stages: [lint]
lint:thing:
  stage: lint
  script:
    - ./scripts/ci/thing.sh'
  printf '#!/bin/bash\nexit 0\n' > "$FIX/scripts/ci/thing.sh"
  _mk_bats "$FIX/tests/unit/test-thing.bats" "thing passes on the real repo" \
      'run bash "$CI_DIR/thing.sh"' \
      '[ "$status" -eq 0 ]'
  : > "$BASE"
  _run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNPROVEN GATE"* ]]
}

@test "a red proof in one @test block does not lend itself to another gate" {
  # Two gates, one test file: block A red-tests alpha, block B green-tests beta.
  # File-scoped attribution would call beta proven. It is not.
  _ci 'stages: [lint]
lint:alpha:
  stage: lint
  script: ["./scripts/ci/alpha.sh"]
lint:beta:
  stage: lint
  script: ["./scripts/ci/beta.sh"]'
  printf '#!/bin/bash\nexit 0\n' > "$FIX/scripts/ci/alpha.sh"
  printf '#!/bin/bash\nexit 0\n' > "$FIX/scripts/ci/beta.sh"
  _mk_bats "$FIX/tests/unit/test-both.bats" "alpha rejects a bad tree" \
      'run bash alpha.sh' '[ "$status" -ne 0 ]'
  _mk_bats "$FIX/tests/unit/test-both.bats" "beta accepts a good tree" \
      'run bash beta.sh' '[ "$status" -eq 0 ]'
  : > "$BASE"
  _run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"beta.sh"* ]]
  # alpha must NOT be reported unproven
  ! grep -q 'UNPROVEN GATE.*alpha' <<< "$output"
}

@test "an ensure-* bootstrap is not mistaken for the gate it bootstraps" {
  # test:unit's before_script runs ensure-yq.sh. Proving the yq INSTALLER can
  # fail says nothing about the gate that later uses yq.
  _ci 'stages: [test]
test:thing:
  stage: test
  before_script:
    - ./scripts/ci/ensure-yq.sh
  script:
    - ./scripts/commands/thing.sh --check'
  printf '#!/bin/bash\nexit 0\n' > "$FIX/scripts/ci/ensure-yq.sh"
  _mk_bats "$FIX/tests/unit/test-ensure.bats" "ensure-yq fails on a sha mismatch" \
      'run bash ensure-yq.sh' '[ "$status" -eq 1 ]'
  : > "$BASE"
  _run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"ensure-* bootstraps"* ]]
}

################################################################################
# 3. Baseline is shrink-only and exact
################################################################################

@test "a baselined unproven gate passes, and the baseline is honoured" {
  _ci 'stages: [lint]
lint:thing:
  stage: lint
  script: ["./scripts/ci/thing.sh"]'
  printf '#!/bin/bash\nexit 0\n' > "$FIX/scripts/ci/thing.sh"
  _run_gate --update-baseline
  [ "$status" -eq 0 ]
  _run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO-RED-PROOF"* ]]
}

@test "a baseline row for a gate that became PROVEN-RED is STALE (must shrink)" {
  _ci 'stages: [lint]
lint:thing:
  stage: lint
  script: ["./scripts/ci/thing.sh"]'
  printf '#!/bin/bash\nexit 0\n' > "$FIX/scripts/ci/thing.sh"
  _run_gate --update-baseline
  # now earn the proof
  _mk_bats "$FIX/tests/unit/test-thing.bats" "thing rejects garbage" \
      'run bash thing.sh --garbage' '[ "$status" -ne 0 ]'
  _run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"STALE BASELINE ROW"* ]]
  [[ "$output" == *"now PROVEN-RED"* ]]
}

@test "a baseline row for a deleted gate is STALE" {
  # Keep a second gate alive: a tree with ZERO gates is exit 2 (cannot verify),
  # which would mask the staleness this case is about.
  _ci 'stages: [lint]
lint:thing:
  stage: lint
  script: ["./scripts/ci/thing.sh"]
lint:keeper:
  stage: lint
  script: ["./scripts/ci/keeper.sh"]'
  printf '#!/bin/bash\nexit 0\n' > "$FIX/scripts/ci/thing.sh"
  printf '#!/bin/bash\nexit 0\n' > "$FIX/scripts/ci/keeper.sh"
  _run_gate --update-baseline
  rm "$FIX/scripts/ci/thing.sh"
  _ci 'stages: [lint]
lint:keeper:
  stage: lint
  script: ["./scripts/ci/keeper.sh"]'
  _run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"no longer exists"* ]]
  [[ "$output" == *"thing.sh"* ]]
}

@test "PROVEN-RED is never written into the baseline" {
  _ci 'stages: [lint]
lint:thing:
  stage: lint
  script: ["./scripts/ci/thing.sh"]'
  printf '#!/bin/bash\nexit 0\n' > "$FIX/scripts/ci/thing.sh"
  _mk_bats "$FIX/tests/unit/test-thing.bats" "thing rejects garbage" \
      'run bash thing.sh --garbage' '[ "$status" -ne 0 ]'
  _run_gate --update-baseline
  [ "$status" -eq 0 ]
  # The header explains the verdict vocabulary, so exclude comments: a
  # structural check that cannot tell a data row from its own documentation is
  # the false-positive half of the disease (see lint-yq-first.sh's header).
  ! grep -v '^#' "$BASE" | grep -q 'PROVEN-RED'
}

################################################################################
# 4. Fail-closed: it never green-ticks a corpus it could not read
################################################################################

@test "an unreadable .gitlab-ci.yml is CANNOT VERIFY (exit 2), never a pass" {
  _run_gate   # no .gitlab-ci.yml written at all
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "a .gitlab-ci.yml that is not a mapping is CANNOT VERIFY" {
  printf -- '- just\n- a\n- list\n' > "$FIX/.gitlab-ci.yml"
  _run_gate
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "zero gates found is CANNOT VERIFY, not 'all gates fine'" {
  _ci 'stages: [lint]
variables:
  FOO: bar'
  _run_gate
  [ "$status" -eq 2 ]
  [[ "$output" == *"zero gates"* ]]
}

################################################################################
# 5. Against the real repo
################################################################################

@test "the real repo's gate baseline is exact" {
  cd "$PROJECT_ROOT"
  run bash "$GATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROVEN-RED"* ]]
}

@test "lint-gate-redproof.sh is itself in the corpus and PROVEN-RED" {
  # If this file stops proving the meta-gate red, the meta-gate must say so
  # about itself. Exemption is the disease.
  cd "$PROJECT_ROOT"
  run bash "$GATE" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROVEN-RED"$'\t'"impl:scripts/ci/lint-gate-redproof.sh"* ]]
}

@test "the real repo's inventory names every verdict class" {
  cd "$PROJECT_ROOT"
  run bash "$GATE" --inventory
  [ "$status" -eq 0 ]
  [[ "$output" == *"CANNOT-FAIL"* ]]
  [[ "$output" == *"NO-RED-PROOF"* ]]
  [[ "$output" == *"PROVEN-RED"* ]]
}
