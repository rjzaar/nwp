#!/usr/bin/env bats
# nwp/ops#47 + item 7 — the impact-report contract, mechanically enforced.
#
# CONTRACT: no destructive verb acts on inferred scope. Any script performing
# destructive operations (rm -rf, ddev delete, DB drops, rsync --delete
# overwrites) must ADOPT lib/impact.sh — print a computed fate manifest before
# acting; -y skips the prompt, never the report.
#
# WHY THIS FILE CHANGED (item 7). The previous version of this gate:
#   * gated on `grep -q 'lib/impact.sh' "$f"` — a STRING MENTION. A file with
#     `rm -rf "$1"` plus the comment "does NOT source lib/impact.sh" passed all
#     four cases green. Cases 5 and 6 below are that exact probe, and they were
#     observed RED against the pre-fix gate before this rewrite landed.
#   * scanned ONLY `scripts/commands/*.sh`. lib/ and servers/ — where the actual
#     destructive engines live, and where destructive logic is MIGRATING — were
#     never looked at. Case 7 is that probe.
#
# The scan/adoption/allowlist logic itself lives in lib/impact.sh so this test,
# CI and any `pl` verb run the SAME code rather than three drifting copies.

setup() {
    PROJECT_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
    export PROJECT_ROOT
    source "${PROJECT_ROOT}/lib/impact.sh"
    PROBES=()
}

teardown() {
    local p
    for p in "${PROBES[@]:-}"; do
        [ -n "$p" ] && rm -f "$p"
    done
    rm -f "${BATS_TEST_TMPDIR:-/tmp}/allowlist.txt"
}

# _probe <repo-relative path> <content> — plant a file, register it for teardown.
_probe() {
    local rel="$1"; shift
    PROBES+=("${PROJECT_ROOT}/${rel}")
    printf '%s\n' "$1" > "${PROJECT_ROOT}/${rel}"
}

# ---------------------------------------------------------------------------
# The real tree
# ---------------------------------------------------------------------------

@test "every destructive script adopts lib/impact.sh or is on the frozen allowlist" {
    run impact_contract_violations
    if [ "$status" -ne 0 ]; then
        echo "Destructive file(s) without the impact contract:" >&2
        echo "$output" >&2
        echo "Adopt lib/impact.sh (source + impact_render + impact_confirm) — see delete.sh." >&2
        return 1
    fi
}

@test "allowlist is shrink-only: no stale entries for converted/removed files" {
    run impact_contract_stale_allowlist
    if [ "$status" -ne 0 ]; then
        echo "Stale allowlist entries — delete them so the list only shrinks:" >&2
        echo "$output" >&2
        return 1
    fi
}

@test "the gate scans lib/ and servers/, not just scripts/commands/" {
    run impact_contract_candidates
    [ "$status" -eq 0 ]
    # The pre-item-7 gate saw none of these three roots' contents together.
    [[ "$output" == *"scripts/commands/delete.sh"* ]]
    [[ "$output" == *"lib/moodle-promote.sh"* ]]
    [[ "$output" == *"servers/live/demo/nwd-demo-reset-restricted"* ]]
}

@test "the gate has a non-trivial corpus (cannot pass over an empty scan)" {
    local n
    n="$(impact_contract_candidates | wc -l)"
    [ "$n" -gt 40 ]
}

# ---------------------------------------------------------------------------
# Self-tests of the DETECTOR — each was RED against the pre-item-7 gate.
# ---------------------------------------------------------------------------

@test "DETECTOR: a comment-only mention of lib/impact.sh does NOT satisfy the contract" {
    # RED before the fix: the old gate's `grep -q 'lib/impact.sh'` matched the
    # comment and passed this file.
    _probe "scripts/commands/zz-probe-mention.sh" '#!/bin/bash
# This file does NOT source lib/impact.sh and that used to be enough.
wipe() { rm -rf "$1"; }'
    run impact_contract_violations
    [ "$status" -ne 0 ]
    [[ "$output" == *"zz-probe-mention.sh"* ]]
}

@test "DETECTOR: sourcing impact.sh without rendering a manifest is NOT adoption" {
    # A confirm with no manifest is the prompt without the information that
    # makes it meaningful. (scripts/commands/branch.sh is a real instance.)
    _probe "scripts/commands/zz-probe-noreport.sh" '#!/bin/bash
source "$PROJECT_ROOT/lib/impact.sh"
impact_confirm standard "wipe it" "false" || exit 1
rm -rf "$1"'
    run impact_contract_violations
    [ "$status" -ne 0 ]
    [[ "$output" == *"zz-probe-noreport.sh"* ]]
}

@test "DETECTOR: a destructive lib/ file with no contract is flagged" {
    # RED before the fix: lib/ was never scanned at all.
    _probe "lib/zz-probe-lib.sh" '#!/bin/bash
zz_wipe() { rm -rf "$1"; }'
    run impact_contract_violations
    [ "$status" -ne 0 ]
    [[ "$output" == *"lib/zz-probe-lib.sh"* ]]
}

@test "DETECTOR: a fully adopting probe is NOT flagged (no false positive)" {
    _probe "scripts/commands/zz-probe-good.sh" '#!/bin/bash
source "$PROJECT_ROOT/lib/impact.sh"
impact_reset
impact_delete "Files" "/tmp/x"
impact_render
impact_confirm standard "delete it" "false" || exit 1
rm -rf "$1"'
    run impact_contract_violations
    [ "$status" -eq 0 ]
}

@test "DETECTOR: documenting rm -rf in a comment does not drag a file into the contract" {
    _probe "lib/zz-probe-comment.sh" '#!/bin/bash
# Historically this ran rm -rf on the tree; it no longer does.
zz_noop() { :; }'
    run impact_contract_violations
    [ "$status" -eq 0 ]
}

@test "DETECTOR: the inline pragma alone is not enough — it needs a real manifest" {
    # Box-resident scripts (forced commands on a server with no checkout) may
    # declare `# impact-contract: inline`, but the pragma must be BACKED by an
    # emitted FATE MANIFEST. A pragma with no manifest is the same vacuous pass
    # in a new costume, so it is explicitly rejected.
    _probe "lib/zz-probe-pragma.sh" '#!/bin/bash
# impact-contract: inline
zz_wipe() { rm -rf "$1"; }'
    run impact_contract_violations
    [ "$status" -ne 0 ]
    [[ "$output" == *"zz-probe-pragma.sh"* ]]
}

@test "DETECTOR: an inline pragma WITH a manifest is accepted" {
    _probe "lib/zz-probe-pragma-ok.sh" '#!/bin/bash
# impact-contract: inline
echo "FATE MANIFEST"
echo "  DELETE: $1"
zz_wipe() { rm -rf "$1"; }'
    run impact_contract_violations
    [ "$status" -eq 0 ]
}

@test "DETECTOR: a converted file left on the allowlist is a hard failure" {
    # delete.sh genuinely adopts the contract; parking it on the allowlist must
    # be caught, or the list stops shrinking and quietly becomes a rubber stamp.
    local fake="${BATS_TEST_TMPDIR}/allowlist.txt"
    echo "scripts/commands/delete.sh   # bogus" > "$fake"
    NWP_IMPACT_ALLOWLIST="$fake" run impact_contract_stale_allowlist
    [ "$status" -ne 0 ]
    [[ "$output" == *"CONVERTED"* ]]
}

# ---------------------------------------------------------------------------
# D3 — IMPACT_DESTRUCTIVE_PATTERN must be FLAG-ORDER AGNOSTIC.
#
# The pattern is what forces a script into the fate-manifest contract, so every
# spelling it misses is a destructive script that ships with no manifest and no
# allowlist row — invisibly, with the gate green. The pre-D3 pattern carried the
# literal alternative `rm -rf`, so `rm -fr`, `rm -r -f`, `rm -f -r`,
# `rm --recursive --force` and `rm -rvf` all walked straight past it.
#
# These rows are a FIXTURE TABLE on purpose: the regex is not readable enough to
# review by eye, so it is judged by what it does to inputs, not by how it looks.
# Every MUST-MATCH row below was RED before the D3 fix (recorded in the MR).
# ---------------------------------------------------------------------------

# _is_destructive <code line> — run the real detector over a one-line file.
_is_destructive() {
    local f="${BATS_TEST_TMPDIR}/d3probe.sh"
    printf '#!/bin/bash\n%s\n' "$1" > "$f"
    impact_is_destructive "$f"
}

@test "D3: recursive rm is detected whatever the flag order or spelling" {
    local fails=0 c
    # Every spelling of "delete a tree" that a real script might use.
    for c in \
        'rm -rf /tmp/x' \
        'rm -fr /tmp/x' \
        'rm -r -f /tmp/x' \
        'rm -f -r /tmp/x' \
        'rm --recursive --force /tmp/x' \
        'rm -rvf /tmp/x' \
        'rm -Rf /tmp/x' \
        'rm -r /tmp/x' \
        'sudo rm -fr "$dir"' \
        '    rm -rf "${dir}"' \
        'ssh box "rm -fr /var/www/x"'
    do
        if ! _is_destructive "$c"; then
            echo "MISSED (should be destructive): $c" >&2
            fails=$((fails + 1))
        fi
    done
    [ "$fails" -eq 0 ]
}

@test "D3: incidental rm mentions are NOT dragged into the contract" {
    # The specific condition that makes a careless widening go red: a pattern
    # that just looks for the letters r and f near "rm" flags half the repo,
    # and a gate that flags everything is a gate nobody can keep green.
    local fails=0 c
    for c in \
        'rm -f /tmp/x' \
        'rm --force /tmp/x' \
        'rm file.rf' \
        'rm "$tmpfile"' \
        'rmdir -p /tmp/x' \
        'confirm -rf' \
        'rm "$d" && grep -r pattern /etc' \
        'echo "removing the stale lock"' \
        'FORM_RF=1'
    do
        if _is_destructive "$c"; then
            echo "FALSE POSITIVE (should not be destructive): $c" >&2
            fails=$((fails + 1))
        fi
    done
    [ "$fails" -eq 0 ]
}

@test "D3: a full-line comment containing rm -rf is stripped before matching" {
    # _impact_code_lines is *supposed* to drop comments so a file that merely
    # documents rm -rf is not dragged in. This asserts it actually does.
    ! _is_destructive '# rm -rf /tmp/x   <- documented, not executed'
    ! _is_destructive '   #rm -rf /tmp/x'
}

@test "D3: KNOWN LIMITATION — a TRAILING comment still counts as code" {
    # _impact_code_lines only drops lines that BEGIN with a comment marker.
    # Stripping trailing `#...` was considered and rejected: `rm -rf "${x#foo}"`
    # is a real destructive line containing a `#`, so naive trailing-comment
    # stripping would BLIND the gate to it. Over-matching a stray trailing
    # comment costs one allowlist conversation; under-matching costs a site.
    # This test pins the trade-off so a future "cleanup" has to argue with it.
    _is_destructive 'true   # rm -rf /tmp/x'
}

@test "D3: the non-rm arms of the pattern still fire" {
    # Negative control on the negative control: if a fix broke the detector into
    # a yes-machine or a no-machine, one of these two tests catches it.
    _is_destructive 'ddev delete --omit-snapshot --yes'
    _is_destructive 'mysql -e "DROP DATABASE nwp"'
    _is_destructive 'drush sql:drop -y'
    _is_destructive 'rsync -a --delete src/ dst/'
}

@test "D3: the detector is not a yes-machine (benign script stays benign)" {
    local f="${BATS_TEST_TMPDIR}/d3benign.sh"
    cat > "$f" <<'BENIGN'
#!/bin/bash
set -euo pipefail
name="$1"
mkdir -p "/tmp/$name"
cp -a src/. "/tmp/$name/"
grep -rn TODO "/tmp/$name" || true
printf 'done: %s\n' "$name"
BENIGN
    ! impact_is_destructive "$f"
}

# ---------------------------------------------------------------------------
# ops#143 — the box-resident demo reset renders a REAL manifest, not a comment
# ---------------------------------------------------------------------------

# The forced command lives on the git box with no repo checkout, so it cannot
# source lib/impact.sh and its manifest is inline. That makes "does the manifest
# actually render?" a question only execution can answer — reading the file
# proves nothing. Extract the render function, stub every external it touches,
# run it, and assert the text.
_render_demo_manifest() {
    local f="${PROJECT_ROOT}/servers/live/demo/nwd-demo-reset-restricted"
    local harness="${BATS_TEST_TMPDIR}/render.sh"
    {
        echo '#!/bin/bash'
        echo 'SITE=nwd; DOMAIN=nwd.nwpcode.org; SITE_ROOT=/var/www/nwd'
        echo 'FILES_PARENT=/var/www/nwd/html/sites/default'
        echo 'GOLDEN_DIR=/var/lib/nwp-demo/nwd/golden; GOLDEN_DB=golden.db.sql.gz'
        echo 'HARVEST_DIR=/var/lib/nwp-demo/nwd/harvest'
        echo 'LOG_FILE=/dev/null; ACTION=dry-run'
        echo "CODES_PAYLOAD='${1:-}'"
        # Stubs: the box's tools are not here and must not be invoked.
        echo 'drush() { echo 123456789; }'
        echo 'du() { echo "42M   x"; }'
        echo 'log() { :; }'
        sed -n '/^_size_of()/,/^}/p'             "$f"
        sed -n '/^render_fate_manifest()/,/^}$/p' "$f"
        echo 'render_fate_manifest'
    } > "$harness"
    bash "$harness"
}

@test "ops#143: the nwd demo reset renders a real FATE MANIFEST when executed" {
    run _render_demo_manifest ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"FATE MANIFEST"* ]]
    # Every fate class must be named, and the uploads must be called out as
    # unrecoverable — that is the whole point of the report.
    [[ "$output" == *"WILL BE PERMANENTLY DELETED"* ]]
    [[ "$output" == *"WILL BE OVERWRITTEN"* ]]
    [[ "$output" == *"NOT AFFECTED"* ]]
    [[ "$output" == *"there is no copy"* ]]
    [[ "$output" == *"nwd"* ]]
}

@test "ops#143: the manifest reports an unstaged invite-code payload honestly" {
    # An absent payload must read as "not-staged", not as a confident zero.
    run _render_demo_manifest "/nonexistent/codes.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not-staged"* ]]
}

@test "ops#143: the demo reset satisfies the contract via the inline pragma" {
    impact_contract_adopted "${PROJECT_ROOT}/servers/live/demo/nwd-demo-reset-restricted"
}

# ---------------------------------------------------------------------------
# ops#170 — the Moodle half. A SECOND box-resident wrapper is a second chance
# to ship a recursive delete with no disclosure, so it is held to the same gate
# by name rather than left to the corpus scan.
# ---------------------------------------------------------------------------

@test "ops#170: the ssd demo reset is IN the gate's corpus (it clears a moodledata tree)" {
    run impact_contract_candidates
    [ "$status" -eq 0 ]
    [[ "$output" == *"servers/live/demo/ssd-demo-reset-restricted"* ]]
}

@test "ops#170: the ssd demo reset satisfies the contract via the inline pragma" {
    impact_contract_adopted "${PROJECT_ROOT}/servers/live/demo/ssd-demo-reset-restricted"
}

# ---------------------------------------------------------------------------
# Converted verbs stay converted
# ---------------------------------------------------------------------------

@test "converted verbs stay converted: delete.sh adopts lib/impact.sh" {
    impact_contract_adopted "${PROJECT_ROOT}/scripts/commands/delete.sh"
}

@test "TUI delete stays a delegation, not a fourth implementation" {
    ! grep -qE 'rm -rf "\$directory"|rm -rf "\$site_dir"' "${PROJECT_ROOT}/scripts/commands/status.sh"
    grep -q 'delete.sh' "${PROJECT_ROOT}/scripts/commands/status.sh"
}

# ---------------------------------------------------------------------------
# ops#351 — SIZE. Every fixture above is two or three lines long, so none of
# them could ever have caught what was actually wrong with this gate.
#
# `impact_is_destructive` was `_impact_code_lines "$1" | grep -qE "$PATTERN"`.
# Under `set -o pipefail` — which every caller runs under — `grep -q` leaves on
# the first match, the writer is killed by SIGPIPE and exits 141, and pipefail
# makes 141 the verdict. On a file bigger than the 64 KiB pipe buffer the writer
# is ALWAYS still writing, so the answer is ALWAYS wrong. Measured on the
# shipped tree, 50 calls each, BEFORE the fix:
#
#     scripts/commands/demo.sh      330 KB, destructive -> said CLEAN 50/50
#     scripts/commands/stg2live.sh  108 KB, destructive -> said CLEAN 50/50
#     scripts/commands/verify.sh    168 KB, destructive -> said CLEAN  1/50
#
# and `impact_contract_violations` reads `impact_is_destructive … || continue`,
# so those files were SKIPPED — the gate could not have reported a missing fate
# manifest in the two largest destructive scripts in the repo.
#
# These cases fail against the pre-fix lib/impact.sh and pass after it. They are
# the reason the size of a fixture is now part of what it asserts.
# ---------------------------------------------------------------------------

# Build a file whose ONLY destructive line is line 2, then pad it past the pipe
# buffer. The padding is what makes the race deterministic rather than a flake:
# grep -q matches immediately and leaves while ~200 KB is still queued.
_big_destructive_probe() {   # $1 = target path
    { printf '#!/bin/bash\n'
      printf 'rm -rf "$doomed"\n'
      awk 'BEGIN { for (i = 0; i < 6000; i++) print "echo padding line " i " ................................" }'
    } > "$1"
}

@test "ops#351: a destructive file PAST the pipe buffer is still detected as destructive" {
    local f="${BATS_TEST_TMPDIR}/big-destructive.sh"
    _big_destructive_probe "$f"
    [ "$(wc -c < "$f")" -gt 65536 ]

    # Under pipefail, exactly as every caller runs. 20 repeats: the pre-fix
    # implementation was wrong on all 20, so one call would have been enough —
    # but a race deserves repeats or the proof is itself a coin flip.
    local wrong=0 i
    for i in $(seq 1 20); do
        ( set -o pipefail; impact_is_destructive "$f" ) || wrong=$((wrong + 1))
    done
    [ "$wrong" -eq 0 ]
}

@test "ops#351: a large file is still correctly reported as NOT destructive" {
    # The fix must not achieve its result by answering yes to everything.
    local f="${BATS_TEST_TMPDIR}/big-clean.sh"
    { printf '#!/bin/bash\n'
      awk 'BEGIN { for (i = 0; i < 6000; i++) print "echo padding line " i " ................................" }'
    } > "$f"
    [ "$(wc -c < "$f")" -gt 65536 ]
    ( set -o pipefail; ! impact_is_destructive "$f" )
}

@test "ops#351: impact_contract_adopted is correct on a file past the pipe buffer" {
    local f="${BATS_TEST_TMPDIR}/big-adopted.sh"
    { printf '#!/bin/bash\n'
      printf 'source "$DIR/lib/impact.sh"\n'
      printf 'impact_render\n'
      printf 'impact_confirm\n'
      awk 'BEGIN { for (i = 0; i < 6000; i++) print "echo padding line " i " ................................" }'
    } > "$f"
    [ "$(wc -c < "$f")" -gt 65536 ]
    local wrong=0 i
    for i in $(seq 1 20); do
        ( set -o pipefail; impact_contract_adopted "$f" ) || wrong=$((wrong + 1))
    done
    [ "$wrong" -eq 0 ]
}

@test "ops#351: the REAL destructive command scripts are seen as destructive, every time" {
    # The shipped files that were being skipped. This is the case that would
    # have gone red on main, and it names them so a future regression is
    # legible rather than statistical.
    local f wrong=0 i
    for f in scripts/commands/demo.sh scripts/commands/stg2live.sh scripts/commands/verify.sh; do
        [ -f "${PROJECT_ROOT}/$f" ] || continue
        for i in $(seq 1 10); do
            ( set -o pipefail; impact_is_destructive "${PROJECT_ROOT}/$f" ) || wrong=$((wrong + 1))
        done
    done
    [ "$wrong" -eq 0 ]
}
