#!/usr/bin/env bats
# Item 1 (`secrets-registry-truth`) acceptance suite.
#
# These three cases encode the defect that made `pl secrets` a vacuous pass:
#   1. `cmd_audit` probed only the FIRST `.secrets.yml:` location of each entry
#      (`head -1`), so a second declared copy holding a different or dead value
#      still printed OK and exited 0. That is how 16 declared composer-token
#      copies and the agent-loop env token could be dead while the audit was
#      green.
#   2. `cmd_lint` only checked registry -> file, never file -> registry, so a
#      live, powerful credential sitting in `.secrets.yml` with no registry
#      entry (linode.provision_token, restic.dr_pull.password) produced
#      `LINT PASS` and exit 0.
#   3. `cmd_scan` printed LEAK lines and exited 0, so nothing could gate on it.
#
# Everything runs OFFLINE: `curl` is shadowed by tests/unit/helpers/fake-curl.sh.
# Fixture values are deliberately NOT token-shaped so the leakage gate stays green.

setup() {
  # NWP_TEST_SECRETS_SH lets the suite be pointed at the PRE-FIX script so the
  # red state can be reproduced on demand (see the MR description).
  SECRETS_SH="${NWP_TEST_SECRETS_SH:-${BATS_TEST_DIRNAME}/../../scripts/commands/secrets.sh}"
  TEST_TMP=$(mktemp -d)
  # hermetic estate root: without this, lint/scan reach into the real
  # checkout and the suite reports the operator's findings as test failures
  export NWP_ROOT="${TEST_TMP}/estate"
  mkdir -p "${NWP_ROOT}/logs" "${NWP_ROOT}/private" "${NWP_ROOT}/sites"
  export HOME="${TEST_TMP}/home"; mkdir -p "$HOME"

  # --- offline curl -------------------------------------------------------
  mkdir -p "${TEST_TMP}/bin"
  cp "${BATS_TEST_DIRNAME}/helpers/fake-curl.sh" "${TEST_TMP}/bin/curl"
  chmod +x "${TEST_TMP}/bin/curl"
  export PATH="${TEST_TMP}/bin:$PATH"
  export FAKE_CURL_ALIVE="${TEST_TMP}/alive"

  # canonical value is alive; the drifted copy's value is NOT listed => revoked
  printf 'PLACEHOLDER_canonical_value_A\n' > "$FAKE_CURL_ALIVE"

  # --- fixture secret store ----------------------------------------------
  export NWP_SECRETS_FILE="${TEST_TMP}/secrets.yml"
  cat > "${NWP_SECRETS_FILE}" <<'YML'
gitlab:
  server:
    domain: fixture.example.org
fixture:
  token: PLACEHOLDER_canonical_value_A
YML
  chmod 600 "${NWP_SECRETS_FILE}"

  # --- a SECOND declared location whose value differs from canonical ------
  mkdir -p "${TEST_TMP}/copy"
  cat > "${TEST_TMP}/copy/auth.json" <<'JSON'
{ "gitlab-token": { "fixture.example.org": "PLACEHOLDER_stale_value_B" } }
JSON
  chmod 600 "${TEST_TMP}/copy/auth.json"

  export NWP_SECRETS_REGISTRY="${TEST_TMP}/registry.yml"
  cat > "${NWP_SECRETS_REGISTRY}" <<YML
version: 1
secrets:
  - id: fixture_token
    provider: gitlab
    type: fixture token with two declared locations
    scopes: [api]
    stored_in:
      - .secrets.yml:fixture.token
      - ${TEST_TMP}/copy/auth.json:.["gitlab-token"]["fixture.example.org"]
    rotate_via: manual
    rotate_url: https://fixture.example.org/-/user_settings/personal_access_tokens
    cadence_days: 365
    expires: "2099-01-01"
    last_rotated: "2026-07-01"
    owner: operator
    status: active
# gitlab.server.domain is infrastructure metadata, not a credential — the
# escape hatch exists so a suppression is a recorded decision, not silence.
ignored_keys:
  - gitlab.server.domain
YML

  # leak-scan surfaces are injectable so the suite never touches the real \$HOME
  mkdir -p "${TEST_TMP}/surface"
  export NWP_LEAK_SURFACES="${TEST_TMP}/surface"
}

teardown() { rm -rf "${TEST_TMP}"; }

# ---------------------------------------------------------------------------
# CASE 1 — a non-first stored_in location holding a different (and dead) value
#          must make `pl secrets audit` FAIL.
# Pre-fix behaviour: exit 0, row printed "OK 2099-01-01".
# ---------------------------------------------------------------------------
@test "audit: drifted non-first stored_in location fails the audit" {
  run bash "$SECRETS_SH" audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"DRIFT"* ]]
}

@test "audit: --locations names the drifted file" {
  run bash "$SECRETS_SH" audit --locations
  [ "$status" -ne 0 ]
  [[ "$output" == *"copy/auth.json"* ]]
}

@test "audit: a dead value in a non-first location is reported DEAD" {
  run bash "$SECRETS_SH" audit --locations
  [[ "$output" == *"DEAD"* ]]
}

@test "audit: passes when every declared location matches canonical" {
  cat > "${TEST_TMP}/copy/auth.json" <<'JSON'
{ "gitlab-token": { "fixture.example.org": "PLACEHOLDER_canonical_value_A" } }
JSON
  run bash "$SECRETS_SH" audit
  [ "$status" -eq 0 ]
}

@test "audit: a declared local path that does not exist is a problem, not a skip" {
  rm -f "${TEST_TMP}/copy/auth.json"
  run bash "$SECRETS_SH" audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING"* ]]
}

@test "audit: --json emits one record per location" {
  run bash "$SECRETS_SH" audit --json
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.entries[0].locations | length == 2' >/dev/null
  echo "$output" | jq -e '[.entries[0].locations[].status] | map(startswith("DRIFT")) | any' >/dev/null
}

# ---------------------------------------------------------------------------
# CASE 2 — a `.secrets.yml` key that no registry entry declares must make
#          `pl secrets lint` exit 1; adding it to `ignored_keys:` makes it pass.
# Pre-fix behaviour: LINT PASS, exit 0 (this is how linode.provision_token and
# the non-recoverable restic DR password stayed invisible).
# ---------------------------------------------------------------------------
@test "lint: an undeclared .secrets.yml key fails the lint" {
  yq e -i '.orphanage.stray_credential = "PLACEHOLDER_unregistered_value"' "$NWP_SECRETS_FILE"
  run bash "$SECRETS_SH" lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"orphanage.stray_credential"* ]]
}

@test "lint: ignored_keys is an explicit, recorded suppression" {
  yq e -i '.orphanage.stray_credential = "PLACEHOLDER_unregistered_value"' "$NWP_SECRETS_FILE"
  yq e -i '.ignored_keys += ["orphanage.stray_credential"]' "$NWP_SECRETS_REGISTRY"
  run bash "$SECRETS_SH" lint
  [ "$status" -eq 0 ]
}

@test "lint: an unparseable stored_in entry is a hard error" {
  yq e -i '.secrets[0].stored_in += ["a free-text note that is not a location"]' "$NWP_SECRETS_REGISTRY"
  run bash "$SECRETS_SH" lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"unparseable"* ]] || [[ "$output" == *"grammar"* ]]
}

@test "lint: a world-readable secret store is a hard error" {
  chmod 644 "$NWP_SECRETS_FILE"
  run bash "$SECRETS_SH" lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"permission"* ]] || [[ "$output" == *"readable"* ]]
}

# ---------------------------------------------------------------------------
# CASE 3 — `pl secrets scan` must exit non-zero when it finds a live value.
# Pre-fix behaviour: 57 LEAK lines printed on the real estate, exit 0.
# ---------------------------------------------------------------------------
@test "scan: a leaked live value makes scan exit non-zero" {
  printf 'oops PLACEHOLDER_canonical_value_A oops\n' > "${TEST_TMP}/surface/transcript.log"
  run bash "$SECRETS_SH" scan
  [ "$status" -ne 0 ]
  [[ "$output" == *"LEAK"* ]]
}

@test "scan: a clean surface exits 0" {
  printf 'nothing to see here\n' > "${TEST_TMP}/surface/transcript.log"
  run bash "$SECRETS_SH" scan
  [ "$status" -eq 0 ]
}

@test "scan and scrub sweep exactly the same surfaces" {
  run bash "$SECRETS_SH" surfaces
  [ "$status" -eq 0 ]
  [[ "$output" == *"${TEST_TMP}/surface"* ]]
}
