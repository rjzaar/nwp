# NWP Quick Start Guide

Get up and running with NWP in 5 minutes.

## Prerequisites

- Ubuntu/Debian Linux (or WSL2 on Windows)
- Git installed
- Sudo access

## Step 1: Clone and Setup

```bash
# Clone the repository
git clone git@github.com:rjzaar/nwp.git ~/nwp
cd ~/nwp

# Run automated setup
./pl setup --auto
```

This installs Docker, DDEV, mkcert, and the NWP CLI (`pl` command).

## Step 2: Create Your First Site

```bash
# See which recipes YOUR install actually offers first
pl install --list

# Install a Drupal site using the 'd' recipe (if your nwp.yml defines it —
# the shipped example.nwp.yml defines only 'pod')
pl install d mysite
```

Wait 2-3 minutes for installation to complete.

## Step 3: Access Your Site

```bash
# Open in browser (from the site's DEV environment directory)
cd sites/mysite/dev
ddev launch

# Or get the URL
ddev describe
```

Your site is available at `https://mysite-dev.ddev.site`

> **Layout note (v2).** Code lives under `sites/<name>/dev/`, and the DDEV project
> is named `<name>-dev`. Staging is `sites/<name>/stg/` (`<name>-stg`).

## Common Operations

### Backup and Restore

```bash
# Create backup
pl backup mysite

# List backups
ls sites/mysite/backups/
# (the legacy location sitebackups/<name>/ is still read for unmigrated sites)

# Restore from backup
pl restore mysite
```

### Development to Staging

```bash
# Create and populate staging in one step (it offers to create stg if missing)
pl dev2stg mysite
```

See [How to: deploy a change](howto-deploy.md) for the full picture.

### Running Tests

```bash
# All tests (run from nwp root or use full path)
pl testos -a mysite

# Just code quality
pl testos -s mysite    # PHPStan
pl testos -c mysite    # CodeSniffer
```

### Frontend Theming

```bash
# Install theme dependencies
pl theme setup mysite

# Start watch mode with live reload
pl theme watch mysite

# Production build
pl theme build mysite

# Show detected build tool
pl theme info mysite
```

## CLI Reference

The `pl` CLI is installed by default during setup:

| Command | Description |
|---------|-------------|
| `pl install d sitename` | Install Drupal site |
| `pl backup sitename` | Backup site |
| `pl restore sitename` | Restore from backup |
| `pl copy from to` | Copy site |
| `pl delete sitename` | Delete site |
| `pl status` | Check all sites |
| `pl theme <cmd> sitename` | Frontend build tooling |
| `pl install --list` | List available recipes |
| `pl --help` | Show all commands |

## Available Recipes

View the recipes **your** install actually offers:

```bash
pl install --list
```

Recipes are defined in the `recipes:` block of your own `nwp.yml` — there is no
`recipes/` directory. The shipped template `example.nwp.yml` defines only `pod`;
the fuller catalogue (`d`, `os`, `avc`, `dm`, `m`, `gitlab`, `pod`) lives in
`example.nwp.v2.yml` or an operator overlay. Commonly referenced:
- `d` - Standard Drupal
- `os` - OpenSocial
- `m` - Moodle

## Configuration

Edit `nwp.yml` to customize:

```yaml
settings:
  php: 8.2
  database: mariadb

recipes:
  myrecipe:
    source: drupal/recommended-project:^10.2
    profile: standard
```

## Next Steps

1. **Full Setup** - Run `./pl setup` for interactive component selection
2. **Testing** - Read [Testing Guide](../testing/testing.md) for test details
3. **CI/CD** - Read [CI/CD Guide](../deployment/cicd.md) for automation
4. **Production** - Read [Production Deployment](../deployment/production-deployment.md)

## Troubleshooting

### Docker Permission Denied

```bash
sudo usermod -aG docker $USER
# Log out and back in
```

### DDEV Not Found

```bash
./pl setup --auto
```

### Site Won't Start

```bash
cd sites/mysite
ddev restart
ddev logs
```

## Getting Help

- Full documentation: [docs/README.md](README.md)
- Main README: [../README.md](../README.md)
- Issue tracker: https://github.com/rjzaar/nwp/issues
