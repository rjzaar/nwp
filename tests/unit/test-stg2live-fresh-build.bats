#!/usr/bin/env bats
# scripts/commands/stg2live.sh — the --fresh-build PLAN (nwc un-fork go-live).
#
# --fresh-build prints the fresh-install-alongside + flip plan (side docroot +
# fresh DB + install sequence via `pl drush --root`) and, for now, fail-closes on
# a real run: the live-mutation path must be built + rehearsed attended first
# (cutover design step 3). Static assertions (grep/sed/awk), same style as
# test-stg2live-profile-guard.bats / -hardening.bats / -p0-safety.bats.

CMD="${BATS_TEST_DIRNAME}/../../scripts/commands/stg2live.sh"

@test "stg2live.sh parses with bash -n" {
  run bash -n "$CMD"
  [ "$status" -eq 0 ]
}

# ── the flag is wired ────────────────────────────────────────────────────────

@test "--fresh-build is a registered long option" {
  run grep -E 'LONGOPTS=.*fresh-build' "$CMD"
  [ "$status" -eq 0 ]
}

@test "the --fresh-build case sets FRESH_BUILD=true" {
  run grep -E -- '--fresh-build\) FRESH_BUILD=true' "$CMD"
  [ "$status" -eq 0 ]
}

@test "--fresh-build and --code-only are mutually exclusive" {
  run grep -E 'mutually exclusive' "$CMD"
  [ "$status" -eq 0 ]
}

# ── the plan function exists and is READ-ONLY (no live mutation) ──────────────

@test "a fresh_build_plan function exists" {
  run grep -E '^fresh_build_plan\(\) \{' "$CMD"
  [ "$status" -eq 0 ]
}

@test "fresh_build_plan performs no destructive ops (prose may name them; nothing is executed)" {
  # The plan names rsync / flip etc. in prose inside a cat heredoc, but must
  # never INVOKE them. An executed line begins (after indentation) with the
  # command verb; a prose line begins with a label. Assert no line starts with a
  # mutation verb.
  body="$(sed -n '/^fresh_build_plan() {/,/^}/p' "$CMD")"
  run grep -nE '^[[:space:]]*(rsync|mysql|ssh|ln|drush|composer)[[:space:]]' <<< "$body"
  [ "$status" -ne 0 ]   # no such line ⇒ grep finds nothing ⇒ non-zero
  [[ "$body" == *"cat <<EOF"* ]]
}

@test "the plan describes the side docroot, fresh DB and the pl drush --root sequence" {
  body="$(sed -n '/^fresh_build_plan() {/,/^}/p' "$CMD")"
  [[ "$body" == *"side_docroot"* ]]
  [[ "$body" == *"side_db"* ]]
  [[ "$body" == *"--root="* ]]
  [[ "$body" == *"nwc:config-heal"* ]]
  [[ "$body" == *"nwc-copyright:sync"* ]]
  [[ "$body" == *"mail guard"* ]]
}

# ── the execute path fail-closes (no untested live mutation) ──────────────────

@test "--fresh-build without --dry-run refuses to run and exits non-zero" {
  block="$(sed -n '/if \[ "\$FRESH_BUILD" = "true" \]; then/,/^    fi/p' "$CMD")"
  [[ "$block" == *"not yet wired"* ]]
  [[ "$block" == *"exit 2"* ]]
}

@test "--fresh-build --dry-run exits 0 after printing the plan" {
  block="$(sed -n '/if \[ "\$FRESH_BUILD" = "true" \]; then/,/^    fi/p' "$CMD")"
  [[ "$block" == *'DRY_RUN" = "true"'* ]]
  [[ "$block" == *"exit 0"* ]]
}

# ── help documents it ────────────────────────────────────────────────────────

@test "the help text documents --fresh-build as plan-only" {
  run bash -c "grep -A1 -- '--fresh-build' '$CMD' | grep -i 'plan'"
  [ "$status" -eq 0 ]
}
