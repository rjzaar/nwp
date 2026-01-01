#!/bin/bash

################################################################################
# NWP Interactive Checkbox UI Library
#
# Provides interactive checkbox selection for install options
# Source this file: source "$SCRIPT_DIR/lib/checkbox.sh"
################################################################################

# Ensure ui.sh is sourced for colors
if [ -z "${NC:-}" ]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    NC=$'\033[0m'
    BOLD=$'\033[1m'
fi
# DIM may not be defined in ui.sh, so ensure it's set
if [ -z "${DIM:-}" ]; then
    DIM=$'\033[2m'
fi

# Checkbox symbols
CHECKBOX_CHECKED="[${GREEN}✓${NC}]"
CHECKBOX_UNCHECKED="[ ]"
CHECKBOX_CURSOR=">"
CHECKBOX_DISABLED="[${DIM}-${NC}]"

################################################################################
# Option Definition System
################################################################################

# Associative arrays for option metadata
declare -A OPTION_LABELS        # Human-readable labels
declare -A OPTION_DESCRIPTIONS  # Descriptions
declare -A OPTION_ENVIRONMENTS  # Which environment (dev/stage/live/prod)
declare -A OPTION_DEFAULTS      # Default state per environment
declare -A OPTION_DEPENDENCIES  # Dependencies (comma-separated)
declare -A OPTION_CONFLICTS     # Conflicts (comma-separated)
declare -A OPTION_INPUTS        # Required input fields (comma-separated key:label pairs)
declare -A OPTION_CATEGORIES    # Category within environment
declare -A OPTION_SELECTED      # Current selection state
declare -A OPTION_VALUES        # Input values for options requiring input
declare -A OPTION_DOCS          # Documentation links (comma-separated URLs)

# List of all options in order
OPTION_LIST=()

# Define a new option
# Usage: define_option "key" "label" "description" "environment" "default" "dependencies" "inputs" "category" "docs"
define_option() {
    local key="$1"
    local label="$2"
    local description="$3"
    local environment="$4"           # dev, stage, live, prod, or "all"
    local default="$5"               # y/n or "dev:y,stage:n,live:n,prod:y"
    local dependencies="${6:-}"      # comma-separated option keys
    local inputs="${7:-}"            # comma-separated key:label pairs
    local category="${8:-general}"   # Category within environment
    local docs="${9:-}"              # comma-separated documentation URLs

    OPTION_LIST+=("$key")
    OPTION_LABELS["$key"]="$label"
    OPTION_DESCRIPTIONS["$key"]="$description"
    OPTION_ENVIRONMENTS["$key"]="$environment"
    OPTION_DEFAULTS["$key"]="$default"
    OPTION_DEPENDENCIES["$key"]="$dependencies"
    OPTION_INPUTS["$key"]="$inputs"
    OPTION_CATEGORIES["$key"]="$category"
    OPTION_SELECTED["$key"]="n"
    OPTION_DOCS["$key"]="$docs"
}

# Clear all options
clear_options() {
    OPTION_LIST=()
    unset OPTION_LABELS OPTION_DESCRIPTIONS OPTION_ENVIRONMENTS OPTION_DEFAULTS
    unset OPTION_DEPENDENCIES OPTION_INPUTS OPTION_CATEGORIES OPTION_SELECTED OPTION_VALUES OPTION_DOCS
    declare -gA OPTION_LABELS OPTION_DESCRIPTIONS OPTION_ENVIRONMENTS OPTION_DEFAULTS
    declare -gA OPTION_DEPENDENCIES OPTION_INPUTS OPTION_CATEGORIES OPTION_SELECTED OPTION_VALUES OPTION_DOCS
}

################################################################################
# Drupal/OpenSocial Options
################################################################################

define_drupal_options() {
    clear_options

    # === DEVELOPMENT OPTIONS ===
    define_option "dev_modules" \
        "Development Modules" \
        "Install devel, kint, webprofiler for debugging. Devel provides helper functions and debug tools. Kint provides beautiful variable dumps. Webprofiler adds a toolbar showing SQL queries, cache hits, and performance data." \
        "dev" "dev:y,stage:n,live:n,prod:n" "" "" "modules" \
        "https://www.drupal.org/project/devel,https://www.drupal.org/project/webprofiler"

    define_option "xdebug" \
        "XDebug" \
        "Enable XDebug for step-through debugging in your IDE. Allows setting breakpoints, inspecting variables, and tracing execution flow. Works with PhpStorm, VS Code, and other IDEs." \
        "dev" "dev:n,stage:n,live:n,prod:n" "" "" "tools" \
        "https://ddev.readthedocs.io/en/stable/users/debugging-profiling/step-debugging/,https://xdebug.org/docs/"
    OPTION_CONFLICTS["xdebug"]="redis"  # XDebug and Redis can conflict in some setups

    define_option "stage_file_proxy" \
        "Stage File Proxy" \
        "Proxy files from production server instead of copying them locally. Saves disk space and speeds up database syncs by only downloading files when accessed." \
        "dev" "dev:n,stage:y,live:n,prod:n" "" "" "modules" \
        "https://www.drupal.org/project/stage_file_proxy"
    OPTION_CONFLICTS["stage_file_proxy"]="cdn"  # Don't proxy files if using CDN

    define_option "config_split" \
        "Config Split" \
        "Enable environment-specific configuration management. Allows different config for dev/stage/prod (e.g., disable Google Analytics on dev, enable caching only on prod)." \
        "dev" "dev:y,stage:y,live:y,prod:y" "" "" "modules" \
        "https://www.drupal.org/project/config_split,https://www.drupal.org/docs/contributed-modules/configuration-split"

    # === STAGING OPTIONS ===
    define_option "db_sanitize" \
        "Database Sanitization" \
        "Sanitize user data when syncing from production. Replaces real emails with fake ones, anonymizes usernames, and removes sensitive data. Essential for GDPR compliance on non-production environments." \
        "stage" "dev:y,stage:y,live:n,prod:n" "" "" "database" \
        "https://www.drush.org/12.x/commands/sql_sanitize/,https://www.drupal.org/project/gdpr"

    define_option "staging_domain" \
        "Staging Domain" \
        "Configure a staging domain for testing before production deployment. Typically uses a subdomain like staging.example.com or site-stg.example.com." \
        "stage" "dev:n,stage:y,live:n,prod:n" "" \
        "domain:Staging Domain (e.g. site-stg.example.com)" "deployment" \
        "https://ddev.readthedocs.io/en/stable/users/extend/additional-hostnames/"

    # === LIVE/PRODUCTION OPTIONS ===
    define_option "security_modules" \
        "Security Modules" \
        "Install essential security modules: SecKit (HTTP headers, CSP), Honeypot (spam protection), Login Security (brute force protection), Flood Control (rate limiting UI). Highly recommended for all production sites." \
        "live" "dev:n,stage:n,live:y,prod:y" "" "" "security" \
        "https://www.drupal.org/project/seckit,https://www.drupal.org/project/honeypot,https://www.drupal.org/project/login_security,https://www.drupal.org/project/flood_control"

    define_option "redis" \
        "Redis Caching" \
        "Enable Redis for object and render caching. Significantly improves performance by storing cached data in memory. Reduces database load and speeds up page generation." \
        "live" "dev:n,stage:n,live:y,prod:y" "" "" "performance" \
        "https://www.drupal.org/project/redis,https://ddev.readthedocs.io/en/stable/users/extend/additional-services/#redis"

    define_option "solr" \
        "Solr Search" \
        "Enable Apache Solr for advanced full-text search. Provides faceted search, highlighting, spell checking, and much better search relevance than database search." \
        "live" "dev:n,stage:n,live:n,prod:n" "" \
        "core:Solr Core Name" "search" \
        "https://www.drupal.org/project/search_api_solr,https://ddev.readthedocs.io/en/stable/users/extend/additional-services/#solr"

    define_option "cron" \
        "Cron Configuration" \
        "Set up automated cron jobs for Drupal. Runs scheduled tasks like clearing caches, sending emails, updating search indexes, and running queues. Critical for site health." \
        "live" "dev:n,stage:n,live:y,prod:y" "" \
        "interval:Cron Interval (minutes)" "scheduling" \
        "https://www.drupal.org/docs/administering-a-drupal-site/cron-automated-tasks,https://www.drupal.org/project/ultimate_cron"

    define_option "backup" \
        "Automated Backups" \
        "Configure automated backups to Backblaze B2 cloud storage. Includes database dumps, files, and configuration. Essential for disaster recovery and compliance." \
        "live" "dev:n,stage:n,live:y,prod:y" "" "" "backup" \
        "https://www.backblaze.com/docs/cloud-storage-command-line-tools,https://www.drupal.org/project/backup_migrate"

    define_option "ssl" \
        "SSL Certificate" \
        "Configure Let's Encrypt SSL certificates for HTTPS. Free, automatic SSL that renews itself. Required for production sites and improves SEO." \
        "live" "dev:n,stage:y,live:y,prod:y" "" \
        "domain:Domain for SSL" "security" \
        "https://letsencrypt.org/getting-started/,https://certbot.eff.org/"

    define_option "cdn" \
        "CDN Configuration" \
        "Configure Cloudflare CDN for global content delivery. Caches static assets at edge locations worldwide, provides DDoS protection, and improves page load times." \
        "live" "dev:n,stage:n,live:y,prod:y" "ssl" "" "performance" \
        "https://www.cloudflare.com/learning/cdn/what-is-a-cdn/,https://www.drupal.org/project/cloudflare"

    # === PRODUCTION-SPECIFIC OPTIONS ===
    define_option "live_domain" \
        "Production Domain" \
        "Configure the production domain for your live site. This is the public-facing URL users will access. Requires DNS configuration pointing to your server." \
        "prod" "dev:n,stage:n,live:n,prod:y" "" \
        "domain:Production Domain" "deployment" \
        "https://www.linode.com/docs/guides/dns-manager/,https://www.cloudflare.com/learning/dns/what-is-dns/"

    define_option "dns_records" \
        "DNS Records" \
        "Auto-configure Linode DNS records including A, AAAA, MX, SPF, DKIM, and DMARC records. Ensures proper domain resolution and email deliverability." \
        "prod" "dev:n,stage:n,live:n,prod:y" "live_domain" "" "deployment" \
        "https://www.linode.com/docs/api/domains/,https://www.linode.com/docs/guides/dns-manager/"

    define_option "monitoring" \
        "Uptime Monitoring" \
        "Configure uptime monitoring to receive alerts when your site goes down. Get notified via email or SMS when issues are detected so you can respond quickly." \
        "prod" "dev:n,stage:n,live:n,prod:y" "live_domain" \
        "email:Alert Email" "monitoring" \
        "https://uptimerobot.com/,https://www.drupal.org/project/monitoring"

    # === CI/CD OPTIONS ===
    define_option "ci_enabled" \
        "CI/CD Pipeline" \
        "Enable GitLab CI/CD for automated testing and deployment. Runs on every push to verify code quality before merging. Essential for team development workflows." \
        "all" "dev:y,stage:y,live:y,prod:y" "" "" "cicd" \
        "https://docs.gitlab.com/ee/ci/,https://about.gitlab.com/topics/ci-cd/"

    define_option "ci_lint" \
        "Linting" \
        "Run PHPCS (PHP_CodeSniffer) and code linting in CI. Enforces Drupal coding standards and catches potential issues before they reach production." \
        "all" "dev:y,stage:y,live:y,prod:y" "ci_enabled" "" "cicd" \
        "https://www.drupal.org/docs/develop/standards,https://github.com/squizlabs/PHP_CodeSniffer"

    define_option "ci_tests" \
        "Automated Tests" \
        "Run PHPUnit tests automatically in CI pipeline. Validates functionality, prevents regressions, and ensures code changes don't break existing features." \
        "all" "dev:y,stage:y,live:y,prod:y" "ci_enabled" "" "cicd" \
        "https://www.drupal.org/docs/testing,https://phpunit.de/documentation.html"

    define_option "ci_security" \
        "Security Scanning" \
        "Run security scans in CI pipeline using tools like security-checker and Drupal's security advisories. Detects known vulnerabilities in dependencies." \
        "all" "dev:n,stage:y,live:y,prod:y" "ci_enabled" "" "cicd" \
        "https://github.com/fabpot/local-php-security-checker,https://www.drupal.org/security"

    define_option "ci_deploy" \
        "Auto Deploy" \
        "Automatically deploy to staging/production after successful CI pipeline. Enables continuous delivery with zero-downtime deployments." \
        "all" "dev:n,stage:n,live:n,prod:n" "ci_enabled" "" "cicd" \
        "https://docs.gitlab.com/ee/ci/environments/,https://about.gitlab.com/topics/ci-cd/continuous-deployment/"

    # === EMAIL OPTIONS ===
    define_option "email_enabled" \
        "Email Configuration" \
        "Enable site email functionality using Postfix with proper authentication. Includes SPF, DKIM, and DMARC for high deliverability rates." \
        "all" "dev:n,stage:n,live:y,prod:y" "" "" "email" \
        "https://www.mail-tester.com/,https://www.drupal.org/docs/contributed-modules/smtp-authentication-support"

    define_option "email_send" \
        "Outgoing Email" \
        "Configure SMTP for sending emails. Uses authenticated SMTP with TLS for secure delivery. Required for password resets, notifications, and contact forms." \
        "all" "dev:n,stage:n,live:y,prod:y" "email_enabled" \
        "address:Site Email Address" "email" \
        "https://www.drupal.org/project/smtp,https://www.drupal.org/project/mailsystem"

    define_option "email_receive" \
        "Incoming Email" \
        "Set up mailbox for receiving emails. Enables email-to-case, comment-by-email, and other inbound email features. Forwards to a configured address." \
        "all" "dev:n,stage:n,live:n,prod:n" "email_send" \
        "forward:Forward To Address" "email" \
        "https://www.drupal.org/project/mailhandler"
}

################################################################################
# Moodle Options
################################################################################

define_moodle_options() {
    clear_options

    # === DEVELOPMENT OPTIONS ===
    define_option "debug_mode" \
        "Debug Mode" \
        "Enable Moodle debug mode" \
        "dev" "dev:y,stage:n,live:n,prod:n" "" "" "debugging"

    define_option "dev_theme" \
        "Development Theme" \
        "Use development theme with debugging info" \
        "dev" "dev:n,stage:n,live:n,prod:n" "" "" "appearance"

    # === STAGING OPTIONS ===
    define_option "staging_domain" \
        "Staging Domain" \
        "Configure staging domain" \
        "stage" "dev:n,stage:y,live:n,prod:n" "" \
        "domain:Staging Domain" "deployment"

    # === LIVE OPTIONS ===
    define_option "ssl" \
        "SSL Certificate" \
        "Configure Let's Encrypt SSL" \
        "live" "dev:n,stage:y,live:y,prod:y" "" \
        "domain:Domain for SSL" "security"

    define_option "redis" \
        "Redis Session Store" \
        "Use Redis for session storage" \
        "live" "dev:n,stage:n,live:y,prod:y" "" "" "performance"

    define_option "backup" \
        "Automated Backups" \
        "Configure automated backups" \
        "live" "dev:n,stage:n,live:y,prod:y" "" "" "backup"

    define_option "cron" \
        "Cron Configuration" \
        "Set up Moodle cron job" \
        "live" "dev:n,stage:n,live:y,prod:y" "" \
        "interval:Cron Interval (minutes)" "scheduling"

    # === PRODUCTION OPTIONS ===
    define_option "live_domain" \
        "Production Domain" \
        "Configure production domain" \
        "prod" "dev:n,stage:n,live:n,prod:y" "" \
        "domain:Production Domain" "deployment"

    define_option "monitoring" \
        "Uptime Monitoring" \
        "Configure uptime monitoring" \
        "prod" "dev:n,stage:n,live:n,prod:y" "live_domain" \
        "email:Alert Email" "monitoring"
}

################################################################################
# GitLab Options
################################################################################

define_gitlab_options() {
    clear_options

    # === DEVELOPMENT OPTIONS ===
    define_option "reduced_memory" \
        "Reduced Memory Mode" \
        "Optimize for development (less RAM)" \
        "dev" "dev:y,stage:n,live:n,prod:n" "" "" "performance"

    # === LIVE OPTIONS ===
    define_option "ssl" \
        "SSL Certificate" \
        "Configure Let's Encrypt SSL" \
        "live" "dev:n,stage:n,live:y,prod:y" "" \
        "domain:GitLab Domain" "security"

    define_option "runner" \
        "GitLab Runner" \
        "Install shared GitLab Runner" \
        "live" "dev:n,stage:n,live:y,prod:y" "" "" "cicd"

    define_option "backup" \
        "Automated Backups" \
        "Configure automated GitLab backups" \
        "live" "dev:n,stage:n,live:y,prod:y" "" "" "backup"

    # === SECURITY OPTIONS ===
    define_option "disable_signups" \
        "Disable Public Signups" \
        "Prevent public user registration" \
        "live" "dev:n,stage:n,live:y,prod:y" "" "" "security"

    define_option "require_2fa" \
        "Require 2FA" \
        "Require two-factor authentication" \
        "live" "dev:n,stage:n,live:n,prod:y" "" "" "security"

    define_option "audit_logging" \
        "Audit Logging" \
        "Enable audit event logging" \
        "live" "dev:n,stage:n,live:y,prod:y" "" "" "security"
}

################################################################################
# Selection Logic
################################################################################

# Get default value for an option in a given environment
get_option_default() {
    local key="$1"
    local env="$2"
    local defaults="${OPTION_DEFAULTS[$key]}"

    # Parse defaults string (e.g., "dev:y,stage:n,live:y,prod:y")
    if [[ "$defaults" == *":"* ]]; then
        echo "$defaults" | tr ',' '\n' | while read -r pair; do
            local e="${pair%%:*}"
            local v="${pair#*:}"
            if [[ "$e" == "$env" ]]; then
                echo "$v"
                return
            fi
        done
    else
        # Simple y/n default
        echo "$defaults"
    fi
}

# Check if option should be visible for environment
option_visible_for_env() {
    local key="$1"
    local env="$2"
    local opt_env="${OPTION_ENVIRONMENTS[$key]}"

    [[ "$opt_env" == "all" ]] || [[ "$opt_env" == "$env" ]]
}

# Apply environment defaults
apply_environment_defaults() {
    local env="$1"

    for key in "${OPTION_LIST[@]}"; do
        local default=$(get_option_default "$key" "$env")
        if [[ "$default" == "y" ]]; then
            OPTION_SELECTED["$key"]="y"
        else
            OPTION_SELECTED["$key"]="n"
        fi
    done
}

# Check dependencies for an option
check_dependencies() {
    local key="$1"
    local deps="${OPTION_DEPENDENCIES[$key]}"

    if [[ -z "$deps" ]]; then
        return 0  # No dependencies
    fi

    local missing=()
    IFS=',' read -ra dep_arr <<< "$deps"
    for dep in "${dep_arr[@]}"; do
        if [[ "${OPTION_SELECTED[$dep]}" != "y" ]]; then
            missing+=("${OPTION_LABELS[$dep]}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "${missing[*]}"
        return 1
    fi
    return 0
}

# Check conflicts for an option
check_conflicts() {
    local key="$1"
    local conflicts="${OPTION_CONFLICTS[$key]:-}"

    if [[ -z "$conflicts" ]]; then
        return 0  # No conflicts
    fi

    local active_conflicts=()
    IFS=',' read -ra conflict_arr <<< "$conflicts"
    for conflict in "${conflict_arr[@]}"; do
        if [[ "${OPTION_SELECTED[$conflict]}" == "y" ]]; then
            active_conflicts+=("${OPTION_LABELS[$conflict]}")
        fi
    done

    if [[ ${#active_conflicts[@]} -gt 0 ]]; then
        echo "${active_conflicts[*]}"
        return 1
    fi
    return 0
}

# Get options that depend on a given option
get_dependents() {
    local key="$1"
    local dependents=()

    for opt in "${OPTION_LIST[@]}"; do
        local deps="${OPTION_DEPENDENCIES[$opt]}"
        if [[ -n "$deps" ]]; then
            IFS=',' read -ra dep_arr <<< "$deps"
            for dep in "${dep_arr[@]}"; do
                if [[ "$dep" == "$key" ]] && [[ "${OPTION_SELECTED[$opt]}" == "y" ]]; then
                    dependents+=("${OPTION_LABELS[$opt]}")
                fi
            done
        fi
    done

    echo "${dependents[*]}"
}

################################################################################
# Interactive UI
################################################################################

################################################################################
# Interactive UI with Arrow Key Navigation
################################################################################

# Read a single keypress (including arrow keys)
read_key() {
    local key=""
    local extra=""

    # Read one character
    IFS= read -rsn1 key

    # Handle escape sequences (arrow keys)
    if [[ "$key" == $'\e' ]]; then
        IFS= read -rsn1 -t 0.1 extra
        if [[ "$extra" == "[" ]]; then
            IFS= read -rsn1 -t 0.1 extra
            case "$extra" in
                A) echo "UP"; return ;;
                B) echo "DOWN"; return ;;
                C) echo "RIGHT"; return ;;
                D) echo "LEFT"; return ;;
            esac
        fi
        echo "ESC"
        return
    fi

    # Handle regular keys
    case "$key" in
        '') echo "ENTER" ;;
        ' ') echo "SPACE" ;;
        q|Q) echo "QUIT" ;;
        a|A) echo "ALL" ;;
        n|N) echo "NONE" ;;
        e|E) echo "EDIT" ;;
        '?'|h|H) echo "HELP" ;;
        j|J) echo "DOWN" ;;
        k|K) echo "UP" ;;
        *) echo "OTHER" ;;
    esac
}

# Build flat list of all options (sorted by environment)
build_option_list() {
    local environment="$1"

    VISIBLE_OPTIONS=()

    # Add options in environment order: dev, stage, live, prod, then 'all'
    for env in dev stage live prod all; do
        for key in "${OPTION_LIST[@]}"; do
            local opt_env="${OPTION_ENVIRONMENTS[$key]}"
            if [[ "$opt_env" == "$env" ]]; then
                VISIBLE_OPTIONS+=("$key")
            fi
        done
    done
}

# Draw the compact option list
draw_options() {
    local cursor="$1"
    local environment="$2"
    local total="${#VISIBLE_OPTIONS[@]}"

    # Header
    echo -e "${BOLD}Options${NC} ${DIM}(${environment})${NC}  ${DIM}↑↓:move  space:toggle  enter:done  a:all  n:none  q:quit${NC}"
    echo ""

    local idx=0
    local current_env=""

    for key in "${VISIBLE_OPTIONS[@]}"; do
        local opt_env="${OPTION_ENVIRONMENTS[$key]}"
        local label="${OPTION_LABELS[$key]}"
        local selected="${OPTION_SELECTED[$key]}"
        local inputs="${OPTION_INPUTS[$key]}"
        local deps="${OPTION_DEPENDENCIES[$key]}"

        # Environment header (compact)
        if [[ "$opt_env" != "$current_env" && "$opt_env" != "all" ]]; then
            current_env="$opt_env"
            local env_name
            case "$opt_env" in
                dev) env_name="DEV" ;;
                stage) env_name="STG" ;;
                live) env_name="LIVE" ;;
                prod) env_name="PROD" ;;
                *) env_name="${opt_env^^}" ;;
            esac
            if [[ "$opt_env" == "$environment" ]]; then
                echo -e " ${GREEN}━━ $env_name ━━${NC}"
            else
                echo -e " ${DIM}━━ $env_name ━━${NC}"
            fi
        fi

        # Checkbox
        local checkbox
        if [[ "$selected" == "y" ]]; then
            checkbox="${GREEN}[✓]${NC}"
        else
            checkbox="${DIM}[ ]${NC}"
        fi

        # Cursor indicator
        local pointer="  "
        if [[ $idx -eq $cursor ]]; then
            pointer="${CYAN}▸${NC} "
            checkbox="${BOLD}$checkbox${NC}"
        fi

        # Indicators
        local indicators=""
        if [[ -n "$inputs" ]]; then
            indicators="${YELLOW}*${NC}"
        fi
        if [[ -n "$deps" ]]; then
            local missing=$(check_dependencies "$key")
            if [[ -n "$missing" ]]; then
                indicators="${indicators}${RED}!${NC}"
            fi
        fi

        # Truncate label if needed
        local display_label="${label:0:28}"

        echo -e "${pointer}${checkbox} ${display_label}${indicators}"

        ((idx++))
    done

    # Footer with count
    local selected_count=0
    for key in "${OPTION_LIST[@]}"; do
        [[ "${OPTION_SELECTED[$key]}" == "y" ]] && ((selected_count++))
    done
    echo ""
    echo -e "${DIM}Selected: $selected_count/${#OPTION_LIST[@]}${NC}  ${YELLOW}*${NC}${DIM}=needs input${NC}  ${RED}!${NC}${DIM}=missing dep${NC}"
}

# Simple text-based menu (fallback)
interactive_select_options_simple() {
    local environment="$1"
    local recipe_type="$2"
    local existing_config="$3"

    # Load appropriate options
    case "$recipe_type" in
        drupal|d|os|nwp|dm) define_drupal_options ;;
        moodle|m) define_moodle_options ;;
        gitlab) define_gitlab_options ;;
        *) define_drupal_options ;;
    esac

    # Apply existing configuration if provided
    if [[ -n "$existing_config" ]]; then
        load_existing_config "$existing_config"
    else
        apply_environment_defaults "$environment"
    fi

    # Build visible options list
    build_option_list "$environment"

    local total="${#VISIBLE_OPTIONS[@]}"

    while true; do
        clear
        echo -e "${BOLD}Options${NC} [${environment}]  Enter number to toggle, ${BOLD}d${NC}=done, ${BOLD}a${NC}=all, ${BOLD}n${NC}=none"
        echo ""

        local idx=1
        local current_env=""

        for key in "${VISIBLE_OPTIONS[@]}"; do
            local opt_env="${OPTION_ENVIRONMENTS[$key]}"
            local label="${OPTION_LABELS[$key]}"
            local selected="${OPTION_SELECTED[$key]}"
            local inputs="${OPTION_INPUTS[$key]}"

            # Environment header
            if [[ "$opt_env" != "$current_env" && "$opt_env" != "all" ]]; then
                current_env="$opt_env"
                local env_name="${opt_env^^}"
                if [[ "$opt_env" == "$environment" ]]; then
                    echo -e " ${GREEN}── $env_name ──${NC}"
                else
                    echo -e " ${DIM}── $env_name ──${NC}"
                fi
            fi

            # Checkbox
            local checkbox="[ ]"
            [[ "$selected" == "y" ]] && checkbox="${GREEN}[✓]${NC}"

            # Input indicator
            local ind=""
            [[ -n "$inputs" ]] && ind="${YELLOW}*${NC}"

            printf "  %2d) %b %-28s %b\n" "$idx" "$checkbox" "${label:0:28}" "$ind"
            ((idx++))
        done

        # Footer
        local sel_count=0
        for k in "${OPTION_LIST[@]}"; do
            [[ "${OPTION_SELECTED[$k]}" == "y" ]] && ((sel_count++))
        done
        echo ""
        echo -e "${DIM}Selected: $sel_count/${#OPTION_LIST[@]}${NC}  ${YELLOW}*${NC}${DIM}=input${NC}"
        echo ""

        read -rp "> " cmd

        case "$cmd" in
            d|D|done|q|Q|quit|"")
                return 0
                ;;
            a|A|all)
                apply_environment_defaults "$environment"
                ;;
            n|N|none)
                for k in "${OPTION_LIST[@]}"; do
                    OPTION_SELECTED["$k"]="n"
                done
                ;;
            [0-9]|[0-9][0-9])
                local num_cmd="$cmd"
                if [[ "$num_cmd" -ge 1 ]] 2>/dev/null && [[ "$num_cmd" -le "$total" ]] 2>/dev/null; then
                    local idx=$((num_cmd - 1))
                    local opt_key="${VISIBLE_OPTIONS[$idx]}"
                    if [[ -n "$opt_key" ]]; then
                        if [[ "${OPTION_SELECTED[$opt_key]:-n}" == "y" ]]; then
                            OPTION_SELECTED["$opt_key"]="n"
                        else
                            OPTION_SELECTED["$opt_key"]="y"
                            # Prompt for inputs if needed
                            local inputs="${OPTION_INPUTS[$opt_key]:-}"
                            if [[ -n "$inputs" ]]; then
                                echo ""
                                IFS=',' read -ra iarr <<< "$inputs"
                                for inp in "${iarr[@]}"; do
                                    local ikey="${inp%%:*}"
                                    local ilabel="${inp#*:}"
                                    local vkey="${opt_key}_${ikey}"
                                    local curr="${OPTION_VALUES[$vkey]:-}"
                                    read -rp "  $ilabel [$curr]: " newval
                                    OPTION_VALUES["$vkey"]="${newval:-$curr}"
                                done
                            fi
                        fi
                    fi
                fi
                ;;
            e|E)
                read -rp "Option # to edit: " num
                if [[ "$num" -ge 1 ]] 2>/dev/null && [[ "$num" -le "$total" ]] 2>/dev/null; then
                    local idx=$((num - 1))
                    local opt_key="${VISIBLE_OPTIONS[$idx]}"
                    local inputs="${OPTION_INPUTS[$opt_key]:-}"
                    if [[ -n "$inputs" ]]; then
                        echo ""
                        IFS=',' read -ra iarr <<< "$inputs"
                        for inp in "${iarr[@]}"; do
                            local ikey="${inp%%:*}"
                            local ilabel="${inp#*:}"
                            local vkey="${opt_key}_${ikey}"
                            local curr="${OPTION_VALUES[$vkey]:-}"
                            read -rp "  $ilabel [$curr]: " newval
                            OPTION_VALUES["$vkey"]="${newval:-$curr}"
                        done
                    fi
                fi
                ;;
        esac
    done
}

# Interactive checkbox menu - uses simple mode for reliability
interactive_select_options() {
    interactive_select_options_simple "$@"
}

# Arrow-key based menu (kept for future use when terminal issues resolved)
interactive_select_options_arrows() {
    local environment="$1"      # dev, stage, live, prod
    local recipe_type="$2"      # drupal, moodle, gitlab
    local existing_config="$3"  # site name for existing config

    # Load appropriate options
    case "$recipe_type" in
        drupal|d|os|nwp|dm) define_drupal_options ;;
        moodle|m) define_moodle_options ;;
        gitlab) define_gitlab_options ;;
        *) define_drupal_options ;;
    esac

    # Apply existing configuration if provided
    if [[ -n "$existing_config" ]]; then
        load_existing_config "$existing_config"
    else
        apply_environment_defaults "$environment"
    fi

    # Build visible options list
    build_option_list "$environment"

    local cursor=0
    local total="${#VISIBLE_OPTIONS[@]}"
    local done=false

    # Check if we have options
    if [[ $total -eq 0 ]]; then
        echo "No options available"
        return 0
    fi

    # Hide cursor (optional, don't fail if not supported)
    tput civis 2>/dev/null || true

    # Cleanup function
    cleanup_terminal() {
        tput cnorm 2>/dev/null || true
        stty echo 2>/dev/null || true
    }
    trap cleanup_terminal EXIT INT TERM

    while [[ "$done" != "true" ]]; do
        # Clear and draw
        clear
        draw_options "$cursor" "$environment"

        # Read key (this blocks until a key is pressed)
        local key
        key=$(read_key)

        case "$key" in
            UP)
                ((cursor > 0)) && ((cursor--))
                ;;
            DOWN)
                ((cursor < total - 1)) && ((cursor++))
                ;;
            SPACE)
                local opt_key="${VISIBLE_OPTIONS[$cursor]}"
                if [[ "${OPTION_SELECTED[$opt_key]}" == "y" ]]; then
                    # Check dependents before deselecting
                    local dependents=$(get_dependents "$opt_key")
                    if [[ -n "$dependents" ]]; then
                        tput cnorm 2>/dev/null
                        echo ""
                        echo -e "${YELLOW}Warning:${NC} Will also deselect: $dependents"
                        read -p "Continue? [y/N]: " confirm
                        tput civis 2>/dev/null
                        if [[ "$confirm" =~ ^[Yy]$ ]]; then
                            OPTION_SELECTED["$opt_key"]="n"
                            # Deselect dependents
                            for dep_key in "${OPTION_LIST[@]}"; do
                                local deps="${OPTION_DEPENDENCIES[$dep_key]}"
                                if [[ -n "$deps" && "$deps" == *"$opt_key"* ]]; then
                                    OPTION_SELECTED["$dep_key"]="n"
                                fi
                            done
                        fi
                    else
                        OPTION_SELECTED["$opt_key"]="n"
                    fi
                else
                    # Check conflicts
                    local conflicts=$(check_conflicts "$opt_key")
                    if [[ -n "$conflicts" ]]; then
                        tput cnorm 2>/dev/null
                        echo ""
                        echo -e "${RED}Conflicts:${NC} $conflicts"
                        read -p "Disable conflicting? [y/N]: " confirm
                        tput civis 2>/dev/null
                        if [[ "$confirm" =~ ^[Yy]$ ]]; then
                            IFS=',' read -ra carr <<< "${OPTION_CONFLICTS[$opt_key]:-}"
                            for c in "${carr[@]}"; do
                                OPTION_SELECTED["$c"]="n"
                            done
                            OPTION_SELECTED["$opt_key"]="y"
                        fi
                    else
                        # Check dependencies
                        local missing=$(check_dependencies "$opt_key")
                        if [[ -n "$missing" ]]; then
                            tput cnorm 2>/dev/null
                            echo ""
                            echo -e "${YELLOW}Requires:${NC} $missing"
                            read -p "Enable dependencies? [Y/n]: " confirm
                            tput civis 2>/dev/null
                            if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
                                IFS=',' read -ra darr <<< "${OPTION_DEPENDENCIES[$opt_key]}"
                                for d in "${darr[@]}"; do
                                    OPTION_SELECTED["$d"]="y"
                                done
                            fi
                        fi
                        OPTION_SELECTED["$opt_key"]="y"
                    fi

                    # Check if input needed
                    local inputs="${OPTION_INPUTS[$opt_key]}"
                    if [[ -n "$inputs" ]]; then
                        tput cnorm 2>/dev/null
                        echo ""
                        IFS=',' read -ra iarr <<< "$inputs"
                        for inp in "${iarr[@]}"; do
                            local ikey="${inp%%:*}"
                            local ilabel="${inp#*:}"
                            local vkey="${opt_key}_${ikey}"
                            local curr="${OPTION_VALUES[$vkey]:-}"
                            read -p "  $ilabel [$curr]: " newval
                            OPTION_VALUES["$vkey"]="${newval:-$curr}"
                        done
                        tput civis 2>/dev/null
                    fi
                fi
                ;;
            ENTER|QUIT)
                # Validate
                local errors=()
                for key in "${OPTION_LIST[@]}"; do
                    if [[ "${OPTION_SELECTED[$key]}" == "y" ]]; then
                        local miss=$(check_dependencies "$key")
                        if [[ -n "$miss" ]]; then
                            errors+=("${OPTION_LABELS[$key]}: needs $miss")
                        fi
                    fi
                done

                if [[ ${#errors[@]} -gt 0 ]]; then
                    tput cnorm 2>/dev/null
                    echo ""
                    echo -e "${RED}Dependency errors:${NC}"
                    for e in "${errors[@]}"; do
                        echo "  - $e"
                    done
                    read -p "Press Enter..."
                    tput civis 2>/dev/null
                else
                    done=true
                fi
                ;;
            ALL)
                apply_environment_defaults "$environment"
                ;;
            NONE)
                for key in "${OPTION_LIST[@]}"; do
                    OPTION_SELECTED["$key"]="n"
                done
                ;;
            EDIT)
                local opt_key="${VISIBLE_OPTIONS[$cursor]}"
                local inputs="${OPTION_INPUTS[$opt_key]}"
                if [[ -n "$inputs" ]]; then
                    tput cnorm 2>/dev/null
                    echo ""
                    echo -e "${BOLD}Edit: ${OPTION_LABELS[$opt_key]}${NC}"
                    IFS=',' read -ra iarr <<< "$inputs"
                    for inp in "${iarr[@]}"; do
                        local ikey="${inp%%:*}"
                        local ilabel="${inp#*:}"
                        local vkey="${opt_key}_${ikey}"
                        local curr="${OPTION_VALUES[$vkey]:-}"
                        read -p "  $ilabel [$curr]: " newval
                        OPTION_VALUES["$vkey"]="${newval:-$curr}"
                    done
                    tput civis 2>/dev/null
                fi
                ;;
            HELP)
                tput cnorm 2>/dev/null
                clear
                echo -e "${BOLD}Keyboard Controls${NC}"
                echo ""
                echo "  ↑/↓     Navigate options"
                echo "  Space   Toggle selected option"
                echo "  Enter   Confirm and continue"
                echo "  a       Select all defaults"
                echo "  n       Deselect all"
                echo "  e       Edit input values"
                echo "  q       Quit/confirm"
                echo "  ?/h     Show this help"
                echo ""
                read -p "Press Enter to continue..."
                tput civis 2>/dev/null
                ;;
        esac
    done

    # Restore cursor
    tput cnorm 2>/dev/null || true
}

# Legacy display function (for non-interactive use)
display_environment_options() {
    local env="$1"
    local env_label="$2"
    local filter_env="$3"

    echo -e " ${BLUE}${BOLD}$env_label${NC}"

    for key in "${OPTION_LIST[@]}"; do
        if ! option_visible_for_env "$key" "$filter_env"; then
            continue
        fi

        local label="${OPTION_LABELS[$key]}"
        local selected="${OPTION_SELECTED[$key]}"

        local checkbox
        if [[ "$selected" == "y" ]]; then
            checkbox="${GREEN}[✓]${NC}"
        else
            checkbox="${DIM}[ ]${NC}"
        fi

        echo -e "   $checkbox $label"
    done
}

# Toggle option by its display index
toggle_option_by_index() {
    local index="$1"
    local idx=1

    for key in "${OPTION_LIST[@]}"; do
        if [[ "$idx" -eq "$index" ]]; then
            if [[ "${OPTION_SELECTED[$key]}" == "y" ]]; then
                # Check for dependents before deselecting
                local dependents=$(get_dependents "$key")
                if [[ -n "$dependents" ]]; then
                    echo ""
                    echo -e "${YELLOW}Warning:${NC} Deselecting '${OPTION_LABELS[$key]}' will affect:"
                    echo -e "  ${dependents}"
                    read -p "Continue? [y/N]: " confirm
                    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                        return
                    fi
                    # Also deselect dependents
                    for opt in "${OPTION_LIST[@]}"; do
                        local deps="${OPTION_DEPENDENCIES[$opt]}"
                        if [[ -n "$deps" ]] && [[ "$deps" == *"$key"* ]]; then
                            OPTION_SELECTED["$opt"]="n"
                        fi
                    done
                fi
                OPTION_SELECTED["$key"]="n"
            else
                # Check conflicts before selecting
                local conflicts=$(check_conflicts "$key")
                if [[ -n "$conflicts" ]]; then
                    echo ""
                    echo -e "${RED}Conflicts with:${NC} $conflicts"
                    read -p "Disable conflicting options? [y/N]: " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        # Disable conflicting options
                        IFS=',' read -ra conflict_arr <<< "${OPTION_CONFLICTS[$key]:-}"
                        for conflict in "${conflict_arr[@]}"; do
                            OPTION_SELECTED["$conflict"]="n"
                        done
                    else
                        return
                    fi
                fi

                # Check dependencies before selecting
                local missing=$(check_dependencies "$key")
                if [[ -n "$missing" ]]; then
                    echo ""
                    echo -e "${YELLOW}Missing dependencies:${NC} $missing"
                    read -p "Enable dependencies too? [Y/n]: " confirm
                    if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
                        # Enable dependencies
                        IFS=',' read -ra dep_arr <<< "${OPTION_DEPENDENCIES[$key]}"
                        for dep in "${dep_arr[@]}"; do
                            OPTION_SELECTED["$dep"]="y"
                        done
                    else
                        return
                    fi
                fi
                OPTION_SELECTED["$key"]="y"

                # Check if inputs are required
                local inputs="${OPTION_INPUTS[$key]}"
                if [[ -n "$inputs" ]]; then
                    edit_option_inputs "$index"
                fi
            fi
            return
        fi
        ((idx++))
    done

    echo -e "${YELLOW}Invalid option number: $index${NC}"
    sleep 1
}

# Edit input values for an option
edit_option_inputs() {
    local index="$1"
    local idx=1

    for key in "${OPTION_LIST[@]}"; do
        if [[ "$idx" -eq "$index" ]]; then
            local inputs="${OPTION_INPUTS[$key]}"
            if [[ -z "$inputs" ]]; then
                echo -e "${YELLOW}Option '${OPTION_LABELS[$key]}' has no inputs to edit${NC}"
                sleep 1
                return
            fi

            echo ""
            echo -e "${BOLD}Editing inputs for: ${OPTION_LABELS[$key]}${NC}"

            IFS=',' read -ra input_arr <<< "$inputs"
            for input in "${input_arr[@]}"; do
                local input_key="${input%%:*}"
                local input_label="${input#*:}"
                local value_key="${key}_${input_key}"
                local current="${OPTION_VALUES[$value_key]:-}"

                if [[ -n "$current" ]]; then
                    read -p "  $input_label [$current]: " new_value
                    new_value="${new_value:-$current}"
                else
                    read -p "  $input_label: " new_value
                fi

                OPTION_VALUES["$value_key"]="$new_value"
            done
            return
        fi
        ((idx++))
    done
}

# Load existing configuration from cnwp.yml site entry
load_existing_config() {
    local site_name="$1"
    local config_file="${2:-cnwp.yml}"

    # Initialize OPTION_FROM_CONFIG if not already declared
    if ! declare -p OPTION_FROM_CONFIG &>/dev/null; then
        declare -gA OPTION_FROM_CONFIG
    fi

    if [[ -f "$config_file" ]] && yaml_site_exists "$site_name" "$config_file" 2>/dev/null; then
        # Get existing options from site entry (silent for TUI)
        local existing_options=$(awk -v site="$site_name" '
            /^sites:/ { in_sites = 1; next }
            in_sites && /^[a-zA-Z]/ && !/^  / { in_sites = 0 }
            in_sites && $0 ~ "^  " site ":" { in_site = 1; next }
            in_site && /^  [a-zA-Z]/ && !/^    / { in_site = 0 }
            in_site && /^    options:/ { in_options = 1; next }
            in_options && /^    [a-zA-Z]/ && !/^      / { in_options = 0 }
            in_options && /^      [a-zA-Z_]+:/ {
                key = $0
                sub(/^      /, "", key)
                sub(/:.*/, "", key)
                val = $0
                sub(/^[^:]+: */, "", val)
                print key "=" val
            }
        ' "$config_file")

        while IFS='=' read -r key val; do
            if [[ -n "$key" ]] && [[ -n "${OPTION_LABELS[$key]:-}" ]]; then
                OPTION_SELECTED["$key"]="$val"
                # Track what was in config (for mismatch detection)
                if [[ "$val" == "y" ]]; then
                    OPTION_FROM_CONFIG["$key"]="y"
                fi
            fi
        done <<< "$existing_options"
    fi
}

################################################################################
# Output Generation
################################################################################

# Generate YAML for selected options
generate_options_yaml() {
    local indent="${1:-    }"

    echo "${indent}options:"
    for key in "${OPTION_LIST[@]}"; do
        if [[ "${OPTION_SELECTED[$key]}" == "y" ]]; then
            echo "${indent}  ${key}: y"

            # Add input values if present
            local inputs="${OPTION_INPUTS[$key]}"
            if [[ -n "$inputs" ]]; then
                IFS=',' read -ra input_arr <<< "$inputs"
                for input in "${input_arr[@]}"; do
                    local input_key="${input%%:*}"
                    local value_key="${key}_${input_key}"
                    local value="${OPTION_VALUES[$value_key]:-}"
                    if [[ -n "$value" ]]; then
                        echo "${indent}    ${input_key}: ${value}"
                    fi
                done
            fi
        fi
    done
}

# Generate manual steps guide based on selected options
generate_manual_steps() {
    local site_name="$1"
    local environment="$2"

    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Manual Steps Required${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    local step=1

    # Development Modules
    if [[ "${OPTION_SELECTED[dev_modules]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Development Modules (Automated)${NC}"
        echo "  Modules will be installed automatically: devel, kint, webprofiler"
        echo "  Access Devel menu at /devel"
        echo ""
        ((step++))
    fi

    # XDebug
    if [[ "${OPTION_SELECTED[xdebug]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Configure XDebug${NC}"
        echo "  1. Run: ddev xdebug on"
        echo "  2. Configure IDE (PhpStorm/VSCode) with port 9003"
        echo "  3. Set breakpoints and start listening for connections"
        echo "  Docs: https://ddev.readthedocs.io/en/stable/users/debugging-profiling/step-debugging/"
        echo ""
        ((step++))
    fi

    # Staging Domain
    if [[ "${OPTION_SELECTED[staging_domain]}" == "y" ]]; then
        local domain="${OPTION_VALUES[staging_domain_domain]:-site-stg.example.com}"
        echo -e "${CYAN}Step $step: Configure Staging Domain${NC}"
        echo "  1. Update DNS A record for: $domain"
        echo "  2. Configure web server (nginx/apache) for domain"
        echo "  3. Update settings.php with trusted_host_patterns"
        echo ""
        ((step++))
    fi

    # Database Sanitization
    if [[ "${OPTION_SELECTED[db_sanitize]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Database Sanitization${NC}"
        echo "  When syncing from production, sanitize user data:"
        echo "  ddev drush sql-sanitize --sanitize-password=test123 --sanitize-email=user+%uid@localhost"
        echo "  This is typically automated in CI/CD pipeline"
        echo ""
        ((step++))
    fi

    # Security Modules
    if [[ "${OPTION_SELECTED[security_modules]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Security Modules (Automated)${NC}"
        echo "  Modules will be installed: seckit, honeypot, login_security, flood_control"
        echo "  Configure at: /admin/config/system/seckit"
        echo "  Review honeypot settings: /admin/config/content/honeypot"
        echo ""
        ((step++))
    fi

    # SSL Certificate
    if [[ "${OPTION_SELECTED[ssl]}" == "y" ]]; then
        local domain="${OPTION_VALUES[ssl_domain]:-example.com}"
        echo -e "${CYAN}Step $step: Configure SSL Certificate${NC}"
        echo "  Run: certbot --nginx -d $domain"
        echo "  Or use Cloudflare SSL if CDN is enabled"
        echo ""
        ((step++))
    fi

    # CDN Configuration
    if [[ "${OPTION_SELECTED[cdn]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Configure Cloudflare CDN${NC}"
        echo "  1. Log into Cloudflare dashboard"
        echo "  2. Add your domain and update nameservers"
        echo "  3. Configure Page Rules for Drupal:"
        echo "     - /admin/* (bypass cache)"
        echo "     - /user/* (bypass cache)"
        echo "  4. Enable development mode during initial testing"
        echo ""
        ((step++))
    fi

    # Redis Configuration
    if [[ "${OPTION_SELECTED[redis]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Configure Redis${NC}"
        echo "  1. For DDEV: ddev get ddev/ddev-redis"
        echo "  2. Edit settings.php to add Redis configuration:"
        echo "     \$settings['redis.connection']['host'] = 'redis';"
        echo "     \$settings['redis.connection']['port'] = 6379;"
        echo "     \$settings['cache']['default'] = 'cache.backend.redis';"
        echo "  3. Enable redis module: ddev drush en redis -y"
        echo ""
        ((step++))
    fi

    # Solr Configuration
    if [[ "${OPTION_SELECTED[solr]}" == "y" ]]; then
        local core="${OPTION_VALUES[solr_core]:-drupal}"
        echo -e "${CYAN}Step $step: Configure Solr${NC}"
        echo "  1. Add Solr service to DDEV: ddev get ddev/ddev-solr"
        echo "  2. Create core: ddev solr create -c $core"
        echo "  3. Configure Search API module:"
        echo "     - Enable: ddev drush en search_api_solr -y"
        echo "     - Create server at /admin/config/search/search-api"
        echo ""
        ((step++))
    fi

    # Cron Configuration
    if [[ "${OPTION_SELECTED[cron]}" == "y" ]]; then
        local interval="${OPTION_VALUES[cron_interval]:-15}"
        echo -e "${CYAN}Step $step: Configure Cron${NC}"
        echo "  For production server, add to crontab:"
        echo "  */$interval * * * * cd /path/to/site && vendor/bin/drush cron"
        echo ""
        echo "  For DDEV development:"
        echo "  ddev drush cron (manual execution)"
        echo ""
        ((step++))
    fi

    # Backup Configuration
    if [[ "${OPTION_SELECTED[backup]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Configure Automated Backups${NC}"
        echo "  1. Configure B2 credentials in .secrets.yml"
        echo "  2. Set up backup script in cron:"
        echo "     0 2 * * * /path/to/backup.sh"
        echo "  3. Test backup and restore procedures"
        echo "  4. Configure retention policy (recommended: 30 days)"
        echo ""
        ((step++))
    fi

    # Production Domain
    if [[ "${OPTION_SELECTED[live_domain]}" == "y" ]]; then
        local domain="${OPTION_VALUES[live_domain_domain]:-example.com}"
        echo -e "${CYAN}Step $step: Configure Production Domain${NC}"
        echo "  1. Update DNS A record for: $domain"
        echo "  2. Configure web server for production"
        echo "  3. Update settings.php with trusted_host_patterns"
        echo "  4. Verify HTTPS is working"
        echo ""
        ((step++))
    fi

    # DNS Records
    if [[ "${OPTION_SELECTED[dns_records]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Configure DNS Records (Automated)${NC}"
        echo "  DNS records are pre-registered via Linode API"
        echo "  Verify at: linode-cli domains list"
        echo "  TTL is set to 300 seconds for quick updates"
        echo ""
        ((step++))
    fi

    # CI/CD Pipeline
    if [[ "${OPTION_SELECTED[ci_enabled]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Configure CI/CD Pipeline${NC}"
        echo "  1. Create .gitlab-ci.yml in project root"
        echo "  2. Configure GitLab Runner for the project"
        echo "  3. Set up deployment keys and variables"
        echo "  4. Configure protected branches (main, develop)"
        echo ""
        ((step++))
    fi

    # 2FA for GitLab
    if [[ "${OPTION_SELECTED[require_2fa]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Enable Required 2FA${NC}"
        echo "  1. Log into GitLab as admin"
        echo "  2. Go to Admin Area > Settings > General"
        echo "  3. Expand 'Sign-in restrictions'"
        echo "  4. Enable 'Require all users to set up two-factor authentication'"
        echo ""
        ((step++))
    fi

    # GitLab Runner
    if [[ "${OPTION_SELECTED[runner]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Install GitLab Runner${NC}"
        echo "  1. Install runner: curl -L https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh | sudo bash"
        echo "  2. sudo apt-get install gitlab-runner"
        echo "  3. Register runner: sudo gitlab-runner register"
        echo "  4. Enter GitLab URL and registration token from Admin > Runners"
        echo ""
        ((step++))
    fi

    # Audit Logging
    if [[ "${OPTION_SELECTED[audit_logging]}" == "y" ]]; then
        echo -e "${CYAN}Step $step: Enable Audit Logging${NC}"
        echo "  1. Go to Admin Area > Settings > General > Visibility"
        echo "  2. Enable audit events"
        echo "  3. View logs at Admin Area > Monitoring > Audit Events"
        echo ""
        ((step++))
    fi

    # Monitoring Setup
    if [[ "${OPTION_SELECTED[monitoring]}" == "y" ]]; then
        local email="${OPTION_VALUES[monitoring_email]:-admin@example.com}"
        echo -e "${CYAN}Step $step: Configure Monitoring${NC}"
        echo "  1. Set up UptimeRobot or Pingdom"
        echo "  2. Add HTTP(s) monitor for your domain"
        echo "  3. Configure alerts to: $email"
        echo "  4. Consider monitoring specific endpoints (/user/login, /api)"
        echo ""
        ((step++))
    fi

    # Email Configuration
    if [[ "${OPTION_SELECTED[email_enabled]}" == "y" ]] || [[ "${OPTION_SELECTED[email_send]}" == "y" ]]; then
        local email="${OPTION_VALUES[email_send_address]:-noreply@example.com}"
        echo -e "${CYAN}Step $step: Configure Email${NC}"
        echo "  1. Verify SMTP credentials in .secrets.yml"
        echo "  2. Install SMTP module: ddev drush en smtp -y"
        echo "  3. Configure at /admin/config/system/smtp"
        echo "  4. Set 'From' address to: $email"
        echo "  5. Test email sending via /admin/config/system/smtp/test"
        echo ""
        ((step++))
    fi

    # Incoming Email
    if [[ "${OPTION_SELECTED[email_receive]}" == "y" ]]; then
        local forward="${OPTION_VALUES[email_receive_forward]:-admin@example.com}"
        echo -e "${CYAN}Step $step: Configure Incoming Email${NC}"
        echo "  1. Configure mailbox via Postfix"
        echo "  2. Set up forwarding to: $forward"
        echo "  3. Configure email processing scripts if needed"
        echo ""
        ((step++))
    fi

    if [[ $step -eq 1 ]]; then
        echo -e "${GREEN}No manual steps required! All selected options will be automated.${NC}"
    else
        echo -e "${BOLD}Total manual steps: $((step-1))${NC}"
    fi
    echo ""
}

# Export functions
export -f define_option clear_options define_drupal_options define_moodle_options define_gitlab_options
export -f get_option_default option_visible_for_env apply_environment_defaults
export -f check_dependencies check_conflicts get_dependents
export -f read_key build_option_list draw_options
export -f display_environment_options interactive_select_options toggle_option_by_index edit_option_inputs
export -f load_existing_config generate_options_yaml generate_manual_steps
