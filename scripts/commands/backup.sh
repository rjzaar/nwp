#!/bin/bash
set -euo pipefail

################################################################################
# NWP Backup Script
#
# Backs up DDEV sites (database + files or database only) with pleasy-style naming convention
# Based on pleasy backup.sh adapted for DDEV environments
#
# Usage: ./backup.sh [OPTIONS] <sitename> [message]
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/git.sh"
source "$PROJECT_ROOT/lib/sanitize.sh"
# canonical.sh: canonicality-phase stamping (nwp/ops#33)
source "$PROJECT_ROOT/lib/canonical.sh"
# ssh.sh: get_ssh_user / nwp_ssh_opts for the remote (--remote) pre-deploy
# snapshot path (PL-STG2LIVE-INTEGRATION-DESIGN §6 P0-3).
source "$PROJECT_ROOT/lib/ssh.sh"
# impact.sh: fate manifest + confirm for the remote backup (impact_render /
# impact_confirm). No-op-safe for the local DDEV path.
source "$PROJECT_ROOT/lib/impact.sh"
# files-secrets.sh: files_secrets_verify — a WARNING gate (never an abort) run
# over the tree the local backup tars. Backups must stay FAITHFUL copies, so we
# never scrub them; the gate just says loudly when the archive will carry a
# live credential (files/sync/*.yml, auth.json, .env) so it can be rotated or
# removed at source instead of being discovered in an artifact later.
source "$PROJECT_ROOT/lib/sanitizers/files-secrets.sh"

# Script start time
START_TIME=$(date +%s)

################################################################################
# Script-specific Functions
################################################################################

# Show help
show_help() {
    cat << EOF
${BOLD}NWP Backup Script${NC}

${BOLD}USAGE:${NC}
    ./backup.sh [OPTIONS] <sitename> [message]

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -b, --db-only           Database-only backup (skip files)
    -g, --git               Create supplementary git backup
    -e, --endpoint=NAME     Backup to different endpoint (default: sitename)
    -y, --yes               Skip the confirmation prompt (for --remote)
    --bundle                Create git bundle for offline/archival backup
    --incremental           Create incremental bundle (use with --bundle)
    --push-all              Push to all configured remotes (with -g)
    --sanitize              Sanitize database backup (remove PII)
    --sanitize-level=LEVEL  Sanitization level: basic, full (default: basic)

${BOLD}REMOTE PRE-DEPLOY SNAPSHOT (P0-3):${NC}
    --remote                Snapshot the LIVE site (not the DDEV-local site).
                            Full webroot tar INCLUDING oauth-keys/ + auth.json +
                            the per-env local settings (EXCLUDING files/ +
                            private) plus a
                            DB dump, pulled back to sites/<name>/backups/ with a
                            verified sha256 sidecar each. Read-only against live.
                            REFUSES if no live server is provisioned.
                            The DR-preflight that 'pl cutover' / 'pl moodle
                            deploy' require. Combine with --db-only / --files-only
                            / --dry-run.
    --files-only            (with --remote) snapshot files only, skip the DB
    --dry-run               (with --remote) print the plan; write nothing

${BOLD}ARGUMENTS:${NC}
    sitename                Name of the DDEV site to backup
    message                 Optional backup description (spaces converted to underscores)

${BOLD}SUBCOMMANDS:${NC}
    sweep                   Sweep all sites: back up any with stale/missing
                            backups (see: ./backup.sh sweep --help)
    prune                   Delete local backups older than the retention
                            window (default 30d; keeps newest per site;
                            see: ./backup.sh prune --help)

${BOLD}EXAMPLES:${NC}
    ./backup.sh nwp                              # Backup 'nwp' site (full)
    ./backup.sh -b nwp                           # Database-only backup
    ./backup.sh nwp 'Fixed error'                # Backup with message
    ./backup.sh -b nwp 'Before update'           # DB-only backup with message
    ./backup.sh -e=nwp_backup nwp 'Test backup'  # Backup to different endpoint
    ./backup.sh -bd nwp                          # DB-only backup with debug output
    ./backup.sh --bundle nwp                     # Create git bundle (full)
    ./backup.sh --bundle --incremental nwp       # Create incremental bundle
    ./backup.sh -g --push-all nwp                # Push to all remotes
    ./backup.sh --sanitize nwp                   # Sanitized backup (GDPR)
    ./backup.sh nwc --remote --dry-run           # Preview a live pre-deploy snapshot
    ./backup.sh nwc --remote -y                  # Full live pre-deploy snapshot (P0-3)
    ./backup.sh ssc --remote --db-only -y        # Live Moodle DB-only snapshot

${BOLD}COMBINED FLAGS:${NC}
    Multiple short flags can be combined: -bd = -b -d
    Example: ./backup.sh -bd nwp is the same as ./backup.sh -b -d nwp

${BOLD}OUTPUT:${NC}
    Backups are stored in: sites/<sitename>/backups/
    (Legacy location sitebackups/<sitename>/ is still honored for unmigrated sites.)

    Naming convention: YYYYMMDDTHHmmss-branch-commit-message.{sql.gz,tar.gz}
    Example: 20241221T143022-main-a1b2c3d4-fixed_error.sql.gz

${BOLD}FILES CREATED:${NC}
    - Database backup (.sql.gz, gzip compressed)
    - Files backup (.tar.gz)

EOF
}

################################################################################
# Backup Functions
################################################################################

# Get git information for backup naming
get_git_info() {
    local site_dir=$1

    if [ -d "$site_dir/.git" ]; then
        cd "$site_dir" || return 1

        # Get current branch
        local branch=$(git branch 2>/dev/null | grep \* | cut -d ' ' -f2)
        if [ -z "$branch" ]; then
            branch="no-branch"
        fi
        # Slashed branches (feat/foo) would put a subdirectory in the
        # backup filename and break ddev export-db.
        branch="${branch//\//-}"

        # Get commit hash (first 8 characters)
        local commit=$(git rev-parse HEAD 2>/dev/null | cut -c 1-8)
        if [ -z "$commit" ]; then
            commit="no-commit"
        fi

        echo "${branch}-${commit}"
    else
        echo "no-git-no-git"
    fi
}

# Create backup name following pleasy convention
create_backup_name() {
    local site_dir=$1
    local message=$2

    # Timestamp: YYYYMMDDTHHmmss
    local timestamp=$(date +%Y%m%dT%H%M%S)

    # Git info: branch-commit
    local git_info=$(get_git_info "$site_dir")

    # Message: convert spaces to underscores, remove special characters
    local msg_clean=""
    if [ -n "$message" ]; then
        msg_clean=$(echo "$message" | tr ' ' '_' | tr -cd '[:alnum:]_-')
        msg_clean="-${msg_clean}"
    fi

    # Construct name
    echo "${timestamp}-${git_info}${msg_clean}"
}

# Backup database
backup_database() {
    local site_dir=$1
    local backup_dir=$2
    local backup_name=$3

    print_header "Backing Up Database"

    # Use absolute path for backup directory
    local abs_backup_dir=$(cd "$(dirname "$backup_dir")" && pwd)/$(basename "$backup_dir")
    local db_file="${abs_backup_dir}/${backup_name}.sql.gz"

    ocmsg "Exporting database to: $db_file"

    # Change to site directory
    local original_dir=$(pwd)
    cd "$site_dir" || {
        print_error "Site directory not found: $site_dir"
        return 1
    }

    # Export database using DDEV with gzip compression
    local temp_file=".ddev/${backup_name}.sql.gz"
    start_spinner "Exporting database..."
    if ddev export-db --file="$temp_file" --gzip > /dev/null 2>&1; then
        stop_spinner
        # Move from .ddev to backup directory
        if [ -f "$temp_file" ]; then
            mv "$temp_file" "$db_file"
            print_status "OK" "Database backed up: $(basename "$db_file")"

            # Show file size
            local size=$(du -h "$db_file" | cut -f1)
            ocmsg "Database backup size: $size"
        else
            print_error "Database export file not found at: $temp_file"
            cd "$original_dir"
            return 1
        fi
    else
        stop_spinner
        print_error "Failed to export database"
        cd "$original_dir"
        return 1
    fi

    cd "$original_dir"
    return 0
}

# Backup files
backup_files() {
    local site_dir=$1
    local backup_dir=$2
    local backup_name=$3
    local webroot=$4

    print_header "Backing Up Files"

    # Use absolute path for backup directory
    local abs_backup_dir=$(cd "$(dirname "$backup_dir")" && pwd)/$(basename "$backup_dir")
    local files_archive="${abs_backup_dir}/${backup_name}.tar.gz"

    ocmsg "Creating file archive: $files_archive"

    # Check if site directory exists
    if [ ! -d "$site_dir" ]; then
        print_error "Site directory not found: $site_dir"
        return 1
    fi

    # Determine what to backup (webroot + other important dirs)
    # SECURITY FIX: Use array to properly handle paths (prevents word splitting issues)
    local -a backup_paths=()

    if [ -d "$site_dir/$webroot" ]; then
        backup_paths+=("$webroot")
    fi

    if [ -d "$site_dir/private" ]; then
        backup_paths+=("private")
    fi

    if [ -d "$site_dir/cmi" ]; then
        backup_paths+=("cmi")
    fi

    if [ -f "$site_dir/composer.json" ]; then
        backup_paths+=("composer.json")
        if [ -f "$site_dir/composer.lock" ]; then
            backup_paths+=("composer.lock")
        fi
    fi

    if [ ${#backup_paths[@]} -eq 0 ]; then
        print_error "No files found to backup"
        return 1
    fi

    ocmsg "Backing up: ${backup_paths[*]}"

    # Leftover-secret WARNING gate (never an abort): a backup is a FAITHFUL copy
    # by design, so nothing is scrubbed here — but if the tree being tarred
    # carries a live credential (files/sync/*.yml, auth.json, .env — the
    # lib/sanitizers/files-secrets.sh vocabulary), the operator must hear about
    # it NOW, not when the archive leaks later. Scoped to the paths that
    # actually enter the archive, so it never warns about files outside it.
    local bp fs_out
    for bp in "${backup_paths[@]}"; do
        [ -d "$site_dir/$bp" ] || continue
        if ! fs_out="$(files_secrets_verify "$site_dir/$bp" 2>&1)"; then
            print_warning "Live-secret-shaped value(s) under '$bp' — the backup archive WILL contain them (backups stay faithful; not scrubbed). Rotate/remove at source:"
            [ -n "$fs_out" ] && printf '%s\n' "$fs_out" | sed 's/^/    /'
        fi
    done

    # Create tar.gz archive (suppress "Removing leading" warnings)
    # SECURITY FIX: Use array expansion "${backup_paths[@]}" to properly quote each path
    start_spinner "Creating archive..."
    tar -czf "$files_archive" -C "$site_dir" "${backup_paths[@]}" 2>&1 | grep -v "Removing leading" || true
    stop_spinner

    # Check if archive was created successfully
    if [ -f "$files_archive" ] && [ -s "$files_archive" ]; then
        print_status "OK" "Files backed up: $(basename "$files_archive")"

        # Show file size
        local size=$(du -h "$files_archive" | cut -f1)
        ocmsg "Files backup size: $size"

        return 0
    else
        print_error "Failed to create file archive"
        return 1
    fi
}

# Write a sidecar manifest next to the backup artifacts (nwp/ops#33).
# Records the canonical phase the backup was taken under plus the code
# anchors (git branch/commit, composer.lock sha256) so a restore/build can
# match a content snapshot to the code that produced it (P65 item 4 is the
# runtime counterpart).
write_backup_manifest() {
    local site_dir=$1
    local backup_dir=$2
    local backup_name=$3
    local sitename=$4
    local endpoint=$5
    local db_only=$6
    local sanitized=$7

    local abs_backup_dir=$(cd "$(dirname "$backup_dir")" && pwd)/$(basename "$backup_dir")
    local manifest="${abs_backup_dir}/${backup_name}.manifest.json"

    local git_branch="" git_commit=""
    if [ -d "$site_dir/.git" ]; then
        git_branch=$(git -C "$site_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
        git_commit=$(git -C "$site_dir" rev-parse HEAD 2>/dev/null || true)
    fi
    local lock_sha=""
    if [ -f "$site_dir/composer.lock" ]; then
        lock_sha=$(sha256sum "$site_dir/composer.lock" 2>/dev/null | awk '{print $1}')
    fi

    {
        printf '{\n'
        printf '  "site": "%s",\n' "$sitename"
        printf '  "endpoint": "%s",\n' "$endpoint"
        printf '  "backup_name": "%s",\n' "$backup_name"
        printf '  "canonical_phase": "%s",\n' "$(canonical_get_phase "$sitename")"
        printf '  "created": "%s",\n' "$(date -u +%FT%TZ)"
        printf '  "by": "%s",\n' "$(canonical_actor)"
        printf '  "git_branch": "%s",\n' "$git_branch"
        printf '  "git_commit": "%s",\n' "$git_commit"
        printf '  "composer_lock_sha256": "%s",\n' "$lock_sha"
        printf '  "db_only": %s,\n' "$db_only"
        printf '  "sanitized": %s\n' "$sanitized"
        printf '}\n'
    } > "$manifest"

    echo "$manifest"
}

################################################################################
# Remote pre-deploy backup — `pl backup <site> --remote`
#
# PL-STG2LIVE-INTEGRATION-DESIGN-2026-07-19 §6 P0-3. The local backup_site()
# path is DDEV-local only; it cannot snapshot a remote LIVE site. This is the
# guarded pre-deploy DR snapshot that `pl cutover` and `pl moodle deploy`
# require before any destructive live change.
#
# Unlike the DDEV path it:
#   - skips resolve_project / DDEV entirely;
#   - resolves the live target via get_live_config + get_ssh_user (REFUSES if
#     server_ip is empty — no provisioned live host to back up);
#   - captures a FULL pre-deploy snapshot: the remote webroot tar INCLUDING
#     oauth-keys/ + auth.json + the per-env local settings (the whole point of a
#     pre-deploy backup — §3.4/INV-2) but EXCLUDING the huge uploads
#     (<webroot>/sites/default/files + private), plus a remote DB dump;
#   - pulls both artifacts back with a sha256 sidecar, verified fail-closed;
#   - is read-only against live (honours live.enabled; NO deploy_gate_require
#     — it never writes site state).
################################################################################

# Get live server config (borrowed verbatim from stg2live.sh:72-96 so the
# backup and the deploy resolve the identical live target from the same
# per-site .nwp.yml). Kept local to avoid sourcing a command script.
backup_get_live_config() {
    local sitename="$1"
    local field="$2"
    local base
    base=$(get_base_name "$sitename")

    local yq_path
    case "$field" in
        server_ip)
            local server_name
            server_name=$(get_site_config_value "$base" '.live.server' "")
            if [[ -n "$server_name" ]] && declare -F get_server_config &>/dev/null; then
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
        enabled)     yq_path='.live.enabled' ;;
        *)           yq_path=".live.$field" ;;
    esac
    get_site_config_value "$base" "$yq_path" ""
}

# Sibling manifest for a remote snapshot. Carries the extra provenance the
# local manifest lacks: remote:true + remote_host + per-artifact sha256s +
# taken_at, so a restore can bind the pulled artifacts to the live host and
# verify integrity independently of the sidecars (P0-3).
write_remote_backup_manifest() {
    local backup_dir="$1"
    local backup_name="$2"
    local sitename="$3"
    local endpoint="$4"
    local remote_host="$5"
    local project_type="$6"
    local db_only="$7"
    local files_only="$8"
    local webroot_sha256="$9"
    local db_sha256="${10}"
    local taken_at="${11}"

    local abs_backup_dir
    abs_backup_dir=$(cd "$(dirname "$backup_dir")" && pwd)/$(basename "$backup_dir")
    local manifest="${abs_backup_dir}/${backup_name}.manifest.json"

    {
        printf '{\n'
        printf '  "site": "%s",\n' "$sitename"
        printf '  "endpoint": "%s",\n' "$endpoint"
        printf '  "backup_name": "%s",\n' "$backup_name"
        printf '  "remote": true,\n'
        printf '  "remote_host": "%s",\n' "$remote_host"
        printf '  "project_type": "%s",\n' "$project_type"
        printf '  "canonical_phase": "%s",\n' "$(canonical_get_phase "$sitename")"
        printf '  "created": "%s",\n' "$(date -u +%FT%TZ)"
        printf '  "taken_at": "%s",\n' "$taken_at"
        printf '  "by": "%s",\n' "$(canonical_actor)"
        printf '  "db_only": %s,\n' "$db_only"
        printf '  "files_only": %s,\n' "$files_only"
        printf '  "webroot_sha256": "%s",\n' "$webroot_sha256"
        printf '  "db_sha256": "%s"\n' "$db_sha256"
        printf '}\n'
    } > "$manifest"

    echo "$manifest"
}

# Detect the remote docroot under remote_path (html | web | "" for root-served
# Moodle). Mirrors the auto-detect in stg2live.sh:659-667 so the exclude paths
# line up with the real live layout instead of a guess.
backup_remote_webroot() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    local remote_path="$4"
    local sudo_prefix="$5"

    if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "$sudo_prefix test -d ${remote_path}/web" 2>/dev/null; then
        echo "web"
    elif ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "$sudo_prefix test -d ${remote_path}/html" 2>/dev/null; then
        echo "html"
    else
        echo ""
    fi
}

# Compute a remote artifact's sha256, pull it back, re-verify locally, and
# write a .sha256 sidecar. Fail-closed on any mismatch (P0-3: "compute sha on
# the remote, pull, re-verify locally, compare — fail-closed on mismatch").
# Echoes the verified sha256 on success; returns 1 on any failure.
backup_pull_verified() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    local remote_file="$4"     # path relative to remote ~ (home)
    local local_path="$5"      # destination path on this box

    # 1. Authoritative sha computed on the remote host.
    local remote_sha
    remote_sha=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "sha256sum ~/${remote_file} 2>/dev/null | awk '{print \$1}'" 2>/dev/null)
    if [ -z "$remote_sha" ]; then
        print_error "Could not compute remote sha256 for ~/${remote_file}" >&2
        return 1
    fi

    # 2. Pull the artifact back.
    if ! scp $(nwp_ssh_opts "$base_name") -o BatchMode=yes \
        "${ssh_user}@${server_ip}:${remote_file}" "$local_path" >/dev/null 2>&1; then
        print_error "Failed to pull ~/${remote_file} from live host" >&2
        return 1
    fi

    # 3. Re-verify locally and compare — fail-closed on mismatch.
    local local_sha
    local_sha=$(sha256sum "$local_path" 2>/dev/null | awk '{print $1}')
    if [ "$local_sha" != "$remote_sha" ]; then
        print_error "sha256 MISMATCH for $(basename "$local_path") (remote=$remote_sha local=$local_sha) — backup is corrupt, removing." >&2
        rm -f "$local_path"
        return 1
    fi

    # 4. Sidecar. Format matches `sha256sum` so `sha256sum -c` works.
    printf '%s  %s\n' "$local_sha" "$(basename "$local_path")" > "${local_path}.sha256"

    echo "$local_sha"
    return 0
}

# Remote pre-deploy backup entry point.
backup_remote() {
    local sitename="$1"
    local endpoint="$2"
    local db_only="${3:-false}"
    local files_only="${4:-false}"
    local dry_run="${5:-false}"
    local auto_confirm="${6:-false}"

    local base_name
    base_name=$(get_base_name "$sitename")

    print_header "NWP Remote Pre-Deploy Backup: $base_name"

    # Honour live.enabled (a read-only backup still respects the operator's
    # intent to leave a site alone). Only an explicit false blocks it.
    local live_enabled
    live_enabled=$(backup_get_live_config "$base_name" "enabled")
    if [ "$live_enabled" == "false" ]; then
        print_error "Live deployment disabled for '$base_name' (live.enabled: false in sites/$base_name/.nwp.yml)"
        return 1
    fi

    # Resolve the live target. REFUSE if no server_ip — there is no
    # provisioned live host to snapshot (P0-3).
    local server_ip remote_path domain ssh_user project_type
    server_ip=$(backup_get_live_config "$base_name" "server_ip")
    if [ -z "$server_ip" ]; then
        print_error "No live server configured for '$base_name' (live.server_ip is empty)."
        print_info "Refusing --remote backup: nothing to snapshot. Provision live first (pl live $base_name)."
        return 1
    fi
    remote_path=$(backup_get_live_config "$base_name" "remote_path")
    [ -z "$remote_path" ] && remote_path="/var/www/${base_name}"
    domain=$(backup_get_live_config "$base_name" "domain")
    ssh_user=$(get_ssh_user "$base_name")
    project_type=$(get_site_config_value "$base_name" '.project.type' "drupal")

    # sudo idiom (stg2live): the gitlab ssh user runs privileged remote ops
    # via sudo; a direct root user does not.
    local sudo_prefix=""
    local drush_sudo=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo"
        drush_sudo="sudo -u www-data"
    fi

    print_info "Live host:   ${ssh_user}@${server_ip}"
    print_info "Remote path: ${remote_path}"
    print_info "Site type:   ${project_type}"
    [ -n "$domain" ] && print_info "Domain:      https://${domain}"

    # SSH reachability check (read-only).
    if ! ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes -o ConnectTimeout=5 \
        "${ssh_user}@${server_ip}" "echo ok" >/dev/null 2>&1; then
        print_error "Cannot connect to live server: ${ssh_user}@${server_ip}"
        return 1
    fi

    # Disk gate — fail-closed (NOT the WARN-and-continue of live_host_snapshot;
    # a pre-deploy backup that silently produced nothing would be worse than
    # useless). Need ~1GB headroom in ~ for the tar + dump.
    local free_kb
    free_kb=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "df -k --output=avail ~ | tail -1" 2>/dev/null | tr -d ' ')
    if [ -n "$free_kb" ] && [ "$free_kb" -lt 1048576 ]; then
        print_error "Live host has <1GB free in ~ (${free_kb}KB) — refusing remote backup (fail-closed)."
        print_info "Free disk on the live host before taking a pre-deploy snapshot."
        return 1
    fi

    # Resolve the remote docroot so the Drupal uploads-exclude paths line up.
    local webroot=""
    if [ "$project_type" != "moodle" ]; then
        webroot=$(backup_remote_webroot "$base_name" "$server_ip" "$ssh_user" "$remote_path" "$sudo_prefix")
    fi

    local ts backup_name
    ts=$(date +%Y%m%dT%H%M%S)
    backup_name="${base_name}-remote-${ts}"

    local do_files="true" do_db="true"
    [ "$db_only" == "true" ] && do_files="false"
    [ "$files_only" == "true" ] && do_db="false"

    # Build the tar exclude list. KEEP oauth-keys/ + auth.json + the per-env local settings
    # (they are the point of a pre-deploy backup); DROP the huge uploads.
    # NB: the local-path files-secrets WARNING gate is deliberately NOT applied
    # here — the tar runs ON the live host (no lib there), sites/default/files
    # is excluded (so files/sync never enters this artifact), and auth.json is
    # kept BY DESIGN: a pre-deploy snapshot exists to restore live exactly.
    local -a tar_excludes=()
    if [ "$project_type" != "moodle" ]; then
        if [ -n "$webroot" ]; then
            tar_excludes+=("--exclude=./${webroot}/sites/default/files")
        else
            tar_excludes+=("--exclude=./sites/default/files")
        fi
        tar_excludes+=("--exclude=./private")
    fi
    # (Moodle: moodledata lives OUTSIDE remote_path, so the -C scope excludes
    # it structurally — nothing extra to add.)

    local backup_base
    backup_base=$(get_backup_dir "$endpoint")

    # IMPACT fate manifest (unconditional; the prompt is what -y skips).
    impact_reset
    if [ "$do_files" == "true" ]; then
        impact_archive "Live files" "tar of ${remote_path} (incl. oauth-keys/, auth.json, local settings; excl. files/ + private) → ${backup_base}/${backup_name}.tar.gz (+.sha256)"
    fi
    if [ "$do_db" == "true" ]; then
        impact_archive "Live DB" "${project_type} dump → ${backup_base}/${backup_name}.sql.gz (+.sha256)"
    fi
    impact_keep "Live site https://${domain:-$server_ip} — DB, uploads and signing keys are READ ONLY; nothing on live is modified or deleted"
    impact_warn "Writes temp artifacts to ${ssh_user}@${server_ip}:~ then pulls + removes them"
    impact_render

    if [ "$dry_run" == "true" ]; then
        print_header "[dry-run] Remote backup plan"
        if [ "$do_files" == "true" ]; then
            echo "  would run on live:  ${sudo_prefix} tar czf ~/${backup_name}.tar.gz ${tar_excludes[*]} -C ${remote_path} ."
        fi
        if [ "$do_db" == "true" ]; then
            if [ "$project_type" == "moodle" ]; then
                echo "  would run on live:  ${sudo_prefix} mysqldump <dbname-from-config.php> | gzip > ~/${backup_name}.sql.gz"
            else
                echo "  would run on live:  cd ${remote_path} && ${drush_sudo} drush sql:dump --gzip > ~/${backup_name}.sql.gz"
            fi
        fi
        echo "  would pull both to: ${backup_base}/ with a verified .sha256 sidecar each"
        echo "  would write:        ${backup_base}/${backup_name}.manifest.json (remote:true)"
        print_status "OK" "Dry run complete; nothing written remote or local."
        return 0
    fi

    # Confirm (standard tier — a backup keeps a recovery path; nothing is
    # destroyed). Fail-closed with no TTY unless -y.
    if ! impact_confirm standard "take a remote pre-deploy backup of '${base_name}' (live ${server_ip})" "$auto_confirm"; then
        print_info "Aborted."
        return 1
    fi

    mkdir -p "$backup_base"

    local webroot_sha="" db_sha=""

    # ---- FILES ----------------------------------------------------------
    if [ "$do_files" == "true" ]; then
        print_header "Snapshotting Live Files"
        local excl_str=""
        local e
        for e in "${tar_excludes[@]}"; do
            excl_str+=" $e"
        done
        # tar as root/sudo so oauth-keys (0600 www-data) + the local settings
        # are readable; chown the artifact back to the ssh user so scp can
        # pull it without sudo.
        if ! ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
            "${sudo_prefix} tar czf ~/${backup_name}.tar.gz${excl_str} -C ${remote_path} . 2>/dev/null && ${sudo_prefix} chown ${ssh_user}:${ssh_user} ~/${backup_name}.tar.gz"; then
            print_error "Remote files tar failed"
            return 1
        fi
        print_status "OK" "Files tarred on live host"

        if ! webroot_sha=$(backup_pull_verified "$base_name" "$server_ip" "$ssh_user" \
            "${backup_name}.tar.gz" "${backup_base}/${backup_name}.tar.gz"); then
            print_error "Files artifact verification failed — aborting backup."
            ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
                "rm -f ~/${backup_name}.tar.gz" 2>/dev/null || true
            return 1
        fi
        print_status "OK" "Files pulled + sha256 verified: ${backup_name}.tar.gz"

        # Clean up the remote temp artifact.
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
            "rm -f ~/${backup_name}.tar.gz" 2>/dev/null || true
    fi

    # ---- DATABASE -------------------------------------------------------
    if [ "$do_db" == "true" ]; then
        print_header "Snapshotting Live Database"
        if [ "$project_type" == "moodle" ]; then
            # Read $CFG->dbname WITHOUT bootstrapping Moodle (ABORT_AFTER_CONFIG,
            # same idiom as lib/sanitizers/moodle.sh). config.php is
            # r--r----- www-data, so read it AS www-data. dbname is not a
            # secret; the dump itself runs via credential-free root-socket
            # mysqldump (the live_host_snapshot idiom) so no password is ever
            # read into the pipeline.
            local mdl_dbname
            mdl_dbname=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
                "${drush_sudo} php -d error_reporting=0 -d display_errors=0 -r 'define(\"CLI_SCRIPT\",true);define(\"ABORT_AFTER_CONFIG\",true);require(\$argv[1]);echo isset(\$CFG->dbname)?\$CFG->dbname:\"\";' ${remote_path}/config.php" 2>/dev/null)
            if [ -z "$mdl_dbname" ]; then
                print_error "Could not read \$CFG->dbname from ${remote_path}/config.php on live — refusing to guess the Moodle DB name."
                return 1
            fi
            if ! ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
                "${sudo_prefix} mysqldump --single-transaction --quick --routines --triggers ${mdl_dbname} 2>/dev/null | gzip > ~/${backup_name}.sql.gz"; then
                print_error "Remote Moodle mysqldump failed"
                return 1
            fi
        else
            # Drupal: drush sql:dump as www-data. Try the project root, then
            # the webroot/../vendor/bin/drush fallback (stg2live:1297-1298).
            if ! ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
                "cd ${remote_path} && ${drush_sudo} drush sql:dump --gzip 2>/dev/null > ~/${backup_name}.sql.gz" 2>/dev/null; then
                if ! ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
                    "cd ${remote_path}/${webroot:-html} && ${drush_sudo} ../vendor/bin/drush sql:dump --gzip 2>/dev/null > ~/${backup_name}.sql.gz" 2>/dev/null; then
                    print_error "Remote Drupal drush sql:dump failed (tried ${remote_path} and ${remote_path}/${webroot:-html}/../vendor/bin/drush)"
                    return 1
                fi
            fi
        fi
        print_status "OK" "Database dumped on live host"

        if ! db_sha=$(backup_pull_verified "$base_name" "$server_ip" "$ssh_user" \
            "${backup_name}.sql.gz" "${backup_base}/${backup_name}.sql.gz"); then
            print_error "DB artifact verification failed — aborting backup."
            ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
                "rm -f ~/${backup_name}.sql.gz" 2>/dev/null || true
            return 1
        fi
        print_status "OK" "Database pulled + sha256 verified: ${backup_name}.sql.gz"

        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
            "rm -f ~/${backup_name}.sql.gz" 2>/dev/null || true
    fi

    # ---- MANIFEST -------------------------------------------------------
    local taken_at
    taken_at=$(date -u +%FT%TZ)
    local manifest_file
    manifest_file=$(write_remote_backup_manifest "$backup_base" "$backup_name" \
        "$base_name" "$endpoint" "${ssh_user}@${server_ip}" "$project_type" \
        "$db_only" "$files_only" "$webroot_sha" "$db_sha" "$taken_at" 2>/dev/null) || true

    print_header "Remote Backup Summary"
    if [ "$do_files" == "true" ]; then
        echo -e "${GREEN}✓${NC} Files:    ${backup_base}/${backup_name}.tar.gz (+.sha256)"
    fi
    if [ "$do_db" == "true" ]; then
        echo -e "${GREEN}✓${NC} Database: ${backup_base}/${backup_name}.sql.gz (+.sha256)"
    fi
    if [ -n "$manifest_file" ]; then
        echo -e "${GREEN}✓${NC} Manifest: ${manifest_file} (remote:true, host ${server_ip})"
    fi
    return 0
}

# Main backup function
backup_site() {
    local sitename=$1
    local endpoint=$2
    local message=$3
    local db_only=${4:-false}
    local git_backup=${5:-false}
    local bundle=${6:-false}
    local incremental=${7:-false}
    local push_all=${8:-false}
    local sanitize=${9:-false}
    local sanitize_level=${10:-basic}

    # Clean up spinner on exit/error
    trap 'stop_spinner' EXIT INT TERM

    if [ "$db_only" == "true" ]; then
        print_header "NWP Database Backup: $sitename"
    else
        print_header "NWP Site Backup: $sitename"
    fi

    # Resolve the DDEV project dir: v2 layout keeps it under
    # sites/<name>/dev/, v1 is the flat sites/<name>/ (resolve_project
    # handles both, plus explicit paths like <name>/stg).
    local site_dir
    if ! site_dir=$(resolve_project "$sitename"); then
        print_error "Site not found: $sitename"
        echo "Looked under: ${NWP_DIR:-${PROJECT_ROOT:-$HOME/nwp}}/sites/"
        return 1
    fi

    # Check if DDEV is configured
    if [ ! -f "$site_dir/.ddev/config.yaml" ]; then
        print_error "DDEV not configured in $site_dir"
        return 1
    fi

    # Get webroot from DDEV config
    local webroot=$(grep "^docroot:" "$site_dir/.ddev/config.yaml" 2>/dev/null | awk '{print $2}')
    if [ -z "$webroot" ]; then
        webroot="web"  # Default fallback
    fi

    ocmsg "Using webroot: $webroot"

    # Create backup directory structure
    # F23 Phase 4: prefer sites/<name>/backups/, fall back to legacy sitebackups/<name>/
    local backup_base
    backup_base=$(get_backup_dir "$endpoint")
    if [ ! -d "$backup_base" ]; then
        mkdir -p "$backup_base"
        print_status "OK" "Created backup directory: $backup_base"
    fi

    # Generate backup name
    local backup_name=$(create_backup_name "$site_dir" "$message")

    print_info "Backup name: ${BOLD}$backup_name${NC}"
    print_info "Backup location: ${BOLD}$backup_base${NC}"

    # Backup database
    if ! backup_database "$site_dir" "$backup_base" "$backup_name"; then
        print_error "Database backup failed"
        return 1
    fi

    # Backup files (skip if database-only)
    if [ "$db_only" != "true" ]; then
        if ! backup_files "$site_dir" "$backup_base" "$backup_name" "$webroot"; then
            print_error "Files backup failed"
            return 1
        fi
    fi

    # Sanitize database backup if requested
    if [ "$sanitize" == "true" ]; then
        local sql_gz_file="${backup_base}/${backup_name}.sql.gz"
        if [ -f "$sql_gz_file" ]; then
            # Decompress, sanitize, recompress
            gunzip "$sql_gz_file"
            local sql_file="${backup_base}/${backup_name}.sql"
            sanitize_database "$site_dir" "$sql_file" "$sanitize_level"
            gzip "$sql_file"
            echo -e "${GREEN}✓${NC} Sanitized: Level $sanitize_level"
        fi
    fi

    # Sidecar manifest with the canonical phase + code anchors (nwp/ops#33)
    local manifest_file
    manifest_file=$(write_backup_manifest "$site_dir" "$backup_base" "$backup_name" \
        "$sitename" "$endpoint" "$db_only" "$sanitize" 2>/dev/null) || true

    # Summary
    print_header "Backup Summary"
    echo -e "${GREEN}✓${NC} Database: ${backup_base}/${backup_name}.sql.gz"
    if [ "$db_only" != "true" ]; then
        echo -e "${GREEN}✓${NC} Files:    ${backup_base}/${backup_name}.tar.gz"
    fi
    if [ -n "$manifest_file" ]; then
        echo -e "${GREEN}✓${NC} Manifest: ${manifest_file} (canonical: $(canonical_get_phase "$sitename"))"
    fi

    # Determine backup type for git operations
    local backup_type="db"
    if [ "$db_only" != "true" ]; then
        backup_type="files"
    fi

    # Git backup if requested
    if [ "$git_backup" == "true" ]; then
        local commit_msg="Backup: $backup_name"
        if [ -n "$message" ]; then
            commit_msg="$message ($backup_name)"
        fi

        if git_backup "$backup_base" "$endpoint" "$backup_type" "$commit_msg"; then
            echo -e "${GREEN}✓${NC} Git:      Committed and pushed to GitLab"

            # Push to additional remotes if requested
            if [ "$push_all" == "true" ]; then
                print_info "Pushing to additional remotes..."
                git_push_all "$backup_base" "backup" "${endpoint}-${backup_type}" "backups"
            fi
        else
            print_warning "Git backup completed with warnings"
        fi
    fi

    # Bundle backup if requested
    if [ "$bundle" == "true" ]; then
        if git_bundle_backup "$backup_base" "$endpoint" "$backup_type" "$incremental"; then
            echo -e "${GREEN}✓${NC} Bundle:   Created offline backup bundle"
        else
            print_warning "Bundle creation completed with warnings"
        fi
    fi

    return 0
}

################################################################################
# Sweep (nwp/ops#87 Part A) — self-driving backups
#
# `pl backup sweep` iterates every discovered site and backs up any whose
# newest backup is older than settings.todo.thresholds.backup_warn_days
# (default 7 — the SAME threshold and directory logic as
# check_missing_backups in lib/todo-checks.sh, so sweep and `pl todo`/
# `pl rag` always agree on what "stale" means).
################################################################################

show_sweep_help() {
    cat << EOF
${BOLD}NWP Backup Sweep${NC}

Back up every site whose newest backup is stale or missing.

${BOLD}USAGE:${NC}
    ./backup.sh sweep [OPTIONS]

${BOLD}OPTIONS:${NC}
    -h, --help          Show this help message
    --dry-run           List the decision for each site; take no backups
    --start-stopped     Start stopped DDEV projects, back up, stop them again
    --site NAME         Sweep a single site (for testing)

${BOLD}BEHAVIOR:${NC}
    - Freshness threshold: settings.todo.thresholds.backup_warn_days
      (default 7) — identical to the 'pl todo' missing-backups check.
    - Sweep backups are database-only (-b) with message "sweep automated backup".
    - Sites whose DDEV project is not running are skipped unless
      --start-stopped is given (prior stopped state is restored afterwards).
    - Sites without a dev DDEV project are noted and skipped.

${BOLD}SCHEDULING:${NC}
    pl schedule install-sweep       # nightly cron (default 0 2 * * *)

EOF
}

# Epoch mtime of the newest backup artifact for a site, or fail if none.
# Mirrors check_missing_backups in lib/todo-checks.sh exactly:
# candidates are <site-dir>/backups then \$ROOT/backups/<site>, and only
# *.sql.gz / *.tar.gz files count.
sweep_latest_backup_epoch() {
    local site="$1"
    local root="${NWP_DIR:-$PROJECT_ROOT}"

    local backup_dir="$root/sites/$site/backups"
    if [ ! -d "$backup_dir" ]; then
        backup_dir="$root/backups/$site"
    fi
    [ -d "$backup_dir" ] || return 1

    local latest
    latest=$(find "$backup_dir" -type f \( -name "*.sql.gz" -o -name "*.tar.gz" \) -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
    [ -z "$latest" ] && return 1

    echo "${latest%.*}"
}

# DDEV project state for a project dir: running | stopped | unknown.
# `ddev describe` is read-only. "unknown" = ddev binary unavailable.
sweep_ddev_state() {
    local proj_dir="$1"

    if ! command -v ddev &>/dev/null; then
        echo "unknown"
        return 0
    fi

    local desc
    if ! desc=$(cd "$proj_dir" && ddev describe -j 2>/dev/null); then
        echo "stopped"
        return 0
    fi

    if echo "$desc" | grep -q '"status": *"running"'; then
        echo "running"
    else
        echo "stopped"
    fi
}

################################################################################
# `pl backup prune` — retention window on LOCAL backups (ops#124)
#
# Deletes local backup SETS (.sql.gz/.tar.gz + their .sha256/.manifest.json
# sidecars) older than the retention window, so deleted user data does not
# survive in local dev backups beyond the promised window (the erasure promise).
# SAFETY: the newest set per site is ALWAYS kept — a site is never left with
# zero backups, even if its newest backup is already older than the window.
#
# Scope note: this enforces retention on the LOCAL sites/<name>/backups/ tier
# only. The remote DR tiers (restic on ver, LUKS sticks, box nightly) enforce
# their own retention; see docs/reports/consolidation-arc-2026-07 for the
# multi-tier erasure-promise reconciliation (⚠ restic keeps 12 monthly today).
################################################################################
show_prune_help() {
    cat <<EOF
pl backup prune — enforce a retention window on local backups (ops#124)

Usage:
  pl backup prune [--days N] [--site NAME] [--dry-run] [-y]

Options:
  --days N       Retention window in days (default: settings
                 thresholds.backup_retention_days, else 30).
  --site NAME    Prune one site (default: all discovered sites).
  --dry-run      Show what would be deleted; delete nothing.
  -y, --yes      Skip the confirmation prompt.
  -h, --help     This help.

The newest backup set per site is always kept.
EOF
}

prune_main() {
    local DRY_RUN=false YES=false ONLY_SITE="" DAYS=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)   show_prune_help; exit 0 ;;
            --dry-run)   DRY_RUN=true; shift ;;
            -y|--yes)    YES=true; shift ;;
            --days)      DAYS="${2:-}"; [ -z "$DAYS" ] && { print_error "--days requires a number"; exit 1; }; shift 2 ;;
            --days=*)    DAYS="${1#*=}"; shift ;;
            --site)      ONLY_SITE="${2:-}"; [ -z "$ONLY_SITE" ] && { print_error "--site requires a name"; exit 1; }; shift 2 ;;
            --site=*)    ONLY_SITE="${1#*=}"; shift ;;
            *)           print_error "Unknown prune option: $1"; echo ""; show_prune_help; exit 1 ;;
        esac
    done

    # Retention window: flag > setting > 30.
    if [ -z "$DAYS" ]; then
        DAYS=30
        if [ -f "$PROJECT_ROOT/lib/todo-checks.sh" ]; then
            # shellcheck source=/dev/null
            source "$PROJECT_ROOT/lib/todo-checks.sh"
            DAYS=$(get_todo_setting "thresholds.backup_retention_days" "30")
        fi
    fi
    if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || [ "$DAYS" -lt 1 ]; then
        print_error "Retention days must be a positive integer (got: $DAYS)"; exit 1
    fi

    local now_epoch cutoff
    now_epoch=$(date +%s)
    cutoff=$((now_epoch - DAYS * 86400))

    print_header "NWP Backup Prune (retention: ${DAYS} days)"
    [ "$DRY_RUN" = true ] && print_info "Dry run — nothing will be deleted"

    local -a sites=()
    if [ -n "$ONLY_SITE" ]; then
        sites=("$ONLY_SITE")
    else
        mapfile -t sites < <(discover_sites)
    fi
    [ ${#sites[@]} -eq 0 ] && { print_warning "No sites discovered"; exit 0; }

    # ── PASS 1: collect victims (stem + backup dir), keeping the newest set. ──
    local -a victim_stems=() victim_dirs=() victim_ages=()
    local total_bytes=0 kept=0
    local site
    for site in "${sites[@]}"; do
        [ -z "$site" ] && continue
        local bdir
        bdir=$(get_backup_dir "$site" 2>/dev/null) || bdir=""
        { [ -z "$bdir" ] || [ ! -d "$bdir" ]; } && continue

        local -a stems=()
        mapfile -t stems < <(
            find "$bdir" -maxdepth 1 -type f \( -name '*.sql.gz' -o -name '*.tar.gz' \) -printf '%f\n' 2>/dev/null \
            | sed -E 's/\.(sql|tar)\.gz$//' | sort -u
        )
        [ ${#stems[@]} -eq 0 ] && continue

        # Newest set (max mtime across its files) is always kept.
        local newest_stem="" newest_epoch=0 stem
        declare -A _epoch=()
        for stem in "${stems[@]}"; do
            local e
            e=$(find "$bdir" -maxdepth 1 -type f -name "${stem}.*" -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
            e=${e%.*}; [ -z "$e" ] && e=0
            _epoch["$stem"]=$e
            if [ "$e" -gt "$newest_epoch" ]; then newest_epoch=$e; newest_stem=$stem; fi
        done

        for stem in "${stems[@]}"; do
            local e=${_epoch[$stem]}
            if [ "$stem" = "$newest_stem" ] || [ "$e" -ge "$cutoff" ]; then
                kept=$((kept + 1)); continue
            fi
            victim_stems+=("$stem"); victim_dirs+=("$bdir")
            victim_ages+=("$(( (now_epoch - e) / 86400 ))")
            local f
            while IFS= read -r f; do
                total_bytes=$((total_bytes + $(stat -c%s "$f" 2>/dev/null || echo 0)))
            done < <(find "$bdir" -maxdepth 1 -type f -name "${stem}.*" 2>/dev/null)
        done
        unset _epoch
    done

    local nvictims=${#victim_stems[@]}
    if [ "$nvictims" -eq 0 ]; then
        print_success "Nothing to prune — all backups within ${DAYS} days (kept $kept set(s))."
        exit 0
    fi

    echo ""
    print_info "Backup sets older than ${DAYS} days (newest per site always kept):"
    local i
    for i in "${!victim_stems[@]}"; do
        echo -e "  ${YELLOW}→${NC} ${victim_stems[$i]} (${victim_ages[$i]}d old)"
    done
    echo -e "  ${DIM}total: $nvictims set(s), ~$((total_bytes/1024/1024)) MB; keeping $kept${NC}"

    if [ "$DRY_RUN" = true ]; then
        echo ""; print_info "Dry run — nothing deleted."; exit 0
    fi

    if [ "$YES" != true ]; then
        echo ""
        read -r -p "Delete these $nvictims backup set(s)? [y/N] " _ans
        case "$_ans" in
            y|Y|yes|YES) : ;;
            *) print_info "Aborted — nothing deleted."; exit 0 ;;
        esac
    fi

    # ── PASS 2: delete. ──
    local deleted=0
    for i in "${!victim_stems[@]}"; do
        local f
        while IFS= read -r f; do rm -f "$f"; done \
            < <(find "${victim_dirs[$i]}" -maxdepth 1 -type f -name "${victim_stems[$i]}.*" 2>/dev/null)
        echo -e "  ${RED}✗${NC} deleted ${victim_stems[$i]}"
        deleted=$((deleted + 1))
    done
    echo ""
    print_success "Pruned $deleted backup set(s) (~$((total_bytes/1024/1024)) MB freed); kept $kept."
    exit 0
}

sweep_main() {
    local DRY_RUN=false
    local START_STOPPED=false
    local ONLY_SITE=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_sweep_help
                exit 0
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --start-stopped)
                START_STOPPED=true
                shift
                ;;
            --site)
                ONLY_SITE="${2:-}"
                if [ -z "$ONLY_SITE" ]; then
                    print_error "--site requires a site name"
                    exit 1
                fi
                shift 2
                ;;
            --site=*)
                ONLY_SITE="${1#*=}"
                shift
                ;;
            *)
                print_error "Unknown sweep option: $1"
                echo ""
                show_sweep_help
                exit 1
                ;;
        esac
    done

    # Stale threshold — read via the todo library so sweep and `pl todo`
    # can never drift apart on the definition of "stale".
    local warn_days=7
    if [ -f "$PROJECT_ROOT/lib/todo-checks.sh" ]; then
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT/lib/todo-checks.sh"
        warn_days=$(get_todo_setting "thresholds.backup_warn_days" "7")
    fi

    local now_epoch warn_seconds
    now_epoch=$(date +%s)
    warn_seconds=$((warn_days * 86400))

    print_header "NWP Backup Sweep"
    print_info "Stale threshold: ${warn_days} days"
    if [ "$DRY_RUN" = true ]; then
        print_info "Dry run — no backups will be taken"
    fi

    # Collect sites up-front (array, not a pipe: backup/ddev calls below
    # must not eat the site list from stdin).
    local -a sweep_sites=()
    if [ -n "$ONLY_SITE" ]; then
        sweep_sites=("$ONLY_SITE")
    else
        mapfile -t sweep_sites < <(discover_sites)
    fi

    if [ ${#sweep_sites[@]} -eq 0 ]; then
        print_warning "No sites discovered under ${NWP_DIR:-$PROJECT_ROOT}/sites/"
        exit 0
    fi

    local total=0 fresh=0 backed_up=0 skipped=0 noproj=0 failed=0
    local site

    for site in "${sweep_sites[@]}"; do
        [ -z "$site" ] && continue
        total=$((total + 1))

        # Locate the dev DDEV project (v2 nested dev/, v1 flat).
        local proj_dir=""
        proj_dir=$(resolve_project "$site" dev 2>/dev/null) || proj_dir=""
        if [ -z "$proj_dir" ] || [ ! -d "$proj_dir/.ddev" ]; then
            echo -e "  ${DIM}- $site: no dev DDEV project — skipping${NC}"
            noproj=$((noproj + 1))
            continue
        fi

        # Freshness check (same logic as check_missing_backups).
        local latest_epoch="" age_desc="no backups found"
        if latest_epoch=$(sweep_latest_backup_epoch "$site"); then
            local age=$((now_epoch - latest_epoch))
            if [ "$age" -le "$warn_seconds" ]; then
                echo -e "  ${GREEN}✓${NC} $site: fresh (last backup $((age / 86400))d old)"
                fresh=$((fresh + 1))
                continue
            fi
            age_desc="last backup $((age / 86400))d old"
        fi

        # Stale or missing — decide based on DDEV state.
        local state
        state=$(sweep_ddev_state "$proj_dir")

        if [ "$DRY_RUN" = true ]; then
            case "$state" in
                running)
                    echo -e "  ${YELLOW}→${NC} $site: would back up ($age_desc; project running)"
                    backed_up=$((backed_up + 1))
                    ;;
                stopped)
                    if [ "$START_STOPPED" = true ]; then
                        echo -e "  ${YELLOW}→${NC} $site: would start, back up, stop ($age_desc)"
                        backed_up=$((backed_up + 1))
                    else
                        echo -e "  ${DIM}- $site: skipped — not running ($age_desc; use --start-stopped)${NC}"
                        skipped=$((skipped + 1))
                    fi
                    ;;
                *)
                    echo -e "  ${DIM}- $site: skipped — ddev not available${NC}"
                    skipped=$((skipped + 1))
                    ;;
            esac
            continue
        fi

        if [ "$state" = "unknown" ]; then
            print_warning "$site: ddev not available — skipped"
            skipped=$((skipped + 1))
            continue
        fi

        local was_stopped=false
        if [ "$state" = "stopped" ]; then
            if [ "$START_STOPPED" != true ]; then
                echo -e "  ${DIM}- $site: skipped — not running ($age_desc; use --start-stopped)${NC}"
                skipped=$((skipped + 1))
                continue
            fi
            was_stopped=true
            print_info "$site: starting DDEV project ($age_desc)..."
            if ! (cd "$proj_dir" && ddev start -y >/dev/null 2>&1); then
                print_error "$site: ddev start failed — skipped"
                failed=$((failed + 1))
                continue
            fi
        fi

        # Reuse the standard backup path (db-only) — no duplicated export logic.
        if backup_site "$site" "$site" "sweep automated backup" true false false false false false basic < /dev/null; then
            backed_up=$((backed_up + 1))
        else
            print_error "$site: backup failed"
            failed=$((failed + 1))
        fi

        # Restore prior state: stop only what we started.
        if [ "$was_stopped" = true ]; then
            print_info "$site: stopping DDEV project (was stopped before sweep)"
            (cd "$proj_dir" && ddev stop >/dev/null 2>&1) || true
        fi
    done

    print_header "Sweep Summary"
    local summary="swept $total sites: $fresh fresh, $backed_up backed up, $skipped skipped-not-running, $noproj no-project"
    if [ "$failed" -gt 0 ]; then
        summary="$summary, $failed FAILED"
    fi
    if [ "$DRY_RUN" = true ]; then
        summary="$summary (dry run)"
    fi
    echo "$summary"

    if [ "$failed" -gt 0 ]; then
        exit 1
    fi
    exit 0
}

################################################################################
# Main Script
################################################################################

main() {
    # Subcommand dispatch: `backup sweep [flags]` (sitename-first args
    # otherwise — sweep is reserved and cannot be a site name).
    if [[ "${1:-}" == "sweep" ]]; then
        shift
        sweep_main "$@"
    fi

    # Subcommand dispatch: `backup prune [flags]` (ops#124 retention; reserved,
    # cannot be a site name). prune_main always exits.
    if [[ "${1:-}" == "prune" ]]; then
        shift
        prune_main "$@"
    fi

    # Parse options
    local DEBUG=false
    local DB_ONLY=false
    local GIT_BACKUP=false
    local BUNDLE=false
    local INCREMENTAL=false
    local PUSH_ALL=false
    local SANITIZE=false
    local SANITIZE_LEVEL="basic"
    local ENDPOINT=""
    local SITENAME=""
    local MESSAGE=""
    # Remote pre-deploy snapshot (P0-3).
    local REMOTE=false
    local FILES_ONLY=false
    local DRY_RUN=false
    local YES=false

    # Use getopt for option parsing
    local OPTIONS=hdbge:y
    local LONGOPTS=help,debug,db-only,git,endpoint:,bundle,incremental,push-all,sanitize,sanitize-level:,remote,files-only,dry-run,yes

    if ! PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTS --name "$0" -- "$@"); then
        show_help
        exit 1
    fi

    eval set -- "$PARSED"

    while true; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -d|--debug)
                DEBUG=true
                shift
                ;;
            -b|--db-only)
                DB_ONLY=true
                shift
                ;;
            -g|--git)
                GIT_BACKUP=true
                shift
                ;;
            -e|--endpoint)
                ENDPOINT="$2"
                shift 2
                ;;
            --bundle)
                BUNDLE=true
                shift
                ;;
            --incremental)
                INCREMENTAL=true
                shift
                ;;
            --push-all)
                PUSH_ALL=true
                shift
                ;;
            --sanitize)
                SANITIZE=true
                shift
                ;;
            --sanitize-level)
                SANITIZE_LEVEL="$2"
                shift 2
                ;;
            --remote)
                REMOTE=true
                shift
                ;;
            --files-only)
                FILES_ONLY=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -y|--yes)
                YES=true
                shift
                ;;
            --)
                shift
                break
                ;;
            *)
                echo "Programming error"
                exit 3
                ;;
        esac
    done

    # Get sitename and message from remaining arguments
    if [ $# -ge 1 ]; then
        SITENAME="$1"
        shift
    else
        print_error "No site specified"
        echo ""
        show_help
        exit 1
    fi

    # Rest of arguments are the message
    if [ $# -ge 1 ]; then
        MESSAGE="$*"
    fi

    # Default endpoint to sitename
    if [ -z "$ENDPOINT" ]; then
        ENDPOINT="$SITENAME"
    fi

    # Remote pre-deploy snapshot path (P0-3). Bypasses the entire DDEV-local
    # flow: no resolve_project, no ddev export-db — it snapshots the LIVE host.
    # This is the DR-preflight `pl cutover` / `pl moodle deploy` require.
    if [ "$REMOTE" == "true" ]; then
        if [ "$DB_ONLY" == "true" ] && [ "$FILES_ONLY" == "true" ]; then
            print_error "--db-only and --files-only are mutually exclusive"
            exit 1
        fi
        if backup_remote "$SITENAME" "$ENDPOINT" "$DB_ONLY" "$FILES_ONLY" "$DRY_RUN" "$YES"; then
            show_elapsed_time "Remote backup"
            exit 0
        else
            print_error "Remote backup failed for site: $SITENAME"
            exit 1
        fi
    fi

    ocmsg "Site: $SITENAME"
    ocmsg "Endpoint: $ENDPOINT"
    ocmsg "Message: $MESSAGE"
    ocmsg "Debug: $DEBUG"
    ocmsg "Database-only: $DB_ONLY"
    ocmsg "Git backup: $GIT_BACKUP"
    ocmsg "Bundle: $BUNDLE"
    ocmsg "Incremental: $INCREMENTAL"
    ocmsg "Push all: $PUSH_ALL"
    ocmsg "Sanitize: $SANITIZE"
    ocmsg "Sanitize level: $SANITIZE_LEVEL"

    # Run backup
    if backup_site "$SITENAME" "$ENDPOINT" "$MESSAGE" "$DB_ONLY" "$GIT_BACKUP" "$BUNDLE" "$INCREMENTAL" "$PUSH_ALL" "$SANITIZE" "$SANITIZE_LEVEL"; then
        show_elapsed_time "Backup"
        exit 0
    else
        print_error "Backup failed for site: $SITENAME"
        exit 1
    fi
}

# Run main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
