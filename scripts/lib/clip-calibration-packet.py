#!/usr/bin/env python3
"""
Build ONE calibration packet per guild rater — nwp/ops#348, P79.

WHY A PER-RATER PACKET AND NOT ONE SHARED DOCUMENT
--------------------------------------------------
P78's `render_calibration.py` renders a single `CALIBRATION-SET.md` for a single
assessor. Handing that same file to three people would silently break two things.

1. **Correlated presentation order.** One shuffle for everybody means every
   rater meets the same passage in the same slot, so order and fatigue effects
   are IDENTICAL across the panel. Shared systematic error is exactly what P78
   5.2.7 says a same-model panel cannot see in itself, and it would inflate
   Gate 0's alpha for a reason that has nothing to do with the judgement. Each
   rater therefore gets their own seed.
2. **Anti-self-review has nowhere to live.** `media-guild.yml` declares
   `pairing.anti_self_review: true # pair never includes the task author
   (ADR-0006)`, and P75 3.1 measured it as NOT BUILT ("grep returns nothing").
   An exclusion applied at RENDER time still ships the item; applied at BUILD
   time the item is not in the rater's packet at all.

BLIND BY CONSTRUCTION, NOT BY TEMPLATE
--------------------------------------
The blinding is a property of the ARTEFACT, not of the page. A template that
merely declines to print a field still ships it, and the estate has already
recorded the consequence of the opposite habit: `ApplyDecisionForm.php:44-51`
renders the author's name and endorsement count to the person deciding, while
the spec says `blind: true`. Here the member-facing document is built from a
whitelist and then asserted against it, so there is nothing to reveal.

Withheld: rank, ranker, score, q_parts, episode, machine grade, machine
rationale, machine confidence, the source pool, the catalogue's current
`video:` block, AND the learning point's catalogue address (`lp_id`) and its
course title. The last two are new here and they are also a PARITY FIX: per
`JUDGE-PROMPT.md`, the machine judge saw "the LP (title, one-sentence summary,
~200 words of body prose)" and nothing else, while `CALIBRATION-SET.md` prints
`lp_id` and `Course:` to the human. That asymmetry both breaks parity and hands
the reader a `grep` key into the catalogue.

Stated honestly: a rater who wants to defeat this can search the LP's prose. The
defence is structural in the payload, attested by the rater, and DETECTABLE
afterwards — not perfect at the human.

RIGHTS (P78 6) — ENFORCED, NOT REQUESTED
----------------------------------------
The `.md` carries <=600-character excerpts of a `derivative-cleared-pending`,
password-gated corpus, and `nwp/nwp` is publicly mirrored (ADR-0039). This
builder REFUSES to write a member-facing document anywhere inside the engine
repository. The join map and the answers template carry no corpus text and are
safe anywhere; they are written beside the document regardless.

Usage:
  clip-calibration-packet.py --cal=<calibration_set.json> --out=<DIR>
                             --rater=<id> [--rater=<id> ...]
                             [--exclusions=<json>] [--min-items=N] [--json]

  --exclusions  {"rater_id": ["A1.01", "B2.03"], ...}  learning points that
                rater authored or suggested a candidate for (ADR-0006).
"""
import collections
import hashlib
import json
import os
import random
import sys

SALT = "nwp-calibration-panel-v1"
EXCERPT_CAP = 600          # the estate bound, P78 6
MIN_ITEMS = 60             # half a sitting; below this a packet is not a packet
MIN_CONTROL_ITEMS = 20     # Gate 4 reports CANNOT VERIFY below this (P78 4.4)

# What a member-facing item may carry. Anything else is a leak.
RENDER_ITEM_KEYS = {"label", "duration_band", "excerpt"}
RENDER_LP_KEYS = {"alias", "lp_title", "lp_summary", "lp_text", "items"}


def die(msg, code=2):
    print(json.dumps({"error": msg, "exit": code}, indent=1))
    sys.exit(code)


def build(cal, rater, excluded):
    """Deterministic per-rater view. Same rater + same set => same packet."""
    lps = [lp for lp in cal if lp["lp_id"] not in excluded]
    rng = random.Random(hashlib.sha256(
        (SALT + "|" + rater).encode()).hexdigest())
    order = list(range(len(lps)))
    rng.shuffle(order)
    out, jmap = [], {}
    for pos, i in enumerate(order, 1):
        lp = lps[i]
        alias = "LP%02d" % pos
        items = list(lp["items"])
        r2 = random.Random(hashlib.sha256(
            (SALT + "|" + rater + "|" + lp["lp_id"]).encode()).hexdigest())
        r2.shuffle(items)
        rendered = []
        for n, it in enumerate(items, 1):
            label = "%s-%d" % (alias, n)
            ex = it["excerpt"]
            if len(ex) > EXCERPT_CAP:
                ex = ex[:EXCERPT_CAP].rsplit(" ", 1)[0] + " …"
            rendered.append({"label": label,
                             "duration_band": it["duration_band"],
                             "excerpt": ex})
            jmap[label] = {"lp_id": lp["lp_id"], "blind_key": it["blind_key"]}
        out.append({"alias": alias, "lp_title": lp["lp_title"],
                    "lp_summary": lp["lp_summary"], "lp_text": lp.get("lp_text", ""),
                    "items": rendered})
    return out, jmap


HEAD = """# Clip calibration — %(n)d learning points, %(j)d judgements, 60–90 minutes

*Packet for **%(rater)s**. Your ordering is yours alone; comparing sheets with
another member does not help and makes both sheets unusable.*

**What this is.** A machine has graded thousands of candidate passages against the
curriculum's learning points. Those labels are **silver, not gold** — useful only if
humans agree with them often enough. Your answers are half of that test. The other
half is whether you and the other raters agree with **each other**, which is the one
thing no amount of machine measurement can supply.

**The thresholds were committed before you judged** (P78 §4.4, P79 §4). **The test can
fail**, and every way it can fail is written down in advance. That is the point.

**Rights.** Everything below is a short excerpt (≤%(cap)d characters) of a
password-gated corpus. Do not copy it anywhere.

---

## How to grade

Each learning point gives you **4 passages**, shown as short excerpts sampled at fixed
points across the clip (start / middle / end) — *not* picked for relevance. A long clip
is genuinely under-sampled and you are seeing a fraction of it. **Grade what you can
see.**

| grade | means |
|---|---|
| **3** | **This is the passage.** It states or teaches this learning point's specific claim. A learner dropped here hears the point being made. |
| **2** | **Relevant.** Genuinely about this subject and would support the point — but it does not make *this* claim. |
| **1** | **Related, not this point.** Same territory (prayer, the interior life, a saint named here) but a different question. |
| **0** | **Irrelevant.** Different subject, an advert, a station ident, listener chat. |

Two more answers, and please use them where they apply:

- **`ABSTAIN-DOCTRINE`** — the topic matches, but whether this passage may be used turns
  on **doctrinal soundness**. That is Theology's call. Your abstention **routes the
  question to them**; it is not a blank.
- **`ABSTAIN-PEDAGOGY`** — the topic matches, but it turns on **formation fit**: right
  depth, safe framing, presumed prior formation.

**Do not abstain because you are unsure.** Unsure is still a grade. Abstain when the
question is not yours to answer. Most people abstain on about 1 item in 100.

**Please do not look up which episode a passage comes from, and do not check what the
site currently points at.** The machine could not see either. If you can, the comparison
measures nothing. The learning points are deliberately un-numbered and the passage order
is random — neither carries information.

**Write your answers into `answers-%(rater)s.json`**, which is generated beside this file:

```json
{ "LP01-1": 2, "LP01-2": 0, "LP01-3": "ABSTAIN-DOCTRINE", "LP01-4": 3 }
```

---
"""

FOOT = """## What happens to your answers

Nothing about you is scored. Two things are measured:

1. **Do the raters agree with each other?** (Krippendorff's α.) If the panel does not
   agree, the finding is that the *rubric above* is ambiguous — the labels are not
   touched and the grade table gets rewritten. **A panel that does not resolve cannot
   condemn anything.**
2. **Does the machine agree with the panel?** Four gates, thresholds fixed in advance.
   They can say PASS, PARTIAL, CANNOT VERIFY or DISCARD, and DISCARD deletes thousands
   of machine labels in one step.

Your abstentions are **routed**, not discarded: doctrine to Theology (Sojourners
propose, Theology approves), formation fit to the formation guild. They come back as
SOUND / UNSOUND / NEEDS-CONTEXT — never as a grade, because they were never a grading
question.

**One rater's mistake cannot delete the label set.** A control item only counts against
the machine when a STRICT majority of raters disagrees with it — both of two, two
of three. That protection exists only because there is more than one of you.
"""


def main():
    cal_path = out_dir = exc_path = None
    raters, as_json = [], False
    min_items = MIN_ITEMS
    for a in sys.argv[1:]:
        if a.startswith("--cal="):
            cal_path = os.path.expanduser(a[6:])
        elif a.startswith("--out="):
            out_dir = os.path.expanduser(a[6:])
        elif a.startswith("--rater="):
            raters.append(a[8:])
        elif a.startswith("--exclusions="):
            exc_path = os.path.expanduser(a[13:])
        elif a.startswith("--min-items="):
            min_items = int(a[12:])
        elif a == "--json":
            as_json = True
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            die("unknown option: %s" % a)
    if not cal_path or not out_dir or not raters:
        print(__doc__)
        sys.exit(2)
    if len(set(raters)) != len(raters):
        die("a rater id was given twice: %s" % raters)

    # ── the rights refusal, before anything is read ───────────────────────────
    repo = os.path.realpath(os.path.join(os.path.dirname(
        os.path.abspath(__file__)), "..", ".."))
    dest = os.path.realpath(out_dir)
    if dest == repo or dest.startswith(repo + os.sep):
        die("REFUSED: %s is inside the engine repository (%s), which is publicly "
            "mirrored (ADR-0039). A calibration packet carries <=%d-character "
            "excerpts of a derivative-cleared-pending corpus and may not be "
            "written there (P78 6). Write it under ~/dir." % (dest, repo, EXCERPT_CAP))

    try:
        cal = json.load(open(cal_path))
    except Exception as e:
        die("cannot read the calibration set %s: %s" % (cal_path, e))
    exclusions = {}
    if exc_path:
        try:
            exclusions = json.load(open(exc_path))
        except Exception as e:
            die("cannot read the exclusions file %s: %s" % (exc_path, e))
        if not isinstance(exclusions, dict):
            die("exclusions must be an object of rater -> [lp_id]")
        known = {lp["lp_id"] for lp in cal}
        for r, lst in exclusions.items():
            bad = sorted(set(lst) - known)
            if bad:
                die("exclusions for '%s' name learning points that are not in the "
                    "calibration set: %s" % (r, bad))

    os.makedirs(dest, exist_ok=True)
    report = {"label_set": os.path.basename(os.path.dirname(
        os.path.abspath(cal_path))), "out": dest, "raters": {}}

    for rater in raters:
        exc = set(exclusions.get(rater, []))
        view, jmap = build(cal, rater, exc)
        n_items = sum(len(lp["items"]) for lp in view)
        # Count controls through the join map: it is the only structure that
        # still knows which catalogue learning point each rendered item came
        # from, the rendered view having deliberately forgotten.
        strat = {lp["lp_id"]: lp["stratum"] for lp in cal}
        ctrl = sum(1 for ref in jmap.values()
                   if strat[ref["lp_id"]].startswith("C-control"))

        # ── anti-self-review must not shrink a packet into meaninglessness ────
        if n_items < min_items:
            die("rater '%s': anti-self-review exclusions (%d learning point(s)) "
                "leave only %d items, below the %d minimum. A short packet must "
                "not ship silently — either widen the calibration set or route "
                "these learning points to a rater who did not author them."
                % (rater, len(exc), n_items, min_items))
        if ctrl < MIN_CONTROL_ITEMS:
            die("rater '%s': only %d control items survive the exclusions, below "
                "the %d Gate 4 needs. That rater would be excluded from the kill "
                "switch, so the packet is refused rather than built blind."
                % (rater, ctrl, MIN_CONTROL_ITEMS))

        # ── structural blinding assertion ─────────────────────────────────────
        for lp in view:
            if set(lp) != RENDER_LP_KEYS:
                die("rater '%s': rendered learning point carries unexpected keys: "
                    "%s" % (rater, sorted(set(lp) ^ RENDER_LP_KEYS)))
            for it in lp["items"]:
                if set(it) != RENDER_ITEM_KEYS:
                    die("rater '%s': rendered item carries unexpected keys: %s"
                        % (rater, sorted(set(it) ^ RENDER_ITEM_KEYS)))

        L = [HEAD % {"n": len(view), "j": n_items, "rater": rater,
                     "cap": EXCERPT_CAP}]
        for lp in view:
            L.append("## %s\n" % lp["alias"])
            L.append("> **The learning point:** %s\n" % lp["lp_summary"])
            if lp["lp_text"]:
                L.append("> \n> %s\n" % lp["lp_text"].replace("\n", " "))
            for it in lp["items"]:
                L.append("**`%s`**  *(clip length: %s)*\n"
                         % (it["label"], it["duration_band"]))
                L.append("> %s\n" % it["excerpt"].replace("\n", " "))
                L.append("`%s` = ______\n" % it["label"])
            L.append("---\n")
        L.append(FOOT)
        blob = "\n".join(L)

        # ── leak check on the RENDERED BYTES, not on the intent ──────────────
        # Structural, per P78 2.2: these are exact catalogue addresses and field
        # names, never words that occur in the corpus's own prose.
        leaks = [t for t in ("machine_grade", "machine_rationale",
                             "machine_confidence", "blind_key", "hybrid_p76",
                             "score_total", "q_parts") if t in blob]
        leaks += [lp["lp_id"] for lp in cal if lp["lp_id"] in blob]
        if leaks:
            die("rater '%s': the member-facing document leaks %s"
                % (rater, sorted(set(leaks))))

        md = os.path.join(dest, "calibration-packet-%s.md" % rater)
        pj = os.path.join(dest, "calibration-packet-%s.json" % rater)
        aj = os.path.join(dest, "answers-%s.json" % rater)
        open(md, "w").write(blob)
        json.dump({"packet_version": 1, "rater_id": rater,
                   "presentation_seed": hashlib.sha256(
                       (SALT + "|" + rater).encode()).hexdigest()[:16],
                   "excluded_lps": sorted(exc),
                   "items": jmap}, open(pj, "w"), indent=1)
        json.dump({k: None for k in jmap}, open(aj, "w"), indent=1)

        report["raters"][rater] = {
            "learning_points": len(view), "judgements_asked": n_items,
            "control_items": ctrl, "excluded_lps": sorted(exc),
            "document": os.path.basename(md), "join_map": os.path.basename(pj),
            "answers_template": os.path.basename(aj),
            "chars": len(blob), "leaks": []}

    # ── two raters must not receive the same ordering ────────────────────────
    if len(raters) > 1:
        seeds = {r: report["raters"][r] for r in raters}
        orders = {}
        for r in raters:
            j = json.load(open(os.path.join(dest,
                                            "calibration-packet-%s.json" % r)))
            orders[r] = tuple((v["lp_id"], v["blind_key"])
                              for _, v in sorted(j["items"].items()))
        dupes = [(a, b) for i, a in enumerate(raters) for b in raters[i + 1:]
                 if orders[a] == orders[b]]
        if dupes:
            die("raters %s received an identical presentation order. Correlated "
                "order effects inflate panel agreement for a reason that is not "
                "the judgement." % dupes)
        report["distinct_orderings"] = len(set(orders.values()))

    print(json.dumps(report, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
