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

@test "enroll prints the headscale runbook without touching the network" {
  run "$CONSOLE_SH" enroll
  [ "$status" -eq 0 ]
  [[ "$output" == *preauthkeys* ]]
  [[ "$output" == *"control server"* ]]
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
