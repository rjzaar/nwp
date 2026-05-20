# Onboarding — Coder (PR reviewer for NWC)

**Status:** v1 — 2026-05-20.
**Read order for a new reviewer:** top to bottom. Each doc links to the others; this README is the index you should bookmark.

The role: an autonomous agent loop generates Pull Requests against the NWC codebase from real user feedback. You read every one of those PRs, approve or push back, and (when something goes wrong) roll back cleanly.

## Start here

1. **[coder-intro.md](./coder-intro.md)** — the welcome + philosophy. Read this first. 20 minutes.
2. **[pr-review-checklist.md](./pr-review-checklist.md)** — the mechanical per-PR checklist. Use this on every PR. 10 minutes.

## Reference (when you need it)

3. **[architecture-brief.md](./architecture-brief.md)** — what NWC is, condensed. 15 minutes.
4. **[testing.md](./testing.md)** — Behat + PHPUnit; how to read a test diff. 10 minutes.
5. **[deploy-pipeline.md](./deploy-pipeline.md)** — what happens after you approve. 10 minutes.
6. **[rollback-playbook.md](./rollback-playbook.md)** — when something goes wrong post-merge. **Refer to during incidents.**
7. **[repo-map.md](./repo-map.md)** — where each repo lives and what's in it. 6 minutes.
8. **[glossary.md](./glossary.md)** — Sojourner, Steward, T1/T2/T3, `pl`, etc. Look up as needed.
9. **[agent-loop-primer.md](./agent-loop-primer.md)** — how the PR-generating loop works. 12 minutes.
10. **[adrs.md](./adrs.md)** — the architecture decisions that constrain new code. Look up as needed.

## The three rules

Three things to internalize before you start approving:

1. **You review every PR.** Trivial-looking changes get the same eyeballs as scary ones. The agent has been wrong about its own changes before; your job is to catch that.
2. **Tier labels (T1 / T2 / T3) are about *attention budget*, not about *whether you read it*.** T1 = read in 2 minutes; T3 = read in 30 minutes. Both get read.
3. **When in doubt, request changes or pause the loop.** `touch /home/rob/nwp/.loop-paused` on mini idles the loop until you unpause it. Nothing bad happens by waiting.

## First-day checklist

When you start, before approving any PR:

- [ ] Read [coder-intro.md](./coder-intro.md) cover to cover.
- [ ] Skim [pr-review-checklist.md](./pr-review-checklist.md); bookmark it.
- [ ] Read [architecture-brief.md §3](./architecture-brief.md#3-the-custom-module-landscape) so you know what `nwc_editorial`, `nwc_governance`, etc. mean.
- [ ] Read [rollback-playbook.md §1–§3](./rollback-playbook.md). Memorize the kill switch.
- [ ] Confirm your GitLab account has Reviewer access on `nwp/nwc`, `nwp/nwc-project`, `nwp/nwd-project`, `nwp/local-nwc-copyright-sync`, `nwp/auth-nwc-oauth2`, `nwp/nwp`. (If not, ping Rob.)
- [ ] Confirm SSH access to `mini` (for rollbacks). (If not, ping Rob.)
- [ ] Skim one merged PR top-to-bottom using [pr-review-checklist.md](./pr-review-checklist.md) — practice run, no approve needed.

After that you're ready to review live.

## When to ping Rob

You **don't** need to ping Rob to:
- Approve a PR you're confident in.
- Request changes on a PR.
- Pause the agent loop.
- Roll back a bad deploy.
- Re-label an issue from `agent-eligible` to `needs-human`.

You **should** ping Rob for:
- T3 PRs touching auth, schema migrations, or multi-site infrastructure.
- Two consecutive rollbacks in <1 hour.
- An auth or cross-site bridge being broken on production.
- A PR that smells wrong but you can't articulate why.
- Anything the loop is doing that doesn't match these docs.

See [rollback-playbook.md §8](./rollback-playbook.md#8-paging-rob) for contact methods and escalation thresholds.

## Document maintenance

These docs are versioned in `nwp/nwp` under `docs/onboarding/`. Updates land via normal PR (against the `nwp/nwp` repo) with your review. When something in the system changes (new ADR, new tier rule, new smoke check URL, etc.), the corresponding doc should change in the same PR.

If a doc gets out of date and you don't have time to fix it, leave a note in the relevant section like `<!-- TODO 2026-MM-DD: drift from current behavior, see PR #N -->` and ping Rob.

---

Welcome aboard.
