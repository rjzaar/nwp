#!/usr/bin/env bats
# `pl secrets steps` for a credential that DOES NOT EXIST YET.
#
# THE DEFECT UNDER TEST (found live 2026-08-10, gitlab_forge_admin)
#   steps has exactly one shape: "create the new token HERE, then revoke the
#   OLD one" — the rotate-an-existing-credential story. For an entry marked
#   `status: not-provisioned` that story is wrong in a way that WASTES THE
#   OPERATOR'S TIME: it sends them to
#   /admin/users/<bot>/impersonation_tokens for a bot user that has never been
#   created, so the page 404s, and it tells them to revoke an old token that
#   has never existed. The identity-creation phase is missing entirely.
#
#   A registry entry may therefore carry `provision_steps:` — the explicit,
#   operator-facing recipe for FIRST issuance — and steps must render it, and
#   must not present the rotate story as if the thing already existed.

load helpers/secrets-sandbox

setup() {
  estate_guard_arm
  TEST_TMP=$(mktemp -d)
  SECRETS_SH=$(secrets_sandbox_script \
    "${BATS_TEST_DIRNAME}/../../scripts/commands/secrets.sh" \
    "${TEST_TMP}/sandbox")
  export NWP_ROOT="${TEST_TMP}/estate"
  mkdir -p "${NWP_ROOT}/logs" "${NWP_ROOT}/private"
  export HOME="${TEST_TMP}/home"; mkdir -p "$HOME"
  export NWP_SECRETS_REGISTRY="${TEST_TMP}/registry.yml"
  export NWP_SECRETS_FILE="${TEST_TMP}/secrets.yml"; echo '{}' > "$NWP_SECRETS_FILE"
  cat > "$NWP_SECRETS_REGISTRY" <<'YML'
secrets:
  - id: brand_new_admin
    provider: gitlab
    type: PAT of a dedicated admin bot user `fixture-bot` (NOT YET ISSUED)
    scopes: [api, sudo]
    stored_in: ['~/.config/nwp/fixture.token:@file']
    rotate_via: manual
    rotate_url: https://fixture.example.org/admin/users/fixture-bot/impersonation_tokens
    expires: ""
    last_rotated: ""
    owner: operator
    status: not-provisioned
    provision_steps:
      - 'Admin → Users → New user. Username `fixture-bot`, email `fixture-bot@example.invalid`.'
      - 'Edit the user → Access level → Administrator → Save.'
      - 'Impersonation Tokens tab → name it, tick api + sudo, expiry 12 months → Create.'
  - id: already_live
    provider: gitlab
    type: an ordinary token that already exists
    scopes: [api]
    stored_in: ['.secrets.yml:gitlab.thing']
    rotate_url: https://fixture.example.org/-/user_settings/personal_access_tokens
    expires: "2030-01-01"
    last_rotated: "2026-01-01"
    owner: operator
YML
}
teardown() { rm -rf "$TEST_TMP"; }

_steps() { run env NWP_ROOT="$NWP_ROOT" HOME="$HOME" \
  NWP_SECRETS_REGISTRY="$NWP_SECRETS_REGISTRY" NWP_SECRETS_FILE="$NWP_SECRETS_FILE" \
  bash "$SECRETS_SH" steps "$1"; }

@test "first-issue: an unprovisioned entry says the identity does not exist yet" {
  _steps brand_new_admin
  [ "$status" -eq 0 ]
  # must be the VERB saying it, not an echo of the entry's own type text
  [[ "$output" == *"FIRST ISSUE"* ]]
  [[ "$output" == *"does not exist yet"* ]]
}

@test "first-issue: the declared provision_steps are RENDERED, in order" {
  _steps brand_new_admin
  [[ "$output" == *"Admin → Users → New user"* ]]
  [[ "$output" == *"Access level → Administrator"* ]]
  [[ "$output" == *"tick api + sudo"* ]]
  # order preserved
  local a b
  a=$(printf '%s\n' "$output" | grep -n 'New user' | head -1 | cut -d: -f1)
  b=$(printf '%s\n' "$output" | grep -n 'Administrator' | head -1 | cut -d: -f1)
  [ "$a" -lt "$b" ]
}

@test "first-issue: does NOT tell the operator to revoke a token that never existed" {
  _steps brand_new_admin
  [[ "$output" != *"Revoke the OLD token"* ]]
}

@test "first-issue: an entry with NO provision_steps still says so honestly" {
  yq e -i 'del(.secrets[0].provision_steps)' "$NWP_SECRETS_REGISTRY"
  _steps brand_new_admin
  [ "$status" -eq 0 ]
  [[ "$output" == *"no provision_steps recorded"* ]]
}

@test "NEGATIVE CONTROL: a normal entry keeps the rotate story unchanged" {
  _steps already_live
  [[ "$output" == *"Revoke the OLD token"* ]]
  [[ "$output" != *"NOT YET ISSUED"* ]]
}

@test "first-issue: does NOT offer the rotate_url — it 404s until the identity exists" {
  _steps brand_new_admin
  [[ "$output" != *"admin/users/fixture-bot/impersonation_tokens"* ]]
}
