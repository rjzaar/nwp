#!/usr/bin/env bats
# `nwp-server backup --host` + lib/server-backup-host.sh — the BOX scope (ADR-0025).
#
# WHAT THESE PIN, AND WHY THEY ARE THE TESTS THEY ARE
#
# The gap this scope closes was not "no backups". On 2026-08-01 the box serving
# every live site had per-site snapshots, a git-tracked config inventory, and a
# nightly cron dumping 16 databases. What it did not have was any archive from
# which the HOST could be rebuilt, and — because nothing verified the chain —
# no way to notice. So the failure mode these tests are written against is not
# "the backup errors out". It is "the backup succeeds and is missing something",
# which is only discovered during a restore, which is the worst possible time.
#
# Hence: every partial-read path must FAIL rather than emit a short archive.

setup() {
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  S="${REPO_ROOT}/scripts/commands/server-backup.sh"
  L="${REPO_ROOT}/lib/server-backup-host.sh"
  TEST_ROOT="$(mktemp -d)"
  # A path set this file OWNS. Asserting against the real /etc and /var/www made
  # the plan's contents a property of the machine: a runner without /var/www
  # produced different output than a laptop with one. The DEFAULTS are pinned
  # separately, by reading them out of the library.
  mkdir -p "${TEST_ROOT}/box/etc" "${TEST_ROOT}/box/opt" "${TEST_ROOT}/box/www"
  export SBH_DEFAULT_PATHS="${TEST_ROOT}/box/etc ${TEST_ROOT}/box/opt"
  WEB="${TEST_ROOT}/box/www"
  # Neither restic nor mysqldump is assumed. Every test that cares says so.
  unset NWP_RESTIC_BIN NWP_SBH_ABSENT
}
teardown() { rm -rf "${TEST_ROOT}"; }

# The runner has no restic; this laptop does. Both conditions are reachable from
# either machine, so neither can quietly decide what a test proves.
RESTIC_ABSENT="/nonexistent/restic-not-installed"

# ── the scope itself ─────────────────────────────────────────────────────────

@test "--host and --site-dir are refused together (two scopes, pick one)" {
  run bash "$S" --host --site-dir /tmp/nope --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"different scopes"* ]]
}

@test "the DEFAULT box paths are /etc, /usr/local, /root, /opt, /var/www" {
  # Read off the library, not off whatever this machine happens to have.
  run bash -c "unset SBH_DEFAULT_PATHS; source '$L'; echo \$SBH_DEFAULT_PATHS"
  [ "$output" = "/etc /usr/local /root /opt /var/www" ]
}

@test "--host plans every configured path plus the web root" {
  run bash "$S" --host --web-root="$WEB" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"${TEST_ROOT}/box/etc"* ]]
  [[ "$output" == *"${TEST_ROOT}/box/opt"* ]]
  [[ "$output" == *"${WEB}"* ]]
}

@test "--host writes to a DISTINCT <name>-system repo, never a site repo" {
  run bash "$S" --host --web-root="$WEB" --dry-run
  [[ "$output" == *"-system"* ]]
}

@test "--scope rejects anything that is not config, db or web" {
  run bash "$S" --host --scope=config,secrets --web-root="$WEB" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"config, db or web"* ]]
}

@test "a --extra-path that does not exist is a hard failure, not a warning" {
  # Silently dropping a path the operator explicitly named is how an archive
  # comes to be missing the one tree they added it for.
  run bash "$S" --host --extra-path=/definitely/not/here --web-root="$WEB" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "paths that are absent are REPORTED, not silently dropped" {
  grep -q 'NOT in this backup (path absent)' "$S"
}

@test "/home's exclusion is stated in the plan rather than left implicit" {
  # A statement about the scope. It must not depend on whether THIS host has a
  # /home — that gating is what made the original version machine-specific.
  run bash "$S" --host --web-root="$WEB" --dry-run
  [[ "$output" == *"/home is not in the default scope"* ]]
}

# ── the disk guard ───────────────────────────────────────────────────────────

@test "refuses when the projected worst case would fill the filesystem" {
  # The box this ships to serves 15 sites on one 78 GB disk. A backup that
  # fills / is a site-down incident; an aborted backup is not.
  run bash "$S" --host --scope=config --min-free-mb=99999999 --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing"* ]]
  [[ "$output" == *"MB free"* ]]
}

@test "--force-disk overrides the guard but says so out loud" {
  run bash "$S" --host --scope=config --min-free-mb=99999999 --force-disk --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"--force-disk"* ]]
}

# ── restic provenance ────────────────────────────────────────────────────────

@test "--restic-provenance rejects an unknown mode WHETHER OR NOT restic is installed" {
  # The bug this pins: verify_restic returned early on "restic not found", so on
  # any host without restic a typo'd mode was silently ACCEPTED. Whether an
  # argument is legal is a property of the command, never of the machine — and
  # this one governs a supply-chain check, so failing open is the wrong way.
  local cond
  for cond in present absent; do
    if [ "$cond" = absent ]; then export NWP_RESTIC_BIN="$RESTIC_ABSENT"; else unset NWP_RESTIC_BIN; fi
    run bash "$S" --host --web-root="$WEB" --restic-provenance=trustme --dry-run
    [ "$status" -ne 0 ] || { echo "restic ${cond}: a bogus mode was ACCEPTED"; return 1; }
    [[ "$output" == *"minisign, apt or none"* ]] \
      || { echo "restic ${cond}: refused for the wrong reason: $output"; return 1; }
  done
  unset NWP_RESTIC_BIN
}

@test "'none' provenance is loud WHETHER OR NOT restic is installed" {
  # "I could not check" and "I chose not to check" are different sentences, and
  # the operator needs the second one even on a host where the binary is absent.
  local cond
  for cond in present absent; do
    if [ "$cond" = absent ]; then export NWP_RESTIC_BIN="$RESTIC_ABSENT"; else unset NWP_RESTIC_BIN; fi
    run bash "$S" --host --web-root="$WEB" --restic-provenance=none --dry-run
    [[ "$output" == *"UNVERIFIED"* ]] \
      || { echo "restic ${cond}: the unverified posture was never stated"; return 1; }
  done
  unset NWP_RESTIC_BIN
}

@test "an absent restic is reported as absent, not as verified" {
  export NWP_RESTIC_BIN="$RESTIC_ABSENT"
  run bash "$S" --host --web-root="$WEB" --restic-provenance=apt --dry-run
  [[ "$output" == *"restic not found"* ]]
  [[ "$output" != *"provenance: dpkg package"* ]]
  unset NWP_RESTIC_BIN
}

@test "an absent restic is FATAL on a live run, in every provenance mode" {
  # --dry-run tolerates a missing binary; --execute must not, or the verb
  # reports a backup it never took.
  local mode
  export NWP_RESTIC_BIN="$RESTIC_ABSENT"
  for mode in apt none minisign; do
    run bash "$S" --host --web-root="$WEB" --restic-provenance="$mode" --execute
    [ "$status" -ne 0 ] || { echo "mode ${mode}: --execute survived a missing restic"; return 1; }
  done
  unset NWP_RESTIC_BIN
}

@test "apt provenance re-checks the on-disk binary against what dpkg installed" {
  # The claim is 'nothing overwrote this binary after apt installed it'. If the
  # check does not actually compare checksums it is a slogan, not a control.
  grep -q 'md5sums' "$S"
  grep -q 'does NOT match the checksum' "$S"
}

@test "--skip-restic-verify still works, as an alias for provenance none" {
  grep -q 'SKIP_RESTIC_VERIFY=y; RESTIC_PROVENANCE=none' "$S"
}

# ── the library: partial reads must fail ─────────────────────────────────────

@test "sbh_list_databases fails when there is no mysql client at all" {
  # Prepending a nonexistent directory to PATH does NOT remove mysql from it —
  # the original version of this test did that and was passing for a different
  # reason on each machine. Name the condition.
  run bash -c "NWP_SBH_ABSENT=mysql; source '$L'; sbh_list_databases"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "sbh_list_databases fails when the client is there but the server is not" {
  # An empty list read as 'this box has no databases' would produce a DR
  # archive with no data in it and a green tick on the console.
  run bash -c "
    source '$L'
    _sbh_have(){ return 0; }
    mysql(){ return 1; }
    sbh_list_databases
  "
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "sbh_dump_databases refuses an empty database list" {
  # STATE the tooling condition. Without the _sbh_have stub this passed on a
  # laptop with mysqldump (reaching the empty-list guard) and failed on a runner
  # without it (stopping at the mysqldump guard) — asserting a refusal that the
  # second run never got near.
  run bash -c "
    source '$L'
    _sbh_have(){ return 0; }
    sbh_list_databases(){ printf ''; return 0; }
    sbh_dump_databases '${TEST_ROOT}/db'
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"EMPTY"* ]]
}

@test "sbh_dump_databases refuses when mysqldump is missing, and says which" {
  # The other side of the same coin, made reachable from a host that HAS
  # mysqldump. Two distinct refusals, each pinned to its own cause.
  run bash -c "
    NWP_SBH_ABSENT=mysqldump
    source '$L'
    sbh_list_databases(){ echo onedb; }
    sbh_dump_databases '${TEST_ROOT}/db'
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"mysqldump not found"* ]]
  [[ "$output" != *"EMPTY"* ]]
}

@test "NWP_SBH_ABSENT makes a tool-missing branch reachable from a host that has it" {
  # The override itself is under test: if it stops working, the runner-condition
  # tests above quietly start asserting the laptop's behaviour again.
  run bash -c "source '$L'; NWP_SBH_ABSENT=bash _sbh_have bash && echo REACHABLE || echo ABSENT"
  [ "$output" = "ABSENT" ]
  run bash -c "source '$L'; _sbh_have bash && echo PRESENT || echo ABSENT"
  [ "$output" = "PRESENT" ]
}

@test "sbh_dump_databases rejects a truncated dump that is still valid gzip" {
  # This is the real trap: mysqldump can die mid-stream and gzip will happily
  # produce a well-formed archive of the half it got. Only the 'Dump completed'
  # trailer distinguishes the two.
  run bash -c "
    source '$L'
    sbh_list_databases(){ echo onedb; }
    _sbh_have(){ return 0; }
    mysqldump(){ echo '-- partial dump, no trailer'; }
    export -f mysqldump
    sbh_dump_databases '${TEST_ROOT}/db'
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"truncated"* ]]
}

@test "sbh_dump_databases accepts a dump carrying the completion trailer" {
  run bash -c "
    source '$L'
    sbh_list_databases(){ echo onedb; }
    _sbh_have(){ return 0; }
    mysqldump(){ echo 'CREATE TABLE t (i int);'; echo '-- Dump completed on 2026-08-02'; }
    export -f mysqldump
    sbh_dump_databases '${TEST_ROOT}/db'
  "
  [ "$status" -eq 0 ]
  [ -f "${TEST_ROOT}/db/onedb.sql.gz" ]
}

@test "system schemas are never dumped as data" {
  run bash -c "source '$L'; printf '%s\n' information_schema performance_schema sys mysql avc \
    | grep -Ev \"\$SBH_SYSTEM_DBS_RE\""
  [ "$output" = "avc" ]
}

@test "sbh_write_manifest records what it could NOT read" {
  # A manifest that quietly omits the grants restores a box where every site
  # returns a database error. The gap has to be inside the archive.
  grep -q 'UNREADABLE.txt' "$L"
  grep -q '_sbh_note "mysql grants"' "$L"
}

@test "the manifest captures the pieces a per-site backup cannot" {
  for needle in dpkg-selections systemd-enabled 'nginx -T' crontabs grants.sql; do
    grep -q -- "$needle" "$L" || { echo "manifest is missing: $needle"; return 1; }
  done
}

@test "sbh_size_mb reports failure when it cannot measure anything" {
  run bash -c "source '$L'; sbh_size_mb /definitely/not/here"
  [ "$status" -ne 0 ]
}

@test "the staged plaintext dumps are shredded after the snapshot" {
  # Between the dump and the snapshot there is a directory of unencrypted
  # member data on a live box. It does not get to survive the run.
  grep -q 'shred -u' "$S"
}

@test "the staging path is fixed, not mktemp — snapshots must dedup across runs" {
  grep -q 'staging="/var/backups/nwp-server/.staging/' "$S"
}

@test "no recursive rm ships in the prod artifact's backup verb" {
  # scripts/commands/server-backup.sh runs as root on a host serving 15 sites.
  run bash -c "grep -nE '(^|[^[:alnum:]_.-])rm([[:space:]]+-[[:alnum:]-]+)*[[:space:]]+-[[:alnum:]]*[rR]' '$S' | grep -v '^[0-9]*:[[:space:]]*#'"
  [ -z "$output" ]
}

@test "the box scope ships in the AI-free artifact allowlist" {
  grep -q '^lib/server-backup-host.sh$' "${REPO_ROOT}/build/nwp-server.include"
}

@test "the artifact still passes the fail-closed deny-scan with the box scope in it" {
  run bash "${REPO_ROOT}/scripts/build-nwp-server.sh" --out "${TEST_ROOT}/artifact"
  [ "$status" -eq 0 ]
  [[ "$output" == *"deny-scan PASSED"* ]]
  [ -f "${TEST_ROOT}/artifact/lib/server-backup-host.sh" ]
}

# ── the per-site scope must not have regressed ───────────────────────────────

@test "the per-site scope still requires --site-dir and still names --host" {
  run bash "$S" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--site-dir is required"* ]]
  [[ "$output" == *"--host"* ]]
}

@test "the staging directory is 0700 at BOTH levels" {
  # It holds unencrypted database dumps for the seconds between mysqldump and
  # restic, on a box with 15 sites and several service accounts.
  grep -q 'install -d -m 700 "$(dirname "${staging:?}")" "$staging"' "$S"
}
