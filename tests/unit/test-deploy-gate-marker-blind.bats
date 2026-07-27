#!/usr/bin/env bats
# A GUARD THAT PROBES A PATH IT MAY NOT BE ABLE TO READ
#
# THE INVERSION THIS FILE PINS
#   lib/deploy-gate.sh:68 asked `[ -e /etc/nwp/deploy-gate-require ]`. Resolving
#   a name inside a directory needs SEARCH (+x) on that directory. If /etc/nwp
#   is not searchable by the caller, `-e` is FALSE **whether or not the marker
#   is there** — the probe cannot return a positive. So the marker file, which
#   exists precisely because env vars get stripped by sudo env_reset / cron
#   (ops#79), silently stops pinning fail-closed, and the deploy gate reverts to
#   the no-op it was hardened away from.
#
#   Every caller of deploy_gate_require is unprivileged: `pl` asserts no EUID,
#   and stg2live / live2prod / stg2prod / moodle / drush / demo / secrets inject
#   / rollback / restore all run as the operator. So "caller may not be able to
#   read it" is the normal case, not an edge case.
#
# THE LINE: UNREADABLE-BUT-NORMAL vs UNREADABLE-AND-IT-MATTERS
#   The parent's ABSENCE is observable without privilege (/etc is 0755
#   everywhere), so the two are always distinguishable:
#     · /etc/nwp does not exist          → the marker mechanism was never set up
#                                          on this host. Genuinely absent. This
#                                          is dev, CI, every worktree and every
#                                          A14 test-tier host. PERMIT — silence
#                                          here is correct, and cases 3/11 below
#                                          are the blast-radius guarantee.
#     · /etc/nwp exists, unsearchable    → the mechanism WAS set up and we cannot
#                                          see the answer. "No marker" would be a
#                                          guess. CANNOT VERIFY → refuse.
#   Vocabulary is lib/boundary.sh's / lib/canonical.sh's rc-2 "cannot-verify",
#   not a new one.
#
#   We test SEARCH, not READ, because search is exactly the capability `-e`
#   consumes: a 0711 directory is unreadable by ls yet answers `-e` correctly,
#   and case 5 pins that it is NOT reported blind.
#
# HONEST SIMULATION
#   The real condition is 0700 root:root probed by an unprivileged caller, which
#   the kernel answers with EACCES on stat(). A directory we own at mode 0000
#   produces the identical EACCES for a non-root process (Linux applies the owner
#   class strictly; only root bypasses). So the fixtures below are the real
#   syscall failure, not a stubbed function that returns false. (A sudo-gated 0700 root:root
#   twin of case 4 was removed: its conditional skip broke the strict
#   skip-equality contract — CI pins exactly 1 named skip, the local budget
#   pins 0 — and the kernel answers both fixtures with the same EACCES.)
#
# EVERY SECTION CARRIES A NEGATIVE CONTROL. A correctly configured, readable
# host must still be permitted, or this is an alarm that always rings.

setup() {
  TEST_TMP=$(mktemp -d)
  LIB="${BATS_TEST_DIRNAME}/../../lib"
  CMD="${BATS_TEST_DIRNAME}/../../scripts/commands/deploy-gate.sh"
  # Isolate from the real operator's keys: an unset NWP_DEPLOY_SK_KEY globs
  # $HOME/.ssh/id_ed25519_sk*, which would make the gate look "configured".
  export HOME="${TEST_TMP}/home"
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "$HOME/.ssh" "$PROJECT_ROOT"
  unset NWP_DEPLOY_GATE_REQUIRE NWP_DEPLOY_SK_KEY NWP_DEPLOY_ALLOWED_SIGNERS
  # shellcheck disable=SC1090
  source "${LIB}/deploy-gate.sh"
}

teardown() {
  # A mode-0000 fixture cannot be removed until it is searchable again.
  [ -n "$TEST_TMP" ] && chmod -R u+rwX "$TEST_TMP" 2>/dev/null
  [ -n "$TEST_TMP" ] && rm -rf "$TEST_TMP"
}

# ─────────────────────────────────────────────────────────────────────────────
# _dg_marker_verdict — the three-way discriminator
# ─────────────────────────────────────────────────────────────────────────────

@test "1 NEGATIVE CONTROL: marker present in a readable dir → present" {
  mkdir -p -m 0755 "$TEST_TMP/etc"
  touch "$TEST_TMP/etc/deploy-gate-require"
  run _dg_marker_verdict "$TEST_TMP/etc/deploy-gate-require"
  [ "$status" -eq 0 ]
  [ "$output" = "present" ]
}

@test "2 NEGATIVE CONTROL: marker absent from a readable dir → absent (not blind)" {
  mkdir -p -m 0755 "$TEST_TMP/etc"
  run _dg_marker_verdict "$TEST_TMP/etc/deploy-gate-require"
  [ "$output" = "absent" ]
}

@test "3 NEGATIVE CONTROL: parent dir does not exist at all → absent (dev/CI/worktree)" {
  # This is the blast-radius guarantee. /etc/nwp does not exist on the dev
  # workstation or on any test-tier host, so the fix must be a no-op there.
  run _dg_marker_verdict "$TEST_TMP/nope/deploy-gate-require"
  [ "$output" = "absent" ]
}

@test "4 THE BUG: dir exists but is not searchable → cannot-verify, NOT absent" {
  mkdir -p "$TEST_TMP/etc"
  touch "$TEST_TMP/etc/deploy-gate-require"   # the marker IS there …
  chmod 000 "$TEST_TMP/etc"                   # … and we cannot see it
  # Prove the premise: the original probe is false even though the file exists.
  run bash -c '[ -e "$1/etc/deploy-gate-require" ]' _ "$TEST_TMP"
  [ "$status" -ne 0 ]
  run _dg_marker_verdict "$TEST_TMP/etc/deploy-gate-require"
  [ "$output" = "cannot-verify" ]
}

@test "5 NEGATIVE CONTROL: 0711 search-only dir answers correctly → present, not blind" {
  # Pins that the discriminator tests SEARCH, not READ. A read-based test
  # (ls/-r) would cry wolf here, and an alarm that always rings gets ignored.
  mkdir -p -m 0711 "$TEST_TMP/etc"
  touch "$TEST_TMP/etc/deploy-gate-require"
  run _dg_marker_verdict "$TEST_TMP/etc/deploy-gate-require"
  [ "$output" = "present" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# _dg_require_enforced — tri-state (0 enforced / 1 not / 2 cannot verify)
# Driven through the per-checkout marker so no new env surface is introduced;
# /etc/nwp shares this exact code path via _dg_marker_verdict above.
# ─────────────────────────────────────────────────────────────────────────────

@test "6 NEGATIVE CONTROL: readable keys/ with the marker → rc 0 (enforced)" {
  mkdir -p -m 0755 "$PROJECT_ROOT/keys"
  touch "$PROJECT_ROOT/keys/deploy-gate.require"
  run _dg_require_enforced
  [ "$status" -eq 0 ]
}

@test "7 NEGATIVE CONTROL: readable keys/ without the marker → rc 1 (not enforced)" {
  mkdir -p -m 0755 "$PROJECT_ROOT/keys"
  run _dg_require_enforced
  [ "$status" -eq 1 ]
}

@test "8 NEGATIVE CONTROL: no keys/ dir and no /etc/nwp → rc 1 (ordinary checkout)" {
  run _dg_require_enforced
  [ "$status" -eq 1 ]
}

@test "9 THE BUG: unsearchable keys/ → rc 2 CANNOT VERIFY, never rc 1" {
  mkdir -p "$PROJECT_ROOT/keys"
  touch "$PROJECT_ROOT/keys/deploy-gate.require"
  chmod 000 "$PROJECT_ROOT/keys"
  run _dg_require_enforced
  [ "$status" -eq 2 ]
}

@test "10 NEGATIVE CONTROL: env NWP_DEPLOY_GATE_REQUIRE=true still wins, no filesystem needed" {
  export NWP_DEPLOY_GATE_REQUIRE=true
  run _dg_require_enforced
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# deploy_gate_require — end to end, unconfigured gate
# ─────────────────────────────────────────────────────────────────────────────

@test "11 NEGATIVE CONTROL: unconfigured gate, no marker infra → PROCEEDS (test tier untouched)" {
  # The A14 test tier and every dev workstation live here. If this goes red the
  # fix is worse than the bug.
  run deploy_gate_require nwt live "a live write"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not configured"* ]]
}

@test "12 NEGATIVE CONTROL: unconfigured gate + readable marker → aborts as it already did" {
  mkdir -p -m 0755 "$PROJECT_ROOT/keys"
  touch "$PROJECT_ROOT/keys/deploy-gate.require"
  run deploy_gate_require nwt live "a live write"
  [ "$status" -ne 0 ]
  [[ "$output" == *"REQUIRED but not configured"* ]]
}

@test "13 THE BUG end-to-end: unconfigured gate + unsearchable marker dir → ABORTS" {
  mkdir -p "$PROJECT_ROOT/keys"
  touch "$PROJECT_ROOT/keys/deploy-gate.require"
  chmod 000 "$PROJECT_ROOT/keys"
  run deploy_gate_require nwt live "a live write"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
  # It must NOT print the reassuring "proceeding without it" line.
  [[ "$output" != *"proceeding without it"* ]]
}

@test "14 the marker path names the reason, so the operator can act on it" {
  mkdir -p "$PROJECT_ROOT/keys"
  chmod 000 "$PROJECT_ROOT/keys"
  run deploy_gate_require nwt live "a live write"
  [ "$status" -ne 0 ]
  [[ "$output" == *"keys/deploy-gate.require"* ]]
}

@test "15 this machine: /etc/nwp is absent, so the fix is a no-op here" {
  # Documents the empirical fact behind the impact assessment. If /etc/nwp ever
  # appears on a dev box, this test tells you before a deploy does.
  if [ -d /etc/nwp ]; then
    run _dg_marker_verdict /etc/nwp/deploy-gate-require
    [ "$output" != "cannot-verify" ] || skip "/etc/nwp exists and is unsearchable — the guard now refuses, by design"
  else
    run _dg_marker_verdict /etc/nwp/deploy-gate-require
    [ "$output" = "absent" ]
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# `pl deploy-gate status` — THE DISPLAY MUST NOT CONTRADICT THE ENFORCEMENT
#
# The library above now answers three ways, but cmd_status kept its own private
# pair of `[ -e ]` probes and its own hardcoded copy of the marker paths. So on
# exactly the host the fix was written for, the operator's diagnostic verb said
#
#     [i] REQUIRE not enforced — an unconfigured gate is a no-op (fail-open)
#     [i] Verdict: gate inactive (test-tier default)
#
# while _dg_require_enforced returned 2 and the very next deploy ABORTED. A
# status verb that disagrees with the code it reports on is worse than no status
# verb: it is the reassurance an operator acts on. Worse, its remedy line told
# them to `sudo touch /etc/nwp/deploy-gate-require` — creating a second marker
# they equally cannot read — instead of naming the unsearchable directory.
#
# These cases pin the display to the SAME helper and the SAME path list, so the
# two cannot drift apart again.
# ─────────────────────────────────────────────────────────────────────────────

# Drive cmd_status against a fixture root. The script recomputes PROJECT_ROOT
# from its own location when sourced, so we re-point it afterwards — the marker
# lookup reads it at call time, which is precisely the property being tested.
dg_status() {
  bash -c 'source "$1" >/dev/null 2>&1; PROJECT_ROOT="$2"; cmd_status' _ "$CMD" "$PROJECT_ROOT"
}

@test "16 NEGATIVE CONTROL: readable keys/, no marker → status still says NOT enforced" {
  # Every dev box, CI job and worktree is here. If this goes red the fix cries wolf.
  mkdir -p -m 0755 "$PROJECT_ROOT/keys"
  run dg_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"REQUIRE not enforced"* ]]
  [[ "$output" != *"CANNOT VERIFY"* ]]
}

@test "17 NEGATIVE CONTROL: readable marker present → status says enforced, and names it" {
  mkdir -p -m 0755 "$PROJECT_ROOT/keys"
  touch "$PROJECT_ROOT/keys/deploy-gate.require"
  run dg_status
  [[ "$output" == *"REQUIRE enforced"* ]]
  [[ "$output" == *"deploy-gate.require"* ]]
  [[ "$output" != *"CANNOT VERIFY"* ]]
}

@test "18 THE BUG: unsearchable marker dir → status must NOT report fail-open" {
  mkdir -p "$PROJECT_ROOT/keys"
  touch "$PROJECT_ROOT/keys/deploy-gate.require"
  chmod 000 "$PROJECT_ROOT/keys"
  run dg_status
  [[ "$output" != *"REQUIRE not enforced"* ]]
  [[ "$output" != *"fail-open"* ]]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "19 THE BUG: the blind verdict line must warn of the abort, not say 'inactive'" {
  mkdir -p "$PROJECT_ROOT/keys"
  touch "$PROJECT_ROOT/keys/deploy-gate.require"
  chmod 000 "$PROJECT_ROOT/keys"
  run dg_status
  [[ "$output" != *"gate inactive"* ]]
  [[ "$output" == *"ABORT"* ]]
}

@test "20 the blind status names the unreadable path, and does not advise a second marker" {
  # "Something is unreadable somewhere" is not actionable; a path is. And telling
  # the operator to create ANOTHER marker they cannot read is worse than silence.
  mkdir -p "$PROJECT_ROOT/keys"
  chmod 000 "$PROJECT_ROOT/keys"
  run dg_status
  [[ "$output" == *"$PROJECT_ROOT/keys/deploy-gate.require"* ]]
  [[ "$output" != *"pin fail-closed with"* ]]
}

@test "21 NEGATIVE CONTROL: env REQUIRE=true still displays enforced, blind dir or not" {
  export NWP_DEPLOY_GATE_REQUIRE=true
  mkdir -p "$PROJECT_ROOT/keys"
  chmod 000 "$PROJECT_ROOT/keys"
  run dg_status
  [[ "$output" == *"REQUIRE enforced"* ]]
  [[ "$output" == *"NWP_DEPLOY_GATE_REQUIRE"* ]]
}

@test "22 THE INVARIANT: status and enforcement agree across all three fixtures" {
  # The property, not a spelling of it: whenever _dg_require_enforced would NOT
  # return 1 (i.e. the deploy will not silently proceed), the display must not
  # tell the operator the gate is a no-op.
  local fixture rc
  for fixture in absent present blind; do
    rm -rf "$PROJECT_ROOT/keys"
    case "$fixture" in
      absent)  mkdir -p -m 0755 "$PROJECT_ROOT/keys" ;;
      present) mkdir -p -m 0755 "$PROJECT_ROOT/keys"
               touch "$PROJECT_ROOT/keys/deploy-gate.require" ;;
      blind)   mkdir -p "$PROJECT_ROOT/keys"
               touch "$PROJECT_ROOT/keys/deploy-gate.require"
               chmod 000 "$PROJECT_ROOT/keys" ;;
    esac
    rc=0; _dg_require_enforced || rc=$?
    out="$(dg_status)"
    if [ "$rc" -ne 1 ]; then
      [[ "$out" != *"REQUIRE not enforced"* ]] || { echo "fixture=$fixture rc=$rc said not-enforced"; false; }
    else
      [[ "$out" == *"REQUIRE not enforced"* ]] || { echo "fixture=$fixture rc=$rc lost the no-op line"; false; }
    fi
    chmod -R u+rwX "$PROJECT_ROOT/keys" 2>/dev/null || true
  done
}

@test "23 the status display consults the shared helper, not its own [ -e ] probe" {
  # Structural backstop for cases 16-22: a private copy of the path list is how
  # the two sides drifted in the first place.
  run grep -c '_dg_marker_verdict' "$CMD"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
  # No hardcoded blind probe of either marker location may remain.
  run grep -nE '\[ -e .*(deploy-gate-require|deploy-gate\.require)' "$CMD"
  [ "$status" -ne 0 ]
}
