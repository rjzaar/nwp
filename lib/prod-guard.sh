#!/bin/bash
# NOTE: no `set -euo pipefail` — SOURCED library (ops#111 lesson: forcing -e/-u
# onto a caller leaks into the bats runner and breaks CI test:unit).
################################################################################
# lib/prod-guard.sh — fail-closed guard for the sanitiser chain (ops#113 / NWP-ADR-0032).
#
# WHY THIS SHAPE (reinterpreting local_datacleaner's "never run on production"):
# NWP's prod-native sanitisers (lib/sanitizers/{standard,mayo,moodle}.sh) RUN ON
# THE PROD HOST BY DESIGN — they dump the live DB read-only into a throwaway
# SCRATCH database and mutate only the scratch copy. So a hostname/recent-activity
# "refuse on production" guard (local_datacleaner's model, meant for an IN-PLACE
# anonymiser) would BREAK the intended flow.
#
# The load-bearing safety property here is instead: **every mutation targets a
# throwaway SCRATCH database that is distinct from the live DB.** Today that holds
# implicitly (SCRATCH_DB = <live> + suffix). This guard makes it EXPLICIT and
# fail-closed, so a future edit that let the scratch name collapse to the live DB
# name (empty/blank suffix, a bad interpolation) can never silently mutate prod.
#
# The DDEV in-place path (lib/database-router.sh:_sanitize_staging_db_drupal) is
# inherently prod-safe — `ddev drush` targets the container DB, never a remote
# prod DB — so it needs no hostname guard; its safety is environmental.
################################################################################

# prod_guard_scratch_distinct <live_db> <scratch_db> [expected_suffix]
# Fail-closed unless the scratch DB is a real, throwaway name distinct from live:
#   - scratch_db non-empty,
#   - live_db non-empty,
#   - scratch_db != live_db (case-insensitive — MySQL DB names can be
#     case-insensitive depending on lower_case_table_names),
#   - and, if expected_suffix is given, scratch_db actually ends with it.
# Call this BEFORE creating/loading/mutating the scratch DB. Returns 0 to proceed,
# non-zero (with a reason on stderr) to abort.
prod_guard_scratch_distinct() {
    local live="${1:-}" scratch="${2:-}" suffix="${3:-}"
    if [ -z "$scratch" ]; then
        echo "prod-guard: scratch DB name is empty — refusing (fail-closed)" >&2; return 1
    fi
    if [ -z "$live" ]; then
        echo "prod-guard: live DB name is empty — refusing (fail-closed)" >&2; return 1
    fi
    # Case-insensitive compare: 'Prod' and 'prod' may be the same database.
    local live_lc scratch_lc
    live_lc="$(printf '%s' "$live" | tr '[:upper:]' '[:lower:]')"
    scratch_lc="$(printf '%s' "$scratch" | tr '[:upper:]' '[:lower:]')"
    if [ "$scratch_lc" = "$live_lc" ]; then
        echo "prod-guard: scratch DB ('$scratch') equals the LIVE DB ('$live') — refusing to mutate production data (fail-closed)" >&2
        return 1
    fi
    if [ -n "$suffix" ]; then
        case "$scratch" in
            *"$suffix") : ;;
            *) echo "prod-guard: scratch DB '$scratch' does not end with the expected suffix '$suffix' — refusing (fail-closed)" >&2; return 1 ;;
        esac
    fi
    return 0
}
