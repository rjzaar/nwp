# ADR-0008: Recipe System Architecture

**Status:** Accepted
**Date:** 2025-12-15 (original design), refined 2026-01-14
**Decision Makers:** Rob
**Related Issues:** P06 (Sites Tracking System), P30 (Modular Install Architecture)
**Related Commits:** 05d13750 (modular refactor), 7956b417 (avc split), e2558617 (post_install_scripts)
**References:** [example.nwp.yml](../../example.nwp.yml), [install-common.sh](../../lib/install-common.sh)

## Context

NWP needed a standardized way to define and install different types of sites (Drupal distributions, Moodle, GitLab, Podcast hosting) with:
1. **Reproducible installations** - Same config produces same result
2. **Environment-specific options** - Dev vs Staging vs Live vs Prod
3. **Per-recipe customization** - Each distribution has unique requirements
4. **Inheritance/defaults** - Global settings with recipe-specific overrides
5. **Interactive selection** - TUI for optional features
6. **Extensibility** - Easy to add new recipes without code changes

The key challenge: How to balance **simplicity** (YAML configuration) with **flexibility** (supporting Drupal, Moodle, GitLab, Podcast, etc.)?

## Options Considered

### Option 1: Recipe System in YAML (Chosen)
Define recipes as YAML configuration in `nwp.yml` with fields for all supported options.

**Pros:**
- Human-readable and editable
- No code changes to add new recipes
- Easy to version control
- Supports inheritance (global defaults → recipe defaults → site overrides)
- Can be extended with new fields without breaking existing recipes

**Cons:**
- Limited validation (no type checking until runtime)
- Complex recipes can get verbose
- YAML parsing complexity in bash

### Option 2: Code-Based Recipe Classes
Define recipes as bash functions or scripts in `recipes/` directory.

**Pros:**
- Full programmatic control
- Better validation via bash's type system
- Easier to debug with shellcheck

**Cons:**
- Requires code changes for new recipes
- Harder for non-developers to customize
- Not version-controlled with site config
- Testing requires running actual installs

### Option 3: Hybrid (Recipe Code + YAML Config)
Recipe scripts in `recipes/` directory, configured via YAML.

**Pros:**
- Programmatic flexibility for complex logic
- YAML for user-facing configuration

**Cons:**
- Two places to look for recipe definition
- More complexity
- Over-engineering for NWP's needs

### Option 4: Plugin System
Dynamic recipe loading from external packages.

**Pros:**
- Ultimate flexibility
- Community can contribute recipes

**Cons:**
- Massive over-engineering (rejected in Deep Analysis Re-Evaluation)
- Security risks (untrusted code execution)
- No external recipe developers yet

## Decision

Implement **YAML-based recipe system** with three-tier configuration hierarchy:

```yaml
# Tier 1: Global defaults (settings section)
settings:
  php: 8.2
  database: mariadb

# Tier 2: Recipe defaults (recipes section)
recipes:
  avc:
    source: nwp/avc-project
    profile: avc
    php: 8.3              # Override global default
    options:
      environment_indicator: y  # Pre-selected
      security_modules:         # Available but not selected

# Tier 3: Per-site overrides (sites section)
sites:
  mysite:
    recipe: avc
    php: 8.2              # Override recipe default
    purpose: production
```

**Resolution order:** Site overrides → Recipe defaults → Global defaults → Hardcoded fallbacks

## Rationale

### Why YAML Instead of Code?

**Configuration as Data:** Recipes describe *what* to install, not *how* to install it. The *how* is in `lib/install-*.sh` libraries.

**Example:** The `avc` recipe doesn't contain installation logic—it declares:
- Source: `nwp/avc-project`
- Profile: `avc`
- Webroot: `html`
- Available options: `security_modules`, `redis`, `solr`, etc.

The installation logic is in:
- `lib/install-common.sh` - Common installation workflow
- `lib/install-drupal.sh` - Drupal-specific installation
- `lib/install-moodle.sh` - Moodle-specific installation

### Why Three-Tier Hierarchy?

**Real-world scenario:**
1. **Global default:** All sites use PHP 8.2 by default
2. **Recipe default:** AVC requires PHP 8.3 for features
3. **Site override:** One AVC site needs PHP 8.2 for legacy module

Three tiers handle this elegantly without duplication.

### Why Options System?

**Problem:** Different environments need different features:
- **Dev:** `dev_modules`, `xdebug`, `stage_file_proxy`
- **Staging:** `db_sanitize`, `staging_domain`
- **Live:** `security_modules`, `redis`, `solr`
- **Prod:** `live_domain`, `dns_records`, `monitoring`

**Solution:** Checkbox-based TUI during install:
```bash
pl install avc mysite
# Shows interactive checkbox menu
# Pre-selected options marked with 'y' in recipe
# User can toggle options before installation
```

This replaced hardcoded logic like "if production, install security modules."

### Recipe Field Design

**Core fields (all recipes):**
- `source` or `source_git` - Where to get the code
- `type` - drupal (default), moodle, gitlab, podcast
- `webroot` - Document root path
- `auto` - Skip confirmation prompt

**Drupal-specific:**
- `profile` - Install profile name
- `install_modules` - Additional composer packages
- `post_install_modules` - Modules to enable after install
- `default_theme` - Theme to set as default

**Environment overrides:**
- `php` - Override global PHP version
- `database` - Override global database type

**Development mode:**
- `dev` - Enable dev module installation
- `dev_modules` - Modules to install when dev: y

**Deployment:**
- `reinstall_modules` - Modules to reinstall during `stg2prod`

**Non-Drupal:**
- `branch` - Git branch (Moodle, GitLab)
- `sitename` - Display name (Moodle, GitLab)
- `domain` - Podcast domain
- `linode_region`, `b2_region` - Infrastructure settings

## Consequences

### Positive
- **No code changes for new recipes** - Add to YAML, works immediately
- **Self-documenting** - Recipe definition includes all options
- **Version controlled** - Recipe changes tracked in git
- **Easy customization** - Site builders can modify without bash knowledge
- **Inheritance** - DRY principle via three-tier hierarchy
- **Interactive workflow** - TUI for option selection reduces command-line flags

### Negative
- **Limited validation** - No schema enforcement (mitigated by field reference comments)
- **YAML verbosity** - Complex recipes can be long (mitigated by comments)
- **Parsing complexity** - AWK/yq parsing can be tricky (mitigated by `lib/yaml-write.sh`)

### Neutral
- **Field discovery** - Developers must read comments to understand available fields
- **No IntelliSense** - Unlike code, YAML has no autocomplete (mitigated by comprehensive comments)

## Implementation Notes

### Recipe Field Reference

`example.nwp.yml` includes comprehensive field reference:
```yaml
# Recipe Field Reference:
#
# CORE FIELDS (all recipes):
#   source:          [REQUIRED*] Composer package
#   source_git:      [REQUIRED*] Git URL to clone
#   type:            [OPTIONAL] drupal (default), moodle, gitlab, podcast
#   webroot:         [OPTIONAL] Document root
#
# DRUPAL-SPECIFIC:
#   profile:         [REQUIRED] Install profile name
#   install_modules: [OPTIONAL] Additional composer packages
#   ... (30+ more fields documented)
```

This turns YAML comments into field documentation.

### Modular Install Architecture (P30)

Commit 05d13750 refactored `install.sh` from monolithic (3000+ lines) to modular:
```
lib/install-common.sh  - Common workflow (35+ functions)
lib/install-drupal.sh  - Drupal-specific (42+ functions)
lib/install-moodle.sh  - Moodle-specific (17+ functions)
lib/install-gitlab.sh  - GitLab-specific (7+ functions)
lib/install-podcast.sh - Castopod-specific (5+ functions)
```

**Result:** 82% code reduction in `install.sh`, now just 500 lines.

Recipe system enabled this refactor by separating *what* (YAML) from *how* (libraries).

### AVC Split Architecture

AVC uses dual-recipe pattern for different workflows:

**avc recipe (site builders):**
```yaml
avc:
  source: nwp/avc-project    # Project template
  profile: avc                # Profile via composer
```

**avc-dev recipe (profile developers):**
```yaml
avc-dev:
  source_git: https://git.nwpcode.org/nwp/avc-project.git
  profile_source: https://git.nwpcode.org/nwp/avc.git
  profile: avc
```

Difference:
- `avc`: Profile installed via composer (production workflow)
- `avc-dev`: Profile cloned via git (development workflow with editable profile)

This pattern solved "I want to work on the profile itself, not just use it."

### Post-Install Scripts

Commit e2558617 added `post_install_scripts` support:
```yaml
avc-dev:
  post_install_scripts:
    - scripts/avc-post-install.sh         # Shell script
    - scripts/migrate_help_to_book.php    # PHP script
```

Enables recipe-specific automation after installation (help pages, sample content, etc.).

### Recipe Types

**Drupal distributions:**
- `d` - Standard Drupal
- `os` - Open Social
- `avc` - AV Commons (production)
- `avc-dev` - AV Commons (development)

**Non-Drupal:**
- `moodle` - Moodle LMS
- `gitlab` - GitLab CE
- `podcast` - Castopod podcast hosting

All use the same YAML structure, differentiated by `type` field.

## Alternatives Considered

### Alternative 1: Recipe Inheritance via `extends`

Allow recipes to extend other recipes:
```yaml
recipes:
  avc-dev:
    extends: avc
    source_git: ...  # Override just this field
```

**Rejected because:**
- Adds complexity to resolution logic
- Harder to understand for site builders
- Current approach (copy full definition) is more explicit
- Can always refactor later if needed

### Alternative 2: Recipe Bundles

Group related recipes:
```yaml
recipe_bundles:
  avc_stack:
    - avc
    - moodle
    - gitlab
```

**Rejected because:**
- No use case for installing multiple recipes at once
- Sites are installed one at a time
- Would require complex multi-site orchestration

### Alternative 3: Recipe Validation Schema

Define JSON Schema for recipe validation:
```json
{
  "type": "object",
  "properties": {
    "source": {"type": "string"},
    "profile": {"type": "string"}
  }
}
```

**Rejected because:**
- Over-engineering for NWP's scale
- Runtime validation in bash is sufficient
- Schema maintenance overhead
- Reduces flexibility for experimental fields

## Migration Path

### Adding New Recipe

1. Copy existing recipe as template
2. Modify fields:
   - `source` or `source_git`
   - `profile` (if Drupal)
   - `options` (available features)
3. Test installation: `pl install <recipe-name> test-site`
4. Document in comments

No code changes required.

### Adding New Field

1. Document in field reference comments
2. Add parsing logic in `lib/install-common.sh` or recipe-specific library
3. Update `example.nwp.yml` with examples
4. Test with existing recipes to ensure backward compatibility

## Recipe Examples

### Minimal Recipe
```yaml
recipes:
  minimal:
    source: drupal/recommended-project:^10
    profile: minimal
    auto: y
```

### Complex Recipe with All Features
```yaml
recipes:
  enterprise:
    source: nwp/enterprise-project
    profile: enterprise
    webroot: html
    php: 8.3
    database: mariadb
    install_modules: drupal/redis drupal/solr
    post_install_modules:
      - redis
      - search_api_solr
    default_theme: enterprise_theme
    dev: n
    options:
      environment_indicator: y
      security_modules: y
      redis: y
      solr: y
      backup: y
      ssl: y
    moodle_integration:
      moodle_site: ""
      role_mapping:
        admin: manager
        member: student
```

## Review

**30-day review date:** 2026-02-14
**Review outcome:** Pending

**Success Metrics:**
- [x] All recipe types supported (Drupal, Moodle, GitLab, Podcast)
- [x] No code changes required for new recipes
- [x] Three-tier hierarchy working (global → recipe → site)
- [x] Interactive option selection via TUI
- [x] Post-install script support
- [ ] Community-contributed recipes (future)
- [x] 82% code reduction in install.sh via modular architecture

## Related Decisions

- **ADR-0002: YAML-Based Configuration** - Established YAML as config format
- **ADR-0010: TUI Framework Design** (pending) - Interactive option selection
- **ADR-0013: Four-State Deployment Model** (pending) - Environment-specific options

## Future Enhancements

Possible additions (not planned):
- Recipe marketplace (share community recipes)
- Recipe testing framework (automated validation)
- Recipe versioning (recipe schema changes)
- Recipe composition (combine multiple recipes)
- Recipe templates (generate recipe from existing site)
