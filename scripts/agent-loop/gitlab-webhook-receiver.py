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
- Bind 127.0.0.1 only; never expose 0.0.0.0.
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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# --- config ---------------------------------------------------------------

LISTEN_HOST = '127.0.0.1'
LISTEN_PORT = int(os.environ.get('NWP_WEBHOOK_PORT', '5099'))
MAX_BODY_BYTES = 1024 * 1024  # 1 MB

NWP_ROOT = Path(os.environ.get('NWP_ROOT', '/home/rob/nwp'))
DEPLOY_SCRIPT = NWP_ROOT / 'scripts' / 'agent-loop' / 'deploy-on-merge.sh'
LOG_FILE = NWP_ROOT / 'logs' / 'webhook.log'
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

# Pre-flight: secret must be set (fail-closed).
SECRET = os.environ.get('GITLAB_WEBHOOK_SECRET', '').strip()
if not SECRET:
    print('FATAL: GITLAB_WEBHOOK_SECRET env var must be set + non-empty', file=sys.stderr)
    sys.exit(1)

# Allowlist: only fire deploys for these repos.
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
        if self.path != '/webhook':
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

        event = self.headers.get('X-Gitlab-Event') or 'unknown'
        logger.info('event=%s', event)

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
