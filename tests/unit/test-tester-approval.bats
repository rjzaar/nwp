#!/usr/bin/env bats
# `pl demo testers <site> add|requests|approve|reject` — the approval orchestration.
#
# WHY THESE ARE MOSTLY STATIC ASSERTIONS
#   The approval spans two hosts and a live site: drush on the demo box creates
#   the account, this host writes the tester registry, and the box installer
#   stages the payload. None of that is runnable in a unit test. What CAN be
#   pinned — and is the thing that must never regress — is the ORDER, and the
#   refusals between the steps. Same idiom as test-demo.bats, which asserts the
#   reset's harvest-before-wipe ordering statically for the same reason.
#
# THE ORDER, AND WHY IT IS THE WHOLE SAFETY PROPERTY
#   Two failure directions, wildly asymmetric:
#     * registry row, no account -> harmless; the reset leg counts it absent.
#     * ACCOUNT, NO REGISTRY ROW -> a person told "you're approved", holding a
#       working login, silently wiped tonight. The worst outcome in the feature.
#   So the account is created BLOCKED, the registry is written and PROVEN, the
#   payload is staged, and only then is the account activated. A blocked account
#   has promised nobody anything.
#
# RED-THEN-GREEN: written against a demo.sh with no approve/reject/requests/add
# actions at all and observed RED (14 failing). Counts in the commit.

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}/sites/demo1"
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  DEMO_CMD="${REPO_ROOT}/scripts/commands/demo.sh"
  SRC="$(cat "$DEMO_CMD")"
  source "${REPO_ROOT}/lib/tester-registry.sh"
  export NWP_DEMO_REGISTRY_HOME_FILE="${TEST_TMP}/registry-home.yml"
  printf 'registry_home: %s\n' "$(hostname -s)" > "$NWP_DEMO_REGISTRY_HOME_FILE"
}

teardown() {
  rm -rf "${TEST_TMP}"
  unset PROJECT_ROOT NWP_DEMO_REGISTRY_HOME_FILE
}

# --- dispatch -----------------------------------------------------------------

@test "the new tester actions are dispatched, not silently unknown" {
  for action in requests approve reject add; do
    [[ "$SRC" == *"cmd_testers_${action}"* ]] || { echo "no cmd_testers_${action}"; false; }
  done
}

@test "an unknown testers action still names the full action set" {
  run bash "$DEMO_CMD" testers demo1 no-such-action
  [ "$status" -ne 0 ]
  [[ "$output" == *"approve"* ]]
  [[ "$output" == *"reject"* ]]
}

@test "approve, reject and add all require an EXPLICIT tier" {
  # A write that does not name its tier is the ops#225/#173 rule; approving a
  # tester against the wrong site is exactly that class of accident.
  [[ "$SRC" =~ approve\|reject\|add ]] || \
    [[ "$SRC" == *"set-guild|set-level|login|approve|reject|add"* ]] || \
    { echo "approve/reject/add are not in the explicit-tier arm"; false; }
}

@test "approve and add refuse a site whose canonical phase is prod" {
  # Keyed on the PHASE, never on the site's name (CLAUDE.md). Inert today,
  # correct forever, arms itself the moment `pl canonical set <site> prod` runs.
  [[ "$SRC" == *"demo_refuse_prod_phase"* ]]
  run bash -c "grep -n 'demo_refuse_prod_phase' '$DEMO_CMD' | wc -l"
  [ "$output" -ge 1 ]
}

# --- THE ORDER ----------------------------------------------------------------

@test "approve creates the account BLOCKED before anything else" {
  body="$(sed -n '/^cmd_testers_approve()/,/^}/p' "$DEMO_CMD")"
  [ -n "$body" ]
  [[ "$body" == *"nwc:join-approve"* ]]
  # And it must say, in the code, that what it got back is not yet usable.
  [[ "$body" == *"BLOCKED"* || "$body" == *"blocked"* ]]
}

@test "approve writes the registry BEFORE it activates the account" {
  body="$(sed -n '/^cmd_testers_approve()/,/^}/p' "$DEMO_CMD")"
  reg=$(printf '%s\n' "$body" | grep -n 'tester_registry_add' | head -1 | cut -d: -f1)
  act=$(printf '%s\n' "$body" | grep -n 'nwc:join-activate' | head -1 | cut -d: -f1)
  [ -n "$reg" ] && [ -n "$act" ]
  [ "$reg" -lt "$act" ]
}

@test "approve STAGES the payload before it activates the account" {
  body="$(sed -n '/^cmd_testers_approve()/,/^}/p' "$DEMO_CMD")"
  stage=$(printf '%s\n' "$body" | grep -n 'demo_testers_stage_payload' | head -1 | cut -d: -f1)
  act=$(printf '%s\n' "$body" | grep -n 'nwc:join-activate' | head -1 | cut -d: -f1)
  [ -n "$stage" ] && [ -n "$act" ]
  [ "$stage" -lt "$act" ]
}

@test "a FAILED registry write aborts the approval — no activation" {
  body="$(sed -n '/^cmd_testers_approve()/,/^}/p' "$DEMO_CMD")"
  # The registry call must be guarded and the guard must return, not warn.
  [[ "$body" =~ tester_registry_add[^\|]*\|\|[[:space:]]*\{ ]] || \
    [[ "$body" == *"tester_registry_add"*"|| {"* ]] || \
    { echo "tester_registry_add is not guarded by a || refusal block"; false; }
  [[ "$body" == *"return"* ]]
}

@test "a FAILED staging aborts the approval — no activation" {
  body="$(sed -n '/^cmd_testers_approve()/,/^}/p' "$DEMO_CMD")"
  [[ "$body" == *"demo_testers_stage_payload"* ]]
  # The refusal must name the consequence, not just fail.
  [[ "$body" == *"wiped"* || "$body" == *"tonight"* ]]
}

@test "the refusal explains what the operator must NOT tell the person" {
  body="$(sed -n '/^cmd_testers_approve()/,/^}/p' "$DEMO_CMD")"
  [[ "$body" == *"not been approved"* || "$body" == *"do NOT tell"* || "$body" == *"nobody has been approved"* ]]
}

# --- credential discipline ----------------------------------------------------

@test "the tester's password is never written to the demo log" {
  body="$(sed -n '/^cmd_testers_approve()/,/^}/p' "$DEMO_CMD")"
  # demo_log lines in this function must not carry the password variable.
  while IFS= read -r line; do
    [[ "$line" != *'password'* ]] || { echo "demo_log line carries a password: $line"; false; }
  done < <(printf '%s\n' "$body" | grep 'demo_log ')
}

@test "approve emits the password ONCE and says it is not stored" {
  body="$(sed -n '/^cmd_testers_approve()/,/^}/p' "$DEMO_CMD")"
  [[ "$body" == *"password"* ]]
  [[ "$body" == *"once"* || "$body" == *"not stored"* || "$body" == *"never logged"* ]]
}

# --- add ----------------------------------------------------------------------

@test "add writes the registry through the validating library, not by hand" {
  body="$(sed -n '/^cmd_testers_add()/,/^}/p' "$DEMO_CMD")"
  [ -n "$body" ]
  [[ "$body" == *"tester_registry_add"* ]]
  # Never a hand-rolled jq write: the validators are the point.
  [[ "$body" != *'jq'*'demo-testers.json'* ]]
}

@test "add stages the payload too — a tester nobody staged is not preserved" {
  body="$(sed -n '/^cmd_testers_add()/,/^}/p' "$DEMO_CMD")"
  [[ "$body" == *"demo_testers_stage_payload"* ]]
}

@test "the staging helper really invokes the box installer's --stage-testers" {
  # The indirection above is only safe if the helper does what its name says:
  # the registry on THIS host is not what the reset reads.
  body="$(sed -n '/^demo_testers_stage_payload()/,/^}/p' "$DEMO_CMD")"
  [ -n "$body" ]
  [[ "$body" == *"install-box.sh"* ]]
  [[ "$body" == *"--stage-testers"* ]]
  # A missing installer must be a refusal, not a silent success.
  [[ "$body" == *"return 2"* ]]
}

# --- requests -----------------------------------------------------------------

@test "requests is a READ — it never writes the registry" {
  body="$(sed -n '/^cmd_testers_requests()/,/^}/p' "$DEMO_CMD")"
  [ -n "$body" ]
  [[ "$body" == *"nwc:join-requests"* ]]
  [[ "$body" != *"tester_registry_add"* ]]
  [[ "$body" != *"join-activate"* ]]
}

@test "demo.sh sources the tester registry library rather than reimplementing it" {
  [[ "$SRC" == *"tester-registry.sh"* ]]
}
