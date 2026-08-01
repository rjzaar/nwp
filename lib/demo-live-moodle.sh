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
# Newest Moodle session timestamp, for the idle guard. Prints an integer.
#
# Fails (returns 1) when the answer is missing or not a number. The caller MUST
# treat that as ACTIVE — the nwd wrapper's [G4] learnt this the hard way: a
# failed or garbled sessions query has to count as "someone is here", never as
# "nobody is here", or a database hiccup becomes a licence to wipe.
# ---------------------------------------------------------------------------
demo_moodle_last_session() {
    local prefix="$1" db="$2" val
    val=$($prefix "sudo mysql ${db} -N -e \"SELECT COALESCE(MAX(timemodified),0) FROM mdl_sessions;\" 2>/dev/null" </dev/null 2>/dev/null | tr -d '[:space:]' || true)
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

# ---------------------------------------------------------------------------
# demo_moodle_dump_cmd <dbname> <out-path>
# The remote dump command. --single-transaction so a live site is not locked;
# --routines/--events so the restore is complete rather than merely populated.
# ---------------------------------------------------------------------------
demo_moodle_dump_cmd() {
    local db="$1" out="$2"
    printf 'sudo mysqldump --single-transaction --quick --routines --events %s | gzip > %s' "$db" "$out"
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
