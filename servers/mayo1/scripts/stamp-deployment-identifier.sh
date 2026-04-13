#!/usr/bin/env bash
#
# stamp-deployment-identifier.sh — Write a deployment identifier for Drupal
# container invalidation. Called by bluegreen-swap.sh pre-flip.
#
# Usage: stamp-deployment-identifier.sh <docroot>
#   e.g.  stamp-deployment-identifier.sh /var/www/mayo/current/html

set -euo pipefail

DOCROOT="${1:?Usage: stamp-deployment-identifier.sh <docroot>}"

if [[ ! -d "$DOCROOT/sites/default" ]]; then
  echo "ERROR: $DOCROOT does not look like a Drupal webroot" >&2
  exit 1
fi

DEPLOY_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$(git -C "$DOCROOT/.." rev-parse --short HEAD 2>/dev/null || echo 'unknown')"

# Write to .env file that settings.php reads via getenv().
ENV_FILE="$DOCROOT/../.env.deploy"
echo "NWP_DEPLOY_ID=$DEPLOY_ID" > "$ENV_FILE"
chmod 640 "$ENV_FILE"

echo "Stamped deployment identifier: $DEPLOY_ID"
