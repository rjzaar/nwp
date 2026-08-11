#!/usr/bin/env bats
#
# pl clips — clip-catalogue referential integrity (nwp/ops#352, follows ops#349)
#
# WHAT THIS FILE HAS TO PROVE
#
#   1. EVERY CHECK CAN GO RED.  There is one learning point per defect class in
#      `tests/fixtures/clip-catalogue/defective/`, and one assertion per class
#      asserting the CLASS NAME and the COUNT.  A blind `! pl clips verify` would
#      prove only "exited non-zero" — and this verb exits non-zero for eight
#      other reasons — so every assertion here reads the class out of the JSON.
#
#   2. EVERY CHECK CAN GO GREEN.  `clean/` is the same shapes with the defects
#      removed and must exit 0.  Without it, a check that fires on everything
#      would pass item 1 and be useless.
#
#   3. FAIL-CLOSED.  A catalogue whose episode has no transcript, and a video id
#      absent from the video index, must report CANNOT VERIFY and exit 2 — never
#      a silent pass, and never a substituted literal.  Exit 2 DOMINATES exit 1:
#      a run that could not evaluate every block must not read as a complete one.
#
#   4. REPAIR NEVER INVENTS.  Z1.07's summary is recoverable from its own
#      standard.text and is completed verbatim.  Z1.08's is NOT recoverable, and
#      the repairer must stamp it rather than write an ending.  That is the
#      assertion that stops a future "helpful" completion: a fabricated summary
#      would silently poison that learning point's retrieval query.
#
#   5. REPAIR IS DRY-RUN BY DEFAULT.  A repair verb that writes without being
#      asked is the shape of the incidents this estate keeps recording.
#
# The fixtures are SYNTHETIC — invented prose about lantern keepers and
# cartographers.  The real corpus is derivative-cleared-pending and local-only;
# none of it appears in this repository, which is publicly mirrored.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    FIX="${REPO_ROOT}/tests/fixtures/clip-catalogue"
    PL="${REPO_ROOT}/pl"
    WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "$WORK"
}

# Run `pl clips <sub>` against one fixture variant.
clips() {
    local variant="$1"; shift
    local catalog="${FIX}/${variant}/catalog"
    # `repair` mutates, so the mutating tests copy the catalogue first and pass
    # the copy in as $CATALOG_OVERRIDE.
    [ -n "${CATALOG_OVERRIDE:-}" ] && catalog="$CATALOG_OVERRIDE"
    NWP_CLIP_CATALOG="$catalog" \
    NWP_CLIP_TRANSCRIPTS="${FIX}/${variant}/transcripts" \
    NWP_CLIP_VIDEO_TRANSCRIPTS="${FIX}/${variant}/video-transcripts" \
    NWP_CLIP_VIDEO_INDEX="${FIX}/${variant}/videos.json" \
    "$PL" "$@"
}

# Count of findings of one class and severity, read out of --json.
count_of() {
    python3 -c '
import json, sys
report = json.loads(sys.stdin.read())
print(report["counts"].get(sys.argv[1], {}).get(sys.argv[2], 0))
' "$1" "$2"
}

# ── 1. every check can go RED, and names its own class ─────────────────────────

@test "defective fixture: D1 a window that ends beyond its own episode is REFUSED" {
    run clips defective clips verify --json
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | count_of window-beyond-media defect)" -eq 1 ]
    printf '%s' "$output" | grep -q 'there is no such moment in the recording'
}

@test "defective fixture: D2 a window that ends beyond the linked video is REFUSED" {
    run clips defective clips verify --json
    [ "$(printf '%s' "$output" | count_of window-beyond-video defect)" -eq 1 ]
    printf '%s' "$output" | grep -q 'the player stops mid-clip'
}

@test "defective fixture: D3a a linked video that is a DIFFERENT recording is REFUSED" {
    run clips defective clips verify --json
    [ "$(printf '%s' "$output" | count_of linkage-refuted defect)" -eq 1 ]
    printf '%s' "$output" | grep -q 'It is a DIFFERENT recording'
}

@test "defective fixture: D3b an inconclusive linkage is CANNOT VERIFY, not a pass" {
    run clips defective clips verify --json
    [ "$(printf '%s' "$output" | count_of linkage-unproven cannot-verify)" -eq 1 ]
    [ "$(printf '%s' "$output" | count_of linkage-unproven defect)" -eq 0 ]
    printf '%s' "$output" | grep -q 'Neither proven nor disproven'
}

@test "defective fixture: D3c a same-recording video with a SHIFTED timeline is REFUSED" {
    run clips defective clips verify --json
    [ "$(printf '%s' "$output" | count_of linkage-offset defect)" -eq 1 ]
    printf '%s' "$output" | grep -q 'timeline is offset by +100s'
}

@test "defective fixture: D4 an unmarked placeholder is REFUSED" {
    run clips defective clips verify --json
    [ "$(printf '%s' "$output" | count_of placeholder-unmarked defect)" -eq 1 ]
    printf '%s' "$output" | grep -q 'indistinguishable from a recommendation'
}

@test "defective fixture: D5 a truncated summary is REFUSED" {
    run clips defective clips verify --json
    [ "$(printf '%s' "$output" | count_of summary-truncated defect)" -eq 1 ]
    printf '%s' "$output" | grep -q 'degrades this learning point'
}

@test "defective fixture: D5 an UNRECOVERABLE truncated summary is CANNOT VERIFY" {
    run clips defective clips verify --json
    [ "$(printf '%s' "$output" | count_of summary-truncated cannot-verify)" -eq 1 ]
    printf '%s' "$output" | grep -q 'It must not be invented'
}

@test "defective fixture: D6 an empty video block is REFUSED" {
    run clips defective clips verify --json
    [ "$(printf '%s' "$output" | count_of video-block-empty defect)" -eq 1 ]
}

@test "defective fixture: D7 duration_min disagreeing with its own window is REFUSED" {
    run clips defective clips verify --json
    [ "$(printf '%s' "$output" | count_of duration-mismatch defect)" -eq 1 ]
}

# ── 2. every check can go GREEN ────────────────────────────────────────────────

@test "clean fixture: exits 0 and says so — the checks are not simply always red" {
    run clips clean clips verify
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAN"* ]]
}

@test "clean fixture: a placeholder STAMPED unset is accepted, an unstamped one is not" {
    # Z1.02 in the clean fixture is the same 0:00-8:00 window as the defective
    # fixture's Z1.06 — the only difference is the honest stamp.
    run clips clean clips verify --json
    [ "$(printf '%s' "$output" | count_of placeholder-unmarked defect)" -eq 0 ]
}

# ── 3. fail-closed ─────────────────────────────────────────────────────────────

@test "fail-closed: an episode with no transcript is CANNOT VERIFY, never a pass" {
    cp -r "${FIX}/clean/catalog" "${WORK}/blind"
    sed -i 's/episode: 1$/episode: 999/' "${WORK}/blind/Z1.yaml"
    CATALOG_OVERRIDE="${WORK}/blind" run clips clean clips verify --json
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | count_of window-beyond-media cannot-verify)" -ge 1 ]
    printf '%s' "$output" | grep -q 'duration unmeasurable'
}

@test "fail-closed: a youtube_id absent from the video index is CANNOT VERIFY" {
    cp -r "${FIX}/clean/catalog" "${WORK}/catalog"
    sed -i 's/vidSAME00001/vidNOTINDEX1/' "${WORK}/catalog/Z1.yaml"
    CATALOG_OVERRIDE="${WORK}/catalog" run clips clean clips verify --json
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | count_of window-beyond-video cannot-verify)" -ge 1 ]
    printf '%s' "$output" | grep -q 'length cannot be read'
}

@test "fail-closed: a missing catalogue directory is CANNOT VERIFY, not an empty pass" {
    CATALOG_OVERRIDE="${WORK}/does-not-exist" run clips clean clips verify
    [ "$status" -eq 2 ]
    printf '%s' "$output" | grep -q 'CANNOT VERIFY'
}

@test "fail-closed: exit 2 DOMINATES exit 1 — a partial verdict is not a complete one" {
    # The defective fixture has BOTH real defects (8) and unmeasurable blocks (2).
    # Reporting 1 there would let a blind run be graded as a finished one.
    run clips defective clips verify --json
    [ "$status" -eq 2 ]
    python3 -c '
import json, sys
r = json.loads(sys.stdin.read())
assert r["defects"] > 0, r["defects"]
assert r["cannot_verify"] > 0, r["cannot_verify"]
' <<< "$output"
}

# ── 4. repair never invents ────────────────────────────────────────────────────

@test "repair: a recoverable truncated summary is completed VERBATIM from standard.text" {
    cp -r "${FIX}/defective/catalog" "${WORK}/r1"
    CATALOG_OVERRIDE="${WORK}/r1" run clips defective clips repair --apply --no-linkage
    [ "$status" -eq 0 ] || [ "$status" -eq 2 ]   # 2 = some class was unrepairable
    run grep -c 'quiet harbour wall\.' "${WORK}/r1/Z1.yaml"
    # once in standard.text, once now in the completed summary
    [ "$output" -eq 2 ]
    ! grep -q 'beside the\.\.\.' "${WORK}/r1/Z1.yaml"
}

@test "repair: an UNRECOVERABLE truncated summary is stamped, NEVER completed" {
    cp -r "${FIX}/defective/catalog" "${WORK}/r2"
    CATALOG_OVERRIDE="${WORK}/r2" run clips defective clips repair --apply --no-linkage
    # Z1.08's ellipsis survives — nothing was invented for it …
    grep -q 'nowhere in this file at\.\.\.' "${WORK}/r2/Z1.yaml"
    # … and it is now flagged rather than silently left looking complete.
    grep -q 'truncated: true' "${WORK}/r2/Z1.yaml"
}

@test "repair: an unfilled slot is stamped unset, and its numbers are NOT changed" {
    cp -r "${FIX}/defective/catalog" "${WORK}/r3"
    CATALOG_OVERRIDE="${WORK}/r3" run clips defective clips repair --apply --no-linkage
    grep -q 'unset: true' "${WORK}/r3/Z1.yaml"
    # the stamp is a statement about what the numbers ARE, not a new choice
    grep -q "start: '0:00'" "${WORK}/r3/Z1.yaml"
    grep -q "end: '8:00'" "${WORK}/r3/Z1.yaml"
}

@test "repair: a REFUTED linkage is never silently replaced with a different video" {
    cp -r "${FIX}/defective/catalog" "${WORK}/r4"
    CATALOG_OVERRIDE="${WORK}/r4" run clips defective clips repair --apply
    # the wrong id is still there — choosing a replacement is a judgement …
    grep -q 'youtube_id: vidOTHER0001' "${WORK}/r4/Z1.yaml"
    # … but it no longer stands unqualified.
    grep -q 'linkage: refuted' "${WORK}/r4/Z1.yaml"
    grep -q 'linkage_evidence:' "${WORK}/r4/Z1.yaml"
}

@test "repair: after repair, the repaired classes stop being reported" {
    cp -r "${FIX}/defective/catalog" "${WORK}/r5"
    CATALOG_OVERRIDE="${WORK}/r5" run clips defective clips repair --apply --no-linkage
    CATALOG_OVERRIDE="${WORK}/r5" run clips defective clips verify --json
    [ "$(printf '%s' "$output" | count_of placeholder-unmarked defect)" -eq 0 ]
    [ "$(printf '%s' "$output" | count_of summary-truncated defect)" -eq 0 ]
}

# ── 5. repair is dry-run by default ────────────────────────────────────────────

@test "repair: DRY RUN by default — the catalogue is byte-identical afterwards" {
    cp -r "${FIX}/defective/catalog" "${WORK}/r6"
    before="$(md5sum "${WORK}/r6/Z1.yaml" | cut -d' ' -f1)"
    CATALOG_OVERRIDE="${WORK}/r6" run clips defective clips repair --no-linkage
    [[ "$output" == *"DRY RUN"* ]]
    after="$(md5sum "${WORK}/r6/Z1.yaml" | cut -d' ' -f1)"
    [ "$before" = "$after" ]
}

# ── the verb is discoverable ───────────────────────────────────────────────────

@test "pl lists clips in its generated command inventory" {
    run "$PL" commands
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qE '^[[:space:]]*clips[[:space:]]'
}

# ── 6. the one repair that CHANGES a value is opt-in ───────────────────────────

@test "repair: duration_min is NOT touched without --fix-derived" {
    cp -r "${FIX}/defective/catalog" "${WORK}/r7"
    CATALOG_OVERRIDE="${WORK}/r7" run clips defective clips repair --apply --no-linkage
    grep -q 'duration_min: 9.0' "${WORK}/r7/Z1.yaml"
}

@test "repair: --fix-derived recomputes duration_min from the window itself" {
    cp -r "${FIX}/defective/catalog" "${WORK}/r8"
    CATALOG_OVERRIDE="${WORK}/r8" run clips defective clips repair --apply --fix-derived --no-linkage
    ! grep -q 'duration_min: 9.0' "${WORK}/r8/Z1.yaml"
    grep -q 'duration_min: 0.5' "${WORK}/r8/Z1.yaml"
    # and the window it was derived FROM is untouched
    grep -q "start: '0:10'" "${WORK}/r8/Z1.yaml"
    grep -q "end: '0:40'" "${WORK}/r8/Z1.yaml"
    CATALOG_OVERRIDE="${WORK}/r8" run clips defective clips verify --json
    [ "$(printf '%s' "$output" | count_of duration-mismatch defect)" -eq 0 ]
}

# ── 6. the repair path runs on a host that has only PyYAML ────────────────────
#
# THE INCIDENT THIS PINS. `run_repair` used to import `ruamel.yaml` for one
# attribute — `.lc`, the per-key line numbers. ruamel is installed on the
# operator workstation and is NOT installed on the met CI runner (Ubuntu 24.04,
# no pip), so all seven `repair:` cases above were green here and red there:
#
#     not ok 386 repair: a recoverable truncated summary is completed VERBATIM …
#     testcases: 4331   failures: 7   skipped: 2   (pipeline 2250, job 19383)
#
# Green-on-my-machine is not a verdict. This case reproduces the runner's
# environment ANYWHERE by shadowing `ruamel` with a module that refuses to
# import, so the host-dependent half of the suite becomes host-independent.
@test "repair runs on a host with no ruamel.yaml (the CI runner's environment)" {
    local shim="${WORK}/no-ruamel"
    mkdir -p "$shim"
    printf 'raise ImportError("shim: ruamel.yaml is not installed on this host")\n' \
        > "${shim}/ruamel.py"
    # The shim really does break the old import — if it did not, this test
    # would pass for the wrong reason.
    run env PYTHONPATH="$shim" python3 -c 'from ruamel.yaml import YAML'
    [ "$status" -ne 0 ]

    cp -r "${FIX}/defective/catalog" "${WORK}/nr"
    CATALOG_OVERRIDE="${WORK}/nr" PYTHONPATH="$shim" \
        run clips defective clips repair --apply --no-linkage
    [[ "$output" != *"ruamel"* ]]
    grep -q 'unset: true' "${WORK}/nr/Z1.yaml"
    grep -q 'truncated: true' "${WORK}/nr/Z1.yaml"
}
