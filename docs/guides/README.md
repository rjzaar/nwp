# NWP Guides

Task-oriented guides for operators, coders, and admins. For the full documentation
index (ADRs, references, proposals) see [`../README.md`](../README.md). For
plain-language summaries of *what all of this is*, see [`../overview/`](../overview/README.md).

**Last updated:** 2026-07-26

---

## How to — the main workflows

One page each, task-oriented, no assumed knowledge. **Start here.**

| Guide | What it covers |
|-------|----------------|
| [howto-backup-restore.md](howto-backup-restore.md) | Everyday backups and restores: what a backup is, `pl backup` / `pl restore`, integrity verification, 30-day retention (`pl backup prune`), scheduling, rollback |
| [howto-deploy.md](howto-deploy.md) | Getting a change out: dev → staging → live → production, the canonical/maturity axes, `--code-only`, every guard you may hit and what it means, the hardware deploy gate |
| [howto-dr-chain.md](howto-dr-chain.md) | Disaster recovery: pull-not-push backups, the raw (30-day) and sanitised (long-term) tiers, `nwp-server backup --sanitize`, `ver backup pull`, rehearsing the whole chain with `pl ver-test` |
| [howto-demo-tier.md](howto-demo-tier.md) | Running the demo site: golden images, `pl demo reset`, the idle-guarded nightly cycle, harvest, safety rails |
| [howto-invite-codes.md](howto-invite-codes.md) | Recruiting testers: `pl demo invite`, the five role bundles, why codes are shown once, distribution rules |
| [howto-console.md](howto-console.md) | The NWP Console: the three locks on the door, the seven tabs, the five safe actions, setup and recovery |
| [test-links.md](test-links.md) | **Click-through smoke test** — every live site, key page, console tab and dev URL, with a tick box and what you should see |

## Start here — the whole system

| Guide | What it covers |
|-------|----------------|
| [using-nwp.md](using-nwp.md) | Map of the whole system: role tiers, the `pl` command surface grouped by purpose, and the self-driving loop |
| [nwp-single-machine.md](nwp-single-machine.md) | The simplest way in — the AI-free core on one machine — and nwp as concentric tiers |
| [quickstart.md](quickstart.md) | NWP quick start |
| [setup.md](setup.md) | Two-tier setup |
| [training-booklet.md](training-booklet.md) | Developer training booklet |

## Deploy, verify, and back up (the AI-free `nwp-server` / `ver` tier)

| Guide | What it covers |
|-------|----------------|
| [ver-setup.md](ver-setup.md) | Set up `ver` / the AI-free `nwp-server` build: trust posture, `pl build-server`, the three-key credential ledger, restic backups (NWP-ADR-0025), verify/apply/rollback, smoke tests |
| [ver-provisioning-runbook.md](ver-provisioning-runbook.md) | **Turnkey provisioning sequence for `ver`** (ops#25): signed tool kit, sealed keystore (FIDO2), Solo enrollment checklist, one-way keys, tunnel, first backup pull |
| [ver-soloW-setup-walkthrough.md](ver-soloW-setup-walkthrough.md) | Walkthrough for enrolling the Solo W hardware token |
| [nwp-server-operations.md](nwp-server-operations.md) | Operating the AI-free `nwp-server` agent on a prod host |
| *(offline deploy-host readiness)* | A readiness checklist for the offline deploy host also lives in this directory — its filename names the host, so it is not linked here (P61 leakage gate) |
| [ops83-dr-restore.md](ops83-dr-restore.md) | **DR restore procedure**, including the paired-site both-or-forward rule |
| [ops81-erasure-channel.md](ops81-erasure-channel.md) · [ops82-key-rotation.md](ops82-key-rotation.md) | Erasure propagation and key rotation |
| [production-site-integration.md](production-site-integration.md) | Integrating a production site |

## Paired sites, contracts and versioning

| Guide | What it covers |
|-------|----------------|
| [nwc-ssc-architecture.md](nwc-ssc-architecture.md) | How Narrow Way Commons and Saint School are wired together (identity, guilds, consent) |
| [ops75-pair-contract-schema.md](ops75-pair-contract-schema.md) | The paired-site contract schema |
| [p74-contract-sync.md](p74-contract-sync.md) | Keeping the intersite contract in sync |
| [ops74-versioning-scheme.md](ops74-versioning-scheme.md) · [ops74-half-b-runbook.md](ops74-half-b-runbook.md) · [ops74-tag-release-runbook.md](ops74-tag-release-runbook.md) | Paired-site versioning and release |
| [ops73-moodle-plugin-manifest-design.md](ops73-moodle-plugin-manifest-design.md) · [ops73-phase-a-reconcile-runbook.md](ops73-phase-a-reconcile-runbook.md) | Moodle plugin manifest and reconciliation |
| [moodle-promotion-substrate.md](moodle-promotion-substrate.md) | Promoting Moodle changes between tiers |

## Development & workflow

| Guide | What it covers |
|-------|----------------|
| [developer-workflow.md](developer-workflow.md) | NWP developer lifecycle |
| [self-healing-loop-guide.md](self-healing-loop-guide.md) | The agent loop that routes issues to fixes |
| [nwc-fork-guide.md](nwc-fork-guide.md) | Working with the nwc profile |
| [migration-workflow.md](migration-workflow.md) · [migration-sites-tracking.md](migration-sites-tracking.md) | Migration workflow and site tracking |
| [frontend-theming.md](frontend-theming.md) | Frontend theming |

## Onboarding

| Guide | What it covers |
|-------|----------------|
| [member-getting-started.md](member-getting-started.md) | For a new **member** of the community site |
| [coder-onboarding.md](coder-onboarding.md) · [admin-onboarding.md](admin-onboarding.md) | Coder / admin onboarding |
| [working-with-claude-securely.md](working-with-claude-securely.md) · [claude-cheatsheet.md](claude-cheatsheet.md) | Working with AI assistants safely |

## Integrations & services

| Guide | What it covers |
|-------|----------------|
| [email-setup.md](email-setup.md) | Email setup |
| [gotify.md](gotify.md) | Gotify push notifications |
| [local-llm.md](local-llm.md) | Running local open-source LLMs |
| [voice-agent.md](voice-agent.md) · [voice-agent-ec-handoff.md](voice-agent-ec-handoff.md) | Voice agent |
| [moodle-course-creation.md](moodle-course-creation.md) · [moodle-microsoft-sso.md](moodle-microsoft-sso.md) | Moodle |
| [mayo-avc-integration.md](mayo-avc-integration.md) · [mayo-migration-plan.md](mayo-migration-plan.md) | Mayo / AVC |

## ⚠️ Superseded — do not follow

| Guide | Why |
|-------|-----|
| [verifier-operations.md](verifier-operations.md) | Describes the F21 SSH-rsync/blue-green pipeline and the old `verifier` binary name. Predates the NWP-ADR-0022/0026 binary split and the `ver` / `prod-agent` vocabulary. Use [ver-setup.md](ver-setup.md). |
| [verifier-mayo-bootstrap.md](verifier-mayo-bootstrap.md) | Interim bootstrap guide, superseded by the above. |

---

## Not in this directory, but you probably want it

| Topic | Where |
|-------|-------|
| Configuration as code / the drift gate | [`../CONFIG_AS_CODE.md`](../CONFIG_AS_CODE.md) |
| The console's technical detail and security model | `scripts/console/README.md` |
| What the July 2026 consolidation arc changed | [`../reports/consolidation-arc-2026-07/decision-log.md`](../reports/consolidation-arc-2026-07/decision-log.md) |
| Plain-language project summaries | [`../overview/`](../overview/README.md) |
