#!/usr/bin/env bash
################################################################################
# lib/vcs-truth.sh — "is this the only copy?"
#
# WHY THIS EXISTS
# ---------------
# A git repository can hold the sole copy of load-bearing work and look
# completely healthy while doing it. `git status` is clean, the site serves, the
# tests pass — and the code exists on exactly one disk.
#
# Two real cases drove this:
#
#   feat/nwptoolkit-deploy   340 lines (lib/nwptoolkit-deploy.sh + an nginx
#                            template), on NO remote in ANY repo for three
#                            weeks. Not covered by the box or stick backup crons
#                            — those back up the box and the site databases, not
#                            un-pushed local refs — and it would have been
#                            destroyed by any routine worktree/branch cleanup.
#
#   servers/nwpcode/.git     a two-commit repository with no remote at all, and
#                            the only home of backup/nwp-box-backup.sh (the
#                            fleet's backup producer) and the GitLab CVE-response
#                            upgrade script.
#
# `pl todo` grew a check for the first shape. `pl doctor` — the command run on a
# fresh machine, and before any cleanup — looked at neither. This library is the
# single primitive both surfaces use, so the definition of "stranded" cannot
# drift between them.
#
# Everything here is READ-ONLY. It never pushes, never writes a ref.
################################################################################

# Guard against double-sourcing (doctor.sh and todo-checks.sh may both pull it).
[ -n "${_NWP_VCS_TRUTH_SOURCED:-}" ] && return 0
_NWP_VCS_TRUTH_SOURCED=1

_VCS_TRUTH_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

################################################################################
# vcs_discover_repos [root]
#
# Absolute work-tree path of every git repository at or under <root>, one per
# line, sorted and deduplicated.
#
# For the NWP tree this DELEGATES to discover_repos() (lib/project-resolver.sh)
# so the fleet's layout rules — the vendor/node_modules/.ddev prunes, the
# sites/tmp exclusion — live in exactly one place and cannot drift. For any
# other root (a fixture, a scratch clone) it does the generic scan.
################################################################################
vcs_discover_repos() {
    local root="${1:-${NWP_DIR:-${PROJECT_ROOT:-$HOME/nwp}}}"
    [ -d "$root" ] || return 0
    root="$(cd "$root" && pwd)"

    local nwp_root="${NWP_DIR:-${PROJECT_ROOT:-}}"
    [ -n "$nwp_root" ] && [ -d "$nwp_root" ] && nwp_root="$(cd "$nwp_root" && pwd)"

    if [ -n "$nwp_root" ] && [ "$root" = "$nwp_root" ]; then
        if ! command -v discover_repos >/dev/null 2>&1; then
            # shellcheck source=/dev/null
            [ -f "$_VCS_TRUTH_DIR/project-resolver.sh" ] && source "$_VCS_TRUTH_DIR/project-resolver.sh"
        fi
        if command -v discover_repos >/dev/null 2>&1; then
            # .agent-checkouts holds full clones of OTHER projects (nwc, …) whose
            # branches are not reachable from any nwp remote — real strandable
            # work that the sites/+servers/ layout rules do not cover.
            { discover_repos "$root/.agent-checkouts" 2>/dev/null
              [ -d "$root/.git" ] && printf '%s\n' "$root"; } | sort -u
            return 0
        fi
    fi

    # Generic scan. `.claude/worktrees` is pruned rather than deduplicated for
    # speed: linked worktrees share the parent's refs, so they can contribute no
    # finding the parent does not already carry, and there can be dozens.
    {
        find "$root" \
            \( -path '*/vendor/*' -o -path '*/node_modules/*' \
               -o -path '*/.ddev/*' -o -path '*/sites/tmp/*' \
               -o -path '*/sites/latest/*' -o -path '*/sites/vendor/*' \
               -o -path '*/.claude/worktrees/*' \) -prune -o \
            -name .git -prune -print 2>/dev/null \
        | while IFS= read -r g; do [ -n "$g" ] && dirname "$g"; done
    } | sort -u
}

################################################################################
# vcs_strand_rows [root] [warn_days]
#
# One TSV row per finding:
#
#   kind <TAB> repo-abs <TAB> label <TAB> count <TAB> age_days
#
#   kind = no-remote   the repository has no remote at all: every commit in it
#                      exists only here. label is the branch, count its commits.
#   kind = unpushed    the repository has remotes, but <label> carries <count>
#                      commits that are on none of them, and its tip is
#                      <age_days> old.
#
# warn_days (default 3) suppresses today's work-in-progress: a branch you made
# an hour ago is not a finding, it is a Tuesday.
#
# Fail-soft on unreadable repositories, and BOUNDED: the fast path is one
# rev-list per repository, and the per-branch walk only runs on repositories
# that already proved they hold something unpushed.
################################################################################
vcs_strand_rows() {
    local root="${1:-${NWP_DIR:-${PROJECT_ROOT:-$HOME/nwp}}}"
    local warn_days="${2:-3}"
    local now_epoch; now_epoch=$(date +%s)

    # Deduplicate by OBJECT STORE, not by path. A linked worktree is a separate
    # directory sharing one refs/ — without this, one stranded branch in a repo
    # with 77 worktrees is reported 77 times, and a report that noisy is one
    # nobody reads.
    local -A _seen_store=()

    local repo n_remotes total b tip age n store
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue

        store=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null \
                || git -C "$repo" rev-parse --git-dir 2>/dev/null || echo "$repo")
        [ -n "${_seen_store[$store]:-}" ] && continue
        _seen_store[$store]=1

        # An empty repository (no commits yet) holds nothing to lose.
        git -C "$repo" rev-parse --verify -q HEAD >/dev/null 2>&1 || continue

        n_remotes=$(git -C "$repo" remote 2>/dev/null | grep -c . || true)
        [[ "$n_remotes" =~ ^[0-9]+$ ]] || n_remotes=0

        if [ "$n_remotes" -eq 0 ]; then
            # No remote: the whole repository is the only copy. Report it once,
            # with its total commit count, regardless of age — age is irrelevant
            # when there is no second copy anywhere at any time.
            total=$(timeout 20 git -C "$repo" rev-list --count --all 2>/dev/null || echo 0)
            [[ "$total" =~ ^[0-9]+$ ]] || total=0
            [ "$total" -gt 0 ] || continue
            b=$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null || echo HEAD)
            tip=$(timeout 10 git -C "$repo" log -1 --format=%ct 2>/dev/null || echo "$now_epoch")
            [[ "$tip" =~ ^[0-9]+$ ]] || tip="$now_epoch"
            printf 'no-remote\t%s\t%s\t%s\t%s\n' "$repo" "$b" "$total" "$(( (now_epoch - tip) / 86400 ))"
            continue
        fi

        # Fast path: does this repository hold ANY commit that is on no remote?
        total=$(timeout 30 git -C "$repo" rev-list --count --branches --not --remotes 2>/dev/null || echo 0)
        [[ "$total" =~ ^[0-9]+$ ]] || total=0
        [ "$total" -gt 0 ] || continue

        # It does — now name the branches, newest tip first.
        while IFS=$'\t' read -r b tip; do
            [ -n "$b" ] || continue
            [[ "$tip" =~ ^[0-9]+$ ]] || continue
            age=$(( (now_epoch - tip) / 86400 ))
            [ "$age" -ge "$warn_days" ] || continue
            n=$(timeout 20 git -C "$repo" rev-list --count "$b" --not --remotes 2>/dev/null || echo 0)
            [[ "$n" =~ ^[0-9]+$ ]] || n=0
            [ "$n" -gt 0 ] || continue
            printf 'unpushed\t%s\t%s\t%s\t%s\n' "$repo" "$b" "$n" "$age"
        done < <(timeout 30 git -C "$repo" for-each-ref \
                    --sort=-committerdate \
                    --format='%(refname:short)%09%(committerdate:unix)' \
                    refs/heads/ 2>/dev/null)
    done < <(vcs_discover_repos "$root")
}

export -f vcs_discover_repos vcs_strand_rows 2>/dev/null || true
