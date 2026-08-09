#!/usr/bin/env bats
# D4 / ops#143 — [G9] of the box-resident nwd demo reset must be a GUARANTEE,
# not a wish.
#
# The header of servers/live/demo/nwd-demo-reset-restricted promises:
#
#   [G9] FATE MANIFEST … Nothing destructive runs until the manifest below has
#        been printed AND logged, naming every component and its fate.
#
# Before this file existed the only call site was:
#
#   render_fate_manifest || log "fate-manifest-failed" "non-fatal — proceeding"
#
# i.e. on failure the script recorded that it had no manifest and then wiped the
# site anyway. tests/unit/test-impact-contract.bats proves the manifest RENDERS;
# nothing proved it GATES. That is what this file is for.
#
# WHY THIS HARNESS LOOKS LIKE THIS
#   The script is a forced command deployed to a box with no repo checkout, and
#   its target paths are hard-wired ON PURPOSE ([G2]: there must be no way to
#   name another site). So it cannot be pointed at a fixture by environment
#   variable — adding such a knob would be a hole in the guarantee it exists to
#   provide. Instead the test REHOMES a copy: exactly five literal lines (four
#   path constants + the PATH line that lets stubs win) are rewritten to point
#   inside BATS_TEST_TMPDIR, and `rehoming is narrow` below asserts that those
#   five and only those five differ. Every other byte — all the guard logic —
#   is the shipped file.
#
# NOTHING here touches the network or the real box: curl/sudo/chown/drush are
# stubs on PATH, and every path lives under BATS_TEST_TMPDIR.

setup() {
    PROJECT_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
    SCRIPT="${PROJECT_ROOT}/servers/live/demo/nwd-demo-reset-restricted"
    BOX="${BATS_TEST_TMPDIR}/box"
    TRACE="${BATS_TEST_TMPDIR}/trace.txt"
    REHOMED="${BATS_TEST_TMPDIR}/nwd-demo-reset-rehomed"
    export PROJECT_ROOT SCRIPT BOX TRACE REHOMED
}

# ---------------------------------------------------------------------------
# Sandbox: a fake box just real enough to get past [G1]-[G8]
# ---------------------------------------------------------------------------

_build_box() {
    local site="${BOX}/var/www/nwd"
    local files_parent="${site}/html/sites/default"
    local golden="${BOX}/var/lib/nwp-demo/nwd/golden"
    mkdir -p "${site}/vendor/bin" "${files_parent}/files" "$golden" \
             "${BOX}/var/log/nwp-demo" "${BOX}/var/lock" "${BOX}/stubs"

    : > "$TRACE"

    # A canary standing in for "something a tester uploaded". A real reset must
    # destroy it; an aborted reset must leave it exactly where it is. This is
    # the assertion that does not depend on trusting the stub trace.
    echo "tester upload" > "${files_parent}/files/tester-upload.txt"

    # --- drush (a real file at the real relative path the script uses) ------
    cat > "${site}/vendor/bin/drush" <<'DRUSH'
#!/bin/bash
printf 'drush %s\n' "$*" >> "$NWD_TEST_TRACE"
case "$1" in
    cget)    echo true ;;
    sqlq)    case "$2" in
                 *sessions*) echo "${NWD_TEST_NEWEST_SESSION:-0}" ;;
                 *)          echo 12345678 ;;
             esac ;;
    sql:cli) cat >/dev/null ;;
esac
exit 0
DRUSH
    chmod +x "${site}/vendor/bin/drush"

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
    cat > "${BOX}/stubs/chown" <<'CHOWN'
#!/bin/bash
exit 0
CHOWN
    cat > "${BOX}/stubs/curl" <<'CURL'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$NWD_TEST_TRACE"
printf '200'
CURL
    chmod +x "${BOX}/stubs/sudo" "${BOX}/stubs/chown" "${BOX}/stubs/curl"

    # --- golden image, genuinely sha256-consistent [G3] ---------------------
    ( cd "$golden" \
      && printf -- '-- golden sql\n' | gzip -c > golden.db.sql.gz \
      && mkdir -p stage/files \
      && echo "golden marker" > stage/files/golden-marker.txt \
      && tar czf golden.files.tar.gz -C stage files \
      && rm -rf stage \
      && sha256sum golden.db.sql.gz    > golden.db.sql.gz.sha256 \
      && sha256sum golden.files.tar.gz > golden.files.tar.gz.sha256 \
      && printf '{"site":"nwd","captured_utc":"2026-07-25T00:00:00Z"}\n' \
             > golden.manifest.json ) >/dev/null
}

# Rewrite ONLY the hard-wired absolute paths + the PATH line. Everything else is
# the shipped script, byte for byte (asserted by `rehoming is narrow`).
_rehome() {
    sed -e "s#^SITE_ROOT=\"/var/www/nwd\"#SITE_ROOT=\"${BOX}/var/www/nwd\"#" \
        -e "s#^STATE_DIR=\"/var/lib/nwp-demo/#STATE_DIR=\"${BOX}/var/lib/nwp-demo/#" \
        -e "s#^LOCK_FILE=\"/var/lock/#LOCK_FILE=\"${BOX}/var/lock/#" \
        -e "s#^LOG_FILE=\"/var/log/nwp-demo/#LOG_FILE=\"${BOX}/var/log/nwp-demo/#" \
        -e "s#^TOKEN_FILE=\"/etc/nwp-demo/#TOKEN_FILE=\"${BOX}/etc/nwp-demo/#" \
        -e "s#^PATH=/usr/local/sbin:#PATH=${BOX}/stubs:/usr/local/sbin:#" \
        "$SCRIPT" > "$REHOMED"
    chmod +x "$REHOMED"
}

# Stage the walled api token the ops#315 action words read. Root-owned 0600 on
# the real box; here just a file at the rehomed TOKEN_FILE path.
_stage_token() {
    mkdir -p "${BOX}/etc/nwp-demo"
    printf '%s\n' "glpat-sekret-test-value" > "${BOX}/etc/nwp-demo/feedback.token"
}

# Inject a failing render_fate_manifest immediately before the call site — the
# literal shape of the acceptance test. Matches both the old call form
# (`render_fate_manifest || …`) and the fixed one (`if ! render_fate_manifest`).
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
# This is the REAL failure mode [G9] cares about: the manifest cannot be logged.
_break_the_log() {
    rm -rf "${BOX}/var/log/nwp-demo"
    : > "${BOX}/var/log/nwp-demo"
}

_run_action() {
    SSH_ORIGINAL_COMMAND="$1" \
    SSH_CLIENT="10.0.0.1 1 22" \
    NWD_TEST_TRACE="$TRACE" \
    run bash "$REHOMED"
}

_wiped()      { grep -q 'sql:drop' "$TRACE"; }
_canary_gone() { [[ ! -f "${BOX}/var/www/nwd/html/sites/default/files/tester-upload.txt" ]]; }

# ---------------------------------------------------------------------------
# Negative controls FIRST — a gate that refuses everything is not a gate
# ---------------------------------------------------------------------------

@test "control: the harness's externals are present (a missing tool must name itself, not skip)" {
    # NWP_BATS_MAX_SKIPPED=0 in CI, and a skipped case reads as `ok`. If the
    # runner lacks one of these the sandbox would fail somewhere deep inside a
    # guard with a misleading message, so assert them here by name.
    local t
    for t in jq flock du numfmt tar gzip gunzip sha256sum awk sed diff; do
        command -v "$t" >/dev/null || { echo "missing required tool: $t"; return 1; }
    done
}

@test "control: rehoming is narrow — only the 6 path/PATH lines differ from the shipped script" {
    _build_box
    _rehome
    local changed
    changed="$(diff "$SCRIPT" "$REHOMED" | grep -c '^< ' || true)"
    [ "$changed" -eq 6 ]
    # and the guard logic itself is untouched
    for marker in '\[G1\]' '\[G2\]' '\[G3\]' '\[G4\]' '\[G5\]' '\[G6\]' 'golden_verify' 'require_demo_mode' 'idle_ok'; do
        grep -q "$marker" "$REHOMED"
    done
}

@test "control: a HEALTHY nightly still performs the reset (the gate is not a blanket refusal)" {
    _build_box
    _rehome
    _run_action nightly
    [ "$status" -eq 0 ]
    [[ "$output" == *"FATE MANIFEST"* ]]
    _wiped
    _canary_gone
    [ -f "${BOX}/var/www/nwd/html/sites/default/files/golden-marker.txt" ]
    [ -s "${BOX}/var/lib/nwp-demo/nwd/last-reset" ]
    grep -q 'fate-manifest|' "${BOX}/var/log/nwp-demo/nwd-demo-reset.log"
}

@test "control: a HEALTHY dry-run prints the manifest, changes nothing, exits 0" {
    _build_box
    _rehome
    _run_action dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"FATE MANIFEST"* ]]
    [[ "$output" == *"DRY RUN"* ]]
    ! _wiped
    ! _canary_gone
}

@test "control: [G1] is unchanged — a bad action word is still refused with exit 2" {
    _build_box
    _rehome
    _run_action 'rm -rf /'
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSED"* ]]
    ! _wiped
    ! _canary_gone
}

# ---------------------------------------------------------------------------
# The claim under test
# ---------------------------------------------------------------------------

@test "[G9] a real reset ABORTS when render_fate_manifest fails (stubbed failure)" {
    _build_box
    _rehome
    _stub_manifest_failure
    _run_action nightly
    [ "$status" -ne 0 ]
    [[ "$output" == *"fate-manifest-failed"* ]]
    # The whole point: nothing was destroyed without a printed+logged manifest.
    ! _wiped
    ! _canary_gone
}

@test "[G9] a real reset ABORTS when the manifest cannot be LOGGED (real failure mode)" {
    # The header promises "printed AND logged". log() is deliberately fail-soft,
    # so an unwritable log dir used to mean the manifest was printed, never
    # recorded, and the wipe proceeded — destruction with no record, which is
    # precisely what [G9] says cannot happen.
    _build_box
    _rehome
    _break_the_log
    _run_action nightly
    [ "$status" -ne 0 ]
    [[ "$output" == *"fate-manifest-failed"* ]]
    ! _wiped
    ! _canary_gone
}

@test "[G9] a dry-run with a failing manifest still reports and exits 0" {
    # A dry run has nothing destructive after the manifest, so failing closed
    # there would only remove an operator's ability to look. It stays fail-open.
    _build_box
    _rehome
    _stub_manifest_failure
    _run_action dry-run
    [ "$status" -eq 0 ]
    ! _wiped
    ! _canary_gone
}

@test "[G9] a dry-run whose manifest cannot be logged still exits 0" {
    _build_box
    _rehome
    _break_the_log
    _run_action dry-run
    [ "$status" -eq 0 ]
    ! _wiped
    ! _canary_gone
}

# ---------------------------------------------------------------------------
# [G10] pending-update detection (ops#226)
#
# A golden captured while a hook_update_N was pending restores a PERMANENTLY
# pending site: the reset puts back the pre-update schema and never runs
# updatedb, so the condition survives every night and an operator's manual
# updatedb is undone at 02:00. `pl demo golden` now refuses such a capture, but
# images taken before that guard exist, so the reset must SAY so instead of
# reporting reset-ok.
# ---------------------------------------------------------------------------

# Replace the sandbox drush with one that answers updatedb:status as told.
# $1 = the case-arm body for updatedb:status.
_drush_updatedb_answer() {
    cat > "${BOX}/var/www/nwd/vendor/bin/drush" <<DRUSH
#!/bin/bash
printf 'drush %s\n' "\$*" >> "\$NWD_TEST_TRACE"
case "\$1" in
    cget)    echo true ;;
    sqlq)    case "\$2" in
                 *sessions*) echo "\${NWD_TEST_NEWEST_SESSION:-0}" ;;
                 *)          echo 12345678 ;;
             esac ;;
    sql:cli) cat >/dev/null ;;
    updatedb:status) ${1} ;;
esac
exit 0
DRUSH
    chmod +x "${BOX}/var/www/nwd/vendor/bin/drush"
}

@test "[G10] control: a site with NO pending updates still reports reset-ok" {
    # The negative control for the two cases below: this guard must not be a
    # blanket degrade. (The stock stub prints nothing for updatedb:status,
    # which is exactly what a clean drush does.)
    _build_box
    _rehome
    _run_action nightly
    [ "$status" -eq 0 ]
    grep -q 'reset-ok|' "${BOX}/var/log/nwp-demo/nwd-demo-reset.log"
    run grep -q 'reset-pending-updates' "${BOX}/var/log/nwp-demo/nwd-demo-reset.log"
    [ "$status" -ne 0 ]
}

@test "[G10] a reset that restores a PENDING update degrades instead of reporting reset-ok" {
    _build_box
    _rehome
    _drush_updatedb_answer 'echo "{\"nwc_moodle_data_update_10001\": {\"module\": \"nwc_moodle_data\"}}"'
    _run_action nightly
    [ "$status" -eq 1 ]
    [[ "$output" == *"PENDING after the restore"* ]]
    [[ "$output" == *"nwc_moodle_data_update_10001"* ]]
    # It must name the real remedy: updatedb here is undone by the next reset.
    [[ "$output" == *"re-capture the golden"* ]]
    grep -q 'reset-pending-updates' "${BOX}/var/log/nwp-demo/nwd-demo-reset.log"
    # and it must NOT claim a clean reset
    run grep -q 'reset-ok|' "${BOX}/var/log/nwp-demo/nwd-demo-reset.log"
    [ "$status" -ne 0 ]
}

@test "[G10] an UNREADABLE update state is degraded too — never silently clean" {
    _build_box
    _rehome
    _drush_updatedb_answer 'exit 9'
    _run_action nightly
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not read the site's update state"* ]]
    grep -q 'reset-pending-updates|state=unreadable' "${BOX}/var/log/nwp-demo/nwd-demo-reset.log"
}

# ---------------------------------------------------------------------------
# ops#315 — the box completes its own nightly: feedback-sync + harvest-post
#
# Two new action words on the same fixed allowlist. Both read the ONE walled
# api token from the root-owned TOKEN_FILE; a missing token is exit 2
# CANNOT VERIFY (a leg that could not run and says so), never a silent skip.
# feedback-sync preserves the ops#140 minimisation interlock FAIL-CLOSED on
# this side of the wire: nothing leaves the box unless the deployed module
# provably carries buildIssueDescription.
# ---------------------------------------------------------------------------

# Replace the sandbox drush with one that answers the feedback probes as told.
#   NWD_TEST_FEEDBACK_PROBE   what --dry-run prints (default: pending)
#   NWD_TEST_MINIMISED        php:eval answer (default: MINIMISED-OK)
_drush_feedback_answer() {
    cat > "${BOX}/var/www/nwd/vendor/bin/drush" <<'DRUSH'
#!/bin/bash
printf 'drush %s\n' "$*" >> "$NWD_TEST_TRACE"
case "$1" in
    cget)    echo true ;;
    sqlq)    case "$2" in
                 *sessions*) echo "${NWD_TEST_NEWEST_SESSION:-0}" ;;
                 *)          echo 12345678 ;;
             esac ;;
    sql:cli) cat >/dev/null ;;
    php:eval) echo "${NWD_TEST_MINIMISED:-MINIMISED-OK}" ;;
    nwc-feedback:sync-to-gitlab)
        case "$*" in
            *--dry-run*) echo "${NWD_TEST_FEEDBACK_PROBE:-[DRY] feedback #12 (bug): would sync}" ;;
            *)           echo "[OK] feedback #12 -> nwp/nwc#41" ;;
        esac ;;
    nwc-feedback:sync-status)
        if [[ -n "${NWD_TEST_STATUS_RC:-}" ]]; then
            echo "status leg exploded" >&2
            exit "${NWD_TEST_STATUS_RC}"
        fi
        echo "  feedback #12 -> 16#41 = closed"
        echo "    -> fixed + poster_invited; notified poster."
        echo "Done. advanced=1 drafts_captured=0 checked=1"
        ;;
esac
exit 0
DRUSH
    chmod +x "${BOX}/var/www/nwd/vendor/bin/drush"
}

@test "ops#315 control: the refusal message names the new action words" {
    _build_box
    _rehome
    _run_action 'rm -rf /'
    [ "$status" -eq 2 ]
    [[ "$output" == *"feedback-sync"* ]]
    [[ "$output" == *"harvest-post"* ]]
}

@test "ops#315 feedback-sync with NO token is exit 2 CANNOT VERIFY, logged — never a silent skip" {
    _build_box
    _rehome
    _drush_feedback_answer
    _run_action feedback-sync
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
    grep -q 'feedback-sync-no-token' "${BOX}/var/log/nwp-demo/nwd-demo-reset.log"
    # and nothing was pushed (the push carries --token=)
    run grep -- '--token=' "$TRACE"
    [ "$status" -ne 0 ]
    ! _wiped
}

@test "ops#315 feedback-sync with nothing pending exits 0 and never reads the token" {
    # The probe runs BEFORE the token read (same order as lib/demo.sh), so a
    # quiet night on an unprovisioned box is a clean no-op, not CANNOT VERIFY.
    _build_box
    _rehome
    _drush_feedback_answer
    NWD_TEST_FEEDBACK_PROBE="No feedback items pending GitLab sync" \
    SSH_ORIGINAL_COMMAND=feedback-sync SSH_CLIENT="10.0.0.1 1 22" \
        NWD_TEST_TRACE="$TRACE" run bash "$REHOMED"
    [ "$status" -eq 0 ]
    grep -q 'feedback-sync-empty' "${BOX}/var/log/nwp-demo/nwd-demo-reset.log"
    ! _wiped
}

@test "ops#315 feedback-sync REFUSES fail-closed when the ops#140 minimisation is unverified" {
    _build_box
    _rehome
    _drush_feedback_answer
    _stage_token
    NWD_TEST_MINIMISED="MINIMISATION-MISSING" \
    SSH_ORIGINAL_COMMAND=feedback-sync SSH_CLIENT="10.0.0.1 1 22" \
        NWD_TEST_TRACE="$TRACE" run bash "$REHOMED"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ops#140"* ]]
    grep -q 'feedback-sync-refused|reason=minimisation-unverified' \
        "${BOX}/var/log/nwp-demo/nwd-demo-reset.log"
    # fail-closed means NOTHING left: the real push (with --token=) never ran
    run grep -- '--token=' "$TRACE"
    [ "$status" -ne 0 ]
}

@test "ops#315 feedback-sync pushes through the module's own command and never prints the token" {
    _build_box
    _rehome
    _drush_feedback_answer
    _stage_token
    _run_action feedback-sync
    [ "$status" -eq 0 ]
    # pushed via the module's own drush command, with the box-file token
    grep -q 'nwc-feedback:sync-to-gitlab --limit=100 --token=glpat-sekret-test-value' "$TRACE"
    # the value reaches drush's argv only — never stdout, never the log
    [[ "$output" != *"glpat-sekret-test-value"* ]]
    run grep 'glpat-sekret-test-value' "${BOX}/var/log/nwp-demo/nwd-demo-reset.log"
    [ "$status" -ne 0 ]
    grep -q 'feedback-sync-ok|synced=1' "${BOX}/var/log/nwp-demo/nwd-demo-reset.log"
    ! _wiped
}

# Drop a spooled pre-wipe digest and make curl answer the issues API as told.
#   $1 = the JSON curl prints for a POST (default: an iid)
_spool_digest_and_curl() {
    local json="${1:-}"
    [[ -n "$json" ]] || json='{"iid": 77}'
    mkdir -p "${BOX}/var/lib/nwp-demo/nwd/harvest"
    printf 'watchdog digest body\n' \
        > "${BOX}/var/lib/nwp-demo/nwd/harvest/harvest-20260807-120000.txt"
    cat > "${BOX}/stubs/curl" <<CURL
#!/bin/bash
printf 'curl %s\n' "\$*" >> "\$NWD_TEST_TRACE"
case "\$*" in
    *issues*) printf '%s' '${json}' ;;
    *)        printf '200' ;;
esac
CURL
    chmod +x "${BOX}/stubs/curl"
}

@test "ops#315 harvest-post with NO token is exit 2 CANNOT VERIFY and the digests are KEPT" {
    _build_box
    _rehome
    _spool_digest_and_curl
    _run_action harvest-post
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
    grep -q 'harvest-post-no-token' "${BOX}/var/log/nwp-demo/nwd-demo-reset.log"
    [ -f "${BOX}/var/lib/nwp-demo/nwd/harvest/harvest-20260807-120000.txt" ]
}

@test "ops#315 harvest-post posts each digest to nwp/ops and moves it to posted/" {
    _build_box
    _rehome
    _spool_digest_and_curl
    _stage_token
    _run_action harvest-post
    [ "$status" -eq 0 ]
    # names what it posted, machine-readably, so the verb can mark its copy
    [[ "$output" == *"NWP-HARVEST-POSTED harvest-20260807-120000.txt iid=77"* ]]
    [ ! -f "${BOX}/var/lib/nwp-demo/nwd/harvest/harvest-20260807-120000.txt" ]
    [ -f "${BOX}/var/lib/nwp-demo/nwd/harvest/posted/harvest-20260807-120000.txt" ]
    grep -q 'harvest-posted|file=harvest-20260807-120000.txt issue=#77' \
        "${BOX}/var/log/nwp-demo/nwd-demo-reset.log"
    # the token travels in a 0600 curl config, NEVER in curl's argv
    run grep 'curl .*glpat-sekret-test-value' "$TRACE"
    [ "$status" -ne 0 ]
    grep -q 'curl .*issues' "$TRACE"
}

@test "ops#315 harvest-post: a failed post leaves the digest in the spool for retry, exit 1" {
    _build_box
    _rehome
    _spool_digest_and_curl '{"message":"401 Unauthorized"}'
    _stage_token
    _run_action harvest-post
    [ "$status" -eq 1 ]
    [ -f "${BOX}/var/lib/nwp-demo/nwd/harvest/harvest-20260807-120000.txt" ]
    grep -q 'harvest-post-failed' "${BOX}/var/log/nwp-demo/nwd-demo-reset.log"
}

@test "ops#315 harvest-post with an empty spool is a clean no-op (token present)" {
    _build_box
    _rehome
    _stage_token
    _run_action harvest-post
    [ "$status" -eq 0 ]
    ! _wiped
}

# ---------------------------------------------------------------------------
# ops#219 Phase A — feedback-status: the RETURN leg, box-side.
#
# `drush nwc-feedback:sync-status` is what turns /my/feedback from a permanent
# "Sent to the team" into the link set the operator asked for — and it was
# scheduled NOWHERE. The box already holds the one walled token the command
# needs (ops#315), so the return leg becomes a third action word on the same
# fixed [G1] allowlist, fired hourly from met over the same restricted key.
# nwd-ONLY like feedback-sync: the pending set and /my/feedback are Drupal
# (nwc_feedback) concepts; the ssd suite pins the refusal.
# ---------------------------------------------------------------------------

@test "ops#219 control: the refusal message names feedback-status" {
    _build_box
    _rehome
    _run_action 'rm -rf /'
    [ "$status" -eq 2 ]
    [[ "$output" == *"feedback-status"* ]]
}

@test "ops#219 feedback-status with NO token is exit 2 CANNOT VERIFY, logged — never a silent skip" {
    # Unlike feedback-sync there is no token-free probe: sync-status cannot even
    # LOOK at GitLab without a token, so a missing token is CANNOT VERIFY
    # immediately — reporters keep seeing stale state, and the leg says so.
    _build_box
    _rehome
    _drush_feedback_answer
    _run_action feedback-status
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
    grep -q 'feedback-status-no-token' "${BOX}/var/log/nwp-demo/nwd-demo-reset.log"
    # and the module command never ran
    run grep -- 'nwc-feedback:sync-status' "$TRACE"
    [ "$status" -ne 0 ]
    ! _wiped
}

@test "ops#219 feedback-status runs the module's own sync-status with the walled token — never printed" {
    _build_box
    _rehome
    _drush_feedback_answer
    _stage_token
    _run_action feedback-status
    [ "$status" -eq 0 ]
    grep -q 'nwc-feedback:sync-status --limit=50 --token=glpat-sekret-test-value' "$TRACE"
    # the value reaches drush's argv only — never stdout, never the log
    [[ "$output" != *"glpat-sekret-test-value"* ]]
    [[ "$output" == *"advanced=1"* ]]
    run grep 'glpat-sekret-test-value' "${BOX}/var/log/nwp-demo/nwd-demo-reset.log"
    [ "$status" -ne 0 ]
    grep -q 'feedback-status-ok' "${BOX}/var/log/nwp-demo/nwd-demo-reset.log"
    ! _wiped
}

@test "ops#219 a failing sync-status is exit 1 and logged — never swallowed" {
    _build_box
    _rehome
    _drush_feedback_answer
    _stage_token
    NWD_TEST_STATUS_RC=3 SSH_ORIGINAL_COMMAND=feedback-status SSH_CLIENT="10.0.0.1 1 22" \
        NWD_TEST_TRACE="$TRACE" run bash "$REHOMED"
    [ "$status" -eq 1 ]
    grep -q 'feedback-status-failed' "${BOX}/var/log/nwp-demo/nwd-demo-reset.log"
    ! _wiped
}

# ---------------------------------------------------------------------------
# ops#219 rider — the posted/ move must be as reliable as the POST.
#
# Found live 2026-08-09: posted/ was root-owned (created by a sudo-run harvest),
# so every `mv` to it failed AFTER GitLab had already confirmed the issue — the
# digest stayed in the spool and the next run filed it AGAIN. A digest that is
# posted but not moved is a double-post factory, so the wrapper must either
# repair posted/ or refuse BEFORE posting anything.
# ---------------------------------------------------------------------------

@test "ops#219 harvest-post REFUSES before posting when posted/ cannot be a writable dir (double-post guard)" {
    _build_box
    _rehome
    _spool_digest_and_curl
    _stage_token
    # a regular file where posted/ must be: mkdir -p and install -d both fail
    : > "${BOX}/var/lib/nwp-demo/nwd/harvest/posted"
    _run_action harvest-post
    [ "$status" -eq 1 ]
    [[ "$output" == *"double-post"* ]]
    # the refusal came BEFORE any API call — nothing was posted
    run grep 'curl .*issues' "$TRACE"
    [ "$status" -ne 0 ]
    [ -f "${BOX}/var/lib/nwp-demo/nwd/harvest/harvest-20260807-120000.txt" ]
    grep -q 'harvest-post-refused|reason=posted-dir-unusable' \
        "${BOX}/var/log/nwp-demo/nwd-demo-reset.log"
}

@test "ops#219 harvest-post REPAIRS a wrongly-permissioned posted/ instead of double-posting" {
    _build_box
    _rehome
    _spool_digest_and_curl
    _stage_token
    mkdir -p "${BOX}/var/lib/nwp-demo/nwd/harvest/posted"
    chmod 000 "${BOX}/var/lib/nwp-demo/nwd/harvest/posted"
    _run_action harvest-post
    [ "$status" -eq 0 ]
    [ -f "${BOX}/var/lib/nwp-demo/nwd/harvest/posted/harvest-20260807-120000.txt" ]
    [ ! -f "${BOX}/var/lib/nwp-demo/nwd/harvest/harvest-20260807-120000.txt" ]
}
