#!/bin/bash
################################################################################
# lib/worktree-prune.sh — classification engine for `pl worktree`
#
# WHY: git worktrees accumulate silently. In ~/nwp at the time of writing,
# `git worktree list | wc -l` was 103 and climbing (90 twenty minutes earlier),
# 1.2 GB across the non-primary trees, of which only ~15 carried a commit
# origin/main lacks. Nothing enumerated them: `pl branch stranded
# --prune-merged` prunes BRANCH REFS, not checkouts — its own header records
# "77 worktrees" as a known unaddressed problem.
#
# WHY THIS IS REFUSE-FIRST: several agents hold uncommitted work in those
# trees at any moment, and a worktree is the ONLY copy of anything not
# committed. So classification is a chain of refusals: a tree is removable
# only when EVERY predicate says so, and every predicate failure is named in
# the manifest rather than swallowed.
#
#   KEEP(primary)   the repo's own main checkout
#   KEEP(current)   the tree $PWD is inside — never saw off your own branch
#   KEEP(self)      the tree the running pl lives in
#   KEEP(locked)    operator locked it (git worktree lock)
#   KEEP(detached)  no branch ⇒ merged-ness is not computable ⇒ not our call
#   KEEP(unmerged)  git rev-list --count <base>..<branch> > 0
#   KEEP(payload)   untracked/ignored data that looks like backups (*.sql.gz…)
#   KEEP(dirty)     tracked files modified or staged
#   KEEP(untracked) any other untracked file
#   KEEP(stash)     a stash entry references this branch
#   STALE           registration whose directory is gone (files already absent)
#   REMOVE          all of the above passed
#
# DELIBERATELY STRICTER THAN `pl branch stranded`: stranded calls a branch
# IDENTICAL (prunable) when its FILES match main even if its commits never
# merged. That is right for a ref and wrong for a checkout — the commits are
# still the only record of how the work was done. Here the gate is the blunt
# one the item specifies: ahead-count must be exactly 0.
#
# We never touch refs. Deleting a checkout must never delete a branch; that
# stays `pl branch stranded --prune-merged`'s job.
################################################################################

# --no-optional-locks on every read: these commands run against worktrees other
# agents are actively using. Without it, `git status` refreshes and rewrites
# that worktree's index, which can race a live session.
_wt_git() { git --no-optional-locks -C "$@"; }

# wt_resolve_base <repo> [explicit] — echo a resolvable base rev, or fail.
# Fails closed: with no base there is no notion of "merged", so nothing is
# removable and the caller must abort rather than guess.
wt_resolve_base() {
    local repo="$1" explicit="${2:-}"
    local cand
    if [ -n "$explicit" ]; then
        if git -C "$repo" rev-parse --verify -q "${explicit}^{commit}" >/dev/null 2>&1; then
            printf '%s\n' "$explicit"; return 0
        fi
        return 1
    fi
    for cand in origin/main main origin/master master; do
        if git -C "$repo" rev-parse --verify -q "${cand}^{commit}" >/dev/null 2>&1; then
            printf '%s\n' "$cand"; return 0
        fi
    done
    return 1
}

# Field separator for wt_records: US (0x1f), NOT tab.
# WHY: `IFS=$'\t' read -r path branch flags` COLLAPSES consecutive tabs,
# because tab is IFS whitespace. A detached worktree has an empty branch
# field, so its flags ("detached") slid into $branch and it classified as
# KEEP(uncomparable) instead of KEEP(detached) — observed, not theorised.
WT_FS=$'\x1f'

# wt_records <repo> — one record per worktree: path US branch US flags
# flags is a comma-joined subset of: detached,locked,prunable,bare
wt_records() {
    local repo="$1"
    local line path="" branch="" flags=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "worktree "*) path="${line#worktree }" ;;
            "branch "*)   branch="${line#branch }"; branch="${branch#refs/heads/}" ;;
            detached)     flags="${flags}detached," ;;
            locked|"locked "*)     flags="${flags}locked," ;;
            prunable|"prunable "*) flags="${flags}prunable," ;;
            bare)         flags="${flags}bare," ;;
            "")
                [ -n "$path" ] && printf '%s%s%s%s%s\n' "$path" "$WT_FS" "$branch" "$WT_FS" "$flags"
                path=""; branch=""; flags=""
                ;;
        esac
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
    [ -n "$path" ] && printf '%s%s%s%s%s\n' "$path" "$WT_FS" "$branch" "$WT_FS" "$flags"
    return 0
}

# wt_ahead <repo> <branch> <base> — commits on <branch> that <base> lacks.
# Echoes "?" when it cannot be computed (which classifies as KEEP, not REMOVE).
wt_ahead() {
    local repo="$1" branch="$2" base="$3" n
    [ -n "$branch" ] || { printf '?\n'; return 0; }
    if n=$(git -C "$repo" rev-list --count "${base}..${branch}" 2>/dev/null); then
        printf '%s\n' "${n:-?}"
    else
        printf '?\n'
    fi
}

# wt_dirty_count <worktree> — TRACKED modifications only (staged or not).
wt_dirty_count() {
    local wt="$1"
    [ -d "$wt" ] || { printf '0\n'; return 0; }
    _wt_git "$wt" status --porcelain --untracked-files=no 2>/dev/null | grep -c . || true
}

# wt_untracked_count <worktree> — untracked entries (ignored files excluded).
wt_untracked_count() {
    local wt="$1"
    [ -d "$wt" ] || { printf '0\n'; return 0; }
    _wt_git "$wt" status --porcelain --untracked-files=normal 2>/dev/null \
        | grep -c '^??' || true
}

# Directories never worth descending into when hunting for data payloads.
_WT_HEAVY_DIRS='node_modules|vendor|\.git|\.ddev|\.venv|__pycache__'

# wt_payload <worktree> — echo the first data-looking untracked/ignored path
# found, or nothing. Return 0 if a payload was found, 1 otherwise.
#
# Two passes, cheap first: the porcelain path itself (which is how the common
# nwp case shows up — a gitignored `backups/` collapses to one entry), then a
# shallow find inside untracked/ignored directories for *.sql*/*.dump.
# `--ignored` without `=matching` keeps ignored directories collapsed, so this
# does not enumerate 100k vendor files.
wt_payload() {
    local wt="$1"
    [ -d "$wt" ] || return 1
    local line p hit
    while IFS= read -r line; do
        p="${line:3}"
        p="${p%\"}"; p="${p#\"}"
        case "$p" in
            backups|backups/*|*/backups|*/backups/*|sitebackups|sitebackups/*|*/sitebackups/*)
                printf '%s\n' "$p"; return 0 ;;
            *.sql|*.sql.gz|*.sql.bz2|*.sql.xz|*.sql.zst|*.dump|*.dump.gz|*.mysql|*.mysql.gz)
                printf '%s\n' "$p"; return 0 ;;
        esac
        if [ -d "$wt/$p" ] && ! [[ "$p" =~ (^|/)($_WT_HEAVY_DIRS)(/|$) ]]; then
            hit=$(find "$wt/$p" -maxdepth 2 \
                    \( -regextype posix-extended -regex ".*/($_WT_HEAVY_DIRS)" \) -prune -o \
                    -type f \( -name '*.sql' -o -name '*.sql.*' -o -name '*.dump' \
                               -o -name '*.dump.*' -o -name '*.mysql' -o -name '*.mysql.*' \) \
                    -print -quit 2>/dev/null || true)
            if [ -n "$hit" ]; then printf '%s\n' "${hit#$wt/}"; return 0; fi
        fi
    done < <(_wt_git "$wt" status --porcelain --untracked-files=normal --ignored 2>/dev/null \
             | grep -E '^(\?\?|!!) ' || true)
    return 1
}

# wt_stash_count <repo> <branch> — stash entries whose subject names <branch>.
# NOTE (honest limitation): refs/stash is shared across all worktrees of a
# repo, so this is a per-BRANCH signal, not a per-worktree one. It errs toward
# KEEP, which is the direction we want.
wt_stash_count() {
    local repo="$1" branch="$2"
    [ -n "$branch" ] || { printf '0\n'; return 0; }
    local s n=0
    # Subjects come in two shapes and the first has NO leading space:
    #   "On wt7: wip"                 (git stash push -m)
    #   "WIP on wt7: 1234abc subject" (bare git stash)
    # Matching " on <branch>:" alone missed the first — observed, not theorised.
    while IFS= read -r s; do
        case "$s" in
            "On ${branch}:"*|"WIP on ${branch}:"*|*" on ${branch}:"*) n=$((n + 1)) ;;
        esac
    done < <(git -C "$repo" stash list --format='%gs' 2>/dev/null || true)
    printf '%s\n' "$n"
}

# wt_size <path> — human-readable disk usage, "-" when the path is gone.
wt_size() {
    local p="$1"
    [ -d "$p" ] || { printf -- '-\n'; return 0; }
    du -sh "$p" 2>/dev/null | awk '{print $1}' || printf -- '?\n'
}

################################################################################
# wt_scan <repo> <base> [--no-size]
#
# Emits one TSV record per worktree:
#   fate \t path \t branch \t size \t ahead \t dirty \t note
#
# WT_PROTECT_PATHS (array, set by the caller) lists paths that must never be
# removed no matter what — the caller puts $PWD and the running pl's own root
# in it. A worktree containing any of them is KEEP(current)/KEEP(self).
################################################################################
wt_scan() {
    local repo="$1" base="$2" want_size="${3:-size}"
    local primary="" path branch flags fate note size ahead dirty untracked payload stashes
    local rec first=true prot

    while IFS="$WT_FS" read -r path branch flags; do
        [ -n "$path" ] || continue
        if [ "$first" = true ]; then primary="$path"; first=false; fi

        fate=""; note=""
        ahead="?"; dirty="0"

        if [ "$path" = "$primary" ]; then
            fate="KEEP(primary)"; note="the repo's own checkout"
        fi

        # WT_PROTECT_PATHS entries are "label|absolute-path".
        if [ -z "$fate" ]; then
            for prot in ${WT_PROTECT_PATHS[@]+"${WT_PROTECT_PATHS[@]}"}; do
                [ -n "${prot#*|}" ] || continue
                case "${prot#*|}/" in
                    "${path}/"*)
                        fate="KEEP(${prot%%|*})"
                        note="you are standing in it — refusing to saw off the branch"
                        break ;;
                esac
            done
        fi

        [ -z "$fate" ] && case ",$flags" in *,locked,*) fate="KEEP(locked)"; note="git worktree lock" ;; esac

        if [ -z "$fate" ] && { [ ! -d "$path" ] || case ",$flags" in *,prunable,*) true ;; *) false ;; esac; }; then
            fate="STALE"; note="directory is gone — registration only"
        fi

        if [ -z "$fate" ]; then
            case ",$flags" in *,detached,*) fate="KEEP(detached)"; note="no branch to compare" ;; esac
        fi
        [ -z "$fate" ] && [ -z "$branch" ] && { fate="KEEP(detached)"; note="no branch to compare"; }

        if [ -z "$fate" ]; then
            ahead=$(wt_ahead "$repo" "$branch" "$base")
            if [ "$ahead" = "?" ]; then
                fate="KEEP(uncomparable)"; note="cannot count commits vs $base"
            elif [ "$ahead" -gt 0 ] 2>/dev/null; then
                fate="KEEP(unmerged)"; note="$ahead commit(s) $base lacks"
            fi
        fi

        if [ -z "$fate" ]; then
            if payload=$(wt_payload "$path"); then
                fate="KEEP(payload)"; note="data payload: $payload"
            fi
        fi

        if [ -z "$fate" ]; then
            dirty=$(wt_dirty_count "$path")
            if [ "${dirty:-0}" -gt 0 ]; then
                fate="KEEP(dirty)"; note="$dirty tracked file(s) modified"
            fi
        fi

        if [ -z "$fate" ]; then
            untracked=$(wt_untracked_count "$path")
            if [ "${untracked:-0}" -gt 0 ]; then
                fate="KEEP(untracked)"; note="$untracked untracked file(s)"
            fi
        fi

        if [ -z "$fate" ]; then
            stashes=$(wt_stash_count "$repo" "$branch")
            if [ "${stashes:-0}" -gt 0 ]; then
                fate="KEEP(stash)"; note="$stashes stash entry/entries on $branch"
            fi
        fi

        [ -z "$fate" ] && { fate="REMOVE"; note="clean and fully merged into $base"; }

        if [ "$want_size" = "no-size" ]; then size="-"; else size=$(wt_size "$path"); fi
        [ "$ahead" = "?" ] && [ -n "$branch" ] && ahead=$(wt_ahead "$repo" "$branch" "$base")

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$fate" "$path" "${branch:-(detached)}" "$size" "$ahead" "${dirty:-0}" "$note"
    done < <(wt_records "$repo")
    return 0
}
