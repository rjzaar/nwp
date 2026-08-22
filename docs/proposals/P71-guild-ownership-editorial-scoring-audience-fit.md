# P71 — Guild ownership of atom types, editorial scoring wiring, and audience-fit review

**Status:** PROPOSED — 2026-07-09. The workflow/governance companion to
[P70](P70-audience-variants-and-learnersourced-stories.md) (the content *schema*). P70 says *what*
varies (atom types + audience axis); P71 says *who owns each atom type, how their work is scored, and
how audience-fit is reviewed*. Operator decisions captured 2026-07-08/09.
**Parent:** [NWP-ADR-0027](../decisions/0027-unified-course-content-architecture.md) — unified
course-content architecture. NWP-ADR-0027 §"Deferred to the Pedagogy Guild" explicitly defers *"the
atom-type→guild ownership + guild-scoped scoring model (under active research 2026-07-08)"*
(0027 line 311); this proposal is that model. Ceremony-scales-with-trust (NWP-ADR-0027 §5) is the frame:
P71 details the "authored, within a community" and "micro" rows of that spectrum.
**Gate:** ops#61 (canonical content model) + ops#62 (NWC onboarding / Class-3 preservation) — the
same prerequisites as P70. Do not build audience routing over a `core` that disagrees with itself
(ops#61 item 1).
**Research base:** three surveys this session (2026-07-08/09), synthesised in the
[Pedagogy Guild briefing](../pedagogy/learning-science-foundations.md): (1) the learning-science
survey (§1–§8 there), (2) a code survey of the existing `nwc_editorial` + `nwc_guild` engines (cited
`file:line` throughout below), and (3) a reputation / incentive-design web survey feeding the briefing's
§"Scoring & motivation" (briefing lines 208–228). Every scoring rule below traces to a numbered
briefing principle.

---

## 1. The question this answers

> P70 gives each learning point *typed atoms* (`core` / `contrast` / `variants` / `contributed`) on
> an `audience` axis. Three governance questions fall straight out and are **not** answered by P70:
> (a) **who is authoritative** over each atom type — a doctrinal `core` edit and a youth `variant`
> must not clear the same way; (b) **how is that authoring/reviewing labour recognised** — the site
> is an education platform and "all education uses grades" (operator), but naïve activity-scoring
> breeds rubber-stamping; (c) **how is a youth variant checked for audience *fit*** — quality
> (Writers) and fitness-for-audience (Youth) are different judgments.

The answers reuse machinery that **already exists** and is proven by the legal-document workflow
(P68) and the guild-scoring/ratification system. The net-new surface is small and additive — no new
engine, four bounded extensions.

---

## 2. What EXISTS vs what is NET-NEW

The engine is largely built. P71 is mostly *wiring* — connecting subsystems that were designed to
connect but were not yet joined.

| Capability | Status | Evidence |
|---|---|---|
| Template-driven sequential state machine (draft → writer → pedagogy → theology → safeguarding → copyright → approved → trial → production) | **EXISTS** | `nwc_editorial/src/Service/EditorialStateService.php:32` (STAGE_ORDER), `:54` (STAGE_TEMPLATES) |
| Graded propose→clear→push→approve **gate** keyed on transition target, enforced in `advance()` | **EXISTS** | `nwc_editorial/src/Service/LegalGate.php:32` (TRANSITION_ACTION+GATES), wired at `EditorialStateService.php:112` |
| Pool resolver: state→role map **plus** guild-membership augmentation per stage | **EXISTS** | `nwc_editorial/src/Service/EditorialPoolResolver.php:38` (STATE_ROLE_MAP), `:55` (STATE_GUILD) |
| Pool-aware anti-self-review (exclude prior actors while a separate reviewer remains) | **EXISTS** | `EditorialPoolResolver.php:101` (applySeparation), `:122` (separationMode) |
| Guild scoring: `awardPoints()`, per-action point defaults, totals, promotion hook | **EXISTS** | `nwc_guild/src/Service/ScoringService.php:54`, `nwc_guild/src/Entity/GuildScore.php:45` (actions), `:54` (points) |
| Propose-vs-approve **credit split** precedent (worker gets `task_ratified`, approver gets `ratification_given`) | **EXISTS** | `nwc_guild/src/Service/RatificationService.php:124`–`:144` |
| 7-role guild ladder (outsider · junior · member · endorsed · verifier · mentor · admin) | **EXISTS** | `nwc_guild/config/install/group.role.guild-*.yml` (7 files); `group.type.guild.yml:10` |
| Seeded guilds: Sojourners, Theology, Copyright, Media, Shepherds, Trialing | **EXISTS** | `nwc_guild/config/install/guilds/*.yml` |
| Writers / Pedagogy as **Interest Groups** (no routing authority, membership = participation) | **EXISTS** | `nwc_guild/config/install/guilds/interest-groups.yml:14` (writers-ig), `:27` (pedagogy-ig); NWC-ADR-0002 |
| **Atom-type → owning-guild ownership model** (core→Theology, variants→Writers, quiz→Pedagogy, av→Media) | **NET-NEW** | §3 |
| Writers + Pedagogy **promoted IG → full guild** (seed `writers-guild.yml`, `pedagogy-guild.yml`; wire into STATE_GUILD) | **NET-NEW** | §4 |
| **Compound `(atom_type, change_kind)` template key** — the docstring promises it; code keys only on `change_kind` | **NET-NEW** | §5 (bug: `EditorialStateService.php:11` vs `:76`) |
| **`awardPoints()` wired into editorial transitions** — the scoring system is never called by `nwc_editorial` today | **NET-NEW** | §6 |
| **`in_audience_fit_review` sequential stage** + `audience` field on `EditorialRevision` + audience-keyed pool lookup | **NET-NEW** | §7 |
| Audience **IG → audience-guild → member-site** birthing ladder (governance) | **NET-NEW** (formalises NWP-ADR-0027 §9) | §7 |

---

## 3. Atom type → owning guild (the DECISIVE stage, not exclusivity)

**Model.** Ownership is modelled as *"which stage is the decisive/mandatory gate for this atom
type"*, **not** as an exclusive lane. The pipeline is strictly sequential (`STAGE_ORDER`,
`EditorialStateService.php:32`); a `core` edit still traverses *every* upstream stage (writer,
pedagogy, …) — but **Theology is its non-skippable gate and the tier that can veto**. This mirrors
exactly how `legal` already works: the `legal` template (`EditorialStateService.php:68`) still
starts at `draft`, but the Copyright/Shepherds guilds hold the decisive `clear`/`push`/`approve`
actions via `LegalGate` (`LegalGate.php:39`). "Owning guild" = "holds the decisive action at its
gate", nothing more.

| Atom type (P70 §3) | Owning guild = decisive gate | Change model |
|---|---|---|
| `core` / invariant | **Sojourners propose → Theology approve** (+ a Theology *higher-confirmation* tier for core) | graded propose→approve gate, `LegalGate`-shaped, on the `in_theology_review` stage |
| `contrast` | Theology (same gate as core — it fixes the concept boundary) | as core |
| `variants` (framing: intro/example/metaphor/story) | **Writers Guild** (decisive at `in_writer_review`) | promote IG→guild (§4) |
| **`application` (how-to-live-it) + its checkpoint typing (Act→Task/Skill/Habit)** | **Pedagogy Guild** (decisive at `in_pedagogy_review`) — **B1, operator-ratified 2026-07-19** | promote IG→guild (§4) |
| quizzes | **Pedagogy Guild** (decisive at `in_pedagogy_review`) | promote IG→guild (§4) |
| `contributed` (stories) | Pedagogy Guild light gate (P70 §5, briefing Principle 7) | already routed to `in_pedagogy_review` |
| video / audio | **Media Guild** (already a full guild) | `guilds/media-guild.yml` |

**`application` → Pedagogy, not the `variants` default (B1).** The `application` slot lives inside `variants` in
P70's schema, so without this row it would default to the **Writers Guild** — a mis-fit. Choosing *how a truth is
lived* (and typing the checkpoint as Act/Skill/Habit — see MASTERY-AND-THEOLOGY-EDITOR) is a **pedagogical-intervention**
judgment (dosing, sequencing, formation-integrity), not a prose-quality one. So `application` atoms + their checkpoint
typing route their decisive gate to `in_pedagogy_review`. Audience-*fit* of a youth-flavoured application still runs the
§7 `in_audience_fit_review`. *(Operator-ratified 2026-07-19; `~/central/PHASE-4-RATIFICATIONS-2026-07-19.md`.)*

**Core = an apprenticeship gate.** The two guilds on `core` are an apprenticeship pair, already
wired this way in the pool resolver:

- **Sojourners** is the *entry* guild — levels are earned by course-completion, not performance
  (`guilds/sojourners.yml:11`; the "formation-by-course-completion, not performance" caution is the
  briefing's open question 9, line 227). Sojourners *propose* changes to `core`.
- **Theology** is the *mentored, mature successor* guild — parent of Sojourners
  (`guilds/theology-guild.yml:23`, `sojourners.yml:21` `parent_guild: 'theology'`), credentialed by
  Class A/B/C taxonomies (`theology-guild.yml:37`). Theology *approves*.

This is not new plumbing: `EditorialPoolResolver.php:62` already folds Sojourners `guild-mentor` /
`guild-admin` into the `in_theology_review` pool (NWC-ADR-0004 §B-spirit). P71 adds the **graded
propose→approve split** on top (Sojourners may propose/edit a `core` atom; only Theology's
higher-confirmation tier may *approve* it), modelled precisely on `LegalGate`'s
`edit`/`clear`/`push`/`approve` ladder (`LegalGate.php:39`). Structurally, a Writers/Pedagogy/audience
guild **has no `core` atom to edit** (NWP-ADR-0027 §9, 0027 line 229) — the invariant stays with
Theology/Sojourners.

---

## 4. Promote Writers + Pedagogy from Interest Groups to full Guilds

**Operator decision B2 (2026-07-08/09):** *"make them both guilds; there was discussion of the
writers guild and its levels."* Today Writers and Pedagogy are **Interest Groups** —
`flexible_group`, "membership IS participation", **no authority over routing**
(`interest-groups.yml:14`, `:27`; NWC-ADR-0002). But the editorial pipeline already has decisive stages
named for them (`in_writer_review`, `in_pedagogy_review`, `EditorialRevision.php:41`–`:42`) whose
pools are currently satisfied only by *Drupal user roles*
(`EditorialPoolResolver.php:39`–`:40`), not by guild membership. That is the same empty-pool /
role-only gap P68 fixed for Copyright/Shepherds by adding them to `STATE_GUILD`
(`EditorialPoolResolver.php:55`).

**Work:**

1. Seed **`writers-guild.yml`** and **`pedagogy-guild.yml`** in
   `nwc_guild/config/install/guilds/`, using the standard **7-role ladder** (outsider · junior ·
   member · endorsed · verifier · mentor · admin — the `group.role.guild-*.yml` set;
   `guild-verifier` is the review tier). Model shape on `copyright-guild.yml` (a sibling,
   non-subguild "community of practice that performs a pipeline stage") with per-skill tiers à la
   `media-guild.yml:74` if the Guild wants graded Writers levels (the "discussion of the writers
   guild and its levels").
2. Wire both into `EditorialPoolResolver::STATE_GUILD` (`EditorialPoolResolver.php:55`):
   `in_writer_review → ['label' => 'Writers Guild', 'roles' => [...]]`,
   `in_pedagogy_review → ['label' => 'Pedagogy Guild', 'roles' => [...]]`. This makes guild
   membership (not just a bare Drupal role granted to nobody) satisfy the pool, and brings both
   stages under the pool-aware anti-self-review policy keyed by guild label
   (`EditorialPoolResolver.php:122` `separationMode`).
3. Note the **precedent**: NWC-ADR-0002's triple-test (sustained bottleneck + 5+ eligible members +
   distinct credentialing) is the promotion trigger, and **Media-from-Video-IG**
   (`interest-groups.yml:51`, operator 2026-07-08) is the exact precedent for an IG earning routing
   authority and becoming a guild. The `pedagogy-guild.yml` seed also closes a standing parity gap:
   the `nwc_pedagogy_guild` module exists but no guild is seeded (briefing line 233).

The **Pedagogy Guild becomes the standing owner** of the briefing's open questions (§9 below) — this
is where the scoring specifics and the load-bearing test are resolved.

---

## 5. Compound `(atom_type, change_kind)` template key (a latent bug)

**The docstring already promises this and the code does not deliver it.**
`EditorialStateService` says the machine is *"parameterised by the (artifact_kind, change_kind)
pair"* (`EditorialStateService.php:11`), but `getStagePath()` keys **only on `change_kind`**
(`EditorialStateService.php:76`–`:78`, `STAGE_TEMPLATES` is a flat `change_kind => [...]` map at
`:54`). So a `typo` in a throwaway youth `variant` and a `typo` in the doctrinal `core` take the
**identical** path — neither can be routed to its owning guild's decisive gate (§3), because the
stage list does not know the atom type.

**Fix (small, additive):**

1. Add an `atom_type` field to `EditorialRevision` (`core | contrast | variants | contributed`) —
   default `core` for backwards compatibility, mirroring how `change_kind` defaults to `typo`
   (`EditorialRevision.php:113`). (An `editorial_artifact` already carries the target;
   `atom_type` is the P70 typing of *what part* of the LP the revision touches.)
2. Re-key `STAGE_TEMPLATES` on the **compound** `(atom_type, change_kind)`, falling back to the
   `change_kind`-only template when no compound entry exists (so existing behaviour is preserved).
   Concretely: `getStagePath()` looks up `"$atom_type:$change_kind"`, then `$change_kind`, then
   `typo` (extend the fallback chain at `EditorialStateService.php:78`).
3. Seed the compound entries that matter: `core:typo` and `contrast:*` **retain** `in_theology_review`
   as mandatory (a "typo" in an invariant can change doctrine); `variants:typo` may **skip** theology
   and land its decisive gate at `in_writer_review`; `contributed:*` routes to the light Pedagogy
   gate (P70 §5). A `variant` typo and a `core` typo now take genuinely different paths.

This is the one item that is a **correctness fix**, not a feature — it makes the state machine match
its own contract, and it is the prerequisite for §3's routing to mean anything.

---

## 6. Editorial scoring — wire the existing engine into transitions

**The scoring system is fully built and never called by the editorial pipeline.**
`ScoringService::awardPoints()` (`ScoringService.php:54`) and `GuildScore` action types
(`GuildScore.php:45`) exist; `RatificationService` calls them (`:124`–`:144`); but `nwc_editorial`
contains **no** call to `awardPoints`. P71 wires it into `EditorialStateService::transition()`
(`EditorialStateService.php:208`, the single funnel every move passes through — the right seam).

### 6.1 The operator frame

- **Score = the site's grading.** Operator (2026-07-08): *"all education uses grades; this is the
  site's version of that"* (briefing line 210). Guild score is a first-class part of the platform,
  not a gimmick.
- **Opt-out visible.** A user **may choose not to see** scores (briefing line 211). The score still
  accrues (it drives `checkPromotion`, `ScoringService.php:230`); the user controls *visibility*, per
  the existing global-private toggle pattern (`sojourners.yml:45`).
- **Mastery/recognition, not a competitive leaderboard.** SDT crowding-out: controlling/competitive
  rewards crowd *out* intrinsic/spiritual motivation; informational recognition crowds it *in*
  (briefing lines 213–215, principle §5 SDT). **Consequence:** the existing
  `ScoringService::getLeaderboard()` (`ScoringService.php:189`, a global ranked list) must **not** be
  the primary surface. Prefer a private mastery view / guild-internal recognition; never a global
  public ranking (briefing open-Q 6, line 218).

### 6.2 Research-backed award rules

Points accrue on **corroboration, never raw activity and never the bare act of approving** (briefing
Principle 7 + §"Scoring & motivation", lines 216–224 — kills rubber-stamp and reciprocal-collusion
farming):

| Trigger | Who earns | Rule (why) |
|---|---|---|
| A proposed revision is *approved by a higher/peer tier* | the **proposer** | corroboration of the author's work — the `task_ratified` analogue (`RatificationService.php:124`) |
| A reviewer's approval is later *corroborated downstream* (survives N days in production, or the next tier concurs, or doctrine holds through theology) | the **reviewer** | the `ratification_given` analogue (`RatificationService.php:136`) — **released on downstream corroboration, not at the moment of clicking approve** |
| Raw activity (submitting, claiming, the bare click of "approve") | **nobody** | activity-scoring is what breeds rubber-stamping (briefing §Scoring, line 213) |

This is the **propose-vs-approve credit split already precedented** in `RatificationService`: the
worker gets `ACTION_TASK_RATIFIED` and the approver gets `ACTION_RATIFICATION_GIVEN`
(`RatificationService.php:124`–`:144`, points at `GuildScore.php:54`). P71 reuses those action
constants; it does **not** invent a parallel scoring vocabulary. New action constants are added to
`GuildScore` only if the Guild wants editorial-specific names (e.g. `revision_corroborated`).

### 6.3 Anti-gaming

- **Blind / randomised reviewer assignment within a guild.** Precedent exists:
  `media-guild.yml:171` already runs blind dual-attestation ("neither member sees the other answer
  until both submit"). Apply the same to editorial reviewer assignment so proposer↔reviewer pairs
  cannot self-select. (briefing open-Q 8, line 224.)
- **Flag reciprocal propose↔approve pairs / clique farming.** A periodic job over `guild_score` +
  the editorial transition log (`EditorialStateService.php:222` already logs every
  `from→to by uid action`) detects A-approves-B / B-approves-A loops above a threshold and flags them
  for a mentor. (briefing open-Q 8.)
- The existing **pool-aware anti-self-review** (`EditorialPoolResolver.php:101`) already prevents an
  author from reviewing their own work whenever a separate reviewer exists — the first line of
  defence; the corroboration rule (§6.2) is the second.

---

## 7. Audience-fit review — a new SEQUENTIAL stage, not dual sign-off

**The need.** A youth `variant` needs **two** judgments: *quality* (Writers Guild) and *fitness for
the youth audience* (a Youth-audience body). These are different — a well-written variant can still
misjudge its audience.

**The engine constraint (why not simultaneous).** The pool resolver is **single-guild-per-stage with
OR-semantics** today (`EditorialPoolResolver.php:55` `STATE_GUILD` maps each state to *one* guild;
`:82` merges that guild's members into the pool; a user holding *any* eligible role qualifies). A
*simultaneous dual-sign-off* (both Writers **and** Youth must independently approve the same stage)
is a **deep engine change** — it breaks the one-claim-per-stage model (`claimed_by`,
`EditorialRevision.php:163`) and the linear `advance()` (`EditorialStateService.php:87`). **Reject
it.**

**The design (LegalGate-shaped, additive).** Implement audience-fit as a **new sequential stage**
`in_audience_fit_review`, inserted after `in_writer_review` for atoms that carry an `audience`:

1. Add the state constant `STATE_IN_AUDIENCE_FIT_REVIEW = 'in_audience_fit_review'` to
   `EditorialRevision` (`EditorialRevision.php:40`–`:52`) and to the `state` allowed-values
   (`:81`); insert it into `STAGE_ORDER` after `in_writer_review`
   (`EditorialStateService.php:33`); add it to the notify/pool-refresh set
   (`EditorialStateService.php:235`).
2. Add an **`audience` field** to `EditorialRevision` (list_string; P70 vocab
   `youth · single · married · religious · priest`, open list — NWP-ADR-0027 §1, 0027 line 296). Absent
   `audience` (a `core`/`general` atom) → the stage is **skipped** by the template (§5), so existing
   content is unaffected.
3. Add an **audience-keyed pool lookup** to `EditorialPoolResolver`: for
   `in_audience_fit_review`, resolve the guild by the revision's `audience` value
   (`youth → 'Youth guild/IG'`) rather than by a fixed `STATE_GUILD` entry. This is the *one* new
   resolver behaviour — a per-revision guild label instead of a per-state constant — and it stays
   within the existing `guildMembers()` machinery (`EditorialPoolResolver.php:152`).
4. Gate the transition into/out of it with a `LegalGate`-shaped action map
   (`LegalGate.php:32`) so only the audience body's review tier may pass it — reusing, not extending,
   the graded-gate pattern.

**The audience birthing ladder (NWP-ADR-0027 §9, 0027 lines 212–231).** An audience is a **lifecycle**,
not a fixed body:

```
  Interest Group  ──promote──▶  Audience Guild  ──birth──▶  Federation member site
  (audience tag in            (owns its variant/story        (own community + users;
   interest-groups.yml,         overlay; gains routing         overlay travels, still a
   zero authority, NWC-ADR-0002)    authority + score)             CANONICAL OVERLAY, not a fork)
```

A new audience (e.g. `youth`) starts as an **IG** (an `application_tag`, `interest-groups.yml:26`
shape — zero routing authority). When it earns routing authority via the NWC-ADR-0002 triple-test
(the Media precedent again), it is **promoted to an audience guild** that owns that audience's
`variants`/`contributed` atoms and satisfies the `in_audience_fit_review` pool — and **structurally
cannot touch `core`** (§3). Until an audience is promoted, `in_audience_fit_review` for that audience
resolves to the IG for *advisory* input, or is skipped, per the Guild's policy. Promotion/birthing
are **deliberate governance acts, not automatic thresholds** (0027 line 231).

---

## 8. Flexible engine — routing is configuration, not hard-coded lanes

**Operator decision E:** keep the workflow engine flexible — *"content flows from the audience guild
into the writers guild etc."* The whole of §3–§7 is designed so that **ownership and routing are
data**, not hard branches:

- Stage membership is a **template map** (`STAGE_TEMPLATES`, `EditorialStateService.php:54`) — adding
  a `(atom_type, change_kind)` route is a config row, not a code path.
- Stage→guild ownership is a **map** (`STATE_GUILD`, `EditorialPoolResolver.php:55`) — adding/moving a
  guild's decisive gate is an entry, not a rewrite. LegalGate already comments that its thresholds are
  *"config-shaped constants … a later pass can move them to config"* (`LegalGate.php:23`).
- Audience→body is a **per-revision lookup** (§7.3), so a new audience needs a guild seed + a vocab
  term, not engine surgery.

The explicit non-goal: **do not model ownership as exclusive lanes.** A `core` edit *flows through*
Writers and Pedagogy on its way to its Theology gate; an audience variant *flows through* Writers on
its way to audience-fit. Sequential-with-decisive-gates keeps the "content flows from X into Y"
property the operator asked for.

---

## 9. Phased plan (prerequisite-ordered, buildable)

1. **(prereq)** ops#61 item 1 — reconcile the two divergent sources; declare v3 canonical (shared
   with P70).
2. **Compound key (§5)** — add `atom_type` field + re-key `STAGE_TEMPLATES` on
   `(atom_type, change_kind)` with a fallback chain. *Correctness fix; unblocks all routing. Ship
   first.*
3. **Writers + Pedagogy guilds (§4)** — seed `writers-guild.yml` + `pedagogy-guild.yml`; wire into
   `STATE_GUILD`. Closes the `nwc_pedagogy_guild` parity gap.
4. **Atom-type ownership (§3)** — add the graded Sojourners→Theology propose→approve split on
   `in_theology_review` for `core`/`contrast` (LegalGate-shaped); confirm variants→Writers,
   quizzes→Pedagogy decisive gates.
5. **Scoring wiring (§6)** — wire `awardPoints()` into `transition()` with the corroboration rules;
   de-emphasise `getLeaderboard`; add the reciprocal-pair flag job. *Ships behind the opt-out-visible
   toggle.*
6. **Audience-fit stage (§7)** — add `in_audience_fit_review` + `audience` field + audience-keyed
   pool; seed the first audience (youth) as an IG, promote to guild when the triple-test fires.
7. **Config-ify (§8)** — move `STAGE_TEMPLATES` / `STATE_GUILD` / LegalGate thresholds to config for
   per-site tuning (optional, post-MVP).

Steps 2–5 are independent of the P70 render-contract work and can proceed in parallel with it.

---

## 10. Relationships

- **[P70](P70-audience-variants-and-learnersourced-stories.md)** — the content-schema companion. P70
  defines the atom types and `audience` axis P71 governs. P71's `atom_type` field (§5) and `audience`
  field (§7) are the entity-side of P70's schema. Do **not** duplicate the vocab — one source
  (NWP-ADR-0027 §1).
- **[NWP-ADR-0027](../decisions/0027-unified-course-content-architecture.md)** — parent. §5
  ceremony-scales-with-trust is the frame; §9 birthing ladder is §7 here; the "atom-type→guild
  ownership + guild-scoped scoring model" deferred at 0027 line 311 **is** this proposal.
- **NWC-ADR-0002 three-guilds-plus-stewards** — in the nwc site-profile repo at
  `sites/nwc/dev/html/profiles/custom/nwc/docs/decisions/0002-three-guilds-plus-stewards.md`
  (the `sites/` tree is gitignored here, so this is a path, not a link)
  — the IG→guild promotion triple-test and the Media-from-Video-IG precedent (§4, §7).
- **[P68 legal-doc workflow](P68-legal-doc-authoring-guild-workflow.md)** — the built precedent P71
  copies: graded guild gate (`LegalGate`), pool-aware anti-self-review, guild-membership-satisfies-pool
  (the Copyright/Shepherds `STATE_GUILD` fix). P71 applies the same pattern to Writers/Pedagogy/audience.
- **ops#62 (NWC onboarding)** — supplies the user-facing surface + the Class-3 content-store boundary
  (shared with P70); the "opt-out of seeing scores" toggle (§6.1) belongs in the same profile-settings
  surface.
- **P67 / ops#48 (maturity)** — orthogonal: P67 governs *code/content maturity per site*; P71 governs
  *editorial ownership + scoring per atom*. They compose (a scored, approved variant still trials on a
  `stabilizing` twin before graduating, P70 §5).

---

## 11. Open questions — routed to the Pedagogy Guild

These are the briefing's §"Scoring & motivation" open questions (learning-science-foundations.md
lines 216–227), now owned by the Pedagogy Guild seeded in §4. The system should be shaped by the
Guild's answer, not the reverse:

1. **Recognition vs comparison surfacing** (briefing Q6, line 218) — given scores stay but are
   opt-out-visible, *how* are they shown (private mastery view? guild-internal? never a global ranked
   leaderboard)? Directly decides the fate of `ScoringService::getLeaderboard()` (§6.1).
2. **Corroboration rule** (briefing Q7, line 221) — what counts as the downstream corroboration that
   releases a reviewer's points: content survives N days? a higher tier concurs? doctrine holds
   through theology? Sets the concrete trigger in §6.2 row 2.
3. **Anti-gaming thresholds** (briefing Q8, line 224) — reciprocal propose↔approve flag threshold;
   blind vs open reviewer assignment within a guild. Tunes §6.3.
4. **Grade legitimacy in a faith context** (briefing Q9, line 227) — the line between a healthy
   competence "grade" and reframing *service/formation* as a transactional game — **especially for
   Sojourners**, whose levels are formation-by-course-completion, not performance (§3). May bound
   whether Sojourners `core`-proposal work is scored at all.
5. **Writers Guild levels** (operator B2) — does the Writers Guild want graded skill tiers
   (`media-guild.yml:74` shape) or the flat 7-role ladder? Feeds the `writers-guild.yml` seed (§4).
6. **Audience axis vs disposition** (NWP-ADR-0027 §1 / briefing Q1) — is demographic *audience* the right
   cut for the `in_audience_fit_review` body, or *state-of-prayer / disposition*? Determines what the
   audience-guild ladder (§7) actually births.

---

*This spec is written to be handed to build agents: every EXISTS row carries a `file:line` seam, and
every NET-NEW item names the exact function/field to extend. The single correctness fix (§5) ships
first; everything else is additive wiring over a proven engine.*
