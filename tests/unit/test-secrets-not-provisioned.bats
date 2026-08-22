#!/usr/bin/env bats
# `pl secrets` — DOES-NOT-EXIST-YET is not IS-BROKEN.
#
# The defect class, hit three times by the operator on one evening (2026-08-10,
# ops#331): the `pl secrets` machinery was built for ROTATING credentials that
# already exist, and FIRST ISSUANCE was never a supported path. MR !407 fixed
# the remote writer, MR !409 fixed `steps` and the local `@file` writer. This
# suite sweeps the rest of the family for the same shape.
#
# `status: not-provisioned` is read in ELEVEN places in secrets.sh plus
# lib/todo-checks.sh, and every one of them SKIPS the entry — audit never probes
# it, `capabilities` never asks what it can do, `lint` never demands a probe,
# `rotate --due` never schedules it, the daily liveness cron ignores it. That is
# right while the credential does not exist. It becomes fail-OPEN the instant it
# does, and NOTHING in the tree ever cleared the flag: `stamp_registry` and
# `mark_done` write `last_rotated`/`expires` and nothing else. So a credential
# minted through the exact path `pl secrets steps` prescribes stays marked
# not-provisioned for ever and is invisible to the whole audit machinery,
# silently. The live registry already carries two entries hand-edited to
# `provisioned-<date>` — the same repair, performed outside a verb, which the
# pl-first standing order says is a bug report rather than a workaround.
#
# The other half of the class is diagnosis: a verb that meets a credential which
# has never been issued must SAY SO. "canonical location unreadable" and
# "refusing to make another copy of a credential that is on its way out or in
# the wrong tier" both describe a broken entry; the entry is not broken, it is
# empty, and the two states need different actions from the operator.
#
# Fully offline. Fixture values are deliberately NOT token-shaped.

load helpers/secrets-sandbox

setup() {
  estate_guard_arm   # BEFORE HOME is moved

  TEST_TMP=$(mktemp -d)
  SECRETS_SH=$(secrets_sandbox_script \
    "${NWP_TEST_SECRETS_SH:-${BATS_TEST_DIRNAME}/../../scripts/commands/secrets.sh}" \
    "${TEST_TMP}/sandbox")

  export NWP_ROOT="${TEST_TMP}/estate"
  mkdir -p "${NWP_ROOT}/private" "${NWP_ROOT}/logs" "${TEST_TMP}/elsewhere"
  export HOME="${TEST_TMP}/home"; mkdir -p "$HOME"

  mkdir -p "${TEST_TMP}/bin"
  cp "${BATS_TEST_DIRNAME}/helpers/fake-curl.sh" "${TEST_TMP}/bin/curl"
  chmod +x "${TEST_TMP}/bin/curl"
  export PATH="${TEST_TMP}/bin:$PATH"
  export FAKE_CURL_ALIVE="${TEST_TMP}/alive"
  printf 'PLACEHOLDER_canonical_value_A\n' > "$FAKE_CURL_ALIVE"

  export NWP_SECRETS_FILE="${NWP_ROOT}/.secrets.yml"
  cat > "${NWP_SECRETS_FILE}" <<'YML'
gitlab:
  server:
    domain: fixture.example.org
fixture:
  token: PLACEHOLDER_canonical_value_A
YML
  chmod 600 "${NWP_SECRETS_FILE}"

  # Entry 0 is a LIVE credential — every negative control in this file runs
  # against it, so a fix that "works" by refusing everything is caught.
  # Entry 1 has never been issued: no value anywhere, `fixture.notyet` is not
  # even a key in .secrets.yml. rotate_url is deliberately EMPTY, which is the
  # honest state for an identity that does not exist yet (MR !409: the token
  # page 404s until the bot user is created).
  export NWP_SECRETS_REGISTRY="${NWP_ROOT}/private/registry.yml"
  cat > "${NWP_SECRETS_REGISTRY}" <<'YML'
version: 1
secrets:
  - id: fixture_token
    provider: gitlab
    type: fixture token that already exists
    scopes: [api]
    stored_in:
      - .secrets.yml:fixture.token
    rotate_via: manual
    rotate_url: ""
    cadence_days: 365
    expires: "2099-01-01"
    last_rotated: "2026-01-01"
    owner: operator
    status: active
  - id: not_yet
    provider: gitlab
    type: fixture credential AWAITING OPERATOR MINT — it does not exist
    scopes: [api]
    stored_in:
      - .secrets.yml:fixture.notyet
    rotate_via: manual
    rotate_url: ""
    cadence_days: 365
    expires: ""
    last_rotated: ""
    owner: operator
    status: not-provisioned
ai_provisionable_hosts:
  - mini
ignored_keys:
  - gitlab.server.domain
YML
  export NWP_LEAK_SURFACES="${TEST_TMP}/surface"; mkdir -p "${TEST_TMP}/surface"

  cd "${TEST_TMP}/elsewhere" || return 1
}

teardown() {
  cd / || true
  local rc=0
  estate_guard_assert || rc=1
  rm -rf "${TEST_TMP}"
  return $rc
}

st_of()      { yq e ".secrets[] | select(.id==\"$1\") | .status"       "$NWP_SECRETS_REGISTRY"; }
rotated_of() { yq e ".secrets[] | select(.id==\"$1\") | .last_rotated" "$NWP_SECRETS_REGISTRY"; }
rot_log()    { echo "${NWP_ROOT}/private/rotation-$(date +%Y-%m).md"; }

run_secrets() { run env HOME="$HOME" bash "$SECRETS_SH" "$@"; }

# Drives `rotate`, which reads the value and the expiry from /dev/tty on
# purpose. $1 is the pasted value ('' = press Enter, i.e. "I updated it
# elsewhere"), $2 the id.
rotate_pty() { # value id
  pty_run "$1
2030-01-01
" "env NWP_ROOT='$NWP_ROOT' HOME='$HOME' PATH='$PATH' \
        NWP_SECRETS_FILE='$NWP_SECRETS_FILE' NWP_SECRETS_REGISTRY='$NWP_SECRETS_REGISTRY' \
        NWP_LEAK_SURFACES='$NWP_LEAK_SURFACES' FAKE_CURL_ALIVE='$FAKE_CURL_ALIVE' \
        bash '$SECRETS_SH' rotate $2"
}

# ── 1. the record must not assert a rotation that never happened ─────────────
#
# `done --all` walked EVERY entry and called mark_done on it. mark_done's
# propagation gate (`entry_locations_in_sync`) returns "in sync" when canonical
# is unreadable — which is exactly the never-issued case — so the not-provisioned
# entry sailed through, got today's date stamped into `last_rotated`, an expiry
# computed from it, and a "- [x] … rotated …" line written into the month's
# rotation log. For a credential nobody has ever minted.

@test "done --all: a credential that was NEVER ISSUED is not stamped as rotated" {
  run_secrets done --all
  [ "$(rotated_of not_yet)" = "" ]
}

@test "done --all: no rotation-log line is written for a credential that does not exist" {
  run_secrets done --all
  if [ -f "$(rot_log)" ]; then
    run grep -c 'not_yet' "$(rot_log)"
    [ "$output" = "0" ]
  fi
}

@test "done <id>: refuses a never-issued credential BY NAME and says how to issue it" {
  run_secrets done not_yet
  [ "$status" -ne 0 ]
  [[ "$output" == *"NOT ISSUED YET"* ]]
  [[ "$output" == *"pl secrets steps not_yet"* ]]
  [ "$(rotated_of not_yet)" = "" ]
}

@test "done: NEGATIVE CONTROL — an issued credential still stamps normally" {
  run_secrets done fixture_token 2026-06-01
  [ "$status" -eq 0 ]
  [ "$(rotated_of fixture_token)" = "2026-06-01" ]
}

# ── 2. FIRST ISSUE has to clear the flag, or the audit never sees it ─────────

@test "rotate: FIRST ISSUE promotes the entry OUT of not-provisioned" {
  rotate_pty 'PLACEHOLDER_first_issue_value' not_yet
  [ "$(yq e '.fixture.notyet' "$NWP_SECRETS_FILE")" = "PLACEHOLDER_first_issue_value" ]
  run st_of not_yet
  [[ "$output" != "not-provisioned" ]]
  [[ "$output" == provisioned-* ]]
}

@test "rotate: after FIRST ISSUE the credential is VISIBLE to audit (it was skipped before)" {
  rotate_pty 'PLACEHOLDER_first_issue_value' not_yet
  run env HOME="$HOME" bash "$SECRETS_SH" audit --offline
  [ "$status" -eq 0 ]
  [[ "$output" == *"not_yet"* ]]
}

@test "rotate: the promotion is on EVIDENCE — an entry with no value is NOT promoted" {
  # Press Enter at the value prompt: "I updated it elsewhere". Nothing was
  # written, so the credential still does not exist and the flag must stand.
  # Promoting on the strength of having been ASKED would put the entry back
  # under the audit's eye while it was still empty — the mirror-image lie.
  rotate_pty '' not_yet
  [ "$(st_of not_yet)" = "not-provisioned" ]
}

@test "done: a hand-minted FIRST ISSUE also promotes, once the value is really there" {
  yq e -i '.fixture.notyet = "PLACEHOLDER_minted_by_hand"' "$NWP_SECRETS_FILE"
  run_secrets done not_yet 2026-06-01
  [ "$status" -eq 0 ]
  run st_of not_yet
  [[ "$output" == provisioned-* ]]
}

@test "rotate: NEGATIVE CONTROL — an already-live entry's status is left alone" {
  rotate_pty 'PLACEHOLDER_canonical_value_B' fixture_token
  [ "$(st_of fixture_token)" = "active" ]
}

# ── 3. diagnosis: say NOT ISSUED YET, not "unreadable" / "on its way out" ────

@test "sync: a never-issued credential reads as NOT ISSUED YET, not as a broken file" {
  run_secrets sync not_yet
  [ "$status" -eq 2 ]
  [[ "$output" == *"NOT ISSUED YET"* ]]
  [[ "$output" == *"pl secrets steps not_yet"* ]]
  [[ "$output" != *"unreadable"* ]]
}

@test "verify-copy: a never-issued credential reads as NOT ISSUED YET, not as unreadable" {
  run_secrets verify-copy not_yet
  [ "$status" -eq 2 ]
  [[ "$output" == *"NOT ISSUED YET"* ]]
  [[ "$output" != *"unreadable"* ]]
}

@test "provision: refuses a never-issued credential for the RIGHT reason" {
  run_secrets provision not_yet --to 'host=mini:~/.config/fix.token:@file' --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"NOT ISSUED YET"* ]]
  [[ "$output" == *"pl secrets steps not_yet"* ]]
  # the old message described a credential being retired or mis-tiered — a
  # completely different problem, and it sent the operator to "fix the entry"
  [[ "$output" != *"on its way out"* ]]
}

@test "provision: NEGATIVE CONTROL — a RETIRED entry still refuses as on-its-way-out" {
  yq e -i '.secrets[1].status = "RETIRED"' "$NWP_SECRETS_REGISTRY"
  run_secrets provision not_yet --to 'host=mini:~/.config/fix.token:@file' --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"on its way out"* ]]
}

@test "provision: NEGATIVE CONTROL — an issued credential is still refused only by the boundary" {
  # fixture_token is live, so it gets past the status gate and is judged on the
  # host allowlist alone. A blanket "refuse everything" fix would break this.
  run_secrets provision fixture_token --to 'host=nowhere:~/.config/fix.token:@file' --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"ai_provisionable_hosts"* ]]
}

# ── 4. a registry full of AWAITING-MINT entries must not be permanently red ──
#
# GREEN TODAY — a regression pin, not a red proof. audit/capabilities/lint
# already skip not-provisioned entries deliberately (ops#268 made the same
# argument for RETIRED ones). Pinned here because the fixes above give the flag
# an exit, and the temptation next time is to make the flag itself an error.

@test "audit: an AWAITING-MINT entry does not make the audit red (pin)" {
  run env HOME="$HOME" bash "$SECRETS_SH" audit --offline
  [ "$status" -eq 0 ]
}

@test "status: an AWAITING-MINT entry is listed as pending, not as a failure (pin)" {
  run_secrets status
  [ "$status" -eq 0 ]
  [[ "$output" == *"not_yet"* ]]
}

# ── 5. the DETECTOR: lint must be able to see the fail-open state at all ─────
#
# Found live while sanity-checking this branch against the operator's own
# registry, 2026-08-10 22:50: `gitlab_forge_admin` had just been minted — the
# file `~/.config/nwp/forge-admin.token` exists and holds a value — and the
# entry still reads `status: not-provisioned`. So audit, capabilities, lint,
# `rotate --due` and the daily liveness cron all skip a credential that EXISTS,
# and NOTHING in the tree could say so: lint's own provisioned/empty
# consistency check keys off a `.secrets.yml:<key>` location and `continue`s
# when there isn't one. That entry's only location is an `@file` outside
# .secrets.yml — which is the WHOLE POINT of that credential (NWP-ADR-0038 keeps it
# out of the AI-readable tier), so the one entry that most needed the check was
# the one shape the check could not see.

@test "lint: a not-provisioned entry whose @file ALREADY HOLDS a value is reported" {
  mkdir -p "${NWP_ROOT}/private"
  printf 'PLACEHOLDER_minted_out_of_band\n' > "${NWP_ROOT}/private/forge.token"
  chmod 600 "${NWP_ROOT}/private/forge.token"
  yq e -i '.secrets[1].stored_in = ["private/forge.token:@file"]' "$NWP_SECRETS_REGISTRY"
  run_secrets lint
  [[ "$output" == *"not_yet"* ]]
  [[ "$output" == *"marked not-provisioned"* ]]
}

@test "lint: NEGATIVE CONTROL — a genuinely un-minted @file entry is NOT reported" {
  yq e -i '.secrets[1].stored_in = ["private/never.token:@file"]' "$NWP_SECRETS_REGISTRY"
  run_secrets lint
  [[ "$output" != *"not_yet: marked not-provisioned"* ]]
}

@test "lint: NEGATIVE CONTROL — the .secrets.yml-keyed case still reports" {
  yq e -i '.fixture.notyet = "PLACEHOLDER_minted_out_of_band"' "$NWP_SECRETS_FILE"
  run_secrets lint
  [[ "$output" == *"not_yet"* ]]
  [[ "$output" == *"marked not-provisioned"* ]]
}
