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
        -e "s#^PATH=/usr/local/sbin:#PATH=${BOX}/stubs:/usr/local/sbin:#" \
        "$SCRIPT" > "$REHOMED"
    chmod +x "$REHOMED"
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

@test "control: rehoming is narrow — only the 5 path/PATH lines differ from the shipped script" {
    _build_box
    _rehome
    local changed
    changed="$(diff "$SCRIPT" "$REHOMED" | grep -c '^< ' || true)"
    [ "$changed" -eq 5 ]
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
