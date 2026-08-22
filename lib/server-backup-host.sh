#!/bin/bash
# lib/server-backup-host.sh — BOX-LEVEL scope helpers for `nwp-server backup --host`
# (NWP-ADR-0025). Runs ON the prod/live host, inside the AI-free nwp-server artifact.
#
# WHY THIS EXISTS
#   NWP-ADR-0025's backup verb was written per-SITE (`--site-dir`): one site's DB plus
#   its files tree. That is the right unit for a pre-deploy snapshot and the wrong
#   unit for disaster recovery, because everything that makes the BOX the box is
#   outside any single site directory:
#
#     nginx server blocks · letsencrypt certificates and renewal state · postfix
#     and DKIM · cron (including the backup cron itself) · sshd config and the
#     forced-command authorized_keys that gate the pull tier · ufw/fail2ban rules
#     · php-fpm pools and php.ini (max_input_vars is load-bearing for Moodle) ·
#     the package selection that makes all of it run · the MySQL users and grants
#     each site's settings.php authenticates as · the site webroots themselves and
#     the moodledata trees that live OUTSIDE them.
#
#   Restore every per-site snapshot onto a bare Ubuntu box and you have a pile of
#   files that serves nothing. This scope is what turns that pile back into a host.
#
# CONTRACT
#   Every function here is READ-ONLY with respect to the host: it reads state and
#   writes only into a caller-supplied temp directory. Nothing here deletes, and
#   nothing here needs a credential that reaches off-box — NWP-ADR-0025's "prod holds
#   no credential that can delete the durable copy" is preserved by construction.
#
#   Functions that CANNOT read what they were asked for FAIL rather than emit a
#   short file. A manifest that silently records half the grants is worse than no
#   manifest: it restores a box that looks complete and locks half the sites out.
################################################################################

# Guard against double-sourcing (server-backup.sh may be re-entered by tests).
[ -n "${_NWP_SERVER_BACKUP_HOST_SH:-}" ] && return 0
_NWP_SERVER_BACKUP_HOST_SH=1

# Default BOX-LEVEL paths, in the order a restore would want them. Deliberately
# NOT /home: on the real live box /home is 9.9 GB of transient `pl` snapshot
# droppings (nwp-snapshot-*.sql.gz) that are already superseded by the very
# backup being taken. Operators who keep working trees there add --extra-path.
SBH_DEFAULT_PATHS=${SBH_DEFAULT_PATHS:-"/etc /usr/local /root /opt /var/www"}

# System schemas that must NOT be dumped as data. `mysql` is deliberately in this
# list: restoring a raw mysql schema across server versions breaks the server.
# The users and grants it holds are captured as replayable SQL in the manifest
# instead, which is the form a restore can actually apply.
SBH_SYSTEM_DBS_RE='^(information_schema|performance_schema|sys|mysql)$'

# Tool presence, with an override so the "this host does not have it" branch is
# reachable from a host that does.
#
# NWP_SBH_ABSENT is a space- or comma-separated list of tool names to treat as
# missing. It exists because the alternative is what bit this file in CI: the
# laptop had mysqldump, the runner did not, and a test that meant to exercise
# the empty-database-list refusal silently exercised the mysqldump-missing
# refusal instead — passing on one machine and failing on the other while
# asserting a behaviour neither run had actually reached. Whether a guard fires
# must be something a test STATES, not something the machine decides.
_sbh_have(){
  local _absent="${NWP_SBH_ABSENT:-}"
  case " ${_absent//,/ } " in *" $1 "*) return 1 ;; esac
  command -v "$1" >/dev/null 2>&1
}

# sbh_hostname — short hostname, used for the repo name and snapshot tag.
sbh_hostname(){ hostname -s 2>/dev/null || hostname 2>/dev/null || echo host; }

# sbh_existing_paths [path ...] — echo (one per line) the paths that exist.
# Missing paths are NOT an error: /opt legitimately does not exist everywhere.
# The caller reports what was skipped so the omission is visible, never silent.
sbh_existing_paths(){
  local p
  for p in "$@"; do [ -e "$p" ] && printf '%s\n' "$p"; done
  return 0
}

# sbh_size_mb <path ...> — total apparent size in MB of the given paths.
# Echoes an integer; echoes 0 and returns 1 if nothing could be measured (the
# caller must treat "cannot measure" as "cannot promise it fits", never as 0).
sbh_size_mb(){
  [ $# -gt 0 ] || { echo 0; return 1; }
  local total
  total="$(du -sm --one-file-system "$@" 2>/dev/null | awk '{s+=$1} END{printf "%d", s+0}')"
  [ -n "$total" ] || { echo 0; return 1; }
  echo "$total"
  [ "$total" -gt 0 ] 2>/dev/null
}

# sbh_free_mb <path> — free MB on the filesystem holding <path> (or its nearest
# existing parent, so a repo path that does not exist yet still measures).
sbh_free_mb(){
  local p="${1:-/}"
  while [ ! -e "$p" ] && [ "$p" != "/" ]; do p="$(dirname "$p")"; done
  df -Pm "$p" 2>/dev/null | awk 'NR==2 {print $4+0}'
}

# sbh_list_databases — echo every non-system MySQL/MariaDB schema, one per line.
# FAILS (returns 1, echoes nothing) when the server cannot be reached: an empty
# database list read as "this box has no databases" is exactly the silent-partial
# failure this file refuses to produce.
sbh_list_databases(){
  _sbh_have mysql || return 1
  local out
  out="$(mysql -N -B -e 'SHOW DATABASES' 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | grep -Ev "$SBH_SYSTEM_DBS_RE" || true
  return 0
}

# sbh_dump_databases <outdir> — one <db>.sql.gz per schema into <outdir>.
# Fail-closed: any single dump failure fails the whole call, because a DR archive
# that is missing one site's database is not a DR archive for that site and the
# operator will not find out until the restore.
sbh_dump_databases(){
  local out="${1:?sbh_dump_databases <outdir>}"
  mkdir -p "$out" || return 1
  _sbh_have mysqldump || { echo "sbh: mysqldump not found" >&2; return 1; }
  local dbs; dbs="$(sbh_list_databases)" || { echo "sbh: cannot enumerate databases" >&2; return 1; }
  [ -n "$dbs" ] || { echo "sbh: database list is EMPTY — refusing (fail-closed)" >&2; return 1; }
  local db rc=0
  while IFS= read -r db; do
    [ -n "$db" ] || continue
    if ! mysqldump --single-transaction --quick --routines --events --triggers \
         --default-character-set=utf8mb4 "$db" 2>/dev/null | gzip -c > "$out/${db}.sql.gz"; then
      echo "sbh: mysqldump FAILED for $db" >&2; rc=1; continue
    fi
    # A gzip stream of a failed dump is a valid, tiny gzip stream. Prove the
    # dump actually terminated rather than trusting the exit status of a pipe.
    if ! gzip -t "$out/${db}.sql.gz" 2>/dev/null; then
      echo "sbh: corrupt gzip for $db" >&2; rc=1; continue
    fi
    if ! zcat "$out/${db}.sql.gz" 2>/dev/null | tail -5 | grep -q 'Dump completed'; then
      echo "sbh: $db dump has no 'Dump completed' trailer — truncated" >&2; rc=1; continue
    fi
  done <<< "$dbs"
  return $rc
}

# sbh_dump_grants <outfile> — replayable CREATE USER + GRANT statements for every
# MySQL account. This is the piece that makes a restored box able to serve: the
# webroots carry settings.php with a username and password, and without the
# matching grant every site returns a database error on a "successful" restore.
sbh_dump_grants(){
  local out="${1:?sbh_dump_grants <outfile>}"
  _sbh_have mysql || return 1
  local users
  users="$(mysql -N -B -e "SELECT CONCAT(QUOTE(user),'@',QUOTE(host)) FROM mysql.user" 2>/dev/null)" || return 1
  [ -n "$users" ] || return 1
  {
    echo "-- nwp-server backup --host: MySQL accounts and grants"
    echo "-- Generated $(date -u +%FT%TZ) on $(sbh_hostname)"
    echo "-- Replay with: mysql < grants.sql   (after restoring the schemas)"
    echo
    local u
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      mysql -N -B -e "SHOW CREATE USER $u" 2>/dev/null | sed 's/$/;/'
      mysql -N -B -e "SHOW GRANTS FOR $u"  2>/dev/null | sed 's/$/;/'
      echo
    done <<< "$users"
    echo "FLUSH PRIVILEGES;"
  } > "$out"
  [ -s "$out" ]
}

# sbh_write_manifest <outdir> — the generated (not-on-disk) host state a restore
# needs: what was installed, what was enabled, what was scheduled, what nginx
# actually resolved to, and the grants. Best-effort per item, but the DIRECTORY
# always records which items could not be read, so a gap is visible in the
# archive itself rather than only in a log nobody kept.
sbh_write_manifest(){
  local out="${1:?sbh_write_manifest <outdir>}"
  mkdir -p "$out/crontabs" || return 1
  local missing="$out/UNREADABLE.txt"
  : > "$missing"
  _sbh_note(){ printf '%s\n' "$1" >> "$missing"; }

  {
    echo "host=$(sbh_hostname)"
    echo "fqdn=$(hostname -f 2>/dev/null || true)"
    echo "generated=$(date -u +%FT%TZ)"
    echo "kernel=$(uname -srmo 2>/dev/null || true)"
    [ -r /etc/os-release ] && . /etc/os-release 2>/dev/null && echo "os=${PRETTY_NAME:-unknown}"
  } > "$out/host.txt"

  dpkg --get-selections            > "$out/dpkg-selections.txt" 2>/dev/null || _sbh_note "dpkg-selections"
  apt-mark showmanual              > "$out/apt-manual.txt"      2>/dev/null || _sbh_note "apt-manual"
  apt-mark showhold                > "$out/apt-hold.txt"        2>/dev/null || _sbh_note "apt-hold"
  systemctl list-unit-files --state=enabled --no-pager --no-legend \
                                   > "$out/systemd-enabled.txt" 2>/dev/null || _sbh_note "systemd-enabled"
  df -PT                           > "$out/df.txt"              2>/dev/null || _sbh_note "df"
  findmnt -rn                      > "$out/mounts.txt"          2>/dev/null || _sbh_note "mounts"
  ip -o addr                       > "$out/ip.txt"              2>/dev/null || _sbh_note "ip"

  # nginx -T is the ONLY faithful record of what is served: it resolves every
  # include and shows the effective config, which a tar of /etc/nginx does not.
  if _sbh_have nginx; then
    nginx -T > "$out/nginx-T.conf" 2>/dev/null || _sbh_note "nginx -T"
  fi

  # Per-user crontabs live in /var/spool/cron, outside every path we snapshot.
  local u
  while IFS=: read -r u _; do
    [ -n "$u" ] || continue
    crontab -l -u "$u" > "$out/crontabs/$u" 2>/dev/null || rm -f "$out/crontabs/$u"
  done < /etc/passwd
  [ -f /var/spool/cron/crontabs/root ] || true

  sbh_dump_grants "$out/grants.sql" 2>/dev/null || _sbh_note "mysql grants"

  # An inventory of what WOULD be restored, so a future operator can diff the
  # archive against the box without unpacking 7 GB.
  du -sm --one-file-system /var/www/* 2>/dev/null | sort -n > "$out/webroot-sizes.txt" || true

  [ -s "$missing" ] || rm -f "$missing"
  unset -f _sbh_note
  return 0
}
