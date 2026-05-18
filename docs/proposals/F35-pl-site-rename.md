# F35: First-class `pl site rename` command

**Status:** PROPOSED
**Created:** 2026-05-16
**Author:** Robert Karsten Zaar (with AI assistance)
**Priority:** Medium (no current pain — but the ss → ss1 rename of 2026-05-16 exposed a multi-step manual recipe that future renames will hit again)
**Depends On:** [F23](F23-project-separation-v2.md) (per-site `.nwp.yml` is the schema this command must keep consistent)
**Breaking Changes:** No (new command; existing sites unaffected unless renamed)
**Estimated Effort:** ~2 phases (renamer + cutover orchestrator); ~1 week
**Architecture decision records:** none new

> **Why this proposal exists.** On 2026-05-16, the SS Moodle site was
> renamed (`~/nwp/sites/ss/` → `~/nwp/sites/ss1/`) to free the `ss` name
> for a v3 rebuild. The rename touched at least nine files across two
> repositories, plus a separate manual server-side cutover sequence that
> `pl stg2live` was not designed to handle. The recipe is documented in
> `~/dir/courses_v3/MIGRATION_PLAN.md`, but every future site rename
> would have to re-derive it. This proposal makes the recipe a
> first-class `pl` command.

---

## 1. Executive Summary

Add `pl site rename <old> <new>` as a first-class command that atomically
renames a site across dev + (optionally) the live server, with a clear
rollback path.

**Concretely, `pl site rename ss ss1` should:**

1. Verify nothing in dev currently uses the old name (no running DDEV; no
   uncommitted changes that reference `ss/`).
2. `mv ~/nwp/sites/ss/ ~/nwp/sites/ss1/` and `mv
   ~/nwp/sites/ss_moodledata/ ~/nwp/sites/ss1_moodledata/`.
3. Update `~/nwp/sites/ss1/.nwp.yml`:
   - `project.name`: `ss` → `ss1`
   - `live.domain`: `ss.<example-prod-domain>` → `ss1.<example-prod-domain>` (or whatever
     domain the operator passes via `--domain`)
   - `live.remote_path`: `/var/www/ss` → `/var/www/ss1`
   - `live.moodle_data_path`: `/var/www/ss_moodledata` →
     `/var/www/ss1_moodledata`
   - Record provenance: `project.renamed_from`, `project.renamed_at`,
     `project.rename_reason` (free-text from `--reason` flag).
4. Update `~/nwp/nwp.yml`: rename the `ss:` block to `ss1:`.
5. For Moodle sites only (detected from `project.type` or
   `recipe`), edit DDEV config:
   - `~/nwp/sites/ss1/dev/.ddev/config.yaml`: `name: ss-dev` → `name:
     ss1-dev`
   - `~/nwp/sites/ss1/dev/.ddev/docker-compose.moodledata.yaml`: volume
     path
   - `~/nwp/sites/ss1/dev/config.php`: `wwwroot`
6. For Drupal sites, perform the equivalent Drupal-specific edits.
7. Optional `--cutover` flag: run the live-server cutover sequence
   (currently in `MIGRATION_PLAN.md` §4a–§4d):
   - Verify DNS for the new domain resolves to the live server.
   - `pl stg2live <new>` to create a fresh parallel deployment.
   - Sync DB + moodledata from the old install to the new install.
   - Edit `mdl_config.wwwroot` (or Drupal equivalent) in the new DB.
   - Replace the old nginx vhost with a 302 redirect to the new domain.
   - Archive (not delete) the old `/var/www/<old>` and
     `/var/www/<old>_moodledata`.
8. Generate a rename log in `~/nwp/sites/<new>/backups/rename-<timestamp>.md`
   capturing every action and its rollback inverse.
9. Print a checklist of any **out-of-tree** references the rename can't
   automatically fix (cross-project doc mentions, memory files, etc.) so
   the operator knows what to follow up.

---

## 2. Why this isn't just "use `pl stg2live <new>`"

The 2026-05-16 audit of `pl` source found that `pl stg2live`:

- **Derives the live vhost, `/var/www/<name>` path, DB name, and DB user
  from the directory name** (`scripts/commands/stg2live.sh:270-271`,
  `scripts/commands/live.sh:352-422`).
- **Does NOT read `live.domain` from `.nwp.yml`** — the domain is
  reconstructed from `${sitename}.${base_domain}`.
- **Does NOT know about a previous deployment under a different name** —
  running `pl stg2live ss1` after a directory rename creates a parallel
  deployment alongside the existing `/var/www/ss` rather than renaming
  it.

So a rename today is a **multi-step manual process**, not "do the rename
in dev and ship". This is exactly the kind of operational sharp edge a
first-class command should round off.

---

## 3. Cross-project ramifications

A rename inside `~/nwp/sites/` affects more than just nwp. The 2026-05-16
audit found stale references in:

- **`~/saint_school/*.md`** (8 files) — operational instructions that
  named the DDEV URL and dev path.
- **`~/central/saint_school.md`, `~/central/INDEX.md`,
  `~/central/PUBLIC-PRIVATE-STRATEGY.md`, `~/central/rosary.md`** —
  oversight docs.
- **`~/rosary/{README,PROPOSAL}.md`, `~/rosary/moodle/README.md`** —
  Moodle plugin canonical-path docs.
- **`~/prayer/proposals/REPORT_Platform_Design_Copyright_Scripture.md`**
  — proposal cites Flutter app + Moodle site path.
- **`~/combined/scripts/extract_courses_combined.py`** — script
  hard-codes the old data path.
- **`~/.claude/projects/-home-rob-nwp/memory/*.md`** — Claude memory
  files cite canonical locations.
- **`~/.local/bin/ccapp`** — shell launcher for the Flutter binary.

`pl site rename` can't automatically rewrite all of these — they're
outside the nwp repo. The command should:

1. `grep -r` for references to the old name across operator-known content
   roots (`~/dir`, `~/central`, `~/prayer`, `~/rosary`, `~/saint_school`,
   `~/combined`, `~/.local/bin`, `~/.claude/projects`).
2. Print a checklist of files containing stale references.
3. Optionally accept `--also-rewrite=PATH[,PATH,...]` to apply the
   substitution in additional roots.

This is the most defensible scope. Anything more (auto-rewriting docs
across the home directory) would be unsafe.

---

## 4. The five phases of the work

### Phase 1 — Renamer (dev-only, no live cutover)

`pl site rename <old> <new>` with these flags:

- `--reason <text>` — populates `project.rename_reason` in `.nwp.yml`.
- `--domain <new-domain>` — overrides the default `<new>.<base_domain>`.
- `--also-rewrite <paths>` — comma-separated additional roots to scan
  and rewrite.
- `--dry-run` — print the plan and exit.
- `--no-ddev` — skip DDEV name updates (for non-DDEV sites).

Does steps 1–6 from the executive summary. Stops short of the live
cutover. Validates with `pl site list` and `pl doctor` before exiting.

### Phase 2 — Live cutover (`--cutover` flag)

When `--cutover` is passed, the renamer additionally:

- Verifies DNS for the new domain resolves to the live server (`dig`
  check against `live.server_ip` from the server registry).
- Runs `pl stg2live <new>` to provision the new deployment.
- Runs the data sync: `mysqldump <old> | mysql <new>`; rsync the
  moodledata; UPDATE `mdl_config.wwwroot`; purge caches.
- Replaces the old vhost with a 302 redirect block to the new domain.
- Archives `/var/www/<old>` and `/var/www/<old>_moodledata`.

The rename log captures the inverse of each action so `pl site rename
--rollback <new>` is a valid undo until the archived directories are
manually deleted.

### Phase 3 — Cross-project reference checker

`pl site rename --check-refs <old>` (no rename; just check) for the
audit use case. Scans known operator content roots for references to
the old name and prints a report.

### Phase 4 — Tests

Bats tests for:

- Dry-run produces a stable plan.
- Renamer leaves the site in a state where `pl site list` shows the new
  name and `ddev start` works.
- `--rollback` after a failed rename leaves the site as it was.
- `--cutover` correctly orchestrates the four substeps and rolls them
  back on failure.

### Phase 5 — Documentation

- `docs/governance/runbooks/site-rename.md` (new) — narrative version
  of the command for operators preferring step-by-step.
- Update `docs/proposals/F23-project-separation-v2.md` §6 (Migration
  Path) to point at `pl site rename` for future renames rather than
  describing them as "manual".

---

## 5. Risks and trade-offs

- **DB rename is the most fragile step.** mysqldump + load is safe but
  can be slow on a large Moodle DB. The renamer should accept a
  `--db-method=dump|alter` flag, defaulting to dump. The `alter` path
  would issue `RENAME TABLE \`<old>\`.\`mdl_*\` TO \`<new>\`.\`mdl_*\``
  per-table, which is faster but only works when source and target DBs
  are on the same MariaDB instance (which they are for shared-server
  sites). Recommended: implement `dump` first; add `alter` later.
- **Let's Encrypt rate limits.** A rename that runs `pl stg2live <new>`
  issues a fresh cert. If the rename happens repeatedly (testing), the
  rate limit (50 certs per week per registered domain) can be hit.
  Recommend `--staging-cert` flag during testing.
- **Moodle session table.** Active user sessions are bound to the old
  `wwwroot` and will be invalidated by the cutover. Print a warning
  during dry-run; users will be forced to log in again on the new
  domain.
- **The "rename" abstraction may be misleading.** The implementation is
  really "create new + sync + redirect old". A truly atomic rename
  doesn't exist for Moodle (or Drupal) at the deployment level — the
  command should be honest about this in its help text.
- **Provoking F23 schema drift.** If F23 reaches Phase 2+ before this
  command lands, the schema fields the command updates may have moved
  or renamed. Add a CURRENT_SITE_SCHEMA check at the top of the renamer.

---

## 6. Out of scope

- **Drupal-specific orchestration** beyond `wwwroot` update and DB
  rename. Drupal has its own quirks (`sites/default/settings.php`,
  trusted_host_patterns, base_url) that this proposal acknowledges
  exist but doesn't enumerate. A separate sub-proposal could detail
  the Drupal path once a real Drupal rename comes up.
- **Cross-server moves.** `pl site rename` assumes the site stays on
  the same `live.server`. Moving a site between servers is a separate
  operation (Linode → Linode migration) that should be its own command
  (`pl site move-server`).
- **Atomic cutover with zero downtime.** The cutover has at least a few
  seconds of user-visible downtime (nginx reload after vhost swap).
  Eliminating this would require a blue-green deployment pattern that
  is out of scope.

---

## 7. Acceptance criteria

- [ ] `pl site rename --help` exists and documents all flags.
- [ ] `pl site rename old new --dry-run` prints a complete plan and exits
      0 without modifying anything.
- [ ] `pl site rename old new` (no flags) successfully renames a dev-only
      Moodle site and leaves it bootable via `ddev start`.
- [ ] `pl site rename old new --cutover` orchestrates the live cutover and
      produces a working deployment at the new domain.
- [ ] `pl site rename --check-refs old` scans the operator's content
      roots and prints a stale-references report.
- [ ] Bats tests pass; `pl doctor` reports the renamed site as healthy.
- [ ] `docs/governance/runbooks/site-rename.md` exists and matches the
      command's behaviour.
- [ ] F23 §6 references this command rather than describing manual
      rename steps.

---

## 8. Prior art

The closest existing pattern is `lib/migrations/site/002-env-layout.sh`,
which absorbs `<site>-stg` siblings into `<site>/stg/` during the F23
Phase 1 → Phase 2 migration. That's a *one-time* schema migration, not a
general-purpose rename. This proposal generalises that pattern to
arbitrary operator-driven renames.
