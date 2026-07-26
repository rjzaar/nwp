#!/usr/bin/env bash
#
# lint-rollback-registry-ids.sh — refuse a rollback registry with a duplicate
# checkpoint ID.
#
# WHY THIS FILE EXISTS
#   On 2026-07-26 docs/reports/consolidation-arc-2026-07/rollback-registry.md
#   held CP19 x3, CP20 x4, CP21 x3, CP22 x2. Three agents each read the file,
#   each saw CP18 as the highest, and each allocated "the next four". Nothing
#   caught it: the file is prose in a table, and no gate reads it.
#
#   In the one document whose entire purpose is "to reverse checkpoint X, run
#   X's restore command", an AMBIGUOUS id is worse than a missing row. A missing
#   row fails loudly at lookup time. A duplicated row silently offers two
#   different restore commands under one name, and the operator reaching for it
#   is by definition already in an incident.
#
#   The underlying defect is structural, not clerical: a hand-assigned
#   monotonic counter cannot survive concurrent appenders, and it will recur
#   every time more than one agent runs. This gate does not fix that. It makes
#   the collision impossible to MERGE, which is the cheap half.
#
# WHAT THIS ASSERTS
#   Every registry table row whose first cell looks like a checkpoint id
#   (`| CP<something> |`) carries an id unique within that file.
#
# WHAT IT DELIBERATELY DOES NOT ASSERT
#   * Not that ids are contiguous, sorted, or numeric. CP-I3, CP-I8b and CP-nwc
#     are all legitimate and deliberate; the arc uses item-scoped ids precisely
#     to sidestep the shared counter. Demanding a dense integer sequence would
#     push authors back onto the counter that caused this.
#   * Not that a row is "correct". Only that its NAME resolves to one row.
#
# FAIL-CLOSED
#   A registry it cannot read, or a file with zero recognisable rows, is exit 2
#   (cannot verify) — never a pass. A gate that green-ticks an unreadable
#   corpus is the failure mode this repo keeps finding.
#
# EXIT
#   0 — every checkpoint id is unique
#   1 — at least one id is used by more than one row
#   2 — cannot verify (file missing/unreadable, or no rows found)
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2

rc=0
found_any=0

# Any rollback registry under docs/reports/**. Globbed, not hard-coded to one
# arc, so a future arc's registry is covered the day it is created rather than
# the day someone remembers to add it here.
shopt -s nullglob globstar
registries=(docs/reports/**/rollback-registry.md)

if [ "${#registries[@]}" -eq 0 ]; then
    echo "lint:registry-ids: CANNOT VERIFY — no rollback-registry.md found under docs/reports/." >&2
    exit 2
fi

for reg in "${registries[@]}"; do
    if [ ! -r "$reg" ]; then
        echo "lint:registry-ids: CANNOT VERIFY — $reg is not readable." >&2
        exit 2
    fi

    # First cell of a table row, when it looks like a checkpoint id.
    mapfile -t ids < <(grep -oE '^\| *CP[A-Za-z0-9_.-]+' "$reg" | sed 's/^| *//')

    if [ "${#ids[@]}" -eq 0 ]; then
        echo "lint:registry-ids: CANNOT VERIFY — $reg contains no recognisable CP rows." >&2
        exit 2
    fi
    found_any=1

    dupes="$(printf '%s\n' "${ids[@]}" | sort | uniq -d)"
    if [ -n "$dupes" ]; then
        echo "DUPLICATE CHECKPOINT IDS: $reg"
        while IFS= read -r d; do
            [ -n "$d" ] || continue
            echo "    $d is used by $(printf '%s\n' "${ids[@]}" | grep -cxF "$d") rows:"
            grep -nE "^\| *${d} *\|" "$reg" | cut -c1-140 | sed 's/^/        /'
        done <<< "$dupes"
        rc=1
    else
        echo "OK — $reg: ${#ids[@]} checkpoint row(s), all ids unique."
    fi
done

if [ "$found_any" -eq 0 ]; then
    echo "lint:registry-ids: CANNOT VERIFY — scanned 0 registries." >&2
    exit 2
fi

if [ "$rc" -ne 0 ]; then
    echo ""
    echo "Two rows share one checkpoint id. Reversing a checkpoint means looking"
    echo "it up BY NAME, so an ambiguous id offers two different restore commands"
    echo "to an operator who is already in an incident."
    echo ""
    echo "Fix by RENAMING the later row(s) — never by deleting one. The registry"
    echo "is append-only. Prefer an item-scoped id (CP-I5, CP-I8b) over the next"
    echo "integer: the shared counter is what collides when agents run in"
    echo "parallel, which is how every duplicate here was created."
fi
exit "$rc"
