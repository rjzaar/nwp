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
#   pl moodle rollback      <site> --tier=live [list|verify|execute] [--dry-run]
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
source "$REPO_ROOT/lib/moodle-policy.sh"   # ops#174 tool_policy site-policy-handler invariant
source "$REPO_ROOT/lib/moodle-mail.sh"     # D7 declared mail identity + deliverability gate

show_help() {
    cat <<EOF
${BOLD}NWP Moodle — guarded plugin build / deploy / upgrade / backup / rollback${NC}

${BOLD}USAGE:${NC}
    pl moodle cli           <site> --tier=live [--dry-run|--execute] -- <admin/cli/x.php> [args]
    pl moodle maintenance   <site> --tier=live on|off [--dry-run|--execute]
    pl moodle plugin build  <plugin> [--from=DIR] [--ddev=SITE|--tree=DIR] [--check-only]
    pl moodle plugin deploy <site> <plugin>... --tier=stg|live [--dry-run|--apply] [--no-upgrade]
                            [--from=DIR|--from-canonical|--from-nwptoolkit]
                            [--allow-downgrade] [--override-pair]
    pl moodle plugin drift  <site> [<plugin>...] [--tree=DIR]... [--no-live] [--no-canonical] [--canonical-ref=REF]
    pl moodle plugins sync  <site> [--tier=dev|live] [--ref=REF] [--dry-run|--apply]
    pl moodle core-patch status <site> [--root=DIR|--live]
    pl moodle privacy       <site> --tier=live [--component=<frankenstyle>]... [--all] [--verbose]
    pl moodle policy        <site> --tier=live [--dry-run|--apply] [--disarm]
    pl moodle mail          <site> --tier=live [--dry-run|--apply] [--sync-golden]
    pl moodle course restore <site> --tier=live|dev --from=DIR [--category=NAME|--category-map=FILE] [--enable-self-enrol] [--dry-run|--apply]
    pl moodle content sync  <site> --tier=live|dev --from=DIR [--dry-run|--apply]
    pl moodle gate-status   <site> [--no-live]     # == pl moodle plugins status
    pl moodle upgrade       <site> --tier=stg|live [--dry-run|--apply] [--no-maintenance]
    pl moodle backup        <site> --tier=live|stg [--db-only|--code-only] [--dry-run|--apply]
    pl moodle rollback      <site> --tier=live [list|verify|execute] [--dry-run]
    pl moodle config        <site> [...]       # == pl moodle-promote (dev/stg substrate)
    pl moodle smoke         <site> [...]       # == pl moodle-smoke

${BOLD}THE TWO PIECES OF BOX KNOWLEDGE (item 9) — now resolved, never typed:${NC}
    Moodle 4.4 REJECTS PHP 8.4 (the box default), and the box php.ini sets
    max_input_vars=1000, below Moodle's floor. Every admin/cli invocation from
    'pl moodle' therefore resolves php8.2/8.3 + '-d max_input_vars=5000' and
    ASSERTS both are present before running. Running upgrade.php without them
    fails the env check AFTER maintenance mode is on and leaves the site DOWN
    (the \`ss\` Moodle instance, ~6 min, 2026-07-26).
    Recovery is always one verb: pl moodle maintenance <site> --tier=live off --execute

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
    * 'privacy' is READ-ONLY and asks MOODLE, on the target, whether a plugin is
      visible to the privacy API — class resolves, interfaces implemented,
      versiondb == versiondisk. 'drift' cannot answer this: it compares
      \$plugin->version between copies, so a file missing from ALL of them reads
      as agreement. local_feedback shipped to live ssd + ssc for weeks with no
      provider.php at all (ops#259) and nothing went red.
    * 'policy' reports whether the site's published legal documents are actually
      presented for acceptance (\$CFG->sitepolicyhandler == tool_policy). ss/ssc
      published five MANDATORY documents with the handler unset and recorded zero
      acceptances for six weeks (ops#174). "No policies visible" reports UNKNOWN,
      never OK — a cold policyid_<slug> pointer is the ops#174 root cause itself.
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
    local allow_downgrade="false"
    # pair_guard's own refusal says "re-run with --override-pair". Until 2026-08-03
    # this verb did not parse that flag and answered the advice with
    # "Unknown option", so the only way through was to know that the OVERRIDE_PAIR
    # environment variable existed. An override that is reachable only by reading
    # the source is an override that never gets ledgered by the people who need
    # it and gets replaced by a hand-rolled ssh by the people who don't. The env
    # var still works, so nothing that used it breaks.
    local override_pair="${OVERRIDE_PAIR:-false}"
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
            --allow-downgrade) allow_downgrade="true" ;;
            --override-pair)   override_pair="true" ;;
            -y|--yes)      AUTO_CONFIRM=true ;;
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
    if ! pair_guard "$BASE" "$tier" "moodle-deploy" "true" "$override_pair"; then return 1; fi
    # 4b. DECLARED CORE PATCHES (item 9) — fail CLOSED before any bytes move,
    #     on dry-run too. A target missing a declared core patch is running
    #     DIFFERENT core code than the one this deploy was validated against;
    #     ssc's guest front door is exactly such a patch and lived only as an
    #     uncommitted working-tree diff until this gate existed. No declaration
    #     ⇒ clean no-op, so sites without core patches are unaffected.
    if [ -s "$(_moodle_core_patches_decl "$BASE" "$CONFIG_FILE")" ]; then
        print_header "Declared core-patch verification (item 9)"
        local _cp_args=("$BASE"); [ "$tier" = "live" ] && _cp_args+=(--live)
        if ! cmd_core_patch status "${_cp_args[@]}"; then
            print_error "Refusing the deploy: a declared core patch is not verified present on the target."
            print_info  "  Re-apply it, or remove the declaration from sites/${BASE}/core-patches.yml."
            print_info  "  Override is deliberately NOT provided — this is the fail-closed half of item 9."
            return 1
        fi
    fi
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

    # Remote target is resolved HERE, before the freshness gate, because the
    # version-direction gate below needs it. Pure config reads + string building;
    # no side effects, nothing dialled yet.
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

    ###########################################################################
    # 6b. VERSION-DIRECTION GATE (ops#229) — a deploy that moves $plugin->version
    #     BACKWARDS is either a mistake or a deliberate rollback, and the
    #     deliberate case has to say so.
    #
    # WHY THIS IS A P0 AND NOT A NICETY. `_moodle_resolve_source` defaults to the
    # DEV tree (rung 5). `sites/ssd/dev/mod/depthcontent` has no video renderer;
    # live ssd runs 2026080101, which has it. So a naive
    #
    #     pl moodle plugin deploy ssd mod/depthcontent --tier=live --apply
    #
    # would ship the dev tree over the top and silently remove video from all
    # 175 clips on a live site. The existing drift WARNING (rung 5) fires only
    # when a canonical cache is present to compare against, says "shipping the
    # DEV copy" either way, and does not look at the TARGET at all — so nothing
    # in the deploy output would have said the version went backwards.
    #
    # Same shape as ops#103: the verb's default source is not the canonical
    # source, and the resulting deploy looks successful.
    #
    # Runs on DRY-RUN too — a refusal you can only discover with --apply is not
    # a preflight. Fails CLOSED on an unreadable source version; an unreadable
    # TARGET version is reported as a first install, which is the honest reading
    # of "no version.php over there" and is proven by a test either way.
    ###########################################################################
    print_header "Version-direction gate (ops#229)"
    local _vd_refuse=0
    i=0
    for p in "${plugins[@]}"; do
        local src_v tgt_v
        src_v="$(moodle_plugin_version_dir "${src_dirs[$i]}" 2>/dev/null || true)"
        # THREE answers, not two: an ssh that cannot be asked must not read as
        # "not installed yet", which would wave a downgrade straight through.
        tgt_v="$(moodle_plugin_target_version "$ssh_target" "$ssh_opts" "$sudo_prefix" "$remote_path" "$p")"
        moodle_version_gate_report "$p" "${src_dirs[$i]}" "$src_v" "$tgt_v" \
            "$allow_downgrade" "$BASE" "$tier" "${MOODLE_SRC_ORIGIN:-?}" || _vd_refuse=1
        i=$((i+1))
    done
    [ "$_vd_refuse" -eq 0 ] || return 1

    # 7. freshness gate — every plugin must be built + fresh at the RESOLVED source
    i=0
    for p in "${plugins[@]}"; do
        if ! cmd_plugin_build "$p" --from="${src_dirs[$i]}" --check-only; then
            print_error "Freshness gate FAILED for '$p' — rebuild before deploy (pl moodle plugin build $p)."
            return 1
        fi
        i=$((i+1))
    done

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
    # ops#229: a downgrade is ledgered where the operator has to read it — in the
    # fate manifest that the typed live confirm renders, not only in a warning
    # that has already scrolled past.
    [ "$allow_downgrade" = "true" ] && impact_warn "--allow-downgrade: \$plugin->version may move BACKWARDS on this target (ops#229)."
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

    # Class-aware verdict (ops#153/ADR-0036): the [UNGATED] rows above are scan
    # facts and stand as printed; a valid none-stored exemption reclassifies
    # only the verdict — the same siteclass_art9_exempt predicate the deploy
    # gate consults, so status and deploy can never disagree.
    moodle_gate_status_verdict "$BASE" "$total_ungated"
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
            -y|--yes)          AUTO_CONFIRM=true ;;
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
    local anchor="" override_pair="false" paired_ack=""
    for a in "$@"; do
        case "$a" in
            --tier=*)  tier="${a#*=}" ;;
            --dry-run) dry="true" ;;
            --anchor=*) anchor="${a#*=}" ;;
            --override-pair) override_pair="true" ;;
            --paired-restore-ack=*) paired_ack="${a#*=}" ;;
            list)      action="list" ;;
            verify)    action="verify" ;;
            execute)   action="execute" ;;
            -*)        print_error "Unknown option: $a"; return 1 ;;
            *)         [ -z "$site" ] && site="$a" || { print_error "Unexpected arg: $a"; return 1; } ;;
        esac
    done
    [ -z "$site" ] && { print_error "usage: pl moodle rollback <site> --tier=live [list|verify|execute] [--dry-run]"; return 1; }
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
        print_info "Are those artifacts still THERE? pl moodle rollback ${BASE} --tier=live verify"
        return 0
    fi

    # verify → the ledger is a claim; the box is the fact.
    #
    # `list` prints "[active]" out of a local JSON file and has never once looked
    # at the target. A rollback point whose remote tarball was cleaned out of
    # /home/gitlab months ago lists exactly the same as a good one, so the ledger
    # can read healthy while the estate has no way back at all — and you find out
    # at the only moment it matters. This action goes and looks: size + sha256 of
    # both artifacts, taken ON the box. READ-ONLY; it writes nothing anywhere.
    # It also prints the sha256 you need for a rollback-registry row, which until
    # now had to be fetched with a hand-rolled ssh.
    if [ "$action" = "verify" ]; then
        local server_ip ssh_user ssh_opts ssh_target
        server_ip=$(get_live_config "$BASE" "server_ip")
        [ -z "$server_ip" ] && { print_error "No live server configured for '$BASE'."; return 1; }
        ssh_user=$(get_ssh_user "$BASE")
        ssh_opts="$(nwp_ssh_opts "$BASE")"; ssh_target="${ssh_user}@${server_ip}"

        print_header "Moodle rollback artifacts: ${BASE} (on ${ssh_target})"
        local f n_ok=0 n_bad=0 n_blind=0
        for f in "${ROLLBACK_DIR}/${BASE}_"*.json; do
            [ -e "$f" ] || continue
            grep -q '"type": *"moodle-remote"' "$f" 2>/dev/null || continue
            local ts st db pl_
            ts=$(grep -m1 '"timestamp"' "$f"        | sed 's/.*: *"\([^"]*\)".*/\1/')
            st=$(grep -m1 '"status"' "$f"           | sed 's/.*: *"\([^"]*\)".*/\1/')
            db=$(grep -m1 '"snapshot_db"' "$f"      | sed 's/.*: *"\([^"]*\)".*/\1/')
            pl_=$(grep -m1 '"snapshot_plugins"' "$f" | sed 's/.*: *"\([^"]*\)".*/\1/')
            echo "  ${ts}  [${st}]  $(basename "$f")"
            local a
            for a in "$db" "$pl_"; do
                [ -n "$a" ] || continue
                local line rc=0
                # shellcheck disable=SC2086
                line="$(ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
                    "if [ -f $(printf '%q' "$a") ]; then stat -c %s $(printf '%q' "$a"); sha256sum $(printf '%q' "$a") | cut -d' ' -f1; else echo MISSING; fi" \
                    </dev/null 2>/dev/null)" || rc=$?
                if [ "$rc" -ne 0 ] || [ -z "$line" ]; then
                    # Could not look. NOT the same as "not there" — grade it apart.
                    printf '      %-64s %s\n' "$(basename "$a")" "CANNOT-VERIFY (ssh/stat failed)"
                    n_blind=$((n_blind+1)); continue
                fi
                if [ "$line" = "MISSING" ]; then
                    printf '      %-64s %s\n' "$(basename "$a")" "MISSING on the target"
                    n_bad=$((n_bad+1)); continue
                fi
                local sz sha
                sz="$(printf '%s\n' "$line" | sed -n 1p)"
                sha="$(printf '%s\n' "$line" | sed -n 2p)"
                printf '      %-64s %s bytes  sha256=%s\n' "$(basename "$a")" "$sz" "$sha"
                n_ok=$((n_ok+1))
            done
        done
        if [ "$n_ok" -eq 0 ] && [ "$n_bad" -eq 0 ] && [ "$n_blind" -eq 0 ]; then
            print_info "No moodle-remote rollback points for ${BASE}."
            return 0
        fi
        print_info "artifacts present=${n_ok} missing=${n_bad} unverifiable=${n_blind}"
        [ "$n_blind" -gt 0 ] && { print_error "CANNOT-VERIFY on ${n_blind} artifact(s) — not a pass."; return 3; }
        [ "$n_bad"   -gt 0 ] && { print_error "${n_bad} recorded artifact(s) are GONE from the target — those rollback points are phantoms."; return 1; }
        print_status "OK" "every recorded rollback artifact is present and hashed."
        return 0
    fi

    # execute → newest active moodle-remote entry
    local entry
    entry=$(ls -1 "${ROLLBACK_DIR}/${BASE}_live_"*.json 2>/dev/null \
        | xargs -I{} grep -l '"type": *"moodle-remote"' {} 2>/dev/null | sort | tail -1 || true)
    [ -z "$entry" ] && { print_error "No moodle-remote rollback point for ${BASE}@live."; return 1; }
    local apply="true"; [ "$dry" = "true" ] && apply="false"

    # ops#83 SIDE DOOR, CLOSED. `moodle_remote_rollback_execute` gunzips a dump
    # straight into the LIVE Moodle DB (lib/moodle-deploy.sh). There are two
    # doors onto that one executor: lib/rollback.sh reaches it through
    # pair_guard_restore + deploy_gate_require, and this verb reached it through
    # neither. For ssc — the consumer half of the real UID-locked pair, with real
    # students — this is precisely the operation ops#83 exists to refuse: rolling
    # the consumer's DB backwards while nwc stays forward orphans every
    # mdl_user.idnumber lock. Same gates, same order, as the other door.
    # A dry run writes nothing, so it is exempt (as elsewhere in this tree).
    if [ "$apply" = "true" ]; then
        local _mr_tier="${tier:-live}"
        [ "$_mr_tier" = "stage" ] && _mr_tier="stg"
        if [ -z "$anchor" ]; then
            anchor=$(grep -m1 '"identity_anchor"' "$entry" 2>/dev/null \
                | sed 's/.*: *"\{0,1\}\([0-9]*\)"\{0,1\}.*/\1/' || true)
        fi
        [ -z "$anchor" ] && anchor="${NWP_RESTORE_ANCHOR:-}"
        if command -v pair_guard_restore >/dev/null 2>&1; then
            # code_only is hard-false: this path loads a database.
            pair_guard_restore "$BASE" "$_mr_tier" "moodle-rollback" \
                "$anchor" "$override_pair" "" false "$paired_ack" || return 1
        fi
        if command -v deploy_gate_require >/dev/null 2>&1; then
            deploy_gate_require "$BASE" "$_mr_tier" \
                "moodle rollback: restore the live Moodle DB + plugin code" || return 1
        fi
    fi

    NWP_SSH_OPTS="$(nwp_ssh_opts "$BASE")" moodle_remote_rollback_execute "$entry" "$(nwp_ssh_opts "$BASE")" "$apply"
}

################################################################################
# cli — the Moodle twin of `pl drush` (item 9)
#
# WHY: `pl moodle` dispatched only plugin/plugins/gate-status/upgrade/backup/
# rollback/config/smoke. Every OTHER admin/cli call against ss, ss2, ssc, ssd
# and sso_moodle was hand-ssh plus two pieces of tribal knowledge (php8.2/8.3,
# -d max_input_vars=5000). Getting it wrong caused the ~6 min `ss` instance
# outage on 2026-07-26: upgrade.php failed its env check and left maintenance
# mode ON, with no pl verb able to clear it.
#
# HOUSE STYLE: identical to `pl drush` — live is DRY-RUN by default, --execute
# is required, the deploy gate + live.enabled + typed confirm apply, and the
# resolved command is ASSERTED (moodle_cli_assert) before anything runs.
################################################################################
cmd_cli() {
    local site="" tier="" explicit_mode="" root_override=""
    local -a cli_args=(); local saw_sep="no"
    while [ "$#" -gt 0 ]; do
        if [ "$saw_sep" = "yes" ]; then cli_args+=("$1"); shift; continue; fi
        case "$1" in
            --)          saw_sep="yes" ;;
            --tier=*)    tier="${1#*=}" ;;
            --dry-run)   explicit_mode="dry-run" ;;
            --execute|--apply) explicit_mode="execute" ;;
            -y|--yes)    AUTO_CONFIRM=true ;;
            --root=*)    root_override="${1#*=}" ;;
            -h|--help)   print_info "usage: pl moodle cli <site> --tier=stg|live [--dry-run|--execute] -- <admin/cli script> [args...]"; return 0 ;;
            -*)          print_error "Unknown option: $1"; return 1 ;;
            *)           [ -z "$site" ] && site="$1" || { print_error "Unexpected arg: $1 (CLI args go after --)"; return 1; } ;;
        esac
        shift
    done
    [ -z "$site" ] && { print_error "usage: pl moodle cli <site> --tier=stg|live [--dry-run|--execute] -- <admin/cli script> [args...]"; return 1; }
    case "$tier" in stg|live) ;; "") print_error "--tier is required (stg|live)"; return 1 ;; *) print_error "Unknown tier '$tier' — only stg|live"; return 1 ;; esac
    if [ "${#cli_args[@]}" -eq 0 ]; then
        print_error "No CLI script given — pass it after '--', e.g. pl moodle cli $site --tier=$tier -- admin/cli/purge_caches.php"
        return 1
    fi
    _resolve_moodle_site "$site" || return 1

    # The script must live under admin/cli — OR directly under the cli/ dir of
    # a plugin this site itself DECLARES (ops#279: sync_practice_defs.php lives
    # at local/practice/cli/, and refusing it pushed a runbook toward raw ssh).
    # This is a *containment* rule, not a convenience: `pl moodle cli` runs as
    # www-data on a live host, and a traversing path would turn it into an
    # arbitrary-file php runner. The plugin arm RESTATES containment rather
    # than relaxing it: the plugin must appear in .moodle.plugins[].path, the
    # dir must be that plugin's own cli/, the leaf a bare <name>.php.
    local script="${cli_args[0]}"
    case "$script" in *..*) print_error "Refusing a path containing '..': ${script}"; return 1 ;; esac
    case "$script" in
        admin/cli/*.php) ;;
        */cli/*.php)
            local plug="${script%%/cli/*}" leaf=""
            leaf="${script#"${plug}/cli/"}"
            if [[ "$leaf" == */* ]]; then
                print_error "Refusing '${script}': only a bare <name>.php directly under the plugin's cli/ dir."
                return 1
            fi
            if ! _moodle_configured_plugins "$CONFIG_FILE" | grep -qx -- "$plug"; then
                print_error "Refusing '${script}': '${plug}' is not a plugin this site declares in .moodle.plugins[].path."
                print_info  "  (containment: admin/cli/ or a DECLARED plugin's own cli/ only — declare the plugin in sites/${BASE}/.nwp.yml first)"
                return 1
            fi
            ;;
        *) print_error "Refusing '${script}': the script must be a repo-relative admin/cli/<name>.php path, or a declared plugin's cli/<name>.php."
           print_info  "  (containment: this runs as www-data on a live host — no traversal, no arbitrary path)"
           return 1 ;;
    esac

    if [ "$tier" != "live" ]; then
        print_error "tier=stg is a local ddev tier for Moodle — use 'ddev exec php admin/cli/...' in sites/${BASE}/stg,"
        print_info  "or 'pl moodle config ${BASE} --tier=stg' for the stg substrate (design §4)."
        return 1
    fi

    local live_enabled; live_enabled=$(get_live_config "$BASE" "enabled")
    local mode="dry-run"; [ "$explicit_mode" = "execute" ] && mode="execute"
    if [ "$live_enabled" = "false" ] && [ "$mode" = "execute" ]; then
        print_error "Live disabled for '$BASE' (live.enabled: false)."; return 1
    fi

    local server_ip ssh_user remote_path ssh_opts ssh_target sudo_prefix=""
    server_ip=$(get_live_config "$BASE" "server_ip")
    [ -z "$server_ip" ] && { print_error "No live server configured for '$BASE' (empty server_ip). 'pl moodle cli' does not provision."; return 1; }
    ssh_user=$(get_ssh_user "$BASE")
    remote_path=$(get_live_config "$BASE" "remote_path"); [ -z "$remote_path" ] && remote_path="/var/www/${BASE}"
    [ "$ssh_user" = "gitlab" ] && sudo_prefix="sudo"
    if [ -n "$root_override" ]; then
        case "$root_override" in /*) ;; *) print_error "--root must be absolute"; return 1 ;; esac
        case "$(basename "$root_override")" in "${BASE}"*) ;; *) print_error "--root basename must start with '${BASE}' (wrong-site guard)"; return 1 ;; esac
        print_warning "targeting NON-canonical docroot via --root: ${root_override}"
        remote_path="$root_override"
    fi
    ssh_opts="$(nwp_ssh_opts "$BASE")"; ssh_target="${ssh_user}@${server_ip}"

    # Resolve the two pieces of box knowledge, then ASSERT them. A plan that has
    # lost either half must refuse — that is the whole point of the verb.
    local php_bin php_opts
    php_bin="$(moodle_cli_php_bin "$CONFIG_FILE")"
    php_opts="$(moodle_cli_php_opts "$CONFIG_FILE")"
    moodle_cli_assert "$php_bin" "$php_opts" || return 1

    local qargs="" a
    for a in "${cli_args[@]:1}"; do qargs+=" $(printf '%q' "$a")"; done
    local remote="cd ${remote_path} && ${sudo_prefix} -u www-data ${php_bin} ${php_opts} ${remote_path%/}/${script}${qargs}"

    print_header "Moodle CLI: ${BASE}@live"
    print_info "Target:  ${ssh_target}:${remote_path}"
    print_info "php:     ${php_bin} ${php_opts}"
    print_info "Command: ${remote}"

    if [ "$mode" != "execute" ]; then
        print_status "OK" "[dry-run] nothing executed. Re-run with --execute to run this on live."
        return 0
    fi

    deploy_gate_require "$BASE" "live" "run ${script} on live via pl moodle cli" || return 1
    impact_reset
    impact_overwrite "Moodle CLI" "${remote_path%/}/${script} runs as www-data on LIVE"
    impact_keep "config.php + moodledata — not touched by this verb"
    impact_warn "admin/cli scripts can be irreversible. Take a backup first: pl moodle backup ${BASE} --tier=live --apply"
    impact_render
    impact_confirm typed "$BASE" "${AUTO_CONFIRM:-false}" || { print_error "aborted."; return 1; }

    print_header "Running admin/cli on live"
    if ! ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "$remote"; then
        print_error "Remote admin/cli run FAILED."
        print_info  "If the site is now in maintenance mode, clear it with:"
        print_info  "    pl moodle maintenance ${BASE} --tier=live off --execute"
        return 1
    fi
    print_status "OK" "admin/cli completed on live for ${BASE}."
    return 0
}

################################################################################
# maintenance — there must ALWAYS be a one-verb way OUT of maintenance mode.
#
# moodle_maintenance() has existed at lib/moodle-deploy.sh:306 since PL-STG2LIVE
# and was unreachable from the CLI, so when the 2026-07-26 upgrade left ss in
# maintenance the only recovery was hand-ssh. Turning maintenance OFF is a
# RECOVERY action and is deliberately NOT behind a typed confirm — recovery must
# never be harder than the failure.
################################################################################
cmd_maintenance() {
    local site="" tier="live" action="" mode="dry-run"
    for a in "$@"; do
        case "$a" in
            --tier=*)  tier="${a#*=}" ;;
            --dry-run) mode="dry-run" ;;
            --execute|--apply) mode="execute" ;;
            on|enable)  action="enable" ;;
            off|disable) action="disable" ;;
            status)     action="status" ;;
            -h|--help)  print_info "usage: pl moodle maintenance <site> --tier=live on|off [--dry-run|--execute]"; return 0 ;;
            -*)         print_error "Unknown option: $a"; return 1 ;;
            *)          if [ -z "$site" ]; then site="$a"; else
                            print_error "Unknown maintenance action '$a' — the action must be on|off."
                            return 1
                        fi ;;
        esac
    done
    [ -z "$site" ] && { print_error "usage: pl moodle maintenance <site> --tier=live on|off [--dry-run|--execute]"; return 1; }
    [ -z "$action" ] && { print_error "action required: on|off (got none)"; return 1; }
    case "$tier" in live) ;; *) print_error "--tier must be live (stg is a local ddev tier)"; return 1 ;; esac
    _resolve_moodle_site "$site" || return 1

    local server_ip ssh_user remote_path ssh_opts ssh_target sudo_prefix="" php_bin
    server_ip=$(get_live_config "$BASE" "server_ip")
    [ -z "$server_ip" ] && { print_error "No live server configured for '$BASE'."; return 1; }
    ssh_user=$(get_ssh_user "$BASE")
    remote_path=$(get_live_config "$BASE" "remote_path"); [ -z "$remote_path" ] && remote_path="/var/www/${BASE}"
    [ "$ssh_user" = "gitlab" ] && sudo_prefix="sudo"
    ssh_opts="$(nwp_ssh_opts "$BASE")"; ssh_target="${ssh_user}@${server_ip}"
    php_bin="$(moodle_cli_php_bin "$CONFIG_FILE")"
    moodle_cli_assert "$php_bin" "$(moodle_cli_php_opts "$CONFIG_FILE")" || return 1

    print_header "Moodle maintenance ${action#en}${action#dis} — ${BASE}@live"
    local apply="false"; [ "$mode" = "execute" ] && apply="true"
    # Turning maintenance ON is a service-affecting write and takes the gate.
    # Turning it OFF is RECOVERY and does not — see the block comment above.
    if [ "$apply" = "true" ] && [ "$action" = "enable" ]; then
        deploy_gate_require "$BASE" "live" "enable maintenance mode on live" || return 1
    fi
    moodle_maintenance "$ssh_target" "$ssh_opts" "$sudo_prefix" "$php_bin" "$remote_path" "$action" "$apply" || {
        print_error "maintenance ${action} FAILED for ${BASE}."; return 1; }
    if [ "$apply" != "true" ]; then
        print_status "OK" "[dry-run] nothing executed. Re-run with --execute."
    else
        print_status "OK" "maintenance ${action}d for ${BASE}."
    fi
    return 0
}

################################################################################
# policy — the tool_policy site-policy-handler invariant (ops#174)
#
#   pl moodle policy <site> --tier=live [--dry-run|--apply] [--disarm]
#
# WHAT IT ANSWERS: "are the legal documents this site publishes actually
# presented to anyone, and is acceptance recorded?"
#
# On ss/ssc the answer was NO for six weeks: five mandatory (optional=0),
# everyone-audience (audience=0) tool_policy documents were published on
# 2026-07-23 while $CFG->sitepolicyhandler stayed '' — so core's default_handler
# was active, its is_defined() keyed off an equally empty $CFG->sitepolicy, and
# the site-policy branch of require_login() never fired. Zero acceptances.
#
# Reads and writes go through Moodle's OWN admin/cli/cfg.php — the same
# contained surface `pl moodle cli` already permits. No raw SQL, no DB
# credentials, no new remote-execution path.
#
# IDEMPOTENT. --apply on an already-armed site is a no-op that says so.
################################################################################
cmd_policy() {
    local site="" tier="" mode="dry-run" want_handler="$MOODLE_POLICY_HANDLER"
    for a in "$@"; do
        case "$a" in
            --tier=*)          tier="${a#*=}" ;;
            --dry-run)         mode="dry-run" ;;
            --apply|--execute) mode="execute" ;;
            --disarm)          want_handler="" ;;
            -h|--help)
                print_info "usage: pl moodle policy <site> --tier=live [--dry-run|--apply] [--disarm]"
                print_info "  (no flags = report only. --apply arms tool_policy. --disarm is the exact rollback.)"
                return 0 ;;
            -*) print_error "Unknown option: $a"; return 1 ;;
            *)  [ -z "$site" ] && site="$a" || { print_error "Unexpected arg: $a"; return 1; } ;;
        esac
    done
    [ -z "$site" ] && { print_error "usage: pl moodle policy <site> --tier=live [--dry-run|--apply] [--disarm]"; return 1; }
    case "$tier" in
        live) ;;
        "")   print_error "--tier is required (live)"; return 1 ;;
        *)    print_error "--tier must be live (stg is a local ddev tier for Moodle)"; return 1 ;;
    esac
    _resolve_moodle_site "$site" || return 1

    local server_ip ssh_user remote_path ssh_opts ssh_target sudo_prefix="" php_bin php_opts
    server_ip=$(get_live_config "$BASE" "server_ip")
    [ -z "$server_ip" ] && { print_error "No live server configured for '$BASE' (empty server_ip)."; return 1; }
    ssh_user=$(get_ssh_user "$BASE")
    remote_path=$(get_live_config "$BASE" "remote_path"); [ -z "$remote_path" ] && remote_path="/var/www/${BASE}"
    [ "$ssh_user" = "gitlab" ] && sudo_prefix="sudo"
    ssh_opts="$(nwp_ssh_opts "$BASE")"; ssh_target="${ssh_user}@${server_ip}"
    php_bin="$(moodle_cli_php_bin "$CONFIG_FILE")"
    php_opts="$(moodle_cli_php_opts "$CONFIG_FILE")"
    moodle_cli_assert "$php_bin" "$php_opts" || return 1

    local cfg="${remote_path%/}/admin/cli/cfg.php"
    local run="cd ${remote_path} && ${sudo_prefix} -u www-data ${php_bin} ${php_opts} ${cfg}"

    print_header "Moodle site-policy handler: ${BASE}@live"
    print_info "Target:  ${ssh_target}:${remote_path}"

    # --- READ (both facts, via Moodle's own CLI) -----------------------------
    local handler listing rc
    handler=$(ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "${run} --name=sitepolicyhandler --no-eol" 2>/dev/null); rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
        # 3 = "variable not set", which is a real answer. Anything else is not.
        print_error "Could not read sitepolicyhandler from ${BASE} live (ssh/cfg.php status ${rc})."
        print_info  "Refusing to report a verdict on a reading that did not happen."
        return 1
    fi
    listing=$(ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
        "${run} --component=${MOODLE_POLICY_SYNC_COMPONENT}" 2>/dev/null || true)

    local pointers verdict vrc
    pointers=$(moodle_policy_pointer_count "$listing")
    verdict=$(moodle_policy_verdict "$handler" "$pointers"); vrc=$?
    echo ""
    moodle_policy_explain "$verdict" "$handler" "$pointers" || true
    echo ""

    # --- REPORT-ONLY ---------------------------------------------------------
    if [ "$mode" != "execute" ]; then
        case "$verdict" in
            OK)      print_status "OK" "handler armed — nothing to do." ;;
            GAP)     print_info "Fix it:      pl moodle policy ${BASE} --tier=live --apply" ;;
            UNKNOWN) print_info "Investigate before treating ${BASE} as clear." ;;
        esac
        return "$vrc"
    fi

    # --- APPLY ---------------------------------------------------------------
    if [ "$handler" = "$want_handler" ]; then
        print_status "OK" "already set to '${want_handler:-(empty)}' — idempotent no-op."
        return 0
    fi
    if [ -n "$want_handler" ] && [ "$verdict" = "UNKNOWN" ]; then
        print_error "REFUSING to arm the handler on a site with no visible published documents."
        print_info  "  Arming it would present nothing, and the empty pointer set means this tool"
        print_info  "  cannot tell 'no policies' from 'cold pointer'. Establish which, then re-run."
        return 1
    fi

    local live_enabled; live_enabled=$(get_live_config "$BASE" "enabled")
    [ "$live_enabled" = "false" ] && { print_error "Live disabled for '$BASE' (live.enabled: false)."; return 1; }

    deploy_gate_require "$BASE" "live" "set \$CFG->sitepolicyhandler='${want_handler:-}' on live" || return 1
    impact_reset
    impact_overwrite "mdl_config" "sitepolicyhandler: '${handler:-}' -> '${want_handler:-}' on LIVE ${BASE}"
    if [ -n "$want_handler" ]; then
        impact_warn "Every non-siteadmin user is shown the published documents at next login and must accept."
        impact_warn "Site admins (\$CFG->siteadmins) are EXEMPT in core require_login() and are never interrupted."
    else
        impact_warn "Disarming: the published documents stop being presented. Existing acceptance rows are kept."
    fi
    impact_keep "tool_policy documents, versions and acceptances — not touched by this verb"
    impact_keep "config.php + moodledata — not touched by this verb"
    impact_render
    impact_confirm typed "$BASE" "${AUTO_CONFIRM:-false}" || { print_error "aborted."; return 1; }

    print_header "Setting the site-policy handler on live"
    # shellcheck disable=SC2086
    if ! ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
            "${run} --name=sitepolicyhandler --set=${want_handler}"; then
        print_error "cfg.php write FAILED — handler unchanged."
        return 1
    fi
    ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
        "cd ${remote_path} && ${sudo_prefix} -u www-data ${php_bin} ${php_opts} ${remote_path%/}/admin/cli/purge_caches.php" >/dev/null 2>&1 \
        || print_warning "purge_caches failed — run it manually: pl moodle cli ${BASE} --tier=live --execute -- admin/cli/purge_caches.php"

    local after
    after=$(ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "${run} --name=sitepolicyhandler --no-eol" 2>/dev/null || true)
    if [ "$after" != "$want_handler" ]; then
        print_error "VERIFY FAILED: handler reads '${after:-(empty)}', expected '${want_handler:-(empty)}'."
        return 1
    fi
    print_status "OK" "sitepolicyhandler = '${after:-(empty)}' on ${BASE} live (verified by re-read)."
    print_info  "Rollback: pl moodle policy ${BASE} --tier=live --apply --disarm"
    return 0
}

################################################################################
# mail — the site's DECLARED mail identity (operator ruling D7, 2026-08-02)
#
#   pl moodle mail <site> --tier=live [--dry-run|--apply] [--sync-golden]
#
# Declared in sites/<site>/.nwp.yml:
#
#   mail:
#     support_email:   support@<estate-domain>     # $CFG->supportemail
#     support_name:    Saint School Support    # $CFG->supportname
#     noreply_address: <sitekey>@<estate-domain>          # $CFG->noreplyaddress
#
# Report-only by DEFAULT (like `policy`). --apply takes the ADR-0028 deploy
# gate and a typed impact confirm, writes through admin/cli/cfg.php, and then
# RE-READS every field to verify — a write this verb did not confirm is a
# failure, not a success.
#
# THE REFUSAL IS THE POINT. Every declared address goes through
# moodle_mail_validate BEFORE anything is written, so the two faults that
# survived for months on live — `admin@<site>.<estate-domain>` (a domain with no MX)
# and `noreply@<site>1.ddev.site` (a dev domain on a live site) — are now
# unreachable states rather than things somebody has to notice.
#
# --- THE GOLDEN, for daily-reset demo sites ---------------------------------
# ssd is restored from a golden image every night by a forced command on the
# box (servers/live/demo/ssd-demo-reset-restricted). That path re-imports
# mdl_config wholesale and re-asserts NOTHING: a value written to live ssd is
# gone by 01:15. On a reset site the golden IS the durable configuration.
#
# So this verb also reads the golden, and `--sync-golden` appends an idempotent
# re-assertion tail to it (INSERT … ON DUPLICATE KEY UPDATE, applied last by
# `gunzip -c golden.db.sql.gz | mysql`). Appending is deliberate: it cannot
# corrupt the dump the way an in-place rewrite of mysqldump output can, and it
# leaves the 55-course catalogue and every other row untouched — which a
# recapture would not guarantee.
#
# The tail is self-healing. A later `pl demo golden <site> --tier=live` drops
# it, but by then live itself carries the declared values, so the recaptured
# mdl_config has them natively.
################################################################################

MOODLE_MAIL_TAIL_BEGIN="-- >>> nwp:mail-identity"
MOODLE_MAIL_TAIL_END="-- <<< nwp:mail-identity"

# _moodle_mail_declared <site> <yq-key> — the declared value, or empty.
_moodle_mail_declared() {
    get_site_config_value "$1" ".mail.$2" "" 2>/dev/null || true
}

# _moodle_mail_golden_dir <site> — echo the live golden dir if it exists.
_moodle_mail_golden_dir() {
    local d="${PROJECT_ROOT:-$REPO_ROOT}/sites/$1/demo-golden-live"
    [ -f "$d/golden.db.sql.gz" ] && printf '%s' "$d"
}

# _moodle_mail_golden_block <golden.db.sql.gz>
# Echo the managed mail-identity block already inside a golden dump, or nothing.
# awk, not grep: the markers begin with `--`, which grep reads as end-of-options
# (the first cut of this check compared the block with `grep -qF "$marker"` and
# died with "unrecognized option" — silently reporting GOLDEN-DRIFT on a golden
# that was in fact correct).
_moodle_mail_golden_block() {
    local gz="$1"
    [ -f "$gz" ] || return 0
    gunzip -c "$gz" 2>/dev/null | awk -v b="$MOODLE_MAIL_TAIL_BEGIN" -v e="$MOODLE_MAIL_TAIL_END" '
        index($0, b) == 1 { inblk = 1 }
        inblk { print }
        index($0, e) == 1 { inblk = 0 }
    '
}

# _moodle_mail_tail <site> <declared-pairs...>  (each "cfgname=value")
_moodle_mail_tail() {
    local site="$1"; shift
    printf '%s %s (managed by `pl moodle mail`) — do not edit by hand\n' \
        "$MOODLE_MAIL_TAIL_BEGIN" "$site"
    printf -- '-- Re-asserted after every nightly golden restore. See lib/moodle-mail.sh.\n'
    local kv name value
    for kv in "$@"; do
        name="${kv%%=*}"; value="${kv#*=}"
        # Single quotes are the only metacharacter that matters here, and every
        # value has already passed moodle_mail_validate (no whitespace, no
        # quotes in an address). supportname is free text, so escape anyway.
        value="${value//\'/\'\'}"
        printf "INSERT INTO mdl_config (name,value) VALUES ('%s','%s') ON DUPLICATE KEY UPDATE value=VALUES(value);\n" \
            "$name" "$value"
    done
    printf '%s\n' "$MOODLE_MAIL_TAIL_END"
}

cmd_mail() {
    local site="" tier="" mode="dry-run" sync_golden="false"
    for a in "$@"; do
        case "$a" in
            --tier=*)          tier="${a#*=}" ;;
            --dry-run|--check) mode="dry-run" ;;
            --apply|--execute) mode="execute" ;;
            --sync-golden)     sync_golden="true" ;;
            -h|--help)
                print_info "usage: pl moodle mail <site> --tier=live [--dry-run|--apply] [--sync-golden]"
                print_info "  (no flags = report only. --apply writes and re-reads to verify.)"
                print_info "  --sync-golden re-asserts the identity in the demo golden image."
                return 0 ;;
            -*) print_error "Unknown option: $a"; return 1 ;;
            *)  [ -z "$site" ] && site="$a" || { print_error "Unexpected arg: $a"; return 1; } ;;
        esac
    done
    [ -z "$site" ] && { print_error "usage: pl moodle mail <site> --tier=live [--dry-run|--apply]"; return 1; }
    case "$tier" in
        live) ;;
        "")   print_error "--tier is required (live)"; return 1 ;;
        *)    print_error "--tier must be live (stg is a local ddev tier for Moodle)"; return 1 ;;
    esac
    _resolve_moodle_site "$site" || return 1

    local root="${PROJECT_ROOT:-$REPO_ROOT}"

    print_header "Moodle mail identity: ${BASE}@live"

    # --- 1. READ THE DECLARATION --------------------------------------------
    local -a want_names=() want_values=() want_keys=()
    local f key cfgname value declared_any="false"
    for f in "${MOODLE_MAIL_FIELDS[@]}"; do
        key="${f%%|*}"; cfgname="${f##*|}"
        value="$(_moodle_mail_declared "$BASE" "$key")"
        want_keys+=("$key"); want_names+=("$cfgname"); want_values+=("$value")
        [ -n "$value" ] && declared_any="true"
    done

    if [ "$declared_any" != "true" ]; then
        print_error "No mail: block declared in sites/${BASE}/.nwp.yml — nothing to enforce."
        print_info  "Declare it (see example.nwp.yml → sites.<name>.mail):"
        print_info  "    mail:"
        print_info  "      support_email:   support@<estate-domain>"
        print_info  "      support_name:    <Site> Support"
        print_info  "      noreply_address: ${BASE}@<estate-domain>"
        return 1
    fi

    # --- 2. GATE THE DECLARATION (before anything is written) ----------------
    print_info "Declared identity (sites/${BASE}/.nwp.yml → mail:)"
    local i refusals=0 unverifiable=0 reason rc
    for i in "${!want_names[@]}"; do
        cfgname="${want_names[$i]}"; value="${want_values[$i]}"
        [ -z "$value" ] && { printf '  %-16s %s\n' "$cfgname:" "(not declared — left alone)"; continue; }
        printf '  %-16s %s\n' "$cfgname:" "$value"
        if moodle_mail_field_is_address "$cfgname"; then
            reason="$(moodle_mail_validate "$value" "$root")"; rc=$?
        else
            # Free text: still refuse a dev-domain leak hiding in a display name.
            reason="OK: free text"; rc=0
            if moodle_mail_is_dev_domain "$(moodle_mail_domain_of "$value")"; then
                reason="REFUSE: ${cfgname} carries a development domain"; rc=1
            fi
        fi
        case $rc in
            0) printf '                   %s\n' "$reason" ;;
            2) print_warning "  $reason"; unverifiable=$((unverifiable + 1)) ;;
            *) print_error   "  $reason"; refusals=$((refusals + 1)) ;;
        esac
    done
    echo ""

    if [ "$refusals" -gt 0 ]; then
        print_error "REFUSING: ${refusals} declared address(es) cannot receive mail."
        print_info  "Fix the declaration, or alias the address and re-track the baseline:"
        print_info  "    pl email add <localpart> --forward-only <target> -y --host=<server>"
        print_info  "    pl email baseline <server>"
        return 1
    fi

    # --- 3. READ LIVE --------------------------------------------------------
    local server_ip ssh_user remote_path ssh_opts ssh_target sudo_prefix="" php_bin php_opts
    server_ip=$(get_live_config "$BASE" "server_ip")
    [ -z "$server_ip" ] && { print_error "No live server configured for '$BASE' (empty server_ip)."; return 1; }
    ssh_user=$(get_ssh_user "$BASE")
    remote_path=$(get_live_config "$BASE" "remote_path"); [ -z "$remote_path" ] && remote_path="/var/www/${BASE}"
    [ "$ssh_user" = "gitlab" ] && sudo_prefix="sudo"
    ssh_opts="$(nwp_ssh_opts "$BASE")"; ssh_target="${ssh_user}@${server_ip}"
    php_bin="$(moodle_cli_php_bin "$CONFIG_FILE")"
    php_opts="$(moodle_cli_php_opts "$CONFIG_FILE")"
    moodle_cli_assert "$php_bin" "$php_opts" || return 1

    local cfg="${remote_path%/}/admin/cli/cfg.php"
    local run="cd ${remote_path} && ${sudo_prefix} -u www-data ${php_bin} ${php_opts} ${cfg}"

    print_info "Target:  ${ssh_target}:${remote_path}"
    echo ""

    local -a have_values=()
    local drift=0 verdict
    for i in "${!want_names[@]}"; do
        cfgname="${want_names[$i]}"
        # shellcheck disable=SC2029
        value="$(ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "${run} --name=${cfgname} --no-eol" 2>/dev/null)"; rc=$?
        if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
            print_error "Could not read ${cfgname} from ${BASE} live (ssh/cfg.php status ${rc})."
            print_info  "Refusing to report a verdict on a reading that did not happen."
            return 1
        fi
        have_values+=("$value")
    done

    print_info "Live vs declared"
    for i in "${!want_names[@]}"; do
        cfgname="${want_names[$i]}"
        verdict="$(moodle_mail_verdict "${want_values[$i]}" "${have_values[$i]}")" || true
        case "$verdict" in
            OK)    printf '  %-16s %-34s OK\n'    "$cfgname:" "${have_values[$i]:-(empty)}" ;;
            UNSET) printf '  %-16s %-34s (not declared)\n' "$cfgname:" "${have_values[$i]:-(empty)}" ;;
            DRIFT) printf '  %-16s %-34s DRIFT -> %s\n' "$cfgname:" "${have_values[$i]:-(empty)}" "${want_values[$i]}"
                   drift=$((drift + 1)) ;;
        esac
    done
    echo ""

    # --- 4. THE GOLDEN (daily-reset demo sites) ------------------------------
    local golden_dir golden_drift=0
    golden_dir="$(_moodle_mail_golden_dir "$BASE")" || true
    local -a tail_pairs=()
    for i in "${!want_names[@]}"; do
        [ -n "${want_values[$i]}" ] && tail_pairs+=("${want_names[$i]}=${want_values[$i]}")
    done
    if [ -n "$golden_dir" ]; then
        local want_tail have_tail
        want_tail="$(_moodle_mail_tail "$BASE" "${tail_pairs[@]}")"
        have_tail="$(_moodle_mail_golden_block "$golden_dir/golden.db.sql.gz")"
        if [ -z "$have_tail" ]; then
            print_warning "GOLDEN-DRIFT: ${BASE} is restored from a golden nightly, and that golden does NOT"
            print_warning "              re-assert the mail identity — a live write here is undone by 01:15."
            golden_drift=1
        elif [ "$have_tail" != "$want_tail" ]; then
            print_warning "GOLDEN-DRIFT: the golden's mail-identity block does not match the declaration"
            golden_drift=1
        else
            print_status "OK" "golden image re-asserts the declared identity after every reset"
        fi
        [ "$golden_drift" -eq 1 ] && print_info "Fix it: add --sync-golden"
        echo ""
    fi

    # --- 5. REPORT-ONLY ------------------------------------------------------
    if [ "$mode" != "execute" ]; then
        if [ "$drift" -eq 0 ] && [ "$golden_drift" -eq 0 ]; then
            [ "$unverifiable" -gt 0 ] && { print_warning "clean, but ${unverifiable} address(es) could not be verified."; return 2; }
            print_status "OK" "${BASE} live matches its declared mail identity."
            return 0
        fi
        print_info "Fix it:      pl moodle mail ${BASE} --tier=live --apply$([ "$golden_drift" -eq 1 ] && printf ' --sync-golden')"
        return 1
    fi

    # --- 6. APPLY ------------------------------------------------------------
    if [ "$unverifiable" -gt 0 ]; then
        print_error "REFUSING to write: ${unverifiable} declared address(es) could not be verified as deliverable."
        print_info  "A CANNOT-VERIFY is not a pass — install a resolver (dig) and re-run."
        return 1
    fi
    if [ "$drift" -eq 0 ] && [ "$golden_drift" -eq 0 ]; then
        print_status "OK" "already matches — idempotent no-op."
        return 0
    fi

    local live_enabled; live_enabled=$(get_live_config "$BASE" "enabled")
    [ "$live_enabled" = "false" ] && { print_error "Live disabled for '$BASE' (live.enabled: false)."; return 1; }

    if [ "$drift" -gt 0 ]; then
        deploy_gate_require "$BASE" "live" "set the mail identity on live ${BASE}" || return 1
        impact_reset
        for i in "${!want_names[@]}"; do
            verdict="$(moodle_mail_verdict "${want_values[$i]}" "${have_values[$i]}")" || true
            [ "$verdict" = "DRIFT" ] && impact_overwrite "mdl_config" \
                "${want_names[$i]}: '${have_values[$i]:-(empty)}' -> '${want_values[$i]}' on LIVE ${BASE}"
        done
        impact_warn "Automated mail from ${BASE} changes its From:/support address at the next send."
        impact_keep "\$CFG->noemailever and \$CFG->divertallemailsto — NOT touched by this verb"
        impact_keep "courses, users, moodledata — not touched by this verb"
        impact_render
        impact_confirm typed "$BASE" "${AUTO_CONFIRM:-false}" || { print_error "aborted."; return 1; }

        print_header "Writing the mail identity on live"
        for i in "${!want_names[@]}"; do
            verdict="$(moodle_mail_verdict "${want_values[$i]}" "${have_values[$i]}")" || true
            [ "$verdict" = "DRIFT" ] || continue
            cfgname="${want_names[$i]}"; value="${want_values[$i]}"
            # shellcheck disable=SC2029
            if ! ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
                    "${run} --name=${cfgname} --set=$(printf '%q' "$value")"; then
                print_error "cfg.php write FAILED for ${cfgname} — stopping."
                return 1
            fi
        done
        # shellcheck disable=SC2029
        ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
            "cd ${remote_path} && ${sudo_prefix} -u www-data ${php_bin} ${php_opts} ${remote_path%/}/admin/cli/purge_caches.php" >/dev/null 2>&1 \
            || print_warning "purge_caches failed — run: pl moodle cli ${BASE} --tier=live --execute -- admin/cli/purge_caches.php"

        # VERIFY BY RE-READ. A write this verb did not confirm is a failure.
        local after fail=0
        for i in "${!want_names[@]}"; do
            [ -n "${want_values[$i]}" ] || continue
            cfgname="${want_names[$i]}"
            # shellcheck disable=SC2029
            after="$(ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "${run} --name=${cfgname} --no-eol" 2>/dev/null || true)"
            if [ "$after" != "${want_values[$i]}" ]; then
                print_error "VERIFY FAILED: ${cfgname} reads '${after:-(empty)}', expected '${want_values[$i]}'."
                fail=1
            else
                print_status "OK" "${cfgname} = '${after}' (verified by re-read)"
            fi
        done
        [ "$fail" -eq 0 ] || return 1
    fi

    # --- 7. THE GOLDEN -------------------------------------------------------
    if [ "$sync_golden" = "true" ]; then
        if [ -z "$golden_dir" ]; then
            print_error "--sync-golden: no golden image at sites/${BASE}/demo-golden-live/"
            return 1
        fi
        _moodle_mail_sync_golden "$BASE" "$golden_dir" "${tail_pairs[@]}" || return 1
    elif [ "$golden_drift" -eq 1 ]; then
        print_warning "The golden still does NOT carry this identity — the nightly reset will undo it."
        print_info    "Run: pl moodle mail ${BASE} --tier=live --apply --sync-golden"
        return 1
    fi

    return 0
}

# _moodle_mail_sync_golden <site> <golden_dir> <pairs...>
# Strip any previous tail, append the current one, re-checksum, re-manifest.
# Everything is done on a COPY and moved into place only once every step has
# succeeded — a half-written golden is a site that cannot be restored.
_moodle_mail_sync_golden() {
    local site="$1" dir="$2"; shift 2
    local gz="$dir/golden.db.sql.gz"

    print_header "Re-asserting the mail identity in the golden image"

    # No RETURN trap here: a RETURN trap also fires for the command
    # substitutions below, which would delete the workspace mid-function. Clean
    # up explicitly on every exit path instead.
    local tmp; tmp="$(mktemp -d)" || return 1
    _mmsg_cleanup() { rm -rf "$tmp"; }

    if ! gunzip -c "$gz" > "$tmp/golden.sql" 2>/dev/null; then
        print_error "Cannot decompress $gz"
        _mmsg_cleanup; return 1
    fi
    local before_bytes; before_bytes=$(wc -c < "$tmp/golden.sql")

    # Drop any previous managed block (idempotent re-runs).
    awk -v b="$MOODLE_MAIL_TAIL_BEGIN" -v e="$MOODLE_MAIL_TAIL_END" '
        index($0, b) == 1 { skip = 1 }
        skip != 1 { print }
        index($0, e) == 1 { skip = 0 }
    ' "$tmp/golden.sql" > "$tmp/stripped.sql"

    _moodle_mail_tail "$site" "$@" >> "$tmp/stripped.sql"

    if ! gzip -c "$tmp/stripped.sql" > "$tmp/golden.db.sql.gz"; then
        print_error "Recompression failed — golden left untouched."
        _mmsg_cleanup; return 1
    fi
    # Sanity: the rewritten dump must still decompress and still be the same
    # order of magnitude. A truncated golden is worse than a stale one.
    local after_bytes
    after_bytes=$(gunzip -c "$tmp/golden.db.sql.gz" | wc -c) || { print_error "Rewritten golden will not decompress."; _mmsg_cleanup; return 1; }
    if [ "$after_bytes" -lt "$before_bytes" ]; then
        print_error "Rewritten golden SHRANK (${before_bytes} -> ${after_bytes} bytes) — refusing."
        _mmsg_cleanup; return 1
    fi

    local sum; sum="$(sha256sum "$tmp/golden.db.sql.gz" | awk '{print $1}')"
    cp "$tmp/golden.db.sql.gz" "$gz" || { _mmsg_cleanup; return 1; }
    ( cd "$dir" && sha256sum golden.db.sql.gz > golden.db.sql.gz.sha256 ) || { _mmsg_cleanup; return 1; }

    # Keep the manifest honest — install-box.sh re-verifies it on staging.
    local man="$dir/golden.manifest.json"
    if [ -f "$man" ] && command -v jq >/dev/null 2>&1; then
        local newman; newman="$(jq --arg s "$sum" '.db_sha256 = $s' "$man")" || { _mmsg_cleanup; return 1; }
        printf '%s\n' "$newman" > "$man"
    fi
    _mmsg_cleanup

    print_status "OK" "golden re-asserts the mail identity (+$((after_bytes - before_bytes)) bytes, db_sha256 ${sum:0:12}…)"
    print_info  "Stage it to the box:  bash servers/live/demo/install-box.sh ${site} --stage-golden"
    return 0
}

################################################################################
# core-patch — declared Moodle CORE patches (item 9)
#
# DECLARATION RESOLUTION (first hit wins):
#   1. sites/<base>/core-patches.yml                      site-local override.
#      sites/* is gitignored in nwp/nwp, so this rung is for local/test use —
#      never the durable home.
#   2. <plugin-repo cache>/core-patches/<base>.yml        CANONICAL. Lives in
#      nwp/ss-moodle-plugins, i.e. under version control, and arrives via
#      `pl moodle plugins sync <site> --apply` like everything else.
# A declaration that lives only in a gitignored tree is the same disease as the
# unversioned core patch it is meant to catch, so rung 2 is the real answer.
################################################################################

_moodle_core_patches_decl() {
    local base="$1" config_file="$2" f
    f="$(moodle_core_patches_file "$base")"
    if [ -s "$f" ]; then printf '%s' "$f"; return 0; fi
    local repo cache
    repo="$(_moodle_plugins_repo "$config_file")"
    cache="$(_moodle_plugin_cache "$base" "$repo")"
    f="${cache}/core-patches/${base}.yml"
    if [ -s "$f" ]; then printf '%s' "$f"; return 0; fi
    printf '%s' "$(moodle_core_patches_file "$base")"   # non-existent ⇒ clean no-op
}

cmd_core_patch() {
    local action="${1:-status}"; shift || true
    local site="" root_override="" want_live="false"
    for a in "$@"; do
        case "$a" in
            --root=*) root_override="${a#*=}" ;;
            --live)   want_live="true" ;;
            -*)       print_error "Unknown option: $a"; return 1 ;;
            *)        [ -z "$site" ] && site="$a" || { print_error "Unexpected arg: $a"; return 1; } ;;
        esac
    done
    case "$action" in status|list) ;; *) print_error "Unknown 'core-patch' action: $action (status|list)"; return 1 ;; esac
    [ -z "$site" ] && { print_error "usage: pl moodle core-patch status <site> [--root=DIR|--live]"; return 1; }
    _resolve_moodle_site "$site" || return 1

    local decl; decl="$(_moodle_core_patches_decl "$BASE" "$CONFIG_FILE")"
    # TRI-STATE read (2026-07-27). The old form was
    #   mapfile -t ids < <(moodle_core_patch_ids "$decl")
    # which discards the reader's exit status inside the process substitution, so
    # "the declaration is unreadable" arrived here as an empty array and printed
    # "no core patches declared" — emptying a gate whose refusal has no override
    # by design. rc 2 is now its own answer and it REFUSES.
    local _cp_out="" _cp_rc=0
    _cp_out="$(moodle_core_patch_ids "$decl")" || _cp_rc=$?
    print_header "Declared Moodle core patches: ${BASE}"
    if [ "$_cp_rc" -eq 2 ]; then
        print_error "CANNOT VERIFY the core-patch declaration for '${BASE}':"
        print_error "  ${_cp_out}"
        print_error "This is NOT a clean result: no patches were checked because none could be READ."
        print_info  "  Declaration: ${decl#$PROJECT_ROOT/}"
        print_info  "  Fix the file, or remove it if this site genuinely has no core patches."
        return 1
    fi
    local -a ids=()
    [ -n "$_cp_out" ] && mapfile -t ids <<< "$_cp_out"
    if [ "${#ids[@]}" -eq 0 ]; then
        print_info "no core patches declared for ${BASE} (${decl#$PROJECT_ROOT/})"
        return 0
    fi

    # Resolve the target tree: --root wins; --live queries the live webroot;
    # otherwise the dev tree.
    local target="" mode="local"
    if [ -n "$root_override" ]; then
        target="$root_override"
    elif [ "$want_live" = "true" ]; then
        mode="live"
    else
        target="$PROJECT_ROOT/sites/${BASE}/dev"
    fi

    local ssh_target="" ssh_opts="" sudo_prefix="" remote_path=""
    if [ "$mode" = "live" ]; then
        local server_ip ssh_user
        server_ip=$(get_live_config "$BASE" "server_ip")
        [ -z "$server_ip" ] && { print_error "No live server configured for '$BASE'."; return 1; }
        ssh_user=$(get_ssh_user "$BASE")
        remote_path=$(get_live_config "$BASE" "remote_path"); [ -z "$remote_path" ] && remote_path="/var/www/${BASE}"
        [ "$ssh_user" = "gitlab" ] && sudo_prefix="sudo"
        ssh_opts="$(nwp_ssh_opts "$BASE")"; ssh_target="${ssh_user}@${server_ip}"
        print_info "target: LIVE ${ssh_target}:${remote_path}"
    else
        print_info "target: ${target}"
    fi

    local id file assert why st problems=0
    for id in "${ids[@]}"; do
        [ -n "$id" ] || continue
        file="$(moodle_core_patch_field "$decl" "$id" file)"
        assert="$(moodle_core_patch_field "$decl" "$id" assert)"
        why="$(moodle_core_patch_field "$decl" "$id" why)"
        if [ -z "$file" ] || [ -z "$assert" ]; then
            printf '    %-38s %-14s %s\n' "$id" "[INVALID]" "declaration needs both 'file:' and 'assert:'"
            problems=$((problems+1)); continue
        fi
        if [ "$mode" = "live" ]; then
            moodle_core_patch_check_remote "$ssh_target" "$ssh_opts" "$sudo_prefix" "$remote_path" "$file" "$assert"
        else
            moodle_core_patch_check_local "$target" "$file" "$assert"
        fi
        case "$?" in
            0) st="APPLIED" ;;
            1) st="MISSING"; problems=$((problems+1)) ;;
            2) st="FILE-ABSENT"; problems=$((problems+1)) ;;
            *) st="UNREACHABLE"; problems=$((problems+1)) ;;
        esac
        printf '    %-38s %-14s %s — %s\n' "$id" "[$st]" "$file" "${why:-(no rationale recorded)}"
    done

    if [ "$problems" -gt 0 ]; then
        print_error "${problems} declared core patch(es) are NOT verified present on the target."
        print_info  "A declared patch that is not applied means the target is running DIFFERENT core code"
        print_info  "than the one this site was validated against. Re-apply it, or remove the declaration."
        return 1
    fi
    print_status "OK" "every declared core patch is present on the target."
    return 0
}

################################################################################
# plugin drift — version.php across every known copy (item 9)
################################################################################
cmd_plugin_drift() {
    local site="" want_live="true" want_canon="true" canon_ref=""
    local -a plugins=() trees=()
    for a in "$@"; do
        case "$a" in
            --tree=*)         trees+=("${a#*=}") ;;
            --no-live)        want_live="false" ;;
            --no-canonical)   want_canon="false" ;;
            --canonical-ref=*) canon_ref="${a#*=}" ;;
            -*)        print_error "Unknown option: $a"; return 1 ;;
            *)         if [ -z "$site" ]; then site="$a"; else plugins+=("$a"); fi ;;
        esac
    done
    [ -z "$site" ] && { print_error "usage: pl moodle plugin drift <site> [<plugin>...] [--tree=DIR]... [--no-live] [--no-canonical] [--canonical-ref=REF]"; return 1; }
    _resolve_moodle_site "$site" || return 1
    if [ "${#plugins[@]}" -eq 0 ]; then
        mapfile -t plugins < <(_moodle_configured_plugins "$CONFIG_FILE")
        [ "${#plugins[@]}" -eq 0 ] && { print_error "No plugins given and none configured under .moodle.plugins."; return 1; }
    fi

    # The canonical repo checkout is resolved INDEPENDENTLY of the tree list, so
    # `--tree=` runs are still measured against canonical rather than silently
    # dropping the strongest comparison the verb has.
    local canon_repo="" repo cache
    repo="$(_moodle_plugins_repo "$CONFIG_FILE")"
    cache="$(_moodle_plugin_cache "$BASE" "$repo")"
    canon_repo="${NWP_MOODLE_CANONICAL_REPO:-$cache}"
    [ -z "$canon_ref" ] && canon_ref="${NWP_MOODLE_CANONICAL_REF:-origin/$(_moodle_plugins_ref "$CONFIG_FILE")}"

    # Default tree set: the dev tree, the canonical repo cache, and the legacy
    # in-repo f26 copy (which is exactly the stale one — 2026071101/1.0.0).
    if [ "${#trees[@]}" -eq 0 ]; then
        trees=("$PROJECT_ROOT/sites/${BASE}/dev" "$cache")
    fi

    print_header "Moodle plugin version drift: ${BASE}"
    local total_problems=0 p t v seen ver_ref ref_tree copies max_copy canon_unknown=0
    for p in "${plugins[@]}"; do
        [ -n "$p" ] || continue
        echo "  ${p}"
        copies=0; ver_ref=""; ref_tree=""; seen=0; max_copy=""
        for t in "${trees[@]}"; do
            v="$(moodle_plugin_version_local "$t" "$p" 2>/dev/null || true)"
            if [ -z "$v" ]; then
                printf '    %-52s %s\n' "${t}" "(absent)"
                continue
            fi
            copies=$((copies+1))
            if [ -z "$max_copy" ] || [ "$v" -gt "$max_copy" ] 2>/dev/null; then max_copy="$v"; fi
            if [ -z "$ver_ref" ]; then ver_ref="$v"; ref_tree="$t"; fi
            if [ "$v" != "$ver_ref" ]; then
                printf '    %-52s %-12s %s\n' "${t}" "$v" "[DRIFT vs ${ver_ref}]"
                seen=1
            else
                printf '    %-52s %-12s\n' "${t}" "$v"
            fi
        done
        if [ "$want_live" = "true" ]; then
            local server_ip ssh_user remote_path ssh_opts sudo_prefix="" lv
            server_ip=$(get_live_config "$BASE" "server_ip")
            if [ -n "$server_ip" ]; then
                ssh_user=$(get_ssh_user "$BASE")
                remote_path=$(get_live_config "$BASE" "remote_path"); [ -z "$remote_path" ] && remote_path="/var/www/${BASE}"
                [ "$ssh_user" = "gitlab" ] && sudo_prefix="sudo"
                ssh_opts="$(nwp_ssh_opts "$BASE")"
                lv="$(moodle_plugin_version_remote "${ssh_user}@${server_ip}" "$ssh_opts" "$sudo_prefix" "$remote_path" "$p" 2>/dev/null || true)"
                if [ -z "$lv" ]; then
                    printf '    %-52s %s\n' "LIVE ${remote_path}/${p}" "(unreachable or absent)"
                else
                    copies=$((copies+1))
                    if [ -z "$max_copy" ] || [ "$lv" -gt "$max_copy" ] 2>/dev/null; then max_copy="$lv"; fi
                    if [ -z "$ver_ref" ]; then ver_ref="$lv"; fi
                    if [ "$lv" != "$ver_ref" ]; then
                        printf '    %-52s %-12s %s\n' "LIVE ${remote_path}/${p}" "$lv" "[DRIFT vs ${ver_ref}]"
                        seen=1
                    else
                        printf '    %-52s %-12s\n' "LIVE ${remote_path}/${p}" "$lv"
                    fi
                fi
            fi
        fi
        # BACKUP-SUBPLUGIN CAPABILITY. Version equality is not sameness: a copy
        # missing backup/moodle2/ has a byte-identical version.php to one that
        # has it, so this verb reported "every compared copy agrees" for live
        # ssc while every course backup it took silently dropped all 247
        # depthcontent activities. Compare the CAPABILITY too, or the verb is
        # blind to the one difference that loses data without erroring.
        local cap blind_copies=0
        for t in "${trees[@]}"; do
            cap="$(moodle_plugin_backup_capable_local "$t" "$p")"
            case "$cap" in
                blind) printf '    %-52s %s\n' "${t}" "[BACKUP-BLIND: claims FEATURE_BACKUP_MOODLE2, ships no task class]"
                       blind_copies=$((blind_copies+1)) ;;
            esac
        done
        if [ "$want_live" = "true" ] && [ -n "${server_ip:-}" ]; then
            cap="$(moodle_plugin_backup_capable_remote "${ssh_user}@${server_ip}" "$ssh_opts" "$sudo_prefix" "$remote_path" "$p")"
            case "$cap" in
                blind) printf '    %-52s %s\n' "LIVE ${remote_path}/${p}" "[BACKUP-BLIND: claims FEATURE_BACKUP_MOODLE2, ships no task class]"
                       blind_copies=$((blind_copies+1)) ;;
            esac
        fi
        if [ "$blind_copies" -gt 0 ]; then
            print_error "  BACKUP-BLIND: ${blind_copies} copy(ies) of ${p} advertise Moodle2 backup with no backup/moodle2/ task class."
            print_info  "  Moodle SKIPS such activities during backup without erroring — restores look clean and are empty."
            total_problems=$((total_problems+1))
        fi

        # CANONICAL COMPARISON (ops#259). Every check above asks "are the copies
        # the same as EACH OTHER?" — a question with a true-and-useless answer
        # when the whole fleet is equally stale. Measured 2026-08-03: ssd's dev
        # tree, plugin cache and LIVE all said local/feedback 2026051704 and this
        # verb printed "every compared copy agrees", while canonical main was
        # 2026080101 — the range that added classes/privacy/provider.php. So live
        # Moodle had no GDPR handler for a table of userid/username/email/ip and
        # the sameness verb said OK. Uniform staleness IS the finding.
        if [ "$want_canon" = "true" ]; then
            local cver
            if cver="$(moodle_plugin_version_canonical "$canon_repo" "$p" "$canon_ref" 2>/dev/null)" && [ -n "$cver" ]; then
                printf '    %-52s %-12s %s\n' "CANONICAL ${canon_ref}" "$cver" "(${canon_repo})"
                if [ -n "$max_copy" ] && [ "$max_copy" -lt "$cver" ] 2>/dev/null; then
                    print_error "  BEHIND-CANONICAL: no copy of ${p} is newer than ${max_copy}; ${canon_ref} is at ${cver}."
                    print_info  "  Everything agreeing on a STALE version is not agreement — merged is not in force (ops#206)."
                    print_info  "  Fix it: pl moodle plugins sync ${BASE} --apply, then pl moodle plugin deploy ${BASE} ${p} --tier=live --apply"
                    total_problems=$((total_problems+1))
                elif [ -n "$max_copy" ] && [ "$max_copy" -gt "$cver" ] 2>/dev/null; then
                    # Deliberately NOT an error: an unmerged REVIEW branch legitimately
                    # runs ahead on dev. It is still worth saying out loud, because code
                    # on LIVE that is ahead of canonical is code no review gate has seen.
                    print_warning "  AHEAD-OF-CANONICAL: a copy of ${p} is at ${max_copy}, ${canon_ref} is at ${cver} — unmerged work is deployed."
                fi
            else
                # "I could not look" is never "it is fine". Say so, and make the
                # closing verdict admit the comparison did not happen.
                printf '    %-52s %s\n' "CANONICAL ${canon_ref}" "[CANONICAL-UNKNOWN — cannot read ${canon_ref}:${p}/version.php in ${canon_repo:-(no repo)}]"
                canon_unknown=1
            fi
        else
            canon_unknown=1
        fi

        # "I found nothing" must NEVER read as "everything agrees" — that is the
        # vacuous-pass class this programme exists to eliminate.
        if [ "$copies" -lt 2 ]; then
            print_error "  cannot verify ${p}: found ${copies} copy(ies), need at least 2 to compare."
            total_problems=$((total_problems+1))
        elif [ "$seen" -eq 1 ]; then
            print_error "  DRIFT: copies of ${p} disagree on \$plugin->version."
            total_problems=$((total_problems+1))
        fi
        echo ""
    done

    if [ "$total_problems" -gt 0 ]; then
        print_error "${total_problems} plugin(s) drifted or unverifiable."
        print_info  "A deploy from the LOWER-versioned tree silently DOWNGRADES live and can drop"
        print_info  "gates that shipped in the higher version (auth_nwc carries the Art.9 consent gate)."
        print_info  "Canonical source: nwp/ss-moodle-plugins — pl moodle plugins sync ${BASE} --apply"
        return 1
    fi
    if [ "$canon_unknown" -eq 1 ]; then
        print_status "OK" "every compared copy agrees on \$plugin->version — but CANONICAL WAS NOT COMPARED."
        print_info  "The copies agreeing with each other does not mean they carry what ${canon_ref:-canonical} carries."
        return 0
    fi
    print_status "OK" "every compared copy agrees on \$plugin->version, and matches ${canon_ref}."
    return 0
}

################################################################################
# course restore — guarded bulk course import from .mbz backups
#
#   pl moodle course restore <site> --tier=live|dev --from=DIR
#       [--category=NAME | --category-map=FILE] [--enable-self-enrol]
#       [--dry-run|--apply]
#
# Replaces the hand idiom (scp *.mbz + ssh 'sudo -u www-data php
# admin/cli/restore_backup.php …' per file) with one verb that keeps the
# guarantees:
#   * dry-run DEFAULT; a LIVE --apply takes the ADR-0028 deploy gate and the
#     typed impact confirm;
#   * accepts ONLY files named backup-moodle2-course-*.mbz — no traversal, no
#     symlinks, no shell-hostile names (the names end up in remote commands);
#   * PII FAIL-CLOSE: each mbz's moodle_backup.xml is parsed LOCALLY, BEFORE
#     any byte ships. A backup with users=1, or with no readable `users`
#     setting at all, is REFUSED unless anonymize=1 — course backups are the
#     one Moodle artifact that can silently carry the whole user table;
#   * IDEMPOTENT: shortnames already present on the target are skipped (staged
#     read-only query), so a re-run after a partial failure is safe;
#   * artifacts reach the box via the sha256-verified push (the
#     demo_push_verified contract: scp to remote home, verify the hash ON THE
#     REMOTE, use, delete) — a corrupt upload is caught before restore runs;
#   * per-course restore via admin/cli/restore_backup.php as www-data, through
#     the resolved php + max_input_vars (moodle_cli_assert — item 9);
#   * post-pass ASSERTS every restored course is visible=1 with an enabled,
#     keyless self-enrolment (generalised from scripts/demo/ssd-seed-courses.php
#     --check) — a course a tester cannot walk into is a restore that failed
#     its purpose, and must say so;
#   * --enable-self-enrol (EXPLICIT opt-in): restore_backup.php provably
#     brings courses up WITHOUT an enabled self-enrolment (ssd rehearsal,
#     2026-08-01 — every restored course ENTER-FAILed). With the flag, each
#     course THIS run restored is made enterable exactly the way the ssd
#     seeder does it (visible + enabled keyless self-enrol, same plugin
#     settings) BEFORE the post-pass asserts. Never retrofits pre-existing
#     (skipped) courses; without the flag behaviour is unchanged and the
#     post-pass fails loudly;
#   * --category-map=FILE maps shortname-prefix → category name (creating
#     categories as needed), e.g. the four formation rails:
#         b = Your Yes
#         c = Prayer & Recollection
#         d = Ascesis
#         e = Sacraments
#     A shortname no prefix matches is a REFUSAL, not a silent default.
################################################################################

# The staged remote helper (list-shortnames / ensure-category / assert-enterable).
CR_HELPER="${CR_HELPER:-$REPO_ROOT/scripts/moodle/course-restore-check.php}"

_cr_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# _cr_extract_backup_xml <mbz> <outfile> — moodle_backup.xml only, locally.
# .mbz is a tgz on this estate (verified against the 2026-07-11 ss set), but
# Moodle also emits zip-flavoured .mbz — accept both, refuse anything else.
_cr_extract_backup_xml() {
    local mbz="$1" out="$2"
    if tar -xzf "$mbz" -O moodle_backup.xml > "$out" 2>/dev/null && [ -s "$out" ]; then return 0; fi
    if command -v unzip >/dev/null 2>&1 \
        && unzip -p "$mbz" moodle_backup.xml > "$out" 2>/dev/null && [ -s "$out" ]; then return 0; fi
    return 1
}

# _cr_backup_setting <xmlfile> <name> — value of a ROOT-level backup setting.
# Prints nothing when the setting is absent (callers must fail-close on that).
_cr_backup_setting() {
    awk -v want="$2" 'BEGIN{RS="</setting>"}
        /<level>root<\/level>/ && $0 ~ ("<name>" want "</name>") {
            if (match($0, /<value>[^<]*<\/value>/)) {
                print substr($0, RSTART+7, RLENGTH-15); exit
            }
        }' "$1"
}

_cr_backup_shortname() {
    sed -n 's/.*<original_course_shortname>\([^<]*\)<\/original_course_shortname>.*/\1/p' "$1" | head -1
}

# Category map: `prefix = Category Name` lines, `#` comments. Fills the two
# parallel arrays; refuses an unparseable line rather than skipping it.
_cr_parse_category_map() {
    local file="$1" line prefix name lineno=0
    CR_MAP_PREFIXES=(); CR_MAP_NAMES=()
    [ -f "$file" ] || { print_error "category map not found: $file"; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno+1))
        line="${line%%#*}"
        [ -z "$(_cr_trim "$line")" ] && continue
        case "$line" in
            *=*) prefix="$(_cr_trim "${line%%=*}")"; name="$(_cr_trim "${line#*=}")" ;;
            *)   print_error "category map ${file}:${lineno}: expected 'prefix = Category Name', got: $(_cr_trim "$line")"; return 1 ;;
        esac
        if [ -z "$prefix" ] || [ -z "$name" ]; then
            print_error "category map ${file}:${lineno}: empty prefix or category name"; return 1
        fi
        CR_MAP_PREFIXES+=("$prefix"); CR_MAP_NAMES+=("$name")
    done < "$file"
    [ "${#CR_MAP_PREFIXES[@]}" -gt 0 ] || { print_error "category map ${file} declares no mappings"; return 1; }
    return 0
}

# _cr_map_category <shortname> — longest case-insensitive prefix wins.
# Returns 1 (mapped to nothing) when no prefix matches: the caller REFUSES.
_cr_map_category() {
    local sn lp i best="" bestlen=0
    sn="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    for i in "${!CR_MAP_PREFIXES[@]}"; do
        lp="$(printf '%s' "${CR_MAP_PREFIXES[$i]}" | tr '[:upper:]' '[:lower:]')"
        if [ "${sn:0:${#lp}}" = "$lp" ] && [ "${#lp}" -gt "$bestlen" ]; then
            best="${CR_MAP_NAMES[$i]}"; bestlen="${#lp}"
        fi
    done
    [ -n "$best" ] && { printf '%s' "$best"; return 0; }
    return 1
}

# _cr_sha256 <file> — the hash field of sha256sum output, nothing else.
#
# `cut -d' ' -f1`, NOT `awk '{print $1}'`, on purpose. This is sha256sum output,
# not YAML — but lint:yq-first's file-scoped heuristic learns that `f` is a YAML
# variable from `_moodle_core_patches_decl` (f="…/${base}.yml") and then flags
# any awk invocation whose arguments mention any `$f`, including the unrelated
# .mbz loop variable in the staging path below. The awk-free form is the honest
# fix rather than a baseline row: `cut -d' ' -f1` is already the sibling idiom
# in lib/verify-runner.sh, lib/console-deploy.sh and lib/golden-hygiene.sh.
_cr_sha256() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# _cr_push_verified <ssh_target> <ssh_opts> <local_path> <remote_name>
# The demo_push_verified contract, parameterised for this verb's target: scp to
# the remote HOME, verify the sha256 ON THE REMOTE against the locally computed
# hash, fail-closed (and remove the corrupt upload) on mismatch.
_cr_push_verified() {
    local ssh_target="$1" ssh_opts="$2" local_path="$3" remote_name="$4"
    local want got
    want="$(_cr_sha256 "$local_path")"
    if [[ ! "$want" =~ ^[0-9a-f]{64}$ ]]; then
        print_error "Cannot compute a local sha256 for $(basename "$local_path")"; return 1
    fi
    # shellcheck disable=SC2086
    if ! scp ${ssh_opts} -o BatchMode=yes "$local_path" "${ssh_target}:${remote_name}" >/dev/null 2>&1; then
        print_error "Failed to push $(basename "$local_path") to the target"; return 1
    fi
    # shellcheck disable=SC2086
    got="$(ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "sha256sum ~/${remote_name} 2>/dev/null | cut -d' ' -f1" 2>/dev/null)"
    if [ "$got" != "$want" ]; then
        print_error "sha256 MISMATCH after push for ${remote_name} (local=${want} remote=${got:-none}) — aborting BEFORE restore."
        # shellcheck disable=SC2086
        ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "rm -f ~/${remote_name}" >/dev/null 2>&1 || true
        return 1
    fi
    return 0
}

cmd_course_restore() {
    local site="" tier="" from_dir="" category="" category_map="" mode="dry-run" enable_self="false"
    for a in "$@"; do
        case "$a" in
            --tier=*)         tier="${a#*=}" ;;
            --from=*)         from_dir="${a#*=}" ;;
            --category=*)     category="${a#*=}" ;;
            --category-map=*) category_map="${a#*=}" ;;
            --enable-self-enrol) enable_self="true" ;;
            --dry-run)        mode="dry-run" ;;
            --apply|--execute) mode="apply" ;;
            -h|--help)
                print_info "usage: pl moodle course restore <site> --tier=live|dev --from=DIR [--category=NAME|--category-map=FILE] [--enable-self-enrol] [--dry-run|--apply]"
                return 0 ;;
            -*) print_error "Unknown option: $a"; return 1 ;;
            *)  [ -z "$site" ] && site="$a" || { print_error "Unexpected arg: $a"; return 1; } ;;
        esac
    done
    [ -z "$site" ] && { print_error "usage: pl moodle course restore <site> --tier=live|dev --from=DIR [--category=NAME|--category-map=FILE] [--enable-self-enrol] [--apply]"; return 1; }
    case "$tier" in
        live|dev) ;;
        "") print_error "--tier is required (live|dev)"; return 1 ;;
        *)  print_error "--tier must be live or dev (stg is a local ddev tier without a restore path here)"; return 1 ;;
    esac
    [ -z "$from_dir" ] && { print_error "--from=DIR is required (directory of backup-moodle2-course-*.mbz files)"; return 1; }
    if [ -n "$category" ] && [ -n "$category_map" ]; then
        print_error "--category and --category-map are mutually exclusive"; return 1
    fi
    if [ -z "$category" ] && [ -z "$category_map" ]; then
        print_error "One of --category=NAME or --category-map=FILE is required — this verb never guesses a category."
        return 1
    fi
    _resolve_moodle_site "$site" || return 1
    [ -d "$from_dir" ] || { print_error "--from is not a directory: $from_dir"; return 1; }
    if [ -n "$category_map" ]; then
        _cr_parse_category_map "$category_map" || return 1
    fi

    # ---- candidate enumeration + name guard (guard 1) -----------------------
    # Only regular files (find without -L excludes symlinks), only the exact
    # backup-moodle2-course-*.mbz shape, and only shell-safe basenames: these
    # names are later embedded in remote command lines, so a hostile name is a
    # refusal for the WHOLE run, not a skip.
    local -a files=()
    mapfile -t files < <(find "$from_dir" -maxdepth 1 -type f -name 'backup-moodle2-course-*.mbz' 2>/dev/null | sort)
    [ "${#files[@]}" -eq 0 ] && { print_error "No backup-moodle2-course-*.mbz files in $from_dir"; return 1; }
    local f base
    for f in "${files[@]}"; do
        base="$(basename "$f")"
        case "$base" in
            *..*) print_error "Refusing '${base}': path-traversal shape ('..') in an mbz name."; return 1 ;;
        esac
        if [[ ! "$base" =~ ^backup-moodle2-course-[A-Za-z0-9._-]+\.mbz$ ]]; then
            print_error "Refusing '${base}': mbz names must match backup-moodle2-course-*.mbz with only [A-Za-z0-9._-]."
            return 1
        fi
    done

    # ---- PII fail-close + shortname + category resolution (all LOCAL) ------
    # Guard 2: parse each mbz BEFORE anything ships. users=1, or an unreadable
    # `users` setting, refuses the run unless anonymize=1. No per-file skip:
    # a batch that contains user data is a wrong batch.
    local xml_tmp; xml_tmp="$(mktemp)" || return 1
    local -a shortnames=() categories=()
    local users anonymize sn cat
    print_header "Moodle course restore: ${BASE}@${tier} (${#files[@]} candidate mbz)"
    for f in "${files[@]}"; do
        base="$(basename "$f")"
        if ! _cr_extract_backup_xml "$f" "$xml_tmp"; then
            print_error "REFUSING ${base}: cannot extract moodle_backup.xml (not a readable .mbz?)."
            rm -f "$xml_tmp"; return 1
        fi
        users="$(_cr_backup_setting "$xml_tmp" users)"
        anonymize="$(_cr_backup_setting "$xml_tmp" anonymize)"
        if [ "$anonymize" != "1" ]; then
            if [ -z "$users" ]; then
                print_error "REFUSING ${base}: no root-level 'users' setting in moodle_backup.xml — cannot prove it carries no user data (PII fail-close)."
                rm -f "$xml_tmp"; return 1
            fi
            if [ "$users" != "0" ]; then
                print_error "REFUSING ${base}: backup includes user data (users=${users}, anonymize=${anonymize:-0})."
                print_info  "  Re-export the course WITHOUT users (or with anonymize) — raw user data never rides a course mbz through this verb."
                rm -f "$xml_tmp"; return 1
            fi
        fi
        sn="$(_cr_backup_shortname "$xml_tmp")"
        if [ -z "$sn" ]; then
            print_error "REFUSING ${base}: no <original_course_shortname> — without it the idempotency check is impossible."
            rm -f "$xml_tmp"; return 1
        fi
        if [ -n "$category_map" ]; then
            if ! cat="$(_cr_map_category "$sn")"; then
                print_error "REFUSING ${base}: shortname '${sn}' matches no prefix in ${category_map}."
                print_info  "  Add a mapping line ('prefix = Category Name') — this verb never guesses a category."
                rm -f "$xml_tmp"; return 1
            fi
        else
            cat="$category"
        fi
        shortnames+=("$sn"); categories+=("$cat")
    done
    rm -f "$xml_tmp"

    # ---- plan --------------------------------------------------------------
    local i
    printf '    %-46s %-14s %s\n' "FILE" "SHORTNAME" "CATEGORY"
    for i in "${!files[@]}"; do
        printf '    %-46s %-14s %s\n' "$(basename "${files[$i]}")" "${shortnames[$i]}" "${categories[$i]}"
    done
    echo ""

    # ---- tier plumbing ------------------------------------------------------
    local ssh_target="" ssh_opts="" sudo_prefix="" remote_path="" php_bin="" php_opts=""
    local dev_root="" dev_stage_rel=".nwp-course-restore-stage"
    if [ "$tier" = "live" ]; then
        local live_enabled; live_enabled=$(get_live_config "$BASE" "enabled")
        [ "$live_enabled" = "false" ] && { print_error "Live disabled for '$BASE' (live.enabled: false)."; return 1; }
        local server_ip ssh_user
        server_ip=$(get_live_config "$BASE" "server_ip")
        [ -z "$server_ip" ] && { print_error "No live server configured for '$BASE'."; return 1; }
        ssh_user=$(get_ssh_user "$BASE")
        remote_path=$(get_live_config "$BASE" "remote_path"); [ -z "$remote_path" ] && remote_path="/var/www/${BASE}"
        [ "$ssh_user" = "gitlab" ] && sudo_prefix="sudo"
        ssh_opts="$(nwp_ssh_opts "$BASE")"; ssh_target="${ssh_user}@${server_ip}"
        # Item 9: the two pieces of box knowledge, resolved and ASSERTED.
        php_bin="$(moodle_cli_php_bin "$CONFIG_FILE")"
        php_opts="$(moodle_cli_php_opts "$CONFIG_FILE")"
        moodle_cli_assert "$php_bin" "$php_opts" || return 1
        print_info "Target:  ${ssh_target}:${remote_path}"
        print_info "php:     ${php_bin} ${php_opts}"
    else
        dev_root="$PROJECT_ROOT/sites/${BASE}/dev"
        [ -f "$dev_root/config.php" ] || { print_error "No Moodle dev tier at ${dev_root} (config.php missing)."; return 1; }
        command -v ddev >/dev/null 2>&1 || { print_error "ddev is required for --tier=dev."; return 1; }
        print_info "Target:  ddev project at ${dev_root}"
    fi
    [ -f "$CR_HELPER" ] || { print_error "Missing staged helper: $CR_HELPER"; return 1; }

    # ---- dry-run stops HERE: no ssh, no scp, no ddev exec ------------------
    if [ "$mode" != "apply" ]; then
        print_info "At --apply time, shortnames already present on the target are SKIPPED (idempotent),"
        print_info "categories are created as needed, and every restored course is asserted"
        print_info "visible + keyless-self-enrolable."
        if [ "$enable_self" = "true" ]; then
            print_info "--enable-self-enrol: WOULD enable a keyless self-enrolment (+ visibility) on each"
            print_info "course restored by that run — restored courses only, never pre-existing ones."
        else
            print_info "(restore_backup.php brings courses up WITHOUT enabled self-enrol; the post-pass"
            print_info " will fail loudly unless you pass --enable-self-enrol or fix enrolments yourself.)"
        fi
        print_status "OK" "[dry-run] ${#files[@]} restore(s) planned — nothing executed. Re-run with --apply."
        return 0
    fi

    # ---- live gates (ADR-0028 + fate manifest + typed confirm) --------------
    if [ "$tier" = "live" ]; then
        deploy_gate_require "$BASE" "live" "restore ${#files[@]} course mbz file(s) into live Moodle via admin/cli/restore_backup.php" || return 1
        impact_reset
        impact_overwrite "mdl_course" "up to ${#files[@]} NEW course(s) created by admin/cli/restore_backup.php (existing shortnames are skipped, never replaced)"
        impact_overwrite "mdl_course_categories" "categories created as needed: $(printf '%s\n' "${categories[@]}" | sort -u | paste -sd ', ' -)"
        if [ "$enable_self" = "true" ]; then
            impact_overwrite "mdl_enrol" "keyless self-enrolment ENABLED (+ visible=1) on each course THIS run restores — never on pre-existing courses"
        fi
        impact_keep "existing courses, users and enrolments — restore only ADDS courses"
        impact_keep "config.php + moodledata config — untouched"
        impact_warn "restore_backup.php has no down-hook; removing a restored course afterwards is a manual course deletion."
        impact_render
        impact_confirm typed "$BASE" "${AUTO_CONFIRM:-false}" || { print_error "aborted."; return 1; }
    fi

    # ---- runner shims: one remote surface per tier --------------------------
    local remote_stage="/tmp/nwp-course-restore-$(date +%s)-$$"
    # Both runners take stdin from /dev/null: ssh and `ddev exec` otherwise
    # swallow the caller's stdin, which silently truncates any surrounding
    # read loop (caught live by the ssd dev-tier rehearsal — only the first
    # category of three resolved).
    _cr_run_helper() {   # <args...> — run the staged helper as the web user
        if [ "$tier" = "live" ]; then
            local qargs="" x
            for x in "$@"; do qargs+=" $(printf '%q' "$x")"; done
            # shellcheck disable=SC2086
            ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
                "cd ${remote_path} && ${sudo_prefix} -u www-data ${php_bin} ${php_opts} ${remote_stage}/course-restore-check.php${qargs}" </dev/null
        else
            (cd "$dev_root" && ddev exec php -d max_input_vars=5000 "${dev_stage_rel}/course-restore-check.php" "$@" </dev/null)
        fi
    }
    _cr_run_restore() {  # <staged mbz name> <categoryid>
        if [ "$tier" = "live" ]; then
            # shellcheck disable=SC2086
            ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
                "cd ${remote_path} && ${sudo_prefix} -u www-data ${php_bin} ${php_opts} ${remote_path%/}/admin/cli/restore_backup.php --file=${remote_stage}/$1 --categoryid=$2" </dev/null
        else
            (cd "$dev_root" && ddev exec php -d max_input_vars=5000 admin/cli/restore_backup.php \
                "--file=/var/www/html/${dev_stage_rel}/$1" "--categoryid=$2" </dev/null)
        fi
    }
    _cr_cleanup() {
        if [ "$tier" = "live" ]; then
            # shellcheck disable=SC2086
            ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "${sudo_prefix} rm -rf ${remote_stage}" >/dev/null 2>&1 || true
        else
            rm -rf "${dev_root:?}/${dev_stage_rel}"
        fi
    }

    # ---- stage: sha256-verified push, then a www-data-readable dir ---------
    print_header "Staging (sha256-verified)"
    if [ "$tier" = "live" ]; then
        local -a pushed=()
        _cr_push_verified "$ssh_target" "$ssh_opts" "$CR_HELPER" "course-restore-check.php" || return 1
        pushed+=("course-restore-check.php")
        for f in "${files[@]}"; do
            base="$(basename "$f")"
            if ! _cr_push_verified "$ssh_target" "$ssh_opts" "$f" "$base"; then
                # shellcheck disable=SC2086
                ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "cd ~ && rm -f ${pushed[*]}" >/dev/null 2>&1 || true
                return 1
            fi
            pushed+=("$base")
        done
        # Move the verified uploads out of ~ into a stage www-data can read,
        # then DELETE the home copies (the push-verify-use-delete contract).
        # shellcheck disable=SC2086
        if ! ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
            "${sudo_prefix} mkdir -p ${remote_stage} && cd ~ && ${sudo_prefix} cp ${pushed[*]} ${remote_stage}/ && ${sudo_prefix} chown -R www-data:www-data ${remote_stage} && ${sudo_prefix} chmod 0755 ${remote_stage} && rm -f ${pushed[*]}"; then
            print_error "Could not stage verified files into ${remote_stage} on the target."
            _cr_cleanup; return 1
        fi
    else
        mkdir -p "${dev_root}/${dev_stage_rel}" || return 1
        cp "$CR_HELPER" "${dev_root}/${dev_stage_rel}/course-restore-check.php" || { _cr_cleanup; return 1; }
        for f in "${files[@]}"; do
            cp "$f" "${dev_root}/${dev_stage_rel}/" || { _cr_cleanup; return 1; }
            if [ "$(_cr_sha256 "${dev_root}/${dev_stage_rel}/$(basename "$f")")" != "$(_cr_sha256 "$f")" ]; then
                print_error "sha256 MISMATCH staging $(basename "$f") into the dev tier."; _cr_cleanup; return 1
            fi
        done
    fi

    # ---- idempotency: staged READ-ONLY query of existing shortnames --------
    print_header "Idempotency check (existing shortnames on target)"
    local existing
    if ! existing="$(_cr_run_helper --list-shortnames)"; then
        print_error "Could not enumerate existing course shortnames on the target — refusing to restore blind."
        _cr_cleanup; return 1
    fi
    existing="$(printf '%s\n' "$existing" | awk '/^SHORTNAME /{ $1=""; sub(/^ /,""); print }')"

    local -a do_files=() do_shortnames=() do_categories=()
    for i in "${!files[@]}"; do
        if printf '%s\n' "$existing" | grep -Fxq -- "${shortnames[$i]}"; then
            print_info "SKIP $(basename "${files[$i]}") — shortname '${shortnames[$i]}' already present on target."
        else
            do_files+=("${files[$i]}"); do_shortnames+=("${shortnames[$i]}"); do_categories+=("${categories[$i]}")
        fi
    done
    if [ "${#do_files[@]}" -eq 0 ]; then
        _cr_cleanup
        print_status "OK" "0 restores to perform — the target already has all ${#files[@]} course(s). Idempotent no-op."
        return 0
    fi
    print_info "${#do_files[@]} of ${#files[@]} course(s) to restore."

    # ---- categories (created as needed) ------------------------------------
    print_header "Category resolution"
    local -a cat_names=() cat_ids=() uniq_cats=()
    local cat_out cat_id
    # mapfile, not a `while read` pipe: the helper below execs ssh/ddev, and a
    # child that reads the loop's stdin truncates the category list.
    mapfile -t uniq_cats < <(printf '%s\n' "${do_categories[@]}" | sort -u)
    for cat in "${uniq_cats[@]}"; do
        [ -n "$cat" ] || continue
        if ! cat_out="$(_cr_run_helper "--ensure-category=${cat}")"; then
            print_error "Could not resolve/create category '${cat}' on the target."
            _cr_cleanup; return 1
        fi
        cat_id="$(printf '%s\n' "$cat_out" | awk '/^CATID /{print $2; exit}')"
        if [[ ! "$cat_id" =~ ^[0-9]+$ ]]; then
            print_error "Unparseable category id for '${cat}' (got: ${cat_out})."
            _cr_cleanup; return 1
        fi
        cat_names+=("$cat"); cat_ids+=("$cat_id")
        print_info "  ${cat} → categoryid=${cat_id}"
    done

    # ---- per-course restore -------------------------------------------------
    print_header "Restoring ${#do_files[@]} course(s)"
    local restored=0 j
    for i in "${!do_files[@]}"; do
        base="$(basename "${do_files[$i]}")"
        cat_id=""
        for j in "${!cat_names[@]}"; do
            [ "${cat_names[$j]}" = "${do_categories[$i]}" ] && { cat_id="${cat_ids[$j]}"; break; }
        done
        [ -z "$cat_id" ] && { print_error "internal: no category id for '${do_categories[$i]}'"; _cr_cleanup; return 1; }
        print_info "RESTORE ${base} (${do_shortnames[$i]}) → '${do_categories[$i]}' (categoryid=${cat_id})"
        if ! _cr_run_restore "$base" "$cat_id"; then
            print_error "restore_backup.php FAILED for ${base} — stopping (${restored} restored; re-run is safe, restored shortnames will be skipped)."
            _cr_cleanup; return 1
        fi
        restored=$((restored+1))
    done

    # ---- opt-in: make THIS run's restored courses enterable -----------------
    # restore_backup.php provably restores courses with no enabled self-enrol
    # (ssd rehearsal 2026-08-01). Scoped to do_shortnames — exactly the courses
    # restored above — so pre-existing (skipped) courses are never retrofitted.
    if [ "$enable_self" = "true" ]; then
        print_header "Enabling keyless self-enrol on ${#do_shortnames[@]} restored course(s)"
        if ! _cr_run_helper --enable-self-enrol "${do_shortnames[@]}"; then
            print_error "--enable-self-enrol FAILED (see ENROL-FAIL lines) — the post-pass below will show what is still closed."
        fi
    fi

    # ---- post-pass: every restored course must be enterable -----------------
    print_header "Post-restore assertion (visible + keyless self-enrol)"
    local assert_rc=0
    _cr_run_helper --assert-enterable "${do_shortnames[@]}" || assert_rc=$?
    _cr_cleanup
    if [ "$assert_rc" -ne 0 ]; then
        print_error "${restored} course(s) restored, but the enterability assertion FAILED (see ENTER-FAIL lines)."
        print_info  "A hidden course rejects require_login; a keyed/disabled self-enrol strands a tester at the door."
        print_info  "Fix visibility/self-enrolment on the target, then re-run the assertion."
        return 1
    fi
    print_status "OK" "${restored} course(s) restored into ${BASE}@${tier}; all visible + keyless-self-enrolable."
    return 0
}

################################################################################
# content sync — repair depth content IN PLACE on a site that already has the
# courses (nwp/ops#220)
#
# THE GAP THIS FILLS. `pl moodle course restore` is idempotent BY SHORTNAME.
# That is right for an importer and useless for a repair: when the ssd demo
# tier was imported on 2026-08-02 from the .mbz set captured 2026-07-11, all
# 247 migrated depth-content activities arrived carrying only
# {id,title,session,depths}, because the archives predate the 2026-07-21
# content refresh. Live ssc carries, for the SAME 247 pointids, 1,671 quiz
# items across 213 activities plus practice, application, checkpoints,
# dogmatic_propositions, catechism_paragraphs and 18 audio clips. Re-running
# `course restore` against a corrected mbz set repairs nothing — it skips all
# 55 shortnames. There was no verb for this, so the fleet had no way to fix it
# that was not a hand-rolled `ssh` + `mysql` UPDATE.
#
#   pl moodle content sync <site> --tier=live|dev --from=DIR [--dry-run|--apply]
#
# --from=DIR is a directory of learning-point JSON files — the shape the
# canonical catalogue already builds (courses_v3/build/json/*.json), where each
# file's top-level `id` is the pointid. The verb reads them LOCALLY, validates
# every one, and ships a single NDJSON payload.
#
# GUARDS (fail-closed, all local except the last):
#   * every *.json must parse and carry a non-empty string `id`; one bad file
#     refuses the WHOLE run. A partially-understood content payload must never
#     be partially applied.
#   * duplicate `id` across two files is a refusal, not last-wins.
#   * the payload is pushed sha256-verified (the demo_push_verified contract,
#     reused via _cr_push_verified) and staged where only www-data can read it.
#   * the remote helper matches on `pointid` and ONLY ever UPDATEs an EXISTING
#     depthcontent row. It cannot create or delete an activity, and it cannot
#     touch a course, an enrolment or a user. A pointid with no row on the
#     target is REPORTED and skipped — absent content is an authoring fact, not
#     something a sync may invent.
#   * --apply refuses unless the helper can open its rollback file first. The
#     prior content_json of every row it changes is written BEFORE the write,
#     in the same NDJSON shape, so the backup is itself a valid payload: feed
#     it back through --apply to undo the run exactly.
#   * a row whose stored content is already byte-identical is not rewritten at
#     all, so a second run is a true no-op and does not churn timemodified.
#   * live additionally takes the ADR-0028 deploy gate, a computed fate
#     manifest and a typed confirm.
################################################################################

# The staged remote helper (plan / apply).
CS_HELPER="${CS_HELPER:-$REPO_ROOT/scripts/moodle/content-sync-apply.php}"

# _cs_build_payload <dir> <outfile> — validate every *.json and emit NDJSON.
# Prints the entry count on stdout. Every refusal names the offending file:
# "some file in that directory is bad" is not an actionable error message.
_cs_build_payload() {
    local dir="$1" out="$2"
    local -a jsons=()
    mapfile -t jsons < <(find "$dir" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort)
    if [ "${#jsons[@]}" -eq 0 ]; then
        print_error "No *.json learning-point files in ${dir}"
        return 1
    fi
    : > "$out" || return 1
    local f id seen_file
    local seen_dir; seen_dir="$(mktemp -d)" || return 1
    for f in "${jsons[@]}"; do
        if ! jq -e . "$f" >/dev/null 2>&1; then
            print_error "REFUSING $(basename "$f"): not valid JSON."
            rm -rf "$seen_dir"; return 1
        fi
        id="$(jq -r 'if (.id | type) == "string" then .id else empty end' "$f" 2>/dev/null)"
        if [ -z "$id" ]; then
            print_error "REFUSING $(basename "$f"): no non-empty string top-level 'id' (the pointid)."
            print_info  "  This verb matches on pointid; a file without one cannot be placed."
            rm -rf "$seen_dir"; return 1
        fi
        case "$id" in
            */*|*..*) print_error "REFUSING $(basename "$f"): pointid '${id}' has a path shape."; rm -rf "$seen_dir"; return 1 ;;
        esac
        seen_file="${seen_dir}/$(printf '%s' "$id" | tr -c '[:alnum:]._-' '_')"
        if [ -e "$seen_file" ]; then
            print_error "REFUSING: pointid '${id}' appears in more than one file (last is $(basename "$f"))."
            rm -rf "$seen_dir"; return 1
        fi
        : > "$seen_file"
        if ! jq -c --arg pid "$id" '{pointid: $pid, content_json: .}' "$f" >> "$out"; then
            print_error "Could not serialise $(basename "$f") into the payload."
            rm -rf "$seen_dir"; return 1
        fi
    done
    rm -rf "$seen_dir"
    printf '%s' "${#jsons[@]}"
    return 0
}

cmd_content_sync() {
    local site="" tier="" from_dir="" mode="dry-run"
    for a in "$@"; do
        case "$a" in
            --tier=*)  tier="${a#*=}" ;;
            --from=*)  from_dir="${a#*=}" ;;
            --dry-run) mode="dry-run" ;;
            --apply|--execute) mode="apply" ;;
            -h|--help)
                print_info "usage: pl moodle content sync <site> --tier=live|dev --from=DIR [--dry-run|--apply]"
                return 0 ;;
            -*) print_error "Unknown option: $a"; return 1 ;;
            *)  [ -z "$site" ] && site="$a" || { print_error "Unexpected arg: $a"; return 1; } ;;
        esac
    done
    [ -z "$site" ] && { print_error "usage: pl moodle content sync <site> --tier=live|dev --from=DIR [--dry-run|--apply]"; return 1; }
    case "$tier" in
        live|dev) ;;
        "") print_error "--tier is required (live|dev)"; return 1 ;;
        *)  print_error "--tier must be live or dev (stg is a local ddev tier without a sync path here)"; return 1 ;;
    esac
    [ -z "$from_dir" ] && { print_error "--from=DIR is required (directory of learning-point *.json files)"; return 1; }
    [ -d "$from_dir" ] || { print_error "--from is not a directory: $from_dir"; return 1; }
    command -v jq >/dev/null 2>&1 || { print_error "jq is required to validate the learning-point JSON."; return 1; }
    _resolve_moodle_site "$site" || return 1
    [ -f "$CS_HELPER" ] || { print_error "Missing staged helper: $CS_HELPER"; return 1; }

    # ---- build + validate the payload, entirely locally ---------------------
    print_header "Moodle content sync: ${BASE}@${tier}"
    local payload; payload="$(mktemp)" || return 1
    local count
    if ! count="$(_cs_build_payload "$from_dir" "$payload")"; then
        rm -f "$payload"; return 1
    fi
    print_info "${count} learning point(s) validated from ${from_dir}"

    # ---- tier plumbing ------------------------------------------------------
    local ssh_target="" ssh_opts="" sudo_prefix="" remote_path="" php_bin="" php_opts=""
    local dev_root="" dev_stage_rel=".nwp-content-sync-stage"
    if [ "$tier" = "live" ]; then
        local live_enabled; live_enabled=$(get_live_config "$BASE" "enabled")
        [ "$live_enabled" = "false" ] && { print_error "Live disabled for '$BASE' (live.enabled: false)."; rm -f "$payload"; return 1; }
        local server_ip ssh_user
        server_ip=$(get_live_config "$BASE" "server_ip")
        [ -z "$server_ip" ] && { print_error "No live server configured for '$BASE'."; rm -f "$payload"; return 1; }
        ssh_user=$(get_ssh_user "$BASE")
        remote_path=$(get_live_config "$BASE" "remote_path"); [ -z "$remote_path" ] && remote_path="/var/www/${BASE}"
        [ "$ssh_user" = "gitlab" ] && sudo_prefix="sudo"
        ssh_opts="$(nwp_ssh_opts "$BASE")"; ssh_target="${ssh_user}@${server_ip}"
        php_bin="$(moodle_cli_php_bin "$CONFIG_FILE")"
        php_opts="$(moodle_cli_php_opts "$CONFIG_FILE")"
        moodle_cli_assert "$php_bin" "$php_opts" || { rm -f "$payload"; return 1; }
        print_info "Target:  ${ssh_target}:${remote_path}"
        print_info "php:     ${php_bin} ${php_opts}"
    else
        dev_root="$PROJECT_ROOT/sites/${BASE}/dev"
        [ -f "$dev_root/config.php" ] || { print_error "No Moodle dev tier at ${dev_root} (config.php missing)."; rm -f "$payload"; return 1; }
        command -v ddev >/dev/null 2>&1 || { print_error "ddev is required for --tier=dev."; rm -f "$payload"; return 1; }
        print_info "Target:  ddev project at ${dev_root}"
    fi

    # ---- dry-run stops HERE: no ssh, no scp, no ddev exec -------------------
    if [ "$mode" != "apply" ]; then
        print_info "At --apply time the payload is pushed sha256-verified and the staged helper"
        print_info "UPDATEs content_json on EXISTING depthcontent rows matched by pointid only."
        print_info "Rows already byte-identical are not rewritten; absent pointids are reported, never created."
        print_info "The prior value of every changed row is written to a rollback NDJSON first,"
        print_info "and pulled back to sites/${BASE}/backups/."
        print_status "OK" "[dry-run] ${count} learning point(s) planned — nothing executed. Re-run with --apply."
        rm -f "$payload"
        return 0
    fi

    # ---- live gates (ADR-0028 + fate manifest + typed confirm) --------------
    if [ "$tier" = "live" ]; then
        deploy_gate_require "$BASE" "live" "sync ${count} learning point(s) of depth content into live Moodle" || { rm -f "$payload"; return 1; }
        impact_reset
        impact_overwrite "mdl_depthcontent.content_json" "up to ${count} EXISTING row(s), matched by pointid — prior values written to a rollback NDJSON first"
        impact_keep "depthcontent activities, courses, sections, enrolments, users — this verb only UPDATEs content_json"
        impact_keep "rows whose content is already identical — not rewritten, timemodified untouched"
        impact_keep "config.php + moodledata — untouched"
        impact_warn "A pointid with no row on the target is SKIPPED and reported; this verb never creates an activity."
        impact_render
        impact_confirm typed "$BASE" "${AUTO_CONFIRM:-false}" || { print_error "aborted."; rm -f "$payload"; return 1; }
    fi

    # ---- runner shims -------------------------------------------------------
    local stamp; stamp="$(date -u +%Y%m%d-%H%M%S)"
    local remote_stage="/tmp/nwp-content-sync-$(date +%s)-$$"
    local backup_dir="${PROJECT_ROOT}/sites/${BASE}/backups"
    local backup_local="${backup_dir}/content-sync-${tier}-${stamp}.ndjson"
    mkdir -p "$backup_dir" || { rm -f "$payload"; return 1; }

    _cs_run_helper() {   # <args...> — run the staged helper as the web user
        if [ "$tier" = "live" ]; then
            local qargs="" x
            for x in "$@"; do qargs+=" $(printf '%q' "$x")"; done
            # shellcheck disable=SC2086
            ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
                "cd ${remote_path} && ${sudo_prefix} -u www-data ${php_bin} ${php_opts} ${remote_stage}/content-sync-apply.php${qargs}" </dev/null
        else
            (cd "$dev_root" && ddev exec php -d max_input_vars=5000 "${dev_stage_rel}/content-sync-apply.php" "$@" </dev/null)
        fi
    }
    _cs_cleanup() {
        if [ "$tier" = "live" ]; then
            # shellcheck disable=SC2086
            ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "${sudo_prefix} rm -rf ${remote_stage}" >/dev/null 2>&1 || true
        else
            rm -rf "${dev_root:?}/${dev_stage_rel}"
        fi
        rm -f "$payload"
    }

    # ---- stage: sha256-verified push ---------------------------------------
    print_header "Staging (sha256-verified)"
    local remote_payload remote_backup
    if [ "$tier" = "live" ]; then
        _cr_push_verified "$ssh_target" "$ssh_opts" "$CS_HELPER" "content-sync-apply.php" || { rm -f "$payload"; return 1; }
        if ! _cr_push_verified "$ssh_target" "$ssh_opts" "$payload" "content-sync-payload.ndjson"; then
            # shellcheck disable=SC2086
            ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "rm -f ~/content-sync-apply.php" >/dev/null 2>&1 || true
            rm -f "$payload"; return 1
        fi
        # shellcheck disable=SC2086
        if ! ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
            "${sudo_prefix} mkdir -p ${remote_stage} && cd ~ && ${sudo_prefix} cp content-sync-apply.php content-sync-payload.ndjson ${remote_stage}/ && ${sudo_prefix} chown -R www-data:www-data ${remote_stage} && ${sudo_prefix} chmod 0755 ${remote_stage} && rm -f content-sync-apply.php content-sync-payload.ndjson"; then
            print_error "Could not stage verified files into ${remote_stage} on the target."
            _cs_cleanup; return 1
        fi
        remote_payload="${remote_stage}/content-sync-payload.ndjson"
        remote_backup="${remote_stage}/rollback.ndjson"
    else
        mkdir -p "${dev_root}/${dev_stage_rel}" || { rm -f "$payload"; return 1; }
        cp "$CS_HELPER" "${dev_root}/${dev_stage_rel}/content-sync-apply.php" || { _cs_cleanup; return 1; }
        cp "$payload"   "${dev_root}/${dev_stage_rel}/content-sync-payload.ndjson" || { _cs_cleanup; return 1; }
        if [ "$(_cr_sha256 "${dev_root}/${dev_stage_rel}/content-sync-payload.ndjson")" != "$(_cr_sha256 "$payload")" ]; then
            print_error "sha256 MISMATCH staging the payload into the dev tier."; _cs_cleanup; return 1
        fi
        remote_payload="${dev_stage_rel}/content-sync-payload.ndjson"
        remote_backup="${dev_stage_rel}/rollback.ndjson"
    fi

    # ---- plan (read-only, on the target) ------------------------------------
    print_header "Plan (read-only, computed on the target)"
    local plan
    if ! plan="$(_cs_run_helper --plan "$remote_payload")"; then
        print_error "Could not compute the plan on the target — refusing to write blind."
        _cs_cleanup; return 1
    fi
    printf '%s\n' "$plan" | grep -E '^POINT .* (ABSENT|PRESENT DIFFER) ' | head -20
    local summary; summary="$(printf '%s\n' "$plan" | grep '^PLAN-SUMMARY ' || true)"
    [ -z "$summary" ] && { print_error "No PLAN-SUMMARY from the target — refusing."; _cs_cleanup; return 1; }
    print_info "$summary"

    # ---- apply --------------------------------------------------------------
    print_header "Applying"
    local out
    if ! out="$(_cs_run_helper --apply "$remote_payload" "--backup=${remote_backup}")"; then
        print_error "Content sync FAILED on the target."
        print_info  "Any rows already changed are recorded in ${remote_backup} on the target; pull it before cleaning up."
        return 1
    fi
    printf '%s\n' "$out" | grep -E '^(ABSENT|APPLY-SUMMARY) ' || true

    # ---- pull the rollback ledger back --------------------------------------
    if [ "$tier" = "live" ]; then
        # shellcheck disable=SC2086
        if ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "${sudo_prefix} cat ${remote_backup}" > "$backup_local" 2>/dev/null \
            && [ -s "$backup_local" ]; then
            print_status "OK" "rollback ledger: ${backup_local}"
        else
            rm -f "$backup_local"
            print_warning "No rollback ledger pulled back (nothing changed, or the pull failed)."
        fi
    else
        if [ -s "${dev_root}/${remote_backup}" ]; then
            cp "${dev_root}/${remote_backup}" "$backup_local" && print_status "OK" "rollback ledger: ${backup_local}"
        fi
    fi

    _cs_cleanup
    print_status "OK" "content sync complete for ${BASE}@${tier}."
    print_info  "Undo: pl moodle content sync ${BASE} --tier=${tier} --from=<dir rebuilt from the rollback ledger> --apply"
    return 0
}

################################################################################
# privacy — "is this plugin VISIBLE to Moodle's privacy API on the target?"
#
# WHY THIS VERB EXISTS (nwp/ops#259)
# ----------------------------------
# On 2026-08-03 `local/feedback` was found installed on live ssd and live ssc
# with `classes/privacy/provider.php` ABSENT from the deployed tree. The plugin
# stores userid, username, email, ipaddress and user_agent per submission. With
# no provider class the privacy API does not know the plugin exists: a DSAR
# export returns nothing for it and an Art.17 erasure silently skips it.
#
# `pl moodle plugin drift` could not see it. Drift compares $plugin->version
# between copies and every copy agreed — a file can be missing from all of them
# at once. And a file listing is not an answer either: "provider.php is on
# disk" is not "the API resolves the class, it implements the interfaces the
# API calls, and the plugin is installed at that version". Only Moodle can say
# that, and only on the target.
#
# READ-ONLY BY CONSTRUCTION. No deploy gate, no typed confirm, no maintenance
# mode — there is nothing to confirm. The only thing written anywhere is the
# staged helper under /tmp on the target, removed on every exit path. That is
# also why it is safe to run before a deploy, which is exactly when you want it:
# a check whose failing state you have never observed is not a check.
#
#   pl moodle privacy <site> --tier=live [--component=<frankenstyle>]... [--all] [--verbose]
#
# With --component the verb ASSERTS and exits non-zero on NO-PROVIDER /
# INCOMPLETE / NOT-INSTALLED. With no --component it scans every installed
# plugin and REPORTS (exit 0 + summary), because a bare core scan always
# surfaces something and a report must not masquerade as a gate.
################################################################################

PRIV_HELPER="${PRIV_HELPER:-$REPO_ROOT/scripts/moodle/privacy-registry.php}"

cmd_privacy() {
    local site="" tier="" verbose="false" scanall="false"
    local -a comps=()
    for a in "$@"; do
        case "$a" in
            --tier=*)      tier="${a#*=}" ;;
            --component=*) comps+=("${a#*=}") ;;
            --all)         scanall="true" ;;
            --verbose)     verbose="true" ;;
            -h|--help)
                print_info "usage: pl moodle privacy <site> --tier=live [--component=<frankenstyle>]... [--all] [--verbose]"
                return 0 ;;
            -*) print_error "Unknown option: $a"; return 1 ;;
            *)  [ -z "$site" ] && site="$a" || { print_error "Unexpected arg: $a"; return 1; } ;;
        esac
    done
    [ -z "$site" ] && { print_error "usage: pl moodle privacy <site> --tier=live [--component=...]"; return 1; }
    case "$tier" in
        live) ;;
        "")   print_error "--tier is required (live)"; return 1 ;;
        *)    print_error "tier '${tier}' is not supported by this verb yet — only live."
              print_info  "  (dev/stg run in ddev; use 'ddev exec php scripts/moodle/privacy-registry.php' there.)"
              return 1 ;;
    esac
    [ ! -f "$PRIV_HELPER" ] && { print_error "Missing helper: $PRIV_HELPER"; return 1; }
    _resolve_moodle_site "$site" || return 1

    local server_ip ssh_user remote_path ssh_opts ssh_target sudo_prefix=""
    server_ip=$(get_live_config "$BASE" "server_ip")
    [ -z "$server_ip" ] && { print_error "No live server configured for '$BASE'."; return 1; }
    ssh_user=$(get_ssh_user "$BASE")
    remote_path=$(get_live_config "$BASE" "remote_path"); [ -z "$remote_path" ] && remote_path="/var/www/${BASE}"
    [ "$ssh_user" = "gitlab" ] && sudo_prefix="sudo"
    ssh_opts="$(nwp_ssh_opts "$BASE")"; ssh_target="${ssh_user}@${server_ip}"

    local php_bin php_opts
    php_bin="$(moodle_cli_php_bin "$CONFIG_FILE")"
    php_opts="$(moodle_cli_php_opts "$CONFIG_FILE")"
    moodle_cli_assert "$php_bin" "$php_opts" || return 1

    local -a hargs=()
    local c
    for c in "${comps[@]:-}"; do [ -n "$c" ] && hargs+=("--component=${c}"); done
    [ "$scanall" = "true" ] && hargs+=("--all")
    [ "$verbose" = "true" ] && hargs+=("--verbose")

    print_header "Moodle privacy registry: ${BASE}@live"
    print_info "Target: ${ssh_target}:${remote_path}"
    if [ "${#comps[@]}" -gt 0 ]; then
        print_info "Asserting: ${comps[*]}"
    else
        print_info "Scanning every installed plugin (report mode — use --component to assert)."
    fi

    local remote_stage="/tmp/nwp-privacy-$(date +%s)-$$"
    _priv_cleanup() {
        # shellcheck disable=SC2086
        ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
            "${sudo_prefix} rm -rf ${remote_stage}; rm -f ~/privacy-registry.php" >/dev/null 2>&1 || true
    }

    _cr_push_verified "$ssh_target" "$ssh_opts" "$PRIV_HELPER" "privacy-registry.php" || return 1
    # shellcheck disable=SC2086
    if ! ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
        "${sudo_prefix} mkdir -p ${remote_stage} && cd ~ && ${sudo_prefix} cp privacy-registry.php ${remote_stage}/ && ${sudo_prefix} chown -R www-data:www-data ${remote_stage} && ${sudo_prefix} chmod 0755 ${remote_stage} && rm -f privacy-registry.php"; then
        print_error "Could not stage the verified helper into ${remote_stage} on the target."
        _priv_cleanup; return 1
    fi

    local qargs="" x
    for x in "${hargs[@]:-}"; do [ -n "$x" ] && qargs+=" $(printf '%q' "$x")"; done

    local out rc=0
    # shellcheck disable=SC2086
    out="$(ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
        "cd ${remote_path} && ${sudo_prefix} -u www-data ${php_bin} ${php_opts} ${remote_stage}/privacy-registry.php${qargs}" </dev/null 2>&1)" || rc=$?
    _priv_cleanup

    printf '%s\n' "$out"

    if [ "$rc" -eq 2 ] || ! printf '%s\n' "$out" | grep -q '^PRIVACY-SUMMARY '; then
        print_error "CANNOT-VERIFY: the privacy registry did not run to completion on ${BASE}@live (rc=${rc})."
        print_info  "  A check that could not look has NOT looked — do not read this as a pass."
        return 3
    fi
    if [ "$rc" -ne 0 ]; then
        print_error "PRIVACY GAP on ${BASE}@live — at least one asserted component is invisible to the privacy API."
        print_info  "  Remedy: pl moodle plugin deploy ${BASE} <plugin> --tier=live --from-canonical --apply"
        return 1
    fi
    print_status "OK" "privacy registry checked on ${BASE}@live."
    return 0
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
            drift)  cmd_plugin_drift  "$@" ;;
            *) print_error "Unknown 'plugin' subcommand: ${PSUB:-(none)} (build|deploy|drift)"; exit 1 ;;
        esac
        ;;
    cli)         cmd_cli         "$@" ;;
    maintenance) cmd_maintenance "$@" ;;
    core-patch)  cmd_core_patch  "$@" ;;
    course)
        PSUB="${1:-}"; shift || true
        case "$PSUB" in
            restore) cmd_course_restore "$@" ;;
            *) print_error "Unknown 'course' subcommand: ${PSUB:-(none)} (restore)"; exit 1 ;;
        esac
        ;;
    content)
        PSUB="${1:-}"; shift || true
        case "$PSUB" in
            sync) cmd_content_sync "$@" ;;
            *) print_error "Unknown 'content' subcommand: ${PSUB:-(none)} (sync)"; exit 1 ;;
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
    privacy)   cmd_privacy  "$@" ;;
    policy)    cmd_policy   "$@" ;;
    mail)      cmd_mail     "$@" ;;
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
