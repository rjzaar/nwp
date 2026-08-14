#!/usr/bin/env python3
"""
Measure the state of the 16-candidate clip shortlist and its remediation
overlays. Emits ONE json object on stdout.

Every field is read off an artefact at run time. Nothing here is a constant
copied out of a report, because a constant copied out of a report is stale the
day after it is written and cannot say so. Where a figure can only come from a
previous run's captured output, this records the SOURCE FILE and its mtime and
compares it against the artefact it was measured from, so staleness is visible
rather than silent.

It is a file rather than a shell heredoc so it can be reviewed and tested, and
it is fed to the measurement host over `ssh <host> python3 - <args>` so the
corpus never leaves that machine.

FAIL-CLOSED. Anything unmeasurable lands in `cannot_verify` and the caller
grades the block CANNOT VERIFY. A missing file is never an empty result, and an
empty result is never "nothing outstanding".

Usage:  clip-finish-shortlist.py <shortlist-dir> <work-dir> [sample-n] [seed]
"""
import hashlib
import json
import math
import os
import random
import re
import sys

BASENAME = "SHORTLIST-16.jsonl"
DEFAULT_SAMPLE = 120
DEFAULT_SEED = 1729
DEEP_CUT = 16           # the recipe's moment_rank window
CEILING_S = 420         # the operator's uniform clip ceiling
MIN_SOURCES = 2         # "corroborated" = >=2 independent sources agreeing


def _emit(obj):
    json.dump(obj, sys.stdout, default=str)
    sys.stdout.write("\n")
    sys.exit(0)          # the CALLER grades; this only measures


def _fail(reason, **extra):
    out = {"ok": False, "cannot_verify": [reason]}
    out.update(extra)
    _emit(out)


def wilson(k, n, z=1.96):
    """95% Wilson interval — computed here, never copied from a report."""
    if n == 0:
        return None
    p = k / float(n)
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return [round(100 * max(0.0, c - h), 1), round(100 * min(1.0, c + h), 1)]


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_json(path):
    with open(path) as fh:
        return json.load(fh)


def main():
    if len(sys.argv) < 3:
        _fail("usage: clip-finish-shortlist.py <shortlist-dir> <work-dir>")
    sl_dir = os.path.expanduser(sys.argv[1])
    wk_dir = os.path.expanduser(sys.argv[2])
    sample_n = int(sys.argv[3]) if len(sys.argv) > 3 else DEFAULT_SAMPLE
    seed = int(sys.argv[4]) if len(sys.argv) > 4 else DEFAULT_SEED

    path = os.path.join(sl_dir, BASENAME)
    if not os.path.isfile(path):
        _fail("shortlist not found: %s" % path, dir=sl_dir)

    cv = []
    out = {"ok": True, "shortlist_dir": sl_dir, "work_dir": wk_dir,
           "shortlist_path": path,
           "shortlist_mtime": int(os.path.getmtime(path))}

    # ── 1. integrity: sha256 against the digest recorded beside it ────────────
    out["sha_actual"] = sha256_of(path)
    sha_path = path + ".sha256"
    rec = None
    if os.path.isfile(sha_path):
        with open(sha_path) as fh:
            first = fh.readline().split()
            if first:
                rec = first[0]
    if rec is None:
        cv.append("no recorded sha256 beside the shortlist (%s)" % sha_path)
    out["sha_recorded"] = rec
    out["sha_match"] = (rec == out["sha_actual"]) if rec else None

    # ── 2. parse the base artefact ───────────────────────────────────────────
    lps = rows = bad = 0
    lps_under_target = 0
    over_ceiling = 0
    needs_quote_pass = 0
    has_shortfall_audit = 0
    nl_rows = nl_frags = nl_caveated = nl_uncaveated = audit_missing = 0
    deep = []

    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                bad += 1
                continue
            lps += 1
            declared = bool(r.get("shortfall_reason"))
            if r.get("shortfall_reason_audit"):
                has_shortfall_audit += 1
            sel = r.get("selected") or []
            if len(sel) < (r.get("target") or 16):
                lps_under_target += 1
            for row in sel:
                rows += 1
                dur = row.get("duration_s")
                if dur is not None and dur > CEILING_S:
                    over_ceiling += 1
                a = row.get("rationale_quote_audit")
                if not isinstance(a, dict):
                    audit_missing += 1
                else:
                    if a.get("status") == "NEEDS-QUOTE-PASS":
                        needs_quote_pass += 1
                    n = a.get("NOT_LOCATED_paraphrase_in_quote_marks")
                    if n is None:
                        audit_missing += 1
                    elif n > 0:
                        nl_rows += 1
                        nl_frags += n
                        if row.get("caveat"):
                            nl_caveated += 1
                        else:
                            nl_uncaveated += 1
                mr = row.get("moment_rank")
                if mr is not None and mr > DEEP_CUT:
                    deep.append((declared, row.get("n_sources_agreeing") or 0))

    if bad:
        cv.append("%d unparseable line(s) in %s" % (bad, BASENAME))
    if rows == 0:
        cv.append("shortlist parsed to zero candidate rows")
    if audit_missing:
        cv.append("%d row(s) carry no usable rationale_quote_audit block — the "
                  "fabricated-quote count is a FLOOR, not a census" % audit_missing)

    out.update({"lps": lps, "rows": rows,
                "lps_under_target": lps_under_target,
                "rows_over_ceiling_420s": over_ceiling,
                "rows_needing_quote_pass": needs_quote_pass,
                "quote_not_located_rows": nl_rows,
                "quote_not_located_fragments": nl_frags,
                "quote_repaired_caveated": nl_caveated,
                "quote_outstanding_uncaveated": nl_uncaveated,
                "rows_without_quote_audit": audit_missing,
                "deep_rows": deep_n(deep)})

    # ── 3. are the remediation overlays APPLIED? measured, never assumed ──────
    #
    # The overlays are files; whether they have been applied is a property of
    # the BASE artefact, so it is read there. Three independent witnesses, each
    # of which the overlay is defined to change:
    #     d3 (ceiling) : over-ceiling rows 19 -> 0, and NEEDS-QUOTE-PASS 0 -> 14
    #     d2 (reasons) : shortfall_reason_audit blocks 0 -> 23
    ov = {}
    for name in ("d3_overlay.json", "d2_overlay.json", "apply_overlay.py",
                 "d2fix.py", "SHORTLIST-16.remediated.jsonl"):
        p = os.path.join(wk_dir, name)
        ov[name] = os.path.isfile(p)
    out["overlay_files"] = ov
    missing_ov = [k for k, v in ov.items() if not v]
    if missing_ov:
        cv.append("overlay artefacts missing from %s: %s"
                  % (wk_dir, ", ".join(missing_ov)))

    d3_applied = (over_ceiling == 0 and needs_quote_pass > 0)
    d2_applied = has_shortfall_audit > 0
    out["d3_ceiling_applied"] = d3_applied
    out["d2_reasons_applied"] = d2_applied
    out["shortfall_audit_blocks_in_base"] = has_shortfall_audit
    out["overlays_applied"] = bool(d3_applied and d2_applied)

    # ── 4. defect 2 — shortfall reasons, read off the overlay ────────────────
    p = os.path.join(wk_dir, "d2_overlay.json")
    if ov["d2_overlay.json"]:
        try:
            d2 = load_json(p)
            verdicts = {}
            unexplained = 0
            unexplained_lps = 0
            for lp, v in d2.items():
                a = v.get("shortfall_reason_audit") or {}
                verdicts[a.get("verdict", "UNKNOWN")] = \
                    verdicts.get(a.get("verdict", "UNKNOWN"), 0) + 1
                n = a.get("n_unexplained") or 0
                if n:
                    unexplained += n
                    unexplained_lps += 1
            out["d2"] = {"lps_examined": len(d2), "verdicts": verdicts,
                         "unexplained_drops": unexplained,
                         "unexplained_lps": unexplained_lps,
                         "source": p,
                         "source_mtime": int(os.path.getmtime(p))}
        except (ValueError, OSError) as e:
            cv.append("could not read d2_overlay.json: %s" % e)

    # ── 5. defect 3 — the ceiling, read off the overlay ──────────────────────
    p = os.path.join(wk_dir, "d3_overlay.json")
    if ov["d3_overlay.json"]:
        try:
            d3 = load_json(p)
            swapped = dropped = other = 0
            for lp, v in d3.items():
                cp = v.get("ceiling_policy") or {}
                for dec in cp.get("decisions") or []:
                    d = str(dec.get("decision", "")).upper()
                    if d.startswith("SWAP"):
                        swapped += 1
                    elif d.startswith("DROP"):
                        dropped += 1
                    else:
                        other += 1
            if other:
                cv.append("%d ceiling decision(s) in d3_overlay.json are "
                          "neither SWAP nor DROP and were not counted" % other)
            out["d3"] = {"lps_affected": len(d3), "swapped": swapped,
                         "dropped": dropped, "unclassified": other, "source": p,
                         "source_mtime": int(os.path.getmtime(p))}
        except (ValueError, OSError) as e:
            cv.append("could not read d3_overlay.json: %s" % e)

    # ── 6. defect 4 — the contested deep third, SAMPLED not censused ─────────
    #
    # The census was refused on an operator scope cut. That refusal is reported
    # in full: the population, the sample, the survival rate with its interval,
    # and the REMAINDER NOBODY HAS LOOKED AT. Never a bare percentage, which
    # would read as coverage.
    d4 = {"census_refused": True,
          "why": "operator scope cut 2026-08-12 — ~1,260 deep rows is not a "
                 "defensible spend on a declared trade-off"}
    vp = os.path.join(wk_dir, "d4_verdicts.json")
    if os.path.isfile(vp):
        try:
            V = load_json(vp)
            c = {}
            for v in V:
                c[v.get("verdict", "UNKNOWN")] = c.get(v.get("verdict", "UNKNOWN"), 0) + 1
            n = len(V)
            strict = c.get("SURVIVES", 0)
            lenient = strict + c.get("SURVIVES_CEILING", 0)
            d4.update({"judged": n, "verdicts": c,
                       "strict_survival_pct": round(100.0 * strict / n, 1) if n else None,
                       "strict_ci95": wilson(strict, n),
                       "lenient_survival_pct": round(100.0 * lenient / n, 1) if n else None,
                       "lenient_ci95": wilson(lenient, n),
                       "verdicts_source": vp,
                       "verdicts_mtime": int(os.path.getmtime(vp))})
        except (ValueError, OSError) as e:
            cv.append("could not read d4_verdicts.json: %s" % e)
    else:
        cv.append("no d4_verdicts.json in %s — the deep-third sample cannot be "
                  "read" % wk_dir)

    # population: only available from the sampler's captured output. Recorded
    # WITH its mtime and compared against the artefact, so a base artefact that
    # has moved since shows up as STALE rather than as a fresh number.
    sp = os.path.join(wk_dir, "d4sample.txt")
    if os.path.isfile(sp):
        try:
            txt = open(sp, errors="replace").read(20000)

            def grab(pat):
                # the sampler pads its labels and parenthesises them, so allow
                # anything up to the colon that is not itself a line break
                m = re.search(pat + r"[^:\n]*:\s*(\d+)", txt)
                return int(m.group(1)) if m else None

            pop_deep = grab(r"deep rows \(moment_rank > 16\)")
            contested = grab(r"CONTESTED deep rows")
            unforced = grab(r"UNFORCED deep rows")
            pop_mtime = int(os.path.getmtime(sp))
            d4.update({"population_source": sp, "population_mtime": pop_mtime,
                       "population_deep_rows": pop_deep,
                       "contested": contested, "unforced": unforced,
                       "population_stale": pop_mtime < out["shortlist_mtime"]})
            if contested is not None and d4.get("judged") is not None:
                d4["contested_unjudged"] = contested - d4["judged"]
            if contested is None:
                cv.append("could not parse the contested population from %s" % sp)
            if d4.get("population_stale"):
                cv.append("the deep-third population in %s was measured BEFORE "
                          "the current shortlist was last written — treat the "
                          "contested/unforced split as stale" % sp)
        except OSError as e:
            cv.append("could not read d4sample.txt: %s" % e)
    else:
        cv.append("no d4sample.txt in %s — the contested population is unknown, "
                  "so the unjudged remainder cannot be stated" % wk_dir)
    out["d4"] = d4

    # ── 7. the cheap deep-row justification signal, censused AND sampled ─────
    #
    # The only justification signals INSIDE the artefact are: the LP declares a
    # shortfall reason, or the row is corroborated on its own. Neither is a
    # reading of the clip, which is why d4 above exists and why this is
    # reported as a signal and not as a verdict.
    n_deep = len(deep)
    census = sum(1 for declared, ns in deep if declared or ns >= MIN_SOURCES)
    sample_n = min(sample_n, n_deep)
    survived = None
    if sample_n > 0:
        survived = sum(1 for declared, ns in
                       random.Random(seed).sample(deep, sample_n)
                       if declared or ns >= MIN_SOURCES)
    out["deep_signal"] = {
        "deep_rows": n_deep, "cut": DEEP_CUT,
        "declared_or_corroborated": census,
        "remainder": n_deep - census,
        "sample_n": sample_n, "sample_seed": seed, "sample_survived": survived}

    out["cannot_verify"] = cv
    _emit(out)


def deep_n(deep):
    return len(deep)


if __name__ == "__main__":
    main()
