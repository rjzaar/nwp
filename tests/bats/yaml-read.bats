#!/usr/bin/env bats
################################################################################
# BATS tests for YAML read functions in lib/yaml-write.sh
#
# Tests Phase 1 functions:
#   - yaml_get_setting()
#   - yaml_get_array()
#   - yaml_get_recipe_field()
#   - yaml_get_secret()
#
# Run with:
#   bats tests/bats/yaml-read.bats
################################################################################

setup() {
    # Get project root
    export PROJECT_ROOT="/home/rob/nwp-yaml-consolidation"

    # Source the yaml library
    source "$PROJECT_ROOT/lib/yaml-write.sh"

    # Create temporary directory for test files
    TEST_DIR=$(mktemp -d)
    export TEST_CONFIG="$TEST_DIR/test.yml"
    export TEST_SECRETS="$TEST_DIR/test-secrets.yml"
    export TEST_RECIPES="$TEST_DIR/test-recipes.yml"
}

teardown() {
    # Clean up temporary files
    rm -rf "$TEST_DIR"
}

################################################################################
# yaml_get_setting() Tests
################################################################################

@test "yaml_get_setting - reads simple top-level key" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  url: example.com
  database: mariadb
EOF

    result=$(yaml_get_setting "url" "$TEST_CONFIG")
    [ "$result" = "example.com" ]
}

@test "yaml_get_setting - reads nested key with dot notation" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  email:
    domain: example.com
    admin_email: admin@example.com
EOF

    result=$(yaml_get_setting "email.domain" "$TEST_CONFIG")
    [ "$result" = "example.com" ]
}

@test "yaml_get_setting - reads deeply nested key" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  php_settings:
    memory_limit: 512M
    max_execution_time: 600
EOF

    result=$(yaml_get_setting "php_settings.memory_limit" "$TEST_CONFIG")
    [ "$result" = "512M" ]
}

@test "yaml_get_setting - strips quotes from value" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  url: "example.com"
  name: 'test-site'
EOF

    result=$(yaml_get_setting "url" "$TEST_CONFIG")
    [ "$result" = "example.com" ]

    result=$(yaml_get_setting "name" "$TEST_CONFIG")
    [ "$result" = "test-site" ]
}

@test "yaml_get_setting - ignores inline comments" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  url: example.com  # This is a comment
  database: mariadb # Another comment
EOF

    result=$(yaml_get_setting "url" "$TEST_CONFIG")
    [ "$result" = "example.com" ]
}

@test "yaml_get_setting - returns empty for missing key" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  url: example.com
EOF

    run yaml_get_setting "nonexistent" "$TEST_CONFIG"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "yaml_get_setting - handles numeric values" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  php_settings:
    max_execution_time: 600
    upload_max_filesize: 100M
EOF

    result=$(yaml_get_setting "php_settings.max_execution_time" "$TEST_CONFIG")
    [ "$result" = "600" ]
}

@test "yaml_get_setting - handles boolean values" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  email:
    auto_configure: true
  debug: false
EOF

    result=$(yaml_get_setting "email.auto_configure" "$TEST_CONFIG")
    [ "$result" = "true" ]

    result=$(yaml_get_setting "debug" "$TEST_CONFIG")
    [ "$result" = "false" ]
}

@test "yaml_get_setting - requires key path parameter" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  url: example.com
EOF

    run yaml_get_setting "" "$TEST_CONFIG"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error"* ]]
}

@test "yaml_get_setting - handles triple-nested paths" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  gitlab:
    hardening:
      enabled: true
      password_min_length: 12
EOF

    result=$(yaml_get_setting "gitlab.hardening.enabled" "$TEST_CONFIG")
    [ "$result" = "true" ]

    result=$(yaml_get_setting "gitlab.hardening.password_min_length" "$TEST_CONFIG")
    [ "$result" = "12" ]
}

################################################################################
# yaml_get_array() Tests
################################################################################

@test "yaml_get_array - reads simple array" {
    cat > "$TEST_CONFIG" <<EOF
other_coders:
  nameservers:
    - ns1.linode.com
    - ns2.linode.com
    - ns3.linode.com
EOF

    result=$(yaml_get_array "other_coders.nameservers" "$TEST_CONFIG")
    [ "$(echo "$result" | wc -l)" -eq 3 ]
    [ "$(echo "$result" | head -1)" = "ns1.linode.com" ]
    [ "$(echo "$result" | tail -1)" = "ns3.linode.com" ]
}

@test "yaml_get_array - reads nested array" {
    cat > "$TEST_CONFIG" <<EOF
sites:
  mysite:
    installed_modules:
      - admin_toolbar
      - pathauto
      - views
EOF

    result=$(yaml_get_array "sites.mysite.installed_modules" "$TEST_CONFIG")
    [ "$(echo "$result" | wc -l)" -eq 3 ]
    [[ "$result" == *"admin_toolbar"* ]]
    [[ "$result" == *"pathauto"* ]]
}

@test "yaml_get_array - strips quotes from array items" {
    cat > "$TEST_CONFIG" <<EOF
array_section:
  items:
    - "quoted-item"
    - 'single-quoted'
    - unquoted
EOF

    result=$(yaml_get_array "array_section.items" "$TEST_CONFIG")
    [ "$(echo "$result" | wc -l)" -eq 3 ]
    [ "$(echo "$result" | head -1)" = "quoted-item" ]
}

@test "yaml_get_array - ignores inline comments in array" {
    cat > "$TEST_CONFIG" <<EOF
modules:
  enabled:
    - admin_toolbar  # Admin UI enhancement
    - pathauto       # URL aliases
EOF

    result=$(yaml_get_array "modules.enabled" "$TEST_CONFIG")
    [ "$(echo "$result" | wc -l)" -eq 2 ]
    [ "$(echo "$result" | head -1)" = "admin_toolbar" ]
}

@test "yaml_get_array - returns empty for missing array" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  url: example.com
EOF

    run yaml_get_array "settings.nonexistent" "$TEST_CONFIG"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "yaml_get_array - requires path parameter" {
    cat > "$TEST_CONFIG" <<EOF
array:
  items:
    - one
EOF

    run yaml_get_array "" "$TEST_CONFIG"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error"* ]]
}

################################################################################
# yaml_get_recipe_field() Tests
################################################################################

@test "yaml_get_recipe_field - reads recipe field" {
    cat > "$TEST_RECIPES" <<EOF
recipes:
  d:
    source: drupal/recommended-project
    dev: y
    webroot: web
  nwp:
    source: git@gitlab.example.com:nwp/nwp-project.git
    dev: n
EOF

    result=$(yaml_get_recipe_field "d" "source" "$TEST_RECIPES")
    [ "$result" = "drupal/recommended-project" ]

    result=$(yaml_get_recipe_field "d" "webroot" "$TEST_RECIPES")
    [ "$result" = "web" ]
}

@test "yaml_get_recipe_field - reads different recipes" {
    cat > "$TEST_RECIPES" <<EOF
recipes:
  d:
    source: drupal/recommended-project
  nwp:
    source: git@example.com:nwp/nwp.git
EOF

    result=$(yaml_get_recipe_field "d" "source" "$TEST_RECIPES")
    [ "$result" = "drupal/recommended-project" ]

    result=$(yaml_get_recipe_field "nwp" "source" "$TEST_RECIPES")
    [ "$result" = "git@example.com:nwp/nwp.git" ]
}

@test "yaml_get_recipe_field - strips quotes" {
    cat > "$TEST_RECIPES" <<EOF
recipes:
  test:
    source: "quoted-source"
    name: 'single-quoted'
EOF

    result=$(yaml_get_recipe_field "test" "source" "$TEST_RECIPES")
    [ "$result" = "quoted-source" ]
}

@test "yaml_get_recipe_field - returns empty for missing recipe" {
    cat > "$TEST_RECIPES" <<EOF
recipes:
  d:
    source: drupal/recommended-project
EOF

    run yaml_get_recipe_field "nonexistent" "source" "$TEST_RECIPES"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "yaml_get_recipe_field - returns empty for missing field" {
    cat > "$TEST_RECIPES" <<EOF
recipes:
  d:
    source: drupal/recommended-project
EOF

    run yaml_get_recipe_field "d" "nonexistent" "$TEST_RECIPES"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "yaml_get_recipe_field - requires recipe and field parameters" {
    cat > "$TEST_RECIPES" <<EOF
recipes:
  d:
    source: test
EOF

    run yaml_get_recipe_field "" "source" "$TEST_RECIPES"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error"* ]]

    run yaml_get_recipe_field "d" "" "$TEST_RECIPES"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error"* ]]
}

################################################################################
# yaml_get_secret() Tests
################################################################################

@test "yaml_get_secret - reads top-level secret" {
    cat > "$TEST_SECRETS" <<EOF
linode:
  api_token: test-token-123
cloudflare:
  api_token: cf-token-456
EOF

    result=$(yaml_get_secret "linode.api_token" "$TEST_SECRETS")
    [ "$result" = "test-token-123" ]
}

@test "yaml_get_secret - reads nested secret" {
    cat > "$TEST_SECRETS" <<EOF
gitlab:
  server:
    domain: git.example.com
    ip: 192.168.1.100
  api_token: gitlab-token
EOF

    result=$(yaml_get_secret "gitlab.server.domain" "$TEST_SECRETS")
    [ "$result" = "git.example.com" ]

    result=$(yaml_get_secret "gitlab.api_token" "$TEST_SECRETS")
    [ "$result" = "gitlab-token" ]
}

@test "yaml_get_secret - strips quotes from secrets" {
    cat > "$TEST_SECRETS" <<EOF
api:
  token: "quoted-token"
  key: 'single-quoted-key'
EOF

    result=$(yaml_get_secret "api.token" "$TEST_SECRETS")
    [ "$result" = "quoted-token" ]

    result=$(yaml_get_secret "api.key" "$TEST_SECRETS")
    [ "$result" = "single-quoted-key" ]
}

@test "yaml_get_secret - returns empty for missing key" {
    cat > "$TEST_SECRETS" <<EOF
linode:
  api_token: test-token
EOF

    run yaml_get_secret "nonexistent.key" "$TEST_SECRETS"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "yaml_get_secret - requires key path parameter" {
    cat > "$TEST_SECRETS" <<EOF
api:
  token: test
EOF

    run yaml_get_secret "" "$TEST_SECRETS"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error"* ]]
}

@test "yaml_get_secret - fails gracefully for missing file" {
    run yaml_get_secret "linode.api_token" "/nonexistent/file.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error"* ]]
}

@test "yaml_get_secret - handles deeply nested secrets" {
    cat > "$TEST_SECRETS" <<EOF
services:
  production:
    database:
      host: db.example.com
      password: secret-pass
EOF

    result=$(yaml_get_secret "services.production.database.password" "$TEST_SECRETS")
    [ "$result" = "secret-pass" ]
}

################################################################################
# Edge Cases and Special Characters
################################################################################

@test "yaml_get_setting - handles underscores in keys" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  php_settings:
    memory_limit: 512M
    max_execution_time: 600
EOF

    result=$(yaml_get_setting "php_settings.memory_limit" "$TEST_CONFIG")
    [ "$result" = "512M" ]
}

@test "yaml_get_setting - handles hyphens in values" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  name: test-site-name
  env: pre-production
EOF

    result=$(yaml_get_setting "name" "$TEST_CONFIG")
    [ "$result" = "test-site-name" ]
}

@test "yaml_get_array - handles empty lines in file" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  items:
    - item1

    - item2

    - item3
EOF

    result=$(yaml_get_array "settings.items" "$TEST_CONFIG")
    [ "$(echo "$result" | wc -l)" -eq 3 ]
}

@test "yaml_get_setting - ignores full-line comments" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  # This is a comment
  url: example.com
  # Another comment
  database: mariadb
EOF

    result=$(yaml_get_setting "url" "$TEST_CONFIG")
    [ "$result" = "example.com" ]
}

################################################################################
# Integration Tests with Real Config Structure
################################################################################

@test "integration - reads from complex nested structure" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  url: nwpcode.org
  email:
    domain: nwpcode.org
    admin_email: admin@example.com
    auto_configure: true
  php_settings:
    memory_limit: 512M
    max_execution_time: 600
  gitlab:
    hardening:
      enabled: true
      password_min_length: 12

sites:
  testsite:
    directory: sites/testsite
    recipe: d
    installed_modules:
      - admin_toolbar
      - pathauto
EOF

    # Test various depth levels
    result=$(yaml_get_setting "url" "$TEST_CONFIG")
    [ "$result" = "nwpcode.org" ]

    result=$(yaml_get_setting "email.domain" "$TEST_CONFIG")
    [ "$result" = "nwpcode.org" ]

    result=$(yaml_get_setting "gitlab.hardening.enabled" "$TEST_CONFIG")
    [ "$result" = "true" ]

    result=$(yaml_get_array "sites.testsite.installed_modules" "$TEST_CONFIG")
    [ "$(echo "$result" | wc -l)" -eq 2 ]
}
