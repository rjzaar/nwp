#!/usr/bin/env bash
set -uo pipefail
################################################################################
# scripts/commands/mass-times.sh — DEPRECATED shim for `pl pipeline`.
#
# RETIRED 2026-08-10 (ops#326 Phase 1 tranche 3). This verb was a per-site data
# pipeline wearing an engine verb's clothes: it hardcoded ONE private site's
# directory in the publicly-mirrored engine tree —
#
#     MT_DIR="$PROJECT_ROOT/<private-site>"
#     exec "$MT_DIR/mass-times.sh" "$@"
#
# — and that path had been dead since the F23 layout change, so every
# invocation exited 127 with a bare "No such file or directory". Nothing
# asserted on it, so nobody noticed.
#
# The replacement is `pl pipeline`, which names the FUNCTION (run a site's
# project-specific data pipeline), takes the site as an argument, and resolves
# the entrypoint inside that site's own repository.
#
#     pl pipeline list                     which checked-out sites have one
#     pl pipeline <site> [args…]           run it
#     pl pipeline <site> --setup|--deploy  the sibling setup-/deploy- script
#
# This shim keeps the old invocation working — including its old flag spellings
# — by asking `pl pipeline --find` which checked-out site owns an entrypoint of
# this name. It therefore names no site itself, which is the whole point.
#
# It will be removed once the deprecation window closes; use `pl pipeline`.
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FLOW="$(basename "${BASH_SOURCE[0]}" .sh)"

notice() {
    printf '\n  DEPRECATED: `pl %s` is retired (ops#326).\n' "$FLOW" >&2
    printf '  Use `pl pipeline <site>` — the generic verb. Try `pl pipeline list`.\n' >&2
    printf '  Forwarding: pl pipeline --find=%s …\n\n' "$FLOW" >&2
}

case "${1:-}" in
    -h|--help)
        notice
        exec "$PROJECT_ROOT/pl" pipeline --help
        ;;
esac

notice

# Translate the retired flag spellings onto the generic verb. Anything else is
# forwarded verbatim.
declare -a fwd=()
case "${1:-}" in
    --setup)            shift; fwd=(--setup "$@") ;;
    --setup-check)      shift; fwd=(--setup --check "$@") ;;
    --setup-uninstall)  shift; fwd=(--setup --uninstall "$@") ;;
    --deploy)           shift; fwd=(--deploy "$@") ;;
    --deploy-conf)      shift; fwd=(--deploy --conf-only "$@") ;;
    *)                  fwd=("$@") ;;
esac

exec "$PROJECT_ROOT/pl" pipeline --find="$FLOW" ${fwd[@]+"${fwd[@]}"}
