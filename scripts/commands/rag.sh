#!/bin/bash
set -euo pipefail

################################################################################
# pl rag — per-site Red/Amber/Green fleet rollup  (Session B, oversight)
#
# The single "what needs attention across everything" view. Merges two existing
# signals into ONE per-site grade + a fleet rollup:
#   - security  → `pl audit` records (private/update-awareness/<site>.json)
#   - work/drift→ `pl todo check --json` items (14 checks, grouped by site)
#
# Grade per site:
#   RED   = an open security advisory (audit) OR a high-priority security todo (SEC/TOK)
#   AMBER = any other todo item (drift/work/uncommitted/backup/...) OR audit cache-stale
#   GREEN = no advisories and no todo items
#
# Read-only. Writes private/rag/state.json. Exit 3 if any site is RED.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh" 2>/dev/null || true
source "$PROJECT_ROOT/lib/gitlab-issues.sh"   # _api_get/_api_send for --sync-issues (ops#6)

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
🟠 AMBER = any other todo item (drift/work/uncommitted/...) or stale audit cache
🟢 GREEN = clear

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
        case "$s" in
            verify-test*|bats-test*|trace-*|*-del|*-del[0-9]*|*delete*|tmp|latest|'(global)') continue ;;
        esac
        printf '%s\n' "$s"
    done
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
          "human — _not_ `agent-eligible` (see nwp/ops#6 Deliverable 2).\n\n"
          "_Last synced: %s_") % (mk,dot,sec,top,h,m_,l,now)
    title="[RAG] %s: %s" % (site, "security advisories" if grade=="RED" else "needs attention")
    want = ["rag-auto", f"site::{site}"] + (["priority::high","security"] if grade=="RED" else ["priority::medium"])
    if not iss:
        actions.append({"act":"create","summary":f"CREATE {site} ({grade}, sec={sec}, todo {h}/{m_}/{l})",
            "method":"POST","path":f"/projects/{pid}/issues",
            "payload":json.dumps({"title":title,"description":body,"labels":",".join(want)})})
        continue
    iid=iss["iid"]; prev=marker(iss.get("description",""))
    changed = prev.get("grade")!=grade or prev.get("sec")!=str(sec)
    if not changed:
        actions.append({"act":"noop","summary":f"noop  #{iid} {site} (unchanged: {grade}/{sec})"})
        continue
    cur=set(iss.get("labels",[]))
    add=[x for x in want if x not in cur]
    rem=[x for x in (["priority::medium"] if grade=="RED" else ["priority::high","security"]) if x in cur]
    payload={"description":body}
    if add: payload["add_labels"]=",".join(add)
    if rem: payload["remove_labels"]=",".join(rem)
    actions.append({"act":"update","summary":f"UPDATE #{iid} {site} ({prev.get('grade','?')}/{prev.get('sec','?')} → {grade}/{sec})",
        "method":"PUT","path":f"/projects/{pid}/issues/{iid}","payload":json.dumps(payload)})
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

    # When syncing we only need state.json refreshed; ask python for JSON and sink
    # it so the table/JSON doesn't precede the sync plan on stdout.
    local out=/dev/stdout
    if [ "$SYNC" = "true" ]; then JSON=true; out=/dev/null; fi
    [ "$JSON" = "true" ] || print_header "Fleet RAG — per-site Red/Amber/Green"

    local rag_rc=0
    set +e
    { AUDIT_DIR="$AUDIT_DIR" TODO_JSON="$todo_json" STATE_DIR="$STATE_DIR" \
    SITE="$SITE" JSON="$JSON" \
    RED="$RED" YEL="$YELLOW" GRN="$GREEN" NC="$NC" BOLD="$BOLD" DIM="${DIM:-}" \
    python3 - <<'PY'
import os, json, glob
from collections import defaultdict

audit_dir=os.environ["AUDIT_DIR"]; state_dir=os.environ["STATE_DIR"]
site_filter=os.environ.get("SITE",""); as_json=os.environ.get("JSON")=="true"
RED,YEL,GRN,NC,BOLD=(os.environ[k] for k in ("RED","YEL","GRN","NC","BOLD"))

# --- security signal from pl audit records ---
sec={}  # site -> {count, stale}
for f in glob.glob(os.path.join(audit_dir,"*.json")):
    try: d=json.load(open(f))
    except Exception: continue
    s=d.get("site") or os.path.basename(f)[:-5]
    sec[s]={"count":int(d.get("security_count",0) or 0),
            "ignored":int(d.get("ignored_count",0) or 0),
            "stale":bool(d.get("cache_stale",False))}

# --- work signal from pl todo ---
try: todo=json.load(open(os.environ["TODO_JSON"]))
except Exception: todo={"items":[]}
items = todo if isinstance(todo,list) else todo.get("items",[])
work=defaultdict(lambda: {"high":0,"med":0,"low":0,"sec_high":0,"top":""})
SEC_CATS={"SEC","TOK"}
for it in items:
    s=it.get("site") or "(global)"
    p=(it.get("priority") or "").lower()
    c=(it.get("category") or "").upper()
    w=work[s]
    if p=="high": w["high"]+=1
    elif p=="medium": w["med"]+=1
    else: w["low"]+=1
    if c in SEC_CATS and p=="high": w["sec_high"]+=1
    if not w["top"] and p in ("high","medium"):
        w["top"]=(it.get("title") or it.get("description") or "")[:46]

sites=set(sec)|set(work)
if site_filter: sites={site_filter}
def grade(s):
    sc=sec.get(s,{}); wk=work.get(s,{})
    secn=sc.get("count",0); sech=wk.get("sec_high",0)
    if secn>0 or sech>0: return "RED"
    if (wk.get("high",0)+wk.get("med",0)+wk.get("low",0))>0 or sc.get("stale"): return "AMBER"
    return "GREEN"

rows=[]
for s in sorted(sites):
    g=grade(s); sc=sec.get(s,{}); wk=work.get(s,{})
    rows.append({"site":s,"rag":g,
        "security":sc.get("count",0),"ignored":sc.get("ignored",0),"stale":sc.get("stale",False),
        "todo_high":wk.get("high",0),"todo_med":wk.get("med",0),"todo_low":wk.get("low",0),
        "top":wk.get("top","")})

counts={"RED":0,"AMBER":0,"GREEN":0}
for r in rows: counts[r["rag"]]+=1
state={"generated":todo.get("timestamp") if isinstance(todo,dict) else None,
       "summary":counts,"sites":rows}
json.dump(state, open(os.path.join(state_dir,"state.json"),"w"), indent=2)

if as_json:
    print(json.dumps(state, indent=2))
else:
    dot={"RED":RED+"●"+NC,"AMBER":YEL+"●"+NC,"GREEN":GRN+"●"+NC}
    print(f"\n  {'':2} {'SITE':<16} {'SEC':>4} {'TODO(h/m/l)':>12}  TOP")
    for r in sorted(rows, key=lambda x:{"RED":0,"AMBER":1,"GREEN":2}[x["rag"]]):
        sec_s=str(r["security"]) + (f"+{r['ignored']}i" if r["ignored"] else "") + ("*" if r["stale"] else "")
        td=f"{r['todo_high']}/{r['todo_med']}/{r['todo_low']}"
        print(f"  {dot[r['rag']]}  {r['site']:<16} {sec_s:>4} {td:>12}  {r['top']}")
    print(f"\n  {BOLD}Fleet:{NC} {RED}● {counts['RED']} red{NC}  {YEL}● {counts['AMBER']} amber{NC}  {GRN}● {counts['GREEN']} green{NC}"
          f"   ({len(rows)} sites)   legend: SEC *=cache-stale, +Ni=ignored")
    print(f"  state → {os.path.join(state_dir,'state.json')}")

import sys
sys.exit(3 if counts["RED"]>0 else 0)
PY
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
