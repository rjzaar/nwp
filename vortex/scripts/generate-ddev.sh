#!/bin/bash
# Generate DDEV configuration from .env and cnwp.yml
# Usage: ./generate-ddev.sh [site_dir]

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VORTEX_DIR="$(dirname "$SCRIPT_DIR")"
NWP_ROOT="$(dirname "$VORTEX_DIR")"

# Site directory
SITE_DIR="${1:-.}"

# Check if .env exists
ENV_FILE="$SITE_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: .env file not found at $ENV_FILE"
    echo "Run generate-env.sh first"
    exit 1
fi

echo "Generating DDEV configuration from $ENV_FILE..."

# Source .env file
set -a
source "$ENV_FILE"
set +a

# Load .env.local if it exists
if [ -f "$SITE_DIR/.env.local" ]; then
    echo "Loading local overrides from .env.local"
    set -a
    source "$SITE_DIR/.env.local"
    set +a
fi

# Create .ddev directory
DDEV_DIR="$SITE_DIR/.ddev"
mkdir -p "$DDEV_DIR"

# Determine Drupal version based on composer.json if it exists
DRUPAL_VERSION="10"
COMPOSER_FILE="$SITE_DIR/composer.json"
if [ -f "$COMPOSER_FILE" ]; then
    if grep -q '"drupal/core": "^11' "$COMPOSER_FILE" 2>/dev/null; then
        DRUPAL_VERSION="11"
    elif grep -q '"drupal/core": "^10' "$COMPOSER_FILE" 2>/dev/null; then
        DRUPAL_VERSION="10"
    elif grep -q '"drupal/core": "^9' "$COMPOSER_FILE" 2>/dev/null; then
        DRUPAL_VERSION="9"
    fi
fi

# Set defaults from .env or use fallbacks
PROJECT_NAME="${PROJECT_NAME:-${COMPOSE_PROJECT_NAME:-$(basename "$(cd "$SITE_DIR" && pwd)")}}"
WEBROOT="${DRUPAL_WEBROOT:-web}"
PHP_VERSION="${PHP_VERSION:-8.2}"
DATABASE_TYPE="${DATABASE_TYPE:-mariadb}"
DATABASE_VERSION="${DATABASE_VERSION:-10.11}"
WEBSERVER_TYPE="${WEBSERVER_TYPE:-nginx-fpm}"

# Generate config.yaml
CONFIG_FILE="$DDEV_DIR/config.yaml"

cat > "$CONFIG_FILE" << EOF
name: $PROJECT_NAME
type: drupal$DRUPAL_VERSION
docroot: $WEBROOT
php_version: "$PHP_VERSION"
webserver_type: $WEBSERVER_TYPE

database:
  type: $DATABASE_TYPE
  version: "$DATABASE_VERSION"

# Environment variables
web_environment:
  - DRUPAL_PROFILE=${DRUPAL_PROFILE:-standard}
  - DRUPAL_CONFIG_PATH=${DRUPAL_CONFIG_PATH:-../config/default}
  - DRUPAL_TRUSTED_HOSTS=^\${DDEV_SITENAME}\.ddev\.site$
  - ENV_TYPE=${ENV_TYPE:-development}
  - ENV_DEBUG=${ENV_DEBUG:-1}
  - NWP_RECIPE=${NWP_RECIPE:-}
EOF

# Add STAGE_FILE_PROXY_ORIGIN if set
if [ -n "${STAGE_FILE_PROXY_ORIGIN:-}" ]; then
    echo "  - STAGE_FILE_PROXY_ORIGIN=$STAGE_FILE_PROXY_ORIGIN" >> "$CONFIG_FILE"
fi

# Add hooks
cat >> "$CONFIG_FILE" << 'EOF'

# Hooks
hooks:
  post-start:
    - exec: composer install
EOF

# Check if we should enable services
ENABLE_REDIS=${REDIS_ENABLED:-0}
ENABLE_SOLR=${SOLR_ENABLED:-0}
ENABLE_MEMCACHE=${MEMCACHE_ENABLED:-0}

# Add service recommendations
if [ "$ENABLE_REDIS" = "1" ] || [ "$ENABLE_SOLR" = "1" ] || [ "$ENABLE_MEMCACHE" = "1" ]; then
    echo "" >> "$CONFIG_FILE"
    echo "# Recommended DDEV add-ons for this project:" >> "$CONFIG_FILE"
fi

if [ "$ENABLE_REDIS" = "1" ]; then
    echo "#   ddev get ddev/ddev-redis" >> "$CONFIG_FILE"
fi

if [ "$ENABLE_SOLR" = "1" ]; then
    echo "#   ddev get ddev/ddev-solr-drupal" >> "$CONFIG_FILE"
fi

if [ "$ENABLE_MEMCACHE" = "1" ]; then
    echo "#   ddev get ddev/ddev-memcached" >> "$CONFIG_FILE"
fi

echo "✓ Generated $CONFIG_FILE"

# Generate config.local.yaml.example if it doesn't exist
CONFIG_LOCAL_EXAMPLE="$DDEV_DIR/config.local.yaml.example"
if [ ! -f "$CONFIG_LOCAL_EXAMPLE" ]; then
    cat > "$CONFIG_LOCAL_EXAMPLE" << 'EOF'
# DDEV Local Configuration Overrides
# Copy this file to config.local.yaml
# This file is not committed to version control

# Example: Override PHP version
# php_version: "8.3"

# Example: Add additional hostnames
# additional_hostnames:
#   - subdomain1
#   - subdomain2

# Example: Add custom environment variables
# web_environment:
#   - CUSTOM_VAR=value
#   - XDEBUG_MODE=debug,develop

# Example: Mount additional directories
# web_extra_exposed_ports:
#   - name: nodejs
#     container_port: 3000
#     http_port: 3000
#     https_port: 3001

# Example: Increase PHP memory limit
# php_ini:
#   memory_limit: 512M
#   max_execution_time: 300
EOF
    echo "✓ Created $CONFIG_LOCAL_EXAMPLE"
fi

# Check if DDEV is installed
if command -v ddev &> /dev/null; then
    echo ""
    echo "DDEV is installed. You can now:"
    echo "  cd $SITE_DIR"
    echo "  ddev start"

    # Suggest add-ons
    if [ "$ENABLE_REDIS" = "1" ] || [ "$ENABLE_SOLR" = "1" ]; then
        echo ""
        echo "Recommended DDEV add-ons:"
        [ "$ENABLE_REDIS" = "1" ] && echo "  ddev get ddev/ddev-redis"
        [ "$ENABLE_SOLR" = "1" ] && echo "  ddev get ddev/ddev-solr-drupal"
    fi
else
    echo ""
    echo "DDEV is not installed. Install it from:"
    echo "  https://ddev.readthedocs.io/en/stable/users/install/"
fi

echo ""
echo "Configuration complete!"
