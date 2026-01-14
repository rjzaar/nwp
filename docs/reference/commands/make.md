# make

**Status:** ACTIVE
**Last Updated:** 2026-01-14

Toggle development and production modes for Drupal sites, managing modules and optimization settings.

## Synopsis

```bash
pl make [OPTIONS] <sitename>
```

## Description

The `make` command switches sites between development and production modes, automatically managing development modules, Composer dependencies, and performance optimizations.

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `sitename` | Yes | Name of the DDEV site |

## Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |
| `-d, --debug` | Enable debug output |
| `-v, --dev` | Enable development mode |
| `-p, --prod` | Enable production mode |
| `-y, --yes` | Skip confirmation prompts |

**Note:** Must specify either `-v` (dev) or `-p` (prod) mode.

## Development Mode

Enables development tools and debugging:

1. Install development Composer packages
2. Enable development Drupal modules
3. Disable production optimizations (aggregation, caching)
4. Set Twig debug mode
5. Clear cache
6. Display dev mode status

**Development modules:**
- `devel` - Development tools
- `webprofiler` - Performance profiling
- `kint` - Variable dumping
- `stage_file_proxy` - Proxy files from production

## Production Mode

Optimizes for production deployment:

1. Disable/uninstall development modules
2. Remove development Composer packages (`--no-dev`)
3. Enable production optimizations (aggregation, caching)
4. Disable Twig debug mode
5. Export configuration
6. Clear cache

## Examples

```bash
# Enable development mode
pl make -v nwp

# Enable production mode
pl make -p nwp

# Dev mode with auto-confirm
pl make -vy nwp

# Production mode with auto-confirm
pl make -py nwp

# Dev mode with debug output
pl make -vdy nwp
```

## Output

Development mode:

```
═══════════════════════════════════════════════════════════════
  Development Mode: nwp
═══════════════════════════════════════════════════════════════

[1/6] Install development packages
✓ Composer dependencies installed

[2/6] Enable development modules
✓ Modules enabled: devel, webprofiler, kint

[3/6] Disable production optimizations
✓ Caching disabled
✓ Aggregation disabled

[4/6] Set Twig debug mode
✓ Twig debugging enabled

[5/6] Clear cache
✓ Cache cleared

[6/6] Display status
✓ Development mode active

═══════════════════════════════════════════════════════════════
  Development Mode Enabled
═══════════════════════════════════════════════════════════════

Site: https://nwp.ddev.site
Modules: devel, webprofiler, kint, stage_file_proxy
Twig Debug: Enabled
Caching: Disabled
```

Production mode:

```
═══════════════════════════════════════════════════════════════
  Production Mode: nwp
═══════════════════════════════════════════════════════════════

[1/6] Disable development modules
✓ Modules disabled: devel, webprofiler, kint

[2/6] Remove development packages
✓ Composer --no-dev complete

[3/6] Enable production optimizations
✓ Caching enabled
✓ Aggregation enabled

[4/6] Disable Twig debug mode
✓ Twig debugging disabled

[5/6] Export configuration
✓ Configuration exported

[6/6] Clear cache
✓ Cache cleared

═══════════════════════════════════════════════════════════════
  Production Mode Enabled
═══════════════════════════════════════════════════════════════

Site ready for deployment
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Mode change successful |
| 1 | Mode change failed |
| 2 | Missing sitename or mode flag |
| 3 | Site not found |

## See Also

- [dev2stg](./dev2stg.md) - Deploy to staging (auto-enables production mode)
- [stg2prod](./stg2prod.md) - Deploy to production
- [status](./status.md) - Check current site mode
