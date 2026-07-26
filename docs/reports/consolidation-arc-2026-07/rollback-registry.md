# Consolidation Arc — Rollback Registry

One row per checkpoint. To reverse a checkpoint, run its **Restore** command.

| # | When | Checkpoint | Artifact(s) + sha | Git ref / bundle | Restore command |
|---|------|-----------|-------------------|------------------|-----------------|
| CP0 | 2026-07-24 | arc-baseline (tool state) | — | tag `arc-baseline` @ nwp `bb238a0` | `git -C ~/nwp checkout arc-baseline` |
| CP1 | 2026-07-24 | `local/browse` both versions preserved | `browse-original/{original-compact-from-ss,current-elaborated-from-ssc}/` + `ANALYSIS.md` | — | copy back from `browse-original/` |
| CP2 | 2026-07-24 | ssc loose custom plugins snapshot | `code-snapshots/ssc-custom-plugins-20260724.tar.gz` (sha `6640451d…`) | — | `tar -xzf … -C sites/ssc/dev` |
| CP-nwc | 2026-07-24 | nwc profile code (already safe) | — | `nwp/nwc.git` @ `ab5a40f` branch `deploy/2026-07-21-reconcile`, clean+pushed | `git -C sites/nwc/dev/html/profiles/custom/nwc checkout ab5a40f` |
| CP3 | 2026-07-24 | fresh remote DR snapshots — **verified** | `sites/ss/backups/ss-remote-20260724T180042.*` (74M tar+2.0M sql, sha256 OK) ; `sites/ssc/backups/ssc-remote-20260724T180130.*` (71M tar+2.6M sql, sha256 OK) | — | `pl restore <artifact>` (round-trip automated in P2) |

<!-- append checkpoints below as backups are taken -->
| CP11 | 2026-07-25 | nwd pre-cutover FULL live snapshot (ops#133 cutover) — **verified** | `sites/nwd/backups/nwd-remote-20260725T111425.tar.gz` (89M webroot) + `.sql.gz` (3.8M, sudo-mysqldump — live vendor had no drush) + `sites/nwd/backups/nwd-files-20260725.tar.gz` + `sites/nwd/backups/nwd-private-20260725.tar.gz`, all sha256 OK | — | untar webroot to `/var/www/nwd`, `sudo mysql nwd < dump`, untar files/private |
| CP12 | 2026-07-25 | nwd dev profile 37 uncommitted files (stale `develop`, 275 behind) | `sites/nwd/backups/nwd-dev-profile-pre-cutover-20260725.bundle` (verified, complete history; `.sha256` sidecar written 2026-07-26) + `sites/nwd/backups/nwd-dev-profile-pre-cutover-20260725.list` | local branch `safety/pre-cutover-20260725` in the pre-rebuild checkout (also in the bundle) | `git clone nwd-dev-profile-pre-cutover-20260725.bundle && git checkout safety/pre-cutover-20260725` |
| CP13 | 2026-07-25 | nwd dev DB+files local backup pre parity-rebuild | `sites/nwd/backups/20260725T112057-main-cc03f81b-pre-cutover-dev.{sql.gz,tar.gz,manifest.json}` | — | `pl restore nwd` from that artifact |

## Pre-arc site state (for reference)
- `~/nwp` (tool): branch `main` @ `bb238a0`
- `sites/nwc/dev`: branch `feat/structural-revision-gate`, 11 uncommitted (incl. untracked `html/` profile)
- `sites/ssc/dev`: branch `MOODLE_404_STABLE`, 10 uncommitted (all NWC Moodle plugins untracked)
- Latest pre-arc remote backups: nwc `nwc-remote-20260722T060724`, ssc `ssc-remote-20260722T060940`
| CP4 | 2026-07-24 | ops#68 prod2stg v2-resolve fix — **MERGED** (!139) | — | merge `b705710` on main | `git revert -m 1 b705710` |
| CP5 | 2026-07-24 | ops#124 backup prune (P2 retention, N1 gate) — **MERGED** (!140) | — | merge `627dba0` on main | `git revert -m 1 627dba0` |
| CP6 | 2026-07-24 | ops#127 restic --keep-within (DR ceiling, capability only) — **MERGED** (!141) | — | merge `bbd8ae6` on main | `git revert -m 1 bbd8ae6` (capability inert until `--keep-within` passed on ver) |
| CP7 | 2026-07-24 | ops#126 reversible retire of orphan /var/www/ss | box:/var/www/_retired_ss_20260724 (+ ss-remote-20260724T180042 sha OK) | — | `ssh gitlab@ss.nwpcode.org sudo mv /var/www/_retired_ss_20260724 /var/www/ss` |
| CP8 | 2026-07-24 | ops#127 (1/3) Drupal DR sanitiser --preserve-admin | — | `origin/ops-127` @ `b74e88d` (MR !142, worktree ~/nwp-ops127) | don't merge; `git branch -D ops-127` |
| CP8b | 2026-07-24 | ops#127 COMPLETE (3 parts) | — | `origin/ops-127` @ `cbb5cee` (MR !142) | don't merge; `git branch -D ops-127` |
| CP9 | 2026-07-24n | Plane1 tool-code batch (5 MRs SOLID) | — | branches ops-auto-* @ origin; MRs !143-!147 | don't merge; `git push origin --delete ops-auto-<x>` |
| CP10 | 2026-07-24n | P3 config-drift gate | — | origin/ops-63-config-drift @ 9eaf4c9 | don't merge; off-by-default if merged |
| CP14 | 2026-07-25 | nwd LIVE golden image (ops#133 demo tier) — **verified**, restores the site to its post-seed demo state | `sites/nwd/demo-golden-live/golden.db.sql.gz` + `sites/nwd/demo-golden-live/golden.files.tar.gz` + `sites/nwd/demo-golden-live/golden.manifest.json`; **integrity = the `.sha256` sidecars alongside each artifact** (the row deliberately no longer duplicates the digest — the golden is re-captured periodically and a copied digest goes stale silently; `pl rollback registry check` compares artifact↔sidecar) | — | `pl demo reset nwd --tier=live --force` (verifies both sha256 before and after upload) |
| CP15 | 2026-07-25 | nwd vhost — repo copy corrected php8.2→8.3 to match the box | `servers/nwpcode/nginx/conf.d/nwd.conf` @ branch `feat/demo-live-tier`; live copy unchanged throughout (box mtime Jul-24 21:49) | box `/etc/nginx/conf.d/nwd.conf` (untouched — **no .bak needed, no edit was made**) | `git checkout HEAD~1 -- servers/nwpcode/nginx/conf.d/nwd.conf` (repo-only; the box was never modified) |
| CP16 | 2026-07-26 | Art.9 pre-deploy remote snapshots (nwc + ssc) — **verified** | `sites/nwc/backups/nwc-remote-20260726T093907.{tar.gz,sql.gz}` (146M + 8.1M) ; `sites/ssc/backups/ssc-remote-20260726T094256.{tar.gz,sql.gz}` (74M + 2.6M) — all four sha256 OK, `.manifest.json` alongside | — | `pl restore <site>` from that artifact |
| CP17 | 2026-07-26 | ssc `mod/depthcontent` dev tree, pre-AMD-rebuild | `docs/reports/consolidation-arc-2026-07/code-snapshots/ssc-dev-depthcontent-prebuild-20260726.tar.gz` (sha `8d9e89d1…`) | — | `tar -xzf … -C sites/ssc/dev` |
| CP18 | 2026-07-26 | **live ssc `mod/depthcontent` immediately before the Art.9 gate deploy** (v2026072002, UNGATED) | box `/var/backups/ssc-depthcontent-pre-art9-20260726.tar.gz` (sha `65fff770…`, 74 KB) | — | `ssh gitlab@97.107.137.88 "sudo tar -xzf /var/backups/ssc-depthcontent-pre-art9-20260726.tar.gz -C /var/www/ssc"` then `sudo -u www-data php8.2 -d max_input_vars=5000 /var/www/ssc/admin/cli/upgrade.php --non-interactive` |
| CP19 | 2026-07-26 | item 2 recovery-path-repair — rollback dispatch table + state-dir ledger + `pl restore --remote` + registry checker | — | — | `git revert -m 1 <merge>`; legacy per-checkout `.rollback` dirs were never modified, so reverting loses no recovery point |
| CP20 | 2026-07-26 | leakage-gate un-blinded (fix-programme item 6) — config-only, no live site or server touched | — | branch `fix/leakage-gate-scope` off main; `.gitleaks.toml`, `.gitleaksignore`, `NOTICE`, `docs/CC0_DEDICATION.md`, `tests/unit/test-leakage-gate.bats` | `git revert -m 1 <merge>` — restores the previous (blind) gate exactly; no state migration, nothing deployed. To keep the rules but quieten CI, add fingerprints to `.gitleaksignore` (3-part form only) — **never** re-widen a `[allowlist] paths` entry. |
| CP-I4 | 2026-07-26 | Item 4 `pl-surfaces-report-reality` — oversight-surface fixes (no live site or server touched; the only behavioural change off the dev box is that the nightly `pl backup sweep` cron now exits 1 while any site has never been backed up) | — | branch `fix/pl-surfaces-report-reality` (MR pending) | `git revert -m 1 <merge>`; all changes are checks + new read-only verbs. Sweep exit code: revert restores exit 0. No state migration, no files written outside the repo. |
