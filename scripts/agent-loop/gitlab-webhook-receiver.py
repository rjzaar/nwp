#!/usr/bin/env python3
"""
GitLab webhook receiver for the NWC agent-loop.

Listens on localhost for GitLab merge-request hook events. On a merged MR,
spawns deploy-on-merge.sh as a background subprocess.

Setup
-----
1. Generate a hook secret:
       export GITLAB_WEBHOOK_SECRET=$(openssl rand -hex 24)

2. Run the receiver:
       python3 /home/rob/nwp/scripts/agent-loop/gitlab-webhook-receiver.py &

3. Expose to GitLab. Options in increasing complexity:
   - ngrok:       ngrok http 5099  → use the public URL in GitLab webhook config
   - cloudflared: cloudflared tunnel --url http://localhost:5099
   - reverse proxy on the live host that round-trips to this laptop

4. In each repo on git.nwpcode.org:
   Settings > Webhooks
       URL: https://<your-tunnel-url>/webhook
       Secret token: <GITLAB_WEBHOOK_SECRET>
       Trigger: Merge request events ONLY
       SSL verification: on

5. Test the wiring:
       curl -sk -X POST http://localhost:5099/webhook \\
         -H "X-Gitlab-Token: $GITLAB_WEBHOOK_SECRET" \\
         -H "X-Gitlab-Event: Merge Request Hook" \\
         -H "Content-Type: application/json" \\
         -d '{"object_kind":"merge_request","object_attributes":{"state":"merged","action":"merge","merge_commit_sha":"abc123"},"project":{"path_with_namespace":"nwp/nwc"}}'

Security notes
--------------
- Bind 127.0.0.1 by default. Override via NWP_WEBHOOK_HOST env var; pin to
  your tailnet IP (e.g. 100.64.0.1) when you want tailnet-only ingress.
  Never bind to 0.0.0.0 unless the host is firewalled to accept only
  trusted source IPs.
- Token comparison is constant-time.
- We refuse hooks with no token even if GITLAB_WEBHOOK_SECRET is empty (fail-closed).
- Bodies > 1 MB are rejected.
- Logs go to /home/rob/nwp/logs/webhook.log; rotate via logrotate.

Dependencies: only the Python stdlib (no flask). Production-ish but minimal.
"""

import hmac
import json
import logging
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# --- config ---------------------------------------------------------------

LISTEN_HOST = os.environ.get('NWP_WEBHOOK_HOST', '127.0.0.1')
LISTEN_PORT = int(os.environ.get('NWP_WEBHOOK_PORT', '5099'))
MAX_BODY_BYTES = 1024 * 1024  # 1 MB

NWP_ROOT = Path(os.environ.get('NWP_ROOT', '/home/rob/nwp'))
DEPLOY_SCRIPT = NWP_ROOT / 'scripts' / 'agent-loop' / 'deploy-on-merge.sh'
AGENT_LOOP_SCRIPT = NWP_ROOT / 'scripts' / 'agent-loop' / 'agent-loop.sh'
RESPAWN_DIR = NWP_ROOT / '.agent-respawn'
RESPAWN_DIR.mkdir(parents=True, exist_ok=True)
LOG_FILE = NWP_ROOT / 'logs' / 'webhook.log'
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
# Append-only audit trail for every power-user-triggered action. Lives in its
# own file (not webhook.log) so it can be reviewed without noise from the
# normal hook traffic. Tamper resistance is best-effort — anyone with write
# access to the agent host can edit the file; for real evidentiary value
# this would need to be mirrored to an external append-only sink.
AUDIT_LOG = NWP_ROOT / 'logs' / 'power-user-audit.jsonl'

POWER_USERS_FILE = Path(os.environ.get(
    'NWP_POWER_USERS_FILE',
    str(Path.home() / '.nwp-power-users.json'),
))

# Pre-flight: secret must be set (fail-closed).
SECRET = os.environ.get('GITLAB_WEBHOOK_SECRET', '').strip()
if not SECRET:
    print('FATAL: GITLAB_WEBHOOK_SECRET env var must be set + non-empty', file=sys.stderr)
    sys.exit(1)

# Allowlist: only fire deploys / instant re-spawns for these repos.
ALLOWED_REPOS = {
    'nwp/nwc',
    'nwp/nwc-project',
    'nwp/nwd-project',
    'nwp/local-nwc-copyright-sync',
    'nwp/auth-nwc-oauth2',
}

logging.basicConfig(
    filename=str(LOG_FILE),
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s',
)
logger = logging.getLogger('nwp.webhook')


# --- helpers --------------------------------------------------------------

def constant_time_token_ok(token: str) -> bool:
    """Constant-time compare against GITLAB_WEBHOOK_SECRET."""
    return hmac.compare_digest(token, SECRET)


def is_merge_event(payload: dict) -> bool:
    """A real merge — not just an MR-open / MR-update."""
    if payload.get('object_kind') != 'merge_request':
        return False
    attrs = payload.get('object_attributes') or {}
    return attrs.get('state') == 'merged' and attrs.get('action') in {'merge', 'close'}


def load_power_users() -> dict:
    """Read the power-user allowlist on every hook (so edits take effect without restart)."""
    try:
        raw = POWER_USERS_FILE.read_text()
    except FileNotFoundError:
        return {'gitlab_usernames': [], 'drupal_uids': {}, 'trigger_phrases': []}
    except OSError as e:
        logger.warning('power-users file unreadable (%s); failing closed', e)
        return {'gitlab_usernames': [], 'drupal_uids': {}, 'trigger_phrases': []}
    try:
        return json.loads(raw)
    except ValueError as e:
        logger.warning('power-users file is not JSON (%s); failing closed', e)
        return {'gitlab_usernames': [], 'drupal_uids': {}, 'trigger_phrases': []}


def is_gitlab_power_user(username: str | None, cfg: dict) -> bool:
    if not username:
        return False
    return username in (cfg.get('gitlab_usernames') or [])


def comment_matches_trigger(body: str | None, cfg: dict) -> bool:
    if not body:
        return False
    needles = cfg.get('trigger_phrases') or ['@agent-loop', '/agent fix']
    haystack = body.lower()
    return any(needle.lower() in haystack for needle in needles)


def write_marker(kind: str, payload: dict) -> Path:
    """Drop a JSON marker for agent-loop.sh to pick up. Idempotent on (kind, project, iid)."""
    project_id = payload.get('project_id', 0)
    iid = payload.get('iid', 0)
    name = f'{kind}-{project_id}-{iid}.json'
    path = RESPAWN_DIR / name
    payload = dict(payload, kind=kind, written_at=int(time.time()))
    path.write_text(json.dumps(payload, indent=2) + '\n')
    logger.info('marker written: %s', path.name)
    return path


def audit(event_type: str, actor: str, target: dict, action: str, extra: dict | None = None) -> None:
    """Append one JSON line to the power-user audit trail. Never raises — audit
    failure must not block a webhook response. Caller passes the actor (a power
    user identifier, e.g. gitlab username or `drupal:nwc:1`), a target dict
    (project_id, iid, kind...), and a one-word action string."""
    try:
        entry = {
            'ts': int(time.time()),
            'event_type': event_type,
            'actor': actor,
            'target': target,
            'action': action,
        }
        if extra:
            entry['extra'] = extra
        with AUDIT_LOG.open('a', encoding='utf-8') as f:
            f.write(json.dumps(entry, sort_keys=True) + '\n')
    except OSError as e:
        logger.warning('audit log write failed: %s', e)


def fire_agent_loop() -> None:
    """Kick agent-loop.sh in the background. The cron tick still runs every 30 min
    as a safety net; this just bypasses that wait for power-user events."""
    if not AGENT_LOOP_SCRIPT.exists():
        logger.warning('agent-loop script missing at %s; marker still written', AGENT_LOOP_SCRIPT)
        return
    env_file = Path.home() / '.nwp-agent-loop.env'
    if env_file.exists():
        cmd = ['/bin/bash', '-c', f'. {env_file} && exec {AGENT_LOOP_SCRIPT}']
    else:
        cmd = ['/bin/bash', str(AGENT_LOOP_SCRIPT)]
    logger.info('firing agent-loop: %s', cmd)
    subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL,
        close_fds=True,
        start_new_session=True,
        env={**os.environ},
    )


def spawn_deploy(repo_full_path: str, sha: str, tier: str | None) -> None:
    """Spawn deploy-on-merge.sh as a detached subprocess. Don't block the hook."""
    repo_short = repo_full_path.rsplit('/', 1)[-1]
    args = [str(DEPLOY_SCRIPT), repo_short, sha]
    if tier:
        args += ['--tier', tier]
    logger.info('spawning deploy: %s', args)
    subprocess.Popen(
        args,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL,
        close_fds=True,
        start_new_session=True,
        env={**os.environ},
    )


# --- handlers for new event types ----------------------------------------

def handle_note_hook(payload: dict, cfg: dict) -> tuple[int, dict]:
    """Note Hook: comment on issue or MR. Re-spawn only if power user + trigger phrase."""
    note = payload.get('object_attributes') or {}
    user = payload.get('user') or {}
    username = user.get('username')

    if not is_gitlab_power_user(username, cfg):
        return 200, {'ok': True, 'action': 'ignored', 'reason': 'not a power user'}

    body = note.get('note') or note.get('description') or ''
    if not comment_matches_trigger(body, cfg):
        return 200, {'ok': True, 'action': 'ignored', 'reason': 'no trigger phrase'}

    project = payload.get('project') or {}
    full_path = project.get('path_with_namespace') or ''
    if full_path not in ALLOWED_REPOS:
        return 200, {'ok': True, 'action': 'ignored', 'reason': 'repo not allowlisted'}

    # The Note Hook payload includes the target issue/MR under different keys.
    target_mr = payload.get('merge_request') or {}
    target_issue = payload.get('issue') or {}
    if target_mr:
        iid = target_mr.get('iid')
        target = 'mr'
    elif target_issue:
        iid = target_issue.get('iid')
        target = 'issue'
    else:
        return 200, {'ok': True, 'action': 'ignored', 'reason': 'note has no target iid'}

    project_id = project.get('id')
    write_marker('respawn', {
        'project_id': project_id,
        'project_path': full_path,
        'iid': iid,
        'target': target,
        'actor': username,
        'reason': 'power-user comment',
        'comment_excerpt': body[:500],
    })
    audit('note', username,
          {'project_id': project_id, 'project_path': full_path, 'iid': iid, 'target': target},
          'respawn-queued',
          {'comment_excerpt': body[:200]})
    fire_agent_loop()
    return 202, {'ok': True, 'action': 'respawn-queued', 'target': target, 'iid': iid, 'actor': username}


def handle_mr_action(payload: dict, cfg: dict) -> tuple[int, dict] | None:
    """MR Hook for non-merge actions: label change or review state. Returns None if
    nothing to do (caller falls through to other MR-event handlers)."""
    attrs = payload.get('object_attributes') or {}
    if attrs.get('state') == 'merged':
        return None  # handled by is_merge_event

    user = payload.get('user') or {}
    username = user.get('username')
    if not is_gitlab_power_user(username, cfg):
        return None  # silently ignore; the 30-min poll catches non-power-user actions

    project = payload.get('project') or {}
    full_path = project.get('path_with_namespace') or ''
    if full_path not in ALLOWED_REPOS:
        return None

    # Did the actor just add the "needs-agent-fix" label?
    changes = payload.get('changes') or {}
    labels_change = changes.get('labels') or {}
    previous_labels = {l.get('title') for l in (labels_change.get('previous') or [])}
    current_labels = {l.get('title') for l in (labels_change.get('current') or [])}
    added = current_labels - previous_labels

    review_action = attrs.get('action') == 'approval' and attrs.get('approval_state') == 'requested_changes'

    if 'needs-agent-fix' not in added and not review_action:
        return None

    project_id = project.get('id')
    iid = attrs.get('iid')
    reason = 'label-added: needs-agent-fix' if 'needs-agent-fix' in added else 'review: requested_changes'
    write_marker('respawn', {
        'project_id': project_id,
        'project_path': full_path,
        'iid': iid,
        'target': 'mr',
        'actor': username,
        'reason': reason,
    })
    audit('mr-action', username,
          {'project_id': project_id, 'project_path': full_path, 'iid': iid, 'target': 'mr'},
          'respawn-queued',
          {'reason': reason})
    fire_agent_loop()
    return 202, {'ok': True, 'action': 'respawn-queued', 'target': 'mr', 'iid': iid, 'actor': username}


# --- handler for /feedback endpoint --------------------------------------

def handle_feedback_endpoint(payload: dict) -> tuple[int, dict]:
    """POST /feedback — called by nwc_feedback Drupal hook *after* it has already
    synced the feedback to a GitLab issue via GitLabSyncService::push(). This
    endpoint is the "kick the loop" signal: it verifies the submitter is a
    Drupal power user, writes a marker for the existing issue, and fires
    agent-loop. We deliberately do NOT create the GitLab issue here, to keep
    the Drupal classifier as the single source of truth for tier + labels.

    Expected payload: {site, feedback_id, user_uid, project_id, issue_iid, web_url?}.
    """
    cfg = load_power_users()
    site = (payload.get('site') or '').strip()
    user_uid = int(payload.get('user_uid') or 0)
    project_id = int(payload.get('project_id') or 0)
    issue_iid = int(payload.get('issue_iid') or 0)

    if not site or not project_id or not issue_iid:
        return 400, {'ok': False, 'error': 'site, project_id, issue_iid required'}

    allowed_uids = (cfg.get('drupal_uids') or {}).get(site) or []
    if user_uid not in allowed_uids:
        # Not a power user — fall back to the existing 15-min cron sync. No-op here.
        return 200, {'ok': True, 'action': 'ignored', 'reason': 'not a drupal power user'}

    actor = f'drupal:{site}:{user_uid}'
    write_marker('respawn', {
        'project_id': project_id,
        'iid': issue_iid,
        'target': 'issue',
        'site': site,
        'feedback_id': payload.get('feedback_id'),
        'web_url': payload.get('web_url'),
        'actor': actor,
        'reason': 'power-user feedback submission',
    })
    audit('feedback', actor,
          {'project_id': project_id, 'iid': issue_iid, 'site': site,
           'feedback_id': payload.get('feedback_id')},
          'loop-fired',
          {'web_url': payload.get('web_url')})
    fire_agent_loop()
    return 202, {
        'ok': True,
        'action': 'loop-fired',
        'issue_iid': issue_iid,
        'project_id': project_id,
    }


# --- HTTP handler ---------------------------------------------------------

class WebhookHandler(BaseHTTPRequestHandler):
    server_version = 'NWPWebhook/1.0'

    def _reply(self, code: int, body: dict) -> None:
        raw = json.dumps(body).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        # Health probe.
        if self.path in ('/health', '/'):
            self._reply(200, {'ok': True, 'service': 'nwp-webhook'})
        else:
            self._reply(404, {'ok': False, 'error': 'not found'})

    def do_POST(self):
        if self.path not in ('/webhook', '/feedback'):
            self._reply(404, {'ok': False, 'error': 'not found'})
            return

        length = int(self.headers.get('Content-Length', '0') or 0)
        if length <= 0 or length > MAX_BODY_BYTES:
            self._reply(413, {'ok': False, 'error': 'bad length'})
            return

        token = (self.headers.get('X-Gitlab-Token') or '').strip()
        if not token or not constant_time_token_ok(token):
            logger.warning('unauthorized hook from %s', self.client_address[0])
            self._reply(401, {'ok': False, 'error': 'unauthorized'})
            return

        try:
            raw = self.rfile.read(length)
            payload = json.loads(raw)
        except (ValueError, json.JSONDecodeError) as e:
            logger.warning('bad json from %s: %s', self.client_address[0], e)
            self._reply(400, {'ok': False, 'error': 'bad json'})
            return

        # /feedback is the Drupal fast-path. No GitLab event header; raw JSON.
        if self.path == '/feedback':
            code, body = handle_feedback_endpoint(payload)
            self._reply(code, body)
            return

        event = self.headers.get('X-Gitlab-Event') or 'unknown'
        logger.info('event=%s', event)

        cfg = load_power_users()

        # Note Hook = comment on issue or MR.
        if event == 'Note Hook' or payload.get('object_kind') == 'note':
            code, body = handle_note_hook(payload, cfg)
            self._reply(code, body)
            return

        # MR Hook: first try non-merge actions (label / approval); fall through
        # to the existing merge handler if those don't match.
        if payload.get('object_kind') == 'merge_request':
            mr_action = handle_mr_action(payload, cfg)
            if mr_action is not None:
                code, body = mr_action
                self._reply(code, body)
                return

        if not is_merge_event(payload):
            self._reply(200, {'ok': True, 'action': 'ignored', 'reason': 'not a merge'})
            return

        project = (payload.get('project') or {})
        full_path = project.get('path_with_namespace') or ''
        if full_path not in ALLOWED_REPOS:
            logger.info('repo not in allowlist: %s', full_path)
            self._reply(200, {'ok': True, 'action': 'ignored', 'reason': 'repo not allowlisted'})
            return

        attrs = payload.get('object_attributes') or {}
        sha = attrs.get('merge_commit_sha') or attrs.get('last_commit', {}).get('id') or ''
        if not sha:
            self._reply(400, {'ok': False, 'error': 'no sha in payload'})
            return

        # Best-effort tier extraction from MR description.
        desc = attrs.get('description') or ''
        tier = None
        for line in desc.splitlines():
            line = line.strip()
            if line.startswith('Tier:') or line.startswith('**Tier:'):
                for t in ('T1', 'T2', 'T3'):
                    if t in line:
                        tier = t
                        break
                break

        spawn_deploy(full_path, sha, tier)
        self._reply(202, {'ok': True, 'action': 'spawned', 'repo': full_path, 'sha': sha, 'tier': tier or 'auto'})

    def log_message(self, format, *args):
        # Use our logger; suppress stderr access log.
        logger.info('%s - %s', self.client_address[0], format % args)


def main():
    if not DEPLOY_SCRIPT.exists():
        print(f'FATAL: deploy script not found: {DEPLOY_SCRIPT}', file=sys.stderr)
        sys.exit(1)
    if not os.access(DEPLOY_SCRIPT, os.X_OK):
        print(f'FATAL: deploy script not executable: {DEPLOY_SCRIPT}', file=sys.stderr)
        sys.exit(1)

    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), WebhookHandler)
    logger.info('starting on %s:%d', LISTEN_HOST, LISTEN_PORT)
    print(f'nwp-webhook listening on http://{LISTEN_HOST}:{LISTEN_PORT}  (log: {LOG_FILE})')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info('shutting down')
        server.shutdown()


if __name__ == '__main__':
    main()
