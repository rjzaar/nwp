#!/usr/bin/env bash
# NWP Config Bundle - export/import site+server configs for offline bootstrap (ops#79)
#
# Moves the non-secret NWP configuration set (root nwp.yml, per-site
# sites/*/.nwp.yml, per-server servers/*/.nwp-server.yml) between machines
# as a single signed-by-checksum tarball — e.g. dev -> ver over USB/scp.
# Secrets are deliberately excluded: the bundle NEVER contains .secrets*,
# keys, .env, dumps, or backups, and the export fail-closes if any staged
# file matches those patterns or carries obvious secret content.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/ui.sh"

# The tree we export from / import into. Overridable for tests.
CONFIG_ROOT="${NWP_CONFIG_ROOT:-$PROJECT_ROOT}"

MANIFEST_NAME="bundle-manifest.json"

################################################################################
# Help Function
################################################################################

show_help() {
    cat << 'EOF'
Usage: pl config <command> [options]

Export/import the NWP configuration set (root nwp.yml, sites/*/.nwp.yml,
servers/*/.nwp-server.yml) as a checksummed tarball, for carrying configs
to an offline deploy box (ver) over USB or scp. Secrets are deliberately
excluded — the bundle never contains .secrets*, keys, .env files, database
dumps, or backups, and export refuses (fail-closed) if anything staged
looks like one.

Commands:
    export [--out FILE]       Bundle configs into a tarball (default:
                              ~/nwp-config-bundle-<UTCdate>.tgz, mode 0600,
                              outside the repo so it can't be committed).
    import FILE [--dry-run]   Restore configs from a bundle. Verifies every
                              member path and sha256 against the embedded
                              manifest; refuses unknown paths, traversal,
                              tampered files, or unparseable YAML. Existing
                              files are backed up to <file>.pre-import-*.bak
                              before being overwritten.

Options:
    --out FILE      Export: write the bundle to FILE instead of the default
    --dry-run       Import: show what would be written/overwritten, write nothing
    -h, --help      Show this help message

Examples:
    pl config export                          # bundle to ~/nwp-config-bundle-<date>.tgz
    pl config export --out /media/usb/cfg.tgz
    pl config import ~/nwp-config-bundle-20260711.tgz --dry-run
    pl config import /media/usb/cfg.tgz

Transfer the bundle by USB stick or direct scp to the target box.
Never push it through the forge (GitLab) — configs stay off shared remotes.

EOF
}

################################################################################
# Shared helpers
################################################################################

# Relative paths (under CONFIG_ROOT) allowed in a bundle, besides the manifest.
# Used by export (what to collect) and import (what to accept).
_is_allowed_member() {
    local rel="$1"
    # No absolute paths, no parent traversal anywhere in the path
    case "/$rel/" in
        //*|*/../*) return 1 ;;
    esac
    case "$rel" in
        "$MANIFEST_NAME") return 0 ;;
        nwp.yml) return 0 ;;
        sites/*/.nwp.yml)
            # Exactly one path segment between sites/ and /.nwp.yml
            local mid="${rel#sites/}"; mid="${mid%/.nwp.yml}"
            [[ "$mid" != */* && "$mid" =~ ^[A-Za-z0-9._-]+$ ]] && return 0
            return 1 ;;
        servers/*/.nwp-server.yml)
            local mid="${rel#servers/}"; mid="${mid%/.nwp-server.yml}"
            [[ "$mid" != */* && "$mid" =~ ^[A-Za-z0-9._-]+$ ]] && return 0
            return 1 ;;
    esac
    return 1
}

# Belt-and-suspenders deny-scan: refuse paths that could ever carry secrets
# or data, even though _is_allowed_member should already preclude them.
# Guards future edits to the include list.
_is_denied_path() {
    local rel="$1"
    case "$rel" in
        *.secrets*|keys/*|*/keys/*|.env*|*/.env*|*.sql|*.sql.gz|*.tar|*.tar.gz|*.tgz|backups/*|*/backups/*)
            return 0 ;;
    esac
    return 1
}

# Content scan for obvious secrets in a staged YAML file. Deliberately
# narrow (glpat- tokens and PEM private-key blocks) — broader patterns
# like `password:` are too noisy for config files.
_has_secret_content() {
    local file="$1"
    grep -Eq 'glpat-|BEGIN [A-Z ]*PRIVATE KEY' "$file" 2>/dev/null
}

_sha256() {
    sha256sum "$1" | awk '{print $1}'
}

# Best-effort schema/version read via yq; blank on any failure.
_yq_field() {
    local file="$1" expr="$2"
    local v=""
    if command -v yq &>/dev/null; then
        v=$(yq eval "$expr // \"\"" "$file" 2>/dev/null) || v=""
        [ "$v" = "null" ] && v=""
    fi
    echo "$v"
}

_utc_stamp() { date -u +%Y%m%d-%H%M%S; }

# ops#77: import relies on yq to read the staged manifest + validate YAML. Two
# silent impostors otherwise surface only as a misleading "not valid JSON":
#   (a) Ubuntu's apt `yq` is a different tool (a Python jq-wrapper); its
#       `--version` does not mention mikefarah.
#   (b) snap-confined mikefarah yq cannot read /tmp (where the manifest is
#       staged), so it reads back empty.
# Returns: 0 = real, usable mikefarah yq; 1 = impostor/snap (message printed);
#          2 = yq not installed at all (caller prints the install hint).
_require_real_yq() {
    command -v yq &>/dev/null || return 2
    local yq_path yq_verline
    yq_path="$(command -v yq)"
    yq_verline="$(yq --version 2>&1 | head -1)"
    if ! printf '%s' "$yq_verline" | grep -qi 'mikefarah'; then
        print_error "The 'yq' on PATH ($yq_path) is the wrong tool."
        print_info "Ubuntu's apt 'yq' is a Python jq-wrapper, not mikefarah yq; NWP config import cannot use it."
        print_info "Fix: install the pinned mikefarah binary to /usr/local/bin/yq — run 'pl setup' (verify with 'pl doctor')."
        return 1
    fi
    if [[ "$yq_path" == /snap/* ]]; then
        print_error "The 'yq' on PATH ($yq_path) is snap-confined."
        print_info "snap confinement blocks yq from reading /tmp, where the import manifest is staged — it reads back empty."
        print_info "Fix: 'sudo snap remove yq' then install the pinned mikefarah binary to /usr/local/bin/yq — run 'pl setup'."
        return 1
    fi
    return 0
}

################################################################################
# Export
################################################################################

cmd_export() {
    local out=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --out) out="${2:-}"; shift 2 ;;
            --out=*) out="${1#--out=}"; shift ;;
            -h|--help) show_help; return 0 ;;
            *) print_error "Unknown export option: $1"; return 1 ;;
        esac
    done
    [ -z "$out" ] && out="$HOME/nwp-config-bundle-$(_utc_stamp).tgz"

    print_header "Config Export"

    # ── Collect EXACTLY: root nwp.yml, sites/*/.nwp.yml, servers/*/.nwp-server.yml
    local files=()
    [ -f "$CONFIG_ROOT/nwp.yml" ] && files+=("nwp.yml")
    local f
    for f in "$CONFIG_ROOT"/sites/*/.nwp.yml; do
        [ -f "$f" ] && files+=("${f#"$CONFIG_ROOT"/}")
    done
    for f in "$CONFIG_ROOT"/servers/*/.nwp-server.yml; do
        [ -f "$f" ] && files+=("${f#"$CONFIG_ROOT"/}")
    done

    if [ ${#files[@]} -eq 0 ]; then
        print_error "Nothing to export: no nwp.yml, sites/*/.nwp.yml, or servers/*/.nwp-server.yml found under $CONFIG_ROOT"
        return 1
    fi

    # ── Fail-closed deny-scan (paths + content) BEFORE writing anything
    local rel
    for rel in "${files[@]}"; do
        if ! _is_allowed_member "$rel"; then
            print_error "Refusing export: staged path not in the allowed set: $rel"
            return 1
        fi
        if _is_denied_path "$rel"; then
            print_error "Refusing export: staged path matches a secret/data pattern: $rel"
            return 1
        fi
        if _has_secret_content "$CONFIG_ROOT/$rel"; then
            print_error "Refusing export: possible secret content (token or private key) in: $rel"
            print_info "Remove the secret from that file (secrets belong in .secrets*.yml, never in configs) and retry."
            return 1
        fi
    done

    # ── Stage copies + build the manifest
    local stage
    stage="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$stage'" EXIT

    local manifest="$stage/$MANIFEST_NAME"
    {
        printf '{\n'
        printf '  "nwp_config_bundle": 1,\n'
        printf '  "created_utc": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  "files": [\n'
    } > "$manifest"

    local first=1 sha schema ver
    for rel in "${files[@]}"; do
        mkdir -p "$stage/$(dirname "$rel")"
        cp "$CONFIG_ROOT/$rel" "$stage/$rel"
        sha="$(_sha256 "$stage/$rel")"
        schema="$(_yq_field "$stage/$rel" '.schema_version')"
        ver="$(_yq_field "$stage/$rel" '.version')"
        [ $first -eq 0 ] && printf ',\n' >> "$manifest"
        printf '    {"path": "%s", "sha256": "%s", "schema_version": "%s", "version": "%s"}' \
            "$rel" "$sha" "$schema" "$ver" >> "$manifest"
        first=0
    done
    printf '\n  ]\n}\n' >> "$manifest"

    # ── Write the tarball (explicit member list — no directory entries)
    tar -czf "$out" -C "$stage" "$MANIFEST_NAME" "${files[@]}"
    chmod 600 "$out"

    print_status "OK" "Exported ${#files[@]} config file(s) + manifest"
    for rel in "${files[@]}"; do
        print_info "  $rel"
    done
    print_status "OK" "Bundle: $out (mode 0600)"
    echo ""
    print_info "Transfer by USB stick or direct scp to the target box (e.g. ver)."
    print_info "Never push the bundle through the forge — configs stay off shared remotes."
    print_info "On the target: pl config import $(basename "$out")"
    return 0
}

################################################################################
# Import
################################################################################

cmd_import() {
    local file="" dry_run=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry_run=1; shift ;;
            -h|--help) show_help; return 0 ;;
            -*) print_error "Unknown import option: $1"; return 1 ;;
            *)
                if [ -n "$file" ]; then
                    print_error "Unexpected argument: $1"; return 1
                fi
                file="$1"; shift ;;
        esac
    done

    if [ -z "$file" ]; then
        print_error "Usage: pl config import FILE [--dry-run]"
        return 1
    fi
    if [ ! -f "$file" ]; then
        print_error "Bundle not found: $file"
        return 1
    fi

    print_header "Config Import"

    # ── List members and refuse (fail-closed) anything outside the allowed set
    local members=() m
    while IFS= read -r m; do
        [ -z "$m" ] && continue
        members+=("$m")
    done < <(tar -tzf "$file")

    local have_manifest=0
    for m in "${members[@]}"; do
        if ! _is_allowed_member "$m"; then
            print_error "Refusing import: bundle member outside the allowed set: $m"
            print_info "Allowed: nwp.yml, sites/<name>/.nwp.yml, servers/<name>/.nwp-server.yml, $MANIFEST_NAME"
            return 1
        fi
        if [ "$m" != "$MANIFEST_NAME" ] && _is_denied_path "$m"; then
            print_error "Refusing import: bundle member matches a secret/data pattern: $m"
            return 1
        fi
        [ "$m" = "$MANIFEST_NAME" ] && have_manifest=1
    done
    if [ $have_manifest -eq 0 ]; then
        print_error "Refusing import: bundle has no $MANIFEST_NAME (cannot verify checksums)"
        return 1
    fi

    # ── Extract to a temp dir (members already vetted) and verify sha256
    local stage
    stage="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$stage'" EXIT
    tar -xzf "$file" -C "$stage"

    # Fail closed with a *useful* message if yq is missing, an impostor, or
    # snap-confined — before it can mislead us with a bogus "not valid JSON".
    local yq_rc=0
    _require_real_yq || yq_rc=$?
    if [ "$yq_rc" -eq 2 ]; then
        print_error "yq is required for import (manifest + YAML validation) but was not found in PATH."
        print_info "Install the pinned mikefarah binary — run 'pl setup' (verify with 'pl doctor')."
        return 1
    elif [ "$yq_rc" -ne 0 ]; then
        return 1   # _require_real_yq already printed the diagnosis + fix
    fi

    # manifest sanity
    if ! yq eval '.' "$stage/$MANIFEST_NAME" >/dev/null 2>&1; then
        print_error "Refusing import: manifest unreadable — bundle corrupt/truncated, OR yq is snap-confined/an impostor (run 'pl doctor')."
        return 1
    fi

    local expected actual
    for m in "${members[@]}"; do
        [ "$m" = "$MANIFEST_NAME" ] && continue
        # -o=yaml: yq would otherwise infer JSON output from the .json
        # extension and wrap the scalar in quotes.
        expected=$(yq eval -o=yaml ".files[] | select(.path == \"$m\") | .sha256" "$stage/$MANIFEST_NAME" 2>/dev/null) || expected=""
        if [ -z "$expected" ] || [ "$expected" = "null" ]; then
            print_error "Refusing import: $m is not listed in the manifest"
            return 1
        fi
        actual="$(_sha256 "$stage/$m")"
        if [ "$actual" != "$expected" ]; then
            print_error "Refusing import: sha256 mismatch for $m (bundle tampered or corrupted)"
            return 1
        fi
        # Structural validation: refuse unparseable YAML
        if ! yq eval '.' "$stage/$m" >/dev/null 2>&1; then
            print_error "Refusing import: $m is not valid YAML"
            return 1
        fi
    done
    print_status "OK" "Manifest present; all checksums verified"

    # ── Schema-version awareness: warn (not refuse) if a file is NEWER than
    #    this tool understands. Best effort via lib/migrate-schema.sh.
    if [ -f "$PROJECT_ROOT/lib/migrate-schema.sh" ]; then
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT/lib/migrate-schema.sh"
        local sv max
        for m in "${members[@]}"; do
            [ "$m" = "$MANIFEST_NAME" ] && continue
            sv=$(read_schema_version "$stage/$m")
            case "$m" in
                nwp.yml) max="${CURRENT_GLOBAL_SCHEMA:-0}" ;;
                sites/*) max="${CURRENT_SITE_SCHEMA:-0}" ;;
                servers/*) max="${CURRENT_SERVER_SCHEMA:-0}" ;;
                *) max="" ;;
            esac
            if [ -n "$max" ] && [[ "$sv" =~ ^[0-9]+$ ]] && [ "$sv" -gt "$max" ]; then
                print_warning "$m has schema_version $sv, newer than this NWP understands ($max) — update NWP before relying on it"
            fi
        done
    fi

    # ── Plan: what gets written/overwritten
    local writes=() overwrites=()
    for m in "${members[@]}"; do
        [ "$m" = "$MANIFEST_NAME" ] && continue
        if [ -f "$CONFIG_ROOT/$m" ]; then
            overwrites+=("$m")
        else
            writes+=("$m")
        fi
    done

    echo ""
    if [ ${#writes[@]} -gt 0 ]; then
        print_info "New files to write:"
        for m in "${writes[@]}"; do print_info "  + $m"; done
    fi
    if [ ${#overwrites[@]} -gt 0 ]; then
        print_info "Existing files to overwrite (a .pre-import-*.bak copy is kept):"
        for m in "${overwrites[@]}"; do print_info "  ~ $m"; done
    fi
    if [ ${#writes[@]} -eq 0 ] && [ ${#overwrites[@]} -eq 0 ]; then
        print_status "INFO" "Bundle contains no config files to apply"
        return 0
    fi

    if [ $dry_run -eq 1 ]; then
        echo ""
        print_status "INFO" "Dry run — nothing written. Re-run without --dry-run to apply."
        return 0
    fi

    # ── Apply: back up existing files, then write into place
    local stamp
    stamp="$(_utc_stamp)"
    for m in "${overwrites[@]}"; do
        cp -p "$CONFIG_ROOT/$m" "$CONFIG_ROOT/$m.pre-import-$stamp.bak"
    done
    for m in "${writes[@]}" "${overwrites[@]}"; do
        mkdir -p "$CONFIG_ROOT/$(dirname "$m")"
        cp "$stage/$m" "$CONFIG_ROOT/$m"
    done

    echo ""
    print_status "OK" "Imported ${#writes[@]} new + ${#overwrites[@]} overwritten config file(s)"
    if [ ${#overwrites[@]} -gt 0 ]; then
        print_info "Previous versions saved as <file>.pre-import-$stamp.bak"
    fi
    return 0
}

################################################################################
# Main
################################################################################

main() {
    local command="${1:-}"
    shift || true

    case "$command" in
        export) cmd_export "$@" ;;
        import) cmd_import "$@" ;;
        -h|--help|help|"") show_help ;;
        *)
            print_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
