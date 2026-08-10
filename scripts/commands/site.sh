#!/usr/bin/env bash
# scripts/commands/site.sh
#
# `pl site` subcommand family: manages per-site configuration files
# (.nwp.yml) and schema migrations.
#
# Usage:
#   pl site list                    List all sites with .nwp.yml and their schema version
#   pl site show <site>             Print the .nwp.yml for a site
#   pl site migrate <site>          Migrate one site's .nwp.yml to current schema
#   pl site migrate --all           Migrate every site that has a .nwp.yml
#   pl site init <site>             Generate a .nwp.yml for an existing site from nwp.yml
#   pl site init --all              Generate .nwp.yml for every real site (Phase 1 bulk init)
#   pl site schema                  Print the current expected schema version

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NWP_DIR="$PROJECT_ROOT"

# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/migrate-schema.sh"

# Version is used by migrations to stamp nwp_version_updated
if [[ -z "${NWP_VERSION:-}" ]]; then
    NWP_VERSION=$(grep -E '^VERSION=' "$PROJECT_ROOT/pl" | head -1 | sed 's/.*="\(.*\)"/\1/')
fi
export NWP_VERSION NWP_DIR

YQ="${YQ_BIN:-yq}"
if ! command -v "$YQ" &>/dev/null; then
    if [[ -x "$HOME/.local/bin/yq" ]]; then
        YQ="$HOME/.local/bin/yq"
    else
        echo "ERROR: yq is required but was not found." >&2
        echo "Install from https://github.com/mikefarah/yq" >&2
        exit 1
    fi
fi

################################################################################
# Helpers
################################################################################

# Sites to skip during bulk operations (generated, scratch, verify-test, etc.)
_site_is_skippable() {
    local name="$1"
    case "$name" in
        tmp|latest|vendor)               return 0 ;;
        *_moodledata)                    return 0 ;;  # Moodle data dirs (sibling to Moodle sites)
        20260117T212337-no-git-no-git)   return 0 ;;
        verify-test*)                    return 0 ;;
        bats-test-*)                     return 0 ;;
        trace-del*)                      return 0 ;;
        *-stg)                           return 0 ;;  # staging clones
        *) return 1 ;;
    esac
}

# Does this site exist on disk as a real project directory?
_site_exists_on_disk() {
    local name="$1"
    [[ -d "$PROJECT_ROOT/sites/$name" ]]
}

# Infer project.type from recipe name.
# drupal | moodle
# (Standalone projects ship their own .nwp.yml with project.type set explicitly.)
_infer_project_type() {
    local recipe="$1"
    case "$recipe" in
        m|moodle*) echo "moodle" ;;
        "") echo "drupal" ;;
        *) echo "drupal" ;;
    esac
}

# Extract a site's data from nwp.yml as a sub-document, or empty if absent.
_extract_site_from_global() {
    local site="$1"
    "$YQ" eval ".sites.\"$site\" // {}" "$PROJECT_ROOT/nwp.yml" 2>/dev/null || echo "{}"
}

# Write .nwp.yml for a single site.
# Reads existing values out of nwp.yml where possible, applies defaults
# for everything else.
_generate_site_config() {
    local site="$1"
    local force="${2:-0}"
    local site_dir="$PROJECT_ROOT/sites/$site"
    local config="$site_dir/.nwp.yml"

    if [[ ! -d "$site_dir" ]]; then
        echo "  ! $site — directory not found at $site_dir (skipping)"
        return 1
    fi

    if [[ -f "$config" && "$force" != "1" ]]; then
        echo "  = $site — already has .nwp.yml (use --force to overwrite)"
        return 0
    fi

    # ABSENT BY CONTEXT vs PRESENT BUT UNREADABLE (lib/canonical.sh:51-64).
    # A fresh clone, CI and a linked worktree all legitimately have no global
    # nwp.yml, and every read below already carries a `// <default>`. What they
    # did not have was a file for yq to open, so under `set -euo pipefail` this
    # verb died on the library's own message — `Error: open …/nwp.yml: no such
    # file or directory`, exit 1, not one word of NWP's own — for the FIRST-EVER
    # site, which is precisely when there is nothing to read from anyway. The
    # `--all` path below already tolerated it (`2>/dev/null || true`); the
    # single-site path did not. Read from an empty document instead, and say so
    # ONCE, so nobody mistakes the defaults for values somebody recorded.
    local gcfg="$PROJECT_ROOT/nwp.yml"
    if [[ ! -f "$gcfg" ]]; then
        echo "  · global nwp.yml is NOT CREATED YET at $gcfg"
        echo "    Normal in a fresh clone, CI or a linked worktree. Writing $site/.nwp.yml"
        echo "    from DEFAULTS, not from recorded values.  (create one: pl setup)"
        gcfg=/dev/null
    fi

    # Pull fields from the existing global nwp.yml
    local recipe environment created purpose
    recipe=$("$YQ" eval ".sites.\"$site\".recipe // \"\"" "$gcfg")
    environment=$("$YQ" eval ".sites.\"$site\".environment // \"development\"" "$gcfg")
    created=$("$YQ" eval ".sites.\"$site\".created // \"\"" "$gcfg")
    purpose=$("$YQ" eval ".sites.\"$site\".purpose // \"indefinite\"" "$gcfg")

    # Timestamp if created is empty
    if [[ -z "$created" || "$created" == "null" ]]; then
        created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    fi

    local project_type
    project_type=$(_infer_project_type "$recipe")

    # live.* subfields
    local live_enabled live_domain live_server_ip live_linode_id live_remote_dir live_type
    live_enabled=$("$YQ" eval ".sites.\"$site\".live.enabled // false" "$gcfg")
    live_domain=$("$YQ" eval ".sites.\"$site\".live.domain // \"\"" "$gcfg")
    live_server_ip=$("$YQ" eval ".sites.\"$site\".live.server_ip // \"\"" "$gcfg")
    live_linode_id=$("$YQ" eval ".sites.\"$site\".live.linode_id // \"\"" "$gcfg")
    live_remote_dir=$("$YQ" eval ".sites.\"$site\".live.remote_dir // \"\"" "$gcfg")
    live_type=$("$YQ" eval ".sites.\"$site\".live.type // \"\"" "$gcfg")

    # Default remote_path: /var/www/<remote_dir or site>
    local remote_path=""
    if [[ -n "$live_domain" && "$live_domain" != "null" ]]; then
        if [[ -n "$live_remote_dir" && "$live_remote_dir" != "null" ]]; then
            remote_path="/var/www/$live_remote_dir"
        else
            remote_path="/var/www/$site"
        fi
    fi

    # Server name: resolve from the IP by scanning the server registry, so this
    # works for ANY configured server (not just the original box) — multi-server
    # audit H3, 2026-07-31.
    local server_name="" _s
    if [[ -n "$live_server_ip" && "$live_server_ip" != "YOUR_SERVER_IP" ]]; then
        for _s in $(discover_servers 2>/dev/null); do
            if [[ "$(get_server_ip "$_s" 2>/dev/null)" == "$live_server_ip" ]]; then
                server_name="$_s"; break
            fi
        done
    fi

    # Begin writing the file (atomic: tmp then mv)
    local tmp
    tmp=$(mktemp "${config}.new.XXXXXX")

    {
        cat <<EOF
# ~/nwp/sites/$site/.nwp.yml
# Per-site configuration — generated by 'pl site init' (F23 Phase 1).
# schema_version is the config schema this file conforms to; run
# 'pl site migrate $site' after upgrading NWP if it lags behind.

schema_version: 1
nwp_version_created: "$NWP_VERSION"
nwp_version_updated: "$NWP_VERSION"

project:
  name: $site
  type: $project_type
EOF

        if [[ -n "$recipe" && "$recipe" != "null" ]]; then
            echo "  recipe: $recipe"
        fi

        cat <<EOF
  environment: $environment
  purpose: $purpose
  created: "$created"

EOF

        # live: section
        if [[ "$live_enabled" == "true" && -n "$live_domain" && "$live_domain" != "null" ]]; then
            cat <<EOF
live:
  enabled: true
  domain: $live_domain
EOF
            if [[ -n "$server_name" ]]; then
                echo "  server: $server_name"
            fi
            if [[ -n "$live_server_ip" && "$live_server_ip" != "null" ]]; then
                echo "  server_ip: $live_server_ip"
            fi
            if [[ -n "$live_linode_id" && "$live_linode_id" != "null" ]]; then
                echo "  linode_id: $live_linode_id"
            fi
            if [[ -n "$live_type" && "$live_type" != "null" ]]; then
                echo "  type: $live_type"
            fi
            if [[ -n "$remote_path" ]]; then
                echo "  remote_path: $remote_path"
            fi
            echo ""
        else
            cat <<EOF
live:
  enabled: false

EOF
        fi

        # Per-site backup section
        cat <<EOF
backups:
  directory: ./backups
EOF

        # Site-specific nested config (e.g., mass_times for MT)
        if [[ "$site" == "mt" ]]; then
            local mt_settings
            mt_settings=$("$YQ" eval '.settings.mass_times // {}' "$gcfg")
            if [[ -n "$mt_settings" && "$mt_settings" != "{}" ]]; then
                echo ""
                echo "# Mass Times scraper settings (was settings.mass_times in nwp.yml)"
                echo "mass_times:"
                # Indent each line by two spaces
                "$YQ" eval '.settings.mass_times' "$gcfg" \
                    | sed 's/^/  /'
            fi
        fi

    } > "$tmp"

    mv "$tmp" "$config"
    echo "  + $site — wrote $config"
}

################################################################################
# Subcommands
################################################################################

cmd_list() {
    local any=0
    printf "%-20s %-10s %-10s %s\n" "SITE" "SCHEMA" "STATUS" "CONFIG"
    printf "%-20s %-10s %-10s %s\n" "----" "------" "------" "------"
    for dir in "$PROJECT_ROOT/sites"/*/; do
        [[ -d "$dir" ]] || continue
        local name
        name=$(basename "$dir")
        _site_is_skippable "$name" && continue
        local config="$dir/.nwp.yml"
        local sv="-" status="no-config"
        if [[ -f "$config" ]]; then
            sv=$("$YQ" eval '.schema_version // 0' "$config")
            if [[ "$sv" -ge "$CURRENT_SITE_SCHEMA" ]]; then
                status="current"
            else
                status="stale"
            fi
            any=1
        fi
        local rel="${config#$PROJECT_ROOT/}"
        rel="${rel//\/\//\/}"
        printf "%-20s %-10s %-10s %s\n" "$name" "$sv" "$status" "$rel"
    done
    if [[ "$any" == "0" ]]; then
        echo ""
        echo "No sites have a .nwp.yml yet. Run: pl site init --all"
    fi
}

cmd_show() {
    local site="${1:-}"
    if [[ -z "$site" ]]; then
        echo "Usage: pl site show <site>" >&2
        return 1
    fi
    local config="$PROJECT_ROOT/sites/$site/.nwp.yml"
    if [[ ! -f "$config" ]]; then
        echo "ERROR: $config not found" >&2
        return 1
    fi
    cat "$config"
}

################################################################################
# Containment (nested-repo credential + payload containment)
################################################################################

# pl site gitignore [--check|--fix] [--site=<name>]
#
# The v2 layout puts real git repos at sites/<n>/{dev,stg,backups}/.git and
# deeper (profiles/custom/*, .plugin-src/*). The repo-root gitleaks gate and
# pre-commit hook cover none of them, so containment has to be a property of
# each nested repo's own ignore rules. Rules come from
# templates/site-gitignore.tmpl via lib/site-containment.sh.
cmd_gitignore() {
    local mode="check" only_site=""
    local a
    for a in "$@"; do
        case "$a" in
            --check)      mode="check" ;;
            --fix)        mode="fix" ;;
            --exposed)    mode="exposed" ;;
            --all)        mode="all" ;;
            --site=*)     only_site="${a#--site=}" ;;
            -h|--help)
                cat <<'EOF'
Usage: pl site gitignore [--check|--fix|--exposed|--all] [--site=<name>]

Containment has two halves, and they need different answers:

  FUTURE  "could a sensitive path still be committed here?"
  PAST    "was one already committed — and pushed?"

  --check          FUTURE. Report every nested repo where a sensitive path
                   would be committable (default). Non-zero if any are, and
                   non-zero if the scan finds NO repos at all ("cannot verify").
  --fix            Idempotently install the managed containment block into
                   each leaky repo's .gitignore. Never removes an existing
                   rule; never untracks an already-tracked file.
  --exposed        PAST. Report already-TRACKED payloads (dumps, tarballs,
                   settings.php, private keys) and the remote they are
                   published to. --fix CANNOT clear these: git does not
                   consult .gitignore for a path it already tracks. Clearing
                   them is `git filter-repo` + force-push, a history rewrite
                   on a remote, which stays operator-gated.
  --all            Both halves. Non-zero if either is non-zero.
  --site=<name>    Restrict to one site.

Checks are behavioural: each probe path is put to `git check-ignore`, so a
comment cannot satisfy the gate and an equivalently-written rule still passes.
EOF
                return 0 ;;
            *) echo "Unknown option: $a" >&2; return 1 ;;
        esac
    done

    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/lib/site-containment.sh"

    local root="$PROJECT_ROOT/sites"
    [[ -n "$only_site" ]] && root="$PROJECT_ROOT/sites/$only_site"

    if [[ ! -d "$root" ]]; then
        echo "ERROR: no such path: $root" >&2
        return 2
    fi

    local repos=() r
    while IFS= read -r r; do
        [[ -n "$r" ]] && repos+=("$r")
    done < <(containment_discover_repos "$root")

    if [[ "${#repos[@]}" -eq 0 ]]; then
        echo "CANNOT VERIFY: no git repositories found under '$root'."
        echo "  A containment sweep that scanned nothing has verified nothing."
        return 3
    fi

    # PAST half — already-tracked, already-published payloads.
    local exposed=0
    if [[ "$mode" == "exposed" || "$mode" == "all" ]]; then
        local report
        for r in "${repos[@]}"; do
            if report="$(containment_check_tracked_repo "$r" 2>/dev/null)"; then
                continue
            fi
            exposed=$((exposed + 1))
            printf '%s\n' "$report" | sed "s|$PROJECT_ROOT/||"
        done
        echo ""
        echo "scanned ${#repos[@]} nested repositories under '${root#$PROJECT_ROOT/}'"
        echo "already-published payloads: ${exposed} repo(s)"
        if [[ "$exposed" -gt 0 ]]; then
            echo ""
            echo "These CANNOT be cleared by --fix. Removing them is a history rewrite"
            echo "on a remote (git filter-repo + force-push) and is operator-gated."
        fi
        if [[ "$mode" == "exposed" ]]; then
            [[ "$exposed" -eq 0 ]]
            return
        fi
        echo ""
    fi

    local leaky=0 fixed=0
    for r in "${repos[@]}"; do
        local kind
        kind="$(containment_repo_kind "$r")"
        if containment_check_repo "$r" "$kind" >/dev/null 2>&1; then
            continue
        fi
        leaky=$((leaky + 1))
        if [[ "$mode" == "fix" ]]; then
            if containment_fix_repo "$r" "$kind"; then
                echo "FIXED     ${r#$PROJECT_ROOT/}  (${kind})"
                fixed=$((fixed + 1))
            else
                echo "FAILED    ${r#$PROJECT_ROOT/}  (${kind})" >&2
            fi
        else
            containment_check_repo "$r" "$kind" | sed "s|$PROJECT_ROOT/||"
        fi
    done

    echo ""
    echo "scanned ${#repos[@]} nested repositories under '${root#$PROJECT_ROOT/}'"
    if [[ "$mode" == "fix" ]]; then
        echo "leaky: ${leaky}   fixed: ${fixed}"
        [[ "$fixed" -eq "$leaky" ]] || return 1
        return 0
    fi
    echo "leaky: ${leaky}"
    if [[ "$mode" == "all" ]]; then
        [[ "$leaky" -eq 0 && "$exposed" -eq 0 ]]
        return
    fi
    [[ "$leaky" -eq 0 ]]
}

# pl site vcs [--site=<name>]
#
# Per nested repo: remote, branch, ahead/behind origin/main, detached HEAD,
# dirty count (-uall), stash count. Consumed by pl todo's containment check.
cmd_vcs() {
    local only_site=""
    local a
    for a in "$@"; do
        case "$a" in
            --site=*) only_site="${a#--site=}" ;;
            -h|--help)
                echo "Usage: pl site vcs [--site=<name>]"
                echo "Reports remote/branch/drift/dirty/stash state for every nested site repo."
                return 0 ;;
            *) echo "Unknown option: $a" >&2; return 1 ;;
        esac
    done

    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/lib/site-containment.sh"

    local root="$PROJECT_ROOT/sites"
    [[ -n "$only_site" ]] && root="$PROJECT_ROOT/sites/$only_site"

    local repos=() r
    while IFS= read -r r; do
        [[ -n "$r" ]] && repos+=("$r")
    done < <(containment_discover_repos "$root")

    if [[ "${#repos[@]}" -eq 0 ]]; then
        echo "CANNOT VERIFY: no git repositories found under '$root'." >&2
        return 3
    fi

    printf "%-46s %-22s %-7s %-7s %-6s %s\n" "REPO" "BRANCH" "DIRTY" "STASH" "AHEAD" "REMOTE"
    printf "%-46s %-22s %-7s %-7s %-6s %s\n" "----" "------" "-----" "-----" "-----" "------"

    local problems=0
    for r in "${repos[@]}"; do
        local rel="${r#$PROJECT_ROOT/}"
        local branch dirty stash remote ahead
        branch="$(git -C "$r" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
        [[ "$branch" == "HEAD" ]] && branch="(detached)"
        dirty="$(git -C "$r" status --porcelain -uall 2>/dev/null | wc -l | tr -d ' ')"
        stash="$(git -C "$r" stash list 2>/dev/null | wc -l | tr -d ' ')"
        remote="$(git -C "$r" remote get-url origin 2>/dev/null || echo '-')"
        ahead="$(git -C "$r" rev-list --count HEAD --not --remotes 2>/dev/null || echo '?')"

        printf "%-46s %-22s %-7s %-7s %-6s %s\n" \
            "$rel" "$branch" "$dirty" "$stash" "$ahead" "$remote"

        if [[ "$dirty" != "0" ]] || [[ "$stash" != "0" ]] || [[ "$branch" == "(detached)" ]]; then
            problems=$((problems + 1))
        fi
    done

    echo ""
    echo "${#repos[@]} nested repositories; ${problems} with uncommitted work, stashes or a detached HEAD"
    [[ "$problems" -eq 0 ]]
}

cmd_schema() {
    echo "Expected schema versions (this NWP build):"
    echo "  site    : $CURRENT_SITE_SCHEMA"
    echo "  global  : $CURRENT_GLOBAL_SCHEMA"
    echo "  server  : $CURRENT_SERVER_SCHEMA"
}

cmd_migrate() {
    local arg="${1:-}"
    if [[ -z "$arg" ]]; then
        echo "Usage: pl site migrate <site> | pl site migrate --all" >&2
        return 1
    fi
    if [[ "$arg" == "--all" ]]; then
        migrate_all_sites
    else
        migrate_site "$arg"
    fi
}

cmd_init() {
    local force=0
    local target=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) target="__all__" ;;
            --force|-f) force=1 ;;
            -*) echo "Unknown flag: $1" >&2; return 1 ;;
            *) target="$1" ;;
        esac
        shift
    done

    if [[ -z "$target" ]]; then
        echo "Usage: pl site init <site> [--force]" >&2
        echo "       pl site init --all [--force]" >&2
        return 1
    fi

    if [[ "$target" == "__all__" ]]; then
        echo "Generating .nwp.yml for all real sites..."
        # Known real sites to seed:
        #   - Anything defined in nwp.yml with a valid recipe and an on-disk dir
        #   - Plus cccrdf (on disk, absent from nwp.yml — treat as experimental)
        local real_sites=()
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            _site_is_skippable "$name" && continue
            _site_exists_on_disk "$name" || continue
            real_sites+=("$name")
        done < <("$YQ" eval '.sites | keys | .[]' "$PROJECT_ROOT/nwp.yml" 2>/dev/null || true)

        # Also include sites present on disk but absent from nwp.yml
        for dir in "$PROJECT_ROOT/sites"/*/; do
            [[ -d "$dir" ]] || continue
            local name
            name=$(basename "$dir")
            _site_is_skippable "$name" && continue
            # Only include if it looks like a real project (composer.json
            # at root OR a web/ or html/ subdir)
            if [[ -f "$dir/composer.json" || -d "$dir/web" || -d "$dir/html" ]]; then
                local already=0
                for existing in "${real_sites[@]}"; do
                    [[ "$existing" == "$name" ]] && already=1 && break
                done
                [[ "$already" == "0" ]] && real_sites+=("$name")
            fi
        done

        if [[ ${#real_sites[@]} -eq 0 ]]; then
            echo "No real sites found."
            return 0
        fi

        echo "Targets: ${real_sites[*]}"
        echo ""
        for s in "${real_sites[@]}"; do
            _generate_site_config "$s" "$force"
        done
    else
        _generate_site_config "$target" "$force"
    fi
}

################################################################################
# Main dispatch
################################################################################

main() {
    local sub="${1:-help}"
    shift || true
    case "$sub" in
        list) cmd_list "$@" ;;
        show) cmd_show "$@" ;;
        schema) cmd_schema "$@" ;;
        migrate) cmd_migrate "$@" ;;
        init) cmd_init "$@" ;;
        gitignore) cmd_gitignore "$@" ;;
        vcs) cmd_vcs "$@" ;;
        help|--help|-h|"")
            cat <<'EOF'
Usage: pl site <subcommand> [args]

Subcommands:
  list                      List sites with schema status
  show <site>               Print a site's .nwp.yml
  schema                    Show expected schema versions
  init <site> [--force]     Generate .nwp.yml from nwp.yml data
  init --all [--force]      Generate .nwp.yml for every real site
  migrate <site>            Run schema migrations for one site
  migrate --all             Run schema migrations for every site

Containment (nested per-site git repos):
  gitignore [--check]       Report nested repos where a credential or a backup
                            payload would be committable (default; non-zero on
                            any finding AND on an empty scan)
  gitignore --fix           Install the managed containment block from
                            templates/site-gitignore.tmpl (idempotent, additive)
  vcs                       Per nested repo: branch, dirty count, stashes,
                            unpushed commits, remote

Part of F23 (project separation v2). See docs/proposals/F23-project-separation-v2.md.
EOF
            ;;
        *)
            echo "Unknown pl site subcommand: $sub" >&2
            echo "Run 'pl site help' for usage." >&2
            return 1
            ;;
    esac
}

main "$@"
