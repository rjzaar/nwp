# P65 — Seed-content lifecycle: shipped content vs the site's editorial workflow

**Status:** PROPOSED (synthesis of 4-agent research, 2026-07-02, ops#3 session)
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

## 5. What this deliberately does NOT do

- No forced local re-review of shipped content at install (rejected: breaks fresh-site
  usability, contradicts ADR-0014's "reviewed upstream", and the ecosystem has no
  precedent); the workflow bite-point is updates + local divergence.
- No content signing per-entity (no Drupal prior art) — provenance rides the already-
  signed package (minisign chain) + the import manifest.
- No push channel of any kind. Receivers pull/apply; their site, their authority.
