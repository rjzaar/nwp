# Moodle plugin manifest + installer + lockfile — design (ADR-0031 Phase A / ops#73)

> **Status: DESIGN — NOT YET WIRED.** This document specifies the file
> formats/schemas and the reconcile mechanics for the Moodle side of ADR-0031
> (plane 3). The example artifacts below are *illustrative* — they are not
> installed by any code yet and MUST NOT be treated as the source of truth for
> any live site. Wiring (the `pl`-managed installer + lockfile emission) is the
> back half of ops#73 and depends on operator-hands reconcile steps that can only
> run on the build host (see the companion runbook,
> [`ops73-phase-a-reconcile-runbook.md`](ops73-phase-a-reconcile-runbook.md)).
> **Date:** 2026-07-10. **Author:** AI (Phase-A planning session, read-only).
> **ADR:** [ADR-0031](../decisions/0031-paired-site-versioning-and-promotion.md)
> D3 (tagging), D4 (repo boundaries — manifest + installer + lockfile).

---

## 0. Why this exists (the drift ADR-0031 D4 names)

The Moodle side has **no taggable boundary today**: custom plugins sit as
untracked files inside upstream-Moodle clones, the two GitLab plugin repos have
already drifted from the working trees, and the canonical build source
(`~/dir/courses_v3/plugins/`) has no git remote. D4's fix is: **the GitLab
plugin repo is the versioned unit; site trees are not.** Plugins deploy into a
site tree via a **manifest + installer**, and each site tree carries a
**lockfile** recording exactly which plugin versions are installed — the Moodle
analogue of `composer.lock` ("lock flows up").

This design extends the **already-proven pattern** at
`~/dir/courses_v3/plugins/manifest.yaml` + `~/dir/courses_v3/build/install_plugins.sh`
+ `verify_plugins.sh` (D4: "adopting the proven `~/dir/courses_v3/plugins/`
manifest + `install_plugins.sh` pattern"). It does **not** invent a new
mechanism — it adds a `release`/tag/repo layer and a lockfile to what exists.

### Observed drift (this session, read-only, 2026-07-10)

`$plugin->version` / `$plugin->release` across the local dev Moodle trees vs the
canonical build source:

| Plugin (component) | ss/dev | ssc/dev | ssd/dev | `courses_v3` canon | GitLab repo |
|---|---|---|---|---|---|
| `local_nwc_copyright_sync` | `2026051700` / `0.1.0` | **`2026052000` / `0.2.0`** | **`2026052000` / `0.2.0`** | `2026051700` / `0.1.0` | `nwp/local-nwc-copyright-sync` (pushed `0.1.0`, 2026-05-19) |
| `local_feedback` | `2026051704` / `0.1.0` | `2026051704` / `0.1.0` | `2026051704` / `0.1.0` | `2026051704` / `0.1.0` | *(none)* |
| `auth_nwc_oauth2` | absent | absent | absent | `2026011300` / `1.0.0` (README claims `2026052000` / `1.1.0`) | `nwp/auth-nwc-oauth2` (pushed 2026-05-19); F26 build staged in `nwp/nwp!49` |
| `mod_depthcontent` | `2026041500` / `1.1.0` | absent | absent | `2026041500` / `1.1.0` | *(none)* |
| `block_dailyreview` | `2026041300` / `0.1.0` | absent | absent | `2026041300` / `0.1.0` | *(none)* |
| `format_tabbed` | `2026030900` / *(empty release)* | absent | absent | `2026030900` / *(empty release)* | *(none)* |
| `local_browse` | `2026051700` / `0.1.0` | absent | absent | `2026051700` / `0.1.0` | *(none)* |
| `auth_avc_oauth2` (legacy) | `2026011300` / `1.0.0` | absent | absent | not in manifest | *(none)* |
| `local_avc_copyright_sync` (legacy) | `2026051700` / `0.1.0` | absent | absent | not in manifest | *(none)* |
| `local_courses_v3` | `2026051700` / `0.1.0` | absent | absent | **not in manifest** (undeclared) | *(none)* |

Three drift classes fall out of this table:

1. **Newest-wins reconcile (D4):** `local_nwc_copyright_sync` `0.2.0` on ssc/ssd
   is the newest state; it must be reconciled *into* the GitLab repo (currently
   `0.1.0`) and into the canonical `courses_v3` manifest/source (currently
   `0.1.0`). ss's `0.1.0` is stale.
2. **Canon disagrees with itself:** `auth_nwc_oauth2` `manifest.yaml`
   (`1.0.0`/`2026011300`) vs `plugins/README.md` (`1.1.0`/`2026052000`) vs the
   F26 build staged in `nwp/nwp!49`. Which is newest is an **operator decision on
   the build host** (see runbook TODO-A1).
3. **Legacy AVC-named plugins on the frozen ss site:** `auth_avc_oauth2`,
   `local_avc_copyright_sync` are superseded by their `nwc_`-named equivalents.
   `local_courses_v3` is installed on ss but declared in no manifest. These are
   *not* on ssc/ssd and are out of scope for the paired sites; flag-only.

> **ss vs ssc/ssd:** ss carries the full v3 catalog plugin set (depthcontent,
> dailyreview, tabbed, browse) plus the legacy AVC plugins; ssc/ssd (the paired
> integration/demo sites) carry only `local_feedback` + `local_nwc_copyright_sync`
> and **no auth plugin at all**. That asymmetry is expected — the manifest
> supports it via per-plugin `sites:`/`optional:` selection (§2.3).

---

## 1. The three artifacts and where they live

| Artifact | Path | Repo it lives in | Role | Who writes it |
|---|---|---|---|---|
| **Manifest** | `plugins/manifest.yaml` | canonical build source (`courses_v3`, once it has a remote — D4) | declares every custom plugin + its canonical repo + version/release + which sites get it | operator/AI, reviewed |
| **Installer** | `build/install_plugins.sh` (+ `verify_plugins.sh`) | same repo as manifest | copies plugins into a target Moodle tree per manifest; **emits/updates the lockfile** | code (already exists; extend) |
| **Lockfile** | `<site-moodle-root>/.nwp-plugins.lock.yml` | the site's Moodle tree (upstream clone) | records exactly which plugin versions are installed in *this* tree | the installer, on each run |

"Manifest declares intent; lockfile records fact." The manifest is the same for
all sites (with per-site selection); the lockfile is per-site-tree and is the
answer to "what is actually deployed on ssc/ssd/ss right now."

---

## 2. Manifest schema v2 (extends the existing v1)

The existing `manifest.yaml` is `schema_version: 1`. Phase A bumps it to
`schema_version: 2`, adding the D3/D4 fields (`repo`, `tag`, `sites`) and
tightening `release` to be **mandatory and semver** (v1 allowed an empty
`release`, which `format_tabbed` exploits — that is exactly the "bumping
`release` without tagging" failure mode D3 wants CI-checked).

### 2.1 Top-level keys

```yaml
schema_version: 2
manifest_updated: "YYYY-MM-DD"
# Canonical source repo for this manifest itself (D4: courses_v3 gets a remote).
source_repo: "git@<gitlab-host>:nwp/courses-plugins.git"   # TODO-A6: subtree-split target
plugins: [ ... ]                                            # list, schema below
```

### 2.2 Per-plugin keys

```yaml
- name: nwc_copyright_sync          # short name (dir under type/)
  type: local                       # Moodle plugin type (maps to install path, §2.4)
  component: local_nwc_copyright_sync # Moodle frankenstyle component — the join key
  title: "NWC Copyright Sync (receiver)"

  # --- versioning (D3) ---------------------------------------------------
  version: 2026052000               # $plugin->version — Moodle-native monotonic key (YYYYMMDDXX)
  release: "0.2.0"                   # $plugin->release — semver; MUST equal the repo tag (below)
  requires: 2024042200              # $plugin->requires — min Moodle core version (optional)

  # --- repo boundary (D4) ------------------------------------------------
  repo: "git@<gitlab-host>:nwp/local-nwc-copyright-sync.git"  # canonical repo (empty = lives in source_repo)
  tag: "v0.2.0"                     # the git tag that pins this release (D3: tag == release)

  # --- deployment --------------------------------------------------------
  source: ~/dir/courses_v3/plugins/local/nwc_copyright_sync   # build-source dir (reconcile target)
  target_path: local/nwc_copyright_sync                        # path under the Moodle root
  optional: false                                              # installer skips silently if source missing
  sites: [ss, ssc, ssd]             # which sites install this (omit/"*" = all) — encodes the asymmetry
  security_critical: true           # copyright-sync & auth get extra review (CLAUDE.md sensitive paths)
```

### 2.3 Field rules (what CI enforces — the ops B check, previewed here)

- `component` is the **join key** everywhere (manifest ↔ version.php ↔ lockfile).
- `version` in the manifest MUST equal `$plugin->version` in the source's
  `version.php` (existing `verify_plugins.sh` check 3 already does this).
- `release` MUST be non-empty semver AND MUST equal `tag` minus its `v` prefix
  (`release: 0.2.0` ⇔ `tag: v0.2.0`). **This is the D3 "bumped release without
  tagging" guard.** (`format_tabbed`'s empty release fails this — fix in reconcile.)
- `repo` empty ⇒ the plugin is vendored inside `source_repo` (no standalone
  GitLab repo); non-empty ⇒ that repo is canonical and `tag` must exist there.
- `sites` selects targets; an absent `sites` means "all". `optional: true`
  makes a missing source a skip, not an error (today's `auth_nwc_oauth2` case).

### 2.4 Type → path map (unchanged from v1, restated for completeness)

`mod → mod/<n>`, `blocks → blocks/<n>`, `course-format → course/format/<n>`,
`auth → auth/<n>`, `local → local/<n>`, `theme → theme/<n>`, `filter → filter/<n>`,
`enrol → enrol/<n>`, `qtype → question/type/<n>`, `qbehaviour → question/behaviour/<n>`.

### 2.5 Full example (reconciled — post-runbook target state)

```yaml
schema_version: 2
manifest_updated: "2026-07-10"
source_repo: "git@<gitlab-host>:nwp/courses-plugins.git"   # TODO-A6

plugins:
  - name: nwc_copyright_sync
    type: local
    component: local_nwc_copyright_sync
    title: "NWC Copyright Sync (receiver)"
    version: 2026052000            # reconciled UP from ssc/ssd 0.2.0 (D4 newest-wins)
    release: "0.2.0"
    requires: 2024042200
    repo: "git@<gitlab-host>:nwp/local-nwc-copyright-sync.git"
    tag: "v0.2.0"                  # TODO-A3: tag the repo at reconciled 0.2.0
    source: ~/dir/courses_v3/plugins/local/nwc_copyright_sync
    target_path: local/nwc_copyright_sync
    optional: false
    sites: [ss, ssc, ssd]
    security_critical: true

  - name: feedback
    type: local
    component: local_feedback
    title: "Saint School feedback widget"
    version: 2026051704
    release: "0.1.0"
    requires: 2024042200
    repo: ""                       # vendored in source_repo (no standalone repo yet)
    tag: "v0.1.0"
    source: ~/dir/courses_v3/plugins/local/feedback
    target_path: local/feedback
    optional: false
    sites: [ss, ssc, ssd]
    security_critical: false

  - name: nwc_oauth2
    type: auth
    component: auth_nwc_oauth2
    title: "NWC OAuth2 SSO (F26)"
    version: 2026052000            # TODO-A1: operator confirms newest (README/​nwp!49 vs manifest)
    release: "1.1.0"
    requires: 2022041900
    repo: "git@<gitlab-host>:nwp/auth-nwc-oauth2.git"
    tag: "v1.1.0"                  # TODO-A3
    source: ~/dir/courses_v3/plugins/auth/nwc_oauth2
    target_path: auth/nwc_oauth2
    optional: true                 # ssc/ssd don't have it installed yet; F26 review gates real deploy
    sites: [ss, ssc, ssd]
    security_critical: true        # auth code — two-person review (CLAUDE.md)

  # depthcontent / dailyreview / tabbed / browse: catalog plugins, ss-only.
  # Included with sites: [ss] once tabbed's empty release is fixed (TODO-A4).
```

---

## 3. Lockfile schema — `<site-moodle-root>/.nwp-plugins.lock.yml`

Emitted/updated by the installer on every run. It is the per-tree record of
**installed fact**. It lives inside the site's Moodle clone (upstream tree), is
committed to that clone (or, if the clone stays pristine-upstream, tracked by
`pl` alongside the site's `.nwp.yml`). It is the Moodle analogue of
`composer.lock`.

### 3.1 Schema

```yaml
lockfile_version: 1
site: ssc                          # nwp site key (§4 registration)
moodle_root: /var/www/ssc          # where these were installed (informational)
manifest_source_repo: "git@<gitlab-host>:nwp/courses-plugins.git"
manifest_commit: "<sha>"           # the manifest commit this install was rendered from
generated_at: "2026-07-10T00:00:00Z"
generated_by: "install_plugins.sh"

installed:
  - component: local_nwc_copyright_sync
    version: 2026052000
    release: "0.2.0"
    repo: "git@<gitlab-host>:nwp/local-nwc-copyright-sync.git"
    tag: "v0.2.0"
    source_sha256: "<sha256 of the copied source dir tree>"   # tamper/drift detector
    installed_at: "2026-07-10T00:00:00Z"
  - component: local_feedback
    version: 2026051704
    release: "0.1.0"
    repo: ""
    tag: "v0.1.0"
    source_sha256: "<sha256>"
    installed_at: "2026-07-10T00:00:00Z"
```

### 3.2 What the lockfile buys us

- **Answers "what is deployed on ssc right now?"** — unanswerable today
  (untracked files, no tags).
- **Drift detection:** re-run `verify_plugins.sh --against-lock <root>` compares
  the live `version.php` + `source_sha256` in the tree against the lockfile;
  any mismatch is the exact drift this ADR is cleaning up (e.g. someone hot-edits
  a plugin on the server).
- **Pair-versioning input (ops C):** `pair_guard` and the pair smoke suite read
  both halves' deployed versions; the ssc lockfile is where the Moodle half's
  version comes from. `local_nwc_copyright_sync`'s release in the lockfile is the
  concrete "copyright-sync surface version" the pair contract's data rail needs.
- **`source_sha256`** is a cheap integrity check that the deployed tree equals
  the tagged source — no server write needed to verify, just a read + hash.

### 3.3 Example — ssc today (as-installed, pre-reconcile) vs target

`ssc/.nwp-plugins.lock.yml` **as it would read for the current tree** (feedback
`0.1.0`, copyright_sync `0.2.0`, no auth plugin) is a faithful snapshot; the
**target** after reconcile pins those to real repo tags (`v0.2.0`, `v0.1.0`) and
adds `auth_nwc_oauth2` only once F26 review lands and it is actually installed.

---

## 4. `ssc`/`ssd` registration (D4)

Read-only finding: global `nwp.yml` registers `ss`, `ssd`, and **`ssc1`** — but
the site directory is `sites/ssc` (moodledata `ssc1_moodledata`). So **`ssc` is
effectively unregistered / name-mismatched** (ADR-0031: "ssc is not registered
in global `nwp.yml` at all — its guards evaluate invisible defaults"). Both
`sites/ssc/.nwp.yml` and `sites/ssd/.nwp.yml` exist per-site.

Registration is an **operator action** (`nwp.yml` is never committed — CLAUDE.md;
the template goes in `example.nwp.yml`). The stanza each site needs:

```yaml
# in nwp.yml under sites:  (template mirror in example.nwp.yml)
  ssc:
    project:
      type: moodle              # ⚠ nothing reads project.type yet (ADR-0031 ops D) — set it now so it's ready
    paired_with: nwc            # ADR-0031 provider; consumed by ops C pair_guard (dead key until then)
    canonical: live             # real students → user state canonical (D6 directional invariant)
    maturity: ...               # operator assigns per P67
  ssd:
    project:
      type: moodle
      demo: true
    paired_with: nwd
    canonical: dev              # demo twin
```

- **TODO-A5 (operator):** resolve the `ssc` vs `ssc1` naming — either rename the
  directory to match the config key or (recommended) register the key `ssc` to
  match the directory `sites/ssc`, and reconcile the stray `ssc1` entry +
  `ssc1_moodledata`. This mismatch is why ssc "evaluates invisible defaults."

---

## 5. Installer changes (design — extends the existing script)

The existing `install_plugins.sh` already: parses `manifest.yaml` via
python3+pyyaml, validates the target is a Moodle root, copies each plugin
atomically, runs `admin/cli/upgrade.php`. Phase-A additions (all backward
compatible; no live write in this branch):

1. **Site selection:** accept `--site <key>`; skip plugins whose `sites:` list
   excludes the key. (Encodes ss-full vs ssc/ssd-minimal.)
2. **Lockfile emission:** after a successful copy pass, write/refresh
   `<target>/.nwp-plugins.lock.yml` (§3) — component, version, release, repo,
   tag, `source_sha256` (`tar cf - <src> | sha256sum` over sorted entries),
   timestamps, and the manifest commit sha.
3. **`--against-lock` verify mode** in `verify_plugins.sh`: read an existing
   lockfile, re-hash the live tree, report drift; exit non-zero on mismatch.
   This is the read-only drift check operators/CI run against ss/ssc/ssd.
4. **`release`/`tag` validation** folded into `verify_plugins.sh` (the ops B CI
   check, D3): non-empty semver `release`, `release`⇔`tag` consistency.
5. **`pl` wrapper (ops D territory, named here):** `pl moodle plugins install
   <site>` / `pl moodle plugins verify <site>` so this is `pl`-managed (D4)
   rather than a loose script. Kept out of Phase A's write scope — flagged.

> Every change above is **AI-preparable on the build host** (pure bash/python,
> host-side, no Moodle/DB dependency, no server write). None of it is wired in
> this planning branch — it is the back half of ops#73, sequenced after the
> operator-hands reconcile in the runbook.

---

## 6. Sequencing (ADR-0031 Implementation Notes: A → B → C)

1. **This branch (Phase-A plan):** design (this doc) + runbook. No live writes.
2. **Reconcile (operator + AI on build host):** runbook §1–§5 — settle drift,
   create/tag the plugin repos, give `courses_v3` a remote, bump manifest to v2.
3. **Wire the installer/lockfile (AI on build host):** §5 changes + CI checks
   (this is where ops A meets ops B's tag↔release CI).
4. **ops C** then consumes the lockfiles for `pair_guard` + pair smoke.

Nothing here touches the security-critical Moodle **sanitizer** or `moodledata`
(that is ops D). The two `security_critical: true` plugins (`auth_nwc_oauth2`,
`local_nwc_copyright_sync`) get two-person review on reconcile per CLAUDE.md.
