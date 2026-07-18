#!/bin/bash
set -uo pipefail
################################################################################
# scripts/commands/moodle.sh — `pl moodle` command family (PL-STG2LIVE §4, P1-2)
#
# The guarded live-facing Moodle path. RETIRES the unguarded hand-scp idiom
#   scp -r <plugin> $LIVE:/tmp; ssh $LIVE 'rm -rf .../<path>; cp -r ...; chown;
#          php admin/cli/upgrade.php'
# (phase-scripts/phase3.sh, ~/dir/courses_v3/build/install_plugins.sh,
#  scripts/agent-loop/deploy-on-merge.sh) — whose `rm -rf` before `cp` leaves
# the live plugin dir EMPTY on a mid-copy failure with no rollback.
#
# SUBCOMMANDS:
#   pl moodle plugin build  <plugin> [--from=DIR] [--ddev=SITE|--tree=DIR] [--check-only]
#   pl moodle plugin deploy <site> <plugin>... --tier=stg|live [--dry-run|--apply] [--no-upgrade]
#   pl moodle upgrade       <site> --tier=stg|live [--dry-run|--apply] [--no-maintenance]
#   pl moodle backup        <site> --tier=live|stg [--db-only|--code-only] [--dry-run|--apply]
#   pl moodle rollback      <site> --tier=live [list|execute] [--dry-run]
#   pl moodle config        <site> [...]        # alias → moodle-promote.sh
#   pl moodle smoke         <site> [...]        # alias → moodle-smoke.sh
#   pl moodle dev2stg       <site> [...]        # delegation target (== config for stg)
#   pl moodle stg2live      <site> [...]        # delegation target (== plugin deploy live)
#
# HOUSE STYLE: --dry-run by default for every destructive subcommand;
# --apply/--execute required; on live, a typed impact_confirm.
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$REPO_ROOT}"

source "$REPO_ROOT/lib/ui.sh"
source "$REPO_ROOT/lib/common.sh"          # get_site_config_value, get_ssh_user, nwp_ssh_opts, get_server_config
source "$REPO_ROOT/lib/impact.sh"
source "$REPO_ROOT/lib/canonical.sh"       # maturity_guard_deploy
source "$REPO_ROOT/lib/deploy-gate.sh"     # deploy_gate_require
source "$REPO_ROOT/lib/pair.sh"            # pair_guard
source "$REPO_ROOT/lib/rollback.sh"        # ROLLBACK_DIR, rollback_init
source "$REPO_ROOT/lib/rollback-remote.sh"
source "$REPO_ROOT/lib/moodle-promote.sh"  # _mp_cfg, _moodle_is_moodle_site, moodle_purge_caches_cmd
source "$REPO_ROOT/lib/moodle-deploy.sh"

show_help() {
    cat <<EOF
${BOLD}NWP Moodle — guarded plugin build / deploy / upgrade / backup / rollback${NC}

${BOLD}USAGE:${NC}
    pl moodle plugin build  <plugin> [--from=DIR] [--ddev=SITE|--tree=DIR] [--check-only]
    pl moodle plugin deploy <site> <plugin>... --tier=stg|live [--dry-run|--apply] [--no-upgrade]
    pl moodle upgrade       <site> --tier=stg|live [--dry-run|--apply] [--no-maintenance]
    pl moodle backup        <site> --tier=live|stg [--db-only|--code-only] [--dry-run|--apply]
    pl moodle rollback      <site> --tier=live [list|execute] [--dry-run]
    pl moodle config        <site> [...]       # == pl moodle-promote (dev/stg substrate)
    pl moodle smoke         <site> [...]       # == pl moodle-smoke

${BOLD}NOTES:${NC}
    * Destructive subcommands are DRY-RUN by default; pass --apply (deploy/upgrade/
      backup) or 'execute' (rollback). A LIVE --apply requires a typed confirm.
    * Deploys are per-plugin-dir (never the whole webroot). config.php and
      moodledata are structurally out of scope and never touched.
    * The AMD freshness gate fail-closes a stale build — unbuilt JS never ships.
    * <plugin> is a Moodle <type>/<name> id, e.g. mod/depthcontent.
EOF
}

# --- live config resolver (mirrors stg2live.sh get_live_config VERBATIM) ------
get_live_config() {
    local sitename="$1" field="$2"
    local base; base=$(get_base_name "$sitename")
    local yq_path
    case "$field" in
        server_ip)
            local server_name
            server_name=$(get_site_config_value "$base" '.live.server' "")
            if [[ -n "$server_name" ]]; then
                get_server_config "$server_name" "ip" ""
                return
            fi
            get_site_config_value "$base" '.live.server_ip' ""
            return
            ;;
        domain)      yq_path='.live.domain' ;;
        type)        yq_path='.live.type' ;;
        server)      yq_path='.live.server' ;;
        remote_path) yq_path='.live.remote_path' ;;
        *)           yq_path=".live.$field" ;;
    esac
    get_site_config_value "$base" "$yq_path" ""
}

# Resolve site config file + assert moodle. Sets: CONFIG_FILE, BASE.
_resolve_moodle_site() {
    local site="$1"
    BASE=$(get_base_name "$site")
    CONFIG_FILE="$PROJECT_ROOT/sites/$BASE/.nwp.yml"
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "No site config at $CONFIG_FILE"; return 1
    fi
    if ! _moodle_is_moodle_site "$CONFIG_FILE"; then
        print_error "'$BASE' is not a Moodle site (project.type != moodle)."; return 1
    fi
    return 0
}

# Read the configured plugin manifest (paths) from .moodle.plugins[].path.
# Falls back to nothing (caller must pass explicit plugins).
_moodle_configured_plugins() {
    local config_file="$1" yq_bin
    yq_bin="$(_mp_yq 2>/dev/null)" || return 0
    "$yq_bin" eval '.moodle.plugins[].path' "$config_file" 2>/dev/null | grep -v '^null$' || true
}
_moodle_plugin_from() {
    local config_file="$1" path="$2" yq_bin
    yq_bin="$(_mp_yq 2>/dev/null)" || return 0
    "$yq_bin" eval ".moodle.plugins[] | select(.path == \"$path\") | .from" "$config_file" 2>/dev/null | grep -v '^null$' | head -1 || true
}

################################################################################
# plugin build
################################################################################
cmd_plugin_build() {
    local plugin="" from="" ddev="" tree="" check_only="false"
    for a in "$@"; do
        case "$a" in
            --from=*)   from="${a#*=}" ;;
            --ddev=*)   ddev="${a#*=}" ;;
            --tree=*)   tree="${a#*=}" ;;
            --check-only) check_only="true" ;;
            --commit)   print_warning "--commit is a developer/CI step, not part of the deploy pipeline (design C3) — ignored." ;;
            -*)         print_error "Unknown option: $a"; return 1 ;;
            *)          [ -z "$plugin" ] && plugin="$a" || { print_error "Unexpected arg: $a"; return 1; } ;;
        esac
    done
    [ -z "$plugin" ] && { print_error "usage: pl moodle plugin build <type>/<name> [--from=DIR] [--ddev=SITE|--tree=DIR] [--check-only]"; return 1; }

    # Resolve the build tree: --tree wins; else --ddev site's dev tree; else ssc dev.
    local build_tree="$tree"
    if [ -z "$build_tree" ]; then
        local dsite="${ddev:-ssc}"
        build_tree="$PROJECT_ROOT/sites/${dsite}/dev"
    fi

    print_header "Moodle plugin build: ${plugin} ($([ "$check_only" = true ] && echo check-only || echo build))"
    moodle_plugin_build "$plugin" "$build_tree" "$ddev" "$from" "$check_only"
}

################################################################################
# plugin deploy — the guarded per-plugin deploy (§4.3)
################################################################################
cmd_plugin_deploy() {
    local site="" tier="" mode="dry-run" no_upgrade="false"
    local -a plugins=()
    for a in "$@"; do
        case "$a" in
            --tier=*)      tier="${a#*=}" ;;
            --dry-run)     mode="dry-run" ;;
            --apply)       mode="apply" ;;
            --no-upgrade)  no_upgrade="true" ;;
            -*)            print_error "Unknown option: $a"; return 1 ;;
            *)             if [ -z "$site" ]; then site="$a"; else plugins+=("$a"); fi ;;
        esac
    done
    [ -z "$site" ] && { print_error "usage: pl moodle plugin deploy <site> <plugin>... --tier=stg|live [--apply]"; return 1; }
    case "$tier" in stg|live) ;; *) print_error "--tier must be stg or live"; return 1 ;; esac
    _resolve_moodle_site "$site" || return 1

    # Default the deploy set from the configured manifest if none passed.
    if [ "${#plugins[@]}" -eq 0 ]; then
        mapfile -t plugins < <(_moodle_configured_plugins "$CONFIG_FILE")
        [ "${#plugins[@]}" -eq 0 ] && { print_error "No plugins given and none configured under .moodle.plugins in $CONFIG_FILE"; return 1; }
        print_info "Deploy set (from manifest): ${plugins[*]}"
    fi

    # ---- GUARD CHAIN (analogue of stg2live.sh:1391-1441) --------------------
    # 1. live.enabled
    if [ "$tier" = "live" ]; then
        local live_enabled; live_enabled=$(get_live_config "$BASE" "enabled")
        if [ "$live_enabled" = "false" ]; then
            print_error "Live deployment disabled for '$BASE' (live.enabled: false)."; return 1
        fi
    fi
    # 2. deploy set is plugin subdirs only (never config.php / moodledata)
    if ! moodle_deploy_assert_set "${plugins[@]}"; then return 1; fi
    # 3. maturity guard (code-flow class gates HOW code reaches live)
    if ! maturity_guard_deploy "$BASE" "moodle-deploy"; then return 1; fi
    # 4. pair guard (code-only by construction ⇒ passes the coupled-tier rule)
    if ! pair_guard "$BASE" "$tier" "moodle-deploy" "true" "${OVERRIDE_PAIR:-false}"; then return 1; fi
    # 5. freshness gate — every plugin must be built + fresh at source
    local p ts type name from_dir
    for p in "${plugins[@]}"; do
        from_dir="$(_moodle_plugin_from "$CONFIG_FILE" "$p")"
        if ! cmd_plugin_build "$p" ${from_dir:+--from="$from_dir"} --check-only; then
            print_error "Freshness gate FAILED for '$p' — rebuild before deploy (pl moodle plugin build $p)."
            return 1
        fi
    done

    # Resolve remote target.
    local server_ip ssh_user remote_path ssh_opts ssh_target sudo_prefix=""
    if [ "$tier" = "live" ]; then
        server_ip=$(get_live_config "$BASE" "server_ip")
        ssh_user=$(get_ssh_user "$BASE")
        remote_path=$(get_live_config "$BASE" "remote_path"); [ -z "$remote_path" ] && remote_path="/var/www/${BASE}"
        [ "$ssh_user" = "gitlab" ] && sudo_prefix="sudo"
        [ -z "$server_ip" ] && { print_error "No live server configured for $BASE."; return 1; }
    else
        print_error "tier=stg remote deploy target is not configured for Moodle in this milestone (see design §4; stg is a local ddev tier)."
        print_info  "Use 'pl moodle config $BASE --tier=stg --apply' for the stg substrate."
        return 1
    fi
    ssh_opts="$(nwp_ssh_opts "$BASE")"
    ssh_target="${ssh_user}@${server_ip}"

    # 6. deploy gate (ADR-0028 solo-touch) — skipped on dry-run (nothing written)
    if [ "$mode" = "apply" ] && [ "$tier" = "live" ]; then
        deploy_gate_require "$BASE" "live" "rsync ${#plugins[@]} Moodle plugin dir(s) → live webroot (per-plugin --delete)" || return 1
    fi

    # 7. IMPACT fate manifest.
    impact_reset
    for p in "${plugins[@]}"; do
        impact_overwrite "Plugin" "${remote_path}/${p}/  (rsync --delete, amd/src excluded)"
    done
    impact_keep "config.php — env-state, never touched (INV-4)"
    impact_keep "${remote_path%/*}/${BASE}_moodledata / moodledata — live uploads, never touched (INV-5)"
    impact_keep "all other plugins + Moodle core — outside the deploy scope"
    [ "$no_upgrade" = "true" ] && impact_warn "--no-upgrade: admin/cli/upgrade.php will NOT run (version bump deferred)."
    impact_render
    if [ "$mode" = "apply" ] && [ "$tier" = "live" ]; then
        impact_confirm typed "$BASE" "${AUTO_CONFIRM:-false}" || { print_error "aborted."; return 1; }
    fi

    local apply="false"; [ "$mode" = "apply" ] && apply="true"

    # 8. Snapshot plugin dirs BEFORE overwrite (call the backup subcommand path).
    if [ "$apply" = "true" ]; then
        print_header "Pre-deploy snapshot (plugin dirs + DB)"
        moodle_remote_backup "$ssh_target" "$ssh_opts" "$sudo_prefix" "$remote_path" "$BASE" \
            "$server_ip" "$ssh_user" "false" "false" "${plugins[*]}" "true" >/dev/null \
            || { print_error "Pre-deploy snapshot failed — refusing to deploy without a rollback point."; return 1; }
    fi

    # 9. Per-plugin rsync.
    print_header "Deploy plugin dirs → ${ssh_target}:${remote_path}"
    local staging
    for p in "${plugins[@]}"; do
        read -r type name <<<"$(moodle_plugin_split "$p")"
        from_dir="$(_moodle_plugin_from "$CONFIG_FILE" "$p")"
        [ -z "$from_dir" ] && from_dir="${HOME}/nwptoolkit/moodle/plugins/${type}/${name}"
        # staging = the freshly-built plugin in the build tree if present, else source
        staging="$PROJECT_ROOT/sites/${BASE}/dev/${type}/${name}"
        [ -d "$staging" ] || staging="$from_dir"
        moodle_plugin_rsync "$staging" "$type" "$name" "$ssh_target" "$remote_path" \
            "$sudo_prefix" "$ssh_opts" "$apply" || return 1
    done

    # 10. Upgrade unless --no-upgrade.
    if [ "$no_upgrade" != "true" ]; then
        local php_bin; php_bin="$(moodle_cli_php_bin "$CONFIG_FILE")"
        moodle_remote_upgrade "$ssh_target" "$ssh_opts" "$sudo_prefix" "$php_bin" "$remote_path" "$BASE" "false" "$apply" || return 1
        # success → smoke
        if [ "$apply" = "true" ]; then
            print_info "Post-deploy smoke:"
            run_script_smoke "$BASE" "$tier"
        fi
    else
        print_warning "--no-upgrade: skipped admin/cli/upgrade.php (run 'pl moodle upgrade $BASE --tier=$tier --apply' when ready)."
    fi
    [ "$apply" = "true" ] && print_status "OK" "Deploy complete for $BASE@$tier." \
                          || print_status "OK" "Dry run — nothing written. Re-run with --apply."
    return 0
}

run_script_smoke() {
    local site="$1" tier="$2"
    if [ -x "$SCRIPT_DIR/moodle-smoke.sh" ]; then
        "$SCRIPT_DIR/moodle-smoke.sh" "$site" --tier="$tier" --run || print_warning "Smoke reported an issue."
    fi
}

################################################################################
# upgrade (§4.4)
################################################################################
cmd_upgrade() {
    local site="" tier="" mode="dry-run" no_maint="false"
    for a in "$@"; do
        case "$a" in
            --tier=*)          tier="${a#*=}" ;;
            --dry-run)         mode="dry-run" ;;
            --apply)           mode="apply" ;;
            --no-maintenance)  no_maint="true" ;;
            -*)                print_error "Unknown option: $a"; return 1 ;;
            *)                 [ -z "$site" ] && site="$a" || { print_error "Unexpected arg: $a"; return 1; } ;;
        esac
    done
    [ -z "$site" ] && { print_error "usage: pl moodle upgrade <site> --tier=stg|live [--apply] [--no-maintenance]"; return 1; }
    case "$tier" in stg|live) ;; *) print_error "--tier must be stg or live"; return 1 ;; esac
    _resolve_moodle_site "$site" || return 1

    if [ "$tier" != "live" ]; then
        print_error "Standalone remote upgrade is only wired for tier=live in this milestone."
        return 1
    fi
    local live_enabled; live_enabled=$(get_live_config "$BASE" "enabled")
    [ "$live_enabled" = "false" ] && { print_error "Live disabled for '$BASE'."; return 1; }

    local server_ip ssh_user remote_path ssh_opts ssh_target sudo_prefix="" php_bin
    server_ip=$(get_live_config "$BASE" "server_ip")
    ssh_user=$(get_ssh_user "$BASE")
    remote_path=$(get_live_config "$BASE" "remote_path"); [ -z "$remote_path" ] && remote_path="/var/www/${BASE}"
    [ "$ssh_user" = "gitlab" ] && sudo_prefix="sudo"
    [ -z "$server_ip" ] && { print_error "No live server configured."; return 1; }
    ssh_opts="$(nwp_ssh_opts "$BASE")"; ssh_target="${ssh_user}@${server_ip}"
    php_bin="$(moodle_cli_php_bin "$CONFIG_FILE")"

    local apply="false"
    if [ "$mode" = "apply" ]; then
        deploy_gate_require "$BASE" "live" "admin/cli/upgrade.php under maintenance on live" || return 1
        impact_reset
        impact_overwrite "mdl_config_plugins" "plugin version rows bumped by admin/cli/upgrade.php"
        impact_warn "The site enters maintenance mode; upgrade.php is irreversible (no down-hooks). Backup first."
        impact_keep "moodledata — untouched"
        impact_render
        impact_confirm typed "$BASE" "${AUTO_CONFIRM:-false}" || { print_error "aborted."; return 1; }
        apply="true"
        # standalone upgrade takes a --db-only backup first (§4.4 step 2)
        print_header "Pre-upgrade DB snapshot"
        moodle_remote_backup "$ssh_target" "$ssh_opts" "$sudo_prefix" "$remote_path" "$BASE" \
            "$server_ip" "$ssh_user" "true" "false" "" "true" >/dev/null \
            || { print_error "Pre-upgrade DB snapshot failed — refusing standalone upgrade."; return 1; }
    fi

    moodle_remote_upgrade "$ssh_target" "$ssh_opts" "$sudo_prefix" "$php_bin" "$remote_path" "$BASE" "$no_maint" "$apply" || return 1
    [ "$apply" = "true" ] && run_script_smoke "$BASE" "$tier"
    return 0
}

################################################################################
# backup (§4.6)
################################################################################
cmd_backup() {
    local site="" tier="" mode="dry-run" db_only="false" code_only="false"
    for a in "$@"; do
        case "$a" in
            --tier=*)    tier="${a#*=}" ;;
            --db-only)   db_only="true" ;;
            --code-only) code_only="true" ;;
            --dry-run)   mode="dry-run" ;;
            --apply)     mode="apply" ;;
            -*)          print_error "Unknown option: $a"; return 1 ;;
            *)           [ -z "$site" ] && site="$a" || { print_error "Unexpected arg: $a"; return 1; } ;;
        esac
    done
    [ -z "$site" ] && { print_error "usage: pl moodle backup <site> --tier=live|stg [--db-only|--code-only] [--apply]"; return 1; }
    case "$tier" in stg|live) ;; *) print_error "--tier must be live or stg"; return 1 ;; esac
    [ "$db_only" = "true" ] && [ "$code_only" = "true" ] && { print_error "--db-only and --code-only are mutually exclusive"; return 1; }
    _resolve_moodle_site "$site" || return 1
    [ "$tier" = "live" ] || { print_error "Only tier=live remote backup is wired in this milestone."; return 1; }

    local server_ip ssh_user remote_path ssh_opts ssh_target sudo_prefix=""
    server_ip=$(get_live_config "$BASE" "server_ip")
    ssh_user=$(get_ssh_user "$BASE")
    remote_path=$(get_live_config "$BASE" "remote_path"); [ -z "$remote_path" ] && remote_path="/var/www/${BASE}"
    [ "$ssh_user" = "gitlab" ] && sudo_prefix="sudo"
    [ -z "$server_ip" ] && { print_error "No live server configured."; return 1; }
    ssh_opts="$(nwp_ssh_opts "$BASE")"; ssh_target="${ssh_user}@${server_ip}"

    local -a plugins=()
    mapfile -t plugins < <(_moodle_configured_plugins "$CONFIG_FILE")
    local plugin_str="${plugins[*]:-}"

    print_header "Moodle backup: ${BASE}@${tier}"
    local apply="false"; [ "$mode" = "apply" ] && apply="true"
    moodle_remote_backup "$ssh_target" "$ssh_opts" "$sudo_prefix" "$remote_path" "$BASE" \
        "$server_ip" "$ssh_user" "$db_only" "$code_only" "$plugin_str" "$apply"
}

################################################################################
# rollback (§4.6)
################################################################################
cmd_rollback() {
    local site="" tier="" action="list" dry="false"
    for a in "$@"; do
        case "$a" in
            --tier=*)  tier="${a#*=}" ;;
            --dry-run) dry="true" ;;
            list)      action="list" ;;
            execute)   action="execute" ;;
            -*)        print_error "Unknown option: $a"; return 1 ;;
            *)         [ -z "$site" ] && site="$a" || { print_error "Unexpected arg: $a"; return 1; } ;;
        esac
    done
    [ -z "$site" ] && { print_error "usage: pl moodle rollback <site> --tier=live [list|execute] [--dry-run]"; return 1; }
    _resolve_moodle_site "$site" || return 1
    rollback_init

    if [ "$action" = "list" ]; then
        print_header "Moodle rollback points: ${BASE}"
        local found=0 f
        for f in "${ROLLBACK_DIR}/${BASE}_"*.json; do
            [ -e "$f" ] || continue
            grep -q '"type": *"moodle-remote"' "$f" 2>/dev/null || continue
            local ts st; ts=$(grep -m1 '"timestamp"' "$f" | sed 's/.*: *"\([^"]*\)".*/\1/')
            st=$(grep -m1 '"status"' "$f" | sed 's/.*: *"\([^"]*\)".*/\1/')
            echo "  ${ts}  [${st}]  $(basename "$f")"
            found=$((found+1))
        done
        [ "$found" -eq 0 ] && print_info "No moodle-remote rollback points for ${BASE}."
        return 0
    fi

    # execute → newest active moodle-remote entry
    local entry
    entry=$(ls -1 "${ROLLBACK_DIR}/${BASE}_live_"*.json 2>/dev/null \
        | xargs -I{} grep -l '"type": *"moodle-remote"' {} 2>/dev/null | sort | tail -1 || true)
    [ -z "$entry" ] && { print_error "No moodle-remote rollback point for ${BASE}@live."; return 1; }
    local apply="true"; [ "$dry" = "true" ] && apply="false"
    NWP_SSH_OPTS="$(nwp_ssh_opts "$BASE")" moodle_remote_rollback_execute "$entry" "$(nwp_ssh_opts "$BASE")" "$apply"
}

################################################################################
# Dispatch
################################################################################
[ "$#" -eq 0 ] && { show_help; exit 1; }
SUB="$1"; shift || true
case "$SUB" in
    -h|--help|help) show_help; exit 0 ;;
    plugin)
        PSUB="${1:-}"; shift || true
        case "$PSUB" in
            build)  cmd_plugin_build  "$@" ;;
            deploy) cmd_plugin_deploy "$@" ;;
            *) print_error "Unknown 'plugin' subcommand: ${PSUB:-（none）} (build|deploy)"; exit 1 ;;
        esac
        ;;
    upgrade)   cmd_upgrade  "$@" ;;
    backup)    cmd_backup   "$@" ;;
    rollback)  cmd_rollback "$@" ;;
    # Back-compat / substrate aliases.
    config)    exec "$SCRIPT_DIR/moodle-promote.sh" "$@" ;;
    smoke)     exec "$SCRIPT_DIR/moodle-smoke.sh" "$@" ;;
    # Delegation targets: `pl stg2live/dev2stg <moodle-site>` route here.
    dev2stg)   exec "$SCRIPT_DIR/moodle-promote.sh" "$@" ;;
    stg2live)  cmd_plugin_deploy "$@" --tier=live ;;
    *) print_error "Unknown moodle subcommand: $SUB"; show_help; exit 1 ;;
esac
exit $?
