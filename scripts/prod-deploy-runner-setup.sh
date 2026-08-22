#!/bin/bash
set -uo pipefail
################################################################################
# prod-deploy-runner-setup.sh — install & lock down a GitLab Runner on a deploy-
# tier host so an APPROVED pipeline can trigger the AI-free `nwp-server` verbs.
#
# This is INFRASTRUCTURE AROUND nwp-server, not part of the AI-free artifact — it
# installs gitlab-runner (a CI component) and therefore must NEVER be added to
# build/nwp-server.include. It runs once, on the box, by the operator.
#
# TRUST MODEL (NWP-ADR-0017/0024, CLAUDE.md):
#   - The box stays AI-free (gitlab-runner + the nwp-server artifact only).
#   - It holds a RUNNER AUTHENTICATION TOKEN only (glrt-…) — never an `api` PAT
#     or control-plane credential. The lock-down (tag=prod-deploy, run_untagged
#     =false, locked, ref_protected) is set when the runner is CREATED in the
#     control plane; that token already encodes it. This script does not weaken it.
#   - The runner service runs as a DEDICATED NON-ROOT user that can read the
#     nwp-server ledger (/etc/nwp-server/*.token) but nothing else.
#   - Real prod stays ver/hardware-gated (A14). Use this on the *.nwpcode.org
#     test tier for the autonomous loop; on real prod the human/hardware gate holds.
#
# Usage (run as root on the deploy box):
#   prod-deploy-runner-setup.sh --url URL --token glrt-TOKEN
#       [--user deploy] [--ledger /etc/nwp-server] [--description TEXT] [--verify-only]
#
#   --url URL        the GitLab instance base URL (runtime input; not stored in-tree)
#   --token TOKEN    the runner AUTHENTICATION token (glrt-…) from a runner CREATED
#                    with: tag_list=prod-deploy, run_untagged=false, locked=true,
#                    access_level=ref_protected
#   --user USER      service user (created if missing; default: deploy). NOT root.
#   --ledger DIR     nwp-server ledger dir to grant the service user read on (default:
#                    /etc/nwp-server); tokens set 0640 root:<user>, dir 0750.
#   --description S  runner description (default: prod-deploy (<hostname>))
#   --verify-only    print the lock-down verification for an already-set-up box
#
# Exit: 0 on success / clean verification; non-zero on any failure. Fail-closed:
#       refuses to run the service as root or with a non-prod-deploy token shape.
################################################################################
URL="" TOKEN="" USER_NAME="deploy" LEDGER="/etc/nwp-server" DESC="" VERIFY_ONLY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;          --url=*) URL="${1#*=}"; shift ;;
    --token) TOKEN="$2"; shift 2 ;;      --token=*) TOKEN="${1#*=}"; shift ;;
    --user) USER_NAME="$2"; shift 2 ;;   --user=*) USER_NAME="${1#*=}"; shift ;;
    --ledger) LEDGER="$2"; shift 2 ;;    --ledger=*) LEDGER="${1#*=}"; shift ;;
    --description) DESC="$2"; shift 2 ;; --description=*) DESC="${1#*=}"; shift ;;
    --verify-only) VERIFY_ONLY=true; shift ;;
    -h|--help) sed -n '3,/^###/{/^###/d;p}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "prod-deploy-runner-setup: unknown arg: $1" >&2; exit 2 ;;
  esac
done

say(){ echo "[prod-deploy-runner] $*"; }
die(){ echo "[prod-deploy-runner] ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (installs a system service)"

CFG="/etc/gitlab-runner/config.toml"

verify(){
  echo "── lock-down verification ──"
  if command -v gitlab-runner >/dev/null 2>&1; then
    echo "runner version: $(gitlab-runner --version 2>/dev/null | awk '/Version/{print $2; exit}')"
    # Shell executor: the daemon runs as root but executes JOBS as the --user in
    # ExecStart. What matters for lock-down is the JOB user, not the daemon user.
    local job_user; job_user=$(systemctl cat gitlab-runner 2>/dev/null | tr -d '"' | grep -oE -- '--user +[^ ]+' | awk '{print $2}' | head -1)
    if [ -n "$job_user" ] && [ "$job_user" != root ]; then
      echo "job user:       $job_user (non-root OK — daemon runs jobs as this user)"
    else
      echo "job user:       ${job_user:-unknown} (!!! jobs must run as a non-root --user)"
    fi
    [ -f "$CFG" ] && echo "config perms:   $(stat -c '%a' "$CFG") ($([ "$(stat -c '%a' "$CFG")" = 600 ] && echo OK || echo 'want 600'))"
    echo "executor:       $(grep -oE 'executor *= *"[^"]+"' "$CFG" 2>/dev/null | head -1 | cut -d'"' -f2)"
  else echo "gitlab-runner: NOT installed"; fi
  echo "run_untagged/tag/locked: enforced SERVER-SIDE at runner creation (auth-token flow) —"
  echo "                verify in GitLab: runner tag=prod-deploy, run_untagged=false, locked, ref_protected"
  echo "ledger:         $LEDGER ($(ls -ld "$LEDGER" 2>/dev/null | awk '{print $1,$3,$4}'))"
  # Search credential-likely locations for a personal-access-token; build the
  # pattern dynamically so THIS script never self-matches on the literal string.
  local pfx="gl""pat"
  if grep -rIl "${pfx}-" /etc/gitlab-runner "$LEDGER" /home 2>/dev/null | grep -q .; then
    echo "api PAT on box: !!! FOUND (a runner box must hold only the glrt runner token)"
  else
    echo "api PAT on box: none OK"
  fi
}

if [ "$VERIFY_ONLY" = true ]; then verify; exit 0; fi

[ -n "$URL" ]   || die "--url URL is required"
[ -n "$TOKEN" ] || die "--token glrt-… is required"
case "$TOKEN" in glrt-*) : ;; *) die "token does not look like a runner auth token (expected glrt-…). Create the runner in the control plane first, locked (tag=prod-deploy, run_untagged=false, ref_protected)." ;; esac
[ "$USER_NAME" = root ] && die "refusing to run the runner as root (--user must be non-root)"
[ -n "$DESC" ] || DESC="prod-deploy ($(hostname))"

# ── install gitlab-runner if missing ─────────────────────────────────────────
if ! command -v gitlab-runner >/dev/null 2>&1; then
  say "installing gitlab-runner"
  curl -fsSL "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | bash \
    || die "failed to add gitlab-runner apt repo"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gitlab-runner >/dev/null || die "apt install gitlab-runner failed"
fi

# ── dedicated non-root service user ──────────────────────────────────────────
if ! id "$USER_NAME" >/dev/null 2>&1; then
  say "creating service user: $USER_NAME"
  # NB: the shell executor runs job scripts via this user's LOGIN SHELL, so it must
  # be a real shell (/bin/bash), not nologin — else jobs fail at "prepare environment".
  useradd --system --create-home --shell /bin/bash "$USER_NAME" || die "useradd failed"
fi
# The stock ~/.bash_logout runs `clear_console`, which exits non-zero without a TTY —
# the shell executor's login shell then exits 1 ("prepare environment: exit status 1",
# the documented shell-profile-loading gotcha). Neutralise it for the runner user.
: > "/home/$USER_NAME/.bash_logout" 2>/dev/null || true

# ── register (shell executor; the token carries the tag/lock-down) ───────────
say "registering runner (shell executor) with $URL"
gitlab-runner register --non-interactive --url "$URL" --token "$TOKEN" \
  --executor shell --description "$DESC" || die "runner registration failed"

# ── run the service as the non-root user; lock the config ────────────────────
say "installing service as user '$USER_NAME'"
gitlab-runner stop >/dev/null 2>&1 || true
gitlab-runner uninstall >/dev/null 2>&1 || true
gitlab-runner install --user "$USER_NAME" --working-directory "/home/$USER_NAME" || die "service install failed"
[ -f "$CFG" ] && chmod 600 "$CFG"
gitlab-runner start || die "service start failed"

# ── grant the service user read on the nwp-server ledger (nothing else) ───────
if [ -d "$LEDGER" ]; then
  say "granting $USER_NAME read on $LEDGER"
  chgrp -R "$USER_NAME" "$LEDGER" 2>/dev/null || true
  chmod 750 "$LEDGER" 2>/dev/null || true
  find "$LEDGER" -type f -name '*.token' -exec chmod 640 {} \; 2>/dev/null || true
fi

# ── scoped privilege: let the non-root job user invoke ONLY the nwp-server ─────
# binary as root (the single privileged deploy action). NOPASSWD, nothing else —
# the job never gets general root. apply.sh needs to write the site + run drush.
NWPSRV="$(command -v nwp-server || echo /usr/local/bin/nwp-server)"
SUDOERS="/etc/sudoers.d/${USER_NAME}-nwp-server"
say "granting $USER_NAME scoped NOPASSWD sudo for $NWPSRV"
echo "${USER_NAME} ALL=(root) NOPASSWD: ${NWPSRV}" > "$SUDOERS"
chmod 440 "$SUDOERS"
visudo -cf "$SUDOERS" >/dev/null 2>&1 || die "generated sudoers rule is invalid: $SUDOERS"

say "done."
verify
