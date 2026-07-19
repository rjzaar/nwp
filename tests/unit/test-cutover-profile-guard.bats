#!/usr/bin/env bats
# scripts/commands/cutover.sh — the fail-closed PROFILE-CHANGE GUARD.
#
# The nwc un-fork is a Drupal INSTALL-PROFILE change (live `nwc` → build
# `social`). `pl stg2live nwc --code-only` (cutover step 4) CANNOT cross a
# profile change, so the orchestrator must ABORT — before wasting a live dump
# (--rehearse) and before any live contact (--execute) — whenever the live
# profile differs from the target build's profile. See
# ~/central/UNFORK-PROFILE-INTENT-2026-07-19.md.
#
# Behavioural cases use a mock `pl` (PL_BIN) + a fixture command dir
# (CUTOVER_CMD_DIR); nothing touches a real site. Static cases grep the source.

CUTOVER="${BATS_TEST_DIRNAME}/../../scripts/commands/cutover.sh"

setup() {
  TEST_TMP=$(mktemp -d)
  export PROJECT_ROOT="${TEST_TMP}/proj"
  mkdir -p "${PROJECT_ROOT}/sites/nwc/dev" \
           "${PROJECT_ROOT}/sites/nwc/stg" \
           "${PROJECT_ROOT}/sites/nwc/backups"

  # TARGET build profile = social (the un-forked build).
  mkdir -p "${PROJECT_ROOT}/sites/nwc/stg/html/sites/default/files/sync"
  printf 'profile: social\n' \
    > "${PROJECT_ROOT}/sites/nwc/stg/html/sites/default/files/sync/core.extension.yml"

  mkdir -p "${TEST_TMP}/bin"
  cat > "${TEST_TMP}/bin/ddev" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "${TEST_TMP}/bin/ddev"
  export PATH="${TEST_TMP}/bin:${PATH}"

  export CUTOVER_CMD_DIR="${TEST_TMP}/cmd"
  mkdir -p "${CUTOVER_CMD_DIR}"
  echo '--remote'     > "${CUTOVER_CMD_DIR}/backup.sh"
  printf 'inject)\n'  > "${CUTOVER_CMD_DIR}/secrets.sh"
  printf 'verify\n'   > "${CUTOVER_CMD_DIR}/link.sh"
  echo 'drush'        > "${CUTOVER_CMD_DIR}/drush.sh"
  echo '--code-only'  > "${CUTOVER_CMD_DIR}/stg2live.sh"
  printf 'execute)\n' > "${CUTOVER_CMD_DIR}/rollback.sh"

  # Mock pl: record calls; LIVE profile read from the imported DB reports `nwc`
  # (the OLD hard-fork) → a MISMATCH against the `social` target build.
  export PL_CALLS="${TEST_TMP}/calls"
  : > "${PL_CALLS}"
  export PL_BIN="${TEST_TMP}/pl"
  cat > "${PL_BIN}" <<'EOF'
#!/bin/bash
echo "$*" >> "$PL_CALLS"
if [[ "$*" == *"cget core.extension profile"* && "$*" == *"--tier=stg"* ]]; then printf "'core.extension:profile': nwc\n"; fi
if [[ "$*" == *"backup --remote"* && "$*" == *"--db-only"* ]]; then
  mkdir -p "${PROJECT_ROOT}/sites/nwc/backups"
  printf 'live-db-dump\n' | gzip > "${PROJECT_ROOT}/sites/nwc/backups/nwc-remote-$(date +%Y%m%dT%H%M%S).sql.gz"
fi
exit 0
EOF
  chmod +x "${PL_BIN}"
}

teardown() { rm -rf "${TEST_TMP}"; }

# ── --rehearse: mismatch aborts (records failed, blocks execute) ─────────────

@test "rehearse ABORTS on an install-profile change and records failed" {
  run bash "$CUTOVER" nwc --rehearse
  [ "$status" -ne 0 ]
  [[ "$output" == *"PROFILE-CHANGE GUARD"* ]]
  [[ "$output" == *"install-profile change"* || "$output" == *"nwc"*"social"* ]]
  # the rehearsal is recorded FAILED so --execute stays blocked…
  grep -q '^status=failed$' "${PROJECT_ROOT}/private/cutover/nwc.rehearse"
  # …the observed live profile is recorded (nwc)…
  [ "$(cat "${PROJECT_ROOT}/private/cutover/nwc.liveprofile")" = "nwc" ]
  # …and the pointless scratch updatedb is NEVER reached (aborted before it).
  ! grep -q -- 'updatedb -y' "${PL_CALLS}"
}

@test "rehearse mismatch points at UNFORK-PROFILE-INTENT and Option 1" {
  run bash "$CUTOVER" nwc --rehearse
  [[ "$output" == *"UNFORK-PROFILE-INTENT-2026-07-19.md"* ]]
  [[ "$output" == *"site:install social"* ]]
}

# ── --execute: OFFLINE refusal before any live contact ───────────────────────

@test "execute ABORTS offline when the recorded live profile != target (no pl call)" {
  mkdir -p "${PROJECT_ROOT}/private/cutover"
  printf 'status=passed\n' > "${PROJECT_ROOT}/private/cutover/nwc.rehearse"
  printf 'nwc\n'           > "${PROJECT_ROOT}/private/cutover/nwc.liveprofile"
  run bash "$CUTOVER" nwc --execute -y
  [ "$status" -ne 0 ]
  [[ "$output" == *"PROFILE-CHANGE GUARD"* ]]
  [[ "$output" == *"cannot be crossed by --code-only"* ]]
  # fail-closed BEFORE any step — no sibling pl verb ran, no lock stamped
  [ ! -s "${PL_CALLS}" ]
  [ ! -f "${PROJECT_ROOT}/private/cutover/nwc.done" ]
}

@test "execute fails closed when a passed rehearsal recorded NO live profile" {
  mkdir -p "${PROJECT_ROOT}/private/cutover"
  printf 'status=passed\n' > "${PROJECT_ROOT}/private/cutover/nwc.rehearse"
  run bash "$CUTOVER" nwc --execute -y
  [ "$status" -ne 0 ]
  [[ "$output" == *"no recorded LIVE install profile"* ]]
  [ ! -s "${PL_CALLS}" ]
}

# ── target-profile unreadable → fail-closed ──────────────────────────────────

@test "rehearse fails closed when the TARGET profile cannot be read" {
  rm -f "${PROJECT_ROOT}/sites/nwc/stg/html/sites/default/files/sync/core.extension.yml"
  run bash "$CUTOVER" nwc --rehearse
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot read the TARGET install profile"* ]]
  [ ! -s "${PL_CALLS}" ]
}

# ── static assertions on the source ──────────────────────────────────────────

@test "cutover.sh carries the ⚠ step-4 --code-only banner citing UNFORK-PROFILE-INTENT" {
  run grep -n 'PROFILE-CHANGE GUARD' "$CUTOVER"
  [ "$status" -eq 0 ]
  grep -q 'INVALID for the nwc' "$CUTOVER"
  grep -q 'stg2live nwc --code-only' "$CUTOVER"
  grep -q 'UNFORK-PROFILE-INTENT-2026-07-19.md' "$CUTOVER"
}

@test "the preflight guard compares live vs target and aborts on mismatch" {
  # preflight_profile_guard reads the target, compares a recorded live profile,
  # and aborts on inequality.
  run bash -c "awk '/^preflight_profile_guard\(\)/{f=1} f{print} f&&/^}/{exit}' '$CUTOVER'"
  [[ "$output" == *"read_target_profile"* ]]
  [[ "$output" == *'"$live" != "$target"'* ]]
  [[ "$output" == *"profile_change_abort"* ]]
}

@test "the offline guard runs in --execute BEFORE the IMPACT confirm / step 1" {
  # In do_execute, preflight_profile_guard precedes render_impact_and_confirm.
  body="$(awk '/^do_execute\(\)/{f=1} f{print} f&&/^}/{exit}' "$CUTOVER")"
  g_ln="$(printf '%s\n' "$body" | grep -n 'preflight_profile_guard'     | head -1 | cut -d: -f1)"
  i_ln="$(printf '%s\n' "$body" | grep -n 'render_impact_and_confirm'   | head -1 | cut -d: -f1)"
  [ -n "$g_ln" ] && [ -n "$i_ln" ]
  [ "$g_ln" -lt "$i_ln" ]
}

@test "the in-rehearsal profile check runs AFTER import but BEFORE updatedb" {
  body="$(awk '/^run_rehearsal\(\)/{f=1} f{print} f&&/^}/{exit}' "$CUTOVER")"
  imp_ln="$(printf '%s\n' "$body" | grep -n 'import-db'                 | head -1 | cut -d: -f1)"
  chk_ln="$(printf '%s\n' "$body" | grep -n 'read_stg_live_profile'     | head -1 | cut -d: -f1)"
  upd_ln="$(printf '%s\n' "$body" | grep -n 'updatedb -y'               | head -1 | cut -d: -f1)"
  [ -n "$imp_ln" ] && [ -n "$chk_ln" ] && [ -n "$upd_ln" ]
  [ "$imp_ln" -lt "$chk_ln" ]
  [ "$chk_ln" -lt "$upd_ln" ]
}

@test "cutover.sh parses with bash -n" {
  run bash -n "$CUTOVER"
  [ "$status" -eq 0 ]
}
