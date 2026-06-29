# Handover — nwp/ops#6: wire the §6 self-healing loop

**Session E.** Closes the OPERATING-MODEL §6 gap where `pl rag` grades the fleet
but nothing turns a 🔴/🟠 into a tracked issue, and the agent-loop isn't wired to
`nwp/ops`. Two deliverables: D1 ships (dev-side, safe), D2 is **designed but
gated** (it touches the human-merge / A14 boundary).

---

## Deliverable 1 — `pl rag --sync-issues` (SHIPPED)

Turns the standing RAG backlog into deduped, self-updating `nwp/ops` issues so
the fleet's state lives in one triage queue instead of being re-derived by
eyeballing `pl rag` every run.

### Usage

```
pl rag --sync-issues              # DRY-RUN: print the create/update/close plan
pl rag --sync-issues --execute    # apply the plan to nwp/ops
```

Dry-run is the default (mirrors the `pl onboard` convention). `--sync-issues`
always grades the **full fleet** first (it ignores `--site`/`--json`) and writes
`private/rag/state.json`, then plans the issue upserts from it.

### What it does

- **One issue per non-green real-fleet site.** Idempotency key = labels
  `rag-auto` + `site::<name>`. The loop fetches all open `rag-auto` issues in one
  call and indexes them by `site::` label — it never duplicates.
- **Grade → labels:** 🔴 → `priority::high` + `security`; 🟠 → `priority::medium`.
  On a grade flip the labels are swapped (add the new pair, remove the stale one).
- **Body** is regenerated from the site's advisory count + top todo + todo
  (h/m/l), and carries a machine-readable marker:
  `<!-- rag-auto:v1 site=<s> grade=<G> sec=<N> -->`.
- **Comment only on material change.** "Material" = the marker's `grade` or `sec`
  changed vs. the live state. Unchanged sites are a **noop** (no comment spam on
  the 30-min cadence).
- **Green → close.** A site that goes 🟢 with an open `rag-auto` issue gets a
  "cleared by `pl rag` <date>" comment and is auto-closed.
- **Not `agent-eligible`.** These are triage items for a human until D2 lands.

### The "real fleet" filter (why it doesn't open junk issues)

`pl rag`'s table includes ephemeral CI/test sites (`verify-test-*`,
`bats-test-delete`, `trace-del2`, `hidden`, `dev`, …) that leak into the RAG
state. Syncing all of them would spam ~45 junk issues. `_rag_eligible_sites`
(in `rag.sh`) restricts to:

> configured sites (`discover_sites`, i.e. have `.nwp.yml`) **∪** on-disk sites
> that carry a `pl audit` record but aren't yet `.nwp.yml`-onboarded (this is how
> **`mg`** — a real RED fleet site with no `.nwp.yml` — gets in), **minus** a
> denylist of test/fixture name patterns (`verify-test*`, `bats-test*`,
> `trace-*`, `*-del…`, `tmp`, `latest`).

Eligible sites that are **absent** from the current RAG run (no advisory, no
todo) are treated as green-by-absence — no issue is opened. As of 2026-06-29 the
eligible set is the 18 real sites; the dry-run plans 8 RED creates (avc, ba,
cathnet, dir1, mayo, mg, mt, nwt) + nwc(2) + 5 amber, matching the issue's fleet.

### Code shape

- **`lib/gitlab-issues.sh`** (new) — the authenticated curl plumbing
  (`_host`/`_token`/`_api_get`/`_api_send`/`_jget`/`_require_ok`) was **extracted
  from `issue.sh`** into this sourceable lib so `rag.sh` reuses it instead of
  duplicating the `ops_note_token` handling. Token stays in a 0600 curl config +
  0600 data file — never argv/ps/history. `issue.sh` now sources it (behaviour
  unchanged; verified with `pl issue ls`).
- **`rag.sh`** — `cmd_sync_issues` plans purely in Python (pure data → a JSON
  array of `{act, summary, method, path, payload}`) and **executes in bash** via
  `_api_send`. Planning/execution are cleanly split so the dry-run prints exactly
  what `--execute` would send. `main` captures the grader's exit code (3-on-red)
  around the sync so the sync still runs, then exits with the RAG code.

### Cadence (SHIPPED) — Stage 1 of §6 now runs itself

`pl rag --sync-issues --execute` was being run by hand. It's now wired to run
**daily at 04:30 UTC**, just after the audit-awareness refresh (~04:00), via:

- **`scripts/agent-loop/rag-sync.sh`** — a thin cron wrapper: sets a cron-safe
  PATH (yq lives in `~/.local/bin`), honours a `.rag-sync-paused` kill switch,
  logs to `logs/rag-sync.log`, and treats `pl rag`'s exit 3 (RED present) as
  normal (only a usage/plumbing exit 1 is a cron failure).
- **`scripts/agent-loop/crontab.entry`** — adds the `30 4 * * *` line (and the
  uninstall grep on `/scripts/agent-loop/` still catches it). Installed live on
  the dev workstation.

It reads its token from `.secrets.yml` (least-privilege `ops_note_token`), needs
no env file, and is **dev-side only** — it files/updates/closes issues, never
bumps packages or deploys. This closes the "RAG grades but doesn't open an issue"
half of §6; the issue→agent half stays gated (D2).

---

## Deliverable 2 — agent-loop fix-repo routing (DESIGNED, GATED — do not ship yet)

### Why "add 21 to AGENT_LOOP_PROJECT_IDS" is wrong

`scripts/agent-loop/agent-loop.sh` assumes **issue-repo == fix-repo**:

- it polls `AGENT_LOOP_PROJECT_IDS` (default `16`) for `agent-eligible` issues
  (`:322`), then **clones that same project** (`:378-388`) and adds a worktree;
- the `PROMPT.md` it composes (`:439-560`) is **hardcoded to the nwc Drupal
  install profile** — see the "Repo-specific testing conventions" block
  (`:477-508`): `profiles/custom/nwc/…`, KernelTestBase-vs-Behat, Open Social;
- it opens the MR back on the **same** project.

A `pl rag` red is tracked in **nwp/ops (21)** — a tracker repo with *no code* —
while its fix is a **composer security bump** in the `nwp` / site code repos.
Adding 21 to the list would clone the tracker (nothing to fix) and feed a Drupal
prompt to a bump task → garbage. So two pieces of routing must exist *before* the
loop can act on ops issues, and this is exactly the §6 **human-merge-approval /
A14** boundary (security bumps reach prod) — auto-fix here is deliberately gated.

### D2.1 — issue → fix-repo map

The loop must learn, per ops issue, **where the code lives**:

- Source of truth: the issue's `site::<name>` label → resolve to that site's code
  repo via the existing site config (`sites/<name>/.nwp.yml`'s `ci.repo`, or the
  server resolver). A `rag-auto` security issue for `site::avc` routes its MR to
  avc's repo, not to nwp/ops.
- Split the loop's current single `pid` into **`issue_pid`** (where the issue +
  `agent-eligible` label live — may be 21) and **`fix_pid` / `fix_repo`** (clone
  + worktree + MR target). Today they're conflated in `project_local_path`/
  `project_ssh_url`/the MR POST (`:681`).
- The MR's "Closes" footer points back at the **issue** repo (`Closes
  nwp/ops#<iid>`), while the branch/MR live on the **fix** repo — the same
  cross-repo pattern `pl issue submit` already builds by hand.

### D2.2 — prompt-template selector

Replace the one hardcoded Drupal `PROMPT.md` with a selector keyed on the issue's
work type (a label, e.g. `kind::security-bump` / `kind::config` / `kind::docs` /
`kind::nwc-drupal`), each pulling a template:

| template | task shape | testing convention |
|----------|-----------|--------------------|
| `security-bump` | `composer update <pkg>` to clear an advisory; re-run `composer audit` | audit-clean, no app code touched |
| `config` | edit `.nwp.yml` / nwp.yml site config (e.g. add a missing backup schedule) | `pl verify` for that site |
| `docs` | markdown only | doc-truth-gate (P62) |
| `nwc-drupal` | the **current** profile-nested prompt (`:477-508`) | KernelTestBase / Behat |

Default stays `nwc-drupal` so nothing regresses for project 16.

### D2.3 — gating

- `AGENT_LOOP_PROJECT_IDS` may include 21 **only after** D2.1 + D2.2 land (else
  the Drupal prompt is mis-applied).
- Mark an ops issue `agent-eligible` **only** when the fix is dev-repo-bounded and
  low-risk — e.g. a dev-site core bump, a missing `backups.schedule` config.
  **Never** an outward-facing prod security bump: those keep the human-merge gate
  (the A14 / ADR-0024 boundary). The `rag-auto` issues D1 opens are therefore
  **not** `agent-eligible` by default; promoting one is a deliberate human act.

---

## Verification

- `bash -n` clean on `lib/gitlab-issues.sh`, `scripts/commands/issue.sh`,
  `scripts/commands/rag.sh`.
- `pl issue ls` works post-refactor (the extracted lib is wired in).
- `pl rag --sync-issues` (dry-run) plans 14 actions over the 18-site eligible set;
  the 8 RED creates match the issue's fleet list exactly.
- Planner branches unit-tested against synthetic existing-issue state:
  update+comment (advisory count moved), noop (unchanged), green-close, and
  grade-flip with label swap all produce the correct action list.

**Not yet done (operational, needs human go-ahead):** running `--execute` against
live `nwp/ops` (creates the real issues). D2 is design-only by intent.
