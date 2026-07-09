#!/bin/bash
################################################################################
# lib/deploy-gate.sh — hardware + signature gate on prod-writes (ADR-0028)
#
# The load-bearing control from ADR-0028: no `pl` command reaches a live/prod
# server without (a) a live operator Solo touch on (b) a valid ed25519-sk
# signature from an authorized signer. This lib provides that gate as a single
# call the prod-write verbs make right after their canonical guard.
#
# HOW THE TOUCH WORKS: verifying a signature needs no hardware — the touch
# happens at SIGNING. So the gate asks the operator to sign this deploy's
# manifest *now* with their sk key (which forces the Solo touch), then verifies
# that fresh signature against the allowed_signers file. A successful touch +
# verify proves the operator physically holds an authorized Solo at deploy time.
#
# OFF BY DEFAULT (like the rest of the ver kit). With no allowed_signers file
# and no sk key configured, deploy_gate_require prints a one-line notice and
# returns 0 — so the AI-capable test tier (A14) is unaffected. On ver, once
# the operator configures the two paths below, the gate enforces.
#
#   Set NWP_DEPLOY_GATE_REQUIRE=true to make an UNCONFIGURED gate fail CLOSED
#   (abort the deploy) instead of no-op — do this on ver so a missing key can
#   never silently drop the gate.
#
# Config (env overrides; sane defaults):
#   NWP_DEPLOY_ALLOWED_SIGNERS  default: $PROJECT_ROOT/keys/allowed_signers
#   NWP_DEPLOY_SK_KEY           default: ~/.ssh/id_ed25519_sk
#   NWP_DEPLOY_GATE_REQUIRE     "true" ⇒ unconfigured = fail-closed
#
# allowed_signers line format (public keys only — safe to keep in-repo):
#   rob@nwp ssh-ed25519-sk AAAA...   (one line per authorized signer)
################################################################################

_dg_allowed_signers() { printf '%s' "${NWP_DEPLOY_ALLOWED_SIGNERS:-${PROJECT_ROOT:-$HOME/nwp}/keys/allowed_signers}"; }
_dg_sk_key()          { printf '%s' "${NWP_DEPLOY_SK_KEY:-$HOME/.ssh/id_ed25519_sk}"; }

# deploy_gate_configured — 0 if both the allowed_signers file and a signing key
# are present (i.e. this host is set up to enforce the gate).
deploy_gate_configured() {
    [ -f "$(_dg_allowed_signers)" ] && [ -f "$(_dg_sk_key)" ]
}

# _dg_note / _dg_err — colour-aware, TTY-safe messaging (fall back to plain).
_dg_note() { if [ -t 1 ]; then printf '\033[1;33m%s\033[0m\n' "$*"; else printf '%s\n' "$*"; fi; }
_dg_ok()   { if [ -t 1 ]; then printf '\033[0;32m%s\033[0m\n' "$*"; else printf '%s\n' "$*"; fi; }
_dg_err()  { if [ -t 2 ]; then printf '\033[0;31m%s\033[0m\n' "$*" >&2; else printf '%s\n' "$*" >&2; fi; }

# deploy_gate_require <site> <target-phase> [human-summary]
#   Prints a plain-English "here is what this will do", then (if configured)
#   requires a live Solo-touch signature that verifies against allowed_signers.
#   Returns 0 = proceed, non-zero = abort the deploy.
deploy_gate_require() {
    local site="${1:?deploy_gate_require: site required}"
    local target="${2:?deploy_gate_require: target phase required}"
    local summary="${3:-a live/production write}"

    # Plain-English impact line — the "not a full terminal guy" affordance.
    echo ""
    _dg_note "╭─ DEPLOY GATE ─────────────────────────────────────────────"
    _dg_note "│  Site:    $site"
    _dg_note "│  Target:  $target  (a LIVE/PRODUCTION write — not reversible cheaply)"
    _dg_note "│  Effect:  $summary"
    _dg_note "╰───────────────────────────────────────────────────────────"

    if ! deploy_gate_configured; then
        if [ "${NWP_DEPLOY_GATE_REQUIRE:-false}" = "true" ]; then
            _dg_err "Hardware signature gate REQUIRED but not configured (ADR-0028):"
            _dg_err "  need $(_dg_allowed_signers) and $(_dg_sk_key). Aborting."
            return 1
        fi
        _dg_note "  (hardware signature gate not configured — proceeding without it;"
        _dg_note "   set NWP_DEPLOY_ALLOWED_SIGNERS + NWP_DEPLOY_SK_KEY on ver to enforce.)"
        return 0
    fi

    if [ ! -t 0 ]; then
        _dg_err "Deploy gate needs a terminal for the Solo touch — no TTY. Aborting."
        return 1
    fi

    local signers sk manifest sig signer rc
    signers="$(_dg_allowed_signers)"; sk="$(_dg_sk_key)"
    # Bind the signature to THIS deploy (site+target+source commit+host).
    local commit host
    commit="$(git -C "${PROJECT_ROOT:-.}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    host="$(hostname 2>/dev/null || echo unknown)"
    manifest="nwp-deploy site=$site target=$target commit=$commit host=$host"

    sig="$(mktemp "${TMPDIR:-/tmp}/nwp-deploy-sig.XXXXXX")" || { _dg_err "mktemp failed"; return 1; }
    # shellcheck disable=SC2064
    trap "rm -f '$sig'" RETURN

    _dg_note "  → Touch your Solo now to authorize this deploy ..."
    if ! printf '%s' "$manifest" | ssh-keygen -Y sign -n nwp-deploy -f "$sk" > "$sig" 2>/dev/null; then
        _dg_err "  Signing failed (no touch / wrong key / device absent). Deploy aborted."
        return 1
    fi

    signer="$(printf '%s' "$manifest" | ssh-keygen -Y find-principals -s "$sig" -f "$signers" 2>/dev/null | head -n1)"
    if [ -n "$signer" ]; then
        _dg_ok "  ✓ authorized by: $signer  — proceeding."
        return 0
    fi
    _dg_err "  Signature did NOT verify against $signers (signer not authorized). Deploy aborted."
    return 1
}
