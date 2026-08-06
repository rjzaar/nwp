import json, re, sys

mode, only_iid, host = sys.argv[1], sys.argv[2], sys.argv[3]
mrs_manifest = sys.argv[4] if len(sys.argv) > 4 else ""
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

if only_iid:
    rows = [r for r in rows if str(r["iid"]) == only_iid]
    if not rows:
        print(f"No open decision #{only_iid}.", file=sys.stderr)
        sys.exit(1)

# ── Open MRs, from the manifest decisions.sh fetched ──────────────────────────
# Under solo review mode (ADR-0032) the merge click IS the approval, so an open
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

if mode == "json":
    print(json.dumps({"count": len(rows), "decisions": rows, "mrs": mrs}, indent=2))
    sys.exit(0)

B, D, R = "\033[1m", "\033[2m", "\033[0m"

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

if not rows:
    if mrs["open_total"]:
        print("No decisions are waiting — the merge requests above are the whole queue.")
    else:
        print("No decisions are waiting. Nothing is blocked on you.")
    sys.exit(0)

incomplete = [r for r in rows if not r["complete"]]
print(f"\n{B}{len(rows)} decision(s) waiting{R}")
print(f"{D}Read in order — later ones may not make sense until earlier ones are answered.{R}\n")

current = None
for r in rows:
    if r["gate"] != current:
        current = r["gate"]
        _, head, why = GATES[current]
        print(f"{B}══ {head} ══{R}  {D}{why}{R}\n")
    print(f"  {B}#{r['iid']}  {r['title']}{R}")
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
