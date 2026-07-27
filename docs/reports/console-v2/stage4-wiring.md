# Stage 4 — Library: wiring contract for the integrator

**Branch:** `console/stage4-library` · **Status:** ready to wire · **Owner:** stage-4 agent

I own `app/library.py`, `templates/library.html`, `templates/_library_list.html`,
`templates/_library_doc.html`, `tests/test_library.py`, `docs/library-manifest.yml`
and `scripts/commands/library.sh`. I have **not** touched `app/main.py`,
`templates/base.html`, `app/config.py` or the nav. Everything below is what you
need to add. Follow it literally; where a choice is load-bearing I say why, so
you can tell a typo from a decision.

---

## 1. Routes to register

Three routes, all `GET`, all HTML, all behind `scoped("viewer")`.

| # | Path | Handler | Auth dependency | Returns |
|---|------|---------|-----------------|---------|
| R1 | `GET /library` | `library_page` | `sc: Scope = Depends(scoped("viewer"))` | full page |
| R2 | `GET /library/list` | `library_list` | `sc: Scope = Depends(scoped("viewer"))` | htmx fragment |
| R3 | `GET /library/doc/{doc_id}` | `library_doc` | `sc: Scope = Depends(scoped("viewer"))` | full page |

Add `from . import library` to main.py's imports.

```python
@app.get("/library", response_class=HTMLResponse)
def library_page(request: Request, view: str = "full", q: str = "",
                 sc: Scope = Depends(scoped("viewer"))):
    ctx = library.page_context(config.DATA_DIR, sc, variant=view, q=q[:200],
                               max_age=LIBRARY_MAX_AGE)
    return _pane(request, "library.html", ctx, sc)


@app.get("/library/list", response_class=HTMLResponse)
def library_list(request: Request, view: str = "full", q: str = "",
                 sc: Scope = Depends(scoped("viewer"))):
    ctx = library.page_context(config.DATA_DIR, sc, variant=view, q=q[:200],
                               max_age=LIBRARY_MAX_AGE)
    return _pane(request, "_library_list.html", ctx, sc)


@app.get("/library/doc/{doc_id}", response_class=HTMLResponse)
def library_doc(request: Request, doc_id: str, view: str = "full",
                sc: Scope = Depends(scoped("viewer"))):
    ctx = library.doc_context(config.DATA_DIR, sc, doc_id, variant=view,
                              max_age=LIBRARY_MAX_AGE)
    if ctx is None:
        raise HTTPException(status_code=404)
    return _pane(request, "library.html", ctx, sc)
```

### Notes that are not style preferences

- **`_pane()`, not `templates.TemplateResponse`.** `page_context`/`doc_context`
  return exactly the ctx `_pane()` expects: `{prov, doc, body, variant, lib{…}}`.
  `prov` is at the **top level** on purpose — `scope.redact()` strips
  `ctx["prov"]["host"]` and `["note"]` by exact path, so nesting it under `lib`
  would silently exempt the Library from a redaction every other read pane
  obeys. `test_the_shared_redactor_reaches_the_librarys_publisher_host` fails if
  you flatten or re-nest it.
- **Leave `redactable` at its default (`True`).** These are read panes. The
  exemption exists for action results whose argv was already scope-validated;
  nothing here shells out.
- **`scrub()` is a no-op here and must stay one.** Library rows key their sites
  as a `sites` *list*, never a `site` string, so nothing is dropped. Under
  `SCOPE_STRICT` (CI) a single dropped row *raises*, so if a future row grows a
  `site` key the page 500s in CI. `test_the_context_carries_no_row_the_scrubber_would_have_to_drop`
  pins it.
- **`doc_id` needs no sanitising in the route.** `library.get_doc()` validates it
  against `DOC_ID_RE` and matches it against the bundle — it is never turned
  into a filesystem path. Do not add a second check that could disagree.
- **404 must not distinguish "no such doc" from "not yours".** `doc_context`
  returns `None` for both, deliberately: a 404 that told them apart would be an
  existence oracle for private docs. Do not add a "you may not read this"
  branch.
- **No `POST` routes, no actions.** The Library is read-only. Nothing here goes
  near the action allowlist, so the Quokka AST test is unaffected.
- **`scoped("viewer")` already handles the project-less user**: `library_shards()`
  returns `[]` when `project_role is None`, and `scoped()` 403s → `/no-project`
  before that matters.

---

## 2. Header entry (NOT a nav tab)

The bottom nav is full: 7 panes + Visuals = 8 is the phone ceiling. The Library
goes in the **header**, next to the Help `?` button, in `base.html`:

```html
<a href="/library" title="Library">Library</a>
```

Visible to **every authenticated user** — no role condition. Every signed-in
user with a project has at least the `public` and `contributor` shards, so the
page is never empty for them; a viewer sees fewer documents, not none.

If you are tight for header width on a phone, a book glyph (`📚`) with
`aria-label="Library"` is fine — but it must not go into the tab bar.

---

## 3. Config keys

One new key. I could not add it (`config.py` is yours), so the snippet above
calls it `LIBRARY_MAX_AGE`; define it in `config.py`:

```python
# How old a published docs library may be before the page shouts. Deliberately
# NOT the fleet max-age: docs change on a commit, days apart, where a RAG grade
# goes stale in minutes. Same idiom (_provenance.html), different number.
LIBRARY_MAX_AGE = int(_env("NWP_CONSOLE_LIBRARY_MAX_AGE", str(14 * 24 * 3600)))
```

`library.DEFAULT_MAX_AGE` is the same 14 days if you would rather not add the
key at all — pass nothing and it applies. Everything else reuses
`config.DATA_DIR`; the two artefacts land at `DATA_DIR/library.json` and
`DATA_DIR/library-public.json` (names exported as `library.FULL_FILE` /
`library.PUBLIC_FILE`, so publisher and reader cannot drift).

No new dependencies. `library.py` is stdlib-only and imports nothing from
`main`/`actions`/`runner`/`subprocess`.

---

## 4. Templates

| File | Role |
|------|------|
| `library.html` | full page; renders the index, or one document when `doc` is set. Extends `base.html`. |
| `_library_list.html` | the doc list — the **htmx swap target** (`#library-list`). Included by `library.html` and returned bare by R2. |
| `_library_doc.html` | one document's header + body. Included by `library.html`. |

`_library_list.html` expects **`lib`** to be the inner dict, i.e. R2 renders it
with the same full ctx and the template reads `lib.*`. Nothing else to include;
`library.html` pulls in `_provenance.html` itself.

Styles are in a `<style>` block inside `library.html` rather than in
`static/style.css`, because three workstreams are editing that file and this
avoids a conflict for you. If you would rather consolidate after landing the
set, the block is self-contained and every selector is `.lib*`-prefixed.

---

## 5. How the corpus reaches mini (and why this way)

**`pl library publish`, a separate verb — not a `pl fleet publish` feed.**

The console holds no docs, the same way it holds no sites. The corpus lives in
the repo on the workstation, so the workstation builds two bundles and ships
them over ssh (0600, atomic write, byte-count verified), exactly as fleet state
is shipped.

I did **not** ride the fleet snapshot, for four reasons:

- **Freshness.** Fleet state is published every 30 minutes because a RAG grade
  goes stale in minutes. Docs change on a commit, days apart. Different cadence,
  different max-age.
- **Size.** ~110 KB of prose against a ~40 KB fleet snapshot. Riding the `*/30`
  cron would roughly triple that cron's bandwidth forever to re-ship bytes that
  did not change.
- **Provenance.** A doc bundle's useful provenance is *the git commit it was
  built from*, and whether the tree was dirty. Fleet state's is a host and a
  clock. Same `_provenance.html` idiom, different facts — the page adds one line
  for the commit and shouts if the build came from a dirty tree, because a
  bundle built from uncommitted work corresponds to no commit anyone can fetch.
- **Blast radius.** A library build can **REFUSE**. Wiring a refusal into the
  fleet cron would take out the Fleet and Todo panes because a doc was
  mis-tagged.

I also rejected **git-pull-on-mini**: it would put the full repo — every private
doc, every ADR — on the console host and make the tenancy boundary a filesystem
question again. The console should hold only what it is allowed to show.

Staleness is rendered by `_provenance.html`, unchanged. A missing bundle is
`snapshot_present: false` with a "no published library on this host" note —
**not** an empty list. "Could not read it" must never render as "there is
nothing in it".

Suggested cadence: on demand, plus a weekly cron. It is not time-sensitive.

---

## 6. The public tier — what it is built on

It is built **on top of** the existing checker, not beside it. `library.sh`
sources `tests/helpers/pubrel-docs-check.sh` and reuses `PUBREL_IDENTITY_RE`,
`PUBREL_ALLOWLIST_SED` and `pubrel_gitleaks_bin`. **No new identity patterns
were written.** Two independent halves per doc, worse answer wins:

- the **grep mirror** (the six operator-identity rules over the allowlist-masked
  file) — pure bash, always runs, cannot be skipped;
- the **gitleaks backstop** — full `.gitleaks.toml`, over a tree containing only
  the candidate docs and **no `.gitleaksignore`** (a fingerprint that suppresses
  a finding in the repo must not also suppress it in a doc about to be
  published).

Verdicts are `clean` / `dirty` / `unknown`, and **`unknown` never publishes**.
On a machine with no gitleaks every doc is `unknown` and every `public` and
`contributor` doc refuses — which is correct for a verb that authorises
publication, and is a test
(`test_e2e_no_scanner_means_no_public_tier`, which first asserts it actually
removed gitleaks from the environment, because an earlier version prefixed PATH
instead of replacing it and was vacuous).

Classification is **fail-closed**: private unless `docs/library-manifest.yml`
says otherwise; unlisted is private; an unparseable manifest refuses the whole
build rather than defaulting. One bad doc refuses the **whole** build and writes
no bundle — it is never quietly demoted, because the operator marked it public
and needs to know they were wrong.

**Cross-project leakage via docs (stage-1 gate check L14)** is enforced at build
time against the text and again at render time against the live `Scope`, because
the manifest (repo, workstation) and `users.json` (console host) have different
authors and can drift:

- a `contributor` doc may name **no** site token at all;
- a `project-<pid>` doc may name only that project's sites;
- a `public` doc may name only sites in the manifest's `public_sites` allowlist.

An **empty site vocabulary refuses the build** — a scan that knows no site names
would report "no sites named" for every doc. So does a vocabulary that is
missing any site the manifest itself names: built from a git worktree the
resolver returned exactly one site name, every cross-project check passed, and
the checks were blind to eleven sites. "Not empty" was a check that passed
without checking.

---

## 7. Evidence

- **69 assertions** in `tests/test_library.py`; **556 console tests green**.
- The required proof — plant an operator identifier in a manifest-public doc and
  the build refuses — runs end to end through `pl library build` against the
  **real corpus and real checker**, parameterised over four identifiers (home
  path, live internal domain, personal email, prod IP):
  `test_e2e_planted_operator_identifier_in_a_public_doc_refuses`. It asserts no
  bundle is written at all.
  **Negative control:** `test_e2e_planted_identifier_in_a_private_doc_still_builds`
  — it is a *boundary* rule; if a planted identifier refused the build wherever
  it landed, the four tests above would pass for the wrong reason and the
  private tier ("the complete set as is") could not exist.
- **13 mutations, each proven to turn specific tests RED** (harness output in
  the MR description): public-view falling back to filtering, no variant check,
  `page_context` ignoring the Scope, search matching everything, `doc_context`
  skipping the gate, the renderer not escaping, provenance dropped from the doc
  page, provenance dropped from the index, `prov` nested under `lib`, a foreign
  `site` key on every row, a missing bundle rendering as an empty one, the body
  bypassing the safe renderer, and the withheld-count silently zeroed. All 13
  were caught.

One defect was found this way rather than assumed away: the doc page rendered
**no** provenance at all, so a reader arriving from a link could spend their
time in a month-old body with nothing on screen saying so — `doc_context()`
returned `prov` and the template never used it. Test written, watched RED,
fixed, GREEN, and pinned by mutation M7 plus a fresh-library negative control
(so the warning cannot pass by crying wolf unconditionally).

### Known gap — please close it when you wire

My template tests render through a plain Jinja environment, not through the
FastAPI app, because `main.py` is yours. **They prove the templates and the
context builders, not the route wiring.** After wiring, please add `/library`,
`/library/list` and `/library/doc/{id}` to the cross-project leakage test in
`test_tenant_isolation.py` (the `NWP_CONSOLE_TEST_DISABLE_SCOPE=1` suite) so the
Library is covered by the same 12-assertions-must-go-red property as every other
pane. The route-level behaviour that needs an assertion there: **a member of
another project requesting a `project-ss-nw` doc by id gets 404, and the index
lists neither its title nor its id.**

---

## 8. Operator-facing verbs

```
pl library check     # verdicts + classification per doc, builds nothing
pl library build     # both bundles locally (refuses on any rule break)
pl library publish   # build, then ship both to the console host
pl library status    # what is built here / published on the host
```

`pl` auto-discovers `scripts/commands/*.sh`, so no dispatcher edit is needed.
Current state of the real corpus: **13 docs — 5 public, 2 contributor,
3 project-ss-nw, 3 private.**
