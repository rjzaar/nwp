#!/usr/bin/env bash
#
# lint-site-names.sh — the engine tree must not name private site instances.
#
# ============================================================================
# WHY THIS FILE EXISTS (ops#326, operator ruling 2026-08-09)
# ============================================================================
# nwp/nwp is the generic engine; every real site instance lives in a private
# overlay. The engine repo is publicly mirrored, so a private instance's name
# in a tracked file is a disclosure. This lint is the permanent guard that
# stops NEW references accreting while the existing ones are migrated out
# (the ops#326 phased plan); the shrink-only baseline holds the debt.
#
# THE DENY-LIST IS DELIBERATELY NOT IN THIS REPO. A tracked list of private
# names would itself be the leak, and hashing does not save it: the names are
# 2-11 lowercase characters, dictionary-trivial to reverse. So the list lives
# in two untracked places and the lint fails CLOSED without one:
#
#   * CI:    $NWP_SITE_NAME_DENYLIST — a GitLab **file-type** CI variable
#            (the env var holds a PATH to the materialized file)
#   * local: private/site-names.deny (private/ is untracked / its own repo)
#
# An env var that names a file wins over the local default. Neither readable
# (or an empty/malformed list) → exit 2 CANNOT VERIFY, never exit 0 — the
# NWP-ADR-0037 direction: "I could not read the policy" must never look like a
# pass. The CI job surfaces exit 2 as a visible non-pass (see .gitlab-ci.yml).
#
# DENY-LIST FORMAT (one entry per line; blank lines and # comments ignored):
#
#   <name>[<whitespace><exclude-ERE>]
#
#   <name>        lowercase [a-z0-9][a-z0-9_-]* — matched with git grep -w
#                 (word boundaries; underscore is a WORD character, so code
#                 identifiers like frankenstyle plugin names do not match —
#                 same semantic as the ops#326 census).
#   <exclude-ERE> optional; the rest of the line. A hit whose whole record
#                 (path:line:content) matches this ERE is discounted. This is
#                 where per-name false-positive context lives — measured on
#                 the real tree 2026-08-09: word-boundary matching alone left
#                 ~1-2%% FPs for most short names (shell locals, minified JS)
#                 but ~57%% for one name that collides with a ubiquitous
#                 lowercase acronym in hyphenated compounds. Keeping the
#                 excludes IN the deny-list keeps name-specific tuning out of
#                 the tracked tree. Failure mode, accepted: a line containing
#                 both an excluded compound AND a real reference is
#                 discounted entirely.
#
# GLOBAL EXCLUDES (name-free, so they may live here): minified assets
# (*.min.js, *.min.css — third-party bundles, boundary-matched noise) and the
# baseline file itself (its rows are repo paths, each already scanned at its
# source; scanning the ledger of counts would only create a fixpoint).
#
# WHAT IS SCANNED: every tracked TEXT file's content (git grep -I), AND every
# tracked PATH (a file named after a private site leaks the name with no
# content at all — 60+ such paths existed at introduction). A path hit counts
# as one finding against that file.
#
# BASELINE (.site-name-baseline) — tracked, SHRINK-ONLY, and NAME-FREE:
# rows are `<path><TAB><count>` where count aggregates finding records
# (name,line and name,path pairs) across ALL denied names. The tracked
# baseline therefore asserts only "this file has N matches against a private
# list" — zero information beyond what the tracked file itself discloses
# today, and a row must be DELETED when its file is cleaned (exactness is
# enforced both directions), so the baseline cannot retain ghosts of scrubbed
# names. Per-name rows keyed by deny-list index were considered and rejected:
# indexes shift when the list grows, and post-scrub the rows would still
# group files by which unknown name they shared — a re-identification aid.
# Accepted failure mode of the aggregate: swapping one denied name for
# another in the same file with an identical record count is invisible to the
# baseline (it is still visible in --list and in MR review).
#
# EXIT
#   0 — every finding is baselined, and the baseline is exact
#   1 — a NEW finding, a GROWN count, or a stale/shrunk baseline row
#   2 — CANNOT VERIFY (no deny-list, empty deny-list, malformed name, not a
#       git checkout) — fail closed, never silently green
#
# Regenerate: scripts/ci/lint-site-names.sh --update-baseline  (growing any
# row is a recorded decision — say why in the commit message)
# Inspect:    scripts/ci/lint-site-names.sh --list

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${NWP_SITE_NAME_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
BASELINE="${NWP_SITE_NAME_BASELINE:-}"
DENYLIST="${NWP_SITE_NAME_DENYLIST:-}"

MODE=check
while [ $# -gt 0 ]; do
    case "$1" in
        --list)            MODE=list ;;
        --update-baseline) MODE=update ;;
        --root=*)          PROJECT_ROOT="${1#*=}" ;;
        --baseline=*)      BASELINE="${1#*=}" ;;
        --denylist=*)      DENYLIST="${1#*=}" ;;
        --help|-h)
            sed -n '2,90p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)  echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

[ -n "$BASELINE" ] || BASELINE="$PROJECT_ROOT/.site-name-baseline"

cd "$PROJECT_ROOT" 2>/dev/null || {
    echo "lint:site-names: CANNOT VERIFY — cannot cd to $PROJECT_ROOT" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "lint:site-names: CANNOT VERIFY — not a git checkout, no tracked corpus" >&2; exit 2; }

# ---------------------------------------------------------------- deny-list --
# private/ is its own repo and is NOT linked into git worktrees, so a worktree
# checkout has no deny-list of its own. Resolving only against PROJECT_ROOT made
# this exit 2 CANNOT VERIFY in every worktree — which is fail-closed and correct
# for CI, but as a pre-commit hook it blocked EVERY commit made from a worktree,
# and worktrees are where this estate does its work (`pl issue work`). So fall
# back to the MAIN working tree, which is where private/ actually lives. Found
# by running the hook against a real commit rather than inspecting its config.
if [ -z "$DENYLIST" ]; then
    DENYLIST="$PROJECT_ROOT/private/site-names.deny"
    if [ ! -r "$DENYLIST" ]; then
        _main_wt="$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
        [ -n "$_main_wt" ] && _main_wt="$(dirname "$_main_wt")"
        [ -n "$_main_wt" ] && [ -r "$_main_wt/private/site-names.deny" ] \
            && DENYLIST="$_main_wt/private/site-names.deny"
    fi
fi
if [ ! -r "$DENYLIST" ]; then
    echo "lint:site-names: CANNOT VERIFY — no readable deny-list." >&2
    echo "  Sources tried: \$NWP_SITE_NAME_DENYLIST (CI file variable), then" >&2
    echo "  $PROJECT_ROOT/private/site-names.deny (local)." >&2
    echo "  Refusing to report success without the policy (fail closed)." >&2
    exit 2
fi

names=()
excludes=()
while IFS= read -r line; do
    line="${line%%$'\r'}"
    case "$line" in ''|\#*) continue ;; esac
    n="${line%%[[:space:]]*}"
    e=""
    [ "$n" != "$line" ] && { e="${line#*[[:space:]]}"; e="${e#"${e%%[![:space:]]*}"}"; }
    if ! printf '%s' "$n" | grep -qE '^[a-z0-9][a-z0-9_-]*$'; then
        echo "lint:site-names: CANNOT VERIFY — malformed deny-list entry: '$n'" >&2
        echo "  (names must match [a-z0-9][a-z0-9_-]*; a policy the lint cannot" >&2
        echo "  parse safely is a policy it must not pretend to enforce)" >&2
        exit 2
    fi
    names+=("$n"); excludes+=("$e")
done < "$DENYLIST"

if [ "${#names[@]}" -eq 0 ]; then
    echo "lint:site-names: CANNOT VERIFY — deny-list is empty: $DENYLIST" >&2
    echo "  An empty policy is indistinguishable from a missing one (fail closed)." >&2
    exit 2
fi

EXCLUDE_PATHSPECS=(':(exclude)*.min.js' ':(exclude)*.min.css'
                   ":(exclude)$(basename "$BASELINE")")

# ------------------------------------------------------------------- scan ----
findings="$(mktemp)"
trap 'rm -f "$findings" "$findings.rows" "$findings.base"' EXIT
: > "$findings"

for i in "${!names[@]}"; do
    n="${names[$i]}"; e="${excludes[$i]}"
    # content: path:line:content records for word-boundary hits in tracked text
    if [ -n "$e" ]; then
        git grep -In --word-regexp -e "$n" -- . "${EXCLUDE_PATHSPECS[@]}" 2>/dev/null \
            | grep -vE -- "$e" || true
    else
        git grep -In --word-regexp -e "$n" -- . "${EXCLUDE_PATHSPECS[@]}" 2>/dev/null || true
    fi | awk -F: -v n="$n" 'NF >= 2 { print $1 "\t" $2 "\t" n }' >> "$findings"
    # paths: a tracked filename carrying the name is a finding in itself
    if [ -n "$e" ]; then
        git ls-files -- . "${EXCLUDE_PATHSPECS[@]}" 2>/dev/null \
            | grep -w -e "$n" | grep -vE -- "$e" || true
    else
        git ls-files -- . "${EXCLUDE_PATHSPECS[@]}" 2>/dev/null \
            | grep -w -e "$n" || true
    fi | awk -v n="$n" '{ print $0 "\t(path)\t" n }' >> "$findings"
done

LC_ALL=C sort -o "$findings" "$findings"

if [ "$MODE" = "list" ]; then
    awk -F'\t' '{ printf "%s:%s: %s\n", $1, $2, $3 }' "$findings"
    exit 0
fi

# rows: path<TAB>count (aggregate across names — see privacy note in header)
cut -f1 "$findings" | LC_ALL=C sort | uniq -c \
    | sed -E 's/^ *([0-9]+) (.*)$/\2\t\1/' > "$findings.rows"

# -------------------------------------------------------------- update mode --
if [ "$MODE" = "update" ]; then
    sticky=""
    [ -f "$BASELINE" ] && sticky="$(grep '^#=' "$BASELINE" 2>/dev/null)"
    {
        echo "# .site-name-baseline — tracked files that still reference private site"
        echo "# instances (ops#326). Generated by scripts/ci/lint-site-names.sh."
        echo "#"
        echo "# Rows are <path><TAB><count>: count of word-boundary matches in that file"
        echo "# (content lines + the path itself) against the PRIVATE deny-list, summed"
        echo "# over all denied names. The names themselves are deliberately NOT here —"
        echo "# a tracked deny-list would be the leak this lint exists to prevent."
        echo "#"
        echo "# SHRINK-ONLY. Deleting/lowering a row is a fix (and is REQUIRED in the"
        echo "# same MR that cleans the file — exactness is enforced both directions)."
        echo "# Growing or adding a row is a recorded decision: say in the commit"
        echo "# message why a new private-name reference is going into the tree."
        echo "# Regenerate: scripts/ci/lint-site-names.sh --update-baseline"
        echo "# Inspect:    scripts/ci/lint-site-names.sh --list"
        [ -n "$sticky" ] && printf '%s\n' "$sticky"
        cat "$findings.rows"
    } > "$BASELINE"
    echo "Baseline written: $BASELINE ($(wc -l < "$findings.rows" | tr -d ' ') row(s))"
    exit 0
fi

# --------------------------------------------------------------- check mode --
declare -A base=()
if [ -f "$BASELINE" ]; then
    while IFS=$'\t' read -r p c; do
        [ -z "$p" ] && continue
        case "$p" in \#*) continue ;; esac
        base["$p"]="$c"
    done < "$BASELINE"
fi

new=0 grown=0 stale=0
while IFS=$'\t' read -r p c; do
    [ -z "$p" ] && continue
    b="${base[$p]:-}"
    if [ -z "$b" ]; then
        new=$((new + 1))
        echo "NEW private-name reference(s): $p ($c match(es))"
        grep -F "$p	" "$findings" | head -5 \
            | awk -F'\t' '{ printf "    %s:%s: matches denied name \x27%s\x27\n", $1, $2, $3 }'
    elif [ "$c" -gt "$b" ]; then
        grown=$((grown + 1))
        echo "REFERENCES GREW: $p  $b -> $c (shrink-only)"
    elif [ "$c" -lt "$b" ]; then
        stale=$((stale + 1))
        echo "REFERENCES SHRANK (good) — lower the baseline row in this MR: $p  $b -> $c"
    fi
done < "$findings.rows"

for p in "${!base[@]}"; do
    grep -qF "$p	" "$findings.rows" && continue
    stale=$((stale + 1))
    echo "STALE BASELINE ROW (file clean or gone — delete the row): $p"
done

if [ "$((new + grown))" -gt 0 ]; then
    echo ""
    echo "ERROR: $new new / $grown grown private-site-name finding(s)."
    echo "  The engine tree must not name private site instances (ops#326)."
    echo "  Use the shipped sample pair or a fictional fixture name instead."
    echo "  If this reference is a deliberate, recorded decision:"
    echo "    scripts/ci/lint-site-names.sh --update-baseline   # + rationale in the commit message"
    exit 1
fi
if [ "$stale" -gt 0 ]; then
    echo ""
    echo "ERROR: $stale stale baseline row(s) — the tree improved; make the baseline say so:"
    echo "    scripts/ci/lint-site-names.sh --update-baseline"
    exit 1
fi

echo "OK — no new private-site-name references ($(wc -l < "$findings.rows" | tr -d ' ') baselined file(s), ${#names[@]} denied name(s))"
exit 0
