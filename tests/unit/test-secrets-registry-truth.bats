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

################################################################################
# Programme item 1 — `secrets-truth-and-gate`.
#
# The prior pass made the registry's LOCATIONS honest (every declared copy is
# probed). It left the registry's CAPABILITY claims folklore: `_probe_scopes`
# was written but 0 of 25 entries carried a `probe:` block, so the scope column
# could never disagree with the provider. That is the exact shape of a vacuous
# pass — a column that renders, from a check that never runs. It is why the
# registry attributed "destroy every prod Linode" to the wrong token for months.
#
# These assert the properties that make the scope claim real:
#   (a) an entry that CLAIMS a scope but declares no probe is a LINT ERROR,
#   (b) a probe whose expectation disagrees with the provider is a non-zero
#       AUDIT (SCOPE-DRIFT),
#   (c) `rotate` is gated the same way `done` already is — you may not stamp
#       last_rotated while a declared copy still holds the old value,
# plus the tier boundary, the blindness state, and tracking of the registry.
################################################################################

# --- (a) a claimed scope with no probe is a lint ERROR ----------------------

@test "lint: an entry declaring scopes but no probe: block is NO-PROBE" {
  # fixture_token declares `scopes: [api]` and (like all 25 live entries) has
  # no probe:. Today lint calls this consistent.
  run bash "$SECRETS_SH" lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"NO-PROBE"* ]]
}

@test "lint: NO-PROBE does not fire for an entry that claims no scope" {
  yq e -i 'del(.secrets[0].scopes)' "$NWP_SECRETS_REGISTRY"
  run bash "$SECRETS_SH" lint
  [[ "$output" != *"NO-PROBE"* ]]
}

@test "lint: NO-PROBE does not fire for a not-provisioned entry" {
  yq e -i '.secrets[0].status = "not-provisioned"' "$NWP_SECRETS_REGISTRY"
  yq e -i '.fixture.token = ""' "$NWP_SECRETS_FILE"
  run bash "$SECRETS_SH" lint
  [[ "$output" != *"NO-PROBE"* ]]
}

@test "probe-scaffold: writes a probe block that satisfies the NO-PROBE rule" {
  run bash "$SECRETS_SH" probe-scaffold fixture_token
  [ "$status" -eq 0 ]
  run yq e '.secrets[0].probe | length' "$NWP_SECRETS_REGISTRY"
  [ "$output" -ge 1 ]
  run bash "$SECRETS_SH" lint
  [[ "$output" != *"NO-PROBE"* ]]
}

# --- (b) a probe whose expectation is wrong must make audit go red ----------

@test "audit: SCOPE-DRIFT when the provider disagrees with the declared scope" {
  bash "$SECRETS_SH" sync fixture_token
  # declare a capability the provider refuses (fake-curl forces 403 on this url)
  printf 'PLACEHOLDER_canonical_value_A\t/api/v4/admin\n' > "${TEST_TMP}/403"
  export FAKE_CURL_403="${TEST_TMP}/403"
  yq e -i '.secrets[0].probe = [{"name":"admin-read","url":"https://fixture.example.org/api/v4/admin","expect":200}]' "$NWP_SECRETS_REGISTRY"
  run bash "$SECRETS_SH" audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCOPE-DRIFT"* ]]
}

@test "audit: a probe whose expectation matches reality is clean" {
  bash "$SECRETS_SH" sync fixture_token
  yq e -i '.secrets[0].probe = [{"name":"read-user","url":"https://fixture.example.org/api/v4/user","expect":200}]' "$NWP_SECRETS_REGISTRY"
  run bash "$SECRETS_SH" audit
  [ "$status" -eq 0 ]
  [[ "$output" != *"SCOPE-DRIFT"* ]]
}

@test "audit: a probe with a NEGATIVE expectation (scope absent) is honoured" {
  # The registry must be able to record "this token must NOT reach instances".
  # linode_api_token claims read_write but probes DNS-only; the way to make that
  # claim checkable is an expect: 403 probe, not prose.
  bash "$SECRETS_SH" sync fixture_token
  printf 'PLACEHOLDER_canonical_value_A\t/api/v4/instances\n' > "${TEST_TMP}/403"
  export FAKE_CURL_403="${TEST_TMP}/403"
  yq e -i '.secrets[0].probe = [{"name":"no-instances","url":"https://fixture.example.org/api/v4/instances","expect":403}]' "$NWP_SECRETS_REGISTRY"
  run bash "$SECRETS_SH" audit
  [ "$status" -eq 0 ]
  [[ "$output" != *"SCOPE-DRIFT"* ]]
}

# --- (c) rotate must be gated exactly as `done` already is -------------------

@test "rotate: --dry-run refuses to stamp while a declared copy is stale" {
  # copy/auth.json and copy/env still hold PLACEHOLDER_stale_value_B.
  run bash "$SECRETS_SH" rotate fixture_token --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to stamp"* ]]
  [ "$(yq e '.secrets[0].last_rotated' "$NWP_SECRETS_REGISTRY")" = "2026-01-01" ]
}

@test "rotate: --dry-run is clean once every location agrees" {
  bash "$SECRETS_SH" sync fixture_token
  run bash "$SECRETS_SH" rotate fixture_token --dry-run
  [ "$status" -eq 0 ]
  # dry-run stamps nothing either way
  [ "$(yq e '.secrets[0].last_rotated' "$NWP_SECRETS_REGISTRY")" = "2026-01-01" ]
}

# --- tier boundary: the AI-readable file may not hold admin/decryption keys --

@test "lint: an admin password in the AI-readable tier is a TIER violation" {
  yq e -i '.gitlab.admin.password = "PLACEHOLDER_admin_password_value"' "$NWP_SECRETS_FILE"
  yq e -i '.ignored_keys += ["gitlab.admin.password"]' "$NWP_SECRETS_REGISTRY"
  run bash "$SECRETS_SH" lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"TIER"* ]]
  [[ "$output" == *".secrets.data.yml"* ]]
}

@test "lint: a backup-decryption password in the AI-readable tier is a TIER violation" {
  yq e -i '.restic.dr_pull.password = "PLACEHOLDER_restic_password_value"' "$NWP_SECRETS_FILE"
  yq e -i '.ignored_keys += ["restic.dr_pull.password"]' "$NWP_SECRETS_REGISTRY"
  run bash "$SECRETS_SH" lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"TIER"* ]]
}

@test "lint: an ordinary infra token is NOT a TIER violation" {
  run bash "$SECRETS_SH" lint
  [[ "$output" != *"TIER"* ]]
}

# --- blindness: an unreachable provider is a STATE, not a silent skip -------

@test "audit: an unreachable provider reports AUDIT-BLIND and does not stamp" {
  export FAKE_CURL_UNREACHABLE=1
  export NWP_SECRETS_AUDIT_RETRIES=2 NWP_SECRETS_AUDIT_BACKOFF=0
  run bash "$SECRETS_SH" audit
  [ "$status" -eq 2 ]
  [[ "$output" == *"AUDIT-BLIND"* ]]
  # blindness must never be recorded as a successful audit
  run yq e '.last_successful_audit // "none"' "$NWP_SECRETS_REGISTRY"
  [ "$output" = "none" ]
}

@test "audit: a reachable provider records last_successful_audit" {
  bash "$SECRETS_SH" sync fixture_token
  bash "$SECRETS_SH" audit
  run yq e '.last_successful_audit // "none"' "$NWP_SECRETS_REGISTRY"
  [ "$output" != "none" ]
  [[ "$output" == 20* ]]
}

@test "audit: retries before declaring blindness" {
  # one flap must not be reported as an outage
  export FAKE_CURL_FLAP="${TEST_TMP}/flap"; printf '1\n' > "$FAKE_CURL_FLAP"
  export NWP_SECRETS_AUDIT_RETRIES=3 NWP_SECRETS_AUDIT_BACKOFF=0
  bash "$SECRETS_SH" sync fixture_token
  run bash "$SECRETS_SH" audit
  [ "$status" -ne 2 ]
}

# --- the source of record must itself be under version control ---------------

@test "lint: an untracked registry inside a git work tree is an error" {
  git -C "$NWP_ROOT" init -q 2>/dev/null || skip "git unavailable"
  git -C "$NWP_ROOT" config user.email t@t; git -C "$NWP_ROOT" config user.name t
  mkdir -p "$NWP_ROOT/private"
  cp "$NWP_SECRETS_REGISTRY" "$NWP_ROOT/private/secrets-registry.yml"
  NWP_SECRETS_REGISTRY="$NWP_ROOT/private/secrets-registry.yml" run bash "$SECRETS_SH" lint
  [[ "$output" == *"UNTRACKED-REGISTRY"* ]]
}

@test "registry-track: makes private/ its own repo and clears UNTRACKED-REGISTRY" {
  command -v git >/dev/null || skip "git unavailable"
  git -C "$NWP_ROOT" init -q
  git -C "$NWP_ROOT" config user.email t@t; git -C "$NWP_ROOT" config user.name t
  # the outer repo must IGNORE private/ — that is the precondition the verb checks
  printf 'private/*\n' > "$NWP_ROOT/.gitignore"
  mkdir -p "$NWP_ROOT/private"
  cp "$NWP_SECRETS_REGISTRY" "$NWP_ROOT/private/secrets-registry.yml"
  export NWP_SECRETS_REGISTRY="$NWP_ROOT/private/secrets-registry.yml"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

  run bash "$SECRETS_SH" registry-track
  [ "$status" -eq 0 ]
  [ -e "$NWP_ROOT/private/.git" ]
  # tracked in the NESTED repo, still invisible to the outer one
  git -C "$NWP_ROOT/private" ls-files --error-unmatch secrets-registry.yml
  run git -C "$NWP_ROOT" ls-files --error-unmatch private/secrets-registry.yml
  [ "$status" -ne 0 ]

  run bash "$SECRETS_SH" lint
  [[ "$output" != *"UNTRACKED-REGISTRY"* ]]
  # …but a single copy on a single disk is still flagged
  [[ "$output" == *"NO-REGISTRY-REMOTE"* ]]
}

@test "registry-track: refuses when the outer repo would actually track the file" {
  command -v git >/dev/null || skip "git unavailable"
  git -C "$NWP_ROOT" init -q
  git -C "$NWP_ROOT" config user.email t@t; git -C "$NWP_ROOT" config user.name t
  # NO private/ ignore rule => committing here would publish the estate topology
  mkdir -p "$NWP_ROOT/private"
  cp "$NWP_SECRETS_REGISTRY" "$NWP_ROOT/private/secrets-registry.yml"
  export NWP_SECRETS_REGISTRY="$NWP_ROOT/private/secrets-registry.yml"
  run bash "$SECRETS_SH" registry-track
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing"* ]]
}

@test "registry-track: --dry-run creates no repository" {
  command -v git >/dev/null || skip "git unavailable"
  git -C "$NWP_ROOT" init -q
  printf 'private/*\n' > "$NWP_ROOT/.gitignore"
  mkdir -p "$NWP_ROOT/private"
  cp "$NWP_SECRETS_REGISTRY" "$NWP_ROOT/private/secrets-registry.yml"
  export NWP_SECRETS_REGISTRY="$NWP_ROOT/private/secrets-registry.yml"
  run bash "$SECRETS_SH" registry-track --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$NWP_ROOT/private/.git" ]
}

# --- the daily audit must be provisioned by code, not by a remembered command -

@test "cron: status exits non-zero when the daily audit is not installed" {
  # a control that exists only as a comment in a script header is not a control
  run env CRONTAB_FAKE=1 bash "$SECRETS_SH" cron status
  [ "$status" -ne 0 ]
  [[ "$output" == *"NOT INSTALLED"* ]]
}

@test "cron: install --dry-run writes no crontab and shows the exact line" {
  run bash "$SECRETS_SH" cron install --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"secrets-daily-audit.sh"* ]]
  [[ "$output" == *"dry-run"* ]]
  run bash "$SECRETS_SH" cron status
  [ "$status" -ne 0 ]
}

# --- the daily audit itself must not report blindness as success -------------

@test "daily-audit: blindness is counted and escalates, never a silent OK" {
  local sh="${BATS_TEST_DIRNAME}/../../scripts/secrets-daily-audit.sh"
  [ -f "$sh" ] || skip "daily-audit script not present"
  # a stub `pl secrets audit` that always reports unreachable (rc=2)
  mkdir -p "${TEST_TMP}/estate/scripts/commands" "${TEST_TMP}/estate/private" "${TEST_TMP}/estate/logs"
  printf '#!/bin/bash\nexit 2\n' > "${TEST_TMP}/estate/scripts/commands/secrets.sh"
  cp "$sh" "${TEST_TMP}/estate/scripts/secrets-daily-audit.sh"

  run env SECRETS_BLIND_MAX_DAYS=2 bash "${TEST_TMP}/estate/scripts/secrets-daily-audit.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUDIT-BLIND"* ]]
  # second consecutive blind run reaches the ceiling and must ESCALATE
  run env SECRETS_BLIND_MAX_DAYS=2 bash "${TEST_TMP}/estate/scripts/secrets-daily-audit.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"has NOT been audited"* ]]
}

# --- probe method: "create-without-creating" --------------------------------
#
# A capability like "can open a merge request" was previously unrecordable: the
# only way to check it was to create one. POSTing an EMPTY body separates the
# authorization layer (401/403 = may not create) from the validation layer
# (400 = may create, but this request is invalid) — so the probe establishes the
# capability while creating nothing.

@test "probe: a POST probe expecting 400 records create capability and is clean" {
  bash "$SECRETS_SH" sync fixture_token
  yq e -i '.secrets[0].probe = [{"name":"can-create-mr","url":"https://fixture.example.org/api/v4/projects/9/merge_requests","method":"POST","expect":400}]' "$NWP_SECRETS_REGISTRY"
  run bash "$SECRETS_SH" audit
  [ "$status" -eq 0 ]
  [[ "$output" != *"SCOPE-DRIFT"* ]]
}

@test "probe: a POST probe is sent as POST, not silently downgraded to GET" {
  # Negative control for the test above: if `method:` were ignored the request
  # would be a GET, which this fixture answers 200 — so expecting 400 would drift.
  # Passing above AND failing here would mean the method never left the registry.
  yq e -i '.secrets[0].probe = [{"name":"mr-as-get","url":"https://fixture.example.org/api/v4/projects/9/merge_requests","expect":400}]' "$NWP_SECRETS_REGISTRY"
  run bash "$SECRETS_SH" audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCOPE-DRIFT"* ]]
  [[ "$output" == *"got=200"* ]]
}

@test "probe: a revoked token cannot create, and the POST probe says so" {
  printf 'PLACEHOLDER_some_other_value\n' > "$FAKE_CURL_ALIVE"   # canonical now dead
  yq e -i '.secrets[0].probe = [{"name":"can-create-mr","url":"https://fixture.example.org/api/v4/projects/9/merge_requests","method":"POST","expect":400}]' "$NWP_SECRETS_REGISTRY"
  run bash "$SECRETS_SH" audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"got=401"* ]]
}

# --- discover-copies: the fleet sweep ---------------------------------------
#
# Before this, the loop `continue`d on any location carrying a host, so a copy on
# met/mini/mons could not be found even in principle and "no undeclared copies
# found" was a claim about one laptop wearing the costume of a claim about the
# fleet. Hashing happens on the REMOTE; only digests cross the wire.

_stub_ssh() { # $1 = sweep stdout the fake host should return (may be empty)
  cat > "${TEST_TMP}/bin/ssh" <<EOF
#!/bin/bash
# consume ssh options, then ignore the remote command
printf '%s' "\$(cat <<'PAYLOAD'
$1
PAYLOAD
)"
EOF
  chmod +x "${TEST_TMP}/bin/ssh"
}

@test "discover-copies: an UNDECLARED copy on a fleet host is reported" {
  yq e -i '.secrets[0].stored_in += ["host=fixturehost:~/.config/declared.token:@file"]' "$NWP_SECRETS_REGISTRY"
  local h; h=$(printf '%s' 'PLACEHOLDER_canonical_value_A' | sha256sum | cut -d' ' -f1)
  # same value, at a path nobody declared
  _stub_ssh "$(printf 'file\037/home/x/.config/sneaky.token\037\037%s' "$h")"
  run bash "$SECRETS_SH" discover-copies
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNDECLARED"* ]]
  [[ "$output" == *"sneaky.token"* ]]
}

@test "discover-copies: a DECLARED copy on a fleet host is NOT reported" {
  # Negative control. Without it, a sweep that flagged every remote file it saw
  # would satisfy the test above while being useless.
  yq e -i '.secrets[0].stored_in += ["host=fixturehost:/home/x/.config/declared.token:"]' "$NWP_SECRETS_REGISTRY"
  local h; h=$(printf '%s' 'PLACEHOLDER_canonical_value_A' | sha256sum | cut -d' ' -f1)
  _stub_ssh "$(printf 'file\037/home/x/.config/declared.token\037\037%s' "$h")"
  run bash "$SECRETS_SH" discover-copies
  [ "$status" -eq 0 ]
  [[ "$output" != *"UNDECLARED"* ]]
}

@test "discover-copies: an unrelated value on a fleet host is NOT reported" {
  # Second negative control: only copies of a value we actually know are copies.
  yq e -i '.secrets[0].stored_in += ["host=fixturehost:~/.config/declared.token:@file"]' "$NWP_SECRETS_REGISTRY"
  local h; h=$(printf '%s' 'SOMETHING_COMPLETELY_UNRELATED' | sha256sum | cut -d' ' -f1)
  _stub_ssh "$(printf 'file\037/home/x/.config/other.token\037\037%s' "$h")"
  run bash "$SECRETS_SH" discover-copies
  [ "$status" -eq 0 ]
  [[ "$output" != *"UNDECLARED"* ]]
}

@test "discover-copies: an UNREACHABLE fleet host is blind, not clean" {
  yq e -i '.secrets[0].stored_in += ["host=fixturehost:~/.config/declared.token:@file"]' "$NWP_SECRETS_REGISTRY"
  _stub_ssh ""            # host answers nothing
  run bash "$SECRETS_SH" discover-copies
  [ "$status" -eq 2 ]     # NOT 0 — "could not look" must not read as "looked, clean"
  [[ "$output" == *"UNREACHABLE"* ]]
}

@test "discover-copies: --no-remote does not touch the fleet at all" {
  yq e -i '.secrets[0].stored_in += ["host=fixturehost:~/.config/declared.token:@file"]' "$NWP_SECRETS_REGISTRY"
  cat > "${TEST_TMP}/bin/ssh" <<'EOF'
#!/bin/bash
echo "ssh was invoked" >&2; exit 99
EOF
  chmod +x "${TEST_TMP}/bin/ssh"
  run bash "$SECRETS_SH" discover-copies --no-remote
  [ "$status" -eq 0 ]
  [[ "$output" != *"ssh was invoked"* ]]
}

@test "discover-copies: a bare-IP host is a prod endpoint and is skipped by default" {
  # CLAUDE.md: no AI-run machine reaches production. This verb runs from cron.
  yq e -i '.secrets[0].stored_in += ["host=203.0.113.9:/root/x.token:@file"]' "$NWP_SECRETS_REGISTRY"
  cat > "${TEST_TMP}/bin/ssh" <<'EOF'
#!/bin/bash
echo "REACHED_PROD" ; exit 0
EOF
  chmod +x "${TEST_TMP}/bin/ssh"
  run bash "$SECRETS_SH" discover-copies
  [[ "$output" == *"SKIPPED (prod endpoint)"* ]]
  [[ "$output" != *"REACHED_PROD"* ]]
}

# --- guards that could not fire ---------------------------------------------

@test "adopt: refuses a remote location that is already declared" {
  # `yq … | grep -q && die` looks like a guard but is not one: with
  # `set -o pipefail`, grep -q exits at the first match, the still-writing yq
  # takes SIGPIPE, the pipeline reports 141 and `die` never runs. Observed on the
  # real registry — adopt happily created a second entry for a location that was
  # already declared. Small fixtures hide it, so this asserts the OUTCOME.
  yq e -i '.secrets[0].stored_in += ["host=fixturehost:~/.config/declared.token:@file"]' "$NWP_SECRETS_REGISTRY"
  local before; before=$(yq e '.secrets | length' "$NWP_SECRETS_REGISTRY")
  cat > "${TEST_TMP}/bin/ssh" <<'EOF'
#!/bin/bash
printf 'abcdef0123456789'
EOF
  chmod +x "${TEST_TMP}/bin/ssh"
  run bash "$SECRETS_SH" adopt 'host=fixturehost:~/.config/declared.token:@file' --as dupe
  [ "$status" -ne 0 ]
  [[ "$output" == *"already declared"* ]]
  [ "$(yq e '.secrets | length' "$NWP_SECRETS_REGISTRY")" = "$before" ]
}

@test "adopt: refuses a remote location where nothing is readable" {
  # A remote read that finds no file emits the SHA-256 of the empty string, which
  # is a perfectly well-formed digest. Accepting it recorded locations that do
  # not exist as verified.
  cat > "${TEST_TMP}/bin/ssh" <<'EOF'
#!/bin/bash
printf ''  | sha256sum | cut -c1-16
EOF
  chmod +x "${TEST_TMP}/bin/ssh"
  local before; before=$(yq e '.secrets | length' "$NWP_SECRETS_REGISTRY")
  run bash "$SECRETS_SH" adopt 'host=fixturehost:~/.config/absent.token:@file' --as ghost
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing readable"* ]]
  [ "$(yq e '.secrets | length' "$NWP_SECRETS_REGISTRY")" = "$before" ]
}

@test "adopt: accepts a remote location that really holds something" {
  # Negative control for the two refusals above: adopt must still be able to
  # succeed, or "refuse everything" would satisfy them.
  cat > "${TEST_TMP}/bin/ssh" <<'EOF'
#!/bin/bash
printf 'abcdef0123456789'
EOF
  chmod +x "${TEST_TMP}/bin/ssh"
  run bash "$SECRETS_SH" adopt 'host=fixturehost:~/.config/real.token:@file' --as adopted_ok
  [ "$status" -eq 0 ]
  [ "$(yq e '.secrets[] | select(.id=="adopted_ok") | .stored_in[0]' "$NWP_SECRETS_REGISTRY")" = "host=fixturehost:~/.config/real.token:@file" ]
}

@test "remote paths: a leading ~/ is expanded on the remote, not sent in quotes" {
  # `head -1 '~/.config/x'` looks for a directory literally called "~". Every
  # remote location in the registry uses a tilde, so verify-copy hashed nothing
  # and reported permanent DRIFT against copies that were byte-identical.
  cat > "${TEST_TMP}/bin/ssh" <<'EOF'
#!/bin/bash
# echo the remote command back so the test can inspect how the path was quoted
echo "$2$3$4$5$6$7$8$9" > "$SSH_CMD_LOG"
printf 'abcdef0123456789'
EOF
  chmod +x "${TEST_TMP}/bin/ssh"
  export SSH_CMD_LOG="${TEST_TMP}/sshcmd"
  bash "$SECRETS_SH" adopt 'host=fixturehost:~/.config/real.token:@file' --as tilde_ok || true
  [ -f "$SSH_CMD_LOG" ]
  grep -q '"\$HOME"/.config/real.token' "$SSH_CMD_LOG"
  ! grep -q "'~/.config/real.token'" "$SSH_CMD_LOG"
}

@test "verify-copy: an absent remote file is ABSENT, not DRIFT" {
  yq e -i '.secrets[0].stored_in += ["host=fixturehost:~/.config/gone.token:@file"]' "$NWP_SECRETS_REGISTRY"
  cat > "${TEST_TMP}/bin/ssh" <<'EOF'
#!/bin/bash
printf '' | sha256sum | cut -d' ' -f1
EOF
  chmod +x "${TEST_TMP}/bin/ssh"
  run bash "$SECRETS_SH" verify-copy fixture_token
  [ "$status" -ne 0 ]
  [[ "$output" == *"ABSENT"* ]]
  [[ "$output" != *"DRIFT"* ]]
}

# --- TIER by capability -----------------------------------------------------
#
# The name-based TIER rule would not have caught the worst credential in the
# estate: `linode.provision_token` reads like an ordinary infra token and sat in
# the AI-readable tier while able to enumerate and destroy every production
# Linode. The threat-model rule is about what a credential CAN DO.

@test "lint: a production-control scope in the AI-readable tier is TIER-CAPABILITY" {
  yq e -i '.secrets[0].provider = "linode" | .secrets[0].scopes = ["linodes:read_write"]' "$NWP_SECRETS_REGISTRY"
  run bash "$SECRETS_SH" lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"TIER-CAPABILITY"* ]]
}

@test "lint: a NARROW scope in the AI-readable tier is not TIER-CAPABILITY" {
  # Negative control. The rule must distinguish DNS-only from instance-capable —
  # that distinction is the entire finding, so a rule that flagged every linode
  # token would be no better than the folklore it replaces.
  yq e -i '.secrets[0].provider = "linode" | .secrets[0].scopes = ["domains:read_write"]' "$NWP_SECRETS_REGISTRY"
  run bash "$SECRETS_SH" lint
  [[ "$output" != *"TIER-CAPABILITY"* ]]
}

@test "lint: a production-control scope NOT in the AI-readable tier is accepted" {
  # Second negative control: the violation is the TIER, not the capability.
  yq e -i '.secrets[0].provider = "linode" | .secrets[0].scopes = ["linodes:read_write"] | .secrets[0].stored_in = ["external:operator password manager"]' "$NWP_SECRETS_REGISTRY"
  run bash "$SECRETS_SH" lint
  [[ "$output" != *"TIER-CAPABILITY"* ]]
}

@test "lint: a RETIRED entry is not held to TIER-CAPABILITY or NO-PROBE" {
  yq e -i '.secrets[0].provider = "linode" | .secrets[0].scopes = ["linodes:read_write"] | .secrets[0].status = "RETIRED"' "$NWP_SECRETS_REGISTRY"
  run bash "$SECRETS_SH" lint
  [[ "$output" != *"TIER-CAPABILITY"* ]]
  [[ "$output" != *"NO-PROBE: fixture_token"* ]]
}
