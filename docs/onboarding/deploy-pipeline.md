# Deploy Pipeline — what happens after you click Approve

**Audience:** Coder, after approving a PR.
**Status:** v1 — 2026-05-20.
**Read time:** 10 minutes.

You approve a PR. What happens next? This doc walks through the deploy stages and the tier gates so you know what to expect — and what's wrong if you don't see it.

If you only remember three things:

1. **Approve = merge + auto-deploy to dev + auto-deploy to stg.** Live deploy depends on tier.
2. **T1 + T2 auto-deploy to live.** T3 stops at stg and waits for a human (you or Rob).
3. **If smoke checks fail post-live, you can roll back without asking.** See [rollback-playbook.md](./rollback-playbook.md).

---

## 1. The deploy stages

```
PR approved (you)
    │
    ▼
GitLab auto-merges into main
    │
    ▼  (webhook → mini → deploy-on-merge.sh)
[ STAGE 1: dev rsync ]
    Rsync new main into ~/nwp/sites/nwc/dev + ~/nwp/sites/nwd/dev
    Run Behat + PHPUnit against both
    Abort if RED — write governance_action(stage=dev, status=fail)
    │ green
    ▼
[ STAGE 2: dev2stg ]
    pl dev2stg nwc -y --dev-db
    pl dev2stg nwd -y --dev-db
    Re-run smoke (Behat critical paths) against stg
    Abort if smoke fails — write governance_action(stage=stg, status=fail)
    │ green
    ▼
[ STAGE 3: tier gate ]
    Tier label on the merged PR decides the next step:
       T1 / T2 → continue to STAGE 4
       T3     → STOP. Write "READY-FOR-MANUAL-LIVE". Wait for human.
    │
    ▼
[ STAGE 4: stg2live ]
    pl stg2live nwc -y
    pl stg2live nwd -y
    5-URL smoke against live
    Abort if smoke fails — auto-rollback to last known good
    │ green
    ▼
[ STAGE 5: write success audit ]
    governance_action(stage=live, status=ok, sha=<commit>, tier=<T1|T2|T3>)
```

Approximate timing:

- **T1 / T2 PR** approved → on live: ~12 minutes
- **T3 PR** approved → on stg: ~8 minutes (then waits for manual stg2live)

You can watch the run in real time at `mini:~/nwp/logs/deploy.log` if you have SSH access.

---

## 2. The tier gate, explained

The agent self-classifies tier in its PR description. If the agent guessed wrong, **you re-classify by editing the PR label before approving** — the deploy pipeline reads the *label*, not the description text.

| Tier | Auto-deploy reaches    | Why                                                                                     |
|------|------------------------|-----------------------------------------------------------------------------------------|
| T1   | Live, no manual gate   | Trivial (typo, CSS tweak, dep patch). Rolling back is cheap if needed.                  |
| T2   | Live, no manual gate   | Single bounded feature/fix. Test coverage required; rollback is `git revert`.           |
| T3   | Stg only. Manual gate. | Architectural change, schema migration, auth touch. Must be human-vetted on stg first. |

**You can promote a T3 to live yourself** after eyeballing the stg site:

```bash
ssh mini
pl stg2live nwc -y
pl stg2live nwd -y
```

You can also demote: if a PR is marked T2 but you smell architectural risk, **set the label to T3 before approving**. The pipeline will respect the label and stop at stg.

---

## 3. The 5-URL smoke check

After every live deploy, the pipeline hits 5 URLs and asserts HTTP 200 + a known string in the body. If any fail, it auto-reverts to the previous good commit.

Current smoke targets (per stack):

**Drupal nwc / nwd:**
1. `/` — homepage, must contain "Narrow Way Commons"
2. `/about` — about page, must contain "amended" (yes, the typo-fix sentinel — proves seed ran)
3. `/dashboard` — logged-in dashboard probe, must contain "Editorial queue"
4. `/api/feedback/log` (GET, expects 405) — proves route exists and POST-only
5. `/user/login` — must contain "Log in"

**Moodle ssc / ssd:**
1. `/` — must contain "Saint School"
2. `/login/index.php` — login form
3. `/admin/tool/policy/index.php` — must contain a policy version row (proves sync ran)
4. `/local/nwc_copyright_sync/status.php` — internal status endpoint
5. `/auth/nwc_oauth2/callback.php` (GET, expects redirect) — proves OAuth endpoint reachable

If you see the words `SMOKE-FAILED` in the deploy log, the rollback has already happened. Read [rollback-playbook.md](./rollback-playbook.md) for the after-action checklist.

---

## 4. The webhook handshake

When you click Approve in GitLab UI:

1. GitLab merges the MR into main.
2. GitLab fires the `Merge Request — merged` webhook to `https://mini.internal/webhook/gitlab` (which port-forwards to `127.0.0.1:5099`).
3. The webhook receiver verifies the shared secret (constant-time compare), checks the repo against the allowlist, then forks `deploy-on-merge.sh <repo> <sha> --tier <Tn>` as a detached subprocess.
4. The deploy script runs Stages 1–5 above.

If the webhook doesn't fire (e.g. mini is down), the merge still completed — but no deploy happened. The agent loop will *not* re-trigger; you'll see "PR merged, dev still showing old commit". When that happens:

```bash
ssh mini
~/nwp/scripts/agent-loop/deploy-on-merge.sh nwp/nwc <merge-sha> --tier T2
```

(Substitute the right tier.) See [rollback-playbook.md](./rollback-playbook.md#manually-triggering-a-deploy) for more.

---

## 5. What gets written where

Each stage writes a `governance_action` audit entity. You can read the audit on the canonical site:

- nwc: `https://nwc.nwpcode.org/admin/reports/governance-actions`
- nwd: `https://nwd.nwpcode.org/admin/reports/governance-actions`

Useful filters:
- `action_type = deploy_stage` → all deploy audits
- `action_type = pr_approval` → who approved what (you)
- `correlation_id = <PR-IID>` → all audits for a single PR

If a deploy went sideways, the audit log is the canonical "what happened" record.

---

## 6. The `pl` commands (you'll see these in logs)

`pl` (short for "pipeline") is the in-repo deploy helper. The relevant commands:

| Command                       | What it does                                                                              |
|-------------------------------|-------------------------------------------------------------------------------------------|
| `pl dev2stg <profile> -y`     | Copy dev DB+files+code → stg, rebuild config, run a `cache:rebuild`                       |
| `pl dev2stg <profile> -y --dev-db` | Same, but use the dev DB snapshot (not stg's). Used by deploy pipeline.              |
| `pl stg2live <profile> -y`    | Same, but stg → live. Includes mysqldump snapshot + nginx confs backup before promotion.  |
| `pl stg2live <profile> -y --dry-run` | Print what would happen, don't actually copy. Useful for sanity checks.            |
| `pl rollback <profile>`       | Restore last snapshot taken before stg2live. See rollback-playbook.md.                    |

All `pl` invocations write to `~/nwp/logs/pl-<date>.log` on mini.

---

## 7. If you only have time to check one thing post-merge

Visit the live URLs and confirm they work:

- https://nwc.nwpcode.org/ (homepage)
- https://nwc.nwpcode.org/dashboard (logged-in only — log in if you want)
- https://nwd.nwpcode.org/ (demo)
- https://ssc.nwpcode.org/ (Moodle canonical)
- https://ssd.nwpcode.org/ (Moodle demo)

All five should return 200 + render content. If any are 5xx or showing a Drupal/Moodle error page, **roll back immediately** ([rollback-playbook.md](./rollback-playbook.md)) and ping Rob.

---

## See also

- [pr-review-checklist.md](./pr-review-checklist.md) — what to check *before* approve
- [rollback-playbook.md](./rollback-playbook.md) — what to do when a deploy goes wrong
- [agent-loop-primer.md](./agent-loop-primer.md) — what produces the PRs in the first place
- [glossary.md](./glossary.md#deploy-terms) — `pl`, `stg`, `dev2stg`, snapshot, etc.
