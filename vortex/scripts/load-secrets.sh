#!/bin/bash
# Load secrets from .secrets.yml and .secrets.data.yml into environment variables
#
# Two-Tier Secrets Architecture:
#   .secrets.yml      - Infrastructure secrets (API tokens, dev credentials)
#   .secrets.data.yml - Data secrets (production DB, SSH, SMTP)
#
# Usage: source ./load-secrets.sh [site_dir] [--all|--infra|--data]
#
# Options:
#   --infra  Load only infrastructure secrets (default, safe for AI contexts)
#   --data   Load only data secrets (for production operations)
#   --all    Load both (use with caution)
#
# This script should be sourced, not executed:
#   source ./load-secrets.sh
# or:
#   . ./load-secrets.sh

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
SITE_DIR="."
LOAD_MODE="infra"  # Default to infrastructure only (safe for AI)

for arg in "$@"; do
    case $arg in
        --infra)
            LOAD_MODE="infra"
            ;;
        --data)
            LOAD_MODE="data"
            ;;
        --all)
            LOAD_MODE="all"
            ;;
        *)
            if [ -d "$arg" ]; then
                SITE_DIR="$arg"
            fi
            ;;
    esac
done

# File paths
INFRA_SECRETS="$SITE_DIR/.secrets.yml"
DATA_SECRETS="$SITE_DIR/.secrets.data.yml"

# Simple YAML parser using awk (no yq required)
get_yaml_value() {
    local path="$1"
    local default="${2:-}"
    local file="$3"

    if [ ! -f "$file" ]; then
        echo "$default"
        return
    fi

    # Split path into parts (e.g., "api_keys.github_token" -> "api_keys" "github_token")
    local parts=(${path//./ })
    local depth=${#parts[@]}

    local value=$(awk -v depth="$depth" -v p1="${parts[0]}" -v p2="${parts[1]}" -v p3="${parts[2]}" '
        BEGIN { level=0; found=0 }
        /^[a-zA-Z_]+:/ {
            if ($1 == p1":") { level=1; next }
            else if (level > 0) { level=0 }
        }
        level==1 && /^  [a-zA-Z_]+:/ {
            sub(/^  /, "")
            if (depth == 1) {
                sub(/:.*/, ""); if ($1 == p1) { sub(/^[^:]+: */, ""); print; found=1; exit }
            } else if ($1 == p2":") { level=2; next }
        }
        level==2 && /^    [a-zA-Z_]+:/ {
            if (depth == 2) {
                sub(/^    /, "")
                if ($1 == p2":") { sub(/^[^:]+: */, ""); gsub(/"/, ""); print; found=1; exit }
            }
        }
        level==1 && /^  [a-zA-Z_]+: *.+/ {
            sub(/^  /, "")
            if ($1 == p2":") {
                sub(/^[^:]+: */, "")
                gsub(/"/, "")
                print
                found=1
                exit
            }
        }
    ' "$file")

    echo "${value:-$default}"
}

# Track loaded secrets
INFRA_LOADED=0
DATA_LOADED=0

################################################################################
# Infrastructure Secrets (.secrets.yml)
# Safe for AI assistants - API tokens for provisioning, dev credentials
################################################################################

load_infra_secrets() {
    if [ ! -f "$INFRA_SECRETS" ]; then
        if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
            echo "Note: .secrets.yml not found at $INFRA_SECRETS"
        fi
        return 0
    fi

    echo "Loading infrastructure secrets from $INFRA_SECRETS..."

    # API keys (development/sandbox)
    export GITHUB_TOKEN=$(get_yaml_value "api_keys.github_token" "" "$INFRA_SECRETS")
    export COMPOSER_AUTH=$(get_yaml_value "api_keys.composer_auth" "" "$INFRA_SECRETS")
    [ -n "$GITHUB_TOKEN" ] && ((INFRA_LOADED++))
    [ -n "$COMPOSER_AUTH" ] && ((INFRA_LOADED++))

    # Local database (ddev/lando managed)
    export LOCAL_DB_HOST=$(get_yaml_value "database.host" "db" "$INFRA_SECRETS")
    export LOCAL_DB_NAME=$(get_yaml_value "database.name" "db" "$INFRA_SECRETS")
    export LOCAL_DB_USER=$(get_yaml_value "database.user" "db" "$INFRA_SECRETS")
    export LOCAL_DB_PASSWORD=$(get_yaml_value "database.password" "db" "$INFRA_SECRETS")

    # Drupal admin (development)
    export DRUPAL_ADMIN_USER=$(get_yaml_value "drupal.admin_user" "admin" "$INFRA_SECRETS")
    export DRUPAL_ADMIN_PASSWORD=$(get_yaml_value "drupal.admin_password" "" "$INFRA_SECRETS")
    export DRUPAL_ADMIN_EMAIL=$(get_yaml_value "drupal.admin_email" "admin@localhost" "$INFRA_SECRETS")
    [ -n "$DRUPAL_ADMIN_PASSWORD" ] && ((INFRA_LOADED++))

    # Local SMTP (development - Mailhog/Mailpit)
    export LOCAL_SMTP_HOST=$(get_yaml_value "smtp.host" "localhost" "$INFRA_SECRETS")
    export LOCAL_SMTP_PORT=$(get_yaml_value "smtp.port" "1025" "$INFRA_SECRETS")

    # Staging deployment
    export STAGING_SSH_KEY=$(get_yaml_value "staging.ssh_key" "~/.ssh/id_rsa" "$INFRA_SECRETS")
    export STAGING_SSH_USER=$(get_yaml_value "staging.ssh_user" "" "$INFRA_SECRETS")
    export STAGING_SSH_HOST=$(get_yaml_value "staging.ssh_host" "" "$INFRA_SECRETS")

    # Third-party services (sandbox keys)
    export SENDGRID_API_KEY=$(get_yaml_value "services.sendgrid_key" "" "$INFRA_SECRETS")
    export GA_TRACKING_ID=$(get_yaml_value "services.ga_tracking_id" "" "$INFRA_SECRETS")
    [ -n "$SENDGRID_API_KEY" ] && ((INFRA_LOADED++))

    echo "  ✓ Loaded $INFRA_LOADED infrastructure secret(s)"
}

################################################################################
# Data Secrets (.secrets.data.yml)
# BLOCKED from AI assistants - production credentials
################################################################################

load_data_secrets() {
    if [ ! -f "$DATA_SECRETS" ]; then
        # Only warn if explicitly requested
        if [ "$LOAD_MODE" = "data" ] || [ "$LOAD_MODE" = "all" ]; then
            echo "Note: .secrets.data.yml not found at $DATA_SECRETS"
        fi
        return 0
    fi

    # Warn if in AI context
    if [ "${AI_CONTEXT:-}" = "true" ]; then
        echo "⚠️  WARNING: Loading data secrets in AI context!" >&2
    fi

    echo "Loading data secrets from $DATA_SECRETS..."

    # Production database
    export PROD_DB_HOST=$(get_yaml_value "production_database.host" "" "$DATA_SECRETS")
    export PROD_DB_PORT=$(get_yaml_value "production_database.port" "3306" "$DATA_SECRETS")
    export PROD_DB_NAME=$(get_yaml_value "production_database.name" "" "$DATA_SECRETS")
    export PROD_DB_USER=$(get_yaml_value "production_database.user" "" "$DATA_SECRETS")
    export PROD_DB_PASSWORD=$(get_yaml_value "production_database.password" "" "$DATA_SECRETS")
    export PROD_DB_ADMIN_PASSWORD=$(get_yaml_value "production_database.admin_password" "" "$DATA_SECRETS")
    [ -n "$PROD_DB_PASSWORD" ] && ((DATA_LOADED++))

    # Production SSH
    export PROD_SSH_KEY=$(get_yaml_value "production_ssh.key_path" "" "$DATA_SECRETS")
    export PROD_SSH_USER=$(get_yaml_value "production_ssh.user" "" "$DATA_SECRETS")
    export PROD_SSH_HOST=$(get_yaml_value "production_ssh.host" "" "$DATA_SECRETS")
    export PROD_SSH_PORT=$(get_yaml_value "production_ssh.port" "22" "$DATA_SECRETS")
    [ -n "$PROD_SSH_HOST" ] && ((DATA_LOADED++))

    # Production SMTP
    export PROD_SMTP_HOST=$(get_yaml_value "production_smtp.host" "" "$DATA_SECRETS")
    export PROD_SMTP_PORT=$(get_yaml_value "production_smtp.port" "587" "$DATA_SECRETS")
    export PROD_SMTP_USERNAME=$(get_yaml_value "production_smtp.username" "" "$DATA_SECRETS")
    export PROD_SMTP_PASSWORD=$(get_yaml_value "production_smtp.password" "" "$DATA_SECRETS")
    [ -n "$PROD_SMTP_HOST" ] && ((DATA_LOADED++))

    # Production Drupal admin
    export PROD_DRUPAL_USER=$(get_yaml_value "production_drupal.admin_user" "" "$DATA_SECRETS")
    export PROD_DRUPAL_PASSWORD=$(get_yaml_value "production_drupal.admin_password" "" "$DATA_SECRETS")
    [ -n "$PROD_DRUPAL_PASSWORD" ] && ((DATA_LOADED++))

    # Backup encryption
    export BACKUP_ENCRYPTION_KEY=$(get_yaml_value "backup.encryption_key" "" "$DATA_SECRETS")

    echo "  ✓ Loaded $DATA_LOADED data secret(s)"
}

################################################################################
# Main
################################################################################

case $LOAD_MODE in
    infra)
        load_infra_secrets
        ;;
    data)
        load_data_secrets
        ;;
    all)
        load_infra_secrets
        load_data_secrets
        ;;
esac

TOTAL_LOADED=$((INFRA_LOADED + DATA_LOADED))

if [ $TOTAL_LOADED -eq 0 ]; then
    echo "Note: No secrets loaded (files may be empty or missing)"
fi

# Return success
return 0 2>/dev/null || exit 0
