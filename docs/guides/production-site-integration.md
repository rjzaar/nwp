# Production Site Integration Guide

**Status:** ACTIVE
**Last Updated:** 2026-04-10
**Covers:** Full lifecycle from existing Drupal site to production deployment via F21 pipeline

This is the definitive guide for bringing an existing production Drupal site
into NWP and deploying it via the signed-artifact pipeline. It was written
from real experience integrating mayostudios.org (April 2026) and includes
every step, script, pitfall, and decision encountered along the way.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Pre-Integration Assessment](#2-pre-integration-assessment)
3. [Phase 1: Scaffold the v2 Layout](#3-phase-1-scaffold-the-v2-layout)
4. [Phase 2: Set Up the Codebase](#4-phase-2-set-up-the-codebase)
5. [Phase 3: Content Strategy](#5-phase-3-content-strategy)
6. [Phase 4: Multi-Machine Replication](#6-phase-4-multi-machine-replication)
7. [Phase 5: Server Configuration](#7-phase-5-server-configuration)
8. [Phase 6: Database Sanitizer](#8-phase-6-database-sanitizer)
9. [Phase 7: Build and Publish (dev/met)](#9-phase-7-build-and-publish)
10. [Phase 8: Blue-Green Deployment Setup (mayo1)](#10-phase-8-blue-green-deployment-setup)
11. [Phase 9: WireGuard Tunnel (mons to prod)](#11-phase-9-wireguard-tunnel)
12. [Phase 10: First Deploy via mons](#12-phase-10-first-deploy-via-mons)
13. [Ongoing Operations](#13-ongoing-operations)
14. [Open Social to AVC Migration](#14-open-social-to-avc-migration)
15. [Error Reporting and Recovery](#15-error-reporting-and-recovery)
16. [Troubleshooting](#16-troubleshooting)
17. [Decisions and Rationale](#17-decisions-and-rationale)
18. [Script Inventory](#18-script-inventory)
19. [Complete Checklist](#19-complete-checklist)

---

## 1. Overview

Integration is a multi-phase process that takes a Drupal site from "running
somewhere, managed manually" to "fully managed by NWP with signed-artifact
deployment via mons."

The pipeline looks like this:

```
Developer (dev/met)              mons (offline laptop)         prod server
    |                                |                            |
    |  Phase 1-4: scaffold,          |                            |
    |  codebase, content,            |                            |
    |  multi-machine                 |                            |
    |                                |                            |
    |-- pl build <site>             |                            |
    |   (composer --no-dev,         |                            |
    |    tarball, minisign sign)     |                            |
    |                                |                            |
    |-- pl publish <site>           |                            |
    |   (upload to GitLab           |                            |
    |    Packages registry)         |                            |
    |                                |                            |
    |                               |-- mons-deploy.sh           |
    |                               |   (download, verify sig,   |
    |                               |    upload to inactive slot) |
    |                               |                            |
    |                               |-- bluegreen-swap.sh   --> swap
    |                               |   (maintenance mode,       |
    |                               |    atomic swap, smoke test,|
    |                               |    auto-rollback on fail)  |
```

### What Runs Where

| Step | Machine | Script | AI Present? |
|------|---------|--------|-------------|
| Scaffold and develop | dev (this machine) | Manual / DDEV | Yes (Claude) |
| Build tarball | dev or met | `pl build <site>` | Yes |
| Sign tarball | dev or met | (part of `pl build`) | Yes |
| Publish to GitLab | dev or met | `pl publish <site>` | Yes |
| Download + verify | mons | `mons-deploy.sh` | **No** |
| Deploy to slot | mons -> prod | `mons-deploy.sh` (via SSH) | **No** |
| Swap slots | prod server | `bluegreen-swap.sh` | **No** |
| Sanitize DB | prod server | `lib/sanitizers/<site>.sh` | **No** |

### Security Model

- **AI never touches production.** Dev/met build and sign. Mons verifies
  and deploys. Mons has no AI tooling.
- **Trust flows through signatures.** Artifacts are trusted because they
  carry a valid minisign signature, not because they came from a "trusted"
  host.
- **Raw user data never leaves prod.** The sanitizer runs on prod. Only
  sanitized database dumps are exported.
- **Dedicated WireGuard tunnel.** mons connects to prod via a one-to-one
  WireGuard tunnel, not via Headscale or the home LAN.

---

## 2. Pre-Integration Assessment

Before starting, document the current state of the production site.

### Information to Gather

```bash
# On the production server (or from an imported DB)
drush status --fields=drupal-version,install-profile,db-driver,php-version
drush sql:query "SELECT COUNT(*) FROM node"
drush sql:query "SELECT COUNT(*) FROM users_field_data WHERE uid > 0"
drush sql:query "SELECT type, COUNT(*) FROM node_field_data GROUP BY type"
drush pm:list --type=module --status=enabled --no-core | head -30
```

### Decision Points

| Question | Options | Guidance |
|----------|---------|----------|
| What install profile? | standard, social, avc, custom | Determines recipe choice |
| Change profile? | Keep or change | Profile change = fresh install (Drupal limitation) |
| Content volume? | Small (<100 nodes) or large | Small: manual re-entry. Large: Migrate API |
| Users with active logins? | Yes/No | Users need password resets after migration |
| Custom modules? | List them | May be redundant after profile change |
| Server infrastructure? | Dedicated/shared Linode | Determines server config approach |

### Recipe Choices

| Recipe | Profile | When to Use |
|--------|---------|-------------|
| `d` | standard | Vanilla Drupal |
| `os` | social | Open Social (goalgorilla/open_social) |
| `avc` | avc | AVC distribution (composer-installed profile) |
| `avc-dev` | avc | AVC with editable profile source (for profile developers) |
| `dm` | standard | Drupal multisite |

---

## 3. Phase 1: Scaffold the v2 Layout

### Directory Structure

Every NWP site follows this layout:

```
sites/<name>/
  .nwp.yml              # Site-level config
  dev/                   # Development environment
    .nwp.yml             # Environment config
    .ddev/config.yaml    # DDEV project config
    composer.json        # Drupal dependencies
    html/                # Drupal webroot (docroot)
    vendor/              # Composer packages
    private/             # Private file system
    auth.json            # Composer registry credentials (gitignored)
  stg/                   # Staging environment (optional, for live-enabled sites)
    .nwp.yml
    .ddev/config.yaml
  backups/               # Database backups (shared across environments)
  scripts/               # Maintenance scripts (shared)
```

### Create the Directories

```bash
cd ~/nwp
mkdir -p sites/<name>/{dev,stg,backups,scripts}
```

### Site-Level .nwp.yml

Create `sites/<name>/.nwp.yml`:

```yaml
schema_version: 2
nwp_version_created: "0.30.0"
nwp_version_updated: "0.30.0"

project:
  name: <name>
  type: drupal
  recipe: <recipe>       # d, avc, avc-dev, os, dm
  purpose: indefinite
  created: "<ISO-8601>"

live:
  enabled: true
  domain: <production-domain>
  server: <server-name>   # matches servers/<server-name>/
  linode_id: shared        # or actual Linode ID
  type: shared             # shared or dedicated
  remote_path: /var/www/<site-path>

backups:
  directory: ./backups

environments:
  - dev
  - stg
```

### Environment-Level .nwp.yml Files

**`sites/<name>/dev/.nwp.yml`:**

```yaml
schema_version: 2
environment: development
parent_site: <name>
ddev_name: <name>-dev
```

**`sites/<name>/stg/.nwp.yml`:**

```yaml
schema_version: 2
environment: staging
parent_site: <name>
stage_file_proxy: true
database_sanitize: true
```

### DDEV Configuration

```bash
cd sites/<name>/dev
ddev config --project-name=<name>-dev --project-type=drupal --docroot=html \
  --php-version=8.2 --database=mariadb:10.11 --webserver-type=nginx-fpm
```

Add NWP environment variables to `.ddev/config.yaml`:

```yaml
web_environment:
  - DRUPAL_PROFILE=<profile>    # standard, social, avc
  - NWP_RECIPE=<recipe>         # d, os, avc, avc-dev
  - ENV_TYPE=development
  - ENV_DEBUG=1
hooks:
  post-start:
    - exec: composer install
```

---

## 4. Phase 2: Set Up the Codebase

### Option A: Standard Drupal (No Profile Change)

```bash
cd sites/<name>/dev
composer create-project drupal/recommended-project:^10.5 . --no-install
ddev start
ddev composer install
ddev drush site:install standard --site-name="<Site Name>" -y
```

### Option B: AVC Distribution

This is the most complex option. AVC is a custom distribution that bundles
Open Social modules with 8 additional custom modules, 30+ patches, and 98+
dependencies.

**1. Create composer.json:**

```json
{
    "name": "<name>/<name>-project",
    "description": "<Name> - AVC-based site",
    "type": "project",
    "license": "GPL-2.0-or-later",
    "repositories": [
        {
            "type": "composer",
            "url": "https://git.nwpcode.org/api/v4/group/nwp/-/packages/composer/packages.json"
        },
        {
            "type": "composer",
            "url": "https://packages.drupal.org/8"
        },
        {
            "type": "composer",
            "url": "https://asset-packagist.org"
        }
    ],
    "require": {
        "php": ">=8.1",
        "drupal/core-recommended": "^10.5",
        "nwp/avc": "^0.3"
    },
    "config": {
        "allow-plugins": {
            "composer/installers": true,
            "drupal/core-composer-scaffold": true,
            "drupal/core-project-message": true,
            "phpstan/extension-installer": true,
            "dealerdirect/phpcodesniffer-composer-installer": true,
            "cweagans/composer-patches": true,
            "oomphinc/composer-installers-extender": true
        },
        "sort-packages": true,
        "audit": {
            "block-insecure": false
        }
    },
    "extra": {
        "drupal-scaffold": {
            "locations": {
                "web-root": "html/"
            }
        },
        "installer-paths": {
            "html/core": ["type:drupal-core"],
            "html/libraries/{$name}": ["type:drupal-library", "type:bower-asset", "type:npm-asset"],
            "html/modules/contrib/{$name}": ["type:drupal-module"],
            "html/profiles/contrib/{$name}": ["type:drupal-profile"],
            "html/themes/contrib/{$name}": ["type:drupal-theme"],
            "drush/Commands/contrib/{$name}": ["type:drupal-drush"],
            "html/modules/custom/{$name}": ["type:drupal-custom-module"],
            "html/profiles/custom/{$name}": ["type:drupal-custom-profile"],
            "html/themes/custom/{$name}": ["type:drupal-custom-theme"]
        },
        "installer-types": ["bower-asset", "npm-asset"]
    },
    "minimum-stability": "dev",
    "prefer-stable": true
}
```

**2. Create auth.json** for the NWP GitLab registry:

```json
{
    "http-basic": {
        "git.nwpcode.org": {
            "username": "token",
            "password": "<your-gitlab-pat>"
        }
    }
}
```

Get the token from `.secrets.yml` (key: `gitlab.api_token`). Add `auth.json`
to `.gitignore`.

**3. Configure private file system** (required by AVC):

```bash
mkdir -p private
```

Edit `html/sites/default/settings.php` -- add **before** the DDEV include:

```php
$settings['file_private_path'] = '../private';
```

**4. Install:**

```bash
ddev start
ddev composer install
ddev drush site:install avc --site-name="<Site Name>" \
  --account-name=admin --account-pass=admin -y
```

### Common Issues During Codebase Setup

| Issue | Symptom | Fix |
|-------|---------|-----|
| Expired GitLab token | `composer install` returns 401 | Update `auth.json` with current token from `.secrets.yml` |
| Security advisory blocking | `composer install` refuses due to advisory | Set `"audit": {"block-insecure": false}` in composer.json |
| Private file system | AVC install fails: "Private File System: Not configured" | Create `private/` dir and add `$settings['file_private_path']` to settings.php |
| DDEV name conflict | "Project already exists" | `ddev stop --unlist <old-name>` first |
| PHP memory | composer runs out of memory | `ddev config --php-version=8.2` and restart |

---

## 5. Phase 3: Content Strategy

### Decision Matrix

| Content Volume | Profile Change? | Strategy |
|---------------|----------------|----------|
| < 100 nodes | No | Import production DB directly |
| < 100 nodes | Yes | **Fresh install + manual re-entry** |
| 100+ nodes | No | Import production DB directly |
| 100+ nodes | Yes | Fresh install + Migrate API |

### Strategy A: Import Production Database (Same Profile)

```bash
# Export from production (via SSH or drush)
ssh user@prod "cd /var/www/site && ./vendor/bin/drush sql:dump --gzip" > backups/prod-import.sql.gz

# Import to dev
zcat backups/prod-import.sql.gz | ddev drush sql:cli
ddev drush cr
ddev drush updb -y
```

### Strategy B: Fresh Install + Manual Re-entry (Small Site, Profile Change)

This is what we did with mayo: 10 nodes, 35 users, 10 groups. Manual
re-entry took less time than building and debugging migration scripts.

**Why this works:** Drupal does not support changing install profiles
in-place. The install profile is baked into the database. A fresh install is
the only clean path. With small content, manual re-creation is fastest.

**Steps:**

1. Document existing content before starting:
   ```bash
   # On production or from imported DB
   ddev drush sql:query "SELECT COUNT(*) FROM node"
   ddev drush sql:query "SELECT COUNT(*) FROM users_field_data"
   ddev drush sql:query "SELECT type, COUNT(*) FROM node_field_data GROUP BY type"
   ```

2. Fresh install with new profile (see Phase 2)

3. Recreate content:
   - **Users:** `ddev drush user:create <username> --mail=<email>` or via admin UI
   - **Content:** Create through the admin UI (preserves field validation and workflow)
   - **Groups:** Create through the admin UI (group types may differ between profiles)

4. Configure site settings, menus, blocks, and views

5. Export configuration baseline: `ddev drush config:export -y`

### Strategy C: Fresh Install + Migrate API (Large Site, Profile Change)

For sites with significant content that need a profile change:

1. Fresh install with new profile
2. Keep the old database accessible as a migration source
3. Write Drupal Migrate plugins to map old content types to new ones
4. Run migrations with rollback capability

This is complex and site-specific. See
[migration-workflow.md](./migration-workflow.md) for the Migrate API tooling.

### Content That Never Migrates Automatically

Regardless of strategy, these always need manual handling:

- **Custom modules** -- review compatibility with the new profile. Small
  form_alter modules may be redundant. Example: mayo had a `mayo_user_form`
  module that just changed a field description -- AVC's `avc_member` already
  handles this.
- **Theme customisations** -- themes are profile-specific; CSS/template
  overrides need rebuilding.
- **Views and display configurations** -- field names and entity types may
  differ between profiles.
- **Group structures** -- Open Social groups and AVC guilds use different
  entity types and field configurations.
- **Workflow states** -- content moderation workflows may differ.

---

## 6. Phase 4: Multi-Machine Replication

Once the dev environment works, replicate to other machines (met, mini).

### Push Code to GitLab

```bash
cd sites/<name>/dev
git init
git remote add origin git@git.nwpcode.org:<group>/<name>.git
git add -A
git commit -m "Initial <profile>-based <name> project"
git push -u origin main
```

### On the Remote Machine

```bash
# Update NWP if needed
cd ~/nwp && git pull origin main

# Clone the site's dev project
cd ~/nwp/sites/<name>
git clone git@git.nwpcode.org:<group>/<name>.git dev
cd dev

# Copy auth.json with GitLab PAT
cp /path/to/auth.json .

# Start DDEV
ddev start
ddev composer install
```

### Import the Database

```bash
# From the dev workstation
cd ~/nwp/sites/<name>/dev
ddev drush sql:dump --gzip > /tmp/<name>-dev.sql.gz
scp /tmp/<name>-dev.sql.gz rob@<remote>:~/nwp/sites/<name>/dev/

# On the remote machine
cd ~/nwp/sites/<name>/dev
zcat <name>-dev.sql.gz | ddev drush sql:cli
ddev drush cr
```

### Common Issues on Second Machine

| Issue | Fix |
|-------|-----|
| DDEV config YAML broken | Don't use `sed -i` on DDEV config files -- it corrupts commented template sections |
| Git branch divergence | `git fetch origin && git reset --hard origin/main` (after confirming no local work) |
| Different PHP version | Match the PHP version in `.ddev/config.yaml` on both machines |
| Missing auth.json | Copy from dev workstation or generate new GitLab PAT |

---

## 7. Phase 5: Server Configuration

### Server Identity File

Create `servers/<server-name>/.nwp-server.yml`:

```yaml
server:
  name: <server-name>
  ip: <public-ip>
  ssh:
    user: <ssh-user>
    key: ~/.ssh/<key-name>
    port: 22

sites:
  <name>:
    domain: <domain>
    webroot: /var/www/<domain>
    profile: <profile>
    status: active

services:
  - nginx
  - postfix
  - certbot
  - fail2ban
  - ufw

deploy:
  method: bluegreen
  slots:
    blue: /var/www/<domain>-blue
    green: /var/www/<domain>-green
  shared: /var/www/<domain>-shared
  interface: wg-mons
```

### .gitignore

Add exceptions for the server directory in the root `.gitignore`:

```gitignore
# Server infrastructure
!servers/<server-name>/
!servers/<server-name>/**
```

---

## 8. Phase 6: Database Sanitizer

The sanitizer is **security-critical infrastructure**. It runs on prod --
raw user data never leaves the production server. The sanitized output is
what gets imported into dev/stg environments.

### Create a Per-Site Sanitizer

Each site gets its own sanitizer at `lib/sanitizers/<name>.sh`. The
sanitizer must be written against the **actual database schema**, not
assumed table names.

### Getting the Real Schema

SSH to the production server and dump the table list:

```bash
ssh user@prod "cd /var/www/<domain> && ./vendor/bin/drush sql:query 'SHOW TABLES'" > /tmp/tables.txt
```

Cross-reference against your sanitizer to ensure:
- Every table with PII is classified
- No references to tables that don't exist
- Cache/session/transient tables are in the DROP list

**Lesson from mayo:** The first sanitizer draft referenced tables from
vanilla Open Social that don't exist in AVC (`private_message__body`,
`login_security_track`, `search_index`). It also missed profile revision
tables, event enrollment emails, and several activity tracking tables. The
rewrite used `SHOW TABLES` output to verify every table name.

### Classification Model

| Strategy | What It Does | When to Use |
|----------|-------------|-------------|
| DROP | Table dropped entirely | Cache, sessions, semaphore, queue, search indexes, router |
| TRUNCATE | Structure kept, all rows removed | Activity tracking, flag counts, voting, redirects, email queues |
| HASH | Column replaced with SHA256 hash | Passwords |
| FAKER_EMAIL | Column set to `user<id>@example.com` | Email addresses |
| FAKER_NAME | Column set to `User <id>` | Display names |
| FAKER_FIRST/LAST | Column set to `First<id>` / `Last<id>` | Profile name fields |
| REDACT | Column set to `[REDACTED]` | Phone, address, free-text bio fields, messages |
| ZERO | Column set to empty string | Hostnames, IP addresses |
| LEAVE | No change | Config tables, content body, taxonomy, menus |

### PII Columns to Cover (AVC/Open Social Sites)

These are the PII-bearing columns in a typical AVC/Open Social database:

**Core user account:**
- `users_field_data`: name, mail, init, pass

**Profile fields (current + revisions):**
- `profile__field_profile_*`: first_name, last_name, phone_number, address,
  self_introduction, organization, summary, function, expertise, interests
- `profile_revision__field_profile_*`: same fields, archived

**Comments:**
- `comment_field_data`: name, mail, hostname

**Social features:**
- `event_enrollment__field_email`: email addresses
- `post__field_post`: may contain @mentions with real names
- `message__field_message_destination`: message recipients
- `mentions_field_data`: mention text
- `group__field_group_address`: physical locations
- `group_revision__field_group_address`: physical locations (archived)

### PII Sweep

After sanitization, the sanitizer runs a regex sweep on the output file
checking for patterns that should not appear:

- Email addresses (excluding allowlisted domains: `@example.com`,
  `@drupal.org`, `@nwpcode.org`, and site-specific public contacts)
- Australian mobile numbers (`04XX XXX XXX`)
- International numbers (`+61...`)
- 1300/1800 numbers (excluding published safety/reporting numbers)

### Multi-Step with Resume

The sanitizer has steps with `--step N` resume capability:

```
Step 0: Validate environment (site dir, drush, DB connection)
Step 1: Create safety backup
Step 2: Drop transient tables (cache, sessions, queues)
Step 3: Truncate behavioral data (activity, flags, voting)
Step 4: Sanitize PII columns (30+ columns)
Step 5: Export sanitized database
Step 6: PII sweep verification
```

If a step fails, the script prints a `mons-say` command and a paste-ready
block for reporting the error.

### Usage

```bash
# On the production server
sudo -u www-data ./lib/sanitizers/<name>.sh --dry-run      # Preview
sudo -u www-data ./lib/sanitizers/<name>.sh                 # Full run
sudo -u www-data ./lib/sanitizers/<name>.sh --step 4        # Resume from step 4
sudo -u www-data ./lib/sanitizers/<name>.sh --verify         # PII sweep only
```

---

## 9. Phase 7: Build and Publish

### Prerequisites

Install minisign on dev/met:

```bash
sudo apt-get install -y minisign
```

Generate a signing keypair (one-time):

```bash
cd ~/nwp
source lib/minisign.sh
minisign_generate_keys
```

Keys are stored at `keys/minisign/nwp-deploy.{key,pub}`.

**When Solo 2C+ arrives:** Regenerate the keypair on hardware and update
the public key on mons.

### Build

```bash
pl build <name>
```

What happens:
1. `composer install --no-dev --optimize-autoloader` (production dependencies)
2. Creates tarball excluding `.git`, `.ddev`, `.nwp.yml`, `auth.json`,
   `.env`, secrets files, `node_modules`, `files/`, `private/`
3. Signs the tarball with minisign
4. Restores dev dependencies (`composer install`)

Output: `sites/<name>/backups/<name>-<tag>-<timestamp>.tar.gz` and `.minisig`

Options:
- `--tag v1.0` -- version tag (default: git short hash)
- `--output /tmp/` -- output directory
- `--no-sign` -- skip signing (not recommended)
- `--no-composer` -- use existing vendor/ (faster for testing)

### Publish

```bash
pl publish <name>
```

What happens:
1. Verifies the tarball's minisign signature (refuses unsigned artifacts)
2. Extracts GitLab API token from `.secrets.yml`
3. Uploads tarball and signature to GitLab Packages registry

The package is published to:
```
https://git.nwpcode.org/api/v4/projects/<group>%2F<name>/packages/generic/<name>-deploy/<version>/
```

Options:
- `--file <path>` -- specific tarball (default: latest in backups/)
- `--version <ver>` -- package version (default: extracted from filename)
- `--project <path>` -- GitLab project path (default: detected)
- `--dry-run` -- show what would be uploaded

### After Publishing

Tell the mons operator the version string:

```
Deploy ready: <name> <version>
e.g.: Deploy ready: mayo abc123-20260410-120000
```

The version string is the tarball filename minus the site prefix and `.tar.gz`.

---

## 10. Phase 8: Blue-Green Deployment Setup

This is a **one-time setup** on the production server. It converts the site
directory from a simple directory to a slotted layout with atomic swaps.

### Layout After Setup

```
/var/www/<domain>              -> symlink to active slot
/var/www/<domain>-blue/        -> slot A (codebase)
/var/www/<domain>-green/       -> slot B (codebase)
/var/www/<domain>-shared/      -> shared state
  files/                        (user uploads)
  private/                      (private file system)
  settings.local.php            (DB credentials)
```

Both slots have symlinks into the shared directory for `files/`, `private/`,
and `settings.local.php`. Only the codebase differs between slots.

### Running the Setup Script

The setup script is at `servers/<server>/scripts/bluegreen-setup.sh`. Copy
it to the production server and run:

```bash
# From mons (via WireGuard tunnel)
scp servers/<server>/scripts/bluegreen-setup.sh <ssh-host>:/tmp/
ssh <ssh-host> 'sudo /tmp/bluegreen-setup.sh --site <domain> && rm /tmp/bluegreen-setup.sh'
```

The script is **idempotent** -- safe to run multiple times. It:

1. Creates the shared directory and moves existing `files/` and `private/`
2. Copies the current site directory to the blue slot
3. Creates an empty green slot
4. Symlinks shared assets into both slots
5. Converts the site directory from a real directory to a symlink (-> blue)
6. Sets permissions (`www-data` ownership)

### Verify

```bash
ssh <ssh-host> 'ls -la /var/www/<domain>'
# Should show: <domain> -> /var/www/<domain>-blue

ssh <ssh-host> 'curl -sI http://127.0.0.1 -H "Host: <domain>"' | head -5
# Should show: HTTP/1.1 200 OK (or 301/302)
```

---

## 11. Phase 9: WireGuard Tunnel

The WireGuard tunnel provides a dedicated, encrypted link between mons and
the production server. This is **not** part of the Headscale mesh. mons
must never join Headscale.

### Addressing

| Machine | Tunnel IP | Role |
|---------|-----------|------|
| mons | 10.99.0.1 | Deploy machine (initiates connections) |
| prod server | 10.99.0.2 | Production server (listens on 51820) |

### Key Generation

On each machine:

```bash
wg genkey | sudo tee /etc/wireguard/private.key | wg pubkey | sudo tee /etc/wireguard/public.key
sudo chmod 600 /etc/wireguard/private.key
```

Exchange public keys **out-of-band** (USB stick, read aloud, visual
verification). Never transmit private keys.

### Config Files

Configs are stored in the NWP repo at `servers/<server>/wireguard/`:

- `wg-mons.conf.mons` -- mons-side config (Address 10.99.0.1, Endpoint: prod-ip:51820)
- `wg-mons.conf.<server>` -- server-side config (Address 10.99.0.2, ListenPort 51820)

Install to `/etc/wireguard/wg-mons.conf` on each machine after replacing
placeholder keys with real keys.

### Firewall

On the production server, allow WireGuard and SSH on the tunnel:

```bash
sudo ufw allow 51820/udp          # WireGuard
sudo ufw allow in on wg-mons to any port 22  # SSH over tunnel only
```

Eventually, rebind sshd to the tunnel interface only (`ListenAddress
10.99.0.2`) and close public SSH. Do this **after** confirming the tunnel is
reliable, with Lish console access as a fallback.

### Testing

```bash
# On mons
sudo wg-quick up wg-mons
ping -c 3 10.99.0.2
ssh -o ConnectTimeout=5 <ssh-host> hostname
sudo wg-quick down wg-mons
```

---

## 12. Phase 10: First Deploy via mons

### Prerequisites on mons

- [ ] minisign installed (`sudo apt-get install -y minisign`)
- [ ] NWP deploy public key at `~/.config/nwp-deploy.pub`
- [ ] Deploy token at `~/.config/<name>-deploy.token` (chmod 600)
- [ ] SSH config entry for the prod server (pointing to tunnel IP)
- [ ] WireGuard config at `/etc/wireguard/wg-mons.conf`
- [ ] Deploy scripts in `~/deploy-scripts/` (copy from NWP repo)
- [ ] `mons-say` installed (for error reporting back to dev)

### Dry Run First

```bash
# Bring mons online (phone hotspot, NOT home LAN)
sudo wg-quick up wg-mons

# Dry run -- download and verify only, no deployment
~/deploy-scripts/mons-deploy.sh <name> <version> --dry-run
```

### Full Deploy

```bash
# 1. Start tunnel
sudo wg-quick up wg-mons

# 2. Deploy
~/deploy-scripts/mons-deploy.sh <name> <version>

# 3. Verify
ssh <ssh-host> 'curl -sI http://127.0.0.1 -H "Host: <domain>"' | head -5
ssh <ssh-host> 'cd /var/www/<domain> && sudo -u www-data ./vendor/bin/drush status --fields=drupal-version,install-profile'

# 4. Tear down tunnel
sudo wg-quick down wg-mons

# 5. Report
mons-say "deploy <name> <version> complete -- smoke test passed"
```

### What mons-deploy.sh Does

The script has 5 steps with `--step N` resume capability:

| Step | What Happens |
|------|-------------|
| 1 | Pre-flight checks: minisign, token, pubkey, tunnel, SSH |
| 2 | Download tarball and signature from GitLab Packages |
| 3 | Verify minisign signature (refuses to proceed if invalid) |
| 4 | Upload to inactive slot, extract, re-create shared symlinks, drush updb |
| 5 | Swap slots (uploads and runs `bluegreen-swap.sh` on prod) |

If any step fails, the script outputs a formatted error with resume
instructions.

### Rollback

If something goes wrong after the swap:

```bash
ssh <ssh-host> 'sudo /path/to/bluegreen-swap.sh --site <domain> --rollback -y'
```

The previous slot remains intact. Rollback is instant (another atomic swap).

---

## 13. Ongoing Operations

### Regular Deploy Cycle

```bash
# On dev/met
pl build <name>
pl publish <name>

# Tell mons operator the version
# On mons
sudo wg-quick up wg-mons
~/deploy-scripts/mons-deploy.sh <name> <version>
sudo wg-quick down wg-mons
mons-say "deploy <name> <version> complete"
```

### Database Sanitization (for dev/stg fixtures)

```bash
# On prod server
sudo -u www-data ./lib/sanitizers/<name>.sh

# Download the sanitized dump via mons
scp <ssh-host>:/tmp/<name>-sanitized.sql.gz ~/

# Transfer to dev (via USB, mons-say, or another secure channel)
# On dev, import to stg:
cd sites/<name>/stg
zcat <name>-sanitized.sql.gz | ddev drush sql:cli
ddev drush cr
```

### Backup Before Major Changes

Always backup the production database before upgrades:

```bash
ssh <ssh-host> 'cd /var/www/<domain> && sudo -u www-data ./vendor/bin/drush sql:dump --gzip --result-file=/tmp/<name>-pre-upgrade.sql'
```

### Checking Current Production State

```bash
ssh <ssh-host> 'ls -la /var/www/<domain>'                    # Which slot is live?
ssh <ssh-host> 'cat /var/log/nwp/deployments.log | tail -5'  # Recent deployments
ssh <ssh-host> 'cd /var/www/<domain> && sudo -u www-data ./vendor/bin/drush status'
```

---

## 14. Open Social to AVC Migration

This section covers the specific case of migrating from vanilla Open Social
to AVC, based on the mayo integration (April 2026).

### What AVC Adds to Open Social

AVC is built on top of Open Social's module ecosystem. It bundles the Open
Social modules directly (not as a composer dependency) and adds:

- **8 custom modules:** avc_core, avc_member, avc_group, avc_guild,
  avc_asset, avc_content, avc_notification, avc_devel
- **Guilds:** structured groups with admin/facilitator/member roles
- **Workflow assignment:** task tracking within groups
- **Asset management:** project/document/resource management
- **Advanced notifications:** digest preferences and custom channels
- **30+ patches** to core and contrib
- **98+ dependencies** managed by the profile
- **Moodle integration:** OAuth2 SSO with role mapping (optional)

### What Changes

| Feature | Open Social | AVC |
|---------|------------|-----|
| Install profile | `social` | `avc` |
| Groups | Open Social groups | AVC guilds (extended groups) |
| User roles | Social roles | AVC roles (guild_admin, guild_facilitator, guild_member) |
| Content types | Social content types | AVC content types + assets |
| Notifications | Social notifications | AVC notifications (extended) |
| Moodle integration | None | OAuth2 SSO with role mapping |
| Package source | goalgorilla/open_social | nwp/avc (self-hosted GitLab) |

### Migration Path

1. **Don't attempt in-place profile swap.** It doesn't work in Drupal.

2. **Export a content inventory** from the Open Social site:
   ```bash
   ddev drush sql:query "SELECT uid, name, mail, status FROM users_field_data WHERE uid > 0" > inventory-users.csv
   ddev drush sql:query "SELECT nid, type, title, status FROM node_field_data" > inventory-nodes.csv
   ddev drush sql:query "SELECT id, type, label FROM groups_field_data" > inventory-groups.csv
   ```

3. **Fresh AVC install** (see Phase 2, Option B)

4. **Recreate content** using the inventory as reference.

5. **Review custom modules.** Check if the new profile already handles
   the same functionality before copying custom modules across.

### Version Considerations

- AVC bundles Open Social modules directly; it does not depend on the
  `goalgorilla/open_social` composer package.
- Open Social 13 is beta-only (as of April 2026). AVC tracks stable
  ~12.4.x components.
- Updating Open Social components within AVC requires upstream work on
  the `nwp/avc` profile.

---

## 15. Error Reporting and Recovery

### The Problem

Scripts run on mons and prod servers where Claude cannot help directly.
When something fails, the operator needs:
1. To understand what went wrong
2. To report the error back to the dev session
3. To resume from where it failed

### Error Message Format

All deployment scripts use a common error reporting pattern:

```
================================================================
  STEP 4 FAILED
================================================================

  Error: Extract to green slot on mayo1 failed

  To report via mons-say:
    mons-say "mons-deploy step 4 failed: Extract to green slot failed"

  Or paste this to the dev Claude session:
    ---
    The mons-deploy script failed at step 4.
    Site: mayo, Version: abc123-20260410-120000
    Error: Extract to green slot on mayo1 failed
    Log file: ~/deploy-staging/mons-deploy.log
    Resume with: ./mons-deploy.sh mayo abc123-20260410-120000 --step 4
    ---

  Full log: cat ~/deploy-staging/mons-deploy.log
================================================================
```

### Reporting Channels

| Channel | When to Use | How |
|---------|------------|-----|
| **mons-say** | On mons, for async reporting | `mons-say "<message>"` -- creates a GitLab issue in ops/mons-log |
| **Claude paste** | On any machine with dev access | Copy the `---` block into the Claude session |
| **Direct SSH** | On prod server | Check logs: `cat /var/log/nwp/deployments.log` |

### Resume Capability

| Script | Resume Flag | How It Works |
|--------|------------|--------------|
| `mons-deploy.sh` | `--step N` | Skips steps 1 through N-1 |
| sanitizer | `--step N` | Skips steps 0 through N-1 |
| `bluegreen-setup.sh` | (none needed) | Idempotent -- re-run from scratch |
| `bluegreen-swap.sh` | (none needed) | Auto-rollback on failure |
| `pl build` | (none needed) | Idempotent |
| `pl publish` | (none needed) | Idempotent |

### Log Files

| Script | Log Location |
|--------|-------------|
| `mons-deploy.sh` | `~/deploy-staging/mons-deploy.log` (on mons) |
| sanitizer | `/tmp/<name>-sanitizer.log` (on prod) |
| `bluegreen-swap.sh` | `/var/log/nwp/deployments.log` (on prod) |

---

## 16. Troubleshooting

### Build Phase

**"minisign not installed"**
```bash
sudo apt-get install -y minisign
```

**"No minisign keys found"**
```bash
cd ~/nwp
source lib/minisign.sh
minisign_generate_keys
```

**"Composer install failed"**
Check if DDEV is running: `ddev status`. Check `auth.json` has a valid
GitLab PAT. Check `composer.json` allows insecure audit if needed.

### Publish Phase

**"Signature verification failed -- refusing to publish"**
The tarball's signature doesn't match. Rebuild: `pl build <name>`.

**"HTTP 401 on upload"**
GitLab API token expired or wrong. Check `.secrets.yml` for the current
`gitlab.api_token`.

**"HTTP 403 on upload"**
Token doesn't have write access to the project. Check the token's scopes
on GitLab.

### Deploy Phase (mons)

**"WireGuard tunnel wg-mons is not up"**
```bash
sudo wg-quick up wg-mons
```
If it fails, check `/etc/wireguard/wg-mons.conf`.

**"Cannot SSH to server"**
1. Check tunnel: `ping -c 3 10.99.0.2`
2. Check SSH config: `ssh -v -o ConnectTimeout=5 <ssh-host>`
3. Fallback to public IP temporarily if tunnel is down

**"Signature verification FAILED"**
DO NOT deploy. Report to dev: `mons-say "signature verification failed for <version>"`.
The tarball may be corrupted or tampered with.

**"Live symlink points to unexpected target"**
Blue-green setup hasn't been run. Copy and run `bluegreen-setup.sh` on the
production server.

### Post-Deploy

**"Smoke test failed -- rolled back"**
The swap script auto-rolled back. SSH to prod and check the failed slot:
```bash
ssh <ssh-host>
ls -la /var/www/<domain>                  # Shows which slot is live
cd /var/www/<domain>-{blue,green}         # Check the OTHER slot
sudo -u www-data ./vendor/bin/drush watchdog:show --count=20
```

**"HTTP 503 after swap"**
Nginx is running but Drupal isn't responding:
```bash
ssh <ssh-host> 'cd /var/www/<domain> && sudo -u www-data ./vendor/bin/drush status'
ssh <ssh-host> 'sudo nginx -t && sudo systemctl status nginx'
```

---

## 17. Decisions and Rationale

Key decisions made during the mayo integration, applicable to future sites:

| Decision | Rationale |
|----------|-----------|
| **Fresh install, not in-place profile swap** | Drupal doesn't support it. Small content volume makes manual faster. |
| **Software-only minisign keys (interim)** | Solo 2C+ not arrived. Architecture identical; only key storage changes. |
| **Dedicated WireGuard, not Headscale** | mons must never join Headscale. One-to-one tunnel only. |
| **Blue-green with symlinks** | Simpler than rsync-based deploys. Shared directory for state. Atomic swap. Instant rollback. |
| **Sanitizer on prod only** | Raw data never leaves prod. AI machines only see sanitized data. |
| **Schema-verified sanitizer tables** | First draft had wrong tables. Always verify against `SHOW TABLES`. |
| **Per-site sanitizers** | Every site's schema is different. A generic sanitizer misses site-specific PII. |
| **mons-say for error reporting** | Asynchronous, works offline. Creates GitLab issues that dev can process later. |
| **Multi-step with resume** | Long-running scripts on remote machines need resume capability after failures. |
| **No AI on mons** | The mons boundary is inviolable. Deploy machine must be free of AI tooling. |

---

## 18. Script Inventory

### On dev/met (Claude-accessible)

| Script | Command | Purpose |
|--------|---------|---------|
| `scripts/commands/build.sh` | `pl build <site>` | Create signed deployment tarball |
| `scripts/commands/publish.sh` | `pl publish <site>` | Upload tarball + sig to GitLab Packages |
| `lib/minisign.sh` | (sourced) | minisign wrapper library |
| `lib/sanitizers/<site>.sh` | (copied to prod) | Per-site database sanitizer |

### On mons (offline, no AI)

| Script | Location | Purpose |
|--------|----------|---------|
| `mons-deploy.sh` | `~/deploy-scripts/` | End-to-end deploy orchestrator |

### On prod server (run via SSH)

| Script | Location | Purpose |
|--------|----------|---------|
| `bluegreen-setup.sh` | (uploaded from NWP) | One-time blue-green layout creation |
| `bluegreen-swap.sh` | (uploaded from NWP) | Atomic slot swap with rollback |
| sanitizer | (uploaded from NWP) | Database sanitization |

### Source locations in NWP repo

All scripts live in the NWP repo and are copied to their target machines:

- `servers/<server>/scripts/mons-deploy.sh` -> mons `~/deploy-scripts/`
- `servers/<server>/scripts/bluegreen-setup.sh` -> prod `/tmp/` (one-time)
- `servers/<server>/scripts/bluegreen-swap.sh` -> prod `/tmp/` (per-deploy)
- `lib/sanitizers/<site>.sh` -> prod (manual copy)

---

## 19. Complete Checklist

### Pre-Integration

- [ ] Document production site state (profile, version, content volume)
- [ ] Choose target recipe (d, avc, os)
- [ ] Decide content strategy (import, fresh + re-entry, Migrate API)
- [ ] Ensure GitLab repo exists for the site
- [ ] Obtain valid GitLab PAT for composer registry

### Phase 1: Scaffold

- [ ] Create directory structure: `sites/<name>/{dev,stg,backups,scripts}`
- [ ] Create site-level `.nwp.yml`
- [ ] Create `dev/.nwp.yml` and `stg/.nwp.yml`
- [ ] Configure DDEV (`ddev config` + environment variables)

### Phase 2: Codebase

- [ ] Create `composer.json` (based on recipe template)
- [ ] Create `auth.json` with GitLab credentials (if needed)
- [ ] `ddev start && ddev composer install`
- [ ] Configure private file system (if required by profile)
- [ ] `ddev drush site:install <profile>`
- [ ] Verify: `ddev drush status` shows correct profile

### Phase 3: Content

- [ ] Export content inventory from production
- [ ] Recreate or migrate content per chosen strategy
- [ ] Verify content counts match inventory
- [ ] Test user login and permissions
- [ ] `ddev drush config:export -y` to capture baseline config

### Phase 4: Multi-Machine

- [ ] Push code to GitLab
- [ ] Clone and configure on second machine (met)
- [ ] Import database on second machine
- [ ] Verify site works identically

### Phase 5: Server Configuration

- [ ] Create `servers/<server>/.nwp-server.yml`
- [ ] Update `.gitignore` to track server directory
- [ ] Verify SSH access to production server

### Phase 6: Sanitizer

- [ ] Get actual table list from production (`SHOW TABLES`)
- [ ] Write sanitizer with correct table names
- [ ] Classify all tables (DROP, TRUNCATE, LEAVE)
- [ ] Identify all PII columns and assign strategies
- [ ] Define PII sweep patterns and allowlist
- [ ] Test with `--dry-run`
- [ ] Run full sanitization and verify PII sweep passes

### Phase 7: Build and Publish

- [ ] Install minisign on dev/met
- [ ] Generate minisign keypair
- [ ] `pl build <name>` succeeds
- [ ] `pl publish <name>` succeeds
- [ ] Verify tarball is in GitLab Packages registry

### Phase 8: Blue-Green Setup

- [ ] Copy `bluegreen-setup.sh` to production server
- [ ] Run setup script (one-time)
- [ ] Verify symlink layout: `ls -la /var/www/<domain>`
- [ ] Verify site still works after conversion

### Phase 9: WireGuard Tunnel

- [ ] Generate WireGuard keys on mons and prod server
- [ ] Exchange public keys out-of-band
- [ ] Install configs on both machines
- [ ] Test tunnel: `ping 10.99.0.2` from mons
- [ ] Test SSH over tunnel: `ssh <host> hostname`
- [ ] Configure firewall on prod server

### Phase 10: First Deploy

- [ ] Install prerequisites on mons (minisign, pubkey, token, scripts)
- [ ] Dry run: `mons-deploy.sh <name> <version> --dry-run`
- [ ] Full deploy: `mons-deploy.sh <name> <version>`
- [ ] Verify production site works
- [ ] Report success: `mons-say "deploy complete"`

### Ongoing

- [ ] Regular deploy cycle working (build -> publish -> deploy)
- [ ] Sanitized fixtures available for dev/stg
- [ ] Backup procedures documented and tested
- [ ] Rollback procedure tested

---

## Related Documents

- [mayo-avc-integration.md](./mayo-avc-integration.md) -- Complete record of the mayo integration
- [mons-operations.md](./mons-operations.md) -- mons deploy procedures (site-specific)
- [mons-mayo-bootstrap.md](./mons-mayo-bootstrap.md) -- Initial bootstrap (superseded by mons-operations.md)
- [migration-workflow.md](./migration-workflow.md) -- Content migration from other platforms
- [ADR-0017](../decisions/0017-distributed-build-deploy-pipeline.md) -- F21 pipeline architecture
- [F21 proposal](../proposals/F21-distributed-build-deploy-pipeline.md) -- Implementation plan with phase status
