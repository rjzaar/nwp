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
# The php_opts (item 9: -d max_input_vars=5000) are inserted here too — the
# box's php.ini max_input_vars=1000 is below Moodle's floor, and getting it
# wrong on the maintenance leg is how a site gets STUCK in maintenance.
moodle_maintenance() {
    local ssh_target="$1" ssh_opts="$2" sudo_prefix="$3" php_bin="$4" root="$5" action="$6" apply="${7:-false}"
    local flag="--enable"; [ "$action" = "disable" ] && flag="--disable"
    local remote="${sudo_prefix} -u www-data ${php_bin} $(moodle_cli_php_opts) ${root%/}/admin/cli/maintenance.php ${flag}"
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

    # item 9: the php opts (-d max_input_vars=5000) are NOT optional here.
    # Without them upgrade.php fails its environment check AFTER maintenance
    # mode has been enabled — the exact sequence that took the `ss` instance down
    # for ~6 minutes on 2026-07-26 with no pl verb able to clear it.
    local opts; opts="$(moodle_cli_php_opts)"
    if ! moodle_cli_assert "$php_bin" "$opts"; then
        _md_err "Refusing to run the Moodle upgrade with an unsafe CLI invocation."
        return 1
    fi
    local up="${sudo_prefix} -u www-data ${php_bin} ${opts} ${root%/}/admin/cli/upgrade.php --non-interactive"
    local pc="${sudo_prefix} -u www-data ${php_bin} ${opts} ${root%/}/admin/cli/purge_caches.php"
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
# FIRST-INSTALL (ops#146): a plugin being deployed for the first time does not
# exist on the remote yet, and GNU tar exits 2 on a missing member. Under
# 'set -e' that aborted the whole snapshot, which the deploy verb correctly
# read as "no rollback point" and refused — making it structurally impossible to
# install any NEW plugin on a live Moodle. Filter to the dirs that actually
# exist: there is nothing to roll back for a plugin that is not there yet, and
# rolling that plugin back is 'rm -rf' of a directory this deploy created.
# If NONE of them exist we still write a valid (empty) tar rather than skipping,
# so the rollback record always points at a real artifact.
PRESENT=""
for p in ${plugins}; do
  if [ -d "${root%/}/\$p" ]; then PRESENT="\$PRESENT \$p"; else echo "  (new plugin, nothing to snapshot: \$p)"; fi
done
if [ -n "\$PRESENT" ]; then
  ${sudo_prefix} tar czf "\$OUT/${code_file}" -C "${root%/}" \$PRESENT
else
  ${sudo_prefix} tar czf "\$OUT/${code_file}" -C "${root%/}" --files-from=/dev/null
fi
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
    # ops#146: this was hardcoded to bare `php`. On the forge box bare `php` is
    # 8.4, which Moodle 4.4 REJECTS — so maintenance --enable would fail and
    # abort the rollback. A rollback path that only works when you don't need it
    # is not a rollback path. Resolve the same way the deploy path does, and
    # assert, so a bad resolution fails loudly here rather than mid-recovery.
    local php_bin php_opts
    php_bin="$(moodle_cli_php_bin "${root%/}/config.php")"
    php_opts="$(moodle_cli_php_opts "${root%/}/config.php")"
    moodle_cli_assert "$php_bin" "$php_opts" || return 1

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
    ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "$(_md_trim "${sudo_prefix} -u www-data ${php_bin} ${php_opts} ${root%/}/admin/cli/purge_caches.php")" \
        || _md_warn "purge_caches failed (non-fatal)."

    moodle_maintenance "$ssh_target" "$ssh_opts" "$sudo_prefix" "$php_bin" "$root" disable true \
        || _md_warn "maintenance --disable failed — disable it manually."

    # Mark entry rolled_back.
    sed -i 's/"status": "active"/"status": "rolled_back"/' "$entry_file" 2>/dev/null || true
    _md_ok "Rollback complete: ${site}@${env} restored from ${ts}."
    return 0
}

################################################################################
# THE TWO PIECES OF TRIBAL KNOWLEDGE, CODIFIED (item 9)
#
# Every `admin/cli/*` invocation against a live Moodle on the forge box needs
# BOTH of these, and typing either one wrong is how a site ends up stuck in
# maintenance mode:
#
#   1. an explicit php8.2/8.3 binary — the box's DEFAULT `php` is 8.4
#      (verified: `php -v` → 8.4.21) and Moodle 4.4 REJECTS PHP 8.4;
#   2. `-d max_input_vars=5000` — the box's php.ini says 1000 (verified:
#      `php8.2 -i | grep max_input_vars` → 1000 => 1000), below Moodle's floor.
#
# On 2026-07-26 `upgrade.php` was run without (2). It failed its environment
# check *after* enabling maintenance mode and left the `ss` instance down for
# ~6 minutes, with no `pl` verb able to clear maintenance. These helpers exist
# so neither value is ever typed by a human again — and moodle_cli_assert makes
# their absence a REFUSAL rather than a silent, damaging run.
################################################################################

# Default CLI php version for remote Moodle. Overridable per site via
# .moodle.cli_php_version, or per invocation via NWP_MOODLE_CLI_PHP_BIN.
MOODLE_CLI_PHP_DEFAULT_VERSION="${MOODLE_CLI_PHP_DEFAULT_VERSION:-8.2}"
# Default CLI php flags. Overridable via .moodle.cli_php_opts / NWP_MOODLE_CLI_PHP_OPTS.
MOODLE_CLI_PHP_DEFAULT_OPTS="${MOODLE_CLI_PHP_DEFAULT_OPTS:--d max_input_vars=5000}"

# Resolve the Moodle CLI php binary for a site (Moodle 4.4 rejects PHP 8.4).
#
# REMOTE-CORRECT (item 9): this names a binary on the REMOTE host, so it must
# NOT be validated with a LOCAL `command -v`. The previous implementation did
# exactly that and fell back to bare `php` whenever the *local* machine lacked
# php8.2 — on the box, bare `php` is 8.4 and Moodle refuses it. That fail-open
# is invisible from the dev laptop (which has php8.2) and appears the moment the
# command runs from another agent host or a CI runner, i.e. where nobody is watching.
moodle_cli_php_bin() {
    local config_file="${1:-}"
    if [ -n "${NWP_MOODLE_CLI_PHP_BIN:-}" ]; then
        printf '%s' "$(_md_trim "${NWP_MOODLE_CLI_PHP_BIN}")"
        return 0
    fi
    local ver=""
    if [ -n "$config_file" ] && declare -F _mp_cfg >/dev/null 2>&1; then
        ver="$(_mp_cfg "$config_file" '.moodle.cli_php_version' '' 2>/dev/null || true)"
    fi
    [ -z "$ver" ] && ver="$MOODLE_CLI_PHP_DEFAULT_VERSION"
    printf 'php%s' "$ver"
}

# Resolve the Moodle CLI php flags. Same override chain as the binary.
moodle_cli_php_opts() {
    local config_file="${1:-}"
    if [ -n "${NWP_MOODLE_CLI_PHP_OPTS+x}" ]; then
        printf '%s' "$(_md_trim "${NWP_MOODLE_CLI_PHP_OPTS}")"
        return 0
    fi
    local opts=""
    if [ -n "$config_file" ] && declare -F _mp_cfg >/dev/null 2>&1; then
        opts="$(_mp_cfg "$config_file" '.moodle.cli_php_opts' '' 2>/dev/null || true)"
    fi
    [ -z "$opts" ] && opts="$MOODLE_CLI_PHP_DEFAULT_OPTS"
    printf '%s' "$opts"
}

# moodle_cli_assert <php_bin> <php_opts>
# Fail-closed check that a resolved Moodle CLI invocation carries BOTH pieces of
# box knowledge. This is the difference between documenting the gotcha and
# enforcing it: a plan that has lost either half must REFUSE, not run.
moodle_cli_assert() {
    local php_bin="$1" php_opts="$2" ok=0
    php_bin="$(_md_trim "$php_bin")"; php_opts="$(_md_trim "$php_opts")"
    if [ -z "$php_bin" ]; then
        _md_err "No php binary resolved for the Moodle CLI."
        _md_err "  The box default 'php' is 8.4 and Moodle 4.4 REJECTS it — refusing to guess."
        _md_err "  Set .moodle.cli_php_version in the site config (e.g. \"8.2\")."
        ok=1
    elif [ "$php_bin" = "php" ]; then
        _md_err "Refusing a bare 'php' binary for the Moodle CLI: on the forge box that is 8.4,"
        _md_err "  which Moodle 4.4 rejects. Set .moodle.cli_php_version (e.g. \"8.2\")."
        ok=1
    fi
    case "$php_opts" in
        *max_input_vars=*) ;;
        *)  _md_err "Resolved Moodle CLI options do not set max_input_vars: '${php_opts}'"
            _md_err "  The box php.ini value (1000) is BELOW Moodle's floor. Without"
            _md_err "  -d max_input_vars=5000, admin/cli scripts fail their environment check"
            _md_err "  AFTER maintenance mode is enabled and leave the site DOWN (2026-07-26)."
            ok=1 ;;
    esac
    return "$ok"
}

################################################################################
# DECLARED CORE PATCHES (item 9)
#
# ssc's live guest front door is a one-line change to Moodle CORE index.php
# (`redirect(new moodle_url('/local/browse/'))`). It was verified live on the
# box and existed ONLY as an uncommitted working-tree diff in a checkout whose
# only remote is github.com/moodle/moodle — so a `git checkout`, a Moodle point
# release or a DR rebuild silently reverts the pilot's entry point.
#
# A declared core patch is a row in <site>/core-patches.yml:
#   core_patches:
#     - id:     ssc-index-browse-frontdoor
#       file:   index.php            # relative to the Moodle root
#       assert: "local/browse"       # substring that MUST be present when applied
#       why:    "guest front door redirects to local_browse"
#       patch:  core-patches/ssc-index-browse-frontdoor.patch   # optional
#
# `assert` is deliberately a presence check on the target, not a diff: it
# answers the only question that matters at deploy time ("is the patch actually
# on the thing I am about to upgrade?") and stays true across Moodle point
# releases that renumber lines.
################################################################################

# moodle_core_patches_file <base> — echo the declaration path for a site.
moodle_core_patches_file() {
    printf '%s/sites/%s/core-patches.yml' "${PROJECT_ROOT:-.}" "$1"
}

# moodle_core_patch_ids <decl_file> — echo one patch id per line.
#
# TRI-STATE (2026-07-27) — same vocabulary as lib/boundary.sh rc 2 / lib/pair.sh:
#   rc 0  ids echoed          — the declaration parsed and names patches
#   rc 1  nothing declared    — file absent/empty, or `core_patches:` is null or
#                               an explicitly empty list. A clean no-op.
#   rc 2  CANNOT VERIFY       — the file exists and carries content, but no patch
#                               ids can be read from it (unparseable YAML, or a
#                               `core_patches:` key that is missing/mis-shaped).
#                               The reason is echoed; NEVER treat this as rc 1.
#
# Why the distinction is load-bearing: the ONLY caller (scripts/commands/moodle.sh
# cmd_core_patch, armed by the `[ -s ... ]` test in the deploy guard chain)
# printed "no core patches declared" and returned 0 on an empty id list. So a
# corrupt or mis-keyed core-patches.yml emptied a gate whose own refusal message
# says "Override is deliberately NOT provided". ssc's live guest front door is a
# declared core patch; an emptied gate means the deploy silently stops checking
# that live core still carries it.
moodle_core_patch_ids() {
    local f="$1" yq_bin
    [ -f "$f" ] || return 1
    [ -s "$f" ] || return 1

    if declare -F _mp_yq >/dev/null 2>&1 && yq_bin="$(_mp_yq 2>/dev/null)"; then
        if ! "$yq_bin" eval '.' "$f" >/dev/null 2>&1; then
            printf '%s does not parse as YAML, so the core patches it declares cannot be read\n' "$f"
            return 2
        fi
        # An explicit `core_patches:` that is null or [] is a real declaration of
        # "this site has none" — rc 1, a clean no-op. A file with content and NO
        # `core_patches:` key at all is a declaration filed under a name this
        # reader does not know (typo, wrong schema) — rc 2, not an absence.
        local roottag; roottag="$("$yq_bin" eval '. | tag' "$f" 2>/dev/null)"
        if [ "$roottag" != '!!map' ]; then
            printf "%s is a %s at its root, not a mapping with a 'core_patches:' key\n" "$f" "${roottag#!!}"
            return 2
        fi
        if [ "$("$yq_bin" eval 'has("core_patches")' "$f" 2>/dev/null)" != "true" ]; then
            printf "%s has content but no 'core_patches:' key — a declaration filed under a key this reader does not know is not the same as no declaration\n" "$f"
            return 2
        fi
        local tag; tag="$("$yq_bin" eval '.core_patches | tag' "$f" 2>/dev/null)"
        case "$tag" in
            '!!null') return 1 ;;
            '!!seq')  ;;
            *)  printf "%s: 'core_patches:' is a %s, not a list of patch entries\n" "$f" "${tag#!!}"
                return 2 ;;
        esac
        local n; n="$("$yq_bin" eval '.core_patches | length' "$f" 2>/dev/null)"
        [ "${n:-0}" -gt 0 ] 2>/dev/null || return 1     # explicitly empty list
        local ids; ids="$("$yq_bin" eval '.core_patches[].id' "$f" 2>/dev/null)"
        if [ -z "$ids" ] || printf '%s\n' "$ids" | grep -q '^null$'; then
            printf "%s declares %s core patch entr(y|ies) but not every one carries an 'id:' — refusing to verify a subset\n" "$f" "$n"
            return 2
        fi
        printf '%s\n' "$ids"
        return 0
    fi

    # No yq on this host: best-effort read, but a declaration file with content
    # that yields ZERO ids is still blindness, not absence.
    local ids
    ids="$(sed -n 's/^[[:space:]]*-[[:space:]]*id:[[:space:]]*//p' "$f" | tr -d '"'"'")"
    if [ -z "$ids" ]; then
        if grep -q '^[[:space:]]*core_patches:[[:space:]]*\(\[\][[:space:]]*\)\?$' "$f" \
           && ! grep -q '[^[:space:]#]' <(grep -v '^[[:space:]]*core_patches:' "$f"); then
            return 1                                    # `core_patches:` and nothing else
        fi
        printf "%s has content but no patch 'id:' lines could be read from it (no yq available to parse it properly)\n" "$f"
        return 2
    fi
    printf '%s\n' "$ids"
    return 0
}

# moodle_core_patch_field <decl_file> <id> <field>
moodle_core_patch_field() {
    local f="$1" id="$2" field="$3" yq_bin v=""
    [ -f "$f" ] || return 1
    if declare -F _mp_yq >/dev/null 2>&1 && yq_bin="$(_mp_yq 2>/dev/null)"; then
        v="$("$yq_bin" eval ".core_patches[] | select(.id == \"$id\") | .${field}" "$f" 2>/dev/null | grep -v '^null$' | head -1 || true)"
    fi
    if [ -z "$v" ]; then
        v="$(awk -v id="$id" -v field="$field" '
            $0 ~ "^[[:space:]]*-[[:space:]]*id:[[:space:]]*" { inblk = ($0 ~ id) }
            inblk && $0 ~ "^[[:space:]]*" field ":" {
                sub("^[[:space:]]*" field ":[[:space:]]*", "")
                gsub(/^["'"'"']|["'"'"']$/, ""); print; exit
            }' "$f")"
    fi
    printf '%s' "$v"
}

# moodle_core_patch_check_local <root> <file> <assert>
# 0 = applied, 1 = missing, 2 = target file absent.
moodle_core_patch_check_local() {
    local root="${1%/}" file="$2" want="$3"
    [ -f "${root}/${file}" ] || return 2
    grep -qF -- "$want" "${root}/${file}" && return 0
    return 1
}

# moodle_core_patch_check_remote <ssh_target> <ssh_opts> <sudo_prefix> <root> <file> <assert>
# Read-only remote grep. Same status contract as the local check, plus 3 =
# unreachable — which must NEVER be reported as "applied".
moodle_core_patch_check_remote() {
    local ssh_target="$1" ssh_opts="$2" sudo_prefix="$3" root="${4%/}" file="$5" want="$6"
    local remote out
    remote="f='${root}/${file}'; if [ ! -f \"\$f\" ]; then echo ABSENT; elif ${sudo_prefix} grep -qF -- $(printf '%q' "$want") \"\$f\"; then echo APPLIED; else echo MISSING; fi"
    remote="$(_md_trim "$remote")"
    out="$(ssh ${ssh_opts} -o BatchMode=yes -o ConnectTimeout=10 "$ssh_target" "$remote" 2>/dev/null || echo UNREACHABLE)"
    case "$out" in
        APPLIED) return 0 ;;
        MISSING) return 1 ;;
        ABSENT)  return 2 ;;
        *)       return 3 ;;
    esac
}

################################################################################
# PLUGIN VERSION DRIFT (item 9)
#
# auth_nwc — the plugin carrying the SSO uid-lock AND the Art.9 consent gate —
# exists in three repos at three versions. Verified 2026-07-26:
#   scripts/f26/moodle/auth_nwc            2026071101 / 1.0.0
#   sites/ssc/dev/auth/nwc                 2026072400 / 1.2.0-draft
#   sites/*/.plugin-src/ss-moodle-plugins  2026072400 / 1.2.0-draft
#   LIVE ssc:/var/www/ssc/auth/nwc         2026072400 / 1.2.0-draft
# A "deploy auth_nwc v1.0.1" from the wrong tree silently DOWNGRADES live ssc
# and drops the consent gate. Nothing detected that before this verb.
################################################################################

# moodle_plugin_version_dir <plugin_dir> — echo the numeric $plugin->version of
# the plugin whose ROOT is this directory (i.e. <dir>/version.php).
#
# The deploy path resolves a source to the plugin directory itself, not to a
# tree root, so it cannot use moodle_plugin_version_local without re-deriving
# the split. Both now read the same file the same way, in one place: a second
# regex for the same field is how two callers come to disagree about what
# version a tree is at.
moodle_plugin_version_dir() {
    local f="${1%/}/version.php"
    [ -f "$f" ] || return 1
    local v; v=$(sed -n 's/.*\$plugin->version[[:space:]]*=[[:space:]]*\([0-9]\{6,\}\).*/\1/p' "$f" | head -1)
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# moodle_plugin_version_local <tree_root> <plugin> — echo the numeric version.
moodle_plugin_version_local() {
    local root="${1%/}" plugin="$2"
    moodle_plugin_version_dir "${root}/${plugin}"
}

# moodle_version_direction <src_version> <tgt_version> — WHICH WAY does this
# deploy move $plugin->version on the target? (ops#229)
#
# The decision is a pure function of two numbers, so it lives here where it can
# be exercised exhaustively without an ssh, a site config or a live host. The
# command that consumes it does the refusing.
#
# Echoes exactly one of:
#   unreadable-source  the SOURCE has no readable version  -> refuse: an
#                      uncomparable deploy is the one this gate exists to stop
#   unreadable-target  the TARGET could not be ASKED         -> refuse: an ssh
#                      timeout must not read as "nothing installed yet"
#   first-install      the TARGET has no version.php          -> allow, and say so
#   forward            src >  tgt                          -> allow
#   same               src == tgt                          -> allow (re-ship)
#   backwards          src <  tgt                          -> refuse unless the
#                      operator says --allow-downgrade
#
# `first-install` and `unreadable-source` are deliberately DIFFERENT answers.
# Both involve a missing version.php, and collapsing them would mean either
# refusing every genuine first install or waving through a source we cannot
# read — the two halves of the same vacuous pass.
moodle_version_direction() {
    local src="${1:-}" tgt="${2:-}"
    case "$src" in ''|*[!0-9]*) echo "unreadable-source"; return 0 ;; esac
    case "$tgt" in unreachable) echo "unreadable-target"; return 0 ;; esac
    case "$tgt" in ''|none|*[!0-9]*) echo "first-install"; return 0 ;; esac
    if   [ "$src" -lt "$tgt" ]; then echo "backwards"
    elif [ "$src" -gt "$tgt" ]; then echo "forward"
    else                             echo "same"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# CANONICAL VERSION — what does nwp/ss-moodle-plugins' own main branch say?
#
# WHY THIS EXISTS (ops#259). Every other reader in this file answers "are the
# copies the same as EACH OTHER?". That question has a true-and-useless answer
# whenever the whole fleet is equally stale: measured 2026-08-03, ssd's dev
# tree, plugin cache and LIVE all reported local/feedback 2026051704 and drift
# printed "every compared copy agrees" — while canonical main was 2026080101,
# the range that added classes/privacy/provider.php. So live Moodle had no
# GDPR handler for a table holding userid/username/email/ipaddress, and the
# verb whose job is deployment sameness said OK.
#
# This reads the version out of a git REF rather than the checked-out tree,
# because the cache is a working checkout that is frequently sitting on some
# feature branch — its worktree is not the canonical answer, its origin/main is.
#
# Echoes the numeric version on success. Returns non-zero — printing nothing —
# when it could not look (not a repo, ref absent, path absent, no version line).
# The caller MUST render that as CANONICAL-UNKNOWN and must not let it read as
# agreement.
# ─────────────────────────────────────────────────────────────────────────────
moodle_plugin_version_canonical() {
    local repo="${1%/}" plugin="$2" ref="${3:-origin/main}" blob v
    [ -n "$repo" ] || return 1
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 1
    git -C "$repo" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1 || return 1
    blob="$(git -C "$repo" show "${ref}:${plugin}/version.php" 2>/dev/null)" || return 1
    [ -n "$blob" ] || return 1
    v="$(printf '%s\n' "$blob" \
         | sed -n 's/.*\$plugin->version[[:space:]]*=[[:space:]]*\([0-9]\{6,\}\).*/\1/p' | head -1)"
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# moodle_plugin_version_remote <ssh_target> <ssh_opts> <sudo_prefix> <root> <plugin>
# ─────────────────────────────────────────────────────────────────────────────
# BACKUP-SUBPLUGIN CAPABILITY — is the module's FEATURE_BACKUP_MOODLE2 claim true?
#
# Moodle never checks. backup_plan_builder does a bare file_exists() on
# backup/moodle2/backup_<name>_activity_task.class.php and SILENTLY SKIPS the
# activity when it is missing — no warning, exit 0. mod/depthcontent answered
# `case FEATURE_BACKUP_MOODLE2: return true;` for its whole life while shipping
# no backup/ directory, so every course backup dropped every depthcontent
# activity and every restore looked clean. 55 courses restored with 0 activities.
#
# Echoes exactly one of:
#   ok       advertises backup support and ships the matching task class
#   blind    advertises backup support and does NOT  — the data-loss posture
#   n/a      not an activity module, or honestly declines support
#   unknown  could not look (absent tree / no lib.php) — never conflated with ok
#
# `unknown` is deliberately distinct from `n/a`: "I could not look" reported as
# "nothing to see" is the vacuous pass this programme exists to eliminate.
# ─────────────────────────────────────────────────────────────────────────────
moodle_plugin_backup_capable_local() {
    local root="${1%/}" plugin="$2"
    local dir="${root}/${plugin}" name="${plugin#*/}"

    # Only activity modules have an activity backup task.
    case "$plugin" in mod/*) ;; *) echo "n/a"; return 0 ;; esac
    [ -d "$dir" ] || { echo "unknown"; return 0; }

    local lib="${dir}/lib.php"
    [ -f "$lib" ] || { echo "unknown"; return 0; }

    # Does it CLAIM Moodle2 backup support? Match the `case ...: return true;`
    # arm specifically — the constant also appears in comments and in `false`
    # arms, and treating either as a claim would cry wolf.
    if ! grep -Eq 'FEATURE_BACKUP_MOODLE2[[:space:]]*:[[:space:]]*return[[:space:]]+true' "$lib"; then
        echo "n/a"; return 0
    fi

    # The claim is only true if THIS module's task class is present. A task
    # class copy-pasted from another module does not implement this one.
    if [ -f "${dir}/backup/moodle2/backup_${name}_activity_task.class.php" ]; then
        echo "ok"
    else
        echo "blind"
    fi
    return 0
}

# Remote twin of the above. Same four answers; an ssh that cannot answer is
# `unknown`, never `ok`.
moodle_plugin_backup_capable_remote() {
    local ssh_target="$1" ssh_opts="$2" sudo_prefix="$3" root="${4%/}" plugin="$5"
    local name="${plugin#*/}" dir="${root}/${plugin}" remote out

    case "$plugin" in mod/*) ;; *) echo "n/a"; return 0 ;; esac

    remote="if [ ! -f '${dir}/lib.php' ]; then echo unknown;
            elif ! ${sudo_prefix} grep -Eq 'FEATURE_BACKUP_MOODLE2[[:space:]]*:[[:space:]]*return[[:space:]]+true' '${dir}/lib.php'; then echo n/a;
            elif ${sudo_prefix} test -f '${dir}/backup/moodle2/backup_${name}_activity_task.class.php'; then echo ok;
            else echo blind; fi"
    remote="$(_md_trim "$remote")"
    out="$(ssh ${ssh_opts} -o BatchMode=yes -o ConnectTimeout=10 "$ssh_target" "$remote" 2>/dev/null || true)"
    out="$(printf '%s' "$out" | tr -dc 'a-z/')"
    case "$out" in
        ok|blind|n/a|unknown) printf '%s' "$out" ;;
        *)                    printf 'unknown' ;;
    esac
    return 0
}

# moodle_plugin_target_version <ssh_target> <ssh_opts> <sudo_prefix> <root> <plugin>
# ─────────────────────────────────────────────────────────────────────────────
# THREE ANSWERS, because "I could not look" is not "there is nothing there".
#
#   <digits>     the target runs this $plugin->version
#   none         the target has no version.php for this plugin (a FIRST INSTALL)
#   unreachable  the host could not be asked at all
#
# moodle_plugin_version_remote (below) collapses the last two into "empty", which
# is right for `drift`'s reporting table and WRONG for a gate: an ssh timeout
# would read as "not installed yet" and the version-direction gate would wave a
# downgrade straight through. The sentinel is emitted by the REMOTE side, so the
# difference is established where the file actually is.
# moodle_version_gate_report <plugin> <src_dir> <src_v> <tgt_v> <allow_downgrade>
#                            <base> <tier> <origin>
# ─────────────────────────────────────────────────────────────────────────────
# Print one line per plugin saying WHICH WAY the deploy moves it, and return 1
# if the deploy must be refused for this plugin (ops#229).
#
# It lives here, not inline in cmd_plugin_deploy, so the REFUSAL itself is
# testable without a site config, a pair contract, an Art.9 gate or a live host.
# The first version of this gate was inline, and the only tests possible were
# greps for the presence of a function name — which stayed green when the
# refusal was deleted. A guard whose refusal cannot be exercised is a guard on
# paper (ops#214).
moodle_version_gate_report() {
    local plugin="$1" src_dir="$2" src_v="$3" tgt_v="$4" allow_downgrade="$5"
    local base="$6" tier="$7" origin="${8:-?}"
    local dir; dir="$(moodle_version_direction "$src_v" "$tgt_v")"

    case "$dir" in
        unreadable-source)
            printf '    %-28s %s\n' "$plugin" "SOURCE VERSION UNREADABLE"
            _md_err  "  ${src_dir}/version.php has no \$plugin->version — refusing."
            _md_info "  A source whose version cannot be read cannot be compared, and an"
            _md_info "  uncomparable deploy is exactly the one this gate exists to stop."
            return 1 ;;
        unreadable-target)
            printf '    %-28s %s\n' "$plugin" "TARGET VERSION UNREADABLE"
            _md_err  "  Could not read ${base}@${tier}'s installed version of '${plugin}' over ssh — refusing."
            _md_info "  This is 'could not look', NOT 'nothing installed'. Treating an ssh"
            _md_info "  timeout as a first install is how a downgrade gets waved through."
            return 1 ;;
        first-install)
            printf '    %-28s %-12s -> %s\n' "$plugin" "$src_v" "(not installed on target — first install)"
            return 0 ;;
        same)
            printf '    %-28s %-12s == %s  (re-ship, no version change)\n' "$plugin" "$src_v" "$tgt_v"
            return 0 ;;
        forward)
            printf '    %-28s %-12s -> %s  (forward)\n' "$plugin" "$tgt_v" "$src_v"
            return 0 ;;
        backwards)
            printf '    %-28s %-12s -> %s  ** BACKWARDS **\n' "$plugin" "$src_v" "$tgt_v"
            if [ "$allow_downgrade" = "true" ]; then
                _md_warn "  DOWNGRADE ACCEPTED for '${plugin}': ${tgt_v} -> ${src_v} (--allow-downgrade)."
                return 0
            fi
            _md_err  "  REFUSED: '${plugin}' would go BACKWARDS on ${base}@${tier}: ${tgt_v} -> ${src_v}."
            _md_info "  Source: ${origin} — ${src_dir}"
            _md_info "  The default source is the DEV tree, which is often behind live."
            _md_info "  Ship the canonical tree instead:"
            _md_info "    pl moodle plugins sync ${base} --apply    # refresh the canonical cache"
            _md_info "    pl moodle plugin deploy ${base} ${plugin} --tier=${tier} --from-canonical"
            _md_info "  Or, if this really is a rollback, say so: --allow-downgrade"
            return 1 ;;
    esac
    # An unrecognised direction is a programming error, and the safe reading of
    # a programming error in a gate is REFUSE.
    _md_err "  unknown version direction '$dir' for '${plugin}' — refusing (fail closed)."
    return 1
}

moodle_plugin_target_version() {
    local ssh_target="$1" ssh_opts="$2" sudo_prefix="$3" root="${4%/}" plugin="$5"
    local remote out rc=0
    remote="if ${sudo_prefix} test -f '${root}/${plugin}/version.php'; then
              ${sudo_prefix} sed -n 's/.*\\\$plugin->version[[:space:]]*=[[:space:]]*\\([0-9]\\{6,\\}\\).*/\\1/p' '${root}/${plugin}/version.php' | head -1;
            else echo NOFILE; fi"
    remote="$(_md_trim "$remote")"
    out="$(ssh ${ssh_opts} -o BatchMode=yes -o ConnectTimeout=10 "$ssh_target" "$remote" 2>/dev/null)" || rc=$?
    [ "$rc" -eq 0 ] || { printf 'unreachable'; return 0; }
    out="$(printf '%s' "$out" | tr -dc 'A-Z0-9')"
    case "$out" in
        NOFILE) printf 'none' ;;
        '')     printf 'none' ;;          # file present but carries no version
        *[!0-9]*) printf 'unreachable' ;; # anything unparseable is "could not look"
        *)      printf '%s' "$out" ;;
    esac
    return 0
}

moodle_plugin_version_remote() {
    local ssh_target="$1" ssh_opts="$2" sudo_prefix="$3" root="${4%/}" plugin="$5"
    local remote out
    remote="${sudo_prefix} sed -n 's/.*\\\$plugin->version[[:space:]]*=[[:space:]]*\\([0-9]\\{6,\\}\\).*/\\1/p' '${root}/${plugin}/version.php' 2>/dev/null | head -1"
    remote="$(_md_trim "$remote")"
    out="$(ssh ${ssh_opts} -o BatchMode=yes -o ConnectTimeout=10 "$ssh_target" "$remote" 2>/dev/null || true)"
    out="$(printf '%s' "$out" | tr -dc '0-9')"
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}
