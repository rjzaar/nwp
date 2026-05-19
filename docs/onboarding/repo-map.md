# Repo Map

**Audience:** Coder, navigating NWC's repositories on git.nwpcode.org.
**Status:** v1 — 2026-05-20.
**Read time:** 6 minutes.

NWC is spread across multiple repos. This is the map.

If you only remember three things:

1. **All NWC repos are private** on git.nwpcode.org under the `nwp/` group.
2. **The repo you'll see 80% of PRs in is `nwp/nwc`** — the install profile + custom modules.
3. **Cross-site changes touch two repos** — e.g. an OAuth change touches both `nwp/nwc` (Drupal side) and `nwp/auth-nwc-oauth2` (Moodle side). Look for paired PRs.

---

## 1. The repos you'll be reviewing

All under `https://git.nwpcode.org/nwp/` and `git@git.nwpcode.org:nwp/<repo>.git`.

| Repo                            | What it is                                                            | Primary language | Deploys to                                  |
|---------------------------------|-----------------------------------------------------------------------|------------------|---------------------------------------------|
| `nwp/nwc`                       | The NWC install profile + ~34 `nwc_*` custom modules + tests          | PHP (Drupal)     | nwc.nwpcode.org, nwd.nwpcode.org            |
| `nwp/nwc-project`               | Composer wrapper + scaffolding for nwc canonical                      | PHP / JSON       | nwc.nwpcode.org                             |
| `nwp/nwd-project`               | Composer wrapper + scaffolding for nwd demo                           | PHP / JSON       | nwd.nwpcode.org                             |
| `nwp/local-nwc-copyright-sync`  | Moodle plugin: NWC → Moodle copyright policy sync                     | PHP (Moodle)     | ssc.nwpcode.org, ssd.nwpcode.org            |
| `nwp/auth-nwc-oauth2`           | Moodle plugin: OAuth2 SSO client for NWC → Moodle login               | PHP (Moodle)     | ssc.nwpcode.org, ssd.nwpcode.org            |
| `nwp/nwp`                       | The infrastructure overlay (deploy scripts, agent loop, this doc)     | Shell / Python   | mini (build host), all live hosts on deploy |

---

## 2. What lives where on your laptop (and on `mini`)

Same layout on both:

```
~/nwp/
├── CLAUDE.md                          # Operator instructions
├── README.md                          # Project + machine map
├── docs/
│   ├── onboarding/                    # ← you are here
│   ├── proposals/                     # F-numbered + P-numbered design docs
│   ├── reference/                     # Command references, role vocab, etc.
│   ├── deployment/                    # Live + stg deploy notes
│   └── archive/                       # Historical, do not edit
│
├── scripts/
│   ├── agent-loop/                    # The PR-loop infrastructure
│   │   ├── agent-loop.sh              # Spawns Claude Code on agent-eligible issues
│   │   ├── deploy-on-merge.sh         # Deploy pipeline (called by webhook receiver)
│   │   ├── gitlab-webhook-receiver.py # 127.0.0.1:5099 webhook listener
│   │   ├── smoke-live.sh              # 5-URL smoke check (per profile)
│   │   └── crontab.entry              # Cron schedule (feedback sync + agent loop)
│   ├── commands/                      # `pl` subcommand handlers
│   │   ├── dev2stg.sh
│   │   ├── stg2live.sh
│   │   └── rollback.sh
│   └── ...
│
├── sites/
│   ├── nwc/dev/                       # The local DDEV instance for nwc canonical
│   │   ├── html/                      # Drupal docroot
│   │   │   └── profiles/custom/nwc/   # ← the NWC install profile
│   │   │       └── modules/nwc_features/  # ← 34 nwc_* modules
│   │   ├── behat.yml.dist
│   │   ├── phpunit.xml
│   │   └── composer.json
│   └── nwd/dev/                       # Local DDEV for nwd demo (composer-aligned to nwc)
│
├── logs/                              # deploy.log, pl-*.log, incidents.log
└── .loop-paused                       # If present → loop is paused (touch to pause)
```

Three things to point out:

- **The profile is the heart of NWC.** `sites/nwc/dev/html/profiles/custom/nwc/` — when an agent PR opens against `nwp/nwc`, its diff is rooted here.
- **The infrastructure overlay is `~/nwp/scripts/`.** When an agent PR opens against `nwp/nwp`, its diff is rooted here. These are rare (T3-only territory).
- **`logs/` is your friend.** `deploy.log` shows every recent deploy. `incidents.log` is the manual log Coder maintains during rollbacks.

---

## 3. Branches you'll see

| Branch              | Repo            | What it's for                                                                     |
|---------------------|-----------------|-----------------------------------------------------------------------------------|
| `main`              | all             | The deploy source-of-truth. Protected; only merges via approved MR.               |
| `fix/issue-N`       | `nwp/nwc`       | Agent-generated fix branches. Always linked to GitLab issue #N.                   |
| `feat/issue-N`      | `nwp/nwc`       | Agent-generated feature branches (T2).                                            |
| `arch/issue-N`      | `nwp/nwc`       | Agent-generated architectural branches (T3, paired with ADR draft).               |
| `coder-onboarding-*` | `nwp/nwp`       | Docs branches like this one — human-authored.                                     |
| `paired/<x>-<y>`    | both stack sides| Cross-site paired PRs (Drupal + Moodle). Reviewer must verify both halves merge. |

**Agent branches always include the GitLab issue number** so cross-referencing is mechanical. If you see a `fix/` branch with no issue link in the PR description, that's a smell (the agent skipped its template) — request changes.

---

## 4. SSH access

You have read+write access to all six repos under `nwp/` on git.nwpcode.org via your GitLab user. Your SSH key was added during onboarding.

If you need to clone everything fresh on your own laptop:

```bash
mkdir -p ~/nwp-coder/
cd ~/nwp-coder/
for repo in nwc nwc-project nwd-project local-nwc-copyright-sync auth-nwc-oauth2 nwp; do
  git clone git@git.nwpcode.org:nwp/$repo.git
done
```

For deploy-host SSH access (mini, where you'd run `pl rollback`), see [rollback-playbook.md §1](./rollback-playbook.md) — Rob sets up your key there separately.

---

## 5. Where the GitLab issue list lives

You'll spend most of your time in the GitLab UI, not the CLI. Useful URLs:

- **All open MRs** (sorted by recency): https://git.nwpcode.org/groups/nwp/-/merge_requests?state=opened
- **All open issues** on the nwc repo: https://git.nwpcode.org/nwp/nwc/-/issues
- **Issues labeled `agent-eligible`** (what the agent loop sees): https://git.nwpcode.org/nwp/nwc/-/issues?label_name=agent-eligible
- **Issues labeled `needs-human`** (parked, agent shouldn't touch): https://git.nwpcode.org/nwp/nwc/-/issues?label_name=needs-human
- **Issues labeled `incident`** (live problems): https://git.nwpcode.org/nwp/nwc/-/issues?label_name=incident

Label reference:
- `agent-eligible` — agent loop will pick this up
- `needs-human` — agent loop won't touch; needs Rob or you
- `T1` / `T2` / `T3` — tier; set on the MR (not the issue) by the agent, overridable by you
- `incident` — production problem; out-of-band priority
- `paired` — cross-site PR; check the paired repo

---

## 6. Where the agent stores its own state

On mini, the loop maintains:

- `~/nwp/.agent-loop.state.json` — last-run, daily PR count, per-issue retry count
- `~/nwp/logs/agent-loop.log` — every poll, every spawned Claude Code session
- `~/nwp/logs/claude-runs/<issue-N>/` — full Claude Code transcript per spawn (huge; rotated weekly)

You don't need to read these unless you're debugging "why did the loop make this PR" or "why did it skip an issue". Rob's the primary maintainer of the loop itself.

---

## See also

- [agent-loop-primer.md](./agent-loop-primer.md) — how the loop uses these repos
- [deploy-pipeline.md](./deploy-pipeline.md) — what happens when an MR merges
- [glossary.md](./glossary.md) — terms used here
