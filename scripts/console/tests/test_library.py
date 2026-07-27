"""Stage 4 — the docs Library, in two versions.

Every test here asserts that the WRONG answer is REFUSAL. The feature's worst
possible output is a false "public": a doc that reaches the public bundle while
still carrying the operator's home path, personal email or prod IP. So the
build refuses on:

  * a doc the identity checker called dirty,
  * a doc the identity checker COULD NOT CHECK (verdict absent == unknown),
  * a doc naming a site outside its audience's project set,
  * a `contributor` doc naming ANY site (that shard is cross-project),
  * an empty site vocabulary (a scan that knows no site names cannot find one).

NEGATIVE CONTROLS, because "refuse everything" would pass all of the above:
  * test_clean_corpus_builds — a correct manifest builds and IS public,
  * test_public_bundle_contains_the_public_doc — the artefact is not empty,
  * test_detector_finds_a_planted_token — the site scanner actually scans.

Operator identifiers are assembled from fragments at runtime (`"/home/" +
"rob"`), never written as literals, so this file does not itself become a leak
the repo's own gitleaks gate has to suppress.
"""
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import library as lib  # noqa: E402
from app.scope import Scope  # noqa: E402

REPO = Path(__file__).resolve().parents[3]

VOCAB = ["nwc", "nwd", "ss", "ss2", "ssc", "ssd", "saintschool", "dir", "dir1", "avc"]

# Assembled, never literal — see the module docstring.
OPERATOR_HOME = "/home/" + "rob" + "/nwp/lib/common.sh"
OPERATOR_HOST = "nwc." + "nwpcode" + ".org"

MANIFEST = """
schema: nwp.library-manifest
schema_version: 1
public_sites: [ss, nwc]

docs:
  - path: docs/overview/README.md
    title: Overview
    audience: public
    summary: what all of this is
    sites: [ss, nwc]
  - path: docs/guides/howto-console.md
    title: Using the console
    audience: contributor
    summary: no site names allowed here
  - path: docs/guides/howto-demo-tier.md
    title: The demo tier
    audience: project-ss-nw
    sites: [nwd, ssd]
  - path: docs/guides/howto-deploy.md
    title: Deploying
    audience: private
"""

FILES = {
    "docs/overview/README.md": "# Overview\n\nss and nwc are the two member sites.\n",
    "docs/guides/howto-console.md": "# Console\n\nA guide with no site names in it at all.\n",
    "docs/guides/howto-demo-tier.md": "# Demo\n\nnwd resets nightly; ssd is its pair.\n",
    "docs/guides/howto-deploy.md": f"# Deploy\n\nRun it from {OPERATOR_HOME} on the box.\n",
    "docs/guides/howto-dr-chain.md": "# DR\n\nNot in the manifest at all.\n",
}

CLEAN_VERDICTS = {p: "clean" for p in FILES}


def _build(manifest_text=MANIFEST, files=None, vocab=None, verdicts=None):
    return lib.build(
        lib.parse_manifest(manifest_text),
        dict(FILES if files is None else files),
        VOCAB if vocab is None else vocab,
        dict(CLEAN_VERDICTS if verdicts is None else verdicts),
        {"host": "workstation"},
        now=datetime(2026, 7, 27, 9, 0, tzinfo=timezone.utc),
    )


# ---------------------------------------------------------------------------
# L1 — manifest parsing is strict, and unreadable means REFUSE
# ---------------------------------------------------------------------------
def test_manifest_parses():
    m = lib.parse_manifest(MANIFEST)
    assert m["schema"] == "nwp.library-manifest"
    assert m["public_sites"] == ["ss", "nwc"]
    assert len(m["docs"]) == 4
    assert m["docs"][0]["audience"] == "public"
    assert m["docs"][2]["sites"] == ["nwd", "ssd"]
    assert "sites" not in m["docs"][1]


@pytest.mark.parametrize("bad", [
    "schema: nwp.library-manifest\nschema_version: 1\ndocs:\n  - path: a.md\n    audience: public\n    secret_flag: yes\n",
    "schema: nwp.library-manifest\nschema_version: 1\nrogue_key: 1\n",
    "schema: nwp.library-manifest\nschema_version: 1\ndocs:\n\tpath: a.md\n",
    "schema: nwp.library-manifest\nschema_version: 9\n",
    "schema: something.else\nschema_version: 1\n",
    "schema: nwp.library-manifest\nschema_version: 1\ndocs:\n    path: orphan.md\n",
    "schema: nwp.library-manifest\nschema_version: 1\npublic_sites: \"ss\"\n",
])
def test_manifest_refuses_what_it_does_not_understand(bad):
    """A permissive parser could drop an `audience:` line and leave the doc on a
    default — and one of the defaults in this module is a publication decision."""
    with pytest.raises(lib.ManifestError):
        lib.parse_manifest(bad)


# ---------------------------------------------------------------------------
# L2 — classification is fail-closed
# ---------------------------------------------------------------------------
def test_unmanifested_doc_is_private():
    full, pub = _build()
    dr = [d for d in full["docs"] if d["id"] == "guides.howto-dr-chain"][0]
    assert dr["audience"] == "private"
    assert dr["unmanifested"] is True
    assert "guides.howto-dr-chain" not in [d["id"] for d in pub["docs"]]


def test_unknown_audience_refuses_the_build():
    bad = MANIFEST.replace("audience: public", "audience: everyone")
    with pytest.raises(lib.BuildRefused) as e:
        _build(bad)
    assert any("unknown audience" in r for r in e.value.reasons)


# ---------------------------------------------------------------------------
# L3 — THE load-bearing test: a planted operator identifier refuses the build
# ---------------------------------------------------------------------------
def test_planted_identifier_in_a_public_doc_refuses_the_build():
    """The checker (tests/helpers/pubrel-docs-check.sh, via `pl library build`)
    returns `dirty` for this file. The builder must refuse the WHOLE build —
    not demote the doc, not warn: the operator said public and was wrong."""
    files = dict(FILES)
    files["docs/overview/README.md"] += f"\nDeployed from {OPERATOR_HOME}.\n"
    verdicts = dict(CLEAN_VERDICTS, **{"docs/overview/README.md": "dirty"})
    with pytest.raises(lib.BuildRefused) as e:
        _build(files=files, verdicts=verdicts)
    assert any("not certified clean" in r for r in e.value.reasons)


def test_uncheckable_public_doc_refuses_the_build():
    """`unknown` is what the checker returns when it COULD NOT SCAN (gitleaks
    missing, scanner error, unparseable report). It must never publish."""
    verdicts = dict(CLEAN_VERDICTS)
    verdicts.pop("docs/overview/README.md")
    with pytest.raises(lib.BuildRefused) as e:
        _build(verdicts=verdicts)
    assert any("'unknown'" in r for r in e.value.reasons)

    verdicts["docs/overview/README.md"] = "unknown"
    with pytest.raises(lib.BuildRefused):
        _build(verdicts=verdicts)


def test_uncheckable_contributor_doc_also_refuses_the_build():
    """`contributor` crosses the tenancy boundary too — every authenticated user
    in every project reads it — so it needs the same certificate `public` does."""
    verdicts = dict(CLEAN_VERDICTS)
    verdicts["docs/guides/howto-console.md"] = "unknown"
    with pytest.raises(lib.BuildRefused) as e:
        _build(verdicts=verdicts)
    assert any("howto-console.md" in r and "not certified clean" in r for r in e.value.reasons)


def test_private_and_project_docs_do_not_need_an_identity_verdict():
    """NEGATIVE CONTROL for the rule above: it must be a boundary rule, not a
    blanket one, or every operator runbook becomes unpublishable to the people
    who operate it."""
    verdicts = {"docs/overview/README.md": "clean", "docs/guides/howto-console.md": "clean"}
    full, _pub = _build(verdicts=verdicts)          # demo-tier + deploy have NO verdict
    assert {d["audience"] for d in full["docs"]} == {
        "public", "contributor", "project-ss-nw", "private"}


def test_public_doc_may_not_name_a_site_outside_the_public_allowlist():
    files = dict(FILES)
    files["docs/overview/README.md"] += "\nThe ssd demo pair resets nightly.\n"
    manifest = MANIFEST.replace("    sites: [ss, nwc]", "    sites: [ss, nwc, ssd]")
    with pytest.raises(lib.BuildRefused) as e:
        _build(manifest, files=files)
    assert any("public_sites" in r for r in e.value.reasons)


def test_public_doc_may_not_name_an_undeclared_site():
    files = dict(FILES)
    files["docs/overview/README.md"] += "\nAlso see nwd.\n"
    with pytest.raises(lib.BuildRefused) as e:
        _build(files=files)
    assert any("does not\ndeclare" in r.replace("does not declare", "does not\ndeclare")
               for r in e.value.reasons)


# ---------------------------------------------------------------------------
# L4 — cross-project leakage via docs (stage-1 gate check L14)
# ---------------------------------------------------------------------------
def test_contributor_doc_may_name_no_site():
    """`contributor` is visible to EVERY authenticated user in EVERY project, so
    one site name in one contributor doc is a cross-project disclosure."""
    files = dict(FILES)
    files["docs/guides/howto-console.md"] += "\nTry it on ssc first.\n"
    with pytest.raises(lib.BuildRefused) as e:
        _build(files=files)
    assert any("may name NO site" in r for r in e.value.reasons)


def test_contributor_doc_may_not_even_declare_a_site():
    manifest = MANIFEST.replace(
        "    summary: no site names allowed here",
        "    summary: no site names allowed here\n    sites: [nwc]")
    with pytest.raises(lib.BuildRefused) as e:
        _build(manifest)
    assert any("may name NO site" in r for r in e.value.reasons)


def test_project_doc_may_not_name_an_undeclared_site():
    files = dict(FILES)
    files["docs/guides/howto-demo-tier.md"] += "\nCompare with avc.\n"
    with pytest.raises(lib.BuildRefused) as e:
        _build(files=files)
    assert any("avc" in r for r in e.value.reasons)


def test_empty_site_vocabulary_refuses_the_build():
    """NEGATIVE CONTROL for the scanner itself: with no vocabulary every doc
    would scan as 'names no site', which is 0-is-not-a-clean-bill-of-health."""
    with pytest.raises(lib.BuildRefused) as e:
        _build(vocab=[])
    assert any("no site vocabulary" in r for r in e.value.reasons)


def test_detector_finds_a_planted_token():
    """NEGATIVE CONTROL: the site scanner is not vacuous, and its boundaries
    are the ones the real fleet needs (ss vs ss2 vs ssc, dir vs dir1)."""
    assert lib.site_tokens_in("we deploy ssc nightly", VOCAB) == ["ssc"]
    assert lib.site_tokens_in(f"see {OPERATOR_HOST}", VOCAB) == ["nwc"]
    assert lib.site_tokens_in("ss2 only", VOCAB) == ["ss2"]
    assert lib.site_tokens_in("the ss-nw project", VOCAB) == []
    assert lib.site_tokens_in("dir1 is not dir", VOCAB) == ["dir", "dir1"]
    assert lib.site_tokens_in("a classless directory", VOCAB) == []


# ---------------------------------------------------------------------------
# L5 — NEGATIVE CONTROLS: the happy path actually happens
# ---------------------------------------------------------------------------
def test_clean_corpus_builds():
    full, pub = _build()
    assert {d["id"] for d in full["docs"]} == {
        "overview.readme", "guides.howto-console", "guides.howto-demo-tier",
        "guides.howto-deploy", "guides.howto-dr-chain"}
    assert full["variant"] == "full"
    assert full["generated_by"]["host"] == "workstation"


def test_public_bundle_contains_the_public_doc_and_nothing_else():
    _full, pub = _build()
    assert [d["id"] for d in pub["docs"]] == ["overview.readme"]
    assert pub["variant"] == "public"
    blob = json.dumps(pub)
    assert OPERATOR_HOME not in blob            # the private doc's body is absent
    assert "howto-deploy" not in blob


# ---------------------------------------------------------------------------
# L6 — render-time gate. The bundle is an input, the Scope is the authority.
# ---------------------------------------------------------------------------
def _scope(role="viewer", pid="ss-nw", sites=("nwc", "nwd", "ssd", "ss"), memberships=None,
           all_sites=False, project_role="viewer"):
    return Scope(user="dana", global_role=role, project_id=pid, project_role=project_role,
                 sites=frozenset(sites), all_sites=all_sites,
                 memberships=tuple(memberships if memberships is not None
                                   else ((pid, "Saint School + NW"),)))


def test_member_sees_public_contributor_and_their_own_project():
    full, _pub = _build()
    rows, dropped = lib.visible_docs(full, _scope())
    assert [r["id"] for r in rows] == [
        "overview.readme", "guides.howto-console", "guides.howto-demo-tier"]
    assert dropped == 2                            # the two private docs
    assert all("text" not in r for r in rows)      # index ships no bodies


def test_private_docs_are_owner_only():
    full, _pub = _build()
    member_ids = {r["id"] for r in lib.visible_docs(full, _scope())[0]}
    assert "guides.howto-deploy" not in member_ids
    owner = _scope(role="owner", project_role="maintainer")
    assert "guides.howto-deploy" in {r["id"] for r in lib.visible_docs(full, owner)[0]}


def test_member_of_another_project_never_sees_a_project_doc():
    full, _pub = _build()
    other = _scope(pid="personal", sites=("avc", "dir", "dir1"),
                   memberships=(("personal", "Operator's own"),))
    ids = {r["id"] for r in lib.visible_docs(full, other)[0]}
    assert ids == {"overview.readme", "guides.howto-console"}
    assert lib.get_doc(full, other, "guides.howto-demo-tier") is None


def test_project_doc_is_dropped_when_the_manifest_has_drifted_from_users_json():
    """The manifest lives in the repo on the workstation; the project->sites map
    lives in users.json on the console host. Two authors, so they can drift —
    and a drifted tenancy map is a disclosure. Render-time re-checks."""
    full, _pub = _build()
    narrowed = _scope(sites=("nwc", "ss"))         # ssd/nwd removed from the project
    ids = {r["id"] for r in lib.visible_docs(full, narrowed)[0]}
    assert "guides.howto-demo-tier" not in ids
    assert lib.get_doc(full, narrowed, "guides.howto-demo-tier") is None


def test_hand_edited_contributor_doc_naming_a_site_is_dropped_at_render_time():
    """Belt to the builder's braces: an older or hand-edited bundle must not be
    able to smuggle a site name into the cross-project shard."""
    full, _pub = _build()
    for d in full["docs"]:
        if d["id"] == "guides.howto-console":
            d["sites"] = ["ssc"]
    ids = {r["id"] for r in lib.visible_docs(full, _scope())[0]}
    assert "guides.howto-console" not in ids


def test_scope_with_no_project_sees_nothing():
    full, _pub = _build()
    nobody = Scope(user="new", global_role="viewer", project_id=None, project_role=None)
    rows, _dropped = lib.visible_docs(full, nobody)
    assert rows == []
    assert lib.get_doc(full, nobody, "overview.readme") is None


def test_get_doc_refuses_a_malformed_id_and_never_confirms_existence():
    full, _pub = _build()
    sc = _scope()
    assert lib.get_doc(full, sc, "../../etc/passwd") is None
    assert lib.get_doc(full, sc, "guides/howto-deploy") is None
    assert lib.get_doc(full, sc, "guides.howto-deploy") is None   # exists, not yours
    assert lib.get_doc(full, sc, "overview.readme")["id"] == "overview.readme"


def test_public_bundle_is_visible_to_any_member():
    _full, pub = _build()
    rows, dropped = lib.visible_docs(pub, _scope())
    assert [r["id"] for r in rows] == ["overview.readme"]
    assert dropped == 0


# ---------------------------------------------------------------------------
# L7 — provenance uses the fleet idiom, and staleness is loud
# ---------------------------------------------------------------------------
def test_provenance_marks_a_stale_bundle():
    full, _pub = _build()
    now = datetime(2026, 8, 27, 9, 0, tzinfo=timezone.utc)      # a month later
    prov = lib.provenance(full, max_age=7 * 86400, now=now)
    assert prov["source"] == "published"
    assert prov["stale"] is True
    assert prov["host"] == "workstation"
    assert prov["max_age_human"] == "7 days"


def test_provenance_of_a_missing_bundle_is_not_a_clean_bill_of_health():
    prov = lib.provenance(None, max_age=7 * 86400)
    assert prov["source"] == "local"
    assert prov["snapshot_present"] is False
    assert "no published library" in prov["note"]


def test_load_bundle_refuses_foreign_or_corrupt_files(tmp_path):
    p = tmp_path / "library.json"
    p.write_text("{not json")
    assert lib.load_bundle(p) is None
    p.write_text(json.dumps({"schema": "something.else", "schema_version": 1, "docs": []}))
    assert lib.load_bundle(p) is None
    p.write_text(json.dumps({"schema": lib.SCHEMA, "schema_version": 99, "docs": []}))
    assert lib.load_bundle(p) is None
    p.write_text(json.dumps({"schema": lib.SCHEMA, "schema_version": 1, "docs": "nope"}))
    assert lib.load_bundle(p) is None
    assert lib.load_bundle(tmp_path / "absent.json") is None
    p.write_text(json.dumps({"schema": lib.SCHEMA, "schema_version": 1, "docs": []}))
    assert lib.load_bundle(p) == {"schema": lib.SCHEMA, "schema_version": 1, "docs": []}


# ---------------------------------------------------------------------------
# L8 — the renderer. Escape first, allowlist after.
# ---------------------------------------------------------------------------
def test_renderer_escapes_html_and_neuters_hostile_links():
    md = ('<script>alert(1)</script>\n\n'
          '[click](javascript:alert(1))\n\n'
          '[ok](https://example.org/x)\n')
    out = lib.render_markdown(md)
    assert "<script>" not in out
    assert "&lt;script&gt;" in out
    assert "javascript:" not in out
    assert 'href="https://example.org/x"' in out
    assert ">click<" not in out and "click" in out       # rendered as plain text


def test_renderer_handles_the_shapes_the_corpus_uses():
    md = ("# Title\n\n"
          "Some **bold** and `code`.\n\n"
          "| a | b |\n|---|---|\n| 1 | 2 |\n\n"
          "- one\n- two\n\n"
          "1. first\n\n"
          "> quoted\n\n"
          "```bash\npl library publish\n```\n")
    out = lib.render_markdown(md)
    assert "<h2>Title</h2>" in out            # h1 is the page's, not the doc's
    assert "<strong>bold</strong>" in out
    assert "<code>code</code>" in out
    assert "<table" in out and "<th>a</th>" in out
    assert "<ul><li>one</li><li>two</li></ul>" in out
    assert "<ol><li>first</li></ol>" in out
    assert "<blockquote>quoted</blockquote>" in out
    assert "<pre><code" in out and "pl library publish" in out


def test_internal_links_only_resolve_to_docs_the_reader_may_see():
    """A dead link is bad; a live link to a doc you may not read is worse, and a
    404 that only fires for docs that exist is an existence oracle."""
    full, _pub = _build()
    rows, _ = lib.visible_docs(full, _scope())
    doc = lib.get_doc(full, _scope(), "overview.readme")
    resolve = lib.link_resolver_for(doc, rows)
    assert resolve("../guides/howto-console.md") == "/library/doc/guides.howto-console"
    assert resolve("../guides/howto-deploy.md") is None          # private
    out = lib.render_markdown("see [the console guide](../guides/howto-console.md) and "
                              "[deploying](../guides/howto-deploy.md)", resolve)
    assert 'href="/library/doc/guides.howto-console"' in out
    assert "howto-deploy" not in out


# ---------------------------------------------------------------------------
# L9 — the REAL corpus and the REAL manifest in this repo
# ---------------------------------------------------------------------------
def test_repo_manifest_is_parseable_and_covers_the_corpus():
    mf = REPO / "docs/library-manifest.yml"
    manifest = lib.parse_manifest(mf.read_text())
    declared = {d["path"] for d in manifest["docs"]}
    corpus = sorted([str(p.relative_to(REPO)) for p in (REPO / "docs/overview").glob("*.md")] +
                    [str(p.relative_to(REPO)) for p in (REPO / "docs/guides").glob("howto-*.md")])
    assert corpus, "the corpus glob found nothing — the test would be vacuous"
    missing = [p for p in corpus if p not in declared]
    assert not missing, f"corpus docs missing from the manifest (they default to private): {missing}"
    ghosts = [p for p in declared if not (REPO / p).is_file()]
    assert not ghosts, f"manifest names docs that do not exist: {ghosts}"


def test_repo_corpus_builds_and_the_public_half_is_identity_clean():
    """The full end-to-end shape, using the repo's real docs. The identity
    verdicts come from the bash checker in the `pl library build` path; here we
    assert the structural half (site scoping) on the real text, which is the
    part this module owns."""
    mf = REPO / "docs/library-manifest.yml"
    manifest = lib.parse_manifest(mf.read_text())
    files = {}
    for d in manifest["docs"]:
        files[d["path"]] = (REPO / d["path"]).read_text()
    verdicts = {p: "clean" for p in files}
    full, pub = lib.build(manifest, files, VOCAB + ["ss1", "nwt", "nw1", "mt", "ba"],
                          verdicts, {"host": "test"})
    assert full["docs"], "no docs built"
    for d in pub["docs"]:
        assert d["audience"] == "public"
        for s in d["named_sites"]:
            assert s in manifest["public_sites"], f"{d['path']} names {s}"
    for d in full["docs"]:
        if d["audience"] == "contributor":
            assert not d["named_sites"], f"{d['path']} is contributor and names {d['named_sites']}"
