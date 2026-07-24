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
