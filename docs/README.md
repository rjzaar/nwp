# NWP Documentation

Welcome to the **Narrow Way Project (NWP)** documentation hub. This directory contains comprehensive documentation for developing, deploying, and maintaining Drupal sites using NWP's automated workflows.

**Current Version:** v0.23.0
**Documentation Last Updated:** 2026-01-15

---

## Getting Started

New to NWP? Start here:

| Document | Description |
|----------|-------------|
| [Quickstart Guide](guides/quickstart.md) | 5-minute quick start - get up and running fast |
| [Setup Guide](guides/setup.md) | Complete installation, configuration, and uninstallation |
| [Training Booklet](guides/training-booklet.md) | Comprehensive 8-phase training curriculum |

---

## Quick Links

Most frequently accessed documentation:

| Document | Description |
|----------|-------------|
| [Feature Reference](reference/features.md) | Complete list of NWP features by category |
| [Command Reference](reference/commands/README.md) | All `pl` CLI commands (56% documented) |
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
| [Migration Sites Tracking](guides/migration-sites-tracking.md) | Migrate to sites tracking system |
| [Git Hooks](development/git-hooks.md) | Automated code quality checks |

### Technical Reference

Detailed technical documentation:

| Document | Description |
|----------|-------------|
| [Features Reference](reference/features.md) | Complete feature list by category |
| [Libraries API](reference/libraries.md) | Bash library function documentation |
| [YAML API Reference](YAML_API.md) | YAML parsing and manipulation functions |
| [Scripts Implementation](reference/scripts-implementation.md) | Script architecture and implementation |
| [Backup Implementation](reference/backup-implementation.md) | Backup system internals |
| [Architecture Analysis](reference/architecture-analysis.md) | Vortex comparison, env vars, workflows |
| [Commands →](reference/commands/) | Individual command documentation (9 files) |

#### Command Reference

Detailed documentation for specific commands:

| Command | Description |
|---------|-------------|
| [All Commands](reference/commands/README.md) | Complete command reference (56% documented) |
| [backup](reference/commands/backup.md) | Create site backups |
| [badges](reference/commands/badges.md) | Dynamic badge generation |
| [coder-setup](reference/commands/coder-setup.md) | Initialize coder environment |
| [coders](reference/commands/coders.md) | Multi-coder management |
| [contribute](reference/commands/contribute.md) | Contribution workflow |
| [copy](reference/commands/copy.md) | Copy/clone sites |
| [delete](reference/commands/delete.md) | Delete sites and cleanup |
| [dev2stg](reference/commands/dev2stg.md) | Deploy development to staging |
| [doctor](reference/commands/doctor.md) | System diagnostics |
| [import](reference/commands/import.md) | Import existing sites |
| [install](reference/commands/install.md) | Install new Drupal sites |
| [live](reference/commands/live.md) | Manage live site deployments |
| [live2prod](reference/commands/live2prod.md) | Sync live to production |
| [live2stg](reference/commands/live2stg.md) | Sync live back to staging |
| [make](reference/commands/make.md) | Generate components |
| [prod2stg](reference/commands/prod2stg.md) | Sync production to staging |
| [report](reference/commands/report.md) | System reporting |
| [restore](reference/commands/restore.md) | Restore from backups |
| [run-tests](reference/commands/run-tests.md) | Unified test runner |
| [security](reference/commands/security.md) | Security scanning |
| [security-check](reference/commands/security-check.md) | Security check details |
| [status](reference/commands/status.md) | Show site status |
| [stg2live](reference/commands/stg2live.md) | Deploy staging to live |
| [stg2prod](reference/commands/stg2prod.md) | Deploy staging to production |
| [test](reference/commands/test.md) | Run site tests |
| [testos](reference/commands/testos.md) | OS testing |
| [verify](reference/commands/verify.md) | Verify site configuration |

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

### Active Proposals

Current proposals under consideration:

| Proposal | Description |
|----------|-------------|
| [F07: SEO & Robots](proposals/F07-seo-robots.md) | SEO optimization and robots.txt |
| [F08: Dynamic Badges](proposals/F08-dynamic-badges.md) | Badge generation system |
| [F09: Comprehensive Testing](proposals/F09-comprehensive-testing.md) | Enhanced testing framework |
| [F10: Local LLM Guide](proposals/F10-local-llm-guide.md) | Local AI development guide |
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

| Document | Description |
|----------|-------------|
| [Email Reply Module](../sites/avc/html/profiles/custom/avc/modules/avc_features/avc_email_reply/README.md) | Email reply system for group notifications |
| [Work Management Implementation](projects/avc/work-management-implementation.md) | AVC work management module |
| [Mobile App Options](projects/avc/mobile-app-options.md) | Mobile application analysis |
| [Hybrid Mobile Approach](projects/avc/hybrid-mobile-approach.md) | Hybrid app strategy |
| [Hybrid Implementation Plan](projects/avc/hybrid-implementation-plan.md) | Implementation roadmap |
| [Python Alternatives](projects/avc/python-alternatives.md) | Backend technology options |

#### Podcast Project

| Document | Description |
|----------|-------------|
| [Podcast Setup](projects/podcast/podcast-setup.md) | Castopod podcast hosting |

### Integration & Completion Documents

Documentation for completed integrations and implementations:

| Document | Description |
|----------|-------------|
| [AVC Moodle Integration Proposal](AVC_MOODLE_INTEGRATION_PROPOSAL.md) | Original Moodle SSO integration proposal |
| [AVC Moodle SSO Implementation](AVC_MOODLE_SSO_IMPLEMENTATION_COMPLETE.md) | Complete SSO implementation details |
| [AVC Moodle SSO Complete](AVC_MOODLE_SSO_COMPLETE.md) | Final SSO implementation summary |
| [NWP Moodle SSO Implementation](NWP_MOODLE_SSO_IMPLEMENTATION.md) | NWP-wide Moodle SSO implementation |
| [Moodle Course Creation Guide](MOODLE_COURSE_CREATION_GUIDE.md) | Guide for creating Moodle courses |
| [Setup Complete](SETUP_COMPLETE.md) | Initial setup completion documentation |
| [Deployment Complete](DEPLOYMENT_COMPLETE.md) | Deployment completion documentation |
| [Verify Enhancements](VERIFY_ENHANCEMENTS.md) | Interactive verification console guide |

### Legal & Licensing

| Document | Description |
|----------|-------------|
| [CC0 Public Domain Dedication](CC0_DEDICATION.md) | Public domain dedication and rationale |
| [Documentation Standards](DOCUMENTATION_STANDARDS.md) | Documentation style guidelines |

### Reports & History

Implementation reports and version history:

| Document | Description |
|----------|-------------|
| [Milestones](reports/milestones.md) | Completed proposals (P01-P35) |
| [Version Changes](reports/version-changes.md) | Version changelog |
| [History](reports/history.md) | Project evolution and documentation history |
| [Documentation Audit](reports/documentation-audit-2026-01-12.md) | January 2026 audit results |
| [Implementation Plan 2026-01](reports/IMPLEMENTATION_PLAN_2026-01.md) | January 2026 implementation roadmap |
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

### Draft Documents

Work in progress specifications:

| Document | Description |
|----------|-------------|
| [AVC Work Management Module](drafts/AVC_WORK_MANAGEMENT_MODULE.md) | Draft module specification |
| [Workflow Access Control Extension](drafts/WORKFLOW_ACCESS_CONTROL_EXTENSION.md) | Draft access control spec |

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
| Live | `sitename.domain` | `mysite.nwpcode.org` |
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

1. Read [DOCUMENTATION_STANDARDS.md](DOCUMENTATION_STANDARDS.md) for style guidelines
2. Place documents in the appropriate subdirectory (guides/, reference/, deployment/, etc.)
3. Update this README.md with links to new documents
4. Include "Last Updated" date in document frontmatter
5. Follow the established naming conventions (lowercase with hyphens)

### Documentation Standards

See [DOCUMENTATION_STANDARDS.md](DOCUMENTATION_STANDARDS.md) for:

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
- [GitLab Setup](../linode/gitlab/README.md) - GitLab server documentation
- [Linode Scripts](../linode/README.md) - Linode provisioning scripts

---

## Need Help?

- **Getting Started:** See [Quickstart Guide](guides/quickstart.md)
- **Installation Issues:** See [Setup Guide](guides/setup.md)
- **Command Help:** Run `pl help` or see [Command Reference](reference/commands/README.md)
- **Feature Questions:** See [Features Reference](reference/features.md)
- **Security Concerns:** See [Security Best Practices](security/data-security-best-practices.md)
- **Testing Problems:** See [Testing Guide](testing/testing.md) or [Manual Testing](testing/human-testing.md)

---

*This documentation structure was established on January 12, 2026 following the documentation reorganization audit. For documentation contribution guidelines, see [DOCUMENTATION_STANDARDS.md](DOCUMENTATION_STANDARDS.md).*
