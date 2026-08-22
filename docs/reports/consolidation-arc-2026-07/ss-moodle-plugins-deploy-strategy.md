# ss-moodle-plugins → running Moodle: deploy/sync strategy

**Status:** recommendation (design only — no deploy scripts changed by this doc)
**Date:** 2026-07-25
**Scope:** how the `nwp/ss-moodle-plugins` git repo (project 33; `main`=base) reaches
the running Moodle sites — dev (ddev, `sites/ssc/dev`, prod (`/var/www/ssc`),
and the paired ssd/nwd tier if/when they exist.
**Author:** research + recommendation pass (consolidation arc 2026-07).

---

## 0. TL;DR recommendation

Build **`pl moodle plugins sync <site>`** as a thin *source-of-truth orchestrator* on top
of the **already-mature** guarded deploy in `scripts/commands/moodle.sh` +
`lib/moodle-deploy.sh`. The git repo becomes the single source of truth; the command:

- **clones/pulls** `ss-moodle-plugins` to a canonical local path;
- for the **dev tier**: **symlink-overlays** each `<type>/<name>` into the ddev Moodle
  root (Option 4's dev half) so Moodle runs the repo working-tree directly and edits/AMD
  builds land back in the repo — no more loose untracked plugins in the upstream Moodle
  clone;
- for the **live tier**: delegates verbatim to the **existing** `pl moodle plugin deploy
  <site> … --tier=live` guarded path (per-plugin rsync `--delete`, pre-deploy DB+code
  snapshot, `admin/cli/upgrade.php` under maintenance, `purge_caches.php`, NWP-ADR-0028
  deploy-gate, typed impact confirm). AI stays test-tier; real prod stays mons/operator-gated.

This is **Option 1 as the command surface, using Option 4's mechanism for dev and the
existing guarded rsync for live.** It beats plain Composer, submodules, and subtree *for
this repo* — reasons in §3.

The only new glue is: (a) the `sync` command; (b) a `.moodle.plugins[]` manifest block in
`sites/ssc/.nwp.yml` that the **existing** deploy already knows how to read
(`moodle.sh:110/115`); (c) a one-time `.git/info/exclude` hygiene fix in the dev Moodle
clone. No change to the guarded live primitives.

---

## 1. Current reality (verified 2026-07-25)

| Fact | Evidence |
|------|----------|
| Repo layout **already mirrors** the Moodle root as `<type>/<name>` | `auth/nwc`, `course/format/tabbed`, `local/{browse,feedback,mentor,practice,nwc_copyright_sync}`, `mod/depthcontent` — 8 plugins, each with `version.php`, at repo root |
| Dev tree is the **upstream Moodle clone** (`github.com/moodle/moodle.git`, 4.4.12+) | `git -C sites/ssc/dev remote -v` |
| Custom plugins sit **loose + untracked** inside that clone (not ignored, not excluded) | `git status` shows `?? auth/nwc/…`, `?? local/browse/`; `.git/info/exclude` has no entries |
| **Three divergent copies exist today**: dev loose tree, `~/nwptoolkit/moodle/plugins`, and now the git repo | dev has `local/browse/classes/privacy/` **not yet in the repo**; `~/nwptoolkit` still carries the `auth/nwc_oauth2` **decoy** + `blocks/dailyreview` + a `course-format/` (wrong) path shape |
| Existing guarded deploy already reads a manifest: `.moodle.plugins[].path` / `.from` | `scripts/commands/moodle.sh:110,115,170` |
| Existing deploy's default source is the **loose dev tree** then `~/nwptoolkit/.../<type>/<name>` | `moodle.sh:249-252`, `moodle-deploy.sh:191` |
| No plugin has a `composer.json` today | `find … -name composer.json` → none |
| ssc `.nwp.yml` has **no** `.moodle.plugins[]` block yet | grep → none |

**Two load-bearing consequences:**

1. The repo root maps 1:1 onto a Moodle root, so *any* rsync/symlink of `<type>/<name>` is
   trivial and needs **no path rewriting**. This is what makes the lightweight options viable
   and Composer's path-mapping machinery redundant.
2. Direction matters. The dev tree is currently **ahead** of the repo (the arc's ops#118
   Art.9 gate + a new `local/browse` privacy provider were authored in the dev tree). A
   naive "repo → overwrite dev" sync would **clobber in-progress dev work**. The dev
   mechanism must therefore make the repo *the* working copy (symlink), not an rsync target
   that overwrites. (Reconcile the current drift **into** the repo before cutover — §5.)

---

## 2. The existing guarded live path (do not reinvent)

`pl moodle plugin deploy <site> <plugin>… --tier=live --apply` already implements the
production-safe half and is the retirement of the old `scp+rm -rf+cp` idiom:

- structural guard: deploy set must be `<type>/<name>` subdirs only — `config.php` and
  `moodledata` are refused (`moodle_deploy_assert_set`, `moodle-deploy.sh:78`);
- maturity guard + pair guard (code-only ⇒ passes coupled-tier rule);
- **AMD freshness gate** — refuses to ship a plugin whose `amd/src/*.js` has no fresh
  `amd/build/*.min.js` (`moodle_amd_freshness_check`);
- **NWP-ADR-0028 deploy-gate** (`deploy_gate_require`) — Solo-touch on live `--apply`;
- typed **impact confirm** on live;
- **pre-deploy snapshot** (DB gzip via creds read from remote `config.php`, never on argv;
  plugin-dir tar — never moodledata) → recorded as a `moodle-remote` rollback entry;
- per-plugin **`rsync -az --delete`** into `<remote>/<type>/<name>/` (`--delete` is safe
  because scope is one plugin dir; `amd/src` excluded — only built `min.js` ships);
- `admin/cli/upgrade.php --non-interactive` → `purge_caches.php` under maintenance, fail-loud
  (leaves maintenance ON on failure, points at `pl moodle rollback`).

The recommendation **feeds** this path; it does not touch it.

---

## 3. Options evaluated

### Recommended — Option 1 (repo-as-source-of-truth `sync`) + Option 4 mechanism

`pl moodle plugins sync <site>`: clone/pull the repo to a canonical path, then
**symlink-overlay for dev / delegate to the guarded rsync for live.**

**Why it wins here**

- **Reuses** the mature, boundary-correct guarded live path unchanged — smallest new
  surface, keeps the mons/NWP-ADR-0028 gate intact.
- Repo layout = Moodle layout ⇒ zero path-mapping machinery needed.
- Symlink dev makes the **repo the working copy**: Moodle runs it live, `grunt amd` writes
  `amd/build` back through the symlink into the repo (so committed build artifacts stay in
  the repo and satisfy the freshness gate), and the upstream Moodle clone stops carrying
  loose untracked plugins. Collapses today's **three copies → one**.
- Identical `<type>/<name>` unit dev↔prod ⇒ one manifest drives both tiers.
- No new external network calls on prod (threat-model clean — contrast Composer §below).

**Trade-off:** dev edits must be made in the repo working tree (that's the point), and a
symlinked tree needs a `.git/info/exclude` line so the Moodle clone ignores it. A
`--rsync` fallback covers the rare case where a tool dislikes symlinks (behat on some
setups, container bind-mount quirks).

### Option 2 — git submodules / subtree

Embed `ss-moodle-plugins` into the Moodle root repo (submodule per `<type>/<name>`, or one
subtree). **Rejected because:**

- The Moodle root repo *is the upstream `moodle/moodle` clone* — you don't want to fork it or
  own its `.gitmodules`. 8 nested submodule paths inside a tree you pull from upstream is a
  detached-HEAD footgun the Moodle community itself flags.
- **It doesn't solve prod at all.** Prod (`/var/www/ssc`, www-data) is *not* a git checkout;
  it's fed by the guarded rsync. Submodules would fix dev-repo hygiene while leaving the
  entire live story to the existing rsync anyway — so it's strictly more moving parts than
  the symlink for the same dev benefit.
- Subtree bloats the (already huge) Moodle repo with vendored plugin history.
- Moodle's own guidance for a plugin developed inside the Moodle tree is to exclude it via
  `.git/info/exclude` (not `.gitignore`, which belongs to upstream) — i.e. keep it *out* of
  the core repo, the opposite of submodules. The symlink approach honours exactly that.

### Option 3 — Composer + `moodle/composer-installer` (the "modern" way)

Give each plugin a `composer.json` named `moodle-<type>_<name>`, publish to a private
Packagist/registry, and `composer install` at the Moodle root. **Rejected for this repo
because:**

- **Threat model.** `composer install` on prod pulls artifacts from a package registry over
  the network — a *new external network dependency on the prod server*, and a new supply-chain
  surface. NWP prod is fed only by signature-/rsync-verified pushes from the guarded path; it
  does not reach out. (CLAUDE.md: distrust third-party fetch on prod; no new external calls.)
- **Invasiveness.** The "composer-managed Moodle" pattern (michaelmeneses/moodle-composer)
  restructures the *whole* root into a composer project with `installer-paths` and needs a
  `keepfiles` directive so upgrades don't delete custom files. That's a large, risky change to
  a **running** full-clone site for the sake of **8 first-party** plugins.
- **No payoff here.** Composer's value is resolving *third-party* plugins + versions from a
  registry. These 8 are all first-party, already co-located, already deployed fine by rsync.
  Adding 8 `composer.json` + a registry + `allow-plugins` wiring buys nothing the manifest
  doesn't already give us.
- Keep it in the back pocket **only if** ss-moodle-plugins ever needs to consume versioned
  *external* contrib plugins; then add `composer.json` per plugin (still declare deps in
  `version.php` too, per moodledev) for a *dev-side* assembly — never a prod-side fetch.

### Option 4 — symlink overlay (dev) + rsync (prod), standalone

The right *mechanism*, but as a bare pair of verbs it lacks the clone/pull, the manifest,
the freshness/gate/snapshot chain, and an auditable explicit prod step. Folding it under the
Option 1 `sync` command (dev=symlink, live=guarded rsync) is what this recommendation is.

---

## 4. The command(s) to build

### 4.1 `pl moodle plugins sync <site> [--tier=dev|live] [--apply] [--rsync] [--ref=main]`

*(note the plural `plugins` — distinct from the existing singular `pl moodle plugin
build|deploy`.)*

**Behaviour**

1. **Resolve + fetch.** Read the site's `.moodle.plugins[]` manifest. For each distinct
   `source: git` repo, clone (if absent) or `git fetch && git checkout --detach <ref>` into a
   canonical cache, default `sites/<site>/.plugin-src/ss-moodle-plugins/` (gitignored). Record
   the resolved commit SHA for the deploy log / rollback registry.
2. **`--tier=dev` (default, local, no gate):**
   - default mechanism **symlink**: for each manifest `path` = `<type>/<name>`, ensure
     `sites/<site>/dev/<type>/<name>` is a symlink → the repo cache's `<type>/<name>`. If a
     *real* directory is already there (today's loose copy), refuse unless `--apply` and move
     it aside to `…/<name>.pre-sync.<ts>` first (never silent-delete).
   - `--rsync` mechanism: `rsync -a --delete --exclude=.git` repo `<type>/<name>` → dev tree
     (overwrite mode; prints an impact diff first — for the case where symlinks are unwanted).
   - add each `<type>/<name>` to `sites/<site>/dev/.git/info/exclude` (idempotent) so the
     upstream Moodle clone stops reporting them as untracked.
   - run the **local** AMD build for any plugin with `amd/src` (reuse `pl moodle plugin
     build <p> --ddev=<site>`), then `ddev … php admin/cli/upgrade.php` + `purge_caches.php`
     against the ddev site so version bumps register locally.
3. **`--tier=live`:** *do not* re-implement. Assert the repo cache is clean + on the intended
   ref, then **exec** `pl moodle plugin deploy <site> <plugin>… --tier=live` with the manifest
   set, pointing each plugin's `--from` at the repo cache (`<cache>/<type>/<name>`). All
   existing guards fire: freshness gate, deploy-gate (Solo), snapshot, per-plugin rsync,
   `upgrade.php`+`purge_caches` under maintenance, typed confirm. Dry-run by default; `--apply`
   required; AI is refused on real prod (mons boundary) exactly as today.

**Hook points into what already exists**

- version.php / classmap: handled by the **existing** `moodle_remote_upgrade`
  (`upgrade.php --non-interactive` → `purge_caches.php` under maintenance) for live, and by
  the ddev `upgrade.php`/`purge_caches` calls for dev. `sync` adds nothing here — it just
  ensures the freshly-synced code is in place *before* those run. A `version.php` bump is what
  makes Moodle re-run install/upgrade hooks and rebuild the class map; purge clears the cached
  map. No bump ⇒ code changes land but hooks/DB stay put (fine for pure template/JS edits).
- freshness gate + build: unchanged; `sync --tier=dev` calls `pl moodle plugin build`, and
  because dev is symlinked, the built `amd/build` lands **in the repo cache**, ready to commit.
- snapshot / rollback / deploy-gate: entirely inherited from the live path.

### 4.2 (optional, later) `pl moodle plugins status <site>`

Report, per manifest plugin: repo ref/SHA in cache vs dev symlink target vs (dry-run) live
rsync delta, and version.php value on each tier — a one-glance drift check across the three
places code can live. Cheap, high-value for the loose→tracked transition; not required for MVP.

---

## 5. Migration steps for ssc (and ssd/nwd if/when live)

Do these in order; each is reversible and none disturbs a running site until the explicit
`--apply` at step 6.

1. **Reconcile drift into the repo first (blocking).** The dev tree is currently *ahead* of
   `ss-moodle-plugins@main` (e.g. `local/browse/classes/privacy/`, the ops#118 gate). Diff
   every manifest plugin dev→repo, commit the dev-side additions onto the appropriate
   ss-moodle-plugins branch, and merge. **Verify the repo is a superset of the dev tree
   before any symlink cutover** — otherwise the symlink would "lose" the un-committed dev work
   the moment the real dir is moved aside. (Per-plugin diff counts on 2026-07-25: browse 2,
   feedback 4, auth/nwc 2, copyright_sync 2, depthcontent 2, tabbed 1, mentor 0, practice 0.)
2. **Retire the decoy + stale third copy.** Confirm `~/nwptoolkit/moodle/plugins` is no longer
   a source (it still carries the `auth/nwc_oauth2` **decoy** — which must never ship — plus
   `blocks/dailyreview` and a `course-format/` path shape). After cutover, `sync` sources only
   from the repo; point any lingering `.from` away from `~/nwptoolkit`.
3. **Add the manifest** to `sites/ssc/.nwp.yml` (the existing deploy already reads it):

   ```yaml
   moodle:
     cli_php_version: "8.2"          # Moodle 4.4 rejects PHP 8.4 (see moodle_cli_php_bin)
     plugins:
       - { path: auth/nwc,                  source: git }
       - { path: course/format/tabbed,      source: git }
       - { path: local/browse,              source: git }
       - { path: local/feedback,            source: git }
       - { path: local/mentor,              source: git }
       - { path: local/practice,            source: git }
       - { path: local/nwc_copyright_sync,  source: git }
       - { path: mod/depthcontent,          source: git }
     plugin_source:
       repo: git@git.nwpcode.org:nwp/ss-moodle-plugins.git
       ref: main
   ```

   (`source: git` is a new hint the `sync` command reads; the *existing* `deploy` only needs
   `path`, and optionally `from` — which `sync` supplies at call time pointing at the cache.)
4. **Clone the cache + exclude hygiene:** `pl moodle plugins sync ssc --tier=dev` (dry-run)
   then `--apply`. This moves the loose dirs aside to `*.pre-sync.<ts>`, symlinks the repo in,
   adds `.git/info/exclude` lines, rebuilds AMD, and runs the ddev upgrade. Smoke the ddev
   site. Reversible: delete symlinks, restore the `*.pre-sync.<ts>` dirs.
5. **Live dry-run:** `pl moodle plugins sync ssc --tier=live` (dry-run) — inspect the impact
   manifest + per-plugin rsync plan. No writes.
6. **Live apply — human/mons-gated.** On the operator/mons desktop:
   `pl moodle plugins sync ssc --tier=live --apply` → Solo touch → typed confirm → snapshot →
   rsync → `upgrade.php`+purge under maintenance → smoke. AI must not run this against real
   `ssc.nwpcode.org` prod; the test tier (`*.nwpcode.org` disposable) is the AI's ceiling per
   the arc guardrails.
7. **ssd / nwd:** identical, *when* they have `live.enabled` sites. ssd pairs against nwd and
   shares the same 8-plugin manifest (drop the `auth/nwc` UID-lock nuance per the pair
   contract). Until they're live, `--tier=dev` only. Respect the standing `--code-only` rule
   for any nwc-paired live deploy (plugin deploys are code-only by construction, so this holds
   automatically).

---

## 6. Risks & gotchas

- **Repo must be a superset before symlink cutover (§5.1).** This is the one true footgun:
  the dev tree currently has un-committed work the repo lacks. Moving the real dir aside
  before that work is in the repo would strand it in `*.pre-sync.<ts>`. Gate the cutover on a
  clean dev→repo diff.
- **version.php bump ⇒ upgrade + classmap.** A plugin whose code changed but whose
  `$plugin->version` did **not** bump will land on disk but Moodle won't run its
  install/upgrade hooks or rebuild the class map. Symptom: "new code, old behaviour," or a
  fatal after adding a new class file. Fix: bump `version.php`; the existing `upgrade.php` +
  `purge_caches.php` sequence then rebuilds. `sync` should *warn* when it detects changed
  files with an unchanged version (a cheap `status` check).
- **AMD/classmap caches.** Purge is already in the live sequence; on dev the `sync` must call
  `purge_caches.php` after a build or the browser serves the old `min.js`. Symlinked dev means
  `grunt amd` writes into the repo cache — good, but ensure ddev's bind-mount follows symlinks
  (default on Linux; if not, use `--rsync`).
- **Symlink edge cases.** Some Moodle tooling (older behat, Windows, certain container FS)
  dislikes symlinked component dirs. `--rsync` is the escape hatch; keep it a first-class flag.
- **`.git/info/exclude`, not `.gitignore`.** Excluding the plugins from the upstream Moodle
  clone must use `.git/info/exclude` (local, private) — never the tracked `.gitignore`, which
  belongs to upstream Moodle. (Moodle dev guidance.)
- **`--delete` blast radius.** Safe *only* because scope is one `<type>/<name>` dir; the
  existing `moodle_deploy_assert_set` refusal of `config.php`/`moodledata` is the guardrail —
  don't let `sync` ever pass a bare root or a non-`type/name` path through.
- **Ref pinning + provenance.** `sync` should record the deployed commit SHA (and ideally
  require a tag/immutable ref for live) so a rollback maps to an exact repo state, complementing
  the DB/code snapshot the guarded path already records.
- **Three-copy reconciliation is one-time but easy to half-do.** After cutover, actively
  *delete/retire* the loose dev dirs and stop sourcing `~/nwptoolkit`, or drift returns.

---

## 7. Sources

Moodle / community best practice:

- [Composer support for plugins — Moodle Developer Resources](https://moodledev.io/docs/5.2/guides/composer) — official `moodle/composer-installer`, `moodle-<type>_<name>` naming, declare in `require`, keep deps in `version.php` too.
- [moodle/composer-installer (GitHub)](https://github.com/moodle/composer-installer) and [Packagist](https://packagist.org/packages/moodle/composer-installer).
- [composer/installers (`installer-paths` / `installer-name`)](https://packagist.org/packages/composer/installers).
- [michaelmeneses/moodle-composer](https://github.com/michaelmeneses/moodle-composer) — root-level composer-managed Moodle; `keepfiles` to survive upgrades (illustrates Option 3's invasiveness).
- [Installing plugins — MoodleDocs](https://docs.moodle.org/501/en/Installing_plugins).
- [managing plugins with git — Moodle.org forum](https://moodle.org/mod/forum/discuss.php?d=416984) and [Managing Multiple Custom Moodle Instances](https://moodle.org/mod/forum/discuss.php?d=425786) — submodules vs single-fork vs assembly-script trade-offs.
- [Tutorial on using git in Moodle development — MoodleDocs](https://docs.moodle.org/dev/Tutorial_on_using_git_in_Moodle_development) — nested plugin repos, exclude via `.git/info/exclude` (not `.gitignore`).
- [Git for Moodle Admins (ElearningWorld)](https://www.elearningworld.org/git-for-moodle-admins-part-3/).

NWP internal (verified in-tree 2026-07-25):

- `scripts/commands/moodle.sh`, `lib/moodle-deploy.sh` — existing guarded build/deploy/upgrade/backup/rollback + `.moodle.plugins[]` manifest reader.
- `sites/ssc/.nwp.yml`, `sites/ssc/dev/` (upstream `moodle/moodle` clone with loose untracked plugins), `~/nwptoolkit/moodle/plugins/` (stale third copy incl. `auth/nwc_oauth2` decoy).
- `docs/reports/consolidation-arc-2026-07/{README.md,decision-log.md}` — arc guardrails (AI=test-tier, mons/operator-gated prod, `--code-only` for nwc-paired live), Plane-2 decision to home ssc plugins in `nwp/ss-moodle-plugins`.
- NWP-ADR-0028 (deploy-gate Solo touch), NWP-ADR-0029 (paired-site `--code-only`).
