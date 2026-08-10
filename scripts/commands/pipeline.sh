#!/usr/bin/env bash
set -uo pipefail
################################################################################
# scripts/commands/pipeline.sh — run a site's project-specific data pipeline.
#
# WHY THIS VERB EXISTS (ops#326 Phase 1 tranche 3)
# ------------------------------------------------------------------------------
# The engine used to ship a verb NAMED after one private site's scraper, which
# hardcoded that site's directory:
#
#     MT_DIR="$PROJECT_ROOT/<private-site>"
#     exec "$MT_DIR/<verb>.sh" "$@"
#
# Two defects. (1) Privacy: nwp/nwp is the generic engine and is publicly
# mirrored — a private instance's name is a disclosure (operator ruling
# 2026-08-09). (2) It had been DEAD since the F23 layout change: per-site
# pipelines live at sites/<site>/dev/pipeline/, so the hardcoded path did not
# exist and every invocation exited 127.
#
# `pl pipeline` names the FUNCTION instead of a site, takes the site as an
# argument, and resolves the entrypoint from that site's own tree. Pipelines
# themselves stay where they belong — inside the site, which is its own repo.
#
# LAYOUT CONTRACT
#   sites/<site>/dev/pipeline/<flow>.sh            the pipeline
#   sites/<site>/dev/pipeline/run-<flow>.sh        optional wrapper (preferred —
#                                                  it carries the venv/PYTHONPATH)
#   sites/<site>/dev/pipeline/setup-<flow>.sh      optional, --setup
#   sites/<site>/dev/pipeline/deploy-<flow>.sh     optional, --deploy
#   sites/<site>/pipeline/…                        pre-F23 layout, still honoured
#
# FAIL-CLOSED: an unknown site, a site with no pipeline, an ambiguous entrypoint
# and an unresolvable --find all REFUSE and name what they could not settle.
# None of them is allowed to become a silent no-op — the previous verb's exit
# 127 was invisible for months precisely because nothing asserted on it.
#
# USAGE
#   pl pipeline list
#   pl pipeline <site> [--entrypoint=<flow>] [--setup|--deploy] [args…]
#   pl pipeline --find=<flow> [--dry] [args…]
#   pl pipeline <site> --dry            resolve and print, run nothing
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROOT="${NWP_DIR:-$PROJECT_ROOT}"

# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/ui.sh" 2>/dev/null || {
    print_error()   { printf 'ERROR: %s\n' "$*" >&2; }
    print_info()    { printf '%s\n' "$*"; }
    print_success() { printf '%s\n' "$*"; }
}

die() { print_error "$*"; exit 2; }

usage() {
    cat <<'EOF'
pl pipeline — run a site's project-specific data pipeline

USAGE
    pl pipeline list
    pl pipeline <site> [--entrypoint=<flow>] [--setup|--deploy] [--dry] [args…]
    pl pipeline --find=<flow> [--dry] [args…]

WHERE PIPELINES LIVE
    sites/<site>/dev/pipeline/<flow>.sh          the pipeline itself
    sites/<site>/dev/pipeline/run-<flow>.sh      preferred wrapper, if present
    sites/<site>/dev/pipeline/setup-<flow>.sh    --setup
    sites/<site>/dev/pipeline/deploy-<flow>.sh   --deploy

    A pipeline is site data, not engine code: it is versioned in the site's own
    repository. The engine only knows how to find and run one.

OPTIONS
    --entrypoint=<flow>  choose one when a site has several
    --setup / --deploy   run the sibling setup-/deploy- script instead
    --find=<flow>        resolve the site that owns <flow> (no site argument)
    --dry                resolve and print; run nothing
    -h, --help           this help

Everything after the first unrecognised argument is forwarded to the pipeline
verbatim.
EOF
}

# _pipeline_dir <site> — echo the site's pipeline dir, or nothing.
_pipeline_dir() {
    local site="$1" d
    for d in "$ROOT/sites/$site/dev/pipeline" "$ROOT/sites/$site/pipeline"; do
        [ -d "$d" ] && { printf '%s' "$d"; return 0; }
    done
    return 1
}

# _sites_with_pipelines — echo site names that have a pipeline dir.
_sites_with_pipelines() {
    local d site
    [ -d "$ROOT/sites" ] || return 0
    for d in "$ROOT"/sites/*/; do
        site="$(basename "$d")"
        _pipeline_dir "$site" >/dev/null 2>&1 && printf '%s\n' "$site"
    done
}

# _flows <dir> — echo the base flow names in <dir>: every *.sh that is not a
# run-/setup-/deploy- sibling. A dir holding ONLY run-*.sh still yields its
# flow, so a site may ship the wrapper alone.
_flows() {
    local dir="$1" f b had_base=0
    for f in "$dir"/*.sh; do
        [ -f "$f" ] || continue
        b="$(basename "$f" .sh)"
        case "$b" in run-*|setup-*|deploy-*) continue ;; esac
        printf '%s\n' "$b"; had_base=1
    done
    [ "$had_base" -eq 1 ] && return 0
    for f in "$dir"/run-*.sh; do
        [ -f "$f" ] || continue
        b="$(basename "$f" .sh)"
        printf '%s\n' "${b#run-}"
    done
}

# _resolve_script <dir> <flow> <kind> — echo the script to exec.
#   kind: run | setup | deploy
_resolve_script() {
    local dir="$1" flow="$2" kind="$3"
    case "$kind" in
        setup)  [ -f "$dir/setup-$flow.sh" ]  && { printf '%s' "$dir/setup-$flow.sh";  return 0; } ;;
        deploy) [ -f "$dir/deploy-$flow.sh" ] && { printf '%s' "$dir/deploy-$flow.sh"; return 0; } ;;
        *)
            [ -f "$dir/run-$flow.sh" ] && { printf '%s' "$dir/run-$flow.sh"; return 0; }
            [ -f "$dir/$flow.sh" ]     && { printf '%s' "$dir/$flow.sh";     return 0; }
            ;;
    esac
    return 1
}

cmd_list() {
    local -a found=()
    while IFS= read -r s; do [ -n "$s" ] && found+=("$s"); done < <(_sites_with_pipelines)
    if [ "${#found[@]}" -eq 0 ]; then
        print_info "no site under $ROOT/sites has a dev/pipeline/ directory"
        return 0
    fi
    local s dir
    for s in "${found[@]}"; do
        dir="$(_pipeline_dir "$s")"
        printf '  %-12s %s\n' "$s" "$(_flows "$dir" | paste -sd, - )"
    done
}

# --find: which site owns <flow>?
cmd_find() {
    local flow="$1"
    local -a owners=()
    local s dir
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        dir="$(_pipeline_dir "$s")" || continue
        if [ -f "$dir/$flow.sh" ] || [ -f "$dir/run-$flow.sh" ]; then owners+=("$s"); fi
    done < <(_sites_with_pipelines)

    if [ "${#owners[@]}" -eq 0 ]; then
        print_error "no site owns a pipeline entrypoint '$flow'"
        print_info  "  looked under $ROOT/sites/*/dev/pipeline/ for ${flow}.sh or run-${flow}.sh"
        print_info  "  a pipeline lives in the site's own repository — check that site out first"
        exit 1
    fi
    if [ "${#owners[@]}" -gt 1 ]; then
        print_error "'$flow' is owned by more than one site: ${owners[*]}"
        print_info  "  name the site instead:  pl pipeline <site> --entrypoint=$flow"
        exit 1
    fi
    printf '%s' "${owners[0]}"
}

main() {
    local site="" flow="" kind="run" dry=0 find_flow=""
    local -a passthru=()

    [ $# -gt 0 ] || { usage; print_error "no site given — pl pipeline needs the site whose pipeline to run"; exit 2; }

    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
        list|--list) shift; cmd_list; exit 0 ;;
    esac

    # Leading options; the first unrecognised argument ends option parsing and
    # everything from there is the pipeline's own argv.
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)        usage; exit 0 ;;
            --entrypoint=*)   flow="${1#*=}"; shift ;;
            --entrypoint)     flow="${2:-}"; shift 2 ;;
            --find=*)         find_flow="${1#*=}"; shift ;;
            --find)           find_flow="${2:-}"; shift 2 ;;
            --setup)          kind="setup"; shift ;;
            --deploy)         kind="deploy"; shift ;;
            --dry|--dry-run)  dry=1; shift ;;
            -*)               break ;;
            *)
                if [ -z "$site" ]; then site="$1"; shift; else break; fi
                ;;
        esac
    done
    passthru=("$@")

    if [ -n "$find_flow" ]; then
        [ -z "$site" ] || die "give a site OR --find, not both"
        site="$(cmd_find "$find_flow")" || exit 1
        [ -n "$flow" ] || flow="$find_flow"
        print_info "pipeline '$find_flow' → site '$site'"
    fi

    [ -n "$site" ] || { usage; print_error "no site given — pl pipeline needs the site whose pipeline to run"; exit 2; }

    if [ ! -d "$ROOT/sites/$site" ]; then
        print_error "unknown site '$site' — no $ROOT/sites/$site"
        exit 1
    fi

    local dir
    if ! dir="$(_pipeline_dir "$site")"; then
        print_error "site '$site' has no pipeline directory"
        print_info  "  expected $ROOT/sites/$site/dev/pipeline/"
        exit 1
    fi

    if [ -z "$flow" ]; then
        local -a flows=()
        while IFS= read -r f; do [ -n "$f" ] && flows+=("$f"); done < <(_flows "$dir")
        if [ "${#flows[@]}" -eq 0 ]; then
            print_error "site '$site' has a pipeline directory but no *.sh entrypoint in it"
            print_info  "  $dir"
            exit 1
        fi
        if [ "${#flows[@]}" -gt 1 ]; then
            print_error "site '$site' has more than one pipeline entrypoint: ${flows[*]}"
            print_info  "  choose one:  pl pipeline $site --entrypoint=${flows[0]}"
            exit 1
        fi
        flow="${flows[0]}"
    fi

    local script
    if ! script="$(_resolve_script "$dir" "$flow" "$kind")"; then
        print_error "site '$site' has no ${kind} script for pipeline '$flow'"
        print_info  "  looked for $(case "$kind" in setup) echo "setup-$flow.sh";; deploy) echo "deploy-$flow.sh";; *) echo "run-$flow.sh / $flow.sh";; esac) in $dir"
        exit 1
    fi

    if [ "$dry" -eq 1 ]; then
        print_success "would run: $script ${passthru[*]:-}"
        exit 0
    fi

    [ -x "$script" ] || die "pipeline entrypoint is not executable: $script"
    exec "$script" ${passthru[@]+"${passthru[@]}"}
}

main "$@"
