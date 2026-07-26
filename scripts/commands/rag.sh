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

Sources: pl audit records ($AUDIT_DIR), pl todo check --json. Exit 3 if any RED.
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

# SELF-LIVENESS BANNER (item 4).
#
# WHY: for 8 nights `pl rag` graded the fleet 12 red / 10 amber / 0 green while
# the machinery that turns those grades into issues was switched off. Every
# component reported success: the rag-sync cron exited 0 ("part disabled —
# skipping"), the agent-loop exited 0 ("globally disabled"), and `pl rag` itself
# printed a perfectly accurate table. Nothing anywhere said the pipeline
# downstream of the table was dark.
#
# An oversight surface that cannot report on its own liveness is asserting more
# than it knows. This banner makes `pl rag` state, every time it runs, whether
# the thing that acts on its output is alive.
_rag_self_banner() {
    local rt="${NWP_ROOT:-$HOME/nwp}"
    local killed="" last_sync="" age="?"

    if [ -f "$PROJECT_ROOT/lib/loop-parts.sh" ]; then
        # shellcheck source=/dev/null
        NWP_ROOT="$rt" source "$PROJECT_ROOT/lib/loop-parts.sh" 2>/dev/null || true
    fi
    if [ -f "$rt/.loop-paused" ]; then
        killed=".loop-paused"
    elif command -v loop_part_raw >/dev/null 2>&1 && [ "$(loop_part_raw all 2>/dev/null)" = "disabled" ]; then
        killed="parts.state all=disabled"
    fi

    local log="$rt/logs/rag-sync.log"
    if [ -f "$log" ]; then
        last_sync=$(grep 'rag-sync done' "$log" 2>/dev/null | tail -1 | awk '{print $1}')
        if [ -n "$last_sync" ]; then
            local e n
            e=$(date -d "$last_sync" +%s 2>/dev/null || echo 0)
            n=$(date +%s)
            [ "$e" != "0" ] && age=$(( (n - e) / 86400 ))
        fi
    fi

    if [ -n "$killed" ]; then
        printf '  %sLOOP ● DARK%s   the self-healing loop is disabled (%s) — this table will NOT become issues.\n' \
            "${RED}" "${NC}" "$killed"
        printf '               re-arm: pl loop enable all   ·   detail: pl loop\n'
    elif [ -z "$last_sync" ]; then
        printf '  %sLOOP ● UNKNOWN%s  rag-sync has never completed a run — grades are not reaching the tracker.\n' \
            "${YELLOW}" "${NC}"
    elif [ "$age" != "?" ] && [ "$age" -ge 7 ]; then
        printf '  %sLOOP ● STALE%s   rag-sync last completed %sd ago (%s) — grades are not reaching the tracker.\n' \
            "${RED}" "${NC}" "$age" "$last_sync"
    elif [ "$age" != "?" ] && [ "$age" -ge 2 ]; then
        printf '  %sLOOP ● AGING%s   rag-sync last completed %sd ago (%s).\n' \
            "${YELLOW}" "${NC}" "$age" "$last_sync"
    else
        printf '  %sLOOP ● live%s    rag-sync last completed %s\n' "${GREEN}" "${NC}" "${last_sync:-?}"
    fi
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

    # Plan the upserts/closes purely from data (python); execution stays in bash.
    local plan
    plan=$(STATE="$state" EXISTING="$existing" ELIGIBLE="$eligible" \
           PID="$PROJECT_ID" NOW="$(date -u +%FT%TZ)" python3 - <<'PY'
import os, json, re
state=json.load(open(os.environ["STATE"]))
existing=json.loads(os.environ["EXISTING"] or "[]")
eligible=set(filter(None, os.environ["ELIGIBLE"].split(",")))
pid=os.environ["PID"]; now=os.environ["NOW"]

def site_of(iss):
    for l in iss.get("labels",[]):
        if l.startswith("site::"): return l[6:]
    return None
def marker(body):
    m=re.search(r'<!-- rag-auto:v1 (.*?) -->', body or "")
    d={}
    if m:
        for kv in m.group(1).split():
            if "=" in kv: k,v=kv.split("=",1); d[k]=v
    return d

bysite={}
for iss in existing:
    s=site_of(iss)
    if s: bysite[s]=iss

rows={r["site"]:r for r in state.get("sites",[])}
actions=[]
for site in sorted(eligible):
    r=rows.get(site)
    if not r:   # eligible but absent from this RAG run — leave any issue as-is
        continue
    grade=r["rag"]; sec=int(r.get("security",0)); iss=bysite.get(site)
    h,m_,l=r.get("todo_high",0),r.get("todo_med",0),r.get("todo_low",0)
    top=(r.get("top","") or "").strip() or "(no high/med todo item)"
    if grade=="GREEN":
        if iss:
            iid=iss["iid"]
            actions.append({"act":"comment","summary":f"close #{iid} {site} (now GREEN)",
                "method":"POST","path":f"/projects/{pid}/issues/{iid}/notes",
                "payload":json.dumps({"body":f"✅ Cleared by `pl rag` {now} — no advisories, no todo items. Auto-closing."})})
            actions.append({"act":"close","summary":f"  └ set #{iid} state=closed",
                "method":"PUT","path":f"/projects/{pid}/issues/{iid}",
                "payload":json.dumps({"state_event":"close"})})
        continue
    # --- non-green: desired issue content ---
    dot="\U0001f534 RED" if grade=="RED" else "\U0001f7e0 AMBER"
    mk=f"<!-- rag-auto:v1 site={site} grade={grade} sec={sec} -->"
    body=("%s\n**RAG: %s** — auto-tracked by `pl rag --sync-issues`.\n\n"
          "- Security advisories (composer audit): **%d**\n"
          "- Top todo: %s\n"
          "- Todo (high/med/low): %d/%d/%d\n\n"
          "Opened/updated automatically from `private/rag/state.json`; "
          "**auto-closes** when the site goes \U0001f7e2 green. Triage item for a "
          "human — _not_ `agent-eligible` by default.\n\n"
          "**To hand the fix to the agent-loop** (a deliberate human act — the "
          "A14 gate): confirm the fix is dev-repo-bounded + low-risk, then add "
          "`kind::security-bump` (or `kind::config` / `kind::docs`) plus "
          "`agent-eligible`. The `site::` label routes the MR to that site's "
          "code repo via `scripts/agent-loop/fix-repo-map.json`; merge stays "
          "human.\n\n"
          "_Last synced: %s_") % (mk,dot,sec,top,h,m_,l,now)
    title="[RAG] %s: %s" % (site, "security advisories" if grade=="RED" else "needs attention")
    want = ["rag-auto", f"site::{site}"] + (["priority::high","security"] if grade=="RED" else ["priority::medium"])
    if not iss:
        actions.append({"act":"create","summary":f"CREATE {site} ({grade}, sec={sec}, todo {h}/{m_}/{l})",
            "method":"POST","path":f"/projects/{pid}/issues",
            "payload":json.dumps({"title":title,"description":body,"labels":",".join(want)})})
        continue
    iid=iss["iid"]; prev=marker(iss.get("description",""))
    state_changed = prev.get("grade")!=grade or prev.get("sec")!=str(sec)
    title_stale   = iss.get("title","") != title   # e.g. red→amber left a stale "security advisories" title
    if not (state_changed or title_stale):
        actions.append({"act":"noop","summary":f"noop  #{iid} {site} (unchanged: {grade}/{sec})"})
        continue
    cur=set(iss.get("labels",[]))
    add=[x for x in want if x not in cur]
    rem=[x for x in (["priority::medium"] if grade=="RED" else ["priority::high","security"]) if x in cur]
    payload={"title":title,"description":body}   # title MUST be in the payload so red→amber corrects it
    if add: payload["add_labels"]=",".join(add)
    if rem: payload["remove_labels"]=",".join(rem)
    reason = (f"{prev.get('grade','?')}/{prev.get('sec','?')} → {grade}/{sec}" if state_changed else "title/label refresh")
    actions.append({"act":"update","summary":f"UPDATE #{iid} {site} ({reason})",
        "method":"PUT","path":f"/projects/{pid}/issues/{iid}","payload":json.dumps(payload)})
    if state_changed:   # only comment on a real posture change, not a cosmetic title refresh
        actions.append({"act":"comment","summary":f"  └ comment material change on #{iid}",
            "method":"POST","path":f"/projects/{pid}/issues/{iid}/notes",
            "payload":json.dumps({"body":f"\U0001f504 `pl rag` {now}: now {grade}, {sec} advisor%s, todo {h}/{m_}/{l} (was {prev.get('grade','?')}/{prev.get('sec','?')})." % ("y" if sec==1 else "ies")})})
print(json.dumps(actions))
PY
)
    [ -n "$plan" ] || { print_error "sync planner produced no output"; return 1; }

    local n; n=$("$YQ" e -p=json 'length' - <<<"$plan" 2>/dev/null || echo 0)
    print_header "RAG → nwp/ops issue sync$([ "$execute" = true ] && echo ' (EXECUTE)' || echo ' (dry-run)')"
    print_info "eligible fleet: $eligible"
    if [ "${n:-0}" -eq 0 ]; then print_success "nothing to do — all eligible sites already in sync"; return 0; fi

    local i act summary method path payload writes=0
    for ((i=0; i<n; i++)); do
        act=$("$YQ"     e -p=json ".[$i].act // \"\""     - <<<"$plan")
        summary=$("$YQ" e -p=json ".[$i].summary // \"\"" - <<<"$plan")
        if [ "$act" = "noop" ]; then
            printf '  %s%s%s\n' "${DIM:-}" "$summary" "${NC}"
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
    if [ "$NOTODO" = "true" ]; then
        echo '{"items":[]}' > "$todo_json"
    else
        # pl todo check --json — read-only; tolerate slowness/failure
        if ! timeout 240 "$PROJECT_ROOT/pl" todo check --json > "$todo_json" 2>/dev/null; then
            print_warning "pl todo sweep failed/timed out — grading from audit records only"
            echo '{"items":[]}' > "$todo_json"
        fi
    fi

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

    # When syncing we only need state.json refreshed; ask python for JSON and sink
    # it so the table/JSON doesn't precede the sync plan on stdout.
    local out=/dev/stdout
    if [ "$SYNC" = "true" ]; then JSON=true; out=/dev/null; fi
    [ "$JSON" = "true" ] || { print_header "Fleet RAG — per-site Red/Amber/Green"; _rag_self_banner; }

    local rag_rc=0
    set +e
    { AUDIT_DIR="$AUDIT_DIR" TODO_JSON="$todo_json" STATE_DIR="$STATE_DIR" \
    SITE="$SITE" JSON="$JSON" PHASES="$phases" MATURITIES="$mats" \
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
