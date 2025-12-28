# Migration Guide: Environment Variables (NWP v0.2)

This guide helps you migrate to NWP's new environment variable system introduced in v0.2.

## What's New in v0.2

NWP now includes a comprehensive environment variable management system:

- **Vortex folder**: Templates and scripts for environment configuration
- **.env files**: Standardized environment variable storage
- **DDEV integration**: Auto-generation of DDEV configuration
- **Secrets management**: Secure handling of credentials
- **Enhanced cnwp.yml**: Support for services and environment-specific settings

## For Existing NWP Users

### Automatic Migration

If you're installing a new site with NWP v0.2+, everything is handled automatically:

```bash
./install.sh d mysite
```

This will:
1. Generate `.env` from your recipe configuration
2. Create `.env.local.example` for local overrides
3. Create `.secrets.example.yml` for credentials
4. Generate DDEV configuration from .env

### Manual Migration (Existing Sites)

If you have existing sites created with older NWP versions:

#### Step 1: Generate Environment Files

```bash
cd your-existing-site
../vortex/scripts/generate-env.sh [recipe] [sitename] .
```

Replace `[recipe]` with your recipe (d, os, nwp, etc.) and `[sitename]` with your site name.

#### Step 2: Review and Customize

1. Review the generated `.env` file
2. Copy `.env.local.example` to `.env.local`
3. Add any site-specific overrides to `.env.local`

#### Step 3: Configure Secrets (Optional)

1. Copy `.secrets.example.yml` to `.secrets.yml`
2. Add your credentials (API keys, passwords, etc.)
3. **Never commit `.secrets.yml`**

#### Step 4: Regenerate DDEV Config (Optional)

```bash
../vortex/scripts/generate-ddev.sh .
ddev restart
```

## For Users Migrating from Other Systems

### From Custom Docker Setup

1. **Map your environment variables** to NWP standards:
   - `YOUR_VAR` → find equivalent in vortex/templates/.env.base
   - Custom variables → add to `.env.local`

2. **Convert to cnwp.yml**:
   ```yaml
   recipes:
     mysite:
       source: your/package
       profile: your_profile
       webroot: web
       dev_modules: devel kint
   ```

3. **Generate NWP environment**:
   ```bash
   ./vortex/scripts/generate-env.sh mysite mysite path/to/site
   ```

### From Vortex/DrevOps

If you're migrating from a Vortex project:

1. **Review your .env file** - most variables are compatible
2. **Map to NWP templates**:
   - `VORTEX_PROJECT` → `PROJECT_NAME`
   - `WEBROOT` → `DRUPAL_WEBROOT`
   - Most `DRUPAL_*` variables work as-is

3. **Create cnwp.yml recipe**:
   ```yaml
   recipes:
     myproject:
       source: drupal/recommended-project
       profile: standard
       webroot: web
   ```

4. **Copy custom variables** to `.env.local`

### From DDEV-only Setup

1. **Extract from .ddev/config.yaml**:
   - `docroot` → `DRUPAL_WEBROOT`
   - `php_version` → add to cnwp.yml settings
   - `web_environment` → add to `.env.local`

2. **Create recipe in cnwp.yml**

3. **Generate environment**:
   ```bash
   ./vortex/scripts/generate-env.sh [recipe] [name] .
   ```

## Environment Variable Reference

### Common Variables You Might Need to Set

In `.env.local`:

```bash
# Local development
ENV_DEBUG=1
XDEBUG_ENABLE=1

# Stage file proxy
STAGE_FILE_PROXY_ORIGIN=https://www.production-site.com

# Database (if using external)
DATABASE_HOST=localhost
DATABASE_NAME=my_database
DATABASE_USER=my_user
DATABASE_PASSWORD=my_password
```

In `.secrets.yml`:

```yaml
api_keys:
  github_token: "ghp_xxxxx"
  composer_auth: '{"github-oauth": {"github.com": "xxxxx"}}'

drupal:
  admin_password: "secure_password"
```

## Troubleshooting

### Variables Not Loading

1. Check `.env` file exists: `ls -la .env`
2. Source it manually: `source .env`
3. For DDEV: `ddev restart`

### Secrets Not Working

1. Verify `.secrets.yml` exists
2. Check YAML syntax
3. Load manually: `source ../vortex/scripts/load-secrets.sh`

### DDEV Config Issues

1. Regenerate: `../vortex/scripts/generate-ddev.sh .`
2. Check config: `cat .ddev/config.yaml`
3. Restart: `ddev restart`

## Best Practices

1. **Never commit secrets**: `.env.local` and `.secrets.yml` are gitignored
2. **Use .env.local for overrides**: Don't edit `.env` directly
3. **Document custom variables**: Add comments explaining custom vars
4. **Keep secrets in .secrets.yml**: Don't put them in `.env.local`
5. **Version control .env.example**: Share examples with your team

## Getting Help

- See `vortex/README.md` for detailed vortex documentation
- See `docs/environment-variables-comparison.md` for architecture details
- Report issues: https://github.com/rjzaar/nwp/issues

## What's Next

Future NWP versions will add:
- Multi-environment support (dev/staging/prod)
- Service management (Redis, Solr, etc.)
- Hosting provider integrations
- CI/CD templates

Check cnwp.yml's `enhanced_example` recipe to see these features in preview.
