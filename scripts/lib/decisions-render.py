import json, os, re, sys

mode, only_iid, host = sys.argv[1], sys.argv[2], sys.argv[3]
mrs_manifest = sys.argv[4] if len(sys.argv) > 4 else ""
notes_dir = sys.argv[5] if len(sys.argv) > 5 else ""
outside_count = sys.argv[6] if len(sys.argv) > 6 else ""
amber_file = sys.argv[7] if len(sys.argv) > 7 else ""
try:
    issues = json.load(sys.stdin)
except Exception:
    print("CANNOT-VERIFY: the tracker returned nothing readable.", file=sys.stderr)
    sys.exit(1)
if not isinstance(issues, list):
    print("CANNOT-VERIFY: unexpected response from the tracker.", file=sys.stderr)
    sys.exit(1)

# Gate → (rank, heading, why it is ordered here)
GATES = {
    "blocks-testers": (1, "BLOCKS TESTERS", "Phase 1 cannot finish until this is answered"),
    "blocks-prod":    (2, "BLOCKS PROD",    "Phase 2 cannot start"),
    "shapes-design":  (3, "SHAPES DESIGN",  "nothing is stopped, but building first means rework"),
    "housekeeping":   (4, "HOUSEKEEPING",   "real, small, nothing downstream"),
}
DEFAULT_GATE = "shapes-design"

def block(body: str) -> dict | None:
    """Pull the ## Decision block out of an issue body."""
    if not body:
        return None
    m = re.search(r"^##\s+Decision\s*$(.*?)(?=^##\s|\Z)", body, re.M | re.S)
    if not m:
        return None
    text = m.group(1)
    # A FIELD starts at column 0 as **Name:** — NOT one indented behind a list
    # marker. The first version allowed an optional leading "- ", so the option
    # items (which are themselves "- **A. …**") were read as the next field and
    # the Options list always came back EMPTY — silently, and Options is the part
    # the operator most needs.
    FIELD_START = r"(?=^\*\*|\Z)"
    def field(name):
        f = re.search(rf"^\*\*{name}:?\*\*:?\s*(.+?){FIELD_START}", text, re.M | re.S)
        return re.sub(r"\s+", " ", f.group(1)).strip() if f else ""
    opts = []
    om = re.search(rf"^\*\*Options:?\*\*:?(.*?){FIELD_START}", text, re.M | re.S)
    if om:
        for line in om.group(1).splitlines():
            s = line.strip()
            if re.match(r"^([-*]|\d+[.)])\s+", s):
                opts.append(re.sub(r"^([-*]|\d+[.)])\s+", "", s).strip())
    gate = field("Gate").lower().strip() or DEFAULT_GATE
    if gate not in GATES:
        gate = DEFAULT_GATE
    deps = [int(x) for x in re.findall(r"Depends-on:\s*#?(\d+)", text)]
    return {
        "what": field("What"),
        "options": opts,
        "recommend": field("Recommend"),
        "unblocks": field("Unblocks"),
        "gate": gate,
        "depends_on": deps,
    }

rows = []
for i in issues:
    b = block(i.get("description") or "")
    rows.append({
        "iid": i["iid"],
        "title": i["title"],
        "url": i.get("web_url") or f"https://{host}/nwp/ops/-/issues/{i['iid']}",
        "labels": i.get("labels", []),
        "complete": b is not None,
        **(b or {"gate": DEFAULT_GATE, "depends_on": [], "what": "", "options": [],
                 "recommend": "", "unblocks": ""}),
    })

# Dependency-first inside a gate: an issue another one waits on sorts earlier, so
# the list reads as a sequence. Ties fall back to iid for a stable order.
def sort_key(r):
    blocking = sum(1 for o in rows if r["iid"] in o["depends_on"])
    return (GATES[r["gate"]][0], -blocking, len(r["depends_on"]), r["iid"])
rows.sort(key=sort_key)

# ── Staleness: does the newest comment read as a resolution? ──────────────────
# ops#143 sat here four days as the sole blocks-prod item while its two newest
# comments both said "recommend close" — the ## Decision block is a snapshot,
# and nothing compared it against the conversation. A match is a FLAG, not a
# verdict: the operator is told to read the comment, never to skip the issue.
STALE_PAT = re.compile(
    r"recommend(?:ed|ing)?\s+clos(?:e|ing)|ALREADY DONE|\bFIXED\s*[—-]"
    r"|overtaken by events|\bOBE\b|^\*\*CLOSING\b",
    re.I | re.M)

def latest_note(iid):
    if not notes_dir:
        return None
    try:
        data = json.load(open(os.path.join(notes_dir, f"{iid}.json")))
    except (OSError, ValueError):
        return None
    if isinstance(data, list) and data:
        return data[0].get("body") or ""
    return None

for r in rows:
    note = latest_note(r["iid"])
    if note and STALE_PAT.search(note):
        r["possibly_stale"] = True
        r["stale_hint"] = re.sub(r"\s+", " ", note).strip()[:200]
    else:
        r["possibly_stale"] = False

if only_iid:
    rows = [r for r in rows if str(r["iid"]) == only_iid]
    if not rows:
        print(f"No open decision #{only_iid}.", file=sys.stderr)
        sys.exit(1)

# ── Open MRs, from the manifest decisions.sh fetched ──────────────────────────
# Under solo review mode (NWP-ADR-0032) the merge click IS the approval, so an open
# MR belongs in the same queue as a needs-decision issue. A project whose fetch
# failed carries ok=False and an error — it is rendered as CANNOT-READ, never
# dropped: an unreadable forge must not look like an empty one.
def mr_row(m: dict) -> dict:
    desc = (m.get("description") or "").strip()
    return {
        "project": "",  # filled by caller
        "iid": m.get("iid"),
        "title": m.get("title") or "",
        "url": m.get("web_url") or "",
        "draft": bool(m.get("draft")),
        "merge_status": m.get("detailed_merge_status") or m.get("merge_status") or "",
        "has_conflicts": bool(m.get("has_conflicts")),
        "source_branch": m.get("source_branch") or "",
        "author": ((m.get("author") or {}).get("username")) or "",
        "updated_at": m.get("updated_at") or "",
        "labels": m.get("labels") or [],
        # The pane renders this as the MR's explanation; 4000 chars keeps the
        # What/Why/Risk sections `pl mr create` writes without shipping a book.
        "description": desc[:4000],
    }

mrs = {"projects": [], "open_total": 0}
if mrs_manifest:
    try:
        manifest_lines = open(mrs_manifest).read().splitlines()
    except OSError:
        manifest_lines = []
    for line in manifest_lines:
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        proj, path, status = parts
        entry = {"project": proj, "ok": False, "error": "", "items": []}
        if status != "ok":
            entry["error"] = "CANNOT-READ (token walled to another project, or forge unreachable)"
        else:
            try:
                data = json.load(open(path))
                if isinstance(data, list):
                    entry["ok"] = True
                    for m in data:
                        row = mr_row(m)
                        row["project"] = proj
                        entry["items"].append(row)
                else:
                    entry["error"] = "CANNOT-READ (unexpected response shape)"
            except (OSError, ValueError):
                entry["error"] = "CANNOT-READ (unparseable response)"
        mrs["projects"].append(entry)
    mrs["open_total"] = sum(len(p["items"]) for p in mrs["projects"])


# ── AMBER: the decision::wanted tier (nwp/ops#279) ───────────────────────────
#
# RED  = `needs-decision`   — a decision is NEEDED. Always rendered first.
# AMBER = `decision::wanted` — a decision is WANTED: real, but nothing is
#                              standing still waiting for it.
#
# Only 4 of the 55 ambers carry a `## Decision` block, so their sequence cannot
# come from a declared Gate the way red's does. It is derived from labels that
# already exist and already mean something, in this precedence:
#
#   1. a DECLARED gate (the 4 that have one) — always the strongest signal
#   2. go-live-prereq  — Phase 2 cannot start until it is settled; that is what
#                        the label means, so it is not an inference at all
#   3. security        — a security question left open decays
#   4. priority::high / ::medium — the operator's own triage
#   5. everything else, by iid
#
# Each row records WHICH signal placed it (`why`), and the renderer says so.
# A sequence that looks authoritative but was guessed is worse than one that
# admits which half is inferred — the operator has to know whether to trust the
# order or re-check it.
AMBER_BUCKETS = [
    ("declared",      "DECLARED GATE",     "these four state their own question"),
    ("go-live",       "GO-LIVE PREREQ",    "Phase 2 cannot start until these are settled"),
    ("security",      "SECURITY",          "an open security question decays"),
    ("high",          "HIGH PRIORITY",     "your own triage said so"),
    ("medium",        "MEDIUM PRIORITY",   "your own triage said so"),
    ("unranked",      "UNRANKED",          "no gate, no priority — triage or close"),
]
AMBER_RANK = {k: n for n, (k, _, _) in enumerate(AMBER_BUCKETS)}

def amber_bucket(labels: list, has_block: bool) -> tuple:
    """Return (bucket_key, why) — the sequence signal and its provenance."""
    if has_block:
        return ("declared", "declares its own Gate")
    if "go-live-prereq" in labels:
        return ("go-live", "labelled go-live-prereq")
    if "security" in labels:
        return ("security", "labelled security")
    if "priority::high" in labels:
        return ("high", "labelled priority::high")
    if "priority::medium" in labels:
        return ("medium", "labelled priority::medium")
    return ("unranked", "no ordering label — inferred position only")

ambers = []
# THREE distinct states, and collapsing any two of them lies to the operator:
#   attempted + parsed    -> render the tier
#   attempted + unparsed  -> "COULD NOT BE READ" (never an empty tier)
#   not attempted         -> fall back to the count-only footer, as before
# The first version conflated "no amber file" with "unreadable", so the plain
# count-only path shouted CANNOT-READ at an operator whose fetch was simply not
# requested. Two pre-existing tests caught it.
amber_attempted = bool(amber_file)
amber_readable = amber_attempted
if amber_file:
    try:
        raw = json.load(open(amber_file))
        if not isinstance(raw, list):
            raise ValueError("not a list")
        for i in raw:
            body = i.get("description") or ""
            b = block(body)
            labels = i.get("labels", [])
            key, why = amber_bucket(labels, b is not None)
            ambers.append({
                "iid": i["iid"],
                "title": i["title"],
                "url": i.get("web_url") or f"https://{host}/nwp/ops/-/issues/{i['iid']}",
                "labels": labels,
                "bucket": key,
                "why": why,
                "what": (b or {}).get("what", ""),
                # ops#292: the row's own gate label. Declared beats inferred —
                # a row that states its Gate shows it; the rest show "".
                "gate": (b or {}).get("gate", "") if b is not None else "",
            })
        ambers.sort(key=lambda r: (AMBER_RANK[r["bucket"]], r["iid"]))
    except Exception:
        amber_readable = False
        ambers = []

# ── PARTIAL detection (ops#292) ──────────────────────────────────────────────
# The list fetch and the count fetch are independent reads of the same filter.
# If the tracker's X-Total says MORE ambers exist than the list carries, the
# list was truncated (a capped fetch, a dropped page) — and a truncated tier
# rendering as the whole tier is the unreadable-renders-as-clean failure with
# a smaller blast radius. Declared, never silently trimmed.
amber_partial = (amber_readable and bool(ambers)
                 and outside_count.isdigit() and int(outside_count) > len(ambers))

if mode == "json":
    out = {"count": len(rows), "decisions": rows, "mrs": mrs,
           "outside_queue": {"label": "decision::wanted",
                             "count": int(outside_count) if outside_count.isdigit() else None,
                             # THREE states, exposed as two flags so the Console
                             # pane can tell "empty" from "not looked" from
                             # "looked and failed" — the same distinction the
                             # text renderer makes.
                             "attempted": amber_attempted,
                             "readable": amber_readable,
                             # ops#292: true when the tracker's total says the
                             # list below is not the whole tier.
                             "partial": amber_partial,
                             # NOT "items": Jinja resolves `.items` to dict.items
                             # (the METHOD), so a template reading
                             # outside_queue.items got a bound builtin and blew
                             # up on |length. Renaming is the fix that cannot be
                             # forgotten by the next consumer.
                             "issues": ambers}}
    print(json.dumps(out, indent=2))
    sys.exit(0)

B, D, R = "\033[1m", "\033[2m", "\033[0m"
# RED / AMBER are the operator's own vocabulary (ops#279) and match `pl rag`'s
# fleet colours, so one glance means the same thing in both places.
RED, AMB = "\033[31m", "\033[33m"

# MRs render FIRST: in solo mode an open green MR is the single most actionable
# item on the operator's plate — PICKUP docs kept putting "merge !N" at the top
# by hand; this is that ordering, held by code instead of by discipline.
if mrs["projects"]:
    unread = [p for p in mrs["projects"] if not p["ok"]]
    if mrs["open_total"] or unread:
        print(f"\n{B}══ AWAITING YOUR MERGE ══{R}  {D}solo mode: the merge click on the MR page is the approval{R}\n")
        for p in mrs["projects"]:
            if not p["ok"]:
                print(f"  {B}{p['project']}{R}: {p['error']}")
                continue
            for m in p["items"]:
                flags = []
                if m["draft"]:
                    flags.append("DRAFT")
                if m["has_conflicts"]:
                    flags.append("CONFLICTS")
                flag_s = f"  [{' '.join(flags)}]" if flags else ""
                print(f"  {B}{p['project']}!{m['iid']}{R}  {m['title']}{flag_s}")
                if m["merge_status"]:
                    print(f"    {D}status: {m['merge_status']} · by {m['author']}{R}")
                print(f"    {m['url']}\n")

def footer():
    """The AMBER tier, rendered (ops#279).

    Was a count in a footer; the operator asked for it as a real section —
    RED = decision needed, AMBER = decision wanted, red always first. A number
    told them 55 existed and gave them no way to act on it; a list in order is
    the difference between a backlog and a queue.

    Compact by design: one line each. 55 full ## Decision blocks would drown
    the red tier, and the red tier is the one that must stay readable.

    Fail-closed: if the list could not be fetched this says so and falls back
    to the count. An unreadable amber tier must never render as an empty one."""
    if only_iid:
        return
    if ambers:
        print(f"{AMB}{B}\u25cf AMBER — DECISION WANTED{R}  {B}({len(ambers)}){R}")
        if amber_partial:
            print(f"{AMB}⚠ PARTIAL: showing {len(ambers)} of {outside_count} — the rest were")
            print(f"not fetched this run. Do not read this list as the whole tier.{R}")
        print(f"{D}Real questions, but nothing is standing still waiting for them.{R}")
        print(f"{D}Only {sum(1 for a in ambers if a['bucket'] == 'declared')} of these state their own question; the rest are ordered by{R}")
        print(f"{D}labels that already exist — the order is partly inferred, so treat it as{R}")
        print(f"{D}a reading sequence, not a ruling.{R}\n")
        current_b = None
        for a in ambers:
            if a["bucket"] != current_b:
                current_b = a["bucket"]
                _, head, why = next(x for x in AMBER_BUCKETS if x[0] == current_b)
                n = sum(1 for x in ambers if x["bucket"] == current_b)
                print(f"  {AMB}── {head} ({n}) ──{R}  {D}{why}{R}")
            print(f"    {B}#{a['iid']}{R}  {a['title']}")
            if a["what"]:
                print(f"      {D}{a['what'][:160]}{R}")
            print(f"      {D}{a['url']}{R}")
        print()
        print(f"{D}Promote one to RED with:  pl issue label <iid> --add needs-decision{R}")
        return
    # No list this run — say which, and never imply the tier is empty.
    if amber_attempted and not amber_readable:
        print(f"{D}AMBER (decision::wanted) COULD NOT BE READ this run. That tier still{R}")
        print(f"{D}exists — this queue is showing needs-decision only. Do not read the{R}")
        print(f"{D}absence of an amber section as an empty backlog.{R}")
    elif outside_count.isdigit() and int(outside_count) > 0:
        print(f"{D}Beyond this queue: {outside_count} open issue(s) carry decision::wanted but not")
        print(f"needs-decision — decision-shaped backlog, not rendered here. Promote one with:")
        print(f"  pl issue label <iid> --add needs-decision{R}")
    elif not outside_count:
        print(f"{D}(The decision::wanted backlog count could not be read this run — that tier")
        print(f"still exists; this queue renders needs-decision only.){R}")

if not rows:
    if mrs["open_total"]:
        print("No decisions are waiting — the merge requests above are the whole queue.")
    else:
        print("No decisions are waiting. Nothing is blocked on you.")
    footer()
    sys.exit(0)

incomplete = [r for r in rows if not r["complete"]]
print(f"\n{RED}{B}\u25cf RED — DECISION NEEDED{R}  {B}({len(rows)}){R}")
print(f"{D}Nothing moves until these are answered. Read in order — later ones may{R}")
print(f"{D}not make sense until earlier ones are.{R}\n")

current = None
for r in rows:
    if r["gate"] != current:
        current = r["gate"]
        _, head, why = GATES[current]
        print(f"{B}══ {head} ══{R}  {D}{why}{R}\n")
    print(f"  {B}#{r['iid']}  {r['title']}{R}")
    if r.get("possibly_stale"):
        print(f"    {B}⚠ possibly already resolved{R} — newest comment: {D}“{r['stale_hint']}”{R}")
        print(f"    {D}Read it before deciding — a ## Decision block can outlive its answer (the ops#143 lesson).{R}")
    if not r["complete"]:
        # Never silently skipped: an unreadable decision still blocks.
        print(f"    {D}(no ## Decision block yet — the question is buried in the issue){R}")
        print(f"    {r['url']}\n")
        continue
    if r["what"]:
        print(f"    {r['what']}")
    if r["options"]:
        print(f"    {D}Options:{R}")
        for o in r["options"]:
            print(f"      • {o}")
    if r["recommend"]:
        print(f"    {B}Recommend:{R} {r['recommend']}")
    if r["unblocks"]:
        print(f"    {D}Unblocks: {r['unblocks']}{R}")
    if r["depends_on"]:
        print(f"    {D}Answer after: {', '.join('#'+str(d) for d in r['depends_on'])}{R}")
    print(f"    {r['url']}\n")

if incomplete:
    print(f"{D}{len(incomplete)} of these have no ## Decision block. They are listed because")
    print(f"they still block you — but reading them means opening the issue.{R}")

footer()
