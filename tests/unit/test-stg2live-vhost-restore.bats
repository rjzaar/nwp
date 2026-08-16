#!/usr/bin/env bats
# nwp/ops#373 — `pl stg2live`'s SSL step must never destroy a working vhost, and
# must never report success over a site it has just taken off the air.
#
# THE INCIDENT (2026-08-15, a site on the live tier, twice in one session)
#   update_nginx_ssl() overwrote /etc/nginx/conf.d/demosite.conf, `nginx -t` failed,
#   and the recovery path ran `rm -f` on the file — four lines under a comment
#   promising "restore the snapshot's version". There was no snapshot and no
#   restore. With no server block for the name, TLS fell THROUGH to the
#   alphabetically-first 443 block on the box: the site served HTTP 500 behind
#   ANOTHER site's certificate, and
#   `pl stg2live` printed `[✓] Deployment completed` and exited 0. It also
#   explains the 2026-08-13 hand-restore of the same vhost, recorded then as a
#   mystery.
#
# WHAT THESE TESTS ARE
#   Fixture-driven, no ssh, no live box. The remote install script is a PURE
#   generator (live_vhost_install_script) so it can be run against a temp
#   directory with a stub `nginx` that fails on demand — the ops#359 design rule
#   "the analysis is local and pure" applied to the write path.
#
# RED PROOF against the pre-fix tree (2026-08-15, this file unchanged):
#   ✗ a failed nginx -t leaves the PREVIOUS vhost installed
#     `update_nginx_ssl` deleted /etc/nginx/conf.d/demosite.conf
#   ✗ a failed SSL/vhost step fails the deploy (does not fall through to success)
#     the SSL block returned 0 after setup_ssl_certificate failed

CMD="${BATS_TEST_DIRNAME}/../../scripts/commands/stg2live.sh"

# Extract one shell function from a script by name.
# `sed -n '/^f() {/,/^}/p' ` — the idiom used elsewhere in tests/unit — TRUNCATES
# update_nginx_ssl, because the nginx config it emits contains a `}` in column 1.
# Stop at the next top-level definition instead.
extract_fn() {
  awk -v n="$2" '
    $0 ~ "^" n "\\(\\)[[:space:]]*\\{" { inf = 1; print; next }
    inf && /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { exit }
    inf && /^#####/ { exit }
    inf { print }
  ' "$1"
}

setup() {
  TEST_TMP=$(mktemp -d)
  CONFD="$TEST_TMP/conf.d"
  BIN="$TEST_TMP/bin"
  mkdir -p "$CONFD" "$BIN"

  # `nginx -t` succeeds unless the fixture says otherwise; the reload is
  # observable so "reloaded" can never be assumed.
  cat > "$BIN/nginx" <<'STUB'
#!/usr/bin/env bash
if [ -f "$NGINX_T_FAILS" ]; then echo "nginx: [emerg] fixture failure" >&2; exit 1; fi
echo "nginx: configuration file test is successful"
STUB
  cat > "$BIN/gitlab-ctl" <<'STUB'
#!/usr/bin/env bash
[ -f "$RELOAD_FAILS" ] && exit 1
echo reloaded >> "$RELOAD_LOG"
STUB
  cp "$BIN/gitlab-ctl" "$BIN/systemctl"
  chmod +x "$BIN"/*
  NGINX_T_FAILS="$TEST_TMP/nginx-t-fails"
  RELOAD_FAILS="$TEST_TMP/reload-fails"
  RELOAD_LOG="$TEST_TMP/reload.log"
  export NGINX_T_FAILS RELOAD_FAILS RELOAD_LOG
  : > "$RELOAD_LOG"

  ORIGINAL='server { listen 443 ssl; server_name demosite.example.org; root /var/www/demosite; }'
  printf '%s\n' "$ORIGINAL" > "$CONFD/demosite.conf"
}
teardown() { rm -rf "$TEST_TMP"; }

# Run the generated remote script the way ssh would: as a shell, with the
# fixture's stubs on PATH and no sudo (the deploy runs sudo-prefixed on the box;
# the prefix is a parameter precisely so this can be driven without root).
run_install_script() {
  eval "$(extract_fn "$CMD" live_vhost_install_script)"
  # NOT VACUOUS: if the generator is missing, say so and fail. A prior session
  # on this issue got "0 failures" out of 0 tests; a fixture that silently does
  # nothing is the same lie at test scope.
  if ! declare -F live_vhost_install_script >/dev/null; then
    echo "MISSING: live_vhost_install_script is not defined in $CMD"
    return 90
  fi
  local script
  script="$(live_vhost_install_script "$CONFD/demosite.conf" "$CONFD/demosite.conf.nwp-prev" "" \
            "gitlab-ctl hup nginx" "$1")"
  PATH="$BIN:$PATH" bash -s <<<"$script"
}

NEWCONF='server { listen 443 ssl; server_name demosite.example.org; root /var/www/demosite/html; }'

# ---------------------------------------------------------------------------
# 1. The promise the comment made: RESTORE, never delete.
# ---------------------------------------------------------------------------

@test "a failed nginx -t leaves the PREVIOUS vhost installed" {
  : > "$NGINX_T_FAILS"
  run run_install_script "$NEWCONF"
  [ "$status" -ne 90 ]
  [ -f "$CONFD/demosite.conf" ]
  [ "$(cat "$CONFD/demosite.conf")" = "$ORIGINAL" ]
}

@test "a failed nginx -t exits non-zero (the deploy may not be told it worked)" {
  : > "$NGINX_T_FAILS"
  run run_install_script "$NEWCONF"
  [ "$status" -ne 0 ]
  [[ "$output" == *RESTORED* ]]
}

@test "a failed nginx -t does NOT reload nginx" {
  : > "$NGINX_T_FAILS"
  run run_install_script "$NEWCONF"
  [ "$status" -ne 90 ]
  [ ! -s "$RELOAD_LOG" ]
}

@test "with no previous vhost, a failed nginx -t leaves the box as it was" {
  rm -f "$CONFD/demosite.conf"
  : > "$NGINX_T_FAILS"
  run run_install_script "$NEWCONF"
  [ "$status" -ne 0 ]
  [ ! -e "$CONFD/demosite.conf" ]
  [[ "$output" == *"no previous vhost"* ]]
}

@test "the snapshot is inert (not *.conf) so nginx never loads two blocks" {
  run run_install_script "$NEWCONF"
  [ "$status" -eq 0 ]
  [ -f "$CONFD/demosite.conf.nwp-prev" ]
  # conf.d is globbed as *.conf, top level only: the snapshot must not match.
  run bash -c "cd '$CONFD' && ls *.conf"
  [ "$output" = "demosite.conf" ]
}

@test "a good config is installed and nginx is reloaded" {
  run run_install_script "$NEWCONF"
  [ "$status" -eq 0 ]
  [ "$(cat "$CONFD/demosite.conf")" = "$NEWCONF" ]
  [ -s "$RELOAD_LOG" ]
}

@test "an empty rendered vhost is refused before anything is overwritten" {
  run run_install_script ""
  [ "$status" -ne 90 ]
  [ "$status" -ne 0 ]
  [ "$(cat "$CONFD/demosite.conf")" = "$ORIGINAL" ]
}

@test "nginx -t passing but the reload failing is not reported as success" {
  : > "$RELOAD_FAILS"
  run run_install_script "$NEWCONF"
  [ "$status" -ne 90 ]
  [ "$status" -ne 0 ]
  [[ "$output" == *reload* ]]
}

# ---------------------------------------------------------------------------
# 2. update_nginx_ssl end to end, with ssh faked onto the fixture directory.
#    This is the function the incident ran.
# ---------------------------------------------------------------------------

fake_ssh_env() {
  # A remote whose /etc/nginx/conf.d is this fixture and whose sudo is a no-op.
  LIVE_VHOST_CONF_DIR=/etc/nginx/conf.d   # rewritten to the fixture by the fake ssh
  ssh() {
    local cmd="${*: -1}"
    cmd="${cmd//\/etc\/nginx\/conf.d/$CONFD}"
    cmd="${cmd//sudo /}"
    case "$cmd" in
      *"bash -s"*) sed "s|/etc/nginx/conf.d|$CONFD|g; s|sudo ||g" | PATH="$BIN:$PATH" bash ;;
      *)           PATH="$BIN:$PATH" bash -c "$cmd" ;;
    esac
  }
  nwp_ssh_opts() { :; }
  resolve_site_php_version() { echo 8.3; }
  print_info() { echo "INFO $*"; }
  print_error() { echo "ERROR $*"; }
  print_status() { echo "$1 ${*:2}"; }
  eval "$(extract_fn "$CMD" render_live_vhost)" 2>/dev/null || true
  eval "$(extract_fn "$CMD" live_vhost_install_script)" 2>/dev/null || true
  eval "$(extract_fn "$CMD" update_nginx_ssl)"
}

@test "update_nginx_ssl: a failing nginx -t leaves the site's vhost in place" {
  : > "$NGINX_T_FAILS"
  fake_ssh_env
  run update_nginx_ssl demosite 203.0.113.9 gitlab demosite.example.org
  [ "$status" -ne 0 ]
  [ -f "$CONFD/demosite.conf" ]
  [ "$(cat "$CONFD/demosite.conf")" = "$ORIGINAL" ]
}

@test "update_nginx_ssl: the happy path still writes the SSL vhost" {
  fake_ssh_env
  run update_nginx_ssl demosite 203.0.113.9 gitlab demosite.example.org
  [ "$status" -eq 0 ]
  grep -q 'ssl_certificate /etc/letsencrypt/live/demosite.example.org/fullchain.pem' "$CONFD/demosite.conf"
  grep -q 'php8.3-fpm.sock' "$CONFD/demosite.conf"
}

# ---------------------------------------------------------------------------
# 3. The swallowed verdict: a failed SSL step must fail the deploy.
# ---------------------------------------------------------------------------

@test "a failed SSL/vhost step fails the deploy (does not fall through to success)" {
  # The SSL block of deploy_to_live, lifted verbatim and run with the step failing.
  local block
  block="$(awk '/^    # Setup SSL certificate$/{f=1} /^    # Deploy production robots.txt$/{f=0} f' "$CMD")"
  [ -n "$block" ]
  eval "_ssl_step() {
    setup_ssl_certificate() { return 1; }
    print_header() { :; }; print_info() { :; }
    print_error() { echo \"ERROR \$*\"; }
    print_status() { echo \"\$1 \${*:2}\"; }
$block
  }"
  run _ssl_step
  [ "$status" -ne 0 ]
}

@test "setup_ssl_certificate never follows update_nginx_ssl with an unconditional return 0" {
  # `update_nginx_ssl …; return 0` discards the failure the function just
  # reported — the second place the verdict was swallowed.
  extract_fn "$CMD" setup_ssl_certificate > "$TEST_TMP/fn"
  run grep -A1 'update_nginx_ssl "\$base_name"' "$TEST_TMP/fn"
  [[ "$output" != *"return 0"* ]]
}

@test "the destroying idiom is gone: update_nginx_ssl never rm -f's a site vhost" {
  extract_fn "$CMD" update_nginx_ssl > "$TEST_TMP/fn"
  run grep -c 'rm -f /etc/nginx/conf.d' "$TEST_TMP/fn"
  [ "$output" = "0" ]
}

@test "stg2live.sh parses with bash -n" {
  run bash -n "$CMD"
  [ "$status" -eq 0 ]
}
