#!/usr/bin/env bats
# Exposure / rotation-debt acceptance suite (operator ruling D8, 2026-08-01):
#
#   "I'm not worried about token exposure. Exposures need to be logged in the
#    todo list so they can be rotated when I get to it and must be done before
#    prod site starts."
#
# THE DEFECT THIS LOCKS DOWN. Before this suite, NWP had no way to say "this
# credential's value has been seen, and rotating it is owed". Three exposures
# were found in one night (ops#182 a live cross-site bearer token printed in
# distributed docs; ops#183 a forgotten api-scope PAT with write access to the
# canonical course registry; ops#194 a webhook secret inline in a script on the
# live box) plus a token value in a local agent transcript — and every one could
# only be recorded as free-text prose in a tracker. Prose in a tracker is not
# read by `pl todo`, is not counted by `pl rag`, and refuses nothing. It is the
# exact shape that gets forgotten.
#
# The load-bearing case in here is "go-live gate REFUSES while a debt is open".
# That is the test that would have caught this being forgotten.
#
# Fixture values are deliberately NOT token-shaped so the leakage gate stays green.

load helpers/secrets-sandbox

setup() {
  estate_guard_arm   # BEFORE HOME moves — see helpers/secrets-sandbox.bash
  TEST_TMP=$(mktemp -d)
  ROOT="${BATS_TEST_DIRNAME}/../.."
  SECRETS_SH=$(secrets_sandbox_script \
    "${ROOT}/scripts/commands/secrets.sh" "${TEST_TMP}/sandbox")

  export NWP_ROOT="${TEST_TMP}/estate"
  mkdir -p "${NWP_ROOT}/logs" "${NWP_ROOT}/private" "${NWP_ROOT}/sites"
  export HOME="${TEST_TMP}/home"; mkdir -p "$HOME"

  export NWP_SECRETS_FILE="${TEST_TMP}/secrets.yml"
  cat > "${NWP_SECRETS_FILE}" <<'YML'
gitlab:
  server:
    domain: fixture.example.org
fixture:
  token: PLACEHOLDER_canonical_value_A
YML
  chmod 600 "${NWP_SECRETS_FILE}"

  export NWP_SECRETS_REGISTRY="${NWP_ROOT}/private/secrets-registry.yml"
  cat > "$NWP_SECRETS_REGISTRY" <<'YML'
version: 1
secrets:
  - id: fixture_token
    provider: gitlab
    type: fixture credential
    scopes: []
    stored_in:
      - .secrets.yml:fixture.token
    rotate_via: manual
    rotate_url: ""
    cadence_days: 90
    expires: "2027-01-01"
    last_rotated: "2026-01-01"
    owner: operator
  - id: second_token
    provider: webhook
    type: another fixture credential
    scopes: []
    stored_in:
      - 'external:somewhere unverifiable'
    rotate_via: manual
    rotate_url: ""
    cadence_days: 365
    expires: "2027-01-01"
    last_rotated: "2026-01-01"
    owner: operator
YML
}

teardown() {
  estate_guard_assert
  [ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"
}

secrets() { run bash "$SECRETS_SH" "$@"; }

# Load the guard library with the fixture registry in scope.
_guard() { # $1 = context; rest = env prelude
  run bash -c '
    source "'"$ROOT"'/lib/rotation-debt.sh"
    '"${2:-}"'
    rotation_debt_guard "'"$1"'"
  '
}

################################################################################
# 1. SCHEMA — record, read back, round-trip
################################################################################

@test "expose records an exposure and the schema round-trips through yq" {
  secrets expose fixture_token --reason='value printed in a distributed doc' \
          --where='doc:/tmp/handover.md' --ref='ops#182' --severity=high
  [ "$status" -eq 0 ]

  [ "$(yq e '.secrets[0].exposure | length' "$NWP_SECRETS_REGISTRY")" = "1" ]
  [ "$(yq e '.secrets[0].exposure[0].how' "$NWP_SECRETS_REGISTRY")" = "value printed in a distributed doc" ]
  [ "$(yq e '.secrets[0].exposure[0].where[0]' "$NWP_SECRETS_REGISTRY")" = "doc:/tmp/handover.md" ]
  [ "$(yq e '.secrets[0].exposure[0].ref' "$NWP_SECRETS_REGISTRY")" = "ops#182" ]
  # The two independent booleans are the whole point of the schema.
  [ "$(yq e '.secrets[0].exposure[0].closed'  "$NWP_SECRETS_REGISTRY")" = "false" ]
  [ "$(yq e '.secrets[0].exposure[0].rotated' "$NWP_SECRETS_REGISTRY")" = "false" ]
  # …and they are real booleans, not the strings "false".
  [ "$(yq e '.secrets[0].exposure[0].rotated | tag' "$NWP_SECRETS_REGISTRY")" = "!!bool" ]
  # Optional fields left empty are omitted, not recorded as "".
  [ "$(yq e '.secrets[0].exposure[0].notes // "ABSENT"' "$NWP_SECRETS_REGISTRY")" = "ABSENT" ]
}

@test "expose refuses a where: that does not match the grammar" {
  secrets expose fixture_token --reason='x' --where='in a doc somewhere'
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not parse"* ]]
  [ "$(yq e '.secrets[0].exposure // "ABSENT"' "$NWP_SECRETS_REGISTRY")" = "ABSENT" ]
}

@test "expose requires a reason and at least one where/ref" {
  secrets expose fixture_token --where='doc:/tmp/x.md'
  [ "$status" -ne 0 ]
  [[ "$output" == *"--reason"* ]]

  secrets expose fixture_token --reason='x'
  [ "$status" -ne 0 ]
  [[ "$output" == *"where"* ]]
}

@test "a --ref alone is an acceptable where (the issue IS a surface)" {
  secrets expose fixture_token --reason='x' --ref='ops#999'
  [ "$status" -eq 0 ]
  [ "$(yq e '.secrets[0].exposure[0].where[0]' "$NWP_SECRETS_REGISTRY")" = "issue:ops#999" ]
}

@test "expose --adopt records an exposure of a credential the registry never knew" {
  # 3 of the 4 real exposures were of UNDECLARED credentials — which is much of
  # why they could be exposed unnoticed. One command, or it does not happen.
  secrets expose brand_new_pat --adopt=gitlab \
          --stored-in='external:Drupal config on frozen avc-dev' \
          --reason='forgotten api-scope PAT' --ref='ops#183'
  [ "$status" -eq 0 ]
  [ "$(yq e '.secrets[] | select(.id == "brand_new_pat") | .status' "$NWP_SECRETS_REGISTRY")" = "needs-classification" ]
  [ "$(yq e '.secrets[] | select(.id == "brand_new_pat") | .exposure | length' "$NWP_SECRETS_REGISTRY")" = "1" ]
}

@test "expose --adopt refuses a stored_in that breaks the stored_in grammar" {
  secrets expose brand_new_pat --adopt=gitlab --stored-in='just some prose' --reason='x' --ref='ops#1'
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not parse"* ]]
}

################################################################################
# 2. A CLOSED SURFACE IS NOT A ROTATION — the distinction the whole thing exists for
################################################################################

@test "recording an exposure as already --closed still owes the rotation" {
  secrets expose fixture_token --reason='printed in a doc, since redacted' \
          --where='doc:/tmp/handover.md' --closed
  [ "$status" -eq 0 ]
  [ "$(yq e '.secrets[0].exposure[0].closed'  "$NWP_SECRETS_REGISTRY")" = "true" ]
  [ "$(yq e '.secrets[0].exposure[0].rotated' "$NWP_SECRETS_REGISTRY")" = "false" ]

  secrets debt
  [ "$status" -ne 0 ]                      # open debt ⇒ non-zero
  [[ "$output" == *"fixture_token"* ]]
}

@test "expose --close closes the surface and explicitly leaves the debt standing" {
  secrets expose fixture_token --reason='leak' --where='doc:/tmp/x.md'
  secrets expose fixture_token --close
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNCHANGED"* ]]
  [ "$(yq e '.secrets[0].exposure[0].closed'  "$NWP_SECRETS_REGISTRY")" = "true" ]
  [ "$(yq e '.secrets[0].exposure[0].rotated' "$NWP_SECRETS_REGISTRY")" = "false" ]
}

################################################################################
# 3. LINT — accepts the new key, rejects a malformed one
################################################################################

_lint_out() { run bash "$SECRETS_SH" lint; }

@test "lint accepts a well-formed exposure block" {
  secrets expose fixture_token --reason='leak' --where='doc:/tmp/x.md' --ref='ops#182'
  _lint_out
  [[ "$output" == *"every exposure record parses"* ]]
  # The DEBT is reported, but it is not a lint defect — the record is correct.
  [[ "$output" == *"EXPOSURE-DEBT"* ]]
  [[ "$output" != *"EXPOSURE-WHERE"* ]]
}

@test "lint rejects a malformed exposure: bad where grammar" {
  yq e -i '.secrets[0].exposure = [{"at":"2026-08-01","how":"x","where":["somewhere"],"closed":false,"rotated":false}]' "$NWP_SECRETS_REGISTRY"
  _lint_out
  [ "$status" -ne 0 ]
  [[ "$output" == *"EXPOSURE-WHERE"* ]]
}

@test "lint rejects a malformed exposure: non-boolean rotated" {
  yq e -i '.secrets[0].exposure = [{"at":"2026-08-01","how":"x","where":["doc:/tmp/x"],"closed":false,"rotated":"no"}]' "$NWP_SECRETS_REGISTRY"
  _lint_out
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be an explicit true/false"* ]]
}

@test "lint rejects a malformed exposure: bad date, missing how, empty where" {
  yq e -i '.secrets[0].exposure = [{"at":"last tuesday","how":"","where":[],"closed":false,"rotated":false}]' "$NWP_SECRETS_REGISTRY"
  _lint_out
  [ "$status" -ne 0 ]
  [[ "$output" == *"at: must be YYYY-MM-DD"* ]]
  [[ "$output" == *"how: is required"* ]]
  [[ "$output" == *"where: needs at least one location"* ]]
}

@test "lint rejects exposure: that is not a list" {
  yq e -i '.secrets[0].exposure = {"at":"2026-08-01"}' "$NWP_SECRETS_REGISTRY"
  _lint_out
  [ "$status" -ne 0 ]
  [[ "$output" == *"EXPOSURE-SHAPE"* ]]
}

@test "lint rejects an UNBACKED discharge — rotated: true with no recorded rotation" {
  # The one way to defeat the mechanism is to hand-edit rotated: true. The
  # registry already knows when a rotation was stamped; if the two disagree, say so.
  yq e -i '.secrets[0].last_rotated = "" |
           .secrets[0].exposure = [{"at":"2026-08-01","how":"x","where":["doc:/tmp/x"],"closed":true,"rotated":true}]' "$NWP_SECRETS_REGISTRY"
  _lint_out
  [ "$status" -ne 0 ]
  [[ "$output" == *"EXPOSURE-UNBACKED"* ]]
}

################################################################################
# 4. THE WORK QUEUE — one high item per open debt, none when clear
################################################################################

_todo_items() {
  run bash -c '
    set +e
    export NWP_SECRETS_REGISTRY="'"$NWP_SECRETS_REGISTRY"'"
    export TODO_CHECKS_PROJECT_ROOT="'"$TEST_TMP"'/todoroot"
    mkdir -p "$TODO_CHECKS_PROJECT_ROOT"
    printf "settings:\n  todo:\n    categories: {}\n" > "$TODO_CHECKS_PROJECT_ROOT/nwp.yml"
    export TODO_CONFIG_FILE="$TODO_CHECKS_PROJECT_ROOT/nwp.yml"
    source "'"$ROOT"'/lib/todo-checks.sh"
    todo_clear_items
    check_exposed_secrets
    printf "%s\n" "${TODO_ITEMS[@]}"
  '
}

@test "todo check emits NO item when there is no exposure" {
  _todo_items
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s' "$output" | tr -d '[:space:]')" ]
}

@test "todo check emits exactly one high-priority SEC item per open debt" {
  secrets expose fixture_token --reason='leak one' --where='doc:/tmp/a.md' --ref='ops#182'
  secrets expose second_token  --reason='leak two' --where='issue:ops#194' --closed
  _todo_items
  [ "$(printf '%s\n' "$output" | grep -c 'SEC-exposed-')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | grep -c '"priority":"high"')" -eq 2 ]
  [[ "$output" == *"SEC-exposed-fixture_token"* ]]
  [[ "$output" == *"SEC-exposed-second_token"* ]]
  # SEC + high is exactly what lib/rag-render.py grades RED.
  [[ "$output" == *'"category":"SEC"'* ]]
}

@test "todo check emits NOTHING for an exposure that has been rotated" {
  secrets expose fixture_token --reason='leak' --where='doc:/tmp/a.md'
  yq e -i '(.secrets[0].exposure[0]) |= (.rotated = true | .rotated_at = "2026-08-02")' "$NWP_SECRETS_REGISTRY"
  _todo_items
  [ "$(printf '%s\n' "$output" | grep -c 'SEC-exposed-')" -eq 0 ]
}

@test "todo check emits UNK — not clean — when the registry cannot be parsed" {
  printf 'secrets: [ this is not: valid: yaml\n' > "$NWP_SECRETS_REGISTRY"
  _todo_items
  [[ "$output" == *"UNK-exposed_secrets"* ]]
}

################################################################################
# 5. THE GO-LIVE GATE — refuses while a debt is open, passes when cleared
#    (the test that would have caught this being forgotten)
################################################################################

@test "guard PASSES when nothing is exposed" {
  _guard "a prod bring-up"
  [ "$status" -eq 0 ]
}

@test "guard REFUSES while a rotation debt is open, and names the entries" {
  secrets expose fixture_token --reason='bearer token printed in distributed docs' \
          --where='doc:/tmp/handover.md' --ref='ops#182' --closed
  _guard "a prod bring-up"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ROTATION-DEBT"* ]]
  [[ "$output" == *"fixture_token"* ]]
  [[ "$output" == *"ops#182"* ]]
  # A redacted doc must not read as "handled".
  [[ "$output" == *"does NOT clear this"* ]]
}

@test "guard REFUSES when the registry exists but cannot be read (cannot-verify != clear)" {
  printf 'secrets: [ broken: : :\n' > "$NWP_SECRETS_REGISTRY"
  _guard "a prod bring-up"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "guard passes on a MISSING registry (fresh clone / CI), which is not a debt" {
  rm -f "$NWP_SECRETS_REGISTRY"
  _guard "a prod bring-up"
  [ "$status" -eq 0 ]
}

@test "the override proceeds but is loud and LEDGERED" {
  secrets expose fixture_token --reason='leak' --where='doc:/tmp/a.md'
  _guard "a prod bring-up" 'export NWP_ROTATION_DEBT_OVERRIDE="operator says ship it"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROCEEDING while a rotation is owed"* ]]
  grep -q 'operator says ship it' "${NWP_ROOT}/private/rotation-debt-overrides.log"
  grep -q 'fixture_token' "${NWP_ROOT}/private/rotation-debt-overrides.log"
}

@test "deploy_gate_require REFUSES a target=prod write while a debt is open" {
  # This is the wiring that makes it bite: pl stg2prod and pl live2prod both
  # reach prod through this one call (ADR-0028), so the gate cannot be acquired
  # by one caller and missed by the next.
  secrets expose fixture_token --reason='leak' --where='doc:/tmp/a.md'
  run bash -c '
    source "'"$ROOT"'/lib/deploy-gate.sh"
    deploy_gate_require testsite prod "push live → production"
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"ROTATION-DEBT"* ]]
}

@test "deploy_gate_require ALLOWS the same prod write once the debt is discharged" {
  secrets expose fixture_token --reason='leak' --where='doc:/tmp/a.md'
  # Discharge through the real rotation path (values already agree, so the
  # propagation gate is satisfied).
  secrets done fixture_token 2026-08-02
  [ "$status" -eq 0 ]
  run bash -c '
    source "'"$ROOT"'/lib/deploy-gate.sh"
    deploy_gate_require testsite prod "push live → production"
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"ROTATION-DEBT"* ]]
}

@test "deploy_gate_require does NOT gate a target=live write on rotation debt" {
  # An exposure is a work item on live and a blocker on prod. Blocking live too
  # would make the gate something people switch off.
  secrets expose fixture_token --reason='leak' --where='doc:/tmp/a.md'
  run bash -c '
    source "'"$ROOT"'/lib/deploy-gate.sh"
    deploy_gate_require testsite live "a live write"
  '
  [ "$status" -eq 0 ]
}

@test "pl canonical set <site> prod calls the guard BEFORE it writes the phase" {
  # Structural: the transition into canonical: prod IS "the prod site starts".
  local f="${ROOT}/scripts/commands/canonical.sh"
  local g w
  g=$(grep -n 'rotation_debt_guard' "$f" | head -1 | cut -d: -f1)
  w=$(grep -n 'yaml_set_site_field "$site" "canonical"' "$f" | head -1 | cut -d: -f1)
  [ -n "$g" ] && [ -n "$w" ]
  [ "$g" -lt "$w" ]
}

@test "every prod-write verb reaches prod through the gated call" {
  # If a new prod path appears that does NOT call deploy_gate_require, this is
  # the test that should be updated deliberately rather than the gate quietly
  # missing it.
  grep -q 'deploy_gate_require "$base_name" "prod"' "${ROOT}/scripts/commands/stg2prod.sh"
  grep -q 'deploy_gate_require "$BASE_NAME" "prod"' "${ROOT}/scripts/commands/live2prod.sh"
}

################################################################################
# 6. ROTATION CLEARS THE DEBT
################################################################################

@test "pl secrets done discharges the debt and stamps rotated_at" {
  secrets expose fixture_token --reason='leak' --where='doc:/tmp/a.md' --ref='ops#182'
  secrets done fixture_token 2026-08-02
  [ "$status" -eq 0 ]
  [ "$(yq e '.secrets[0].exposure[0].rotated' "$NWP_SECRETS_REGISTRY")" = "true" ]
  [ "$(yq e '.secrets[0].exposure[0].rotated_at' "$NWP_SECRETS_REGISTRY")" = "2026-08-02" ]
  secrets debt
  [ "$status" -eq 0 ]
  [[ "$output" == *"no open rotation debt"* ]]
}

@test "the discharge is written to the rotation log, not just the registry" {
  secrets expose fixture_token --reason='leak' --where='doc:/tmp/a.md' --ref='ops#182'
  secrets done fixture_token 2026-08-02
  grep -q 'cleared exposure debt' "${NWP_ROOT}/private/rotation-$(date +%Y-%m).md"
}

@test "a rotation that could NOT be propagated does not discharge the debt" {
  # `done` already refuses to stamp last_rotated while a declared copy disagrees.
  # The debt must ride on that same refusal — otherwise a failed rotation clears
  # the record of the exposure it failed to fix.
  yq e -i '.secrets[0].stored_in += ["'"$TEST_TMP"'/drift.yml:fixture.token"]' "$NWP_SECRETS_REGISTRY"
  printf 'fixture:\n  token: PLACEHOLDER_a_different_value_B\n' > "$TEST_TMP/drift.yml"
  chmod 600 "$TEST_TMP/drift.yml"
  secrets expose fixture_token --reason='leak' --where='doc:/tmp/a.md'
  secrets done fixture_token 2026-08-02
  [ "$status" -ne 0 ]
  [ "$(yq e '.secrets[0].exposure[0].rotated' "$NWP_SECRETS_REGISTRY")" = "false" ]
}
