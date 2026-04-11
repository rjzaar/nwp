# F25: Mayo NWP Integration (repo, fixtures, content lifecycle, CI/CD)

**Status:** PROPOSED
**Created:** 2026-04-11
**Author:** Rob Zaar, Claude Opus 4.6
**Priority:** High (blocks production deploy of mayostudios.org; blocks sanitized-fixture testing)
**Depends On:** F21 (distributed build/deploy pipeline), ADR-0017, AVC site precedent
**Breaking Changes:** No (mayo is not yet in production under NWP)
**Related:** `docs/guides/mayo-avc-integration.md` (existing WIP integration doc), `sites/avc/` (canonical precedent)

---

## 1. Executive Summary

### 1.1 Problem Statement

mayostudios.org has been migrated from vanilla Open Social to the AVC Drupal distribution in-place at `/home/rob/nwp/sites/mayo/dev/`. It has a working `mayo_content` module (13 pages, 10 groups, menus, footer block), 35 sanitized users, and v2 `.nwp.yml` layout. However:

- **Nothing under `sites/mayo/` is tracked in any git repo.** All files are loose, unversioned artifacts. A single `rm -rf` loses weeks of work.
- **The `mayo_content` module uses `hook_install` only.** It creates content on fresh installs but cannot re-deploy updates to prod — prod would need a full reinstall, which would destroy real user data.
- **There is no sanitized-fixture pipeline.** CI cannot restore a realistic site, stg cannot be populated with non-PII data, and there is no "known good" snapshot to test deploys against.
- **There is no CI/CD pipeline.** There is no build, no signing, no publish, no review apps. The F21 pipeline that already works for AVC has no mayo equivalent.
- **`sites/mayo/stg/` is a stub** with only `.nwp.yml` — no DDEV project, no DB, no way to test changes before prod.

### 1.2 Proposed Solution

Mirror the AVC precedent end-to-end, modernise the content lifecycle to 2025 Drupal best practice, and stand up the F21 pipeline for mayo:

1. **`mayo/mayo` private git repo** (new, on `git.nwpcode.org`) — site template, mirroring the `nwp/avc-project` pattern; `mayo_content` module lives inside.
2. **`mayo/mayo-fixtures` private git repo** (new) — signed sanitized DB + files snapshots, published nightly from mayo1, consumed by CI + stg.
3. **Modernised `mayo_content`** — keep the module, add `mayo_content.deploy.php` with `hook_deploy_NAME()` so `drush deploy` re-applies structural content idempotently on every prod update. **Not Drupal Recipes** (Recipes in core 10.3+ are apply-once and cannot re-apply on `drush updb`).
4. **`drupal/config_ignore ^3.3` + `config_filter ^2.6`** for env-safe config.
5. **`sites/mayo/stg/` built out** to a full DDEV project with a fixture-restore workflow.
6. **`.gitlab-ci.yml` in `mayo/mayo`** with 11 stages ending at signed GitLab Package publish.
7. **mons handoff via `ops/mons-log` issues** — CI posts "Deploy ready"; mons polls, verifies minisign, deploys.

### 1.3 Design Rationale

- **Mirror AVC, don't reinvent.** AVC's repo layout, `.gitignore`, composer consumption pattern, and pipeline shape are already proven. Mayo diverges only where it must: no nested profile fork (mayo consumes `nwp/avc` purely via composer), no private user-pack module (just `mayo_content`).
- **Fixtures repo is a git repo + LFS, not GitLab Packages.** Packages are write-once mutable-metadata; a git repo gives diffable manifest history, atomic manifest+artifact commits, and `git revert` for rollback. Each artifact carries a detached minisign signature so verification works without cloning.
- **Keep the software signing key in CI as an interim.** Per ADR-0017 Phase 5, Solo 2C+ hardware signing is the target. Until then, signing runs on a dedicated met runner, concurrency 1, protected tags only, key shredded after use.
- **No CI runner ever touches mayo1.** The mons boundary is inviolable. CI ends at Package publish; mons pulls out-of-band.

---

## 2. Goals & Non-Goals

### 2.1 Goals

- Mayo code, content, and fixtures are all backed up to `git.nwpcode.org`.
- Fresh `ddev drush site:install avc` on dev produces a fully-populated mayo site in one step.
- `ddev drush deploy` on dev with existing DB is a verified no-op (idempotency guarantee).
- Every tagged release of `mayo/mayo` produces a signed tarball in GitLab Packages.
- mons can deploy that tarball to mayo1 with zero changes to real user data.
- Stg runs a realistic mayo site restored from sanitized fixtures.
- Review apps spin up per MR, scoped to Headscale network.
- Zero PII ever enters any tracked file.

### 2.2 Non-Goals

- Public (non-private) repos. All three repos stay private until a governance decision says otherwise.
- Moving `mayo_content` to Drupal Recipes. Revisit only if core adds "recipe apply on update".
- Solving the interim signing-key-in-CI problem. That is ADR-0017 Phase 5 work, tracked separately.
- Public review apps. Reviewers need Headscale access.
- Multi-branch `mayo/mayo`. Single protected `main`, tags for releases.

---

## 3. Current State (2026-04-11)

- `/home/rob/nwp/sites/mayo/dev/` — working AVC site, DDEV project `mayo-dev`, 13 pages, 10 groups, 35 sanitized users. Not in any git repo.
- `/home/rob/nwp/sites/mayo/dev/html/modules/custom/mayo_content/` — `mayo_content.install` (~700 lines) with idempotent `_mayo_content_create_*` helpers.
- `/home/rob/nwp/sites/mayo/dev/scripts/seed-sanitized-users.sh` — dev/stg-only user seeder (refuses to run against other DDEV projects).
- `/home/rob/nwp/sites/mayo/.nwp.yml` + `dev/.nwp.yml` — v2 schema, recipe: avc, live target: mayo1.
- `/home/rob/nwp/sites/mayo/stg/.nwp.yml` — stub.
- `/home/rob/nwp/lib/sanitizers/mayo.sh` — exists, needs file-system layer verification.
- `/home/rob/nwp/servers/mayo1/` — mayo1 infra tracked in NWP (scripts, systemd units, nginx configs).
- `git@git.nwpcode.org:mayo/mayo.git` — empty, bootstrap proven 2026-04-08 (per memory).
- `git@git.nwpcode.org:mayo/mayo-fixtures.git` — does not exist yet.
- `/home/rob/nwp/.gitlab-ci.yml` — NWP tooling pipeline (not per-site); mayo pipeline will be separate.
- `/home/rob/nwp/lib/minisign.sh` — signing primitives, already in place.
- `/home/rob/nwp/scripts/ci/create-preview.sh`, `cleanup-preview.sh` — review app helpers to reuse.
- `/home/rob/nwp/scripts/commands/build.sh`, `publish.sh` — `pl build` / `pl publish` implementations.
- `/home/rob/nwp/servers/mayo1/scripts/mons-deploy.sh` — consumer contract; dictates tarball naming and Package URL layout.

---

## 4. Phased Execution

Each phase is numbered. Each step within a phase is numbered. Phases 1–4 can run sequentially on the dev workstation; Phase 7 runs on mayo1; Phase 8 is end-to-end.

### Phase 1 — Bootstrap `mayo/mayo` private repo

Mirrors AVC's site-template pattern, using `git init` in place so DDEV is not disturbed.

1.1. Verify nothing under `sites/mayo/` is tracked by NWP: `cd ~/nwp && git ls-files sites/mayo/ | wc -l` → 0.
1.2. Copy `/home/rob/nwp/sites/avc/dev/.gitignore` to `/home/rob/nwp/sites/mayo/dev/.gitignore`. Remove line 19 (`/html/profiles/custom/avc/`) — mayo has no nested profile fork.
1.3. Move `/home/rob/nwp/sites/mayo/scripts/seed-sanitized-users.sh` and `setup-safety-email.sh` into `/home/rob/nwp/sites/mayo/dev/scripts/` so they ship inside the repo.
1.4. Write `/home/rob/nwp/sites/mayo/dev/README.md` (1 page: what, how to clone+install, links to NWP + ADR-0017).
1.5. `cd ~/nwp/sites/mayo/dev && git init -b main`.
1.6. `git add` with **explicit file list**, never `-A`:
```
.gitignore .gitattributes .editorconfig composer.json composer.lock
README.md scripts/
html/.gitignore html/autoload.php html/index.php html/.htaccess
html/robots.txt html/update.php
html/sites/default/default.settings.php
html/sites/default/default.services.yml
html/modules/custom/
.ddev/config.yaml
```
1.7. `git status` review. Expect: no `vendor/`, no `html/core/`, no `auth.json`, no `.env*`, no `private/`, no `.ddev/config.local.yaml`, no `.nwp.yml`, no `nwp.yml`.
1.8. `git commit -S -m "Initial mayo/mayo site template (bootstrap from NWP tree)"`.
1.9. Confirm `mayo/mayo` exists and is empty on GitLab (proven 2026-04-08 per memory). If not, create as **private** under `mayo` group.
1.10. `git remote add origin git@git.nwpcode.org:mayo/mayo.git && git push -u origin main`.
1.11. Protect `main` branch: require MR, block force-push.
1.12. `ddev start mayo-dev && ddev exec drush status` — sanity check DDEV still works (path-keyed, not git-keyed, so the new `.git/` is inert to DDEV).

### Phase 2 — Bootstrap `mayo/mayo-fixtures` private repo

2.1. GitLab UI: create `mayo/mayo-fixtures`, **private**, Git LFS enabled.
2.2. `mkdir ~/nwp/work/mayo-fixtures && cd ~/nwp/work/mayo-fixtures && git init -b main` (work outside `sites/` to avoid confusion).
2.3. Author `.gitattributes`:
```
*.sql.gz filter=lfs diff=lfs merge=lfs -text
*.tar.gz filter=lfs diff=lfs merge=lfs -text
```
Keep `*.minisig` as plain text so signatures are diffable.
2.4. Create skeleton tree: `manifest.yml`, `README.md`, `keys/pubkey.minisign`, `db/`, `files-public/`, `files-private-sanitized/`, `archive/`.
2.5. Seed from `/home/rob/nwp/sites/mayo/backups/mayo-avc-fresh.sql`: gzip → `db/mayo-db-bootstrap-<timestamp>.sql.gz`, sign with `minisign -S -s ~/.minisign/nwp-deploy.key`, update `manifest.yml`, create `db/latest` symlink.
2.6. Author `manifest.yml` per the schema in F21 release metadata (`schema_version`, `site`, `generated_at`, `sanitizer_version`, `db`, `files_public`, `files_private_sanitized`, `signing_key_id`).
2.7. `git add . && git commit -S -m "Bootstrap mayo-fixtures with fresh-install DB seed"`.
2.8. `git remote add origin git@git.nwpcode.org:mayo/mayo-fixtures.git && git push -u origin main`.
2.9. Protect `main` branch.
2.10. On mayo1 (later, when Phase 7 runs): `ssh-keygen -t ed25519 -f ~/.ssh/mayo-fixtures-write -C "mayo1 fixtures publisher"`; register on `mayo/mayo-fixtures` as **write-only** deploy key.
2.11. On met: `ssh-keygen -t ed25519 -f ~/.ssh/mayo-fixtures-read -C "met fixtures consumer"`; register as **read-only** deploy key.
2.12. Copy `keys/pubkey.minisign` from the repo to `~/.config/mayo-fixtures.pub` on met (this is the real trust anchor; the in-repo copy is for bootstrap only).

### Phase 3 — Modernise `mayo_content` (add deploy hooks)

3.1. Edit `/home/rob/nwp/sites/mayo/dev/composer.json` to require: `"drupal/config_ignore": "^3.3"`, `"drupal/config_filter": "^2.6"`, `"drupal/update_helper": "^4"`. Run `ddev composer update`.
3.2. Create `/home/rob/nwp/sites/mayo/dev/html/modules/custom/mayo_content/mayo_content.deploy.php` with one function:
```php
function mayo_content_deploy_0001_ensure_structural_content(&$sandbox): void {
  _mayo_content_create_pages();
  _mayo_content_create_groups();
  _mayo_content_create_menu();
  _mayo_content_create_footer_block();
}
```
3.3. **(Optional but recommended)** Extract the `_mayo_content_create_*` helpers into `src/ContentBuilder.php` service so `hook_install` and `hook_deploy_N` share a single code path. Skip if scope-creep; revisit in a follow-up.
3.4. Edit `mayo_content.info.yml` to add `drupal:update_helper` and `drupal:config_ignore` dependencies.
3.5. `ddev drush deploy` on dev. **Expected**: zero DB changes. Every creator uses `$storage->loadByProperties(['uuid' => $uuid])` before creating (verified at `mayo_content.install` lines 42, 103, 151, 172), so re-runs are idempotent.
3.6. `ddev drush config:export`. Review diff. Any env-specific settings that leak in (mail, domain, keys) get added to the Config Ignore list in Phase 4. Re-export, commit.

### Phase 4 — Config management + `deployment_identifier`

4.1. Create `/home/rob/nwp/sites/mayo/dev/config/sync/config_ignore.settings.yml` (at project level, not under `html/`, so it survives blue/green slot swaps). Ignored entries:
```
- system.site:mail
- system.site:name
- system.site:slogan
- system.mail
- symfony_mailer.settings
- symfony_mailer.mailer_transport.*
- reverse_proxy.*
- key.key.*
- update.settings
- environment_indicator.indicator
- stage_file_proxy.settings
- social_swiftmail.settings
- advagg.settings
- search_api.server.*
```
4.2. Edit `/home/rob/nwp/sites/mayo/dev/html/sites/default/settings.php`:
  - Uncomment `deployment_identifier` block and change to: `$settings['deployment_identifier'] = getenv('NWP_DEPLOY_ID') ?: \Drupal::VERSION;`
  - Add: `$settings['config_exclude_modules'] = ['devel', 'devel_generate', 'webprofiler', 'environment_indicator', 'stage_file_proxy', 'seckit'];`
  - Add: `$settings['config_sync_directory'] = '../../config/sync';`
  - Conditionally include `settings.deploy.php` if present (slot-local, for prod only).
4.3. Create `/home/rob/nwp/servers/mayo1/scripts/stamp-deployment-identifier.sh`: writes `<?php $settings['deployment_identifier'] = '<tarball-version>';` into the active slot's `settings.deploy.php`. Invoked by `bluegreen-swap.sh` **before** the symlink flip.
4.4. Patch `/home/rob/nwp/servers/mayo1/scripts/bluegreen-swap.sh` to call `stamp-deployment-identifier.sh` pre-flip and `drush deploy` post-flip.

### Phase 5 — Build out `sites/mayo/stg/`

5.1. Create `/home/rob/nwp/sites/mayo/stg/.ddev/config.yaml` — `name: mayo-stg`, `type: drupal10`, same PHP/DB/composer versions as dev, `ENV_TYPE=staging`.
5.2. Copy `composer.json` + `auth.json` from `sites/mayo/dev/` to `sites/mayo/stg/`.
5.3. `cd sites/mayo/stg && ddev start && ddev composer install` — provisions AVC codebase.
5.4. `ddev drush site:install avc --existing-config` — first install using the sync directory from Phase 4.
5.5. Create `/home/rob/nwp/sites/mayo/scripts/restore-sanitized-fixture.sh`: takes a path or GitLab Package URL, runs `ddev import-db`, `ddev drush deploy`, `ddev drush cr`. Refuses to run unless DDEV project is `mayo-dev` or `mayo-stg`.
5.6. Run `restore-sanitized-fixture.sh` against the fixtures repo's `db/latest` (cloned via the met read deploy key from Phase 2).
5.7. Verify: stg shows 13 pages, 10 groups, 35 users, menu links, footer block.
5.8. Add `sites/mayo/stg/.nwp.yml` entry: `live.snapshot.source: mayo1` so future `pl live:snapshot stg` knows which dump to fetch.

### Phase 6 — Mayo CI/CD pipeline

6.1. Create `nwp/ci-templates` GitLab project (or alternatively `.gitlab/ci/drupal-site.yml` inside the NWP repo) with common job definitions for drupal-site pipelines.
6.2. Create `/home/rob/nwp/sites/mayo/dev/.gitlab-ci.yml` (becomes root of `mayo/mayo`). Uses `include:` from the templates project.
6.3. Pipeline stages (11):

| # | Stage | Runner tag | Script | Secrets |
|---|---|---|---|---|
| 1 | `verify:signature` | `met` | `git verify-commit HEAD` against runner-baked keyring | commit-signing pubkey ring |
| 2 | `lint` | `mini` | `composer validate --strict`, `php -l`, `phpcs --standard=Drupal` | none |
| 3 | `test:fixture` | `met` | `scripts/ci/fetch-mayo-fixture.sh` → verify → `scripts/ci/build.sh` → `ddev import-db` → `drush deploy` | `MAYO_FIXTURES_DEPLOY_TOKEN`, `NWP_DEPLOY_PUBKEY` |
| 4 | `test:phpunit` | `met` | `ddev drush test:run mayo_content` + PHPUnit kernel tests | none |
| 5 | `security:scan` | `nwp` | Reuse root pipeline's composer audit + secret detection block | none |
| 6 | `build` | `met` (protected) | `pl build mayo --tag $CI_COMMIT_SHORT_SHA` (unsigned) | none — rules gate: `$CI_COMMIT_TAG =~ /^v/` |
| 7 | `sign` | `met` (protected, dedicated runner, concurrency 1) | `minisign_sign out/mayo-*.tar.gz`, shred key after | `MINISIGN_SECRET_KEY` (file), `MINISIGN_PASSWORD` |
| 8 | `publish:package` | `met` (protected) | `pl publish mayo --file out/mayo-*.tar.gz` → GitLab Packages at `mayo%2Fmayo/packages/generic/mayo-deploy/<version>/`; post `Deploy ready: mayo <version>` issue to `ops/mons-log` | `GITLAB_API_TOKEN_MAYO_PUBLISH`, `OPS_MONS_LOG_WRITE_TOKEN` |
| 9 | `deploy:review` | `met` | `scripts/ci/create-preview.sh mr-$CI_MERGE_REQUEST_IID-mayo`; dotenv `PREVIEW_URL` via `environment.url` | `MAYO_FIXTURES_DEPLOY_TOKEN` |
| 10 | `e2e` | `met` | Behat / Drupal Test Traits against `$PREVIEW_URL` | none |
| 11 | `cleanup:review` | `met` | `scripts/ci/cleanup-preview.sh mr-$CI_MERGE_REQUEST_IID-mayo`; `auto_stop_in: 1 week` | none |

6.4. Stages 1–5 and 9–11 run on MRs and branch pushes. Stages 6–8 are gated to protected tags (`$CI_COMMIT_TAG =~ /^v/`) so feature branches never reach the signing key.
6.5. Create `/home/rob/nwp/scripts/ci/fetch-mayo-fixture.sh` (new): curl latest fixture from `mayo-fixtures` Package registry + signature, verify with `minisign_verify`, SQL sanity check (`zcat | head -c 1024 | grep -q 'CREATE TABLE'`), refuse on failure.
6.6. Register a dedicated met runner `met-sign` with `tags: [met, sign]`, concurrency 1, protected-only. Install `minisign` binary on it.
6.7. Configure required GitLab CI/CD variables (project-scoped on `mayo/mayo`, not group-wide):

| Variable | Type | Scope | Protected |
|---|---|---|---|
| `MAYO_FIXTURES_DEPLOY_TOKEN` | masked var | all | yes |
| `NWP_DEPLOY_PUBKEY` | file | all | no |
| `MINISIGN_SECRET_KEY` | file (masked) | protected tags only | **yes** |
| `MINISIGN_PASSWORD` | masked var | protected tags only | **yes** |
| `GITLAB_API_TOKEN_MAYO_PUBLISH` | masked var | protected tags only | **yes** |
| `OPS_MONS_LOG_WRITE_TOKEN` | masked var | protected tags only | **yes** |

**Explicitly NOT in the list**: any SSH key or hostname for mayo1. CI cannot reach prod.

6.8. Commit `.gitlab-ci.yml` to `mayo/mayo` main. Trigger first pipeline via a no-op commit. Expect stages 1–5 to pass.

### Phase 7 — Sanitizer + fixture publish loop (on mayo1)

Runs once mayo1 is reachable. Security-critical — `lib/sanitizers/mayo.sh` is a CLAUDE.md-protected path, so changes require human review before merge.

7.1. SSH to mayo1. Verify `/home/rob/nwp/lib/sanitizers/mayo.sh` covers: DB (all real user data stripped), public files (WWCC scans, real photos replaced with placeholders), private files (documents, incident reports excluded entirely).
7.2. Patch gaps found in 7.1 — **each patch is a separate MR, human-reviewed, no AI merge**.
7.3. Create `/home/rob/nwp/servers/mayo1/scripts/fixtures-publish.sh`: runs sanitizer, produces 3 tarballs (db/files-public/files-private-sanitized), signs each with minisign, clones `mayo/mayo-fixtures` via write deploy key, commits atomically (manifest + artifacts + `latest` symlinks), pushes.
7.4. Create `/home/rob/nwp/servers/mayo1/systemd/mayo-fixtures-publish.service` and `.timer`. Timer runs nightly 02:00 Australia/Melbourne.
7.5. Manually trigger first run: `sudo systemctl start mayo-fixtures-publish.service`. Verify output in `mayo/mayo-fixtures`.
7.6. Enable timer: `sudo systemctl enable --now mayo-fixtures-publish.timer`.
7.7. Back on dev/met: verify `git pull` in `~/nwp/work/mayo-fixtures` pulls the new snapshot; verify `minisign -V` passes.

### Phase 8 — End-to-end deploy test

8.1. Tag `mayo/mayo` as `v0.1.0` on `main`: `git tag -a v0.1.0 -m "First mayo production release"`.
8.2. `git push origin v0.1.0`.
8.3. Watch pipeline. Expect stages 1–8 pass (the tag matches the rules gate for build/sign/publish).
8.4. Verify signed tarball at `https://git.nwpcode.org/mayo/mayo/-/packages` — expect `mayo-deploy/v0.1.0/mayo-v0.1.0.tar.gz` and `.minisig`.
8.5. Verify `ops/mons-log` has issue `Deploy ready: mayo v0.1.0` with paste-ready `mons-deploy.sh mayo v0.1.0`.
8.6. Power up mons, bring up `wg-mons`, run `mons-deploy.sh mayo v0.1.0`.
8.7. Verify on mayo1: site loads, 13 pages present, 10 groups present. **Critical check**: `SELECT COUNT(*) FROM users_field_data` matches pre-deploy (zero changes to real users).
8.8. `mons-say "deploy mayo v0.1.0 complete"`.
8.9. Close `Deploy ready` issue in `ops/mons-log`.

---

## 5. Files To Create / Modify / Reuse

### 5.1 To create

- `sites/mayo/dev/.gitignore` (copy from AVC, strip line 19)
- `sites/mayo/dev/README.md`
- `sites/mayo/dev/html/modules/custom/mayo_content/mayo_content.deploy.php`
- `sites/mayo/dev/html/modules/custom/mayo_content/src/ContentBuilder.php` (optional)
- `sites/mayo/dev/config/sync/config_ignore.settings.yml`
- `sites/mayo/dev/.gitlab-ci.yml` (becomes root of `mayo/mayo`)
- `sites/mayo/stg/.ddev/config.yaml`
- `sites/mayo/stg/composer.json` (copy from dev)
- `sites/mayo/scripts/restore-sanitized-fixture.sh`
- `servers/mayo1/scripts/stamp-deployment-identifier.sh`
- `servers/mayo1/scripts/fixtures-publish.sh`
- `servers/mayo1/systemd/mayo-fixtures-publish.service`
- `servers/mayo1/systemd/mayo-fixtures-publish.timer`
- `scripts/ci/fetch-mayo-fixture.sh`
- `~/nwp/work/mayo-fixtures/` (becomes `mayo/mayo-fixtures` repo)
- `tests/src/Kernel/ContentBuilderTest.php` (PHPUnit kernel test for idempotency)

### 5.2 To modify

- `sites/mayo/dev/composer.json` — add config_ignore, config_filter, update_helper
- `sites/mayo/dev/html/modules/custom/mayo_content/mayo_content.info.yml` — add deps
- `sites/mayo/dev/html/sites/default/settings.php` — deployment_identifier, config_exclude_modules, config_sync_directory, slot-local include
- `servers/mayo1/scripts/bluegreen-swap.sh` — call stamp-deployment-identifier pre-flip + post-flip `drush deploy`
- `docs/guides/mayo-avc-integration.md` — update "Layer 1" paragraph with deploy-hook wording

### 5.3 Existing files reused

- `sites/avc/dev/.gitignore` — template for mayo's `.gitignore`
- `sites/mayo/dev/html/modules/custom/mayo_content/mayo_content.install` — kept unchanged for fresh-install path
- `sites/mayo/dev/scripts/seed-sanitized-users.sh` — fresh-install fallback (optional once stg has real sanitized dumps)
- `lib/minisign.sh` — `minisign_sign`, `minisign_verify`
- `scripts/commands/build.sh` — `pl build` (lines 167–274 drive the tarball format)
- `scripts/commands/publish.sh` — `pl publish` (lines 159–201 drive the Package URL layout)
- `scripts/ci/create-preview.sh` — review app creation (lines 46–211)
- `scripts/ci/cleanup-preview.sh` — review app cleanup (lines 94–103)
- `servers/mayo1/scripts/mons-deploy.sh` — consumer contract (lines 100–107 + 210–240)

---

## 6. Verification

- `cd ~/nwp/sites/mayo/dev && git log --oneline` shows signed commits. `git remote -v` points at `git.nwpcode.org:mayo/mayo.git`.
- `ddev drush status` on dev still reports `Install profile: avc`, 13 pages, 35 users.
- `ddev drush deploy` on dev is a no-op (zero DB changes — proves idempotency).
- `ddev drush config:export` produces clean diff (nothing env-specific leaks).
- `cd ~/nwp/work/mayo-fixtures && git log` shows signed bootstrap commit. `git lfs ls-files` shows the seed dump.
- On met: `minisign -V -p ~/.config/mayo-fixtures.pub -m db/latest` returns "Signature and comment signature verified".
- `sites/mayo/stg/` running DDEV project `mayo-stg` with imported sanitized fixture; stg shows 13 pages, 10 groups.
- Pipeline green on `mayo/mayo v0.1.0` tag. Signed tarball in GitLab Packages. `ops/mons-log` issue created.
- mons deploy succeeds on mayo1. Prod site loads. `SELECT COUNT(*) FROM users_field_data` on prod unchanged.
- `mons-say` confirmation reaches dev session.

---

## 7. Risks & Mitigations

- **Interim software signing key in CI.** Met runner compromise = key exfiltration. Mitigate: dedicated runner, concurrency 1, protected-tags-only scope, rotating register tokens, shred after use. Permanent fix is Solo 2C+ (ADR-0017 Phase 5, tracked separately).
- **Review apps reachable only via Headscale.** External reviewers excluded. Accept: current reviewers are Rob + invited members who already have Headscale access.
- **Sanitizer file-system layer is security-critical.** Any change to `lib/sanitizers/mayo.sh` requires human review per CLAUDE.md; AI may propose, human must merge.
- **Shared `settings.local.php` across blue/green slots.** Fixed by moving `deployment_identifier` into slot-local `settings.deploy.php` conditionally included from `settings.php`.
- **Deploy hook re-entrancy.** Every `hook_deploy_N` must remain UUID-idempotent. Enforced via `tests/src/Kernel/ContentBuilderTest.php` (PHPUnit kernel test that runs the hook twice and asserts zero diff on the second run).
- **Fixture staleness.** If nightly timer fails, CI falls back to prior snapshot with a warning, never fails the build on stale fixtures, never accepts unsigned.
- **Bootstrap commit accidentally including secrets.** Mitigated by explicit `git add <file list>` in step 1.6, AVC-derived `.gitignore`, pre-commit `git status` review in step 1.7.
- **Drupal Recipes temptation.** Recipes look nice for content-as-code but are apply-once only. Re-deploy would break. Documented the Why in this proposal; revisit when core ships "recipe apply on update".

---

## 8. Out of Scope (follow-ups)

- Promoting `mayo/mayo` to public. Governance decision, not technical.
- Hardware signing (Solo 2C+). Tracked in ADR-0017 Phase 5.
- Multi-branch strategy, release channels. Single `main` + tags is enough for now.
- Per-reviewer access to review apps. Headscale-only is acceptable.
- Public PR from outside contributors. Governance decision.
- Converting `mayo_content` helpers into a service class. Optional, step 3.3 flags it.
- Fixture retention/pruning automation. Start with "keep everything", revisit when LFS storage becomes a concern.

---

## 9. Acceptance

This proposal is done when:

1. Phases 1–8 all complete and their verification steps pass.
2. `mayo/mayo v0.1.0` is deployed to mayo1 via mons with zero changes to real user data.
3. Nightly fixture publish has run successfully at least once.
4. A subsequent MR to `mayo/mayo` successfully spins up a review app and runs e2e tests against it.
