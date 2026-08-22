# Box-level disaster recovery (`pl server backup`)

**Status:** live on `live` since 2026-08-02 · **Implements:** [NWP-ADR-0025](../decisions/0025-production-backup-to-ver.md) · **Agent:** [NWP-ADR-0026](../decisions/0026-nwp-server-capability-agent.md)

## What was missing

On 2026-08-01, the box serving every live site had three things that look like backups
and one thing it did not have.

| Existing | What it holds | What it cannot do |
|---|---|---|
| `pl backup <site> --remote` | one site's webroot tar + DB dump, pulled to the workstation | it is per-site and on demand; nothing schedules it, and it does not carry `/etc`, the grants, or the moodledata trees for sites it was not run against |
| `pl server-state capture <name>` | host **config** state, scrubbed, in git | deliberately carries no data and no secrets — it is an inventory, not an archive |
| `/etc/cron.d/nwp-box-backup` (01:30) | 16 `mysqldump`s + an nginx tarball into `/var/backups/nwp-pull` | databases only. No files, no `/etc`, no certificates, no grants, no verification, 2-day retention |

Missing: **any archive from which the host could be rebuilt**, and any check that the
archive could be read back.

Two findings from building this, both recorded so they are not re-discovered:

1. **The off-box leg still points at the pre-split box.** `met`'s nightly
   `nwp-stick-backup` still names the **`nwpcode`** box by IP,
   which stopped serving the sites at the 2026-07-31 split. It reports `ok` every night
   because it successfully pulls a box that is no longer the one that matters. A green
   backup light over the wrong host is worse than a red one. **Operator action** — see
   [Still not protected](#what-this-still-does-not-protect-against).
2. **`live` answers `git` to `hostname -s`.** It is a clone of the forge box and the
   hostname was never changed. The archive is therefore filed under the NWP **server
   record** name (`live-system`), not the host's own idea of itself.

## What it does

`pl server backup <name>` is the control-host front door to the **NWP-ADR-0025** agent. It
does not carry data. It preflights headroom, then invokes `nwp-server backup --host` **on
the box**, which writes an encrypted restic repository **local to the box**. A custodian
(`ver`) later *pulls*. The box holds no credential that can delete the durable copy.

Scope of `--host`, i.e. what a rebuild gets back:

- **config** — `/etc` (nginx, letsencrypt, postfix, cron, sshd, ufw, fail2ban, php),
  `/usr/local`, `/root`, `/opt`, plus a generated manifest: `dpkg --get-selections`,
  `apt-mark showmanual/showhold`, enabled systemd units, `df`/mounts/addresses,
  the resolved `nginx -T`, every user's crontab, and **replayable `CREATE USER` +
  `GRANT` statements**.
- **db** — one gzipped `mysqldump` per non-system schema, each verified to carry the
  `Dump completed` trailer (a truncated dump still produces a valid gzip stream).
- **web** — everything under `/var/www`: webroots *and* the moodledata trees that live
  outside them.

Not included by default: `/home` (on `live` that is ~10 GB of transient `pl` snapshot
droppings that this very backup supersedes) and the `mysql` system schema (its grants
are captured as replayable SQL instead, which is the form a restore can apply). The plan
says so on every run, whether or not the host has a `/home`.

### Reproducing a runner's tool set

`NWP_RESTIC_BIN` and `NWP_SBH_ABSENT` exist so that "this host has no restic" and "this
host has no `mysqldump`" are conditions a caller can *state* rather than inherit:

```bash
NWP_RESTIC_BIN=/nonexistent/restic pl server backup live      # behave as a host without restic
NWP_SBH_ABSENT=mysqldump,mysql     …                          # behave as a host without the client
```

They were added after three of this feature's tests passed on a laptop and failed on the
CI runner: the machine, not the test, was deciding which guard fired. The suite now runs
identically under both tool sets (79/79 either way) and skips nothing under either — a
test that quietly skips on the runner removes coverage without turning anything red.

## Running it

```bash
pl server health live                     # the preflight; the verb runs it too
pl server backup live --install           # once per box: restic + agent + repo password
pl server backup live                     # dry-run plan: sizes, paths, disk projection
pl server backup live --execute           # take it (fate manifest + confirm)
pl server backup live --status            # repo size + snapshots
pl server backup live --verify            # restic check --read-data-subset=5%
pl server backup live --restore-test      # restore a stratified sample, byte-compare
pl server backup live --schedule          # dry-run the nightly cron entry
pl server backup live --schedule -y       # install it
```

`--verify` proves **integrity**. `--restore-test` proves **recoverability** — it restores
real files out of the archive and compares sha256 against what is still on the box, and
restores one database dump and checks it is a complete `mysqldump`. NWP-ADR-0025 is explicit:
a backup that has not been test-restored is not counted as a backup. Run the drill after
any change to the tooling, and monthly regardless.

The sample is **stratified**, not uniform: 96% of the 585k files in the archive are
`vendor/` trees, so a uniform draw of a dozen files would prove the vendor directories
restore and prove nothing about `/etc`, `/root`, or moodledata. One file is taken from
each of N randomly chosen distinct areas, so each drill sweeps a different dozen.

## First real run (2026-08-02, server record `live`)

| | |
|---|---|
| repo | `/var/backups/nwp-server/live-system` (825 MB on disk) |
| repo `config` sha256 | `605fc259aaa696e1dc9c2722dca256e3f485d7d3cf65d84e5e983ed571ed182e` |
| box snapshot | 585,845 files / 4.93 GiB logical → 677 MiB stored |
| state snapshot | 29 files / 128.8 MiB (16 databases + manifest) → 77 MiB stored |
| compression | 2.52× (60.3% saved) |
| second run delta | box +18 KiB stored, state +12.3 MiB — dedup working |
| `restic check --read-data-subset=5%` | **no errors were found** |
| restore drill | **13 passed, 0 failed** across `/etc`, `/opt`, `/root`, `/usr/local`, `/var/www`, plus `avc.sql.gz` restored and confirmed a complete dump |
| duration | ~4 min first run, ~50 s subsequent |
| disk after | 45 GB free of 78 GB (43% used) |

Scheduled: `/etc/cron.d/nwp-server-backup-live`, `20 4 * * *` — after the legacy 01:30
job and clear of the 01:00–03:00 demo-reset window. Verified installed with the cron
daemon `active`, and the exact command line proven to work in a stripped cron-like
environment before it was scheduled.

## What was installed, and how to take it back out

Everything below is reversible and nothing else on the box was touched.

| # | Installed on `live` | Reverse |
|---|---|---|
| 1 | `restic` 0.16.4-2ubuntu0.24.04.3 (Ubuntu archive, `--no-install-recommends`) | `apt-get remove restic` |
| 2 | `/etc/nwp-server/` (0700) with `restic.pass` (0600, generated on the box, never transmitted) | `pl server backup live --uninstall --purge-repo` |
| 3 | `/opt/nwp-server/` — the AI-free artifact (31 files, deny-scan clean) | `pl server backup live --uninstall` |
| 4 | `/var/backups/nwp-server/live-system` — the restic repo (825 MB) | `pl server backup live --uninstall --purge-repo` |
| 5 | `/etc/cron.d/nwp-server-backup-live` | `pl server backup live --unschedule -y` |
| 6 | `/var/log/nwp-server-backup.log` | `rm` it; nothing depends on it |

`--purge-repo` deletes `restic.pass`, which makes **every snapshot in those repos
permanently unreadable**. It therefore requires a typed confirmation, not a `y`.

## What this still does not protect against

Be precise about this, because a backup people over-trust is its own failure mode.

**Protected:** accidental deletion, a bad deploy, config drift, database corruption,
a site trashed by an upgrade, ransomware that encrypts webroots without finding
`/var/backups`, and the ordinary case of "what did `/etc/nginx` look like last Tuesday".

**NOT protected:**

- **Loss of the host.** The archive is on the disk it backs up. If the Linode is
  destroyed, the disk fails, or the account is lost, the archive goes with it. This is
  by design — NWP-ADR-0025 puts the durable copy on `ver`, which **is not provisioned**. This
  is the single biggest remaining gap and the reason the verb warns on every run.
- **An attacker with root on the box.** `restic forget --prune` runs locally. Root can
  delete the repo. The anti-ransomware property in NWP-ADR-0025 comes from the *pull* tier,
  which does not exist yet.
- **Anything after the last run.** RPO is 24 h (the 04:20 cron), not continuous.
- **`/home`,** unless you pass `--extra-path=/home`.
- **The `mysql` system schema** as a schema. Accounts and grants are captured; a restore
  replays them rather than dropping the old `mysql` database in.
- **Silent divergence between the archive and reality** *between* drills. `--verify`
  checks integrity every time; only `--restore-test` checks recoverability, and only for
  the sample it drew.

### To close the host-loss gap (operator decisions, not code)

1. **Repoint `met`'s pull at `live`.** One line in `/usr/local/sbin/nwp-stick-backup`
   (`BOX=`), plus a decision about whether the stick pulls the raw restic repo (which
   would need the read-only `rrsync` jail widened from `/var/backups/nwp-pull` to
   `/var/backups`, or a second jailed key). Requires root on `met`.
2. **Or provision `ver`** and run the real NWP-ADR-0025 pull leg, which is already written
   and harness-proven end to end (`pl ver-test`):

   ```bash
   ver backup pull --from sftp:<live-over-tunnel>:/var/backups/nwp-server/live-system \
                   --to /srv/ver-backups/live-system --kind raw --keep-within 30d --execute
   ```

   `--kind raw` is not optional: the archive carries unsanitised member data, and the
   pull verb refuses to drain a raw source without an erasure ceiling.

Until one of those lands, the honest status of `live` is: **backed up on-box, verified,
restorable — and not yet surviving loss of the box.**

## Related

- [NWP-ADR-0025](../decisions/0025-production-backup-to-ver.md) — restic, custodian-pull, append-only
- [NWP-ADR-0026](../decisions/0026-nwp-server-capability-agent.md) — the AI-free agent this extends
- `pl server health` — the preflight this verb refuses to skip
- `pl server-state capture` — the git-tracked config inventory (complementary, not a backup)
- `pl ver-test` — the throwaway-Linode harness that proves the full chain
