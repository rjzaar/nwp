# NWP Guides

Task-oriented guides for operators, coders, and admins. For the full documentation
index (ADRs, references, proposals) see [`../README.md`](../README.md).

## Start here — the whole system

| Guide | What it covers |
|-------|----------------|
| [using-nwp.md](using-nwp.md) | Map of the whole system: role tiers, the `pl` command surface grouped by purpose, and the self-driving loop |
| [nwp-single-machine.md](nwp-single-machine.md) | The simplest way in — the AI-free core on one machine — and nwp as concentric tiers |
| [quickstart.md](quickstart.md) | NWP quick start |
| [setup.md](setup.md) | Two-tier setup |

## Deploy, verify, and back up (the AI-free `nwp-server` / `ver` tier)

| Guide | What it covers |
|-------|----------------|
| [ver-setup.md](ver-setup.md) | Set up `ver` / the AI-free `nwp-server` build: trust posture, `pl build-server`, the three-key credential ledger, restic backups (ADR-0025), verify/apply/rollback, smoke tests |
| [ver-provisioning-runbook.md](ver-provisioning-runbook.md) | **Turnkey provisioning sequence for `ver`** (ops#25): signed tool kit, sealed keystore (FIDO2), Solo enrollment checklist, one-way keys, tunnel, first backup pull — AI-prepared vs operator+hardware steps marked throughout |
| [verifier-operations.md](verifier-operations.md) | Older F21 signed-tarball deploy pipeline. **Stale** vs the `nwp-server`/`ver` model — see the follow-up note below |
| [verifier-mayo-bootstrap.md](verifier-mayo-bootstrap.md) | Interim bootstrap guide, superseded by the above |
| [production-site-integration.md](production-site-integration.md) | Integrating a production site |

## Development & workflow

| Guide | What it covers |
|-------|----------------|
| [developer-workflow.md](developer-workflow.md) | NWP developer lifecycle |
| [migration-workflow.md](migration-workflow.md) · [migration-sites-tracking.md](migration-sites-tracking.md) | Migration workflow and site tracking |
| [frontend-theming.md](frontend-theming.md) | Frontend theming |
| [training-booklet.md](training-booklet.md) | Developer training booklet |

## Onboarding

| Guide | What it covers |
|-------|----------------|
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

---

> **Follow-up (stale docs):** `verifier-operations.md` and `verifier-mayo-bootstrap.md`
> predate the ADR-0022/0024 binary split and the `ver` / `prod-agent` role vocabulary
> (they still describe the F21 SSH-rsync/blue-green pipeline and the `verifier` binary
> by its old name). They should be reconciled with [ver-setup.md](ver-setup.md) or
> marked superseded. Not done here to avoid mass-rewriting; tracked as a follow-up.
