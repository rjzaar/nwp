# How to: deploy a change (dev → staging → live)

**Who this is for:** anyone pushing a change out to a real site.
**Prerequisite:** you have a working local copy of the site and a backup habit.
**Last updated:** 2026-07-25

---

## The four places a site can live

| Name | Where it is | Who sees it | What it is for |
|------|-------------|-------------|----------------|
| **dev** | your own machine, in Docker (DDEV) | just you | building and breaking things |
| **stg** (staging) | also your own machine, in Docker | just you | a dress rehearsal that looks like the real thing |
| **live** | a real server on the internet (`*.nwpcode.org`) | anyone with the link | testing in public conditions |
| **prod** | the real production server | actual members | the thing that must not break |

On disk: `sites/<name>/dev/` and `sites/<name>/stg/`.

The normal direction of travel is **left to right**. Content, however, often
travels **right to left** — you pull the real database back down so staging looks
like reality. That is why there is a command for each direction.

```
   dev  ──pl dev2stg──▶  stg  ──pl stg2live──▶  live  ──pl live2prod──▶  prod
                          ◀──pl live2stg────           ◀──pl prod2stg────
```

---

## Before you start: which way does content flow?

Every site has a **canonical phase** that answers one question: *where does the
real content live?*

```bash
pl canonical show mysite    # dev, live or prod
pl canonical check mysite   # which safety rules are therefore switched on
```

- **`dev`** — the real content is your local copy. Pushing the database outward is fine.
- **`live` / `prod`** — the real content is out on the server, created by real
  people. Pushing your local database outward would **destroy their work**, so
  NWP refuses to do it unless you explicitly say so.

There is a second, separate axis — **maturity** — which governs how carefully
*code* moves:

```bash
pl maturity show mysite     # incubating | stabilizing | production
```

Both are ledgers: every change is recorded with who and when.

---

## Step 1 — dev to staging

```bash
pl dev2stg mysite
```

Run with no options and it shows an interactive menu. The useful options:

```bash
pl dev2stg mysite -y -t essential      # non-interactive, run the essential tests
pl dev2stg mysite --preflight          # only run the checks; deploy nothing
pl dev2stg mysite --db-source production   # rehearse against real-shaped data
```

By default the database is **sanitized** on the way in — real personal data is
replaced with fake data. `--no-sanitize` exists; do not use it on a database that
came from real people.

If staging does not exist yet you will be offered to create it (`--create-stg` to
answer yes up front).

---

## Step 2 — staging to the live server

First, make sure there *is* a live server:

```bash
pl live mysite            # provision mysite.<your-live-domain>
pl live --status mysite
```

Then rehearse, then go:

```bash
pl stg2live mysite --dry-run    # snapshot + preview only, aborts before any write
pl stg2live mysite
```

### The one rule that matters most

> **If the site is canonical `live` or `prod`, deploy code only:**
>
> ```bash
> pl stg2live mysite --code-only
> ```

`--code-only` sends the code and configuration and leaves the live database
alone. Pushing a whole database over a live site rewrites every internal user ID,
which severs single-sign-on links between paired sites — members simply stop
being able to log in. This is a standing rule for Narrow Way Commons.

If you genuinely mean to overwrite the live content you must say so twice:
`--push-content`, and `--override-canonical` if the site is not canonical `dev`.
Both are recorded in `private/canonical/<site>.log`.

### The guards you may hit, and what they mean

| Guard | Plain meaning | Override (think first) |
|-------|---------------|------------------------|
| Pre-deploy snapshot failed | a full copy of the live webroot could not be taken, so the deletion step would be unrecoverable | `--override-snapshot` |
| Paired-site guard | this site's log-ins are tied to a partner site; deploying out of order breaks them | `--override-pair` |
| Profile-change guard | the site's Drupal install profile changed; `--code-only` cannot cross that and the site would not boot | `--allow-profile-change` (almost always wrong) |
| Configuration drift | someone changed settings directly on the server and your deploy would silently wipe them | see [CONFIG_AS_CODE.md](../CONFIG_AS_CODE.md) |

Every override is written to a ledger. None of them are routine.

---

## Step 3 — live (or staging) to production

```bash
pl stg2prod mysite      # staging → production
pl live2prod mysite     # live → production
```

Both now carry the same guard stack as `stg2live`: take a snapshot first, put the
site into maintenance mode, and **stop** if any of that fails. Specifically, if
switching maintenance mode on fails, the deploy aborts *before* the step that
deletes files. It fails safe, not fast.

### Production needs a hardware key

Writes to production are gated by a physical security key (a Solo 2) that you
must touch, with a PIN. No AI-operated machine holds a key that reaches
production — that boundary is deliberate and not negotiable.

```bash
pl deploy-gate status    # is the gate configured?
pl deploy-gate test      # prove your key works, before you need it
```

If the gate is not configured, the deploy stops. That is the gate working.

---

## Pulling reality back down

```bash
pl live2stg mysite       # pull the live site into local staging
pl prod2stg mysite       # pull production into local staging
```

Both sanitize the database on the way down by default. That is what makes it safe
for the copy to sit on a laptop.

```bash
pl live2stg mysite --db-only
pl live2stg mysite --files-only
```

---

## Running a database command on a remote site

Never SSH in and run `drush` by hand. Use:

```bash
pl drush mysite --tier=stg -- cr                    # rebuild caches on staging
pl drush mysite --tier=live -- status                # live: DRY RUN by default
pl drush mysite --tier=live --execute -- cr          # actually run it
```

Live is dry-run unless you say `--execute`. That is on purpose.

---

## If it goes wrong

```bash
pl rollback list mysite
pl rollback execute mysite prod --dry-run
pl rollback execute mysite prod
```

And for the local copies, see [How to: back up and restore](howto-backup-restore.md).

---

## Quick reference

| I want to… | Command |
|------------|---------|
| See where the real content lives | `pl canonical show mysite` |
| Rehearse locally | `pl dev2stg mysite -y -t essential` |
| Preview a live deploy safely | `pl stg2live mysite --dry-run` |
| Deploy code but keep live content | `pl stg2live mysite --code-only` |
| Deploy to production | `pl stg2prod mysite` (hardware key required) |
| Pull real data back to staging | `pl live2stg mysite` |
| Run drush remotely | `pl drush mysite --tier=live --execute -- cr` |
| Undo | `pl rollback execute mysite prod` |

## See also

- [How to: back up and restore](howto-backup-restore.md)
- [CONFIG_AS_CODE.md](../CONFIG_AS_CODE.md) — the configuration-drift gate
- [developer-workflow.md](developer-workflow.md) — the wider development lifecycle
