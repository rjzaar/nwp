#!/usr/bin/env bats
# PL-STG2LIVE §6 P0-4 — `pl secrets inject`: registry-driven env-config +
# cross-site token injection. These tests run fully OFFLINE: every case is
# either --dry-run (no live write) or a fail-closed abort BEFORE any ssh.
# Assertions prove the ADR-0017 invariant — key-paths are printed, values are
# NOT. Fixtures use obvious placeholder values (never token-shaped) so the
# gitleaks pre-push stays green.

setup() {
  SECRETS_SH="${BATS_TEST_DIRNAME}/../../scripts/commands/secrets.sh"
  TEST_TMP=$(mktemp -d)

  # Tokenless registry with an inject: block for a drupal + a moodle site.
  # NOTE the placeholder secret VALUES live in the .secrets.yml fixture below;
  # the registry only names key-paths + targets.
  export NWP_SECRETS_REGISTRY="${TEST_TMP}/registry.yml"
  cat > "${NWP_SECRETS_REGISTRY}" <<'YML'
version: 1
secrets: []
inject:
  - site: injdrupal
    platform: drupal
    tiers: [live, stg]
    overrides_file: /var/www/injdrupal/html/sites/default/settings.local.overrides.php
    config:
      - { object: "nwc_feedback.cross_site", keys: [bearer_token],       secret: link.injpair.bearer_token }
      - { object: "nwc_copyright.settings",  keys: [moodle, admin_token], secret: link.injpair.admin_token }
      - { object: "nwc_copyright.settings",  keys: [moodle, base_url],    value: "https://injmoodle.example.org" }
      - { object: "simple_oauth.settings",   keys: [public_key],          value: "/var/www/injdrupal/oauth-keys/public.key" }
      - { object: "simple_oauth.settings",   keys: [private_key],         value: "/var/www/injdrupal/oauth-keys/private.key" }
  - site: injmoodle
    platform: moodle
    tiers: [live, stg]
    config:
      - { component: local_nwc_copyright_sync, name: admin_token,  secret: link.injpair.admin_token }
      - { component: local_nwc_copyright_sync, name: signal_token, secret: link.injpair.signal_token }
      - { component: local_nwc_copyright_sync, name: nwc_base_url, value: "https://injdrupal.example.org" }
YML

  # Placeholder secret store — VALUES are deliberately NOT token-shaped.
  export NWP_SECRETS_FILE="${TEST_TMP}/secrets.yml"
  cat > "${NWP_SECRETS_FILE}" <<'YML'
link:
  injpair:
    bearer_token: PLACEHOLDER_bearer_not_a_real_token
    admin_token: PLACEHOLDER_admin_not_a_real_token
    signal_token: PLACEHOLDER_signal_not_a_real_token
YML

  # A store with one required key empty (fail-closed fixture).
  export NWP_SECRETS_FILE_EMPTY="${TEST_TMP}/secrets-empty.yml"
  cat > "${NWP_SECRETS_FILE_EMPTY}" <<'YML'
link:
  injpair:
    bearer_token: ""
    admin_token: PLACEHOLDER_admin_not_a_real_token
    signal_token: PLACEHOLDER_signal_not_a_real_token
YML
}

teardown() { rm -rf "${TEST_TMP}"; }

# Strip ANSI so greps are robust.
run_inject() { run bash -c "set -o pipefail; '${SECRETS_SH}' inject $* 2>&1 | sed 's/\x1b\[[0-9;]*m//g'"; }

@test "inject: dispatch is wired (help needs no registry)" {
  run bash -c "NWP_SECRETS_REGISTRY=/nonexistent '${SECRETS_SH}' inject --help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pl secrets inject"* ]]
  [[ "$output" == *"--tier=stg|live"* ]]
}

@test "inject: appears in the top-level help listing" {
  run bash -c "'${SECRETS_SH}' help 2>&1 | sed 's/\x1b\[[0-9;]*m//g'"
  [[ "$output" == *"inject"* ]]
}

@test "inject: --dry-run prints Drupal key-paths and NEVER the secret values" {
  run_inject injdrupal --tier=stg --dry-run
  [ "$status" -eq 0 ]
  # Key-paths ARE shown…
  [[ "$output" == *"\$config['nwc_feedback.cross_site']['bearer_token']"* ]]
  [[ "$output" == *"\$config['nwc_copyright.settings']['moodle']['admin_token']"* ]]
  # …but no secret value ever leaks.
  [[ "$output" != *"PLACEHOLDER_bearer_not_a_real_token"* ]]
  [[ "$output" != *"PLACEHOLDER_admin_not_a_real_token"* ]]
  # dry-run must not have written to any live host.
  [[ "$output" == *"[dry-run]"* ]]
}

@test "inject: fail-closed when a required registry secret is empty" {
  run bash -c "set -o pipefail; NWP_SECRETS_FILE='${NWP_SECRETS_FILE_EMPTY}' '${SECRETS_SH}' inject injdrupal --tier=stg 2>&1 | sed 's/\x1b\[[0-9;]*m//g'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL-CLOSED"* ]]
  [[ "$output" == *"bearer_token"* ]]
  # Even the fail-closed path never prints a value.
  [[ "$output" != *"PLACEHOLDER_admin_not_a_real_token"* ]]
}

@test "inject: refuses live when server_ip is empty (site not provisioned)" {
  run_inject injdrupal --tier=live --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing live inject"* ]]
  [[ "$output" == *"server_ip"* ]]
}

@test "inject: Drupal target = settings.local.overrides.php" {
  run_inject injdrupal --tier=stg --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"settings.local.overrides.php"* ]]
  [[ "$output" == *"(drupal, tier=stg"* ]]
}

@test "inject: Moodle target = admin/cli/cfg.php and component/name rows" {
  run_inject injmoodle --tier=stg --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"admin/cli/cfg.php"* ]]
  [[ "$output" == *"local_nwc_copyright_sync/admin_token"* ]]
  [[ "$output" == *"(moodle, tier=stg"* ]]
  # No settings.local.overrides.php on the Moodle path.
  [[ "$output" != *"settings.local.overrides.php"* ]]
}

@test "inject: unknown site fails closed (no inject spec)" {
  run_inject nosuchsite --tier=stg --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"no inject spec"* ]]
}

@test "inject: bad tier is rejected" {
  run_inject injdrupal --tier=prod --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--tier must be stg or live"* ]]
}

@test "inject: dry-run renders an IMPACT manifest before any apply" {
  run_inject injdrupal --tier=stg --dry-run
  [[ "$output" == *"WILL BE OVERWRITTEN"* ]]
  [[ "$output" == *"NOT AFFECTED"* ]]
  [[ "$output" == *"oauth-keys"* ]]
}
