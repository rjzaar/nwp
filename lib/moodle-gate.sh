#!/bin/bash
################################################################################
# lib/moodle-gate.sh — Art.9 "ship-together" invariant guard (ops#137).
#
# THE FAIL-OPEN THIS CLOSES
# -------------------------
# `pl moodle plugin deploy` used to default a plugin's source to
# `~/nwptoolkit/moodle/plugins/<type>/<name>` — a stale 2026-07-03 snapshot that
# predates the ops#118 consent gate and carries NO `may_keep_formation` call
# sites at all. An operator "deploying the Moodle Art.9 gate" through the normal
# path therefore shipped the UNGATED copy while believing the invariant was
# satisfied. That is a GDPR fail-open (special-category formation data retained
# for users who never consented), not a hygiene issue.
#
# TWO HALVES, BOTH REQUIRED
#   1. scripts/commands/moodle.sh repoints the DEFAULT source at the canonical
#      repo (nwp/ss-moodle-plugins) — the fix.
#   2. This file asserts, immediately before any bytes move, that the artifact
#      ACTUALLY CONTAINS the gate — the safety net. A repoint alone is one
#      config edit away from regressing; the assertion is not.
#
# The assertion is deliberately artifact-level (grep the staged bytes), not
# source-level: it can only be satisfied by the thing that is about to ship.
#
# ROLES (moodle_gate_requirement)
#   consumer — reads/writes formation data; MUST call the gate and MUST delegate
#              to auth_nwc\consent (mod/depthcontent, local/practice).
#   provider — defines the gate itself (auth/nwc); MUST carry the definition.
#   exempt   — allowlisted as legitimately gate-free (no formation data).
#
# FAIL-CLOSED DEFAULT: a plugin that is neither a known consumer/provider nor on
# the exempt allowlist is treated as a CONSUMER. A new plugin must be classified
# deliberately (add it to the allowlist, or ship the gate) — the speed bump is
# the point. `--allow-ungated` is the audited escape hatch.
#
# PURE + unit-testable: no ssh, no network, no secrets. Everything degrades to a
# clear refusal when a dependency is absent.
################################################################################

# --- soft-dep messaging (works standalone or with lib/ui.sh) -----------------
if ! declare -F _mg_err >/dev/null 2>&1; then
    _mg_err()  { if command -v print_error   >/dev/null 2>&1; then print_error   "$*"; else printf 'ERROR: %s\n' "$*" >&2; fi; }
    _mg_warn() { if command -v print_warning >/dev/null 2>&1; then print_warning "$*"; else printf 'WARN: %s\n'  "$*" >&2; fi; }
    _mg_info() { if command -v print_info    >/dev/null 2>&1; then print_info    "$*"; else printf '%s\n'        "$*"; fi; }
fi

################################################################################
# Classification
################################################################################

# Plugins that MUST carry a consent-gate call site before they may ship.
MOODLE_GATE_CONSUMERS="${MOODLE_GATE_CONSUMERS:-mod/depthcontent local/practice}"
# The plugin that DEFINES the gate. Shipping a consumer against a provider that
# lacks the definition is a fatal-on-first-call, so the provider is checked too.
MOODLE_GATE_PROVIDERS="${MOODLE_GATE_PROVIDERS:-auth/nwc}"
# Small allowlist of plugins that legitimately hold no formation data and so
# legitimately have no gate. Extend via NWP_MOODLE_GATE_EXEMPT (space-separated).
MOODLE_GATE_EXEMPT_DEFAULT="course/format/tabbed local/browse local/feedback local/mentor local/nwc_copyright_sync blocks/dailyreview"

# The symbol every consumer must call and the provider must define.
MOODLE_GATE_SYMBOL="may_keep_formation"
# The delegation a consumer must make — a local helper that never reaches
# auth_nwc is a decoy gate, so the call site is asserted separately.
MOODLE_GATE_PROVIDER_CLASS='auth_nwc'

# moodle_gate_requirement <plugin> — echo consumer|provider|exempt.
# Fail-closed: unknown ⇒ consumer.
moodle_gate_requirement() {
    local plugin="${1:-}" p
    [ -n "$plugin" ] || { echo "consumer"; return 0; }
    for p in $MOODLE_GATE_PROVIDERS;  do [ "$p" = "$plugin" ] && { echo "provider"; return 0; }; done
    for p in $MOODLE_GATE_CONSUMERS;  do [ "$p" = "$plugin" ] && { echo "consumer"; return 0; }; done
    for p in $MOODLE_GATE_EXEMPT_DEFAULT ${NWP_MOODLE_GATE_EXEMPT:-}; do
        [ "$p" = "$plugin" ] && { echo "exempt"; return 0; }
    done
    echo "consumer"          # fail-closed: classify a new plugin deliberately
    return 0
}

################################################################################
# Artifact scanning (grep the staged bytes — never a "source of truth" file)
################################################################################

# moodle_gate_scan <dir> — echo "calls=<n> delegations=<n> definitions=<n> tests=<n>".
# calls        = any `may_keep_formation` mention in PRODUCTION php
# delegations  = a production mention on a line that also names auth_nwc
# definitions  = `function may_keep_formation` in production php
# tests        = gate mentions under tests/ — a CORROBORATING signal only
#
# tests/ is deliberately excluded from calls/delegations/definitions: a plugin
# whose lib.php lost the gate but kept mod/depthcontent/tests/write_gate_test.php
# must NOT read as GATED. The test count is reported separately so a reviewer can
# see the gate's test coverage travelled with it.
moodle_gate_scan() {
    local dir="${1:-}"
    local calls=0 delegations=0 definitions=0 tests=0
    if [ -n "$dir" ] && [ -d "$dir" ]; then
        local prod
        prod="$(grep -rI --include='*.php' -e "$MOODLE_GATE_SYMBOL" "$dir" 2>/dev/null \
                | grep -v "^${dir%/}/tests/" | grep -v '/tests/' || true)"
        calls=$(printf '%s' "$prod" | grep -c . || true)
        delegations=$(printf '%s' "$prod" | grep -c -- "$MOODLE_GATE_PROVIDER_CLASS" || true)
        definitions=$(printf '%s' "$prod" | grep -cE "function[[:space:]]+${MOODLE_GATE_SYMBOL}" || true)
        tests=$(grep -rIl --include='*.php' -e "$MOODLE_GATE_SYMBOL" "${dir%/}/tests" 2>/dev/null | wc -l | tr -d ' ')
    fi
    printf 'calls=%s delegations=%s definitions=%s tests=%s\n' \
        "${calls:-0}" "${delegations:-0}" "${definitions:-0}" "${tests:-0}"
}

# moodle_gate_present <plugin> <dir> — 0 iff the artifact satisfies its role.
#   consumer ⇒ ≥1 call AND ≥1 delegation to auth_nwc
#   provider ⇒ ≥1 definition
#   exempt   ⇒ always satisfied
# A missing/blank dir is NOT satisfied (except exempt) — fail closed.
moodle_gate_present() {
    local plugin="${1:-}" dir="${2:-}"
    local role; role="$(moodle_gate_requirement "$plugin")"
    [ "$role" = "exempt" ] && return 0
    [ -n "$dir" ] && [ -d "$dir" ] || return 1

    local scan calls delegations definitions
    scan="$(moodle_gate_scan "$dir")"
    calls="${scan#calls=}";              calls="${calls%% *}"
    delegations="${scan#*delegations=}"; delegations="${delegations%% *}"
    definitions="${scan#*definitions=}"; definitions="${definitions%% *}"

    case "$role" in
        provider) [ "${definitions:-0}" -ge 1 ] ;;
        consumer) [ "${calls:-0}" -ge 1 ] && [ "${delegations:-0}" -ge 1 ] ;;
        *)        return 1 ;;
    esac
}

# moodle_gate_report <plugin> <dir> — one-line status token for gate-status.
#   EXEMPT | GATED | UNGATED | ABSENT
moodle_gate_report() {
    local plugin="${1:-}" dir="${2:-}"
    local role; role="$(moodle_gate_requirement "$plugin")"
    if [ "$role" = "exempt" ]; then echo "EXEMPT"; return 0; fi
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then echo "ABSENT"; return 0; fi
    if moodle_gate_present "$plugin" "$dir"; then echo "GATED"; else echo "UNGATED"; fi
    return 0
}

################################################################################
# Ledger — an --allow-ungated deploy is an audited operator decision
################################################################################

moodle_gate_ledger_dir() { echo "${PROJECT_ROOT:-$HOME/nwp}/private/moodle-gate"; }
moodle_gate_actor()      { echo "$(id -un)@$(hostname -s 2>/dev/null || hostname)"; }

moodle_gate_ledger_append() {
    local site="${1:-unknown}"; shift
    local dir; dir="$(moodle_gate_ledger_dir)"
    mkdir -p "$dir" 2>/dev/null || return 0
    echo "$(date -u +%FT%TZ) who=$(moodle_gate_actor) $*" >> "${dir}/${site}.log"
}

################################################################################
# The assertion — called immediately before any bytes move
################################################################################

# moodle_gate_assert <site> <tier> <allow_ungated> <plugin> <staged_dir> [...]
# Args after the 4th are (plugin, staged_dir) PAIRS. Returns 0 = proceed,
# 1 = REFUSE. The staged_dir MUST be the exact directory that will be rsynced —
# asserting a different tree than the one that ships defeats the whole point.
moodle_gate_assert() {
    local site="${1:-}" tier="${2:-}" allow="${3:-false}"; shift 3
    local -a failed=() checked=()
    local plugin dir role

    while [ "$#" -ge 2 ]; do
        plugin="$1"; dir="$2"; shift 2
        role="$(moodle_gate_requirement "$plugin")"
        [ "$role" = "exempt" ] && continue
        checked+=("$plugin")
        if ! moodle_gate_present "$plugin" "$dir"; then
            failed+=("${plugin}|${role}|${dir}")
        fi
    done

    if [ "${#failed[@]}" -eq 0 ]; then
        [ "${#checked[@]}" -gt 0 ] && \
            _mg_info "Art.9 gate assertion: OK — ${#checked[@]} gate-bearing plugin(s) carry the consent gate (${checked[*]})."
        return 0
    fi

    echo "" >&2
    _mg_err "════════════════════════════════════════════════════════════════"
    _mg_err "ART.9 GATE MISSING — DEPLOY REFUSED (ops#137)"
    _mg_err "════════════════════════════════════════════════════════════════"
    local entry p r d
    for entry in "${failed[@]}"; do
        p="${entry%%|*}"; r="${entry#*|}"; d="${r#*|}"; r="${r%%|*}"
        _mg_err "  ${p}  [role=${r}]"
        _mg_err "      staged source : ${d:-<none>}"
        _mg_err "      scan          : $(moodle_gate_scan "$d")"
        if [ "$r" = "provider" ]; then
            _mg_err "      expected      : a 'function ${MOODLE_GATE_SYMBOL}' definition"
        else
            _mg_err "      expected      : ≥1 ${MOODLE_GATE_SYMBOL} call delegating to ${MOODLE_GATE_PROVIDER_CLASS}"
        fi
    done
    echo "" >&2
    _mg_err "This artifact does NOT carry the Art.9 consent gate. Shipping it would"
    _mg_err "retain special-category formation data for users who never consented,"
    _mg_err "while the deploy log claims the ship-together invariant was satisfied."
    echo "" >&2
    _mg_info "Canonical, gate-bearing source: nwp/ss-moodle-plugins (project 33), ref main."
    _mg_info "  pl moodle plugins sync ${site:-<site>}            # fetch/refresh the canonical cache"
    _mg_info "  pl moodle gate-status ${site:-<site>}             # which trees carry the gate"
    _mg_info "~/nwptoolkit/moodle/plugins is a STALE 2026-07-03 snapshot — it predates"
    _mg_info "the ops#118 gate and has no auth/nwc, local/mentor or local/practice at all."
    echo "" >&2

    if [ "$allow" = "true" ]; then
        _mg_warn "════════════════════════════════════════════════════════════════"
        _mg_warn "--allow-ungated: PROCEEDING WITH AN UNGATED ARTIFACT."
        _mg_warn "Legitimate only when deliberately deploying a pre-consent-era plugin."
        _mg_warn "Recorded in private/moodle-gate/${site:-unknown}.log."
        _mg_warn "════════════════════════════════════════════════════════════════"
        for entry in "${failed[@]}"; do
            p="${entry%%|*}"; d="${entry##*|}"
            moodle_gate_ledger_append "${site:-unknown}" \
                "action=allow-ungated ref=ops#137 tier=${tier:-?} plugin=${p} src=${d:-none} scan=[$(moodle_gate_scan "$d")]"
        done
        echo "" >&2
        return 0
    fi

    _mg_err "REFUSED. Re-run against the canonical repo, or pass --allow-ungated to"
    _mg_err "override deliberately (loudly logged, ops#137)."
    return 1
}
