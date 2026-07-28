# The Self-Healing Loop — how it works, where it's at, how to drive it

**Audience:** the operator (a coder, not a devops person — jargon is explained
as it appears).
**Status:** written 2026-07-03, the day the loop went live end-to-end
(ops#41 / MR !38); updated 2026-07-28 with the resource preflight and the
ai-host arming procedure (ops#109). This is the system-level guide; the
per-component docs it links to go deeper.
**Read time:** ~15 minutes.

---

## 1. The idea in one paragraph

You run a fleet of ~18 Drupal/Moodle sites. Things go wrong on a schedule:
dependencies grow security holes, backups get missed, config drifts. The
self-healing loop is a pipeline that turns "something is wrong on site X" into
"here is a reviewed, merged fix" with **exactly one human step in the middle —
you approving things**. Think of it as CI in reverse: normal CI checks code you
wrote; this system *writes* code in response to checks, and you review it the
same way you'd review a colleague's PR.

```
        DETECT              GRADE                TICKET               FIX                 APPROVE            RE-CHECK
  pl audit + pl todo  →    pl rag      →   pl rag --sync-issues → agent-loop      →   YOU merge the MR  →  next pl rag run
  (advisories, drift)  (🔴/🟠/🟢 per site)  (one nwp/ops issue    (headless Claude       (the A14 gate)      goes 🟢 → issue
                                            per non-green site)   opens an MR on                            auto-closes
                                                                  the right repo)
                                     ▲                                                                          │
                                     └──────────────────────────────────────────────────────────────────────────┘
```

The one deliberate human act besides merging: **promoting** an issue to the
agent (adding two labels). Nothing is fixed by machine unless you asked for it.

---

## 2. The pieces, in pipeline order

### 2.1 Detection — `pl audit` and `pl todo`

- **`pl audit`** runs `composer audit` per site. *Jargon:* composer is PHP's
  package manager (like npm/cargo); `composer audit` checks your lockfile
  against a database of published vulnerability advisories — "package X below
  version Y has a known security hole". Results are cached as JSON per site in
  `private/update-awareness/<site>.json`.
- **`pl todo`** runs ~15 non-security checks: missing backups, uncommitted
  work, failing verify, stale schedules, open issues. Output is a
  priority-ranked list (also JSON via `--json`).

> **Known gap (2026-07-03):** nothing on the dev workstation refreshes the
> `pl audit` records on a schedule — they update only when you (or a session)
> run `pl audit`/`pl rag`. the build-host runs its own independent daily audit (02:30 UTC,
> posts to the ops log-queue on state change) but does **not** write these records.
> Until a refresh cron exists, the security signal into the loop is as fresh as
> the last manual run — stale records are at least *marked* stale (`*` in the
> tables, amber grade). This is Stage-4 work, see §5.

### 2.2 Grading — `pl rag`

Merges both signals into one per-site grade. *Jargon:* RAG =
Red/Amber/Green, standard traffic-light status reporting.

- 🔴 **RED** — open security advisory, or a high-priority security todo.
- 🟠 **AMBER** — anything else that needs work (todos, drift, stale audit cache).
- 🟢 **GREEN** — clear.

`pl rag` prints the fleet table and writes machine-readable state to
`private/rag/state.json`. It exits with code 3 if anything is red (so scripts
can branch on it). `pl status` shows the same grade as a colored dot column,
read from that cached state — with a footer telling you how old the cache is.

### 2.3 Ticketing — `pl rag --sync-issues`

Turns the graded state into GitLab issues on **nwp/ops** (the tracker project —
it holds work items, no code). Runs daily at 04:30 UTC from cron
(`scripts/agent-loop/rag-sync.sh`), and you can run it by hand (dry-run by
default, `--execute` to write).

- One issue per non-green real site, deduplicated via labels `rag-auto` +
  `site::<name>`. *Jargon:* this is an **upsert** — create if absent, update if
  present, never duplicate. Re-running is safe (**idempotent**).
- Grade changes update the issue; a site going green **auto-closes** it.
- Test/fixture sites are filtered out so the tracker doesn't fill with junk.

### 2.4 The human gate — promotion (this is the A14 boundary)

A `rag-auto` issue is a *triage item for you*. The agent will not touch it
until **you** add two labels:

| label | meaning |
|---|---|
| `kind::security-bump` \| `kind::config` \| `kind::docs` \| `kind::nwc-drupal` | what shape of fix this is → which prompt + which repo |
| `agent-eligible` | "I've judged this dev-repo-bounded and low-risk — agent may act" |

*Jargon:* **A14** is the standing decision that AI may act autonomously only up
to the test tier; anything reaching real production stays human-gated. In this
loop, A14 shows up twice: promotion (above) and merge (§2.6). Optionally add
`repo::<group/project>` to route somewhere explicit.

**Never promote:** anything touching real prod, auth/secrets, CI config, or
the frozen avc-fork pins. The prompt templates also hard-refuse those paths
from the inside.

### 2.5 The fix — the agent-loop

`scripts/agent-loop/agent-loop.sh`, cron every 30 min **on the ai-host** (dev has a
paused fallback copy). Per tick it takes at most one eligible issue and:

1. **Routes** it to the repo where the fix belongs. nwp/ops issues carry no
   code, so: `repo::` label wins → else the kind decides for single-repo kinds
   (`config`/`docs` → nwp/nwp, `nwc-drupal` → nwp/nwc) → else `site::<name>` →
   that site's composer project (`nwp/<site>-project`, per
   `scripts/agent-loop/fix-repo-map.json`). Unroutable → one explanatory
   comment, label removed, no guessing.
2. **Clones/refreshes** that repo into `.agent-checkouts/` and makes a git
   **worktree** on a fresh branch. *Jargon:* a worktree is a second working
   directory sharing one repo — the agent gets an isolated checkout without
   touching anything else.
3. **Runs headless Claude** (`claude -p` — same binary you use, no interactive
   prompt) with a prompt built from the issue plus the kind-specific template
   in `scripts/agent-loop/prompts/<kind>.md` (what to change, what tests to
   run, what it must refuse).
4. **Opens a merge request** on the fix repo if Claude committed something.
   *Jargon:* MR = GitLab's name for a PR. The MR body carries a cross-project
   `Closes nwp/ops#N` so merging it auto-closes the tracker issue.

Guardrails: daily MR cap (5), per-issue retry budget (3), max-age cutoff,
kill-switch file, and it **never merges anything**.

### 2.5b The resource preflight — the loop yields to a busy box (ops#109)

The loop's home (the ai-host) is a **shared** box: it is also the local-LLM
host, the webhook receiver and a CI runner. So before each tick claims an
issue, a preflight (`lib/loop-preflight.sh`) asks one question — *is this box
busy enough that the run should wait?* — and if yes, the tick **defers**.

**Deferral semantics** (this is the part worth remembering):

- A deferral is **not an error**. The tick exits 0 (cron stays green), logs
  `PREFLIGHT DEFER: <reason>` to `~/nwp/logs/agent-loop.log`, and stops
  *before* the poll — so it claims no issue, touches no label, spawns no
  Claude, and consumes none of the daily-cap or retry budgets. To GitLab it
  looks as if the tick never ran; the next :00/:30 tick simply retries.
- The gate is **fail-safe, not fail-closed**: a probe that *cannot answer*
  (missing command, unreadable `/proc`, the health library absent from the
  checkout) also defers — a 30-minute wait is a better failure than an
  unguarded spawn on a box that could not be measured.
- The **one documented exception** is ollama, because it is optional: an
  unreachable or garbled ollama API is read as "no model resident" (the
  permissive answer), never as a defer. Otherwise every host *without* ollama
  would defer forever.

**What it checks, and the defaults** (each is an env override in the cron
line's environment; full rationale in the `lib/loop-preflight.sh` header):

| signal | knob | default | defers when |
|---|---|---|---|
| available **system** RAM | `AGENT_LOOP_MIN_MEM_MB` | 2048 | below the floor |
| load average per core | `AGENT_LOOP_MAX_LOAD_PCT` | 150 (% of one core) | above the threshold |
| resident ollama model | `AGENT_LOOP_REQUIRE_IDLE_OLLAMA` | 1 (on) | any model loaded (`/api/ps` non-empty) |
| CI runner activity | `AGENT_LOOP_MAX_RUNNER_JOBS` (user: `AGENT_LOOP_RUNNER_USER`, default `gitlab-runner`) | 0 | any process owned by the runner user |
| disk + swap pressure | `NWP_HEALTH_MIN_DISK_MB` / `NWP_HEALTH_MIN_SWAP_FREE_PCT` | 2048 / 25% | inherited for free — see below |

Two design points:

- **RAM means *system* RAM.** On the ai-host the LLM's ~96 GB lives in iGPU
  VRAM — a *different pool* from the ~30 GB of system RAM the preflight reads.
  That is exactly why the ollama signal exists: a fully-loaded model and an
  idle box report the same `MemAvailable`. Load is judged **per core** (32
  cores at load 8 is 25%, idle; 2 cores at load 8 is drowning).
- **It reuses `pl server health`'s engine**, not a copy of it. Signals 1–2
  (plus disk and swap) go through the same `host_health_*` functions in
  `lib/host-capture.sh` that back `pl server health`, so the loop and the verb
  the standing orders call "a REQUIRED PREFLIGHT" cannot drift apart.

`AGENT_LOOP_SKIP_PREFLIGHT=1` is the escape hatch for a hand-run — logged
loudly, consulted by nothing automatic.

### 2.6 Approve and re-check

You review the MR like any PR and merge or reject — the second A14 gate. After
merge, the next audit/grade cycle sees the advisory gone → site goes green →
the rag-auto issue auto-closes. If the fix was bad, MR review is where it dies;
if it merged and still didn't fix it, the site stays non-green and the issue
stays open. If the agent's MR misses the mark, comment `@agent-loop` on it (the
webhook respawn path closes the MR and re-queues the issue with a retry).

### 2.7 What this loop does NOT do (yet): deploy

The loop ends at **merged code**. Getting merged code onto live servers is the
separate deploy pipeline (signed bundles → verification → apply), and its prod
half is still human-driven pending the `ver` machine (ops#25) and the
runner-resident model in ADR-0024. The `*.example.com` test tier is
AI-deployable under A14; real prod is not. See
`docs/onboarding/deploy-pipeline.md` and ADR-0017/0022/0024/0026.

---

## 3. Where everything runs

| host | what it is | role in this loop |
|---|---|---|
| dev (this box) | your workstation | `pl` commands; 04:30 rag-sync cron; paused fallback copy of the agent-loop |
| **ai-host** | the always-on home box | **the live agent-loop** (cron :00/:30) + the GitLab/feedback webhook receiver |
| build-host | the CI/build box | its own daily composer audit (02:30 UTC → the ops log-queue); feedback→issue reconciler |
| <gitlab-host> | self-hosted GitLab (Linode) | issues, MRs, repos — the system of record |
| prod boxes | live sites | untouched by this loop; deploy pipeline + the ver boundary applies |

Host names above are ROLE names (the gitleaks doc-gate keeps real hostnames
out of committed docs); the role→machine binding lives in
`~/nwp-instances/instance-manifest.yml`.

Token note: the loop authenticates with `GITLAB_TOKEN` from
`~/.nwp-agent-loop.env` (0600, never committed); `pl issue`/`pl rag` use the
least-privilege `ops_note_token` from `.secrets.yml`.

---

## 4. Safety model in one table

| risk | control |
|---|---|
| agent fixes something you didn't sanction | `agent-eligible` label is human-applied, per issue |
| agent touches the wrong repo | explicit routing map; unroutable = refuse + de-eligibilise |
| agent edits sensitive paths | prompt hard-boundaries (CI config, auth/secrets, keys, live-deploy scripts → stop + note) + your MR review |
| bad code reaches main | **nothing auto-merges** |
| runaway loop | daily cap 5, one issue per tick, retry budget 3, `touch ~/nwp/.loop-paused` on the ai-host stops it within 30 min |
| loop piles onto a busy shared box (LLM in use, CI job running, low RAM/high load) | resource preflight defers the tick — exit 0, nothing claimed, retried next tick (§2.5b, ops#109) |
| issue spam | idempotent upserts, real-fleet filter, auto-close on green (`.rag-sync-paused` pauses the sync) |
| anything reaching real prod | out of scope of this loop entirely (the ver boundary, ADR-0024) |

---

## 5. Stages of implementation — where we are

| stage | what | status | record |
|---|---|---|---|
| 0 | `pl status` / `pl todo` / `pl audit` (see + know) | ✅ done | pre-ops#2 |
| 1 | `pl rag` grading + `pl issue` CLI (grade + act on tracker) | ✅ done 2026-06-29 | ops#2 |
| 2 | `pl rag --sync-issues` + 04:30 cron (grades become tickets) | ✅ done, running | ops#6 D1 |
| 3 | agent-loop wired to nwp/ops: fix-repo routing, prompt selector, RAG column in `pl status`; live on the ai-host | ✅ done 2026-07-03 | ops#41, MR !38 |
| **4** | **prove + harden (CURRENT)** — see checklist below | ⬜ in progress | — |
| 5 | deploy half: `ver` prod agent, signed-bundle apply, phone/WebAuthn approval | ⬜ future, gated | ops#4/#25, ADR-0024/0026 |

### Stage 4 checklist (the "how to proceed" part — roughly in order)

1. ⬜ **First supervised promotion** (you): pick a low-risk item, label
   `kind::docs` or `kind::config` + `agent-eligible`, watch the next tick,
   review the MR. This proves the whole chain on something harmless.
   (The only red sites, avc/mayo, are the *frozen* fork pins — explicitly not
   promotion material; a real `security-bump` run waits for a fresh advisory
   on a non-frozen site.)
2. ⬜ **Automate the dev-side audit refresh** (the §2.1 gap): a daily
   `pl audit` cron before 04:30, or have met's audit write
   `private/update-awareness/`. Until then, run `pl audit` before trusting a
   grade.
3. ⬜ **Downscope the loop's token**: `~/.nwp-agent-loop.env` currently holds a
   broad api-scope token; now that the loop reaches multiple repos, a dedicated
   bot user with membership only on the mapped projects bounds the blast
   radius (same linchpin concern as ADR-0024 flagged).
4. ⬜ Small fixes: rag-auto issue **titles** don't update on grade flips
   (body/labels do); keep the ai-host's `~/nwp` from going stale again (ssh-config
   entry or a daily pull — it sat 6 weeks behind once).
5. ⬜ **Decommission the dev fallback loop** after item 1 succeeds (remove the
   cron line + env file here), per the 2026-05-22 migration plan.

---

## 6. Driving it — cheat sheet

```bash
# daily glance (RAG dots + provenance footer)
pl status

# full grading detail / refresh the cache
pl rag                       # table; exit 3 if any red
pl audit                     # refresh the security signal first if stale

# the ticket queue
pl issue ls                  # open nwp/ops issues
pl issue show <N>

# promote one to the agent (THE human act)
pl issue label <N> --add "kind::config,agent-eligible"

# watch the loop (on the ai-host; ticks at :00 and :30)
ssh <ai-host> tail -f ~/nwp/logs/agent-loop.log

# EMERGENCY STOP
ssh <ai-host> touch ~/nwp/.loop-paused # loop halts within 30 min
touch ~/nwp/.rag-sync-paused           # stop issue syncing (dev)

# resume
ssh <ai-host> rm ~/nwp/.loop-paused

# agent MR missed the mark? comment on the MR:
#   @agent-loop <what was wrong>   → closes MR, re-queues issue (retry budget 3)

# is the preflight deferring? (a deferring loop and a quiet loop look identical
# except in the log — grep for the reason)
ssh <ai-host> "grep 'PREFLIGHT DEFER' ~/nwp/logs/agent-loop.log | tail -20"
```

### 6.1 ARMING the loop on the ai-host — **operator-run, by hand, only**

These commands are recorded here so the procedure is not folklore. They are
**not for AI sessions to run**: arming the loop is an operator decision (the
A14 boundary starts with you switching it on), and every step below happens
*on the ai-host itself*. The role→machine binding is in
`~/nwp-instances/instance-manifest.yml`, as ever.

```bash
# ── OPERATOR ONLY — run these yourself, on the ai-host ────────────────────
# 0. Preconditions: ~/nwp up to date (git pull), and the loop's token present:
#      echo 'GITLAB_TOKEN=<glpat-…>' >> ~/.nwp-agent-loop.env && chmod 600 ~/.nwp-agent-loop.env
#    (never inline in the crontab — the cron line sources this file).

# 1. Install the cron entries (agent-loop :00/:30, rag-sync 04:30, log rotation):
crontab -l > /tmp/cron.bak
cat ~/nwp/scripts/agent-loop/crontab.entry >> /tmp/cron.bak
crontab /tmp/cron.bak
crontab -l          # verify

# 2. Enable the parts you want (wrapper-enforced switches, host-local state):
pl loop enable fix-loop
pl loop enable respawn-drain
pl loop parts       # confirm

# 3. Remove the whole-loop sentinel LAST — this is the actual arming act:
rm ~/nwp/.loop-paused

# 4. Watch the first tick (next :00/:30) do its preflight:
tail -f ~/nwp/logs/agent-loop.log
#    On a busy box the first thing you'll see is a PREFLIGHT DEFER with the
#    reason — that is the gate working, not a fault. It retries next tick.
```

Disarming is the reverse and faster: `touch ~/nwp/.loop-paused` stops it
within 30 minutes (or `pl loop disable all`); the crontab can stay installed.

Logs: `~/nwp/logs/agent-loop.log` (ai-host and dev), `~/nwp/logs/rag-sync.log`
(dev). Loop state (caps/retries): `~/nwp/.agent-loop.state.json`.

---

## 7. Glossary

| term | meaning |
|---|---|
| advisory | published vulnerability report against a package version range |
| composer / lockfile | PHP's package manager; the lockfile pins exact installed versions |
| cron | the Unix job scheduler; "04:30 cron" = runs daily at 04:30 |
| idempotent | safe to run repeatedly — same end state, no duplicates |
| kill switch | a file whose mere existence makes the next run exit early |
| MR | merge request = GitLab's pull request |
| PAT / token scope | API password; its scope is what it's allowed to do — smaller is safer |
| RAG | Red/Amber/Green status rollup |
| upsert | update-or-insert |
| worktree | extra working directory attached to the same git repo — isolated checkout, shared history |
| A14 | the decision bounding autonomous AI action to the test tier; humans gate merges + real prod |

## 8. Deeper reading

- `~/central/nwc-internal/OPERATING-MODEL.md` — the operating model this implements (private)
- `docs/handover-ops6-self-healing-loop.md` — design + gating rationale for the sync and routing
- `docs/onboarding/agent-loop-primer.md` — the loop internals for PR reviewers (v1 predates the ops#41 routing; §1's "same repo" assumption is superseded by this guide)
- `docs/onboarding/deploy-pipeline.md`, ADR-0017 / 0022 / 0024 / 0026 — the deploy half and its trust boundaries
