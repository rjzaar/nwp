#!/usr/bin/env bats
# NWP Console — pl console dispatch + guard tests (no network, no deploy host).

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
  CONSOLE_SH="$REPO_ROOT/scripts/commands/console.sh"
}

@test "console.sh passes bash -n" {
  bash -n "$CONSOLE_SH"
}

@test "console.sh is executable" {
  [ -x "$CONSOLE_SH" ]
}

@test "help exits 0 and mentions subcommands" {
  run "$CONSOLE_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *deploy* ]]
  [[ "$output" == *"user add"* ]]
  [[ "$output" == *enroll* ]]
}

@test "no arguments shows help (exit 0)" {
  run "$CONSOLE_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *USAGE* ]]
}

@test "unknown subcommand fails" {
  run "$CONSOLE_SH" frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown subcommand"* ]]
}

@test "enroll --runbook prints the steps without touching the network" {
  # Bare `enroll` now MINTS a key (it ssh's the control-plane host), so the
  # offline contract moved to --runbook. Keeping an offline path matters: it is
  # what you read when the mesh is the thing that is broken.
  run "$CONSOLE_SH" enroll --runbook
  [ "$status" -eq 0 ]
  [[ "$output" == *preauthkeys* ]]
  [[ "$output" == *"CONTROL SERVER"* ]]
}

@test "enroll rejects a malformed --expiry before going near ssh" {
  run "$CONSOLE_SH" enroll --expiry forever
  [ "$status" -ne 0 ]
  [[ "$output" == *"duration like"* ]]
}

@test "enroll reads the headscale host from its OWN setting, not the console host" {
  # 2026-08-01: the runbook told the operator to ssh the CONSOLE host for
  # headscale. The console runs on a keyless dev-tier box precisely so that a
  # public control endpoint is not on it — the two are different machines and
  # the config has to say so.
  grep -q 'HEADSCALE_HOST=' "$CONSOLE_SH"
  grep -q '_console_cfg headscale_host' "$CONSOLE_SH"
  run bash -c "grep -A4 'minting a' '$CONSOLE_SH' | grep -c 'CONSOLE_HOST'"
  [ "$output" = "0" ]
}

@test "enroll falls back to the manual runbook when the control host is unset" {
  NWP_CONSOLE_HEADSCALE_HOST= NWP_CONSOLE_HEADSCALE_USER= \
    NWP_CONSOLE_CONFIG=/nonexistent HOME=/nonexistent run "$CONSOLE_SH" enroll
  [ "$status" -ne 0 ]
  [[ "$output" == *"headscale_host"* ]]
  [[ "$output" == *preauthkeys* ]]
}

@test "network verbs fail closed when settings.console is unconfigured" {
  # Force the placeholder chain (no nwp.yml anywhere).
  NWP_CONSOLE_CONFIG=/nonexistent HOME=/nonexistent run "$CONSOLE_SH" status
  [ "$status" -ne 0 ]
  [[ "$output" == *"settings.console is not configured"* ]]
}

@test "user add rejects invalid username locally (no ssh attempted)" {
  run "$CONSOLE_SH" user add 'bad name;rm' --role viewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid username"* ]]
}

@test "user add rejects invalid role locally" {
  run "$CONSOLE_SH" user add gooduser --role admin
  [ "$status" -ne 0 ]
  [[ "$output" == *"role must be"* ]]
}

@test "user role rejects bad role locally" {
  run "$CONSOLE_SH" user role gooduser superuser
  [ "$status" -ne 0 ]
  [[ "$output" == *"role must be"* ]]
}

@test "pl dispatches console" {
  run "$REPO_ROOT/pl" console --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"pl console"* ]]
}

@test "console python sources are syntax-clean" {
  run python3 -m py_compile \
    "$REPO_ROOT"/scripts/console/app/*.py
  [ "$status" -eq 0 ]
}

@test "action allowlist (ACTIONS map) contains no live/prod verbs" {
  # Inspect only the ACTIONS map (the FORBIDDEN_VERBS blocklist legitimately
  # names these verbs earlier in the file).
  run bash -c "awk '/^ACTIONS: dict/,0' '$REPO_ROOT/scripts/console/app/actions.py' \
    | grep -E '\"(stg2live|live2prod|stg2prod|deploy-gate|server-apply|rollback|restore|live)\"'"
  [ "$status" -ne 0 ]
}

################################################################################
# ops#47 impact contract — `deploy` rsyncs with --delete, so it must print a
# COMPUTED fate manifest before the first byte moves. ssh/rsync/curl are
# stubbed on PATH: no network, no console host, and the stub records whether
# the REAL transfer ever ran.
################################################################################

_stub_bin() {   # writes ssh/rsync/curl stubs into $1; rsync prints an itemized plan
  local bin="$1"
  cat > "$bin/ssh" <<'EOF'
#!/bin/bash
exit 0
EOF
  cat > "$bin/rsync" <<EOF
#!/bin/bash
for a in "\$@"; do [ "\$a" = "--dry-run" ] && dry=1; done
if [ -n "\${dry:-}" ]; then
  printf '%s\n' '*deleting   app/only_on_host.py' \\
                '<f+++++++++ app/brand_new.py' \\
                '<f.st...... app/main.py' \\
                'cd+++++++++ app/'
  exit 0
fi
touch "$bin/REAL_RSYNC_RAN"
EOF
  cat > "$bin/curl" <<'EOF'
#!/bin/bash
exit 1
EOF
  chmod +x "$bin/ssh" "$bin/rsync" "$bin/curl"
}

@test "deploy --dry-run renders the fate manifest rsync itself computed, and writes nothing" {
  BIN=$(mktemp -d); _stub_bin "$BIN"
  PATH="$BIN:$PATH" NWP_CONSOLE_CONFIG=/nonexistent \
    NWP_CONSOLE_FQDN=console.test.invalid NWP_CONSOLE_HOST=stub-host \
    run "$CONSOLE_SH" deploy --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"WILL BE PERMANENTLY DELETED"* ]]
  [[ "$output" == *"only_on_host.py"* ]]
  [[ "$output" == *"WILL BE OVERWRITTEN"* ]]
  [[ "$output" == *"main.py"* ]]
  [[ "$output" == *"dry-run"* ]]
  # the real transfer must NOT have run
  [ ! -f "$BIN/REAL_RSYNC_RAN" ]
  rm -rf "$BIN"
}

@test "a deploy that would delete host-only files fails closed without a TTY (no -y)" {
  BIN=$(mktemp -d); _stub_bin "$BIN"
  PATH="$BIN:$PATH" NWP_CONSOLE_CONFIG=/nonexistent \
    NWP_CONSOLE_FQDN=console.test.invalid NWP_CONSOLE_HOST=stub-host \
    run "$CONSOLE_SH" deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"WILL BE PERMANENTLY DELETED"* ]]
  [[ "$output" == *"No terminal available"* ]]
  [ ! -f "$BIN/REAL_RSYNC_RAN" ]
  rm -rf "$BIN"
}

@test "-y skips the PROMPT, never the REPORT (manifest still printed, deploy proceeds)" {
  BIN=$(mktemp -d); _stub_bin "$BIN"
  PATH="$BIN:$PATH" NWP_CONSOLE_CONFIG=/nonexistent \
    NWP_CONSOLE_FQDN=console.test.invalid NWP_CONSOLE_HOST=stub-host \
    run "$CONSOLE_SH" deploy -y --no-restart
  [[ "$output" == *"WILL BE PERMANENTLY DELETED"* ]]
  [[ "$output" == *"only_on_host.py"* ]]
  [ -f "$BIN/REAL_RSYNC_RAN" ]
  rm -rf "$BIN"
}

@test "deploy REFUSES when the plan cannot be computed (never ships blind)" {
  BIN=$(mktemp -d); _stub_bin "$BIN"
  cat > "$BIN/rsync" <<EOF
#!/bin/bash
for a in "\$@"; do [ "\$a" = "--dry-run" ] && { echo "ssh: connect to host stub-host port 22: No route to host" >&2; exit 255; }; done
touch "$BIN/REAL_RSYNC_RAN"
EOF
  chmod +x "$BIN/rsync"
  PATH="$BIN:$PATH" NWP_CONSOLE_CONFIG=/nonexistent \
    NWP_CONSOLE_FQDN=console.test.invalid NWP_CONSOLE_HOST=stub-host \
    run "$CONSOLE_SH" deploy -y
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSING to deploy blind"* ]]
  [ ! -f "$BIN/REAL_RSYNC_RAN" ]
  rm -rf "$BIN"
}

@test "the dry run and the real transfer are ONE definition (they cannot drift)" {
  # exactly one 'rsync -az --delete' in the file, inside _console_rsync
  [ "$(grep -c 'rsync -az --delete' "$CONSOLE_SH")" -eq 1 ]
  grep -A3 '^_console_rsync()' "$CONSOLE_SH" | grep -q 'rsync -az --delete'
}

@test "the manifest is built BEFORE the transfer (static ordering)" {
  manifest=$(grep -n '_console_deploy_manifest ||' "$CONSOLE_SH" | head -1 | cut -d: -f1)
  transfer=$(grep -n '^    _console_rsync$' "$CONSOLE_SH" | head -1 | cut -d: -f1)
  [ -n "$manifest" ] && [ -n "$transfer" ]
  [ "$manifest" -lt "$transfer" ]
}

@test "host-only deletions confirm at the TYPED tier (their last copy)" {
  grep -q 'impact_confirm typed "\$CONSOLE_HOST"' "$CONSOLE_SH"
}

@test "--dry-run touches the host at all: not even the mkdir runs before the report" {
  # the manifest must precede every remote write, mkdir included
  manifest=$(grep -n '_console_deploy_manifest ||' "$CONSOLE_SH" | head -1 | cut -d: -f1)
  mkdir_line=$(grep -n "mkdir -p ~/nwp-console/src" "$CONSOLE_SH" | head -1 | cut -d: -f1)
  [ -n "$manifest" ] && [ -n "$mkdir_line" ]
  [ "$manifest" -lt "$mkdir_line" ]
}

# --- passkey enrolment ceremony (user addkey) -------------------------------
# Every assertion below is either a local-input guard (must fail BEFORE any
# ssh) or a static ordering property. Nothing here touches the host.

@test "user addkey rejects an invalid username locally (no ssh attempted)" {
  run "$CONSOLE_SH" user addkey 'bad name;rm'
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid username"* ]]
}

@test "user addkey rejects an unknown flag rather than passing it through" {
  run "$CONSOLE_SH" user addkey rob --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "user addkey rejects a non-numeric or absurdly short --timeout" {
  run "$CONSOLE_SH" user addkey rob --timeout soon
  [ "$status" -ne 0 ]
  [[ "$output" == *"--timeout must be seconds"* ]]
  run "$CONSOLE_SH" user addkey rob --timeout 5
  [ "$status" -ne 0 ]
}

@test "user addkey with no name prints its usage" {
  run "$CONSOLE_SH" user addkey
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: pl console user addkey"* ]]
}

@test "addkey issues the token only AFTER the reachability check" {
  # Burning a single-use token when the mesh is down would leave the operator
  # holding a link they cannot open and a token they cannot re-show.
  health=$(grep -n '_console_health || {' "$CONSOLE_SH" | head -1 | cut -d: -f1)
  issue=$(grep -n 'app.manage user-addkey' "$CONSOLE_SH" | head -1 | cut -d: -f1)
  [ -n "$health" ] && [ -n "$issue" ]
  [ "$health" -lt "$issue" ]
}

@test "addkey waits by polling the host, not by declaring success" {
  # The failure mode this guards: the browser saves a platform passkey instead
  # of using the security key. Only the host's count can tell you.
  grep -q '_enrol_wait' "$CONSOLE_SH"
  grep -q 'ENROLLED' "$CONSOLE_SH"
  grep -q 'still on \$before passkey' "$CONSOLE_SH"
}

@test "help documents addkey and its flags" {
  run "$CONSOLE_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"user addkey"* ]]
  [[ "$output" == *"--no-open"* ]]
}

# --- per-passkey inventory + revoke ----------------------------------------

@test "user keys requires a name and validates it locally" {
  run "$CONSOLE_SH" user keys
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: pl console user keys"* ]]
  run "$CONSOLE_SH" user keys 'Bad;Name'
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid username"* ]]
}

@test "user rmkey demands both a name and a handle, and validates the handle" {
  run "$CONSOLE_SH" user rmkey rob
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: pl console user rmkey"* ]]
  run "$CONSOLE_SH" user rmkey rob 'a b;rm -rf /'
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid handle"* ]]
}

@test "addkey --qr never opens a browser on THIS machine" {
  # The QR exists to enrol a different device; opening the link here would
  # burn the single-use token on the wrong one.
  grep -A2 -- '--qr)' "$CONSOLE_SH" | grep -q 'do_open=0'
}

@test "help documents the passkey inventory verbs" {
  run "$CONSOLE_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"user keys"* ]]
  [[ "$output" == *"user rmkey"* ]]
}
