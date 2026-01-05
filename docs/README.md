# NWP Documentation

This directory contains all documentation for the Narrow Way Project (NWP).

## Getting Started

| Document | Description |
|----------|-------------|
| [QUICKSTART.md](QUICKSTART.md) | 5-minute quick start guide |
| [SETUP.md](SETUP.md) | Installation, configuration, and uninstallation |
| [TESTING.md](TESTING.md) | Running tests and code quality checks |
| [CICD.md](CICD.md) | CI/CD pipelines and automation |

## Security & Training

| Document | Description |
|----------|-------------|
| [DATA_SECURITY_BEST_PRACTICES.md](DATA_SECURITY_BEST_PRACTICES.md) | Two-tier secrets architecture, AI safety, security hardening |
| [NWP_TRAINING_BOOKLET.md](NWP_TRAINING_BOOKLET.md) | Comprehensive 8-phase training curriculum |
| [VERIFICATION_GUIDE.md](VERIFICATION_GUIDE.md) | Feature verification tracking system |

## Deployment

| Document | Description |
|----------|-------------|
| [PRODUCTION_DEPLOYMENT.md](PRODUCTION_DEPLOYMENT.md) | Deploying to production |
| [LINODE_DEPLOYMENT.md](LINODE_DEPLOYMENT.md) | Linode-specific deployment |
| [SSH_SETUP.md](SSH_SETUP.md) | SSH key configuration |

## Reference

| Document | Description |
|----------|-------------|
| [FEATURES.md](FEATURES.md) | Complete feature reference by category |
| [LIB_REFERENCE.md](LIB_REFERENCE.md) | Library function API documentation |
| [SCRIPTS_IMPLEMENTATION.md](SCRIPTS_IMPLEMENTATION.md) | Script architecture and details |
| [BACKUP_IMPLEMENTATION.md](BACKUP_IMPLEMENTATION.md) | Backup system implementation |
| [GIT_BACKUP_RECOMMENDATIONS.md](GIT_BACKUP_RECOMMENDATIONS.md) | Git-based backup strategy |

## Project

| Document | Description |
|----------|-------------|
| [ROADMAP.md](ROADMAP.md) | Project roadmap and proposals |
| [CHANGES.md](CHANGES.md) | Version changelog |

## Migration Guides

| Document | Description |
|----------|-------------|
| [MIGRATION_SITES_TRACKING.md](MIGRATION_SITES_TRACKING.md) | Migrating to sites tracking |
| [MIGRATION_GUIDE_ENV.md](MIGRATION_GUIDE_ENV.md) | Environment variable migration |

## Technical Reference

| Document | Description |
|----------|-------------|
| [ARCHITECTURE_ANALYSIS.md](ARCHITECTURE_ANALYSIS.md) | Consolidated research: Vortex comparison, env vars, deployment workflow |
| [podcast_setup.md](podcast_setup.md) | Podcast site configuration |

## Archived Documents

Historical proposals and research documents are in `docs/archive/`:
- Training system planning (Moodle/CodeRunner)
- Email/Postfix infrastructure proposal
- Original Vortex and deployment analysis
- Code reviews and implementation summaries

## Quick Reference

### Common Commands

```bash
# Setup
./setup.sh                    # Interactive setup
./setup.sh --auto             # Auto-install core components

# Site Management
./install.sh recipe sitename  # Install new site
./backup.sh sitename          # Backup site
./restore.sh sitename         # Restore site
./copy.sh source dest         # Copy site
./delete.sh sitename          # Delete site

# Deployment
./dev2stg.sh sitename         # Dev to staging
./stg2prod.sh sitename        # Staging to production

# Testing
./testos.sh -a sitename       # All tests
./testos.sh -b sitename       # Behat tests
./test-nwp.sh                 # NWP self-tests

# CLI (if installed)
pl install recipe sitename
pl backup sitename
pl test sitename
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
| `cnwp.yml` | Main configuration |
| `.secrets.yml` | Credentials (not in git) |
| `example.cnwp.yml` | Configuration template |

## Related Documentation

- [Main README](../README.md) - Project overview
- [CLAUDE.md](../CLAUDE.md) - AI assistant instructions and protected files
- [KNOWN_ISSUES.md](../KNOWN_ISSUES.md) - Current known issues and test failures
- [GitLab Setup](../linode/gitlab/README.md) - GitLab server, Composer registry, and migration
- [Linode Scripts](../linode/README.md) - Linode provisioning
- [Vortex Environment](../vortex/README.md) - Environment configuration system
