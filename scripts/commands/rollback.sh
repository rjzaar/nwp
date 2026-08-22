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
# deploy-gate.sh: hardware+signature gate on prod-writes (NWP-ADR-0028); no-op unless
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

# Is this artifact in version control? Asked of the repo that OWNS the file,
# which is not necessarily the one holding the registry: nested site repos keep
# their own backups, and asking the wrong checkout returns a confident "no" for
# a file that is tracked next door.
_artifact_is_tracked() {
    local f="$1" repo rel
    repo="$(git -C "$(dirname "$f")" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$repo" ] || return 1
    rel="$(realpath --relative-to="$repo" "$f" 2>/dev/null || printf '%s' "$f")"
    git -C "$repo" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1
}

# Does the repo's own policy forbid committing this path? Read from git, not
# from a glob list duplicated here — a duplicated list drifts, and the whole
# point is that the containment rules are the single source of truth.
_artifact_is_ignored() {
    local f="$1" repo
    repo="$(git -C "$(dirname "$f")" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$repo" ] || return 1
    git -C "$repo" check-ignore -q -- "$f" 2>/dev/null
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

            # SURVIVABILITY, asked before integrity — they are different
            # questions and the sidecar only answers the second one.
            #
            # A `.sha256` sidecar proves the bytes have not rotted. It says
            # nothing about whether the bytes still exist after `git clean
            # -xfd`, a pruned worktree or a reimaged laptop — and the sidecar
            # is untracked in exactly the cases the artifact is, so the check
            # was comparing a file against its own untracked shadow and
            # reporting OK. That is how CP17 sat green in this ledger while its
            # tarball was one `git clean` from gone.
            #
            # `register` now refuses such a row at the front door, but every
            # row written before that guard existed came in unchecked, and the
            # ledger is read at the worst possible moment by someone who needs
            # the artifact to still be there.
            #
            # The repo is derived from the ARTIFACT's own directory, not from
            # PROJECT_ROOT: registry and artifact are not always in the same
            # checkout (nested site repos hold their own backups), and asking
            # the wrong repo about a path returns "not tracked" for a file that
            # is perfectly well tracked next door.
            local durable=1
            if ! _artifact_is_tracked "$resolved"; then
                durable=0
                # TWO DIFFERENT DEFECTS WITH TWO DIFFERENT REMEDIES, and
                # conflating them would be actively dangerous.
                #
                # If the repo's own ignore policy excludes this path, "commit
                # it" is the WRONG advice: these are database dumps and files
                # tarballs, and committing one is precisely the P0 already
                # found in this estate (a 36 MB member-data .sql pushed to the
                # forge, where no erasure request can reach it). Such an
                # artifact cannot be made durable by git at all — it needs a
                # second copy somewhere else, and the row needs to say where.
                #
                # Using `git check-ignore` rather than a glob list means the
                # policy is read from the repo instead of duplicated here, so
                # the two cannot drift apart.
                if _artifact_is_ignored "$resolved"; then
                    print_status "FAIL" "${row_id}: LAPTOP-ONLY — ${a} exists in exactly one place, and that place travels"
                    print_info   "        Ignored by repo policy (it is member data) — do NOT commit it."
                    print_info   "        Get a second copy off this machine, then re-record the row:"
                    print_info   "          pl rollback register --cp=${row_id} --off-host --artifact=<host:path> --sha=<hex> ..."
                else
                    print_status "FAIL" "${row_id}: UNTRACKED — ${a} is on this disk but not in version control"
                    print_info   "        A recovery point only this laptop holds is not a recovery point."
                    print_info   "        Commit it, or re-record the row as off-host with a sha."
                fi
                problems=$((problems + 1))
                # Deliberately NO `continue`. Survivability and integrity are
                # independent questions and a row can be wrong in both ways at
                # once; short-circuiting here would hide a stale sha behind an
                # untracked artifact and force two round trips to learn it.
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
                # Only claim OK if the row passed BOTH questions. An artifact
                # that matches its sidecar but nothing durable holds is not an
                # OK row, and printing OK under it is how the ledger looked
                # green while its recovery points were one `git clean` away.
                [ "$durable" -eq 1 ] && print_status "OK" "${row_id}: ${a}"
            else
                # No sidecar. Git's own object hashing is the integrity anchor
                # for a tracked file — a committed file that changed shows up
                # as a diff. If it is not tracked, the durability branch above
                # has already failed the row and there is nothing left to
                # verify it with.
                if [ "$durable" -eq 1 ]; then
                    print_status "OK" "${row_id}: ${a} (tracked in git)"
                else
                    print_info "        …and no .sha256 sidecar either, so nothing can verify it"
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
    local cp="" what="" artifact="" restore="" when off_host=0 off_sha=""
    when="$(date +%Y-%m-%d)"
    local a
    for a in "$@"; do
        case "$a" in
            --cp=*)       cp="${a#*=}" ;;
            --what=*)     what="${a#*=}" ;;
            --artifact=*) artifact="${a#*=}" ;;
            --restore=*)  restore="${a#*=}" ;;
            --when=*)     when="${a#*=}" ;;
            --off-host)   off_host=1 ;;
            --sha=*)      off_sha="${a#*=}" ;;
            *) print_error "Unknown option: $a"; exit 1 ;;
        esac
    done

    [ -n "$cp" ]   || { print_error "--cp=CPn required";   exit 1; }
    [ -n "$what" ] || { print_error "--what=... required"; exit 1; }

    if [ -n "$off_sha" ] && [ "$off_host" != 1 ]; then
        print_error "--sha= is only meaningful with --off-host"
        exit 1
    fi

    local reg; reg="$(_registry_file)"
    [ -f "$reg" ] || { print_error "Registry not found: $reg"; exit 1; }

    if grep -q "^| ${cp} " "$reg"; then
        print_error "${cp} already exists in the registry — pick a new id."
        exit 1
    fi

    # An artifact that cannot be located or verified is not a recovery point.
    local sha_note="—" resolved=""

    # An artifact that lives on another host cannot be tracked here. It is still
    # a legitimate recovery point, but it has to carry a recorded sha instead —
    # which is exactly what `registry check` already demands of such rows. The
    # flag is explicit so "off-host" is a decision someone made, not a state a
    # typo can fall into.
    if [ "$off_host" = 1 ]; then
        [ -n "$artifact" ] || { print_error "--off-host requires --artifact="; exit 1; }
        if ! printf '%s' "$off_sha" | grep -qE '^[0-9a-f]{8,}$'; then
            print_error "--off-host requires --sha=<hex> (>=8 chars): an artifact nobody can reach here is trusted only by its recorded hash"
            exit 1
        fi
        sha_note="\`${artifact}\` (off-host, sha \`${off_sha:0:8}…\`)"

    elif [ -n "$artifact" ]; then
        if ! resolved="$(_registry_resolve "$artifact")"; then
            print_error "artifact not found: ${artifact}"
            print_info "Refusing to register a recovery point that does not resolve to a real file."
            exit 1
        fi

        # TRACKEDNESS, not mere existence.
        #
        # Resolution only proves the file is on this laptop right now. CP17 was
        # registered against a tarball that was on disk and untracked, so the
        # ledger's integrity check was green while the artifact was one `git
        # clean` from gone. The laptop is the machine we are least entitled to
        # assume survives: it travels, and the fleet backup crons cover the box
        # and the site DBs — not un-pushed local files.
        local art_repo art_rel
        art_repo="$(git -C "$(dirname "$resolved")" rev-parse --show-toplevel 2>/dev/null || true)"
        if [ -z "$art_repo" ]; then
            print_error "UNTRACKED: ${artifact} is not inside a git repository"
            print_info "Commit it somewhere, or record it as --off-host --sha=<hex>."
            exit 1
        fi
        art_rel="$(realpath --relative-to="$art_repo" "$resolved" 2>/dev/null || printf '%s' "$resolved")"
        if ! git -C "$art_repo" ls-files --error-unmatch -- "$art_rel" >/dev/null 2>&1; then
            print_error "UNTRACKED: ${artifact} exists on disk but is not in version control"
            print_info "A recovery point that only exists locally is not a recovery point."
            print_info "Fix:  git -C ${art_repo} add -- ${art_rel} && git commit"
            print_info "Or, if it genuinely lives elsewhere: --off-host --sha=<hex>"
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
