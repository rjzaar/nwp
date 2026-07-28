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
# SITE CLASS (ops#153, ADR-0036)
#   The three roles above classify the PLUGIN. They do not ask what kind of SITE
#   it is landing on, and that omission is what made this gate unsatisfiable on
#   rgs: an unpaired site has no auth_nwc to delegate to, so `consumer` could
#   never be met and `--allow-ungated` became permanent (ops#154).
#
#   lib/siteclass.sh supplies the missing dimension, in two places. (1) A
#   fully-validated `posture: local` declaration RETARGETS the delegation scan
#   at the site's own consent source — run before the scan, it changes WHICH
#   class the artifact must delegate to (never WHETHER it must; an artifact
#   delegating to the wrong source is refused, deliberately). (2) On the
#   FAILURE PATH only, a failure may be reclassified as an EXEMPTION when the
#   site declares `art9.posture: none-stored` AND that claim's own evidence
#   holds (fresh attestation, zero formation rows, member count under cap, not
#   expired). Neither path can suppress the scan or waive the call-site
#   requirement; every exempt pass is ledgered.
#
# PURE + unit-testable: no ssh, no network, no secrets. Everything degrades to a
# clear refusal when a dependency is absent.
################################################################################

# Soft dependency: the class axis is optional. Without it every posture read
# below is empty and this file behaves exactly as it did before ops#153.
if ! declare -F siteclass_art9_exempt >/dev/null 2>&1; then
    if [ -f "${PROJECT_ROOT:-$HOME/nwp}/lib/siteclass.sh" ]; then
        # shellcheck source=/dev/null
        . "${PROJECT_ROOT:-$HOME/nwp}/lib/siteclass.sh"
    fi
fi

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
        delegations=$(printf '%s' "$prod" | grep -cF -- "$MOODLE_GATE_PROVIDER_CLASS" || true)
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

# moodle_gate_status_verdict <site> <ungated_count> — the FINAL verdict line(s)
# of `pl moodle gate-status`, class-aware (the ops#153 follow-up recorded in
# ADR-0036). The per-plugin [UNGATED] rows above it are scan facts and are
# never rewritten; this reclassifies only the VERDICT, and only when the site
# carries a valid, evidenced none-stored exemption — the same predicate the
# deploy gate uses (siteclass_art9_exempt), so status and deploy cannot
# disagree about whether the estate is in an acceptable state.
#   rc 0  no ungated artifacts, OR the failure is class-exempt (says so loudly)
#   rc 1  ungated and no valid exemption
moodle_gate_status_verdict() {
    local site="${1:-}" ungated="${2:-0}"
    if [ "${ungated:-0}" -le 0 ]; then
        if command -v print_status >/dev/null 2>&1; then
            print_status "OK" "Every gate-bearing plugin found carries the Art.9 consent gate."
        else
            printf 'OK: every gate-bearing plugin found carries the Art.9 consent gate.\n'
        fi
        return 0
    fi
    if declare -F siteclass_art9_exempt >/dev/null 2>&1 && [ -n "$site" ] \
       && siteclass_art9_exempt "$site"; then
        local _gs_cls _gs_exp _gs_att
        _gs_cls="$(siteclass_of "$site" 2>/dev/null || echo '?')"
        _gs_exp="$(_sc_yq "$(siteclass_decl_file "$site")" '.art9.expires')"
        _gs_att="$(_sc_yq "$(siteclass_decl_file "$site")" '.art9.evidence.attestation.at')"
        _mg_warn "${ungated} UNGATED artifact(s) above — the scan facts stand."
        _mg_warn "SITE CLASS: '$site' (${_gs_cls}) carries a DECLARED, EVIDENCED Art.9"
        _mg_warn "exemption (posture: none-stored; attested ${_gs_att}; expires ${_gs_exp})."
        _mg_info "The exemption reclassifies the failure — same predicate the deploy gate"
        _mg_info "uses, so 'pl moodle plugin deploy $site' proceeds without --allow-ungated"
        _mg_info "while the evidence holds. Re-check: pl class evidence $site"
        if command -v print_status >/dev/null 2>&1; then
            print_status "OK" "EXEMPT (class) — bounded, expiring, ledgered on use."
        else
            printf 'OK: EXEMPT (class) — bounded, expiring, ledgered on use.\n'
        fi
        return 0
    fi
    _mg_warn "Ship-together invariant NOT satisfied: ${ungated} UNGATED artifact(s) above (ops#137)."
    _mg_info "Deploys from an UNGATED source are now REFUSED by 'pl moodle plugin deploy'."
    if declare -F siteclass_of >/dev/null 2>&1 && [ -n "$site" ]; then
        local _gs_cls2; _gs_cls2="$(siteclass_of "$site" 2>/dev/null || true)"
        case "$_gs_cls2" in
            undeclared)
                _mg_info "If this gate can never be satisfied here (no consent source), declare"
                _mg_info "what the site IS instead of overriding forever:  pl class check $site" ;;
        esac
    fi
    return 1
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

    # --- SITE CLASS, part 1 of 2: posture `local` retargets the delegation ---
    # A standalone site that has built its OWN consent source must delegate to
    # THAT, not to auth_nwc. This changes what the scan looks for; it does not
    # weaken it — a call site is still mandatory, still artifact-level.
    #
    # THE RETARGET IS ITSELF GATED. Only a declaration that (a) resolves to a
    # valid, uncontradicted class for THIS site, (b) whose class PERMITS
    # posture local (registry), and (c) whose obligations all hold
    # (siteclass_art9_check: source named, root exists) may change what the
    # scan demands. Anything less — a bare 4-line file, a posture the class
    # forbids, a body naming a different site — changes NOTHING, and the scan
    # keeps demanding auth_nwc. The class name is also validated as a literal
    # PHP-class token and matched fixed-string, because it reaches a grep
    # pattern: a declaration must never be able to smuggle a regex (".") that
    # matches every line.
    local _mg_posture="" _mg_local_class=""
    if declare -F siteclass_art9_posture >/dev/null 2>&1 && [ -n "$site" ]; then
        _mg_posture="$(siteclass_art9_posture "$site" 2>/dev/null || true)"
        if [ "$_mg_posture" = "local" ]; then
            if siteclass_of "$site" >/dev/null 2>&1 \
               && siteclass_art9_check "$site" >/dev/null 2>&1; then
                _mg_local_class="$(siteclass_art9_local_class "$site" 2>/dev/null || true)"
                case "$_mg_local_class" in
                    ""|*[!A-Za-z0-9_\\]*|[0-9]*)
                        [ -n "$_mg_local_class" ] && \
                            _mg_warn "Art.9: consent_source_class '${_mg_local_class}' is not a valid class token — retarget REFUSED, auth_nwc still required."
                        _mg_local_class=""
                        ;;
                esac
                if [ -n "$_mg_local_class" ]; then
                    local MOODLE_GATE_PROVIDER_CLASS="$_mg_local_class"
                    _mg_info "Art.9: site '$site' is class-declared posture=local — the artifact must delegate to '${_mg_local_class}' (not auth_nwc)."
                fi
            else
                _mg_warn "Art.9: site '$site' declares posture=local but the declaration does not hold up — retarget REFUSED, auth_nwc still required."
            fi
        fi
    fi

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

    # --- SITE CLASS, part 2 of 2: is this failure a DECLARED, EVIDENCED N/A? --
    # Reached only because the scan already FAILED. The class cannot suppress
    # the scan; it can only answer "and is that failure legitimate here?" — and
    # only ever with evidence that fails closed on absence, staleness, expiry, a
    # non-zero formation row count, or an exceeded member cap.
    if declare -F siteclass_art9_exempt >/dev/null 2>&1 && [ -n "$site" ]; then
        if siteclass_art9_exempt "$site"; then
            local _mg_cls _mg_exp _mg_att _mg_rows _mg_mem
            _mg_cls="$(siteclass_of "$site" 2>/dev/null || echo '?')"
            _mg_exp="$(_sc_yq "$(siteclass_decl_file "$site")" '.art9.expires')"
            _mg_att="$(_sc_yq "$(siteclass_decl_file "$site")" '.art9.evidence.attestation.at')"
            _mg_rows="$(_sc_yq "$(siteclass_decl_file "$site")" '.art9.evidence.attestation.formation_rows')"
            _mg_mem="$(_sc_yq "$(siteclass_decl_file "$site")" '.art9.evidence.attestation.member_count')"
            echo "" >&2
            _mg_warn "════════════════════════════════════════════════════════════════"
            _mg_warn "ART.9 GATE: DECLARED N/A FOR THIS SITE — EXEMPT BY EVIDENCE"
            _mg_warn "════════════════════════════════════════════════════════════════"
            _mg_warn "  site        : $site   (class: $_mg_cls, posture: none-stored)"
            _mg_warn "  declaration : classes/${site}.class.yml   [TRACKED — reviewable in an MR]"
            _mg_warn "  evidence    : attested $_mg_att — formation_rows=$_mg_rows member_count=$_mg_mem"
            _mg_warn "  expires     : $_mg_exp"
            _mg_warn ""
            _mg_warn "  This is NOT --allow-ungated. The exemption is bounded and self-"
            _mg_warn "  dissolving: it fails closed the moment the attestation goes stale,"
            _mg_warn "  the expiry passes, a formation row appears, or the member cap is"
            _mg_warn "  exceeded. Re-check any time with:  pl class check $site"
            _mg_warn "════════════════════════════════════════════════════════════════"
            local entry p d
            for entry in "${failed[@]}"; do
                p="${entry%%|*}"; d="${entry##*|}"
                siteclass_ledger_append "$site" \
                    "action=class-exempt ref=ops#153 class=${_mg_cls} posture=none-stored tier=${tier:-?} plugin=${p} src=${d:-none} evidence=[at=${_mg_att} rows=${_mg_rows} members=${_mg_mem} expires=${_mg_exp}]"
            done
            echo "" >&2
            return 0
        fi
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

    # If the site is UNPAIRED, the canonical-source advice above is a dead end —
    # no artifact it can run will ever delegate to auth_nwc. Say so, and name the
    # supported way out, rather than leaving --allow-ungated as the only door.
    if declare -F siteclass_of >/dev/null 2>&1 && [ -n "$site" ]; then
        local _mg_cls2; _mg_cls2="$(siteclass_of "$site" 2>/dev/null || true)"
        case "$_mg_cls2" in
            undeclared|cannot-verify:*|contradictory:*|invalid:*)
                _mg_warn "SITE CLASS: '$site' is ${_mg_cls2} (ADR-0036)."
                _mg_warn "  This gate cannot tell whether it even APPLIES here. If '$site' has no"
                _mg_warn "  consent source to delegate to, no artifact will ever satisfy the check"
                _mg_warn "  and --allow-ungated becomes permanent — the ops#154 ritual."
                _mg_info "  Declare what this site IS, once, reviewably:"
                _mg_info "    pl class check $site        # what is missing"
                _mg_info "    pl class set $site <member-paired|member-standalone|demo|service>"
                echo "" >&2
                ;;
            member-standalone|demo|service)
                _mg_warn "SITE CLASS: '$site' is class '$_mg_cls2', whose Art.9 posture may be"
                _mg_warn "  satisfied WITHOUT delegating to auth_nwc — but its declaration does not"
                _mg_warn "  currently hold up. The exemption was checked and REFUSED:"
                siteclass_art9_check "$site" || true
                echo "" >&2
                ;;
        esac
    fi

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
