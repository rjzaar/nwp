#!/bin/bash
set -euo pipefail

################################################################################
# pl branch — branched twin sites (P67 §5c / nwp/ops#48)
#
# A twin is a disposable copy of a site's dev project on its own git branch,
# for working with an AI/coder in parallel while the real site keeps serving.
# Twins are deploy-incapable BY CONSTRUCTION: registered with purpose:testing
# and no live: block, linked to their parent via branch_of/branch, and their
# content provenance is stamped (content_source/content_as_of) so pl status
# can say what the content is and how old.
#
#   pl branch <site> <git-ref> [--name=<twin>] [--content=parent|fresh]
#   pl branch list [<site>]
#   pl branch content <twin> --from=parent
#   pl branch merge <twin>
#   pl branch delete <twin>
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/yaml-write.sh"
source "$PROJECT_ROOT/lib/canonical.sh"
# impact.sh: consistent confirmation tiers (the only rm -rf here removes the
# twin's own partial copy on a failed create; real deletion delegates to
# delete.sh, which carries the full fate-manifest contract)
source "$PROJECT_ROOT/lib/impact.sh"

show_help() {
    cat << EOF
${BOLD}pl branch${NC} — branched twin sites (work on a branch while the real site serves)

${BOLD}USAGE:${NC}
    pl branch <site> <git-ref> [options]   Create a twin of <site>'s dev project
                                           on branch <git-ref>
    pl branch list [<site>]                Tree view: parents with twins nested,
                                           code Δ vs origin/main, content provenance
    pl branch content <twin> --from=parent Refresh the twin's DB from its parent
                                           (re-stamps provenance)
    pl branch merge <twin>                 Push the twin's branch + print the MR
                                           URL (never merges anything itself)
    pl branch delete <twin>                Delete the twin (delegates to pl delete
                                           — impact report + archived backups)

${BOLD}OPTIONS (create):${NC}
    --name=<twin>       Twin site name (default: <site>-<ref-slug>)
    --content=parent    Copy the parent's dev DB into the twin (default)
    --content=fresh     No DB copy — twin starts empty (installer's job)
    --no-start          Copy + register + branch only; skip ddev start/import
                        (finish later with: cd sites/<twin>/dev && ddev start)
    -y, --yes           Skip confirmation

${BOLD}PROPERTIES OF A TWIN:${NC}
    • registered with purpose: testing, branch_of: <parent>, NO live: block —
      it cannot deploy anywhere, even by accident
    • its content is throwaway (provenance stamped, shown in pl status)
    • code merges home via git: push branch → MR → merge → the REAL site
      receives it per its maturity class (pl maturity)

${BOLD}EXAMPLE:${NC}
    pl branch nwc feat/big-idea         # → sites/nwc-big-idea on that branch
    ... work with Claude on the twin ...
    pl branch merge nwc-big-idea        # push + MR URL
    pl branch delete nwc-big-idea       # done; backups auto-archived
EOF
}

# slugify a git ref for use in a site name: feat/big-idea → big-idea
_ref_slug() {
    basename "$1" | tr -c 'a-zA-Z0-9' '-' | sed 's/^-*//; s/-*$//' | cut -c1-20
}

cmd_create() {
    local parent="${1:-}"
    local ref="${2:-}"
    local twin="${3:-}"
    local content="${4:-parent}"
    local no_start="${5:-false}"
    local auto_yes="${6:-false}"
    local config; config=$(canonical_config_file)

    [ -n "$parent" ] && [ -n "$ref" ] || { print_error "Usage: pl branch <site> <git-ref> [--name=<twin>]"; return 1; }
    [ -n "$twin" ] || twin="${parent}-$(_ref_slug "$ref")"

    if ! yaml_validate_sitename "$twin"; then
        print_error "Derived twin name '$twin' is not a valid site name — pass --name=<twin>"
        return 1
    fi
    if [ -d "$PROJECT_ROOT/sites/$twin" ] || { [ -f "$config" ] && yaml_site_exists "$twin" "$config"; }; then
        print_error "Twin '$twin' already exists (directory or nwp.yml entry)"
        return 1
    fi

    local src_dev
    src_dev=$(resolve_project "$parent" "dev" 2>/dev/null) || src_dev=""
    if [ -z "$src_dev" ] || [ ! -d "$src_dev" ]; then
        print_error "Cannot resolve a dev project for '$parent'"
        return 1
    fi
    if [ ! -d "$src_dev/.git" ]; then
        print_error "'$parent' dev has no git repo — a branch twin needs one"
        return 1
    fi

    local twin_dev="$PROJECT_ROOT/sites/$twin/dev"
    local src_size; src_size=$(du -sh "$src_dev" 2>/dev/null | awk '{print $1}')

    print_header "Create branch twin: $parent → $twin"
    echo -e "  ${BOLD}Source:${NC}   $src_dev ($src_size)"
    echo -e "  ${BOLD}Twin:${NC}     $twin_dev"
    echo -e "  ${BOLD}Branch:${NC}   $ref"
    echo -e "  ${BOLD}Content:${NC}  $content"
    echo -e "  ${BOLD}Deploy:${NC}   incapable by construction (no live: block, purpose: testing)"
    echo ""

    if ! impact_confirm standard "create twin '$twin'" "$auto_yes"; then
        print_info "Aborted."
        return 1
    fi

    # 1. Copy the dev tree (includes .git — full history travels with the twin)
    print_info "Copying dev tree..."
    mkdir -p "$PROJECT_ROOT/sites/$twin"
    if ! cp -a "$src_dev" "$twin_dev"; then
        print_error "Copy failed — cleaning up"
        rm -rf "$PROJECT_ROOT/sites/$twin"
        return 1
    fi

    # 2. Branch
    print_info "Switching twin to branch '$ref'..."
    if git -C "$twin_dev" rev-parse --verify -q "$ref" >/dev/null 2>&1; then
        git -C "$twin_dev" switch -q "$ref"
    else
        git -C "$twin_dev" switch -q -c "$ref"
    fi

    # 3. Re-identify the DDEV project (the copied config still carries the
    #    parent's project name — a duplicate name would collide)
    local twin_project="${twin}-dev"
    if [ -f "$twin_dev/.ddev/config.yaml" ]; then
        sed -i "s/^name: .*/name: ${twin_project}/" "$twin_dev/.ddev/config.yaml"
    fi

    # 4. Register in nwp.yml with lineage + provenance
    if command -v yaml_add_site >/dev/null 2>&1 && [ -f "$config" ]; then
        local recipe
        recipe=$(yaml_get_site_field "$parent" "recipe" "$config" 2>/dev/null) || recipe="?"
        yaml_add_site "$twin" "$twin_dev" "${recipe:-?}" "development" "testing" "$config" >/dev/null 2>&1 || true
        yaml_set_site_field "$twin" "branch_of" "$parent" "$config" >/dev/null
        yaml_set_site_field "$twin" "branch" "$ref" "$config" >/dev/null
        # Provenance reflects what HAPPENED, not what was requested: at this
        # point no DB has been loaded, so the twin is "fresh". The actual
        # content load (_load_content_from_parent) re-stamps it.
        yaml_set_site_field "$twin" "content_source" "fresh" "$config" >/dev/null
    fi
    canonical_ledger_append "$twin" "action=branch-create parent=$parent ref=$ref content=$content"

    # 5. Start + content (skippable)
    if [ "$no_start" = "true" ]; then
        print_status "OK" "Twin created (not started — --no-start)"
        print_info "Finish with: cd $twin_dev && ddev start"
        [ "$content" = "parent" ] && print_info "Then load content: pl branch content $twin --from=parent"
        return 0
    fi

    print_info "Starting DDEV project '$twin_project'..."
    if ! (cd "$twin_dev" && ddev start >/dev/null 2>&1); then
        print_warning "ddev start failed — start it manually: cd $twin_dev && ddev start"
    elif [ "$content" = "parent" ]; then
        _load_content_from_parent "$twin" "$parent" || print_warning "Content load failed — retry: pl branch content $twin --from=parent"
    fi

    print_status "OK" "Twin '$twin' ready on branch '$ref'"
    print_info "Work there, then: pl branch merge $twin   (push + MR)"
    return 0
}

_load_content_from_parent() {
    local twin="$1"
    local parent="$2"

    local src_dev twin_dev
    src_dev=$(resolve_project "$parent" "dev" 2>/dev/null) || return 1
    twin_dev=$(resolve_project "$twin" "dev" 2>/dev/null) || twin_dev="$PROJECT_ROOT/sites/$twin/dev"

    local dump="/tmp/nwp-branch-${twin}-$$.sql.gz"
    print_info "Copying database $parent → $twin..."
    (cd "$src_dev" && ddev export-db --gzip --file="$dump") || return 1
    (cd "$twin_dev" && ddev import-db --file="$dump") || { rm -f "$dump"; return 1; }
    rm -f "$dump"
    (cd "$twin_dev" && ddev drush cr >/dev/null 2>&1) || true

    local config; config=$(canonical_config_file)
    yaml_set_site_field "$twin" "content_source" "parent" "$config" >/dev/null 2>&1 || true
    yaml_set_site_field "$twin" "content_as_of" "$(date -u +%FT%TZ)" "$config" >/dev/null 2>&1 || true
    canonical_ledger_append "$twin" "action=content-refresh from=parent"
    print_status "OK" "Content loaded from $parent (provenance stamped)"
    return 0
}

cmd_list() {
    local filter="${1:-}"
    local config; config=$(canonical_config_file)
    [ -f "$config" ] || { print_error "No nwp.yml found at $config"; return 1; }

    print_header "Branch twins"
    local sites; sites=$(yaml_get_all_sites "$config")
    local printed=0 site parent
    while read -r site; do
        [ -z "$site" ] && continue
        parent=$(site_branch_parent "$site" "$config")
        [ -n "$parent" ] && continue          # twins print under their parent
        [ -n "$filter" ] && [ "$site" != "$filter" ] && continue

        # does this parent have twins?
        local twins="" t tp
        while read -r t; do
            [ -z "$t" ] && continue
            tp=$(site_branch_parent "$t" "$config")
            [ "$tp" = "$site" ] && twins+="$t "
        done <<< "$sites"
        [ -z "$twins" ] && [ -n "$filter" ] || [ -n "$twins" ] || continue

        local pdir pbranch
        pdir=$(resolve_project "$site" "dev" 2>/dev/null) || pdir=""
        pbranch="?"
        [ -n "$pdir" ] && [ -d "$pdir/.git" ] && pbranch=$(git -C "$pdir" branch --show-current 2>/dev/null || echo "?")
        printf "  ${BOLD}%-20s${NC} %-24s %-10s %s\n" "$site" "$pbranch" "$(site_code_delta "$pdir")" "content: $(site_content_provenance "$site" "$config")"
        for t in $twins; do
            local tdir tbranch
            tdir=$(resolve_project "$t" "dev" 2>/dev/null) || tdir="$PROJECT_ROOT/sites/$t/dev"
            tbranch=$(git -C "$tdir" branch --show-current 2>/dev/null || echo "?")
            printf "   └─ %-16s %-24s %-10s %s\n" "$t" "$tbranch" "$(site_code_delta "$tdir")" "content: $(site_content_provenance "$t" "$config")"
        done
        printed=1
    done <<< "$sites"
    [ "$printed" = "1" ] || print_info "No branch twins found. Create one: pl branch <site> <git-ref>"
    echo ""
    print_info "Δ = commits vs origin/main (+ahead/-behind); '=' even; '?' no origin/main"
}

cmd_content() {
    local twin="${1:-}"
    local from="${2:-parent}"
    [ -n "$twin" ] || { print_error "Usage: pl branch content <twin> --from=parent"; return 1; }
    local config; config=$(canonical_config_file)
    local parent; parent=$(site_branch_parent "$twin" "$config")
    [ -n "$parent" ] || { print_error "'$twin' has no branch_of parent in nwp.yml"; return 1; }

    case "$from" in
        parent)
            _load_content_from_parent "$twin" "$parent"
            ;;
        live|prod)
            print_error "--from=$from is not implemented yet — use the parent's own pull first:"
            print_info  "  pl import $parent   (sanitized, default on)  then: pl branch content $twin --from=parent"
            return 1
            ;;
        demo)
            print_error "--from=demo is not implemented yet (needs the demo recipe seed; see ops#48)."
            return 1
            ;;
        *)
            print_error "Unknown --from=$from (parent|live|prod|demo)"
            return 1
            ;;
    esac
}

cmd_merge() {
    local twin="${1:-}"
    [ -n "$twin" ] || { print_error "Usage: pl branch merge <twin>"; return 1; }
    local config; config=$(canonical_config_file)
    local parent; parent=$(site_branch_parent "$twin" "$config")
    [ -n "$parent" ] || { print_error "'$twin' has no branch_of parent in nwp.yml"; return 1; }

    local tdir; tdir=$(resolve_project "$twin" "dev" 2>/dev/null) || tdir="$PROJECT_ROOT/sites/$twin/dev"
    [ -d "$tdir/.git" ] || { print_error "No git repo at $tdir"; return 1; }

    local branch; branch=$(git -C "$tdir" branch --show-current 2>/dev/null)
    [ -n "$branch" ] && [ "$branch" != "main" ] || { print_error "Twin is on '$branch' — nothing branch-like to merge"; return 1; }

    if [ -n "$(git -C "$tdir" status --porcelain 2>/dev/null)" ]; then
        print_error "Twin has uncommitted changes — commit them first."
        return 1
    fi
    if [ -z "$(git -C "$tdir" remote 2>/dev/null)" ]; then
        print_error "Twin repo has no git remote — add one (it should have inherited the parent's)."
        return 1
    fi

    print_info "Pushing '$branch'..."
    if git -C "$tdir" push -u origin "$branch" 2>&1 | tail -3; then
        print_status "OK" "Branch pushed. Open the MR from the URL above (or GitLab → New MR)."
        print_info "After merge, the REAL site ('$parent') receives it per its maturity class: pl maturity check $parent"
    else
        print_error "Push failed"
        return 1
    fi
}

cmd_delete() {
    local twin="${1:-}"; shift || true
    [ -n "$twin" ] || { print_error "Usage: pl branch delete <twin>"; return 1; }
    local config; config=$(canonical_config_file)
    local parent; parent=$(site_branch_parent "$twin" "$config")
    if [ -z "$parent" ]; then
        print_error "'$twin' is not a branch twin (no branch_of) — refusing; use pl delete directly if you mean it."
        return 1
    fi
    exec "$SCRIPT_DIR/delete.sh" "$@" "$twin"
}

main() {
    local AUTO_YES=false NAME="" CONTENT="parent" NO_START=false FROM="parent"
    local args=()
    local a
    for a in "$@"; do
        case "$a" in
            -h|--help) show_help; exit 0 ;;
            -y|--yes) AUTO_YES=true ;;
            --name=*) NAME="${a#*=}" ;;
            --content=*) CONTENT="${a#*=}" ;;
            --from=*) FROM="${a#*=}" ;;
            --no-start) NO_START=true ;;
            *) args+=("$a") ;;
        esac
    done
    set -- "${args[@]:-}"

    local sub="${1:-}"
    case "$sub" in
        ""|-*)      show_help; exit 1 ;;
        list)       cmd_list "${2:-}" ;;
        content)    cmd_content "${2:-}" "$FROM" ;;
        merge)      cmd_merge "${2:-}" ;;
        delete)     shift; local t="${1:-}"; shift || true; cmd_delete "$t" "$@" ;;
        *)          cmd_create "$sub" "${2:-}" "$NAME" "$CONTENT" "$NO_START" "$AUTO_YES" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
