# PR Review Checklist

**Audience:** Coder, reviewing every Pull Request the NWC agent loop opens.
**Use:** Work through this top-to-bottom on each PR before clicking Approve.

This is the mechanical checklist. The [intro guide](./coder-intro.md) explains the philosophy; this doc is what you actually do per PR.

---

## Quick rules

- **Approve only what you'd ship yourself.** "Agent passed CI" is necessary, not sufficient.
- **When in doubt, request changes.** The agent is cheap; getting a bad change live is expensive.
- **If something feels off:** [pause the loop](./rollback-playbook.md#pausing-the-agent-loop) and ping Rob. Better to stop the line than ship junk.

---

## The checklist

### 1. PR description (30 seconds)

Every agent-generated PR description must have these sections. If any is missing or vacuous, **request changes** asking the agent to fill it in:

- [ ] **Issue ref** — links to the GitLab issue it's solving.
- [ ] **Tier** — explicitly `T1`, `T2`, or `T3`. Determines auto-deploy behaviour after merge.
- [ ] **What changed** — one-paragraph summary of the actual code change.
- [ ] **Why** — the failure mode being fixed, in user terms.
- [ ] **Files changed** — bullet list with a one-line "why this file".
- [ ] **Tests added/modified** — names + what they cover.
- [ ] **Test results** — Behat + PHPUnit pass/fail counts.
- [ ] **Rollback plan** — `git revert <sha>` is fine if it's truly a clean revert; if not, agent must spell out the manual steps.
- [ ] **Self-flags** — `⚠ touches auth`, `⚠ schema migration`, `⚠ ADR change`, etc. Missing flags = re-classify yourself.

### 2. Diff sanity (1-5 minutes depending on tier)

- [ ] Diff size matches description. A "fix typo" PR with 500 lines of diff is suspicious.
- [ ] Files changed match description. Unexpected files = request changes + ask why.
- [ ] No `vendor/`, `html/core/`, or other install-artifact paths in the diff.
- [ ] No `.env`, `auth.json`, `settings.local.php`, `.secrets.yml`. **If you see one, do NOT approve — pause the loop immediately.**
- [ ] No hardcoded passwords, tokens, or API keys (`glpat-*`, `ghp_*`, raw bcrypt strings). Same severity as the previous item.
- [ ] Comments are sparse + meaningful (or absent). Verbose comments are an agent tell; check the code carefully if the comments outnumber the code.

### 3. Test coverage (per tier)

| Tier | What you need to see |
|------|----------------------|
| **T1** (typo, doc fix, dep patch) | Existing Behat + PHPUnit still green. No new tests required if change is purely cosmetic. |
| **T2** (bug fix, small feature) | A new test that **fails before the fix** and **passes after**. Agent must show both states in PR description, OR the new test must be paired with a fixed-issue link. |
| **T3** (architectural, schema migration) | New tests + updated existing tests + an ADR draft (see ADRs at `~/nwp/sites/nwc/dev/html/profiles/custom/nwc/docs/decisions/`). |

For each new test:
- [ ] Does it test the change, or does it just exercise unrelated code?
- [ ] Does the test name describe a behaviour, not an implementation detail? (`testReviewerRequestsRevisionReturnsToDraft` not `testFooBar`.)
- [ ] If you removed the production code change but kept the test, would the test still pass? **If yes, the test doesn't test the change — request changes.**

### 4. Tests pass (must)

- [ ] CI green on the MR. Don't trust "agent says they passed" — verify in the GitLab UI.
- [ ] If you want to re-run locally:
  ```bash
  cd ~/nwp/sites/nwc/dev
  # Latest main + the PR branch
  git fetch origin
  git checkout <pr-branch>
  ddev exec "vendor/bin/behat --config=behat.yml.dist --suite=nwc_editorial"
  ddev exec "cd /var/www/html && vendor/bin/phpunit --bootstrap=/var/www/html/html/core/tests/bootstrap.php --no-configuration /var/www/html/html/profiles/custom/nwc/modules/nwc_features/nwc_editorial/tests/src/Kernel/"
  ```

### 5. Special checks for T2

In addition to the above:

- [ ] Does the change affect user-visible behaviour? Pull up the dev site (`https://nwc-dev.ddev.site/`) and **manually exercise the changed path**. Don't skip this.
- [ ] Does it interact with the editorial state machine ([architecture-brief §editorial-pipeline](./architecture-brief.md#editorial-pipeline))? Watch for changes that bypass the state transitions.
- [ ] Does it interact with the Decision Log visibility tiers (ADR-0010)? Stewards-tier content must never become member-visible by accident.
- [ ] Does it touch the `field_content_visibility` default? Open Social content access depends on this — wrong default = either site goes 403 or leaks.

### 6. Special checks for T3

T2 checks PLUS:

- [ ] Is there an ADR draft? If not, the change probably shouldn't be made by an agent at all — push back hard.
- [ ] Schema migration? Make sure the agent included an upgrade hook (`hook_update_N`) AND a downgrade story (if not, request the downgrade story).
- [ ] Auth/secrets touched? **Manual review with Rob mandatory.** Do not approve without him.
- [ ] Multi-site impact? Changes that affect both `nwc` and `nwd` profiles need to be verified to actually deploy cleanly to both.
- [ ] Cross-site impact? Changes to `nwc_feedback` cross-site receiver or `nwc_copyright` Moodle sync MUST be reviewed against the paired SS sites too.

### 7. The "agent smells"

Patterns that should make you suspicious of an AI-generated PR. Any single smell ≠ blocker, but **three or more = request changes**:

- **Over-commenting**: `// loop through items` above a `foreach`. Agent comments restate the code instead of explaining intent.
- **Test was always going to pass**: the new test doesn't actually verify the bug is fixed; it just exercises a different code path.
- **"Improved" code paths unrelated to the issue**: if the diff includes refactors of functions the issue didn't mention, the agent is changing scope on you.
- **New abstractions for one-time use**: agent extracts a helper class/function used by exactly one caller. Push back.
- **Defensive code where none is needed**: `if (isset($x))` guards on values the function literally just received as a typed parameter. Bloat without purpose.
- **String comparison of types/classes**: `if (get_class($x) === 'Foo\\Bar')` instead of `$x instanceof Bar`.
- **Catching exceptions that can't happen** or swallowing exceptions that should propagate.
- **Markdown/docs changes mixed with code changes** that weren't asked for. Should be a separate PR.
- **`@author` or `@version` tags added**. Drupal core has stripped these for years.
- **TODO comments left in the diff**. Agent must finish the work, not leave breadcrumbs.

### 8. Approve / Request changes

If everything above is green:

```
✓ Approve via GitLab UI
✓ Add comment: "LGTM — <tier>; <one-line note if relevant>"
```

If not:

```
✗ Request Changes via GitLab UI
✓ Comment specifically what's wrong. The agent reads your comments.
```

After approval, the loop auto-merges + auto-deploys per tier:
- **T1/T2** → `pl dev2stg nwc` → tests → `pl stg2live nwc` → smoke. See [deploy-pipeline.md](./deploy-pipeline.md).
- **T3** → stops at `stg`. Manual `pl stg2live nwc` by you or Rob.

If a smoke check fails post-deploy: see [rollback-playbook.md](./rollback-playbook.md). **You can roll back without asking permission.**

---

## Skim version (for the dozenth PR of the day)

1. Description has all 9 sections? ✓
2. Diff size matches description? ✓
3. No secrets, no installed artifacts in the diff? ✓
4. CI green? ✓
5. Test actually tests the change? ✓
6. T2: did I manually exercise the changed path? ✓
7. T3: ADR? auth flags? Rob agrees?
8. Any 3+ smells? → request changes

If all green: approve. Sub-10-minute turnaround for T1, 15-20 for T2, longer for T3.

---

## Worked example: a real T1 PR

Issue: feedback #4 says "Typo on /about — 'amened' should be 'amended'."

Agent opens PR `fix/issue-4` with description:

> **Issue:** [#4](https://git.nwpcode.org/nwp/nwc/-/issues/4)
> **Tier:** T1
> **What changed:** Replaced "amened" with "amended" in the body of the About page seed node (nwc.profile, lines 312-314).
> **Why:** Source feedback (B1 typo class) reported the misspelling on https://nwc.nwpcode.org/about §1.
> **Files changed:**
> - `nwc.profile` — corrected the source text used by the polish-seeder.
> - `tests/src/Behat/feedback_pipeline.feature` — new scenario verifies the about page renders "amended" not "amened".
> **Tests added:** `feedback_pipeline.feature` `Scenario: About page reflects latest typo fix`.
> **Tests results:** Behat 7/7 pass (was 6/6; new scenario added).
> **Rollback plan:** `git revert <sha>`; affects no schema; no migration.
> **Self-flags:** none.

Review:
- All 9 sections present. ✓
- Diff is 4 lines changed, 12 lines added (the new Behat scenario). Size matches description. ✓
- No secrets, no installed artifacts. ✓
- CI green (6→7 Behat scenarios). ✓
- Test removes the fix → test fails (mentally check; or `git stash` the fix locally and re-run). ✓
- T1 doesn't need manual exercise.
- No smells.

Approve. Add comment "LGTM — T1; clean typo fix." Loop merges and deploys.

Total elapsed: ~3 minutes.

---

## Worked example: a PR you should reject

Issue: feedback #99 says "the search is bad."

Agent opens PR with description:

> **Issue:** [#99](...)
> **Tier:** T2
> **What changed:** Refactored `nwc_editorial.search` to use a new ScoreBoostService that weights newer revisions higher. Added a SearchPreferences user setting. Added 800 lines.

**Reject immediately.** Why:
- The issue is design-shaped, not coding-shaped. Should have been "needs human author" not T2.
- 800 lines for "the search is bad" is scope explosion.
- New user-facing setting added without an ADR.
- New service added without discussion.
- This is the **scope creep smell** in concentrated form.

Comment:
> Closing without merge. This issue is design-shaped — "the search is bad" doesn't define what's wrong or what better looks like. Pausing the issue; @rob can decide on a focused fix or a design discussion.

Then: re-classify the GitLab issue from `agent-eligible` to `needs-human` so the loop won't pick it up again.

---

## See also

- [intro guide](./coder-intro.md) — the welcome + philosophy
- [agent-loop-primer.md](./agent-loop-primer.md) — what produces these PRs in the first place
- [testing.md](./testing.md) — how to run + interpret the test suites
- [rollback-playbook.md](./rollback-playbook.md) — when something goes wrong post-merge
