# NWP Vortex Configuration

This directory contains environment configuration templates and utilities for the Narrow Way Project (NWP).

## Overview

The `vortex` folder provides a standardized approach to environment variable management, inspired by the DrevOps Vortex framework but adapted for NWP's recipe-based workflow.

## Directory Structure

```
vortex/
├── README.md                    # This file
├── templates/                   # Environment templates
│   ├── .env.base               # Base environment template
│   ├── .env.drupal             # Drupal standard recipe
│   ├── .env.social             # Open Social recipe
│   ├── .env.varbase            # Varbase recipe
│   ├── .env.local.example      # Local overrides example
│   ├── .secrets.example.yml    # Infrastructure secrets template
│   └── .secrets.data.example.yml # Data secrets template (AI blocked)
└── scripts/                     # Utility scripts
    ├── generate-env.sh         # Generate .env from cnwp.yml
    ├── generate-ddev.sh        # Generate DDEV config
    └── load-secrets.sh         # Load secrets (supports two-tier)
```

## How It Works

### 1. Configuration Hierarchy

NWP uses a flexible configuration system with clear precedence:

**For cnwp.yml configuration:**
1. **Recipe-specific** settings (e.g., `recipes.mysite.services.redis.enabled`)
2. **Global defaults** in settings (e.g., `settings.services.redis.enabled`)
3. **Profile-based** defaults (e.g., redis=true for social/varbase profiles)
4. **Hardcoded** defaults (final fallback)

**Example:**
```yaml
# cnwp.yml
settings:
  services:
    redis:
      enabled: false      # Default for all recipes
      version: "7"

recipes:
  mysite:
    services:
      redis:
        enabled: true     # Override just for mysite
        # version: "7" inherited from settings
```

This allows you to:
- Set common defaults once in `settings`
- Override per recipe only when needed
- Keep recipes minimal and focused

### 2. Environment Files

NWP generates environment configuration files in each site directory based on:
- The recipe configuration in `cnwp.yml` (with fallback to settings)
- The appropriate template from `vortex/templates/`
- Local overrides from `.env.local` (if present)
- Secrets from `.secrets.yml` (if present)

### 3. File Priority

Environment variables are loaded in this order (later overrides earlier):

1. **Template** (`vortex/templates/.env.[recipe]`) - Recipe defaults
2. **Generated** (`.env`) - Generated from cnwp.yml + template
3. **Local** (`.env.local`) - Local developer overrides
4. **Secrets** (`.secrets.yml`) - Sensitive credentials

### 3. Templates

Each template provides sensible defaults for a specific recipe:

- **`.env.base`** - Base template with all available variables
- **`.env.drupal`** - Drupal standard installation
- **`.env.social`** - Open Social distribution
- **`.env.varbase`** - Varbase distribution

## Usage

### Creating a New Site

When you run `./install.sh [recipe] [sitename]`, NWP automatically:

1. Determines the recipe (d, os, nwp, etc.)
2. Selects the appropriate template
3. Generates `.env` file in the site directory
4. Copies `.env.local.example` for customization
5. Copies `.secrets.example.yml` for credentials

### Customizing Environment

#### For Local Development

1. Copy `.env.local.example` to `.env.local`:
   ```bash
   cd mysite
   cp .env.local.example .env.local
   ```

2. Edit `.env.local` with your local settings:
   ```bash
   # .env.local
   ENV_DEBUG=1
   XDEBUG_ENABLE=1
   STAGE_FILE_PROXY_ORIGIN=https://www.example.com
   ```

#### For Secrets (Two-Tier Architecture)

NWP uses a two-tier secrets system for AI assistant safety:

| File | Contains | AI Access |
|------|----------|-----------|
| `.secrets.yml` | API tokens, dev credentials | Allowed |
| `.secrets.data.yml` | Production passwords, SSH keys | Blocked |

**Infrastructure secrets** (safe for AI):

1. Copy `.secrets.example.yml` to `.secrets.yml`:
   ```bash
   cd mysite
   cp .secrets.example.yml .secrets.yml
   ```

2. Edit `.secrets.yml` with API tokens and dev credentials:
   ```yaml
   # .secrets.yml - Infrastructure (AI can help with these)
   api_keys:
     github_token: "ghp_xxxxxxxxxxxx"
   drupal:
     admin_password: "dev_password"  # Development only
   ```

**Data secrets** (blocked from AI):

1. Copy `.secrets.data.example.yml` to `.secrets.data.yml`:
   ```bash
   cd mysite
   cp .secrets.data.example.yml .secrets.data.yml
   ```

2. Edit `.secrets.data.yml` with production credentials:
   ```yaml
   # .secrets.data.yml - Production (AI cannot read)
   production_database:
     password: "production_password"
   production_ssh:
     key_path: "keys/prod_deploy"
   ```

3. **NEVER** commit `.secrets.yml` or `.secrets.data.yml` to version control!

See [DATA_SECURITY_BEST_PRACTICES.md](../docs/DATA_SECURITY_BEST_PRACTICES.md) for full documentation.

## Configuring Services

NWP supports configuring services at both global and recipe levels:

### Global Service Defaults

Set defaults in `cnwp.yml` that apply to all recipes:

```yaml
settings:
  services:
    redis:
      enabled: false      # Off by default
      version: "7"
    solr:
      enabled: false
      version: "8"
      core: drupal
    memcache:
      enabled: false
```

### Recipe Service Overrides

Override defaults for specific recipes:

```yaml
recipes:
  mysite:
    profile: social
    services:
      redis:
        enabled: true     # Override: enable Redis for this recipe
        version: "7"      # Can also override version
      solr:
        enabled: true
        core: social      # Use 'social' core instead of 'drupal'
      # memcache uses global default (disabled)
```

### Minimal Recipe Configuration

Only specify what differs from defaults:

```yaml
recipes:
  simple:
    profile: standard
    # Uses all settings.services defaults
    # No need to specify redis: false, solr: false, etc.
```

This keeps recipe definitions clean and maintainable.

## Environment Variables Reference

### Project Variables

- `PROJECT_NAME` - Project/site name
- `COMPOSE_PROJECT_NAME` - Docker Compose project name
- `NWP_RECIPE` - NWP recipe identifier (d, os, nwp, etc.)

### Drupal Variables

- `DRUPAL_PROFILE` - Installation profile (standard, minimal, social, etc.)
- `DRUPAL_WEBROOT` - Web root directory (web, html, docroot)
- `DRUPAL_CONFIG_PATH` - Configuration directory path
- `DRUPAL_TRUSTED_HOSTS` - Trusted host patterns
- `DRUPAL_THEME` - Default theme
- `DRUPAL_PRIVATE_FILES` - Private files directory

### Database Variables

- `DATABASE_HOST` - Database hostname (db, database, localhost)
- `DATABASE_NAME` - Database name
- `DATABASE_USER` - Database username
- `DATABASE_PASSWORD` - Database password
- `DATABASE_PORT` - Database port (default: 3306)

### Service Variables

- `REDIS_ENABLED` - Enable Redis (0 or 1)
- `REDIS_HOST` - Redis hostname
- `SOLR_ENABLED` - Enable Solr (0 or 1)
- `SOLR_HOST` - Solr hostname
- `SOLR_CORE` - Solr core name

### Environment Variables

- `ENV_TYPE` - Environment type (development, staging, production)
- `ENV_DEBUG` - Enable debug mode (0 or 1)
- `XDEBUG_ENABLE` - Enable XDebug (0 or 1)
- `TZ` - Timezone (default: UTC)

### Development Variables

- `DEV_MODULES` - Development Drupal modules (space-separated)
- `DEV_COMPOSER` - Development Composer packages (space-separated)
- `STAGE_FILE_PROXY_ORIGIN` - Origin URL for stage_file_proxy module

### Deployment Variables

- `DEPLOY_METHOD` - Deployment method (rsync, git, tar)
- `DEPLOY_TARGET` - Deployment target (SSH alias or path)
- `DEPLOY_BRANCH` - Git branch for deployment

## DDEV Integration

NWP can generate DDEV configuration from these environment files:

```bash
# Generate DDEV config for a site
cd mysite
../vortex/scripts/generate-ddev.sh
```

This creates:
- `.ddev/config.yaml` - Main DDEV configuration
- `.ddev/config.local.yaml.example` - Local overrides template

## Best Practices

### 1. Don't Edit Generated Files

Never edit `.env` directly - it's generated from `cnwp.yml`. Instead:
- Modify `cnwp.yml` for recipe defaults
- Use `.env.local` for local overrides

### 2. Keep Secrets Secret (Two-Tier)

Use the appropriate secrets file:

**`.secrets.yml`** (infrastructure - AI can help):
- API tokens (Linode, Cloudflare, GitLab)
- Development passwords
- Non-sensitive configuration

**`.secrets.data.yml`** (data - AI blocked):
- Production database passwords
- Production SSH keys
- Production SMTP credentials
- Encryption keys

### 3. Document Custom Variables

If you add custom environment variables:
- Document them in your project's README
- Add them to `.env.local.example`
- Consider contributing back to NWP templates

### 4. Environment-Specific Settings

Use `ENV_TYPE` to conditionally enable features:

```bash
# In scripts
if [ "$ENV_TYPE" = "production" ]; then
  REDIS_ENABLED=1
  ENV_DEBUG=0
fi
```

## Troubleshooting

### Variables Not Loading

1. Check file exists: `ls -la .env .env.local`
2. Check file permissions: `chmod 644 .env .env.local`
3. Verify variable names match template
4. Check for typos (variable names are case-sensitive)

### DDEV Not Using Variables

1. Restart DDEV: `ddev restart`
2. Check `.ddev/config.yaml` was generated
3. Verify `web_environment` section contains your variables

### Secrets Not Working

1. Verify `.secrets.yml` exists and is readable
2. Check YAML syntax: `yamllint .secrets.yml`
3. Ensure scripts are loading secrets properly

## Migration from Custom Setup

If you have an existing project with custom environment configuration:

1. Identify your current environment variables
2. Map them to NWP standard variables (see reference above)
3. Create `.env.local` with your custom values
4. Create `.secrets.yml` for credentials
5. Test with `ddev start` or `docker-compose up`

See `docs/MIGRATION_GUIDE.md` for detailed instructions.

## Contributing

To add a new recipe template:

1. Create `vortex/templates/.env.[recipe-name]`
2. Base it on `.env.base`
3. Set recipe-specific defaults
4. Document recipe-specific variables
5. Submit a pull request

## Resources

- [NWP Documentation](../docs/)
- [DDEV Documentation](https://ddev.readthedocs.io/)
- [DrevOps Vortex](https://docs.drevops.com/) (inspiration)
- [Twelve-Factor App](https://12factor.net/) (environment config principles)
