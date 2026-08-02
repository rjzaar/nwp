#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# A FLEET THAT IS UNIFORMLY STALE IS NOT A FLEET THAT AGREES  (nwp/ops#259)
#
# `pl moodle plugin drift` compared $plugin->version across the dev tree, the
# plugin cache and LIVE — against EACH OTHER, and nothing else. That question
# has a true-and-useless answer whenever every copy is equally out of date.
#
# Measured on 2026-08-03, before this change:
#
#   local/feedback
#     sites/ssd/dev                          2026051704
#     sites/ssd/.plugin-src/ss-moodle-plugins 2026051704
#     LIVE /var/www/ssd/local/feedback       2026051704
#   [OK] every compared copy agrees on $plugin->version.
#
# …while nwp/ss-moodle-plugins origin/main was at 2026080101 — the commit range
# (1bbd2d7 ops#93, a5d515d ops#166) that added local/feedback/classes/privacy/
# provider.php. So on the live Moodle sites a table carrying userid, username,
# email, user_agent, ipaddress and the submission body had NO handler in
# Moodle's privacy/erasure API, and the verb whose entire job is deployment
# sameness reported OK.
#
# Same failure shape as the backup-capability blindness fixed the day before:
# the verb answered a narrower question than the one the operator was asking,
# and the narrow answer was green.
#
# These cases pin the three states, and the closing verdict must never claim a
# comparison it did not make.
# ─────────────────────────────────────────────────────────────────────────────

setup() {
  TEST_TMP=$(mktemp -d)
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  MOODLE="${REPO_ROOT}/scripts/commands/moodle.sh"

  # Throwaway site fixture. No ssh, no ddev, no network: --no-live everywhere.
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}/sites/ssd/dev"
  cat > "${PROJECT_ROOT}/sites/ssd/.nwp.yml" <<'EOF'
schema_version: 2
project:
  name: ssd
  type: moodle
live:
  enabled: true
  domain: ssd.example.org
  server_ip: 203.0.113.11
  ssh_user: gitlab
  remote_path: /var/www/ssd
moodle:
  cli_php_version: "8.2"
  plugins:
    - path: local/feedback
EOF

  # A canonical repo: a real git repo whose origin/main carries version 2026080101.
  CANON="${TEST_TMP}/canonical"
  mkdir -p "${CANON}/local/feedback"
  git -C "${CANON}" init -q -b main
  git -C "${CANON}" config user.email t@example.com
  git -C "${CANON}" config user.name t
  echo '<?php $plugin->version = 2026080101;' > "${CANON}/local/feedback/version.php"
  git -C "${CANON}" add -A
  git -C "${CANON}" commit -qm canonical
  # origin/main must exist as a REF, because the cache checkout is routinely
  # sitting on some feature branch — its worktree is not the canonical answer.
  git -C "${CANON}" update-ref refs/remotes/origin/main refs/heads/main

  # Two deployed copies that agree with each other and are BEHIND canonical.
  for d in a b; do
    mkdir -p "${TEST_TMP}/${d}/local/feedback"
    echo '<?php $plugin->version = 2026051704;' > "${TEST_TMP}/${d}/local/feedback/version.php"
  done
}

teardown() { rm -rf "$TEST_TMP"; }

_drift() {
  NWP_MOODLE_CANONICAL_REPO="$1" NWP_MOODLE_CANONICAL_REF=main \
    bash "$MOODLE" plugin drift ssd local/feedback \
      --tree="${TEST_TMP}/a" --tree="${TEST_TMP}/b" --no-live
}

@test "canon1: copies that agree with each other but are BEHIND canonical go RED" {
  run _drift "${CANON}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"BEHIND-CANONICAL"* ]]
  [[ "$output" == *"2026080101"* ]]
}

@test "canon2: the OLD verdict is no longer reachable for a stale-but-consistent fleet" {
  # Mutation guard on the bug itself: the exact sentence that made the ssd
  # blindness look fine must not be printed when canonical is newer. Without
  # this, a future refactor could re-introduce the green line beside the error.
  run _drift "${CANON}"
  [[ "$output" != *"every compared copy agrees on \$plugin->version."* ]]
}

@test "canon3: copies that match canonical are GREEN and the verdict says canonical was compared" {
  echo '<?php $plugin->version = 2026080101;' > "${TEST_TMP}/a/local/feedback/version.php"
  echo '<?php $plugin->version = 2026080101;' > "${TEST_TMP}/b/local/feedback/version.php"
  run _drift "${CANON}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"matches main"* ]]
  [[ "$output" != *"CANONICAL WAS NOT COMPARED"* ]]
}

@test "canon4: an unreadable canonical is CANONICAL-UNKNOWN, never silent agreement" {
  # "I could not look" is never "it is fine". The run still exits 0 — the copies
  # really do agree — but the verdict must admit the comparison did not happen,
  # or this is the vacuous pass the check exists to remove.
  run _drift "${TEST_TMP}/not-a-repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CANONICAL-UNKNOWN"* ]]
  [[ "$output" == *"CANONICAL WAS NOT COMPARED"* ]]
}

@test "canon5: a repo that exists but has no such ref is also CANONICAL-UNKNOWN" {
  run env NWP_MOODLE_CANONICAL_REPO="${CANON}" NWP_MOODLE_CANONICAL_REF=origin/nope \
      bash "$MOODLE" plugin drift ssd local/feedback \
        --tree="${TEST_TMP}/a" --tree="${TEST_TMP}/b" --no-live
  [ "$status" -eq 0 ]
  [[ "$output" == *"CANONICAL-UNKNOWN"* ]]
}

@test "canon6: --no-canonical opts out, and says the comparison was not made" {
  run env NWP_MOODLE_CANONICAL_REPO="${CANON}" NWP_MOODLE_CANONICAL_REF=main \
      bash "$MOODLE" plugin drift ssd local/feedback \
        --tree="${TEST_TMP}/a" --tree="${TEST_TMP}/b" --no-live --no-canonical
  [ "$status" -eq 0 ]
  [[ "$output" == *"CANONICAL WAS NOT COMPARED"* ]]
  [[ "$output" != *"BEHIND-CANONICAL"* ]]
}

@test "canon7: a copy AHEAD of canonical warns but does not fail" {
  # An unmerged REVIEW branch legitimately runs ahead on dev, so this must not
  # be an error — but code on a box that canonical has never seen is code no
  # review gate has seen, so it must not be silent either.
  echo '<?php $plugin->version = 2026090909;' > "${TEST_TMP}/a/local/feedback/version.php"
  echo '<?php $plugin->version = 2026090909;' > "${TEST_TMP}/b/local/feedback/version.php"
  run _drift "${CANON}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AHEAD-OF-CANONICAL"* ]]
}

@test "canon8: the canonical version is read from the REF, not from the working tree" {
  # The plugin cache is a live checkout; on 2026-08-03 ssd's was sitting on
  # feat/ops118-consumer-set-consent-ws. If this read the worktree instead of
  # origin/main, the 'canonical' answer would be whatever branch someone left
  # checked out — a moving target dressed up as a fixed point.
  echo '<?php $plugin->version = 1999010101;' > "${CANON}/local/feedback/version.php"
  run _drift "${CANON}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"2026080101"* ]]
  [[ "$output" != *"1999010101"* ]]
}
