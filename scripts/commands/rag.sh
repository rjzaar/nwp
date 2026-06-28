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

AUDIT_DIR="$PROJECT_ROOT/private/update-awareness"
STATE_DIR="$PROJECT_ROOT/private/rag"

show_help() {
    cat << EOF
${BOLD}pl rag${NC} — per-site Red/Amber/Green fleet rollup

${BOLD}USAGE:${NC} pl rag [--site <name>] [--json] [--no-todo]

  --site <name>   one site only
  --json          emit the rollup as JSON (no table)
  --no-todo       skip the (slower) pl todo sweep; use cached audit records only
  -h, --help

🔴 RED   = open security advisory (pl audit) or high-priority security todo
🟠 AMBER = any other todo item (drift/work/uncommitted/...) or stale audit cache
🟢 GREEN = clear

Sources: pl audit records ($AUDIT_DIR), pl todo check --json. Exit 3 if any RED.
EOF
}

main() {
    local SITE="" JSON=false NOTODO=false
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            --site) SITE="${2:-}"; shift 2 ;;
            --json) JSON=true; shift ;;
            --no-todo) NOTODO=true; shift ;;
            *) print_error "Unknown option: $1"; show_help; exit 1 ;;
        esac
    done

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

    [ "$JSON" = "true" ] || print_header "Fleet RAG — per-site Red/Amber/Green"

    AUDIT_DIR="$AUDIT_DIR" TODO_JSON="$todo_json" STATE_DIR="$STATE_DIR" \
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
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
