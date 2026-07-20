#!/usr/bin/env bats
# scripts/commands/stg2live.sh — the live nginx vhost must target the PHP-FPM
# version the BUILD requires, not a hardcoded 8.2. The nwc go-live 500'd
# (2026-07-20) because a PHP>=8.3 build was served by php8.2-fpm. Tests the
# resolve_site_php_version resolver (extracted + run against fixtures) + static
# assertions that the hardcode is gone.

CMD="${BATS_TEST_DIRNAME}/../../scripts/commands/stg2live.sh"

setup() {
  TEST_TMP=$(mktemp -d)
  # Extract just the resolver function and stub its one dependency.
  eval "$(sed -n '/^resolve_site_php_version() {/,/^}/p' "$CMD")"
  get_stg_dir() { echo "$FIXTURE_STG"; }
}
teardown() { rm -rf "$TEST_TMP"; }

@test "stg2live.sh parses with bash -n" {
  run bash -n "$CMD"; [ "$status" -eq 0 ]
}

@test "the php8.2 hardcode is gone from the nginx vhost" {
  run grep -F 'php8.2-fpm.sock' "$CMD"
  [ "$status" -ne 0 ]
}

@test "the vhost fastcgi_pass uses the derived \${php_ver}" {
  run grep -F 'fastcgi_pass unix:/var/run/php/php${php_ver}-fpm.sock' "$CMD"
  [ "$status" -eq 0 ]
}

@test "resolver reads the build's DDEV php_version" {
  FIXTURE_STG="$TEST_TMP/stg"; mkdir -p "$FIXTURE_STG/.ddev"
  printf 'php_version: "8.3"\n' > "$FIXTURE_STG/.ddev/config.yaml"
  run resolve_site_php_version nwc
  [ "$output" = "8.3" ]
}

@test "resolver parses composer require.php when no DDEV config" {
  FIXTURE_STG="$TEST_TMP/stg"; mkdir -p "$FIXTURE_STG"
  printf '{ "require": { "php": ">=8.3" } }\n' > "$FIXTURE_STG/composer.json"
  run resolve_site_php_version nwc
  [ "$output" = "8.3" ]
}

@test "resolver defaults to 8.3 (never 8.2) when nothing is resolvable" {
  FIXTURE_STG="$TEST_TMP/none"
  run resolve_site_php_version nwc
  [ "$output" = "8.3" ]
}

@test "resolver prefers DDEV config over composer" {
  FIXTURE_STG="$TEST_TMP/stg"; mkdir -p "$FIXTURE_STG/.ddev"
  printf 'php_version: "8.4"\n' > "$FIXTURE_STG/.ddev/config.yaml"
  printf '{ "require": { "php": ">=8.3" } }\n' > "$FIXTURE_STG/composer.json"
  run resolve_site_php_version nwc
  [ "$output" = "8.4" ]
}
