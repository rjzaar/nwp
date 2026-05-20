# Glossary

**Audience:** Coder, decoding vocabulary used in PRs, issues, and the rest of the onboarding docs.
**Status:** v1 — 2026-05-20.
**Read time:** as needed (lookup reference).

Terms grouped by where you'll encounter them. Anything in **bold** is a defined term elsewhere in this glossary.

---

## Community + role terms

**NWC** — Narrow Way Commons. The Drupal-based platform you'll be reviewing PRs for.

**Saint School** (sometimes **SS**) — the affiliated Moodle-based theology curriculum. Lives at `ssc.nwpcode.org` (canonical) and `ssd.nwpcode.org` (demo). NWC and Saint School are paired but separate.

**Sojourner** — a regular NWC member. Can write, comment, propose revisions to content within their permissions. Most logged-in users are Sojourners.

**Steward** — an elevated-trust NWC member. Can access the **Decision Log** at the Stewards tier, approve certain workflow transitions, and is implicitly trusted for governance audits. Smaller group.

**Guild** — a topical group of reviewers. Guilds in NWC: **Pedagogy Guild**, **Theology Guild**, **Copyright Guild**, **Trialing Guild**, **Safeguarding Guild**. Each guild has its own queue of pending **revisions** to review at its stage of the editorial pipeline.

**Trialing Guild** — the guild that runs **revisions** through real classroom use to surface practical issues. Their feedback is classified A1–E3 (see below).

---

## Editorial-pipeline terms

**Artifact** (entity `editorial_artifact`) — the thing being edited. A session plan, a curriculum unit, a doctrine page. Owns a chain of **revisions**.

**Revision** (entity `editorial_revision`) — a proposed change to an **artifact**. Carries a `state` (where it is in the pipeline), a `change_kind` (typo / pedagogical / doctrinal / hotfix), and an author.

**State machine** — the engine in `nwc_editorial/src/Service/EditorialStateService.php` that gates revisions through stages. See [architecture-brief.md §4](./architecture-brief.md#4-the-editorial-pipeline-a30) for the diagram.

**Template** — the rule set that decides which stages a revision skips. `CHANGE_TYPO` skips pedagogy + theology + safeguarding. `CHANGE_HOTFIX` skips in_trial + trialed. Defined in `EditorialRevision` constants.

**Copyright gate** — the requirement that `copyright_cleared` be `TRUE` before a revision can advance out of `in_copyright_clearance`. Enforced in `EditorialStateService::advance()`.

**Trial** — the stage where the **Trialing Guild** uses a revision in a real session before it can go to **in_production**.

**Trial feedback classes** — `A1` through `E3`. Tier maps to outcome:
- `A1`, `A2`, `B1`, `B2` → `fold` (merge silently)
- `B3`, `B4`, `C1`–`C3` → `revise` (kick back to writer)
- `B5`, `D1`–`D3` → `halt` (pause trial, raise to **Theology Guild**)
- `D4`, `D5`, `E1`–`E3` → `escalate` (pause trial, raise to **Stewards**)

**Hotfix** — a revision that skips the trial stages. Used for live-production issues that need to bypass slow review. `markAsHotfix()` records justification; required.

---

## Governance + audit terms

**`governance_action`** — Drupal entity that audits every state change, every approval, every deploy. Found at `/admin/reports/governance-actions`. Never removed by a PR — only added to.

**Decision Log** — public-facing log of which **revisions** went through, who reviewed, when. Has visibility tiers (Stewards / Members / Public) per ADR-0010.

**ADR** — Architecture Decision Record. Each one numbered (ADR-0001, ADR-0015, etc.) and lives at `~/nwp/sites/nwc/dev/html/profiles/custom/nwc/docs/decisions/`. See [adrs.md](./adrs.md) for the list with summaries.

**Self-flag** — a `⚠` marker the agent should add to a PR description when its change touches sensitive surface (auth, schema, ADRs, governance). Missing self-flags = reviewer (you) re-classifies up.

---

## Cross-site terms

**Paired sites** — sites that share a tier (canonical or demo) across stacks. Drupal canonical (`nwc`) is paired with Moodle canonical (`ssc`). Demo `nwd` is paired with `ssd`.

**Cross-site POST** — a request from Moodle (Saint School) → Drupal NWC, or vice versa, that bypasses normal browser session auth. Uses a shared secret in the `X-NWC-Shared-Secret` header.

**`_oauth_skip_auth`** — a Drupal route flag that tells `simple_oauth`'s authentication provider to leave the request alone (otherwise it 401s before the controller fires). Required on cross-site POST routes.

**Copyright sync** — the Moodle plugin `local-nwc-copyright-sync` pulls the copyright policy text from NWC and writes it into Moodle's `tool_policy_versions` table. Schema-defensive because Moodle 4.4 moved the `name` column.

**OAuth bridge** — `nwc_oauth_bridge` (Drupal) + `auth-nwc-oauth2` (Moodle). NWC is the OAuth issuer; SS is the client.

---

## Deploy terms

**`pl`** — short for "pipeline". The in-repo deploy helper. Subcommands: `dev2stg`, `stg2live`, `rollback`, etc.

**dev** — your local DDEV instance running on your laptop. (`https://nwc-dev.ddev.site/`.)

**stg** — staging. Internal-only URL, usually `nwc-stg.nwpcode.org` (TLS, accessible to team). Mirror of live with anonymized data.

**live** — production. `nwc.nwpcode.org` + `nwd.nwpcode.org` + `ssc.nwpcode.org` + `ssd.nwpcode.org`.

**Snapshot** — the mysqldump + nginx config bundle taken before every `stg2live`. Used by `pl rollback execute <profile> prod`. Lives at `/var/backups/nwc-snapshots/<timestamp>/`. Last 14 kept. Use `pl rollback list` to see them.

**Smoke check** — a 5-URL HTTP probe after every live deploy. See [deploy-pipeline.md §3](./deploy-pipeline.md#3-the-5-url-smoke-check). Auto-rolls-back on failure.

**Tier** — `T1` / `T2` / `T3`. Decides how much the agent (and you) should scrutinize a PR, and whether it auto-deploys to live or stops at stg. See [pr-review-checklist.md §3](./pr-review-checklist.md#3-test-coverage-per-tier).

**CMI** — Configuration Management Initiative. Drupal's config import/export system. PRs that touch CMI files (`config/sync/*.yml`) require `drush cim` on deploy, which `pl stg2live` runs automatically.

---

## Agent-loop terms

**Agent loop** — the cron-driven pipeline on `mini` that polls GitLab for `agent-eligible` issues, spawns a headless Claude Code session per issue, lets it produce an MR, and waits for human (your) approval.

**Kill switch** — the file `/home/rob/nwp/.loop-paused` on mini. If present, the loop logs "paused" and exits without spawning. See [rollback-playbook.md §2](./rollback-playbook.md#2-pausing-the-agent-loop).

**`agent-eligible`** — GitLab label on an issue. The loop only picks up labeled issues. Removing the label parks an issue indefinitely.

**`needs-human`** — GitLab label that prevents the loop from picking up an issue. Use this for design-shaped issues, security questions, anything the agent shouldn't try.

**Headless Claude Code** — `claude -p '<task>' --dangerously-skip-permissions`. The same Claude Code you've been using, run non-interactively in a script. Not the Anthropic API.

**Worktree** — a git worktree (separate working dir on a branch, shared `.git`). The loop creates one per spawn so multiple Claude sessions can run in parallel without stepping on each other.

**Per-issue retry cap** — the loop will spawn Claude on the same issue at most 3 times. After that, the issue is marked `needs-human` automatically.

**Daily PR cap** — the loop will create at most 5 MRs per UTC day. Beyond that, it queues. Tunable via `AGENT_LOOP_DAILY_CAP` env var.

---

## Repo + branch terms

**`nwp/nwc`** — the repo containing the install profile + custom modules. Your PR review homebase. See [repo-map.md](./repo-map.md).

**Install profile** — Drupal's term for a deploy unit: site config + a list of modules + initial content. The `nwc` profile is what `nwc.nwpcode.org` runs.

**Install-artifact** — files Composer or scaffolding generates (`vendor/`, `html/core/`, `web/sites/default/files/`). These should never be in a PR diff. If you see them, it's a smell.

**`auth.json`** — Composer's credentials file. Contains `glpat-*` tokens; **must never be committed**. Gitleaks blocks accidental commits; you should still eyeball every diff.

---

## Tooling terms

**DDEV** — the local Docker-based dev environment. `ddev start`, `ddev exec`, `ddev logs`. Each project gets its own DDEV instance: `nwc-dev`, `nwd-dev`, `ssc-dev`, `ssd-dev`.

**Gitleaks** — pre-commit + CI secret scanner. Configured at `~/nwp/.gitleaks.toml` with custom rules (`operator-home-path`, `internal-bare-hostname`, etc.). Allowlist at `~/nwp/.gitleaksignore`.

**Behat** — BDD test runner; Gherkin scenarios. See [testing.md §3](./testing.md#3-the-behat-suites-that-exist).

**PHPUnit** — unit + kernel test runner. See [testing.md §4](./testing.md#4-the-behat-suites-that-exist).

**Drupal Extension** — Behat plugin that adds Drupal-aware steps (`Given I am logged in as a user with the "X" role`).

**Drush** — Drupal CLI. You'll see it in deploy scripts (`drush cr`, `drush cim`, `drush nwc-feedback:sync-to-gitlab`).

---

## See also

- [architecture-brief.md](./architecture-brief.md) — the platform vocabulary in context
- [pr-review-checklist.md](./pr-review-checklist.md) — how these terms show up in review
- [adrs.md](./adrs.md) — formal definitions of the architectural pieces
