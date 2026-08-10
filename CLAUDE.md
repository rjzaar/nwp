# Claude Code Instructions

> **READ-FIRST (operating model):** before any ops work, read
> `~/central/nwc-internal/OPERATING-MODEL.md` (the self-driving operating model +
> session-start protocol). **Work is tracked as GitLab issues in `nwp/ops`**, not docs.
> **Oversight = `pl rag`** (per-site Red/Amber/Green fleet rollup). Execution runbooks live
> in `~/central/nwc-internal/`. Don't re-derive what those already assert; verify any
> unstated claim against live code before acting.

This file provides specific instructions for Claude Code when working on this project.

## Project Identity

**NWP — Narrow Way Project.** This is the permanent name of the project. It will never be renamed. NWP is a Drupal hosting, deployment, and infrastructure automation tool. Any proposals to rename the project (e.g., P52) are permanently rejected.

## ⚠️ LIVE IS NOT PROD — you may work on live freely

**Operator instruction, 2026-08-02, stated twice and asked to be made permanent:**

> *"You have full access on live. Prod doesn't exist yet."*
> *"this is live not prod … so you can touch it since no actual user data is involved."*

**LIVE = today.** `nwd`, `ssd`, `nwc` and `ss` all run on the live box. They serve real HTTP
to real browsers but hold **no real user data** (measured 2026-08-02: nwc 1 non-admin
account, ss 4 — fixtures). **Work on them freely.** Do not refuse a task on nwc/ss because it
"looks like production"; that reasoning is stale and blocks legitimate work. The care that
still applies is ordinary care: back up first, record old values, write a rollback row, go
through a `pl` verb.

**PROD = does not exist yet.** It is created in **Phase 2**, provisioned from `ver` running
nwp code with **no AI**, and is the first moment real users and real user data exist. The
mons/`ver` boundary and the retraction of AI write access become real **then** — everything
below in this Threat Model describes that future state and remains correct for it.

**The rule for any guard or automation you write:** key off the **per-site canonical phase**
(`pl canonical`, `dev|live|prod` — ops#33), **never off a site's name**. "Refuse nwc and ss"
is wrong today (it blocks real work) and wrong later (it would miss a new prod site). "Refuse
a site whose canonical phase is prod" is inert today, correct forever, and arms itself the
moment `pl canonical set <site> prod` runs. Give such a guard a test proving it REFUSES
against a fixture marked prod — an inert guard nobody has seen fire is the
"check that has never been proven to fail" class (ops#214).

Programme phases: `~/central/PROGRAMME-PHASES-2026-08-02.md` · ops#203.

## Threat Model

> **Read the section above first.** This Threat Model describes the posture for **prod**,
> which does not exist yet. It is not a reason to refuse work on the live tier today.

NWP operates under a **paranoid + open-source + local-first** threat model. When suggesting tools, architectures, or workflows, defer to these assumptions rather than reasoning from generic industry defaults.

### Trust Assumptions

- **Third-party SaaS is distrusted by default.** Prefer self-hosted, open-source alternatives even when they require more setup (e.g., Headscale over Tailscale, Gotify over Pushover, GitLab self-hosted over GitLab.com).
  - **Bounded SaaS exception for PSTN voice/SMS access** — see [ADR-0018](docs/decisions/0018-twilio-bounded-saas-for-pstn.md). The `prefer self-hosted` rule holds everywhere else; this is the single documented exception, scoped to the audio transport layer only. Do not cite ADR-0018 as a precedent for other SaaS additions — each is evaluated on its own merits.
- **AI agents (including Claude) are distrusted for production access.** No AI-run machine may hold a key that reaches a production server. AI's blast radius is bounded to dev/stg/live and CI.
- **Hardware-rooted keys for irreversible actions.** Anything that writes to prod must be gated by a hardware security token with user presence + PIN (Solo 2C+ NFC, Trussed-based open firmware — YubiKey is explicitly rejected due to closed firmware).
- **Trust flows through signatures, not machines.** Artifacts are trusted because they carry a valid minisign signature from a known key, not because they came from a "trusted" host. This is the load-bearing property that lets an AI-driven build host (mmt) feed an air-gapped deploy host (mons) without compromising prod.

### Distributed Actor Glossary

| Actor | Location | Runs AI? | Prod access? | Role |
|-------|----------|----------|--------------|------|
| dev workstation (this machine) | home | yes (Claude) | no | Authoring, signed commits |
| met (metabox) | home | yes | no | CI/CD runner, heavy builds |
| mini (Beelink 395) | home | yes (local LLM) | no | Day-to-day agent, routine tasks, monitoring |
| mmt (met + mini team) | home | yes | no | Combined build/test/sign tier |
| mons (offline-by-default laptop) | home | **no** | **yes** | Verifies signed artifacts, deploys to prod via dedicated WireGuard tunnel, creates bug reports back to mmt |
| git.nwpcode.org | au-mel Linode | no | no | Code + artifact distribution (GitLab + Packages) |
| **live box** (nwd, ssd, nwc, ss) | us-iad Linode | n/a | **n/a — not prod** | **Today's live tier. No real user data. AI may work on it freely — see the section above.** |
| prod servers (future) | us-iad Linode | no | yes (from mons only) | Created in Phase 2 from `ver`; the row above becomes this once `pl canonical set <site> prod` runs |

### Practical Implications for AI Suggestions

- **Never propose a path where an AI-accessible machine writes to prod.** The mons boundary is inviolable. If a workflow seems to require it, the workflow is wrong.
- **The sanitizer is security-critical.** Sanitization happens on the prod server (raw user data never leaves prod). Any change to sanitization scripts requires explicit human review — treat it with the same scrutiny as authentication code.
- **Signed commits and signed artifacts are mandatory, not optional.** Don't suggest workflows that bypass verification "for convenience."
- **Don't expose SSH to the public internet.** External access is via Headscale VPN only. Never propose opening port 22 on home routers or cloud hosts.
- **Don't put mons on the Headscale mesh.** mons is offline by default and connects only while actively deploying, via a phone hotspot or dedicated cellular modem — never via the home LAN and never as a Headscale member alongside met/mini. During deploys mons reaches `git.nwpcode.org` over public HTTPS (with signature verification) and reaches prod through a dedicated one-to-one WireGuard tunnel where mons and prod are the only peers and prod's sshd binds only to the tunnel interface. Don't suggest adding mons to Headscale or putting its traffic over the home router.
- **Prefer open-source, self-hosted, local-first tools** when recommending new infrastructure. If a SaaS is the only reasonable option, flag the trade-off explicitly.

See [ADR-0017: Distributed Build/Deploy Pipeline](docs/decisions/0017-distributed-build-deploy-pipeline.md) for the full architecture and rationale.

## STANDING ORDER: everything goes through `pl`

**Operator order, 2026-07-28. Permanent. This one is not negotiable for convenience.**

If a `pl` verb exists for what you are about to do, **use it**. If a `pl` verb *should*
exist and does not, or exists and is broken for your case, **fix the verb** and use the
fixed verb — do not step around it. Ultimately every operation on this estate is performed
by a `pl` command.

**What "stepping around it" looks like** (all of these are violations, not shortcuts):

```bash
# NO                                          # YES
scp file host:/tmp && ssh host 'sudo cp …'    pl moodle plugin deploy <site> <plugin> --tier=live --apply
ssh host 'sudo -u www-data php … drush …'     pl drush <site> --tier=live --execute -- <args>
ssh host 'sudo -u www-data php admin/cli/…'   pl moodle cli <site> --tier=live --execute -- <script>
ssh host 'tail /var/log/nginx/…'              pl logs <name> --source=nginx --tail=200
ssh host 'free -h; uptime'                    pl server health <name>
```

**Why this is a rule and not a preference.** The `pl` verbs are where the guarantees live:
the dry-run default, the typed live confirm, the `live.enabled` check, the ADR-0028 deploy
gate, `pair_guard`, the fate manifest, the rollback ledger, the no-secret-printing rule,
the php-version and `max_input_vars` assertions that stop a Moodle upgrade from stranding a
site in maintenance mode. A hand-rolled `ssh`+`sudo` one-liner reproduces the *effect* of a
verb while silently dropping every one of those. `lint:doc-truth`'s `raw-remote-cli` check
already fails any runbook that prescribes the raw idiom; this rule says the same thing
about what you actually *run*.

**When the verb does not fit, that is a bug report, not a licence.** Write the verb, or
extend it, red-then-green, as its own REVIEW MR. A gap you route around stays a gap
forever; a gap you fix is fixed for every future session and for the operator.

**Recorded failure, so the next reader believes the rule:** on 2026-07-28 the ops#149
depthcontent XSS fix was deployed to live `rgs` with `scp` + `sudo cp` + a raw
`admin/cli/upgrade.php`. It worked, was backed up and verified — and it still bypassed
`pl moodle plugin deploy`'s guard chain and left no rollback-ledger entry. The correct
command existed the whole time (`--from=DIR` is a supported flag). Doing it by hand is how
the estate acquires operations that only one session knows how to repeat.

**The one exception is read-only reconnaissance** for which no verb exists yet — e.g.
enumerating served nginx roots before `pl server roots` was written. Take the reading, then
*write the verb*, which is exactly how `pl server roots` came to exist.

## STANDING ORDER: ONE reviewer today — and `approvers:` is the whole switch

**Operator ruling, 2026-08-06, stated twice and asked to be made permanent:**

> *"The current system is just you and me. We don't need the extra overhead of two
> checks for now. It should only be happening once I approve the shift and there is
> a second human dev in the system. Until then I should be able to approve/merge
> once and only in one spot which is the MR location."*

**The number of humans who review a change is declared ONCE**, as `approvers:` in
`private/secrets-registry.yml`. Everything reads it through one accessor,
`_mr_approver_count` → `_mr_review_mode` in `lib/gitlab-mr.sh`.

| `approvers:` | mode | what it means |
|---|---|---|
| one name | `solo` — today | Clicking **Merge on the MR page** is the whole approval. No release step; `pl mr release` is unnecessary and `--merge` is refused, because a shell would be a second approval spot. A sensitive-path MR is **reported** — here and as a note on the MR — not held. |
| two or more | `team` | A sensitive-path MR is **held as Draft** until somebody who is **not** its author records a release bound to the head commit. |

**Adding the second name is the entire switch.** It is simultaneously the operator
approving the shift and the second human dev existing — the two conditions of the
ruling above — so there is no flag to remember, and no way to be in team mode with
nobody available to be the second pair of eyes. This is the same declared-fact
pattern `cmd_release`'s ADR-0028 dispensation already used: *"inert today, correct
forever, and it arms without anyone remembering to arm it."*

**`.nwp-review-mode` is a GENERATED PROJECTION, not a policy.** `private/` is a
separate repository, so a CI job cannot read the registry at all. The count is
projected into that tracked file so CI can see it; **the registry wins wherever it
is readable**, and a pre-commit hook refuses to commit a projection that disagrees.
Regenerate with `pl mr review-mode sync`. Never hand-edit it to change behaviour —
there is deliberately no `pl mr review-mode set`, and asking for one is an error
that explains why.

**Do not add a second reader, a config option, a per-project override, or an "if
it's sensitive then two people" special case.** `tests/unit/test-review-mode.bats`
fails if a second reader of the fact appears. A policy expressed in several places
is a policy that drifts, and the operator asked specifically that this not "drift
back into complexity".

**What does NOT change between the modes** — and it is why solo is safe:

> **A machine never merges. A human merges.**

Auto-merge is disarmed in both modes, and every verb that could merge refuses when
the token's **forge-verified** identity is a bot (`_mr_merge_actor_ok`). Solo mode
removes the *second* human, never the human. The 2026-08-01 incident was a sweeper
merging an MR nobody had approved; nothing here relaxes that. **You — the AI — hold
a bot token, so you cannot merge in either mode. That is deliberate: propose, and
let the operator click.**

**Do not "helpfully" restore two-person review.** If a gate feels too permissive,
that is the operator's call to make by adding a name to `approvers:`, not a special
case you add to a verb.

**Fail-closed direction:** no readable registry, no projection, or an unrecognised
value reads as **`team`**, the stricter mode. The tempting default is today's, but
then a typo or a bad checkout silently switches the estate to single-approval — the
permissive direction. `pl mr review-mode` reports **NOT DECLARED** in that case, so
"I could not read the policy" never looks like a decision somebody made. This
nearly bit for real: `.nwp-review-mode` was silently gitignored on first writing
(the root `.gitignore` denies `/*`), so it would have been present locally and
absent in CI — and because the fallback is `team`, that surfaced as CI holding
everything rather than as two-person review silently switched off.

See [ADR-0037](docs/decisions/0037-review-mode-follows-approvers.md) (renumbered from a duplicate 0032, ops#319).

## STANDING ORDER: a check that has never been proven to fail is not a check

**Recorded 2026-08-02, after one night found SIX of them.** Before you believe a
green tick — yours or one already in the tree — ask when that check was last
*observed red*. If the answer is "never", you have a hypothesis, not a gate.

Every fix in this repo is **red-then-green with real counts**: write the case that
fails against the current tree, run it, quote the failure, then fix, then re-run.
"I added a test and it passes" is not evidence; a test written after the fix has
never been shown capable of failing.

| Question | Command |
|----------|---------|
| Which gates have ever been proven RED? | `pl verify gates` |
| Machine-readable verdicts | `pl verify gates --list` |
| Which checks assert less than they look? | `pl verify honesty` (`--list` for all findings) |
| Record a gap deliberately (shrink-only) | `… --update-baseline`, and say why in the commit |

The four shapes the lints catch, all found live:

- **Blind negation.** `! pl install '<payload>' 2>/dev/null` proves only "exited
  non-zero". `pl install` exited 1 for an unrelated reason and seven security
  checks went green over a tree with no input validation at all. **Assert the
  error text**: `pl install d 'bad name' 2>&1 | grep -q 'Invalid site name'`.
- **Swallowed verdict.** `updates=$(drush pm:security … || echo "[]")` turned a
  removed-subcommand error into "no security updates". A check may not substitute
  a literal for a measurement it failed to take — it must fail, or report
  CANNOT VERIFY.
- **Skips.** bats scores a skip as `ok`. `tests/.skip-budget` caps runtime skips;
  `.test-honesty-baseline` caps skip statements at source. Both shrink-only.
- **Host-blind branches.** `command -v restic || return 0` before validating the
  argument accepted `--restic-provenance=trustme` on every host without restic.
  Either fail closed, or add an `NWP_*` knob so the absent-tool path is testable.

**Fail-closed is the default everywhere.** An unreadable corpus, a missing tool,
an empty input: exit 2 CANNOT VERIFY, never exit 0. `pl server health` already
works this way (exit 3 when it cannot measure) and it is the estate rule, not
that command's quirk. Grade an exit-2 AMBER; never count it as a pass.

**Baselines are shrink-only, and growing one is a recorded decision.** Deleting a
row is a fix. Adding a row says "this goes in blind, on purpose, and here is why"
— put the why in the commit message. Never add a `.yq-first-baseline` row.

### Merge automation: this GitLab's `detailed_merge_status` goes stale

**Verified 2026-08-02 by local test-merge.** The API reports
`detailed_merge_status: conflict` for branches that merge cleanly. The value is a
cached computation, and it is not always recomputed when the target branch moves.

Rules for anything that automates merges:

- **Never trust `conflict` on its own.** Poke it first —
  `PUT /projects/:id/merge_requests/:iid/rebase` forces GitLab to recompute — or
  settle it locally with a real test-merge (`git merge --no-commit --no-ff`, then
  `git merge --abort`). Only a *reproduced* conflict is a conflict.
- **`checking` means retry, not failure.** Poll it; do not classify it.
- **If a `pl` verb ever merges MRs, this logic belongs inside the verb**, with
  its own red-proof — not in a session's shell loop, where the next session
  re-derives it wrongly. Same standing order as everything else: fix the verb.

## Critical: Protected Files

### nwp.yml - NEVER COMMIT

The `nwp.yml` file contains user-specific site configurations and **must never be committed to git**.

- **NEVER add nwp.yml to git staging**
- **NEVER commit nwp.yml**
- **NEVER include nwp.yml in any commit**

If you need to make changes to the nwp.yml schema or add new default options, make those changes to `example.nwp.yml` instead.

### Why?

- `nwp.yml` is in `.gitignore` for a reason
- Each user has their own local site configurations
- `example.nwp.yml` serves as the template for new installations
- Users copy `example.nwp.yml` to `nwp.yml` and customize it

### Correct Workflow

1. New options, structure changes, documentation -> Edit `example.nwp.yml`
2. User-specific site data -> Only in `nwp.yml` (never committed)
3. When asked to update "the config", clarify: example.nwp.yml for templates, nwp.yml for user testing only

### Propagating Changes to nwp.yml

When you make changes to `example.nwp.yml` (adding new options, updating defaults, etc.), you **MUST** offer to update the user's `nwp.yml` with the same changes:

1. After editing `example.nwp.yml`, ask: "Would you like me to update your nwp.yml with these changes?"
2. If yes, apply the changes to all relevant sections in `nwp.yml`:
   - New recipe options -> Update all sites using that recipe
   - New settings -> Add to the settings section
   - New defaults -> Offer to apply to existing sites
3. Remember: You can READ and EDIT `nwp.yml` - just never COMMIT it

### sites/tmp/ — NEVER CREATE

Do **not** create `sites/tmp/` or any project beneath it (e.g. `sites/tmp/foo`, `sites/tmp/scratch`). This applies to DDEV projects, scratch directories, throwaway test fixtures, anything.

- For test fixtures, use the existing test layout under `tests/` or `.verification-scenarios/`.
- For ad-hoc scratch work, use `/tmp/` outside the repo, not `sites/tmp/`.
- If a workflow seems to require `sites/tmp/`, the workflow is wrong — ask the user before improvising a new top-level path under `sites/`.
- After any `ddev config` you initiate, you are responsible for `ddev delete --omit-snapshot --yes` on completion or failure, *before* the session ends — `ddev stop` alone leaves orphan Docker volumes and built images that survive session crashes.

Why this rule exists: on 2026-01-16 an autonomous P50-verification session created `sites/tmp/malicious` and `sites/tmp/malicious1` as negative-test fixtures, then crashed (the 7.3 GB conversation log corrupted). The directories were eventually deleted but the orphan Docker volumes and images survived for four months before being noticed.

## Two-Tier Secrets Architecture

NWP uses a two-tier secrets system that allows you to help with infrastructure while protecting user data:

### Files You CAN Read

| File | Contents | Why Safe |
|------|----------|----------|
| `.secrets.yml` | API tokens (Linode, Cloudflare, GitLab) | Infrastructure automation only |
| `.secrets.example.yml` | Template with empty values | No real credentials |
| `.env`, `.env.local` | Development settings | Local dev only |

### Files You CANNOT Read (Blocked by deny rules)

| File | Contents | Why Blocked |
|------|----------|-------------|
| `.secrets.data.yml` | Production DB, SSH, SMTP | Access to user data |
| `keys/prod_*` | Production SSH keys | Server access |
| `*.sql`, `*.sql.gz` | Database dumps | User data |
| `settings.php` | Drupal credentials | Production access |

### Using Secrets in Scripts

When helping with scripts, use the appropriate function:

```bash
# Infrastructure secrets (you can help with these)
token=$(get_infra_secret "linode.api_token" "")

# Data secrets (you should not access these)
db_pass=$(get_data_secret "production_database.password" "")
```

### Safe Operations

For operations needing data secrets, use the `pl` verbs that return sanitized output.
They read the tracked `servers/<name>/.nwp-server.yml` route, never a credential you
have to handle:

```bash
pl server status <name>        # SSH reachability only
pl server health <name>        # load / memory / disk HEADROOM — no credentials
pl server health --all         # every configured server
pl server forge status <name>  # forge package version + apt key expiry
pl logs <name> --source=nginx --tail=200   # read-only, clamped, fixed source set
pl audit <site> --security-only            # advisory counts, no DB contents
```

**`pl server health` is a REQUIRED PREFLIGHT** before anything heavy on a shared box.
`git.nwpcode.org` has 3.8 GB of RAM and serves GitLab plus five live sites; on
2026-07-25 a heavy op OOM-killed it for 5-8 minutes. `health` exits 1 with no
headroom and **3 when it cannot measure** — an unmeasurable host is never treated as
healthy. Never run `gitlab-rails`/`gitlab-rake` on that box.

> **Retired 2026-07-26:** `lib/safe-ops.sh` and its `safe_server_status` /
> `safe_db_status` / `safe_security_check` helpers. That library had **zero callers
> anywhere in the tree** and told you to run `./stg2prod.sh` and `./backup.sh`, root <!-- doc-truth:retired -->
> scripts that do not exist. Standing orders that point at dead code read as coverage.
> `tests/unit/test-host.bats` now fails if any `lib/*.sh` named in this file has no
> production caller.

See `docs/security/data-security-best-practices.md` for the full security architecture.

### Token & secret lifecycle — the registry is the source of record

**Before doing ANY work on a token/secret** (creating, rotating, revoking, wiring
a new consumer, debugging an auth failure), consult the tokenless registry
`private/secrets-registry.yml` and use the `pl secrets` tooling — never hand-roll,
and never guess a token's identity, scope, expiry, or storage location:

| Need | Command |
|------|---------|
| What exists, expiry, rotation status | `pl secrets status` |
| Is a token actually alive? real expiry? drift? | `pl secrets audit` (live probe; `--sync` fixes recorded drift) |
| Who owns a GitLab token (revoked?) | `pl secrets whose <#\|id>` |
| Exact reissue procedure for one entry | `pl secrets steps <#\|id>` |
| Reissue/rotate (hidden entry, propagates to every `stored_in`, logs it) | `pl secrets rotate <#\|id>` |
| Which code/functions read a token | `pl secrets consumers [--write] [--strict]` → `private/token-consumers.md` |
| Structure of `.secrets.yml` without values | `pl secrets keys` |
| Is every declared copy actually in sync? | `pl secrets audit --locations` (one row per `stored_in`) |
| Propagate canonical to every copy (repair) | `pl secrets sync <#\|id>` |
| Is there a copy nobody declared? | `pl secrets discover-copies` |
| Check a copy on another host (by hash, over ssh) | `pl secrets verify-copy <#\|id>` |
| Which token can create an MR / manage CI vars? | `pl secrets capabilities` |
| Register a `.secrets.yml` key lint says is undeclared | `pl secrets adopt <dotted.key>` |
| Bring an old registry up to the `stored_in` grammar | `pl secrets migrate-registry [--apply]` |
| Make an entry's SCOPE claim checkable (incl. negative "must NOT reach X") | `pl secrets probe-scaffold <#\|id\|--all>` |
| Put the registry under version control (nested private repo) | `pl secrets registry-track` |
| Provision the daily audit by code, here or on a remote role | `pl secrets cron install [--host=<role>]` · `cron status` |
| Would a rotation stamp honestly right now? (no prompt, no write) | `pl secrets rotate <#\|id> --dry-run` |
| **A credential's VALUE was seen — record it, rotation becomes OWED** | `pl secrets expose <#\|id> --reason='…' [--where=…] [--ref=ops#N] [--closed] [--adopt=<provider>]` |
| What is owed right now (what blocks going to prod) | `pl secrets debt [--all] [--json]` |

Rules:
- **An exposure is recorded against the CREDENTIAL, never only in an issue.**
  Operator ruling D8 (2026-08-01): *"Exposures need to be logged in the todo list
  so they can be rotated when I get to it and must be done before prod site
  starts."* One command records it (`--adopt` covers credentials the registry
  does not know yet — 3 of the first 4 real exposures were undeclared). It then
  appears in `pl todo`, reddens `pl rag`, and **fails a prod bring-up closed**:
  `pl canonical set <site> prod` and every prod write through the ADR-0028 gate
  (`pl stg2prod`, `pl live2prod`) REFUSE while any debt is open, naming the
  entries. `NWP_ROTATION_DEBT_OVERRIDE="<why>"` is the only way past and it is
  ledgered to `private/rotation-debt-overrides.log`.
- **A closed surface is NOT a rotation.** Redacting the doc / deleting the
  transcript sets `closed:`; only `pl secrets rotate` / `pl secrets done` — which
  already refuse to stamp while declared copies disagree — set `rotated:` and
  discharge the debt. Hand-editing `rotated: true` fails `pl secrets lint` with
  `EXPOSURE-UNBACKED` unless the entry's rotation history corroborates it.
- **Every token has three names** — the `.secrets.yml` key, the registry `id`, and
  the live GitLab bot/token name. Use the crosswalk in the registry / `~/central/TOKEN-REGISTRY-*.md`; don't conflate them.
- **`.secrets.yml:gitlab.api_token` is NOT the root admin PAT.** That claim is stale.
  Since the 2026-07-18 ADR-0024 cutover the slot holds the non-admin group bot
  `group_9_bot` / `nwp-automation-dev` (`is_admin: false`, Developer). It **can**
  create merge requests on `nwp/nwp`; it cannot manage deploy keys, CI variables or
  project access tokens. Don't route work around it on the assumption that it is
  root, and don't treat it as root-equivalent. Verify with `pl secrets capabilities`,
  never from memory.
- **`stored_in` is a grammar, not prose.** `<path>:<ref>` · `host=<role>:<path>:<ref>` ·
  `external:<text>`. Anything else is a lint error, because a location the tooling
  cannot parse is a location it silently stops checking. Notes go in `stored_in_notes:`.
- **Recording a rotation requires having propagated it.** `pl secrets done` AND
  `pl secrets rotate` both refuse to stamp `last_rotated` while any declared copy still
  holds a different value. Check before you start: `pl secrets rotate <id> --dry-run`.
- **A declared scope must carry a `probe:`.** `pl secrets lint` fails with `NO-PROBE`
  otherwise, because a capability the registry never checks is folklore — that is how
  "can destroy every prod Linode" came to be recorded against a DNS-only token. Probes may
  be NEGATIVE (`expect: 401/403` = "must NOT reach this"), which is the only way to record
  a *limit* so that widening it goes red.
- **A blind audit is not a clean audit.** `pl secrets audit` retries, then reports
  `AUDIT-BLIND` and returns 2 without stamping `last_successful_audit`. Never treat exit 2
  as a pass; grade AMBER.
- **Admin and backup-decryption credentials do not belong in `.secrets.yml`.** It is the
  tier this file tells you that you MAY read. `pl secrets lint` fails with `TIER:` on them;
  moving one to `.secrets.data.yml` is an OPERATOR action (you are deny-ruled from it).
- **After any token change**, the registry must reflect reality: `pl secrets rotate`/`done`
  stamps `expires`/`last_rotated` and appends `private/rotation-YYYY-MM.md`; if you
  add/retire a token or change where it's stored or read, update its entry
  (`stored_in`) and regenerate `pl secrets consumers --write`.
- **Never print a token value** — use the 0600-curl-config pattern (see `cmd_whose`);
  read structure with `pl secrets keys`, copy with `pl secrets get` (clipboard).
- Values live in `.secrets.yml` / `~/.nwp-agent-loop.env` / per-host `~/.config/*.token`;
  the registry holds only metadata. A daily `pl secrets audit` (via `pl todo`'s
  `check_token_liveness` + `scripts/secrets-daily-audit.sh`) catches dead/expiring tokens.

## Other Protected Files

- `.env` files - Never commit environment secrets
- Any file in `.gitignore` - Respect the ignore patterns
- `.secrets.data.yml` - NEVER read, contains production credentials

## Project Structure

- `lib/` - Shared bash libraries
  - `lib/project-resolver.sh` - Site path/config resolution (`resolve_project`, `get_backup_dir`, `get_site_config_value`, `discover_sites`); auto-sourced via `lib/common.sh`
  - `lib/server-resolver.sh` - Server resolution (`resolve_server`, `get_server_ip`, `get_server_ssh_command`, `discover_servers`, `get_server_sites`); auto-sourced via `lib/common.sh`
  - `lib/migrate-schema.sh` - Schema migration framework for `.nwp.yml`, global `nwp.yml`, and `servers/*/.nwp-server.yml`
  - `lib/migrations/{site,global,server}/` - Numbered migration scripts (one function `migrate_NNN_to_MMM` per file)
- **Recipes** — there is **no `recipes/` directory**. Recipes live in two places:
  - the `recipes:` block inside `nwp.yml` (template: `example.nwp.yml`, which ships only `pod`;
    the fuller catalogue is in `example.nwp.v2.yml` / an operator overlay)
  - project-shipped `sites/<recipe>/recipe.yml` (see `lib/install-common.sh`)
  - list what your install actually offers with `pl install --list`
- `sites/` - Each site uses v2 nested layout (F17 + F23):
  - `sites/<name>/.nwp.yml` - Site-level config (schema v2); `project.*`, `live.*`, `environments`, `backups.directory`
  - `sites/<name>/dev/` - Development DDEV project (`<name>-dev`); `.ddev/`, `web/`, `composer.json`, env-level `.nwp.yml`
  - `sites/<name>/stg/` - Staging DDEV project (`<name>-stg`); live-enabled sites only; sanitised live DB
  - `sites/<name>/backups/` - Per-site database backups (shared, outside DDEV/git)
  - `sites/<name>/scripts/` - Maintenance scripts (shared, outside DDEV)
  - `sites/<name>/dev/pipeline/` - Project-specific Python pipelines (mt, cathnet, fin)
  - Per-site proposals live inside each site's profile repo (e.g. `sites/avc/dev/html/profiles/custom/avc/docs/proposals/`); aggregated by `pl proposals`
- `servers/` - Per-server infrastructure (F17 Phase 8, formerly F23):
  - `servers/<name>/.nwp-server.yml` - Server identity (gitignored plaintext; SOPS-encrypted version comes with F18)
  - `servers/<name>/{email,linode,nginx,demo}/` - Generic mechanism: installers, hooks, snippets, provisioning scripts. **Engine-tracked.**
  - `servers/<name>/{nginx/conf.d,system,php,postfix,letsencrypt}/` - Per-host **IDENTITY**: vhosts with real domains, the operator crontab, mail aliases, ufw, authorized keys, inventories. **NOT engine-tracked** (ops#326 / [ADR-0039](docs/decisions/0039-instance-state-in-private-overlay-repos.md)) — the engine repo is publicly mirrored.
  - **Each server is its own PRIVATE git repo, in place**: `servers/<name>/.git`, remote `nwp/server-<name>`. The files never move, so every `pl` verb reads the same paths; only the repo boundary moves. `pl doctor` (`host_check_server_repos`) fails when a host dir holds state with no repo, has no remote, has unpushed commits, or is dirty — and prints the exact command to settle it.
  - After a `git pull` that lands an engine-side split, restore the captured state with `git -C servers/<name> checkout -- .`
- `scripts/commands/` - All executable commands (accessed via `pl` CLI)
  - `pl site list|show|schema|migrate|init` - Per-site config management
  - `pl server list|show|status|sites|schema|migrate` - Per-server config management
  - `pl proposals [--site=|--status=|--root|--sites]` - Cross-site proposal aggregator
- `docs/` - Project documentation
  - `governance/roadmap.md` - Pending proposals and future work
  - `reports/milestones.md` - Completed proposals and version history
  - `CHANGELOG.md` (root) - Version changelog for releases
  - `decisions/` - Architecture Decision Records (ADRs)

## Security Red Flags

When reviewing code changes, contributions, or merge requests, watch for these security red flags that may indicate malicious code or security vulnerabilities.

### High Risk (Block and Escalate)

These changes require immediate attention and should not be merged without thorough review:

- **Authentication/Authorization Changes** - Modifications to authentication or authorization logic without a related security issue
- **New External Network Calls** - Adding curl, file_get_contents with URLs, or other external network requests
- **Dynamic Code Execution** - Introduction of eval(), exec(), system(), passthru(), shell_exec(), or proc_open()
- **Server Configuration Changes** - Modifications to .htaccess, nginx.conf, Apache configs, or other server configuration files
- **Cryptographic Changes** - Changes to encryption, key handling, or cryptographic functions
- **New Dependencies** - Adding composer or npm dependencies not mentioned in issue description
- **CI/CD Pipeline Changes** - Modifications to .gitlab-ci.yml, .github/workflows/, or other CI/CD configurations
- **Git Configuration** - Changes to .gitignore, .gitattributes, or git hooks

### Medium Risk (Require Explanation)

These changes need justification and careful review:

- **Scope Creep** - Changes affecting significantly more files than issue scope suggests
- **Mixed Changes** - "Cleanup" or "refactoring" bundled with bug fixes or features
- **Database Changes** - Modifications to database queries, schema, or migrations
- **File Permission Changes** - Changes to chmod, chown, or file permission logic
- **New User Input Handling** - Adding new user input fields without proper validation/sanitization
- **Secret Handling** - Changes to how secrets, credentials, or API keys are stored or accessed
- **Backup/Restore Logic** - Modifications to backup, restore, or data export functionality

### Malicious Code Patterns

Watch for these specific code patterns that may indicate malicious intent:

- **Obfuscated Code** - Base64 encoding, hex encoding, or other obfuscation techniques
- **Hidden Functionality** - Logic bombs (time-based triggers), backdoors, or undocumented features
- **Data Exfiltration** - Code that sends data to unexpected external URLs
- **Credential Harvesting** - Code that logs, stores, or transmits passwords or tokens
- **Supply Chain Attacks** - Typosquatting dependencies (e.g., "druapl/core" instead of "drupal/core")
- **Hardcoded Secrets** - API keys, passwords, or tokens embedded in code

### Scope Verification Questions

For every merge request, ask:

1. **Does the diff match the MR title?** - "Fix typo" should not modify 10 files
2. **Are all changed files related?** - Bug fix in backup.sh should not touch authentication code
3. **Is the change size proportional?** - Simple fixes should be small, not 500 lines
4. **Are new dependencies justified?** - Why is this package needed? What does it do?
5. **Do external URLs make sense?** - Why is this connecting to an external service?
6. **Are sensitive paths explained?** - Why does this change authentication/security code?

### Red Flag Response Protocol

When red flags are detected:

1. **Document the concern** - Note specifically what triggered the red flag
2. **Ask for explanation** - Give the contributor a chance to explain (may be legitimate)
3. **Request scope reduction** - Ask for unrelated changes to be split into separate MRs
4. **Verify with maintainer** - High-risk changes require senior developer review
5. **Check CI results** - Ensure all automated security scans passed
6. **Test thoroughly** - Manual testing of security-sensitive changes

### Security Review Checklist

For merge requests touching sensitive areas:

- [ ] Scope matches issue description
- [ ] No unexpected file modifications
- [ ] No new dependencies (or dependencies are explained and audited)
- [ ] No suspicious code patterns (eval, base64_decode, external URLs)
- [ ] No sensitive path changes (or has required approvers)
- [ ] CI security scans passed
- [ ] Change size is proportional to stated purpose
- [ ] All external URLs are necessary and trusted
- [ ] No hardcoded credentials or secrets

### Sensitive File Paths

These paths require extra scrutiny and two-person approval:

- `lib/auth*` - Authentication libraries
- `lib/*secret*` - Secret handling code
- `**/settings.php` - Drupal settings files
- `.gitlab-ci.yml` - CI/CD configuration
- `composer.json` - Dependency definitions
- `scripts/commands/live*.sh` - Production deployment scripts
- `CLAUDE.md` - AI standing orders (this file)
- `.env*` - Environment configuration
- `keys/**` - SSH and encryption keys

### Safe Contribution Practices

Encourage contributors to:

- **Small, focused changes** - One issue per MR
- **Clear descriptions** - Explain what and why
- **Test evidence** - Show that changes were tested
- **Document decisions** - Explain non-obvious choices
- **Separate refactoring** - Don't mix cleanup with features
- **Declare dependencies** - List any new packages in issue description

See also: `docs/governance/distributed-contribution-governance.md` for the complete security review system.

## Release Tag Process

When the user asks to create a new release tag (e.g., "create tag v0.13"), follow this complete checklist:

### 1. Pre-Release Verification

- [ ] Run `pl verify --run --depth=thorough` - ensure 98%+ pass rate
- [ ] Run `pl verify badges` to check coverage
- [ ] Run `bash -n` syntax check on modified scripts in `scripts/commands/` and `lib/`
- [ ] Verify no uncommitted changes: `git status`
- [ ] Review git log since last tag: `git log $(git describe --tags --abbrev=0)..HEAD --oneline`

### 2. Version Updates

- [ ] Update version in `pl` script (NWP_VERSION variable)
- [ ] Update version in `example.nwp.yml` if schema changed
- [ ] Update "Current Version" in `docs/governance/roadmap.md`

### 3. Documentation Updates

- [ ] Review all modified `docs/*.md` files for accuracy
- [ ] Update "Last Updated" dates on modified docs
- [ ] Ensure README.md reflects current features
- [ ] Update CLAUDE.md if standing orders changed

### 4. Roadmap & Milestones

- [ ] Move completed proposals from `docs/governance/roadmap.md` to `docs/reports/milestones.md`
- [ ] Update proposal statuses (PLANNED → IN PROGRESS → COMPLETE)
- [ ] Add any new proposals discovered during development
- [ ] Update success criteria checkboxes (mark completed items with [x])
- [ ] Update phase completion percentages

### 5. Changelog

- [ ] Create/update `CHANGELOG.md` in project root with:
  - Version number and date
  - New features (from completed proposals)
  - Bug fixes
  - Breaking changes (if any)
  - Migration notes (if needed)

### 6. Final Checks

- [ ] Ensure all significant changes from git log are documented
- [ ] Verify `example.nwp.yml` matches current schema
- [ ] Check that new commands are documented in help text

### 7. Create Tag

```bash
# Create annotated tag with description
git tag -a v0.XX -m "Version 0.XX: Brief description of major changes"

# Push tag to remote
git push origin v0.XX
```

### 8. Post-Release

- [ ] Update any "Coming Soon" references to "Available"
- [ ] Create GitLab/GitHub release with changelog summary
- [ ] Announce release if significant

### Changelog Format

Use this format for `CHANGELOG.md` entries:

```markdown
## [v0.XX] - YYYY-MM-DD

### Added
- Feature description (P## reference if applicable)

### Changed
- Change description

### Fixed
- Bug fix description

### Breaking Changes
- Breaking change with migration path

### Migration Notes
- Steps users need to take when upgrading
```

### Version Numbering

NWP uses semantic-ish versioning:
- **v0.X** - Major feature releases (new proposals implemented)
- **v0.X.Y** - Bug fixes and minor improvements
- **v1.0** - Reserved for production-ready release
