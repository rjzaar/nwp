#!/usr/bin/env bats
# pl ver-test — the pl-driven ver DR test harness (task #11; ops#25 + ops#127).
#
# The live cycle (2 throwaway Linodes running the full raw+sanitised → pull →
# restore-drill chain) is proven by ACTUALLY RUNNING it (see
# docs/reports/consolidation-arc-2026-07/ver-harness-run-2026-07-25.md), not by
# mocks. These tests pin the cheap, load-bearing invariants of the command
# surface: dispatch, fail-closed token handling, and the teardown-tracking
# (disposable-ledger) writes — in the style of the repo's other static bats.

VER_TEST_SH="${BATS_TEST_DIRNAME}/../../scripts/commands/ver-test.sh"
PL="${BATS_TEST_DIRNAME}/../../pl"

setup() {
  TEST_TMP=$(mktemp -d)
}

teardown() {
  rm -rf "${TEST_TMP}"
}

# Source the script with the dispatch guard active (functions only), inside a
# `run`-spawned bash so the caller's shell is never polluted.
harness_call() { # $1 = snippet to eval after sourcing
  VERTEST_STATE_DIR="$TEST_TMP/state" VERTEST_LEDGER="$TEST_TMP/LEDGER.md" \
    bash -c "source '$VER_TEST_SH'; $1"
}

################################################################################
# Command surface / dispatch
################################################################################

@test "script parses (bash -n)" {
  run bash -n "$VER_TEST_SH"
  [ "$status" -eq 0 ]
}

@test "--help documents all subcommands and the harness deltas" {
  run bash "$VER_TEST_SH" --help
  [ "$status" -eq 0 ]
  for sub in provision provision-prod cycle teardown status; do
    [[ "$output" == *"$sub"* ]]
  done
  [[ "$output" == *"HARNESS DELTAS"* ]]
  [[ "$output" == *"WireGuard"* ]]
  [[ "$output" == *"arc-disposable"* ]]
}

@test "no subcommand → usage + non-zero (fail-closed, nothing implicit)" {
  run bash "$VER_TEST_SH"
  [ "$status" -ne 0 ]
}

@test "unknown subcommand is rejected" {
  run bash "$VER_TEST_SH" frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown subcommand"* ]]
}

@test "pl dispatches ver-test to the harness" {
  grep -Eq 'ver-test\)' "$PL"
  grep -q 'run_script "ver-test.sh"' "$PL"
}

################################################################################
# Fail-closed token handling
################################################################################

@test "require_token fails closed when no token is resolvable" {
  # Neuter both sources: the env override and the .secrets.yml reader.
  run harness_call 'get_infra_secret(){ echo ""; }; NWP_VERTEST_LINODE_TOKEN=""; require_token'
  [ "$status" -ne 0 ]
  [[ "$output" == *"fail-closed"* ]]
  [[ "$output" == *"linode.provision_token"* ]]
}

@test "require_token writes the token ONLY into a 0600 curl config" {
  run harness_call 'NWP_VERTEST_LINODE_TOKEN="tok-bats-$$"; require_token;
                    stat -c %a "$STATE_DIR/api.curlcfg";
                    grep -c "Authorization: Bearer" "$STATE_DIR/api.curlcfg"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"600"* ]]
  [[ "$output" == *"1"* ]]
}

@test "token never rides on curl argv (0600 config pattern only)" {
  # every curl in the script must use -K; no Authorization header on argv
  ! grep -E 'curl .*Authorization' "$VER_TEST_SH"
  ! grep -E 'curl (?!.*-K)' "$VER_TEST_SH" 2>/dev/null || true
  # (bash grep has no lookahead — assert the positive form instead)
  [ "$(grep -cE '^\s*curl ' "$VER_TEST_SH")" -eq "$(grep -cE '^\s*curl .*(-K|"\$\{args\[@\]\}")' "$VER_TEST_SH")" ]
}

################################################################################
# Teardown-tracking (disposable-ledger) writes
################################################################################

@test "record_created writes state files AND the ledger entry immediately" {
  run harness_call 'mkdir -p "$STATE_DIR"; record_created ver 424242 192.0.2.10 nwp-vertest-ver-bats;
                    cat "$STATE_DIR/ver.id" "$STATE_DIR/ver.ip"; cat "$LEDGER"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"424242"* ]]
  [[ "$output" == *"192.0.2.10"* ]]
  [[ "$output" == *"ACTIVE until torn down"* ]]
  [[ "$output" == *"arc-disposable,ver-harness"* ]]
  [[ "$output" == *"pl ver-test teardown"* ]]
}

@test "record_torndown appends the verified-gone line to the ledger" {
  run harness_call 'mkdir -p "$STATE_DIR"; record_torndown ver 424242 200 404; cat "$LEDGER"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"TORN DOWN"* ]]
  [[ "$output" == *"424242"* ]]
  [[ "$output" == *"DELETE HTTP 200"* ]]
  [[ "$output" == *"404"* ]]
}

@test "teardown with no recorded instances is a clean no-op (nothing to orphan)" {
  run harness_call 'NWP_VERTEST_LINODE_TOKEN="tok-bats-$$"; do_teardown'
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to tear down"* ]]
}

################################################################################
# Static invariants (fire only on a live run; pinned as text, house style)
################################################################################

@test "instances are created with the arc-disposable + ver-harness tags" {
  grep -q '"arc-disposable","ver-harness"' "$VER_TEST_SH"
}

@test "create path records the ledger BEFORE waiting on boot/ssh" {
  # record_created must appear before the running/ssh waits inside create_instance
  awk '/^create_instance\(\)/,/^}/' "$VER_TEST_SH" \
    | grep -n 'record_created\|wait_ssh' \
    | head -2 | paste -sd' ' - | grep -q 'record_created.*wait_ssh'
}

@test "cycle asserts the ops#127 retention split (raw ceiling vs sanitised tiers)" {
  grep -q 'keep-within 30d' "$VER_TEST_SH"
  grep -q 'Retention (d:7 w:8 m:12)' "$VER_TEST_SH"
}

@test "cycle drills BOTH gate directions (sanitised passes, raw must fail rc=1)" {
  grep -q 'GATE_SANITIZED_WITH_ALLOW rc=0' "$VER_TEST_SH"
  grep -q 'GATE_RAW rc=1' "$VER_TEST_SH"
}

@test "teardown verifies deletion via GET 404 and sweeps residual tagged instances" {
  awk '/^do_teardown\(\)/,/^}/' "$VER_TEST_SH" | grep -q '404'
  awk '/^do_teardown\(\)/,/^}/' "$VER_TEST_SH" | grep -q 'ver-harness'
}

@test "fixture identities exercise the gate for real (non-allowlisted domains)" {
  # admin + members must NOT be on the pii-gate allowlist (example.com/nwpcode.org
  # would silently pass and prove nothing)
  grep -q 'ADMIN_MAIL="admin@vertest-harness.org"' "$VER_TEST_SH"
  grep -q 'MEMBER_DOMAIN="harness-member.net"' "$VER_TEST_SH"
  ! grep -E 'ADMIN_MAIL=.*(example\.(com|org|net)|nwpcode\.org)' "$VER_TEST_SH"
}

################################################################################
# ops#47 impact contract — teardown DESTROYS Linodes (instance + disks, no
# backups). Disposable-by-design is why the answer is usually yes; it is not a
# reason to skip the question. The API is stubbed: no network, no spend.
################################################################################

# A recorded instance + a stubbed Linode API that answers for it.
_stub_api='api(){ printf "%s" "{\"id\":424242,\"label\":\"nwp-vertest-ver-bats\",\"status\":\"running\",\"ipv4\":[\"192.0.2.10\"],\"type\":\"g6-standard-2\",\"region\":\"us-iad-2\",\"data\":[]}"; };
           api_code(){ if [ "$1" = DELETE ]; then echo 200; else echo 404; fi; };
           mkdir -p "$STATE_DIR"; record_created ver 424242 192.0.2.10 nwp-vertest-ver-bats >/dev/null;'

@test "teardown names every instance it is about to destroy (fate manifest)" {
  run harness_call "NWP_VERTEST_LINODE_TOKEN=tok-bats; $_stub_api ASSUME_YES=true; do_teardown"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WILL BE PERMANENTLY DELETED"* ]]
  [[ "$output" == *"424242"* ]]
  [[ "$output" == *"nwp-vertest-ver-bats"* ]]
  [[ "$output" == *"g6-standard-2"* ]]
  [[ "$output" == *"us-iad-2"* ]]
  [[ "$output" == *"no snapshot or backup exists"* ]]
  # -y skipped the prompt, not the report: it really did tear down
  [[ "$output" == *"confirmed GONE"* ]]
}

@test "teardown without -y and without a TTY refuses — nothing is destroyed" {
  run harness_call "NWP_VERTEST_LINODE_TOKEN=tok-bats; $_stub_api ASSUME_YES=false;
                    do_teardown || true; echo \"STILL_RECORDED=\$(cat \"\$STATE_DIR/ver.id\")\""
  [[ "$output" == *"WILL BE PERMANENTLY DELETED"* ]]
  [[ "$output" == *"No terminal available"* ]]
  [[ "$output" == *"Teardown cancelled"* ]]
  [[ "$output" != *"confirmed GONE"* ]]
  [[ "$output" == *"STILL_RECORDED=424242"* ]]
}

@test "the manifest flags ver-harness instances that are NOT ours to destroy" {
  local stub='api(){ if [ "$2" = "/linode/instances" ]; then
                       printf "%s" "{\"data\":[{\"id\":999111,\"tags\":[\"ver-harness\"]}]}";
                     else
                       printf "%s" "{\"id\":424242,\"label\":\"nwp-vertest-ver-bats\",\"status\":\"running\",\"ipv4\":[\"192.0.2.10\"],\"type\":\"g6-standard-2\",\"region\":\"us-iad-2\"}";
                     fi; };
              api_code(){ if [ "$1" = DELETE ]; then echo 200; else echo 404; fi; };
              mkdir -p "$STATE_DIR"; record_created ver 424242 192.0.2.10 nwp-vertest-ver-bats >/dev/null;'
  run harness_call "NWP_VERTEST_LINODE_TOKEN=tok-bats; $stub ASSUME_YES=true; do_teardown || true"
  [[ "$output" == *"NOT on record here: 999111"* ]]
}

@test "teardown adopts lib/impact.sh rather than hand-rolling a prompt" {
  grep -q 'lib/impact.sh' "$VER_TEST_SH"
  awk '/^do_teardown\(\)/,/^}/' "$VER_TEST_SH" | grep -q 'impact_render'
  awk '/^do_teardown\(\)/,/^}/' "$VER_TEST_SH" | grep -q 'impact_confirm standard'
  # the report is built before the first DELETE
  render=$(grep -n 'impact_render' "$VER_TEST_SH" | head -1 | cut -d: -f1)
  del=$(grep -n 'api_code DELETE' "$VER_TEST_SH" | head -1 | cut -d: -f1)
  [ "$render" -lt "$del" ]
}
