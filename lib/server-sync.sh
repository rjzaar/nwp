#!/usr/bin/env bash
# lib/server-sync.sh — box-to-box site DATA migration (the box-split primitive).
#
# WHY THIS EXISTS
# `pl backup --remote` pulls a live snapshot DOWN to the workstation. That is
# the DR preflight, and it is the right shape for DR — but a server migration
# needs the opposite: move a site's live data from one server to ANOTHER server
# without the workstation becoming the system of record. Before this verb the
# only way to do that was a hand-rolled `mysqldump | ssh mysql` loop, which is
# exactly the sort of parallel script the estate is supposed to not have.
#
# DESIGN RULES (each one is a bug this code refuses to reintroduce)
#  1. NEVER guess a database name. Read it from the application's own config on
#     BOTH boxes and refuse if they disagree or either is empty. This mirrors
#     backup.sh's "refusing to guess the Moodle DB name".
#  2. The SOURCE is read-only. Every source-side command is a dump or a probe.
#  3. Dry-run by default. Writing to a second box is not something to discover
#     you have done.
#  4. Verify after writing. A sync that reports success without comparing the
#     two sides is a backup that cannot restore.
#  5. Never treat "cannot verify" as "verified". Unknown is a failure.
#
# The stream is source -> workstation -> target (a pipe, never a temp file), so
# no box-to-box trust relationship has to be created for a one-time migration.

# Guard against double-sourcing.
[[ -n "${_NWP_SERVER_SYNC_LOADED:-}" ]] && return 0
_NWP_SERVER_SYNC_LOADED=1

# ---------------------------------------------------------------------------
# ssh_prefix_for <server-name>
# Builds the ssh invocation for a server from its record. -n is deliberately
# NOT set here: some callers pipe data in on stdin. Callers that loop must
# redirect stdin themselves.
# ---------------------------------------------------------------------------
sync_ssh_prefix() {
    local server="$1" ip user key
    ip=$(get_server_ip "$server")   || return 1
    user=$(get_server_user "$server") || return 1
    key=$(get_server_ssh_key "$server") || return 1
    [[ -n "$ip" && -n "$user" ]] || return 1
    printf 'ssh -i %s -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new %s@%s' \
        "$key" "$user" "$ip"
}

# ---------------------------------------------------------------------------
# sync_probe_dbname <ssh-prefix> <type> <remote_path> [webroot]
# Reads the live database name out of the application's OWN configuration.
# Prints the name on stdout; empty output means "could not determine", which
# every caller must treat as fatal rather than falling back to a guess.
# ---------------------------------------------------------------------------
sync_probe_dbname() {
    local prefix="$1" type="$2" remote_path="$3" webroot="${4:-}"
    local out="" cand
    case "$type" in
        moodle)
            # config.php is r--r----- www-data, so it must be read AS www-data.
            # ABORT_AFTER_CONFIG stops Moodle before it bootstraps anything.
            out=$($prefix "sudo -u www-data php -d error_reporting=0 -d display_errors=0 -r 'define(\"CLI_SCRIPT\",true);define(\"ABORT_AFTER_CONFIG\",true);require(\$argv[1]);echo isset(\$CFG->dbname)?\$CFG->dbname:\"\";' ${remote_path}/config.php" 2>/dev/null </dev/null || true)
            ;;
        drupal)
            # Ask Drupal, not the filesystem: settings.php can include other
            # files and compute the name at runtime.
            #
            # Site layout is NOT declared anywhere in sites/*/.nwp.yml (no site
            # sets .project.webroot), and the fleet genuinely mixes them —
            # avc/nwc/nwd are html-rooted, ba/dir1/mt/ccc/cccrdf are web-rooted.
            # So probe a candidate list instead of assuming one shape; assuming
            # "html" made every web-rooted site look undeterminable.
            for cand in \
                "cd ${remote_path} && sudo -u www-data vendor/bin/drush sql:conf --format=json" \
                "cd ${remote_path} && sudo -u www-data drush sql:conf --format=json" \
                "cd ${remote_path}/${webroot:-web} && sudo -u www-data ../vendor/bin/drush sql:conf --format=json" \
                "cd ${remote_path}/html && sudo -u www-data ../vendor/bin/drush sql:conf --format=json"
            do
                out=$($prefix "$cand 2>/dev/null" 2>/dev/null </dev/null \
                      | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("database",""))
except Exception: pass' 2>/dev/null || true)
                [[ -n "$out" ]] && break
            done
            ;;
        static)
            # A static site has no database. This is a legitimate outcome, not
            # a failure — callers distinguish it by the dedicated exit code.
            return 2
            ;;
        *) return 1 ;;
    esac
    printf '%s' "$(printf '%s' "$out" | tr -d '[:space:]')"
}

# ---------------------------------------------------------------------------
# sync_path_exists <ssh-prefix> <path>
# ---------------------------------------------------------------------------
sync_path_exists() {
    local prefix="$1" path="$2" out
    out=$($prefix "test -e '${path}' && echo yes || echo no" </dev/null 2>/dev/null || true)
    [[ "$out" == "yes" ]]
}

# ---------------------------------------------------------------------------
# sync_db_fingerprint <ssh-prefix> <dbname>
# A cheap, order-stable summary of a schema+size: "<table_count>:<total_rows>".
# Row counts come from a real COUNT(*) per table, not information_schema's
# estimate, because InnoDB's estimate is not comparable across two servers.
# Prints "UNKNOWN" if it cannot be computed — never a zero that reads as equal.
# ---------------------------------------------------------------------------
sync_db_fingerprint() {
    local prefix="$1" db="$2" out
    out=$($prefix "sudo mysql -N -B -e \"
        SELECT GROUP_CONCAT(CONCAT(table_name) ORDER BY table_name)
        FROM information_schema.tables WHERE table_schema='${db}' AND table_type='BASE TABLE';\"" 2>/dev/null </dev/null)
    if [[ -z "$out" || "$out" == "NULL" ]]; then printf 'UNKNOWN'; return 1; fi

    local tables count sql=""
    tables=$(printf '%s' "$out" | tr ',' ' ')
    count=$(printf '%s' "$tables" | wc -w)
    local t
    for t in $tables; do
        sql+="SELECT '${t}', COUNT(*) FROM \\\`${db}\\\`.\\\`${t}\\\`;"
    done
    local rows
    rows=$($prefix "sudo mysql -N -B -e \"${sql}\"" 2>/dev/null </dev/null | sort | md5sum | cut -d' ' -f1)
    if [[ -z "$rows" ]]; then printf 'UNKNOWN'; return 1; fi
    printf '%s:%s' "$count" "$rows"
}

# ---------------------------------------------------------------------------
# sync_db_stream <src-prefix> <dst-prefix> <src-db> <dst-db>
# Streams a consistent dump from source into target. The source side is a pure
# read (--single-transaction, no locks that would stall a live site).
# ---------------------------------------------------------------------------
sync_db_stream() {
    local sp="$1" dp="$2" sdb="$3" ddb="$4"
    set -o pipefail
    $sp "sudo mysqldump --single-transaction --quick --routines --triggers --events --default-character-set=utf8mb4 ${sdb} | gzip -1" </dev/null \
      | $dp "gunzip | sudo mysql --default-character-set=utf8mb4 ${ddb}"
}
