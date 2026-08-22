#!/usr/bin/env bats
# `pl server backup <name>` — the control-host front door to box-level DR.
#
# THE THING THIS COMMAND MUST NEVER DO is bring the archive here. It is raw
# member data and this workstation is the dev/AI tier; NWP-ADR-0025 keeps the DR
# flow (raw → ver only) and the publish flow (sanitised → git host → dev)
# separate, and conflating them breaks the boundary the whole threat model
# rests on. So the first test is not about backups at all — it is about the
# absence of a download.
#
# The rest pin the two ways a backup verb lies: running heavy work on a box
# with no headroom (which is how the 3.8 GB forge box was OOM-killed on
# 2026-07-25), and reporting success without ever proving a restore.

setup() {
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  S="${REPO_ROOT}/scripts/commands/server.sh"
  TEST_ROOT="$(mktemp -d)"
  BIN="${TEST_ROOT}/bin"; mkdir -p "$BIN"
  mkdir -p "${TEST_ROOT}/servers/fake"
  cat > "${TEST_ROOT}/servers/fake/.nwp-server.yml" <<'YML'
---
schema_version: 1
server:
  name: fake
  ip: 203.0.113.9
  domain: example.invalid
  ssh_user: tester
  ssh_key: /dev/null
YML
  # A fake `ssh` that answers the two probes the verb makes before it does
  # anything, records every command it was asked to run, and reports the agent
  # as absent unless the test says otherwise.
  cat > "${BIN}/ssh" <<'SSH'
#!/usr/bin/env bash
cmd="${!#}"
printf '%s\n' "$cmd" >> "${FAKE_SSH_LOG}"
case "$cmd" in
  *"test -x /opt/nwp-server"*)
    [ "${FAKE_AGENT_INSTALLED:-0}" = 1 ] && exit 0
    exit 1 ;;
  *NWPHEALTH*|*MemAvailable*)
    echo "NWPHEALTH v1"
    echo "mem_total_mb=${FAKE_MEM_TOTAL:-3915}"
    echo "mem_avail_mb=${FAKE_MEM_AVAIL:-2200}"
    echo "swap_total_mb=2543"; echo "swap_free_mb=2400"
    echo "disk_avail_mb=${FAKE_DISK_AVAIL:-46000}"; echo "disk_pct=42"
    echo "load1=0.10"; echo "nproc=2"
    exit 0 ;;
  "echo ok") echo ok; exit 0 ;;
  *server-backup.sh*) echo "AGENT-INVOKED: $cmd"; exit 0 ;;
esac
exit 0
SSH
  chmod +x "${BIN}/ssh"
  export FAKE_SSH_LOG="${TEST_ROOT}/ssh.log"; : > "$FAKE_SSH_LOG"
  export NWP_DIR="${TEST_ROOT}" NWP_SERVERS_DIR="${TEST_ROOT}/servers"
  export PATH="${BIN}:${PATH}"
}
teardown() { rm -rf "${TEST_ROOT}"; }

# ── the boundary ─────────────────────────────────────────────────────────────

@test "the archive is never copied to this workstation" {
  # No scp, no `rsync` pulling from the box, no `restic ... --target` that
  # resolves locally. If this ever changes, raw member data lands in the AI
  # tier and NWP-ADR-0025's inviolable split is gone.
  run bash -c "sed -n '/^cmd_backup()/,/^}/p;/_srvbk_/,/^}/p' '$S' | grep -nE '(^|[^[:alnum:]])scp |rsync .*:.* [^:]*\$'"
  [ -z "$output" ]
}

@test "the code says, in words, why it does not pull the archive here" {
  grep -q 'It does not pull the archive to this' "$S"
}

# ── the preflight ────────────────────────────────────────────────────────────

@test "a box with no memory headroom is refused before any work starts" {
  export FAKE_MEM_AVAIL=64
  run bash "$S" backup fake
  [ "$status" -ne 0 ]
  [[ "$output" == *"NO HEADROOM"* ]] || [[ "$output" == *"REFUSING"* ]]
  # and it must not have reached the agent
  ! grep -q 'server-backup.sh' "$FAKE_SSH_LOG"
}

@test "a box with no disk headroom is refused" {
  export FAKE_DISK_AVAIL=100
  run bash "$S" backup fake
  [ "$status" -ne 0 ]
  [[ "$output" == *"disk headroom"* ]] || [[ "$output" == *"REFUSING"* ]]
}

@test "an unmeasurable box is refused, never treated as healthy" {
  # 'I could not look' is not 'it is fine'. This is the estate's standing rule
  # and the reason pl server health has a distinct exit 3.
  grep -q 'host_health_require' "$S"
  run bash -c "sed -n '/^cmd_backup()/,/^      install)/p' '$S' | grep -c 'host_health_require'"
  [ "$output" -ge 1 ]
}

# ── install gating ───────────────────────────────────────────────────────────

@test "a plan on a box without the agent tells you how to install it" {
  run bash "$S" backup fake
  [ "$status" -ne 0 ]
  [[ "$output" == *"not installed"* ]]
  [[ "$output" == *"--install"* ]]
}

@test "scheduling is refused when the agent is not installed" {
  # A cron entry pointing at a binary that is not there is a schedule that
  # reports nothing and backs up nothing.
  run bash "$S" backup fake --schedule
  [ "$status" -ne 0 ]
  [[ "$output" == *"not installed"* ]]
}

@test "the default action is a plan, not a backup" {
  export FAKE_AGENT_INSTALLED=1
  run bash "$S" backup fake
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]] || [[ "$output" == *"dry-run"* ]] || [[ "$output" == *"--execute"* ]]
  grep -q -- '--dry-run' "$FAKE_SSH_LOG"
  ! grep -q -- '--execute' "$FAKE_SSH_LOG"
}

@test "the plan invokes the ON-HOST agent, it does not reimplement it" {
  export FAKE_AGENT_INSTALLED=1
  run bash "$S" backup fake
  grep -q '/opt/nwp-server/scripts/commands/server-backup.sh --host' "$FAKE_SSH_LOG"
}

@test "the repo is named for the NWP server record, not the box's hostname" {
  # The live box is a clone of the forge box and still answers 'git' to
  # hostname -s. Filing the live estate's DR archive under 'git-system' is one
  # letter from the box it is not.
  export FAKE_AGENT_INSTALLED=1
  run bash "$S" backup fake
  grep -q 'fake-system' "$FAKE_SSH_LOG"
  ! grep -q 'git-system' "$FAKE_SSH_LOG"
}

@test "apt provenance is requested for the restic binary on every run" {
  export FAKE_AGENT_INSTALLED=1
  run bash "$S" backup fake
  grep -q -- '--restic-provenance apt' "$FAKE_SSH_LOG"
}

# ── the fate manifest ────────────────────────────────────────────────────────

@test "--execute renders a fate manifest naming the pruned snapshots" {
  grep -q 'impact_delete "\${server}: staging snapshots older than the newest' "$S"
  grep -q 'impact_render' "$S"
  grep -q 'impact_confirm' "$S"
}

@test "the manifest states that the archive does not survive loss of the host" {
  grep -q 'does not survive loss of that host' "$S"
}

@test "--purge-repo requires a TYPED confirmation, not a y/n" {
  # Deleting restic.pass makes every existing snapshot permanently unreadable.
  grep -q 'local level="standard"; (( purge_repo )) && level="typed"' "$S"
  grep -q 'permanently unreadable' "$S"
}

@test "uninstall keeps the repos and the password unless --purge-repo is given" {
  grep -q 'pass --purge-repo to remove them too' "$S"
}

# ── verification ─────────────────────────────────────────────────────────────

@test "--verify is restic check, and says it is not proof of recoverability" {
  grep -q 'check --read-data-subset' "$S"
  grep -q 'for recoverability' "$S"
}

@test "a failed restic check reports the repo as NOT a backup" {
  grep -q 'treat this repo as NOT a backup' "$S"
}

@test "the restore drill compares restored bytes against the live file" {
  # Restoring without comparing proves the archive is readable, not that it is
  # right. sha256 on both sides is the whole point.
  grep -q 'sha256sum "\\\$got"' "$S"
  grep -q 'archive \\\$a != live \\\$b' "$S"
}

@test "the restore drill samples across areas, not uniformly" {
  # 96% of the files are vendor trees; a uniform draw proves nothing about
  # /etc, /root or moodledata.
  grep -q 'STRATIFIED sample' "$S"
  grep -q "seen\[\\\\\$1\]++" "$S"
}

@test "the restore drill proves a database dump restores complete" {
  grep -q 'Dump completed' "$S"
  grep -q 'truncated or corrupt' "$S"
}

@test "a restore drill with no 'box' snapshot FAILS rather than passing vacuously" {
  grep -q 'FAIL: no snapshot tagged' "$S"
  grep -q 'lists no regular files' "$S"
}

@test "a missing state snapshot is reported as coverage NOT proven" {
  grep -q 'database coverage NOT proven' "$S"
}

# ── scheduling ───────────────────────────────────────────────────────────────

@test "the cron entry is derived from the same flags the verb uses" {
  # A hand-typed cron line is where the repo path, retention and provenance
  # drift away from what the verb actually does.
  grep -q 'cron_cmd+=" --repo \$(_srvbk_repo "\$server")' "$S"
  grep -q 'the ENTRY is derived, not typed' "$S"
}

@test "scheduling goes through pl host schedule, not a hand-rolled ssh write" {
  run bash -c "sed -n '/schedule|unschedule)/,/^      uninstall)/p' '$S' | grep -c 'host.sh\" schedule'"
  [ "$output" -ge 2 ]
}

@test "the default schedule avoids the existing 01:30 and demo-reset windows" {
  grep -q 'after the legacy 01:30 nwp-box-backup' "$S"
}

@test "pl server backup is wired into the dispatcher and the help text" {
  grep -q '^    backup)  cmd_backup' "$S"
  run bash "$S" help
  [[ "$output" == *"backup <name>"* ]]
  [[ "$output" == *"BOX-LEVEL disaster recovery"* ]]
}

@test "an unknown option is rejected rather than silently ignored" {
  run bash "$S" backup fake --scop=web
  [ "$status" -eq 2 ]
}

@test "a missing server name is a usage error, not a fleet-wide operation" {
  run bash "$S" backup
  [ "$status" -eq 2 ]
}
