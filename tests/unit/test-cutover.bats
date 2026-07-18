#!/usr/bin/env bats
# scripts/commands/cutover.sh — `pl cutover nwc` un-fork migration orchestrator
# (PL-STG2LIVE-INTEGRATION-DESIGN §3.7 + §6 P1-4).
#
# Exercises the orchestration contract with NO ssh, NO ddev, NO network and NO
# secrets: a mock `pl` (via PL_BIN) records every sibling invocation, and a
# fixture command dir (via CUTOVER_CMD_DIR) toggles which in-flight sibling MRs
# are "merged". Nothing ever touches a real live site.
#
# Covered: dispatch/help; --execute refused without a passed --rehearse; the
# one-time idempotency lock blocks re-run; each step invokes the expected `pl`
# verb (asserted against the recorded command strings, in order); the IMPACT
# typed-confirm is required before step 1; and absent siblings abort with
# "prerequisite MR not merged".

CUTOVER="${BATS_TEST_DIRNAME}/../../scripts/commands/cutover.sh"

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/proj"
  mkdir -p "${PROJECT_ROOT}"

  # A fixture command dir where EVERY in-flight sibling reads as "merged" —
  # each capability probe greps these stubs for its marker.
  export CUTOVER_CMD_DIR="${TEST_TMP}/cmd"
  mkdir -p "${CUTOVER_CMD_DIR}"
  echo '--remote'          > "${CUTOVER_CMD_DIR}/backup.sh"     # P0-3
  printf 'inject)\n'       > "${CUTOVER_CMD_DIR}/secrets.sh"    # P0-4
  printf 'verify\n'        > "${CUTOVER_CMD_DIR}/link.sh"       # P1-3
  echo 'drush'             > "${CUTOVER_CMD_DIR}/drush.sh"      # merged
  echo '--code-only'       > "${CUTOVER_CMD_DIR}/stg2live.sh"   # !117
  printf 'execute)\n'      > "${CUTOVER_CMD_DIR}/rollback.sh"

  # Mock pl: record every call; emit representative pm:list/updatedb output.
  export PL_CALLS="${TEST_TMP}/calls"
  : > "${PL_CALLS}"
  export PL_BIN="${TEST_TMP}/pl"
  cat > "${PL_BIN}" <<'EOF'
#!/bin/bash
echo "$*" >> "$PL_CALLS"
if [[ "$*" == *"pm:list"* && "$*" == *"--tier=live"* ]]; then printf 'block\nnode\n'; fi
if [[ "$*" == *"pm:list"* && "$*" == *"--tier=stg"* ]];  then printf 'block\nnode\n'; fi
if [[ "$*" == *"updatedb"* ]]; then echo "Performed update: nwc_update_9001"; fi
exit 0
EOF
  chmod +x "${PL_BIN}"
}

teardown() { rm -rf "${TEST_TMP}"; }

# Record a PASSED rehearsal so --execute is permitted.
_mark_rehearsed() {
  mkdir -p "${PROJECT_ROOT}/private/cutover"
  printf 'status=passed\n' > "${PROJECT_ROOT}/private/cutover/nwc.rehearse"
}

# ── dispatch / help ──────────────────────────────────────────────────────────

@test "pl routes 'cutover' to cutover.sh" {
  run grep -E 'cutover\)' "${BATS_TEST_DIRNAME}/../../pl"
  [ "$status" -eq 0 ]
}

@test "--help prints usage and the ordered steps" {
  run bash "$CUTOVER" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"un-fork migration orchestrator"* ]]
  [[ "$output" == *"--rehearse"* ]]
  [[ "$output" == *"--execute"* ]]
}

@test "a site other than nwc is refused" {
  run bash "$CUTOVER" ssc --rehearse
  [ "$status" -ne 0 ]
  [[ "$output" == *"only the nwc un-fork"* ]]
}

@test "a missing mode (neither --rehearse nor --execute) is refused" {
  run bash "$CUTOVER" nwc
  [ "$status" -ne 0 ]
  [[ "$output" == *"--rehearse | --execute is required"* ]]
}

@test "an out-of-range --from is refused" {
  run bash "$CUTOVER" nwc --execute --from=9
  [ "$status" -ne 0 ]
  [[ "$output" == *"--from must be a step number 1-7"* ]]
}

# ── --execute is refused without a passed --rehearse ─────────────────────────

@test "--execute is refused when no rehearsal is on record" {
  run bash "$CUTOVER" nwc --execute -y
  [ "$status" -ne 0 ]
  [[ "$output" == *"no PASSED rehearsal on record"* ]]
  # no sibling pl verb was invoked
  [ ! -s "${PL_CALLS}" ]
}

@test "--rehearse records status=passed and invokes the scratch updatedb" {
  run bash "$CUTOVER" nwc --rehearse
  [ "$status" -eq 0 ]
  [[ "$output" == *"rehearsal PASSED"* ]]
  run cat "${PROJECT_ROOT}/private/cutover/nwc.rehearse"
  [[ "$output" == *"status=passed"* ]]
  # the rehearsal pulls a live DB dump and runs updatedb on the scratch (stg) DB
  grep -q -- 'backup --remote nwc --db-only' "${PL_CALLS}"
  grep -q -- 'drush nwc --tier=stg -- updatedb -y' "${PL_CALLS}"
  # …and NEVER touches live with a write (read-only-on-live invariant)
  ! grep -q -- '--tier=live --execute' "${PL_CALLS}"
}

# ── IMPACT typed-confirm is required before step 1 ───────────────────────────

@test "--execute without -y and no TTY fails the IMPACT confirm before any step" {
  _mark_rehearsed
  run bash -c "bash '$CUTOVER' nwc --execute </dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"IMPACT confirmation declined"* ]]
  # fail-closed BEFORE step 1 — no sibling pl verb ran
  [ ! -s "${PL_CALLS}" ]
}

@test "the IMPACT manifest renders the un-fork magnitude" {
  _mark_rehearsed
  run bash -c "bash '$CUTOVER' nwc --execute </dev/null"
  [[ "$output" == *"6253"* ]]
  [[ "$output" == *"6497"* ]]
  [[ "$output" == *"LIVE member DB"* ]]
}

# ── each step invokes the expected pl verb, in order ─────────────────────────

@test "--execute runs steps 1-7 and invokes each expected pl verb in order" {
  _mark_rehearsed
  run bash "$CUTOVER" nwc --execute -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"cutover COMPLETE"* ]]

  # exact command strings, in sequence (design §3.7 / §5.4 order)
  run cat "${PL_CALLS}"
  [[ "${lines[0]}" == "backup --remote nwc" ]]
  [[ "${lines[1]}" == "drush nwc --tier=live --execute -- pm:uninstall tracer nwp_lockdown -y" ]]
  [[ "${lines[4]}" == "stg2live nwc --code-only" ]]
  [[ "${lines[5]}" == "secrets inject nwc --tier=live" ]]
  [[ "${lines[6]}" == "drush nwc --tier=live --execute -- en nwc_examen -y" ]]
  [[ "${lines[7]}" == "drush nwc --tier=live --execute -- nwc-guild:media-levels-seed" ]]
  [[ "${lines[8]}" == "drush nwc --tier=live --execute -- cr" ]]
  [[ "${lines[9]}" == "link verify nwc --tier=live --round-trip" ]]
}

@test "a successful --execute stamps the one-time idempotency lock" {
  _mark_rehearsed
  run bash "$CUTOVER" nwc --execute -y
  [ "$status" -eq 0 ]
  [ -f "${PROJECT_ROOT}/private/cutover/nwc.done" ]
}

# ── the idempotency lock blocks a re-run ─────────────────────────────────────

@test "--execute is refused when the idempotency lock is present" {
  _mark_rehearsed
  mkdir -p "${PROJECT_ROOT}/private/cutover"
  echo "cutover=nwc" > "${PROJECT_ROOT}/private/cutover/nwc.done"
  run bash "$CUTOVER" nwc --execute -y
  [ "$status" -ne 0 ]
  [[ "$output" == *"already completed"* ]]
  [ ! -s "${PL_CALLS}" ]
}

@test "--force overrides the idempotency lock" {
  _mark_rehearsed
  mkdir -p "${PROJECT_ROOT}/private/cutover"
  echo "cutover=nwc" > "${PROJECT_ROOT}/private/cutover/nwc.done"
  run bash "$CUTOVER" nwc --execute -y --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"cutover COMPLETE"* ]]
}

# ── absent siblings abort with "prerequisite MR not merged" ──────────────────

@test "step 1 aborts when pl backup --remote is unmerged" {
  _mark_rehearsed
  # remove the backup --remote marker → capability reads absent
  echo '# no remote flag' > "${CUTOVER_CMD_DIR}/backup.sh"
  run bash "$CUTOVER" nwc --execute -y
  [ "$status" -ne 0 ]
  [[ "$output" == *"prerequisite MR not merged: pl backup --remote"* ]]
}

@test "step 5 aborts when pl secrets inject is unmerged (and points at rollback)" {
  _mark_rehearsed
  echo '# no inject subcommand' > "${CUTOVER_CMD_DIR}/secrets.sh"
  run bash "$CUTOVER" nwc --execute -y
  [ "$status" -ne 0 ]
  [[ "$output" == *"prerequisite MR not merged: pl secrets inject"* ]]
  [[ "$output" == *"rollback"* ]]
}

@test "step 6 aborts (lock NOT stamped) when pl link verify is unmerged" {
  _mark_rehearsed
  rm -f "${CUTOVER_CMD_DIR}/link.sh"
  run bash "$CUTOVER" nwc --execute -y
  [ "$status" -ne 0 ]
  [[ "$output" == *"prerequisite MR not merged: pl link verify"* ]]
  [ ! -f "${PROJECT_ROOT}/private/cutover/nwc.done" ]
}

@test "rehearse aborts when pl backup --remote is unmerged (its live-dump source)" {
  echo '# no remote flag' > "${CUTOVER_CMD_DIR}/backup.sh"
  run bash "$CUTOVER" nwc --rehearse
  [ "$status" -ne 0 ]
  [[ "$output" == *"prerequisite MR not merged: pl backup --remote"* ]]
}

# ── resumability ─────────────────────────────────────────────────────────────

@test "--from=5 resumes after the destructive swap and skips the IMPACT confirm" {
  _mark_rehearsed
  run bash -c "bash '$CUTOVER' nwc --execute --from=5 </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resumes AFTER the destructive code swap"* ]]
  # steps 1-4 skipped: no backup / stg2live call, but step 5+ verbs ran
  ! grep -q -- 'backup --remote nwc$' "${PL_CALLS}"
  ! grep -q -- 'stg2live nwc --code-only' "${PL_CALLS}"
  grep -q -- 'secrets inject nwc --tier=live' "${PL_CALLS}"
  grep -q -- 'link verify nwc --tier=live --round-trip' "${PL_CALLS}"
}
