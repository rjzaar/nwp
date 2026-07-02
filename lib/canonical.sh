#!/bin/bash
################################################################################
# lib/canonical.sh — canonicality phases + content-flow guards (nwp/ops#33)
#
# A site moves through canonicality phases; WHICH HOST IS CANONICAL governs
# where content may change and which way sync flows:
#
#   canonical: dev   — dev DB is the source of truth (no real audience yet).
#                      dev→live content pushes ALLOWED (dev overwrites live).
#   canonical: live  — live is the source of truth. Content changes on live
#                      only; dev receives a SANITIZED copy (live→dev).
#                      dev→live CONTENT pushes are REFUSED (would clobber the
#                      canonical source). Code/config-only deploys still flow.
#   canonical: prod  — prod is the source. live/dev are downstream sanitized
#                      copies; additionally code work is branch-only with a
#                      protected, CI-gated main (ADR-0024).
#
# The phase lives in the global nwp.yml per site (sites.<name>.canonical) and
# is ENFORCED here, not just documented: guard functions below are called by
# the deploy commands (stg2live, stg2prod, live2prod, dev2stg). Absent field
# defaults to "dev" (today's behavior); an unparseable value FAILS CLOSED —
# every guard allows only exact, known-safe phases.
#
# Transitions are explicit operator actions: `pl canonical set <site> <phase>`
# (scripts/commands/canonical.sh) records who/when in nwp.yml and appends to
# an append-only ledger in private/canonical/<site>.log.
################################################################################

# Requires: lib/ui.sh (print_*), lib/yaml-write.sh (yaml_get_site_field).
# Source yaml-write.sh ourselves if the caller hasn't (ui.sh has no such
# self-heal because every command sources it first thing).
_canonical_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v yaml_get_site_field >/dev/null 2>&1; then
    # shellcheck source=yaml-write.sh
    source "$_canonical_lib_dir/yaml-write.sh"
fi

CANONICAL_PHASES="dev live prod"

# Global nwp.yml (user config, never committed). NWP_YML override exists so
# tests can point at a fixture without cd-ing into a repo root.
canonical_config_file() {
    echo "${NWP_YML:-${PROJECT_ROOT:-$HOME/nwp}/nwp.yml}"
}

canonical_ledger_dir() {
    echo "${PROJECT_ROOT:-$HOME/nwp}/private/canonical"
}

canonical_actor() {
    echo "$(id -un)@$(hostname -s 2>/dev/null || hostname)"
}

# Echo the site's phase. Absent/unregistered → "dev" (back-compat default);
# present but not dev|live|prod → "invalid:<raw>" so guards fail closed.
# Always returns 0 (callers run under set -e); use canonical_phase_is_explicit
# to distinguish an explicit "dev" from the default.
canonical_get_phase() {
    local site="$1"
    local config="${2:-$(canonical_config_file)}"
    local raw=""
    if [ -n "$site" ] && [ -f "$config" ]; then
        raw=$(yaml_get_site_field "$site" "canonical" "$config" 2>/dev/null || true)
    fi
    case "$raw" in
        dev|live|prod) echo "$raw" ;;
        "")            echo "dev" ;;
        *)             echo "invalid:$raw" ;;
    esac
    return 0
}

# 0 if sites.<site>.canonical is present and valid in nwp.yml
canonical_phase_is_explicit() {
    local site="$1"
    local config="${2:-$(canonical_config_file)}"
    [ -f "$config" ] || return 1
    local raw
    raw=$(yaml_get_site_field "$site" "canonical" "$config" 2>/dev/null || true)
    case "$raw" in
        dev|live|prod) return 0 ;;
        *)             return 1 ;;
    esac
}

# Append-only transition/override ledger (private/, never committed)
canonical_ledger_append() {
    local site="$1"; shift
    local dir; dir="$(canonical_ledger_dir)"
    mkdir -p "$dir"
    echo "$(date -u +%FT%TZ) who=$(canonical_actor) $*" >> "$dir/${site}.log"
}

################################################################################
# Guards — called by nwp processes, not just documented
################################################################################

# Guard a CONTENT push toward <target>. Returns 0 = allowed, 1 = refused.
#   $1 site, $2 target (live|prod), $3 override (true|false), $4 cmd label
# Rules:
#   target=live: allowed only when canonical: dev (dev is the source).
#   target=prod: refused only when canonical: prod (content changes on prod
#                only); the live→prod push is the cutover path under dev/live.
# --override escape: proceeds with a loud warning + a ledger record of
# who/when/what — the clobber is then an audited operator decision.
canonical_guard_content_push() {
    local site="$1"
    local target="$2"
    local override="${3:-false}"
    local cmd="${4:-content-push}"

    local phase; phase=$(canonical_get_phase "$site")
    case "$target" in
        live) [ "$phase" = "dev" ] && return 0 ;;
        prod) case "$phase" in dev|live) return 0 ;; esac ;;
        *) print_error "canonical_guard_content_push: unknown target '$target'"; return 1 ;;
    esac

    case "$phase" in
        invalid:*)
            print_error "Site '$site' has an unrecognized canonical phase in nwp.yml: '${phase#invalid:}'"
            print_error "Guards fail closed on unparseable phases. Fix it: pl canonical set $site <dev|live|prod>"
            ;;
    esac

    if [ "$override" = "true" ]; then
        echo "" >&2
        print_warning "════════════════════════════════════════════════════════════════"
        print_warning "CANONICAL OVERRIDE: pushing content to $target while '$site' is"
        print_warning "canonical: $phase — this OVERWRITES the canonical content source."
        print_warning "This action is recorded in private/canonical/${site}.log."
        print_warning "════════════════════════════════════════════════════════════════"
        echo "" >&2
        canonical_ledger_append "$site" "action=override cmd=$cmd target=$target phase=$phase"
        return 0
    fi

    print_error "REFUSED: '$site' is canonical: $phase — content changes belong on $phase."
    print_error "A $cmd content push would clobber the canonical $phase content."
    print_info  "The supported flow while canonical: $phase is a SANITIZED pull toward dev:"
    print_info  "  pl live2stg $site          # sanitized live → stg"
    print_info  "  pl import $site            # pull from the canonical host"
    if [ "$target" = "live" ]; then
        print_info "Code/config-only deploys are still allowed: re-run with --code-only."
    fi
    print_info  "To push content anyway (clobbers $phase): re-run with --override-canonical."
    return 1
}

# When canonical != dev, content authored on dev is throwaway — surface it.
canonical_warn_dev_content() {
    local site="$1"
    local phase; phase=$(canonical_get_phase "$site")
    [ "$phase" = "dev" ] && return 0
    print_warning "'$site' is canonical: $phase — content authored on dev/stg is THROWAWAY."
    print_warning "It will be overwritten by the next sanitized $phase→dev refresh and can never be pushed to $phase."
    return 0
}

# canonical: prod ⇒ branch-only work + deploys from clean main (ADR-0024).
#   $1 site, $2 mode: "work" (dev2stg) | "deploy" (stg2live/stg2prod/live2prod)
#   work:   refuse UNCOMMITTED changes sitting on main (work belongs on a
#           branch); committed main state and feature branches are fine.
#   deploy: refuse anything that is not a CLEAN checkout of main/master —
#           deploys must come from the CI-gated protected main, not from an
#           unmerged branch or a dirty tree.
# If the site has no resolvable dev git repo the policy can't be evaluated:
# warn and allow (the content-push guard above remains the hard gate).
canonical_enforce_branch_policy() {
    local site="$1"
    local mode="${2:-deploy}"

    local phase; phase=$(canonical_get_phase "$site")
    [ "$phase" = "prod" ] || return 0

    local dev_dir=""
    if command -v resolve_project >/dev/null 2>&1; then
        dev_dir=$(resolve_project "$site" "dev" 2>/dev/null || true)
    fi
    if [ -z "$dev_dir" ] || [ ! -d "$dev_dir/.git" ]; then
        print_warning "canonical: prod branch policy: no git repo found for '$site' dev — cannot verify branch-only rule."
        return 0
    fi

    local branch dirty=false
    branch=$(git -C "$dev_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    [ -n "$(git -C "$dev_dir" status --porcelain 2>/dev/null)" ] && dirty=true

    if [ "$mode" = "work" ]; then
        if { [ "$branch" = "main" ] || [ "$branch" = "master" ]; } && [ "$dirty" = "true" ]; then
            print_error "REFUSED: '$site' is canonical: prod — main is protected; work on branches only."
            print_error "The dev repo ($dev_dir) has uncommitted changes directly on '$branch'."
            print_info  "Move the work to a branch: git -C $dev_dir switch -c <feature-branch>"
            return 1
        fi
        return 0
    fi

    # mode=deploy
    if [ "$branch" != "main" ] && [ "$branch" != "master" ]; then
        print_error "REFUSED: '$site' is canonical: prod — deploys must come from the CI-gated main."
        print_error "The dev repo ($dev_dir) is on branch '$branch'. Merge via MR (protected main), then deploy."
        return 1
    fi
    if [ "$dirty" = "true" ]; then
        print_error "REFUSED: '$site' is canonical: prod — deploys must come from a CLEAN main."
        print_error "The dev repo ($dev_dir) has uncommitted changes. Commit via a branch + MR, or stash."
        return 1
    fi
    return 0
}

################################################################################
# Manifest stamping — every backup/deploy records the phase it ran under
################################################################################

# Write a deploy manifest JSON stamped with the canonical phase.
#   $1 site, $2 action (stg2live|dev2stg|...), remaining args: key=value extras
# Output path: private/deploys/<site>/<action>-<utc-ts>.json (echoed).
canonical_deploy_manifest() {
    local site="$1"
    local action="$2"
    shift 2

    local dir="${PROJECT_ROOT:-$HOME/nwp}/private/deploys/${site}"
    mkdir -p "$dir"
    local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
    local file="$dir/${action}-${ts}.json"

    local nwp_sha=""
    if [ -d "${PROJECT_ROOT:-$HOME/nwp}/.git" ]; then
        nwp_sha=$(git -C "${PROJECT_ROOT:-$HOME/nwp}" rev-parse HEAD 2>/dev/null || true)
    fi

    {
        printf '{\n'
        printf '  "site": "%s",\n' "$site"
        printf '  "action": "%s",\n' "$action"
        printf '  "canonical_phase": "%s",\n' "$(canonical_get_phase "$site")"
        printf '  "timestamp": "%s",\n' "$(date -u +%FT%TZ)"
        printf '  "by": "%s",\n' "$(canonical_actor)"
        printf '  "nwp_sha": "%s"' "$nwp_sha"
        local kv
        for kv in "$@"; do
            printf ',\n  "%s": "%s"' "${kv%%=*}" "${kv#*=}"
        done
        printf '\n}\n'
    } > "$file"

    echo "$file"
}
