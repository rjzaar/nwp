#!/usr/bin/env bats
# `pl secrets` — the WRITE half of registry truth.
#
# The audit half (test-secrets-audit.bats) proved the READER checks every
# declared location. It resolves each location with `loc_abspath`, so a relative
# `sites/<x>/auth.json:…` is read from the estate root.
#
# The WRITER never learned that. `write_value_to_location` still does its own
# ad-hoc path handling — `~` expansion and nothing else — so every relative
# location resolves against the CALLER'S WORKING DIRECTORY. On the real estate
# that is 48 of the 49 declared copies of the composer registry token, plus the
# canonical `.secrets.yml` itself. Three consequences, all observed live:
#
#   1. `rotate` wrote 1 of 49 locations and reported success.
#   2. `sync` — the repair verb `audit` tells you to run — wrote 0 of 2 and
#      exited 0. The tool's own remedy is a no-op.
#   3. `audit` and `sync` therefore DISAGREE about where a value lives: audit
#      reads sites/x/auth.json from the estate and calls it DRIFT; sync looks
#      for it under $PWD, says "missing", and returns success.
#
# A reader and a writer that disagree about a path is the same class of defect
# as an audit that checks one location: the command reports on something other
# than the thing it claims to report on.
#
# Fully offline. Fixture values are deliberately NOT token-shaped.

load helpers/secrets-sandbox

setup() {
  estate_guard_arm   # BEFORE HOME is moved

  TEST_TMP=$(mktemp -d)
  # Containment is a property of WHERE the subject sits, not of a variable it is
  # asked to honour — see helpers/secrets-sandbox.bash.
  SECRETS_SH=$(secrets_sandbox_script \
    "${NWP_TEST_SECRETS_SH:-${BATS_TEST_DIRNAME}/../../scripts/commands/secrets.sh}" \
    "${TEST_TMP}/sandbox")

  export NWP_ROOT="${TEST_TMP}/estate"
  mkdir -p "${NWP_ROOT}/private" "${NWP_ROOT}/logs" "${NWP_ROOT}/sites/demo" "${TEST_TMP}/elsewhere"
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

  # A RELATIVE declared copy — the shape of all 47 sites/*/auth.json entries.
  printf '{ "gitlab-token": { "fixture.example.org": "PLACEHOLDER_stale_value_B" } }\n' \
    > "${NWP_ROOT}/sites/demo/auth.json"
  chmod 600 "${NWP_ROOT}/sites/demo/auth.json"
  printf 'export FIXTURE_TOKEN="PLACEHOLDER_stale_value_B"\n' > "${NWP_ROOT}/sites/demo/env"
  chmod 600 "${NWP_ROOT}/sites/demo/env"

  export NWP_SECRETS_REGISTRY="${NWP_ROOT}/private/registry.yml"
  cat > "${NWP_SECRETS_REGISTRY}" <<'YML'
version: 1
secrets:
  - id: fixture_token
    provider: gitlab
    type: fixture token with relative declared locations
    scopes: [api]
    stored_in:
      - .secrets.yml:fixture.token
      - sites/demo/auth.json:.["gitlab-token"]["fixture.example.org"]
      - sites/demo/env:FIXTURE_TOKEN
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
  export NWP_LEAK_SURFACES="${TEST_TMP}/surface"; mkdir -p "${TEST_TMP}/surface"

  # Every test runs from a directory that is NOT the estate root. That is the
  # normal case for `pl` (it is on $PATH and run from wherever you happen to be)
  # and it is the mandated case for this project, whose standing rule is to work
  # in a `pl issue work` worktree.
  cd "${TEST_TMP}/elsewhere" || return 1
}

teardown() {
  cd / || true
  local rc=0
  estate_guard_assert || rc=1
  rm -rf "${TEST_TMP}"
  return $rc
}

json_at()  { jq -r '.["gitlab-token"]["fixture.example.org"]' "${NWP_ROOT}/sites/demo/auth.json"; }
canon_at() { yq e '.fixture.token' "${NWP_SECRETS_FILE}"; }
stamped()  { yq e '.secrets[0].last_rotated' "${NWP_SECRETS_REGISTRY}"; }
rot_log()  { echo "${NWP_ROOT}/private/rotation-$(date +%Y-%m).md"; }

# --- defect 1: the writer must resolve paths exactly like the reader ---------

@test "sync: a RELATIVE stored_in path resolves against the estate root, not \$PWD" {
  run bash "$SECRETS_SH" sync fixture_token
  [ "$(json_at)" = "PLACEHOLDER_canonical_value_A" ]
  grep -q 'FIXTURE_TOKEN="PLACEHOLDER_canonical_value_A"' "${NWP_ROOT}/sites/demo/env"
}

@test "sync: exits non-zero when a declared location could not be written" {
  yq e -i '.secrets[0].stored_in += ["sites/ghost/auth.json:.[\"gitlab-token\"][\"fixture.example.org\"]"]' \
    "$NWP_SECRETS_REGISTRY"
  run bash "$SECRETS_SH" sync fixture_token
  [ "$status" -ne 0 ]
  [[ "$output" == *"sites/ghost/auth.json"* ]]
}

@test "sync: never writes anything under the caller's working directory" {
  run bash "$SECRETS_SH" sync fixture_token
  run find "${TEST_TMP}/elsewhere" -mindepth 1
  [ -z "$output" ]
}

@test "audit and sync agree about where a declared value lives" {
  # audit calls the relative copy DRIFT and points at `sync`; after `sync` the
  # same audit must be clean. If the two resolve paths differently, one of them
  # is reporting on a file the other never touches.
  run bash "$SECRETS_SH" audit --locations
  [ "$status" -ne 0 ]
  [[ "$output" == *"DRIFT"* ]]
  bash "$SECRETS_SH" sync fixture_token
  run bash "$SECRETS_SH" audit --locations
  [ "$status" -eq 0 ]
}

# --- defect 2: rotate must fail loudly and must not stamp -------------------

@test "rotate: propagates to every declared location, including relative ones" {
  pty_run 'PLACEHOLDER_canonical_value_A
2030-01-01
' "env NWP_ROOT='$NWP_ROOT' HOME='$HOME' PATH='$PATH' \
        NWP_SECRETS_FILE='$NWP_SECRETS_FILE' NWP_SECRETS_REGISTRY='$NWP_SECRETS_REGISTRY' \
        NWP_LEAK_SURFACES='$NWP_LEAK_SURFACES' FAKE_CURL_ALIVE='$FAKE_CURL_ALIVE' \
        bash '$SECRETS_SH' rotate fixture_token"
  [ "$(canon_at)" = "PLACEHOLDER_canonical_value_A" ]
  [ "$(json_at)"  = "PLACEHOLDER_canonical_value_A" ]
  grep -q 'FIXTURE_TOKEN="PLACEHOLDER_canonical_value_A"' "${NWP_ROOT}/sites/demo/env"
}

@test "rotate: refuses to stamp the registry when a location could not be written" {
  yq e -i '.secrets[0].stored_in += ["sites/ghost/auth.json:.[\"gitlab-token\"][\"fixture.example.org\"]"]' \
    "$NWP_SECRETS_REGISTRY"
  out=$(pty_run 'PLACEHOLDER_canonical_value_A
2030-01-01
' "env NWP_ROOT='$NWP_ROOT' HOME='$HOME' PATH='$PATH' \
        NWP_SECRETS_FILE='$NWP_SECRETS_FILE' NWP_SECRETS_REGISTRY='$NWP_SECRETS_REGISTRY' \
        NWP_LEAK_SURFACES='$NWP_LEAK_SURFACES' FAKE_CURL_ALIVE='$FAKE_CURL_ALIVE' \
        bash '$SECRETS_SH' rotate fixture_token")
  echo "$out"
  # A rotation that reached some-but-not-all locations is an ERROR, not a success.
  [ "$(stamped)" = "2026-01-01" ]
  [ ! -f "$(rot_log)" ]
  [[ "$out" == *"sites/ghost/auth.json"* ]]
}

@test "rotate: prints a per-location result for every declared location" {
  out=$(pty_run 'PLACEHOLDER_canonical_value_A
2030-01-01
' "env NWP_ROOT='$NWP_ROOT' HOME='$HOME' PATH='$PATH' \
        NWP_SECRETS_FILE='$NWP_SECRETS_FILE' NWP_SECRETS_REGISTRY='$NWP_SECRETS_REGISTRY' \
        NWP_LEAK_SURFACES='$NWP_LEAK_SURFACES' FAKE_CURL_ALIVE='$FAKE_CURL_ALIVE' \
        bash '$SECRETS_SH' rotate fixture_token")
  echo "$out"
  [[ "$out" == *".secrets.yml:fixture.token"* ]]
  [[ "$out" == *"sites/demo/auth.json"* ]]
  [[ "$out" == *"sites/demo/env"* ]]
  [[ "$out" == *"3/3"* ]]
}

@test "rotate --force: stamps a partial rotation, but records that it was partial" {
  yq e -i '.secrets[0].stored_in += ["sites/ghost/auth.json:.[\"gitlab-token\"][\"fixture.example.org\"]"]' \
    "$NWP_SECRETS_REGISTRY"
  out=$(pty_run 'PLACEHOLDER_canonical_value_A
2030-01-01
' "env NWP_ROOT='$NWP_ROOT' HOME='$HOME' PATH='$PATH' \
        NWP_SECRETS_FILE='$NWP_SECRETS_FILE' NWP_SECRETS_REGISTRY='$NWP_SECRETS_REGISTRY' \
        NWP_LEAK_SURFACES='$NWP_LEAK_SURFACES' FAKE_CURL_ALIVE='$FAKE_CURL_ALIVE' \
        bash '$SECRETS_SH' rotate fixture_token --force")
  echo "$out"
  [ "$(stamped)" != "2026-01-01" ]
  grep -q 'PARTIAL' "$(rot_log)"
}

# --- defect 3: the suite may not touch real credential state ----------------

@test "containment: the script under test cannot reach the real estate" {
  # The sandboxed copy must derive its own PROJECT_ROOT/estate root from inside
  # the sandbox even with every NWP_* override removed — which is exactly the
  # condition the pre-fix script ran under when it appended `fixture_token` to
  # the operator's real rotation log.
  run env -u NWP_ROOT -u NWP_SECRETS_FILE -u NWP_SECRETS_REGISTRY \
      HOME="$HOME" PATH="$PATH" bash "$SECRETS_SH" status
  # Whatever it does, it must not have consulted the real estate. The estate
  # guard in teardown is the assertion; this case exists to exercise the path.
  [ -n "$output" ]
}

@test "containment: the estate guard actually fires when real state is touched" {
  # A canary that has never been shown to sing is indistinguishable from a dead
  # one. Arm the guard on a file we control, change it, and require a failure.
  local canary="${TEST_TMP}/canary"; printf 'before\n' > "$canary"
  ( NWP_TEST_ESTATE_GUARD_FILES="$canary" \
    BATS_TEST_DIRNAME="$BATS_TEST_DIRNAME" \
    bash -c 'source "'"${BATS_TEST_DIRNAME}"'/helpers/secrets-sandbox.bash"
             estate_guard_arm
             estate_guard_assert || { echo UNEXPECTED_EARLY_FAIL; exit 9; }
             printf "after\n" > "'"$canary"'"
             estate_guard_assert && { echo GUARD_DID_NOT_FIRE; exit 8; }
             exit 0' )
  [ "$?" -eq 0 ]
}

@test "containment: the sandboxed script's root is the sandbox, not the checkout" {
  local root
  root=$(cd "$(dirname "$SECRETS_SH")/../.." && pwd)
  [[ "$root" == "${TEST_TMP}/sandbox" ]]
  # and a git-common-dir lookup from there must stay inside it
  run git -C "$root" rev-parse --path-format=absolute --git-common-dir
  [[ "$output" == "${TEST_TMP}/sandbox"* ]]
}

# ── ops#317: host= @file — write over ssh or refuse the stamp ────────────────
#
# WHY: rotate consumed a shown-once pasted token, its writer returned
# "skip by design" for the entry's ONLY location (host=…:@file), and the
# registry stamped a clean rotation over a box file that was never written.
# The value was lost; the record said done. A host= @file location is
# WRITABLE (stdin → root 0600 install → hash read-back) and anything less
# than a verified write must block the stamp.

_arm_ssh_stub() { # $1 = ok | writefail | mismatch
  export SSH_STUB_LOG="${TEST_TMP}/ssh.log" SSH_STUB_CAP="${TEST_TMP}/ssh.stdin" SSH_STUB_MODE="$1"
  : > "$SSH_STUB_LOG"
  cat > "${TEST_TMP}/bin/ssh" <<'EOF'
#!/bin/bash
printf 'ARGS:%s\n' "$*" >> "$SSH_STUB_LOG"
case "$*" in
  *install*)
    cat > "$SSH_STUB_CAP"
    [ "$SSH_STUB_MODE" = writefail ] && exit 1
    exit 0 ;;
  *sha256sum*)
    if [ "$SSH_STUB_MODE" = mismatch ]; then echo deadbeefdeadbeef
    else head -1 "$SSH_STUB_CAP" | tr -d '\n' | sha256sum | cut -c1-16; fi
    exit 0 ;;
esac
exit 0
EOF
  chmod +x "${TEST_TMP}/bin/ssh"
}

_rotate_hostfile() { # runs rotate against a host=-only entry with the stub armed
  yq e -i '.secrets[0].stored_in = ["host=stubbox:/etc/nwp-demo/feedback.token:@file"]' \
    "$NWP_SECRETS_REGISTRY"
  pty_run 'PLACEHOLDER_canonical_value_A
2030-01-01
' "env NWP_ROOT='$NWP_ROOT' HOME='$HOME' PATH='$PATH' \
        NWP_SECRETS_FILE='$NWP_SECRETS_FILE' NWP_SECRETS_REGISTRY='$NWP_SECRETS_REGISTRY' \
        NWP_LEAK_SURFACES='$NWP_LEAK_SURFACES' FAKE_CURL_ALIVE='$FAKE_CURL_ALIVE' \
        SSH_STUB_LOG='$SSH_STUB_LOG' SSH_STUB_CAP='$SSH_STUB_CAP' SSH_STUB_MODE='$SSH_STUB_MODE' \
        bash '$SECRETS_SH' rotate fixture_token"
}

@test "ops#317: rotate WRITES a host= @file location — value via stdin, NEVER argv, then stamps" {
  _arm_ssh_stub ok
  _rotate_hostfile
  [ -f "$SSH_STUB_CAP" ]
  [ "$(head -1 "$SSH_STUB_CAP")" = "PLACEHOLDER_canonical_value_A" ]
  ! grep -q 'PLACEHOLDER_canonical_value_A' "$SSH_STUB_LOG"
  [ "$(stamped)" = "$(date +%F)" ]
}

@test "ops#317: ssh write FAILS → registry NOT stamped, rotation NOT logged" {
  _arm_ssh_stub writefail
  _rotate_hostfile || true
  [ "$(stamped)" = "2026-01-01" ]
  ! grep -q 'fixture_token — rotated' "${NWP_ROOT}/private/rotation-$(date +%Y-%m).md" 2>/dev/null
}

@test "ops#317: read-back hash MISMATCH → not trusted, registry NOT stamped" {
  _arm_ssh_stub mismatch
  _rotate_hostfile || true
  [ "$(stamped)" = "2026-01-01" ]
}

# ── 2026-08-10: a host= @file location in the REMOTE USER'S HOME ─────────────
# The ops#317 writer assumed every remote target was a root-owned system file
# (`sudo -n install -o root -g root`). That is wrong twice over for a path in
# the ssh user's own home: on a host where the login user has no passwordless
# sudo the write simply FAILS (measured on mini, 2026-08-10 — the console's
# read token could not be delivered), and where sudo DOES work it produces a
# root-owned 0600 file that the service running as that user cannot read.
# A `~`-relative path is BY DEFINITION the login user's own file: write it as
# that user, no sudo, and read it back the same way.
_rotate_homefile() { # host= @file target under the remote user's home
  yq e -i '.secrets[0].stored_in = ["host=stubbox:~/.config/nwp-console/gitlab.token:@file"]' \
    "$NWP_SECRETS_REGISTRY"
  pty_run 'PLACEHOLDER_canonical_value_A
2030-01-01
' "env NWP_ROOT='$NWP_ROOT' HOME='$HOME' PATH='$PATH' \
        NWP_SECRETS_FILE='$NWP_SECRETS_FILE' NWP_SECRETS_REGISTRY='$NWP_SECRETS_REGISTRY' \
        NWP_LEAK_SURFACES='$NWP_LEAK_SURFACES' FAKE_CURL_ALIVE='$FAKE_CURL_ALIVE' \
        SSH_STUB_LOG='$SSH_STUB_LOG' SSH_STUB_CAP='$SSH_STUB_CAP' SSH_STUB_MODE='$SSH_STUB_MODE' \
        bash '$SECRETS_SH' rotate fixture_token"
}

@test "home-path: a ~ target is written as the LOGIN USER — no sudo in the command" {
  _arm_ssh_stub ok
  _rotate_homefile
  [ -f "$SSH_STUB_CAP" ]
  [ "$(head -1 "$SSH_STUB_CAP")" = "PLACEHOLDER_canonical_value_A" ]
  # the whole point: a home path must not be handed to sudo
  ! grep -q 'sudo' "$SSH_STUB_LOG"
  ! grep -q -- '-o root' "$SSH_STUB_LOG"
}

@test "home-path: the read-back is ALSO unprivileged (a root-only read would lie)" {
  _arm_ssh_stub ok
  _rotate_homefile
  run grep -c 'sha256sum' "$SSH_STUB_LOG"
  [ "$output" -ge 1 ]
  ! grep -E 'sudo -n (head|cat)' "$SSH_STUB_LOG"
}

@test "home-path: a verified home write STAMPS the registry" {
  _arm_ssh_stub ok
  _rotate_homefile
  [ "$(stamped)" = "$(date +%F)" ]
}

@test "system-path: a NON-home target still uses sudo (no privilege regression)" {
  _arm_ssh_stub ok
  _rotate_hostfile
  grep -q 'sudo -n install' "$SSH_STUB_LOG"
  grep -q -- '-o root -g root' "$SSH_STUB_LOG"
}

@test "home-path: a FAILED home write still blocks the stamp" {
  _arm_ssh_stub writefail
  _rotate_homefile || true
  [ "$(stamped)" = "2026-01-01" ]
}
