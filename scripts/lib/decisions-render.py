import json, re, sys

mode, only_iid, host = sys.argv[1], sys.argv[2], sys.argv[3]
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

if mode == "json":
    print(json.dumps({"count": len(rows), "decisions": rows}, indent=2))
    sys.exit(0)

if not rows:
    print("No decisions are waiting. Nothing is blocked on you.")
    sys.exit(0)

B, D, R = "\033[1m", "\033[2m", "\033[0m"
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
