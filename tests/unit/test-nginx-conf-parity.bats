#!/usr/bin/env bats
# lib/nginx-conf-parity.sh — the D19 stray-vhost guard (ops#157/#92/#106).
# The 2026-07-29 incident: two conf files sat in the box's conf.d, untracked,
# claiming live server_names with dead roots, and an unrelated reload armed one.
# This guard must flag exactly that BEFORE a reload can.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/lib/host-capture.sh"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/lib/nginx-conf-parity.sh"

  # A fake tracked baseline: ccc.conf + mt.conf are legitimate.
  export FAKE_ROOT="${TEST_TMP}/root"
  mkdir -p "${FAKE_ROOT}/servers/box/nginx/conf.d"
  : > "${FAKE_ROOT}/servers/box/nginx/conf.d/ccc.conf"
  : > "${FAKE_ROOT}/servers/box/nginx/conf.d/mt.conf"
}
teardown() { rm -rf "$TEST_TMP"; }

# A fake transport: host_run calls `$prefix "$script"` (word-split, no quote
# processing), so the prefix must be a plain command that ignores its script
# argument and emits a canned capture. We write the capture to a temp file and
# `cat` it — robust against newlines that `$'...'`/`%q` would mangle under
# unquoted expansion.
# host_run calls `$prefix "$script"` (word-split, no quote processing — the
# real transport is `ssh -o… user@host`, plain tokens). So the fake prefix is
# a single path to an executable wrapper that ignores its script argument and
# emits a canned capture. No spaces-in-args, no quoting to survive splitting.
fakebox() {
  local w="${TEST_TMP}/fakebox.$RANDOM"
  { printf '#!/usr/bin/env bash\ncat <<'\''CAP'\''\n'; printf '%s\n' "$1"; printf 'CAP\n'; } > "$w"
  chmod +x "$w"
  printf '%s' "$w"
}

# ---------------------------------------------------------------------------
# Pure compare
# ---------------------------------------------------------------------------

@test "compare: identical sets → no stray, no undeployed, matched count" {
  nginx_parity_compare $'a.conf\nb.conf' $'a.conf\nb.conf'
  [ "${#NP_STRAY[@]}" -eq 0 ]
  [ "${#NP_UNDEPLOYED[@]}" -eq 0 ]
  [ "$NP_MATCHED" -eq 2 ]
}

@test "compare: a box file not tracked is a STRAY (the incident)" {
  nginx_parity_compare $'ccc.conf\nmt.conf\ncathnet.conf' $'ccc.conf\nmt.conf'
  [ "${#NP_STRAY[@]}" -eq 1 ]
  [ "${NP_STRAY[0]}" = "cathnet.conf" ]
  [ "${#NP_UNDEPLOYED[@]}" -eq 0 ]
}

@test "compare: a tracked file absent on the box is UNDEPLOYED" {
  nginx_parity_compare $'ccc.conf' $'ccc.conf\nmt.conf'
  [ "${#NP_UNDEPLOYED[@]}" -eq 1 ]
  [ "${NP_UNDEPLOYED[0]}" = "mt.conf" ]
  [ "${#NP_STRAY[@]}" -eq 0 ]
}

@test "compare: empty box vs empty tracked is parity, not a crash" {
  nginx_parity_compare "" ""
  [ "${#NP_STRAY[@]}" -eq 0 ]
  [ "${#NP_UNDEPLOYED[@]}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Orchestrator — fail closed on blindness, flag drift, pass on parity
# ---------------------------------------------------------------------------

@test "check: a matching box is IN PARITY (rc 0)" {
  local cap; cap=$'NWPCONF v1\nconfdir=present\nFccc.conf\nFmt.conf'
  run nginx_parity_check box "$FAKE_ROOT" "$(fakebox "$cap")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 conf file(s) present in both"* ]]
}

@test "check: a stray on the box is DRIFT (rc 1), named, with the reload warning" {
  local cap; cap=$'NWPCONF v1\nconfdir=present\nFccc.conf\nFmt.conf\nFcathnet.conf'
  run nginx_parity_check box "$FAKE_ROOT" "$(fakebox "$cap")"
  [ "$status" -eq 1 ]
  [[ "$output" == *"STRAY"* ]]
  [[ "$output" == *"cathnet.conf"* ]]
  [[ "$output" == *"reload"* ]]
}

@test "check: an undeployed tracked conf is DRIFT (rc 1)" {
  local cap; cap=$'NWPCONF v1\nconfdir=present\nFccc.conf'
  run nginx_parity_check box "$FAKE_ROOT" "$(fakebox "$cap")"
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNDEPLOYED"* ]]
  [[ "$output" == *"mt.conf"* ]]
}

@test "check: an unreadable conf.d is CANNOT-VERIFY (rc 3), never parity" {
  local cap; cap=$'NWPCONF v1\nconfdir=unreadable'
  run nginx_parity_check box "$FAKE_ROOT" "$(fakebox "$cap")"
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "check: a probe with no banner is CANNOT-VERIFY, not empty-parity" {
  run nginx_parity_check box "$FAKE_ROOT" "$(fakebox 'total 0')"
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "check: a dead transport (nonzero probe) is CANNOT-VERIFY" {
  run nginx_parity_check box "$FAKE_ROOT" "sh -c 'exit 7'"
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
}

@test "check: no tracked baseline is CANNOT-VERIFY, not 'everything is a stray'" {
  local cap; cap=$'NWPCONF v1\nconfdir=present\nFccc.conf'
  run nginx_parity_check box "${TEST_TMP}/no-such-root" "$(fakebox "$cap")"
  [ "$status" -eq 3 ]
  [[ "$output" == *"CANNOT-VERIFY"* ]]
  [[ "$output" == *"baseline"* ]]
}
