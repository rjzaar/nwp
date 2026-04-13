# F29: Mayo Comprehensive Integration — docs, saintschool, two-tier sanitization, example site

**Status:** PROPOSED
**Created:** 2026-04-13
**Author:** Rob Zaar, Claude Opus 4.6
**Priority:** High (consolidates and sequences all pending mayo work into a single actionable plan)
**Depends On:** F21 (distributed pipeline — phases 1-3a done), F23 (site layout — done), F25 (mayo NWP integration — proposed, subsumed here), F26 (OIDC — proposed, adapted here for mayo↔saintschool)
**Supersedes:** F25 is fully absorbed into this proposal (phases 1-8 of F25 become phases 2-5 here). F25 should be marked SUPERSEDED BY F29.
**Breaking Changes:** No (mayo is not yet in production under NWP; saintschool does not exist yet)

---

## 1. Executive Summary

### 1.1 Problem Statement

Mayo has working dev infrastructure (DDEV, AVC profile, mayo_content module, 35 synthetic users, v2 .nwp.yml) but everything else is scattered, unversioned, or missing:

1. **Governance and policy documents live in `~/MAYO/`**, a loose directory outside the project tree. Nine documents (incorporation guide, technical plan, policy pack, consultation summary, research spreadsheet) are not tracked in any repo. They are the canonical source for every policy page the site displays, yet one `rm -rf ~/MAYO` loses them.

2. **Nothing under `sites/mayo/` is in git.** All code, config, and content module files are unversioned. F25 proposed fixing this but has not been actioned.

3. **saintschool.mayostudios.org exists only as a one-line entry** in `servers/mayo1/.nwp-server.yml` (status: planned). There is no site directory, no repo, no DDEV project, no content, and no OIDC integration with mayo's user base.

4. **The sanitizer produces one tier of output** (internal dev/stg fixtures). There is no mechanism to produce a second tier — a public, zero-PII-risk example site that can ship with NWP as a demonstration of what AVC looks like in production.

5. **Policy content lives in three disconnected places**: `.docx` files in `~/MAYO/`, hardcoded strings in `mayo_content.install`, and (eventually) rendered pages on mayostudios.org. There is no lifecycle connecting them, so updating a policy means manually editing code, which is error-prone and unauditable.

### 1.2 Proposed Solution

A single end-to-end plan in 10 phases that:

1. **Relocates all `~/MAYO/` documents** into the mayo/mayo git repo at `sites/mayo/dev/docs/`, tracked and versioned.
2. **Bootstraps the mayo/mayo repo** (absorbing F25 phases 1-2) with docs, code, and content module.
3. **Establishes a policy content lifecycle** from source `.md` files through the mayo_content module to the live site, with a diff-auditable update path.
4. **Modernises the content module** with deploy hooks (absorbing F25 phase 3-4).
5. **Builds out stg and the signed pipeline** (absorbing F25 phases 5-8).
6. **Bootstraps saintschool.mayostudios.org** as a second AVC site on mayo1, sharing mayo's user base via OIDC.
7. **Implements two-tier sanitization**: Tier 1 (internal, sanitized prod data) and Tier 2 (public, synthetic from scratch — zero real data ever present).
8. **Packages Tier 2 as an NWP example site** that ships with tagged NWP releases.
9. **Wires CI/CD for both sites** with shared fixture infrastructure.
10. **End-to-end cross-site integration test** (mayo ↔ saintschool OIDC, both sanitization tiers, mons deploy).

### 1.3 Design Rationale

- **One proposal, not five.** F25, the saintschool bootstrap, the doc relocation, the two-tier sanitization, and the example-site packaging are deeply interdependent. Executing them as separate proposals creates sequencing confusion and orphaned work. This proposal establishes the canonical execution order.
- **Tier 2 sanitization is a clean-room build, not a second sanitizer pass.** The safest way to produce a public example site is to never involve real data at all. A fresh `drush site:install avc` + mayo_content install hooks + seed-sanitized-users.sh produces a fully populated site with zero PII risk. This is both simpler and more secure than running a second, more aggressive sanitizer pass over production data.
- **Policy lifecycle flows from docs/ to code to site.** Source markdown files in the repo are the single source of truth. The content module reads from them (or is updated to match them). The live site receives updates via `drush deploy`. Auditing a policy change means reviewing a git diff of the markdown file and the corresponding module update.
- **saintschool mirrors the mayo pattern** — same repo structure, same pipeline, same deploy path via mons. The OIDC integration follows F26's architecture with mayo as the identity provider.

---

## 2. Current State (2026-04-13)

### 2.1 What Exists

| Asset | Location | Status |
|---|---|---|
| Mayo dev environment | `sites/mayo/dev/` (DDEV project `mayo-dev`) | Working, AVC profile, 13 pages, 10 groups, 35 users |
| mayo_content module | `sites/mayo/dev/html/modules/custom/mayo_content/` | 700+ lines, idempotent `hook_install`, UUIDs for all entities |
| Site configs | `sites/mayo/.nwp.yml`, `dev/.nwp.yml`, `stg/.nwp.yml` | v2 schema, stg is a stub |
| Sanitizer | `lib/sanitizers/mayo.sh` | 6-step pipeline, PII sweep, resume capability |
| OIDC email helper | `lib/sanitizers/oidc-email.sh` | Deterministic cross-site email hashing |
| User seeder | `sites/mayo/scripts/seed-sanitized-users.sh` | 35 synthetic users, role distribution |
| Safety email setup | `sites/mayo/scripts/setup-safety-email.sh` | Postfix alias for safety@mayostudios.org |
| Server config | `servers/mayo1/.nwp-server.yml` | mayo (active) + saintschool (planned) |
| Server scripts | `servers/mayo1/scripts/` | bluegreen-setup.sh, bluegreen-swap.sh, mons-deploy.sh |
| WireGuard configs | `servers/mayo1/wireguard/` | wg-mons.conf for both sides |
| Backups | `sites/mayo/backups/` | mayo-avc-fresh.sql, mayo-live, pre-avc-migration |
| Pre-AVC archive | `sites/mayo/dev-pre-avc/` | Original Open Social codebase |
| Integration guide | `docs/guides/mayo-avc-integration.md` | WIP, 15 sections |
| Bootstrap guide | `docs/guides/mons-mayo-bootstrap.md` | Interim procedure |
| Operations guide | `docs/guides/mons-operations.md` | mayo1 references |
| GitLab repo | `git@git.nwpcode.org:mayo/mayo.git` | Empty, bootstrap proven 2026-04-08 |

### 2.2 What Exists in ~/MAYO/ (Untracked)

| File | Format | Content |
|---|---|---|
| `mayo_incorporation_and_governance.md` | Markdown | Full Victorian incorporation guide, 7 parts, committee roles, child safety, ongoing obligations |
| `mayo_technical_implementation_plan.md` | Markdown | Platform migration plan, infrastructure, compliance, 5 phases |
| `mayo_consultation_summary.docx` | Word | March 2026 consultation findings |
| `mayo_incorporation_guide.docx` | Word | Formatted version of the .md guide |
| `mayo_policy_pack.docx` | Word | 9 child safety and governance policies |
| `mayo_policy_review.docx` | Word | Review of policy pack against standards |
| `mayo_reference_document.docx` | Word | Reference compilation |
| `vic_association_guide.docx` | Word | Victorian association law guide |
| `vic_association_research.xlsx` | Excel | Research data for incorporation |

### 2.3 What Does NOT Exist

- `mayo/mayo` repo with any commits
- `mayo/mayo-fixtures` repo
- `sites/mayo/dev/docs/` (no docs directory in the site)
- `sites/mayo/stg/.ddev/` (stg is a stub)
- `sites/saintschool/` (site directory does not exist)
- `mayo/saintschool` GitLab repo
- Any Tier 2 (public/synthetic) fixture pipeline
- Any NWP example-site packaging mechanism
- Any OIDC configuration on mayo or saintschool
- Deploy hooks in mayo_content (`mayo_content.deploy.php` does not exist)
- `.gitlab-ci.yml` for mayo pipeline

---

## 3. Document Relocation Plan

### 3.1 Target Structure

All `~/MAYO/` documents move into the mayo/mayo git repo at `sites/mayo/dev/docs/`:

```
sites/mayo/dev/docs/
├── governance/
│   ├── incorporation-guide.md          ← ~/MAYO/mayo_incorporation_and_governance.md
│   ├── technical-implementation.md     ← ~/MAYO/mayo_technical_implementation_plan.md
│   └── reference/
│       ├── consultation-summary.docx   ← ~/MAYO/mayo_consultation_summary.docx
│       ├── incorporation-guide.docx    ← ~/MAYO/mayo_incorporation_guide.docx
│       ├── policy-review.docx          ← ~/MAYO/mayo_policy_review.docx
│       ├── reference-document.docx     ← ~/MAYO/mayo_reference_document.docx
│       ├── vic-association-guide.docx  ← ~/MAYO/vic_association_guide.docx
│       └── vic-association-research.xlsx ← ~/MAYO/vic_association_research.xlsx
├── policies/
│   ├── README.md                       ← Index of all 9 policies with status
│   ├── 01-child-safety-wellbeing.md    ← Extracted from mayo_policy_pack.docx
│   ├── 02-code-of-conduct.md           ← Extracted from mayo_policy_pack.docx
│   ├── 03-risk-management.md           ← Extracted from mayo_policy_pack.docx
│   ├── 04-privacy-policy.md            ← Extracted from mayo_policy_pack.docx
│   ├── 05-chat-code-of-conduct.md      ← Extracted from mayo_policy_pack.docx
│   ├── 06-conflict-resolution.md       ← Extracted from mayo_policy_pack.docx
│   ├── 07-whistleblower-protection.md  ← Extracted from mayo_policy_pack.docx
│   ├── 08-photography-consent.md       ← Extracted from mayo_policy_pack.docx
│   ├── 09-emergency-procedures.md      ← Extracted from mayo_policy_pack.docx
│   └── source/
│       └── mayo_policy_pack.docx       ← Original .docx preserved for audit trail
├── proposals/
│   └── (mayo-specific proposals go here, aggregated by pl proposals)
└── README.md                           ← Index linking to governance/, policies/, proposals/
```

### 3.2 Rationale

- **Markdown policies are the source of truth.** The mayo_content module reads policy text from these files (or is kept in sync with them). The `.docx` originals are preserved in `source/` and `reference/` for the audit trail but are not the editing surface.
- **Per CLAUDE.md convention**, per-site proposals live inside the site's profile repo. Mayo has no profile fork, so `sites/mayo/dev/docs/proposals/` serves this role.
- **The `.docx` files are committed via Git LFS** (`.gitattributes` entry: `*.docx filter=lfs diff=lfs merge=lfs -text` and `*.xlsx filter=lfs diff=lfs merge=lfs -text`).
- **After relocation, `~/MAYO/` is deleted.** A symlink `~/MAYO → ~/nwp/sites/mayo/dev/docs/` is created for convenience during the transition period.

---

## 4. Two-Tier Sanitization Architecture

### 4.1 Overview

| Property | Tier 1 — Internal Fixture | Tier 2 — Public Example |
|---|---|---|
| **Purpose** | Dev/stg/CI testing with realistic data shape | NWP distribution, demo, public showcase |
| **Data source** | Production database on mayo1 | Fresh install — zero prod data involved |
| **Process** | `lib/sanitizers/mayo.sh` on mayo1 → export → sign → publish | `drush site:install avc` → mayo_content hooks → seed users → export |
| **Where it runs** | On mayo1 (raw data never leaves prod) | On met or dev workstation (no prod access needed) |
| **Schedule** | Nightly timer on mayo1 | On-demand or on tagged NWP release |
| **PII risk** | Low (faker names/emails, redacted profiles, hashed passwords, PII sweep verification) | **Zero** (no real data ever present) |
| **Content** | Real content structure preserved (node count, group count matches prod) | 13 pages, 10 groups, menus, footer from mayo_content module |
| **Users** | Real user structure with faker PII (count matches prod) | 35 synthetic users from seed script (example.com emails) |
| **OIDC linkage** | Preserved via deterministic email hashing (oidc-email.sh) | Not applicable (no real users to link) |
| **Distribution** | Private GitLab Package Registry (`mayo/mayo-fixtures`) | Public GitLab Package or NWP release artifact |
| **Signing** | minisign (mandatory) | minisign (mandatory) |
| **Human review gate** | First N snapshots require human review | First build requires human review |
| **Consumers** | CI pipeline (stages 3-4), stg restore, dev restore | NWP new-user bootstrap, `pl init --example mayo`, public download |

### 4.2 Why Tier 2 Is Not a Second Sanitizer Pass

The obvious design would be to run `mayo.sh` with a `--public` flag that applies more aggressive redaction. This was rejected for three reasons:

1. **Any sanitizer pass over real data carries residual risk.** PII can hide in unexpected places — serialized PHP in `key_value`, base64-encoded blobs in contrib module tables, encoded filenames in `file_managed`. The regex PII sweep in Step 6 catches known patterns but cannot guarantee zero false negatives. A clean-room build eliminates this entire risk class.

2. **The two tiers serve fundamentally different purposes.** Tier 1 needs to be a realistic mirror of production (matching node count, user count, content volume, performance characteristics). Tier 2 needs to be a *demonstration* — small, self-contained, and illustrative. These are different requirements that happen to share a database schema, not two points on a sanitization spectrum.

3. **Tier 2 already exists in pieces.** `mayo_content.install` creates all structural content. `seed-sanitized-users.sh` creates all users. A fresh `drush site:install avc` produces the database schema. The only missing piece is a script that runs these in sequence and exports the result.

### 4.3 Tier 2 Content Considerations

The mayo_content module creates MAYO-specific content (child safety policies, youth organisation groups, Australian legal references). For a public NWP example site, this is a *feature*, not a bug:

- **Policies demonstrate real-world content management.** A new NWP user sees how policy pages are created via deploy hooks, how public vs. members-only access works, how footer blocks display emergency contacts.
- **Groups demonstrate AVC's community features.** Committee, Facilitators, Youth Members, Events — these show how AVC's group system works in practice.
- **The content is already public.** The child safety policy, code of conduct, and privacy policy are designed to be displayed on a public website. There is nothing private about them.

One modification for Tier 2: the "About Mayo Studios" and "Our Mission" pages get a small banner at the top: *"This is a demonstration site created by NWP. Replace this content with your own."* This is added by a `--example-mode` flag on the build script, not by modifying the source content.

### 4.4 Tier 2 File-System Content

Tier 1 includes sanitized public files (user-uploaded images with WWCC scans and real photos replaced by placeholders). Tier 2 includes **no uploaded files at all** — the fresh install has an empty `files/` directory. This is correct: a demo site doesn't need user uploads, and the empty state demonstrates the AVC file management system.

If a richer demo is desired in future (e.g., sample images for groups, placeholder hero banners), these would be committed as fixtures in the mayo_content module, not extracted from production.

---

## 5. Phased Execution

### Phase 1 — Document Relocation and Policy Extraction

**Goal:** All `~/MAYO/` documents tracked in `sites/mayo/dev/docs/`, policy pack extracted to individual markdown files, audit trail preserved.

**Autonomy level:** Fully autonomous except step 1.6 (policy extraction requires reading .docx content which Claude cannot do directly — Rob must extract or confirm the AI-generated markdown matches the .docx).

1.1. Create directory structure:
```bash
mkdir -p ~/nwp/sites/mayo/dev/docs/{governance/reference,policies/source,proposals}
```

1.2. Copy markdown documents:
```bash
cp ~/MAYO/mayo_incorporation_and_governance.md \
   ~/nwp/sites/mayo/dev/docs/governance/incorporation-guide.md
cp ~/MAYO/mayo_technical_implementation_plan.md \
   ~/nwp/sites/mayo/dev/docs/governance/technical-implementation.md
```

1.3. Copy .docx and .xlsx reference files:
```bash
cp ~/MAYO/mayo_consultation_summary.docx \
   ~/MAYO/mayo_incorporation_guide.docx \
   ~/MAYO/mayo_policy_review.docx \
   ~/MAYO/mayo_reference_document.docx \
   ~/MAYO/vic_association_guide.docx \
   ~/nwp/sites/mayo/dev/docs/governance/reference/
cp ~/MAYO/vic_association_research.xlsx \
   ~/nwp/sites/mayo/dev/docs/governance/reference/
cp ~/MAYO/mayo_policy_pack.docx \
   ~/nwp/sites/mayo/dev/docs/policies/source/
```

1.4. Add LFS tracking in `sites/mayo/dev/.gitattributes`:
```
*.docx filter=lfs diff=lfs merge=lfs -text
*.xlsx filter=lfs diff=lfs merge=lfs -text
*.sql.gz filter=lfs diff=lfs merge=lfs -text
*.tar.gz filter=lfs diff=lfs merge=lfs -text
```

1.5. Create `sites/mayo/dev/docs/README.md` — index linking to governance/, policies/, proposals/.

1.6. **Extract policies from `mayo_policy_pack.docx` to individual markdown files.** This step requires Rob to either:
   - (a) Open the `.docx` and copy-paste each policy section into the corresponding `policies/NN-*.md` file, OR
   - (b) Use `pandoc` to convert: `pandoc mayo_policy_pack.docx -t markdown -o policies-raw.md` then split into individual files.
   Each policy file gets YAML frontmatter:
   ```yaml
   ---
   policy_number: 1
   title: "Child Safety and Wellbeing Policy"
   visibility: public
   node_uuid: "6b8a1c20-1111-4000-8000-000000000001"
   alias: "/child-safety-policy"
   last_reviewed: "2026-04-13"
   next_review: "2027-04-13"
   ---
   ```
   The `node_uuid` and `alias` fields link the policy file to the corresponding mayo_content entity.

1.7. Create `sites/mayo/dev/docs/policies/README.md` — index of all 9 policies with visibility (public/members-only), review status, and UUID cross-references to mayo_content.

1.8. Create symlink for transition period:
```bash
ln -sfn ~/nwp/sites/mayo/dev/docs ~/MAYO.migrated
```
After verification, `rm -rf ~/MAYO` and `mv ~/MAYO.migrated ~/MAYO` (optional convenience symlink).

1.9. Verify: `ls -la ~/nwp/sites/mayo/dev/docs/governance/` shows both .md and reference/ files. `ls ~/nwp/sites/mayo/dev/docs/policies/` shows 9 numbered policy files + README + source/.

---

### Phase 2 — Bootstrap mayo/mayo Git Repo

**Goal:** All mayo site code tracked in `git@git.nwpcode.org:mayo/mayo.git`. DDEV still works after git init.

**Autonomy level:** Fully autonomous. Steps from F25 Phase 1, adapted.

2.1. Verify nothing under `sites/mayo/` is tracked by NWP:
```bash
cd ~/nwp && git ls-files sites/mayo/ | wc -l  # → 0
```

2.2. Copy `sites/avc/dev/.gitignore` to `sites/mayo/dev/.gitignore`. Remove the `html/profiles/custom/avc/` exclusion (mayo has no profile fork).

2.3. Move shared scripts into the repo tree:
```bash
mv ~/nwp/sites/mayo/scripts/seed-sanitized-users.sh \
   ~/nwp/sites/mayo/dev/scripts/
mv ~/nwp/sites/mayo/scripts/setup-safety-email.sh \
   ~/nwp/sites/mayo/dev/scripts/
```

2.4. Create `sites/mayo/dev/README.md` — what mayo/mayo is, how to clone + install, links to NWP and ADR-0017.

2.5. Initialize git:
```bash
cd ~/nwp/sites/mayo/dev && git init -b main
```

2.6. Stage with **explicit file list** (never `-A`):
```
.gitignore .gitattributes .editorconfig
composer.json composer.lock
README.md
docs/
scripts/
html/.gitignore html/autoload.php html/index.php html/.htaccess
html/robots.txt html/update.php
html/sites/default/default.settings.php
html/sites/default/default.services.yml
html/modules/custom/
.ddev/config.yaml
```

2.7. `git status` review. Expect: NO `vendor/`, `html/core/`, `auth.json`, `.env*`, `private/`, `.ddev/config.local.yaml`, `.nwp.yml`, `nwp.yml`.

2.8. `git commit -S -m "Initial mayo/mayo site template with docs and policies"`.

2.9. Push to GitLab:
```bash
git remote add origin git@git.nwpcode.org:mayo/mayo.git
git push -u origin main
```

2.10. Protect `main` branch on GitLab: require MR, block force-push.

2.11. Sanity check: `ddev start mayo-dev && ddev exec drush status`.

---

### Phase 3 — Policy Content Lifecycle

**Goal:** Updating a policy means editing a markdown file, running a script, and deploying. The content module stays in sync with the source docs.

**Autonomy level:** Steps 3.1-3.4 autonomous. Step 3.5 requires Rob to verify policy text matches .docx originals.

3.1. Create `sites/mayo/dev/scripts/sync-policies.sh` — a script that reads each `docs/policies/NN-*.md` file, extracts the body (below the YAML frontmatter), converts markdown to Drupal-safe HTML (via `pandoc -f markdown -t html` or a simple sed pipeline for basic formatting), and outputs a PHP array that the content module can consume. The script writes to `html/modules/custom/mayo_content/policy-content.generated.php` (gitignored — generated artifact, not source).

3.2. Modify `mayo_content.install` to load policy body text from `policy-content.generated.php` instead of inline strings. The UUIDs and aliases remain hardcoded in the module (they are structural, not content). The body text is the variable part.

   Fallback: if `policy-content.generated.php` does not exist (fresh checkout before running sync), the module falls back to a minimal placeholder: *"Policy content pending. Run scripts/sync-policies.sh to generate."*

3.3. Create `sites/mayo/dev/html/modules/custom/mayo_content/mayo_content.deploy.php` with deploy hooks:
```php
function mayo_content_deploy_0001_ensure_structural_content(&$sandbox): void {
    _mayo_content_create_pages();
    _mayo_content_create_groups();
    _mayo_content_create_menu();
    _mayo_content_create_footer_block();
}
```

3.4. Add `drupal/config_ignore ^3.3`, `drupal/config_filter ^2.6`, and `drupal/update_helper ^4` to composer.json. Run `ddev composer update`.

3.5. **Rob reviews**: run `ddev drush deploy` on dev. Verify zero DB changes (idempotency). Open each policy page in the browser and confirm content matches the `.docx` originals.

3.6. Commit to mayo/mayo:
```bash
git add scripts/sync-policies.sh html/modules/custom/mayo_content/
git commit -S -m "Policy content lifecycle: source markdown → deploy hooks"
```

---

### Phase 4 — Config Management and Staging

**Goal:** Config export is clean (no env-specific leaks). Staging has a real DDEV project with imported fixtures.

**Autonomy level:** Fully autonomous.

4.1. Create `sites/mayo/dev/config/sync/config_ignore.settings.yml` with env-specific exclusions:
```yaml
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

4.2. Edit `sites/mayo/dev/html/sites/default/settings.php`:
- Set `deployment_identifier` from `NWP_DEPLOY_ID` env var
- Add `config_exclude_modules` for dev-only modules
- Set `config_sync_directory = '../../config/sync'`
- Conditionally include `settings.deploy.php` if present

4.3. Create `servers/mayo1/scripts/stamp-deployment-identifier.sh`.

4.4. Patch `servers/mayo1/scripts/bluegreen-swap.sh` to call stamp pre-flip and `drush deploy` post-flip.

4.5. Build out `sites/mayo/stg/`:
- Create `.ddev/config.yaml` (name: `mayo-stg`, type: drupal10, ENV_TYPE=staging)
- Copy `composer.json` + `auth.json` from dev
- `ddev start && ddev composer install`
- `ddev drush site:install avc --existing-config`

4.6. Create `sites/mayo/scripts/restore-sanitized-fixture.sh` — takes a path or Package URL, runs `ddev import-db`, `ddev drush deploy`, `ddev drush cr`. Refuses to run unless DDEV project is mayo-dev or mayo-stg.

4.7. Export and commit config: `ddev drush config:export`, review diff, commit.

---

### Phase 5 — Mayo CI/CD Pipeline and Fixture Repo

**Goal:** Tagged releases of mayo/mayo produce signed tarballs in GitLab Packages. Nightly fixture publication from mayo1.

**Autonomy level:** Pipeline YAML and scripts are autonomous. GitLab CI variable configuration and runner registration require Rob.

5.1. Create `mayo/mayo-fixtures` private repo on GitLab with Git LFS enabled.

5.2. Bootstrap fixture repo in `~/nwp/work/mayo-fixtures/`:
- `.gitattributes` (LFS for .sql.gz, .tar.gz; plain text for .minisig)
- `manifest.yml`, `README.md`, `keys/pubkey.minisign`
- Seed from `sites/mayo/backups/mayo-avc-fresh.sql`
- Sign with minisign, commit, push

5.3. Create `sites/mayo/dev/.gitlab-ci.yml` — 11-stage pipeline per F25 Phase 6 spec (verify:signature, lint, test:fixture, test:phpunit, security:scan, build, sign, publish:package, deploy:review, e2e, cleanup:review).

5.4. Create `scripts/ci/fetch-mayo-fixture.sh` — downloads latest fixture from Package registry, verifies minisign, SQL sanity check.

5.5. Register dedicated `met-sign` runner (concurrency 1, protected-tags-only) with minisign installed.

5.6. Configure GitLab CI/CD variables on `mayo/mayo` (project-scoped, not group-wide):
- `MAYO_FIXTURES_DEPLOY_TOKEN` (masked, protected)
- `NWP_DEPLOY_PUBKEY` (file)
- `MINISIGN_SECRET_KEY` (file, masked, protected tags only)
- `MINISIGN_PASSWORD` (masked, protected tags only)
- `GITLAB_API_TOKEN_MAYO_PUBLISH` (masked, protected tags only)
- `OPS_MONS_LOG_WRITE_TOKEN` (masked, protected tags only)

5.7. Commit `.gitlab-ci.yml` to mayo/mayo main. Trigger first pipeline. Expect stages 1-5 pass.

5.8. Create `servers/mayo1/scripts/fixtures-publish.sh` — runs sanitizer, produces tarballs, signs, commits to mayo-fixtures, pushes.

5.9. Create `servers/mayo1/systemd/mayo-fixtures-publish.{service,timer}` — nightly 02:00 AEST.

5.10. First tagged release: `git tag -a v0.1.0 -m "First mayo production release"` → full pipeline → signed tarball in Packages → `ops/mons-log` issue.

---

### Phase 6 — Saintschool Bootstrap

**Goal:** saintschool.mayostudios.org has a working dev environment, git repo, and NWP site structure.

**Autonomy level:** Fully autonomous except step 6.8 (mons-bot identity split requires Rob).

6.1. Create identity split (per mayo-sites-scope memory):
- Create `mons-bot` GitLab user with read-only access to mayo group
- Issue mons its own PAT
- Revoke mons's use of mini-bot's PAT
- mini-bot stays the build-tier identity (read/write)

6.2. Create NWP site directory structure:
```bash
mkdir -p ~/nwp/sites/saintschool/{dev,stg,backups,scripts}
```

6.3. Create `sites/saintschool/.nwp.yml`:
```yaml
schema_version: 2
nwp_version_created: "0.30.0"
nwp_version_updated: "0.30.0"

project:
  name: saintschool
  type: drupal
  recipe: avc
  purpose: indefinite
  created: "2026-04-13T00:00:00Z"

live:
  enabled: true
  domain: saintschool.mayostudios.org
  server: mayo1
  linode_id: shared
  type: shared
  remote_path: /var/www/saintschool

backups:
  directory: ./backups

environments:
  - dev
  - stg
```

6.4. Create `sites/saintschool/dev/.nwp.yml` and `stg/.nwp.yml`.

6.5. Set up DDEV project:
- Create `sites/saintschool/dev/.ddev/config.yaml` (name: `saintschool-dev`)
- Create `composer.json` requiring `nwp/avc ^0.3` (same as mayo)
- `ddev start && ddev composer install`
- `ddev drush site:install avc`

6.6. Create `saintschool_content` custom module (mirrors mayo_content structure):
- Basic structural content: About page, policy pages (can reference mayo's policies if the organisations share them, or create school-specific versions)
- Groups relevant to a school context
- Deploy hooks for idempotent content creation

6.7. Initialize git and push:
```bash
cd ~/nwp/sites/saintschool/dev
git init -b main
# Stage with explicit file list (same pattern as Phase 2)
git commit -S -m "Initial saintschool site template"
git remote add origin git@git.nwpcode.org:mayo/saintschool.git
git push -u origin main
```

6.8. Protect `main` branch on GitLab.

6.9. Update `servers/mayo1/.nwp-server.yml`: change saintschool status from `planned` to `active`.

6.10. Create blue-green slot layout on mayo1 for saintschool:
```
/var/www/saintschool → /var/www/saintschool-blue
/var/www/saintschool-green/
/var/www/saintschool-shared/
  ├── files/
  ├── private/
  └── settings.local.php
```

6.11. Configure nginx for `saintschool.mayostudios.org` on mayo1 (virtual host, SSL via certbot).

---

### Phase 7 — Mayo↔Saintschool OIDC Integration

**Goal:** A user with a mayo account can log into saintschool with "Log in with Mayo". Mayo is the identity provider. Saintschool is the OIDC client.

**Autonomy level:** Steps 7.1-7.8 autonomous. Step 7.9 (first real cross-site login test) requires Rob.

This phase adapts F26's architecture (AVC as OIDC provider, SS as client) to the mayo context. The pattern is identical; only the domain names change.

7.1. On mayo dev: install and configure `simple_oauth` module.
- `ddev composer require drupal/simple_oauth`
- Generate RSA keys for token signing
- Configure OAuth2 server at `/oauth/authorize`
- Register saintschool as an OAuth2 client (client_id, redirect_uri)
- Enable OIDC discovery at `/.well-known/openid-configuration`

7.2. On saintschool dev: install and configure OIDC client.
- For Drupal/AVC: `ddev composer require drupal/openid_connect`
- Configure client to point at mayo's `.well-known/openid-configuration`
- Set `client_id` and `client_secret` (stored in settings.local.php, not in code)
- Map claims: `sub` → uid, `email` → mail, `name` → display name

7.3. Define the UID lock strategy (per F26 § 3.2):
- On first OIDC login, saintschool creates a local user with `field_mayo_uid = <mayo_uid>`
- Subsequent logins look up by `field_mayo_uid`, NOT by email
- Email and name sync from mayo on each login (mayo is authoritative)

7.4. Test cross-site login on dev:
- Start both DDEV projects (`mayo-dev`, `saintschool-dev`)
- Log into mayo-dev as a test user
- Navigate to saintschool-dev, click "Log in with Mayo"
- Verify: redirected to mayo, authorized, returned to saintschool with a session
- Verify: saintschool user record created with correct `field_mayo_uid`

7.5. Test email change propagation:
- Change test user's email on mayo-dev
- Log into saintschool-dev again
- Verify: saintschool user's email updated to match mayo

7.6. Add OIDC configuration to config_ignore lists on both sites (client_secret, redirect_uri are env-specific).

7.7. Update sanitizers for cross-site consistency:
- Extend `lib/sanitizers/mayo.sh` to call `oidc_email_sanitize()` from `oidc-email.sh` for the mayo user table
- Create `lib/sanitizers/saintschool.sh` following the mayo.sh pattern, also calling `oidc_email_sanitize()` for the saintschool user table
- Verify: sanitized mayo user emails match sanitized saintschool user emails for the same real person

7.8. Commit OIDC configuration to both repos.

7.9. **Rob tests**: end-to-end cross-site login on dev with sanitized fixture data.

---

### Phase 8 — Tier 2 Synthetic Example Site Pipeline

**Goal:** A single command produces a complete, zero-PII example site database that can ship with NWP.

**Autonomy level:** Fully autonomous.

8.1. Create `scripts/ci/build-example-site.sh`:
```bash
#!/bin/bash
# Build a Tier 2 synthetic example site from scratch.
# Zero production data involved. Safe for public distribution.
#
# Usage: ./build-example-site.sh [--output DIR] [--example-banner]
#
# Steps:
#   1. Start a temporary DDEV project (mayo-example)
#   2. composer install (AVC dependencies)
#   3. drush site:install avc
#   4. drush en mayo_content
#   5. Run seed-sanitized-users.sh (35 synthetic users)
#   6. Optionally inject example-mode banner on About/Mission pages
#   7. drush sql:dump → mayo-example-<version>.sql.gz
#   8. Sign with minisign
#   9. Tear down temporary DDEV project
#  10. Output: signed .sql.gz ready for packaging
```

8.2. The script uses a **temporary, isolated DDEV project** (name: `mayo-example-build`) that is created and destroyed within the script. It does not touch `mayo-dev` or `mayo-stg`.

8.3. The `--example-banner` flag (default: on) injects a notice into the About and Mission page bodies:
> *This is a demonstration site built by NWP (Narrow Way Project). It showcases the AVC (AV Commons) platform configured for a youth organisation. Replace this content with your own.*

This is done via a SQL UPDATE after the mayo_content install, targeting the known UUIDs of those two nodes. The banner is a Drupal `<div class="messages messages--warning">` so it renders as a visible notice.

8.4. Create `scripts/ci/package-example-site.sh`:
```bash
# Package the Tier 2 example as an NWP release artifact.
#
# Input:  mayo-example-<version>.sql.gz + .minisig
# Output: nwp-example-mayo-<version>.tar.gz containing:
#   - mayo-example-<version>.sql.gz (signed DB dump)
#   - mayo-example-<version>.sql.gz.minisig
#   - README.md (how to import into a fresh AVC install)
#   - MANIFEST.yml (schema_version, nwp_version, generated_at, checksums)
```

8.5. Add a `pl example build` command that wraps `build-example-site.sh`.

8.6. Add a `pl example publish` command that uploads the packaged artifact to the NWP GitLab Packages registry at `nwp/nwp/packages/generic/nwp-example-mayo/<version>/`.

8.7. Test the full cycle:
- `pl example build --tag v0.1.0`
- `pl example publish --tag v0.1.0`
- On a clean machine (or met): create a fresh AVC site, import the example DB, verify 13 pages + 10 groups + 35 users + example banner.

8.8. Commit scripts and command wrappers.

---

### Phase 9 — Saintschool CI/CD and Shared Fixtures

**Goal:** Saintschool has its own pipeline, fixture repo, and sanitizer. Shared infrastructure with mayo.

**Autonomy level:** Fully autonomous except runner and GitLab variable configuration.

9.1. Create `lib/sanitizers/saintschool.sh` following the mayo.sh pattern:
- Same 6-step structure (validate → backup → drop → truncate → sanitize → export → verify)
- Schema derived from actual saintschool tables (run `SHOW TABLES` once saintschool has a DB)
- Calls `oidc_email_sanitize()` for cross-site linkage
- PII sweep with appropriate allowlist

9.2. Create `mayo/saintschool-fixtures` private repo on GitLab with Git LFS.

9.3. Create `sites/saintschool/dev/.gitlab-ci.yml` — same 11-stage structure as mayo, pointing at saintschool-fixtures.

9.4. Create `servers/mayo1/scripts/saintschool-fixtures-publish.sh` and corresponding systemd timer.

9.5. Create `scripts/ci/fetch-saintschool-fixture.sh`.

9.6. Configure GitLab CI/CD variables on `mayo/saintschool` (same pattern as Phase 5.6).

9.7. First tagged release: `git tag -a v0.1.0` → pipeline → signed tarball → `ops/mons-log` issue.

---

### Phase 10 — End-to-End Integration Test

**Goal:** Both sites deployed to mayo1 via mons, cross-site OIDC working, both sanitization tiers verified.

**Autonomy level:** Steps 10.1-10.4 require Rob at mons. Steps 10.5-10.8 are verification that can be partially automated.

10.1. **WireGuard tunnel activation** (if not already done from F21):
- Generate WireGuard keypairs on mons and mayo1
- Exchange public keys
- Install configs from `servers/mayo1/wireguard/`
- Rebind mayo1 sshd to tunnel interface
- End-to-end tunnel test

10.2. **Deploy mayo v0.1.0 via mons:**
- Power up mons, bring up `wg-mons`
- `mons-deploy.sh mayo v0.1.0`
- Verify: site loads, 13 pages, 10 groups, user count unchanged
- `mons-say "deploy mayo v0.1.0 complete"`

10.3. **Deploy saintschool v0.1.0 via mons:**
- `mons-deploy.sh saintschool v0.1.0`
- Verify: site loads, structural content present
- `mons-say "deploy saintschool v0.1.0 complete"`

10.4. **Cross-site OIDC test on production:**
- Log into mayostudios.org as a test account
- Navigate to saintschool.mayostudios.org, click "Log in with Mayo"
- Verify: seamless login, correct user profile, correct permissions

10.5. **Tier 1 (internal) fixture verification:**
- On mayo1: `sudo systemctl start mayo-fixtures-publish.service`
- On met: pull mayo-fixtures, verify minisign, import to stg
- Verify: stg shows realistic data (node count matches prod, no PII in sweep)

10.6. **Tier 2 (public) fixture verification:**
- On dev: `pl example build --tag v0.1.0`
- Import into a fresh AVC DDEV project
- Verify: 13 pages, 10 groups, 35 users, example banner, zero real data
- `pl example publish --tag v0.1.0`
- On met: download from Packages, verify minisign, import, verify again

10.7. **Cross-site OIDC with Tier 1 fixtures:**
- Import mayo Tier 1 fixture into mayo-stg
- Import saintschool Tier 1 fixture into saintschool-stg
- Test OIDC login flow between stg environments
- Verify: deterministic email hashing preserved the linkage

10.8. **Documentation updates:**
- Update `docs/guides/mayo-avc-integration.md` with final state
- Update `docs/guides/mons-operations.md` with saintschool deploy procedure
- Create `docs/guides/nwp-example-site.md` — how to use the Tier 2 example

---

## 6. Files To Create / Modify

### 6.1 To Create

| File | Phase | Purpose |
|---|---|---|
| `sites/mayo/dev/docs/README.md` | 1 | Docs index |
| `sites/mayo/dev/docs/governance/incorporation-guide.md` | 1 | Relocated |
| `sites/mayo/dev/docs/governance/technical-implementation.md` | 1 | Relocated |
| `sites/mayo/dev/docs/governance/reference/*.docx` | 1 | Relocated |
| `sites/mayo/dev/docs/policies/01-*.md` through `09-*.md` | 1 | Extracted policies |
| `sites/mayo/dev/docs/policies/README.md` | 1 | Policy index |
| `sites/mayo/dev/.gitignore` | 2 | From AVC template |
| `sites/mayo/dev/README.md` | 2 | Repo readme |
| `sites/mayo/dev/html/modules/custom/mayo_content/mayo_content.deploy.php` | 3 | Deploy hooks |
| `sites/mayo/dev/scripts/sync-policies.sh` | 3 | Policy → module sync |
| `sites/mayo/dev/config/sync/config_ignore.settings.yml` | 4 | Env-safe config |
| `sites/mayo/stg/.ddev/config.yaml` | 4 | Staging DDEV |
| `sites/mayo/scripts/restore-sanitized-fixture.sh` | 4 | Fixture restore |
| `servers/mayo1/scripts/stamp-deployment-identifier.sh` | 4 | Deploy ID stamping |
| `sites/mayo/dev/.gitlab-ci.yml` | 5 | Mayo CI pipeline |
| `scripts/ci/fetch-mayo-fixture.sh` | 5 | CI fixture fetch |
| `servers/mayo1/scripts/fixtures-publish.sh` | 5 | Nightly sanitize+publish |
| `servers/mayo1/systemd/mayo-fixtures-publish.{service,timer}` | 5 | Nightly timer |
| `sites/saintschool/.nwp.yml` | 6 | Site config |
| `sites/saintschool/dev/.nwp.yml` | 6 | Dev env config |
| `sites/saintschool/stg/.nwp.yml` | 6 | Stg env config |
| `sites/saintschool/dev/.ddev/config.yaml` | 6 | DDEV project |
| `sites/saintschool/dev/composer.json` | 6 | Dependencies |
| `sites/saintschool/dev/html/modules/custom/saintschool_content/` | 6 | Content module |
| `lib/sanitizers/saintschool.sh` | 9 | Saintschool sanitizer |
| `scripts/ci/build-example-site.sh` | 8 | Tier 2 builder |
| `scripts/ci/package-example-site.sh` | 8 | Tier 2 packager |
| `scripts/ci/fetch-saintschool-fixture.sh` | 9 | CI fixture fetch |
| `servers/mayo1/scripts/saintschool-fixtures-publish.sh` | 9 | Nightly sanitize+publish |
| `servers/mayo1/systemd/saintschool-fixtures-publish.{service,timer}` | 9 | Nightly timer |
| `docs/guides/nwp-example-site.md` | 10 | Example site guide |

### 6.2 To Modify

| File | Phase | Change |
|---|---|---|
| `sites/mayo/dev/.gitattributes` | 1 | Add LFS tracking |
| `sites/mayo/dev/composer.json` | 3 | Add config_ignore, config_filter, update_helper |
| `sites/mayo/dev/html/modules/custom/mayo_content/mayo_content.install` | 3 | Load body text from generated file |
| `sites/mayo/dev/html/modules/custom/mayo_content/mayo_content.info.yml` | 3 | Add deps |
| `sites/mayo/dev/html/sites/default/settings.php` | 4 | deployment_identifier, config_exclude, sync dir |
| `servers/mayo1/scripts/bluegreen-swap.sh` | 4 | Call stamp pre-flip + drush deploy post-flip |
| `servers/mayo1/.nwp-server.yml` | 6 | saintschool status → active |
| `lib/sanitizers/mayo.sh` | 7 | Call oidc_email_sanitize for user emails |
| `docs/guides/mayo-avc-integration.md` | 10 | Final state update |
| `docs/guides/mons-operations.md` | 10 | Saintschool deploy procedure |
| `docs/proposals/F25-mayo-nwp-integration.md` | — | Mark SUPERSEDED BY F29 |

### 6.3 Existing Files Reused

| File | Used In |
|---|---|
| `sites/avc/dev/.gitignore` | Phase 2 (template) |
| `lib/sanitizers/oidc-email.sh` | Phases 7, 9 (cross-site email hashing) |
| `lib/minisign.sh` | Phases 5, 8, 9 (signing) |
| `scripts/commands/build.sh` | Phases 5, 9 (`pl build`) |
| `scripts/commands/publish.sh` | Phases 5, 8, 9 (`pl publish`) |
| `scripts/ci/create-preview.sh` | Phase 5 (review apps) |
| `scripts/ci/cleanup-preview.sh` | Phase 5 (review app cleanup) |
| `servers/mayo1/scripts/mons-deploy.sh` | Phase 10 (deploy orchestrator) |
| `servers/mayo1/scripts/bluegreen-setup.sh` | Phase 6 (saintschool slot setup) |

---

## 7. Verification Checklist

### Phase 1
- [ ] `ls ~/nwp/sites/mayo/dev/docs/policies/` shows 9 numbered .md files
- [ ] `ls ~/nwp/sites/mayo/dev/docs/governance/reference/` shows .docx files
- [ ] `~/MAYO/` is empty or replaced by symlink

### Phase 2
- [ ] `cd ~/nwp/sites/mayo/dev && git log --oneline` shows signed commits
- [ ] `git remote -v` points at `git.nwpcode.org:mayo/mayo.git`
- [ ] `ddev drush status` on mayo-dev still works

### Phase 3
- [ ] `ddev drush deploy` on dev is a no-op (zero changes)
- [ ] Policy pages show correct content from markdown source
- [ ] Changing a policy .md and running sync-policies.sh updates the page

### Phase 4
- [ ] `ddev drush config:export` produces clean diff
- [ ] mayo-stg running, shows imported fixture data

### Phase 5
- [ ] Pipeline green on mayo/mayo v0.1.0 tag
- [ ] Signed tarball in GitLab Packages
- [ ] `ops/mons-log` issue created
- [ ] Nightly fixture timer running on mayo1

### Phase 6
- [ ] `ddev drush status` on saintschool-dev works
- [ ] saintschool git repo on GitLab with protected main
- [ ] mons-bot identity split complete (separate PAT from mini-bot)

### Phase 7
- [ ] Cross-site OIDC login works on dev (mayo → saintschool)
- [ ] Email change on mayo propagates to saintschool
- [ ] Sanitized fixtures preserve OIDC linkage

### Phase 8
- [ ] `pl example build` produces a signed .sql.gz
- [ ] Importing into a fresh AVC site shows 13 pages, 10 groups, 35 users
- [ ] Example banner visible on About/Mission pages
- [ ] PII sweep of Tier 2 output: zero real data (expected: all synthetic)

### Phase 9
- [ ] saintschool pipeline green on v0.1.0 tag
- [ ] Saintschool fixture timer running on mayo1

### Phase 10
- [ ] Mayo and saintschool deployed to mayo1 via mons
- [ ] Cross-site OIDC working on production
- [ ] Tier 1 fixtures verified (realistic, no PII)
- [ ] Tier 2 example verified (synthetic, zero PII, importable)
- [ ] `mons-say` confirmations received

---

## 8. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Policy extraction from .docx loses formatting | Medium | Preserve .docx originals in `source/`; human review at step 1.6 |
| Tier 2 example site drifts from mayo_content module | Low | build-example-site.sh runs mayo_content install hooks directly; drift = code bug |
| OIDC client_secret in wrong config scope | High | Config Ignore list (Phase 4.1) excludes all OIDC secrets; per-env settings.local.php |
| Saintschool content module duplicates mayo_content patterns | Low | Acceptable duplication — sites have different content needs; shared helpers extracted only if pattern repeats 3+ times |
| Nightly fixture timer fails silently | Medium | Timer logs to journal; gotify alert on failure (if F22 Gotify is available); CI falls back to prior fixture with warning |
| Two-tier naming confusion | Low | Consistent naming: "internal fixture" (Tier 1) and "example site" (Tier 2) in all docs and scripts |
| mons-bot / mini-bot PAT split breaks existing pipeline | Medium | Do the split in Phase 6 before saintschool repo exists; test existing mayo pipeline with both identities |

---

## 9. Dependency Graph

```
Phase 1 (docs)          Phase 2 (repo)
    │                       │
    └───────┬───────────────┘
            │
        Phase 3 (policy lifecycle)
            │
        Phase 4 (config + stg)
            │
        Phase 5 (CI/CD + fixtures)
            │                           Phase 6 (saintschool bootstrap)
            │                               │
            └───────────┬───────────────────┘
                        │
                    Phase 7 (OIDC integration)
                        │
            ┌───────────┼───────────────────┐
            │           │                   │
        Phase 8     Phase 9             Phase 10
        (Tier 2)    (saintschool        (end-to-end)
                     CI/CD)                 │
            │           │                   │
            └───────────┴───────────────────┘
                        │
                    Phase 10 (end-to-end)
```

Phases 1-2 can run in parallel. Phases 8 and 9 can run in parallel after Phase 7. Phase 10 requires all others complete.

---

## 10. Acceptance

This proposal is done when:

1. All 10 phases complete with verification checklists passing.
2. `~/MAYO/` is empty (all docs in mayo/mayo repo).
3. mayo v0.1.0 and saintschool v0.1.0 deployed to mayo1 via mons.
4. Cross-site OIDC login works end-to-end on production.
5. Tier 1 nightly fixtures publishing from mayo1 for both sites.
6. Tier 2 example site importable by a new NWP user via `pl example build`.
7. All sanitization tiers verified (Tier 1: no PII in sweep; Tier 2: no real data ever present).
8. Documentation updated to reflect final state.

---

## 11. Relationship to Other Proposals

| Proposal | Relationship |
|---|---|
| **F25** (Mayo NWP Integration) | **Superseded.** F25 phases 1-8 are absorbed into F29 phases 2-5. Mark F25 as SUPERSEDED BY F29. |
| **F21** (Distributed Pipeline) | **Depends on.** F29 consumes F21's pipeline infrastructure (build, publish, minisign, mons-deploy, blue-green). F21 phases 5-8 (WireGuard, hardware tokens) are prerequisites for F29 Phase 10. |
| **F26** (AVC↔SS OIDC) | **Adapted.** F29 Phase 7 applies F26's OIDC architecture to mayo↔saintschool. F26 remains its own proposal for the avc.nwpcode.org ↔ ss.nwpcode.org pair. |
| **F27** (Feedback Ingest) | **Unblocked by.** F27's first tenant is mayo. F29 Phase 5 provides the mayo pipeline that F27 Phase 3 needs. |
| **F28** (Unified Pipeline) | **Aligned.** F29's pipeline structure follows F28's bundle/verify conventions. |
| **F23** (Site Environment Layout) | **Prerequisite met.** F23 is complete; F29 builds on its dev/stg layout. |
