#!/bin/bash
################################################################################
# lib/moodle-deploy.sh — guarded Moodle plugin BUILD + DEPLOY + UPGRADE +
#                        BACKUP/ROLLBACK primitives (PL-STG2LIVE §4, P1-2).
#
# This is the live-facing half the promotion substrate (lib/moodle-promote.sh)
# deliberately never had: it builds AMD, deploys plugin CODE to a remote server,
# runs the DB upgrade under maintenance, and snapshots/restores. It RETIRES the
# unguarded live-Moodle idiom
#     scp -r <plugin> $LIVE:/tmp; ssh $LIVE 'rm -rf .../<path>; cp -r ...; chown;
#            php admin/cli/upgrade.php'
# whose `rm -rf` before `cp` leaves the live plugin dir EMPTY on a mid-copy
# failure with no rollback. Every destructive path here is:
#   * per-plugin-dir scoped (never the whole webroot; config.php + moodledata are
#     structurally out of scope, INV-9/§4.3);
#   * snapshotted BEFORE overwrite (moodle_remote_backup);
#   * atomic-ish (rsync --delete into a plugin dir, not rm-then-cp);
#   * DRY-RUN by default — the command layer requires --apply/--execute and, on
#     live, a typed impact_confirm.
#
# HARD SAFETY CONTRACT:
#   * NEVER writes config.php or touches moodledata (asserted structurally).
#   * NEVER ships unbuilt JS: the AMD freshness gate fail-closes a stale build.
#   * NO secret on argv: live DB creds are read from the live config.php on the
#     remote (ABORT_AFTER_CONFIG) into a remote subshell; the password never
#     leaves the remote host and never appears on any argv.
#   * All remote CLI runs as `sudo -u www-data` (config.php is www-data-only;
#     upgrade.php writes mdl_config_plugins).
#
# Requires (soft): lib/ui.sh (print_*), lib/moodle-promote.sh (_mp_cfg,
# moodle_purge_caches_cmd), lib/impact.sh, lib/rollback-remote.sh. Everything
# degrades to a clear refusal when a dependency or tool is absent.
################################################################################

# --- soft-dep messaging (works with or without lib/ui.sh) --------------------
if ! declare -F _mp_err >/dev/null 2>&1; then
    _md_err()  { if command -v print_error   >/dev/null 2>&1; then print_error   "$*"; else printf 'ERROR: %s\n' "$*" >&2; fi; }
    _md_warn() { if command -v print_warning >/dev/null 2>&1; then print_warning "$*"; else printf 'WARN: %s\n'  "$*" >&2; fi; }
    _md_info() { if command -v print_info    >/dev/null 2>&1; then print_info    "$*"; else printf '%s\n'        "$*"; fi; }
    _md_ok()   { if command -v print_status  >/dev/null 2>&1; then print_status "OK" "$*"; else printf 'OK: %s\n' "$*"; fi; }
else
    _md_err()  { _mp_err  "$@"; }
    _md_warn() { _mp_warn "$@"; }
    _md_info() { _mp_info "$@"; }
    _md_ok()   { _mp_ok   "$@"; }
fi

################################################################################
# Plugin identity helpers (pure — unit-testable)
################################################################################

# moodle_plugin_split <plugin> — echo "<type> <name>" for a `type/name`
# identifier (e.g. mod/depthcontent). REFUSES anything that is not exactly two
# non-empty path segments, or that contains a traversal / absolute component —
# this is the first structural guard that a deploy target is a plugin subdir and
# never config.php or a path escaping the webroot.
moodle_plugin_split() {
    local plugin="${1:-}"
    case "$plugin" in
        ""|/*|*/) return 1 ;;                 # empty, absolute, or trailing slash
        *..*)     return 1 ;;                 # traversal
        */*)      : ;;                        # must contain a slash…
        *)        return 1 ;;                 # …single segment is not a plugin id
    esac
    # exactly one slash → exactly two segments
    local type="${plugin%%/*}" name="${plugin#*/}"
    [ -n "$type" ] && [ -n "$name" ] || return 1
    case "$name" in */*) return 1 ;; esac      # more than two segments
    printf '%s %s\n' "$type" "$name"
    return 0
}

# moodle_deploy_assert_set <plugin>... — every arg must be a valid plugin subdir
# identifier (per moodle_plugin_split) and NONE may be config.php or moodledata
# or any absolute/traversing path. This is the §4.3 "assert deploy set is plugin
# subdirs only, never config.php/moodledata" guard. Returns 0 iff the whole set
# is safe; prints the offending entry otherwise. PURE — unit-testable.
moodle_deploy_assert_set() {
    [ "$#" -gt 0 ] || { _md_err "empty deploy set (no plugins given)"; return 1; }
    local p base
    for p in "$@"; do
        base="$(basename "$p" 2>/dev/null || echo "$p")"
        case "$p" in
            *config.php*)
                _md_err "REFUSED: '$p' targets config.php — env-state, never deployed (INV-4)."; return 1 ;;
            *moodledata*)
                _md_err "REFUSED: '$p' targets moodledata — live uploads, never touched (INV-5)."; return 1 ;;
        esac
        case "$base" in
            config.php|moodledata)
                _md_err "REFUSED: '$p' resolves to $base — out of scope for a plugin deploy."; return 1 ;;
        esac
        if ! moodle_plugin_split "$p" >/dev/null 2>&1; then
            _md_err "REFUSED: '$p' is not a <type>/<name> plugin subdir (absolute/traversing/malformed)."
            return 1
        fi
    done
    return 0
}

################################################################################
# AMD freshness gate (pure — unit-testable). §4.2 step 5 / INV-9.
#
# For a plugin dir with an amd/ tree: every amd/src/*.js MUST have a matching
# amd/build/*.min.js with mtime(build) >= mtime(src), and the module count must
# be equal (N src ⇒ N build). Any missing/older output → refuse (return 1). A
# plugin with no amd/src is trivially fresh (return 0). Prints one line per
# problem; NEVER builds anything.
#
# Usage: moodle_amd_freshness_check <plugin_dir>
################################################################################
moodle_amd_freshness_check() {
    local dir="${1:-}"
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        _md_err "moodle_amd_freshness_check: plugin dir '$dir' not found"
        return 2
    fi
    local src_dir="${dir%/}/amd/src" build_dir="${dir%/}/amd/build"

    # No AMD in this plugin → nothing to build, trivially fresh.
    if [ ! -d "$src_dir" ]; then
        _md_info "amd freshness: no amd/src in $(basename "$dir") — nothing to build (fresh)."
        return 0
    fi

    local src_count=0 build_count=0 problems=0 f base build mt_src mt_build
    # Count build outputs (top-level *.min.js only, matching grunt amd output).
    if [ -d "$build_dir" ]; then
        for build in "$build_dir"/*.min.js; do
            [ -e "$build" ] || continue
            build_count=$((build_count+1))
        done
    fi

    for f in "$src_dir"/*.js; do
        [ -e "$f" ] || continue
        src_count=$((src_count+1))
        base="$(basename "$f" .js)"
        build="${build_dir}/${base}.min.js"
        if [ ! -f "$build" ]; then
            _md_err "  stale: amd/src/${base}.js has NO amd/build/${base}.min.js"
            problems=$((problems+1))
            continue
        fi
        # mtime(build) >= mtime(src) — a build older than its source is stale.
        mt_src="$(_md_mtime "$f")"
        mt_build="$(_md_mtime "$build")"
        if [ -z "$mt_src" ] || [ -z "$mt_build" ] || [ "$mt_build" -lt "$mt_src" ]; then
            _md_err "  stale: amd/build/${base}.min.js is OLDER than amd/src/${base}.js"
            problems=$((problems+1))
        fi
    done

    if [ "$src_count" -ne "$build_count" ]; then
        _md_err "  module count mismatch: ${src_count} src vs ${build_count} build (each src needs one min.js)"
        problems=$((problems+1))
    fi

    if [ "$problems" -gt 0 ]; then
        _md_err "amd freshness: REFUSE — $(basename "$dir") has ${problems} problem(s); rebuild with 'pl moodle plugin build'."
        return 1
    fi
    _md_ok "amd freshness: OK — ${src_count} module(s) built and fresh in $(basename "$dir")."
    return 0
}

# Portable mtime (epoch seconds). GNU stat then BSD stat.
_md_mtime() {
    local f="$1"
    stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo ""
}

################################################################################
# moodle_plugin_build <plugin> <build_tree> <ddev_site> <from_dir> <check_only>
#
# §4.2. Resolve source (default ~/nwptoolkit/moodle/plugins/<type>/<name>), rsync
# it into <build_tree>/<type>/<name>/, ensure the node toolchain (ddev npm ci,
# FAIL-CLOSED — never ship unbuilt JS), run grunt amd, then the freshness gate.
# --check-only reports the freshness gate on the SOURCE without building.
#
# ddev_site "" ⇒ resolve the ddev project from <build_tree> (its .ddev/config).
################################################################################
moodle_plugin_build() {
    local plugin="$1" build_tree="$2" ddev_site="${3:-}" from_dir="${4:-}" check_only="${5:-false}"

    local ts; ts="$(moodle_plugin_split "$plugin")" || {
        _md_err "moodle_plugin_build: '$plugin' is not a <type>/<name> plugin id."; return 1; }
    local type="${ts%% *}" name="${ts##* }"

    # Source resolution.
    [ -z "$from_dir" ] && from_dir="${HOME}/nwptoolkit/moodle/plugins/${type}/${name}"
    if [ ! -f "${from_dir%/}/version.php" ]; then
        _md_err "REFUSED: source '$from_dir' has no version.php — not a Moodle plugin."
        return 1
    fi
    local version; version="$(grep -oE '\$plugin->version[[:space:]]*=[[:space:]]*[0-9]+' "${from_dir%/}/version.php" 2>/dev/null | grep -oE '[0-9]+' | tail -1)"
    _md_info "Plugin ${type}/${name} — source ${from_dir} (version ${version:-?})"

    # --check-only: freshness gate on the source, no build.
    if [ "$check_only" = "true" ]; then
        moodle_amd_freshness_check "${from_dir%/}"
        return $?
    fi

    if [ -z "$build_tree" ] || [ ! -f "${build_tree%/}/version.php" ]; then
        _md_err "REFUSED: build tree '$build_tree' is not a Moodle root (no version.php)."
        _md_info "Point --tree=<moodle-dir> or --ddev=<site> at a Moodle 4.4 tree with the Gruntfile."
        return 1
    fi
    if [ ! -f "${build_tree%/}/Gruntfile.js" ]; then
        _md_err "REFUSED: build tree '$build_tree' has no Gruntfile.js — cannot run grunt amd."
        return 1
    fi

    command -v rsync >/dev/null 2>&1 || { _md_err "rsync required for the build."; return 1; }
    command -v ddev  >/dev/null 2>&1 || { _md_err "ddev required to run npm ci / grunt amd (fail-closed — never ship unbuilt JS)."; return 1; }

    # 1. rsync the plugin into the build tree.
    local dest="${build_tree%/}/${type}/${name}"
    mkdir -p "$(dirname "$dest")" || { _md_err "cannot create $(dirname "$dest")"; return 1; }
    _md_info "rsync ${from_dir%/}/ → ${dest}/"
    rsync -a --delete --exclude='.git' --exclude='node_modules' "${from_dir%/}/" "${dest}/" \
        || { _md_err "rsync of plugin into build tree failed."; return 1; }

    # 2. Toolchain: npm ci if node_modules absent (fail-closed).
    if [ ! -d "${build_tree%/}/node_modules" ]; then
        _md_info "node_modules absent → ddev exec npm ci (this is cached after the first run)…"
        if ! (cd "$build_tree" && ddev exec npm ci); then
            _md_err "REFUSED: 'ddev exec npm ci' failed — refusing to ship unbuilt JS (INV-9)."
            return 1
        fi
    fi

    # 3. grunt amd for this plugin (Gruntfile is at the tree root; cd into the
    #    plugin so grunt amd scopes to it).
    _md_info "ddev exec (cd ${type}/${name} && npx grunt amd)…"
    if ! (cd "$build_tree" && ddev exec bash -c "cd ${type}/${name} && npx grunt amd"); then
        _md_err "REFUSED: 'npx grunt amd' failed for ${type}/${name} — build did not complete."
        return 1
    fi

    # 4. Freshness gate on the freshly built plugin.
    if ! moodle_amd_freshness_check "$dest"; then
        _md_err "REFUSED: freshness gate failed AFTER build — build output is incomplete/stale."
        return 1
    fi
    _md_ok "Built ${type}/${name} in ${build_tree} — AMD fresh. Staging dir: ${dest}"
    printf '%s\n' "$dest"   # emit the staging dir for a deploy to consume
    return 0
}

################################################################################
# moodle_plugin_rsync <staging_dir> <type> <name> <ssh_target> <remote_base>
#                     <sudo_prefix> <ssh_opts> <apply>
#
# §4.3 per-plugin-dir guarded rsync. --delete is SAFE here because its scope is
# ONE plugin dir; config.php + moodledata are structurally outside it. amd/src is
# excluded (only the built min.js ships). Prints the command on dry-run; executes
# via sudo on --apply. NEVER touches the whole webroot.
################################################################################
moodle_plugin_rsync() {
    local staging="$1" type="$2" name="$3" ssh_target="$4" remote_base="$5"
    local sudo_prefix="${6:-}" ssh_opts="${7:-}" apply="${8:-false}"

    if [ ! -d "${staging%/}/${type}/${name}" ] && [ ! -d "${staging%/}" ]; then
        _md_err "moodle_plugin_rsync: staging plugin dir not found for ${type}/${name}"
        return 1
    fi
    # Accept either a staging tree root (…/type/name inside) or the plugin dir.
    local src
    if [ -d "${staging%/}/${type}/${name}" ]; then
        src="${staging%/}/${type}/${name}/"
    else
        src="${staging%/}/"
    fi
    local remote_dir="${remote_base%/}/${type}/${name}/"

    # rsync-over-ssh with a remote sudo shell (ssh_user==gitlab ⇒ sudo). Using
    # --rsync-path so the REMOTE side runs under sudo without a root login.
    local rsync_path_opt=""
    [ -n "$sudo_prefix" ] && rsync_path_opt="--rsync-path=${sudo_prefix} rsync"

    local -a cmd=(rsync -az --delete
        --exclude='.git' --exclude='node_modules' --exclude='amd/src'
        -e "ssh ${ssh_opts}")
    [ -n "$rsync_path_opt" ] && cmd+=("$rsync_path_opt")
    cmd+=("$src" "${ssh_target}:${remote_dir}")

    if [ "$apply" != "true" ]; then
        _md_info "[dry-run] would rsync ${type}/${name}:"
        printf '    %q ' "${cmd[@]}"; echo
        return 0
    fi
    _md_info "rsync ${type}/${name} → ${ssh_target}:${remote_dir}"
    "${cmd[@]}" || { _md_err "rsync of ${type}/${name} to live FAILED."; return 1; }
    _md_ok "Deployed ${type}/${name}."
    return 0
}

################################################################################
# Remote CLI helpers. All Moodle CLI runs as www-data. php_bin defaults to the
# tier's cli php (Moodle 4.4 rejects PHP 8.4 → php8.2/8.3), resolved by caller.
################################################################################

# moodle_maintenance <ssh_target> <ssh_opts> <sudo_prefix> <php_bin> <root> <enable|disable> <apply>
moodle_maintenance() {
    local ssh_target="$1" ssh_opts="$2" sudo_prefix="$3" php_bin="$4" root="$5" action="$6" apply="${7:-false}"
    local flag="--enable"; [ "$action" = "disable" ] && flag="--disable"
    local remote="${sudo_prefix} -u www-data ${php_bin} ${root%/}/admin/cli/maintenance.php ${flag}"
    remote="$(_md_trim "$remote")"
    if [ "$apply" != "true" ]; then _md_info "[dry-run] maintenance ${action}: ssh ${ssh_target} \"${remote}\""; return 0; fi
    ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "$remote"
}

_md_trim() { local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "$s"; }

################################################################################
# moodle_remote_upgrade — §4.4 exact sequence. Runs under maintenance:
#   maintenance --enable → (optional db-only backup) → admin/cli/upgrade.php
#   --non-interactive → admin/cli/purge_caches.php → maintenance --disable
# On ANY failure: leave maintenance ON, point at rollback, return non-zero.
#
# Args: <ssh_target> <ssh_opts> <sudo_prefix> <php_bin> <root> <site>
#       <no_maintenance> <apply>
################################################################################
moodle_remote_upgrade() {
    local ssh_target="$1" ssh_opts="$2" sudo_prefix="$3" php_bin="$4" root="$5" site="$6"
    local no_maint="${7:-false}" apply="${8:-false}"

    local up="${sudo_prefix} -u www-data ${php_bin} ${root%/}/admin/cli/upgrade.php --non-interactive"
    local pc="${sudo_prefix} -u www-data ${php_bin} ${root%/}/admin/cli/purge_caches.php"
    up="$(_md_trim "$up")"; pc="$(_md_trim "$pc")"

    if [ "$apply" != "true" ]; then
        _md_info "[dry-run] Moodle upgrade sequence for ${site}:"
        [ "$no_maint" != "true" ] && echo "    1. maintenance --enable"
        echo "    2. ${up}"
        echo "    3. ${pc}"
        [ "$no_maint" != "true" ] && echo "    4. maintenance --disable"
        return 0
    fi

    if [ "$no_maint" != "true" ]; then
        moodle_maintenance "$ssh_target" "$ssh_opts" "$sudo_prefix" "$php_bin" "$root" enable true \
            || { _md_err "Could not enable maintenance — aborting upgrade."; return 1; }
    else
        _md_warn "--no-maintenance: running upgrade with the site LIVE (discouraged hotfix path)."
    fi

    _md_info "Running admin/cli/upgrade.php --non-interactive…"
    if ! ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "$up"; then
        _md_err "upgrade.php FAILED. Leaving maintenance ON (fail-loud)."
        _md_err "Recover: pl moodle rollback ${site} --tier=live execute"
        return 1
    fi
    _md_info "Purging caches…"
    if ! ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "$pc"; then
        _md_err "purge_caches.php FAILED. Leaving maintenance ON (fail-loud)."
        _md_err "Recover: pl moodle rollback ${site} --tier=live execute"
        return 1
    fi
    if [ "$no_maint" != "true" ]; then
        moodle_maintenance "$ssh_target" "$ssh_opts" "$sudo_prefix" "$php_bin" "$root" disable true \
            || { _md_err "upgrade OK but maintenance --disable FAILED — site still in maintenance."; return 1; }
    fi
    _md_ok "Moodle upgrade complete for ${site}."
    return 0
}

################################################################################
# Remote backup script builder (§4.6). Emits a self-contained remote bash script
# that reads dbname/dbuser/dbhost/dbpass from the live config.php via
# ABORT_AFTER_CONFIG (so the password NEVER leaves the remote host and never
# appears on any argv — MYSQL_PWD is set inside the remote subshell only), dumps
# the DB (gzip) and tars the deployed plugin dirs (NEVER moodledata).
#
# Usage: moodle_backup_remote_script <root> <site> <ts> <sudo_prefix> \
#            <db_only> <code_only> <plugin_relpaths_space_sep>
################################################################################
moodle_backup_remote_script() {
    local root="$1" site="$2" ts="$3" sudo_prefix="$4" db_only="$5" code_only="$6" plugins="$7"
    local db_file="nwp-snapshot-${site}-moodledb-${ts}.sql.gz"
    local code_file="nwp-snapshot-${site}-plugins-${ts}.tar.gz"

    cat <<RB
set -euo pipefail
CFGP="${root%/}/config.php"
OUT="\$HOME"
RB
    if [ "$code_only" != "true" ]; then
        cat <<RB
# --- DB dump: creds read from config.php on THIS host; password stays local ---
creds="\$(${sudo_prefix} -u www-data php -r 'define("CLI_SCRIPT",1); define("ABORT_AFTER_CONFIG",1); require \$argv[1]; echo \$CFG->dbname."|".\$CFG->dbuser."|".\$CFG->dbhost."|".\$CFG->dbpass;' "\$CFGP")"
DBN="\${creds%%|*}"; r="\${creds#*|}"; DBU="\${r%%|*}"; r="\${r#*|}"; DBH="\${r%%|*}"; DBP="\${r##*|}"
[ -n "\$DBN" ] || { echo "could not read dbname from config.php" >&2; exit 1; }
MYSQL_PWD="\$DBP" mysqldump --single-transaction --quick --routines --triggers -h "\$DBH" -u "\$DBU" "\$DBN" | gzip > "\$OUT/${db_file}"
echo "DB snapshot: \$OUT/${db_file}"
RB
    fi
    if [ "$db_only" != "true" ]; then
        cat <<RB
# --- plugin code tar (scoped to the deployed plugin dirs; NEVER moodledata) ---
${sudo_prefix} tar czf "\$OUT/${code_file}" -C "${root%/}" ${plugins}
${sudo_prefix} chown "\$(id -un):\$(id -gn)" "\$OUT/${code_file}" 2>/dev/null || true
echo "Code snapshot: \$OUT/${code_file}"
RB
    fi
    printf 'echo "%s"\n' "$db_file"
    printf 'echo "%s"\n' "$code_file"
}

################################################################################
# moodle_remote_backup — run the backup script on the remote and record a
# type:"moodle-remote" rollback entry (via rollback_record_moodle_remote).
#
# Args: <ssh_target> <ssh_opts> <sudo_prefix> <root> <site> <server_ip>
#       <ssh_user> <db_only> <code_only> <plugins_space_sep> <apply>
# Echoes "<ts>" on success.
################################################################################
moodle_remote_backup() {
    local ssh_target="$1" ssh_opts="$2" sudo_prefix="$3" root="$4" site="$5"
    local server_ip="$6" ssh_user="$7" db_only="$8" code_only="$9" plugins="${10}" apply="${11:-false}"

    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local script; script="$(moodle_backup_remote_script "$root" "$site" "$ts" "$sudo_prefix" "$db_only" "$code_only" "$plugins")"

    if [ "$apply" != "true" ]; then
        _md_info "[dry-run] would run on ${ssh_target} (backup ${site}, ts=${ts}):"
        printf '%s\n' "$script" | sed 's/^/    /'
        echo "$ts"
        return 0
    fi

    _md_info "Snapshotting ${site} on ${ssh_target} (ts=${ts})…"
    if ! printf '%s\n' "$script" | ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "bash -s"; then
        _md_err "Remote backup FAILED for ${site}."
        return 1
    fi
    local db_file="nwp-snapshot-${site}-moodledb-${ts}.sql.gz"
    local code_file="nwp-snapshot-${site}-plugins-${ts}.tar.gz"
    local home_dir; home_dir="$(ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" 'echo $HOME' 2>/dev/null || echo "/home/${ssh_user}")"
    [ "$db_only"   = "true" ] && code_file=""
    [ "$code_only" = "true" ] && db_file=""
    if command -v rollback_record_moodle_remote >/dev/null 2>&1; then
        rollback_record_moodle_remote "$site" "live" "$ssh_user" "$server_ip" "$ts" \
            "${db_file:+${home_dir}/${db_file}}" "${code_file:+${home_dir}/${code_file}}" \
            "${root%/}" "$plugins" || _md_warn "Snapshot written but rollback registration failed."
    fi
    _md_ok "Backup complete for ${site} (ts=${ts})."
    echo "$ts"
    return 0
}

################################################################################
# moodle_remote_rollback_execute — §4.6 restore. Reads a type:"moodle-remote"
# entry, then: typed-timestamp confirm → maintenance ON → tar xzf plugin code →
# gunzip|mysql (creds from config.php on the remote) → purge_caches →
# maintenance OFF → smoke hand-off. DRY-RUN prints the plan.
#
# Args: <entry_file> <ssh_opts> <apply>
################################################################################
moodle_remote_rollback_execute() {
    local entry_file="$1" ssh_opts="${2:-}" apply="${3:-false}"
    [ -f "$entry_file" ] || { _md_err "rollback entry not found: $entry_file"; return 1; }

    local site env ts host user dbs plugins root
    site=$(grep    -m1 '"sitename"'       "$entry_file" | sed 's/.*: *"\([^"]*\)".*/\1/')
    env=$(grep     -m1 '"environment"'    "$entry_file" | sed 's/.*: *"\([^"]*\)".*/\1/')
    ts=$(grep      -m1 '"timestamp"'      "$entry_file" | sed 's/.*: *"\([^"]*\)".*/\1/')
    host=$(grep    -m1 '"host"'           "$entry_file" | sed 's/.*: *"\([^"]*\)".*/\1/')
    user=$(grep    -m1 '"ssh_user"'       "$entry_file" | sed 's/.*: *"\([^"]*\)".*/\1/')
    dbs=$(grep     -m1 '"snapshot_db"'    "$entry_file" | sed 's/.*: *"\([^"]*\)".*/\1/')
    plugins=$(grep -m1 '"snapshot_plugins"' "$entry_file" | sed 's/.*: *"\([^"]*\)".*/\1/')
    root=$(grep    -m1 '"moodle_root"'    "$entry_file" | sed 's/.*: *"\([^"]*\)".*/\1/')

    local sudo_prefix=""; [ "$user" = "gitlab" ] && sudo_prefix="sudo"
    local ssh_target="${user}@${host}"
    local php_bin="php"

    print_header "Moodle rollback: ${site}@${env} (snapshot ${ts})" 2>/dev/null || echo "== Moodle rollback: ${site}@${env} (snapshot ${ts}) =="
    _md_info "  DB dump:      ${dbs:-（none）}"
    _md_info "  Plugins tar:  ${plugins:-（none）}"
    _md_info "  Moodle root:  ${root}"

    if [ "$apply" != "true" ]; then
        _md_warn "DRY RUN — nothing executed. Plan:"
        echo "    1. maintenance --enable"
        [ -n "$plugins" ] && echo "    2. ${sudo_prefix} tar xzf ${plugins} -C ${root}"
        [ -n "$dbs" ]     && echo "    3. gunzip -c ${dbs} | mysql <dbname-from-config.php>"
        echo "    4. admin/cli/purge_caches.php"
        echo "    5. maintenance --disable"
        echo "    6. pl moodle smoke ${site} --tier=${env} --run"
        _md_info "Re-run with 'execute' (you will be asked to type the timestamp)."
        return 0
    fi

    # Typed-timestamp confirm (last-recovery-path strength).
    if command -v impact_confirm >/dev/null 2>&1; then
        impact_reset 2>/dev/null || true
        impact_overwrite "Live Moodle DB" "restored from ${dbs:-（db-only skipped）}"
        impact_overwrite "Plugin code"    "restored from ${plugins:-（code skipped）}"
        impact_keep "moodledata (uploads) — never touched by rollback"
        impact_render
        impact_confirm typed "$ts" "${AUTO_CONFIRM:-false}" || { _md_err "aborted."; return 1; }
    else
        read -rp "Type the snapshot timestamp (${ts}) to confirm: " c
        [ "$c" = "$ts" ] || { _md_err "confirmation mismatch — aborting."; return 1; }
    fi

    moodle_maintenance "$ssh_target" "$ssh_opts" "$sudo_prefix" "$php_bin" "$root" enable true \
        || { _md_err "maintenance --enable failed — aborting rollback."; return 1; }

    if [ -n "$plugins" ]; then
        _md_info "Restoring plugin code from ${plugins}…"
        ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "${sudo_prefix} tar xzf '${plugins}' -C '${root%/}'" \
            || { _md_err "plugin tar restore FAILED — site left in maintenance."; return 1; }
    fi
    if [ -n "$dbs" ]; then
        _md_info "Restoring DB from ${dbs}…"
        local restore_db
        restore_db="$(cat <<RB
set -euo pipefail
creds="\$(${sudo_prefix} -u www-data php -r 'define("CLI_SCRIPT",1); define("ABORT_AFTER_CONFIG",1); require \$argv[1]; echo \$CFG->dbname."|".\$CFG->dbuser."|".\$CFG->dbhost."|".\$CFG->dbpass;' '${root%/}/config.php')"
DBN="\${creds%%|*}"; r="\${creds#*|}"; DBU="\${r%%|*}"; r="\${r#*|}"; DBH="\${r%%|*}"; DBP="\${r##*|}"
gunzip -c '${dbs}' | MYSQL_PWD="\$DBP" mysql -h "\$DBH" -u "\$DBU" "\$DBN"
RB
)"
        printf '%s\n' "$restore_db" | ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "bash -s" \
            || { _md_err "DB restore FAILED — live state indeterminate, site in maintenance. INVESTIGATE."; return 2; }
    fi

    _md_info "Purging caches…"
    ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "$(_md_trim "${sudo_prefix} -u www-data ${php_bin} ${root%/}/admin/cli/purge_caches.php")" \
        || _md_warn "purge_caches failed (non-fatal)."

    moodle_maintenance "$ssh_target" "$ssh_opts" "$sudo_prefix" "$php_bin" "$root" disable true \
        || _md_warn "maintenance --disable failed — disable it manually."

    # Mark entry rolled_back.
    sed -i 's/"status": "active"/"status": "rolled_back"/' "$entry_file" 2>/dev/null || true
    _md_ok "Rollback complete: ${site}@${env} restored from ${ts}."
    return 0
}

# Resolve the Moodle CLI php binary for a site (Moodle 4.4 rejects PHP 8.4).
# Reads .moodle.cli_php_version from the site config; defaults to php8.2 if that
# binary exists, else php.
moodle_cli_php_bin() {
    local config_file="$1"
    local ver=""
    if declare -F _mp_cfg >/dev/null 2>&1; then
        ver="$(_mp_cfg "$config_file" '.moodle.cli_php_version' '' 2>/dev/null || true)"
    fi
    if [ -n "$ver" ] && command -v "php${ver}" >/dev/null 2>&1; then echo "php${ver}"; return; fi
    if command -v php8.2 >/dev/null 2>&1; then echo "php8.2"; return; fi
    echo "php"
}
