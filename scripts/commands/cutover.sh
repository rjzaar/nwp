#!/bin/bash
################################################################################
# ⚠  PROFILE-CHANGE GUARD — READ BEFORE RUNNING AGAINST nwc  ⚠
#
# Step 4 below uses `pl stg2live nwc --code-only`, which is INVALID for the nwc
# un-fork. The un-fork is a Drupal INSTALL-PROFILE CHANGE: live runs profile
# `nwc`; the new build's profile is `social` (Open Social distro + nwc recipes).
# `--code-only` CANNOT cross a profile change — it leaves the live DB recording
# `profile: nwc` while the new code ships NO `nwc` profile and hides Open
# Social's modules under `profiles/contrib/social/`, so the site cannot boot.
# See ~/central/UNFORK-PROFILE-INTENT-2026-07-19.md.
#
# This orchestrator is being REPLACED by the Option-1 rebuild+migrate flow
# (fresh `drush site:install social` + recipe + Migrate import). Until that
# lands, DO NOT run this against nwc. The fail-closed `preflight_profile_guard`
# (and the in-rehearsal profile check) below ABORT any rehearse/execute when the
# LIVE install profile differs from the TARGET build's install profile.
################################################################################
# scripts/commands/cutover.sh — `pl cutover nwc` : the one-time nwc un-fork
# migration orchestrator (PL-STG2LIVE-INTEGRATION-DESIGN-2026-07-19 §3.7 + §6
# P1-4, promote order §5.4).
#
# WHAT THIS IS
#   The nwc go-live is NOT a routine `pl stg2live` — it is the un-fork cutover
#   (old hard-forked Open Social → composer-managed OS v13). The dry-run proves
#   it deletes ~6,253 in-profile files and adds ~6,497 distro files, then runs
#   cross-version `updatedb` hooks against the LIVE member DB
#   (NWC-DEPLOY-STATUS-2026-07-19). This wrapper makes that a deliberate,
#   fail-closed, resumable migration instead of a bare stg2live one-liner.
#
# SHAPE (design §3.7, P1-4)
#   A thin ORCHESTRATOR: an ordered sequence of GUARDED `pl` commands, each
#   fail-closed (any failure aborts the whole cutover). It reimplements nothing
#   destructive itself and NEVER runs raw ssh — every live action routes through
#   `pl drush` (the sanctioned remote runner) or a sibling `pl` verb by NAME.
#
#   The sibling verbs are in-flight MRs. When one is absent this wrapper does
#   NOT improvise — it prints "prerequisite MR not merged: <cmd>" and aborts.
#
#   Ordered steps (each fail-closed):
#     0. IMPACT typed-confirm of the 6,253-delete / 6,497-add magnitude (--execute)
#     1. Preflight backup      : pl backup --remote nwc          (P0-3)
#     2. Uninstall non-surv.   : pl drush … pm:uninstall tracer nwp_lockdown -y
#                                + module-set drop diff (warn)
#     3. Rehearsal (updatedb on a SCRATCH copy of the live DB) — gates --execute
#     4. Code cutover          : pl stg2live nwc --code-only     (excludes+snap+updatedb via !117/!119)
#     5. Live post-provision   : pl secrets inject + en nwc_examen + media-levels-seed + cr
#     6. Link health gate      : pl link verify nwc --tier=live --round-trip
#     7. Stamp one-time idempotency lock (private/cutover/nwc.done)
#
# SAFETY
#   * --rehearse is runnable independently and READ-ONLY on live except the
#     scratch DB it creates + drops.
#   * --execute is refused unless a --rehearse has recorded status=passed.
#   * The idempotency lock refuses a second --execute (unless --force).
#   * ⚠ MUST NOT be run before its prerequisite MRs merge (pl backup --remote,
#     pl secrets inject, pl link verify, stg2live !119). The steps detect the
#     absent siblings and abort — this is the guard, not a licence to run early.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
# Libs load from the repo; state/config resolve from PROJECT_ROOT (defaults to
# the repo, honoured if pre-set — test isolation, mirrors drush.sh).
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/impact.sh"
# project-resolver.sh gives resolve_project (the same resolver `pl drush
# --tier=stg` uses) + get_backup_dir (where `pl backup --remote` writes its
# dump). The rehearsal needs both to import the pulled live DB into the stg
# DDEV scratch surface. Self-contained (defines functions only; no side effects).
source "$REPO_ROOT/lib/project-resolver.sh"

# ── sibling `pl` invocation (mockable) ───────────────────────────────────────
# All sibling verbs are invoked through PL_BIN so a mock `pl` can record/assert
# the exact command strings in tests, and so a real run routes through the pl
# dispatcher (guards, deploy-gate, etc.). Never raw ssh.
PL_BIN="${PL_BIN:-$REPO_ROOT/pl}"
run_pl() { "$PL_BIN" "$@"; }

# ── capability detection (degrade-if-absent) ─────────────────────────────────
# The sibling verbs land in separate in-flight MRs. Detect presence against the
# real command surface (overridable for tests via CUTOVER_CMD_DIR). Each maps
# to a P0/P1 item in the design's build spec.
CMD_DIR="${CUTOVER_CMD_DIR:-$REPO_ROOT/scripts/commands}"
cap_backup_remote()     { grep -Eq -- '--remote' "$CMD_DIR/backup.sh"   2>/dev/null; }   # P0-3
cap_secrets_inject()    { grep -Eq '^[[:space:]]*inject\)' "$CMD_DIR/secrets.sh" 2>/dev/null; } # P0-4
cap_link_verify()       { [ -f "$CMD_DIR/link.sh" ] && grep -q 'verify' "$CMD_DIR/link.sh" 2>/dev/null; } # P1-3
cap_drush()             { [ -f "$CMD_DIR/drush.sh" ]; }                                    # merged
cap_stg2live_codeonly() { grep -q -- '--code-only' "$CMD_DIR/stg2live.sh" 2>/dev/null; }  # !117
cap_rollback_execute()  { grep -Eq '^[[:space:]]*execute\)' "$CMD_DIR/rollback.sh" 2>/dev/null; }

# require_sibling <human-cmd> <capability-fn> <mr-hint>
require_sibling() {
    local cmd="$1" capfn="$2" hint="$3"
    if "$capfn"; then return 0; fi
    print_error "prerequisite MR not merged: ${cmd}"
    print_hint "$hint"
    print_hint "Merge the sibling MR, then re-run (or resume with --from=STEP)."
    return 1
}

# ── magnitude constants (nwc, NWC-DEPLOY-STATUS-2026-07-19) ───────────────────
UNFORK_DELETES=6253   # in-profile Open Social files removed (old hard-fork)
UNFORK_ADDS=6497      # OS-v13 composer-distro files added

# ── globals (set in parse_args) ──────────────────────────────────────────────
SITE=""
MODE=""              # rehearse | execute
FROM_STEP=1
FORCE=false
AUTO_CONFIRM=false

STATE_DIR=""         # $PROJECT_ROOT/private/cutover
LOCK_FILE=""         # $STATE_DIR/$SITE.done
REHEARSE_FILE=""     # $STATE_DIR/$SITE.rehearse
PROGRESS_FILE=""     # $STATE_DIR/$SITE.state

abort() { print_error "$1"; print_status "FAIL" "cutover aborted — no further steps run."; exit 1; }

show_help() {
    cat <<EOF
${BOLD}NWP Cutover — the one-time nwc un-fork migration orchestrator${NC}
(PL-STG2LIVE-INTEGRATION-DESIGN §3.7 + §6 P1-4)

${BOLD}USAGE:${NC}
    pl cutover <site> --rehearse
    pl cutover <site> --execute [--from=STEP] [--force] [-y]

${BOLD}MODES:${NC}
    --rehearse          Read-only on live except a scratch DB it creates+drops:
                        dump live → import to scratch → drush updatedb → record.
                        MUST pass before --execute is allowed.
    --execute           Run the ordered, fail-closed cutover (steps 1-7).

${BOLD}OPTIONS:${NC}
    --from=STEP         Resume --execute at step N (1-7) after a fixed failure.
    --force             Override the one-time idempotency lock (re-run --execute).
    -y, --yes           Skip the typed IMPACT confirm (DISCOURAGED).
    -h, --help          Show this help.

${BOLD}ORDERED STEPS (each fail-closed; a failure aborts the whole cutover):${NC}
    0  IMPACT typed-confirm  — ~${UNFORK_DELETES} deletes / ~${UNFORK_ADDS} adds + live-DB updatedb
    1  pl backup --remote <site>                               (P0-3)
    2  pl drush <site> --tier=live --execute -- pm:uninstall tracer nwp_lockdown -y
       + module-set drop diff vs the new build (warn on unexpected drops)
    3  rehearsal gate (updatedb on a scratch copy of the live DB)
    4  pl stg2live <site> --code-only                         (!117 excludes / !119 updatedb)
    5  pl secrets inject <site> --tier=live; en nwc_examen; nwc-guild:media-levels-seed; cr
    6  pl link verify <site> --tier=live --round-trip         (must be green)
    7  stamp private/cutover/<site>.done (idempotency lock)

${BOLD}⚠  DO NOT run before the prerequisite MRs merge.${NC} The steps detect absent
   sibling verbs (pl backup --remote, pl secrets inject, pl link verify) and
   abort with "prerequisite MR not merged" — that is the guard, not a licence.
EOF
}

# ── arg parsing ──────────────────────────────────────────────────────────────
parse_args() {
    local a
    while [ $# -gt 0 ]; do
        a="$1"
        case "$a" in
            -h|--help|help) show_help; exit 0 ;;
            --rehearse)     MODE="rehearse"; shift ;;
            --execute)      MODE="execute";  shift ;;
            --from=*)       FROM_STEP="${a#*=}"; shift ;;
            --from)         FROM_STEP="${2:-}"; shift 2 ;;
            --force)        FORCE=true; shift ;;
            -y|--yes)       AUTO_CONFIRM=true; shift ;;
            -*)             abort "Unknown option: $a" ;;
            *)              if [ -z "$SITE" ]; then SITE="$a"; else abort "Unexpected argument: $a"; fi; shift ;;
        esac
    done

    [ -z "$SITE" ] && { print_error "Site required (e.g. 'nwc')."; show_help; exit 1; }
    # The un-fork cutover is nwc-specific (magnitude, module set, recipes).
    if [ "$SITE" != "nwc" ]; then
        abort "pl cutover currently supports only the nwc un-fork (got '$SITE')."
    fi
    if [ -z "$MODE" ]; then
        print_error "Exactly one of --rehearse | --execute is required."
        show_help; exit 1
    fi
    case "$FROM_STEP" in
        ''|*[!0-9]*) abort "--from must be a step number 1-7 (got '$FROM_STEP')." ;;
    esac
    if [ "$FROM_STEP" -lt 1 ] || [ "$FROM_STEP" -gt 7 ]; then
        abort "--from must be a step number 1-7 (got '$FROM_STEP')."
    fi

    STATE_DIR="$PROJECT_ROOT/private/cutover"
    LOCK_FILE="$STATE_DIR/$SITE.done"
    REHEARSE_FILE="$STATE_DIR/$SITE.rehearse"
    PROGRESS_FILE="$STATE_DIR/$SITE.state"
    mkdir -p "$STATE_DIR"
}

record_progress() { echo "$1" > "$PROGRESS_FILE"; }

################################################################################
# PROFILE-CHANGE GUARD (fail-closed).
#
# The nwc un-fork is a Drupal INSTALL-PROFILE change: live installs profile
# `nwc`; the new build installs profile `social`. `--code-only` (step 4) CANNOT
# cross a profile change — it leaves the live DB recording `profile: nwc` while
# the new code ships no `nwc` profile and hides Open Social under
# `profiles/contrib/social/`, so the site will not boot. The correct route is
# Option 1 (fresh `drush site:install social` + recipe + Migrate import).
# See ~/central/UNFORK-PROFILE-INTENT-2026-07-19.md.
#
#   TARGET profile — read OFFLINE from the staging build's config-sync
#     core.extension.yml (`profile:` key): the profile the new code installs as.
#   LIVE profile   — read from the LIVE DB. The rehearsal imports the live DB
#     into the stg scratch surface, so we read it there READ-ONLY (`--tier=stg
#     -- cget core.extension profile`) and RECORD it. `--execute` then compares
#     OFFLINE (recorded live profile vs target) BEFORE any live contact.
#
# Fail-closed: an unreadable target profile aborts; a recorded live profile that
# differs from the target aborts; `--execute` with no recorded live profile
# aborts. Same-profile sites pass silently (no behaviour change).
################################################################################

# Read the TARGET (new build) install profile from the stg config-sync dir.
# Offline: a plain file read, no live contact.
read_target_profile() {
    local site="$1" stg_dir sync val
    stg_dir="$(resolve_project "$site" stg 2>/dev/null || true)"
    [ -n "$stg_dir" ] || return 1
    sync="$stg_dir/html/sites/default/files/sync/core.extension.yml"
    [ -f "$sync" ] || return 1
    val="$(awk -F: '/^profile:/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$sync")"
    [ -n "$val" ] || return 1
    printf '%s\n' "$val"
}

# Read the LIVE install profile from the just-imported live DB on the stg
# scratch surface (READ-ONLY on live — the dump was already pulled+imported).
read_stg_live_profile() {
    local site="$1" out val
    out="$(run_pl drush "$site" --tier=stg -- cget core.extension profile 2>/dev/null || true)"
    # drush prints e.g.  'core.extension:profile': social   → take the last field.
    val="$(printf '%s\n' "$out" | awk 'NF{v=$NF} END{gsub(/[[:space:]'"'"'"]/,"",v); print v}')"
    [ -n "$val" ] || return 1
    printf '%s\n' "$val"
}

record_live_profile()   { echo "$1" > "$STATE_DIR/$SITE.liveprofile"; }
recorded_live_profile() { [ -f "$STATE_DIR/$SITE.liveprofile" ] && cat "$STATE_DIR/$SITE.liveprofile"; }

profile_change_abort() {
    local live="$1" target="$2"
    print_error "PROFILE-CHANGE GUARD: refusing the nwc un-fork via --code-only."
    print_error "Live installs profile '${live}' but the new build installs profile '${target}'."
    print_error "The un-fork is a Drupal INSTALL-PROFILE change ('${live}' → '${target}') — --code-only CANNOT cross it:"
    print_error "  it leaves the live DB recording profile '${live}' while the new code ships no '${live}' profile"
    print_error "  and hides Open Social under profiles/contrib/social/, so the site will not boot."
    print_hint "Correct route: Option 1 — fresh 'drush site:install ${target}' + recipe + Migrate import."
    print_hint "See ~/central/UNFORK-PROFILE-INTENT-2026-07-19.md (§4 Option 1)."
}

# Offline preflight guard. $1=require_live (true|false).
#   * Target profile must be readable → else fail-closed abort.
#   * A recorded live profile that differs from target → fail-closed abort.
#   * require_live=true (--execute) with no recorded live profile → abort.
# Runs BEFORE any destructive step / before the rehearsal pulls a live dump.
preflight_profile_guard() {
    local require_live="${1:-false}" target live
    target="$(read_target_profile "$SITE" 2>/dev/null || true)"
    if [ -z "$target" ]; then
        abort "PROFILE-CHANGE GUARD: cannot read the TARGET install profile from the stg config-sync (core.extension.yml) — refusing (fail-closed)."
    fi
    live="$(recorded_live_profile 2>/dev/null || true)"
    if [ -z "$live" ]; then
        if [ "$require_live" == "true" ]; then
            abort "PROFILE-CHANGE GUARD: no recorded LIVE install profile — run 'pl cutover $SITE --rehearse' first (it reads live profile from the imported DB). Refusing (fail-closed)."
        fi
        # First rehearse: the live profile is established from the imported DB
        # (in-rehearsal check below). Nothing to compare offline yet.
        print_info "PROFILE-CHANGE GUARD: target profile '${target}'; live profile will be read from the imported DB during the rehearsal."
        return 0
    fi
    if [ "$live" != "$target" ]; then
        profile_change_abort "$live" "$target"
        abort "profile change ('${live}' → '${target}') cannot be crossed by --code-only."
    fi
    print_status "OK" "PROFILE-CHANGE GUARD: live profile '${live}' == target profile '${target}' — profile-safe."
    return 0
}

################################################################################
# The IMPACT typed-confirm — rendered before step 1 on --execute (P1-4).
# impact_confirm typed forces the operator to type the site name; -y skips only
# the prompt, never the printed manifest (the impact.sh contract).
################################################################################
render_impact_and_confirm() {
    impact_reset
    impact_delete    "In-profile files" "~${UNFORK_DELETES} old-fork Open Social files under html/profiles/custom removed"
    impact_overwrite "Live webroot"      "~${UNFORK_ADDS} OS-v13 distro files added under html/profiles/contrib/social — swapped via rsync --delete"
    impact_warn      "Cross-version updatedb runs OS fork→v13 hooks against the LIVE member DB (irreversible; recovery only via the preflight backup + DB restore)"
    impact_warn      "2 non-survivable modules (tracer, nwp_lockdown) are uninstalled on live before the swap"
    impact_keep      "Live member DB content preserved — --code-only, no DB import (INV-1)"
    impact_keep      "oauth-keys/, auth.json, files/, private/, settings.local.php + settings.local.overrides.php — rsync-excluded (!117, INV-2/3/5)"
    impact_keep      "OIDC consumer entity + already-issued tokens survive --code-only"
    impact_render
    impact_confirm typed "$SITE" "$AUTO_CONFIRM" || abort "IMPACT confirmation declined."
}

################################################################################
# STEP 1 — Preflight backup (P0-3). Refuse to proceed without a verified backup.
################################################################################
step_preflight_backup() {
    print_header "STEP 1/7 — preflight remote backup (pl backup --remote $SITE)"
    require_sibling "pl backup --remote" cap_backup_remote \
        "P0-3 (pl backup --remote): live DR-preflight snapshot (webroot tar + sql:dump + sha256 sidecar)." \
        || return 1
    if ! run_pl backup --remote "$SITE"; then
        return 1
    fi
    print_status "OK" "verified preflight backup taken — recovery path exists before any --delete."
    return 0
}

################################################################################
# STEP 2 — Uninstall the 2 non-survivable modules of 182, then diff the live
# module set vs the new build and warn on unexpected drops (§3.7 step 1).
################################################################################
step_uninstall_nonsurvivable() {
    print_header "STEP 2/7 — uninstall non-survivable modules (tracer, nwp_lockdown)"
    require_sibling "pl drush" cap_drush \
        "pl drush (sanctioned remote runner) must be present — never raw ssh drush." || return 1

    if ! run_pl drush "$SITE" --tier=live --execute -- pm:uninstall tracer nwp_lockdown -y; then
        return 1
    fi
    print_status "OK" "tracer + nwp_lockdown uninstalled on live."

    # Module-set drop diff: live-enabled vs new-build-available. Read-only; a
    # drop beyond the 2 handled above is a WARN (operator judgement), not abort.
    local live_enabled stg_available missing
    live_enabled="$(run_pl drush "$SITE" --tier=live --execute -- pm:list --status=enabled --field=name 2>/dev/null || true)"
    stg_available="$(run_pl drush "$SITE" --tier=stg -- pm:list --field=name 2>/dev/null || true)"
    if [ -n "$live_enabled" ] && [ -n "$stg_available" ]; then
        missing="$(comm -23 <(printf '%s\n' "$live_enabled" | sort -u) \
                             <(printf '%s\n' "$stg_available" | sort -u) 2>/dev/null || true)"
        if [ -n "$missing" ]; then
            print_warning "modules enabled on live but ABSENT from the new build (verify before continuing):"
            printf '    %s\n' $missing
        else
            print_status "OK" "every live-enabled module is present in the new build."
        fi
    else
        print_warning "could not compute the module-set diff (empty pm:list output) — verify manually."
    fi
    return 0
}

################################################################################
# STEP 3 — Rehearsal: run updatedb on a SCRATCH COPY of the live DB and record
# the result. Blocks --execute unless the update hooks all succeeded (F3/G4).
# Read-only on live except the scratch DB (created + dropped here).
#
# Faithfully models the real --execute order (step-2 uninstall on LIVE with the
# OLD code present → step-4 stg2live swaps to the NEW code → step-4 updatedb on
# the live member DB). On the scratch surface that becomes:
#   a. pl backup --remote nwc --db-only  → a local live DB dump (+ sha sidecar)
#   b. ddev import-db the dump into the disposable stg (DDEV) DB — WITHOUT this
#      the rehearsal ran updatedb against stg's OWN fresh DB, never the live one
#   c. DE-REGISTER tracer + nwp_lockdown at the DB level (mirror of the step-2
#      uninstall). NOT pm:uninstall: the new un-forked build ships no tracer/
#      nwp_lockdown CODE, so pm:uninstall aborts "module does not exist". We drop
#      them from system.schema + core.extension instead (tolerant of absence).
#   d. pl drush nwc --tier=stg -- updatedb -y (+ cr)  → scan for failed hooks
#   e. record status=passed|failed; the stg DB is rebuilt by the operator after
################################################################################
run_rehearsal() {
    print_header "REHEARSAL — updatedb on a scratch copy of the live DB (gate for --execute)"

    require_sibling "pl backup --remote" cap_backup_remote \
        "P0-3 (pl backup --remote): needed to pull a live DB dump for the scratch rehearsal." || return 1
    require_sibling "pl drush" cap_drush \
        "pl drush must be present for the scratch updatedb." || return 1

    print_status "OK" "rehearsal is READ-ONLY on live except the scratch DB (created + dropped here)."

    # a. Pull a live DB dump (read-only on live). Writes
    #    sites/<site>/backups/<site>-remote-<ts>.sql.gz (+ .sha256 + manifest).
    if ! run_pl backup --remote "$SITE" --db-only; then
        record_rehearse "failed" "live DB dump failed"
        return 1
    fi

    # a'. Locate the just-written dump (newest remote db-only artifact). Without
    #     a real dump there is nothing to test — fail-closed.
    local backup_dir dump
    backup_dir="$(get_backup_dir "$SITE")"
    dump="$(ls -1t "$backup_dir/$SITE"-remote-*.sql.gz 2>/dev/null | head -1)"
    if [ -z "$dump" ] || [ ! -f "$dump" ]; then
        record_rehearse "failed" "could not locate the pulled live DB dump under $backup_dir"
        print_status "FAIL" "no live DB dump found to import — rehearsal cannot test the live DB."
        return 1
    fi
    print_status "OK" "pulled live DB dump: $dump"

    # a''. Resolve the disposable stg DDEV scratch surface (the SAME resolver that
    #      `pl drush --tier=stg` uses). It must exist to import into.
    local stg_dir
    stg_dir="$(resolve_project "$SITE" stg 2>/dev/null || true)"
    if [ -z "$stg_dir" ] || [ ! -d "$stg_dir" ]; then
        record_rehearse "failed" "stg DDEV scratch dir not found — run 'pl dev2stg $SITE' first"
        print_status "FAIL" "no stg DDEV site to rehearse against."
        return 1
    fi

    # b. Import the live dump into the stg DDEV scratch DB (ddev import-db infers
    #    gzip from the .sql.gz extension). THE FIX: the old rehearsal pulled the
    #    dump but never imported it, so updatedb ran against stg's own fresh DB —
    #    not the live member DB it is meant to gate. Fail-closed on import error.
    print_info "importing the live DB dump into the stg scratch surface (ddev import-db)…"
    if ! ( cd "$stg_dir" && ddev import-db --file="$dump" ); then
        record_rehearse "failed" "ddev import-db of the live dump into stg failed"
        print_status "FAIL" "could not import the live DB into the stg scratch surface — --execute stays blocked."
        return 1
    fi
    print_status "OK" "live member DB imported into the stg scratch surface."

    # b'. PROFILE-CHANGE GUARD (in-DB): read the LIVE install profile from the
    #     just-imported live DB and compare it to the TARGET (new build) profile.
    #     A profile change ('nwc' → 'social') CANNOT be crossed by the step-4
    #     --code-only swap, so abort the rehearsal BEFORE the pointless updatedb
    #     and RECORD the mismatch so --execute stays blocked offline. Fail-closed
    #     if either profile can't be read. See UNFORK-PROFILE-INTENT-2026-07-19.
    local _target _live
    _target="$(read_target_profile "$SITE" 2>/dev/null || true)"
    _live="$(read_stg_live_profile "$SITE" 2>/dev/null || true)"
    [ -n "$_live" ] && record_live_profile "$_live"
    if [ -z "$_target" ] || [ -z "$_live" ]; then
        record_rehearse "failed" "profile guard could not read live='${_live}' / target='${_target}'"
        print_status "FAIL" "PROFILE-CHANGE GUARD: could not determine live/target install profile — refusing (fail-closed)."
        return 1
    fi
    if [ "$_live" != "$_target" ]; then
        profile_change_abort "$_live" "$_target"
        record_rehearse "failed" "install-profile change ${_live} -> ${_target}; --code-only invalid (UNFORK-PROFILE-INTENT)"
        print_status "FAIL" "PROFILE-CHANGE GUARD: install-profile change (${_live} → ${_target}) — --execute stays blocked."
        return 1
    fi
    print_status "OK" "PROFILE-CHANGE GUARD: live profile '${_live}' == target '${_target}' — profile-safe."

    # c. Mirror the step-2 uninstall at the DB level, TOLERANTLY. pm:uninstall
    #    CANNOT run here: the new un-forked build ships no tracer/nwp_lockdown
    #    code, so drush would abort "The module tracer does not exist" (this was
    #    the second rehearsal bug). De-register them directly instead — the same
    #    end-state a clean uninstall leaves — so updatedb doesn't choke on a
    #    missing-code enabled module. Never fail-closed on an already-absent
    #    module (it is *supposed* to be gone).
    rehearsal_deregister_nonsurvivable "$stg_dir" \
        || print_warning "de-registration reported a non-zero — continuing (tolerant of already-absent modules)."

    # d. The rehearsed updatedb on the scratch surface (now = new code + imported
    #    live DB, minus the 2 modules). This is the real gate. Mirrors stg2live's
    #    actual post-swap sequence (updatedb -y → cache:rebuild, §3.6 / lines
    #    1068-1112 of stg2live.sh), not the P0.5 two-phase --no-post-updates
    #    variant (stg2live does not implement that). Capture output to scan for
    #    failed hooks.
    local out
    if ! out="$(run_pl drush "$SITE" --tier=stg -- updatedb -y 2>&1)"; then
        printf '%s\n' "$out"
        record_rehearse "failed" "updatedb returned non-zero"
        print_status "FAIL" "rehearsed updatedb FAILED — --execute stays blocked."
        return 1
    fi
    printf '%s\n' "$out"
    if printf '%s' "$out" | grep -Eiq 'fail|exception|error'; then
        record_rehearse "failed" "updatedb output reported a failing hook"
        print_status "FAIL" "rehearsed updatedb reported a failing hook — --execute stays blocked."
        return 1
    fi

    # Faithful tail of the stg2live sequence: rebuild caches after updatedb.
    # A cr wobble is not the gate (updatedb output already passed) — warn only.
    run_pl drush "$SITE" --tier=stg -- cr >/dev/null 2>&1 \
        || print_warning "post-updatedb cache:rebuild reported a non-zero (not the gate — continuing)."

    record_rehearse "passed" "all update hooks succeeded"
    print_status "OK" "rehearsal PASSED — --execute is now permitted."
    print_hint "The stg DB now holds the rehearsed (post-updatedb) copy of the LIVE DB — rebuild it with 'pl dev2stg $SITE --dev-db' before go-live."
    return 0
}

################################################################################
# De-register the 2 non-survivable modules (tracer, nwp_lockdown) at the DB
# level on the stg scratch surface — the DB-level mirror of the step-2 live
# `pm:uninstall`. The new un-forked build ships NO code for these modules, so
# `pm:uninstall` is impossible (it would abort "module does not exist"); we
# instead drop them from the `system.schema` key-value store AND from the
# `core.extension` config `module` list, then rebuild caches. That is exactly
# the end-state a clean uninstall leaves, so the rehearsed updatedb won't choke
# on a missing-code enabled module.
#
# TOLERANT BY DESIGN: an already-absent module is a no-op (array_key_exists /
# keyValue delete are both safe on absence), so a to-be-removed module that is
# already gone never fails the rehearsal. Routed through `pl drush --tier=stg`
# (local DDEV, no ssh) for consistency with the rehearsed updatedb.
################################################################################
rehearsal_deregister_nonsurvivable() {
    # $1 (stg_dir) is accepted for symmetry/logging; the drush routing resolves
    # the same stg surface via --tier=stg.
    local php='
$mods = ["tracer", "nwp_lockdown"];
$ext = \Drupal::configFactory()->getEditable("core.extension");
$list = $ext->get("module") ?: [];
$schema = \Drupal::keyValue("system.schema");
foreach ($mods as $m) {
  if (array_key_exists($m, $list)) {
    unset($list[$m]);
    \Drupal::logger("cutover")->notice("rehearsal: de-registered @m from core.extension", ["@m" => $m]);
  } else {
    \Drupal::logger("cutover")->notice("rehearsal: @m already absent from core.extension (tolerated)", ["@m" => $m]);
  }
  $schema->delete($m);
}
$ext->set("module", $list)->save();
'
    print_info "de-registering tracer + nwp_lockdown at the DB level (mirror of the live step-2 uninstall)…"
    run_pl drush "$SITE" --tier=stg -- php:eval "$php" || return 1
    run_pl drush "$SITE" --tier=stg -- cr || return 1
    return 0
}

record_rehearse() {
    {
        echo "status=$1"
        echo "detail=$2"
        echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$REHEARSE_FILE"
}

rehearsal_passed() {
    [ -f "$REHEARSE_FILE" ] && grep -q '^status=passed$' "$REHEARSE_FILE"
}

################################################################################
# STEP 4 — The code cutover: pl stg2live nwc --code-only (§3.7 step 3/4).
# stg2live now carries the §3.4 excludes + webroot snapshot + updatedb sequence
# (merged !117 / in-flight !119). --code-only preserves the live member DB.
################################################################################
step_stg2live_codeonly() {
    print_header "STEP 4/7 — code cutover (pl stg2live $SITE --code-only)"
    require_sibling "pl stg2live --code-only" cap_stg2live_codeonly \
        "stg2live --code-only (with !117 excludes + !119 webroot snapshot + updatedb)." || return 1

    # stg2live has no separate --unfork flag today; the un-fork intent is carried
    # by --code-only (design §3.7: preserve the live member DB, swap code only).
    if grep -q -- '--unfork' "$CMD_DIR/stg2live.sh" 2>/dev/null; then
        print_info "passing --unfork to stg2live."
        run_pl stg2live "$SITE" --code-only --unfork || return 1
    else
        print_info "stg2live has no --unfork flag yet — the un-fork intent is carried by --code-only (§3.7)."
        run_pl stg2live "$SITE" --code-only || return 1
    fi
    print_status "OK" "code cutover applied — webroot swapped, live-DB updatedb run (via stg2live)."
    return 0
}

################################################################################
# STEP 5 — Live post-provision (§3.7 step 5). If updatedb failed inside step 4
# stg2live already aborted; here we provision on the migrated DB. Any failure
# ABORTS and points at pl rollback execute nwc (the DB-restore branch, !119).
################################################################################
step_live_post() {
    print_header "STEP 5/7 — live post-provision (secrets inject, enable modules, seed, cr)"
    require_sibling "pl secrets inject" cap_secrets_inject \
        "P0-4 (pl secrets inject): writes settings.local.overrides.php cross-site tokens + hash_salt." || { rollback_hint; return 1; }
    require_sibling "pl drush" cap_drush "pl drush must be present." || { rollback_hint; return 1; }

    if ! run_pl secrets inject "$SITE" --tier=live; then rollback_hint; return 1; fi
    print_status "OK" "env config + cross-site secrets injected (settings.local.overrides.php)."

    if ! run_pl drush "$SITE" --tier=live --execute -- en nwc_examen -y; then rollback_hint; return 1; fi
    if ! run_pl drush "$SITE" --tier=live --execute -- nwc-guild:media-levels-seed; then rollback_hint; return 1; fi
    if ! run_pl drush "$SITE" --tier=live --execute -- cr; then rollback_hint; return 1; fi
    print_status "OK" "nwc_examen enabled, media levels seeded, caches rebuilt."
    return 0
}

rollback_hint() {
    print_error "A live post-step failed AFTER the code/DB cutover."
    if cap_rollback_execute; then
        print_hint "Restore from the preflight snapshot: pl rollback execute $SITE"
        print_hint "(the DB-restore branch from !119 re-imports the preflight sql:dump behind a typed-timestamp confirm)."
    else
        print_hint "Restore manually from the STEP-1 preflight backup (pl rollback execute — DB-restore branch — not yet merged)."
    fi
}

################################################################################
# STEP 6 — Link health gate (§3.7 step 6, §5.5). Must be GREEN before finishing;
# a red result leaves the maintenance-window decision to the operator and aborts
# (the lock is NOT stamped).
################################################################################
step_link_verify() {
    print_header "STEP 6/7 — link health gate (pl link verify $SITE --tier=live --round-trip)"
    require_sibling "pl link verify" cap_link_verify \
        "P1-3 (pl link verify): three-channel OIDC + copyright + signal round-trip health gate." || return 1
    if ! run_pl link verify "$SITE" --tier=live --round-trip; then
        print_error "link verify is RED — the nwc↔ssc link is not healthy after the cutover."
        print_hint "Do NOT disable maintenance blindly. Investigate the red channel; maintenance-window handling is left to the operator."
        return 1
    fi
    print_status "OK" "link verify GREEN — OIDC + cross-site channels healthy."
    return 0
}

################################################################################
# STEP 7 — Stamp the one-time idempotency lock (private/cutover/<site>.done).
################################################################################
step_stamp_lock() {
    print_header "STEP 7/7 — stamp the one-time idempotency lock"
    {
        echo "cutover=$SITE"
        echo "completed=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "magnitude=deletes~${UNFORK_DELETES} adds~${UNFORK_ADDS}"
        echo "note=nwc un-fork (OS fork → composer OS v13) completed via pl cutover"
    } > "$LOCK_FILE"
    print_status "OK" "idempotency lock stamped: $LOCK_FILE"
    print_success "nwc un-fork cutover COMPLETE."
    return 0
}

################################################################################
# Drivers
################################################################################
do_rehearse() {
    # Offline PROFILE-CHANGE GUARD: block a REPEAT rehearse (a prior rehearsal
    # recorded a mismatched live profile) BEFORE it wastes another live dump, and
    # fail-closed if the target profile is unreadable. The first rehearse has no
    # recorded live profile yet — the in-rehearsal check establishes it.
    preflight_profile_guard false
    run_rehearsal || abort "rehearsal failed — --execute remains blocked."
    print_success "rehearsal recorded PASSED — you may now run: pl cutover $SITE --execute"
}

do_execute() {
    # Idempotency lock: refuse a second --execute unless --force.
    if [ -f "$LOCK_FILE" ] && [ "$FORCE" != "true" ]; then
        print_error "cutover already completed (lock present: $LOCK_FILE)."
        print_hint "Re-running the un-fork on an already-migrated live site is unsafe. Use --force only if you truly intend to re-run."
        exit 1
    fi

    # Rehearsal gate: --execute blocked unless a --rehearse recorded status=passed.
    if ! rehearsal_passed; then
        print_error "no PASSED rehearsal on record — run 'pl cutover $SITE --rehearse' first."
        print_hint "The cross-version updatedb against the live member DB must be rehearsed on a scratch copy before execution (design §3.7 / F3 / G4)."
        exit 1
    fi

    # PROFILE-CHANGE GUARD (fail-closed, OFFLINE) — refuse BEFORE any live
    # contact / the IMPACT prompt if the live install profile (recorded by the
    # passed rehearsal) differs from the target build's profile. --code-only
    # cannot cross a profile change (nwc → social); see UNFORK-PROFILE-INTENT.
    preflight_profile_guard true

    # IMPACT typed-confirm before the first destructive step (unless resuming
    # past the destructive rsync at step 4).
    if [ "$FROM_STEP" -le 4 ]; then
        render_impact_and_confirm
    else
        print_warning "--from=$FROM_STEP resumes AFTER the destructive code swap — skipping the IMPACT confirm."
    fi

    local step
    for step in 1 2 3 4 5 6 7; do
        [ "$step" -lt "$FROM_STEP" ] && continue
        case "$step" in
            1) step_preflight_backup      || abort "step 1 (preflight backup) failed." ;;
            2) step_uninstall_nonsurvivable || abort "step 2 (uninstall non-survivable modules) failed." ;;
            3) rehearsal_passed && print_status "OK" "STEP 3/7 — rehearsal gate satisfied (recorded PASSED)." \
                   || abort "step 3 (rehearsal gate) not satisfied." ;;
            4) step_stg2live_codeonly     || abort "step 4 (stg2live --code-only) failed — see rollback guidance above." ;;
            5) step_live_post             || abort "step 5 (live post-provision) failed." ;;
            6) step_link_verify           || abort "step 6 (link verify) failed — lock NOT stamped." ;;
            7) step_stamp_lock            || abort "step 7 (stamp lock) failed." ;;
        esac
        record_progress "$step"
    done
}

main() {
    parse_args "$@"
    case "$MODE" in
        rehearse) do_rehearse ;;
        execute)  do_execute ;;
        *)        show_help; exit 1 ;;
    esac
}

main "$@"
