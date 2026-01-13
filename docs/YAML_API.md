# NWP YAML API Reference

**Last Updated:** 2026-01-13
**Library:** `lib/yaml-write.sh`

## Overview

The NWP YAML API provides a consolidated interface for reading and writing YAML configuration files. All functions use a **yq-first, AWK-fallback** pattern for maximum robustness and portability.

### Key Features

- **Unified API** - Single source of truth for all YAML operations
- **yq-first** - Uses yq when available for robust parsing (anchors, complex nesting)
- **AWK fallback** - Pure AWK implementation when yq is not installed
- **Security validation** - Built-in site name validation and path traversal prevention
- **Transaction safety** - Automatic backup and rollback on write failures
- **Consistent error handling** - All functions return proper exit codes

### Configuration Files

| File | Purpose | Functions |
|------|---------|-----------|
| `cnwp.yml` | Site registry and settings | Most read/write functions |
| `.secrets.yml` | Infrastructure secrets (API tokens) | `yaml_get_secret()` |
| `.secrets.data.yml` | Production data secrets | `get_data_secret()` (in common.sh) |
| `example.cnwp.yml` | Template for new installations | Read functions for defaults |

---

## Reading Functions

### Site Functions

#### `yaml_get_all_sites()`

List all site names from the sites section.

**Usage:**
```bash
sites=$(yaml_get_all_sites)
sites=$(yaml_get_all_sites "/path/to/config.yml")
```

**Arguments:**
- `$1` - Config file path (optional, defaults to `cnwp.yml`)

**Returns:**
- Site names, one per line
- Exit code 0 on success, 1 on failure

**Example:**
```bash
for site in $(yaml_get_all_sites); do
    echo "Found site: $site"
done
```

---

#### `yaml_get_site_field()`

Get a field value from a site entry.

**Usage:**
```bash
directory=$(yaml_get_site_field "mysite" "directory")
recipe=$(yaml_get_site_field "mysite" "recipe" "cnwp.yml")
```

**Arguments:**
- `$1` - Site name (required)
- `$2` - Field name (required)
- `$3` - Config file path (optional)

**Returns:**
- Field value
- Exit code 0 on success, 1 on failure

**Example:**
```bash
if yaml_get_site_field "avc" "purpose" | grep -q "production"; then
    echo "This is a production site"
fi
```

---

#### `yaml_get_site_list()`

Get list field values from a site entry (e.g., installed_modules).

**Usage:**
```bash
modules=$(yaml_get_site_list "mysite" "installed_modules")
```

**Arguments:**
- `$1` - Site name (required)
- `$2` - List field name (required)
- `$3` - Config file path (optional)

**Returns:**
- List values, one per line
- Exit code 0 on success, 1 on failure

**Example:**
```bash
for module in $(yaml_get_site_list "avc" "post_install_modules"); do
    echo "Will install: $module"
done
```

---

#### `yaml_site_exists()`

Check if a site exists in the configuration.

**Usage:**
```bash
if yaml_site_exists "mysite"; then
    echo "Site exists"
fi
```

**Arguments:**
- `$1` - Site name (required)
- `$2` - Config file path (optional)

**Returns:**
- Exit code 0 if exists, 1 if not

---

#### `yaml_get_site_purpose()`

Get site purpose with default fallback.

**Usage:**
```bash
purpose=$(yaml_get_site_purpose "mysite")
```

**Arguments:**
- `$1` - Site name (required)
- `$2` - Config file path (optional)

**Returns:**
- Purpose value (testing/indefinite/permanent/migration)
- Defaults to "indefinite" if not set

---

### Settings Functions

#### `yaml_get_setting()`

Get a value from the settings section using dot notation.

**Usage:**
```bash
# Simple key
url=$(yaml_get_setting "url")

# Nested key (2 levels)
domain=$(yaml_get_setting "email.domain")

# Nested key (3 levels)
enabled=$(yaml_get_setting "gitlab.hardening.enabled")
```

**Arguments:**
- `$1` - Key path with dot notation (required)
- `$2` - Config file (optional, defaults to `cnwp.yml`)

**Returns:**
- Setting value
- Exit code 0 on success, 1 on failure

**Supported nesting:** Unlimited depth

**Example:**
```bash
# Get PHP memory limit from nested settings
memory=$(yaml_get_setting "php_settings.memory_limit")

# Use default if not set
memory=${memory:-512M}
```

---

### Array Functions

#### `yaml_get_array()`

Get array values from any path in the configuration.

**Usage:**
```bash
# Top-level array
nameservers=$(yaml_get_array "other_coders.nameservers")

# Nested array
modules=$(yaml_get_array "sites.mysite.modules.enabled")
```

**Arguments:**
- `$1` - Path with dot notation (required)
- `$2` - Config file (optional)

**Returns:**
- Array items, one per line
- Exit code 0 on success, 1 on failure

**Example:**
```bash
# Iterate over nameservers
while IFS= read -r ns; do
    echo "Nameserver: $ns"
done < <(yaml_get_array "other_coders.nameservers")
```

---

### Coder Functions

#### `yaml_get_coder_list()`

List all coder names from other_coders section.

**Usage:**
```bash
coders=$(yaml_get_coder_list)
```

**Arguments:**
- `$1` - Config file (optional)

**Returns:**
- Coder names, one per line

**Example:**
```bash
for coder in $(yaml_get_coder_list); do
    email=$(yaml_get_coder_field "$coder" "email")
    echo "Coder: $coder ($email)"
done
```

---

#### `yaml_get_coder_field()`

Get a field value from a coder entry.

**Usage:**
```bash
email=$(yaml_get_coder_field "coder2" "email")
status=$(yaml_get_coder_field "coder2" "status")
notes=$(yaml_get_coder_field "coder2" "notes")
```

**Arguments:**
- `$1` - Coder name (required)
- `$2` - Field name (required)
- `$3` - Config file (optional)

**Returns:**
- Field value
- Exit code 0 on success, 1 on failure

---

### Recipe Functions

#### `yaml_get_recipe_field()`

Get a field value from a recipe entry.

**Usage:**
```bash
source=$(yaml_get_recipe_field "oc" "source")
webroot=$(yaml_get_recipe_field "oc" "webroot")
recipe_type=$(yaml_get_recipe_field "oc" "recipe")
```

**Arguments:**
- `$1` - Recipe name (required)
- `$2` - Field name (required)
- `$3` - Config file (optional)

**Returns:**
- Field value
- Exit code 0 on success, 1 on failure

---

#### `yaml_get_recipe_list()`

Get a list field value from a recipe (returns space-separated items).

**Usage:**
```bash
modules=$(yaml_get_recipe_list "oc" "post_install_modules")
```

**Arguments:**
- `$1` - Recipe name (required)
- `$2` - Field name (required)
- `$3` - Config file (optional)

**Returns:**
- Space-separated list items
- Exit code 0 on success, 1 on failure

**Example:**
```bash
# Convert to array
modules=$(yaml_get_recipe_list "avc" "post_install_modules")
for module in $modules; do
    drush en "$module" -y
done
```

---

### Secret Functions

#### `yaml_get_secret()`

Read a secret value from `.secrets.yml` using dot notation.

**Usage:**
```bash
# Infrastructure secrets (safe for automation)
token=$(yaml_get_secret "linode.api_token")
zone=$(yaml_get_secret "cloudflare.zone_id")

# Nested secrets
key=$(yaml_get_secret "b2.backup.key_id")
```

**Arguments:**
- `$1` - Key path with dot notation (required)
- `$2` - Secrets file (optional, defaults to `.secrets.yml`)

**Returns:**
- Secret value
- Exit code 0 on success, 1 on failure

**Security Note:** This function reads from `.secrets.yml` which contains infrastructure automation secrets. For production data secrets (DB passwords, SSH keys), use `get_data_secret()` from `lib/common.sh` which reads from `.secrets.data.yml`.

---

## Writing Functions

### Site Management

#### `yaml_add_site()`

Add a new site to the configuration.

**Usage:**
```bash
yaml_add_site "mysite" "oc" "sites/mysite" "testing" "cnwp.yml"
```

**Arguments:**
- `$1` - Site name (required, validated)
- `$2` - Recipe name (required)
- `$3` - Directory path (required)
- `$4` - Purpose (testing/indefinite/permanent/migration, optional)
- `$5` - Config file (optional)

**Returns:**
- Exit code 0 on success, 1 on failure

**Validation:**
- Site name must be alphanumeric with hyphens/underscores
- Site name cannot contain path components (../)
- Automatic backup before modification
- Automatic rollback on validation failure

---

#### `yaml_add_site_stub()`

Add a minimal site stub (used during initial setup).

**Usage:**
```bash
yaml_add_site_stub "mysite" "oc" "sites/mysite"
```

**Arguments:**
- `$1` - Site name (required)
- `$2` - Recipe name (required)
- `$3` - Directory path (required)
- `$4` - Config file (optional)

---

#### `yaml_complete_site_stub()`

Complete a site stub with full installation details.

**Usage:**
```bash
yaml_complete_site_stub "mysite" "9.5.0" "modules_to_install" "modules_already_there"
```

**Arguments:**
- `$1` - Site name (required)
- `$2` - Drupal version (required)
- `$3` - Space-separated list of modules to install
- `$4` - Space-separated list of already installed modules
- `$5` - Config file (optional)

---

#### `yaml_remove_site()`

Remove a site from the configuration.

**Usage:**
```bash
yaml_remove_site "mysite"
```

**Arguments:**
- `$1` - Site name (required)
- `$2` - Config file (optional)

**Returns:**
- Exit code 0 on success, 1 on failure

**Safety:** Automatic backup before deletion.

---

#### `yaml_update_site_field()`

Update a field value for a site.

**Usage:**
```bash
yaml_update_site_field "mysite" "purpose" "production"
yaml_update_site_field "mysite" "drupal_version" "10.2.0"
```

**Arguments:**
- `$1` - Site name (required)
- `$2` - Field name (required)
- `$3` - New value (required)
- `$4` - Config file (optional)

---

#### `yaml_add_site_modules()`

Add modules to a site's installed_modules list.

**Usage:**
```bash
yaml_add_site_modules "mysite" "views pathauto token"
```

**Arguments:**
- `$1` - Site name (required)
- `$2` - Space-separated module names (required)
- `$3` - Config file (optional)

---

#### `yaml_add_site_production()`

Add production configuration to a site.

**Usage:**
```bash
yaml_add_site_production "mysite" "alias" "uri" "ip_address"
```

**Arguments:**
- `$1` - Site name (required)
- `$2` - Alias (subdomain)
- `$3` - URI (full domain)
- `$4` - IP address
- `$5` - Config file (optional)

---

#### `yaml_add_site_live()`

Add live server configuration to a site.

**Usage:**
```bash
yaml_add_site_live "mysite" "alias" "uri" "ip_address" "linode_id"
```

**Arguments:**
- `$1` - Site name (required)
- `$2` - Alias (subdomain)
- `$3` - URI (full domain)
- `$4` - IP address
- `$5` - Linode instance ID
- `$6` - Config file (optional)

---

### Utility Functions

#### `yaml_validate()`

Validate YAML file structure.

**Usage:**
```bash
if yaml_validate "cnwp.yml"; then
    echo "Valid YAML"
fi
```

**Arguments:**
- `$1` - Config file path (optional)

**Returns:**
- Exit code 0 if valid, 1 if invalid

**Implementation:**
- Uses yq if available (most robust)
- Falls back to basic AWK validation
- Checks indentation, syntax, structure

---

#### `yaml_validate_sitename()`

Validate a site name for safe use.

**Usage:**
```bash
if yaml_validate_sitename "my-site"; then
    echo "Valid site name"
fi
```

**Arguments:**
- `$1` - Site name (required)

**Returns:**
- Exit code 0 if valid, 1 if invalid

**Rules:**
- Must start with a letter
- Can contain letters, numbers, hyphens, underscores
- Cannot contain path components (../)
- Cannot contain YAML special characters (:, #, [, ])
- Maximum 64 characters

---

#### `yaml_backup()`

Create a backup of a YAML file before modification.

**Usage:**
```bash
yaml_backup "cnwp.yml"
```

**Arguments:**
- `$1` - Config file path (required)

**Returns:**
- Backup file path on stdout
- Exit code 0 on success, 1 on failure

**Backup location:** Same directory with `.backup` extension

---

#### `yaml_validate_or_restore()`

Validate YAML file and restore from backup if invalid.

**Usage:**
```bash
if ! yaml_validate_or_restore "cnwp.yml" "/path/to/backup"; then
    echo "Validation failed, restored from backup"
fi
```

**Arguments:**
- `$1` - Config file path (required)
- `$2` - Backup file path (required)

**Returns:**
- Exit code 0 if valid, 1 if invalid (and restored)

---

## Migration Guide

### Migrating from Inline AWK

**Before:**
```bash
url=$(awk '
    /^settings:/ { in_settings = 1; next }
    in_settings && /^  url:/ {
        sub(/^  url: */, "")
        print
        exit
    }
' cnwp.yml)
```

**After:**
```bash
source "$PROJECT_ROOT/lib/yaml-write.sh"
url=$(yaml_get_setting "url")
```

---

### Migrating from parse_yaml_value()

**Before:**
```bash
token=$(parse_yaml_value ".secrets.yml" "linode" "api_token")
```

**After:**
```bash
source "$PROJECT_ROOT/lib/yaml-write.sh"
token=$(yaml_get_secret "linode.api_token" ".secrets.yml")
```

---

### Migrating from get_recipe_value()

**Before:**
```bash
source=$(get_recipe_value "oc" "source")
```

**After:**
```bash
source=$(yaml_get_recipe_field "oc" "source")
```

---

## Best Practices

### 1. Always Source the Library

```bash
# At the top of your script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/yaml-write.sh"
```

### 2. Check Return Codes

```bash
if ! yaml_get_setting "url" >/dev/null; then
    echo "ERROR: URL not found in config" >&2
    exit 1
fi
```

### 3. Use Default Values

```bash
# In lib/common.sh style
database=$(yaml_get_setting "database")
database=${database:-mysql}  # Default to mysql
```

### 4. Validate Before Write

```bash
if ! yaml_validate_sitename "$sitename"; then
    echo "ERROR: Invalid site name" >&2
    exit 1
fi

yaml_add_site "$sitename" "$recipe" "$directory" "testing"
```

### 5. Handle Missing Keys Gracefully

```bash
# Check if key exists before using
if purpose=$(yaml_get_site_field "$site" "purpose" 2>/dev/null); then
    echo "Purpose: $purpose"
else
    echo "No purpose set, using default"
fi
```

---

## Error Handling

All functions follow these conventions:

- **Exit code 0** - Success
- **Exit code 1** - Failure (missing file, invalid key, etc.)
- **Error messages** - Written to stderr with color coding
- **Empty output** - Returns empty string (not "null") on missing keys

### Example Error Handling

```bash
if ! site_dir=$(yaml_get_site_field "$site" "directory"); then
    echo "ERROR: Site $site not found" >&2
    exit 1
fi

if [ -z "$site_dir" ]; then
    echo "ERROR: Site directory not set" >&2
    exit 1
fi
```

---

## Performance Considerations

### yq vs AWK

- **yq** - Faster for complex queries, handles edge cases (anchors, multiline)
- **AWK** - Faster for simple queries on small files, no dependencies

### Caching (Future Enhancement)

Phase 7 of the consolidation proposal includes optional caching:

```bash
# Planned for future release
yaml_cache_load "cnwp.yml"
url=$(yaml_cached_get "settings.url")  # No file I/O
```

---

## Testing

Run the comprehensive test suite:

```bash
bats tests/bats/yaml-read.bats
```

Test results: **39/41 passing (95%)**

---

## See Also

- **Proposal:** `docs/proposals/YAML_PARSER_CONSOLIDATION.md`
- **Examples:** `example.cnwp.yml`
- **Code:** `lib/yaml-write.sh`
- **Tests:** `tests/bats/yaml-read.bats`

---

## Support

For issues or questions about the YAML API:

1. Check function documentation in `lib/yaml-write.sh`
2. Review test cases in `tests/bats/yaml-read.bats`
3. See migration examples in proposal document

---

**Version:** 0.13+
**Maintained by:** NWP Project
**License:** Same as NWP project
