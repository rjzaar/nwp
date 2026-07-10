#!/bin/bash
set -euo pipefail
################################################################################
# scripts/commands/impact.sh — `pl impact` (P74 Phase 2)
#
# Classify a diff as INTERNAL vs BOUNDARY-TOUCHING against the nwc↔ssc pair
# contract's `boundary:` map. INTERNAL → ship freely (normal single-site CI).
# BOUNDARY-TOUCHING → coordinate the other side (cross-site contract-verify +
# CODEOWNERS review — Phase 2/3). FAIL-SAFE CLOSED: an uncomputable diff is
# treated as BOUNDARY.
#
# This command CLASSIFIES, it does not BLOCK — it always exits 0. (The
# version-bump gate + CODEOWNERS that actually block are a later phase.)
#
# Usage:
#   pl impact [--base=main] [--json] [--pair=ssc] [--honesty] [-h|--help]
#
#   --base=<ref>   compare HEAD against <ref> (default: main)
#   --json         emit a machine summary (for CI) instead of the human report
#   --pair=<id>    pair contract to use (default: ssc)
#   --honesty      run the manifest-honesty check instead of classifying a diff
#
# Test/CI hook: NWP_IMPACT_FILES="<newline-separated paths>" feeds a synthetic
# diff instead of calling git (see lib/boundary.sh).
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
export PROJECT_ROOT

# shellcheck source=/dev/null
[ -f "$PROJECT_ROOT/lib/ui.sh" ] && source "$PROJECT_ROOT/lib/ui.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/boundary.sh"

BASE="main"
JSON=0
PAIR="ssc"
HONESTY=0

for arg in "$@"; do
    case "$arg" in
        --base=*)  BASE="${arg#*=}" ;;
        --pair=*)  PAIR="${arg#*=}" ;;
        --json)    JSON=1 ;;
        --honesty) HONESTY=1 ;;
        -h|--help)
            sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "pl impact: unknown argument '$arg' (see --help)" >&2
            exit 0   # classify-only: never hard-fail the caller
            ;;
    esac
done

CONTRACT="$(boundary_contract_file "$PAIR")"

if [ "$HONESTY" -eq 1 ]; then
    viol="$(boundary_honesty_violations "$CONTRACT")"
    if [ -n "$viol" ]; then
        printf '%s\n' "$viol"
        echo ""
        echo "manifest-honesty: $(printf '%s\n' "$viol" | grep -c VIOLATION) violation(s)."
        # Advisory in Phase 2 — report, don't block.
    else
        echo "manifest-honesty: clean — no boundary symbol referenced outside its declared paths."
    fi
    exit 0
fi

boundary_classify "$BASE" "$CONTRACT"

if [ "$JSON" -eq 1 ]; then
    boundary_json
else
    boundary_render
fi

# Classify, don't block.
exit 0
