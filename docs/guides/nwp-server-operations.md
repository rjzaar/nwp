# nwp-server Agent Operations Guide

> **Status:** ACTIVE (self-deploying-prod path; ADR-0024). Complements — does not
> replace — `verifier-operations.md`, which covers the offline blue-green flow
> retained for hardware-gated/irreversible actions.
> **Last Updated:** 2026-07-01
>
> **Audience:** the operator or the control-loop, acting **on a production host**.
> `nwp-server` is the minimal, AI-free agent that host runs to pull, verify, and
> apply its own signed deploys. It is NOT `pl` — `pl` carries the authoring / AI /
> CI / SaaS surface and must never be present on a host that can write to prod.

## What This Is

`nwp-server` is a **build target** of the `nwp` source tree (ADR-0022/0024), not a
separate repo. It is assembled by `pl build-server` from an allowlist
(`build/nwp-server.include`) and then scanned **fail-closed** against
`build/nwp-server.deny-symbols`; any AI/CI/SaaS vendor token in the assembled
artifact fails the build. The artifact is separately signed with a hardware-rooted
key and installed on prod; the full `nwp` tree is never installed there.

The entrypoint is `bin/nwp-server`. It exposes exactly this capability set and
nothing else:

| Verb | What it does |
|------|--------------|
| `pull` | fetch a signed bundle over HTTPS and verify it (fail-closed) |
| `verify` | verify a local signed bundle without downloading |
| `apply` | verify → (opt-in) DR snapshot → run the bundle's own idempotent scripts; dry-run by default |
| `publish` | snapshot → sanitize → fail-closed PII gate → publish sanitized artifact |
| `backup` | raw restic DR snapshot for the offline custodian (ADR-0025) |
| `rollback` | restore the previous release/DB on this host |
| `status` | emit local health as JSON |

```bash
nwp-server version    # -> nwp-server v0.1.0  (distinct from `nwp`)
nwp-server help       # full verb list
nwp-server <verb> --help
```

## The Credential Ledger (the inviolable part)

An `nwp-server` host holds **exactly three** credentials and nothing else
(ADR-0024). Provisioning them is the last gate before the agent may apply with
authority:

1. a **read-only deploy key/token** — pull signed bundles (inbound, one-way);
2. a **write-only-to-its-own-repo deploy key** — publish the sanitized artifact
   (outbound, one-way; optionally locked with an `authorized_keys` forced
   `command=`);
3. the **minisign public key** — verify bundle signatures
   (default location: `keys/minisign/nwp-deploy.pub`, override with `--pubkey`).

**Zero** Personal Access Tokens, **zero** control-plane credentials, **zero** keys
that reach another host. A compromise of a prod host cannot pivot to the control
plane, to another prod host, or to any AI-capable machine — the blast radius is
that single box.

## pull + verify

Fetch a signed bundle from the self-hosted artifact host over HTTPS, then verify
it against the pinned minisign public key **and** recompute the payload/scripts
SHA-256 against the manifest. Verification is the same contract the build tier
signs against; the agent adds transport, not a second verification path.

```bash
# Pull with the read-only deploy token (read from a 0600 file, never argv/env):
nwp-server pull \
  --url https://<gitlab-host>/api/v4/projects/<enc>/packages/generic/<pkg>/<ver>/<bundle>.tar.gz \
  --out /var/lib/nwp-server/bundles \
  --token-file /etc/nwp-server/pull.token \
  --pubkey /etc/nwp-server/nwp-deploy.pub
```

- **HTTPS only.** A non-HTTPS `--url` is refused — the pull transport is HTTPS plus
  signature verification.
- **Fail-closed.** A downloaded bundle that does not verify is left in place for
  inspection and is **never** reported as good. The signature is **never** skipped
  on prod (`BUNDLE_VERIFY_NO_SIG` is forced empty by the agent).

Verify a bundle already on disk (no download):

```bash
nwp-server verify /var/lib/nwp-server/bundles/<bundle>.tar.gz \
  --pubkey /etc/nwp-server/nwp-deploy.pub
```

Exit `0` = verified; non-zero = transport error or verification failure.

## apply

Apply a **verified** bundle on this host. The agent does not contain bespoke
deploy logic — the bundle carries its own signed, idempotent `scripts/apply.sh`
(plus optional `pre-deploy.sh` / `post-deploy.sh`, F28 §3.5). The agent's job is
to verify, optionally snapshot, run those scripts in order, and fail loud.

**Dry-run is the default.** Nothing on the host is mutated without `--execute`:

```bash
# 1. See the plan (verifies the bundle, prints the steps, changes nothing):
nwp-server apply /var/lib/nwp-server/bundles/<bundle>.tar.gz \
  --site mysite --site-dir /var/www/mysite \
  --pubkey /etc/nwp-server/nwp-deploy.pub

# 2. Apply for real, taking a pre-apply restic DR snapshot first (fail-closed —
#    a failed snapshot aborts the apply):
nwp-server apply /var/lib/nwp-server/bundles/<bundle>.tar.gz \
  --site mysite --site-dir /var/www/mysite \
  --pubkey /etc/nwp-server/nwp-deploy.pub \
  --execute --snapshot -- --repo /var/backups/nwp-server/mysite \
                          --pass-file /etc/nwp-server/restic.pass
```

Everything after `--` is passed through to `server-backup.sh` (the ADR-0025
restic DR snapshot). Omit `--snapshot` to skip the pre-apply snapshot (not
recommended for a schema-changing deploy).

The bundle scripts run with CWD at the bundle root and this context exported:
`NWP_BUNDLE_DIR`, `NWP_PAYLOAD_DIR`, `NWP_SITE`, `NWP_SITE_DIR`.

### Rollback

Rollback in this model (F28 §3.4) is **"apply the previous good bundle"** — because
`apply.sh` is idempotent, roll-forward and roll-back are the same operation with a
different bundle id:

```bash
nwp-server apply /var/lib/nwp-server/bundles/<previous-bundle>.tar.gz \
  --site mysite --site-dir /var/www/mysite --execute
```

The agent therefore does **not** perform an unreviewed DB/code restore on failure.
If `apply.sh` fails it fails loud (leaving the F28 marker file its own
`pre-deploy.sh` checks next time), the pre-apply DR snapshot (if taken) remains
for the offline custodian `ver`, and the agent prints the exact recovery command.
`nwp-server rollback` restores a previously-recorded local rollback point where one
exists.

## status

Emit **local** health as JSON. Unlike the fleet `pl status` / `pl rag` (which read
the whole fleet and, for server stats, call a distrusted SaaS API), this reports
**only** what can be read from this host, with **no outbound network call at all**.
The control plane pulls this JSON; the prod host never pushes.

```bash
nwp-server status --site-dir /var/www/mysite
```

```json
{
  "agent": "nwp-server",
  "version": "0.1.0",
  "generated": "2026-07-01T05:09:06Z",
  "host": "prod1",
  "kernel": "6.x",
  "load1": 0.42,
  "uptime_seconds": 226742,
  "disk": { "path": "/var/www", "free_kb": 9442776, "used_percent": 61 },
  "sites": [
    { "name": "mysite", "path": "/var/www/mysite", "present": true,
      "git_ref": "abc1234", "drupal_bootstrap": true, "db_connected": true,
      "maintenance_mode": false }
  ]
}
```

Per-site fields (`git_ref`, `drupal_bootstrap`, `db_connected`, `maintenance_mode`)
are best-effort via the site's own drush under a short timeout; a missing or
down site degrades a field to `null` and never aborts the report. `status` always
exits `0` — a red field is data, not an error.

## Building & Auditing the Artifact (build tier, not prod)

On the build/test/sign tier:

```bash
pl build-server                     # assemble + fail-closed deny-scan -> build/out/nwp-server/
pl build-server --list              # print the include allowlist
pl build-server --scan-only DIR     # independently re-scan an assembled tree
```

The deny-scan returning zero AI/CI/SaaS matches is the mechanical form of
ADR-0022's "`strings` check returns zero AI-vendor symbols" success metric. The
artifact is signed with the hardware-rooted key and distributed to prod out of
band; prod verifies the signature before install.

## Security Reminders

- **Never run AI tooling on an `nwp-server` host.** No cloud AI, no local LLM, no
  authoring `pl`. The AI-free guarantee is build-time; keep it that way at runtime.
- **Never skip the signature.** The agent forces signature verification on; do not
  set `BUNDLE_VERIFY_NO_SIG`.
- **Three keys, all one-way.** Read-only-in, write-only-out, minisign pubkey. No
  PATs, no control-plane creds, no key that reaches another host.
- **Raw data never leaves prod.** The `publish` path sanitizes on this host behind
  a fail-closed PII gate; `backup` ships raw restic snapshots only to the offline
  custodian `ver`, which this host cannot delete.

## See Also

- [ADR-0024](../decisions/0024-self-deploying-prod-agent.md) — the self-deploying
  prod agent decision and capability set.
- [ADR-0022](../decisions/0022-nwp-verifier-binary-split.md) — the build-time
  AI-free split this target inherits.
- [ADR-0025](../decisions/0025-production-backup-to-ver.md) — the raw restic DR
  backup path (`backup` verb, custodian pull).
- [verifier-operations.md](verifier-operations.md) — the offline blue-green
  deploy flow retained for hardware-gated/irreversible actions.
