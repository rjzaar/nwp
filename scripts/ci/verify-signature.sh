#!/usr/bin/env bash
#
# verify-signature.sh — say out loud how many commits are actually signed.
#
# WHY THIS FILE EXISTS
#   The `verify-signature` CI job was:
#       script: - echo "Signature verification — placeholder until signing is configured"
#       allow_failure: true
#   A green tick on a job named "verify-signature" that verifies nothing, while
#   CLAUDE.md states "Signed commits and signed artifacts are mandatory, not
#   optional". A green tick asserting something false is worse than no job.
#
#   Commit signing needs the operator's key/hardware token on the authoring
#   machines — an agent cannot fix it. What an agent CAN do is stop the pipeline
#   from asserting it away. So this runs `git verify-commit` for real and prints
#   the true numbers.
#
# MODES
#   report-only (default)  — prints signed/unsigned counts, exits 0.
#                            Honest: the log shows "0 of 12 signed".
#   enforcing              — NWP_REQUIRE_SIGNED_COMMITS=1 (or --require);
#                            exits 1 if any commit in the range is unsigned.
#                            Flip this on once signing is configured.
#
# EXIT
#   0 — report mode, or enforcing and every commit verified
#   1 — enforcing and at least one commit unsigned/bad
#   2 — cannot verify (no gpg/range unresolvable) — never a silent pass

set -uo pipefail

REQUIRE="${NWP_REQUIRE_SIGNED_COMMITS:-0}"
BASE="${CI_MERGE_REQUEST_DIFF_BASE_SHA:-${CI_COMMIT_BEFORE_SHA:-}}"
HEAD_REF="HEAD"

while [ $# -gt 0 ]; do
    case "$1" in
        --require) REQUIRE=1 ;;
        --base=*)  BASE="${1#*=}" ;;
        --head=*)  HEAD_REF="${1#*=}" ;;
        -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

case "$BASE" in
    ""|0000000000000000000000000000000000000000)
        BASE="$(git rev-parse --verify --quiet "${HEAD_REF}~20" 2>/dev/null || git rev-list --max-parents=0 "$HEAD_REF" | tail -1)"
        ;;
esac

if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
    echo "ERROR: cannot resolve compare base '$BASE'." >&2
    exit 2
fi

mapfile -t commits < <(git rev-list "${BASE}..${HEAD_REF}" 2>/dev/null)
if [ "${#commits[@]}" -eq 0 ]; then
    echo "No commits in ${BASE}..${HEAD_REF} — nothing to verify."
    exit 0
fi

signed=0; unsigned=0
for c in "${commits[@]}"; do
    if git verify-commit "$c" >/dev/null 2>&1; then
        signed=$((signed + 1))
    else
        unsigned=$((unsigned + 1))
        echo "UNSIGNED: $(git log -1 --format='%h %s' "$c")"
    fi
done

echo ""
echo "Signature report for ${BASE}..${HEAD_REF}: ${signed} signed / ${unsigned} unsigned (${#commits[@]} total)"

if [ "$REQUIRE" = "1" ]; then
    if [ "$unsigned" -gt 0 ]; then
        echo "ERROR: signing is enforced (NWP_REQUIRE_SIGNED_COMMITS=1) and ${unsigned} commit(s) are unsigned." >&2
        exit 1
    fi
    echo "OK — every commit in range carries a valid signature."
    exit 0
fi

if [ "$unsigned" -gt 0 ]; then
    cat <<EOF

NOTE: this job is REPORT-ONLY. CLAUDE.md says signed commits are mandatory, and
      ${unsigned} of ${#commits[@]} commit(s) in this range are not signed. This job exits 0
      so the gap is VISIBLE rather than asserted away; it does not certify the
      commits. Set NWP_REQUIRE_SIGNED_COMMITS=1 as a CI variable to enforce
      once signing keys are configured on the authoring machines.
EOF
fi
exit 0
