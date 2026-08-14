#!/usr/bin/env bats
#
# pl clips calibrate — the multi-rater calibration instrument (nwp/ops#348, P79)
#
# WHAT THIS FILE HAS TO PROVE
#
#   P78 committed four gates against ONE assessor. P79 hands the same instrument
#   to a guild. The ways that goes wrong are not arithmetic mistakes; they are
#   an instrument that AGREES WITH ITSELF for the wrong reason:
#
#   1. THREE COPIES OF ONE OPINION MUST NOT READ AS THREE OPINIONS. A panel whose
#      members hand in the same answers has an alpha of 1.000 and has measured
#      nothing. This is the single most dangerous failure, because its symptom is
#      an excellent number.
#   2. A PANEL THAT DID NOT RESOLVE MAY NOT CONDEMN THE LABELS. Gates 1, 2 and 4
#      can all say DISCARD off a panel of random answers. The run must still
#      refuse to discard, because it has not measured the machine — it has
#      measured three people disagreeing. DISCARD deletes 3,309 labels in one
#      step (P78 4.5), so the permissive direction here is deletion.
#   3. ONE BAD RATER MUST NOT DELETE THE SET, AND MUST STILL BE NAMED. Gate 4's
#      kill switch is corroborated at N>1. The same answers that discard the set
#      alone must only produce an OUTLIER row on a panel.
#   4. A LOST JOIN MAP IS A REFUSAL, NOT A GUESS. Item labels are positional and
#      per-rater. Scoring them against the canonical order would compare a
#      grade about one passage with a grade about another and report the result
#      as disagreement.
#   5. THE RIGHTS BOUNDARY IS ENFORCED, NOT REQUESTED. `nwp/nwp` is publicly
#      mirrored (ADR-0039); the builder must refuse to write corpus excerpts
#      into it.
#   6. AT N=1 IT IS STILL P78'S INSTRUMENT. If the thresholds move when the
#      panel arrives, they were not committed in advance.
#
# RED PROOF — OBSERVED, not predicted. Four mutations were applied to
# `scripts/lib/clip-calibration-multi.py` and `clip-calibration-packet.py` ONLY
# (this file was untouched):
#
#   1. `COLLUSION_EXACT = 0.98` -> `1.01`            (detector can never fire)
#   2. the `g0_instrument_failure` branch moved BELOW the DISCARD branch in the
#      overall-verdict chain                          (panel failure stops dominating)
#   3. Gate 4's `need` forced to `1`                  (corroboration removed)
#   4. the packet builder's repo-containment refusal `if dest == repo or
#      dest.startswith(repo + os.sep):` changed to `if False:`
#
# and this file was run against the mutated code. Observed, verbatim:
#
#   1..13
#   not ok 2 three identical answer files are one opinion, not three
#   not ok 5 a panel that did not resolve may not DISCARD the labels
#   not ok 7 one rater who answered at random is NAMED, not obeyed
#   not ok 12 the builder REFUSES to write corpus excerpts into the mirrored repo
#
# FOUR failures of THIRTEEN tests, one per mutation. Tests 1, 3, 4, 6, 8, 9, 10,
# 11 and 13 stayed green because they exercise paths none of the four mutations
# touched — recorded rather than tidied away, because claiming thirteen failures
# when four were observed is the same species of error this file exists to catch.
#
# Mutation 4 was not merely detected, it left evidence: the mutated builder
# actually wrote `docs/reports/nope/calibration-packet-ann.md` — 600-character
# excerpts of a password-gated corpus — into the publicly mirrored repository.
# The file had to be deleted by hand before the suite would go green again. That
# is what this gate stops, and it has now been seen doing it.
#
# The fixture carries NO corpus. `tests/fixtures/clip-calibration/` is 30
# synthetic learning points with synthetic prose, so this suite runs anywhere,
# including on a CI runner that has never seen ~/dir.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCORE="$PROJECT_ROOT/scripts/lib/clip-calibration-multi.py"
    PACKET="$PROJECT_ROOT/scripts/lib/clip-calibration-packet.py"
    CAL="$PROJECT_ROOT/tests/fixtures/clip-calibration/calibration_set.json"
    W="$BATS_TEST_TMPDIR/w"
    mkdir -p "$W"

    # Answer sets are DERIVED from the fixture's own machine grades, so a change
    # to the fixture cannot silently decouple them.
    python3 - "$CAL" "$W" <<'PY'
import json, random, sys
cal = json.load(open(sys.argv[1])); W = sys.argv[2]
truth = {it["label"]: it["machine_grade"] for lp in cal for it in lp["items"]}
ctrl = {it["label"] for lp in cal if lp["stratum"].startswith("C-control")
        for it in lp["items"]}
def w(n, d): json.dump(d, open("%s/answers-%s.json" % (W, n), "w"), indent=1)

def noisy(seed, frac=0.35):
    r = random.Random(seed)
    return {k: (max(0, min(3, v + r.choice([-1, 1]))) if r.random() < frac else v)
            for k, v in truth.items()}

w("perfect", truth)
w("ann", noisy(1)); w("ben", noisy(2)); w("cal", noisy(3))
# a rater who answered at random
r = random.Random(9)
w("rand", {k: r.randint(0, 3) for k in truth})
# three raters who agree with each other and read the screening cut the other
# way from the machine -- the Gate 1b case
for n, s in (("d1", 11), ("d2", 12), ("d3", 13)):
    r = random.Random(s)
    w(n, {k: (max(0, min(3, (2 if v == 1 else 1 if v == 2 else v)
                         + (r.choice([-1, 1]) if r.random() < 0.06 else 0))))
          for k, v in truth.items()})
# opposed scale offsets: Gate 3 cancels to zero, Gate 3b must see it
w("gen", {k: min(3, v + 1) for k, v in truth.items()})
w("harsh", {k: max(0, v - 1) for k, v in truth.items()})
# an unanswered item
inc = dict(truth); inc[sorted(truth)[0]] = None
w("inc", inc)
# three copies of ONE opinion
o = noisy(77)
for n in ("x1", "x2", "x3"): w(n, o)
PY
}

score() { python3 "$SCORE" --cal="$CAL" --boot=300 "$@"; }
overall() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["OVERALL"])'; }
gate() { printf '%s' "$2" | python3 -c "import json,sys; print(json.load(sys.stdin)['$1']['verdict'])"; }

# ── 1. the instrument still works at N=1 ──────────────────────────────────────
@test "N=1: an assessor who agrees with the machine PASSES, and the panel gates report NOT ARMED" {
    run score "$W/answers-perfect.json"
    [ "$status" -eq 0 ]
    [[ "$(overall "$output")" == PASS* ]]
    [[ "$(gate gate0_panel_coherence "$output")" == "NOT ARMED (1 rater; arms at 2)" ]]
    [[ "$(gate gate1b_machine_not_an_outlier "$output")" == "NOT ARMED"* ]]
    [[ "$(gate gate3b_rater_scale_dispersion "$output")" == "NOT ARMED"* ]]
    # the P78 gates are evaluated, not skipped
    [[ "$(gate gate1_screening_kappa "$output")" == "PASS" ]]
    [[ "$(gate gate4_controls_corroborated "$output")" == "PASS"* ]]
}

# ── 2. THE MOST DANGEROUS FAILURE: a good number from one opinion ─────────────
@test "three identical answer files are one opinion, not three" {
    run score "$W/answers-x1.json" "$W/answers-x2.json" "$W/answers-x3.json"
    [ "$status" -eq 2 ]
    [[ "$output" == *"DUPLICATE-RATER"* ]]
    [[ "$output" == *"agree on 100.0% of shared items exactly"* ]]
    # it must name WHICH pair, not just complain
    [[ "$output" == *'"exact_agreement": 1.0'* ]]
    # and it must not have gone on to publish an alpha
    [[ "$output" != *"COHERENT — the panel is a usable reference standard"* ]]
}

# ── 3. a real panel is measured on both axes ──────────────────────────────────
@test "N=3: inter-human alpha is reported alongside the machine gates, with a CI" {
    run score "$W/answers-ann.json" "$W/answers-ben.json" "$W/answers-cal.json"
    [[ "$output" == *'"alpha_interval"'* ]]
    [[ "$output" == *'"alpha_interval_ci95"'* ]]
    [[ "$output" == *'"alpha_ordinal"'* ]]
    [[ "$output" == *'"comparator_machine_panel_alpha_interval": 0.921'* ]]
    [[ "$output" == *'"disagreement_composition"'* ]]
    # per-rater kappas are reported individually, never only pooled
    [[ "$output" == *'"per_rater"'* ]]
    printf '%s' "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert set(d["gate1_screening_kappa"]["per_rater"]) == {"ann","ben","cal"}, d["gate1_screening_kappa"]["per_rater"]
assert d["n_raters_scored"] == 3'
}

# ── 4. the new gate the panel makes possible ─────────────────────────────────
@test "Gate 1b DISCARDS a machine that is an outlier on a panel that DID resolve" {
    run score "$W/answers-d1.json" "$W/answers-d2.json" "$W/answers-d3.json"
    [ "$status" -eq 1 ]
    [[ "$(gate gate0_panel_coherence "$output")" == COHERENT* ]]
    [[ "$(gate gate1b_machine_not_an_outlier "$output")" == DISCARD* ]]
    [[ "$output" == *"below its least-agreeing human"* ]]
    [[ "$(overall "$output")" == DISCARD* ]]
}

# ── 5. THE FAIL-CLOSED DIRECTION: deletion is the permissive answer ──────────
@test "a panel that did not resolve may not DISCARD the labels" {
    # three raters answering at random: the humans-vs-machine gates all fail
    python3 - "$W" <<'PY'
import json, random, sys
W = sys.argv[1]
truth = json.load(open(W + "/answers-perfect.json"))
for n, s in (("r1", 91), ("r2", 92), ("r3", 93)):
    r = random.Random(s)
    json.dump({k: r.randint(0, 3) for k in truth},
              open("%s/answers-%s.json" % (W, n), "w"), indent=1)
PY
    run score "$W/answers-r1.json" "$W/answers-r2.json" "$W/answers-r3.json"
    [ "$status" -eq 2 ]
    [[ "$(gate gate0_panel_coherence "$output")" == "INSTRUMENT FAILURE"* ]]
    # at least one machine gate DID say DISCARD ...
    [[ "$output" == *DISCARD* ]]
    # ... and the run refused to act on it
    [[ "$(overall "$output")" == "CANNOT VERIFY — INSTRUMENT FAILURE at Gate 0."* ]]
    [[ "$output" == *"labels are NOT discarded and P78 4.5 is NOT triggered"* ]]
}

# ── 6. Gate 3 can pass vacuously; 3b is why that is caught ───────────────────
@test "opposed rater offsets cancel in Gate 3 and are caught by Gate 3b" {
    run score "$W/answers-gen.json" "$W/answers-harsh.json"
    [[ "$(gate gate3_directional_bias "$output")" == "PASS" ]]
    [[ "$(gate gate3b_rater_scale_dispersion "$output")" == FAIL* ]]
    [[ "$output" == *"They are not using one scale"* ]]
    [[ "$output" == *"Remedy is rater training, NOT a change to the labels"* ]]
}

# ── 7. corroboration: one rater's error is a finding about the rater ─────────
@test "one rater who answered at random is NAMED, not obeyed" {
    run score "$W/answers-rand.json"
    alone="$(gate gate4_controls_corroborated "$output")"
    [[ "$alone" == DISCARD* ]]          # alone, that rater deletes the label set

    run score "$W/answers-ann.json" "$W/answers-ben.json" "$W/answers-rand.json"
    [[ "$(gate gate4_controls_corroborated "$output")" == PASS* ]]
    [[ "$output" == *'"outlier_raters"'* ]]
    [[ "$output" == *"rand"* ]]
    [[ "$output" == *"reported, NOT dropped; investigate the rater, not the labels"* ]]
}

# ── 8. fail-closed on partial input ──────────────────────────────────────────
@test "an unanswered item is CANNOT VERIFY, never a pass and never an imputed grade" {
    run score "$W/answers-inc.json"
    [ "$status" -eq 2 ]
    [[ "$(overall "$output")" == *"left items unanswered"* ]]
    [[ "$output" == *'"missing_by_rater"'* ]]
}

@test "an unreadable calibration set is exit 2, not an empty panel" {
    run python3 "$SCORE" --cal="$W/does-not-exist.json" "$W/answers-perfect.json"
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot read the calibration set"* ]]
}

# ── 9. the join, and the refusal when it is missing ──────────────────────────
@test "per-rater packets shuffle the order and the join recovers the same verdicts" {
    P="$BATS_TEST_TMPDIR/pk"
    run python3 "$PACKET" --cal="$CAL" --out="$P" --rater=ann --rater=ben
    [ "$status" -eq 0 ]
    [[ "$output" == *'"distinct_orderings": 2'* ]]
    # the member-facing document must not carry a catalogue address or a machine opinion
    run grep -cE 'Z[0-9]\.[0-9]{2}|machine_grade|machine_rationale' "$P/calibration-packet-ann.md"
    [ "$output" = "0" ]

    # translate the machine's own grades into ann's local labels
    python3 - "$CAL" "$P" <<'PY'
import json, sys
cal = json.load(open(sys.argv[1])); P = sys.argv[2]
by = {(lp["lp_id"], it["blind_key"]): it["machine_grade"]
      for lp in cal for it in lp["items"]}
pk = json.load(open(P + "/calibration-packet-ann.json"))
json.dump({l: by[(v["lp_id"], v["blind_key"])] for l, v in pk["items"].items()},
          open(P + "/answers-ann.json", "w"), indent=1)
PY
    run python3 "$SCORE" --cal="$CAL" --packet-dir="$P" --boot=300 "$P/answers-ann.json"
    [ "$status" -eq 0 ]
    [[ "$(overall "$output")" == PASS* ]]
}

@test "answers in a per-rater ordering with no join map are REFUSED, not guessed" {
    P="$BATS_TEST_TMPDIR/pk2"
    python3 "$PACKET" --cal="$CAL" --out="$P" --rater=ann >/dev/null
    python3 - "$CAL" "$P" <<'PY'
import json, sys
cal = json.load(open(sys.argv[1])); P = sys.argv[2]
by = {(lp["lp_id"], it["blind_key"]): it["machine_grade"]
      for lp in cal for it in lp["items"]}
pk = json.load(open(P + "/calibration-packet-ann.json"))
json.dump({l: by[(v["lp_id"], v["blind_key"])] for l, v in pk["items"].items()},
          open(P + "/answers-ann.json", "w"), indent=1)
PY
    rm "$P/calibration-packet-ann.json"
    run python3 "$SCORE" --cal="$CAL" --packet-dir="$P" "$P/answers-ann.json"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Refusing to guess which candidate was graded"* ]]
}

# ── 10. rights, and anti-self-review ────────────────────────────────────────
@test "the builder REFUSES to write corpus excerpts into the mirrored repo" {
    run python3 "$PACKET" --cal="$CAL" --out="$PROJECT_ROOT/docs/reports/nope" --rater=ann
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSED"* ]]
    [[ "$output" == *"publicly mirrored"* ]]
    [ ! -d "$PROJECT_ROOT/docs/reports/nope" ]
}

@test "anti-self-review exclusions that gut the control stratum REFUSE the packet" {
    python3 - "$CAL" > "$BATS_TEST_TMPDIR/exc.json" <<'PY'
import json, sys
cal = json.load(open(sys.argv[1]))
print(json.dumps({"ann": [lp["lp_id"] for lp in cal
                          if lp["stratum"].startswith("C-control")][:5]}))
PY
    run python3 "$PACKET" --cal="$CAL" --out="$BATS_TEST_TMPDIR/pk3" --rater=ann \
        --exclusions="$BATS_TEST_TMPDIR/exc.json"
    [ "$status" -eq 2 ]
    [[ "$output" == *"control items survive the exclusions"* ]]
    [[ "$output" == *"refused rather than built blind"* ]]
}
