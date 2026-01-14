# live2stg

Pull site from live server to local staging.

**Last Updated:** 2026-01-14

## Overview

The `live2stg` command pulls a site from a live test server back to local staging. It synchronizes files and optionally the database, useful for bringing live-tested changes back to local development.

## Usage

```bash
pl live2stg [OPTIONS] <sitename>
```

## Arguments

| Argument | Description |
|----------|-------------|
| `sitename` | Site name (with or without `-stg` suffix) |

## Options

| Flag | Description |
|------|-------------|
| `-h, --help` | Show help message |
| `-y, --yes` | Skip confirmation prompts |
| `--files-only` | Pull files only, skip database |
| `--db-only` | Pull database only, skip files |

## Deployment Steps

1. **Test SSH Connection** - Verify access to live server
2. **Pull Files** - Rsync from live to staging (if not `--db-only`)
3. **Pull Database** - Export from live, import to staging (if not `--files-only`)
4. **Clear Cache** - Run `drush cache:rebuild`

## Examples

### Pull live to staging
```bash
pl live2stg mysite
```

### Pull files only
```bash
pl live2stg --files-only mysite
```

### Pull database only
```bash
pl live2stg --db-only mysite
```

## Rsync Excludes

- `.ddev` - Local development environment
- `.git` - Version control
- `web/sites/default/files` - User-uploaded files
- `private` - Private files

## Prerequisites

- Staging site must exist locally
- Live server must be configured in `cnwp.yml`

## Troubleshooting

### Cannot connect to live server
- Check live server status: `pl live --status mysite`
- Verify SSH keys: `ssh gitlab@<live_ip>` or `ssh root@<live_ip>`

### Database export failed
- Verify drush is installed on live server
- Check database credentials in settings.local.php

## Exit Codes

- `0` - Pull successful
- `1` - Pull failed

## Related Commands

- [stg2live](stg2live.md) - Deploy staging to live
- [live](live.md) - Manage live servers
- [prod2stg](prod2stg.md) - Pull production to staging

## See Also

- Live server documentation
