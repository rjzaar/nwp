#!/bin/bash
set -euo pipefail
################################################################################
# scripts/commands/patches.sh — `pl patches` (nwp/ops#223)
#
# WHY THIS EXISTS
# ---------------
# The estate patches contrib Drupal through cweagans/composer-patches, declared
# in each project's composer.json under `extra.patches`. That machinery has one
# genuine safety property — `composer-exit-on-patch-failure: true` means a patch
# that no longer applies FAILS THE BUILD instead of being silently skipped — and
# several ways to lose it that nothing was watching:
#
#   - `enable-patching` flipped to false, or the flag simply absent on a new
#     project: every declared patch becomes decoration.
#   - `composer-exit-on-patch-failure` flipped to false: a patch that stops
#     applying after an upstream release is skipped with a warning nobody reads.
#   - the .patch FILE missing from the repo while the declaration stays. On nwd
#     this was already true: nwd-project tracks only composer.json + .gitignore,
#     so its `patches/` directory is untracked and a fresh clone cannot apply
#     anything it declares.
#   - the DEPLOYED tree not matching the declaration at all, because live is
#     rsynced from a staging webroot rather than composer-installed on the box.
#
# The last one is the one that matters most here. ops#223 is an Art. 17 blocker
# fixed by a patch to goalgorilla/open_social; "the patch is declared" and "the
# code running on live contains the fix" are different claims, and only the
# second one protects anybody.
#
# So this verb checks the DECLARATION and the BUILT TREE, locally or on live,
# and it is deliberately the Drupal twin of `pl moodle core-patch` — same
# tri-state reading, same refusal semantics, same "an unreadable declaration is
# not an empty one" rule.
#
# THE ANTI-VACUITY RULE (inherited from `pl erasure`)
# --------------------------------------------------
# A patch that could not be CHECKED is never reported as applied. Every
# unreadable composer.json, missing package directory, unreachable host and
# unparseable patch is CANNOT-VERIFY and exits non-zero. "0 problems" is only
# ever printed when something actually verified something.
#
# Usage:
#   pl patches <site> [--tier=dev|stg|live] [--quiet]
#   pl patches --all  [--tier=dev]
#
# Exit codes:
#   0  every declared patch is present and applied in the target tree
#   1  at least one patch is missing, unapplied, or undeclarable
#   2  CANNOT-VERIFY — nothing was checked (bad path, unreadable declaration)
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
NWP_REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$NWP_REPO_ROOT}"

# shellcheck source=/dev/null
[ -f "$NWP_REPO_ROOT/lib/ui.sh" ] && source "$NWP_REPO_ROOT/lib/ui.sh"
# shellcheck source=/dev/null
[ -f "$NWP_REPO_ROOT/lib/common.sh" ] && source "$NWP_REPO_ROOT/lib/common.sh" 2>/dev/null || true
# shellcheck source=/dev/null
[ -f "$NWP_REPO_ROOT/lib/server-resolver.sh" ] && source "$NWP_REPO_ROOT/lib/server-resolver.sh" 2>/dev/null || true

# _p_live_field <site> <field> — the live-tier route, resolved the same way
# `pl drush` and `pl stg2live` resolve it. `.live.server_ip` is NOT the field to
# read: shared-host sites name a SERVER (`.live.server: live`) and the IP lives
# in servers/<name>/.nwp-server.yml. Reading the site key alone returns empty
# and the verb then reports "no live server configured" for a site that plainly
# has one — a CANNOT-VERIFY produced by the checker, not by the estate.
_p_live_field() {
    local site="$1" field="$2" server_name=""
    case "$field" in
        server_ip)
            server_name="$(get_site_config_value "$site" '.live.server' "" 2>/dev/null || true)"
            if [ -n "$server_name" ] && declare -F get_server_config >/dev/null 2>&1; then
                get_server_config "$server_name" "ip" "" 2>/dev/null || true
                return
            fi
            get_site_config_value "$site" '.live.server_ip' "" 2>/dev/null || true
            ;;
        *)
            get_site_config_value "$site" ".live.$field" "" 2>/dev/null || true
            ;;
    esac
}

_p_say()  { if command -v print_info    >/dev/null 2>&1; then print_info    "$*"; else printf '%s\n' "$*"; fi; }
_p_warn() { if command -v print_warning >/dev/null 2>&1; then print_warning "$*"; else printf 'WARN: %s\n' "$*"; fi; }
_p_err()  { if command -v print_error   >/dev/null 2>&1; then print_error   "$*"; else printf 'ERROR: %s\n' "$*" >&2; fi; }
_p_ok()   { if command -v print_status  >/dev/null 2>&1; then print_status "OK" "$*"; else printf 'OK: %s\n' "$*"; fi; }
_p_head() { if command -v print_header  >/dev/null 2>&1; then print_header  "$*"; else printf '\n== %s ==\n' "$*"; fi; }

usage() {
    cat <<'EOF'
pl patches — are this site's declared contrib patches actually applied?

USAGE:
    pl patches <site> [--tier=dev|stg|live] [--quiet]
    pl patches --all  [--tier=dev]

WHAT IT CHECKS, per declared patch in composer.json `extra.patches`:
    DECLARED    the package + patch file are named
    FILE        the .patch file exists in the project (a declaration pointing
                at a missing file cannot survive a fresh clone)
    APPLIED     the patch is already present in the installed package tree,
                proved by a reverse dry-run (`patch -p1 -R --dry-run`), which
                succeeds only if every hunk is currently in place

It also asserts the two composer flags the whole scheme rests on:
    extra.enable-patching                  must be true
    extra.composer-exit-on-patch-failure   must be true
        — without it a patch that stops applying after an upstream release is
          skipped with a warning instead of failing the build. That is the
          "silently dropped by composer update" failure mode.

TIERS:
    --tier=dev   (default) sites/<site>/dev
    --tier=stg             sites/<site>/stg
    --tier=live            the live webroot over ssh (read-only)

EXIT: 0 all applied · 1 problems · 2 CANNOT-VERIFY (nothing was checked)
EOF
}

# _p_installer_dir <composer.json> <package>
# Where composer put a package, from extra.installer-paths. Echoes a path
# RELATIVE to the project root.
#
# It deliberately returns a path even when that path does not exist: "the
# package is not built" and "I have no idea where this package goes" are
# different findings and the caller reports them differently. Collapsing them
# would turn a missing composer install into an unhelpful shrug.
_p_installer_dir() {
    local cj="$1" pkg="$2" hit=""
    hit="$(python3 - "$cj" "$pkg" "$PROJ" <<'PY' 2>/dev/null || true
import json, os, sys
cj, pkg, proj = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(open(cj))
except Exception:
    sys.exit(0)
paths = d.get('extra', {}).get('installer-paths', {}) or {}
name = pkg.split('/')[-1]

exact, globs = [], []
for path, matchers in paths.items():
    for m in (matchers or []):
        if m == pkg:
            # An exact package pin may point anywhere, including a fixed path
            # whose basename is nothing like the package name (open_social ->
            # html/profiles/contrib/social). Trust it.
            exact.append(path.replace('{$name}', name))
        elif m.startswith('type:') and '{$name}' in path:
            # Only name-parameterised globs can be about THIS package. A fixed
            # path like "html/core" answers a different question, and matching
            # it here is how search_api once resolved to the Drupal core dir.
            globs.append(path.replace('{$name}', name))

# Exact package pins win over type: globs -- composer's own precedence. Among
# globs, prefer one that actually exists on disk (a project declares paths for
# modules, themes, profiles and libraries; only one of them holds this package).
for cand in exact:
    print(cand)
    sys.exit(0)
for cand in globs:
    if os.path.isdir(os.path.join(proj, cand)):
        print(cand)
        sys.exit(0)
if globs:
    print(globs[0])
PY
)"
    if [ -n "$hit" ]; then printf '%s' "$hit"; return 0; fi
    # Conventional fallbacks when installer-paths says nothing useful.
    local name="${pkg##*/}"
    for cand in "html/profiles/contrib/$name" "web/profiles/contrib/$name" \
                "html/modules/contrib/$name" "web/modules/contrib/$name" \
                "html/themes/contrib/$name" "web/themes/contrib/$name" \
                "vendor/$pkg"; do
        [ -d "$PROJ/$cand" ] && { printf '%s' "$cand"; return 0; }
    done
    return 1
}

# _p_declared <composer.json> -> lines of "<package>\t<patchfile>\t<description>"
_p_declared() {
    python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("PARSE-ERROR\t%s" % e, end="\n")
    sys.exit(3)
extra = d.get('extra', {}) or {}
print("FLAG\tenable-patching\t%s" % extra.get('enable-patching'))
print("FLAG\tcomposer-exit-on-patch-failure\t%s" % extra.get('composer-exit-on-patch-failure'))
for pkg, patches in (extra.get('patches', {}) or {}).items():
    for desc, path in (patches or {}).items():
        print("PATCH\t%s\t%s\t%s" % (pkg, path, desc))
PY
}

# _p_check_local <project-dir>
_p_check_local() {
    PROJ="$1"
    local cj="$PROJ/composer.json"
    if [ ! -f "$cj" ]; then
        _p_err "CANNOT-VERIFY: no composer.json at $cj"
        _p_err "  Nothing was checked. This is not a clean result."
        return 2
    fi

    local decl rc=0
    decl="$(_p_declared "$cj")" || rc=$?
    if [ "$rc" -eq 3 ] || printf '%s' "$decl" | grep -q '^PARSE-ERROR'; then
        _p_err "CANNOT-VERIFY: $cj does not parse as JSON."
        _p_err "  ${decl#PARSE-ERROR	}"
        _p_err "  A declaration that cannot be READ is not a declaration that is empty."
        return 2
    fi

    local problems=0 checked=0 flag value
    while IFS=$'\t' read -r kind a b c; do
        [ "$kind" = "FLAG" ] || continue
        flag="$a"; value="$b"
        if [ "$value" != "True" ]; then
            printf '    %-38s %-14s %s\n' "$flag" "[NOT SET]" "is '${value}', must be true"
            problems=$((problems+1))
        elif [ "${QUIET:-false}" != "true" ]; then
            printf '    %-38s %-14s\n' "$flag" "[true]"
        fi
    done <<< "$decl"

    local pkg file desc pkgdir
    while IFS=$'\t' read -r kind pkg file desc; do
        [ "$kind" = "PATCH" ] || continue
        checked=$((checked+1))
        local label="${pkg}: ${file##*/}"

        # Remote patch URLs are outside this check's remit -- we cannot prove a
        # URL's content is what is in the tree. Say so rather than pass it.
        case "$file" in
            http://*|https://*)
                printf '    %-58s %-16s %s\n' "$label" "[REMOTE]" "URL patch — not verifiable locally"
                continue
                ;;
        esac

        if [ ! -f "$PROJ/$file" ]; then
            printf '    %-58s %-16s %s\n' "$label" "[FILE MISSING]" "$file"
            printf '    %-58s %-16s %s\n' "" "" "declared but absent — a fresh clone cannot apply it"
            problems=$((problems+1)); continue
        fi

        if ! pkgdir="$(_p_installer_dir "$cj" "$pkg")"; then
            printf '    %-58s %-16s %s\n' "$label" "[CANNOT-VERIFY]" "cannot locate installed package dir"
            problems=$((problems+1)); continue
        fi
        if [ ! -d "$PROJ/$pkgdir" ]; then
            printf '    %-58s %-16s %s\n' "$label" "[CANNOT-VERIFY]" "$pkgdir not built (run composer install)"
            problems=$((problems+1)); continue
        fi

        # THE ASSERTION. A reverse dry-run succeeds only if every hunk is
        # currently present in the tree, so this proves the built code carries
        # the fix -- not merely that somebody wrote it down in composer.json.
        if (cd "$PROJ/$pkgdir" && patch -p1 -R --dry-run --force --silent < "$PROJ/$file" >/dev/null 2>&1); then
            [ "${QUIET:-false}" = "true" ] || printf '    %-58s %-16s %s\n' "$label" "[APPLIED]" "$pkgdir"
        else
            printf '    %-58s %-16s %s\n' "$label" "[NOT APPLIED]" "$pkgdir"
            printf '    %-58s %-16s %s\n' "" "" "the declared patch is NOT in the built tree"
            problems=$((problems+1))
        fi
    done <<< "$decl"

    if [ "$checked" -eq 0 ]; then
        _p_say "no contrib patches declared in ${cj#$PROJECT_ROOT/}"
        return 0
    fi
    if [ "$problems" -gt 0 ]; then
        _p_err "${problems} problem(s) across ${checked} declared patch(es)."
        return 1
    fi
    _p_ok "${checked} declared patch(es), all present and applied."
    return 0
}

# _p_check_live <site>
# Read-only: hashes the patched files on the box and compares against the
# locally patched copy. We do not ship the patch to the box.
_p_check_live() {
    local site="$1"
    local ip user remote
    ip="$(_p_live_field "$site" "server_ip")"
    [ -z "$ip" ] && { _p_err "CANNOT-VERIFY: no live server configured for '$site'."; return 2; }
    user="$(get_ssh_user "$site" 2>/dev/null || echo gitlab)"
    [ -z "$user" ] && user="gitlab"
    remote="$(_p_live_field "$site" "remote_path")"
    [ -z "$remote" ] && remote="/var/www/$site"

    local proj="$PROJECT_ROOT/sites/$site/dev"
    local cj="$proj/composer.json"
    [ -f "$cj" ] || { _p_err "CANNOT-VERIFY: no local composer.json to read the declaration from ($cj)."; return 2; }
    PROJ="$proj"

    local decl; decl="$(_p_declared "$cj")" || {
        _p_err "CANNOT-VERIFY: $cj does not parse."; return 2; }

    _p_say "target: LIVE ${user}@${ip}:${remote}  (declaration read from ${cj#$PROJECT_ROOT/})"

    local problems=0 checked=0 pkg file desc pkgdir
    while IFS=$'\t' read -r kind pkg file desc; do
        [ "$kind" = "PATCH" ] || continue
        case "$file" in http://*|https://*) continue ;; esac
        [ -f "$proj/$file" ] || continue
        pkgdir="$(_p_installer_dir "$cj" "$pkg")" || continue

        # Every file the patch touches, from its own +++ headers.
        local touched
        touched="$(awk '/^\+\+\+ /{p=$2; sub(/^b\//,"",p); print p}' "$proj/$file")"
        [ -n "$touched" ] || { printf '    %-58s %-16s\n' "${pkg}: ${file##*/}" "[CANNOT-VERIFY]"; problems=$((problems+1)); continue; }

        local f localsum remotesum
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            checked=$((checked+1))
            localsum="$(md5sum "$proj/$pkgdir/$f" 2>/dev/null | cut -d' ' -f1)"
            remotesum="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "${user}@${ip}" \
                "md5sum '${remote}/${pkgdir}/${f}' 2>/dev/null | cut -d' ' -f1" 2>/dev/null || true)"
            if [ -z "$remotesum" ]; then
                printf '    %-58s %-16s %s\n' "${f##*/}" "[CANNOT-VERIFY]" "unreadable on live"
                problems=$((problems+1))
            elif [ -z "$localsum" ]; then
                printf '    %-58s %-16s %s\n' "${f##*/}" "[CANNOT-VERIFY]" "absent locally, nothing to compare"
                problems=$((problems+1))
            elif [ "$localsum" = "$remotesum" ]; then
                printf '    %-58s %-16s %s\n' "${f##*/}" "[MATCHES DEV]" "$localsum"
            else
                printf '    %-58s %-16s %s\n' "${f##*/}" "[DRIFT]" "live $remotesum != dev $localsum"
                problems=$((problems+1))
            fi
        done <<< "$touched"
    done <<< "$decl"

    if [ "$checked" -eq 0 ]; then
        _p_err "CANNOT-VERIFY: nothing was compared on live."
        return 2
    fi
    if [ "$problems" -gt 0 ]; then
        _p_err "${problems} problem(s) over ${checked} patched file(s) on live."
        return 1
    fi
    _p_ok "${checked} patched file(s) on live are byte-identical to the patched dev tree."
    _p_say "NOTE: this proves live == dev, and \`pl patches ${site}\` (dev tier) proves dev is patched."
    _p_say "      Both, together, are the claim. Neither alone is."
    return 0
}

main() {
    local site="" tier="dev" all="false"
    QUIET="false"
    for a in "$@"; do
        case "$a" in
            -h|--help) usage; return 0 ;;
            --all)     all="true" ;;
            --tier=*)  tier="${a#*=}" ;;
            --quiet|-q) QUIET="true" ;;
            -*)        _p_err "Unknown option: $a"; usage; return 2 ;;
            *)         [ -z "$site" ] && site="$a" || { _p_err "Unexpected argument: $a"; return 2; } ;;
        esac
    done

    case "$tier" in dev|stg|live) ;; *) _p_err "Unknown tier: $tier (dev|stg|live)"; return 2 ;; esac

    if [ "$all" = "true" ]; then
        local rc=0 s
        for s in $(ls -1 "$PROJECT_ROOT/sites" 2>/dev/null); do
            [ -f "$PROJECT_ROOT/sites/$s/$tier/composer.json" ] || continue
            _p_head "Declared contrib patches: $s ($tier)"
            _p_check_local "$PROJECT_ROOT/sites/$s/$tier" || rc=1
        done
        return $rc
    fi

    [ -z "$site" ] && { usage; return 2; }

    if [ "$tier" = "live" ]; then
        _p_head "Declared contrib patches on LIVE: $site"
        _p_check_live "$site"
        return $?
    fi

    _p_head "Declared contrib patches: $site ($tier)"
    _p_check_local "$PROJECT_ROOT/sites/$site/$tier"
}

main "$@"
