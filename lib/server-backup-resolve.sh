#!/bin/bash
# NOTE: no `set -euo pipefail` — SOURCED library (see lib/pii-gate.sh, and the
# ops#111 lesson: forcing -e/-u onto the caller leaks into the bats runner).
# Functions do explicit error handling and never rely on errexit.
################################################################################
# lib/server-backup-resolve.sh — stack-aware resolvers for `nwp-server backup`
# (NWP-ADR-0032 Flow B). Pure, testable helpers so server-backup.sh can back up a
# MOODLE site (moodledata + mysqldump) as well as a Drupal site (public+private
# files + drush), instead of assuming a single Drupal layout.
#
# All raw-data movement stays within NWP-ADR-0025's DR flow (raw → ver only). These
# helpers only RESOLVE paths/creds; the actual restic/mysqldump run in
# server-backup.sh on the prod host.
################################################################################

# sb_detect_stack <site-dir> → "moodle" | "drupal"
# Moodle roots carry version.php declaring $release; everything else is Drupal.
sb_detect_stack() {
    local d="${1:-}"
    if [ -f "$d/version.php" ] && grep -q '\$release' "$d/version.php" 2>/dev/null; then echo moodle; return; fi
    if [ -f "$d/web/version.php" ] && grep -q '\$release' "$d/web/version.php" 2>/dev/null; then echo moodle; return; fi
    echo drupal
}

# sb_moodle_root <site-dir> → dir containing config.php/version.php (site-dir or its web/)
sb_moodle_root() {
    local d="${1:-}"
    [ -f "$d/web/version.php" ] && { printf '%s\n' "$d/web"; return; }
    printf '%s\n' "$d"
}

# sb_moodle_dataroot <site-dir> → HOST moodledata path.
# DDEV mount override (dev/stg) → config.php $CFG->dataroot (HOST paths only, as
# on prod) → sibling default. Rejects the /var/www/* container path and Moodle's
# dataroot-check fatal message (same guard as pl fixture-load).
sb_moodle_dataroot() {
    local d="${1:-}" root dc dr=""
    root="$(sb_moodle_root "$d")"
    dc="$d/.ddev/docker-compose.moodledata.yaml"
    if [ -f "$dc" ]; then
        dr="$(sed -nE 's|^[[:space:]]*-[[:space:]]*"([^"]+):/var/www/moodledata:[^"]*".*$|\1|p' "$dc" | head -1)"
    fi
    if [ -z "$dr" ] && [ -f "$root/config.php" ] && command -v php >/dev/null 2>&1; then
        local v
        v="$(php -d error_reporting=0 -d display_errors=0 -r '
            define("CLI_SCRIPT", true); define("ABORT_AFTER_CONFIG", true);
            require($argv[1]); echo isset($CFG->dataroot) ? $CFG->dataroot : "";' \
            "$root/config.php" 2>/dev/null || true)"
        case "$v" in
            /var/www/*) : ;;
            /*) [ -d "$v" ] && dr="$v" ;;
        esac
    fi
    [ -n "$dr" ] || dr="${d%/}/moodledata"
    printf '%s\n' "$dr"
}

# sb_backup_files_paths <site-dir> [drupal_public_sub] [drupal_private_sub]
# Echo (newline-separated) the EXISTING dirs to back up for this stack:
#   moodle → the moodledata tree (the NWP-ADR-0031 D8 "zero backups today" gap).
#   drupal → public files + private files (private is often outside the webroot;
#            probe the common locations, or use the explicit sub if given).
sb_backup_files_paths() {
    local d="${1:-}" pub="${2:-web/sites/default/files}" priv="${3:-}"
    local stack; stack="$(sb_detect_stack "$d")"
    if [ "$stack" = moodle ]; then
        local dr; dr="$(sb_moodle_dataroot "$d")"
        [ -d "$dr" ] && printf '%s\n' "$dr"
        return 0
    fi
    # drupal: public first
    [ -d "$d/$pub" ] && printf '%s\n' "$d/$pub"
    # private: explicit sub, else common locations (include the first that exists)
    if [ -n "$priv" ]; then
        [ -d "$d/$priv" ] && printf '%s\n' "$d/$priv"
    else
        local p
        for p in private web/sites/default/private ../private; do
            if [ -d "$d/$p" ]; then printf '%s\n' "$d/$p"; break; fi
        done
    fi
    return 0
}

# sb_moodle_db_dump <site-dir> <out.sql.gz>
# Raw Moodle DB dump for the DR backup (Moodle has no drush). Reads creds from
# config.php WITHOUT bootstrapping Moodle (ABORT_AFTER_CONFIG), into a 0600 option
# file (password never on argv), then mysqldump | gzip. Runs on the prod host.
# Fail-closed (non-zero) on any missing tool/cred/dump error.
sb_moodle_db_dump() {
    local d="${1:-}" out="${2:-}"
    [ -n "$d" ] && [ -n "$out" ] || { echo "sb_moodle_db_dump: usage: <site-dir> <out.sql.gz>" >&2; return 2; }
    local root; root="$(sb_moodle_root "$d")"
    [ -f "$root/config.php" ] || { echo "sb_moodle_db_dump: config.php not found under $root" >&2; return 1; }
    command -v php >/dev/null 2>&1        || { echo "sb_moodle_db_dump: php required" >&2; return 1; }
    command -v mysqldump >/dev/null 2>&1  || { echo "sb_moodle_db_dump: mysqldump required" >&2; return 1; }

    local creds
    creds="$(php -d error_reporting=0 -d display_errors=0 -r '
        define("CLI_SCRIPT", true); define("ABORT_AFTER_CONFIG", true);
        require($argv[1]);
        $o = (isset($CFG->dboptions) && is_array($CFG->dboptions)) ? $CFG->dboptions : array();
        $g = function($k) use ($CFG) { return isset($CFG->$k) ? $CFG->$k : ""; };
        printf("dbname\t%s\n",   $g("dbname"));
        printf("dbuser\t%s\n",   $g("dbuser"));
        printf("dbpass\t%s\n",   $g("dbpass"));
        printf("dbhost\t%s\n",   $g("dbhost"));
        printf("dbport\t%s\n",   isset($o["dbport"])   ? $o["dbport"]   : "");
        printf("dbsocket\t%s\n", isset($o["dbsocket"]) ? $o["dbsocket"] : "");' \
        "$root/config.php" 2>/dev/null || true)"
    local db user pass host port sock
    db=$(awk   -F'\t' '$1=="dbname"{print $2}'   <<<"$creds")
    user=$(awk -F'\t' '$1=="dbuser"{print $2}'   <<<"$creds")
    pass=$(awk -F'\t' '$1=="dbpass"{print $2}'   <<<"$creds")
    host=$(awk -F'\t' '$1=="dbhost"{print $2}'   <<<"$creds")
    port=$(awk -F'\t' '$1=="dbport"{print $2}'   <<<"$creds")
    sock=$(awk -F'\t' '$1=="dbsocket"{print $2}' <<<"$creds")
    [ -n "$db" ] && [ -n "$user" ] || { echo "sb_moodle_db_dump: incomplete DB creds from config.php" >&2; return 1; }

    local cnf; cnf="$(mktemp)"; chmod 600 "$cnf"
    {
        echo "[client]"
        echo "user=${user}"
        echo "password=${pass}"
        [ -n "$host" ] && echo "host=${host}"
        [ -n "$port" ] && echo "port=${port}"
        [ -n "$sock" ] && echo "socket=${sock}"
    } > "$cnf"
    mkdir -p "$(dirname "$out")"
    if mysqldump --defaults-extra-file="$cnf" --no-tablespaces --single-transaction \
        --skip-lock-tables --quick "$db" 2>/dev/null | gzip > "$out"; then
        rm -f "$cnf"
        [ -s "$out" ] || { echo "sb_moodle_db_dump: dump is empty" >&2; return 1; }
        return 0
    fi
    rm -f "$cnf"
    echo "sb_moodle_db_dump: mysqldump failed" >&2
    return 1
}
