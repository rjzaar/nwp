#!/bin/bash
set -euo pipefail
################################################################################
# scripts/commands/demo.sh — daily-reset demo tier (ops#133 Phase 1)
#
# The nwd demo pair's operational surface (DAILY-DEMO-TIER-PROPOSAL-2026-07-25,
# decisions §4): capture a golden image, reset the site back to it nightly
# (activity-guarded), and manage the hashed invite-code registry the
# nwc_demo_access module redeems against.
#
#   pl demo golden <site>                     capture current state as golden
#   pl demo reset  <site> [--if-idle 30m]     verified restore + reseed + cr
#   pl demo nightly <site>                    scheduled entrypoint (retry loop)
#   pl demo status <site>                     last reset/skips, golden, codes
#   pl demo codes  <site> list|issue|revoke|rotate|sync
#   pl demo schedule <site> [--remove]        install the 01:00 Melbourne cron
#
# GUARDS (fail-closed):
#   * reset only proceeds when the golden manifest names THIS site and both
#     artifacts pass sha256 verification (demo_golden_verify).
#   * reset is tier-scoped: dev|stg only in Phase 1. --tier=live is REFUSED —
#     the nwd live cutover is a follow-up after operator review.
#   * --if-idle treats a failed/garbled sessions query as ACTIVE (never
#     green-lights a wipe on bad data); "active" exits DEMO_EXIT_ACTIVE (3),
#     distinct from errors, so the nightly wrapper can retry.
#   * codes are hashed (sha256) before they ever touch disk or the site;
#     `issue`/`rotate` print the plaintext exactly ONCE and never store it.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/demo.sh"

# Names of the golden artifacts inside sites/<site>/demo-golden/.
GOLDEN_DB="golden.db.sql.gz"
GOLDEN_FILES="golden.files.tar.gz"

show_help() {
    cat <<EOF
${BOLD}NWP Demo — daily-reset demo tier (ops#133 Phase 1)${NC}

${BOLD}USAGE:${NC}
    pl demo <subcommand> <site> [options]

${BOLD}SUBCOMMANDS:${NC}
    golden <site>                 Capture the current state as the golden image
                                  (verified DB dump + files tar + manifest under
                                  sites/<site>/demo-golden/)
    reset <site> [--if-idle 30m] [--force] [--yes] [--skip-seed]
                                  Pre-wipe error harvest (watchdog → spool,
                                  fail-open), then verified restore of the
                                  golden image, drush nwc:seed-demo, code
                                  re-sync, cache rebuild. --if-idle: skip
                                  (exit 3) if any session was active within
                                  the window.
    nightly <site>                Scheduled entrypoint: reset --if-idle 30m,
                                  retrying every 30 min until the 04:00
                                  ${DEMO_TZ} floor, then skip + log.
    status <site>                 Golden capture info, recent resets/skips,
                                  invite-code summary.
    codes <site> list             List codes (hashes only — never plaintext)
    codes <site> issue <bundle> [--expires=14d]
                                  Issue a code; plaintext printed ONCE.
    codes <site> revoke <id>      Revoke a code (kept in registry as audit row)
    codes <site> rotate           Revoke every live code, reissue one per
                                  bundle that had one (new plaintexts, once)
    codes <site> sync             Re-push the hashed registry into the site
    schedule <site> [--remove]    Install/remove the nightly cron on THIS
                                  machine (intended host: met)

${BOLD}OPTIONS:${NC}
    --tier=dev|stg     Which local instance to act on (default: dev).
                       --tier=live is REFUSED in Phase 1 (nwd cutover is a
                       follow-up after operator review).
    --if-idle <dur>    Only reset when no session activity within <dur>
                       (e.g. 30m). Active → exit ${DEMO_EXIT_ACTIVE} (retryable), logged as skip.
    --force            Override the interactive confirmation (same as --yes).
    --skip-seed        Skip drush nwc:seed-demo after restore (non-nwc sites).
    --expires=<dur>    Code lifetime for issue/rotate (default: 14d).

${BOLD}ROLE BUNDLES${NC} (decisions §4.4 — sitemanager is never offered):
    tester-member                 Open Social 'verified' member
    tester-guild-leader           member + Tester's Guild leadership role
    tester-content-manager        Open Social 'contentmanager' (NOT sitemanager)
    tester-copyright-reviewer     + copyright_reviewer role
    tester-safeguarding-reviewer  + safeguarding_reviewer role

${BOLD}FILES:${NC}
    sites/<site>/demo-golden/     golden image + .sha256 sidecars + manifest
    sites/<site>/demo-codes.json  hashed code registry (survives the wipe)
    sites/<site>/demo-reset.log   every reset / skip / harvest, one line each
    sites/<site>/demo-harvest/    pre-wipe error digests (labels
                                  demo-tester,auto-harvest; GitLab posting is
                                  wired at the nwd cutover)
EOF
}

################################################################################
# Small helpers (ddev plumbing — kept out of lib/demo.sh for testability)
################################################################################

# The site's DDEV project dir for the tier.
demo_project_dir() {
    local site="$1" tier="$2"
    local dir
    dir="$(resolve_project "$site" "$tier")" || return 1
    [[ -d "$dir" && -d "$dir/.ddev" ]] || {
        print_error "No DDEV project for '$site' tier '$tier' at $dir"
        return 1
    }
    echo "$dir"
}

# The docroot (web/ or html/) read from .ddev/config.yaml — fail-closed.
demo_docroot() {
    local proj="$1" droot
    droot="$(awk '/^docroot:/ {print $2; exit}' "$proj/.ddev/config.yaml" 2>/dev/null)"
    if [[ -z "$droot" ]]; then
        # ddev default docroot is the project root; nwp sites always set one.
        for d in web html; do [[ -d "$proj/$d/sites/default" ]] && { echo "$d"; return 0; }; done
        print_error "Cannot determine docroot for $proj"
        return 1
    fi
    echo "$droot"
}

demo_drush() {
    local proj="$1"; shift
    ( cd "$proj" && ddev drush "$@" )
}

# Refuse anything but dev|stg in Phase 1 (live lands with the nwd cutover).
demo_check_tier() {
    local tier="$1"
    case "$tier" in
        dev|stg) return 0 ;;
        live|prod)
            print_error "Phase 1 is local-only: --tier=$tier is REFUSED."
            print_info  "The nwd live cutover (remote golden restore + schedule on met) is the follow-up after operator review."
            return 1 ;;
        *)
            print_error "Unknown tier '$tier' (dev|stg)"
            return 1 ;;
    esac
}

# Push the live (non-revoked, non-expired) hashed codes into the site's state
# entry. Runs after every code change and after every reset.
demo_sync_codes_to_site() {
    local site="$1" tier="$2"
    local proj payload
    proj="$(demo_project_dir "$site" "$tier")" || return 1
    payload="$(demo_codes_payload "$(demo_codes_file "$site")")" || return 1
    if demo_drush "$proj" state:set nwc_demo_access.codes "$payload" >/dev/null 2>&1; then
        demo_log "$site" codes-synced "tier=$tier"
        return 0
    fi
    print_warning "Could not sync codes into the site (is $site-$tier running with nwc_demo_access enabled?)"
    print_hint "Re-run later: pl demo codes $site sync"
    return 1
}

# Collector for the pre-wipe error harvest: watchdog Error + Critical rows
# (the wipe destroys watchdog) plus a best-effort PHP error-log tail. Output
# on stdout; demo_harvest spools it if non-empty. Any failure here is caught
# by demo_harvest's fail-open contract.
demo_harvest_collect() {
    local proj="$1"
    demo_drush "$proj" watchdog:show --severity=Error --count=100 --format=table 2>/dev/null || true
    demo_drush "$proj" watchdog:show --severity=Critical --count=100 --format=table 2>/dev/null || true
    # PHP error log, when the container exposes one (best-effort, never fatal).
    ( cd "$proj" && ddev exec 'test -f /var/log/php-fpm-error.log && tail -n 50 /var/log/php-fpm-error.log' 2>/dev/null ) || true
}

################################################################################
# golden — capture the current state as the golden image
################################################################################

cmd_golden() {
    local site="$1" tier="$2"
    local proj droot gdir
    proj="$(demo_project_dir "$site" "$tier")" || return 1
    droot="$(demo_docroot "$proj")" || return 1
    gdir="$(demo_golden_dir "$site")"
    mkdir -p "$gdir"

    print_header "Capturing golden image: $site ($tier)"

    # 1. DB dump (ddev export-db handles credentials + gzip).
    print_info "Exporting database…"
    ( cd "$proj" && ddev export-db --file="$gdir/$GOLDEN_DB" --gzip ) >/dev/null || {
        print_error "ddev export-db failed"
        return 1
    }

    # 2. Files tar (sites/default/files).
    local files_parent="$proj/$droot/sites/default"
    [[ -d "$files_parent/files" ]] || {
        print_error "No files directory at $files_parent/files"
        return 1
    }
    print_info "Archiving files…"
    tar -czf "$gdir/$GOLDEN_FILES" -C "$files_parent" files || {
        print_error "files tar failed"
        return 1
    }

    # 3. sha256 sidecars (format matches sha256sum -c).
    local f
    for f in "$GOLDEN_DB" "$GOLDEN_FILES"; do
        ( cd "$gdir" && sha256sum "$f" > "$f.sha256" ) || {
            print_error "sha256 sidecar failed for $f"
            return 1
        }
    done

    # 4. Manifest, then verify the whole set exactly as reset will.
    demo_manifest_write "$gdir" "$site" "$GOLDEN_DB" "$GOLDEN_FILES" || return 1
    demo_golden_verify "$gdir" "$site" || {
        print_error "Post-capture verification failed — golden NOT usable"
        return 1
    }

    demo_log "$site" golden-captured "tier=$tier db=$(du -h "$gdir/$GOLDEN_DB" | cut -f1) files=$(du -h "$gdir/$GOLDEN_FILES" | cut -f1)"
    print_status "OK" "Golden image captured + verified: $gdir"
    print_hint "Nightly restore will return $site to exactly this state."
}

################################################################################
# reset — verified restore of the golden image
################################################################################

cmd_reset() {
    local site="$1" tier="$2" if_idle="$3" auto_yes="$4" skip_seed="$5"
    local proj droot gdir start_ts
    start_ts=$(date +%s)
    proj="$(demo_project_dir "$site" "$tier")" || return 1
    droot="$(demo_docroot "$proj")" || return 1
    gdir="$(demo_golden_dir "$site")"

    print_header "Demo reset: $site ($tier)"

    # 1. Fail-closed golden verification (site match + sha256 both artifacts).
    demo_golden_verify "$gdir" "$site" || {
        demo_log "$site" reset-failed "tier=$tier reason=golden-verify"
        return 1
    }
    print_status "OK" "Golden image verified (sha256 + manifest site match)"

    # 2. Activity guard (--if-idle). A failed sessions query counts as ACTIVE:
    #    never wipe on bad data.
    if [[ -n "$if_idle" ]]; then
        local window newest
        window="$(demo_parse_duration "$if_idle")" || {
            print_error "Bad --if-idle duration: '$if_idle' (use e.g. 30m)"
            return 1
        }
        newest="$(demo_drush "$proj" sqlq \
            'SELECT COALESCE(MAX(timestamp),0) FROM sessions' 2>/dev/null | tr -d '[:space:]')" || newest=""
        if ! demo_idle_ok "$newest" "$window"; then
            demo_log "$site" skip-active "tier=$tier window=${if_idle} newest=${newest:-query-failed}"
            print_status "WARN" "Session activity within ${if_idle} (newest=${newest:-query-failed}) — NOT resetting (exit ${DEMO_EXIT_ACTIVE})"
            return "$DEMO_EXIT_ACTIVE"
        fi
        print_status "OK" "Idle for ≥ ${if_idle} — safe to reset"
    fi

    # 3. Confirm (destructive). --force/--yes for the scheduler.
    if [[ "$auto_yes" != "true" ]]; then
        printf 'This will ERASE the current %s (%s) DB+files and restore the golden image. Continue? [y/N]: ' "$site" "$tier"
        local reply; read -r reply
        [[ "$reply" =~ ^[Yy]$ ]] || { print_info "Aborted."; return 1; }
    fi

    # 3.5 PRE-WIPE ERROR HARVEST (fail-OPEN — must never block the reset).
    #     Runs strictly BEFORE import-db: the restore destroys watchdog, and
    #     testers only report what they notice. demo_harvest always returns 0;
    #     the `|| true` is belt-and-braces against set -e.
    print_info "Harvesting error signals before the wipe…"
    demo_harvest "$site" "$tier" demo_harvest_collect "$proj" || true

    # 4. Restore DB.
    print_info "Restoring database from golden…"
    ( cd "$proj" && ddev import-db --file="$gdir/$GOLDEN_DB" ) >/dev/null || {
        demo_log "$site" reset-failed "tier=$tier reason=import-db"
        print_error "ddev import-db failed"
        return 1
    }

    # 5. Restore files (delete-then-untar so removed files don't linger).
    print_info "Restoring files from golden…"
    local files_parent="$proj/$droot/sites/default"
    rm -rf "$files_parent/files"
    tar -xzf "$gdir/$GOLDEN_FILES" -C "$files_parent" || {
        demo_log "$site" reset-failed "tier=$tier reason=files-untar"
        print_error "files untar failed"
        return 1
    }

    # 6. Reseed the demo account matrix (nwc profile sites). Deliberately NOT
    #    --force: if real members somehow appear post-restore, seed-demo's own
    #    guard refuses and the reset fails loudly.
    if [[ "$skip_seed" != "true" ]]; then
        print_info "Reseeding demo accounts (drush nwc:seed-demo)…"
        if ! demo_drush "$proj" nwc:seed-demo >/dev/null 2>&1; then
            demo_log "$site" reset-failed "tier=$tier reason=seed-demo"
            print_error "drush nwc:seed-demo failed (use --skip-seed for non-nwc sites)"
            return 1
        fi
    fi

    # 7. Re-push the invite-code registry (the wipe just erased the state
    #    entry; the local registry is the source of truth). Non-fatal: codes
    #    can be re-synced, the reset itself succeeded.
    demo_sync_codes_to_site "$site" "$tier" || true

    # 8. Cache rebuild.
    demo_drush "$proj" cr >/dev/null 2>&1 || print_warning "drush cr failed (non-fatal)"

    local took=$(( $(date +%s) - start_ts ))
    demo_log "$site" reset-ok "tier=$tier took=${took}s"
    print_status "OK" "Demo reset complete in ${took}s — $site ($tier) is back at the golden image"
}

################################################################################
# nightly — scheduled entrypoint with the §4.3 retry loop
################################################################################

cmd_nightly() {
    local site="$1" tier="$2"
    local rc now
    while true; do
        set +e
        cmd_reset "$site" "$tier" "30m" "true" "false"
        rc=$?
        set -e
        if [[ "$rc" -ne "$DEMO_EXIT_ACTIVE" ]]; then
            return "$rc"   # success (0) or hard failure (≠0,≠3) — both final
        fi
        now="$(TZ="$DEMO_TZ" date '+%H:%M')"
        if demo_past_floor "$now"; then
            demo_log "$site" skip-floor "tier=$tier now=$now floor=$DEMO_FLOOR_TIME"
            print_status "WARN" "Still active at the ${DEMO_FLOOR_TIME} ${DEMO_TZ} floor — skipping tonight's reset (logged)"
            return 0
        fi
        print_info "Active session — retrying in $(( DEMO_RETRY_SECONDS / 60 )) min (floor ${DEMO_FLOOR_TIME} ${DEMO_TZ}, now ${now})"
        sleep "$DEMO_RETRY_SECONDS"
    done
}

################################################################################
# status
################################################################################

cmd_status() {
    local site="$1"
    local gdir cfile lfile
    gdir="$(demo_golden_dir "$site")"
    cfile="$(demo_codes_file "$site")"
    lfile="$(demo_log_file "$site")"

    print_header "Demo status: $site"

    if [[ -f "$gdir/golden.manifest.json" ]]; then
        echo "  Golden image:"
        echo "    captured: $(jq -r '.captured_utc' "$gdir/golden.manifest.json" 2>/dev/null)"
        echo "    db:       $GOLDEN_DB ($(du -h "$gdir/$GOLDEN_DB" 2>/dev/null | cut -f1))"
        echo "    files:    $GOLDEN_FILES ($(du -h "$gdir/$GOLDEN_FILES" 2>/dev/null | cut -f1))"
        if demo_golden_verify "$gdir" "$site" >/dev/null 2>&1; then
            print_status "OK" "Golden verifies (sha256)"
        else
            print_status "FAIL" "Golden does NOT verify — recapture before the next reset"
        fi
    else
        print_status "WARN" "No golden image captured yet (pl demo golden $site)"
    fi

    echo ""
    echo "  Invite codes:"
    if [[ -f "$cfile" ]] && command -v jq >/dev/null 2>&1; then
        local now; now="$(date +%s)"
        jq -r --argjson now "$now" '
            .codes[] |
            [ .id, .bundle,
              (if .revoked then "revoked" elif .expires <= $now then "expired" else "live" end),
              (.expires | todate) ] | @tsv' "$cfile" 2>/dev/null \
        | awk -F'\t' 'BEGIN { printf "    %-5s %-30s %-8s %s\n", "id", "bundle", "state", "expires" }
                      { printf "    %-5s %-30s %-8s %s\n", $1, $2, $3, $4 }'
    else
        echo "    (no code registry — pl demo codes $site issue <bundle>)"
    fi

    echo ""
    echo "  Recent resets/skips (last 10):"
    if [[ -f "$lfile" ]]; then
        tail -n 10 "$lfile" | sed 's/^/    /'
        if tail -n 3 "$lfile" | grep -q "skip-"; then
            print_status "WARN" "Recent skip present — check activity guard / floor"
        fi
    else
        echo "    (no resets logged yet)"
    fi
}

################################################################################
# codes
################################################################################

cmd_codes() {
    local site="$1" tier="$2" action="$3"; shift 3 || true
    local cfile; cfile="$(demo_codes_file "$site")"
    demo_require_jq || return 1

    case "$action" in
        list)
            cmd_status "$site" | sed -n '/Invite codes:/,/Recent resets/p' | head -n -1
            print_info "Only sha256 hashes are stored — plaintext codes are shown once at issue time."
            ;;
        issue)
            local bundle="${1:-}" expires_in="14d" a
            for a in "$@"; do [[ "$a" == --expires=* ]] && expires_in="${a#--expires=}"; done
            [[ -n "$bundle" ]] || { print_error "Usage: pl demo codes <site> issue <bundle> [--expires=14d]"; return 1; }
            demo_bundle_valid "$bundle" || {
                print_error "Unknown bundle '$bundle'. Valid: ${DEMO_BUNDLES[*]}"
                return 1
            }
            local secs code hash id expires
            secs="$(demo_parse_duration "$expires_in")" || { print_error "Bad --expires duration '$expires_in'"; return 1; }
            code="$(demo_generate_code)" || { print_error "Code generation failed"; return 1; }
            hash="$(demo_hash_code "$code")"
            id="$(demo_next_code_id "$cfile")"
            expires=$(( $(date +%s) + secs ))
            demo_code_add "$cfile" "$id" "$bundle" "$hash" "$expires" || return 1
            demo_log "$site" codes-issued "id=$id bundle=$bundle expires_in=$expires_in"
            print_header "Invite code issued (${bundle})"
            echo ""
            echo "    ${BOLD}${code}${NC}"
            echo ""
            print_status "WARN" "Shown ONCE — only its sha256 hash is stored ($id, expires $(date -d "@$expires" '+%Y-%m-%d'))."
            print_info "Distribute to INVITED helpers only (decisions §4.2 — never post publicly)."
            demo_sync_codes_to_site "$site" "$tier" || true
            ;;
        revoke)
            local id="${1:-}"
            [[ -n "$id" ]] || { print_error "Usage: pl demo codes <site> revoke <id>"; return 1; }
            demo_code_revoke "$cfile" "$id" || return 1
            demo_log "$site" codes-revoked "id=$id"
            print_status "OK" "Revoked $id"
            demo_sync_codes_to_site "$site" "$tier" || true
            ;;
        rotate)
            local bundles b now
            bundles="$(demo_active_bundles "$cfile")"
            [[ -n "$bundles" ]] || { print_info "No live codes to rotate."; return 0; }
            now="$(date +%s)"
            # Revoke every live code…
            while IFS= read -r cid; do
                demo_code_revoke "$cfile" "$cid"
            done < <(jq -r --argjson now "$now" \
                '.codes[] | select(.revoked == false and .expires > $now) | .id' "$cfile")
            demo_log "$site" codes-rotated ""
            print_status "OK" "All live codes revoked."
            # …then reissue one per bundle that had one (each prints once).
            while IFS= read -r b; do
                cmd_codes "$site" "$tier" issue "$b"
            done <<< "$bundles"
            ;;
        sync)
            demo_sync_codes_to_site "$site" "$tier"
            ;;
        *)
            print_error "Unknown codes action '$action' (list|issue|revoke|rotate|sync)"
            return 1
            ;;
    esac
}

################################################################################
# schedule — nightly cron on THIS machine (intended host: met)
################################################################################

cmd_schedule() {
    local site="$1" remove="$2"
    local marker="# NWP Demo Reset - $site"
    local current
    current="$(crontab -l 2>/dev/null || true)"
    # Drop any existing entry (idempotent install / clean removal). The install
    # writes a 3-line block (marker, CRON_TZ, command) — remove the whole block
    # by marker, plus any stray command line as belt-and-braces.
    local cleaned
    cleaned="$(printf '%s\n' "$current" \
        | awk -v m="$marker" 'index($0, m) == 1 { skip = 3 } skip > 0 { skip--; next } { print }' \
        | grep -v "pl demo nightly $site\b" || true)"

    if [[ "$remove" == "true" ]]; then
        printf '%s\n' "$cleaned" | crontab -
        print_status "OK" "Removed demo-reset cron for $site (if present)"
        return 0
    fi

    mkdir -p "$PROJECT_ROOT/logs"
    # CRON_TZ pins the fire time to Melbourne regardless of host TZ (handles
    # DST; supported by ISC/vixie cron on Ubuntu 22.04+). The retry semantics
    # (every 30 min to a 04:00 floor) live in `pl demo nightly`, keeping cron
    # itself a single dumb line.
    local entry="CRON_TZ=${DEMO_TZ}
0 1 * * * ${PROJECT_ROOT}/pl demo nightly ${site} >> ${PROJECT_ROOT}/logs/demo-nightly-${site}.log 2>&1"
    printf '%s\n%s\n%s\n' "$cleaned" "$marker" "$entry" | crontab -
    print_status "OK" "Installed nightly demo reset for $site (01:00 ${DEMO_TZ}, retries to ${DEMO_FLOOR_TIME})"
    print_info "Runs on THIS machine's crontab — the production schedule belongs on met (pl schedule host)."
    print_hint "Verify: crontab -l | grep -A2 'NWP Demo Reset'"
}

################################################################################
# main
################################################################################

main() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        -h|--help|"") show_help; return 0 ;;
    esac

    local site="${1:-}"; shift || true
    [[ -n "$site" ]] || { print_error "Site name required."; show_help; return 1; }

    # Common option parse (subcommand-specific positionals pass through).
    local tier="dev" if_idle="" auto_yes="false" skip_seed="false" remove="false"
    local passthru=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tier=*)   tier="${1#--tier=}"; shift ;;
            --if-idle)  if_idle="${2:-}"; shift 2 ;;
            --if-idle=*) if_idle="${1#--if-idle=}"; shift ;;
            --force|--yes|-y) auto_yes="true"; shift ;;
            --skip-seed) skip_seed="true"; shift ;;
            --remove)   remove="true"; shift ;;
            *)          passthru+=("$1"); shift ;;
        esac
    done

    demo_check_tier "$tier" || return 1

    case "$sub" in
        golden)   cmd_golden "$site" "$tier" ;;
        reset)    cmd_reset "$site" "$tier" "$if_idle" "$auto_yes" "$skip_seed" ;;
        nightly)  cmd_nightly "$site" "$tier" ;;
        status)   cmd_status "$site" ;;
        codes)    cmd_codes "$site" "$tier" "${passthru[@]:-list}" ;;
        schedule) cmd_schedule "$site" "$remove" ;;
        *)        print_error "Unknown subcommand: $sub"; show_help; return 1 ;;
    esac
}

main "$@"
