# ops#90 — depthcontent `<details>` stored-XSS hardening (patch artifact)

**Status:** committed upstream in `~/nwptoolkit` and `~/dir`; **not applied** to the
four in-tree site copies, and **not deployed** anywhere.
**Why an artifact:** the agent that produced this ran isolated in a git worktree of
`nwp/nwp` and cannot run git in any tree under `/home/rob/nwp`, so the four site
copies get a patch instead of a branch. `sites/ssc` has no remote in any case.

## What ops#90 was, and what is left

ops#90 reported that `depthcontent_render_markdown()` lifts `<details>…</details>`
blocks out of the text *before* `format_text()` and splices them back *after*, and
that the blocks were re-inserted **raw** — so any author-stored `on*` handler,
`<script>` or `javascript:` URL rendered live. On Moodle that is privilege
escalation: a teacher or admin viewing the page runs the payload with their session.

**That original hole was already closed** on 2026-07-17 by
`~/nwptoolkit` commit `d478905`, and — this is the part ops#103 left ambiguous —
the fix had already been propagated to **all six** known copies, which carry a
**byte-identical** `depthcontent_sanitise_details_block()` (sha256 of the extracted
function: `1af16744…`). Live `ssc` and `ssd` run it. So the P0 is **not open**.

What remained was a real but narrower defect in that fix, plus the two things
ops#90 explicitly asked for and never got: the autoloadable refactor, and a test.

### The residual defect

The scheme check was `^\s*(javascript|vbscript|data)\s*:` — it tolerates only
*leading* whitespace. Browsers strip TAB/LF/CR from a URL *before* resolving its
scheme, so:

```html
<details><summary>s</summary><a href="jav&#x09;ascript:alert(1)">x</a></details>
```

is `javascript:` to a browser but does **not** match that pattern. The attribute
survived the sanitiser's own logic. It was neutralised only *incidentally*: libxml
percent-encodes the tab on serialisation (`jav%09ascript:`), and `%` is not legal
in a scheme, so the URL degrades to a relative reference. Not exploitable as it
stands today — but the defence belongs to the serialiser, not to the sanitiser, and
nothing pins it there.

## What the patch does

* Moves the logic into `\mod_depthcontent\local\renderer`
  (`classes/local/renderer.php`). `view.php` `require()`s `config.php` on line 28,
  so nothing in it can be loaded by a test; `sanitise_details_block()` is now pure
  (no `$DB`/`$CFG`/`$COURSE`). This is the refactor ops#90 recommended.
* **Denylist → allowlist.** Only known-safe elements survive. Script-bearing ones
  (`script`/`style`/`iframe`/`object`/`embed`/`form`/`svg`/`math`/…) are dropped
  subtree and all; anything unrecognised is *unwrapped* with its text preserved. An
  element nobody anticipated now fails closed.
* Attributes are allowlisted per element (plus `data-*`/`aria-*`), so `on*`, `style`
  and `srcdoc` are gone by construction rather than by enumeration.
* URL attributes go through `sanitise_url()`: C0 controls / DEL / NUL are stripped
  **before** the scheme is read, and the scheme must be in
  `{http, https, mailto, tel, ftp, ftps}` or absent. The *cleaned* value is written
  back, so no `%09` reaches the page.
* The extraction regex is now case-insensitive, so `<DETAILS>` is sanitised by us
  rather than relying on `format_text()` to catch the fallthrough.
* `view.php` keeps both original function names as thin wrappers — no caller changes.

`tests/sanitise_details_test.php` runs standalone, no Moodle bootstrap:

```
php mod/depthcontent/tests/sanitise_details_test.php
```

31 checks. Recorded results:

| implementation | failures | |
|---|---|---|
| pre-`d478905` (raw re-insert) | **18** | the original ops#90 vulnerability, reproduced |
| `d478905` (denylist) | **2** | the TAB/LF split-scheme gap |
| this patch (allowlist) | **0** | |

Nine of the 31 are negative controls (legitimate accordions, links, images, tables,
`data-*` must still render) — without them a sanitiser that deleted everything
would pass.

## Regression risk

Low. A census of the 251 authored learning-point JSON files in
`dir/courses_v3/build/json` plus the catalog YAML found **no HTML at all** — the
authored `text` fields are pure Markdown. No stored content currently exercises the
`<details>` path, so the stricter allowlist has nothing live to break.

## Applying it

The patch is rooted at a Moodle install root (paths `mod/depthcontent/…`). Verified
`--dry-run` clean against all four in-tree copies on 2026-07-28:

```bash
cd <moodle-root>
patch -p1 --forward < ops-90-depthcontent-xss-hardening.patch
php -l mod/depthcontent/view.php
php -l mod/depthcontent/classes/local/renderer.php
php mod/depthcontent/tests/sanitise_details_test.php   # expect: 31 checks, 0 failures
```

| target | root | applies clean |
|---|---|---|
| ssc dev | `/home/rob/nwp/sites/ssc/dev` | yes |
| ss dev | `/home/rob/nwp/sites/ss/dev` | yes |
| ss stg | `/home/rob/nwp/sites/ss/stg` | yes |
| ss2 dev | `/home/rob/nwp/sites/ss2/dev` | yes |

The patch deliberately touches **only** `view.php` plus two new files. It does not
go near `lib.php` or `classes/external/`, which is where the ssc Art.9 gate lives —
so that gate is untouched by construction.

### version.php is NOT in the patch

Each copy carries a different `$plugin->version`, so a shared hunk could not apply.
Bump by hand after patching, to force the Moodle upgrade step:

| copy | current | set to |
|---|---|---|
| ssc dev | `2026072600` | `2026072800` |
| ss dev | `2026072001` | `2026072800` |
| ss stg | `2026041500` | `2026072800` |
| ss2 dev | `2026041500` | `2026072800` |

(`~/nwptoolkit` `2026041502 → 2026072800`, release `1.1.0 → 1.1.1`, and `~/dir`
`2026072002 → 2026072800` are already committed.)

## Upstream commits

| repo | branch | sha | pushed |
|---|---|---|---|
| `~/nwptoolkit` | `fix/ops-90-depthcontent-xss` | `0170216` | yes, `gitp` (met mirror) |
| `~/dir` | `fix/ops-90-depthcontent-xss` | `f25dbd8` | yes, `gitp` (met mirror) |

Both carry the `REVIEW:` prefix — XSS/sanitiser changes are security-critical and
need two-person review. **Nothing is merged and nothing is deployed.**

## Deployment is an operator act

Live `ssc` and `ssd` (`/var/www/ssc`, `/var/www/ssd` on `git.nwpcode.org`) still run
the `d478905` denylist. They are **not** carrying an open P0 — this is a hardening
rollout, not an incident response, and it can wait for a normal gated window. Do not
push it from an AI-accessible machine.
