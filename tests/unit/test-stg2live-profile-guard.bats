#!/usr/bin/env bats
# scripts/commands/stg2live.sh — the fail-closed PROFILE-CHANGE GUARD on the
# --code-only path (protects the primitive even when called directly, not just
# via `pl cutover`).
#
# A --code-only deploy does NOT push the DB, so the live DB keeps recording its
# existing install profile. If the staging build installs a DIFFERENT profile,
# --code-only cannot cross that change (e.g. nwc un-fork: live `nwc` → build
# `social`, Open Social under profiles/contrib/social/ → unbootable). On a
# canonical:live|prod site the guard REFUSES unless --allow-profile-change.
# See ~/central/UNFORK-PROFILE-INTENT-2026-07-19.md.
#
# Static assertions (grep/awk on the script), same style as
# test-stg2live-hardening.bats / test-stg2live-p0-safety.bats.

CMD="${BATS_TEST_DIRNAME}/../../scripts/commands/stg2live.sh"

@test "stg2live.sh parses with bash -n" {
  run bash -n "$CMD"
  [ "$status" -eq 0 ]
}

# ── the guard exists and reads both profiles ─────────────────────────────────

@test "a stg2live_profile_change_guard function exists" {
  run grep -E '^stg2live_profile_change_guard\(\) \{' "$CMD"
  [ "$status" -eq 0 ]
}

@test "the guard reads the TARGET profile OFFLINE from the build config-sync" {
  run bash -c "sed -n '/^read_build_profile() {/,/^}/p' '$CMD'"
  [[ "$output" == *"core.extension.yml"* ]]
  [[ "$output" == *"^profile:"* ]]
}

@test "the guard reads the LIVE profile read-only via drush cget core.extension profile" {
  run bash -c "sed -n '/^read_live_profile() {/,/^}/p' '$CMD'"
  [[ "$output" == *"cget core.extension profile"* ]]
}

# ── the refusal on a canonical:live profile mismatch ─────────────────────────

@test "the guard only enforces on canonical:live|prod (inert for dev targets)" {
  run bash -c "sed -n '/^stg2live_profile_change_guard() {/,/^}/p' '$CMD'"
  [[ "$output" == *"canonical_get_phase"* ]]
  [[ "$output" == *'phase" != "live"'* ]]
  [[ "$output" == *'phase" != "prod"'* ]]
}

@test "a profile mismatch REFUSES with a return 1 (fail-closed)" {
  # Inside the guard, `$live != $target` leads to a `return 1` refusal.
  run bash -c "sed -n '/^stg2live_profile_change_guard() {/,/^}/p' '$CMD' | awk '/\"\\\$live\" != \"\\\$target\"/{f=1} f&&/return 1/{print \"ok\"; exit}'"
  [ "$output" = "ok" ]
}

@test "the refusal points at Option 1 (site:install) and UNFORK-PROFILE-INTENT" {
  run bash -c "sed -n '/^stg2live_profile_change_guard() {/,/^}/p' '$CMD'"
  [[ "$output" == *"site:install"* ]]
  [[ "$output" == *"UNFORK-PROFILE-INTENT-2026-07-19.md"* ]]
}

@test "an unreadable live profile fails closed (return 1) too" {
  run bash -c "sed -n '/^stg2live_profile_change_guard() {/,/^}/p' '$CMD' | awk '/could not read the LIVE install profile/{f=1} f&&/return 1/{print \"ok\"; exit}'"
  [ "$output" = "ok" ]
}

# ── the --allow-profile-change override ──────────────────────────────────────

@test "--allow-profile-change is a parsed longopt" {
  grep -Eq 'allow-profile-change' "$CMD"
  run bash -c "grep -E -- '--allow-profile-change\) ALLOW_PROFILE_CHANGE=true' '$CMD'"
  [ "$status" -eq 0 ]
}

@test "--allow-profile-change overrides the refusal but WARNS it is almost certainly wrong" {
  run bash -c "sed -n '/^stg2live_profile_change_guard() {/,/^}/p' '$CMD'"
  [[ "$output" == *"ALLOW_PROFILE_CHANGE"* ]]
  [[ "$output" == *"almost certainly WRONG"* ]]
}

@test "ALLOW_PROFILE_CHANGE is exported so the guard function can read it" {
  run grep -E 'export .*ALLOW_PROFILE_CHANGE' "$CMD"
  [ "$status" -eq 0 ]
}

# ── dry-run safety ───────────────────────────────────────────────────────────

@test "a --dry-run prints the guard verdict but does NOT read the live profile" {
  # In the guard, the DRY_RUN branch returns BEFORE read_live_profile is called.
  body="$(sed -n '/^stg2live_profile_change_guard() {/,/^}/p' "$CMD")"
  dry_ln="$(printf '%s\n' "$body" | grep -n 'DRY_RUN.*==.*true'  | head -1 | cut -d: -f1)"
  live_ln="$(printf '%s\n' "$body" | grep -n 'read_live_profile' | head -1 | cut -d: -f1)"
  [ -n "$dry_ln" ] && [ -n "$live_ln" ]
  [ "$dry_ln" -lt "$live_ln" ]
  [[ "$body" == *"[dry-run] PROFILE-CHANGE GUARD"* ]]
}

# ── the guard is checked BEFORE the destructive deploy ───────────────────────

@test "the guard runs in main() BEFORE deploy_to_live, gated on --code-only" {
  body="$(awk '/^main\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$CMD")"
  g_ln="$(printf '%s\n' "$body" | grep -n 'stg2live_profile_change_guard' | head -1 | cut -d: -f1)"
  d_ln="$(printf '%s\n' "$body" | grep -n 'if deploy_to_live '            | head -1 | cut -d: -f1)"
  [ -n "$g_ln" ] && [ -n "$d_ln" ]
  [ "$g_ln" -lt "$d_ln" ]
  # gated on CODE_ONLY
  printf '%s\n' "$body" | grep -B2 'stg2live_profile_change_guard' | grep -q 'CODE_ONLY.*==.*true'
}
