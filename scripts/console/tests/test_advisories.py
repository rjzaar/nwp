"""Security advisories: parsing, the feed contract, and XSS containment.

The module under test sits on BOTH sides of the publish pipe (the workstation
builds the feed, the console renders it), so these tests exercise the whole
round trip: composer output -> build_feed -> JSON -> read_feed -> template.
"""
from __future__ import annotations

import json

import pytest

from app import advisories, parsers

# The rest of scripts/console/tests/ is stdlib-only on purpose (README: "pytest,
# stdlib-only imports — no server / no venv needed"). The ESCAPING tests are the
# one place that genuinely needs a real Jinja environment: asserting that
# hostile advisory text is escaped is only meaningful against the actual
# autoescape policy, not a hand-rolled stand-in. So jinja2 is imported softly —
# every parsing/contract test still runs on a bare interpreter, and the render
# tests skip there and run wherever the console's own venv exists (CI's bats
# job, the workstation, and the console host itself).
try:
    from jinja2 import Environment, FileSystemLoader, select_autoescape
    HAVE_JINJA = True
except ImportError:  # pragma: no cover — depends on the interpreter, not the code
    HAVE_JINJA = False

needs_jinja = pytest.mark.skipif(
    not HAVE_JINJA, reason="jinja2 is needed only for the render/escaping tests")

TEMPLATES = __import__("pathlib").Path(__file__).resolve().parent.parent / "templates"


# ---------------------------------------------------------------------------
# fixtures — real composer output shapes
# ---------------------------------------------------------------------------
AUDIT_JSON = json.dumps({
    "advisories": {
        "drupal/core": [
            {
                "advisoryId": "PKSA-2t4c-2xxx-1111",
                "packageName": "drupal/core",
                "affectedVersions": "<10.6.13 || >=11.3.0 <11.3.14",
                "title": "Drupal core - Moderately critical - Cross-site scripting - SA-CORE-2026-012",
                "cve": "CVE-2026-55805",
                "link": "https://www.drupal.org/sa-core-2026-012",
                "reportedAt": "2026-07-15T19:52:26+00:00",
                "sources": [{"name": "Drupal", "remoteId": "SA-CORE-2026-012"}],
                "severity": "medium",
            }
        ],
        "webonyx/graphql-php": [
            {
                "advisoryId": "PKSA-xwpn-zs9j-6wy5",
                "packageName": "webonyx/graphql-php",
                "affectedVersions": "<=15.32.2",
                "title": "unbounded recursion in parser",
                "cve": "NO CVE",
                "link": "https://github.com/advisories/GHSA-r7cg-qjjm-xhqq",
                "reportedAt": "2026-05-05T17:24:57+00:00",
                "sources": [],
                "severity": "high",
            }
        ],
    },
    "abandoned": {},
})

# What `pl audit` actually caches: composer's table, wrapped in the ddev/exec
# error blob, with the "Found N …" summaries hoisted to the top because they
# came from stderr.
AUDIT_TABLE = """Found 6 security vulnerability advisories affecting 2 packages:
Composer [audit --locked] failed: exit status 1, stdout='+-------------------+------------------+
| Package           | drupal/core                                                  |
| Severity          |                                                              |
| Advisory ID       | SA-CORE-2026-012                                             |
| CVE               | CVE-2026-55805                                               |
| Title             | Drupal core - Moderately critical - Cross-site scripting -   |
|                   | SA-CORE-2026-012                                             |
| URL               | https://www.drupal.org/sa-core-2026-012                      |
| Affected versions | <10.6.13 || >=11.3.0 <11.3.14                                |
| Reported at       | 2026-07-15T19:52:26+00:00                                    |
+-------------------+------------------+
+-------------------+------------------+
| Package           | webonyx/graphql-php                                          |
| Severity          | high                                                         |
| Advisory ID       | PKSA-xwpn-zs9j-6wy5                                          |
| CVE               | NO CVE                                                       |
| Title             | unbounded recursion in parser                                |
| URL               | https://github.com/advisories/GHSA-r7cg-qjjm-xhqq            |
| Affected versions | <=15.32.2                                                    |
| Reported at       | 2026-05-05T17:24:57+00:00                                    |
+-------------------+------------------+
'"""


def _record(**kw):
    rec = {
        "site": "avc", "checked": "2026-07-25T17:50:01Z",
        "security_count": 2, "ignored_count": 0, "cache_stale": False,
        "composer_audit_text": AUDIT_TABLE,
    }
    rec.update(kw)
    return rec


# ---------------------------------------------------------------------------
# parsing
# ---------------------------------------------------------------------------
def test_parses_composer_audit_json():
    advs = advisories.parse_composer_audit(AUDIT_JSON)
    assert len(advs) == 2
    core = [a for a in advs if a["package"] == "drupal/core"][0]
    # The upstream id (SA-CORE-…) is what an operator recognises; prefer it
    # over the packagist PKSA even though composer puts PKSA in advisoryId.
    assert core["id"] == "SA-CORE-2026-012"
    assert core["cve"] == "CVE-2026-55805"
    assert core["severity"] == "medium"
    assert core["reported_at"] == "2026-07-15T19:52:26+00:00"
    assert core["link"] == "https://www.drupal.org/sa-core-2026-012"
    assert core["affected"] == "<10.6.13 || >=11.3.0 <11.3.14"
    gql = [a for a in advs if a["package"] == "webonyx/graphql-php"][0]
    assert gql["cve"] == ""          # "NO CVE" is not a CVE id
    assert gql["id"] == "PKSA-xwpn-zs9j-6wy5"


def test_parses_composer_audit_table_including_wrapped_titles():
    advs = advisories.parse_composer_audit(AUDIT_TABLE)
    # Parsing preserves DOCUMENT order — split_ignored() depends on it. The
    # worst-first sort happens later, in site_block()/read_feed().
    assert [a["package"] for a in advs] == ["drupal/core", "webonyx/graphql-php"]
    core = [a for a in advs if a["package"] == "drupal/core"][0]
    # The Title column wraps onto a continuation line with an empty label.
    assert core["title"].endswith("Cross-site scripting - SA-CORE-2026-012")
    assert core["id"] == "SA-CORE-2026-012"
    assert core["severity"] == ""     # composer leaves drupal.org SAs unrated
    assert core["affected"] == "<10.6.13 || >=11.3.0 <11.3.14"   # '||' survives the split


def test_empty_and_malformed_input_never_raise():
    for payload in ("", None, "   ", "not json at all", "{", "[]", "{}",
                    '{"advisories": "nonsense"}', b"bytes"[:0].decode(), 12345,
                    {"advisories": None}, ["a", "b"]):
        assert advisories.parse_composer_audit(payload) == []


def test_clean_result_is_zero_advisories_not_an_error():
    advs = advisories.parse_composer_audit('{"advisories": {}, "abandoned": {}}')
    assert advs == []
    block = advisories.site_block(_record(security_count=0, composer_audit_text="No security vulnerability advisories found"))
    assert block["state"] == "ok"
    assert block["count"] == 0


def test_severity_ordering_puts_worst_first_then_newest():
    advs = advisories.sort_advisories([
        {"severity": "low", "reported_at": "2026-01-01", "package": "a", "id": "1"},
        {"severity": "critical", "reported_at": "2020-01-01", "package": "b", "id": "2"},
        {"severity": "high", "reported_at": "2026-01-01", "package": "c", "id": "3"},
        {"severity": "high", "reported_at": "2026-06-01", "package": "d", "id": "4"},
        {"severity": "", "reported_at": "2026-09-09", "package": "e", "id": "5"},
    ])
    assert [a["id"] for a in advs] == ["2", "4", "3", "1", "5"]


def test_unknown_severity_sorts_last_and_is_not_styled_as_mild():
    assert advisories.severity_rank("banana") > advisories.severity_rank("low")
    assert advisories.severity_class("banana") == "sev-unknown"
    assert advisories.severity_class("") == "sev-unknown"
    assert advisories.severity_class("CRITICAL") == "sev-critical"


# ---------------------------------------------------------------------------
# ignored-by-policy advisories
# ---------------------------------------------------------------------------
# composer emits the IGNORED table first, then the ACTIVE one, with no marker
# between them (the "Found …" summaries went to stderr). Here: 2 ignored across
# ONE package, then 1 active — asymmetric, so only one split satisfies both of
# composer's stated counts.
IGNORED_BLOB = """Found 2 ignored security vulnerability advisories affecting 1 packages:
Found 1 security vulnerability advisories affecting 1 packages:
| Package           | drupal/ginvite   |
| Severity          | low              |
| Advisory ID       | SA-CONTRIB-2026-001 |
| URL               | https://www.drupal.org/sa-contrib-2026-001 |
+---+
| Package           | drupal/ginvite   |
| Severity          | low              |
| Advisory ID       | SA-CONTRIB-2026-002 |
| URL               | https://www.drupal.org/sa-contrib-2026-002 |
+---+
| Package           | drupal/core      |
| Severity          | medium           |
| Advisory ID       | SA-CORE-2026-012 |
| URL               | https://www.drupal.org/sa-core-2026-012 |
+---+
"""


def test_ignored_advisories_are_separated_when_the_counts_verify():
    block = advisories.site_block(
        _record(security_count=1, ignored_count=2, composer_audit_text=IGNORED_BLOB))
    assert [a["package"] for a in block["advisories"]] == ["drupal/core"]
    assert [a["id"] for a in block["ignored_advisories"]] == \
        ["SA-CONTRIB-2026-001", "SA-CONTRIB-2026-002"]
    assert all(a["ignored"] for a in block["ignored_advisories"])
    assert block["note"] == ""


def test_unverifiable_ignored_split_labels_nothing_and_says_so():
    # Counts that do not add up must NOT be guessed at: mislabelling a live
    # advisory as "ignored by policy" is the worst failure this pane could have.
    bad = IGNORED_BLOB.replace("Found 2 ignored", "Found 5 ignored")
    active, ignored, note = advisories.split_ignored(
        advisories.parse_composer_audit(bad), bad)
    assert len(active) == 3 and ignored == []
    assert "could not be split" in note


def test_ambiguous_ignored_split_is_refused():
    # 1 ignored + 1 active, one advisory each, one package each: both orderings
    # satisfy the checksum, so neither may be used.
    blob = ("Found 1 ignored security vulnerability advisories affecting 1 packages:\n"
            "Found 1 security vulnerability advisories affecting 1 packages:\n"
            "| Package | a/one |\n+---+\n| Package | b/two |\n+---+\n")
    active, ignored, note = advisories.split_ignored(
        advisories.parse_composer_audit(blob), blob)
    assert len(active) == 2 and ignored == []
    assert "ambiguous" in note


# ---------------------------------------------------------------------------
# per-site state honesty
# ---------------------------------------------------------------------------
def test_moodle_site_is_na_not_clean():
    block = advisories.site_block({
        "site": "ss", "platform": "moodle", "security_count": 0,
        "moodle_installed": "4.5.2", "moodle_latest": "4.5.3", "moodle_branch": "405",
        "note": "Behind the latest point release",
    })
    assert block["state"] == "n/a"
    assert block["moodle"]["latest"] == "4.5.3"
    assert block["advisories"] == []


def test_recorded_count_without_parsable_output_is_unreadable_not_zero():
    block = advisories.site_block(_record(security_count=7, composer_audit_text="???"))
    assert block["state"] == "unreadable"
    assert block["count"] == 7          # the number we DO know is kept
    assert "could not be parsed" in block["note"]


def test_registry_auth_failure_marks_the_list_incomplete():
    block = advisories.site_block(_record(cache_stale=True))
    assert block["state"] == "stale"
    assert "may be incomplete" in block["note"]


def test_site_with_no_record_is_reported_missing(tmp_path):
    feed = advisories.build_feed(tmp_path, sites=["ghost"])
    assert feed["sites"][0]["state"] == "missing"
    assert "pl audit --site ghost" in feed["sites"][0]["note"]
    assert feed["totals"]["sites_unknown"] == 1


def test_corrupt_record_file_does_not_break_the_feed(tmp_path):
    (tmp_path / "good.json").write_text(json.dumps(_record(site="good")))
    (tmp_path / "bad.json").write_text("{ not json")
    feed = advisories.build_feed(tmp_path)
    states = {b["site"]: b["state"] for b in feed["sites"]}
    assert states["good"] == "ok"
    assert states["bad"] == "unreadable"


def test_installed_version_comes_from_composer_lock(tmp_path):
    root = tmp_path / "root"
    (root / "sites" / "avc" / "dev").mkdir(parents=True)
    (root / "sites" / "avc" / "dev" / "composer.lock").write_text(json.dumps(
        {"packages": [{"name": "drupal/core", "version": "10.6.12"}]}))
    block = advisories.site_block(_record(), root=root)
    core = [a for a in block["advisories"] if a["package"] == "drupal/core"][0]
    assert core["installed"] == "10.6.12"


def test_missing_composer_lock_leaves_installed_blank_not_wrong(tmp_path):
    block = advisories.site_block(_record(), root=tmp_path)
    assert all(a["installed"] == "" for a in block["advisories"])


# ---------------------------------------------------------------------------
# the round trip the publish pipe actually performs
# ---------------------------------------------------------------------------
def test_build_feed_read_feed_round_trip(tmp_path):
    (tmp_path / "avc.json").write_text(json.dumps(_record()))
    (tmp_path / "ss.json").write_text(json.dumps(
        {"site": "ss", "platform": "moodle", "security_count": 0}))
    feed = advisories.build_feed(tmp_path, now="2026-07-26T03:00:00Z")
    # exactly what fleet.sh ships and fleet_state.as_result hands back
    view = parsers.parse_security(json.dumps(feed))
    assert view["ok"]
    assert view["totals"]["advisories"] == 2
    assert view["totals"]["sites_affected"] == 1
    assert view["totals"]["worst"] == "high"
    avc = advisories.by_site(view)["avc"]
    assert avc["anchor"] == "sec-avc"
    assert [b["site"] for b in advisories.affected_sites(view)] == ["avc"]
    assert advisories.audit_window(view)[0] == "2026-07-25T17:50:01Z"


def test_headline_is_honest_in_every_state():
    assert advisories.headline({"ok": False}) == "no security data in this snapshot"
    clean = {"ok": True, "sites": [], "totals": advisories.totals(
        [{"state": "ok", "count": 0, "advisories": []}])}
    assert "no open advisories" in advisories.headline(clean)
    mixed = {"ok": True, "sites": [], "totals": advisories.totals([
        {"state": "ok", "count": 2, "advisories": [{"severity": "high"}, {"severity": "low"}]},
        {"state": "missing", "count": 0, "advisories": []},
    ])}
    assert advisories.headline(mixed) == "2 advisories on 1 site, 1 site(s) unknown"


# ---------------------------------------------------------------------------
# degradation: a snapshot with no security feed
# ---------------------------------------------------------------------------
def test_absent_feed_reads_as_no_data_not_as_zero():
    view = advisories.read_feed(None)
    assert view["ok"] is False
    assert view["totals"]["advisories"] == 0
    assert advisories.headline(view) == "no security data in this snapshot"
    assert advisories.affected_sites(view) == []
    assert advisories.by_site(view) == {}


@pytest.mark.parametrize("payload", ["", "garbage", "[]", '{"nope": 1}', 42, [1, 2]])
def test_unreadable_feed_degrades_without_raising(payload):
    view = advisories.read_feed(payload)
    assert view["ok"] is False and view["sites"] == []


def test_parse_security_on_empty_stdout():
    view = parsers.parse_security("")
    assert view["ok"] is False
    assert "no JSON found" in view["error"]


@needs_jinja
def test_old_snapshot_without_security_feed_still_yields_a_pane():
    """A snapshot published before this feature existed has no security feed;
    fleet_state.as_result returns None and the pane must still render."""
    from app import fleet_state
    snap = {"schema": "nwp.fleet-state", "schema_version": 1,
            "generated_at": "2026-07-26T03:00:00Z", "feeds": {"rag": {"ok": True, "data": {}}}}
    assert fleet_state.as_result(snap, "security") is None
    view = advisories.read_feed(None)
    html = _render(view)
    assert "No security data in this snapshot" in html
    assert "0 advisories" not in html


# ---------------------------------------------------------------------------
# XSS — advisory text is third-party and ends up in the DOM
# ---------------------------------------------------------------------------
def _render(view: dict) -> str:
    env = Environment(loader=FileSystemLoader(str(TEMPLATES)),
                      autoescape=select_autoescape(["html"]))
    af, at = advisories.audit_window(view)
    return env.get_template("_security.html").render(
        sec=view, sec_headline=advisories.headline(view),
        sec_sites=advisories.affected_sites(view), sec_audit_from=af, sec_audit_to=at)


HOSTILE = {
    "advisories": {
        "<img src=x onerror=alert(1)>": [{
            "advisoryId": "</dd><script>alert('id')</script>",
            "affectedVersions": "<10.0 & >=9.0 \"quoted\"",
            "title": "<script>alert('title')</script> & <b>bold</b>",
            "cve": "CVE-<script>1</script>",
            "link": "javascript:alert(document.cookie)",
            "reportedAt": "2026-01-01T00:00:00+00:00",
            "severity": "<script>high</script>",
        }],
    }
}


@needs_jinja
def test_hostile_advisory_text_is_escaped_in_the_rendered_pane(tmp_path):
    (tmp_path / "evil.json").write_text(json.dumps({
        "site": "evil", "checked": "2026-07-25T00:00:00Z", "security_count": 1,
        "composer_audit_json": HOSTILE,
    }))
    view = parsers.parse_security(json.dumps(advisories.build_feed(tmp_path)))
    html = _render(view)
    # Not one character of the payload survives as markup: no injected tag, no
    # attribute boundary broken. It is all still VISIBLE, just inert text.
    assert "<script>" not in html
    assert "<img" not in html
    assert "</dd><script" not in html
    assert "&lt;script&gt;" in html          # it IS shown, just inert
    assert "&lt;img src=x onerror=alert(1)&gt;" in html
    assert "&amp;" in html                   # bare & escaped too
    assert "&#34;" in html or "&quot;" in html   # the quote in affectedVersions


def test_javascript_and_data_urls_never_become_an_href():
    for bad in ("javascript:alert(1)", "JavaScript:alert(1)", "data:text/html,<script>",
                "vbscript:x", "  javascript:alert(1)", "//evil.example/x",
                "https://ok.example/a\" onmouseover=\"alert(1)", "file:///etc/passwd", "", None):
        assert advisories.safe_link(bad) == ""
    assert advisories.safe_link("https://www.drupal.org/sa-core-2026-012") == \
        "https://www.drupal.org/sa-core-2026-012"
    assert advisories.safe_link("http://example.org/x") == "http://example.org/x"


@needs_jinja
def test_advisory_without_a_usable_link_renders_no_anchor(tmp_path):
    (tmp_path / "x.json").write_text(json.dumps({
        "site": "x", "security_count": 1,
        "composer_audit_json": {"advisories": {"a/b": [
            {"advisoryId": "X-1", "title": "t", "link": "javascript:alert(1)", "severity": "high"}]}},
    }))
    view = parsers.parse_security(json.dumps(advisories.build_feed(tmp_path)))
    html = _render(view)
    assert "javascript:" not in html
    assert "no usable advisory link" in html


def test_control_characters_and_ansi_are_stripped():
    dirty = advisories.clean("\x1b[31mred\x1b[0m\x00\x07 text\nwrapped")
    assert dirty == "red text wrapped"
    assert "\x1b" not in dirty and "\x00" not in dirty


def test_absurdly_long_fields_are_bounded():
    long_title = "A" * 50_000
    advs = advisories.parse_composer_audit(json.dumps(
        {"advisories": {"a/b": [{"advisoryId": "X", "title": long_title}]}}))
    assert len(advs[0]["title"]) <= 400


@needs_jinja
def test_rendered_detail_shows_every_field_the_operator_asked_for(tmp_path):
    root = tmp_path / "root"
    (root / "sites" / "avc" / "dev").mkdir(parents=True)
    (root / "sites" / "avc" / "dev" / "composer.lock").write_text(json.dumps(
        {"packages": [{"name": "drupal/core", "version": "10.6.12"}]}))
    (root / "rec").mkdir()
    (root / "rec" / "avc.json").write_text(json.dumps(_record(composer_audit_json=json.loads(AUDIT_JSON))))
    view = parsers.parse_security(json.dumps(
        advisories.build_feed(root / "rec", root=root)))
    html = _render(view)
    for expected in ("SA-CORE-2026-012",                    # advisory id
                     "CVE-2026-55805",                      # CVE
                     "drupal/core",                         # package
                     "10.6.12",                             # installed version
                     "&lt;10.6.13 || &gt;=11.3.0",          # affected constraint
                     "Cross-site scripting",                # title
                     "medium",                              # severity
                     "2026-07-15T19:52:26+00:00",           # reported date
                     'href="https://www.drupal.org/sa-core-2026-012"',   # link
                     'target="_blank"', 'rel="noopener noreferrer"'):
        assert expected in html, expected


# ---------------------------------------------------------------------------
# non-composer platforms: Moodle ships security fixes only in the newest point
# release, so "behind" IS the advisory. `pl rag` turns such a site RED — the
# pane must not be silent about it just because there is no CVE to list.
# ---------------------------------------------------------------------------
def _moodle(count):
    return {"site": "ss", "platform": "moodle", "security_count": count,
            "checked": "2026-07-25T17:50:01Z",
            "moodle_installed": "4.5.2", "moodle_latest": "4.5.3", "moodle_branch": "405",
            "note": "Behind the latest point release on this branch"}


@needs_jinja
def test_moodle_behind_a_point_release_is_surfaced_not_swallowed(tmp_path):
    (tmp_path / "ss.json").write_text(json.dumps(_moodle(1)))
    view = parsers.parse_security(json.dumps(advisories.build_feed(tmp_path)))
    assert view["totals"]["platform_alerts"] == 1
    assert view["totals"]["advisories"] == 0, "a point release is not a CVE count"
    assert [b["site"] for b in advisories.affected_sites(view)] == ["ss"]
    assert "behind on platform security releases" in advisories.headline(view)
    html = _render(view)
    assert "4.5.2" in html and "4.5.3" in html
    assert "moodle.org/security" in html


def test_moodle_up_to_date_is_not_listed_at_all(tmp_path):
    (tmp_path / "ss.json").write_text(json.dumps(_moodle(0)))
    view = parsers.parse_security(json.dumps(advisories.build_feed(tmp_path)))
    assert advisories.affected_sites(view) == []
    assert view["totals"]["platform_alerts"] == 0
    assert "no open advisories" in advisories.headline(view)
