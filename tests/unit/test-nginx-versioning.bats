#!/usr/bin/env bats
# nwp/ops (slug nginx-versioning) — the git.nwpcode.org nginx vhosts are
# versioned for DR reproducibility, and the certbot renew deploy-hook that
# reloads GitLab's BUNDLED nginx exists (closing the silent cert-expiry gap
# documented in memory git-box-nginx-mechanism).
#
# These files live under servers/ which is gitignored in the public tool repo,
# so the test asserts on their ON-DISK presence (they were added with -f on the
# branch). The test is the mechanical guard that the DR capture + hook are real.

NGINX_DIR="${BATS_TEST_DIRNAME}/../../servers/nwpcode/nginx"
CONF_DIR="${NGINX_DIR}/conf.d"
HOOK="${NGINX_DIR}/renew-hook.sh"
README="${NGINX_DIR}/README.md"

@test "captured vhost directory exists" {
  [ -d "$CONF_DIR" ]
}

@test "at least the core site vhosts were captured" {
  # A representative sample that must be present after a real capture.
  for f in ss ssc nwc avc dir pray.rosaryforge; do
    [ -s "${CONF_DIR}/${f}.conf" ]
  done
}

@test "only ACTIVE vhosts captured — no .bak/.backup files committed" {
  run bash -c "ls '${CONF_DIR}' | grep -E '\\.(bak|backup)' || true"
  [ -z "$output" ]
}

@test "every captured vhost is a real nginx server block" {
  for f in "${CONF_DIR}"/*.conf; do
    grep -q 'server {' "$f"
  done
}

@test "captured vhosts contain no obvious secrets" {
  # Cert PATHS are fine; private-key MATERIAL / passwords / tokens are not.
  run grep -rniE 'BEGIN [A-Z ]*PRIVATE KEY|password[[:space:]]*=|api[_-]?key[[:space:]]*=|secret[[:space:]]*=' "$CONF_DIR"
  [ "$status" -ne 0 ]
}

@test "renew-hook.sh exists and is executable" {
  [ -f "$HOOK" ]
  [ -x "$HOOK" ]
}

@test "renew-hook.sh has valid bash syntax" {
  run bash -n "$HOOK"
  [ "$status" -eq 0 ]
}

@test "renew-hook.sh reloads the GitLab-bundled nginx (gitlab-ctl hup nginx)" {
  grep -q 'gitlab-ctl hup nginx' "$HOOK"
}

@test "renew-hook.sh does NOT use system nginx reload (would no-op on this box)" {
  # Ignore comment lines — the doc-comment mentions it only to warn against it.
  run bash -c "grep -vE '^[[:space:]]*#' '$HOOK' | grep -qE 'systemctl (reload|restart) nginx'"
  [ "$status" -ne 0 ]
}

@test "renew-hook.sh fails closed if gitlab-ctl is missing" {
  # Must abort loudly (exit 1), not silently pass, when it cannot reload.
  grep -Eq 'command -v gitlab-ctl' "$HOOK"
  grep -Eq 'exit 1' "$HOOK"
}

@test "README documents install path and the reload command" {
  [ -s "$README" ]
  grep -q 'renewal-hooks/deploy' "$README"
  grep -q 'gitlab-ctl hup nginx' "$README"
}
