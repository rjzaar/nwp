#!/usr/bin/env bats
# lib/server-handoff.sh — the traffic switch used by a server migration.
#
# Context: a DNS cutover is a fade, not a switch. While resolvers still hold the
# old A record, BOTH boxes answer for the same hostname against their own
# database, and writes landing on the old one are destroyed at prune time. These
# tests pin the properties that make the switch safe.

setup() {
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  LIB="${REPO_ROOT}/lib/server-handoff.sh"
}

@test "drain emits a 443 block ONLY when a certificate exists" {
  # Referencing a missing certificate makes nginx refuse the ENTIRE config,
  # which would take every other site on the box down with it.
  run bash -c "source '$LIB'; handoff_render_drain example.org 1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"listen 443"* ]]
  [[ "$output" == *"ssl_certificate"* ]]

  run bash -c "source '$LIB'; handoff_render_drain example.org 0"
  [ "$status" -eq 0 ]
  [[ "$output" == *"listen 80"* ]]
  [[ "$output" != *"listen 443"* ]]
  [[ "$output" != *"ssl_certificate"* ]]
}

@test "front emits a 443 block ONLY when a certificate exists" {
  run bash -c "source '$LIB'; handoff_render_front example.org 10.0.0.9 1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"listen 443"* ]]
  [[ "$output" == *"proxy_pass https://10.0.0.9"* ]]

  run bash -c "source '$LIB'; handoff_render_front example.org 10.0.0.9 0"
  [ "$status" -eq 0 ]
  [[ "$output" == *"proxy_pass http://10.0.0.9"* ]]
  [[ "$output" != *"listen 443"* ]]
}

@test "front preserves the original Host and forwards the real client" {
  # Without Host preservation Drupal/Moodle generate links for the wrong site;
  # without X-Forwarded-For every request appears to come from the old box.
  run bash -c "source '$LIB'; handoff_render_front app.example.org 10.0.0.9 1"
  [ "$status" -eq 0 ]
  [[ "$output" == *'proxy_set_header Host $host'* ]]
  [[ "$output" == *'X-Forwarded-For $proxy_add_x_forwarded_for'* ]]
  [[ "$output" == *'X-Forwarded-Proto $scheme'* ]]
  # SNI, so the upstream serves the certificate for the ORIGINAL hostname.
  [[ "$output" == *"proxy_ssl_server_name on"* ]]
  [[ "$output" == *'proxy_ssl_name $host'* ]]
}

@test "drain returns 503, not 404 or a redirect" {
  # 503 is the honest status: the service exists and is coming back. A 404
  # invites search engines to drop the page; a redirect loses the request.
  run bash -c "source '$LIB'; handoff_render_drain example.org 1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"return 503"* ]]
  [[ "$output" != *"return 404"* ]]
}

@test "drain leaves ACME reachable so a renewal in the window is not collateral damage" {
  run bash -c "source '$LIB'; handoff_render_drain example.org 1"
  [ "$status" -eq 0 ]
  [[ "$output" == *".well-known/acme-challenge"* ]]
}

@test "the nginx test and the nginx reload agree on WHICH nginx is serving" {
  # The box that started this migration runs GitLab's BUNDLED nginx while the
  # distro nginx package is installed but inactive, so `sudo nginx -t` there
  # validates a config nobody is using — and the sites box is a clone that has
  # BOTH on disk. Detection must therefore be by what is RUNNING, and the test
  # must target the same server the reload will hup, or the safety check is
  # checking the wrong file.
  run bash -c "sed -n '/^handoff_nginx_test()/,/^}/p' '$LIB'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"systemctl is-active --quiet nginx"* ]]

  run bash -c "sed -n '/^handoff_nginx_reload()/,/^}/p' '$LIB'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"systemctl is-active --quiet nginx"* ]]

  # Both must know about the omnibus path as the non-systemd case.
  grep -q 'gitlab-ctl hup nginx' "$LIB"
  grep -q '/opt/gitlab/embedded/sbin/nginx' "$LIB"
}

@test "server names are read from the running config, not a hand-kept list" {
  run bash -c "sed -n '/^handoff_server_names()/,/^}/p' '$LIB'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"server_name"* ]]
  [[ "$output" == *"HANDOFF_CONF_DIR"* ]]
  # The catch-all server_name "_" is not a hostname and must be filtered out.
  [[ "$output" == *'/^_$/d'* ]]
}
