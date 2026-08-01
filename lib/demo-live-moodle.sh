#!/usr/bin/env bash
# lib/demo-live-moodle.sh — the Moodle half of the LIVE demo tier.
#
# WHY THIS FILE EXISTS
# The live-tier plumbing in scripts/commands/demo.sh (demo_live_ctx,
# demo_live_require_demo_mode, cmd_golden_live, cmd_reset_live) was written for
# nwd and is Drupal-shaped throughout: it asks drush for the demo flag, dumps
# with `drush sql:dump`, and archives `sites/default/files`. Moodle has no
# drush, keeps its user data OUTSIDE the docroot in $CFG->dataroot, and stores
# its settings in the `mdl_config` TABLE rather than in config.php.
#
# That last point is a genuine trap and cost this session a wrong conclusion:
# reading config.php with ABORT_AFTER_CONFIG shows `nwp_demo_mode` UNSET on a
# site where it is very much set, because ABORT_AFTER_CONFIG stops before
# Moodle loads DB-stored config. The demo posture (noindex, noemailever, the
# banner, and the demo marker itself) lives in `mdl_config`. Any guard that
# reads config.php is asking the wrong place and will fail OPEN — it will see
# "not a demo site" and refuse, which is safe, or worse, a future variant that
# defaults the other way would see nothing and proceed. So the demo-mode guard
# here reads the TABLE, deliberately and only.
#
# Everything in this file is designed to be callable for a site whose kind is
# `moodle` at tier `live`, and to fail closed: every probe that cannot answer
# prints nothing and returns non-zero, and no caller may treat that as "fine".

[[ -n "${_NWP_DEMO_LIVE_MOODLE_LOADED:-}" ]] && return 0
_NWP_DEMO_LIVE_MOODLE_LOADED=1

# Regenerable Moodle data. Excluded from the golden because it is large,
# churns constantly, and is rebuilt on demand — freezing it into an image that
# is restored every night buys nothing and makes every capture slower and every
# restore riskier. NOT excluded: filedir (the actual user files) and repository
# caches that Moodle does not rebuild.
DEMO_MOODLEDATA_EXCLUDES="${DEMO_MOODLEDATA_EXCLUDES:-cache localcache temp sessions trashdir muc lock}"

# demo_moodle_tar_excludes — the --exclude flags for the moodledata tar.
demo_moodle_tar_excludes() {
    local e out=""
    for e in $DEMO_MOODLEDATA_EXCLUDES; do out+=" --exclude=./${e}"; done
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# demo_moodle_cfg_scalar <ssh-prefix> <site-root> <name>
# Read ONE scalar out of a live Moodle's config.php by text, not by executing
# it. Executing config.php to learn where the site is would be circular, and
# ABORT_AFTER_CONFIG on a broken Moodle prints a fatal error on stdout that the
# 2026-07-31 split proved will be carried onward as if it were a value.
# Prints nothing and fails when the name is absent.
# ---------------------------------------------------------------------------
demo_moodle_cfg_scalar() {
    local prefix="$1" root="$2" name="$3" out
    out=$($prefix "sudo sed -n \"s/.*\\\$CFG->${name}[[:space:]]*=[[:space:]]*'\\([^']*\\)'.*/\\1/p\" ${root}/config.php 2>/dev/null | head -1" </dev/null 2>/dev/null | tr -d '\r' || true)
    # Shape-validate: a Moodle answer is a single token. Prose means the read
    # failed and must not be carried as a value.
    [[ -n "$out" ]] || return 1
    [[ "$out" != *" "* ]] || return 1
    printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# demo_moodle_is_demo <ssh-prefix> <dbname>
# GUARD 2, Moodle flavour: the site must positively declare itself a demo.
#
# Reads `nwp_demo_mode` from the mdl_config TABLE — the same fact
# scripts/demo/ssd-demo-posture.php writes, and deliberately the same opt-in
# shape as nwd's nwc_demo_access.settings demo_mode. Anything other than a
# literal 1 is a refusal, including an unreadable database.
# ---------------------------------------------------------------------------
demo_moodle_is_demo() {
    local prefix="$1" db="$2" val
    val=$($prefix "sudo mysql ${db} -N -e \"SELECT value FROM mdl_config WHERE name='nwp_demo_mode';\" 2>/dev/null" </dev/null 2>/dev/null | tr -d '[:space:]' || true)
    [[ "$val" == "1" ]]
}

# ---------------------------------------------------------------------------
# demo_moodle_last_session <ssh-prefix> <dbname>
# Newest AUTHENTICATED Moodle session timestamp, for the idle guard. Prints an
# integer.
#
# Fails (returns 1) when the answer is missing or not a number. The caller MUST
# treat that as ACTIVE — the nwd wrapper's [G4] learnt this the hard way: a
# failed or garbled sessions query has to count as "someone is here", never as
# "nobody is here", or a database hiccup becomes a licence to wipe.
#
# `userid <> 0` IS LOAD-BEARING, and it is the one place this diverges from the
# Drupal half on purpose. Moodle writes an mdl_sessions row for EVERY anonymous
# request — crawlers, uptime probes, a stray curl. On ssd that is essentially
# all of the traffic: 3931 anonymous rows against 1 authenticated one when this
# was measured (2026-08-01). A guard keyed on MAX(timemodified) over the whole
# table therefore asks "has any robot touched the site in 30 minutes?", and any
# crawler on a sub-30-minute cadence silently vetoes the nightly for ever —
# every run exiting 3 "ACTIVE, retry", nothing ever erased, and the site's own
# banner ("everything here is erased nightly") quietly false. That is the exact
# failure this guard exists to prevent, arrived at from the other direction.
#
# What [G4] is actually protecting is a TESTER mid-flow, and a tester on ssd is
# signed in — they arrive by SSO from nwd. An anonymous page view is not a
# person to be protected; at worst a visitor mid-redirect starts again, which is
# what a nightly reset does to everyone anyway. So the guard counts people.
#
# The Drupal half needs no matching change: its `sessions` table is not written
# on plain anonymous requests, which is why nwd's nightly has been passing this
# guard and firing (27–29 July, reset-ok each night) while ssd's would not have.
# ---------------------------------------------------------------------------
demo_moodle_last_session() {
    local prefix="$1" db="$2" val
    val=$($prefix "sudo mysql ${db} -N -e \"SELECT COALESCE(MAX(timemodified),0) FROM mdl_sessions WHERE userid <> 0;\" 2>/dev/null" </dev/null 2>/dev/null | tr -d '[:space:]' || true)
    [[ "$val" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$val"
}

# ---------------------------------------------------------------------------
# demo_moodle_anon_sessions <ssh-prefix> <dbname>
# Newest ANONYMOUS session timestamp. Never gates anything — it exists so the
# idle decision can be logged with both figures, and so "quiet" is never
# reported when the site is merely quiet of humans.
# ---------------------------------------------------------------------------
demo_moodle_anon_sessions() {
    local prefix="$1" db="$2" val
    val=$($prefix "sudo mysql ${db} -N -e \"SELECT COALESCE(MAX(timemodified),0) FROM mdl_sessions WHERE userid = 0;\" 2>/dev/null" </dev/null 2>/dev/null | tr -d '[:space:]' || true)
    [[ "$val" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$val"
}

# ---------------------------------------------------------------------------
# demo_moodle_idle_ok <last-session-epoch> <now-epoch> <window-seconds>
# PURE. True only when the newest session is older than the window.
# An empty/garbled last-session value is ACTIVE (fail-closed), matching [G4].
# ---------------------------------------------------------------------------
demo_moodle_idle_ok() {
    local last="$1" now="$2" window="$3"
    [[ "$last" =~ ^[0-9]+$ ]] || return 1
    [[ "$now"  =~ ^[0-9]+$ ]] || return 1
    [[ "$window" =~ ^[0-9]+$ ]] || return 1
    (( last == 0 )) && return 0            # no sessions ever recorded
    (( now - last > window ))
}

# Log tables whose SCHEMA belongs in the golden but whose ROWS never do
# (nwp/ops#168). Space-separated, overridable for a site with a different
# logstore.
#
# WHY, with the numbers that forced it. The 2026-08-01 ssd golden carried
# 4,521 `mdl_logstore_standard_log` rows — 74 days deep, 299 distinct public
# visitor IPs, and 652 KB of a 2.40 MB dump (27 % of the whole artifact). A
# golden is a REFERENCE IMAGE that is restored onto the live demo site every
# night, so those rows are not a log: they are an immortal replay. They cannot
# age out, because the thing that would age them out is replaced from the image
# at 01:00; they are duplicated at rest into every golden and every backup of
# one; and on the Drupal half the same defect made the nightly harvest digest
# re-report the identical errors three nights running (ops#168's evidence).
# `mdl_task_log` is EMPTY today and is excluded anyway: it fills exactly when a
# scheduled task fails, which is precisely the state nobody wants frozen.
#
# Nothing is lost. The box wrapper harvests the errors it cares about BEFORE
# the wipe (servers/live/demo/ssd-demo-reset-restricted), and that digest — not
# the golden's copy of the table — is the record.
# `mdl_sessions` was MISSED by the first cut of this list, and it was the worse
# offender of the two. Measured on the ssd golden captured immediately after
# ops#168 landed: logstore was gone, and the dump still carried 3,940
# `mdl_sessions` rows holding 306 distinct public visitor IPs — because Moodle
# writes a session row for EVERY anonymous request (the same fact that forced
# [G4] of the box wrapper to count `userid <> 0`). So the artifact still made
# visitor IPs immortal by nightly restore; only the table they sat in changed.
#
# Restoring session rows is meaningless on top of that: the reset wipes
# moodledata including the session files, and the wrapper's own fate manifest
# already promises "every live session, so everyone signed in is signed out".
# Rows pointing at session files that no longer exist are not state, they are
# just the IPs.
#
# This also restores PARITY with the Drupal half, which has excluded `sessions`
# from the first commit (watchdog,sessions,flood). The two halves disagreeing
# about what a golden may contain is how this was missed.
DEMO_MOODLE_NODATA_TABLES="${DEMO_MOODLE_NODATA_TABLES:-mdl_logstore_standard_log mdl_task_log mdl_sessions}"

# ---------------------------------------------------------------------------
# demo_moodle_dump_cmd <dbname> <out-path>
# The remote dump command. --single-transaction so a live site is not locked;
# --routines/--events so the restore is complete rather than merely populated.
#
# TWO PASSES, and the second one is not optional (nwp/ops#168). A plain
# `--ignore-table` drops the CREATE TABLE along with the rows, and the Moodle
# restore path DROPS THE WHOLE SCHEMA FIRST (demo_moodle_droptables_cmd) — so a
# one-pass exclusion would leave the restored site with those tables simply
# absent, and Moodle fatals the moment anything writes a log row. Pass 1 is the
# data dump minus those tables; pass 2 re-adds their structure with --no-data.
# Both stream into ONE gzip, so the artifact keeps exactly the shape the rest of
# the pipeline (sha256 sidecar, demo_moodle_import_cmd's `gunzip -c`) already
# expects.
#
# The passes are chained with `&&`, not `;`: if the data pass dies, the
# structure pass must not run and hand back a dump that LOOKS complete. Note
# the pre-existing limit this does not fix — the exit status of `… | gzip > f`
# is gzip's, so a mysqldump failure is not visible to the caller here either
# way. That is unchanged from the single-pass version and is the golden
# verifier's gap (it checks sha256, not content), not this function's.
# ---------------------------------------------------------------------------
demo_moodle_dump_cmd() {
    local db="$1" out="$2" t ignore="" structonly=""
    for t in $DEMO_MOODLE_NODATA_TABLES; do
        ignore+=" --ignore-table=${db}.${t}"
        structonly+=" ${t}"
    done
    printf '{ sudo mysqldump --single-transaction --quick --routines --events%s %s && sudo mysqldump --single-transaction --no-data %s%s; } | gzip > %s' \
        "$ignore" "$db" "$db" "$structonly" "$out"
}

# ---------------------------------------------------------------------------
# demo_moodle_dataroot_is_safe <dataroot>
# Refuse to aim a recursive delete at anything that is not plausibly a
# moodledata directory. This is the guard on the single most dangerous string
# in the reset path: an empty or mistyped $dataroot would turn
# `rm -rf ${dataroot}/*` into something catastrophic, and the value arrives
# from a sed over a remote file.
# ---------------------------------------------------------------------------
demo_moodle_dataroot_is_safe() {
    local d="$1"
    [[ -n "$d" ]]                 || return 1
    [[ "$d" == /var/www/* ]]      || return 1   # inside the estate's data area
    [[ "$d" != "/var/www" && "$d" != "/var/www/" ]] || return 1
    [[ "$d" != *".."* ]]          || return 1
    [[ "$d" == *moodledata* ]]    || return 1   # named like what it is
    return 0
}

# ---------------------------------------------------------------------------
# demo_moodle_droptables_cmd <dbname>
# Empty the schema WITHOUT dropping the database.
#
# `DROP DATABASE` would also discard the grants that live against that database
# name, so a restore would leave a site whose credentials no longer work — and
# it would fail late, at the first page load, not at the point of the mistake.
# Dropping the tables instead leaves the database object and its grants intact.
# Foreign-key checks are disabled for the duration because Moodle's schema has
# ordering constraints a flat DROP list cannot respect.
# ---------------------------------------------------------------------------
demo_moodle_droptables_cmd() {
    local db="$1"
    printf 'sudo mysql %s -N -e "SET FOREIGN_KEY_CHECKS=0; SET GROUP_CONCAT_MAX_LEN=1000000; SELECT IFNULL(CONCAT(\x27DROP TABLE IF EXISTS \x27, GROUP_CONCAT(table_name), \x27;\x27),\x27SELECT 1;\x27) FROM information_schema.tables WHERE table_schema=\x27%s\x27;" | sudo mysql %s' \
        "$db" "$db" "$db"
}

# demo_moodle_import_cmd <dbname> <gz-file>
demo_moodle_import_cmd() {
    printf 'gunzip -c %s | sudo mysql %s' "$2" "$1"
}

# ---------------------------------------------------------------------------
# demo_moodle_unpack_files_cmd <dataroot> <gz-file>
# Unpack the golden moodledata and hand it back to www-data. NON-DESTRUCTIVE by
# itself: emptying the directory first is a separate step that deliberately
# lives in the RESET COMMAND, next to the fate manifest that discloses it.
#
# That split is the ops#47 contract's shape, the same one lib/server-sync.sh
# follows: the destructive act and the manifest that discloses it must not be
# separable, or a second caller can drive the destruction with no disclosure.
# A helper that quietly contained `rm -rf` in a lib with no manifest would be
# exactly that — and the repo's own contract gate flags it, correctly.
#
# The regenerable trees excluded from the golden are not preserved across a
# reset: Moodle recreates cache/localcache/temp/muc on demand, and clearing
# `sessions` is exactly what a wipe should do — every tester is logged out,
# which is the point.
# ---------------------------------------------------------------------------
demo_moodle_unpack_files_cmd() {
    local dataroot="${1%/}" file="$2"
    printf 'sudo tar xzf %s -C %s && sudo chown -R www-data:www-data %s && sudo chmod 0700 %s' \
        "$file" "$dataroot" "$dataroot" "$dataroot"
}

# demo_moodle_purge_caches_cmd <site-root> <cli-php>
demo_moodle_purge_caches_cmd() {
    local root="$1" php="${2:-php8.3}"
    [[ "$php" == php* ]] || php="php${php}"
    printf 'cd %s && sudo -u www-data %s -d max_input_vars=5000 admin/cli/purge_caches.php' "$root" "$php"
}

# ---------------------------------------------------------------------------
# demo_moodle_files_tar_cmd <dataroot> <out-path>
# Archive moodledata MINUS the regenerable trees. Runs as root (moodledata is
# 0700 www-data) and hands ownership back so the pull needs no privilege.
# ---------------------------------------------------------------------------
demo_moodle_files_tar_cmd() {
    local dataroot="$1" out="$2" owner="${3:-gitlab}"
    printf 'sudo tar czf %s -C %s%s . && sudo chown %s:%s %s' \
        "$out" "$dataroot" "$(demo_moodle_tar_excludes)" "$owner" "$owner" "$out"
}
