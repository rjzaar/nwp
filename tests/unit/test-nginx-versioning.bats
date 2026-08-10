#!/usr/bin/env bats
# nwp/ops (slug nginx-versioning) — the forge box's nginx configuration is
# versioned for DR reproducibility, and the certbot renew deploy-hook that
# reloads GitLab's BUNDLED nginx exists (closing the silent cert-expiry gap
# documented in memory git-box-nginx-mechanism).
#
# ops#326 Phase 1 tranche 3 SPLIT THIS FILE'S SUBJECT IN TWO.
#
#   * The MECHANISM — renew-hook.sh and the deny-files-secrets snippet — is
#     generic product code, carries no instance identity, and stays in the
#     engine. It is asserted directly, as before.
#
#   * The CAPTURE — conf.d/*.conf, real hosts on a real box — is per-host
#     identity. It moved to the private per-server repo (servers/<host>/.git,
#     remote nwp/server-<host>), so it is NOT present in an engine checkout or
#     in CI. Asserting on its on-disk presence there would be a check that can
#     only ever be host-blind.
#
# So the capture-HYGIENE properties (every file is a real server block; no
# .bak/.backup was captured; no private-key material was captured) are asserted
# against a SHIPPED FIXTURE on every machine, and ADDITIONALLY against the real
# capture when a checkout has one — pointed at by $NWP_NGINX_CAPTURE_DIR, or
# found at its conventional path. That is the CLAUDE.md rule for an
# absent-resource branch: do not `|| return 0`, give the absent path a knob and
# keep the assertion running.
#
# The last case sabotages the hygiene predicate so it is proven capable of
# failing even when every real and fixture capture is clean.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  NGINX_DIR="${REPO_ROOT}/servers/nwpcode/nginx"
  HOOK="${NGINX_DIR}/renew-hook.sh"
  SNIPPET="${NGINX_DIR}/snippets/deny-files-secrets.conf"
  FIXTURE="${REPO_ROOT}/tests/fixtures/nginx-capture/conf.d"
  TMP="${BATS_TEST_TMPDIR}"
}

# _capture_dirs — every capture directory this machine can see: the shipped
# fixture always, plus the real capture when one is present.
_capture_dirs() {
  printf '%s\n' "$FIXTURE"
  local real="${NWP_NGINX_CAPTURE_DIR:-${NGINX_DIR}/conf.d}"
  [ -d "$real" ] && printf '%s\n' "$real"
  return 0
}

# _hygiene <dir> — the capture-hygiene predicate. Prints every violation;
# returns 1 if there were any, 2 if the directory holds no vhost at all.
_hygiene() {
  local dir="$1" bad=0 seen=0 f
  for f in "$dir"/*.conf; do
    [ -f "$f" ] || continue
    seen=$((seen + 1))
    grep -q 'server[[:space:]]*{' "$f" || { echo "NOT-A-SERVER-BLOCK: $f"; bad=1; }
  done
  [ "$seen" -gt 0 ] || { echo "EMPTY-CAPTURE: $dir"; return 2; }
  if ls "$dir" | grep -qE '\.(bak|backup)'; then
    echo "BACKUP-FILE-CAPTURED: $dir"; bad=1
  fi
  if grep -rqniE 'BEGIN [A-Z ]*PRIVATE KEY|password[[:space:]]*=|api[_-]?key[[:space:]]*=|secret[[:space:]]*=' "$dir"; then
    echo "SECRET-MATERIAL-CAPTURED: $dir"; bad=1
  fi
  return $bad
}

@test "the shipped capture fixture exists — the hygiene assertions are never vacuous" {
  [ -d "$FIXTURE" ]
  run bash -c "ls '${FIXTURE}'/*.conf | wc -l"
  [ "$output" -ge 1 ]
}

@test "every capture this machine can see passes capture hygiene" {
  local d rc=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    echo "checking: $d"
    run _hygiene "$d"
    echo "$output"
    [ "$status" -eq 0 ] || rc=1
  done < <(_capture_dirs)
  [ "$rc" -eq 0 ]
}

@test "the hygiene predicate CAN fail — a captured .bak, a non-server file and key material are all caught" {
  mkdir -p "${TMP}/dirty"
  printf 'server { server_name a.invalid; }\n' > "${TMP}/dirty/a.conf"
  printf 'server { server_name b.invalid; }\n' > "${TMP}/dirty/b.conf.bak"
  run _hygiene "${TMP}/dirty"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BACKUP-FILE-CAPTURED"* ]]

  mkdir -p "${TMP}/notserver"
  printf 'this is not nginx configuration\n' > "${TMP}/notserver/a.conf"
  run _hygiene "${TMP}/notserver"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOT-A-SERVER-BLOCK"* ]]

  mkdir -p "${TMP}/leaky"
  printf 'server { server_name c.invalid; }\n-----BEGIN RSA PRIVATE KEY-----\n' > "${TMP}/leaky/c.conf"
  run _hygiene "${TMP}/leaky"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SECRET-MATERIAL-CAPTURED"* ]]
}

@test "an EMPTY capture directory is reported, never silently green" {
  mkdir -p "${TMP}/empty"
  run _hygiene "${TMP}/empty"
  [ "$status" -eq 2 ]
  [[ "$output" == *"EMPTY-CAPTURE"* ]]
}

@test "the real per-host capture is NOT in the engine tree (ops#326)" {
  cd "$REPO_ROOT"
  run git ls-files 'servers/*/nginx/conf.d/*'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
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

@test "the deny-files-secrets snippet is shipped and refuses the credential shapes" {
  [ -s "$SNIPPET" ]
  grep -q 'yml' "$SNIPPET"
  grep -q 'auth.json' "$SNIPPET"
  grep -qE 'env' "$SNIPPET"
}
