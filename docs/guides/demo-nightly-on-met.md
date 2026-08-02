# Nightly demo reset — restricted keys + the met schedule

**Status (2026-08-01):** BOTH halves live and scheduled on **met**.
`nwd` (Drupal) fires at minutes 0,30 · `ssd` (Moodle) at 15,45 · 01:00–03:30
Australia/Melbourne, 04:00 floor. The laptop's interim cron is gone.
**Issues:** ops#133 (nwd) · ops#170 (ssd)

> **Two wrappers, two keys, one box.** Each wrapper hard-wires its own site
> ([G2]); there is deliberately no way to install one and aim it at the other.
> A key for one half is refused by the other — proven, see §11.

> **The scheduler moved twice, and the log is the record of it.** The nightly ran
> from the LAPTOP's crontab on 27, 28 and 29 July (`reset-ok` each night in the
> box log) and then stopped, because that cron only fires while the laptop is
> awake and the demo pair moved boxes on 31 July. It has been on met since
> 2026-08-01. If the nightly ever goes quiet again, read
> `/var/log/nwp-demo/<site>-demo-reset.log` on the box FIRST — it is the only
> record that spans schedulers.

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
| box `/usr/local/bin/nwd-demo-reset-restricted` | the wrapper (versioned at `servers/live/demo/nwd-demo-reset-restricted`) | `root:root 0755` |
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

## 6. The schedule — HISTORY, and why the laptop cron is gone

> **Superseded.** The block below is what ran on the LAPTOP from 25–29 July. It
> is kept because it explains the three `reset-ok` nights in the box log and the
> silence after them, which otherwise reads as "the nightly never ran". The live
> schedule is on met — see §7 and §11.


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
bash servers/live/demo/install-on-met.sh
```

That single command does all six steps and **stops before removing the laptop
cron if any check fails**, so the nightly is never left unowned. Dry variant:

```bash
bash servers/live/demo/install-on-met.sh --check     # verifies, changes nothing
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
| after `pl demo golden nwd --tier=live` | `bash servers/live/demo/install-box.sh --stage-golden` — the box holds its **own** copy of the golden; recapturing locally does not update it |
| after `pl demo codes …` / `pl demo invite` | `bash servers/live/demo/install-box.sh --stage-codes` — **required**, see the gap below |
| after editing the wrapper | `bash servers/live/demo/install-box.sh` (wrapper + dirs only) |
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
7. **The box wrapper cannot sync tester feedback — it can only warn** (nwp/ops#161).
   Tester reports filed through `/feedback/submit` are Feedback entities in the
   database the restore replaces. `pl demo reset` now syncs them to GitLab
   pre-wipe (see §12), but the *nightly* on this path runs the restricted
   wrapper, which holds no GitLab token and must not — a key that can push to
   the tracker is no longer a key that can only reset. So the wrapper counts
   what is pending and prints a `WARN` naming
   `pl demo feedback-sync nwd --tier=live`, and the loss is logged rather than
   silent. Closing it properly needs a decision between:
   (a) staging a 0600 token on the box — an **operator** secret-placement call,
       and a `private/secrets-registry.yml` entry with a scope probe; or
   (b) routing met's cron through `pl demo nightly nwd --tier=live` instead of
       the key, which keeps the token on met where it already lives and needs
       no new secret — but gives up the "scheduler needs no repo checkout"
       property this whole design was built for.
   (b) is the pl-first answer; neither has been done.

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

---

## 11. The Moodle half — `ssd` (ops#170)

Everything in §1–§10 applies. This section records only what is **different**,
and why.

### 11.1 Why a second wrapper rather than a parameter

`nwd-demo-reset-restricted` hard-wires nwd by design — [G2] says there must be
no way to name another site, and a `--site` flag would be exactly that way. So
the Moodle half gets its own file, its own forced command and its own key.
The cost is two files to keep in step; the alternative is a hole in the one
guarantee that stops a restricted key reaching a non-demo site.

### 11.2 What is installed where

| Where | What |
|---|---|
| box `/usr/local/bin/ssd-demo-reset-restricted` | the wrapper (versioned at `servers/live/demo/ssd-demo-reset-restricted`) |
| box `/var/lib/nwp-demo/ssd/golden/` | golden DB + moodledata tar + sha256 sidecars + manifest |
| box `/var/lib/nwp-demo/ssd/last-reset` | idempotence stamp |
| box `/var/lib/nwp-demo/ssd/harvest/` | pre-wipe digests (failed tasks + logstore errors) |
| box `/var/log/nwp-demo/ssd-demo-reset.log` | one line per invocation |
| **met** `~/.ssh/ssd_demo_reset` | the private key — **generated on met and never copied off it** |
| workstation `~/.ssh/ssd_demo_reset.pub` | the public half only, for `install-box.sh` |

There is no `codes-payload.json`: invite codes are a provider-side
(`nwc_demo_access`) concept. `install-box.sh ssd --stage-codes` **refuses**
rather than quietly doing nothing.

### 11.3 Install / re-install

```bash
bash servers/live/demo/install-box.sh ssd --stage-golden   # wrapper + dirs + golden + key
bash servers/live/demo/install-box.sh ssd --no-key         # wrapper only, after an edit
```

The site is the first bare word; `nwd` remains the default, so every existing
command line in this guide still means what it always did.

### 11.4 Three Moodle traps this wrapper is built around

1. **The demo flag is in the `mdl_config` TABLE, not `config.php`.** Reading
   `config.php` with `ABORT_AFTER_CONFIG` shows `nwp_demo_mode` unset on a site
   where it is very much set, because that stops before Moodle loads DB-stored
   config. The guard reads the table, deliberately and only.
2. **`config.php` is checked, never followed.** The dataroot and dbname are
   constants in the wrapper; `config.php` is read to confirm they agree. A
   disagreement is a refusal — following the file would clear a directory the
   site is not using, report success, and leave the real data intact. A reset
   that erases nothing while the banner promises nightly erasure is worse than
   one that stops.
3. **Moodle writes an `mdl_sessions` row for every ANONYMOUS request.** Measured
   on 2026-08-01: 3931 anonymous rows against 1 authenticated. An idle guard
   keyed on `MAX(timemodified)` over the whole table therefore asks "has any
   robot touched the site in 30 minutes?" — and any crawler on a sub-30-minute
   cadence silently vetoes the nightly for ever, every run exiting 3 "ACTIVE,
   retry". So [G4] counts `userid <> 0`: a tester on ssd is signed in (they
   arrive by SSO from nwd). The anonymous figure is still measured and logged
   beside the decision, so a wipe is never recorded as happening on a "quiet"
   site when the site was only quiet of humans. `lib/demo-live-moodle.sh` was
   changed to match, so `pl demo reset ssd --tier=live` and the nightly cannot
   disagree about what "idle" means.

### 11.5 Scheduling — the 15-minute offset

Both halves now live on the same box, so `pl demo schedule` fires the
**consumer** half of a demo pair at minutes `15,45` instead of `0,30`. Same
window, same 30-minute retry cadence, never the same minute. It is derived from
the pair contract rather than passed as a flag, because a collision-avoidance
measure an operator has to remember is one they will forget.

```
# NWP Demo Reset - ssd (restricted key; see docs/guides/demo-nightly-on-met.md)
CRON_TZ=Australia/Melbourne
15,45 1-3 * * * ssh -F /dev/null -i $HOME/.ssh/ssd_demo_reset -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=30 gitlab@<box> nightly >> /home/rob/nwp/logs/demo-nightly-ssd.log 2>&1
```

**FIXED (nwp/ops#171).** This used to read: *`pl demo schedule ssd --tier=live
--via-key` cannot run ON met, because met has no `sites/` config and the verb
resolves the box host from `sites/<site>/.nwp.yml`.* Both blocks above therefore
had to be generated on the workstation against a stub crontab and installed on
met by hand — hand-work the runbook did not describe, and a live hazard: met's
checkout predated MR !262, so re-running the verb there would have installed the
cron line **without `-F /dev/null`**, the exact admin-key hijack that MR had just
fixed. Re-running it on the workstation, meanwhile, rewrites the WORKSTATION's
crontab.

There are now two supported ways, and the hand path is gone:

```bash
# ON MET — name the box directly; no sites/ config needed, which is the whole
# point of --via-key. NWP_DEMO_BOX_HOST=<user>@<ip> is the env equivalent.
pl demo schedule ssd --tier=live --via-key --host gitlab@<box>

# ANYWHERE — emit the block, install it wherever the scheduler actually is.
# --print-only touches no crontab at all (it does not even read one) and what
# it prints on stdout is byte-identical to what the install path writes.
pl demo schedule ssd --tier=live --via-key --print-only > /tmp/ssd.block
scp /tmp/ssd.block met:/tmp/ && ssh met 'crontab -l > /tmp/c; cat /tmp/ssd.block >> /tmp/c; crontab /tmp/c'
```

Check the log path in a `--print-only` block before installing it: it is
resolved from the GENERATING machine's `PROJECT_ROOT`, which is not necessarily
the target's. `--print-only` says so on stderr, so stdout stays crontab-clean.

Either way the marker is unchanged, so `pl demo schedule ssd --remove` still
manages the job from met.

`-F /dev/null` is load-bearing for the same reason as §5: `IdentitiesOnly` and
`IdentityAgent=none` block the AGENT, but an `IdentityFile` in `~/.ssh/config`
for this host is still offered — and on a workstation that names the admin key.

### 11.6 The pair lock

The ssd wrapper takes the **nwd wrapper's** lock as well as its own, so the two
halves never restore simultaneously on a small shared box. It is **advisory**:
the nwd wrapper knows nothing about this one, so failing closed on an
unavailable pair lock would let a permissions change on the other site's file
silently stop ssd's nightly for ever. Taken if possible, logged as
`pair-lock-unavailable` if not, never a refusal. Both use `flock -n`, so the
worst case is one of them skipping and cron retrying in 30 minutes.

The two halves are **serialised, not atomic** — they are two databases and two
file trees. The window in which nwd is back at its golden and ssd is not is a
couple of minutes on an idle site. It is not zero and nothing here claims it is.

### 11.7 Proof captured 2026-08-01 (from met, through the restricted key)

Canaries planted first: a table the golden does not have (`mdl_zz_canary`) and a
file in `moodledata` (`filedir/ZZ-CANARY.txt`). Both must be gone, or the reset
is an import over the top rather than a wipe.

```
$ <restricted key> status
site:        ssd (ssd.nwpcode.org)   [Moodle]
demo_mode:   1

$ <restricted key> dry-run
OK  dataroot /var/www/ssd_moodledata has the shape of a moodledata directory
OK  live config.php agrees: dataroot=/var/www/ssd_moodledata dbname=ssd
OK  golden image verified (manifest site=ssd + sha256 x2)
OK  site reports nwp_demo_mode=1
OK  no signed-in session for >= 30 min (newest_user=1785081795, newest_anon=1785569189)
FATE MANIFEST — ssd (ssd.nwpcode.org) Moodle demo reset, action=dry-run
…
OK  DRY RUN — all guards passed. Nothing was changed.

$ <restricted key> nightly
..  dropping every table in ssd and reloading from golden
..  clearing /var/www/ssd_moodledata and unpacking the golden moodledata
OK  https://ssd.nwpcode.org/ and /login/index.php both serve 200
OK  ssd demo reset complete in 9s — back at the golden image.

after: mdl_zz_canary GONE · filedir/ZZ-CANARY.txt GONE
       502 tables · 4 users · 4 courses · nwp_demo_mode=1
       /var/www/ssd_moodledata drwx------ www-data (directory itself never removed)

$ <restricted key> 'id'
REFUSED: this key may only run the ssd demo reset.        (exit 2)

$ <restricted key> 'nwd nightly'
REFUSED: this key may only run the ssd demo reset.        (exit 2)
```

The last one is the one worth keeping: one half's key cannot reach the other
half, because the forced command names the wrapper and the wrapper names the
site.

---

## 12. Pre-wipe tester-feedback sync (nwp/ops#161, interlocked with ops#140)

`pl demo reset` (and therefore `pl demo nightly`) runs a **pre-wipe feedback
sync** immediately beside the existing error harvest, on all three reset paths
(dev, live, paired). It delegates to the module's own
`drush nwc-feedback:sync-to-gitlab`, which owns the classifier, the doctrine
body-withholding and the agent-eligibility fence — nothing in `pl` renders an
issue body.

Same **fail-OPEN** contract as the harvest: `demo_feedback_sync` always returns
`0`. A failed sync is logged to `sites/<site>/demo-reset.log` and the reset
proceeds. Losing a night of feedback must never leave a demo site un-reset.

**It is interlocked with ops#140 and that interlock is fail-CLOSED.** Before it
pushes anything it probes the *deployed* code:

```
method_exists(\Drupal::service('nwc_feedback.gitlab_sync'), 'buildIssueDescription')
```

`buildIssueDescription()` is the pure renderer nwp/nwc!50 introduced when it
took the submitter's name out of the payload; it does not exist on the
pre-ops#140 service. A site that fails that probe — or that cannot answer it —
is logged `feedback-sync-refused reason=minimisation-unverified` and **nothing
is sent**. "I could not look" is not "it is safe": ops#161 and ops#140 were
filed independently, and enabling the sync against unfixed code would have
switched a member-identity leak back on.

Log events, all in `sites/<site>/demo-reset.log`:

| event | meaning |
|---|---|
| `feedback-sync-ok synced=N` | N reports became GitLab issues before the wipe |
| `feedback-sync-empty` | nothing pending — **no token was even read** |
| `feedback-sync-refused` | deployed payload not provably minimised; nothing sent |
| `feedback-sync-skipped` | no usable token on this host; nothing sent |
| `feedback-sync-failed` | drush/probe failed; reset continued regardless |
| `feedback-pending-unsynced` | *box wrapper only* — N reports destroyed, see §9.7 |

Hand/scheduled entrypoint, and what to run after a `refused` or `skipped` line:

```bash
pl demo feedback-sync nwd --tier=live --dry-run   # probe only, sends nothing
pl demo feedback-sync nwd --tier=live
```

The Moodle half (`ssd`) is deliberately skipped: `local_feedback` forwards each
report to GitLab synchronously at submit time, so it holds no pending set for a
wipe to destroy. Its payload was minimised by `nwp/ss-moodle-plugins!11`.

---

## 13. §12's residual, and what met actually runs (nwp/ops#156, ruling D15)

§12 ends with a gap it names honestly: the box wrapper cannot sync feedback,
because it holds no GitLab token and **must not** — a key that can reset must
not also be able to push to the tracker. The operator ruled option **(b)**:
route met's cron through `pl demo nightly` rather than stage a token on the box.

What that means in practice, after researching what met can and cannot do:

### 13.1 met runs `pl demo nightly <site> --tier=live --via-key`

```
# NWP Demo Reset - nwd (restricted key; see docs/guides/demo-nightly-on-met.md)
CRON_TZ=Australia/Melbourne
0,30 1-3 * * * /home/rob/nwp/pl demo nightly nwd --tier=live --via-key --host gitlab@<box> >> /home/rob/nwp/logs/demo-nightly-nwd.log 2>&1
```

Installed, never hand-edited:

```bash
pl demo schedule nwd --tier=live --via-key --host gitlab@<box>     # ON MET
pl demo schedule ssd --tier=live --via-key --host gitlab@<box>     # minutes 15,45, derived
```

**The transport does not change.** Same restricted key, same `-F /dev/null`
options, same single action word, same box-resident sha256-verified golden, same
box-side pair lock (§11.6). `demo_box_ssh_args` is the one function that decides
what ssh invocation reaches the box, and both the cron line and the runner read
it — a unit test pins that the command met RUNS is the command the verb
INSTALLED.

What the pl wrapper adds is the two things only a checkout can do:

| when | step | needs |
|---|---|---|
| before the wipe | tester-feedback sync (§12) | a drush transport + a token |
| after a successful wipe | drain the box's pre-wipe error digests (`harvest`, read-only) and post them to nwp/ops | the same restricted key; a token only to POST |

Both are **fail-OPEN and cannot change the reset's exit code**. A scheduler step
that can turn a good reset into a reported failure is a step that eventually
stops the nightly.

### 13.2 Why not the obvious form, `pl demo nightly <half> --tier=live`

Because met cannot run it, and making it able to would be a worse posture than
the gap it closes:

- it routes into `cmd_reset_live`, which needs `sites/<site>/.nwp.yml` — met's
  checkout has `sites/{avc,mayo,nwc,ss}` and no `nwd` or `ssd`;
- it uploads the golden from the SCHEDULER on every run; the box already holds a
  verified copy (nwd 84 MB DB + files, ssd 23 MB DB + 134 MB moodledata);
- it needs an admin `gitlab@` shell on the live box, whose `gitlab` user has
  `NOPASSWD: ALL` over ~15 live sites. Handing that to an AI-accessible machine
  to save a flag is exactly what §1 says never;
- once nwp/nwp!300 merges, that exact command **REFUSES** anyway: nwd and ssd are
  a coupled pair and the paired live reset is opt-in.

`--with-pair` is not the answer either: the paired LIVE reset has never run
against the estate, which is precisely why !300 made it opt-in. An unattended
nightly must not be its first exerciser. `--no-pair` silences the guard rather
than satisfying it.

`--via-key` sidesteps the question correctly, not by luck: it never enters
`cmd_reset`, so the paired-half guard is not in its path — and the pair
invariant it protects is held on the box, where the ssd wrapper takes the nwd
wrapper's lock so the two halves never restore simultaneously.

### 13.3 What is still NOT closed, stated plainly

**met still cannot sync feedback**, and this change does not pretend otherwise.
The sync runs `drush nwc-feedback:sync-to-gitlab` on the live site; the only
transports to that site are the admin shell (refused above) and the restricted
key, whose entire guarantee [G1] is that it runs fixed action words and nothing
else. On met the verb therefore logs

```
feedback-sync-no-transport tier=live reason=no-live-config-on-scheduler
```

and prints a WARN naming `pl demo feedback-sync nwd --tier=live`. That is
*logged* loss, in the log an operator already reads, instead of loss inferred
from a box-side warning nobody sees. Closing it needs one of:

1. a **token-free `feedback` export action word** in the box wrappers — the box
   dumps pending rows, met posts them with met's own token. This is the correct
   final fix and it keeps every existing guarantee; it is a box-wrapper change
   and therefore its own MR;
2. or live site config + a registered GitLab token on met (a new secret
   placement: `pl secrets` entry, `stored_in: host=met:…`, and a scope probe).

Neither is done here. `pl demo nightly --via-key` is where either plugs in.

### 13.4 Cutover order — this matters

The cron line names a verb. **met's checkout must know the verb before the
crontab names it.** An older `pl` silently ignores `--via-key` and attempts a
full live reset it cannot perform, so the nightly would fail instead of reset.

```bash
# 1. merge the MR, then ON MET:
git -C ~/nwp pull --ff-only
~/nwp/pl demo nightly nwd --tier=live --via-key --host gitlab@<box> --dry-run   # proves it
# 2. only then:
crontab -l > ~/crontab.backup-$(date +%Y%m%d)        # keep the old one
~/nwp/pl demo schedule nwd --tier=live --via-key --host gitlab@<box>
~/nwp/pl demo schedule ssd --tier=live --via-key --host gitlab@<box>
```

`--raw-ssh` reinstalls the previous bare-ssh line at any time; it is the
rollback, and it is also the right choice for a scheduler that has the key and
no checkout.

### 13.5 met's git identity is still @root (ops#156 residue)

Measured 2026-08-02: `ssh -T -i ~/.ssh/gitlab_metabox -o IdentitiesOnly=yes
git@git.nwpcode.org` from met answers **`Welcome to GitLab, @root`**, and `git
ls-remote` authenticates with that same key. It is a root-identity credential
and it must be replaced with a read-only, met-specific deploy key.

Two things follow, and both matter:

- **This nightly does not use it.** `pl demo nightly --via-key` runs no `git`
  command; its only network calls are the restricted-key ssh to the box and (if
  a token is ever present) an HTTPS POST to nwp/ops. The credential's exposure
  is unchanged by this MR.
- **It still gates the cutover.** The code met executes nightly arrives through
  that credential, so the honest sequence is: de-root met's git identity, then
  flip the crontab. Minting the deploy key needs Maintainer/admin — `pl secrets
  capabilities` shows `deploy-keys: no` for every token available to automation,
  including `gitlab_operator_pat`. It is an operator action.
