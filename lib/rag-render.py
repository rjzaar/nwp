#!/usr/bin/env python3
"""pl rag rendering core — extracted from scripts/commands/rag.sh so it can be
unit-tested (tests/unit/test-rag-unscanned.bats).

Inputs are environment variables (AUDIT_DIR, TODO_JSON, STATE_DIR, SITE, JSON,
PHASES, MATURITIES, RED/YEL/GRN/NC/BOLD); it writes $STATE_DIR/state.json and
exits 3 if any site is RED.

Item 2 (oversight-honesty) added the UNSCANNED state. Before it, a site with no
audit record — or an audit record that says "I could not scan you" — rendered
`security: 0` and graded GREEN, identical to an audited-clean site. Adding a
site to the fleet made the fleet look SAFER. `0` now only ever means "measured,
and it was zero"; anything unmeasured renders `-`, grades AMBER at best, and is
counted separately in the fleet line so the operator can see the size of the
blind spot.
"""
import os, json, glob
from collections import defaultdict

audit_dir=os.environ["AUDIT_DIR"]; state_dir=os.environ["STATE_DIR"]
site_filter=os.environ.get("SITE",""); as_json=os.environ.get("JSON")=="true"
RED,YEL,GRN,NC,BOLD=(os.environ[k] for k in ("RED","YEL","GRN","NC","BOLD"))

# canonical phases (ops#33) + maturity classes (P67): explicit pairs; absent = defaults
phases=dict(kv.split("=",1) for kv in os.environ.get("PHASES","").split() if "=" in kv)
mats=dict(kv.split("=",1) for kv in os.environ.get("MATURITIES","").split() if "=" in kv)
MAT_ABBR={"incubating":"inc","stabilizing":"stab","production":"prod"}

# --- security signal from pl audit records ---
# `scanned` is written by pl audit. Records predating it are inferred from
# cache_stale, which had the same meaning for the composer leg; a record with
# neither key is assumed scanned so historical records don't all flip amber at
# once, but a record whose reason we can see is honoured.
sec={}  # site -> {count, ignored, stale, scanned, reason}
for f in glob.glob(os.path.join(audit_dir,"*.json")):
    try: d=json.load(open(f))
    except Exception:
        # An unreadable record is a blind spot, not an absent site.
        s=os.path.basename(f)[:-5]
        sec[s]={"count":0,"ignored":0,"stale":True,"scanned":False,
                "reason":"audit record is unreadable/corrupt"}
        continue
    s=d.get("site") or os.path.basename(f)[:-5]
    stale=bool(d.get("cache_stale",False))
    scanned=d.get("scanned")
    if scanned is None:
        scanned = not stale
    reason=d.get("stale_reason","") or ""

    # SELF-EVIDENTLY BOGUS RECORD. `pl audit`'s Moodle leg had a greedy-sed bug
    # that parsed BOTH the installed and the upstream $version to the literal
    # string "branchingdateYYYYMMDD-donotmodify!", so `behind` was arithmetically
    # always 0 and every Moodle site recorded security_count: 0. Those records
    # are still on disk and would keep grading GREEN until the next audit run.
    # A record that carries the evidence of its own invalidity must not be
    # believed: if a Moodle record's version fields are not numeric, no
    # comparison happened, whatever the record claims.
    if d.get("platform") == "moodle":
        def _numeric(v):
            try: float(str(v)); return True
            except Exception: return False
        iv, lv = d.get("moodle_installed_version"), d.get("moodle_latest_version")
        if not (_numeric(iv) and _numeric(lv)):
            scanned = False; stale = True
            reason = ("Moodle version fields are unparseable (installed=%r latest=%r) — "
                      "no version comparison happened, so security_count 0 is meaningless. "
                      "Re-run: pl audit --site %s" % (iv, lv, s))

    sec[s]={"count":int(d.get("security_count",0) or 0),
            "ignored":int(d.get("ignored_count",0) or 0),
            "stale":stale,
            "scanned":bool(scanned),
            "reason":reason}

# --- work signal from pl todo ---
try: todo=json.load(open(os.environ["TODO_JSON"]))
except Exception: todo={"items":[]}
items = todo if isinstance(todo,list) else todo.get("items",[])
work=defaultdict(lambda: {"high":0,"med":0,"low":0,"sec_high":0,"unknown":0,"top":""})
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
    # UNK items are checks that could not run (unreachable host, missing tool).
    # They are not findings — they are the absence of a finding we cannot vouch
    # for, and they must stop a site grading GREEN.
    if it.get("unknown") is True or c=="UNK" or str(it.get("id","")).startswith("UNK-"):
        w["unknown"]+=1
    if not w["top"] and p in ("high","medium"):
        w["top"]=(it.get("title") or it.get("description") or "")[:46]

sites=set(sec)|set(work)
if site_filter: sites={site_filter}

def is_scanned(s):
    # No audit record at all == never scanned. This is the case that made adding
    # a site to the fleet improve the fleet's apparent health.
    if s not in sec: return False
    return bool(sec[s].get("scanned", False))

def grade(s):
    sc=sec.get(s,{}); wk=work.get(s,{})
    secn=sc.get("count",0); sech=wk.get("sec_high",0)
    if secn>0 or sech>0: return "RED"
    if (wk.get("high",0)+wk.get("med",0)+wk.get("low",0))>0 or sc.get("stale"): return "AMBER"
    # GREEN is a positive assertion ("I looked, it was clear"). We may only make
    # it about a site we actually scanned and whose checks all completed.
    if not is_scanned(s) or wk.get("unknown",0)>0: return "AMBER"
    return "GREEN"

def unscanned_reason(s):
    if s not in sec: return "no pl audit record — this site has never been audited"
    return sec[s].get("reason","") or "pl audit could not complete a scan"

rows=[]
for s in sorted(sites):
    g=grade(s); sc=sec.get(s,{}); wk=work.get(s,{}); scanned=is_scanned(s)
    rows.append({"site":s,"rag":g,"phase":phases.get(s,"(dev)"),
        "maturity":MAT_ABBR.get(mats.get(s,""),"(inc)") if mats.get(s) else "(inc)",
        # security stays numeric for consumers, but `scanned` is what says
        # whether the number means anything. Render from `scanned`, not `security`.
        "security":sc.get("count",0),"ignored":sc.get("ignored",0),"stale":sc.get("stale",False),
        "scanned":scanned,
        "unscanned_reason":("" if scanned else unscanned_reason(s)),
        "unknown":wk.get("unknown",0),
        "todo_high":wk.get("high",0),"todo_med":wk.get("med",0),"todo_low":wk.get("low",0),
        "top":wk.get("top","")})

counts={"RED":0,"AMBER":0,"GREEN":0}
for r in rows: counts[r["rag"]]+=1
# UNSCANNED is a separate axis from R/A/G: it says how much of the AMBER is
# "we found work" versus "we cannot see". rag-sync files these as their own
# issue class so a permanently-blind site cannot sit quietly in the amber pile.
counts["UNSCANNED"]=sum(1 for r in rows if not r["scanned"])
state={"generated":todo.get("timestamp") if isinstance(todo,dict) else None,
       "summary":counts,
       "unscanned":[{"site":r["site"],"reason":r["unscanned_reason"]} for r in rows if not r["scanned"]],
       "sites":rows}
json.dump(state, open(os.path.join(state_dir,"state.json"),"w"), indent=2)

if as_json:
    print(json.dumps(state, indent=2))
else:
    dot={"RED":RED+"●"+NC,"AMBER":YEL+"●"+NC,"GREEN":GRN+"●"+NC}
    print(f"\n  {'':2} {'SITE':<16} {'PHASE':<7} {'MAT':<6} {'SEC':>4} {'TODO(h/m/l)':>12}  TOP")
    for r in sorted(rows, key=lambda x:{"RED":0,"AMBER":1,"GREEN":2}[x["rag"]]):
        if r["scanned"]:
            sec_s=str(r["security"]) + (f"+{r['ignored']}i" if r["ignored"] else "")
        else:
            sec_s="-"   # never "0": nothing was measured
        td=f"{r['todo_high']}/{r['todo_med']}/{r['todo_low']}"
        if r["unknown"]: td+=f" ?{r['unknown']}"
        top=r["top"] or ("" if r["scanned"] else "UNSCANNED: "+r["unscanned_reason"][:40])
        print(f"  {dot[r['rag']]}  {r['site']:<16} {r['phase']:<7} {r['maturity']:<6} {sec_s:>4} {td:>12}  {top}")
    unsc=counts["UNSCANNED"]
    print(f"\n  {BOLD}Fleet:{NC} {RED}● {counts['RED']} red{NC}  {YEL}● {counts['AMBER']} amber{NC}  {GRN}● {counts['GREEN']} green{NC}"
          f"   ({len(rows)} sites, {unsc} unscanned)   legend: SEC -=unscanned, +Ni=ignored, ?N=checks that could not run")
    if unsc:
        print(f"  {YEL}{unsc} site(s) could not be scanned — a blank SEC column is not a clean one:{NC}")
        for r in rows:
            if not r["scanned"]:
                print(f"    - {r['site']}: {r['unscanned_reason']}")
    print(f"  state → {os.path.join(state_dir,'state.json')}")

import sys
sys.exit(3 if counts["RED"]>0 else 0)
