#!/usr/bin/env bash
#
# lint-review-mode-projection.sh — the review mode's anti-drift check.
#
# The mode is DERIVED from `approvers:` in private/secrets-registry.yml. CI cannot
# read that (separate repo), so the count is projected into the tracked
# .nwp-review-mode. Two representations of one fact can disagree, and the operator
# asked specifically that this not "drift back into complexity" — so the drift is
# MEASURED here rather than hoped away.
#
# WHERE THIS RUNS, AND WHY THAT MATTERS. Only a host that can read the registry can
# compare them, which means a workstation, not CI. That is exactly why this is a
# PRE-COMMIT hook: it runs where both are visible, so a contradicting projection
# never reaches a pipeline in the first place.
#
# EXIT
#   0 — they agree, or there is nothing to compare
#   1 — they DISAGREE: CI would enforce a policy the operator did not choose
#   2 — cannot verify (no yq AND no readable registry) — reported, never a silent pass
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/ui.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/gitlab-mr.sh"

reg=$(_mr_approver_registry)
if ! n=$(_mr_approver_count); then
    # NOT a pass. On a machine without the private repo there is nothing to check,
    # and saying so beats implying the projection was verified.
    echo "review-mode projection: CANNOT VERIFY — ${reg/#$HOME/~} is not readable here."
    echo "  Nothing to compare against, so the projection is UNCHECKED (not confirmed)."
    echo "  This is expected on a host without the private repo; run it where the"
    echo "  registry lives before trusting .nwp-review-mode."
    exit 2
fi

proj=$(_mr_review_mode_raw)
[ "$n" -eq 1 ] && want=solo || want=team

if [ "$proj" = "$want" ]; then
    echo "review-mode projection: OK — $n approver(s) declared, projection says $proj."
    exit 0
fi

echo "review-mode projection: DRIFT."
echo "  approvers: in ${reg/#$HOME/~} declares $n  ->  $want"
echo "  .nwp-review-mode says                         ${proj:-(nothing readable)}"
echo ""
echo "  CI reads the PROJECTION, so a pipeline would enforce '${proj:-fallback}' while"
echo "  the estate's declared fact says '$want'. That is the drift this check exists"
echo "  to stop reaching a pipeline."
echo ""
echo "  Fix:  pl mr review-mode sync   # then commit .nwp-review-mode"
exit 1
