# NWP Documentation

This directory contains all documentation for the Narrow Way Project (NWP).

**29 active documents** organized by category.

---

## Getting Started

| Document | Description |
|----------|-------------|
| [QUICKSTART.md](QUICKSTART.md) | 5-minute quick start guide |
| [SETUP.md](SETUP.md) | Installation, configuration, and uninstallation |
| [FEATURES.md](FEATURES.md) | Complete feature reference by category |

## Reference

| Document | Description |
|----------|-------------|
| [LIB_REFERENCE.md](LIB_REFERENCE.md) | Library function API documentation |
| [SCRIPTS_IMPLEMENTATION.md](SCRIPTS_IMPLEMENTATION.md) | Script architecture and implementation details |
| [BACKUP_IMPLEMENTATION.md](BACKUP_IMPLEMENTATION.md) | Backup system implementation |
| [ARCHITECTURE_ANALYSIS.md](ARCHITECTURE_ANALYSIS.md) | Research: Vortex comparison, env vars, workflows |

## Deployment

| Document | Description |
|----------|-------------|
| [PRODUCTION_DEPLOYMENT.md](PRODUCTION_DEPLOYMENT.md) | Deploying to production servers |
| [ADVANCED_DEPLOYMENT.md](ADVANCED_DEPLOYMENT.md) | Blue-green deployment, canary releases |
| [LINODE_DEPLOYMENT.md](LINODE_DEPLOYMENT.md) | Linode infrastructure guide |
| [SSH_SETUP.md](SSH_SETUP.md) | SSH key configuration |
| [ENVIRONMENTS.md](ENVIRONMENTS.md) | Four-tier environment model (dev/stg/live/prod) |
| [DISASTER_RECOVERY.md](DISASTER_RECOVERY.md) | Recovery procedures and RTO/RPO targets |

## Testing

| Document | Description |
|----------|-------------|
| [TESTING.md](TESTING.md) | Automated testing: Behat, PHPUnit, PHPStan |
| [HUMAN_TESTING.md](HUMAN_TESTING.md) | Manual test procedures (12 categories) |
| [VERIFICATION_GUIDE.md](VERIFICATION_GUIDE.md) | Feature verification tracking system |

## CI/CD & Git

| Document | Description |
|----------|-------------|
| [CICD.md](CICD.md) | CI/CD pipelines: GitLab CI, GitHub Actions |
| [GIT_BACKUP_RECOMMENDATIONS.md](GIT_BACKUP_RECOMMENDATIONS.md) | Git-based backup strategy |
| [CHANGES.md](CHANGES.md) | Version changelog |

## Security & Best Practices

| Document | Description |
|----------|-------------|
| [DATA_SECURITY_BEST_PRACTICES.md](DATA_SECURITY_BEST_PRACTICES.md) | Two-tier secrets, AI safety, security hardening |
| [WHY.md](WHY.md) | Design decisions and architecture rationale |

## Training & Guides

| Document | Description |
|----------|-------------|
| [NWP_TRAINING_BOOKLET.md](NWP_TRAINING_BOOKLET.md) | Comprehensive 8-phase training curriculum |
| [DEVELOPER_LIFECYCLE_GUIDE.md](DEVELOPER_LIFECYCLE_GUIDE.md) | 9-phase developer workflow guide |
| [CODER_ONBOARDING.md](CODER_ONBOARDING.md) | Multi-coder infrastructure setup |

## Planning & History

| Document | Description |
|----------|-------------|
| [ROADMAP.md](ROADMAP.md) | Pending & future work (F01-F03) |
| [MILESTONES.md](MILESTONES.md) | Completed implementation history (P01-P35) |

## Specialized

| Document | Description |
|----------|-------------|
| [podcast_setup.md](podcast_setup.md) | Castopod podcast hosting setup |
| [MIGRATION_SITES_TRACKING.md](MIGRATION_SITES_TRACKING.md) | Migrating to sites tracking system |

---

## Archived Documents

Historical proposals and research in `docs/archive/` (14 files):

| Category | Files |
|----------|-------|
| **Implemented Proposals** | dev2stg-enhancement, IMPORT, multi-coder-dns, LIVE_DEPLOYMENT_AUTOMATION, NWP_COMPLETE_ROADMAP |
| **Superseded Research** | VORTEX_COMPARISON, DEPLOYMENT_WORKFLOW_ANALYSIS, environment-variables-comparison |
| **Historical Guides** | MIGRATION_GUIDE_ENV, IMPLEMENTATION_SUMMARY |
| **Future Proposals** | EMAIL_POSTFIX_PROPOSAL, NWP_TRAINING_SYSTEM, NWP_TRAINING_IMPLEMENTATION_PLAN |
| **Reviews** | CODE_REVIEW_2024-12 |

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

# Or use scripts directly
./scripts/commands/install.sh nwp mysite
./scripts/commands/backup.sh mysite
```

### Environment Naming

| Environment | Pattern | Example |
|-------------|---------|---------|
| Development | `sitename` | `mysite` |
| Staging | `sitename_stg` | `mysite_stg` |
| Live | `sitename.domain` | `mysite.nwpcode.org` |
| Production | Custom domain | `mysite.com` |

### Configuration Files

| File | Purpose |
|------|---------|
| `cnwp.yml` | Main configuration (user-specific, not in git) |
| `example.cnwp.yml` | Configuration template |
| `.secrets.yml` | Infrastructure credentials |
| `.secrets.data.yml` | Production credentials (blocked from AI) |

---

## Related Documentation

- [Main README](../README.md) - Project overview
- [CLAUDE.md](../CLAUDE.md) - AI assistant instructions
- [KNOWN_ISSUES.md](../KNOWN_ISSUES.md) - Current known issues
- [GitLab Setup](../linode/gitlab/README.md) - GitLab server documentation
- [Linode Scripts](../linode/README.md) - Linode provisioning

---

*Last updated: January 5, 2026*
