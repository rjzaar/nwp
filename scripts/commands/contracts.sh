#!/bin/bash
set -euo pipefail
################################################################################
# scripts/commands/contracts.sh — `pl contracts <verb>` (P74 Phase 3)
#
# The trust + compatibility layer over the intersite data-contract schemas in
# contracts/ (the wire-shape of the nwc↔ssc boundary). Three jobs, matching the
# three deliverables of P74 Phase 3 (docs/proposals/P74-intersite-data-contract.md
# §Phase-3 / intersite-contract research §2 layer 3):
#
#   compat [--base=<ref>]   Expand-and-contract (BACKWARD) checker: for each
#                           changed contracts/*.schema.json, diff the new file
#                           against its git-committed old version and FAIL on a
#                           breaking delta (field removed, type narrowed, new
#                           required, enum value dropped, additionalProps
#                           tightened). A schema-registry's BACKWARD guarantee
#                           with only git history. Wire as the contracts:compat
#                           CI job (MR-scoped, rules:changes contracts/**).
#
#   sums                    Regenerate contracts/SHA256SUMS from the *.schema.json
#                           files (the pins the pair contract references).
#
#   sign                    Regenerate SHA256SUMS, then minisign-sign it →
#                           contracts/SHA256SUMS.minisig. INTERACTIVE (minisign
#                           prompts for the secret-key password on the tty). The
#                           consumer then trusts the schema bundle by SIGNATURE,
#                           not by host (threat-model trust root).
#
#   verify                  Fail-closed check: (1) minisign-verify SHA256SUMS
#                           against the pinned public key, (2) sha256sum -c the
#                           schema files against SHA256SUMS. Safe for the offline
#                           consumer / CI.
#
#   bundle [--out=DIR]      Assemble the signed cross-repo sync artifact (a tar
#                           of the schemas + SHA256SUMS + .minisig + pubkey) that
#                           the Moodle plugin repo verifies by minisign before
#                           merge. See docs/guides/p74-contract-sync.md.
#
#   sync-plan               Print the cross-repo signed-artifact sync runbook
#                           summary (provider signs → bot PRs → consumer verifies).
#
# Usage: pl contracts <compat|sums|sign|verify|bundle|sync-plan> [opts]
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
export PROJECT_ROOT
NWP_ROOT="$PROJECT_ROOT"
CONTRACTS_DIR="$PROJECT_ROOT/contracts"
SUMS_FILE="$CONTRACTS_DIR/SHA256SUMS"

# shellcheck source=/dev/null
[ -f "$PROJECT_ROOT/lib/ui.sh" ] && source "$PROJECT_ROOT/lib/ui.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/lib/minisign.sh"

_say()  { if command -v print_info    >/dev/null 2>&1; then print_info  "$*"; else printf '%s\n' "$*"; fi; }
_warn() { if command -v print_warning >/dev/null 2>&1; then print_warning "$*"; else printf '%s\n' "$*" >&2; fi; }
_err()  { if command -v print_error   >/dev/null 2>&1; then print_error  "$*"; else printf '%s\n' "$*" >&2; fi; }

# List the schema files (basename, one per line), sorted. Excludes SHA256SUMS,
# validate.py, compat.py — only the *.schema.json wire shapes are pinned.
_schema_files() {
    ( cd "$CONTRACTS_DIR" && ls *.schema.json 2>/dev/null | LC_ALL=C sort )
}

# ---------------------------------------------------------------------------
# compat — expand-and-contract (BACKWARD) gate
# ---------------------------------------------------------------------------
cmd_compat() {
    local base="main"
    for arg in "$@"; do
        case "$arg" in
            --base=*) base="${arg#*=}" ;;
            *) : ;;
        esac
    done

    if ! command -v python3 >/dev/null 2>&1; then
        _err "contracts compat: python3 not found — cannot run the compat checker."
        return 2
    fi

    # Which schema files changed vs the base? Test/CI hook: NWP_CONTRACTS_FILES
    # overrides git (newline-separated repo-relative paths).
    local changed
    if [ -n "${NWP_CONTRACTS_FILES+x}" ]; then
        changed="$(printf '%s\n' "$NWP_CONTRACTS_FILES" | grep -E '^contracts/.*\.schema\.json$' || true)"
    elif git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
         && git -C "$PROJECT_ROOT" rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
        changed="$(git -C "$PROJECT_ROOT" diff --name-only "${base}...HEAD" -- 'contracts/*.schema.json' 2>/dev/null || true)"
    else
        # Fail-safe CLOSED: cannot compute the diff ⇒ check EVERY schema against
        # its committed version (never let "can't compute" skip the gate).
        _warn "contracts compat: cannot resolve base '$base' — checking all schemas (fail-safe closed)."
        changed="$(_schema_files | sed 's#^#contracts/#')"
    fi

    if [ -z "$changed" ]; then
        _say "contracts compat: no contracts/*.schema.json changed vs '$base' — nothing to check."
        return 0
    fi

    local fails=0 f old_tmp
    old_tmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$old_tmp'" RETURN
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        local newfile="$PROJECT_ROOT/$f"
        if [ ! -f "$newfile" ]; then
            _err "BREAKING: $f was DELETED — removing a boundary schema is not backward-compatible."
            fails=$((fails + 1))
            continue
        fi
        # Old committed version. Absent ⇒ newly-added schema ⇒ compatible.
        if [ -n "${NWP_CONTRACTS_BASE_DIR+x}" ]; then
            # Test hook: read the old version from a directory instead of git.
            if [ -f "$NWP_CONTRACTS_BASE_DIR/$(basename "$f")" ]; then
                cp "$NWP_CONTRACTS_BASE_DIR/$(basename "$f")" "$old_tmp"
            else
                _say "contracts compat: $f is new (no baseline) — OK (a new surface)."
                continue
            fi
        elif git -C "$PROJECT_ROOT" cat-file -e "${base}:${f}" 2>/dev/null; then
            git -C "$PROJECT_ROOT" show "${base}:${f}" > "$old_tmp" 2>/dev/null
        else
            _say "contracts compat: $f is new (not in $base) — OK (a new surface)."
            continue
        fi

        echo ""
        _say "contracts compat: $f (vs $base)"
        if python3 "$CONTRACTS_DIR/compat.py" "$old_tmp" "$newfile"; then
            :
        else
            fails=$((fails + 1))
        fi
    done <<< "$changed"

    echo ""
    if [ "$fails" -gt 0 ]; then
        _err "contracts compat: $fails schema(s) have a BREAKING change (expand-and-contract violated)."
        _say "  Fix-forward: keep old fields, add new ones OPTIONAL, and bump contract_version"
        _say "  in pairs/ssc.pair-contract.yml (the provider promotes first — pair_guard)."
        return 1
    fi
    _say "contracts compat: all changed schemas are backward-compatible. ✓"
    return 0
}

# ---------------------------------------------------------------------------
# sums — regenerate contracts/SHA256SUMS
# ---------------------------------------------------------------------------
cmd_sums() {
    local files; files="$(_schema_files)"
    [ -n "$files" ] || { _err "contracts sums: no *.schema.json in $CONTRACTS_DIR"; return 1; }
    ( cd "$CONTRACTS_DIR" && sha256sum $files > SHA256SUMS )
    _say "contracts sums: regenerated $SUMS_FILE"
    ( cd "$CONTRACTS_DIR" && cat SHA256SUMS )
    return 0
}

# ---------------------------------------------------------------------------
# sign — regenerate SHA256SUMS + minisign-sign it (interactive)
# ---------------------------------------------------------------------------
cmd_sign() {
    cmd_sums >/dev/null || return 1
    if ! minisign_check 2>/dev/null; then
        _err "contracts sign: minisign not installed (sudo apt-get install -y minisign)."
        return 1
    fi
    if ! minisign_keys_exist; then
        _err "contracts sign: minisign keys not found at $MINISIGN_KEY_DIR."
        _say  "  Generate once: source lib/minisign.sh && minisign_generate_keys"
        return 1
    fi
    _say "contracts sign: signing $SUMS_FILE (minisign will prompt for the key password)…"
    # Read the password from the controlling tty even when stdin is redirected
    # (same fix as the ver-kit signing loop, ops#25). If there is no tty (CI),
    # signing is an operator step — CI only VERIFIES a pre-signed bundle.
    if [ -e /dev/tty ]; then
        minisign_sign "$SUMS_FILE" "NWP intersite contract schemas $(date -I)" </dev/tty || return 1
    else
        minisign_sign "$SUMS_FILE" "NWP intersite contract schemas $(date -I)" || return 1
    fi
    _say "contracts sign: wrote ${SUMS_FILE}.minisig — commit it alongside contracts/."
    return 0
}

# ---------------------------------------------------------------------------
# verify — fail-closed: signature + checksums
# ---------------------------------------------------------------------------
cmd_verify() {
    local pubkey="${1:-$MINISIGN_PUBLIC_KEY}"
    local ok=0

    if [ ! -f "$SUMS_FILE" ]; then
        _err "contracts verify: $SUMS_FILE missing — cannot verify (fail-closed)."
        return 1
    fi

    # 1. Signature (fail-closed on a missing .minisig — the whole point is that
    #    the consumer trusts by signature, not host).
    if [ -f "${SUMS_FILE}.minisig" ]; then
        if minisign_check 2>/dev/null && [ -f "$pubkey" ]; then
            if minisign_verify "$SUMS_FILE" "$pubkey" >/dev/null 2>&1; then
                _say "contracts verify: signature OK (minisign, pinned key)."
            else
                _err "contracts verify: SIGNATURE INVALID — refusing to trust the schemas."
                ok=1
            fi
        else
            _warn "contracts verify: minisign or public key unavailable — cannot check signature."
            ok=1
        fi
    else
        _err "contracts verify: ${SUMS_FILE}.minisig MISSING — the bundle is UNSIGNED (fail-closed)."
        _say  "  Operator TODO: run 'pl contracts sign' to produce it (needs the minisign password)."
        ok=1
    fi

    # 2. Checksums match the on-disk schema files.
    if ( cd "$CONTRACTS_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then
        _say "contracts verify: checksums match on-disk schemas."
    else
        _err "contracts verify: CHECKSUM MISMATCH — a schema file differs from SHA256SUMS."
        ok=1
    fi

    [ "$ok" -eq 0 ] && _say "contracts verify: OK ✓"
    return "$ok"
}

# ---------------------------------------------------------------------------
# bundle — assemble the signed cross-repo sync artifact
# ---------------------------------------------------------------------------
cmd_bundle() {
    local out="$PROJECT_ROOT/dist"
    for arg in "$@"; do
        case "$arg" in --out=*) out="${arg#*=}" ;; esac
    done
    mkdir -p "$out"
    [ -f "${SUMS_FILE}.minisig" ] || _warn "contracts bundle: SHA256SUMS.minisig absent — bundle will be UNSIGNED (run 'pl contracts sign')."
    local ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"
    local name="nwp-contracts-${ts}.tar.gz"
    local files; files="$(_schema_files)"
    ( cd "$CONTRACTS_DIR" && tar -czf "$out/$name" \
        $files SHA256SUMS \
        $( [ -f SHA256SUMS.minisig ] && echo SHA256SUMS.minisig ) )
    # Ship the pinned public key beside the bundle so the consumer can verify.
    [ -f "$MINISIGN_PUBLIC_KEY" ] && cp "$MINISIGN_PUBLIC_KEY" "$out/nwp-deploy.pub" 2>/dev/null || true
    _say "contracts bundle: $out/$name"
    _say "  Consumer verifies with: minisign -Vm SHA256SUMS -p nwp-deploy.pub  &&  sha256sum -c SHA256SUMS"
    echo "$out/$name"
    return 0
}

cmd_sync_plan() {
    cat <<'EOF'
Cross-repo signed-artifact sync (P74 Phase 3) — provider → Moodle plugin repo
=============================================================================
  1. PROVIDER (nwc side, this repo):
       pl contracts compat --base=main     # gate: backward-compatible change
       pl contracts sign                    # regenerate + minisign SHA256SUMS
       pl contracts bundle                  # → dist/nwp-contracts-<ts>.tar.gz
     Commit contracts/SHA256SUMS.minisig alongside the schema change.
  2. BOT (no running service required): opens a PR into the Moodle plugin repo
       (auth_nwc / local_nwc_copyright_sync / local_feedback) that drops the
       bundle's contracts/ + SHA256SUMS + SHA256SUMS.minisig under the plugin's
       vendored contract dir. See docs/guides/p74-contract-sync.md for the
       helper invocation.
  3. CONSUMER (Moodle plugin CI) verifies BEFORE merge:
       minisign -Vm SHA256SUMS -p nwp-deploy.pub   # signature (pinned key)
       sha256sum -c SHA256SUMS                       # files match
     A bad signature or checksum FAILS the plugin's pipeline (fail-closed).
  Trust flows through the minisign signature, NOT the transport (no broker,
  no cross-repo call at MR time) — mirrors the build-host→ver signed flow.
EOF
    return 0
}

main() {
    local verb="${1:-help}"; shift || true
    case "$verb" in
        compat)    cmd_compat "$@" ;;
        sums)      cmd_sums "$@" ;;
        sign)      cmd_sign "$@" ;;
        verify)    cmd_verify "$@" ;;
        bundle)    cmd_bundle "$@" ;;
        sync-plan) cmd_sync_plan "$@" ;;
        -h|--help|help)
            sed -n '3,49p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            ;;
        *)
            _err "pl contracts: unknown verb '$verb' (compat|sums|sign|verify|bundle|sync-plan)"
            return 2
            ;;
    esac
}

main "$@"
