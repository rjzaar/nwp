#!/bin/bash
################################################################################
# lib/restore-remote.sh — the inverse of `pl backup <site> --remote`.
#
# WHY THIS EXISTS
# ---------------
# `pl backup <site> --remote` pulls a verified snapshot of a LIVE host back to
# `sites/<site>/backups/`. Until now nothing put one back. `grep -c 'ssh '
# scripts/commands/restore.sh` returned 0: `pl restore` was a DDEV-local verb
# only. Meanwhile the consolidation-arc rollback registry named
# `pl restore <artifact>` as the reversal command for CP3 and CP16 — the live
# snapshots of nwc and ssc. The DR chain was green only up to "the artifact
# unpacks in a scratch dir"; the leg that actually returns a live site to a
# known-good state did not exist.
#
# SAFETY POSTURE (this is a production-write path)
#   * DRY-RUN BY DEFAULT. --execute is required to touch anything.
#   * VERIFY FIRST. sha256 of every artifact is checked against the manifest and
#     the .sha256 sidecars BEFORE any gate, prompt or remote write. A restore
#     from a corrupt artifact is worse than no restore: it destroys the live
#     state AND does not replace it.
#   * PRE-RESTORE SNAPSHOT. We snapshot the live host and register it as a
#     rollback point before overwriting, so a bad restore is itself reversible.
#   * GATED. pair_guard_restore (ops#83 both-or-forward) then deploy_gate_require
#     (ADR-0028 hardware gate), in the same order as every other prod write.
#   * FATE MANIFEST. lib/impact.sh renders exactly what is overwritten and what
#     is left alone, then requires a typed confirmation.
#   * MAINTENANCE MODE. The site is put into maintenance for the write window
#     and taken out afterwards; a failure leaves it IN maintenance and says so
#     loudly rather than exposing a half-restored site.
#   * NO SECRET ON ARGV. DB credentials are read from the remote's own
#     settings.php/config.php inside a remote subshell, exactly as
#     lib/moodle-deploy.sh does. They never appear in a local process listing.
#
# Requires: lib/ui.sh, lib/common.sh, lib/impact.sh, lib/pair.sh,
#           lib/deploy-gate.sh, lib/rollback.sh, lib/ssh.sh.
################################################################################

# lib/impact.sh is sourced HERE, not by scripts/commands/restore.sh, because the
# fate-manifest calls (impact_overwrite/impact_keep/impact_confirm) live in this
# file. A library declaring its own dependency also keeps restore.sh's status
# honest: restore.sh itself is still the unconverted legacy local-DDEV verb and
# remains on the ops#47 impact-contract allowlist. Sourcing impact.sh from
# restore.sh would have made a string-matching gate believe it was converted.
# shellcheck disable=SC1091
if ! declare -F impact_reset >/dev/null 2>&1; then
    source "$(dirname "${BASH_SOURCE[0]}")/impact.sh"
fi

# --- soft-dep messaging -------------------------------------------------------
if ! declare -F _rr_err >/dev/null 2>&1; then
    _rr_err()  { if command -v print_error   >/dev/null 2>&1; then print_error   "$*"; else printf 'ERROR: %s\n' "$*" >&2; fi; }
    _rr_warn() { if command -v print_warning >/dev/null 2>&1; then print_warning "$*"; else printf 'WARN: %s\n'  "$*" >&2; fi; }
    _rr_info() { if command -v print_info    >/dev/null 2>&1; then print_info    "$*"; else printf '%s\n'        "$*"; fi; }
    _rr_ok()   { if command -v print_status  >/dev/null 2>&1; then print_status "OK" "$*"; else printf 'OK: %s\n' "$*"; fi; }
fi

################################################################################
# Artifact resolution + verification
################################################################################

# Directory holding a site's backups.
# Usage: restore_remote_backup_dir <site> [explicit_artifact]
#
# When the operator names an artifact by PATH, that path wins — it is the least
# surprising behaviour and it is also what makes this verb usable from a
# `pl issue work` worktree, where `sites/` is empty because it is gitignored and
# only materialised in the main checkout.
restore_remote_backup_dir() {
    local site="$1" explicit="${2:-}" d=""

    if [ -n "$explicit" ] && [ "$explicit" != "$(basename "$explicit")" ]; then
        d="$(cd "$(dirname "$explicit")" 2>/dev/null && pwd)" || d=""
        if [ -n "$d" ]; then printf '%s' "$d"; return 0; fi
    fi

    [ -n "${NWP_BACKUP_DIR:-}" ] && { printf '%s' "$NWP_BACKUP_DIR"; return 0; }

    if declare -F get_backup_dir >/dev/null 2>&1; then
        d="$(get_backup_dir "$site" 2>/dev/null || true)"
    fi
    [ -n "$d" ] || d="${PROJECT_ROOT}/sites/${site}/backups"
    printf '%s' "$d"
}

# Resolve the artifact base name (…-remote-<TS>) to restore.
# Usage: restore_remote_resolve_artifact <site> [explicit_name]
restore_remote_resolve_artifact() {
    local site="$1" explicit="${2:-}"
    local dir; dir="$(restore_remote_backup_dir "$site" "$explicit")"

    if [ -n "$explicit" ]; then
        # Accept a bare name, a filename or a full path.
        local b; b="$(basename "$explicit")"
        b="${b%.manifest.json}"; b="${b%.tar.gz}"; b="${b%.sql.gz}"; b="${b%.sha256}"
        printf '%s' "$b"
        return 0
    fi

    local latest
    latest=$(ls -1 "${dir}/${site}-remote-"*.manifest.json 2>/dev/null | sort | tail -1 || true)
    if [ -z "$latest" ]; then
        # Fall back to a sidecar-only (pre-manifest) artifact set.
        latest=$(ls -1 "${dir}/${site}-remote-"*.tar.gz 2>/dev/null | sort | tail -1 || true)
        [ -z "$latest" ] && return 1
        local b; b="$(basename "$latest")"; printf '%s' "${b%.tar.gz}"
        return 0
    fi
    local b; b="$(basename "$latest")"; printf '%s' "${b%.manifest.json}"
}

# Verify one artifact file against its .sha256 sidecar and, when present, the
# manifest's recorded digest. FAIL CLOSED — a missing sidecar on a --remote
# artifact is an error, not a shrug (backup --remote always writes one).
# Usage: _rr_verify_file <path> [expected_sha_from_manifest]
_rr_verify_file() {
    local path="$1" manifest_sha="${2:-}"
    local sidecar="${path}.sha256"

    if [ ! -f "$path" ]; then
        _rr_err "artifact missing: $path"
        return 1
    fi

    local actual
    actual=$(sha256sum "$path" 2>/dev/null | awk '{print $1}')
    if [ -z "$actual" ]; then
        _rr_err "could not compute sha256 for $path"
        return 1
    fi

    local checked=0

    if [ -f "$sidecar" ]; then
        local want
        want=$(awk '{print $1}' "$sidecar" 2>/dev/null | head -1)
        if [ -n "$want" ] && [ "$want" != "$actual" ]; then
            _rr_err "sha256 MISMATCH vs sidecar for $(basename "$path")"
            _rr_err "  sidecar: $want"
            _rr_err "  actual:  $actual"
            return 1
        fi
        [ -n "$want" ] && checked=1
    fi

    if [ -n "$manifest_sha" ]; then
        if [ "$manifest_sha" != "$actual" ]; then
            _rr_err "sha256 MISMATCH vs manifest for $(basename "$path")"
            _rr_err "  manifest: $manifest_sha"
            _rr_err "  actual:   $actual"
            return 1
        fi
        checked=1
    fi

    if [ "$checked" -eq 0 ]; then
        _rr_err "no sha256 sidecar and no manifest digest for $(basename "$path") — refusing."
        _rr_info "A remote artifact without an integrity record cannot be trusted onto a live host."
        _rr_info "If this is a legacy artifact you have independently verified, re-run with"
        _rr_info "NWP_RESTORE_ALLOW_UNVERIFIED=1 (recorded in the fate manifest)."
        [ "${NWP_RESTORE_ALLOW_UNVERIFIED:-0}" = "1" ] || return 1
        _rr_warn "PROCEEDING UNVERIFIED for $(basename "$path") (NWP_RESTORE_ALLOW_UNVERIFIED=1)."
    fi

    _rr_ok "verified $(basename "$path")  ${actual:0:16}…"
    return 0
}

# Read a scalar from the artifact manifest (no yq dependency for JSON).
_rr_manifest_get() {
    local manifest="$1" key="$2"
    [ -f "$manifest" ] || return 1
    grep -m1 "\"${key}\"" "$manifest" 2>/dev/null \
        | sed 's/.*: *"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/' \
        | tr -d ' '
}

################################################################################
# Main
################################################################################

# restore_remote_main <site> [options]
#   --artifact=<name>  restore a specific …-remote-<TS> set (default: latest)
#   --db-only          restore the database only
#   --files-only       restore the webroot only
#   --execute          actually do it (default is a dry run)
#   --tier=<t>         tier being restored (default live)
restore_remote_main() {
    local site="" artifact="" do_db="true" do_files="true"
    local apply="false" tier="live" a

    for a in "$@"; do
        case "$a" in
            --artifact=*) artifact="${a#*=}" ;;
            --db-only)    do_files="false" ;;
            --files-only) do_db="false" ;;
            --execute)    apply="true" ;;
            --dry-run)    apply="false" ;;
            --tier=*)     tier="${a#*=}" ;;
            -*)           _rr_err "unknown option: $a"; return 1 ;;
            *)            [ -z "$site" ] && site="$a" || { _rr_err "unexpected argument: $a"; return 1; } ;;
        esac
    done

    [ -n "$site" ] || { _rr_err "site required"; return 1; }
    if [ "$do_db" = "false" ] && [ "$do_files" = "false" ]; then
        _rr_err "--db-only and --files-only are mutually exclusive"
        return 1
    fi

    local base; base="$(get_base_name "$site" 2>/dev/null || printf '%s' "$site")"

    print_header "Remote restore: ${base}@${tier}"

    # ---- 1. Resolve the artifact ------------------------------------------
    local dir name
    dir="$(restore_remote_backup_dir "$base" "$artifact")"
    if ! name="$(restore_remote_resolve_artifact "$base" "$artifact")" || [ -z "$name" ]; then
        _rr_err "No remote backup artifact found for '${base}' in ${dir}"
        _rr_info "Take one first: pl backup ${base} --remote -y"
        return 1
    fi

    local tarball="${dir}/${name}.tar.gz"
    local dumpfile="${dir}/${name}.sql.gz"
    local manifest="${dir}/${name}.manifest.json"

    _rr_info "Artifact:  ${name}"
    _rr_info "Directory: ${dir}"

    # ---- 2. VERIFY FIRST — before any gate, prompt or remote write --------
    # This ordering is deliberate. Verifying after the confirmation would mean
    # the operator has already authorised a write we then discover we cannot
    # safely perform.
    print_header "Integrity check (before anything else)"
    local m_web_sha="" m_db_sha="" m_type="" m_host=""
    if [ -f "$manifest" ]; then
        m_web_sha="$(_rr_manifest_get "$manifest" webroot_sha256 || true)"
        m_db_sha="$(_rr_manifest_get  "$manifest" db_sha256      || true)"
        m_type="$(_rr_manifest_get    "$manifest" project_type   || true)"
        m_host="$(_rr_manifest_get    "$manifest" remote_host    || true)"
    else
        _rr_warn "no manifest for ${name} — relying on .sha256 sidecars only."
    fi

    if [ "$do_files" = "true" ]; then
        _rr_verify_file "$tarball" "$m_web_sha" || return 1
    fi
    if [ "$do_db" = "true" ]; then
        _rr_verify_file "$dumpfile" "$m_db_sha" || return 1
    fi

    # ---- 3. Resolve the target host ---------------------------------------
    local server_ip remote_path ssh_user project_type sudo_prefix ssh_opts
    local server_name
    server_name=$(get_site_config_value "$base" '.live.server' "" 2>/dev/null || true)
    if [ -n "$server_name" ] && declare -F get_server_config >/dev/null 2>&1; then
        server_ip=$(get_server_config "$server_name" "ip" "" 2>/dev/null || true)
    fi
    [ -z "${server_ip:-}" ] && server_ip=$(get_site_config_value "$base" '.live.server_ip' "" 2>/dev/null || true)

    if [ -z "${server_ip:-}" ]; then
        _rr_err "No live server configured for '${base}' (live.server / live.server_ip empty)."
        _rr_info "Refusing a remote restore with no target — there is nothing to restore ONTO."
        return 1
    fi

    remote_path=$(get_site_config_value "$base" '.live.remote_path' "" 2>/dev/null || true)
    [ -z "$remote_path" ] && remote_path="/var/www/${base}"
    project_type=$(get_site_config_value "$base" '.project.type' "drupal" 2>/dev/null || echo drupal)
    [ -n "$m_type" ] && project_type="$m_type"
    ssh_user=$(get_ssh_user "$base" 2>/dev/null || echo gitlab)
    ssh_opts=$(nwp_ssh_opts "$base" 2>/dev/null || true)
    sudo_prefix=""
    [ "$ssh_user" = "gitlab" ] && sudo_prefix="sudo"

    local ssh_target="${ssh_user}@${server_ip}"
    _rr_info "Target:      ${ssh_target}"
    _rr_info "Remote path: ${remote_path}"
    _rr_info "Site type:   ${project_type}"

    # Cross-check the artifact came from this host — restoring site A's data
    # onto site B is the kind of mistake that has no undo.
    if [ -n "$m_host" ] && [ "$m_host" != "$ssh_target" ]; then
        _rr_err "artifact was taken from '${m_host}' but the configured target is '${ssh_target}'."
        _rr_info "Refusing a cross-host restore. Fix .nwp.yml or pass the right artifact."
        return 1
    fi

    # ---- 4. Fate manifest --------------------------------------------------
    if command -v impact_reset >/dev/null 2>&1; then
        impact_reset
        [ "$do_files" = "true" ] && impact_overwrite "Live webroot ${remote_path}" "extracted from ${name}.tar.gz"
        [ "$do_db" = "true" ]    && impact_overwrite "Live database"               "loaded from ${name}.sql.gz"
        if [ "$project_type" = "moodle" ]; then
            impact_keep "moodledata (live uploads) — outside the artifact scope, never touched"
        else
            impact_keep "sites/default/files (live uploads) — excluded from the artifact, never touched"
        fi
        impact_keep "settings.php / config.php credentials — read on the remote, never transported"
        impact_warn "This overwrites LIVE state at ${ssh_target}."
        [ "${NWP_RESTORE_ALLOW_UNVERIFIED:-0}" = "1" ] && impact_warn "Integrity check was BYPASSED (NWP_RESTORE_ALLOW_UNVERIFIED=1)."
        impact_render
    fi

    # ---- 5. Dry run stops here --------------------------------------------
    if [ "$apply" != "true" ]; then
        _rr_warn "DRY RUN — nothing executed. Plan:"
        echo "    1. snapshot live ${base} and register a rollback point"
        echo "    2. maintenance mode ON"
        [ "$do_files" = "true" ] && echo "    3. upload ${name}.tar.gz → extract into ${remote_path}"
        [ "$do_db" = "true" ]    && echo "    4. upload ${name}.sql.gz → load into the live DB"
        echo "    5. rebuild caches"
        echo "    6. maintenance mode OFF"
        _rr_info "Re-run with --execute (you will be asked to type the artifact timestamp)."
        return 0
    fi

    # ---- 6. Gates (same order as every other prod write) -------------------
    local pg_tier="$tier"; [ "$pg_tier" = "stage" ] && pg_tier="stg"
    if command -v pair_guard_restore >/dev/null 2>&1; then
        pair_guard_restore "$base" "$pg_tier" "restore-remote" \
            "${NWP_RESTORE_ANCHOR:-}" "${PL_OVERRIDE_PAIR:-false}" || return 1
    fi
    if command -v deploy_gate_require >/dev/null 2>&1; then
        deploy_gate_require "$base" "$tier" \
            "restore-remote: overwrite live webroot + DB from ${name}" || return 1
    fi

    # ---- 7. Typed confirmation --------------------------------------------
    local ts="${name##*-remote-}"
    if command -v impact_confirm >/dev/null 2>&1; then
        impact_confirm typed "$ts" "${AUTO_CONFIRM:-false}" || { _rr_err "aborted."; return 1; }
    else
        local c; read -rp "Type the artifact timestamp (${ts}) to confirm: " c
        [ "$c" = "$ts" ] || { _rr_err "confirmation mismatch — aborting."; return 1; }
    fi

    # ---- 8. Pre-restore snapshot (make THIS restore reversible) ------------
    _rr_info "Taking a pre-restore snapshot of the live host…"
    if ! restore_remote_pre_snapshot "$base" "$tier" "$ssh_target" "$ssh_opts" \
            "$sudo_prefix" "$remote_path" "$project_type"; then
        _rr_err "pre-restore snapshot FAILED — refusing to restore."
        _rr_info "A restore with no undo is not a recovery operation. Fix the snapshot path first."
        return 1
    fi

    # ---- 9. Do it ----------------------------------------------------------
    restore_remote_apply "$base" "$ssh_target" "$ssh_opts" "$sudo_prefix" \
        "$remote_path" "$project_type" "$tarball" "$dumpfile" "$do_files" "$do_db"
}

################################################################################
# Pre-restore snapshot — registers a rollback point so the restore is reversible
################################################################################
restore_remote_pre_snapshot() {
    local site="$1" tier="$2" ssh_target="$3" ssh_opts="$4"
    local sudo_prefix="$5" remote_path="$6" project_type="$7"

    local ts; ts=$(date +%Y%m%d-%H%M%S)
    local snap_files="\$HOME/nwp-prerestore-${site}-files-${ts}.tar.gz"
    local snap_db="\$HOME/nwp-prerestore-${site}-db-${ts}.sql.gz"

    # Files.
    if ! ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
        "${sudo_prefix} tar czf ${snap_files} -C '${remote_path}' . 2>/dev/null && ${sudo_prefix} chown \$(id -un):\$(id -gn) ${snap_files}"; then
        _rr_err "could not snapshot the live webroot"
        return 1
    fi

    # DB — credentials resolved on the remote, never transported.
    local dump_script
    if [ "$project_type" = "moodle" ]; then
        dump_script="$(cat <<RS
set -euo pipefail
creds="\$(${sudo_prefix} -u www-data php -r 'define("CLI_SCRIPT",1); define("ABORT_AFTER_CONFIG",1); require \$argv[1]; echo \$CFG->dbname."|".\$CFG->dbuser."|".\$CFG->dbhost."|".\$CFG->dbpass;' '${remote_path%/}/config.php')"
DBN="\${creds%%|*}"; r="\${creds#*|}"; DBU="\${r%%|*}"; r="\${r#*|}"; DBH="\${r%%|*}"; DBP="\${r##*|}"
MYSQL_PWD="\$DBP" mysqldump --no-tablespaces -h "\$DBH" -u "\$DBU" "\$DBN" | gzip > ${snap_db}
RS
)"
    else
        dump_script="$(cat <<RS
set -euo pipefail
cd '${remote_path}'
${sudo_prefix} -u www-data ./vendor/bin/drush sql:dump --gzip > ${snap_db} 2>/dev/null \
  || ${sudo_prefix} -u www-data drush sql:dump --gzip > ${snap_db}
RS
)"
    fi
    if ! printf '%s\n' "$dump_script" | ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "bash -s"; then
        _rr_err "could not snapshot the live database"
        return 1
    fi

    # Register it so `pl rollback list` can see it and `pl rollback execute`
    # can use it. This closes the loop: the restore's own undo is a first-class
    # recovery point, not a path in someone's shell history.
    local host="${ssh_target#*@}" user="${ssh_target%@*}"
    local resolved_files resolved_db
    resolved_files=$(ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "echo ${snap_files}" 2>/dev/null || echo "")
    resolved_db=$(ssh    ${ssh_opts} -o BatchMode=yes "$ssh_target" "echo ${snap_db}"    2>/dev/null || echo "")

    if declare -F rollback_record_remote >/dev/null 2>&1; then
        rollback_record_remote "$site" "$tier" "$user" "$host" "$ts" \
            "$resolved_db" "" "(pre-restore snapshot)" || true
    fi
    _rr_ok "pre-restore snapshot registered (${ts})"
    return 0
}

################################################################################
# The write window
################################################################################
restore_remote_apply() {
    local site="$1" ssh_target="$2" ssh_opts="$3" sudo_prefix="$4"
    local remote_path="$5" project_type="$6" tarball="$7" dumpfile="$8"
    local do_files="$9" do_db="${10}"

    local rc=0
    local remote_tar="/tmp/nwp-restore-$(basename "$tarball")"
    local remote_dump="/tmp/nwp-restore-$(basename "$dumpfile")"

    # --- maintenance ON ---
    _rr_info "Enabling maintenance mode…"
    _rr_maintenance "$ssh_target" "$ssh_opts" "$sudo_prefix" "$remote_path" "$project_type" enable \
        || { _rr_err "could not enable maintenance mode — aborting before any write."; return 1; }

    # --- files ---
    if [ "$do_files" = "true" ]; then
        _rr_info "Uploading webroot artifact…"
        if ! scp ${ssh_opts} "$tarball" "${ssh_target}:${remote_tar}" >/dev/null 2>&1; then
            _rr_err "upload failed — site left in maintenance."
            return 1
        fi
        # Re-verify ON the remote: the bytes that will be extracted are the
        # bytes we verified locally, not merely a file with the same name.
        local want_sha remote_sha
        want_sha=$(sha256sum "$tarball" | awk '{print $1}')
        remote_sha=$(ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "sha256sum '${remote_tar}' | awk '{print \$1}'" 2>/dev/null)
        if [ "$want_sha" != "$remote_sha" ]; then
            _rr_err "uploaded artifact sha256 differs from the local one — refusing to extract."
            ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "rm -f '${remote_tar}'" 2>/dev/null || true
            return 1
        fi
        _rr_info "Extracting into ${remote_path}…"
        if ! ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
            "${sudo_prefix} tar xzf '${remote_tar}' -C '${remote_path%/}' && ${sudo_prefix} rm -f '${remote_tar}'"; then
            _rr_err "extract FAILED — live webroot state indeterminate, site in maintenance. INVESTIGATE."
            return 2
        fi
    fi

    # --- database ---
    if [ "$do_db" = "true" ]; then
        _rr_info "Uploading database dump…"
        if ! scp ${ssh_opts} "$dumpfile" "${ssh_target}:${remote_dump}" >/dev/null 2>&1; then
            _rr_err "dump upload failed — site left in maintenance."
            return 1
        fi
        _rr_info "Loading database…"
        local load_script
        if [ "$project_type" = "moodle" ]; then
            load_script="$(cat <<RS
set -euo pipefail
creds="\$(${sudo_prefix} -u www-data php -r 'define("CLI_SCRIPT",1); define("ABORT_AFTER_CONFIG",1); require \$argv[1]; echo \$CFG->dbname."|".\$CFG->dbuser."|".\$CFG->dbhost."|".\$CFG->dbpass;' '${remote_path%/}/config.php')"
DBN="\${creds%%|*}"; r="\${creds#*|}"; DBU="\${r%%|*}"; r="\${r#*|}"; DBH="\${r%%|*}"; DBP="\${r##*|}"
gunzip -c '${remote_dump}' | MYSQL_PWD="\$DBP" mysql -h "\$DBH" -u "\$DBU" "\$DBN"
rm -f '${remote_dump}'
RS
)"
        else
            load_script="$(cat <<RS
set -euo pipefail
cd '${remote_path}'
gunzip -c '${remote_dump}' | ${sudo_prefix} -u www-data ./vendor/bin/drush sql:cli
rm -f '${remote_dump}'
RS
)"
        fi
        if ! printf '%s\n' "$load_script" | ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" "bash -s"; then
            _rr_err "DB load FAILED — live state indeterminate, site in maintenance. INVESTIGATE."
            _rr_info "Undo: pl rollback execute ${site} <tier>   (the pre-restore point registered above)"
            return 2
        fi
    fi

    # --- caches + maintenance OFF ---
    _rr_info "Rebuilding caches…"
    if [ "$project_type" = "moodle" ]; then
        ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
            "${sudo_prefix} -u www-data php ${remote_path%/}/admin/cli/purge_caches.php" \
            || _rr_warn "purge_caches failed (non-fatal)."
    else
        ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
            "cd '${remote_path}' && ${sudo_prefix} -u www-data ./vendor/bin/drush cr" \
            || _rr_warn "drush cr failed (non-fatal)."
    fi

    _rr_maintenance "$ssh_target" "$ssh_opts" "$sudo_prefix" "$remote_path" "$project_type" disable \
        || _rr_warn "maintenance --disable FAILED — the site is still in maintenance. Clear it: pl moodle maintenance / drush sset."

    _rr_ok "Remote restore complete for ${site}."
    _rr_info "Verify now: pl monitor uptime ${site}"
    return $rc
}

# Maintenance mode for either engine.
_rr_maintenance() {
    local ssh_target="$1" ssh_opts="$2" sudo_prefix="$3" remote_path="$4"
    local project_type="$5" action="$6"

    if [ "$project_type" = "moodle" ]; then
        # Delegate to lib/moodle-deploy.sh when it is loaded (it owns the
        # Moodle maintenance idiom); fall back to the CLI form.
        if declare -F moodle_maintenance >/dev/null 2>&1; then
            moodle_maintenance "$ssh_target" "$ssh_opts" "$sudo_prefix" "php" "$remote_path" "$action" true
            return $?
        fi
        local flag="--enable"; [ "$action" = "disable" ] && flag="--disable"
        ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
            "${sudo_prefix} -u www-data php ${remote_path%/}/admin/cli/maintenance.php ${flag}"
        return $?
    fi

    local val=1; [ "$action" = "disable" ] && val=0
    ssh ${ssh_opts} -o BatchMode=yes "$ssh_target" \
        "cd '${remote_path}' && ${sudo_prefix} -u www-data ./vendor/bin/drush sset system.maintenance_mode ${val}"
}
