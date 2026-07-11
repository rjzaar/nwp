#!/usr/bin/env bats
# nwp/ops D — ADR-0031 D8: Moodle promotion SUBSTRATE (lib/moodle-promote.sh).
# Exercises the settings writer, tier fail-closed, vhost generator, wwwroot
# rewrite plan, OIDC wiring (issuer per tier), and the off-unless-configured
# no-op — all on throwaway fixtures, with NO ddev/drush/network and NO secrets.

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}"

  # Fake Moodle root (version.php marks it as a real Moodle codebase).
  MROOT="${TEST_TMP}/moodleroot"
  mkdir -p "${MROOT}/lib" "${MROOT}/admin/cli"
  echo "<?php \$version = 2024041600;" > "${MROOT}/version.php"

  # Synthetic Moodle site config (.nwp.yml-shaped).
  CFG="${TEST_TMP}/site.nwp.yml"
  cat > "${CFG}" <<'EOF'
schema_version: 2
project:
  name: moodsite
  type: moodle
live:
  domain: moodsite.example.org
moodle:
  tiers:
    dev:
      wwwroot: "https://moodsite-dev.ddev.site"
      dataroot: "/data/moodsite/dev/moodledata"
      dbtype: mariadb
      dbhost: db
      dbname: devdb
      dbuser: devuser
      prefix: "mdl_"
      dbpass_ddev_default: true
    stg:
      wwwroot: "https://moodsite-stg.ddev.site"
      dataroot: "/data/moodsite/stg/moodledata"
      dbtype: mariadb
      dbhost: db
      dbname: stgdb
      dbuser: stguser
      prefix: "stg_"
      dbpass_ddev_default: true
  oauth:
    client_id: ss_moodle
    client_secret_source: "moodle.moodsite.oauth.client_secret"
    enabled: false
EOF

  # Drupal config for the no-op test.
  DCFG="${TEST_TMP}/drupal.nwp.yml"
  cat > "${DCFG}" <<'EOF'
schema_version: 2
project:
  name: drupsite
  type: drupal
EOF

  # Synthetic pair contract (issuer per tier).
  CONTRACT="${TEST_TMP}/moodsite.pair-contract.yml"
  cat > "${CONTRACT}" <<'EOF'
pair: moodsite-nwc
contract_version: 1
provider: nwc
consumer: moodsite
identity:
  uid_lock: true
  coupled_tiers: [live, prod]
endpoints:
  dev:
    issuer: "https://nwc-dev.ddev.site"
  stg:
    issuer: "https://nwc-stg.ddev.site"
EOF

  # Fake auth_nwc plugin source tree (version.php marks it as a real plugin).
  PLUGSRC="${TEST_TMP}/auth_nwc"
  mkdir -p "${PLUGSRC}/classes"
  echo "<?php \$plugin->component='auth_nwc'; \$plugin->version=2026070900;" > "${PLUGSRC}/version.php"
  echo "<?php // auth.php" > "${PLUGSRC}/auth.php"

  source "${BATS_TEST_DIRNAME}/../../lib/ui.sh"
  source "${BATS_TEST_DIRNAME}/../../lib/pair.sh"
  source "${BATS_TEST_DIRNAME}/../../lib/moodle-promote.sh"

  # Bypass any real secret lookup: return a synthetic, recognisable password.
  # Proves the writer reads from the resolver FUNCTION (never argv/hardcoded).
  moodle_db_password() { echo "SYNTH_PW_9c3f"; }
}

teardown() { rm -rf "${TEST_TMP}"; }

# ── settings writer: correct tier-specific config.php ────────────────────────

@test "settings writer produces dev-tier config.php with the right values" {
  run moodle_write_config "${MROOT}" dev "${CFG}"
  [ "$status" -eq 0 ]
  [ -f "${MROOT}/config.php" ]
  grep -q "wwwroot   = 'https://moodsite-dev.ddev.site'" "${MROOT}/config.php"
  grep -q "dataroot  = '/data/moodsite/dev/moodledata'" "${MROOT}/config.php"
  grep -q "dbname    = 'devdb'" "${MROOT}/config.php"
  grep -q "dbuser    = 'devuser'" "${MROOT}/config.php"
  grep -q "prefix    = 'mdl_'" "${MROOT}/config.php"
  grep -q "dbpass    = 'SYNTH_PW_9c3f'" "${MROOT}/config.php"
  # never leaks the live domain into a dev config
  ! grep -q "moodsite.example.org" "${MROOT}/config.php"
}

@test "settings writer emits stg-tier values (different prefix + db)" {
  run moodle_write_config "${MROOT}" stg "${CFG}"
  [ "$status" -eq 0 ]
  grep -q "wwwroot   = 'https://moodsite-stg.ddev.site'" "${MROOT}/config.php"
  grep -q "dbname    = 'stgdb'" "${MROOT}/config.php"
  grep -q "prefix    = 'stg_'" "${MROOT}/config.php"
}

@test "settings writer writes config.php with mode 0600 (secret-bearing)" {
  moodle_write_config "${MROOT}" dev "${CFG}"
  perms=$(stat -c '%a' "${MROOT}/config.php")
  [ "$perms" = "600" ]
}

@test "settings writer is idempotent (same inputs → byte-identical file)" {
  moodle_write_config "${MROOT}" dev "${CFG}"
  h1=$(sha256sum "${MROOT}/config.php" | awk '{print $1}')
  moodle_write_config "${MROOT}" dev "${CFG}"
  h2=$(sha256sum "${MROOT}/config.php" | awk '{print $1}')
  [ "$h1" = "$h2" ]
}

# ── settings writer: fail-closed refusals ────────────────────────────────────

@test "settings writer REFUSES a live (canonical) target — writes nothing" {
  run moodle_write_config "${MROOT}" live "${CFG}"
  [ "$status" -ne 0 ]
  [ ! -f "${MROOT}/config.php" ]
  [[ "$output" == *"REFUSED"* ]]
}

@test "settings writer REFUSES a prod target — writes nothing" {
  run moodle_write_config "${MROOT}" prod "${CFG}"
  [ "$status" -ne 0 ]
  [ ! -f "${MROOT}/config.php" ]
}

@test "settings writer REFUSES an unknown tier (fail-closed)" {
  run moodle_write_config "${MROOT}" staging "${CFG}"
  [ "$status" -ne 0 ]
  [ ! -f "${MROOT}/config.php" ]
}

@test "settings writer REFUSES a non-Moodle root (no version.php)" {
  noroot="${TEST_TMP}/notmoodle"; mkdir -p "$noroot"
  run moodle_write_config "$noroot" dev "${CFG}"
  [ "$status" -ne 0 ]
  [ ! -f "$noroot/config.php" ]
  [[ "$output" == *"version.php"* ]]
}

@test "settings writer REFUSES when the tier has no wwwroot configured" {
  cat > "${TEST_TMP}/nowww.yml" <<'EOF'
project: { name: m, type: moodle }
moodle: { tiers: { dev: { dbname: db } } }
EOF
  run moodle_write_config "${MROOT}" dev "${TEST_TMP}/nowww.yml"
  [ "$status" -ne 0 ]
  [ ! -f "${MROOT}/config.php" ]
}

@test "settings writer REFUSES a dev wwwroot that points at the live domain" {
  cat > "${TEST_TMP}/badwww.yml" <<'EOF'
project: { name: m, type: moodle }
live: { domain: moodsite.example.org }
moodle: { tiers: { dev: { wwwroot: "https://moodsite.example.org" } } }
EOF
  run moodle_write_config "${MROOT}" dev "${TEST_TMP}/badwww.yml"
  [ "$status" -ne 0 ]
  [ ! -f "${MROOT}/config.php" ]
}

# ── vhost generator ──────────────────────────────────────────────────────────

@test "vhost generator emits a valid-looking Moodle server block" {
  out="${TEST_TMP}/vhost.conf"
  run moodle_generate_vhost "moodsite-dev.ddev.site" "${MROOT}" dev "$out" 8.1
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  grep -q "server {" "$out"
  grep -q "server_name moodsite-dev.ddev.site;" "$out"
  grep -q "root ${MROOT};" "$out"
  grep -q "fastcgi_pass unix:/run/php/php8.1-fpm.sock;" "$out"
  grep -q "location ~ \[\^/\]\\\\.php" "$out"
  # non-prod tier → noindex
  grep -q "X-Robots-Tag" "$out"
  # deny config.php
  grep -q "config\\\\.php" "$out"
}

@test "vhost generator omits noindex for a live tier" {
  out="${TEST_TMP}/vhost-live.conf"
  moodle_generate_vhost "moodsite.example.org" "${MROOT}" live "$out" 8.1
  ! grep -q "X-Robots-Tag" "$out"
}

# ── wwwroot rewrite plan: prints, never executes ─────────────────────────────

@test "wwwroot purge cmd echoes admin/cli/purge_caches.php" {
  run moodle_purge_caches_cmd "${MROOT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"admin/cli/purge_caches.php"* ]]
}

@test "wwwroot rewrite plan prints replace.php + purge, and runs nothing" {
  run moodle_wwwroot_rewrite_plan "${MROOT}" "https://old.example" "https://new.example"
  [ "$status" -eq 0 ]
  [[ "$output" == *"admin/cli/replace.php"* ]]
  [[ "$output" == *"--search='https://old.example'"* ]]
  [[ "$output" == *"purge_caches.php"* ]]
  # no side effects: the fixture Moodle root gained no files
  [ ! -f "${MROOT}/config.php" ]
}

# ── OAuth wiring: right issuer per tier, native userinfo, no secret ──────────

@test "oauth consumer config writes the dev issuer + native userinfo endpoint" {
  out="${TEST_TMP}/oidc-dev.yml"
  run moodle_oauth_consumer_config moodsite dev "${CONTRACT}" "${CFG}" "$out"
  [ "$status" -eq 0 ]
  grep -q 'baseurl: "https://nwc-dev.ddev.site"' "$out"
  grep -q 'userinfo_endpoint: "https://nwc-dev.ddev.site/oauth/userinfo"' "$out"
  grep -q 'client_id: "ss_moodle"' "$out"
  grep -q 'enabled: false' "$out"
  # names the secret SOURCE, never a secret value
  grep -q 'client_secret_source: "moodle.moodsite.oauth.client_secret"' "$out"
  ! grep -qi 'client_secret:' "$out"
}

@test "oauth consumer config picks the stg issuer for the stg tier" {
  out="${TEST_TMP}/oidc-stg.yml"
  moodle_oauth_consumer_config moodsite stg "${CONTRACT}" "${CFG}" "$out"
  grep -q 'userinfo_endpoint: "https://nwc-stg.ddev.site/oauth/userinfo"' "$out"
}

@test "oauth consumer config REFUSES a prod tier (auth-adjacent, operator-only)" {
  out="${TEST_TMP}/oidc-prod.yml"
  run moodle_oauth_consumer_config moodsite prod "${CONTRACT}" "${CFG}" "$out"
  [ "$status" -ne 0 ]
  [ ! -f "$out" ]
}

@test "oauth consumer config REFUSES when the contract has no issuer for the tier" {
  cat > "${TEST_TMP}/noissuer.yml" <<'EOF'
provider: nwc
consumer: moodsite
endpoints: { dev: { issuer: "https://nwc-dev.ddev.site" } }
EOF
  out="${TEST_TMP}/oidc-none.yml"
  run moodle_oauth_consumer_config moodsite stg "${TEST_TMP}/noissuer.yml" "${CFG}" "$out"
  [ "$status" -ne 0 ]
  [ ! -f "$out" ]
}

@test "oauth provider snippet has the Moodle callback redirect + client_id, no secret" {
  out="${TEST_TMP}/prov.yml"
  run moodle_oauth_provider_snippet moodsite dev "${CONTRACT}" "${CFG}" "$out"
  [ "$status" -eq 0 ]
  grep -q 'client_id: "ss_moodle"' "$out"
  grep -q 'https://moodsite-dev.ddev.site/admin/oauth2callback.php' "$out"
  ! grep -qE '^\s*client_secret:' "$out"
}

# ── F26 OIDC consumer descriptor: the live-proven gotchas ────────────────────

@test "consumer descriptor uses the /.well-known/jwks.json JWKS URI (not /oauth/jwks)" {
  out="${TEST_TMP}/oidc-jwks.yml"
  moodle_oauth_consumer_config moodsite dev "${CONTRACT}" "${CFG}" "$out"
  grep -q 'jwks_uri: "https://nwc-dev.ddev.site/.well-known/jwks.json"' "$out"
  ! grep -q '/oauth/jwks"' "$out"
}

@test "consumer descriptor carries sub→idnumber + requireconfirmation=0" {
  out="${TEST_TMP}/oidc-map.yml"
  moodle_oauth_consumer_config moodsite dev "${CONTRACT}" "${CFG}" "$out"
  grep -q 'sub: idnumber' "$out"
  grep -q 'requireconfirmation: 0' "$out"
}

@test "_mp_jwks_uri appends /.well-known/jwks.json and strips a trailing slash" {
  run _mp_jwks_uri "https://x.example/"
  [ "$status" -eq 0 ]
  [ "$output" = "https://x.example/.well-known/jwks.json" ]
}

# ── F26 OIDC apply-script generator (the "actually create" artifact) ─────────

@test "apply-script generator writes a runnable PHP script for a dev tier" {
  out="${TEST_TMP}/apply.php"
  run moodle_generate_oidc_apply_script moodsite dev "${CONTRACT}" "${CFG}" "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  head -1 "$out" | grep -q '<?php'
  # real core APIs, not a descriptor
  grep -q '\\core\\oauth2\\api::get_all_issuers' "$out"
  grep -q "new \\\\core\\\\oauth2\\\\issuer" "$out"
  grep -q "issuer_name.*nwc (F26)\|ISSUER_NAME = 'nwc (F26)'" "$out"
}

@test "apply-script ALWAYS creates the sub→idnumber UID-lock mapping" {
  out="${TEST_TMP}/apply2.php"
  moodle_generate_oidc_apply_script moodsite dev "${CONTRACT}" "${CFG}" "$out"
  grep -q "'sub' *=> *'idnumber'" "$out"
  # and fail-closed asserts it before finishing
  grep -q "sub->idnumber mapping absent" "$out"
}

@test "apply-script sets the manual endpoints incl. the correct JWKS URI" {
  out="${TEST_TMP}/apply3.php"
  moodle_generate_oidc_apply_script moodsite dev "${CONTRACT}" "${CFG}" "$out"
  grep -q "BASEURL . '/oauth/authorize'" "$out"
  grep -q "BASEURL . '/oauth/userinfo'" "$out"
  grep -q "/.well-known/jwks.json" "$out"
  ! grep -q "/oauth/jwks'" "$out"
}

@test "apply-script sets requireconfirmation=0 and appends oauth2,nwc to auth" {
  out="${TEST_TMP}/apply4.php"
  moodle_generate_oidc_apply_script moodsite dev "${CONTRACT}" "${CFG}" "$out"
  grep -q "'requireconfirmation' => 0" "$out"
  grep -q "set_config('autoredirect', 0, 'auth_nwc')" "$out"
  grep -q "'email', 'oauth2', 'nwc'" "$out"
}

@test "apply-script contains NO secret — reads it from the environment" {
  out="${TEST_TMP}/apply5.php"
  moodle_generate_oidc_apply_script moodsite dev "${CONTRACT}" "${CFG}" "$out"
  grep -q "getenv('NWC_OIDC_CLIENT_SECRET')" "$out"
  ! grep -qiE "clientsecret.*=.*'[A-Za-z0-9]{8,}'" "$out"
}

@test "apply-script generator REFUSES a prod tier — writes nothing" {
  out="${TEST_TMP}/apply-prod.php"
  run moodle_generate_oidc_apply_script moodsite prod "${CONTRACT}" "${CFG}" "$out"
  [ "$status" -ne 0 ]
  [ ! -f "$out" ]
}

@test "apply-script generator REFUSES when the contract has no issuer for the tier" {
  cat > "${TEST_TMP}/noiss.yml" <<'EOF'
provider: nwc
endpoints: { dev: { issuer: "https://nwc-dev.ddev.site" } }
EOF
  out="${TEST_TMP}/apply-none.php"
  run moodle_generate_oidc_apply_script moodsite stg "${TEST_TMP}/noiss.yml" "${CFG}" "$out"
  [ "$status" -ne 0 ]
  [ ! -f "$out" ]
}

# ── F26 auth_nwc plugin deploy ───────────────────────────────────────────────

@test "auth_nwc deploy copies the plugin into <root>/auth/nwc + prints php8.x upgrade" {
  run moodle_deploy_auth_nwc "${MROOT}" dev "${PLUGSRC}" 8.2
  [ "$status" -eq 0 ]
  [ -f "${MROOT}/auth/nwc/version.php" ]
  [ -f "${MROOT}/auth/nwc/auth.php" ]
  [[ "$output" == *"php8.2 -d max_input_vars=5000"* ]]
  [[ "$output" == *"admin/cli/upgrade.php"* ]]
}

@test "auth_nwc deploy REFUSES a prod tier — copies nothing" {
  run moodle_deploy_auth_nwc "${MROOT}" prod "${PLUGSRC}" 8.2
  [ "$status" -ne 0 ]
  [ ! -d "${MROOT}/auth/nwc" ]
}

@test "auth_nwc deploy REFUSES a non-Moodle root" {
  noroot="${TEST_TMP}/notmoodle2"; mkdir -p "$noroot"
  run moodle_deploy_auth_nwc "$noroot" dev "${PLUGSRC}" 8.2
  [ "$status" -ne 0 ]
  [ ! -d "$noroot/auth/nwc" ]
}

@test "auth_nwc deploy REFUSES a bogus plugin source (no version.php)" {
  badsrc="${TEST_TMP}/badplug"; mkdir -p "$badsrc"
  run moodle_deploy_auth_nwc "${MROOT}" dev "$badsrc" 8.2
  [ "$status" -ne 0 ]
  [ ! -d "${MROOT}/auth/nwc" ]
}

# ── F26 OIDC apply runner: fail-closed refusals (no php/live in unit tests) ───

@test "run_oidc_apply REFUSES a prod tier" {
  echo "<?php" > "${TEST_TMP}/s.php"
  echo "x" > "${MROOT}/config.php"
  run moodle_run_oidc_apply "${MROOT}" prod "${TEST_TMP}/s.php" moodsite "${CFG}" 8.2
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
}

@test "run_oidc_apply REFUSES when config.php / script is missing" {
  run moodle_run_oidc_apply "${MROOT}" dev "${TEST_TMP}/nope.php" moodsite "${CFG}" 8.2
  [ "$status" -ne 0 ]
}

# ── off-unless-configured: the substrate is a no-op for non-Moodle sites ──────

@test "_moodle_is_moodle_site: true for a moodle config, false for drupal" {
  run _moodle_is_moodle_site "${CFG}";  [ "$status" -eq 0 ]
  run _moodle_is_moodle_site "${DCFG}"; [ "$status" -ne 0 ]
}

@test "moodle_promote_plan is a no-op for a non-Moodle site (writes nothing)" {
  run moodle_promote_plan drupsite dev "${DCFG}" "${MROOT}" "${CONTRACT}" "${TEST_TMP}/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
  [ ! -f "${MROOT}/config.php" ]
  [ ! -d "${TEST_TMP}/out" ]
}

@test "moodle_promote_plan prints an ordered plan for a Moodle site but writes nothing" {
  run moodle_promote_plan moodsite dev "${CFG}" "${MROOT}" "${CONTRACT}" "${TEST_TMP}/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"settings:"* ]]
  [[ "$output" == *"vhost:"* ]]
  [[ "$output" == *"oauth:"* ]]
  [ ! -f "${MROOT}/config.php" ]
}

@test "moodle_promote_plan REFUSES a live tier even for a Moodle site" {
  run moodle_promote_plan moodsite live "${CFG}" "${MROOT}"
  [ "$status" -ne 0 ]
}

# ── the substrate command is a no-op for a non-Moodle site (fleet-safe) ───────

@test "pl moodle-promote dry-run is a no-op for a drupal site" {
  mkdir -p "${PROJECT_ROOT}/sites/drupsite"
  cp "${DCFG}" "${PROJECT_ROOT}/sites/drupsite/.nwp.yml"
  run bash "${BATS_TEST_DIRNAME}/../../scripts/commands/moodle-promote.sh" drupsite --tier=dev --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
}

@test "pl moodle-promote dry-run plans (no writes) for a Moodle site" {
  mkdir -p "${PROJECT_ROOT}/sites/moodsite/dev/lib"
  cp "${CFG}" "${PROJECT_ROOT}/sites/moodsite/.nwp.yml"
  echo "<?php \$version=1;" > "${PROJECT_ROOT}/sites/moodsite/dev/version.php"
  run bash "${BATS_TEST_DIRNAME}/../../scripts/commands/moodle-promote.sh" moodsite --tier=dev --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN"* ]]
  [ ! -f "${PROJECT_ROOT}/sites/moodsite/dev/config.php" ]
}

# ── Moodle-aware smoke: dry-run returns without network ───────────────────────

@test "pl moodle-smoke dry-run returns 0 without touching the network" {
  export NWP_PAIR_CONTRACT_DIR="${TEST_TMP}/pairs"
  mkdir -p "${NWP_PAIR_CONTRACT_DIR}"
  cp "${CONTRACT}" "${NWP_PAIR_CONTRACT_DIR}/moodsite.pair-contract.yml"
  run bash "${BATS_TEST_DIRNAME}/../../scripts/commands/moodle-smoke.sh" moodsite --tier=dev --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run"* ]]
  [[ "$output" == *"openid-configuration"* ]]
}

@test "pl moodle-smoke refuses --run against prod without --force-prod" {
  export NWP_PAIR_CONTRACT_DIR="${TEST_TMP}/pairs"
  mkdir -p "${NWP_PAIR_CONTRACT_DIR}"
  cp "${CONTRACT}" "${NWP_PAIR_CONTRACT_DIR}/moodsite.pair-contract.yml"
  run bash "${BATS_TEST_DIRNAME}/../../scripts/commands/moodle-smoke.sh" moodsite --tier=prod --run
  [ "$status" -ne 0 ]
}
