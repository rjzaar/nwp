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
import os, sys, json, glob
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib
# lib/audit-record.py — the SHARED interpreter for pl audit records (ops#178).
# `pl todo`'s check_security_updates reads the same module, so the two oversight
# surfaces cannot disagree about what a record asserts.
audit_record = importlib.import_module("audit-record")

audit_dir=os.environ["AUDIT_DIR"]; state_dir=os.environ["STATE_DIR"]
site_filter=os.environ.get("SITE",""); as_json=os.environ.get("JSON")=="true"
RED,YEL,GRN,NC,BOLD=(os.environ[k] for k in ("RED","YEL","GRN","NC","BOLD"))

# canonical phases (ops#33) + maturity classes (P67): explicit pairs; absent = defaults
phases=dict(kv.split("=",1) for kv in os.environ.get("PHASES","").split() if "=" in kv)
mats=dict(kv.split("=",1) for kv in os.environ.get("MATURITIES","").split() if "=" in kv)
MAT_ABBR={"incubating":"inc","stabilizing":"stab","production":"prod"}

# --- security signal from pl audit records ---
# Interpretation (the `scanned` inference for pre-`scanned` records, the
# unreadable-record blind spot, and the bogus-Moodle-version guard) lives in
# lib/audit-record.py so `pl todo` grades the identical records identically.
#
# KNOWN_SITES (space-separated) is what lets an ORPHAN record be told from a
# real one — see audit_record.load_dir. Empty/absent disables the check rather
# than orphaning the fleet, because "the caller could not enumerate the sites"
# must not render as "none of these sites exist".
_known = os.environ.get("KNOWN_SITES", "").split()
known_sites = set(_known) if _known else None
sec = {s: {k: r.get(k) for k in ("count", "ignored", "stale", "scanned", "reason",
                                 "retired", "retired_reason", "orphan")}
       for s, r in audit_record.load_dir(audit_dir, known_sites=known_sites).items()}

# --- work signal from pl todo ---
# A TODO_JSON we cannot parse is a BLIND SWEEP, not an empty one (ops#178).
# This used to be `except Exception: todo={"items":[]}`: ANY malformed document
# — a producer bug, a truncated write, a disk-full — silently became "swept,
# found nothing", and every site could then grade GREEN. Unlike the sweep
# timeout, which announced itself in a banner, this failure mode was completely
# quiet, so it is the more dangerous of the two. Defence in depth: the producer
# is also being fixed to emit escaped JSON, but rag must not be the component
# that converts someone else's bug into a clean bill of health.
todo_unreadable = ""
try:
    todo = json.load(open(os.environ["TODO_JSON"]))
except Exception as e:
    todo = {"items": []}
    todo_unreadable = "pl todo emitted unparseable JSON (%s)" % e
items = todo if isinstance(todo,list) else todo.get("items",[])

# Did the work sweep actually happen?
#
# `items == []` is ambiguous and the ambiguity was load-bearing: it is the shape
# of "swept, nothing found" AND the shape of "the sweep timed out and rag.sh
# substituted an empty list". The first should grade GREEN; the second must
# never. A slow network therefore made the fleet render greener than a healthy
# one — the same inversion item 2 fixed for unscanned sites, one signal over.
#
#   complete -> believe the items
#   failed   -> we tried to look and could not. Every site is UNKNOWN on the
#               work axis; none may grade GREEN.
#   skipped  -> the operator passed --no-todo. Shown, but not treated as a
#               blind spot: it is an answer to a question they chose not to ask.
sweep_state=os.environ.get("SWEEP_STATE","complete") or "complete"
sweep_reason=os.environ.get("SWEEP_REASON","") or ""
if isinstance(todo,dict) and todo.get("sweep_state"):
    sweep_state=todo["sweep_state"]
    sweep_reason=todo.get("sweep_reason","") or sweep_reason
if todo_unreadable:
    sweep_state = "failed"
    sweep_reason = (sweep_reason + " | " if sweep_reason else "") + todo_unreadable
sweep_failed = (sweep_state == "failed")
work=defaultdict(lambda: {"high":0,"med":0,"low":0,"sec_high":0,"ovr_high":0,"unknown":0,"top":""})
SEC_CATS={"SEC","TOK"}
# ops#230 — OVERSIGHT LIVENESS IS A RED-GRADE SIGNAL, not ordinary work.
#
# `pl todo`'s check_rag_sync_freshness files an RSY item when the machinery that
# turns this table into tracked issues has stopped. Before this line that item
# graded like any other todo: AMBER, one row among twenty, on the `(global)`
# pseudo-site. So for 16 nights the estate's oversight was dead and the oversight
# surface rendered it as a mild amber. A high-priority RSY item now grades RED
# and therefore makes `pl rag` exit 3 — "the watchman has stopped" must be at
# least as loud as "a site has an advisory".
OVERSIGHT_CATS={"RSY"}
for it in items:
    s=it.get("site") or "(global)"
    p=(it.get("priority") or "").lower()
    c=(it.get("category") or "").upper()
    w=work[s]
    if p=="high": w["high"]+=1
    elif p=="medium": w["med"]+=1
    else: w["low"]+=1
    if c in SEC_CATS and p=="high": w["sec_high"]+=1
    if c in OVERSIGHT_CATS and p=="high": w["ovr_high"]+=1
    # UNK items are checks that could not run (unreachable host, missing tool).
    # They are not findings — they are the absence of a finding we cannot vouch
    # for, and they must stop a site grading GREEN.
    if it.get("unknown") is True or c=="UNK" or str(it.get("id","")).startswith("UNK-"):
        w["unknown"]+=1
    if not w["top"] and p in ("high","medium"):
        w["top"]=(it.get("title") or it.get("description") or "")[:46]

sites=set(sec)|set(work)
if site_filter: sites={site_filter}

# A failed sweep is a blind spot on EVERY site, including the ones that produced
# no items precisely because nothing ran. Charge each of them one unknown so
# grade() cannot reach GREEN.
if sweep_failed:
    for s in sites:
        w=work[s]                      # defaultdict: also creates absent sites
        w["unknown"]+=1
        if not w["top"]: w["top"]="work sweep did not run — UNKNOWN"

def is_scanned(s):
    # No audit record at all == never scanned. This is the case that made adding
    # a site to the fleet improve the fleet's apparent health.
    if s not in sec: return False
    return bool(sec[s].get("scanned", False))

def is_retired(s): return bool(sec.get(s,{}).get("retired"))
def is_orphan(s):  return bool(sec.get(s,{}).get("orphan"))

def grade(s):
    sc=sec.get(s,{}); wk=work.get(s,{})
    # RETIRED and ORPHAN are answers to a DIFFERENT question than R/A/G. R/A/G
    # asks "how healthy is this site"; these two say "this is not a site we are
    # grading" — one by decision, one because it does not exist. Folding either
    # into RED (today) or GREEN (the tempting alternative) makes the fleet line
    # a worse instrument: RED-forever rows train the reader to ignore red, and a
    # green one would let deletion masquerade as remediation.
    if is_retired(s): return "RETIRED"
    if is_orphan(s):  return "ORPHAN"
    secn=sc.get("count",0); sech=wk.get("sec_high",0); ovr=wk.get("ovr_high",0)
    if secn>0 or sech>0 or ovr>0: return "RED"
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
        "retired":sc.get("retired","") or "",
        "retired_reason":sc.get("retired_reason","") or "",
        "orphan":bool(sc.get("orphan")),
        "unknown":wk.get("unknown",0),
        "todo_high":wk.get("high",0),"todo_med":wk.get("med",0),"todo_low":wk.get("low",0),
        "top":wk.get("top","")})

counts={"RED":0,"AMBER":0,"GREEN":0,"RETIRED":0,"ORPHAN":0}
for r in rows: counts[r["rag"]]+=1
# UNSCANNED is a separate axis from R/A/G: it says how much of the AMBER is
# "we found work" versus "we cannot see". rag-sync files these as their own
# issue class so a permanently-blind site cannot sit quietly in the amber pile.
#
# A RETIRED or ORPHAN site is NOT unscanned. "Unscanned" is a blind spot — we
# tried to look and could not, and somebody should fix the looking. Here we
# looked at the question and answered it: there is nothing to scan. Counting
# them as blind spots would inflate exactly the number that is supposed to
# measure how much of the estate we cannot see.
counts["UNSCANNED"]=sum(1 for r in rows
                        if not r["scanned"] and not r["retired"] and not r["orphan"])
state={"generated":todo.get("timestamp") if isinstance(todo,dict) else None,
       "summary":counts,
       # A consumer (the console, pl fleet publish, rag-sync) must be able to
       # tell a green fleet from a fleet we could not measure. Publishing the
       # grades without publishing how they were obtained is what let a silent
       # sweep failure read as good news downstream.
       "todo_sweep":{"state":sweep_state,"reason":sweep_reason},
       "unscanned":[{"site":r["site"],"reason":r["unscanned_reason"]}
                    for r in rows if not r["scanned"] and not r["retired"] and not r["orphan"]],
       "retired":[{"site":r["site"],"retired":r["retired"],"reason":r["retired_reason"]}
                  for r in rows if r["retired"]],
       # Named, not just counted: an orphan is a piece of debris somebody has to
       # delete, and a number nobody can act on is how it survived for weeks.
       "orphans":[{"site":r["site"],"reason":r["unscanned_reason"]} for r in rows if r["orphan"]],
       "sites":rows}
json.dump(state, open(os.path.join(state_dir,"state.json"),"w"), indent=2)

if as_json:
    print(json.dumps(state, indent=2))
else:
    DIM=os.environ.get("DIM","")
    dot={"RED":RED+"●"+NC,"AMBER":YEL+"●"+NC,"GREEN":GRN+"●"+NC,
         # Deliberately not a traffic-light colour: these rows are not a grade.
         "RETIRED":DIM+"·"+NC,"ORPHAN":DIM+"·"+NC}
    if sweep_state=="failed":
        print(f"  {RED}TODO ● BLIND{NC}   {sweep_reason}")
        print( "                every site below is graded on its audit record ALONE.\n")
    elif sweep_state=="skipped":
        print(f"  {YEL}TODO ● skipped{NC} {sweep_reason}\n")
    print(f"\n  {'':2} {'SITE':<16} {'PHASE':<7} {'MAT':<6} {'SEC':>4} {'TODO(h/m/l)':>12}  TOP")
    _ORDER={"RED":0,"AMBER":1,"GREEN":2,"RETIRED":3,"ORPHAN":4}
    for r in sorted(rows, key=lambda x:_ORDER[x["rag"]]):
        if r["scanned"]:
            sec_s=str(r["security"]) + (f"+{r['ignored']}i" if r["ignored"] else "")
        else:
            sec_s="-"   # never "0": nothing was measured
        td=f"{r['todo_high']}/{r['todo_med']}/{r['todo_low']}"
        if r["unknown"]: td+=f" ?{r['unknown']}"
        if r["retired"]:
            # The date is the whole point: a retirement is a dated claim about
            # the world, so it can be checked against the world later.
            top=f"RETIRED {r['retired']}" + (f" — {r['retired_reason'][:40]}" if r["retired_reason"] else "")
        elif r["orphan"]:
            top="ORPHAN: "+r["unscanned_reason"][:52]
        else:
            top=r["top"] or ("" if r["scanned"] else "UNSCANNED: "+r["unscanned_reason"][:40])
        print(f"  {dot[r['rag']]}  {r['site']:<16} {r['phase']:<7} {r['maturity']:<6} {sec_s:>4} {td:>12}  {top}")
    unsc=counts["UNSCANNED"]
    graded=len(rows)-counts["RETIRED"]-counts["ORPHAN"]
    extra=""
    if counts["RETIRED"]: extra+=f", {counts['RETIRED']} retired"
    if counts["ORPHAN"]:  extra+=f", {counts['ORPHAN']} orphan"
    print(f"\n  {BOLD}Fleet:{NC} {RED}● {counts['RED']} red{NC}  {YEL}● {counts['AMBER']} amber{NC}  {GRN}● {counts['GREEN']} green{NC}"
          f"   ({graded} graded sites, {unsc} unscanned{extra})   legend: SEC -=unscanned, +Ni=ignored, ?N=checks that could not run")
    if counts["ORPHAN"]:
        print(f"  {YEL}{counts['ORPHAN']} audit record(s) name a site that does not exist — CANNOT VERIFY, not clean and not red:{NC}")
        for r in rows:
            if r["orphan"]:
                print(f"    - {r['site']}: {r['unscanned_reason']}")
    if unsc:
        print(f"  {YEL}{unsc} site(s) could not be scanned — a blank SEC column is not a clean one:{NC}")
        for r in rows:
            # Same predicate as the count above. They were briefly different —
            # the count said 8 and the list printed 12 — which is the identical
            # class of defect this whole change is about: a summary number that
            # does not describe the thing listed under it.
            if not r["scanned"] and not r["retired"] and not r["orphan"]:
                print(f"    - {r['site']}: {r['unscanned_reason']}")
    print(f"  state → {os.path.join(state_dir,'state.json')}")

import sys
sys.exit(3 if counts["RED"]>0 else 0)
