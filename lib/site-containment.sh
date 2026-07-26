#!/usr/bin/env bash
################################################################################
# lib/site-containment.sh — nested-repo containment
#
# NWP's v2 site layout puts real git repositories underneath sites/:
#   sites/<name>/dev/.git, .../stg/.git, .../backups/.git,
#   .../dev/html/profiles/custom/<x>/.git, .../.plugin-src/*/.git
# The repo-root gitleaks gate and the repo-root pre-commit hook do not cover
# any of them. Containment therefore has to be a property of each nested repo's
# own ignore rules.
#
# This library provides the mechanism; `pl site gitignore` and `pl site vcs`
# provide the operator surface, and scripts/commands/backup.sh calls
# containment_assert_backup_path() before writing any artifact.
#
# Design notes:
#   * Checks are BEHAVIOURAL, not textual. containment_check_repo asks
#     `git check-ignore` whether a representative sensitive path would be
#     committed, rather than grepping the .gitignore for a rule string. A
#     comment cannot satisfy it, and an equivalent rule written differently
#     still passes.
#   * The rules live in templates/site-gitignore.tmpl, not in this file, so the
#     scaffolder and the checker can never disagree.
#   * containment_check_fleet fails on an EMPTY corpus. A containment sweep that
#     scanned nothing must report "cannot verify", never "clean".
################################################################################

# Guard against double-sourcing.
[ -n "${_NWP_SITE_CONTAINMENT_SOURCED:-}" ] && return 0
_NWP_SITE_CONTAINMENT_SOURCED=1

_CONTAINMENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Marker wrapped around the managed block inside each repo's .gitignore.
CONTAINMENT_BEGIN_MARKER='# >>> nwp containment (managed by `pl site gitignore --fix`) >>>'
CONTAINMENT_END_MARKER='# <<< nwp containment <<<'

################################################################################
# Template access
################################################################################

# Absolute path to the containment template.
containment_template_path() {
    if [ -n "${NWP_CONTAINMENT_TEMPLATE:-}" ] && [ -f "$NWP_CONTAINMENT_TEMPLATE" ]; then
        printf '%s\n' "$NWP_CONTAINMENT_TEMPLATE"
        return 0
    fi
    local candidate="$_CONTAINMENT_LIB_DIR/../templates/site-gitignore.tmpl"
    if [ -f "$candidate" ]; then
        (cd "$(dirname "$candidate")" && printf '%s/%s\n' "$(pwd)" "$(basename "$candidate")")
        return 0
    fi
    echo "ERROR: containment template not found (looked at $candidate)" >&2
    return 1
}

# containment_render_section <site|backups>
# Emit the rule lines for one section of the template (comments preserved).
containment_render_section() {
    local kind="${1:-}"
    case "$kind" in
        site|backups) ;;
        *) echo "ERROR: unknown containment section '$kind' (want: site|backups)" >&2; return 2 ;;
    esac

    local tmpl
    tmpl="$(containment_template_path)" || return 1

    awk -v want="# ===== nwp:section:${kind} =====" '
        $0 == want { inside = 1; next }
        /^# ===== nwp:section:/ { if (inside) exit; next }
        inside { print }
    ' "$tmpl"
}

# containment_probe_paths <site|backups>
# Representative paths that MUST be ignored for a repo of this kind. These are
# what the behavioural check interrogates.
containment_probe_paths() {
    local kind="${1:-}"
    case "$kind" in
        site)
            printf '%s\n' \
                'html/sites/default/settings.php' \
                'web/sites/default/settings.php' \
                'oauth-keys/private.key' \
                'auth.json' \
                '.secrets.yml'
            ;;
        backups)
            printf '%s\n' \
                'nwp-containment-probe.sql' \
                'nwp-containment-probe.sql.gz' \
                'nwp-containment-probe.tar.gz' \
                'nwp-containment-probe.manifest.json'
            ;;
        *)
            echo "ERROR: unknown containment kind '$kind'" >&2; return 2 ;;
    esac
}

################################################################################
# Repo inspection
################################################################################

# containment_repo_kind <repo_path>
# Infer which rule set applies. A directory literally named backups (the v2
# per-site backup dir) is a backups repo; everything else is a site repo.
containment_repo_kind() {
    local repo="${1:-}"
    case "$(basename "$repo")" in
        backups|backup) echo "backups" ;;
        *)              echo "site" ;;
    esac
}

# containment_check_repo <repo_path> [kind]
# Print the probe paths that would be COMMITTABLE. Non-zero if any are.
containment_check_repo() {
    local repo="${1:-}"
    local kind="${2:-}"
    [ -n "$kind" ] || kind="$(containment_repo_kind "$repo")"

    if [ ! -d "$repo" ]; then
        echo "ERROR: not a directory: $repo" >&2
        return 2
    fi
    if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        echo "ERROR: not a git repository: $repo" >&2
        return 2
    fi

    local missing=0 probe
    while IFS= read -r probe; do
        [ -n "$probe" ] || continue
        if ! git -C "$repo" check-ignore -q "$probe" 2>/dev/null; then
            echo "LEAKABLE  ${repo}  ${probe}"
            missing=$((missing + 1))
        fi
    done < <(containment_probe_paths "$kind")

    [ "$missing" -eq 0 ]
}

# containment_fix_repo <repo_path> [kind]
# Idempotently install/refresh the managed containment block in the repo's
# .gitignore. Never removes or negates a pre-existing rule.
containment_fix_repo() {
    local repo="${1:-}"
    local kind="${2:-}"
    [ -n "$kind" ] || kind="$(containment_repo_kind "$repo")"

    if [ ! -d "$repo" ]; then
        echo "ERROR: not a directory: $repo" >&2
        return 2
    fi

    local gi="$repo/.gitignore"
    local section
    section="$(containment_render_section "$kind")" || return 1

    local desired
    desired="$(
        printf '%s\n' "$CONTAINMENT_BEGIN_MARKER"
        printf '%s\n' "$section"
        printf '%s\n' "$CONTAINMENT_END_MARKER"
    )"

    local existing="" preserved=""
    if [ -f "$gi" ]; then
        # Everything outside the managed block is preserved verbatim.
        preserved="$(
            awk -v b="$CONTAINMENT_BEGIN_MARKER" -v e="$CONTAINMENT_END_MARKER" '
                $0 == b { skip = 1; next }
                $0 == e { skip = 0; next }
                !skip   { print }
            ' "$gi"
        )"
        existing="$(cat "$gi")"
    fi

    local rebuilt
    if [ -n "$preserved" ]; then
        rebuilt="$(printf '%s\n\n%s\n' "$preserved" "$desired")"
    else
        rebuilt="$(printf '%s\n' "$desired")"
    fi

    # Idempotent: only write when the content actually changes.
    if [ "$existing" = "$rebuilt" ]; then
        return 0
    fi

    printf '%s\n' "$rebuilt" > "$gi" || return 1
    return 0
}

################################################################################
# Discovery
################################################################################

# containment_discover_repos <root>
# Every nested git repo under <root>, one absolute path per line, sorted.
# Skips vendor/, node_modules/, DDEV internals and agent worktrees.
containment_discover_repos() {
    local root="${1:-}"
    [ -d "$root" ] || return 0

    find "$root" \
        \( -path '*/vendor/*' -o -path '*/node_modules/*' \
           -o -path '*/.ddev/*' -o -path '*/.claude/*' \) -prune -o \
        -name '.git' -print 2>/dev/null \
    | while IFS= read -r gitpath; do
        dirname "$gitpath"
      done | sort -u
}

################################################################################
# Fleet check
################################################################################

# containment_check_fleet [sites_root]
# Check every discovered nested repo. Non-zero if ANY repo is leaky OR if the
# corpus is empty (a sweep that scanned nothing has verified nothing).
containment_check_fleet() {
    local root="${1:-}"
    if [ -z "$root" ]; then
        root="${NWP_DIR:-${PROJECT_ROOT:-.}}/sites"
    fi

    local repos=() r
    while IFS= read -r r; do
        [ -n "$r" ] && repos+=("$r")
    done < <(containment_discover_repos "$root")

    if [ "${#repos[@]}" -eq 0 ]; then
        echo "CANNOT VERIFY: containment scan found zero git repositories under '$root'."
        echo "  A containment sweep that scanned nothing has verified nothing."
        echo "  (In CI, sites/ is gitignored and therefore absent — this check belongs"
        echo "   on a host where the fleet exists, surfaced via pl todo / pl rag.)"
        return 3
    fi

    local leaky=0
    for r in "${repos[@]}"; do
        if ! containment_check_repo "$r" 2>/dev/null; then
            leaky=$((leaky + 1))
        fi
    done

    echo "scanned ${#repos[@]} nested repositories under '$root'; ${leaky} leaky"
    [ "$leaky" -eq 0 ]
}

################################################################################
# Already-tracked payloads — the half ignore rules can never fix
#
# git does not consult .gitignore for a path it already tracks. So a repo that
# has ALREADY committed a production dump reports perfectly clean once the
# containment block is installed: containment_check_repo asks "could this be
# committed?", and the answer for an already-committed file is "it already was".
#
# That is sites/avc/backups today — a 36 MB unsanitised SQL dump and a 363 MB
# files tarball, blob-for-blob on the backups/avc-files repo on the code forge.
# Clearing it needs `git filter-repo` + a force-push to the forge, which is a
# history rewrite on a remote and therefore operator-gated. What the tooling
# owes is to never let that state be mistaken for a clean one.
################################################################################

# Glob patterns whose presence in the TRACKED set is a disclosure, not a risk.
#
# These were chosen from measurement over the real 47-repo fleet, not guessed.
# A bare `*/settings.php` matched 300+ upstream Moodle plugin admin-settings
# declarations, which are not credentials — and an alarm that cries wolf 300
# times is an alarm nobody reads, which is just a slower vacuous pass. So the
# Drupal credential file is matched by its actual location (`sites/<x>/`), and
# key material by its actual home (`oauth-keys/`), not by extension alone.
containment_tracked_patterns() {
    printf '%s\n' \
        '*.sql' \
        '*.sql.gz' \
        '*.sql.bz2' \
        '*.tar.gz' \
        '*.tgz' \
        'sites/*/settings.php' \
        '*/sites/*/settings.php' \
        'sites/*/settings.local.php' \
        '*/sites/*/settings.local.php' \
        'oauth-keys/*' \
        '*/oauth-keys/*' \
        'auth.json' \
        '*/auth.json' \
        '.secrets.yml' \
        '*/.secrets.yml' \
        '.secrets.data.yml' \
        '*/.secrets.data.yml'
}

# Paths that match a payload pattern but are upstream test fixtures or vendored
# third-party material, not site data. Measured against the fleet: these account
# for every hit except sites/avc/backups (a real 36 MB production dump) and
# sites/mayo/dev/html/sites/default/settings.php (a real tracked credential
# file). Expressed as git pathspec-exclude magic so git does the matching.
containment_tracked_exclusions() {
    printf '%s\n' \
        ':(exclude)tests/*' \
        ':(exclude)*/tests/*' \
        ':(exclude)test/*' \
        ':(exclude)*/test/*' \
        ':(exclude)fixtures/*' \
        ':(exclude)*/fixtures/*' \
        ':(exclude)vendor/*' \
        ':(exclude)*/vendor/*' \
        ':(exclude)node_modules/*' \
        ':(exclude)*/node_modules/*' \
        ':(exclude)*cacert*' \
        ':(exclude)lib/dml/*' \
        ':(exclude)*/lib/dml/*'
}
# NOTE on ':(exclude)*/lib/dml/*': Moodle ships Oracle DDL as
# lib/dml/oci_native_moodle_package.sql in every Moodle checkout. It is upstream
# schema, not site data, and it was public on github.com/moodle/moodle long
# before we cloned it. This list is deliberately SHRINK-ONLY in spirit: every
# entry above was justified by measurement over the real fleet, and widening it
# is how an exposure detector goes quietly blind. Add an entry only with the
# evidence that made it necessary.

# containment_check_tracked_repo <repo_path>
# Print one EXPOSED line per already-tracked sensitive blob. Non-zero if any.
# Names the remote, because a remote is what turns "committed" into "published".
containment_check_tracked_repo() {
    local repo="${1:-}"

    if [ ! -d "$repo" ]; then
        echo "ERROR: not a directory: $repo" >&2
        return 2
    fi
    if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        echo "ERROR: not a git repository: $repo" >&2
        return 2
    fi

    local pats=()
    local p
    while IFS= read -r p; do
        [ -n "$p" ] && pats+=("$p")
    done < <(containment_tracked_patterns)
    while IFS= read -r p; do
        [ -n "$p" ] && pats+=("$p")
    done < <(containment_tracked_exclusions)

    local hits=()
    local f
    while IFS= read -r f; do
        [ -n "$f" ] && hits+=("$f")
    done < <(git -C "$repo" ls-files -- "${pats[@]}" 2>/dev/null | sort -u)

    [ "${#hits[@]}" -eq 0 ] && return 0

    # A remote is what makes a committed blob a published one. Report it either
    # way — a local-only repo still gains a remote the moment someone adds one.
    local url
    url="$(git -C "$repo" remote get-url origin 2>/dev/null)"
    [ -n "$url" ] || url="(no remote — not published yet)"

    for f in "${hits[@]}"; do
        echo "EXPOSED   ${repo}  ${f}  ->  ${url}"
    done
    return 1
}

# containment_check_tracked_fleet [sites_root]
# Fleet sweep for already-published payloads. Fails closed on an empty corpus:
# a sweep that scanned nothing has verified nothing.
containment_check_tracked_fleet() {
    local root="${1:-}"
    if [ -z "$root" ]; then
        root="${NWP_DIR:-${PROJECT_ROOT:-.}}/sites"
    fi

    local repos=() r
    while IFS= read -r r; do
        [ -n "$r" ] && repos+=("$r")
    done < <(containment_discover_repos "$root")

    if [ "${#repos[@]}" -eq 0 ]; then
        echo "CANNOT VERIFY: exposure scan found zero git repositories under '$root'."
        echo "  A sweep that scanned nothing has verified nothing."
        return 3
    fi

    local exposed=0
    for r in "${repos[@]}"; do
        if ! containment_check_tracked_repo "$r" 2>/dev/null; then
            exposed=$((exposed + 1))
        fi
    done

    echo "scanned ${#repos[@]} nested repositories under '$root'; ${exposed} with published payloads"
    [ "$exposed" -eq 0 ]
}

################################################################################
# Backup-write guard
################################################################################

# containment_assert_backup_path <dir>
# Refuse to write backup artifacts into a directory that sits inside a git work
# tree with a configured remote, unless dumps/tarballs are already ignored
# there. Fail closed.
containment_assert_backup_path() {
    local dir="${1:-}"
    [ -n "$dir" ] || return 0

    if [ "${NWP_ALLOW_BACKUP_IN_REPO:-0}" = "1" ]; then
        echo "WARNING: NWP_ALLOW_BACKUP_IN_REPO=1 — containment guard bypassed for '$dir'." >&2
        echo "WARNING: backup artifacts may become committable in an enclosing git repo." >&2
        return 0
    fi

    # Walk up to the nearest existing ancestor so the guard works before mkdir.
    local probe_dir="$dir"
    while [ -n "$probe_dir" ] && [ ! -d "$probe_dir" ]; do
        local parent
        parent="$(dirname "$probe_dir")"
        [ "$parent" = "$probe_dir" ] && break
        probe_dir="$parent"
    done
    [ -d "$probe_dir" ] || return 0

    # Resolve to the PHYSICAL path before probing. `git check-ignore` refuses any
    # pathspec that traverses a symlink ("fatal: … is beyond a symbolic link"),
    # and that refusal reads as "not ignored" → the guard fail-closes on a
    # directory that is in fact perfectly well ignored. That is not a hypothetical:
    # `pl issue work` deliberately symlinks sites/ into every issue worktree, so
    # EVERY `pl backup --remote` run from a worktree hit this. The physical path is
    # also the one that actually matters — `git add -A` sees the real location, not
    # the symlink — so resolving makes the check both correct and stricter.
    local probe_real
    probe_real="$(cd "$probe_dir" 2>/dev/null && pwd -P)" || return 1
    [ -n "$probe_real" ] || return 1
    probe_dir="$probe_real"

    local toplevel
    toplevel="$(git -C "$probe_dir" rev-parse --show-toplevel 2>/dev/null)" || return 0
    [ -n "$toplevel" ] || return 0

    # No remote means nothing to publish to; a local-only repo is not a
    # disclosure path.
    local remotes
    remotes="$(git -C "$toplevel" remote 2>/dev/null)"
    [ -n "$remotes" ] || return 0

    # Already-published payloads are a DIFFERENT finding from a committable one,
    # and they get a different severity. Refusing here would break the nightly
    # backup for exactly the site that most needs one, and the operator cannot
    # clear the finding without a history rewrite on the forge. So: loud, and
    # repeated every run, but never fatal.
    local exposure
    if exposure="$(containment_check_tracked_repo "$toplevel" 2>/dev/null)"; then
        : # nothing already published
    else
        echo "WARNING: this backup repository has ALREADY published payloads." >&2
        printf '%s\n' "$exposure" | sed 's/^/  /' >&2
        echo "  Ignore rules cannot retract these — they are already in the history," >&2
        echo "  and on the remote. Clearing them is 'git filter-repo' + force-push," >&2
        echo "  a history rewrite on a remote, which stays operator-gated." >&2
        echo "  Report: pl site gitignore --exposed" >&2
    fi

    local committable=() p
    for p in nwp-containment-probe.sql nwp-containment-probe.sql.gz nwp-containment-probe.tar.gz; do
        if ! git -C "$probe_dir" check-ignore -q "${probe_dir}/${p}" 2>/dev/null; then
            committable+=("$p")
        fi
    done

    # SELF-REMEDIATION: when the backup directory IS the repository root (the
    # sites/<n>/backups/ shape that lib/git.sh created), the containment block
    # can simply be installed and the backup allowed to proceed. Installing an
    # ignore rule is additive and cannot untrack an already-tracked file, so
    # this is safe and it keeps the nightly sweep working. Anything else — a
    # backup dir buried inside a site or profile repo — still fails closed.
    if [ "${#committable[@]}" -gt 0 ] && [ "$toplevel" = "$probe_dir" ]; then
        if containment_fix_repo "$probe_dir" backups 2>/dev/null; then
            committable=()
            for p in nwp-containment-probe.sql nwp-containment-probe.sql.gz nwp-containment-probe.tar.gz; do
                if ! git -C "$probe_dir" check-ignore -q "${probe_dir}/${p}" 2>/dev/null; then
                    committable+=("$p")
                fi
            done
            if [ "${#committable[@]}" -eq 0 ]; then
                echo "NOTE: installed the nwp containment block in ${probe_dir}/.gitignore" >&2
                echo "      (backup payloads were committable in a repo with a remote)." >&2
                echo "      Already-committed artifacts are unaffected — removing those is a" >&2
                echo "      history rewrite and stays operator-gated." >&2
                return 0
            fi
        fi
    fi

    if [ "${#committable[@]}" -gt 0 ]; then
        echo "ERROR: refusing to write backups into a publishable git work tree." >&2
        echo "  backup dir : $dir" >&2
        echo "  work tree  : $toplevel" >&2
        echo "  remote(s)  : $(printf '%s ' $remotes)" >&2
        echo "  committable: ${committable[*]}" >&2
        echo "" >&2
        echo "  Backups hold UNSANITISED member data. Writing them where a" >&2
        echo "  'git add -A' would stage them puts production data one command" >&2
        echo "  away from the forge." >&2
        echo "" >&2
        echo "  Fix:      pl site gitignore --fix" >&2
        echo "  Override: NWP_ALLOW_BACKUP_IN_REPO=1 (recorded, one release only)" >&2
        return 1
    fi

    return 0
}
