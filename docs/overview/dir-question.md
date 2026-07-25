# The `dir` question: integrate into nwc, or keep separate?

**Asked by:** the operator, as item 8 of the post-planes backlog (ops#132).
**Answered:** 2026-07-25, from the evidence in the repos and the copyright pack.
**Status:** RECOMMENDATION — not a decision. The operator decides.

---

## Short answer

**Keep it separate — and finish the two things that are already half-built.**

`dir` should not fold into Narrow Way Commons. The architecture already written
down (though never applied to this question) puts transcript search on its own
address as its own product, cross-linked to the community site rather than buried
inside it. More importantly, the copyright rules would **forbid** the obvious
version of "integrate": DIR transcripts are classified as never-public material,
and Narrow Way Commons is a member-facing surface.

There is a form of integration that is already underway and does not cross that
line — DIR-derived *clips* being curated by guild members inside nwc — and it is
the one worth finishing.

---

## First, a naming trap

Three different things are called "dir". Most of the confusion about this
question comes from conflating them.

| "dir" | What it actually is | Where |
|-------|--------------------|-------|
| **the dir site** | a Drupal 10 site that searches Divine Intimacy Radio transcripts | the `dir` subdomain, `/var/www/dir` on the shared server; local copy `sites/dir1/` |
| **the `~/dir` repo** | *not the site.* The canonical **Saint School course catalogue** (56 courses) + Moodle plugin sources + the Whisper transcript corpus | `~/dir/` on the workstation, 2 GB, deliberately not pushed to any remote |
| **the `dir` set** | a data set inside the modern search engine | `~/nwptoolkit`, index at `~/nwptoolkit/build/index.db` |

Whenever someone asks "should dir go into nwc?", ask which one they mean. The
answer is different for each.

---

## What the dir site actually is today

- **Content:** Divine Intimacy Radio — a Catholic podcast by Dan and Stephanie
  Burke (SpiritualDirection.com) on prayer, spiritual direction, discernment and
  the interior life. **648 episodes**, 648 transcripts, **288,236 searchable
  segments**.
- **Technology:** Drupal 10.6.5 with one custom module, `dir_search`, doing
  database `LIKE` searches. That is the first-generation approach and it is slow.
- **Who can see it:** effectively **nobody**. Both the home page and `/dir`
  return "access denied". It is a password-gated test site by design.
- **The local copy is empty.** `sites/dir1/dev` runs, but the database has no
  `dir_episodes` table and the latest backup is 2 KB. The real content exists
  only on the server and in the source corpus.

There is also `sites/dir/` — a different, never-built scaffold (`install_step: 0`,
no site) that is registered in `nwp.yml` and should probably just be deleted.

---

## The search capability has already been replaced

This is the single most important fact, and it is easy to miss.

|  | Generation 1 (the dir site) | Generation 2 (in use now) |
|--|------------------------------|---------------------------|
| Engine | Drupal `dir_search`, SQL `LIKE` | `~/nwptoolkit` — FastAPI + SQLite full-text search |
| Speed | slow | sub-0.05 s (was 14–43 s before a fix) |
| Scope | DIR only, 288k segments | 5+ sets, **610,000+** segments |
| Running? | on the server, gated | **yes** — a background service on the workstation since 2026-07-17 |
| Intended home | the `dir` subdomain | the planned `vid` subdomain — built, **not yet deployed** |

The toolkit already serves DIR (648 episodes), Restore The Glory (180), and the
Thomistic Institute (600). Its own architecture decision record (ADR-0001,
accepted 2026-05-17) states plainly that the DIR site directories **become
consumers of the toolkit, not its owner**.

So the Drupal `dir_search` module is redundant technology maintaining an empty
local copy of a gated site whose job something else already does better.

---

## What the record says about integrating with nwc

### On the direct question: the record is silent — and admits it

The backlog item that prompted this research says so in as many words: *"Whether
the transcript-search capability folds into nwc is NOT yet confirmed in the arc
record."* No architecture decision record, proposal, or issue resolves it. That
silence is itself a finding.

### On the architecture: the record is clear, and it implies separate

The podcast pipeline proposal (2026-07-02, approved in planning, tracked as
ops#34) defines what it calls the **product triple** — for any podcast, three
sites, cross-linked and gated:

| Leg | Example address | Built with |
|-----|-----------------|------------|
| transcript search + player | `<slug>v.<domain>` | the toolkit (FastAPI + full-text search) |
| short-course site | `<slug>s.<domain>` | Moodle |
| **community** | `<slug>c.<domain>` | **the nwc profile** |

Narrow Way Commons is the **community leg**. Transcript search is **its own leg
on its own address**. The `dir` site is the ancestor of the search leg.

### On copyright: the record is emphatic, and it forbids the naive integration

The third-party content register records DIR as **Tier 1 — test, password
protected**:

> "[the dir site] is live as a password-protected test site — invited beta
> community access only. **Not publicly accessible; not search-engine indexed;
> never to be made public.**"
>
> "**The original DIR podcast and SD video-series transcripts never cross to a
> public surface.**"

The public surfaces receive only reworked human-authored expression,
public-domain sources, open-licensed sources, and short attributed snippets. And
the underlying permission is not settled: item **Q-3PC-DIR-01 is marked
BLOCKING** — there is provisional permission from Dan Burke, but final approval
and a lawyer's check are both still outstanding.

**Inference, clearly labelled as mine:** the copyright pack never mentions nwc,
but it decides this question anyway. Moving DIR transcripts into the member-facing
community site would move Tier-1 never-public material onto a member surface.
That is exactly what the tier rules prohibit.

### And yet: data from DIR *already flows into* nwc

Two modules ship in the nwc profile today, both shaped around the DIR corpus:

- `nwc_clip_review` — "Curator UI for reviewing video clip candidates per
  learning point. **Pulls ranked candidates from the DIR pipeline**, lets the
  guild propose alternative clips with rationale…" — currently **disabled by
  default**, pending P64.
- `nwc_clip_choice` — stores the chosen clip: episode, start second, end second,
  YouTube ID, quality.

So a *narrow* integration is already designed and half-built. It moves **short,
attributed, guild-reviewed clips** — not the transcript archive.

---

## The three options, honestly costed

### Option A — Keep separate (RECOMMENDED)

Deploy the already-built toolkit at the planned `vid` subdomain behind its gate, cross-link
it from nwc for signed-in members, and **retire the Drupal `dir_search` site**.

- **Work:** DNS + a server + a web server config + the access gate. The toolkit
  itself is done and tested.
- **Also fix:** an audit noted that the `vid` surface is currently "built and
  served entirely by hand", and that the publish gate "depends on a flag read
  inside the FastAPI app — no `pl` choke-point enforces it". That is a real gap:
  a single code change could publish gated content with nothing outside the app
  to stop it. Close it before deploying.
- **Also do:** delete the empty `sites/dir/` scaffold; correct the stale docs that
  still point at `~/nwp/modules/dir_search/`, which no longer exists.
- **Why:** matches the product-triple architecture, respects the copyright tiers,
  retires redundant technology, and needs no new legal clearance.

### Option B — Thin integration (RECOMMENDED, alongside A)

Don't move search into nwc. Finish the **clip** path that already exists: enable
`nwc_clip_review` (P64 / ops#60) so guild members curate DIR-derived clips inside
the community site while the transcripts stay behind their gate.

- **Work:** finish P64; the modules exist.
- **Why:** this is what "integrate dir into nwc" should mean. It delivers the real
  value — DIR material informing member learning — without moving Tier-1 content
  onto a member surface.

### Option C — Full fold-in (NOT recommended)

Build the transcript search interface inside nwc as a Drupal module.

- **Work:** a `nwptoolkit_search` Drupal client — already scoped in the toolkit's
  ADR-0001 as Phase C, **not built**. Plus resolving the blocking copyright item.
- **Why not:** highest cost, highest legal exposure, and it duplicates a working
  service to put restricted content on a less restricted surface. It also
  contradicts the product-triple design without any recorded reason to.

---

## What to write down once you decide

Whatever the decision, it deserves an architecture decision record, because the
absence of one is what caused this question. Suggested content:

1. dir stays a separate product leg (or does not).
2. the `vid` subdomain is the successor to the `dir` subdomain; the Drupal
   `dir_search` module is retired.
3. The nwc↔DIR relationship is **clips, curated, attributed** — not transcripts.
4. The gate is enforced outside the application, at a `pl` choke-point.
5. Q-3PC-DIR-01 stays blocking until Dan Burke's final approval and the lawyer's
   check are both in hand.

---

## Sources

| Claim | File |
|-------|------|
| The question is unresolved | `docs/reports/consolidation-arc-2026-07/post-planes-backlog.md` §8; GitLab nwp/ops#132 |
| Product triple; nwc = community leg | `~/central/PODCAST-PIPELINE-PROPOSAL-2026-07-02.md` §0 (ops#34) |
| Toolkit is the search engine; dir sites are consumers | `~/nwptoolkit/docs/decisions/0001-toolkit-scope.md`; `~/nwptoolkit/README.md` |
| DIR is Tier 1, never public; Q-3PC-DIR-01 blocking | `~/central/copyright/03-THIRD-PARTY-CONTENT-REGISTER.md` §1.1; `10-DECISIONS-LOG.md` D-09 |
| DIR may go to vid, TI may not | `~/central/AWARENESS-2026-07-02.md` |
| Clip modules already in nwc | `sites/nwc/dev/html/profiles/custom/nwc/modules/nwc_features/nwc_clip_review/nwc_clip_review.info.yml`; ops#60 |
| `~/dir` is courses, not the site | `~/dir/DIR_PROJECT_STATUS.md`; `~/dir/courses_v3/README.md`; `~/dir/BACKUP.md` |
| Courses integrate via ssc | `docs/decisions/0027-unified-course-content-architecture.md`; `~/central/COURSES-SSC-INTEGRATION-PROPOSAL-2026-07-19.md` |
| vid gate has no `pl` choke-point | `~/central/PL-COVERAGE-AUDIT-2026-07-19.md` §FAM-H |
