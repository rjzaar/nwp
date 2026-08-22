#!/bin/bash
# NOTE: no `set -euo pipefail` — SOURCED library (ops#111 lesson: forcing -e/-u
# onto a caller leaks into the bats runner and breaks CI test:unit).
################################################################################
# lib/rotation-debt.sh — "this credential is known-exposed and rotation is OWED"
#
# OPERATOR RULING D8 (2026-08-01, verbatim):
#   "I'm not worried about token exposure. Exposures need to be logged in the
#    todo list so they can be rotated when I get to it and must be done before
#    prod site starts."
#
# Two halves, and the second is the load-bearing one:
#   1. an exposure is RECORDED against the credential itself, in the tokenless
#      registry, so it cannot be forgotten the way a free-text issue can, and
#   2. an open rotation DEBT fails a prod bring-up CLOSED.
#
# THE DISTINCTION THIS FILE EXISTS TO ENFORCE
#   Closing the leak SURFACE (redacting the doc, deleting the transcript,
#   fixing the script) does NOT discharge the debt. The value was seen; the
#   only thing that discharges it is a rotation. So an exposure record carries
#   TWO independent booleans:
#
#       closed:  the surface is remediated  (nice; changes nothing here)
#       rotated: the credential was replaced (the ONLY thing that clears debt)
#
#   `pl secrets expose --closed` sets the first. Only `pl secrets rotate` /
#   `pl secrets done` — which already refuse to stamp while declared copies
#   disagree — set the second. That ordering is why a redacted doc cannot
#   quietly clear a rotation that never happened.
#
# SCHEMA (per registry entry, optional; see `pl secrets lint` section 10):
#   exposure:
#     - at:        "YYYY-MM-DD"     when the value was exposed / the exposure was found
#       how:       "one line"       how it leaked
#       where:     [<loc>, ...]     WHERE it leaked to — grammar below, >=1 required
#       closed:    true|false       is the leak SURFACE remediated?
#       closed_at: "YYYY-MM-DD"     optional; when the surface was closed
#       rotated:   true|false       is the ROTATION DEBT discharged?  (false = OWED)
#       rotated_at:"YYYY-MM-DD"     optional; stamped by rotate/done
#       ref:       "ops#182"        optional issue reference
#       severity:  low|medium|high|critical   optional (default high)
#       notes:     "…"              optional
#
#   `where:` grammar (deliberately strict, same reasoning as `stored_in`: a
#   location the tooling cannot parse is a location it silently stops checking):
#       doc:<path>                a document/file on this host
#       repo:<project>:<path>     a file in a git repo
#       issue:<project>#<n>       a tracker issue or note
#       host=<role>:<path>        a file on another host
#       transcript:<path>         an AI/session transcript
#       log:<path>                a log file
#       ci:<free text>            a CI job/artifact/variable surface
#       external:<free text>      deliberately NOT machine-checkable
#
# CANNOT VERIFY IS NOT CLEAR (same vocabulary as lib/boundary.sh / lib/canonical.sh):
#   registry MISSING   → no debt (fresh clone, CI, a checkout that never had one)
#   registry PRESENT but unreadable/unparseable, or yq absent → CANNOT VERIFY,
#   and the prod guard REFUSES. Nothing legitimate produces a corrupt registry,
#   and "I could not look" must never render as "there is nothing there".
################################################################################

# ── where the registry lives ───────────────────────────────────────────────
# Same resolution order as scripts/commands/secrets.sh: an explicit override,
# else the ESTATE root (the main checkout, not whichever worktree we run from —
# the registry exists in exactly one place and `pl issue work` worktrees are the
# standing rule, so resolving it against the caller's tree would make the answer
# depend on your current directory, which is not an answer).
rotation_debt_registry() {
    if [ -n "${NWP_SECRETS_REGISTRY:-}" ]; then printf '%s' "$NWP_SECRETS_REGISTRY"; return 0; fi
    local root="${NWP_ROOT:-}"
    if [ -z "$root" ]; then
        local here gcd cand
        here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
        root="${here:-${PROJECT_ROOT:-$HOME/nwp}}"
        if gcd=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null); then
            case "$gcd" in /*) ;; *) gcd="$root/$gcd" ;; esac
            cand=$(cd "$(dirname "$gcd")" 2>/dev/null && pwd) && [ -n "$cand" ] && root="$cand"
        fi
    fi
    printf '%s' "$root/private/secrets-registry.yml"
}

# rotation_debt_state — "clear" | "debt" | "cannot-verify:<reason>"
# The single source of truth every other function here defers to.
rotation_debt_state() {
    local reg; reg="$(rotation_debt_registry)"
    [ -f "$reg" ] || { printf 'clear'; return 0; }
    if ! command -v yq >/dev/null 2>&1; then
        printf 'cannot-verify:yq is not installed, so the exposure registry could not be read'
        return 0
    fi
    # A registry that exists but does not parse is the one failure that must never
    # read as "no debt recorded".
    if ! yq e '.' "$reg" >/dev/null 2>&1; then
        printf 'cannot-verify:%s exists but does not parse as YAML' "$reg"
        return 0
    fi
    local n
    n="$(rotation_debt_count)" || {
        printf 'cannot-verify:could not count open rotation debts in %s' "$reg"; return 0; }
    if [ "${n:-0}" -gt 0 ] 2>/dev/null; then printf 'debt'; else printf 'clear'; fi
}

# rotation_debt_open — one TAB-separated row per OPEN debt:
#   <id>\t<at>\t<ref>\t<closed:true|false>\t<severity>\t<how>
# An exposure is an open debt while `rotated` is anything other than true.
# Defaulting the ABSENT field to false is deliberate: a record that forgot to
# say whether it was rotated has not been shown to be rotated.
#
# Field 4 is the RAW boolean, rendered by the callers. yq's `if/then/else` is
# not accepted by every yq 4.x lexer in this position (measured: v4.50.1 errors),
# and a formatting nicety that makes the reader exit 1 turns every clean estate
# into "cannot verify" — i.e. it would have wedged every prod deploy.
rotation_debt_open() {
    local reg; reg="$(rotation_debt_registry)"
    [ -f "$reg" ] || return 0
    command -v yq >/dev/null 2>&1 || return 1
    yq e '.secrets[] | .id as $id | (.exposure // [])[]
          | select((.rotated // false) != true)
          | [$id, (.at // "?"), (.ref // "-"), ((.closed // false) | tostring),
             (.severity // "high"), (.how // "-")] | @tsv' "$reg" 2>/dev/null
}

# rotation_debt_surface_label — "surface closed" | "surface OPEN"
rotation_debt_surface_label() { [ "${1:-false}" = "true" ] && printf 'surface closed' || printf 'surface OPEN'; }

rotation_debt_count() {
    local out rc=0
    out="$(rotation_debt_open)" || rc=$?
    [ "$rc" -ne 0 ] && return 1
    [ -z "$out" ] && { printf '0'; return 0; }
    printf '%s' "$(printf '%s\n' "$out" | grep -c .)"
}

# rotation_debt_ids — distinct credential ids carrying an open debt.
rotation_debt_ids() {
    rotation_debt_open | cut -f1 | sort -u
}

################################################################################
# THE GO-LIVE GATE
################################################################################
# rotation_debt_guard <context> [--advisory]
#   rc 0  proceed (no debt recorded, or an override was taken and ledgered)
#   rc 1  REFUSE — an open rotation debt, or the registry could not be read
#
# Called by every path that brings a site up on PROD:
#   · lib/deploy-gate.sh:deploy_gate_require   when target == prod  (NWP-ADR-0028;
#     covers pl stg2prod + pl live2prod + any future prod-write verb by
#     construction, because they all pass through the one gate)
#   · pl canonical set <site> prod             the moment a site BECOMES prod
#
# OVERRIDE. There is one, and it is expensive on purpose: a hard-wedged gate
# with no path through is how gates get deleted. NWP_ROTATION_DEBT_OVERRIDE must
# carry a non-empty REASON, the refusal is still printed, and the override is
# appended to private/rotation-debt-overrides.log so "we went to prod owing a
# rotation" is a fact on disk rather than a thing someone remembers.
rotation_debt_guard() {
    local context="${1:-a production bring-up}" state
    state="$(rotation_debt_state)"

    case "$state" in
        clear) return 0 ;;
    esac

    local reason="${NWP_ROTATION_DEBT_OVERRIDE:-}"

    if [ "${state#cannot-verify:}" != "$state" ]; then
        _rd_err "ROTATION-DEBT: CANNOT VERIFY whether any credential is awaiting rotation."
        _rd_err "  reason: ${state#cannot-verify:}"
        _rd_err "  registry: $(rotation_debt_registry)"
        _rd_err "  'I could not look' is not 'there is nothing there' — refusing $context."
    else
        _rd_err "ROTATION-DEBT: refusing $context — credential(s) are known-EXPOSED and"
        _rd_err "not yet rotated. Operator ruling D8: rotation must be done before prod starts."
        _rd_err ""
        local id at ref closed sev how
        while IFS=$'\t' read -r id at ref closed sev how; do
            [ -n "$id" ] || continue
            _rd_err "  ● $id   exposed $at   [$sev, $(rotation_debt_surface_label "$closed")]   ${ref:--}"
            _rd_err "      $how"
        done < <(rotation_debt_open)
        _rd_err ""
        _rd_err "  A closed surface (redacted doc, deleted transcript) does NOT clear this."
        _rd_err "  Discharge it:   pl secrets rotate <id>      (or: pl secrets done <id>)"
        _rd_err "  Review it:      pl secrets debt"
    fi

    if [ -n "$reason" ]; then
        _rd_ledger "$context" "$state" "$reason"
        _rd_err ""
        _rd_err "  NWP_ROTATION_DEBT_OVERRIDE given — PROCEEDING while a rotation is owed."
        _rd_err "  reason: $reason"
        _rd_err "  ledgered: $(_rd_ledger_path)"
        return 0
    fi
    _rd_err ""
    _rd_err "  (deliberate, reasoned exception only: NWP_ROTATION_DEBT_OVERRIDE=\"<why>\" — ledgered)"
    return 1
}

_rd_ledger_path() {
    local reg root; reg="$(rotation_debt_registry)"; root="$(dirname "$reg")"
    printf '%s/rotation-debt-overrides.log' "$root"
}

_rd_ledger() { # context state reason
    local f; f="$(_rd_ledger_path)"
    [ -d "$(dirname "$f")" ] || return 0
    printf '%s\tactor=%s\thost=%s\tcontext=%s\tstate=%s\tids=%s\treason=%s\n' \
        "$(date -u +%FT%TZ)" \
        "$(git config user.email 2>/dev/null || id -un 2>/dev/null || echo unknown)" \
        "$(hostname 2>/dev/null || echo unknown)" \
        "$1" "$2" "$(rotation_debt_ids | tr '\n' ',' | sed 's/,$//')" "$3" >> "$f" 2>/dev/null || true
}

_rd_err() { if [ -t 2 ]; then printf '\033[0;31m%s\033[0m\n' "$*" >&2; else printf '%s\n' "$*" >&2; fi; }
