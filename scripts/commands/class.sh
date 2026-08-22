#!/bin/bash
set -euo pipefail

################################################################################
# pl class — per-site CLASS: what a site IS, therefore which invariants apply.
# NWP-ADR-0036 / nwp/ops#153, ops#154.
#
# The third per-site axis, beside the two from NWP-ADR-0030:
#   pl canonical  content-flow  (dev|live|prod)          where truth lives
#   pl maturity   code-flow     (incubating|…|production) how carefully code moves
#   pl class      data/identity (this)                    what the site IS
#
# Unlike the other two, the authoritative declaration is a TRACKED file
# (classes/<site>.class.yml), because `nwp.yml` is never committed and `sites/*`
# is gitignored — and a claim that decides whether the Art.9 consent gate
# applies to a live formation site has to be reviewable in a merge request.
#
# FAILS CLOSED. `undeclared`, `contradictory:`, `invalid:` and `cannot-verify:`
# are all non-zero. An estate that cannot say what a site is has not said it is
# safe.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Code loads from where THIS script lives; PROJECT_ROOT (the data root:
# sites/, classes/, pairs/) is env-overridable so the CLI surface is
# unit-testable against fixtures — the review that forced this found every
# non-zero code path here untested (and, as it happened, unreachable; see the
# errexit notes below).
NWP_SRC_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$NWP_SRC_ROOT}"

source "$NWP_SRC_ROOT/lib/ui.sh"
source "$NWP_SRC_ROOT/lib/common.sh"
source "$NWP_SRC_ROOT/lib/siteclass.sh"

show_help() {
    cat << EOF
${BOLD}pl class${NC} — per-site class: what a site IS, therefore which invariants apply

${BOLD}USAGE:${NC}
    pl class show [site]        Class of every site (or one), with Art.9 posture
    pl class check <site>       Full report: class, gates that follow, what fails
    pl class set <site> <class> Declare a class (writes the TRACKED declaration)
    pl class list               The closed class set and each one's invariants
    pl class evidence <site>    Show the Art.9 evidence backing an exemption

${BOLD}CLASSES:${NC}
    member-paired       real members; identity+consent from a paired provider
                        → Art.9 gate REQUIRED, delegated to that provider
    member-standalone   real members; NO paired provider, no consent source
                        → Art.9 satisfied locally, or exempted BY EVIDENCE
    demo                synthetic/seeded data only; resettable; never real members
                        → Art.9 N/A, asserted via demo_mode=on + zero formation
                          rows (ops#162 — the demo-mode probe replaces the
                          member cap; no expiry, it is a standing property)
    service             no non-operator accounts at all
                        → Art.9 N/A, asserted via a zero-account claim

${BOLD}ART.9 POSTURES${NC} (each carries a positive obligation; none is a skip):
    delegated     a paired provider holds consent; the artifact must ask it
    local         the site carries its own consent source; must exist + be called
    none-stored   bounded, evidenced, EXPIRING exemption — the only posture that
                  lets an artifact ship without a gate call site, and the one
                  with the most obligations

${BOLD}EXIT:${NC} 0 declared and consistent · 1 undeclared or an obligation broken
        2 CANNOT-VERIFY (never treated as a pass)

Declarations: classes/<site>.class.yml (tracked)   Registry: classes/registry.yml
EOF
}

# --- helpers ----------------------------------------------------------------

# The UNION of sites that have a local tree and sites that have a declaration.
# Not just sites/*/ — rgs's whole shape is "declared and live, but its build tree
# lives on another host", and a site that exists only as a declaration must still
# be listed or the axis reintroduces the very blindness ops#149 fixed.
_class_all_sites() {
    {
        local d
        for d in "$PROJECT_ROOT"/sites/*/.nwp.yml; do
            [ -f "$d" ] || continue
            basename "$(dirname "$d")"
        done
        for d in "$(siteclass_dir)"/*.class.yml; do
            [ -f "$d" ] || continue
            basename "$d" .class.yml
        done
    } | sort -u
}

_class_posture_display() {
    local site="$1" p
    p="$(siteclass_art9_posture "$site" 2>/dev/null || true)"
    [ -n "$p" ] && printf '%s' "$p" || printf '%s' "-"
}

# --- show -------------------------------------------------------------------

cmd_show() {
    local one="${1:-}"
    local sites
    if [ -n "$one" ]; then sites="$one"; else sites="$(_class_all_sites)"; fi
    [ -n "$sites" ] || { print_info "No sites found under sites/"; return 0; }

    print_header "Site classes (what each site IS — NWP-ADR-0036)"
    printf "  ${BOLD}%-16s %-20s %-14s %-10s %s${NC}\n" "SITE" "CLASS" "ART.9 POSTURE" "ART.9" "NOTE"
    printf "  %-16s %-20s %-14s %-10s %s\n" "----------------" "--------------------" "--------------" "----------" "----"

    local site cls rc posture a9 note undeclared=0 broken=0
    while read -r site; do
        [ -z "$site" ] && continue
        rc=0; cls="$(siteclass_of "$site" 2>/dev/null)" || rc=$?
        posture="$(_class_posture_display "$site")"
        note=""
        if [ "$rc" -eq 0 ]; then
            if siteclass_art9_check "$site" >/dev/null 2>&1; then a9="OK"
            else a9="FAIL"; broken=$((broken+1)); note="pl class check $site"; fi
        else
            a9="-"
            undeclared=$((undeclared+1))
            case "$cls" in
                undeclared) note="no classes/${site}.class.yml" ;;
                *)          note="FAILS CLOSED" ;;
            esac
        fi
        printf "  %-16s %-20s %-14s %-10s %s\n" "$site" "$cls" "$posture" "$a9" "$note"
    done <<< "$sites"

    echo ""
    print_info "$undeclared undeclared, $broken with a broken Art.9 obligation."
    if [ "$undeclared" -gt 0 ]; then
        print_info "Undeclared is not a permissive default — it is 'nobody has said what this is'."
        print_info "Declare one:  pl class set <site> <member-paired|member-standalone|demo|service>"
    fi
    [ "$broken" -eq 0 ] || return 1
    return 0
}

# --- check ------------------------------------------------------------------

cmd_check() {
    local site="${1:-}"
    [ -n "$site" ] || { print_error "Usage: pl class check <site>"; return 2; }

    print_header "Class check: $site"

    local cls rc
    rc=0; cls="$(siteclass_of "$site" 2>/dev/null)" || rc=$?
    echo -e "  ${BOLD}Class:${NC} $cls"

    if [ "$rc" -ne 0 ]; then
        echo ""
        case "$cls" in
            undeclared)
                print_error "UNDECLARED — no classes/${site}.class.yml."
                print_info "This is not 'no constraints'. It is 'nobody has said what this site is',"
                print_info "so no gate can tell whether it applies. Declare it:"
                print_info "  pl class set $site <member-paired|member-standalone|demo|service>"
                return 1 ;;
            contradictory:*)
                print_error "CONTRADICTORY — the tracked declaration and a site config disagree:"
                print_error "  ${cls#contradictory:}"
                print_info "classes/${site}.class.yml is the source of truth; fix the config key"
                print_info "(sites/${site}/.nwp.yml or nwp.yml sites.${site}.class) to match."
                return 2 ;;
            invalid:*)
                print_error "INVALID class '${cls#invalid:}' — not one of: $SITECLASS_CLASSES"
                return 2 ;;
            *)
                print_error "CANNOT-VERIFY — ${cls#cannot-verify:}"
                print_info "Never treated as a pass."
                return 2 ;;
        esac
    fi

    # Invariants that follow from the class.
    echo ""
    echo -e "  ${BOLD}Invariants that follow from this class:${NC}"
    local inv val
    for inv in art9_consent_gate erasure_channel pair_contract uid_lock_code_only \
               sanitize_on_downcopy real_member_pii; do
        val="$(siteclass_invariant "$cls" "$inv" 2>/dev/null || echo '?')"
        printf "    %-24s %s\n" "$inv" "$val"
    done

    # The Art.9 obligation, checked for real.
    echo ""
    echo -e "  ${BOLD}Art.9 posture and its obligations:${NC}"
    local posture; posture="$(siteclass_art9_posture "$site" 2>/dev/null || echo '<unset>')"
    echo "    posture: $posture"
    echo ""
    local out arc=0
    out="$(siteclass_art9_check "$site" 2>&1)" || arc=$?
    if [ -n "$out" ]; then printf '%s\n' "$out"; fi
    case "$arc" in
        0) print_status "OK" "the declared posture's obligations are satisfied" ;;
        1) print_status "FAIL" "an obligation is broken — the gate will REFUSE (see above)" ;;
        *) print_status "FAIL" "CANNOT-VERIFY — never treated as a pass" ;;
    esac

    echo ""
    print_info "Sibling axes:  pl canonical check $site   ·   pl maturity check $site"
    return "$arc"
}

# --- list -------------------------------------------------------------------

cmd_list() {
    local reg; reg="$(siteclass_registry)"
    [ -f "$reg" ] || { print_error "No registry at $reg"; return 2; }
    print_header "The closed class set (classes/registry.yml)"
    local c
    for c in $SITECLASS_CLASSES; do
        echo ""
        echo -e "  ${BOLD}${c}${NC}"
        SC_C="$c" yq eval '.classes[strenv(SC_C)].summary' "$reg" 2>/dev/null \
            | sed 's/^/      /'
        echo "      invariants:"
        SC_C="$c" yq eval '.classes[strenv(SC_C)].invariants | to_entries | .[] | "        " + .key + ": " + .value' "$reg" 2>/dev/null
    done
    echo ""
    print_info "A class may reclassify a gate failure into an EVIDENCED exemption."
    print_info "It may never suppress the scan that produced the failure."
    return 0
}

# --- evidence ---------------------------------------------------------------

cmd_evidence() {
    local site="${1:-}"; shift || true
    [ -n "$site" ] || { print_error "Usage: pl class evidence <site>"; return 2; }
    local decl; decl="$(siteclass_decl_file "$site")"
    # Exit 2 in this file means CANNOT VERIFY — "something stopped me looking".
    # Nothing stopped this look: the site has simply never been declared, which
    # `cmd_check` above reports properly at exit 1, with the verb that fixes it
    # and a sentence explaining that undeclared is not a permissive default.
    # Same missing file, two verdicts in one file, and the worse one was here.
    if [ ! -f "$decl" ]; then
        print_error "UNDECLARED — no classes/${site}.class.yml."
        print_info "This is not 'no evidence recorded'. It is 'nobody has said what this site"
        print_info "is', so there is no declared probe for evidence to exist against. Declare it:"
        print_info "  pl class set $site <member-paired|member-standalone|demo|service>"
        return 1
    fi

    local a
    for a in "$@"; do
        case "$a" in
            --refresh)
                print_error "NOT IMPLEMENTED — deliberately."
                print_info "Re-attesting means reading the LIVE database of '$site'. That needs a"
                print_info "server-health preflight and a live read, neither of which belongs in a"
                print_info "gate library. Run the declared probe yourself and record the reading:"
                print_info ""
                print_info "  $(_sc_yq "$decl" '.art9.evidence.probe_cmd')"
                print_info ""
                print_info "then update art9.evidence.attestation in classes/${site}.class.yml"
                print_info "(a tracked file — the update is reviewed, which is the point)."
                return 2 ;;
        esac
    done

    print_header "Art.9 evidence: $site"
    local posture; posture="$(siteclass_art9_posture "$site" 2>/dev/null || echo '<unset>')"
    echo "  posture : $posture"
    if [ "$posture" != "none-stored" ]; then
        print_info "This posture grants no exemption and consumes no evidence."
        return 0
    fi
    echo "  probe   : $(_sc_yq "$decl" '.art9.evidence.probe_cmd')"
    local cls; cls="$(siteclass_of "$site" 2>/dev/null || true)"
    if [ "$cls" = "demo" ]; then
        # ops#162 demo shape: demo-mode assertion replaces the member cap;
        # no expiry — a demo is a standing class property.
        echo "  demo    : $(_sc_yq "$decl" '.art9.evidence.demo_mode_probe_cmd')"
        echo "  age     : max_age_days=$(_sc_yq "$decl" '.art9.evidence.max_age_days')   (demo shape: no member cap, no expiry)"
    else
        echo "  cap     : max_members=$(_sc_yq "$decl" '.art9.evidence.max_members') max_age_days=$(_sc_yq "$decl" '.art9.evidence.max_age_days')"
        echo "  expires : $(_sc_yq "$decl" '.art9.expires')"
    fi
    echo ""
    echo "  attestation:"
    yq eval '.art9.evidence.attestation' "$decl" 2>/dev/null | sed 's/^/    /'
    echo ""
    local out arc=0
    out="$(siteclass_art9_check "$site" 2>&1)" || arc=$?
    [ -n "$out" ] && printf '%s\n' "$out"
    [ "$arc" -eq 0 ] && print_status "OK" "the exemption holds today" \
                     || print_status "FAIL" "the exemption does NOT hold"
    return "$arc"
}

# --- set --------------------------------------------------------------------

cmd_set() {
    local site="${1:-}" new="${2:-}"
    [ -n "$site" ] && [ -n "$new" ] || {
        print_error "Usage: pl class set <site> <$(echo "$SITECLASS_CLASSES" | tr ' ' '|')>"; return 2; }
    siteclass_valid_class "$new" || {
        print_error "Invalid class '$new' — must be one of: $SITECLASS_CLASSES"; return 2; }

    local decl; decl="$(siteclass_decl_file "$site")"
    mkdir -p "$(siteclass_dir)"

    local who at
    # The declaration is a TRACKED file: no user@hostname in it (leakage gate;
    # git history carries the author anyway). Role label, overridable.
    who="${NWP_CLASS_ACTOR:-operator}"; at="$(date -u +%F)"

    if [ -f "$decl" ]; then
        local cur; cur="$(_sc_yq "$decl" '.class')"
        if [ "$cur" = "$new" ]; then
            print_info "'$site' is already class: $new — nothing to do."
            return 0
        fi
        print_warning "Reclassifying '$site': $cur → $new"
        print_warning "A class change changes WHICH INVARIANTS APPLY. Review the Art.9 block."
        yq eval -i ".class = \"$new\"" "$decl"
        yq eval -i ".classified_by = \"$who\"" "$decl"
        yq eval -i ".classified_at = \"$at\"" "$decl"
    elif [ "$new" = "demo" ]; then
        # Demo gets the DEMO-SHAPED none-stored skeleton (ops#162): the
        # registry permits exactly one posture for this class, so it is
        # prefilled; the demo-mode assertion replaces the member cap and no
        # expires is required. The placeholders keep 'pl class check' failing
        # (NO-PROBE / NO-DEMO-PROBE / DEMO-MODE-OFF) until an operator runs
        # the probes and records real readings — scaffolding is not attestation.
        cat > "$decl" <<EOF
# classes/${site}.class.yml — site class declaration (NWP-ADR-0036 / ops#162)
# TRACKED on purpose: nwp.yml is never committed and sites/* is gitignored, so
# neither can carry a claim a reviewer needs to see.
site: ${site}
class: demo
classified_by: "${who}"
classified_at: "${at}"

art9:
  # class demo permits exactly this posture (classes/registry.yml).
  posture: none-stored

  # DEMO-SHAPED evidence (ops#162): a demo is synthetic BY DESIGN, so the
  # demo-mode assertion REPLACES the member cap, and no expires: is required —
  # a demo is a standing class property, not an expiring exemption.
  # Until every placeholder below carries a real probe command and a real
  # reading, 'pl class check ${site}' FAILS and this site is exempt from
  # nothing.
  evidence:
    # The command that counts Art.9 formation rows on the site (must read 0).
    probe_cmd: ""
    # The command that POSITIVELY checks the site is in demo mode, e.g.
    #   Drupal: pl drush ${site} --tier=live -- config:get nwc_demo_access.settings demo_mode
    #   Moodle: the equivalent admin/cli probe on the demo instance
    demo_mode_probe_cmd: ""
    max_age_days: 30
    attestation:
      at: ""             # YYYY-MM-DD the probes were ACTUALLY run
      by: ""             # role label, never user@hostname (tracked file)
      formation_rows:    # must be 0, as read by probe_cmd
      demo_mode:         # must be true, as read by demo_mode_probe_cmd
EOF
        print_status "OK" "wrote $decl (demo-shaped Art.9 evidence skeleton)"
    else
        cat > "$decl" <<EOF
# classes/${site}.class.yml — site class declaration (NWP-ADR-0036)
# TRACKED on purpose: nwp.yml is never committed and sites/* is gitignored, so
# neither can carry a claim a reviewer needs to see.
site: ${site}
class: ${new}
classified_by: "${who}"
classified_at: "${at}"

art9:
  # REQUIRED. One of: delegated | local | none-stored.
  # Each carries a positive obligation — see classes/registry.yml.
  # Until this is filled in, 'pl class check ${site}' reports CANNOT-VERIFY and
  # the Art.9 gate will not treat this site as exempt from anything.
  posture:
EOF
        print_status "OK" "wrote $decl"
    fi

    # Mirror into the site config as a cross-check (also honoured; a disagreement
    # is DETECTED rather than silently ignored).
    local site_cfg="$PROJECT_ROOT/sites/${site}/.nwp.yml"
    if [ -f "$site_cfg" ]; then
        yq eval -i ".class = \"$new\"" "$site_cfg"
        print_info "Mirrored class into sites/${site}/.nwp.yml (cross-check)."
    fi

    siteclass_ledger_append "$site" "action=class-set ref=ops#153 class=${new}"
    echo ""
    print_info "Now declare the Art.9 posture in $decl, then:  pl class check $site"
    return 0
}

main() {
    local args=() a
    for a in "$@"; do
        case "$a" in
            -h|--help) show_help; exit 0 ;;
            *) args+=("$a") ;;
        esac
    done
    set -- "${args[@]:-}"

    local sub="${1:-show}"
    case "$sub" in
        show)     cmd_show "${2:-}" ;;
        check)    cmd_check "${2:-}" ;;
        set)      cmd_set "${2:-}" "${3:-}" ;;
        list)     cmd_list ;;
        evidence) shift; cmd_evidence "$@" ;;
        *)
            if [ -f "$PROJECT_ROOT/sites/${sub}/.nwp.yml" ]; then
                cmd_check "$sub"
            else
                print_error "Unknown subcommand: $sub"
                show_help
                exit 2
            fi
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
