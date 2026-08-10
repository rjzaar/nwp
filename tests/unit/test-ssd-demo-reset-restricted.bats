#!/usr/bin/env bats
# ops#170 — the box-resident ssd demo reset. Sibling of
# tests/unit/test-demo-reset-restricted.bats, which does the same job for the
# Drupal half; read that file's header first, this one only records what is
# DIFFERENT here.
#
# Until this wrapper existed, ssd's banner ("everything here is erased nightly.
# Nothing you enter is kept.") was false: `pl demo reset ssd --tier=live` worked
# but nothing unattended could fire it without handing a scheduler the admin key
# — i.e. root on the box. So the thing under test is not "does a reset work"
# (pl already proves that) but "does the RESTRICTED path refuse everything it
# promises to refuse, and destroy nothing it has not first disclosed".
#
# WHY THIS HARNESS LOOKS LIKE THIS
#   The script is a forced command deployed to a box with no repo checkout and
#   its target paths are hard-wired ON PURPOSE ([G2]: there must be no way to
#   name another site). So it cannot be pointed at a fixture by environment
#   variable — such a knob would be a hole in the guarantee it exists to
#   provide. Instead the test REHOMES a copy: exactly eight literal lines (seven
#   path constants + the PATH line that lets stubs win) are rewritten to point
#   inside BATS_TEST_TMPDIR, and `rehoming is narrow` asserts that those eight
#   and only those eight differ. Every other byte — all the guard logic — is the
#   shipped file.
#
# MOODLE-SPECIFIC POINTS THE DRUPAL SUITE HAS NO EQUIVALENT FOR
#   * The wipe target is $CFG->dataroot, OUTSIDE the docroot, cleared by
#     contents (never removed). Both halves of that are asserted.
#   * The demo flag lives in the mdl_config TABLE, not config.php. A test that
#     satisfied the guard from config.php would be testing the wrong place.
#   * config.php is read only to CHECK the hard-wired constants. A config.php
#     that names a DIFFERENT dataroot must produce a REFUSAL, never a
#     redirection — that is the case that would otherwise wipe the wrong tree.
#
# NOTHING here touches the network or the real box: sudo/mysql/curl/chown/php8.3
# are stubs on PATH, and every path lives under BATS_TEST_TMPDIR.

setup() {
    PROJECT_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
    SCRIPT="${PROJECT_ROOT}/servers/live/demo/ssd-demo-reset-restricted"
    BOX="${BATS_TEST_TMPDIR}/box"
    TRACE="${BATS_TEST_TMPDIR}/trace.txt"
    REHOMED="${BATS_TEST_TMPDIR}/ssd-demo-reset-rehomed"
    export PROJECT_ROOT SCRIPT BOX TRACE REHOMED
}

# ---------------------------------------------------------------------------
# Sandbox: a fake box just real enough to get past [G1]-[G9]
# ---------------------------------------------------------------------------

_build_box() {
    local root="${BOX}/var/www/ssd"
    local dataroot="${BOX}/var/www/ssd_moodledata"
    local golden="${BOX}/var/lib/nwp-demo/ssd/golden"
    mkdir -p "${root}/admin/cli" "${dataroot}/filedir" "$golden" \
             "${BOX}/var/log/nwp-demo" "${BOX}/var/lock" "${BOX}/stubs"

    : > "$TRACE"

    # config.php — read BY TEXT by the wrapper, and by default agreeing with the
    # rehomed constants. `_repoint_config` below makes it disagree.
    cat > "${root}/config.php" <<CFG
<?php
\$CFG = new stdClass();
\$CFG->dbname    = 'ssd';
\$CFG->dbuser    = 'ssd';
\$CFG->dataroot  = '${dataroot}';
\$CFG->prefix    = 'mdl_';
\$CFG->wwwroot   = 'https://ssd.nwpcode.org';
CFG
    : > "${root}/admin/cli/purge_caches.php"

    # Canaries. A real reset must destroy both; an aborted one must leave them
    # exactly where they are. These are the assertions that do not depend on
    # trusting the stub trace.
    echo "tester upload" > "${dataroot}/filedir/tester-upload.txt"
    echo "tester session" > "${dataroot}/sessions-canary.txt"

    # --- PATH stubs --------------------------------------------------------
    cat > "${BOX}/stubs/sudo" <<'SUDO'
#!/bin/bash
while [[ "${1:-}" == -* ]]; do
    case "$1" in
        -u|-g) shift 2 ;;
        *)     shift ;;
    esac
done
exec "$@"
SUDO

    # mysql: two call shapes.
    #   `mysql <db> -N -e "<sql>"`  → answer a query
    #   `mysql <db>`                → swallow a script on stdin (drop / import)
    cat > "${BOX}/stubs/mysql" <<'MYSQL'
#!/bin/bash
sql=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -e) sql="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
if [[ -z "$sql" ]]; then
    # script on stdin — this is the DROP or the IMPORT
    body="$(cat)"
    if [[ "$body" == *"DROP TABLE"* ]]; then
        printf 'mysql DROP-APPLIED\n' >> "$SSD_TEST_TRACE"
    else
        printf 'mysql IMPORT-APPLIED\n' >> "$SSD_TEST_TRACE"
    fi
    exit 0
fi
printf 'mysql -e %s\n' "${sql//$'\n'/ }" >> "$SSD_TEST_TRACE"
case "$sql" in
    *nwp_demo_mode*)        echo "${SSD_TEST_DEMO_MODE-1}" ;;
    *MAX\(timemodified\)*userid\ \<\>\ 0*) echo "${SSD_TEST_NEWEST_SESSION-0}" ;;
    *MAX\(timemodified\)*userid\ =\ 0*)   echo "${SSD_TEST_NEWEST_ANON-0}" ;;
    *data_length*)          echo 16195584 ;;
    *COUNT\(\*\)\ FROM\ mdl_user*)   echo 4 ;;
    *COUNT\(\*\)\ FROM\ mdl_course*) echo 4 ;;
    *DROP\ TABLE*)          echo "DROP TABLE IF EXISTS mdl_user,mdl_course;" ;;
    *task_log*)             echo "" ;;
    *logstore_standard_log*) echo "" ;;
    *)                      echo "" ;;
esac
exit 0
MYSQL

    cat > "${BOX}/stubs/chown" <<'CHOWN'
#!/bin/bash
exit 0
CHOWN
    cat > "${BOX}/stubs/curl" <<'CURL'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$SSD_TEST_TRACE"
printf '%s' "${SSD_TEST_HTTP:-200}"
CURL
    cat > "${BOX}/stubs/php8.3" <<'PHP'
#!/bin/bash
printf 'php8.3 %s\n' "$*" >> "$SSD_TEST_TRACE"
exit 0
PHP
    chmod +x "${BOX}/stubs/sudo" "${BOX}/stubs/mysql" "${BOX}/stubs/chown" \
             "${BOX}/stubs/curl" "${BOX}/stubs/php8.3"

    # --- golden image, genuinely sha256-consistent [G3] ---------------------
    # The archive is a moodledata tree, so it unpacks with `-C $DATAROOT` and
    # its members are relative to the dataroot itself (./filedir/…), exactly as
    # demo_moodle_files_tar_cmd produces them.
    ( cd "$golden" \
      && printf -- '-- golden sql\n' | gzip -c > golden.db.sql.gz \
      && mkdir -p stage/filedir \
      && echo "golden marker" > stage/filedir/golden-marker.txt \
      && tar czf golden.files.tar.gz -C stage . \
      && rm -rf stage \
      && sha256sum golden.db.sql.gz    > golden.db.sql.gz.sha256 \
      && sha256sum golden.files.tar.gz > golden.files.tar.gz.sha256 \
      && printf '{"site":"ssd","captured_utc":"2026-08-01T06:15:32Z"}\n' \
             > golden.manifest.json ) >/dev/null
}

# Rewrite ONLY the hard-wired absolute paths + the PATH line. Everything else is
# the shipped script, byte for byte (asserted by `rehoming is narrow`).
_rehome() {
    sed -e "s#^SITE_ROOT=\"/var/www/ssd\"#SITE_ROOT=\"${BOX}/var/www/ssd\"#" \
        -e "s#^DATAROOT=\"/var/www/ssd_moodledata\"#DATAROOT=\"${BOX}/var/www/ssd_moodledata\"#" \
        -e "s#^DATAROOT_PREFIX=\"/var/www/\"#DATAROOT_PREFIX=\"${BOX}/var/www/\"#" \
        -e "s#^STATE_DIR=\"/var/lib/nwp-demo/#STATE_DIR=\"${BOX}/var/lib/nwp-demo/#" \
        -e "s#^LOCK_FILE=\"/var/lock/#LOCK_FILE=\"${BOX}/var/lock/#" \
        -e "s#^PAIR_LOCK_FILE=\"/var/lock/#PAIR_LOCK_FILE=\"${BOX}/var/lock/#" \
        -e "s#^LOG_FILE=\"/var/log/nwp-demo/#LOG_FILE=\"${BOX}/var/log/nwp-demo/#" \
        -e "s#^TOKEN_FILE=\"/etc/nwp-demo/#TOKEN_FILE=\"${BOX}/etc/nwp-demo/#" \
        -e "s#^PATH=/usr/local/sbin:#PATH=${BOX}/stubs:/usr/local/sbin:#" \
        "$SCRIPT" > "$REHOMED"
    chmod +x "$REHOMED"
}

# Stage the walled api token the ops#315 harvest-post word reads.
_stage_token() {
    mkdir -p "${BOX}/etc/nwp-demo"
    printf '%s\n' "glpat-sekret-test-value" > "${BOX}/etc/nwp-demo/feedback.token"
}

# Point config.php at a DIFFERENT dataroot — the case [G2b] exists for.
_repoint_config() {
    sed -i "s#\$CFG->dataroot  = '.*';#\$CFG->dataroot  = '${BOX}/var/www/other_moodledata';#" \
        "${BOX}/var/www/ssd/config.php"
}

# Inject a failing render_fate_manifest immediately before the call site.
_stub_manifest_failure() {
    awk '
        !done && /^(if ! )?render_fate_manifest([^(]|$)/ {
            print "render_fate_manifest() { echo \"STUB: render failed\" >&2; return 1; }"
            done = 1
        }
        { print }
    ' "$REHOMED" > "${REHOMED}.tmp" && mv "${REHOMED}.tmp" "$REHOMED"
    chmod +x "$REHOMED"
    grep -q 'STUB: render failed' "$REHOMED"   # the injection must have landed
}

# Make the log genuinely unpersistable: LOG_FILE's parent becomes a regular
# file, so both `mkdir -p` and the append fail with ENOTDIR — for root too.
_break_the_log() {
    rm -rf "${BOX}/var/log/nwp-demo"
    : > "${BOX}/var/log/nwp-demo"
}

_run_action() {
    SSH_ORIGINAL_COMMAND="$1" \
    SSH_CLIENT="10.0.0.1 1 22" \
    SSD_TEST_TRACE="$TRACE" \
    run bash "$REHOMED"
}

# The OTHER route into this wrapper, and the one no test exercised until
# ops#329 D6: `sudo /usr/local/bin/ssd-demo-reset-restricted <word>` over the
# ordinary admin ssh. sudo's env_reset strips SSH_ORIGINAL_COMMAND *and*
# SSH_CLIENT, so the action word can only arrive as a positional argument.
_run_action_sudo() {
    unset SSH_ORIGINAL_COMMAND SSH_CLIENT
    SSD_TEST_TRACE="$TRACE" run bash "$REHOMED" "$@"
}

_dropped()      { grep -q 'DROP-APPLIED' "$TRACE"; }
_imported()     { grep -q 'IMPORT-APPLIED' "$TRACE"; }
_canary_gone()  { [[ ! -f "${BOX}/var/www/ssd_moodledata/filedir/tester-upload.txt" ]]; }
_golden_here()  { [[ -f "${BOX}/var/www/ssd_moodledata/filedir/golden-marker.txt" ]]; }

# ---------------------------------------------------------------------------
# Negative controls FIRST — a gate that refuses everything is not a gate
# ---------------------------------------------------------------------------

@test "control: the harness's externals are present (a missing tool must name itself, not skip)" {
    local t
    for t in jq flock du numfmt tar gzip gunzip sha256sum awk sed find stat; do
        command -v "$t" >/dev/null || { echo "missing required tool: $t"; return 1; }
    done
}

@test "control: rehoming is narrow — only the 9 path/PATH lines differ from the shipped script" {
    _build_box
    _rehome
    local changed
    changed="$(diff "$SCRIPT" "$REHOMED" | grep -c '^< ' || true)"
    [ "$changed" -eq 9 ]
    # and the guard logic itself is untouched
    for marker in '\[G1\]' '\[G2\]' '\[G3\]' '\[G4\]' '\[G5\]' '\[G6\]' '\[G9\]' \
                  'golden_verify' 'require_demo_mode' 'idle_ok' 'dataroot_is_safe'; do
        grep -q "$marker" "$REHOMED"
    done
}

@test "control: a HEALTHY nightly performs the reset (the guards are not a blanket refusal)" {
    _build_box
    _rehome
    _run_action nightly
    [ "$status" -eq 0 ]
    [[ "$output" == *"FATE MANIFEST"* ]]
    _dropped
    _imported
    _canary_gone
    _golden_here
    [ -s "${BOX}/var/lib/nwp-demo/ssd/last-reset" ]
    grep -q 'fate-manifest|' "${BOX}/var/log/nwp-demo/ssd-demo-reset.log"
    grep -q 'reset-ok|'      "${BOX}/var/log/nwp-demo/ssd-demo-reset.log"
}

@test "control: a HEALTHY dry-run prints the manifest, changes nothing, exits 0" {
    _build_box
    _rehome
    _run_action dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"FATE MANIFEST"* ]]
    [[ "$output" == *"DRY RUN"* ]]
    ! _dropped
    ! _canary_gone
}

# ---------------------------------------------------------------------------
# [G1] the client's command line is never executed
# ---------------------------------------------------------------------------

@test "[G1] a bad action word is refused with exit 2 and nothing runs" {
    _build_box
    _rehome
    _run_action 'rm -rf /'
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSED"* ]]
    ! _dropped
    ! _canary_gone
}

@test "[G1] a REFUSED command word is logged verbatim but never executed" {
    _build_box
    _rehome
    _run_action 'nightly; touch /tmp/pwned'
    [ "$status" -eq 2 ]
    grep -q 'rejected-command|' "${BOX}/var/log/nwp-demo/ssd-demo-reset.log"
    grep -q 'nightly; touch /tmp/pwned' "${BOX}/var/log/nwp-demo/ssd-demo-reset.log"
    ! _dropped
}

@test "[G1] status and harvest are read-only — they reach no destructive step" {
    _build_box
    _rehome
    _run_action status
    [ "$status" -eq 0 ]
    ! _dropped
    ! _canary_gone
    _run_action harvest
    [ "$status" -eq 0 ]
    ! _dropped
    ! _canary_gone
}

# ---------------------------------------------------------------------------
# [G1] ops#329 D6 — the SUDO route must carry the action word too
#
# MEASURED 2026-08-10. `pl demo status ssd --tier=live` reported
#   "[!] UNKNOWN — the box answered but named no 'last reset'".
# It had asked the box for `status` over the admin path:
#   ssh … "sudo /usr/local/bin/ssd-demo-reset-restricted status"
# and the box answered
#   2026-08-10T12:31:02Z|invoked|action=nightly client=local original=
#   2026-08-10T12:31:02Z|skip-locked|another ssd reset is already running
# The wrapper read its action word ONLY from $SSH_ORIGINAL_COMMAND, which sudo
# strips. The positional `status` was dropped on the floor and the empty string
# fell into the `""|nightly)` arm — so a READ-ONLY monitoring probe asked the
# box to WIPE the site, and only an already-held lock stopped it.
#
# UNKNOWN was the symptom. "status runs a reset" was the defect.
# ---------------------------------------------------------------------------

@test "[G1] ops#329 the action word is honoured on the SUDO route (positional arg)" {
    _build_box
    _rehome
    _run_action_sudo status
    [ "$status" -eq 0 ]
    # The thing the caller parses. Its absence is what rendered as UNKNOWN.
    [[ "$output" == *"last reset:"* ]]
    # …and, far more importantly, it must not have run a reset.
    [[ "$output" != *"action=nightly"* ]]
    ! _dropped
    ! _canary_gone
}

@test "[G1] ops#329 a positional harvest drains, it does not wipe" {
    # `pl demo harvest --pull` takes the same sudo route when the restricted
    # key is not on this host (scripts/commands/demo.sh cmd_harvest).
    _build_box
    _rehome
    _run_action_sudo harvest
    [ "$status" -eq 0 ]
    [[ "$output" != *"action=nightly"* ]]
    ! _dropped
    ! _canary_gone
}

@test "[G1] ops#329 a BAD positional word is refused — it must not fall through to nightly" {
    # The dangerous default: an unrecognised word arriving positionally must
    # take the REFUSED arm, never the empty-string/nightly arm.
    _build_box
    _rehome
    _run_action_sudo 'rm -rf /'
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSED"* ]]
    ! _dropped
    ! _canary_gone
}

@test "[G1] ops#329 the CRON contract survives: no word at all is still nightly" {
    # The forced command runs with SSH_ORIGINAL_COMMAND empty and no argv when
    # the nightly cron fires. Honouring $1 must not break that.
    _build_box
    _rehome
    _run_action_sudo
    [ "$status" -eq 0 ]
    [[ "$output" == *"FATE MANIFEST"* ]]
    _dropped
    _canary_gone
}

# ---------------------------------------------------------------------------
# ops#315 — harvest-post on the Moodle half (and NO feedback-sync, by design)
# ---------------------------------------------------------------------------

@test "ops#315 ssd REFUSES feedback-sync — the Moodle half has no pending set, by design" {
    # local_feedback forwards each report at submit time; a feedback-sync word
    # here would be a capability with nothing behind it. It stays off the
    # allowlist ON PURPOSE, so this must be the [G1] refusal, not a no-op.
    _build_box
    _rehome
    _run_action feedback-sync
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSED"* ]]
    ! _dropped
    ! _canary_gone
}

@test "ops#315 ssd harvest-post with NO token is exit 2 CANNOT VERIFY and the digests are KEPT" {
    _build_box
    _rehome
    mkdir -p "${BOX}/var/lib/nwp-demo/ssd/harvest"
    printf 'task_log digest\n' \
        > "${BOX}/var/lib/nwp-demo/ssd/harvest/harvest-20260807-120000.txt"
    _run_action harvest-post
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
    grep -q 'harvest-post-no-token' "${BOX}/var/log/nwp-demo/ssd-demo-reset.log"
    [ -f "${BOX}/var/lib/nwp-demo/ssd/harvest/harvest-20260807-120000.txt" ]
    ! _dropped
}

@test "ops#315 ssd harvest-post posts to nwp/ops, moves the digest to posted/, token never in argv" {
    _build_box
    _rehome
    _stage_token
    mkdir -p "${BOX}/var/lib/nwp-demo/ssd/harvest"
    printf 'task_log digest\n' \
        > "${BOX}/var/lib/nwp-demo/ssd/harvest/harvest-20260807-120000.txt"
    cat > "${BOX}/stubs/curl" <<'CURL'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$SSD_TEST_TRACE"
case "$*" in
    *issues*) printf '%s' '{"iid": 78}' ;;
    *)        printf '%s' "${SSD_TEST_HTTP:-200}" ;;
esac
CURL
    chmod +x "${BOX}/stubs/curl"
    _run_action harvest-post
    [ "$status" -eq 0 ]
    [[ "$output" == *"NWP-HARVEST-POSTED harvest-20260807-120000.txt iid=78"* ]]
    [ -f "${BOX}/var/lib/nwp-demo/ssd/harvest/posted/harvest-20260807-120000.txt" ]
    [ ! -f "${BOX}/var/lib/nwp-demo/ssd/harvest/harvest-20260807-120000.txt" ]
    grep -q 'harvest-posted|file=harvest-20260807-120000.txt issue=#78' \
        "${BOX}/var/log/nwp-demo/ssd-demo-reset.log"
    run grep 'curl .*glpat-sekret-test-value' "$TRACE"
    [ "$status" -ne 0 ]
    ! _dropped
    ! _canary_gone
}

# ---------------------------------------------------------------------------
# [G2] the target is hard-wired, and three further checks must agree
# ---------------------------------------------------------------------------

@test "[G2b] a config.php naming a DIFFERENT dataroot is a refusal, not a redirection" {
    # The failure this prevents: following config.php would clear a directory
    # the site is not using, report success, and leave the real data intact —
    # a reset that erases nothing while telling every visitor it erased
    # everything. Refusing is the only safe reading of a disagreement.
    _build_box
    _rehome
    _repoint_config
    _run_action nightly
    [ "$status" -ne 0 ]
    [[ "$output" == *"dataroot-mismatch"* ]]
    ! _dropped
    ! _canary_gone
    # and the directory config.php pointed AT was not touched either
    [ ! -d "${BOX}/var/www/other_moodledata" ]
}

@test "[G2c] demo_mode is read from the mdl_config TABLE, and anything but 1 refuses" {
    _build_box
    _rehome
    SSD_TEST_DEMO_MODE=0 SSH_ORIGINAL_COMMAND=nightly SSH_CLIENT="10.0.0.1 1 22" \
        SSD_TEST_TRACE="$TRACE" run bash "$REHOMED"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not-demo-mode"* ]]
    ! _dropped
    ! _canary_gone
}

@test "[G2c] an UNREADABLE demo-mode answer refuses (empty is not a pass)" {
    _build_box
    _rehome
    SSD_TEST_DEMO_MODE="" SSH_ORIGINAL_COMMAND=nightly SSH_CLIENT="10.0.0.1 1 22" \
        SSD_TEST_TRACE="$TRACE" run bash "$REHOMED"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not-demo-mode"* ]]
    ! _dropped
    ! _canary_gone
}

@test "[G2a] a dataroot constant that is not a moodledata path refuses before anything else" {
    _build_box
    _rehome
    sed -i "s#^DATAROOT=\".*\"#DATAROOT=\"${BOX}/var/www\"#" "$REHOMED"
    _run_action nightly
    [ "$status" -ne 0 ]
    [[ "$output" == *"dataroot-shape"* ]]
    ! _dropped
    ! _canary_gone
}

# ---------------------------------------------------------------------------
# [G3] fail-closed on the golden
# ---------------------------------------------------------------------------

@test "[G3] a golden whose manifest names ANOTHER site is refused" {
    _build_box
    _rehome
    printf '{"site":"nwd","captured_utc":"2026-08-01T06:42:14Z"}\n' \
        > "${BOX}/var/lib/nwp-demo/ssd/golden/golden.manifest.json"
    _run_action nightly
    [ "$status" -ne 0 ]
    [[ "$output" == *"golden-verify"* ]]
    ! _dropped
    ! _canary_gone
}

@test "[G3] a CORRUPT golden artifact is refused before a single byte is dropped" {
    _build_box
    _rehome
    printf 'corrupted' >> "${BOX}/var/lib/nwp-demo/ssd/golden/golden.db.sql.gz"
    _run_action nightly
    [ "$status" -ne 0 ]
    [[ "$output" == *"golden-verify"* ]]
    ! _dropped
    ! _canary_gone
}

@test "[G3] a MISSING golden is refused" {
    _build_box
    _rehome
    rm -f "${BOX}/var/lib/nwp-demo/ssd/golden/golden.manifest.json"
    _run_action nightly
    [ "$status" -ne 0 ]
    ! _dropped
    ! _canary_gone
}

# ---------------------------------------------------------------------------
# [G4] idle guard — a hiccup must never read as "nobody is here"
# ---------------------------------------------------------------------------

@test "[G4] a session inside the window exits 3 (retryable) and wipes nothing" {
    _build_box
    _rehome
    SSD_TEST_NEWEST_SESSION="$(date +%s)" SSH_ORIGINAL_COMMAND=nightly \
        SSH_CLIENT="10.0.0.1 1 22" SSD_TEST_TRACE="$TRACE" run bash "$REHOMED"
    [ "$status" -eq 3 ]
    [[ "$output" == *"ACTIVE"* ]]
    ! _dropped
    ! _canary_gone
}

@test "[G4] ANONYMOUS traffic does NOT veto the wipe (a crawler cannot disable the nightly)" {
    # Moodle writes an mdl_sessions row for every anonymous request. On ssd
    # those outnumber signed-in sessions ~4000:1, so a guard that counted them
    # would let any robot on a sub-30-minute cadence silently stop the nightly
    # for ever — every run exiting 3, nothing erased, and the site's banner
    # ("everything here is erased nightly") false. That is [G4]'s own purpose
    # defeated from the other direction, so this case is a REAL reset.
    _build_box
    _rehome
    SSD_TEST_NEWEST_ANON="$(date +%s)" SSH_ORIGINAL_COMMAND=nightly \
        SSH_CLIENT="10.0.0.1 1 22" SSD_TEST_TRACE="$TRACE" run bash "$REHOMED"
    [ "$status" -eq 0 ]
    _dropped
    _canary_gone
}

@test "[G4] the idle decision logs BOTH figures, so a wipe is never called quiet on hearsay" {
    _build_box
    _rehome
    SSD_TEST_NEWEST_ANON=1785569189 SSH_ORIGINAL_COMMAND=dry-run \
        SSH_CLIENT="10.0.0.1 1 22" SSD_TEST_TRACE="$TRACE" run bash "$REHOMED"
    [ "$status" -eq 0 ]
    [[ "$output" == *"newest_user="* ]]
    [[ "$output" == *"newest_anon=1785569189"* ]]
}

@test "[G4] a GARBLED sessions answer counts as ACTIVE, never as idle" {
    _build_box
    _rehome
    SSD_TEST_NEWEST_SESSION="ERROR 1146 (42S02)" SSH_ORIGINAL_COMMAND=nightly \
        SSH_CLIENT="10.0.0.1 1 22" SSD_TEST_TRACE="$TRACE" run bash "$REHOMED"
    [ "$status" -eq 3 ]
    ! _dropped
    ! _canary_gone
}

# ---------------------------------------------------------------------------
# [G5] idempotence — met's cron retries every 30 min and must find a cheap no-op
# ---------------------------------------------------------------------------

@test "[G5] a second nightly on the same Melbourne day is a no-op, not a second wipe" {
    _build_box
    _rehome
    _run_action nightly
    [ "$status" -eq 0 ]
    _dropped
    : > "$TRACE"
    # re-plant the canary so a second wipe would be unmistakable
    echo "tester upload" > "${BOX}/var/www/ssd_moodledata/filedir/tester-upload.txt"
    _run_action nightly
    [ "$status" -eq 0 ]
    [[ "$output" == *"already reset today"* ]]
    ! _dropped
    ! _canary_gone
}

# ---------------------------------------------------------------------------
# [G6] single-flight, and the ADVISORY pair lock
# ---------------------------------------------------------------------------

@test "[G6] a held PAIR lock makes this half stand down (exit 0) without wiping" {
    _build_box
    _rehome
    # hold the nwd half's lock exactly as a mid-reset nwd wrapper would
    exec 7>"${BOX}/var/lock/nwd-demo-reset.lock"
    flock -n 7
    _run_action nightly
    exec 7>&-
    [ "$status" -eq 0 ]
    [[ "$output" == *"nwd half"* ]]
    ! _dropped
    ! _canary_gone
    grep -q 'skip-pair-locked|' "${BOX}/var/log/nwp-demo/ssd-demo-reset.log"
}

@test "[G6] an UNAVAILABLE pair lock is advisory — the reset proceeds and says so" {
    # Fail-closed here would let a permissions change on the OTHER site's lock
    # file silently stop ssd's nightly forever. The pair lock is about box load,
    # not correctness, so it degrades loudly instead of refusing.
    _build_box
    _rehome
    # ONLY the pair lock is made unopenable (a directory → EISDIR on
    # open-for-write). The site's own lock must stay usable, or this would be
    # testing [G6]'s fail-closed half instead of the advisory half.
    rm -f "${BOX}/var/lock/nwd-demo-reset.lock"
    mkdir -p "${BOX}/var/lock/nwd-demo-reset.lock"
    _run_action nightly
    [ "$status" -eq 0 ]
    _dropped
    _canary_gone
    grep -q 'pair-lock-unavailable|' "${BOX}/var/log/nwp-demo/ssd-demo-reset.log"
}

# ---------------------------------------------------------------------------
# [G9] no manifest → no destruction
# ---------------------------------------------------------------------------

@test "[G9] a real reset ABORTS when render_fate_manifest fails (stubbed failure)" {
    _build_box
    _rehome
    _stub_manifest_failure
    _run_action nightly
    [ "$status" -ne 0 ]
    [[ "$output" == *"fate-manifest-failed"* ]]
    ! _dropped
    ! _canary_gone
}

@test "[G9] a real reset ABORTS when the manifest cannot be LOGGED (real failure mode)" {
    _build_box
    _rehome
    _break_the_log
    _run_action nightly
    [ "$status" -ne 0 ]
    [[ "$output" == *"fate-manifest-failed"* ]]
    ! _dropped
    ! _canary_gone
}

@test "[G9] a dry-run with a failing manifest still reports and exits 0" {
    _build_box
    _rehome
    _stub_manifest_failure
    _run_action dry-run
    [ "$status" -eq 0 ]
    ! _dropped
    ! _canary_gone
}

@test "[G9] the manifest names the dataroot, the Article 9 exposure, and the SSO locks" {
    # An operator reads this before consenting; a manifest that named the
    # Drupal path (sites/default/files) would be worse than none, and one that
    # did not mention consent-gated formation data would understate the wipe.
    _build_box
    _rehome
    _run_action dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"${BOX}/var/www/ssd_moodledata"* ]]
    [[ "$output" == *"Article 9"* ]]
    [[ "$output" == *"idnumber"* ]]
    [[ "$output" != *"sites/default/files"* ]]
}

# ---------------------------------------------------------------------------
# The Moodle-shaped restore itself
# ---------------------------------------------------------------------------

@test "the restore DROPS tables before importing (a plain import would leave orphans)" {
    _build_box
    _rehome
    _run_action nightly
    [ "$status" -eq 0 ]
    # order matters: DROP must be recorded before IMPORT
    local drop_line import_line
    drop_line="$(grep -n 'DROP-APPLIED' "$TRACE" | head -1 | cut -d: -f1)"
    import_line="$(grep -n 'IMPORT-APPLIED' "$TRACE" | head -1 | cut -d: -f1)"
    [ -n "$drop_line" ] && [ -n "$import_line" ]
    [ "$drop_line" -lt "$import_line" ]
}

@test "the dataroot DIRECTORY survives — only its contents are cleared" {
    # `rm -rf $DATAROOT` would take the directory's ownership and 0700 mode with
    # it, and Moodle would refuse to start on a dataroot it cannot read.
    _build_box
    _rehome
    local ino_before ino_after
    ino_before="$(stat -c '%i' "${BOX}/var/www/ssd_moodledata")"
    _run_action nightly
    [ "$status" -eq 0 ]
    [ -d "${BOX}/var/www/ssd_moodledata" ]
    # same inode = the directory was CLEARED, not removed and recreated
    ino_after="$(stat -c '%i' "${BOX}/var/www/ssd_moodledata")"
    [ "$ino_before" = "$ino_after" ]
    # and it is left at the 0700 Moodle refuses to start without
    [ "$(stat -c '%a' "${BOX}/var/www/ssd_moodledata")" = "700" ]
}

@test "a FAILED smoke check degrades the exit status instead of stamping success" {
    _build_box
    _rehome
    SSD_TEST_HTTP=500 SSH_ORIGINAL_COMMAND=nightly SSH_CLIENT="10.0.0.1 1 22" \
        SSD_TEST_TRACE="$TRACE" run bash "$REHOMED"
    [ "$status" -eq 1 ]
    [[ "$output" == *"treat as FAILED"* ]]
    # the data WAS restored, but the day must not be stamped as done
    [ ! -s "${BOX}/var/lib/nwp-demo/ssd/last-reset" ]
}

@test "no reseed and no invite-code sync are attempted (they are provider-side)" {
    _build_box
    _rehome
    _run_action nightly
    [ "$status" -eq 0 ]
    ! grep -q 'seed-demo' "$TRACE"
    ! grep -q 'codes' "$TRACE"
}

@test "caches are purged with php8.3 and a raised max_input_vars, not the box default php" {
    _build_box
    _rehome
    _run_action nightly
    [ "$status" -eq 0 ]
    grep -q 'php8.3 .*max_input_vars=5000 admin/cli/purge_caches.php' "$TRACE"
}

# ---------------------------------------------------------------------------
# ops#219 — the RETURN leg (feedback-status) is nwd-ONLY, and the posted/ move
# must be as reliable as the POST (double-post guard; found live 2026-08-09
# when a root-owned posted/ made every post-then-move fail its second half).
# ---------------------------------------------------------------------------

@test "ops#219 ssd REFUSES feedback-status — the return leg is nwd-only, by design (pinned negative)" {
    # /my/feedback and the pending set are nwc_feedback (Drupal) concepts; the
    # Moodle half forwards at submit time and has no return leg to run. The
    # word stays off THIS allowlist on purpose, and the refusal must SAY so.
    _build_box
    _rehome
    _run_action feedback-status
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSED"* ]]
    [[ "$output" == *"feedback-status"* ]]
    ! _dropped
    ! _canary_gone
}

@test "ops#219 ssd harvest-post REFUSES before posting when posted/ cannot be a writable dir" {
    _build_box
    _rehome
    _stage_token
    mkdir -p "${BOX}/var/lib/nwp-demo/ssd/harvest"
    printf 'task_log digest\n' \
        > "${BOX}/var/lib/nwp-demo/ssd/harvest/harvest-20260807-120000.txt"
    # a regular file where posted/ must be: mkdir -p and install -d both fail
    : > "${BOX}/var/lib/nwp-demo/ssd/harvest/posted"
    _run_action harvest-post
    [ "$status" -eq 1 ]
    [[ "$output" == *"double-post"* ]]
    # nothing was posted: the refusal came before any API call
    run grep 'curl .*issues' "$TRACE"
    [ "$status" -ne 0 ]
    [ -f "${BOX}/var/lib/nwp-demo/ssd/harvest/harvest-20260807-120000.txt" ]
    grep -q 'harvest-post-refused|reason=posted-dir-unusable' \
        "${BOX}/var/log/nwp-demo/ssd-demo-reset.log"
    ! _dropped
}

@test "ops#219 ssd harvest-post REPAIRS a wrongly-permissioned posted/ instead of double-posting" {
    _build_box
    _rehome
    _stage_token
    mkdir -p "${BOX}/var/lib/nwp-demo/ssd/harvest"
    printf 'task_log digest\n' \
        > "${BOX}/var/lib/nwp-demo/ssd/harvest/harvest-20260807-120000.txt"
    mkdir -p "${BOX}/var/lib/nwp-demo/ssd/harvest/posted"
    chmod 000 "${BOX}/var/lib/nwp-demo/ssd/harvest/posted"
    cat > "${BOX}/stubs/curl" <<'CURL'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$SSD_TEST_TRACE"
case "$*" in
    *issues*) printf '%s' '{"iid": 79}' ;;
    *)        printf '%s' "${SSD_TEST_HTTP:-200}" ;;
esac
CURL
    chmod +x "${BOX}/stubs/curl"
    _run_action harvest-post
    [ "$status" -eq 0 ]
    [ -f "${BOX}/var/lib/nwp-demo/ssd/harvest/posted/harvest-20260807-120000.txt" ]
    [ ! -f "${BOX}/var/lib/nwp-demo/ssd/harvest/harvest-20260807-120000.txt" ]
    ! _dropped
}

# ---------------------------------------------------------------------------
# [G1] static: the client's string is never in a command position
#
# The Drupal half has carried this check since ops#133 (test-demo.bats). The
# Moodle half never did — and ops#329 D6 has just WIDENED where the client's
# word can arrive from (argv as well as $SSH_ORIGINAL_COMMAND), so the gap
# stops being theoretical. Same property, same two shapes of failure proven
# below before the tick above is believed.
# ---------------------------------------------------------------------------

_client_input_uses_are_safe() {
    local f="$1" line
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *'scrub "$RAW_CMD"'* ]] && continue
        if [[ "$line" == *'$('* || "$line" == *'`'* || "$line" == *'eval'* ]]; then
            echo "unsafe use of client input (command substitution): $line"; return 1
        fi
        [[ "$line" =~ ^[[:space:]]*(RAW_CMD|ARGV_CMD)=\" ]] && continue
        [[ "$line" == *'[['*']]'* ]]                        && continue
        [[ "$line" == *'case "$RAW_CMD" in'* ]]             && continue
        echo "unsafe use of client input: $line"; return 1
    done < <(grep -E 'RAW_CMD|ARGV_CMD' "$f")
    return 0
}

@test "[G1] the ssd wrapper never evals or shells out to client input" {
    ! grep -qE '\beval\b' "$SCRIPT"
    ! grep -qE '(sh|bash) +-c +.*SSH_ORIGINAL_COMMAND' "$SCRIPT"
    _client_input_uses_are_safe "$SCRIPT"
}

@test "[G1] NEGATIVE CONTROL: that guard actually rejects an unsafe use" {
    local copy="${BATS_TEST_TMPDIR}/wrapper-unsafe"
    cp "$SCRIPT" "$copy"
    printf '\n$RAW_CMD\n' >> "$copy"
    run _client_input_uses_are_safe "$copy"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsafe use of client input"* ]]

    cp "$SCRIPT" "$copy"
    printf '\nX="$(echo "$ARGV_CMD")"\n' >> "$copy"
    run _client_input_uses_are_safe "$copy"
    [ "$status" -ne 0 ]
    [[ "$output" == *"command substitution"* ]]

    run _client_input_uses_are_safe "$SCRIPT"
    [ "$status" -eq 0 ]
}
