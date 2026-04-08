# F18: Unified Backup Strategy — Secrets, Config, Databases, and Full Rebuild

> **Renumbered 2026-04-08:** Previously **F24**. The old number is still used
> in some external references; treat F24 as an alias for F18.

**Status:** PROPOSED
**Created:** 2026-04-06
**Author:** Rob Zaar, Claude Opus 4.6
**Priority:** High (data safety)
**Depends On:** F17 (Project Separation) — partial; Phases 1-4 of F17 must land first
**Breaking Changes:** No
**Estimated Effort:** 30-42 hours across 6 phases

---

## 1. Executive Summary

### 1.1 Problem Statement

NWP's `~/nwp/` directory is 22GB, but the vast majority is **regeneratable** — Drupal core (~5GB across sites), vendor/ directories (~2.2GB), verify-test sites (~2.5GB), Python venvs, etc. What's *irreplaceable* is scattered and unprotected:

1. **Secrets are gitignored but not backed up.** `.secrets.yml`, `.secrets.data.yml`, `nwp.yml`, SSH keys in `keys/`, `.auth.yml` — all excluded from git with no alternative backup mechanism.

2. **Database dumps are local-only.** `sitebackups/` (2.5GB) has no offsite copy, no encryption, no retention policy, no rotation.

3. **No rebuild recipe exists.** If the development machine dies, there is no documented or automated way to reconstruct the full environment from a backup set.

4. **No backup scheduling.** All backups are manual (`pl backup`). The cron infrastructure is not connected.

5. **Git provides code backup but not the full picture.** Git tracks NWP core and (after F17) each site's code, but everything else — secrets, databases, user uploads, local config — is unprotected.

### 1.2 Proposed Solution

A **layered backup strategy** that minimises footprint while enabling full rebuild:

| Layer | What | Tool | Destination |
|-------|------|------|-------------|
| **Code** | NWP core + per-site repos | Git (already done) | git.nwpcode.org |
| **Secrets** | `.secrets.yml`, `.secrets.data.yml`, `.auth.yml`, `nwp.yml`, `.nwp.yml`, `.nwp-server.yml` | SOPS + age encryption → git | Encrypted in repos |
| **Databases** | Per-site SQL dumps | restic (stdin capture) | Local repo + Linode Object Storage |
| **User files** | Uploaded media, Moodle data | restic (deduplicated) | Local repo + Linode Object Storage |
| **Everything else** | Configs, pipeline data, anything missed | restic (full sweep with excludes) | Local repo + Linode Object Storage |
| **Rebuild** | Automated restore script | `pl rebuild` | N/A |

**Design principles:**
- **Smallest footprint:** Exclude everything regeneratable. Back up only what you can't recreate.
- **Full rebuild from backup:** A single `pl rebuild` command on a fresh machine can restore the entire environment.
- **3-2-1 rule:** 3 copies (local + local repo + cloud), 2 media types, 1 offsite.
- **Encrypted at rest:** Secrets encrypted with SOPS+age before going anywhere. Restic encrypts all backup data.
- **Automated:** Daily cron, retention policies, health checks.

### 1.3 Current Disk Analysis

```
~/nwp/ total:                     22 GB

REGENERATABLE (exclude from backup):
  sites/*/vendor/                  2.2 GB    composer install
  sites/*/html/core/               0.9 GB    composer install
  sites/*/web/core/                3.7 GB    composer install
  sites/verify-test*/              2.5 GB    pl verify creates these
  mt/.venv/, cathnet/.venv/        ~0.3 GB   pip install -r requirements.txt
  sites/*-stg/                     1.8 GB    rebuilt from dev or live
  cathnet/ pipeline data           7.8 GB    can be re-downloaded

IRREPLACEABLE (must back up):
  .secrets.yml                     1.7 KB    API tokens
  .secrets.data.yml                ~3 KB     Production credentials
  nwp.yml                          ~65 KB    All NWP configuration
  keys/                            ~0.5 KB   SSH keys
  .auth.yml                        ~0.5 KB   OAuth2 tokens
  sites/*/.nwp.yml (after F17)     ~5 KB ea  Per-site config
  Database dumps (all sites)       ~1-2 GB   Content, users, settings
  sites/*/files/ (user uploads)    ~0.5 GB   Media, documents
  sites/ss_moodledata/             ~2.5 MB   Course files
  Custom modules/themes            ~10 MB    Code not yet in git
  Pipeline source code             ~5 MB     Python src (not data)

ESTIMATED BACKUP SIZE (after excludes): ~2-3 GB initial
ESTIMATED INCREMENTAL DAILY:            ~50-200 MB
ESTIMATED CLOUD STORAGE COST:           ~$0.02/month (Linode Object Storage)
```

---

## 2. Layer 1: Secrets Backup with SOPS + age

### 2.1 Why SOPS + age

| Option | Verdict | Reason |
|--------|---------|--------|
| **SOPS + age** | **Recommended** | No infrastructure, value-level encryption (diffs readable), multiple recipients, break-glass key support |
| git-crypt | Rejected | Whole-file encryption (useless diffs), GPG dependency |
| HashiCorp Vault | Rejected | Server infrastructure overkill for single developer |
| Manual USB backup | Supplementary | Good as break-glass but not primary |

SOPS (Secrets OPerationS, by Mozilla) encrypts only the **values** in YAML files, leaving keys readable. This means encrypted secrets files can be committed to git and still produce useful diffs:

```yaml
# .secrets.yml.enc (committed to git — safe)
linode:
    api_token: ENC[AES256_GCM,data:abc123...,iv:...,tag:...,type:str]
gitlab:
    password: ENC[AES256_GCM,data:def456...,iv:...,tag:...,type:str]
```

### 2.2 Setup

**One-time setup:**

```bash
# Install age (encryption tool — single binary, no GPG needed)
sudo apt install age    # or: brew install age

# Install sops
# Download from https://github.com/getsops/sops/releases
sudo install sops /usr/local/bin/

# Generate your daily-use age key
age-keygen -o ~/.config/sops/age/keys.txt
# Output: public key: age1abc123...

# Generate a break-glass recovery key (store on paper/USB in a safe)
age-keygen -o /tmp/breakglass.txt
# Copy public key, then move private key to secure offline storage
# Public key: age1def456...
# IMPORTANT: Print /tmp/breakglass.txt on paper, store in safe, then:
shred -u /tmp/breakglass.txt
```

**Create `.sops.yaml` in project root:**

```yaml
# ~/nwp/.sops.yaml
creation_rules:
  # Secrets files — encrypt to both daily key and break-glass key
  - path_regex: \.secrets\.yml\.enc$
    age: >-
      age1abc123...,
      age1def456...
  - path_regex: \.secrets\.data\.yml\.enc$
    age: >-
      age1abc123...,
      age1def456...
  - path_regex: \.auth\.yml\.enc$
    age: >-
      age1abc123...
  # Per-site secrets
  - path_regex: sites/.*/\.secrets\.yml\.enc$
    age: >-
      age1abc123...,
      age1def456...
```

### 2.3 Workflow

**Encrypting secrets (before commit or backup):**

```bash
pl secrets encrypt
# Internally:
#   sops encrypt .secrets.yml > .secrets.yml.enc
#   sops encrypt .secrets.data.yml > .secrets.data.yml.enc
#   sops encrypt .auth.yml > .auth.yml.enc
#   sops encrypt nwp.yml > nwp.yml.enc
#   for site in sites/*/; do
#     [ -f "$site/.secrets.yml" ] && sops encrypt "$site/.secrets.yml" > "$site/.secrets.yml.enc"
#     [ -f "$site/.nwp.yml" ] && sops encrypt "$site/.nwp.yml" > "$site/.nwp.yml.enc"
#   done
# Encrypted files ARE committed to git — they're safe
```

**Decrypting (after clone or restore):**

```bash
pl secrets decrypt
# Internally:
#   sops decrypt .secrets.yml.enc > .secrets.yml
#   sops decrypt .secrets.data.yml.enc > .secrets.data.yml
#   etc.
```

**Editing secrets in-place (SOPS opens $EDITOR with decrypted content, re-encrypts on save):**

```bash
sops .secrets.yml.enc
```

### 2.4 What Gets SOPS-Encrypted

| File | Contains | Notes |
|------|----------|-------|
| `.secrets.yml` | Linode, GitLab, GitHub API tokens | Value-level encryption (diffable) |
| `.secrets.data.yml` | Production DB creds, SMTP | Value-level encryption |
| `nwp.yml` | Global config including sensitive settings | Value-level encryption |
| `.auth.yml` | OAuth2 tokens | Value-level encryption |
| `sites/*/.nwp.yml` | Per-site config with deploy credentials | Value-level encryption |
| `sites/*/.secrets.yml` | Per-site API keys | Value-level encryption |
| `servers/*/.nwp-server.yml` | Server IPs, SSH users, linode_id, service config | Value-level encryption |

**Not covered by this scheme:** SSH private keys (`~/.ssh/`). These are user-level credentials backed up by the operator outside of NWP (encrypted USB, password manager, hardware token, offline paper backup, etc.). NWP's backup strategy covers NWP state only.

### 2.5 Break-Glass Recovery

If the primary age key is lost (machine dies, key file corrupted):

1. Retrieve the break-glass private key from paper/USB in your safe
2. Set `SOPS_AGE_KEY_FILE=/path/to/breakglass.txt`
3. Run `pl secrets decrypt` — all secrets are recoverable
4. Generate a new daily key, re-encrypt all secrets

**The break-glass key should be stored:**
- Printed on paper in a physical safe
- On an encrypted USB drive in a separate location
- **Never** on the same machine or cloud service as the daily key

### 2.6 `.gitignore` Updates

```gitignore
# Plaintext secrets — NEVER commit
**/.secrets.yml
**/.secrets.data.yml
.auth.yml
**/nwp.yml
keys/*
!keys/.gitkeep

# Encrypted secrets — SAFE to commit
!**/.secrets.yml.enc
!**/.secrets.data.yml.enc
!.auth.yml.enc
!nwp.yml.enc
!**/.nwp.yml.enc
!**/.nwp-server.yml.enc
```

---

## 3. Layer 2: Database and File Backup with Restic

### 3.1 Why Restic

| Tool | Verdict | Reason |
|------|---------|--------|
| **Restic** | **Recommended** | Static binary, native S3/B2 support, encryption by default, deduplication, stdin capture |
| Borg + Borgmatic | Strong alternative | Better compression (10-20%), native DB hooks, but SSH-only remotes, Python dependency |
| Rclone | Supplementary | Sync tool, not backup — no deduplication, no snapshots, no retention |
| tar + cron | Rejected | No deduplication, no encryption, no retention, manual everything |

Restic features critical for NWP:
- **Deduplication:** Repeated daily full backups store only the changed blocks. A 2GB backup set with 50MB of daily changes costs ~50MB/day, not 2GB/day.
- **Encryption:** Every repository is encrypted with a password. No separate key management.
- **`--stdin-from-command`:** Pipe database dumps directly into a backup snapshot without intermediate files.
- **Native cloud support:** S3-compatible backends (Linode Object Storage, Backblaze B2) without rclone.
- **Retention policies:** `restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12`

### 3.2 Repository Layout

Two restic repositories for the 3-2-1 rule:

```
LOCAL REPO:   /mnt/backup/nwp-restic/     (external drive or second partition)
CLOUD REPO:   s3:ap-southeast-1.linodeobjects.com/nwp-backup/
```

Both repos have the same content (restic can back up to multiple repos). The cloud repo provides offsite protection.

### 3.3 What Restic Backs Up

```
INCLUDE (everything irreplaceable):
  ~/nwp/.secrets.yml
  ~/nwp/.secrets.data.yml
  ~/nwp/.auth.yml
  ~/nwp/nwp.yml
  ~/nwp/keys/                     (legacy NWP-root SSH keys)
  ~/nwp/.sops.yaml
  ~/nwp/sites/*/.nwp.yml
  ~/nwp/sites/*/.nwp.local.yml
  ~/nwp/sites/*/.secrets.yml
  ~/nwp/sites/*/backups/          (database dumps from pl backup)
  ~/nwp/sites/*/html/sites/default/files/   (user uploads)
  ~/nwp/sites/*/web/sites/default/files/    (user uploads)
  ~/nwp/sites/*/private/          (Drupal private files)
  ~/nwp/sites/ss/faith_formation/ (Flutter app — small, custom code)
  ~/nwp/sites/ss_moodledata/      (Moodle course files)
  ~/nwp/servers/*/.nwp-server.yml
  ~/nwp/servers/*/nginx/
  ~/nwp/servers/*/email/

  Note: Restic captures the PLAINTEXT versions of all of the above and
  encrypts them with restic's own password. The SOPS-encrypted .enc
  files committed to git are a SEPARATE protection layer for the
  "in-repo" copy. Either layer alone is sufficient to recover the data,
  which is exactly the redundancy the 3-2-1 rule requires.

  NOT INCLUDED: ~/.ssh/ — SSH keys are the operator's responsibility
  and backed up via their own mechanism (encrypted USB, password manager,
  hardware token, etc.). NWP backup covers NWP state only.

EXCLUDE (regeneratable):
  sites/*/vendor/
  sites/*/node_modules/
  sites/*/html/core/
  sites/*/web/core/
  sites/verify-test*/
  sites/*-stg/
  sites/tmp/
  sites/latest/
  mt/.venv/
  mt/venv/
  mt/data/
  cathnet/.venv/
  cathnet/data/
  fin/.venv/
  **/__pycache__/
  **/.pytest_cache/
  **/.ddev/.ddev-docker-compose-*
  **/.ddev/.global_commands/
  *.sql.gz                         (handled separately via stdin capture)
```

### 3.4 Database Capture via Stdin

Rather than backing up stale `.sql.gz` files from `sitebackups/`, restic captures fresh database dumps directly:

```bash
# For each DDEV-managed site with a running database:
backup_site_database() {
    local site="$1"
    local site_dir="$NWP_DIR/sites/$site"

    if [[ -f "$site_dir/.ddev/config.yaml" ]] && ddev describe "$site" &>/dev/null; then
        ddev export-db -s "$site" --gzip \
            | restic backup --stdin \
              --stdin-filename "databases/$site-$(date +%Y%m%d).sql.gz" \
              --tag "database" --tag "$site"
    fi
}

# For live sites (direct mysqldump from server):
backup_live_database() {
    local site="$1"
    local server=$(get_site_config "$site" "live.server")
    local ssh_cmd=$(get_ssh_command "$server")
    local db_name=$(get_site_config "$site" "live.database")

    $ssh_cmd "mysqldump --single-transaction $db_name | gzip --rsyncable" \
        | restic backup --stdin \
          --stdin-filename "databases/$site-live-$(date +%Y%m%d).sql.gz" \
          --tag "database" --tag "$site" --tag "live"
}
```

### 3.5 Retention Policy (Grandfather-Father-Son)

```bash
restic forget --prune \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 12 \
    --keep-yearly 2 \
    --keep-tag "manual"    # Never auto-delete manually tagged backups
```

| Tier | Frequency | Retention | Recovery Window |
|------|-----------|-----------|-----------------|
| Daily | Every day at 2am | Keep 7 | Recover anything from last week |
| Weekly | Sunday | Keep 4 | Weekly granularity for last month |
| Monthly | 1st of month | Keep 12 | Monthly granularity for a year |
| Yearly | Jan 1 | Keep 2 | Annual archives |

### 3.6 Restic Configuration

```bash
# ~/nwp/.restic.env (gitignored)
export RESTIC_REPOSITORY="/mnt/backup/nwp-restic"
export RESTIC_PASSWORD_COMMAND="cat ~/.config/restic/nwp-password"

# Cloud repo (for offsite)
export RESTIC_REPOSITORY2="s3:ap-southeast-1.linodeobjects.com/nwp-backup"
export AWS_ACCESS_KEY_ID="..."      # Linode Object Storage key
export AWS_SECRET_ACCESS_KEY="..."  # Linode Object Storage secret
```

---

## 4. Layer 3: The Rebuild Recipe

### 4.1 What Makes a Complete Environment

A full NWP environment requires:

| Component | Source | How to Restore |
|-----------|--------|----------------|
| NWP core tool | git.nwpcode.org:nwp/nwp.git | `git clone` |
| Global config | SOPS-encrypted `nwp.yml.enc` in git | `sops decrypt` |
| Global secrets | SOPS-encrypted `.secrets.yml.enc` in git | `sops decrypt` |
| Data secrets | SOPS-encrypted `.secrets.data.yml.enc` in git | `sops decrypt` |
| SSH keys | SOPS-encrypted in git or restic backup | `sops decrypt` or `restic restore` |
| Auth tokens | Restic backup (or re-authenticate) | `restic restore` or `pl auth login` |
| Per-site code | git.nwpcode.org:nwp/<site>.git | `git clone` into `sites/` |
| Per-site config | SOPS-encrypted `.nwp.yml.enc` in site git | `sops decrypt` |
| Per-site secrets | SOPS-encrypted `.secrets.yml.enc` in site git | `sops decrypt` |
| Drupal core + vendor | composer.json in site repo | `composer install` |
| Database content | Restic snapshot (stdin capture) | `restic restore` + `ddev import-db` |
| User uploads | Restic snapshot (files/) | `restic restore` |
| Moodle data | Restic snapshot (moodledata/) | `restic restore` |
| Server configs | git.nwpcode.org:nwp/nwpcode-server.git | `git clone` into `servers/` |
| Server secrets | SOPS-encrypted in server git | `sops decrypt` |
| DDEV config | Site repo (`.ddev/config.yaml`) | `git clone` (already there) |
| Python venvs | requirements.txt in site repo | `pip install -r requirements.txt` |

### 4.2 `pl rebuild` Command

```bash
pl rebuild [--from-restic] [--site=<name>] [--all]
```

**Full environment rebuild (fresh machine):**

```bash
#!/bin/bash
# scripts/commands/rebuild.sh

rebuild_full() {
    echo "=== NWP Full Environment Rebuild ==="
    echo ""
    echo "Prerequisites:"
    echo "  1. age private key at ~/.config/sops/age/keys.txt"
    echo "  2. Restic password at ~/.config/restic/nwp-password"
    echo "  3. Access to git.nwpcode.org (SSH key)"
    echo ""

    # Phase 1: NWP Core
    echo "--- Phase 1: Restoring NWP core ---"
    # (Already done — you cloned this repo to get rebuild.sh)
    sops decrypt .secrets.yml.enc > .secrets.yml
    sops decrypt .secrets.data.yml.enc > .secrets.data.yml
    sops decrypt nwp.yml.enc > nwp.yml
    [ -f .auth.yml.enc ] && sops decrypt .auth.yml.enc > .auth.yml
    chmod 600 .secrets.yml .secrets.data.yml nwp.yml

    # Restore SSH keys from restic (or SOPS-encrypted in git)
    if [[ -d keys/ ]] && [[ ! -f keys/nwp ]]; then
        restic restore latest --target /tmp/nwp-restore --include "keys/"
        cp /tmp/nwp-restore/keys/* keys/
        chmod 600 keys/*
        rm -rf /tmp/nwp-restore
    fi

    # Phase 2: Sites
    echo "--- Phase 2: Restoring sites ---"
    local sites=(avc mt cathnet dir1 ss fin cccrdf)
    for site in "${sites[@]}"; do
        rebuild_site "$site"
    done

    # Phase 3: Servers
    echo "--- Phase 3: Restoring server configs ---"
    cd "$NWP_DIR/servers"
    git clone git@git.nwpcode.org:nwp/nwpcode-server.git nwpcode
    cd nwpcode
    sops decrypt .nwp-server.yml.enc > .nwp-server.yml

    echo ""
    echo "=== Rebuild complete ==="
    echo "Run 'pl doctor' to verify."
}

rebuild_site() {
    local site="$1"
    local site_dir="$NWP_DIR/sites/$site"

    echo "  Restoring $site..."

    # 1. Clone site repo
    cd "$NWP_DIR/sites"
    git clone "git@git.nwpcode.org:nwp/$site.git" "$site" 2>/dev/null || true

    # 2. Decrypt site config and secrets
    cd "$site_dir"
    [ -f .nwp.yml.enc ] && sops decrypt .nwp.yml.enc > .nwp.yml
    [ -f .secrets.yml.enc ] && sops decrypt .secrets.yml.enc > .secrets.yml
    chmod 600 .nwp.yml .secrets.yml 2>/dev/null

    # 2a. Migrate schema if config came from an older NWP version (F17 §3.7)
    pl site migrate "$site" --quiet || {
        log_error "Schema migration failed for $site — manual intervention required"
        return 1
    }

    # 3. Restore database from restic (latest snapshot tagged with this site)
    local db_snapshot
    db_snapshot=$(restic snapshots --tag "database" --tag "$site" --latest 1 --json \
        | jq -r '.[0].short_id // empty')
    if [[ -n "$db_snapshot" ]]; then
        restic restore "$db_snapshot" --target /tmp/nwp-db-restore
        local db_file=$(find /tmp/nwp-db-restore -name "*.sql.gz" | head -1)
        if [[ -n "$db_file" ]]; then
            mkdir -p backups
            cp "$db_file" "backups/$(basename "$db_file")"
        fi
        rm -rf /tmp/nwp-db-restore
    fi

    # 4. Restore user uploads from restic
    local files_snapshot
    files_snapshot=$(restic snapshots --tag "files" --tag "$site" --latest 1 --json \
        | jq -r '.[0].short_id // empty')
    if [[ -n "$files_snapshot" ]]; then
        restic restore "$files_snapshot" --target "$site_dir/"
    fi

    # 5. Install dependencies
    local site_type=$(yq eval '.project.type' .nwp.yml 2>/dev/null)
    case "$site_type" in
        drupal)
            composer install --no-dev 2>/dev/null || true
            ;;
        moodle)
            # Moodle doesn't use composer the same way
            ;;
        utility)
            if [[ -f pipeline/requirements.txt ]]; then
                python3 -m venv pipeline/.venv
                pipeline/.venv/bin/pip install -r pipeline/requirements.txt
            fi
            ;;
    esac

    # 6. Start DDEV and import database
    if [[ -f .ddev/config.yaml ]]; then
        ddev start
        local latest_db=$(ls -t backups/*.sql.gz 2>/dev/null | head -1)
        if [[ -n "$latest_db" ]]; then
            ddev import-db --file="$latest_db"
            ddev drush cr 2>/dev/null || true
        fi
    fi

    echo "  $site restored."
}
```

### 4.3 Rebuild Verification

After rebuild, `pl doctor` verifies completeness:

```bash
pl doctor --post-rebuild
# Checks:
# ✓ nwp.yml exists and is valid YAML
# ✓ .secrets.yml exists and is readable
# ✓ .secrets.data.yml exists (or not required for dev)
# ✓ SSH keys in keys/ have correct permissions (600)
# ✓ All sites have .nwp.yml
# ✓ All DDEV sites start successfully
# ✓ All databases imported
# ✓ All sites respond to HTTP requests
# ✓ Server configs decrypted and valid
```

---

## 5. Automation: `pl backup` Unified Command

### 5.1 Extended Backup Command

The existing `pl backup` command gets extended with a `--full` mode that runs the complete backup pipeline:

```bash
# Existing (unchanged):
pl backup mt                    # DDEV database + files backup for MT site
pl backup mt 'Before update'   # With message

# New modes:
pl backup --full                # Full restic backup of everything irreplaceable
pl backup --full --offsite      # Same + push to cloud repo
pl backup --secrets             # SOPS-encrypt all secrets (for git commit)
pl backup --database mt         # Database-only restic snapshot for MT
pl backup --database --all      # Database snapshots for all sites
pl backup --live mt             # Pull live database from server + restic snapshot
pl backup --status              # Show backup health: last backup time, repo size, etc.
```

### 5.2 Cron Schedule

```bash
# /etc/cron.d/nwp-backup (installed by pl backup --install-cron)

# Daily full backup at 2am
0 2 * * * rob /home/rob/nwp/pl backup --full --offsite --quiet 2>&1 | logger -t nwp-backup

# Database snapshots every 6 hours for active sites
0 */6 * * * rob /home/rob/nwp/pl backup --database --all --quiet 2>&1 | logger -t nwp-backup-db

# Weekly retention cleanup (Sunday 4am)
0 4 * * 0 rob /home/rob/nwp/pl backup --prune --quiet 2>&1 | logger -t nwp-backup-prune

# Monthly backup verification (1st of month, 5am)
0 5 1 * * rob /home/rob/nwp/pl backup --verify --quiet 2>&1 | logger -t nwp-backup-verify

# Daily SOPS encryption of secrets (3am — after full backup)
0 3 * * * rob /home/rob/nwp/pl backup --secrets --quiet 2>&1 | logger -t nwp-secrets
```

### 5.3 Backup Health Monitoring

```bash
pl backup --status
# Output:
# === NWP Backup Status ===
#
# Local Repository:  /mnt/backup/nwp-restic/
#   Last backup:     2026-04-06 02:00:12 (4 hours ago)
#   Snapshots:       47 (7 daily, 4 weekly, 12 monthly, 2 yearly)
#   Repository size: 3.2 GB (deduplicated)
#   Raw data size:   28.4 GB (before dedup)
#   Dedup ratio:     8.9x
#   Integrity:       ✓ verified 2026-04-01
#
# Cloud Repository:  s3:ap-southeast-1.linodeobjects.com/nwp-backup/
#   Last sync:       2026-04-06 02:15:30 (4 hours ago)
#   Repository size: 3.2 GB
#   Monthly cost:    ~$0.02
#
# Secrets:
#   Last encrypted:  2026-04-06 03:00:05
#   Files encrypted: 12/12
#   Break-glass key: ✓ configured (2 recipients)
#
# Databases:
#   avc:             2026-04-06 06:00 (142 MB)
#   mt:              2026-04-06 06:00 (51 MB)
#   cathnet:         2026-04-06 06:00 (38 MB)
#   dir1:            2026-04-06 06:00 (22 MB)
#
# ⚠ Warning: ss (Moodle) database not backed up (no DDEV config)
# ⚠ Warning: Backup verification overdue (last: 32 days ago, threshold: 30)
```

---

## 6. Backup Verification and Restore Testing

### 6.1 Automated Verification

```bash
pl backup --verify
```

Runs monthly (cron) or on demand:

1. **Repository integrity:** `restic check --read-data` — verifies all data blobs are readable
2. **Sample restore:** Restore latest snapshot to `/tmp/nwp-verify-restore/`, verify file counts
3. **Database test:** Import a sample database dump into a test database, run `SELECT COUNT(*) FROM users`
4. **Secrets test:** Decrypt one `.enc` file, verify it produces valid YAML
5. **Manifest comparison:** Compare restored file list against expected manifest
6. **Cleanup:** Remove temporary restore directory

### 6.2 Quarterly Full-Stack Test

Documented procedure (not automated — requires human judgment):

1. Spin up a fresh VM or container
2. Clone NWP from git
3. Run `pl rebuild --from-restic`
4. Verify all sites load in browser
5. Verify databases have correct content
6. Tear down
7. Log results in `docs/backup-verification-log.md`

### 6.3 Alerting

If the daily backup cron fails:
- `logger -t nwp-backup` writes to syslog
- `pl backup --status` shows stale backup warning
- Optional: email alert via `pl email send` if backup is >48 hours old

---

## 7. Implementation Plan

### Phase 1: SOPS + age Setup (4-6 hours)

1. Install `age` and `sops` on development machine
2. Generate daily-use and break-glass age keys
3. Create `.sops.yaml` configuration
4. Encrypt all existing secrets files (`.secrets.yml`, `.secrets.data.yml`, `nwp.yml`, `.auth.yml`, `keys/`)
5. Update `.gitignore` to allow `.enc` files
6. Commit encrypted files to git
7. Implement `pl secrets encrypt` and `pl secrets decrypt` commands
8. Store break-glass key offline (paper + USB)
9. Test: delete plaintext, decrypt from `.enc`, verify contents match

### Phase 2: Restic Repository Setup (4-6 hours)

1. Install restic on development machine
2. Create local restic repository (`restic init`)
3. Create Linode Object Storage bucket for offsite repo
4. Create cloud restic repository (`restic -r s3:... init`)
5. Create exclude file (`~/nwp/.restic-excludes`)
6. Create `.restic.env` with repo paths and credentials
7. Test: manual `restic backup` of `~/nwp/` with excludes
8. Verify: `restic snapshots`, `restic stats`

### Phase 3: Database Stdin Capture (6-8 hours)

1. Implement `backup_site_database()` function with restic stdin capture
2. Implement `backup_live_database()` for pulling from live server
3. Add `--database` mode to `pl backup`
4. Tag snapshots with site name and `database` tag
5. Test: capture database, restore from snapshot, import into DDEV, verify
6. Handle edge cases: DDEV not running, site has no database, Moodle sites

### Phase 4: Full Backup Pipeline (6-8 hours)

1. Implement `--full` mode in `pl backup`
2. Create exclude list covering all regeneratable content
3. Implement `--offsite` flag (backup to cloud repo)
4. Implement `--prune` flag with GFS retention
5. Implement `--status` reporting
6. Test: full backup, verify sizes match expectations, test restore

### Phase 5: Rebuild Command (6-8 hours)

1. Implement `pl rebuild` command
2. Implement `rebuild_site()` for each site type (Drupal, Moodle, utility)
3. Add `--post-rebuild` checks to `pl doctor`
4. Create rebuild manifest (expected files/sites for verification)
5. Test: simulate rebuild on fresh directory, verify all sites work
6. Document the rebuild procedure

### Phase 6: Automation and Monitoring (4-6 hours)

1. Implement `--install-cron` flag for `pl backup`
2. Create cron entries (daily full, 6-hourly DB, weekly prune, monthly verify)
3. Implement `--verify` mode (restic check + sample restore)
4. Implement stale backup warnings in `pl backup --status`
5. Add backup status to `pl doctor` output
6. Update CLAUDE.md with backup-related instructions

---

## 8. Exclude List — Complete Reference

```
# ~/nwp/.restic-excludes
# Everything here is REGENERATABLE — excluded from restic backup

# Drupal/PHP dependencies (composer install)
sites/*/vendor/
sites/*/html/core/
sites/*/web/core/
sites/*/html/vendor/
sites/*/web/vendor/

# Node.js dependencies (npm install)
sites/*/node_modules/

# Python virtual environments (pip install -r requirements.txt)
**/.venv/
**/venv/

# Python caches
**/__pycache__/
**/.pytest_cache/
**/.mypy_cache/

# Staging sites (rebuilt from dev or live)
sites/*-stg/

# Verify test sites (ephemeral, created by pl verify)
sites/verify-test*/

# Temporary/scratch directories
sites/tmp/
sites/latest/

# DDEV generated files (ddev start regenerates)
**/.ddev/.ddev-docker-compose-*
**/.ddev/.global_commands/
**/.ddev/.homeadditions/
**/.ddev/db_snapshots/
**/.ddev/.sso-port

# Pipeline data (can be re-downloaded/regenerated)
mt/data/
cathnet/data/
fin/data/

# Logs and temporary output
**/*.log
mt/mass-times.conf
scripts/commands/podcast-setup-*/

# Build artifacts
**/build/
**/dist/

# Large Drupal caches
sites/*/html/sites/default/files/css/
sites/*/html/sites/default/files/js/
sites/*/web/sites/default/files/css/
sites/*/web/sites/default/files/js/
sites/*/html/sites/default/files/php/
sites/*/web/sites/default/files/php/
```

---

## 9. Security Considerations

### 9.1 Encryption at Rest

| Data | At Rest Encryption | Key Management |
|------|-------------------|----------------|
| Secrets in git | SOPS + age (AES-256-GCM) | age keys (daily + break-glass) |
| Restic snapshots | Restic built-in (AES-256-CTR + Poly1305) | Restic password |
| Cloud storage | Restic encryption + provider TLS | Same restic password |
| SSH keys in `~/.ssh/` | Out of scope — operator's own backup mechanism | Operator-managed |

### 9.2 Key Hierarchy

```
Break-glass age key (paper/USB in safe — last resort)
  └── Can decrypt ALL SOPS-encrypted files
  
Daily-use age key (~/.config/sops/age/keys.txt)
  └── Can decrypt ALL SOPS-encrypted files
  └── Used for day-to-day pl secrets encrypt/decrypt

Restic password (~/.config/restic/nwp-password)
  └── Decrypts all restic snapshots (local and cloud)
  └── Independent of age keys — different threat model

SSH keys (~/.ssh/)
  └── User-level credentials, out of scope for NWP backup
  └── Backed up by the operator (encrypted USB, password manager, hardware token, etc.)
```

### 9.3 Threat Model

| Threat | Protection |
|--------|-----------|
| Development machine stolen | Restic repos encrypted; secrets SOPS-encrypted in git; plaintext secrets only in RAM during use |
| Cloud storage compromised | Restic encrypts client-side before upload |
| Git repo leaked | Secrets are `.enc` files — useless without age key |
| Age daily key lost | Break-glass key recovers everything |
| Both age keys lost | Restic backup still has plaintext secrets (encrypted by restic's own password) |
| Restic password lost | SOPS-encrypted secrets in git still recoverable with age key |
| Break-glass key compromised | Rotate: generate new break-glass key, re-encrypt all secrets |
| All local copies destroyed | Cloud restic repo + git.nwpcode.org have everything needed for full rebuild |

### 9.4 What NOT to Back Up

- **Production database dumps with PII** should be sanitized before backup (`pl backup --sanitize`)
- **Active session tokens** (`.auth.yml`) — can be re-obtained via `pl auth login`
- **DDEV Docker images/volumes** — `ddev start` pulls them fresh

---

## 10. Cost Estimate

| Component | One-Time | Monthly |
|-----------|----------|---------|
| Linode Object Storage (5GB) | $0 | $5.00 (minimum bucket) |
| Backblaze B2 (5GB, alternative) | $0 | $0.03 |
| External USB drive (1TB) | $50 | $0 |
| Development time | 30-42 hours | — |

**Note:** Linode Object Storage has a $5/month minimum. If you're already using Linode, this may be included. Backblaze B2 has no minimum and charges $0.005/GB/month — a 5GB backup costs $0.025/month.

---

## 11. Success Criteria

- [ ] All secrets files have SOPS-encrypted `.enc` counterparts committed to git
- [ ] Break-glass age key exists offline (paper or USB) and can decrypt all secrets
- [ ] `pl secrets encrypt` and `pl secrets decrypt` work correctly
- [ ] Restic local repository initialized and contains at least one full snapshot
- [ ] Restic cloud repository initialized and synced
- [ ] Database snapshots captured via stdin for all active sites
- [ ] `pl backup --full` completes in under 15 minutes
- [ ] `pl backup --status` reports healthy state
- [ ] `pl backup --verify` passes (repository integrity + sample restore)
- [ ] `pl rebuild` successfully restores a site from scratch on a clean directory
- [ ] Backup cron runs daily without errors for 7 consecutive days
- [ ] Retention policy prunes old snapshots correctly
- [ ] `pl doctor` includes backup health in its checks
- [ ] Total backup footprint is under 5GB (initial, after excludes and dedup)
- [ ] Everything within `~/nwp/` — no external backup configs

---

## 12. Timeline

| Phase | Description | Effort | Dependencies |
|-------|-------------|--------|-------------|
| 1 | SOPS + age setup | 4-6h | None |
| 2 | Restic repository setup | 4-6h | None |
| 3 | Database stdin capture | 6-8h | Phase 2 |
| 4 | Full backup pipeline | 6-8h | Phases 1-3 |
| 5 | Rebuild command | 6-8h | Phase 4 |
| 6 | Automation and monitoring | 4-6h | Phase 5 |
| **Total** | | **30-42h** | |

Phases 1 and 2 can run in parallel. Phase 3 depends on 2. Phase 4 depends on 1-3. Phases 5-6 are sequential.

---

## 13. Relationship to F17 (Project Separation)

F18 is designed to work with both the current layout and the F17 target layout:

| F17 Phase | F18 Impact |
|-----------|-----------|
| Before F17 | Restic backs up `sitebackups/`, `modules/`, `mt/`, etc. from current locations |
| After F17 Phase 1 (schema framework) | `pl rebuild` calls `pl site migrate` to upgrade old-version configs from backups (F17 §3.7) |
| After F17 Phase 4 (backups moved into sites) | Restic backs up `sites/*/backups/` instead |
| After F17 Phase 7 (per-site git) | SOPS-encrypted configs committed to each site's git repo |
| After F17 Phase 8 (servers/) | Server configs SOPS-encrypted in `servers/*/` git repos |

**Recommendation:** Start F18 Phase 1-2 now (SOPS + restic setup). These work regardless of F17 progress. Phases 3-6 can adapt to whichever layout exists at implementation time.

---

## 14. Worth-It Evaluation

### Benefits

| Benefit | Impact |
|---------|--------|
| Secrets safely versioned in git | No more "secrets only on one machine" risk |
| Full rebuild from scratch | Machine dies → new machine → `pl rebuild` → back to work |
| Automated daily backups | No human remembering to run `pl backup` |
| 3-2-1 compliance | Local + local repo + cloud = protected against any single failure |
| Minimal footprint | ~3GB instead of 22GB — only irreplaceable data |
| Encrypted everywhere | Stolen laptop / leaked git / compromised cloud = no exposure |
| Verified restores | Monthly automated check that backups actually work |
| Break-glass recovery | Lost your key? Paper backup in safe recovers everything |

### Costs

| Cost | Impact |
|------|--------|
| 30-42 hours of development | Moderate effort, phased delivery |
| $5/month cloud storage (Linode) or $0.03/month (B2) | Negligible |
| Learning SOPS + age + restic | ~2 hours for all three (simple tools) |
| Break-glass key custody | Must physically store paper/USB |
| Daily cron maintenance | Minimal — alerts if something fails |

### Verdict

**Strongly recommended.** The current state (secrets unprotected, no offsite backup, no rebuild capability) is a significant operational risk. A single disk failure would require days of manual reconstruction. This proposal eliminates that risk with minimal ongoing cost and a 3-5GB storage footprint.
