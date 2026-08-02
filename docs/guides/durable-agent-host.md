# The durable agent host (`ai-host`)

**Last Updated:** 2026-08-02

Long-running agent work belongs on the `ai-host`, not on `authoring`. This guide
says what that host holds, what it must never hold, how to attach to it, and how
to refresh it.

Host **roles** are used throughout — see `docs/reference/role-vocabulary.md`. The
binding from a role to a machine lives in the operator's private overlay, never
in this repo.

## Why there is a durable agent host at all

On 2026-08-02 the `authoring` laptop crashed mid-operation and killed seven
running agents. Anything running in a terminal on `authoring` dies with
`authoring`. The `ai-host` has months of uptime, already runs the agent-loop and
the NWP Console, and now carries a named tmux session, so work survives a
disconnect, a laptop crash, and (with linger enabled) a logout.

The operator asked about TeamViewer for this. It was declined on the standing
SaaS-distrust rule in `CLAUDE.md`: a third-party remote-desktop relay is exactly
the trust dependency the threat model rejects. The replacement is tmux reached
over the existing self-hosted mesh VPN. **Do not install remote-desktop software
on any estate host.**

## THE BOUNDARY — the `ai-host` never reaches prod

Operator-stated 2026-08-02, and permanent. This is **never**, not *not yet*.

- The `ai-host` **MAY** hold **live-tier** credentials. The live tier holds no
  real user data, so a live-tier credential on an AI-run host is within the
  threat model.
- The `ai-host` **MUST NEVER** hold anything that reaches prod. Prod belongs to
  the `ver` role alone (ADR-0028), which is offline by default and provisioned
  by the operator, in person, from the operator's own store.

That rule is enforced in code, two ways, both fail-closed:

1. **Allowlist.** `pl secrets provision` writes only to hosts the registry names
   in `ai_provisionable_hosts:`. An estate that has declared nothing can
   provision nothing. A denylist has to be *complete* to be correct, and the one
   time it is not is the time it matters.
2. **Prod roles are refused even if allowlisted**, so the two lists cannot be
   edited into agreement by accident. No `--force`, no env var and no config key
   gets past it — an escape hatch would make the boundary a preference.

See `tests/unit/test-secrets-provision.bats`.

## What the `ai-host` holds

Registry ids only — never values. Inspect with `pl secrets status`, and prove
each copy is real with `pl secrets verify-copy <id>` or
`pl secrets audit --locations`.

| What | Registry id | Why the host needs it |
|------|-------------|------------------------|
| nwp/ops issue token | `gitlab_bot_ops_note` | `pl issue ls/show/comment` — how an agent reads and updates the work board. Reporter + api on the ops project only: it can comment there and reach nothing else. |
| agent-loop identity | `gitlab_automation_mini` | The agent loop's own GitLab identity. Already present and in daily use; not added by this provisioning. |
| live-tier SSH key | `ssh_live_box_gitlab` | `pl server health`, `pl drush <site> --tier=live`, `pl logs`, `pl moodle …`. Live tier only. |
| git push identity | *(host-local, not shared)* | Clone/pull/push against `gitlab-host`. This host has its **own** key — it is not a copy of `authoring`'s. |

Non-credential config the host also needs, none of which contains a secret:
`nwp.yml`, `servers/<name>/.nwp-server.yml`, `sites/<name>/.nwp.yml`. These are
gitignored **topology**, not credentials — kept out of the repo for the same
reason the secrets registry is.

It also needs `yq` (mikefarah) **on the non-interactive PATH**, not just the
login PATH. `pl secrets verify-copy`, `audit --locations` and `provision` invoke
a bare `yq` on the far side of an ssh command, and `ssh host <cmd>` never reads
`~/.profile`. Without it those verbs go blind against the host.

### Everything on the host is DECLARED, on purpose

Every credential above is a `stored_in` row in the registry with a `host=<role>:…`
qualifier, so `pl secrets audit --locations` can see it and `pl secrets rotate`
reaches it.

This is the whole point. A credential copied to a host by hand is undeclared
**by construction**, and therefore invisible to rotation forever. That is not
hypothetical — it is the recorded defect on the `ci-host`, which holds 70
`auth.json` files and a whole `.secrets.yml`, six of seven values byte-identical
to live, that no rotation has ever touched because nothing ever named them.

So: **never `scp` a secret to a host.** Use the verb:

```bash
pl secrets provision <id> --to 'host=<role>:<path>:<ref>'          # dry run
pl secrets provision <id> --to 'host=<role>:<path>:<ref>' --apply  # write + declare
```

`provision` writes the copy and declares it in the *same* operation, verifies it
by SHA-256 read-back before touching the registry, and rolls the declaration
back if the write fails — so the registry can never claim a copy that is not
there. The value travels on stdin, never in argv, so it appears in no process
list and no shell history on either machine.

## What the `ai-host` must NEVER hold

| Excluded | Why |
|----------|-----|
| Anything reaching **prod** | The boundary above. Prod is the `ver` role's alone (ADR-0028). |
| `ver` credentials, deploy-gate `ed25519-sk` hardware keys | Deploy tier. The operator provisions those in person. |
| `.secrets.data.yml` (production DB, SSH, SMTP) | Operator-only tier; AI is deny-ruled from it. It is not on the host and must not be put there. |
| Any Linode API token | Reaches production infrastructure from the AI-readable tier. `linode.provision_token` did exactly that once and was revoked. |
| Admin / backup-decryption credentials | GitLab admin password, restic DR password, Gotify admin. Wrong tier; `pl secrets lint` fails on them with `TIER:`. |
| The root/operator GitLab PAT | Not needed. `gitlab_bot_ops_note` is the least-privilege token for issue work. |

## How to attach

```bash
ssh <ai-host>
tmux attach -t nwp
```

One line: `ssh <ai-host> -t 'tmux attach -t nwp'`.

Detach with `Ctrl-b d` — **detaching leaves the work running.** The session has
three windows: `main`, `agent`, `logs` (`Ctrl-b` then `0`/`1`/`2`).

The session is recreated on boot by the systemd **user** unit
`~/.config/systemd/user/nwp-tmux.service`, and `loginctl enable-linger` keeps the
tmux server alive when nobody is logged in. Check both:

```bash
ssh <ai-host> 'systemctl --user is-enabled nwp-tmux.service; tmux ls'
```

Start agent work *inside* the session, not in a bare `ssh` shell — a bare shell
dies with your connection, which is the failure this host exists to prevent.

## How to refresh it

```bash
ssh <ai-host>
cd ~/nwp
git status --porcelain     # ALWAYS look first — never clobber uncommitted work
git pull --ff-only origin main
```

If `git status` is not clean, stop and deal with it. This is a working host, not
a mirror.

Config files are gitignored and do **not** arrive with `git pull`. When
`nwp.yml`, a `servers/*/.nwp-server.yml` or a `sites/*/.nwp.yml` changes on
`authoring`, the agent host needs the new copy or its `pl` verbs resolve against
stale topology. There is no verb for this yet — see below.

Verify after any refresh:

```bash
ssh <ai-host> 'cd ~/nwp && ./pl issue ls | head'
ssh <ai-host> 'cd ~/nwp && ./pl server health live'
ssh <ai-host> 'cd ~/nwp && ./pl drush nwd --tier=live --execute -- status'
```

## Known gaps and operator actions

1. **No verb distributes topology config to a second control host.**
   `servers/*/.nwp-server.yml`, `sites/*/.nwp.yml` and `nwp.yml` were copied with
   `rsync`. They contain no credentials, but a hand-copy still drifts silently.
   Proposed: `pl server publish <name> --to=<role>`, or a broader
   `pl host provision <role>` that syncs the declared config set and reports
   drift. Until it exists, re-copy after any change.

2. **`pl issue ls` and `pl issue board` do not paginate.** They issue a single
   `per_page=100` request against ~145 open issues sorted `created_at` ascending
   — so an agent reading the board sees the **oldest 100** and never the newest
   45. `pl issue reconcile` already paginates and carries a comment about this
   exact bug; `ls`/`board` were not fixed with it.

3. **`ssh_live_box_gitlab` is a shared key with a large blast radius.** The
   service account it logs in as has `NOPASSWD: ALL` on `gitlab-host`, so this
   one key is root on the box that holds the trust root — and the same key is now
   on two AI-run machines. It is a **live-tier** credential, so the agent host
   holding it is within the boundary, but it is shared rather than per-host, so
   revoking one holder means re-keying all of them. Recommended: mint a per-host,
   forced-command-jailed key (as was done for the demo-reset key), then drop the
   shared key. Minting requires writing `authorized_keys` on the box; **no token
   in the registry holds that capability, so this is an operator action.**

4. **`gitlab_bot_ops_note` is the same value on `authoring` and the agent host.**
   Declared, so rotation reaches both. If you would rather the agent host had its
   own identity, mint a second project access token on the ops project (needs
   Maintainer there — no registry token has it), adopt it, and drop the
   `host=…` row.

5. **A `@file` location on a private key is a vacuous check.** `@file` is read as
   `head -1`, and every OpenSSH private key's first line is identical, so
   `verify-copy` would report MATCH between two unrelated keys. That is why
   `ssh_live_box_gitlab` declares the `.pub` halves — a single line, uniquely
   identifying, and not secret. It verifies the public half only. Fixing `@file`
   to hash whole files needs its own change: it would also alter the
   yaml-canonical vs `@file`-copy comparison inside `pl secrets sync`.

## See also

- `CLAUDE.md` — threat model, actor glossary, the `pl`-first standing order
- `docs/reference/role-vocabulary.md` — why this guide names roles, not hosts
- ADR-0017 — distributed build/deploy pipeline
- ADR-0028 — the `ver` role and the hardware-gated deploy gate
- `pl secrets --help` — `provision`, `adopt`, `verify-copy`, `audit --locations`
