# Clip calibration — a one-page brief for Media Guild members

**Time:** 60–90 minutes, one sitting. **Prerequisite:** none.
**What it earns:** it is tracked separately and does **not** count toward Practitioner
(`media-guild.yml`, locked at Q-MG-08). It is opt-in, and you may stop.
**Full design:** `docs/proposals/P79-calibration-as-guild-work.md`.

---

## What you are actually judging

The site has to pick, for each learning point in a course, **one clip from a podcast** that
teaches it. A machine has already read thousands of candidate passages and graded how well each
one matches. Those grades are **silver, not gold** — a machine's opinion, useful only if humans
turn out to agree with it often enough.

**You are the check on that.** You will read 30 learning points. Each comes with 4 short
passages. You grade each passage 0–3. That is 120 judgements.

You are **not** choosing the clip, fixing anything, or reviewing anyone's work. You are answering
one question 120 times: *how well does this passage teach this point?*

---

## The four grades

| grade | means | the test |
|---|---|---|
| **3** | **This is the passage** | it states or teaches *this* point's specific claim. A learner dropped here hears the point being made. |
| **2** | **Relevant** | genuinely about this subject and would support the point — but it does not make *this* claim. |
| **1** | **Related, not this point** | same territory (prayer, the interior life, a saint named here), different question. |
| **0** | **Irrelevant** | different subject, an advert, a station ident, listener chat. |

**Most of your work happens on the 1-versus-2 line, and that is expected.** When the machines
were measured against each other, **57.7%** of all their disagreement sat exactly there. It is
the hardest call in the task because it is really a question about the *course* — what is this
learning point trying to make the learner take away? — not about the passage. Take your time
there and go quickly everywhere else.

**Use the whole scale.** Clustering on 1 and 2 to avoid committing makes the measurement useless.
**0 is a real grade** and adverts and station idents genuinely occur.

**You are seeing a sample, not the whole passage.** The excerpts are taken at fixed points —
start, middle, end — and are *not* chosen to look relevant. On a long clip you are seeing maybe a
sixth of it. **Grade what you can see.** Do not imagine what might be in the gap.

---

## The two abstentions — they are referrals, not blanks

| answer | when | where it goes |
|---|---|---|
| **`ABSTAIN-DOCTRINE`** | the topic clearly matches, but whether this passage may be *used* turns on **doctrinal soundness** or the right reading of a magisterial or saintly text | **Theology** — Sojourners propose, Theology approves. They answer SOUND / UNSOUND / NEEDS-CONTEXT. |
| **`ABSTAIN-PEDAGOGY`** | the topic clearly matches, but it turns on **formation fit** — right depth, safe framing, presumes prior formation the course has not given | the **formation** guild. They answer FITS / TOO-DEEP / UNSAFE-FRAMING. |

**Do not abstain because you are unsure.** Unsure is a grade. Abstain when the question is **not
yours to answer** — when you can see the match perfectly well and the decision belongs to someone
with a different competence. Expect roughly **1 item in 100**; the machine abstained on 0.88%.

Your abstention is a real routed question with a real answer coming back. It is never a gap in
the data.

---

## The rules, and why each one exists

1. **Do not look up which episode a passage comes from.** The machine could not. If you can, the
   comparison measures nothing.
2. **Do not check what the site currently uses for that learning point.** Same reason — and that
   choice was itself machine-made, so it is not an answer key.
3. **Do not compare sheets with another member.** Your ordering is yours alone and the
   learning points are deliberately un-numbered. Two matching sheets are detected automatically
   and **both become unusable** — the scorer refuses to read one opinion as two.
4. **Answer every item.** A partial sheet returns CANNOT VERIFY, not a partial result. If you
   cannot finish in one sitting, finish it in two — just finish it.
5. **If you wrote or proposed the clip for a learning point, it is not in your packet.** That is
   handled before you receive anything; you do not need to watch for it.

---

## How to do it

```bash
pl clips calibrate status                  # is a packet waiting for you?
```

You receive two files:

- `calibration-packet-<you>.md` — what you read. It repeats the grade table above.
- `answers-<you>.json` — what you fill in. Every item starts as `null`.

Write your answer beside each label:

```json
{ "LP01-1": 2, "LP01-2": 0, "LP01-3": "ABSTAIN-DOCTRINE", "LP01-4": 3 }
```

Then:

```bash
pl clips calibrate status                  # confirms you graded all 120
pl clips calibrate score                   # scores everyone who has handed in
```

---

## What happens to your answers

**Nothing about you is scored.** Two things are measured, in this order:

1. **Do the raters agree with each other?** If the panel does not agree, the finding is that the
   **grade table above is ambiguous** — the machine's labels are not touched, the table gets
   rewritten, and everyone is asked again. **A panel that does not agree cannot condemn
   anything**, so a bad result here is a finding about the instructions, not about you or the
   machine.
2. **Does the machine agree with the panel?** Seven gates, every threshold fixed in writing
   before anybody judged. They can return PASS, PARTIAL, CANNOT VERIFY or DISCARD — and DISCARD
   deletes thousands of machine labels in one step.

**One rater's mistake cannot delete the label set.** The kill-switch items only count against the
machine when a *strict majority* of raters disagrees — **both of two**, two of three. That
protection exists only because there is more than one of you — which is, precisely, why you were asked.

---

## Why this is worth a Saturday morning

Every other task in the clip programme asks you to *apply* a standard. This one asks you, 120
times, blind, where **you** put the line between *"supports the point"* and *"is about a
neighbouring point"* — and then tells you whether the rest of the guild puts it in the same
place. You will finish knowing something specific about what these courses are actually teaching
that you did not know at the start.

It is also the shortest path to a real decision in the whole programme. **One morning settles
whether the machine's shortlist may be handed to authors at all.**
