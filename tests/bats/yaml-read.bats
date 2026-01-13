#!/usr/bin/env bats
################################################################################
# BATS tests for YAML read functions in lib/yaml-write.sh
#
# Run with:
#   bats tests/bats/yaml-read.bats
################################################################################

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    YAML_LIB="${PROJECT_ROOT}/lib/yaml-write.sh"

    # Create temporary test config file
    TEST_CONFIG="${BATS_TMPDIR}/test-config-$$.yml"

    # Source the YAML library
    source "$YAML_LIB"

    # Set config file for functions
    export YAML_CONFIG_FILE="$TEST_CONFIG"
}

teardown() {
    # Clean up test config files
    [ -f "$TEST_CONFIG" ] && rm -f "$TEST_CONFIG" || true
    [ -f "${BATS_TMPDIR}/test-secrets-$$.yml" ] && rm -f "${BATS_TMPDIR}/test-secrets-$$.yml" || true
}

################################################################################
# Syntax Tests
################################################################################

@test "yaml-write.sh - syntax check passes" {
    run bash -n "$YAML_LIB"
    [ "$status" -eq 0 ]
}

@test "yaml-write.sh - all new functions are exported" {
    grep -q "export -f yaml_get_all_sites" "$YAML_LIB"
    grep -q "export -f yaml_get_setting" "$YAML_LIB"
    grep -q "export -f yaml_get_array" "$YAML_LIB"
    grep -q "export -f yaml_get_coder_list" "$YAML_LIB"
    grep -q "export -f yaml_get_coder_field" "$YAML_LIB"
    grep -q "export -f yaml_get_recipe_field" "$YAML_LIB"
    grep -q "export -f yaml_get_recipe_list" "$YAML_LIB"
    grep -q "export -f yaml_get_secret" "$YAML_LIB"
}

################################################################################
# yaml_get_all_sites Tests
################################################################################

@test "yaml_get_all_sites - lists all sites from sites section" {
    cat > "$TEST_CONFIG" <<EOF
sites:
  site1:
    directory: sites/site1
  site2:
    directory: sites/site2
  site3:
    directory: sites/site3
EOF

    run yaml_get_all_sites "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"site1"* ]]
    [[ "$output" == *"site2"* ]]
    [[ "$output" == *"site3"* ]]
}

@test "yaml_get_all_sites - returns empty for no sites" {
    cat > "$TEST_CONFIG" <<EOF
sites:
settings:
  url: example.com
EOF

    run yaml_get_all_sites "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "yaml_get_all_sites - ignores commented sites" {
    cat > "$TEST_CONFIG" <<EOF
sites:
  site1:
    directory: sites/site1
  # site2:
  #   directory: sites/site2
EOF

    run yaml_get_all_sites "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"site1"* ]]
    [[ "$output" != *"site2"* ]]
}

################################################################################
# yaml_get_setting Tests
################################################################################

@test "yaml_get_setting - reads simple setting" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  url: nwpcode.org
  database: mariadb
EOF

    run yaml_get_setting "url" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "nwpcode.org" ]
}

@test "yaml_get_setting - reads nested setting (2 levels)" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  email:
    domain: example.com
    admin_email: admin@example.com
EOF

    run yaml_get_setting "email.domain" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "example.com" ]
}

@test "yaml_get_setting - reads nested setting (3 levels)" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  gitlab:
    hardening:
      enabled: true
      disable_signups: true
EOF

    run yaml_get_setting "gitlab.hardening.enabled" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "yaml_get_setting - strips quotes" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  url: "nwpcode.org"
  quoted: 'single.com'
EOF

    run yaml_get_setting "url" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "nwpcode.org" ]

    run yaml_get_setting "quoted" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "single.com" ]
}

@test "yaml_get_setting - strips inline comments" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  url: nwpcode.org  # This is a comment
  database: mariadb # Another comment
EOF

    run yaml_get_setting "url" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "nwpcode.org" ]
}

@test "yaml_get_setting - returns error for missing key" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  url: nwpcode.org
EOF

    run yaml_get_setting "nonexistent" "$TEST_CONFIG"
    [ "$status" -ne 0 ]
}

@test "yaml_get_setting - requires key path argument" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  url: nwpcode.org
EOF

    run yaml_get_setting "" "$TEST_CONFIG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
}

################################################################################
# yaml_get_array Tests
################################################################################

@test "yaml_get_array - reads simple array" {
    cat > "$TEST_CONFIG" <<EOF
other_coders:
  nameservers:
    - ns1.linode.com
    - ns2.linode.com
    - ns3.linode.com
EOF

    run yaml_get_array "other_coders.nameservers" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ns1.linode.com"* ]]
    [[ "$output" == *"ns2.linode.com"* ]]
    [[ "$output" == *"ns3.linode.com"* ]]
}

@test "yaml_get_array - returns items one per line" {
    cat > "$TEST_CONFIG" <<EOF
other_coders:
  nameservers:
    - ns1.linode.com
    - ns2.linode.com
EOF

    result=$(yaml_get_array "other_coders.nameservers" "$TEST_CONFIG")
    line_count=$(echo "$result" | wc -l)
    [ "$line_count" -eq 2 ]
}

@test "yaml_get_array - strips quotes from array items" {
    cat > "$TEST_CONFIG" <<EOF
other_coders:
  nameservers:
    - "ns1.linode.com"
    - 'ns2.linode.com'
EOF

    run yaml_get_array "other_coders.nameservers" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ns1.linode.com"* ]]
    [[ "$output" != *'"'* ]]
    [[ "$output" != *"'"* ]]
}

@test "yaml_get_array - strips inline comments from array items" {
    cat > "$TEST_CONFIG" <<EOF
other_coders:
  nameservers:
    - ns1.linode.com  # Primary
    - ns2.linode.com  # Secondary
EOF

    run yaml_get_array "other_coders.nameservers" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ns1.linode.com"* ]]
    [[ "$output" != *"Primary"* ]]
}

@test "yaml_get_array - returns error for non-existent array" {
    cat > "$TEST_CONFIG" <<EOF
other_coders:
  nameservers:
    - ns1.linode.com
EOF

    run yaml_get_array "other_coders.nonexistent" "$TEST_CONFIG"
    [ "$status" -ne 0 ]
}

@test "yaml_get_array - handles nested site array" {
    cat > "$TEST_CONFIG" <<EOF
sites:
  mysite:
    modules:
      enabled:
        - views
        - pathauto
        - token
EOF

    run yaml_get_array "sites.mysite.modules.enabled" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"views"* ]]
    [[ "$output" == *"pathauto"* ]]
    [[ "$output" == *"token"* ]]
}

################################################################################
# yaml_get_coder_list Tests
################################################################################

@test "yaml_get_coder_list - lists all coders" {
    cat > "$TEST_CONFIG" <<EOF
other_coders:
  nameservers:
    - ns1.linode.com
  coders:
    coder1:
      email: coder1@example.com
      status: active
    coder2:
      email: coder2@example.com
      status: active
EOF

    run yaml_get_coder_list "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"coder1"* ]]
    [[ "$output" == *"coder2"* ]]
}

@test "yaml_get_coder_list - returns empty for no coders" {
    cat > "$TEST_CONFIG" <<EOF
other_coders:
  nameservers:
    - ns1.linode.com
  coders:
EOF

    run yaml_get_coder_list "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

################################################################################
# yaml_get_coder_field Tests
################################################################################

@test "yaml_get_coder_field - reads coder email" {
    cat > "$TEST_CONFIG" <<EOF
other_coders:
  coders:
    coder1:
      email: coder1@example.com
      status: active
      notes: "Test coder"
EOF

    run yaml_get_coder_field "coder1" "email" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "coder1@example.com" ]
}

@test "yaml_get_coder_field - reads coder status" {
    cat > "$TEST_CONFIG" <<EOF
other_coders:
  coders:
    coder1:
      email: coder1@example.com
      status: active
EOF

    run yaml_get_coder_field "coder1" "status" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "active" ]
}

@test "yaml_get_coder_field - strips quotes from field value" {
    cat > "$TEST_CONFIG" <<EOF
other_coders:
  coders:
    coder1:
      notes: "This is a note"
EOF

    run yaml_get_coder_field "coder1" "notes" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "This is a note" ]
}

@test "yaml_get_coder_field - returns error for non-existent coder" {
    cat > "$TEST_CONFIG" <<EOF
other_coders:
  coders:
    coder1:
      email: coder1@example.com
EOF

    run yaml_get_coder_field "nonexistent" "email" "$TEST_CONFIG"
    [ "$status" -ne 0 ]
}

@test "yaml_get_coder_field - requires both arguments" {
    cat > "$TEST_CONFIG" <<EOF
other_coders:
  coders:
    coder1:
      email: coder1@example.com
EOF

    run yaml_get_coder_field "coder1" "" "$TEST_CONFIG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
}

################################################################################
# yaml_get_recipe_field Tests
################################################################################

@test "yaml_get_recipe_field - reads recipe source" {
    cat > "$TEST_CONFIG" <<EOF
recipes:
  oc:
    source: git@github.com:rjzaar/opencourse.git
    recipe: drupal
    webroot: docroot
EOF

    run yaml_get_recipe_field "oc" "source" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "git@github.com:rjzaar/opencourse.git" ]
}

@test "yaml_get_recipe_field - reads recipe webroot" {
    cat > "$TEST_CONFIG" <<EOF
recipes:
  oc:
    source: git@example.com
    webroot: docroot
EOF

    run yaml_get_recipe_field "oc" "webroot" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "docroot" ]
}

@test "yaml_get_recipe_field - strips quotes" {
    cat > "$TEST_CONFIG" <<EOF
recipes:
  oc:
    source: "git@github.com:repo.git"
EOF

    run yaml_get_recipe_field "oc" "source" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "git@github.com:repo.git" ]
}

@test "yaml_get_recipe_field - returns error for non-existent recipe" {
    cat > "$TEST_CONFIG" <<EOF
recipes:
  oc:
    source: git@example.com
EOF

    run yaml_get_recipe_field "nonexistent" "source" "$TEST_CONFIG"
    [ "$status" -ne 0 ]
}

################################################################################
# yaml_get_recipe_list Tests
################################################################################

@test "yaml_get_recipe_list - reads recipe module list" {
    cat > "$TEST_CONFIG" <<EOF
recipes:
  oc:
    post_install_modules:
      - views
      - pathauto
      - token
EOF

    run yaml_get_recipe_list "oc" "post_install_modules" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"views"* ]]
    [[ "$output" == *"pathauto"* ]]
    [[ "$output" == *"token"* ]]
}

@test "yaml_get_recipe_list - returns space-separated items" {
    cat > "$TEST_CONFIG" <<EOF
recipes:
  oc:
    post_install_modules:
      - views
      - pathauto
EOF

    result=$(yaml_get_recipe_list "oc" "post_install_modules" "$TEST_CONFIG")
    [[ "$result" == *"views"*"pathauto"* ]]
}

@test "yaml_get_recipe_list - strips quotes from list items" {
    cat > "$TEST_CONFIG" <<EOF
recipes:
  oc:
    post_install_modules:
      - "views"
      - 'pathauto'
EOF

    run yaml_get_recipe_list "oc" "post_install_modules" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" != *'"'* ]]
    [[ "$output" != *"'"* ]]
}

################################################################################
# yaml_get_secret Tests
################################################################################

@test "yaml_get_secret - reads simple secret" {
    TEST_SECRETS="${BATS_TMPDIR}/test-secrets-$$.yml"
    cat > "$TEST_SECRETS" <<EOF
linode:
  api_token: test-token-12345
cloudflare:
  api_token: cf-token-67890
EOF

    run yaml_get_secret "linode.api_token" "$TEST_SECRETS"
    [ "$status" -eq 0 ]
    [ "$output" = "test-token-12345" ]

    rm -f "$TEST_SECRETS"
}

@test "yaml_get_secret - reads nested secret" {
    TEST_SECRETS="${BATS_TMPDIR}/test-secrets-$$.yml"
    cat > "$TEST_SECRETS" <<EOF
b2:
  backup:
    key_id: backup-key-id
    application_key: backup-app-key
EOF

    run yaml_get_secret "b2.backup.key_id" "$TEST_SECRETS"
    [ "$status" -eq 0 ]
    [ "$output" = "backup-key-id" ]

    rm -f "$TEST_SECRETS"
}

@test "yaml_get_secret - strips quotes from secret" {
    TEST_SECRETS="${BATS_TMPDIR}/test-secrets-$$.yml"
    cat > "$TEST_SECRETS" <<EOF
linode:
  api_token: "test-token-12345"
EOF

    run yaml_get_secret "linode.api_token" "$TEST_SECRETS"
    [ "$status" -eq 0 ]
    [ "$output" = "test-token-12345" ]

    rm -f "$TEST_SECRETS"
}

@test "yaml_get_secret - returns error for missing secret file" {
    run yaml_get_secret "linode.api_token" "/nonexistent/file.yml"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
}

################################################################################
# Edge Case Tests
################################################################################

@test "yaml_get_setting - handles values with spaces" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  description: "This is a test description"
EOF

    run yaml_get_setting "description" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "This is a test description" ]
}

@test "yaml_get_setting - handles values with special characters" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  special: "user@example.com"
EOF

    run yaml_get_setting "special" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "user@example.com" ]
}

@test "yaml_get_array - handles empty array" {
    cat > "$TEST_CONFIG" <<EOF
other_coders:
  nameservers:
EOF

    run yaml_get_array "other_coders.nameservers" "$TEST_CONFIG"
    [ "$status" -ne 0 ]
}

@test "All functions handle missing config file" {
    run yaml_get_all_sites "/nonexistent/file.yml"
    [ "$status" -ne 0 ]

    run yaml_get_setting "url" "/nonexistent/file.yml"
    [ "$status" -ne 0 ]

    run yaml_get_array "other_coders.nameservers" "/nonexistent/file.yml"
    [ "$status" -ne 0 ]
}

################################################################################
# Integration Tests with Real Structure
################################################################################

@test "Integration - realistic cnwp.yml structure" {
    cat > "$TEST_CONFIG" <<EOF
settings:
  url: nwpcode.org
  database: mariadb
  php: 8.2
  email:
    domain: nwpcode.org
    admin_email: admin@example.com
  gitlab:
    hardening:
      enabled: true
      disable_signups: true

other_coders:
  nameservers:
    - ns1.linode.com
    - ns2.linode.com
  coders:
    coder1:
      email: coder1@example.com
      status: active

recipes:
  oc:
    source: git@github.com:rjzaar/opencourse.git
    recipe: drupal
    webroot: docroot
    post_install_modules:
      - views
      - pathauto

sites:
  testsite:
    directory: sites/testsite
    recipe: oc
    purpose: testing
EOF

    # Test all function types
    run yaml_get_setting "url" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "nwpcode.org" ]

    run yaml_get_setting "email.admin_email" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "admin@example.com" ]

    run yaml_get_array "other_coders.nameservers" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ns1.linode.com"* ]]

    run yaml_get_coder_list "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"coder1"* ]]

    run yaml_get_coder_field "coder1" "email" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "coder1@example.com" ]

    run yaml_get_recipe_field "oc" "webroot" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "docroot" ]

    run yaml_get_recipe_list "oc" "post_install_modules" "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"views"* ]]

    run yaml_get_all_sites "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"testsite"* ]]
}
