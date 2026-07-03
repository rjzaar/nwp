# Research annex — seed content vs editorial workflow (P65 evidence base)

Condensed from 4 research agents, 2026-07-02 (ops#3 session). This is the evidence behind
`docs/proposals/P65-seed-content-lifecycle.md`. File:line refs are against the nwc profile
package at commit `a60117f` (branch `unfork/open-social-13`); verify before relying on them.

## A. Workflow machinery map (what "the content workflow" actually is)

Three unrelated machines; none gates entity creation:

1. **`workflow_assignment` (live, in base recipe):** per-node ordered `workflow_task`
   entities (`status ∈ pending|in_progress|completed`); "advancing" = manually editing the
   task status field — no transition engine. The real check is access: `hook_node_access` →
   `WorkflowAccessManager::checkAccess()` locks a node to participants *while tasks are
   active* — but ONLY for bundles listed in BOTH `enabled_content_types` AND
   `workflow_access_control_types`, and **no module/recipe ships that config** — by default
   no content type is governed until an admin opts bundles in. `nwc_content_access`:
   destination-task completion triggers file migration + optional auto-publish
   (`field_auto_publish` on the destination term); note the auto-publish fires only on the
   pending→completed *transition* — seeding tasks pre-completed does NOT publish.
   `nwc_asset\Service\WorkflowChecker::check()` is an advisory validator, never blocks.
2. **`nwc_editorial` (WIP, NOT enabled, no shipped config, not in any recipe):** full state
   machine draft→writer/pedagogy/theology/safeguarding/copyright→approved→trial→production
   (+revise/escalate/reject), template-driven per `change_kind` (`legal` path skips
   writer/pedagogy/theology/trial: draft→copyright_clearance→approved→production).
   Reviewer pools per stage (writer/pedagogy/theology/safeguarding/copyright roles;
   Shepherds for approve); author excluded from own pool; claim service enforces pools but
   **`TransitionForm`/advance() does NOT** (flat `transition editorial revision` permission);
   **no access control handler on either entity**; `state` is a plain field — a seeder can
   write `in_production` directly, nothing prevents it. `origin` field (human|pipeline|
   hybrid) exists on artifact+revision with `pipeline_provenance`; the ONLY origin-branching
   logic is `PipelineSampler` (batch audit sampling). No node↔artifact bridge exists
   (`subject_ref` free-form, "resolver lives in the consumer module" — no consumer).
3. **`nwc_governance`:** group/policy machinery (PolicyDecision cascade, GovernanceAction
   audit), not content review.

Core `content_moderation`/`workflows` are unused anywhere. **Doctrine-vs-code gaps:**
"content trials ≥7 days" and "pipeline content needs Class B approval" exist in no code;
the 7-day figure is the seeded policy-*discussion* default (`nwc_governance.install` ~L57);
trial durations are per-template `default_trial_days` (ADR-0006); ADR-0011's extra pipeline
stages (ai_disclosure_audit etc.) are unimplemented. "Class A/B/C" is the Sojourners badge
taxonomy, not a reviewer class.

## B. Content-ingress inventory (every path content enters a site)

| Path | What | Mechanism | Workflow? | Provenance | Updatable post-install? |
|---|---|---|---|---|---|
| recipes (all tiers) | none (modules + front-page config action only; no `content:` dirs yet) | recipe apply | n/a | n/a | n/a |
| `nwc_guild.install` seed materialisation | guild/IG groups + per-guild vocabularies/terms (from `config/install/guilds/*.yml`) | hook_install | bypasses (active groups) | logger only | **create-only; YAML edits after a guild exists are ignored** |
| `nwc_demo.install` | demo users/memberships/editorial samples/governance log | hook_install | bypasses; editorial samples set real states but write `state` directly (no transitions) | origin=human + ADR note on revisions; site_mode stamp | create-if-missing only |
| `nwc_copyright` drush sync (`nwc-copyright:sync` → `DataPolicySync::syncAll/syncDoc`) | data_policy entities/revisions from `canonical-text/` | **manual drush — no install hook; nothing runs at module install** | bypasses; version bump forces re-consent for all users | strong: `"nwc_copyright vN — summary"` in revision_log_message + effective_date | YES — versions.yml bump is the channel |
| `nwc_copyright.module` L~51 `publishFromEditorial` | data_policy revision from an approved editorial revision (`legal:*` subject reaching in_production) | hook_ENTITY_TYPE_update | **the ONLY workflow-respecting path in the package** | log = "editorial revision N — summary" (NO vN tag) | per approved revision |
| `nwc_content/scripts/migrate_help_to_book.php` | 11 book nodes (Help/About/Contact + hierarchy + aliases) | manual `drush php:script` | bypasses — `status=1`, no moderation_state, uid=1 | uid=1 only | no |
| `nwc_devel.install` + `drush nwc:generate` | sample nodes (status=1), workflow_tasks/skills at arbitrary states | hook_install (auto when devel recipe applied) / drush | bypasses | minimal | no (has `nwc:cleanup`) |
| `nwc_core` AvcMigrateCommands (4 verbs) | users (UID-preserving), legal-text history→state audit blob, scores, levels | manual drush, read-only `avc` DB connection | bypasses (raw copy) | strong for legal-text (state blob w/ source+rows) | one-way |
| `nwc_carmelite_dictionary.install` | Headword entities from external SQLite | hook_install (module not in any recipe) | bypasses | uniqueness triple incl. source_edition | no re-import path |
| `nwc_member` / `nwc_content_access` installs | reference vocabularies/terms | hook_install | bypasses (reference data) | none | no |

No `default_content`, no migrate-module content migrations, no recipe `content/` dirs
anywhere in the package today.

**THE BUG (P65 item 1):** the two data_policy channels race. The drush sync tracks
versions by parsing `nwc_copyright vN` from `revision_log_message`
(`DataPolicySync::extractVersionFromLog`); `publishFromEditorial` writes a log WITHOUT
that tag → the sync later reads "no version" → treats entity as older → can re-bump/
overwrite the editorially-published revision. Both channels also call
`configureEnforcement()`. Fix direction (P65 §3.4): version as a real field (or both
channels write the same tag); editorial = authoring channel on the canonical site,
filesystem sync = delivery channel on receiving sites; one writer per site.

**Draft-start break analysis:** forcing all seeds to start unpublished would 404 the Help
book (inter-page links baked in body HTML), break demo dashboards (fixtures assume
completed/approved states), have no analogue for groups (no unpublished group concept),
and could wedge login behind an invisible unaccepted policy (consent gate referencing a
non-live policy). This is why P65 lands install-time Class-3 content as published.

## C. Ecosystem practice (web-verified 2026-07-02)

- **Core Recipe API ships content on our exact build (10.6.12 verified locally):**
  `content/` dir beside recipe.yml, YAML per entity (`content/node/<UUID>.yml`), imported
  on apply, IDs reassigned, references resolve via UUID. `RecipeRunner.php:138` uses
  `Existing::Skip` → **idempotent-create, never updates** (enum has only Error|Skip — no
  update mode). Users cannot be exported. Export tooling: core `content:export` is 11.3+
  (CR 3533854); on 10.6 author with contrib `default_content` 2.x (authoring-time only;
  no stable release). Module-level `content/` dirs are ignored (#3517668 open). API
  formally experimental in 10.x, treated stable from 11.1.
- **Distros:** Open Social `social_demo` (own YAML+drush system, demo-only); Thunder
  (default_content-based test demo); Varbase (migrating demo to recipes); Drupal CMS
  (recipe `content/` in 1.x; 2.x pivoting to site templates). **Common pattern: shipped
  content = one-shot install-time gift; NO distro pushes content revisions post-install;
  config gets hook_update_N, content does not.**
- **Moderation on import:** entities land in the workflow's default state (draft) unless
  moderation_state explicitly set (#3105518 "works as designed") — so "updates enter as
  drafts" is supported behavior, not a fight against core.
- **Workspaces** (stable since 10.3): single-site staging/review of a batch — a review
  surface, not a delivery channel. **Entity Share**: pull-based JSON:API federation
  channel, UUID-matched *updates*, diff UI, receiver-side authority; needs a small
  ImportProcessor plugin to force pulled content into draft; needs upstream to run a live
  hub site. The later upgrade path for P65's update verb.
- **Reconsent pattern:** data_policy (2.0.8 installed) — new revision invalidates consent,
  per-policy required/optional; maintainers seeking new owners (adopt-and-own if
  load-bearing). Moodle tool_policy identical + **"minor change" flag** (update text
  without forcing re-acceptance) — copied into P65 §3.5.
- **No prior art for per-entity signed content provenance** in Drupal — provenance rides
  the signed package (minisign chain) + P65's import manifest.

## D. Governance grounding (ADRs)

- **ADR-0014:** seed content passed the standard editorial pipeline *during authoring* —
  "not magic". ADR-0015: `--site-mode` picks which content set installs (canonical vs demo).
- **ADR-0006:** template-driven state machine; trial durations per-template config.
  ADR-0011: pipeline-origin content first-class w/ operator accountability + extra stages
  (unimplemented). ADR-0008: solo approval only via auditable ScopeGrant. ADR-0005:
  Shepherds oversight; quorum scales with size.
- **Legal-text authority:** Copyright Guild authors, Shepherds approve
  (copyright-guild.yml / shepherds.yml); `nwc_copyright` is "single source of truth" with
  version-bump reconsent (README + versions.yml `posture` — implemented, but **no ADR
  records this design**).
- **ADR-0001 (federation seam):** forks rename, replace the particulars (branding,
  canonical legal text, demo content), own their editorial authority entirely; no
  cross-federation editorial body; not required to share particulars back.
- **Gaps found:** `docs/FORK_GUIDE.md` referenced by ADR-0001/0014/0015 but DOES NOT
  EXIST; no ADR for the reconsent design; no decision on install-time approval state
  (P65 §2 is that decision, needs ratifying as an ADR — P65 item 6); trial/pipeline
  doctrine unimplemented; guild seeds carry structure but NOT charter prose (charter
  content authoring = ops#22 #3, human); `guilds/README.md` stale (lists files that no
  longer exist); no upstreaming/content-contribution mechanism decided (F30 proposal
  exists, unreferenced by any accepted ADR).

---

# Part 2 — Site identity & fresh-site starting content (3 agents, same day)

## E. Substitution inventory (every baked site/operator string in shipped content)

**Half a mechanism already exists:** nwc_mailer templates use `[site:name]`/`[site:url]`;
the nwc_growth first-run wizard collects the community name → `system.site.name` (treats
literal "Narrow Way Commons" as the unset sentinel, FirstRunWizardForm ~L126/158). Baked
literals live in: **legal docs** (`canonical-text/*.md` — operator name ×8, contact email
×12, Melbourne/Victoria jurisdiction, AU statutes, AUD 100 cap, nwpcode.org URL family,
infra facts in privacy.md:64); **help book** (`migrate_help_to_book.php` — "Narrow Way
Commons" ×25 incl. the book-root title that doubles as the book-tree parent key at L224/282/
840/901/935; two mailto: contacts L946/956); **guild seeds** (founder name in
initial_members notes ×6 files; "NWC" in every IG charter one-liner; Saint School/Avila
SSF/formation curriculum in sojourners/trialing/theology YAMLs); **apply webform**
(`webform.webform.apply.yml` — title, Apostoli Viae fieldset L40-58, s195AW consent L213/227,
**hardcoded `to_mail: <operator email>` at L363 bypassing the `approver_email` setting** —
latent bug); **notification Twig templates** (hardcoded brand in daily/weekly digest +
workflow-advance footers); recipe descriptions (admin-facing, low priority). `nwc_help`
topics are already generic (clean). nwc_theme = metadata only.

**Sufficient parameter set (~10):** site_name (=system.site), site_short_name,
operator_legal_name, operator_type, contact_email, general_inquiries_email,
operator_locality, governing_law_region, base_url (=[site:url]), sister_site_url.

**NOT string-substitutable (authoring):** AU statute citations (Copyright Act 1968
ss40/41/195AW, Privacy Act 1988/OAIC, ACL) — swapping the region name makes them FALSE;
currency/liability cap; operator infra facts (Linode/us-iad/Gmail retention);
formation curriculum (Sojourners 12 levels, theology Class A/B/C, Narrow Way Examen);
Apostoli Viae fieldset; posture/"pre-counsel"/effective-date prose; real-person notes
(media-guild.yml:228 "Greg"/"Rob").

## F. Build mechanics (verified on core 10.6.12 / drush 13 / data_policy 2.0.8 / token 1.15)

- **Recipe `input:` = config-only channel.** Schema: description+data_type(primitive)+
  constraints+prompt+default(value|config) (Recipe.php:182-240). Values substitute ONLY
  into config actions as `${<recipe-dirname>.<key>}` (RecipeRunner.php:95-126,336-346);
  the DefaultContent Importer takes no replacements — content imports byte-for-byte.
  `drush recipe <path> --input=dir.key=value` works (core RecipeCommand registered by
  drush; ConsoleInputCollector.php:42-50); non-interactive = defaults, no error. Inputs
  namespaced per defining recipe (parent can supply a child's value, not inject).
- **Tokens can't fix legal docs:** token module enabled, `token_filter` ABSENT;
  data_policy `field_description` is text_long rendered by **basic_string** formatter —
  no filter pipeline ever runs (core.entity_view_display…default.yml:15). nwc_copyright's
  own render path emits Markup directly (LegalController.php:39-43).
- **The choke point:** `LegalDocRenderer::toCleanHtml()` (LegalDocRenderer.php:79) is
  shared by render() AND DataPolicySync::syncDoc/publishFromEditorial — one strtr() there
  covers every legal surface; doing it at sync time bakes identity into the stored
  revision (correct for consent semantics). `cleanMarkdown()` already strips the
  `**Operator:**` metadata header lines from public render (L116) — inline prose still
  carries literals. versions.yml has no identity fields today.
- **First-run wizard persists only site_name** (SetupManager.php:28-30); steps 2/4/5 not
  persisted; no site_identity config exists anywhere (grep clean); `nwc_core` has no
  config/ dir — natural home for `nwc_core.site_identity`.
- **pl install** does `drush site:install <profile> --site-name --site-mail` (lib/
  install-drupal.sh:932-938); post-install `drush config:set` is an established pattern
  (import.sh:333, stg2live.sh:1024). **`nwc-copyright:sync` is called by NO install path**
  → a fresh site has zero legal docs until someone runs it manually.

## G. Prior art (web-verified)

- **WordPress core:** privacy-policy tooling creates a DRAFT page + Privacy Policy Guide;
  only auto-substitution in core's text is the site URL; shipped disclaimer: "It is your
  responsibility to write a comprehensive privacy policy…"; drift notices when suggested
  text changes after publication (policy_text_changed_notice). Plugins register suggested
  sections via wp_add_privacy_policy_content().
- **Discourse:** 2018 counsel-rewritten templates use `{{Company Name}}`/`{{Governing
  Law}}`/`{{{Company Address}}}` etc. bound to site settings company_name/governing_law/
  city_for_disputes (config/site_settings.yml, default ""); TOS/privacy topics are seeded
  ONLY once company_name is supplied (live placeholder-leak embarrassments documented,
  e.g. Racket forum); CDCK: "can't guarantee the template terms… will be the best terms
  for any particular operator", won't take "attorney-like responsibility". External-URL
  escape hatch (tos_url/privacy_policy_url).
- **Moodle tool_policy:** ships EMPTY (high confidence, inferred from docs+repo); no
  substitution mechanism; draft default state; version-bump reconsent as known.
- **Drupal:** core ships nothing (#2850879 postponed since 2017 over jurisdiction
  specificity); **Drupal CMS creates an UNPUBLISHED privacy-policy stub** + footer link +
  "consult your lawyer" guidance — incompleteness is structurally visible (Klaro consent
  manager links to it; unfinished = visibly broken); contrib `legal` module ships no text
  (minimally maintained). No maintained contrib generates/templates legal text.
- **Template corpora:** basecamp/policies (CC BY 4.0, archived, "edit them, adapt them",
  no merge fields) and Automattic/legalmattic (CC BY-SA 4.0 — the lineage Discourse's
  original TOS came from). No cross-project placeholder-syntax standard exists.
- **Converged pattern:** template-as-draft + explicit identity placeholders (identity/
  venue ONLY — never substantive clauses) + counsel disclaimer + a gate before text is
  live + drift notices. Nobody detects "published with literal placeholders" — P65 §3b's
  enforcement-layer gate closes that hole; Discourse's company_name gate is the nearest
  precedent.
