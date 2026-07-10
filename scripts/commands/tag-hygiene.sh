#!/bin/bash
#
# pl tag-hygiene — tag & release hygiene linter (ADR-0031 D3 / ops#74).
#
# READ-ONLY. It never creates, deletes, moves, or pushes a tag — it only reports.
# It answers, per git repo, the two ops#74 acceptance questions locally:
#
#   1. untagged-version — a declared release version (composer.json "version" or
#                         $plugin->release in a repo-root version.php) with no
#                         matching `vX.Y.Z` git tag. This is D3's "bumped the
#                         version/release without cutting the tag" failure mode.
#   2. empty-release    — a Moodle version.php with $plugin->version but a missing
#                         or empty $plugin->release (the format_tabbed case).
#   3. stray-tag        — a `pre-*` (or refs/tags/rollback/*) rollback anchor
#                         still living under refs/tags, polluting `git tag -l`.
#                         D3: rollback anchors belong out-of-band (refs/rollback/).
#
# By design it makes NO network calls and NO writes, so it is safe to run against
# the operator's real clones (nwc profile, plugin repos).
#
# Usage:
#   pl tag-hygiene                 lint the default repos (nwp tool + nwc profile)
#   pl tag-hygiene --repo DIR ...  lint the given git repo(s) instead
#   pl tag-hygiene --json          machine-readable summary to stdout
#   pl tag-hygiene --all           also list rollback anchors already parked in refs/rollback/
#   pl tag-hygiene -h|--help
#
# Exit: 0 = clean, 1 = findings, 2 = usage error.
#
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/ui.sh" 2>/dev/null || {
    print_header(){ echo "== $* =="; }; print_error(){ echo "ERROR: $*" >&2; }
    print_success(){ echo "OK: $*"; }; print_warning(){ echo "WARN: $*"; }
}

usage(){ sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# Read composer.json "version" (jq if available, else grep). Empty if absent.
composer_version(){
    local f="$1/composer.json"
    [ -f "$f" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r '.version // empty' "$f" 2>/dev/null || true
    else
        grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$f" 2>/dev/null \
            | head -1 | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
    fi
}

# Extract $plugin->release from a version.php (empty string if line absent).
plugin_release(){
    local f="$1"
    [ -f "$f" ] || return 0
    sed -nE "s/.*\\\$plugin->release[[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" "$f" 2>/dev/null | head -1
}
plugin_has_release_line(){ [ -f "$1" ] && grep -q 'plugin->release' "$1" 2>/dev/null; }
plugin_has_version_line(){ [ -f "$1" ] && grep -q 'plugin->version'  "$1" 2>/dev/null; }

# Emit "kind|repo|detail" findings for one repo dir.
lint_repo(){
    local dir="$1" label
    label="$(basename "$dir")"
    if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
        print_warning "not a git repo, skipping: $dir" >&2
        return 0
    fi

    # Check B — stray pre-*/rollback anchors under refs/tags.
    local t
    while IFS= read -r t; do
        [ -n "$t" ] && echo "stray-tag|$label|$t"
    done < <(git -C "$dir" tag -l 'pre-*' 'rollback/*' 2>/dev/null || true)

    # Check A — composer.json declared version has a matching vX.Y.Z tag.
    local cv
    cv="$(composer_version "$dir")"
    if [ -n "$cv" ]; then
        if ! git -C "$dir" rev-parse -q --verify "refs/tags/v${cv}" >/dev/null 2>&1; then
            echo "untagged-version|$label|composer:${cv} (no tag v${cv})"
        fi
    fi

    # Check A/2 — repo-root version.php $plugin->release vs tag / empty-release.
    local vp="$dir/version.php" rel
    if plugin_has_version_line "$vp"; then
        if ! plugin_has_release_line "$vp"; then
            echo "empty-release|$label|version.php has \$plugin->version but no \$plugin->release"
        else
            rel="$(plugin_release "$vp")"
            if [ -z "$rel" ]; then
                echo "empty-release|$label|\$plugin->release is empty"
            elif ! git -C "$dir" rev-parse -q --verify "refs/tags/v${rel}" >/dev/null 2>&1; then
                echo "untagged-version|$label|release:${rel} (no tag v${rel})"
            fi
        fi
    fi
}

main(){
    local mode=report
    local -a repos=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --json)    mode=json ;;
            --all)     mode=all ;;
            --repo)    shift; [ $# -gt 0 ] || { print_error "--repo needs a DIR"; exit 2; }; repos+=("$1") ;;
            *) print_error "unknown arg: $1"; usage; exit 2 ;;
        esac
        shift
    done

    if [ "${#repos[@]}" -eq 0 ]; then
        repos+=("$PROJECT_ROOT")
        local nwc="$PROJECT_ROOT/sites/nwc/dev/html/profiles/custom/nwc"
        [ -d "$nwc/.git" ] && repos+=("$nwc")
    fi

    local findings="" r
    for r in "${repos[@]}"; do
        findings+="$(lint_repo "$r")"$'\n'
    done
    findings="$(printf '%s\n' "$findings" | grep -E '^[a-z]' || true)"

    local n; n="$(printf '%s\n' "$findings" | grep -c '^[a-z]' || true)"

    if [ "$mode" = json ]; then
        local stray untag empty
        stray="$(printf '%s\n' "$findings" | grep -c '^stray-tag'       || true)"
        untag="$(printf '%s\n' "$findings" | grep -c '^untagged-version' || true)"
        empty="$(printf '%s\n' "$findings" | grep -c '^empty-release'    || true)"
        printf '{"total":%d,"stray_tag":%d,"untagged_version":%d,"empty_release":%d}\n' \
            "$n" "$stray" "$untag" "$empty"
        [ "$n" -eq 0 ]; return
    fi

    print_header "tag-hygiene (ADR-0031 D3 / ops#74) — ${#repos[@]} repo(s)"
    if [ "$n" -gt 0 ]; then
        local kind repo detail
        while IFS='|' read -r kind repo detail; do
            [ -n "$kind" ] || continue
            print_error "[$kind] $repo → $detail"
        done < <(printf '%s\n' "$findings")
    fi

    if [ "$mode" = all ]; then
        for r in "${repos[@]}"; do
            git -C "$r" rev-parse --git-dir >/dev/null 2>&1 || continue
            local parked
            parked="$(git -C "$r" for-each-ref --format='%(refname)' refs/rollback/ 2>/dev/null || true)"
            [ -n "$parked" ] && print_warning "$(basename "$r"): parked out-of-band → $(printf '%s ' $parked)"
        done
    fi

    if [ "$n" -eq 0 ]; then
        print_success "clean — no untagged version bumps, empty releases, or stray pre-* tags"
        return 0
    fi
    print_warning "$n hygiene finding(s) above. See docs/guides/ops74-tag-release-runbook.md."
    return 1
}

main "$@"
