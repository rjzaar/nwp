# mons operational readiness — running `nwp`/`pl` AI-free with error reporting

> **Audience:** the operator, sitting at **mons** (role: `ver`, the offline
> verifier host). Every command here is something **you** type — no AI session
> can reach mons.
>
> **Status:** setup kit ready; mons not yet provisioned (see "Current gaps").
> The feature ships **OFF by default** — nothing in this guide changes `nwp`/`pl`
> behaviour until you opt in.

## What "run nwp on mons AI-free" means

mons is the only machine that touches production, so it deliberately has **no AI
assistant** on it. You drive `nwp`/`pl` by hand. Two capabilities make that
workable offline:

1. **A one-way message channel out of mons** — `verifier-say` (helper file
   `scripts/mons-say.sh`) posts a GitLab issue into the ops queue
   (`$NWP_OPS_LOG_PROJECT` on `$NWP_GITLAB_HOST`). mons never accepts inbound
   connections; the dev session reads that queue on request.
2. **Automatic error reporting through that same channel** — when a `pl`
   command fails, `nwp` can compose a small report (command, exit code,
   timestamp, git commit, hostname — **no secrets, no file contents, no command
   output**) and post it via `verifier-say`, non-interactively. This replaces
   the default browser-URL error reporter, which is useless on a headless box.

Both are **opt-in**. With no config and no env var, `pl` behaves exactly as it
does today.

## Operator steps

Run these on mons, from inside the nwp checkout.

### 1. Run the setup script

```bash
cd ~/nwp                       # your nwp checkout on mons
NWP_GITLAB_HOST=<your-git-host> NWP_OPS_LOG_PROJECT=ops/verifier-log \
  ./scripts/mons-setup.sh
```

The script is idempotent and fail-closed. It:

- checks `curl` is present;
- checks `~/.config/verifier-log.token` exists with `0600` perms (it never reads
  or writes the value — if absent it tells you how to place it);
- writes the two **non-secret** identifiers to `~/.config/nwp-verifier.env` and
  makes `~/.bashrc` source it;
- symlinks `verifier-say` onto `~/bin`;
- offers to append the verification stanza to your local `nwp.yml`;
- runs an offline check (add `--smoke` to instead post a labelled TEST issue).

### 2. Place the token (if the script said it was missing)

From **your own secret store** (not from any AI session output):

```bash
umask 077 && printf '%s\n' '<glpat-…>' > ~/.config/verifier-log.token
chmod 600 ~/.config/verifier-log.token
```

The token is the project-scoped PAT for `ops/verifier-log` — it can touch that
one project and nothing else.

### 3. Load the env and confirm the channel

```bash
. ~/.config/nwp-verifier.env
verifier-say --help              # prints usage (exit 2 is expected)
./scripts/mons-setup.sh --smoke  # posts a labelled TEST issue; then close it
```

### 4. Enable error reporting via verifier-say

Either edit `nwp.yml` (the setup script can append the stanza — source of truth
is `docs/guides/mons-verification.stanza.yml`) and uncomment:

```yaml
      via: verifier-say        # under verification.error_reporting
      auto_post: true          # headless mons: post without prompting
```

…or, for a single session without editing the file:

```bash
export NWP_REPORT_VIA=verifier-say
```

On a headless host you **must** set `auto_post: true` (or accept that nothing is
posted, since there is no TTY to prompt at). On an interactive host you may
leave `auto_post` off and be asked `[Y/n]` before each post.

### 5. First real test

Run any `pl` command you expect to fail (e.g. against a missing site). On
failure a single issue should appear in `ops/verifier-log`. The command's own
exit code is unchanged — reporting is best-effort and never masks it.

## What gets reported (and what never does)

Reported: `command`, `exit_code`, `host`, `git_commit`, `timestamp`.
Never reported: secrets, tokens, `.secrets.yml`/`settings.php` contents, DB
dumps, command stdout/stderr, file paths beyond the command name.

## Do NOT flip consent

The stanza ships `verification.consent.agreed: false`. That gate controls
verification **auto-logging**, not error reporting. Leave it false unless the
operator has actually agreed to auto-logging.

## Current gaps (as of this kit)

- **mons is not yet provisioned / not on the tailnet.** These steps are ready to
  run but assume mons exists with the nwp checkout, `curl`, and outbound network
  to `$NWP_GITLAB_HOST`. See `docs/guides/verifier-mayo-bootstrap.md` and
  `docs/guides/verifier-operations.md` for the host bootstrap.
- **`verify.sh` and `verifier-say` are NOT in the signed `nwp-server` artifact by
  default.** They are now **deny-clean** (they pass `pl build-server
  --scan-only`), so they *can* be added to `build/nwp-server.include` — but
  whether to ship them in the AI-free artifact is an operator decision, not made
  here.
- **The reporting feature defaults OFF.** Until step 4 is done (or
  `NWP_REPORT_VIA` is exported), `pl` uses the legacy interactive browser-URL
  reporter, i.e. effectively nothing on a headless box.
- **Consent is off** by design (see above).

## Related

- `docs/guides/mons-verification.stanza.yml` — the paste-ready config block.
- `scripts/mons-setup.sh` — the setup script this runbook drives.
- `scripts/mons-say.sh` — the `verifier-say` helper.
- `lib/verify-autolog.sh` — where on-failure reporting is wired.
- `docs/guides/verifier-mayo-bootstrap.md`, `docs/guides/verifier-operations.md`
  — host bootstrap + trust path.
