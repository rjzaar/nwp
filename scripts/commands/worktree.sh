#!/bin/bash
set -euo pipefail

################################################################################
# pl worktree — list and safely prune git worktrees, with a fate manifest
#
# THE PROBLEM IT ADDRESSES: worktrees accumulate invisibly. `git worktree list
# | wc -l` in ~/nwp was 103 and still climbing (90 twenty minutes earlier),
# 1.2 GB across the non-primary trees, and only ~15 of them carried a commit
# origin/main lacks. `pl branch stranded --prune-merged` prunes BRANCH REFS
# only — its own header names "77 worktrees" as a known unaddressed problem.
#
#   pl worktree list  [--repo=<path>] [--base=<ref>] [--no-size]
#   pl worktree prune [--repo=<path>] [--base=<ref>] [--dry-run|--confirm|--yes]
#
# DRY-RUN IS THE DEFAULT. Bare `pl worktree prune` computes and prints the
# manifest and changes nothing. Removal requires --yes (no prompt) or
# --confirm (y/N prompt). Classification, and the refusal chain behind it,
# lives in lib/worktree-prune.sh.
#
# TWO PROPERTIES WORTH KNOWING:
#   * `git worktree remove` is called WITHOUT --force. Our own predicates
#     already refuse dirty trees; git's refusal is a second, independent gate.
#   * refs are never touched. Deleting a checkout must never delete a branch —
#     that stays `pl branch stranded --prune-merged`'s job.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

source "$PROJECT_ROOT/lib/ui.sh"
# impact.sh: the fate-manifest contract every destructive verb obeys
# (nwp/ops#47). Sourced, not edited — it belongs to the impact contract.
source "$PROJECT_ROOT/lib/impact.sh"
source "$PROJECT_ROOT/lib/worktree-prune.sh"

show_help() {
    cat << EOF
${BOLD}pl worktree${NC} — list and safely prune git worktrees

${BOLD}USAGE:${NC}
    pl worktree list  [options]     Fate-classified table of every worktree
    pl worktree prune [options]     Remove ONLY clean, fully-merged worktrees

${BOLD}OPTIONS:${NC}
    --repo=<path>   Repository to operate on (default: this NWP checkout)
    --base=<ref>    Merged-ness base (default: origin/main, then main)
    --no-size       Skip du(1) — much faster on a large estate
    --dry-run       Print the manifest, change nothing (DEFAULT for prune)
    --confirm       Print the manifest, then ask y/N before removing
    -y, --yes       Print the manifest and remove without prompting

${BOLD}A WORKTREE IS REMOVED ONLY IF ALL OF THESE HOLD:${NC}
    • it is not the primary worktree
    • it is not the worktree you are standing in, nor pl's own checkout
    • it is not locked (git worktree lock)
    • it is on a branch (detached HEADs are never our call)
    • git rev-list --count <base>..<branch> == 0   (no unmerged commit)
    • no untracked/ignored data payload (backups/, *.sql.gz, *.dump …)
    • no modified tracked files, no untracked files
    • no stash entry naming its branch

${BOLD}WHAT IT NEVER DOES:${NC}
    • never deletes a branch ref — 'pl branch stranded --prune-merged' does that
    • never passes --force to git worktree remove
    • never removes anything without printing the manifest first

${BOLD}EXAMPLES:${NC}
    pl worktree list --no-size
    pl worktree prune                    # dry-run: what would go
    pl worktree prune --confirm          # manifest, then y/N
    pl worktree prune --yes              # operator-timed: run it when no
                                         # other agent session is active
EOF
}

# Absolute path of the worktree containing <dir>, if any.
_wt_toplevel_of() {
    local d="$1"
    [ -d "$d" ] || return 1
    git -C "$d" rev-parse --show-toplevel 2>/dev/null || return 1
}

_wt_print_table() {
    local fate path branch size ahead dirty note
    printf '  %-16s %-58s %-26s %8s %6s %6s  %s\n' FATE PATH BRANCH SIZE AHEAD DIRTY NOTE
    while IFS=$'\t' read -r fate path branch size ahead dirty note; do
        local color="$GREEN"
        case "$fate" in
            REMOVE)   color="$RED" ;;
            STALE)    color="$YELLOW" ;;
            KEEP\(unmerged\)) color="$YELLOW" ;;
            *)        color="$DIM" ;;
        esac
        printf '  %s%-16s%s %-58s %-26s %8s %6s %6s  %s\n' \
            "$color" "$fate" "$NC" "$path" "$branch" "$size" "$ahead" "$dirty" "$note"
    done
    return 0
}

# Shared front half of both verbs: resolve the repo + base, scan, print.
# Populates the RECORDS array in the caller's scope.
_wt_collect() {
    local repo="$1" base_opt="$2" size_opt="$3"

    if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        print_error "Not a git repository: $repo"
        return 1
    fi

    local base
    if ! base=$(wt_resolve_base "$repo" "$base_opt"); then
        print_error "Cannot resolve base ref${base_opt:+ '$base_opt'} in $repo."
        echo "Without a base ref there is no notion of 'merged', so nothing is prunable." >&2
        echo "Fetch the remote, or pass --base=<ref> naming a ref that exists." >&2
        return 1
    fi
    WT_BASE="$base"

    # Never remove the ground we are standing on, nor the checkout running us.
    WT_PROTECT_PATHS=()
    local top
    if top=$(_wt_toplevel_of "$PWD"); then WT_PROTECT_PATHS+=("current|$top"); fi
    WT_PROTECT_PATHS+=("self|$PROJECT_ROOT")

    RECORDS=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && RECORDS+=("$line")
    done < <(wt_scan "$repo" "$base" "$size_opt")
    return 0
}

cmd_list() {
    local repo="$PROJECT_ROOT" base_opt="" size_opt="size" a
    for a in "$@"; do
        case "$a" in
            --repo=*)  repo="${a#*=}" ;;
            --base=*)  base_opt="${a#*=}" ;;
            --no-size) size_opt="no-size" ;;
            -h|--help) show_help; return 0 ;;
        esac
    done

    local RECORDS=() WT_BASE=""
    _wt_collect "$repo" "$base_opt" "$size_opt" || return 1

    print_header "Worktrees of $repo (base $WT_BASE)"
    printf '%s\n' "${RECORDS[@]}" | _wt_print_table
    echo ""
    local removable
    removable=$(printf '%s\n' "${RECORDS[@]}" | grep -c $'^REMOVE\t' || true)
    print_info "${#RECORDS[@]} worktree(s); ${removable} classified REMOVE (see 'pl worktree prune')."
    return 0
}

cmd_prune() {
    local repo="$PROJECT_ROOT" base_opt="" size_opt="size"
    local execute=false auto_yes=false a
    for a in "$@"; do
        case "$a" in
            --repo=*)   repo="${a#*=}" ;;
            --base=*)   base_opt="${a#*=}" ;;
            --no-size)  size_opt="no-size" ;;
            --dry-run)  execute=false ;;
            --confirm)  execute=true ;;
            -y|--yes)   execute=true; auto_yes=true ;;
            -h|--help)  show_help; return 0 ;;
            *) print_error "Unknown option: $a"; return 1 ;;
        esac
    done

    local RECORDS=() WT_BASE=""
    _wt_collect "$repo" "$base_opt" "$size_opt" || return 1

    print_header "FATE MANIFEST — worktrees of $repo (base $WT_BASE)"
    printf '%s\n' "${RECORDS[@]}" | _wt_print_table
    echo ""

    # Feed the same findings into the impact-report contract, so this verb
    # renders and confirms exactly like every other destructive verb.
    impact_reset
    local -a to_remove=() to_prune=()
    local fate path branch size ahead dirty note rec
    for rec in "${RECORDS[@]}"; do
        IFS=$'\t' read -r fate path branch size ahead dirty note <<< "$rec"
        case "$fate" in
            REMOVE)
                to_remove+=("$path")
                impact_delete "Worktree" "$path ($branch, $size) — $note"
                ;;
            STALE)
                to_prune+=("$path")
                impact_archive "Registration" "$path — $note (no files to delete)"
                ;;
            *)
                impact_keep "$path [$fate] — $note"
                [ "$fate" = "KEEP(unmerged)" ] && \
                    impact_warn "$path is $ahead commit(s) ahead of $WT_BASE — that work exists only here"
                [ "$fate" = "KEEP(dirty)" ] && \
                    impact_warn "$path has $dirty uncommitted tracked change(s) — another session may be mid-edit"
                ;;
        esac
    done
    impact_keep "Branch refs — this verb never deletes a branch (that is 'pl branch stranded')"
    impact_render

    if [ ${#to_remove[@]} -eq 0 ] && [ ${#to_prune[@]} -eq 0 ]; then
        print_info "Nothing is removable — every worktree tripped at least one refuse-predicate."
        return 0
    fi

    if [ "$execute" != true ]; then
        print_info "DRY RUN — nothing was removed. Re-run with --confirm (y/N) or --yes to act."
        return 0
    fi

    impact_confirm standard "remove ${#to_remove[@]} worktree(s) from $repo" "$auto_yes" || {
        print_info "Aborted — nothing removed."
        return 0
    }

    local failed=0 p
    for p in ${to_remove[@]+"${to_remove[@]}"}; do
        # No --force: our predicates already refused dirty trees, and git's own
        # refusal is an independent second gate.
        if git -C "$repo" worktree remove "$p" 2>/dev/null; then
            print_success "removed $p"
        else
            print_warning "git refused to remove $p — left in place"
            failed=$((failed + 1))
        fi
    done

    # Clears registrations whose directories are already gone. Removes no files.
    git -C "$repo" worktree prune

    if [ "$failed" -gt 0 ]; then
        print_warning "$failed worktree(s) were kept because git refused them."
    fi
    print_success "Done. Branch refs untouched — 'pl branch stranded' handles those."
    return 0
}

main() {
    local sub="${1:-list}"
    case "$sub" in
        list)      shift || true; cmd_list "$@" ;;
        prune)     shift || true; cmd_prune "$@" ;;
        -h|--help|help) show_help ;;
        --*)       cmd_list "$@" ;;
        *)         print_error "Unknown subcommand: $sub"; echo ""; show_help; return 1 ;;
    esac
}

main "$@"
