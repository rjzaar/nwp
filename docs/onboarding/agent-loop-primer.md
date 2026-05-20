# Agent Loop Primer

**Audience:** Coder, understanding the machine that produces the PRs you review.
**Status:** v1 — 2026-05-20.
**Read time:** 12 minutes.

The PRs you review are produced by a closed loop running on `mini` (one of Rob's home boxes). This doc explains the loop end-to-end so you can recognize when it's misbehaving and decide what to do about it.

If you only remember three things:

1. **The loop spawns headless Claude Code, not the Anthropic API.** It's the same `claude` binary you use, with `-p '<task>' --dangerously-skip-permissions`.
2. **Issues flow from real user feedback** — the widget on nwc.nwpcode.org → `feedback` entity → GitLab issue with tier label → loop picks it up.
3. **The kill switch is a single file.** `touch /home/rob/nwp/.loop-paused` on mini. Loop stops within 30 minutes. See [rollback-playbook.md §2](./rollback-playbook.md#2-pausing-the-agent-loop).

---

## 1. End-to-end flow

```
[ User on nwc.nwpcode.org clicks "Send feedback" widget ]
                       │
                       ▼
   POST /api/feedback/log   (or cross-site POST from Moodle)
                       │
                       ▼
       feedback entity created on nwc.nwpcode.org
                       │
                       │   (cron, every 15 min)
                       ▼
        drush nwc-feedback:sync-to-gitlab
                       │
                       │   classifies tier (A1–E3 → T1/T2/T3)
                       │   chooses target repo (usually nwp/nwc)
                       │   composes issue body
                       ▼
   GitLab issue created on git.nwpcode.org/nwp/nwc
            with labels: agent-eligible, T<n>
                       │
                       │   (cron, every 30 min)
                       ▼
              agent-loop.sh runs
                       │
                       │   polls GitLab for agent-eligible + no-MR issues
                       │   picks one, creates fresh worktree on fix/issue-N
                       ▼
   claude -p '<issue-body + repo context>' --dangerously-skip-permissions
                       │
                       │   Claude Code reads repo, writes code,
                       │   runs Behat + PHPUnit locally,
                       │   pushes branch, opens MR
                       ▼
            MR opened on nwp/nwc by service account
              with structured PR description (9 sections)
                       │
                       ▼
         *** YOU REVIEW (or request changes) ***
                       │
                       ▼  on approve
              MR auto-merges to main
                       │
                       │   webhook → gitlab-webhook-receiver.py
                       ▼
              deploy-on-merge.sh runs
              dev → stg → tier-gate → live → smoke
                       │
                       ▼
           governance_action entries written
              for each deploy stage
```

The whole loop, from user feedback to live deploy, takes between 20 minutes (T1, no review queue) and a few days (T3, manual stg verification).

---

## 2. The components

All on `mini`. All in `~/nwp/scripts/agent-loop/`.

| Component                       | What it does                                                         | Triggered by                          |
|---------------------------------|----------------------------------------------------------------------|---------------------------------------|
| `agent-loop.sh`                 | Polls GitLab, picks an issue, spawns Claude Code, opens MR           | Cron every 30 minutes                 |
| `nwc_feedback` sync drush cmd   | Reads `feedback` entities, posts to GitLab as issues                 | Cron every 15 minutes                 |
| `gitlab-webhook-receiver.py`    | HTTP server on 127.0.0.1:5099, listens for MR-merged webhooks        | GitLab webhook (when an MR merges)    |
| `deploy-on-merge.sh`            | Runs the full deploy pipeline (dev → stg → tier-gate → live → smoke) | Webhook receiver fork                 |
| `smoke-live.sh`                 | Runs the 5-URL smoke check post-deploy                               | Called by deploy-on-merge.sh          |
| `.agent-loop.state.json`        | Tracks per-issue retry counts, daily PR count, last-poll timestamp   | Read/written by agent-loop.sh         |
| `.loop-paused`                  | Kill switch. If present, agent-loop.sh exits early.                  | Manually touched/removed              |

---

## 3. What Claude Code is told

When the loop spawns Claude on issue #N, it passes a structured prompt approximately like this:

```
You are Claude Code running headless inside the nwp/nwc repository.
Your task is to resolve GitLab issue #<N> at:
  https://git.nwpcode.org/nwp/nwc/-/issues/<N>

Issue title: <title>
Issue body: <body, including user feedback verbatim>

Repository context:
- This is the Drupal install profile at profiles/custom/nwc/
- Custom modules under modules/nwc_features/
- Tests must pass: ddev exec "vendor/bin/behat --config=behat.yml.dist --suite=nwc_editorial"
                   ddev exec "vendor/bin/phpunit --bootstrap=html/core/tests/bootstrap.php --no-configuration profiles/custom/nwc/modules/nwc_features/<module>/tests/src/Kernel/"

Your worktree: <path>
Branch (already created, you're on it): fix/issue-<N>

Constraints:
- Do not modify code outside profiles/custom/nwc/ unless the issue explicitly requires it.
- Do not commit vendor/, .env, auth.json, html/core/, or any install artifacts.
- Behat + PHPUnit must be green BEFORE you push.
- The MR description MUST follow the 9-section template in
  docs/onboarding/pr-review-checklist.md §1.
- Self-classify the tier (T1, T2, or T3) honestly.

When done, push the branch and open an MR via the gh CLI.
```

The agent reads the repo, makes the change, runs the tests, pushes, opens the MR. If anything fails, the loop catches the non-zero exit, marks the issue with `agent-failed-<N>` label, and increments the retry counter.

---

## 4. Caps and limits

These guards stop the loop from blowing up if something goes wrong:

| Limit                                 | Default | Override env var                | What it prevents                                          |
|---------------------------------------|---------|---------------------------------|-----------------------------------------------------------|
| Daily PR cap                          | 5       | `AGENT_LOOP_DAILY_CAP`          | Loop opening dozens of MRs in a runaway                   |
| Per-run PR cap                        | 1       | `AGENT_LOOP_MAX_PER_RUN`        | Loop opening multiple MRs on a single tick                |
| Per-issue retry cap                   | 3       | (hardcoded; ask Rob to change)  | Same broken issue spawning Claude indefinitely            |
| Issue age cap (days)                  | 30      | `AGENT_LOOP_MAX_AGE_DAYS`       | Ancient issues that nobody triaged getting auto-worked    |
| Headless Claude wallclock per spawn   | 25 min  | `CLAUDE_TIMEOUT_SECONDS`        | A stuck Claude session running until the heat death       |
| `gitlab-webhook-receiver.py` body cap | 1 MB    | (hardcoded)                     | Memory exhaustion from a malformed webhook                |

After 3 retries on the same issue, the loop labels it `needs-human` and stops trying. You'll see this — and it usually means the issue is design-shaped, not coding-shaped. Pause and ping Rob.

---

## 5. Pausing and resuming the loop

```bash
# Pause
ssh mini
touch /home/rob/nwp/.loop-paused

# Resume
ssh mini
rm /home/rob/nwp/.loop-paused
```

The loop checks for `.loop-paused` at the very top of each cron tick. If present, it logs `paused — skipping run` and exits 0. No new spawns, no new MRs.

**Sessions that are already mid-spawn finish naturally.** They might still push an MR after you pause. That's fine — the MR is still subject to your review.

Resume by deleting the file. Within 30 minutes, the next cron tick picks up where it left off.

---

## 6. When the loop is misbehaving

Patterns that mean "pause the loop and call Rob":

- **Same issue keeps getting picked up after you `needs-human`-label it.** Either the label isn't being read (bug) or the loop's state file is stale.
- **PRs are arriving with empty diffs or only test file changes.** Means Claude is "fixing" by adjusting tests, not code.
- **PR descriptions are missing sections.** The template's broken or the agent is being prompted differently than expected.
- **Two PRs for the same issue.** Race condition between cron ticks; the second one usually has the wrong context.
- **PR opened on a repo not in the allowlist.** Should never happen — the receiver enforces a hardcoded list. If you see it, something is very wrong.

Patterns that are *normal* and don't require pausing:

- A PR gets rejected and the agent makes another attempt 30 minutes later. (Expected; that's the loop working.)
- An issue sits in the queue for hours. (Expected during high-PR days; daily cap throttles intentionally.)
- Smoke check fails and auto-rolls-back. (Expected; the safety mechanism worked.)

---

## 7. Where Rob is the source of truth

You don't need to know the internals of the agent loop to review PRs. If you find yourself wondering "why did the loop do X?" — ask Rob. He maintains:

- The `agent-loop.sh` script itself
- The prompt template the loop uses
- The webhook receiver and its allowlist
- The deploy pipeline scripts
- The gitleaks config

Your job is to be the human gate on outputs. Rob's job is to keep the loop healthy.

---

## 8. Reading the loop logs (optional)

If you want to look at what the loop is doing:

```bash
ssh mini

# What runs are happening
tail -100 ~/nwp/logs/agent-loop.log

# Detail of a specific Claude Code spawn
ls ~/nwp/logs/claude-runs/
cat ~/nwp/logs/claude-runs/issue-<N>/transcript.log

# Webhook receiver activity
tail -50 ~/nwp/logs/gitlab-webhook.log

# Deploy pipeline (per merge)
tail -200 ~/nwp/logs/deploy.log
```

The transcripts can be huge (Claude is verbose). They're rotated weekly; if you need an older one, ask Rob.

---

## See also

- [pr-review-checklist.md](./pr-review-checklist.md) — what to do with the PRs the loop produces
- [deploy-pipeline.md](./deploy-pipeline.md) — what happens after you approve
- [rollback-playbook.md](./rollback-playbook.md) — when something goes wrong
- [repo-map.md](./repo-map.md) — where the loop's source lives
