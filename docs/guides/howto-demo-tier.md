# How to: run the demo tier

**Who this is for:** whoever hosts the demo site that testers and reviewers try out.
**Last updated:** 2026-07-26

---

## What the demo tier is

A **demo site** is a full, working copy of Narrow Way Commons that invited people
can log into and play with freely — click everything, post things, break things —
because **it is wiped and rebuilt from a known-good starting point** on a regular
cycle.

That starting point is called the **golden image**. A reset means: throw away
everything that has happened since, put the golden image back, and re-seed the
sample content.

The demo pair is `nwd` (the Commons side) and `ssd` (the Saint School side).

Why it exists:

- Testers can be fearless. Nothing they do is permanent, so nothing needs approval.
- No real member data is ever in there, so there is nothing to leak.
- Every reset is a free rehearsal of the restore machinery.

---

## The five things you will actually do

### 1. Capture the golden image (once, and after deliberate changes)

```bash
pl demo golden nwd
```

This takes the site **exactly as it is now** and stores it as the state every
reset returns to: a database dump, a files archive, integrity fingerprints, and a
manifest, under `sites/nwd/demo-golden/`.

Do this when the site is in the state you *want* testers to start from — sample
content in place, no test rubbish, no leftover accounts.

**Log tables are captured as structure only, never as rows** (nwp/ops#168) —
`watchdog`, `sessions` and `flood` on Drupal; `mdl_logstore_standard_log` and
`mdl_task_log` on Moodle. A golden is restored onto the live demo site every
night, so a row inside it is *immortal*: it cannot age out, because the table
that would age it out is replaced from the image at 01:00. The 2026-08-01
goldens carried 36 `watchdog` rows (16 of them from ddev, with dev-path
backtraces) and 4,521 Moodle log rows across 299 public visitor IPs — and the
nightly harvest digest re-reported the identical two errors every night as a
result. Nothing is lost: the box wrapper harvests errors *before* the wipe, and
that digest is the record.

This takes effect at the **next** capture. Fixing the dump command does not
clean an already-stored golden.

### 2. Reset the site

```bash
pl demo reset nwd
```

What happens, in order:

1. **Harvest first.** Any errors testers hit since the last reset are collected
   into a digest *before* the wipe, so the evidence is not thrown away with the
   site. (`sites/nwd/demo-harvest/`)
2. Verify the golden image against its fingerprints.
3. Restore it.
4. Re-seed the demo content (`drush nwc:seed-demo`).
5. Re-sync the code and rebuild the caches.
6. Smoke-test the result — the home page and the join page must both answer.

Useful options:

```bash
pl demo reset nwd --if-idle 30m   # skip if anyone was active in the last 30 min
pl demo reset nwd --yes           # no confirmation prompt
pl demo reset nwd --skip-seed     # for non-Commons sites
```

`--if-idle` exits with status **3** if someone is mid-session. That is not an
error — it means "come back later", and it is logged as a skip.

### 3. Check on it

```bash
pl demo status nwd
```

Shows when the golden image was captured, the recent resets and skips, and a
summary of the invite codes (counts and IDs only — never the codes themselves).

Everything is also appended, one line per event, to `sites/nwd/demo-reset.log`.

### 4. Issue invitations

See the dedicated guide: [How to: issue demo invite codes](howto-invite-codes.md).

### 5. Put it on a schedule

```bash
pl demo schedule nwd            # install the nightly job on THIS machine
pl demo schedule nwd --tier=live
pl demo schedule nwd --remove
```

The nightly job runs `pl demo nightly nwd`, which:

- tries a reset at **01:00 Australia/Melbourne**;
- if anyone is active, waits 30 minutes and tries again;
- keeps retrying until a **04:00 floor**, then gives up and logs a skip rather
  than interrupting a tester.

> **Current state (2026-07-26):** the nightly schedule is **not installed**. It is
> meant to run on the build host, and installing it there needs an access decision
> the operator has not yet made. Until then the demo tier **resets on demand only**
> — you run `pl demo reset nwd --tier=live` yourself. Everything else is live and
> working: the cutover ran for real and scored 9/9.

---

## Where things live

| Path | What it is |
|------|------------|
| `sites/nwd/demo-golden/` | the golden image + fingerprints + manifest |
| `sites/nwd/demo-codes.json` | the invite-code registry — **hashes only**, survives the wipe |
| `sites/nwd/demo-reset.log` | one line per reset, skip and harvest |
| `sites/nwd/demo-harvest/` | error digests collected before each wipe |
| `sites/nwd/demo-invites/` | saved invitation drafts (these *do* contain plain codes) |

Note the design detail: the code registry is stored **outside** the golden image
and re-pushed into the site after every reset. That is why an invitation you sent
last week still works after tonight's wipe.

---

## Safety rails worth understanding

- **Three tiers, `--tier=dev` (default) | `stg` | `live`.** `dev` and `stg` are the
  local Docker pair. `live` acts on the real demo host over SSH: the golden image is
  a remote dump and archive pulled back and fingerprint-checked, and a reset uploads
  it, **re-verifies it on the remote**, then replaces the database and re-seeds.
- **`--tier=prod` is always refused**, and a live reset additionally refuses unless
  the remote site reports that it really is in demo mode. You cannot wipe a real
  site with this command by mistyping a tier.
- **The site manager role is never handed out.** The most powerful role on offer
  is Open Social's *content manager*. Nobody gets the keys to the whole site.
- **The demo site does not send email** and tells search engines not to index it.
- **A banner** makes it obvious to visitors that this is a demo that gets wiped.
- **The reset returns a real failure code** if the post-restore smoke test fails.
  A silent "FAIL" printed to the screen followed by success was a real bug; it is
  fixed.

---

## When something goes wrong

| Symptom | Likely cause | What to do |
|---------|--------------|------------|
| Reset exits 3 | someone was active within the idle window | expected — retry later, or `--force` |
| Reset fails on integrity | golden image damaged | re-capture with `pl demo golden nwd` from a known-good state |
| Codes stop working after a reset | registry was not re-pushed | `pl demo codes nwd sync --tier=live` |
| Codes never worked at all | they were issued against the wrong tier | `pl demo codes nwd list --tier=live` — if it is empty, reissue with `--tier=live` |
| Site looks wrong after reset | golden image captured in a bad state | fix the site, then re-capture the golden |

---

## Quick reference

| I want to… | Command |
|------------|---------|
| Set today's state as the baseline | `pl demo golden nwd` |
| Wipe and rebuild | `pl demo reset nwd` |
| Wipe only if nobody is on | `pl demo reset nwd --if-idle 30m` |
| See what's been happening | `pl demo status nwd` |
| Invite people | `pl demo invite nwd --tier=live` |
| Automate the nightly wipe | `pl demo schedule nwd` |

## See also

- [How to: issue demo invite codes](howto-invite-codes.md)
- [How to: back up and restore](howto-backup-restore.md)
- `~/central/DAILY-DEMO-TIER-PROPOSAL-2026-07-25.md` — the design and the decisions behind it
