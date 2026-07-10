#!/bin/bash
################################################################################
# lib/boundary.sh — the intersite change-impact classifier (P74 Phase 2)
#
# SIBLING to lib/impact.sh. impact.sh answers "what does this DESTRUCTIVE verb
# destroy?" (blast-radius at deploy). boundary.sh answers "does this DIFF touch
# the nwc↔ssc boundary?" (blast-radius at commit) — same philosophy, orthogonal
# axis. It reads the SAME source of truth impact.sh's renderer style comes from,
# and the boundary declaration lives in the pair contract's `boundary:` block
# (pairs/<pair>.pair-contract.yml), so classification is a pure set-intersection
# with ONE declared boundary, no hardcoding (research report §3).
#
# CONTRACT: classify only, never block. `pl impact` exits 0 always. It is
# FAIL-SAFE CLOSED: if the diff cannot be computed (bad base, detached history,
# no git), the change is treated as BOUNDARY-TOUCHING — "can't compute" must
# NEVER mean "internal" (research §3, path-gating fail-safe rule).
#
# Public API:
#   boundary_contract_file [pair_id]      → path to the pair contract
#   boundary_surfaces [file]              → surface names with a boundary: entry
#   boundary_paths <surface> [file]       → provider_paths + consumer_paths globs
#   boundary_symbols <surface> [file]     → provider_symbols
#   boundary_match_path <path> [file]     → echoes the surface(s) a path touches
#   boundary_changed_files <base>         → changed files (git, or NWP_IMPACT_FILES)
#   boundary_classify <base> [file]       → sets BOUNDARY_* globals (see below)
#   boundary_render                       → human report (impact.sh idiom)
#   boundary_json                         → machine summary for CI (--json)
#   boundary_honesty_violations [file]    → manifest-honesty check (Phase 1)
#
# Test/CI hook: export NWP_IMPACT_FILES="<newline-separated changed paths>" to
# feed a synthetic diff instead of calling git (used by the bats suite and by a
# CI runner that already computed the diff).
################################################################################

# Colors + PROJECT_ROOT: reuse impact.sh (defines RED/GREEN/YELLOW/BOLD/NC with
# the same TTY-aware fallback). Source is idempotent.
_BOUNDARY_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [[ -z "${RED+x}" ]]; then
    # shellcheck source=/dev/null
    [ -f "$_BOUNDARY_DIR/impact.sh" ] && source "$_BOUNDARY_DIR/impact.sh"
fi
: "${PROJECT_ROOT:=$( cd "$_BOUNDARY_DIR/.." && pwd )}"

# Results of the last boundary_classify (globals; one classification in flight).
BOUNDARY_CLASS=""            # INTERNAL | BOUNDARY-TOUCHING | BOUNDARY
BOUNDARY_SURFACES=()         # surfaces touched (names)
BOUNDARY_FILES=()            # changed files considered
BOUNDARY_HITS=()             # "surface|path" pairs that matched
BOUNDARY_UNCOMPUTABLE=0      # 1 ⇒ diff could not be computed (fail-safe closed)
BOUNDARY_BASE=""             # base ref used
BOUNDARY_REASON=""           # short human reason

# --- contract access ---------------------------------------------------------

# Echo the pair contract file. Default pair id: ssc (the real nwc↔ssc pair).
# Honors NWP_PAIR_CONTRACT_DIR (same override lib/pair.sh uses).
boundary_contract_file() {
    local pair_id="${1:-ssc}"
    local dir="${NWP_PAIR_CONTRACT_DIR:-${PROJECT_ROOT}/pairs}"
    echo "${dir}/${pair_id}.pair-contract.yml"
}

_boundary_yq() { command -v yq 2>/dev/null || true; }

# List surface names that carry a boundary: entry.
boundary_surfaces() {
    local file="${1:-$(boundary_contract_file)}"
    local yq; yq="$(_boundary_yq)"
    [ -n "$yq" ] && [ -f "$file" ] || return 0
    "$yq" e -r '.boundary // {} | keys | .[]' "$file" 2>/dev/null | grep -v '^null$' || true
}

# Echo provider_paths + consumer_paths globs for a surface (one per line).
boundary_paths() {
    local surface="$1"
    local file="${2:-$(boundary_contract_file)}"
    local yq; yq="$(_boundary_yq)"
    [ -n "$yq" ] && [ -f "$file" ] || return 0
    SURF="$surface" "$yq" e -r \
        '.boundary[strenv(SURF)] | (.provider_paths // []) + (.consumer_paths // []) | .[]' \
        "$file" 2>/dev/null | grep -v '^null$' || true
}

# Echo provider_symbols for a surface (one per line).
boundary_symbols() {
    local surface="$1"
    local file="${2:-$(boundary_contract_file)}"
    local yq; yq="$(_boundary_yq)"
    [ -n "$yq" ] && [ -f "$file" ] || return 0
    SURF="$surface" "$yq" e -r \
        '.boundary[strenv(SURF)].provider_symbols // [] | .[]' \
        "$file" 2>/dev/null | grep -v '^null$' || true
}

# Does <path> match a boundary glob? Echoes the matching surface name(s), one
# per line. `*` in a glob matches across `/` (bash [[ == ]] pattern matching, not
# pathname expansion), so a `.../<module>/**` glob matches any file beneath it;
# `**` is normalized to `*` for the same effect.
boundary_match_path() {
    local path="$1"
    local file="${2:-$(boundary_contract_file)}"
    local surface glob norm
    while IFS= read -r surface; do
        [ -n "$surface" ] || continue
        while IFS= read -r glob; do
            [ -n "$glob" ] || continue
            norm="${glob//\*\*/\*}"
            # shellcheck disable=SC2053
            if [[ "$path" == $norm ]]; then
                echo "$surface"
                break
            fi
        done < <(boundary_paths "$surface" "$file")
    done < <(boundary_surfaces "$file")
}

# --- diff computation (fail-safe closed) -------------------------------------

# Echo the changed files for <base>. Test/CI hook: NWP_IMPACT_FILES overrides
# git entirely. On any git failure, echoes nothing and returns 1 (the caller
# treats a non-zero return as UNCOMPUTABLE ⇒ boundary).
boundary_changed_files() {
    local base="$1"
    if [ -n "${NWP_IMPACT_FILES+x}" ]; then
        printf '%s\n' "$NWP_IMPACT_FILES" | grep -v '^$' || true
        return 0
    fi
    command -v git >/dev/null 2>&1 || return 1
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    # Resolve base; a base we can't resolve is uncomputable (fail-safe closed).
    git rev-parse --verify --quiet "$base" >/dev/null 2>&1 || return 1
    # Three-dot: changes on HEAD since the merge-base with <base>.
    git diff --name-only "${base}...HEAD" 2>/dev/null || return 1
}

# --- classification ----------------------------------------------------------

boundary_reset() {
    BOUNDARY_CLASS=""
    BOUNDARY_SURFACES=()
    BOUNDARY_FILES=()
    BOUNDARY_HITS=()
    BOUNDARY_UNCOMPUTABLE=0
    BOUNDARY_BASE=""
    BOUNDARY_REASON=""
}

# boundary_classify <base> [contract-file]
# Populates the BOUNDARY_* globals. Returns 0 always (classify, don't block).
boundary_classify() {
    local base="${1:-main}"
    local file="${2:-$(boundary_contract_file)}"
    boundary_reset
    BOUNDARY_BASE="$base"

    local files
    if ! files="$(boundary_changed_files "$base")"; then
        # UNCOMPUTABLE ⇒ fail-safe CLOSED.
        BOUNDARY_UNCOMPUTABLE=1
        BOUNDARY_CLASS="BOUNDARY"
        BOUNDARY_REASON="diff could not be computed against '${base}' — fail-safe closed"
        return 0
    fi

    local path surface seen
    local -A surfset=()
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        BOUNDARY_FILES+=("$path")
        while IFS= read -r surface; do
            [ -n "$surface" ] || continue
            BOUNDARY_HITS+=("${surface}|${path}")
            surfset["$surface"]=1
        done < <(boundary_match_path "$path" "$file")
    done <<< "$files"

    if [ "${#surfset[@]}" -gt 0 ]; then
        # Stable order: iterate the contract's surface order.
        while IFS= read -r surface; do
            [ -n "${surfset[$surface]:-}" ] && BOUNDARY_SURFACES+=("$surface")
        done < <(boundary_surfaces "$file")
        BOUNDARY_CLASS="BOUNDARY-TOUCHING"
        BOUNDARY_REASON="diff touches ${#BOUNDARY_SURFACES[@]} declared surface(s)"
    else
        BOUNDARY_CLASS="INTERNAL"
        BOUNDARY_REASON="no changed file matches a declared boundary path"
    fi
    return 0
}

# --- rendering (lib/impact.sh AFFECTED / NOT-AFFECTED idiom) ------------------

boundary_render() {
    echo ""
    echo -e "${BOLD}Intersite change-impact — pair ssc (nwc↔ssc), base ${BOUNDARY_BASE}${NC}"
    echo ""

    case "$BOUNDARY_CLASS" in
        BOUNDARY-TOUCHING|BOUNDARY)
            echo -e "${BOLD}${RED}CLASSIFICATION: ${BOUNDARY_CLASS}${NC}"
            echo -e "  ${BOUNDARY_REASON}"
            echo ""
            if [ "$BOUNDARY_UNCOMPUTABLE" -eq 1 ]; then
                echo -e "${BOLD}${YELLOW}⚠ FAIL-SAFE:${NC} treated as boundary-touching — run the cross-site checks."
                echo ""
            fi
            if [ "${#BOUNDARY_SURFACES[@]}" -gt 0 ]; then
                echo -e "${BOLD}${RED}BOUNDARY SURFACES AFFECTED:${NC}"
                local s hit
                for s in "${BOUNDARY_SURFACES[@]}"; do
                    echo -e "  ${RED}•${NC} ${BOLD}${s}${NC}"
                    for hit in "${BOUNDARY_HITS[@]}"; do
                        [ "${hit%%|*}" = "$s" ] && printf '      %s\n' "${hit#*|}"
                    done
                done
                echo ""
                echo -e "  ${YELLOW}→ coordinate the other side: cross-site contract-verify + CODEOWNERS review (Phase 2/3).${NC}"
                echo ""
            fi
            ;;
        INTERNAL)
            echo -e "${BOLD}${GREEN}CLASSIFICATION: INTERNAL${NC}"
            echo -e "  ${BOUNDARY_REASON} — ship freely (normal single-site CI)."
            echo ""
            echo -e "${BOLD}${GREEN}NOT AFFECTED:${NC}"
            echo -e "  • the nwc↔ssc boundary (no declared surface touched)"
            echo ""
            ;;
        *)
            echo -e "${YELLOW}CLASSIFICATION: (not computed)${NC}"
            echo ""
            ;;
    esac

    if [ "${#BOUNDARY_FILES[@]}" -gt 0 ]; then
        echo -e "  (${#BOUNDARY_FILES[@]} changed file(s) considered)"
        echo ""
    fi
}

# --- JSON (for CI) -----------------------------------------------------------

boundary_json() {
    local surfaces_json="" f="" first
    local s
    first=1
    for s in "${BOUNDARY_SURFACES[@]}"; do
        [ $first -eq 0 ] && surfaces_json+=","
        surfaces_json+="\"$s\""; first=0
    done
    first=1
    local p
    for p in "${BOUNDARY_FILES[@]}"; do
        [ $first -eq 0 ] && f+=","
        f+="\"$(printf '%s' "$p" | sed 's/\\/\\\\/g; s/"/\\"/g')\""; first=0
    done
    printf '{"classification":"%s","base":"%s","uncomputable":%s,"surfaces":[%s],"files":[%s],"reason":"%s"}\n' \
        "$BOUNDARY_CLASS" "$BOUNDARY_BASE" \
        "$([ "$BOUNDARY_UNCOMPUTABLE" -eq 1 ] && echo true || echo false)" \
        "$surfaces_json" "$f" \
        "$(printf '%s' "$BOUNDARY_REASON" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

# --- manifest-honesty check (Phase 1) ----------------------------------------
#
# For each surface symbol, grep production code (php/module/inc/install/sh/theme)
# under PROJECT_ROOT (minus vendor/.claude/build) for references. Every hit must
# be inside that surface's declared paths; a NON-COMMENT reference from outside
# is a violation ("a boundary symbol grew a new tentacle"). Comment/doc lines
# (starting with # * // /*) are ignored — they cannot couple code, and `tests`
# dirs are excluded (tests legitimately exercise a surface's public API). Echoes one
# violation per line and returns the count as exit status intent (caller checks
# output). If the profile tree is absent (nwp CI, where sites/* is gitignored),
# there are no references and the check is trivially clean.
#
# SCAN SCOPE: only the roots the boundary actually declares (the first two path
# components of each in-repo glob, e.g. `sites/nwc`, `lib`) plus `scripts` — NOT
# the whole monorepo. This keeps the check meaningful (catches a NEW edge from a
# sibling module or from lib/scripts tooling into a boundary symbol) while not
# tripping over unrelated SITE CHECKOUTS that each carry their own clone of the
# nwc profile (sites/nw1, sites/nwt, .agent-checkouts — clones, not couplings).

# Echo the set of existing scan roots (relative to PROJECT_ROOT), one per line.
boundary_scan_roots() {
    local file="${1:-$(boundary_contract_file)}"
    local surface glob head r
    local -A roots=()
    [ -d "${PROJECT_ROOT}/lib" ]     && roots["lib"]=1
    [ -d "${PROJECT_ROOT}/scripts" ] && roots["scripts"]=1
    while IFS= read -r surface; do
        [ -n "$surface" ] || continue
        while IFS= read -r glob; do
            [ -n "$glob" ] || continue
            head="${glob%%\**}"                 # portion before first '*'
            head="${head#/}"
            # First two path components (e.g. sites/nwc, lib, moodle).
            r="$(printf '%s\n' "$head" | cut -d/ -f1-2)"
            r="${r%/}"
            [ -n "$r" ] && [ -d "${PROJECT_ROOT}/${r}" ] && roots["$r"]=1
        done < <(boundary_paths "$surface" "$file")
    done < <(boundary_surfaces "$file")
    # Drop any root that is a descendant of another root (e.g. lib/sanitizers ⊂
    # lib) so we never grep — and thus never double-report — the same subtree.
    local a b subsumed
    for a in "${!roots[@]}"; do
        subsumed=0
        for b in "${!roots[@]}"; do
            [ "$a" = "$b" ] && continue
            case "$a" in "$b"/*) subsumed=1; break ;; esac
        done
        [ "$subsumed" -eq 0 ] && printf '%s\n' "$a"
    done
}

boundary_honesty_violations() {
    local file="${1:-$(boundary_contract_file)}"
    local surface symbol path line code norm inside glob rroot
    # Scan roots (absolute) derived from the contract; empty ⇒ nothing to scan.
    local -a scan_roots=()
    while IFS= read -r rroot; do
        [ -n "$rroot" ] && scan_roots+=("${PROJECT_ROOT}/${rroot}")
    done < <(boundary_scan_roots "$file")
    [ "${#scan_roots[@]}" -gt 0 ] || return 0

    while IFS= read -r surface; do
        [ -n "$surface" ] || continue
        # Declared paths for this surface (globs) — normalize ** → *.
        local -a globs=()
        while IFS= read -r glob; do
            [ -n "$glob" ] && globs+=("${glob//\*\*/\*}")
        done < <(boundary_paths "$surface" "$file")

        while IFS= read -r symbol; do
            [ -n "$symbol" ] || continue
            # grep production code only; prune vendor / worktrees / build.
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                path="${line%%:*}"
                code="${line#*:*:}"
                # Ignore comment/doc lines — they cannot form a code edge.
                if printf '%s' "$code" | grep -qE '^[[:space:]]*(#|\*|//|/\*|\*/)'; then
                    continue
                fi
                # Is this file inside one of the surface's declared paths?
                inside=0
                for glob in "${globs[@]}"; do
                    # shellcheck disable=SC2053
                    if [[ "$path" == $glob ]]; then inside=1; break; fi
                done
                [ "$inside" -eq 1 ] && continue
                echo "VIOLATION: surface '${surface}' symbol '${symbol}' referenced outside declared paths at ${line}"
            done < <(
                grep -rn --include='*.php' --include='*.module' --include='*.inc' \
                         --include='*.install' --include='*.sh' --include='*.theme' \
                         --exclude-dir=vendor --exclude-dir=.claude --exclude-dir=build \
                         --exclude-dir=node_modules --exclude-dir=tests \
                         --exclude-dir=.agent-checkouts --exclude-dir=.git \
                         -F "$symbol" "${scan_roots[@]}" 2>/dev/null \
                    | sed "s#^${PROJECT_ROOT}/##"
            )
        done < <(boundary_symbols "$surface" "$file")
    done < <(boundary_surfaces "$file")
}
