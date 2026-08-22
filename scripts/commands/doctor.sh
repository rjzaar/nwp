#!/usr/bin/env bash
# NWP Doctor - Diagnostic and troubleshooting command
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/migrate-schema.sh"
source "$PROJECT_ROOT/lib/rotation-debt.sh"   # known-exposed credentials / go-live gate (D8)

# Expose NWP_DIR / NWP_VERSION to the schema check (needed by migrate-schema.sh).
NWP_DIR="$PROJECT_ROOT"
NWP_VERSION=$(grep -E '^VERSION=' "$PROJECT_ROOT/pl" | head -1 | sed 's/.*="\(.*\)"/\1/')
export NWP_DIR NWP_VERSION

################################################################################
# Help Function
################################################################################

show_help() {
    cat << 'EOF'
Usage: pl doctor [OPTIONS]

Diagnose common issues and verify NWP configuration.

Options:
    -v, --verbose    Show detailed output for all checks
    -q, --quiet      Only show errors
    -h, --help       Show this help message

Checks performed:
    - System prerequisites (Docker, DDEV, PHP, Composer, yq, git)
    - Configuration files (nwp.yml, .secrets.yml)
    - Network connectivity (Linode API, Cloudflare API, drupal.org)
    - Common issues (Docker daemon, DDEV sites, disk space, memory)
    - Version control (commits/repos that exist only on this machine)

Exit codes:
    0 - All checks passed
    1 - One or more issues found

Examples:
    pl doctor              # Run all diagnostics
    pl doctor --verbose    # Show detailed output
    NO_COLOR=1 pl doctor   # Disable color output

EOF
}

################################################################################
# Check Functions
################################################################################

# First diagnostic (ops#77): is the global `pl` command registered? On a fresh
# clone `./pl setup` has not been run, so `pl` is not on PATH and every other
# instruction that says "pl ..." fails confusingly. Surface the fix up front.
check_pl_registration() {
    print_header "Checking pl Registration"

    if command -v pl &>/dev/null; then
        print_success "pl: registered ($(command -v pl))"
    else
        print_warning "pl not registered — run: ./pl setup"
        print_hint "'./pl setup' installs the global 'pl' command (to /usr/local/bin/pl) so you can run 'pl' from any directory."
    fi

    # Advisory only — does not count toward the error total.
    return 0
}

check_prerequisites() {
    local errors=0

    print_header "Checking Prerequisites"

    # Docker (required)
    if command -v docker &>/dev/null; then
        local docker_version=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
        print_success "Docker: $docker_version"

        # Check if Docker daemon is running
        if ! docker info &>/dev/null; then
            print_error "Docker daemon is not running"
            print_hint "Start Docker Desktop or run: sudo systemctl start docker"
            ((errors++))
        fi
    else
        print_error "Docker: NOT INSTALLED"
        print_hint "Install from: https://docs.docker.com/get-docker/"
        ((errors++))
    fi

    # DDEV (required)
    if command -v ddev &>/dev/null; then
        local ddev_version=$(ddev version 2>/dev/null | grep "DDEV version" | grep -oP 'v\d+\.\d+\.\d+' || echo "unknown")
        print_success "DDEV: $ddev_version"
    else
        print_error "DDEV: NOT INSTALLED"
        print_hint "Install from: https://ddev.readthedocs.io/en/stable/"
        ((errors++))
    fi

    # PHP (optional)
    if command -v php &>/dev/null; then
        local php_version=$(php -v 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
        print_success "PHP: $php_version (optional)"
    else
        print_warning "PHP: NOT INSTALLED (optional for local development)"
    fi

    # Composer (optional)
    if command -v composer &>/dev/null; then
        local composer_version=$(composer --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
        print_success "Composer: $composer_version (optional)"
    else
        print_warning "Composer: NOT INSTALLED (optional, DDEV includes it)"
    fi

    # yq (recommended) — must be the *mikefarah* binary, and NOT snap-confined.
    # Two silent impostors break NWP (ops#77):
    #   (a) Ubuntu's apt `yq` is a different tool (a Python jq-wrapper); its
    #       `--version` does not mention mikefarah and it has no `eval`.
    #   (b) snap-confined mikefarah yq IS mikefarah, but snap confinement stops
    #       it reading /tmp, which silently breaks `pl config import` (the staged
    #       manifest reads back as "not valid JSON").
    if command -v yq &>/dev/null; then
        local yq_path yq_verline
        yq_path="$(command -v yq)"
        yq_verline="$(yq --version 2>&1 | head -1)"
        if ! printf '%s' "$yq_verline" | grep -qi 'mikefarah'; then
            print_error "yq: wrong tool at $yq_path (not mikefarah yq)"
            print_hint "Ubuntu's apt 'yq' is a different (Python jq-wrapper) tool that NWP cannot use."
            print_hint "Install the pinned mikefarah binary to /usr/local/bin/yq — run: ./pl setup"
            errors=$((errors + 1))
        elif [[ "$yq_path" == /snap/* ]]; then
            print_error "yq: snap-confined mikefarah yq at $yq_path"
            print_hint "snap confinement blocks yq from reading /tmp, which silently breaks 'pl config import'."
            print_hint "Remove the snap (sudo snap remove yq) and install the pinned binary — run: ./pl setup"
            errors=$((errors + 1))
        else
            local yq_version
            yq_version="$(printf '%s' "$yq_verline" | grep -oP '\d+\.\d+\.\d+' || echo "unknown")"
            print_success "yq: $yq_version (mikefarah, $yq_path)"
        fi
    else
        print_warning "yq: NOT INSTALLED (recommended for faster YAML parsing)"
        print_hint "Install from: https://github.com/mikefarah/yq"
    fi

    # git (required)
    if command -v git &>/dev/null; then
        local git_version=$(git --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
        print_success "Git: $git_version"
    else
        print_error "Git: NOT INSTALLED"
        print_hint "Install git from your package manager: sudo apt install git"
        ((errors++))
    fi

    return $errors
}

check_configuration() {
    local errors=0

    print_header "Checking Configuration"

    # nwp.yml exists
    if [ -f "$PROJECT_ROOT/nwp.yml" ]; then
        print_success "nwp.yml: Found"

        # Validate YAML syntax
        if command -v yq &>/dev/null; then
            if yq eval '.' "$PROJECT_ROOT/nwp.yml" &>/dev/null; then
                print_success "nwp.yml: Valid YAML syntax"
            else
                print_error "nwp.yml: Invalid YAML syntax"
                print_hint "Check for syntax errors: yq eval . nwp.yml"
                ((errors++))
            fi
        fi

        # Check for sites defined (F36 A-C2: yq-first per ADR-0015)
        local site_count=0
        if grep -q "^sites:" "$PROJECT_ROOT/nwp.yml" 2>/dev/null; then
            site_count=$(yq eval '.sites | length' "$PROJECT_ROOT/nwp.yml" 2>/dev/null)
            [ -z "$site_count" ] || [ "$site_count" = "null" ] && site_count=0
        fi

        if [ "$site_count" -gt 0 ]; then
            print_success "Sites configured: $site_count"
        else
            print_warning "No sites configured in nwp.yml"
            print_hint "Create a site with: pl install <sitename> <recipe>"
        fi
    else
        print_error "nwp.yml: NOT FOUND"
        print_hint "Copy example.nwp.yml to nwp.yml and configure"
        ((errors++))
    fi

    # .secrets.yml exists (infrastructure secrets)
    if [ -f "$PROJECT_ROOT/.secrets.yml" ]; then
        print_success ".secrets.yml: Found (infrastructure secrets)"
    else
        print_warning ".secrets.yml: NOT FOUND (needed for Linode/Cloudflare)"
        print_hint "Copy .secrets.example.yml to .secrets.yml and add your API tokens"
    fi

    # Check sites directory
    if [ -d "$PROJECT_ROOT/sites" ]; then
        local installed_count=$(find "$PROJECT_ROOT/sites" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        if [ "$installed_count" -gt 0 ]; then
            print_success "Sites directory: $installed_count site(s) installed"
        else
            print_info "Sites directory: exists but empty"
        fi
    else
        print_info "Sites directory: NOT FOUND (will be created on first install)"
    fi

    return $errors
}

check_network() {
    local errors=0

    print_header "Checking Network Connectivity"

    # Linode API
    if curl -sf --max-time 5 "https://api.linode.com/v4/regions" -o /dev/null 2>&1; then
        print_success "Linode API: Reachable"
    else
        print_warning "Linode API: Unreachable (may affect server commands)"
        print_hint "Check your internet connection or firewall settings"
    fi

    # Cloudflare API
    if curl -sf --max-time 5 "https://api.cloudflare.com/client/v4" -o /dev/null 2>&1; then
        print_success "Cloudflare API: Reachable"
    else
        print_warning "Cloudflare API: Unreachable (may affect DNS commands)"
        print_hint "Check your internet connection or firewall settings"
    fi

    # drupal.org
    if curl -sf --max-time 5 "https://www.drupal.org/" -o /dev/null 2>&1; then
        print_success "drupal.org: Reachable"
    else
        print_warning "drupal.org: Unreachable (may affect Drupal downloads)"
        print_hint "Check your internet connection"
    fi

    return $errors
}

check_gitlab_token() {
    local errors=0
    print_header "Checking GitLab Token"

    # gitlab_token_status lives in lib/git.sh (not auto-sourced by doctor).
    command -v gitlab_token_status >/dev/null 2>&1 || source "$PROJECT_ROOT/lib/git.sh"

    local line status owner is_admin expires
    line="$(gitlab_token_status)"
    IFS='|' read -r status owner is_admin expires <<< "$line"

    case "$status" in
        MISSING)
            print_warning "GitLab token (gitlab.api_token): not set"
            print_hint "Set it:  pl secrets set gitlab.api_token"
            ;;
        NOURL)
            print_warning "GitLab token: can't resolve the GitLab URL (settings.url in nwp.yml)"
            ;;
        UNREACHABLE)
            print_warning "GitLab token: could not reach the API to verify (network/GitLab down)"
            ;;
        INVALID)
            print_error "GitLab token: INVALID — revoked or EXPIRED (API returned 401/403)"
            print_hint "This is why automation would fail silently. Rotate: create a new token, then 'pl secrets set gitlab.api_token'"
            errors=1
            ;;
        OK)
            if [ "$is_admin" = "True" ]; then
                print_warning "GitLab token: valid but ADMIN identity ($owner)"
                print_hint "Downscope to a non-admin group/project bot (Developer + api) — the ADR-0024 linchpin"
            else
                local msg="GitLab token: valid — $owner (non-admin)"
                [ -n "$expires" ] && msg="$msg, expires $expires"
                print_success "$msg"
                if [ -n "$expires" ]; then
                    local exp_epoch now days
                    exp_epoch=$(date -d "$expires" +%s 2>/dev/null || echo 0)
                    now=$(date +%s)
                    if [ "$exp_epoch" -gt 0 ]; then
                        days=$(( (exp_epoch - now) / 86400 ))
                        if [ "$days" -lt 0 ]; then
                            print_error "GitLab token EXPIRED $(( -days )) day(s) ago — rotate now"
                            errors=1
                        elif [ "$days" -lt 30 ]; then
                            print_warning "GitLab token expires in $days day(s) — rotate soon"
                        fi
                    fi
                fi
            fi
            ;;
    esac
    return $errors
}

check_common_issues() {
    local errors=0

    print_header "Checking for Common Issues"

    # Docker daemon running (already checked in prerequisites, but good to confirm)
    if docker info &>/dev/null; then
        print_success "Docker daemon: Running"
    else
        print_error "Docker daemon: NOT RUNNING"
        print_hint "Start Docker Desktop or run: sudo systemctl start docker"
        ((errors++))
    fi

    # DDEV running sites
    if command -v ddev &>/dev/null; then
        # Use JSON output for reliable counting (avoids ANSI color code issues)
        local running_sites=$(ddev list --json-output 2>/dev/null | jq '[.raw[] | select(.status=="running")] | length' 2>/dev/null || echo "0")
        # Ensure we have a valid integer
        running_sites="${running_sites:-0}"
        if [ "$running_sites" -gt 0 ] 2>/dev/null; then
            print_info "DDEV sites running: $running_sites"
        else
            print_info "DDEV sites running: 0"
        fi
    fi

    # Disk space
    local disk_usage=$(df -h "$PROJECT_ROOT" 2>/dev/null | tail -1 || echo "")
    if [ -n "$disk_usage" ]; then
        local disk_free=$(echo "$disk_usage" | awk '{print $4}')
        local disk_percent=$(echo "$disk_usage" | awk '{print $5}' | tr -d '%')

        if [ "$disk_percent" -gt 90 ]; then
            print_warning "Disk space: ${disk_free} free (${disk_percent}% used)"
            print_hint "Consider freeing up disk space - DDEV and Docker can use significant storage"
        else
            print_success "Disk space: ${disk_free} free (${disk_percent}% used)"
        fi
    else
        print_warning "Disk space: Unable to check"
    fi

    # Memory (Linux only)
    if command -v free &>/dev/null; then
        local mem_available=$(free -h 2>/dev/null | grep "Mem:" | awk '{print $7}')
        if [ -n "$mem_available" ]; then
            print_info "Memory available: $mem_available"
        fi
    fi

    return $errors
}

################################################################################
# Version control: is anything here the ONLY copy?
#
# Every other check in this file asks whether the machine can do its job today.
# This one asks whether the work survives the machine. `feat/nwptoolkit-deploy`
# (340 lines) sat on no remote in any repo for three weeks; servers/nwpcode is a
# two-commit repository with no remote at all and is the only home of the
# fleet's backup producer. Both were invisible to `git status`, to `pl status`,
# and to `pl doctor`.
#
# NWP_VCS_ROOT overrides the tree to scan (the acceptance suite uses it).
################################################################################

check_vcs_safety() {
    local errors=0
    print_header "Checking Version control (is anything the only copy?)"

    if ! command -v git &>/dev/null; then
        print_warning "Version control: git not installed — cannot check"
        return 0
    fi

    local root="${NWP_VCS_ROOT:-$PROJECT_ROOT}"
    if [ ! -d "$root" ]; then
        print_warning "Version control: '$root' is not a directory — cannot check"
        return 0
    fi

    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/lib/vcs-truth.sh"

    local warn_days="${NWP_VCS_WARN_DAYS:-3}"
    local rows
    rows=$(vcs_strand_rows "$root" "$warn_days" 2>/dev/null || true)

    if [ -z "$rows" ]; then
        print_success "Version control: every commit in every repo is on a remote"
        return 0
    fi

    local kind repo label n age rel
    while IFS=$'\t' read -r kind repo label n age; do
        [ -n "$kind" ] || continue
        rel="${repo#$root/}"; [ "$rel" = "$repo" ] && rel="$(basename "$repo")"
        case "$kind" in
            no-remote)
                print_error "Version control: $rel has no remote — its $n commit(s) exist only on this machine"
                print_hint "  give it one:  git -C $repo remote add origin <url> && git -C $repo push -u origin $label"
                ((errors++))
                ;;
            unpushed)
                print_error "Version control: $rel '$label' — $n commit(s) exist only on this machine (${age}d old)"
                print_hint "  push them:    git -C $repo push -u origin $label"
                ((errors++))
                ;;
        esac
    done <<< "$rows"

    return $errors
}

################################################################################
# F23 Phase 1: Per-site schema checks
################################################################################

check_site_schemas() {
    local errors=0

    print_header "Checking Per-Site .nwp.yml Schema Versions"

    # Require yq before proceeding; upstream checks should already have
    # caught it, but be defensive here.
    if ! command -v yq &>/dev/null; then
        print_warning "yq not installed — skipping schema checks"
        return 0
    fi

    local any_real=0
    local any_missing=0
    local any_stale=0

    for dir in "$PROJECT_ROOT"/sites/*/; do
        [[ -d "$dir" ]] || continue
        local name
        name=$(basename "$dir")

        # Skip known scratch/verify sites
        case "$name" in
            tmp|latest|vendor) continue ;;
            *_moodledata) continue ;;  # Moodle data dirs (sibling to Moodle sites)
            20260117T212337-no-git-no-git) continue ;;
            verify-test*|bats-test-*|trace-del*|*-stg) continue ;;
        esac

        # Only check sites that look real (composer.json or web/html dir)
        if [[ ! -f "$dir/composer.json" && ! -d "$dir/web" && ! -d "$dir/html" ]]; then
            continue
        fi
        any_real=1

        local config="$dir/.nwp.yml"
        if [[ ! -f "$config" ]]; then
            print_warning "$name: no .nwp.yml — run 'pl site init $name'"
            any_missing=1
            continue
        fi

        local sv
        sv=$(yq eval '.schema_version // 0' "$config" 2>/dev/null || echo "0")
        if [[ "$sv" -lt "$CURRENT_SITE_SCHEMA" ]]; then
            print_warning "$name: schema_version=$sv (current=$CURRENT_SITE_SCHEMA) — run 'pl site migrate $name'"
            any_stale=1
            errors=$((errors + 1))
        else
            print_success "$name: schema_version=$sv"
        fi
    done

    if [[ "$any_real" -eq 0 ]]; then
        print_info "No real sites found under $PROJECT_ROOT/sites/"
    elif [[ "$any_missing" -eq 0 && "$any_stale" -eq 0 ]]; then
        print_success "All sites at current schema ($CURRENT_SITE_SCHEMA)"
    fi

    return $errors
}

################################################################################
# F23 Phase 8: Per-server schema checks
################################################################################

check_server_schemas() {
    local errors=0

    print_header "Checking Per-Server .nwp-server.yml Schema Versions"

    if ! command -v yq &>/dev/null; then
        print_warning "yq not installed — skipping server schema checks"
        return 0
    fi

    local any=0
    local stale=0
    if [[ ! -d "$PROJECT_ROOT/servers" ]]; then
        print_info "No servers/ directory yet — skipping"
        return 0
    fi

    for dir in "$PROJECT_ROOT"/servers/*/; do
        [[ -d "$dir" ]] || continue
        local name
        name=$(basename "$dir")
        local config="$dir/.nwp-server.yml"
        [[ -f "$config" ]] || continue
        any=1

        local sv
        sv=$(yq eval '.schema_version // 0' "$config" 2>/dev/null || echo "0")
        if [[ "$sv" -lt "$CURRENT_SERVER_SCHEMA" ]]; then
            print_warning "$name: schema_version=$sv (current=$CURRENT_SERVER_SCHEMA) — run 'pl server migrate $name'"
            stale=1
            errors=$((errors + 1))
        else
            print_success "$name: schema_version=$sv"
        fi
    done

    if [[ "$any" -eq 0 ]]; then
        print_info "No servers configured yet"
    elif [[ "$stale" -eq 0 ]]; then
        print_success "All servers at current schema ($CURRENT_SERVER_SCHEMA)"
    fi

    return $errors
}

################################################################################
# Nested server repos + captured host state (fix-programme item 6)
#
# Two overlapping git repos over one path guarantee a divergent second copy.
# servers/nwpcode/ is a 2-commit repo with NO REMOTE whose tracked set is
# disjoint from the parent's — and it is the sole home of the fleet backup
# producer and the CVE-response upgrade script. If that disk dies, the DR chain
# and the security procedure die with it.
################################################################################
################################################################################
# Rotation debt — credentials known to be EXPOSED and not yet rotated (D8)
#
# `pl doctor` is where "is this estate fit to go to prod" gets asked out loud,
# so the answer must include the credentials whose values have been seen. This
# reports; lib/rotation-debt.sh's guard is what actually REFUSES (pl canonical
# set <site> prod, and every prod write through the ADR-0028 deploy gate).
################################################################################
check_rotation_debt() {
    local errors=0
    print_header "Checking Credential Exposure / Rotation Debt"

    local state; state="$(rotation_debt_state)"
    case "$state" in
        clear)
            print_success "no credential is recorded as exposed-and-unrotated"
            return 0 ;;
        cannot-verify:*)
            print_error "CANNOT VERIFY rotation debt: ${state#cannot-verify:}"
            print_hint "a prod bring-up will REFUSE while this cannot be read — 'pl secrets lint'"
            return 1 ;;
    esac

    local id at ref closed sev how
    while IFS=$'\t' read -r id at ref closed sev how; do
        [ -n "$id" ] || continue
        print_error "EXPOSED, rotation OWED: $id (exposed $at, $sev, $(rotation_debt_surface_label "$closed")) ${ref:-}"
        printf '      %s\n' "$how"
        errors=$((errors + 1))
    done < <(rotation_debt_open)
    print_warning "These BLOCK a prod bring-up: pl canonical set <site> prod, pl stg2prod, pl live2prod."
    print_hint "detail: pl secrets debt   ·   discharge: pl secrets rotate <id>"
    return $errors
}

check_server_state() {
    local errors=0

    print_header "Checking Captured Host State (servers/)"

    if [[ ! -f "$PROJECT_ROOT/lib/host-capture.sh" ]]; then
        print_warning "lib/host-capture.sh missing — cannot check captured host state"
        return 0
    fi
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/lib/host-capture.sh"

    local out
    if out=$(host_check_server_repos "$PROJECT_ROOT" 2>&1); then
        print_success "no unbacked nested server repos"
    else
        while IFS= read -r line; do [[ -n "$line" ]] && print_error "$line"; done <<< "$out"
        print_hint "Give it a real private remote, or delete the inner .git and let the outer repo own the tree"
        errors=$((errors + 1))
    fi

    if out=$(host_check_servers_registered "$PROJECT_ROOT" 2>&1); then
        print_success "every host with captured state is in the server registry"
    else
        while IFS= read -r line; do [[ -n "$line" ]] && print_error "$line"; done <<< "$out"
        print_hint "An unregistered host is invisible to 'pl server health --all' — the required preflight"
        errors=$((errors + 1))
    fi

    if out=$(host_check_servers_tracked "$PROJECT_ROOT" 2>&1); then
        print_success "captured host state is trackable and committed"
    else
        while IFS= read -r line; do [[ -n "$line" ]] && print_warning "$line"; done <<< "$out"
        print_hint "Capture with 'pl host capture <target>', then commit — do not 'git add -f'"
        errors=$((errors + 1))
    fi

    return $errors
}

################################################################################
# Fleet engine-code currency (ops#360) — is any nwp host running stale main?
#
# WHY: the ai-host's checkout — the one the ARMED agent-loop executes from —
# was measured 59 commits behind origin/main on 2026-08-12, and nothing
# surfaced it. `pl fleet sync status` grades every sync-target host against
# the FORGE's main (never this checkout's opinion of it); this check puts
# that fact where the operator already looks. It only runs where the private
# instance manifest is readable (the roles → hosts resolver); elsewhere it
# says so instead of asserting a green it cannot measure.
################################################################################
check_fleet_sync() {
    print_header "Checking Fleet Engine-Code Currency (pl fleet sync)"

    local manifest="${NWP_INSTANCE_MANIFEST:-$HOME/nwp-instances/instance-manifest.yml}"
    if [[ ! -f "$manifest" ]] || ! command -v yq >/dev/null 2>&1; then
        # This used to print the honest sentence and then RETURN 0 — the exit
        # code asserted the pass the sentence disclaimed, so doctor's summary
        # counted "host currency: fine" on exactly the machines that cannot
        # measure it (ops#383, the ops#214 class). Estate rule: an unreadable
        # corpus is exit 2 CANNOT VERIFY, never 0. The truthful exit (ops#361)
        # is the check itself: it clears on its own terms wherever the
        # manifest is readable — no override, no attribution.
        print_error "CANNOT VERIFY fleet engine-code currency — no readable instance manifest here (looked for: $manifest, and yq must be installed)"
        print_hint "grade it where the manifest lives: pl fleet sync status"
        return 2
    fi

    local out rc=0
    out=$("$PROJECT_ROOT/pl" fleet sync status --quiet 2>&1) || rc=$?
    case "$rc" in
        0)
            print_success "every sync-target host is on current origin/main"
            return 0 ;;
        2)
            while IFS= read -r line; do [[ -n "$line" ]] && print_error "$line"; done <<< "$out"
            print_error "CANNOT VERIFY host currency — an unreachable host is never 'up to date'"
            print_hint "detail: pl fleet sync status   ·   provision: pl fleet sync install --host=<role>"
            return 1 ;;
        *)
            while IFS= read -r line; do [[ -n "$line" ]] && print_error "$line"; done <<< "$out"
            print_hint "settle a stale host now: pl fleet sync run --host=<role>"
            return 1 ;;
    esac
}

################################################################################
# Mail alias coverage — every referenced address must be deliverable
#
# WHY: MX for nwpcode.org points at the box whose /etc/postfix/virtual is the
# only thing that makes an @nwpcode.org address deliverable. On 2026-08-01 a
# sweep found NINE referenced-but-unaliased addresses (support@, rob@, dev@,
# nwp-security@, fin-monitor@, mass-times@, robert.zaar@, postmaster@, abuse@)
# — every one a silent black hole for replies/bounces. The fix pattern is:
#   servers/<server>/email/referenced-addresses.txt  (the promise)
#   servers/<server>/email/postfix-virtual           (tracked baseline of the map)
# This check asserts promise ⊆ baseline, so referencing a new address without
# aliasing it goes red on the next doctor run instead of years later.
################################################################################
check_mail_aliases() {
    local errors=0 found=0
    local manifest baseline dir addr

    print_header "Checking Mail Alias Coverage (servers/*/email/)"

    for manifest in "$PROJECT_ROOT"/servers/*/email/referenced-addresses.txt; do
        [[ -f "$manifest" ]] || continue
        found=1
        dir="$(dirname "$manifest")"
        baseline="$dir/postfix-virtual"

        if [[ ! -f "$baseline" ]]; then
            print_error "$(basename "$(dirname "$dir")"): referenced-addresses.txt exists but postfix-virtual baseline is missing"
            print_hint "Refresh it from the box: ssh <box> 'cat /etc/postfix/virtual' > $baseline"
            errors=$((errors + 1))
            continue
        fi

        local missing=0 total=0
        while IFS= read -r addr; do
            addr="${addr%%#*}"                    # strip trailing comments
            addr="$(echo "$addr" | tr -d '[:space:]')"
            [[ -z "$addr" ]] && continue
            total=$((total + 1))
            if ! grep -Eq "^${addr}[[:space:]]" "$baseline"; then
                print_error "referenced but NOT aliased: $addr"
                missing=$((missing + 1))
            fi
        done < "$manifest"

        if [[ $missing -eq 0 ]]; then
            print_success "$(basename "$(dirname "$dir")"): all $total referenced addresses have aliases in the tracked baseline"
        else
            print_hint "Alias it on the box: sudo /opt/nwp/email/add_site_email.sh <localpart> --forward-only <target> -y"
            print_hint "then refresh $baseline and commit (server-local repo)"
            errors=$((errors + missing))
        fi
    done

    if [[ $found -eq 0 ]]; then
        print_success "no servers/*/email/referenced-addresses.txt manifests (check not applicable to this checkout)"
    fi

    return $errors
}

################################################################################
# Live-deploy dependency policy — drush must be a PROD dep (ops#157 item 1)
#
# WHY: dev2stg builds staging with `composer install --no-dev`, and stg2live
# §3.6 then runs `drush updatedb` ON LIVE from that synced vendor. A site with
# drush in require-dev therefore deploys a drush-less vendor and aborts — AFTER
# maintenance mode is enabled. That is the 2026-07-29 incident: mt went down for
# ~25 minutes.
#
# stg2live_stg_has_drush() (stg2live.sh, D17) already refuses at deploy time,
# which stops the outage. But it fires against the STAGING VENDOR, i.e. only
# once you are already deploying, and the fix from there is a composer edit plus
# a full staging rebuild. The issue asked for the other half and it was never
# done: "POLICY: every live-enabled site's composer.json should be checked".
#
# This is that sweep, run by code instead of by hand. It reads composer.json —
# the DECLARATION — so a site is caught before anyone tries to ship it.
#
# Deliberately does NOT look at vendor/: an unbuilt or freshly-cloned tree has
# no vendor at all, and grading that RED would train operators to ignore the
# check. The declaration is the thing policy is actually about.
################################################################################

# doctor_composer_drush_placement <composer.json> — echo where drush is declared.
#
# Echoes exactly one of: require | require-dev | none | unreadable
# PURE: no globals, no output beyond the verdict, so bats can table-test it.
doctor_composer_drush_placement() {
    local composer="${1:-}"
    [ -n "$composer" ] && [ -f "$composer" ] || { echo "unreadable"; return 0; }
    command -v jq >/dev/null 2>&1 || { echo "unreadable"; return 0; }

    # A malformed composer.json must read as "I could not look", never as a
    # confident "none" — a parse failure that grades green is the exact shape of
    # a check that cannot fail (ops#214).
    jq -e . "$composer" >/dev/null 2>&1 || { echo "unreadable"; return 0; }

    # Match the PACKAGE, not the substring: `drupal/drush_language` is not drush.
    # Vendors differ across the fleet (drush/drush today), so anchor on the
    # package NAME half rather than hardcoding one vendor.
    local prod dev
    prod=$(jq -r '[(.require        // {}) | keys[] | select(split("/")[-1] == "drush")] | length' "$composer" 2>/dev/null || echo 0)
    dev=$( jq -r '[(."require-dev"  // {}) | keys[] | select(split("/")[-1] == "drush")] | length' "$composer" 2>/dev/null || echo 0)

    if [ "${prod:-0}" -gt 0 ]; then echo "require"
    elif [ "${dev:-0}" -gt 0 ]; then echo "require-dev"
    else echo "none"
    fi
}

# doctor_site_composer <site-dir> — echo the composer.json that governs the
# deploy, or nothing. dev/ wins: it is the tree dev2stg builds staging from.
doctor_site_composer() {
    local dir="${1:-}" cand
    dir="${dir%/}"   # the sites/*/ glob supplies a trailing slash
    for cand in "$dir/dev/composer.json" "$dir/composer.json"; do
        [ -f "$cand" ] && { printf '%s\n' "$cand"; return 0; }
    done
    return 0
}

check_live_drush_dependency() {
    local errors=0 found=0
    local dir name config enabled composer placement

    print_header "Checking Live-Deploy Dependencies (drush in require, not require-dev)"

    if ! command -v yq >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        print_warning "yq and jq are both required for this check — skipping"
        return 0
    fi

    for dir in "$PROJECT_ROOT"/sites/*/; do
        [[ -d "$dir" ]] || continue
        name=$(basename "$dir")
        config="$dir/.nwp.yml"
        [[ -f "$config" ]] || continue

        # Bare path, never `// "false"`: yq's alternative operator treats a real
        # `enabled: false` as absent and would hand back the fallback. Same trap
        # lib/project-resolver.sh documents for this exact key.
        enabled=$(yq eval '.live.enabled' "$config" 2>/dev/null)
        [[ "$enabled" == "true" ]] || continue
        found=$((found + 1))

        composer="$(doctor_site_composer "$dir")"
        if [[ -z "$composer" ]]; then
            # Moodle and static sites legitimately have no composer.json, and
            # stg2live's drush step does not apply to them.
            print_info "$name: live-enabled, no composer.json (not a Composer site — n/a)"
            continue
        fi

        placement="$(doctor_composer_drush_placement "$composer")"
        case "$placement" in
            require)
                print_success "$name: drush in require — survives 'composer install --no-dev'"
                ;;
            require-dev)
                print_error "$name: drush is in require-dev — a live deploy would strip it"
                print_hint "dev2stg runs 'composer install --no-dev', then stg2live runs 'drush updatedb' on live from that vendor."
                print_hint "Move drush/drush to \"require\" in ${composer#"$PROJECT_ROOT"/}, then rebuild staging with 'pl dev2stg $name'."
                errors=$((errors + 1))
                ;;
            none)
                # Not an error: a Composer site may genuinely not use drush
                # (stg2live has NWP_ALLOW_NO_DRUSH=1 for exactly that path).
                print_info "$name: no drush declared at all — deploys need NWP_ALLOW_NO_DRUSH=1"
                ;;
            unreadable)
                print_warning "$name: composer.json unreadable or malformed — cannot verify (${composer#"$PROJECT_ROOT"/})"
                ;;
        esac
    done

    if [[ $found -eq 0 ]]; then
        print_info "No live-enabled sites in this checkout (check not applicable)"
    elif [[ $errors -eq 0 ]]; then
        print_success "All $found live-enabled site(s) can run drush on live after a --no-dev build"
    fi

    return $errors
}

################################################################################
# Main Function
################################################################################

main() {
    local verbose=0
    local quiet=0
    local total_errors=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                verbose=1
                shift
                ;;
            -q|--quiet)
                quiet=1
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo ""
                show_help
                exit 1
                ;;
        esac
    done

    # Print banner
    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║          NWP Doctor v0.20.0            ║"
    echo "╚════════════════════════════════════════╝"
    echo ""

    # Run all checks — pl registration first (ops#77), it is the fresh-clone gotcha.
    check_pl_registration
    echo ""

    local prereq_errors=0
    if check_prerequisites; then prereq_errors=0; else prereq_errors=$?; fi
    total_errors=$((total_errors + prereq_errors))
    echo ""

    check_configuration || total_errors=$((total_errors + $?))
    echo ""

    check_network || total_errors=$((total_errors + $?))

    check_gitlab_token || total_errors=$((total_errors + $?))
    echo ""

    check_common_issues || total_errors=$((total_errors + $?))
    echo ""

    check_vcs_safety || total_errors=$((total_errors + $?))
    echo ""

    check_site_schemas || total_errors=$((total_errors + $?))
    echo ""

    check_server_schemas || total_errors=$((total_errors + $?))
    echo ""

    check_server_state || total_errors=$((total_errors + $?))
    echo ""

    check_fleet_sync || total_errors=$((total_errors + $?))
    echo ""

    check_rotation_debt || total_errors=$((total_errors + $?))
    echo ""

    check_mail_aliases || total_errors=$((total_errors + $?))

    check_live_drush_dependency || total_errors=$((total_errors + $?))
    echo ""

    # Print summary
    print_header "Summary"

    if [ "$total_errors" -eq 0 ]; then
        print_success "All checks passed! NWP is ready to use."
        exit 0
    else
        print_error "$total_errors issue(s) found"
        if [ "$prereq_errors" -gt 0 ]; then
            print_hint "Missing prerequisites — run 'pl init' to install them all automatically"
        fi
        print_hint "Fix the issues above and run 'pl doctor' again"
        exit 1
    fi
}

# Run main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
