#!/bin/bash
################################################################################
# lib/config-drift.sh — Vortex-style config-drift gate around `drush updatedb`
#                       (config-as-code, report P3 / nwp/ops#63)
#
# THE GAP THIS CLOSES
# -------------------
# No NWP site tracks Drupal config as code yet: the config/sync dir is
# gitignored, so `stg2live` deliberately runs NO `config:import` and `stg2prod`
# skips it unless NWP_ALLOW_CONFIG_IMPORT=1 (ops#63 cheap-guard, already merged).
# The consequence is that a live/prod site's ACTIVE config drifts invisibly:
# `drush updatedb` runs hook_update_N / hook_post_update_NAME which may rewrite
# active config, and nothing notices or records it.
#
# Vortex (the reference tool) provisions by exporting config BEFORE and AFTER
# `drush updatedb` and FAILS the build if update hooks silently changed active
# config that isn't reflected in tracked git config. This library adopts that
# pattern for NWP: a reusable, host-agnostic gate that wraps updatedb and
# fails LOUD + fail-CLOSED on unexpected drift.
#
# DESIGN — host-agnostic via an injected executor
# -----------------------------------------------
# The gate never calls ssh or drush directly. The caller injects:
#   * EXEC_FN — the NAME of a shell function; `EXEC_FN "<shell string>"` runs
#               that string on the TARGET host (locally, or over ssh for a
#               remote live/prod box) and streams its stdout/stderr, returning
#               the remote exit status. This is the single seam that lets the
#               same code path run in a bats unit test (executor = local
#               `bash -c`) and against a live server (executor = an ssh wrapper).
#   * DRUSH   — a drush invocation PREFIX valid on the target, e.g.
#               'sudo -u www-data /var/www/foo/vendor/bin/drush --root=/var/www/foo/web'
#               (stg2live already resolves exactly this; we reuse it verbatim).
#
# The gate exports active config to two FRESH temp dirs on the target (so each
# export is a full snapshot, independent of the — currently gitignored — sync
# dir), fingerprints each as a sorted sha256 manifest (computed on the target,
# so no files cross the ssh boundary), runs updatedb between them, and compares.
#
#   before == after  -> updatedb did not touch active config           -> PASS
#   before != after  -> update hooks mutated active config              -> DRIFT
#
# FAIL-CLOSED, OPT-IN ALLOW
# -------------------------
# On DRIFT the gate returns non-zero (deploy aborts). Legitimate drift — a
# module update that genuinely adds a config key — is handled by the operator
# re-running with the allow flag, reviewing the printed diff, and committing the
# new config to the tracked sync dir:
#     NWP_ALLOW_CONFIG_DRIFT=1   (or arg 5 == "1")
#
# The gate itself is OFF by default in the deploy path (see config_drift_enabled);
# a site opts in only after it tracks config as code (`pl config track`). Until
# then updatedb runs exactly as before — zero behaviour change.
#
# EXIT CODES (config_drift_guarded_updatedb)
#   0  no drift, or drift explicitly allowed, or gate produced a clean pass
#   1  `drush updatedb` itself FAILED (schema hooks not applied)
#   2  DRIFT detected and NOT allowed (fail-closed)
#   3  gate could not run (config:export failed / no config to export / mktemp)
################################################################################

# --- enablement --------------------------------------------------------------
# Whether the drift gate should engage for a given site. OFF unless the operator
# opts the site in, so existing deploys are unaffected until config-as-code is
# adopted per-site. Precedence:
#   1. NWP_CONFIG_DRIFT_GATE   env override  (1 = on, 0 = off) — wins if set
#   2. per-site .nwp.yml  `config.drift_gate: true`            — site opt-in
#   3. default: OFF
#
# Usage: config_drift_enabled <site>   -> returns 0 (enabled) / 1 (disabled)
config_drift_enabled() {
    local site="${1:-}"

    # Explicit env override always wins (both directions).
    if [ -n "${NWP_CONFIG_DRIFT_GATE:-}" ]; then
        [ "${NWP_CONFIG_DRIFT_GATE}" == "1" ] && return 0 || return 1
    fi

    # Per-site opt-in in .nwp.yml (get_site_config_value comes from
    # lib/project-resolver.sh, auto-sourced via lib/common.sh). Guard its
    # existence so this lib is usable stand-alone (and in unit tests).
    if [ -n "$site" ] && command -v get_site_config_value >/dev/null 2>&1; then
        local v
        v="$(get_site_config_value "$site" '.config.drift_gate' "false" 2>/dev/null)"
        [ "$v" == "true" ] && return 0
    fi

    return 1
}

# --- fingerprint helper ------------------------------------------------------
# Shell (run on the target) that prints a stable, path-relative sha256 manifest
# of an exported config dir. Sorted for determinism; empty if the dir is empty.
# Kept as a function so both the gate and tests build the identical command.
_config_drift_manifest_cmd() {
    local dir="$1"
    # LC_ALL=C for a stable sort independent of the target's locale.
    printf 'cd %q 2>/dev/null && find . -type f | LC_ALL=C sort | xargs -r sha256sum' "$dir"
}

# --- the gate ----------------------------------------------------------------
# config_drift_guarded_updatedb EXEC_FN DRUSH UPDATEDB_ARGS LABEL [ALLOW]
#
#   EXEC_FN        name of a function; `$EXEC_FN "<shell>"` runs <shell> on target
#   DRUSH          drush prefix valid on the target (see header)
#   UPDATEDB_ARGS  the updatedb invocation, e.g. 'updatedb -y'
#   LABEL          human label for messages, e.g. 'live (avc)'
#   ALLOW          '1' to downgrade DRIFT from fail to warn (opt-in). Defaults
#                  to $NWP_ALLOW_CONFIG_DRIFT.
#
# Returns the exit codes documented in the header.
config_drift_guarded_updatedb() {
    local exec_fn="$1"
    local drush="$2"
    local updatedb_args="$3"
    local label="${4:-target}"
    local allow="${5:-${NWP_ALLOW_CONFIG_DRIFT:-0}}"

    if ! command -v "$exec_fn" >/dev/null 2>&1; then
        print_error "config-drift gate: executor function '$exec_fn' is not defined"
        return 3
    fi

    print_info "config-drift gate ENGAGED for ${label} — exporting config before/after updatedb"

    # 1. Two fresh temp dirs on the TARGET.
    local before after
    before="$("$exec_fn" 'mktemp -d 2>/dev/null')" || before=""
    after="$("$exec_fn" 'mktemp -d 2>/dev/null')" || after=""
    if [ -z "$before" ] || [ -z "$after" ]; then
        print_error "config-drift gate: could not create temp dirs on ${label} — cannot gate"
        [ -n "$before" ] && "$exec_fn" "rm -rf ${before}" >/dev/null 2>&1
        [ -n "$after" ] && "$exec_fn" "rm -rf ${after}" >/dev/null 2>&1
        return 3
    fi

    # 2. Snapshot BEFORE: full active-config export -> manifest.
    if ! "$exec_fn" "${drush} config:export --destination=${before} -y" >/dev/null 2>&1; then
        print_error "config-drift gate: 'config:export' failed on ${label} BEFORE updatedb — cannot gate (does the site have exportable config?)"
        "$exec_fn" "rm -rf ${before} ${after}" >/dev/null 2>&1
        return 3
    fi
    local man_before
    man_before="$("$exec_fn" "$(_config_drift_manifest_cmd "$before")" 2>/dev/null)"

    # 3. Run updatedb (fail-loud on its own failure — code 1).
    if ! "$exec_fn" "${drush} ${updatedb_args}"; then
        print_error "config-drift gate: 'drush ${updatedb_args}' FAILED on ${label} — schema hooks not applied"
        "$exec_fn" "rm -rf ${before} ${after}" >/dev/null 2>&1
        return 1
    fi

    # 4. Snapshot AFTER.
    if ! "$exec_fn" "${drush} config:export --destination=${after} -y" >/dev/null 2>&1; then
        print_error "config-drift gate: 'config:export' failed on ${label} AFTER updatedb — cannot verify drift"
        "$exec_fn" "rm -rf ${before} ${after}" >/dev/null 2>&1
        return 3
    fi
    local man_after
    man_after="$("$exec_fn" "$(_config_drift_manifest_cmd "$after")" 2>/dev/null)"

    # 5. Compare, then clean up the target temp dirs.
    if [ "$man_before" == "$man_after" ]; then
        "$exec_fn" "rm -rf ${before} ${after}" >/dev/null 2>&1
        print_status "OK" "config-drift gate: updatedb did NOT change active config on ${label}"
        return 0
    fi

    # DRIFT. Show which config objects changed (manifest diff on the two
    # sha256 listings — this reveals added/removed/modified files by name).
    print_status "FAIL" "config-drift gate: 'drush ${updatedb_args}' CHANGED active config on ${label}"
    echo "----- config drift (before | after manifest diff) -------------------"
    diff <(printf '%s\n' "$man_before") <(printf '%s\n' "$man_after") || true
    echo "---------------------------------------------------------------------"
    "$exec_fn" "rm -rf ${before} ${after}" >/dev/null 2>&1

    if [ "$allow" == "1" ]; then
        print_status "WARN" "config drift ALLOWED (NWP_ALLOW_CONFIG_DRIFT=1) — review the diff and commit the new config to config/sync"
        return 0
    fi

    print_error "config drift is fail-closed. If this change is expected (e.g. a module update adding config):"
    print_error "  1. review the diff above,"
    print_error "  2. re-run with NWP_ALLOW_CONFIG_DRIFT=1 to let the deploy proceed,"
    print_error "  3. export + commit the new config to the site's tracked config/sync (see 'pl config track')."
    return 2
}
