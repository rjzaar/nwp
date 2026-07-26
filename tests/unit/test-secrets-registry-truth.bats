#!/usr/bin/env bats
# Item 1 (`secrets-registry-truth`) — the repair + discovery verbs.
#
# `audit` proves the DECLARED copies are right. These prove the rest of the
# contract:
#   · `sync`  propagates canonical to every declared location (the repair path
#     `audit` points at — without it the only advice is "rotate again").
#   · `done`  refuses to stamp last_rotated while a declared copy still holds a
#     different value: you may not RECORD a rotation you did not PROPAGATE.
#   · `adopt` turns "this key is undeclared" into a command instead of a
#     hand-edit of the source of record.
#   · `discover-copies` closes the other direction — nothing undeclared.
#
# Fully offline. Fixture values are deliberately NOT token-shaped.

load helpers/secrets-sandbox

setup() {
  estate_guard_arm   # BEFORE HOME moves — see helpers/secrets-sandbox.bash
  TEST_TMP=$(mktemp -d)
  # Hermeticity may not rest on a variable the SUBJECT is trusted to honour.
  # NWP_ROOT is a request; `NWP_TEST_SECRETS_SH=<pre-fix script>` points this
  # suite at a script with no NWP_ROOT support, which derives its rotation log
  # from its OWN location — and duly appended `fixture_token` lines to the
  # operator's real private/rotation-2026-07.md. Sandboxing the script makes
  # containment a property of where it sits.
  SECRETS_SH=$(secrets_sandbox_script \
    "${NWP_TEST_SECRETS_SH:-${BATS_TEST_DIRNAME}/../../scripts/commands/secrets.sh}" \
    "${TEST_TMP}/sandbox")
  export NWP_ROOT="${TEST_TMP}/estate"
  mkdir -p "${NWP_ROOT}/logs" "${NWP_ROOT}/private" "${NWP_ROOT}/sites"
  export HOME="${TEST_TMP}/home"; mkdir -p "$HOME"

  mkdir -p "${TEST_TMP}/bin"
  cp "${BATS_TEST_DIRNAME}/helpers/fake-curl.sh" "${TEST_TMP}/bin/curl"
  chmod +x "${TEST_TMP}/bin/curl"
  export PATH="${TEST_TMP}/bin:$PATH"
  export FAKE_CURL_ALIVE="${TEST_TMP}/alive"
  printf 'PLACEHOLDER_canonical_value_A\n' > "$FAKE_CURL_ALIVE"

  export NWP_SECRETS_FILE="${TEST_TMP}/secrets.yml"
  cat > "${NWP_SECRETS_FILE}" <<'YML'
gitlab:
  server:
    domain: fixture.example.org
fixture:
  token: PLACEHOLDER_canonical_value_A
YML
  chmod 600 "${NWP_SECRETS_FILE}"

  mkdir -p "${TEST_TMP}/copy"
  cat > "${TEST_TMP}/copy/auth.json" <<'JSON'
{ "gitlab-token": { "fixture.example.org": "PLACEHOLDER_stale_value_B" } }
JSON
  chmod 600 "${TEST_TMP}/copy/auth.json"
  printf 'export FIXTURE_TOKEN="PLACEHOLDER_stale_value_B"\n' > "${TEST_TMP}/copy/env"
  chmod 600 "${TEST_TMP}/copy/env"

  export NWP_SECRETS_REGISTRY="${TEST_TMP}/registry.yml"
  cat > "${NWP_SECRETS_REGISTRY}" <<YML
version: 1
secrets:
  - id: fixture_token
    provider: gitlab
    type: fixture token with three declared locations
    scopes: [api]
    stored_in:
      - .secrets.yml:fixture.token
      - ${TEST_TMP}/copy/auth.json:.["gitlab-token"]["fixture.example.org"]
      - ${TEST_TMP}/copy/env:FIXTURE_TOKEN
    rotate_via: manual
    rotate_url: https://fixture.example.org/-/user_settings/personal_access_tokens
    cadence_days: 365
    expires: "2099-01-01"
    last_rotated: "2026-01-01"
    owner: operator
    status: active
ignored_keys:
  - gitlab.server.domain
YML
  export NWP_LEAK_SURFACES="${TEST_TMP}/surface"
  mkdir -p "${TEST_TMP}/surface"
}

teardown() {
  local rc=0
  estate_guard_assert || rc=1
  rm -rf "${TEST_TMP}"
  return $rc
}

# --- sync -------------------------------------------------------------------

@test "sync: --dry-run reports what it would change and writes nothing" {
  local before; before=$(sha256sum "${TEST_TMP}/copy/auth.json")
  run bash "$SECRETS_SH" sync fixture_token --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would update"* ]]
  [ "$(sha256sum "${TEST_TMP}/copy/auth.json")" = "$before" ]
}

@test "sync: propagates canonical to every declared location" {
  run bash "$SECRETS_SH" sync fixture_token
  [ "$status" -eq 0 ]
  [ "$(jq -r '.["gitlab-token"]["fixture.example.org"]' "${TEST_TMP}/copy/auth.json")" = "PLACEHOLDER_canonical_value_A" ]
  grep -q 'FIXTURE_TOKEN="PLACEHOLDER_canonical_value_A"' "${TEST_TMP}/copy/env"
}

@test "sync then audit is clean" {
  bash "$SECRETS_SH" sync fixture_token
  run bash "$SECRETS_SH" audit
  [ "$status" -eq 0 ]
}

@test "sync: env-style locations are actually written (perl defined-or regression)" {
  # `write_value_to_location`'s env branch used `($1//"")`, which perl reads as
  # an empty match, not defined-or — it aborted with a COMPILE error on every
  # call, so no env-file location has ever been written by rotate/sync. This is
  # the mechanical cause of the agent-loop token drifting from canonical.
  run bash "$SECRETS_SH" sync fixture_token
  [[ "$output" != *"syntax error"* ]]
  [[ "$output" != *"write failed"* ]]
  grep -q '^export FIXTURE_TOKEN="PLACEHOLDER_canonical_value_A"$' "${TEST_TMP}/copy/env"
}

# --- done -------------------------------------------------------------------

@test "done: refuses to stamp a rotation that was never propagated" {
  run bash "$SECRETS_SH" done fixture_token 2026-07-26
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to stamp"* ]]
  # the registry must be untouched
  [ "$(yq e '.secrets[0].last_rotated' "$NWP_SECRETS_REGISTRY")" = "2026-01-01" ]
}

@test "done: stamps once every location agrees" {
  bash "$SECRETS_SH" sync fixture_token
  run bash "$SECRETS_SH" done fixture_token 2026-07-26
  [ "$status" -eq 0 ]
  [ "$(yq e '.secrets[0].last_rotated' "$NWP_SECRETS_REGISTRY")" = "2026-07-26" ]
}

# --- adopt ------------------------------------------------------------------

@test "adopt: registers an undeclared key so lint goes green" {
  yq e -i '.orphanage.stray_credential = "PLACEHOLDER_unregistered_value"' "$NWP_SECRETS_FILE"
  run bash "$SECRETS_SH" lint
  [ "$status" -ne 0 ]
  run bash "$SECRETS_SH" adopt orphanage.stray_credential
  [ "$status" -eq 0 ]
  run yq e '.secrets[] | select(.id == "orphanage_stray_credential") | .stored_in[0]' "$NWP_SECRETS_REGISTRY"
  [ "$output" = ".secrets.yml:orphanage.stray_credential" ]
}

@test "adopt: refuses a key that is already declared" {
  run bash "$SECRETS_SH" adopt fixture.token
  [ "$status" -ne 0 ]
}

# --- discover-copies --------------------------------------------------------

@test "discover-copies: an undeclared env copy of a known value is reported" {
  bash "$SECRETS_SH" sync fixture_token
  export HOME="${TEST_TMP}/home"; mkdir -p "$HOME"
  printf 'GITLAB_TOKEN="PLACEHOLDER_canonical_value_A"\n' > "$HOME/.nwp-agent-loop.env"
  chmod 600 "$HOME/.nwp-agent-loop.env"
  run bash "$SECRETS_SH" discover-copies
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNDECLARED"* ]]
}

@test "discover-copies: exits 0 when nothing undeclared exists" {
  export HOME="${TEST_TMP}/home"; mkdir -p "$HOME"
  run bash "$SECRETS_SH" discover-copies
  [ "$status" -eq 0 ]
  [[ "$output" == *"no undeclared copies"* ]]
}

# --- grammar ----------------------------------------------------------------

@test "grammar: host= locations are REMOTE, not silently skipped" {
  yq e -i '.secrets[0].stored_in += ["host=ci-host:~/.nwp-agent-loop.env:GITLAB_TOKEN"]' "$NWP_SECRETS_REGISTRY"
  bash "$SECRETS_SH" sync fixture_token
  run bash "$SECRETS_SH" audit --locations
  [[ "$output" == *"REMOTE"* ]]
  [[ "$output" == *"ci-host"* ]]
}

@test "grammar: external: locations are declared-unverifiable, and lint accepts them" {
  yq e -i '.secrets[0].stored_in += ["external:gitlab-ci-var nwp/nwc-project SOME_VAR (masked)"]' "$NWP_SECRETS_REGISTRY"
  run bash "$SECRETS_SH" lint
  [[ "$output" != *"unparseable"* ]]
}

# --- migrate-registry -------------------------------------------------------

@test "migrate-registry: rewrites legacy prose locations into the grammar" {
  yq e -i '.secrets[0].stored_in += [
      "~/.config/fixture.token (on ci-host, created at provisioning)",
      "CI/CD variable SOME_VAR (masked)",
      "VERIFY: some site secrets / drush uli"
    ]' "$NWP_SECRETS_REGISTRY"
  run bash "$SECRETS_SH" migrate-registry --apply
  [ "$status" -eq 0 ]
  run yq e '.secrets[0].stored_in | join("|")' "$NWP_SECRETS_REGISTRY"
  [[ "$output" == *"host=ci-host:~/.config/fixture.token:@file"* ]]
  [[ "$output" == *"external:CI/CD variable SOME_VAR (masked)"* ]]
  [[ "$output" == *"external:VERIFY: some site secrets / drush uli"* ]]
}

@test "migrate-registry: is idempotent" {
  yq e -i '.secrets[0].stored_in += ["~/.config/fixture.token (on ci-host)"]' "$NWP_SECRETS_REGISTRY"
  bash "$SECRETS_SH" migrate-registry --apply
  local after; after=$(sha256sum "$NWP_SECRETS_REGISTRY")
  run bash "$SECRETS_SH" migrate-registry --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"already migrated"* ]]
  [ "$(sha256sum "$NWP_SECRETS_REGISTRY")" = "$after" ]
}

@test "migrate-registry: --dry-run writes nothing" {
  yq e -i '.secrets[0].stored_in += ["VERIFY: prose"]' "$NWP_SECRETS_REGISTRY"
  local before; before=$(sha256sum "$NWP_SECRETS_REGISTRY")
  run bash "$SECRETS_SH" migrate-registry
  [ "$(sha256sum "$NWP_SECRETS_REGISTRY")" = "$before" ]
}

@test "migrate-registry: preserves the original prose in stored_in_notes" {
  yq e -i '.secrets[0].stored_in += ["~/.config/fixture.token (on ci-host, DEFERRED — not provisioned)"]' "$NWP_SECRETS_REGISTRY"
  bash "$SECRETS_SH" migrate-registry --apply
  run yq e '.secrets[0].stored_in_notes | join("|")' "$NWP_SECRETS_REGISTRY"
  [[ "$output" == *"DEFERRED"* ]]
}

@test "grammar: bare prose in stored_in is rejected" {
  yq e -i '.secrets[0].stored_in += ["VERIFY: ba site secrets / drush uli"]' "$NWP_SECRETS_REGISTRY"
  run bash "$SECRETS_SH" lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"unparseable"* ]]
}
