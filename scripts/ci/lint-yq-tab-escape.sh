#!/usr/bin/env bash
#
# lint-yq-tab-escape.sh — refuse a yq expression that builds a separator with
# the "\t" escape.
#
# WHY THIS FILE EXISTS
#   yq only began expanding "\t" to a real tab in v4.45+. CI pins v4.44.1, where
#   it stays a literal backslash-t. So `.key + "\t" + .value` produces
#
#       mykey\tmyvalue          (one field, containing the characters \ and t)
#
#   and the `IFS=$'\t' read -r k v` on the other end silently fails to split:
#   `k` gets the whole line and `v` gets nothing. Nothing errors. The loop just
#   quietly does nothing, or does it wrong.
#
#   The reason this is a GATE and not another comment is that four files in this
#   tree ALREADY carry prose warning about it:
#
#       lib/gitlab-issues.sh:288      lib/pair.sh:208
#       lib/gitlab-mr.sh:306          scripts/commands/monitor.sh:99
#
#   and on 2026-08-03 lib/gitlab-tunables.sh hit it anyway — written by someone
#   who had not read those four comments, on a workstation with v4.50.1 where
#   the bug is invisible. Four warnings did not prevent a fifth instance. A
#   check that fails the pipeline will.
#
#   The same shape has now produced a green-locally/red-in-CI failure three
#   times in two days (test-issue-ls-pagination, the !317 baseline work, and
#   this). It is the single most repeated defect in the tree.
#
# WHAT IT ASSERTS
#   No shell file passes a yq expression containing "\t" (or '\t') OUTSIDE a
#   comment. Use a real tab via strenv:
#
#       TAB=$'\t' yq e -r '... .key + strenv(TAB) + .value ...'
#
#   or pick a separator that needs no escaping (a literal "|" is fine when the
#   data cannot contain one — see scripts/commands/monitor.sh).
#
# EXIT
#   0 — clean
#   1 — at least one offending line
#   2 — cannot verify (no corpus)

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2

shopt -s nullglob globstar
files=(lib/**/*.sh scripts/**/*.sh)
if [ "${#files[@]}" -eq 0 ]; then
    echo "lint:yq-tab: CANNOT VERIFY — no shell files found." >&2
    exit 2
fi

# A line is an offender when it mentions yq AND contains a \t escape inside a
# quoted expression, and is not a comment. Comments are exempt on purpose: the
# four warnings above must stay readable, and taxing the explanation is how you
# train people to delete it.
# THE DEFECT SHAPE, precisely: a \t escape used as a CONCATENATION OPERAND
# inside a yq expression — `.a + "\t" + .b`. Narrowed to that because the first
# draft of this gate flagged three things that are not defects:
#   * `TAB=$'\t'` — bash ANSI-C quoting, which IS a real tab. That is the FIX.
#     A gate that condemns its own remedy is worse than no gate.
#   * this file's own help text
#   * any incidental \t in a comment
# Comments are exempt: four files carry prose warnings about this trap and
# taxing the explanation is how you train people to delete it.
hits=""
for f in "${files[@]}"; do
    [ -r "$f" ] || continue
    while IFS= read -r line; do
        n="${line%%:*}"
        body="${line#*:}"
        trimmed="${body#"${body%%[! ]*}"}"
        case "$trimmed" in \#*) continue ;; esac
        case "$f" in */lint-yq-tab-escape.sh) continue ;; esac
        # concatenation operand only: + "\t"   or   "\t" +
        if printf '%s' "$body" | grep -qE '\+[[:space:]]*"\\t"|"\\t"[[:space:]]*\+'; then
            hits="${hits}${f}:${n}: ${trimmed:0:100}"$'\n'
        fi
    done < <(grep -n '\\t' "$f" 2>/dev/null)
done

if [ -n "$hits" ]; then
    echo "YQ TAB ESCAPE — these produce a literal backslash-t on yq < v4.45 (CI pins v4.44.1):"
    printf '%s' "$hits" | sed 's/^/    /'
    echo ""
    echo "  The field split on the other end fails SILENTLY: the reader gets one"
    echo "  field instead of two and the loop does nothing, or does it wrong. It"
    echo "  works on a workstation with a newer yq, which is why this keeps"
    echo "  reaching CI."
    echo ""
    echo "  Fix:  TAB=\$'\\t' yq e -r '... .key + strenv(TAB) + .value ...'"
    echo "  Or:   choose a separator needing no escape (see scripts/commands/monitor.sh)."
    exit 1
fi

echo "OK — no yq expression builds a separator with the \\t escape."
exit 0
