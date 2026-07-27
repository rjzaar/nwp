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
import os
import shutil
import subprocess
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


def test_vocabulary_must_cover_what_the_manifest_itself_names():
    """The check that used to pass without checking.

    Built from a git worktree — no nwp.yml, one directory under sites/ — the
    vocabulary resolver returned exactly ONE site name. The build passed every
    cross-project rule while being blind to eleven sites. "Vocabulary is not
    empty" was not the same property as "vocabulary is usable"."""
    with pytest.raises(lib.BuildRefused) as e:
        _build(vocab=["ss"])
    assert any("vocabulary is missing" in r for r in e.value.reasons)
    reason = [r for r in e.value.reasons if "vocabulary is missing" in r][0]
    for expected in ("nwc", "nwd", "ssd"):
        assert expected in reason


# ---------------------------------------------------------------------------
# L10 — END TO END through the REAL identity checker (`pl library build`)
# ---------------------------------------------------------------------------
# These drive scripts/commands/library.sh, which sources
# tests/helpers/pubrel-docs-check.sh. That is where the six identity rules and
# the fail-closed gitleaks discipline actually live; everything above this line
# simulates its verdicts.
E2E_VOCAB = "ss,ss1,ss2,ssc,ssd,saintschool,nwc,nwd,nwt,nw1,nw2,dir,dir1,avc,mt,cathnet,ba,mayo"


@pytest.fixture
def gitleaks():
    """Resolve the scanner, and FAIL the test if we cannot.

    Deliberately not a `skip`. pytest reports a skip as a pass, and these are
    the tests that decide whether a public docs release is authorised. "We could
    not check" reading as "checked and clean" is the exact defect the checker
    under test was written to close; it must not be reintroduced by the test
    harness. Same rule as tests/unit/test-pubrel-docs-genericised.bats.
    """
    for cand in (os.environ.get("NWP_GITLEAKS_BIN"), os.environ.get("GITLEAKS_BIN"),
                 shutil.which("gitleaks"),
                 str(Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
                     / "nwp/gitleaks-8.30.0/gitleaks")):
        if cand and Path(cand).is_file() and os.access(cand, os.X_OK):
            return cand
    pytest.fail("no usable gitleaks binary — cannot verify the public tier. "
                "Install gitleaks or set NWP_GITLEAKS_BIN. Refusing to report "
                "the public docs library clean on the strength of a scan that "
                "never ran.")


def _fixture_tree(tmp_path):
    """A minimal tree `pl library build --root` can build from: the real corpus,
    the real manifest, and nothing else."""
    root = tmp_path / "tree"
    (root / "docs/overview").mkdir(parents=True)
    (root / "docs/guides").mkdir(parents=True)
    for src in sorted((REPO / "docs/overview").glob("*.md")):
        shutil.copy(src, root / "docs/overview" / src.name)
    for src in sorted((REPO / "docs/guides").glob("howto-*.md")):
        shutil.copy(src, root / "docs/guides" / src.name)
    shutil.copy(REPO / "docs/library-manifest.yml", root / "library-manifest.yml")
    return root


def _pl_build(root, out, extra=(), env=None):
    e = dict(os.environ, NWP_LIBRARY_SITES=E2E_VOCAB)
    e.update(env or {})
    return subprocess.run(
        [str(REPO / "pl"), "library", "build",
         "--root", str(root), "--manifest", str(root / "library-manifest.yml"),
         "--out", str(out), *extra],
        capture_output=True, text=True, cwd=str(REPO), env=e, timeout=600)


def test_e2e_real_corpus_builds_two_bundles(tmp_path, gitleaks):
    """NEGATIVE CONTROL for every refusal below: the real thing does build."""
    root = _fixture_tree(tmp_path)
    out = tmp_path / "out"
    r = _pl_build(root, out)
    assert r.returncode == 0, r.stdout + r.stderr
    full = lib.load_bundle(out / "library.json")
    pub = lib.load_bundle(out / "library-public.json")
    assert full and pub
    assert len(full["docs"]) == 13
    assert {d["audience"] for d in pub["docs"]} == {"public"}
    assert len(pub["docs"]) < len(full["docs"]), "the public half must be a strict subset"


@pytest.mark.parametrize("planted,label", [
    ("/home/" + "rob" + "/nwp/lib/common.sh", "operator home path"),
    ("nwd." + "nwpcode" + ".org", "live internal domain"),
    ("rjzaar" + "@" + "gmail.com", "operator personal email"),
    ("97." + "107.137.88", "prod IP"),
])
def test_e2e_planted_operator_identifier_in_a_public_doc_refuses(tmp_path, gitleaks, planted, label):
    """THE test this feature exists to pass. Plant a real operator identifier in
    a manifest-PUBLIC doc and the build must write no bundle at all."""
    root = _fixture_tree(tmp_path)
    out = tmp_path / "out"
    target = root / "docs/overview/nwp.md"
    target.write_text(target.read_text() + f"\n\nRun it from {planted} on the box.\n")
    r = _pl_build(root, out)
    assert r.returncode != 0, f"{label} was published: {r.stdout}"
    assert "not certified clean" in (r.stdout + r.stderr)
    assert not (out / "library.json").exists(), "a refused build must write NOTHING"
    assert not (out / "library-public.json").exists()


def test_e2e_planted_identifier_in_a_private_doc_still_builds(tmp_path, gitleaks):
    """NEGATIVE CONTROL for the rule above: it is a BOUNDARY rule. If a planted
    identifier refused the build wherever it landed, the four tests above would
    pass for the wrong reason and the private tier ('the complete set as is')
    could not exist at all."""
    root = _fixture_tree(tmp_path)
    out = tmp_path / "out"
    target = root / "docs/guides/howto-dr-chain.md"          # audience: private
    target.write_text(target.read_text() + "\n\nSee /home/" + "rob" + "/nwp for the chain.\n")
    r = _pl_build(root, out)
    assert r.returncode == 0, r.stdout + r.stderr
    full = lib.load_bundle(out / "library.json")
    pub = lib.load_bundle(out / "library-public.json")
    assert "/home/" + "rob" in json.dumps(full)              # kept in the full set
    assert "/home/" + "rob" not in json.dumps(pub)           # never in the public one


def test_e2e_no_scanner_means_no_public_tier(tmp_path):
    """FAIL-CLOSED: with no usable gitleaks the checker cannot certify anything,
    so every verdict is `unknown` and every public/contributor doc refuses.
    'I could not check' must never publish."""
    root = _fixture_tree(tmp_path)
    out = tmp_path / "out"
    # PATH is replaced, not prefixed. The first version of this test prefixed a
    # nonexistent directory and left the rest of PATH alone; gitleaks was still
    # found in ~/.local/bin, the build succeeded, and the test would have
    # asserted a fail-closed property that was never exercised. The `if` below
    # is what caught it — keep it.
    r = _pl_build(root, out, env={
        "NWP_GITLEAKS_BIN": str(tmp_path / "definitely-not-here"),
        "GITLEAKS_BIN": str(tmp_path / "definitely-not-here"),
        "PATH": "/usr/bin:/bin",
    })
    combined = r.stdout + r.stderr
    if "no gitleaks binary" not in combined:
        pytest.fail("could not remove gitleaks from the build's environment — "
                    "this test would be vacuous:\n" + combined)
    assert r.returncode != 0
    assert "not certified clean" in combined
    assert not (out / "library-public.json").exists()


def test_e2e_a_contributor_doc_that_names_a_site_refuses(tmp_path, gitleaks):
    """Cross-project leakage via docs, end to end (stage-1 gate check L14)."""
    root = _fixture_tree(tmp_path)
    out = tmp_path / "out"
    target = root / "docs/guides/howto-console.md"            # audience: contributor
    target.write_text(target.read_text() + "\n\nTry it against ssc first.\n")
    r = _pl_build(root, out)
    assert r.returncode != 0, r.stdout
    assert "may name NO site" in (r.stdout + r.stderr)


def test_e2e_a_project_doc_naming_a_foreign_site_refuses(tmp_path, gitleaks):
    root = _fixture_tree(tmp_path)
    out = tmp_path / "out"
    target = root / "docs/guides/howto-invite-codes.md"       # audience: project-ss-nw
    target.write_text(target.read_text() + "\n\nThe same works on dir1.\n")
    r = _pl_build(root, out)
    assert r.returncode != 0, r.stdout
    assert "dir1" in (r.stdout + r.stderr)


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


# ---------------------------------------------------------------------------
# L11 — the published artefacts on disk, and the templates that render them
# ---------------------------------------------------------------------------
# Everything above tests bundles held in memory. These tests exercise the path
# the console actually takes: two FILES in DATA_DIR, read by load_for(), turned
# into a context by page_context()/doc_context(), rendered by the templates.
#
# The templates are rendered through a plain Jinja environment rather than the
# FastAPI app because main.py belongs to the integrator. That is a real gap, so
# it is named here rather than papered over: these prove the TEMPLATES and the
# CONTEXT BUILDERS, not the route wiring. The route contract is written down in
# docs/reports/console-v2/stage4-wiring.md, and the cross-project leakage test
# in test_tenant_isolation.py covers the wiring once the integrator lands it.
import jinja2  # noqa: E402

TEMPLATES = Path(__file__).resolve().parent.parent / "templates"


def _render(name, **ctx):
    """Autoescape ON, matching starlette's Jinja2Templates. A test that rendered
    with autoescape off would prove the opposite of what it claims."""
    env = jinja2.Environment(
        loader=jinja2.FileSystemLoader(str(TEMPLATES)), autoescape=True)
    return env.get_template(name).render(**ctx)


def _publish(tmp_path, files=None, manifest_text=MANIFEST, verdicts=None):
    """Write both artefacts where the console expects them, as `pl library
    publish` would."""
    full, pub = _build(manifest_text=manifest_text, files=files, verdicts=verdicts)
    d = tmp_path / "data"
    d.mkdir(exist_ok=True)
    (d / lib.FULL_FILE).write_text(json.dumps(full))
    (d / lib.PUBLIC_FILE).write_text(json.dumps(pub))
    return d


def _page(data_dir, scope, **kw):
    """The ctx exactly as the route hands it to _pane()."""
    return lib.page_context(data_dir, scope,
                            now=datetime(2026, 7, 27, 9, 5, tzinfo=timezone.utc), **kw)


def _render_page(ctx, scope=None, user=None):
    """Render library.html the way the route does: the whole context splatted,
    plus the two keys _pane() adds. Rendering from a hand-built context instead
    would let the template and the real ctx shape drift apart."""
    sc = scope if scope is not None else _scope()
    return _render("library.html", **dict(
        ctx, user=user or {"name": "dana", "role": "viewer"}, scope=sc))


# -- the two artefacts are two artefacts ------------------------------------
def test_public_view_reads_the_published_public_artefact(tmp_path):
    """NEGATIVE CONTROL for the two tests below: when the public artefact IS
    published, the public view renders it."""
    d = _publish(tmp_path)
    ctx = _page(d, _scope(), variant="public")
    assert ctx["lib"]["bundle_present"] is True
    assert [r["id"] for r in ctx["lib"]["rows"]] == ["overview.readme"]
    html = _render_page(ctx)
    assert "Overview" in html
    assert "No public library" not in html


def test_a_missing_public_artefact_is_never_synthesised_by_filtering(tmp_path):
    """THE fail-closed property of the two-version design.

    If /library?view=public fell back to filtering library.json, the preview
    would be a claim this host computed rather than the artefact the build
    certified — the operator would be reviewing the console's opinion of what is
    publishable. A public bundle that was never published must read as 'not
    published', with the full library sitting right there, unused.
    """
    d = _publish(tmp_path)
    (d / lib.PUBLIC_FILE).unlink()
    assert lib.load_for(d, "full") is not None, "the full library is still there"

    ctx = _page(d, _scope(), variant="public")
    assert ctx["lib"]["bundle_present"] is False
    assert ctx["lib"]["rows"] == []
    html = _render_page(ctx)
    assert "No <strong>public</strong> library" in html
    assert "Overview" not in html, "the full library leaked into the public view"


def test_the_full_library_shipped_as_the_public_file_is_refused(tmp_path):
    """A swapped or mis-shipped file. Without the variant check every private
    doc in the corpus would render under the heading 'Public release' — the
    exact false-public this feature exists to prevent, arriving by cp rather
    than by classification."""
    d = _publish(tmp_path)
    (d / lib.PUBLIC_FILE).write_text((d / lib.FULL_FILE).read_text())
    assert lib.load_for(d, "public") is None
    ctx = _page(d, _scope(role="owner", project_role="maintainer"), variant="public")
    assert ctx["lib"]["bundle_present"] is False
    assert ctx["lib"]["rows"] == []


def test_a_corrupt_bundle_is_absent_not_empty(tmp_path):
    """'Could not read it' must not render as 'there is nothing in it'."""
    d = _publish(tmp_path)
    (d / lib.FULL_FILE).write_text("{ this is not json")
    ctx = _page(d, _scope())
    assert ctx["lib"]["bundle_present"] is False
    html = _render("_library_list.html", lib=ctx["lib"])
    assert "No library has been published" in html
    assert "no documents you may read" not in html.lower()


# -- the context is the shape the shared tenancy nets already act on --------
def test_the_shared_redactor_reaches_the_librarys_publisher_host(tmp_path):
    """`prov` sits at the TOP level of the context, which is the only reason
    scope.redact() applies to the library at all: it strips ctx["prov"]["host"]
    by exact path. Nested as ctx["lib"]["prov"] the redactor would walk straight
    past it and the library would quietly stop obeying a policy every other read
    pane obeys — with every test still green. So assert the wiring, not the
    intention."""
    from app import scope as scope_mod
    d = _publish(tmp_path)

    # A host token that appears NOWHERE in the page's own prose. The default
    # fixture host is "workstation", which the footnote uses as an English word
    # ("the corpus lives in the repo on the workstation") — asserting on that
    # would have been asserting on the copy, not on the redactor.
    HOST = "publisher-box-7f3"
    for f in (lib.FULL_FILE, lib.PUBLIC_FILE):
        b = json.loads((d / f).read_text())
        b["generated_by"] = dict(b["generated_by"], host=HOST)
        (d / f).write_text(json.dumps(b))

    ctx = _page(d, _scope())
    assert ctx["prov"]["host"] == HOST, "nothing to redact — the test would be vacuous"
    assert HOST in _render_page(ctx), "it must be rendered BEFORE redaction, or ditto"

    red = scope_mod.redact(ctx, _scope())
    assert "host" not in red["prov"]
    assert HOST not in _render_page(red)

    # NEGATIVE CONTROL: redaction is for SCOPED readers. An all-sites owner is
    # exempt and must still be told which host published the library — without
    # this, a redactor that simply deleted everything would satisfy the above.
    owner = _scope(role="owner", project_role="maintainer", all_sites=True)
    octx = _page(d, owner)
    assert scope_mod.redact(octx, owner)["prov"]["host"] == HOST
    assert HOST in _render_page(octx, scope=owner,
                                user={"name": "rob", "role": "owner"})


def test_the_context_carries_no_row_the_scrubber_would_have_to_drop(tmp_path):
    """_pane() scrubs any dict carrying a foreign `site` key, and under
    SCOPE_STRICT (CI) a single dropped row RAISES. Library rows key their sites
    as a `sites` LIST, so the scrubber is a no-op here — which is worth pinning,
    because a future row that grew a `site` key would take the whole page down
    in CI rather than in review."""
    from app import scope as scope_mod
    d = _publish(tmp_path)
    for ctx in (_page(d, _scope()), lib.doc_context(d, _scope(), "overview.readme")):
        _clean, dropped = scope_mod.scrub(ctx, _scope())
        assert dropped == 0


# -- the index renders only what the reader may see -------------------------
def test_index_renders_visible_docs_and_no_others(tmp_path):
    d = _publish(tmp_path)
    ctx = _page(d, _scope())
    html = _render_page(ctx)
    assert "Using the console" in html          # contributor
    assert "The demo tier" in html              # their project
    assert "Deploying" not in html              # private — owner only
    assert "howto-deploy" not in html           # nor its id, nor a link to it


def test_index_reports_that_something_was_withheld_without_naming_it(tmp_path):
    """Honest, but not an oracle: the count is fine, the titles are not."""
    d = _publish(tmp_path)
    ctx = _page(d, _scope())
    assert ctx["lib"]["dropped"] == 2
    html = _render("_library_list.html", lib=ctx["lib"])
    assert "2 further documents" in html
    assert "Deploying" not in html
    assert "howto-dr-chain" not in html


def test_owner_sees_the_private_docs_the_member_could_not(tmp_path):
    """NEGATIVE CONTROL for the two tests above — otherwise a template that
    rendered nothing at all would pass them both."""
    d = _publish(tmp_path)
    owner = _scope(role="owner", project_role="maintainer")
    ctx = _page(d, owner)
    html = _render("_library_list.html", lib=ctx["lib"])
    assert "Deploying" in html
    assert ctx["lib"]["dropped"] == 0


def test_unclassified_docs_are_flagged_not_silently_private(tmp_path):
    """Private-by-default is safe, but a doc nobody classified is a decision
    nobody made. The owner's view says so."""
    d = _publish(tmp_path)
    ctx = _page(d, _scope(role="owner", project_role="maintainer"))
    html = _render("_library_list.html", lib=ctx["lib"])
    assert "unclassified" in html


def test_search_filters_the_rendered_list(tmp_path):
    d = _publish(tmp_path)
    ctx = _page(d, _scope(), q="demo")
    assert [r["id"] for r in ctx["lib"]["rows"]] == ["guides.howto-demo-tier"]
    html = _render("_library_list.html", lib=ctx["lib"])
    assert "The demo tier" in html
    assert "Using the console" not in html


def test_search_cannot_reach_a_doc_the_reader_may_not_see(tmp_path):
    """Search filters the ALREADY-gated rows; it is not a query over the bundle.
    A search box that widened visibility would be a hole with a text input in
    front of it."""
    d = _publish(tmp_path)
    ctx = _page(d, _scope(), q="Deploying")
    assert ctx["lib"]["rows"] == []
    html = _render("_library_list.html", lib=ctx["lib"])
    # The page echoes the term the reader typed — that is their own input, not a
    # disclosure. What must not appear is any way to REACH the doc, or any
    # confirmation that a doc by that name exists.
    assert "/library/doc/guides.howto-deploy" not in html
    assert "howto-deploy" not in html


# -- the doc reader ---------------------------------------------------------
def test_doc_context_renders_a_body_for_a_permitted_doc(tmp_path):
    d = _publish(tmp_path)
    ctx = lib.doc_context(d, _scope(), "overview.readme")
    assert ctx is not None
    assert "text" not in ctx["doc"], "the raw source must not ride along with the render"
    html = _render_page(ctx)
    assert "ss and nwc are the two member sites" in html


def test_doc_context_is_none_for_a_doc_outside_the_scope(tmp_path):
    d = _publish(tmp_path)
    assert lib.doc_context(d, _scope(), "guides.howto-deploy") is None      # private
    assert lib.doc_context(d, _scope(), "nope.not.a.doc") is None           # absent
    assert lib.doc_context(d, _scope(), "../../etc/passwd") is None         # malformed
    owner = _scope(role="owner", project_role="maintainer")
    assert lib.doc_context(d, owner, "guides.howto-deploy") is not None     # control


def test_the_public_view_of_a_doc_cannot_reach_a_non_public_doc(tmp_path):
    """?view=public switches the ARTEFACT, not the permissions. An owner asking
    for a private doc's public view gets nothing, because it is not in the
    public release."""
    d = _publish(tmp_path)
    owner = _scope(role="owner", project_role="maintainer")
    assert lib.doc_context(d, owner, "guides.howto-deploy", variant="public") is None
    assert lib.doc_context(d, owner, "overview.readme", variant="public") is not None


def test_rendered_doc_body_escapes_hostile_prose(tmp_path):
    """A doc is exactly the kind of file that gets pasted into. The body reaches
    the template pre-rendered and is emitted with `| safe`, so the escaping must
    already have happened inside render_markdown()."""
    hostile = dict(FILES)
    hostile["docs/overview/README.md"] = (
        "# Overview\n\nss and nwc.\n\n<script>alert(1)</script>\n\n"
        "[click](javascript:alert(2))\n\n<img src=x onerror=alert(3)>\n")
    d = _publish(tmp_path, files=hostile)
    ctx = lib.doc_context(d, _scope(), "overview.readme")

    # Assert on the BODY, not on the whole page: base.html legitimately carries
    # a <script> of its own (the service-worker registration), so a page-wide
    # `"<script>" not in html` would fail for a reason that has nothing to do
    # with the doc — and, worse, would tempt someone to weaken it to something
    # that no longer checks the doc at all.
    body = ctx["body"]
    # The property is that no raw TAG survives — not that the characters do not.
    # `<img src=x onerror=alert(3)>` renders as `&lt;img src=x onerror=alert(3)&gt;`
    # inside a <p>: the substring "onerror=" is still there and is completely
    # inert, so asserting on it would be asserting on the wrong thing.
    assert "<script>" not in body
    assert "<img" not in body
    assert "javascript:" not in body
    assert "&lt;script&gt;" in body, "it should still be VISIBLE as text, just inert"
    assert "&lt;img src=x onerror=alert(3)&gt;" in body

    html = _render_page(ctx)
    # Not `"alert(" not in html`: the escaped text legitimately contains it. The
    # property is that none of the doc's tags survive as TAGS in the shipped
    # page. base.html has no <img> of its own, and its two <script>s are the
    # stylesheet/service-worker pair, neither of which is `<script>alert`.
    assert "<script>alert" not in html
    assert "<img" not in html
    assert "&lt;script&gt;" in html


def test_doc_page_shows_which_version_the_reader_is_in(tmp_path):
    """The operator must be able to tell 'this is in the public release' from
    'this is in my complete set' at a glance — that distinction is the feature."""
    d = _publish(tmp_path)
    pub = lib.doc_context(d, _scope(), "overview.readme", variant="public")
    html = _render_page(pub)
    assert "published public release" in html

    owner = _scope(role="owner", project_role="maintainer")
    priv = lib.doc_context(d, owner, "guides.howto-deploy")
    html = _render_page(priv, scope=owner, user={"name": "rob", "role": "owner"})
    assert "Owner only" in html
    assert "no published public release" in html


# -- provenance uses the shared idiom ---------------------------------------
def test_index_shouts_when_the_published_library_is_stale(tmp_path):
    d = _publish(tmp_path)
    ctx = lib.page_context(d, _scope(), max_age=60,
                           now=datetime(2026, 8, 30, 9, 0, tzinfo=timezone.utc))
    assert ctx["prov"]["stale"] is True
    html = _render_page(ctx)
    assert "STALE" in html


def test_a_stale_library_shouts_on_the_DOC_page_too_not_just_the_index(tmp_path):
    """Staleness has to reach the page where the reader is actually reading.

    An index that shouts and a document that does not is worse than neither:
    the reader arrives at the document from a link, spends their time in the
    body, and nothing on that screen says the text is a month old. doc_context()
    returns `prov` for exactly this reason — rendering it only on the index
    leaves the warning plumbed and unused.
    """
    d = _publish(tmp_path)
    stale_now = datetime(2026, 8, 30, 9, 0, tzinfo=timezone.utc)
    ctx = lib.doc_context(d, _scope(), "overview.readme", max_age=60, now=stale_now)
    assert ctx["prov"]["stale"] is True
    assert "STALE" in _render_page(ctx)

    # NEGATIVE CONTROL: a fresh library must NOT shout, or the assertion above
    # would be satisfied by a page that cried wolf unconditionally.
    fresh = lib.doc_context(d, _scope(), "overview.readme", max_age=14 * 24 * 3600,
                            now=datetime(2026, 7, 27, 9, 5, tzinfo=timezone.utc))
    assert fresh["prov"]["stale"] is False
    assert "STALE" not in _render_page(fresh)


def test_index_calls_out_a_bundle_built_from_a_dirty_tree(tmp_path):
    """A bundle built from uncommitted work corresponds to no commit anyone can
    fetch, so 'which version of the docs is public' stops being answerable."""
    full, pub = _build()
    for b in (full, pub):
        b["generated_by"] = dict(b["generated_by"], git_commit="abc1234", git_dirty=True)
    d = tmp_path / "data"
    d.mkdir()
    (d / lib.FULL_FILE).write_text(json.dumps(full))
    (d / lib.PUBLIC_FILE).write_text(json.dumps(pub))
    ctx = _page(d, _scope())
    html = _render_page(ctx)
    assert "uncommitted changes" in html
