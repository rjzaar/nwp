# YAML API Reference

**Last Updated:** 2026-01-14

NWP provides a consolidated YAML parsing library in `lib/yaml-write.sh` that offers robust, tested functions for reading and writing YAML configuration files.

## Quick Start

```bash
source "$PROJECT_ROOT/lib/yaml-write.sh"

# Read settings from cnwp.yml
url=$(yaml_get_setting "url")
email=$(yaml_get_setting "email.domain")

# Read secrets from .secrets.yml
token=$(yaml_get_secret "linode.api_token")

# Read recipe values
source=$(yaml_get_recipe_field "nwp" "source")

# Read arrays
modules=$(yaml_get_array "sites.mysite.modules")
```

## Architecture

The YAML API consolidates all YAML parsing into a single, well-tested library that:

1. **Eliminates inline AWK parsing** scattered throughout the codebase
2. **Provides consistent error handling** for missing keys and files
3. **Handles edge cases** like quotes, comments, nested structures
4. **Offers comprehensive test coverage** (34 test cases in `tests/bats/yaml-read.bats`)

### File Structure

- **`lib/yaml-write.sh`** - Main YAML library (read and write functions)
- **`tests/bats/yaml-read.bats`** - Comprehensive test suite for read functions
- **`tests/test-yaml-write.sh`** - Integration tests for write functions
- **`tests/fixtures/test-config.yml`** - Test fixture with complex nested YAML

## Reading Functions

### yaml_get_setting

Reads a setting value from `cnwp.yml` using dot notation for nested keys.

**Usage:**
```bash
value=$(yaml_get_setting "key.path")
```

**Arguments:**
- `$1` - Key path using dot notation (e.g., "settings.php_version" or "email.domain")

**Returns:**
- The setting value (stripped of quotes and comments)
- Empty string if key not found

**Examples:**
```bash
# Simple top-level key
url=$(yaml_get_setting "url")

# Nested key with dot notation
php_version=$(yaml_get_setting "settings.php_version")
domain=$(yaml_get_setting "email.domain")

# Triple-nested paths
smtp_host=$(yaml_get_setting "email.smtp.host")

# Handles numeric and boolean values
port=$(yaml_get_setting "database.port")        # Returns: 3306
enabled=$(yaml_get_setting "features.enabled")  # Returns: true
```

**Edge Cases Handled:**
- Strips single and double quotes from values
- Ignores inline comments (e.g., `key: value  # comment`)
- Handles underscores and hyphens in keys and values
- Returns empty string for missing keys (no error)

---

### yaml_get_array

Reads an array from `cnwp.yml` and returns space-separated values.

**Usage:**
```bash
array_values=$(yaml_get_array "path.to.array")
```

**Arguments:**
- `$1` - Key path to the array using dot notation

**Returns:**
- Space-separated string of array values
- Empty string if array not found

**Examples:**
```bash
# Read array from cnwp.yml
modules=$(yaml_get_array "sites.mysite.modules")
# Returns: "module1 module2 module3"

# Iterate over array values
for module in $modules; do
    echo "Module: $module"
done

# Count array items
module_count=$(yaml_get_array "sites.mysite.modules" | wc -w)
```

**YAML Format Expected:**
```yaml
sites:
  mysite:
    modules:
      - pathauto
      - token
      - views
```

**Edge Cases Handled:**
- Strips quotes from array items
- Ignores inline comments after array items
- Handles empty lines in YAML file
- Returns empty string for missing arrays (no error)

---

### yaml_get_recipe_field

Reads a field value from a recipe definition in `cnwp.yml`.

**Usage:**
```bash
value=$(yaml_get_recipe_field "recipe_name" "field_name")
```

**Arguments:**
- `$1` - Recipe name (e.g., "nwp", "d", "dm")
- `$2` - Field name (e.g., "source", "profile", "webroot")

**Returns:**
- The field value from the recipe
- Empty string if recipe or field not found

**Examples:**
```bash
# Read recipe fields
source=$(yaml_get_recipe_field "nwp" "source")
profile=$(yaml_get_recipe_field "nwp" "profile")
webroot=$(yaml_get_recipe_field "nwp" "webroot")

# Different recipes
drupal_source=$(yaml_get_recipe_field "d" "source")
moodle_branch=$(yaml_get_recipe_field "dm" "branch")

# Validate recipe exists
source=$(yaml_get_recipe_field "custom" "source")
if [[ -z "$source" ]]; then
    echo "Recipe 'custom' not found or missing 'source' field"
fi
```

**YAML Format Expected:**
```yaml
recipes:
  nwp:
    source: "https://github.com/example/nwp.git"
    profile: "nwp"
    webroot: "html"
  d:
    source: "drupal/recommended-project"
    profile: "standard"
    webroot: "web"
```

**Edge Cases Handled:**
- Strips quotes from values
- Returns empty for missing recipe or field (no error)
- Works with different recipe types (git-based, composer-based)

---

### yaml_get_secret

Reads a secret value from `.secrets.yml` using dot notation.

**Usage:**
```bash
secret=$(yaml_get_secret "key.path")
```

**Arguments:**
- `$1` - Key path using dot notation (e.g., "linode.api_token")

**Returns:**
- The secret value (stripped of quotes)
- Empty string if key not found or file missing

**Examples:**
```bash
# Read API tokens
linode_token=$(yaml_get_secret "linode.api_token")
cf_token=$(yaml_get_secret "cloudflare.api_token")

# Read nested secrets
smtp_password=$(yaml_get_secret "email.smtp.password")
db_password=$(yaml_get_secret "database.prod.password")

# Handle missing secrets gracefully
token=$(yaml_get_secret "service.api_token")
if [[ -z "$token" ]]; then
    echo "Warning: API token not configured"
    exit 1
fi
```

**Security Notes:**
- Only reads from `.secrets.yml` (infrastructure secrets)
- Does NOT read from `.secrets.data.yml` (protected production credentials)
- See `docs/DATA_SECURITY_BEST_PRACTICES.md` for secrets architecture

**Edge Cases Handled:**
- Gracefully handles missing `.secrets.yml` file
- Strips quotes from secret values
- Returns empty string for missing keys (no error)
- Supports deeply nested secret structures

---

## Writing Functions

### yaml_write_setting

Writes or updates a setting in `cnwp.yml`.

**Usage:**
```bash
yaml_write_setting "key.path" "value"
```

**Arguments:**
- `$1` - Key path using dot notation
- `$2` - Value to write

**Examples:**
```bash
# Update simple setting
yaml_write_setting "url" "https://example.com"

# Update nested setting
yaml_write_setting "settings.php_version" "8.2"
yaml_write_setting "email.domain" "example.org"
```

**Behavior:**
- Creates backup before modifying file
- Updates existing key or creates new one
- Preserves YAML structure and formatting
- Validates syntax after write

---

### yaml_write_site_field

Writes or updates a field in a site configuration.

**Usage:**
```bash
yaml_write_site_field "site_name" "field_name" "value"
```

**Arguments:**
- `$1` - Site name (e.g., "mysite")
- `$2` - Field name (e.g., "php_version", "recipe")
- `$3` - Value to write

**Examples:**
```bash
# Update site fields
yaml_write_site_field "mysite" "php_version" "8.2"
yaml_write_site_field "mysite" "recipe" "nwp"
yaml_write_site_field "mysite" "stage" "installed"
```

---

### yaml_write_array

Writes an array to `cnwp.yml`.

**Usage:**
```bash
yaml_write_array "path.to.array" "item1" "item2" "item3"
```

**Arguments:**
- `$1` - Key path for the array
- `$@` - Array items (space-separated)

**Examples:**
```bash
# Write module array
yaml_write_array "sites.mysite.modules" "pathauto" "token" "views"

# Write empty array
yaml_write_array "sites.mysite.themes"
```

---

## Utility Functions

### yaml_validate

Validates YAML syntax (checks for common errors).

**Usage:**
```bash
if yaml_validate "cnwp.yml"; then
    echo "YAML is valid"
else
    echo "YAML has syntax errors"
fi
```

---

### yaml_backup

Creates a timestamped backup of a YAML file.

**Usage:**
```bash
yaml_backup "cnwp.yml"
# Creates: cnwp.yml.backup-20260113-192000
```

---

## Migration Guide

### Before: Inline AWK Parsing

Old code scattered throughout the codebase:

```bash
# DON'T DO THIS - Inline AWK parsing
url=$(awk '
    /^settings:/ { in_settings = 1; next }
    in_settings && /^[^ ]/ { in_settings = 0 }
    in_settings && /^  url:/ {
        sub(/^  url: */, "");
        gsub(/"/, "");
        print;
        exit
    }
' cnwp.yml)

# DON'T DO THIS - Inline YAML parsing for arrays
modules=$(awk '
    /^sites:/ { in_sites = 1 }
    in_sites && /^  '"$site_name"':/ { in_site = 1 }
    in_site && /^    modules:/ { in_modules = 1; next }
    in_modules && /^    [^ ]/ { exit }
    in_modules && /^ *- / {
        sub(/^ *- */, "");
        gsub(/"/, "");
        printf "%s ", $0
    }
' cnwp.yml)
```

**Problems with this approach:**
- Code duplication (same parsing logic repeated everywhere)
- Error-prone (easy to make mistakes in AWK scripts)
- Hard to test (inline AWK not unit-testable)
- Inconsistent behavior (different scripts handle edge cases differently)
- Maintenance nightmare (bug fixes need to be applied in multiple places)

### After: Consolidated Functions

New code using the YAML API:

```bash
# DO THIS - Use consolidated functions
source "$PROJECT_ROOT/lib/yaml-write.sh"

url=$(yaml_get_setting "url")
modules=$(yaml_get_array "sites.$site_name.modules")
```

**Benefits:**
- Single source of truth for YAML parsing
- Comprehensive test coverage (34 test cases)
- Consistent error handling
- Handles all edge cases (quotes, comments, nested structures)
- Easy to maintain (fix once, works everywhere)

### Migration Steps

1. **Add source statement** at the top of your script:
   ```bash
   source "$PROJECT_ROOT/lib/yaml-write.sh"
   ```

2. **Replace inline AWK** with appropriate function:
   - Settings: `yaml_get_setting "key.path"`
   - Arrays: `yaml_get_array "path.to.array"`
   - Recipes: `yaml_get_recipe_field "recipe" "field"`
   - Secrets: `yaml_get_secret "key.path"`

3. **Test your changes** with the test suite:
   ```bash
   bats tests/bats/yaml-read.bats
   ```

### Common Migration Patterns

#### Pattern 1: Reading Settings

```bash
# Before
php_version=$(awk '/^settings:/,/^[^ ]/ {
    if ($1 == "php_version:") { print $2; exit }
}' cnwp.yml | tr -d '"')

# After
php_version=$(yaml_get_setting "settings.php_version")
```

#### Pattern 2: Reading Arrays

```bash
# Before
readarray -t modules < <(awk "
    /^sites:/ { in_sites = 1 }
    in_sites && /^  $site_name:/ { in_site = 1 }
    in_site && /^    modules:/ { in_modules = 1; next }
    in_modules && /^      - / {
        gsub(/^      - /, \"\");
        gsub(/\"/, \"\");
        print
    }
    in_modules && /^    [^ ]/ { exit }
" cnwp.yml)

# After
modules=$(yaml_get_array "sites.$site_name.modules")
```

#### Pattern 3: Reading Recipes

```bash
# Before
source=$(awk "
    /^recipes:/ { in_recipes = 1 }
    in_recipes && /^  $recipe:/ { in_recipe = 1 }
    in_recipe && /^    source:/ {
        sub(/^    source: */, \"\");
        gsub(/\"/, \"\");
        print;
        exit
    }
" cnwp.yml)

# After
source=$(yaml_get_recipe_field "$recipe" "source")
```

#### Pattern 4: Reading Secrets

```bash
# Before
token=$(awk '/^linode:/,/^[^ ]/ {
    if ($1 == "api_token:") {
        sub(/api_token: */, "");
        gsub(/"/, "");
        print;
        exit
    }
}' .secrets.yml)

# After
token=$(yaml_get_secret "linode.api_token")
```

---

## Testing

### Running Tests

```bash
# Run all YAML read tests
cd /home/rob/nwp
bats tests/bats/yaml-read.bats

# Run specific test
bats tests/bats/yaml-read.bats -f "yaml_get_setting"

# Run integration tests
./tests/test-yaml-write.sh
./tests/test-integration.sh
```

### Test Coverage

The YAML API includes 34 test cases covering:

- ✅ Simple top-level keys
- ✅ Nested keys (dot notation)
- ✅ Deeply nested keys (triple-nested)
- ✅ Quote stripping (single and double quotes)
- ✅ Comment handling (inline and full-line)
- ✅ Numeric and boolean values
- ✅ Arrays (simple and nested)
- ✅ Recipe fields (multiple recipes)
- ✅ Secrets (with missing file handling)
- ✅ Edge cases (underscores, hyphens, empty lines)
- ✅ Error handling (missing keys, files, parameters)
- ✅ Integration scenarios (complex nested structures)

### Writing New Tests

When adding new YAML parsing features, add tests to `tests/bats/yaml-read.bats`:

```bash
@test "yaml_get_setting - your new test case" {
    result=$(yaml_get_setting "your.key.path")
    [ "$result" = "expected_value" ]
}
```

---

## Best Practices

### 1. Always Source the Library

```bash
# At the top of your script
source "$PROJECT_ROOT/lib/yaml-write.sh"
```

### 2. Check for Empty Returns

```bash
value=$(yaml_get_setting "some.key")
if [[ -z "$value" ]]; then
    echo "ERROR: Missing required setting: some.key"
    exit 1
fi
```

### 3. Use Dot Notation for Nested Keys

```bash
# Good - clear hierarchy
email=$(yaml_get_setting "email.domain")
smtp_host=$(yaml_get_setting "email.smtp.host")

# Bad - confusing
email=$(yaml_get_setting "email_domain")
```

### 4. Validate Before Writing

```bash
# Backup before modifying
yaml_backup "cnwp.yml"

# Write changes
yaml_write_setting "settings.php_version" "8.2"

# Validate after write
if ! yaml_validate "cnwp.yml"; then
    echo "ERROR: YAML validation failed, restoring backup"
    # Restore backup logic here
fi
```

### 5. Prefer Functions Over Inline Parsing

```bash
# Good - maintainable, tested
url=$(yaml_get_setting "url")

# Bad - inline parsing
url=$(grep "^url:" cnwp.yml | cut -d: -f2 | tr -d ' "')
```

---

## Troubleshooting

### Function Not Found

**Error:** `bash: yaml_get_setting: command not found`

**Solution:** Source the library at the top of your script:
```bash
source "$PROJECT_ROOT/lib/yaml-write.sh"
```

### Empty Return Value

**Error:** Function returns empty string but key exists in YAML

**Checklist:**
1. Verify key path syntax (use dot notation: "parent.child")
2. Check for typos in key names
3. Ensure YAML structure matches expectation
4. Verify file exists and is readable
5. Check for YAML syntax errors (indentation, quotes)

**Debug:**
```bash
# Print the actual YAML structure
cat cnwp.yml | grep -A 5 "parent:"

# Test with simple key first
result=$(yaml_get_setting "url")
echo "URL result: '$result'"
```

### Quote/Comment Issues

If you're getting unexpected quotes or comments in values:

```bash
# The functions handle this automatically
value=$(yaml_get_setting "key")
# Returns: actual_value (not "actual_value" or "actual_value  # comment")
```

If you're still seeing issues, there may be non-standard YAML formatting.

---

## Performance Considerations

The YAML functions use AWK for parsing, which is fast for most use cases. For large YAML files or repeated reads:

### Good Performance

```bash
# Read once, use many times
php_version=$(yaml_get_setting "settings.php_version")
url=$(yaml_get_setting "url")
# Each call parses the file once - acceptable
```

### Better Performance (Large Scripts)

```bash
# Cache frequently-used values
declare -A settings_cache
settings_cache[php_version]=$(yaml_get_setting "settings.php_version")
settings_cache[url]=$(yaml_get_setting "url")
settings_cache[email]=$(yaml_get_setting "email.domain")

# Use cached values
echo "PHP Version: ${settings_cache[php_version]}"
echo "URL: ${settings_cache[url]}"
```

---

## Related Documentation

- **`docs/DATA_SECURITY_BEST_PRACTICES.md`** - Secrets architecture and security
- **`docs/proposals/YAML_PARSER_CONSOLIDATION.md`** - Implementation proposal
- **`tests/bats/yaml-read.bats`** - Complete test suite with examples
- **`example.cnwp.yml`** - Configuration file structure

---

## API Versioning

This API was introduced in **NWP v0.13** as part of the YAML Parser Consolidation proposal (P13).

### Breaking Changes

If you have scripts using inline AWK parsing, they will continue to work but should be migrated to use the consolidated functions for better maintainability and consistency.

### Future Enhancements

Planned improvements to the YAML API:
- YAML validation with detailed error messages
- Support for writing complex nested structures
- Performance optimization for large files
- Support for YAML anchors and aliases

---

## Contributing

When contributing code that reads YAML:

1. **Use the consolidated functions** - Don't add new inline AWK parsing
2. **Add tests** - Update `tests/bats/yaml-read.bats` for new features
3. **Document edge cases** - Add examples to this documentation
4. **Validate changes** - Run full test suite before committing

```bash
# Before committing
bats tests/bats/yaml-read.bats
./scripts/commands/test-nwp.sh
```

---

## Support

For issues or questions about the YAML API:

1. Check this documentation first
2. Review test cases in `tests/bats/yaml-read.bats` for examples
3. Search existing issues in GitLab/GitHub
4. Create a new issue with:
   - Function being used
   - Expected vs actual behavior
   - YAML structure being parsed
   - Error messages (if any)

---

**Last Updated:** 2026-01-13
**Version:** 0.13
**Status:** Complete
