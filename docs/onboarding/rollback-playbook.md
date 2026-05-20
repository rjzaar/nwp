# Rollback Playbook

**Audience:** Coder, when something has gone wrong post-merge.
**Status:** v1 — 2026-05-20.
**Read time:** 8 minutes. **Refer to during incidents.**

**You do not need permission to roll back.** If a live site is broken or behaving badly after a deploy, restore the last good state first, then we sort out cause-and-effect. The cost of rolling back unnecessarily is a few minutes of churn; the cost of leaving a broken site up is real users seeing real broken pages.

If you only remember three things:

1. **Pause the loop first** (`touch /home/rob/nwp/.loop-paused` on mini). Stops new PRs while you investigate.
2. **`pl rollback execute nwc prod`** (and the same for `nwd`) restores the last snapshot. Always works because every `stg2live` takes a snapshot. Use `pl rollback list` to see available restore points first.
3. **Write what happened** in the relevant PR comment + post in Slack. Don't silently roll back — someone needs to know.

---

## 1. Symptom → action map

| Symptom                                                | First action                                                         |
|--------------------------------------------------------|----------------------------------------------------------------------|
| Live site returns 5xx                                  | [Pause loop + rollback](#full-rollback-procedure)                    |
| Live site returns 200 but renders an error page        | [Pause loop + rollback](#full-rollback-procedure)                    |
| Smoke check failed (auto-rollback already ran)         | [Confirm rollback succeeded](#confirming-an-auto-rollback)           |
| Site OK but a specific page is broken                  | [Targeted revert](#targeted-revert)                                  |
| OAuth or cross-site bridge down                        | [Pause loop + page Rob](#paging-rob)                                 |
| You're not sure if it's broken                         | [Run the smoke check manually](#running-the-smoke-check-manually)    |
| Agent loop seems to be making bad PRs                  | [Pause loop](#pausing-the-agent-loop)                                |

---

## 2. Pausing the agent loop

The loop reads `/home/rob/nwp/.loop-paused` before every run. If that file exists, the loop logs "paused" and exits.

```bash
ssh mini
touch /home/rob/nwp/.loop-paused
```

That's it. Within 30 minutes (the cron interval), all spawned-Claude-Code processes complete or time out; no new ones start. To resume:

```bash
ssh mini
rm /home/rob/nwp/.loop-paused
```

**Do this freely.** Pausing the loop is a no-op for the live site. The downside is just that pending issues sit in GitLab a bit longer.

---

## 3. Full rollback procedure

The standard "we shipped something bad" recovery.

```bash
# 1. SSH to the deploy host
ssh mini

# 2. Pause the loop so no new PRs land while you fix this
touch /home/rob/nwp/.loop-paused

# 3. List available rollback points (optional but recommended)
pl rollback list nwc   # show snapshot timestamps available for nwc
pl rollback list nwd   # ditto for nwd

# 4. Roll back the affected profile(s)
pl rollback execute nwc prod   # restore last snapshot for nwc.nwpcode.org
pl rollback execute nwd prod   # restore last snapshot for nwd.nwpcode.org

# 5. Verify the rollback succeeded
pl rollback verify nwc
pl rollback verify nwd

# 6. Confirm: hit the smoke URLs
curl -sI https://nwc.nwpcode.org/ | head -1     # expect 200
curl -sI https://nwd.nwpcode.org/ | head -1     # expect 200
curl -s  https://nwc.nwpcode.org/ | grep -i "narrow way"

# 7. Comment on the offending PR (via GitLab UI or `gh pr comment` if you have the gh CLI configured for git.nwpcode.org)
# Example body: "Rolled back live at $(date -u +%Y-%m-%dT%H:%M:%SZ) — <reason>. Site restored to <previous-sha>."

# 8. Tell Rob (Slack / WhatsApp / whatever you've agreed)
```

After step 8: investigate. The agent's PR description has its rollback plan; if the actual rollback differed, that's a finding to flag.

`pl rollback` restores:
- The MariaDB database (from the mysqldump snapshot taken at the previous `stg2live`)
- The nginx site configs (in case the PR touched them)
- The codebase (git reset to the previous SHA)

It does **not** restore Open Social config exported via CMI. If the PR was a CMI change that went bad, `pl rollback` brings back the code that imports the *old* config, but you may need to run `drush cim` to actually apply it. The audit log notes when CMI is involved.

---

## 4. Confirming an auto-rollback

If you see `SMOKE-FAILED` in the deploy log, the pipeline has *already* rolled back. Confirm:

```bash
ssh mini
tail -50 ~/nwp/logs/deploy.log | grep -E "SMOKE|ROLLBACK|ROLLED-BACK"
curl -sI https://nwc.nwpcode.org/ | head -1     # expect 200
```

If both checks are clean, you don't need to do anything — but you should still:
- Comment on the auto-rolled-back PR ("smoke failed, auto-reverted to <SHA>") so the agent's next pass knows the diff didn't land.
- Re-classify the issue as `needs-human` in GitLab so the loop doesn't re-attempt it identically.

---

## 5. Targeted revert (one bad commit on an otherwise OK site)

If the live site is mostly OK but a single recent commit is causing a specific problem (broken page, busted button, etc), prefer a targeted revert over a full rollback:

```bash
# On your laptop or mini
cd ~/nwp/sites/nwc/dev
git checkout main
git pull
git revert <bad-sha> --no-edit
git push origin main

# This will re-trigger the deploy pipeline naturally via the next push hook.
# Watch the deploy log on mini to confirm dev2stg2live ran clean.
```

Targeted revert keeps every other recent change in place. Use this when:
- The bad commit is **after** a bunch of good commits you don't want to lose,
- The change is a clean revert (no schema migration, no auth, no CMI),
- The PR's "Rollback plan" said `git revert <sha>` (always check the original PR's plan before improvising).

---

## 6. Running the smoke check manually

If you suspect something's off but aren't sure:

```bash
ssh mini
~/nwp/scripts/agent-loop/smoke-live.sh nwc
~/nwp/scripts/agent-loop/smoke-live.sh nwd
~/nwp/scripts/agent-loop/smoke-live.sh ssc
~/nwp/scripts/agent-loop/smoke-live.sh ssd
```

Each prints `OK` or `FAIL: <url> <status-or-string>`. Any FAIL is grounds for rollback.

---

## 7. Manually triggering a deploy

Sometimes a merge happens but the webhook misses (mini was rebooting, network blip, etc). The deploy doesn't run; the live site lags behind main. To force it:

```bash
ssh mini

# Replace <repo> with the merged-into repo (e.g. nwp/nwc) and <sha> with the merge commit.
~/nwp/scripts/agent-loop/deploy-on-merge.sh nwp/nwc <sha> --tier T2
```

The tier flag matters — it decides whether the script auto-promotes to live (T1/T2) or stops at stg (T3). If you don't know, use **T3** to be safe (forces manual promotion).

---

## 8. Paging Rob

Page Rob if:
- Two consecutive rollbacks happen in <1 hour.
- Auth (OAuth) is broken — members can't log in.
- A cross-site bridge (feedback ingest, copyright sync) is broken on production.
- A T3 PR's stg manual review surfaces something you're not sure about.
- The agent loop is making PRs that consistently get rejected — there's an upstream bug.
- You can't reach mini (SSH timing out).

Reach him by: WhatsApp / Slack DM / phone. He has accepted that "two consecutive rollbacks" is a wake-him-up event.

If he's unreachable: pause the loop, roll back to a known good, and leave the site up in that state. Don't experiment.

---

## 9. After-action: what to write down

For any rollback, append to `~/nwp/logs/incidents.log` on mini (one-liner per incident is fine):

```
2026-05-20T14:32Z  PR #87 (T2)  smoke-failed at /dashboard  auto-rolled-back to 7a3c2f1   coder/rob
```

Format: `<UTC timestamp>  <PR-or-trigger>  <symptom>  <action>  <who-noticed>`.

This file is the audit trail. Every Friday Rob reviews it.

---

## 10. What NOT to do

- **Don't `git push --force` to main.** Even to "fix" a bad merge. The deploy pipeline takes snapshots from main; force-pushing breaks the rollback chain.
- **Don't manually edit the live DB or files.** Always go through `pl rollback` or a revert PR. Manual edits leave the audit log inconsistent.
- **Don't bypass the smoke check.** If `SMOKE-FAILED`, the rollback happened for a reason; don't manually re-promote without understanding why it failed first.
- **Don't keep approving on a red branch.** If a PR is red, fix or pause; don't stack more PRs on top.
- **Don't delete the snapshots.** They live under `/var/backups/nwc-snapshots/` on the live host. Each snapshot is ~2GB; we keep the last 14 days. Cron prunes the older ones.

---

## See also

- [deploy-pipeline.md](./deploy-pipeline.md) — what triggers the deploys you're rolling back
- [pr-review-checklist.md](./pr-review-checklist.md) — what should have caught this earlier
- [agent-loop-primer.md](./agent-loop-primer.md#pausing-and-resuming-the-loop) — pause/resume semantics
- [glossary.md](./glossary.md#deploy-terms) — snapshot, pl rollback, CMI, etc.
