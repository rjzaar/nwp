# Handover — nwp/ops#3 · Un-fork nwc → composer-managed Open Social 13

**Last updated:** 2026-06-29 · **Branch (both repos):** `unfork/open-social-13`
**Status:** ✅ **WORKS end-to-end** — a clean NWC site installs on composer-managed Open
Social 13.0.2, `composer audit`-clean. Remaining work is productionization + the test gate
(see §8). Prod cutover gated on **A14** (NWP-ADR-0024).

> This doc is self-contained for handover. The work is tracked as **nwp/ops#3** (the system
> of record); this is the technical detail. Two git repos are involved:
> - **root project** `~/nwp/sites/nwc/dev` (package `nwp/nwc-project`)
> - **profile/source repo** `~/nwp/sites/nwc/dev/html/profiles/custom/nwc` (package `nwp/nwc`)

---

## 1. TL;DR

The old nwc **forked** Open Social — the entire OS codebase was vendored inside the nwc
install profile. We un-forked it to consume `goalgorilla/open_social:^13.0` via composer.

The naive approach (keep nwc as a profile "on top of" a composer-installed OS) is **impossible
in Drupal** (§3). The working architecture, now built and validated, is Open Social's own
documented model: **`social` is the active install profile; nwc rides as modules + a sub-theme
+ a Recipe.** A clean install now produces a full NWC site on OS 13.0.2, security-clean.

---

## 2. Current state of nwc-dev

- Both repos are on branch **`unfork/open-social-13`**.
- The DDEV site holds a **fresh recipe-installed NWC-on-OS-13.0.2** site (login `admin` /
  `adminpass`). Drupal 10.6.12, active profile `social`, 33 nwc modules enabled, guilds seeded.
- **Dev-only symlinks** (in gitignored `html/`, not committed) make nwc discoverable outside
  `profiles/`:
  - `html/modules/custom/nwc_features` → `../../profiles/custom/nwc/modules/nwc_features`
  - `html/themes/custom/nwc_theme` → `../../profiles/custom/nwc/themes/nwc_theme`
  These must be replaced by real composer packaging for production (§8).
- **To return to the legacy fork** (if needed before #3 is closed):
  ```bash
  cd ~/nwp/sites/nwc/dev/html/profiles/custom/nwc && git checkout security/audit-2026-05-patches
  cd ~/nwp/sites/nwc/dev && git checkout drush-as-runtime-requirement
  ddev composer install
  ddev import-db --file=~/nwp/sites/nwc/backups/unfork-preflight-db-20260628-211302.sql.gz
  ```

---

## 3. Why "a profile on top of OS" is impossible (the core finding)

Triple-confirmed against Drupal core source (`core/lib/Drupal/Core/Extension/ExtensionDiscovery.php`,
10.6.x):

- `ExtensionDiscovery::scan()` → `filterByProfileDirectories()` runs for **both modules and
  themes** and keeps a profile-nested extension **only if it sits under the single _active_
  profile's directory**. `setProfileDirectoriesFromSettings()` records only
  `\Drupal::installProfile()`'s path — **there is no base/parent-profile chain.**
- So with `nwc` active and OS at `html/profiles/contrib/social/`, every `social_*` module +
  `socialbase`/`socialblue` theme is filtered out → install fails: *"Required modules not found:
  social_core"* (and *"Undefined array key socialblue"* for the maintenance theme).
- **`base profile:` is not a core feature** (never landed — core #1356276/#3266057; maintainers:
  "will never be in core"). Nothing reads the key; adding it had no effect.
- **`installer-paths` cannot un-nest** a profile package's modules — `open_social` is one
  `drupal-profile` package; its modules are files inside it, not separate composer packages.
- Extensions **outside** `profiles/` (i.e. `modules/custom`, `themes/custom`) are **always**
  discovered — this is the seam the working architecture uses.

This is exactly why OS was vendored inside the profile originally. (Research streams also cited
Varbase/Thunder for patch governance and confirmed Drupal's strategic direction: Recipes are
the replacement for forking distributions.)

---

## 4. The architecture that works

Open Social's **own documented model** (also what `goalgorilla/social_template` and
`sites/mayo/dev-pre-avc` do): never edit OS; add custom modules + a `socialblue` sub-theme.

| Element | Old (fork) | New (un-forked) |
|---|---|---|
| Active install profile | `nwc` | **`social`** (Open Social) |
| Open Social code | vendored inside `nwc` profile | composer at `html/profiles/contrib/social` |
| nwc feature modules | inside the profile | normal modules (dev: symlinked into `modules/custom`) |
| nwc theme | inside the profile | `socialblue` sub-theme in `themes/custom` |
| nwc install/seed logic | `nwc.profile` install tasks | **`nwc` Recipe** + `nwc_core` `hook_install()` |

---

## 5. How to install / verify it

```bash
cd ~/nwp/sites/nwc/dev
ddev drush site:install social --account-name=admin --account-pass=adminpass --site-name="NWC" -y
# Recipe enables 56 modules in one batch → needs memory_limit ≥ 2G (default 512M OOMs):
ddev exec php -d memory_limit=2048M /var/www/html/vendor/drush/drush/drush.php \
    recipe /var/www/html/html/profiles/custom/nwc/recipe -y
ddev drush cr
```
**Expected:** profile `social`; 33 nwc modules enabled; guilds seeded (Copyright / Media /
Shepherds / Theology / Trialing Guilds + Sojourners + Writers/Pedagogy/Coders/Video/Creatives/
Prayer IGs); front page `/stream`; `nwc.site_mode` = `canonical`; `ddev composer audit --locked`
clean except 3 documented/ignored webonyx advisories.

---

## 6. What was committed (branch `unfork/open-social-13`)

**Root repo** (`~/nwp/sites/nwc/dev`):
- `db4d196` — social-as-active-profile composer. Requires `goalgorilla/open_social:^13.0`;
  installer-path `open_social → html/profiles/contrib/social`; `paragraphs 1.21.0 as 1.19.0`
  (security fix); `audit.ignore` ×3 webonyx (§7); patch `patches/social_group-declare-flag-dependency.patch`;
  `patches-ignore` for the 2 rotted OS patches (redirect #2991423, search_api #2949022).
- *(earlier on this branch, superseded by db4d196: the composer-only un-fork e030464 which used
  graphql-5 aliases — see §7 for why that was wrong.)*

**Profile repo** (`…/html/profiles/custom/nwc`):
- `e7452c2` — composer.json un-forked (require `open_social:^13.0`; dropped vendored-fork
  `replace{}` + empty autoload).
- `bf4420f` — dropped the 48 MB vendored OS tree (git history proved zero nwc edits to it).
- `78c57d0` — `nwc_registration` fixes (declare `webform:webform`; drop bogus `configure:` route).
- `9eb303c` — `recipe/recipe.yml` (module enablement + front page) + `nwc_core.install`
  (re-homed `nwc_install()`: site_mode state + user-1 admin grant).
- `603aaa5` — *(on the base branch)* WIP snapshot of the prior in-progress security/audit-2026-05
  work (21 files + `nwc_formation`), preserved before branching.

Also done (not committed — env config): PHP 8.3 set on nwd/nwt DDEV (`ddev config --php-version=8.3`).

---

## 7. Security posture (important — bigger than the runbook assumed)

OS 13.0.2 pins several deps to **exact versions that have since gone vulnerable**; composer's
block-insecure refuses them. Handling:

| Package | OS 13.0.2 pin | Our handling | Why |
|---|---|---|---|
| `drupal/paragraphs` | `1.19.0` | force **`1.21.0`** | drop-in fix for SA-CONTRIB-2026-060/061 (access bypass) |
| `drupal/graphql` | `4.9.0` | **leave at 4.9.0**, don't enable the module | see below |
| `webonyx/graphql-php` | 14.11.10 (via graphql 4.9.0) | **`audit.ignore` ×3** (justified) | 3 DoS incl. CVE-2026-40476 (`<=15.32.x`); unreachable — graphql modules off |
| `drupal/ginvite` | — | OS supplies **3.0.4** | **fixes** SA-CONTRIB-2026-001 (the old `audit.ignore` was removed) |
| `drupal/core` | `^10.5.9` | resolves **10.6.12** | root's `core-recommended ^10.6.11` wins; secure |

**The graphql subtlety (do not re-introduce the alias):** an earlier commit forced
`graphql 5.0.0 as 4.9.0`. That is **wrong for 13.0.2-stable** — `drupal/graphql 4.x` hard-caps
`webonyx ^14.8.0`, and graphql 5 requires OS's `main`-branch code migration (RichTextJSON
scalar + schema-plugin rework) **absent from 13.0.2**. (P63's graphql-5 worked only because the
fork vendored OS `main`.) Forcing graphql 5 over 13.0.2 would break `social_graphql` at runtime
**if enabled**. Since nwc **does not use GraphQL** (zero refs in `nwc_features`; not in the
install list), the correct move is: graphql stays at OS's 4.9.0, the graphql/`social_graphql`
modules are **not enabled**, and the webonyx advisories are `audit.ignore`'d as unreachable.
**Drop the ignore when adopting OS's first stable release that ships the graphql-5 migration.**

**Patch policy** (validated against Varbase/Thunder/OS): keep `composer-exit-on-patch-failure:
true` + `patches-ignore`; reference immutable commit `.diff` URLs. OS uses composer-patches 1.x,
patches keyed by package name with no version constraint, and exact-pins deps so patches don't
rot — which is why floating a dep past OS's pin silently drops its patch.

---

## 8. What still needs to be done (punch list to close ops#3)

In rough priority order:

1. **Production packaging of nwc** (blocks a real deploy). Dev uses two manual symlinks
   (§2) so nwc modules/theme are discovered outside `profiles/`. Replace with composer-managed
   delivery to scanned paths. Options:
   - Restructure the `nwp/nwc` package so composer installs its modules → `modules/custom` (or
     `modules/contrib`) and theme → `themes/custom` (e.g. installer-path by package name to a
     non-`profiles/` location), **or**
   - Split `nwp/nwc` into separate packages (`nwc_features` module(s), `nwc_theme`, `nwc` recipe).
   - Decide the source-of-truth layout for the git repo accordingly.
2. **Retire the install-profile files.** `nwc.profile` still holds the **demo-seed** logic
   (`nwc_seed_demo_content` — demo users/memberships/editorial/governance for **nwd**). Extract
   it into an **`nwc_demo` recipe**, then delete `nwc.profile`, `nwc.info.yml`, `nwc.install`
   (now redundant — canonical logic lives in `recipe/recipe.yml` + `nwc_core.install`).
3. **`pl` install wrapper** for the §5 three-command sequence, **including the `memory_limit
   ≥2G`** bump for the recipe (the 56-module batch OOMs at the default 512M). E.g. `pl install nwc`.
4. **Verification gate** (the original ops#3 task 7):
   - `~/central/test-module-lifecycle.sh` → 20/20 clean disable/re-enable of nwc modules.
   - Re-point `behat.yml` / `phpunit.xml` off the old `avc` / `profiles/contrib/social` paths to
     the new layout; get the ~30 PHPUnit + 2 Behat green. Add a fresh-install test (none exists).
   - Add a profile `.gitlab-ci.yml` with gitleaks + composer-audit gates.
5. **Replicate to nwd + nwt** (they consume `nwp/nwc` too): nwd = demo mode (`NWC_SITE_MODE=demo`
   + the `nwc_demo` recipe); nwt = canonical. PHP 8.3 already set on their DDEV configs; recipe
   `php: 8.3` bump for nwc/nwd/nwt recipes still TODO.
6. **GraphQL follow-up:** adopt OS's first stable release off `main` that ships the graphql-5
   migration, then drop graphql to `^5` and remove the webonyx `audit.ignore` (§7).
7. **Verify-then-publish / cutover:** prod cutover is gated on **A14** (NWP-ADR-0024). Publishing the
   un-forked profile is now clean (no vendored GPL OS) — see PUBLISH-SCRUB when ready.

### Known non-blocking warnings during install
- `field_group_affiliation entity reference field … no longer has any valid bundle` — an OS
  profile-field config warning; install continues. Worth a follow-up but not fatal.
- `Solr endpoint http://solr:8983 unreachable` — expected; DDEV has no Solr. Non-fatal.
- `oomphinc/composer-installers-extender is abandoned` — pre-existing; cosmetic.

---

## 9. Install bugs found & fixed (all the same config-ordering class the fork masked)

A module that ships a config entity in `config/install/` **must declare the config's provider
module as a dependency**, or install-order is nondeterministic and the config fails with
"unmet dependencies" (core #2090115). The fork's profile install masked these; a clean install
surfaced three:

1. **OS bug** — `social_group` ships `flag.flag.mute_group_notifications` but never declared
   `flag:flag`. Fixed via composer patch (`patches/social_group-declare-flag-dependency.patch`).
   (Worth filing upstream with OS.)
2. **nwc bug** — `nwc_registration` ships `webform.webform.apply` but never declared
   `webform:webform`. Fixed in its `.info.yml`.
3. **nwc bug** — `nwc_registration`'s `configure: nwc_registration.settings` referenced a route
   that doesn't exist. Removed.

---

## 10. Backups & references

- **Backups** (under `~/nwp/sites/nwc/backups/` and `~/nwp/sites/avc/backups/`):
  - `unfork-preflight-db-20260628-211302.sql.gz` — pre-un-fork nwc DB (2.8 MB)
  - `unfork-preflight-20260628-211236/` — root + profile composer.json/lock snapshots + full
    profile git bundle
  - `avc-profile-preflight-*.bundle` — avc profile safety bundle
- **Runbook:** `~/central/nwc-internal/UNFORK-RUNBOOK.md` (note: it framed this as a "trivial
  ~120-line re-base"; that was wrong — the divergence was OS-main-vs-13.0.2 drift, and the real
  work was the architecture pivot + the 3 install-ordering bugs + the security version handling).
- **Memory:** `unfork-os13-ops3.md` in the agent memory dir.
- **Scope note:** only **nwc** un-forks now; **avc** stays on the fork (its sites keep consuming
  it). Six OS-derived sites total: nwc/nwd/nwt (consume `nwp/nwc`) + mayo/saintschool (`nwp/avc`).

---

## 11. Packaging decision — research + briefing for a planning agent (2026-07-02)

**Purpose:** hand the §8 punch list (esp. #1 "production packaging") to a fresh planning/research
agent. This section is the self-contained brief; the GitLab issue **nwp/ops#3** is the system of
record (a pointer comment there references this section).

### 11.1 Session recap (what this session established, no code written)

- Re-grounded ops#3 against live state. **Post-handover rename (2026-07-01):** the canonical target
  is now **`sites/nwc`** (the integrated 2.0, DDEV `nwc-dev`); the old un-fork base is archived at
  **`sites/nw1`**. Both are on branch **`unfork/open-social-13`**. The nwc 2.0 punch list is
  **ops#22**, which explicitly defers productionization to ops#3 (ops#22 item 6: *"Productionization
  shares ops#3 (symlinks→composer, CI)"*). So **ops#3 = productionize the un-fork on `sites/nwc`.**
- **Physical constraint for the next agent:** `sites/*` is **gitignored** in the meta-repo and the
  nested site repos exist **only in the main worktree** `~/nwp/sites/nwc/` — NOT in the
  `nwp-ops3` worktree. So:
  - Drupal root/profile/recipe/composer work → done in `~/nwp/sites/nwc/dev/...` on branch
    `unfork/open-social-13` (root repo `nwp/nwc-project`, profile repo `nwp/nwc`). Shared across
    meta-worktrees.
  - Meta-repo work (`pl install` wrapper, CI templates, docs) → the `nwp-ops3` worktree on branch
    `ops-3` (⚠️ currently **22 commits behind main**; lacks `lib/gitlab-issues.sh`, so `pl issue`
    only works from `~/nwp`. Merge `main` into `ops-3` before meta-repo work.)

### 11.2 The core packaging problem (why the symlinks exist)

Drupal `ExtensionDiscovery` only scans profile-nested modules/themes under the **single active**
profile's dir (no base/parent chain — confirmed core 10.6.x, §3). The un-fork makes **`social`** the
active profile, but nwc's code sits inside its own `type: drupal-profile` package at
`html/profiles/custom/nwc/{modules/nwc_features/*, themes/nwc_theme}` → invisible to discovery.
`modules/custom` + `themes/custom` are **always** scanned — that's the seam.

**Current dev methodology (NOT prod-safe):** two hand-made symlinks bridge the code into scanned dirs:
```
html/modules/custom/nwc_features → ../../profiles/custom/nwc/modules/nwc_features
html/themes/custom/nwc_theme     → ../../profiles/custom/nwc/themes/nwc_theme
```
They are created by hand, live in gitignored `html/`, and are **not produced by `composer install`**
→ a fresh/clean/offline build has no symlinks → discovery fails. This is what blocks a reproducible
deploy. (Relative symlinks are also fragile across rsync/artifact/offline-deploy steps.)

### 11.3 The options (replace symlinks with composer-managed delivery)

- **Option A — one package, `installer-paths` by name.** Keep `nwp/nwc` as one package; change its
  `type` + add installer-paths so composer drops its modules → `html/modules/custom/{$name}` and
  theme → `html/themes/custom/{$name}`. Smallest change; package stays monolithic.
- **Option B — split into real packages** (`nwc_features` module(s), `nwc_theme`, `nwc` recipe), each
  a normal `drupal-module`/`drupal-theme`. Existing installer-paths route them automatically.
  Cleanest/idiomatic, independently versionable; biggest restructuring + changes git source layout.

### 11.4 How Varbase does it (researched this session, verified against its composer.json)

Verified `vardot/varbase-project` + `vardot/varbase` (10.0.x). Varbase = **Option B by a mature
distribution**, three tiers:
1. `vardot/varbase-project` — root/scaffold; stock installer-paths (modules→`modules/contrib`,
   profile→`profiles/contrib/{$name}`); requires just `vardot/varbase` + `vardot/varbase-patches`.
2. `vardot/varbase` — the profile (`type: drupal-profile`), **thin**: config + install logic, and
   `require`s the feature modules. It does **not** vendor them.
3. `vardot/varbase_core|_media|_editor|…`, `vartheme_bs5` — each feature module/theme is its **own**
   composer package (`type: drupal-module`/`drupal-theme`), own repo, installed to
   `modules/contrib`/`themes/contrib` by standard installer-paths.
Also: **patches live in a dedicated `vardot/varbase-patches` package** (`enable-patching: true`);
**no `composer-merge-plugin`** (they moved off it).

**Load-bearing lesson (transfers even though Varbase *is* its own active profile):** never nest
feature modules in the profile — ship them as composer modules to a scanned path
(`modules/contrib`/`custom`), keep the profile/recipe thin.

### 11.5 Recommendation from this session (for the planning agent to pressure-test)

**"B-lite":** don't fragment nwc's ~33 modules into ~33 repos (Varbase does that because it's a big
multi-team product). Instead: one `nwp/nwc` delivered as `type: drupal-module` (or a metapackage)
whose modules install to a scanned path, the theme as its own package/target, a thin recipe, and
patches in their own package. Gets the "fresh `composer install` just works, no symlinks" guarantee
with the Varbase idiom, minus the 33-repo overhead. **Open trade to resolve:** whether
`modules/custom` (Option-A placement) or `modules/contrib` (Varbase placement) is the right scanned
target given nwc is source-owned, not contrib.

### 11.6 Open questions / decisions for the planning agent

1. **A vs B vs B-lite**, and the modules/custom-vs-contrib placement (11.5). Produce the concrete
   `composer.json` diff for the chosen shape.
2. **Source-of-truth git layout** for `nwp/nwc` implied by the choice (single repo w/ installer-paths
   vs split repos). Coordinate with **ops#22 item 1** (git identity — the un-fork line was adopted
   as a fast-forward onto `nwp/nwc` + `nwp/nwc-project` `main`).
3. **Sequencing** of the rest of §8: #2 retire install-profile → `nwc_demo` recipe; #3 `pl install
   nwc` wrapper (safe, meta-repo, unblocks the gate — good first build); #4 verification gate + CI;
   #5 replicate to nwd/nwt (still on `main`/`develop`, not yet on the un-fork branch).
4. **Sensitive-path review:** the packaging change edits profile `composer.json` — a two-person-
   approval path per CLAUDE.md. Plan for human review; no new deps beyond what OS pins.
5. **GraphQL follow-up** (§7) and **A14-gated prod cutover** (§8 #7) stay out of scope until upstream
   / A14 wiring lands.

### 11.7 Where to read / verify (don't trust, check)

- Live truth: `pl status` / `pl rag` / `./pl issue show 3` (+ `22`) — run from `~/nwp`.
- Actual files: `~/nwp/sites/nwc/dev/composer.json` (root installer-paths + `nwc-local` path
  repo) and `~/nwp/sites/nwc/dev/html/profiles/custom/nwc/composer.json` (`type:
  drupal-profile`) + `recipe/recipe.yml`.
- This session wrote **no code** — only this brief + an ops#3 pointer comment.

---

## 12. Packaging plan — DECIDED (planning session 2026-07-02, verified against live code)

**Decision: single-package delivery — `nwp/nwc` becomes `type: drupal-custom-module` and
composer installs the whole package to `html/modules/custom/nwc`.** This is §11.5's B-lite
taken to its logical end: no repo split at all. Modules, nested submodules, the theme, and
the recipe all ride inside the one package; the two dev symlinks are deleted.

### 12.1 Why this shape (each fact verified this session, not assumed)

1. **Recursive discovery covers everything in one scanned path.** Core
   `ExtensionDiscovery::scanDirectory()` (10.6.x, read live) determines extension type from
   the info.yml's own `type:` key and groups by it — the parent directory name is irrelevant.
   `RecursiveExtensionFilterCallback` restricts only the *top level* of a search root to
   `profiles|modules|themes`; below that it recurses into anything not in the skip list
   (`src, lib, vendor, assets, css, files, images, js, misc, templates, includes, fixtures,
   Drupal, tests`). `themes` and `modules` are not skipped at depth. Therefore:
   - `html/modules/custom/nwc/modules/nwc_features/*` → all 42 info.ymls found (incl. the 6
     `nwc_growth` submodules the recipe enables);
   - `html/modules/custom/nwc/themes/nwc_theme` → **discovered as a theme** (its
     `type: theme` is what counts). Base theme `socialblue` sits under the *active* profile
     `social`, so it survives `filterByProfileDirectories()`.
2. **`drupal-custom-module` is a real composer/installers type.** Verified in the installed
   v2.3.0 `DrupalInstaller` (`custom-module => modules/custom/{$name}/`). One installer-path
   line routes it under `html/`.
3. **GitLab's composer registry publishes one package per project** (the project-root
   composer.json). A Varbase-style split (§11.4) means 2–3 new GitLab projects + release CI,
   and reopens the git identity that ops#22 #1 just settled as a clean fast-forward onto
   `nwp/nwc`. Not worth it for a source-owned package with exactly **one** composer patch
   (no patches package needed — it stays in the root project).
4. **`modules/custom` over `modules/contrib`** (the §11.5 open trade): nwc is source-owned
   and path-repo-symlinked in dev — semantically custom; matches the existing
   `modules/custom`/`themes/custom` symlink convention; discovery treats both identically.
5. **Escape hatch if live verify surprises us:** split *only* `nwc_theme` into its own tiny
   `drupal-custom-theme` package (→ `themes/custom/`). One small package, everything else
   unchanged. Only needed if theme-under-modules causes real tooling friction — the fresh
   install in 12.3 is the binding test.

### 12.2 Concrete diffs

**Profile repo** `html/profiles/custom/nwc/composer.json`:
```diff
-    "type": "drupal-profile",
+    "type": "drupal-custom-module",
-    "version": "0.4.0",
+    "version": "0.5.0",
```

**Root repo** `composer.json` installer-paths:
```diff
         "installer-paths": {
             "html/core": ["type:drupal-core"],
+            "html/modules/custom/{$name}": ["type:drupal-custom-module"],
             "html/modules/contrib/{$name}": ["type:drupal-module"],
```
Path repo `nwc-local` keeps working: composer symlinks `html/modules/custom/nwc` → the
checkout. Delete the two hand symlinks (`modules/custom/nwc_features`, `themes/custom/nwc_theme`).

**Sequencing constraint:** retiring the profile files (§8 #2) must land **with or before**
the type change — otherwise `nwc.info.yml` (`type: profile`) would be discovered as a stray
installable profile at `modules/custom/nwc`. So #1 and #2 of the §8 punch list are one step.

### 12.3 Work plan (order matters)

Drupal work in `~/nwp/sites/nwc/dev` on `unfork/open-social-13` (both repos);
meta-repo work in the `nwp-ops3` worktree on `ops-3` **after merging `main` into it** (§11.1).
Lane A discipline: ops#3 + ops#22 same session, never concurrent nwc-profile sessions.

1. **Prep:** `ddev snapshot` + SQL backup (ops#22 #2 pattern).
2. **Profile repo — extract demo seed:** new module `nwc_features/nwc_demo`; move
   `nwc_seed_demo_content` + the four `_nwc_seed_demo_*` helpers from `nwc.profile` into
   `nwc_demo.install::hook_install()` (sets `nwc.site_mode=demo`; keep the idempotent
   sub-steps — the quarterly demo-reset cron reuses them). Add a small `nwc_demo` recipe
   (installs `nwc_demo` after the main recipe). Canonical logic already lives in
   `recipe/recipe.yml` + `nwc_core.install` — nothing to move there.
3. **Profile repo — retire profile files:** delete `nwc.profile`, `nwc.info.yml`,
   `nwc.install` (grep first for stray references, e.g. `_nwc_site_mode` callers). Then the
   composer.json type/version change (12.2).
4. **Root repo:** installer-path line (12.2); `ddev composer update nwp/nwc --lock` →
   package lands at `html/modules/custom/nwc`; remove the two symlinks; `drush cr`.
   *Severable follow-up:* relocate the dev checkout out of gitignored `html/` (e.g.
   `dev/packages/nwc`, path-repo url updated) — removes the "`rm -rf html` deletes the
   working repo" hazard; verify fresh-clone behavior of a missing path-repo dir (glob url
   or CI pre-clone) before committing to it.
5. **Fresh-install verify (the gate for the whole decision):** `drush site:install social`
   → `php -d memory_limit=2048M … drush recipe /var/www/html/html/modules/custom/nwc/recipe`
   → `cr`. Expect: 58 modules incl. `nwc_collab`/`nwc_moodle*`, `nwc_theme` installable,
   front `/stream`, `composer audit` clean (3 webonyx ignores). Then
   `~/central/test-module-lifecycle.sh` (20/20) and a fresh **clone** build (registry-only,
   no symlinks) — proves the reproducible-deploy guarantee. Restore snapshot after.
6. **Meta-repo:** `pl install nwc` — add an `nwc` recipe to `example.nwp.yml` (recipes are
   nwp.yml-driven, not a `recipes/` dir — CLAUDE.md is stale there) + install.sh flow:
   clone/create project → `ddev config --php-version=8.3` → composer install → site:install
   social → recipe @2G → cr; `--site-mode=demo` variant applies `nwc_demo`. Offer the
   matching nwp.yml update (CLAUDE.md rule).
7. **Verification gate + CI (§8 #4):** re-point `behat.yml.dist`/`phpunit.xml` (currently
   untracked in the root repo) to the new layout; profile `.gitlab-ci.yml` with gitleaks +
   composer-audit; add the fresh-install test.
8. **Replicate to nwd/nwt (§8 #5):** move both onto the un-fork branch/`nwp/nwc ^0.5`;
   nwd = `NWC_SITE_MODE=demo` + `nwc_demo` recipe; nwt = canonical.

**Out of scope** (per §11.6 #5): graphql-5 follow-up (§7 — do NOT reintroduce the alias or
touch the webonyx ignores) and the A14-gated prod cutover.

**Human-review gate:** both composer.json files and the profile `.gitlab-ci.yml` are
CLAUDE.md sensitive paths — two-person review before merge. No new dependencies are added
anywhere in this plan.

### 12.4 Risks

| Risk | Mitigation |
|---|---|
| Theme-under-modules surprises some tool (drush/theme build) | Core discovery verified in source; step 5 is the live proof; escape hatch 12.1 #5 |
| Path repo dir missing on fresh clone breaks `composer install` | Step 5 fresh-clone test; registry package `nwp/nwc` is the fallback resolution channel |
| Existing dev DB caches old extension paths | `drush cr` re-resolves; snapshot from step 1 protects |
| `nwc_formation` still missing / WIP modules | ops#22 #4, untouched — recipe already omits them |

### 12.5 Execution status — steps 1–5 DONE, gate GREEN (2026-07-02)

Executed and pushed to `unfork/open-social-13`: `nwp/nwc` `3b03a48` (nwc_demo
extraction + `recipe_demo/`) + `824d76a` (profile files retired,
`type: drupal-custom-module` 0.5.0); `nwp/nwc-project` `b1a179d` (installer-path,
`nwp/nwc ^0.5`, hand symlinks deleted). Full verify results on nwp/ops#3
(comment 2026-07-02): fresh install + recipe from `modules/custom/nwc` green,
nwc_theme installs (escape hatch not needed), recipe_demo seeds end-to-end,
lifecycle 19 PASS/0 FAIL/1 expected SKIP, audit clean, fresh-clone build
reproduces the layout. Corrections to 12.2/12.4 learned in execution:
- The root diff also needs `"nwp/nwc": "^0.4"` → `"^0.5"` (caret on 0.x
  excludes the next minor) — landed in `b1a179d`.
- The 12.4 "registry package is the fallback resolution channel" mitigation is
  NOT yet real: composer install without the pre-cloned profile fails hard
  (`Source path "html/profiles/custom/nwc" is not found for package nwp/nwc`)
  because the lock records the path dist, and 0.5.0 isn't published to the
  GitLab registry yet. `pl install nwc` (step 6) must clone the profile BEFORE
  `composer install`; registry-only resolution arrives with the step-7 publish.

Remaining: steps 6 (`pl install nwc`, meta-repo), 7 (CI gate + behat/phpunit
re-point + publish 0.5.0), 8 (nwd/nwt replication). Human-review gate before
merge to main: both composer.json files (sensitive paths).
