# Dependency refresh cadence — nwc-project + nwp/nwc

**Status:** ADOPTED 2026-05-22 (P63 Phase 5)
**Owner:** project maintainer (rotates per release cycle)
**Frequency:** monthly, plus on-demand for high/critical advisories

## Why this exists

P63 caught the project in a degraded state: dev's `vendor/` had
accumulated 4+ months of security advisories (Drupal core,
twig sandbox bypasses, role_delegation, graphql-php DoS), and no
process existed to surface this. Each fresh `composer install` on
a new machine eventually became impossible.

The fix isn't a one-time bump; it's adopting a refresh loop so this
state doesn't reaccumulate.

## The monthly procedure

Run this on the **first business day of each month**. Estimate:
30 minutes if nothing's flagged; 1-3 hours if anything needs a bump
that ripples (Drupal core minor, framework majors).

### 1. Audit current state (5 min)

On dev's nwc-dev:

```bash
cd ~/nwp/sites/nwc/dev
ddev composer audit --no-dev --format=plain | tee /tmp/audit-$(date +%Y-%m).log
```

Look for:
- New `<package> | <severity>` rows
- The "Found N abandoned packages" line at the bottom

### 2. Categorise findings (5 min)

For each flagged advisory:

| Severity | Plan |
|---|---|
| `critical` or actively exploited | Patch within 48 hours via hotfix release |
| `high` | Patch within 2 weeks |
| `medium` | Patch in next scheduled release |
| `low` / informational | Track; bundle with next minor |

For each finding, decide:
- **Bump** (preferred): a fix version exists; bump constraint in
  `nwp/nwc` or `nwc-project` `composer.json`.
- **Ignore with rationale**: add to `audit.ignore` in
  `nwc-project/composer.json` with a comment explaining why and a
  ticket reference. Reserve for cases where:
    - No fix is available yet, AND
    - The vulnerability doesn't apply to this codebase's usage, OR
    - The fix is too invasive for the immediate release (defer with date).

### 3. Make the changes (varies)

For each `Bump` decision:
- If the package is required by `nwp/nwc` (the profile):
  - Edit `html/profiles/custom/nwc/composer.json`
  - Bump constraint, then bump the profile's `version` field
  - Commit + tag a new patch version on the `nwp/nwc` repo
- If the package is required by `nwp/nwc-project` directly:
  - Edit `composer.json` in nwc-project
- Run:
  ```bash
  ddev composer update <changed-packages> --with-dependencies
  ```
- Note: full `-W` updates can ripple into Drupal core and Symfony.
  Prefer targeted updates unless you specifically want to refresh
  the world.
- If `composer-patches` complains about a patch failing because the
  fix is upstreamed: remove that patch from the relevant
  `composer.json`'s `extra.patches` block. Then delete
  `vendor/composer/installed.json` and re-run `ddev composer install`
  to clear the patch plugin's cache.

### 4. Verify locally (5 min)

```bash
ddev composer install --no-dev          # what production gets
ddev exec drush updb -y                 # apply any DB updates
ddev exec drush cr                      # cache rebuild
ddev exec drush status                  # confirm bootstrap ok
ddev composer audit --no-dev            # confirm advisories cleared
```

If audit is clean (or only has the explicitly-ignored entries),
proceed.

### 5. Commit + push (5 min)

- nwc-project: single commit `composer: monthly refresh YYYY-MM`,
  push to main.
- nwp/nwc (if bumped): single commit `composer: monthly refresh YYYY-MM`,
  push to main, tag patch version, push tag.
- The CI pipeline (P63 Phase 4) will run audit + build a signed
  artifact on the tag.

### 6. Notify

Open a GitLab issue on `ops/notes` (or wherever the ops log lives)
summarizing:
- Audit before / after
- What was bumped
- What was ignored (with rationale)
- Whether the artifact pipeline produced a clean tarball
- Whether live needs a deploy

## On-demand triggers (skip the monthly wait)

Run the procedure immediately when:
- A `critical` advisory is published affecting an installed package
- A `high` advisory is published AND the package is on the public-
  facing request path (currently includes Drupal core, twig,
  webonyx/graphql-php)
- A maintainer reports active exploitation

## Common gotchas

- **`composer.lock` MUST stay committed.** If you find yourself
  gitignoring it, stop — the lock IS the artifact's bill-of-materials.
- **Dev-only modules in DB.** If `composer install --no-dev` leaves
  Drupal unable to boot because dev's DB snapshot has `kint`/`devel`
  enabled — your DB snapshot is stale. Uninstall those modules from
  the canonical snapshot. Recipe in
  `~/.claude/projects/-home-rob-nwp/memory/secure-rebuildable-nwc-project.md`.
- **`composer-patches` cache.** After dropping a patch, you may need
  `rm vendor/composer/installed.{json,php} && ddev composer install`
  to clear the plugin's cache.
- **DDEV PHP version drift.** If a transitive dep wants PHP 8.3+,
  decide whether to bump DDEV's PHP version in `.ddev/config.yaml`
  or hold the dep at an older line. Don't silently pin around a
  fresh PHP requirement — investigate first.

## Annual review

Each January, evaluate:
- Whether the cadence (monthly) is right — speed up to bi-weekly if
  Drupal advisories spike, slow down to quarterly if quiet.
- Whether the audit-ignore list has grown — if entries have been
  ignored for >12 months, escalate them.
- Whether the project is on a supported Drupal core minor. Drupal
  drops support for older minors on a published schedule
  (https://www.drupal.org/about/core/policies/core-release-cycles/schedule).

## See also

- `docs/proposals/P63-secure-rebuildable-nwc-project.md` — the
  proposal that introduced this cadence
- `.gitlab-ci.yml` — the build/sign/publish pipeline that consumes
  each refresh
- `docs/decisions/0017-distributed-build-deploy-pipeline.md` — trust
  model that the signed artifact carries
