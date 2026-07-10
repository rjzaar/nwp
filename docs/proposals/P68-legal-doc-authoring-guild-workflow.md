# P68 — In-app legal-document authoring: the Copyright-Guild → Shepherds workflow, graded membership, and dynamic anti-self-review

**Status:** PROPOSED — §8 decisions all resolved 2026-07-08; ready to schedule implementation
(§7). Operator session 2026-07-08: "the Copyright Guild edits copyright docs which pass to the
Shepherds Guild for approval, triggering re-acceptance on next login; keep the internal notes as a
guild annotation; and make a fresh install reusable for another site (e.g. rg)".
**Research base:** four parallel code surveys (2026-07-08) over `nwc_registration` (the `/apply`
webform + provisioning), `nwc_copyright` (canonical text + `data_policy` sync + `/legal/*`
rendering), `nwc_editorial` (the A30 state machine + authoring/annotation surface), and
`nwc_guild` (Group-entity guilds + membership → editorial-pool wiring).
**Relation:** the *publish/enforce half* of this already exists (editorial → `data_policy` → forced
re-acceptance). P68 supplies the missing *authoring half* and fixes two live blockers. The
generic-install half **is already designed** in **P65** (seed-content lifecycle) and tracked in
**ops#32** (items 8–9: `site_identity` + legal template gate); P68 extends those rather than
re-deriving them.

---

## 1. The finding that frames everything

The legal pipeline is **half-built**, and the built half is the *back* half:

- **Publish + enforce — DONE.** A legal `editorial_revision` reaching `in_production` fires
  `nwc_copyright_editorial_revision_update()` → `DataPolicySync::publishFromEditorial()`, which
  mints a new `data_policy` revision; `configureEnforcement()` turns on the login consent gate;
  the version bump forces every member to re-accept on next login. `/apply` consent boxes and the
  public `/legal/<doc>` pages both render from that same `data_policy` revision via
  `LegalDocRenderer`, so the text is genuinely single-source.
- **Author + review — MISSING.** There is **no browser surface to write or edit a legal document.**
  `EditorialRevision` has no form handler; the only editorial screen (`TransitionForm`) moves states
  and does **not even render the document body** (`diff`). Legal revisions are created only in tests
  and by hand-editing `canonical-text/*.md` + bumping `versions.yml` + running
  `drush nwc-copyright:sync`. So "the Copyright Guild edits the docs" is, today, a filesystem + drush
  operation, not an in-app one.

Two consequences of that gap are **live blockers** — they stop even the *current* design from
running end-to-end:

1. **The clearance stage is wired to a role nobody holds, not to the Copyright Guild.**
   `EditorialPoolResolver::STATE_ROLE_MAP` resolves `in_copyright_clearance` by the Drupal *user
   roles* `copyright_reviewer` / `site_admin`. Nobody is granted those at install (uid 1 holds only
   `administrator`; its superuser bypass does not satisfy a role-filtered entity query). The Copyright
   Guild is **never referenced** by the resolver. Only the `approved` stage is guild-wired (to
   Shepherds). → The clearance pool is **empty**; a legal revision cannot leave `draft`.
2. **Solo-operator deadlock via anti-self-review.** A30 §4.4 excludes the *author* from the review
   pool. With one operator who is the sole member of both guilds, authoring the draft excludes them
   from clearing and approving it → both pools empty → the document can never ship.

And a smaller one that must be fixed regardless: **`TransitionForm` never shows `diff`**, so a
reviewer approves blind.

P68 closes the authoring half, fixes both blockers, adds the operator's two refinements (graded
guild membership; dynamic anti-self-review), keeps the stripped internal notes as a guild
annotation, and makes the whole thing generic so a fresh `rg`-style install works.

## 2. What is already correct (do not rebuild)

- **Guilds are Group entities** (`group` contrib, bundle `guild`). `nwc_guild.install`
  materialises `config/install/guilds/*.yml` as groups owned by uid 1 with
  `creator_roles: [guild-admin]`, so the originator is the **lone `guild-admin`** of both the
  Copyright Guild and the Shepherds Guild at install. The "sole member" model is already true —
  membership just needs to *drive the workflow*, which today it doesn't (blocker 1).
- **Graded guild roles already exist** as `group_role` config: `guild-admin`, `guild-mentor`,
  `guild-endorsed`, `guild-junior`, `guild-member`, `guild-verifier`, `guild-outsider`. P68 needs
  **no new roles** — only a policy mapping *stage-action → minimum guild role*.
- **The `legal` change-kind template** (`EditorialStateService::STAGE_TEMPLATES['legal']`) is already
  the right short path: `draft → in_copyright_clearance → approved → in_production`.
- **`copyright_notes`** (string_long) already exists on `EditorialRevision`, currently written by
  `recordCopyrightClearance()` but shown nowhere — the natural home for the guild annotation.
- **`data_policy` re-acceptance-on-revision** works natively; `LegalDocRenderer::toCleanHtml()` is a
  single render chokepoint shared by page, raw endpoint, and sync — which is exactly where P65's
  identity substitution is meant to land.

## 3. The authoring model: graded Copyright-Guild membership

Editing is **not** flat across the guild. Map each stage-action to a **minimum guild role**,
resolved against the actor's Copyright-Guild membership (reuse `GuildService` /
`nwc_guild_get_member_role()`, which already reads `guild-admin/mentor/endorsed/junior`). No new
roles; a new policy table.

| Action | Stage transition | Minimum Copyright-Guild role |
|---|---|---|
| **View** doc + annotation | — | any member (`guild-member` / `guild-junior`) |
| **Author / edit** the body + annotation; create a `draft` legal revision | (create) / into `draft` | `guild-endorsed` |
| **Clear** — copyright/rights sign-off (confirm the doc is clean to publish: no infringing text, licence posture correct, citations intact) | into `in_copyright_clearance` … through the clearance gate | `guild-mentor` |
| **Push to Shepherds** — hand the cleared revision to the oversight body | `in_copyright_clearance → approved` | **`guild-admin` only (the head)** |
| **Approve** → publish | `approved → in_production` | **Shepherds `guild-admin` (head) for now** — graded like the Copyright ladder; the minimum-role gate is per-guild configurable so a lower Shepherds level can be granted approval later without code change |

This gives the ladder the operator asked for: a trusted member (endorsed) may draft/edit; a senior
member (mentor) clears; **only the guild head releases to the Shepherds**; the Shepherds approve and
publish. It composes cleanly with the existing state machine — we are gating *who may perform each
existing transition*, not adding states.

**Where the gate lives:** an access check on the transition, driven by a new
`nwc_editorial` service (e.g. `LegalActionPolicy`) consulted by `TransitionForm` and the new
authoring form. The `legal` change-kind is the trigger; non-legal kinds keep today's generic
permission behaviour.

## 4. Dynamic anti-self-review (the operator's rule: only when separate people exist)

Replace the unconditional author-exclusion with a **pool-aware** rule, applied per transition:

```
Eligible = users meeting the stage's role/guild/level requirement
Others   = Eligible \ { author }          # or \ { author ∪ prior actors } — per-guild configurable (see below)
if Others ≠ ∅:  acting user MUST be in Others          # normal anti-self-review
else:           acting user MAY be the author if in Eligible,
                and the transition is stamped  unilateral = true   # audited, no independent review
```

Properties:
- **Solo operator ships.** One-person Copyright + Shepherds guilds → `Others = ∅` at every stage →
  unilateral is permitted, honouring `shepherds.yml quorum.size_1: unilateral`.
- **Self-review re-engages automatically.** The moment a second qualified member exists,
  `Others ≠ ∅` and the author is barred again — no config change, no flag flip.
- **Auditable.** Every unilateral transition carries `unilateral = true` so the Decision Log
  shows exactly which versions shipped without an independent second party.

This is a general fix in `EditorialPoolResolver` / `EditorialStateService::advance()`, not a
legal-only hack — it corrects blocker 2 for every change-kind.

**Per-guild configurable separation (resolved 2026-07-08).** The strictness of "separate person"
is **not** global — each guild's seed config carries a `review_separation` key:
`author_only` (default — exclude only the author) or `prior_actors` (exclude the author *and*
everyone who already acted on this revision, so draft ≠ clear ≠ push whenever enough members
exist). `EditorialPoolResolver` reads the key from the acting guild's config, so different guilds
can run at different rigour (e.g. Shepherds `prior_actors`, a small interest guild `author_only`).

## 5. Keep the internal notes as a guild annotation (stop deleting them)

Today `LegalDocRenderer::cleanMarkdown()` **discards** three things at publish: the "Notes to
counsel" section, the `**Effective date / Version / Operator / Status / …**` metadata block, and
internal paths (`~/central`, `~/nwp`). The operator wants that content **kept and shown to the
guild**.

- **Notes to counsel → a first-class annotation field.** Author it as a *separate* field (reuse
  `copyright_notes`, conceptually "Internal notes — Copyright Guild / counsel"), carried on the
  `editorial_revision` (the durable per-version audit record). Shown on the authoring form and the
  review (`TransitionForm`) screen; **never** written to `data_policy` / never public. Keep
  `cleanMarkdown()`'s stripping only as a defensive backstop for the public render.
- **Metadata → sourced from structure, not parsed from prose.** Version, effective date, status,
  change summary, propagates-to already live in `versions.yml` + the `data_policy` revision log.
  Display them read-only from there. (The prose headers already drift — `terms.md` says "Version:
  1" while `versions.yml` says v2 — which is exactly why prose metadata must not be authoritative.)

Net: the guild edits **two fields** (public body + internal notes) and sees structured metadata; the
public sees only the clean body.

## 6. Generic fresh-install (rg) — finish P65 / ops#32, don't reinvent

The reusability the operator wants is **already the approved P65 design**; P68 only adds the concrete
seed trigger and inherits the two new mechanisms above generically.

From P65 §3b / ops#32 items 8–9:
- **`nwc_core.site_identity`** config (operator legal name, contact, locality, governing-law region,
  short name, …) + `[nwc:*]` tokens, populated by first-run wizard / recipe `input:` / `pl install`.
- **Placeholderize the legal text** — identity/venue **only**, never clauses or statute citations —
  with substitution at the single `LegalDocRenderer::toCleanHtml()` chokepoint, so identity is baked
  into the immutable stored policy revision at sync time.
- **Fail-closed template gate:** `DataPolicySync` refuses to sync/enforce a doc that is
  `template: true`, has unresolved `{{placeholders}}`, or has empty required identity keys. Until it
  passes: consent gate **off** + a persistent admin warning. A fresh operator literally cannot ship
  our (or blank) legal text.

P68 additions:
- **Seed `data_policy` on install** from a **generic placeholderized template set** shipped in the
  module (the *engine + templates* are package; your Victoria-Australia text is `nwc` **instance**
  content — the fork-guide rule). Wire the sync into the install path (today it is called by *no*
  install path). A fresh `rg` install boots with generic templates, gate off + warning, until the
  operator fills `site_identity` and confirms.
- The graded-membership policy (§3) and dynamic anti-self-review (§4) are written generically — a new
  instance gets a working single-operator legal workflow out of the box.

## 7. Delivery plan (sequencing + issues)

Ordered smallest-blocker-first; each is independently shippable.

1. **Unblock the existing workflow (small, own MR).** Guild-wire `in_copyright_clearance` to the
   Copyright Guild (mirror the Shepherds→`approved` bridge) **and** land dynamic anti-self-review
   (§4) **and** make `TransitionForm` render `diff` + the annotation. After this, the legal workflow
   runs end-to-end for a solo operator with today's file-authored bodies.
2. **Annotation (small).** Separate internal-notes field, shown on review/authoring, kept out of the
   public render (§5). Migrate existing `.md` "Notes to counsel" out of the bodies.
3. **In-app authoring surface (the feature build, own issue).** A "Legal documents" screen for the
   Copyright Guild: list docs, edit body + internal notes, "Submit for approval" → creates a `legal`
   `editorial_revision` and walks it through the graded state machine (§3). The `.md` + drush path is
   retained as the dev/bootstrap seed mechanism only.
4. **Generic install (fold into ops#32).** `site_identity` + placeholderize + fail-closed gate +
   seed-on-install (§6). Sequenced as ops#32 8 → 9, plus the seed trigger.

**Issue plan:** P68 is the design record. Fold §6 into **ops#32** (comment linking here). Open a new
`nwp/ops` issue for the in-app authoring surface (step 3) labelled `site::nwc`; steps 1–2 can ride
the same issue or a small "legal-workflow unblock" issue.

## 8. Decisions (resolved 2026-07-08)

1. **Separation-of-duties scope (§4):** **per-guild configurable** via a `review_separation` key
   on each guild's seed config — `author_only` (default) or `prior_actors`. The resolver reads it
   from the acting guild, so guilds can run at different rigour.
2. **Role thresholds (§3):** confirmed — edit = `guild-endorsed`, clear = `guild-mentor`, push =
   `guild-admin`. The thresholds are themselves config (a stage-action → minimum-role map), so they
   can be re-tuned per guild without code change.
3. **Shepherds approval (§3 last row):** gated to the Shepherds **head (`guild-admin`) for now**;
   the minimum-role gate is graded and per-guild configurable, so a lower Shepherds level (or a real
   `shepherds.yml` quorum) can be enabled later without code change.
4. **Authoring format:** **rich text** — CKEditor editing to `full_html`, which is what
   `data_policy` stores natively (no publish-time markdown conversion needed for authored docs; the
   legacy `.md` seed path keeps its own conversion).

All four are settled; no operator decisions block P68. Remaining work is implementation
(§7) and folding §6 into ops#32 (done — comment posted 2026-07-08).
