#!/bin/bash
set -uo pipefail

################################################################################
# pl snapshot — git bundles that can actually rebuild what they claim to hold
#
#   pl snapshot bundle <repo> [--out=F] [--thin --base=<ref> --prereq-source=U]
#   pl snapshot verify <bundle>...
#   pl snapshot audit  [--root=<dir>] [--json]
#
# WHY THIS EXISTS
# ---------------
# On 2026-07-26 the consolidation arc's decision log described a committed git
# bundle of the Art.9 Moodle consent work as "triply safe". It was not safe at
# all. Both bundles under docs/reports/ were *thin* — created with a revision
# range, so they carry only the objects since some base and record the base as a
# PREREQUISITE. Outside the single working copy on this laptop that still holds
# those objects, they rebuild nothing:
#
#   $ git init -q scratch
#   $ git -C scratch bundle verify …/ssc-depthcontent-art9-20260726.bundle
#   error: Repository lacks these prerequisite commits:
#   error: 346025ce13dc2151c0a6d084c1b24c19b713aa91
#
#   $ git -C scratch bundle verify …/ops-118-moodle-art9-gate.bundle
#   error: Repository lacks these prerequisite commits:
#   error: 67c80957df19d4d908e4927fb1c40db02fe40dd2
#
# The trap is that `git bundle verify` run from INSIDE the repo you bundled
# reports success — it silently borrows the objects from the repo you are
# standing in. Whoever made these ran exactly that check and got a green.
#
# So every check here runs in a PRISTINE scratch repository created by this
# script, with every inherited GIT_* variable cleared, so a bundle can pass
# only by carrying its own objects.
#
# A thin bundle is still legitimate — a fork of a 1 GB upstream should not
# commit 1 GB — but only if it is DECLARED: `--thin` demands `--prereq-source`
# and writes a <bundle>.prereq.json naming every prerequisite object and where
# to obtain it. An undeclared thin bundle is a BRICK and the audit fails on it.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
NWP_REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$NWP_REPO_ROOT}"

# shellcheck source=/dev/null
[ -f "$NWP_REPO_ROOT/lib/ui.sh" ] && source "$NWP_REPO_ROOT/lib/ui.sh"
# impact_rm_scratch: the tree's single audited primitive for removing a
# throwaway directory this process created. Used instead of a bare recursive
# delete so a future edit that passes the wrong variable gets a refusal.
# shellcheck source=/dev/null
[ -f "$NWP_REPO_ROOT/lib/impact.sh" ] && source "$NWP_REPO_ROOT/lib/impact.sh"

_say()  { if command -v print_info    >/dev/null 2>&1; then print_info    "$*"; else printf '%s\n' "$*"; fi; }
_ok()   { if command -v print_success >/dev/null 2>&1; then print_success "$*"; else printf '%s\n' "$*"; fi; }
_warn() { if command -v print_warning >/dev/null 2>&1; then print_warning "$*"; else printf '%s\n' "$*"; fi; }
_err()  { if command -v print_error   >/dev/null 2>&1; then print_error   "$*"; else printf '%s\n' "$*"; fi; }

usage() {
    cat <<'EOF'
pl snapshot — git bundles that can actually rebuild what they claim to hold

USAGE
  pl snapshot bundle <repo> [--out=<file>] [--thin --base=<ref>
                                            --prereq-source=<url>] [--quiet]
      Create a bundle of <repo> and PROVE it stands alone before shipping it.
      Default is `git bundle create --all` (whole history, no prerequisites).
      A bundle that fails its own standalone check is deleted, never left
      behind. Also writes <file>.sha256.

  pl snapshot verify <bundle> [<bundle>...]
      Verify each bundle in a pristine scratch repository. Names the missing
      prerequisite commits when a bundle is not standalone. Non-zero on any
      failure. Never borrows objects from the repo you are standing in.

  pl snapshot audit [--root=<dir>] [--json]
      Every *.bundle committed under <dir> (plus any loose ones under docs/)
      must either stand alone, or carry a complete <bundle>.prereq.json naming
      every prerequisite and the source they come from. Also checks any
      <bundle>.sha256 sidecar. Non-zero on any BRICK or CHECKSUM failure.
      This is the gate; run it in CI and from pl verify.

THIN BUNDLES
  `--thin --base=<ref>` bundles only what is newer than <ref>. It is refused
  without `--prereq-source=<url>`: an undeclared thin bundle is indistinguishable
  from a corrupt one the day the machine that made it dies.
EOF
}

################################################################################
# The pristine-scratch primitive. Everything in this file goes through it.
#
# `git bundle verify` resolves prerequisites against the CURRENT repository, so
# it must never be run from anywhere that might hold the objects. We create an
# empty repo in a fresh temp dir and clear every git variable that could point
# object lookup somewhere else (GIT_DIR, GIT_OBJECT_DIRECTORY and — the subtle
# one — GIT_ALTERNATE_OBJECT_DIRECTORIES, which would let borrowed objects in
# through the back door).
################################################################################
_scratch_verify() {   # <abs-bundle-path>  → stdout: git's message; rc: git's rc
    local bundle="$1" scratch rc=0
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/nwp-snapshot-XXXXXX")" || return 2
    (
        unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
              GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
        cd "$scratch" || exit 2
        git init -q . >/dev/null 2>&1 || exit 2
        git bundle verify "$bundle" 2>&1
    )
    rc=$?
    impact_rm_scratch "$scratch" >/dev/null || _warn "snapshot: could not remove scratch dir $scratch"
    return "$rc"
}

# Prerequisite commits a bundle needs but does not carry, one sha per line.
# Taken from git's own verify output in the pristine scratch — authoritative,
# and immune to bundle header format (v2 vs v3) changes.
_missing_prereqs() {  # <abs-bundle-path>
    _scratch_verify "$1" 2>/dev/null \
        | grep -oE '\b[0-9a-f]{40}\b' \
        | sort -u
}

_abs() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s\n' "$PWD/$1" ;; esac; }

################################################################################
# bundle
################################################################################
cmd_bundle() {
    local repo="" out="" thin=false base="" prereq_source="" quiet=false a
    for a in "$@"; do
        case "$a" in
            --out=*)            out="${a#*=}" ;;
            --thin)             thin=true ;;
            --base=*)           base="${a#*=}"; thin=true ;;
            --prereq-source=*)  prereq_source="${a#*=}" ;;
            --quiet)            quiet=true ;;
            -h|--help)          usage; return 0 ;;
            -*)                 _err "snapshot bundle: unknown option: $a"; return 2 ;;
            *)                  [ -z "$repo" ] && repo="$a" ;;
        esac
    done

    [ -n "$repo" ] || { _err "snapshot bundle: <repo> is required."; return 2; }
    repo="$(_abs "$repo")"
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || {
        _err "snapshot bundle: not a git repository: $repo"; return 2; }

    if [ "$thin" = true ]; then
        [ -n "$base" ] || { _err "snapshot bundle: --thin needs --base=<ref>."; return 2; }
        if [ -z "$prereq_source" ]; then
            _err "snapshot bundle: --thin refused without --prereq-source=<url>."
            _say "  A thin bundle carries no history before --base. Undeclared, it is"
            _say "  indistinguishable from a corrupt one the day its source repo is gone."
            _say "  Either drop --thin (full history, always standalone), or declare where"
            _say "  the prerequisite objects can be fetched from:"
            _say "    pl snapshot bundle $repo --thin --base=$base --prereq-source=<clone-url>"
            return 2
        fi
        git -C "$repo" rev-parse --verify -q "$base" >/dev/null 2>&1 || {
            _err "snapshot bundle: --base='$base' does not resolve in $repo."; return 2; }
    fi

    if [ -z "$out" ]; then
        out="$PWD/$(basename "$repo")-$(date -u +%Y%m%dT%H%M%SZ).bundle"
    fi
    out="$(_abs "$out")"
    mkdir -p "$(dirname "$out")" || return 2

    # Build. --all so every ref travels; a bundle of one branch loses the tags
    # and the sibling work that made it make sense.
    local mkout rc=0
    if [ "$thin" = true ]; then
        mkout=$(git -C "$repo" bundle create "$out" --all --not "$base" 2>&1) || rc=$?
    else
        mkout=$(git -C "$repo" bundle create "$out" --all 2>&1) || rc=$?
    fi
    if [ "$rc" -ne 0 ] || [ ! -s "$out" ]; then
        _err "snapshot bundle: git bundle create failed:"
        printf '%s\n' "$mkout" >&2
        rm -f "$out"
        return 1
    fi

    # ---- the self-check that makes a brick impossible to ship ---------------
    local vout vrc=0
    vout=$(_scratch_verify "$out") || vrc=$?
    [ -n "${NWP_SNAPSHOT_FORCE_VERIFY_FAIL:-}" ] && { vrc=1; vout="forced failure (test hook)"; }

    if [ "$thin" = false ]; then
        if [ "$vrc" -ne 0 ]; then
            _err "snapshot bundle: the bundle just written does NOT stand alone — discarded."
            printf '%s\n' "$vout" >&2
            _say "  This is the failure mode that produced the two brick bundles in"
            _say "  docs/reports/. The artifact was removed rather than shipped."
            rm -f "$out"
            return 1
        fi
    else
        # Thin bundles are expected to fail the standalone check — that is what
        # thin means. What must hold is that we can enumerate exactly what is
        # missing, and record it.
        local -a prereqs=()
        mapfile -t prereqs < <(_missing_prereqs "$out")
        if [ "${#prereqs[@]}" -eq 0 ]; then
            _warn "snapshot bundle: --thin requested but the bundle needs no prerequisites; it stands alone."
        fi
        {
            printf '{\n'
            printf '  "bundle": "%s",\n'   "$(basename "$out")"
            printf '  "created": "%s",\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf '  "standalone": false,\n'
            printf '  "base": "%s",\n'     "$base"
            printf '  "source": "%s",\n'   "$prereq_source"
            printf '  "prerequisites": ['
            local i
            for i in "${!prereqs[@]}"; do
                [ "$i" -gt 0 ] && printf ', '
                printf '"%s"' "${prereqs[$i]}"
            done
            printf ']\n'
            printf '}\n'
        } > "${out}.prereq.json"
    fi

    ( cd "$(dirname "$out")" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )

    if [ "$quiet" = false ]; then
        if [ "$thin" = true ]; then
            _ok "snapshot bundle: wrote $(basename "$out") (THIN — prerequisites declared in $(basename "$out").prereq.json)"
        else
            _ok "snapshot bundle: wrote $(basename "$out") — verified standalone in a pristine scratch repo"
        fi
        _say "  $out"
    fi
    return 0
}

################################################################################
# verify
################################################################################
cmd_verify() {
    local -a bundles=() a
    for a in "$@"; do
        case "$a" in
            -h|--help) usage; return 0 ;;
            -*)        _err "snapshot verify: unknown option: $a"; return 2 ;;
            *)         bundles+=("$a") ;;
        esac
    done
    [ "${#bundles[@]}" -gt 0 ] || { _err "snapshot verify: give at least one bundle path."; return 2; }

    local b rc=0 out vrc
    for b in "${bundles[@]}"; do
        b="$(_abs "$b")"
        if [ ! -f "$b" ]; then
            _err "snapshot verify: no such bundle: $b"; rc=1; continue
        fi
        vrc=0
        out=$(_scratch_verify "$b") || vrc=$?
        if [ "$vrc" -eq 0 ]; then
            _ok "STANDALONE     $(basename "$b")"
        else
            _err "NOT STANDALONE $(basename "$b") — it cannot rebuild itself outside the machine that made it"
            printf '%s\n' "$out" | sed 's/^/    /'
            rc=1
        fi
    done
    return "$rc"
}

################################################################################
# audit — the repo-wide gate
################################################################################

# Read one scalar from a tiny hand-written JSON manifest without a JSON parser
# dependency. Deliberately strict: anything it cannot read counts as absent,
# which fails closed.
_manifest_source() {  # <manifest>
    sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1
}
_manifest_prereqs() { # <manifest> → one sha per line
    tr -d '\n' < "$1" \
        | sed -n 's/.*"prerequisites"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' \
        | grep -oE '[0-9a-f]{40}' || true
}

cmd_audit() {
    local root="$PROJECT_ROOT" as_json=false a
    for a in "$@"; do
        case "$a" in
            --root=*)  root="${a#*=}" ;;
            --json)    as_json=true ;;
            -h|--help) usage; return 0 ;;
            *)         _err "snapshot audit: unknown option: $a"; return 2 ;;
        esac
    done
    root="$(_abs "$root")"
    [ -d "$root" ] || { _err "snapshot audit: no such directory: $root"; return 2; }

    # What to inspect: every *.bundle git tracks, plus any loose bundle sitting
    # under docs/ (an untracked "backup" makes exactly the same promise, and the
    # gdpr-artifacts one is untracked today).
    local -a bundles=()
    local f
    if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
        while IFS= read -r f; do [ -n "$f" ] && bundles+=("$root/$f"); done \
            < <(git -C "$root" ls-files -- '*.bundle' 2>/dev/null)
    fi
    # Loose bundles: under docs/ (untracked "safety copies" make exactly the
    # same promise as tracked ones — the gdpr-artifacts brick is untracked
    # today), and under sites/*/backups/, which is where the rollback registry
    # points several of its recovery rows.
    local -a loose=()
    [ -d "$root/docs" ] && mapfile -t -O "${#loose[@]}" loose < <(find "$root/docs" -type f -name '*.bundle' 2>/dev/null | sort)
    [ -d "$root/sites" ] && mapfile -t -O "${#loose[@]}" loose < <(find "$root/sites" -mindepth 3 -maxdepth 3 -type f -name '*.bundle' -path '*/backups/*' 2>/dev/null | sort)
    for f in "${loose[@]:-}"; do
        [ -n "$f" ] || continue
        local seen=false b
        for b in "${bundles[@]:-}"; do [ "$b" = "$f" ] && { seen=true; break; }; done
        [ "$seen" = false ] && bundles+=("$f")
    done

    if [ "${#bundles[@]}" -eq 0 ]; then
        [ "$as_json" = true ] && { printf '[]\n'; return 0; }
        _ok "snapshot audit: no bundles under ${root} — nothing claims to be a restorable snapshot."
        return 0
    fi

    [ "$as_json" = false ] && print_header "Snapshot bundles" 2>/dev/null || true
    [ "$as_json" = true ] && printf '[\n'

    local rc=0 first=true bundle rel vrc vout status_word detail
    for bundle in "${bundles[@]}"; do
        rel="${bundle#$root/}"
        status_word=""; detail=""

        vrc=0
        vout=$(_scratch_verify "$bundle") || vrc=$?

        if [ "$vrc" -eq 0 ]; then
            status_word="STANDALONE"
        elif [ -f "${bundle}.prereq.json" ]; then
            # Declared thin. The declaration must be COMPLETE: a source, and
            # every prerequisite git actually reports. A manifest that lists
            # nothing documents nothing.
            local src; src="$(_manifest_source "${bundle}.prereq.json")"
            local -a declared=() actual=() undeclared=()
            mapfile -t declared < <(_manifest_prereqs "${bundle}.prereq.json")
            mapfile -t actual   < <(printf '%s\n' "$vout" | grep -oE '\b[0-9a-f]{40}\b' | sort -u)
            local want have found
            for want in "${actual[@]:-}"; do
                [ -n "$want" ] || continue
                found=false
                for have in "${declared[@]:-}"; do [ "$have" = "$want" ] && { found=true; break; }; done
                [ "$found" = false ] && undeclared+=("$want")
            done

            if [ -z "$src" ]; then
                status_word="BRICK"
                detail="prereq manifest names no source — nowhere to fetch the missing objects from"
                rc=1
            elif [ "${#undeclared[@]}" -gt 0 ]; then
                status_word="BRICK"
                detail="prereq manifest is incomplete — undeclared: ${undeclared[*]}"
                rc=1
            else
                status_word="THIN-DECLARED"
                detail="needs ${#actual[@]} prerequisite(s) from $src"
            fi
        else
            status_word="BRICK"
            detail="$(printf '%s' "$vout" | grep -oE '\b[0-9a-f]{40}\b' | sort -u | tr '\n' ' ')"
            [ -n "$detail" ] && detail="missing prerequisite commit(s): $detail" \
                             || detail="git could not verify this bundle at all"
            rc=1
        fi

        # Checksum sidecar, when one exists, must still match.
        local ck_bad=false
        if [ -f "${bundle}.sha256" ]; then
            if ! ( cd "$(dirname "$bundle")" && sha256sum -c "$(basename "$bundle").sha256" >/dev/null 2>&1 ); then
                ck_bad=true; rc=1
            fi
        fi

        if [ "$as_json" = true ]; then
            [ "$first" = true ] && first=false || printf ',\n'
            printf '  {"bundle":"%s","status":"%s","checksum":"%s","detail":"%s"}' \
                "$rel" "$status_word" "$([ "$ck_bad" = true ] && echo MISMATCH || echo ok)" "$detail"
        else
            case "$status_word" in
                STANDALONE)    _ok   "STANDALONE     $rel" ;;
                THIN-DECLARED) _say  "THIN-DECLARED  $rel — $detail" ;;
                BRICK)         _err  "BRICK          $rel — $detail" ;;
            esac
            [ "$ck_bad" = true ] && _err "CHECKSUM       $rel — sha256 sidecar does not match the file on disk"
        fi
    done

    if [ "$as_json" = true ]; then
        printf '\n]\n'
        return "$rc"
    fi

    echo ""
    if [ "$rc" -eq 0 ]; then
        _ok "snapshot audit: ${#bundles[@]} bundle(s) — every one can rebuild what it claims to hold."
    else
        _err "snapshot audit: at least one bundle cannot restore anything."
        _say "  A BRICK is not a backup. Either re-make it standalone:"
        _say "    pl snapshot bundle <source-repo> --out=<path>"
        _say "  or declare it: pl snapshot bundle … --thin --base=<ref> --prereq-source=<url>"
        _say "  or delete it, because it is asserting a safety it does not provide."
    fi
    return "$rc"
}

################################################################################
main() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        bundle)          cmd_bundle "$@" ;;
        verify)          cmd_verify "$@" ;;
        audit)           cmd_audit  "$@" ;;
        ""|-h|--help|help) usage ;;
        *) _err "pl snapshot: unknown subcommand '$sub'"; usage; return 2 ;;
    esac
}

main "$@"
