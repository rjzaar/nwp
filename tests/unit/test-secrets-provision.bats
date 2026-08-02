#!/usr/bin/env bats
# `pl secrets provision` — the missing half of the registry contract.
#
# Before this verb existed there was NO `pl` way to put a credential onto
# another host. `sync` reads the grammar, sees `host=…`, and prints
# "SKIP (not writable from here)"; `write_value_to_location` returns 1 on any
# `host=` location with "propagate there". So the only way to give an agent
# host a token was `scp` — and a hand-scp'd secret is undeclared by
# construction, which is precisely the defect already recorded against met
# (70 auth.json + a full .secrets.yml, 6 of 7 values byte-identical to live,
# invisible to rotate/audit forever).
#
# `provision` closes it: it WRITES the copy and DECLARES it in the same step,
# so a copy cannot exist without a `stored_in` row that
# `pl secrets audit --locations` can see.
#
# Fully offline. `ssh` is faked to execute the remote command locally against a
# separate HOME, so the write + the hash read-back are genuinely exercised.
# Fixture values are deliberately NOT token-shaped.

load helpers/secrets-sandbox

setup() {
  estate_guard_arm   # BEFORE HOME moves — see helpers/secrets-sandbox.bash
  TEST_TMP=$(mktemp -d)
  SECRETS_SH=$(secrets_sandbox_script \
    "${BATS_TEST_DIRNAME}/../../scripts/commands/secrets.sh" \
    "${TEST_TMP}/sandbox")
  export NWP_ROOT="${TEST_TMP}/estate"
  mkdir -p "${NWP_ROOT}/logs" "${NWP_ROOT}/private"
  export HOME="${TEST_TMP}/home"; mkdir -p "$HOME"

  # The "remote" host's home. The fake ssh runs the command with HOME set here,
  # so `"$HOME"/…` in a remote command lands in a different tree than local.
  export FAKE_REMOTE_HOME="${TEST_TMP}/remote-home"; mkdir -p "$FAKE_REMOTE_HOME"

  mkdir -p "${TEST_TMP}/bin"
  cat > "${TEST_TMP}/bin/ssh" <<'SSH'
#!/usr/bin/env bash
# Fake ssh: drop options, drop the host word, run the rest locally under
# HOME=$FAKE_REMOTE_HOME. Records every invocation for argv assertions.
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    -o*|-q|-T|-n) shift ;;
    -i|-p|-l) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
host="${args[0]:-}"; unset 'args[0]'
printf '%s\n' "host=${host} cmd=${args[*]}" >> "${FAKE_SSH_LOG:-/dev/null}"
HOME="$FAKE_REMOTE_HOME" bash -c "${args[*]}"
SSH
  chmod +x "${TEST_TMP}/bin/ssh"
  cp "${BATS_TEST_DIRNAME}/helpers/fake-curl.sh" "${TEST_TMP}/bin/curl"
  chmod +x "${TEST_TMP}/bin/curl"
  export FAKE_CURL_ALIVE="${TEST_TMP}/alive"
  printf 'PLACEHOLDER_canonical_value_A\n' > "$FAKE_CURL_ALIVE"
  export PATH="${TEST_TMP}/bin:$PATH"
  export FAKE_SSH_LOG="${TEST_TMP}/ssh.log"

  export NWP_SECRETS_FILE="${TEST_TMP}/secrets.yml"
  cat > "${NWP_SECRETS_FILE}" <<'YML'
gitlab:
  server:
    domain: fixture.example.org
fixture:
  token: PLACEHOLDER_canonical_value_A
YML
  chmod 600 "${NWP_SECRETS_FILE}"

  export NWP_SECRETS_REGISTRY="${TEST_TMP}/registry.yml"
  cat > "${NWP_SECRETS_REGISTRY}" <<'YML'
version: 1
secrets:
  - id: fixture_token
    provider: gitlab
    type: fixture
    scopes: [api]
    stored_in:
      - .secrets.yml:fixture.token
    rotate_via: manual
    rotate_url: ""
    cadence_days: 365
    expires: unknown
    last_rotated: ""
    owner: operator
ai_provisionable_hosts:
  - mini
ignored_keys: []
YML
}

teardown() { estate_guard_assert; rm -rf "${TEST_TMP:?}"; }

run_secrets() { run env HOME="$HOME" bash "$SECRETS_SH" "$@"; }

canon_sha() { printf '%s' 'PLACEHOLDER_canonical_value_A' | sha256sum | cut -d' ' -f1; }

# ── the gap this verb exists to close ─────────────────────────────────────────

@test "provision: dry-run by default — declares nothing and writes nothing" {
  run_secrets provision fixture_token --to 'host=mini:~/.config/fix.token:@file'
  [ "$status" -eq 0 ]
  [[ "$output" == *"would"* ]] || [[ "$output" == *"dry run"* ]]
  [ ! -e "${FAKE_REMOTE_HOME}/.config/fix.token" ]
  run grep -c 'host=mini' "$NWP_SECRETS_REGISTRY"
  [ "$output" = "0" ]
}

@test "provision --apply: writes the remote copy AND declares it in one step" {
  run_secrets provision fixture_token --to 'host=mini:~/.config/fix.token:@file' --apply
  [ "$status" -eq 0 ]
  # written
  [ -f "${FAKE_REMOTE_HOME}/.config/fix.token" ]
  run cat "${FAKE_REMOTE_HOME}/.config/fix.token"
  [ "$output" = "PLACEHOLDER_canonical_value_A" ]
  # declared — this is the whole point: no copy without a stored_in row
  run "$(command -v yq)" e '.secrets[0].stored_in[]' "$NWP_SECRETS_REGISTRY"
  [[ "$output" == *'host=mini:~/.config/fix.token:@file'* ]]
}

@test "provision --apply: the value never appears in argv on either side" {
  run_secrets provision fixture_token --to 'host=mini:~/.config/fix.token:@file' --apply
  [ "$status" -eq 0 ]
  run grep -c 'PLACEHOLDER_canonical_value_A' "$FAKE_SSH_LOG"
  [ "$output" = "0" ]
}

@test "provision --apply: never prints the value" {
  run_secrets provision fixture_token --to 'host=mini:~/.config/fix.token:@file' --apply
  [[ "$output" != *"PLACEHOLDER_canonical_value_A"* ]]
}

@test "provision --apply: remote file is created 0600" {
  run_secrets provision fixture_token --to 'host=mini:~/.config/fix.token:@file' --apply
  [ "$status" -eq 0 ]
  run stat -c '%a' "${FAKE_REMOTE_HOME}/.config/fix.token"
  [ "$output" = "600" ]
}

@test "provision --apply: verifies by SHA-256 read-back, and says so" {
  run_secrets provision fixture_token --to 'host=mini:~/.config/fix.token:@file' --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"VERIFIED"* ]]
  # the read-back really did hash the remote file
  run bash -c "head -1 '${FAKE_REMOTE_HOME}/.config/fix.token' | tr -d '\n' | sha256sum | cut -d' ' -f1"
  [ "$output" = "$(canon_sha)" ]
}

@test "provision: yaml kind creates the remote file and sets a dotted key" {
  run_secrets provision fixture_token --to 'host=mini:~/nwp/.secrets.yml:gitlab.ops_note_token' --apply
  [ "$status" -eq 0 ]
  run "$(command -v yq)" e '.gitlab.ops_note_token' "${FAKE_REMOTE_HOME}/nwp/.secrets.yml"
  [ "$output" = "PLACEHOLDER_canonical_value_A" ]
  run stat -c '%a' "${FAKE_REMOTE_HOME}/nwp/.secrets.yml"
  [ "$output" = "600" ]
}

@test "provision: env kind appends the var when absent" {
  run_secrets provision fixture_token --to 'host=mini:~/.agent.env:FIX_TOKEN' --apply
  [ "$status" -eq 0 ]
  run grep -c '^FIX_TOKEN=' "${FAKE_REMOTE_HOME}/.agent.env"
  [ "$output" = "1" ]
}

@test "provision: re-provisioning a declared copy is idempotent" {
  run_secrets provision fixture_token --to 'host=mini:~/.config/fix.token:@file' --apply
  [ "$status" -eq 0 ]
  run_secrets provision fixture_token --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"already correct"* ]] || [[ "$output" == *"VERIFIED"* ]]
  # still exactly one declaration — provision must not duplicate the row
  run bash -c "\"$(command -v yq)\" e '.secrets[0].stored_in[]' '$NWP_SECRETS_REGISTRY' | grep -c 'host=mini'"
  [ "$output" = "1" ]
}

# ── the boundary: an agent host may hold live-tier, never prod ────────────────

@test "provision: REFUSES the ver role even when it is allowlisted — the two lists cannot be edited into agreement" {
  "$(command -v yq)" e -i '.ai_provisionable_hosts += ["ver"]' "$NWP_SECRETS_REGISTRY"
  run_secrets provision fixture_token --to 'host=ver:~/.config/fix.token:@file' --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"ver"* ]]
  [ ! -e "${FAKE_REMOTE_HOME}/.config/fix.token" ]
  run grep -c 'host=ver' "$NWP_SECRETS_REGISTRY"
  [ "$output" = "0" ]
}

@test "provision: REFUSES a host the operator named in prod_hosts:" {
  "$(command -v yq)" e -i '.prod_hosts = ["deploy-laptop"]' "$NWP_SECRETS_REGISTRY"
  "$(command -v yq)" e -i '.ai_provisionable_hosts += ["deploy-laptop"]' "$NWP_SECRETS_REGISTRY"
  run_secrets provision fixture_token --to 'host=deploy-laptop:~/.config/fix.token:@file' --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"prod territory"* ]]
  [ ! -e "${FAKE_REMOTE_HOME}/.config/fix.token" ]
}

@test "provision: FAIL-CLOSED — a host nobody allowlisted is refused" {
  run_secrets provision fixture_token --to 'host=some-other-box:~/.config/fix.token:@file' --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"ai_provisionable_hosts"* ]]
  run grep -c 'some-other-box' "$NWP_SECRETS_REGISTRY"
  [ "$output" = "0" ]
}

@test "provision: FAIL-CLOSED — an estate that declares no agent host can provision nothing" {
  "$(command -v yq)" e -i 'del(.ai_provisionable_hosts)' "$NWP_SECRETS_REGISTRY"
  run_secrets provision fixture_token --to 'host=mini:~/.config/fix.token:@file' --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"ai_provisionable_hosts"* ]]
  [ ! -e "${FAKE_REMOTE_HOME}/.config/fix.token" ]
}

@test "provision: the prod refusal has no override flag" {
  "$(command -v yq)" e -i '.ai_provisionable_hosts += ["ver"]' "$NWP_SECRETS_REGISTRY"
  run_secrets provision fixture_token --to 'host=ver:~/.config/fix.token:@file' --apply --force
  [ "$status" -ne 0 ]
  run env HOME="$HOME" NWP_SECRETS_PROVISION_FORCE=1 bash "$SECRETS_SH" \
      provision fixture_token --to 'host=ver:~/.config/fix.token:@file' --apply
  [ "$status" -ne 0 ]
}

# ── refuse to spread a credential that should not be spread ───────────────────

@test "provision: REFUSES an entry whose status is RETIRED / REVOKE-PENDING" {
  "$(command -v yq)" e -i '.secrets[0].status = "REVOKE-PENDING"' "$NWP_SECRETS_REGISTRY"
  run_secrets provision fixture_token --to 'host=mini:~/.config/fix.token:@file' --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"REVOKE-PENDING"* ]]
  [ ! -e "${FAKE_REMOTE_HOME}/.config/fix.token" ]
}

@test "provision: REFUSES a --to that is not a host= location" {
  run_secrets provision fixture_token --to '.secrets.yml:fixture.token' --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"host="* ]]
}

@test "provision: REFUSES an unparseable --to rather than declaring garbage" {
  run_secrets provision fixture_token --to 'host=mini:no-ref-here' --apply
  [ "$status" -ne 0 ]
  run grep -c 'no-ref-here' "$NWP_SECRETS_REGISTRY"
  [ "$output" = "0" ]
}

@test "provision: unknown id fails loudly" {
  run_secrets provision no_such_entry --to 'host=mini:~/.config/x:@file' --apply
  [ "$status" -ne 0 ]
}

@test "provision: with no --to and no declared host= copies, says so and exits 0" {
  run_secrets provision fixture_token --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"no host="* ]]
}

# ── the declaration must not outlive a failed write ───────────────────────────

@test "provision: a failed remote write leaves NO declaration behind" {
  cat > "${TEST_TMP}/bin/ssh" <<'SSH'
#!/usr/bin/env bash
exit 255
SSH
  chmod +x "${TEST_TMP}/bin/ssh"
  run_secrets provision fixture_token --to 'host=mini:~/.config/fix.token:@file' --apply
  [ "$status" -ne 0 ]
  run grep -c 'host=mini' "$NWP_SECRETS_REGISTRY"
  [ "$output" = "0" ]
}

@test "provision: a write that does not read back CLEAN fails and declares nothing" {
  # ssh writes nothing but exits 0 — the read-back must catch it.
  cat > "${TEST_TMP}/bin/ssh" <<'SSH'
#!/usr/bin/env bash
exit 0
SSH
  chmod +x "${TEST_TMP}/bin/ssh"
  run_secrets provision fixture_token --to 'host=mini:~/.config/fix.token:@file' --apply
  [ "$status" -ne 0 ]
  run grep -c 'host=mini' "$NWP_SECRETS_REGISTRY"
  [ "$output" = "0" ]
}

# ── sibling gap: `adopt` could not describe a credential that is a FILE ───────
# The estate's live-box ssh key (`servers/live/.nwp-server.yml` → ssh_key:
# ~/.ssh/gitlab_linode) is not a .secrets.yml key, so before this branch it
# could not be entered into the registry on ANY host — undeclared by
# construction, on every machine that held it.

@test "adopt: a local <path>:<ref> location becomes a registry entry" {
  printf 'ssh-ed25519 AAAAFIXTUREPUBLICKEY fixture@host\n' > "${TEST_TMP}/k.pub"
  run_secrets adopt "${TEST_TMP}/k.pub:@file" --as fixture_ssh_key
  [ "$status" -eq 0 ]
  run "$(command -v yq)" e '.secrets[] | select(.id == "fixture_ssh_key") | .stored_in[0]' "$NWP_SECRETS_REGISTRY"
  [ "$output" = "${TEST_TMP}/k.pub:@file" ]
}

@test "adopt: refuses a local location that is not there" {
  run_secrets adopt "${TEST_TMP}/absent.pub:@file" --as fixture_ssh_key
  [ "$status" -ne 0 ]
  run grep -c 'fixture_ssh_key' "$NWP_SECRETS_REGISTRY"
  [ "$output" = "0" ]
}

@test "adopt: refuses a local location that reads back empty" {
  : > "${TEST_TMP}/empty.pub"
  run_secrets adopt "${TEST_TMP}/empty.pub:@file" --as fixture_ssh_key
  [ "$status" -ne 0 ]
}

@test "adopt: refuses to declare the same local location twice" {
  printf 'ssh-ed25519 AAAAFIXTUREPUBLICKEY fixture@host\n' > "${TEST_TMP}/k.pub"
  run_secrets adopt "${TEST_TMP}/k.pub:@file" --as fixture_ssh_key
  [ "$status" -eq 0 ]
  run_secrets adopt "${TEST_TMP}/k.pub:@file" --as fixture_ssh_key2
  [ "$status" -ne 0 ]
  [[ "$output" == *"already declared"* ]]
}

@test "adopt: a .secrets.yml dotted key still works (no regression)" {
  run_secrets adopt fixture.token --as fixture_dup
  # already declared by the fixture registry — must be refused, not duplicated
  [ "$status" -ne 0 ]
  [[ "$output" == *"already declared"* ]]
}

@test "adopt+provision: one entry can name canonical here AND the copy on mini" {
  printf 'ssh-ed25519 AAAAFIXTUREPUBLICKEY fixture@host\n' > "${TEST_TMP}/k.pub"
  run_secrets adopt "${TEST_TMP}/k.pub:@file" --as fixture_ssh_key
  [ "$status" -eq 0 ]
  mkdir -p "${FAKE_REMOTE_HOME}/.ssh"
  printf 'ssh-ed25519 AAAAFIXTUREPUBLICKEY fixture@host\n' > "${FAKE_REMOTE_HOME}/.ssh/k.pub"
  # the copy is already in place and identical — provision declares + verifies it
  run_secrets provision fixture_ssh_key --to 'host=mini:~/.ssh/k.pub:@file' --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"VERIFIED"* ]]
  run bash -c "\"$(command -v yq)\" e '.secrets[] | select(.id == \"fixture_ssh_key\") | .stored_in | length' '$NWP_SECRETS_REGISTRY'"
  [ "$output" = "2" ]
}

# ── ssh probes: a falsifiable scope claim for a credential with no HTTP face ──
# The estate's live-box ssh key is root-equivalent on the box that holds the
# trust root. Probes were HTTP-only AND gated on provider gitlab|github|linode,
# so `provider: local` could never carry a checkable claim — the exact shape of
# "a capability the registry never checks is folklore".

_probe_setup() {
  cat > "${TEST_TMP}/bin/ssh" <<SSH
#!/usr/bin/env bash
# exit code is driven by the destination, so positive and negative probes
# can both be exercised offline
for a in "\$@"; do
  case "\$a" in
    reachable@host) exit 0 ;;
    refused@host)   exit 255 ;;
  esac
done
exit 0
SSH
  chmod +x "${TEST_TMP}/bin/ssh"
  printf 'ssh-ed25519 AAAAFIXTUREPUBLICKEY fixture@host\n' > "${TEST_TMP}/k.pub"
  touch "${TEST_TMP}/k"
  "$(command -v yq)" e -i '.secrets[0].provider = "local"' "$NWP_SECRETS_REGISTRY"
}

@test "audit: a POSITIVE ssh probe that reaches its host is clean" {
  _probe_setup
  PJ='[{"name":"reaches","ssh":"reachable@host","key":"'"${TEST_TMP}/k"'","expect_rc":0}]' \
    "$(command -v yq)" e -i '.secrets[0].probe = (strenv(PJ) | from_json)' "$NWP_SECRETS_REGISTRY"
  run_secrets audit
  [[ "$output" != *"SCOPE-DRIFT"* ]]
}

@test "audit: a NEGATIVE ssh probe records a LIMIT — widening it goes red" {
  _probe_setup
  # claim: this key must NOT be accepted there (rc 255). Reality agrees.
  PJ='[{"name":"must-not-reach","ssh":"refused@host","key":"'"${TEST_TMP}/k"'","expect_rc":255}]' \
    "$(command -v yq)" e -i '.secrets[0].probe = (strenv(PJ) | from_json)' "$NWP_SECRETS_REGISTRY"
  run_secrets audit
  [[ "$output" != *"SCOPE-DRIFT"* ]]

  # now the limit is violated: the host starts accepting the key
  PJ='[{"name":"must-not-reach","ssh":"reachable@host","key":"'"${TEST_TMP}/k"'","expect_rc":255}]' \
    "$(command -v yq)" e -i '.secrets[0].probe = (strenv(PJ) | from_json)' "$NWP_SECRETS_REGISTRY"
  run_secrets audit
  [[ "$output" == *"SCOPE-DRIFT"* ]]
}

@test "audit: an ssh probe whose key is absent reports PROBE-BLIND, not a pass" {
  _probe_setup
  PJ='[{"name":"must-not-reach","ssh":"refused@host","key":"'"${TEST_TMP}/absent-key"'","expect_rc":255}]' \
    "$(command -v yq)" e -i '.secrets[0].probe = (strenv(PJ) | from_json)' "$NWP_SECRETS_REGISTRY"
  run_secrets audit
  [[ "$output" == *"PROBE-BLIND"* ]]
  # and it must NOT have been silently graded as the negative it claims
  [[ "$output" != *"SCOPE-DRIFT"* ]]
}

@test "lint: an ssh probe satisfies NO-PROBE for a scope-declaring entry" {
  _probe_setup
  "$(command -v yq)" e -i '.secrets[0].scopes = ["live-tier-ssh"]' "$NWP_SECRETS_REGISTRY"
  run_secrets lint
  [[ "$output" == *"NO-PROBE"* ]]
  PJ='[{"name":"reaches","ssh":"reachable@host","key":"'"${TEST_TMP}/k"'","expect_rc":0}]' \
    "$(command -v yq)" e -i '.secrets[0].probe = (strenv(PJ) | from_json)' "$NWP_SECRETS_REGISTRY"
  run_secrets lint
  [[ "$output" != *"NO-PROBE"* ]]
}
