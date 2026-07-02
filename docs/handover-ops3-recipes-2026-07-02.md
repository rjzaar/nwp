# Handover — ops#3 session 2026-07-02: packaging execution + recipe split + seed-content research

**Audience:** any process/session continuing this work. Self-contained, but canonical
sources win: `pl issue show 3` / `show 22` (system of record),
`docs/handover-unfork-ops3.md` §12 (the decided packaging plan this session executes),
`~/central/nwc-internal/OPERATING-MODEL.md` (read-first). Lane discipline: ops#3 + ops#22
are ONE lane (both edit the nwc profile tree) — never run two nwc-profile sessions
concurrently.

**Working locations:** Drupal work in `~/nwp/sites/nwc/dev` (DDEV `nwc-dev`,
PHP 8.3, Drupal 10.6.12), profile package repo at
`html/profiles/custom/nwc` — branch `unfork/open-social-13` in BOTH repos.
Meta-repo (`pl`) work: `nwp-ops3` worktree on `ops-3` after merging `main`.

---

## 1. Decisions ratified this session (user-confirmed, 2026-07-02)

1. **Single-package delivery stands** (per §12): `nwp/nwc` becomes
   `type: drupal-custom-module` → installs whole to `html/modules/custom/nwc`;
   the two dev symlinks die. The Varbase-style composer-package split stays REJECTED.
2. **9-tier Drupal-recipe split ADOPTED** (supersedes the single `recipe/recipe.yml`).
   This came from an earlier (crashed) session's dependency analysis, pasted back in by
   the user and refined. It splits the *Drupal recipe*, NOT the composer package.
   Full tier table in §3 below.
3. **`nwc_safeguarding` = its own recipe** (user decision): it implements youth-site
   obligations under **Australian law for an incorporated association** (WWCC/police
   checks, parental consent, incident reporting). A general/global site doesn't need it.
   Scope note added to its info.yml so this isn't confused later.
4. **`nwc_mailer` → `growth` recipe** (user decision): its only consumer is nwc_growth's
   first-run wizard (guarded `moduleExists`). Note added to its info.yml: if another
   cluster needs templated email, MOVE it to base, don't duplicate.
5. **`nwc_copyright` stays in `base`** (engine = legal-text reader/renderer + data_policy
   & Moodle tool_policy sync with version-bump forced re-acceptance). BUT the module
   currently bundles the **actual operator legal texts** (`canonical-text/*.md` — names
   the operator personally, Victorian/AU law, pre-counsel). Recommendation made & accepted
   in principle: split content from engine via a configurable `canonical_dir` in
   `nwc_copyright.settings` (CanonicalReader currently hard-codes the module dir —
   `src/Service/CanonicalReader.php:40`); module ships template texts only; operator
   texts live per-site (editing home is already `~/central/legal` + `sync.sh`).
   **Deliberately NOT in the packaging MR** (scope discipline; legal surface). File as
   its own ops issue. May be superseded by the seed-content design (§5).
6. **Parity breaks accepted** vs today's 61-module canonical install:
   `nwc_devel` moves out of the default install (devel recipe, dev/test sites only).
   `full` **includes** safeguarding (nwc/nwt serve minors via Saint School) — this was
   assistant-proposed, user did not object; re-confirm if it matters.

## 2. Work COMPLETED this session

- **Backups (§12.3 step 1):** DDEV snapshot `ops3-prepackaging` + SQL backup
  `sites/nwc/backups/nwc-dev-ops3-prepackaging-20260702-183531.sql.gz` (1.7M, gzip -t OK).
- **`nwc_demo` module created (§12.3 step 2):**
  `modules/nwc_features/nwc_demo/{nwc_demo.info.yml,nwc_demo.install}` — demo seed
  extracted from `nwc.profile` (`nwc_seed_demo_content` + 4 `_nwc_seed_demo_*` helpers →
  `hook_install` + idempotent helpers in the .install, reusable via
  `loadInclude('nwc_demo','install')` for the quarterly demo-reset cron). Includes
  `hook_uninstall` reverting `nwc.site_mode` to canonical. Hard deps kept minimal
  (`nwc_core`, `nwc_guild`, `drupal:user`); editorial/governance seeding is
  `hasDefinition()`-guarded (those providers: `nwc_editorial` WIP, `nwc_governance`).
  The user hand-polished both files — treat current file state as canonical.
  NOT yet committed. Grep-verified: no callers of the old helpers outside the profile files.
- **Info.yml notes added** (uncommitted): `nwc_mailer.info.yml` (growth placement +
  move-don't-duplicate rule), `nwc_safeguarding.info.yml` (AU-law youth-site scope,
  own recipe, never in base).
- **Verified against core source** (10.6.x `RecipeConfigurator::getIncludedRecipe`):
  a bare name in a recipe's `recipes:` key resolves to a SIBLING directory of the
  applying recipe (`<parent>/<name>/recipe.yml`); names containing `/` resolve from
  Drupal root. So the flat `recipes/<tier>/` layout composes natively; `full` and `demo`
  can be pure composers. Also verified earlier (recorded §12.1): ExtensionDiscovery
  recurses below top level — modules AND nwc_theme are discovered under
  `modules/custom/nwc/`; composer/installers v2.3.0 supports `drupal-custom-module`.
- **nwc_core.install already re-homes** the old profile's install logic (site-mode state
  stamp + user-1 admin role) — nothing else to move before retiring profile files.

## 3. The adopted recipe tier table (build target)

Layout: `recipes/<name>/recipe.yml` in the package root (replaces `recipe/`).
All tiers `type: 'Site'`. Dependencies point downward only; every tier assumes `base`.
Current 61-module install list partitions EXACTLY (verified count 36+3+4+4+7+4+1+1+1=61):

| Recipe | Modules |
|---|---|
| **base** | social_comment, social_editor, social_event, social_font, social_footer, social_group_gvbo, social_like, social_mentions, social_page, social_post, social_post_album, social_post_photo, social_profile, social_queue_storage, social_search, social_topic, social_group_invite, social_group_request, social_event_invite, social_advanced_queue, social_emoji, ultimate_cron, book, workflow_assignment, nwc_core, nwc_member, nwc_group, nwc_guild, nwc_content, nwc_copyright, nwc_email_reply, nwc_error_report, nwc_feedback, nwc_help, nwc_notification, nwc_registration + config action `system.site: page.front: /stream` |
| **production** | nwc_asset, nwc_content_access, nwc_work_management |
| **media** | nwc_annotation, nwc_clip_review, nwc_video, nwc_visual_dam |
| **specialists** | nwc_code_sync, nwc_scripture, nwc_translation, nwc_trial |
| **growth** | nwc_growth, nwc_blueprints, nwc_delegation, nwc_governance, nwc_mailer, nwc_onboarding, nwc_telemetry |
| **moodle** | nwc_oidc_claims, nwc_moodle, nwc_moodle_data, nwc_moodle_sync |
| **collab** | nwc_collab (Node/Hocuspocus sidecar = real operational cost; opt-in) |
| **devel** | nwc_devel (dev/test sites only — OUT of full: parity break) |
| **safeguarding** | nwc_safeguarding (AU youth-site law; opt-in) |
| **full** (composer) | `recipes: [base, production, media, specialists, growth, moodle, collab, safeguarding]` — what nwc/nwt apply |
| **demo** (composer) | `recipes: [full]` + `install: [nwc_demo]` — what nwd applies |

Deliberately left out (unchanged from the crashed session's analysis):
`nwc_carmelite_dictionary` (untested — add to specialists once verified),
`nwc_moodle_oauth` (per-site opt-in when Moodle SSO is actually served — ops#22 decision),
WIP `nwc_editorial`/`nwc_formation`/`nwc_pairing` (nwc_editorial → future `editorial`
recipe depending on production+growth, since it deps nwc_governance).
Memory nuance: composed recipes still apply in ONE drush process → `full` keeps the 2G
memory requirement; batching win comes from the `pl install nwc --tiers=...` wrapper
applying tiers as sequential drush invocations (build it that way).

## 4. Remaining work plan (updated §12.3)

1. ~~Backups~~ ✅  2. ~~nwc_demo extraction~~ ✅ (recipe part folds into #3 below)
3. **Build `recipes/` layout** per §3 table; delete `recipe/`. Update
   `docs/handover-unfork-ops3.md` §12 + post ops#3 comment recording the split.
4. **Retire profile files**: delete `nwc.profile`, `nwc.info.yml`, `nwc.install`
   (grep stray refs first: `_nwc_site_mode`, `nwc_install_tasks`); THEN composer.json
   `type: drupal-profile`→`drupal-custom-module`, version 0.4.0→0.5.0. (Sequencing
   constraint: retire must land with/before type change — stray `type: profile` info.yml
   under modules/custom would register a bogus profile.)
5. **Root repo**: add installer-path `"html/modules/custom/{$name}": ["type:drupal-custom-module"]`;
   `ddev composer update nwp/nwc --lock`; delete symlinks `html/modules/custom/nwc_features`
   + `html/themes/custom/nwc_theme`; `drush cr`.
6. **Fresh-install verify (THE gate)**: `drush site:install social` → apply `full` recipe
   @2G (path now `/var/www/html/html/modules/custom/nwc/recipes/full`) → `cr`. Expect:
   60 modules (61 minus nwc_devel), nwc_theme installable, front `/stream`,
   `composer audit` clean (3 webonyx ignores stay). Then
   `~/central/test-module-lifecycle.sh` (20/20) + fresh-CLONE registry-only build.
   Also verify `demo` composer on a scratch install. Restore snapshot after.
7. **Meta-repo**: `pl install nwc` with `--tiers=` (sequential drush per tier) +
   `--site-mode=demo`; add nwc recipe entry to `example.nwp.yml` (offer nwp.yml update
   per CLAUDE.md).
8. **CI gate**: re-point behat.yml.dist/phpunit.xml; profile `.gitlab-ci.yml` with
   gitleaks + composer-audit + fresh-install test.
9. **Replicate nwd/nwt** (nwd = demo composer; nwt = full).

**Review gate (unchanged):** both composer.json files + profile `.gitlab-ci.yml` are
CLAUDE.md sensitive paths → human review before merge. Zero new dependencies anywhere.
**Out of scope:** graphql-5 follow-up (don't touch webonyx ignores), A14-gated real-prod
cutover, guild charter authoring (ops#22 #3, human).

## 5. Research IN FLIGHT: seed content vs editorial workflow (user question)

**The question (user, 2026-07-02):** package-shipped seed content (canonical legal texts,
guild charters, help book pages, demo data, future courses) lands on sites that have their
own editorial content-workflow. The copyright-content split (§1.5) is one instance.
How should seed content be managed across FULL nwc functionality — including federation
operators installing the package, whose editorial authority is their own? "Do max
planning/research."

**4 background research agents running** (launched this session):
- **A — workflow machinery map**: nwc_editorial states/transitions (incl. origin
  human|pipeline field), workflow_assignment, nwc_trial, nwc_clip_review,
  nwc_content_access, nwc_governance; what "entering the workflow" means mechanically.
- **B — ingress inventory**: every path content enters a site today (recipe config,
  nwc_guild seed materialisation, nwc_copyright sync→data_policy, nwc_demo hook_install,
  AvcMigrateCommands/help-book migration, nwc_devel, default_content/migrate usage);
  workflow-bypassing vs respecting; provenance; idempotency; post-install updatability.
- **C — ecosystem practice** (web): core Recipe content/ support + which version, default_content
  contrib status on D10, how Open Social/Thunder/Varbase/Drupal CMS ship starter content,
  moderation-state-aware import patterns, Workspaces, data_policy/tool_policy
  reconsent-on-version-bump as the canonical-document pattern.
- **D — governance grounding**: ADR-0008/0014/0015 + guild seed YAMLs (charter content vs
  structure), federation/operator authority statements in package docs +
  `~/central/nwc-internal/` (OPENSOCIAL-ARCHITECTURE-DECISION, PUBLISH-SCRUB-MANIFEST),
  the nwc_copyright "posture" design; explicit list of gaps where no decision exists.

**Synthesis deliverable** (when agents return): a design proposal
(`docs/proposals/` — next free number; P62/P64 exist) answering: which classes of shipped
content exist, which enter the receiving site's workflow as drafts vs arrive as
upstream-canonical-with-version-sync (the nwc_copyright/data_policy model) vs
install-time-only (demo), how provenance is stamped (the `origin` field precedent), and
what a federation operator owns vs inherits. Then reconcile §1.5 (copyright split) with it.

**Early shape (assistant's working hypothesis, unvalidated):** three content classes —
(a) *upstream-canonical governed documents* (legal texts, maybe charters): version-synced,
forced re-acceptance, receiving operator can pin/replace source dir;
(b) *editorial content* (courses, help pages): ships as workflow-entering drafts (origin
stamp = package/upstream) on sites with the workflow enabled, published directly only on
demo installs; (c) *fixture data* (nwc_demo, nwc_devel): install-time only, never on
canonical sites. Agents' findings may overturn this.

## 6. Session state / uncommitted changes (profile repo, branch unfork/open-social-13)

Untracked: `modules/nwc_features/nwc_demo/` (2 files). Modified:
`nwc_mailer.info.yml`, `nwc_safeguarding.info.yml`. Everything else clean.
Recipes build (§4 #3) was starting when this doc was written. Root repo untouched so far.
Rollback path: snapshot `ops3-prepackaging` + the SQL backup in §2.

---

## 7. CLOSING ADDENDUM (same day, later) — supersedes §4/§6 status

**§4 steps 3–6 (core) are DONE.** A parallel executor session did the retire/type-change/
root-delivery (profile `3b03a48`+`824d76a`, root `b1a179d`) while this session built the
recipes (`8bd3114`, dedup `a60117f` — its `recipe_demo/` was dropped in favor of
`recipes/demo/`). Both repos pushed to origin. **Lane A warning is real:** two sessions
touched the profile concurrently; reconciled cleanly this time — keep it one at a time.

**Fresh-install gate PASSED (2026-07-02):** `site:install social` → `recipes/full` 54/54
@2G → 37 nwc modules (devel/demo correctly absent), `nwc_theme` DISCOVERED under
`modules/custom/nwc/themes` + installs (theme-under-modules live-proven; escape hatch not
needed), front `/stream`, `composer audit` clean (3 webonyx ignores). `demo` composer
re-applies idempotently on top + seeds (site_mode=demo, demo users present). Dev DB
restored from snapshot after. Gotcha: `php vendor/bin/drush` prints the bash wrapper —
use `ddev exec php -d memory_limit=2048M vendor/drush/drush/drush.php recipe …`.

**Seed-content research (§5) COMPLETE** → design: `docs/proposals/P65-seed-content-lifecycle.md`;
evidence annex: `docs/research/seed-content-research-2026-07-02.md`. Bug filed: **ops#31**
(data_policy version race, latent). The copyright split (§1.5) is enlarged into P65 item 2
— still NOT for the packaging MR.

**Remaining for whoever continues (this session is closing):**
1. Verify-gate tail: `~/central/test-module-lifecycle.sh` (20/20) + fresh-CLONE
   registry-only build (§4 #6).
2. §4 #7 `pl install nwc --tiers=…` (meta-repo, ops-3 worktree after merging main).
3. §4 #8 CI gate (sensitive path — human review).
4. §4 #9 replicate nwd/nwt.
5. Human review before merge: both composer.json files + `.gitlab-ci.yml`.
6. P65 items (separate MRs; ratify P65 as ADR + write FORK_GUIDE.md per its item 6).
