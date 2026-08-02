#!/usr/bin/env python3
"""pl rag --sync-issues planner — extracted from scripts/commands/rag.sh (ops#230)
so it can be unit-tested (tests/unit/test-oversight-freshness.bats), the same
reason lib/rag-render.py exists. Execution stays in bash; this file is pure:
state + existing issues in, a list of actions out. It performs no I/O beyond
reading its environment and writing JSON to stdout.

Inputs (environment):
  STATE     path to private/rag/state.json
  EXISTING  JSON array of currently-open `rag-auto` issues
  ELIGIBLE  comma-separated list of sites eligible for issue sync
  PID       GitLab project id
  NOW       ISO-8601 timestamp for the note text

THE `continue` BUG THIS FIXES (ops#230 item 4)
----------------------------------------------
This planner used to say:

    r = rows.get(site)
    if not r:   # eligible but absent from this RAG run — leave any issue as-is
        continue

An eligible site that did not appear in the RAG run therefore produced NOTHING:
no action, no note, no line in the dry-run plan. The issue stayed open, still
asserting whatever grade it was last given, and the tracker and reality diverged
in complete silence — the same shape as the outer bug (a stopped oversight that
looks exactly like a healthy one), one level down. A site can drop out of a run
because `pl audit` never scanned it, because it was renamed, because it was
deleted, or because the run itself half-failed; all four are worth knowing and
none of them are "unchanged".

Leaving the issue OPEN is still right — absence is not evidence the site is
clean, and auto-closing on absence would be the worst possible reading. What
changes is that the absence is now RECORDED: an `absent` action always appears
in the plan (so the dry-run and the log show it), and, once per absence streak,
a note is posted on the issue and the marker is stamped `absent=1`. The stamp is
what makes it idempotent — a site absent for thirty nights gets one note, not
thirty. Its return stamps `absent=0` and comments again.
"""
import os, json, re

state = json.load(open(os.environ["STATE"]))
existing = json.loads(os.environ.get("EXISTING") or "[]")
eligible = set(filter(None, os.environ.get("ELIGIBLE", "").split(",")))
pid = os.environ["PID"]
now = os.environ["NOW"]


def site_of(iss):
    for l in iss.get("labels", []):
        if l.startswith("site::"):
            return l[6:]
    return None


def marker(body):
    m = re.search(r'<!-- rag-auto:v1 (.*?) -->', body or "")
    d = {}
    if m:
        for kv in m.group(1).split():
            if "=" in kv:
                k, v = kv.split("=", 1)
                d[k] = v
    return d


bysite = {}
for iss in existing:
    s = site_of(iss)
    if s:
        bysite[s] = iss

rows = {r["site"]: r for r in state.get("sites", [])}
actions = []
for site in sorted(eligible):
    r = rows.get(site)
    iss = bysite.get(site)

    # --- eligible but ABSENT from this RAG run -------------------------------
    if not r:
        if not iss:
            # Nothing open, nothing measured. Say so in the plan; do not invent
            # an issue for a site we have no grade for.
            actions.append({"act": "absent", "summary":
                            "ABSENT %s — eligible but not in this RAG run, and no open rag-auto issue "
                            "(never graded, or dropped out before one was filed)" % site})
            continue
        iid = iss["iid"]
        prev = marker(iss.get("description", ""))
        already = prev.get("absent") == "1"
        actions.append({"act": "absent", "summary":
                        "ABSENT %s — not in this RAG run; #%d left OPEN, grade shown there is STALE%s"
                        % (site, iid, " (already recorded)" if already else "")})
        if already:
            continue
        body = iss.get("description", "") or ""
        mk_old = re.search(r'<!-- rag-auto:v1 (.*?) -->', body)
        if mk_old:
            fields = dict(kv.split("=", 1) for kv in mk_old.group(1).split() if "=" in kv)
            fields["absent"] = "1"
            newmk = "<!-- rag-auto:v1 %s -->" % " ".join("%s=%s" % kv for kv in sorted(fields.items()))
            body = body.replace(mk_old.group(0), newmk, 1)
        else:
            body = ("<!-- rag-auto:v1 site=%s absent=1 -->\n" % site) + body
        actions.append({"act": "update", "summary": "  └ stamp #%d absent=1" % iid,
                        "method": "PUT", "path": "/projects/%s/issues/%d" % (pid, iid),
                        "payload": json.dumps({"description": body})})
        actions.append({"act": "comment", "summary": "  └ record the absence on #%d" % iid,
                        "method": "POST", "path": "/projects/%s/issues/%d/notes" % (pid, iid),
                        "payload": json.dumps({"body":
                            "⚠️ `pl rag --sync-issues` %s: **%s produced no RAG row in this run.** "
                            "This issue is left OPEN and the grade above is now STALE — absence of a "
                            "measurement is not evidence the site is clean. Usual causes: `pl audit` has "
                            "not scanned it, the site was renamed or removed, or the run itself did not "
                            "complete. Check with `pl rag --site %s` and `pl audit %s`."
                            % (now, site, site, site)})})
        continue

    grade = r["rag"]
    sec = int(r.get("security", 0))
    h, m_, l = r.get("todo_high", 0), r.get("todo_med", 0), r.get("todo_low", 0)
    top = (r.get("top", "") or "").strip() or "(no high/med todo item)"
    if grade == "GREEN":
        if iss:
            iid = iss["iid"]
            actions.append({"act": "comment", "summary": "close #%d %s (now GREEN)" % (iid, site),
                            "method": "POST", "path": "/projects/%s/issues/%d/notes" % (pid, iid),
                            "payload": json.dumps({"body": "✅ Cleared by `pl rag` %s — no advisories, no todo items. Auto-closing." % now})})
            actions.append({"act": "close", "summary": "  └ set #%d state=closed" % iid,
                            "method": "PUT", "path": "/projects/%s/issues/%d" % (pid, iid),
                            "payload": json.dumps({"state_event": "close"})})
        continue

    # --- non-green: desired issue content ---
    dot = "\U0001f534 RED" if grade == "RED" else "\U0001f7e0 AMBER"
    mk = "<!-- rag-auto:v1 absent=0 grade=%s sec=%d site=%s -->" % (grade, sec, site)
    body = ("%s\n**RAG: %s** — auto-tracked by `pl rag --sync-issues`.\n\n"
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
            "_Last synced: %s_") % (mk, dot, sec, top, h, m_, l, now)
    title = "[RAG] %s: %s" % (site, "security advisories" if grade == "RED" else "needs attention")
    want = ["rag-auto", "site::%s" % site] + (["priority::high", "security"] if grade == "RED" else ["priority::medium"])
    if not iss:
        actions.append({"act": "create",
                        "summary": "CREATE %s (%s, sec=%d, todo %d/%d/%d)" % (site, grade, sec, h, m_, l),
                        "method": "POST", "path": "/projects/%s/issues" % pid,
                        "payload": json.dumps({"title": title, "description": body, "labels": ",".join(want)})})
        continue
    iid = iss["iid"]
    prev = marker(iss.get("description", ""))
    state_changed = prev.get("grade") != grade or prev.get("sec") != str(sec)
    # A site that was absent and is back is a material change even if the grade
    # is unchanged — the stale-grade warning on the issue has to be retracted.
    returned = prev.get("absent") == "1"
    title_stale = iss.get("title", "") != title   # e.g. red→amber left a stale "security advisories" title
    if not (state_changed or title_stale or returned):
        actions.append({"act": "noop", "summary": "noop  #%d %s (unchanged: %s/%d)" % (iid, site, grade, sec)})
        continue
    cur = set(iss.get("labels", []))
    add = [x for x in want if x not in cur]
    rem = [x for x in (["priority::medium"] if grade == "RED" else ["priority::high", "security"]) if x in cur]
    payload = {"title": title, "description": body}   # title MUST be in the payload so red→amber corrects it
    if add:
        payload["add_labels"] = ",".join(add)
    if rem:
        payload["remove_labels"] = ",".join(rem)
    if returned:
        reason = "back in the run after an absence (%s/%s)" % (grade, sec)
    elif state_changed:
        reason = "%s/%s → %s/%s" % (prev.get("grade", "?"), prev.get("sec", "?"), grade, sec)
    else:
        reason = "title/label refresh"
    actions.append({"act": "update", "summary": "UPDATE #%d %s (%s)" % (iid, site, reason),
                    "method": "PUT", "path": "/projects/%s/issues/%d" % (pid, iid),
                    "payload": json.dumps(payload)})
    if state_changed or returned:   # only comment on a real posture change, not a cosmetic title refresh
        if returned:
            note = ("\U0001f501 `pl rag` %s: **%s is back in the run** — now %s, %d advisor%s, todo %d/%d/%d. "
                    "The stale-grade warning above no longer applies."
                    % (now, site, grade, sec, "y" if sec == 1 else "ies", h, m_, l))
        else:
            note = ("\U0001f504 `pl rag` %s: now %s, %d advisor%s, todo %d/%d/%d (was %s/%s)."
                    % (now, grade, sec, "y" if sec == 1 else "ies", h, m_, l,
                       prev.get("grade", "?"), prev.get("sec", "?")))
        actions.append({"act": "comment", "summary": "  └ comment material change on #%d" % iid,
                        "method": "POST", "path": "/projects/%s/issues/%d/notes" % (pid, iid),
                        "payload": json.dumps({"body": note})})

print(json.dumps(actions))
