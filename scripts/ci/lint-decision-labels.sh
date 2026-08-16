#!/usr/bin/env bash
#
# lint-decision-labels.sh — an issue may not wear a decision label nothing reads.
#
# WHY THIS FILE EXISTS
#   Measured 2026-08-16: `decision-needed` (hyphen) had ZERO readers anywhere in
#   scripts/ or lib/, and four open "DECISION: …" issues wore it — ops#338, #339,
#   #340, #348. Three also wore `decision::wanted` and so surfaced anyway. ops#340
#   did not, and appeared in NO tier of `pl decisions` at all.
#
#   Nothing could have caught that, because a label no code mentions is a label
#   no code can miss. The queue rendered a confident list with a row silently
#   absent — the estate's own "unreadable renders as clean" shape.
#
# WHAT THIS ASSERTS
#   For every OPEN issue on the decisions tracker: every label that LOOKS like a
#   decision label (contains "decision", any case) is one of the labels declared
#   in lib/decision-labels.sh. Shape-matching is the point — it is the only way
#   to notice a spelling that has never been written down.
#
#   A seventh spelling therefore cannot be introduced silently: the first issue
#   to wear it reddens this gate.
#
# FAIL CLOSED
#   Cannot reach the tracker, cannot parse it, no token: exit 2 CANNOT VERIFY.
#   Never exit 0. An unread tracker is not a clean tracker.
#
# TESTABLE
#   --from=FILE reads a GitLab-shaped issues JSON array instead of the network,
#   which is how tests/unit/test-decision-labels.bats proves this gate RED
#   against a fixture carrying the real ops#340 state.
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/decision-labels.sh"

FROM=""
for a in "$@"; do
    case "$a" in
        --from=*) FROM="${a#*=}" ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "lint:decision-labels: unknown flag: $a" >&2; exit 2 ;;
    esac
done

DECISIONS_PROJECT="${NWP_DECISIONS_PROJECT:-21}"

issues_json=""
if [ -n "$FROM" ]; then
    [ -r "$FROM" ] || { echo "lint:decision-labels: CANNOT VERIFY — cannot read $FROM"; exit 2; }
    issues_json="$(cat "$FROM")"
else
    command -v yq >/dev/null 2>&1 || {
        echo "lint:decision-labels: CANNOT VERIFY — no yq, cannot read the forge route"; exit 2; }
    tok="$(yq e '.gitlab.ops_note_token // .gitlab.api_token // ""' \
            "$PROJECT_ROOT/.secrets.yml" 2>/dev/null | grep -v '^null$')"
    host="$(yq e '.gitlab.server.domain // ""' \
            "$PROJECT_ROOT/.secrets.yml" 2>/dev/null | grep -v '^null$')"
    [ -n "$tok" ] && [ -n "$host" ] || {
        echo "lint:decision-labels: CANNOT VERIFY — no forge host/token readable on this machine"
        exit 2; }
    # ops#374: the credential goes to curl on STDIN and never becomes a file.
    issues_json="$(printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok" \
        | curl -sS -f -K - --get \
            --data-urlencode "state=opened" \
            --data-urlencode "per_page=100" \
            "https://${host}/api/v4/projects/${DECISIONS_PROJECT}/issues" 2>/dev/null)" || {
        echo "lint:decision-labels: CANNOT VERIFY — the tracker did not answer"; exit 2; }
fi

[ -n "$issues_json" ] || { echo "lint:decision-labels: CANNOT VERIFY — empty response"; exit 2; }

# Emit "iid<TAB>label" for every label that is decision-SHAPED. Pure text work
# from here, so the classifier is the shell and the fixture drives it.
shaped="$(printf '%s' "$issues_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(3)
if not isinstance(data, list):
    sys.exit(3)
for i in data:
    for l in (i.get("labels") or []):
        if "decision" in l.lower():
            print("%s\t%s" % (i.get("iid", "?"), l))
' 2>/dev/null)" || {
    echo "lint:decision-labels: CANNOT VERIFY — the issues payload did not parse"; exit 2; }

declared_list="$(decision_labels_all | tr '\n' '|' | sed 's/|$//; s/|/, /g')"

fail=0
undeclared_seen=""
while IFS=$'\t' read -r iid label; do
    [ -n "${label:-}" ] || continue
    if ! decision_label_is_declared "$label"; then
        echo "UNDECLARED  nwp/ops#${iid}  wears '${label}' — no code reads this label"
        undeclared_seen="${undeclared_seen}${label}"$'\n'
        fail=1
    fi
done <<< "$shaped"

n_shaped="$(printf '%s' "$shaped" | grep -c . || true)"
echo "lint:decision-labels: checked ${n_shaped} decision-shaped label use(s) against: ${declared_list}"


if [ "$fail" -ne 0 ]; then
    cat <<EOF

A decision label that no code reads is a decision the queue cannot show.

That is not hypothetical: on 2026-08-16 ops#340 wore only \`decision-needed\`,
which nothing read, and it appeared in NO tier of \`pl decisions\` — an operator
decision invisible to the operator's own decision queue.

Fix it one of two ways:
  * relabel the issue onto the canonical vocabulary
        RED   ${DECISION_LABEL_RED}      answer now, this blocks the phase
        AMBER ${DECISION_LABEL_AMBER}    a real question, nothing is blocked
    with:  pl issue label <iid> --add '${DECISION_LABEL_AMBER}' --remove '<the dead one>'
  * or DECLARE the label on purpose in lib/decision-labels.sh, and say why in
    the commit. Declaring one is a recorded decision, not a way to silence this.

Undeclared spellings seen:
$(printf '%s' "$undeclared_seen" | sort -u | sed 's/^/  /')
EOF
    exit 1
fi

echo "lint:decision-labels: OK — every decision-shaped label in use is declared"
exit 0
