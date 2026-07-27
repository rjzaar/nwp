"""Library — the docs corpus, in two versions. Pure, stdlib only, unit-tested.

The operator asked for "the library that was created available … and the
library needs 2 versions: one the complete set as is, and a second 'public' one
which is purged of all my private information."

So there are two ARTEFACTS, not one artefact and a filter:

  library.json         every doc in the corpus, classified by audience shard.
                       The console renders it filtered by `library_shards()`.
  library-public.json  ONLY the docs certified public. This is the thing you
                       could put on a website tomorrow, and it is also exactly
                       what `/library?view=public` previews — the preview reads
                       the real artefact rather than re-filtering the full one,
                       so the preview cannot drift from what would ship.

WHY THE CLASSIFIER FAILS CLOSED
-------------------------------
A false "public" is the worst thing this feature can produce: it publishes the
operator's home path, personal email or prod IP. So:

  * A doc is PRIVATE unless the manifest says otherwise. Not in the manifest,
    manifest unparseable, audience unrecognised — all private, and the last two
    refuse the whole build.
  * A doc may be PUBLIC only if an external checker returned an explicit
    `clean` verdict for it. A MISSING verdict is `unknown`, and unknown refuses
    the build. "I could not check" is never "clean" — that rule is inherited
    verbatim from tests/helpers/pubrel-docs-check.sh, whose six identity rules
    and fail-closed gitleaks discipline do the actual scanning. There is
    deliberately NO second scrubber in this file.
  * One bad doc refuses the WHOLE build rather than being quietly demoted to
    private. A silent demotion is a manifest that lies about itself; the
    operator marked it public and must be told they were wrong.

CROSS-PROJECT LEAKAGE VIA DOCS (stage-1 gate check L14)
-------------------------------------------------------
The `contributor` shard is visible to EVERY authenticated user regardless of
project, so a contributor doc that names any site is a cross-project leak. And
a `project-<pid>` doc that names a site outside that project leaks between
tenants. Both are build-time refusals, and the project rule is re-checked at
RENDER time against the live Scope, because the manifest (in the repo, on the
workstation) and users.json (on the console host) have different authors and
can drift. Build-time checks the text against the declaration; render-time
checks the declaration against the reader.

Site names are found with an explicit fleet VOCABULARY supplied by the builder.
An empty vocabulary refuses the build: a scan that knows no site names would
report "no sites named" for every doc, which is the "0 is not a clean bill of
health" failure in a new costume.

This module must not import main/actions/runner/subprocess.
"""
from __future__ import annotations

import hashlib
import html
import json
import re
from datetime import datetime, timezone
from pathlib import Path

try:                                     # normal import inside the app package
    from .authz import library_shards
    from . import fleet_state
except ImportError:                      # running as a script: `pl library build`
    from authz import library_shards     # type: ignore[no-redef]
    import fleet_state                   # type: ignore[no-redef]

SCHEMA = "nwp.library"
SUPPORTED_VERSIONS = (1,)
MANIFEST_SCHEMA = "nwp.library-manifest"
MANIFEST_SUPPORTED_VERSIONS = (1,)

# The four audience shards. `project-<pid>` is generated per project.
PUBLIC = "public"
CONTRIBUTOR = "contributor"
PRIVATE = "private"
FIXED_AUDIENCES = (PUBLIC, CONTRIBUTOR, PRIVATE)

# Which audiences require an explicit `clean` verdict from the identity
# checker. These are exactly the two shards that CROSS the tenancy boundary:
# `public` goes to the world, `contributor` to every authenticated user in
# every project. Anything a non-owner outside your project can read must have
# passed the six operator-identity rules.
#
# `project-<pid>` and `private` are deliberately exempt: a runbook for the
# people who operate a project has to be able to name that project's own server
# to be worth anything, and the operator has already chosen to work with them.
# Project docs are still bounded by their site set, at build AND render time.
NEEDS_CLEAN = (PUBLIC, CONTRIBUTOR)

PROJECT_AUDIENCE_RE = re.compile(r"^project-([a-z0-9][a-z0-9_-]{0,31})$")
DOC_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,120}$")
SITE_TOKEN_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")

# Doc ids reach this module from a URL path segment. They are matched against
# the bundle rather than turned into a filesystem path, but they are validated
# anyway: an id that cannot be an id is not a lookup miss, it is a bad request.
_ID_MAX = 120


class ManifestError(Exception):
    """The manifest could not be read. Never degrades to 'assume private for
    everything and carry on' — an unreadable manifest means the operator's
    intent is unknown, and publishing on unknown intent is the whole risk."""


class BuildRefused(Exception):
    """One or more docs failed a publication rule. Carries every reason, so a
    build is fixed in one pass rather than one refusal at a time."""

    def __init__(self, reasons):
        self.reasons = list(reasons)
        super().__init__("; ".join(self.reasons) if self.reasons else "build refused")


# ---------------------------------------------------------------------------
# manifest — a STRICT subset of YAML, parsed here so nothing new is imported
# ---------------------------------------------------------------------------
# Deliberately strict: every line must be one of the four shapes below, every
# key must be one this module knows, and anything else raises. A permissive
# parser that skips lines it does not understand would silently drop a
# `audience: private` line and leave the doc's audience to a default — and one
# of the defaults in this file is a publication decision.
_TOP_KEYS = ("schema", "schema_version", "public_sites", "docs")
_DOC_KEYS = ("path", "title", "audience", "summary", "sites")


def _scalar(raw: str, where: str):
    v = raw.strip()
    if v.startswith("[") :
        if not v.endswith("]"):
            raise ManifestError(f"{where}: unterminated inline list: {raw!r}")
        inner = v[1:-1].strip()
        if not inner:
            return []
        return [_scalar(part, where) for part in inner.split(",")]
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
        return v[1:-1]
    if v[:1] in ("'", '"') or v[-1:] in ("'", '"'):
        raise ManifestError(f"{where}: unbalanced quote: {raw!r}")
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    return v


def parse_manifest(text: str) -> dict:
    """Parse the strict manifest subset. Raises ManifestError on anything it
    does not fully understand.

    Comments are whole-line only (`#` as the first non-space character). A `#`
    inside a value is a literal `#`, because guessing where a comment starts
    inside a title is how a parser eats half a value.
    """
    if not isinstance(text, str):
        raise ManifestError("manifest is not text")
    out: dict = {"docs": []}
    cur: dict | None = None
    in_docs = False
    for lineno, raw in enumerate(text.splitlines(), 1):
        where = f"line {lineno}"
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if raw.rstrip() != raw.rstrip("\n").rstrip() and False:  # pragma: no cover
            pass
        m = re.match(r"^([a-z_]+):[ \t]*(.*)$", raw)
        if m:                                             # top-level key
            key, val = m.group(1), m.group(2)
            if key not in _TOP_KEYS:
                raise ManifestError(f"{where}: unknown top-level key {key!r}")
            if key == "docs":
                if val.strip():
                    raise ManifestError(f"{where}: `docs:` must start a list on the next line")
                in_docs = True
                cur = None
                continue
            in_docs = False
            cur = None
            out[key] = _scalar(val, where)
            continue
        m = re.match(r"^[ ]{2}-[ ]+([a-z_]+):[ \t]*(.*)$", raw)
        if m:                                             # new list item
            if not in_docs:
                raise ManifestError(f"{where}: list item outside `docs:`")
            cur = {}
            out["docs"].append(cur)
            key, val = m.group(1), m.group(2)
            if key not in _DOC_KEYS:
                raise ManifestError(f"{where}: unknown doc key {key!r}")
            cur[key] = _scalar(val, where)
            continue
        m = re.match(r"^[ ]{4}([a-z_]+):[ \t]*(.*)$", raw)
        if m:                                             # continuation of item
            if cur is None:
                raise ManifestError(f"{where}: indented key with no list item above it")
            key, val = m.group(1), m.group(2)
            if key not in _DOC_KEYS:
                raise ManifestError(f"{where}: unknown doc key {key!r}")
            if key in cur:
                raise ManifestError(f"{where}: duplicate key {key!r} in one doc entry")
            cur[key] = _scalar(val, where)
            continue
        raise ManifestError(f"{where}: cannot parse: {raw!r}")

    if out.get("schema") != MANIFEST_SCHEMA:
        raise ManifestError(f"manifest schema is {out.get('schema')!r}, expected {MANIFEST_SCHEMA!r}")
    try:
        ver = int(out.get("schema_version", 0))
    except (TypeError, ValueError):
        raise ManifestError("manifest schema_version is not a number") from None
    if ver not in MANIFEST_SUPPORTED_VERSIONS:
        raise ManifestError(f"unsupported manifest schema_version {ver}")
    ps = out.get("public_sites", [])
    if isinstance(ps, str):
        raise ManifestError("public_sites must be a list, e.g. []")
    out["public_sites"] = [str(s) for s in (ps or [])]
    return out


# ---------------------------------------------------------------------------
# classification
# ---------------------------------------------------------------------------
def valid_audience(a) -> bool:
    return isinstance(a, str) and (a in FIXED_AUDIENCES or bool(PROJECT_AUDIENCE_RE.match(a)))


def doc_id_for(path: str) -> str:
    """`docs/guides/howto-deploy.md` -> `guides.howto-deploy`.

    Deterministic and reversible enough to grep, and it never contains a slash
    or a dot-dot, so it cannot be mistaken for a path by a later reader.
    """
    p = str(path)
    p = re.sub(r"^docs/", "", p)
    p = re.sub(r"\.md$", "", p)
    p = p.replace("/", ".").lower()
    p = re.sub(r"[^a-z0-9._-]+", "-", p)
    return p[:_ID_MAX]


def site_tokens_in(text: str, vocab) -> list:
    """Every fleet site name the text actually names, in vocabulary order.

    Word-boundary and case-sensitive, with `-` and `_` treated as word
    characters so `ss` does not match inside `ss-nw` and `dir` does not match
    inside `dir1`. `nwc.example.org` DOES match `nwc`, because `.` is a
    boundary — a domain is a site name with extra letters after it.
    """
    if not isinstance(text, str):
        return []
    found = []
    for tok in vocab or ():
        if not isinstance(tok, str) or not SITE_TOKEN_RE.match(tok):
            continue
        if re.search(r"(?<![A-Za-z0-9_-])" + re.escape(tok) + r"(?![A-Za-z0-9_-])", text):
            found.append(tok)
    return found


def _entry_sites(entry: dict) -> list:
    s = entry.get("sites", [])
    if isinstance(s, str):
        s = [s]
    return [str(x) for x in (s or [])]


# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------
def build(manifest, files: dict, vocab, verdicts: dict, meta: dict | None = None,
          now: datetime | None = None) -> tuple:
    """Build (full_bundle, public_bundle) or raise BuildRefused.

    manifest  parsed manifest dict (see parse_manifest)
    files     {repo-relative path: text} — the whole corpus, manifested or not
    vocab     every site name in the fleet. EMPTY REFUSES (see module docstring)
    verdicts  {path: "clean"|"dirty"|"unknown"} from the external checker.
              A path that is absent is `unknown`, and unknown never publishes.
    """
    if not isinstance(files, dict) or not files:
        raise BuildRefused(["corpus is empty — nothing to build"])
    vocab = sorted({str(v) for v in (vocab or ()) if isinstance(v, str) and SITE_TOKEN_RE.match(str(v))})
    if not vocab:
        raise BuildRefused([
            "no site vocabulary supplied — cannot check any doc for cross-project "
            "site names, and a scan that knows no site names would call every doc clean"
        ])
    verdicts = verdicts if isinstance(verdicts, dict) else {}
    public_sites = set(manifest.get("public_sites") or ())

    entries = {}

    reasons = []
    for i, e in enumerate(manifest.get("docs") or ()):
        if not isinstance(e, dict) or not e.get("path"):
            reasons.append(f"manifest doc #{i + 1} has no path")
            continue
        p = str(e["path"])
        if p in entries:
            reasons.append(f"{p}: listed twice in the manifest")
            continue
        entries[p] = e

    # The vocabulary must be at least as complete as the manifest's own
    # evidence. A non-empty vocabulary is not the same as a USABLE one: built
    # from a git worktree (no nwp.yml, no sites/) the resolver returned exactly
    # one site name, the build passed every cross-project check, and the checks
    # were blind to eleven sites. "Not empty" was the check that passed without
    # checking. Every site the manifest itself names must be known.
    known = set(vocab)
    evidence = set(public_sites)
    for e in entries.values():
        evidence |= set(_entry_sites(e))
    missing = sorted(evidence - known)
    if missing:
        raise BuildRefused([
            f"the site vocabulary is missing {missing} — sites the manifest itself "
            f"names. An incomplete vocabulary scans blind for exactly those names. "
            f"Pass --sites, set NWP_LIBRARY_SITES, or build from a tree that has "
            f"nwp.yml/sites/ (vocabulary seen: {sorted(known)})"
        ])

    docs = []
    seen_ids = {}
    for path in sorted(files):
        text = files[path]
        e = entries.get(path, {})
        audience = e.get("audience", PRIVATE)             # <- the fail-closed default
        if path not in entries:
            audience = PRIVATE
        if not valid_audience(audience):
            reasons.append(f"{path}: unknown audience {audience!r} "
                           f"(use public, contributor, project-<id> or private)")
            continue

        declared = _entry_sites(e)
        bad_decl = [s for s in declared if not SITE_TOKEN_RE.match(s)]
        if bad_decl:
            reasons.append(f"{path}: declared sites are not site names: {bad_decl}")
            continue
        named = site_tokens_in(text, vocab)

        if audience != PRIVATE:
            undeclared = [s for s in named if s not in declared]
            if undeclared:
                reasons.append(
                    f"{path}: names site(s) {undeclared} that the manifest does not "
                    f"declare (audience {audience})")

        if audience == CONTRIBUTOR and (named or declared):
            reasons.append(
                f"{path}: a `contributor` doc is visible to every authenticated user "
                f"in every project, so it may name NO site — it names {sorted(set(named + declared))}")

        m = PROJECT_AUDIENCE_RE.match(audience) if isinstance(audience, str) else None
        if m and not declared and named:
            reasons.append(f"{path}: project doc names {named} but declares no sites")

        if audience in NEEDS_CLEAN:
            v = verdicts.get(path, "unknown")
            if v != "clean":
                reasons.append(
                    f"{path}: marked {audience} but the identity checker returned "
                    f"'{v}' — refusing to publish a doc that is not certified clean")

        if audience == PUBLIC:
            outside = sorted({s for s in set(named + declared) if s not in public_sites})
            if outside:
                reasons.append(
                    f"{path}: marked public but names site(s) {outside} that are not in "
                    f"the manifest's `public_sites` allowlist")

        did = doc_id_for(path)
        if not DOC_ID_RE.match(did):
            reasons.append(f"{path}: cannot derive a usable doc id ({did!r})")
            continue
        if did in seen_ids:
            reasons.append(f"{path}: doc id {did!r} collides with {seen_ids[did]}")
            continue
        seen_ids[did] = path

        docs.append({
            "id": did,
            "path": path,
            "title": str(e.get("title") or _title_of(text, path)),
            "audience": audience,
            "summary": str(e.get("summary") or ""),
            "sites": sorted(set(declared)),
            "named_sites": sorted(set(named)),
            "bytes": len(text.encode("utf-8")),
            "sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
            "text": text,
            "unmanifested": path not in entries,
        })

    if reasons:
        raise BuildRefused(sorted(reasons))

    now = now or datetime.now(timezone.utc)
    meta = dict(meta or {}, site_vocabulary=vocab)
    full = _bundle("full", docs, now, meta, sorted(public_sites))
    pub = _bundle("public", [d for d in docs if d["audience"] == PUBLIC], now, meta,
                  sorted(public_sites))
    return full, pub


def _title_of(text: str, path: str) -> str:
    for line in (text or "").splitlines():
        if line.startswith("# "):
            return line[2:].strip()[:200]
    return Path(path).stem


def _bundle(variant, docs, now, meta, public_sites) -> dict:
    counts = {}
    for d in docs:
        counts[d["audience"]] = counts.get(d["audience"], 0) + 1
    return {
        "schema": SCHEMA,
        "schema_version": 1,
        "variant": variant,
        "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "generated_by": {
            "host": str(meta.get("host", "")),
            "user": str(meta.get("user", "")),
            "git_commit": str(meta.get("git_commit", "")),
            "git_dirty": bool(meta.get("git_dirty", False)),
        },
        "public_sites": list(public_sites),
        # Recorded so a reviewer can see WHAT the cross-project scan knew about.
        # A verdict is only as good as the vocabulary behind it.
        "site_vocabulary": list(meta.get("site_vocabulary") or ()),
        "counts": counts,
        "docs": docs,
    }


# ---------------------------------------------------------------------------
# reading a published bundle
# ---------------------------------------------------------------------------
# The two artefacts, as they land on the console host (0600, shipped by
# `pl library publish`). Named here rather than in config.py so the filenames
# the publisher writes and the filenames the console reads cannot drift.
FULL_FILE = "library.json"
PUBLIC_FILE = "library-public.json"
VARIANTS = ("full", "public")

# Docs change on a commit, not on a clock. A fortnight-old library is usually
# just a fortnight without doc edits, where a fortnight-old RAG grade is a dead
# publisher. Different number, deliberately — same IDIOM (_provenance.html).
DEFAULT_MAX_AGE = 14 * 24 * 3600


def bundle_path(data_dir, variant: str = "full"):
    return Path(data_dir) / (PUBLIC_FILE if variant == "public" else FULL_FILE)


def load_for(data_dir, variant: str = "full") -> dict | None:
    """Load ONE variant. The public variant is read from its own artefact and
    is NEVER synthesised by re-filtering the full one.

    That is the whole point of shipping two files. If the public preview were a
    filter over library.json, the preview would be a claim this host computed,
    and it could show a doc as public that the build never certified — the
    reviewer would be reviewing the console's opinion instead of the artefact.
    So a missing library-public.json renders as "not published", never as a
    filtered stand-in.
    """
    b = load_bundle(bundle_path(data_dir, variant))
    if b is None:
        return None
    # A bundle that says it is the other variant is not this variant. Refusing
    # here means a mis-shipped or swapped file cannot present the full corpus
    # under the "public release" heading.
    want = "public" if variant == "public" else "full"
    if b.get("variant") != want:
        return None
    return b


def load_bundle(path) -> dict | None:
    """Read a published bundle. None for missing/corrupt/foreign/unknown-version
    — never raises, and never guesses at a schema it does not know."""
    try:
        raw = Path(path).read_text()
    except (OSError, ValueError):
        return None
    try:
        data = json.loads(raw or "")
    except (json.JSONDecodeError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("schema") != SCHEMA:
        return None
    try:
        if int(data.get("schema_version", 0)) not in SUPPORTED_VERSIONS:
            return None
    except (TypeError, ValueError):
        return None
    if not isinstance(data.get("docs"), list):
        return None
    return data


def _project_pids(scope) -> set:
    return {p for p, _n in (getattr(scope, "memberships", ()) or ())}


def _doc_allowed(doc, scope, shards) -> bool:
    """The render-time gate. Net 1 for docs.

    Everything here is re-derived from the LIVE scope. The bundle's own
    classification is an input, never an authority: it was written on another
    machine, by another author, possibly before the reader's project changed.
    """
    if not isinstance(doc, dict):
        return False
    audience = doc.get("audience")
    if not valid_audience(audience):
        return False
    if audience not in shards:
        return False
    sites = doc.get("sites")
    sites = [s for s in sites if isinstance(s, str)] if isinstance(sites, list) else []
    if audience == PUBLIC:
        return True
    if audience == CONTRIBUTOR:
        # Belt to the builder's braces: a contributor doc that names a site is
        # a cross-project leak, so if one ever reaches a reader (an older
        # bundle, a hand-edited file) it is dropped here too.
        return not sites
    if audience == PRIVATE:
        return getattr(scope, "global_role", "") == "owner"
    m = PROJECT_AUDIENCE_RE.match(audience)
    if not m:
        return False
    pid = m.group(1)
    if pid not in _project_pids(scope):
        return False
    if getattr(scope, "all_sites", False):
        return True
    allowed = getattr(scope, "sites", frozenset()) or frozenset()
    # The manifest declared these sites on the workstation; users.json decides
    # them on the console host. If they have drifted apart, the reader does not
    # get the doc.
    return all(s in allowed for s in sites)


def visible_docs(bundle, scope) -> tuple:
    """(rows, dropped). Rows carry no `text` — the index does not need it, and
    not shipping it means a template bug cannot render a body nobody may see."""
    shards = set(library_shards(scope))
    rows, dropped = [], 0
    for d in (bundle or {}).get("docs") or ():
        if _doc_allowed(d, scope, shards):
            rows.append({k: v for k, v in d.items() if k != "text"})
        else:
            dropped += 1
    rows.sort(key=lambda r: (_AUDIENCE_ORDER.get(_audience_group(r.get("audience")), 9),
                             str(r.get("path", ""))))
    return rows, dropped


_AUDIENCE_ORDER = {PUBLIC: 0, CONTRIBUTOR: 1, "project": 2, PRIVATE: 3}


def _audience_group(a) -> str:
    if isinstance(a, str) and PROJECT_AUDIENCE_RE.match(a):
        return "project"
    return a if a in FIXED_AUDIENCES else "private"


def get_doc(bundle, scope, doc_id):
    """One doc, or None. None covers 'no such doc' AND 'not yours' on purpose:
    a 404 that distinguishes them is an existence oracle."""
    if not isinstance(doc_id, str) or not DOC_ID_RE.match(doc_id):
        return None
    shards = set(library_shards(scope))
    for d in (bundle or {}).get("docs") or ():
        if isinstance(d, dict) and d.get("id") == doc_id:
            return d if _doc_allowed(d, scope, shards) else None
    return None


def counts_for(bundle, scope) -> dict:
    rows, _ = visible_docs(bundle, scope)
    out = {}
    for r in rows:
        g = _audience_group(r.get("audience"))
        out[g] = out.get(g, 0) + 1
    out["total"] = len(rows)
    return out


# ---------------------------------------------------------------------------
# provenance — the SAME idiom as fleet state, rendered by _provenance.html
# ---------------------------------------------------------------------------
def provenance(bundle, max_age: int, now: datetime | None = None, local_host: str = "") -> dict:
    """Provenance in the exact shape `_provenance.html` already renders.

    Docs are not fleet state: a library that is a week old is usually fine,
    where a two-hour-old RAG grade is not. So the max_age differs — but the
    IDIOM does not, because an operator should not have to learn a second way
    of being told data is old.
    """
    import socket
    age = fleet_state.age_seconds(bundle, now) if bundle else None
    stale = bool(bundle is not None and age is not None and max_age > 0 and age > max_age)
    return {
        "source": "published" if bundle is not None else "local",
        "host": fleet_state.source_host(bundle) if bundle else "",
        "local_host": local_host or socket.gethostname(),
        "generated_at": fleet_state.generated_at(bundle) if bundle else "",
        "age_seconds": age,
        "age_human": fleet_state.fmt_age(age) if age is not None else "",
        "stale": stale,
        "snapshot_present": bundle is not None,
        "snapshot_stale": stale,
        "max_age_human": fleet_state.fmt_duration(max_age),
        "scoped": False,
        "note": "" if bundle is not None else "no published library on this host",
    }


# ---------------------------------------------------------------------------
# markdown -> HTML. Escape-first, allowlist-only.
# ---------------------------------------------------------------------------
# Docs are prose from the repo, so this is not an untrusted-input renderer in
# the usual sense — but it renders into an authenticated operator's session,
# and a doc is exactly the kind of file that gets pasted into from elsewhere.
# So: escape EVERYTHING first, then re-introduce a fixed set of tags. No raw
# HTML passthrough, ever, and no `javascript:` href can survive _href().
_SAFE_SCHEME_RE = re.compile(r"^(https?://|mailto:)", re.I)


def _href(url: str, link_resolver=None) -> str | None:
    u = (url or "").strip()
    if not u:
        return None
    if u.startswith("#"):
        return None                      # in-page anchors: rendered as text
    if _SAFE_SCHEME_RE.match(u):
        return u
    if link_resolver and (u.endswith(".md") or ".md#" in u):
        return link_resolver(u)
    return None                          # everything else: not a link


def _inline(text: str, link_resolver=None) -> str:
    """Inline spans over ALREADY-ESCAPED text."""
    out = re.sub(r"`([^`]+)`", lambda m: f"<code>{m.group(1)}</code>", text)

    def link(m):
        label, url = m.group(1), html.unescape(m.group(2))
        href = _href(url, link_resolver)
        if not href:
            return label
        return f'<a href="{html.escape(href, quote=True)}" rel="noopener noreferrer">{label}</a>'

    out = re.sub(r"\[([^\]\[]*)\]\(([^)\s]+)\)", link, out)
    out = re.sub(r"\*\*([^*]+)\*\*", lambda m: f"<strong>{m.group(1)}</strong>", out)
    out = re.sub(r"(?<![\w*])\*([^*\n]+)\*(?!\w)", lambda m: f"<em>{m.group(1)}</em>", out)
    return out


def render_markdown(text: str, link_resolver=None) -> str:
    """A small, safe subset renderer: headings, fenced code, lists, tables,
    blockquotes, rules, paragraphs, and inline code/bold/italic/links.

    `#` becomes `<h2>` so a doc body never competes with the page's own `<h1>`.
    """
    if not isinstance(text, str):
        return ""
    lines = text.replace("\r\n", "\n").split("\n")
    out = []
    i = 0
    n = len(lines)

    def esc(s):
        return html.escape(s, quote=False)

    while i < n:
        line = lines[i]
        stripped = line.strip()

        if stripped.startswith("```"):
            lang = stripped[3:].strip()
            body = []
            i += 1
            while i < n and not lines[i].strip().startswith("```"):
                body.append(lines[i])
                i += 1
            i += 1
            cls = f' class="lang-{esc(lang)}"' if re.fullmatch(r"[A-Za-z0-9_+-]{0,20}", lang or "") and lang else ""
            out.append(f"<pre><code{cls}>" + esc("\n".join(body)) + "</code></pre>")
            continue

        if not stripped:
            i += 1
            continue

        if re.fullmatch(r"(-{3,}|\*{3,}|_{3,})", stripped):
            out.append("<hr>")
            i += 1
            continue

        m = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if m:
            level = min(6, len(m.group(1)) + 1)
            out.append(f"<h{level}>{_inline(esc(m.group(2).strip()), link_resolver)}</h{level}>")
            i += 1
            continue

        if stripped.startswith("|") and i + 1 < n and re.fullmatch(
                r"\|[\s:|-]+\|", lines[i + 1].strip()):
            head = _row(stripped)
            i += 2
            body = []
            while i < n and lines[i].strip().startswith("|"):
                body.append(_row(lines[i].strip()))
                i += 1
            cells = "".join(f"<th>{_inline(esc(c), link_resolver)}</th>" for c in head)
            rows = "".join(
                "<tr>" + "".join(f"<td>{_inline(esc(c), link_resolver)}</td>" for c in r) + "</tr>"
                for r in body)
            out.append(f'<table class="tbl"><tr>{cells}</tr>{rows}</table>')
            continue

        if stripped.startswith("> "):
            body = []
            while i < n and lines[i].strip().startswith(">"):
                body.append(lines[i].strip().lstrip(">").strip())
                i += 1
            out.append("<blockquote>" + _inline(esc(" ".join(body)), link_resolver) + "</blockquote>")
            continue

        m = re.match(r"^\s*([-*+])\s+(.*)$", line)
        if m:
            items = []
            while i < n and re.match(r"^\s*[-*+]\s+", lines[i]):
                items.append(re.sub(r"^\s*[-*+]\s+", "", lines[i]))
                i += 1
            out.append("<ul>" + "".join(
                f"<li>{_inline(esc(x), link_resolver)}</li>" for x in items) + "</ul>")
            continue

        m = re.match(r"^\s*\d+[.)]\s+(.*)$", line)
        if m:
            items = []
            while i < n and re.match(r"^\s*\d+[.)]\s+", lines[i]):
                items.append(re.sub(r"^\s*\d+[.)]\s+", "", lines[i]))
                i += 1
            out.append("<ol>" + "".join(
                f"<li>{_inline(esc(x), link_resolver)}</li>" for x in items) + "</ol>")
            continue

        para = []
        while i < n and lines[i].strip() and not re.match(
                r"^\s*(#{1,6}\s|[-*+]\s|\d+[.)]\s|\||>|```)", lines[i]) and not re.fullmatch(
                r"(-{3,}|\*{3,}|_{3,})", lines[i].strip()):
            para.append(lines[i].strip())
            i += 1
        if para:
            out.append("<p>" + _inline(esc(" ".join(para)), link_resolver) + "</p>")
        else:
            i += 1
    return "\n".join(out)


def _row(line: str) -> list:
    cells = line.strip().strip("|").split("|")
    return [c.strip() for c in cells]


def link_resolver_for(doc, rows):
    """Rewrite a relative `*.md` link to `/library/doc/<id>` — but ONLY when the
    target is a doc the reader may actually see. An unresolvable link renders as
    plain text rather than a dead (or worse, informative) URL: a 404 on
    `/library/doc/private-thing` would tell a reader that private-thing exists.
    """
    ids = {r.get("id") for r in (rows or ()) if isinstance(r, dict)}
    base = str((doc or {}).get("path", ""))
    base_dir = base.rsplit("/", 1)[0] if "/" in base else "docs"

    def resolve(url: str):
        target = url.split("#", 1)[0]
        if target.startswith("docs/"):
            cand = target
        else:
            parts = [p for p in (base_dir + "/" + target).split("/")]
            stack = []
            for p in parts:
                if p in ("", "."):
                    continue
                if p == "..":
                    if stack:
                        stack.pop()
                    continue
                stack.append(p)
            cand = "/".join(stack)
        did = doc_id_for(cand)
        return f"/library/doc/{did}" if did in ids else None

    return resolve


# ---------------------------------------------------------------------------
# route-facing context builders
# ---------------------------------------------------------------------------
# main.py is owned by the integrator, so the handlers there must be trivial:
# load, delegate, render. Everything that decides WHAT A READER SEES lives here,
# where the tests are. A route that had to remember to call visible_docs() is a
# route that can forget to.
def _matches(row, q: str) -> bool:
    if not q:
        return True
    hay = " ".join(str(row.get(k, "")) for k in ("title", "summary", "path", "id")).lower()
    return all(term in hay for term in q.lower().split())


def page_context(data_dir, scope, variant: str = "full", q: str = "",
                 max_age: int = DEFAULT_MAX_AGE, now: datetime | None = None,
                 local_host: str = "") -> dict:
    """Everything /library needs. One call, so a route cannot half-apply it.

    `variant="public"` previews the artefact that would ship. It is still run
    through the render-time gate: the preview is not a privileged view, and a
    hand-edited library-public.json must not become a way to read a doc the
    live Scope does not allow.
    """
    variant = variant if variant in VARIANTS else "full"
    bundle = load_for(data_dir, variant)
    rows, dropped = visible_docs(bundle, scope)
    shown = [r for r in rows if _matches(r, q)]
    return {
        "variant": variant,
        "q": q,
        "rows": shown,
        "total_rows": len(rows),
        "dropped": dropped,
        "counts": counts_for(bundle, scope),
        "prov": provenance(bundle, max_age, now=now, local_host=local_host),
        "shards": sorted(library_shards(scope)),
        "bundle_present": bundle is not None,
        "public_sites": list((bundle or {}).get("public_sites") or ()),
        "site_vocabulary": list((bundle or {}).get("site_vocabulary") or ()),
        "generated_by": dict((bundle or {}).get("generated_by") or {}),
    }


def doc_context(data_dir, scope, doc_id, variant: str = "full",
                max_age: int = DEFAULT_MAX_AGE, now: datetime | None = None,
                local_host: str = "") -> dict | None:
    """One doc, rendered — or None, which the route turns into a 404.

    None means "no such doc OR not yours", deliberately conflated: a 404 that
    distinguishes them is an existence oracle for private docs.
    """
    variant = variant if variant in VARIANTS else "full"
    bundle = load_for(data_dir, variant)
    doc = get_doc(bundle, scope, doc_id)
    if doc is None:
        return None
    rows, _ = visible_docs(bundle, scope)
    body = render_markdown(doc.get("text", ""), link_resolver_for(doc, rows))
    return {
        "variant": variant,
        "doc": {k: v for k, v in doc.items() if k != "text"},
        "body": body,
        "prov": provenance(bundle, max_age, now=now, local_host=local_host),
        "shards": sorted(library_shards(scope)),
    }


# ---------------------------------------------------------------------------
# CLI — `pl library build` calls this. Everything above is import-safe.
# ---------------------------------------------------------------------------
def _cli(argv) -> int:
    import argparse
    import os
    import sys

    ap = argparse.ArgumentParser(prog="library.py", description="build the docs library bundles")
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--manifest", required=True)
    b.add_argument("--root", required=True, help="repo root; doc paths are relative to it")
    b.add_argument("--files", required=True, help="file with one repo-relative doc path per line")
    b.add_argument("--sites", default="", help="comma-separated fleet site vocabulary")
    b.add_argument("--verdicts", default="", help="JSON {path: clean|dirty|unknown}")
    b.add_argument("--out-full", required=True)
    b.add_argument("--out-public", required=True)
    b.add_argument("--host", default="")
    b.add_argument("--user", default="")
    b.add_argument("--git-commit", default="")
    b.add_argument("--git-dirty", default="0")
    a = ap.parse_args(argv)

    root = Path(a.root)
    try:
        manifest = parse_manifest(Path(a.manifest).read_text())
    except (OSError, ManifestError) as exc:
        print(f"library: manifest unusable: {exc}", file=sys.stderr)
        return 2

    paths = [ln.strip() for ln in Path(a.files).read_text().splitlines()
             if ln.strip() and not ln.strip().startswith("#")]
    files = {}
    for p in paths:
        try:
            files[p] = (root / p).read_text()
        except OSError as exc:
            print(f"library: cannot read {p}: {exc}", file=sys.stderr)
            return 2

    verdicts = {}
    if a.verdicts:
        try:
            verdicts = json.loads(Path(a.verdicts).read_text())
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            print(f"library: cannot read verdicts ({exc}) — refusing to build", file=sys.stderr)
            return 2
        if not isinstance(verdicts, dict):
            print("library: verdicts file is not an object — refusing to build", file=sys.stderr)
            return 2

    vocab = [s.strip() for s in a.sites.split(",") if s.strip()]
    meta = {"host": a.host or os.uname().nodename, "user": a.user,
            "git_commit": a.git_commit, "git_dirty": a.git_dirty not in ("", "0", "false")}
    try:
        full, pub = build(manifest, files, vocab, verdicts, meta)
    except BuildRefused as exc:
        print("library: BUILD REFUSED — no bundle written.", file=sys.stderr)
        for r in exc.reasons:
            print(f"  - {r}", file=sys.stderr)
        return 1

    for path, data in ((a.out_full, full), (a.out_public, pub)):
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(p.suffix + ".tmp")
        tmp.write_text(json.dumps(data, indent=1, sort_keys=False))
        tmp.chmod(0o600)
        tmp.replace(p)
    print(f"library: {len(full['docs'])} docs -> {a.out_full} "
          f"({len(pub['docs'])} public -> {a.out_public})")
    for d in full["docs"]:
        if d.get("unmanifested"):
            print(f"library: NOTE {d['path']} is not in the manifest — classified private")
    return 0


if __name__ == "__main__":                                  # pragma: no cover
    import sys
    raise SystemExit(_cli(sys.argv[1:]))
