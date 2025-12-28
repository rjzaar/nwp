#!/bin/bash
# Load secrets from .secrets.yml into environment variables
# Usage: source ./load-secrets.sh [site_dir]
#
# This script should be sourced, not executed:
#   source ./load-secrets.sh
# or:
#   . ./load-secrets.sh

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Site directory
SITE_DIR="${1:-.}"

# Secrets file
SECRETS_FILE="$SITE_DIR/.secrets.yml"

if [ ! -f "$SECRETS_FILE" ]; then
    # Only show warning if explicitly called (not from other scripts)
    if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
        echo "Warning: .secrets.yml not found at $SECRETS_FILE"
        echo "Create from .secrets.example.yml if you need to store credentials"
    fi
    return 0 2>/dev/null || exit 0
fi

echo "Loading secrets from $SECRETS_FILE..."

# Simple YAML parser using awk (no yq required)
get_yaml_value() {
    local path="$1"
    local default="${2:-}"
    local file="$3"

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

# Load API keys
export GITHUB_TOKEN=$(get_yaml_value "api_keys.github_token" "" "$SECRETS_FILE")
export ACQUIA_KEY=$(get_yaml_value "api_keys.acquia_key" "" "$SECRETS_FILE")
export ACQUIA_SECRET=$(get_yaml_value "api_keys.acquia_secret" "" "$SECRETS_FILE")
export COMPOSER_AUTH=$(get_yaml_value "api_keys.composer_auth" "" "$SECRETS_FILE")

# Load database credentials
export DATABASE_ADMIN_PASSWORD=$(get_yaml_value "database.admin_password" "" "$SECRETS_FILE")
export DATABASE_BACKUP_USER=$(get_yaml_value "database.backup_user" "" "$SECRETS_FILE")
export DATABASE_BACKUP_PASSWORD=$(get_yaml_value "database.backup_password" "" "$SECRETS_FILE")

# Load Drupal admin
export DRUPAL_ADMIN_USER=$(get_yaml_value "drupal.admin_user" "admin" "$SECRETS_FILE")
export DRUPAL_ADMIN_PASSWORD=$(get_yaml_value "drupal.admin_password" "" "$SECRETS_FILE")
export DRUPAL_ADMIN_EMAIL=$(get_yaml_value "drupal.admin_email" "admin@localhost" "$SECRETS_FILE")

# Load SMTP settings
export SMTP_HOST=$(get_yaml_value "smtp.host" "" "$SECRETS_FILE")
export SMTP_PORT=$(get_yaml_value "smtp.port" "587" "$SECRETS_FILE")
export SMTP_USERNAME=$(get_yaml_value "smtp.username" "" "$SECRETS_FILE")
export SMTP_PASSWORD=$(get_yaml_value "smtp.password" "" "$SECRETS_FILE")
export SMTP_FROM_EMAIL=$(get_yaml_value "smtp.from_email" "" "$SECRETS_FILE")

# Load deployment
export DEPLOY_SSH_KEY=$(get_yaml_value "deployment.ssh_key" "~/.ssh/id_rsa" "$SECRETS_FILE")
export DEPLOY_SSH_USER=$(get_yaml_value "deployment.ssh_user" "" "$SECRETS_FILE")
export DEPLOY_SSH_HOST=$(get_yaml_value "deployment.ssh_host" "" "$SECRETS_FILE")
export DEPLOY_REMOTE_PATH=$(get_yaml_value "deployment.remote_path" "" "$SECRETS_FILE")

# Load third-party services
export SENDGRID_API_KEY=$(get_yaml_value "services.sendgrid_key" "" "$SECRETS_FILE")
export MAILCHIMP_API_KEY=$(get_yaml_value "services.mailchimp_key" "" "$SECRETS_FILE")
export GA_TRACKING_ID=$(get_yaml_value "services.ga_tracking_id" "" "$SECRETS_FILE")
export CLOUDFLARE_API_KEY=$(get_yaml_value "services.cloudflare_api_key" "" "$SECRETS_FILE")
export CLOUDFLARE_ZONE_ID=$(get_yaml_value "services.cloudflare_zone_id" "" "$SECRETS_FILE")

# Count loaded secrets (non-empty values)
LOADED=0
[ -n "$GITHUB_TOKEN" ] && ((LOADED++))
[ -n "$ACQUIA_KEY" ] && ((LOADED++))
[ -n "$DRUPAL_ADMIN_PASSWORD" ] && ((LOADED++))
[ -n "$SMTP_HOST" ] && ((LOADED++))

if [ $LOADED -gt 0 ]; then
    echo "✓ Loaded $LOADED secret(s) from .secrets.yml"
else
    echo "Warning: No secrets found in .secrets.yml (all values are empty)"
fi

# Return success
return 0 2>/dev/null || exit 0
