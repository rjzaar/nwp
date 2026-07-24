# Post-Planes Backlog (operator-requested 2026-07-24) — action AFTER all planes complete

Captured verbatim-in-intent so it survives context resets. Do NOT action until the 5 planes are done.

## UX — navigation & explanation (most users are NOT tech-savvy; explain everything)
1. **Help section — accordion + counts.** The nwc help has many sections. Reorganise so the top-level
   HEADINGS show first, each labelled with how many parts it contains; **only one section expands at a
   time** (accordion) → its sub-topics → optionally sub-sub-topics. Goal: easy navigation, no wall of text.
2. **/apply form — a proper intro.** Add top-of-form explanation that gives a new user the big picture of
   *how the whole system works* before the agreements/fields, with the ability to dive into detail. Same
   navigational shape as the help accordion.
3. **Explanation levels (both contexts).** Buttons at the top to switch the depth of explanation, e.g.
   **non-tech / standard / tech** (find the best labels — maybe "plain / normal / technical" or a slider).
   Applies to BOTH the help section and the /apply intro. Content authored at each level.
4. **Reflect the new consent model + agreements** (functionality gates, Trialing/Tester's Guild, CC0 &
   Art9 optional) in all of the above copy.

> Note: the consent-arc draft (branch `ops-consent-arc-draft`) is building the consent UI + /apply consent
> boxes NOW as a functional draft. Items 1–4 are the UX layer to refine ON TOP of that once it works.

## Documentation & review (after planes)
5. **Full NWP code documentation review** — review all `docs/` for accuracy vs the shipped changes; write
   missing **guides** (how-to for the main workflows). Tie into `pl doc-truth`.
6. **Single test-links doc** — one page listing links to exercise every part of the site(s), so the operator
   can click through and smoke-test everything by hand.
7. **Executive summaries + overview** — a short exec summary of each main project **and** an overall
   overview: **nwp, ss (Saint School / Moodle), nwc (Narrow Way Commons), theocat**. Audience: the operator
   + newcomers.

## Open question to resolve (part of #7 overview work)
8. **dir site (video-transcript search)** — status + is it being integrated into nwc? Known: `dir.nwpcode.org`
   = DIR (Divine Intimacy Radio), Drupal at `/var/www/dir1`; there's a DIR/SD podcast-transcript corpus
   (see memory `dir-sd-corpus-overlap`). Whether the transcript-search capability folds into nwc is NOT yet
   confirmed in the arc record — RESEARCH the intended relationship and state it in the overview, then
   propose keep-separate vs integrate. Do not assume.

## Sequencing
All of the above is gated on: 5 planes complete (Plane 1 tool-code MRs merged; Plane 2/3 done; Plane 4 consent
arc working + reviewed; deploy/validate). Then do UX (1–4) → docs/guides (5) → test-links (6) → exec
summaries/overview incl. the dir decision (7–8).
