#!/usr/bin/env bats
# nwp/ops#332 — the nightly box backup producer may not report success on a leg
# it never ran.
#
# THE BUG THESE TESTS EXIST TO KEEP DEAD. `nwp-box-backup.sh` enumerated the
# site databases with
#
#     for db in $(mysql -N -e "SHOW DATABASES" 2>>"$LOG" | ...); do
#
# under `set -u` with no `set -e` and no `set -o pipefail`. When mysql could not
# connect, the command substitution was EMPTY, the loop body never ran, and the
# script walked on to `log "done"` and exit 0. A zero-iteration loop read as a
# successful backup. On the forge box that state persisted from 2026-08-04 to
# 2026-08-10 and every night reported success.
#
# These tests DRIVE THE REAL SCRIPT with fake `mysql`/`mysqldump`/`gitlab-backup`
# binaries on PATH and env-injected paths, so they assert behaviour and exit
# codes rather than the presence of source strings. Every one of them was run
# against the pre-fix script first (NWP_BOX_BACKUP_SCRIPT pointed at a
# path-patched copy of HEAD~) and observed RED.
#
# Exit contract under test:  0 every declared leg ran · 1 a leg FAILED ·
#                            2 CANNOT VERIFY (undeclared and unmeasurable).

PRODUCER="${NWP_BOX_BACKUP_SCRIPT:-${BATS_TEST_DIRNAME}/../../servers/nwpcode/backup/nwp-box-backup.sh}"

setup() {
  TDIR="$(mktemp -d)"
  export NWP_BOX_BACKUP_OUT="$TDIR/out"
  export NWP_BOX_BACKUP_LOG="$TDIR/backup.log"
  export NWP_BOX_BACKUP_CONF="$TDIR/nwp-box-backup.conf"
  export NWP_BOX_BACKUP_NGINX_DIRS="$TDIR/nginx"
  export NWP_BOX_BACKUP_GITLAB_DIR="$TDIR/gitlab-backups"
  export NWP_BOX_BACKUP_CHOWN=0
  mkdir -p "$TDIR/nginx" "$TDIR/gitlab-backups" "$TDIR/bin"
  echo "server { listen 80; }" > "$TDIR/nginx/site.conf"
  PATH="$TDIR/bin:$PATH"
}

teardown() { rm -rf "$TDIR"; }

VERDICT() { cat "$NWP_BOX_BACKUP_OUT/backup-verdict.json"; }

# --- fakes ------------------------------------------------------------------

# a database server that is not there — the exact ops#332 condition
fake_mysql_down() {
  cat > "$TDIR/bin/mysql" <<'EOF'
#!/bin/sh
echo "ERROR 2002 (HY000): Can't connect to local server through socket '/run/mysqld/mysqld.sock' (2)" >&2
exit 1
EOF
  cat > "$TDIR/bin/mysqldump" <<'EOF'
#!/bin/sh
echo "ERROR 2002 (HY000): Can't connect to local server" >&2
exit 1
EOF
  chmod +x "$TDIR/bin/mysql" "$TDIR/bin/mysqldump"
}

# a database server holding $* site databases (plus the system schemas)
fake_mysql_up() {
  { echo '#!/bin/sh'
    echo 'cat <<LIST'
    printf '%s\n' information_schema performance_schema sys mysql "$@"
    echo 'LIST'
  } > "$TDIR/bin/mysql"
  cat > "$TDIR/bin/mysqldump" <<'EOF'
#!/bin/sh
for db in "$@"; do :; done          # POSIX "last argument" — the database name
if [ -n "${FAKE_DUMP_FAIL:-}" ] && [ "$db" = "$FAKE_DUMP_FAIL" ]; then
  echo "mysqldump: Got error: 1045 on $db" >&2
  exit 2
fi
echo "-- MySQL dump of $db"
i=0; while [ "$i" -lt 200 ]; do echo "INSERT INTO t VALUES ($i);"; i=$((i+1)); done
EOF
  chmod +x "$TDIR/bin/mysql" "$TDIR/bin/mysqldump"
}

declare_conf() { printf '%s\n' "$@" > "$NWP_BOX_BACKUP_CONF"; }

################################################################################
# 1. The bug itself: an unreachable database server must never read as success
################################################################################

@test "REGRESSION ops#332: DB server unreachable on a host that DECLARES the leg -> exit 1, names the leg" {
  fake_mysql_down
  declare_conf 'SITE_DB_LEG=required' 'GITLAB_LEG=none'
  run bash "$PRODUCER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"db"* ]]
  run cat "$NWP_BOX_BACKUP_LOG"
  [[ "$output" == *"ERROR"* ]]
  # …and it must NOT be able to end with the old unconditional success line
  [[ "$output" != *"] done"* ]]
}

@test "REGRESSION ops#332: a failing leg is written into the verdict artefact, not just the log" {
  fake_mysql_down
  declare_conf 'SITE_DB_LEG=required' 'GITLAB_LEG=none'
  run bash "$PRODUCER"
  [ "$status" -eq 1 ]
  run VERDICT
  [[ "$output" == *'"verdict": "failed"'* ]]
  [[ "$output" == *'"db"'* ]]
  [[ "$output" == *'"state": "failed"'* ]]
}

################################################################################
# 2. The three states, told apart honestly
################################################################################

@test "state (a) DECLARED no-DB-leg + no database server -> exit 0, state declared-none" {
  fake_mysql_down
  declare_conf 'SITE_DB_LEG=none' 'GITLAB_LEG=none'
  run bash "$PRODUCER"
  [ "$status" -eq 0 ]
  run VERDICT
  [[ "$output" == *'"verdict": "ok"'* ]]
  [[ "$output" == *'"state": "declared-none"'* ]]
  [[ "$output" == *'"declared": "none"'* ]]
}

@test "state (a) is a PASS ONLY because it was declared — the SAME host undeclared is CANNOT VERIFY (exit 2)" {
  fake_mysql_down
  rm -f "$NWP_BOX_BACKUP_CONF"          # nothing declared at all
  run bash "$PRODUCER"
  [ "$status" -eq 2 ]
  run VERDICT
  [[ "$output" == *'"verdict": "cannot-verify"'* ]]
  [[ "$output" == *'"state": "cannot-verify"'* ]]
  [[ "$output" == *'"declared": "undeclared"'* ]]
}

@test "state (a) is not a licence to lose data: DECLARED none but databases EXIST -> exit 1" {
  fake_mysql_up alpha beta
  declare_conf 'SITE_DB_LEG=none' 'GITLAB_LEG=none'
  run bash "$PRODUCER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"declaration"* ]] || [[ "$output" == *"DECLARES"* ]]
  run VERDICT
  [[ "$output" == *'"verdict": "failed"'* ]]
}

@test "state (b) N databases dumped OK -> exit 0, count is the real count" {
  fake_mysql_up alpha beta gamma
  declare_conf 'SITE_DB_LEG=required' 'GITLAB_LEG=none'
  run bash "$PRODUCER"
  [ "$status" -eq 0 ]
  run VERDICT
  [[ "$output" == *'"verdict": "ok"'* ]]
  [[ "$output" == *'"count": 3'* ]]
  [ -s "$NWP_BOX_BACKUP_OUT/db/alpha-$(date -u +%F).sql.gz" ]
  [ -s "$NWP_BOX_BACKUP_OUT/db/gamma-$(date -u +%F).sql.gz" ]
}

@test "state (c) PARTIAL dump failure fails the whole run -> exit 1, names the database" {
  fake_mysql_up alpha beta gamma
  declare_conf 'SITE_DB_LEG=required' 'GITLAB_LEG=none'
  export FAKE_DUMP_FAIL=beta
  run bash "$PRODUCER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"beta"* ]]
  run VERDICT
  [[ "$output" == *'"verdict": "failed"'* ]]
}

@test "a dump that produces an EMPTY file is a failure, not a backup" {
  fake_mysql_up alpha
  cat > "$TDIR/bin/mysqldump" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$TDIR/bin/mysqldump"
  declare_conf 'SITE_DB_LEG=required' 'GITLAB_LEG=none'
  run bash "$PRODUCER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"alpha"* ]]
}

@test "DECLARED required but the server reports ZERO site databases -> exit 1 (never a silent pass)" {
  fake_mysql_up                       # only the four system schemas
  declare_conf 'SITE_DB_LEG=required' 'GITLAB_LEG=none'
  run bash "$PRODUCER"
  [ "$status" -eq 1 ]
  run VERDICT
  [[ "$output" == *'"verdict": "failed"'* ]]
}

@test "an unrecognised SITE_DB_LEG value reads as UNDECLARED, the stricter direction" {
  fake_mysql_down
  declare_conf 'SITE_DB_LEG=probably' 'GITLAB_LEG=none'
  run bash "$PRODUCER"
  [ "$status" -eq 2 ]
  run VERDICT
  [[ "$output" == *'"declared": "undeclared"'* ]]
}

@test "the conf is PARSED, never sourced — a command in it is not executed" {
  fake_mysql_down
  printf 'SITE_DB_LEG=none\nGITLAB_LEG=none\ntouch %s/PWNED\n' "$TDIR" > "$NWP_BOX_BACKUP_CONF"
  run bash "$PRODUCER"
  [ "$status" -eq 0 ]
  [ ! -e "$TDIR/PWNED" ]
}

################################################################################
# 3. The other two legs must be as loud as the DB leg
################################################################################

@test "GITLAB_LEG=required with no gitlab-backup binary -> exit 1" {
  fake_mysql_down
  declare_conf 'SITE_DB_LEG=none' 'GITLAB_LEG=required'
  export NWP_BOX_BACKUP_GITLAB_BACKUP="$TDIR/bin/definitely-not-here"
  run bash "$PRODUCER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gitlab"* ]]
}

@test "GITLAB_LEG=none removes the gitlab/ directory so an empty dir never masquerades as a backup" {
  fake_mysql_down
  declare_conf 'SITE_DB_LEG=none' 'GITLAB_LEG=none'
  run bash "$PRODUCER"
  [ "$status" -eq 0 ]
  [ ! -d "$NWP_BOX_BACKUP_OUT/gitlab" ]
  [ ! -d "$NWP_BOX_BACKUP_OUT/db" ]
}

@test "GITLAB_LEG=required with a real tarball -> exit 0 and the tarball is staged" {
  fake_mysql_down
  declare_conf 'SITE_DB_LEG=none' 'GITLAB_LEG=required'
  cat > "$TDIR/bin/gitlab-backup" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$TDIR/bin/gitlab-backup"
  echo "tarball-bytes" > "$TDIR/gitlab-backups/1754_2026_08_10_18.7.7_gitlab_backup.tar"
  touch -d "10 minutes ago" "$TDIR/gitlab-backups/1754_2026_08_10_18.7.7_gitlab_backup.tar"
  run bash "$PRODUCER"
  [ "$status" -eq 0 ]
  [ -s "$NWP_BOX_BACKUP_OUT/gitlab/1754_2026_08_10_18.7.7_gitlab_backup.tar" ]
}

@test "the nginx leg fails loudly when none of its declared directories exist" {
  fake_mysql_down
  declare_conf 'SITE_DB_LEG=none' 'GITLAB_LEG=none'
  export NWP_BOX_BACKUP_NGINX_DIRS="$TDIR/no-such-nginx"
  run bash "$PRODUCER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nginx"* ]]
}

@test "the nginx tarball is verified readable, not merely created" {
  fake_mysql_down
  declare_conf 'SITE_DB_LEG=none' 'GITLAB_LEG=none'
  run bash "$PRODUCER"
  [ "$status" -eq 0 ]
  run tar tzf "$NWP_BOX_BACKUP_OUT/nginx/nginx-conf-$(date -u +%F).tgz"
  [ "$status" -eq 0 ]
  [[ "$output" == *"site.conf"* ]]
}

################################################################################
# 4. The verdict artefact — the thing the pull side grades
################################################################################

@test "every run writes a verdict artefact, including a failing one" {
  fake_mysql_down
  declare_conf 'SITE_DB_LEG=required' 'GITLAB_LEG=none'
  run bash "$PRODUCER"
  [ -f "$NWP_BOX_BACKUP_OUT/backup-verdict.json" ]
}

@test "the verdict artefact carries schema, host, finish time, exit code and every leg" {
  fake_mysql_up alpha
  declare_conf 'SITE_DB_LEG=required' 'GITLAB_LEG=none'
  run bash "$PRODUCER"
  [ "$status" -eq 0 ]
  run VERDICT
  [[ "$output" == *'"schema": 1'* ]]
  [[ "$output" == *'"host"'* ]]
  [[ "$output" == *'"finished_at"'* ]]
  [[ "$output" == *'"exit_code": 0'* ]]
  [[ "$output" == *'"gitlab"'* ]]
  [[ "$output" == *'"db"'* ]]
  [[ "$output" == *'"nginx"'* ]]
}

@test "the verdict artefact is valid JSON" {
  fake_mysql_up alpha beta
  declare_conf 'SITE_DB_LEG=required' 'GITLAB_LEG=none'
  bash "$PRODUCER"
  run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["verdict"], d["legs"]["db"]["count"])' \
      "$NWP_BOX_BACKUP_OUT/backup-verdict.json"
  [ "$status" -eq 0 ]
  [ "$output" = "ok 2" ]
}

@test "a stale verdict is replaced, never left behind to look like tonight's" {
  fake_mysql_up alpha
  declare_conf 'SITE_DB_LEG=required' 'GITLAB_LEG=none'
  bash "$PRODUCER"
  local first; first="$(VERDICT)"
  fake_mysql_down
  run bash "$PRODUCER"
  [ "$status" -eq 1 ]
  run VERDICT
  [[ "$output" == *'"verdict": "failed"'* ]]
  [ "$output" != "$first" ]
}

@test "the producer never ends without a verdict, even when it aborts mid-run" {
  fake_mysql_up alpha
  declare_conf 'SITE_DB_LEG=required' 'GITLAB_LEG=none'
  # make the output tree unwritable part-way: the nginx leg cannot stage
  export NWP_BOX_BACKUP_ABORT_AFTER_DB=1
  run bash "$PRODUCER"
  [ "$status" -ne 0 ]
  [ -f "$NWP_BOX_BACKUP_OUT/backup-verdict.json" ]
  run VERDICT
  [[ "$output" == *'"verdict": "failed"'* ]]
  [[ "$output" == *"aborted"* ]]
}

################################################################################
# 5. Source-level invariants that made the bug possible
################################################################################

@test "the producer sets pipefail (a mysqldump|gzip failure was invisible without it)" {
  grep -Eq '^set -[a-z]*u[a-z]* -o pipefail|^set -o pipefail|^set -uo pipefail' "$PRODUCER"
}

@test "the producer has no unconditional success line" {
  # `log "done"` at the tail, reached whatever happened, is the whole bug.
  ! grep -Eq '^log "done"$' "$PRODUCER"
}
