# status

**Status:** ACTIVE
**Last Updated:** 2026-01-14

Interactive site management dashboard with health checks, DDEV status, and production monitoring.

## Synopsis

```bash
pl status [COMMAND] [OPTIONS]
```

## Description

The `status` command provides a comprehensive overview of all NWP sites with an interactive TUI for management tasks. It displays site status, health checks, resource usage, and provides quick access to common operations.

## Commands

| Command | Description |
|---------|-------------|
| (none) | Interactive TUI mode (default) |
| `health` | Run health checks on all sites |
| `production` | Show production status dashboard |
| `info <site>` | Show detailed info for specific site |
| `delete <site>` | Delete a site with confirmation |
| `start <site>` | Start DDEV for a site |
| `stop <site>` | Stop DDEV for a site |
| `restart <site>` | Restart DDEV for a site |
| `servers` | Show Linode server statistics |

## Options

| Option | Description |
|--------|-------------|
| `-f, --fast` | Fast text mode (skip interactive TUI) |
| `-r, --recipes` | Show only recipes |
| `-s, --sites` | Show only sites |
| `-v, --verbose` | Show detailed information |
| `-a, --all` | Show all details (health, disk, DB, activity) |
| `-y, --yes` | Skip confirmation prompts |
| `-h, --help` | Show help message |

## Interactive Mode

Default mode with keyboard navigation:

**Navigation:**
- `↑/↓` - Navigate sites
- `←/→` - Select action (Info/Start/Stop/Restart/Health/Delete/Setup)
- `SPACE` - Toggle site selection
- `ENTER` - Execute action on selected sites
- `a` - Select all sites
- `n` - Deselect all sites
- `r` - Refresh (load full data: DDEV, disk, health, SSL)
- `s` - Setup (configure visible columns)
- `q` - Quit

**Columns (Configurable):**
- `NAME` - Site name
- `RECIPE` - Recipe used
- `STG` - Stages (d=dev, s=stg, l=live, p=prod)
- `DDEV` - Container status
- `PURPOSE` - Site purpose (t/i/p/m)
- `DISK` - Directory size
- `DOMAIN` - Live domain
- `USERS` - Active user count
- `DB` - Database size
- `HEALTH` - Health check status
- `ACTIVITY` - Last git commit
- `SSL` - SSL certificate expiry
- `CI` - CI/CD enabled

## Examples

### Interactive Mode

```bash
# Launch interactive TUI
pl status

# Navigate with arrow keys, select actions
```

### Text Mode

```bash
# Fast text status
pl status -f

# Sites only
pl status -s

# Verbose with all details
pl status -v

# Full status with health, disk, DB info
pl status -a
```

### Specific Commands

```bash
# Health checks on all sites
pl status health

# Production dashboard
pl status production

# Detailed info for specific site
pl status info avc

# Site management
pl status start avc
pl status stop test-site
pl status restart nwp
pl status delete old-site

# Linode server statistics
pl status servers
```

## Output

Interactive TUI:

```
┌─────────────────────────────────────────────────────────────┐
│ NWP Status Dashboard                      [r]efresh [q]uit │
├─────────────────────────────────────────────────────────────┤
│ NAME      RECIPE  STG  DDEV     PURPOSE  DISK    HEALTH    │
├─────────────────────────────────────────────────────────────┤
│ avc       avc     dsl  running  perm     1.2GB   ✓         │
│ avc-stg   avc     s    running  indef    1.1GB   ✓         │
│ nwp       nwp     d    running  indef    856MB   ✓         │
│ test-nwp  d       d    stopped  testing  445MB   -         │
└─────────────────────────────────────────────────────────────┘
Actions: [I]nfo [S]tart [T]op [R]estart [H]ealth [D]elete
```

Text mode output:

```
═══════════════════════════════════════════════════════════════
  NWP Site Status
═══════════════════════════════════════════════════════════════

avc (avc recipe)
  DDEV:    running (https://avc.ddev.site)
  Purpose: permanent
  Disk:    1.2 GB
  Health:  ✓ Healthy

avc-stg (avc recipe)
  DDEV:    running (https://avc-stg.ddev.site)
  Purpose: indefinite
  Disk:    1.1 GB
  Health:  ✓ Healthy

nwp (nwp recipe)
  DDEV:    running (https://nwp.ddev.site)
  Purpose: indefinite
  Disk:    856 MB
  Health:  ✓ Healthy

test-nwp (d recipe)
  DDEV:    stopped
  Purpose: testing
  Disk:    445 MB
  Health:  - (not running)

═══════════════════════════════════════════════════════════════
  Summary: 3 running, 1 stopped
═══════════════════════════════════════════════════════════════
```

## Production Dashboard

```bash
pl status production
```

Shows comprehensive production monitoring:

```
═══════════════════════════════════════════════════════════════
  Production Status Dashboard
═══════════════════════════════════════════════════════════════

Site: avc-live (example.com)
  Status:     ✓ Online
  Response:   245ms
  Uptime:     99.98%
  SSL:        Valid (expires 2026-04-15)
  Users:      1,234 active
  DB Size:    2.4 GB
  Disk:       45% used
  Last Deploy: 2026-01-13 14:22:15
  Health:     ✓ All checks passed

Checks:
  ✓ HTTP 200 OK
  ✓ Database connection
  ✓ Redis connection
  ✓ Cron running
  ✓ Security updates current
  ✓ Disk space available
  ✓ SSL certificate valid
```

## See Also

- [install](./install.md) - Install new sites
- [delete](./delete.md) - Delete sites
- [verify](./verify.md) - Verify site configuration
- [Production Deployment](../../deployment/production-deployment.md) - Production monitoring
