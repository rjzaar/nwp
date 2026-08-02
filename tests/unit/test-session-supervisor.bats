#!/usr/bin/env bats
# The supervisor — the thing that makes sessions replaceable.
#
# WHAT IS ACTUALLY BEING TESTED HERE IS AN ORDER.
#   The supervisor's safety is not in any single check; it is in the sequence:
#
#     0. is one already running?          (never two)
#     1. does the baton want a session?   (READY, or ABANDONED past timeout)
#     2. have we already failed this way? (repeat-stop, BEFORE spending anything)
#     3. can we reach the operator?       (refuse to run unwatchable)
#     4. can we generate a brief?         (no brief → no session)
#     5. launch, bounded
#
# Move step 2 after step 5 and a wedged loop costs a night instead of one
# failure. Move step 3 after the launch and an unattended agent runs with nobody
# able to be told. So each test below pins a step by making it FIRE and
# asserting that nothing after it happened.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export PROJECT_ROOT="$REPO_ROOT"
  export NWP_BATON_FILE="$BATS_TEST_TMPDIR/BATON.md"
  export NWP_SESSION_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export NWP_SESSION_BRIEF_DIR="$BATS_TEST_TMPDIR/briefs"
  export NWP_SESSION_TMUX="nwp-test-$$"
  export NWP_BATON_TIMEOUT_MIN=90
  export NWP_SESSION_MAX_REPEATS=2
  mkdir -p "$NWP_SESSION_STATE_DIR"

  # A stub `pl`. It records every call, so a test can assert what the supervisor
  # DID NOT do — which is the interesting half.
  export CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"
  STUB="$BATS_TEST_TMPDIR/pl"
  cat > "$STUB" <<'EOF'
#!/bin/sh
echo "$*" >> "$CALLS"
case "$1 $2" in
  "notify health") [ "${STUB_NOTIFY_OK:-1}" = "1" ] && exit 0 || exit 3 ;;
  "notify send")   exit 0 ;;
  "session brief") [ "${STUB_BRIEF_OK:-1}" = "1" ] && { echo "# stub brief"; exit 0; } || exit 1 ;;
esac
exit 0
EOF
  chmod +x "$STUB"
  export NWP_PL="$STUB"

  # A stub `tmux` on PATH. The supervisor runs on mini, which has tmux; this
  # workstation does not. Stubbing the binary rather than weakening the check
  # means the tests still exercise the REAL step-0 logic — including the
  # distinction between "no session running" and "no tmux at all", which is the
  # bit that would otherwise read as a green light.
  export FAKE_TMUX_DIR="$BATS_TEST_TMPDIR/tmux-sessions"
  mkdir -p "$FAKE_TMUX_DIR" "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/tmux" <<'EOF'
#!/bin/sh
echo "tmux $*" >> "$CALLS"
sub="$1"; shift
name=""
while [ $# -gt 0 ]; do
  case "$1" in -t|-s) name="$2"; shift 2 ;; *) shift ;; esac
done
case "$sub" in
  has-session)  [ -e "$FAKE_TMUX_DIR/$name" ] && exit 0 || exit 1 ;;
  new-session)  : > "$FAKE_TMUX_DIR/$name"; exit 0 ;;
  kill-session) rm -f "$FAKE_TMUX_DIR/$name"; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/tmux"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

teardown() { rm -f "$FAKE_TMUX_DIR"/* 2>/dev/null || true; }

run_sup() { run "$REPO_ROOT/scripts/commands/session.sh" supervisor run --dry-run; }
called()  { grep -q -- "$1" "$CALLS"; }

ready()       { printf 'STATUS: READY\nHEARTBEAT: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$NWP_BATON_FILE"; }
in_progress() { printf 'STATUS: IN-PROGRESS\nHEARTBEAT: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$NWP_BATON_FILE"; }
dropped()     { printf 'STATUS: IN-PROGRESS\nHEARTBEAT: %s\n' "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)" > "$NWP_BATON_FILE"
                touch -d '3 hours ago' "$NWP_BATON_FILE"; }

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1 — does the baton want a session?
# ═════════════════════════════════════════════════════════════════════════════

@test "supervisor: READY starts a FRESH session" {
  ready
  run_sup
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode=fresh"* ]]
}

@test "supervisor: a LIVE IN-PROGRESS baton is left alone" {
  # The most important negative in the file: the supervisor must not shoot a
  # healthy session that is simply still working.
  in_progress
  run_sup
  [ "$status" -eq 0 ]
  [[ "$output" == *"waiting"* ]]
  ! called "session brief"
}

@test "RED-PROOF supervisor: a DROPPED baton starts in RE-DERIVE mode" {
  # IN-PROGRESS, three hours stale. The previous session is gone and cannot say
  # so. Start — but tell the new session its inheritance is untrustworthy.
  dropped
  run_sup
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode=re-derive"* ]]
}

@test "RED-PROOF supervisor: a MISSING baton starts in RE-DERIVE mode" {
  rm -f "$NWP_BATON_FILE"
  run_sup
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode=re-derive"* ]]
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2 — repeat-failure stop, before anything is spent
# ═════════════════════════════════════════════════════════════════════════════

@test "RED-PROOF supervisor: two identical failures STOP the supervisor" {
  ready
  printf '%s\tsupervisor:launch:fresh\tx\n' "$(date -u +%FT%TZ)" >> "$NWP_SESSION_STATE_DIR/failures.tsv"
  printf '%s\tsupervisor:launch:fresh\ty\n' "$(date -u +%FT%TZ)" >> "$NWP_SESSION_STATE_DIR/failures.tsv"
  run_sup
  [ "$status" -eq 3 ]
  [[ "$output" == *"STOPPING"* ]]
}

@test "supervisor: the repeat-stop fires BEFORE any brief is generated" {
  # Ordering proof. A stop that happens after the expensive part is not a stop,
  # it is a log line.
  ready
  printf '%s\tsupervisor:launch:fresh\tx\n' "$(date -u +%FT%TZ)" >> "$NWP_SESSION_STATE_DIR/failures.tsv"
  printf '%s\tsupervisor:launch:fresh\ty\n' "$(date -u +%FT%TZ)" >> "$NWP_SESSION_STATE_DIR/failures.tsv"
  run_sup
  ! called "session brief"
}

@test "supervisor: the stop is reported to the operator, not just to a log" {
  ready
  printf '%s\tsupervisor:launch:fresh\tx\n' "$(date -u +%FT%TZ)" >> "$NWP_SESSION_STATE_DIR/failures.tsv"
  printf '%s\tsupervisor:launch:fresh\ty\n' "$(date -u +%FT%TZ)" >> "$NWP_SESSION_STATE_DIR/failures.tsv"
  run_sup
  called "notify send"
  grep -q "stopped-repeat-failure" "$CALLS"
}

@test "supervisor: ONE prior failure does not stop it — the guard is not a hair trigger" {
  ready
  printf '%s\tsupervisor:launch:fresh\tx\n' "$(date -u +%FT%TZ)" >> "$NWP_SESSION_STATE_DIR/failures.tsv"
  run_sup
  [ "$status" -eq 0 ]
}

@test "supervisor: a stop on 'fresh' does not also block 're-derive'" {
  # The signatures are distinct on purpose: a broken clean-start path should not
  # prevent recovery from a dropped baton, which is a different code path.
  dropped
  printf '%s\tsupervisor:launch:fresh\tx\n' "$(date -u +%FT%TZ)" >> "$NWP_SESSION_STATE_DIR/failures.tsv"
  printf '%s\tsupervisor:launch:fresh\ty\n' "$(date -u +%FT%TZ)" >> "$NWP_SESSION_STATE_DIR/failures.tsv"
  run_sup
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode=re-derive"* ]]
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3 — do not run what nobody can be told about
# ═════════════════════════════════════════════════════════════════════════════

@test "RED-PROOF supervisor: NO TMUX at all is CANNOT-VERIFY, not a green light" {
  # `tmux has-session` also fails when tmux is absent. Reading that as "nothing
  # is running, go ahead" would launch into a void — and this workstation is
  # exactly such a host, so the case is real, not theoretical.
  ready
  PATH="/usr/bin:/bin" run "$REPO_ROOT/scripts/commands/session.sh" supervisor run --dry-run
  if command -v /usr/bin/tmux >/dev/null 2>&1; then skip "this host has a real tmux"; fi
  [ "$status" -eq 2 ]
  [[ "$output" == *"no tmux"* ]]
}

@test "RED-PROOF supervisor: a DEAD notification path REFUSES the launch" {
  # An unattended session nobody can be alerted about is unbounded in time. This
  # is the same doctrine as 'a blind audit is not a clean audit', applied to the
  # thing that would have told you the audit was blind.
  ready
  STUB_NOTIFY_OK=0 run_sup
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSING to launch"* ]]
}

@test "supervisor: the notify refusal happens BEFORE the brief is generated" {
  ready
  STUB_NOTIFY_OK=0 run_sup
  ! called "session brief"
}

@test "supervisor: the notify refusal is RECORDED as a failure, so it can repeat-stop" {
  ready
  STUB_NOTIFY_OK=0 run_sup
  grep -q "notify-unhealthy" "$NWP_SESSION_STATE_DIR/failures.tsv"
}

@test "supervisor: the no-notify override is explicit and works" {
  # An escape hatch that nobody can find is an escape hatch that gets replaced
  # by someone deleting the check.
  ready
  STUB_NOTIFY_OK=0 NWP_SESSION_ALLOW_NO_NOTIFY=1 run_sup
  [ "$status" -eq 0 ]
  [[ "$output" == *"launching blind"* ]]
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4 — no brief, no session
# ═════════════════════════════════════════════════════════════════════════════

@test "RED-PROOF supervisor: if the brief cannot be generated, NOTHING is launched" {
  # The whole premise is that a session starts from generated state. A session
  # started without one is the old failure mode wearing the new system's badge.
  ready
  STUB_BRIEF_OK=0 run_sup
  [ "$status" -eq 2 ]
  [ ! -e "$FAKE_TMUX_DIR/$NWP_SESSION_TMUX" ]
}

@test "supervisor: a failed brief tells the operator it is stuck" {
  ready
  STUB_BRIEF_OK=0 run_sup
  grep -q "stuck" "$CALLS"
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 0 — never two
# ═════════════════════════════════════════════════════════════════════════════

@test "supervisor: an already-running session is not doubled" {
  ready
  : > "$FAKE_TMUX_DIR/$NWP_SESSION_TMUX"
  run_sup
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
  ! called "session brief"
}

# ═════════════════════════════════════════════════════════════════════════════
# The units themselves
# ═════════════════════════════════════════════════════════════════════════════

@test "units: the systemd user units exist and are oneshot+timer" {
  local d="$REPO_ROOT/servers/mini/system"
  [ -f "$d/systemd-nwp-session-supervisor.service" ]
  [ -f "$d/systemd-nwp-session-supervisor.timer" ]
  grep -q '^Type=oneshot' "$d/systemd-nwp-session-supervisor.service"
  grep -q '^OnUnitActiveSec=' "$d/systemd-nwp-session-supervisor.timer"
}

@test "units: supervisor install names files that actually EXIST in the repo" {
  # The bug this catches was live for one commit: the units were renamed to the
  # servers/<host>/system/systemd-* convention and `install` kept the old names,
  # so `pl session supervisor install` would have failed on a real host with a
  # bare "No such file". A path in an install step is a claim about the tree.
  local sh="$REPO_ROOT/scripts/commands/session.sh" src line f
  while IFS= read -r line; do
    f=$(printf '%s' "$line" | sed -n 's/.*"\$SUP_SRC\/\([^"]*\)".*/\1/p')
    [ -n "$f" ] || continue
    [ -f "$REPO_ROOT/servers/mini/system/$f" ]
  done < <(grep 'SUP_SRC/' "$sh")
}

@test "units: they install under the BARE systemd unit name, not the repo prefix" {
  # systemd will not load `systemd-nwp-session-supervisor.timer`; the enable
  # call would then fail with a confusing "Unit not found".
  grep -q '"\$SUP_UNIT_DIR/nwp-session-supervisor.service"' "$REPO_ROOT/scripts/commands/session.sh"
  grep -q '"\$SUP_UNIT_DIR/nwp-session-supervisor.timer"'   "$REPO_ROOT/scripts/commands/session.sh"
}

@test "units: the launched agent must NOT die with the unit" {
  # oneshot + KillMode=process: the tick exits, the tmux session lives. Without
  # this a `systemctl restart` mid-session kills an agent in the middle of a
  # write.
  grep -q '^KillMode=process' "$REPO_ROOT/servers/mini/system/systemd-nwp-session-supervisor.service"
}

@test "units: every bound is a declared Environment= so changing one is a diff" {
  local f="$REPO_ROOT/servers/mini/system/systemd-nwp-session-supervisor.service"
  grep -q 'NWP_BATON_TIMEOUT_MIN=' "$f"
  grep -q 'NWP_SESSION_MAX_REPEATS=' "$f"
  grep -q 'NWP_SESSION_TOKEN_CEILING=' "$f"
  grep -q 'NWP_SESSION_MAX_TURNS=' "$f"
  grep -q 'NWP_SESSION_DEMO_SITES=' "$f"
}

@test "units: the timer does NOT catch up after a suspend" {
  # Persistent=true would fire six ticks after a laptop wakes.
  grep -q '^Persistent=false' "$REPO_ROOT/servers/mini/system/systemd-nwp-session-supervisor.timer"
}

@test "units: the supervisor uses its OWN tmux session name, not mini's nwp one" {
  # mini already runs a durable `nwp` tmux session (nwp-tmux.service, created
  # 2026-08-02 by the credential-provisioning work). Colliding with it would let
  # the supervisor kill or reuse a session an operator is working in.
  grep -q 'NWP_SESSION_TMUX=nwp-auto' "$REPO_ROOT/servers/mini/system/systemd-nwp-session-supervisor.service"
  ! grep -qE '^Environment=NWP_SESSION_TMUX=nwp$' "$REPO_ROOT/servers/mini/system/systemd-nwp-session-supervisor.service"
}

# ═════════════════════════════════════════════════════════════════════════════
# The SessionEnd hook
# ═════════════════════════════════════════════════════════════════════════════

@test "hook: a clean exit flips the baton to READY" {
  printf 'STATUS: IN-PROGRESS\nHEARTBEAT: x\nbody\n' > "$NWP_BATON_FILE"
  NWP_PL="$REPO_ROOT/pl" \
    printf '{"exit_reason":"exit","transcript_path":"/tmp/x.jsonl"}' \
    | NWP_PL="$REPO_ROOT/pl" "$REPO_ROOT/scripts/hooks/session-end-baton.sh"
  [ "$(head -1 "$NWP_BATON_FILE")" = "STATUS: READY" ]
}

@test "RED-PROOF hook: an UNKNOWN exit reason flips to ABANDONED, not READY" {
  # Fail closed. A crashed session must not leave a handover that reads complete.
  printf 'STATUS: IN-PROGRESS\nHEARTBEAT: x\nbody\n' > "$NWP_BATON_FILE"
  printf '{"exit_reason":"crashed_horribly"}' \
    | NWP_PL="$REPO_ROOT/pl" "$REPO_ROOT/scripts/hooks/session-end-baton.sh"
  [ "$(head -1 "$NWP_BATON_FILE")" = "STATUS: ABANDONED" ]
}

@test "hook: the handover records status, in-flight, HELD and UNVERIFIED" {
  printf 'STATUS: IN-PROGRESS\nHEARTBEAT: x\n' > "$NWP_BATON_FILE"
  printf '{"exit_reason":"exit"}' \
    | NWP_PL="$REPO_ROOT/pl" "$REPO_ROOT/scripts/hooks/session-end-baton.sh"
  grep -q '^## Status'                    "$NWP_BATON_FILE"
  grep -q '^## In flight when this session ended' "$NWP_BATON_FILE"
  grep -q '^## HELD, and why'             "$NWP_BATON_FILE"
  grep -q '^## UNVERIFIED'                "$NWP_BATON_FILE"
}

@test "hook: a hook failure never takes the session's exit down with it" {
  # A hook that can fail the shutdown is a hook operators disable.
  printf 'not json at all' | NWP_PL=/nonexistent "$REPO_ROOT/scripts/hooks/session-end-baton.sh"
}
