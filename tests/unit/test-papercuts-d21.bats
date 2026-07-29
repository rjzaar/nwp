#!/usr/bin/env bats
# register D21 — two worktree-blindness papercuts:
#   ops#70  get_infra_secret returned empty for a >2-level nested key
#   ops#107 pl contracts targeted the shipping checkout, not the worktree cwd

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TEST_TMP"; }

# ---------------------------------------------------------------------------
# ops#70 — nested-key resolution in get_infra_secret / get_secret
# ---------------------------------------------------------------------------

@test "ops#70: a 3-level nested infra key resolves (was empty)" {
  export PROJECT_ROOT="$TEST_TMP"
  cat > "${TEST_TMP}/.secrets.yml" <<'EOF'
gitlab:
  api_token: two-level-value
  server:
    ip: 10.20.30.40
    domain: example.test
EOF
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/lib/common.sh"
  run get_infra_secret gitlab.server.ip MISSING
  [ "$status" -eq 0 ]
  [ "$output" = "10.20.30.40" ]
}

@test "ops#70: the ordinary 2-level key still resolves (no regression)" {
  export PROJECT_ROOT="$TEST_TMP"
  cat > "${TEST_TMP}/.secrets.yml" <<'EOF'
gitlab:
  api_token: two-level-value
EOF
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/lib/common.sh"
  run get_infra_secret gitlab.api_token MISSING
  [ "$output" = "two-level-value" ]
}

@test "ops#70: an absent key returns the default, not a stray value" {
  export PROJECT_ROOT="$TEST_TMP"
  printf 'gitlab:\n  api_token: x\n' > "${TEST_TMP}/.secrets.yml"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/lib/common.sh"
  run get_infra_secret gitlab.nope.deeper MISSING
  [ "$output" = "MISSING" ]
}

@test "ops#70: a key with a hyphen resolves (quoted-segment path)" {
  export PROJECT_ROOT="$TEST_TMP"
  cat > "${TEST_TMP}/.secrets.yml" <<'EOF'
cloudflare:
  api-token: cf-secret-value
EOF
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/lib/common.sh"
  run get_infra_secret 'cloudflare.api-token' MISSING
  [ "$output" = "cf-secret-value" ]
}

# ---------------------------------------------------------------------------
# ops#107 — contracts.sh resolves the INSPECTED tree from the cwd's git
# toplevel, not the checkout it ships in.
# ---------------------------------------------------------------------------

@test "ops#107: invoked inside a worktree, PROJECT_ROOT is that worktree" {
  # A fake worktree: a git repo with a contracts/ dir, distinct from REPO_ROOT.
  local wt="${TEST_TMP}/fake-wt"
  mkdir -p "$wt/contracts"
  git -C "$wt" init -q
  : > "$wt/contracts/SHA256SUMS"

  # Run the script's resolution with cwd inside the fake worktree, PROJECT_ROOT
  # unset. It must resolve to the fake worktree, not REPO_ROOT.
  run bash -c "cd '$wt' && unset PROJECT_ROOT && source '${REPO_ROOT}/scripts/commands/contracts.sh' 2>/dev/null; echo \"\$PROJECT_ROOT\""
  [ "$status" -eq 0 ]
  # last line of output is the resolved root
  [ "${lines[-1]}" = "$wt" ]
}

@test "ops#107: an explicit PROJECT_ROOT still wins (fixtures depend on it)" {
  local scratch="${TEST_TMP}/scratch"; mkdir -p "$scratch/contracts"
  run bash -c "cd / && export PROJECT_ROOT='$scratch'; source '${REPO_ROOT}/scripts/commands/contracts.sh' 2>/dev/null; echo \"\$PROJECT_ROOT\""
  [ "${lines[-1]}" = "$scratch" ]
}

@test "ops#107: outside any contracts-bearing tree, falls back to the shipping checkout" {
  run bash -c "cd '$TEST_TMP' && unset PROJECT_ROOT && source '${REPO_ROOT}/scripts/commands/contracts.sh' 2>/dev/null; echo \"\$PROJECT_ROOT\""
  [ "${lines[-1]}" = "$REPO_ROOT" ]
}
