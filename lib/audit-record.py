#!/usr/bin/env python3
"""Shared interpreter for `pl audit` records (private/update-awareness/<site>.json).

WHY THIS FILE EXISTS (ops#178)
    Two consumers grade the fleet's security signal: `pl rag` (lib/rag-render.py)
    and `pl todo`'s check_security_updates (lib/todo-checks.sh). They MUST NOT be
    able to disagree about what a record means — "rag says UNSCANNED, todo says
    clean" is exactly the class of split-brain that made `security: 0` mean two
    different things depending on who asked.

    Before ops#178 there was no shared reader at all: rag interpreted the records
    and `check_security_updates` ignored them entirely, shelling
    `ddev drush pm:security` per site instead. That command was REMOVED from
    Drush ("pm:security has been removed. Please use `composer audit`"), its
    error was swallowed by a trailing `|| echo "[]"`, and the v2 site layout
    (sites/<name>/dev/web, not sites/<name>/web) meant the webroot probe missed
    19 of 21 sites before it even got that far. The check could not emit a SEC
    item for ANY input while reporting "Security: clean".

    This module is now the single definition of what an audit record asserts.

THE THREE STATES a record can be in — the same distinction the rest of the
estate insists on (see lib/todo-checks.sh's todo_add_unknown):

    measured    we looked; `count` is a real number
    unscanned   we could NOT look; `count` is meaningless, NOT zero
    stale       we looked, but too long ago for the answer to still be load-bearing

`scanned` is the axis `pl rag` grades on: a site that is not scanned can never
grade GREEN. `stale` is a strictly-more-conservative axis that `pl todo` adds on
top (an aged record raises an UNK item, which drives rag to AMBER via its
unknown>0 rule). Being stricter here cannot contradict rag; it can only refuse
to call something clean that rag would also refuse to call green.
"""
import os, json, glob, datetime

# How old a record may be before `pl todo` stops believing it. Only the todo leg
# applies this; rag's own staleness axis is the record's own `cache_stale` flag.
DEFAULT_STALE_DAYS = 7


def _numeric(v):
    try:
        float(str(v))
        return True
    except Exception:
        return False


def interpret_record(path):
    """Interpret one audit record. Returns the dict `pl rag` grades on:
       {site, count, ignored, stale, scanned, reason, checked}

    This is the EXACT logic rag-render.py used inline before ops#178; moving it
    here changed no semantics, it only gave the todo leg the same eyes.
    """
    site = os.path.basename(path)[:-5] if path.endswith(".json") else os.path.basename(path)
    try:
        d = json.load(open(path))
    except Exception:
        # An unreadable record is a blind spot, not an absent site.
        return {"site": site, "count": 0, "ignored": 0, "stale": True, "scanned": False,
                "reason": "audit record is unreadable/corrupt", "checked": ""}

    s = d.get("site") or site
    stale = bool(d.get("cache_stale", False))
    scanned = d.get("scanned")
    if scanned is None:
        # Records predating the `scanned` key are inferred from cache_stale,
        # which had the same meaning for the composer leg; a record with neither
        # key is assumed scanned so historical records don't all flip amber at
        # once, but a record whose reason we can see is honoured.
        scanned = not stale
    reason = d.get("stale_reason", "") or ""

    # SELF-EVIDENTLY BOGUS RECORD. `pl audit`'s Moodle leg had a greedy-sed bug
    # that parsed BOTH the installed and the upstream $version to the literal
    # string "branchingdateYYYYMMDD-donotmodify!", so `behind` was arithmetically
    # always 0 and every Moodle site recorded security_count: 0. Those records
    # are still on disk and would keep grading GREEN until the next audit run.
    # A record that carries the evidence of its own invalidity must not be
    # believed: if a Moodle record's version fields are not numeric, no
    # comparison happened, whatever the record claims.
    if d.get("platform") == "moodle":
        iv, lv = d.get("moodle_installed_version"), d.get("moodle_latest_version")
        if not (_numeric(iv) and _numeric(lv)):
            scanned = False
            stale = True
            reason = ("Moodle version fields are unparseable (installed=%r latest=%r) — "
                      "no version comparison happened, so security_count 0 is meaningless. "
                      "Re-run: pl audit --site %s" % (iv, lv, s))

    return {"site": s,
            "count": int(d.get("security_count", 0) or 0),
            "ignored": int(d.get("ignored_count", 0) or 0),
            "stale": stale,
            "scanned": bool(scanned),
            "reason": reason,
            "checked": d.get("checked") or ""}


def load_dir(audit_dir):
    """site -> interpreted record, for every *.json in audit_dir."""
    out = {}
    for f in glob.glob(os.path.join(audit_dir, "*.json")):
        r = interpret_record(f)
        out[r["site"]] = r
    return out


def record_age_days(rec, now=None):
    """Age of the record in whole days, or None if the timestamp is unusable.

    None is NOT 'fresh' — callers must treat an unparseable timestamp as a
    reason to distrust the record, which is why this returns None rather than 0.
    """
    checked = rec.get("checked") or ""
    if not checked:
        return None
    now = now or datetime.datetime.now(datetime.timezone.utc)
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%d %H:%M:%S"):
        try:
            ts = datetime.datetime.strptime(checked, fmt)
            if ts.tzinfo is None:
                ts = ts.replace(tzinfo=datetime.timezone.utc)
            return (now - ts).days
        except Exception:
            continue
    return None


def classify(rec, stale_days=DEFAULT_STALE_DAYS, now=None):
    """Collapse a record to the todo leg's three states.

    Returns (state, count, reason) where state is one of:
        measured | unscanned | stale
    """
    if not rec.get("scanned", False):
        return ("unscanned", rec.get("count", 0),
                rec.get("reason") or "pl audit recorded this site as not scanned")

    age = record_age_days(rec, now=now)
    if age is None:
        return ("stale", rec.get("count", 0),
                "audit record has no usable 'checked' timestamp (%r) — its age cannot be established"
                % (rec.get("checked", ""),))
    if age > stale_days:
        return ("stale", rec.get("count", 0),
                "audit record is %d days old (threshold %d) — re-run pl audit before trusting it"
                % (age, stale_days))
    if rec.get("stale"):
        return ("stale", rec.get("count", 0),
                rec.get("reason") or "pl audit marked this record cache_stale")
    return ("measured", rec.get("count", 0), "record is %d day(s) old" % age)


def _main(argv):
    """CLI for the bash caller: emit one TSV row per record.

    Usage: audit-record.py --dir <audit_dir> [--stale-days N] [--site NAME]
    Output: site \t state \t count \t ignored \t reason
    """
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--dir", required=True)
    p.add_argument("--stale-days", type=int, default=DEFAULT_STALE_DAYS)
    p.add_argument("--site", default="")
    a = p.parse_args(argv)

    recs = load_dir(a.dir)
    for site in sorted(recs):
        if a.site and site != a.site:
            continue
        rec = recs[site]
        state, count, reason = classify(rec, stale_days=a.stale_days)
        reason = " ".join(str(reason).split())
        print("%s\t%s\t%d\t%d\t%s" % (site, state, count, rec.get("ignored", 0), reason))
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(_main(sys.argv[1:]))
