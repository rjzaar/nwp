# How to: the disaster-recovery chain

**Who this is for:** whoever is responsible for the fleet surviving a fire, a
ransomware attack, or a mistake.
**Last updated:** 2026-07-25

---

## The problem this solves

Ordinary backups fail in three ways:

1. The backup lives on the same machine that just burned down.
2. An attacker who takes over the server also deletes the backups.
3. The backups quietly keep copies of people's personal data long after you
   promised to delete it.

The NWP disaster-recovery chain answers all three.

---

## The shape of it, in one picture

```
  PROD SERVER                          ver  (offline custodian)
  ───────────                          ────────────────────────
  raw snapshot ──────────┐
   (all real data)       │  PULL ───▶  durable raw repo      kept 30 days max
                         │             (encrypted, off-box)
  sanitized snapshot ────┘  PULL ───▶  durable sanitized repo  kept for years
   (people scrubbed out)                (no personal data in it)
```

Three properties do the work:

- **Pull, not push.** `ver` reaches out and takes the snapshots. The production
  server holds **no credential that can delete ver's copy**. Ransomware on the
  web server cannot reach the backups.
- **Offline by default.** `ver` is a machine that is switched off and disconnected
  most of the time. It comes online, pulls, verifies, and goes away. It is never
  on the home network mesh, and no AI-operated machine can reach it.
- **Two tiers.** Raw data (with real names and emails in it) is deleted after 30
  days. Sanitized data (with the people scrubbed out) can be kept for years,
  because there is nothing left in it to leak.

---

## Step 1 — the production server makes snapshots

Run **on the production host**, via the AI-free `nwp-server` tool:

```bash
# Raw — everything, for restoring the site as it really was.
nwp-server backup --site-dir /var/www/mysite --execute

# Sanitized — same site, but every member replaced with fake data.
nwp-server backup --site-dir /var/www/mysite --sanitize --execute
```

Both are **dry-run by default**. Nothing happens without `--execute`.

Notes worth knowing:

- The tool works out for itself whether the site is Drupal or Moodle and backs up
  the right things.
- `--sanitize` keeps **one** account — the site's real administrator — and scrubs
  everybody else. On Drupal that is user 1; on Moodle it is whoever is listed in
  the site's `siteadmins` setting (which is usually *not* user 1).
- After sanitizing, an independent checker scans the output for anything that
  looks like personal data. **If it finds any, the backup fails and is not
  written.** It fails closed, on purpose.
- The sanitized snapshot goes into a completely separate store named
  `<site>-sanitized`, so the two tiers can never be confused for each other.
- The copy on the production server is short-term staging only (3 snapshots).
  The real archive is on `ver`.

---

## Step 2 — ver pulls the snapshots

Run **on ver**, during its scheduled online session:

```bash
# Raw source: an erasure ceiling is COMPULSORY.
ver backup pull \
  --from sftp:prod-over-tunnel:/var/backups/nwp-server/mysite \
  --to   /srv/ver-backups/mysite \
  --kind raw --keep-within 30d --execute

# Sanitized source: keep the long tiered history.
ver backup pull \
  --from sftp:prod-over-tunnel:/var/backups/nwp-server/mysite-sanitized \
  --to   /srv/ver-backups/mysite-sanitized \
  --kind sanitized --execute
```

`--kind raw` **without** `--keep-within` is refused. That refusal is the whole
point: without it, raw snapshots would quietly fall through to the long policy
(7 daily / 8 weekly / 12 monthly) and personal data would survive for about a
year — silently contradicting the 30-day promise made to members.

After draining, the tool prunes old snapshots and runs an integrity check
(`restic check`, re-reading a percentage of the actual data, not just the index).

The connection is a dedicated one-to-one encrypted tunnel where `ver` and that
production server are the only two participants.

---

## Step 3 — prove it works, on purpose, regularly

A backup you have never restored is a rumour. The drill:

1. Restore a **sanitized** snapshot to a scratch location → the personal-data
   checker should **pass** (it is clean).
2. Restore a **raw** snapshot to a scratch location → the checker should **fail**
   (it is supposed to have real data in it).

If the raw restore *passes* the checker, something is wrong: either the restore
did not work, or the raw tier is not actually raw.

---

## Rehearsing the whole chain without touching anything real

There is a harness that builds two throwaway servers, runs the entire chain on
them for real, scores it, and destroys them:

```bash
pl ver-test provision        # create the stand-in custodian
pl ver-test provision-prod   # create a throwaway production site with fake members
pl ver-test cycle            # run the full chain, print a PASS/FAIL scorecard
pl ver-test status           # what exists right now
pl ver-test teardown         # DELETE both servers and verify they are gone
```

It last ran on 2026-07-25 and scored **16/16** — see
[the run report](../reports/consolidation-arc-2026-07/ver-harness-run-2026-07-25.md).

> ⚠️ **Never point `pl ver-test` at the real ver or a real production host.** It
> only ever creates fresh, tagged, disposable servers, records their IDs in a
> ledger the moment they exist, and refuses to declare success on teardown until
> it has confirmed they are gone. **Always run `teardown`** — these are billable.

The harness deliberately differs from the real thing in four places (plain SSH
instead of the WireGuard tunnel; a plain-file stand-in for the hardware-sealed
key store; a throwaway signing key; and root instead of a locked-down backup
user). Everything else is the real script.

---

## Restoring for real

The DR restore path is deliberately manual and deliberately on `ver`. Read
[ops83-dr-restore.md](ops83-dr-restore.md) before you need it, not during.

The one rule to remember under pressure: if the site's log-ins are **paired** with
another site (Narrow Way Commons ↔ Saint School), you must restore both halves to
the same point in time, or roll both forward. Restoring one alone severs members'
identities.

---

## Quick reference

| I want to… | Command | Where |
|------------|---------|-------|
| Snapshot a production site | `nwp-server backup --site-dir DIR --execute` | prod host |
| Snapshot it with people scrubbed out | add `--sanitize` | prod host |
| Pull raw snapshots off-box | `ver backup pull … --kind raw --keep-within 30d --execute` | ver |
| Pull sanitized snapshots off-box | `ver backup pull … --kind sanitized --execute` | ver |
| Rehearse the whole chain safely | `pl ver-test provision && pl ver-test cycle` | your machine |
| Tear the rehearsal down | `pl ver-test teardown` | your machine |

## See also

- [ver-setup.md](ver-setup.md) — building and setting up `ver`
- [ver-provisioning-runbook.md](ver-provisioning-runbook.md) — the step-by-step provisioning sequence
- [ops83-dr-restore.md](ops83-dr-restore.md) — the paired-site restore rule
- [How to: back up and restore](howto-backup-restore.md) — the everyday, local kind
- NWP-ADR-0025 (backup custody) and NWP-ADR-0017 (the distributed build/deploy pipeline)
