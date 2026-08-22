# live2prod

Deploy directly from live test server to production server.

**Last Updated:** 2026-01-14
**Reviewed:** 2026-07-26 — see the staleness notice below.

## Overview

The `live2prod` command deploys directly from a live test server to a production server. This is an advanced workflow for when the live server has been tested and you want to bypass staging.

## Usage

```bash
pl live2prod [OPTIONS] <sitename>
```

## Arguments

| Argument | Description |
|----------|-------------|
| `sitename` | Site name |

> ⚠️ **Partially stale (reviewed 2026-07-26).** This page was written in January 2026
> and predates every safety guard added since. The Options table below is incomplete
> and the step descriptions describe the older **fail-open** behaviour. The guards and
> flags documented in the two sections immediately below are authoritative; run
> `pl live2prod --help` for the live list.

## Guards that run before anything is pushed

Since mid-2026 this command refuses to proceed unless several conditions hold. Each
refusal is a safety feature, not a bug.

| Guard | What it checks | Source |
|-------|----------------|--------|
| **Canonical content guard** | that pushing a database outward will not overwrite content that real people created on the server (ops#33) | `canonical_guard_content_push()` |
| **Maturity guard** | that the site's code-flow class permits this deploy (P67/ops#48) | `maturity_guard_deploy()` |
| **Pair guard** | that a paired site's ordering and identity-lock rules are respected (ADR-0031/ops#75) | `pair_guard()` |
| **Pre-deploy snapshot** | that a full webroot snapshot was taken **before** the destructive `rsync --delete`. **Fail-closed** — if the snapshot cannot be taken, the deploy stops | — |
| **Maintenance mode** | that maintenance mode was actually switched on. **Fail-closed** — if switching it on fails, the deploy aborts *before* `rsync --delete`, not after | — |

The two fail-closed guards are the important change. Previously a failure here let the
deploy continue, which could delete files with no recoverable snapshot.

## Override flags (all ledgered — none are routine)

| Option | What it does | Ledger |
|--------|--------------|--------|
| `--code-only` | Deploy code and configuration only; do **not** push the database. This is the correct shape for any site whose real content lives on the server, and it satisfies the identity-lock rule for paired sites (ADR-0031 D6). | — |
| `--override-canonical` | Push content even though the site is not canonical `dev`. **Overwrites the canonical content source.** | `private/canonical/<site>.log` |
| `--override-pair` | Proceed past a paired-site guard — wrong ordering, the identity-lock rule, or a red pair. | `private/pairs/<pair>.log` |
| `--override-snapshot` | Proceed with the destructive `rsync --delete` even though the pre-deploy webroot snapshot could not be taken. **The deletion is then UNRECOVERABLE.** | `private/snapshots/<site>.log` |

> **`--override-snapshot` is the dangerous one.** It removes the only thing standing
> between a failed deploy and permanent data loss. Do not use it to get past a
> disk-space problem — fix the disk-space problem.

See also: [How to: deploy a change](../../guides/howto-deploy.md).

## Options

| Flag | Description |
|------|-------------|
| `-h, --help` | Show help message |
| `-y, --yes` | Skip confirmation prompts |
| `-s, --step <n>` | Start from step n (1-8) |
| `--skip-backup` | Skip production backup (dangerous!) |

## Deployment Steps

1. **Validate Deployment** - Check live and production server configurations
2. **Backup Production** - Create database backup on production
3. **Export Live Configuration** - Run `drush config:export` on live
4. **Sync Files** - Rsync from live to production (server-to-server)
5. **Run Composer** - Install dependencies on production
6. **Database Updates** - Run `drush updatedb -y` on production
7. **Import Configuration** - Run `drush config:import -y` on production
8. **Clear Caches** - Run `drush cache:rebuild` on production

## Examples

### Deploy live to production
```bash
pl live2prod mysite
```

### Deploy without confirmation
```bash
pl live2prod -y mysite
```

### Skip production backup
```bash
pl live2prod --skip-backup mysite
```

### Resume from step 4
```bash
pl live2prod -s 4 mysite
```

## Recommended Workflow

For most deployments, use the safer two-step approach:

1. `pl live2stg mysite` - Pull live changes to staging
2. `pl stg2prod mysite` - Deploy staging to production

Use `live2prod` only when:
- Live server is thoroughly tested
- You need to bypass local staging
- Direct server-to-server deployment is preferred

## Rsync Excludes

- `.git` - Version control
- `sites/*/files` - User-uploaded files
- `sites/*/private` - Private files
- `vendor` - Composer dependencies (reinstalled via composer install)

## Prerequisites

- Live server must be configured in `nwp.yml`
- Production server must be configured in `nwp.yml`
- SSH access to both servers

## Configuration

```yaml
sites:
  mysite:
    live:
      server_ip: 192.0.2.10
      ssh_user: root
      webroot: /var/www/mysite
    production:
      server_ip: 192.0.2.20
      ssh_user: root
      webroot: /var/www/mysite
      domain: example.com
```

## Troubleshooting

### Cannot connect to live server
- Verify live server is provisioned: `pl live --status mysite`
- Test SSH: `ssh <user>@<live_ip>`

### Cannot connect to production server
- Verify production configuration in nwp.yml
- Test SSH: `ssh <user>@<prod_ip>`

### Server-to-server rsync failed
- Verify live server can SSH to production
- May need to set up SSH keys between servers

## Exit Codes

- `0` - Deployment successful
- `1` - Deployment failed

## Related Commands

- [live](live.md) - Provision live server
- [stg2prod](stg2prod.md) - Deploy staging to production
- [live2stg](live2stg.md) - Pull live to staging

## See Also

- Production deployment workflows
- Server-to-server deployment documentation
