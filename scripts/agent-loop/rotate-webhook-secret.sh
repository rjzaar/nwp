#!/usr/bin/env bash
# rotate-webhook-secret.sh — atomically rotate the GitLab webhook secret
# across the env file, the systemd service, and all allowlisted repos.
#
# Why this script exists
# ----------------------
# GITLAB_WEBHOOK_SECRET is shared by:
#   - ~/.nwp-agent-loop.env (read by systemd unit nwp-webhook + agent-loop cron)
#   - one webhook config per allowlisted repo on the project's GitLab instance
#   - the Drupal nwc_feedback.agent_fast_path.webhook_secret config on every
#     site that uses the /feedback fast-path
#
# If the secret leaks, all of these must be updated together or the webhook
# will start rejecting events from real repos. This script does it in the
# right order:
#   1. Generate a new secret.
#   2. Update each GitLab webhook with the new secret. If any update fails,
#      abort and leave the old secret in place everywhere.
#   3. Once all GitLab updates succeed, write the new secret into the env
#      file and restart the systemd unit.
#   4. Print the new secret so the operator can paste it into Drupal
#      settings.local.php overrides for each site that uses /feedback.
#
# Usage:
#   ./rotate-webhook-secret.sh                 # generate + rotate
#   ./rotate-webhook-secret.sh --dry-run       # show what would change
#   NEW_SECRET=hex... ./rotate-webhook-secret.sh   # use a specific value
#
# Required env (read from ~/.nwp-agent-loop.env if not in the calling shell):
#   GITLAB_TOKEN              api-scoped PAT on the project GitLab instance
#   AGENT_LOOP_GITLAB_BASE_URL  GitLab base URL (no default; must be set)
#
# Exit codes:
#   0 = rotation complete; new secret printed on stdout
#   1 = pre-flight check failed; nothing changed
#   2 = a GitLab update failed mid-rotation; aborted before env file update

set -euo pipefail

NWP_ROOT="${NWP_ROOT:-${HOME}/nwp}"
ENV_FILE="${HOME}/.nwp-agent-loop.env"
GITLAB_BASE_URL="${AGENT_LOOP_GITLAB_BASE_URL:-}"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

# Source the env file so we have GITLAB_TOKEN even when called via cron.
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi

if [[ -z "${GITLAB_TOKEN:-}" ]]; then
  echo "ERROR: GITLAB_TOKEN not set (looked in env + $ENV_FILE)" >&2
  exit 1
fi

if [[ -z "${GITLAB_BASE_URL}" ]]; then
  echo "ERROR: AGENT_LOOP_GITLAB_BASE_URL not set (looked in env + $ENV_FILE)" >&2
  exit 1
fi

# Repos that have a webhook pointing at this receiver. Must match
# gitlab-webhook-receiver.py::ALLOWED_REPOS.
ALLOWED_REPOS=(
  "nwp/nwc"
  "nwp/nwc-project"
  "nwp/nwd-project"
  "nwp/local-nwc-copyright-sync"
  "nwp/auth-nwc-oauth2"
)

NEW_SECRET="${NEW_SECRET:-$(openssl rand -hex 24)}"
echo "Rotating GitLab webhook secret across ${#ALLOWED_REPOS[@]} repo(s)..."
echo "New secret length: ${#NEW_SECRET} chars"
[[ "$DRY_RUN" == "1" ]] && echo "(DRY RUN — no changes will be made)"

# Helper: fetch the webhook id for a repo (assumes one webhook per repo
# pointing at our receiver — if there are multiple, the script picks the
# first match on URL substring "5099/webhook").
find_webhook_id() {
  local repo_path="$1"
  local encoded="${repo_path//\//%2F}"
  curl -sS -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${GITLAB_BASE_URL}/api/v4/projects/${encoded}/hooks" \
    | python3 -c '
import json, sys
hooks = json.load(sys.stdin)
for h in hooks:
    if "5099/webhook" in (h.get("url") or "") or "/webhook" in (h.get("url") or ""):
        print(h["id"]); break
'
}

# 1. Pre-flight: confirm we can find all hook ids before touching anything.
echo "--- pre-flight: finding webhook ids ---"
declare -A HOOK_IDS
for repo in "${ALLOWED_REPOS[@]}"; do
  hid="$(find_webhook_id "$repo")"
  if [[ -z "$hid" ]]; then
    echo "  $repo: NO WEBHOOK FOUND — aborting; nothing changed" >&2
    exit 1
  fi
  HOOK_IDS["$repo"]="$hid"
  echo "  $repo: hook id=$hid"
done

if [[ "$DRY_RUN" == "1" ]]; then
  echo "(dry-run) would update env file: $ENV_FILE"
  echo "(dry-run) would restart: systemctl --user restart nwp-webhook"
  echo "(dry-run) new secret would be: $NEW_SECRET"
  exit 0
fi

# 2. Update each GitLab webhook. Stop on first failure.
echo "--- updating GitLab webhooks ---"
for repo in "${ALLOWED_REPOS[@]}"; do
  hid="${HOOK_IDS[$repo]}"
  encoded="${repo//\//%2F}"
  body="$(python3 -c 'import json, sys; print(json.dumps({"token": sys.argv[1]}))' "$NEW_SECRET")"
  rc=0
  resp="$(curl -sS --fail-with-body -X PUT \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$body" \
    "${GITLAB_BASE_URL}/api/v4/projects/${encoded}/hooks/${hid}" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    echo "  $repo: UPDATE FAILED (rc=$rc): $resp" >&2
    echo
    echo "Partial rotation: some repos may have the new secret, others the old." >&2
    echo "Env file NOT updated; webhook NOT restarted." >&2
    echo "Recovery: re-run this script (idempotent if NEW_SECRET is held stable)" >&2
    echo "or PUT the old secret back manually." >&2
    exit 2
  fi
  echo "  $repo: updated"
done

# 3. Update env file. Use a temp + atomic rename so cron / systemd never see a
# partial file.
echo "--- updating $ENV_FILE ---"
tmp="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
chmod 600 "$tmp"
if grep -q '^GITLAB_WEBHOOK_SECRET=' "$ENV_FILE"; then
  sed "s|^GITLAB_WEBHOOK_SECRET=.*|GITLAB_WEBHOOK_SECRET=$NEW_SECRET|" "$ENV_FILE" > "$tmp"
else
  cat "$ENV_FILE" > "$tmp"
  printf '\nGITLAB_WEBHOOK_SECRET=%s\n' "$NEW_SECRET" >> "$tmp"
fi
mv "$tmp" "$ENV_FILE"
chmod 600 "$ENV_FILE"

# 4. Restart the systemd unit so the receiver picks up the new value.
echo "--- restarting nwp-webhook ---"
systemctl --user restart nwp-webhook
sleep 1
if ! systemctl --user is-active --quiet nwp-webhook; then
  echo "  WARN: nwp-webhook is not active after restart; check 'systemctl --user status nwp-webhook'" >&2
fi

# 5. Print the new secret so the operator can update Drupal settings.local.php.
echo
echo "===================================================================="
echo "ROTATION COMPLETE."
echo
echo "New GITLAB_WEBHOOK_SECRET (also in $ENV_FILE):"
echo "    $NEW_SECRET"
echo
echo "Manual follow-up for each site that uses the /feedback fast-path:"
echo "  edit settings.local.php and set"
echo "    \$config['nwc_feedback.agent_fast_path']['webhook_secret'] = '$NEW_SECRET';"
echo "  drush cr"
echo "===================================================================="
