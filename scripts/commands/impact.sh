#!/bin/bash
set -euo pipefail
################################################################################
# scripts/commands/impact.sh — `pl impact` (P74 Phase 2)
#
# Classify a diff as INTERNAL vs BOUNDARY-TOUCHING against a pair contract's
# `boundary:` map. INTERNAL → ship freely (normal single-site CI).
# BOUNDARY-TOUCHING → coordinate the other side (cross-site contract-verify +
# CODEOWNERS review — Phase 2/3). FAIL-SAFE CLOSED: an uncomputable diff is
# treated as BOUNDARY.
#
# CLASSIFICATION CLASSIFIES, it does not BLOCK — the diff modes always exit 0.
# (The version-bump gate + CODEOWNERS that actually block are a later phase.)
# `--honesty` is DIFFERENT: it is a gate and it reports through its exit status
# (see below), because an honesty check that always exits 0 cannot fail.
#
# Usage:
#   pl impact [--base=main] [--json] [--pair=<id>] [--honesty] [--advisory]
#             [--fail-uncomputable] [-h]
#
#   --base=<ref>   compare HEAD against <ref> (default: main)
#   --json         emit a machine summary (for CI) instead of the human report
#   --pair=<id>    pair contract to use (REQUIRED unless NWP_BOUNDARY_PAIR is set —
#                  the engine ships no default pair; ops#326)
#   --honesty      run the manifest-honesty check instead of classifying a diff
#   --advisory     with --honesty: report but always exit 0 (legacy behaviour)
#   --fail-uncomputable
#                  exit 2 when the classification is FAIL-SAFE-CLOSED (diff or
#                  contract unreadable). For CI: a runner that cannot classify
#                  must show red for THAT — "treated as boundary" is the safe
#                  verdict for a human, but in a pipeline it means the job is
#                  misprovisioned (no yq, unfetched base) and should say so
#                  instead of stamping every MR with the same non-answer.
#
# --honesty EXIT STATUS (item 7 — "cannot verify" is not "clean"):
#   0  verified clean   every surface's provider tree was on disk and scanned
#   1  violations       a boundary symbol is referenced outside its declared paths
#   2  CANNOT VERIFY    a surface's provider tree is absent (e.g. sites/* is
#                       gitignored in CI) — the check found nothing because it
#                       could not look, which must never render as green.
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
# ops#326: NO engine default pair — the engine ships no estate. The pair id
# comes from --pair, or NWP_BOUNDARY_PAIR (estate config / CI job variable).
PAIR="${NWP_BOUNDARY_PAIR:-}"
HONESTY=0
ADVISORY=0
FAIL_UNCOMPUTABLE=0

for arg in "$@"; do
    case "$arg" in
        --base=*)   BASE="${arg#*=}" ;;
        --pair=*)   PAIR="${arg#*=}" ;;
        --json)     JSON=1 ;;
        --honesty)  HONESTY=1 ;;
        --advisory) ADVISORY=1 ;;
        --fail-uncomputable) FAIL_UNCOMPUTABLE=1 ;;
        -h|--help)
            sed -n '3,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "pl impact: unknown argument '$arg' (see --help)" >&2
            exit 0   # classify-only: never hard-fail the caller
            ;;
    esac
done

if [ -z "$PAIR" ]; then
    echo "pl impact: no pair id — the engine ships no default pair (ops#326)." >&2
    echo "  Pass --pair=<id> or set NWP_BOUNDARY_PAIR. The shipped sample pair is 'ssd';" >&2
    echo "  a real estate declares its own pair contract in the private overlay (private/pairs/)." >&2
    exit 2
fi

CONTRACT="$(boundary_contract_file "$PAIR")" || true

if [ "$HONESTY" -eq 1 ]; then
    # `set -e` is on; boundary_honesty_check returns 1/2 by design.
    rc=0
    boundary_honesty_check "$CONTRACT" || rc=$?
    if [ "$ADVISORY" -eq 1 ] && [ "$rc" -ne 0 ]; then
        echo "(--advisory: reporting only, exiting 0)"
        exit 0
    fi
    exit "$rc"
fi

boundary_classify "$BASE" "$CONTRACT"

if [ "$JSON" -eq 1 ]; then
    boundary_json
else
    boundary_render
fi

# --fail-uncomputable (CI): an uncomputable classification is a provisioning
# defect on THIS run, not information about the diff — surface it as red.
if [ "$FAIL_UNCOMPUTABLE" -eq 1 ] && [ "${BOUNDARY_UNCOMPUTABLE:-0}" -eq 1 ]; then
    echo "pl impact: classification was FAIL-SAFE-CLOSED (${BOUNDARY_REASON}) — refusing to report it as a verdict (--fail-uncomputable)" >&2
    exit 2
fi

# Classify, don't block.
exit 0
