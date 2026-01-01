# Migration Guide: Sites Tracking System

## Overview

This guide helps you migrate existing NWP sites to the new sites tracking system introduced in v0.7+.

The new system automatically tracks installed sites in `cnwp.yml` with:
- Directory path and recipe used
- Environment type (development/staging/production)
- Installed modules
- Production deployment configuration
- Creation timestamp

## What's Changed

### Before (v0.6 and earlier)
- Sites were not tracked in cnwp.yml
- No automatic cleanup when sites were deleted
- Manual configuration required for production deployments
- Module reinstallation not supported

### After (v0.7+)
- Sites automatically registered in `cnwp.yml` after installation
- Automatic cleanup when sites are deleted (configurable)
- Production deployment configuration stored and used by `stg2prod.sh`
- Module reinstallation supported via `reinstall_modules` in recipes

## Migration Steps

### Option 1: Automatic Migration (Recommended)

A migration script will be provided to automatically scan your existing sites and register them in `cnwp.yml`.

```bash
# Coming soon: Auto-migration script
# ./migrate-to-sites-tracking.sh
```

### Option 2: Manual Migration

If you prefer to manually register your existing sites:

#### 1. Update cnwp.yml Structure

Ensure your `cnwp.yml` has the new sections:

```yaml
settings:
  # ... existing settings ...

  # New: Site management settings
  delete_site_yml: true  # Remove site from cnwp.yml when deleted
```

Add empty `sites:` section if not present:

```yaml
sites:
  # Sites will be registered here automatically
```

#### 2. Register Existing Sites

For each existing site, add an entry under `sites:`:

```yaml
sites:
  mysite:
    directory: /home/user/nwp/mysite
    recipe: nwp
    environment: development
    created: 2024-12-29T00:00:00Z
    installed_modules:
      - devel
      - kint
    # Optional: production config
    production_config:
      method: rsync
      server: linode_primary
      remote_path: /var/www/mysite
      domain: mysite.example.com
```

#### 3. Determine Environment Type

Sites are categorized by suffix:
- `sitename` → development
- `sitename_dev` → development
- `sitename_stg` → staging
- `sitename_prod` → production

#### 4. Find Installed Modules

Check `install_modules` in your recipe or run:

```bash
cd /path/to/site
ddev drush pm:list --status=enabled --type=module | grep -v "^Package"
```

#### 5. Add Production Configuration (Optional)

If you deploy to production, add the configuration:

```yaml
production_config:
  method: rsync              # Deployment method
  server: linode_primary     # Reference to linode.servers entry
  remote_path: /var/www/site # Remote path on server
  domain: example.com        # Production domain
```

## New Linode Configuration

If you deploy to Linode, add server configuration:

```yaml
linode:
  servers:
    linode_primary:
      ssh_user: deploy
      ssh_host: 203.0.113.10  # Your actual Linode IP
      ssh_port: 22
      api_token: ${LINODE_API_TOKEN}  # Use environment variable
      server_ips:
        - 203.0.113.10
      domains:
        - example.com
```

## Recipe Updates for Module Reinstallation

Update your recipes to specify modules that should be reinstalled during deployments:

```yaml
recipes:
  nwp:
    # ... existing config ...
    reinstall_modules: custom_module another_module  # Space-separated

    # Optional: production deployment config
    prod_method: rsync
    prod_server: linode_primary
    prod_domain: example.com
    prod_path: /var/www/nwp
```

## Verifying Migration

### Check Site Registration

```bash
# View sites section in cnwp.yml
grep -A 10 "^sites:" cnwp.yml
```

### Test YAML Library

```bash
# Run unit tests
./tests/test-yaml-write.sh

# Run integration tests
./tests/test-integration.sh
```

### Test Site Deletion

```bash
# Test with --keep-yml flag (preserves entry)
./delete.sh --keep-yml test_site

# Normal deletion (removes from cnwp.yml)
./delete.sh test_site
```

### Test Production Deployment

```bash
# Dry run first
./stg2prod.sh --dry-run mysite

# Actual deployment
./stg2prod.sh mysite
```

## Backward Compatibility

The new system is fully backward compatible:

- ✅ Sites tracking is **optional** - all scripts work without it
- ✅ Existing cnwp.yml files continue to work
- ✅ Scripts gracefully handle missing YAML library
- ✅ No breaking changes to existing functionality

If the YAML library is not available:
- install.sh: Skips site registration
- delete.sh: Skips cnwp.yml cleanup
- dev2stg.sh/stg2prod.sh: Falls back to base name as recipe

## Troubleshooting

### Site Not Registered After Installation

**Cause**: YAML library not available or error during registration

**Solution**:
```bash
# Manually register the site
source lib/yaml-write.sh
yaml_add_site "sitename" "/full/path" "recipe" "development" "cnwp.yml"
```

### Site Not Removed After Deletion

**Cause**: `delete_site_yml: false` in settings or `--keep-yml` flag used

**Solution**:
```bash
# Check setting
grep "delete_site_yml" cnwp.yml

# Manually remove
source lib/yaml-write.sh
yaml_remove_site "sitename" "cnwp.yml"
```

### Module Reinstallation Not Working

**Cause**: `reinstall_modules` not set in recipe

**Solution**:
```yaml
# Add to recipe in cnwp.yml
recipes:
  myrecipe:
    reinstall_modules: module1 module2
```

### Production Deployment Fails

**Cause**: Missing production configuration or SSH issues

**Solution**:
```bash
# Check configuration
grep -A 5 "prod_" cnwp.yml | grep myrecipe

# Test SSH connection
ssh deploy@your-server.com echo "Connection OK"

# Run with debug
./stg2prod.sh --debug mysite
```

## Getting Help

If you encounter issues during migration:

1. Check the test results: `./tests/test-yaml-write.sh`
2. Review the integration tests: `./tests/test-integration.sh`
3. Check the example configuration: `example.cnwp.yml`
4. Review production deployment docs: `docs/PRODUCTION_DEPLOYMENT.md`
5. Report issues at: https://github.com/anthropics/claude-code/issues

## Next Steps

After migration:

1. ✅ Verify all existing sites are registered
2. ✅ Test site deletion with a test site
3. ✅ Configure Linode servers if using production deployment
4. ✅ Test module reinstallation with dev2stg.sh
5. ✅ Test production deployment with --dry-run first
6. ✅ Update team documentation with new workflows

## See Also

- [Production Deployment Guide](PRODUCTION_DEPLOYMENT.md)
- [ROADMAP.md](ROADMAP.md) - Project roadmap
- [example.cnwp.yml](../example.cnwp.yml) - Configuration examples
