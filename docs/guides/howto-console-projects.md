# How-to: onboard a developer onto the console without showing them everything

**Last Updated:** 2026-07-26

The console can show a person **only the sites of the projects they belong to**.
This guide takes you from "another dev needs access" to "they can see exactly
the Saint School / Narrow Way sites and nothing else".

See [ADR-0033](../decisions/0033-console-multi-tenant-projects.md) for the
design and — importantly — for what this boundary is *not*.

> **Read this first.** Project scoping is an **application** boundary. Anyone
> with a **shell** on the console host reads every project's data whatever
> `users.json` says. Before an external developer gets a device on the mesh,
> a Headscale ACL restricting their node to the console port only (no SSH, no
> ollama, no Gotify) is a **hard prerequisite**.

---

## 0. Nothing changes until you create a project

With no projects, the console behaves exactly as it always has: every
authenticated user sees the whole fleet, bounded only by their global role.
Creating the first project is what turns scoping on.

```bash
pl console project list        # "no projects — the console is in legacy mode"
```

## 1. Create the project

```bash
pl console project add ss-nw \
    --name "Saint School + Narrow Way" \
    --sites nwc ssc nwd ssd ss ss2 saintschool \
    --demo-sites nwd \
    --issue-label project::ss-nw \
    --ci-projects nwp/nwc
```

What each field actually gates:

| field | effect |
|---|---|
| `--sites` | the ONLY sites members see, anywhere in the console |
| `--demo-sites` | which of those demo actions may touch (must be a subset) |
| `--issue-label` | members see only issues carrying this label. **Omit it and they see no issues at all** — never "all" |
| `--ci-projects` | members see/retry only these pipelines. Omit ⇒ no CI |

Sites you do **not** assign to any project stay **owner-only** automatically.
That is the fail-closed default and needs no configuration.

> A site may belong to **at most one** project. Trying to put it in a second is
> refused, and the refusal names the project that already holds it — silently
> reassigning a site would move data between tenants.

## 2. Create the developer's account, with their membership

Do it in one command so the account is never briefly project-less:

```bash
pl console user add dana --role operator --project ss-nw --project-role operator
```

This prints a **one-time enrolment link** (48 h, single use). Send it to them;
the token is stored hashed and cannot be re-shown.

Their device must be on the mesh first — `pl console enroll` prints that
runbook. **Add the ACL from the warning above at this step.**

### The two role axes

| axis | values | governs |
|---|---|---|
| global (`--role`) | viewer / operator / owner | the console itself |
| project (`--project-role`) | viewer / operator / maintainer | one project |

The global role is a **ceiling**: a global `viewer` recorded as a project
`maintainer` is still, in effect, a viewer. That is what makes handing out
project maintainership safe.

A project `maintainer` may assign *existing* users to *their own* project at a
role no higher than their own. Only a global **owner** may create projects,
create users, or **change a project's site list** — because changing the site
list *is* a permission grant.

## 3. Check what they will actually see

```bash
pl console user show dana
```

```
user:        dana
global role: operator
passkeys:    1
projects:    ss-nw (operator)
             sites: nwc nwd saintschool ss ss2 ssc ssd
```

If it says `projects: none  -> this user sees NOTHING`, they will land on the
"you are not in a project yet" page. That is deliberate — an empty-looking
dashboard would read as "the fleet is fine".

## 4. Day-to-day

```bash
pl console project list                              # projects, sites, members
pl console project assign sam ss-nw --role viewer     # add someone
pl console project unassign sam ss-nw                 # remove someone
pl console project set ss-nw --sites nwc ssc nwd      # change the site list (a GRANT)
pl console project rm ss-nw                           # deletes + revokes every membership
```

The same operations are on the web UI at **/projects** (owner only).

In the browser, the **scope bar** under the header always states which project
you are looking at and lists its sites. Members with more than one project get
a picker; an owner additionally gets "All projects".

## 5. Export the map for the workstation

Some workstation-side tooling (the per-project publish path, and the Stage 4
doc-library gate) needs to know which sites belong to which project:

```bash
pl console project export        # -> private/project-map.json (0600, gitignored)
```

The console host is the single **author** of that map; the workstation only
ever receives a copy. It contains no user, credential or token data.

## 6. Rolling it back

```bash
pl console project rm ss-nw      # ...and any others
```

With no projects left the console returns to legacy mode immediately. No
restart, no migration, no data loss.

## Troubleshooting

| symptom | cause |
|---|---|
| user sees "not in a project yet" | no membership — `pl console project assign` |
| Issues tab empty for a member | no `issue_label` on the project, or nothing carries it (the pane says which) |
| CI tab empty for a member | no `ci_projects` on the project |
| "fleet-wide action: run it unscoped" | `pl rag` sweeps every site; it cannot be narrowed to a project |
| "site X already belongs to project Y" | a site may be in only one project |
| member can't edit the site list | correct — that is an owner-only permission grant |
