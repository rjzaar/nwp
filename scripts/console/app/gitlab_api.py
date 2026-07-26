"""GitLab API client for the issues + CI panes — stdlib urllib only.

Token discipline (mirrors lib/gitlab-issues.sh):
  * Read from a 0600 file the OPERATOR provisions (config.GITLAB_TOKEN_FILE,
    default ~/.config/nwp-console/gitlab.token) — the walled ops_note_token
    pattern (non-admin bot, api scope, walled to nwp/ops). `pl console deploy`
    NEVER copies a token; provisioning is a documented manual step.
  * The token value is never logged, never rendered, never in argv.
  * No token file => every function returns {"ok": False, "error": "no-token"}
    and the UI degrades to deep-links into GitLab.
"""
from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

TIMEOUT = 15


class GitLab:
    def __init__(self, host: str, token_file: Path):
        self.host = host
        self.token_file = Path(token_file)

    # -- plumbing ------------------------------------------------------------
    def _token(self) -> str | None:
        try:
            t = self.token_file.read_text().strip()
            return t or None
        except OSError:
            return None

    def has_token(self) -> bool:
        return self._token() is not None

    def web_url(self, path: str = "") -> str:
        return f"https://{self.host}/{path.lstrip('/')}"

    def _req(self, method: str, path: str, payload: dict | None = None) -> dict:
        token = self._token()
        if token is None:
            return {"ok": False, "error": "no-token"}
        url = f"https://{self.host}/api/v4{path}"
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("PRIVATE-TOKEN", token)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                body = r.read().decode("utf-8", "replace")
                return {"ok": True, "status": r.status, "data": json.loads(body) if body else None}
        except urllib.error.HTTPError as e:
            detail = ""
            try:
                detail = e.read().decode("utf-8", "replace")[:300]
            except OSError:
                pass
            return {"ok": False, "error": f"http-{e.code}", "detail": detail}
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
            return {"ok": False, "error": str(e)[:200]}

    @staticmethod
    def _proj(project: str) -> str:
        return urllib.parse.quote(project, safe="")

    # -- issues (nwp/ops) ----------------------------------------------------
    def list_issues(self, project: str, state: str = "opened", per_page: int = 40) -> dict:
        return self._req(
            "GET",
            f"/projects/{self._proj(project)}/issues?state={state}&order_by=updated_at&per_page={per_page}",
        )

    def get_issue(self, project: str, iid: int) -> dict:
        """One issue, by iid. Used by the tenancy check before any issue WRITE:
        the labels on the live issue — not the ones the rendering pane happened
        to show — decide whether a scoped operator may touch it."""
        return self._req("GET", f"/projects/{self._proj(project)}/issues/{int(iid)}")

    def issue_notes(self, project: str, iid: int, per_page: int = 20) -> dict:
        return self._req(
            "GET",
            f"/projects/{self._proj(project)}/issues/{int(iid)}/notes?sort=desc&order_by=created_at&per_page={per_page}",
        )

    def post_note(self, project: str, iid: int, body: str) -> dict:
        body = (body or "").strip()
        if not body or len(body) > 20_000:
            return {"ok": False, "error": "empty or oversized note"}
        return self._req("POST", f"/projects/{self._proj(project)}/issues/{int(iid)}/notes", {"body": body})

    def add_label(self, project: str, iid: int, label: str) -> dict:
        if not label or len(label) > 100:
            return {"ok": False, "error": "bad label"}
        return self._req("PUT", f"/projects/{self._proj(project)}/issues/{int(iid)}", {"add_labels": label})

    def remove_label(self, project: str, iid: int, label: str) -> dict:
        if not label or len(label) > 100:
            return {"ok": False, "error": "bad label"}
        return self._req("PUT", f"/projects/{self._proj(project)}/issues/{int(iid)}", {"remove_labels": label})

    def close_issue(self, project: str, iid: int) -> dict:
        return self._req("PUT", f"/projects/{self._proj(project)}/issues/{int(iid)}", {"state_event": "close"})

    # -- CI (open MRs + head pipelines) --------------------------------------
    def open_mrs(self, project: str, per_page: int = 10) -> dict:
        return self._req(
            "GET",
            f"/projects/{self._proj(project)}/merge_requests?state=opened&order_by=updated_at&per_page={per_page}",
        )

    def mr_detail(self, project: str, iid: int) -> dict:
        return self._req("GET", f"/projects/{self._proj(project)}/merge_requests/{int(iid)}")

    def retry_pipeline(self, project: str, pipeline_id: int) -> dict:
        return self._req("POST", f"/projects/{self._proj(project)}/pipelines/{int(pipeline_id)}/retry")
