"""GitLab API client for the issues + CI panes — stdlib urllib only.

Token discipline (mirrors lib/gitlab-issues.sh):
  * Read from a 0600 file the OPERATOR provisions (config.GITLAB_TOKEN_FILE,
    default ~/.config/nwp-console/gitlab.token) — the walled ops_note_token
    pattern (non-admin bot, api scope, walled to nwp/ops). `pl console deploy`
    NEVER copies a token; provisioning is a documented manual step.
  * The token value is never logged, never rendered, never in argv.
  * No token file => every function returns {"ok": False, "error": "no-token"}
    and the UI degrades to deep-links into GitLab.

PER-TRACKER TOKENS. The walled ops_note_token is walled *hard*: measured from
the console host on 2026-08-02 it returns HTTP 200 for project 21 (nwp/ops) and
HTTP 404 "Project Not Found" for project 16 (nwp/nwc) — 404 is how GitLab says
"not authorised" for a project you cannot see. So reading the tester-feedback
tracker is not a code problem alone; it needs its own credential, and widening
the walled one would hand the console reach it was deliberately denied.

The convention is a sibling file per tracker basename:

    ~/.config/nwp-console/gitlab.token       <- default (nwp/ops)
    ~/.config/nwp-console/gitlab.nwc.token   <- used for nwp/nwc if present

Absent sibling => the default token is tried and the pane reports the real
HTTP status against that tracker. It never renders an empty list as "clean".
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
    def token_file_for(self, project: str | None = None) -> Path:
        """The default token file, unless a sibling named for this tracker's
        basename exists (gitlab.token -> gitlab.nwc.token for nwp/nwc)."""
        if project:
            base = str(project).rstrip("/").rsplit("/", 1)[-1].strip()
            if base and "/" not in base and base not in (".", ".."):
                sibling = self.token_file.with_name(
                    f"{self.token_file.stem}.{base}{self.token_file.suffix}"
                )
                if sibling.exists():
                    return sibling
        return self.token_file

    def _token(self, project: str | None = None) -> str | None:
        try:
            t = self.token_file_for(project).read_text().strip()
            return t or None
        except OSError:
            return None

    def has_token(self, project: str | None = None) -> bool:
        return self._token(project) is not None

    def web_url(self, path: str = "") -> str:
        return f"https://{self.host}/{path.lstrip('/')}"

    def _req(self, method: str, path: str, payload: dict | None = None,
             project: str | None = None) -> dict:
        token = self._token(project)
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
                # x-total is how GitLab states the size of the WHOLE result set,
                # which is the only way a paginating caller can know it stopped
                # early. Absent on keyset pagination; then it stays None and the
                # caller says "at least N" rather than inventing a total.
                total = r.headers.get("x-total")
                return {"ok": True, "status": r.status,
                        "total": int(total) if (total or "").isdigit() else None,
                        "data": json.loads(body) if body else None}
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

    # -- issues --------------------------------------------------------------
    def list_issues(self, project: str, state: str = "opened", per_page: int = 100,
                    labels: str = "", max_pages: int = 4) -> dict:
        """Open (or closed/all) issues for ONE tracker, PAGINATED.

        Returns {ok, data, total, truncated}. `total` is GitLab's x-total for
        the query; `truncated` is True when max_pages ran out before the set
        did. The pane must show both — the previous single un-paginated page of
        40 out of 136 open issues rendered no hint that 96 were missing, and an
        invisible cut is indistinguishable from an empty queue.
        """
        state_q = "" if state == "all" else f"state={state}&"
        labels_q = f"labels={urllib.parse.quote(labels)}&" if labels else ""
        rows: list = []
        total: int | None = None
        page = 1
        while page <= max(1, int(max_pages)):
            r = self._req(
                "GET",
                f"/projects/{self._proj(project)}/issues?{state_q}{labels_q}"
                f"order_by=updated_at&per_page={int(per_page)}&page={page}",
                project=project,
            )
            if not r.get("ok"):
                # Page 1 failed => the tracker is unreadable, say so. A later
                # page failing must not throw away what we already have.
                if page == 1:
                    return dict(r, data=[], total=None, truncated=False)
                return {"ok": True, "data": rows, "total": total, "truncated": True}
            batch = r.get("data") or []
            if page == 1:
                total = r.get("total")
            rows.extend(batch)
            if len(batch) < int(per_page):
                return {"ok": True, "data": rows, "total": total, "truncated": False}
            page += 1
        return {"ok": True, "data": rows, "total": total,
                "truncated": total is None or len(rows) < total}

    def get_issue(self, project: str, iid: int) -> dict:
        """One issue, by iid. Used by the tenancy check before any issue WRITE:
        the labels on the live issue — not the ones the rendering pane happened
        to show — decide whether a scoped operator may touch it."""
        return self._req("GET", f"/projects/{self._proj(project)}/issues/{int(iid)}",
                         project=project)

    def issue_notes(self, project: str, iid: int, per_page: int = 20) -> dict:
        return self._req(
            "GET",
            f"/projects/{self._proj(project)}/issues/{int(iid)}/notes?sort=desc&order_by=created_at&per_page={per_page}",
            project=project,
        )

    def post_note(self, project: str, iid: int, body: str) -> dict:
        body = (body or "").strip()
        if not body or len(body) > 20_000:
            return {"ok": False, "error": "empty or oversized note"}
        return self._req("POST", f"/projects/{self._proj(project)}/issues/{int(iid)}/notes",
                         {"body": body}, project=project)

    def add_label(self, project: str, iid: int, label: str) -> dict:
        if not label or len(label) > 100:
            return {"ok": False, "error": "bad label"}
        return self._req("PUT", f"/projects/{self._proj(project)}/issues/{int(iid)}",
                         {"add_labels": label}, project=project)

    def remove_label(self, project: str, iid: int, label: str) -> dict:
        if not label or len(label) > 100:
            return {"ok": False, "error": "bad label"}
        return self._req("PUT", f"/projects/{self._proj(project)}/issues/{int(iid)}",
                         {"remove_labels": label}, project=project)

    def close_issue(self, project: str, iid: int) -> dict:
        return self._req("PUT", f"/projects/{self._proj(project)}/issues/{int(iid)}",
                         {"state_event": "close"}, project=project)

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
