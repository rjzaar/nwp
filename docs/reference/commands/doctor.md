# doctor

**Status:** ACTIVE
**Last Updated:** 2026-01-14

Diagnose common issues and verify NWP system configuration and prerequisites.

## Synopsis

```bash
pl doctor [OPTIONS]
```

## Description

The `doctor` command runs comprehensive diagnostic checks on your NWP installation, verifying prerequisites, configuration files, network connectivity, and common issues. It helps identify and troubleshoot problems before they impact your workflow.

## Options

| Option | Description |
|--------|-------------|
| `-v, --verbose` | Show detailed output for all checks |
| `-q, --quiet` | Only show errors |
| `-h, --help` | Show help message |

## Checks Performed

### System Prerequisites
- Docker (running and accessible)
- DDEV (installed and correct version)
- PHP (version compatibility)
- Composer (installed and accessible)
- yq (YAML processor)
- Git (version control)

### Configuration Files
- `cnwp.yml` (exists and valid YAML)
- `.secrets.yml` (exists, not tracked in git)
- Recipe validation
- DDEV configurations

### Network Connectivity
- Linode API (if configured)
- Cloudflare API (if configured)
- drupal.org (package downloads)
- GitHub/GitLab (git repositories)

### Common Issues
- Docker daemon status
- DDEV site states
- Disk space availability
- Memory limits
- Port conflicts
- Permission issues

## Examples

```bash
# Run all diagnostics
pl doctor

# Verbose output for debugging
pl doctor --verbose

# Quiet mode (errors only)
pl doctor --quiet

# Disable color output
NO_COLOR=1 pl doctor
```

## Output

Normal mode:

```
═══════════════════════════════════════════════════════════════
  NWP Doctor - System Diagnostics
═══════════════════════════════════════════════════════════════

Checking prerequisites...
  ✓ Docker (20.10.12)
  ✓ DDEV (v1.21.4)
  ✓ PHP (8.2.15)
  ✓ Composer (2.6.5)
  ✓ yq (4.35.1)
  ✓ Git (2.39.1)

Checking configuration...
  ✓ cnwp.yml exists and is valid
  ✓ .secrets.yml exists
  ✓ Recipes validated (8 recipes found)
  ⚠ .secrets.data.yml not found (optional)

Checking network connectivity...
  ✓ Linode API accessible
  ✓ Cloudflare API accessible
  ✓ drupal.org accessible
  ✓ GitHub accessible

Checking for common issues...
  ✓ Docker daemon running
  ✓ DDEV sites healthy (3 running)
  ✓ Disk space available (45% used)
  ✓ Memory available (8GB total, 2.1GB free)
  ✓ No port conflicts detected

═══════════════════════════════════════════════════════════════
  Diagnosis: System healthy ✓
═══════════════════════════════════════════════════════════════
```

With errors:

```
═══════════════════════════════════════════════════════════════
  NWP Doctor - System Diagnostics
═══════════════════════════════════════════════════════════════

Checking prerequisites...
  ✓ Docker (20.10.12)
  ✗ DDEV not found
  ✓ PHP (8.2.15)
  ✓ Composer (2.6.5)

Checking configuration...
  ✗ cnwp.yml not found
  ✓ .secrets.yml exists

═══════════════════════════════════════════════════════════════
  Diagnosis: 2 errors found
═══════════════════════════════════════════════════════════════

Recommendations:
  1. Install DDEV: ./setup.sh
  2. Create cnwp.yml: cp example.cnwp.yml cnwp.yml
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All checks passed |
| 1 | One or more issues found |

## Troubleshooting

### Docker Not Running

```
✗ Docker daemon not responding
```

**Solution:**
```bash
# Start Docker
sudo systemctl start docker

# Or on macOS
open -a Docker
```

### DDEV Not Found

```
✗ DDEV not found
```

**Solution:**
```bash
# Install prerequisites
./setup.sh
```

### Configuration Missing

```
✗ cnwp.yml not found
```

**Solution:**
```bash
# Copy example configuration
cp example.cnwp.yml cnwp.yml

# Edit with your settings
nano cnwp.yml
```

### Network Issues

```
✗ Cannot connect to drupal.org
```

**Solution:**
- Check internet connection
- Check firewall settings
- Try with VPN if corporate network
- Verify DNS resolution: `ping drupal.org`

## See Also

- [setup](./setup.md) - Initial NWP setup
- [status](./status.md) - Check site status
- [Troubleshooting Guide](../../guides/troubleshooting.md) - Common issues and solutions
