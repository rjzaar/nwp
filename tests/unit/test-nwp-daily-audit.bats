#!/usr/bin/env bats
# ops auto — nwp-daily-audit.sh smoke test.
# The daily audit script was pulled into version control from met's
# ~/bin/nwp-daily-audit (met was down at extraction; documented reconstruction).
# These are pure static checks: syntax + that it does what its name claims and
# carries no hardcoded secret.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/nwp-daily-audit.sh"

@test "nwp-daily-audit.sh has valid bash syntax" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "nwp-daily-audit.sh is strict (set -euo pipefail)" {
  grep -Eq '^set -euo pipefail' "$SCRIPT"
}

@test "runs composer audit and composer outdated" {
  grep -Eq 'composer[^\n]*audit' "$SCRIPT"
  grep -Eq 'composer[^\n]*outdated' "$SCRIPT"
}

@test "tracks upstream drift" {
  grep -q 'fetch_upstream_composer' "$SCRIPT"
  grep -q 'UPSTREAM' "$SCRIPT"
}

@test "posts to the ops log queue only on state change" {
  # role-label default project (real one injected via NWP_OPS_LOG_PROJECT)
  grep -q 'NWP_OPS_LOG_PROJECT' "$SCRIPT"
  # baseline diff gate: only posts when the fingerprint differs
  grep -Eq 'baseline' "$SCRIPT"
  grep -q 'daily-audit:' "$SCRIPT"
}

@test "GitLab host/project defaults are placeholders, not a real host" {
  # must not hardcode a real internal domain; env-injected instead
  grep -q 'NWP_GITLAB_HOST' "$SCRIPT"
  run grep -Eq 'nwpcode\.org' "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "no hardcoded secret — token read from a 0600 file, not inline" {
  # token comes from a file path, never a glpat- literal in the source
  grep -q 'AUDIT_TOKEN_FILE' "$SCRIPT"
  run grep -Eq 'glpat-[A-Za-z0-9]' "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "has a SITES array and a parameterised override" {
  grep -Eq 'SITES=\(' "$SCRIPT"
  grep -q 'NWP_AUDIT_SITES' "$SCRIPT"
}

@test "documents the 02:30 UTC pl-schedule wiring" {
  grep -Eq '30 2 \* \* \*' "$SCRIPT"
  grep -q 'pl schedule' "$SCRIPT"
}

@test "token is passed via a 0600 curl config, never on curl argv" {
  # Drive the script end-to-end with a stubbed composer (changed state => it
  # tries to POST) and a stubbed curl that records its argv. The sentinel token
  # must NEVER appear on the recorded curl command line (would leak via
  # /proc/<pid>/cmdline); it may only reach curl through the -K config file.
  local work stub site
  work="$(mktemp -d)"
  stub="$work/bin"
  site="$work/site"
  mkdir -p "$stub" "$site"
  echo '{"require":{}}' > "$site/composer.json"

  # Stubbed composer: emit findings so the fingerprint differs from the empty
  # baseline and post_issue() is reached.
  cat > "$stub/composer" <<'EOF'
#!/bin/bash
case "$1" in
  audit)    echo '{"advisories":{"drupal/core":[{"advisoryId":"SA-TEST-1","title":"t"}]}}' ;;
  outdated) echo '{"installed":[{"name":"drupal/core","version":"10.0.0","latest":"10.1.0"}]}' ;;
esac
EOF
  chmod +x "$stub/composer"

  # Stubbed curl: append every argv token (one per line) to the capture file.
  cat > "$stub/curl" <<'EOF'
#!/bin/bash
for a in "$@"; do printf '%s\n' "$a" >> "$CURL_ARGV_CAPTURE"; done
exit 0
EOF
  chmod +x "$stub/curl"

  printf '%s\n' 'SENTINELTOKEN123' > "$work/token"
  chmod 600 "$work/token"

  export CURL_ARGV_CAPTURE="$work/argv.txt"
  : > "$CURL_ARGV_CAPTURE"

  run env PATH="$stub:$PATH" \
    NWP_AUDIT_TOKEN_FILE="$work/token" \
    NWP_AUDIT_SITES="testsite:$site:" \
    NWP_AUDIT_CACHE_DIR="$work/cache" \
    NWP_AUDIT_LOG="$work/audit.log" \
    NWP_GITLAB_HOST="gitlab.example" \
    NWP_OPS_LOG_PROJECT="ops/verifier-log" \
    bash "$SCRIPT"

  [ "$status" -eq 0 ]
  # curl must actually have been invoked (test is meaningful) ...
  grep -q -- '-K' "$CURL_ARGV_CAPTURE"
  # ... and the token must NOT be anywhere on its argv.
  run grep -q 'SENTINELTOKEN123' "$CURL_ARGV_CAPTURE"
  [ "$status" -ne 0 ]

  rm -rf "$work"
}

@test "upstream-drift docs make no false 'main' source claim" {
  # The compare uses Packagist p2 (latest RELEASED version), NOT the upstream
  # dev-main branch. Guard against a comment reintroducing the old false claim
  # that it tracks Open Social `main`, and require the honest source (Packagist).
  run grep -Eiq 'open ?social[^\n]*\bmain\b' "$SCRIPT"
  [ "$status" -ne 0 ]
  grep -q 'Packagist' "$SCRIPT"
}
