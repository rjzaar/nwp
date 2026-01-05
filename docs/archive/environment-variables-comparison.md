# Environment Variables and Configuration Comparison

> **NOTE: Superseded by `docs/ARCHITECTURE_ANALYSIS.md`**
>
> This research has been consolidated into the main architecture analysis document.
> NWP uses cnwp.yml + .secrets.yml for configuration (see docs/DATA_SECURITY_BEST_PRACTICES.md).

This document compares environment variable structures and configurations from:
- Vortex (DrevOps framework)
- Open Social and Varbase Drupal profiles
- NWP cnwp.yml configuration
- DDEV configuration approach

## Executive Summary

The three main approaches examined are:
1. **Vortex**: Comprehensive `.env` file + `docker-compose.yml` for Docker-based development
2. **DDEV**: `config.yaml` with `web_environment` for containerized development
3. **NWP cnwp.yml**: Custom YAML configuration for project recipes and settings

## 1. Vortex Configuration Structure

### 1.1 Environment Variables (.env)

Vortex uses a comprehensive `.env` file organized into logical sections:

#### General Settings
```bash
VORTEX_PROJECT=your_site
WEBROOT=web
TZ=UTC
```

#### Drupal Configuration
```bash
DRUPAL_PROFILE=standard
DRUPAL_CONFIG_PATH=../config/default
DRUPAL_TRUSTED_HOSTS=your-site-domain.example
DRUPAL_THEME=your_site_theme
DRUPAL_MAINTENANCE_THEME=your_site_theme
DRUPAL_STAGE_FILE_PROXY_ORIGIN=https://www.your-site-domain.example
DRUPAL_SHIELD_PRINT="Restricted access."
DRUPAL_REDIS_ENABLED=1
DRUPAL_CLAMAV_ENABLED=1
DRUPAL_CLAMAV_MODE=daemon
```

#### Provisioning
```bash
VORTEX_PROVISION_TYPE=database
VORTEX_PROVISION_OVERRIDE_DB=0
VORTEX_PROVISION_SANITIZE_DB_SKIP=0
VORTEX_PROVISION_SANITIZE_DB_EMAIL=user_%uid@your-site-domain.example
VORTEX_PROVISION_USE_MAINTENANCE_MODE=1
```

#### Hosting (Conditional)
```bash
# Lagoon
LAGOON_PROJECT=your_site
VORTEX_LAGOON_PRODUCTION_BRANCH=main

# Acquia
VORTEX_ACQUIA_APP_NAME=
```

#### Database Source
```bash
VORTEX_DB_DIR=./.data
VORTEX_DB_FILE=db.sql
VORTEX_DB_DOWNLOAD_SOURCE=url
VORTEX_DB_DOWNLOAD_URL=
VORTEX_DB_DOWNLOAD_ENVIRONMENT=prod
VORTEX_DB_DOWNLOAD_ACQUIA_DB_NAME=your_site
```

#### Deployment
```bash
VORTEX_RELEASE_VERSION_SCHEME=calver
VORTEX_DEPLOY_TYPES=artifact
```

#### Notifications
```bash
VORTEX_NOTIFY_CHANNELS=email
VORTEX_NOTIFY_EMAIL_FROM=webmaster@your-site-domain.example
VORTEX_NOTIFY_EMAIL_RECIPIENTS="webmaster@your-site-domain.example|Webmaster"
VORTEX_NOTIFY_JIRA_USER_EMAIL=user@example.com
VORTEX_NOTIFY_WEBHOOK_URL=
```

### 1.2 Local Environment Overrides (.env.local.example)

Vortex provides `.env.local` for:
- Local development URL overrides
- Debug settings
- Database override preferences
- API tokens and secrets (not committed)
- Hosting-specific credentials

```bash
VORTEX_PROVISION_OVERRIDE_DB=1
PACKAGE_TOKEN=
VORTEX_DB_DOWNLOAD_FORCE=1
VORTEX_DB_DOWNLOAD_FTP_USER=
VORTEX_DB_DOWNLOAD_FTP_PASS=
VORTEX_ACQUIA_KEY=
VORTEX_ACQUIA_SECRET=
VORTEX_CONTAINER_REGISTRY_USER=$DOCKER_USER
VORTEX_CONTAINER_REGISTRY_PASS=$DOCKER_PASS
```

### 1.3 Docker Compose Structure

Vortex's `docker-compose.yml` defines:

#### Environment Variable Anchors
```yaml
x-environment: &default-environment
  TZ: ${TZ:-UTC}
  CI: ${CI:-}
  XDEBUG_ENABLE: ${XDEBUG_ENABLE:-}
  VORTEX_LOCALDEV_URL: &default-url ${COMPOSE_PROJECT_NAME:-example-site}.docker.amazee.io
  LAGOON_ROUTE: *default-url
  DATABASE_HOST: database
  DATABASE_NAME: drupal
  DATABASE_USERNAME: drupal
  DATABASE_PASSWORD: drupal
  DATABASE_PORT: 3306
  DRUPAL_TRUSTED_HOSTS: ${DRUPAL_TRUSTED_HOSTS:-}
  DRUPAL_THEME: ${DRUPAL_THEME:-olivero}
  DRUPAL_CONFIG_PATH: ${DRUPAL_CONFIG_PATH:-../config/default}
  DRUPAL_SHIELD_USER: ${DRUPAL_SHIELD_USER:-}
  DRUPAL_SHIELD_PASS: ${DRUPAL_SHIELD_PASS:-}
  DRUPAL_REDIS_ENABLED: ${DRUPAL_REDIS_ENABLED:-}
```

#### Services
- **cli**: Command execution container
- **nginx**: Web server
- **php**: PHP-FPM
- **database**: MariaDB/MySQL
- **redis**: Caching (conditional)
- **solr**: Search (conditional)
- **clamav**: Antivirus (conditional)
- **chrome**: Browser testing

**Key Features:**
- Conditional service inclusion using special comments (`#;< SERVICE_NAME`)
- Volume mounting for local development
- Lagoon-specific labels for hosting
- Service interdependencies

## 2. Open Social and Varbase

### 2.1 Configuration Approach

Both Open Social and Varbase are **Drupal installation profiles**, not complete project frameworks. They:
- Don't include environment configuration files
- Expect to be installed within a project structure (Composer-based)
- Rely on the parent project for environment configuration

### 2.2 Typical Usage

These profiles are typically used with:
- **Vortex/DrevOps**: As demonstrated in the Vortex recipes
- **DDEV**: Using ddev config.yaml
- **Lando**: Using .lando.yml
- **Custom Docker setups**: Using project-specific configurations

### 2.3 Profile-Specific Settings

Configuration is handled through:
- Drupal's configuration management system
- `settings.php` and `settings.local.php`
- Composer dependencies defined in `composer.json`

## 3. DDEV Configuration Structure

### 3.1 config.yaml

DDEV uses `.ddev/config.yaml` for configuration:

```yaml
name: project-name
type: drupal10
docroot: web
php_version: "8.2"
webserver_type: nginx-fpm
database:
  type: mariadb
  version: "10.11"

# Environment variables
web_environment:
  - DRUPAL_TRUSTED_HOSTS=^.+\.ddev\.site$
  - DRUPAL_CONFIG_PATH=../config/default
  - STAGE_FILE_PROXY_ORIGIN=https://www.example.com
```

### 3.2 Environment Variable Management

**Setting Variables:**
```bash
# Via CLI
ddev config --web-environment-add="MY_VAR=value"

# Via config.yaml
web_environment:
  - MY_ENV_VAR=someval
  - MY_OTHER_ENV_VAR=someotherval
```

**Local Overrides:**
- `.ddev/config.local.yaml` for environment-specific settings
- Not committed to version control
- Smart merging: same variable names override

**Best Practices:**
- Keep secrets in `config.local.yaml`
- Use `.env` files alongside DDEV
- Provide `.env.example` for expected keys

### 3.3 DDEV Features

- **Auto-detection**: Automatically detects Drupal, WordPress, etc.
- **Service management**: Add services via add-ons
- **URL routing**: Automatic `.ddev.site` domains
- **Database management**: Built-in backup/restore
- **Hooks**: Pre/post hooks for custom commands

## 4. NWP cnwp.yml Configuration

### 4.1 Structure

The NWP uses a custom YAML configuration with three main sections:

```yaml
settings:
  database: mariadb
  php: 8.2
  webserver: nginx
  os: ubuntu
  cli: y
  cliprompt: pl
  linodeuse: all
  urluse: all
  url: nwpcode.org

setup:
  creategitlab: y

recipes:
  [recipe-name]:
    source: [composer-package]
    install_modules: [modules]
    profile: [drupal-profile]
    webroot: [directory]
    auto: y
    # Advanced options
    private: ../private
    cmi: ../cmi
    dev_modules: [modules]
    dev_composer: [packages]
    prod_method: rsync

sites:
  # Dynamic site configurations
```

### 4.2 Configuration Scope

**Global Settings:**
- Technology stack (database, PHP, webserver, OS)
- CLI configuration
- Linode and URL usage flags
- Base domain

**Recipe-Level Configuration:**
- Project source (Composer package or Git repository)
- Drupal profile selection
- Additional modules to install
- Webroot directory
- Development vs. production settings
- Deployment methods

### 4.3 Comparison to Traditional Approaches

Unlike Vortex and DDEV, the NWP configuration:
- Focuses on **recipe-based project initialization**
- Combines project creation + environment setup
- Not directly compatible with standard Drupal tooling
- Custom implementation via bash scripts

## 5. Comparative Analysis

### 5.1 Configuration Scope

| Aspect | Vortex | DDEV | NWP cnwp.yml |
|--------|--------|------|--------------|
| **Scope** | Project environment + deployment | Local development environment | Project recipes + setup |
| **Format** | `.env` + `docker-compose.yml` | `config.yaml` | `cnwp.yml` |
| **Secrets** | `.env.local` (gitignored) | `config.local.yaml` | Not specified |
| **Service Definition** | docker-compose services | Built-in + add-ons | Defined in settings |
| **Hosting Support** | Lagoon, Acquia | DDEV Cloud | Linode (custom) |

### 5.2 Environment Variables Coverage

| Category | Vortex | DDEV | NWP |
|----------|--------|------|-----|
| **Drupal Core** | ✅ Comprehensive | ✅ Basic | ⚠️ Indirect (via recipes) |
| **Database** | ✅ Full control | ✅ Managed | ✅ Type only |
| **Services (Redis, Solr)** | ✅ Conditional | ✅ Add-ons | ❌ Not specified |
| **Deployment** | ✅ Multi-target | ❌ Development only | ⚠️ Via recipes |
| **Notifications** | ✅ Multiple channels | ❌ None | ❌ None |
| **CI/CD** | ✅ Built-in | ⚠️ External | ❌ None |

### 5.3 Variable Organization

**Vortex Approach:**
- Hierarchical organization by functionality
- Clear separation of concerns
- Extensive documentation inline
- Conditional sections for optional features

**DDEV Approach:**
- Service-focused configuration
- Minimal required variables
- Environment variables as list items
- Override pattern for customization

**NWP Approach:**
- Recipe-centric organization
- Global settings + per-recipe configuration
- No explicit environment variable mapping
- Custom interpretation by scripts

### 5.4 Use Case Suitability

**Vortex:**
- ✅ Complex projects with multiple environments
- ✅ Teams using Lagoon or Acquia
- ✅ CI/CD pipeline requirements
- ✅ Multiple deployment targets
- ❌ Simple local development
- ❌ Beginners

**DDEV:**
- ✅ Local development focus
- ✅ Quick project setup
- ✅ Cross-platform compatibility
- ✅ Beginners to advanced users
- ⚠️ Production deployment (requires additional tooling)
- ❌ Complex multi-environment workflows

**NWP cnwp.yml:**
- ✅ Standardized project initialization
- ✅ Multiple project types (Drupal, Moodle, GitLab)
- ✅ Recipe-based workflow
- ❌ Standard Drupal tooling integration
- ❌ Established hosting providers
- ❌ Community support/documentation

## 6. Recommendations for NWP Implementation

### 6.1 Adopt a Hybrid Approach

Combine the best aspects of each system:

```yaml
# cnwp.yml - Enhanced structure
settings:
  # Stack configuration (keep current)
  database: mariadb
  php: 8.2
  webserver: nginx
  os: ubuntu

  # Development environment choice
  dev_environment: ddev  # or: vortex, docker-compose, lando

  # Environment-specific settings
  environment:
    development:
      debug: true
      xdebug: true
      database_import: always
    staging:
      debug: false
      database_sanitize: true
    production:
      debug: false
      database_sanitize: false

recipes:
  [name]:
    # Current fields (keep)
    source: [package]
    profile: [profile]
    webroot: [directory]

    # Enhanced environment variables
    env:
      DRUPAL_CONFIG_PATH: ../config/default
      DRUPAL_TRUSTED_HOSTS: ^.+\.ddev\.site$
      DRUPAL_REDIS_ENABLED: 1

    # Service requirements
    services:
      - redis
      - solr
      - clamav

    # Development vs. production separation
    dev:
      modules: [devel, kint, webprofiler]
      composer: [drupal/devel]
    prod:
      method: rsync
      target: user@host:/path
```

### 6.2 Environment Variable Management

**Option 1: Generate DDEV Configuration**
- NWP reads `cnwp.yml` and generates `.ddev/config.yaml`
- Leverage DDEV's mature tooling
- Better community support
- Easier onboarding for developers familiar with DDEV

**Implementation:**
```bash
# install.sh generates:
.ddev/config.yaml
.ddev/config.local.yaml.example
```

**Option 2: Generate Vortex Configuration**
- NWP reads `cnwp.yml` and generates `.env` + `docker-compose.yml`
- Suitable for CI/CD-heavy workflows
- Better for Lagoon/Acquia deployments
- More complex maintenance

**Option 3: Hybrid - DDEV for Local, Scripts for Deployment**
- Use DDEV for local development
- NWP scripts handle deployment to production
- Best of both worlds
- Recommended approach ✅

### 6.3 Proposed Environment Variable Structure

Create a standardized `.env.example` for each recipe:

```bash
# .env.example (generated from cnwp.yml)

# Project
PROJECT_NAME=sitename
COMPOSE_PROJECT_NAME=sitename

# Drupal
DRUPAL_PROFILE=social
DRUPAL_WEBROOT=html
DRUPAL_CONFIG_PATH=../config/default
DRUPAL_TRUSTED_HOSTS=

# Database
DATABASE_HOST=db
DATABASE_NAME=db
DATABASE_USER=db
DATABASE_PASSWORD=db
DATABASE_PORT=3306

# Services
REDIS_ENABLED=1
SOLR_ENABLED=0

# Development
DEV_MODE=1
XDEBUG_ENABLE=0

# Deployment
DEPLOY_METHOD=rsync
DEPLOY_TARGET=

# Secrets (not committed)
# Copy from .env.local
ADMIN_PASSWORD=
API_KEYS=
```

### 6.4 Configuration File Priority

Establish a clear hierarchy:

1. **cnwp.yml** - Project-wide defaults
2. **cnwp.local.yml** - Local overrides (gitignored)
3. **.env** - Runtime environment (generated from cnwp.yml)
4. **.env.local** - Local secrets (gitignored)
5. **.ddev/config.yaml** - DDEV config (if using DDEV)
6. **.ddev/config.local.yaml** - DDEV local overrides

### 6.5 Standardize Variable Naming

Adopt a consistent naming convention:

```bash
# Project-level (NWP_)
NWP_RECIPE=d
NWP_SITE_NAME=mysite
NWP_CLI_PROMPT=pl

# Drupal-level (DRUPAL_)
DRUPAL_PROFILE=standard
DRUPAL_CONFIG_PATH=../config/default
DRUPAL_TRUSTED_HOSTS=

# Service-level ([SERVICE]_)
REDIS_ENABLED=1
SOLR_CORE=drupal
DATABASE_HOST=db

# Deployment-level (DEPLOY_)
DEPLOY_METHOD=rsync
DEPLOY_TARGET=user@host:/path
DEPLOY_BRANCH=main

# Environment-level (ENV_)
ENV_TYPE=development  # development, staging, production
ENV_DEBUG=1
```

### 6.6 Migration Path

For existing NWP users:

**Phase 1: Backward Compatibility**
- Keep `cnwp.yml` as primary configuration
- Auto-generate DDEV/Vortex configs from cnwp.yml
- Support existing workflows

**Phase 2: Enhanced Configuration**
- Add `environment` section to cnwp.yml
- Introduce `.env` support
- Provide migration guide

**Phase 3: Full Integration**
- DDEV as recommended local development
- NWP scripts for deployment
- Comprehensive documentation

### 6.7 Documentation Requirements

Create documentation for:

1. **Environment Variable Reference**
   - Complete list of supported variables
   - Default values
   - Where they're used

2. **Configuration Examples**
   - Common scenarios (Open Social, Drupal Standard, Moodle)
   - Development vs. production setups
   - Multi-site configurations

3. **Migration Guides**
   - From custom Docker to NWP+DDEV
   - From Vortex to NWP
   - From vanilla Drupal to NWP

4. **Troubleshooting**
   - Common configuration issues
   - Debugging environment variables
   - Service connectivity problems

## 7. Specific Implementation Recommendations

### 7.1 DDEV Integration (Recommended)

**Benefits:**
- Mature, well-tested tooling
- Automatic SSL certificates
- Built-in database management
- Service add-ons (Redis, Solr, Elasticsearch)
- Cross-platform support
- Active community

**Implementation:**

```bash
# install.sh - DDEV initialization
generate_ddev_config() {
  local recipe=$1
  local sitename=$2

  # Read from cnwp.yml
  local profile=$(yq eval ".recipes.$recipe.profile" cnwp.yml)
  local webroot=$(yq eval ".recipes.$recipe.webroot" cnwp.yml)
  local php=$(yq eval ".settings.php" cnwp.yml)
  local database=$(yq eval ".settings.database" cnwp.yml)

  # Generate .ddev/config.yaml
  cat > .ddev/config.yaml <<EOF
name: $sitename
type: drupal10
docroot: $webroot
php_version: "$php"
webserver_type: nginx-fpm
database:
  type: $database
  version: "10.11"

web_environment:
  - DRUPAL_PROFILE=$profile
  - DRUPAL_CONFIG_PATH=../config/default

hooks:
  post-start:
    - exec: composer install
    - exec: drush deploy
EOF

  # Generate config.local.yaml.example
  cat > .ddev/config.local.yaml.example <<EOF
# Local overrides - copy to config.local.yaml
web_environment:
  - ADMIN_EMAIL=admin@localhost
  - XDEBUG_MODE=debug
EOF
}
```

### 7.2 Environment-Specific Configurations

Support different environments through cnwp.yml:

```yaml
# cnwp.yml
environments:
  development:
    debug: true
    database_sanitize: false
    dev_modules: devel kint webprofiler stage_file_proxy
    xdebug: true

  staging:
    debug: false
    database_sanitize: true
    dev_modules: stage_file_proxy
    xdebug: false
    trusted_hosts: staging.example.com

  production:
    debug: false
    database_sanitize: false
    xdebug: false
    trusted_hosts: www.example.com,example.com
    redis: true
    caching: aggressive
```

### 7.3 Service Management

Define services in recipes:

```yaml
recipes:
  nwp:
    source: goalgorilla/social_template:dev-master
    profile: social
    webroot: html

    # Service requirements
    services:
      database:
        type: mariadb
        version: "10.11"
      redis:
        enabled: true
      solr:
        enabled: true
        core: social
      mail:
        type: mailhog  # or smtp for production
```

**Generate DDEV add-ons:**
```bash
# If services.redis.enabled = true
ddev get ddev/ddev-redis

# If services.solr.enabled = true
ddev get ddev/ddev-solr
```

### 7.4 Secrets Management

**Never commit secrets to cnwp.yml**

Create a secrets management approach:

```yaml
# cnwp.yml (committed)
settings:
  secrets_file: .secrets.yml  # gitignored

# .secrets.yml (NOT committed)
api_keys:
  acquia_key: xxx
  acquia_secret: xxx
  github_token: xxx

database:
  admin_password: xxx

smtp:
  username: xxx
  password: xxx
```

**Load secrets in scripts:**
```bash
# install.sh
if [ -f .secrets.yml ]; then
  export ACQUIA_KEY=$(yq eval '.api_keys.acquia_key' .secrets.yml)
  export ACQUIA_SECRET=$(yq eval '.api_keys.acquia_secret' .secrets.yml)
fi
```

### 7.5 Multi-Site Support

Extend cnwp.yml to support multi-site:

```yaml
sites:
  main:
    recipe: nwp
    domain: main.example.com
    database: main_db

  blog:
    recipe: d
    domain: blog.example.com
    database: blog_db
    profile: minimal

  shop:
    recipe: commerce
    domain: shop.example.com
    database: shop_db
```

**DDEV supports multi-site:**
```yaml
# .ddev/config.yaml
additional_hostnames:
  - blog.example
  - shop.example
```

## 8. Comparison Matrix

### 8.1 Feature Comparison

| Feature | Vortex | DDEV | NWP (Current) | NWP (Proposed) |
|---------|--------|------|---------------|----------------|
| **Local Dev Environment** | ✅ Docker Compose | ✅ Docker (managed) | ⚠️ Manual | ✅ DDEV-integrated |
| **Environment Variables** | ✅ .env | ✅ config.yaml | ❌ None | ✅ .env + cnwp.yml |
| **Service Management** | ✅ Conditional | ✅ Add-ons | ❌ Manual | ✅ Recipe-defined |
| **Database Import** | ✅ Multiple sources | ✅ Built-in | ⚠️ Basic | ✅ Enhanced |
| **Secrets Management** | ✅ .env.local | ✅ config.local.yaml | ❌ None | ✅ .secrets.yml |
| **Multi-Environment** | ✅ Full support | ⚠️ Dev only | ❌ None | ✅ Planned |
| **CI/CD Integration** | ✅ Built-in | ⚠️ External | ❌ None | ⚠️ Custom scripts |
| **Production Deployment** | ✅ Multiple methods | ❌ Not supported | ⚠️ Basic rsync | ✅ Enhanced |
| **Multi-Site** | ✅ Supported | ✅ Supported | ❌ None | ✅ Planned |
| **Recipe System** | ❌ None | ❌ None | ✅ Core feature | ✅ Enhanced |
| **Hosting Provider Integration** | ✅ Lagoon, Acquia | ✅ DDEV Cloud | ⚠️ Linode (custom) | ✅ Multiple |

### 8.2 Learning Curve

| Aspect | Vortex | DDEV | NWP (Current) | NWP (Proposed) |
|--------|--------|------|---------------|----------------|
| **Initial Setup** | Medium | Easy | Easy | Easy |
| **Configuration** | Complex | Simple | Simple | Medium |
| **Maintenance** | Medium | Low | Low | Low |
| **Documentation** | Excellent | Excellent | Limited | Planned |
| **Community Support** | Good | Excellent | None | Growing |

### 8.3 Best Fit Scenarios

**Use Vortex when:**
- Working with Lagoon or Acquia hosting
- Need comprehensive CI/CD pipelines
- Managing multiple environments (dev, staging, prod)
- Team has DevOps expertise

**Use DDEV when:**
- Focus on local development
- Need quick project setup
- Cross-platform team (Mac, Windows, Linux)
- Prefer managed Docker environment
- Want strong community support

**Use NWP when:**
- Need recipe-based project initialization
- Managing multiple project types (Drupal, Moodle, GitLab)
- Want standardized project structure
- Custom deployment requirements

**Use NWP + DDEV (Recommended) when:**
- Want recipe system + mature local development
- Need flexibility for deployment
- Balance between simplicity and power
- Growing team with varying skill levels

## 9. Action Items

### 9.1 Immediate (High Priority) ✅ COMPLETED

1. ✅ **Create environment variable mapping** from cnwp.yml to DDEV config
2. ✅ **Add .env support** to NWP scripts for runtime configuration
3. ✅ **Document environment variables** in README
4. ✅ **Create .env.example** templates for each recipe
5. ✅ **Add .gitignore entries** for secrets (.env.local, .secrets.yml, config.local.yaml)

### 9.2 Short-term (Medium Priority) ✅ COMPLETED

6. ✅ **Implement DDEV config generation** in install.sh
7. ✅ **Add environment selection** (development, staging, production) - Added to settings
8. ✅ **Create service management** system in cnwp.yml - Implemented with defaults + overrides
9. ✅ **Build secrets management** framework - .secrets.yml template created
10. ✅ **Write migration guide** for existing users

### 9.3 Additional Enhancements (IMPLEMENTED)

11. ✅ **Configuration hierarchy** - Recipe → Settings → Profile → Defaults
12. ✅ **Global defaults in settings** - Define once, use everywhere
13. ✅ **Recipe overrides** - Override only what differs from defaults
14. ✅ **No external dependencies** - Uses awk instead of yq for YAML parsing
15. ✅ **Comprehensive documentation** - README, vortex/README, migration guide

### 9.3 Long-term (Future Enhancement)

11. **Multi-site support** in cnwp.yml
12. **Hosting provider integrations** (Pantheon, Platform.sh, etc.)
13. **CI/CD templates** (GitHub Actions, GitLab CI)
14. **GUI configuration tool** for cnwp.yml
15. **Plugin/extension system** for custom recipes

## 10. Conclusion

The comparison reveals three distinct approaches to environment configuration:

1. **Vortex**: Comprehensive, deployment-focused, complex
2. **DDEV**: Developer-friendly, local-focused, simple
3. **NWP**: Recipe-focused, flexible, evolving

**Implemented Solution (v0.2):**

NWP now implements the recommended hybrid approach:

- ✅ **Integrated DDEV** as the local development environment manager
- ✅ **Enhanced cnwp.yml** with hierarchical configuration (recipe → settings → defaults)
- ✅ **Added environment variable support** via .env files with templates
- ✅ **Maintained recipe system** as NWP's core differentiator
- ✅ **Built on DDEV foundation** with auto-generation of DDEV configs
- ✅ **No external dependencies** - Uses standard Unix tools (awk, sed, grep)

**Key Achievements:**

1. **Configuration Hierarchy**: Recipe-specific → Global settings → Profile defaults → Hardcoded
2. **Vortex System**: Template-based .env generation with service management
3. **DDEV Integration**: Automatic config.yaml generation from .env
4. **Secrets Management**: Secure .secrets.yml support (gitignored)
5. **Backward Compatible**: Existing installations continue to work
6. **Well Documented**: Complete guides and examples

This hybrid approach leverages:
- ✅ DDEV's maturity for local development
- ✅ NWP's recipe system for project initialization
- ✅ Standard .env files for cross-compatibility
- ✅ Hierarchical configuration for flexibility
- ⏳ Flexible deployment options for various hosting scenarios (planned)

The result is a system that is:
- ✅ **Easy for beginners** (DDEV + recipes with sensible defaults)
- ✅ **Powerful for experts** (full override capabilities)
- ✅ **Compatible with existing tools** (.env, DDEV)
- ✅ **Maintainable long-term** (community-supported DDEV base)
- ✅ **DRY principle** (define once in settings, override as needed)

## References

- [DDEV Documentation - Config Options](https://docs.ddev.com/en/stable/users/configuration/config/)
- [DDEV Documentation - Customization](https://docs.ddev.com/en/stable/users/extend/customization-extendibility/)
- [Vortex Documentation](https://www.vortextemplate.com/docs/)
- [Open Social](https://www.getopensocial.com/)
- [Varbase](https://www.vardot.com/varbase)
