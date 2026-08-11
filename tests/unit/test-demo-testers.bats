#!/usr/bin/env bats
# ops#328 tranche 3 — `pl demo testers <site> list|set-guild|set-level`.
#
# The pl-first wrapper the console's per-tester editor calls: reads
# `drush nwc:tester-list --format=json`, writes through
# `drush nwc:tester-set-guild` / `drush nwc:tester-set-level` — never raw ssh.
# The drush transport is the REAL tier path (demo_drush → `ddev drush` at
# dev; demo_rdrush at live); these tests stand up a stub `ddev` binary the
# way the delivery fixture does, so the wrapper's own plumbing is exercised,
# not switched off.
#
# What is pinned here:
#   * writes name their tier explicitly (the ops#225/#173 rule);
#   * writes REFUSE unless the target site reports demo_mode=true — the
#     pl-layer half of the fence (the drush command's account fence is the
#     other half); an unreadable demo_mode refuses too (fail toward the
#     fence);
#   * --allow-real is NEVER forwarded — the wrapper refuses it by name;
#   * a missing drush command (not deployed yet) is exit 2 with a
#     not_deployed JSON document naming the fix, never error soup;
#   * a failed transport is exit 2 CANNOT VERIFY, never an empty roster;
#   * argument shapes are validated before anything is executed.

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}/sites/demo1"
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  source "${REPO_ROOT}/lib/demo.sh"
  DEMO_CMD="${REPO_ROOT}/scripts/commands/demo.sh"
  export NWP_DEMO_REGISTRY_HOME_FILE="${TEST_TMP}/registry-home.yml"
  printf 'registry_home: %s\n' "$(hostname -s)" > "$NWP_DEMO_REGISTRY_HOME_FILE"
}

teardown() {
  rm -rf "${TEST_TMP}"
  unset PROJECT_ROOT
  unset NWP_DEMO_REGISTRY_HOME_FILE
}

# A DDEV project + a stub `ddev` that answers exactly the drush surface the
# testers verb uses. Behaviour is steered by files in $TEST_TMP:
#   demo_mode     — what `cget nwc_demo_access.settings demo_mode` returns
#   tester_json   — what nwc:tester-* emit
#   drush_rc      — exit code for the nwc:tester-* calls
#   not_defined   — if present, nwc:tester-* answer like an undeployed drush
# Every nwc:tester-* invocation is appended to $TEST_TMP/drush_calls.
testers_fixture() {
  mkdir -p "${PROJECT_ROOT}/sites/demo1/.ddev" "${TEST_TMP}/bin"
  printf 'docroot: web\n' > "${PROJECT_ROOT}/sites/demo1/.ddev/config.yaml"
  printf 'true\n' > "${TEST_TMP}/demo_mode"
  printf '{"ok": true, "accounts": [], "counts": {}}\n' > "${TEST_TMP}/tester_json"
  printf '0\n' > "${TEST_TMP}/drush_rc"
  cat > "${TEST_TMP}/bin/ddev" <<STUB
#!/bin/bash
T="${TEST_TMP}"
[ "\$1" = "drush" ] || exit 1
shift
case "\$1" in
  cget)
    cat "\$T/demo_mode" 2>/dev/null || true
    exit 0 ;;
  nwc:tester-list|nwc:tester-set-guild|nwc:tester-set-level)
    echo "\$@" >> "\$T/drush_calls"
    if [ -e "\$T/not_defined" ]; then
      echo "In Application.php line 651:" >&2
      echo "  Command \"\$1\" is not defined." >&2
      exit 1
    fi
    cat "\$T/tester_json"
    exit "\$(cat "\$T/drush_rc")" ;;
  state:get) echo '{"version":1,"codes":[]}'; exit 0 ;;
esac
exit 1
STUB
  chmod +x "${TEST_TMP}/bin/ddev"
  export PATH="${TEST_TMP}/bin:$PATH"
}

# --- dispatch ----------------------------------------------------------------

@test "t3: 'pl demo testers' is a real subcommand (help names it)" {
  run bash "$DEMO_CMD" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"testers"* ]]
}

@test "t3: unknown testers action is refused" {
  testers_fixture
  run bash "$DEMO_CMD" testers demo1 frobnicate --tier=dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown testers action"* ]]
}

# --- list --------------------------------------------------------------------

@test "t3: list --json passes the drush roster through and asks for --format=json" {
  testers_fixture
  printf '{"ok": true, "accounts": [{"uid": 12}], "counts": {"fenced_active": 1}}\n' > "${TEST_TMP}/tester_json"
  run bash "$DEMO_CMD" testers demo1 list --json --tier=dev
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true and .accounts[0].uid == 12'
  grep -q 'nwc:tester-list --format=json' "${TEST_TMP}/drush_calls"
}

@test "t3: list --json with a failing drush is exit 2 CANNOT VERIFY, never empty" {
  testers_fixture
  printf 'some transport error\n' > "${TEST_TMP}/tester_json"
  printf '3\n' > "${TEST_TMP}/drush_rc"
  run bash "$DEMO_CMD" testers demo1 list --json --tier=dev
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.ok == false'
  echo "$output" | jq -e '.reason | test("CANNOT VERIFY")'
}

@test "t3: an undeployed drush command is exit 2 with not_deployed + the deploy hint" {
  testers_fixture
  : > "${TEST_TMP}/not_defined"
  run bash "$DEMO_CMD" testers demo1 list --json --tier=dev
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.ok == false and .not_deployed == true'
  echo "$output" | jq -e '.reason | test("merge \\+ deploy")'
}

# --- write guards ------------------------------------------------------------

@test "t3: set-guild without an explicit tier is REFUSED before anything runs" {
  testers_fixture
  run bash "$DEMO_CMD" testers demo1 set-guild demo_writer writers
  [ "$status" -ne 0 ]
  [[ "$output" == *"must name the tier"* ]]
  [ ! -e "${TEST_TMP}/drush_calls" ]
}

@test "t3: set-guild REFUSES when the site does not report demo_mode=true" {
  testers_fixture
  printf 'false\n' > "${TEST_TMP}/demo_mode"
  run bash "$DEMO_CMD" testers demo1 set-guild demo_writer writers --tier=dev
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'demo_mode'
  [ ! -e "${TEST_TMP}/drush_calls" ]
  # unreadable answers refuse too — fail toward the fence
  printf '\n' > "${TEST_TMP}/demo_mode"
  run bash "$DEMO_CMD" testers demo1 set-guild demo_writer writers --tier=dev
  [ "$status" -ne 0 ]
  [ ! -e "${TEST_TMP}/drush_calls" ]
}

@test "t3: --allow-real is refused BY NAME and never forwarded" {
  testers_fixture
  run bash "$DEMO_CMD" testers demo1 set-guild real_user writers --allow-real --tier=dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"--allow-real"* ]]
  [ ! -e "${TEST_TMP}/drush_calls" ]
}

@test "t3: set-guild forwards account, seed key, --group-role and --format=json" {
  testers_fixture
  printf '{"ok": true, "changed": true, "membership": {"member": true}}\n' > "${TEST_TMP}/tester_json"
  run bash "$DEMO_CMD" testers demo1 set-guild demo_writer writers --group-role=guild-mentor --tier=dev
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true and .changed == true'
  grep -q -- 'nwc:tester-set-guild demo_writer writers --group-role=guild-mentor' "${TEST_TMP}/drush_calls"
}

@test "t3: set-guild --remove forwards --remove" {
  testers_fixture
  printf '{"ok": true, "changed": true, "membership": {"member": false}}\n' > "${TEST_TMP}/tester_json"
  run bash "$DEMO_CMD" testers demo1 set-guild demo_writer writers --remove --tier=dev
  [ "$status" -eq 0 ]
  grep -q -- '--remove' "${TEST_TMP}/drush_calls"
}

@test "t3: a typed drush refusal passes through as exit 1, not error soup" {
  testers_fixture
  printf '{"ok": false, "refused": true, "reason": "no guild-leader role"}\n' > "${TEST_TMP}/tester_json"
  printf '1\n' > "${TEST_TMP}/drush_rc"
  run bash "$DEMO_CMD" testers demo1 set-guild demo_writer writers --group-role=guild-leader --tier=dev
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.refused == true'
  echo "$output" | jq -e '.reason | test("guild-leader")'
}

@test "t3: argument shapes are validated before any drush call" {
  testers_fixture
  # metacharacter account
  run bash "$DEMO_CMD" testers demo1 set-guild 'a;b' writers --tier=dev
  [ "$status" -ne 0 ]
  # label-shaped seed key (spaces/capitals) — seed keys are machine ids
  run bash "$DEMO_CMD" testers demo1 set-guild demo_writer 'Writers Guild' --tier=dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"seed key"* ]]
  # missing args
  run bash "$DEMO_CMD" testers demo1 set-guild demo_writer --tier=dev
  [ "$status" -ne 0 ]
  [ ! -e "${TEST_TMP}/drush_calls" ]
}

# --- set-level ---------------------------------------------------------------

@test "t3: set-level forwards account + integer level" {
  testers_fixture
  printf '{"ok": true, "changed": true, "level_before": 0, "level_after": 2}\n' > "${TEST_TMP}/tester_json"
  run bash "$DEMO_CMD" testers demo1 set-level demo_writer 2 --tier=dev
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.level_after == 2'
  grep -q -- 'nwc:tester-set-level demo_writer 2' "${TEST_TMP}/drush_calls"
}

@test "t3: set-level refuses a non-integer level before any drush call" {
  testers_fixture
  run bash "$DEMO_CMD" testers demo1 set-level demo_writer two --tier=dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"level"* ]]
  [ ! -e "${TEST_TMP}/drush_calls" ]
}

@test "t3: set-level without an explicit tier is REFUSED" {
  testers_fixture
  run bash "$DEMO_CMD" testers demo1 set-level demo_writer 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"must name the tier"* ]]
}

@test "t3: writes are logged to the demo log" {
  testers_fixture
  printf '{"ok": true, "changed": true}\n' > "${TEST_TMP}/tester_json"
  run bash "$DEMO_CMD" testers demo1 set-guild demo_writer writers --tier=dev
  [ "$status" -eq 0 ]
  grep -q 'testers-set-guild' "$(demo_log_file demo1)"
}

@test "t3: demo_rdrush resolves the live context BEFORE interpolating the remote path" {
  # The latent first-call trap this tranche tripped live: demo_rdrush built
  # `cd ${DEMO_LIVE_PATH} && …` while the context was still unresolved, so the
  # FIRST call in a fresh process ran `cd  && ./vendor/bin/drush` in the ssh
  # user's $HOME (rc=127, proven on nwd live 2026-08-09). Every older caller
  # masked it by calling demo_live_ctx explicitly first. Pin the fix
  # functionally: source the command file, stub ctx + transport, and assert
  # the remote command string carries the resolved path on the very first call.
  run bash -c '
    source "'"$DEMO_CMD"'" >/dev/null 2>&1 || true
    demo_live_ctx() { DEMO_LIVE_SITE="$1"; DEMO_LIVE_PATH="/var/www/stub"; DEMO_LIVE_DRUSHSUDO="sudo -u www-data"; }
    demo_rssh()     { shift; printf "%s\n" "$*"; }
    DEMO_LIVE_SITE=""; DEMO_LIVE_PATH=""; DEMO_LIVE_DRUSHSUDO=""
    demo_rdrush demo1 status
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"cd /var/www/stub && sudo -u www-data ./vendor/bin/drush status"* ]]
  [[ "$output" != *"cd  &&"* ]]
}

@test "t3: --tier=prod stays refused (demo_check_tier)" {
  testers_fixture
  run bash "$DEMO_CMD" testers demo1 list --tier=prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
}

################################################################################
# ops#328 t4 — `pl demo testers <site> login <account>`: sign in AS a tester
#
# The demo personas have no passwords (nwc:seed-demo mints them; nobody ever
# set one), so the only way to see the site through a tester's eyes is a
# one-time login link. Two traps, both verified live on nwd before this verb
# existed, and both guarded here:
#
#   1. --uri is REQUIRED. Without it drush mints http://default/user/reset/…,
#      a link that goes nowhere. The verb resolves the site's own base URL and
#      refuses if it cannot — it never calls user:login without one.
#   2. THE POSITIONAL ARGUMENT IS A PATH, NOT A USERNAME. `drush user:login
#      <name>` puts the name in the `path` slot, falls through to
#      User::load(1), and returns an ADMIN link that looks exactly like a
#      persona link. The verb passes --name=, and then PROVES the returned
#      link belongs to the expected uid by reading the uid out of
#      /user/reset/<uid>/… — a mismatch DISCARDS the link unprinted.
#
# The link is a CREDENTIAL: it is rendered once on stdout, is never written to
# the demo log, and never appears in a refusal document or a raw-output tail.
################################################################################

# Extends testers_fixture's stub with the drush user:login surface. Steered by:
#   login_link  — what user:login prints (default: a well-formed link for uid 12)
#   login_rc    — its exit code
_login_fixture() {
  testers_fixture
  cat > "${TEST_TMP}/tester_json" <<'JSON'
{"ok": true,
 "counts": {"fenced_active": 2, "fenced_blocked": 0, "real_active": 1, "real_blocked": 0},
 "accounts": [
   {"uid": 12, "name": "demo_writer", "mail": "demo_writer@demo.invalid",
    "active": true, "fence": "persona", "guilds": [], "roles": []},
   {"uid": 13, "name": "demo_blocked", "mail": "demo_blocked@demo.invalid",
    "active": false, "fence": "persona", "guilds": [], "roles": []},
   {"uid": 1, "name": "trap_admin", "mail": "trap_admin@demo.invalid",
    "active": true, "fence": "persona", "guilds": [], "roles": []}
 ]}
JSON
  printf 'https://demo1-dev.ddev.site/user/reset/12/1786000000/AbCdEf/login\n' > "${TEST_TMP}/login_link"
  printf '0\n' > "${TEST_TMP}/login_rc"
  cat > "${TEST_TMP}/bin/ddev" <<STUB
#!/bin/bash
T="${TEST_TMP}"
[ "\$1" = "drush" ] || exit 1
shift
case "\$1" in
  cget)
    cat "\$T/demo_mode" 2>/dev/null || true
    exit 0 ;;
  user:login)
    echo "\$@" >> "\$T/drush_calls"
    cat "\$T/login_link"
    exit "\$(cat "\$T/login_rc")" ;;
  nwc:tester-list|nwc:tester-set-guild|nwc:tester-set-level)
    echo "\$@" >> "\$T/drush_calls"
    if [ -e "\$T/not_defined" ]; then
      echo "  Command \"\$1\" is not defined." >&2
      exit 1
    fi
    cat "\$T/tester_json"
    exit "\$(cat "\$T/drush_rc")" ;;
  state:get) echo '{"version":1,"codes":[]}'; exit 0 ;;
esac
exit 1
STUB
  chmod +x "${TEST_TMP}/bin/ddev"
}

# bats `run` merges stdout and stderr, and every wrapper refusal prints a human
# line to stderr BEFORE its JSON document (deliberately: an operator at a
# terminal should not have to read JSON). Pull the document back out.
_json() { printf '%s\n' "$output" | sed -n '/^{/,$p'; }

@test "t4 login: mints a one-time link for a fenced tester and passes --name= AND --uri=" {
  _login_fixture
  run bash "$DEMO_CMD" testers demo1 login demo_writer --json --tier=dev
  [ "$status" -eq 0 ]
  _json | jq -e '.ok == true and .account == "demo_writer" and .uid == 12'
  _json | jq -e '.url | test("/user/reset/12/")'
  # the two traps, pinned at the call site
  grep -q 'user:login --name=demo_writer' "${TEST_TMP}/drush_calls"
  grep -q -- '--uri=https://demo1-dev.ddev.site' "${TEST_TMP}/drush_calls"
  # the account is NEVER in the positional slot (that slot is a PATH)
  ! grep -qE 'user:login (--[^ ]+ )*demo_writer( |$)' "${TEST_TMP}/drush_calls"
}

@test "t4 login: the ADMIN-LINK TRAP is unreachable — a uid-1 link is DISCARDED, never printed" {
  _login_fixture
  # drush answers with a uid-1 link (exactly what the positional-name mistake
  # produces) while we asked for uid 12.
  printf 'https://demo1-dev.ddev.site/user/reset/1/1786000000/RootHash/login\n' > "${TEST_TMP}/login_link"
  run bash "$DEMO_CMD" testers demo1 login demo_writer --json --tier=dev
  [ "$status" -ne 0 ]
  _json | jq -e '.ok == false and .refused == true'
  _json | jq -e '.reason | test("uid 1")'
  # THE LINK ITSELF MUST NOT APPEAR ANYWHERE IN THE REFUSAL
  ! [[ "$output" == *"RootHash"* ]]
  ! [[ "$output" == *"/user/reset/1/"* ]]
}

@test "t4 login: uid<=1 is refused ALWAYS, before any link is minted" {
  _login_fixture
  run bash "$DEMO_CMD" testers demo1 login trap_admin --json --tier=dev
  [ "$status" -ne 0 ]
  _json | jq -e '.ok == false and .refused == true'
  _json | jq -e '.reason | test("uid")'
  ! grep -q 'user:login' "${TEST_TMP}/drush_calls"
}

@test "t4 login: an account off the @demo.invalid fence is refused (--allow-real is not forwardable)" {
  _login_fixture
  cat > "${TEST_TMP}/tester_json" <<'JSON'
{"ok": true, "counts": {},
 "accounts": [{"uid": 42, "name": "realperson", "mail": "real@example.org",
               "active": true, "fence": "none", "guilds": [], "roles": []}]}
JSON
  run bash "$DEMO_CMD" testers demo1 login realperson --json --tier=dev
  [ "$status" -ne 0 ]
  _json | jq -e '.refused == true'
  _json | jq -e '.reason | test("fence")'
  ! grep -q 'user:login' "${TEST_TMP}/drush_calls"
  # and the wrapper still refuses --allow-real by name
  run bash "$DEMO_CMD" testers demo1 login realperson --allow-real --json --tier=dev
  [ "$status" -ne 0 ]
  _json | jq -e '.reason | test("allow-real")'
}

@test "t4 login: an account that is not in the roster is refused, not guessed at" {
  _login_fixture
  run bash "$DEMO_CMD" testers demo1 login nobody_here --json --tier=dev
  [ "$status" -ne 0 ]
  _json | jq -e '.refused == true'
  _json | jq -e '.reason | test("roster")'
  ! grep -q 'user:login' "${TEST_TMP}/drush_calls"
}

@test "t4 login: a blocked tester is refused with a reason (drush would throw)" {
  _login_fixture
  run bash "$DEMO_CMD" testers demo1 login demo_blocked --json --tier=dev
  [ "$status" -ne 0 ]
  _json | jq -e '.reason | test("blocked")'
  ! grep -q 'user:login' "${TEST_TMP}/drush_calls"
}

@test "t4 login: an unreadable roster is exit 2 CANNOT VERIFY — it never proceeds blind" {
  _login_fixture
  printf 'transport exploded\n' > "${TEST_TMP}/tester_json"
  printf '3\n' > "${TEST_TMP}/drush_rc"
  run bash "$DEMO_CMD" testers demo1 login demo_writer --json --tier=dev
  [ "$status" -eq 2 ]
  _json | jq -e '.ok == false'
  ! grep -q 'user:login' "${TEST_TMP}/drush_calls"
}

@test "t4 login: a link on the WRONG origin (http://default — the missing --uri symptom) is discarded" {
  _login_fixture
  printf 'http://default/user/reset/12/1786000000/AbCdEf/login\n' > "${TEST_TMP}/login_link"
  run bash "$DEMO_CMD" testers demo1 login demo_writer --json --tier=dev
  [ "$status" -ne 0 ]
  _json | jq -e '.ok == false'
  ! [[ "$output" == *"AbCdEf"* ]]
}

@test "t4 login: the one-time link is NEVER written to the demo log" {
  _login_fixture
  run bash "$DEMO_CMD" testers demo1 login demo_writer --json --tier=dev
  [ "$status" -eq 0 ]
  grep -q 'tester-login' "$(demo_log_file demo1)"
  grep -q 'acct=demo_writer' "$(demo_log_file demo1)"
  ! grep -q '/user/reset/' "$(demo_log_file demo1)"
  ! grep -q 'AbCdEf' "$(demo_log_file demo1)"
}

@test "t4 login: writes name their tier (login mints a credential against a running site)" {
  _login_fixture
  run bash "$DEMO_CMD" testers demo1 login demo_writer --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"must name the tier"* ]]
}

@test "t4 login: refuses when demo_mode is not true (fails toward the fence)" {
  _login_fixture
  printf 'false\n' > "${TEST_TMP}/demo_mode"
  run bash "$DEMO_CMD" testers demo1 login demo_writer --json --tier=dev
  [ "$status" -ne 0 ]
  _json | jq -e '.refused == true'
  _json | jq -e '.reason | test("demo_mode")'
  ! grep -q 'user:login' "${TEST_TMP}/drush_calls"
}
