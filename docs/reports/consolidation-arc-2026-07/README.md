# NWP Consolidation Arc — 2026-07

Execution record for the combined **P0–P4 + consent/legal (ops#117–126)** program.
Plan of record: `~/.claude/plans/compressed-conjuring-parnas.md`.
Design of record (consent): `~/central/CONSENT-AS-FUNCTIONALITY-GATE-AND-TRIALING-PROPOSAL-2026-07-24.md`.
Comparison report that seeded P0–P4: `docs/reports/nwp-vortex-pleasy-comparison-2026-07-23.md`.

## Files
- `decision-log.md` — append-only log of every autonomous decision (what/why/basis/reversible-how).
- `rollback-registry.md` — one row per checkpoint: backup artifact + sha, git commit/bundle, restore command.
- `browse-original/` — preserved original compact `local/browse` page + course-set comparison.

## Standing guardrails (do not cross)
- Autonomous deploys: **test tier only** (`*.nwpcode.org`, disposable Linode, mini). Real member-serving prod = mons/operator-gated.
- **#119 DPO ratification + the single real-member prod wording deploy = human handoff** at the end.
- nwc live/prod deploys are `--code-only` (UID-lock). Sanitizer/auth/consent commits tagged `REVIEW:` for operator eyes.
- ~/nwp code work goes through `pl issue work <N>` worktrees, never committed on `main` directly.

## Rollback
- Whole arc → `git -C ~/nwp checkout arc-baseline` (tool state) + per-site restore rows below.
- Any single checkpoint → its `rollback-registry.md` row.
