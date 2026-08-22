#!/usr/bin/env bats
################################################################################
# Unit tests for lib/server-backup-resolve.sh — stack-aware backup resolvers
# (ops#112 / NWP-ADR-0032 Flow B). Docker-free, secret-free, filesystem-shape.
################################################################################

source "${BATS_TEST_DIRNAME}/../../lib/server-backup-resolve.sh"

setup() { TMP="$(mktemp -d)"; }
teardown() { rm -rf "$TMP"; }

_mk_moodle() { # $1 dir  [$2=web to nest under web/]
    local d="$1"
    if [ "${2:-}" = web ]; then mkdir -p "$d/web"; printf '<?php\n$release = "4.1.2";\n' > "$d/web/version.php"; printf '<?php\n' > "$d/web/config.php"
    else mkdir -p "$d"; printf '<?php\n$release = "4.1.2";\n' > "$d/version.php"; printf '<?php\n' > "$d/config.php"; fi
}
_mk_drupal() { local d="$1"; mkdir -p "$d/web/sites/default/files"; printf '<?php\n' > "$d/index.php"; }
_mk_ddev_mount() { # $1 site-dir  $2 hostpath
    mkdir -p "$1/.ddev"
    printf 'services:\n  web:\n    volumes:\n      - "%s:/var/www/moodledata:rw"\n' "$2" > "$1/.ddev/docker-compose.moodledata.yaml"
}

# ── sb_detect_stack ───────────────────────────────────────────────────────────

@test "detect_stack: moodle root (version.php with \$release)" {
    _mk_moodle "$TMP/m"
    run sb_detect_stack "$TMP/m"; [ "$output" = moodle ]
}
@test "detect_stack: moodle under web/" {
    _mk_moodle "$TMP/m" web
    run sb_detect_stack "$TMP/m"; [ "$output" = moodle ]
}
@test "detect_stack: drupal (no version.php)" {
    _mk_drupal "$TMP/d"
    run sb_detect_stack "$TMP/d"; [ "$output" = drupal ]
}

# ── sb_moodle_dataroot ────────────────────────────────────────────────────────

@test "moodle_dataroot: reads the DDEV compose mount host path" {
    _mk_moodle "$TMP/m"; _mk_ddev_mount "$TMP/m" "/home/x/sites/ssc1_moodledata"
    run sb_moodle_dataroot "$TMP/m"
    [ "$output" = "/home/x/sites/ssc1_moodledata" ]
}
@test "moodle_dataroot: falls back to <site>/moodledata when nothing else resolves" {
    _mk_moodle "$TMP/m"
    run sb_moodle_dataroot "$TMP/m"
    [ "$output" = "$TMP/m/moodledata" ]
}

# ── sb_backup_files_paths ─────────────────────────────────────────────────────

@test "files_paths: moodle → the moodledata dir (when it exists)" {
    _mk_moodle "$TMP/m"; mkdir -p "$TMP/m/moodledata/filedir"
    run sb_backup_files_paths "$TMP/m"
    [ "$output" = "$TMP/m/moodledata" ]
}
@test "files_paths: drupal → public files + private (both when present)" {
    _mk_drupal "$TMP/d"; mkdir -p "$TMP/d/private"
    run sb_backup_files_paths "$TMP/d"
    [[ "$output" == *"$TMP/d/web/sites/default/files"* ]]
    [[ "$output" == *"$TMP/d/private"* ]]
}
@test "files_paths: drupal public only (no private dir)" {
    _mk_drupal "$TMP/d"
    run sb_backup_files_paths "$TMP/d"
    [[ "$output" == *"web/sites/default/files"* ]]
    [[ "$output" != *"private"* ]]
}

# ── sb_moodle_db_dump (fail-closed guards; the real dump needs a live DB) ──────

@test "moodle_db_dump: usage error without args" {
    run sb_moodle_db_dump ""; [ "$status" -eq 2 ]
}
@test "moodle_db_dump: refuses a site with no config.php (fail-closed)" {
    mkdir -p "$TMP/m"; printf '<?php\n$release="4.1";\n' > "$TMP/m/version.php"
    run sb_moodle_db_dump "$TMP/m" "$TMP/out.sql.gz"
    [ "$status" -eq 1 ]
    [[ "$output" == *"config.php not found"* ]]
}
