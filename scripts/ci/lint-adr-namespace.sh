#!/usr/bin/env bash
#
# lint-adr-namespace.sh — an ADR reference must say WHICH series it means.
#
# ============================================================================
# WHY THIS FILE EXISTS (ops#383)
# ============================================================================
# Three independent decision series all wrote the same token, `ADR-NNNN`:
#
#   1. the ENGINE series — docs/decisions/NNNN-*.md in nwp/nwp (0001-0039)
#   2. the PROFILE series — docs/decisions/NNNN-*.md inside each site profile
#      repo (0001-0018), replicated across nine site trees
#   3. a BANDED scheme invented by docs/onboarding/adrs.md, which re-indexed
#      the profile series into 10/20/30/40/50/60/70 bands purely so the
#      cheat-sheet's sections would sort tidily
#
# Measured 2026-08-22, before this gate existed: every integer 1-22 meant at
# least two different decisions, and 0020/0021/0022 meant THREE each — e.g.
# 0020 was simultaneously "tiered architecture model" (engine), "Disciples as
# fifth guild" (profile) and "editorial state machine" (banded). 904 bare
# references across 230 site markdown files, spanning 22 distinct numbers,
# every one of which resolved against docs/decisions/ and reported GREEN while
# naming a document its author had never read.
#
# The resolver that reported those greens is scripts/commands/doc-truth.sh's
# `dead-adr` check: `compgen -G "$PROJECT_ROOT/docs/decisions/${num}-*.md"`.
# It cannot be blamed. A bare number carries no information about which series
# it belongs to, so ANY resolver given a bare number is guessing. The fix is
# not a smarter resolver; it is to stop emitting ambiguous references.
#
# THE RULE: every `ADR-NNNN` in a tracked markdown file must carry a series
# prefix. `NWP-ADR-0020` is the engine's tiered architecture model.
# `NWC-ADR-0020` would be the nwc profile's. A bare `ADR-0020` is a defect
# because there is no fact of the matter about what it names.
#
# NUMBERS ARE NEVER REUSED AND NEVER REASSIGNED (Nygard). This gate adds a
# prefix and changes nothing else: NWP-ADR-0017 is the same document ADR-0017
# always was. Renumbering would have invalidated every citation in every
# transcript, issue and MR description in the estate.
#
# ============================================================================
# WHY THIS GATE HAS NO OVERRIDE, AND WHY THAT IS NOT A GAP
# ============================================================================
# The standing order (CLAUDE.md) is that a fail-closed guard must offer a
# TRUTHFUL exit — a recheck that clears on its own terms, or a ledgered
# override. That order exists because ops#361 found guards whose only exit was
# fabricating an operator approval.
#
# It does not apply here, because this gate has no false positives to escape
# from. Every other lint in scripts/ci/ carries a shrink-only baseline because
# it makes a JUDGEMENT (is this yq-first? is this a raw remote CLI? is this
# lowercase token a private site name?) and judgements misfire. This one makes
# an OBSERVATION with no judgement in it: the four characters before `ADR-`
# either are a recognised series prefix or they are not. A reference cannot be
# "legitimately bare"; bareness IS the defect, and the fix is always the same
# five keystrokes. A baseline here would only record "these references are
# still ambiguous, on purpose" — which is not a state anyone wants to bank.
#
# The truthful exit this gate DOES owe is the one it has: `--list` names every
# hit with the collision it would resolve into, so clearing a finding never
# requires guessing what the gate saw.
#
# What it MUST have, and does, is a CANNOT VERIFY path. An unreadable corpus,
# a non-git tree, or a corpus that scans to zero markdown files exits 2 — never
# 0. "I could not look" must never render as "I looked and it was clean"
# (CLAUDE.md fail-closed rule; the same direction NWP-ADR-0037 takes for review
# mode).
#
# ============================================================================
# CORPUS AND PREFIXES
# ============================================================================
# CORPUS: `git ls-files --cached --others --exclude-standard '*.md'` — every
# markdown file the ENGINE repo owns, tracked or newly added-but-uncommitted,
# with .gitignore honoured. That last part matters and is deliberate: the
# `sites/` trees are gitignored here because each is a SEPARATE repo with its
# own MR. Their 904 bare references are real and are the ops#383 follow-on,
# but they are not this repo's to fix and this gate will not report them.
#
# RECOGNISED PREFIXES are declared below in ADR_NAMESPACES. Adding one is a
# deliberate act: it declares that a new decision series exists and that this
# repo may cite it. An unrecognised prefix (`FOO-ADR-0001`) is reported as a
# hit, not silently accepted, because the alternative is that any typo in a
# prefix reads as a new namespace.
#
# EXEMPTION, one shape only: a line carrying the marker
# `<!-- adr-namespace:literal -->` is skipped. This exists so a document can
# QUOTE the defective bare form in order to describe it — a migration note, a
# forensic record, this gate's own documentation. It is per-LINE, invisible
# when rendered, and greps in one command. It is not an override of the rule;
# it is how a document says "I am naming the disease, not carrying it".
#
# EXIT
#   0 — every ADR reference in the corpus carries a recognised series prefix
#   1 — at least one bare or unrecognised-prefix reference
#   2 — CANNOT VERIFY (not a git checkout, corpus unreadable, corpus empty)
#
# Inspect: scripts/ci/lint-adr-namespace.sh --list
#
set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

# The declared decision series this repo may cite. See the header: adding a row
# declares a new namespace exists.
ADR_NAMESPACES="NWP NWC AVC"

# Per-line escape so a doc can quote the defective form while describing it.
LITERAL_MARKER='adr-namespace:literal'

MODE="check"
case "${1:-}" in
    --list)     MODE="list" ;;
    -h|--help)  sed -n '3,100p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "")         ;;
    *)          echo "lint-adr-namespace: unknown argument: $1" >&2; exit 2 ;;
esac

cannot_verify() {
    echo "CANNOT VERIFY: $1" >&2
    echo "lint:adr-namespace — exit 2. An unreadable corpus is not a clean corpus." >&2
    exit 2
}

command -v git >/dev/null 2>&1 || cannot_verify "git is not on PATH"
git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
    || cannot_verify "$PROJECT_ROOT is not a git checkout — cannot enumerate the corpus"

# ---------------------------------------------------------------------------
# Corpus
# ---------------------------------------------------------------------------
files_raw="$(cd "$PROJECT_ROOT" && git ls-files --cached --others --exclude-standard -- '*.md' 2>/dev/null)"
git_rc=$?
[ $git_rc -eq 0 ] || cannot_verify "git ls-files failed (rc=$git_rc)"

file_count=0
readable=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    file_count=$((file_count + 1))
    [ -r "$PROJECT_ROOT/$f" ] && readable=$((readable + 1))
done <<< "$files_raw"

[ "$file_count" -gt 0 ] || cannot_verify "corpus scanned to ZERO markdown files"
[ "$readable" -eq "$file_count" ] \
    || cannot_verify "$((file_count - readable)) of $file_count corpus files are unreadable"

# ---------------------------------------------------------------------------
# What does a bare number COLLIDE with? Reported alongside each hit so the
# failure names the ambiguity rather than merely asserting it.
# ---------------------------------------------------------------------------
engine_title_for() {
    local num="$1" hit
    hit="$(cd "$PROJECT_ROOT" && ls docs/decisions/"$num"-*.md 2>/dev/null | head -1)"
    [ -n "$hit" ] || { echo ""; return; }
    basename "$hit" .md | sed -E "s/^${num}-//; s/-/ /g"
}

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------
prefix_alt="$(echo "$ADR_NAMESPACES" | tr ' ' '|')"

findings=""
finding_count=0
declare -A numbers_seen=()

while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    abs="$PROJECT_ROOT/$rel"

    # grep -n over the file; -a so a stray binary byte cannot silence a file.
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        lineno="${line%%:*}"
        text="${line#*:}"

        case "$text" in *"$LITERAL_MARKER"*) continue ;; esac

        # Every ADR-NNNN on the line, WITH up to 8 preceding non-space chars so
        # the prefix (if any) is visible to the classifier.
        while IFS= read -r occ; do
            [ -n "$occ" ] || continue
            num="${occ##*ADR-}"

            # Recognised prefix immediately before `ADR-`?
            if [[ "$occ" =~ ($prefix_alt)-ADR-[0-9]{4}$ ]]; then
                continue
            fi

            # An unrecognised WORD-ish prefix is still a defect, but say so
            # differently: a typo'd namespace must not read as a new namespace.
            kind="bare"
            if [[ "$occ" =~ ([A-Za-z0-9]+)-ADR-[0-9]{4}$ ]]; then
                kind="unknown-prefix:${BASH_REMATCH[1]}"
            fi

            title="$(engine_title_for "$num")"
            if [ -n "$title" ]; then
                collides="resolves TODAY against docs/decisions/${num}-*.md ($title)"
            else
                collides="resolves against NO engine ADR — docs/decisions/${num}-*.md does not exist"
            fi

            findings+="${rel}:${lineno}|${kind}|ADR-${num}|${collides}"$'\n'
            finding_count=$((finding_count + 1))
            numbers_seen["$num"]=1
        done < <(grep -oE '[A-Za-z0-9_-]{0,12}ADR-[0-9]{4}' <<< "$text" 2>/dev/null)
    done < <(grep -anE 'ADR-[0-9]{4}' "$abs" 2>/dev/null)
done <<< "$files_raw"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if [ "$MODE" = "list" ]; then
    printf '%s' "$findings"
    [ "$finding_count" -eq 0 ] && exit 0
    exit 1
fi

if [ "$finding_count" -eq 0 ]; then
    echo "lint:adr-namespace — OK"
    echo "  corpus: $file_count tracked/untracked markdown files under $PROJECT_ROOT"
    echo "  every ADR reference carries a declared series prefix ($ADR_NAMESPACES)"
    exit 0
fi

echo "lint:adr-namespace — FAIL" >&2
echo "" >&2
echo "$finding_count ambiguous ADR reference(s) across ${#numbers_seen[@]} distinct number(s)." >&2
echo "A bare ADR-NNNN names no series, so any resolver reading it is guessing." >&2
echo "" >&2

# Group by file so the failure reads as a work list.
printf '%s' "$findings" | awk -F'|' '
    { split($1, p, ":"); f = p[1]
      if (f != last) { printf "\n  %s\n", f; last = f }
      printf "    line %-6s %-24s %s\n", p[2], $3 " (" $2 ")", $4 }
' >&2

echo "" >&2
echo "FIX: prefix the reference with the series it means." >&2
echo "  engine decisions (docs/decisions/)  -> NWP-ADR-NNNN" >&2
echo "  a site profile's own decisions      -> <CODE>-ADR-NNNN, where <CODE> is" >&2
echo "     that profile's short code, uppercased. Declared codes: $ADR_NAMESPACES" >&2
echo "" >&2
echo "There is deliberately NO baseline and NO override for this gate: a" >&2
echo "reference either carries a prefix or it does not, so there is no false" >&2
echo "positive to escape from. To QUOTE the bare form while describing it," >&2
echo "put <!-- $LITERAL_MARKER --> on that line." >&2
exit 1
