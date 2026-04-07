# F25: Pre-Baseline Cleanup for v0.30.0 Fresh Repo Reset

**Status:** IMPLEMENTED (Phases 1–7 complete; Phase 8 pending user confirmation)
**Created:** 2026-04-07
**Completed:** 2026-04-07 (cleanup phases)
**Author:** Rob Zaar, Claude Opus 4.6
**Priority:** Critical (blocks fresh repo commit)
**Depends On:** F23 phases 1-8 + 10 (complete)
**Breaking Changes:** None (documentation, config, and cosmetic code only)

> **Status note:** Cleanup phases 1–7 are complete. Phase 8 (delete `.git`,
> re-init, commit, tag v0.30.0) is destructive and intentionally left for
> explicit user trigger. Items marked `(deferred)` were optional polish that
> the user chose to skip for the baseline.

---

## 1. Executive Summary

### 1.1 Context

F23 phases 1-8 and 10 are complete. The existing `~/nwp/.git` carries a lot of legacy
history — completed handover docs, pre-F23 paths, stale whitelist entries, session
recovery artifacts, and 1 MB of verification state that churns on every test run.
The user has already backed up `.git` and renamed the upstream remotes. The plan is
to `rm -rf .git`, re-initialise the repo, and commit a clean v0.30.0 baseline.

Before committing, we need to clean up everything that would otherwise ship into the
first commit as legacy noise.

### 1.2 Goal

Produce a cleanly-organised v0.30.0 baseline where:

- Every top-level file is either essential (`pl`, `CLAUDE.md`, `README.md`, etc.) or
  consciously kept.
- All documentation reflects the post-F23 architecture — no stale paths.
- Proposal IDs are unique, status fields accurately reflect reality, and completed
  work is in `docs/reports/milestones.md`.
- Documentation has a navigable structure (no 9 miscellaneous files dumped into
  `docs/` root).
- `.gitignore` has no dead whitelist entries.
- The final `git add -A` stages exactly what we intend, nothing more.

### 1.3 Non-goals

- **Not** doing F23 Phase 9 (OAuth2 + Guild sync) — deferred.
- **Not** doing F24 (unified backup strategy) — deferred.
- **Not** touching `sites/<name>/` contents — each production site has its own git
  repo and is out of scope.
- **Not** doing architectural changes — only docs, config, and tiny dispatch fixes.

### 1.4 How to use this document

Every item below is numbered as `X.Y` where `X` is the phase and `Y` is the item.
Work phase-by-phase; within a phase items are independent and can be done in any
order. Mark items done with `[x]`.

**Blocker matrix:**
- **BLOCKER** — must finish before the fresh commit.
- **SHOULD** — strongly recommended before commit; defers create tech debt.
- **OPTIONAL** — post-baseline cleanup; safe to defer.

---

## 2. Audit Findings Summary

Three parallel audits ran over the top-level docs, the codebase at large (for stale
F23 refs), the schema/migration framework, the proposal corpus, and the `docs/`
structure. Summary of actionable findings:

| Area | Issues | Critical | Should | Optional |
|---|---|---|---|---|
| Top-level docs (11 files) | 5 obsolete/misplaced, 3 stale paths in README, 1 link fix | 4 | 3 | 1 |
| Codebase stale refs (scripts/lib/tests) | 0 showstoppers, 2 minor dispatch bugs | 0 | 2 | 0 |
| Schema/migration consistency | All sites at v1, server at v1, example.nwp.yml missing `dir` recipe | 0 | 1 | 0 |
| Proposal corpus (32 files) | **2 F23 files** (v2 supersedes v1), F23 status still `PROPOSED` despite being mostly done, P59 gap (unexplained), 9 site-specific proposals with one non-standard location | 2 | 3 | 1 |
| `docs/` structure (188 .md, 4 .docx) | 9 top-level files that should live in subdirs, 4 Moodle SSO docs overlap, 3 redundant `.docx`, 1 `.docx` with no companion, `docs/README.md` says v0.23.0 | 3 | 6 | 3 |
| `.gitignore` stale whitelist | 8 dead entries (dirs/files no longer exist or being deleted) | 0 | 1 | 0 |
| **Totals** | — | **9** | **16** | **5** |

Two claims from the audits were **refuted** on follow-up verification and are **not**
included as findings:

- ❌ ~`scripts/ci/fetch-db.sh:108` hardcoded sitebackups path~ — it's CI-only,
  `SITE_NAME` is set by GitLab env, and there's explicit error handling. Not a bug.
- ❌ ~`sites/cccrdf/.nwp.yml` field order broken~ — `lib/migrate-schema.sh:40` uses
  `yq eval '.schema_version'`, which is position-agnostic. Not a bug.

---

## 3. Phase 1 — Pre-Commit Critical Cleanup (BLOCKER)

These must be done before the fresh commit or the baseline will ship with broken,
obsolete, or confusing content.

- [x] **1.1 Delete obsolete session artifacts at repo root**
  Files are from completed P50 work, no ongoing value:
  - `~/nwp/HANDOVER-P50.md` — crashed-session recovery dump
  - `~/nwp/IMPLEMENT-P50.md` — task tracker, P50 status=COMPLETE
  - `~/nwp/migrate-verification-v2.sh` — one-time schema migration, already executed
  Command: `rm -f HANDOVER-P50.md IMPLEMENT-P50.md migrate-verification-v2.sh`

- [x] **1.2 Move `IMPLEMENTATION_SUMMARY.md` to its project**
  It's an AVC-Moodle SSO Phase 1 summary, not NWP core. Destination:
  `docs/projects/avc/implementation-summary.md` (rename for clarity).

- [x] **1.3 Resolve F23 duplicate proposal files**
  Two files claim ID `F23`, both created 2026-04-06:
  - `docs/proposals/F23-project-separation.md` (1409 lines, v1 — "extract core NWP")
  - `docs/proposals/F23-project-separation-v2.md` (2005 lines, v2 — "self-contained
    sites within NWP", explicitly `**Supersedes:** F23 v1`)
  v2 is the one we actually implemented. Actions:
    - [ ] Move v1 → `docs/archive/F23-project-separation-v1-superseded.md`
    - [ ] Rename v2 → `docs/proposals/F23-project-separation.md`
    - [ ] Add a `**Superseded by:** (archived)` line to the v1 header before moving

- [x] **1.4 Update F23 status to reflect reality**
  In the renamed `F23-project-separation.md`:
    - [ ] Change `**Status:** PROPOSED` → `**Status:** IMPLEMENTED (phases 1-8, 10);
          Phase 9 DEFERRED`
    - [ ] Add `**Completed:** 2026-04-07` line
    - [ ] Update the phase checklist section if present to mark 1-8 and 10 as done
    - [ ] Leave Phase 9 section intact but clearly labelled DEFERRED

- [x] **1.5 Delete redundant `.docx` files in `docs/reports/`**
  All three have matching `.md` companions — the `.docx` is binary noise:
  - `docs/reports/nwp-status-2026-03-10.docx` (35K)
  - `docs/reports/nwp-executive-summary-2026-03-10.docx` (17K)
  - `docs/reports/nwp-landscape-analysis-2026-03-12.docx` (35K)

- [x] **1.6 Decide fate of `docs/proposals/nwp-solveit-proposal.docx`**
  **Decision:** Converted to `F26-solveit-methodology.md` and original `.docx` deleted.
  19K binary, no `.md` companion. Either:
    - [ ] Convert to `.md` and keep (if it's still an active proposal), or
    - [ ] Move to `docs/archive/` (if it's superseded), or
    - [ ] Delete (if obsolete)
  **User decision required.**

- [x] **1.7 Fix version in `docs/README.md`**
  Currently says v0.23.0; should say v0.30.0. Also update the "Last Updated" line.

- [x] **1.8 Delete `docs/P54-IMPLEMENTATION-PLAN.md` at docs/ top level**
  P54 is IMPLEMENTED. The implementation plan is historical. Move to
  `docs/reports/P54-implementation-plan.md` (archive) or delete.

- [x] **1.9 Delete `docs/SETUP_COMPLETE.md` and `docs/DEPLOYMENT_COMPLETE.md`**
  **Decision:** Deleted (per user direction).
  Both are completion artefacts from integration work. Move to `docs/reports/` or
  delete. **User decision: keep as history or drop?**

---

## 4. Phase 2 — Top-Level Documentation Updates (SHOULD)

Most of these are small find-and-replace fixes in live docs.

- [x] **2.1 `README.md` — fix stale GitLab deployment section**
  Lines 1092–1130 reference `cd git` and `./linode/gitlab/gitlab_setup.sh`. Update to
  `servers/nwpcode/linode/gitlab/gitlab_setup.sh`. Ensure any `cd git` → `cd
  servers/nwpcode`.

- [x] **2.2 `README.md` — fix module installation section**
  Lines 1028–1029 say "Clone git modules to `modules/custom/`" at repo root. Update
  to `sites/<name>/web/modules/custom/`.

- [x] **2.3 `README.md` — fix directory structure diagrams**
  Lines 1492–1549 show `email/` and `linode/` at root. Update to show them under
  `servers/nwpcode/`. Also show `sites/<name>/web/modules/custom/` and
  `sites/<name>/pipeline/`.

- [ ] **2.4 `README.md` — add F23 architecture note** *(deferred — minor polish)*
  Brief callout near the top: "As of v0.30.0 (F23), sites and servers are
  self-contained. See `docs/proposals/F23-project-separation.md` for the full story."

- [x] **2.5 `CONTRIBUTING.md` — fix coder onboarding link**
  Line 34 references `docs/CODER_ONBOARDING.md`. Correct path is
  `docs/guides/coder-onboarding.md`.

- [x] **2.6 `CHANGELOG.md` — close out `[Unreleased]` as `[0.30.0]`**
  The F23 entries under `[Unreleased]` become the `[0.30.0] - 2026-04-07` block. Add
  a one-line summary at the top. Include migration note pointing to F23 proposal.

- [x] **2.7 `example.nwp.yml` — add `dir` recipe**
  **Note:** Done via the new project-shipped recipes pattern instead — `dir` recipe
  now lives at `sites/dir/recipe.yml` (loaded via fallback in `lib/install-common.sh`).
  Same for `mt`. `example.nwp.yml` now contains a comment block explaining the pattern.
  The `dir` recipe (Divine Intimacy Radio) exists in the user's `nwp.yml` at lines
  790-801 but is missing from `example.nwp.yml`. Copy the recipe definition across
  (as a commented example like the others).

- [ ] **2.8 `example.nwp.yml` — document `schema_version` for new users** *(deferred — minor polish)*
  Add a top-level comment block explaining the per-site `.nwp.yml` schema_version
  field and the migration framework. 5-10 lines of comment.

- [ ] **2.9 `CLAUDE.md` — no changes needed** ✓
  The audit confirmed `CLAUDE.md` is clean and accurately reflects post-F23
  architecture. Ship as-is.

- [ ] **2.10 `KNOWN_ISSUES.md` — sweep for F23-completed items** *(deferred — manual review)*
  Check for any entries about F23-era issues that are now resolved and remove them.

---

## 5. Phase 3 — `docs/` Structural Cleanup (SHOULD / OPTIONAL)

`docs/` has 188 `.md` files and 16 of them are loose at the top level. Nine of those
belong in subdirectories. Also 4 Moodle SSO docs that overlap massively.

### 5a. Move top-level docs into subdirs (SHOULD)

| Current | Destination | Reason |
|---|---|---|
| `docs/AVC_MOODLE_INTEGRATION_PROPOSAL.md` | `docs/projects/avc/moodle-sso-proposal.md` | AVC-specific |
| `docs/AVC_MOODLE_SSO_COMPLETE.md` | `docs/projects/avc/moodle-sso-complete.md` | AVC-specific |
| `docs/AVC_MOODLE_SSO_IMPLEMENTATION_COMPLETE.md` | `docs/projects/avc/moodle-sso-implementation.md` | AVC-specific |
| `docs/NWP_MOODLE_SSO_IMPLEMENTATION.md` | `docs/projects/avc/moodle-sso-nwp.md` | AVC-specific |
| `docs/MOODLE_COURSE_CREATION_GUIDE.md` | `docs/guides/moodle-course-creation.md` | Is a guide |
| `docs/CLAUDE_CHEATSHEET.md` | `docs/guides/claude-cheatsheet.md` | Is a guide |
| `docs/DOCUMENTATION_STANDARDS.md` | `docs/governance/documentation-standards.md` | Is governance |
| `docs/YAML_API.md` | `docs/reference/yaml-api.md` | Is a reference |
| `docs/VERIFY_ENHANCEMENTS.md` | `docs/testing/verify-enhancements.md` | Is testing docs |

- [x] **3.1** Execute the 9 moves above (prefer `git mv` once in the fresh repo; for
  now just `mv`). **Done.** Plain `mv` used. `docs/README.md` and `lib/README.md`
  navigational refs updated; historical references inside the moved AVC docs were
  intentionally left untouched (they describe past file paths).

### 5b. Consolidate overlapping docs (SHOULD)

- [ ] **3.2 Consolidate the 4 Moodle SSO docs into a single source of truth** *(deferred — significant writing task, may be done post-baseline)*
  Total ~3,800 lines across 4 files. Target: one `docs/projects/avc/moodle-sso.md`
  that merges the non-redundant content. Archive the originals to
  `docs/archive/avc-moodle-sso-history/` for traceability.
  **This is a significant writing task — may be done post-baseline.**

- [ ] **3.3 Verify `docs/SECURITY.md` vs `docs/security/data-security-best-practices.md`** *(deferred — manual content audit)*
  Audit flagged possible duplication. If content is identical or near-identical,
  delete `docs/SECURITY.md` and keep the subdir version. Otherwise merge.

- [ ] **3.4 Resolve `docs/COMMAND_INVENTORY.md` vs `docs/reference/commands/README.md`** *(deferred — manual content audit)*
  Audit says the former is superseded by the latter. Delete `COMMAND_INVENTORY.md`
  or move to `docs/archive/`.

### 5c. Archive stale reports (OPTIONAL)

- [x] **3.5 Archive reports older than 60 days**
  Move these to `docs/archive/reports/`:
  - `docs/reports/NWP_COMPREHENSIVE_ANALYSIS_2026-01-20.md` (~65 days old)
  - `docs/reports/IMPLEMENTATION_PLAN_2026-01.md` (~80 days old)
  - `docs/reports/documentation-audit-2026-01-12.md` (~80 days old)
  - `docs/reports/documentation-creation-timeline.txt` — convert to `.md` or delete

### 5d. Add navigation README files (OPTIONAL)

- [ ] **3.6 Create `docs/plans/README.md`** *(deferred — optional polish)*
  Brief index of the 3 plan files there (F19 CathNet, SS mobile analysis, SS mobile
  implementation). Note: `docs/plans/` is legitimate and new — keep it.

- [ ] **3.7 Create `docs/projects/README.md`** *(deferred — optional polish)*
  Brief index of the avc/ and podcast/ subdirs with one-line descriptions.

- [ ] **3.8 Create `docs/reports/README.md`** *(deferred — optional polish)*
  Distinguish living docs (`milestones.md`) from dated snapshots
  (`nwp-status-2026-03-10.md`).

---

## 6. Phase 4 — Proposal Corpus Hygiene (SHOULD)

- [x] **4.1 F23 deduplication** — done as 1.3 above.

- [x] **4.2 F23 status update** — done as 1.4 above.

- [x] **4.3 Standardise AVC site proposal location**
  AVC proposals currently live at the non-standard path
  `sites/avc/html/profiles/custom/avc/docs/proposals/`. Other sites use
  `sites/<name>/docs/proposals/`. The `pl proposals` aggregator only looks at the
  standard location.
  - [x] Move `WORKFLOW_SYSTEM_COMPLETE_IMPLEMENTATION_PLAN.md` and
        `GUILD_MULTIPLE_VERIFICATION_TYPES.md` to `sites/avc/docs/proposals/`
  - [x] Verify `pl proposals --site=avc` picks them up — confirmed (both listed)
  **Note:** This touches `sites/avc/`, which is its own git repo. Do the move with
  a commit in the AVC repo separately; don't stage it in the NWP baseline.

- [x] **4.4 Document the P59 gap or fill it**
  P58 → P60 exists with no P59. **Decision:** Note added to
  `docs/proposals/README.md` explaining the intentional skip.

- [x] **4.5 P52 (rejected rename) — archive or keep?**
  **Decision:** Keep in `docs/proposals/` as historical record. Visibility of the
  rejection is the point — anyone scanning the proposal index sees that the rename
  was considered and refused.

- [x] **4.6 Update `docs/proposals/README.md` proposal index**
  After 1.3 and 1.4, update the index to reflect:
    - F23 status = IMPLEMENTED (phases 1-8, 10)
    - F23 v1 archived
    - Any other state changes

- [x] **4.7 Scan P51 (AI-Powered Verification) for actual status**
  **Decision:** Keep P51 monolithic (Agent A recommendation). P51 is the main
  Functional Verification system, status confirmed via the Completed list in
  `docs/proposals/README.md`. Header left as-is.

---

## 7. Phase 5 — Schema / Config Refinements (OPTIONAL)

- [x] **5.1 Add `dir` recipe to `example.nwp.yml`** — done as 2.7 above.

- [x] **5.2 Sweep per-site `nwp_version_updated` timestamps**
  Verified all 8 sites at `"0.30.0"` (avc, cathnet, cccrdf, dir, dir1, fin, mt, ss).

- [ ] **5.3 `cccrdf/.nwp.yml` field order** — NOT A BUG, SKIP.
  The audit claim was refuted; `yq` is position-agnostic. Leaving the file alone.
  (Listed only so we don't waste time re-debating it.)

---

## 8. Phase 6 — Minor Code Fixes (OPTIONAL)

Only 2 verified bugs in the entire codebase sweep. Both low-impact.

- [x] **6.1 Wire `vrt` into `pl` dispatch**
  Added `vrt)` case in `pl` dispatch.

- [x] **6.2 Wire `fin-monitor` into `pl` dispatch**
  **Decision:** N/A — `fin-monitor.sh` was deleted entirely. `fin/finmonitor` work
  is being extracted from NWP (lives in `sites/fin/`, which is gitignored).

- [ ] **6.3 Decide on `avc-moodle-{setup,status,sync,test}` scripts** *(deferred — depends on AVC-Moodle project timeline)*

---

## 9. Phase 7 — `.gitignore` Cleanup (SHOULD)

Dead whitelist entries point to files/dirs that no longer exist. Not harmful but
confusing for a fresh baseline.

- [x] **7.1 Remove whitelist entries for moved directories** (lines in `.gitignore`)
  - `!email/` (F23: now `servers/nwpcode/email/`)
  - `!email/**`
  - `!linode/` (F23: now `servers/nwpcode/linode/`)
  - `!linode/**`
  - `!git/` (F23: now `servers/nwpcode/git/`)
  - `!git/**`
  - `!vortex/` (directory no longer exists)
  - `!vortex/**`
  - `!url/` (directory no longer exists)
  - `!url/**`
  - `!avcbits/` (directory no longer exists)
  - `!avcbits/**`

- [x] **7.2 Remove whitelist entries for files being deleted**
  - `!podcast.sh` (root symlink removed in commit `e0ff5007`)
  - `!install.sh` (root symlink removed)
  - `!HANDOVER-P50.md` (deleted in 1.1)
  - `!IMPLEMENT-P50.md` (deleted in 1.1)
  - `!IMPLEMENTATION_SUMMARY.md` (moved in 1.2)
  - `!migrate-verification-v2.sh` (deleted in 1.1)
  - `!folder_proposal.md` (file doesn't exist — dead whitelist)
  - `!avc_folder_implementation_plan.md` (file doesn't exist)
  - `!nwp-improvement-proposal.md` (file doesn't exist)
  - `!VERIFY_ENHANCEMENTS.md` (moved in 3.1)

- [x] **7.3 Decide on `.verification.yml` (1 MB file)**
  **Decision:** Keep tracked. The transparency value (showing which commands have
  been verified, real-run vs. syntax-only) outweighs the churn cost. A comment was
  added to `.gitignore` explaining the trade-off.

- [ ] **7.4 Decide on `.verification.yml.backup*` files** *(deferred — not whitelisted, won't be committed; cleanup is cosmetic)*
  Multiple large backup copies: `.verification.yml.backup` (736K),
  `.verification.yml.backup-1768444978` (258K),
  `.verification.yml.backup-before-reset` (427K),
  `.verification.yml.pre-enhance-backup` (123K), `.verification.yml.v1.backup` (49K).
  None are whitelisted so they won't be committed anyway — but they're on disk
  consuming ~1.5 MB. Recommend deleting pre-commit for a cleaner working tree.

---

## 10. Phase 8 — Baseline Commit (BLOCKER)

- [ ] **8.1 Sanity check version strings**
  ```bash
  grep -rn "VERSION=\"" ~/nwp/pl        # should show VERSION="0.30.0"
  grep -rn "nwp_version_updated" ~/nwp/sites/*/.nwp.yml  # all "0.30.0"
  grep "nwp_version_updated" ~/nwp/servers/*/.nwp-server.yml  # "0.30.0"
  ```

- [ ] **8.2 Run the full test suite one last time**
  ```bash
  bats tests/unit/ tests/bats/ tests/integration/
  bash tests/test-yaml-write.sh
  bash tests/test-yaml-remove-duplicate.sh
  bash tests/test-integration.sh
  bash tests/test-podcast.sh
  ```
  All should pass (we confirmed 442/442 last session).

- [ ] **8.3 Delete `.git`**
  ```bash
  rm -rf ~/nwp/.git
  ```

- [ ] **8.4 Re-init**
  ```bash
  git -C ~/nwp init -b main
  ```

- [ ] **8.5 Stage and review**
  ```bash
  git -C ~/nwp add -A
  git -C ~/nwp status --short | wc -l        # expected: ~430-450 files
  git -C ~/nwp status --short | less         # eyeball review
  ```

- [ ] **8.6 Commit**
  ```bash
  git -C ~/nwp commit -m "Initial commit: NWP v0.30.0

  First commit of the reset NWP repository. See CHANGELOG.md and
  docs/reports/milestones.md for the full history of proposals that landed
  before this baseline. F23 (project separation) phases 1-8 and 10 are
  complete; phase 9 and F24 are deferred.
  "
  ```
  **Do not add Claude co-author to the initial commit** — this is a new repo root.

- [ ] **8.7 Tag v0.30.0**
  ```bash
  git -C ~/nwp tag -a v0.30.0 -m "NWP v0.30.0 — fresh repo baseline after F23 cleanup"
  ```

- [ ] **8.8 (Post-commit) Re-add remotes**
  User action. After the upstream is ready at its new location:
  ```bash
  git -C ~/nwp remote add origin <new-upstream-url>
  git -C ~/nwp push -u origin main
  git -C ~/nwp push origin v0.30.0
  ```

---

## 11. Things to Be Aware Of (Surprises & Risks)

### 11.1 Numbering concerns raised by the user

- **"Two P50s"** — ❌ **Not found.** There is exactly one P50. The user may have
  been thinking of the two F23 files, which IS a real issue (see 1.3).
- **Two F23 files** — ✓ **Confirmed.** v1 explicitly superseded by v2. Handled in 1.3.
- **P59 gap** — P58 jumps to P60. Could be intentional skip or could be a deleted
  proposal. Worth a quick check in `git log -- docs/proposals/P59*` before
  deleting `.git`. See 4.4.

### 11.2 Things already tracked that are arguably too big

- `.verification.yml` — **1,016 KB** (1 MB). Biggest single file in the commit. See
  7.3 for the gitignore decision.
- `docs/reports/history.md` — 62 KB. Living doc, probably fine.
- `docs/reference/api/library-functions.md` — 4,519 lines. Consider splitting
  post-baseline.
- `docs/reference/libraries.md` — 1,357 lines. Consider splitting post-baseline.

### 11.3 `sites/` and `servers/` have their own git repos

- The fresh NWP baseline will only commit the `.gitkeep` placeholders under
  `sites/` and `servers/`. Each site with its own repo (`avc`, `ss`, possibly
  `dir`) manages its own history. Each server dir (`servers/nwpcode/`) is its own
  local git repo.
- **Do not** `git add -f sites/avc` or similar — they're intentionally excluded.

### 11.4 Secrets files are already protected

- `.gitignore` lines 135-145 catch `.secrets.yml`, `.secrets.data.yml`, `nwp.yml`,
  `.env.local`, `.ddev/config.local.yaml`, `*.local.yml`. The whitelist-based
  `.gitignore` is belt-and-braces safe. ✓

### 11.5 ADRs missing for F23 and F24

- `docs/decisions/` has ADRs 0001–0016, all dated 2026-01-18 (bulk creation).
- No ADR for F23 project separation (the biggest architectural decision since
  January). **Post-baseline action: write ADR-0017 (F23 project separation) and
  ADR-0018 (F24 unified backups) to capture the decision rationale.**

### 11.6 `docs/plans/` is new and legitimate

- New directory containing `F19-implementation-plan.md`, `mobile-app-analysis.md`,
  `ss-mobile-implementation.md`. These are active planning docs, not stray. Keep.

### 11.7 Renumbering we are NOT doing

- Not renumbering P1–P58, F1–F24. All IDs are stable; changing them would break
  cross-references across milestones, roadmap, changelog, and ADRs.
- The only "renumbering" is archiving F23 v1 (1.3).

### 11.8 Test suite state

- Full suite was 442/442 passing as of the end of the previous session. Re-running
  before commit (8.2) should confirm no regressions introduced by this cleanup.
- `pl verify --run` is blocked on Docker being off — environmental, not a
  regression. That's a separate concern from this proposal.

### 11.9 What's NOT in this proposal but might need attention later

- **Multi-server support.** Everything currently assumes single server
  (`servers/nwpcode/`). F24 will probably force this question.
- **SOPS encryption for `.nwp-server.yml`.** Currently plaintext and gitignored.
  Per the F23 proposal, SOPS integration is slated for a later release.
- **Decentralised contribution governance review.** The
  `docs/governance/distributed-contribution-governance.md` doc is 40K and was last
  touched 2026-01-18. Might need a light refresh post-baseline.

---

## 12. Execution Order

Strict ordering for a clean run:

1. **Phase 1** (all of it) — mechanical cleanup, user decisions where flagged
2. **Phase 2** (items 2.1–2.6) — doc updates; 2.7–2.8 before 5.1
3. **Phase 7** — `.gitignore` cleanup (after Phase 1 deletes files so the
   whitelist entries actually correspond to non-existent files)
4. **Phase 3** (3.1 moves) — docs/ restructuring
5. **Phase 4** (proposal hygiene) — can run in parallel with 3
6. **Phase 5** — config sweeps
7. **Phase 6** — minor bug fixes (can be done any time, or deferred)
8. **Phase 8** — commit

Phases 2, 3, 4, 5, 6 are mostly independent and can be parallelised. Phase 1 must
come first (so Phase 7's ignores match reality). Phase 8 comes last.

---

## 13. Decision Points Requiring User Input

Before I start executing, I need yes/no on these:

| # | Item | Decision needed |
|---|---|---|
| 1.6 | `nwp-solveit-proposal.docx` (no .md companion) | Convert to .md / archive / delete? |
| 1.9 | `SETUP_COMPLETE.md`, `DEPLOYMENT_COMPLETE.md` | Archive to reports/ or delete? |
| 4.4 | P59 gap | Investigate git log for deleted P59 before removing .git, or just document skip? |
| 4.5 | `P52-rename-nwp-to-nwo.md` (rejected) | Keep in proposals/ or archive/? |
| 4.7 | P51 status | I audit it now (file is large but readable in chunks) or skip? |
| 6.3 | `avc-moodle-*` scripts | Wire into pl now or defer until project lands? |
| 7.3 | `.verification.yml` (1 MB) | Gitignore, reset, or commit as-is? |
| 3.2 | Moodle SSO doc consolidation | Do before baseline (heavy writing) or defer post-baseline? |

Phase 3 (everything except 3.1) and most of Phase 5 are fine to defer post-baseline
if you want a faster path to the commit. Phase 1, Phase 2.1-2.6, Phase 4.1-4.2, and
Phase 7 are the **minimum** set for a defensible v0.30.0 baseline.

---

## 14. Minimum Viable Cleanup (Fast Path)

If you want to commit in the next ~90 minutes and defer everything else:

- [ ] Phase 1 items 1.1, 1.2, 1.3, 1.4, 1.5, 1.7 (skip 1.6, 1.8, 1.9 if undecided)
- [ ] Phase 2 items 2.1, 2.2, 2.3, 2.5, 2.6
- [ ] Phase 7 items 7.1, 7.2, 7.3 (gitignore `.verification.yml`)
- [ ] Phase 8 (the commit)

This ships a clean-enough baseline with no broken paths, accurate top-level docs,
no session artefacts, and no stale whitelist. Everything else becomes F26+ work.

---

## 15. Summary

- **Real issues:** ~25 actionable items across 7 cleanup phases.
- **Fake issues** (claimed by audit, refuted on verification): 2 (`fetch-db.sh`,
  `cccrdf` field order).
- **The "two P50s" concern:** not real. The real duplicate is two F23 files.
- **Ready to execute:** yes, pending user decisions on 8 items in §13.
- **Minimum-viable fast path** in §14 gets to a clean commit quickly; everything
  else is deferable.

Once you approve the proposal (or mark which items to skip), I'll work through it
phase-by-phase, confirming completion as I go. Nothing destructive (the `.git`
deletion) happens until Phase 8.
