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
