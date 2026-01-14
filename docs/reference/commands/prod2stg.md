# prod2stg

Pull code and database from production server to local staging.

**Last Updated:** 2026-01-14

## Overview

The `prod2stg` command pulls a site from a production Linode server to a local staging environment. It synchronizes files, exports/imports the database, and runs post-import configuration steps.

## Usage

```bash
pl prod2stg [OPTIONS] <sitename>
```

## Arguments

| Argument | Description |
|----------|-------------|
| `sitename` | Name of the staging site (e.g., `nwp-stg`) |

## Options

| Flag | Description |
|------|-------------|
| `-y, --yes` | Auto-confirm (skip all prompts) |
| `-d, --debug` | Enable debug output |
| `--step=N` | Start from step N (1-10) |
| `--dry-run` | Show what would be done without making changes |
| `--files-only` | Pull only files, skip database |
| `--db-only` | Pull only database, skip files |
| `-h, --help` | Show help message |

## Deployment Steps

1. **Validate Pull Configuration** - Check staging site exists, verify production config
2. **Test SSH Connection** - Verify SSH access to production server
3. **Backup Local Staging** - Create backup before overwriting
4. **Pull Files from Production** - Rsync files from production (excludes files/, private/)
5. **Export Production Database** - Run `drush sql:dump --gzip` on production
6. **Import Database to Staging** - Import via `ddev import-db`
7. **Update Database** - Run `drush updatedb -y`
8. **Import Configuration** - Run `drush config:import -y`
9. **Reinstall Modules** - Reinstall modules from recipe config
10. **Clear Cache** - Run `drush cr`

## Examples

### Pull production to staging
```bash
pl prod2stg nwp-stg
```

### Pull with auto-confirm
```bash
pl prod2stg -y nwp-stg
```

### Pull only files
```bash
pl prod2stg --files-only nwp-stg
```

### Pull only database
```bash
pl prod2stg --db-only nwp-stg
```

### Dry run (show what would happen)
```bash
pl prod2stg --dry-run nwp-stg
```

### Resume from step 5
```bash
pl prod2stg --step=5 nwp-stg
```

## Configuration

Production configuration is read from `cnwp.yml`:

### Site-specific config
```yaml
sites:
  nwp:
    recipe: nwp
    production_config:
      server: prod1
      remote_path: /var/www/nwp
      domain: example.com
```

### Recipe default config
```yaml
recipes:
  nwp:
    prod_server: prod1
    prod_path: /var/www/nwp
    prod_domain: example.com
```

### Linode server config
```yaml
linode:
  servers:
    prod1:
      ssh_user: root
      ssh_host: 192.0.2.10
      ssh_port: 22
      ssh_key: ~/keys/nwp
```

## Prerequisites

- Local staging site must exist
- SSH access to production server configured
- Production configuration in `cnwp.yml`
- Production server must have drush installed

## Rsync Excludes

- `.ddev` - Local development environment
- `.git` - Version control
- `html/sites/default/files` - User-uploaded files (large, not needed locally)
- `private` - Private files

## Troubleshooting

### SSH connection failed
- Verify SSH key path in cnwp.yml
- Test manual connection: `ssh -i <key> <user>@<host>`
- Check SSH port if not default 22

### Database export failed
- Check drush is installed on production
- Verify production path is correct
- Ensure SSH user has permissions

### Database import failed
- Check DDEV is running: `ddev describe`
- Verify SQL dump file exists in /tmp
- Check disk space

## Exit Codes

- `0` - Pull successful
- `1` - Pull failed

## Related Commands

- [stg2prod](stg2prod.md) - Deploy staging to production
- [backup](backup.md) - Create backups
- [restore](restore.md) - Restore from backup

## See Also

- Production deployment workflow documentation
- SSH configuration guide
