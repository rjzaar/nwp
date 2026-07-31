# nwd nightly demo reset — restricted key + met handover

**Status:** box side LIVE (2026-07-25) · laptop cron INTERIM · met handover PENDING (met away)
**Issue:** ops#133 · **Branch:** `feat/demo-nightly-restricted-key`

---

## 1. Why a restricted key at all

`pl demo reset nwd --tier=live` drives the nightly wipe over ssh as `gitlab@`.
`gitlab@` on `git.nwpcode.org` has `(ALL) NOPASSWD: ALL` — that box also runs
GitLab and five live sites, so **a plain `gitlab@` key on met would be root on
the forge box.** Standing rule: never.

Option A instead gives met a key that can invoke exactly **one program**:

```
command="/usr/local/bin/nwd-demo-reset-restricted",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding ssh-ed25519 AAAA… nwd-demo-reset@met
```

Same pattern as the existing `nwp-dr-pull@met` rrsync jail two lines above it in
the same `authorized_keys` — different payload.

| | plain `gitlab@` key | restricted key |
|---|---|---|
| arbitrary commands | yes | **no** (refused + logged) |
| sudo / root | yes | **no** |
| shell / PTY | yes | **no** |
| scp / sftp | yes | **no** |
| port forwarding | yes | **no** |
| reads `/etc/gitlab/gitlab-secrets.json` | yes | **no** |
| runs the nwd demo reset | yes | yes |

---

## 2. What is installed where

| Where | What | Owner/mode |
|---|---|---|
| box `/usr/local/bin/nwd-demo-reset-restricted` | the wrapper (versioned at `servers/sites1/demo/nwd-demo-reset-restricted`) | `root:root 0755` |
| box `/var/lib/nwp-demo/nwd/golden/` | golden DB + files + sha256 sidecars + manifest | `root:root 0644` |
| box `/var/lib/nwp-demo/nwd/codes-payload.json` | **hashed** invite codes (never plaintext) | `root:root 0644` |
| box `/var/lib/nwp-demo/nwd/last-reset` | idempotence stamp (Melbourne date + epoch) | `gitlab` |
| box `/var/lib/nwp-demo/nwd/harvest/` | pre-wipe watchdog digests, last 30 kept | `gitlab` |
| box `/var/log/nwp-demo/nwd-demo-reset.log` | one line per invocation, logrotate weekly ×8 | `gitlab` |
| box `~gitlab/.ssh/authorized_keys` | the forced-command entry (backups kept as `authorized_keys.bak-*`) | `gitlab 0600` |
| workstation `~/.ssh/nwd_demo_reset` | the private key (to be copied to met) | `rob 0600` |
| workstation `crontab` | **INTERIM** nightly, marked in the crontab comment | |

The wrapper needs **no repo checkout on the box and none on the scheduler** —
met will hold only the private key.

---

## 3. Action words (the only client input that is honoured)

`$SSH_ORIGINAL_COMMAND` is logged verbatim and then matched against a fixed
literal allowlist. It is never evaluated, never expanded into a command
position, never passed to `sh -c`.

| word | meaning | exit |
|---|---|---|
| *(empty)* / `nightly` | guarded reset; **no-op if already reset today** | 0 ok/no-op · 3 active · 1 fail |
| `reset` | same, but ignores the daily stamp (still rate-limited, still idle-guarded) | as above |
| `dry-run` | run every guard, change nothing | 0 / 1 |
| `status` | golden info + last 15 log lines | 0 |
| anything else | **refused**, logged as `rejected-command`, nothing executed | 2 |

---

## 4. Guarantees the wrapper enforces

1. **No client command is ever executed.** Allowlist of literal words only.
2. **Target is hard-wired to nwd.** Site, paths and domain are constants; and
   before anything destructive the wrapper re-checks that the live site reports
   `nwc_demo_access.settings demo_mode = true`. A non-demo site can never be
   wiped by this key, even if the constants were wrong.
3. **Fail-closed golden.** Manifest must name `nwd` and both artifacts must pass
   `sha256sum -c` before a byte is dropped.
4. **Idle guard.** A session newer than 30 min — or a failed/garbled sessions
   query — counts as ACTIVE and exits 3. It never wipes on bad data.
5. **Idempotent.** One successful reset per Melbourne day, plus a 10-minute hard
   floor between resets. Repeat invocations are cheap no-ops — which is why cron
   can just fire every 30 minutes instead of holding a 3-hour ssh session open
   against a 3.8 GB host.
6. **Single-flight** (`flock`), so overlapping invocations cannot interleave.
7. **Everything is logged** — accepted and refused alike.
8. **Non-zero exit on failure**; the post-restore smoke check (`/` and
   `/demo/join` must both serve 200, retried 5×) degrades a data-only success to
   exit 1.

---

## 5. ⚠ `IdentitiesOnly=yes` **and** `IdentityAgent=none` are load-bearing

Without both, ssh offers the agent-held admin key (`gitlab_linode`) first, the
connection matches the **unrestricted** `gitlab@nwpcode.org` entry, and you get
a normal shell — the forced command is never reached. This was hit during the
build: `ssh -i ~/.ssh/nwd_demo_reset gitlab@git.nwpcode.org status` returned
`bash: status: command not found`, i.e. it had authenticated as the admin.

The workstation has a `~/.ssh/config` alias that pins both:

```
Host nwd-demo-reset
    HostName 97.107.137.88
    User gitlab
    IdentityFile ~/.ssh/nwd_demo_reset
    IdentitiesOnly yes
    IdentityAgent none
```

The cron lines spell the options out explicitly so they do not depend on
`~/.ssh/config` being present.

---

## 6. Interim schedule (laptop) — active NOW

```
# NWP Demo Reset - nwd (restricted key; see docs/guides/demo-nightly-on-met.md)
CRON_TZ=Australia/Melbourne
0,30 1-3 * * * ssh -i $HOME/.ssh/nwd_demo_reset -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=30 gitlab@git.nwpcode.org nightly >> /home/rob/nwp/logs/demo-nightly-nwd.log 2>&1
```

Installed with:

```bash
pl demo schedule nwd --tier=live --via-key
```

**Limitation, stated plainly: this only fires while the laptop is awake.** A
laptop asleep or shut at 01:00–03:30 Melbourne means nwd is not reset that
night. There is no catch-up: the next attempt is the following night. That is
acceptable as a stopgap because the wrapper is idempotent and the site is a
demo, but it is exactly why the schedule belongs on met — which is always on.

Check whether last night actually fired:

```bash
tail -5 /home/rob/nwp/logs/demo-nightly-nwd.log
ssh nwd-demo-reset status
```

---

## 7. Handover to met — one command

When met is back:

```bash
bash servers/sites1/demo/install-on-met.sh
```

That single command does all six steps and **stops before removing the laptop
cron if any check fails**, so the nightly is never left unowned. Dry variant:

```bash
bash servers/sites1/demo/install-on-met.sh --check     # verifies, changes nothing
```

If you would rather do it by hand, it is four commands:

```bash
# 1. key → met (0600)
scp ~/.ssh/nwd_demo_reset metabox:.ssh/nwd_demo_reset && ssh metabox 'chmod 600 ~/.ssh/nwd_demo_reset'

# 2. prove the restriction from met
ssh metabox 'ssh -i $HOME/.ssh/nwd_demo_reset -o IdentitiesOnly=yes -o IdentityAgent=none gitlab@git.nwpcode.org dry-run'

# 3. met's crontab (paste the 3-line block from §6, with $HOME/logs/… as the log)
ssh metabox 'crontab -e'

# 4. remove the interim laptop cron
pl demo schedule nwd --remove
```

Verify afterwards:

```bash
ssh metabox "crontab -l | grep -A2 'NWP Demo Reset'"
crontab -l | grep -c nwd_demo_reset      # must be 0 on the laptop
ssh nwd-demo-reset status                # box-side log, from either machine
```

---

## 8. Routine maintenance

| When | Do |
|---|---|
| after `pl demo golden nwd --tier=live` | `bash servers/sites1/demo/install-box.sh --stage-golden` — the box holds its **own** copy of the golden; recapturing locally does not update it |
| after `pl demo codes …` / `pl demo invite` | `bash servers/sites1/demo/install-box.sh --stage-codes` — **required**, see the gap below |
| after editing the wrapper | `bash servers/sites1/demo/install-box.sh` (wrapper + dirs only) |
| rotating the key | `ssh-keygen -t ed25519 -f ~/.ssh/nwd_demo_reset` then `install-box.sh` then `install-on-met.sh` |
| revoking the key | delete the `nwd-demo-reset@met` line from the box's `authorized_keys` (backups are alongside it) |

---

## 9. Honest gaps

1. **The wrapper still runs as `gitlab`, which has NOPASSWD sudo**, and it uses
   `sudo` for the www-data drush calls and the files restore. The containment is
   that met can only *invoke* the script, not choose what it does — not that the
   script is unprivileged. A dedicated unix account plus a narrow sudoers rule
   would remove that residue. Anyone who can already write
   `/usr/local/bin/nwd-demo-reset-restricted` (i.e. root, or `gitlab` via its own
   sudo) can change what the key does; the key itself grants no such write.
2. **Empty code payload clears every invite code.** The staged
   `codes-payload.json` is authoritative, exactly as the laptop's
   `pl demo reset --tier=live` is. Right now every nwd code is revoked, so the
   payload is `{"codes":[]}` — and the wrapper prints a loud WARN when it applies
   an empty one. If you issue codes and forget `install-box.sh --stage-codes`,
   the next nightly locks testers out. Not automated; a follow-up could have the
   wrapper refuse an empty payload older than N days.
3. **The golden on the box drifts from the laptop's** until you re-stage it.
   Two copies of the same artifact, both sha-verified, neither watching the other.
4. **Laptop-cron liveness is unmonitored.** Nothing alerts if the laptop was
   asleep at 01:00. Once met owns it, `pl rag` / the daily audit should assert
   that `last-reset` is today's Melbourne date; not wired yet.
5. **No deploy-gate / Solo touch** on this path. `pl demo reset --tier=live`
   calls `deploy_gate_require`; the box-side wrapper cannot (no Solo on met, and
   the whole point is unattended nightly operation). The compensating controls
   are that the blast radius is one demo site whose contents are a
   sha256-verified golden image, and that the site must self-report
   `demo_mode=true`.
6. **`met` was unreachable during this build**, so steps 2–6 of the handover are
   *untested on met itself*. They were tested end-to-end from the workstation
   using the identical key, options and action words.

---

## 10. Proof captured 2026-07-25 (from the workstation, restricted key)

```
$ ssh <restricted key> gitlab@git.nwpcode.org dry-run
OK  golden image verified (manifest site=nwd + sha256 x2)
OK  site reports demo_mode=true
OK  idle for >= 30 min (newest=1784947462)
OK  DRY RUN — all guards passed. Nothing was changed.

$ ssh <restricted key> gitlab@git.nwpcode.org reset
...
OK  https://nwd.nwpcode.org/ and /demo/join both serve 200
OK  nwd demo reset complete in 40s — back at the golden image.

$ ssh <restricted key> gitlab@git.nwpcode.org nightly     # immediately after
OK  nwd already reset today (2026-07-25 Australia/Melbourne) — nothing to do.

$ ssh <restricted key> gitlab@git.nwpcode.org 'id'
REFUSED: this key may only run the nwd demo reset.        (exit 2, no uid= output)

$ ssh <restricted key> gitlab@git.nwpcode.org 'sudo cat /etc/gitlab/gitlab-secrets.json'
REFUSED: …                                                (exit 2)

$ ssh -tt <restricted key> gitlab@git.nwpcode.org 'sudo -i'
PTY allocation request failed on channel 0                (exit 255)

$ scp <restricted key> /etc/hostname gitlab@git.nwpcode.org:/tmp/pwn
scp: Received message too long …                          (/tmp/pwn does not exist)

$ ssh -N -L 9999:127.0.0.1:22 <restricted key> gitlab@git.nwpcode.org
channel 2: open failed: administratively prohibited: open failed
```
