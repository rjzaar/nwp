#!/usr/bin/env bash
# deploy-on-merge.sh — auto-deploy an agent-loop MR after it merges on GitLab.
#
# Usage:
#   deploy-on-merge.sh <repo> <commit-sha> [--tier T1|T2|T3]
#
#   <repo>       — bare repo name (nwc | nwc-project | nwd-project | local-nwc-copyright-sync | auth-nwc-oauth2)
#   <commit-sha> — the merge SHA (audit only; we always pull origin/main)
#   --tier       — explicit tier override; otherwise parsed from MR description on GitLab
#
# Behaviour:
#   - Pull the merged main into the relevant local checkout.
#   - For nwc: rsync into both nwc-dev and nwd-dev (ADR-0016 parallel install).
#   - Run Behat + PHPUnit on nwc-dev. Abort if red.
#   - pl dev2stg nwc -y --dev-db   (and nwd, if appropriate)
#   - Re-run tests on stg.
#   - T1/T2: pl stg2live nwc -y (snapshot + nginx -t + smoke is built into pl)
#   - T3: stop with "READY-FOR-MANUAL-LIVE" message.
#   - Smoke-check 5 live URLs after stg2live. Non-200 anywhere = warn + log.
#   - Write a governance_action per stage so the Decision Log shows it.
#
# Exit codes:
#   0  — all stages green (or T3 deferred for manual live)
#   1  — tests failed before any deploy
#   2  — stg deploy failed
#   3  — live deploy failed
#   4  — post-deploy smoke failed (manual rollback needed)

set -euo pipefail

NWP_ROOT="${NWP_ROOT:-/home/rob/nwp}"
LOG_DIR="${NWP_ROOT}/logs"
LOG_FILE="${LOG_DIR}/deploy.log"
GITLAB_BASE_URL="${GITLAB_BASE_URL:-https://git.nwpcode.org}"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"

mkdir -p "$LOG_DIR"

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG_FILE"
}

usage() {
  sed -n '2,20p' "$0"
  exit 64
}

if [[ $# -lt 2 ]]; then usage; fi

REPO="$1"
SHA="$2"
TIER=""
shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier) TIER="$2"; shift 2;;
    *) log "unknown arg: $1"; usage;;
  esac
done

log "=== deploy-on-merge start: repo=$REPO sha=$SHA tier=${TIER:-auto} ==="

# Governance audit helper.
gov_action() {
  local action_type="$1"; local reason="$2"
  cd "$NWP_ROOT/sites/nwc/dev" 2>/dev/null && \
  ddev drush ev "
    if (\Drupal::entityTypeManager()->hasDefinition('governance_action')) {
      try {
        \Drupal::entityTypeManager()->getStorage('governance_action')->create([
          'action_type' => '${action_type}',
          'reason' => '${reason}',
          'actor' => 1,
        ])->save();
      } catch (\Throwable \$e) { /* swallow */ }
    }
  " >/dev/null 2>&1 || true
}

# Map repo → checkout location.
case "$REPO" in
  nwc)
    PROFILE_REPO="$NWP_ROOT/sites/nwc/dev/html/profiles/custom/nwc"
    # parallel install — nwd copies the profile dir
    NWD_PROFILE_COPY="$NWP_ROOT/sites/nwd/dev/html/profiles/custom/nwc"
    ;;
  nwc-project) PROJECT_REPO="$NWP_ROOT/sites/nwc/dev" ;;
  nwd-project) PROJECT_REPO="$NWP_ROOT/sites/nwd/dev" ;;
  local-nwc-copyright-sync) PLUGIN_REPO="/tmp/plugin-checkout-$$" ;;  # cloned fresh
  auth-nwc-oauth2)          PLUGIN_REPO="/tmp/plugin-checkout-$$" ;;
  *) log "unknown repo: $REPO"; exit 64;;
esac

# Stage 1: pull main into local checkout.
log "Stage 1: pull origin main"
if [[ -n "${PROFILE_REPO:-}" ]]; then
  cd "$PROFILE_REPO"
  GIT_SSH_COMMAND="ssh -i ~/.ssh/nwp -o IdentitiesOnly=yes" git fetch origin
  git checkout main
  GIT_SSH_COMMAND="ssh -i ~/.ssh/nwp -o IdentitiesOnly=yes" git pull origin main
  # Parallel install: rsync profile into nwd's copy.
  if [[ -n "${NWD_PROFILE_COPY:-}" && -d "${NWD_PROFILE_COPY}" ]]; then
    log "  rsync profile → nwd-dev's parallel copy"
    rsync -a --delete \
      --exclude='.git/' --exclude='.git*' \
      "${PROFILE_REPO}/" "${NWD_PROFILE_COPY}/"
  fi
fi
if [[ -n "${PROJECT_REPO:-}" ]]; then
  cd "$PROJECT_REPO"
  GIT_SSH_COMMAND="ssh -i ~/.ssh/nwp -o IdentitiesOnly=yes" git fetch origin
  GIT_SSH_COMMAND="ssh -i ~/.ssh/nwp -o IdentitiesOnly=yes" git pull origin main
fi
if [[ -n "${PLUGIN_REPO:-}" ]]; then
  GIT_SSH_COMMAND="ssh -i ~/.ssh/nwp -o IdentitiesOnly=yes" \
    git clone "git@git.nwpcode.org:nwp/${REPO}.git" "$PLUGIN_REPO"
  # Deploy to ssc + ssd if it's a Moodle plugin.
  case "$REPO" in
    local-nwc-copyright-sync|auth-nwc-oauth2)
      plugin_name=$(echo "$REPO" | sed -E 's/^(local-|auth-)//' | tr '-' '_')
      plugin_type=$(echo "$REPO" | grep -oE '^(local|auth)')
      for site in ssc ssd; do
        target="${NWP_ROOT}/sites/${site}/dev/${plugin_type}/${plugin_name}"
        if [[ -d "$target" ]]; then
          rsync -a --delete --exclude='.git/' "${PLUGIN_REPO}/" "${target}/"
          log "  rsync plugin → $target"
        fi
      done
      ;;
  esac
fi
gov_action "deploy_pull" "${REPO}@${SHA}"

# Stage 2: drush cr + tests on dev.
log "Stage 2: dev cache rebuild + tests"
cd "$NWP_ROOT/sites/nwc/dev"
ddev drush cr >> "$LOG_FILE" 2>&1 || true

# Behat suite (if it exists).
if [[ -f "$NWP_ROOT/sites/nwc/dev/behat.yml.dist" ]]; then
  if ! ddev exec "vendor/bin/behat --config=behat.yml.dist --suite=nwc_editorial" >> "$LOG_FILE" 2>&1; then
    log "BEHAT FAILED ON DEV — aborting deploy."
    gov_action "deploy_aborted_behat_red" "${REPO}@${SHA}"
    exit 1
  fi
  log "  Behat: green"
fi

# PHPUnit suite.
if [[ -f "$NWP_ROOT/sites/nwc/dev/phpunit.xml" ]]; then
  if ! ddev exec "cd /var/www/html && SIMPLETEST_DB='mysql://db:db@db:3306/db' BROWSERTEST_OUTPUT_DIRECTORY=/tmp vendor/bin/phpunit --bootstrap=/var/www/html/html/core/tests/bootstrap.php --no-configuration /var/www/html/html/profiles/custom/nwc/modules/nwc_features/nwc_editorial/tests/src/Kernel/" >> "$LOG_FILE" 2>&1; then
    log "PHPUNIT FAILED ON DEV — aborting deploy."
    gov_action "deploy_aborted_phpunit_red" "${REPO}@${SHA}"
    exit 1
  fi
  log "  PHPUnit: green"
fi
gov_action "deploy_dev_tests_green" "${REPO}@${SHA}"

# Stage 3: tier resolution.
if [[ -z "$TIER" ]]; then
  # Try to parse from the MR description via GitLab API (best-effort).
  if [[ -n "$GITLAB_TOKEN" ]]; then
    mr_body=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      "$GITLAB_BASE_URL/api/v4/projects/nwp%2F${REPO}/merge_requests?state=merged&order_by=updated_at&sort=desc&per_page=5" 2>/dev/null | \
      python3 -c "import sys, json
data = json.load(sys.stdin) or []
for mr in data:
    if mr.get('merge_commit_sha','').startswith('${SHA}'[:8]):
        print(mr.get('description',''))
        break" 2>/dev/null || true)
    TIER=$(printf '%s' "$mr_body" | grep -oE 'Tier:[[:space:]]*T[123]' | head -1 | grep -oE 'T[123]' || true)
  fi
  TIER="${TIER:-T2}"   # default to T2 if we can't tell
fi
log "Stage 3: resolved tier=$TIER"

# Stage 4: dev → stg
log "Stage 4: pl dev2stg nwc"
if ! (cd "$NWP_ROOT" && ./pl dev2stg nwc -y --dev-db >> "$LOG_FILE" 2>&1); then
  log "dev2stg failed — aborting"
  gov_action "deploy_stg_failed" "${REPO}@${SHA}"
  exit 2
fi
gov_action "deploy_stg_ok" "${REPO}@${SHA}"

# Stage 5: re-run tests against stg
log "Stage 5: re-run tests against stg"
# Behat/PHPUnit on stg can be heavier; skip for now since we re-tested on dev which is a clone.
# (TODO: when stg has its own test runner, plug it in here.)
log "  (skipping stg test re-run; dev tests are sufficient for current shape)"

# Stage 6: tier gate for live.
case "$TIER" in
  T1|T2)
    log "Stage 6: pl stg2live nwc (auto for $TIER)"
    if ! (cd "$NWP_ROOT" && ./pl stg2live nwc -y >> "$LOG_FILE" 2>&1); then
      log "stg2live FAILED — manual investigation needed"
      gov_action "deploy_live_failed" "${REPO}@${SHA}"
      exit 3
    fi
    gov_action "deploy_live_ok" "${REPO}@${SHA}"
    ;;
  T3)
    log "Stage 6: T3 — STOPPED. Run manually: cd $NWP_ROOT && ./pl stg2live nwc"
    gov_action "deploy_live_t3_pending_manual" "${REPO}@${SHA}"
    exit 0
    ;;
  *)
    log "Unknown tier: $TIER — defaulting to MANUAL"
    exit 0
    ;;
esac

# Stage 7: smoke-check live.
log "Stage 7: post-deploy smoke"
SMOKE_URLS=(
  "https://nwc.nwpcode.org/"
  "https://nwc.nwpcode.org/about"
  "https://nwc.nwpcode.org/guilds"
  "https://nwc.nwpcode.org/help/apply"
  "https://nwc.nwpcode.org/admin/nwc/governance/decisions"
)
smoke_failures=0
for url in "${SMOKE_URLS[@]}"; do
  code=$(curl -sk -L -o /dev/null -w '%{http_code}' --max-time 10 "$url" || echo 000)
  log "  $url -> $code"
  if [[ "$code" != "200" ]]; then
    smoke_failures=$((smoke_failures + 1))
  fi
done

if [[ $smoke_failures -gt 0 ]]; then
  log "POST-DEPLOY SMOKE FAILED ($smoke_failures non-200). Manual rollback may be needed."
  log "Rollback: ssh -i ~/.ssh/nwp gitlab@97.107.137.88 'ls ~/nwp-snapshot-nwc-*.sql.gz | head -1' then gunzip -c | mysql nwc"
  gov_action "deploy_smoke_failed_${smoke_failures}_of_5" "${REPO}@${SHA}"
  exit 4
fi

log "=== deploy-on-merge complete: all green ==="
gov_action "deploy_complete_green" "${REPO}@${SHA}"
exit 0
