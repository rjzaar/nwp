#!/usr/bin/env bats
#
# pl clips finish — the completion process (nwp/ops#348 / ops#352)
#
# WHAT THIS FILE HAS TO PROVE
#
#   The verb's whole claim is "it MEASURES; it does not assert". The way that
#   claim fails is not by printing a wrong number — it is by printing a
#   REASSURING one when it could not look. So every test here drives the verb
#   into a state where the honest answer is bad news, and asserts the bad news
#   BY ITS TEXT.
#
#   1. AN UNREACHABLE MEASUREMENT HOST IS NOT "NOTHING OUTSTANDING".  Point the
#      verb at a host that does not resolve and it must say CANNOT VERIFY and
#      exit 2. This is the single most important assertion in the file: the
#      failure mode being defended against is a cold operator reading silence
#      as completion.
#
#   2. A SHA MISMATCH IS REPORTED, NOT ROUNDED OFF.  The fixture's recorded
#      digest disagrees with its bytes; the verb must say MISMATCH and print
#      both prefixes.
#
#   3. ABSENT CALIBRATION ANSWERS ARE OWED WORK, AND ARE PRINTED FIRST.  With no
#      answers.json the verb must say "not started" and must print the
#      calibration section before the shortlist section — the ordering is the
#      product decision, so it is asserted, not assumed.
#
#   4. UNAPPLIED OVERLAYS ARE MEASURED IN THE BASE ARTEFACT.  The fixture base
#      still carries over-ceiling rows and no shortfall-audit blocks, so the
#      verb must report the overlays as NOT applied — from the artefact, never
#      from the presence of the overlay files.
#
#   5. EXIT 2 DOMINATES EXIT 1.  A run with both owed work and an unreadable
#      source reports 2.
#
#   6. NO SILENT CAPS.  Wherever it samples, it prints the sample size and the
#      remainder. Asserted by text.
#
# RED PROOF — OBSERVED, not predicted. Two mutations were applied to
# `scripts/commands/clips.sh` ONLY (the tests were untouched; `git status
# tests/` showed nothing but this new file):
#
#   1. `_f_shortlist`'s host-failure branch changed to `return 0`
#   2. the sha comparison `[ "$SHA_MATCH" = "True" ]` changed to `true`
#
# and this file was run against the mutated verb. Observed, verbatim:
#
#   1..7
#   not ok 1 finish: an unreachable measurement host is CANNOT VERIFY, never silence
#   #   `[[ "$output" == *"could not reach the measurement host"* ]]' failed
#   not ok 2 finish: a sha256 mismatch is reported with both prefixes
#   #   `[[ "$output" == *"sha256 MISMATCH"* ]]' failed
#   ok 3..7
#
# TWO failures of SEVEN tests. Test 7 (exit-2 dominance) stayed green under
# those two mutations because it is driven by a THIRD path — the helper's own
# cannot_verify list — which neither mutation touched. That is recorded rather
# than tidied away: claiming three failures when two were observed would be the
# same species of error this file exists to catch.
#
# Quoting the test COUNT matters. A prior session in this estate stashed the
# tests together with the fix and got a vacuous "0 failures" because 0 tests
# ran.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    FIX="$BATS_TEST_TMPDIR/fix"
    mkdir -p "$FIX/shortlist" "$FIX/work" "$FIX/cal" "$FIX/scorer"

    # ── a two-learning-point shortlist, deliberately in the UNREMEDIATED state:
    #    a row over the 420 s ceiling, no shortfall_reason_audit block, a deep
    #    row, and a row whose quoted fragment could not be located.
    cat > "$FIX/shortlist/SHORTLIST-16.jsonl" <<'JSON'
{"lp":"Z1.01","target":16,"shortfall_reason":null,"source_slice":"slice-01","method":"fixture","selected":[{"moment_id":"Z1.01-m01","moment_rank":3,"duration_s":180,"n_sources_agreeing":2,"rationale_quote_audit":{"fragments_checked":1,"corroborated_in_emitted_clip":1,"NOT_LOCATED_paraphrase_in_quote_marks":0}},{"moment_id":"Z1.01-m02","moment_rank":41,"duration_s":610,"n_sources_agreeing":0,"caveat":"MACHINE-RANKED","rationale_quote_audit":{"fragments_checked":1,"corroborated_in_emitted_clip":0,"NOT_LOCATED_paraphrase_in_quote_marks":1}}]}
{"lp":"Z1.02","target":16,"shortfall_reason":"fixture reason","source_slice":"slice-01","method":"fixture","selected":[{"moment_id":"Z1.02-m01","moment_rank":22,"duration_s":200,"n_sources_agreeing":1,"rationale_quote_audit":{"fragments_checked":0,"corroborated_in_emitted_clip":0,"NOT_LOCATED_paraphrase_in_quote_marks":0}}]}
JSON
    # a digest that DISAGREES with the bytes above — the red state for check 2
    printf '%s  SHORTLIST-16.jsonl\n' \
        "0000000000000000000000000000000000000000000000000000000000000000" \
        > "$FIX/shortlist/SHORTLIST-16.jsonl.sha256"

    # ── overlays present on disk but NOT applied to the base above
    cat > "$FIX/work/d2_overlay.json" <<'JSON'
{"Z1.01":{"shortfall_reason_audit":{"verdict":"FALSE_REPLACED","n_unexplained":2}},
 "Z1.02":{"shortfall_reason_audit":{"verdict":"CORRECTED","n_unexplained":0}}}
JSON
    cat > "$FIX/work/d3_overlay.json" <<'JSON'
{"Z1.01":{"ceiling_policy":{"rule":"UNIFORM 420 s CEILING","decisions":[
  {"moment_id":"Z1.01-m02","decision":"SWAPPED"},{"moment_id":"Z1.01-m03","decision":"DROPPED"}]}}}
JSON
    printf '#\n' > "$FIX/work/apply_overlay.py"
    printf '#\n' > "$FIX/work/d2fix.py"
    printf '#\n' > "$FIX/work/SHORTLIST-16.remediated.jsonl"
    cat > "$FIX/work/d4_verdicts.json" <<'JSON'
[{"verdict":"SURVIVES"},{"verdict":"SWAP"},{"verdict":"SWAP"},{"verdict":"SURVIVES_CEILING"}]
JSON
    cat > "$FIX/work/d4sample.txt" <<'TXT'
POPULATION
  deep rows (moment_rank > 16)                 : 100
  CONTESTED deep rows (something to displace)  : 60
  UNFORCED deep rows (nothing corroborated to  : 40
TXT
    # make the population NEWER than the artefact so staleness is not the thing
    # under test in the tests that are not about staleness
    touch "$FIX/work/d4sample.txt"

    # ── calibration: the set and the template exist, answers.json does NOT
    printf '# fixture calibration set\n' > "$FIX/cal/CALIBRATION-SET.md"
    printf '{"Z1.01-1": null, "Z1.01-2": null}\n' > "$FIX/cal/answers-template.json"
    printf '#\n' > "$FIX/scorer/score_calibration.py"

    export NWP_CLIPS_POOL_HOST=local
    export NWP_CLIPS_POOL_SHORTLIST="$FIX/shortlist"
    export NWP_CLIPS_POOL_WORK="$FIX/work"
    export NWP_CLIPS_CAL_DIR="$FIX/cal"
    export NWP_CLIPS_SCORER_DIR="$FIX/scorer"
    export NWP_CLIPS_ANSWERS="$FIX/cal/answers.json"
    export NWP_CLIPS_SSH_TIMEOUT=2
}

run_finish() { run bash "$PROJECT_ROOT/scripts/commands/clips.sh" finish; }

# ─────────────────────────────────────────────────────────────────────────────

@test "finish: an unreachable measurement host is CANNOT VERIFY, never silence" {
    export NWP_CLIPS_POOL_HOST="no-such-host.invalid"
    run_finish
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
    [[ "$output" == *"could not reach the measurement host"* ]]
    [[ "$output" == *"an unreachable host is NOT 'nothing outstanding'"* ]]
    # and it must NOT claim the programme is complete
    [[ "$output" != *"NOTHING OWED"* ]]
}

@test "finish: a sha256 mismatch is reported with both prefixes" {
    run_finish
    [[ "$output" == *"sha256 MISMATCH"* ]]
    [[ "$output" == *"recorded 000000000000"* ]]
    [[ "$output" != *"sha256 MATCHES"* ]]
}

@test "finish: absent calibration answers are OWED, and printed FIRST" {
    run_finish
    [[ "$output" == *"0 of 2 judgements graded — not started"* ]]
    [[ "$output" == *"Only your own judgements speak to VALIDITY"* ]]
    # ordering is the product decision, so assert it rather than assume it
    local cal short
    cal=$(printf '%s\n' "$output" | grep -n "CALIBRATION SET" | head -1 | cut -d: -f1)
    short=$(printf '%s\n' "$output" | grep -n "SHORTLIST —" | head -1 | cut -d: -f1)
    [ -n "$cal" ] && [ -n "$short" ] && [ "$cal" -lt "$short" ]
}

@test "finish: unapplied overlays are measured in the BASE artefact" {
    run_finish
    [[ "$output" == *"THE REMEDIATION OVERLAYS ARE NOT APPLIED"* ]]
    # 1 row over the ceiling and 0 NEEDS-QUOTE-PASS markers, read off the base
    [[ "$output" == *"over-ceiling rows 1,"* ]]
    [[ "$output" == *"NEEDS-QUOTE-PASS markers 0"* ]]
    # the overlay files ARE all present, so a presence check would have said
    # "applied" — this asserts the verb did not take that shortcut
    [[ "$output" != *"applied: ceiling ✓"* ]]
}

@test "finish: the contested deep third is named, never silently capped" {
    run_finish
    [[ "$output" == *"CONTESTED DEEP ROWS REMAIN UNJUDGED"* ]]
    [[ "$output" == *"60 of 100 deep rows are CONTESTED"* ]]
    [[ "$output" == *"56 CONTESTED DEEP ROWS REMAIN UNJUDGED"* ]]   # 60 - 4 judged
    [[ "$output" == *"SAMPLE, not a census"* ]]
    [[ "$output" == *"SAMPLED, NOT CENSUSED"* ]]
}

@test "finish: the ceiling overlay's swap/drop split is read from the overlay" {
    run_finish
    [[ "$output" == *"1 swapped, 1 dropped, never padded"* ]]
    [[ "$output" == *"have NOT been through the quote"* ]]
}

@test "finish: exit 2 dominates exit 1" {
    # owed work exists (calibration not started) AND a source is unreadable
    rm -f "$NWP_CLIPS_POOL_WORK/d4_verdicts.json"
    run_finish
    [ "$status" -eq 2 ]
    [[ "$output" == *"Grade this AMBER"* ]]
}
