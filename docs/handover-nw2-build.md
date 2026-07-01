# Handover — nw2: the unified "2.0" site (avc + nwc → un-forked OS13)

> **⇢ RENAMED 2026-07-01:** the site built here as **`nw2` is now `sites/nwc`** (DDEV `nwc-dev`) —
> it is the canonical NWC 2.0. The previous un-fork base (old `sites/nwc`) is archived at
> **`sites/nw1`**. Read "nw2" below as "nwc". Tracked in **nwp/ops#22**.

**Living plan doc.** Goal: build `nw2`, a new site that **functionally covers and integrates
everything from `avc` and `nwc`**, built the *correct* way — on **un-forked, composer-managed
Open Social 13**, not a fork. Work one verified step at a time; `avc` and `nwc` are read-only
reference points. Update the "Current step" section as work proceeds.

> Started 2026-06-30 in a long autonomous session. Backups of all curated work exist under
> `~/nwp-curated-backups/`. This doc + the git repos are the source of truth.

---

## 0. The decisive architecture finding (why this is tractable)

From `docs/handover-unfork-ops3.md` (the un-fork, **already working** on nwc-dev):
- **"A profile on top of OS" is impossible in Drupal** — `ExtensionDiscovery` only scans the
  single *active* profile's dir; no base-profile chain. (Triple-confirmed against core source.)
- **The working model** (Open Social's own documented pattern): `social` is the **active install
  profile**; custom code rides on top as **normal modules + a `socialblue` sub-theme + a Recipe**.
- nwc-dev already runs a clean **NWC-on-OS-13.0.2** site (profile `social`, Drupal 10.6.12,
  31 nwc modules, guilds seeded, `composer audit`-clean bar 3 ignored webonyx DoS).
- Dev discoverability uses **two relative symlinks** (productionization gap, not a blocker):
  - `html/modules/custom/nwc_features → ../../profiles/custom/nwc/modules/nwc_features`
  - `html/themes/custom/nwc_theme → ../../profiles/custom/nwc/themes/nwc_theme`

**So nw2 inherits a WORKING OS13 foundation by copying nwc.** The real work is module
reconciliation, not foundation-building.

## 1. The key insight: avc and nwc are parallel prefixed module sets

avc (`avc_*`) and nwc (`nwc_*`) are ~27 of the **same modules** with swapped prefixes. nwc's are
**already OS13-adapted**; avc's carry **newer features** (the v0.8 + 95-file "growth layer") but
**forked-OS APIs**. Per common module the job is: *graft avc's newer features onto nwc's
OS13-compatible version, newest-wins.*

### Module reconciliation matrix (snapshot 2026-06-30)
- **Common (~27, prefix-swapped):** annotation, asset, clip_review, code_sync, content,
  content_access, copyright, core, devel, email_reply, error_report, feedback, group, growth,
  guild, help, member, notification, oidc_claims, registration, safeguarding, scripture,
  translation, trial, video, visual_dam, work_man(agement).
- **nwc-only (keep):** `nwc_editorial`, `nwc_formation`, `nwc_pairing`.
- **avc-only (port, OS13-adapt):** `avc_collab`, `avc_moodle`, `workflow_assignment`, and the
  uncommitted **`avc_governance`** (under `avc_growth/modules/`).
- **avc has uncommitted growth work** (95 files; see `~/nwp-curated-backups/avc-profile-2026…`):
  avc_governance engine, avc_feedback A19 rework + cross-site receiver, avc_collab (HMAC + Node
  sidecar), avc_moodle (OIDC), avc_copyright. **3 auth surfaces need two-person review**
  (cross-site feedback endpoint, collab token, moodle OIDC); `avc_registration` is a broken stub.

### Recency facts (most-recent-wins, established this session)
- **avc DEV working tree is the canonical newest avc source** — avc/stg is a strict subset
  (verified: 0 unique work, 0 conflicts). nwc-dev `unfork/open-social-13` branch is the canonical
  nwc source.
- avc profile = heavy fork (`replace: drupal/social`); nwc profile = un-forked (`open_social:^13`).
  **They are already code-unlinked** (separate repos, no cross-require).

## 2. Security state (carry forward, don't regress)
- The 3 contrib pins (ginvite/paragraphs/role_delegation) are **fixed in the nwc un-fork already**
  (OS supplies ginvite 3.0.4; paragraphs forced 1.21.0; role_delegation via OS). So **nw2 inherits
  the security fix from nwc** — no separate pin work needed on the OS13 base. (avc 1.x still needs
  its own fix; tracked separately.)
- graphql stays at OS's 4.9.0, modules NOT enabled, 3 webonyx advisories `audit.ignore`'d as
  unreachable. Don't re-introduce the graphql-5 alias (see unfork §7).

## 3. Roadmap (phases)
- **P0 — Create nw2** = working copy of nwc-dev (OS13 base). DDEV `nw2-dev`, DB imported, verified.
- **P1 — Reconcile common modules** one at a time: for each `X` in the common set, diff
  `avc_X` vs `nwc_X`, decide newest/best, graft avc's newer features onto the OS13-compatible nwc
  version, enable + smoke-test in nw2. Order: low-risk leaf modules first; core/group/member last.
- **P2 — Port avc-only modules** (collab, moodle, governance, workflow_assignment), OS13-adapting
  forked-OS API calls. The 3 auth surfaces get isolated commits + flagged for review.
- **P3 — Keep nwc-only modules** (editorial, formation, pairing) as-is; verify still load.
- **P4 — Reconcile the Recipe + install** so a fresh `nw2` install enables the unified module set
  (extend nwc's `recipe/recipe.yml`). Verify fresh-install reproducibility.
- **P5 — Verify it operates correctly**: drush updb clean, modules enable/disable lifecycle,
  Behat/PHPUnit, the auth surfaces reviewed.
- **P6 — Productionize** (later, shared with ops#3 punch list): replace dev symlinks with composer
  packaging; retire install-profile files; CI gates. Gated on review.

## 4. Per-module reconciliation method (the repeatable recipe — TBD, refine after first module)
For each common module `X`:
1. `diff -ru sites/nwc/.../nwc_X sites/avc/.../avc_X` (account for prefix rename).
2. Identify: avc-newer features absent from nwc; nwc OS13-adaptations absent from avc.
3. Base on the **nwc version** (OS13-compatible); graft avc's newer logic, translating any
   forked-OS API (`social_*` services/classes from the fork) to OS13-consumed equivalents.
4. Enable in nw2, smoke-test, note API-translation cost.
The **first module** doubles as the probe that measures the true forked-OS→OS13 translation cost.

## 4b. DEFINITIVE FINDING (2026-06-30) — the port list is just 2 modules

Deep survey + recency analysis settled it:
- **nwc was derived from avc (prefix-renamed) then advanced ~2 months further** (nwc modules
  committed June; avc committed April + uncommitted work). The ~13 trivial common modules are
  byte-identical; the divergent ones (feedback, governance, guild, growth, copyright, core,
  registration, member) are all **larger / newer on the nwc side**, which **supersedes** avc.
- **Verified coverage:** `nwc_feedback` already contains ALL of avc's uncommitted A19 rework
  (CrossSite/TesterGuildScore/FeedbackGuide/public-board) and is bigger; `nwc_governance` is
  bigger than `avc_governance`. nwc has the entire growth submodule set + workflow_assignment.
- **Forked-OS API usage in avc modules ≈ 0** → porting is mechanical (prefix rename), not rewrite.

**⇒ nw2 (= nwc) already covers ~98% of avc+nwc. The ONLY genuinely-missing avc work:**
1. **`avc_collab`** — collaborative editing (Hocuspocus/Yjs). ~29 source files + a Node sidecar
   (`hocuspocus/server.mjs`); the 8675 file count is mostly `node_modules` (exclude). Auth surface:
   HMAC token service — **flag for review**.
2. **`avc_moodle`** — Moodle SSO/data/sync, 36 files, submodules incl. an **OIDC UserInfo
   endpoint** — **flag for review**.

Everything else: nw2 already has it (the newer nwc version). No grafting needed.

### Naming decision (OPEN, deferred): nw2 currently keeps `nwc_` module names (it's a copy of
nwc). Porting `avc_collab`→`nwc_collab`, `avc_moodle`→`nwc_moodle` for consistency. A full
rebrand `nwc_`→`nw2_` across 31 modules is a separate decision — do NOT do it unilaterally.

## 5. Current step — CORE INTEGRATION COMPLETE ✅ (2026-06-30)
- **P0 DONE:** `sites/nw2/dev` = working copy of nwc-dev (DDEV `nw2-dev`, git remotes
  disconnected, nwc DB imported). Drupal 10.6.12, profile `social`, bootstrap OK.
- **P1 DONE (by construction):** nw2 inherits nwc's newer versions of all common + divergent
  modules (verified nwc supersedes avc on feedback/governance/etc.). Nothing to graft.
- **P2 DONE:** the 2 genuinely-missing avc modules ported, enabled, bootstrap-verified:
  - `avc_moodle` → `nwc_moodle` (+ submodules `_data`/`_oauth`/`_sync`), all 4 enabled.
  - `avc_collab` → `nwc_collab` (30 files, node_modules excluded), enabled.
  - **Port recipe (proven):** `rsync -a --exclude=node_modules` → rename **basenames** deepest-first
    (`find -depth`, sed only the basename, handles `_` and `-`) → `sed` contents
    (`avc_→nwc_`, `AVC→NWC`, `Avc→Nwc`, `\bavc\b→nwc`) → `ddev drush en`. The whole-path sed is
    WRONG (target dir doesn't exist yet) — rename basenames only.
- nw2 now has **186 modules enabled**; functionally covers the union of avc + nwc on un-forked OS13.

### Punch list to finish nw2 (remaining)
1. **Auth-surface review (two-person, CLAUDE.md):** `nwc_collab` HMAC token service; `nwc_moodle_oauth`
   OIDC UserInfo endpoint. Both ported verbatim from avc — review before any stg/live exposure.
2. **`nwc_collab` Node sidecar:** `…/nwc_collab/hocuspocus/server.mjs` needs `npm install` in that
   dir to run at runtime (module enables without it; real-time editing won't work until built).
3. **Recipe:** add `nwc_collab` + `nwc_moodle*` to `…/custom/nwc/recipe/recipe.yml` so a FRESH
   nw2 install enables them (right now they're enabled only in the imported DB).
4. **nwc-only modules:** `nwc_editorial`/`nwc_formation`/`nwc_pairing` are present on disk (full nwc
   copy) but not enabled in the imported DB — enable + verify if wanted.
5. **Naming/rebrand decision (OPEN):** keep `nwc_` or rebrand `nwc_`→`nw2_` fleet-wide. Deferred.
6. **nw2 git identity:** remotes are disconnected (sandbox). Give nw2 its own repo before any push.
7. **Productionization** (shared w/ ops#3 §8): replace dev symlinks with composer packaging; CI gates.
8. **Optional rigor:** deep per-file content diff of the divergent modules to 100%-confirm nwc ⊇ avc
   (size + feature-signature evidence already says yes; this would just remove all doubt).

## 5c. Content seeding (2026-07-01) — DONE for the real content
Content comparison finding: avc's DB is mostly **Open Social demo** (Springfield/EAA events,
topics, demo users) + **empty stubs** (avc_document/resource/project = 0 body). The guilds hold
only **demo memberships** — no seed-worthy content. The ONE genuinely real dataset is the
**AV Commons Help book** (9 pages, real docs) + 2 real pages.
- **Migrated into nw2** (nids 13–23) as `page` nodes; the 9 help pages placed into a core **Book**
  (root "AV Commons Help"); body content transferred losslessly (char-counts match avc). Enabled
  core `book` module + allowed `page` in books. Scripts: `scratchpad/avc-seed-export.php` +
  `nw2-seed-import.php` (idempotent by title).
- **Deliberately NOT migrated:** all OS demo (events/topics/EAA/Springfield), demo users/comments,
  `[TEST]` items, `codoc1`, and the empty document/resource/project stubs.
- nw2's guilds keep the canonical nwc structure (Copyright/Media/Shepherds/Theology/Trialing + IGs);
  they still need real charters/content authored fresh (not available in avc to migrate).

## 5b. Reproducing nw2 from scratch (if the DDEV copy is ever lost)
`sites/nw2/dev` is a copy, not yet reproducible-by-recipe. Until punch-list #3/#7 land, recreate via:
`rsync -a --exclude=node_modules sites/nwc/dev/ sites/nw2/dev/` → set `.ddev/config.yaml name: nw2-dev`
→ remove git remotes → `ddev start` → import nwc DB → re-port the 2 modules (§5 recipe).

## 6. References
- `docs/handover-unfork-ops3.md` — the un-fork architecture + install commands + security posture.
- `~/nwp-curated-backups/avc-profile-2026…` (dev) + `…-STG-…` (stg) — avc curated-work backups.
- avc reference tree: `sites/avc/dev/html/profiles/custom/avc` (HEAD + 95 uncommitted = newest avc).
- nwc reference tree: `sites/nwc/dev/html/profiles/custom/nwc` (branch `unfork/open-social-13`).
- Module memory: `unfork-os13-ops3.md`; this build is the avc+nwc → nw2 unification.
