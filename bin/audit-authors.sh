#!/usr/bin/env bash
# P61 §4.5 — enumerate non-operator authors in git log and emit a
# classification template.
#
# Output is reviewable for the per-author audit recommended in the
# operator's separate copyright work (see
# ~/central/copyright/12-LEGAL-SOLUTION-MASTER.md §5.2.10):
#   (a) explicit CC0 acceptance
#   (b) de minimis / machine-generated
#   (c) material contribution without explicit dedication
#
# Run from the repo root:
#   ./bin/audit-authors.sh > /tmp/audit-$(date -I).md

set -euo pipefail

OPERATOR_NAMES_REGEX='Robert Karsten Zaar|Rob Zaar|Robert Zaar|Robert K Zaar|rjzaar'

cat <<EOF
# Per-author audit — $(basename "$(pwd)")

**Date:** $(date -I)
**Repo:** $(pwd)
**Operator regex:** \`${OPERATOR_NAMES_REGEX}\`

| Author | Commits | Sample | Classification |
|---|---|---|---|
EOF

git log --all --format='%aN <%aE>' \
  | sort -u \
  | grep -vE "${OPERATOR_NAMES_REGEX}" \
  | while IFS= read -r author; do
      count=$(git log --all --author="${author%% <*}" --oneline | wc -l)
      sample=$(git log --all --author="${author%% <*}" --oneline | head -1 | tr '|' '/')
      echo "| ${author} | ${count} | ${sample} | [ ] (a) acceptance  [ ] (b) de minimis  [ ] (c) gap |"
    done

echo ""
echo "## Notes"
echo ""
echo "For each (c) classification, send the outreach template at"
echo "the operator's drafting pack §7 and record the response per the"
echo "audit conventions in the operator's copyright work."
