#!/bin/bash
# Generate .env file from cnwp.yml and template
# Usage: ./env-generate.sh <recipe> <sitename> [site_dir]

set -euo pipefail

# Get script directory (lib/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NWP_ROOT="$(dirname "$SCRIPT_DIR")"
TEMPLATES_DIR="$NWP_ROOT/templates/env"

# Arguments
RECIPE="${1:-}"
SITENAME="${2:-}"
SITE_DIR="${3:-.}"

# Validate arguments
if [ -z "$RECIPE" ] || [ -z "$SITENAME" ]; then
    echo "Usage: $0 <recipe> <sitename> [site_dir]"
    echo "Example: $0 d mysite ./mysite"
    exit 1
fi

# Read cnwp.yml
CNWP_FILE="$NWP_ROOT/cnwp.yml"
if [ ! -f "$CNWP_FILE" ]; then
    echo "Error: cnwp.yml not found at $CNWP_FILE"
    exit 1
fi

echo "Generating .env for recipe '$RECIPE' site '$SITENAME'..."

# YAML parsing functions (using awk - no yq required)
read_recipe_config() {
    local key="$1"
    local default="${2:-}"

    # Use awk to extract the value
    local value=$(awk -v recipe="$RECIPE" -v key="$key" '
        BEGIN { in_recipe = 0; found = 0 }
        /^  [a-zA-Z0-9_-]+:/ {
            if ($1 == recipe":") {
                in_recipe = 1
            } else if (in_recipe && /^  [a-zA-Z0-9_-]+:/) {
                in_recipe = 0
            }
        }
        in_recipe && $0 ~ "^    " key ":" {
            sub("^    " key ": *", "")
            print
            found = 1
            exit
        }
    ' "$CNWP_FILE")

    echo "${value:-$default}"
}

# Read global settings
read_setting() {
    local key="$1"
    local default="${2:-}"

    local value=$(awk -v key="$key" '
        /^settings:/ { in_settings = 1; next }
        /^[a-zA-Z]/ && in_settings { in_settings = 0 }
        in_settings && $0 ~ "^  " key ":" {
            sub("^  " key ": *", "")
            print
            exit
        }
    ' "$CNWP_FILE")

    echo "${value:-$default}"
}

# Read nested config with fallback: recipe.services.X.Y -> settings.services.X.Y -> default
read_service_config() {
    local service="$1"
    local key="$2"
    local default="${3:-}"

    # Try recipe first
    local value=$(awk -v recipe="$RECIPE" -v service="$service" -v key="$key" '
        BEGIN { in_recipe=0; in_services=0; in_service=0 }
        /^  [a-zA-Z0-9_-]+:/ {
            if ($1 == recipe":") { in_recipe=1 }
            else if (in_recipe) { in_recipe=0; in_services=0; in_service=0 }
        }
        in_recipe && /^    services:/ { in_services=1; next }
        in_recipe && in_services && /^      [a-zA-Z0-9_-]+:/ {
            sub(/^      /, "")
            if ($1 == service":") { in_service=1; next }
            else { in_service=0 }
        }
        in_recipe && in_services && in_service && /^        [a-zA-Z0-9_-]+:/ {
            sub(/^        /, "")
            if ($1 == key":") {
                sub(/^[^:]+: */, "")
                print
                exit
            }
        }
    ' "$CNWP_FILE")

    # If not found in recipe, try settings
    if [ -z "$value" ]; then
        value=$(awk -v service="$service" -v key="$key" '
            BEGIN { in_settings=0; in_services=0; in_service=0 }
            /^settings:/ { in_settings=1; next }
            /^[a-zA-Z]/ && in_settings { in_settings=0 }
            in_settings && /^  services:/ { in_services=1; next }
            in_settings && in_services && /^    [a-zA-Z0-9_-]+:/ {
                sub(/^    /, "")
                if ($1 == service":") { in_service=1; next }
                else { in_service=0 }
            }
            in_settings && in_services && in_service && /^      [a-zA-Z0-9_-]+:/ {
                sub(/^      /, "")
                if ($1 == key":") {
                    sub(/^[^:]+: */, "")
                    print
                    exit
                }
            }
        ' "$CNWP_FILE")
    fi

    echo "${value:-$default}"
}

# Read config with fallback: recipe -> settings -> default
read_config_with_fallback() {
    local key="$1"
    local default="${2:-}"

    # Try recipe first
    local value=$(read_recipe_config "$key" "")

    # If not found, try settings
    if [ -z "$value" ]; then
        value=$(read_setting "$key" "")
    fi

    echo "${value:-$default}"
}

# Get recipe configuration
PROFILE=$(read_recipe_config "profile" "standard")
WEBROOT=$(read_recipe_config "webroot" "web")
DEV_MODULES=$(read_recipe_config "dev_modules" "")
DEV_COMPOSER=$(read_recipe_config "dev_composer" "")
PRIVATE_DIR=$(read_recipe_config "private" "../private")
CMI_DIR=$(read_recipe_config "cmi" "../cmi")
DEPLOY_METHOD=$(read_recipe_config "prod_method" "rsync")
DEPLOY_TARGET=$(read_recipe_config "prod_alias" "")

# Get global settings
PHP_VERSION=$(read_setting "php" "8.2")
DATABASE_TYPE=$(read_setting "database" "mariadb")
WEBSERVER=$(read_setting "webserver" "nginx")

# Determine template
TEMPLATE_FILE="$TEMPLATES_DIR/.env.base"
RECIPE_TEMPLATE="$TEMPLATES_DIR/.env.$RECIPE"

# Use recipe-specific template if it exists
if [ -f "$RECIPE_TEMPLATE" ]; then
    TEMPLATE_FILE="$RECIPE_TEMPLATE"
else
    # Try profile-based template
    PROFILE_TEMPLATE="$TEMPLATES_DIR/.env.$PROFILE"
    if [ -f "$PROFILE_TEMPLATE" ]; then
        TEMPLATE_FILE="$PROFILE_TEMPLATE"
    fi
fi

echo "Using template: $(basename "$TEMPLATE_FILE")"

# Determine theme based on profile
case "$PROFILE" in
    social)
        THEME="socialblue"
        ;;
    varbase)
        THEME="vartheme_bs5"
        ;;
    minimal|standard)
        THEME="olivero"
        ;;
    *)
        THEME="olivero"
        ;;
esac

# Determine services - check recipe.services, then settings.services, then profile defaults
REDIS_ENABLED=$(read_service_config "redis" "enabled" "")
SOLR_ENABLED=$(read_service_config "solr" "enabled" "")
SOLR_CORE=$(read_service_config "solr" "core" "drupal")
MEMCACHE_ENABLED=$(read_service_config "memcache" "enabled" "")

# If not explicitly set, use profile-based defaults
if [ -z "$REDIS_ENABLED" ]; then
    case "$PROFILE" in
        social|varbase) REDIS_ENABLED=1 ;;
        *) REDIS_ENABLED=0 ;;
    esac
fi

if [ -z "$SOLR_ENABLED" ]; then
    case "$PROFILE" in
        social|varbase) SOLR_ENABLED=1 ;;
        *) SOLR_ENABLED=0 ;;
    esac
fi

if [ -z "$MEMCACHE_ENABLED" ]; then
    MEMCACHE_ENABLED=0
fi

# Convert true/false to 1/0
case "$REDIS_ENABLED" in
    true|True|TRUE|1|yes|Yes|YES) REDIS_ENABLED=1 ;;
    *) REDIS_ENABLED=0 ;;
esac

case "$SOLR_ENABLED" in
    true|True|TRUE|1|yes|Yes|YES) SOLR_ENABLED=1 ;;
    *) SOLR_ENABLED=0 ;;
esac

case "$MEMCACHE_ENABLED" in
    true|True|TRUE|1|yes|Yes|YES) MEMCACHE_ENABLED=1 ;;
    *) MEMCACHE_ENABLED=0 ;;
esac

# Create site directory if it doesn't exist
mkdir -p "$SITE_DIR"

# Generate .env file
ENV_FILE="$SITE_DIR/.env"

echo "# Generated environment configuration for $SITENAME" > "$ENV_FILE"
echo "# Recipe: $RECIPE" >> "$ENV_FILE"
echo "# Profile: $PROFILE" >> "$ENV_FILE"
echo "# Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "$ENV_FILE"
echo "#" >> "$ENV_FILE"
echo "# DO NOT EDIT THIS FILE DIRECTLY" >> "$ENV_FILE"
echo "# For local overrides, use .env.local" >> "$ENV_FILE"
echo "# For secrets, use .secrets.yml" >> "$ENV_FILE"
echo "" >> "$ENV_FILE"

# Read template and substitute variables
while IFS= read -r line; do
    # Skip empty lines and comments in template
    if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
        echo "$line" >> "$ENV_FILE"
        continue
    fi

    # Substitute variables
    line="${line//\$\{PROJECT_NAME\}/$SITENAME}"
    line="${line//\$\{COMPOSE_PROJECT_NAME\}/$SITENAME}"
    line="${line//\$\{DRUPAL_PROFILE\}/$PROFILE}"
    line="${line//\$\{DRUPAL_WEBROOT\}/$WEBROOT}"
    line="${line//\$\{DRUPAL_THEME\}/$THEME}"
    line="${line//\$\{DRUPAL_PRIVATE_FILES\}/$PRIVATE_DIR}"
    line="${line//\$\{REDIS_ENABLED:-0\}/$REDIS_ENABLED}"
    line="${line//\$\{SOLR_ENABLED:-0\}/$SOLR_ENABLED}"
    line="${line//\$\{SOLR_CORE:-drupal\}/$SOLR_CORE}"
    line="${line//\$\{MEMCACHE_ENABLED:-0\}/$MEMCACHE_ENABLED}"
    line="${line//\$\{DEV_MODULES\}/$DEV_MODULES}"
    line="${line//\$\{DEV_COMPOSER\}/$DEV_COMPOSER}"
    line="${line//\$\{DEPLOY_METHOD\}/$DEPLOY_METHOD}"
    line="${line//\$\{DEPLOY_TARGET\}/$DEPLOY_TARGET}"
    line="${line//\$\{NWP_RECIPE\}/$RECIPE}"
    line="${line//\$\{STAGE_FILE_PROXY_ORIGIN\}/}"

    echo "$line" >> "$ENV_FILE"
done < <(grep -v "^#\|^$" "$TEMPLATE_FILE" || true)

# Copy .env.local.example if it doesn't exist
if [ ! -f "$SITE_DIR/.env.local" ] && [ ! -f "$SITE_DIR/.env.local.example" ]; then
    cp "$TEMPLATES_DIR/.env.local.example" "$SITE_DIR/.env.local.example"
    echo "Created .env.local.example"
fi

# Copy .secrets.example.yml if it doesn't exist
if [ ! -f "$SITE_DIR/.secrets.yml" ] && [ ! -f "$SITE_DIR/.secrets.example.yml" ]; then
    cp "$TEMPLATES_DIR/.secrets.example.yml" "$SITE_DIR/.secrets.example.yml"
    echo "Created .secrets.example.yml"
fi

echo "✓ Generated $ENV_FILE"
echo ""
echo "Next steps:"
echo "1. Review $ENV_FILE"
echo "2. Copy .env.local.example to .env.local for local overrides"
echo "3. Copy .secrets.example.yml to .secrets.yml for credentials"
echo "4. Never commit .env.local or .secrets.yml to version control!"
