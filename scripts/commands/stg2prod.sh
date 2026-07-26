#!/bin/bash
set -euo pipefail

################################################################################
# NWP Staging to Production Deployment Script
#
# Deploys changes from staging environment to Linode production server
# Uses SSH/rsync for file transfer and remote drush commands
#
# Usage: ./stg2prod.sh [OPTIONS] <sitename>
################################################################################

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"

# Source install-common for get_settings_value
if [ -f "$PROJECT_ROOT/lib/install-common.sh" ]; then
    source "$PROJECT_ROOT/lib/install-common.sh"
fi

# Source YAML library
if [ -f "$PROJECT_ROOT/lib/yaml-write.sh" ]; then
    source "$PROJECT_ROOT/lib/yaml-write.sh"
fi

# canonical.sh: canonicality-phase content-flow guards (nwp/ops#33)
source "$PROJECT_ROOT/lib/canonical.sh"
# deploy-gate.sh: hardware+signature gate on prod-writes (ADR-0028); no-op unless
# configured (ver) — the AI test tier (A14) is unaffected.
source "$PROJECT_ROOT/lib/deploy-gate.sh"
# pair.sh: paired-site versioning guard (ADR-0031/ops#75); no-op unless paired.
source "$PROJECT_ROOT/lib/pair.sh"

# Script start time
START_TIME=$(date +%s)

################################################################################
# Helper Functions
################################################################################

# Display elapsed time
show_elapsed_time() {
    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))
    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))
    local seconds=$((elapsed % 60))

    echo ""
    print_status "OK" "Deployment completed in $(printf "%02d:%02d:%02d" $hours $minutes $seconds)"
}

# Check if we should run a step
should_run_step() {
    local step_num=$1
    local start_step=${2:-1}

    if [ "$step_num" -ge "$start_step" ]; then
        return 0
    else
        return 1
    fi
}

# Build SSH command with optional key
# IdentitiesOnly=yes prevents ssh from offering every key in ~/.ssh/, which
# would otherwise trip fail2ban after 3 attempts on the production server.
build_ssh_cmd() {
    local ssh_opts="-o IdentitiesOnly=yes"

    if [ -n "$SSH_KEY" ]; then
        ssh_opts="$ssh_opts -i $SSH_KEY"
    fi

    echo "ssh $ssh_opts -p $SSH_PORT $SSH_USER@$SSH_HOST"
}

# Build rsync SSH options
# IdentitiesOnly=yes prevents ssh from offering every key in ~/.ssh/.
build_rsync_ssh_opts() {
    local opts="-e \"ssh -o IdentitiesOnly=yes -p $SSH_PORT\""

    if [ -n "$SSH_KEY" ]; then
        opts="-e \"ssh -o IdentitiesOnly=yes -i $SSH_KEY -p $SSH_PORT\""
    fi

    echo "$opts"
}

################################################################################
# Safety / Pre-Deploy Snapshots + Maintenance-Mode Wrap
#
# Ported from stg2live.sh (live_host_snapshot / live_maintenance_set, P0
# cutover-safety hardening 2026-07-19). stg2prod's prod leg was v1-era and did a
# bare destructive `rsync --delete` with NO pre-deploy snapshot and NO
# maintenance wrap. These bring the prod leg to parity: a fail-closed webroot
# snapshot BEFORE the --delete, and Drupal maintenance mode ON before the swap /
# OFF only after updatedb + cache rebuild SUCCEED.
################################################################################

# Ledger an --override-snapshot use so a destructive deploy that ran WITHOUT a
# proven webroot snapshot is auditable after the fact (mirrors stg2live).
_snapshot_override_ledger() {
    local base_name="$1"
    local reason="$2"
    local ledger_dir="${PROJECT_ROOT}/private/snapshots"
    mkdir -p "$ledger_dir" 2>/dev/null || true
    local who
    who=$(whoami 2>/dev/null || echo "unknown")
    echo "$(date -Iseconds 2>/dev/null || date)  ${who}  ${base_name}  stg2prod --override-snapshot  ${reason}" \
        >> "${ledger_dir}/${base_name}.log" 2>/dev/null || true
    print_status "WARN" "--override-snapshot ledgered: ${ledger_dir}/${base_name}.log"
}

# Take a fail-closed pre-deploy snapshot of the production host BEFORE the
# destructive rsync --delete: all databases (compressed dump) + /etc/nginx/conf.d/
# (tarball) + the WEBROOT ($PROD_PATH, excl. files/ + private/). Stored in the
# deploying user's home dir on the remote box. Idempotent within 1 hour (keyed on
# the webroot tar). The DB + nginx dumps WARN-and-continue; a WEBROOT snapshot
# failure ABORTS the deploy (return 1) unless --override-snapshot is set — without
# that tar a bad --delete/updatedb is unrecoverable (mirrors stg2live F2/P0-2).
prod_host_snapshot() {
    local base_name="$1"

    print_header "Pre-Deploy Snapshot"

    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)

    local sudo_prefix=""
    if [ "$SSH_USER" == "gitlab" ]; then
        sudo_prefix="sudo "
    fi

    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local dbs_file="nwp-snapshot-${base_name}-dbs-${ts}.sql.gz"
    local nginx_file="nwp-snapshot-${base_name}-nginx-${ts}.tar.gz"
    local webroot_file="nwp-snapshot-${base_name}-webroot-${ts}.tar.gz"

    # Check disk space first (bail if tighter than ~1 GB free in ~).
    local free_kb
    free_kb=$($ssh_cmd "df -k --output=avail ~ | tail -1" 2>/dev/null | tr -d ' ')
    if [ -n "$free_kb" ] && [ "$free_kb" -lt 1048576 ]; then
        print_status "WARN" "Production host has <1GB free in ~ (${free_kb}KB)."
        if [ "${OVERRIDE_SNAPSHOT:-false}" == "true" ]; then
            _snapshot_override_ledger "$base_name" "disk-tight (<1GB free in ~); snapshot skipped"
            print_status "WARN" "--override-snapshot set — proceeding WITHOUT a pre-deploy snapshot."
            return 0
        fi
        print_error "Refusing the destructive rsync --delete without a webroot snapshot (disk-tight)."
        print_error "Free disk on the production host, or re-run with --override-snapshot (ledgered)."
        return 1
    fi

    # Idempotent: skip if a WEBROOT snapshot from the last hour already exists.
    local recent
    recent=$($ssh_cmd "find ~ -maxdepth 1 -name 'nwp-snapshot-${base_name}-webroot-*.tar.gz' -mmin -60 2>/dev/null | head -1" 2>/dev/null)
    if [ -n "$recent" ]; then
        print_status "INFO" "Recent snapshot exists: $(basename "$recent")"
        print_status "INFO" "Skipping (idempotent within 1 hour)."
        return 0
    fi

    print_info "Snapshotting all databases..."
    if $ssh_cmd "${sudo_prefix}mysqldump --all-databases --single-transaction --quick --routines --triggers 2>/dev/null | gzip > ~/${dbs_file}"; then
        print_status "OK" "DB snapshot: ~/${dbs_file}"
    else
        print_status "WARN" "DB snapshot failed (continuing — verify prod state manually before destructive ops)"
    fi

    print_info "Snapshotting /etc/nginx/conf.d/..."
    if $ssh_cmd "${sudo_prefix}tar czf ~/${nginx_file} /etc/nginx/conf.d/ 2>/dev/null && ${sudo_prefix}chown ${SSH_USER}:${SSH_USER} ~/${nginx_file}"; then
        print_status "OK" "Nginx snapshot: ~/${nginx_file}"
    else
        print_status "WARN" "Nginx snapshot failed (continuing — verify prod state manually)"
    fi

    # FAIL-CLOSED webroot snapshot. Captures code (excl. the large, rsync-safe
    # uploads under files/ + private/, which the deploy never --deletes). Success
    # is decided by `test -s` on the tar (not tar's exit code, which can be 1 on a
    # benign "file changed as we read it" against a live site).
    print_info "Snapshotting production webroot (${PROD_PATH}, excl. files/ + private)..."
    if $ssh_cmd "${sudo_prefix}tar czf ~/${webroot_file} -C ${PROD_PATH} . --exclude=./sites/*/files --exclude=./*/sites/default/files --exclude=./private 2>/dev/null; ${sudo_prefix}chown ${SSH_USER}:${SSH_USER} ~/${webroot_file} 2>/dev/null; test -s ~/${webroot_file}"; then
        print_status "OK" "Webroot snapshot: ~/${webroot_file}"
    else
        print_status "WARN" "Webroot snapshot failed or empty (~/${webroot_file})."
        if [ "${OVERRIDE_SNAPSHOT:-false}" == "true" ]; then
            _snapshot_override_ledger "$base_name" "webroot snapshot failed/empty; --override-snapshot set"
            print_status "WARN" "--override-snapshot set — proceeding WITHOUT a webroot snapshot (ledgered)."
        else
            print_error "Refusing the destructive rsync --delete without a webroot snapshot."
            print_error "Investigate the production host, or re-run with --override-snapshot (ledgered)."
            return 1
        fi
    fi

    echo ""
    print_info "To restore from this snapshot if needed (manual):"
    echo "  ssh ${SSH_USER}@${SSH_HOST}"
    echo "  # restore DBs:     gunzip -c ~/${dbs_file} | ${sudo_prefix}mysql"
    echo "  # restore nginx:   ${sudo_prefix}tar xzf ~/${nginx_file} -C / && ${sudo_prefix}nginx -t && ${sudo_prefix}systemctl reload nginx"
    echo "  # restore webroot: ${sudo_prefix}tar xzf ~/${webroot_file} -C ${PROD_PATH}"
    echo ""

    return 0
}

# Drupal maintenance mode around the destructive swap (ported from stg2live G3).
# Enable BEFORE the rsync --delete so members never hit a half-populated webroot;
# disable only AFTER the post-sync updatedb + cache:rebuild SUCCEED. On a failed
# DISABLE the site is stuck at 503 — make it LOUD and return non-zero.
prod_maintenance_set() {
    local state=$1   # 1 = ON (maintenance), 0 = OFF (live)

    local label="ON"
    [ "$state" == "0" ] && label="OFF"

    if [ "$DRY_RUN" == "true" ]; then
        print_info "[dry-run] would set system.maintenance_mode=${state} on production"
        return 0
    fi

    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)

    print_info "Maintenance mode ${label} (system.maintenance_mode=${state})..."
    if $ssh_cmd "cd $PROD_PATH && drush state:set system.maintenance_mode ${state} --input-format=integer && drush cr" >/dev/null 2>&1; then
        print_status "OK" "Maintenance mode ${label}"
        return 0
    elif [ "$state" == "0" ]; then
        print_error "Could NOT disable maintenance mode — THE SITE MAY BE STUCK IN MAINTENANCE (503)."
        # NO pl VERB — `pl drush` is stg|live only and prod writes are operator-gated
        # (ADR-0024/0028), so the sanctioned recovery is the rollback verb.
        print_error "Recover through pl (prod writes are operator-gated — do NOT hand-ssh):"
        print_error "  pl rollback list ${SITENAME:-<site>}"
        print_error "  pl rollback execute ${SITENAME:-<site>} prod"
        print_error "  pl server status"
        return 1
    else
        # Failed to turn maintenance ON. Return non-zero so the caller REFUSES
        # to start the destructive rsync --delete (members would otherwise see a
        # half-populated webroot mid-deploy). Parity with live2prod.
        print_status "WARN" "Could not enable maintenance_mode=${state} (drush unavailable?)"
        return 1
    fi
}

# Get recipe value from nwp.yml
# F36 A-C2: yq-first per ADR-0015 (replaces legacy AWK YAML parser).
get_recipe_value() {
    local recipe=$1
    local key=$2
    local config_file="${3:-nwp.yml}"

    recipe="$recipe" key="$key" yq eval \
        '.recipes[env(recipe)] | .[env(key)] | select(tag == "!!str" or tag == "!!int" or tag == "!!float" or tag == "!!bool") // ""' \
        "$config_file" 2>/dev/null
}

# Get Linode server configuration
# F36 A-C2: yq-first per ADR-0015.
get_linode_config() {
    local server_name=$1
    local field=$2
    local config_file="${3:-nwp.yml}"

    server_name="$server_name" field="$field" yq eval \
        '.linode.servers[env(server_name)] | .[env(field)] | select(tag == "!!str" or tag == "!!int" or tag == "!!float" or tag == "!!bool") // ""' \
        "$PROJECT_ROOT/nwp.yml" 2>/dev/null
}

# Resolve the staging directory for a site (ops#79 finding 3).
# Prefers the v2 nested layout (sites/<name>/stg/, via resolve_project like
# stg2live does); falls back to the legacy flat layout (sites/<name>-stg/).
# Prints the absolute path, or returns 1 if no staging dir exists.
get_stg_dir() {
    local site=$1
    local base
    base=$(get_base_name "$site")

    # v2 nested layout: sites/<name>/stg/. resolve_project returns the
    # EXPECTED path for a v2 site even before stg exists, and returns the
    # flat dir itself for v1 sites — so require both that the dir exists
    # and that it is the stg env subdir before trusting it.
    local v2_dir
    v2_dir=$(resolve_project "$base" "stg" 2>/dev/null || true)
    if [ -n "$v2_dir" ] && [ -d "$v2_dir" ] && [[ "$v2_dir" == */stg ]]; then
        echo "$v2_dir"
        return 0
    fi

    # Legacy flat layout: sites/<name>-stg/
    if [ -d "$PROJECT_ROOT/sites/${base}-stg" ]; then
        echo "$PROJECT_ROOT/sites/${base}-stg"
        return 0
    fi

    return 1
}

# Check if site is in production mode
# Returns 0 if in prod mode, 1 if in dev mode
# Takes the resolved staging directory (v2 or legacy), not a site name.
is_prod_mode() {
    local stg_dir=$1

    if [ ! -d "$stg_dir" ]; then
        return 1
    fi

    local original_dir=$(pwd)
    cd "$stg_dir" || return 1

    # Check CSS preprocessing setting - 1 means prod mode
    local css_preprocess=$(ddev drush config:get system.performance css.preprocess 2>/dev/null | grep -oP "'\K[^']+")

    cd "$original_dir"

    if [ "$css_preprocess" == "1" ] || [ "$css_preprocess" == "true" ]; then
        return 0  # Is in prod mode
    else
        return 1  # Is in dev mode
    fi
}

# Ensure site is in production mode before deployment
# Takes the resolved staging dir (for the mode check) and the base site
# name (make.sh normalises <base>-stg for both v1 and v2 layouts).
ensure_prod_mode() {
    local stg_dir=$1
    local base_name=$2

    print_info "Checking if staging ($stg_dir) is in production mode..."

    if is_prod_mode "$stg_dir"; then
        print_status "OK" "Staging is already in production mode"
        return 0
    fi

    print_status "WARN" "Staging is in development mode"
    print_info "Switching to production mode..."

    # Run make.sh -py to switch to prod mode with auto-confirm
    if "${SCRIPT_DIR}/make.sh" -py "${base_name}-stg"; then
        print_status "OK" "Staging switched to production mode"
        return 0
    else
        print_error "Failed to switch staging to production mode"
        return 1
    fi
}

# Show help
show_help() {
    cat << EOF
${BOLD}NWP Staging to Production Deployment Script${NC}

${BOLD}USAGE:${NC}
    ./stg2prod.sh [OPTIONS] <sitename>

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -y, --yes               Skip confirmation prompts
    -v, --verbose           Show detailed rsync output
    -s N, --step=N          Resume from step N
    --dry-run               Show what would be done without making changes
    --code-only             Signal a code/config-only intent to the pair guard
                            (ADR-0031 D6) — satisfies the UID-lock rule for a paired
                            provider/consumer prod deploy.
    --override-pair         Proceed past a paired-site guard (ADR-0031). Ledgered in
                            private/pairs/<pair>.log. For paired sites only.
    --override-snapshot     Proceed with the destructive rsync --delete even when the
                            fail-closed pre-deploy WEBROOT snapshot could not be taken
                            (disk-tight or tar failed). The --delete is then
                            UNRECOVERABLE. Ledgered in private/snapshots/<site>.log.

${BOLD}ARGUMENTS:${NC}
    sitename                Base name of the staging site (production will be configured in nwp.yml)

${BOLD}EXAMPLES:${NC}
    ./stg2prod.sh nwp                     # Deploy nwp staging to production
    ./stg2prod.sh -y nwp                  # Deploy with auto-confirm
    ./stg2prod.sh --dry-run nwp           # Dry run - show what would happen
    ./stg2prod.sh -s 5 nwp                # Resume from step 5

${BOLD}ENVIRONMENT NAMING:${NC}
    Staging site: sites/<sitename>/stg/  (v2 layout; legacy sites/<sitename>-stg/ also supported)
    Production:   Configured in nwp.yml linode: section

${BOLD}DEPLOYMENT WORKFLOW:${NC}
    1. Validate deployment configuration
    2. Test SSH connection to production server
    3. Export configuration from staging
    4. Backup production (always in -y mode; never skipped)
    5. Fail-closed pre-deploy snapshot + maintenance ON, then rsync files
    6. Run composer install on production (failure aborts the deploy)
    7. Run database updates on production (failure aborts the deploy)
    8. Import configuration to production
    9. Verify and configure site email
   10. Reinstall modules on production (if configured)
   11. Clear cache and display production URL

${BOLD}CONFIGURATION:${NC}
    Production deployment configuration is stored in nwp.yml:
    - linode: section defines server credentials
    - Recipe prod_server, prod_domain, prod_path define deployment target
    - Or sites: section can override recipe-level settings

${BOLD}NOTE:${NC}
    - Staging site must exist with DDEV configured
    - SSH access to production server must be configured
    - Production server must have composer and drush installed

EOF
}

################################################################################
# Deployment Steps
################################################################################

# Step 1: Validate deployment configuration
validate_deployment() {
    local stg_dir=$1
    local base_name=$2

    print_header "Step 1: Validate Deployment Configuration"

    # Check if staging site exists (v2: sites/<name>/stg/, legacy: sites/<name>-stg/)
    if [ -z "$stg_dir" ] || [ ! -d "$stg_dir" ]; then
        print_error "Staging site not found for '$base_name' (expected sites/$base_name/stg/ or sites/$base_name-stg/)"
        return 1
    fi
    print_status "OK" "Staging site exists: $stg_dir"

    # Get recipe from sites: or use base_name
    local recipe=""
    if command -v yaml_get_site_field &> /dev/null; then
        recipe=$(yaml_get_site_field "$base_name" "recipe" "$PROJECT_ROOT/nwp.yml" 2>/dev/null)
    fi

    if [ -z "$recipe" ]; then
        recipe="$base_name"
        ocmsg "Using base name as recipe: $recipe"
    else
        ocmsg "Recipe from sites: $recipe"
    fi

    # Try to read production config from sites: first, then fall back to recipe
    local prod_server prod_domain prod_path prod_method

    if command -v yaml_get_site_field &> /dev/null; then
        # Check if site has production_config (F36 A-C2: yq-first per ADR-0015)
        prod_method=$(site="$base_name" yq eval \
            '.sites[env(site)].production_config.method | select(tag == "!!str" or tag == "!!int" or tag == "!!float" or tag == "!!bool") // ""' \
            "$PROJECT_ROOT/nwp.yml" 2>/dev/null)
    fi

    # If not in sites:, read from recipe
    if [ -z "$prod_method" ]; then
        prod_method=$(get_recipe_value "$recipe" "prod_method" "$PROJECT_ROOT/nwp.yml")
        prod_server=$(get_recipe_value "$recipe" "prod_server" "$PROJECT_ROOT/nwp.yml")
        prod_domain=$(get_recipe_value "$recipe" "prod_domain" "$PROJECT_ROOT/nwp.yml")
        prod_path=$(get_recipe_value "$recipe" "prod_path" "$PROJECT_ROOT/nwp.yml")
    fi

    if [ -z "$prod_method" ]; then
        print_error "No production deployment method configured for recipe '$recipe'"
        echo "Add 'prod_method: rsync' to the recipe in nwp.yml"
        return 1
    fi

    if [ "$prod_method" != "rsync" ]; then
        print_error "Only rsync deployment method is supported (found: $prod_method)"
        return 1
    fi

    print_status "OK" "Deployment method: $prod_method"

    # Validate server configuration
    if [ -z "$prod_server" ]; then
        print_error "No prod_server configured for recipe '$recipe'"
        return 1
    fi

    # Get server details from linode: section
    local ssh_user=$(get_linode_config "$prod_server" "ssh_user" "$PROJECT_ROOT/nwp.yml")
    local ssh_host=$(get_linode_config "$prod_server" "ssh_host" "$PROJECT_ROOT/nwp.yml")
    local ssh_port=$(get_linode_config "$prod_server" "ssh_port" "$PROJECT_ROOT/nwp.yml")
    local ssh_key=$(get_linode_config "$prod_server" "ssh_key" "$PROJECT_ROOT/nwp.yml")

    if [ -z "$ssh_user" ] || [ -z "$ssh_host" ]; then
        print_error "Server '$prod_server' not found in linode: section of nwp.yml"
        return 1
    fi

    print_status "OK" "Server: $prod_server ($ssh_user@$ssh_host:${ssh_port:-22})"

    if [ -n "$ssh_key" ]; then
        # Expand ~ to home directory
        ssh_key="${ssh_key/#\~/$HOME}"
        if [ ! -f "$ssh_key" ]; then
            print_error "SSH key not found: $ssh_key"
            return 1
        fi
        print_status "OK" "SSH key: $ssh_key"
    fi

    if [ -z "$prod_path" ]; then
        print_error "No prod_path configured for recipe '$recipe'"
        return 1
    fi

    print_status "OK" "Remote path: $prod_path"

    if [ -n "$prod_domain" ]; then
        print_status "OK" "Domain: $prod_domain"
    fi

    # Export for use in other functions
    export PROD_RECIPE="$recipe"
    export PROD_SERVER="$prod_server"
    export PROD_DOMAIN="$prod_domain"
    export PROD_PATH="$prod_path"
    export SSH_USER="$ssh_user"
    export SSH_HOST="$ssh_host"
    export SSH_PORT="${ssh_port:-22}"
    export SSH_KEY="$ssh_key"

    return 0
}

# Step 2: Test SSH connection
test_ssh_connection() {
    print_header "Step 2: Test SSH Connection"

    local ssh_cmd=$(build_ssh_cmd)

    ocmsg "Testing SSH: $ssh_cmd"

    if $ssh_cmd "echo 'SSH connection successful'" >/dev/null 2>&1; then
        print_status "OK" "SSH connection to $SSH_USER@$SSH_HOST successful"
    else
        print_error "SSH connection failed to $SSH_USER@$SSH_HOST"
        echo "Please ensure:"
        echo "  1. SSH keys are configured"
        echo "  2. Server is reachable"
        echo "  3. User has appropriate permissions"
        return 1
    fi

    return 0
}

# Step 3: Export configuration from staging
export_config_staging() {
    local stg_dir=$1

    print_header "Step 3: Export Configuration from Staging"

    local original_dir=$(pwd)
    cd "$stg_dir" || {
        print_error "Cannot access staging site: $stg_dir"
        return 1
    }

    ocmsg "Exporting configuration..."
    if ddev drush config:export -y >/dev/null 2>&1; then
        print_status "OK" "Configuration exported from staging"
    else
        print_status "WARN" "Configuration export had warnings (may be no changes)"
    fi

    cd "$original_dir"
    return 0
}

# Step 4: Backup production
# The pre-deploy full-copy backup. In -y (AUTO_YES) mode this now ALWAYS runs —
# it must NEVER be skipped just because prompts were suppressed (a -y prod deploy
# is exactly when an unattended safety copy matters most). Only an interactive
# operator may decline. The fail-closed webroot snapshot (prod_host_snapshot, run
# at the top of sync_files) is the hard --delete backstop; this cp is the
# belt-and-suspenders full copy incl. files/.
backup_production() {
    print_header "Step 4: Backup Production"

    if [ "$DRY_RUN" == "true" ]; then
        print_status "INFO" "DRY RUN: Would create a full production backup copy"
        return 0
    fi

    # -y mode always backs up; interactive mode prompts (default Yes).
    local do_backup="y"
    if [ "$AUTO_YES" != "true" ]; then
        echo -n "Create production backup before deployment? [Y/n]: "
        read do_backup
        do_backup="${do_backup:-y}"
    else
        print_status "INFO" "Auto-yes mode: creating production backup (never skipped)"
    fi

    if [[ ! "$do_backup" =~ ^[Yy] ]]; then
        print_status "INFO" "Skipping production backup (operator declined)"
        return 0
    fi

    local backup_name="backup-$(date +%Y%m%d-%H%M%S)"
    local ssh_cmd=$(build_ssh_cmd)

    ocmsg "Creating backup: $backup_name"

    if $ssh_cmd "cd $(dirname $PROD_PATH) && cp -r $(basename $PROD_PATH) ${backup_name}" 2>&1; then
        print_status "OK" "Backup created: $backup_name"
    else
        print_status "WARN" "Backup creation failed (fail-closed webroot snapshot still applies before rsync)"
    fi

    return 0
}

# Step 5: Sync files to production
sync_files() {
    local stg_dir=$1
    local base_name=$2

    print_header "Step 5: Sync Files to Production"

    # Fail-closed pre-deploy snapshot + maintenance-mode enable BEFORE the
    # destructive rsync --delete (parity with stg2live). A snapshot failure
    # ABORTS here, before anything is overwritten; maintenance ON keeps members
    # off a half-populated webroot during the swap. Skipped on --dry-run (no
    # writes to the production host).
    if [ "$DRY_RUN" != "true" ]; then
        if ! prod_host_snapshot "$base_name"; then
            print_error "Pre-deploy snapshot failed — aborting before the destructive rsync --delete."
            print_error "(Override at your own risk with --override-snapshot, which is ledgered.)"
            return 1
        fi
        if ! prod_maintenance_set 1; then
            print_error "REFUSING destructive rsync --delete — maintenance mode not enabled."
            print_error "(Members would otherwise see a half-populated webroot mid-deploy.)"
            return 1
        fi
    else
        print_info "[dry-run] skipping pre-deploy snapshot + maintenance-mode enable (would write to production)"
    fi

    # Build rsync exclude list
    local excludes=(
        "--exclude=.git"
        "--exclude=.ddev"
        "--exclude=*/settings.php"
        "--exclude=*/settings.local.php"
        "--exclude=*/services.yml"
        "--exclude=*/files/*"
        "--exclude=private/*"
        "--exclude=node_modules"
        "--exclude=.env"
        # Never sync (and never --delete) per-host OAuth signing keys. They live
        # at site-root (e.g. oauth-keys/), not under files/, so without this a
        # stg→prod sync would replace prod's keypair with staging's (or delete
        # it), invalidating every outstanding ss OIDC token → SSO breaks (ops#63).
        "--exclude=oauth-keys/*"
        "--exclude=*/oauth-keys/*"
        "--exclude=keys/*"
    )

    # Build SSH options for rsync
    # IdentitiesOnly=yes prevents fail2ban lockouts from key spraying.
    local ssh_opts="ssh -o IdentitiesOnly=yes -p $SSH_PORT"
    if [ -n "$SSH_KEY" ]; then
        ssh_opts="ssh -o IdentitiesOnly=yes -i $SSH_KEY -p $SSH_PORT"
    fi

    # Rsync (quiet by default, verbose with -v flag)
    local rsync_opts="-az"
    if [ "${VERBOSE:-false}" == "true" ]; then
        rsync_opts="-avz"
    fi

    local rsync_cmd="rsync $rsync_opts --delete -e \"$ssh_opts\" ${excludes[@]} $stg_dir/ $SSH_USER@$SSH_HOST:$PROD_PATH/"

    ocmsg "Rsync command: $rsync_cmd"

    if [ "$DRY_RUN" == "true" ]; then
        print_status "INFO" "DRY RUN: Would execute: $rsync_cmd"
        return 0
    fi

    echo -e "${CYAN}Syncing files to production...${NC}"
    if eval "$rsync_cmd"; then
        print_status "OK" "Files synced to production"
    else
        print_error "File sync failed (maintenance mode left ON — verify the production host / rollback)."
        return 1
    fi

    return 0
}

# Step 6: Run composer install on production
run_composer_production() {
    print_header "Step 6: Run Composer Install on Production"

    local ssh_cmd=$(build_ssh_cmd)

    if [ "$DRY_RUN" == "true" ]; then
        print_status "INFO" "DRY RUN: Would run composer install on production"
        return 0
    fi

    ocmsg "Running composer install..."
    # FAIL-LOUD (was demoted to a WARN): a failed composer install leaves the
    # webroot with code that does not match its dependencies (a PHP>=8.3 build
    # served under the wrong deps is exactly how nwc go-live 500'd). Abort so the
    # caller leaves maintenance ON and points at rollback. pipefail (set at top)
    # makes the `| tail` pipeline carry composer's real exit code.
    if $ssh_cmd "cd $PROD_PATH && composer install --no-dev --optimize-autoloader" 2>&1 | tail -10; then
        print_status "OK" "Composer install completed on production"
    else
        print_error "Composer install FAILED on production — dependencies do not match the deployed code."
        return 1
    fi

    return 0
}

# Step 7: Run database updates on production
run_db_updates_production() {
    print_header "Step 7: Run Database Updates on Production"

    local ssh_cmd=$(build_ssh_cmd)

    if [ "$DRY_RUN" == "true" ]; then
        print_status "INFO" "DRY RUN: Would run database updates on production"
        return 0
    fi

    ocmsg "Running database updates..."
    # FAIL-LOUD (was demoted to a WARN): a silently-failed updatedb leaves schema
    # hooks unrun and the code/DB schema mismatched. Abort so the caller leaves
    # maintenance ON and points at rollback rather than serving a half-updated
    # schema (2026-07-21 stg2live incident, ported here). pipefail carries drush's
    # real exit code through the `| tail`.
    if $ssh_cmd "cd $PROD_PATH && drush updatedb -y" 2>&1 | tail -10; then
        print_status "OK" "Database updates completed on production"
    else
        print_error "drush updatedb FAILED on production — schema hooks NOT applied. Maintenance mode left ON."
        return 1
    fi

    return 0
}

# Step 8: Import configuration to production
import_config_production() {
    print_header "Step 8: Import Configuration to Production"

    local ssh_cmd=$(build_ssh_cmd)

    if [ "$DRY_RUN" == "true" ]; then
        print_status "INFO" "DRY RUN: Would import configuration on production"
        return 0
    fi

    # GUARD (ops#63): config:import is fail-closed SKIPPED unless explicitly
    # opted in. No NWP site tracks its Drupal config as code today — the sync dir
    # is gitignored and stg's export never reaches prod through the rsync
    # boundary — so importing whatever stale/empty snapshot prod happens to hold
    # would REVOKE runtime-only config (e.g. nwc's `grant simple_oauth codes`,
    # signing-key paths, the error-report token) and silently break live SSO.
    # Opt in per run with NWP_ALLOW_CONFIG_IMPORT=1 once the site has a trusted
    # tracked config/sync baseline (the real fix is ops#63 config-as-code). Also:
    # a failed import is no longer demoted to a warning — it fails the deploy.
    if [ "${NWP_ALLOW_CONFIG_IMPORT:-0}" != "1" ]; then
        print_status "SKIP" "config:import skipped (set NWP_ALLOW_CONFIG_IMPORT=1 to enable — see ops#63)"
    else
        ocmsg "Importing configuration..."
        if $ssh_cmd "cd $PROD_PATH && drush config:import -y" 2>&1 | tail -10; then
            print_status "OK" "Configuration imported to production"
        else
            print_error "Configuration import FAILED — aborting (config:import must not partially apply)"
            return 1
        fi
    fi

    return 0
}

# Step 9: Verify and configure site email
verify_site_email() {
    local base_name=$1

    print_header "Step 9: Verify Site Email Configuration"

    # Check if email auto-configure is enabled
    local auto_configure
    auto_configure=$(get_settings_value "email.auto_configure" "true" 2>/dev/null)
    if [ "$auto_configure" != "true" ]; then
        print_status "INFO" "Email auto-configure disabled in settings"
        return 0
    fi

    # Get email domain and admin email
    local email_domain
    email_domain=$(get_settings_value "email.domain" "" 2>/dev/null)
    if [ -z "$email_domain" ]; then
        email_domain=$(get_settings_value "url" "nwpcode.org" 2>/dev/null)
    fi

    local admin_email
    admin_email=$(get_settings_value "email.admin_email" "" 2>/dev/null)
    if [ -z "$admin_email" ]; then
        print_status "WARN" "No admin_email configured in settings.email"
        print_info "Email verification skipped"
        return 0
    fi

    local site_email="${base_name}@${email_domain}"
    local gitlab_host="git.${email_domain}"

    print_info "Expected site email: $site_email"
    print_info "Forward to: $admin_email"

    if [ "$DRY_RUN" == "true" ]; then
        print_status "INFO" "DRY RUN: Would verify email configuration"
        return 0
    fi

    # Check if email forwarding exists on mail server
    local ssh_cmd=$(build_ssh_cmd)
    local mail_ssh_user="gitlab"  # Default user for mail server

    # Try to check if the forwarding alias exists
    print_info "Checking email forwarding on $gitlab_host..."
    local alias_exists=false

    if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes -o ConnectTimeout=5 "${mail_ssh_user}@${gitlab_host}" \
        "grep -q '^${site_email}' /etc/postfix/virtual 2>/dev/null" 2>/dev/null; then
        alias_exists=true
        print_status "OK" "Email forwarding exists: $site_email"

        # Verify it forwards to the correct address
        local current_forward
        current_forward=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${mail_ssh_user}@${gitlab_host}" \
            "grep '^${site_email}' /etc/postfix/virtual 2>/dev/null | awk '{print \$2}'" 2>/dev/null)

        if [ "$current_forward" != "$admin_email" ] && [ -n "$current_forward" ]; then
            print_status "WARN" "Forward address mismatch: $current_forward (expected: $admin_email)"
            print_info "Updating email forwarding..."

            # Update the forwarding
            # F23 Phase 8: email scripts moved to servers/<server>/email/. Legacy fallback retained.
            local email_script="${PROJECT_ROOT}/servers/nwpcode/email/add_site_email.sh"
            [ -f "$email_script" ] || email_script="${PROJECT_ROOT}/email/add_site_email.sh"
            if [ -f "$email_script" ]; then
                if scp $(nwp_ssh_opts "$base_name") -q "$email_script" "${mail_ssh_user}@${gitlab_host}:/tmp/add_site_email.sh" 2>/dev/null; then
                    if ssh $(nwp_ssh_opts "$base_name") "${mail_ssh_user}@${gitlab_host}" \
                        "sudo bash /tmp/add_site_email.sh ${base_name} --forward-only ${admin_email} -y && rm /tmp/add_site_email.sh" 2>/dev/null; then
                        print_status "OK" "Email forwarding updated: $site_email -> $admin_email"
                    else
                        print_status "WARN" "Could not update email forwarding"
                    fi
                fi
            fi
        else
            print_status "OK" "Email forwards to: $current_forward"
        fi
    else
        print_status "WARN" "Email forwarding not configured"
        print_info "Creating email forwarding..."

        # Create the forwarding alias
        # F23 Phase 8: email scripts moved to servers/<server>/email/. Legacy fallback retained.
        local email_script="${PROJECT_ROOT}/servers/nwpcode/email/add_site_email.sh"
        [ -f "$email_script" ] || email_script="${PROJECT_ROOT}/email/add_site_email.sh"
        if [ -f "$email_script" ]; then
            if scp $(nwp_ssh_opts "$base_name") -q "$email_script" "${mail_ssh_user}@${gitlab_host}:/tmp/add_site_email.sh" 2>/dev/null; then
                if ssh $(nwp_ssh_opts "$base_name") "${mail_ssh_user}@${gitlab_host}" \
                    "sudo bash /tmp/add_site_email.sh ${base_name} --forward-only ${admin_email} -y && rm /tmp/add_site_email.sh" 2>/dev/null; then
                    print_status "OK" "Email forwarding created: $site_email -> $admin_email"
                else
                    print_status "WARN" "Could not create email forwarding (may need manual setup)"
                fi
            else
                print_status "WARN" "Could not copy email script to mail server"
            fi
        else
            print_status "WARN" "Email setup script not found: $email_script"
        fi
    fi

    # Verify Drupal site email matches
    print_info "Verifying Drupal site email..."
    local current_drupal_email
    current_drupal_email=$($ssh_cmd "cd $PROD_PATH && drush config:get system.site mail --format=string 2>/dev/null" 2>/dev/null)

    if [ "$current_drupal_email" == "$site_email" ]; then
        print_status "OK" "Drupal site email correct: $current_drupal_email"
    elif [ -n "$current_drupal_email" ]; then
        print_status "WARN" "Drupal site email mismatch: $current_drupal_email (expected: $site_email)"
        print_info "Updating Drupal site email..."

        if $ssh_cmd "cd $PROD_PATH && drush config:set system.site mail '${site_email}' -y" 2>/dev/null; then
            print_status "OK" "Drupal site email updated to: $site_email"
        else
            print_status "WARN" "Could not update Drupal site email"
        fi
    else
        print_info "Could not read current Drupal site email"
    fi

    return 0
}

# Step 10: Reinstall modules on production
reinstall_modules_production() {
    print_header "Step 10: Reinstall Modules (if configured)"

    if [ "$DRY_RUN" == "true" ]; then
        print_status "INFO" "DRY RUN: Would reinstall modules on production"
        return 0
    fi

    # Read reinstall_modules from recipe configuration
    local reinstall_modules=$(get_recipe_value "$PROD_RECIPE" "reinstall_modules" "$PROJECT_ROOT/nwp.yml")

    if [ -z "$reinstall_modules" ]; then
        print_status "INFO" "No modules configured for reinstallation in recipe '$PROD_RECIPE'"
        return 0
    fi

    ocmsg "Modules to reinstall: $reinstall_modules"

    local module_array=($reinstall_modules)
    local total_modules=${#module_array[@]}
    local success_count=0
    local fail_count=0

    echo -e "Found ${BOLD}$total_modules${NC} module(s) to reinstall: ${BOLD}$reinstall_modules${NC}"
    echo ""

    local ssh_cmd=$(build_ssh_cmd)

    for module in "${module_array[@]}"; do
        echo -e "${CYAN}Processing module: ${BOLD}$module${NC}"

        # Check if enabled
        local is_enabled=$($ssh_cmd "cd $PROD_PATH && drush pm:list --filter=\"$module\" --status=enabled --format=list 2>/dev/null | grep -c \"^$module$\"")

        if [ "$is_enabled" -eq 0 ]; then
            print_status "INFO" "Module '$module' not enabled, skipping"
            echo ""
            continue
        fi

        # Uninstall
        if $ssh_cmd "cd $PROD_PATH && drush pm:uninstall -y $module" >/dev/null 2>&1; then
            print_status "OK" "Uninstalled '$module'"
        else
            print_status "FAIL" "Failed to uninstall '$module'"
            fail_count=$((fail_count + 1))
            echo ""
            continue
        fi

        # Re-enable
        if $ssh_cmd "cd $PROD_PATH && drush pm:enable -y $module" >/dev/null 2>&1; then
            print_status "OK" "Re-enabled '$module'"
            success_count=$((success_count + 1))
        else
            print_status "FAIL" "Failed to re-enable '$module'"
            fail_count=$((fail_count + 1))
        fi

        echo ""
    done

    echo -e "${BOLD}Module Reinstallation Summary:${NC}"
    echo -e "  Total:    $total_modules"
    echo -e "  ${GREEN}Success:  $success_count${NC}"
    if [ $fail_count -gt 0 ]; then
        echo -e "  ${RED}Failed:   $fail_count${NC}"
    fi
    echo ""

    return 0
}

# Step 11: Clear cache, disable maintenance, display URL
clear_cache_and_display() {
    print_header "Step 11: Clear Cache, Disable Maintenance, Display Production URL"

    local ssh_cmd=$(build_ssh_cmd)

    if [ "$DRY_RUN" == "true" ]; then
        print_status "INFO" "DRY RUN: Would clear cache + disable maintenance on production"
    else
        ocmsg "Clearing cache..."
        # Maintenance mode is dropped ONLY AFTER cache:rebuild succeeds (and only
        # this far because updatedb, step 7, already succeeded fail-loud). A failed
        # cache rebuild leaves maintenance ON (site at 503) rather than exposing a
        # stale/incoherent cache — fail-loud so the operator recovers.
        if $ssh_cmd "cd $PROD_PATH && drush cache:rebuild" >/dev/null 2>&1; then
            print_status "OK" "Cache cleared on production"
            if ! prod_maintenance_set 0; then
                return 1
            fi
        else
            print_error "Cache rebuild FAILED — leaving maintenance mode ON (site stays at 503 until recovered)."
            # NO pl VERB — `pl drush` is stg|live only; prod is operator-gated.
            print_error "Recover through pl (prod writes are operator-gated — do NOT hand-ssh):"
            print_error "  pl rollback list ${SITENAME:-<site>}"
            print_error "  pl rollback execute ${SITENAME:-<site>} prod"
            print_error "  pl server status"
            return 1
        fi
    fi

    echo ""
    if [ -n "$PROD_DOMAIN" ]; then
        print_status "OK" "Production site: ${BOLD}https://$PROD_DOMAIN${NC}"
    else
        print_status "OK" "Production site deployed to: ${BOLD}$SSH_HOST:$PROD_PATH${NC}"
    fi

    return 0
}

################################################################################
# Main Deployment Function
################################################################################

deploy_stg2prod() {
    local stg_dir=$1
    local base_name=$2
    local auto_yes=$3
    local start_step=${4:-1}
    local dry_run=${5:-false}

    print_header "NWP Staging to Production Deployment"
    echo -e "${BOLD}Staging:${NC}    $stg_dir"
    echo -e "${BOLD}Site:${NC}       $base_name"
    echo ""

    # Validate first to get configuration
    if should_run_step 1 "$start_step"; then
        if ! validate_deployment "$stg_dir" "$base_name"; then
            return 1
        fi
    fi

    # Confirm deployment
    if [ "$auto_yes" != "true" ] && [ "$dry_run" != "true" ] && [ "$start_step" -eq 1 ]; then
        echo -e "${YELLOW}${BOLD}WARNING: This will deploy to PRODUCTION!${NC}"
        echo -e "${YELLOW}Server: ${BOLD}$SSH_USER@$SSH_HOST${NC}"
        echo -e "${YELLOW}Path:   ${BOLD}$PROD_PATH${NC}"
        if [ -n "$PROD_DOMAIN" ]; then
            echo -e "${YELLOW}Domain: ${BOLD}$PROD_DOMAIN${NC}"
        fi
        echo ""
        echo -n "Continue with production deployment? [y/N]: "
        read confirm
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            print_info "Deployment cancelled"
            return 1
        fi
    fi

    # Execute deployment steps
    if should_run_step 2 "$start_step"; then
        if ! test_ssh_connection; then
            return 1
        fi
    fi

    if should_run_step 3 "$start_step"; then
        export_config_staging "$stg_dir"
    fi

    if should_run_step 4 "$start_step"; then
        backup_production
    fi

    if should_run_step 5 "$start_step"; then
        # sync_files takes the fail-closed pre-deploy snapshot + enables
        # maintenance mode before the destructive rsync --delete.
        if ! sync_files "$stg_dir" "$base_name"; then
            return 1
        fi
    fi

    if should_run_step 6 "$start_step"; then
        # Composer failure is now fail-loud: abort with maintenance left ON.
        if ! run_composer_production; then
            print_error "Composer install FAILED — aborting (maintenance left ON). Rollback: pl rollback execute ${base_name} prod"
            return 1
        fi
    fi

    if should_run_step 7 "$start_step"; then
        # updatedb failure is now fail-loud: abort with maintenance left ON.
        if ! run_db_updates_production; then
            print_error "Live DB updates FAILED — aborting (maintenance left ON). Rollback: pl rollback execute ${base_name} prod"
            return 1
        fi
    fi

    if should_run_step 8 "$start_step"; then
        if ! import_config_production; then
            print_error "Config import FAILED — aborting (maintenance left ON). Rollback: pl rollback execute ${base_name} prod"
            return 1
        fi
    fi

    if should_run_step 9 "$start_step"; then
        verify_site_email "$base_name"
    fi

    if should_run_step 10 "$start_step"; then
        reinstall_modules_production
    fi

    if should_run_step 11 "$start_step"; then
        # Drops maintenance mode ONLY AFTER cache:rebuild succeeds.
        if ! clear_cache_and_display; then
            return 1
        fi
    fi

    return 0
}

################################################################################
# Main Function
################################################################################

main() {
    # Parse options
    local DEBUG=false
    local AUTO_YES=false
    local DRY_RUN=false
    local VERBOSE=false
    local START_STEP=1
    local SITENAME=""

    local OVERRIDE_SNAPSHOT=false

    # Export for use in functions
    export DEBUG AUTO_YES DRY_RUN VERBOSE OVERRIDE_SNAPSHOT

    local OVERRIDE_CANONICAL=false
    local OVERRIDE_PAIR=false
    local CODE_ONLY=false

    local OPTIONS=hdyvs:
    local LONGOPTS=help,debug,yes,verbose,step:,dry-run,override-canonical,override-pair,code-only,override-snapshot

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
            -y|--yes)
                AUTO_YES=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --override-canonical)
                OVERRIDE_CANONICAL=true
                shift
                ;;
            --override-pair)
                OVERRIDE_PAIR=true
                shift
                ;;
            --code-only)
                CODE_ONLY=true
                shift
                ;;
            --override-snapshot)
                OVERRIDE_SNAPSHOT=true
                shift
                ;;
            -s|--step)
                START_STEP="$2"
                shift 2
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

    # Get sitename
    if [ $# -lt 1 ]; then
        print_error "Missing site name"
        echo ""
        show_help
        exit 1
    fi

    SITENAME="$1"

    # Resolve the staging directory (ops#79 finding 3). Accepts a bare site
    # name or a legacy -stg/_stg-suffixed name; prefers the v2 nested layout
    # (sites/<name>/stg/), falls back to legacy flat (sites/<name>-stg/).
    local base_name
    base_name=$(get_base_name "$SITENAME")
    local STG_DIR
    if ! STG_DIR=$(get_stg_dir "$SITENAME"); then
        print_error "No staging environment found for '$base_name'"
        print_info "Expected sites/$base_name/stg/ (v2) or sites/$base_name-stg/ (legacy)."
        print_info "Create staging first: pl dev2stg $base_name"
        exit 1
    fi

    ocmsg "Staging dir: $STG_DIR"
    ocmsg "Auto yes: $AUTO_YES"
    ocmsg "Dry run: $DRY_RUN"
    ocmsg "Start step: $START_STEP"

    # Canonicality guard (nwp/ops#33): under canonical: prod, content changes
    # happen on prod ONLY — a stg→prod push would clobber the canonical source.
    if ! canonical_guard_content_push "$base_name" "prod" "$OVERRIDE_CANONICAL" "stg2prod"; then
        exit 1
    fi
    if ! canonical_enforce_branch_policy "$base_name" "deploy"; then
        exit 1
    fi
    # Maturity guard (P67/ops#48): code-flow class gate
    if ! maturity_guard_deploy "$base_name" "stg2prod"; then
        exit 1
    fi
    # Pair guard (ADR-0031/ops#75): refuse a paired promotion that breaks
    # provider-first ordering, the D6 UID-lock/--code-only rule, or a red pair.
    # No-op for unpaired sites; fail-closed on a declared-but-missing contract.
    if ! pair_guard "$base_name" "prod" "stg2prod" "$CODE_ONLY" "$OVERRIDE_PAIR"; then
        exit 1
    fi

    # Hardware+signature gate on the production write (ADR-0028). No-op on the
    # test tier (unconfigured); on ver it requires a live Solo touch.
    if [ "${DRY_RUN:-false}" != "true" ]; then
        # stg2prod rsyncs the staging webroot only — it pushes NO database (no
        # dump/import step exists on this leg). The old summary that claimed both
        # files and the database mis-described the write this gate authorizes.
        deploy_gate_require "$base_name" "prod" \
            "rsync staging files → production webroot (--delete); NO database push" || exit 1
    fi

    # Ensure staging site is in production mode before deploying to prod
    if [ "$DRY_RUN" != "true" ] && [ -d "$STG_DIR" ]; then
        if ! ensure_prod_mode "$STG_DIR" "$base_name"; then
            print_error "Cannot deploy to production without staging site in production mode"
            exit 1
        fi
    fi

    # Run deployment
    if deploy_stg2prod "$STG_DIR" "$base_name" "$AUTO_YES" "$START_STEP" "$DRY_RUN"; then
        # Record the pair contract_version this half reached at prod (best-effort;
        # no-op for unpaired sites and dry runs).
        if [ "${DRY_RUN:-false}" != "true" ]; then
            pair_guard_record_success "$base_name" "prod" || true
        fi
        show_elapsed_time
        exit 0
    else
        print_error "Deployment to production failed: $SITENAME"
        exit 1
    fi
}

# Run main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
