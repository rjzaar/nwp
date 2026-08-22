# NWP Documentation

Welcome to the **Narrow Way Project (NWP)** documentation hub. This directory contains comprehensive documentation for developing, deploying, and maintaining Drupal sites using NWP's automated workflows.

**Current Version:** v0.30.0
**Documentation Last Updated:** 2026-07-26

---

## Getting Started

New to NWP? Start here:

| Document | Description |
|----------|-------------|
| [Quickstart Guide](guides/quickstart.md) | 5-minute quick start - get up and running fast |
| [Setup Guide](guides/setup.md) | Complete installation, configuration, and uninstallation |
| [Training Booklet](guides/training-booklet.md) | Comprehensive 8-phase training curriculum |

---

## Overview — what all of this actually is

Plain-language summaries, no assumed knowledge. Start here if you are new, or have been away.

| Document | Description |
|----------|-------------|
| [Fleet overview](overview/README.md) | How the four projects fit together, and the shared infrastructure |
| [NWP](overview/nwp.md) | The tooling itself — what it does, where it's up to, what's next |
| [Saint School](overview/saint-school.md) | The Moodle learning site |
| [Narrow Way Commons](overview/narrow-way-commons.md) | The Drupal community site |
| [theocat](overview/theocat.md) | The theology source library |
| [The `dir` question](overview/dir-question.md) | What the `dir` site is, and whether it folds into nwc (research + recommendation) |

## How-to guides — the main workflows

One page each, task-oriented, plain language.

| Document | Description |
|----------|-------------|
| [Back up and restore](guides/howto-backup-restore.md) | Everyday backups, restores, retention, scheduling |
| [Deploy a change](guides/howto-deploy.md) | dev → staging → live → production, and the guards |
| [The disaster-recovery chain](guides/howto-dr-chain.md) | Off-site backups, the two-tier sanitiser, rehearsing it |
| [Run the demo tier](guides/howto-demo-tier.md) | Golden images, resets, the nightly cycle |
| [Issue demo invite codes](guides/howto-invite-codes.md) | Recruiting testers |
| [Use the NWP Console](guides/howto-console.md) | The fleet on your phone |
| [Fleet test links](guides/test-links.md) | Click-through smoke test of every surface |

---

## Quick Links

Most frequently accessed documentation:

| Document | Description |
|----------|-------------|
| [Feature Reference](reference/features.md) | Complete list of NWP features by category |
| [Command Reference](reference/commands.md) | How to get the authoritative verb list — `pl commands` / `pl commands --json` (generated, 100%) |
| [Retired Documents](_retired/README.md) | What was retired, when, why — and `pl docs restore` to undo it |
| [Libraries API](reference/libraries.md) | Bash library function reference |
| [Production Deployment](deployment/production-deployment.md) | Deploy to production servers |
| [Testing Guide](testing/testing.md) | Automated testing with Behat, PHPUnit, PHPStan |
| [Security Best Practices](security/data-security-best-practices.md) | Two-tier secrets, AI safety, security hardening |
| [Git Hooks](development/git-hooks.md) | Automated code quality checks |
| [Roadmap](governance/roadmap.md) | Current status and future plans |

---

## Documentation by Category

### User Guides

Step-by-step guides for common workflows:

| Document | Description |
|----------|-------------|
| [Quickstart Guide](guides/quickstart.md) | Get started in 5 minutes |
| [Setup Guide](guides/setup.md) | Installation and configuration |
| [Training Booklet](guides/training-booklet.md) | 8-phase training curriculum |
| [Developer Workflow](guides/developer-workflow.md) | 9-phase development lifecycle |
| [Admin Onboarding](guides/admin-onboarding.md) | System administrator onboarding |
| [Coder Onboarding](guides/coder-onboarding.md) | Multi-coder infrastructure setup |
| [Email Setup](guides/email-setup.md) | Email configuration, SMTP, and email reply system |
| [Working with Claude Securely](guides/working-with-claude-securely.md) | AI assistant security guidelines |
| [Local LLM Guide](guides/local-llm.md) | Running open source AI models locally (Ollama, hardware, model selection) |
| [Moodle Microsoft SSO](guides/moodle-microsoft-sso.md) | Create a Moodle site with Microsoft account sign-on |
| [Migration Sites Tracking](guides/migration-sites-tracking.md) | Migrate to sites tracking system |
| [Git Hooks](development/git-hooks.md) | Automated code quality checks |

### Technical Reference

Detailed technical documentation:

| Document | Description |
|----------|-------------|
| [Features Reference](reference/features.md) | Complete feature list by category |
| [Libraries API](reference/libraries.md) | Bash library function documentation |
| [YAML API Reference](reference/yaml-api.md) | YAML parsing and manipulation functions |
| [Scripts Implementation](reference/scripts-implementation.md) | Script architecture and implementation |
| [Backup Implementation](reference/backup-implementation.md) | Backup system internals |
| [Architecture Analysis](reference/architecture-analysis.md) | Vortex comparison, env vars, workflows |
| [Commands →](reference/commands.md) | Where the command list comes from (generated by `pl commands`) |

#### Command Reference

The 48 hand-written per-command pages were retired on 2026-08-22 (ops#383):
they covered 46 of 119 verbs, and one of them documented a verb that no longer
exists. The list is now generated from the code, so it cannot go stale:

| Command | Description |
|---------|-------------|
| `pl commands` | Every verb `pl` can dispatch, with a one-line synopsis |
| `pl commands --json` | The same list, machine-readable |
| `pl <verb> --help` | Everything one verb can do, including its guard flags |
| [Command Reference](reference/commands.md) | Why the pages went, and how to get one back |

The retired pages are not gone — see [`docs/_retired/MANIFEST.md`](_retired/MANIFEST.md),
or `pl docs restore docs/reference/commands`.

### Deployment

Guides for deploying NWP sites:

| Document | Description |
|----------|-------------|
| [Environments](deployment/environments.md) | Four-tier model (dev/stg/live/prod) |
| [Production Deployment](deployment/production-deployment.md) | Deploy to production servers |
| [Advanced Deployment](deployment/advanced-deployment.md) | Blue-green, canary releases |
| [Linode Deployment](deployment/linode-deployment.md) | Linode infrastructure setup |
| [SSH Setup](deployment/ssh-setup.md) | SSH key configuration |
| [Disaster Recovery](deployment/disaster-recovery.md) | Recovery procedures, RTO/RPO |
| [CI/CD Pipelines](deployment/cicd.md) | GitLab CI, GitHub Actions |
| [Git Backup Strategy](deployment/git-backup-recommendations.md) | Git-based backup recommendations |
| [Configuration as Code](CONFIG_AS_CODE.md) | The configuration-drift gate and `pl config track` |

### Development

Development workflows and tools:

| Document | Description |
|----------|-------------|
| [Developer Workflow](guides/developer-workflow.md) | 9-phase development lifecycle |
| [Git Hooks](development/git-hooks.md) | Automated code quality checks |
| [Working with Claude Securely](guides/working-with-claude-securely.md) | AI assistant security guidelines |

### Testing

Testing strategies and tools:

| Document | Description |
|----------|-------------|
| [Automated Testing](testing/testing.md) | Behat, PHPUnit, PHPStan |
| [Manual Testing](testing/human-testing.md) | 12-category test procedures |
| [Verification Guide](testing/verification-guide.md) | Feature verification tracking |
| [Verify Enhancements](testing/verify-enhancements.md) | Interactive TUI console (v0.18.0+) |

### Security

Security documentation and best practices:

| Document | Description |
|----------|-------------|
| [Data Security Best Practices](security/data-security-best-practices.md) | Two-tier secrets, AI safety, hardening |
| [SEO Setup](security/seo-setup.md) | SEO and robots.txt configuration |
| [Design Decisions](security/design-decisions.md) | Security architecture rationale |
| ~~[SECURITY.md](SECURITY.md)~~ | ⚠️ **Superseded 2026-07-25** — obsolete threat model + 8 non-existent commands. Read `CLAUDE.md` § Threat Model and ADR-0017/0024/0026/0028 instead |

### Active Proposals

Current proposals under consideration:

| Proposal | Description |
|----------|-------------|
| [F07: SEO & Robots](proposals/F07-seo-robots.md) | SEO optimization and robots.txt |
| [F08: Dynamic Badges](proposals/F08-dynamic-badges.md) | Badge generation system |
| [F09: Comprehensive Testing](proposals/F09-comprehensive-testing.md) | Enhanced testing framework |
| [NWP Deep Analysis](proposals/nwp-deep-analysis.md) | Comprehensive system analysis |
| [YAML Parser Consolidation](proposals/YAML_PARSER_CONSOLIDATION.md) | Consolidate duplicate YAML parsers |
| [API Client Abstraction](proposals/API_CLIENT_ABSTRACTION.md) | Abstraction layer for API calls |
| [Coder Identity Bootstrap](proposals/CODER_IDENTITY_BOOTSTRAP.md) | Automated identity configuration |

### Governance

Project management and governance:

| Document | Description |
|----------|-------------|
| [Roadmap](governance/roadmap.md) | Current status and future plans |
| [Roles](governance/roles.md) | Project roles and responsibilities |
| [Executive Summary](governance/executive-summary.md) | High-level project overview |
| [Distributed Contribution Governance](governance/distributed-contribution-governance.md) | Security review process for contributions |
| [Core Developer Onboarding](governance/core-developer-onboarding.md) | Onboarding core developers |

### Project-Specific Documentation

Documentation for specific projects:

#### AVC Project

> ⚠️ **Removed.** `docs/projects/avc/` no longer exists — AVC is the frozen 1.x
> predecessor to Narrow Way Commons. Its per-site documentation now lives inside
> the site's own profile repository. See [Narrow Way Commons](overview/narrow-way-commons.md)
> for the successor, and `docs/guides/nwc-ssc-architecture.md` for the current
> architecture.

#### Podcast Project

| Document | Description |
|----------|-------------|
| [Podcast Setup](projects/podcast/podcast-setup.md) | Castopod podcast hosting |

### Integration & Completion Documents

> ⚠️ **Removed.** These pages documented the original AVC↔Moodle single-sign-on
> work and lived under `docs/projects/avc/`, which no longer exists. The current
> single-sign-on architecture (Narrow Way Commons ↔ Saint School, with identity
> locking) is documented in [nwc-ssc-architecture.md](guides/nwc-ssc-architecture.md).

| Document | Description |
|----------|-------------|
| [Moodle Course Creation Guide](guides/moodle-course-creation.md) | Guide for creating Moodle courses |
| [Verify Enhancements](testing/verify-enhancements.md) | Interactive verification console guide |

### Legal & Licensing

| Document | Description |
|----------|-------------|
| [CC0 Public Domain Dedication](CC0_DEDICATION.md) | Public domain dedication and rationale |
| [Documentation Standards](governance/documentation-standards.md) | Documentation style guidelines |

### Reports & History

Implementation reports and version history:

| Document | Description |
|----------|-------------|
| [Milestones](reports/milestones.md) | Completed proposals (P01-P35) |
| [Version Changes](reports/version-changes.md) | Version changelog |
| [History](reports/history.md) | Project evolution and documentation history |
| [Documentation Audit](archive/reports/documentation-audit-2026-01-12.md) | January 2026 audit results (archived) |
| [Implementation Plan 2026-01](archive/reports/IMPLEMENTATION_PLAN_2026-01.md) | January 2026 implementation roadmap (archived) |
| [F05/F04/F09/F07 Implementation](reports/f05-f04-f09-f07-implementation.md) | Feature implementation report |
| [Implementation Consolidation](reports/implementation-consolidation.md) | Consolidation summary |
| [Coder Identity Bootstrap Implementation](reports/CODER_IDENTITY_BOOTSTRAP_IMPLEMENTATION.md) | Bootstrap system implementation |
| [NWP Deep Analysis Reevaluation](reports/NWP_DEEP_ANALYSIS_REEVALUATION.md) | System analysis reevaluation |
| [Documentation Creation Analysis](reports/documentation_creation_analysis.md) | Documentation creation patterns |
| [README Documentation Analysis](reports/README-documentation-analysis.md) | README analysis and recommendations |

### Architecture Decision Records (ADRs)

Documented technical decisions:

| Document | Description |
|----------|-------------|
| [ADR Index](decisions/index.md) | All architecture decisions |
| [ADR 0001](decisions/0001-use-ddev-for-local-development.md) | Use DDEV for local development |
| [ADR 0002](decisions/0002-yaml-based-configuration.md) | YAML-based configuration |
| [ADR 0003](decisions/0003-bash-for-automation-scripts.md) | Bash for automation scripts |
| [ADR 0004](decisions/0004-two-tier-secrets-architecture.md) | Two-tier secrets architecture |
| [ADR 0005](decisions/0005-distributed-contribution-governance.md) | Distributed contribution governance |
| [ADR 0006](decisions/0006-contribution-workflow.md) | Contribution workflow |
| [ADR 0016](decisions/0016-avc-email-reply-architecture.md) | AVC email reply architecture |
| [ADR 0017](decisions/0017-distributed-build-deploy-pipeline.md) | Distributed build/deploy pipeline |
| [ADR 0024](decisions/0024-self-deploying-prod-supersedes-verifier.md) | Self-deploying prod (production deploy authority) |
| [ADR 0025](decisions/0025-production-backup-to-ver.md) | Production backup to `ver` (restic, custodian-pull) |
| [ADR 0026](decisions/0026-nwp-server-capability-agent.md) | The AI-free `nwp-server` capability agent |
| [ADR 0028](decisions/0028-ver-single-operator-human-gated-workstation.md) | `ver` as a single-operator, human-gated workstation |
| [ADR 0030](decisions/0030-per-site-canonical-maturity-axes.md) | Per-site canonical & maturity axes |
| [ADR 0031](decisions/0031-paired-site-versioning-and-promotion.md) | Paired-site versioning & promotion |
| [ADR 0032](decisions/0032-non-prod-data-refresh-and-file-store.md) | Non-prod data refresh & file store |
| [Decision Log](decisions/decision-log.md) | Chronological decision log |
| [ADR Template](decisions/template.md) | Template for new ADRs |

### Archive

Historical documents no longer actively maintained:

| Category | Documents |
|----------|-----------|
| [Archive Directory](archive/) | 14 archived documents |
| Implemented Proposals | [dev2stg-enhancement](archive/dev2stg-enhancement-proposal-IMPLEMENTED.md), [IMPORT](archive/IMPORT-PROPOSAL.md), [multi-coder-dns](archive/multi-coder-dns-proposal-IMPLEMENTED.md), [LIVE_DEPLOYMENT_AUTOMATION](archive/LIVE_DEPLOYMENT_AUTOMATION_PROPOSAL-INTEGRATED.md) |
| Superseded Research | [VORTEX_COMPARISON](archive/VORTEX_COMPARISON.md), [DEPLOYMENT_WORKFLOW_ANALYSIS](archive/DEPLOYMENT_WORKFLOW_ANALYSIS.md), [environment-variables-comparison](archive/environment-variables-comparison.md) |
| Historical Guides | [MIGRATION_GUIDE_ENV](archive/MIGRATION_GUIDE_ENV-HISTORICAL.md), [IMPLEMENTATION_SUMMARY](archive/IMPLEMENTATION_SUMMARY.md), [NWP_COMPLETE_ROADMAP](archive/NWP_COMPLETE_ROADMAP-ARCHIVED.md) |
| Future Proposals | [EMAIL_POSTFIX_PROPOSAL](archive/EMAIL_POSTFIX_PROPOSAL.md), [NWP_TRAINING_SYSTEM](archive/NWP_TRAINING_SYSTEM.md), [NWP_TRAINING_IMPLEMENTATION_PLAN](archive/NWP_TRAINING_IMPLEMENTATION_PLAN.md) |
| Reviews | [CODE_REVIEW_2024-12](archive/CODE_REVIEW_2024-12.md) |

### Theme Documentation

Theme-specific assets and documentation:

| Document | Description |
|----------|-------------|
| [Gospel Meditations Specifications](themes/gospel-meditations-specifications.md) | Theme specifications |

---

## Quick Reference

### Common Commands

```bash
# Using pl CLI (recommended)
pl install nwp mysite        # Install new site
pl backup mysite             # Backup site
pl restore mysite            # Restore site
pl copy source dest          # Copy site
pl delete mysite             # Delete site
pl dev2stg mysite            # Dev to staging
pl stg2prod mysite           # Staging to production
pl test mysite               # Run tests
pl verify                    # Interactive verification console (v0.18.0+)

# Or use scripts directly
./scripts/commands/install.sh nwp mysite
./scripts/commands/backup.sh mysite
```

### Environment Naming

| Environment | Pattern | Example |
|-------------|---------|---------|
| Development | `sitename` | `mysite` |
| Staging | `sitename-stg` | `mysite-stg` |
| Live | `sitename.domain` | `mysite.<prod-domain>` |
| Production | Custom domain | `mysite.com` |

### Configuration Files

| File | Purpose | Git Status |
|------|---------|------------|
| `nwp.yml` | Main configuration (user-specific) | Not tracked |
| `example.nwp.yml` | Configuration template | Tracked |
| `.secrets.yml` | Infrastructure credentials | Not tracked |
| `.secrets.data.yml` | Production credentials (AI-blocked) | Not tracked |

---

## Contributing to Documentation

When contributing to NWP documentation:

1. Read [Documentation Standards](governance/documentation-standards.md) for style guidelines
2. Place documents in the appropriate subdirectory (guides/, reference/, deployment/, etc.)
3. Update this README.md with links to new documents
4. Include "Last Updated" date in document frontmatter
5. Follow the established naming conventions (lowercase with hyphens)

### Documentation Standards

See [Documentation Standards](governance/documentation-standards.md) for:

- File naming conventions
- Document structure guidelines
- Markdown formatting standards
- Cross-referencing guidelines
- Version control practices

---

## Related Documentation

- [Main README](../README.md) - Project overview and quick start
- [CLAUDE.md](../CLAUDE.md) - AI assistant standing orders
- [CHANGELOG.md](../CHANGELOG.md) - Version changelog
- [KNOWN_ISSUES.md](../KNOWN_ISSUES.md) - Current known issues
- [Server Configs](../servers/) - Per-server provisioning, GitLab, Linode, email scripts (F17 Phase 8)

---

## Need Help?

- **Getting Started:** See [Quickstart Guide](guides/quickstart.md)
- **Installation Issues:** See [Setup Guide](guides/setup.md)
- **Command Help:** Run `pl commands` (generated, complete) or see [Command Reference](reference/commands.md)
- **Feature Questions:** See [Features Reference](reference/features.md)
- **Security Concerns:** See [Security Best Practices](security/data-security-best-practices.md)
- **Testing Problems:** See [Testing Guide](testing/testing.md) or [Manual Testing](testing/human-testing.md)

---

*This documentation structure was established on January 12, 2026 following the documentation reorganization audit. For documentation contribution guidelines, see [Documentation Standards](governance/documentation-standards.md).*
