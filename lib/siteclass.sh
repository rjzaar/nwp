#!/bin/bash
################################################################################
# lib/siteclass.sh — per-site CLASS: what a site IS, and therefore which data
# invariants bind it. ADR-0036 / nwp/ops#153, ops#154.
#
# THE THIRD AXIS
# --------------
# ADR-0030 already gives a site two orthogonal axes:
#   canonical:  dev|live|prod                    which host is true for CONTENT
#   maturity:   incubating|stabilizing|production how carefully CODE changes
# Neither answers "does the Art.9 consent gate apply here?" — a question about
# what KIND of site this is and what data it holds. That is this axis:
#   class:      member-paired|member-standalone|demo|service
#
# THE DEFECT THIS EXISTS TO FIX (ops#153/154)
# -------------------------------------------
# `pl moodle gate-status rgs` reports mod/depthcontent [UNGATED]. The gate
# requires ">=1 may_keep_formation call delegating to auth_nwc". rgs is
# UNPAIRED — no SSO, no auth_nwc, no consent source to delegate TO — so no
# artifact rgs can run will EVER satisfy it. The only way through is
# --allow-ungated, forever, which turns a gate into a ritual. One undifferentiated
# gate set was being applied to genuinely different kinds of site.
#
# THE RULE THAT KEEPS THIS FROM BECOMING AN OFF-SWITCH
# ----------------------------------------------------
# A class may RECLASSIFY a gate failure into an EVIDENCED exemption, or (for
# posture `local`, and only behind a fully-validated declaration) RETARGET the
# delegation scan at the site's own consent source. It may NEVER suppress the
# scan or lower what it demands: the exemption path runs only AFTER the scan
# has failed, and the retarget makes the scan require delegation to a
# DIFFERENT class — a call site is still mandatory, and an artifact delegating
# to the wrong source is refused. `none-stored`, the only posture that ships
# an artifact with no gate call at all, is backed by evidence that itself
# fails closed on absence, staleness, expiry, a non-zero formation row count,
# or an exceeded member cap. (On class=demo the cap and expiry are replaced by
# a positive demo-mode assertion — see the none-stored branch and ops#162.)
#
# Modelled directly on `pl contracts key-rotation` (scripts/commands/contracts.sh),
# where `consumer_verifies_signature: false` REQUIRES a positive scan proving no
# verification code exists, and an unreadable corpus is CANNOT-VERIFY:
#
#   "Absence of evidence is not a pass."
#
# PURE: no ssh, no network, no secrets. Everything degrades to a clear refusal.
################################################################################

# --- soft-dep messaging (works standalone or with lib/ui.sh) -----------------
if ! declare -F _sc_err >/dev/null 2>&1; then
    _sc_err()  { if command -v print_error   >/dev/null 2>&1; then print_error   "$*"; else printf 'ERROR: %s\n' "$*" >&2; fi; }
    _sc_warn() { if command -v print_warning >/dev/null 2>&1; then print_warning "$*"; else printf 'WARN: %s\n'  "$*" >&2; fi; }
    _sc_say()  { if command -v print_info    >/dev/null 2>&1; then print_info    "$*"; else printf '%s\n'        "$*"; fi; }
fi

################################################################################
# The closed set
################################################################################

# CLOSED. tests/unit/test-siteclass.bats asserts this is exactly these four —
# widening it fails CI until the test is updated in the same reviewable change.
SITECLASS_CLASSES="${SITECLASS_CLASSES:-member-paired member-standalone demo service}"

# The Art.9 postures. Each carries a positive obligation; none is a skip.
SITECLASS_POSTURES="delegated local none-stored"

siteclass_dir()          { echo "${NWP_SITECLASS_DIR:-${PROJECT_ROOT:-$HOME/nwp}/classes}"; }

# ops#326 (engine/site separation): REAL instance declarations live in the
# PRIVATE OVERLAY repo (private/classes/ — its own reviewed git repo, remote
# nwp/private), searched AFTER the shipped classes/ (which carries only the
# sample pair: ssd, nwd). This preserves the ADR-0036 "reviewable in an MR"
# property — the MR simply lives on the overlay repo — without shipping the
# operator's estate in the engine tree. A site declared in BOTH dirs is
# contradictory and FAILS CLOSED (siteclass_of → cannot-verify:duplicate-…).
siteclass_overlay_dir()  { echo "${NWP_SITECLASS_OVERLAY_DIR:-${PROJECT_ROOT:-$HOME/nwp}/private/classes}"; }
siteclass_registry()     { echo "$(siteclass_dir)/registry.yml"; }
siteclass_decl_file()    {
    local shipped overlay
    shipped="$(siteclass_dir)/${1}.class.yml"
    overlay="$(siteclass_overlay_dir)/${1}.class.yml"
    if [ ! -f "$shipped" ] && [ -f "$overlay" ]; then
        echo "$overlay"
    else
        echo "$shipped"
    fi
}
# 0 iff <site> is declared in BOTH the shipped and overlay dirs. Never resolve
# one silently: two reviewed files disagreeing about what a site IS must be a
# refusal, not a precedence rule nobody remembers.
siteclass_decl_duplicate() {
    local shipped overlay
    shipped="$(siteclass_dir)/${1}.class.yml"
    overlay="$(siteclass_overlay_dir)/${1}.class.yml"
    [ -f "$shipped" ] && [ -f "$overlay" ] && [ "$shipped" != "$overlay" ]
}

siteclass_valid_class() {
    local c="${1:-}" k
    for k in $SITECLASS_CLASSES; do [ "$k" = "$c" ] && return 0; done
    return 1
}

siteclass_valid_posture() {
    local p="${1:-}" k
    for k in $SITECLASS_POSTURES; do [ "$k" = "$p" ] && return 0; done
    return 1
}

# _sc_yq <file> <expr> — read a scalar; empty string for null/absent/unreadable.
_sc_yq() {
    local f="${1:-}" e="${2:-}" out
    [ -n "$f" ] && [ -f "$f" ] || return 0
    command -v yq >/dev/null 2>&1 || return 0
    out="$(yq eval "$e" "$f" 2>/dev/null || true)"
    [ "$out" = "null" ] && out=""
    printf '%s' "$out"
}

################################################################################
# Resolution — tracked declaration is the source of truth, config keys are
# ALSO HONOURED, and disagreement FAILS CLOSED.
#
# Exactly the shape lib/pair.sh uses for pair membership, and for the same
# reason: `nwp.yml` is never committed and `sites/*` is gitignored, so neither
# can carry a claim that a reviewer needs to see. The tracked
# classes/<site>.class.yml is the reviewable authority; the config keys exist so
# that a site config which disagrees is DETECTED rather than silently ignored.
################################################################################

# siteclass_of <site> [global_config] — tri-state resolver.
#   rc 0  prints the class
#   rc 1  prints "undeclared"
#   rc 2  prints "contradictory:<a>|<b>" or "invalid:<raw>" or "cannot-verify:<why>"
#
# rc 2 is NEVER treated as a pass by any caller. An estate that cannot say what
# a site is has not said it is safe.
siteclass_of() {
    local site="${1:-}"
    local config="${2:-${PROJECT_ROOT:-$HOME/nwp}/nwp.yml}"
    [ -n "$site" ] || { echo "cannot-verify:no-site-given"; return 2; }

    if ! command -v yq >/dev/null 2>&1; then
        echo "cannot-verify:yq-not-installed"; return 2
    fi

    # ops#326: a declaration present in BOTH the shipped dir and the private
    # overlay is ambiguity about the authority itself — fail closed.
    if siteclass_decl_duplicate "$site"; then
        echo "cannot-verify:duplicate-declaration:${site}"; return 2
    fi

    local decl tracked site_cfg from_site from_global
    decl="$(siteclass_decl_file "$site")"

    # 1. the tracked declaration (authoritative)
    tracked=""
    if [ -f "$decl" ]; then
        # The body's `site:` key must match the filename it was resolved by.
        # The CODE reads the path, a REVIEWER reads the body — a declaration
        # whose body names a different site would be reviewed as one site and
        # applied to another, which quietly breaks the "reviewable in an MR"
        # property this whole axis rests on.
        local declared_site
        declared_site="$(_sc_yq "$decl" '.site')"
        if [ -n "$declared_site" ] && [ "$declared_site" != "$site" ]; then
            echo "cannot-verify:site-key-mismatch:${declared_site}"; return 2
        fi
        tracked="$(_sc_yq "$decl" '.class')"
        if [ -z "$tracked" ]; then
            echo "cannot-verify:declaration-has-no-class-key"; return 2
        fi
        if ! siteclass_valid_class "$tracked"; then
            echo "invalid:$tracked"; return 2
        fi
    fi

    # 2. the per-site config key (also honoured)
    site_cfg="${PROJECT_ROOT:-$HOME/nwp}/sites/${site}/.nwp.yml"
    from_site="$(_sc_yq "$site_cfg" '.class')"

    # 3. the global registry key (also honoured)
    from_global="$(SC_SITE="$site" _sc_yq "$config" '.sites[strenv(SC_SITE)].class')"

    # Every PRESENT source must agree with the tracked one.
    local s
    for s in "$from_site" "$from_global"; do
        [ -n "$s" ] || continue
        if ! siteclass_valid_class "$s"; then
            echo "invalid:$s"; return 2
        fi
        if [ -n "$tracked" ] && [ "$s" != "$tracked" ]; then
            echo "contradictory:${tracked}|${s}"; return 2
        fi
    done

    if [ -n "$tracked" ]; then
        echo "$tracked"; return 0
    fi

    # No tracked declaration. A config key alone is NOT enough to classify a
    # site: the whole point is that the claim must be reviewable, and a
    # gitignored file cannot be reviewed. Report it distinctly so the operator
    # is told exactly what to do rather than just "undeclared".
    if [ -n "$from_site" ] || [ -n "$from_global" ]; then
        echo "cannot-verify:config-only-no-tracked-declaration"; return 2
    fi

    echo "undeclared"; return 1
}

# siteclass_is_declared <site> — quiet 0/1.
siteclass_is_declared() { siteclass_of "$@" >/dev/null 2>&1; }

################################################################################
# Invariants
################################################################################

# siteclass_invariant <class> <invariant> — echo REQUIRED|NOT_APPLICABLE|...
# Empty output + rc 1 when the registry cannot answer (never a default).
siteclass_invariant() {
    local class="${1:-}" inv="${2:-}" reg out
    reg="$(siteclass_registry)"
    [ -f "$reg" ] || return 1
    out="$(SC_C="$class" SC_I="$inv" _sc_yq "$reg" '.classes[strenv(SC_C)].invariants[strenv(SC_I)]')"
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

################################################################################
# Art.9 posture + evidence
################################################################################

# siteclass_art9_posture <site> — echo the declared posture, or "" with rc 1.
siteclass_art9_posture() {
    local site="${1:-}" decl p
    decl="$(siteclass_decl_file "$site")"
    [ -f "$decl" ] || return 1
    p="$(_sc_yq "$decl" '.art9.posture')"
    [ -n "$p" ] || return 1
    siteclass_valid_posture "$p" || { printf 'invalid:%s' "$p"; return 1; }
    printf '%s' "$p"
    return 0
}

# _sc_days_since <YYYY-MM-DD> — echo whole days since that date; "" if unparseable.
_sc_days_since() {
    local d="${1:-}" then now
    [ -n "$d" ] || return 1
    then="$(date -u -d "$d" +%s 2>/dev/null)" || return 1
    [ -n "$then" ] || return 1
    now="$(date -u +%s)"
    echo $(( (now - then) / 86400 ))
}

# _sc_is_past <YYYY-MM-DD> — 0 if the date is strictly in the past.
_sc_is_past() {
    local d="${1:-}" then now
    then="$(date -u -d "$d" +%s 2>/dev/null)" || return 1
    now="$(date -u +%s)"
    [ "$then" -lt "$now" ]
}

# _sc_is_uint <val> — 0 iff a non-negative decimal integer. Every numeric read
# from a declaration goes through this BEFORE an arithmetic test, because
# `[ garbage -gt 0 ]` ERRORS rather than failing, an errored test is FALSE, and
# a false condition silently skips the very branch that would have refused —
# a check that cannot fail. A garbage reading is not a reading.
# Length-bounded to 18 digits: a 20-digit value is all-digits yet still ERRORS
# `[ -gt ]` (past 2^63), and an errored test is FALSE — the same silent-skip
# hole from the other side.
_sc_is_uint() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 18 ]
}

# _sc_is_date <val> — 0 iff literally YYYY-MM-DD. `date -d` alone is NOT a
# validator: it accepts relative English ("tomorrow", "now"), which would make
# an exemption's time bounds float with the clock — never stale, never expired.
# A recorded date is a fixed point or it is not a record.
_sc_is_date() {
    case "${1:-}" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}

# siteclass_art9_check <site> — verify the site's declared Art.9 posture is
# actually honoured. Prints one machine-greppable token per failure.
#   rc 0  the posture's obligations are satisfied
#   rc 1  a specific obligation is broken
#   rc 2  CANNOT-VERIFY (never a pass)
#
# THIS IS THE ANTI-VACUITY CORE. `none-stored` — the only posture that can
# excuse an artifact from carrying the gate — is the posture with the MOST
# obligations, deliberately. It costs more to declare than --allow-ungated
# costs to type, and unlike --allow-ungated it expires and it notices members.
siteclass_art9_check() {
    local site="${1:-}"
    local decl; decl="$(siteclass_decl_file "$site")"
    local bad=0

    if ! command -v yq >/dev/null 2>&1; then
        _sc_err "[$site] CANNOT-VERIFY: yq not installed — the declaration cannot be parsed."
        return 2
    fi
    if [ ! -f "$decl" ]; then
        _sc_err "[$site] CANNOT-VERIFY: no class declaration at classes/${site}.class.yml (shipped) or private/classes/${site}.class.yml (overlay)."
        _sc_say "  A site with no declared class has not been said to be safe; it has only"
        _sc_say "  not been described. Declare one:  pl class set $site <class>"
        return 2
    fi

    local posture; posture="$(siteclass_art9_posture "$site")" || {
        _sc_err "[$site] CANNOT-VERIFY: art9.posture is absent or not one of: $SITECLASS_POSTURES"
        _sc_err "                       (got: '${posture:-<absent>}'). This is the load-bearing"
        _sc_err "                       fact; it may not be left implicit."
        return 2
    }

    # The class must actually permit this posture.
    local class; class="$(siteclass_of "$site")" || {
        _sc_err "[$site] CANNOT-VERIFY: class is '$class'."
        return 2
    }
    local allowed
    allowed="$(SC_C="$class" _sc_yq "$(siteclass_registry)" '[.classes[strenv(SC_C)].art9.posture_required] | flatten | join(" ")')"
    # The registry is what stops a class buying a posture it is not entitled
    # to. An unreadable registry (deleted, renamed, YAML rot, NWP_SITECLASS_DIR
    # pointing somewhere bare) must therefore be CANNOT-VERIFY — skipping this
    # check on an empty read is precisely the fail-open the ABUSE tests exist
    # to forbid, and it would fail open for EVERY site at once.
    if [ -z "$allowed" ]; then
        _sc_err "[$site] CANNOT-VERIFY: classes/registry.yml is unreadable or carries no"
        _sc_err "                       art9.posture_required for class '$class', so posture"
        _sc_err "                       permission cannot be checked. A missing rulebook is"
        _sc_err "                       not permission."
        return 2
    fi
    if ! printf '%s' " $allowed " | grep -q " $posture "; then
        _sc_err "[$site] POSTURE-NOT-PERMITTED: class '$class' permits posture(s) [$allowed],"
        _sc_err "                              but this site declares '$posture'."
        bad=1
    fi

    case "$posture" in
        delegated)
            # Obligation: a real consent source must EXIST to delegate to.
            local src pair_contract
            src="$(_sc_yq "$decl" '.art9.consent_source')"
            if [ -z "$src" ]; then
                _sc_err "[$site] NO-CONSENT-SOURCE: posture=delegated but art9.consent_source is unset."
                _sc_err "                          Delegation to nothing is not delegation."
                bad=1
            else
                # ops#326: the contract, like the declaration, may live in the
                # private overlay (same search order as lib/pair.sh).
                pair_contract="${NWP_PAIR_CONTRACT_DIR:-${PROJECT_ROOT:-$HOME/nwp}/pairs}/${site}.pair-contract.yml"
                if [ ! -f "$pair_contract" ]; then
                    local _sc_ovl_contract
                    _sc_ovl_contract="${NWP_PAIR_OVERLAY_DIR:-${PROJECT_ROOT:-$HOME/nwp}/private/pairs}/${site}.pair-contract.yml"
                    [ -f "$_sc_ovl_contract" ] && pair_contract="$_sc_ovl_contract"
                fi
                if [ ! -f "$pair_contract" ]; then
                    _sc_err "[$site] NO-CONSENT-SOURCE: posture=delegated names consent_source='$src',"
                    _sc_err "                          but there is no pair contract at pairs/${site}.pair-contract.yml."
                    _sc_err "                          An unpaired site has nothing to delegate to — this is"
                    _sc_err "                          exactly the rgs shape (ops#153)."
                    bad=1
                else
                    local provider; provider="$(_sc_yq "$pair_contract" '.provider')"
                    if [ -n "$provider" ] && [ "$provider" != "$src" ]; then
                        _sc_err "[$site] CONSENT-SOURCE-MISMATCH: declaration says '$src', the pair"
                        _sc_err "                                contract says provider '$provider'."
                        bad=1
                    fi
                fi
            fi
            ;;

        local)
            # Obligation: the local consent source must be named AND present.
            local lp lroot
            lp="$(_sc_yq "$decl" '.art9.consent_source_plugin')"
            if [ -z "$lp" ]; then
                _sc_err "[$site] NO-LOCAL-CONSENT-SOURCE: posture=local but"
                _sc_err "                                art9.consent_source_plugin is unset."
                bad=1
            else
                lroot="$(_sc_yq "$decl" '.art9.consent_source_root')"
                if [ -z "$lroot" ]; then
                    _sc_err "[$site] CANNOT-VERIFY: posture=local names plugin '$lp' but no"
                    _sc_err "                       art9.consent_source_root to look for it in, so the"
                    _sc_err "                       claim cannot be checked against code."
                    _sc_err "                       Absence of evidence is not a pass."
                    return 2
                fi
                if [ ! -d "${PROJECT_ROOT:-$HOME/nwp}/$lroot" ]; then
                    _sc_err "[$site] LOCAL-SOURCE-ABSENT: art9.consent_source_root '$lroot' does not"
                    _sc_err "                            exist here, so the local consent source cannot"
                    _sc_err "                            be shown to exist. Absence of evidence is not a pass."
                    return 2
                fi
            fi
            ;;

        none-stored)
            # ---------------------------------------------------------------
            # The bounded, evidenced exemption. TWO SHAPES (ops#162):
            #
            #   rgs shape (member-standalone, service): member cap +
            #     attestation + EXPIRY. Six obligations, exactly as before.
            #
            #   demo shape (class=demo only): a demo is synthetic BY DESIGN.
            #     Its honest checkable assertion is not "member_count <= cap"
            #     — seeded accounts are not capped real members — but
            #     "demo_mode is ON and formation_rows == 0". The member cap
            #     is REPLACED by a positive demo-mode assertion
            #     (demo_mode_probe_cmd + attestation.demo_mode: true), and
            #     art9.expires is NOT required: demo is a STANDING class
            #     property, not an expiring exemption. An expires that IS
            #     declared is still honoured — a declared bound may not rot.
            # ---------------------------------------------------------------
            local demo_shape=0
            [ "$class" = "demo" ] && demo_shape=1

            local probe max_members max_age att_at att_by rows members expires

            probe="$(_sc_yq "$decl" '.art9.evidence.probe_cmd')"
            if [ -z "$probe" ]; then
                _sc_err "[$site] NO-PROBE: posture=none-stored but art9.evidence.probe_cmd is unset."
                _sc_err "                  A claim nobody can re-check is folklore. Declare the command"
                _sc_err "                  that would falsify it."
                bad=1
            fi

            if [ "$demo_shape" -eq 1 ]; then
                # The cap-replacing assertion: HOW is demo mode checked?
                local demo_probe
                demo_probe="$(_sc_yq "$decl" '.art9.evidence.demo_mode_probe_cmd')"
                if [ -z "$demo_probe" ]; then
                    _sc_err "[$site] NO-DEMO-PROBE: class=demo but art9.evidence.demo_mode_probe_cmd is"
                    _sc_err "                       unset. The demo-mode assertion REPLACES the member cap;"
                    _sc_err "                       a demo that cannot say how demo_mode would be checked"
                    _sc_err "                       has not asserted it."
                    bad=1
                fi
            fi

            att_at="$(_sc_yq "$decl" '.art9.evidence.attestation.at')"
            att_by="$(_sc_yq "$decl" '.art9.evidence.attestation.by')"
            rows="$(_sc_yq   "$decl" '.art9.evidence.attestation.formation_rows')"
            members="$(_sc_yq "$decl" '.art9.evidence.attestation.member_count')"
            if [ "$demo_shape" -eq 1 ]; then
                # member_count is NOT required on a demo: seeded accounts are
                # not capped real members, and demanding a cap here would
                # either misrepresent them or gut the cap's meaning on rgs.
                if [ -z "$att_at" ] || [ -z "$att_by" ] || [ -z "$rows" ]; then
                    _sc_err "[$site] NO-ATTESTATION: class=demo posture=none-stored requires"
                    _sc_err "                        art9.evidence.attestation with at/by/formation_rows."
                    _sc_err "                        Got at='${att_at:-<unset>}' by='${att_by:-<unset>}'"
                    _sc_err "                        formation_rows='${rows:-<unset>}'."
                    _sc_err "                        An unevidenced exemption is just --allow-ungated with"
                    _sc_err "                        extra steps."
                    return 1
                fi
            elif [ -z "$att_at" ] || [ -z "$att_by" ] || [ -z "$rows" ] || [ -z "$members" ]; then
                _sc_err "[$site] NO-ATTESTATION: posture=none-stored requires"
                _sc_err "                        art9.evidence.attestation with at/by/formation_rows/"
                _sc_err "                        member_count. Got at='${att_at:-<unset>}'"
                _sc_err "                        by='${att_by:-<unset>}' formation_rows='${rows:-<unset>}'"
                _sc_err "                        member_count='${members:-<unset>}'."
                _sc_err "                        An unevidenced exemption is just --allow-ungated with"
                _sc_err "                        extra steps."
                return 1
            fi

            # rows always; member_count wherever it is PRESENT (a garbage
            # reading that was declared must refuse, whatever the shape).
            if ! _sc_is_uint "$rows" || { [ -n "$members" ] && ! _sc_is_uint "$members"; }; then
                _sc_err "[$site] CANNOT-VERIFY: attestation readings must be non-negative integers"
                _sc_err "                       (got formation_rows='$rows' member_count='$members')."
                _sc_err "                       A garbage reading is not a reading."
                return 2
            fi

            if [ "$demo_shape" -eq 1 ]; then
                # The recorded reading of demo_mode_probe_cmd must be exactly
                # `true`. Off, absent, or anything else fails closed: a demo
                # whose demo_mode is off is NOT a demo — real signups could
                # land in it.
                local demo_mode
                demo_mode="$(_sc_yq "$decl" '.art9.evidence.attestation.demo_mode')"
                if [ "$demo_mode" != "true" ]; then
                    _sc_err "[$site] DEMO-MODE-OFF: attestation.demo_mode='${demo_mode:-<unset>}' — the"
                    _sc_err "                      recorded demo-mode reading must be exactly 'true'."
                    _sc_err "                      A demo whose demo_mode is off is NOT a demo; real"
                    _sc_err "                      accounts could exist. Fail closed."
                    bad=1
                fi
            fi

            max_age="$(_sc_yq "$decl" '.art9.evidence.max_age_days')"
            [ -n "$max_age" ] || max_age=30
            if ! _sc_is_uint "$max_age"; then
                _sc_err "[$site] CANNOT-VERIFY: max_age_days='$max_age' is not a non-negative integer,"
                _sc_err "                       so the staleness bound cannot be applied."
                return 2
            fi
            if ! _sc_is_date "$att_at"; then
                _sc_err "[$site] CANNOT-VERIFY: attestation.at='$att_at' is not a literal YYYY-MM-DD."
                _sc_err "                       Relative dates ('now') would make the staleness clock"
                _sc_err "                       float with the wall clock — never stale by construction."
                return 2
            fi
            local age; age="$(_sc_days_since "$att_at")" || {
                _sc_err "[$site] CANNOT-VERIFY: attestation.at='$att_at' is not a parseable date."
                return 2
            }
            if [ "$age" -gt "$max_age" ]; then
                _sc_err "[$site] STALE-ATTESTATION: the evidence was taken ${age}d ago (at $att_at),"
                _sc_err "                          exceeding max_age_days=${max_age}. Re-attest:"
                _sc_err "                            pl class evidence $site --refresh"
                bad=1
            fi

            # The two readings that make the exemption self-dissolving.
            if [ "$rows" != "0" ]; then
                _sc_err "[$site] EVIDENCE-CONTRADICTS: the declaration asserts this site stores no"
                _sc_err "                            Art.9 formation data, but its own attestation"
                _sc_err "                            records formation_rows=$rows. The exemption is void."
                bad=1
            fi

            if [ "$demo_shape" -eq 0 ]; then
                # The member cap — rgs shape only. On class=demo the cap is
                # replaced by the demo-mode assertion above.
                max_members="$(_sc_yq "$decl" '.art9.evidence.max_members')"
                [ -n "$max_members" ] || max_members=0
                if ! _sc_is_uint "$max_members"; then
                    _sc_err "[$site] CANNOT-VERIFY: max_members='$max_members' is not a non-negative"
                    _sc_err "                       integer, so the member cap cannot be applied."
                    return 2
                fi
                if [ "$members" -gt "$max_members" ]; then
                    _sc_err "[$site] MEMBER-CAP-EXCEEDED: member_count=$members exceeds max_members=$max_members."
                    _sc_err "                            ops#153: the exposure 'becomes real the day rgs takes"
                    _sc_err "                            a member'. That day is today. The exemption is void —"
                    _sc_err "                            ship a gated artifact or build a local consent source."
                    bad=1
                fi
            fi

            expires="$(_sc_yq "$decl" '.art9.expires')"
            if [ -z "$expires" ]; then
                # class=demo: expiry NOT required. A demo is a standing class
                # property, not an expiring exemption (ops#162; documented in
                # classes/registry.yml). Every other none-stored declarer
                # (rgs shape) must still expire — unchanged.
                if [ "$demo_shape" -eq 0 ]; then
                    _sc_err "[$site] EXEMPTION-EXPIRED: art9.expires is unset. An open-ended exemption is"
                    _sc_err "                          the ritual this axis exists to abolish; set a date."
                    bad=1
                fi
            elif ! _sc_is_date "$expires" || ! date -u -d "$expires" +%s >/dev/null 2>&1; then
                # Two distinct holes, one refusal: garbage must not read as "not
                # yet expired" (_sc_is_past returns non-zero for it, silently
                # skipping the branch), and a RELATIVE date ('tomorrow') that
                # `date -d` happily parses would expire never — the bound must
                # be a fixed YYYY-MM-DD.
                _sc_err "[$site] CANNOT-VERIFY: art9.expires='$expires' is not a literal, parseable"
                _sc_err "                       YYYY-MM-DD, so the expiry bound cannot be applied."
                return 2
            elif _sc_is_past "$expires"; then
                _sc_err "[$site] EXEMPTION-EXPIRED: art9.expires=$expires has passed."
                bad=1
            fi
            ;;
    esac

    return "$bad"
}

# siteclass_art9_exempt <site> — QUIET predicate used by the deploy gate.
# 0 iff the site legitimately carries an evidenced none-stored exemption.
# Any doubt whatsoever returns non-zero.
siteclass_art9_exempt() {
    local site="${1:-}" posture
    posture="$(siteclass_art9_posture "$site" 2>/dev/null)" || return 1
    [ "$posture" = "none-stored" ] || return 1
    siteclass_art9_check "$site" >/dev/null 2>&1
}

# siteclass_art9_local_class <site> — for posture=local, the class a shipped
# artifact must delegate to instead of auth_nwc. Empty + rc 1 if not applicable.
siteclass_art9_local_class() {
    local site="${1:-}" decl p out
    p="$(siteclass_art9_posture "$site" 2>/dev/null)" || return 1
    [ "$p" = "local" ] || return 1
    decl="$(siteclass_decl_file "$site")"
    out="$(_sc_yq "$decl" '.art9.consent_source_class')"
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

################################################################################
# Ledger — an exemption USED is an event, not just a setting.
#
# Shares the moodle-gate ledger so that `private/moodle-gate/<site>.log` tells
# one continuous story: the two historical `action=allow-ungated` lines for rgs
# and, after this lands, `action=class-exempt` lines carrying the evidence that
# justified each one.
################################################################################
siteclass_ledger_dir() { echo "${PROJECT_ROOT:-$HOME/nwp}/private/moodle-gate"; }
siteclass_actor()      { echo "$(id -un)@$(hostname -s 2>/dev/null || hostname)"; }

siteclass_ledger_append() {
    local site="${1:-unknown}"; shift
    local dir; dir="$(siteclass_ledger_dir)"
    mkdir -p "$dir" 2>/dev/null || return 0
    echo "$(date -u +%FT%TZ) who=$(siteclass_actor) $*" >> "${dir}/${site}.log"
}
