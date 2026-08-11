#!/bin/bash
set -euo pipefail

################################################################################
# pl rag — per-site Red/Amber/Green fleet rollup  (Session B, oversight)
#
# The single "what needs attention across everything" view. Merges two existing
# signals into ONE per-site grade + a fleet rollup:
#   - security  → `pl audit` records (private/update-awareness/<site>.json)
#   - work/drift→ `pl todo check --json` items, grouped by site
#
# Grade per site:
#   RED   = an open security advisory (audit) OR a high-priority security todo (SEC/TOK)
#   AMBER = any other todo item (drift/work/uncommitted/backup/...), OR audit
#           cache-stale, OR the site was never scanned, OR a check could not run
#   GREEN = we LOOKED and it was clear
#
# GREEN is a positive assertion, not a default. Before item 2 (oversight-honesty)
# a site with no audit record rendered `security: 0` and graded GREEN exactly
# like an audited-clean site — so adding a site to the fleet made the fleet look
# SAFER. Unscanned sites now render `-`, never `0`, and are counted separately.
#
# The rendering core lives in lib/rag-render.py so it can be unit-tested
# (tests/unit/test-rag-unscanned.bats).
#
# Read-only. Writes private/rag/state.json. Exit 3 if any site is RED.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh" 2>/dev/null || true
source "$PROJECT_ROOT/lib/http.sh"            # shared timeout policy + rc-2 "could not tell"
source "$PROJECT_ROOT/lib/gitlab-issues.sh"   # _api_get/_api_send for --sync-issues (ops#6)
source "$PROJECT_ROOT/lib/canonical.sh"       # canonical phases for the PHASE column (ops#33)

AUDIT_DIR="$PROJECT_ROOT/private/update-awareness"
STATE_DIR="$PROJECT_ROOT/private/rag"

show_help() {
    cat << EOF
${BOLD}pl rag${NC} — per-site Red/Amber/Green fleet rollup

${BOLD}USAGE:${NC} pl rag [--site <name>] [--json] [--no-todo]
       pl rag --sync-issues [--execute]

  --site <name>   one site only
  --json          emit the rollup as JSON (no table)
  --no-todo       skip the (slower) pl todo sweep; use cached audit records only
  --sync-issues   upsert one nwp/ops issue per non-green real-fleet site
                  (idempotent via labels rag-auto + site::<name>). DRY-RUN by
                  default — prints the plan; add --execute to write to GitLab.
  --execute       with --sync-issues: actually create/update/close issues
  -h, --help

🔴 RED   = open security advisory (pl audit) or high-priority security todo
🟠 AMBER = any other todo item (drift/work/uncommitted/...), a stale audit cache,
           an UNSCANNED site, or a check that could not run
🟢 GREEN = we looked, and it was clear

SEC column: a number means measured. '-' means UNSCANNED — nothing was measured,
which is NOT the same as zero. TODO column '?N' = N checks could not run.
A site that cannot be scanned can never grade GREEN.

Sources: pl audit records ($AUDIT_DIR), pl todo check --json. Exit 3 if any RED —
including the (global) row, which goes RED when the oversight loop itself has
stopped (ops#230). Schedule state: pl loop schedule status.
EOF
}

# The "real fleet" eligible for issue sync: configured sites (have .nwp.yml, via
# discover_sites) PLUS on-disk sites that carry an audit record but aren't yet
# .nwp.yml-onboarded (e.g. mg) — MINUS CI/test fixtures (verify-test*, bats-*,
# trace-*, *-del…). This is what keeps `pl rag --sync-issues` from opening junk
# issues for ephemeral test sites that leak into the RAG table.
_rag_eligible_sites(){
    {
        discover_sites 2>/dev/null
        local f s
        for f in "$AUDIT_DIR"/*.json; do
            [ -e "$f" ] || continue
            s=$(basename "$f" .json)
            [ -d "$PROJECT_ROOT/sites/$s" ] && printf '%s\n' "$s"
        done
    } | sort -u | while read -r s; do
        # Skip special pseudo-sites + fixture debris. is_fixture_sitename (lib/common.sh,
        # ops#37) is the shared canonical fixture-prefix list; the pseudo-sites stay inline.
        case "$s" in tmp|latest|'(global)') continue ;; esac
        if command -v is_fixture_sitename >/dev/null 2>&1; then
            is_fixture_sitename "$s" && continue
        else
            case "$s" in verify-test*|bats-test*|trace-*|*-del|*-del[0-9]*|*delete*) continue ;; esac
        fi
        printf '%s\n' "$s"
    done
}

# SELF-LIVENESS BANNER (item 4; rewired for ops#230).
#
# WHY: for 8 nights `pl rag` graded the fleet 12 red / 10 amber / 0 green while
# the machinery that turns those grades into issues was switched off. Every
# component reported success: the rag-sync cron exited 0 ("part disabled —
# skipping"), the agent-loop exited 0 ("globally disabled"), and `pl rag` itself
# printed a perfectly accurate table. Nothing anywhere said the pipeline
# downstream of the table was dark. Then it happened again and ran to 16 nights.
#
# An oversight surface that cannot report on its own liveness is asserting more
# than it knows. This banner makes `pl rag` state, every time it runs, whether
# the thing that acts on its output is alive.
#
# ops#230 changed two things. (1) The probe is no longer inline here: it is
# lib/oversight-freshness.sh, shared with `pl todo` and `pl loop`, so the three
# surfaces cannot drift into three different answers. (2) It now also catches
# the case that actually happened second — the part is enabled and unpaused and
# there is simply NO CRON, so nothing will ever wake it. "Not paused" was being
# rendered as "alive".
_rag_self_banner() {
    local rt="${NWP_ROOT:-$HOME/nwp}"

    if [ -f "$PROJECT_ROOT/lib/loop-parts.sh" ]; then
        # shellcheck source=/dev/null
        NWP_ROOT="$rt" source "$PROJECT_ROOT/lib/loop-parts.sh" 2>/dev/null || true
    fi
    if [ ! -f "$PROJECT_ROOT/lib/oversight-freshness.sh" ]; then
        printf '  %sLOOP ● UNKNOWN%s  lib/oversight-freshness.sh is missing — cannot tell whether this table reaches the tracker.\n\n' \
            "${YELLOW}" "${NC}"
        return 0
    fi
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/lib/oversight-freshness.sh"
    NWP_ROOT="$rt" oversight_probe

    local colour="${GREEN}"
    case "$OVERSIGHT_GRADE" in RED) colour="${RED}" ;; AMBER) colour="${YELLOW}" ;; esac
    printf '  %sLOOP ● %-10s%s %s\n' "$colour" "$OVERSIGHT_STATE" "${NC}" "$OVERSIGHT_DETAIL"
    [ "$OVERSIGHT_GRADE" = "GREEN" ] || printf '               fix: %s   ·   detail: pl loop\n' "$OVERSIGHT_ACTION"
    # The grade itself is what makes this load-bearing rather than decorative:
    # pl todo files an RSY item off the same probe, and lib/rag-render.py grades
    # a high RSY item RED, so a dead oversight loop makes `pl rag` exit 3.
    echo ""
}

# pl rag --sync-issues [--execute] — turn the RAG state into tracked nwp/ops
# issues (ops#6 Deliverable 1). Dry-run by default; --execute writes.
cmd_sync_issues(){
    local execute="$1"
    local state="$STATE_DIR/state.json"
    [ -f "$state" ] || { print_error "no $state — run 'pl rag' first"; return 1; }

    local eligible; eligible=$(_rag_eligible_sites | paste -sd, -)
    [ -n "$eligible" ] || { print_warning "no eligible fleet sites found"; return 0; }

    # all currently-open auto-issues (one API call, indexed by site in python)
    local existing; existing=$(_api_get "/projects/$PROJECT_ID/issues?labels=rag-auto&state=opened&per_page=100")
    [ -n "$existing" ] || existing='[]'

    # Plan the upserts/closes purely from data; execution stays in bash. The
    # planner lives in lib/rag-sync-plan.py (ops#230) rather than a heredoc so
    # it can be unit-tested — it is where the "site absent from the run" bug
    # lived, silently, for as long as the file existed.
    local plan
    plan=$(STATE="$state" EXISTING="$existing" ELIGIBLE="$eligible" \
           PID="$PROJECT_ID" NOW="$(date -u +%FT%TZ)" \
           python3 "$PROJECT_ROOT/lib/rag-sync-plan.py")
    [ -n "$plan" ] || { print_error "sync planner produced no output"; return 1; }

    local n; n=$("$YQ" e -p=json 'length' - <<<"$plan" 2>/dev/null || echo 0)
    print_header "RAG → nwp/ops issue sync$([ "$execute" = true ] && echo ' (EXECUTE)' || echo ' (dry-run)')"
    print_info "eligible fleet: $eligible"
    if [ "${n:-0}" -eq 0 ]; then print_success "nothing to do — all eligible sites already in sync"; return 0; fi

    local i act summary method path payload writes=0 absent=0
    for ((i=0; i<n; i++)); do
        act=$("$YQ"     e -p=json ".[$i].act // \"\""     - <<<"$plan")
        summary=$("$YQ" e -p=json ".[$i].summary // \"\"" - <<<"$plan")
        if [ "$act" = "noop" ]; then
            printf '  %s%s%s\n' "${DIM:-}" "$summary" "${NC}"
            continue
        fi
        # `absent` is a REPORT, not a write: an eligible site that produced no
        # RAG row. It carries no method/path, and it prints in execute mode too
        # — the whole point of ops#230 item 4 is that a site dropping out of the
        # run stops being invisible. Any writes that record it (the marker stamp
        # and the note) follow as their own actions.
        if [ "$act" = "absent" ]; then
            printf '  %s%s%s\n' "${YELLOW:-}" "$summary" "${NC}"
            absent=$((absent+1))
            continue
        fi
        if [ "$execute" != true ]; then
            printf '  %s\n' "$summary"
            continue
        fi
        method=$("$YQ"  e -p=json ".[$i].method // \"\""  - <<<"$plan")
        path=$("$YQ"    e -p=json ".[$i].path // \"\""    - <<<"$plan")
        # the planner stored the JSON body as a STRING field; it survives intact here
        payload=$("$YQ" e -p=json ".[$i].payload // \"\"" - <<<"$plan")
        local resp ok; resp=$(_api_send "$method" "$path" "$payload")
        ok=$(printf '%s' "$resp" | "$YQ" e -p=json '(has("id") or has("iid"))' - 2>/dev/null)
        if [ "$ok" = "true" ]; then
            print_success "$summary"; writes=$((writes+1))
        else
            local msg; msg=$(printf '%s' "$resp" | "$YQ" e -p=json '.message // .error // ""' - 2>/dev/null | grep -v '^null$')
            print_error "FAILED: $summary${msg:+ — $msg}"
        fi
    done
    [ "$absent" -gt 0 ] && print_warning "$absent eligible site(s) produced no RAG row in this run — their issues are left OPEN with a STALE grade, and the absence is recorded on each"
    [ "$execute" = true ] && print_success "applied $writes write(s) to nwp/ops" \
        || print_hint "re-run with --execute to apply the $n planned action(s)"
}

main() {
    local SITE="" JSON=false NOTODO=false SYNC=false EXECUTE=false
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            --site) SITE="${2:-}"; shift 2 ;;
            --json) JSON=true; shift ;;
            --no-todo) NOTODO=true; shift ;;
            --sync-issues) SYNC=true; shift ;;
            --execute) EXECUTE=true; shift ;;
            *) print_error "Unknown option: $1"; show_help; exit 1 ;;
        esac
    done
    # --sync-issues always grades the full fleet first (no --site/--json table).
    if [ "$SYNC" = "true" ]; then SITE=""; JSON=false; fi

    mkdir -p "$STATE_DIR"
    local todo_json="$STATE_DIR/.todo.json"

    # THE FALSE-GREEN THIS FIXES.
    #
    # This block used to substitute `{"items":[]}` whenever the todo sweep
    # failed or timed out. An empty item list is not neutral input to
    # lib/rag-render.py — it is the exact shape of "I checked everything and
    # found no work". So every audited-clean site graded GREEN, and a network
    # slow enough to blow the sweep's deadline made the fleet look BETTER than a
    # working one. The rest of this file goes to some length to insist that
    # "GREEN is a positive assertion, not a default", and then the single most
    # likely failure mode handed it a default.
    #
    # Note the deadline is now a policy value, not the flat 240s that made this
    # reachable in the first place: 240s is longer than an operator will wait,
    # so interactively the sweep "succeeded" by keeping them hostage, and in
    # cron it exceeded the */30 publish window.
    #
    # Three states, and the difference between the last two is the whole point:
    #   complete — the sweep ran; its items are the work signal.
    #   failed   — we tried to look and could not. UNKNOWN. Nothing may grade
    #              GREEN off the back of it.
    #   skipped  — the operator said --no-todo. Recorded and shown loudly, but
    #              it is not our place to call a deliberate choice a blind spot.
    local sweep_state="complete" sweep_reason=""
    if [ "$NOTODO" = "true" ]; then
        sweep_state="skipped"
        sweep_reason="--no-todo: the work/drift sweep was not run; grades reflect audit records only"
        echo '{"items":[]}' > "$todo_json"
    else
        local budget
        budget=$([ "$(nwp_http_profile)" = batch ] && echo 180 || echo 45)
        budget="${NWP_RAG_TODO_BUDGET:-$budget}"
        local trc=0
        timeout "$budget" "$PROJECT_ROOT/pl" todo check --json > "$todo_json" 2>/dev/null || trc=$?
        if [ "$trc" != 0 ]; then
            sweep_state="failed"
            if [ "$trc" = "124" ]; then
                sweep_reason="pl todo check did not finish within ${budget}s ($(nwp_http_budget_desc)) — the work/drift signal is UNKNOWN for every site, not empty"
            else
                sweep_reason="pl todo check exited $trc — the work/drift signal is UNKNOWN for every site, not empty"
            fi
            # stderr, not stdout: under --json this warning used to be printed
            # straight into the JSON document, so the one run that most needed a
            # machine consumer to notice was the one it could not parse.
            print_warning "$sweep_reason" >&2
            printf '{"items":[],"sweep_state":"failed","sweep_reason":%s}\n' \
                "$(printf '%s' "$sweep_reason" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
                > "$todo_json"
        fi
    fi
    export RAG_SWEEP_STATE="$sweep_state" RAG_SWEEP_REASON="$sweep_reason"

    # Canonical phases (ops#33) + maturity classes (P67) for the PHASE/MAT
    # columns: "site=value …". Only explicit values are passed; python
    # defaults the rest to (dev)/(inc).
    local phases="" mats="" _ps _pp
    if [ -f "$PROJECT_ROOT/nwp.yml" ] && command -v yaml_get_all_sites >/dev/null 2>&1; then
        while read -r _ps; do
            [ -z "$_ps" ] && continue
            if canonical_phase_is_explicit "$_ps" "$PROJECT_ROOT/nwp.yml"; then
                _pp=$(canonical_get_phase "$_ps" "$PROJECT_ROOT/nwp.yml")
                phases+="${_ps}=${_pp} "
            fi
            if maturity_class_is_explicit "$_ps" "$PROJECT_ROOT/nwp.yml"; then
                _pp=$(maturity_get_class "$_ps" "$PROJECT_ROOT/nwp.yml")
                mats+="${_ps}=${_pp} "
            fi
        done < <(yaml_get_all_sites "$PROJECT_ROOT/nwp.yml" 2>/dev/null)
    fi

    # KNOWN_SITES — what actually exists, so lib/audit-record.py can tell a real
    # site from an ORPHAN audit record (a record whose site was deleted). Both
    # sources count: nwp.yml (configured) AND sites/<name>/ on disk, because rag
    # deliberately shows on-disk-but-unconfigured sites, and orphaning
    # those would be a regression, not a fix.
    #
    # If BOTH enumerations come back empty we pass nothing, which switches the
    # orphan check OFF rather than declaring the whole fleet non-existent — we
    # do not infer absence from our own failure to look.
    local known="" _k
    while read -r _k; do [ -n "$_k" ] && known+="$_k "; done < <(
        { yaml_get_all_sites "$PROJECT_ROOT/nwp.yml" 2>/dev/null || true
          for _d in "$PROJECT_ROOT"/sites/*/; do
              [ -d "$_d" ] && basename "$_d"
          done 2>/dev/null || true
        } | sort -u )

    # When syncing we only need state.json refreshed; ask python for JSON and sink
    # it so the table/JSON doesn't precede the sync plan on stdout.
    local out=/dev/stdout
    if [ "$SYNC" = "true" ]; then JSON=true; out=/dev/null; fi
    [ "$JSON" = "true" ] || { print_header "Fleet RAG — per-site Red/Amber/Green"; _rag_self_banner; }

    local rag_rc=0
    set +e
    { AUDIT_DIR="$AUDIT_DIR" TODO_JSON="$todo_json" STATE_DIR="$STATE_DIR" \
    SWEEP_STATE="$sweep_state" SWEEP_REASON="$sweep_reason" \
    SITE="$SITE" JSON="$JSON" PHASES="$phases" MATURITIES="$mats" KNOWN_SITES="$known" \
    RED="$RED" YEL="$YELLOW" GRN="$GREEN" NC="$NC" BOLD="$BOLD" DIM="${DIM:-}" \
    python3 "$PROJECT_ROOT/lib/rag-render.py"
    } > "$out"
    rag_rc=$?
    set -e

    if [ "$SYNC" = "true" ]; then
        local mode=false; [ "$EXECUTE" = "true" ] && mode=true
        cmd_sync_issues "$mode"
    fi
    exit "$rag_rc"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
