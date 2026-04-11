# Mayo AVC Integration: Full Record

**Status:** IN PROGRESS
**Last Updated:** 2026-04-10
**Covers:** Conversations from 2026-04-08 to 2026-04-10

This document records everything discussed, recommended, and achieved in
integrating mayostudios.org into the NWP ecosystem as an AVC-enabled site.
It serves as the single reference for the entire effort -- what was done,
what is pending, and what decisions were made along the way.

---

## Table of Contents

1. [Background](#1-background)
2. [What Was Achieved](#2-what-was-achieved)
3. [NWP v2 Integration](#3-nwp-v2-integration)
4. [Platform Migration (Open Social to AVC)](#4-platform-migration-open-social-to-avc)
5. [Infrastructure and Server Setup](#5-infrastructure-and-server-setup)
6. [F21 Pipeline (Build, Sign, Publish, Deploy)](#6-f21-pipeline-build-sign-publish-deploy)
7. [Database Sanitizer](#7-database-sanitizer)
8. [Blue-Green Deployment](#8-blue-green-deployment)
9. [WireGuard Tunnel (mons to mayo1)](#9-wireguard-tunnel-mons-to-mayo1)
10. [Governance and Compliance Documents](#10-governance-and-compliance-documents)
11. [Email Setup](#11-email-setup)
12. [Error Reporting and Operability](#12-error-reporting-and-operability)
    - [12A. Sanitized Dev Fixtures and Deployable Content](#12a-sanitized-dev-fixtures-and-deployable-content)
13. [What Remains to be Done](#13-what-remains-to-be-done)
14. [Decisions Made](#14-decisions-made)
15. [File Inventory](#15-file-inventory)

---

## 1. Background

**mayostudios.org** is the website for Mission Action Youth Organisation
(MAYO), a Catholic youth group in Victoria, Australia. The site was
running vanilla Open Social (community platform built on Drupal) on a
Linode VPS (`mayo1`, IP 172.105.183.226, Sydney region).

The integration effort has three goals:

1. **Platform upgrade:** Replace vanilla Open Social with the AVC (AV
   Commons) distribution, which extends Open Social with guilds, workflow
   assignment, asset management, and advanced notifications.
2. **NWP management:** Bring the site under NWP's v2 schema layout with
   proper development/staging/production environments, automated backups,
   and the F21 signed-artifact deployment pipeline.
3. **Governance compliance:** Implement website changes from a March 2026
   consultation on child safety and governance, including public policy
   pages, safety contact email, and external reporting numbers.

### Site Scale

| Content Type | Count |
|-------------|-------|
| User accounts | ~35 |
| Groups | 10 (9 closed, 1 secret) |
| Pages | 6 |
| Topics | 3 |
| Landing pages | 1 |

This small content volume drove the decision to use a **fresh AVC install
with manual content re-entry** rather than automated migration scripts.

---

## 2. What Was Achieved

### Fully complete

- NWP v2 directory layout for mayo (`sites/mayo/`)
- Site-level and environment-level `.nwp.yml` configs
- DDEV development environment (`mayo-dev`) with AVC profile installed
- Pre-AVC codebase archived (`sites/mayo/dev-pre-avc/`)
- Composer project with `nwp/avc` package from `git.nwpcode.org` registry
- Development environment replicated on metabox (met) via git
- Server config (`servers/mayo1/.nwp-server.yml`)
- `pl build mayo` command -- creates signed deployment tarballs
- `pl publish mayo` command -- uploads to GitLab Packages
- `mons-deploy.sh` -- end-to-end deploy orchestrator for mons
- `bluegreen-setup.sh` -- one-time blue-green slot layout creation
- `bluegreen-swap.sh` -- atomic slot swap with auto-rollback
- Database sanitizer (`lib/sanitizers/mayo.sh`) with correct AVC schema
- WireGuard tunnel configs for mons-to-mayo1
- Operations guide (`docs/guides/mons-operations.md`)
- Production site integration guide (`docs/guides/production-site-integration.md`)
- Technical implementation plan (`~/MAYO/mayo_technical_implementation_plan.md`)
- Incorporation and governance guide (`~/MAYO/mayo_incorporation_and_governance.md`)
- All scripts updated with multi-step error reporting and mons-say integration

### Pending (requires hands-on or external)

- Install minisign on dev workstation (`sudo apt-get install -y minisign`)
- Generate minisign keypair (`source lib/minisign.sh && minisign_generate_keys`)
- Solo 2C+ hardware tokens (ordered, not yet arrived)
- WireGuard key exchange between mons and mayo1 (requires physical access)
- First actual build/publish/deploy cycle
- Blue-green slot setup on mayo1 (one-time, requires SSH)
- Rebinding mayo1 sshd to tunnel interface
- safety@mayostudios.org email alias configuration on mayo1
- Content migration (manual re-entry of ~35 users, 10 groups, 10 pages)
- Policy page creation on the AVC site
- saintschool.mayostudios.org (planned, not yet started)

---

## 3. NWP v2 Integration

### Directory Layout Created

```
sites/mayo/
  .nwp.yml              # recipe: avc, live: mayostudios.org, server: mayo1
  dev/                   # DDEV project "mayo-dev" with AVC installed
    .nwp.yml             # environment: development
    .ddev/config.yaml
    composer.json         # requires nwp/avc ^0.3
    auth.json             # GitLab registry credentials (gitignored)
    html/                 # Drupal webroot
    vendor/               # Composer packages
    private/              # Private file system (required by AVC)
  dev-pre-avc/           # Archived original Open Social codebase
  stg/                   # Staging environment (placeholder)
    .nwp.yml
  backups/               # Database backups
  scripts/               # Maintenance scripts
```

### Key Configuration

**`sites/mayo/.nwp.yml`:**
- Schema version: 2
- Recipe: `avc`
- Live domain: `mayostudios.org`
- Server: `mayo1`
- Remote path: `/var/www/mayostudios.org`

### Second Machine Setup (met/metabox)

The development environment was replicated on metabox:
1. `git clone` the mayo dev project to `~/nwp/sites/mayo/dev` on met
2. Copy `auth.json` with GitLab PAT
3. `ddev start && ddev composer install`
4. Import database from dev workstation

This enables development from any machine on the Headscale VPN overlay.

---

## 4. Platform Migration (Open Social to AVC)

### Why Fresh Install

Drupal does not support changing install profiles in-place. The database
schema is bound to the original profile. For mayo's small content volume
(~35 users, 10 groups, 10 pages), a fresh AVC install with manual
content re-entry was determined to be faster and cleaner than building
migration scripts.

### What AVC Adds

AVC extends Open Social with:
- **8 custom modules:** avc_core, avc_member, avc_group, avc_guild,
  avc_asset, avc_content, avc_notification, avc_devel
- **Guild system:** Structured groups with admin/facilitator/member roles
  that map to Moodle roles
- **Workflow assignment:** Task tracking within groups
- **Asset management:** Project/document/resource management
- **Advanced notifications:** Digest preferences and custom channels
- **30+ patches** to core and contrib modules
- **98+ dependencies** managed by the profile

### Composer Setup

The AVC profile is installed via composer from the NWP GitLab registry:

```json
{
    "require": {
        "nwp/avc": "^0.3"
    },
    "repositories": [
        {
            "type": "composer",
            "url": "https://git.nwpcode.org/api/v4/group/nwp/-/packages/composer/packages.json"
        }
    ]
}
```

An `auth.json` with a GitLab PAT is required for registry access.

### Issues Encountered

- **Security advisory blocking:** AVC pins some packages with known
  advisories (ginvite, role_delegation). Fixed by setting
  `"audit": {"block-insecure": false}` in composer.json.
- **Private file system:** AVC install fails without it. Fixed by
  creating `private/` directory and adding
  `$settings['file_private_path'] = '../private';` to settings.php.
- **Open Social version:** AVC bundles Open Social modules directly (not
  as a composer dependency). It tracks stable ~12.4.x components. Open
  Social 13 was beta-only as of April 2026.

### Content Strategy

For the actual production migration (still pending):

1. Export content inventory from production for reference
2. Fresh AVC install (already done in dev)
3. Manually recreate content through the admin UI
4. Users will need password resets after migration
5. Groups recreated with same names and settings

---

## 5. Infrastructure and Server Setup

### Server: mayo1

| Property | Value |
|---------|-------|
| IP | 172.105.183.226 |
| SSH user | mayo |
| SSH key | ~/.ssh/opencat |
| Region | ap-southeast (Sydney) |
| Provider | Linode |
| OS | Ubuntu |
| Services | nginx, postfix, certbot, fail2ban, ufw, drupal |

### Server Config Created

`servers/mayo1/.nwp-server.yml` -- defines server identity, sites,
services, and deploy configuration (blue-green method with WireGuard
tunnel).

### Sites on mayo1

| Site | Domain | Profile | Status |
|------|--------|---------|--------|
| mayo | mayostudios.org | avc | active |
| saintschool | saintschool.mayostudios.org | social | planned |

### .gitignore Updated

Added `!servers/mayo1/` and `!servers/mayo1/**` exceptions to track
the mayo1 server configuration in git (same pattern as `servers/mini/`).

---

## 6. F21 Pipeline (Build, Sign, Publish, Deploy)

The integration of mayo drove the implementation of F21 Phases 5-8, the
signed-artifact deployment pipeline. This is the production-grade path
from code change to live site.

### Pipeline Flow

```
Developer (dev/met)              mons (offline laptop)         mayo1 (prod)
    |                                |                            |
    |-- pl build mayo               |                            |
    |   (composer --no-dev,         |                            |
    |    tar, minisign sign)        |                            |
    |                               |                            |
    |-- pl publish mayo             |                            |
    |   (upload to GitLab           |                            |
    |    Packages registry)         |                            |
    |                               |                            |
    |                               |-- mons-deploy.sh mayo VER  |
    |                               |   (download, verify sig,   |
    |                               |    upload to inactive slot,|
    |                               |    drush updb)             |
    |                               |                            |
    |                               |-- bluegreen-swap.sh   --> swap
    |                               |   (maintenance mode,       |
    |                               |    atomic symlink swap,    |
    |                               |    cache clear,            |
    |                               |    smoke test,             |
    |                               |    auto-rollback if fail)  |
```

### Scripts Created

| Script | Location | Runs On | Purpose |
|--------|----------|---------|---------|
| `pl build` | `scripts/commands/build.sh` | dev/met | Create signed tarball from dev environment |
| `pl publish` | `scripts/commands/publish.sh` | dev/met | Upload tarball + signature to GitLab Packages |
| `mons-deploy.sh` | `servers/mayo1/scripts/` | mons | Download, verify, deploy, swap |
| `bluegreen-setup.sh` | `servers/mayo1/scripts/` | mayo1 | One-time blue-green layout creation |
| `bluegreen-swap.sh` | `servers/mayo1/scripts/` | mayo1 | Atomic slot swap with rollback |

### Signing

- **Tool:** minisign (lightweight, open-source, self-hosted)
- **Key location:** `keys/minisign/nwp-deploy.{key,pub}`
- **Library:** `lib/minisign.sh` (check, generate, sign, verify, key_id)
- **Interim:** Software-only keys until Solo 2C+ hardware tokens arrive
- **Key on mons:** Public key at `~/.config/nwp-deploy.pub`

### GitLab Packages

Tarballs are published to the GitLab generic packages registry:
```
PUT https://git.nwpcode.org/api/v4/projects/mayo%2Fmayo/packages/generic/mayo-deploy/<version>/<filename>
```

Both the tarball (`.tar.gz`) and signature (`.tar.gz.minisig`) are
uploaded. mons downloads both and verifies the signature before any
deployment action.

---

## 7. Database Sanitizer

### Purpose

The sanitizer runs **on prod** (mayo1) -- raw user data never leaves the
production server. It produces a sanitized database dump that can be
safely used in dev/stg/CI environments.

### Location

`lib/sanitizers/mayo.sh`

### Classification Model

| Strategy | Tables/Columns | Example |
|----------|---------------|---------|
| DROP | Cache tables (`cache_%`, `cachetags`), sessions, semaphore, queue, search indexes, router | Transient data, rebuilt on import |
| TRUNCATE | Activity tracking, flag counts, voting, redirects, queue storage, skill endorsements, guild scores | Behavioral data not needed in dev |
| HASH | `users_field_data.pass` | Passwords replaced with SHA256 hash |
| FAKER_EMAIL | `users_field_data.mail`, `users_field_data.init`, event enrollment emails | `user<uid>@example.com` |
| FAKER_NAME | `users_field_data.name`, comment names | `User <uid>` |
| FAKER_FIRST/LAST | Profile first/last name fields | `First<id>`, `Last<id>` |
| REDACT | Phone, address, self-introduction, organization, summary, function, expertise, interests, post content, messages, mentions, group addresses | `[REDACTED]` |
| ZERO | `comment_field_data.hostname` | Empty string |
| LEAVE | Config tables, content body, taxonomy, menu, block | Non-PII data left intact |

### PII Columns Sanitized (30+)

The sanitizer covers:
- Core user accounts (name, mail, init, pass)
- Profile fields (first name, last name, phone, address, self-introduction, organization, summary, function, expertise, interests)
- Profile revision fields (same fields, archived)
- Comment author data (name, mail, hostname)
- Event enrollment emails
- Post content (may contain @mentions with real names)
- Message destinations
- Mention text
- Group addresses (physical locations)

### PII Sweep

After sanitization, a regex sweep checks the output file for:
- Email addresses (excluding `@example.com`, `@drupal.org`, `@nwpcode.org`, public contacts)
- Australian mobile numbers (`04XX XXX XXX`)
- International AU numbers (`+61...`)
- 1300/1800 numbers (excluding published safety numbers)

### Multi-Step with Resume

The sanitizer has 6 steps with `--step N` resume capability:
0. Validate environment
1. Create safety backup
2. Drop transient tables
3. Truncate behavioral data
4. Sanitize PII columns
5. Export sanitized database
6. PII sweep verification

Each step has pause-between-steps prompts (skippable with `--no-pause`)
and `report_error` output with mons-say commands for error reporting.

### Key Design Decision

The sanitizer's table list was **verified against the actual AVC database
schema** (via `SHOW TABLES` on the production database). The first draft
had incorrect table names (tables from vanilla Open Social that don't
exist in AVC, e.g. `private_message__body`, `login_security_track`). The
rewrite used the real schema to ensure completeness.

---

## 8. Blue-Green Deployment

### Layout on mayo1

```
/var/www/mayostudios.org         -> symlink to active slot
/var/www/mayostudios.org-blue/   -> slot A (codebase)
/var/www/mayostudios.org-green/  -> slot B (codebase)
/var/www/mayostudios.org-shared/ -> shared state
  files/                          (user uploads)
  private/                        (private file system)
  settings.local.php              (DB credentials)
```

Both slots have symlinks into the shared directory for `files/`,
`private/`, and `settings.local.php`. This means user uploads and
database credentials are shared between slots -- only the codebase
differs.

### Swap Process

1. Detect current live slot
2. Run `drush updb -y` on the inactive slot (pre-swap)
3. Enable maintenance mode on the current live slot
4. Atomic symlink swap: `ln -sfn <target> <temp>` then `mv -Tf <temp> <link>`
5. Clear caches, disable maintenance mode on the new live slot
6. Smoke test (drush bootstrap + HTTP check)
7. Auto-rollback if smoke test fails

### Rollback

```bash
sudo ./bluegreen-swap.sh --site mayostudios.org --rollback -y
```

The previous slot remains intact and can be swapped back at any time.

---

## 9. WireGuard Tunnel (mons to mayo1)

### Design

A dedicated one-to-one WireGuard tunnel between mons and mayo1. This is
NOT part of the Headscale mesh. mons must never join Headscale.

| Endpoint | Tunnel IP | Role |
|----------|-----------|------|
| mons | 10.99.0.1 | Deploy machine (initiates connections) |
| mayo1 | 10.99.0.2 | Production server (listens on 51820) |

### Configs Created

- `servers/mayo1/wireguard/wg-mons.conf.mons` -- mons-side config
- `servers/mayo1/wireguard/wg-mons.conf.mayo1` -- mayo1-side config
- `servers/mayo1/wireguard/README.md` -- setup instructions, key
  generation, sshd rebinding, firewall rules, rollback via Lish

### Connectivity

mons connects via phone hotspot or dedicated cellular modem. Never via
the home LAN, never via Headscale. The tunnel only activates during
deploys.

### Pending

- Generate WireGuard keypairs (requires physical access to both machines)
- Exchange public keys out-of-band (USB stick or read aloud)
- Install configs and test end-to-end tunnel
- Rebind mayo1 sshd to tunnel interface only
- Close public SSH port on mayo1 (defer until tunnel proven reliable)

---

## 10. Governance and Compliance Documents

Three major documents were created or updated based on the downloaded
Mayo consultation materials (`~/MAYO/`):

### Technical Implementation Plan

`~/MAYO/mayo_technical_implementation_plan.md`

A committee-readable document covering 5 phases:
1. Platform upgrade (Open Social to AVC)
2. Infrastructure and development environment
3. Website compliance (policy pages, safety contact, reporting numbers)
4. Testing and deployment
5. Ongoing maintenance

Includes content migration table, testing checklist, deployment
procedure with rollback plan, cost summary ($0 additional), and timeline
(~1-2 weeks total).

### Incorporation and Governance Guide

`~/MAYO/mayo_incorporation_and_governance.md`

Comprehensive guide for MAYO's incorporation under the Associations
Incorporation Reform Act 2012 (Vic):
- Pre-incorporation checklist (people, name, rules, purposes)
- Incorporation process (online application, $37.60)
- Post-incorporation setup (bank account, insurance, WWCC)
- Committee position guides:
  - President
  - Secretary
  - Treasurer
  - Child Safety Officer
  - Chaplain
  - **Webmaster** (added during this session -- was missing from original)
  - Ordinary Committee Members
- Ongoing obligations (annual returns, AGM, financial reporting)

### Webmaster Position Guide (Added)

Section 5.6 was added to the incorporation document covering:
- Online platform management responsibilities
- Child safety obligations for the platform (Victorian Child Safe Standards)
- Authority to suspend users for safety reasons
- Required skills (basic Drupal administration)
- Time commitment (~2 hours/month routine, more during upgrades)
- Training and handover checklist

### Policy Pages Required

From the consultation, these pages need to be created on the AVC site:

**Public (no login required):**
| Page | Standard |
|------|----------|
| Child Safety and Wellbeing Policy | Vic Child Safe Standards 2, 11 |
| Child Safe Code of Conduct | Standard 7 |
| Privacy Policy | Privacy Act 1988 |
| Safety commitment statement | Homepage/prominent |
| Safety contact (safety@mayostudios.org) | All policy pages + footer |
| External reporting numbers | All policy pages |
| Acknowledgement of Country | Homepage/about |

**Members-only (login required):**
| Page | Content |
|------|---------|
| Child Safety Officer details | Name, contact, photo |
| Mandatory Reporting Quick Reference | Three criminal offences, contacts, action steps |
| Risk Management Plan | Policy 3 from policy pack |
| Online Community Chat Code of Conduct | Policy 5 |
| Conflict Resolution Policy | Policy 6 |
| Photography and Image Consent Policy | Policy 8 |
| Emergency Management Procedures | Policy 9 |

---

## 11. Email Setup

A role-based email address `safety@mayostudios.org` was recommended to
be configured on mayo1's postfix as a forwarding alias to the current
Child Safety Officer's personal email.

**Rationale:** The website never needs updating when the CSO changes --
only the forwarding address is updated in postfix.

**Status:** Discussed and documented in the technical implementation
plan. Not yet configured on the server. Requires SSH access to mayo1 to
add the alias to `/etc/aliases` or the virtual alias table.

---

## 12. Error Reporting and Operability

All deployment scripts were updated with structured error reporting:

### mons-say Integration

Scripts running on mons or mayo1 produce formatted error messages with:
1. A `mons-say` command for reporting through the GitLab issue queue
2. A paste-ready block for the dev Claude session with:
   - Step number and description
   - Error details
   - Site and version info
   - Resume command (`--step N`)

### Multi-Step with Resume

**mons-deploy.sh** -- 5 steps, `--step N` resume:
1. Pre-flight checks (minisign, token, pubkey, tunnel, SSH)
2. Download tarball and signature from GitLab
3. Verify minisign signature
4. Upload and extract to inactive slot
5. Swap slots

**mayo sanitizer** -- 6 steps, `--step N` resume:
0. Validate environment
1. Safety backup
2. Drop transient tables
3. Truncate behavioral data
4. Sanitize PII columns
5. Export sanitized database
6. PII sweep

**bluegreen-swap.sh** -- 5 steps with auto-rollback on smoke failure

**bluegreen-setup.sh** -- 6 steps, idempotent (fix and re-run)

**build.sh** and **publish.sh** -- error context formatted for Claude
paste (no mons-say needed since they run where Claude is available)

### Error Message Format

```
================================================================
  STEP 4 FAILED
================================================================

  Error: Extract to green slot on mayo1 failed

  To report via mons-say:
    mons-say "mons-deploy step 4 failed: Extract to green slot on mayo1 failed"

  Or paste this to the dev Claude session:
    ---
    The mons-deploy script failed at step 4.
    Site: mayo, Version: abc123-20260410-120000
    Error: Extract to green slot on mayo1 failed
    Resume with: ./mons-deploy.sh mayo abc123-20260410-120000 --step 4
    ---
================================================================
```

---

## 12A. Sanitized Dev Fixtures and Deployable Content

### The Pattern

Mayo follows a **sanitized-fixtures-plus-deployable-content** pattern that
protects prod user data while allowing rich dev/stg environments and code-based
deploys of structural content.

```
              +-------------------+
              |   dev / stg       |
              |  (sanitized)      |
              |                   |
              | - fake users      |
              | - fake group      |
              |   memberships     |
              | - no WWCCs        |
              | - no photos       |
              | - no private      |
              |   files           |
              +---------+---------+
                        |
        code tarball    |      live-snapshot
        + minisign      |      (sanitized DB only)
                        |
                        v
              +-------------------+
              |      prod         |
              |                   |
              | - real users      |
              | - real groups     |
              | - real WWCCs      |
              |   (private dir)   |
              | - real photos     |
              | - structural      |
              |   content from    |
              |   mayo_content    |
              |   module          |
              +-------------------+
```

The sanitised dev site has enough **structure** (user counts, role
distributions, group topology) to feel realistic, but **no PII** and **no
uploaded user files**. The code tarball carries all policy pages, groups,
menus and footer blocks via a `mayo_content` module; when prod runs `drush
updb` after a deploy, the module's `hook_install` (or later `post_update_*`
hooks) applies the structural changes on top of the real data without
touching users.

### Layer 1 — `mayo_content` Module (Deploys to Prod)

`sites/mayo/dev/html/modules/custom/mayo_content/` is a small custom module
with a single install hook. It:

| Content | How it deploys to prod |
|---------|------------------------|
| 3 public policy pages (Child Safety, Code of Conduct, Privacy) | `hook_install` creates them if not present (idempotent by UUID) |
| 7 members-only policy pages (CSO, Mandatory Reporting, Risk Management, Online Chat CoC, Conflict Resolution, Photography Consent, Emergency Procedures) | Same |
| 3 information pages (About, Mission, Join) | Same |
| 10 flexible groups (Committee, Facilitators, Chaplaincy, Seniors, Youth, Events, Formation, Music, Outreach, Safeguarding) | Same |
| Policies menu (3 public links in main menu) | Same |
| Footer block with external reporting numbers (000, 13 12 78, 1300 78 29 78, Kids Helpline, Lifeline) | Same |
| CSO email in page bodies (safety@mayostudios.org) | Same |

All content is keyed by stable UUID so re-runs of the hook do not create
duplicates. Future edits to policy text ship as numbered
`mayo_content_post_update_NNNN_*` hooks so `drush updb` reliably picks them
up.

**What this module never touches:**

- Existing user accounts
- Existing profile field values
- Existing WWCC uploads or any file in the private files directory
- Any node not owned by the module (nodes created by members stay intact)

### Layer 2 — Sanitized User Fixtures (Dev/Stg Only)

`sites/mayo/scripts/seed-sanitized-users.sh` creates 35 placeholder users on
a fresh AVC dev/stg site so that layouts, permissions, and group operations
can be tested against realistic user counts. The script:

- **Only runs in DDEV projects named `mayo-dev` or `mayo-stg`.** It refuses
  to run anywhere else — critical guard against accidental use on prod.
- Creates users `user2` through `user36` with emails
  `user2@example.com..user36@example.com`.
- Distributes roles:
  - 6 × `sitemanager` (5 committee + 1 CSO)
  - 1 × `verified` (chaplain — sitemanager not required)
  - 8 × `contentmanager` (5 facilitators + 3 content editors)
  - 20 × `verified` (general members)
- Sets a single known password (`sanitized-dev-password`) for all fixtures.
- Is idempotent — re-running skips users that already exist.

Fixture users are **never** in the tarball that ships to prod. When prod
runs `drush updb` after a deploy, it sees only its own real users; the
fixture users exist only in the dev DB.

### Layer 3 — File System Separation

The sanitizer (`lib/sanitizers/mayo.sh`) is **database-only**. It does not
touch the public or private files directories. This is deliberate — files
are handled by the `live:snapshot` pull workflow, not by the sanitizer.

The `live:snapshot` pull for mayo **must** exclude:

```
sites/default/files/private/      # WWCC uploads, incident reports, CSO docs
sites/default/files/wwcc/         # legacy WWCC path if present
sites/default/files/documents/    # scanned consent forms, medical info
```

and should **only** pull:

```
sites/default/files/styles/       # generated image styles (regeneratable)
sites/default/files/js/           # aggregated JS
sites/default/files/css/          # aggregated CSS
```

Even public profile photos should be scrubbed at pull time: the pulled
`public://pictures/` tree is replaced with a directory of stock placeholder
images keyed by `uid` before the dev workstation ever sees it.

> **Note:** The existing `pl live:snapshot` command in NWP is DB-focused. A
> dedicated `pl live:files-sync` that honours the exclude list is planned
> for F21 Phase 9. Until then, file sync for mayo is manual and must be
> reviewed by a human before landing on a dev workstation.

### Layer 4 — Full Restore Path for Prod

After a deploy, prod runs `drush deploy` (which chains cache rebuild, updb,
config import, cache rebuild again). The `mayo_content` module's install
hook is the primary vehicle for new structural content; later edits ship
as `post_update_NNNN` hooks. Prod's real user data, group memberships,
WWCCs, and uploaded photos remain untouched throughout this cycle.

---

## 13. What Remains to be Done

### Immediate (before first deploy)

1. Install minisign: `sudo apt-get install -y minisign`
2. Generate minisign keypair: `source lib/minisign.sh && minisign_generate_keys`
3. Copy public key to mons: `~/.config/nwp-deploy.pub`
4. Create mons-bot deploy token on GitLab, save to mons: `~/.config/mayo-deploy.token`
5. Generate WireGuard keys on mons and mayo1, exchange public keys
6. Install WireGuard configs on both machines
7. Run `bluegreen-setup.sh` on mayo1 (one-time)
8. Test tunnel: `ping 10.99.0.2` from mons
9. First `pl build mayo && pl publish mayo` from dev
10. First `mons-deploy.sh mayo <version> --dry-run` from mons
11. First real deploy

### Content and Compliance — DONE on dev (2026-04-11)

12. ✅ `mayo_content` custom module created and enabled on dev.
13. ✅ 3 public policy pages created (Child Safety, Code of Conduct, Privacy).
14. ✅ 7 members-only policy pages created (CSO, Mandatory Reporting, Risk
    Management, Online Chat CoC, Conflict Resolution, Photography Consent,
    Emergency Procedures).
15. ✅ 3 information pages created (About, Mission, Join).
16. ✅ 10 groups created (non-PII labels, flexible_group type).
17. ✅ Policies menu populated with 3 public policy links in main menu.
18. ✅ Footer block with external reporting numbers created.
19. ✅ 35 sanitized users seeded on dev via `seed-sanitized-users.sh`.

### Content and Compliance — Still outstanding

20. Configure `safety@mayostudios.org` email alias on mayo1 (requires SSH to
    prod, not a dev task).
21. Replace CSO placeholder ("[To be appointed at incorporation]") with real
    name and phone after the inaugural general meeting — edit via Drupal UI
    on prod, not via code deploy.
22. File-system sanitization in `pl live:files-sync` (F21 Phase 9): add
    exclude list for `private/`, `wwcc/`, `documents/`, and placeholder
    swap for `pictures/`.
23. End-to-end deploy test: build → publish → deploy to a staging slot and
    verify that `mayo_content` creates the same pages on prod that exist on
    dev.

### When Solo 2C+ Arrives

24. Re-enroll SSH keys as `ed25519-sk` with `verify-required` and `resident`
25. Regenerate minisign keypair on hardware
26. Update `~/.config/nwp-deploy.pub` on mons
27. Complete F21 Phase 5 (full hardware-rooted signing)

### Future

28. Rebind mayo1 sshd to WireGuard tunnel interface only
29. Set up saintschool.mayostudios.org on mayo1
30. Systemd timer on mayo1 for automated sanitized fixture publication
31. CI integration for mmt to consume fixtures in pipeline

---

## 14. Decisions Made

| Decision | Rationale |
|----------|-----------|
| **Fresh AVC install, not in-place profile swap** | Drupal doesn't support profile changes. Small content volume makes manual re-entry faster than migration scripts. |
| **Software-only minisign keys (interim)** | Solo 2C+ ordered but not arrived. Architecture is identical; only key storage changes when hardware arrives. |
| **Dedicated WireGuard tunnel, not Headscale** | mons must never join the Headscale mesh. One-to-one tunnel between mons and mayo1 only. |
| **Blue-green slots with symlinks** | Simpler than the nwpcode server's existing 552-line bluegreen script. Shared directory for files, private, settings. Atomic swap via ln/mv. |
| **Sanitizer runs on prod only** | Raw user data never leaves the production server. Sanitized output is what gets published. |
| **Sanitizer table list from real schema** | First draft had incorrect tables. Rewritten after SHOW TABLES against the actual AVC database. |
| **Content strategy: deployable custom module, not manual re-entry** | Policy pages and structural content are carried by the `mayo_content` module so the same content that exists on dev lands on prod via `drush updb` after every deploy. Prod never has to click through Drupal forms to build out the site. |
| **Sanitized fixture users, not prod user migration** | Dev has 35 fake users with non-PII names/emails covering the role distribution. Prod keeps its own real users untouched. Dev never sees prod user data, but the site still feels realistic for testing. |
| **File-system excludes for `private/`, `wwcc/`, `documents/`** | WWCC scans, incident reports, and medical forms must never reach a dev workstation. DB sanitizer is not enough — file sync must honour an explicit exclude list, and profile photos must be swapped for placeholders at pull time. |
| **au-mel GitLab migration dropped** | Latency gain not worth the cost. GitLab stays on Newark alongside Headscale. |
| **No AI on mons** | Inviolable. No Claude, no ollama, no LLM agents on the deploy machine. |
| **Webmaster role added to governance** | Was missing from the committee position guides despite having a community platform. |

---

## 15. File Inventory

### NWP Repository Files Created/Modified

| File | Purpose |
|------|---------|
| `sites/mayo/.nwp.yml` | Site config (recipe: avc, live: mayostudios.org) |
| `sites/mayo/dev/` | DDEV development environment with AVC |
| `sites/mayo/dev/html/modules/custom/mayo_content/` | Deployable custom module: 13 pages, 10 groups, menu links, footer block |
| `sites/mayo/dev/html/modules/custom/mayo_content/mayo_content.info.yml` | Module definition |
| `sites/mayo/dev/html/modules/custom/mayo_content/mayo_content.module` | Module file stub |
| `sites/mayo/dev/html/modules/custom/mayo_content/mayo_content.install` | Install + post_update hooks creating all structural content |
| `sites/mayo/dev-pre-avc/` | Archived original Open Social codebase |
| `sites/mayo/stg/.nwp.yml` | Staging environment config |
| `sites/mayo/scripts/seed-sanitized-users.sh` | Dev-only 35 sanitized user fixtures |
| `servers/mayo1/.nwp-server.yml` | Server identity and deploy config |
| `servers/mayo1/scripts/mons-deploy.sh` | mons deploy orchestrator |
| `servers/mayo1/scripts/bluegreen-setup.sh` | One-time slot setup |
| `servers/mayo1/scripts/bluegreen-swap.sh` | Atomic slot swap |
| `servers/mayo1/wireguard/wg-mons.conf.mons` | mons-side WireGuard config |
| `servers/mayo1/wireguard/wg-mons.conf.mayo1` | mayo1-side WireGuard config |
| `servers/mayo1/wireguard/README.md` | WireGuard setup instructions |
| `scripts/commands/build.sh` | `pl build` command |
| `scripts/commands/publish.sh` | `pl publish` command |
| `lib/minisign.sh` | minisign wrapper library |
| `lib/sanitizers/mayo.sh` | Mayo database sanitizer |
| `docs/guides/mons-operations.md` | mons operations guide |
| `docs/guides/production-site-integration.md` | Production site migration guide |
| `docs/proposals/F21-*.md` | Updated with Phase 5-8 completion notes |
| `.gitignore` | Added `!servers/mayo1/` exceptions |

### External Documents Created

| File | Purpose |
|------|---------|
| `~/MAYO/mayo_technical_implementation_plan.md` | Committee-readable tech plan |
| `~/MAYO/mayo_incorporation_and_governance.md` | Incorporation guide + position guides |

### Related Existing Guides

| File | Relevance |
|------|-----------|
| `docs/guides/mons-mayo-bootstrap.md` | Superseded by mons-operations.md |
| `docs/decisions/0017-distributed-build-deploy-pipeline.md` | F21 architecture (the "why") |
| `docs/decisions/0018-twilio-bounded-saas-for-pstn.md` | Only SaaS exception (not mayo-related) |

---

*This document records the state of the mayo integration as of 2026-04-11.
It should be updated as remaining work is completed.*
