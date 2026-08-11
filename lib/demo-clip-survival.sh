#!/usr/bin/env bash
# lib/demo-clip-survival.sh — would an author's clip choices survive tonight?
#
# ── THE HOLE (nwp/ops#338) ──────────────────────────────────────────────────
# The nightly demo reset is a FULL destroy-and-restore, with no allowlist:
#
#     drush sql:drop -y && gunzip -c "${GOLDEN_DIR}/${GOLDEN_DB}" | drush sql:cli
#
# (servers/live/demo/nwd-demo-reset-restricted). Two PRE-WIPE legs already
# exist because two earlier data losses were noticed — `harvest` for watchdog
# and `feedback-sync` for tester feedback. There is NO leg for clip choices, so
# every clip_choice revision, clip_review_decision, clip_suggestion and
# off-list video_snippet made on a reset-path site is destroyed at 01:00 with
# nothing kept.
#
# ── WHY THIS IS A CHECK AND NOT A COMMENT ───────────────────────────────────
# Today the authoring site (nwc) is NOT on the reset path and the demo site
# (nwd) is. That is the whole safety argument, and it rests on nothing but
# convention: nwc simply has no `class: demo` and its pair contract has no
# `demo:` block. Nobody would notice if that changed. A convention that is
# load-bearing and unenforced is the "check that has never been proven to
# fail" shape CLAUDE.md names — so it is expressed here as something that can
# go RED.
#
# ── THE RULE, keyed off CONFIG and never off a site's name ──────────────────
# CLAUDE.md: *"key off the per-site canonical phase … never off a site's
# name."* The same reasoning applies here: "refuse nwd" would be wrong the
# moment a second demo site exists. A site is on the reset path when it
# DECLARES itself one:
#
#   - `class: demo` in sites/<site>/.nwp.yml, or
#   - it is the provider or consumer of a pair contract whose `demo.enabled`
#     is true.
#
# A site is at risk when it is on that path AND carries clip-review authoring
# data AND has no clip-choice pre-wipe leg.
#
# Exit codes (fail-closed):
#   0  no site is at risk
#   1  at least one site IS at risk
#   2  CANNOT VERIFY — never treat as a pass

# The export command that already exists in nwc_clip_choice but that nothing
# ever invokes. Its default --out is <siteroot>/private/, which the reset does
# NOT delete (the wipe removes only sites/default/files), so wiring it up is a
# small change; the point of this file is that until somebody does, the answer
# to "did the choices survive?" is no.
: "${DEMO_CLIP_EXPORT_COMMAND:=nwc-clip-choice:export-history}"

# Marker files/commands that would constitute a wired leg. Kept as a list so
# that adding a real leg makes this go green without editing the predicate.
demo_clip_leg_wired() {
    local site="$1"
    local root="${PROJECT_ROOT:?PROJECT_ROOT not set}"
    # A leg is "wired" when the reset path for this site actually invokes the
    # export. Both halves must be true, because either alone is a leg that
    # never runs: the box wrapper is what runs on the box, and the pl
    # orchestrator is what runs the scheduled nightly.
    local wrapper="${root}/servers/live/demo/${site}-demo-reset-restricted"
    local wrapper_ok=false orchestrator_ok=false
    if [[ -f "$wrapper" ]] && grep -q "$DEMO_CLIP_EXPORT_COMMAND" "$wrapper" 2>/dev/null; then
        wrapper_ok=true
    fi
    if grep -rq "$DEMO_CLIP_EXPORT_COMMAND" "${root}/lib/demo.sh" "${root}/scripts/commands/demo.sh" 2>/dev/null; then
        orchestrator_ok=true
    fi
    [[ "$wrapper_ok" == true && "$orchestrator_ok" == true ]]
}

# Is yq usable here? The NWP_DEMO_CLIP_NO_YQ knob exists because CLAUDE.md
# requires the absent-tool path to be TESTABLE ("either fail closed, or add an
# NWP_* knob so the absent-tool path is testable") — an emptied $PATH would
# also take away basename/grep/find and prove nothing about yq.
_demo_clip_have_yq() {
    [[ -n "${NWP_DEMO_CLIP_NO_YQ:-}" ]] && return 1
    command -v yq >/dev/null 2>&1
}

# _demo_clip_pair_get <contract> <yq-path> [default]
#
# One scalar out of a pair contract, read with yq.
#
# WHY NOT awk. The first cut of this function parsed the contract with
#     awk '/^demo:/{d=1} d && /^[[:space:]]+enabled:[[:space:]]*true/{found=1} …'
# and `awk -v k="^provider:" '$0 ~ k {print $2; exit}'`, which lint:yq-first
# caught on !436 (pipeline 2252, job 19405):
#
#     NEW AWK YAML PARSER: lib/demo-clip-survival.sh::demo_site_on_reset_path
#     ERROR: 1 AWK YAML parser(s) introduced. Use yq instead (ADR-0015).
#
# The lint was right about more than style. That awk read `provider: nwd  # note`
# as the value `nwd` only by luck of field splitting, would have taken a quoted
# or flow-mapping value verbatim, and — the one that matters here — matched
# `enabled: true` under ANY nested block once `demo:` had been seen, because its
# reset pattern (`/^[a-z_]+:/`) does not fire on an indented key. A contract with
#     demo:
#       enabled: false
#       smoke:
#         enabled: true
# would have read as demo-enabled and dragged both halves onto the reset path.
#
# Deliberately a local helper and not lib/demo-pair.sh's `demo_pair_get`: this
# file is sourced on its own by tests/unit/test-demo-clip-survival.bats, and it
# must also read the PRIVATE overlay dir, which demo_pair_dir does not cover.
# Same yq idiom, same fail-soft-on-absent-key contract.
_demo_clip_pair_get() {
    local file="$1" path="$2" default="${3:-}" val=""
    if [[ -f "$file" ]]; then
        val="$(yq e "${path} // \"\"" "$file" 2>/dev/null || true)"
        [[ "$val" == "null" ]] && val=""
    fi
    printf '%s\n' "${val:-$default}"
}

# Is this site destroyed by a nightly reset? Read from declared config only.
#
# TRI-STATE, and the third state is the point:
#   0  on the reset path
#   1  not on it
#   2  CANNOT VERIFY — the contracts exist but yq does not, so "not on it"
#      would be a verdict about the toolchain wearing a verdict about the
#      estate. Fail-closed is the estate rule (CLAUDE.md), and this is the
#      host-blind-branch shape it names: without this branch a runner with no
#      yq would report every site safe.
demo_site_on_reset_path() {
    local site="$1"
    local root="${PROJECT_ROOT:?PROJECT_ROOT not set}"
    local cfg="${root}/sites/${site}/.nwp.yml"

    if [[ -f "$cfg" ]] && grep -Eq '^[[:space:]]*class:[[:space:]]*demo[[:space:]]*$' "$cfg"; then
        return 0
    fi

    # Pair contracts: a demo-enabled pair resets BOTH halves as one cut.
    local pc
    for pc in "${root}"/pairs/*.pair-contract.yml "${root}"/private/pairs/*.pair-contract.yml; do
        [[ -f "$pc" ]] || continue
        # Checked HERE, not at the top: a corpus with no contracts at all needs
        # no yq, and refusing there would make the check unrunnable on a tree
        # that has nothing to read.
        _demo_clip_have_yq || return 2
        # Only a contract that opts in (`demo:` block with enabled: true).
        [[ "$(_demo_clip_pair_get "$pc" '.demo.enabled' 'false')" == "true" ]] || continue
        local half name
        for half in provider consumer; do
            name="$(_demo_clip_pair_get "$pc" ".${half}")"
            [[ "$name" == "$site" ]] && return 0
        done
    done
    return 1
}

# Does this site carry clip-review authoring data worth losing?
#
# Read from the site's own tree, not from a list here — a second site that
# grows the module must be covered without anybody remembering to add it.
demo_site_has_clip_authoring() {
    local site="$1"
    local root="${PROJECT_ROOT:?PROJECT_ROOT not set}"
    local d
    for d in "${root}/sites/${site}"/*/; do
        [[ -d "$d" ]] || continue
        if find "$d" -maxdepth 8 -type d -name 'nwc_clip_review' -not -path '*/vendor/*' 2>/dev/null | grep -q .; then
            return 0
        fi
    done
    return 1
}

# demo_clip_survival_report [site...]
#
# Prints one row per site examined and returns the worst verdict seen.
# Is this checkout a LINKED GIT WORKTREE?
#
# In a linked worktree, `.git` is a FILE ("gitdir: …"), not a directory. This
# matters because sites/ is gitignored: a worktree therefore has an EMPTY or
# near-empty sites/ tree while the main checkout has the real estate.
#
# That is a recorded, previously-bitten failure ("worktree pl guards read BLANK
# state"): a guard run from a worktree sees nothing and reports all-clear. Here
# it would print "No site is about to lose an author's clip choices" for the
# exact reason that it could not see any sites — the swallowed-verdict shape
# with a reassuring sentence on top. So it is refused instead.
demo_clip_survival_in_worktree() {
    local root="$1"
    [[ -f "${root}/.git" ]]
}

demo_clip_survival_report() {
    local -a sites=("$@")
    local root="${PROJECT_ROOT:?PROJECT_ROOT not set}"

    # Only when no explicit site was named: naming a site is an explicit claim
    # about what to examine, and the fixtures in the test suite rely on it.
    if [[ ${#sites[@]} -eq 0 ]] && demo_clip_survival_in_worktree "$root"; then
        echo "CANNOT VERIFY: this is a linked git worktree, where sites/ is gitignored and"
        echo "  therefore blank. Scanning it would report 'nothing at risk' because nothing"
        echo "  is visible, not because nothing is exposed. Run from the main checkout, or"
        echo "  set PROJECT_ROOT to it."
        return 2
    fi

    if [[ ${#sites[@]} -eq 0 ]]; then
        # Self-contained scan on purpose. Depending on discover_sites would
        # make this check's verdict differ between a full checkout and a
        # worktree, and a check that answers differently depending on where
        # you stand is not a check.
        local d n
        for d in "${root}/sites"/*/; do
            [[ -d "$d" ]] || continue
            n="$(basename "$d")"
            case "$n" in
                tmp|latest|vendor|*_moodledata) continue ;;
            esac
            sites+=("$n")
        done
    fi
    if [[ ${#sites[@]} -eq 0 ]]; then
        echo "CANNOT VERIFY: no sites discovered — an empty corpus is not a clean bill of health."
        return 2
    fi

    local worst=0 examined=0 at_risk=0
    local site
    for site in "${sites[@]}"; do
        [[ -n "$site" ]] || continue
        [[ -d "${root}/sites/${site}" ]] || continue
        examined=$(( examined + 1 ))

        local path_rc=0
        demo_site_on_reset_path "$site" || path_rc=$?
        if [[ "$path_rc" -eq 2 ]]; then
            # Never collapse "I could not read the contracts" into "safe".
            printf '  %-12s CANNOT VERIFY  pair contracts exist but yq is absent — reset-path membership unknown\n' "$site"
            worst=2
            continue
        fi
        if [[ "$path_rc" -ne 0 ]]; then
            printf '  %-12s OK        not on the nightly reset path\n' "$site"
            continue
        fi
        if ! demo_site_has_clip_authoring "$site"; then
            printf '  %-12s OK        on the reset path, but holds no clip-review data\n' "$site"
            continue
        fi
        if demo_clip_leg_wired "$site"; then
            printf '  %-12s OK        on the reset path, clip-choice pre-wipe leg is wired\n' "$site"
            continue
        fi
        printf '  %-12s AT RISK   nightly reset destroys clip choices — no pre-wipe leg\n' "$site"
        at_risk=$(( at_risk + 1 ))
        # exit 2 DOMINATES exit 1 (CLAUDE.md): a run that could not evaluate
        # every site must not read as a complete verdict just because a later
        # site was decidable.
        [[ "$worst" -eq 2 ]] || worst=1
    done

    if [[ "$examined" -eq 0 ]]; then
        echo "CANNOT VERIFY: no site directories were readable."
        return 2
    fi
    echo
    printf '  examined %d site(s); %d at risk.\n' "$examined" "$at_risk"
    return "$worst"
}
