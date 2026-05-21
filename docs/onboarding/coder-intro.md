# Coder's Intro Guide — Reviewing PRs for NWC

**Audience:** Coder (PR reviewer for the NWC platform).
**Status:** v1 — written 2026-05-20.
**Read time:** 20 minutes for the full guide; 5 minutes if you skim the headings.

Welcome. You're the human in the loop. An autonomous agent generates Pull Requests against the NWC codebase from real user feedback; your job is to read every one of those PRs, decide whether to approve or push back, and (when something goes wrong) help us roll back cleanly. This document is the single page you should bookmark; everything else in this folder is a deeper read on a specific topic.

If you only remember three things:

1. **You review every PR.** Trivial-looking changes get the same eyeballs as scary ones. The agent has been wrong about its own changes before; your job is to catch that.
2. **Tier labels (T1 / T2 / T3) are about *attention budget*, not about *whether you read it*.** T1 = read in 2 minutes; T3 = read in 30 minutes. Both get read.
3. **When in doubt, request changes or pause the loop.** Use [`touch /home/rob/nwp/.loop-paused`](./rollback-playbook.md#pausing-the-agent-loop) and ping Rob. The loop will idle until you unpause it. Nothing bad happens by waiting.

---

## 1. What NWC is, in 30 seconds

NWC = **Narrow Way Commons**. It's a Drupal install profile (a "distribution") built on top of [Open Social](https://www.drupal.org/project/social), with a stack of custom modules that add community-curated content workflow, multi-stage editorial review, governance audit, and copyright awareness. Real members log in, write or critique theology / pedagogy / curriculum content, and that content flows through reviewer queues before going live.

Important things to keep straight:

- **NWC is a real product**, not a framework. There is exactly one canonical deployment, at `nwc.nwpcode.org`. Forks are allowed but must rename — see [ADR-0001](./adrs.md#adr-0001-nwc-is-the-platform).
- **The site you see** is built from the install profile at `~/nwp/sites/nwc/dev/html/profiles/custom/nwc/`. That profile composes ~34 `nwc_*` modules + a chunk of Open Social.
- **The work is editorial.** State machine: `draft → in_writer_review → in_pedagogy_review → in_theology_review → in_copyright_clearance → approved → in_trial → trialed → in_production`. PRs you review will touch any layer of that machinery.

For the longer version, read [architecture-brief.md](./architecture-brief.md).

---

## 2. The 4 live sites — and why there are 4

NWC actually runs as **four** sites in production. Two are Drupal (NWC itself); two are Moodle (Saint School, the affiliated theology curriculum platform). They're paired: each canonical site has a demo twin.

| Live URL                | Stack    | Pair       | Audience                      | What it serves                                                                |
|-------------------------|----------|------------|-------------------------------|-------------------------------------------------------------------------------|
| `nwc.nwpcode.org`       | Drupal   | canonical  | Real Narrow Way community     | Saint School theology mission; real Sojourners + Stewards                     |
| `nwd.nwpcode.org`       | Drupal   | demo       | Evaluators, potential forkers | Demo content: Logic curriculum + curated Saint School subset; sample guilds   |
| `ssc.nwpcode.org`       | Moodle   | canonical  | Real Saint School students    | The actual Moodle courses for nwc members                                     |
| `ssd.nwpcode.org`       | Moodle   | demo       | Evaluators                    | Demo Moodle courses; mirrors ssc structure with sample data                   |

Pairing rules (you will see these in PRs):

- **Drupal pair:** `nwc ↔ ssc` (canonical); `nwd ↔ ssd` (demo). When a PR touches cross-site integration (OAuth, copyright sync, feedback ingest), it touches one or both pairs.
- **One codebase per stack.** Both `nwc.nwpcode.org` and `nwd.nwpcode.org` are deployed from the same git repo (`nwp/nwc`). Same for ssc/ssd against the Moodle plugin repos.
- **Both demo sites stay live indefinitely.** They are first-class production traffic, not throwaway. Treat a "demo" PR with the same rigor as canonical.

Settled architecturally in [ADR-0015](./adrs.md#adr-0015-two-site-topology) and [ADR-0016](./adrs.md#adr-0016-nwd-deployment-pattern). The trial tier `ss.nwpcode.org` (singular) is the gate between approved-in-nwc-editorial and shown-to-real-trialing-guild — see [architecture-brief.md §4](./architecture-brief.md#4-the-editorial-pipeline-a30).

The legacy `avc.nwpcode.org` is also up but is **historical only** — it's a frozen pre-refactor snapshot kept as comparison. No PR should touch it.

---

## 3. The agent loop — what it is and how it talks to you

A pipeline runs on `mini` (one of Rob's home boxes) and produces the PRs you review. The shape:

```
NWC user clicks "feedback" widget
    │
    ▼
POST /api/feedback/log
    │
    ▼
`feedback` Drupal entity created on nwc.nwpcode.org
    │
    ▼  (cron, every 15 min)
`drush nwc-feedback:sync-to-gitlab`
    │
    ▼
GitLab issue on git.nwpcode.org/nwp/nwc with tier label (T1 / T2 / T3)
    │
    ▼  (cron, every 30 min)
`agent-loop.sh` spawns `claude -p "fix issue #N"` in headless mode
    │
    ▼
Claude opens an MR on the same repo, self-classifies tier, attaches diff
    │
    ▼
*** YOU REVIEW IT ***
    │
    ├── approve → merge → deploy-on-merge.sh → live (auto for T1/T2; manual gate for T3)
    └── request changes → agent picks up your comments, opens a new MR
                                ↑
                  (see §3.1 for the exact triggers)
```

Key properties of the loop you must know:

1. **The agent self-classifies the PR tier.** The label on the MR (`tier::T1`, `tier::T2`, `tier::T3`) was set by the agent. **Verify the label matches the diff.** If the agent labelled a schema migration as T1, that's a misclassification — flip it to T3 and treat accordingly. See [pr-review-checklist.md §3](./pr-review-checklist.md#3-verify-the-tier-label).
2. **Auto-merge does not exist.** Every PR waits for your approval — there is no path where a green CI alone merges anything. The "auto" in "auto-deploy" refers to what happens **after merge**, not before.
3. **You can pause the loop** at any time:
   ```bash
   ssh mini "touch /home/rob/nwp/.loop-paused"
   ```
   The next cron tick will see the flag and skip. To resume:
   ```bash
   ssh mini "rm /home/rob/nwp/.loop-paused"
   ```
4. **Kill switches above the loop:** The loop has a global rate limit (max 5 open MRs at once) and a daily MR cap. If something's spamming you with PRs, the rate limit will save your inbox — but if it's pathological, pause the loop.

For the full agent-loop spec, see [agent-loop-primer.md](./agent-loop-primer.md).

### 3.1 How to send the agent back to the drawing board

The loop reacts to **three signals** from you when an MR needs another pass. Pick whichever feels most natural for the situation:

| Signal | How | Latency | When to use |
|---|---|---|---|
| **Add a label** | Click "Edit" on the MR sidebar → add `needs-agent-fix` | Seconds | Cleanest. The label survives review-tool restarts and is unambiguous in the audit log. |
| **GitLab "Request Changes" review** | Use the standard review UI → "Submit review" → "Request changes" | Seconds | The most discoverable for a GitLab-native workflow. Also keeps your specific review comments attached to lines. |
| **Comment with `@agent-loop` or `/agent fix`** | Plain MR comment containing one of those phrases | Seconds | Best when you want to give natural-language steering: "@agent-loop the new test should be a Kernel test, not Functional — see existing examples in nwc_editorial/tests/src/Kernel/". |

Behind the scenes, any of those three writes a marker to `~/nwp/.agent-respawn/` on the agent host, which fires `agent-loop.sh` within seconds (vs. the default 30-min cron tick). The loop then closes the existing MR, re-eligibilises the linked issue, and the next cron tick spawns Claude with your comments as additional context. **`MAX_RETRIES=3` per issue** — after three respawns the `agent-eligible` label is stripped and the issue waits for a human.

All three signals require **power-user status** (your GitLab account is on the allowlist). Submissions from anyone not on the list silently fall back to the 30-min poll, which still catches label changes / changes-requested reviews — they just don't get the instant turnaround. Every power-user-triggered respawn is logged to `~/nwp/logs/power-user-audit.jsonl` so we can review delegation patterns later.

Same trust unit applies to **NWC site users**: if you submit feedback from `nwc.nwpcode.org` while logged in as a UID on the Drupal allowlist (admin or rjzaar today), the feedback is synced to GitLab and queued for agent attention in seconds rather than the default 15-min cron lag.

---

## 4. The tier system — your attention dial

Every PR is labelled `tier::T1`, `tier::T2`, or `tier::T3`. The tier tells you **how much attention to give** and **what the impact of approving is**:

| Tier | Meaning                | Examples                                                                                  | Attention budget | Auto-deploy on merge?     |
|------|------------------------|-------------------------------------------------------------------------------------------|------------------|---------------------------|
| **T1** | Minor / cosmetic       | Typo fix; help-text wording; CSS tweak; behat scenario clarification; comment fix         | 2-5 min          | Yes (dev → stg → live)    |
| **T2** | Behavioural change     | New form field; routing tweak; permission check addition; new editorial transition step   | 10-20 min        | Yes (dev → stg → live)    |
| **T3** | Architectural / risky  | Schema migration; auth touch; new module; secrets/permissions change; ADR amendment       | 20-60 min        | **No.** Manual gate.      |

**Promotion rules** (Rob set these; don't relax them without ADR):

- A PR that **adds a database column** is T3 even if "trivial". Schema = T3, full stop.
- A PR that **adds or changes an external network call** is T3. (You also want to check it's not data exfiltration — see [nwp/CLAUDE.md security red flags](../../CLAUDE.md#security-red-flags).)
- A PR that **touches `*/settings.php`, `*/Auth*`, `auth_*`, `*/.gitlab-ci.yml`, `composer.json` deps, or any `keys/`** is T3.
- A PR that **adds eval / exec / system / passthru / shell_exec / proc_open** is T3 + immediate "request changes" unless explicitly approved by Rob.
- A PR labelled **T3 + `auto-deploy::blocked`** means CI saw something blocking; investigate before approving.

**Don't promote down.** If you suspect a T2 should be T3, flip it up. Rob would rather review more carefully than less.

The mechanical checklist for every tier is in [pr-review-checklist.md](./pr-review-checklist.md). For T2 and T3, there are extra checks at the end of that doc.

---

## 5. Your first day — checklist

Work through this once. It should take about 90 minutes.

**Setup (one-off; ~30 min):**

- [ ] You have a GitLab account at `git.nwpcode.org`. (Rob created it; if you can't log in, message him before proceeding.)
- [ ] You have SSH set up against `git.nwpcode.org`. Test: `ssh -T git@git.nwpcode.org` should print a banner with your name.
- [ ] You have access to the `nwp/nwp` and `nwp/nwc` repos. Try opening each in the GitLab web UI. If you see "404", message Rob.
- [ ] Clone the two main repos locally:
  ```bash
  git clone git@git.nwpcode.org:nwp/nwp.git ~/nwp
  git clone git@git.nwpcode.org:nwp/nwc.git ~/nwc-profile
  ```
  (`nwp/nwp` is the toolkit. `nwp/nwc` is the install profile most PRs touch.)
- [ ] Skim [`~/nwp/CLAUDE.md`](../../CLAUDE.md) — the operator standing orders. You don't need to memorise it; just know where it is. The "Security Red Flags" section in the middle is the part you'll consult.

**Orientation (~30 min):**

- [ ] Read [architecture-brief.md](./architecture-brief.md) end-to-end. ~10 min.
- [ ] Read [pr-review-checklist.md](./pr-review-checklist.md) end-to-end. ~10 min.
- [ ] Skim [glossary.md](./glossary.md). You won't remember it all; just locate it.
- [ ] Open the GitLab MR list for `nwp/nwc`. Pick one labelled `tier::T1` if any is open (or browse closed MRs from the last week). Walk through it using the checklist. You don't have to approve — just practice the motions.

**First real review (~30 min):**

- [ ] Wait for a fresh T1 MR. Run the checklist. Approve it, or comment to ask for clarification, or request changes.
- [ ] After your decision, watch what happens: `deploy-on-merge.sh` runs on merge, the deploy pipeline marches dev → stg → live, smoke tests run against live. If anything's red, see [rollback-playbook.md](./rollback-playbook.md).
- [ ] Note one thing that surprised you. Tell Rob next time you sync.

That's it. From day two on, your loop is: open MR list → pick one → checklist → decide → repeat.

---

## 6. Your typical PR review — a worked example

Suppose an MR lands in your inbox:

> **MR !142** — "Fix typo in pedagogy reviewer help text" (`tier::T1`, `auto-deploy::ready`)
> **Branch:** `agent/feedback-289/fix-pedagogy-helptext`
> **Author:** `agent-loop-bot`
> **Lines:** +4 / -4

### Step 1 — Read the description (30 sec)

A good agent-generated description has these sections:

```
## Issue
Closes #289

## What changed
Fixed "pedaagogy" → "pedagogy" in the Pedagogy Reviewer help bubble shown when
opening an editorial revision.

## Why
User feedback (issue #289) flagged the typo.

## Tests
- vendor/bin/behat --config=behat.yml.dist --suite=nwc_editorial: 6/6 pass
- vendor/bin/phpunit -c phpunit.xml: 6/6 pass

## Rollback
git revert <commit-sha> — no schema change, no data migration.
```

If any of issue ref / what / why / tests / rollback is missing → request changes. The PR description is a contract; an incomplete one is reason enough to send it back.

### Step 2 — Verify tier (30 sec)

Pedagogy help text is content, not behaviour or schema. `tier::T1` is correct. Move on.

### Step 3 — Read the diff (1 min)

Two files: a `.module` file and the matching behat scenario. Both contain "pedaagogy" → "pedagogy". Nothing extraneous. No imports added. No `eval`. No new dependencies.

### Step 4 — Verify tests run (passive)

You don't need to run tests yourself for T1 — CI does. Look at the CI badge on the MR: green = good. If yellow or red, click in and read.

### Step 5 — Approve

Click "Approve" in the GitLab UI. The merge button enables. Click "Merge".

### Step 6 — Watch the deploy (passive; ~5 min)

`deploy-on-merge.sh` will:

1. Pull the merge commit into dev's working tree (~10 sec).
2. Run dev Behat + PHPUnit (~3 min). Re-runs to confirm no regression.
3. `pl dev2stg nwc` → push dev DB + code to stg (~1 min).
4. Run smoke tests against stg.
5. `pl stg2live nwc` → push stg to live (~1 min).
6. Take a fresh snapshot before any destructive step. (Snapshot lives at `~/nwp/sites/nwc/backups/`.)
7. Run live smoke (curl `https://nwc.nwpcode.org/` → expect 200; `/user/login` → expect 200; etc.)
8. Done. Notify GitLab via the bot.

If anything in 1-7 fails, `deploy-on-merge.sh` halts at the failed step, pings you, and the agent loop pauses. See [deploy-pipeline.md](./deploy-pipeline.md) and [rollback-playbook.md](./rollback-playbook.md).

That's a T1. Total time from MR landing to live: ~10 minutes. Your time on it: ~3 minutes.

A T3 with a migration will involve more steps and more decisions. The mechanics of the diff-read are the same; the threshold of what stops you is lower.

---

## 7. The investigative loop — when something looks wrong

You'll see PRs that don't smell right. Here's how to investigate, in order of cheapest-first:

### Smell 1 — "The description doesn't match the diff"

**Action:** read the diff again. Sometimes the description glosses over things ("refactored copyright clearance" hides "...and changed the permission model"). If the diff is bigger than the description, comment with: "Please update the PR description to include all changes," and request changes.

### Smell 2 — "The tier label looks wrong"

**Action:** check the diff against the [tier promotion rules above](#4-the-tier-system--your-attention-dial). If the agent marked schema-change as T2, write a one-line comment: "Schema migrations are T3 per [pr-review-checklist.md](./pr-review-checklist.md#3-verify-the-tier-label); please re-classify and re-run the T3 checks." The agent should re-open with the right label and the T3-tier extra tests.

### Smell 3 — "Tests pass but I don't believe them"

**Action:** read the test. Does it actually test the behaviour being changed, or did the agent add a tautology (`assertTrue(true);`)? Look for assertions that match the change's intent. If the test is hollow, request changes and ask for a real assertion.

### Smell 4 — "An unexpected file is modified"

**Action:** check if it's in the [sensitive-paths list](../../CLAUDE.md#sensitive-file-paths). If yes, request changes immediately and ping Rob. If no, ask in a comment: "Why is `<filename>` touched? Wasn't expecting that for this change." The agent's response will either explain (legit cross-cutting concern) or reveal that it spread further than it should have (regen it).

### Smell 5 — "The diff has a `// TODO:` or `// FIXME:` planted in it"

**Action:** these are footguns. Request changes and tell the agent to either resolve or open a new issue for it. Don't accept TODOs into main.

### Smell 6 — "The diff has a base64 / hex string I don't recognise"

**Action:** request changes immediately. This is a red flag (see [`~/nwp/CLAUDE.md`](../../CLAUDE.md#malicious-code-patterns) "Malicious Code Patterns"). Ping Rob. The agent should never need to embed encoded blobs.

### Smell 7 — "It connects to an external URL I haven't seen before"

**Action:** request changes. Same red flag as above. The only external URLs that should appear in nwc/nwd code are: `nwc.nwpcode.org`, `nwd.nwpcode.org`, `ssc.nwpcode.org`, `ssd.nwpcode.org`, `saint.school`, `git.nwpcode.org`. Anything else needs justification.

When the investigation deepens and you're not sure: **pause the loop and ping Rob**. The cost of a 1-hour pause is small. The cost of merging something wrong is large.

---

## 8. Escalation table — when to do what

| Situation                                                  | First action                                              | Who to ping                          |
|------------------------------------------------------------|-----------------------------------------------------------|--------------------------------------|
| PR description incomplete                                  | Request changes; ask agent to add missing sections        | (No one yet; agent will redo)        |
| Tier label looks wrong                                     | Comment + request changes                                 | (Agent reclassifies)                 |
| Test passes but feels hollow                               | Request changes with specifics                            | (Agent rewrites the test)            |
| Touch of a sensitive path (auth, settings, CI, deps, keys) | Request changes immediately                               | **Rob**                              |
| Suspicious code pattern (eval, base64, external URL)       | Request changes immediately + add `red-flag` label        | **Rob**                              |
| Live smoke fails after merge                               | Run rollback playbook; pause loop                         | **Rob** (within the hour)            |
| Live site down (HTTP 500 / 502)                            | Pause loop; restore from snapshot                         | **Rob** (immediately)                |
| Agent producing 20+ MRs / day                              | Pause loop; review queue                                  | **Rob** (within the day)             |
| Agent contradicting itself across MRs                      | Pause loop; review the last 5 MRs together                | **Rob** (within the day)             |
| Behat/PHPUnit failing intermittently                       | Note the flake; don't fail the PR on it; track            | **Rob** (when you have 3+ examples)  |
| You're unsure if something is OK                           | Pause loop; comment on the MR; wait                       | **Rob**                              |

**Rule of thumb:** if you're spending more than 5 minutes wondering whether to approve, pause the loop and ask. Pausing has no cost. Approving a wrong thing has real cost.

---

## 9. Where to find me

**Rob Zaar** is the operator and the person you escalate to.

- **Email:** *[placeholder — Rob to fill in]*
- **Signal / SMS:** *[placeholder — Rob to fill in]*
- **GitLab:** `@rzaar` on `git.nwpcode.org`
- **Best response time:** *[placeholder — Rob's typical availability window]*
- **For pauses / urgent issues:** *[placeholder — explicit "wake me up" channel]*

When you ping Rob about a PR, please include:

1. The MR URL.
2. What you saw that made you stop.
3. What you've already done (paused the loop? requested changes? rolled back?).

This lets Rob spin up fast without re-reading everything from scratch.

---

## 10. The other docs in this folder — what to read when

This intro is the entry point. Here's what each adjacent doc covers, and when you'd read it:

| Doc                                                  | What it covers                                                                        | When to read                                                       |
|------------------------------------------------------|---------------------------------------------------------------------------------------|--------------------------------------------------------------------|
| [pr-review-checklist.md](./pr-review-checklist.md)   | The mechanical checklist for every PR — work through it before approving.            | Every PR (you'll memorise it after ~20 reviews).                   |
| [architecture-brief.md](./architecture-brief.md)     | Condensed NWC architecture; how the site, modules, guilds, and pipeline fit together. | Day one; refer back when a PR touches an unfamiliar module.        |
| [testing.md](./testing.md)                           | How to run + interpret behat, PHPUnit, smoke tests; how to add a test.                | When a PR is missing tests or you doubt the ones it has.           |
| [deploy-pipeline.md](./deploy-pipeline.md)           | What happens between "you click merge" and "it's live."                              | Day one (read once); when a deploy fails.                          |
| [rollback-playbook.md](./rollback-playbook.md)       | Exactly how to undo a bad merge at code level + at live tier; how to pause the loop. | When something is broken on live. Keep the URL bookmarked.         |
| [repo-map.md](./repo-map.md)                         | The 6 repos you'll encounter and what each is for.                                    | Day one; refer back when a PR's path looks unfamiliar.             |
| [glossary.md](./glossary.md)                         | NWC vocabulary: guild names, ADR list, pipeline states, tier definitions.            | When a word in a PR doesn't make sense.                            |
| [agent-loop-primer.md](./agent-loop-primer.md)       | How the loop that produces PRs actually works — feedback widget through to merge.    | Day one; when the agent's behavior is surprising.                  |
| [adrs.md](./adrs.md)                                 | Annotated list of all 16 ADRs with "what Coder needs to know" per ADR.                | When a PR cites an ADR you don't recognise.                        |

[README.md](./README.md) at the top of this folder is just an index of the above.

---

## 11. What you don't have — and that's by design

Some things you intentionally lack access to:

- **Production server SSH.** You cannot SSH into `nwc.nwpcode.org` or any live host. Deploys happen from `mons` (Rob's offline laptop) per [ADR-0017](../../docs/decisions/0017-distributed-build-deploy-pipeline.md). Even Rob's home boxes (`metabox`, `mini`) can't reach prod directly.
- **Production database credentials.** Same reason. You don't need them to review code; you'd need them to run queries against live, which is a separate workflow with two-person gating.
- **Secrets files** (`.secrets.data.yml`, `keys/prod_*`). These are blocked in repo-level access controls. If you find a PR that tries to read or write these, that's a high red flag — request changes + ping Rob.
- **Force-push to main.** GitLab settings disallow force-push to protected branches. If you ever see a merge request that's been force-pushed *on its own MR branch*, that's not unusual (the agent sometimes rewrites its own commits during iteration) — but force-push to main itself shouldn't be possible from your account.

What you **do** have:

- Read + comment + approve + reject on `nwp/nwc`, `nwp/nwp`, `nwp/nwc-project`, `nwp/nwd-project`, `nwp/local-nwc-copyright-sync`, `nwp/auth-nwc-oauth2`.
- Ability to pause the agent loop (SSH access to `mini` for the `touch /home/rob/nwp/.loop-paused` command).
- Read access to CI logs on every MR.
- Ability to view production smoke-test results in GitLab CI artefacts.

If you need something you don't have, that's a real conversation with Rob — but the default answer for "should Coder have prod access" is **no** (per the [paranoid threat model](../../CLAUDE.md#threat-model)).

---

## 12. Closing — what good looks like

A month from now, the rhythm should feel like this:

- You open the MR list 2-3 times a day. Most days there are 1-5 fresh PRs.
- T1s take 2-3 minutes each. You approve most; occasionally request a tightened description.
- T2s take 10-15 minutes each. You read the diff, run the checklist, maybe check one related file for context. You approve most.
- T3s are rare (1-3 a week). You schedule a quiet 30-60 min slot. You read carefully. You sometimes request changes; you sometimes pull Rob in.
- You catch ~1 misclassified tier per week. You catch ~1 hollow-test PR per week. You catch ~1 scope-creep PR per week. These are the agent's known failure modes.
- You haven't had to run a rollback yet — but you know exactly how, because you read [rollback-playbook.md](./rollback-playbook.md) on day one and again any time the procedure changes.

You're the human in the loop. **The whole system depends on you reading carefully.** That's the gig.

Welcome aboard.

---

*Version 1 — 2026-05-20. Maintained by Rob; PR against this doc if anything's wrong.*
