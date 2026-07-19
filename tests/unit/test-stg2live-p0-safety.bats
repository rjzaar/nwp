#!/usr/bin/env bats
# P0 cutover-safety hardening of the stg2live destructive deploy path
# (PL-STG2LIVE-INTEGRATION-DESIGN-2026-07-19.md + PHASED-BUILD-PLAN Phase-0 items 3/4/7):
#   F5   — hash_salt is PERSISTENT live state: reuse → mint-once → abort,
#          never `openssl rand` a fresh salt on a canonical:live site (INV-10).
#   P2-2 — `--push-content` opt-in: refuse full_database_deployment against a
#          canonical:live|prod site unless explicitly opted in (INV-1).
#   G3   — maintenance mode ON before the destructive rsync --delete, OFF only
#          after the post-sync updatedb/cr sequence; both skipped on --dry-run.
# Static assertions (grep/awk on the script), same style as
# test-stg2live-hardening.bats / test-stg2live-excludes.bats.

CMD="${BATS_TEST_DIRNAME}/../../scripts/commands/stg2live.sh"

# ---------------------------------------------------------------------------
# F5 — hash_salt persistence (reuse → mint-once → abort)
# ---------------------------------------------------------------------------

@test "F5: a resolve_live_hash_salt helper exists" {
  run grep -E '^resolve_live_hash_salt\(\) \{' "$CMD"
  [ "$status" -eq 0 ]
}

@test "F5: resolve reuses an existing salt read off live (reuse state)" {
  run bash -c "sed -n '/^resolve_live_hash_salt() {/,/^}/p' '$CMD'"
  [[ "$output" == *"Reusing persisted hash_salt"* ]]
  # It extracts the persisted \$settings['hash_salt'] value.
  [[ "$output" == *"hash_salt'"* ]]
  [[ "$output" == *'printf'* ]]
}

@test "F5: resolve aborts (return 1) on a canonical:live|prod site with no reusable salt" {
  run bash -c "sed -n '/^resolve_live_hash_salt() {/,/^}/p' '$CMD' | awk '/phase.*==.*\"live\"/{f=1} f&&/return 1/{print \"ok\"; exit}'"
  [ "$output" = "ok" ]
}

@test "F5: resolve aborts under --code-only when no salt is reusable" {
  run bash -c "sed -n '/^resolve_live_hash_salt() {/,/^}/p' '$CMD' | grep -E 'CODE_ONLY.*true'"
  [ "$status" -eq 0 ]
}

@test "F5: mint (openssl rand) is the LAST branch — after reuse and both abort guards" {
  # reuse (printf existing) → abort (return 1) → mint (openssl rand), in order.
  run bash -c "sed -n '/^resolve_live_hash_salt() {/,/^}/p' '$CMD' | awk '/printf .*existing/{r=NR} /return 1/{a=NR} /openssl rand/{m=NR} END{print (r && a && m && r<a && a<m) ? \"ok\" : \"bad\"}'"
  [ "$output" = "ok" ]
}

@test "F5: generate_live_settings mints NO salt inline (uses the resolved value)" {
  # No bare `openssl rand` anywhere on the live-settings generation path
  # (from the function header through the settings heredoc EOF).
  run bash -c "awk '/^generate_live_settings\(\) \{/{f=1} f{print} f&&/^EOF\$/{exit}' '$CMD' | grep -c 'openssl rand'"
  [ "$output" = "0" ]
}

@test "F5: the live hash_salt line uses the resolved \${hash_salt} variable" {
  run grep -F '${hash_salt}' "$CMD"
  [ "$status" -eq 0 ]
}

@test "F5: generate_live_settings aborts if the salt cannot be resolved" {
  run bash -c "sed -n '/^generate_live_settings() {/,/^EOF\$/p' '$CMD' | awk '/resolve_live_hash_salt/{f=1} f&&/return 1/{print \"ok\"; exit}'"
  [ "$output" = "ok" ]
}

# ---------------------------------------------------------------------------
# P2-2 — --push-content opt-in guard (INV-1)
# ---------------------------------------------------------------------------

@test "P2-2: --push-content flag is parsed" {
  run grep -E '\-\-push-content\) PUSH_CONTENT=true' "$CMD"
  [ "$status" -eq 0 ]
}

@test "P2-2: --push-content is declared in longopts" {
  run grep -E 'LONGOPTS=.*push-content' "$CMD"
  [ "$status" -eq 0 ]
}

@test "P2-2: PUSH_CONTENT is exported to the deploy function" {
  run grep -E 'export .*PUSH_CONTENT' "$CMD"
  [ "$status" -eq 0 ]
}

@test "P2-2: the DB push is refused on canonical:live before full_database_deployment" {
  # phase read → PUSH_CONTENT != true → return 1, all BEFORE the
  # `if ! full_database_deployment` call.
  run bash -c "awk '/_phase=.*canonical_get_phase/{f=1} f&&/PUSH_CONTENT.*!=.*true/{p=NR} f&&/return 1/{r=NR} f&&/if ! full_database_deployment/{fd=NR; exit} END{print (p && r && fd && p<r && r<fd) ? \"ok\" : \"bad\"}' '$CMD'"
  [ "$output" = "ok" ]
}

@test "P2-2: the guard keys on canonical:live|prod phase" {
  run bash -c "awk '/_phase=.*canonical_get_phase/{f=1} f&&/_phase.*==.*\"live\"/{print \"ok\"; exit}' '$CMD'"
  [ "$output" = "ok" ]
}

@test "P2-2: --code-only path still skips the DB push (unchanged)" {
  run grep -F '[code-only] skipping database push' "$CMD"
  [ "$status" -eq 0 ]
}

@test "P2-2: the !119 abort-on-failed-import is preserved" {
  run bash -c "awk '/if ! full_database_deployment/{f=1} f&&/return 1/{print \"ok\"; exit}' '$CMD'"
  [ "$output" = "ok" ]
}

# ---------------------------------------------------------------------------
# G3 — maintenance-mode hoist (before the --delete rsync, after updatedb/cr)
# ---------------------------------------------------------------------------

@test "G3: a live_maintenance_set helper exists using state:set --input-format=integer" {
  run bash -c "sed -n '/^live_maintenance_set() {/,/^}/p' '$CMD' | grep -E 'drush state:set system.maintenance_mode .* --input-format=integer'"
  [ "$status" -eq 0 ]
}

@test "G3: maintenance is enabled BEFORE the destructive rsync --delete" {
  run bash -c "awk '/live_maintenance_set .* 1\$/{on=NR} /rsync -e .*--delete/{d=NR} END{print (on && d && on<d) ? \"ok\" : \"bad\"}' '$CMD'"
  [ "$output" = "ok" ]
}

@test "G3: maintenance is disabled AFTER the post-sync updatedb sequence" {
  run bash -c "awk '/run_live_db_updates /{u=NR} /live_maintenance_set .* 0\$/{off=NR} END{print (u && off && u<off) ? \"ok\" : \"bad\"}' '$CMD'"
  [ "$output" = "ok" ]
}

@test "G3: the maintenance ENABLE call is dry-run guarded" {
  run bash -c "grep -B3 'live_maintenance_set .* 1\$' '$CMD' | grep -E 'DRY_RUN:-false.*!=.*true'"
  [ "$status" -eq 0 ]
}

@test "G3: the maintenance DISABLE call is dry-run guarded" {
  run bash -c "grep -B3 'live_maintenance_set .* 0\$' '$CMD' | grep -E 'DRY_RUN:-false.*!=.*true'"
  [ "$status" -eq 0 ]
}

@test "G3: an abort after maintenance-ON points at rollback / leaves maintenance ON" {
  run bash -c "grep -F 'maintenance mode left ON' '$CMD'"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# sanity
# ---------------------------------------------------------------------------

@test "stg2live.sh parses with bash -n" {
  run bash -n "$CMD"
  [ "$status" -eq 0 ]
}
