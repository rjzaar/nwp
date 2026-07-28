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
#   crossref [<pair>|--all] CROSS-REPO promise gate (item 8). A pair contract
#                           names endpoints and Moodle web-service functions
#                           that live in a DIFFERENT repository. This verb
#                           checks the other repo actually honours them:
#                             * every WS function the provider code calls is
#                               defined in the consumer plugin tree's
#                               db/services.php  → UNDEFINED-WS
#                             * every `smoke_urls` entry with side: consumer
#                               names a file that exists  → MISSING-PATH
#                           Fail-closed on an empty corpus: a checkout that is
#                           not present reports CANNOT-VERIFY (non-zero), never
#                           a silent green.
#
#   erasure [<pair>|--all] [--strict]
#                           ERASURE-CHANNEL gate (ops#81). An Art.17 obligation
#                           lands the day a real member asks, so the question
#                           "is there a defined, pinned, closed erasure channel
#                           for this pair?" must be answerable by a verb rather
#                           than by reading three files and a README.
#                           STRUCTURAL failures (always fatal):
#                             * no surfaces.erasure block      → CHANNEL-UNDEFINED
#                             * no schema: pointer             → SCHEMA-UNPINNED
#                             * schema file absent/unparseable → SCHEMA-MISSING
#                             * schema not additionalProperties:false, or with
#                               an empty required[]            → SCHEMA-NOT-CLOSED
#                             * erasure.receiver_path / sender_path unset
#                                                              → CHANNEL-UNDEFINED
#                           ESTATE + OPERATOR findings (reported; fatal only
#                           under --strict, because they are true-and-known
#                           operator states, not gate bugs — the ops#138
#                           precedent):
#                             * declared path not present under the crossref
#                               roots                          → NOT-DEPLOYED
#                             * semantics_approved is not true → SEMANTICS-UNAPPROVED
#                             * backup_ceiling unset           → NO-BACKUP-CEILING
#                           An unparseable or absent contract is CANNOT-VERIFY,
#                           never a silent green.
#
#   key-rotation [<pair>|--all]
#                           OIDC SIGNING-KEY ROTATION INVARIANT (ops#82). The
#                           nwc→ssc rotation runbook is safe only because the
#                           Moodle consumer never verifies the id_token
#                           signature. That fact lived in prose alone, so
#                           nothing failed when the code drifted. This verb
#                           couples the claim to the code, fail-closed:
#                             * verifies=false → the consumer tree must contain
#                               no executable signature/JWKS code → CLAIM-DRIFT
#                             * verifies=true  → the issuer must support key
#                               overlap, tokens must carry a kid, announce /
#                               overlap / retire windows must be non-zero, and
#                               a refetch-on-unknown-kid implementation must
#                               exist → OVERLAP-REQUIRED / NO-REFETCH
#                           The unsafe middle state (a verifying consumer on a
#                           single-key hard swap) is therefore unreachable.
#
# Usage: pl contracts <compat|sums|sign|verify|bundle|sync-plan|crossref|key-rotation|erasure> [opts]
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# The repo this script ships in (libs always come from here). PROJECT_ROOT is
# the tree being INSPECTED and is honoured when pre-set, so the bats fixtures
# can point contracts/ + pairs/ + sites/ at a scratch dir.
NWP_REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$NWP_REPO_ROOT}"
export PROJECT_ROOT
NWP_ROOT="$PROJECT_ROOT"
CONTRACTS_DIR="$PROJECT_ROOT/contracts"
SUMS_FILE="$CONTRACTS_DIR/SHA256SUMS"
PAIRS_DIR="${NWP_PAIR_CONTRACT_DIR:-$PROJECT_ROOT/pairs}"

# shellcheck source=/dev/null
[ -f "$NWP_REPO_ROOT/lib/ui.sh" ] && source "$NWP_REPO_ROOT/lib/ui.sh"
# shellcheck source=/dev/null
source "$NWP_REPO_ROOT/lib/minisign.sh"

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

# ---------------------------------------------------------------------------
# trust-anchor assertion — EXACTLY ONE signature file in contracts/
# ---------------------------------------------------------------------------
# Two conflicting copies of contracts/SHA256SUMS.minisig were found in the
# working tree on 2026-07-26: the tracked one (which verifies) and an untracked
# older backup named SHA256SUMS.minisig.<suffix> (which does NOT). A trust
# anchor with more than one candidate is not a trust anchor: whichever copy
# happens to win a `cp`/`tar` decides what the offline consumer believes.
# Fail closed.
# Echoes the candidate list; returns 1 when the anchor is ambiguous.
_assert_single_trust_anchor() {
    local found=() f
    for f in "$CONTRACTS_DIR"/*.minisig*; do
        [ -e "$f" ] || continue
        found+=("$(basename "$f")")
    done
    if [ "${#found[@]}" -gt 1 ]; then
        _err "contracts: AMBIGUOUS TRUST ANCHOR — ${#found[@]} signature files in $CONTRACTS_DIR:"
        for f in "${found[@]}"; do _err "    $f"; done
        _say  "  Exactly one *.minisig may exist. Delete the strays (they are ignored by"
        _say  "  contracts/.gitignore, so they are local debris) and re-run."
        return 1
    fi
    return 0
}

cmd_verify() {
    local pubkey="${1:-$MINISIGN_PUBLIC_KEY}"
    local ok=0

    if [ ! -f "$SUMS_FILE" ]; then
        _err "contracts verify: $SUMS_FILE missing — cannot verify (fail-closed)."
        return 1
    fi

    # 0. Exactly one trust anchor (see above).
    _assert_single_trust_anchor || ok=1

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
    # Never assemble a bundle while the trust anchor is ambiguous — the tar
    # would pick a copy by name and the consumer would trust it blind.
    _assert_single_trust_anchor || return 1
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

# ---------------------------------------------------------------------------
# crossref — the CROSS-REPO promise gate (item 8)
# ---------------------------------------------------------------------------
# A pair contract in pairs/ makes promises about a repository that is NOT this
# one (the Moodle plugin repo, checked out at sites/<consumer>/.plugin-src/).
# Two of those promises were silently false for weeks:
#
#   * nwc's Art.9 withdrawal push calls the Moodle web-service function
#     `auth_nwc_set_consent`, which ss-moodle-plugins origin/main did not
#     define. Because the failure path is DESIGNED to degrade gracefully, every
#     withdrawal told the member "we could not confirm that saving was switched
#     off on the Saint School just now" — forever, looking like a transient
#     network blip rather than a permanently absent endpoint.
#   * both pair contracts declared liveness probes at
#     /local/nwc_copyright_sync/status.php and /local/feedback/api.php. Neither
#     file has ever existed. A probe that can never go green trains everyone to
#     ignore its output.
#
# This verb makes both classes impossible to reintroduce.
#
# Contract block consumed (see pairs/README.md):
#   crossref:
#     provider_roots:   [ <repo-relative dirs holding the PROVIDER code> ]
#     consumer_roots:   [ <repo-relative dirs holding the CONSUMER plugin tree> ]
#     core_paths:       [ <consumer paths served by Moodle CORE, exempt> ]
#     core_ws_functions:[ <WS fns provided by Moodle CORE, exempt> ]
#
# Exit: 0 all promises honoured · 1 a promise is broken or CANNOT-VERIFY.
# ---------------------------------------------------------------------------

_crossref_yq() {
    # $1 = file, $2 = yq expression. Echoes nothing on absence.
    local yq_bin; yq_bin="$(command -v yq || true)"
    [ -n "$yq_bin" ] || return 1
    "$yq_bin" e "$2" "$1" 2>/dev/null | grep -v '^null$' || true
}

# Existing directories among a newline-separated list of repo-relative roots.
_crossref_existing_roots() {
    local r
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        [ -d "$PROJECT_ROOT/$r" ] && printf '%s\n' "$PROJECT_ROOT/$r"
    done
}

# Every Moodle web-service function name the provider code references.
# Recognises the two shapes nwc actually uses:
#     public const WS_FUNCTION = 'auth_nwc_set_consent';
#     'wsfunction' => 'auth_nwc_set_consent',
# Variable wsfunctions ('wsfunction' => $function) are deliberately NOT
# reported — they are resolved at runtime and cannot be checked statically.
_crossref_ws_functions() {
    local roots=("$@")
    [ "${#roots[@]}" -gt 0 ] || return 0
    grep -rhoE "(WS_FUNCTION[[:space:]]*=|'wsfunction'[[:space:]]*=>|\"wsfunction\"[[:space:]]*=>)[[:space:]]*['\"][a-z][a-z0-9_]+['\"]" \
        --include='*.php' --include='*.module' --include='*.inc' "${roots[@]}" 2>/dev/null \
        | grep -oE "['\"][a-z][a-z0-9_]+['\"]$" \
        | tr -d "'\"" \
        | LC_ALL=C sort -u
}

# 0 when <name> is declared in a db/services.php under any consumer root.
_crossref_ws_defined() {
    local name="$1"; shift
    local roots=("$@")
    [ "${#roots[@]}" -gt 0 ] || return 1
    grep -rqE "['\"]${name}['\"][[:space:]]*=>" --include='services.php' "${roots[@]}" 2>/dev/null
}

cmd_crossref() {
    local want=() all=false quiet=false arg
    for arg in "$@"; do
        case "$arg" in
            --all)   all=true ;;
            --quiet) quiet=true ;;
            -*)      _err "contracts crossref: unknown option '$arg'"; return 2 ;;
            *)       want+=("$arg") ;;
        esac
    done

    if ! command -v yq >/dev/null 2>&1; then
        _err "contracts crossref: CANNOT-VERIFY — yq not installed (the contract cannot be parsed)."
        return 1
    fi

    if [ "$all" = true ] || [ "${#want[@]}" -eq 0 ]; then
        want=()
        local f
        for f in "$PAIRS_DIR"/*.pair-contract.yml; do
            [ -e "$f" ] || continue
            want+=("$(basename "$f" .pair-contract.yml)")
        done
        if [ "${#want[@]}" -eq 0 ]; then
            _err "contracts crossref: CANNOT-VERIFY — no pair contracts in $PAIRS_DIR."
            return 1
        fi
    fi

    local rc=0 pair
    for pair in "${want[@]}"; do
        _crossref_one "$pair" "$quiet" || rc=1
    done
    if [ "$rc" -eq 0 ]; then
        [ "$quiet" = true ] || _say "contracts crossref: OK ✓ — every cross-repo promise is honoured."
    fi
    return "$rc"
}

_crossref_one() {
    local pair="$1" quiet="${2:-false}"
    local contract="$PAIRS_DIR/${pair}.pair-contract.yml"
    local bad=0

    if [ ! -f "$contract" ]; then
        _err "[$pair] CANNOT-VERIFY: no contract at $contract"
        return 1
    fi
    if [ -z "$(_crossref_yq "$contract" '.crossref')" ]; then
        _err "[$pair] CANNOT-VERIFY: the contract declares no 'crossref:' corpus."
        _say  "  Add crossref.provider_roots + crossref.consumer_roots so the cross-repo"
        _say  "  promises can be checked. An unverifiable contract is not a passing one."
        return 1
    fi

    local prov_roots=() cons_roots=() r
    while IFS= read -r r; do [ -n "$r" ] && prov_roots+=("$r"); done < <(
        _crossref_yq "$contract" '.crossref.provider_roots[]' | _crossref_existing_roots)
    while IFS= read -r r; do [ -n "$r" ] && cons_roots+=("$r"); done < <(
        _crossref_yq "$contract" '.crossref.consumer_roots[]' | _crossref_existing_roots)

    if [ "${#prov_roots[@]}" -eq 0 ]; then
        _err "[$pair] CANNOT-VERIFY: none of the declared crossref.provider_roots exist here."
        _crossref_yq "$contract" '.crossref.provider_roots[]' | while IFS= read -r r; do
            [ -n "$r" ] && _say "    absent: $r"
        done
        bad=1
    fi
    if [ "${#cons_roots[@]}" -eq 0 ]; then
        _err "[$pair] CANNOT-VERIFY: none of the declared crossref.consumer_roots exist here."
        _crossref_yq "$contract" '.crossref.consumer_roots[]' | while IFS= read -r r; do
            [ -n "$r" ] && _say "    absent: $r"
        done
        bad=1
    fi
    [ "$bad" -eq 0 ] || return 1

    # --- exemption lists -----------------------------------------------------
    local core_ws core_paths
    core_ws="$(_crossref_yq "$contract" '.crossref.core_ws_functions[]')"
    core_paths="$(_crossref_yq "$contract" '.crossref.core_paths[]')"

    [ "$quiet" = true ] || _say "[$pair] corpus  provider=${#prov_roots[@]} root(s)  consumer=${#cons_roots[@]} root(s)"

    # --- 1. web-service functions -------------------------------------------
    local fn ws_seen=0
    while IFS= read -r fn; do
        [ -n "$fn" ] || continue
        ws_seen=$((ws_seen + 1))
        if [ "$fn" != "${fn#core_}" ] || printf '%s\n' "$core_ws" | grep -qxF "$fn"; then
            [ "$quiet" = true ] || _say "[$pair] ws  core-exempt  $fn"
            continue
        fi
        if _crossref_ws_defined "$fn" "${cons_roots[@]}"; then
            [ "$quiet" = true ] || _say "[$pair] ws  OK           $fn"
        else
            _err "[$pair] ws  UNDEFINED-WS $fn — provider code calls it; no db/services.php in the"
            _err "                          consumer tree defines it. The call fails at runtime."
            bad=1
        fi
    done < <(_crossref_ws_functions "${prov_roots[@]}")

    # Zero WS call sites is legal (not every pair uses web services) but it is
    # ALSO what a stale provider checkout looks like — say so out loud rather
    # than leaving an empty section that reads as "checked, all fine".
    if [ "$ws_seen" -eq 0 ]; then
        _warn "[$pair] ws  NONE-FOUND  no literal wsfunction call site in the checked-out provider"
        _warn "                        roots. If the provider is meant to call one, the checkout is"
        _warn "                        on the wrong branch — this section verified nothing."
    fi

    # --- 2. consumer smoke_urls point at files that exist --------------------
    local p rel found root
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        rel="${p%%\?*}"; rel="${rel%%#*}"; rel="${rel#/}"
        if printf '%s\n' "$core_paths" | grep -qxF "$rel"; then
            [ "$quiet" = true ] || _say "[$pair] url core-exempt  /$rel"
            continue
        fi
        found=false
        for root in "${cons_roots[@]}"; do
            [ -e "$root/$rel" ] && { found=true; break; }
        done
        if [ "$found" = true ]; then
            [ "$quiet" = true ] || _say "[$pair] url OK           /$rel"
        else
            _err "[$pair] url MISSING-PATH /$rel — the contract names a consumer endpoint that"
            _err "                          does not exist in the consumer tree. The probe can"
            _err "                          never go green; declare it under crossref.core_paths"
            _err "                          if Moodle core serves it."
            bad=1
        fi
    done < <(_crossref_yq "$contract" '.smoke_urls[] | select(.side == "consumer") | .path')

    return "$bad"
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

# ---------------------------------------------------------------------------
# guards — the GUARD-ADOPTION gate (ops#138)
# ---------------------------------------------------------------------------
# A safety guard that nothing calls is not a control; it is a capability with a
# reassuring name. ops#138 is the estate's live example: `Art9ConsentGate::
# assertMayWriteArt9()` — the Drupal-side Art.9 hard write-gate — has zero
# production call sites, and `nwc_privacy/tests/src/PrivacySweep.php` "verifies"
# it by grepping for the string, so the gap reported as covered for weeks.
#
# This verb asks the only question that distinguishes a control from a comment:
# is the symbol CALLED, in executable position, from a file other than the one
# that defines it?
#
# Contract block consumed:
#   guards:
#     - symbol: assertMayWriteArt9      # the function/method name
#       side: provider|consumer         # which crossref root set to scan
#       why: "Art.9 hard write-gate"    # printed with the failure
#       defined_in: "src/.../Gate.php"  # excluded from the call-site search
#
# Deliberately NOT folded into `crossref` (which blocks `pl pair-smoke` at plan
# time): ops#138 is red on the real estate right now and is an operator-owned
# decision. Making a true finding visible and turning it into a surprise
# promotion block are different calls; only the first is an agent's to make.
#
# Exit: 0 every declared guard is adopted (or none declared) · 1 otherwise.
# ---------------------------------------------------------------------------

# Strip PHP comments from stdin: MULTI-LINE /* */ and /** */ docblocks (state
# machine, not a per-line regex), plus // and # line comments — WITHOUT
# mistaking a comment opener that appears INSIDE A STRING LITERAL for a comment.
#
# The multi-line case is load-bearing, not pedantry. The first version of this
# gate used a per-line `sed` and reported the ops#138 guard ADOPTED because
# nwc_privacy/src/Exception/Art9ConsentRequiredException.php has the line
# `* Art9ConsentGate::assertMayWriteArt9($uid) first;` inside a docblock. A
# guard-adoption gate that goes green on a comment is the exact defect it exists
# to find.
#
# ops#152 — STRING AWARENESS. The previous version took the earliest `//`, `#`
# or `/*` on the line regardless of context, so it truncated ordinary code:
#
#   $u = "https://nwc.example.org/.well-known/jwks.json";  ->  $u = "https:
#   $hash = "#not-a-comment-jwks";                         ->  $hash = "
#
# Every token after the `//` — including `jwks` — was deleted BEFORE the grep,
# so a URL naming a JWKS endpoint was invisible to a gate whose entire job is
# to notice JWKS code. That is a fail-OPEN blind spot in a fail-closed gate:
# it does not merely miss a finding, it destroys the evidence first. Verified
# 2026-07-28 against the live function.
#
# The scanner now tracks single- and double-quoted strings with backslash
# escapes, so a comment opener inside a literal is kept as code.
#
# String state is deliberately reset at end-of-line rather than carried across
# lines. PHP strings *can* span lines, but of the two failure modes only this
# one is fail-CLOSED: an unterminated quote then leaves the following lines
# visible to the grep (possibly a false positive, which a human adjudicates),
# whereas carrying the state would let one stray quote swallow the rest of the
# file and hide real verification code (a false negative, which nobody sees).
#
# ACCEPTED RESIDUAL: a PHP 8 attribute `#[Foo]` is still treated as a `#`
# comment and truncates the line. Pre-existing behaviour, left alone to keep
# this change reviewable; attributes do not carry JWKS/JWT tokens, and the
# failure is confined to the line the attribute is on.
_guards_strip_comments() {
    awk '
    {
        line = $0
        n = length(line)
        out = ""
        instr = ""          # "" | "\x27" | "\"" — reset every line, see header
        i = 1
        while (i <= n) {
            c = substr(line, i, 1)
            if (inblock) {
                if (c == "*" && substr(line, i + 1, 1) == "/") { inblock = 0; i += 2 }
                else { i++ }
                continue
            }
            if (instr != "") {
                out = out c
                if (c == "\\") { out = out substr(line, i + 1, 1); i += 2; continue }
                if (c == instr) { instr = "" }
                i++
                continue
            }
            if (c == "\"" || c == "\x27") { instr = c; out = out c; i++; continue }
            if (c == "/" && substr(line, i + 1, 1) == "*") { inblock = 1; i += 2; continue }
            if (c == "/" && substr(line, i + 1, 1) == "/") { break }
            if (c == "#") { break }
            out = out c
            i++
        }
        print out
    }' 2>/dev/null
}

# Non-comment call sites of <symbol> under <roots>, excluding every path in
# <exclude-list> (newline separated). Matches ->sym( / ::sym( / sym( in
# executable position.
_guards_call_sites() { # <symbol> <exclude-list> <roots...>
    local sym="$1" excludes="$2"; shift 2
    local roots=("$@") f
    [ "${#roots[@]}" -gt 0 ] || return 0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -n "$excludes" ] && printf '%s\n' "$excludes" | grep -qxF "$f"; then continue; fi
        if _guards_strip_comments < "$f" \
             | grep -qE "(->|::)?[[:space:]]*\b${sym}[[:space:]]*\("; then
            printf '%s\n' "$f"
        fi
    done < <(grep -rlE "\b${sym}\b" --include='*.php' --include='*.module' --include='*.inc' \
                --include='*.install' --include='*.theme' "${roots[@]}" 2>/dev/null)
}

cmd_guards() {
    local want=() all=false arg
    for arg in "$@"; do
        case "$arg" in
            --all) all=true ;;
            -*)    _err "contracts guards: unknown option '$arg'"; return 2 ;;
            *)     want+=("$arg") ;;
        esac
    done

    if ! command -v yq >/dev/null 2>&1; then
        _err "contracts guards: CANNOT-VERIFY — yq not installed (the contract cannot be parsed)."
        return 1
    fi

    if [ "$all" = true ] || [ "${#want[@]}" -eq 0 ]; then
        want=()
        local f
        for f in "$PAIRS_DIR"/*.pair-contract.yml; do
            [ -e "$f" ] || continue
            want+=("$(basename "$f" .pair-contract.yml)")
        done
        if [ "${#want[@]}" -eq 0 ]; then
            _err "contracts guards: CANNOT-VERIFY — no pair contracts in $PAIRS_DIR."
            return 1
        fi
    fi

    local rc=0 pair
    for pair in "${want[@]}"; do
        _guards_one "$pair" || rc=1
    done
    return "$rc"
}

_guards_one() {
    local pair="$1"
    local contract="$PAIRS_DIR/${pair}.pair-contract.yml"

    if [ ! -f "$contract" ]; then
        _err "[$pair] CANNOT-VERIFY: no contract at $contract"
        return 1
    fi

    local count
    count="$(_crossref_yq "$contract" '.guards | length' | head -1)"
    if [ -z "$count" ] || [ "$count" = "0" ]; then
        _say "[$pair] guards NONE-DECLARED — this contract declares no safety guards to check."
        _say "  If this pair has a write-gate, consent gate or similar, declare it under"
        _say "  'guards:' so a guard with no callers cannot hide behind its own documentation."
        return 0
    fi

    local prov_roots=() cons_roots=() r
    while IFS= read -r r; do [ -n "$r" ] && prov_roots+=("$r"); done < <(
        _crossref_yq "$contract" '.crossref.provider_roots[]' | _crossref_existing_roots)
    while IFS= read -r r; do [ -n "$r" ] && cons_roots+=("$r"); done < <(
        _crossref_yq "$contract" '.crossref.consumer_roots[]' | _crossref_existing_roots)

    local bad=0 i sym side why defined roots=() sites exclude
    for (( i=0; i<count; i++ )); do
        sym="$(_crossref_yq "$contract" ".guards[$i].symbol")"
        side="$(_crossref_yq "$contract" ".guards[$i].side")"; [ -n "$side" ] || side="provider"
        why="$(_crossref_yq "$contract" ".guards[$i].why")"
        defined="$(_crossref_yq "$contract" ".guards[$i].defined_in")"
        [ -n "$sym" ] || continue

        if [ "$side" = "consumer" ]; then roots=("${cons_roots[@]:-}"); else roots=("${prov_roots[@]:-}"); fi
        # Drop the empty-array placeholder bash leaves behind.
        [ "${#roots[@]}" -eq 1 ] && [ -z "${roots[0]}" ] && roots=()

        if [ "${#roots[@]}" -eq 0 ]; then
            _err "[$pair] guard $sym: CANNOT-VERIFY — no ${side} root from crossref.${side}_roots exists here."
            _say  "  A guard scanned over an empty corpus reports adopted. Refusing to."
            bad=1
            continue
        fi

        # The definition must be excluded under EVERY declared root, not just
        # the first that happens to hold it: dev/ and stg/ are both provider
        # roots and both carry the file, so a `break` here let the stg copy of
        # the guard's own definition count as adoption.
        exclude=""
        if [ -n "$defined" ]; then
            for r in "${roots[@]}"; do
                [ -f "$r/$defined" ] && exclude="${exclude}${r}/${defined}"$'\n'
            done
        fi

        sites="$(_guards_call_sites "$sym" "$exclude" "${roots[@]}")"
        if [ -z "$sites" ]; then
            _err "[$pair] guard UNCALLED-GUARD  $sym  (${why:-no rationale recorded})"
            _say  "  Declared as a control, called from nowhere. Every remaining reference is a"
            _say  "  comment, a docblock or a name in a list — which is how this stayed invisible."
            [ -n "$exclude" ] && printf '%s' "$exclude" | sed 's|^|  defined in: |'
            bad=1
        else
            local n; n="$(printf '%s\n' "$sites" | grep -c .)"
            _say "[$pair] guard adopted      $sym  (${n} call site(s))"
            printf '%s\n' "$sites" | sed 's|^|    |'
        fi
    done

    [ "$bad" -eq 0 ] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# key-rotation — the OIDC signing-key rotation invariant (ops#82)
#
# WHY THIS EXISTS. The nwc→ssc rotation runbook is safe for exactly one reason:
# the Moodle consumer never verifies the id_token signature, so swapping the
# provider's signing key cannot invalidate anything the consumer holds. Every
# leg of that argument used to live only in prose (a comment in auth.php, a
# paragraph in the runbook, a `false` in the contract). Nothing failed if the
# code drifted out from under it — and the day a consumer starts verifying
# signatures, the documented hard swap becomes a total SSO outage, silently.
#
# This verb turns the argument into a coupled, fail-closed check:
#
#   consumer_verifies_signature: false  →  the consumer tree must contain NO
#                                          executable signature-verification
#                                          code            (else CLAIM-DRIFT)
#   consumer_verifies_signature: true   →  the provider must be able to publish
#                                          overlapping keys, tokens must carry
#                                          a kid, announce/overlap/retire
#                                          windows must be real, and a
#                                          refetch-on-unknown-kid implementation
#                                          must exist      (else OVERLAP-REQUIRED)
#
# So you cannot enable verification without first building the overlap path,
# and you cannot claim the overlap path without the machinery. The unsafe
# middle state — verifying consumer, single-key hard swap — is unreachable.
#
# Contract block consumed (pairs/<consumer>.pair-contract.yml → oidc.key_rotation):
#   consumer_verifies_signature: <bool>   the load-bearing fact
#   tokens_carry_kid:            <bool>   can a verifier select key by kid?
#   provider_supports_overlap:   <bool>   can the issuer publish 2 keys at once?
#   mode:                        hard_swap | overlap
#   announce_window / overlap_window / retire_after   durations (0 = none)
#   refetch_impl:                <repo-relative file>  required when verifying
#   verification_exempt_paths:   [ <paths whose matches are reviewed + waived> ]
#   runbook:                     <repo-relative doc that must exist>
#
# Exit: 0 invariant holds · 1 broken or CANNOT-VERIFY.
# ---------------------------------------------------------------------------

# Is <path> waived by the contract's verification_exempt_paths?
#
# ops#152 — entries are SHELL GLOBS and are tested against TWO anchorings:
#   * the PROJECT_ROOT-relative path  (e.g. sites/ssc/dev/mod/lti/token.php)
#   * the SCANNED-ROOT-relative path  (e.g. mod/lti/token.php)
# The second is what makes a declared waiver readable and portable: the LTI
# exemptions are properties of *Moodle*, so they are written the way Moodle
# names them (`mod/lti/**`) and do not have to repeat wherever a particular
# estate happens to mount the core tree.
#
# An entry containing no glob metacharacter still matches exactly, so this is
# backward compatible with the previous `grep -qxF` semantics.
_keyrot_is_exempt() { # <project-rel path> <root-rel path> <exempt list>
    local rel="$1" rrel="$2" excludes="$3" e
    [ -n "$excludes" ] || return 1
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        # shellcheck disable=SC2254  # $e is a glob ON PURPOSE
        case "$rel"  in $e) return 0 ;; esac
        # shellcheck disable=SC2254
        case "$rrel" in $e) return 0 ;; esac
    done <<<"$excludes"
    return 1
}

# Executable (comment-stripped) signature-verification call sites under <roots>.
# Emits "<file>:<line>:<text>" so a human can adjudicate each hit.
#
# Iterates PER ROOT (rather than handing every root to one grep) so each hit
# knows which root it came from and can be matched against a root-relative
# exemption.
#
# PERFORMANCE (ops#152, measured on the real ssc tree, 16,517 core PHP/inc
# files): the `grep -rlE` prefilter is the only thing that touches all 16.5k
# files and costs 0.54s; it narrows to 80 candidates, and only those are
# comment-stripped. End-to-end 0.74s. The expensive per-character awk pass is
# therefore bounded by the prefilter, not by the tree size — which is why
# widening the corpus to core does not need the grep to be scoped to
# "interesting" subdirectories. Scoping it would also have reintroduced the
# very fail-open this issue is about: a gate that only looks where it already
# expects trouble.
_keyrot_verify_sites() { # <exclude-list> <roots...>
    local excludes="$1"; shift
    local roots=("$@") root f rel rrel
    [ "${#roots[@]}" -gt 0 ] || return 0
    local pat='JWT::decode|Firebase.{0,2}JWT|CachedKeySet|openssl_verify|verify_?signature|validateSignature|jwks|id_token'
    for root in "${roots[@]}"; do
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            rel="${f#"$PROJECT_ROOT"/}"
            rrel="${f#"$root"/}"
            _keyrot_is_exempt "$rel" "$rrel" "$excludes" && continue
            _guards_strip_comments < "$f" | grep -nEi "$pat" 2>/dev/null \
                | while IFS= read -r hit; do printf '%s:%s\n' "$rel" "$hit"; done
        done < <(grep -rlEi "$pat" --include='*.php' --include='*.module' --include='*.inc' \
                    --include='*.install' --include='*.theme' "$root" 2>/dev/null)
    done
}

cmd_key_rotation() {
    local want=() all=false quiet=false arg
    for arg in "$@"; do
        case "$arg" in
            --all)   all=true ;;
            --quiet) quiet=true ;;
            -*)      _err "contracts key-rotation: unknown option '$arg'"; return 2 ;;
            *)       want+=("$arg") ;;
        esac
    done

    if ! command -v yq >/dev/null 2>&1; then
        _err "contracts key-rotation: CANNOT-VERIFY — yq not installed (the contract cannot be parsed)."
        return 1
    fi

    if [ "$all" = true ] || [ "${#want[@]}" -eq 0 ]; then
        want=()
        local f
        for f in "$PAIRS_DIR"/*.pair-contract.yml; do
            [ -e "$f" ] || continue
            want+=("$(basename "$f" .pair-contract.yml)")
        done
        if [ "${#want[@]}" -eq 0 ]; then
            _err "contracts key-rotation: CANNOT-VERIFY — no pair contracts in $PAIRS_DIR."
            return 1
        fi
    fi

    local rc=0 pair
    for pair in "${want[@]}"; do
        _keyrot_one "$pair" "$quiet" || rc=1
    done
    if [ "$rc" -eq 0 ]; then
        [ "$quiet" = true ] || _say "contracts key-rotation: OK ✓ — the rotation invariant holds."
    fi
    return "$rc"
}

_keyrot_one() {
    local pair="$1" quiet="${2:-false}"
    local contract="$PAIRS_DIR/${pair}.pair-contract.yml"
    local bad=0

    if [ ! -f "$contract" ]; then
        _err "[$pair] CANNOT-VERIFY: no contract at $contract"
        return 1
    fi
    if [ -z "$(_crossref_yq "$contract" '.oidc.key_rotation')" ]; then
        _err "[$pair] CANNOT-VERIFY: the contract declares no 'oidc.key_rotation:' clause."
        _say  "  A pair whose issuer can rotate a signing key, with no recorded rotation"
        _say  "  obligations, is not a passing contract — it is an unwritten outage."
        _say  "  See docs/guides/ops82-key-rotation.md §Contract linkage."
        return 1
    fi

    local verifies kid overlap mode runbook refetch
    verifies="$(_crossref_yq "$contract" '.oidc.key_rotation.consumer_verifies_signature')"
    kid="$(_crossref_yq      "$contract" '.oidc.key_rotation.tokens_carry_kid')"
    overlap="$(_crossref_yq  "$contract" '.oidc.key_rotation.provider_supports_overlap')"
    mode="$(_crossref_yq     "$contract" '.oidc.key_rotation.mode')"
    runbook="$(_crossref_yq  "$contract" '.oidc.key_rotation.runbook')"
    refetch="$(_crossref_yq  "$contract" '.oidc.key_rotation.refetch_impl')"

    # A field we cannot read is never treated as a safe default.
    if [ "$verifies" != "true" ] && [ "$verifies" != "false" ]; then
        _err "[$pair] CANNOT-VERIFY: oidc.key_rotation.consumer_verifies_signature is not a"
        _err "                       literal true/false (got: '${verifies:-<absent>}'). This is the"
        _err "                       load-bearing fact; it may not be left implicit."
        return 1
    fi
    if [ -z "$mode" ]; then
        _err "[$pair] MISSING-FIELD: oidc.key_rotation.mode (hard_swap|overlap)."
        bad=1
    fi

    # The runbook must exist — a clause pointing at a missing document is folklore.
    if [ -n "$runbook" ] && [ ! -f "$PROJECT_ROOT/$runbook" ]; then
        _err "[$pair] MISSING-RUNBOOK: oidc.key_rotation.runbook -> '$runbook' does not exist."
        bad=1
    elif [ -z "$runbook" ]; then
        _err "[$pair] MISSING-FIELD: oidc.key_rotation.runbook (the procedure an operator follows)."
        bad=1
    fi

    # --- the consumer corpus (reuse the crossref roots) ----------------------
    local cons_roots=() r
    while IFS= read -r r; do [ -n "$r" ] && cons_roots+=("$r"); done < <(
        _crossref_yq "$contract" '.crossref.consumer_roots[]' | _crossref_existing_roots)
    if [ "${#cons_roots[@]}" -eq 0 ]; then
        _err "[$pair] CANNOT-VERIFY: none of the declared crossref.consumer_roots exist here, so"
        _err "                       the 'consumer does not verify signatures' claim cannot be"
        _err "                       checked against code. Absence of evidence is not a pass."
        return 1
    fi

    # --- the CORE corpus (ops#152) ------------------------------------------
    # consumer_roots names the first-party PLUGIN tree — about 105 PHP files.
    # But "the consumer does not verify the id_token signature" is a claim about
    # the CONSUMER, and the consumer is Moodle: core (~16,500 PHP files) plus
    # plugins. Scanning only the plugins and printing OK was a fail-open: JWT
    # verification planted at lib/classes/oauth2/client.php — the very file the
    # ssc contract's comment cites as hand-verified — did NOT trip CLAIM-DRIFT.
    # Verified by reproduction 2026-07-28.
    #
    # The core tree's location is DECLARED, not guessed, and its absence is
    # CANNOT-VERIFY rather than a pass — the same fail-closed rule already
    # applied to consumer_roots. A gate that silently narrows its own corpus is
    # how the hand-verification became folklore in the first place.
    local core_declared core_roots=()
    core_declared="$(_crossref_yq "$contract" '.oidc.key_rotation.consumer_core_roots[]')"
    if [ -z "$core_declared" ]; then
        _err "[$pair] CANNOT-VERIFY: oidc.key_rotation.consumer_core_roots is not declared."
        _err "                       consumer_roots covers the first-party plugin tree only."
        _err "                       The 'consumer does not verify signatures' claim is a claim"
        _err "                       about the WHOLE consumer — Moodle core included — so the"
        _err "                       contract must say where core lives. Scanning the plugins"
        _err "                       and calling it OK is the fail-open this field closes."
        return 1
    fi
    while IFS= read -r r; do [ -n "$r" ] && core_roots+=("$r"); done < <(
        printf '%s\n' "$core_declared" | _crossref_existing_roots)
    if [ "${#core_roots[@]}" -eq 0 ]; then
        _err "[$pair] CANNOT-VERIFY: none of the declared oidc.key_rotation.consumer_core_roots"
        _err "                       exist here, so the Moodle core tree cannot be scanned."
        _err "                       Absence of evidence is not a pass."
        printf '%s\n' "$core_declared" | while IFS= read -r r; do
            [ -n "$r" ] && _say "    declared, missing: $r"
        done
        return 1
    fi

    local exempt
    exempt="$(_crossref_yq "$contract" '.oidc.key_rotation.verification_exempt_paths[]')"

    local scan_roots=("${cons_roots[@]}" "${core_roots[@]}")
    [ "$quiet" = true ] || _say "[$pair] mode=$mode verifies=$verifies kid=${kid:-<unset>} overlap=${overlap:-<unset>} corpus=${#scan_roots[@]} root(s) (${#cons_roots[@]} plugin + ${#core_roots[@]} core), $(printf '%s\n' "$exempt" | grep -c .) exempt path(s)"

    local hits
    hits="$(_keyrot_verify_sites "$exempt" "${scan_roots[@]}")"

    if [ "$verifies" = "false" ]; then
        # ---- the drift check: prose says "does not verify"; does the code agree?
        if [ -n "$hits" ]; then
            _err "[$pair] CLAIM-DRIFT: the contract says consumer_verifies_signature=false, but the"
            _err "                     consumer tree contains executable signature/JWKS code. If the"
            _err "                     consumer now verifies, the documented hard swap is an OUTAGE."
            printf '%s\n' "$hits" | while IFS= read -r h; do [ -n "$h" ] && _say "    $h"; done
            _say  "  Fix by EITHER removing the code, OR flipping consumer_verifies_signature=true"
            _say  "  and building the overlap path (this gate will then demand it), OR — if the hit"
            _say  "  is genuinely inert — listing the file under"
            _say  "  oidc.key_rotation.verification_exempt_paths (an explicit, reviewable waiver)."
            bad=1
        else
            [ "$quiet" = true ] || _say "[$pair] verify  OK           no executable signature/JWKS code in the consumer plugin tree OR Moodle core, outside the contract's declared verification_exempt_paths (ops#152: core is now scanned; the 2026-07-28 hand verification of lib/classes/oauth2/ is machine-checked from here on)"
        fi
        # hard_swap is only legitimate while nobody verifies.
        if [ -n "$mode" ] && [ "$mode" != "hard_swap" ]; then
            _err "[$pair] MODE-MISMATCH: mode='$mode' but consumer_verifies_signature=false."
            _err "                       Overlap machinery with no verifier is unnecessary ceremony;"
            _err "                       declare hard_swap or explain the third consumer."
            bad=1
        fi
    else
        # ---- verification is ON: every overlap obligation becomes mandatory.
        local need_fail=0
        if [ "$overlap" != "true" ]; then
            _err "[$pair] OVERLAP-REQUIRED: consumer_verifies_signature=true but"
            _err "                         provider_supports_overlap='${overlap:-<unset>}'. A verifying"
            _err "                         consumer + a single-key issuer means every rotation is a"
            _err "                         hard outage. Build overlap before enabling verification."
            need_fail=1
        fi
        if [ "$kid" != "true" ]; then
            _err "[$pair] OVERLAP-REQUIRED: tokens_carry_kid='${kid:-<unset>}'. Without a kid a verifier"
            _err "                         cannot select the right key during the overlap window, so"
            _err "                         overlap cannot actually be used."
            need_fail=1
        fi
        local w
        for w in announce_window overlap_window retire_after; do
            local v; v="$(_crossref_yq "$contract" ".oidc.key_rotation.${w}")"
            if [ -z "$v" ] || [ "$v" = "0" ]; then
                _err "[$pair] OVERLAP-REQUIRED: ${w}='${v:-<unset>}'. A verifying consumer needs a real"
                _err "                         announce → overlap → retire schedule, not a zero."
                need_fail=1
            fi
        done
        if [ -z "$refetch" ] || [ ! -f "$PROJECT_ROOT/$refetch" ]; then
            _err "[$pair] NO-REFETCH: consumer_verifies_signature=true but refetch_impl"
            _err "                    ('${refetch:-<unset>}') does not name an existing file. A verifier"
            _err "                    that caches a JWKS and does NOT refetch on an unknown kid will"
            _err "                    reject every token signed by the new key until its cache expires."
            need_fail=1
        fi
        [ "$need_fail" -eq 0 ] || bad=1
        [ "$bad" -ne 0 ] || { [ "$quiet" = true ] || _say "[$pair] verify  OK           overlap obligations satisfied"; }
    fi

    return "$bad"
}

# =============================================================================
# erasure — the ops#81 erasure-channel gate
# =============================================================================
# Why a CONTRACT gate when `pl erasure` already exists: `pl erasure` is the
# operational runner (plan/execute/verify a single request). It answers "can I
# erase this person". This verb answers the prior question — "does this pair
# have a defined, pinned, CLOSED erasure channel at all" — which is the one a
# release gate and a DPIA reviewer need, and which nothing asked before.
#
# The schema-closure check is the load-bearing one. An erasure command with
# additionalProperties:true is a data-minimisation hole in a DESTRUCTIVE
# cross-site message: fields nobody reviewed ride along to a delete endpoint.
cmd_erasure() {
    local want=() all=false strict=false arg
    for arg in "$@"; do
        case "$arg" in
            --all)    all=true ;;
            --strict) strict=true ;;
            -*)       _err "contracts erasure: unknown option '$arg'"; return 2 ;;
            *)        want+=("$arg") ;;
        esac
    done

    if ! command -v yq >/dev/null 2>&1; then
        _err "contracts erasure: CANNOT-VERIFY — yq not installed (the contract cannot be parsed)."
        return 1
    fi

    if [ "$all" = true ] || [ "${#want[@]}" -eq 0 ]; then
        want=()
        local f
        for f in "$PAIRS_DIR"/*.pair-contract.yml; do
            [ -e "$f" ] || continue
            want+=("$(basename "$f" .pair-contract.yml)")
        done
        if [ "${#want[@]}" -eq 0 ]; then
            _err "contracts erasure: CANNOT-VERIFY — no pair contracts in $PAIRS_DIR."
            return 1
        fi
    fi

    local rc=0 pair
    for pair in "${want[@]}"; do
        _erasure_one "$pair" "$strict" || rc=1
    done
    return "$rc"
}

# Is a JSON Schema CLOSED? additionalProperties:false + a non-empty required[].
# Uses jq when present; falls back to a conservative grep that can only ever
# under-report closure (i.e. fail closed), never over-report it.
_erasure_schema_closed() { # <schema-file>  -> 0 closed, 1 open, 2 unparseable
    local s="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -e . "$s" >/dev/null 2>&1 || return 2
        local ap req
        ap="$(jq -r '.additionalProperties' "$s" 2>/dev/null)"
        req="$(jq -r '(.required // []) | length' "$s" 2>/dev/null)"
        [ "$ap" = "false" ] || return 1
        [ -n "$req" ] && [ "$req" -gt 0 ] 2>/dev/null || return 1
        return 0
    fi
    grep -q '"additionalProperties"[[:space:]]*:[[:space:]]*false' "$s" || return 1
    grep -q '"required"[[:space:]]*:[[:space:]]*\[[[:space:]]*"' "$s" || return 1
    return 0
}

# First existing match for a repo-relative path under a list of roots.
_erasure_find_under() { # <relpath> <root>...
    local rel="$1"; shift
    local r
    for r in "$@"; do
        [ -n "$r" ] || continue
        if [ -e "$r/$rel" ]; then printf '%s\n' "$r/$rel"; return 0; fi
    done
    return 1
}

_erasure_one() {
    local pair="$1" strict="$2"
    local contract="$PAIRS_DIR/${pair}.pair-contract.yml"

    if [ ! -f "$contract" ]; then
        _err "[$pair] CANNOT-VERIFY: no contract at $contract"
        return 1
    fi

    local fatal=0 soft=0

    # --- 1. the wire surface must exist and pin a schema ---------------------
    local has_surface schema_rel
    # NB: `.surfaces.erasure | type` yields the literal '!!null' for a MISSING
    # key, which is non-empty and so read as present — the gate went green on a
    # pair with no erasure surface at all. `has()` is the only form that
    # answers the question actually being asked, and it is false-y even when
    # `.surfaces` itself is absent. Caught by the red test, not by review.
    has_surface="$(_crossref_yq "$contract" '.surfaces | has("erasure")' | head -1)"
    if [ "$has_surface" != "true" ]; then
        _err "[$pair] erasure CHANNEL-UNDEFINED — no 'surfaces.erasure' block."
        _say "  This pair has no declared erasure channel. An Art.17 request against it"
        _say "  has no defined mechanism, so nothing can prove it was honoured."
        return 1
    fi

    schema_rel="$(_crossref_yq "$contract" '.surfaces.erasure.schema' | head -1)"
    if [ -z "$schema_rel" ]; then
        _err "[$pair] erasure SCHEMA-UNPINNED — surfaces.erasure declares no 'schema:'."
        _say "  An unpinned destructive message shape can drift on either side silently."
        fatal=1
    else
        local schema_abs="$PROJECT_ROOT/$schema_rel"
        if [ ! -f "$schema_abs" ]; then
            _err "[$pair] erasure SCHEMA-MISSING — $schema_rel is pinned but absent."
            fatal=1
        else
            _erasure_schema_closed "$schema_abs"; local sc=$?
            case "$sc" in
                0) _say "[$pair] erasure schema CLOSED        $schema_rel" ;;
                1) _err "[$pair] erasure SCHEMA-NOT-CLOSED — $schema_rel permits unreviewed fields."
                   _say "  A destructive cross-site command must be additionalProperties:false with"
                   _say "  a non-empty required[]; otherwise it is not a contract, it is a suggestion."
                   fatal=1 ;;
                2) _err "[$pair] erasure SCHEMA-MISSING — $schema_rel is not parseable JSON."
                   fatal=1 ;;
            esac
        fi
    fi

    # --- 2. the operational half must name both channel ends ----------------
    local recv send
    recv="$(_crossref_yq "$contract" '.erasure.receiver_path' | head -1)"
    send="$(_crossref_yq "$contract" '.erasure.sender_path'   | head -1)"
    if [ -z "$recv" ] || [ -z "$send" ]; then
        _err "[$pair] erasure CHANNEL-UNDEFINED — erasure.receiver_path / sender_path not both set."
        _say "  receiver_path='${recv:-<unset>}'  sender_path='${send:-<unset>}'"
        fatal=1
    fi

    [ "$fatal" -eq 0 ] || return 1

    # --- 3. estate: is the declared channel actually deployed? --------------
    local prov_roots=() cons_roots=() r
    while IFS= read -r r; do [ -n "$r" ] && prov_roots+=("$r"); done < <(
        _crossref_yq "$contract" '.crossref.provider_roots[]' | _crossref_existing_roots)
    while IFS= read -r r; do [ -n "$r" ] && cons_roots+=("$r"); done < <(
        _crossref_yq "$contract" '.crossref.consumer_roots[]' | _crossref_existing_roots)

    local hit
    if [ "${#cons_roots[@]}" -eq 0 ]; then
        _warn "[$pair] erasure NOT-DEPLOYED receiver — no consumer root present to look in."
        soft=1
    elif hit="$(_erasure_find_under "$recv" "${cons_roots[@]}")"; then
        _say "[$pair] erasure receiver DEPLOYED   $hit"
    else
        _warn "[$pair] erasure NOT-DEPLOYED receiver — '$recv' not present under any consumer root."
        soft=1
    fi

    if [ "${#prov_roots[@]}" -eq 0 ]; then
        _warn "[$pair] erasure NOT-DEPLOYED sender — no provider root present to look in."
        soft=1
    elif hit="$(_erasure_find_under "$send" "${prov_roots[@]}")"; then
        _say "[$pair] erasure sender   DEPLOYED   $hit"
    else
        _warn "[$pair] erasure NOT-DEPLOYED sender — '$send' not present under any provider root."
        soft=1
    fi

    # --- 4. operator assertions the gate must never make on their behalf ----
    local sem ceiling
    sem="$(_crossref_yq "$contract" '.erasure.semantics_approved' | head -1)"
    ceiling="$(_crossref_yq "$contract" '.erasure.backup_ceiling' | head -1)"

    if [ "$sem" = "true" ]; then
        _say "[$pair] erasure semantics APPROVED"
    else
        _warn "[$pair] erasure SEMANTICS-UNAPPROVED — Art.17 semantics not signed off (OPERATOR)."
        soft=1
    fi

    if [ -n "$ceiling" ]; then
        _say "[$pair] erasure backup ceiling  $ceiling"
    else
        _warn "[$pair] erasure NO-BACKUP-CEILING — raw-backup retention window unasserted (OPERATOR)."
        _say "  Erasing live rows while a raw backup holds the person is the usual way a"
        _say "  retention schedule fails. Unset is the TRUE state; do not assert it blind."
        soft=1
    fi

    if [ "$soft" -ne 0 ] && [ "$strict" = true ]; then
        _err "[$pair] erasure: --strict — channel declared but not provably operable."
        return 1
    fi
    return 0
}

main() {
    local verb="${1:-help}"; shift || true
    case "$verb" in
        compat)    cmd_compat "$@" ;;
        guards)    cmd_guards "$@" ;;
        erasure)   cmd_erasure "$@" ;;
        sums)      cmd_sums "$@" ;;
        sign)      cmd_sign "$@" ;;
        verify)    cmd_verify "$@" ;;
        bundle)    cmd_bundle "$@" ;;
        sync-plan) cmd_sync_plan "$@" ;;
        crossref)  cmd_crossref "$@" ;;
        key-rotation|key_rotation) cmd_key_rotation "$@" ;;
        -h|--help|help)
            sed -n '3,97p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            ;;
        *)
            _err "pl contracts: unknown verb '$verb' (compat|sums|sign|verify|bundle|sync-plan|crossref|key-rotation|erasure)"
            return 2
            ;;
    esac
}

main "$@"
