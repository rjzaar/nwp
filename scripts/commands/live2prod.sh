#!/bin/bash
set -euo pipefail

################################################################################
# NWP Live to Production Deployment Script
#
# Deploys from live test server directly to production server
#
# Usage: ./live2prod.sh [OPTIONS] <sitename>
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
# canonical.sh: canonicality-phase content-flow guards (nwp/ops#33)
source "$PROJECT_ROOT/lib/canonical.sh"
# deploy-gate.sh: hardware+signature gate on prod-writes (ADR-0028); no-op unless
# configured (ver) — the AI test tier (A14) is unaffected.
source "$PROJECT_ROOT/lib/deploy-gate.sh"
# pair.sh: paired-site versioning guard (ADR-0031/ops#75); no-op unless paired.
source "$PROJECT_ROOT/lib/pair.sh"
# rollback.sh: register the pre-deploy snapshot as a rollback point (optional —
# rollback_record_remote is called guarded, so a missing helper is a clean no-op).
source "$PROJECT_ROOT/lib/rollback.sh"

# Script start time
START_TIME=$(date +%s)

################################################################################
# Configuration Functions
################################################################################

get_live_config() {
    local sitename="$1"
    local field="$2"
    local base=$(get_base_name "$sitename")

    # F23: read from per-site .nwp.yml via layered config reader.
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

get_prod_config() {
    local sitename="$1"
    local field="$2"

    awk -v site="$sitename" -v field="$field" '
        /^sites:/ { in_sites = 1; next }
        in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
        in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
        in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
        in_site && /^    production:/ { in_prod = 1; next }
        in_prod && /^    [a-zA-Z]/ && !/^      / { in_prod = 0 }
        in_prod && $0 ~ "^      " field ":" {
            sub("^      " field ": *", "")
            gsub(/["'"'"']/, "")
            print
            exit
        }
    ' "$PROJECT_ROOT/nwp.yml"
}

################################################################################
# Safety / Pre-Deploy Snapshots + Maintenance Wrap
#
# Ported from stg2live.sh's guard-stack (F2/P0-2 fail-closed snapshot + G3
# maintenance wrap + §3.6 fail-loud updatedb). live2prod is server→server (live
# → prod), so all destructive ops target the PROD host; the snapshot and the
# maintenance toggle are taken there, before/around the rsync --delete.
################################################################################

# Resolve the deploy webroot (docroot subdir) from the v2 site tree via
# resolve_project (F23). Prefers the live checkout's DDEV docroot, then stg,
# then dev; defaults to "web". Scopes the pre-deploy webroot tar AND the drush
# --root path so both point at the same docroot the deploy overwrites.
get_deploy_webroot() {
    local base_name="$1"
    local env dir webroot=""
    for env in live stg dev; do
        dir=$(resolve_project "$base_name" "$env" 2>/dev/null || true)
        if [ -n "$dir" ] && [ -f "$dir/.ddev/config.yaml" ]; then
            webroot=$(grep '^docroot:' "$dir/.ddev/config.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"' | head -1)
            [ -n "$webroot" ] && break
        fi
    done
    [ -z "$webroot" ] && webroot="web"
    printf '%s' "$webroot"
}

# Ledger an --override-snapshot / --skip-backup use so a destructive deploy that
# ran WITHOUT a proven prod snapshot is auditable after the fact (mirrors the
# --override-canonical / --override-pair ledgers in stg2live.sh).
_snapshot_override_ledger() {
    local base_name="$1"
    local reason="$2"
    local ledger_dir="${PROJECT_ROOT}/private/snapshots"
    mkdir -p "$ledger_dir" 2>/dev/null || true
    local who
    who=$(whoami 2>/dev/null || echo "unknown")
    echo "$(date -Iseconds 2>/dev/null || date)  ${who}  ${base_name}  override  ${reason}" \
        >> "${ledger_dir}/${base_name}.log" 2>/dev/null || true
    print_status "WARN" "snapshot override ledgered: ${ledger_dir}/${base_name}.log"
}

# Take a pre-deploy snapshot of the PRODUCTION host: all databases (compressed
# dump) + /etc/nginx/conf.d/ (tarball) + the WEBROOT (tarball, excl.
# files/+private). FAIL-CLOSED: a webroot-snapshot failure ABORTS the deploy
# (return 1) unless --override-snapshot (ledgered), because the live→prod rsync
# --delete that follows is otherwise unrecoverable. Idempotent within 1 hour off
# the webroot tar. Mirrors stg2live.sh::live_host_snapshot.
prod_host_snapshot() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    local remote_path="${4:-}"
    local webroot="${5:-web}"

    print_header "Pre-Deploy Production Snapshot"

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo "
    fi

    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local dbs_file="nwp-snapshot-${base_name}-dbs-${ts}.sql.gz"
    local nginx_file="nwp-snapshot-${base_name}-nginx-${ts}.tar.gz"

    # Check disk space first (bail if tighter than 1 GB free in ~).
    local free_kb
    free_kb=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "df -k --output=avail ~ | tail -1" 2>/dev/null | tr -d ' ')
    if [ -n "$free_kb" ] && [ "$free_kb" -lt 1048576 ]; then
        print_status "WARN" "Prod host has <1GB free in ~ (${free_kb}KB)."
        if [ "${OVERRIDE_SNAPSHOT:-false}" == "true" ]; then
            _snapshot_override_ledger "$base_name" "disk-tight (<1GB free in ~); snapshot skipped"
            print_status "WARN" "--override-snapshot set — proceeding WITHOUT a pre-deploy snapshot."
            return 0
        fi
        print_error "Refusing the destructive rsync --delete without a webroot snapshot (disk-tight)."
        print_error "Free disk on the prod host, or re-run with --override-snapshot (ledgered)."
        return 1
    fi

    # Idempotent: skip if a WEBROOT snapshot from the last hour exists (the
    # webroot tar is the critical --delete backstop, so idempotency keys off it).
    local recent
    recent=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "find ~ -maxdepth 1 -name 'nwp-snapshot-${base_name}-webroot-*.tar.gz' -mmin -60 2>/dev/null | head -1" \
        2>/dev/null)
    if [ -n "$recent" ]; then
        print_status "INFO" "Recent snapshot exists: $(basename "$recent")"
        print_status "INFO" "Skipping (idempotent within 1 hour)."
        return 0
    fi

    print_info "Snapshotting all databases..."
    if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "${sudo_prefix}mysqldump --all-databases --single-transaction --quick --routines --triggers 2>/dev/null | gzip > ~/${dbs_file}"; then
        local dbs_size
        dbs_size=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
            "ls -lh ~/${dbs_file} | awk '{print \$5}'" 2>/dev/null)
        print_status "OK" "DB snapshot: ~/${dbs_file} (${dbs_size})"
    else
        print_status "WARN" "DB snapshot failed (continuing — verify prod state manually before destructive ops)"
    fi

    print_info "Snapshotting /etc/nginx/conf.d/..."
    if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "${sudo_prefix}tar czf ~/${nginx_file} /etc/nginx/conf.d/ 2>/dev/null && ${sudo_prefix}chown ${ssh_user}:${ssh_user} ~/${nginx_file}"; then
        print_status "OK" "Nginx snapshot: ~/${nginx_file}"
    else
        print_status "WARN" "Nginx snapshot failed (continuing — verify prod state manually)"
    fi

    # Snapshot the prod WEBROOT before the rsync --delete swaps it out. This is
    # the fail-closed backstop: unlike the DB/nginx dumps above (WARN-and-
    # continue), a webroot snapshot failure ABORTS the deploy (return 1) unless
    # --override-snapshot. Success is decided by `test -s` on the resulting tar
    # (not tar's exit code, which can be 1 on a benign "file changed as we read
    # it" against a live site).
    local webroot_file="nwp-snapshot-${base_name}-webroot-${ts}.tar.gz"
    local web_remote=""
    if [ -n "$remote_path" ]; then
        print_info "Snapshotting prod webroot (${remote_path}, excl. ${webroot}/sites/default/files + private)..."
        if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
            "${sudo_prefix}tar czf ~/${webroot_file} -C ${remote_path} . --exclude=./${webroot}/sites/default/files --exclude=./private 2>/dev/null; ${sudo_prefix}chown ${ssh_user}:${ssh_user} ~/${webroot_file} 2>/dev/null; test -s ~/${webroot_file}"; then
            local web_size
            web_size=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
                "ls -lh ~/${webroot_file} | awk '{print \$5}'" 2>/dev/null)
            print_status "OK" "Webroot snapshot: ~/${webroot_file} (${web_size})"
            web_remote="${webroot_file}"
        else
            print_status "WARN" "Webroot snapshot failed or empty (~/${webroot_file})."
            if [ "${OVERRIDE_SNAPSHOT:-false}" == "true" ]; then
                _snapshot_override_ledger "$base_name" "webroot snapshot failed/empty; --override-snapshot set"
                print_status "WARN" "--override-snapshot set — proceeding WITHOUT a webroot snapshot (ledgered)."
            else
                print_error "Refusing the destructive rsync --delete without a webroot snapshot."
                print_error "Investigate the prod host, or re-run with --override-snapshot (ledgered)."
                return 1
            fi
        fi
    else
        print_status "WARN" "No remote_path resolved — skipping webroot snapshot (no --delete backstop)."
    fi

    # Register the snapshot as a rollback point (best-effort; guarded so a
    # missing helper is a clean no-op).
    if command -v rollback_record_remote >/dev/null 2>&1; then
        local commit_sha=""
        if [ -d "${PROJECT_ROOT}/.git" ]; then
            commit_sha=$(cd "$PROJECT_ROOT" && git rev-parse HEAD 2>/dev/null || true)
        fi
        local dbs_remote nginx_remote home_dir
        home_dir=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
            'echo $HOME' 2>/dev/null || echo "/home/${ssh_user}")
        dbs_remote="${home_dir}/${dbs_file}"
        nginx_remote="${home_dir}/${nginx_file}"
        local web_remote_abs=""
        [ -n "$web_remote" ] && web_remote_abs="${home_dir}/${web_remote}"
        rollback_record_remote "$base_name" "prod" "$ssh_user" "$server_ip" \
            "$ts" "$dbs_remote" "$nginx_remote" "$commit_sha" "$web_remote_abs" "$remote_path" \
            || print_status "WARN" "Could not register rollback point (snapshot files OK)."
    fi

    echo ""
    print_info "To restore from this snapshot if needed:"
    echo "  pl rollback execute ${base_name} prod --dry-run    # preview"
    echo "  pl rollback execute ${base_name} prod              # apply (with confirmation)"
    echo ""

    return 0
}

# Is there a FRESH pre-deploy snapshot ARTIFACT for this site on the prod host?
# Keys off the webroot tar (the rsync --delete backstop) written by
# prod_host_snapshot in the last hour — the same artifact prod_host_snapshot
# uses for its own idempotency. Returns 0 iff one is present.
_prod_snapshot_present() {
    local base_name="$1"
    local recent
    recent=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${PROD_USER}@${PROD_IP}" \
        "find ~ -maxdepth 1 -name 'nwp-snapshot-${base_name}-webroot-*.tar.gz' -mmin -60 2>/dev/null | head -1" \
        2>/dev/null)
    [ -n "$recent" ]
}

# FAIL-CLOSED gate on the destructive region. Called immediately BEFORE the
# rsync --delete, regardless of --step, so a `-s N` resume that jumps PAST the
# snapshot step (step 1) can NEVER reach the --delete without a fresh backstop
# for THIS deploy. If no fresh snapshot artifact is present it RE-TAKES one
# (prod_host_snapshot is idempotent, so a normal full run does not double-dump);
# only an explicit --override-snapshot / --skip-backup (ledgered) may proceed
# without a proven snapshot. Returns non-zero to make the caller abort.
require_prod_snapshot() {
    local base_name="$1"

    # Explicit operator override: proceed, but ledger loudly if no artifact
    # actually exists (so a --step resume under --skip-backup is still audited).
    if [ "${SKIP_BACKUP:-false}" == "true" ] || [ "${OVERRIDE_SNAPSHOT:-false}" == "true" ]; then
        if ! _prod_snapshot_present "$base_name"; then
            _snapshot_override_ledger "$base_name" "rsync --delete reached with NO fresh snapshot artifact (override/--skip-backup)"
            print_warning "Proceeding to the rsync --delete WITHOUT a verified snapshot (override, ledgered)."
        fi
        return 0
    fi

    # Fresh snapshot already on the host (normal full run, or a resume soon
    # after a prior snapshot) — nothing to do.
    if _prod_snapshot_present "$base_name"; then
        print_status "OK" "Fresh pre-deploy snapshot verified — destructive rsync --delete may proceed."
        return 0
    fi

    # No fresh snapshot for THIS deploy — most likely a `-s N` resume that
    # skipped step 1. Re-take it fail-closed rather than silently --delete.
    print_warning "No fresh pre-deploy snapshot found (--step resume?). Re-taking BEFORE the rsync --delete."
    if ! backup_production "$base_name"; then
        print_error "Pre-deploy snapshot failed — REFUSING the destructive rsync --delete (fail-closed)."
        print_error "(Override at your own risk with --override-snapshot or --skip-backup, both ledgered.)"
        return 1
    fi
    if ! _prod_snapshot_present "$base_name"; then
        print_error "Snapshot reported success but no artifact is present — REFUSING the rsync --delete (fail-closed)."
        return 1
    fi
    return 0
}

# Drupal maintenance mode around the destructive swap (G3). Enable BEFORE the
# rsync --delete so members never hit a half-populated webroot; disable only
# AFTER the post-sync updatedb/cr sequence. Fail-loud: a failed maintenance-ON
# ABORTS before the --delete (return 1); a failed maintenance-OFF leaves the
# site stuck at 503 and is reported LOUDLY. Mirrors
# stg2live.sh::live_maintenance_set.
prod_maintenance_set() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    local remote_path="$4"
    local webroot="$5"
    local state="$6"   # 1 = ON (maintenance), 0 = OFF (live)

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo"
    fi

    local label="ON"
    [ "$state" == "0" ] && label="OFF"
    print_info "Maintenance mode ${label} (system.maintenance_mode=${state})..."

    # Explicit drush resolve (no PATH reliance), stderr NOT swallowed.
    local resolve="for D in ${remote_path}/vendor/bin/drush ${remote_path}/${webroot}/vendor/bin/drush; do [ -x \"\$D\" ] && break; done"
    if ssh $(nwp_ssh_opts "$base_name") "${ssh_user}@${server_ip}" \
        "${resolve}; ${sudo_prefix} -u www-data \"\$D\" --root=${remote_path}/${webroot} state:set system.maintenance_mode ${state} --input-format=integer && ${sudo_prefix} -u www-data \"\$D\" --root=${remote_path}/${webroot} cr"; then
        print_status "OK" "Maintenance mode ${label}"
        return 0
    elif [ "$state" == "0" ]; then
        print_error "Could NOT disable maintenance mode — THE SITE MAY BE STUCK IN MAINTENANCE (503)."
        # NO pl VERB — `pl drush` is stg|live only; the v2 site schema carries no
        # `production:` block, so there is nothing for a --tier=prod arm to
        # resolve. Prod writes are operator-gated by design (ADR-0024/0028), so the
        # sanctioned recovery is the rollback verb, not a hand drush.
        print_error "Recover through pl (prod writes are operator-gated — do NOT hand-ssh):"
        print_error "  pl rollback list ${base_name}"
        print_error "  pl rollback execute ${base_name} prod        # restores the pre-deploy state"
        print_error "  pl server status                            # confirm the host is up"
        print_error "NO pl VERB clears maintenance_mode on prod on its own — if rollback does not lift"
        print_error "the 503, escalate to the offline deploy operator (see docs/SECURITY.md)."
        return 1
    else
        # Failed to turn maintenance ON. Return non-zero so the caller REFUSES
        # to start the destructive rsync --delete (members would otherwise see a
        # half-populated webroot mid-deploy).
        print_status "WARN" "Could not set maintenance_mode=${state} (drush unavailable?)"
        return 1
    fi
}

show_help() {
    cat << EOF
${BOLD}NWP Live to Production Deployment${NC}

${BOLD}USAGE:${NC}
    ./live2prod.sh [OPTIONS] <sitename>

    Deploys directly from live test server to production server.
    This is an advanced workflow for when live has been tested and
    you want to bypass staging.

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -y, --yes               Skip confirmation prompts (NEVER the pre-deploy snapshot)
    -s, --step <n>          Start from step n. A resume that jumps PAST the
                            snapshot step still RE-TAKES a fresh pre-deploy
                            snapshot before the rsync --delete (fail-closed) —
                            it never silently --deletes without a backstop.
    --skip-backup           Skip the fail-closed pre-deploy production snapshot
                            (dangerous!). No longer a silent bypass — it is
                            ledgered to private/snapshots/<site>.log.
    --override-snapshot     Proceed past a failed/disk-tight pre-deploy snapshot
                            (ledgered). The rsync --delete then has no backstop.
    --code-only             Signal code/config-only intent to the pair guard
                            (ADR-0031 D6) — satisfies the UID-lock rule for a paired
                            provider/consumer prod deploy.
    --override-pair         Proceed past a paired-site guard (ADR-0031). Ledgered in
                            private/pairs/<pair>.log. For paired sites only.

${BOLD}WORKFLOW:${NC}
    1. Validate live and production configurations
    2. Fail-closed pre-deploy production snapshot (DBs + nginx + webroot)
       -- maintenance mode ON (wraps the destructive region below) --
    3. Export configuration from live
       -- assert a fresh snapshot exists (re-take on --step resume, else refuse) --
    4. Sync files from live to production (rsync --delete)
    5. Run composer install on production (fail-loud)
    6. Run database updates (fail-loud; maintenance left ON on failure)
       -- maintenance mode OFF (only after a clean updatedb) --
    7. Import configuration (fail-closed skip; NWP_ALLOW_CONFIG_IMPORT=1 to enable)
    8. Clear caches

${BOLD}EXAMPLES:${NC}
    ./live2prod.sh mysite              # Deploy live to production
    ./live2prod.sh -y mysite           # Deploy without confirmation

${BOLD}RECOMMENDED WORKFLOW:${NC}
    For most deployments, use the safer two-step approach:
    1. pl live2stg mysite    # Pull live changes to staging
    2. pl stg2prod mysite    # Deploy staging to production

EOF
}

################################################################################
# Deployment Functions
################################################################################

validate_deployment() {
    local base_name="$1"

    print_info "Validating deployment configuration..."

    # Check live server config
    local live_ip=$(get_live_config "$base_name" "server_ip")
    local live_user=$(get_live_config "$base_name" "ssh_user")
    local live_path=$(get_live_config "$base_name" "webroot")

    if [ -z "$live_ip" ]; then
        print_error "No live server configured for $base_name"
        print_info "Run 'pl live $base_name' first to provision live server"
        return 1
    fi

    # Check production server config
    local prod_ip=$(get_prod_config "$base_name" "server_ip")
    local prod_user=$(get_prod_config "$base_name" "ssh_user")
    local prod_path=$(get_prod_config "$base_name" "webroot")

    if [ -z "$prod_ip" ]; then
        print_error "No production server configured for $base_name"
        print_info "Configure production section in nwp.yml first"
        return 1
    fi

    # Test SSH connections
    print_info "Testing SSH connection to live server ($live_ip)..."
    if ! ssh $(nwp_ssh_opts "$base_name") -o ConnectTimeout=5 -o BatchMode=yes "${live_user:-root}@${live_ip}" "echo OK" &>/dev/null; then
        print_error "Cannot connect to live server: ${live_user:-root}@${live_ip}"
        return 1
    fi
    print_status "OK" "Live server accessible"

    print_info "Testing SSH connection to production server ($prod_ip)..."
    if ! ssh $(nwp_ssh_opts "$base_name") -o ConnectTimeout=5 -o BatchMode=yes "${prod_user:-root}@${prod_ip}" "echo OK" &>/dev/null; then
        print_error "Cannot connect to production server: ${prod_user:-root}@${prod_ip}"
        return 1
    fi
    print_status "OK" "Production server accessible"

    # Export variables for other functions
    export LIVE_IP="$live_ip"
    export LIVE_USER="${live_user:-root}"
    export LIVE_PATH="${live_path:-/var/www/$base_name}"
    export PROD_IP="$prod_ip"
    export PROD_USER="${prod_user:-root}"
    export PROD_PATH="${prod_path:-/var/www/$base_name}"

    return 0
}

backup_production() {
    local base_name="$1"

    # FAIL-CLOSED pre-deploy snapshot (DBs + nginx + WEBROOT), mirroring
    # stg2live's live_host_snapshot. Replaces the old DB-only dump-to-/tmp backup
    # which (a) captured no webroot backstop for the rsync --delete, and (b) was
    # a bare-cd-drush that could silently no-op. A webroot-snapshot failure now
    # ABORTS the deploy (return 1) unless --override-snapshot (ledgered).
    prod_host_snapshot "$base_name" "$PROD_IP" "$PROD_USER" "$PROD_PATH" "${PROD_WEBROOT:-web}"
}

export_live_config() {
    local base_name="$1"

    print_info "Exporting configuration from live server..."

    local export_cmd="cd $LIVE_PATH && drush config:export -y"

    if ssh $(nwp_ssh_opts "$base_name") "${LIVE_USER}@${LIVE_IP}" "$export_cmd"; then
        print_status "OK" "Configuration exported on live"
    else
        print_error "Failed to export configuration"
        return 1
    fi
}

sync_files() {
    local base_name="$1"

    print_info "Syncing files from live to production..."

    # Rsync from live to production (server to server)
    local rsync_cmd="rsync -avz --delete \
        --exclude='.git' \
        --exclude='sites/*/files' \
        --exclude='sites/*/private' \
        --exclude='vendor' \
        ${LIVE_USER}@${LIVE_IP}:${LIVE_PATH}/ \
        ${PROD_PATH}/"

    if ssh $(nwp_ssh_opts "$base_name") "${PROD_USER}@${PROD_IP}" "$rsync_cmd"; then
        print_status "OK" "Files synced to production"
    else
        print_error "Failed to sync files"
        return 1
    fi
}

run_composer() {
    local base_name="$1"

    print_info "Running composer install on production..."

    local composer_cmd="cd $PROD_PATH && composer install --no-dev --optimize-autoloader"

    if ssh $(nwp_ssh_opts "$base_name") "${PROD_USER}@${PROD_IP}" "$composer_cmd"; then
        print_status "OK" "Composer dependencies installed"
    else
        print_error "Composer install failed"
        return 1
    fi
}

run_db_updates() {
    local base_name="$1"
    local remote_path="${PROD_PATH}"
    local webroot="${PROD_WEBROOT:-web}"

    print_info "Running database updates on production..."

    local sudo_prefix=""
    [ "$PROD_USER" == "gitlab" ] && sudo_prefix="sudo"

    # Resolve drush EXPLICITLY (never rely on PATH — the old `cd $PROD_PATH &&
    # drush` form silently no-ops where drush isn't on PATH) and DO NOT swallow
    # stderr. Mirrors stg2live.sh::run_live_db_updates.
    local resolve="for D in ${remote_path}/vendor/bin/drush ${remote_path}/${webroot}/vendor/bin/drush; do [ -x \"\$D\" ] && break; done"

    if ssh $(nwp_ssh_opts "$base_name") "${PROD_USER}@${PROD_IP}" \
        "${resolve}; ${sudo_prefix} -u www-data \"\$D\" --root=${remote_path}/${webroot} updatedb -y"; then
        print_status "OK" "Database updates complete"
    else
        # FAIL-LOUD (was WARN-and-continue): a silently-failed updatedb leaves
        # hooks unrun + code/schema mismatched while the deploy would otherwise
        # report success (2026-07-21 incident). Return non-zero so the caller
        # ABORTS and maintenance mode stays ON for recovery.
        print_error "drush updatedb FAILED on production — schema hooks NOT applied. Maintenance mode left ON."
        # NO pl VERB — see prod_maintenance_set: `pl drush` is stg|live only and
        # prod writes are operator-gated (ADR-0024/0028). Rolling back is the
        # sanctioned move; a hand drush on prod is not.
        print_error "Recover through pl (prod writes are operator-gated — do NOT hand-ssh):"
        print_error "  pl rollback list ${base_name}"
        print_error "  pl rollback execute ${base_name} prod        # restores the pre-updatedb state"
        print_error "Re-attempt the deploy only after the schema mismatch is understood: pl live2prod ${base_name}"
        return 1
    fi

    print_info "Rebuilding cache..."
    ssh $(nwp_ssh_opts "$base_name") "${PROD_USER}@${PROD_IP}" \
        "${resolve}; ${sudo_prefix} -u www-data \"\$D\" --root=${remote_path}/${webroot} cache:rebuild" \
        || print_status "WARN" "cache:rebuild reported an error — verify the site"

    return 0
}

import_config() {
    local base_name="$1"

    # GUARD (ops#63): fail-closed skip unless opted in — see stg2prod.sh for the
    # rationale (importing a stale/empty sync snapshot revokes runtime-only
    # config and breaks live SSO). This path already fails the deploy on error.
    if [ "${NWP_ALLOW_CONFIG_IMPORT:-0}" != "1" ]; then
        print_status "SKIP" "config:import skipped (set NWP_ALLOW_CONFIG_IMPORT=1 to enable — see ops#63)"
        return 0
    fi

    print_info "Importing configuration on production..."

    local import_cmd="cd $PROD_PATH && drush config:import -y"

    if ssh $(nwp_ssh_opts "$base_name") "${PROD_USER}@${PROD_IP}" "$import_cmd"; then
        print_status "OK" "Configuration imported"
    else
        print_error "Configuration import failed"
        return 1
    fi
}

clear_caches() {
    local base_name="$1"

    print_info "Clearing caches on production..."

    local cache_cmd="cd $PROD_PATH && drush cache:rebuild"

    if ssh $(nwp_ssh_opts "$base_name") "${PROD_USER}@${PROD_IP}" "$cache_cmd"; then
        print_status "OK" "Caches cleared"
    else
        print_warning "Cache clear returned non-zero"
    fi
}

################################################################################
# Main
################################################################################

main() {
    local YES=false
    local SKIP_BACKUP=false
    local START_STEP=1
    local SITENAME=""

    local OVERRIDE_CANONICAL=false
    local OVERRIDE_PAIR=false
    local OVERRIDE_SNAPSHOT=false
    local CODE_ONLY=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) show_help; exit 0 ;;
            -y|--yes) YES=true; shift ;;
            -s|--step) START_STEP="$2"; shift 2 ;;
            --skip-backup) SKIP_BACKUP=true; shift ;;
            --override-snapshot) OVERRIDE_SNAPSHOT=true; shift ;;
            --override-canonical) OVERRIDE_CANONICAL=true; shift ;;
            --override-pair) OVERRIDE_PAIR=true; shift ;;
            --code-only) CODE_ONLY=true; shift ;;
            -*) print_error "Unknown option: $1"; exit 1 ;;
            *) SITENAME="$1"; shift ;;
        esac
    done

    if [ -z "$SITENAME" ]; then
        print_error "Sitename required"
        show_help
        exit 1
    fi

    local BASE_NAME=$(get_base_name "$SITENAME")

    # Canonicality guard (nwp/ops#33): under canonical: prod, content changes
    # happen on prod ONLY — a live→prod push would clobber the canonical
    # source (under dev/live it is the seed/cutover path and stays allowed).
    if ! canonical_guard_content_push "$BASE_NAME" "prod" "$OVERRIDE_CANONICAL" "live2prod"; then
        exit 1
    fi
    if ! canonical_enforce_branch_policy "$BASE_NAME" "deploy"; then
        exit 1
    fi
    # Maturity guard (P67/ops#48): code-flow class gate
    if ! maturity_guard_deploy "$BASE_NAME" "live2prod"; then
        exit 1
    fi
    # Pair guard (ADR-0031/ops#75): refuse a paired promotion that breaks
    # provider-first ordering, the D6 UID-lock/--code-only rule, or a red pair.
    # No-op for unpaired sites; fail-closed on a declared-but-missing contract.
    # ops#75/ops#83: resolve the provider's local code root (the live tier tree
    # being promoted) so pair_provider_sub_shape_guard can statically verify the
    # deployed source still emits the contracted UUID sub. Resolves empty when no
    # local live checkout exists → the sub-shape check stays inert (never a false
    # refusal); inert for non-provider/uncoupled sites regardless.
    local PROVIDER_CODE_ROOT
    PROVIDER_CODE_ROOT="$(resolve_project "$BASE_NAME" "live" 2>/dev/null || true)"
    if ! pair_guard "$BASE_NAME" "prod" "live2prod" "$CODE_ONLY" "$OVERRIDE_PAIR" "$PROVIDER_CODE_ROOT"; then
        exit 1
    fi

    print_header "Live to Production Deployment: $BASE_NAME"

    # Hardware+signature gate on the production write (ADR-0028). No-op on the
    # test tier (unconfigured); on ver it requires a live Solo touch.
    # UNCONDITIONAL: live2prod has no dry-run mode, so there is nothing to
    # exempt — the old `[ "$DRY_RUN" != true ]` guard let an *inherited* env
    # var skip the gate while every deploy step still ran for real (ops#79).
    deploy_gate_require "$BASE_NAME" "prod" \
        "push live → production (files + DB)" || exit 1

    # Validate configuration
    if ! validate_deployment "$BASE_NAME"; then
        exit 1
    fi

    # Confirmation
    if [ "$YES" != "true" ]; then
        print_warning "This will deploy LIVE directly to PRODUCTION"
        echo ""
        echo "  Live server:       ${LIVE_USER}@${LIVE_IP}"
        echo "  Production server: ${PROD_USER}@${PROD_IP}"
        echo ""
        read -p "Are you sure you want to continue? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[yY] ]]; then
            print_info "Deployment cancelled"
            exit 0
        fi
    fi

    # Resolve the prod docroot subdir once (v2 resolve_project) and export it so
    # the snapshot tar, the maintenance toggle and the updatedb --root all scope
    # to the same webroot the deploy overwrites.
    export OVERRIDE_SNAPSHOT
    local PROD_WEBROOT
    PROD_WEBROOT=$(get_deploy_webroot "$BASE_NAME")
    export PROD_WEBROOT

    # Execute deployment steps
    local step=1

    # Step 1: FAIL-CLOSED pre-deploy production snapshot (DBs + nginx + webroot).
    # -y NEVER skips it. --skip-backup is no longer a silent bypass: it is a
    # loud, ledgered override of the snapshot. Otherwise a snapshot failure
    # ABORTS before the destructive rsync --delete (prod_host_snapshot returns 1).
    if [ $step -ge $START_STEP ]; then
        if [ "$SKIP_BACKUP" == "true" ]; then
            _snapshot_override_ledger "$BASE_NAME" "--skip-backup passed; pre-deploy prod snapshot skipped"
            print_warning "--skip-backup — proceeding WITHOUT a pre-deploy production snapshot (ledgered)."
        else
            print_info "Step $step: Pre-deploy production snapshot"
            if ! backup_production "$BASE_NAME"; then
                print_error "Pre-deploy snapshot failed — aborting before the destructive rsync --delete."
                print_error "(Override at your own risk with --override-snapshot or --skip-backup, both ledgered.)"
                exit 1
            fi
        fi
    fi
    ((step++))

    if [ $step -ge $START_STEP ]; then
        print_info "Step $step: Export live configuration"
        export_live_config "$BASE_NAME"
    fi
    ((step++))

    # G3: maintenance mode wraps the destructive region (rsync --delete →
    # composer → updatedb). Enable ON here, BEFORE the sync; disable OFF only
    # after a clean updatedb (below). On ANY abort in the region the error paths
    # return without disabling it — members see a 503, not a broken half-deploy.
    # Gated so a --step resume PAST the DB step (START_STEP >= 6) never toggles it.
    local wrap_maint=false
    if [ 5 -ge "$START_STEP" ]; then
        wrap_maint=true
        # Fail-closed: if maintenance mode cannot be turned ON we must NOT run the
        # destructive rsync --delete (members would hit a half-populated webroot).
        if ! prod_maintenance_set "$BASE_NAME" "$PROD_IP" "$PROD_USER" "$PROD_PATH" "$PROD_WEBROOT" 1; then
            print_error "Could not enable maintenance mode — REFUSING the destructive rsync --delete (fail-closed)."
            print_error "Nothing was changed. Check the prod host is reachable and healthy, then re-run:"
            print_error "  pl server status"
            print_error "  pl live2prod ${BASE_NAME}"
            exit 1
        fi
    fi

    if [ $step -ge $START_STEP ]; then
        # CRITICAL fail-closed gate: the pre-deploy snapshot (step 1) is
        # START_STEP-gated, so a `-s 3` resume jumps straight here and would
        # otherwise run the rsync --delete with NO backstop. Assert a fresh
        # snapshot artifact exists on the prod host REGARDLESS of --step — and
        # re-take (or refuse) if it does not — before touching the webroot.
        if ! require_prod_snapshot "$BASE_NAME"; then
            print_error "Aborting before the destructive rsync --delete (no verified snapshot; maintenance left ON)."
            exit 1
        fi
        print_info "Step $step: Sync files"
        if ! sync_files "$BASE_NAME"; then
            print_error "File sync FAILED — aborting (maintenance mode left ON). Verify the prod host / rollback:"
            print_error "  pl rollback execute ${BASE_NAME} prod"
            exit 1
        fi
    fi
    ((step++))

    if [ $step -ge $START_STEP ]; then
        print_info "Step $step: Run composer"
        if ! run_composer "$BASE_NAME"; then
            print_error "Composer install FAILED — aborting (maintenance mode left ON)."
            print_error "Recover the prod host / rollback: pl rollback execute ${BASE_NAME} prod"
            exit 1
        fi
    fi
    ((step++))

    if [ $step -ge $START_STEP ]; then
        print_info "Step $step: Database updates"
        if ! run_db_updates "$BASE_NAME"; then
            print_error "Live DB updates FAILED — aborting (maintenance left ON)."
            print_error "Rollback: pl rollback execute ${BASE_NAME} prod"
            exit 1
        fi
    fi
    ((step++))

    # Destructive region complete + coherent — drop maintenance mode so prod
    # serves members again. Only reached on the success path (every error path
    # above exits without disabling it).
    if [ "$wrap_maint" == "true" ]; then
        # OFF failure is loudly reported inside prod_maintenance_set (503 risk);
        # tolerate its non-zero here so we still reach the cache/config steps.
        prod_maintenance_set "$BASE_NAME" "$PROD_IP" "$PROD_USER" "$PROD_PATH" "$PROD_WEBROOT" 0 || true
    fi

    if [ $step -ge $START_STEP ]; then
        print_info "Step $step: Import configuration"
        import_config "$BASE_NAME"
    fi
    ((step++))

    if [ $step -ge $START_STEP ]; then
        print_info "Step $step: Clear caches"
        clear_caches "$BASE_NAME"
    fi

    # Show elapsed time
    show_elapsed_time "Deployment"

    print_header "Deployment Complete"
    print_status "OK" "Live deployed to production successfully"

    # Stamp the canonical phase into a deploy manifest (nwp/ops#33)
    local deploy_manifest
    deploy_manifest=$(canonical_deploy_manifest "$BASE_NAME" "live2prod" \
        "override=${OVERRIDE_CANONICAL:-false}" 2>/dev/null) || true
    [ -n "$deploy_manifest" ] && print_info "Deploy manifest: $deploy_manifest"

    # Record the pair contract_version this half reached at prod (best-effort;
    # no-op for unpaired sites) so provider-first ordering can compare halves.
    pair_guard_record_success "$BASE_NAME" "prod" || true

    echo ""
    print_info "Production URL: https://$(get_prod_config "$BASE_NAME" "domain")"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
