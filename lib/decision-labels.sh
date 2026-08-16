#!/bin/bash
################################################################################
# lib/decision-labels.sh — the decision vocabulary, DECLARED ONCE.
#
# WHY THIS FILE EXISTS
#   Measured 2026-08-16. SIX spellings of "this needs a decision" were in use on
#   nwp/ops at once:
#
#       decision::wanted    52   read by `pl decisions` (AMBER tier)
#       decision-recorded   12   not read
#       needs-decision      11   read by `pl decisions` (RED tier)
#       decision            11   not read
#       decision::made       6   not read
#       decision-needed      4   NOT READ BY ANYTHING
#
#   `decision-needed` had ZERO readers in scripts/ and lib/, and four open
#   issues titled "DECISION: …" wore it — ops#338, #339, #340 and #348. Three of
#   them also wore `decision::wanted`, so they surfaced anyway and the drift was
#   invisible. **ops#340 did not, and appeared in no tier at all**: an operator
#   decision the operator's own decision queue could not see.
#
#   That is the estate's recurring failure shape, applied to a label — the queue
#   rendered a confident list while silently omitting a row, and nothing could
#   fail, because no code knew the label existed.
#
# WHAT IS CANONICAL
#   RED   `needs-decision`   answer NOW; this blocks the current phase.
#   AMBER `decision::wanted` a real question, but nothing is standing still.
#
#   Everything else is either TERMINAL (the decision has been taken and the
#   issue is no longer a question) or is not a decision label at all.
#
# HOW A SEVENTH SPELLING IS PREVENTED
#   scripts/ci/lint-decision-labels.sh fails when any OPEN issue wears a
#   decision-shaped label that is not declared here. So a new spelling does not
#   quietly join the set: it reddens CI the first time it is applied, and the
#   fix is to either use the canonical label or declare it here on purpose.
#
#   Declaring one is a recorded decision, exactly like growing a baseline: add
#   the row AND say why in the commit. Do not add a row to silence a lint.
################################################################################

# The one true RED label.
DECISION_LABEL_RED="needs-decision"

# The one true AMBER label.
DECISION_LABEL_AMBER="decision::wanted"

# TERMINAL labels: the question has been answered. Not a queue tier — declared
# so the lint can tell "answered" apart from "a spelling nobody reads".
DECISION_LABELS_TERMINAL=(
    "decision::made"
    "decision-recorded"
)

# Decision-shaped labels that are DELIBERATELY not a tier and not terminal.
# `decision` (bare) is used as a topic tag on 11 issues; it means "this issue is
# about a decision", not "a decision is pending". Declared so the lint does not
# redden on it, and so that meaning is written down somewhere rather than living
# in whoever last looked.
DECISION_LABELS_NEUTRAL=(
    "decision"
)

# Every label this vocabulary knows about.
decision_labels_all() {
    printf '%s\n' "$DECISION_LABEL_RED" "$DECISION_LABEL_AMBER" \
        "${DECISION_LABELS_TERMINAL[@]}" "${DECISION_LABELS_NEUTRAL[@]}"
}

# Is <label> declared? rc 0 yes, rc 1 no.
decision_label_is_declared() {
    local want="$1" have
    while IFS= read -r have; do
        [ "$have" = "$want" ] && return 0
    done < <(decision_labels_all)
    return 1
}

# Does <label> LOOK like a decision label? This is what makes the lint able to
# notice a spelling nobody has ever written down — it matches on shape, not on
# membership, so an unknown one is caught precisely because it is unknown.
decision_label_is_shaped() {
    case "$1" in
        *decision*|*Decision*|*DECISION*) return 0 ;;
        *) return 1 ;;
    esac
}
