# P63 — Secure, rebuildable nwc-project

**Status:** PHASES 1-5 COMPLETE 2026-05-22 (Phase 2.1 webonyx upgrade also done; Phase 4 CI + Phase 5 cadence committed)
**Owner:** Worker-E 2026-05-22 (Phases 1-3); unassigned for remainder
**Surfaced by:** Worker-E session 2026-05-22 (Track E set-up of met)
**Predecessor:** none — this captures latent debt that wasn't tracked
**Estimated effort:** 4–8 hrs focused, plus deploy verification. Phases 1-3 took ~1.5 hrs.
**Risk:** medium (Drupal core minor bump + dependency churn)

## What's done (2026-05-22)

Phase 1 (nwp/nwc 0.3.1 — security bump):
- ✅ `drupal/role_delegation` 1.4.0 → 1.6.0 (clears SA-CONTRIB-2026-002)
- ✅ `drupal/graphql` 4.9.0 → ^4.13 (lands 4.14.0 in lock; latest 4.x line)
- ✅ Dropped 2 graphql patches (3488581, 3506885) that are upstreamed in 4.14
- ✅ Kept 3191622 patch (Open Social cache-metadata behavior change)
- ✅ Tagged `v0.3.1`, pushed to `<gitlab-host>/nwp/nwc`

Phase 2 (nwc-project — composer update):
- ✅ `drupal/core` 10.6.8 → 10.6.9 (clears SA-CORE-2026-004)
- ✅ `twig/twig` 3.22.2 → 3.26.0 (clears 4 twig sandbox advisories incl. CVE-2024-45411)
- ✅ Many Symfony/Guzzle/etc patch bumps (transitive)
- ✅ drush/drush 13.6.2 now properly recorded in lock

Phase 3 (commit lock):
- ✅ `composer.lock` un-ignored + committed to `nwp/nwc-project`
- ✅ Single commit `composer: commit lock + un-ignore (P63 Phase 3)` pushed to origin/main

Phase 2.1 (deferred-then-completed) — webonyx DoS family cleared:
- ✅ `nwp/nwc v0.4.0` tagged (graphql 4→5, drush 13.6→13.7, PHP 8.1→8.3)
- ✅ Open Social research showed our custom code is byte-identical to
  theirs in the webonyx-touching files — no breakage risk for the bump
- ✅ All 3 webonyx/graphql-php DoS advisories now resolved

Phase 4 (CI):
- ✅ `.gitlab-ci.yml` committed to nwp/nwc-project (audit → build →
  minisign → publish). Awaits met-sign runner registration + CI variables.

Phase 5 (cadence):
- ✅ `docs/security/dependency-refresh-cadence.md` published — monthly
  audit + bump procedure, on-demand triggers for critical advisories.

Reproducibility test on met: ✅ git pull + composer install + drush updb + drush cr work cleanly. drush nwc-feedback:sync-to-gitlab returns healthy "no items pending."

## What's left

- ✅ **Phase 2.1 — webonyx/graphql-php DoS family.** All 3 advisories
  cleared 2026-05-22. The first-pass evaluation deferred this, but a
  deeper read of Open Social's upstream changed the verdict — see
  notes below.

  **What landed:**
  - `drupal/graphql` 4.14.0 → 5.0.0-rc1
  - `drupal/graphql_oauth` 1.0.0-alpha3 → 1.0.0-alpha4
  - `webonyx/graphql-php` 14.x-dev → v15.32.3 (the actual fix)
  - `drush/drush` ^13.6 → ^13.7 (required by graphql 5's new
    `DetectBreakingChangesCommand` using `Drush\Formatters\FormatterTrait`)
  - PHP minimum: 8.1 → 8.3 (required by drush 13.7+; matches Open
    Social 13.0.0's 2026-02-10 PHP bump)
  - DDEV `php_version` bumped 8.2 → 8.3 (per-machine config; .ddev/config.yaml
    is gitignored — has to be applied separately on each setup)
  - DB updates: `graphql_update_50000` + `graphql_update_50001` (sets
    `query_depth` and `query_complexity` to integer types — this is the
    GraphQL module gaining native query-complexity limits in 5.x, which
    is independently useful for hardening against DoS)

  **What the deeper Open Social research revealed (correcting the
  first-pass defer):**
  - Open Social's `main` branch pins `drupal/graphql 5.0.0-beta4`
    (committed 2026-04-24). Their last released tag (13.0.2) still
    ships graphql 4.9, but the upgrade work IS done on main.
  - We're ahead of their release schedule but on a path they've
    already verified.
  - The "~50 social_graphql classes" concern was wrong: a file-by-file
    diff between our profile and Open Social main shows the
    webonyx-API-touching classes (`EntityConnection`, `ConnectionInterface`,
    `ResolverRegistry`) are byte-identical. Open Social's resolution
    of breaking changes is a no-op — they didn't need to change those
    files, because they don't touch the breaking surfaces either.
  - Webonyx 14→15 has only 2 documented breaking changes per their
    UPGRADE.md: `category` field removed from error extensions, and
    `$exitWhenDone` parameter removed from `StandardServer::handleRequest()`.
    Neither affects our codebase.
  - The drupal/graphql 4→5 PR has been in beta since 2025-09 and
    rc since 2026-05-09 (more than a year of bake time).
  - Verified end-to-end on dev: drush 13.7.3 + Drupal 10.6.9 + PHP 8.3.25
    boots clean, sync command works, audit shows zero unfixed advisories.

  Tagged `nwp/nwc v0.4.0` for the bump.
- **Phase 4 — signed-artifact CI on met.** Now that the lock is
  committed, every `composer install` produces a deterministic vendor.
  Build that into a CI job that tars + signs + uploads as a release.
- **Phase 5 — refresh cadence + live backport.** Monthly audit + bump
  routine. Decide what live nwc runs.
- **Surfaced during P63 execution but not in original scope:**
  - **kint/devel/tracer/webprofiler enabled in nwc-dev DB.** These
    are dev-only modules that get installed via composer require-dev.
    The DB has them enabled (dev had them installed at DB-snapshot
    time). After `composer install` removes them (because they're
    not in require), Drupal can't boot on a fresh machine: the
    kint module's twig extension service is missing. Fix on met
    tonight was SQL surgery to remove the entries from `core.extension`
    config. The clean answer is to either (a) snapshot a sanitised
    DB that has dev-only modules uninstalled first, or (b) add a
    `drush pm:uninstall kint devel tracer webprofiler` step to the
    deploy/setup pipeline. See worker-E handover for the recipe used.
  - **HTTPS-token git remotes on met.** Since met doesn't
    have the `gitlab_linode` SSH key, `git pull` uses
    `https://oauth2:$GITLAB_TOKEN@<gitlab-host>/...` remotes for
    both nwc-project and nwc profile. Functional but tokens in
    `.git/config` is sub-ideal. Could be improved with git credential
    helper or by giving met its own SSH key (which the threat
    model would also accept — met is home-LAN AI-tier).

## Problem

`nwc-project` and its profile `nwp/nwc` are currently un-rebuildable
on a fresh machine. The vendor tree dev runs has accumulated several
months of CVE drift; composer's `block-insecure` audit refuses to
resolve any of the affected versions during a fresh `composer install`
or `composer update`. Dev still works because its `vendor/` predates
the advisories — but every other tier in the architecture (build,
deploy, and future CI runners) cannot reach that state through
composer.

The current "set up nwc on a new machine" procedure has degenerated
to: rsync dev's `html/` + `vendor/` + `composer.lock` to the target.
That works for replication but defeats reproducibility: there's no
signed artifact, no audited bill of materials, and no path back from
"dev's vendor as the source of truth" to "git as the source of truth."

This directly conflicts with the project's stated threat model
(`CLAUDE.md`): "Artifacts are trusted because they carry a valid
minisign signature from a known key, not because they came from a
'trusted' host." Today the artifact IS the trusted host's vendor
tree.

## Concrete advisory exposure (snapshot 2026-05-22)

Output of `ddev composer audit` against dev's currently-installed
tree:

| Package | Installed | Advisory IDs | Fix version |
|---|---|---|---|
| `drupal/role_delegation` | 1.4.0 | SA-CONTRIB-2026-002 | 1.5.0 (security release Jan 2026); 1.6.0 latest |
| `drupal/core` | 10.6.8 | SA-CORE-2026-004 (+ historical -001/-002/-003) | needs minor bump (check current 10.6.x or 10.7.x) |
| `twig/twig` | <3.26.0 | 4 advisories incl. CVE-2024-45411 (sandbox bypass) | 3.26.0 |
| `webonyx/graphql-php` | <=15.32.2 | 3 advisories (parser DoS) | 15.32.3 |
| `oomphinc/composer-installers-extender` | abandoned | n/a — package abandoned, no replacement suggested | replace or remove |

Plus: the install-blocking `block-insecure` behavior means we can't
even *try* a `composer update` to refresh until the role_delegation
pin is bumped, because composer halts at the first audit-failure
during dependency resolution.

## Scope of the proposed work

### Required (the security floor)

1. **Bump `drupal/role_delegation` from `1.4.0` to `1.6.0`** in
   `nwp/nwc` `composer.json`. Tag a `v0.3.1` release.

2. **Bump Drupal core** to a version that clears SA-CORE-2026-001
   through -004. Check `drupal/core-recommended` releases; pick the
   smallest minor that's not on the current advisory list.

3. **Bump `webonyx/graphql-php`** to ≥15.32.3 — likely requires
   bumping `drupal/graphql` from 4.9.0 to whatever pulls the
   patched version.

4. **Bump twig past 3.26.0.** Drupal core's twig pin will need to
   come along; this may force a higher core minor than (2) alone
   would require.

5. **Replace or remove `oomphinc/composer-installers-extender`.**
   **Resolution 2026-05-22:** keep it. The package is "abandoned"
   in the maintainer sense but still functions on composer 2.9.x.
   The functionality it provides — letting `composer/installers`
   handle arbitrary types like `npm-asset` and `bower-asset` — is
   deliberately not in `composer/installers` v2 (the maintainer
   considers it out of scope). Drupal projects that use
   asset-packagist (like this one) all carry the same dependency.
   No drop-in replacement exists. Fork into `nwp/composer-installers-extender`
   if it ever stops working; not justified today.

### Architectural (the reproducibility floor)

6. **Commit `composer.lock` to `nwp/nwc-project`.** Remove the
   `composer.lock` line from `.gitignore`. Composer's own docs and
   the `drupal/recommended-project` canonical template both commit
   the lock for `"type": "project"` repos. Today's "lock is
   gitignored" was almost certainly accidental — added in commit
   `87c3eab` ("Protect auth.json + secrets from accidental commits")
   bundled with the auth.json protection.

7. **Define and document the rebuild pipeline.** With (1)–(6) done,
   `composer install` on a fresh machine should produce an identical
   vendor/ to dev. Wrap that in a CI job (on met or future runner)
   that:
   - Pulls source from `nwp/nwc-project`
   - Runs `composer install --no-dev` (or with-dev for CI tests)
   - Runs `composer audit` (must pass clean)
   - Tarballs `html/` + `vendor/`
   - Signs the tarball with minisign
   - Uploads as a release artifact

8. **Bump DDEV PHP version from 8.2 to 8.3.** Drush 13.7+ requires
   8.3. Currently `drush/drush 13.7-rc` and beyond can't install
   in DDEV because the container is locked to 8.2 by
   `.ddev/config.yaml`. This isn't blocking today (13.6.2 is
   installed and works) but it'll bite the next time drush wants to
   move up.

### Stretch (the hygiene floor)

9. **Refresh cadence.** Adopt a monthly (or per-release) cycle of
   "run `composer audit`, plan the bumps, tag a new release of
   `nwp/nwc-project` with refreshed lock + signed artifact."
   Without this, the same drift accumulates in another year.

10. **Backport the secured baseline to live nwc.** If live is on the
    same vendor tree as dev, it carries the same advisories. Coordinate
    with the deploy pipeline (the offline deploy host) once the signed artifact is
    available.

## Why this matters for Track E (and any future "set up X on Y" work)

Until (1)–(7) land, **every new machine that needs nwc-dev requires
a manual rsync from dev**. That includes:

- A future fresh met rebuild
- A future fresh the home-LAN agent host rebuild
- Mons (offline deploy host)
- Any new CI runner
- A second developer joining the project

The rsync method is fragile:
- ~500 MB transfer per setup
- No verification that what arrived matches what was sent
- No audit trail of who installed what when
- Mismatches between machines accumulate silently (`auth.json`,
  `.env.local`, local DDEV addons like `docker-compose.ss-bridge.yaml`)

## Non-goals

- Not changing the application's behavior. Pure dependency hygiene.
- Not migrating to a different distribution base (e.g. Drupal 11).
  That's its own proposal.
- Not adopting a different deployment topology. The signed-artifact
  approach in (7) is what the existing threat model already prescribes;
  this just delivers it.

## Open questions

1. Does live nwc run the same vendor as dev? If yes, (10) is critical;
   if no, (10) reduces to "audit live and bring it to the same baseline."
2. Are there contrib modules in the dep tree pinned at exact versions
   that resist core bumps? `nwp/nwc` `composer.json` has many `1.0.0-beta6`,
   `2.1.0`, `3.0.0-beta4` style exact pins. The Drupal core bump in (2)
   may require relaxing some of these.
3. Should `nwp/nwc-project` keep the `nwc-local` path repository?
   Convenient for in-place dev edits to the profile, but adds resolution
   complexity. Could be replaced with a `composer` repository pointing
   at `<gitlab-host>`'s nwp registry.

## Suggested approach to scoping

Don't try (1)–(10) in one session. Suggested sequencing:

1. **Phase 1 (small win, ~1 hr):** (1) only — role_delegation bump
   to v0.3.1. Validates the bump procedure end-to-end without core
   churn. May not unblock fresh installs yet (core advisory still
   blocks), but lands the security fix.
2. **Phase 2 (~3-4 hrs):** (2)+(3)+(4) — core/twig/graphql bumps,
   working through whatever cascade results. End state: `composer
   audit` is clean.
3. **Phase 3 (~1 hr):** (5)+(6) — abandoned package + commit lock.
   Fresh `composer install` should now succeed on any machine.
4. **Phase 4 (~2 hrs):** (7)+(8) — signed-artifact CI + DDEV PHP 8.3.
5. **Phase 5 (ongoing):** (9)+(10) — cadence + live backport.

Each phase tags a new nwc-project release. Track E's rsync-mirroring
of met can be replaced with `composer install` from artifact at
the end of Phase 3.

---

*Surfaced 2026-05-22. Not yet scheduled.*
