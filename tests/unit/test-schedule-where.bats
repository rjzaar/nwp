#!/usr/bin/env bats
# ops#164 — `pl schedule where` must report cron-daemon state.
#
# During the 2026-08-01 box split a parked clone had its cron daemon
# deliberately stopped+disabled; `pl schedule where` still listed
# /etc/cron.d/nwp-box-backup with no hint that nothing could run it. The verb
# checked that the cron FILE exists, not that the daemon that would execute it
# is alive. These tests pin the fix:
#   - entries on a host whose daemon is inactive carry an INACTIVE flag and
#     force a nonzero exit (1);
#   - an unreadable daemon state is reported as blindness (UNKNOWN flag,
#     exit 3 — the `pl server health` cannot-measure precedent), never as
#     active;
#   - UNREACHABLE-host behaviour is unchanged.
#
# Boundary stubbing: schedule.sh computes PROJECT_ROOT from its own location,
# so each test runs a copy of the real script inside a sandbox tree whose
# lib/{server-resolver,host-capture}.sh are stubs, with PATH-shimmed
# crontab/systemctl for the LOCAL block.

SCHEDULE_SH="${BATS_TEST_DIRNAME}/../../scripts/commands/schedule.sh"

setup() {
  TEST_TMP=$(mktemp -d)
  mkdir -p "$TEST_TMP/scripts/commands" "$TEST_TMP/lib" "$TEST_TMP/bin"
  cp "$SCHEDULE_SH" "$TEST_TMP/scripts/commands/schedule.sh"

  cat > "$TEST_TMP/lib/ui.sh" <<'EOF'
BOLD=""; NC=""
print_header()  { echo "== $*"; }
print_status()  { echo "$1 $2"; }
print_info()    { echo "$*"; }
print_warning() { echo "WARN: $*"; }
print_error()   { echo "ERROR: $*"; }
EOF
  : > "$TEST_TMP/lib/common.sh"

  cat > "$TEST_TMP/lib/server-resolver.sh" <<'EOF'
discover_servers() { printf '%s\n' "${STUB_SERVERS:-live}"; }
EOF

  # Boundary stub: emulates the remote side of host_run. If the script the
  # verb ships contains the systemctl daemon probe, answer it with a
  # DAEMON:<state> line (STUB_REMOTE_DAEMON=missing suppresses the line —
  # a host whose daemon state could not be read); then emit the cron.d
  # listing. The pre-ops#164 script shipped no probe, so the stub emitted no
  # daemon line — exactly the old blindness.
  cat > "$TEST_TMP/lib/host-capture.sh" <<'EOF'
host_resolve_dest() {
  [ "${STUB_UNRESOLVABLE:-}" = "1" ] && return 1
  echo "STUBSSH"
}
host_run() {
  local prefix="$1" script="$2"
  [ "${STUB_UNREACHABLE:-}" = "1" ] && return 255
  if printf '%s' "$script" | grep -q 'systemctl is-active'; then
    if [ "${STUB_REMOTE_DAEMON:-active}" != "missing" ]; then
      echo "DAEMON:${STUB_REMOTE_DAEMON:-active}"
    fi
  fi
  [ -n "${STUB_CRON_FILES:-}" ] && printf '%s\n' "$STUB_CRON_FILES"
  return 0
}
EOF

  cat > "$TEST_TMP/bin/crontab" <<'EOF'
#!/bin/bash
[ "$1" = "-l" ] || exit 1
[ -n "${STUB_LOCAL_CRON:-}" ] && printf '%s\n' "$STUB_LOCAL_CRON"
exit 0
EOF
  cat > "$TEST_TMP/bin/systemctl" <<'EOF'
#!/bin/bash
# is-active [--quiet] <unit> — state driven by STUB_LOCAL_DAEMON
[ "${STUB_LOCAL_DAEMON:-active}" = "active" ] && exit 0
exit 3
EOF
  chmod +x "$TEST_TMP/bin/crontab" "$TEST_TMP/bin/systemctl"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# Run the sandboxed `schedule where` with stub state supplied as VAR=val args.
run_where() {
  run env "$@" PATH="$TEST_TMP/bin:$PATH" \
    bash "$TEST_TMP/scripts/commands/schedule.sh" where
}

################################################################################
# Sanity
################################################################################

@test "schedule.sh parses (bash -n)" {
  run bash -n "$SCHEDULE_SH"
  [ "$status" -eq 0 ]
}

################################################################################
# Remote hosts — the box-split blindness itself
################################################################################

@test "RED->GREEN: entry on host with INACTIVE cron daemon is flagged and exit is 1" {
  run_where STUB_CRON_FILES="nwp-box-backup" STUB_REMOTE_DAEMON="inactive"
  [[ "$output" == *"/etc/cron.d/nwp-box-backup"* ]]
  [[ "$output" == *"cron INACTIVE — will not run"* ]]
  [ "$status" -eq 1 ]
}

@test "flag is appended AFTER the schedule path — columns stay parse-stable" {
  run_where STUB_CRON_FILES="nwp-box-backup" STUB_REMOTE_DAEMON="inactive"
  echo "$output" | grep -Eq '^live[[:space:]]+remote[[:space:]]+/etc/cron\.d/nwp-box-backup \(cron INACTIVE'
}

@test "entry on host with ACTIVE cron daemon carries no flag and exit is 0" {
  run_where STUB_CRON_FILES="nwp-box-backup" STUB_REMOTE_DAEMON="active"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/etc/cron.d/nwp-box-backup"* ]]
  [[ "$output" != *"INACTIVE"* ]]
  [[ "$output" != *"UNKNOWN"* ]]
}

@test "unreadable daemon state is blindness: UNKNOWN flag, exit 3 — never treated as active" {
  run_where STUB_CRON_FILES="nwp-box-backup" STUB_REMOTE_DAEMON="missing"
  [[ "$output" == *"/etc/cron.d/nwp-box-backup"* ]]
  [[ "$output" == *"could not read daemon"* ]]
  [ "$status" -eq 3 ]
}

@test "host with NO entries and a dead daemon does not poison the exit code" {
  run_where STUB_CRON_FILES="" STUB_REMOTE_DAEMON="inactive"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no /etc/cron.d NWP entries"* ]]
}

@test "UNREACHABLE host behaviour is unchanged (blindness line, exit untouched)" {
  run_where STUB_UNREACHABLE=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNREACHABLE"* ]]
  [[ "$output" == *"NOT 'none'"* ]]
}

################################################################################
# LOCAL block — same honesty, for symmetry
################################################################################

@test "RED->GREEN: local entries with local cron daemon inactive are flagged, exit 1" {
  run_where STUB_LOCAL_CRON="0 2 * * * /home/x/nwp/pl backup sweep" \
            STUB_LOCAL_DAEMON="inactive" STUB_CRON_FILES=""
  [[ "$output" == *"pl backup sweep"* ]]
  [[ "$output" == *"cron INACTIVE — will not run"* ]]
  [ "$status" -eq 1 ]
}

@test "local entries with local cron daemon active carry no flag, exit 0" {
  run_where STUB_LOCAL_CRON="0 2 * * * /home/x/nwp/pl backup sweep" \
            STUB_LOCAL_DAEMON="active" STUB_CRON_FILES=""
  [ "$status" -eq 0 ]
  [[ "$output" != *"INACTIVE"* ]]
}

################################################################################
# Pure helper — schedule_annotate_daemon_state maps state -> (suffix, rc)
################################################################################

helper() {  # helper <state> -> prints "<suffix>|<rc>"
  bash -c "source '$TEST_TMP/scripts/commands/schedule.sh'
           rc=0; out=\$(schedule_annotate_daemon_state '$1') || rc=\$?
           printf '%s|%s' \"\$out\" \"\$rc\""
}

@test "annotate: active -> empty suffix, rc 0" {
  run helper active
  [ "$output" = "|0" ]
}

@test "annotate: inactive -> INACTIVE suffix, rc 1" {
  run helper inactive
  [ "$output" = " (cron INACTIVE — will not run)|1" ]
}

@test "annotate: unknown/empty -> UNKNOWN suffix, rc 3 (server-health cannot-measure precedent)" {
  run helper unknown
  [ "$output" = " (cron state UNKNOWN — could not read daemon)|3" ]
  run helper ""
  [ "$output" = " (cron state UNKNOWN — could not read daemon)|3" ]
}

@test "annotate: any other non-active state (failed) counts as INACTIVE, rc 1" {
  run helper failed
  [ "$output" = " (cron INACTIVE — will not run)|1" ]
}

@test "rc combine: dead daemon (1) beats blind (3) beats clean (0)" {
  run bash -c "source '$TEST_TMP/scripts/commands/schedule.sh'
               printf '%s %s %s %s' \
                 \"\$(schedule_rc_combine 0 0)\" \"\$(schedule_rc_combine 0 3)\" \
                 \"\$(schedule_rc_combine 3 1)\" \"\$(schedule_rc_combine 1 3)\""
  [ "$output" = "0 3 1 1" ]
}

################################################################################
# Wiring — the real script must actually ship the probe and use the helper
################################################################################

@test "cmd_schedule_where ships the systemctl daemon probe (cron OR crond)" {
  grep -q 'systemctl is-active' "$SCHEDULE_SH"
  grep -Eq 'systemctl is-active[^&|]*crond' "$SCHEDULE_SH"
}

@test "cmd_schedule_where calls schedule_annotate_daemon_state for both blocks" {
  # At least two call sites inside cmd_schedule_where (local + remote).
  local calls
  calls=$(awk '/^cmd_schedule_where\(\)/{f=1} f && /schedule_annotate_daemon_state /{n++} f && /^}/{f=0} END{print n+0}' "$SCHEDULE_SH")
  [ "$calls" -ge 2 ]
}
