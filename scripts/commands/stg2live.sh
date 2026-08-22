#!/bin/bash
set -euo pipefail

################################################################################
# NWP Staging to Live Deployment Script
#
# Deploys staging site to live server (provisioned by live.sh)
#
# Features:
#   - File synchronization via rsync
#   - Database deployment (P34 - requires P33/P35 for full integration)
#   - Security module installation
#   - Permission management
#   - Cache clearing
#
# Usage: ./stg2live.sh [OPTIONS] <sitename>
################################################################################

# Get script directory (from symlink location, not resolved target)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Source shared libraries
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/ssh.sh"
# rollback.sh sets ROLLBACK_DIR=${SCRIPT_DIR}/.rollback. SCRIPT_DIR
# (set at the top of this file) is scripts/commands/ — same dir the
# rollback dispatcher uses, so both writers/readers share one registry.
source "$PROJECT_ROOT/lib/rollback.sh"
# canonical.sh: canonicality-phase content-flow guards (nwp/ops#33)
source "$PROJECT_ROOT/lib/canonical.sh"
# deploy-gate.sh: hardware+signature gate on prod-writes (NWP-ADR-0028); no-op unless
# configured (ver) — the AI test tier (A14) is unaffected.
source "$PROJECT_ROOT/lib/deploy-gate.sh"
# pair.sh: paired-site versioning guard (NWP-ADR-0031/ops#75); no-op unless the site
# is declared paired (paired_with:) — fail-closed on a declared-but-missing contract.
source "$PROJECT_ROOT/lib/pair.sh"
# config-drift.sh: Vortex-style config-as-code gate around live `drush updatedb`
# (report P3 / ops#63); OFF unless the site opts in (config.drift_gate: true or
# NWP_CONFIG_DRIFT_GATE=1), so it cannot alter current deploys until adopted.
source "$PROJECT_ROOT/lib/config-drift.sh"

# Source install-common for get_settings_value
if [ -f "$PROJECT_ROOT/lib/install-common.sh" ]; then
    source "$PROJECT_ROOT/lib/install-common.sh"
fi

# Script start time
START_TIME=$(date +%s)

################################################################################
# Helper Functions
################################################################################

# Get staging directory path (F23: v2 sites/<name>/stg/)
get_stg_dir() {
    local site=$1
    local base=$(get_base_name "$site")
    resolve_project "$base" "stg"
}

# Get base domain from nwp.yml settings.url (fallback to nwpcode.org)
get_base_domain() {
    local root="${PROJECT_ROOT:-$HOME/nwp}"
    local global_config="$root/nwp.yml"
    if [[ -f "$global_config" ]] && command -v yq &>/dev/null; then
        local url
        url=$(yq eval '.settings.url // ""' "$global_config" 2>/dev/null)
        [[ -n "$url" && "$url" != "null" ]] && { echo "$url"; return; }
    fi
    echo "nwpcode.org"
}

# Get live server config (F23: reads per-site .nwp.yml, falls back to nwp.yml)
get_live_config() {
    local sitename="$1"
    local field="$2"
    local base=$(get_base_name "$sitename")

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
        remote_path)
            # D18 (ops#157): honour `remote_dir` as scripts/commands/site.sh
            # already does — some sites declare only remote_dir (the /var/www
            # subdir) and no explicit remote_path. Reading only remote_path
            # would resolve empty and the caller would fall back to
            # /var/www/<base>, which for a remote_dir site is the WRONG (often
            # nonexistent) tree. Explicit remote_path always wins; otherwise
            # derive it from remote_dir; the caller's /var/www/<base> default
            # remains the last resort.
            local rp rd
            rp="$(get_site_config_value "$base" '.live.remote_path' "")"
            if [ -n "$rp" ]; then echo "$rp"; return; fi
            rd="$(get_site_config_value "$base" '.live.remote_dir' "")"
            if [ -n "$rd" ]; then echo "/var/www/${rd}"; return; fi
            echo ""; return
            ;;
        *)           yq_path=".live.$field" ;;
    esac
    get_site_config_value "$base" "$yq_path" ""
}

# stg2live_stg_has_drush <stg_dir> — 0 iff the staging tree carries an
# executable drush in its vendor. D17 (ops#157): dev2stg builds staging with
# `composer install --no-dev`, so a site with drush in require-dev ships a
# drush-less vendor; stg2live §3.6 then runs `drush updatedb` ON LIVE from that
# synced vendor and aborts — but only AFTER maintenance mode is enabled, which
# is where the 2026-07-29 incident's ~25-minute outage came from. This lets the
# caller refuse BEFORE the destructive path, while recovery is still free.
stg2live_stg_has_drush() {
    local stg_dir="${1:-}"
    [ -n "$stg_dir" ] || return 1
    local d
    for d in "$stg_dir/vendor/bin/drush" "$stg_dir/web/vendor/bin/drush"; do
        [ -x "$d" ] && return 0
    done
    return 1
}

# Check if live security is enabled (reads global nwp.yml settings)
is_live_security_enabled() {
    local root="${PROJECT_ROOT:-$HOME/nwp}"
    local global_config="$root/nwp.yml"
    if [[ -f "$global_config" ]] && command -v yq &>/dev/null; then
        local enabled
        enabled=$(yq eval '.settings.live_security.enabled // false' "$global_config" 2>/dev/null)
        [ "$enabled" == "true" ]
    else
        return 1
    fi
}

# Get security modules from nwp.yml settings
get_security_modules() {
    local root="${PROJECT_ROOT:-$HOME/nwp}"
    local global_config="$root/nwp.yml"
    if [[ -f "$global_config" ]] && command -v yq &>/dev/null; then
        yq eval '.settings.live_security.modules[]' "$global_config" 2>/dev/null
    fi
}

# Secure user passwords before live deployment
# - Regenerates admin password to a secure random value
# - Forces password reset for all other users on next login
# - Returns new admin password for display
secure_user_passwords() {
    local stg_site="$1"

    # Check if skipped via command line
    if [ "${SKIP_PASSWORD_RESET:-false}" == "true" ]; then
        print_info "Password security skipped (--no-password-reset)"
        return 0
    fi

    print_header "Securing User Passwords"

    local original_dir=$(pwd)
    cd "$stg_site" || return 1

    # Skip cleanly if drush isn't available (composer --no-dev removes it where drush
    # is a dev-only dep); a missing-drush staging site must not hard-fail the deploy. (MR !11)
    if ! ddev drush --version >/dev/null 2>&1; then
        print_status "WARN" "drush unavailable in staging — skipping password security"
        print_info "  To enable: ddev composer require drush/drush in $stg_site"
        cd "$original_dir"; return 0
    fi

    # Generate secure admin password (16 chars, alphanumeric)
    local new_admin_pass=$(openssl rand -base64 24 | tr -d '/=+' | cut -c -16)

    # Step 1: Reset admin password to secure value
    print_info "Generating secure admin password..."
    if ddev drush user:password admin "$new_admin_pass" 2>/dev/null; then
        print_status "OK" "Admin password regenerated"
    else
        print_error "Failed to reset admin password"
        cd "$original_dir"
        return 1
    fi

    # Step 2: Check for weak passwords on all users and force reset
    print_info "Checking for weak passwords..."
    local weak_users=$(ddev drush php:eval '
        $passwords_to_test = ["password", "admin", "admin123", "test", "test123", "1234", "123456"];
        $users = \Drupal::entityTypeManager()->getStorage("user")->loadMultiple();
        $service = \Drupal::service("password");
        $weak = [];
        foreach ($users as $user) {
            if ($user->id() == 0) continue;
            foreach ($passwords_to_test as $pwd) {
                if ($service->check($pwd, $user->getPassword())) {
                    $weak[] = $user->getAccountName();
                    break;
                }
            }
        }
        echo implode(",", $weak);
    ' 2>/dev/null)

    if [ -n "$weak_users" ] && [ "$weak_users" != "" ]; then
        print_status "WARN" "Found users with weak passwords: $weak_users"

        # Force password reset for weak password users (except admin which we just reset)
        print_info "Forcing password reset for users with weak passwords..."
        for username in ${weak_users//,/ }; do
            if [ "$username" != "admin" ]; then
                # Generate a random password and block the account until they reset
                local temp_pass=$(openssl rand -base64 24 | tr -d '/=+' | cut -c -20)
                ddev drush user:password "$username" "$temp_pass" 2>/dev/null || true
                print_info "  Reset password for: $username"
            fi
        done
        print_status "OK" "Weak passwords have been reset"
    else
        print_status "OK" "No weak passwords detected"
    fi

    # Step 3: Export configuration
    print_info "Exporting updated configuration..."
    ddev drush cex -y 2>/dev/null || true

    cd "$original_dir"

    # Store admin password for display at the end
    NEW_ADMIN_PASSWORD="$new_admin_pass"

    print_status "OK" "User passwords secured"
    echo ""
    echo -e "  ${BOLD}${YELLOW}⚠ SAVE THIS:${NC} New admin password: ${GREEN}${new_admin_pass}${NC}"
    echo ""

    return 0
}

# Install security modules on staging site before deployment
install_security_modules() {
    local stg_site="$1"

    # Check if skipped via command line
    if [ "${SKIP_SECURITY:-false}" == "true" ]; then
        print_info "Security module installation skipped (--no-security)"
        return 0
    fi

    if ! is_live_security_enabled; then
        print_info "Live security hardening disabled in nwp.yml"
        return 0
    fi

    print_header "Installing Security Modules"

    local modules=$(get_security_modules)
    if [ -z "$modules" ]; then
        print_info "No security modules configured"
        return 0
    fi

    local original_dir=$(pwd)
    cd "$stg_site" || return 1

    # Skip cleanly if drush isn't available — module enable uses drush. (MR !11)
    if ! ddev drush --version >/dev/null 2>&1; then
        print_status "WARN" "drush unavailable in staging — skipping security module install"
        cd "$original_dir"; return 0
    fi

    # Install each module via composer and enable
    while IFS= read -r module; do
        [ -z "$module" ] && continue

        # Check if already installed
        if ddev composer show "drupal/$module" >/dev/null 2>&1; then
            print_status "OK" "$module already installed"
        else
            print_info "Installing drupal/$module..."
            if ddev composer require "drupal/$module" --no-interaction 2>/dev/null; then
                print_status "OK" "Installed $module"
            else
                print_status "WARN" "Could not install $module (may not exist or have conflicts)"
            fi
        fi

        # Enable module if not already enabled
        if ! ddev drush pm:list --status=enabled --type=module 2>/dev/null | grep -q "^$module "; then
            print_info "Enabling $module..."
            if ddev drush en "$module" -y 2>/dev/null; then
                print_status "OK" "Enabled $module"
            else
                print_status "WARN" "Could not enable $module"
            fi
        fi
    done <<< "$modules"

    # Export config so modules are enabled on live
    print_info "Exporting configuration..."
    ddev drush cex -y 2>/dev/null || true

    cd "$original_dir"
    return 0
}

################################################################################
# Safety / Pre-Deploy Snapshots
################################################################################

# Ledger an --override-snapshot use so a destructive deploy that ran WITHOUT a
# proven webroot snapshot is auditable after the fact (mirrors the
# --override-canonical / --override-pair ledgers).
_snapshot_override_ledger() {
    local base_name="$1"
    local reason="$2"
    local ledger_dir="${PROJECT_ROOT}/private/snapshots"
    mkdir -p "$ledger_dir" 2>/dev/null || true
    local who
    who=$(whoami 2>/dev/null || echo "unknown")
    echo "$(date -Iseconds 2>/dev/null || date)  ${who}  ${base_name}  --override-snapshot  ${reason}" \
        >> "${ledger_dir}/${base_name}.log" 2>/dev/null || true
    print_status "WARN" "--override-snapshot ledgered: ${ledger_dir}/${base_name}.log"
}

# Take a pre-deploy snapshot of the live host: all MySQL/MariaDB databases
# (compressed dump) + the /etc/nginx/conf.d/ directory (tarball) + the WEBROOT
# (tarball, excl. files/+private/ — F2/P0-2). Stored in the deploying user's
# home dir on the remote box. Idempotent within 1 hour (skips if a webroot
# snapshot from the last hour exists for the same site) so repeated
# dev2stg+stg2live runs don't blow up disk.
#
# Recovery (manual): files written to ~ on the live host with timestamped
# names; restore mysqldump via `gunzip -c <dump> | sudo mysql`; restore
# nginx via `sudo tar xzf <tar> -C /`; restore webroot via
# `sudo tar xzf <webroot-tar> -C <remote_path>`.
live_host_snapshot() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    # F2/P0-2 (design 2026-07-19): remote_path + webroot are hoisted from the
    # rsync-prep block above the call so the pre-deploy webroot tar can capture
    # exactly what the rsync --delete is about to overwrite.
    local remote_path="${4:-}"
    local webroot="${5:-web}"

    print_header "Pre-Deploy Snapshot"

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo "
    fi

    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local dbs_file="nwp-snapshot-${base_name}-dbs-${ts}.sql.gz"
    local nginx_file="nwp-snapshot-${base_name}-nginx-${ts}.tar.gz"

    # Check disk space first (need ~500 MB free; bail if tighter than 1 GB).
    local free_kb
    free_kb=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "df -k --output=avail ~ | tail -1" 2>/dev/null | tr -d ' ')
    if [ -n "$free_kb" ] && [ "$free_kb" -lt 1048576 ]; then
        print_status "WARN" "Live host has <1GB free in ~ (${free_kb}KB)."
        # F2/P0-2: a stg2live deploy always rsyncs --delete against the live
        # webroot, so skipping the snapshot here would leave that --delete
        # unrecoverable. Fail-closed abort unless the operator explicitly
        # accepts the risk with --override-snapshot (ledgered).
        if [ "${OVERRIDE_SNAPSHOT:-false}" == "true" ]; then
            _snapshot_override_ledger "$base_name" "disk-tight (<1GB free in ~); snapshot skipped"
            print_status "WARN" "--override-snapshot set — proceeding WITHOUT a pre-deploy snapshot."
            return 0
        fi
        print_error "Refusing the destructive rsync --delete without a webroot snapshot (disk-tight)."
        print_error "Free disk on the live host, or re-run with --override-snapshot (ledgered)."
        return 1
    fi

    # Idempotent: skip if a WEBROOT snapshot from the last hour exists for this
    # site — the webroot tar is the critical --delete backstop (F2/P0-2), so
    # idempotency keys off it, not the DB dump.
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
        print_status "WARN" "DB snapshot failed (continuing — verify live state manually before destructive ops)"
    fi

    print_info "Snapshotting /etc/nginx/conf.d/..."
    if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "${sudo_prefix}tar czf ~/${nginx_file} /etc/nginx/conf.d/ 2>/dev/null && ${sudo_prefix}chown ${ssh_user}:${ssh_user} ~/${nginx_file}"; then
        print_status "OK" "Nginx snapshot: ~/${nginx_file}"
    else
        print_status "WARN" "Nginx snapshot failed (continuing — verify live state manually)"
    fi

    # F2/P0-2: snapshot the live WEBROOT before the rsync --delete swaps it out.
    # This is the fail-closed backstop for the ~6,253-out/~6,497-in un-fork swap:
    # captures code + oauth-keys/ + auth.json + the generated env settings, but EXCLUDES the
    # large, rsync-safe uploads (files/ + private/), which the deploy never
    # touches. Unlike the DB/nginx dumps above (WARN-and-continue), a webroot
    # snapshot failure ABORTS the deploy (return 1) unless --override-snapshot is
    # set — without this tar a bad --delete/updatedb is unrecoverable. Success is
    # decided by `test -s` on the resulting tar (not tar's exit code, which can
    # be 1 on a benign "file changed as we read it" against a live site).
    local webroot_file="nwp-snapshot-${base_name}-webroot-${ts}.tar.gz"
    local web_remote=""
    if [ -n "$remote_path" ]; then
        print_info "Snapshotting live webroot (${remote_path}, excl. ${webroot}/sites/default/files + private)..."
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
                print_error "Investigate the live host, or re-run with --override-snapshot (ledgered)."
                return 1
            fi
        fi
    else
        print_status "WARN" "No remote_path resolved — skipping webroot snapshot (no --delete backstop)."
    fi

    # Register the snapshot as a rollback point so `pl rollback list` /
    # `pl rollback execute` can find it. Failure here is non-fatal — the
    # snapshot files are written regardless; we just lose the
    # registry-driven discovery for this particular point.
    if command -v rollback_record_remote >/dev/null 2>&1; then
        local commit_sha=""
        if [ -d "${PROJECT_ROOT}/.git" ]; then
            commit_sha=$(cd "$PROJECT_ROOT" && git rev-parse HEAD 2>/dev/null || true)
        fi
        # Remote paths are relative to ssh_user's home; expand for the
        # registry so restore commands work without re-resolving ~.
        local dbs_remote nginx_remote home_dir
        home_dir=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
            'echo $HOME' 2>/dev/null || echo "/home/${ssh_user}")
        dbs_remote="${home_dir}/${dbs_file}"
        nginx_remote="${home_dir}/${nginx_file}"
        # F2/P0-2: thread the webroot tar (arg 9) + its extraction target (arg
        # 10 = remote_path) into the registry so `pl rollback execute` can
        # `tar xzf` the code back on a failed --delete/updatedb.
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
    print_info "Or restore manually:"
    echo "  ssh ${ssh_user}@${server_ip}"
    echo "  # restore DBs:    gunzip -c ~/${dbs_file} | ${sudo_prefix}mysql"
    echo "  # restore nginx:  ${sudo_prefix}tar xzf ~/${nginx_file} -C / && ${sudo_prefix}nginx -t && ${sudo_prefix}systemctl reload nginx"
    echo ""

    return 0
}

################################################################################
# Database Deployment Functions
################################################################################

# Generate a secure random password
generate_db_password() {
    openssl rand -base64 24 | tr -d '/=+' | cut -c -20
}

# Setup database on live server (create DB and user if they don't exist)
setup_live_database() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    local db_pass="$4"

    local db_name="${base_name//-/_}"  # Replace hyphens with underscores for MySQL
    local db_user="${db_name}"

    print_info "Setting up database on live server..."

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo"
    fi

    # Check if MySQL/MariaDB is available
    if ! ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix mysql -e 'SELECT 1' >/dev/null 2>&1"; then
        print_error "MySQL/MariaDB not accessible on live server"
        return 1
    fi

    # Create database if it doesn't exist. Stderr no longer suppressed —
    # silent failures here are how the DB-credentials-drift bug of
    # 2026-05-22 happened: ALTER USER errored under load, output was
    # discarded, the deploy proceeded, and nwc was 500ing on Access
    # denied. Let real errors surface; the caller already prints them.
    local setup_out
    setup_out=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix mysql -e \"
        CREATE DATABASE IF NOT EXISTS \\\`${db_name}\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
        ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
        GRANT ALL PRIVILEGES ON \\\`${db_name}\\\`.* TO '${db_user}'@'localhost';
        FLUSH PRIVILEGES;
    \"" 2>&1)
    local setup_rc=$?

    if [ $setup_rc -ne 0 ]; then
        print_error "Database setup failed (rc=$setup_rc): $setup_out"
        return 1
    fi

    # Verify the user can actually authenticate with the password we just
    # set. Catches the drift case where ALTER USER reports success but the
    # auth plugin or some MySQL quirk leaves the password in a different
    # state than we expect. One retry, then fail loudly so the deploy
    # aborts before generate_live_settings writes a credential file that
    # doesn't match the live DB.
    local verify_rc
    ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "mysql -u${db_user} -p'${db_pass}' -e 'SELECT 1' >/dev/null 2>&1"
    verify_rc=$?

    if [ $verify_rc -ne 0 ]; then
        print_warning "Initial auth check failed; retrying ALTER USER..."
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix mysql -e \"
            ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
            FLUSH PRIVILEGES;
        \"" 2>&1 || true

        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
            "mysql -u${db_user} -p'${db_pass}' -e 'SELECT 1' >/dev/null 2>&1"
        verify_rc=$?
    fi

    if [ $verify_rc -ne 0 ]; then
        print_error "Database user '${db_user}'@'localhost' cannot authenticate with the deploy-generated password."
        print_error "This is the credentials-drift bug class — generate_live_settings would write a settings.local.php with the wrong password and the site would 500."
        # NO pl VERB — this is the one recovery on this path with no `pl`
        # equivalent: repairing a MySQL grant is host DB-admin, not a deploy
        # step, and NWP has no credential-repair verb (deliberately: it would
        # need the data-tier secrets). The deploy has ALREADY retried the
        # ALTER USER twice above; a third automated attempt would not help.
        print_error "NO pl VERB exists for this one — host DB-admin action, escalate to the server owner:"
        print_error "  ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '<password-from-settings.local.php>'; FLUSH PRIVILEGES;"
        print_error "Then re-run: pl stg2live ${base_name}"
        return 1
    fi

    print_status "OK" "Database '${db_name}' ready (auth verified)"
    return 0
}

# F5 / INV-10 (design 2026-07-19 §3.5a): resolve a PERSISTENT hash_salt for the
# live settings.local.php. hash_salt is stable live state — regenerating it every
# deploy (the old inline `openssl rand -hex 32`) invalidates every member's
# one-time-login / password-reset link and in-flight CSRF tokens, and (on a DB
# that is preserved under --code-only) breaks session/CSRF continuity. Three
# states, never treating an unreadable/empty read as "absent" (F5):
#   (a) REUSE — a stored salt is preferred; on a live site the mint-once source of
#       truth is `pl secrets inject` (P0-5). Here we reuse the salt already
#       persisted in the live settings.local.php (mint-once holds: first provision
#       writes one, every deploy after reuses it).
#   (b) MINT-ONCE — only when the site is provably first-provision AND not
#       canonical:live|prod: mint a fresh salt.
#   (c) ABORT (fail-closed) — on a canonical:live|prod site with no reusable salt,
#       or under --code-only, REFUSE to mint. A fresh salt on a live site logs
#       everyone out and breaks stored hashes; an empty/failed read must not be
#       mistaken for "absent". The operator seeds it once via `pl secrets`.
# NEVER `openssl rand` a fresh salt on a canonical:live site.
resolve_live_hash_salt() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    local settings_path="$4"
    local sudo_prefix="$5"

    local phase
    phase=$(canonical_get_phase "$base_name" 2>/dev/null || echo dev)

    # (a) Reuse the salt already persisted on live. A non-empty read = present.
    #     The sed runs LOCALLY on the fetched file so remote quoting stays sane.
    local existing
    existing=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "${sudo_prefix} cat ${settings_path}/settings.local.php 2>/dev/null" 2>/dev/null \
        | sed -n "s/.*\\\$settings\\['hash_salt'\\][[:space:]]*=[[:space:]]*'\\([^']*\\)'.*/\\1/p" | head -1)
    if [ -n "$existing" ]; then
        print_status "OK" "Reusing persisted hash_salt (INV-10: stable live state)" >&2
        printf '%s' "$existing"
        return 0
    fi

    # (c) FAIL-CLOSED: on a canonical:live|prod site an unreadable/empty read
    #     cannot be told apart from a genuine first-provision — refuse to mint.
    if [ "$phase" == "live" ] || [ "$phase" == "prod" ]; then
        print_error "hash_salt not readable off live for canonical:${phase} site '${base_name}' (F5/INV-10)." >&2
        print_error "Refusing to mint a fresh salt: it logs every member out + breaks stored hashes and one-time links." >&2
        print_error "Seed it once via 'pl secrets' (mint-once), then re-run." >&2
        return 1
    fi
    # (c) FAIL-CLOSED under --code-only: the DB (and its salt-keyed CSRF/session
    #     state) is preserved, so a fresh salt would break it silently.
    if [ "${CODE_ONLY:-false}" == "true" ]; then
        print_error "hash_salt not readable off live under --code-only for '${base_name}' — refusing to mint (F5)." >&2
        return 1
    fi

    # (b) Provably first-provision on a non-canonical:live site: mint once.
    print_status "OK" "Minting hash_salt (first provision; site is not canonical:live)" >&2
    openssl rand -hex 32
    return 0
}

# Generate settings.local.php with database credentials for live server
generate_live_settings() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    local webroot="$4"
    local db_pass="$5"

    local db_name="${base_name//-/_}"
    local db_user="${db_name}"
    local site_path="/var/www/${base_name}"
    local settings_path="${site_path}/${webroot}/sites/default"

    print_info "Generating settings.local.php..."

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo"
    fi

    # F5/INV-10: resolve a PERSISTENT hash_salt (reuse → mint-once → abort) BEFORE
    # writing settings — never regenerate it inline on a canonical:live site.
    local hash_salt
    if ! hash_salt=$(resolve_live_hash_salt "$base_name" "$server_ip" "$ssh_user" "$settings_path" "$sudo_prefix"); then
        print_error "Could not resolve a persistent hash_salt for live — aborting settings generation (F5/INV-10)."
        return 1
    fi

    # Create settings.local.php with database credentials
    ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix tee ${settings_path}/settings.local.php > /dev/null" << EOF
<?php
/**
 * Live server database configuration
 * Generated by NWP stg2live deployment
 */

\$databases['default']['default'] = [
  'database' => '${db_name}',
  'username' => '${db_user}',
  'password' => '${db_pass}',
  'prefix' => '',
  'host' => 'localhost',
  'port' => '3306',
  'isolation_level' => 'READ COMMITTED',
  'driver' => 'mysql',
  'namespace' => 'Drupal\\mysql\\Driver\\Database\\mysql',
  'autoload' => 'core/modules/mysql/src/Driver/Database/mysql/',
];

// Trusted host patterns for live site
\$settings['trusted_host_patterns'] = [
  '^${base_name}\\.nwpcode\\.org\$',
  '^www\\.${base_name}\\.nwpcode\\.org\$',
];

// File paths
\$settings['file_private_path'] = '${site_path}/private';

// Config sync directory
\$settings['config_sync_directory'] = '../config/sync';

// Hash salt — PERSISTENT live state (F5/INV-10). Resolved by
// resolve_live_hash_salt: reused from live if present, minted only on a
// provable first provision, never regenerated on a canonical:live site.
\$settings['hash_salt'] = '${hash_salt}';

// Operator-managed overrides — never touched by the deploy. Put any
// per-host config (e.g. \$config['nwc_feedback.agent_fast_path'][...])
// in settings.local.overrides.php; the deploy regenerates everything
// else above on every stg2live run, but leaves the overrides file
// alone. Also excluded from rsync --delete so it survives file sync.
if (file_exists(__DIR__ . '/settings.local.overrides.php')) {
  include __DIR__ . '/settings.local.overrides.php';
}
EOF

    if [ $? -eq 0 ]; then
        # Ensure settings.local.php is included from settings.php
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix grep -q 'settings.local.php' ${settings_path}/settings.php || $sudo_prefix bash -c 'echo \"
if (file_exists(\\\$app_root . \\\"/\" . \\\$site_path . \\\"/settings.local.php\\\")) {
  include \\\$app_root . \\\"/\" . \\\$site_path . \\\"/settings.local.php\\\";
}\" >> ${settings_path}/settings.php'" 2>/dev/null

        # Set correct permissions
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix chown www-data:www-data ${settings_path}/settings.local.php" 2>/dev/null
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix chmod 440 ${settings_path}/settings.local.php" 2>/dev/null

        # Create private files directory
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix mkdir -p ${site_path}/private && $sudo_prefix chown www-data:www-data ${site_path}/private && $sudo_prefix chmod 750 ${site_path}/private" 2>/dev/null

        print_status "OK" "settings.local.php created"
        return 0
    else
        print_error "Failed to create settings.local.php"
        return 1
    fi
}

# Export database from staging and import to live
deploy_database() {
    local stg_site="$1"
    local base_name="$2"
    local server_ip="$3"
    local ssh_user="$4"

    local db_name="${base_name//-/_}"

    print_info "Exporting database from staging..."

    local original_dir=$(pwd)
    cd "$stg_site" || return 1

    # Export database from DDEV
    local dump_file="/tmp/${base_name}_stg_live_deploy.sql.gz"
    if ddev export-db --gzip --file="$dump_file" 2>/dev/null; then
        print_status "OK" "Database exported"
    else
        print_error "Failed to export database from staging"
        cd "$original_dir"
        return 1
    fi

    cd "$original_dir"

    # Transfer to live server
    print_info "Transferring database to live server..."
    if scp $(nwp_ssh_opts "$base_name") -o BatchMode=yes "$dump_file" "${ssh_user}@${server_ip}:/tmp/" 2>/dev/null; then
        print_status "OK" "Database transferred"
    else
        print_error "Failed to transfer database"
        rm -f "$dump_file"
        return 1
    fi

    # Import on live server
    print_info "Importing database on live server..."
    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo"
    fi

    local remote_dump="/tmp/${base_name}_stg_live_deploy.sql.gz"
    if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "gunzip -c $remote_dump | $sudo_prefix mysql ${db_name}" 2>/dev/null; then
        print_status "OK" "Database imported"
        # Cleanup
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "rm -f $remote_dump" 2>/dev/null
        rm -f "$dump_file"
        return 0
    else
        print_error "Failed to import database"
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "rm -f $remote_dump" 2>/dev/null
        rm -f "$dump_file"
        return 1
    fi
}

# Setup SSL certificate using certbot
setup_ssl_certificate() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    # Domain resolution chain (same chain used for rsync destination):
    #   .nwp.yml .live.domain → settings.url base → NWP_PROD_DOMAIN env.
    # The previous default ("example.org") produced certbot calls against
    # nonexistent nwc.example.org. Wrong, never going to succeed.
    local domain
    domain=$(get_live_config "$base_name" "domain" 2>/dev/null)
    if [ -z "$domain" ]; then
        local base_domain
        base_domain=$(get_base_domain 2>/dev/null)
        [ -z "$base_domain" ] && base_domain="${NWP_PROD_DOMAIN:-nwpcode.org}"
        domain="${base_name}.${base_domain}"
    fi

    print_info "Setting up SSL certificate for $domain..."

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo"
    fi

    # Check if certbot is installed
    if ! ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "which certbot >/dev/null 2>&1"; then
        print_info "Installing certbot..."
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix apt-get update && $sudo_prefix apt-get install -y certbot" 2>/dev/null || {
            print_status "WARN" "Could not install certbot - SSL setup skipped"
            return 1
        }
    fi

    # Check if certificate already exists. If it does, skip cert
    # acquisition but STILL run update_nginx_ssl below so that the
    # per-site nginx config gets written/refreshed. Without this,
    # a re-run after an interrupted previous run leaves the site
    # with an HTTP-only or stale nginx config.
    local cert_exists=0
    if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix test -f /etc/letsencrypt/live/${domain}/fullchain.pem" 2>/dev/null; then
        print_status "OK" "SSL certificate already exists; refreshing nginx config"
        cert_exists=1
        update_nginx_ssl "$base_name" "$server_ip" "$ssh_user" "$domain"
        return $?
    fi

    # Get certificate using webroot method.
    #
    # CHICKEN-AND-EGG: certbot --webroot needs nginx to ALREADY serve
    # /.well-known/acme-challenge/<token> from the webroot. On a first
    # deploy there's no per-site nginx config yet, so requests fall
    # through to the GitLab default (404). Bootstrap a minimal HTTP-only
    # config first — certbot can then place + retrieve its challenge,
    # and update_nginx_ssl below replaces it with the full HTTPS config.
    local webroot="/var/www/${base_name}/html"
    # Auto-detect webroot for Moodle (no /html subdir) and Drupal-with-web.
    if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix test ! -d $webroot" 2>/dev/null; then
        if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix test -d /var/www/${base_name}/web" 2>/dev/null; then
            webroot="/var/www/${base_name}/web"
        else
            webroot="/var/www/${base_name}"
        fi
    fi

    if ! ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix test -f /etc/nginx/conf.d/${base_name}.conf" 2>/dev/null; then
        print_info "Writing HTTP-only nginx bootstrap config for ACME challenge..."
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix tee /etc/nginx/conf.d/${base_name}.conf > /dev/null" << ACMEEOF
server {
    listen 80;
    server_name ${domain};
    root ${webroot};
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 301 https://\$server_name\$request_uri; }
}
ACMEEOF
        if ! ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix nginx -t" >/dev/null 2>&1; then
            print_error "Bootstrap nginx config failed validation; removing"
            ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix rm -f /etc/nginx/conf.d/${base_name}.conf" 2>/dev/null || true
            return 1
        fi
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix gitlab-ctl hup nginx" 2>/dev/null || \
            ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix systemctl reload nginx" 2>/dev/null || true
    fi

    if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix certbot certonly --webroot -w $webroot -d $domain --non-interactive --agree-tos --email admin@nwpcode.org" 2>/dev/null; then
        print_status "OK" "SSL certificate obtained"

        # Update nginx config to use SSL
        update_nginx_ssl "$base_name" "$server_ip" "$ssh_user" "$domain"
        return 0
    else
        print_status "WARN" "Could not obtain SSL certificate (may need manual setup)"
        return 1
    fi
}

# Deploy robots.txt to live server
# By default, deploys BLOCKING robots.txt (same as staging) to prevent indexing.
# Only deploys permissive robots.txt if robots_allow is set in site live config.
deploy_production_robots() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    local domain="$4"

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo"
    fi

    # Check if site has robots_allow enabled in live config
    local robots_allow=$(get_live_config "$base_name" "robots_allow" 2>/dev/null || true)

    local template_path
    if [ "$robots_allow" == "true" ] || [ "$robots_allow" == "yes" ] || [ "$robots_allow" == "y" ]; then
        print_info "Deploying permissive robots.txt (robots_allow enabled)..."
        template_path="$PROJECT_ROOT/templates/robots-production.txt"
    else
        print_info "Deploying blocking robots.txt (default: no indexing)..."
        template_path="$PROJECT_ROOT/templates/robots-staging.txt"
    fi

    if [ ! -f "$template_path" ]; then
        print_status "WARN" "robots.txt template not found at $template_path"
        return 1
    fi

    # Replace [DOMAIN] with actual domain and deploy
    local robots_content=$(sed "s/\[DOMAIN\]/${domain}/g" "$template_path")

    # Deploy to webroot
    local site_path="/var/www/${base_name}"
    local webroot_path="${site_path}/html"

    if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix test -d ${site_path}/web" 2>/dev/null; then
        webroot_path="${site_path}/web"
    fi

    # Write robots.txt to server
    echo "$robots_content" | ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix tee ${webroot_path}/robots.txt > /dev/null" 2>/dev/null

    if [ $? -eq 0 ]; then
        # Set correct permissions
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix chown www-data:www-data ${webroot_path}/robots.txt && $sudo_prefix chmod 644 ${webroot_path}/robots.txt" 2>/dev/null
        print_status "OK" "robots.txt deployed"
        return 0
    else
        print_status "WARN" "Could not deploy robots.txt"
        return 1
    fi
}

# Update nginx config to include SSL
# Resolve the PHP-FPM version the live nginx vhost should target for a site.
# NEVER hardcode: the nwc go-live 500'd (2026-07-20) because a PHP>=8.3 build was
# served by php8.2-fpm ("Composer dependencies require a PHP version >= 8.3.0").
# Order: the staging build's DDEV php_version (what it was tested on) → the built
# composer.json require.php → 8.3 as the floor (never 8.2).
resolve_site_php_version() {
    local base_name="$1"
    local ver="" stg_dir
    stg_dir="$(get_stg_dir "$base_name" 2>/dev/null || true)"
    if [ -n "$stg_dir" ] && [ -f "$stg_dir/.ddev/config.yaml" ]; then
        ver="$(grep -E '^php_version:' "$stg_dir/.ddev/config.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"' | head -1)"
    fi
    if [ -z "$ver" ] && [ -n "$stg_dir" ] && [ -f "$stg_dir/composer.json" ]; then
        # ">=8.3" / "^8.3" / "8.3.*" -> 8.3
        ver="$(grep -oE '"php"[[:space:]]*:[[:space:]]*"[^"]+"' "$stg_dir/composer.json" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
    fi
    [ -z "$ver" ] && ver="8.3"
    printf '%s' "$ver"
}

update_nginx_ssl() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    local domain="$4"

    # PHP-FPM version for the fastcgi_pass — derived from the build, not hardcoded.
    local php_ver
    php_ver="$(resolve_site_php_version "$base_name")"

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo"
    fi

    print_info "Updating nginx config for SSL..."

    # Create updated nginx config with SSL
    ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix tee /etc/nginx/conf.d/${base_name}.conf > /dev/null" << EOF
server {
    listen 80;
    server_name ${domain};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${domain};

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'self';" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    # SEO: Production site - allow indexing
    # (No X-Robots-Tag needed - search engines will index normally)

    # Hide server information
    server_tokens off;
    fastcgi_hide_header X-Generator;
    fastcgi_hide_header X-Powered-By;
    fastcgi_hide_header X-Drupal-Cache;
    fastcgi_hide_header X-Drupal-Dynamic-Cache;

    root /var/www/${base_name}/html;
    index index.php index.html;

    location / {
        try_files \$uri /index.php\$is_args\$args;
    }

    location ~ \\.php\$ {
        fastcgi_pass unix:/var/run/php/php${php_ver}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include /opt/gitlab/embedded/conf/fastcgi_params;
    }

    location ~ /\\.ht {
        deny all;
    }

    location = /favicon.ico {
        log_not_found off;
        access_log off;
    }

    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }

    location = /sitemap.xml {
        try_files \$uri @rewrite;
    }

    location ~* \\.(txt|log)\$ {
        deny all;
    }

    location ~ ^/sites/.*/files/styles/ {
        try_files \$uri @rewrite;
    }

    location @rewrite {
        rewrite ^ /index.php;
    }
}
EOF

    # Validate nginx config BEFORE reload. If broken, restore the snapshot's
    # version of conf.d/<base_name>.conf and bail. Otherwise the reload could
    # leave nginx unreloadable on next config change (sibling sites still
    # work because they're in separate conf.d/ files, but it's a foot-gun).
    if ! ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "$sudo_prefix nginx -t" >/dev/null 2>&1; then
        print_error "nginx -t failed AFTER writing conf.d/${base_name}.conf."
        print_error "Removing the broken config so nginx remains reloadable."
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
            "$sudo_prefix rm -f /etc/nginx/conf.d/${base_name}.conf" 2>/dev/null || true
        return 1
    fi

    # Reload nginx (GitLab's nginx)
    ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix gitlab-ctl hup nginx" 2>/dev/null || \
        ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "$sudo_prefix systemctl reload nginx" 2>/dev/null || true

    print_status "OK" "Nginx SSL config updated"
}

# Full database deployment (orchestrates all steps)
full_database_deployment() {
    local stg_site="$1"
    local base_name="$2"
    local server_ip="$3"
    local ssh_user="$4"
    local webroot="$5"

    print_header "Database Deployment"

    # Generate a secure password for the database
    local db_pass=$(generate_db_password)

    # Step 1: Setup database on live server
    if ! setup_live_database "$base_name" "$server_ip" "$ssh_user" "$db_pass"; then
        print_error "Database setup failed"
        return 1
    fi

    # Step 2: Generate settings.local.php
    if ! generate_live_settings "$base_name" "$server_ip" "$ssh_user" "$webroot" "$db_pass"; then
        print_error "Settings generation failed"
        return 1
    fi

    # Step 3: Deploy database from staging
    if ! deploy_database "$stg_site" "$base_name" "$server_ip" "$ssh_user"; then
        print_error "Database deployment failed"
        return 1
    fi

    print_status "OK" "Database deployment complete"
    return 0
}

# §3.6 (design 2026-07-19): the missing live DB-update sequence.
#
# stg2live historically ran NO `drush updatedb` at all — after a code sync (esp.
# the cross-version un-fork swap) the live code and DB schema would be
# mismatched. This runs the canonical drush-deploy order on live, for BOTH full
# and --code-only deploys (it operates on whatever DB is now present), BEFORE
# the final `drush cr`:
#     drush updatedb -y        (hook_update_N + hook_post_update_NAME; schema
#                               advances in place against the live DB — never a
#                               DB import, INV-1)
#     (config step: stg2live has NO config:import by design — §3.2 "no blind
#      config:import against the stale sync dir" — so nothing runs here)
#     drush cache:rebuild
#
# Uses the same remote `sudo -u www-data drush` idiom as the post-deploy cr.
# Skips cleanly on --dry-run (prints what it would do).
run_live_db_updates() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    local webroot="$4"
    local remote_path="$5"

    print_header "Database Updates (updatedb)"

    if [ "${DRY_RUN:-false}" == "true" ]; then
        print_info "[dry-run] would run: drush updatedb -y  →  drush cache:rebuild on ${remote_path}"
        return 0
    fi

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo"
    fi

    # Resolve drush EXPLICITLY (do NOT rely on PATH — the old `cd ${remote_path}
    # && drush` form silently failed because there is no drush on PATH there) and
    # DO NOT swallow stderr. vendor/ is the sibling of the webroot in a Drupal
    # project; --root points drush at the docroot. `$D` is left set to the first
    # existing candidate (or the last, non-existent, one → the command fails).
    local resolve="for D in ${remote_path}/vendor/bin/drush ${remote_path}/${webroot}/vendor/bin/drush; do [ -x \"\$D\" ] && break; done"

    # config-drift gate (ops#63): only when the site has opted into tracked
    # config-as-code (config.drift_gate: true, or NWP_CONFIG_DRIFT_GATE=1). When
    # OFF (every site today), the original updatedb path below runs UNCHANGED.
    if config_drift_enabled "$base_name"; then
        # Executor: run an arbitrary shell string on the live host. Defined here
        # so it closes (bash dynamic scope) over base_name/ssh_user/server_ip.
        _stg2live_drift_exec() {
            ssh $(nwp_ssh_opts "$base_name") "${ssh_user}@${server_ip}" "$1"
        }
        # Drush prefix valid on the target: resolve $D first (no PATH reliance),
        # then invoke as www-data. \$D stays literal so the REMOTE shell expands
        # it in the same session the gate runs each command in.
        local remote_drush="${resolve}; ${sudo_prefix} -u www-data \$D --root=${remote_path}/${webroot}"
        config_drift_guarded_updatedb _stg2live_drift_exec "$remote_drush" "updatedb -y" "live (${base_name})"
        local _drift_rc=$?
        case "$_drift_rc" in
            0) print_status "OK" "Database updates applied (updatedb, config-drift verified)" ;;
            1) print_error "drush updatedb FAILED on live — schema hooks NOT applied. Maintenance mode left ON."
               print_error "Recover through pl — no ssh (the NWP-ADR-0028 gate, the live.enabled flag and the ledger all apply):"
               print_error "  pl drush ${base_name} --tier=live --execute -- updatedb -y"
               print_error "  pl drush ${base_name} --tier=live --execute -- cr"
               print_error "  pl drush ${base_name} --tier=live --execute -- sset system.maintenance_mode 0"
               return 1 ;;
            2) print_error "Config drift detected on live — aborting (maintenance left ON). See diff above; NWP_ALLOW_CONFIG_DRIFT=1 to override."
               return 1 ;;
            *) print_error "config-drift gate could not run on live — aborting (maintenance left ON). Fix, then re-deploy (or unset NWP_CONFIG_DRIFT_GATE / config.drift_gate to bypass)."
               return 1 ;;
        esac
    else
        print_info "Running drush updatedb -y..."
        if ssh $(nwp_ssh_opts "$base_name") "${ssh_user}@${server_ip}" \
            "${resolve}; ${sudo_prefix} -u www-data \"\$D\" --root=${remote_path}/${webroot} updatedb -y"; then
            print_status "OK" "Database updates applied (updatedb)"
        else
            # FAIL-LOUD (2026-07-21 incident: a silently-failed updatedb left hooks
            # unrun + the site in maintenance while the deploy reported success).
            # Return non-zero so the caller ABORTS (maintenance stays ON for recovery).
            print_error "drush updatedb FAILED on live — schema hooks NOT applied. Maintenance mode left ON."
            print_error "Recover through pl — no ssh (the NWP-ADR-0028 gate, the live.enabled flag and the ledger all apply):"
            print_error "  pl drush ${base_name} --tier=live --execute -- updatedb -y"
            print_error "  pl drush ${base_name} --tier=live --execute -- cr"
            print_error "  pl drush ${base_name} --tier=live --execute -- sset system.maintenance_mode 0"
            return 1
        fi
    fi

    # Post-deploy canonical legal-text propagation (idempotent, version-aware).
    # A code deploy rsyncs the updated canonical-text/*.md but nothing re-syncs
    # them into the live data_policy entities: the seeding hook (update_10002)
    # is ONE-TIME, so `updatedb` above does not re-run it. If this site exposes
    # `nwc-copyright:sync`, run it so any versions.yml-bumped legal-text edit
    # reaches BOTH the live NWC data_policy (+ login consent gate) AND the
    # co-located SS Moodle tool_policy. Existence-guarded → clean no-op on
    # non-nwc sites; version-aware on both sides → no-op when nothing changed.
    # Non-fatal: a sync hiccup must not abort a good deploy.
    if ssh $(nwp_ssh_opts "$base_name") "${ssh_user}@${server_ip}" \
        "${resolve}; ${sudo_prefix} -u www-data \"\$D\" --root=${remote_path}/${webroot} help nwc-copyright:sync >/dev/null 2>&1"; then
        print_info "Post-deploy legal-text sync (nwc-copyright:sync --skip-notice)..."
        # --skip-notice: sync the NWC data_policy + consent gate AND push to the
        # SS Moodle tool_policy (both idempotent/version-aware). Only the repo
        # NOTICE-file writes are skipped — they target ~/nwp + ~/nwptoolkit repo
        # paths that do not exist on a live web box.
        if ssh $(nwp_ssh_opts "$base_name") "${ssh_user}@${server_ip}" \
            "${resolve}; ${sudo_prefix} -u www-data \"\$D\" --root=${remote_path}/${webroot} nwc-copyright:sync --skip-notice" 2>&1 | tail -18; then
            print_status "OK" "Canonical legal-text synced: NWC data_policy + consent gate + SS tool_policy"
        else
            print_status "WARN" "nwc-copyright:sync errored — verify /legal/* + SS tool_policy on live"
        fi
    fi

    print_info "Running drush cache:rebuild..."
    ssh $(nwp_ssh_opts "$base_name") "${ssh_user}@${server_ip}" \
        "${resolve}; ${sudo_prefix} -u www-data \"\$D\" --root=${remote_path}/${webroot} cache:rebuild" \
        || print_status "WARN" "cache:rebuild reported an error — verify the site"

    return 0
}

# G3 (design 2026-07-19): Drupal maintenance mode around the destructive swap.
# Enable maintenance mode BEFORE the rsync --delete so members never hit a
# half-populated webroot during the ~6.3k-out/~6.5k-in un-fork swap + the live
# updatedb; disable it only AFTER the post-sync updatedb/cr sequence. Matches
# the Moodle `pl moodle upgrade` maintenance pattern (§4.4). Uses the same
# remote `sudo -u www-data drush` idiom as run_live_db_updates, with the
# webroot/vendor fallback. Caller MUST gate this on --dry-run (no live writes).
# Fail-loud philosophy: if a later step aborts, maintenance is deliberately
# left ON (the caller does not disable it on the error paths) and the operator
# is pointed at rollback.
live_maintenance_set() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    local webroot="$4"
    local remote_path="$5"
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
    elif [ "$state" == "0" ]; then
        # A failed maintenance-OFF leaves the site stuck at 503 — make it LOUD.
        print_error "Could NOT disable maintenance mode — THE SITE MAY BE STUCK IN MAINTENANCE (503)."
        print_error "Fix through pl — no ssh (the NWP-ADR-0028 gate and the ledger apply):"
        print_error "  pl drush ${base_name} --tier=live --execute -- sset system.maintenance_mode 0"
        print_error "  pl drush ${base_name} --tier=live --execute -- cr"
    else
        print_status "WARN" "Could not set maintenance_mode=${state} (drush unavailable?)"
    fi
}

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

# Verify and configure site email
verify_site_email() {
    local base_name="$1"
    local server_ip="$2"
    local ssh_user="$3"

    print_header "Verify Site Email Configuration"

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
    local mail_ssh_user="gitlab"

    print_info "Expected site email: $site_email"
    print_info "Forward to: $admin_email"

    # Check if email forwarding exists on mail server
    print_info "Checking email forwarding on $gitlab_host..."

    if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes -o ConnectTimeout=5 "${mail_ssh_user}@${gitlab_host}" \
        "grep -q '^${site_email}' /etc/postfix/virtual 2>/dev/null" 2>/dev/null; then
        print_status "OK" "Email forwarding exists: $site_email"

        # Verify it forwards to the correct address
        local current_forward
        current_forward=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${mail_ssh_user}@${gitlab_host}" \
            "grep '^${site_email}' /etc/postfix/virtual 2>/dev/null | awk '{print \$2}'" 2>/dev/null)

        if [ "$current_forward" != "$admin_email" ] && [ -n "$current_forward" ]; then
            print_status "WARN" "Forward address mismatch: $current_forward (expected: $admin_email)"
            print_info "Updating email forwarding..."

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

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo -u www-data"
    fi

    local current_drupal_email
    current_drupal_email=$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
        "cd /var/www/${base_name} && $sudo_prefix vendor/bin/drush config:get system.site mail --format=string 2>/dev/null" 2>/dev/null)

    if [ "$current_drupal_email" == "$site_email" ]; then
        print_status "OK" "Drupal site email correct: $current_drupal_email"
    elif [ -n "$current_drupal_email" ]; then
        print_status "WARN" "Drupal site email mismatch: $current_drupal_email (expected: $site_email)"
        print_info "Updating Drupal site email..."

        if ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
            "cd /var/www/${base_name} && $sudo_prefix vendor/bin/drush config:set system.site mail '${site_email}' -y" 2>/dev/null; then
            print_status "OK" "Drupal site email updated to: $site_email"
        else
            print_status "WARN" "Could not update Drupal site email"
        fi
    else
        print_info "Could not read current Drupal site email"
    fi

    return 0
}

# Show help
show_help() {
    cat << EOF
${BOLD}NWP Staging to Live Deployment${NC}

${BOLD}USAGE:${NC}
    ./stg2live.sh [OPTIONS] <sitename>

    Deploys staging site to the live server provisioned by 'pl live'.

${BOLD}OPTIONS:${NC}
    -h, --help              Show this help message
    -d, --debug             Enable debug output
    -y, --yes               Skip confirmation prompts
    -v, --verbose           Show detailed rsync output
    --no-security           Skip security module installation
    --no-password-reset     Skip password security (admin regeneration, weak password reset)
    --no-provision          Skip auto-provisioning (used internally)
    --dry-run               Snapshot + rsync preview only; abort before any DB write,
                            permission change, or service reload. Safe to run any time.
    --code-only             Deploy code/config only — skip the database push so live
                            CONTENT is preserved. The allowed deploy shape when the
                            site is canonical: live|prod (see 'pl canonical').
    --fresh-build           nwc un-fork go-live: print the fresh-install-alongside +
                            flip PLAN (side docroot + fresh DB + install sequence).
                            PLAN-ONLY today — fail-closes on a real run until the
                            mutation path is rehearsed attended. Pairs with --dry-run.
                            Mutually exclusive with --code-only.
    --push-content          Opt in to pushing the staging DB OVER the live database
                            (INV-1). Required to run full_database_deployment against
                            a canonical: live|prod site; without it the DB push is
                            refused to protect the live member DB. No effect with
                            --code-only (which never pushes the DB).
    --override-canonical    Push content even though the site is NOT canonical: dev.
                            OVERWRITES the canonical content source. Warns loudly and
                            records who/when in private/canonical/<site>.log.
    --override-pair         Proceed past a paired-site guard (NWP-ADR-0031): provider-first
                            ordering, the D6 UID-lock/--code-only rule, or a red pair.
                            Ledgered in private/pairs/<pair>.log. For paired sites only.
    --override-snapshot     Proceed with the destructive rsync --delete even when the
                            fail-closed pre-deploy WEBROOT snapshot (F2/P0-2) could not
                            be taken (disk-tight or tar failed). The --delete is then
                            UNRECOVERABLE. Ledgered in private/snapshots/<site>.log.
    --allow-profile-change  Override the fail-closed PROFILE-CHANGE GUARD and run
                            --code-only ACROSS a Drupal install-profile change on a
                            canonical:live|prod site. Almost certainly WRONG: --code-only
                            cannot cross a profile change (e.g. nwc → social), so the site
                            will likely be unbootable. See UNFORK-PROFILE-INTENT-2026-07-19.

${BOLD}ARGUMENTS:${NC}
    sitename                Site name (with or without _stg suffix)

${BOLD}EXAMPLES:${NC}
    ./stg2live.sh mysite              # Deploy mysite/stg/ to mysite.<prod-domain>
    ./stg2live.sh mysite-stg          # Same as above (legacy name accepted)
    ./stg2live.sh -y mysite           # Deploy without confirmation
    ./stg2live.sh --no-security mysite  # Deploy without security modules

${BOLD}PASSWORD SECURITY:${NC}
    Before deployment, this script automatically:
    - Regenerates the admin password to a secure 16-character random value
    - Detects users with weak passwords (password, admin, test123, etc.)
    - Resets weak passwords to secure random values
    - Displays the new admin password (SAVE IT!)
    Disable with: --no-password-reset flag

${BOLD}SECURITY HARDENING:${NC}
    By default, security modules are installed from nwp.yml settings.live_security
    Includes: seckit, honeypot, flood_control, login_security, etc.
    Disable with: --no-security flag or set enabled: false in nwp.yml

${BOLD}NOTE:${NC}
    If no live server is configured, this script will automatically
    call 'pl live' to provision one first.

${BOLD}REQUIREMENTS:${NC}
    - Staging site must exist and be in production mode

EOF
}

################################################################################
# PROFILE-CHANGE GUARD (fail-closed) — protect the --code-only primitive.
#
# A `--code-only` deploy pushes code/config but NOT the DB, so the live DB keeps
# recording whatever install profile it already has. If the staging build
# installs a DIFFERENT profile, `--code-only` cannot cross that change: the live
# DB keeps recording the OLD profile while the new code ships no such profile
# (e.g. nwc un-fork — live `nwc` → build `social`, Open Social under
# profiles/contrib/social/), so the site will not boot. The correct route is a
# fresh `drush site:install <target>` + recipe + Migrate import.
# See ~/central/UNFORK-PROFILE-INTENT-2026-07-19.md.
################################################################################

# Read the install profile the STAGING BUILD installs, from its config-sync
# core.extension.yml (`profile:` key). Offline — no live contact.
read_build_profile() {
    local stg_dir="$1" sync val
    sync="$stg_dir/html/sites/default/files/sync/core.extension.yml"
    [ -f "$sync" ] || return 1
    val="$(awk -F: '/^profile:/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$sync")"
    [ -n "$val" ] || return 1
    printf '%s\n' "$val"
}

# Read the LIVE site's installed profile from the live DB (READ-ONLY: drush
# config:get). Uses the same remote `sudo -u www-data drush` idiom (with the
# webroot/vendor fallback) as run_live_db_updates. Callers MUST NOT invoke this
# on --dry-run (it contacts the live host).
read_live_profile() {
    local base_name="$1" server_ip ssh_user remote_path webroot sudo_prefix out val
    server_ip=$(get_live_config "$base_name" "server_ip")
    [ -n "$server_ip" ] || return 1
    ssh_user=$(get_ssh_user "$base_name")
    remote_path=$(get_live_config "$base_name" "remote_path")
    [ -z "$remote_path" ] && remote_path="/var/www/${base_name}"
    webroot="web"
    sudo_prefix=""
    [ "$ssh_user" == "gitlab" ] && sudo_prefix="sudo"
    out="$(ssh $(nwp_ssh_opts "$base_name") "${ssh_user}@${server_ip}" \
            "cd ${remote_path} && $sudo_prefix -u www-data drush cget core.extension profile --format=string" 2>/dev/null \
        || ssh $(nwp_ssh_opts "$base_name") "${ssh_user}@${server_ip}" \
            "cd ${remote_path}/$webroot && $sudo_prefix -u www-data ../vendor/bin/drush cget core.extension profile --format=string" 2>/dev/null)"
    val="$(printf '%s\n' "$out" | awk 'NF{v=$NF} END{gsub(/[[:space:]'"'"'"]/,"",v); print v}')"
    [ -n "$val" ] || return 1
    printf '%s\n' "$val"
}

# Refuse a --code-only deploy that would cross an install-profile change on a
# canonical:live|prod site. Returns 0 = allowed, 1 = refused (fail-closed).
stg2live_profile_change_guard() {
    local base_name="$1" stg_dir="$2"
    local phase; phase=$(canonical_get_phase "$base_name" 2>/dev/null || echo dev)
    # Only content-bearing live/prod tiers are at risk; a dev target is throwaway.
    if [ "$phase" != "live" ] && [ "$phase" != "prod" ]; then
        return 0
    fi

    local target; target="$(read_build_profile "$stg_dir" 2>/dev/null || true)"
    if [ -z "$target" ]; then
        print_error "PROFILE-CHANGE GUARD: cannot read the staging build's install profile (core.extension.yml) — refusing --code-only (fail-closed)."
        print_hint "See ~/central/UNFORK-PROFILE-INTENT-2026-07-19.md."
        if [ "${ALLOW_PROFILE_CHANGE:-false}" == "true" ]; then
            print_warning "--allow-profile-change: proceeding despite an unreadable build profile — almost certainly WRONG."
            return 0
        fi
        return 1
    fi

    # --dry-run must touch NOTHING live: print the verdict and pass. A real run
    # reads the live profile and enforces the comparison below.
    if [ "${DRY_RUN:-false}" == "true" ]; then
        print_info "[dry-run] PROFILE-CHANGE GUARD: staging build installs profile '${target}'."
        print_info "[dry-run] a real --code-only run refuses if the LIVE profile differs from '${target}' (unless --allow-profile-change) — the live profile is not read on a dry run."
        return 0
    fi

    local live; live="$(read_live_profile "$base_name" 2>/dev/null || true)"
    if [ -z "$live" ]; then
        print_error "PROFILE-CHANGE GUARD: could not read the LIVE install profile — refusing --code-only (fail-closed)."
        print_hint "See ~/central/UNFORK-PROFILE-INTENT-2026-07-19.md."
        if [ "${ALLOW_PROFILE_CHANGE:-false}" == "true" ]; then
            print_warning "--allow-profile-change: proceeding despite an unreadable live profile — almost certainly WRONG."
            return 0
        fi
        return 1
    fi

    if [ "$live" != "$target" ]; then
        print_error "PROFILE-CHANGE GUARD: refusing --code-only across an install-profile change."
        print_error "Live installs profile '${live}' but the staging build installs profile '${target}'."
        print_error "--code-only CANNOT cross a profile change: the live DB keeps recording '${live}' while the new"
        print_error "code ships no '${live}' profile (Open Social sits under profiles/contrib/social/) → the site will not boot."
        print_hint "Correct route: Option 1 — fresh 'drush site:install ${target}' + recipe + Migrate import."
        print_hint "See ~/central/UNFORK-PROFILE-INTENT-2026-07-19.md (§4 Option 1)."
        if [ "${ALLOW_PROFILE_CHANGE:-false}" == "true" ]; then
            print_warning "--allow-profile-change: proceeding across the '${live}' → '${target}' profile change — almost certainly WRONG; the site will likely be unbootable."
            return 0
        fi
        return 1
    fi

    print_status "OK" "PROFILE-CHANGE GUARD: live profile '${live}' == build profile '${target}' — no profile change."
    return 0
}

################################################################################
# Deployment Functions
################################################################################

deploy_to_live() {
    local stg_site="$1"
    local base_name="$2"
    local auto_yes="$3"

    # Get live server config
    local server_ip=$(get_live_config "$base_name" "server_ip")
    local domain=$(get_live_config "$base_name" "domain")
    local server_type=$(get_live_config "$base_name" "type")

    if [ -z "$server_ip" ]; then
        print_error "No live server configured for $base_name"
        print_info "Run 'pl live $base_name' first to provision a live server"
        return 1
    fi

    local base_domain=$(get_base_domain)
    if [ -z "$domain" ]; then
        domain="${base_name}.${base_domain}"
    fi

    print_header "Deploy Staging to Live"
    echo -e "${BOLD}Staging:${NC}     $stg_site"
    echo -e "${BOLD}Live:${NC}        https://$domain"
    echo -e "${BOLD}Server:${NC}      $server_ip"
    echo -e "${BOLD}Type:${NC}        ${server_type:-shared}"
    echo ""

    # Check staging site exists
    if [ ! -d "$stg_site" ]; then
        print_error "Staging site not found: $stg_site"
        return 1
    fi

    # Secure passwords before deployment (regenerate admin, reset weak passwords).
    # Both of these mutate the staging site, so skip them on dry-run. On
    # --code-only the DB never leaves staging, so the password reset would
    # change nothing on live while printing a misleading new admin password —
    # skip it too (security modules still apply: they ship as code+config).
    if [ "${DRY_RUN:-false}" != "true" ]; then
        if [ "${CODE_ONLY:-false}" != "true" ]; then
            secure_user_passwords "$stg_site"
        else
            print_info "[code-only] skipping secure_user_passwords (database is not pushed)"
        fi
        install_security_modules "$stg_site"
    else
        print_info "[dry-run] skipping secure_user_passwords + install_security_modules (would mutate staging)"
    fi

    # Determine SSH user via resolution chain (F15)
    local ssh_user
    ssh_user=$(get_ssh_user "$base_name")

    # Test SSH connection
    print_info "Testing SSH connection..."
    if ! ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes -o ConnectTimeout=5 "${ssh_user}@${server_ip}" "echo ok" >/dev/null 2>&1; then
        print_error "Cannot connect to live server: ${ssh_user}@${server_ip}"
        return 1
    fi
    print_status "OK" "SSH connection successful (user: $ssh_user)"

    # D17 (ops#157): REFUSE now — before maintenance mode, before the
    # destructive rsync — if the staging tree has no drush. §3.6 runs
    # `drush updatedb` on live from the SYNCED vendor for BOTH full and
    # --code-only deploys; a drush-less staging vendor (drush was in
    # require-dev, stripped by dev2stg's `composer install --no-dev`) makes
    # that step abort AFTER maintenance is enabled, stranding the live site
    # (the 2026-07-29 incident: ~25 min down). Skipped on dry-run (no live
    # mutation to protect). Override for a genuinely drush-free deploy path
    # with NWP_ALLOW_NO_DRUSH=1.
    if [ "${DRY_RUN:-false}" != "true" ] && [ "${NWP_ALLOW_NO_DRUSH:-0}" != "1" ]; then
        if ! stg2live_stg_has_drush "$stg_site"; then
            # NOTE: describe the missing tool WITHOUT printing a pasteable
            # command-shape in a print_error — the pl-first lint
            # (test-doc-truth.bats) forbids a deploy verb prescribing a raw
            # ssh/drush recovery, and the path detail belongs in print_info.
            print_error "Staging tree carries no executable drush in its vendor directory."
            print_error "The post-sync database-update step runs on live from that vendor, so"
            print_error "this deploy would abort AFTER enabling maintenance mode and strand the"
            print_error "live site (ops#157)."
            print_info  "Checked: ${stg_site}/vendor and ${stg_site}/web/vendor."
            print_info  "Fix: move drush/drush to \"require\" in the site's composer.json (not"
            print_info  "require-dev — dev2stg's 'composer install --no-dev' strips it), rebuild"
            print_info  "staging with 'pl dev2stg <site>', and re-deploy."
            print_info  "(Override for a deliberately drush-free path: NWP_ALLOW_NO_DRUSH=1.)"
            return 1
        fi
        print_status "OK" "Staging carries drush — the live updatedb step can run."
    fi

    # Get webroot from staging site. Hoisted ABOVE the pre-deploy snapshot
    # (F2/P0-2) so the webroot tar and the rsync --delete share one resolution
    # of what the deploy is about to overwrite.
    local webroot="web"
    if [ -f "$stg_site/.ddev/config.yaml" ]; then
        webroot=$(grep "^docroot:" "$stg_site/.ddev/config.yaml" 2>/dev/null | awk '{print $2}')
        [ -z "$webroot" ] && webroot="web"
    fi

    # F23: read remote_path from per-site config, default to /var/www/<name>
    local remote_path
    remote_path=$(get_live_config "$base_name" "remote_path")
    [ -z "$remote_path" ] && remote_path="/var/www/${base_name}"

    # Belt-and-suspenders: snapshot the live host's DBs + nginx configs AND the
    # webroot before doing anything destructive. Cheap insurance; recovers from
    # DB-import gone-wrong, bad nginx config, and a bad rsync --delete swap.
    # Skipped on dry-run: a dry-run must not WRITE to the live host at all
    # (the snapshot dumps DBs + tars configs onto it) — ops#79.
    # F2/P0-2: the snapshot is now FAIL-CLOSED — a failure ABORTS the deploy
    # (exit 1) before the destructive rsync --delete, unless --override-snapshot.
    if [ "${DRY_RUN:-false}" != "true" ]; then
        if ! live_host_snapshot "$base_name" "$server_ip" "$ssh_user" "$remote_path" "$webroot"; then
            print_error "Pre-deploy snapshot failed — aborting before the destructive rsync --delete."
            print_error "(Override at your own risk with --override-snapshot.)"
            exit 1
        fi
    else
        print_info "[dry-run] skipping live-host snapshot (would write to the live host)"
    fi

    # Build rsync excludes
    local excludes=(
        "--exclude=.ddev"
        # DDEV also writes sites/default/settings.ddev.php (OUTSIDE .ddev/). It is
        # included un-guarded by DDEV's settings.php and forces symfony_mailer to a
        # mailpit SMTP at localhost:1025 — on a production host that has no mailpit,
        # every outbound mail then fails ("Unable to send email"). This is exactly
        # how nwc live went mail-dark (2026-07-20). It must never reach prod.
        "--exclude=$webroot/sites/default/settings.ddev.php"
        "--exclude=.git"
        "--exclude=.nwp.yml"
        "--exclude=$webroot/sites/default/settings.local.php"
        "--exclude=$webroot/sites/default/settings.local.overrides.php"
        "--exclude=$webroot/sites/default/files"
        "--exclude=private"
        "--exclude=node_modules"
        "--exclude=.env"
        "--exclude=.env.local"
        # Live-only runtime state that MUST survive rsync --delete. These are
        # generated ON the live host and never exist in staging, so without an
        # exclude the --delete would remove them:
        #   oauth-keys/  simple_oauth signing keys — deleting them breaks all
        #                OAuth/OIDC logins (SSO) on live instantly.
        #   auth.json    composer credentials for the live host; overwriting it
        #                with staging's can break composer auth on live.
        "--exclude=oauth-keys"
        "--exclude=auth.json"
    )

    # ...but "oauth-keys" is only ONE of the names simple_oauth uses. nwc keeps
    # its keypair in oauth-keys/, nwd keeps it in keys/ — the directory is
    # whatever simple_oauth.settings points at, and hardcoding one name meant
    # the other site got NONE of the protection above: rsync --delete would
    # remove its signing keys and the chown below would hand private.key
    # (0600) to the gitlab user, after which www-data cannot read it and EVERY
    # OIDC/SSO login fails. So ask Drupal where its keys actually are.
    #
    # Fail SAFE, not silent: if the answer cannot be read, protect every name we
    # know of rather than assuming the default. An over-broad exclude leaves a
    # stale directory behind; an under-broad one breaks live SSO.
    local key_dirs=() key_dir_msg=""
    local _kd
    _kd="$(ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" \
            "cd ${remote_path} && ${drush_sudo:-sudo -u www-data} vendor/bin/drush cget simple_oauth.settings private_key --format=string 2>/dev/null" 2>/dev/null | tr -d '\r')"
    if [[ -n "$_kd" && "$_kd" == /* ]]; then
        _kd="$(dirname "$_kd")"
        # Only the basename is useful as an rsync exclude (they are relative to
        # the transfer root).
        key_dirs+=("$(basename "$_kd")")
        key_dir_msg="simple_oauth keys live in ${_kd} — excluded from the sync"
    else
        key_dirs+=("oauth-keys" "keys")
        key_dir_msg="could not read simple_oauth.settings — protecting BOTH 'oauth-keys' and 'keys' (fail-safe)"
    fi
    for _kd in "${key_dirs[@]}"; do
        [[ "$_kd" == "oauth-keys" ]] && continue   # already in the list above
        excludes+=("--exclude=${_kd}")
    done
    print_info "$key_dir_msg"

    # Sync files
    print_header "Syncing Files"
    print_info "Source: $stg_site/"
    print_info "Destination: ${ssh_user}@${server_ip}:${remote_path}/"

    local sudo_prefix=""
    if [ "$ssh_user" == "gitlab" ]; then
        sudo_prefix="sudo"
    fi

    # Ensure target directory exists with correct ownership for rsync.
    # Skipped on dry-run: mkdir/chown are real writes to the live host — ops#79.
    if [ "${DRY_RUN:-false}" != "true" ]; then
        ssh $(nwp_ssh_opts "$base_name") "${ssh_user}@${server_ip}" "$sudo_prefix mkdir -p ${remote_path}" 2>/dev/null || true
        if [ "$ssh_user" == "gitlab" ]; then
            # Give gitlab user ownership temporarily for rsync — but NEVER touch
            # oauth-keys/. Those are the simple_oauth signing keys (0600, www-data);
            # rsync already excludes them, so gitlab needs no access. If the -R
            # chown reassigned them to gitlab and the deploy then aborted before
            # the post-rsync chown restored www-data:www-data, www-data could no
            # longer read private.key and EVERY SSO/OIDC login would break until a
            # manual re-chown. Prune oauth-keys so it stays www-data-owned throughout.
            # Prune EVERY simple_oauth key directory, not just the literal
            # "oauth-keys" — see the key_dirs resolution above. Missing one here
            # is what would silently break live SSO.
            local _prune=""
            for _kd in "${key_dirs[@]}"; do
                _prune+=" -path ${remote_path}/${_kd} -prune -o"
            done
            ssh $(nwp_ssh_opts "$base_name") "${ssh_user}@${server_ip}" \
                "sudo find ${remote_path}${_prune} -exec chown gitlab:www-data {} +" 2>/dev/null || true
        fi
    else
        print_info "[dry-run] skipping remote mkdir/chown (would write to the live host)"
    fi

    # G3: hoist maintenance mode ON BEFORE the destructive rsync --delete so
    # members never see a half-populated webroot mid-swap. Skipped on --dry-run
    # (a dry-run must not write to the live host — the rsync itself runs with
    # --dry-run below). Left ON if any later step aborts (fail-loud); dropped
    # after the post-sync updatedb/cr sequence on success.
    if [ "${DRY_RUN:-false}" != "true" ]; then
        live_maintenance_set "$base_name" "$server_ip" "$ssh_user" "$webroot" "$remote_path" 1
    else
        print_info "[dry-run] skipping maintenance-mode enable (would write to the live host)"
    fi

    # Rsync (quiet by default, verbose with -v flag). On dry-run we add
    # --dry-run so rsync prints the planned changes without writing anything;
    # we always print the verbose summary in that mode so the operator
    # actually sees what would change.
    #
    # --no-owner --no-group: the ssh user is 'gitlab' (non-root), pre-chowned to
    # gitlab:www-data above. -a's implicit -o/-g would then try to chgrp each
    # destination file to the STAGING source's group, which the gitlab user
    # cannot set -> "chgrp ... Operation not permitted" and rsync aborts (code
    # 23), leaving the webroot half-synced + maintenance mode stuck ON. This bit
    # a live --code-only deploy (2026-07-21: behat.yml + the html/modules/custom
    # symlink). Owner/group preservation is redundant here anyway — the
    # post-rsync `chown -R www-data:www-data` (below) sets final ownership. So we
    # drop owner/group preservation and let that chown be authoritative.
    local rsync_opts="-az --no-owner --no-group"
    if [ "${VERBOSE:-false}" == "true" ]; then
        rsync_opts="-avz --no-owner --no-group"
    fi
    local rsync_dryflag=""
    if [ "${DRY_RUN:-false}" == "true" ]; then
        rsync_dryflag="--dry-run"
        rsync_opts="-avz"
        print_info "[dry-run] rsync --dry-run output:"
    fi

    if rsync -e "ssh $(nwp_ssh_opts "$base_name")" $rsync_opts $rsync_dryflag --delete "${excludes[@]}" \
        "$stg_site/" \
        "${ssh_user}@${server_ip}:${remote_path}/"; then
        print_status "OK" "Files synced"
    else
        print_error "File sync failed (maintenance mode left ON — verify the live host / rollback)."
        return 1
    fi

    # Set permissions
    if [ "${DRY_RUN:-false}" == "true" ]; then
        print_info "[dry-run] would chown -R www-data:www-data ${remote_path}"
    else
        print_info "Setting permissions..."
        ssh $(nwp_ssh_opts "$base_name") "${ssh_user}@${server_ip}" "$sudo_prefix chown -R www-data:www-data ${remote_path}" 2>/dev/null || true
    fi

    # Deploy database (creates DB, generates settings.local.php, imports data).
    # Hard stop on dry-run before any DB write: this is the most destructive
    # step in the script, so we don't want to do even read-only DB queries
    # in dry-run beyond what the snapshot already did.
    if [ "${DRY_RUN:-false}" == "true" ]; then
        # The plan must match what the real run would DO. This printer used to
        # announce the DB import unconditionally, so a --code-only --dry-run
        # showed "would import into live DB" — a plan for a step the real run
        # provably skips. A dry run that misdescribes the mutation it is
        # rehearsing is worse than none: it teaches the operator to expect (or
        # fear) the wrong thing.
        if [ "${CODE_ONLY:-false}" == "true" ]; then
            print_info "[dry-run] [code-only] DB push SKIPPED — live content preserved"
        else
            local stg_db_name="${base_name}_stg"
            local live_db_name="${base_name}"
            print_info "[dry-run] would dump stg DB '${stg_db_name}' and import into live DB '${live_db_name}' on ${server_ip}"
            print_info "[dry-run] would generate fresh settings.local.php for live"
        fi
        print_info "[dry-run] would run drush updatedb -y + cache:rebuild on live (§3.6)"
        print_info "[dry-run] would run drush cr on live"
        print_status "OK" "Dry run complete; no destructive ops executed"
        return 0
    fi
    # Determine the canonical phase once for the P2-2 DB-push guard below.
    local _phase
    _phase=$(canonical_get_phase "$base_name" 2>/dev/null || echo dev)
    if [ "${CODE_ONLY:-false}" == "true" ]; then
        print_info "[code-only] skipping database push — live content preserved (canonical: ${_phase})"
    elif { [ "$_phase" == "live" ] || [ "$_phase" == "prod" ]; } && [ "${PUSH_CONTENT:-false}" != "true" ]; then
        # P2-2/INV-1 (design 2026-07-19 §6): full_database_deployment imports the
        # staging DB OVER the live database. On a canonical:live|prod site that
        # would clobber the live member DB — a live-data-sovereignty violation.
        # REFUSE by default; the operator must opt in with --push-content (or use
        # --code-only, the canonical:live default). This is the second independent
        # INV-1 guard alongside the pair contract (F4-forward-to-P0).
        print_error "Refusing to push the staging DB over the LIVE member database (canonical:${_phase}, INV-1)."
        print_error "Use --code-only to deploy code/config only (the canonical:live default),"
        print_error "or --push-content to intentionally overwrite live content."
        print_error "Maintenance mode was enabled before the file sync — verify/disable it after you resolve this."
        return 1
    elif ! full_database_deployment "$stg_site" "$base_name" "$server_ip" "$ssh_user" "$webroot"; then
        # F4 (design 2026-07-19 §Critic F4): a FAILED live DB import must ABORT,
        # not WARN-and-continue. A half-imported member DB served live violates
        # INV-1 (live data sovereignty); fail loud so the operator restores from
        # the pre-deploy snapshot rather than serving broken/partial data.
        print_error "Live database deployment FAILED — aborting deploy (maintenance mode left ON)."
        print_error "Recover the live DB from the pre-deploy snapshot: pl rollback execute ${base_name} prod"
        return 1
    fi

    # §3.6 (design 2026-07-19): run the Drupal DB-update sequence on live AFTER
    # the code sync (and DB push, if any), for BOTH full and --code-only modes.
    # stg2live historically ran NO updatedb, leaving code + schema mismatched
    # after a code swap. Runs BEFORE the final `drush cr` below.
    # ABORT if updatedb failed (fail-loud): leave maintenance ON, point to
    # rollback — do NOT fall through to maintenance-OFF and report success with a
    # half-updated schema (2026-07-21 incident).
    if ! run_live_db_updates "$base_name" "$server_ip" "$ssh_user" "$webroot" "$remote_path"; then
        print_error "Live DB updates FAILED — aborting (maintenance left ON). Rollback: pl rollback execute ${base_name} prod"
        return 1
    fi

    # G3: post-sync updatedb/cr sequence is done and the swap is coherent — drop
    # maintenance mode so the site serves members again. Skipped on --dry-run
    # (which returned earlier, before any live write). Only reached on the
    # success path; every error path above returns without disabling it.
    if [ "${DRY_RUN:-false}" != "true" ]; then
        live_maintenance_set "$base_name" "$server_ip" "$ssh_user" "$webroot" "$remote_path" 0
    fi

    # Setup SSL certificate
    print_header "SSL Certificate"
    if ! setup_ssl_certificate "$base_name" "$server_ip" "$ssh_user"; then
        print_status "WARN" "SSL setup incomplete - site may not have HTTPS"
    fi

    # Deploy production robots.txt
    print_header "SEO Configuration"
    deploy_production_robots "$base_name" "$server_ip" "$ssh_user" "$domain"

    # Run post-deployment commands
    print_header "Post-Deployment Tasks"

    # Clear cache via drush if available
    print_info "Clearing cache..."
    ssh $(nwp_ssh_opts "$base_name") "${ssh_user}@${server_ip}" "cd ${remote_path} && $sudo_prefix -u www-data drush cr" 2>/dev/null || \
        ssh $(nwp_ssh_opts "$base_name") "${ssh_user}@${server_ip}" "cd ${remote_path}/$webroot && $sudo_prefix -u www-data ../vendor/bin/drush cr" 2>/dev/null || \
        print_status "WARN" "Could not clear cache (drush may not be available)"

    # Verify and configure site email
    verify_site_email "$base_name" "$server_ip" "$ssh_user"

    # Success
    print_header "Deployment Complete"
    print_status "OK" "Staging deployed to live server"

    # Stamp the canonical phase into a deploy manifest (nwp/ops#33) so a
    # restore/audit can tell which content-flow regime this deploy ran under.
    local deploy_manifest
    deploy_manifest=$(canonical_deploy_manifest "$base_name" "stg2live" \
        "code_only=${CODE_ONLY:-false}" "override=${OVERRIDE_CANONICAL:-false}" \
        "domain=${domain}" 2>/dev/null) || true
    [ -n "$deploy_manifest" ] && print_info "Deploy manifest: $deploy_manifest"

    echo ""
    echo -e "  ${BOLD}Live URL:${NC} ${GREEN}https://${domain}${NC}"
    echo ""

    return 0
}

################################################################################
# FRESH-BUILD PLAN (nwc un-fork go-live). Prints the ordered, side-by-side
# fresh-install cutover for review — the executable form of the ratified
# NWC-GO-LIVE-FRESH-BUILD plan. Pure/read-only: resolves names + prints; runs
# nothing. The mutation path is deliberately not here (attended rehearsal first).
################################################################################
fresh_build_plan() {
    local base_name="$1"
    local stg_dir="$2"

    local remote_path
    remote_path=$(get_live_config "$base_name" "remote_path")
    [ -z "$remote_path" ] && remote_path="/var/www/${base_name}"
    local db_name="${base_name//-/_}"
    # Deterministic-per-run timestamp for the side docroot/DB names.
    local ts
    ts=$(date +%Y%m%d%H%M%S 2>/dev/null || echo TS)
    local side_docroot="${remote_path}-${ts}"
    local side_db="${db_name}_fresh_${ts}"

    print_header "pl stg2live ${base_name} --fresh-build — PLAN (review only)"
    print_info "Builds a FRESH Open-Social+nwc site ALONGSIDE the running live site, then the operator flips a symlink. No data migrated; the old docroot+DB are kept as an instant rollback."
    cat <<EOF

  Source (code)  : ${stg_dir}         (rsync, NO --delete, dev-file excludes applied)
  Side docroot   : ${side_docroot}    (live ${remote_path} stays untouched until the flip)
  Side database  : ${side_db}          (fresh; live DB '${db_name}' preserved for rollback)

  Build sequence (each run via: pl drush ${base_name} --tier=live --root=${side_docroot} --execute -- …):
    1. site:install social            (php memory_limit=2G — 512M OOMs)
    2. recipe <nwc>/recipes/full
    3. nwc:config-heal                 (recover the ~41 recipe-skipped configs)
    4. pl secrets inject ${base_name} --tier=live   (cross-site tokens + moodle config into the side docroot)
    5. nwc-copyright:sync              (5 data_policy legal docs from canonical-text)
    6. simple-oauth:generate-keys + OIDC consumer; re-provision the ssc link (new keys)

  Health gate (before any flip):
    - pl link verify ${base_name} --tier=live --round-trip   (OIDC sub==uuid + copyright_sync)
    - assert the side docroot ships NO DDEV dev settings file (mail guard)
    - pl monitor mail ${base_name} == GREEN

  Flip (operator, via pl cutover): repoint ${remote_path} symlink at the side docroot; reload php-fpm; opcache reset; nginx reload; drush cr
  Rollback: repoint ${remote_path} at the old docroot + reload (instant; nothing was migrated)
EOF
    print_status "OK" "[plan] nothing executed."
}

################################################################################
# Main
################################################################################

# PL-STG2LIVE §4.1: a Moodle site's live promotion is handled by the guarded
# `pl moodle` family (per-plugin rsync + upgrade under maintenance), NOT the
# Drupal whole-webroot rsync path. Detect project.type==moodle BEFORE getopt
# (moodle.sh has its own flag grammar) and hand off. No-op — and thus safe — for
# every non-moodle site (the common case), so nothing else changes.
_maybe_delegate_moodle() {
    local delegate_verb="$1"; shift
    local a site=""
    for a in "$@"; do
        case "$a" in -*) continue ;; *) site="$a"; break ;; esac
    done
    [ -n "$site" ] || return 0
    local base cfg ptype="" yq_bin=""
    base="$(get_base_name "$site" 2>/dev/null || echo "$site")"
    # Read project.type straight from the site config file (independent of
    # resolve_project so the detection can never be silently dropped).
    cfg="${PROJECT_ROOT:-$HOME/nwp}/sites/${base}/.nwp.yml"
    [ -f "$cfg" ] || return 0
    if command -v yq >/dev/null 2>&1; then yq_bin=yq
    elif [ -x "$HOME/.local/bin/yq" ]; then yq_bin="$HOME/.local/bin/yq"; fi
    [ -n "$yq_bin" ] && ptype="$("$yq_bin" eval '.project.type' "$cfg" 2>/dev/null || true)"
    case "$ptype" in
        moodle|Moodle|MOODLE)
            exec "${SCRIPT_DIR}/moodle.sh" "$delegate_verb" "$@"
            ;;
    esac
    return 0
}

main() {
    _maybe_delegate_moodle "stg2live" "$@"
    local DEBUG=false
    local YES=false
    local VERBOSE=false
    local SKIP_SECURITY=false
    local SKIP_PASSWORD_RESET=false
    local NO_PROVISION=false
    local DRY_RUN=false
    local CODE_ONLY=false
    local PUSH_CONTENT=false
    local OVERRIDE_CANONICAL=false
    local OVERRIDE_PAIR=false
    local OVERRIDE_SNAPSHOT=false
    local ALLOW_PROFILE_CHANGE=false
    local FRESH_BUILD=false
    local SITENAME=""

    # Parse options
    local OPTIONS=hdyv
    local LONGOPTS=help,debug,yes,verbose,no-security,no-password-reset,no-provision,dry-run,code-only,push-content,override-canonical,override-pair,override-snapshot,allow-profile-change,fresh-build

    if ! PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTS --name "$0" -- "$@"); then
        show_help
        exit 1
    fi

    eval set -- "$PARSED"

    while true; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            -d|--debug) DEBUG=true; shift ;;
            -y|--yes) YES=true; shift ;;
            -v|--verbose) VERBOSE=true; shift ;;
            --no-security) SKIP_SECURITY=true; shift ;;
            --no-password-reset) SKIP_PASSWORD_RESET=true; shift ;;
            --no-provision) NO_PROVISION=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --code-only) CODE_ONLY=true; shift ;;
            --push-content) PUSH_CONTENT=true; shift ;;
            --override-canonical) OVERRIDE_CANONICAL=true; shift ;;
            --override-pair) OVERRIDE_PAIR=true; shift ;;
            --override-snapshot) OVERRIDE_SNAPSHOT=true; shift ;;
            --allow-profile-change) ALLOW_PROFILE_CHANGE=true; shift ;;
            --fresh-build) FRESH_BUILD=true; shift ;;
            --) shift; break ;;
            *) echo "Programming error"; exit 3 ;;
        esac
    done

    # --fresh-build and --code-only are contradictory routes (fresh install vs
    # in-place code swap). Refuse both.
    if [ "$FRESH_BUILD" = "true" ] && [ "$CODE_ONLY" = "true" ]; then
        print_error "--fresh-build and --code-only are mutually exclusive (fresh install vs in-place code swap)."
        exit 1
    fi

    # Export so deploy_to_live and friends can read it.
    export DRY_RUN CODE_ONLY PUSH_CONTENT OVERRIDE_CANONICAL OVERRIDE_PAIR OVERRIDE_SNAPSHOT ALLOW_PROFILE_CHANGE FRESH_BUILD

    # Get sitename
    if [ $# -ge 1 ]; then
        SITENAME="$1"
    else
        print_error "Sitename required"
        show_help
        exit 1
    fi

    # Normalize names
    local BASE_NAME=$(get_base_name "$SITENAME")

    # F23: resolve stg directory (v2: sites/<name>/stg/, v1: sites/<name>-stg/)
    local STG_DIR
    STG_DIR=$(get_stg_dir "$SITENAME")
    if [ -z "$STG_DIR" ]; then
        print_error "Cannot resolve staging directory for $BASE_NAME"
        exit 1
    fi

    # Honor the per-site live.enabled flag. Without this guard, every site
    # with a `live.server: <known-server>` entry deploys to that server
    # regardless of whether live deployment was intentionally disabled —
    # which is exactly the misfire the "enabled" flag exists to prevent.
    # Found 2026-05-20: a system-test fixture had `live.enabled: false`
    # set explicitly but stg2live still progressed to "Pre-Deploy
    # Snapshot" on the live host because the flag was never checked.
    local live_enabled
    live_enabled=$(get_live_config "$BASE_NAME" "enabled")
    if [ "$live_enabled" = "false" ]; then
        print_error "Live deployment disabled for '$BASE_NAME' (live.enabled: false in sites/$BASE_NAME/.nwp.yml)"
        print_info "To enable: set live.enabled: true in the site's .nwp.yml, or pass --force-enabled (not yet implemented)."
        exit 1
    fi

    # --fresh-build: the nwc un-fork go-live route (fresh install alongside +
    # flip), NOT the in-place code swap. Short-circuits the normal deploy path.
    # Currently PLAN-ONLY: it prints exactly what the cutover will do and
    # fail-closes on a real run, because the live-mutation path (side DB/docroot
    # provisioning) MUST be built + rehearsed attended (cutover design step 3).
    if [ "$FRESH_BUILD" = "true" ]; then
        fresh_build_plan "$BASE_NAME" "$STG_DIR"
        if [ "$DRY_RUN" = "true" ]; then
            exit 0
        fi
        print_warning "The --fresh-build EXECUTE path is not yet wired — nothing was run."
        print_info "It provisions a live DB + docroot and must be rehearsed attended first (see ~/central/NWC-CUTOVER-RESCOPE-DESIGN-2026-07-20.md step 3). Re-run with --dry-run to just view the plan."
        exit 2
    fi

    # Canonicality guard (nwp/ops#33): a dev→live CONTENT push is allowed only
    # while the site is canonical: dev — otherwise it would clobber the
    # canonical content source. --code-only skips the DB push (content
    # preserved) and is always allowed; --override-canonical is the audited
    # escape hatch (loud warning + private/canonical/<site>.log record).
    # canonical: prod additionally requires deploys from a clean CI-gated main.
    if [ "$CODE_ONLY" != "true" ]; then
        if ! canonical_guard_content_push "$BASE_NAME" "live" "$OVERRIDE_CANONICAL" "stg2live"; then
            exit 1
        fi
    fi
    if ! canonical_enforce_branch_policy "$BASE_NAME" "deploy"; then
        exit 1
    fi
    # Maturity guard (P67/ops#48): the code-flow class gates HOW code may
    # reach live — incubating: direct; stabilizing: clean merged main only;
    # production: signed-bundle path only.
    if ! maturity_guard_deploy "$BASE_NAME" "stg2live"; then
        exit 1
    fi
    # Pair guard (NWP-ADR-0031/ops#75): for a paired site (ssc↔nwc, ssd↔nwd) refuse a
    # promotion that violates provider-first ordering, the D6 UID-lock/--code-only
    # rule, or a red pair. No-op for unpaired sites; fail-closed on a declared pair
    # whose contract is missing. --override-pair is the ledgered escape.
    # ops#75/ops#83: pass the provider code root (the staging tree being promoted)
    # so pair_provider_sub_shape_guard can statically verify the deployed source
    # still emits the contracted UUID sub. Inert for non-provider/uncoupled sites.
    if ! pair_guard "$BASE_NAME" "live" "stg2live" "$CODE_ONLY" "$OVERRIDE_PAIR" "$STG_DIR"; then
        exit 1
    fi

    # PROFILE-CHANGE GUARD (fail-closed) — a --code-only deploy CANNOT cross a
    # Drupal install-profile change. On a canonical:live|prod site, if the LIVE
    # DB installs a DIFFERENT profile than the staging build, --code-only leaves
    # the live DB recording the OLD profile while the new code ships no such
    # profile — e.g. the nwc un-fork: live `nwc` → build `social`, which hides
    # Open Social under profiles/contrib/social/ so the site will not boot.
    # Refuse unless --allow-profile-change (which is almost certainly wrong).
    # See ~/central/UNFORK-PROFILE-INTENT-2026-07-19.md. Inert for same-profile
    # sites, non-code-only deploys, and dev-phase targets. Runs BEFORE the
    # destructive deploy_to_live; --dry-run prints the verdict, touches nothing live.
    if [ "$CODE_ONLY" == "true" ]; then
        if ! stg2live_profile_change_guard "$BASE_NAME" "$STG_DIR"; then
            exit 1
        fi
    fi

    # Hardware+signature gate on the live write (NWP-ADR-0028). No-op on the test
    # tier (unconfigured); on ver it requires a live Solo touch. Skipped for
    # a dry run (nothing is written).
    if [ "${DRY_RUN:-false}" != "true" ]; then
        deploy_gate_require "$BASE_NAME" "live" \
            "rsync files → live webroot (--delete); DB push unless --code-only" || exit 1
    fi

    # Export for use in deploy function
    export SKIP_SECURITY VERBOSE
    export SKIP_PASSWORD_RESET

    # Check if live server is configured
    local server_ip=$(get_live_config "$BASE_NAME" "server_ip")

    if [ -z "$server_ip" ] && [ "$NO_PROVISION" != "true" ]; then
        print_info "No live server configured for $BASE_NAME"
        print_info "Provisioning live server first..."
        echo ""

        # Call live.sh to provision (it will call back to us with --no-provision)
        if "${SCRIPT_DIR}/live.sh" -y "$BASE_NAME"; then
            # live.sh already called stg2live with --no-provision, so we're done
            exit 0
        else
            print_error "Failed to provision live server for: $BASE_NAME"
            exit 1
        fi
    fi

    # Run deployment
    if deploy_to_live "$STG_DIR" "$BASE_NAME" "$YES"; then
        # Record the pair contract_version this half reached at live so the
        # provider-first ordering check can compare halves (best-effort; a
        # dry run wrote nothing so it is skipped). No-op for unpaired sites.
        if [ "${DRY_RUN:-false}" != "true" ]; then
            pair_guard_record_success "$BASE_NAME" "live" || true
        fi
        show_elapsed_time
        exit 0
    else
        print_error "Deployment to live failed: $STG_DIR → $BASE_NAME"
        exit 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
