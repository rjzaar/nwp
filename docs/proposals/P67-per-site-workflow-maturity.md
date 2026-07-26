# P67 — Per-site workflow classes: the `maturity:` axis (code flow) beside `canonical:` (content flow)

**Status:** PROPOSED (operator question 2026-07-06: "per-site CI status … what are all the
possibilities? how should they be classed? can I switch sites between options?")
**Research base:** three parallel surveys (2026-07-06) over the ADRs (0013/0017/0022/0024/0025/0026,
role-vocabulary), the vision docs (`~/central/reeval-2026-06-11/08` Part IV, PRINCIPLES,
OPERATING-MODEL, self-healing-loop-guide, nwc-fork-guide, instance-manifest), and the code
(deploy scripts, canonical.sh, agent-loop, bundle/nwp-server path, CI, copy/install).
**Relation:** implements the site-maturity model already *designed* in `08` Part IV (candidate
ADR, never built) using the enforcement pattern *proven* by ops#33 (`canonical:`).

---

## 1. The finding that frames everything

The system already separates two questions, and answers each with a different mechanism:

- **"Where may CONTENT change?"** → `sites.<name>.canonical: dev|live|prod` — **built and
  enforced** (ops#33): guards in stg2live/stg2prod/live2prod/dev2stg, PHASE column,
  manifests, ledger.
- **"Who may change CODE, and what gates a deploy?"** → designed in `08` Part IV as
  per-site **maturity tiers** (incubating / stabilizing / production, graduation one-way,
  auto-runner retired per site) — **never built**. Today it is approximated by scattered
  mechanisms: per-issue `agent-eligible` labels, `fix-repo-map.json` routing, the
  `_rag_eligible_sites` denylist, `live.enabled`, and the A14 test-tier/prod split
  hardcoded in docs and CI comments. `ci.enabled` in nwp.yml is display-only; the v3
  `features.*` block in example.nwp.yml is unread by any deploy script.

P67 = give the code axis the same treatment the content axis got in ops#33: **one per-site
field, read by the same choke-point scripts, enforced fail-closed, switchable by an
explicit ledgered verb, visible in status/rag.**

## 2. The two-axis model

Every site's workflow is fully described by a pair:

```yaml
sites:
  <name>:
    canonical: dev | live | prod     # CONTENT: which host owns the content (ops#33, built)
    maturity:  incubating | stabilizing | production   # CODE: who may deploy, past what gate (P67)
```

### The three maturity classes (vocabulary from 08 Part IV, kept deliberately)

| | **incubating** (default) | **stabilizing** | **production** |
|---|---|---|---|
| Who edits code | operator + Claude directly on dev | same, but on branches | branches only (canonical: prod already enforces this) |
| Gate before live | none — direct `pl stg2live` (A14 test tier) | **merged, CI-green `main`** — direct stg2live from a dirty tree/branch refused | **signed bundle + `nwp-server` verify/apply** (or the ADR-0024 protected runner once its 3 preconditions land); WebAuthn-gated merge |
| Agent-loop | may auto-work `agent-eligible` issues, MR → human merge | same (MR-only is already the loop's contract) | may *propose* MRs only; deploy never automatic |
| Real-world examples | scratch sites, nwt/nwd fixtures, nwc today | nwc after its content cutover; mt/cathnet/dir1 once users depend on them | avc/mayo real prod, future paying sites |
| Direct `pl stg2live` | ✅ allowed | ⚠ only from clean, merged main (`canonical_enforce_branch_policy deploy`-style check, plus CI-green) | ❌ refused — points at the signed-bundle path |

**Default when absent: `incubating`** — today's behavior, zero regression (same
back-compat rule as `canonical:` defaulting to `dev`). Unparseable values fail closed,
same as ops#33.

### Sensible (maturity, canonical) combinations

| maturity \ canonical | dev | live | prod |
|---|---|---|---|
| incubating | scratch/dev sites, **nwc today** | rare (content real, code experimental — warn) | invalid (prod content demands prod discipline — refuse) |
| stabilizing | pre-cutover polish | **the normal grown-up test-tier site** | transitional only |
| production | invalid — refuse | live-canonical real site | **real prod end-state (avc future)** |

`pl maturity set` validates the pair and refuses the invalid corners.

## 3. Direct answers to the operator's questions

1. **"When ver is set up, will the pipeline go through `ai-host` and my direct dev→live work
   change?"** — **No.** Three sources agree: the A14 grant (ADR-0024 header, 2026-07-01)
   scopes the direct/AI deploy path to the `*.example.com` test fleet explicitly and
   permanently ("this grant does NOT extend AI write access" to real prod);
   `nwp-server-operations.md` encodes it in the CI rule (`test tier: on_success. real
   prod: when: manual`); and 08 Part IV makes retirement of the direct path a **per-site
   graduation event**, not a global switch. ver's arrival *adds* the real-prod path; it
   removes nothing from the test tier. Also: `ai-host` is the *fix* half (agent-loop,
   issue→MR), never the deploy half — "the loop ends at merged code." Your direct work
   and `ai-host`'s loop are parallel producers of merged code; neither blocks the other.

2. **"Per-site CI status — possible?"** — Yes, and it is *already designed* (08 Part IV);
   P67 is the build plan. The field is per-site in nwp.yml, enforced at the same
   choke points canonical uses.

3. **"What are all the possibilities / how classed?"** — §2. Two orthogonal axes
   (content: `canonical`, code: `maturity`), three classes each, ~6 valid combinations.
   A third, finer-grained knob already exists and stays: per-issue `agent-eligible`
   promotion (which *items* the loop may touch, inside whatever the site's class allows).

4. **"Can I switch sites between options?"** — Yes: `pl maturity set <site> <class>`,
   exact mirror of `pl canonical set` (records who/when in nwp.yml + append-only ledger
   `private/canonical/<site>.log`). Per 08, **graduation is one-way by default**:
   upgrades are routine; downgrades (production→stabilizing etc.) demand the typed-name
   confirmation tier from `lib/impact.sh` + a ledger record, because they widen the
   blast radius.

5. **"Branched test site to work on with you, while live serves others?"** — §5 below.

6. **"How does this interact with code/content separation?"** — they compose exactly:
   `maturity` gates the code track (git → deploy), `canonical` gates the content track
   (DB/files sync direction), `config/sync` rides the code track. The branched-site
   workflow in §5 is the two axes doing their jobs simultaneously.

## 4. Enforcement plan (mirrors ops#33, small and mechanical)

1. `lib/canonical.sh` gains `maturity_get_class()` (same read/default/fail-closed shape)
   and `maturity_guard_deploy <site> <cmd>`:
   - incubating → return 0.
   - stabilizing → require clean checkout of `main` + (when CI info available) last
     pipeline green on that SHA; else refuse with the exact commands to fix.
   - production → refuse direct SSH/rsync deploys outright; print the signed-bundle
     path (`pl build` → `server-pull`/`server-apply`) or the runner instructions.
2. Call it from the same four scripts that call the canonical guards (stg2live,
   stg2prod, live2prod + a work-mode warning in dev2stg). ~6 lines each, same pattern
   reviewers have already approved twice.
3. `pl maturity show|set|check|log` — clone of canonical.sh's verb (or fold both into
   one `pl site class` umbrella later; start separate, KISS).
4. `pl status` + `pl rag`: MAT column next to PHASE (`(inc)` parenthesized default,
   same convention).
5. Deploy/backup manifests + the impact reports stamp `maturity` next to
   `canonical_phase` (one line in `canonical_deploy_manifest` and `build_impact_report`).
6. Agent-loop: `_rag_eligible_sites`/sync-issues may auto-apply a `maturity::<class>`
   label so promotion decisions see the class at triage time. (The loop's own gate —
   `agent-eligible` per issue — is unchanged.)
7. Migration: nothing. Absent field = incubating = today. Operator sets real classes
   site-by-site (`pl maturity set mt stabilizing`, etc.) the same way canonical phases
   are being set.

Deliberately NOT in scope: building the ADR-0024 runner (own preconditions), wiring
per-site deploys into .gitlab-ci.yml (the `production` class only *refuses* direct
paths until the signed path is chosen per ADR-0024/0026 — it does not invent a new one).

## 5. The branched test site (work with Claude while live serves users)

**Recipe with today's tooling** (all pieces exist; one gap noted):

```
pl copy nwc nwct                # clone code+DB to sites/nwct (local DDEV twin)
cd sites/nwct/dev && git switch -c feat/big-idea    # branch the twin's repo
# hack with Claude on nwct-dev; users keep using the real site's live
# content refresh when wanted: sanitized live→dev pull into nwct (ops#33 path)
# when happy: push branch → MR → CI → merge to main
# main lands on the REAL site per its maturity class (direct / clean-main / signed)
pl delete nwct                  # twin is disposable; backups auto-archived (ops#47)
```

- The twin is `(incubating, dev-content-throwaway)` by construction — `purpose: testing`,
  no `live:` block, so it *can't* deploy anywhere even by accident (`live.enabled`
  absent + nothing to point at).
- The real site keeps serving; its content authority is whatever its `canonical` says;
  code changes reach it only through the merge → its-class-gate path.
- This is the ADR-0016 parallel-install pattern (nwt/nwd) generalized to ad-hoc twins.
- **Gap to close (small):** `pl copy --branch=<ref>` (or `pl branch <site> <ref>`) to do
  the copy+switch+composer-install in one verb; `install.sh`'s `source_git` clone has no
  `-b` flag either. One flag + ~20 lines each.

## 5b. Branch-aware status (operator request 2026-07-06: "main site first, branches under it")

Today the fleet tables show no branch at all (only `pl status info <site>` does), and a
twin made by `pl copy` isn't even registered in nwp.yml — it appears as an orphan. Design:

**Lineage fields** (written by `pl branch`, readable by hand):
```yaml
sites:
  nwct:
    branch_of: nwc            # ← makes it render nested under nwc
    branch: feat/big-idea     # informational; live truth read from git
    content_source: live      # live | parent | prod | demo | fresh
    content_as_of: 2026-07-05T09:12Z
    purpose: testing
```

**Rendering** (text views + TUI; parents in current order, twins indented under parent):
```
  RAG NAME              RECIPE   PHASE  MAT   BRANCH             CODE Δ        CONTENT
  ●   nwc               nwc-dev  dev    inc   unfork/os-13       —             canonical
  ●    └─ nwct          nwc-dev  —      inc   feat/big-idea      +3 ahead −1   live@07-05 (sanitized)
  ●   mt                mt       live   stab  main               —             canonical
```
- **BRANCH**: `git branch --show-current` in the resolved dev repo; `main` rendered dim
  so drift jumps out (nwc sitting on `unfork/os-13` becomes visible fleet-wide).
- **CODE Δ**: `git rev-list --left-right --count origin/main...HEAD` → "+ahead −behind".
  Shown for twins always; for parents only when not on main (drift indicator).
- **CONTENT**: content is a database, not a git history — "commits ahead of main" has no
  meaning for it. The honest, computable metric is **provenance + age**:
  `canonical` (this site owns its content) · `live@<date> (sanitized)` ·
  `parent@<date>` · `demo` (seeded from the demo recipe) · `fresh`. Stamped by whichever
  verb loads a DB (branch/copy/import/restore/live2stg), consistent with the ops#33/#47
  manifest discipline. A stale stamp (> N days, configurable) renders with a `*`.

## 5c. New verb: `pl branch` (yes — a new command is warranted)

`pl copy` + hand-git works but loses lineage (twin unregistered, no provenance). One verb
that records what it did:

```
pl branch <site> <git-ref> [--name=<twin>] [--content=parent|live|demo|fresh]
    # copy code (reusing copy.sh), git switch -c <ref> (or checkout existing ref),
    # register twin in nwp.yml with branch_of/branch/content_* + purpose: testing,
    # NO live: block (deploy-incapable by construction)
pl branch list [<site>]        # the nested tree + Δmain + content provenance
pl branch content <twin> --from=parent|live|prod|demo    # refresh twin DB, restamp
pl branch merge <twin>         # push branch + open MR (never merges; prints the URL)
pl branch delete <twin>        # delegates to pl delete (impact contract applies)
```
Also: `pl copy --branch=<ref>` and `install.sh source_git` branch support fall out of the
same ~20-line change.

## 5d. Sanitized-content pulls — what exists, and one honesty gap found

| Path | Command | Sanitizes? |
|---|---|---|
| prod/live server → local site | `pl import <site> --server=<s>` | **yes, default on** (`--no-sanitize` to opt out) — this IS the "pull sanitized prod content into a test site" verb |
| dev → stg | `pl dev2stg` | yes (`sanitize_staging_db`, default on) |
| live → stg | `pl live2stg` | **NO — raw pull** (grep: zero sanitize references) |
| prod → stg | `pl prod2stg` | **NO — raw pull** |
| prod-side (designed) | `nwp-server publish` (ADR-0026) | sanitize ON prod + fail-closed PII gate → write-only publish; built, not yet the default plumbing |

Gap: the ops#33 guard messages say "sanitized live→dev is the path" but `live2stg` pulls
raw. Fix (small, P67 item): `live2stg`/`prod2stg` gain a default-on sanitize step (same
`sanitize_staging_db` call dev2stg uses) whenever the site is `canonical: live|prod`,
`--no-sanitize` to opt out; long-term the real-prod path migrates to `server-publish`
(sanitize-on-prod, per threat model "raw user data never leaves prod").

## 5e. The ops board

Exists today as **`pl issue ls`** (open issues: number/state/title/labels; `--all` for
closed too) — plus `pl rag` (per-site fleet state) and `pl todo` (work queue). What's
missing for "one screen, every op, its state": grouping and MR linkage. Proposed small
addition — `pl issue board`:
```
  WORK ITEMS (12 open)          rag-auto (15)              MRs
  #48 P67 maturity   [proposed] #7 avc  🔴 sec            !44 merged
  #47 impact contract [partial] #12 mayo 🔴 sec           ...
  #37 flock/prune    [open]     ...
```
— i.e. `pl issue ls` split into work-items vs rag-auto, joined with open MRs (one API
call each), state column derived from labels. Cheap because issue.sh already has the
API plumbing.

## 6. Decision points for the operator

1. Adopt `maturity:` as the field name (keeps 08 Part IV vocabulary) vs `workflow:`.
   **Recommend `maturity`** — the vision docs, ADR-0024's incubating/production language,
   and future ADR all already speak it.
2. Confirm the invalid-combination refusals in §2's matrix (esp. incubating+prod).
3. Confirm one-way-by-default graduation (downgrade = typed confirm + ledger).
4. `pl copy --branch` as part of P67 or separate small issue.
5. After implementation: assign classes to the current fleet (suggested opening state:
   everything incubating except mt/cathnet/dir1/ba/mg → stabilizing; avc/mayo → production
   *the day the signed path or runner exists*, until then stabilizing-with-frozen-code).
6. (2026-07-06 amendment) Approve §5b–5e: the `branch_of` lineage fields + nested status
   rendering, the `pl branch` verb family, the live2stg/prod2stg default-sanitize fix
   (closes the "sanitized live→dev" honesty gap), and `pl issue board`.

## 7. Sources (for the future reader)

ADR-0013 (four-state model), ADR-0017 (distributed pipeline, key separation), ADR-0022
(nwp-server build target), **ADR-0024** (runner-resident prod, A14 grant + scoping,
incubating-vs-production deploy gates, 3 preconditions), ADR-0025 (DR to ver), ADR-0026
(nwp-server capability agent, three-key ledger), role-vocabulary.md;
`08-VISION…` **Part IV (maturity tiers, graduation one-way)** + Part III-A (control
plane); PRINCIPLES §2/§3/§6/§8; self-healing-loop-guide (agent-loop = fix half only);
nwc-fork-guide (code/content/config three-layer split); instance-manifest.yml (role→host);
code: lib/canonical.sh, stg2live/stg2prod/live2prod, agent-loop.sh + fix-repo-map.json,
bundle-build/verify + server-*.sh, copy.sh/install.sh (no branch flag), .gitlab-ci.yml
(no per-site deploy; ci.enabled display-only).
