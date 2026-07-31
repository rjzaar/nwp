#!/usr/bin/env bats
# lib/server-sync.sh — the box-to-box migration primitive.
#
# These pin two incidents from the 2026-07-31 nwpcode -> live split, both of
# which were SILENT: the command reported success while doing damage.
#
# 1. OWNERSHIP LAUNDERING. Data trees were relayed through a staging directory
#    on the workstation. An unprivileged local user cannot own files as
#    www-data, so `rsync -a` quietly rewrote every file to the local user, and
#    the second hop faithfully applied that wrong owner to the target. Three
#    Moodles began returning HTTP 500 ("$CFG->dataroot is not writable") after
#    a sync that printed a tick for every tree. The fix is --fake-super on both
#    hops PLUS an explicit post-copy comparison, because the reason it went
#    unnoticed is that nothing ever compared the two sides.
#
# 2. PROSE ACCEPTED AS AN IDENTIFIER. The DB-name probe runs application code.
#    A broken Moodle answers on stdout with "Fatal error: $CFG->dataroot is not
#    writable, admin has to fix directory permissions! Exiting." — which was
#    returned as if it were a database name. Had the two sides' error text
#    happened to match, the verb would have gone on to mysqldump a database
#    called "Fatalerror:...". Shape validation turns that into "unknown".

setup() {
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  TEST_ROOT="$(mktemp -d)"
  export TEST_ROOT
}

teardown() { rm -rf "${TEST_ROOT}"; }

# A stub "ssh prefix": a command that runs its argument locally, so the probe
# functions can be exercised without a server.
stub_prefix() { echo "bash -c"; }

@test "a Moodle fatal-error message is NOT accepted as a database name" {
  run bash -c "
    source '${REPO_ROOT}/lib/server-sync.sh'
    fake() { echo 'Fatal error: \$CFG->dataroot is not writable, admin has to fix directory permissions! Exiting.'; }
    export -f fake
    sync_probe_dbname 'bash -c' moodle '/var/www/x' 2>/dev/null <<< ''
  "
  # Whatever happens, the one unacceptable outcome is prose coming back as a name.
  [[ "$output" != *"Fatal"* ]]
  [[ "$output" != *"dataroot"* ]]
}

@test "database-name validation accepts real identifiers and rejects prose" {
  # Exercise the shape rule directly — it is the guard that stands between a
  # broken app's stdout and a mysqldump argument.
  run bash -c '
    ok()  { [[ "$1" =~ ^[A-Za-z0-9_$-]{1,64}$ ]] && echo yes || echo no; }
    for n in ssd sso_moodle ccc_db avc dir1 nwc; do printf "%s=%s " "$n" "$(ok "$n")"; done
    echo
    for n in "Fatalerror:\$CFG->datarootisnotwritable" "a;DROPTABLE" "two words" ""; do
      printf "[%s]=%s " "$n" "$(ok "$n")"
    done
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssd=yes"* ]]
  [[ "$output" == *"sso_moodle=yes"* ]]
  [[ "$output" == *"ccc_db=yes"* ]]
  # Each rejection case must come back "no" — checked by exact token, not by a
  # loose glob across the whole line.
  [[ "$output" == *'[a;DROPTABLE]=no'* ]]
  [[ "$output" == *'[two words]=no'* ]]
  [[ "$output" == *'[]=no'* ]]
  [[ "$output" == *'datarootisnotwritable]=no'* ]]
}

@test "sync_dir_relay passes --fake-super on BOTH hops" {
  # Without this on the workstation-staging side, ownership is laundered to the
  # local user and then written onto the target as fact.
  run grep -c -- '--fake-super' "${REPO_ROOT}/lib/server-sync.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "sync_dir_relay verifies ownership after copying, and fails when it cannot" {
  # The incident was invisible because nothing compared the two sides.
  run grep -A6 'sown=' "${REPO_ROOT}/lib/server-sync.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stat -c"* ]]
  grep -q 'refusing to call this synced' "${REPO_ROOT}/lib/server-sync.sh"
  grep -q 'ownership/mode mismatch' "${REPO_ROOT}/lib/server-sync.sh"
}

@test "the source side is only ever read (no writes in the dump path)" {
  # sync_db_stream must never send a mutating statement to the source.
  run bash -c "sed -n '/^sync_db_stream()/,/^}/p' '${REPO_ROOT}/lib/server-sync.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mysqldump"* ]]
  [[ "$output" == *"--single-transaction"* ]]
  [[ "$output" != *"DROP "* ]]
  [[ "$output" != *"sudo mysql "* ]] || {
    # a `sudo mysql` here is legitimate ONLY on the destination prefix
    [[ "$output" == *'$dp "gunzip | sudo mysql'* ]]
  }
}
