#!/usr/bin/env bash
#
# lint-conflict-markers.sh — refuse a tree that still contains merge-conflict
# markers.
#
# WHY THIS FILE EXISTS
#   On 2026-07-26, commit 3c4c631 on `fix/item8-art9-cross-repo-contract` was
#   pushed with an UNRESOLVED merge sitting in the tree:
#
#       docs/reports/consolidation-arc-2026-07/decision-log.md
#         1031:  <<<<<<< HEAD
#         1129:  =======
#         1246:  >>>>>>> c6ba428 (REVIEW: fix(contracts): ...)
#
#   The MR went green. Every lint job, the unit suite, the integration suite,
#   the leakage gate and doc-truth all passed over a file with conflict markers
#   in it, because not one of them looks for markers. The file in question is
#   the arc DECISION LOG — the append-only record of what was decided and why —
#   so the corruption landed in exactly the artifact whose whole value is being
#   trustworthy.
#
#   It was caught by a human reading the rebase, which is not a control.
#
# WHAT THIS ASSERTS
#   No TRACKED file contains a line that is a conflict marker:
#       ^<<<<<<< , ^>>>>>>> , ^=======$ , ^||||||| (diff3 base section)
#
#   Tracked-only: untracked scratch and ignored build output are not the repo's
#   problem, and scanning them makes the gate slow and flaky.
#
# DOCUMENTING THE MARKERS vs HAVING THEM
#   The arc decision log records the 3c4c631 finding, and the natural way to
#   write that up is a fenced example of the exact thing the gate hunts for:
#
#       ```
#       <<<<<<< HEAD
#       ...
#       ```
#
#   A first version of this gate reddened on precisely that, i.e. it blocked
#   `main` on its own bug report. Measured: appending that write-up to
#   decision-log.md flipped the gate to exit 1. A check that fires on prose
#   describing itself gets disabled within a week, so:
#
#     * in markdown, marker lines INSIDE a ``` / ~~~ fenced block are exempt —
#       that is how a document shows a conflict instead of having one;
#     * the exemption is never silent: the job prints which file used one and
#       how many lines, so it cannot become a quiet blanket suppression;
#     * an UNBALANCED fence exempts nothing (fail closed), so you cannot hide a
#       real conflict by opening a fence and never closing it;
#     * outside a fence, and in every non-markdown file, a marker is still a
#       hard failure. The 3c4c631 corruption was at top level, not in a fence,
#       so the historical case this gate exists for is still caught — there is
#       a regression test that replays that exact commit.
#
# WHY THE `=======` RULE IS ANCHORED
#   A bare `=======` line is also legitimate Markdown setext-H1 underlining and
#   reStructuredText section punctuation. Matching it ALONE would redden ordinary
#   docs. So `^=======$` (7 chars, nothing else on the line) only counts when the
#   same file ALSO carries a `<<<<<<<` or `>>>>>>>` opener — a `=======` on its
#   own is not evidence of a conflict, but a `=======` next to a `<<<<<<<` is.
#
# SELF-EXEMPTION
#   This script documents the markers it hunts for, so it must not match itself.
#   The patterns are written in ERE repetition form (`<{7}`, not seven literal
#   `<`), so no line in this file is itself a marker and the gate can scan its
#   own source. Do NOT "simplify" these to literals.
#
#   (First cut of this script built the literals with printf and interpolated
#   them into an alternation — `^(<<<<<<<|>>>>>>>|\|\|\|\|\|\|\|) `. The seven
#   pipes of the diff3 base marker are ERE alternation metacharacters, so that
#   pattern reduced to "empty branch", matched every line of every file, and
#   reported the whole repo as conflicted. Repetition form has no such trap.)
#
# EXIT
#   0 — clean
#   1 — at least one tracked file contains conflict markers
#   2 — cannot verify (not a git repo / git unavailable) — fail closed
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2

command -v git >/dev/null 2>&1 || { echo "lint:conflict-markers: CANNOT VERIFY — git unavailable." >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "lint:conflict-markers: CANNOT VERIFY — not a git repository." >&2; exit 2; }

# ERE repetition form: matches the markers without this file containing one.
# A real marker line is the 7 chars then a space (git always writes a label
# after `<<<<<<<` / `>>>>>>>` / `|||||||`).
MARKER_RE='^(<{7}|>{7}|\|{7}) '
MID_RE='^={7}$'

mapfile -t files < <(git ls-files -z | tr '\0' '\n')
if [ "${#files[@]}" -eq 0 ]; then
    echo "lint:conflict-markers: CANNOT VERIFY — git ls-files returned nothing." >&2
    exit 2
fi

# Emit the line numbers of every FENCED CODE BLOCK line in a markdown file, so
# the scan can exempt them. See the DOCUMENTING THE MARKERS note above.
# Fail-closed: if the file ends while a fence is still open, emit nothing — an
# unbalanced fence must not turn the rest of the file into a blind spot.
# The line numbers are BUFFERED and only emitted at END. Printing them as we go
# would defeat the fail-closed rule: awk streams, so an unbalanced fence would
# already have emitted its exemptions before END could suppress them (that hole
# was caught by the "UNBALANCED fence exempts nothing" test, which went red).
_fenced_lines() { # $1 = file  -> newline-separated line numbers, or nothing
    awk '
        /^[[:space:]]*(```|~~~)/ {
            inside = !inside
            buf = buf NR "\n"
            next
        }
        inside { buf = buf NR "\n" }
        END { if (!inside) printf "%s", buf }
    ' "$1" 2>/dev/null || true
}

rc=0
scanned=0
exempted_total=0
for f in "${files[@]}"; do
    [ -f "$f" ] || continue                 # submodule gitlinks, deleted-in-worktree
    grep -Iq . "$f" 2>/dev/null || continue # skip binaries
    scanned=$((scanned + 1))

    hits="$(grep -nE "$MARKER_RE" "$f" 2>/dev/null || true)"
    # A bare `=======` only counts alongside a real opener/closer (setext H1).
    if [ -n "$hits" ]; then
        mid_hits="$(grep -nE "$MID_RE" "$f" 2>/dev/null || true)"
        [ -n "$mid_hits" ] && hits="${hits}"$'\n'"${mid_hits}"
    fi
    [ -n "$hits" ] || continue

    # Markdown only: drop hits that sit inside a fenced code block. That is how
    # a document SHOWS a conflict rather than HAVING one, and it is the shape
    # docs/reports/consolidation-arc-2026-07/decision-log.md uses to record the
    # 3c4c631 finding. A gate that reddens on the write-up of the bug it exists
    # to catch gets switched off within a week.
    exempted=0
    case "$f" in
        *.md|*.markdown)
            fenced="$(_fenced_lines "$f")"
            if [ -n "$fenced" ]; then
                kept=""
                while IFS= read -r h; do
                    [ -n "$h" ] || continue
                    ln="${h%%:*}"
                    if printf '%s\n' "$fenced" | grep -qxF "$ln"; then
                        exempted=$((exempted + 1))
                    else
                        kept="${kept}${kept:+$'\n'}${h}"
                    fi
                done <<< "$hits"
                hits="$kept"
            fi ;;
    esac

    # An exemption is never silent: say which file used one and how many lines.
    if [ "$exempted" -gt 0 ]; then
        echo "note: ${f}: ${exempted} marker-like line(s) exempted inside fenced code block(s)"
        exempted_total=$((exempted_total + exempted))
    fi

    if [ -n "$hits" ]; then
        echo "CONFLICT MARKERS: $f"
        printf '%s\n' "$hits" | sed 's/^/    /'
        rc=1
    fi
done

if [ "$scanned" -eq 0 ]; then
    echo "lint:conflict-markers: CANNOT VERIFY — scanned 0 files." >&2
    exit 2
fi

if [ "$rc" -eq 0 ]; then
    suffix=""
    [ "$exempted_total" -gt 0 ] && suffix=" (${exempted_total} line(s) exempted inside fenced examples)"
    echo "OK — scanned ${scanned} tracked text file(s); no merge-conflict markers${suffix}."
else
    echo ""
    echo "An unresolved merge is in the tree. Resolve it and re-commit."
    echo "For the append-only arc docs (decision-log.md, rollback-registry.md)"
    echo "the resolution is ALWAYS to keep BOTH sides — never drop an entry."
fi
exit "$rc"
