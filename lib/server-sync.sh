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

# The destructive act lives HERE, so the fate manifest and the confirmation
# live here too (lib/impact.sh, the ops#47 contract). Putting the gate in the
# caller would mean a second caller could drive these primitives with no
# manifest at all — which is exactly the hole the contract exists to close.
_nwp_sync_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=impact.sh
[[ -f "$_nwp_sync_lib_dir/impact.sh" ]] && source "$_nwp_sync_lib_dir/impact.sh"
unset _nwp_sync_lib_dir

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
# sync_render_and_confirm <from> <to> <do_files> <auto_yes> <site...> — the gate.
#
# Names every database about to be replaced BEFORE asking, and refuses to
# proceed unless confirmed. The report is unconditional; only the prompt is
# skippable. Arrays are read from the caller's plan via nameref so the manifest
# lists real targets rather than a count.
#
# Tier "standard", not "typed": this overwrites databases, but the SOURCE is
# only ever read, so a recovery path survives.
# ---------------------------------------------------------------------------
sync_render_and_confirm() {
    local from="$1" to="$2" do_files="$3" auto_yes="$4"
    local -n _sites="$5"
    local -n _dbs="$6"

    impact_reset
    local i
    for i in "${!_sites[@]}"; do
        impact_overwrite "${to}: database '${_dbs[$i]}'" \
                         "replaced wholesale with ${from}'s live copy (site ${_sites[$i]})"
    done
    if [[ "$do_files" == "1" ]]; then
        for i in "${!_sites[@]}"; do
            impact_overwrite "${to}: ${_sites[$i]} data files" \
                             "rsync --delete from ${from}; files absent on ${from} are REMOVED on ${to}"
        done
    fi
    impact_warn "Anything written on '${to}' since the last sync is lost — this is a one-way copy."
    impact_warn "Run this only while '${to}' is not taking live traffic (see: pl server handoff drain)."
    impact_keep "Source server '${from}' — read-only throughout; dumps only, never modified"
    impact_keep "Every database on '${to}' NOT listed above"
    impact_render

    local confirm_auto=false
    [[ "$auto_yes" == "1" ]] && confirm_auto=true
    impact_confirm standard \
        "overwrite ${#_sites[@]} database(s) on '${to}' with live data from '${from}'" "$confirm_auto"
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

    out=$(printf '%s' "$out" | tr -d '[:space:]')

    # Validate the SHAPE before returning. These probes run application code,
    # and a broken application answers with prose: a Moodle whose dataroot is
    # unwritable prints "Fatal error: \$CFG->dataroot is not writable..." on
    # stdout, which was then reported as though it were the database name. A
    # MySQL identifier is at most 64 characters of word characters, $ and -, so
    # anything else is an error message and must be treated as "unknown".
    if [[ ! "$out" =~ ^[A-Za-z0-9_$-]{1,64}$ ]]; then
        return 1
    fi
    printf '%s' "$out"
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
# sync_probe_datadirs <ssh-prefix> <type> <remote_path> [webroot]
# Prints the absolute paths of the site's MUTABLE DATA directories, one per
# line — the trees that hold uploads and therefore cannot be reconstructed from
# a code deploy. Same rule as the DB name: ask the application where its data
# lives, never assume a layout.
#
# Code is deliberately NOT included. Code arrives via `pl stg2live`; copying it
# between boxes during a migration is how two hosts end up with quietly
# different builds.
# ---------------------------------------------------------------------------
sync_probe_datadirs() {
    local prefix="$1" type="$2" remote_path="$3" webroot="${4:-}"
    case "$type" in
        moodle)
            # $CFG->dataroot is Moodle's own answer and sits OUTSIDE the docroot.
            $prefix "sudo -u www-data php -d error_reporting=0 -d display_errors=0 -r 'define(\"CLI_SCRIPT\",true);define(\"ABORT_AFTER_CONFIG\",true);require(\$argv[1]);echo isset(\$CFG->dataroot)?\$CFG->dataroot:\"\";' ${remote_path}/config.php" 2>/dev/null </dev/null || true
            echo
            ;;
        drupal)
            # drush core:status reports 'root' (the docroot) and 'files' (public
            # files, relative to the site dir). Private files, when configured,
            # come back as an absolute path.
            local cand
            for cand in \
                "cd ${remote_path} && sudo -u www-data vendor/bin/drush core:status --format=json" \
                "cd ${remote_path} && sudo -u www-data drush core:status --format=json" \
                "cd ${remote_path}/${webroot:-web} && sudo -u www-data ../vendor/bin/drush core:status --format=json" \
                "cd ${remote_path}/html && sudo -u www-data ../vendor/bin/drush core:status --format=json"
            do
                local out
                out=$($prefix "$cand 2>/dev/null" 2>/dev/null </dev/null || true)
                [[ -z "$out" ]] && continue
                printf '%s' "$out" | python3 -c '
import json,sys,os,posixpath
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
root=d.get("root","") or ""
site=d.get("site","sites/default") or "sites/default"
for key in ("files","private"):
    v=d.get(key) or ""
    if not v: continue
    # "files" is relative to the docroot; "private" is usually absolute.
    print(v if posixpath.isabs(v) else posixpath.join(root, v))
' 2>/dev/null || true
                return 0
            done
            ;;
    esac
}

# ---------------------------------------------------------------------------
# sync_dir_relay <from-server> <to-server> <abs-path> <stage-root>
# Delta-copies one directory from source to target THROUGH a local staging
# tree. Two rsync hops instead of one, because a direct box-to-box rsync would
# require minting a new trust relationship between two production hosts just to
# run a migration; staging locally keeps the credential surface unchanged and
# costs only disk. Repeat runs are cheap: both hops are deltas.
#
# Takes server NAMES, not ssh prefixes: rsync needs the transport (-e) and the
# host:path separated, and splitting a pre-built prefix string back apart is
# the kind of cleverness that breaks the day a record grows another option.
# ---------------------------------------------------------------------------
sync_dir_relay() {
    local from="$1" to="$2" path="$3" stage_root="$4"
    local sip suser skey dip duser dkey
    sip=$(get_server_ip "$from");   suser=$(get_server_user "$from");  skey=$(get_server_ssh_key "$from")
    dip=$(get_server_ip "$to");     duser=$(get_server_user "$to");    dkey=$(get_server_ssh_key "$to")
    [[ -n "$sip" && -n "$dip" ]] || return 1

    local sopt="ssh -i ${skey} -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
    local dopt="ssh -i ${dkey} -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

    local stage="${stage_root}${path}"
    mkdir -p "$stage" || return 1

    # --fake-super is load-bearing on BOTH hops. The staging tree is written by
    # an unprivileged workstation user, which CANNOT own files as www-data:
    # without this, `rsync -a` silently downgrades every file to the local user,
    # and the second hop then faithfully applies that wrong owner on the target.
    # The observable result is a Moodle that returns HTTP 500 because its
    # dataroot is no longer writable — after a sync that reported success for
    # every tree. --fake-super stores the real ownership in extended attributes
    # on the staging side and restores it on the way out.
    #
    # Trailing slashes: copy the CONTENTS of the directory, not the directory
    # into itself. --delete so a file removed on the source is removed on the
    # target too; a migration that only ever adds is not a copy.
    rsync -a --delete --numeric-ids --fake-super --rsync-path="sudo rsync" \
          -e "$sopt" "${suser}@${sip}:${path}/" "${stage}/" || return 1
    rsync -a --delete --numeric-ids --fake-super --rsync-path="sudo rsync" \
          -e "$dopt" "${stage}/" "${duser}@${dip}:${path}/" || return 1

    # Then PROVE it. The failure above was invisible precisely because nothing
    # compared the two sides afterwards; a copy nobody checked is not a copy.
    local sown town
    sown=$(ssh -i "$skey" -o IdentitiesOnly=yes -o BatchMode=yes -n "${suser}@${sip}" \
             "sudo stat -c '%U:%G:%a' '${path}'" 2>/dev/null || true)
    town=$(ssh -i "$dkey" -o IdentitiesOnly=yes -o BatchMode=yes -n "${duser}@${dip}" \
             "sudo stat -c '%U:%G:%a' '${path}'" 2>/dev/null || true)
    if [[ -z "$sown" || -z "$town" ]]; then
        echo "    cannot verify ownership of ${path} — refusing to call this synced" >&2
        return 1
    fi
    if [[ "$sown" != "$town" ]]; then
        echo "    ownership/mode mismatch on ${path}: source=${sown} target=${town}" >&2
        return 1
    fi
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
