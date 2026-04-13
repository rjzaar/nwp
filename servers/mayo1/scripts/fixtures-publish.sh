#!/usr/bin/env bash
#
# fixtures-publish.sh — Run the mayo sanitizer, produce fixtures,
# sign with minisign, and publish to mayo/mayo-fixtures on GitLab.
#
# Runs on mayo1 as root (production server). Designed for the nightly
# systemd timer (mayo-fixtures-publish.timer).
#
# Prerequisites:
#   - minisign installed and key at /etc/nwp/minisign.key
#   - NWP sanitizer at /opt/nwp/lib/sanitizers/mayo.sh
#   - mayo-fixtures repo cloned at /opt/nwp/work/mayo-fixtures
#   - MAYO_FIXTURES_PUSH_TOKEN in /etc/nwp/fixtures.env

set -euo pipefail

SITE="mayostudios.org"
WEBROOT="/var/www/${SITE}"
SANITIZER="/opt/nwp/lib/sanitizers/mayo.sh"
FIXTURES_REPO="/opt/nwp/work/mayo-fixtures"
MINISIGN_KEY="/etc/nwp/minisign.key"
ENV_FILE="/etc/nwp/fixtures.env"
LOG="/var/log/nwp/fixtures-publish.log"
WORK_DIR="/tmp/mayo-fixtures-$$"
DATE_TAG="$(date -u +%Y%m%d)"

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG"; }

log "=== Fixture publish starting ==="

# Validate prerequisites.
for f in "$SANITIZER" "$MINISIGN_KEY" "$ENV_FILE"; do
  [[ -f "$f" ]] || { log "ERROR: Missing $f"; exit 1; }
done
[[ -d "$FIXTURES_REPO/.git" ]] || { log "ERROR: Fixtures repo not found at $FIXTURES_REPO"; exit 1; }

# Load push token.
# shellcheck source=/dev/null
source "$ENV_FILE"
: "${MAYO_FIXTURES_PUSH_TOKEN:?Missing MAYO_FIXTURES_PUSH_TOKEN in $ENV_FILE}"

mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

# Step 1: Run sanitizer on production database.
log "Step 1: Running sanitizer..."
"$SANITIZER" --site "$SITE" --output-dir "$WORK_DIR" 2>&1 | tee -a "$LOG"

SANITIZED_SQL="$WORK_DIR/mayo-sanitized.sql.gz"
if [[ ! -f "$SANITIZED_SQL" ]]; then
  SANITIZED_SQL="$(ls "$WORK_DIR"/mayo-sanitized*.sql.gz 2>/dev/null | head -1)"
fi
[[ -f "$SANITIZED_SQL" ]] || { log "ERROR: Sanitized SQL not found in $WORK_DIR"; exit 1; }

# Step 2: Sign the fixture.
log "Step 2: Signing..."
FIXTURE_NAME="mayo-fixture-${DATE_TAG}.sql.gz"
cp "$SANITIZED_SQL" "$WORK_DIR/$FIXTURE_NAME"

minisign -S -s "$MINISIGN_KEY" -m "$WORK_DIR/$FIXTURE_NAME" \
  -t "mayo-fixture $DATE_TAG $(sha256sum "$WORK_DIR/$FIXTURE_NAME" | cut -d' ' -f1)"

# Step 3: Copy to fixtures repo and commit.
log "Step 3: Publishing to mayo-fixtures..."
cd "$FIXTURES_REPO"
git pull --ff-only origin main 2>&1 | tee -a "$LOG"

cp "$WORK_DIR/$FIXTURE_NAME" .
cp "$WORK_DIR/${FIXTURE_NAME}.minisig" .

# Update manifest.
cat > manifest.yml <<YAML
latest: $FIXTURE_NAME
date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
sha256: $(sha256sum "$FIXTURE_NAME" | cut -d' ' -f1)
YAML

git add "$FIXTURE_NAME" "${FIXTURE_NAME}.minisig" manifest.yml
git commit -m "Fixture: $DATE_TAG"

# Push using the deploy token.
git push "https://fixtures-bot:${MAYO_FIXTURES_PUSH_TOKEN}@git.nwpcode.org/mayo/mayo-fixtures.git" main 2>&1 | tee -a "$LOG"

log "=== Fixture publish complete: $FIXTURE_NAME ==="
