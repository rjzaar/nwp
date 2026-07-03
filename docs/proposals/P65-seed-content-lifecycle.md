# P65 — Seed-content lifecycle: shipped content vs the site's editorial workflow

**Status:** APPROVED (operator, 2026-07-02). Synthesis of 7-agent research (2026-07-02,
ops#3 session; §3b amendment same day). Implementation tracked in nwp/ops (see issue
created at approval); item 1 = ops#31. Item 6 (ADR + FORK_GUIDE.md) ratifies this
document's decisions into the canonical record.
**Question (operator, 2026-07-02):** package-shipped seed content lands on sites whose
whole editorial apparatus exists to review content before it's live — and the package
will be installed by other operators (federation). How is seed content best managed
across the full functionality of nwc? (Trigger case: `nwc_copyright` bundles the
operator's actual legal texts.)

**Research base:** `docs/research/seed-content-research-2026-07-02.md` — condensed reports
of the 4 agents: (A) workflow-machinery map, (B) content-ingress inventory, (C) Drupal-
ecosystem practice (web-verified), (D) governance/ADR grounding.

---

## 1. Findings that frame the design

1. **"The content workflow" is three different machines, and none of them gates entity
   creation today.** The live one (`workflow_assignment`) is a per-node task list that
   locks *access* while tasks are active — and only for bundles an admin explicitly opts
   in (`enabled_content_types` is not shipped by any config). The rich editorial state
   machine (`nwc_editorial`, states draft→…→in_production, reviewer pools, origin
   human|pipeline) is **WIP, not enabled, and has no node bridge**. Core
   content_moderation is not used at all. So today, *nothing* stops seed content — the
   question is what SHOULD hold, designed now before nwc_editorial matures.
2. **Exactly one ingress path respects review** (agent B): legal text published from an
   approved `editorial_revision` (`in_production` → `DataPolicySync::publishFromEditorial`).
   Every other path (guild seeds, demo, help-book script, devel, dictionary, AVC
   migration) writes published/active entities directly. Provenance is weak everywhere
   except legal-text versioning.
3. **BUG found (must fix regardless of this proposal):** legal text has two competing
   channels into `data_policy` — the filesystem sync tracks versions by parsing a
   `nwc_copyright vN` tag out of `revision_log_message`, but the editorial-publish path
   writes a log with no such tag, which the sync then reads as "no version" → can
   re-bump/overwrite. The two channels race.
4. **Ecosystem convergence** (agent C, verified): shipped content is a **one-shot gift**
   — recipe `content/` dirs (working in core 10.6.12: UUID-keyed, idempotent-create,
   skip-on-exists, *never updates*) transfer ownership wholly to the receiving site.
   NO distribution pushes content revisions post-install. The single exception pattern:
   **versioned policy documents** (data_policy / Moodle tool_policy), where upstream ships
   new *revisions* and version-bump forces re-consent. Moodle adds a "minor change" flag
   (update text without re-consent) worth copying. Imported content under moderation
   defaults to draft unless a state is set — so "enters as draft for local review" is the
   natural, supported behavior when we want it.
5. **Governance already decided more than the code implements** (agent D): ADR-0014 —
   seed content is not privileged; it's authored content that went through the pipeline
   *upstream during authoring*. ADR-0001 — forks replace the "particulars" (legal text,
   branding, demo) and own their editorial authority entirely; no cross-federation
   editorial body exists. Explicit gaps: no decision on install-time approval state; no
   ADR for the reconsent design; `FORK_GUIDE.md` referenced by three ADRs but unwritten;
   "7-day trial" / "pipeline needs Class B approval" are doctrine with no code.

## 2. The design: four content classes, four lifecycles

The unifying principle — **review happens where authorship happens; installation is not
authorship.** Upstream's editorial pipeline reviewed the content before it shipped
(ADR-0014); the receiving site's pipeline governs what happens to it *after* it lands.
Push-updates in place are forbidden; updates arrive as drafts for local review.

| Class | Examples | Install-time | Post-install updates | Provenance |
|---|---|---|---|---|
| **1. Structure** | vocabularies, destination terms, guild groups/taxonomies | hook_install / config as today — active immediately (structure, not editorial content) | config updates via hook_update_N as today | logger only (fine) |
| **2. Canonical governed documents** | legal texts (Terms/Privacy/AUP/CC0); later: covenant/charter *canonical* texts | versioned entity minted from the site's OWN canonical source (see §3 — the module ships TEMPLATES, not our texts) | new version = new revision + re-consent (minor-change flag skips re-consent); on the authoring site, versions come FROM the editorial pipeline | version + change_summary + effective_date in entity fields (not log-string parsing) |
| **3. Editorial content** | help book, course/session content, authored charter prose | recipe `content/` dirs, UUID-keyed, **published**, provenance-stamped — the reviewed output of upstream's pipeline (ADR-0014); a fresh site must be usable (a draft Help book that 404s serves no one) | NEVER updated in place. Updates ship as new draft revisions (hook_update_N / drush verb; later Entity Share pull) entering the receiving site's workflow; local edits always win (skip-if-modified) | import manifest: package version + UUID set + content hash recorded in state at import |
| **4. Fixtures** | nwc_demo, nwc_devel sample content, test generators | hook_install on demo/devel recipes only — never canonical sites (site-mode guard as built) | none — reset/cleanup verbs instead | site-mode stamp + per-entity notes (as built) |

**Install-time approval state — the decision ADR-0014 left open:** shipped Class-3
content installs **published**, because upstream review already happened and the package
version + manifest records exactly what was shipped. The receiving site's editorial
authority is exercised over (a) whether to apply the recipe at all (tiers are opt-in),
(b) every subsequent update (drafts), and (c) local divergence (their edits are never
overwritten). For a fork this matches ADR-0001: the gift transfers; they own it.

## 3. Class 2 in detail — the nwc_copyright resolution (the trigger case)

The module splits into **engine** (reader/renderer/data_policy sync/tool_policy sync/
reconsent — publishable, stays in `base`) and **content** (operator legal instruments —
never shipped as live text):

1. `canonical_dir` becomes configurable in `nwc_copyright.settings` (CanonicalReader
   currently hard-codes the module path). Default: the module's `canonical-text/`, which
   after the split contains **templates only** (placeholders for operator name/contact/
   jurisdiction), each marked `template: true` in versions.yml.
2. **Fail-closed template gate:** `DataPolicySync` REFUSES to sync any document whose
   metadata says `template: true` — it logs "replace with your own legal text" instead of
   enforcing consent to a placeholder. A fresh operator literally cannot ship our (or
   blank) legal texts live. This makes ADR-0001's "fork must replace the particulars"
   mechanical instead of aspirational.
3. Our real texts move per-site (editing home stays `~/central/legal` + sync.sh, which is
   already the workflow), pointed at by `canonical_dir` in settings.local.php — same
   override pattern the module already uses for the Moodle URL and NOTICE targets.
4. **Fix the dual-channel race (§1.3):** version becomes a real field on the data_policy
   revision (or at minimum both channels write the same `nwc_copyright vN` tag).
   Direction of authority: on the authoring site, the editorial pipeline
   (`legal` change_kind → copyright clearance → Shepherds approval, per the guild
   charters) is the source and the filesystem is its *output*; on receiving sites the
   filesystem sync is the delivery channel. One writer per site, no race.
5. Adopt Moodle's **minor-change flag** in versions.yml (typo fixes shouldn't force
   every user to re-consent).

## 3b. Site identity & fresh-site starting content (amendment, 2026-07-02 — 3-agent research)

**The deeper issue (operator, 2026-07-02):** §3's fail-closed template gate stops a fork
shipping OUR legal texts, but leaves a fresh site with NOTHING usable — and the help book
installs saying "Narrow Way Commons" whatever the site is called. Research (substitution
inventory / build mechanics / WordPress+Discourse+Moodle+Drupal-CMS prior art — annex §E-G)
resolves it as follows.

**Finding that reframes the problem:** a fresh install today has NO legal documents at all —
`nwc-copyright:sync` is not called by any install path; the consent gate is simply off.
And a half-mechanism already exists: mailer templates use `[site:name]` tokens, and the
first-run wizard already collects the community name (writing `system.site.name`, treating
the literal "Narrow Way Commons" as its unset sentinel). The gap is that legal docs, the
help book, guild seeds, notification Twig templates, and the apply webform bake literals.

**Ecosystem verdict (verified):** nobody ships enforceable legal text. WordPress = suggested
text into a DRAFT + guide + "your responsibility" disclaimer + drift notices; Discourse =
templates with `{{Company Name}}`/`{{Governing Law}}` placeholders bound to site settings,
seeded ONLY once the operator supplies `company_name` (after live sites leaked literal
placeholders); Moodle/Drupal-core/contrib-legal = empty; Drupal CMS = unpublished stub whose
absence is structurally visible (broken consent link). Substitution scope is universally
**identity/venue fields only — never substantive clauses** (GDPR-era guidance: the policy
must describe YOUR actual practice; statute citations can't be find/replaced).

### The design

1. **`nwc_core.site_identity` config object** — single source for the ~10 identity keys the
   inventory found sufficient (annex §E): operator_legal_name, operator_type, contact_email,
   general_inquiries_email, operator_locality, governing_law_region, site_short_name,
   sister_site_url (reuse `system.site` name/mail where they suffice). Populated by any of:
   first-run wizard (extend Step 1 — the write path exists), recipe `input:` (verified: a
   config-ONLY channel — `${dirname.key}` into config actions; `drush recipe --input=…`
   works non-interactively; inputs can NEVER reach content files), or `pl install` from
   per-site nwp.yml via `drush config:set` (established pattern in install scripts).
   Expose `[nwc:*]` tokens for render-time surfaces.
2. **Legal docs = per-jurisdiction template sets + identity substitution at the choke
   point.** Canonical texts get explicit `{{placeholders}}` for identity/venue fields only.
   Substitution happens in `LegalDocRenderer::toCleanHtml()` — the single point both the
   page render AND `DataPolicySync` pass through — so identity is BAKED into the stored
   policy revision at sync time (consent must attach to immutable text; render-time tokens
   are wrong here, and mechanically impossible anyway: data_policy's body renders via
   `basic_string`, no filter pipeline). The current AU texts become the AU template set;
   statute citations stay inside the jurisdiction set, never substituted. A generic
   no-statute international baseline is an authoring task.
3. **Fail-closed gate, refined (supersedes §3.2):** `DataPolicySync` refuses to sync/enforce
   a document if ANY of: required site_identity keys empty · unresolved `{{placeholders}}`
   remain after substitution · doc marked `template: true` with operator confirmation absent.
   This is Discourse's company_name gate moved to the ENFORCEMENT layer — stricter than
   anything surveyed, and it closes the one failure mode the whole ecosystem still leaks
   (operator publishes with literal placeholders). Until the gate passes: consent gate off
   + persistent admin warning (Drupal-CMS-style structural visibility).
4. **Install flow closes the no-legal-docs gap:** collect identity (wizard / --input /
   nwp.yml) → sync → docs live + consent gate on. Plus a WordPress-style **drift notice**:
   when the shipped template version advances past the operator's fork point
   (versions.yml template_version vs local), surface an admin notice — never auto-apply.
5. **Help book & other prose:** generalize to site-neutral phrasing where possible
   ("this site"); where the name genuinely helps, `{{site_name}}`/`{{contact_email}}`
   substituted by a small **post-import step** (recipe inputs can't reach content;
   token_filter absent — a strtr pass at import time in the Class-3 import service is the
   mechanism; the book root title doubles as the book-tree parent key, so substitution must
   be consistent). Notification Twig templates take a `site_name` variable; the apply
   webform is rewritten generic — incl. fixing the hardcoded `to_mail` that bypasses the
   existing `approver_email` setting (latent bug), and dropping the operator-specific
   Apostoli Viae fieldset to an opt-in.
6. **Explicitly NOT substitutable (needs authoring — feeds FORK_GUIDE):** jurisdiction
   statute citations, operator infrastructure facts in the privacy policy, monetary/liability
   caps, the formation curriculum (Sojourners levels, theology credentials), external-
   apostolate integrations, posture/effective-date prose, real-person founder notes.

## 4. Concrete work items (ordered)

1. **[bug] Unify data_policy version bookkeeping** across sync + publishFromEditorial (§1.3).
2. **[copyright split]** configurable `canonical_dir` + template texts + `template: true`
   fail-closed gate + minor-change flag (§3). Supersedes the earlier "file a copyright
   split issue" note; this is that issue, enlarged.
3. **[help book → recipe content]** Export the 11 live book nodes (authoring-time
   `default_content` module) into a recipe `content/` dir (either `recipes/base/content/`
   or a dedicated `help` recipe); retire `migrate_help_to_book.php`; stamp the import
   manifest. First proof of the Class-3 channel.
4. **[provenance manifest]** On any recipe-content import: record package version, UUID
   list, per-entity hash in state. Small service in nwc_core; used by update verbs to
   implement skip-if-locally-modified.
5. **[update verb]** `drush nwc-content:update` (hook_update_N-callable): for each
   shipped UUID whose local hash matches the manifest (unmodified), create a new draft
   revision from the updated shipped copy → enters local review; skip + report anything
   locally modified. (Entity Share pull is the later federation-scale upgrade of this
   verb — same receiver-side authority model.)
6. **[ADR]** Record this lifecycle as an ADR (fills agent D's gaps #2 and #4: reconsent
   design + install-time approval state). Write `FORK_GUIDE.md` (gap #1) — §2's table +
   §3 is most of its content.
7. **[later, when nwc_editorial lands]** demo editorial samples should *transition* into
   their states rather than writing `state` directly; pipeline-origin sampling gates and
   trial minimums need code if the doctrine is to be enforced (agent D gap #3).
8. **[site identity]** `nwc_core.site_identity` config + schema + `[nwc:*]` tokens;
   extend first-run wizard; `pl install` wiring from per-site nwp.yml (§3b.1).
9. **[legal templates]** placeholderize canonical texts (identity/venue only) +
   substitution in `toCleanHtml()` + refined fail-closed gate + drift notice + sync wired
   into the install flow (§3b.2-4). Extends item 2; land together.
10. **[prose generalization]** help book site-neutralization + post-import substitution
    step; notification Twig `site_name` variable; apply-webform rewrite incl. the
    hardcoded-`to_mail`-bypasses-`approver_email` bug (§3b.5).
11. **[jurisdiction sets]** restructure canonical-text as per-jurisdiction template sets
    (AU = current docs); author the generic no-statute baseline (human + counsel review).

## 5. What this deliberately does NOT do

- No forced local re-review of shipped content at install (rejected: breaks fresh-site
  usability, contradicts ADR-0014's "reviewed upstream", and the ecosystem has no
  precedent); the workflow bite-point is updates + local divergence.
- No content signing per-entity (no Drupal prior art) — provenance rides the already-
  signed package (minisign chain) + the import manifest.
- No push channel of any kind. Receivers pull/apply; their site, their authority.
