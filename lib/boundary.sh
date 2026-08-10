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

# Echo the pair contract file for a pair id. ops#326: there is NO engine
# default pair id — the engine ships no estate. The pair id is configuration:
# an explicit argument, or NWP_BOUNDARY_PAIR. With neither, echo nothing and
# return 1; every downstream reader then fails safe CLOSED (uncomputable),
# and `pl impact` refuses up front naming the knobs.
# Search order (same as lib/pair.sh): shipped pairs/ first, then the private
# overlay (NWP_PAIR_OVERLAY_DIR, default $PROJECT_ROOT/private/pairs). A pair
# declared in BOTH resolves to a path that cannot exist — fail closed, never
# a precedence rule.
boundary_contract_file() {
    local pair_id="${1:-${NWP_BOUNDARY_PAIR:-}}"
    [ -n "$pair_id" ] || return 1
    local dir="${NWP_PAIR_CONTRACT_DIR:-${PROJECT_ROOT}/pairs}"
    local odir="${NWP_PAIR_OVERLAY_DIR:-${PROJECT_ROOT}/private/pairs}"
    local shipped="${dir}/${pair_id}.pair-contract.yml"
    local overlay="${odir}/${pair_id}.pair-contract.yml"
    if [ -f "$shipped" ] && [ -f "$overlay" ] && [ "$shipped" != "$overlay" ]; then
        echo "${shipped}.DUPLICATE-DECLARATION"
        return 2
    fi
    if [ ! -f "$shipped" ] && [ -f "$overlay" ]; then
        echo "$overlay"
    else
        echo "$shipped"
    fi
}

_boundary_yq() { command -v yq 2>/dev/null || true; }

# Can the contract be READ at all? Classify must treat "no" as UNCOMPUTABLE
# (fail-safe closed): with no readable boundary map every surface list comes
# back empty, every path lookup misses, and — measured on the six straight red
# MR pipelines behind ops#165 — a genuinely boundary-touching diff silently
# classifies INTERNAL. "Can't read the boundary" must never render as "not on
# the boundary".
#
# ops#196 (2026-08-02): this used to check only `yq on PATH && file exists`,
# which left TWO fail-OPEN holes that the ops#165 note believed were closed.
# Measured on the real contract with the merged, now-BLOCKING job:
#   * a contract whose YAML is CORRUPT — every `yq e` in this library redirects
#     stderr to /dev/null and returns nothing, so zero surfaces ⇒ INTERNAL,
#     uncomputable:false, exit 0. Identical output to a genuinely internal diff.
#   * a contract that parses but declares `boundary: {}` — same result.
# Both are the pre-ops#165 defect wearing a different hat: the classifier
# reported "not on the boundary" when the truth was "I could not look". So the
# check now PARSES the file and requires at least one declared surface; only a
# contract that can actually answer questions counts as readable.
boundary_contract_readable() {
    local file="${1:-$(boundary_contract_file)}"
    local yq; yq="$(_boundary_yq)"
    [ -n "$yq" ] || return 1
    [ -f "$file" ] || return 1
    # Parse must SUCCEED (not just be silenced) …
    "$yq" e '.' "$file" >/dev/null 2>&1 || return 1
    # … and must yield a boundary map with at least one surface. A classifier
    # with zero surfaces cannot distinguish "internal" from "blind".
    local n
    n="$("$yq" e -r '.boundary // {} | length' "$file" 2>/dev/null)" || return 1
    case "$n" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$n" -gt 0 ]
}

# Why is it unreadable? A red gate that only says "unreadable" costs the next
# reader an investigation; each of these four causes has a different fix.
boundary_unreadable_why() {
    local file="${1:-$(boundary_contract_file)}"
    local yq; yq="$(_boundary_yq)"
    [ -n "$yq" ]   || { echo "yq is not on PATH — run scripts/ci/ensure-yq.sh"; return 0; }
    [ -f "$file" ] || { echo "'${file}' does not exist"; return 0; }
    "$yq" e '.' "$file" >/dev/null 2>&1 \
        || { echo "'${file}' is not parseable YAML"; return 0; }
    echo "'${file}' declares no boundary: surfaces — a classifier with zero surfaces cannot tell INTERNAL from blind"
}

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

# Echo provider_paths ONLY for a surface (one per line). The honesty check can
# only ever verify the PROVIDER side: consumer_paths point at `moodle/**` in
# nwp/ss-moodle-plugins, a different repo that is never checked out here.
boundary_provider_paths() {
    local surface="$1"
    local file="${2:-$(boundary_contract_file)}"
    local yq; yq="$(_boundary_yq)"
    [ -n "$yq" ] && [ -f "$file" ] || return 0
    SURF="$surface" "$yq" e -r \
        '.boundary[strenv(SURF)].provider_paths // [] | .[]' \
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

    # An unreadable contract makes every classification below vacuous (zero
    # surfaces ⇒ nothing ever matches ⇒ INTERNAL). Fail-safe CLOSED instead.
    if ! boundary_contract_readable "$file"; then
        BOUNDARY_UNCOMPUTABLE=1
        BOUNDARY_CLASS="BOUNDARY"
        BOUNDARY_REASON="pair contract unreadable ($(boundary_unreadable_why "$file")) — fail-safe closed"
        return 0
    fi

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
# SCAN SCOPE: only the roots the boundary actually declares plus `scripts` —
# NOT the whole monorepo. This keeps the check meaningful (catches a NEW edge
# from a sibling module or from lib/scripts tooling into a boundary symbol)
# while not tripping over unrelated SITE CHECKOUTS that each carry their own
# clone of the nwc profile (sites/nw1, sites/nwt, .agent-checkouts — clones,
# not couplings).
#
# ROOT DEPTH (fixed in item 7). The root used to be the first TWO path
# components of each glob, so `sites/nwc/dev/…/nwc_copyright/**` yielded the
# root `sites/nwc` — which also contains `sites/nwc/stg`, the ENVIRONMENT TWIN
# of the very tree being declared (F23 `sites/<site>/{dev,stg}` layout). Every
# provider symbol therefore appeared once in `dev` (inside its declared path,
# fine) and again in the byte-identical `stg` copy (outside it, "VIOLATION").
# Measured 2026-07-26: **all 11 reported violations were the stg twin and not
# one was a real coupling** — the twin files `diff` clean against their dev
# originals. That is the noisy-detector failure mode: a check that cries wolf
# 11 times out of 11 teaches everyone to ignore its output, which is how the
# 12th — a real one — gets ignored too.
#
# So: under `sites/`, the root is `sites/<site>/<env>` (THREE components) — the
# environment checkout that actually owns the declared code. A sibling module
# inside that same checkout is still scanned, which is the edge the check is
# for; the twin environment is a copy and is not.
boundary_scan_root_depth() {
    # First component decides: site checkouts are site/env-scoped, everything
    # else (lib, scripts, moodle, contracts) is two-deep at most.
    case "$1" in
        sites) echo 3 ;;
        *)     echo 2 ;;
    esac
}

# Echo the set of existing scan roots (relative to PROJECT_ROOT), one per line.
boundary_scan_roots() {
    local file="${1:-$(boundary_contract_file)}"
    local surface glob head r depth
    local -A roots=()
    [ -d "${PROJECT_ROOT}/lib" ]     && roots["lib"]=1
    [ -d "${PROJECT_ROOT}/scripts" ] && roots["scripts"]=1
    while IFS= read -r surface; do
        [ -n "$surface" ] || continue
        while IFS= read -r glob; do
            [ -n "$glob" ] || continue
            head="${glob%%\**}"                 # portion before first '*'
            head="${head#/}"
            depth="$(boundary_scan_root_depth "${head%%/*}")"
            r="$(printf '%s\n' "$head" | cut -d/ -f1-"$depth")"
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

# --- CORPUS HONESTY: "cannot verify" is not "clean" (item 7) ------------------
#
# THE DEFECT THIS FIXES. boundary_honesty_violations greps for provider symbols
# under the roots the contract declares. In nwp CI `sites/*` is gitignored, so
# the nwc profile — where 10 of the 11 provider symbols live — is simply ABSENT.
# Zero files scanned ⇒ zero hits ⇒ zero violations ⇒ "manifest is HONEST".
# The previous version of the bats suite even documented this in a comment and
# asserted clean anyway. Measured on 2026-07-26: the identical check reports
# **0 violations in CI and 11 on a dev workstation with the profile present**.
# A gate whose green light means "I could not look" is worse than no gate.
#
# So: presence of the corpus is asserted SEPARATELY from the absence of
# violations, and a surface whose provider tree is not on disk is reported as
# UNVERIFIABLE, never folded into "clean".

# boundary_surface_present <surface> [file] — 0 if at least one provider file
# for this surface actually exists on disk.
boundary_surface_present() {
    local surface="$1"
    local file="${2:-$(boundary_contract_file)}"
    local glob head
    while IFS= read -r glob; do
        [ -n "$glob" ] || continue
        head="${glob%%\**}"          # portion before the first '*'
        head="${head%/}"
        head="${head#/}"
        [ -n "$head" ] || continue
        [ -f "${PROJECT_ROOT}/${head}" ] && return 0
        if [ -d "${PROJECT_ROOT}/${head}" ]; then
            find "${PROJECT_ROOT}/${head}" -type f \
                 \( -name '*.php' -o -name '*.module' -o -name '*.inc' \
                    -o -name '*.install' -o -name '*.sh' -o -name '*.theme' \) \
                 -print -quit 2>/dev/null | grep -q . && return 0
        fi
    done < <(boundary_provider_paths "$surface" "$file")
    return 1
}

# boundary_honesty_check [file] — the gate. Echoes UNVERIFIABLE/VIOLATION lines
# plus a one-line verdict. Exit status:
#   0  VERIFIED-CLEAN   every surface's provider tree present, no leaks
#   1  VIOLATIONS       at least one boundary symbol leaked outside its paths
#   2  CANNOT-VERIFY    at least one surface's provider tree is not on disk
# 1 outranks 2: a real leak is worse news than a missing corpus.
boundary_honesty_check() {
    local file="${1:-$(boundary_contract_file)}"
    local surface present=0 missing=0 viol

    # Name the real blocker. Before ops#165, a missing yq fell through to the
    # generic "declares no boundary surfaces at all" below — which reads as a
    # CONTRACT problem and sent the first investigation down the wrong path
    # (the committed contract declares 7 surfaces; the runner just had no yq).
    if ! boundary_contract_readable "$file"; then
        echo "CANNOT-VERIFY: pair contract unreadable ($(boundary_unreadable_why "$file")) — fix that before believing anything else this check says."
        return 2
    fi

    while IFS= read -r surface; do
        [ -n "$surface" ] || continue
        if boundary_surface_present "$surface" "$file"; then
            present=$((present + 1))
        else
            missing=$((missing + 1))
            echo "UNVERIFIABLE: surface '${surface}' — no provider file on disk (declared: $(boundary_provider_paths "$surface" "$file" | tr '\n' ' '))"
        fi
    done < <(boundary_surfaces "$file")

    if [ "$((present + missing))" -eq 0 ]; then
        echo "CANNOT-VERIFY: the pair contract declares no boundary surfaces at all."
        return 2
    fi

    viol="$(boundary_honesty_violations "$file")"
    [ -n "$viol" ] && printf '%s\n' "$viol"

    if [ -n "$viol" ]; then
        echo "manifest-honesty: VIOLATIONS — $(printf '%s\n' "$viol" | grep -c VIOLATION) symbol(s) referenced outside their declared paths (${present}/$((present + missing)) surfaces verifiable)."
        return 1
    fi
    if [ "$missing" -gt 0 ]; then
        echo "manifest-honesty: CANNOT VERIFY — ${missing} of $((present + missing)) surface(s) have no provider tree on disk. This is NOT a clean result: the check found nothing because it could not look. Run it where sites/nwc is checked out."
        return 2
    fi
    echo "manifest-honesty: VERIFIED CLEAN — all ${present} surface(s) scanned, no boundary symbol referenced outside its declared paths."
    return 0
}
