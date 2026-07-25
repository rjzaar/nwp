# NWP Console

The `pl` surfaces as a **mesh-only, passkey-only, role-gated** web app (PWA).
Phases 1+2: dashboards + safe actions + roles + audit log. Push notifications
(Gotify) are deferred (Phase 3).

```
phone/laptop (Tailscale app → your headscale control URL)
        │  WireGuard mesh (transport gate)
        ▼
console host <tailnet-ip>:<port>  ← uvicorn binds the TAILNET IP ONLY
  https://console.<your-domain>:<port>   (public DNS A → the tailnet IP;
                                          resolvable anywhere, reachable only on the mesh)
```

Operator-specific values (ssh alias of the console host, FQDN, tailnet IP, port,
headscale URL) live in the **gitignored** `nwp.yml` under `settings.console`
(schema in `example.nwp.yml`) — never in this tree (P61 leakage gate).

## Security model (three gates, in order)

1. **Transport = the mesh.** The app binds the console host's tailnet IP only.
   The console FQDN points at tailnet space — off-mesh it routes nowhere.
2. **Auth = WebAuthn passkeys, no passwords.** Hardware security keys (Solo) and
   phone platform passkeys. WebAuthn *requires* a secure context and a DNS-name
   RP ID, hence the real Let's Encrypt cert (DNS-01; the DNS API token stays on
   the workstation — `pl console cert` issues there and pushes only the cert+key
   to the console host). Sessions: itsdangerous-signed cookies, 7 days,
   `Secure; HttpOnly; SameSite=Strict`.
3. **Roles + fail-closed actions.** `viewer` (GET), `operator` (+safe actions),
   `owner` (+user management). The ONLY shell-outs are the literal argv allowlist in
   `app/actions.py` — no interpolation, strict per-arg validators, **no live/prod
   verbs representable**. The console host holds no prod keys anyway (blast radius
   = the A14 dev/test tier). Every action POST appends to
   `~/.local/share/nwp-console/audit.jsonl` (also rendered at `/audit`).

## Deploy / operate (from the workstation)

```
pl console dns             # upsert the console A record -> tailnet IP (Linode API)
pl console cert            # issue/renew LE cert via DNS-01 locally, push cert+key over
pl console deploy          # rsync src -> host:~/nwp-console/src, venv, unit, restart, health
pl console status          # systemd + /health over the mesh
pl console user add <you> --role owner  # first-run bootstrap -> ONE-TIME enrolment link
pl console user reset <name>            # break-glass: revoke passkeys, fresh link (shell-only)
pl console user list
pl console enroll          # prints the Headscale pre-auth key runbook for a new device
pl console logs            # tail the console log
```

First-run bootstrap: `pl console user add <you> --role owner` prints a one-time
`/enroll?token=…` link (48 h, single use, token stored hashed). Open it on the
device that holds the passkey. Further users can be added from `/users` (owner
role) — but their device needs mesh access first (`pl console enroll`).

**Cert renewal is manual-ish:** Let's Encrypt certs last 90 days; re-run
`pl console cert` (idempotent). A `pl todo` freshness check is a good follow-up.

## Issues/CI panes token (operator-provisioned — never automated)

The issues + CI panes call the GitLab API with the **walled bot token pattern**
(`gitlab.ops_note_token` — non-admin, walled to nwp/ops; see
`private/secrets-registry.yml`, use `pl secrets` for any token work). Provision it
on the console host yourself:

```
ssh <console-host> 'umask 077 && mkdir -p ~/.config/nwp-console && cat > ~/.config/nwp-console/gitlab.token'
# paste the token value, Ctrl-D
```

`pl console deploy` never copies tokens. With no token file the panes degrade to
deep-links into GitLab; nothing breaks.

## Layout

```
scripts/console/
  app/            FastAPI app (main.py) + pure modules:
                  authz.py (roles) actions.py (allowlist) parsers.py store.py
                  runner.py (only process spawner) gitlab_api.py webauthn_flow.py
                  manage.py (shell CLI: python3 -m app.manage — used by pl console user)
  templates/      Jinja2 (base + panes; htmx partial swaps)
  static/         style.css, webauthn.js, sw.js, icons,
                  htmx.min.js  ← vendored htmx.org 2.0.4, integrity verified:
                  sha384-HGfztofotfshcF7+8n44JQL2oJmowVChPTg48S+jvZoztPfvwD79OC/LTtG6dMp+
  tests/          pytest, stdlib-only imports (no server / no venv needed)
  nwp-console.service   systemd --user unit (linger required on the host)
  requirements.txt
```

Runtime state on the console host (never in git):
`~/nwp-console/{src,venv,console.log}`,
`~/.local/share/nwp-console/{users.json,audit.jsonl,secret.key}` (0600),
`~/.config/nwp-console/{env,gitlab.token,tls/}`.

## Tests

```
python3 -m pytest scripts/console/tests/    # pure-python unit tests
bats tests/unit/test-console.bats           # pl console dispatch
```

## Honest limits

- `pl demo status` / `codes list` output is parsed heuristically (human tables);
  the panes always keep the raw text in a collapsible block. `pl rag --json` and
  `pl todo check --json` are real contracts.
- The fleet view reflects **the console host's** checkout/caches (`pl rag
  --no-todo` reads cached audit records on that host — typically empty unless
  synced); it is not a substitute for `pl rag` on the workstation.
- Backups pane is read-only (the sweep runs where the backups live).
- Live/prod anything: read-only by design — run it on the workstation (or the
  air-gapped deploy host for real prod).
