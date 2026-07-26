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
    [[ "$output" == *"servers/nwpcode/demo/nwd-demo-reset-restricted"* ]]
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
# Converted verbs stay converted
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# ops#143 — the box-resident demo reset renders a REAL manifest, not a comment
# ---------------------------------------------------------------------------

# The forced command lives on the git box with no repo checkout, so it cannot
# source lib/impact.sh and its manifest is inline. That makes "does the manifest
# actually render?" a question only execution can answer — reading the file
# proves nothing. Extract the render function, stub every external it touches,
# run it, and assert the text.
_render_demo_manifest() {
    local f="${PROJECT_ROOT}/servers/nwpcode/demo/nwd-demo-reset-restricted"
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
    impact_contract_adopted "${PROJECT_ROOT}/servers/nwpcode/demo/nwd-demo-reset-restricted"
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
