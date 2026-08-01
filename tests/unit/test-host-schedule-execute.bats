#!/usr/bin/env bats
# `pl host schedule <target> install|remove --execute` — remote cron, for real.
#
# This path was a deliberate stub: it printed the entry it would write and then
# said "an operator installs it and records it". That made every verb needing a
# remote schedule impossible to finish through `pl`, and the estate's standing
# order is to fix the verb rather than reach for `ssh ... | sudo tee`. Enabling
# it also means these failure modes now matter:
#
#   * a malformed cron line is NOT rejected loudly by cron. It is skipped. The
#     schedule you believe you installed simply never runs, forever, silently.
#   * a cron FILE is not a SCHEDULE. During the 2026-08-01 box split a parked
#     clone had cron stopped and disabled; a file sitting on a dead daemon
#     looked exactly like a working one (ops#164).
#   * a write's exit status is not proof the file is there.

setup() {
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  H="${REPO_ROOT}/scripts/commands/host.sh"
  TEST_ROOT="$(mktemp -d)"
  BIN="${TEST_ROOT}/bin"; mkdir -p "$BIN"
  mkdir -p "${TEST_ROOT}/servers/fake"
  cat > "${TEST_ROOT}/servers/fake/.nwp-server.yml" <<'YML'
---
schema_version: 1
server:
  name: fake
  ip: 203.0.113.9
  ssh_user: tester
  ssh_key: /dev/null
YML
  # A fake `ssh` that executes the script it is handed against a sandbox root,
  # so the heredoc, the install(1) call and the read-back are all exercised for
  # real rather than pattern-matched.
  cat > "${BIN}/ssh" <<'SSH'
#!/usr/bin/env bash
script="${!#}"
printf '%s\n' "$script" >> "${FAKE_SSH_LOG}"
# Sandbox surgery, all of it deliberate and all of it here rather than in the
# code under test: /etc/cron.d becomes a temp dir, `sudo -n` disappears, and
# root ownership is dropped because bats does not run as root. Everything that
# remains — the heredoc, install(1)'s mode, the read-back, the daemon probe —
# runs for real.
script="${script//\/etc\/cron.d/${FAKE_ROOT}/etc/cron.d}"
script="${script//sudo -n /}"
script="${script//-o root -g root /}"
mkdir -p "${FAKE_ROOT}/etc/cron.d"
systemctl() { echo "${FAKE_CRON_STATE:-active}"; }
export -f systemctl
bash -c "$script"
SSH
  chmod +x "${BIN}/ssh"
  export FAKE_ROOT="${TEST_ROOT}/root"; mkdir -p "${FAKE_ROOT}/etc/cron.d"
  export FAKE_SSH_LOG="${TEST_ROOT}/ssh.log"; : > "$FAKE_SSH_LOG"
  export NWP_DIR="${TEST_ROOT}" NWP_SERVERS_DIR="${TEST_ROOT}/servers"
  export PATH="${BIN}:${PATH}"
}
teardown() { rm -rf "${TEST_ROOT}"; }

# ── validation happens BEFORE anything is written ────────────────────────────

@test "a schedule with the wrong number of fields is refused" {
  run bash "$H" schedule fake install --name=x --schedule="0 4 * *" --command=/bin/true --execute
  [ "$status" -eq 2 ]
  [[ "$output" == *"5 (or 6"* ]]
  [ -z "$(ls -A "${FAKE_ROOT}/etc/cron.d")" ]
}

@test "a schedule containing shell metacharacters is refused" {
  # Five fields, so the field-count guard does NOT fire — this is the character
  # class doing the work. `;` in a cron expression is either a typo or an
  # injection attempt, and neither belongs in /etc/cron.d.
  run bash "$H" schedule fake install --name=x --schedule='0 4 * * *;rm' --command=/bin/true --execute
  [ "$status" -eq 2 ]
  [[ "$output" == *"cron does not accept"* ]]
  [ -z "$(ls -A "${FAKE_ROOT}/etc/cron.d")" ]
}

@test "a relative command is refused (cron has no useful PATH)" {
  run bash "$H" schedule fake install --name=x --schedule="0 4 * * *" --command="backup.sh" --execute
  [ "$status" -eq 2 ]
  [[ "$output" == *"ABSOLUTE"* ]]
}

@test "a multi-line command is refused — it would forge a second crontab line" {
  run bash "$H" schedule fake install --name=x --schedule="0 4 * * *" \
      --command="$(printf '/bin/true\n0 5 * * * root /bin/evil')" --execute
  [ "$status" -eq 2 ]
  [[ "$output" == *"single line"* ]]
}

@test "a command containing the heredoc delimiter is refused" {
  run bash "$H" schedule fake install --name=x --schedule="0 4 * * *" \
      --command="/bin/true NWPCRONEOF" --execute
  [ "$status" -eq 2 ]
}

@test "a six-field (with year) schedule is accepted" {
  run bash "$H" schedule fake install --name=six --schedule="0 4 * * * 2026" --command=/bin/true --execute
  [ "$status" -eq 0 ]
}

# ── dry run is still the default ─────────────────────────────────────────────

@test "without --execute nothing is written" {
  run bash "$H" schedule fake install --name=dry --schedule="20 4 * * *" --command=/bin/true
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  [ ! -f "${FAKE_ROOT}/etc/cron.d/nwp-dry" ]
}

# ── the write ────────────────────────────────────────────────────────────────

@test "--execute writes one managed file with SHELL, PATH and the entry" {
  run bash "$H" schedule fake install --name=dr --schedule="20 4 * * *" \
      --command="/opt/nwp-server/scripts/commands/server-backup.sh --host --execute" --execute
  [ "$status" -eq 0 ]
  local f="${FAKE_ROOT}/etc/cron.d/nwp-dr"
  [ -f "$f" ]
  grep -q '^SHELL=/bin/bash$' "$f"
  grep -q '^PATH=/usr/local/sbin:' "$f"
  grep -q '^20 4 \* \* \* root /opt/nwp-server/scripts/commands/server-backup.sh --host --execute$' "$f"
}

@test "the managed file says how to remove it" {
  bash "$H" schedule fake install --name=dr --schedule="20 4 * * *" --command=/bin/true --execute
  grep -q 'pl host schedule <target> remove --name=dr' "${FAKE_ROOT}/etc/cron.d/nwp-dr"
}

@test "re-installing rewrites rather than appending a duplicate entry" {
  bash "$H" schedule fake install --name=dr --schedule="20 4 * * *" --command=/bin/true --execute
  bash "$H" schedule fake install --name=dr --schedule="40 5 * * *" --command=/bin/true --execute
  local n; n=$(grep -c 'root /bin/true' "${FAKE_ROOT}/etc/cron.d/nwp-dr")
  [ "$n" -eq 1 ]
  grep -q '^40 5 ' "${FAKE_ROOT}/etc/cron.d/nwp-dr"
}

@test "the entry is verified by reading it BACK, not by trusting the write" {
  grep -q 'Verify by READING BACK' "$H"
  grep -q 'is not present on .* after install' "$H"
}

# ── a file is not a schedule ─────────────────────────────────────────────────

@test "a stopped cron daemon makes the install a FAILURE, not a success" {
  export FAKE_CRON_STATE=inactive
  run bash "$H" schedule fake install --name=dr --schedule="20 4 * * *" --command=/bin/true --execute
  [ "$status" -ne 0 ]
  [[ "$output" == *"will NOT run"* ]]
}

@test "an unreadable daemon state warns and refuses to be recorded as scheduled" {
  export FAKE_CRON_STATE=unknown
  run bash "$H" schedule fake install --name=dr --schedule="20 4 * * *" --command=/bin/true --execute
  [[ "$output" == *"could not be read"* ]]
  [[ "$output" == *"do NOT record this as scheduled"* ]]
}

# ── remove ───────────────────────────────────────────────────────────────────

@test "remove --execute deletes the managed file and confirms it is gone" {
  bash "$H" schedule fake install --name=dr --schedule="20 4 * * *" --command=/bin/true --execute
  [ -f "${FAKE_ROOT}/etc/cron.d/nwp-dr" ]
  run bash "$H" schedule fake remove --name=dr --execute
  [ "$status" -eq 0 ]
  [ ! -f "${FAKE_ROOT}/etc/cron.d/nwp-dr" ]
}

@test "removing an absent entry is not an error (idempotent)" {
  run bash "$H" schedule fake remove --name=never-existed --execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"was not present"* ]]
}

@test "remove without --execute leaves the file alone" {
  bash "$H" schedule fake install --name=dr --schedule="20 4 * * *" --command=/bin/true --execute
  run bash "$H" schedule fake remove --name=dr
  [ "$status" -eq 0 ]
  [ -f "${FAKE_ROOT}/etc/cron.d/nwp-dr" ]
}

@test "the schedule stub refusal is gone" {
  # `pl host apply` is still a stub on purpose; `pl host schedule` is not.
  run bash -c "sed -n '/^cmd_schedule()/,/^}/p' '$H' | grep -c 'is not enabled in this release'"
  [ "$output" = "0" ]
}
