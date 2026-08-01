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
#   ENV VARS CAN BE STRIPPED (sudo env_reset, cron, desktop launchers), which
#   would silently turn fail-closed back into fail-open. So REQUIRE can also
#   be pinned by a marker FILE, which survives env stripping (ops#79):
#     /etc/nwp/deploy-gate-require            (host-wide; root-owned — preferred on ver)
#     $PROJECT_ROOT/keys/deploy-gate.require  (per-checkout)
#   If either file exists, an unconfigured gate fails closed regardless of env.
#
#   THE MARKER'S DIRECTORY MUST BE SEARCHABLE BY THE OPERATOR (0755, not 0700).
#   Resolving a name inside a directory costs SEARCH (+x) on it, and every caller
#   of deploy_gate_require is unprivileged — `pl` asserts no EUID, and stg2live /
#   live2prod / stg2prod / moodle / drush / demo / secrets inject / rollback /
#   restore all run as the operator. Create it as:
#       sudo mkdir -p -m 0755 /etc/nwp && sudo touch /etc/nwp/deploy-gate-require
#   The marker is NOT a secret; its presence is the whole signal, so 0755 costs
#   nothing. If the directory is unsearchable the gate can no longer tell present
#   from unreadable, and it ABORTS rather than assume the permissive answer.
#
# Config (env overrides; sane defaults):
#   NWP_DEPLOY_ALLOWED_SIGNERS  default: $PROJECT_ROOT/keys/allowed_signers
#   NWP_DEPLOY_SK_KEY           default: ~/.ssh/id_ed25519_sk
#   NWP_DEPLOY_GATE_REQUIRE     "true" ⇒ unconfigured = fail-closed
#
# allowed_signers line format (public keys only):
#   rob@nwp sk-ssh-ed25519@openssh.com AAAA...   (one line per authorized signer;
#   first field is the principal; key type+blob = fields 1-2 of the sk .pub file)
################################################################################

# The rotation-debt gate (operator ruling D8) rides on this same call for
# target=prod — see deploy_gate_require below. Sourced by path relative to THIS
# file so it resolves identically from a worktree, from CI and from a fresh
# clone; if it is somehow absent, deploy_gate_require refuses rather than
# proceeding without the check.
if ! declare -F rotation_debt_guard >/dev/null 2>&1; then
    _dg_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    # shellcheck source=lib/rotation-debt.sh
    [ -f "$_dg_lib_dir/rotation-debt.sh" ] && source "$_dg_lib_dir/rotation-debt.sh"
    unset _dg_lib_dir
fi

_dg_allowed_signers() { printf '%s' "${NWP_DEPLOY_ALLOWED_SIGNERS:-${PROJECT_ROOT:-$HOME/nwp}/keys/allowed_signers}"; }
_dg_sk_key()          { printf '%s' "${NWP_DEPLOY_SK_KEY:-$HOME/.ssh/id_ed25519_sk}"; }

# _dg_sk_keys — candidate signing keys, one per line. An explicit
# NWP_DEPLOY_SK_KEY wins outright; otherwise every sk key at the default
# location (id_ed25519_sk, then id_ed25519_sk_*) is a candidate, so the gate
# works with WHICHEVER enrolled Solo is plugged in (W or the W2 hot-spare) —
# no env var to remember during a lost-token emergency (ops#25).
_dg_sk_keys() {
    if [ -n "${NWP_DEPLOY_SK_KEY:-}" ]; then
        printf '%s\n' "$NWP_DEPLOY_SK_KEY"
        return
    fi
    local k
    for k in "$HOME/.ssh/id_ed25519_sk" "$HOME"/.ssh/id_ed25519_sk_*; do
        [ -f "$k" ] || continue
        case "$k" in *.pub) continue ;; esac
        printf '%s\n' "$k"
    done
}

# _dg_marker_verdict <path> — three-way, because "[ -e ]" cannot tell "absent"
# from "I am not allowed to look". If the parent directory is not SEARCHABLE
# (0700 root:root is the shipped posture for /etc/nwp) then `[ -e ]` is false
# whether or not the marker exists, and a guard built on it silently reports
# "not required" — the exact fail-open this file's own comment was written to
# prevent when the env-only form proved bypassable (ops#79).
#
# Deliberately tests SEARCH (-x), not read (-r): a 0711 drop-box directory can
# be traversed but not listed, and answering "cannot-verify" there would be a
# false alarm. An alarm that always rings gets ignored, which is the same
# failure one level up.
#
# Echoes present|absent|cannot-verify; returns 0|1|2 to match.
_dg_marker_verdict() {
    local marker="$1" parent
    parent="$(dirname -- "$marker")"

    [ -e "$marker" ] && { echo present; return 0; }

    # Not visible. Absent, or unlookable?
    [ -d "$parent" ] || { echo absent; return 1; }   # no parent at all: genuinely absent
    [ -x "$parent" ] && { echo absent; return 1; }   # searchable and not there: genuinely absent
    echo cannot-verify; return 2
}

# _dg_marker_paths — the marker locations, in precedence order. One list, so the
# enforcement path and `pl deploy-gate status` cannot drift apart and disagree
# about which files were even consulted.
_dg_marker_paths() {
    printf '%s\n' /etc/nwp/deploy-gate-require \
                  "${PROJECT_ROOT:-$HOME/nwp}/keys/deploy-gate.require"
}

# _dg_require_enforced — is fail-closed-when-unconfigured demanded?
#   0 = yes   1 = no   2 = CANNOT VERIFY (a marker location exists but is
#                          unreadable; callers must treat this as "yes", never
#                          as "no" — see deploy_gate_require).
#
# On rc 2 it sets _DG_REQUIRE_BLIND to the specific path(s) that could not be
# resolved. "Something is unreadable somewhere" is not actionable; a path is.
_dg_require_enforced() {
    _DG_REQUIRE_BLIND=""
    [ "${NWP_DEPLOY_GATE_REQUIRE:-false}" = "true" ] && return 0

    local marker v
    while IFS= read -r marker; do
        v="$(_dg_marker_verdict "$marker")"
        [ "$v" = "present" ] && return 0
        [ "$v" = "cannot-verify" ] && _DG_REQUIRE_BLIND="${_DG_REQUIRE_BLIND:+$_DG_REQUIRE_BLIND, }$marker"
    done < <(_dg_marker_paths)

    [ -n "$_DG_REQUIRE_BLIND" ] && return 2
    return 1
}

# deploy_gate_configured — 0 if both the allowed_signers file and a signing key
# are present (i.e. this host is set up to enforce the gate).
deploy_gate_configured() {
    [ -f "$(_dg_allowed_signers)" ] && [ -n "$(_dg_sk_keys)" ]
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

    # ── ROTATION-DEBT GATE (operator ruling D8) ───────────────────────────────
    # A known-exposed credential must be rotated BEFORE a prod site starts. This
    # sits here rather than in each prod verb on purpose: every path that writes
    # to prod already funnels through this one call (stg2prod, live2prod, and any
    # verb added later), so the gate cannot be acquired by one caller and missed
    # by the next. Scoped to target=prod — an exposure is a work item on live,
    # a blocker on prod. Fail-closed, including on an unreadable registry.
    if [ "$target" = "prod" ]; then
        if declare -F rotation_debt_guard >/dev/null 2>&1; then
            rotation_debt_guard "this deploy to PROD ($site: $summary)" || return 1
        else
            _dg_err "Rotation-debt gate unavailable (lib/rotation-debt.sh not sourced) — cannot"
            _dg_err "confirm no credential is awaiting rotation. Refusing the prod write."
            return 1
        fi
    fi

    if ! deploy_gate_configured; then
        local rq=0
        _dg_require_enforced || rq=$?
        if [ "$rq" -eq 0 ]; then
            _dg_err "Hardware signature gate REQUIRED but not configured (ADR-0028):"
            _dg_err "  need $(_dg_allowed_signers) and an sk key at ~/.ssh/id_ed25519_sk[_*]. Aborting."
            return 1
        fi
        if [ "$rq" -eq 2 ]; then
            # Blind, not clear. "No marker" here would be a GUESS, and the guess
            # is the permissive one — which is precisely the silent bypass the
            # marker file was introduced to close (ops#79). Refuse instead, and
            # name the path so the operator can fix it rather than divine it.
            local blind_dir
            blind_dir="$(dirname -- "${_DG_REQUIRE_BLIND%%,*}")"
            _dg_err "CANNOT VERIFY whether the deploy gate is REQUIRED here (ADR-0028):"
            _dg_err "  marker location: $_DG_REQUIRE_BLIND"
            _dg_err "  Its directory exists but is not searchable as $(id -un 2>/dev/null || echo "${USER:-this user}"),"
            _dg_err "  so a marker pinning fail-closed could be sitting in it unseen. That is NOT"
            _dg_err "  the same as 'no marker', and refusing to guess is the whole point."
            _dg_err "  The marker is not a secret — its PRESENCE is the entire signal — so its"
            _dg_err "  directory must be searchable by the unprivileged operator who runs pl:"
            _dg_err "      sudo chmod 0755 $blind_dir"
            _dg_err "  Or configure the gate properly (allowed_signers + an sk key), which makes"
            _dg_err "  the question moot. No env override is offered: one would be strippable by"
            _dg_err "  the same sudo/cron path the marker file exists to survive. Aborting."
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

    local signers manifest sig signer rc
    signers="$(_dg_allowed_signers)"
    # Bind the signature to THIS deploy (site+target+source commit+host).
    local commit host
    commit="$(git -C "${PROJECT_ROOT:-.}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    host="$(hostname 2>/dev/null || echo unknown)"
    manifest="nwp-deploy site=$site target=$target commit=$commit host=$host"

    sig="$(mktemp "${TMPDIR:-/tmp}/nwp-deploy-sig.XXXXXX")" || { _dg_err "mktemp failed"; return 1; }
    # shellcheck disable=SC2064
    trap "rm -f '$sig'" RETURN

    # Try each candidate key: the one whose Solo is actually plugged in signs;
    # the others fail fast (their token is absent). Lets W or the W2 hot-spare
    # work interchangeably with zero configuration (ops#25).
    # NOTE: ssh-keygen's own stderr stays visible on purpose — it carries the
    # "Confirm user presence"/PIN prompts and the real failure reason (ops#79).
    local sk signed=false
    while IFS= read -r sk; do
        [ -n "$sk" ] || continue
        _dg_note "  → Touch your Solo now to authorize this deploy (key: $(basename "$sk")) ..."
        if printf '%s' "$manifest" | ssh-keygen -Y sign -n nwp-deploy -f "$sk" > "$sig"; then
            signed=true
            break
        fi
        _dg_note "  (that key's token isn't present or declined — trying the next candidate)"
    done < <(_dg_sk_keys)
    if [ "$signed" != "true" ]; then
        _dg_err "  Signing failed on every candidate key (no touch / no enrolled Solo plugged in). Deploy aborted."
        return 1
    fi

    # Two-step authorization (ops#79 — find-principals alone only matches the
    # embedded pubkey; it does NOT check the signature over the manifest):
    #   1. find-principals: whose key is this?  2. verify: did that principal
    #   really sign THIS manifest (site/target/commit/host binding)?
    signer="$(printf '%s' "$manifest" | ssh-keygen -Y find-principals -s "$sig" -f "$signers" 2>/dev/null | head -n1)"
    if [ -z "$signer" ]; then
        _dg_err "  Signer not listed in $signers — not authorized. Deploy aborted."
        return 1
    fi
    if ! printf '%s' "$manifest" | ssh-keygen -Y verify -f "$signers" -I "$signer" -n nwp-deploy -s "$sig" >/dev/null; then
        _dg_err "  Signature did NOT cryptographically verify for principal '$signer'. Deploy aborted."
        return 1
    fi
    _dg_ok "  ✓ authorized by: $signer  — signature verified, proceeding."
    return 0
}
