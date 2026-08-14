#!/usr/bin/env python3
"""
Score the clip-retrieval calibration when it is judged by a PANEL rather than by
one assessor — nwp/ops#348, P79. Emits ONE json object on stdout.

WHAT CHANGES WHEN THE SECOND HUMAN ARRIVES
------------------------------------------
P78 4.4 committed four gates, all of them measuring ONE operator against the
machine. With N humans a quantity exists that no machine measurement could ever
supply: **inter-HUMAN agreement**. P78 5.2.7 states the limit it removes —
"every instance is the same model ... a systematic error shared by all instances
is invisible here BY CONSTRUCTION". Two humans who have never read each other's
answers do not share that error.

So this scorer measures on TWO axes and reports them in a fixed order:

  axis H  humans vs each other   -> Gate 0 (NEW). Is the panel a coherent
                                    reference standard at all?
  axis M  humans vs the machine  -> Gates 1-4, generalised from P78 4.4.

**Gate 0 is evaluated FIRST and it can fail WITHOUT condemning the labels.**
That direction is the whole point. If the humans do not agree with each other,
a low machine agreement says nothing about the machine — the instrument did not
resolve. P78 4.5's one-step `rm -rf` is therefore NOT triggered by a Gate 0
failure; the run exits 2 CANNOT VERIFY and the remedy is the rubric, not the
labels. A run that deleted 3,309 labels because two volunteers read row 1 of the
grade table differently would be the estate's named failure shape pointed at its
own ground truth.

DEGRADING TO N = 1
------------------
The estate has one active worker (P75 3.1: 2 accounts can apply a clip, 0 hold
`sitemanager`). At N = 1 this file must be exactly the instrument P78 already
committed — same gates, same thresholds, same verdict strings, same exit codes —
or the thresholds were not committed in advance after all. Gates 0, 1b and 3b
report NOT ARMED and are excluded from the overall verdict. The equivalence is
asserted by the bats suite against the six adversarial answer sets P78 4.4.1
already recorded, which is the only way to know it holds.

Arming follows a DECLARED FACT — how many answers files were handed in — never a
flag. Same pattern as `approvers:` (CLAUDE.md) and P75 3.3.4: "There must be no
'turn on dual review' setting, because a setting is a second place for the
policy to live."

FAIL-CLOSED
-----------
  * a bootstrap CI that STRADDLES a threshold is CANNOT VERIFY, never a pass
  * a rater with missing answers makes the RUN CANNOT VERIFY (P78's rule, kept)
  * a rater with too few pairs is EXCLUDED AND NAMED, never silently averaged
  * two raters who agree too well to be independent are a DATA-INTEGRITY finding
    (exit 2), not a reliability finding
  * abstentions are counted and excluded, never imputed as a grade

RIGHTS (P78 6)
--------------
`calibration_set.json` carries excerpts, rationales and learning-point prose
from a password-gated corpus. This file PROJECTS it to a corpus-free view on
load and never holds the text at all, so a leak into the report is structurally
impossible rather than filtered. The projection asserts its own key set and
exits 2 if an unexpected key survives.

Usage:
  clip-calibration-multi.py --cal=<calibration_set.json> <answers1.json> [...]
                            [--packet-dir=DIR] [--boot=N] [--out=FILE]
"""
import collections
import json
import math
import os
import random
import statistics
import sys

NUM = {0, 1, 2, 3}
ABST = {"ABSTAIN-DOCTRINE", "ABSTAIN-PEDAGOGY"}

# ── thresholds ────────────────────────────────────────────────────────────────
# Gates 1-4 are P78 4.4 VERBATIM. They are not re-derived here and must not be
# "adjusted for the panel": a threshold that moves when the measurement arrives
# is not a threshold.
G1_PASS, G1_PARTIAL = 0.45, 0.30
G2_GRADED, G2_BINARY = 0.60, 0.40
G3_MAX_BIAS = 0.5
G4_MAX_SEVERE = 2
G4_MIN_CONTROL_PAIRS = 20
MIN_PAIRS = 30

# Gate 0 — NEW, committed here before any human judgement exists.
#
# 0.667 is Krippendorff's own lowest value supporting even TENTATIVE conclusions
# (P77 3.5 / [D8]). Tentative is exactly the claim strength P78 permits
# ("nothing here may be quoted as an accuracy figure"), so the bar is set at the
# claim being made and not one band above it. Krippendorff's 0.800 "firm
# conclusions" bar is NOT used: P77 3.5 records Voorhees' TREC assessors
# overlapping at Jaccard ~0.30 on the relevant set, and P76 7.1 records two
# competent reviewers agreeing on ~67% of relevance decisions and three on ~45%.
# A gate set at 0.800 for human relevance judging is a gate that cannot pass,
# which is as useless as one that cannot fail.
#
# 0.400 is the floor. Below it the coincidence matrix is closer to chance than
# to structure and the panel is not a reference standard, so NOTHING may be
# concluded about the machine from it.
G0_COHERENT, G0_FLOOR = 0.667, 0.400

# Gate 1b — the machine must not be an OUTLIER on the panel. Armed at 3 humans.
# 0.15 is set from the instrument's own resolution, not from a convention: P78
# 4.3 puts kappa's SE at n=120 at roughly 0.05-0.09, i.e. a 95% CI of +-0.10 to
# +-0.18. A gap narrower than that cannot be told from noise. 0.15 sits inside
# the upper half of that band, so a fired Gate 1b is a gap the instrument can
# actually see.
G1B_MARGIN = 0.15
G1B_MIN_RATERS = 3

# Gate 3b — the raters must be using the same scale as each other. Armed at 2.
# Same unit and same tolerance as Gate 3: half a grade.
G3B_MAX_SPREAD = 0.5

# Integrity — two humans cannot independently agree this closely.
# The highest exact agreement ever MEASURED on this instrument is 0.893
# [0.866, 0.923] (P78 5.2.3) — and that was between instances of the SAME MODEL
# judging identical items. Two humans exceeding the upper bound of that CI by a
# wide margin is evidence about the data's provenance, not about reliability.
# This is deliberately NOT the guild's `agreement_rate_for_auto_approval: 0.95`
# (media-guild.yml): that is a binary stage-approval rate over a sample, a
# different quantity, and a number reused across two meanings is a number that
# drifts.
COLLUSION_EXACT = 0.98
COLLUSION_MIN_SHARED = 30

BOOT = 2000

# The ONLY keys the corpus-free projection may carry. `excerpt`, `lp_text`,
# `lp_summary`, `lp_title`, `course_title` and `machine_rationale` are dropped
# on load and never enter this process's data structures.
ITEM_KEYS = {"label", "lp_id", "stratum", "blind_key", "duration_band",
             "ranker", "rank", "machine_grade", "machine_confidence"}


def die(msg, rep=None):
    out = rep or {}
    out["OVERALL"] = "CANNOT VERIFY — " + msg
    out["exit"] = 2
    print(json.dumps(out, indent=1, default=str))
    sys.exit(2)


# ── the corpus-free projection ────────────────────────────────────────────────
def load_calibration(path):
    """Project calibration_set.json to a corpus-free item table.

    Structural, not a text filter. P78 2.2 records why: a grep for leaked words
    false-positives on the learning point's own prose, and a check that fires
    for the wrong reason is not a check. Here the text is simply not copied.
    """
    try:
        raw = json.load(open(path))
    except Exception as e:
        die("cannot read the calibration set %s: %s" % (path, e))
    items = {}
    for lp in raw:
        for it in lp.get("items", []):
            rec = {"label": it["label"],
                   "lp_id": lp["lp_id"],
                   "stratum": lp["stratum"],
                   "blind_key": it["blind_key"],
                   "duration_band": it["duration_band"],
                   "ranker": it.get("ranker"),
                   "rank": it.get("rank"),
                   "machine_grade": it["machine_grade"],
                   "machine_confidence": it.get("machine_confidence")}
            extra = set(rec) - ITEM_KEYS
            if extra:
                die("projection leaked unexpected keys: %s" % sorted(extra))
            items[rec["label"]] = rec
    if not items:
        die("the calibration set contains no items")
    return items


def rater_id_from(path):
    b = os.path.basename(path)
    if b.endswith(".json"):
        b = b[:-5]
    for pre in ("answers-", "answers_"):
        if b.startswith(pre):
            return b[len(pre):]
    return "operator" if b == "answers" else b


# ── Cohen's kappa (P78's implementation, unchanged) ───────────────────────────
def cohen_kappa(a, b, weights=None):
    cats = sorted(set(a) | set(b))
    n = len(a)
    if n == 0 or len(cats) < 2:
        return None
    idx = {c: i for i, c in enumerate(cats)}
    k = len(cats)
    O = [[0] * k for _ in range(k)]
    for x, y in zip(a, b):
        O[idx[x]][idx[y]] += 1
    ra = [sum(O[i]) for i in range(k)]
    cb = [sum(O[i][j] for i in range(k)) for j in range(k)]
    if weights == "quadratic":
        Wt = [[((cats[i] - cats[j]) ** 2) / ((cats[-1] - cats[0]) ** 2)
               for j in range(k)] for i in range(k)]
    else:
        Wt = [[0 if i == j else 1 for j in range(k)] for i in range(k)]
    num = sum(Wt[i][j] * O[i][j] for i in range(k) for j in range(k))
    den = sum(Wt[i][j] * ra[i] * cb[j] / n for i in range(k) for j in range(k))
    if den == 0:
        return None
    return 1 - num / den


# ── Krippendorff's alpha ──────────────────────────────────────────────────────
def krippendorff_alpha(units, metric="interval"):
    """`units` is a list of lists of numeric grades — one list per ITEM, holding
    every rating that item received. Items with fewer than 2 ratings contribute
    nothing, which is how alpha handles an incomplete design natively.

    Alpha is used and not Fleiss' kappa because the realistic shape of guild
    judging is a VARIABLE number of raters per item with missing values (P77
    3.5): "the only one that handles any number of raters, any measurement
    level, and missing data". Fleiss requires a fixed rater count; Cohen
    requires exactly two and no gaps.
    """
    coinc = collections.Counter()
    for vals in units:
        m = len(vals)
        if m < 2:
            continue
        for i in range(m):
            for j in range(m):
                if i == j:
                    continue
                coinc[(vals[i], vals[j])] += 1.0 / (m - 1)
    n = sum(coinc.values())
    if n < 2:
        return None
    marg = collections.Counter()
    for (c, k), v in coinc.items():
        marg[c] += v
    cats = sorted(marg)
    if len(cats) < 2:
        # No variance anywhere. Alpha is undefined, NOT 1.0. Returning 1.0 here
        # would score "every rater said 2 to everything" as perfect reliability.
        return None

    if metric == "interval":
        def d2(c, k):
            return (c - k) ** 2
    else:                                   # ordinal
        cum = {}
        run = 0.0
        for c in cats:
            cum[c] = run + marg[c] / 2.0
            run += marg[c]

        def d2(c, k):
            lo, hi = (c, k) if c <= k else (k, c)
            s = sum(marg[g] for g in cats if lo <= g <= hi)
            return (s - (marg[lo] + marg[hi]) / 2.0) ** 2

    do = sum(coinc[(c, k)] * d2(c, k) for c in cats for k in cats) / n
    de = sum(marg[c] * marg[k] * d2(c, k)
             for c in cats for k in cats) / (n * (n - 1))
    if de == 0:
        return None
    return 1 - do / de


# ── cluster bootstrap over LEARNING POINTS ────────────────────────────────────
# The learning point is the unit of dependence (P78 5.2 established it: four
# candidates of one LP are judged together, in one context, against one piece of
# prose). Resampling ITEMS would treat those four as independent and report a CI
# narrower than the data supports — the "asserts less than it looks" shape.
def cluster_boot(lp_ids, fn, reps, seed=17):
    rng = random.Random(seed)
    lps = sorted(set(lp_ids))
    out = []
    for _ in range(reps):
        draw = [lps[rng.randrange(len(lps))] for _ in range(len(lps))]
        v = fn(draw)
        if v is not None and not (isinstance(v, float) and math.isnan(v)):
            out.append(v)
    if len(out) < reps * 0.5:
        return None
    out.sort()
    return (out[int(0.025 * len(out))], out[int(0.975 * len(out))])


def straddle(point, ci, thresholds):
    if point is None:
        return "CANNOT VERIFY (statistic undefined)", True
    if ci is None:
        return "CANNOT VERIFY (bootstrap degenerate)", True
    for t in thresholds:
        if ci[0] < t < ci[1]:
            return ("CANNOT VERIFY (95%% CI [%.3f, %.3f] straddles the %.2f "
                    "threshold)" % (ci[0], ci[1], t)), True
    return None, False


def r3(x):
    return None if x is None else round(x, 4)


def rci(ci):
    return None if ci is None else [round(ci[0], 4), round(ci[1], 4)]


# ── loading one rater ─────────────────────────────────────────────────────────
def load_rater(path, items, packet_dir, rep):
    """Returns (rater_id, {canonical_label: answer}, notes).

    THE JOIN IS THE DANGEROUS PART. Item labels are POSITIONAL (`E5.01-1` is
    "whatever landed first after the shuffle"), and P79 gives every rater their
    OWN presentation seed so that order effects are not correlated across the
    panel. That makes the label rater-relative. A scorer that joined on the raw
    label would then compare rater A's answer about one passage with rater B's
    answer about a different one and report the resulting garbage as
    disagreement.

    So: with a packet, join through (lp_id, blind_key) — the candidate's own
    identity. Without a packet, the labels MUST be the canonical ones, and if
    they are not the run REFUSES. A missing packet is never assumed benign.
    """
    rid = rater_id_from(path)
    try:
        ans = json.load(open(path))
    except Exception as e:
        die("rater '%s': cannot read %s: %s" % (rid, path, e), rep)
    if not isinstance(ans, dict):
        die("rater '%s': %s is not a json object" % (rid, path), rep)

    pkt_path = os.path.join(packet_dir or os.path.dirname(os.path.abspath(path)),
                            "calibration-packet-%s.json" % rid)
    notes = {}
    if os.path.exists(pkt_path):
        try:
            pkt = json.load(open(pkt_path))
        except Exception as e:
            die("rater '%s': packet %s unreadable: %s" % (rid, pkt_path, e), rep)
        by_cand = {(v["lp_id"], v["blind_key"]): k for k, v in items.items()}
        remap, unresolved = {}, []
        for lbl, ref in pkt.get("items", {}).items():
            key = (ref.get("lp_id"), ref.get("blind_key"))
            if key not in by_cand:
                unresolved.append(lbl)
                continue
            remap[lbl] = by_cand[key]
        if unresolved:
            die("rater '%s': packet %s names %d item(s) that are not in the "
                "calibration set (first: %s). A packet that does not resolve is "
                "a join nobody can check."
                % (rid, pkt_path, len(unresolved), unresolved[0]), rep)
        out = {}
        for lbl, val in ans.items():
            if lbl not in remap:
                die("rater '%s': answer '%s' is not in that rater's packet"
                    % (rid, lbl), rep)
            out[remap[lbl]] = val
        notes["packet"] = os.path.basename(pkt_path)
        notes["presentation_seed"] = pkt.get("presentation_seed")
        notes["excluded_lps"] = pkt.get("excluded_lps", [])
        return rid, out, notes

    # No packet: the canonical ordering is the only admissible reading.
    unknown = sorted(set(ans) - set(items))
    if unknown:
        die("rater '%s': no packet at %s, and %d answer label(s) are not "
            "canonical calibration-set labels (first: %s). Refusing to guess "
            "which candidate was graded — score it with its packet or not at "
            "all." % (rid, pkt_path, len(unknown), unknown[0]), rep)
    notes["packet"] = None
    notes["presentation_seed"] = "canonical (calibration_set.json order)"
    notes["excluded_lps"] = []
    return rid, dict(ans), notes


def main():
    argv = sys.argv[1:]
    cal_path = None
    packet_dir = None
    out_path = None
    boot = BOOT
    files = []
    for a in argv:
        if a.startswith("--cal="):
            cal_path = os.path.expanduser(a[6:])
        elif a.startswith("--packet-dir="):
            packet_dir = os.path.expanduser(a[13:])
        elif a.startswith("--boot="):
            boot = int(a[7:])
        elif a.startswith("--out="):
            out_path = os.path.expanduser(a[6:])
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        elif a.startswith("-"):
            die("unknown option: %s" % a)
        else:
            files.append(os.path.expanduser(a))

    if not cal_path or not files:
        print(__doc__)
        sys.exit(2)

    items = load_calibration(cal_path)
    rep = {"instrument": "P79 multi-rater generalisation of P78 4.4",
           "gates_committed_in": "Gates 1-4: P78 4.4, verbatim. Gates 0, 1b, 3b: "
                                 "P79 4, committed before any panel existed.",
           "calibration_set": os.path.basename(cal_path),
           "n_items_in_set": len(items)}

    # ── load the panel ────────────────────────────────────────────────────────
    raters, notes = {}, {}
    for f in files:
        rid, ans, note = load_rater(f, items, packet_dir, rep)
        if rid in raters:
            die("rater id '%s' supplied twice — one answers file per rater" % rid, rep)
        raters[rid] = ans
        notes[rid] = note
    rep["raters_submitted"] = sorted(raters)

    # ── per-rater pairing against the machine ─────────────────────────────────
    per = {}
    incomplete = []
    for rid, ans in raters.items():
        pairs, abst, missing = [], [], []
        for lbl, it in items.items():
            o = ans.get(lbl)
            m = it["machine_grade"]
            if o is None:
                missing.append(lbl)
                continue
            if o in ABST or m in ABST:
                abst.append((lbl, m, o, it["stratum"], it["lp_id"]))
                continue
            try:
                pairs.append({"label": lbl, "lp_id": it["lp_id"],
                              "stratum": it["stratum"],
                              "band": it["duration_band"],
                              "m": int(m), "o": int(o)})
            except (TypeError, ValueError):
                die("rater '%s': answer for '%s' is neither a 0-3 grade nor an "
                    "abstention: %r" % (rid, lbl, o), rep)
        for p in pairs:
            if p["o"] not in NUM:
                die("rater '%s': answer for '%s' is out of range: %r"
                    % (rid, p["label"], p["o"]), rep)
        per[rid] = {"pairs": pairs, "abstentions": abst, "missing": missing,
                    "packet": notes[rid]["packet"],
                    "presentation_seed": notes[rid]["presentation_seed"],
                    "excluded_lps": notes[rid]["excluded_lps"]}
        if missing:
            incomplete.append(rid)

    # ── integrity: excluded, and named ────────────────────────────────────────
    excluded = [r for r in per if len(per[r]["pairs"]) < MIN_PAIRS]
    for r in excluded:
        per[r]["excluded_reason"] = ("fewer than %d scoreable pairs (%d)"
                                     % (MIN_PAIRS, len(per[r]["pairs"])))
    active = [r for r in sorted(per) if r not in excluded]
    rep["raters_excluded"] = {r: per[r]["excluded_reason"] for r in excluded}
    rep["raters_scored"] = active
    rep["n_raters_scored"] = len(active)
    rep["per_rater"] = {
        r: {"n_scored_pairs": len(per[r]["pairs"]),
            "n_abstention_pairs_excluded": len(per[r]["abstentions"]),
            "n_missing": len(per[r]["missing"]),
            "packet": per[r]["packet"],
            "presentation_seed": per[r]["presentation_seed"],
            "excluded_lps": per[r]["excluded_lps"]}
        for r in sorted(per)}

    if not active:
        die("no rater has %d scoreable pairs" % MIN_PAIRS, rep)

    # ── integrity: nobody agrees this well by accident ────────────────────────
    collusion = []
    for i, a in enumerate(active):
        for b in active[i + 1:]:
            A = {p["label"]: p["o"] for p in per[a]["pairs"]}
            B = {p["label"]: p["o"] for p in per[b]["pairs"]}
            sh = sorted(set(A) & set(B))
            if len(sh) < COLLUSION_MIN_SHARED:
                continue
            exact = sum(1 for l in sh if A[l] == B[l]) / len(sh)
            if exact >= COLLUSION_EXACT:
                collusion.append({"raters": [a, b], "shared_items": len(sh),
                                  "exact_agreement": round(exact, 4)})
    if collusion:
        rep["integrity_duplicate_raters"] = collusion
        die("DUPLICATE-RATER — %s agree on %.1f%% of shared items exactly. The "
            "highest exact agreement ever measured on this instrument is 0.893 "
            "[0.866, 0.923], between instances of ONE model on identical items "
            "(P78 5.2.3). Independent humans do not exceed that. Treat these as "
            "one submission, not two, and find out how it happened."
            % (" and ".join(collusion[0]["raters"]),
               100 * collusion[0]["exact_agreement"]), rep)

    nh = len(active)

    # ═══ GATE 0 — panel coherence (humans only; the machine is NOT a member) ═══
    # Including the machine here would be the circularity the whole exercise
    # exists to break: a panel whose coherence is propped up by the thing being
    # tested cannot testify about it.
    g0 = {"armed": nh >= 2, "n_human_raters": nh,
          "note": "humans only — the machine is deliberately not a panel member"}
    g0_verdict = "NOT ARMED (1 rater; arms at 2)"
    g0_cap_binary = False
    g0_instrument_failure = False
    if nh >= 2:
        by_item = collections.defaultdict(list)
        item_lp = {}
        for r in active:
            for p in per[r]["pairs"]:
                by_item[p["label"]].append(p["o"])
                item_lp[p["label"]] = p["lp_id"]
        multi = {l: v for l, v in by_item.items() if len(v) >= 2}
        g0["n_items_with_2plus_ratings"] = len(multi)

        def a_for(metric):
            def f(draw):
                units = []
                for lp in draw:
                    for l, v in multi.items():
                        if item_lp[l] == lp:
                            units.append(v)
                return krippendorff_alpha(units, metric)
            return f

        lp_pool = sorted({item_lp[l] for l in multi})
        a_int = krippendorff_alpha(list(multi.values()), "interval")
        a_ord = krippendorff_alpha(list(multi.values()), "ordinal")
        ci0 = cluster_boot(lp_pool, a_for("interval"), boot) if multi else None
        g0["alpha_interval"] = r3(a_int)
        g0["alpha_interval_ci95"] = rci(ci0)
        g0["alpha_ordinal"] = r3(a_ord)
        g0["comparator_machine_panel_alpha_interval"] = 0.921
        g0["comparator_source"] = ("P78 5.2.3, 16 instances of one model on "
                                   "identical items, CI [0.887, 0.947]")

        # where the panel disagrees — the diagnosis when Gate 0 fails
        bd = collections.Counter()
        pairs_seen = 0
        for l, v in multi.items():
            for i in range(len(v)):
                for j in range(i + 1, len(v)):
                    pairs_seen += 1
                    d = abs(v[i] - v[j])
                    if d == 0:
                        bd["agree"] += 1
                    elif d > 1:
                        bd["more_than_one_grade_apart"] += 1
                    else:
                        bd["%d<->%d" % (min(v[i], v[j]), max(v[i], v[j]))] += 1
        g0["paired_human_comparisons"] = pairs_seen
        g0["disagreement_composition"] = dict(bd)
        g0["exact_agreement"] = (round(bd["agree"] / pairs_seen, 4)
                                 if pairs_seen else None)

        msg, blind = straddle(a_int, ci0, [G0_COHERENT, G0_FLOOR])
        if blind:
            g0_verdict = msg
        elif a_int >= G0_COHERENT:
            g0_verdict = "COHERENT — the panel is a usable reference standard"
        elif a_int >= G0_FLOOR:
            g0_verdict = ("SCREENING-ONLY — the panel agrees about what is worth "
                          "a human's time but not about how relevant; Gate 2 is "
                          "capped at BINARY")
            g0_cap_binary = True
        else:
            g0_verdict = ("INSTRUMENT FAILURE — alpha %.3f is below the %.2f "
                          "floor. NOTHING follows about the machine and the "
                          "labels are NOT discarded: the panel did not resolve. "
                          "Fix the rubric row the disagreement composition names, "
                          "re-train, re-run." % (a_int, G0_FLOOR))
            g0_instrument_failure = True
    g0["verdict"] = g0_verdict
    rep["gate0_panel_coherence"] = g0

    # ── shared machinery for the per-rater gates ──────────────────────────────
    def per_rater_stat(r, subset_lps, fn):
        ps = [p for p in per[r]["pairs"]] if subset_lps is None else \
             [p for lp in subset_lps for p in per[r]["pairs"] if p["lp_id"] == lp]
        if len(ps) < 2:
            return None
        return fn(ps)

    def mean_over_raters(subset_lps, fn):
        vals = [per_rater_stat(r, subset_lps, fn) for r in active]
        vals = [v for v in vals if v is not None]
        return statistics.mean(vals) if vals else None

    all_lps = sorted({p["lp_id"] for r in active for p in per[r]["pairs"]})

    def k_screen(ps):
        return cohen_kappa([1 if p["m"] >= 2 else 0 for p in ps],
                           [1 if p["o"] >= 2 else 0 for p in ps])

    def k_graded(ps):
        return cohen_kappa([p["m"] for p in ps], [p["o"] for p in ps],
                           "quadratic")

    # ═══ GATE 1 — screening agreement ═════════════════════════════════════════
    # The panel statistic is the MEAN OF PER-RATER kappas, never a kappa over
    # pooled rater-machine pairs. Pooling would count three ratings of one item
    # as three independent observations and narrow the CI on a dependence the
    # design deliberately created.
    k1_each = {r: r3(per_rater_stat(r, None, k_screen)) for r in active}
    k1 = mean_over_raters(None, k_screen)
    ci1 = cluster_boot(all_lps, lambda d: mean_over_raters(d, k_screen), boot)
    msg, blind = straddle(k1, ci1, [G1_PASS, G1_PARTIAL])
    if blind:
        g1v = msg
    elif k1 >= G1_PASS:
        g1v = "PASS"
    elif k1 >= G1_PARTIAL:
        g1v = "PARTIAL — deltas only, may NOT certify a shortlist"
    else:
        g1v = "DISCARD"
    rep["gate1_screening_kappa"] = {"mean_kappa": r3(k1), "ci95": rci(ci1),
                                    "per_rater": k1_each, "verdict": g1v}

    # ═══ GATE 1b — is the machine an outlier on the panel? ════════════════════
    # The question a single assessor CANNOT ask. A machine that agrees with
    # humans about as well as humans agree with each other is behaving like a
    # panel member; one that sits below every human is not, and the same kappa
    # can mean either depending on how well the humans did.
    g1b = {"armed": nh >= G1B_MIN_RATERS, "margin": G1B_MARGIN,
           "arms_at_n_human_raters": G1B_MIN_RATERS}
    if nh < G1B_MIN_RATERS:
        g1b["verdict"] = ("NOT ARMED (%d human rater(s); arms at %d). With two "
                          "humans the 'lowest human' is scored partly against "
                          "the machine itself, so the comparison is not "
                          "independent of what it is testing."
                          % (nh, G1B_MIN_RATERS))
    else:
        members = {}
        for r in active:
            members[r] = {p["label"]: (1 if p["o"] >= 2 else 0)
                          for p in per[r]["pairs"]}
        members["__machine__"] = {p["label"]: (1 if p["m"] >= 2 else 0)
                                  for p in per[active[0]]["pairs"]}
        for r in active[1:]:
            for p in per[r]["pairs"]:
                members["__machine__"].setdefault(p["label"],
                                                  1 if p["m"] >= 2 else 0)
        means = {}
        for a in members:
            ks = []
            for b in members:
                if a == b:
                    continue
                sh = sorted(set(members[a]) & set(members[b]))
                if len(sh) < MIN_PAIRS:
                    continue
                k = cohen_kappa([members[a][l] for l in sh],
                                [members[b][l] for l in sh])
                if k is not None:
                    ks.append(k)
            means[a] = statistics.mean(ks) if ks else None
        hm = {r: v for r, v in means.items()
              if r != "__machine__" and v is not None}
        mm = means.get("__machine__")
        g1b["mean_pairwise_kappa"] = {k: r3(v) for k, v in means.items()}
        if mm is None or not hm:
            g1b["verdict"] = "CANNOT VERIFY — too few shared items to compare members"
        else:
            lo = min(hm.values())
            g1b["lowest_human_mean"] = r3(lo)
            g1b["machine_mean"] = r3(mm)
            if mm < lo - G1B_MARGIN:
                g1b["verdict"] = ("DISCARD — the machine agrees with the panel "
                                  "%.3f below its least-agreeing human (limit "
                                  "%.2f). It is not a member of this panel; it "
                                  "is an outlier on it." % (lo - mm, G1B_MARGIN))
            else:
                g1b["verdict"] = ("PASS — the machine sits within %.2f of the "
                                  "least-agreeing human" % G1B_MARGIN)
    rep["gate1b_machine_not_an_outlier"] = g1b

    # ═══ GATE 2 — graded agreement ════════════════════════════════════════════
    k2_each = {r: r3(per_rater_stat(r, None, k_graded)) for r in active}
    k2 = mean_over_raters(None, k_graded)
    ci2 = cluster_boot(all_lps, lambda d: mean_over_raters(d, k_graded), boot)
    msg, blind = straddle(k2, ci2, [G2_GRADED, G2_BINARY])
    if blind:
        g2v = msg
    elif k2 >= G2_GRADED:
        g2v = "GRADED METRICS PERMITTED"
    elif k2 >= G2_BINARY:
        g2v = "BINARY COLLAPSE ONLY — graded metrics REFUSED"
    else:
        g2v = "DISCARD"
    if g0_cap_binary and g2v == "GRADED METRICS PERMITTED":
        g2v = ("BINARY COLLAPSE ONLY — CAPPED BY GATE 0. The machine tracks the "
               "panel's grades, but the panel does not agree with itself about "
               "them, so a graded metric would inherit an agreement that does "
               "not exist.")
    rep["gate2_weighted_kappa"] = {"mean_kappa_w": r3(k2), "ci95": rci(ci2),
                                   "per_rater": k2_each, "verdict": g2v}

    # ═══ GATE 3 — directional bias, and GATE 3b — scale dispersion ════════════
    bias_each = {}
    for r in active:
        d = [p["o"] - p["m"] for p in per[r]["pairs"]]
        bias_each[r] = statistics.mean(d) if d else None
    bvals = [v for v in bias_each.values() if v is not None]
    bias = statistics.mean(bvals) if bvals else None
    if bias is None:
        g3v = "CANNOT VERIFY — no scoreable pairs"
    elif abs(bias) <= G3_MAX_BIAS:
        g3v = "PASS"
    else:
        g3v = ("FAIL — the machine is systematically %s by %.2f grades against "
               "the panel" % ("GENEROUS" if bias < 0 else "HARSH", abs(bias)))
    rep["gate3_directional_bias"] = {
        "panel_mean_signed_difference_rater_minus_machine": r3(bias),
        "per_rater": {k: r3(v) for k, v in bias_each.items()},
        "verdict": g3v}

    # Gate 3b exists because Gate 3 can pass VACUOUSLY on a panel: one rater a
    # whole grade generous and another a whole grade harsh average to zero bias
    # while agreeing with nobody. That cancellation is invisible to every
    # statistic P78 committed, and it is the single new failure mode a panel
    # introduces.
    g3b = {"armed": nh >= 2, "max_spread_grades": G3B_MAX_SPREAD}
    if nh < 2:
        g3b["verdict"] = "NOT ARMED (1 rater; arms at 2)"
    else:
        sd = statistics.pstdev(bvals)
        g3b["between_rater_sd_of_signed_bias"] = r3(sd)
        g3b["range"] = [r3(min(bvals)), r3(max(bvals))]
        if sd <= G3B_MAX_SPREAD:
            g3b["verdict"] = "PASS — the raters are using one scale"
        else:
            g3b["verdict"] = ("FAIL — the raters' own offsets differ by sd %.2f "
                              "grades (limit %.2f). They are not using one "
                              "scale, so the panel mean in Gate 3 is a "
                              "cancellation, not an agreement. Remedy is rater "
                              "training, NOT a change to the labels." % (sd, G3B_MAX_SPREAD))
    rep["gate3b_rater_scale_dispersion"] = g3b

    # ═══ GATE 4 — the control kill switch, now CORROBORATED ═══════════════════
    # One human's error must not delete 3,309 labels. An error the panel AGREES
    # on must. So an item counts toward the kill switch only when a majority of
    # scoreable raters is off by >=2 on it. At N=1 the majority is that one
    # rater and the gate is byte-for-byte P78 4.4's.
    g4 = {"limit_items": G4_MAX_SEVERE, "min_control_pairs_per_rater": G4_MIN_CONTROL_PAIRS}
    ctrl_ok, ctrl_thin = [], {}
    for r in active:
        c = [p for p in per[r]["pairs"] if p["stratum"].startswith("C-control")]
        if len(c) < G4_MIN_CONTROL_PAIRS:
            ctrl_thin[r] = len(c)
        else:
            ctrl_ok.append(r)
    g4["raters_with_too_few_controls"] = ctrl_thin
    g4["raters_counted"] = ctrl_ok
    if not ctrl_ok:
        g4["verdict"] = ("CANNOT VERIFY — no rater has %d scoreable control "
                         "pairs" % G4_MIN_CONTROL_PAIRS)
        g4["severe_items"] = []
    else:
        # STRICT majority: floor(N/2) + 1. N=1 -> 1, N=2 -> 2, N=3 -> 2, N=4 -> 3.
        #
        # `(N + 1) // 2` is the WRONG formula here and it was shipped once. At
        # N = 2 it evaluates to 1, so a single rater's bad morning on three
        # control items DISCARDS the whole label set while the other rater
        # agrees with the machine on every control — i.e. no corroboration at
        # all, at exactly the panel size this proposal designs for. The promise
        # made in P79 3.8, in the packet's own closing text and in the member
        # guide is "a MAJORITY of raters", and one of two is not a majority.
        need = len(ctrl_ok) // 2 + 1
        g4["corroboration_required_raters"] = need
        g4["corroboration_rule"] = ("strict majority of scoreable raters "
                                    "(floor(N/2)+1): %d of %d"
                                    % (need, len(ctrl_ok)))
        sev_by_rater = collections.Counter()
        sev_count = collections.Counter()
        for r in ctrl_ok:
            for p in per[r]["pairs"]:
                if not p["stratum"].startswith("C-control"):
                    continue
                if abs(p["m"] - p["o"]) >= 2:
                    sev_by_rater[r] += 1
                    sev_count[p["label"]] += 1
        severe = sorted(l for l, n in sev_count.items() if n >= need)
        g4["severe_disagreements_per_rater"] = dict(sev_by_rater)
        g4["severe_items_corroborated"] = severe
        # A single rogue rater must be VISIBLE even when corroboration protects
        # the set from them. Dropping their file to make a gate pass would be
        # the swallowed-verdict shape, so they are named and kept.
        counts = [sev_by_rater.get(r, 0) for r in ctrl_ok]
        med = statistics.median(counts) if counts else 0
        outliers = [r for r in ctrl_ok if sev_by_rater.get(r, 0) >= med + 5]
        if outliers:
            g4["outlier_raters"] = {
                r: ("%d severe control disagreements against a panel median of "
                    "%g — reported, NOT dropped; investigate the rater, not the "
                    "labels" % (sev_by_rater.get(r, 0), med)) for r in outliers}
        if len(severe) > G4_MAX_SEVERE:
            g4["verdict"] = ("DISCARD — %d control item(s) on which %d+ rater(s) "
                             "disagree with the machine by >=2 grades (limit %d). "
                             "Correlated error where the judge was certain is a "
                             "fault, not noise."
                             % (len(severe), need, G4_MAX_SEVERE))
        else:
            g4["verdict"] = ("PASS (%d corroborated severe item(s) of limit %d)"
                             % (len(severe), G4_MAX_SEVERE))
    rep["gate4_controls_corroborated"] = g4

    # ── the fifth reported quantity: abstentions (never a gate) ───────────────
    ab = {"machine_rate_in_full_label_set": 0.0088,
          "machine_rate_source": "P78 3.1 — 29 of 3,309 judgements"}
    sets = {}
    for r in active:
        c = collections.Counter(o for _, _, o, _, _ in per[r]["abstentions"]
                                if o in ABST)
        n = len(per[r]["pairs"]) + len(per[r]["abstentions"])
        ab[r] = {"counts": dict(c), "rate": round(sum(c.values()) / n, 4) if n else None}
        sets[r] = {l for l, _, o, _, _ in per[r]["abstentions"] if o in ABST}
    if nh >= 2:
        # Same rate on disjoint items means the TAXONOMY is not shared even
        # though the frequency looks agreed. Only a panel can show this.
        j = {}
        for i, a in enumerate(active):
            for b in active[i + 1:]:
                u = sets[a] | sets[b]
                j["%s|%s" % (a, b)] = (round(len(sets[a] & sets[b]) / len(u), 4)
                                       if u else None)
        ab["jaccard_of_abstention_sets"] = j
        ab["reading"] = ("equal rates on disjoint items mean the abstention "
                         "TAXONOMY is not shared. Fix the taxonomy, not the grades.")
    rep["abstentions_reported_not_gated"] = ab

    # ── the routing queue: abstentions are ROUTES, not gaps ───────────────────
    routes = []
    for r in active:
        for lbl, m, o, stratum, lp in per[r]["abstentions"]:
            if o in ABST:
                routes.append({"label": lbl, "lp_id": lp, "rater": r,
                               "route": "THEOLOGY" if o == "ABSTAIN-DOCTRINE"
                                        else "PEDAGOGY",
                               "machine_said": m})
    rep["routes"] = routes
    rep["routes_note"] = ("A routed item is a QUESTION for another guild, not a "
                          "grade. Its answer is SOUND / UNSOUND / NEEDS-CONTEXT "
                          "on the admissibility plane and is never folded back "
                          "into any kappa (P78 3: an abstention is not a grade).")

    # ── strata and bands ──────────────────────────────────────────────────────
    rep["per_stratum"] = {}
    for s in sorted({p["stratum"] for r in active for p in per[r]["pairs"]}):
        sub = [p for r in active for p in per[r]["pairs"] if p["stratum"] == s]
        rep["per_stratum"][s] = {
            "n_rater_item_pairs": len(sub),
            "exact_agreement": round(sum(1 for p in sub if p["m"] == p["o"]) / len(sub), 3),
            "mean_signed_diff": round(statistics.mean([p["o"] - p["m"] for p in sub]), 3)}
    rep["per_duration_band"] = {}
    for b in sorted({p["band"] for r in active for p in per[r]["pairs"]}):
        sub = [p for r in active for p in per[r]["pairs"] if p["band"] == b]
        rep["per_duration_band"][b] = {
            "n_rater_item_pairs": len(sub),
            "mean_signed_diff": round(statistics.mean([p["o"] - p["m"] for p in sub]), 3)}
    conf = collections.Counter((p["m"], p["o"]) for r in active
                               for p in per[r]["pairs"])
    rep["confusion_machine_x_panel"] = {"%d->%d" % k: v
                                        for k, v in sorted(conf.items())}

    # ── the overall verdict ───────────────────────────────────────────────────
    # ORDER MATTERS AND IS THE FAIL-CLOSED DIRECTION.
    # Gate 0 dominates everything: if the panel did not resolve, no verdict
    # about the machine is admissible, INCLUDING a bad one. A run that reported
    # DISCARD off an incoherent panel would have deleted the labels on the
    # strength of a measurement it did not take.
    armed = [g1v, g2v, rep["gate3_directional_bias"]["verdict"],
             g4["verdict"], g3b["verdict"], g1b["verdict"]]
    armed = [v for v in armed if not v.startswith("NOT ARMED")]

    if g0_instrument_failure:
        rep["OVERALL"] = ("CANNOT VERIFY — INSTRUMENT FAILURE at Gate 0. The "
                          "panel is not a reference standard, so nothing "
                          "follows about the machine. The labels are NOT "
                          "discarded and P78 4.5 is NOT triggered.")
        code = 2
    elif any(v.startswith("DISCARD") for v in armed):
        rep["OVERALL"] = "DISCARD — delete the label-set directory (P78 4.5)"
        code = 1
    elif g0["verdict"].startswith("CANNOT VERIFY") or \
            any(v.startswith("CANNOT VERIFY") for v in armed):
        rep["OVERALL"] = "CANNOT VERIFY — grade AMBER, do not treat as a pass"
        code = 2
    elif any(v.startswith("FAIL") for v in armed):
        rep["OVERALL"] = "FAIL — recalibrate before any use"
        code = 1
    elif g1v == "PASS" and g2v == "GRADED METRICS PERMITTED":
        rep["OVERALL"] = "PASS — silver set usable, graded metrics permitted"
        code = 0
    else:
        rep["OVERALL"] = "PARTIAL — usable only as stated by the individual gates"
        code = 0

    if incomplete:
        rep["OVERALL"] = ("CANNOT VERIFY — rater(s) %s left items unanswered"
                          % ", ".join(sorted(incomplete)))
        rep["missing_by_rater"] = {r: per[r]["missing"][:20] for r in incomplete}
        code = 2

    rep["exit"] = code
    blob = json.dumps(rep, indent=1, default=str)
    if out_path:
        open(out_path, "w").write(blob)
    print(blob)
    sys.exit(code)


if __name__ == "__main__":
    main()
