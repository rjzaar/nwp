#!/usr/bin/env bats
################################################################################
# Bounded HTTP on the oversight paths — and the false-green underneath it.
#
# THE DEFECT. `pl rag`, `pl todo check` and `pl fleet publish` are the fleet
# oversight surfaces. Every network call on those paths was an unbounded
# `curl -sf`: fine on a low-latency link, and on a higher-latency one curl's own
# defaults take over (~2 min before it gives up on a connect, effectively
# unbounded on a transfer that stalls mid-body). Measured on the operator's
# link after a network change: todo >100s, rag >200s, and the */30
# `pl fleet publish` cron exiting 124 having published nothing at all.
#
# THE WORSE DEFECT. `curl -sf` prints NOTHING when it fails. Two callers read
# that empty string as data:
#   - check_gitlab_issues returned 0 (== "no issues assigned to you")
#   - rag.sh substituted {"items":[]} for a failed sweep, which is the exact
#     shape of "swept, found no work" — so every audited-clean site graded GREEN
# i.e. a slow enough network did not make `pl rag` fail, it made it lie, and in
# the reassuring direction.
#
# HOW THESE TESTS ARE HONEST. tests/unit/helpers/slow-curl.sh is a latency
# simulator that HONOURS the timeout it is given (`tc netem` needs root and
# cannot run in CI; a blackholed IP behaves differently on a DROP path vs a
# REJECT path). Because it honours --max-time, removing a timeout genuinely
# makes the clock-bound tests below go red — see test-http-timeouts-redgreen.bats
# for that proof run against a deliberately reverted copy.
#
# Every latency test is paired with a NEGATIVE CONTROL at latency 0: on a
# healthy link the output must be byte-identical to today's, with nothing
# spuriously marked UNKNOWN.
################################################################################

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$BATS_TEST_TMPDIR/http"
  mkdir -p "$TMP/bin" "$TMP/private/rag" "$TMP/private/update-awareness"

  # The latency simulator, first on PATH as `curl`.
  ln -sf "$ROOT/tests/unit/helpers/slow-curl.sh" "$TMP/bin/curl"
  chmod +x "$ROOT/tests/unit/helpers/slow-curl.sh"
  export PATH="$TMP/bin:$PATH"

  cat > "$TMP/.secrets.yml" <<'EOF'
gitlab:
  api_token: "fixture-token-not-real"
  server:
    domain: "gitlab.fixture.invalid"
EOF
  # Only the two network-touching categories, so the clock measures the network
  # and not this repo's (large, local, disk-bound) git sweep.
  cat > "$TMP/nwp.yml" <<'EOF'
settings:
  todo:
    categories:
      git_issues: true
      agent_loop: true
      test_instances: false
      token_rotation: false
      orphaned_sites: false
      ghost_sites: false
      incomplete_installs: false
      missing_backups: false
      missing_schedules: false
      security_updates: false
      verification: false
      uncommitted_work: false
      disk_usage: false
      ssl_expiry: false
      secret_expiry: false
      token_liveness: false
      loop_liveness: false
      rag_sync: false
      agent_host_auth: false
      site_registry_drift: false
      live_backup: false
      paused_automation: false
      notify_health: false
EOF
  export TODO_CONFIG_FILE="$TMP/nwp.yml"
  export TODO_CHECKS_PROJECT_ROOT="$TMP"
  export TODO_CACHE_DIR="$TMP/cache"
}

# Run the two network checks; print their items.
#   $1 = simulated latency   $2 = profile (default interactive)
#
# The profile is passed EXPLICITLY rather than inherited, because bats itself
# runs without a controlling terminal and would therefore be graded `batch` —
# which is correct behaviour for cron but is not the operator's situation, and
# silently measuring the wrong profile is how a bound test stops meaning
# anything.
_net_checks() {
  NWP_FAKE_CURL_LATENCY="$1" NWP_HTTP_PROFILE="${2:-interactive}" bash -c '
    source "'"$ROOT"'/lib/ui.sh" 2>/dev/null
    source "'"$ROOT"'/lib/todo-checks.sh"
    todo_clear_items
    check_gitlab_issues
    check_agent_loop_cap
    printf "%s\n" "${TODO_ITEMS[@]:-}"
  '
}

_elapsed() { # runs "$@", prints whole seconds elapsed
  local s e; s=$(date +%s); "$@" >/dev/null 2>&1 || true; e=$(date +%s)
  echo $((e - s))
}

################################################################################
# 1. The shared policy itself
################################################################################

@test "http: interactive and batch profiles differ, and context is TTY-derived" {
  source "$ROOT/lib/http.sh"

  NWP_HTTP_PROFILE=interactive run nwp_http_max_time
  [ "$output" -le 10 ]                      # a human is waiting

  NWP_HTTP_PROFILE=batch run nwp_http_max_time
  [ "$output" -gt 10 ]                      # nobody is

  NWP_HTTP_PROFILE=interactive run nwp_http_attempts
  [ "$output" -eq 1 ]                       # retries in front of a human multiply the stall

  NWP_HTTP_PROFILE=batch run nwp_http_attempts
  [ "$output" -gt 1 ]                       # a cron may retry before declaring blindness
}

@test "http: no TTY (cron/CI) selects batch; a TTY selects interactive" {
  # bats already runs us without a controlling terminal on any of 0/1/2.
  run bash -c "unset NWP_HTTP_PROFILE; source '$ROOT/lib/http.sh'; nwp_http_profile </dev/null >/dev/null 2>&1 || true; nwp_http_profile"
  [ "$status" -eq 0 ]
  # The call above still had bats' pipe on stdout; assert explicitly with all
  # three fds redirected, which is precisely cron's situation.
  run bash -c "unset NWP_HTTP_PROFILE; source '$ROOT/lib/http.sh'; nwp_http_profile > '$TMP/p' 2>/dev/null </dev/null; cat '$TMP/p'"
  [ "$output" = "batch" ]

  # And with a TTY on stderr only (operator running `pl rag --json > file`),
  # simulated by script(1) if available.
  if command -v script >/dev/null 2>&1; then
    run script -qec "bash -c \"unset NWP_HTTP_PROFILE; source '$ROOT/lib/http.sh'; nwp_http_profile\"" /dev/null
    [[ "$output" == *interactive* ]]
  fi
}

@test "http: a timeout classifies as rc 2 (could not tell), not rc 1 (a verdict)" {
  source "$ROOT/lib/http.sh"
  [ "$NWP_HTTP_RC_UNREACHABLE" -eq 2 ]      # same code lib/boundary.sh uses for CANNOT-VERIFY

  NWP_FAKE_CURL_LATENCY=30 NWP_HTTP_PROFILE=interactive \
    run nwp_http_get "https://gitlab.fixture.invalid/api/v4/user"
  [ "$status" -eq 2 ]
  [ -z "$output" ]                          # and it printed nothing: callers must not read this as data
}

@test "http: an HTTP error is rc 1 — the server answered, that IS a verdict" {
  source "$ROOT/lib/http.sh"
  NWP_FAKE_CURL_LATENCY=0 NWP_FAKE_CURL_RC=22 \
    run nwp_http_get "https://gitlab.fixture.invalid/api/v4/user"
  [ "$status" -eq 1 ]
}

@test "http: the token never reaches curl's argv" {
  source "$ROOT/lib/http.sh"
  local log="$TMP/argv.log"
  NWP_FAKE_CURL_LATENCY=0 NWP_FAKE_CURL_ARGV_LOG="$log" \
    nwp_http_gitlab_get "gitlab.fixture.invalid" "/user" "SUPERSECRETVALUE" >/dev/null 2>&1 || true
  [ -f "$log" ]
  run grep -c "SUPERSECRETVALUE" "$log"
  [ "$output" = "0" ]                       # CLAUDE.md: never let a token land where ps can read it
}

################################################################################
# 2. The bound — the slowness the operator actually reported
################################################################################

@test "todo: interactive — network checks bounded under a 60s-latency link" {
  # Unbounded, these two checks make 2 calls that each block for the full
  # latency: ~120s, which is what made `pl todo check --json` stop finishing.
  # Interactively there is 1 attempt of 8s per call, so ~16s.
  secs=$(_elapsed _net_checks 60 interactive)
  [ "$secs" -lt 30 ]
}

@test "todo: batch waits longer and retries — but is still bounded" {
  # The whole point of two profiles. A cron may spend more wall clock to avoid
  # losing a night's data to a blip; it may NOT spend unbounded wall clock.
  # 2 attempts x 20s x 2 call sites + backoff ~= 84s, and must not exceed 120s.
  secs=$(_elapsed _net_checks 60 batch)
  [ "$secs" -gt 30 ]      # it really did retry — otherwise this test is vacuous
  [ "$secs" -lt 120 ]     # and it really did stop
}

@test "todo: NEGATIVE CONTROL — on a healthy link nothing is marked UNKNOWN" {
  run _net_checks 0
  [ "$status" -eq 0 ]
  ! grep -q 'UNK' <<<"$output"
  # and it is fast
  secs=$(_elapsed _net_checks 0)
  [ "$secs" -lt 5 ]
}

################################################################################
# 3. The false-green — the part that matters more than the clock
################################################################################

@test "todo: an unreachable GitLab yields UNKNOWN, not an empty (clean) result" {
  # THE REGRESSION THIS PINS. check_gitlab_issues used to `return 0` when curl
  # printed nothing, so "GitLab unreachable" and "no issues assigned" were the
  # same output. A check that could not look must say so.
  run _net_checks 60
  [[ "$output" == *'"category": "UNK"'* ]] || [[ "$output" == *'"category":"UNK"'* ]]
  [[ "$output" == *"UNKNOWN"* ]] || [[ "$output" == *"NOT a clean result"* ]]
}

@test "rag: a failed todo sweep grades AMBER, never GREEN" {
  # A site with a clean audit record. Before the fix, a sweep that timed out was
  # rendered as {"items":[]} — indistinguishable from "swept, no work" — so this
  # site graded GREEN off the back of a network failure.
  cat > "$TMP/private/update-awareness/demo.json" <<'EOF'
{"site":"demo","security_count":0,"ignored_count":0,"cache_stale":false,"scanned":true}
EOF
  printf '{"items":[],"sweep_state":"failed","sweep_reason":"pl todo check did not finish in time"}' \
    > "$TMP/private/rag/.todo.json"

  run env AUDIT_DIR="$TMP/private/update-awareness" \
          TODO_JSON="$TMP/private/rag/.todo.json" \
          STATE_DIR="$TMP/private/rag" \
          SITE="" JSON=true PHASES="" MATURITIES="" \
          RED="" YEL="" GRN="" NC="" BOLD="" DIM="" \
          python3 "$ROOT/lib/rag-render.py"

  [[ "$output" == *'"rag": "AMBER"'* ]]
  [[ "$output" != *'"rag": "GREEN"'* ]]
  [[ "$output" == *'"state": "failed"'* ]]   # and it says WHY, in the machine output
}

@test "rag: NEGATIVE CONTROL — a completed sweep with no work still grades GREEN" {
  cat > "$TMP/private/update-awareness/demo.json" <<'EOF'
{"site":"demo","security_count":0,"ignored_count":0,"cache_stale":false,"scanned":true}
EOF
  printf '{"items":[]}' > "$TMP/private/rag/.todo.json"

  run env AUDIT_DIR="$TMP/private/update-awareness" \
          TODO_JSON="$TMP/private/rag/.todo.json" \
          STATE_DIR="$TMP/private/rag" \
          SITE="" JSON=true PHASES="" MATURITIES="" SWEEP_STATE="complete" \
          RED="" YEL="" GRN="" NC="" BOLD="" DIM="" \
          python3 "$ROOT/lib/rag-render.py"

  # This is the assertion that stops the fix from becoming "mark everything
  # amber and call it honest". A real clean result must still read as clean.
  [[ "$output" == *'"rag": "GREEN"'* ]]
}

@test "rag: the sweep verdict is published for downstream consumers" {
  printf '{"items":[],"sweep_state":"failed","sweep_reason":"deadline"}' \
    > "$TMP/private/rag/.todo.json"
  env AUDIT_DIR="$TMP/private/update-awareness" \
      TODO_JSON="$TMP/private/rag/.todo.json" \
      STATE_DIR="$TMP/private/rag" \
      SITE="" JSON=true PHASES="" MATURITIES="" \
      RED="" YEL="" GRN="" NC="" BOLD="" DIM="" \
      python3 "$ROOT/lib/rag-render.py" >/dev/null
  run python3 -c "
import json; d=json.load(open('$TMP/private/rag/state.json'))
print(d['todo_sweep']['state'])"
  [ "$output" = "failed" ]
}
