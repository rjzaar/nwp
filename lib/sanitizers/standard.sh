#!/bin/bash
set -euo pipefail
################################################################################
# lib/sanitizers/standard.sh — generic, prod-native sanitizer for a standard-
# profile Drupal site. The safe default when a site has no bespoke
# lib/sanitizers/<site>.sh (the mayo.sh model, generalised).
#
# SECURITY MODEL (identical to lib/sanitizers/mayo.sh):
#   - The LIVE database is treated as READ-ONLY. We dump it once, load that dump
#     into a throwaway SCRATCH database, run every mutation against the scratch
#     copy, and export a dump of the scratch copy. Live user data is never
#     modified and never leaves this host un-sanitized.
#   - DB credentials are read via drush and written to a 0600 option file so the
#     password never appears in argv/ps.
#
# REQUIREMENT: the Drupal DB user must be able to CREATE/DROP the scratch database
# `<db>_sanitize_scratch` (grant it `ALL ON \`<db>_sanitize_scratch\`.*`, or run the
# sanitizer with a DB-admin option file). A user scoped only to its own DB will fail
# at scratch creation — which is fail-closed (no dump is produced), never a leak.
#
# This is a CONSERVATIVE generic pass: it anonymises the core Drupal PII columns
# and empties the volatile/PII tables that exist in a standard profile. A site
# with extra PII-bearing tables (webform, commerce, custom entities) MUST ship
# its own lib/sanitizers/<site>.sh — this generic pass does not know about them,
# so the independent fail-closed PII gate (lib/pii-gate.sh) is the backstop.
#
# Usage:
#   bash lib/sanitizers/standard.sh --site-dir DIR [--output FILE] [--drush PATH]
#   bash lib/sanitizers/standard.sh --verify --output FILE   # PII sweep only
#
# Exit: 0 sanitized dump written (and, with --verify, no PII found); non-zero on
#       any failure — fail-closed (a failed sanitize must never yield a "clean" dump).
################################################################################
OUTPUT="/tmp/standard-sanitized.sql.gz"
SITE_DIR=""
DRUSH=""
VERIFY_ONLY=false
SCRATCH_SUFFIX="_sanitize_scratch"

while [ $# -gt 0 ]; do
    case "$1" in
        --output)   OUTPUT="$2"; shift 2 ;;
        --output=*) OUTPUT="${1#*=}"; shift ;;
        --site-dir) SITE_DIR="$2"; shift 2 ;;
        --site-dir=*) SITE_DIR="${1#*=}"; shift ;;
        --drush)    DRUSH="$2"; shift 2 ;;
        --drush=*)  DRUSH="${1#*=}"; shift ;;
        --verify)   VERIFY_ONLY=true; shift ;;
        -h|--help)  sed -n '3,/^###/{/^###/d;p}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "standard-sanitizer: unknown arg: $1" >&2; exit 2 ;;
    esac
done

log()       { echo "[standard-sanitizer] $*"; }
log_error() { echo "[standard-sanitizer] ERROR: $*" >&2; }

# ── built-in PII sweep (mirrors lib/pii-gate.sh defaults; the gate is the real backstop)
pii_sweep() { # $1 = gz dump
    local f="$1"
    command -v zcat >/dev/null 2>&1 || { log_error "zcat missing"; return 2; }
    local hits
    hits=$(zcat -- "$f" 2>/dev/null \
        | grep -E -- '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' 2>/dev/null \
        | grep -Ev -- '@(example\.(com|org|net)|drupal\.org|nwpcode\.org)|noreply@|no-reply@' \
        | head -5 || true)
    [ -z "$hits" ] && { log "PII sweep: clean"; return 0; }
    log_error "PII sweep FAIL — residual email-like values remain:"
    printf '%s\n' "$hits" | sed -E 's/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/[REDACTED]/g' | sed 's/^/    /' >&2
    return 1
}

if [ "$VERIFY_ONLY" = true ]; then
    [ -f "$OUTPUT" ] || { log_error "no output file to verify: $OUTPUT"; exit 2; }
    pii_sweep "$OUTPUT"; exit $?
fi

[ -n "$SITE_DIR" ] || { log_error "--site-dir DIR is required"; exit 2; }
[ -z "$DRUSH" ] && DRUSH="$SITE_DIR/vendor/bin/drush"
[ -x "$DRUSH" ] || { log_error "drush not found/executable: $DRUSH"; exit 2; }

cd "$SITE_DIR" || { log_error "site dir not found: $SITE_DIR"; exit 2; }

# ── read live DB creds via drush into a 0600 option file (pass never on argv) ──
MYSQL_CNF="$(mktemp)"; chmod 600 "$MYSQL_CNF"
cleanup(){ [ -n "${SCRATCH_DB:-}" ] && mysql --defaults-extra-file="$MYSQL_CNF" -e "DROP DATABASE IF EXISTS \`${SCRATCH_DB}\`" 2>/dev/null || true; rm -f "$MYSQL_CNF" "${LIVE_DUMP:-}"; }
trap cleanup EXIT

creds="$("$DRUSH" php:eval '
  $o = \Drupal::database()->getConnectionOptions();
  foreach (["database","username","password","host","port","unix_socket"] as $k) {
    printf("%s\t%s\n", $k, isset($o[$k]) ? $o[$k] : "");
  }' 2>/dev/null)" || { log_error "could not read DB options via drush"; exit 1; }
db=$(awk -F'\t' '$1=="database"{print $2}' <<<"$creds")
user=$(awk -F'\t' '$1=="username"{print $2}' <<<"$creds")
pass=$(awk -F'\t' '$1=="password"{print $2}' <<<"$creds")
host=$(awk -F'\t' '$1=="host"{print $2}' <<<"$creds")
port=$(awk -F'\t' '$1=="port"{print $2}' <<<"$creds")
sock=$(awk -F'\t' '$1=="unix_socket"{print $2}' <<<"$creds")
[ -n "$db" ] && [ -n "$user" ] || { log_error "incomplete DB credentials from drush"; exit 1; }
{ echo "[client]"; echo "user=${user}"; echo "password=${pass}";
  [ -n "$host" ] && echo "host=${host}"; [ -n "$port" ] && echo "port=${port}";
  [ -n "$sock" ] && echo "socket=${sock}"; } > "$MYSQL_CNF"
SCRATCH_DB="${db}${SCRATCH_SUFFIX}"
mysql_cli(){ mysql --defaults-extra-file="$MYSQL_CNF" "$@"; }
sq(){ mysql_cli -N -B "$SCRATCH_DB" -e "$1"; }

# ── dump live (read-only) → scratch ───────────────────────────────────────────
LIVE_DUMP="$(mktemp --suffix=.sql.gz)"
log "dumping live DB (read-only) → scratch copy"
mysqldump --defaults-extra-file="$MYSQL_CNF" --single-transaction --quick "$db" 2>/dev/null | gzip > "$LIVE_DUMP" \
  || { log_error "live dump failed"; exit 1; }
mysql_cli -e "DROP DATABASE IF EXISTS \`${SCRATCH_DB}\`; CREATE DATABASE \`${SCRATCH_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" \
  || { log_error "scratch create failed"; exit 1; }
zcat "$LIVE_DUMP" | mysql_cli "$SCRATCH_DB" || { log_error "scratch load failed"; exit 1; }

# ── sanitize the SCRATCH copy ─────────────────────────────────────────────────
log "anonymising users_field_data (all real users, uid>0 incl. admin)"
sq "UPDATE users_field_data SET mail=CONCAT('user',uid,'@example.com'), init=CONCAT('user',uid,'@example.com'), name=CONCAT('user_',uid) WHERE uid>0;" \
  || { log_error "user anonymisation failed"; exit 1; }
table_exists(){ [ -n "$(sq "SELECT 1 FROM information_schema.tables WHERE table_schema='${SCRATCH_DB}' AND table_name='$1' LIMIT 1;")" ]; }
for t in sessions watchdog contact_message key_value_expire history; do
    table_exists "$t" && { log "truncating $t"; sq "TRUNCATE \`$t\`;" || true; }
done
for t in $(sq "SELECT table_name FROM information_schema.tables WHERE table_schema='${SCRATCH_DB}' AND table_name LIKE 'cache%';"); do
    sq "TRUNCATE \`$t\`;" 2>/dev/null || true
done

# ── export the scratch copy → OUTPUT ──────────────────────────────────────────
log "exporting sanitized dump → $OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
mysqldump --defaults-extra-file="$MYSQL_CNF" --single-transaction --quick "$SCRATCH_DB" 2>/dev/null | gzip > "$OUTPUT" \
  || { log_error "sanitized export failed"; exit 1; }
[ -s "$OUTPUT" ] || { log_error "sanitized dump is empty"; exit 1; }

# ── first-gate PII sweep (the independent lib/pii-gate.sh is the real backstop) ─
pii_sweep "$OUTPUT" || { log_error "built-in sweep found PII — refusing to hand off"; exit 1; }
log "done: $OUTPUT"
