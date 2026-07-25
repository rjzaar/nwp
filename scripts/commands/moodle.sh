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
source "$REPO_ROOT/lib/moodle-gate.sh"     # ops#137 Art.9 ship-together assertion

show_help() {
    cat <<EOF
${BOLD}NWP Moodle — guarded plugin build / deploy / upgrade / backup / rollback${NC}

${BOLD}USAGE:${NC}
    pl moodle plugin build  <plugin> [--from=DIR] [--ddev=SITE|--tree=DIR] [--check-only]
    pl moodle plugin deploy <site> <plugin>... --tier=stg|live [--dry-run|--apply] [--no-upgrade]
    pl moodle plugins sync  <site> [--tier=dev|live] [--ref=REF] [--dry-run|--apply]
    pl moodle gate-status   <site> [--no-live]     # == pl moodle plugins status
    pl moodle upgrade       <site> --tier=stg|live [--dry-run|--apply] [--no-maintenance]
    pl moodle backup        <site> --tier=live|stg [--db-only|--code-only] [--dry-run|--apply]
    pl moodle rollback      <site> --tier=live [list|execute] [--dry-run]
    pl moodle config        <site> [...]       # == pl moodle-promote (dev/stg substrate)
    pl moodle smoke         <site> [...]       # == pl moodle-smoke

${BOLD}PLUGIN SOURCE (ops#137):${NC}
    Resolution order for each plugin's source directory — FIRST HIT WINS:
      1. --from=DIR                        explicit, this invocation only
      2. .moodle.plugins[].from            per-plugin config override
      3. sites/<site>/.plugin-src/<repo>/  only when forced with --from-canonical
      4. ~/nwptoolkit/moodle/plugins/...   only when forced with --from-nwptoolkit
      5. sites/<site>/dev/<type>/<name>    dev build tree        ← DEFAULT
      6. sites/<site>/.plugin-src/<repo>/  canonical repo cache — the FALLBACK
                                           that used to be ~/nwptoolkit
    The dev tree remains the default promotion source. Only the fallback moved:
    ~/nwptoolkit is a stale 2026-07-03 snapshot with NO Art.9 consent gate and
    no auth/nwc, local/mentor or local/practice at all, and is no longer
    reachable without its flag. Sync the cache: pl moodle plugins sync <site> --apply.

    A dev tree can itself be ungated (ss and ss2 carry a pre-gate depthcontent
    today), so precedence alone cannot establish the invariant — the artifact
    assertion below is what actually enforces it.

${BOLD}NOTES:${NC}
    * Destructive subcommands are DRY-RUN by default; pass --apply (deploy/upgrade/
      backup) or 'execute' (rollback). A LIVE --apply requires a typed confirm.
    * Deploys are per-plugin-dir (never the whole webroot). config.php and
      moodledata are structurally out of scope and never touched.
    * The AMD freshness gate fail-closes a stale build — unbuilt JS never ships.
    * The Art.9 ship-together assertion fail-closes an UNGATED artifact: a plugin
      that handles formation data must carry the consent gate in the bytes that
      ship. Override deliberately with --allow-ungated (loudly ledgered).
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
# ops#137 — plugin source resolution
#
# WHAT WAS ACTUALLY BROKEN (verified against origin/main, 2026-07-25):
#
#   ship path  (old L246-253): staging = sites/<site>/dev/<type>/<name> if that
#              dir exists, ELSE .moodle.plugins[].from, ELSE ~/nwptoolkit.
#   check path (old L188-193): from_dir = .moodle.plugins[].from ELSE
#              ~/nwptoolkit — the dev tree was NEVER consulted.
#
# So the two halves disagreed: for ssc the AMD freshness gate validated the
# UNGATED ~/nwptoolkit snapshot while the rsync shipped the GATED dev tree.
# Checking one tree and shipping another is the structural defect; it makes any
# pre-flight assertion meaningless. Everything below resolves ONCE so the gate,
# the freshness check and the rsync all see the same bytes.
#
# The dev tree stays the DEFAULT — it is the working promotion source for ssc
# and the ssd rebuild depends on it. Only the *fallback* moves: ~/nwptoolkit
# (a stale 2026-07-03 snapshot with no Art.9 gate, no auth/nwc, no local/mentor
# and no local/practice) is replaced by the canonical repo cache and is no
# longer reachable without an explicit opt-in flag.
#
# RESOLUTION ORDER (first hit wins):
#   1. --from=DIR                       explicit per-invocation flag
#   2. .moodle.plugins[].from           per-plugin config override
#   3. <site>/.plugin-src/<repo>/<p>    ONLY when forced with --from-canonical
#   4. ~/nwptoolkit/moodle/plugins/<p>  ONLY when forced with --from-nwptoolkit
#   5. <site>/dev/<type>/<name>         dev build tree            ← DEFAULT
#   6. <site>/.plugin-src/<repo>/<p>    canonical repo cache — the FALLBACK that
#                                       used to be ~/nwptoolkit
#   (none)                              REFUSE, point at `pl moodle plugins sync`
#
# NOTE: a dev tree can itself be ungated (ss and ss2 both carry a pre-gate
# mod/depthcontent today, and both are live.enabled). Source precedence alone
# therefore CANNOT establish the Art.9 invariant — only the artifact-level
# assertion in lib/moodle-gate.sh can. That is why the assertion, not this
# ordering, is the load-bearing half of ops#137.
################################################################################

# Repo PATH only — the GitLab host is derived from configured settings
# (nwp.yml settings.url via get_gitlab_url), never hardcoded here.
MOODLE_PLUGINS_REPO_PATH="${MOODLE_PLUGINS_REPO_PATH:-nwp/ss-moodle-plugins}"

# Echo the plugin repo URL: .moodle.plugins_repo wins; otherwise derive
# git@<configured-gitlab-host>:<path>.git. Empty ⇒ caller must refuse.
_moodle_plugins_repo() {
    local config_file="$1" yq_bin v="" host=""
    if yq_bin="$(_mp_yq 2>/dev/null)"; then
        v="$("$yq_bin" eval '.moodle.plugins_repo' "$config_file" 2>/dev/null | grep -v '^null$' | head -1 || true)"
    fi
    if [ -n "$v" ]; then echo "$v"; return 0; fi
    if ! declare -F get_gitlab_url >/dev/null 2>&1; then
        [ -f "$REPO_ROOT/lib/git.sh" ] && source "$REPO_ROOT/lib/git.sh" 2>/dev/null || true
    fi
    if declare -F get_gitlab_url >/dev/null 2>&1; then
        host="$(get_gitlab_url 2>/dev/null || true)"
    fi
    [ -n "$host" ] && echo "git@${host}:${MOODLE_PLUGINS_REPO_PATH}.git" || echo ""
}
_moodle_plugins_ref() {
    local config_file="$1" yq_bin v=""
    yq_bin="$(_mp_yq 2>/dev/null)" || { echo "main"; return 0; }
    v="$("$yq_bin" eval '.moodle.plugins_ref' "$config_file" 2>/dev/null | grep -v '^null$' | head -1 || true)"
    echo "${v:-main}"
}
# Canonical local cache for a site's plugin repo (gitignored, per design §4.1).
# A repo URL that cannot be derived still yields a stable cache path, so
# gate-status keeps working on an already-synced cache.
_moodle_plugin_cache() {
    local base="$1" repo="${2:-}"
    local name
    name="$(basename "${repo%.git}")"
    [ -z "$name" ] && name="$(basename "$MOODLE_PLUGINS_REPO_PATH")"
    echo "$PROJECT_ROOT/sites/${base}/.plugin-src/${name}"
}

# _moodle_resolve_source <config> <base> <plugin> [explicit_from] [force_nwptoolkit] [force_canonical]
# Sets MOODLE_SRC_DIR + MOODLE_SRC_ORIGIN. Returns 1 (with guidance) if nothing
# resolves — silently falling through to a stale tree is exactly the bug.
_moodle_resolve_source() {
    local config_file="$1" base="$2" plugin="$3"
    local explicit="${4:-}" force_toolkit="${5:-false}" force_canonical="${6:-false}"
    MOODLE_SRC_DIR=""; MOODLE_SRC_ORIGIN=""

    # 1. explicit flag
    if [ -n "$explicit" ]; then
        MOODLE_SRC_DIR="${explicit%/}"; MOODLE_SRC_ORIGIN="flag:--from"; return 0
    fi
    # 2. per-plugin config override
    local cfg_from; cfg_from="$(_moodle_plugin_from "$config_file" "$plugin")"
    if [ -n "$cfg_from" ]; then
        MOODLE_SRC_DIR="${cfg_from%/}"; MOODLE_SRC_ORIGIN="config:.moodle.plugins[].from"
        case "$MOODLE_SRC_DIR" in
            *nwptoolkit*) _moodle_warn_nwptoolkit "$MOODLE_SRC_DIR" "config" ;;
        esac
        return 0
    fi

    local dev_dir="$PROJECT_ROOT/sites/${base}/dev/${plugin}"
    local cache_dir; cache_dir="$(_moodle_plugin_cache "$base" "$(_moodle_plugins_repo "$config_file")")/${plugin}"

    local toolkit="${HOME}/nwptoolkit/moodle/plugins/${plugin}"

    # 3/4. Forcing flags — explicit intent overrides the default precedence.
    if [ "$force_canonical" = "true" ] && [ -d "$cache_dir" ]; then
        MOODLE_SRC_DIR="$cache_dir"; MOODLE_SRC_ORIGIN="canonical-repo-cache (--from-canonical)"
        return 0
    fi
    if [ "$force_toolkit" = "true" ] && [ -d "$toolkit" ]; then
        MOODLE_SRC_DIR="$toolkit"; MOODLE_SRC_ORIGIN="nwptoolkit (STALE, opt-in)"
        _moodle_warn_nwptoolkit "$toolkit" "--from-nwptoolkit"
        return 0
    fi

    # 5. dev build tree — the DEFAULT, unchanged from origin/main's ship path.
    if [ -d "$dev_dir" ]; then
        MOODLE_SRC_DIR="$dev_dir"; MOODLE_SRC_ORIGIN="dev-tree (default)"
        if [ -d "$cache_dir" ] && ! diff -rq --exclude=.git --exclude=amd "$dev_dir" "$cache_dir" >/dev/null 2>&1; then
            print_warning "Drift: sites/${base}/dev/${plugin} differs from the canonical repo — shipping the DEV copy."
            print_info    "  Commit dev-side work to ss-moodle-plugins, or pass --from-canonical to ship the repo copy."
        fi
        return 0
    fi
    # 6. canonical repo cache — the fallback that used to be ~/nwptoolkit.
    if [ -d "$cache_dir" ]; then
        MOODLE_SRC_DIR="$cache_dir"; MOODLE_SRC_ORIGIN="canonical-repo-cache (no dev tree)"
        print_info "No dev tree for ${plugin} — using the canonical repo cache (ops#137: this fallback was ~/nwptoolkit)."
        return 0
    fi
    # No rung matched. ~/nwptoolkit is deliberately NOT an implicit fallback.
    print_error "No source resolved for '${plugin}' (site ${base})."
    print_info  "  dev tree        : ${dev_dir} (absent)"
    print_info  "  canonical cache : ${cache_dir} (absent — run: pl moodle plugins sync ${base} --apply)"
    if [ -d "$toolkit" ]; then
        print_info "  ~/nwptoolkit    : present but NO LONGER an implicit fallback (ops#137 — stale, ungated)."
        print_info "                    Opt in deliberately with --from-nwptoolkit."
    fi
    return 1
}

_moodle_warn_nwptoolkit() {
    local dir="$1" how="$2"
    print_warning "════════════════════════════════════════════════════════════════"
    print_warning "SOURCE = ~/nwptoolkit (${how}): ${dir}"
    print_warning "This is a STALE 2026-07-03 snapshot. It PREDATES the ops#118 Art.9"
    print_warning "consent gate and does not contain auth/nwc, local/mentor or"
    print_warning "local/practice at all. It is NOT the canonical source (ops#137)."
    print_warning "Canonical: nwp/ss-moodle-plugins — pl moodle plugins sync <site>"
    print_warning "════════════════════════════════════════════════════════════════"
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
    local explicit_from="" force_toolkit="false" force_canonical="false" allow_ungated="false"
    local -a plugins=()
    for a in "$@"; do
        case "$a" in
            --tier=*)      tier="${a#*=}" ;;
            --dry-run)     mode="dry-run" ;;
            --apply)       mode="apply" ;;
            --no-upgrade)  no_upgrade="true" ;;
            --from=*)          explicit_from="${a#*=}" ;;
            --from-canonical)  force_canonical="true" ;;
            --from-nwptoolkit) force_toolkit="true" ;;
            --allow-ungated)   allow_ungated="true" ;;
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
    # 5. SOURCE RESOLUTION (ops#137) — resolve ONCE, up front, and reuse the
    #    same directory for the freshness gate, the Art.9 assertion and the
    #    rsync. Asserting one tree while shipping another is the fail-open.
    local p ts type name
    local -a src_dirs=()
    print_header "Plugin source resolution"
    for p in "${plugins[@]}"; do
        _moodle_resolve_source "$CONFIG_FILE" "$BASE" "$p" \
            "$explicit_from" "$force_toolkit" "$force_canonical" || return 1
        src_dirs+=("$MOODLE_SRC_DIR")
        printf '    %-28s %s\n      └─ %s\n' "$p" "[$MOODLE_SRC_ORIGIN]" "$MOODLE_SRC_DIR"
    done

    # 6. ART.9 SHIP-TOGETHER ASSERTION (ops#137) — fail CLOSED before any bytes
    #    move. Runs on dry-run too, so the refusal is visible without --apply.
    local -a gate_args=()
    local i=0
    for p in "${plugins[@]}"; do gate_args+=("$p" "${src_dirs[$i]}"); i=$((i+1)); done
    if ! moodle_gate_assert "$BASE" "$tier" "$allow_ungated" "${gate_args[@]}"; then
        return 1
    fi

    # 7. freshness gate — every plugin must be built + fresh at the RESOLVED source
    i=0
    for p in "${plugins[@]}"; do
        if ! cmd_plugin_build "$p" --from="${src_dirs[$i]}" --check-only; then
            print_error "Freshness gate FAILED for '$p' — rebuild before deploy (pl moodle plugin build $p)."
            return 1
        fi
        i=$((i+1))
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

    # 9. Per-plugin rsync — ships EXACTLY the directories resolved and asserted
    #    in steps 5/6 (ops#137: never re-resolve here, or the assertion is moot).
    print_header "Deploy plugin dirs → ${ssh_target}:${remote_path}"
    i=0
    for p in "${plugins[@]}"; do
        read -r type name <<<"$(moodle_plugin_split "$p")"
        moodle_plugin_rsync "${src_dirs[$i]}" "$type" "$name" "$ssh_target" "$remote_path" \
            "$sudo_prefix" "$ssh_opts" "$apply" || return 1
        i=$((i+1))
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
# plugins sync — canonical repo → local cache (ops#137 / design §4.1)
#
# Makes nwp/ss-moodle-plugins the source of truth: clone/pull it into
# sites/<site>/.plugin-src/<repo>/ and let _moodle_resolve_source default every
# deploy at it. --tier=live delegates VERBATIM to the guarded plugin deploy —
# no live primitive is reimplemented here.
################################################################################
cmd_plugins_sync() {
    local site="" tier="dev" ref="" mode="dry-run"
    for a in "$@"; do
        case "$a" in
            --tier=*)  tier="${a#*=}" ;;
            --ref=*)   ref="${a#*=}" ;;
            --apply)   mode="apply" ;;
            --dry-run) mode="dry-run" ;;
            -*)        print_error "Unknown option: $a"; return 1 ;;
            *)         [ -z "$site" ] && site="$a" || { print_error "Unexpected arg: $a"; return 1; } ;;
        esac
    done
    [ -z "$site" ] && { print_error "usage: pl moodle plugins sync <site> [--tier=dev|live] [--ref=REF] [--apply]"; return 1; }
    case "$tier" in dev|live) ;; *) print_error "--tier must be dev or live"; return 1 ;; esac
    _resolve_moodle_site "$site" || return 1

    local repo cache
    repo="$(_moodle_plugins_repo "$CONFIG_FILE")"
    [ -z "$ref" ] && ref="$(_moodle_plugins_ref "$CONFIG_FILE")"
    cache="$(_moodle_plugin_cache "$BASE" "$repo")"

    print_header "Plugin source sync: ${BASE}"
    if [ -z "$repo" ]; then
        print_error "No plugin repo configured for '${BASE}' and no GitLab host to derive one from."
        print_info  "Set it in sites/${BASE}/.nwp.yml:"
        print_info  "    moodle:"
        print_info  "      plugins_repo: git@<your-gitlab-host>:${MOODLE_PLUGINS_REPO_PATH}.git"
        print_info  "      plugins_ref:  main"
        print_info  "…or set settings.url in nwp.yml so it can be derived."
        return 1
    fi
    print_info "  repo  : ${repo}"
    print_info "  ref   : ${ref}"
    print_info "  cache : ${cache}"

    if [ "$mode" != "apply" ]; then
        print_info "[dry-run] would $( [ -d "$cache/.git" ] && echo 'fetch + checkout' || echo 'clone' ) ${repo}@${ref} → ${cache}"
    else
        command -v git >/dev/null 2>&1 || { print_error "git is required for plugins sync."; return 1; }
        if [ -d "$cache/.git" ]; then
            git -C "$cache" fetch --prune origin || { print_error "git fetch failed for ${repo}"; return 1; }
        else
            mkdir -p "$(dirname "$cache")" || return 1
            git clone --quiet "$repo" "$cache" || { print_error "git clone failed for ${repo}"; return 1; }
            git -C "$cache" fetch --prune origin >/dev/null 2>&1 || true
        fi
        # Detached checkout of the requested ref — a deploy should map to an
        # exact commit, not to a moving branch tip in a dirty working tree.
        git -C "$cache" checkout --quiet --detach "origin/${ref}" 2>/dev/null \
            || git -C "$cache" checkout --quiet --detach "$ref" \
            || { print_error "Cannot check out ref '${ref}' in ${cache}"; return 1; }
        print_status "OK" "Cache at $(git -C "$cache" rev-parse --short HEAD) (${ref})"
    fi

    # Gate visibility on what was just synced.
    if [ -d "$cache" ]; then
        print_header "Art.9 gate status of the synced cache"
        _moodle_gate_status_tree "$CONFIG_FILE" "$cache" "cache"
    fi

    if [ "$tier" = "live" ]; then
        print_header "Delegating to the guarded live deploy"
        print_info "The live half is NOT reimplemented here. Run:"
        print_info "  pl moodle plugin deploy ${BASE} --tier=live $( [ "$mode" = apply ] && echo --apply )"
        print_info "It resolves each plugin from this cache, asserts the Art.9 gate, runs the"
        print_info "freshness gate, ADR-0028 deploy gate, typed confirm, snapshot and rsync."
    fi
    return 0
}

################################################################################
# gate-status — "is the ship-together invariant actually satisfied?" (ops#137)
#
# One command instead of an archaeology session. Reports per plugin, per tree:
# canonical cache / dev tree / ~/nwptoolkit / LIVE webroot.
################################################################################

# _moodle_gate_status_tree <config> <root> <label> — print one column of rows.
# Sets _MG_TREE_UNGATED to the number of UNGATED findings.
_moodle_gate_status_tree() {
    local config_file="$1" root="$2" label="$3"
    local -a plugins=()
    mapfile -t plugins < <(_moodle_configured_plugins "$config_file")
    [ "${#plugins[@]}" -eq 0 ] && mapfile -t plugins < <(printf '%s\n' $MOODLE_GATE_PROVIDERS $MOODLE_GATE_CONSUMERS)
    _MG_TREE_UNGATED=0
    local p st
    for p in "${plugins[@]}"; do
        st="$(moodle_gate_report "$p" "${root%/}/${p}")"
        [ "$st" = "UNGATED" ] && _MG_TREE_UNGATED=$((_MG_TREE_UNGATED+1))
        printf '    %-28s %-10s %-8s %s\n' "$p" "[$st]" "$label" "$(moodle_gate_scan "${root%/}/${p}")"
    done
}

cmd_gate_status() {
    local site="" want_live="true"
    for a in "$@"; do
        case "$a" in
            --no-live) want_live="false" ;;
            -*)        print_error "Unknown option: $a"; return 1 ;;
            *)         [ -z "$site" ] && site="$a" || { print_error "Unexpected arg: $a"; return 1; } ;;
        esac
    done
    [ -z "$site" ] && site="ssc"
    _resolve_moodle_site "$site" || return 1

    local repo cache dev_root toolkit
    repo="$(_moodle_plugins_repo "$CONFIG_FILE")"
    cache="$(_moodle_plugin_cache "$BASE" "$repo")"
    dev_root="$PROJECT_ROOT/sites/${BASE}/dev"
    toolkit="${HOME}/nwptoolkit/moodle/plugins"

    print_header "Art.9 ship-together gate status: ${BASE} (ops#137)"
    print_info "Symbol: ${MOODLE_GATE_SYMBOL}  •  consumers must delegate to ${MOODLE_GATE_PROVIDER_CLASS}"
    echo ""

    local total_ungated=0
    for pair in "canonical-cache:${cache}" "dev-tree:${dev_root}" "nwptoolkit:${toolkit}"; do
        local lbl="${pair%%:*}" root="${pair#*:}"
        echo "  ${lbl}  (${root})"
        if [ ! -d "$root" ]; then
            printf '    %s\n' "(absent)"
        else
            _moodle_gate_status_tree "$CONFIG_FILE" "$root" "$lbl"
            total_ungated=$((total_ungated + _MG_TREE_UNGATED))
        fi
        echo ""
    done

    # LIVE — read-only remote grep. No writes, no secrets on argv.
    if [ "$want_live" = "true" ]; then
        local server_ip ssh_user remote_path ssh_opts sudo_prefix=""
        server_ip=$(get_live_config "$BASE" "server_ip")
        ssh_user=$(get_ssh_user "$BASE")
        remote_path=$(get_live_config "$BASE" "remote_path"); [ -z "$remote_path" ] && remote_path="/var/www/${BASE}"
        [ "$ssh_user" = "gitlab" ] && sudo_prefix="sudo"
        echo "  LIVE  (${ssh_user}@${server_ip}:${remote_path})"
        if [ -z "$server_ip" ]; then
            printf '    %s\n' "(no live server configured)"
        else
            ssh_opts="$(nwp_ssh_opts "$BASE")"
            local -a plugins=()
            mapfile -t plugins < <(_moodle_configured_plugins "$CONFIG_FILE")
            [ "${#plugins[@]}" -eq 0 ] && mapfile -t plugins < <(printf '%s\n' $MOODLE_GATE_PROVIDERS $MOODLE_GATE_CONSUMERS)
            local p role remote out calls dels defs st
            for p in "${plugins[@]}"; do
                role="$(moodle_gate_requirement "$p")"
                if [ "$role" = "exempt" ]; then
                    printf '    %-28s %-10s %s\n' "$p" "[EXEMPT]" "live"; continue
                fi
                # Production code only (tests/ excluded) — mirrors moodle_gate_scan.
                remote="d='${remote_path%/}/${p}'; if [ ! -d \"\$d\" ]; then echo ABSENT 0 0 0; else \
P=\$(${sudo_prefix} grep -rI --include='*.php' '${MOODLE_GATE_SYMBOL}' \"\$d\" 2>/dev/null | grep -v '/tests/'); \
c=\$(printf '%s' \"\$P\" | grep -c .); \
g=\$(printf '%s' \"\$P\" | grep -c '${MOODLE_GATE_PROVIDER_CLASS}'); \
f=\$(printf '%s' \"\$P\" | grep -cE 'function[[:space:]]+${MOODLE_GATE_SYMBOL}'); \
echo PRESENT \$c \$g \$f; fi"
                out="$(ssh ${ssh_opts} -o BatchMode=yes -o ConnectTimeout=10 "${ssh_user}@${server_ip}" "$remote" 2>/dev/null || echo "ERROR 0 0 0")"
                read -r st calls dels defs <<<"$out"
                case "$st" in
                    ABSENT)  st="ABSENT" ;;
                    ERROR)   st="UNREACHABLE" ;;
                    PRESENT)
                        if [ "$role" = "provider" ]; then
                            [ "${defs:-0}" -ge 1 ] && st="GATED" || st="UNGATED"
                        else
                            { [ "${calls:-0}" -ge 1 ] && [ "${dels:-0}" -ge 1 ]; } && st="GATED" || st="UNGATED"
                        fi ;;
                esac
                [ "$st" = "UNGATED" ] && total_ungated=$((total_ungated+1))
                printf '    %-28s %-10s %-8s calls=%s delegations=%s definitions=%s\n' \
                    "$p" "[$st]" "live" "${calls:-0}" "${dels:-0}" "${defs:-0}"
            done
        fi
        echo ""
    fi

    if [ "$total_ungated" -gt 0 ]; then
        print_warning "Ship-together invariant NOT satisfied: ${total_ungated} UNGATED artifact(s) above (ops#137)."
        print_info    "Deploys from an UNGATED source are now REFUSED by 'pl moodle plugin deploy'."
        return 1
    fi
    print_status "OK" "Every gate-bearing plugin found carries the Art.9 consent gate."
    return 0
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
#
# Sourcing this file (bats unit tests) defines the functions WITHOUT dispatching,
# so pure helpers like _moodle_resolve_source can be exercised directly.
################################################################################
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0 2>/dev/null || true
fi

[ "$#" -eq 0 ] && { show_help; exit 1; }
SUB="$1"; shift || true
case "$SUB" in
    -h|--help|help) show_help; exit 0 ;;
    plugin)
        PSUB="${1:-}"; shift || true
        case "$PSUB" in
            build)  cmd_plugin_build  "$@" ;;
            deploy) cmd_plugin_deploy "$@" ;;
            *) print_error "Unknown 'plugin' subcommand: ${PSUB:-(none)} (build|deploy)"; exit 1 ;;
        esac
        ;;
    plugins)
        PSUB="${1:-}"; shift || true
        case "$PSUB" in
            sync)   cmd_plugins_sync "$@" ;;
            status) cmd_gate_status  "$@" ;;
            *) print_error "Unknown 'plugins' subcommand: ${PSUB:-(none)} (sync|status)"; exit 1 ;;
        esac
        ;;
    gate-status) cmd_gate_status "$@" ;;
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
