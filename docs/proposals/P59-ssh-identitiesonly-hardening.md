# P59: SSH IdentitiesOnly Hardening (Fail2ban Lockout Fix)

**Status:** ✅ COMPLETE (v0.31.0) | **Priority:** HIGH | **Effort:** Medium | **Dependencies:** None

> **TL;DR:** NWP scripts that ssh to production by raw IP would offer every key in `~/.ssh/` on every connection, tripping fail2ban (`maxretry=3`) and locking developers out of nwpcode.org. The fix forces `IdentitiesOnly=yes` everywhere ssh, scp, or rsync is called, plus a per-site `-i <key>` resolved from `nwp.yml`.

---

## 1. Problem Statement

### 1.1 Symptoms

Developers with several keys in `~/.ssh/` (>3) were intermittently locked out of `97.107.137.88` (`git.nwpcode.org`) by fail2ban. The lockouts:

- Affected `pl stg2live`, `pl live`, `pl podcast`, and any direct `ssh gitlab@97.107.137.88` from a script.
- Did **not** affect connections that went through a `Host` alias in `~/.ssh/config` (those already pinned an `IdentityFile`).
- Manifested as repeated "Permission denied (publickey)" failures followed by a 10-minute ban.

### 1.2 Root Cause

OpenSSH offers every key it knows about (every file in `~/.ssh/` plus every key in `ssh-agent`) until one succeeds. Each rejected key counts as a failed authentication attempt against fail2ban's `[sshd]` jail. With ~10 keys present, the 4th key offered already trips the default `maxretry=3` filter.

There were two compounding factors:

1. **`~/.ssh/config` was missing `IdentitiesOnly yes` on most `Host` blocks.** A `Host *` catch-all would have helped, but only the `git-server` alias was reliably matched. Scripts that ssh by raw IP (`ssh gitlab@97.107.137.88`) skipped the alias entirely and fell through to defaults.
2. **NWP scripts called `ssh` / `scp` / `rsync` without `-o IdentitiesOnly=yes`** in ~80 places across `lib/` and `scripts/commands/`. Even fixing the user's local `~/.ssh/config` would not protect anyone running these commands on a fresh machine.

### 1.3 Why a Defensive Library Fix

The right fix has to live inside NWP itself, so the bug cannot recur for any user — including new contributors who will never know about the historical fail2ban incident.

---

## 2. Solution

### 2.1 Library Helpers in `lib/ssh.sh`

Three new helpers (already merged):

- `nwp_ssh_opts <name>` — returns the inline options string `-o IdentitiesOnly=yes [-i <key>]`. The key is resolved from `sites.<name>.live.ssh_key` (or `linode.servers.<name>.ssh_key`) via the existing `get_ssh_key()` function. If the resolved key file does not exist, only `-o IdentitiesOnly=yes` is returned, so the call still works on machines that have not configured a per-site key.
- `nwp_ssh` / `nwp_scp` / `nwp_rsync` — drop-in replacements that take the site/server name as the first argument and forward the rest to the underlying tool.
- `_nwp_ssh_args_for <name>` — building block that emits the args one-per-line, used internally by the wrappers.

A constant `NWP_SSH_HARDENING_OPTS="-o IdentitiesOnly=yes"` is also exported for scripts that just want to splice the option into an existing command.

`lib/common.sh` auto-sources `lib/ssh.sh`, so every script that already sources `common.sh` gets the helpers for free.

### 2.2 Migration Pattern

For scripts that already use `nwp.yml`-resolved variables (`base_name`, `sitename`, `BASE_NAME`, `SITENAME`), inline-splice `nwp_ssh_opts`:

```bash
# Before
ssh -o BatchMode=yes "${ssh_user}@${server_ip}" "command"

# After
ssh $(nwp_ssh_opts "$base_name") -o BatchMode=yes "${ssh_user}@${server_ip}" "command"
```

For server-provisioning scripts that have no site context yet (e.g. `produce.sh`), simply add the option directly:

```bash
ssh -o IdentitiesOnly=yes "root@${server_ip}" "command"
```

For library helpers that build SSH option strings (`get_ssh_opts` in `lib/server-scan.sh`, `get_server_ssh_command` in `lib/server-resolver.sh`, `build_ssh_cmd` in `stg2prod.sh`), add `-o IdentitiesOnly=yes` to the constant prefix.

For rsync, the `-e` argument needs to embed the option: `rsync -e "ssh -o IdentitiesOnly=yes -i $key" ...`.

### 2.3 Fail2ban Configuration

The default `maxretry=3` is fine **once IdentitiesOnly is in place** — three real authentication failures from the same IP is still the right ban threshold. P59 deliberately does **not** raise `maxretry`; that would mask the underlying bug instead of fixing it.

---

## 3. Implementation

### 3.1 Files Modified

**Library (`lib/`)** — 11 files:

- `lib/ssh.sh` — added `nwp_ssh_opts`, `nwp_ssh`, `nwp_scp`, `nwp_rsync`, `_nwp_ssh_args_for`, `NWP_SSH_HARDENING_OPTS`. Updated `get_ssh_options`, `build_ssh_command`, `ssh_exec` to include `-o IdentitiesOnly=yes`.
- `lib/common.sh` — auto-source `ssh.sh`.
- `lib/server-resolver.sh` — `get_server_ssh_command` adds `-o IdentitiesOnly=yes`.
- `lib/server-scan.sh` — `get_ssh_opts` and the ssh-test path add `-o IdentitiesOnly=yes`.
- `lib/import.sh` — rsync `-e` strings add `-o IdentitiesOnly=yes`.
- `lib/git.sh` — `check_git_server_alias` and `gitlab_create_project` ssh calls hardened.
- `lib/state.sh` — server reachability check hardened.
- `lib/linode.sh` — Linode SSH-ready wait loop hardened.
- `lib/live-server-setup.sh` — `remote_ssh` opts hardened.
- `lib/safe-ops.sh` — `safe_server_status` ssh hardened.
- `lib/remote.sh` — `remote_exec` and backup `scp` hardened.
- `lib/install-common.sh` — DNS pre-registration ssh calls hardened.
- `lib/database-router.sh` — production database pull ssh hardened.
- `lib/podcast.sh` — generated `deploy-to-server.sh` template emits hardened ssh/scp.

**Commands (`scripts/commands/`)** — 13 files:

- `stg2live.sh`, `stg2prod.sh` — all email-server and webroot ssh/scp/rsync calls migrated to `nwp_ssh_opts "$base_name"`.
- `live.sh` — all 18+ ssh calls migrated to `nwp_ssh_opts "$sitename"`.
- `live2prod.sh`, `live2stg.sh` — migrated to `nwp_ssh_opts "$base_name"` / `"$BASE_NAME"`.
- `prod2stg.sh` — `ssh $SSH_CONN` calls prefixed; `rsync_ssh` and `scp_opts` builders include `-o IdentitiesOnly=yes` and fall back to nwp.yml-resolved keys.
- `produce.sh` — server provisioning ssh calls hardened (no site context).
- `podcast.sh` — already passed `-i <key>`; added `-o IdentitiesOnly=yes` to every call and to user-facing instruction strings.
- `sync.sh` — rsync `-e` string hardened.
- `server.sh` — connectivity test ssh hardened.
- `setup-ssh.sh` — `ssh_cmd` array adds `-o IdentitiesOnly=yes`.
- `coder-setup.sh` — key deployment ssh calls migrated to `nwp_ssh_opts "$server"`.
- `bootstrap-coder.sh` — GitLab SSH detection hardened.

### 3.2 Verification

All 27 modified files pass `bash -n`. The migration is mechanical: every hardened call has either:

1. An inline `-o IdentitiesOnly=yes` (server-provisioning, no site context), or
2. `$(nwp_ssh_opts "$name")` spliced in (where `$name` is the resolved site/server variable already in scope).

---

## 4. Success Criteria

- [x] No `ssh`, `scp`, or `rsync` call in `lib/` or `scripts/commands/` runs without `-o IdentitiesOnly=yes`
- [x] `nwp_ssh_opts`, `nwp_ssh`, `nwp_scp`, `nwp_rsync` available in every script that sources `lib/common.sh`
- [x] Server-resolver and server-scan helpers emit hardened option strings
- [x] All 27 modified files pass `bash -n`
- [x] Generated scripts (e.g. `lib/podcast.sh` deploy template) also emit hardened ssh/scp
- [ ] Documentation updated to show the safe form (`docs/reference/commands/sync.md`, `docs/deployment/ssh-setup.md`, etc.) — tracked by Task #5

---

## 5. Migration Notes for Users

Users do **not** need to take any action. Existing `nwp.yml` files keep working. The fix is purely additive: `IdentitiesOnly=yes` only restricts which keys ssh **offers**; it does not remove any keys or break any working connection.

If a user wants to revert temporarily (e.g. while debugging), they can `unset NWP_SSH_HARDENING_OPTS` and edit the script in question — but this is not recommended.

---

## 6. Why This Is Not F15 / Why It Is Its Own Proposal

F15 ("SSH User Management") consolidated the **user** resolution chain (`get_ssh_user`). It does not touch the **key offering** behavior, which is what trips fail2ban. P59 is the security-hardening twin of F15: F15 makes sure you ssh as the right user, P59 makes sure you ssh with the right key (and *only* the right key).
