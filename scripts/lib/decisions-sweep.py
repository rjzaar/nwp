"""sweep-approved classifier (ops#327) — pure: files in, report out.

The console Review pane's Approve button posted a `[console-review] APPROVED`
note that nothing consumed: the decision labels stayed on, the issue stayed in
the queue, and the operator re-approved — #139 four times, #74 and #101 in the
same state. The Approve action now discharges (scripts/console/app/main.py);
this classifier finds the RESIDUE: issues carrying an approving note that
still wear `needs-decision` / `decision::wanted`.

Pure on purpose, like decisions-render.py and decisions-promote-plan.py: the
network shell in decisions.sh stays thin, and the failing state is a fixture
in tests/unit/test-decisions-sweep.bats.

argv: <mode: text|json> <issues.json> <notes-dir>
  issues.json  list of {iid, title, web_url, labels} (the tracker's rows)
  notes-dir    one <iid>.json per issue with its notes; a MISSING file means
               the notes fetch failed for that issue — its approval state is
               UNKNOWN, which is declared and makes the whole run exit 2.

exit: 0 report complete · 2 CANNOT-VERIFY (unreadable input, or any UNKNOWN)
"""
import json
import re
import sys

DECISION_LABELS = ("needs-decision", "decision::wanted")

# An approval is either the console's server-side-tagged note, or an operator
# reply whose first line SAYS approved. "Approved. Go with B." counts;
# "Should we get this approved?" does not — the ruling word must lead the
# line, not merely occur in it.
_REPLY = re.compile(r"^[\s*_>#`-]*approved\b", re.IGNORECASE)


def is_approving(note: dict) -> bool:
    if note.get("system"):
        return False  # a machine event is not an operator ruling
    body = (note.get("body") or "").strip()
    if not body:
        return False
    if "[console-review]" in body and "APPROVED" in body:
        return True
    return bool(_REPLY.match(body.splitlines()[0]))


def main() -> int:
    if len(sys.argv) < 4:
        print("CANNOT-VERIFY: usage: decisions-sweep.py <text|json> <issues.json> <notes-dir>")
        return 2
    mode, issues_file, notes_dir = sys.argv[1], sys.argv[2], sys.argv[3]

    try:
        with open(issues_file) as f:
            issues = json.load(f)
        assert isinstance(issues, list)
    except Exception:
        print("CANNOT-VERIFY: the issue list could not be read — this is not "
              "'no undischarged approvals', it is 'the sweep could not look'.")
        return 2

    rows, unknown = [], []
    for i in issues:
        iid = i.get("iid")
        labels = [l for l in (i.get("labels") or []) if l in DECISION_LABELS]
        if not labels:
            continue  # already discharged; nothing to sweep
        try:
            with open(f"{notes_dir}/{iid}.json") as f:
                notes = json.load(f)
            assert isinstance(notes, list)
        except Exception:
            unknown.append({"iid": iid, "title": i.get("title") or ""})
            continue
        approving = [n for n in notes if is_approving(n)]
        if not approving:
            continue
        when = max((n.get("created_at") or "") for n in approving)
        rows.append({
            "iid": iid,
            "title": i.get("title") or "",
            "url": i.get("web_url") or "",
            "decision_labels": labels,
            "approved_when": when,
            "approved_times": len(approving),
        })
    rows.sort(key=lambda r: r["approved_when"])

    if mode == "json":
        json.dump({"rows": rows, "unknown": unknown}, sys.stdout)
        print()
        return 2 if unknown else 0

    if rows:
        print(f"{len(rows)} undischarged approval(s) — approved on the record, "
              f"decision labels still on the issue:")
        print(f"{'iid':>6}  {'approved-when':<20}  {'times':>5}  {'labels':<32}  title")
        for r in rows:
            times = str(r["approved_times"]) + (" ⚠" if r["approved_times"] > 1 else "")
            print(f"{'#' + str(r['iid']):>6}  {r['approved_when']:<20}  {times:>5}  "
                  f"{','.join(r['decision_labels']):<32}  {r['title']}")
        print("\ndischarge with: pl decisions sweep-approved --discharge")
    else:
        print("0 undischarged approvals — every approving note's issue has had "
              "its decision labels removed.")
    if unknown:
        print(f"\nCANNOT-VERIFY: {len(unknown)} issue(s) whose notes could not be "
              f"read — approval state UNKNOWN, this sweep is NOT complete:")
        for u in unknown:
            print(f"  #{u['iid']}  UNKNOWN  {u['title']}")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
