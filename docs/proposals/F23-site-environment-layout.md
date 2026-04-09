# F23: Site Environment Layout — Per-Site Directory Restructure

**Status:** PROPOSED
**Created:** 2026-04-09
**Author:** Rob Zaar, Claude Opus 4.6
**Priority:** High (blocks F18 backup paths; blocks `pl live2stg` / `pl stg2live` for F17-migrated sites)
**Depends On:** F17 (Project Separation) — phases 1-8 complete (prerequisite satisfied)
**Breaking Changes:** Yes — site directory paths change; all commands that resolve site paths require updates
**Estimated Effort:** 12-18 hours across 5 phases

---

## 1. Executive Summary

### 1.1 Problem Statement

F17 moved sites into self-contained `sites/<name>/` directories with per-site
`.nwp.yml`, but left three problems unsolved:

1. **Flat layout conflates code with environment state.** `sites/ba/` is
   simultaneously the DDEV project root, the backup target, the scripts
   directory, and the git checkout. There is no separation between "the
   Drupal project" and "the NWP wrapper that manages it."

2. **Sync scripts are broken for F17-migrated sites.** `live2stg.sh` and
   `stg2live.sh` still read from the root `nwp.yml` (looking for a
   `sites.<name>.live.server_ip` path that no longer exists) and target
   `sites/<name>-stg/` sibling directories. Both assumptions are stale.
   Any site that completed F17 migration cannot use `pl live2stg` or
   `pl stg2live`.

3. **`-stg` siblings are unmanaged.** `sites/avc-stg/`, `sites/cathnet-stg/`,
   `sites/dir1-stg/` exist as full filesystem copies with no `.nwp.yml`,
   no backup config, and no migration tracking. They are invisible to
   `pl site list` and drift silently.

### 1.2 Proposed Solution

Restructure every site from:

```
sites/<name>/          ← flat: DDEV + code + backups + scripts all mixed
```

To:

```
sites/<name>/          ← NWP site container (identity + shared resources)
├── .nwp.yml           ← site-level config (identity, live server, recipe)
├── dev/               ← DDEV project: active development (test data, debug on)
│   ├── .ddev/
│   ├── .nwp.yml       ← env-level config (environment: development)
│   ├── composer.json
│   ├── web/
│   └── ...
├── stg/               ← DDEV project: staging (sanitised live DB, deploy testing)
│   ├── .ddev/
│   ├── .nwp.yml       ← env-level config (environment: staging)
│   ├── composer.json
│   ├── web/
│   └── ...
├── backups/           ← DB dumps from live (shared, outside DDEV/git)
└── scripts/           ← maintenance scripts (shared, optionally in git)
```

This creates a clean two-tier structure:

- **Site level** (`sites/<name>/`) — NWP's management layer. Holds identity,
  backup config, shared resources. Not a DDEV project. Not a git checkout.
- **Environment level** (`sites/<name>/dev/`, `sites/<name>/stg/`) — the
  Drupal project itself. Each is its own DDEV project, own potential git
  worktree, own webroot.

For **live-enabled sites** (`live.enabled: true`), both `dev/` and `stg/` are
created by default. `dev/` is the active development workspace (test data,
debug mode, feature work). `stg/` is the pre-deploy testing workspace
(sanitised live DB, production-like config). They run as independent DDEV
projects (`<name>-dev.ddev.site`, `<name>-stg.ddev.site`) and can operate
simultaneously — edit code in dev/ while testing a migration in stg/.

For **non-live sites** (experiments, local-only), only `dev/` is created.
`stg/` can be added later with `pl site env add <name> stg`.

The disk cost of stg/ is modest (~200 MB for vendor/ + a few MB for the DB
copy). When not in use, `ddev stop` reclaims all RAM.

### 1.3 Relationship to Other Proposals

- **F17** (Project Separation) — prerequisite; F23 is the "Phase 2" that
  F17's layout left unfinished
- **F18** (Unified Backup Strategy) — F23 establishes the `backups/`
  directory path that F18's restic/borg scripts will target. F18 should
  be implemented after F23 so backup paths are stable.
- **F21** (Distributed Build/Deploy Pipeline) — F23's fixed sync scripts
  are prerequisites for F21's automated build/deploy flows

---

## 2. Goals & Non-Goals

### Goals

- Live-enabled sites follow `<name>/{dev,stg,backups,scripts}` layout;
  non-live sites get `<name>/{dev,backups,scripts}` (stg added on demand)
- `pl live2stg <name>` and `pl stg2live <name>` work for all F17-migrated
  sites, reading from per-site `.nwp.yml` (not root `nwp.yml`)
- `pl site list`, `pl site show`, `discover_sites()`, `resolve_project()`
  handle the new depth-2 layout
- Schema v2 migration is idempotent, reversible (dry-run), and handles
  all existing sites including `-stg` siblings
- DDEV project names are unambiguous (`ba-dev` not `ba`)
- Shared resources (backups/, scripts/) live at the site level, outside
  the DDEV project and outside git

### Non-Goals

- **Server-hosted staging environments.** Research confirmed local DDEV
  is sufficient for NWP's solo-dev, single-Linode setup. A server-side
  stg vhost adds maintenance cost with minimal benefit.
- **Server-hosted staging.** Local DDEV stg/ is sufficient for NWP's
  solo-dev, single-Linode setup. A server-side stg vhost on nwpcode.org
  adds maintenance cost with minimal benefit over local DDEV.
- **Per-site git repo creation.** Whether `sites/ba/dev/` gets its own
  git repo is a per-site decision, not an NWP core concern. NWP should
  provide `pl site repo init` as tooling; individual sites decide when
  to use it.
- **Backup scheduling or offsite replication.** That is F18's scope.
  F23 only establishes the directory paths.
- **Moodle site integration.** `sites/ss/` and `sites/mayo/` lack
  `.nwp.yml` entirely. Bringing them into the per-site config system
  is prerequisite work outside F23's scope.

---

## 3. Options Considered

### 3.1 Option 1 — Three subdirectories (dev/ + stg/ + live/)

Each site gets `dev/`, `stg/`, and `live/` as separate DDEV projects.

**Rejected.** A local `live/` directory adds no value — live is on the
server. The `dev/` + `stg/` split is valuable; a `live/` copy is not.

### 3.2 Option 2 — Keep `-stg` siblings, fix scripts only

Leave the directory layout unchanged. Update `live2stg.sh` and `stg2live.sh`
to read per-site `.nwp.yml` while keeping the `<name>-stg/` convention.

**Rejected.** This perpetuates the core problem: `-stg` siblings have no
`.nwp.yml`, are invisible to `pl site list`, and drift. It also does not
address the flat-layout conflation of code with environment state.

### 3.3 Option 3 — dev/ + stg/ inside site wrapper *(recommended)*

Live-enabled sites get `<name>/dev/` and `<name>/stg/` as two independent
DDEV projects under a site-level wrapper. Non-live sites get `dev/` only.
Shared resources (backups/, scripts/) live at the site level.

`dev/` is the active development workspace: test data, debug on, feature
work. `stg/` is the pre-deploy testing workspace: sanitised live DB,
production-like config. Both can run simultaneously (~350 MB RAM each;
`ddev stop` when not in use costs zero). The disk overhead for stg/ is
modest (~200 MB for vendor/).

**Selected.** Solves all three problems in § 1.1. Protects dev state
when pulling live data for testing. Absorbs existing `-stg` siblings
rather than leaving them unmanaged.

---

## 4. Implementation Phases

### Phase 1: Schema v2 definition (2 hours)

Define the two-tier `.nwp.yml` schema:

**Site-level** (`sites/<name>/.nwp.yml`):

```yaml
schema_version: 2
project:
  name: ba
  type: drupal
  recipe: d
  created: "2026-04-07T12:27:44Z"
live:
  enabled: true
  domain: ba.nwpcode.org
  server: nwpcode
  remote_path: /var/www/ba
environments:
  - dev
  - stg
backups:
  directory: ./backups
```

**Env-level** (`sites/<name>/dev/.nwp.yml`):

```yaml
schema_version: 2
environment: development
parent_site: ba
ddev_name: ba-dev
```

**Env-level** (`sites/<name>/stg/.nwp.yml`):

```yaml
schema_version: 2
environment: staging
parent_site: ba
ddev_name: ba-stg
settings:
  stage_file_proxy: true
  database_sanitize: true
```

Update `example.nwp.yml` to document both tiers.

### Phase 2: Update core libraries (4-6 hours)

Update the resolution chain in `lib/project-resolver.sh`:

- `resolve_project("ba")` → `sites/ba/dev/` (the DDEV root)
- `resolve_project("ba", "site")` → `sites/ba/` (the site container)
- `discover_sites()` → finds site-level `.nwp.yml` at depth 1 (schema v2),
  returns site names (not env names)
- `get_site_config_value()` → reads site-level `.nwp.yml` for identity/live
  config, env-level `.nwp.yml` for environment config
- `get_backup_dir()` → returns `sites/<name>/backups/` (site level, unchanged)

Update `lib/migrate-schema.sh`:
- Add `CURRENT_SITE_SCHEMA=2`
- Create `lib/migrations/site/002-env-layout.sh`

Update DDEV-related logic:
- `pl site init` creates the nested layout from scratch (dev/ always,
  stg/ when `live.enabled: true`)
- DDEV project names use `<name>-dev` and `<name>-stg` convention

### Phase 3: Fix sync scripts (4-6 hours)

**`live2stg.sh`:**
- Replace `get_live_config()` AWK on root `nwp.yml` with
  `get_site_config_value <name> '.live.server'` → resolve via
  `lib/server-resolver.sh` → `get_server_ip()`
- Target `sites/<name>/stg/` (the staging environment, not dev/)
- Add `--dry-run` flag (show what would be synced without executing)
- Run `drush sql:sanitize` after DB import (strip PII from live data)

**`stg2live.sh`:**
- Same config-source migration as live2stg
- Source from `sites/<name>/stg/` instead of `sites/$name-stg/`
- Replace `is_live_security_enabled()` and `get_security_modules()`
  AWK parsers with `get_site_config_value` calls

**`dev2stg.sh`** (new or updated):
- Copy code from dev/ → stg/ (rsync excluding .ddev, vendor, files)
- Run `composer install` in stg/
- Keep stg/ database intact (live data for testing)

**Other affected scripts:**
- `backup.sh` — verify `get_backup_dir()` still resolves correctly
- `site-init.sh` — generate nested layout
- `site-list.sh`, `site-show.sh` — use updated `discover_sites()`

### Phase 4: Schema v2 migration script (2-3 hours)

Create `lib/migrations/site/002-env-layout.sh` with `migrate_001_to_002()`:

1. **Detect current state:** Is this a flat v1 site? Does a `-stg` sibling
   exist? Is `live.enabled: true`?
2. **Create site container:** `mkdir -p sites/<name>/backups`
3. **Move contents into dev/:** `mv` everything except `.nwp.yml` and
   `backups/` into `sites/<name>/dev/`
4. **Split `.nwp.yml`:** Extract identity fields → site-level `.nwp.yml`;
   create env-level `.nwp.yml` in `dev/` with `environment: development`
5. **Rename DDEV project:** Update `.ddev/config.yaml` `name:` field to
   `<name>-dev`; run `ddev stop` before rename to avoid ghost containers
6. **Create stg/ for live-enabled sites:** If `live.enabled: true`:
   - If `sites/<name>-stg/` exists: move its contents into `sites/<name>/stg/`
     (absorb the existing sibling rather than recreating from scratch)
   - Otherwise: copy dev/ to stg/ (excluding .ddev DB state)
   - Create `stg/.nwp.yml` with `environment: staging`
   - Create `stg/.ddev/config.yaml` with `name: <name>-stg`
   - Run `composer install` in stg/
7. **Clean up `-stg` siblings:** Remove `sites/<name>-stg/` after contents
   have been moved into `sites/<name>/stg/`. Archive first to
   `sites/<name>/backups/stg-archive/` if user requests.
8. **Bump schema_version to 2**

Requirements:
- `--dry-run` mode (show what would change, do nothing)
- Idempotent (safe to re-run on already-migrated sites)
- Per-site execution (`pl site migrate ba`) or batch (`pl site migrate --all`)

### Phase 5: Documentation and cleanup (1-2 hours)

- Update `CLAUDE.md` § Project Structure to reflect new layout
- Update `example.nwp.yml` with schema v2 documentation
- Update `docs/proposals/README.md` to note F23 completion
- Move F23 to milestones when done
- Clean up verify-test fixture sites if they use the old layout
- Update `lib/project-resolver.sh` inline comments

---

## 5. Affected NWP Components

### Modified files

| File | Change |
|------|--------|
| `lib/project-resolver.sh` | `resolve_project()`, `discover_sites()`, `get_site_config_value()` — depth-2 awareness |
| `lib/migrate-schema.sh` | Bump `CURRENT_SITE_SCHEMA` to 2 |
| `scripts/commands/live2stg.sh` | Read per-site `.nwp.yml` + server-resolver; target `dev/` subdir |
| `scripts/commands/stg2live.sh` | Same config migration as live2stg |
| `scripts/commands/backup.sh` | Verify `get_backup_dir()` resolves under new layout |
| `scripts/commands/site-init.sh` | Generate nested layout on new site creation |
| `scripts/commands/site-list.sh` | Use updated `discover_sites()` |
| `scripts/commands/site-show.sh` | Display site-level + env-level config |
| `scripts/commands/site-migrate.sh` | Invoke v2 migration |
| `example.nwp.yml` | Document schema v2 two-tier format |
| `CLAUDE.md` | Update § Project Structure |

### New files

| File | Purpose |
|------|---------|
| `lib/migrations/site/002-env-layout.sh` | v1 → v2 migration logic |

### Not modified

- Root `nwp.yml` — global settings unchanged
- `lib/server-resolver.sh` — already correct, used by new sync scripts
- `lib/ssh.sh` — unchanged
- `recipes/` — recipes don't care about env layout
- `servers/` — server configs unaffected
- Per-site git repos (avc, ss) — code stays in git

---

## 6. Migration Path for Existing Sites

| Site | Current state | Migration action |
|------|--------------|-----------------|
| `ba` | Flat, no git, `.nwp.yml`, live.enabled | Move into `ba/dev/`, create `ba/stg/`, split config |
| `avc` | Flat, own git repo, `.nwp.yml`, live.enabled | Move into `avc/dev/`, git repo stays in `dev/` |
| `avc-stg` | Sibling, no `.nwp.yml` | Move contents into `avc/stg/`, add `.nwp.yml`, remove sibling |
| `mt` | Flat, no git, `.nwp.yml`, not live | Move into `mt/dev/`, no stg/ (not live-enabled) |
| `cathnet` | Flat, no git, `.nwp.yml`, live.enabled | Move into `cathnet/dev/`, create `cathnet/stg/` |
| `cathnet-stg` | Sibling, no `.nwp.yml` | Move contents into `cathnet/stg/`, add `.nwp.yml`, remove sibling |
| `dir1` | Flat, no git, `.nwp.yml`, live.enabled | Move into `dir1/dev/`, create `dir1/stg/` |
| `dir1-stg` | Sibling, no `.nwp.yml` | Move contents into `dir1/stg/`, add `.nwp.yml`, remove sibling |
| `cccrdf` | Flat, minimal `.ddev`, live.enabled | Move into `cccrdf/dev/`, create `cccrdf/stg/` |
| `ss` | No `.nwp.yml` (Moodle) | **Skip** — needs `.nwp.yml` first (out of scope) |
| `mayo` | No `.nwp.yml` (Moodle) | **Skip** — needs `.nwp.yml` first (out of scope) |

---

## 7. Risk Assessment

### High risk

| Risk | Mitigation |
|------|-----------|
| Migration moves files incorrectly, breaking a site | `--dry-run` mode; full backup before migration; per-site execution (not batch-only) |
| DDEV rename leaves ghost containers | `ddev stop` before rename; `ddev list` check after migration |
| Git repos (avc) break when moved into `dev/` subdir | Git is path-relative; `.git/` moves with the directory. Remote URLs unchanged. Verify with `git status` post-migration. |

### Medium risk

| Risk | Mitigation |
|------|-----------|
| Scripts not updated miss the new layout | `pl verify` tests should catch path resolution failures |
| `-stg` siblings contain uncommitted work | Migration prompts before removal; archives to `backups/stg-archive/` first |

### Low risk

| Risk | Mitigation |
|------|-----------|
| DDEV name collision (`ba-dev` already exists) | Check `ddev list` before rename; fail gracefully |

---

## 8. Success Criteria

- [ ] `pl site list` shows all F17-migrated sites under new layout
- [ ] `pl site show ba` displays site-level config + lists environments (dev, stg)
- [ ] `pl live2stg ba` pulls live DB + files into `sites/ba/stg/` from per-site `.nwp.yml`
- [ ] `pl stg2live ba` pushes `sites/ba/stg/` to live server from per-site `.nwp.yml`
- [ ] `pl dev2stg ba` syncs code from `sites/ba/dev/` → `sites/ba/stg/`
- [ ] `pl backup ba` writes to `sites/ba/backups/`
- [ ] `pl site init newsite` creates nested layout (dev/ always; stg/ when live-enabled)
- [ ] `pl site migrate --all --dry-run` shows planned changes for all sites
- [ ] `pl site migrate ba` migrates a single site from v1 to v2
- [ ] All `-stg` siblings absorbed into `<name>/stg/` and removed
- [ ] Live-enabled sites have both `<name>-dev` and `<name>-stg` DDEV projects
- [ ] `ba-dev.ddev.site` and `ba-stg.ddev.site` both resolve and serve content
- [ ] `bash -n` passes on all modified scripts
- [ ] Existing `pl verify` tests pass (or are updated for new paths)

---

## 9. Open Questions

1. **DDEV naming: `ba-dev` or just `ba`?** Using `ba-dev` is consistent
   with `ba-stg` and unambiguous in `ddev list`. But `ba` is shorter for
   daily use. This proposal recommends `ba-dev` for consistency.

2. **Should `scripts/` live inside `dev/` (in git) or at site level (outside
   git)?** If the site has its own git repo, scripts committed with the code
   are better. If filesystem-only, site level is fine. Recommend: inside
   `dev/` for git-tracked sites, site level for filesystem-only sites.

3. **Should the migration create `backups/live/` and `backups/stg/`
   subdirectories, or leave `backups/` flat?** F18 will define backup
   naming. Recommend: create `backups/live/` by default, let F18 refine.

4. **What happens to root `nwp.yml` per-site entries after migration?**
   The fallback chain in `get_site_config_value()` reads root `nwp.yml` as
   a last resort. After all sites are on schema v2, the root `sites:` block
   could be removed. Recommend: leave it until all sites are migrated, then
   remove in a cleanup pass.

---

## 10. Out of Scope

- Server-hosted staging environments (see § 3.1 — rejected after research)
- Per-site git repo creation (per-site decision, not NWP core)
- Backup scheduling, offsite replication, borg/restic configuration (F18)
- Moodle site integration (ss, mayo need `.nwp.yml` first)
- Content loading, security audits, or other per-site operational work
- External SSD backup rotation strategy (F18)

---

## 11. Cross-references

- **[F17: Project Separation](F17-project-separation.md)** — prerequisite;
  established per-site `.nwp.yml` and `sites/<name>/` layout
- **[F18: Unified Backup Strategy](F18-unified-backup-strategy.md)** —
  depends on F23 for stable backup paths
- **[F21: Distributed Build/Deploy Pipeline](F21-distributed-build-deploy-pipeline.md)** —
  fixed sync scripts are a prerequisite for automated build/deploy
- **[ADR-0017: Distributed Build/Deploy Pipeline](../decisions/0017-distributed-build-deploy-pipeline.md)** —
  the distributed actor model that defines where staging and production live
- **[`lib/project-resolver.sh`](../../lib/project-resolver.sh)** — the
  critical file for site path resolution
- **[`example.nwp.yml`](../../example.nwp.yml)** — schema template
  including the `[PLANNED]` environment settings block that F23 partially
  implements

---

## 12. Decision Record

*This section is filled in when the proposal is accepted.*

**Decided option:** pending
**Decision date:** pending
**Decision maker:** Rob
