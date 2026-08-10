#!/usr/bin/env bash
# nwp-box-backup.sh — LOCAL backup producer, run as a ROOT cron on every box in
# the estate. Writes everything the off-box pull needs into /var/backups/nwp-pull/
# (gitlab-readable), and — this is the part ops#332 added — writes a VERDICT
# saying which legs actually ran, so the pull side can grade the night without
# re-deriving anything.
#
# Produces:
#   gitlab/               newest GitLab data tarball (repos+DB+uploads; NOT
#                         /etc/gitlab — the secrets file is operator-carried by
#                         design, ops#25)
#   db/                   per-database mysqldump .sql.gz for every site DB
#   nginx/                /etc/nginx/conf.d + sites-enabled tarball
#   backup-verdict.json   what happened, per leg (ops#332)
# Retention: keeps RETAIN_DAYS locally (the stick keeps its own generations).
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT IS SHAPED THE WAY IT IS  (nwp/ops#332, 2026-08-10)
#
# It used to enumerate the site databases like this:
#
#     for db in $(mysql -N -e "SHOW DATABASES" 2>>"$LOG" | grep -Ev '…'); do
#
# under `set -u`, with no `set -e` and no `set -o pipefail`. When mysql could
# not connect the command substitution was EMPTY, the loop body never ran, and
# execution walked straight on to `log "done"` and exit 0. A ZERO-ITERATION LOOP
# READ AS A SUCCESSFUL BACKUP. On the forge box that state persisted from
# 2026-08-04 to 2026-08-10 and reported success every single night; the only
# reason it was ever noticed is that a separate probe grades the OUTPUT
# directory rather than the script's exit code.
#
# So three properties are now load-bearing, and the bats suite
# tests/unit/test-box-backup-producer.bats fails if any of them is removed:
#
#   1. FAIL LOUDLY.  `set -o pipefail`; every leg's success is asserted from a
#      reading (a non-empty, gzip-valid file; a listable tarball), never from
#      "the command did not obviously explode". Any failing leg ⇒ an ERROR line
#      naming the leg and a NON-ZERO exit. There is no unconditional `done`.
#
#   2. THE THREE STATES ARE TOLD APART, AND "no leg here" IS **DECLARED**.
#      "this host has no site databases" and "the database server is down" look
#      identical from inside the loop, so the script may not infer the first
#      from the second — an inferred (a) is the same swallowed verdict wearing a
#      different hat. It reads the declaration out of $CONF
#      (/etc/nwp-box-backup.conf, installed from the repo by
#      `pl host apply <host> --kind=backup`). Undeclared + unmeasurable ⇒ exit 2
#      CANNOT VERIFY, never 0. And a declaration is not a licence: if the host
#      DECLARES no DB leg but site databases are found anyway, that is a
#      mis-declaration and a FAILURE, because those databases are going unbacked.
#
#   3. EVERY RUN LEAVES A VERDICT.  backup-verdict.json is written on the way
#      out — including from the EXIT trap, so even an abort leaves "failed"
#      rather than yesterday's file pretending to be tonight's.
#
# The conf is PARSED, never sourced: this runs as root out of cron, and a
# `source`d config file is a root code-execution surface.
#
# Install (through the verb — never by hand; the pl-first standing order):
#   pl host apply <host> --kind=backup            # dry run: what would change
#   pl host apply <host> --kind=backup --execute  # install + measure
# ---------------------------------------------------------------------------
set -uo pipefail

OUT="${NWP_BOX_BACKUP_OUT:-/var/backups/nwp-pull}"
LOG="${NWP_BOX_BACKUP_LOG:-/var/log/nwp-box-backup.log}"
CONF="${NWP_BOX_BACKUP_CONF:-/etc/nwp-box-backup.conf}"
RETAIN_DAYS="${NWP_BOX_BACKUP_RETAIN_DAYS:-2}"
MYSQL="${NWP_BOX_BACKUP_MYSQL:-mysql}"
MYSQLDUMP="${NWP_BOX_BACKUP_MYSQLDUMP:-mysqldump}"
GITLAB_BACKUP="${NWP_BOX_BACKUP_GITLAB_BACKUP:-gitlab-backup}"
GITLAB_DIR="${NWP_BOX_BACKUP_GITLAB_DIR:-/var/opt/gitlab/backups}"
NGINX_DIRS="${NWP_BOX_BACKUP_NGINX_DIRS:-/etc/nginx/conf.d /etc/nginx/sites-enabled}"
OWNER="${NWP_BOX_BACKUP_OWNER:-gitlab:gitlab}"
DO_CHOWN="${NWP_BOX_BACKUP_CHOWN:-1}"
# An empty gzip stream is 20 bytes; a real mysqldump is thousands. Anything at
# or under this floor is a file, not a backup.
MIN_DUMP_BYTES="${NWP_BOX_BACKUP_MIN_DUMP_BYTES:-100}"

VERDICT_FILE="$OUT/backup-verdict.json"
STARTED_AT="$(date -u +%FT%TZ)"
STAMP="$(date -u +%F)"
HOSTNAME_S="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }
# Loud on BOTH channels: the log is for forensics, stdout/stderr is what cron
# mails and what `pl host apply --kind=backup --execute` reads back.
say() { printf '%s\n' "$*"; log "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; log "ERROR: $*"; ERRORS+=("$*"); }

ERRORS=()
GITLAB_STATE="not-run"; GITLAB_DECLARED="undeclared"; GITLAB_DETAIL=""
DB_STATE="not-run";     DB_DECLARED="undeclared";     DB_COUNT=0; DB_DETAIL=""
NGINX_STATE="not-run";  NGINX_DETAIL=""
VERDICT_WRITTEN=0

json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r\t'; }

finalise_permissions() {
    [ "$DO_CHOWN" = "1" ] || return 0
    [ "$(id -u)" -eq 0 ] || return 0
    chown -R "$OWNER" "$OUT" 2>>"$LOG" || true
    chmod -R u=rwX,g=rX,o= "$OUT" 2>>"$LOG" || true
}

write_verdict() { # <verdict> <exit-code>
    local verdict="$1" code="$2" i sep=""
    mkdir -p "$OUT" 2>/dev/null || true
    {
        printf '{\n'
        printf '  "schema": 1,\n'
        printf '  "producer": "nwp-box-backup.sh",\n'
        printf '  "host": "%s",\n'          "$(json_esc "$HOSTNAME_S")"
        printf '  "started_at": "%s",\n'    "$STARTED_AT"
        printf '  "finished_at": "%s",\n'   "$(date -u +%FT%TZ)"
        printf '  "verdict": "%s",\n'       "$verdict"
        printf '  "exit_code": %s,\n'       "$code"
        printf '  "legs": {\n'
        printf '    "gitlab": { "state": "%s", "declared": "%s", "detail": "%s" },\n' \
               "$GITLAB_STATE" "$GITLAB_DECLARED" "$(json_esc "$GITLAB_DETAIL")"
        printf '    "db": { "state": "%s", "declared": "%s", "count": %s, "detail": "%s" },\n' \
               "$DB_STATE" "$DB_DECLARED" "${DB_COUNT:-0}" "$(json_esc "$DB_DETAIL")"
        printf '    "nginx": { "state": "%s", "detail": "%s" }\n' \
               "$NGINX_STATE" "$(json_esc "$NGINX_DETAIL")"
        printf '  },\n'
        printf '  "errors": ['
        for i in ${ERRORS[@]+"${!ERRORS[@]}"}; do
            printf '%s\n    "%s"' "$sep" "$(json_esc "${ERRORS[$i]}")"; sep=","
        done
        [ -n "$sep" ] && printf '\n  '
        printf ']\n'
        printf '}\n'
    } > "$VERDICT_FILE"
    VERDICT_WRITTEN=1
}

# A run that dies without a verdict is exactly the failure mode this whole
# change exists to remove, so the verdict is also written from the trap.
on_exit() {
    local rc=$?
    if [ "$VERDICT_WRITTEN" -eq 0 ]; then
        ERRORS+=("the producer aborted before completing (exit ${rc}) — this run is NOT a backup")
        printf 'ERROR: nwp-box-backup aborted before completing (exit %s)\n' "$rc" >&2
        log "ERROR: aborted before completing (exit $rc)"
        write_verdict failed "$rc"
    fi
    finalise_permissions
}
trap on_exit EXIT

################################################################################
# 0. The DECLARATION. Parsed, never sourced. Unknown/absent ⇒ undeclared, which
#    is the STRICTER reading: it can only produce CANNOT VERIFY, never a pass.
################################################################################
read_declaration() { # <KEY> -> none|required|undeclared
    local key="$1" v
    [ -r "$CONF" ] || { printf 'undeclared'; return 0; }
    v="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\([A-Za-z-]*\).*/\1/p" "$CONF" | head -1)"
    case "$v" in
        none|required) printf '%s' "$v" ;;
        "")            printf 'undeclared' ;;
        *)             printf 'undeclared' ;;
    esac
}

DB_DECLARED="$(read_declaration SITE_DB_LEG)"
GITLAB_DECLARED="$(read_declaration GITLAB_LEG)"
if [ ! -r "$CONF" ]; then
    say "no declaration file at ${CONF} — legs are UNDECLARED (see pl host apply <host> --kind=backup)"
fi

mkdir -p "$OUT" || err "cannot create $OUT"

################################################################################
# 1. GitLab application backup (repos, DB, uploads, CI). Skipped if one ran <20h
#    ago — the nightly and a manual verification run should not both pay for it.
################################################################################
gitlab_leg() {
    local have=0 newest="" staged=""
    command -v "$GITLAB_BACKUP" >/dev/null 2>&1 && have=1

    case "$GITLAB_DECLARED" in
        none)
            if [ "$have" -eq 1 ]; then
                GITLAB_STATE="failed"
                GITLAB_DETAIL="declared GITLAB_LEG=none but ${GITLAB_BACKUP} is installed here"
                err "gitlab leg: this host DECLARES GITLAB_LEG=none but ${GITLAB_BACKUP} exists — the declaration is wrong and GitLab is NOT being backed up"
                return
            fi
            GITLAB_STATE="declared-none"
            GITLAB_DETAIL="no GitLab on this host, and the host says so"
            rmdir "$OUT/gitlab" 2>/dev/null || true
            say "gitlab leg: declared none — skipped"
            return ;;
        required)
            if [ "$have" -eq 0 ]; then
                GITLAB_STATE="failed"
                GITLAB_DETAIL="declared GITLAB_LEG=required but ${GITLAB_BACKUP} is not installed"
                err "gitlab leg: GITLAB_LEG=required but ${GITLAB_BACKUP} is not on this host — the required leg did not run"
                return
            fi ;;
        undeclared)
            if [ "$have" -eq 0 ]; then
                # Distinct from the DB case on purpose: "the binary is not
                # installed" is a POSITIVE reading of the host, not an empty
                # result set. It is still reported so the gap is visible.
                GITLAB_STATE="cannot-verify"
                GITLAB_DETAIL="GITLAB_LEG undeclared and ${GITLAB_BACKUP} absent"
                err "gitlab leg: GITLAB_LEG is undeclared and ${GITLAB_BACKUP} is absent — declare it, do not guess"
                rmdir "$OUT/gitlab" 2>/dev/null || true
                return
            fi ;;
    esac

    mkdir -p "$OUT/gitlab" || { GITLAB_STATE="failed"; err "gitlab leg: cannot create $OUT/gitlab"; return; }
    newest="$(ls -t "$GITLAB_DIR"/*_gitlab_backup.tar 2>/dev/null | head -1)"
    if [ -z "$newest" ] || [ -n "$(find "$newest" -mmin +1200 2>/dev/null)" ]; then
        say "running ${GITLAB_BACKUP} create"
        if ! "$GITLAB_BACKUP" create CRON=1 >> "$LOG" 2>&1; then
            err "gitlab leg: ${GITLAB_BACKUP} create exited non-zero"
        fi
        newest="$(ls -t "$GITLAB_DIR"/*_gitlab_backup.tar 2>/dev/null | head -1)"
    fi
    if [ -z "$newest" ]; then
        GITLAB_STATE="failed"; GITLAB_DETAIL="no tarball in ${GITLAB_DIR}"
        err "gitlab leg: ${GITLAB_BACKUP} is installed but produced no tarball in ${GITLAB_DIR}"
        return
    fi
    if ! cp -u "$newest" "$OUT/gitlab/" 2>>"$LOG"; then
        GITLAB_STATE="failed"; GITLAB_DETAIL="could not stage $(basename "$newest")"
        err "gitlab leg: could not stage $(basename "$newest") into $OUT/gitlab"
        return
    fi
    staged="$OUT/gitlab/$(basename "$newest")"
    if [ ! -s "$staged" ]; then
        GITLAB_STATE="failed"; GITLAB_DETAIL="staged tarball is empty"
        err "gitlab leg: staged tarball $(basename "$newest") is EMPTY"
        return
    fi
    GITLAB_STATE="ok"; GITLAB_DETAIL="$(basename "$newest")"
    say "gitlab tarball staged: $(basename "$newest")"
}

################################################################################
# 2. Site databases, one gz per DB (root cron ⇒ socket auth works).
#    THE ops#332 LEG. Enumerate first, decide from the DECLARATION, then dump.
################################################################################
db_leg() {
    local reachable=0 raw="" names=() n dumped=0 failed=0 why=""

    # Enumerate FIRST and judge second. The enumeration failing is not by itself
    # an error — on a host that declares no site-DB leg it is the expected
    # reading — so the reason is carried and only escalated by the branch that
    # actually cares. (An "error" logged on a leg the host does not have is the
    # noise that trains people to skim the errors array.)
    if command -v "$MYSQL" >/dev/null 2>&1; then
        if raw="$("$MYSQL" -N -e "SHOW DATABASES" 2>>"$LOG")"; then
            reachable=1
            while IFS= read -r n; do
                [ -n "$n" ] && names+=("$n")
            done < <(printf '%s\n' "$raw" | grep -Ev '^(information_schema|performance_schema|sys|mysql)$' || true)
        else
            why="'${MYSQL} -N -e SHOW DATABASES' failed — see $LOG for the server's own message"
        fi
    else
        why="no ${MYSQL} client on this host"
    fi
    local found="${#names[@]}"

    # --- state (a): the host DECLARES it has no site-DB leg -----------------
    if [ "$DB_DECLARED" = "none" ]; then
        if [ "$found" -gt 0 ]; then
            DB_STATE="failed"; DB_COUNT=0
            DB_DETAIL="declared SITE_DB_LEG=none but ${found} site database(s) exist here"
            err "db leg: this host DECLARES SITE_DB_LEG=none, but ${found} site database(s) exist here (${names[*]}) — the declaration is wrong and those databases are NOT being backed up"
            return
        fi
        DB_STATE="declared-none"; DB_COUNT=0
        DB_DETAIL="no site databases on this host, and the host says so${why:+ (${why})}"
        rmdir "$OUT/db" 2>/dev/null || true
        say "db leg: declared none — no site-DB leg on this host"
        return
    fi

    # --- states (b)/(c): the leg is expected, or nobody said ----------------
    if [ "$reachable" -ne 1 ] || [ "$found" -eq 0 ]; then
        DB_COUNT=0
        if [ "$DB_DECLARED" = "required" ]; then
            DB_STATE="failed"
            if [ "$reachable" -ne 1 ]; then
                DB_DETAIL="SITE_DB_LEG=required but the database server could not be reached: ${why}"
                err "db leg: SITE_DB_LEG=required but the database server could not be reached (${why}) — the required leg DID NOT RUN. This run is not a backup."
            else
                DB_DETAIL="SITE_DB_LEG=required but the server reported zero site databases"
                err "db leg: SITE_DB_LEG=required but the server reported ZERO site databases — either they were dropped or this host's declaration is stale"
            fi
        else
            DB_STATE="cannot-verify"
            DB_DETAIL="undeclared, and no site database could be enumerated${why:+ (${why})}"
            err "db leg: SITE_DB_LEG is UNDECLARED and no site database could be enumerated${why:+ (${why})}. 'this host has none' and 'the server is unreachable' are indistinguishable from here — declare it: pl host apply <host> --kind=backup"
        fi
        return
    fi

    mkdir -p "$OUT/db" || { DB_STATE="failed"; err "db leg: cannot create $OUT/db"; return; }
    local db f sz
    for db in "${names[@]}"; do
        f="$OUT/db/${db}-${STAMP}.sql.gz"
        # pipefail is what makes this `if` see a mysqldump failure at all. Without
        # it the exit status was gzip's, which is 0 for an empty input stream.
        if ! "$MYSQLDUMP" --single-transaction --routines "$db" 2>>"$LOG" | gzip > "$f"; then
            failed=$((failed + 1)); rm -f "$f"
            err "db leg: dump of '${db}' FAILED"
            continue
        fi
        sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
        if [ "$sz" -le "$MIN_DUMP_BYTES" ] || ! gzip -t "$f" 2>>"$LOG"; then
            failed=$((failed + 1)); rm -f "$f"
            err "db leg: dump of '${db}' produced an unusable file (${sz} bytes) — removed, so it cannot be mistaken for a backup"
            continue
        fi
        dumped=$((dumped + 1))
        say "dumped ${db} (${sz} bytes)"
    done

    DB_COUNT="$dumped"
    if [ "$failed" -gt 0 ]; then
        DB_STATE="failed"
        DB_DETAIL="${dumped} of ${found} database(s) dumped; ${failed} FAILED"
        err "db leg: ${failed} of ${found} database(s) FAILED to dump — a partial night is a failed night"
        return
    fi
    DB_STATE="ok"
    DB_DETAIL="${dumped} database(s) dumped"
    [ "$DB_DECLARED" = "undeclared" ] && \
        say "NOTE: SITE_DB_LEG is undeclared on this host; it worked tonight, but declare it so a silent zero can never read as success"
    return 0
}

################################################################################
# 3. nginx configs (server blocks are hand-tuned — cheap to save)
################################################################################
nginx_leg() {
    local d rel=() present=() tarf
    for d in $NGINX_DIRS; do
        [ -d "$d" ] && { present+=("$d"); rel+=("${d#/}"); }
    done
    if [ "${#present[@]}" -eq 0 ]; then
        NGINX_STATE="cannot-verify"
        NGINX_DETAIL="none of the declared config directories exist: ${NGINX_DIRS}"
        err "nginx leg: none of the declared config directories exist (${NGINX_DIRS}) — nothing was staged and that is NOT 'nothing to do'"
        return
    fi
    mkdir -p "$OUT/nginx" || { NGINX_STATE="failed"; err "nginx leg: cannot create $OUT/nginx"; return; }
    tarf="$OUT/nginx/nginx-conf-${STAMP}.tgz"
    # -C / with relative members: no "Removing leading /" warning to sift out of
    # the log, and the archive restores where an operator expects.
    if ! tar czf "$tarf" -C / "${rel[@]}" 2>>"$LOG"; then
        NGINX_STATE="failed"; NGINX_DETAIL="tar failed"
        err "nginx leg: tar of ${present[*]} FAILED"
        return
    fi
    if [ ! -s "$tarf" ] || ! tar tzf "$tarf" >/dev/null 2>>"$LOG"; then
        NGINX_STATE="failed"; NGINX_DETAIL="tarball is empty or unreadable"
        err "nginx leg: the staged tarball is empty or unreadable"
        return
    fi
    NGINX_STATE="ok"; NGINX_DETAIL="$(basename "$tarf") from ${present[*]}"
    say "nginx configs staged"
}

################################################################################
# main
################################################################################
gitlab_leg
db_leg
# Test-only abort knob. A trap that has never been proven to fire is not a trap
# (CLAUDE.md: "a check that has never been proven to fail is not a check"), so
# there is a supported way to make this run die mid-flight.
if [ -n "${NWP_BOX_BACKUP_ABORT_AFTER_DB:-}" ]; then
    printf 'simulated abort after the db leg\n' >&2
    exit 9
fi
nginx_leg

# Local retention BEFORE the verdict is written, so tonight's verdict survives.
find "$OUT" -type f -mtime +"$RETAIN_DAYS" -delete 2>>"$LOG" || true

FAILED=0; CANNOT=0
for s in "$GITLAB_STATE" "$DB_STATE" "$NGINX_STATE"; do
    case "$s" in
        failed|not-run) FAILED=1 ;;
        cannot-verify)  CANNOT=1 ;;
    esac
done

if [ "$FAILED" -eq 1 ]; then
    write_verdict failed 1
    printf 'nwp-box-backup: FAILED — gitlab=%s db=%s nginx=%s (see %s)\n' \
        "$GITLAB_STATE" "$DB_STATE" "$NGINX_STATE" "$VERDICT_FILE" >&2
    log "verdict: FAILED (gitlab=$GITLAB_STATE db=$DB_STATE nginx=$NGINX_STATE)"
    exit 1
fi
if [ "$CANNOT" -eq 1 ]; then
    write_verdict cannot-verify 2
    printf 'nwp-box-backup: CANNOT VERIFY — gitlab=%s db=%s nginx=%s (see %s)\n' \
        "$GITLAB_STATE" "$DB_STATE" "$NGINX_STATE" "$VERDICT_FILE" >&2
    log "verdict: CANNOT VERIFY (gitlab=$GITLAB_STATE db=$DB_STATE nginx=$NGINX_STATE)"
    exit 2
fi
write_verdict ok 0
say "verdict: OK (gitlab=$GITLAB_STATE db=$DB_STATE[$DB_COUNT] nginx=$NGINX_STATE)"
exit 0
