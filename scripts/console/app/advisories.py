"""Security advisories — the one place that understands `composer audit`.

WHY THIS MODULE IS SHARED
-------------------------
The console host has no sites, so it can never run `composer audit`.
Advisories reach it the same way every other fleet number does: inside the
snapshot published by `pl fleet publish` from the machine that HAS the sites
(scripts/commands/fleet.sh -> feeds.security.data).

Both ends of that pipe need the same understanding of an advisory, so both
import this module:

  * the PUBLISHER  calls build_feed()   to turn `pl audit`'s cached records
    into the structured feed it ships;
  * the CONSOLE    calls read_feed()    to turn that feed back into a view
    model — and RE-SANITISES every field, because a snapshot is third-party
    text from another host that gets rendered in a browser.

Pure stdlib, no I/O except the explicit file reads in build_feed(), and no
function here raises on malformed input: a record we cannot parse becomes a
site marked "unreadable", never an exception and never a silent zero.

WHERE THE DATA COMES FROM (and why not a fresh `composer audit`)
---------------------------------------------------------------
`pl audit` already runs `ddev composer audit --locked` per site and caches the
result in private/update-awareness/<site>.json — that same cache is what
`pl rag` grades RED on. Re-running composer audit inside `pl fleet publish`
would mean 16 × `ddev composer` (containers up, minutes) every 30 minutes, and
would let the console disagree with the RAG badge sitting next to it. So the
publisher reads the cache, and `pl fleet publish --refresh-security` is the
explicit opt-in for "re-audit first".

Both input shapes are accepted, because the cache holds whichever `pl audit`
captured: `composer audit --format=json` and composer's human table.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

# ---------------------------------------------------------------------------
# severity
# ---------------------------------------------------------------------------
# composer/packagist severities, worst first. Anything else sorts last as
# "unknown" — an unrecognised severity must never quietly read as "low".
SEVERITY_ORDER = ("critical", "high", "medium", "low")
_SEV_CLASS = {"critical": "sev-critical", "high": "sev-high",
              "medium": "sev-medium", "low": "sev-low"}


def severity_rank(sev: str) -> int:
    s = str(sev or "").strip().lower()
    return SEVERITY_ORDER.index(s) if s in SEVERITY_ORDER else len(SEVERITY_ORDER)


def severity_class(sev: str) -> str:
    """CSS class for a severity. Unknown -> the muted class, never a colour
    that implies we know it is mild."""
    return _SEV_CLASS.get(str(sev or "").strip().lower(), "sev-unknown")


# ---------------------------------------------------------------------------
# field hygiene — everything below is rendered in a browser
# ---------------------------------------------------------------------------
_CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def clean(value, limit: int = 400) -> str:
    """One advisory field, made safe to store and print.

    Escaping for HTML is Jinja's job (autoescape is on); this strips the things
    autoescape does NOT handle — ANSI sequences and control characters — and
    bounds the length so a hostile or broken feed cannot blow up the page.
    """
    text = _ANSI.sub("", str(value if value is not None else ""))
    text = _CTRL.sub(" ", text)
    return " ".join(text.split())[:limit]


def safe_link(url) -> str:
    """An advisory URL we are willing to put in an href, or ''.

    Advisory links come from a third-party feed and are rendered as clickable
    anchors, so the scheme is allowlisted here rather than filtered in the
    template: `javascript:`, `data:` and friends never reach the page.
    """
    text = clean(url, 500)
    low = text.lower()
    if not (low.startswith("https://") or low.startswith("http://")):
        return ""
    if any(c in text for c in ' "\'<>'):
        return ""
    return text


# ---------------------------------------------------------------------------
# parsing composer audit — JSON form
# ---------------------------------------------------------------------------
_NO_CVE = {"", "-", "no cve", "none", "n/a", "null"}


def _norm(package: str, raw: dict) -> dict:
    """One raw composer advisory -> the shape the UI renders."""
    cve = clean(raw.get("cve") or "", 60)
    if cve.lower() in _NO_CVE:
        cve = ""
    ident = clean(raw.get("advisoryId") or raw.get("advisory_id") or "", 80)
    # composer's `sources` carries the upstream id (SA-CORE-…, GHSA-…), which is
    # what an operator actually recognises; prefer it over the packagist PKSA.
    for src in raw.get("sources") or []:
        if isinstance(src, dict) and src.get("remoteId"):
            remote = clean(src.get("remoteId"), 80)
            if remote and remote != ident:
                ident = remote
            break
    return {
        "id": ident or cve or "(no id)",
        "cve": cve,
        "package": clean(package or raw.get("packageName") or raw.get("package_name") or "", 120),
        "installed": "",  # filled in from composer.lock by the publisher
        "affected": clean(raw.get("affectedVersions") or raw.get("affected_versions") or "", 300),
        "title": clean(raw.get("title") or "", 400),
        "severity": clean(raw.get("severity") or "", 20).lower(),
        "reported_at": clean(raw.get("reportedAt") or raw.get("reported_at") or "", 40),
        "link": safe_link(raw.get("link") or raw.get("url") or ""),
    }


def _from_json(data) -> list[dict] | None:
    """composer audit --format=json -> advisories, or None if not that shape."""
    if not isinstance(data, dict):
        return None
    advs = data.get("advisories")
    if advs is None:
        return None
    out: list[dict] = []
    if isinstance(advs, dict):
        for package, items in advs.items():
            if isinstance(items, dict):
                items = list(items.values())
            if not isinstance(items, list):
                continue
            out.extend(_norm(package, a) for a in items if isinstance(a, dict))
    elif isinstance(advs, list):
        out.extend(_norm(a.get("packageName", ""), a) for a in advs if isinstance(a, dict))
    else:
        return None
    return out


# ---------------------------------------------------------------------------
# parsing composer audit — human table form (what `pl audit` caches today)
# ---------------------------------------------------------------------------
_TABLE_FIELDS = {
    "package": "package", "severity": "severity", "advisory id": "id",
    "cve": "cve", "title": "title", "url": "link",
    "affected versions": "affected", "reported at": "reported_at",
}


def _flush_table_row(row: dict, out: list[dict]) -> None:
    if not row.get("package"):
        return
    cve = row.get("cve", "")
    if cve.strip().lower() in _NO_CVE:
        cve = ""
    out.append({
        "id": clean(row.get("id") or cve or "(no id)", 80),
        "cve": clean(cve, 60),
        "package": clean(row.get("package"), 120),
        "installed": "",
        "affected": clean(row.get("affected"), 300),
        "title": clean(row.get("title"), 400),
        "severity": clean(row.get("severity"), 20).lower(),
        "reported_at": clean(row.get("reported_at"), 40),
        "link": safe_link(row.get("link")),
    })


def _from_table(text: str) -> list[dict]:
    """composer's `| Package | drupal/core |` table -> advisories.

    Tolerant by design: the table can arrive wrapped in a ddev/exec error blob
    (that is exactly how `pl audit` captures it), rows wrap onto continuation
    lines with an empty label, and a truncated final row is simply dropped.
    """
    out: list[dict] = []
    row: dict = {}
    last_key = ""
    for line in str(text or "").splitlines():
        line = _ANSI.sub("", line).rstrip()
        stripped = line.strip()
        if stripped.startswith("+-") or stripped.startswith("+="):
            _flush_table_row(row, out)
            row, last_key = {}, ""
            continue
        if not (stripped.startswith("|") and stripped.endswith("|") and len(stripped) > 2):
            continue
        inner = stripped[1:-1]
        if "|" not in inner:
            continue
        label, _, value = inner.partition("|")
        label, value = label.strip().lower(), value.strip()
        if label:
            key = _TABLE_FIELDS.get(label)
            if key is None:
                last_key = ""
                continue
            if key == "package" and row.get("package"):
                _flush_table_row(row, out)  # next record without a rule between
                row = {}
            row[key] = value
            last_key = key
        elif last_key and value:
            row[last_key] = (row.get(last_key, "") + " " + value).strip()
    _flush_table_row(row, out)
    return out


# --- separating ignored-by-policy advisories from active ones ---------------
# composer prints its "Found N …" summaries on STDERR and its tables on STDOUT,
# so once `pl audit` merges the two streams the IGNORED table and the ACTIVE
# table sit back-to-back with no marker between them. Guessing the boundary
# from document order alone would be a coin flip that silently mislabels a live
# advisory as "ignored by policy" — the single worst thing this pane could do.
#
# So the boundary is DERIVED and then VERIFIED against two independent numbers
# composer states in its summary: how many advisories each group has, AND how
# many distinct packages each group spans. A split is only used when exactly
# one candidate satisfies both. Otherwise nothing is labelled and the caller
# says so out loud.
_RE_IGNORED = re.compile(r"found\s+(\d+)\s+ignored\s+security\s+vulnerability\s+advisor\w*"
                         r"(?:\s+affecting\s+(\d+)\s+package)?", re.I)
_RE_ACTIVE = re.compile(r"found\s+(\d+)\s+security\s+vulnerability\s+advisor\w*"
                        r"(?:\s+affecting\s+(\d+)\s+package)?", re.I)


def _group_counts(text: str, pattern) -> tuple[int, int] | None:
    m = pattern.search(text or "")
    if not m:
        return None
    return int(m.group(1)), int(m.group(2) or 0)


def _fits(advs: list[dict], n_adv: int, n_pkg: int) -> bool:
    return len(advs) == n_adv and (n_pkg == 0 or len({a.get("package", "") for a in advs}) == n_pkg)


def split_ignored(advs: list[dict], text: str) -> tuple[list[dict], list[dict], str]:
    """(active, ignored, note). Falls back to (all, [], why) when unverifiable."""
    ign = _group_counts(text, _RE_IGNORED)
    if not ign or not ign[0]:
        return advs, [], ""
    act = _group_counts(text, _RE_ACTIVE) or (len(advs) - ign[0], 0)
    n_ign, n_act = ign[0], act[0]
    if n_ign + n_act != len(advs):
        return advs, [], (f"{n_ign} advisor{'y' if n_ign == 1 else 'ies'} are ignored by policy, but "
                          "composer's cached output could not be split — the list below is BOTH sets")
    # Candidate A: ignored table first (what composer does today).
    # Candidate B: active table first (what it might do tomorrow).
    a_ign, a_act = advs[:n_ign], advs[n_ign:]
    b_act, b_ign = advs[:n_act], advs[n_act:]
    ok_a = _fits(a_ign, n_ign, ign[1]) and _fits(a_act, n_act, act[1])
    ok_b = _fits(b_ign, n_ign, ign[1]) and _fits(b_act, n_act, act[1])
    if ok_a and not ok_b:
        return a_act, a_ign, ""
    if ok_b and not ok_a:
        return b_act, b_ign, ""
    return advs, [], (f"{n_ign} advisor{'y' if n_ign == 1 else 'ies'} are ignored by policy, but which "
                      "ones is ambiguous in composer's cached output — the list below is BOTH sets")


def parse_composer_audit(payload) -> list[dict]:
    """`composer audit` output (JSON string, dict, or human table) -> advisories.

    Never raises. Unrecognisable input yields [] — the CALLER decides whether
    that means "clean" or "unknown"; this function refuses to guess, which is
    why build_feed() keeps `security_count` from the record alongside it.
    """
    if isinstance(payload, (dict, list)):
        return _from_json(payload) or []
    text = str(payload or "")
    if not text.strip():
        return []
    stripped = text.strip()
    if stripped[0] in "{[":
        try:
            parsed = _from_json(json.loads(stripped))
        except (json.JSONDecodeError, ValueError):
            parsed = None
        if parsed is not None:
            return parsed
    return _from_table(text)


def sort_advisories(advs: list[dict]) -> list[dict]:
    """Worst severity first, then newest, then stable by package/id.

    Three stable passes rather than one clever key: mixing ascending rank with
    descending ISO dates in a single tuple needs a date-negation hack, and a
    subtly wrong sort order in a security list is not worth the brevity.
    """
    out = sorted(advs, key=lambda a: (str(a.get("package", "")), str(a.get("id", ""))))
    out.sort(key=lambda a: str(a.get("reported_at", "")), reverse=True)
    out.sort(key=lambda a: severity_rank(a.get("severity", "")))
    return out


# ---------------------------------------------------------------------------
# PUBLISHER SIDE — build the feed from `pl audit`'s cached records
# ---------------------------------------------------------------------------
# One site's state, and what each value means to the operator:
#   ok          audited, advisories listed (count may be 0 = clean)
#   stale       audited, but composer fell back to its local cache (registry
#               auth failed) — a 0 here is NOT "verified clean"
#   unreadable  a record exists but we could not make sense of it
#   n/a         nothing composer can audit here (e.g. Moodle) — reported as
#               its own state, never as an error and never as "0 advisories"
#   missing     no `pl audit` record at all — unknown, say so
STATES = ("ok", "stale", "unreadable", "n/a", "missing")


def _installed_versions(lock_path: Path) -> dict[str, str]:
    """package -> installed version, from a composer.lock. {} if unreadable."""
    try:
        data = json.loads(Path(lock_path).read_text())
    except (OSError, ValueError):
        return {}
    out: dict[str, str] = {}
    for key in ("packages", "packages-dev"):
        for pkg in data.get(key) or []:
            if isinstance(pkg, dict) and pkg.get("name"):
                out.setdefault(str(pkg["name"]), str(pkg.get("version", "")))
    return out


def _find_lock(root: Path, site: str) -> Path | None:
    for rel in (f"sites/{site}/dev/composer.lock", f"sites/{site}/composer.lock",
                f"sites/{site}/stg/composer.lock"):
        p = Path(root) / rel
        if p.is_file():
            return p
    return None


def site_block(record: dict, root=None) -> dict:
    """One `pl audit` record -> one site entry of the security feed."""
    if not isinstance(record, dict):
        return {"state": "unreadable", "count": 0, "advisories": [],
                "note": "audit record is not an object"}
    site = clean(record.get("site", ""), 60)
    platform = clean(record.get("platform", ""), 30).lower()
    block = {
        "site": site,
        "state": "ok",
        "platform": platform or "composer",
        "checked": clean(record.get("checked", ""), 40),
        "cache_stale": bool(record.get("cache_stale")),
        "count": 0,
        "ignored": 0,
        "advisories": [],
        "note": "",
    }
    try:
        block["count"] = int(record.get("security_count", 0) or 0)
    except (TypeError, ValueError):
        block["count"] = 0
    try:
        block["ignored"] = int(record.get("ignored_count", 0) or 0)
    except (TypeError, ValueError):
        block["ignored"] = 0

    # Moodle is not composer-managed: `pl audit` grades it on point releases,
    # so there is no advisory list to show. That is "n/a", not "clean".
    if platform == "moodle":
        block["state"] = "n/a"
        block["note"] = clean(record.get("note", "") or
                              "Moodle is not composer-managed — graded on point releases", 300)
        block["moodle"] = {
            "installed": clean(record.get("moodle_installed", ""), 40),
            "latest": clean(record.get("moodle_latest", ""), 40),
            "branch": clean(record.get("moodle_branch", ""), 20),
        }
        return block

    raw = record.get("composer_audit_json")
    if raw is None:
        raw = record.get("composer_audit_text", "")
    advs = parse_composer_audit(raw)

    if not str(raw or "").strip() and not isinstance(raw, (dict, list)):
        block["state"] = "missing"
        block["note"] = "the audit record holds no composer output"
        return block

    # Ignored-by-policy advisories share the cached blob with the active ones.
    if isinstance(raw, str):
        advs, ignored_advs, split_note = split_ignored(advs, raw)
        if split_note:
            block["note"] = split_note
        if ignored_advs:
            for a in ignored_advs:
                a["ignored"] = True
            block["ignored_advisories"] = sort_advisories(ignored_advs)

    if block["count"] and not advs:
        # The record says N advisories but nothing parsed — do NOT show 0.
        block["state"] = "unreadable"
        block["note"] = (f"{block['count']} advisor{'y' if block['count'] == 1 else 'ies'} "
                         "recorded, but the cached composer output could not be parsed")
        return block

    if root is not None and (advs or block.get("ignored_advisories")):
        # "installed" is the one field composer audit never reports; without it
        # "affected: <10.6.13" cannot be acted on. It comes from the site's own
        # composer.lock — a local file read, no container and no network.
        lock = _find_lock(Path(root), site)
        versions = _installed_versions(lock) if lock else {}
        for a in advs + list(block.get("ignored_advisories") or []):
            a["installed"] = clean(versions.get(a.get("package", ""), ""), 40)

    block["advisories"] = sort_advisories(advs)
    if not block["count"]:
        block["count"] = len(advs)
    if block["cache_stale"]:
        block["state"] = "stale"
        block["note"] = ("composer fell back to its local cache (registry auth failed) — "
                         "this list may be incomplete")
    return block


def build_feed(state_dir, sites=None, root=None, now: str = "") -> dict:
    """The `feeds.security.data` payload: one entry per site plus totals.

    `state_dir` is private/update-awareness/. Sites named in `sites` but with no
    record are reported as "missing" rather than omitted, so a site that stopped
    being audited is visible instead of silently disappearing.
    """
    state_dir = Path(state_dir)
    found: dict[str, dict] = {}
    try:
        paths = sorted(state_dir.glob("*.json"))
    except OSError:
        paths = []
    for path in paths:
        try:
            record = json.loads(path.read_text())
        except (OSError, ValueError):
            found[path.stem] = {"site": path.stem, "state": "unreadable", "count": 0,
                                "advisories": [], "note": "audit record is not valid JSON",
                                "platform": "composer", "checked": "", "cache_stale": False,
                                "ignored": 0}
            continue
        block = site_block(record, root=root)
        block["site"] = block.get("site") or path.stem
        found[block["site"]] = block

    for site in sites or []:
        found.setdefault(clean(site, 60), {
            "site": clean(site, 60), "state": "missing", "count": 0, "advisories": [],
            "note": "no pl audit record — run: pl audit --site " + clean(site, 60),
            "platform": "composer", "checked": "", "cache_stale": False, "ignored": 0,
        })

    blocks = [found[k] for k in sorted(found)]
    return {"generated_at": now, "sites": blocks, "totals": totals(blocks)}


def totals(blocks) -> dict:
    """Headline numbers over a list of site blocks. Total by construction."""
    out = {"sites": 0, "sites_affected": 0, "advisories": 0, "sites_unknown": 0,
           "platform_alerts": 0, "by_severity": {}, "worst": ""}
    for b in blocks or []:
        if not isinstance(b, dict):
            continue
        out["sites"] += 1
        state = b.get("state", "")
        if state in ("unreadable", "missing", "stale"):
            out["sites_unknown"] += 1
        try:
            count = int(b.get("count", 0) or 0)
        except (TypeError, ValueError):
            count = 0
        if state == "n/a":
            # Not composer-managed (Moodle). `pl audit` still grades it — being
            # behind the newest point release IS the security signal there,
            # because Moodle ships fixes only in the newest one. It is counted
            # separately so it never inflates the CVE count, but it is NEVER
            # dropped: `pl rag` turns such a site RED and the pane must agree.
            if count:
                out["platform_alerts"] += 1
            continue
        if count:
            out["sites_affected"] += 1
            out["advisories"] += count
        for a in b.get("advisories") or []:
            sev = str((a or {}).get("severity", "")).lower() or "unknown"
            out["by_severity"][sev] = out["by_severity"].get(sev, 0) + 1
    ranked = [s for s in SEVERITY_ORDER if out["by_severity"].get(s)]
    out["worst"] = ranked[0] if ranked else ("unknown" if out["by_severity"] else "")
    return out


# ---------------------------------------------------------------------------
# CONSOLE SIDE — read a published feed back into a view model
# ---------------------------------------------------------------------------
def read_feed(data) -> dict:
    """Published feed -> {"ok", "sites", "totals"} for the Fleet pane.

    Everything is re-sanitised here. The snapshot was written by another host
    and its contents are third-party advisory text; the console must not
    inherit the publisher's trust in it. Returns ok:false (never raises) for a
    feed it cannot read at all.
    """
    if data is None:
        return {"ok": False, "error": "no security feed in this snapshot", "sites": [], "totals": totals([])}
    if isinstance(data, str):
        try:
            data = json.loads(data)
        except (json.JSONDecodeError, ValueError):
            return {"ok": False, "error": "security feed is not JSON", "sites": [], "totals": totals([])}
    if not isinstance(data, dict) or not isinstance(data.get("sites"), list):
        return {"ok": False, "error": "unrecognised security feed shape", "sites": [], "totals": totals([])}

    sites = []
    for raw in data["sites"]:
        if not isinstance(raw, dict):
            continue
        state = str(raw.get("state", "")).lower()
        block = {
            "site": clean(raw.get("site", ""), 60) or "(unnamed)",
            "state": state if state in STATES else "unreadable",
            "platform": clean(raw.get("platform", ""), 30),
            "checked": clean(raw.get("checked", ""), 40),
            "note": clean(raw.get("note", ""), 300),
            "count": _int(raw.get("count")),
            "ignored": _int(raw.get("ignored")),
            "advisories": [],
            "ignored_advisories": [],
        }
        moodle = raw.get("moodle")
        if isinstance(moodle, dict):
            block["moodle"] = {k: clean(moodle.get(k, ""), 40) for k in ("installed", "latest", "branch")}
        for key in ("advisories", "ignored_advisories"):
            rows = []
            for a in raw.get(key) or []:
                if isinstance(a, dict):
                    rows.append(_view_advisory(a, block["site"], len(rows)))
            block[key] = sort_advisories(rows)
        block["anchor"] = "sec-" + _slug(block["site"])
        sites.append(block)

    sites.sort(key=lambda b: (-b["count"], b["site"]))
    return {"ok": True, "sites": sites, "totals": totals(sites),
            "generated_at": clean(data.get("generated_at", ""), 40)}


def _view_advisory(a: dict, site: str, index: int) -> dict:
    """One advisory, re-sanitised for rendering. Never trusts the snapshot."""
    return {
        "id": clean(a.get("id", ""), 80) or "(no id)",
        "cve": clean(a.get("cve", ""), 60),
        "package": clean(a.get("package", ""), 120) or "(unknown package)",
        "installed": clean(a.get("installed", ""), 40),
        "affected": clean(a.get("affected", ""), 300),
        "title": clean(a.get("title", ""), 400),
        "severity": clean(a.get("severity", ""), 20).lower(),
        "sev_class": severity_class(a.get("severity", "")),
        "sev_label": clean(a.get("severity", ""), 20).lower() or "unrated",
        "reported_at": clean(a.get("reported_at", ""), 40),
        "link": safe_link(a.get("link", "")),
        "ignored": bool(a.get("ignored")),
        "anchor": _anchor(site, a.get("id", ""), index),
    }


def _int(value) -> int:
    try:
        return max(0, int(value or 0))
    except (TypeError, ValueError):
        return 0


_SLUG = re.compile(r"[^a-z0-9]+")


def _slug(text: str) -> str:
    return _SLUG.sub("-", str(text or "").lower()).strip("-")[:60] or "x"


def _anchor(site: str, ident: str, index: int) -> str:
    return f"adv-{_slug(site)}-{_slug(ident) or index}"


def affected_sites(view: dict) -> list[dict]:
    """The sites worth expanding: anything with advisories, anything we could
    not audit, and any non-composer site its own checker flagged (a Moodle
    behind on point releases has no advisory list but is still the RED)."""
    if not view.get("ok"):
        return []
    return [b for b in view["sites"]
            if b["advisories"]
            or b["state"] in ("stale", "unreadable", "missing")
            or (b["state"] == "n/a" and b["count"])]


def by_site(view: dict) -> dict:
    """site name -> its block, so the RAG table can link a row to its detail."""
    if not view.get("ok"):
        return {}
    return {b["site"]: b for b in view["sites"]}


def audit_window(view: dict) -> tuple[str, str]:
    """(oldest, newest) `pl audit` timestamp across the fleet.

    The snapshot's own age is NOT the age of this data: the console could be
    showing a 2-minute-old snapshot of a 6-day-old audit. Both get rendered.
    """
    stamps = sorted({b.get("checked", "") for b in view.get("sites") or [] if b.get("checked")})
    return (stamps[0], stamps[-1]) if stamps else ("", "")


def headline(view: dict) -> str:
    """One honest sentence for the Fleet pane and the tab count."""
    if not view.get("ok"):
        return "no security data in this snapshot"
    t = view["totals"]
    if not t["advisories"] and not t["sites_unknown"] and not t.get("platform_alerts"):
        return f"no open advisories across {t['sites']} site(s)"
    parts = []
    if t["advisories"]:
        parts.append(f"{t['advisories']} advisor{'y' if t['advisories'] == 1 else 'ies'} "
                     f"on {t['sites_affected']} site{'' if t['sites_affected'] == 1 else 's'}")
    if t.get("platform_alerts"):
        parts.append(f"{t['platform_alerts']} site(s) behind on platform security releases")
    if t["sites_unknown"]:
        parts.append(f"{t['sites_unknown']} site(s) unknown")
    return ", ".join(parts)
