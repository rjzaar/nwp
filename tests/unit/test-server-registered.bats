#!/usr/bin/env bats
#
# tests/unit/test-server-registered.bats — a host the fleet verbs cannot see.
#
# THE DEFECT THIS GUARDS
# ----------------------
# `pl server health` is the REQUIRED PREFLIGHT before anything heavy on a shared
# box (CLAUDE.md standing order; the rule exists because a heavy op OOM-killed
# the 3.8 GB forge box for 5-8 minutes on 2026-07-25). Its fleet form,
# `pl server health --all`, enumerates through `discover_servers`, which lists
# only directories containing a `.nwp-server.yml`.
#
# On 2026-08-11 `servers/met/` held real captured per-host state — the DR crons,
# the stick-backup cron, the nightly audit, the cpu-freq unit, the host
# inventory — and had NO `.nwp-server.yml`. met runs the CI runner, the backup
# routes, the demo-nightly cron and the toolkit. Consequences, all measured:
#
#     $ pl server list
#     SERVER   SCHEMA  STATUS   IP              CONFIG
#     live     1       current  45.33.76.180    servers/live/.nwp-server.yml
#     nwpcode  1       current  97.107.137.88   servers/nwpcode/.nwp-server.yml
#
#     $ pl server health --all      # -> rc=0, "HEALTHY", TWO hosts measured
#
# The fleet preflight reported a clean fleet having never looked at the busiest
# machine in it. That is worse than a preflight that fails: it is a preflight
# that CANNOT fail for a host it does not know exists — the ops#214 class, with
# the corpus itself as the blind spot.
#
# TWO properties are asserted, each with a negative control so a guard that is
# simply always-red cannot pass this file:
#
#   1. host_check_servers_registered() finds a host that holds private per-host
#      state and has no identity file — and does NOT cry wolf over a directory
#      of purely generic, engine-tracked mechanism, nor over a registered host.
#
#   2. `pl server health --all` never returns 0 while such a host exists. An
#      unmeasured host is not a healthy host; rc=3 UNKNOWN is the estate's
#      "I could not look", and it must name the host.
#
# Everything runs against a fixture NWP_DIR, so nothing here depends on the
# operator's real servers/ tree or reaches any network.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="${BATS_TEST_TMPDIR}"

  # A fixture estate that is a REAL git repo with the engine's own ignore rules
  # for servers/, because "does this host hold private state?" is defined by
  # `git check-ignore` — the same predicate host_check_server_repos already uses.
  export FIX="${TMP}/estate"
  mkdir -p "$FIX/servers"
  git -C "$FIX" init -q
  git -C "$FIX" config user.email t@t.test
  git -C "$FIX" config user.name  t
  cat > "$FIX/.gitignore" <<'IGN'
servers/*/.nwp-server.yml
servers/*/system/**
IGN

  # (a) a registered host with state — must stay silent
  mkdir -p "$FIX/servers/nwpcode/system"
  echo "hosts: []"        > "$FIX/servers/nwpcode/system/inventory.yml"
  _server_yml nwpcode 203.0.113.9 > "$FIX/servers/nwpcode/.nwp-server.yml"

  # (b) generic engine-tracked mechanism only — must stay silent (no state)
  mkdir -p "$FIX/servers/genericonly/demo"
  echo "# installer" > "$FIX/servers/genericonly/demo/install-box.sh"

  # (c) THE DEFECT: private per-host state, no identity file
  mkdir -p "$FIX/servers/met/system"
  echo "hosts: [met]"     > "$FIX/servers/met/system/inventory.yml"
  echo "30 1 * * * true"  > "$FIX/servers/met/system/cron-nwp-dr-pull"

  git -C "$FIX" add -A >/dev/null 2>&1 || true
  git -C "$FIX" commit -qm fixture >/dev/null 2>&1 || true
}

_server_yml() {
  cat <<YML
---
schema_version: 1
server:
  name: $1
  ip: $2
  ssh_user: probe
  ssh_key: ~/.ssh/nope
YML
}

_check() {
  run env NWP_DIR="$FIX" bash -c '
    set -uo pipefail
    PROJECT_ROOT="$1"; export PROJECT_ROOT
    source "$1/lib/host-capture.sh"
    host_check_servers_registered "$2"
  ' _ "$REPO_ROOT" "$FIX"
}

################################################################################
# 1. The finding.
################################################################################
@test "a host with captured state and no .nwp-server.yml is REPORTED" {
  _check
  [ "$status" -ne 0 ]
  [[ "$output" == *"met"* ]]
  [[ "$output" == *"servers/met"* ]]
}

@test "the report says WHY it matters — the fleet verbs skip it" {
  _check
  [[ "$output" == *"health --all"* ]] || [[ "$output" == *"fleet"* ]]
}

################################################################################
# 1b. NEGATIVE CONTROLS. Without these the guard could be always-red.
################################################################################
@test "a REGISTERED host with state is not reported" {
  _check
  [[ "$output" != *"servers/nwpcode"* ]]
}

@test "a directory of purely generic engine-tracked mechanism is not reported" {
  _check
  [[ "$output" != *"genericonly"* ]]
}

@test "once the identity file exists the check goes GREEN (rc=0, silent)" {
  _server_yml met 100.64.0.3 > "$FIX/servers/met/.nwp-server.yml"
  _check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an estate with no servers/ at all is rc=0, not a false alarm" {
  rm -rf "$FIX/servers"
  _check
  [ "$status" -eq 0 ]
}

################################################################################
# 2. The preflight itself must not report a clean fleet it never measured.
################################################################################
@test "pl server health --all is rc=3 UNKNOWN while a host with state is unregistered" {
  run env NWP_DIR="$FIX" "${REPO_ROOT}/pl" server health --all
  [ "$status" -eq 3 ]
  [[ "$output" == *"met"* ]]
  [[ "$output" == *"UNKNOWN"* ]] || [[ "$output" == *"CANNOT"* ]]
}

@test "NEGATIVE CONTROL: with every stateful host registered, --all measures and does not force rc=3" {
  _server_yml met 100.64.0.3 > "$FIX/servers/met/.nwp-server.yml"
  # Both hosts are unreachable fixtures, so each is legitimately rc=3 on its
  # own; what must NOT be present is the corpus complaint.
  run env NWP_DIR="$FIX" "${REPO_ROOT}/pl" server health --all
  [[ "$output" != *"not in the server registry"* ]]
}
