#!/usr/bin/env bash
#
# review-marker-gate.sh — turn the `security:review` job from a printed
# checklist into an assertion.
#
# WHY THIS FILE EXISTS
#   `security:review` in .gitlab-ci.yml ended with:
#       echo "Review: Does the diff match the MR title and description?"
#       echo "Red flags:"
#       echo "  - Large changeset for small fix"
#       ...
#   i.e. it rendered CLAUDE.md's red-flag checklist as literal `echo` lines and
#   exited 0. Nothing was checked. It was also `allow_failure: true`.
#
# WHAT IT ASSERTS
#   CLAUDE.md ("Sensitive File Paths") names paths that require extra scrutiny
#   and two-person approval. The project convention for flagging a change as
#   human-review class is a `REVIEW:` marker. So:
#
#       if the diff touches a CLAUDE.md sensitive path
#       and neither the MR title nor any commit subject in the range carries
#       `REVIEW:`  →  FAIL.
#
#   That is a claim that can be false, which is the whole point. It does not
#   pretend to judge the change — it only refuses to let a sensitive-path change
#   through unlabelled.
#
# USAGE
#   scripts/ci/review-marker-gate.sh [--base=<ref>] [--head=<ref>] [--title=<s>]
#   Defaults come from GitLab CI predefined variables.
#
# EXIT
#   0 — no sensitive path touched, or a REVIEW: marker is present
#   1 — sensitive path touched with no REVIEW: marker
#   2 — cannot verify (base ref unreachable) — fail closed, never silently green

set -uo pipefail

BASE="${CI_MERGE_REQUEST_DIFF_BASE_SHA:-}"
HEAD_REF="HEAD"
TITLE="${CI_MERGE_REQUEST_TITLE:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --base=*)  BASE="${1#*=}" ;;
        --head=*)  HEAD_REF="${1#*=}" ;;
        --title=*) TITLE="${1#*=}" ;;
        -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -z "$BASE" ] && [ -n "${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-}" ]; then
    git fetch -q origin "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME" 2>/dev/null || true
    BASE="origin/${CI_MERGE_REQUEST_TARGET_BRANCH_NAME}"
fi
[ -n "$BASE" ] || BASE="origin/main"

if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
    echo "ERROR: cannot resolve compare base '$BASE' — cannot verify the diff." >&2
    echo "       Failing closed rather than reporting a vacuous pass." >&2
    exit 2
fi

# CLAUDE.md "Sensitive File Paths" (two-person approval class), verbatim.
SENSITIVE_PATTERNS=(
    '^lib/auth'
    '^lib/[^/]*secret'
    '(^|/)settings\.php$'
    '^\.gitlab-ci\.yml$'
    '(^|/)composer\.json$'
    '^scripts/commands/live'
    '^CLAUDE\.md$'
    '(^|/)\.env'
    '^keys/'
)

mapfile -t changed < <(git diff --name-only "${BASE}...${HEAD_REF}" 2>/dev/null)
if [ "${#changed[@]}" -eq 0 ]; then
    echo "No files changed against ${BASE} — nothing to review."
    exit 0
fi

touched=()
for f in "${changed[@]}"; do
    for p in "${SENSITIVE_PATTERNS[@]}"; do
        if printf '%s\n' "$f" | grep -qE "$p"; then
            touched+=("$f")
            break
        fi
    done
done

echo "Files changed: ${#changed[@]}"
if [ "${#touched[@]}" -eq 0 ]; then
    echo "OK — no CLAUDE.md sensitive path touched."
    exit 0
fi

echo "Sensitive paths touched (${#touched[@]}):"
printf '  %s\n' "${touched[@]}"

subjects="$(git log --format='%s%n%b' "${BASE}..${HEAD_REF}" 2>/dev/null)"
if printf '%s\n%s\n' "$TITLE" "$subjects" | grep -q 'REVIEW:'; then
    echo ""
    echo "OK — change carries a REVIEW: marker; routed for human review."
    exit 0
fi

cat <<'EOF'

ERROR: this change touches a CLAUDE.md sensitive path but carries no `REVIEW:`
       marker in the MR title or in any commit message in the range.

       Sensitive paths require extra scrutiny and two-person approval
       (CLAUDE.md → "Sensitive File Paths"). Mark the change explicitly:

         * prefix the MR title with `REVIEW:`, or
         * put `REVIEW:` in the commit subject of the sensitive commit.

       This gate does not judge the change — it only refuses to let a
       sensitive-path change through unlabelled.
EOF
exit 1
