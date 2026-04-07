# NWP Command Reference

Comprehensive reference documentation for all NWP CLI commands.

## Quick Reference

All commands are accessed via the `pl` CLI wrapper:

```bash
pl <command> [options] [arguments]
```

## Command Categories

### Site Management
| Command | Description | Documentation |
|---------|-------------|---------------|
| `install` | Install new Drupal sites with recipes | [install.md](install.md) ✓ |
| `delete` | Delete sites and cleanup resources | [delete.md](delete.md) ✓ |
| `copy` | Copy/clone sites | [copy.md](copy.md) ✓ |
| `status` | Show site status and health | [status.md](status.md) ✓ |
| `verify` | Verify site configuration and setup | [verify.md](verify.md) ✓ |
| `modify` | Modify site configuration | [modify.md](modify.md) |
| `make` | Generate new components (modules, themes) | [make.md](make.md) ✓ |
| `theme` | Theme management | [theme.md](theme.md) |

### Backup & Restore
| Command | Description | Documentation |
|---------|-------------|---------------|
| `backup` | Create site backups | [backup.md](backup.md) ✓ |
| `restore` | Restore from backups | [restore.md](restore.md) ✓ |
| `rollback` | Rollback deployments | [rollback.md](rollback.md) |

### Deployment & Sync
| Command | Description | Documentation |
|---------|-------------|---------------|
| `dev2stg` | Deploy development to staging | [dev2stg.md](dev2stg.md) ✓ |
| `stg2prod` | Deploy staging to production | [stg2prod.md](stg2prod.md) ✓ |
| `stg2live` | Deploy staging to live | [stg2live.md](stg2live.md) ✓ |
| `live2stg` | Sync live back to staging | [live2stg.md](live2stg.md) ✓ |
| `live2prod` | Sync live to production | [live2prod.md](live2prod.md) ✓ |
| `prod2stg` | Sync production to staging | [prod2stg.md](prod2stg.md) ✓ |
| `live` | Manage live site deployments | [live.md](live.md) ✓ |
| `sync` | Synchronization operations | [sync.md](sync.md) |
| `produce` | Production operations | [produce.md](produce.md) |

### Testing & Quality
| Command | Description | Documentation |
|---------|-------------|---------------|
| `test` | Run site tests | [test.md](test.md) ✓ |
| `verify --run` | NWP verification runner | [verify.md](verify.md) |
| `run-tests` | Unified test runner | [run-tests.md](run-tests.md) ✓ |
| `testos` | OS testing | [testos.md](testos.md) ✓ |

### Security
| Command | Description | Documentation |
|---------|-------------|---------------|
| `security` | Security audits and updates | [security.md](security.md) ✓ |
| `security-check` | HTTP security headers check | [security-check.md](security-check.md) ✓ |
| `seo-check` | SEO validation | [seo-check.md](seo-check.md) |

### Migration & Import
| Command | Description | Documentation |
|---------|-------------|---------------|
| `import` | Import external sites | [import.md](import.md) ✓ |
| `migration` | Site migration workflow | [migration.md](migration.md) |
| `migrate-secrets` | Migrate secrets configuration | [migrate-secrets.md](migrate-secrets.md) |

### Coder Management
| Command | Description | Documentation |
|---------|-------------|---------------|
| `coders` | Multi-coder TUI management | [coders.md](coders.md) ✓ |
| `coder-setup` | Coder provisioning/removal | [coder-setup.md](coder-setup.md) ✓ |
| `contribute` | Contribution workflow | [contribute.md](contribute.md) ✓ |
| `upstream` | Upstream sync | [upstream.md](upstream.md) |

### Infrastructure
| Command | Description | Documentation |
|---------|-------------|---------------|
| `setup` | Initial NWP setup | [setup.md](setup.md) |
| `setup-ssh` | SSH key generation | [setup-ssh.md](setup-ssh.md) |
| `doctor` | System diagnostics and troubleshooting | [doctor.md](doctor.md) ✓ |
| `email` | Email configuration | [email.md](email.md) |
| `storage` | Storage management | [storage.md](storage.md) |
| `schedule` | Cron scheduling | [schedule.md](schedule.md) |
| `podcast` | Podcast site setup | [podcast.md](podcast.md) |

### Utilities
| Command | Description | Documentation |
|---------|-------------|---------------|
| `badges` | Dynamic badges generation | [badges.md](badges.md) ✓ |
| `report` | Error reporting to GitLab | [report.md](report.md) ✓ |
| `uninstall_nwp` | NWP uninstallation | [uninstall_nwp.md](uninstall_nwp.md) |

## Documentation Status

✓ = Documented (complete reference available)

**Documentation Coverage: 56% (27/48 commands)**

Updated: 2026-01-14

## Getting Help

For any command, use the `--help` flag:

```bash
pl <command> --help
```

## Common Options

Many commands support these common options:

- `-h, --help` - Show help message
- `-y, --yes` - Auto-confirm prompts
- `-v, --verbose` - Verbose output
- `-d, --debug` - Debug mode
- `--dry-run` - Show what would be done without making changes

## Configuration

Commands read configuration from:

- `nwp.yml` - Main site configuration
- `.secrets.yml` - API keys and credentials (never committed)
- `.env` files - Environment-specific settings

## Exit Codes

Standard exit codes:

- `0` - Success
- `1` - General error
- `2` - Invalid arguments
- `3` - Missing prerequisites

## Examples

### Complete Site Setup
```bash
# Install new Drupal 11 site
pl install d mysite

# Run tests
pl test mysite

# Deploy to staging
pl dev2stg mysite

# Deploy to production
pl stg2prod mysite
```

### Import External Site
```bash
# Interactive import
pl import

# Import specific site
pl import oldsite --server=production --source=/var/www/oldsite/web
```

### Security Workflow
```bash
# Check for security updates
pl security check mysite

# Apply updates
pl security update mysite

# Verify HTTP headers
pl security-check https://mysite.example.com
```

### Coder Management
```bash
# Launch coder management TUI
pl coders

# Add new coder
pl coder-setup add john --email john@example.com

# Submit contribution
pl contribute
```

## Command Line Interface

The `pl` wrapper provides:

- Tab completion (if configured)
- Consistent error handling
- Colored output
- Progress indicators
- Logging

## Error Reporting

Use the `report` wrapper to automatically create GitLab issues on failure:

```bash
pl report backup mysite
```

## Advanced Usage

### Chaining Commands

```bash
# Backup, update, and deploy
pl backup mysite && \
pl security update mysite && \
pl dev2stg mysite
```

### Batch Operations

```bash
# Check security on all sites
pl security check --all

# Run tests on multiple sites
for site in site1 site2 site3; do
  pl test $site
done
```

## Contributing

See [contribute.md](contribute.md) for information on submitting improvements to NWP.

## Related Documentation

- [Main README](../../../README.md) - Main NWP documentation
- [Roadmap](../../governance/roadmap.md) - Future plans
- [Milestones](../../reports/milestones.md) - Version history
- [Architecture Decisions](../../decisions/) - Architecture Decision Records

## Support

- Report bugs: Use `pl report <command>` when a command fails
- Ask questions: Create an issue on GitLab
- Documentation: Check command-specific `.md` files

---

Last Updated: 2026-01-14
NWP Version: 0.22.0
