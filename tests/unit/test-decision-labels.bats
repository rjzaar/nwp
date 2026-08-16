#!/usr/bin/env bats
#
# The decision vocabulary — one declared set, and a gate that reddens on a
# seventh spelling.
#
# THE MEASUREMENT THIS EXISTS FOR (2026-08-16). Six spellings of "this needs a
# decision" were live on nwp/ops at once:
#
#     decision::wanted 52 · decision-recorded 12 · needs-decision 11 ·
#     decision 11 · decision::made 6 · decision-needed 4
#
# `decision-needed` had ZERO readers in scripts/ or lib/. Four open "DECISION: …"
# issues wore it — ops#338, #339, #340, #348. Three also wore `decision::wanted`
# and surfaced anyway; **ops#340 wore neither tier label and appeared in NO tier
# of `pl decisions` at all**.
#
# Nothing in the tree could have caught that, because a label no code mentions is
# a label no code can miss. Hence a gate that matches on SHAPE (contains
# "decision") rather than on membership: an unknown spelling is caught precisely
# because it is unknown.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    LINT="$REPO_ROOT/scripts/ci/lint-decision-labels.sh"
    TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/declab.XXXXXX")"
}
teardown() { rm -rf "$TMP"; }

_issues() { # $1 = out file; rest = "iid|label,label"
    local out="$1"; shift
    python3 - "$out" "$@" <<'PY'
import json, sys
out = sys.argv[1]
rows = []
for spec in sys.argv[2:]:
    iid, labels = spec.split("|", 1)
    rows.append({"iid": int(iid), "labels": [l for l in labels.split(",") if l]})
json.dump(rows, open(out, "w"))
PY
}

# ── the vocabulary is declared in exactly one place ──────────────────────────

@test "the vocabulary declares both tiers, and lib/decision-labels.sh is its home" {
    [ -f "$REPO_ROOT/lib/decision-labels.sh" ]
    source "$REPO_ROOT/lib/decision-labels.sh"
    [ "$DECISION_LABEL_RED" = "needs-decision" ]
    [ "$DECISION_LABEL_AMBER" = "decision::wanted" ]
}

@test "decisions.sh takes its tier labels FROM the declared vocabulary, not literals" {
    # If a second home for the fact appears, this is the test that notices.
    grep -q 'source "\$PROJECT_ROOT/lib/decision-labels.sh"' "$REPO_ROOT/scripts/commands/decisions.sh"
    grep -q 'DECISIONS_LABEL="\${NWP_DECISIONS_LABEL:-\$DECISION_LABEL_RED}"' \
        "$REPO_ROOT/scripts/commands/decisions.sh"
}

@test "decision_label_is_declared accepts the declared set and rejects the dead one" {
    source "$REPO_ROOT/lib/decision-labels.sh"
    decision_label_is_declared "needs-decision"
    decision_label_is_declared "decision::wanted"
    decision_label_is_declared "decision::made"
    decision_label_is_declared "decision-recorded"
    decision_label_is_declared "decision"
    ! decision_label_is_declared "decision-needed"
    ! decision_label_is_declared "decision_wanted"
}

# ── THE RED PROOF: the gate fails on the state actually measured ─────────────

@test "lint:decision-labels is RED on the real 2026-08-16 state (ops#338/339/340/348)" {
    _issues "$TMP/real.json" \
        "338|decision-needed,decision::wanted,site::nwc" \
        "339|decision-needed,decision::wanted,site::sample1" \
        "340|ci,decision-needed,site::nwc,test-honesty" \
        "348|decision-needed,decision::wanted,site::nwc" \
        "345|decision::wanted,needs-human"
    run "$LINT" --from="$TMP/real.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"nwp/ops#340"* ]]
    [[ "$output" == *"decision-needed"* ]]
    [[ "$output" == *"no code reads this label"* ]]
}

# The actual requirement: a SEVENTH spelling cannot be introduced silently.
@test "lint:decision-labels is RED on a seventh spelling nobody has declared" {
    _issues "$TMP/seventh.json" "999|decision_wanted"
    run "$LINT" --from="$TMP/seventh.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"decision_wanted"* ]]
}

@test "lint:decision-labels is GREEN once the issues use the canonical vocabulary" {
    _issues "$TMP/clean.json" \
        "338|decision::wanted,site::nwc" \
        "340|ci,decision::wanted,site::nwc,test-honesty" \
        "77|decision-recorded" \
        "78|decision"
    run "$LINT" --from="$TMP/clean.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"every decision-shaped label in use is declared"* ]]
}

# ── fail-closed ─────────────────────────────────────────────────────────────

@test "lint:decision-labels CANNOT VERIFY on an unreadable source (exit 2, never 0)" {
    run "$LINT" --from="$TMP/does-not-exist.json"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "lint:decision-labels CANNOT VERIFY on an unparseable payload (exit 2, never 0)" {
    printf 'not json at all' > "$TMP/junk.json"
    run "$LINT" --from="$TMP/junk.json"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
}

# An empty tracker answer must not read as "no bad labels".
@test "lint:decision-labels CANNOT VERIFY on an empty response (exit 2, never 0)" {
    : > "$TMP/empty.json"
    run "$LINT" --from="$TMP/empty.json"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
}
