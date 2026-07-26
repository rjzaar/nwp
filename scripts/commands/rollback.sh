#!/bin/bash
set -euo pipefail

################################################################################
# NWP Deployment Rollback
#
# Manages deployment rollback points and recovery
#
# Usage: pl rollback <command> [options] <sitename>
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/rollback.sh"
# deploy-gate.sh: hardware+signature gate on prod-writes (ADR-0028); no-op unless
# configured (ver) — the AI test tier (A14) is unaffected. lib/rollback.sh calls
# deploy_gate_require before executing a REMOTE (live/prod host) rollback;
# sourced explicitly here too so the dependency is visible at the command level.
source "$PROJECT_ROOT/lib/deploy-gate.sh"
# moodle-deploy.sh: provides moodle_remote_rollback_execute, the restore arm for
# type:"moodle-remote" entries (written by pl moodle deploy). Without this the
# generic verb can LIST a Moodle recovery point but not execute it — which is
# exactly the defect this file's dispatch fix addresses. Pure function
# definitions; no source-time side effects.
source "$PROJECT_ROOT/lib/moodle-deploy.sh"

show_help() {
    cat << EOF
${BOLD}NWP Deployment Rollback${NC}

${BOLD}USAGE:${NC}
    pl rollback <command> [options] <sitename>

${BOLD}COMMANDS:${NC}
    list [sitename]                          List available rollback points
    execute <sitename> [env] [--dry-run]     Rollback to last deployment
                                             (env defaults to prod; --dry-run
                                              prints what would happen)
    verify <sitename>                        Verify site after rollback
    cleanup [--keep=N]                       Remove old rollback points
    backfill <sitename>                      Scan the live host for existing
                                             snapshots and register them
    registry check                           Validate the consolidation-arc
                                             rollback registry: every named
                                             artifact must resolve to a real
                                             file and be integrity-verifiable
    register --cp=CPn --what=... [--artifact=PATH] [--restore=CMD]
                                             The only sanctioned writer of the
                                             rollback registry. Refuses an
                                             artifact that does not resolve;
                                             writes a .sha256 sidecar if absent.

${BOLD}OPTIONS:${NC}
    --env <environment>          Environment (prod, stage, live)
    --keep <count>               Number of rollback points to keep (default: 5)
    --dry-run                    Print commands without executing them

${BOLD}EXAMPLES:${NC}
    pl rollback list                          # Show all rollback points
    pl rollback list mysite                   # Show rollback points for mysite
    pl rollback execute mysite prod --dry-run # Preview what a rollback would do
    pl rollback execute mysite prod           # Rollback mysite production (prompts)
    pl rollback backfill nwc                  # Register snapshots already on live
    pl rollback cleanup --keep=3              # Keep only last 3 rollback points

${BOLD}AUTOMATIC ROLLBACK:${NC}
    Rollback points are automatically created before each deployment by
    pl stg2live (via live_host_snapshot → rollback_record_remote). Remote
    points point at \`~/nwp-snapshot-<site>-<dbs|nginx>-<ts>\` on the live
    host. Local points (legacy) reference paths inside this checkout.

EOF
}

cmd_list() {
    local sitename="${1:-}"
    rollback_list "$sitename"
}

cmd_execute() {
    local sitename="" environment="" extra="" a

    # Accept the flags before OR after the subcommand, and in any order
    # relative to the positionals. $ENV comes from the global option parse
    # below; previously it was parsed and then referenced NOWHERE, so the
    # documented `--env` flag was dead code and the only working form was an
    # undocumented positional.
    [ -n "${ENV:-}" ] && environment="$ENV"

    for a in "$@"; do
        case "$a" in
            --dry-run)  extra="--dry-run" ;;
            --env=*)    environment="${a#*=}" ;;
            -*)         print_error "Unknown option: $a"; exit 1 ;;
            *)
                if   [ -z "$sitename" ];    then sitename="$a"
                elif [ -z "$environment" ]; then environment="$a"
                else print_error "Unexpected argument: $a"; exit 1
                fi
                ;;
        esac
    done

    if [ -z "$sitename" ]; then
        print_error "Sitename required"
        exit 1
    fi

    # Dry-run delegates straight to rollback_execute (skips verify step).
    if [ "$extra" = "--dry-run" ]; then
        rollback_execute "$sitename" "$environment" "--dry-run"
    else
        rollback_quick "$sitename" "$environment"
    fi
}

cmd_backfill() {
    local sitename="$1"

    if [ -z "$sitename" ]; then
        print_error "Sitename required"
        exit 1
    fi

    rollback_backfill_remote "$sitename"
}

cmd_verify() {
    local sitename="$1"

    if [ -z "$sitename" ]; then
        print_error "Sitename required"
        exit 1
    fi

    rollback_verify "$sitename"
}

################################################################################
# Rollback REGISTRY (docs/reports/consolidation-arc-2026-07/rollback-registry.md)
#
# The registry is the human-facing "how do I undo checkpoint N" ledger. It was
# written by hand and never validated, so rows accumulated four incompatible
# path conventions (repo-relative, registry-dir-relative, absolute box paths,
# and bare filenames) and at least one row recorded a sha256 that no longer
# matched the artifact it named. A recovery ledger nobody checks is a recovery
# ledger that is wrong precisely when it is needed.
#
# `pl rollback registry check` is the mechanical check; `pl rollback register`
# is the only sanctioned writer.
################################################################################

_registry_file() {
    printf '%s' "${NWP_ROLLBACK_REGISTRY:-${PROJECT_ROOT}/docs/reports/consolidation-arc-2026-07/rollback-registry.md}"
}

# Resolve a registry-named artifact to a real path, trying the conventions the
# file actually uses. Echoes the resolved path, or nothing.
_registry_resolve() {
    local p="$1"
    local reg_dir; reg_dir="$(dirname "$(_registry_file)")"
    local root="$PROJECT_ROOT"
    # Site artifacts live in the main checkout (sites/ is gitignored, so a
    # worktree never has them).
    local main_root; main_root="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    [ -n "$main_root" ] && main_root="$(dirname "$main_root")"

    local c
    for c in "$p" "${root}/${p}" "${reg_dir}/${p}" "${main_root:+${main_root}/${p}}"; do
        [ -n "$c" ] || continue
        [ -e "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

cmd_registry_check() {
    local reg; reg="$(_registry_file)"
    if [ ! -f "$reg" ]; then
        print_error "Registry not found: $reg"
        return 1
    fi

    print_header "Rollback registry check"
    print_info "File: $reg"
    echo ""

    local problems=0 rows=0
    local line row_id artifacts a resolved sha_in_row actual sidecar

    while IFS= read -r line; do
        # Only checkpoint rows.
        case "$line" in
            \|\ CP*) ;;
            *) continue ;;
        esac
        rows=$((rows + 1))
        row_id=$(printf '%s' "$line" | awk -F'|' '{print $2}' | tr -d ' ')

        # Backticked tokens that look like artifact files, taken ONLY from the
        # "Artifact(s) + sha" column (field 5). Scanning the whole row also
        # picked up filenames quoted inside the Restore-command column, where a
        # bare name is perfectly correct (`git clone foo.bundle`), producing
        # noise that would train people to ignore this check.
        local art_col
        art_col=$(printf '%s' "$line" | awk -F'|' '{print $5}')
        artifacts=$(printf '%s' "$art_col" \
            | grep -oE '`[^`]+`' | tr -d '`' \
            | grep -oE '[A-Za-z0-9._/~-]+\.(tar\.gz|sql\.gz|bundle|conf|patch)' \
            | sort -u || true)

        [ -z "$artifacts" ] && continue

        while IFS= read -r a; do
            [ -n "$a" ] || continue

            # Bare filename with no directory: unresolvable by construction.
            if [ "$a" = "$(basename "$a")" ]; then
                print_status "WARN" "${row_id}: '${a}' is a bare filename — ambiguous, no directory given"
                problems=$((problems + 1))
                continue
            fi

            # Try to resolve FIRST. An absolute path that exists locally is a
            # local artifact and gets the full integrity check; only a path we
            # genuinely cannot reach is treated as off-host. Checking
            # "starts with /" before attempting resolution let a local file be
            # waved through on the strength of a sha nobody compared.
            if ! resolved="$(_registry_resolve "$a")"; then
                case "$a" in
                    /*)
                        # Off-repo host path (box:/var/…, /etc/…). Unreachable
                        # from here, so it MUST carry a recorded sha instead.
                        if printf '%s' "$line" | grep -qE 'sha *`?[0-9a-f]{8}'; then
                            print_status "OK" "${row_id}: off-host '${a}' carries a recorded sha"
                        else
                            print_status "WARN" "${row_id}: off-host '${a}' has NO recorded sha — unverifiable"
                            problems=$((problems + 1))
                        fi
                        continue
                        ;;
                esac
                print_status "FAIL" "${row_id}: artifact NOT FOUND: ${a}"
                problems=$((problems + 1))
                continue
            fi

            # Integrity: prefer the artifact's own .sha256 sidecar.
            sidecar="${resolved}.sha256"
            if [ -f "$sidecar" ]; then
                actual=$(sha256sum "$resolved" 2>/dev/null | awk '{print $1}')
                local want; want=$(awk '{print $1}' "$sidecar" 2>/dev/null | head -1)
                if [ "$actual" != "$want" ]; then
                    print_status "FAIL" "${row_id}: ${a} does NOT match its .sha256 sidecar"
                    problems=$((problems + 1))
                    continue
                fi
                # Cross-check any sha quoted in the row itself.
                sha_in_row=$(printf '%s' "$line" | grep -oE 'sha256 `[0-9a-f]{8}|sha `[0-9a-f]{8}|`[0-9a-f]{8}…' | grep -oE '[0-9a-f]{8}' | head -1 || true)
                if [ -n "$sha_in_row" ] && [ "${actual:0:8}" != "$sha_in_row" ]; then
                    print_status "FAIL" "${row_id}: registry row quotes sha ${sha_in_row}… but the artifact is ${actual:0:8}… (row is STALE)"
                    problems=$((problems + 1))
                    continue
                fi
                print_status "OK" "${row_id}: ${a}"
            else
                # No sidecar: tracked-in-git is an acceptable integrity anchor.
                if git -C "$PROJECT_ROOT" ls-files --error-unmatch "$a" >/dev/null 2>&1; then
                    print_status "OK" "${row_id}: ${a} (tracked in git)"
                else
                    print_status "WARN" "${row_id}: ${a} has no .sha256 sidecar and is not tracked — unverifiable"
                    problems=$((problems + 1))
                fi
            fi
        done <<< "$artifacts"
    done < "$reg"

    echo ""
    print_info "Checkpoint rows scanned: ${rows}"
    # A parser that scans nothing must not report success — that is the vacuous
    # pass this whole programme exists to eliminate.
    if [ "$rows" -eq 0 ]; then
        print_error "No checkpoint rows found — cannot verify. Refusing to report clean."
        return 1
    fi
    if [ "$problems" -gt 0 ]; then
        print_error "${problems} registry problem(s) found"
        return 1
    fi
    print_status "OK" "Registry consistent (${rows} rows)"
    return 0
}

cmd_register() {
    local cp="" what="" artifact="" restore="" when
    when="$(date +%Y-%m-%d)"
    local a
    for a in "$@"; do
        case "$a" in
            --cp=*)       cp="${a#*=}" ;;
            --what=*)     what="${a#*=}" ;;
            --artifact=*) artifact="${a#*=}" ;;
            --restore=*)  restore="${a#*=}" ;;
            --when=*)     when="${a#*=}" ;;
            *) print_error "Unknown option: $a"; exit 1 ;;
        esac
    done

    [ -n "$cp" ]   || { print_error "--cp=CPn required";   exit 1; }
    [ -n "$what" ] || { print_error "--what=... required"; exit 1; }

    local reg; reg="$(_registry_file)"
    [ -f "$reg" ] || { print_error "Registry not found: $reg"; exit 1; }

    if grep -q "^| ${cp} " "$reg"; then
        print_error "${cp} already exists in the registry — pick a new id."
        exit 1
    fi

    # An artifact that cannot be located or verified is not a recovery point.
    local sha_note="—" resolved=""
    if [ -n "$artifact" ]; then
        if ! resolved="$(_registry_resolve "$artifact")"; then
            print_error "artifact not found: ${artifact}"
            print_info "Refusing to register a recovery point that does not resolve to a real file."
            exit 1
        fi
        local sidecar="${resolved}.sha256" sha
        sha=$(sha256sum "$resolved" | awk '{print $1}')
        if [ ! -f "$sidecar" ]; then
            printf '%s  %s\n' "$sha" "$(basename "$resolved")" > "$sidecar"
            print_info "Wrote integrity sidecar: $(basename "$sidecar")"
        fi
        sha_note="\`${artifact}\` (sha \`${sha:0:8}…\`, sidecar alongside)"
    fi

    printf '| %s | %s | %s | %s | — | %s |\n' \
        "$cp" "$when" "$what" "$sha_note" "${restore:-—}" >> "$reg"

    print_status "OK" "Registered ${cp}"
    print_info "Validate: pl rollback registry check"
}

cmd_cleanup() {
    local keep="${KEEP:-5}"

    print_info "Cleaning up old rollback points (keeping last $keep)..."
    rollback_cleanup "$keep"
    print_status "OK" "Cleanup complete"
}

# Parse options
KEEP=""
ENV=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --keep=*) KEEP="${1#*=}"; shift ;;
        --keep) KEEP="$2"; shift 2 ;;
        --env=*) ENV="${1#*=}"; shift ;;
        --env) ENV="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) break ;;
    esac
done

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    list) cmd_list "$@" ;;
    execute) cmd_execute "$@" ;;
    verify) cmd_verify "$@" ;;
    cleanup) cmd_cleanup ;;
    backfill) cmd_backfill "$@" ;;
    registry)
        case "${1:-check}" in
            check|"") cmd_registry_check ;;
            *) print_error "Unknown registry subcommand: $1"; exit 1 ;;
        esac
        ;;
    register) cmd_register "$@" ;;
    -h|--help|help|"") show_help ;;
    *) print_error "Unknown command: $COMMAND"; show_help; exit 1 ;;
esac
