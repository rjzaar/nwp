#!/usr/bin/env bats
# The baton — the relay contract between one session and the next.
#
# WHAT THIS PINS
#   The single case the whole handover design turns on: A SESSION THAT DIES
#   LEAVES `IN-PROGRESS` BEHIND FOREVER. Nothing else writes to that file, so a
#   supervisor that believes the written status waits all night for a handover
#   that is never coming. Every ABANDONED shape below is a way of detecting a
#   session that cannot tell you it is gone.
#
# RED-PROOF DISCIPLINE (ops#214)
#   For each guard there is a paired test that makes it FIRE. A test suite that
#   only ever shows the happy path proves the code runs, not that the guard
#   guards.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export PROJECT_ROOT="$REPO_ROOT"
  export NWP_BATON_FILE="$BATS_TEST_TMPDIR/BATON.md"
  export NWP_BATON_TIMEOUT_MIN=90
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/session.sh"
}

# ── the three written states round-trip ──────────────────────────────────────

@test "baton: a READY baton reads READY" {
  printf 'STATUS: READY\nbody\n' > "$NWP_BATON_FILE"
  [ "$(session_baton_effective_status)" = "READY" ]
}

@test "baton: a fresh IN-PROGRESS baton reads IN-PROGRESS" {
  printf 'STATUS: IN-PROGRESS\nHEARTBEAT: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$NWP_BATON_FILE"
  [ "$(session_baton_effective_status)" = "IN-PROGRESS" ]
}

@test "baton: an explicitly ABANDONED baton reads ABANDONED" {
  printf 'STATUS: ABANDONED\n' > "$NWP_BATON_FILE"
  [ "$(session_baton_effective_status)" = "ABANDONED" ]
}

# ── the dropped baton: the case that matters ─────────────────────────────────

@test "RED-PROOF baton: IN-PROGRESS past the timeout is detected as ABANDONED(timeout)" {
  # A session that died two hours ago. Its file still says IN-PROGRESS, because
  # a dead process cannot correct the record.
  local old; old=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)
  printf 'STATUS: IN-PROGRESS\nHEARTBEAT: %s\n' "$old" > "$NWP_BATON_FILE"
  touch -d '2 hours ago' "$NWP_BATON_FILE"
  [ "$(session_baton_effective_status)" = "ABANDONED(timeout)" ]
  session_baton_requires_rederive
}

@test "baton: IN-PROGRESS just INSIDE the timeout is NOT shot" {
  # The paired negative. Without this, a timeout of 0 would pass the test above
  # and silently kill every healthy session.
  local recent; recent=$(date -u -d '89 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  printf 'STATUS: IN-PROGRESS\nHEARTBEAT: %s\n' "$recent" > "$NWP_BATON_FILE"
  touch -d '89 minutes ago' "$NWP_BATON_FILE"
  [ "$(session_baton_effective_status)" = "IN-PROGRESS" ]
  ! session_baton_requires_rederive
}

@test "RED-PROOF baton: a heartbeat rescues an old FILE, so long-running work is not shot" {
  # mtime alone is the wrong signal: a session can work for hours without
  # touching the baton. The heartbeat is what distinguishes "quiet" from "dead".
  printf 'STATUS: IN-PROGRESS\nHEARTBEAT: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$NWP_BATON_FILE"
  touch -d '5 hours ago' "$NWP_BATON_FILE"
  [ "$(session_baton_effective_status)" = "IN-PROGRESS" ]
}

@test "RED-PROOF baton: a MISSING baton is ABANDONED, never READY" {
  rm -f "$NWP_BATON_FILE"
  [ "$(session_baton_effective_status)" = "ABANDONED(missing)" ]
  session_baton_requires_rederive
}

@test "RED-PROOF baton: a MALFORMED line 1 is ABANDONED, never READY" {
  # Fail closed. The expensive error is reading a partial handover as complete.
  printf 'this is not a status line\nSTATUS: READY\n' > "$NWP_BATON_FILE"
  [ "$(session_baton_effective_status)" = "ABANDONED(malformed)" ]
}

@test "RED-PROOF baton: STATUS on line 2 does NOT count — line 1 is the contract" {
  printf '\nSTATUS: READY\n' > "$NWP_BATON_FILE"
  [ "$(session_baton_effective_status)" = "ABANDONED(malformed)" ]
}

# ── writing ──────────────────────────────────────────────────────────────────

@test "baton: write puts STATUS on line 1 and stamps a heartbeat" {
  printf 'some body\n' | session_baton_write READY
  [ "$(head -1 "$NWP_BATON_FILE")" = "STATUS: READY" ]
  grep -q '^HEARTBEAT:' "$NWP_BATON_FILE"
  grep -q 'some body' "$NWP_BATON_FILE"
}

@test "RED-PROOF baton: write REFUSES an unknown status rather than inventing one" {
  printf 'x\n' > "$NWP_BATON_FILE"
  # Called directly, not via `run bash -c`: the function is sourced into THIS
  # shell, and a subshell that cannot find it would exit 127 and pass the
  # assertion for entirely the wrong reason.
  local rc=0
  printf 'body' | session_baton_write MAYBE 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ]
  # the old contents survive an attempted bad write
  [ "$(cat "$NWP_BATON_FILE")" = "x" ]
}

@test "baton: set_status flips line 1 and leaves the body alone" {
  printf 'STATUS: IN-PROGRESS\nHEARTBEAT: x\nthe body\n' > "$NWP_BATON_FILE"
  session_baton_set_status READY
  [ "$(head -1 "$NWP_BATON_FILE")" = "STATUS: READY" ]
  grep -q 'the body' "$NWP_BATON_FILE"
}

@test "baton: heartbeat refreshes the stamp without touching status or body" {
  printf 'STATUS: IN-PROGRESS\nHEARTBEAT: 2020-01-01T00:00:00Z\nthe body\n' > "$NWP_BATON_FILE"
  session_baton_heartbeat
  [ "$(head -1 "$NWP_BATON_FILE")" = "STATUS: IN-PROGRESS" ]
  ! grep -q '2020-01-01' "$NWP_BATON_FILE"
  grep -q 'the body' "$NWP_BATON_FILE"
}

@test "baton: the write is ATOMIC, so a polling supervisor never reads a half file" {
  # Non-atomic writes are how a healthy session gets graded malformed and shot.
  printf 'STATUS: READY\nold\n' > "$NWP_BATON_FILE"
  local before; before=$(stat -c %i "$NWP_BATON_FILE")
  printf 'new body\n' | session_baton_write IN-PROGRESS
  local after; after=$(stat -c %i "$NWP_BATON_FILE")
  # a rename, not an in-place truncate+write
  [ "$before" != "$after" ]
}

# ── the real estate's baton still satisfies the contract ─────────────────────

@test "baton: the LIVE baton (if present) parses under this contract" {
  local live="$HOME/central/OVERNIGHT-BATON.md"
  if [ ! -r "$live" ]; then skip "no live baton on this host"; fi
  NWP_BATON_FILE="$live"
  local s; s=$(session_baton_effective_status)
  case "$s" in
    READY|IN-PROGRESS|ABANDONED*) : ;;
    *) echo "live baton graded '$s' — the contract does not cover it" >&2; return 1 ;;
  esac
}
