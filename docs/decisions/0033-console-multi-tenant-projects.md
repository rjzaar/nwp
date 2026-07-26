# ADR-0033: NWP Console multi-tenancy — projects, the Scope choke point, and what it is NOT

**Status:** Accepted (2026-07-26, operator)
**Date:** 2026-07-26
**Decision Makers:** Robert Karsten Zaar (with AI assistance)
**Related Issues:** Console v2 Stage 1
**References:** [ADR-0017](0017-distributed-build-deploy-pipeline.md) (distributed actors, offline
deploy-host boundary), [ADR-0028](0028-ver-single-operator-human-gated-workstation.md) (deploy gate),
`scripts/console/README.md`, `scripts/console/app/scope.py`

---

## Context

The NWP Console is a mesh-only, passkey-only PWA on the console host. Until now every
authenticated user saw the whole fleet — 16 sites mixing the operator's own
projects (avc, mt, cathnet, dir, dir1, fin, …) with the Saint School / Narrow
Way family (nwc, ssc, nwd, ssd, ss, ss2, saintschool).

The operator wants to onboard other developers onto the Saint School / Narrow
Way work **without showing them the rest**. That requires a tenancy boundary
where there was none.

Two structural facts shape the answer:

1. **The console host does not hold the sites.** Fleet data arrives as a
   snapshot published from the workstation (`pl fleet publish`). Anything a
   pane shows about a site rides that one channel.
2. **There is exactly one of everything else** — one Unix user, one `pl`
   checkout, one GitLab token, one audit log, one ollama.

## Decision

### 1. A project is a named set of sites, and it is the only boundary

`users.json` gains a `projects` map (schema v2). A project holds `sites`,
`demo_sites`, and the GitLab surfaces (`issue_label`, `ci_projects`) that
belong with them. Membership is `users.<n>.projects = {pid: project_role}`.

Invariants, enforced on write:

- a site belongs to **at most one** project (refusal names the other project);
- `demo_sites ⊆ sites`; `ci_projects ⊆` the console's configured CI list;
- a missing `issue_label` means the project sees **no** issues — never "all";
- **sites in no project are owner-only, with no configuration required.**

### 2. Two role axes, and the global role is a ceiling

Global roles (`viewer`/`operator`/`owner`) are unchanged and govern the console
itself. Project roles (`viewer`/`operator`/`maintainer`) govern one project.
`effective_project_role()` caps the second by the first, so adding someone as a
project maintainer can never make them a console operator.

**Editing a project's site list is a permission grant**, so it is owner-only —
a maintainer may hand out access to what the project already contains, never
change what it contains.

### 3. Render-time filtering through one choke point, not one file per tenant

Site-derived data stays in **one** snapshot and is filtered at render time
through `Scope` (`app/scope.py`).

The alternative — publishing one file per project — was rejected as the
*default* because it gives the project→sites map a second author (the
publisher) and therefore lets it drift; drift in a tenancy map is a disclosure.
The console host is the single author, and `pl console project export` ships a
read-only copy to the workstation.

The file-isolated path still exists for when it is genuinely wanted:
`fleet_state.load_for()` prefers `fleet-state.<pid>.json` when present and the
provenance line says which of the two you are reading. No code change needed.

### 4. Three nets, because one is never enough

1. `scoped(need)` — a FastAPI dependency on every route that can show or touch
   site data. `require("owner")` survives only on `/users`, `/projects`,
   `/notifications`.
2. `_pane()` — recursively **scrubs** any dict carrying a foreign `site` key
   out of the render context and **redacts** free-text passthroughs (raw
   command output, publisher hostname, provenance notes) for scoped readers.
   Dropped rows are audited; under `NWP_CONSOLE_SCOPE_STRICT=1` (set in tests)
   a drop raises, so a leak fails the build rather than being silently repaired
   at render time forever.
3. An **AST test over `main.py`** asserting that every route carries a
   dependency, that no route calls a fleet-wide `_gather_*_raw`, that no route
   reads `config.DEMO_SITES`/`CI_PROJECTS` directly, and that every pane
   renders through `_pane()`. A net you can forget to hang is not a net.

### 5. Fail-closed defaults

| state | result |
|---|---|
| no projects exist at all | legacy mode — byte-identical to the previous console |
| authenticated, member of nothing, projects exist | sees **nothing**; lands on `/no-project` |
| explicit `?project=` for a non-member | 403 + audited `scope.denied` |
| stale/forged project cookie | ignored, falls back — never widens |
| unknown role, missing user record, unreadable store | empty scope |
| derived counts (RAG totals, todo summary) | **recomputed** after filtering, never inherited |

Memberships are read from the store on **every request**, never carried in the
session cookie — so `pl console project unassign` takes effect on the next
request rather than when a cookie happens to expire.

### 6. Deliberately fleet-wide, and named as such

Notifications (one Gotify channel, the operator's phone) and the morning brief
stay owner-only and fleet-wide. They run at `scope.fleet_scope()` — a named
function so every intentional crossing of the boundary is greppable — and no
route reaches them.

## Consequences

### This is an APPLICATION boundary, not an OS one

**State this plainly, because nobody should later mistake it for more than it
is.** There is one Unix user, one `pl` checkout, one key set, one GitLab token,
one audit file and one snapshot on the console host. Anyone with a **shell** on that host
reads every project's data regardless of what `users.json` says. The boundary
constrains the *web application* and nothing else.

Therefore, **before the first external developer**, a Headscale ACL restricting
their node to the console port only — no `:22`, no ollama, no Gotify — is a
**hard prerequisite**. It is not part of this codebase and must not be assumed
by it.

A tenant who must not have another tenant's bytes on the same disk needs the
per-project snapshot path (§3) *plus* that ACL, and even then shares a host.
Genuine isolation means a second console instance.

### Other consequences

- Legacy audit entries have no `project` field and become **owner-only**. A
  backfill would have to guess, and a guess in an audit log is worse than an
  omission.
- Issue writes re-fetch the issue to check its labels rather than trusting the
  pane that offered the button, and **fail closed (502) when the tracker is
  unreachable** — an API outage must not become a write-anywhere window.
- Fleet-wide actions (`pl rag`) are refused to scoped callers outright.
  Filtering the output afterwards is not the same promise as never having run
  it on their behalf.
- Quokka's context cache is **per scope**; one shared cache would hand the
  first caller's fleet to the next caller's model.
- Rollback is `pl console project rm --all` → legacy mode, no restart.

## Alternatives considered

- **One snapshot file per project as the default** — rejected: second author,
  therefore drift (kept as an opt-in escape hatch, §3).
- **Filtering in each pane** — rejected: N places to forget. The whole design
  is that there is exactly one place, and a test that proves it.
- **`sites.<n>.group` in `nwp.yml` as the boundary** — rejected: the workstation
  is not the authority on who may see what, and a display label must never be
  load-bearing for permissions. It survives as a cosmetic sub-grouping only.
- **Carrying memberships in the session cookie** — rejected: a grant that lives
  in a cookie survives its own revocation.
