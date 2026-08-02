#!/usr/bin/env bats
# The bounds on an unattended session.
#
# ops#214: PROVE EACH GUARD CAN FAIL. An unproven guard is not a guard — it is a
# line of code that has only ever been observed saying yes. Every bound below
# has a test that makes it REFUSE, and a paired test that makes it ALLOW, because
# a guard that refuses everything is just as useless as one that refuses nothing
# and is much easier to ship by accident.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export PROJECT_ROOT="$REPO_ROOT"
  export NWP_SESSION_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export NWP_SESSION_MAX_REPEATS=2
  export NWP_SESSION_DEMO_SITES="nwd ssd"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/session.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/session-bounds.sh"
}

# ═════════════════════════════════════════════════════════════════════════════
# BOUND 1 — sensitive paths
# ═════════════════════════════════════════════════════════════════════════════

hits() { printf '%s\n' "$1" | session_sensitive_hits; }

@test "sensitive: the pattern is READ FROM THE LIVE GATE, not copied" {
  # If this ever fails, the extraction has drifted and every other sensitive
  # test below is testing a pattern nobody enforces.
  local re; re=$(session_loop_sensitive_re)
  [ -n "$re" ]
  grep -q "^SENSITIVE_PATH_RE=" "$REPO_ROOT/scripts/agent-loop/agent-loop.sh"
}

@test "sensitive: the CLAUDE.md supplement is COMPILED FROM CLAUDE.md" {
  # Not a hand-copied second list. Adding a bullet to the standing orders must
  # widen the gate with no code change; this asserts the compile step runs and
  # produces a rule for a known bullet.
  local re; re=$(session_claude_md_re)
  [ -n "$re" ]
  [[ "$re" == *'CLAUDE\.md$'* ]]
  [[ "$re" == *'composer\.json$'* ]]
  [[ "$re" == *'settings\.php$'* ]]
}

@test "RED-PROOF sensitive: CLAUDE.md itself is refused (the loop gate alone MISSED this)" {
  # The measured 2026-08-02 gap. The agent-loop's push pattern does not match
  # CLAUDE.md, so before the supplement an unattended agent could have merged a
  # change to its own standing orders. Both halves are asserted: the gap was
  # real, and the union closes it.
  run bash -c 'source "'"$REPO_ROOT"'/lib/session.sh"; source "'"$REPO_ROOT"'/lib/session-bounds.sh"
               re=$(session_loop_sensitive_re); printf "CLAUDE.md\n" | grep -qE "$re" && echo LOOP-CATCHES || echo LOOP-MISSES'
  [ "$output" = "LOOP-MISSES" ]
  run hits "CLAUDE.md"
  [ "$status" -eq 0 ]
}

@test "RED-PROOF sensitive: composer.json is refused (supply chain)" {
  run hits "composer.json"
  [ "$status" -eq 0 ]
}

@test "RED-PROOF sensitive: a settings.php at ANY depth is refused" {
  run hits "sites/x/dev/web/sites/default/settings.php"
  [ "$status" -eq 0 ]
}

@test "RED-PROOF sensitive: an UNREADABLE CLAUDE.md refuses everything too" {
  # Half a rule set is not a rule set. If the standing orders cannot be read,
  # the union must refuse rather than silently falling back to the loop pattern.
  run bash -c 'export NWP_CLAUDE_MD="'"$BATS_TEST_TMPDIR"'/absent.md"
               source "'"$REPO_ROOT"'/lib/session.sh"
               source "'"$REPO_ROOT"'/lib/session-bounds.sh"
               printf "docs/harmless.md\n" | session_sensitive_hits'
  [ "$status" -eq 2 ]
  [[ "$output" == *"SENSITIVE-GATE-BLIND"* ]]
}

@test "RED-PROOF sensitive: a CLAUDE.md with NO sensitive-paths section refuses everything" {
  # The subtle version: the file is readable but the list is gone. A parser
  # that returned "" here would silently drop every standing-order rule.
  run bash -c 'export NWP_CLAUDE_MD="'"$BATS_TEST_TMPDIR"'/gutted.md"
               printf "# Claude\n\nno list here\n" > "$NWP_CLAUDE_MD"
               source "'"$REPO_ROOT"'/lib/session.sh"
               source "'"$REPO_ROOT"'/lib/session-bounds.sh"
               printf "docs/harmless.md\n" | session_sensitive_hits'
  [ "$status" -eq 2 ]
}

@test "sensitive: a doc that merely mentions a rule word is NOT caught" {
  # Anchoring proof. An unanchored `keys/**` would fire on docs/keys-guide.md
  # and the gate would become noise everyone learns to override.
  run hits "docs/keys-guide.md"
  [ "$status" -eq 1 ]
  run hits "composer.lock"
  [ "$status" -eq 1 ]
}

@test "RED-PROOF sensitive: .gitlab-ci.yml is refused" {
  run hits ".gitlab-ci.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *".gitlab-ci.yml"* ]]
}

@test "RED-PROOF sensitive: a secrets file is refused" {
  run hits ".secrets.yml"
  [ "$status" -eq 0 ]
}

@test "RED-PROOF sensitive: a live-deploy command is refused" {
  run hits "scripts/commands/stg2live.sh"
  [ "$status" -eq 0 ]
}

@test "RED-PROOF sensitive: an SSH key is refused" {
  run hits "keys/prod_id_ed25519"
  [ "$status" -eq 0 ]
}

@test "sensitive: an ordinary doc is ALLOWED — the gate is not a blanket no" {
  # The paired positive. Without it, `return 0` unconditionally would pass every
  # refusal test above.
  run hits "docs/guides/some-guide.md"
  [ "$status" -eq 1 ]
}

@test "RED-PROOF sensitive: an UNREADABLE rule set refuses EVERYTHING (exit 2)" {
  # The failure mode that matters most: a gate that cannot read its own rules
  # must not conclude "no rules matched". Point the extractor at a file with no
  # assignment in it and confirm it does not quietly wave a clean path through.
  run bash -c 'export NWP_SENSITIVE_SRC="'"$BATS_TEST_TMPDIR"'/nothing.sh"
               : > "$NWP_SENSITIVE_SRC"
               source "'"$REPO_ROOT"'/lib/session.sh"
               source "'"$REPO_ROOT"'/lib/session-bounds.sh"
               printf "docs/harmless.md\n" | session_sensitive_hits'
  [ "$status" -eq 2 ]
  [[ "$output" == *"SENSITIVE-GATE-BLIND"* ]]
}

# ═════════════════════════════════════════════════════════════════════════════
# BOUND 2 — live writes are demo-tier only
# ═════════════════════════════════════════════════════════════════════════════

@test "live-bound: a demo-tier live write is ALLOWED" {
  session_guard_live nwd live
  session_guard_live ssd live
}

@test "RED-PROOF live-bound: a live write to a NON-demo site is REFUSED" {
  run session_guard_live ssc live
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
}

@test "RED-PROOF live-bound: prod is refused outright, whatever the site" {
  run session_guard_live nwd prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"prod belongs to ver"* ]]
}

@test "RED-PROOF live-bound: an UNKNOWN tier is refused (fail closed)" {
  run session_guard_live nwd staging-ish
  [ "$status" -ne 0 ]
}

@test "live-bound: dev and stg never leave the workstation, so they are allowed" {
  session_guard_live anything-at-all dev
  session_guard_live anything-at-all stg
}

@test "RED-PROOF live-bound: an EMPTY demo allowlist refuses even nwd" {
  # Proves the allowlist is actually consulted rather than the site name being
  # special-cased somewhere.
  NWP_SESSION_DEMO_SITES="" run session_guard_live nwd live
  [ "$status" -ne 0 ]
}

# ═════════════════════════════════════════════════════════════════════════════
# BOUND 3 — repeat-failure stop
# ═════════════════════════════════════════════════════════════════════════════

@test "repeat-stop: one failure is not a repeat — the run continues" {
  session_failure_record "sig:alpha" "first"
  [ "$(session_failure_count 'sig:alpha')" -eq 1 ]
  ! session_repeat_stop "sig:alpha"
}

@test "RED-PROOF repeat-stop: the SAME failure twice STOPS instead of looping" {
  session_failure_record "sig:beta" "first"
  session_failure_record "sig:beta" "second"
  [ "$(session_failure_count 'sig:beta')" -eq 2 ]
  session_repeat_stop "sig:beta"
}

@test "repeat-stop: DIFFERENT failures do not add up into a false stop" {
  # Otherwise any two unrelated hiccups would wedge the supervisor shut.
  session_failure_record "sig:one" "x"
  session_failure_record "sig:two" "y"
  ! session_repeat_stop "sig:one"
  ! session_repeat_stop "sig:two"
}

@test "repeat-stop: a success CLEARS its own signature so the stop is not permanent" {
  session_failure_record "sig:gamma" "a"
  session_failure_record "sig:gamma" "b"
  session_repeat_stop "sig:gamma"
  session_failure_clear "sig:gamma"
  [ "$(session_failure_count 'sig:gamma')" -eq 0 ]
  ! session_repeat_stop "sig:gamma"
}

@test "repeat-stop: clearing one signature leaves the others recorded" {
  session_failure_record "sig:keep" "x"
  session_failure_record "sig:drop" "y"
  session_failure_clear "sig:drop"
  [ "$(session_failure_count 'sig:keep')" -eq 1 ]
  [ "$(session_failure_count 'sig:drop')" -eq 0 ]
}

@test "repeat-stop: an unseen signature counts zero, not error" {
  [ "$(session_failure_count 'never:seen')" -eq 0 ]
}

# ═════════════════════════════════════════════════════════════════════════════
# BOUND 4 — token ceiling
# ═════════════════════════════════════════════════════════════════════════════

@test "budget: an empty transcript spends nothing" {
  : > "$BATS_TEST_TMPDIR/t.jsonl"
  [ "$(session_tokens_used "$BATS_TEST_TMPDIR/t.jsonl")" -eq 0 ]
}

@test "budget: every usage field is counted, cache reads included" {
  cat > "$BATS_TEST_TMPDIR/t.jsonl" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50}}}
{"type":"assistant","message":{"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":1000,"cache_read_input_tokens":20000}}}
EOF
  # A ceiling that ignores cache reads is not a ceiling; 21165, not 165.
  [ "$(session_tokens_used "$BATS_TEST_TMPDIR/t.jsonl")" -eq 21165 ]
}

@test "RED-PROOF budget: crossing the ceiling reports EXCEEDED" {
  printf '{"usage":{"input_tokens":500,"output_tokens":600}}\n' > "$BATS_TEST_TMPDIR/t.jsonl"
  session_budget_exceeded "$BATS_TEST_TMPDIR/t.jsonl" 1000
}

@test "budget: staying under the ceiling does NOT trip it" {
  printf '{"usage":{"input_tokens":5,"output_tokens":5}}\n' > "$BATS_TEST_TMPDIR/t.jsonl"
  ! session_budget_exceeded "$BATS_TEST_TMPDIR/t.jsonl" 1000
}

@test "RED-PROOF budget: a MISSING transcript reads zero — which is why it is not the only bound" {
  # Documented on purpose. If the transcript cannot be found the tally is blind,
  # and `claude -p --max-turns` is the layer that still binds. Two bounds,
  # because this one can be starved of input.
  [ "$(session_tokens_used "$BATS_TEST_TMPDIR/absent.jsonl")" -eq 0 ]
  ! session_budget_exceeded "$BATS_TEST_TMPDIR/absent.jsonl" 1
  grep -q 'max-turns' "$REPO_ROOT/scripts/commands/session.sh"
}

# ═════════════════════════════════════════════════════════════════════════════
# The JSON quoter — small, and load-bearing for every hold note posted
# ═════════════════════════════════════════════════════════════════════════════

@test "json-quote: quotes, backslashes and newlines survive a round trip" {
  local out; out=$(_sess_json_quote 'a "quoted" \ thing
second line')
  printf '%s' "$out" | yq e -p=json '.' - >/dev/null
  [[ "$out" == *'\"quoted\"'* ]]
  [[ "$out" == *'\\n'* ]] || [[ "$out" == *'\n'* ]]
}
