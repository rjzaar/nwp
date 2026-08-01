#!/usr/bin/env bats
# scripts/commands/drush.sh — the sanctioned `pl drush` remote/stg runner
# (PL-STG2LIVE-INTEGRATION-DESIGN §6 P1-4: retire raw `ssh … "… drush …"`).
#
# Exercises arg parsing (site + tier + verbatim `-- <args>`), the live
# dry-run-by-default house style (no execution without --execute), unknown-tier
# refusal, and the refuse-when-no-server_ip guard — all on throwaway fixtures,
# with NO ssh, NO ddev, NO network and NO secrets. The live path never reaches a
# real ssh in these tests: dry-run prints and returns; the no-server_ip case
# aborts before any connection.

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}"
  DRUSH="${BATS_TEST_DIRNAME}/../../scripts/commands/drush.sh"

  # A fixture live site: enabled, with a (bogus, unrouted) server_ip so the
  # dry-run path resolves a host but never connects. The dev/ subdir makes it a
  # v2 site, so the stg env resolves to sites/nwc/stg (absent until created).
  mkdir -p "${PROJECT_ROOT}/sites/nwc/dev"
  cat > "${PROJECT_ROOT}/sites/nwc/.nwp.yml" <<'EOF'
schema_version: 2
project:
  name: nwc
  type: drupal
live:
  enabled: true
  domain: nwc.example.org
  server_ip: 203.0.113.10
  ssh_user: gitlab
  remote_path: /var/www/nwc
EOF

  # A fixture site whose live tier is NOT configured (no server_ip).
  mkdir -p "${PROJECT_ROOT}/sites/noserver"
  cat > "${PROJECT_ROOT}/sites/noserver/.nwp.yml" <<'EOF'
schema_version: 2
project:
  name: noserver
  type: drupal
live:
  enabled: true
  domain: noserver.example.org
EOF
}

teardown() { rm -rf "${TEST_TMP}"; }

# ── arg parsing: site + tier + verbatim `-- <args>` ──────────────────────────

@test "live dry-run captures site, tier and the verbatim drush args after --" {
  run bash "$DRUSH" nwc --tier=live -- pm:uninstall tracer nwp_lockdown -y
  [ "$status" -eq 0 ]
  # the remote command carries the args verbatim, in order
  [[ "$output" == *"pm:uninstall tracer nwp_lockdown -y"* ]]
  # resolved the fixture host + path from .nwp.yml
  [[ "$output" == *"gitlab@203.0.113.10:/var/www/nwc"* ]]
  # gitlab ssh user ⇒ sudo -u www-data prefix (stg2live idiom)
  [[ "$output" == *"sudo -u www-data drush"* ]]
}

@test "a single-word drush command is accepted after --" {
  run bash "$DRUSH" nwc --tier=live -- cr
  [ "$status" -eq 0 ]
  [[ "$output" == *"drush"* ]]
  [[ "$output" == *"cr"* ]]
}

@test "missing drush args (nothing after --) is refused" {
  run bash "$DRUSH" nwc --tier=live --
  [ "$status" -ne 0 ]
  [[ "$output" == *"No drush arguments"* ]]
}

@test "missing site is refused" {
  run bash "$DRUSH" --tier=live -- cr
  [ "$status" -ne 0 ]
}

# ── live: dry-run by default, no execution without --execute ─────────────────

@test "live defaults to dry-run — prints command, executes nothing" {
  run bash "$DRUSH" nwc --tier=live -- cr
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [[ "$output" == *"Re-run with --execute"* ]]
  # never claims to have run anything
  [[ "$output" != *"drush completed on live"* ]]
}

@test "live dry-run prints both the primary and the vendor/bin fallback command" {
  run bash "$DRUSH" nwc --tier=live -- cr
  [ "$status" -eq 0 ]
  [[ "$output" == *"cd /var/www/nwc && sudo -u www-data drush"* ]]
  [[ "$output" == *"../vendor/bin/drush"* ]]
}

# ── unknown tier is refused (fail-closed) ────────────────────────────────────

@test "an unknown tier is refused" {
  run bash "$DRUSH" nwc --tier=prod -- cr
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown tier"* ]]
}

@test "a missing tier is refused" {
  run bash "$DRUSH" nwc -- cr
  [ "$status" -ne 0 ]
  [[ "$output" == *"--tier is required"* ]]
}

# ── live --execute refuses when the live target is not configured ────────────

@test "live --execute refuses a site with no server_ip (does not provision)" {
  run bash "$DRUSH" noserver --tier=live --execute -- cr
  [ "$status" -ne 0 ]
  [[ "$output" == *"No live server configured"* ]]
  [[ "$output" == *"does not provision"* ]]
}

@test "live --execute refuses a site whose live.enabled is false" {
  mkdir -p "${PROJECT_ROOT}/sites/disabled"
  cat > "${PROJECT_ROOT}/sites/disabled/.nwp.yml" <<'EOF'
project: { name: disabled, type: drupal }
live: { enabled: false, server_ip: 203.0.113.20, ssh_user: gitlab, remote_path: /var/www/disabled }
EOF
  run bash "$DRUSH" disabled --tier=live --execute -- cr
  [ "$status" -ne 0 ]
  [[ "$output" == *"Live disabled"* ]]
}

# ── stg: resolves the local DDEV staging dir; refuses if absent ──────────────

@test "stg tier refuses when the staging site is not present" {
  run bash "$DRUSH" nwc --tier=stg -- cr
  [ "$status" -ne 0 ]
  [[ "$output" == *"Staging site not found"* ]]
}

@test "stg dry-run names the ddev drush command without running it" {
  # Give the site a staging dir so resolution succeeds.
  mkdir -p "${PROJECT_ROOT}/sites/nwc/stg"
  run bash "$DRUSH" nwc --tier=stg --dry-run -- updatedb -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [[ "$output" == *"ddev drush updatedb -y"* ]]
}

# ── --help works and exits 0 ─────────────────────────────────────────────────

@test "pl drush --help prints usage and exits 0" {
  run bash "$DRUSH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"pl drush <site> --tier=dev|stg|live"* ]]
}

# ── --root override (fresh-build side docroot for pl cutover) ────────────────

@test "--root live dry-run targets the non-canonical docroot, not remote_path" {
  run bash "$DRUSH" nwc --tier=live --root=/var/www/nwc-20260720 -- site:install social -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"gitlab@203.0.113.10:/var/www/nwc-20260720"* ]]
  [[ "$output" == *"NON-canonical docroot"* ]]
  [[ "$output" == *"site:install social -y"* ]]
}

@test "--root is refused on the stg tier" {
  run bash "$DRUSH" nwc --tier=stg --root=/var/www/nwc-20260720 -- cr
  [ "$status" -ne 0 ]
  [[ "$output" == *"only valid with --tier=live"* ]]
}

@test "--root refuses a non-absolute path" {
  run bash "$DRUSH" nwc --tier=live --root=nwc-20260720 -- cr
  [ "$status" -ne 0 ]
  [[ "$output" == *"absolute path"* ]]
}

@test "--root refuses a docroot whose basename does not start with the site name (wrong-site guard)" {
  run bash "$DRUSH" nwc --tier=live --root=/var/www/avc-20260720 -- cr
  [ "$status" -ne 0 ]
  [[ "$output" == *"wrong-site guard"* ]]
}

# ── ops#155: project-root vendor/bin/drush fallback ──────────────────────────
# Sites with NO local stg tree (webroot guess defaults to "web") whose live
# docroot is "html" (Open Social template, e.g. avctest) failed BOTH remote
# candidates: PATH drush is absent for www-data, and ${remote_path}/web does
# not exist. The third candidate runs ${remote_path}/vendor/bin/drush from the
# project root, which exists in any composer layout regardless of webroot name.

@test "ops#155: live dry-run prints the project-root vendor/bin/drush fallback" {
  run bash "$DRUSH" nwc --tier=live -- cr
  [ "$status" -eq 0 ]
  [[ "$output" == *"cd /var/www/nwc && sudo -u www-data vendor/bin/drush cr"* ]]
  [[ "$output" == *"Fallback 2:"* ]]
}

@test "ops#155: execute path tries the project-root vendor fallback (three candidates)" {
  grep -q 'fallback2="cd ${remote_path} && ${sudo_prefix} -u www-data vendor/bin/drush${qargs}"' "$DRUSH"
  # and the run chain actually reaches it (not just the print)
  grep -q '"\$fallback2" || {' "$DRUSH"
}
