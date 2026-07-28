#!/usr/bin/env bats
# ops#109 / decision 23 — the agent-loop's resource preflight.
#
# WHY THIS FILE EXISTS
# --------------------
# Decision 23 makes ONE host (the ai-host) the sole owner of the agent-loop.
# Concentrating the loop on one box is only safe if the loop yields when that
# box is busy: the ai-host is also the LLM host, the webhook host and a
# gitlab-runner. Without a gate, a :00/:30 cron tick would spawn a headless
# `claude -p` on top of whatever the operator was already doing.
#
# The gate's contract is DEFER, not FAIL. A deferred run costs 30 minutes and
# claims no issue, churns no label, spawns no agent. So the gate is FAIL-SAFE:
# a probe that cannot answer defers rather than proceeding. The single
# documented exception is ollama, which is optional — unreachable ollama means
# "no model resident", not "cannot tell".
#
# WHAT IT TESTS
# -------------
# The health half is stubbed at the TRANSPORT seam (host_health_probe) so the
# real `pl server health` thresholds and arithmetic are exercised against
# synthetic /proc readings, not re-implemented here. The ollama half is stubbed
# at its transport seam (loop_pf_fetch_ollama_ps) so the real JSON parse runs.
# The runner half is not stubbed at all: it is pointed at a real user (matches)
# or a nonexistent one (no runner installed), so the real probe runs.
#
# THE NEGATIVE CONTROL THAT MATTERS: an idle host must still PROCEED. Without
# it, "always defer" would pass every test above.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LOOP_SH="$REPO_ROOT/scripts/agent-loop/agent-loop.sh"
  PREFLIGHT_LIB="$REPO_ROOT/lib/loop-preflight.sh"

  [ -f "$PREFLIGHT_LIB" ] || {
    echo "FATAL: no $PREFLIGHT_LIB" >&2
    return 1
  }

  # Neutral environment: every knob explicitly set, so no test depends on the
  # machine bats happens to run on (the CI runner IS the ai-host).
  export AGENT_LOOP_MIN_MEM_MB=2048
  export AGENT_LOOP_MAX_LOAD_PCT=150
  export AGENT_LOOP_REQUIRE_IDLE_OLLAMA=1
  export AGENT_LOOP_MAX_RUNNER_JOBS=0
  export AGENT_LOOP_RUNNER_USER="nwp-no-such-runner-user-$$"
  export NWP_HEALTH_MIN_DISK_MB=1
  export NWP_HEALTH_MIN_SWAP_FREE_PCT=0
  unset AGENT_LOOP_SKIP_PREFLIGHT

  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/host-capture.sh"
  # shellcheck source=/dev/null
  source "$PREFLIGHT_LIB"
}

# `! grep -q X` cannot fail a bats test: bash's errexit explicitly exempts a
# command whose return value is inverted with `!`, so every non-final `! grep`
# in a test body asserts NOTHING. This repo has been bitten by that once
# (test-agent-loop-sensitive-gate.bats). Route negative assertions through
# these plain commands instead.
refute_str() {
  local haystack="$1" pattern="$2"
  if grep -q -- "$pattern" <<<"$haystack"; then
    echo "REFUTE FAILED: '$pattern' is present in the given text" >&2
    return 1
  fi
  return 0
}

refute_in() {
  local file="$1" pattern="$2"
  if grep -q -- "$pattern" "$file" 2>/dev/null; then
    echo "REFUTE FAILED: '$pattern' is present in $file" >&2
    return 1
  fi
  return 0
}

# A synthetic NWPHEALTH block, in the exact protocol host_health_eval parses.
# mem_avail / load1 / nproc are the arguments; the rest are generous constants
# so only the signal under test can trip the gate.
fake_health() { # $1=mem_avail_mb $2=load1 $3=nproc
  printf 'NWPHEALTH v1\n'
  printf 'mem_total_mb=31727\n'
  printf 'mem_avail_mb=%s\n' "$1"
  printf 'swap_total_mb=8192\n'
  printf 'swap_free_mb=8192\n'
  printf 'disk_avail_mb=951888\n'
  printf 'disk_pct=40\n'
  printf 'load1=%s\n' "$2"
  printf 'nproc=%s\n' "$3"
}

# Install a stubbed health transport. The REAL host_health_eval thresholds run.
stub_health() { # $1=mem_avail_mb $2=load1 $3=nproc
  local m="$1" l="$2" n="$3"
  eval "host_health_probe() { fake_health $m $l $n; return 0; }"
}

# Idle-host baseline, matching the real measurement taken on the ai-host on
# 2026-07-27: 27823 MB available of 31727, load 0.05 over 32 cores.
stub_health_idle() { stub_health 27823 0.05 32; }

stub_ollama_empty()       { loop_pf_fetch_ollama_ps() { printf '{"models":[]}\n'; return 0; }; }
stub_ollama_resident()    { loop_pf_fetch_ollama_ps() { printf '{"models":[{"name":"qwen3-coder:30b","size_vram":21474836480}]}\n'; return 0; }; }
stub_ollama_unreachable() { loop_pf_fetch_ollama_ps() { return 1; }; }
stub_ollama_garbage()     { loop_pf_fetch_ollama_ps() { printf '<html>502 Bad Gateway</html>\n'; return 0; }; }

# --------------------------------------------------------------------------
# SIGNAL 1 — available system RAM below a floor.
#
# A headless `claude -p` is a Node process that then runs the repo's own test
# commands (bats, php, composer). Starting one on a box with no RAM headroom
# gets it OOM-killed mid-edit, leaving a half-written worktree and a retry
# burned.
# --------------------------------------------------------------------------

@test "DEFERS when available RAM is below the floor" {
  stub_health 900 0.05 32
  stub_ollama_empty
  run loop_preflight "test"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PREFLIGHT DEFER"* ]]
  [[ "$output" == *"memory headroom"* ]]
}

@test "the RAM floor is env-overridable (AGENT_LOOP_MIN_MEM_MB)" {
  stub_health 900 0.05 32
  stub_ollama_empty
  AGENT_LOOP_MIN_MEM_MB=512 run loop_preflight "test"
  [ "$status" -eq 0 ]
}

# --------------------------------------------------------------------------
# SIGNAL 2 — load average per core above a threshold.
#
# Per CORE, not absolute: the ai-host has 32 of them and a fixed load number
# means nothing without the core count. The loop is discretionary background
# work, so its default (150%) yields EARLIER than `pl server health`'s own
# 200% "is this box dying" threshold.
# --------------------------------------------------------------------------

@test "DEFERS when load per core is above the threshold" {
  stub_health 27823 64 32     # 64/32 = 200% > 150%
  stub_ollama_empty
  run loop_preflight "test"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PREFLIGHT DEFER"* ]]
  [[ "$output" == *"load"* ]]
}

@test "load is judged PER CORE, not absolutely" {
  # load 8 is fine on 32 cores (25%) and not fine on 2 (400%).
  stub_ollama_empty
  stub_health 27823 8 32
  run loop_preflight "test"
  [ "$status" -eq 0 ]
  stub_health 27823 8 2
  run loop_preflight "test"
  [ "$status" -eq 1 ]
}

@test "the load threshold is env-overridable (AGENT_LOOP_MAX_LOAD_PCT)" {
  stub_health 27823 64 32
  stub_ollama_empty
  AGENT_LOOP_MAX_LOAD_PCT=400 run loop_preflight "test"
  [ "$status" -eq 0 ]
}

# --------------------------------------------------------------------------
# SIGNAL 3 — a model resident in ollama.
#
# The ai-host is also the LLM host. ollama keeps a model resident for ~5
# minutes after its last request, so a non-empty /api/ps is a good proxy for
# "the operator is using the local LLM right now". The 96 GB the model occupies
# is iGPU VRAM — a DIFFERENT pool from the 30 GB of system RAM signal 1 reads —
# which is exactly why RAM headroom alone cannot see this.
# --------------------------------------------------------------------------

@test "DEFERS when a model is resident in ollama" {
  stub_health_idle
  stub_ollama_resident
  run loop_preflight "test"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PREFLIGHT DEFER"* ]]
  [[ "$output" == *"ollama"* ]]
}

# The documented EXCEPTION to fail-safe. ollama is optional: plenty of hosts
# that could own the loop never run it. Treating "no ollama" as "cannot tell"
# would defer forever on those hosts, which is not safety, it is a dead loop.
@test "an UNREACHABLE ollama is 'no model', NOT a defer (ollama is optional)" {
  stub_health_idle
  stub_ollama_unreachable
  run loop_preflight "test"
  [ "$status" -eq 0 ]
  refute_str "$output" "PREFLIGHT DEFER"
}

@test "an unparseable ollama response is 'no model', NOT a defer" {
  stub_health_idle
  stub_ollama_garbage
  run loop_preflight "test"
  [ "$status" -eq 0 ]
}

@test "the ollama signal can be switched off entirely" {
  stub_health_idle
  stub_ollama_resident
  AGENT_LOOP_REQUIRE_IDLE_OLLAMA=0 run loop_preflight "test"
  [ "$status" -eq 0 ]
}

# The parser, directly — a resident model must be distinguished from an empty
# array, and both from a malformed body.
@test "the /api/ps parser distinguishes resident / empty / malformed" {
  stub_ollama_resident
  run loop_pf_ollama_model_resident
  [ "$status" -eq 0 ]
  stub_ollama_empty
  run loop_pf_ollama_model_resident
  [ "$status" -eq 1 ]
  stub_ollama_garbage
  run loop_pf_ollama_model_resident
  [ "$status" -eq 1 ]
}

# --------------------------------------------------------------------------
# SIGNAL 4 — concurrent gitlab-runner jobs.
#
# Decision 23 puts the loop on the same box as the CI runner. A runner job is
# the single heaviest thing that box does (composer, ddev, phpunit), so the
# loop must not stack a claude on top of one. Probed WITHOUT stubs here: a real
# user with real processes, and a user that does not exist.
# --------------------------------------------------------------------------

@test "DEFERS when the runner user has running processes" {
  stub_health_idle
  stub_ollama_empty
  # This test's own shell is owned by the invoking user, so pointing the probe
  # at that user guarantees at least one match — a real pgrep, real count.
  AGENT_LOOP_RUNNER_USER="$(id -un)" run loop_preflight "test"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PREFLIGHT DEFER"* ]]
  [[ "$output" == *"runner"* ]]
}

@test "a host with no gitlab-runner installed is 0 jobs, not a defer" {
  stub_health_idle
  stub_ollama_empty
  AGENT_LOOP_RUNNER_USER="nwp-definitely-not-a-user-$$" run loop_preflight "test"
  [ "$status" -eq 0 ]
}

@test "the runner job allowance is env-overridable (AGENT_LOOP_MAX_RUNNER_JOBS)" {
  stub_health_idle
  stub_ollama_empty
  AGENT_LOOP_RUNNER_USER="$(id -un)" AGENT_LOOP_MAX_RUNNER_JOBS=9999 \
    run loop_preflight "test"
  [ "$status" -eq 0 ]
}

# FAIL-SAFE, NOT FAIL-CLOSED, and not fail-open either: a runner probe that
# cannot answer defers. Unlike ollama, the runner user EXISTS here, so "I
# cannot count" is genuine blindness about a signal that applies.
@test "DEFERS when the runner probe cannot answer (blind probe defers)" {
  stub_health_idle
  stub_ollama_empty
  local stubdir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stubdir"
  printf '#!/usr/bin/env bash\nexit 3\n' >"$stubdir/pgrep"
  chmod +x "$stubdir/pgrep"
  PATH="$stubdir:$PATH" AGENT_LOOP_RUNNER_USER="$(id -un)" run loop_preflight "test"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PREFLIGHT DEFER"* ]]
}

# --------------------------------------------------------------------------
# FAIL-SAFE on the health half too.
# --------------------------------------------------------------------------

@test "DEFERS when the health probe cannot measure the host (UNKNOWN is not OK)" {
  host_health_probe() { echo "UNKNOWN: health probe failed"; return 3; }
  stub_ollama_empty
  run loop_preflight "test"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PREFLIGHT DEFER"* ]]
}

@test "DEFERS when pl server health's engine is not available at all" {
  stub_ollama_empty
  unset -f host_health_require
  run loop_preflight "test"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PREFLIGHT DEFER"* ]]
}

# --------------------------------------------------------------------------
# THE NEGATIVE CONTROL. Without this, a gate that always deferred would pass
# every test above.
# --------------------------------------------------------------------------

@test "NEGATIVE CONTROL: an IDLE host PROCEEDS" {
  stub_health_idle
  stub_ollama_empty
  run loop_preflight "test"
  [ "$status" -eq 0 ]
  refute_str "$output" "PREFLIGHT DEFER"
  [[ "$output" == *"preflight OK"* ]]
}

@test "NEGATIVE CONTROL: each signal alone is enough to PROCEED when idle" {
  # Same idle host, asserted once per knob at its DEFAULT value, so a default
  # accidentally set to something that always trips is caught.
  stub_health_idle
  stub_ollama_empty
  unset AGENT_LOOP_MIN_MEM_MB AGENT_LOOP_MAX_LOAD_PCT \
        AGENT_LOOP_MAX_RUNNER_JOBS AGENT_LOOP_REQUIRE_IDLE_OLLAMA
  run loop_preflight "test"
  [ "$status" -eq 0 ]
}

@test "the escape hatch skips the whole preflight" {
  stub_health 1 999 1          # catastrophically busy
  stub_ollama_resident
  AGENT_LOOP_SKIP_PREFLIGHT=1 run loop_preflight "test"
  [ "$status" -eq 0 ]
}

# --------------------------------------------------------------------------
# WIRING — a gate nothing calls is not a gate.
# --------------------------------------------------------------------------

@test "agent-loop.sh calls loop_preflight BEFORE it polls for issues" {
  local pf_line poll_line
  pf_line="$(grep -n 'loop_preflight' "$LOOP_SH" | tail -1 | cut -d: -f1)"
  poll_line="$(grep -n 'polling project' "$LOOP_SH" | head -1 | cut -d: -f1)"
  [ -n "$pf_line" ] && [ -n "$poll_line" ]
  [ "$pf_line" -lt "$poll_line" ]
}

@test "agent-loop.sh calls loop_preflight BEFORE it spawns claude" {
  local pf_line claude_line
  pf_line="$(grep -n 'loop_preflight' "$LOOP_SH" | tail -1 | cut -d: -f1)"
  claude_line="$(grep -n 'spawning claude' "$LOOP_SH" | head -1 | cut -d: -f1)"
  [ -n "$pf_line" ] && [ -n "$claude_line" ]
  [ "$pf_line" -lt "$claude_line" ]
}

@test "the loop's own control libraries are inside the sensitive-path gate" {
  # lib/loop-parts.sh is the WRAPPER-ENFORCED kill switch and
  # lib/loop-preflight.sh is this gate. Both bound what the loop may do, so an
  # agent-loop MR that rewrites either must be refused the same way one that
  # rewrites scripts/agent-loop/ is. loop-parts.sh was outside the pattern
  # until ops#109 — the kill switch itself was agent-writable.
  local assign
  assign="$(grep -m1 '^SENSITIVE_PATH_RE=' "$LOOP_SH")"
  [ -n "$assign" ]
  eval "$assign"
  printf 'lib/loop-parts.sh\n'     | grep -Eq "$SENSITIVE_PATH_RE"
  printf 'lib/loop-preflight.sh\n' | grep -Eq "$SENSITIVE_PATH_RE"
  # NEGATIVE CONTROL for that widening: it must not swallow every lib/.
  refute_str "$(printf 'lib/ui.sh\n'      | grep -En "$SENSITIVE_PATH_RE" || true)" 'ui.sh'
  refute_str "$(printf 'lib/impact.sh\n'  | grep -En "$SENSITIVE_PATH_RE" || true)" 'impact.sh'
}

@test "every threshold's default is recorded in the library header" {
  local v
  for v in AGENT_LOOP_MIN_MEM_MB AGENT_LOOP_MAX_LOAD_PCT \
           AGENT_LOOP_REQUIRE_IDLE_OLLAMA AGENT_LOOP_MAX_RUNNER_JOBS \
           AGENT_LOOP_RUNNER_USER AGENT_LOOP_OLLAMA_URL \
           AGENT_LOOP_SKIP_PREFLIGHT; do
    grep -q "$v" "$PREFLIGHT_LIB" || {
      echo "FATAL: $v is not documented in $PREFLIGHT_LIB" >&2
      return 1
    }
  done
  # …and the header must state the defaults, not just name the variables.
  sed -n '1,80p' "$PREFLIGHT_LIB" | grep -q 'default'
}

# --------------------------------------------------------------------------
# BEHAVIOURAL — the real script, real probes, no stubs. Proves the defer costs
# nothing: no issue claimed, no label churn, exit 0 so cron stays green.
# --------------------------------------------------------------------------

_e2e_env() {
  export NWP_ROOT="$BATS_TEST_TMPDIR/rt"
  mkdir -p "$NWP_ROOT"
  export NWP_LOOP_STATE="$BATS_TEST_TMPDIR/parts.state"
  export GITLAB_TOKEN="not-a-real-token"
  export AGENT_LOOP_DRY_RUN=1
  # An immediately-refused port, so the poll (if reached) fails fast instead of
  # touching a real forge.
  export AGENT_LOOP_GITLAB_BASE_URL="http://127.0.0.1:1"
  export AGENT_LOOP_RUNNER_USER="nwp-definitely-not-a-user-$$"
  export AGENT_LOOP_OLLAMA_URL="http://127.0.0.1:1"
  export NWP_HEALTH_MIN_DISK_MB=1
  export NWP_HEALTH_MIN_SWAP_FREE_PCT=0
}

@test "BEHAVIOURAL: a busy host defers — exit 0, nothing polled, no issue claimed" {
  _e2e_env
  # The one knob that is certain to trip on any real machine.
  export AGENT_LOOP_MIN_MEM_MB=99999999
  run bash "$LOOP_SH"
  [ "$status" -eq 0 ]                       # cron must stay green
  local logf="$NWP_ROOT/logs/agent-loop.log"
  [ -f "$logf" ]
  grep -q 'PREFLIGHT DEFER' "$logf"
  refute_in "$logf" 'polling project'       # no issue was even looked at
  refute_in "$logf" 'spawning claude'
}

@test "BEHAVIOURAL NEGATIVE CONTROL: an idle host reaches the poll" {
  # Without this, the test above would pass on a loop that always deferred —
  # which is indistinguishable from a loop that never runs.
  _e2e_env
  export AGENT_LOOP_MIN_MEM_MB=1
  export AGENT_LOOP_MAX_LOAD_PCT=100000
  run bash "$LOOP_SH"
  [ "$status" -eq 0 ]
  local logf="$NWP_ROOT/logs/agent-loop.log"
  [ -f "$logf" ]
  grep -q 'polling project' "$logf"
  refute_in "$logf" 'PREFLIGHT DEFER'
}

@test "lib/loop-preflight.sh and agent-loop.sh are syntactically valid" {
  run bash -n "$PREFLIGHT_LIB"
  [ "$status" -eq 0 ]
  run bash -n "$LOOP_SH"
  [ "$status" -eq 0 ]
}
