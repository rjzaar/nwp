# How to: back up and restore a site

**Who this is for:** anyone looking after an NWP site. No prior knowledge assumed.
**Time:** a backup takes seconds to a few minutes. A restore takes a few minutes.
**Last updated:** 2026-07-25

---

## What a "backup" actually is here

A site is two things: a **database** (all the text, accounts and settings) and
**files** (uploaded images, documents, and the site's code). A backup captures one
or both.

NWP writes backups to a folder inside the site:

```
sites/<sitename>/backups/
```

Each backup is one *set* of files that belong together:

| File | What it holds |
|------|---------------|
| `…sql.gz` | the database, compressed |
| `…tar.gz` | the files/code, compressed |
| `….sha256` | a fingerprint used to prove the backup was not damaged |

The name tells you when and what: `20260725T143022-main-a1b2c3d4-before_upgrade.sql.gz`
= 25 July 2026, 14:30:22, from git branch `main`, commit `a1b2c3d4`, message
"before upgrade".

> **Fingerprints matter.** Since the 2026-07 consolidation work, restoring checks
> the `.sha256` fingerprint *before* it overwrites anything. If the backup was
> corrupted or tampered with, the restore stops instead of destroying your site
> with a bad copy.

---

## The everyday commands

### Take a backup before you change anything

```bash
pl backup mysite "before the module upgrade"
```

That is the habit worth forming: a message describing *why* you took it. The
message becomes part of the filename, so future-you can find it.

Faster variant — database only (usually all you need, because the code is in git):

```bash
pl backup -b mysite "before the module upgrade"
```

### Back up every site that has gone stale

```bash
pl backup sweep --dry-run     # show what it would do, change nothing
pl backup sweep               # actually do it
```

"Stale" means the newest backup is older than the warning threshold (7 days by
default). Sweep backups are database-only. Sites whose DDEV container is stopped
are skipped unless you add `--start-stopped`.

### Take a backup of the LIVE site (not your local copy)

```bash
pl backup mysite --remote --dry-run   # preview
pl backup mysite --remote -y          # do it
```

This reaches out to the real server and pulls back a snapshot. It is read-only
against live — it cannot break the live site. This is the safety net you take
*before* a deploy, and some commands (`pl cutover`, `pl moodle deploy`) refuse to
run without it.

### Take a backup with no personal data in it

```bash
pl backup --sanitize mysite
```

"Sanitized" means real member names, email addresses and other personal data are
replaced with fake ones. Use this whenever a copy is going somewhere less trusted
than the live server — for example onto a developer laptop.

---

## Restoring

### Restore a site from its newest backup

```bash
pl restore mysite
```

You will be shown a list and asked to pick. To skip the prompts and take the
newest automatically:

```bash
pl restore -fy mysite
```

Database only (leave the files/code alone):

```bash
pl restore -b mysite
```

Restore one site's backup **into a different site** — handy for making a scratch
copy to experiment on:

```bash
pl restore mysite mysite2
```

### What the restore does, in order

1. Pick the backup.
2. **Verify its fingerprint.** A mismatch aborts here — nothing is overwritten.
3. Check the destination is a real site.
4. Unpack the files.
5. Fix the settings file and file permissions.
6. Load the database.
7. Clear the cache.

### Things that will (correctly) stop you

| You see | What it means | What to do |
|---------|---------------|------------|
| integrity/sha256 mismatch | the backup file does not match its fingerprint | do **not** use `--skip-verify`; find another backup and investigate why this one changed |
| a paired-site restore gate | this site's identity is linked to another site (e.g. Narrow Way Commons ↔ Saint School log-ins) and restoring only one half would break the link | restore both halves, or roll forward; see [ops83-dr-restore.md](ops83-dr-restore.md) |

`--skip-verify` exists but only skips the check on backups that *have* a
fingerprint. An older backup without one is allowed through with a notice either
way. Do not reach for it.

---

## Undoing a deploy (different from a restore)

A **restore** puts a backup back. A **rollback** undoes the last deployment to a
server:

```bash
pl rollback list mysite                    # what can I go back to?
pl rollback execute mysite prod --dry-run  # what would happen?
pl rollback execute mysite prod            # do it
```

---

## Keeping the backup folder from filling the disk

Backups are deleted after 30 days, but only when you (or a schedule) ask:

```bash
pl backup prune --dry-run     # show what would go
pl backup prune               # delete backups older than 30 days
pl backup prune --days 14     # a tighter window
pl backup prune --site mysite # one site only
```

**The newest backup of each site is always kept**, no matter how old it is. You
can never prune yourself down to zero.

Why 30 days? Because members are told their data is removed within 30 days.
Keeping backups longer than that would quietly break the promise. The default
lives in `settings.todo.thresholds.backup_retention_days`.

> The same 30-day ceiling is enforced separately on the off-site disaster-recovery
> copies. See [How to: the disaster-recovery chain](howto-dr-chain.md).

---

## Doing it automatically

```bash
pl schedule install mysite     # daily DB 02:00, weekly full 03:00 Sun, monthly bundle
pl schedule install-sweep      # nightly sweep of every site instead
pl schedule list               # what is scheduled
pl schedule run mysite         # test it now
pl schedule remove mysite
```

---

## Quick reference

| I want to… | Command |
|------------|---------|
| Back up before a risky change | `pl backup mysite "why"` |
| Back up just the database | `pl backup -b mysite` |
| Back up every stale site | `pl backup sweep` |
| Snapshot the live server | `pl backup mysite --remote -y` |
| Back up with no personal data | `pl backup --sanitize mysite` |
| Restore from the newest backup | `pl restore -fy mysite` |
| Restore the database only | `pl restore -b mysite` |
| Undo the last deploy | `pl rollback execute mysite prod` |
| Tidy old backups | `pl backup prune` |
| Automate it | `pl schedule install mysite` |

## See also

- [How to: deploy a change](howto-deploy.md)
- [How to: the disaster-recovery chain](howto-dr-chain.md)
- [ops83-dr-restore.md](ops83-dr-restore.md) — the paired-site restore rule in detail
