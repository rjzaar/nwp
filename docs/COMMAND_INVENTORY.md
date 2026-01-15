# NWP Command Inventory

Complete inventory of all 49 commands in the NWP codebase.

**Last Updated:** 2026-01-14
**Total Commands:** 49

---

## Core Lifecycle Commands

### install.sh
**Purpose:** Install sites from recipes (Drupal/OpenSocial, Moodle, GitLab, Podcast)
**Key Features:**
- Multi-type installation (drupal, opensocial, moodle, gitlab, podcast)
- Recipe-based configuration from cnwp.yml
- Auto-increment directory naming (nwp, nwp2, nwp3, etc.)
- Resume from specific step (s=N, --step=N, --resume)
- Test content generation (c, --create-content)
- Purpose flags (testing, indefinite, permanent, migration)
- Interactive option selection with checkboxes
- GitLab Composer registry integration
- DNS registration (Linode)

**Recipes:** os (OpenSocial), d (Drupal), nwp (Networked Workforce Platform), dm (Drupal Minimal)

**Verification Points:**
- Drupal recipes (os, d, nwp, dm)
- Moodle recipe
- GitLab recipe
- Podcast (Castopod) recipe
- Resume functionality
- Migration stub creation

---

### setup.sh
**Purpose:** Interactive TUI for managing NWP prerequisites installation
**Key Features:**
- Interactive TUI with arrow key navigation
- Multi-page component organization (Core & Tools, Infrastructure)
- Dependency enforcement
- Editable fields (CLI command name, Linode token)
- Component categories: core, tools, testing, security, linode, gitlab
- Priority levels: required, recommended, optional
- Auto-install mode (--auto)
- Status-only mode (--status)

**Components Managed:**
- Core: Docker, Docker Compose, PHP, Composer, DDEV, mkcert, yq
- Tools: NWP config, CLI command, secrets, script symlinks
- Testing: BATS framework
- Security: Claude Code security config
- Linode: Linode CLI, SSH keys
- GitLab: GitLab server, DNS, SSH config, Composer registry

---

### delete.sh
**Purpose:** Gracefully delete DDEV sites
**Key Features:**
- Multi-type site support (Drupal, Moodle, any DDEV site)
- Optional pre-deletion backup (-b, --backup)
- Keep/remove backup options (-k, --keep-backups)
- Auto-confirm mode (-y, --yes)
- cnwp.yml cleanup (configurable via delete_site_yml setting)
- Purpose-based protection (permanent sites require manual override)
- Force mode for cleanup (--force)
- Keep YAML entry option (--keep-yml)

**Safety Features:**
- Confirmation prompts for permanent sites
- Backup preservation by default with -y flag
- Purpose validation (testing, indefinite, permanent, migration)

---

### uninstall_nwp.sh
**Purpose:** Reverse all changes made by setup.sh
**Key Features:**
- State file detection (original_state.json or legacy pre_setup_state.json)
- Component-aware removal (skip pre-existing installations)
- Shell configuration restoration
- CLI command removal
- Optional config file cleanup
- Installation log preservation
- Legacy state file support

**Components Removed:**
- Docker (if installed by NWP)
- DDEV (if installed by NWP)
- mkcert (if installed by NWP)
- Linode CLI (if installed by NWP)
- Docker group membership
- SSH keys
- NWP CLI command
- Configuration files

---

## Site Management Commands

### status.sh
**Purpose:** Comprehensive status display and site management
**Key Features:**
- Interactive TUI mode (default)
- Text status modes (-s, -r, -v, -a)
- Health checks across all sites
- Detailed site info (info <site>)
- DDEV operations (start, stop, restart)
- Ghost/orphaned site detection
- Recipe listing
- Installation progress tracking
- Linode server status

**Display Modes:**
- Interactive: Arrow key navigation, checkbox operations
- Recipes: Show only recipes (-r, --recipes)
- Sites: Show only sites (-s, --sites)
- Verbose: Detailed information (-v, --verbose)
- All: Everything including health/disk/db (-a, --all)

---

### doctor.sh
**Purpose:** Diagnostic and troubleshooting
**Key Features:**
- System prerequisites check (Docker, DDEV, PHP, Composer, yq, git)
- Configuration file validation (cnwp.yml, .secrets.yml)
- Network connectivity tests (Linode API, Cloudflare API, drupal.org)
- Common issue detection (Docker daemon, DDEV sites, disk space, memory)
- Verbose and quiet modes
- Exit code reporting (0=pass, 1=issues found)

**Checks Performed:**
- Docker daemon running
- DDEV installation and version
- PHP/Composer availability
- yq YAML processor
- Config file syntax
- API connectivity
- Disk space warnings
- Memory availability

---

### verify.sh
**Purpose:** Feature verification tracking
**Key Features:**
- Interactive TUI console (default)
- Verification status tracking
- Automatic invalidation on code changes
- SHA256 hash-based change detection
- Multiple command modes:
  - report: Show verification status
  - check: Find invalidated verifications
  - details <id>: Show what changed
  - verify [id]: Mark as verified
  - unverify <id>: Mark as unverified
  - list: List all feature IDs
  - summary: Statistics
  - reset: Clear all verifications

**State Management:**
- YAML-based verification file (.verification.yml)
- File hash tracking for change detection
- Verification checklists per feature

---

### modify.sh
**Purpose:** Interactive TUI for modifying existing site options
**Key Features:**
- Site selection (interactive or by name)
- Option modification via checkboxes
- cnwp.yml updates
- List all sites (-l)
- Uses yaml-write.sh library
- Uses checkbox.sh library

---

## Backup & Restore Commands

### backup.sh
**Purpose:** Backup DDEV sites (database + files or database only)
**Key Features:**
- Full backup (database + files)
- Database-only backup (-b, --db-only)
- Git supplementary backup (-g, --git)
- Git bundle creation (--bundle, --incremental)
- Push to all remotes (--push-all)
- Database sanitization (--sanitize, --sanitize-level)
- Custom endpoint (-e, --endpoint)
- Pleasy-style naming: YYYYMMDDTHHmmss-branch-commit-message.{sql,tar.gz}

**Output Location:** sitebackups/<sitename>/

**Sanitization Levels:**
- basic: Remove PII (personally identifiable information)
- full: Comprehensive sanitization

---

### restore.sh
**Purpose:** Restore DDEV sites from backups
**Key Features:**
- Full restore (database + files)
- Database-only restore (-b, --db-only)
- Resume from step (-s, --step=N)
- Auto-select latest backup (-f, --first)
- Auto-confirm prompts (-y, --yes)
- Generate login link (-o, --open)
- Restore to different site name
- Step-by-step restoration process

**Restoration Steps:**
1. Select backup
2. Validate target site
3. Stop DDEV
4. Backup current site (optional)
5. Restore database
6. Restore files
7. Clear cache
8. Verify restoration

---

### rollback.sh
**Purpose:** Manage deployment rollback points and recovery
**Key Features:**
- Rollback point creation
- Deployment state snapshots
- Recovery from failed deployments
- Multiple rollback strategies

---

### schedule.sh
**Purpose:** Manage cron-based backup scheduling
**Key Features:**
- Cron job creation for automated backups
- Schedule management per site
- Configurable backup frequency
- Email notifications on backup completion/failure

---

## Deployment Commands

### dev2stg.sh
**Purpose:** Deploy from development to staging
**Key Features:**
- Intelligent state detection
- Auto-create staging if missing
- Multi-source database routing
- Multi-tier testing (8 types, 5 presets)
- Interactive TUI or automated mode (-y)
- Doctor/preflight checks
- Configuration sync
- Database updates
- Cache clearing

**Test Types:**
1. Unit tests
2. Integration tests
3. Behat/functional tests
4. PHPUnit tests
5. PHPStan static analysis
6. PHPCS code standards
7. Security checks
8. Performance tests

**Presets:**
- quick: Essential checks only
- standard: Common test suite
- full: All available tests
- ci: CI/CD optimized
- security: Security-focused

---

### stg2live.sh
**Purpose:** Deploy staging to live test server
**Key Features:**
- File synchronization via rsync
- Database deployment
- Security module installation
- Permission management
- Cache clearing
- Live server provisioning integration

---

### stg2prod.sh
**Purpose:** Deploy staging to Linode production server
**Key Features:**
- SSH/rsync file transfer
- Remote drush commands
- Database sync options
- Configuration deployment
- Rollback point creation
- Production safety checks
- Cache warming

---

### live.sh
**Purpose:** Provision live test servers
**Key Features:**
- Automatic provisioning at sitename.nwpcode.org
- Linode VPS creation
- DNS configuration (Cloudflare/Linode)
- SSL certificate installation
- DDEV-to-live deployment
- Server status monitoring

---

### produce.sh
**Purpose:** Provision production servers
**Key Features:**
- Custom domain configuration
- SSL certificate management
- Backup configuration
- Production-grade security
- Performance optimization
- Monitoring setup

---

### prod2stg.sh
**Purpose:** Pull code and database from production to staging
**Key Features:**
- SSH/rsync file synchronization
- Remote/local drush integration
- Database sanitization options
- Configuration preservation
- Selective sync (files-only, db-only)

---

### live2prod.sh
**Purpose:** Deploy from live test server directly to production
**Key Features:**
- Direct server-to-server deployment
- Bypasses local development
- Configuration validation
- Rollback support

---

### live2stg.sh
**Purpose:** Pull from live server to local staging
**Key Features:**
- Live-to-local synchronization
- Database and file sync
- Development environment preparation

---

## Content Sync Commands

### sync.sh
**Purpose:** Re-sync imported site with remote source
**Key Features:**
- Database sync from remote
- File sync from remote
- Database sanitization (--no-sanitize to skip)
- Pre-sync backup option (--backup)
- Auto-confirm mode (-y, --yes)
- Selective sync (--db-only, --files-only)

---

### import.sh
**Purpose:** Import live Drupal sites from remote Linode servers
**Key Features:**
- Interactive server selection from cnwp.yml
- Custom SSH connection support
- Source path specification
- Database and file import
- DDEV configuration
- Database sanitization
- Auto-configure from remote settings

**Modes:**
- Interactive: Select server from cnwp.yml
- Direct: Specify server (--server=name)
- SSH: Custom connection (--ssh=root@example.com)

---

### copy.sh
**Purpose:** Copy one DDEV site to another
**Key Features:**
- Full copy (files + database)
- Files-only copy option
- DDEV reconfiguration
- Database rename
- Selective content copying

---

## Testing Commands

### test.sh
**Purpose:** Run tests for DDEV sites
**Key Features:**
- PHPCS (code standards)
- PHPStan (static analysis)
- PHPUnit (unit tests)
- Behat (behavior tests)
- Test type selection
- Parallel test execution
- Test report generation

---

### testos.sh
**Purpose:** Comprehensive OpenSocial distribution testing
**Key Features:**
- Behat functional tests
- PHPUnit unit tests
- PHPStan static analysis
- Code quality tests
- OpenSocial-specific validation
- Test suite selection
- CI/CD integration

---

### test-nwp.sh
**Purpose:** Comprehensive NWP functionality testing
**Key Features:**
- 22+ test categories
- Core operations (install, backup, restore, copy, delete, deploy)
- Script validation
- Deployment scripts
- YAML library functions
- Linode production testing
- Input validation & error handling
- Git backup features (P11-P13)
- Scheduling features (P14)
- CI/CD & testing templates (P16-P21)
- Unified CLI wrapper (P22)

**Test Categories:**
1. Install validation
2. Backup functionality
3. Restore operations
4. Copy operations
5. Delete operations
6. Deployment workflows
7. Configuration management
8. Error handling
9. Script validation
10. Deployment scripts
11. YAML library
12. Linode integration
13. Input validation
14. Git backup (P11-P13)
15. Scheduling (P14)
16. CI/CD templates (P16-P21)
17. CLI wrapper (P22)

---

### run-tests.sh
**Purpose:** Run all levels of tests (unit, integration, E2E)
**Key Features:**
- BATS unit tests
- BATS integration tests
- End-to-end tests
- Test suite orchestration
- Report aggregation

---

## Utility Commands

### make.sh
**Purpose:** Toggle between development and production modes
**Key Features:**
- Development mode (dev)
- Production mode (prod)
- Drupal settings.php configuration
- Cache configuration
- Error reporting levels
- Performance optimization
- Security hardening

---

### theme.sh
**Purpose:** Unified frontend build tool management
**Key Features:**
- Build tool auto-detection (Gulp, Grunt, Webpack, Vite)
- Theme compilation
- Asset watching
- Production builds
- Development server integration

**Subcommands:**
- build: Compile theme assets
- watch: Watch for changes
- clean: Clean build artifacts
- install: Install dependencies

---

### security.sh
**Purpose:** Check for and apply security updates
**Key Features:**
- Security update detection
- Update application
- Vulnerability scanning
- Security report generation

**Commands:**
- check: Scan for vulnerabilities
- update: Apply security patches
- report: Generate security report

---

### security-check.sh
**Purpose:** Test HTTP security headers
**Key Features:**
- Security header validation
- Mozilla Observatory-style checks
- HTTPS configuration
- Header recommendations
- Security scoring

**Headers Checked:**
- Content-Security-Policy
- X-Frame-Options
- X-Content-Type-Options
- Strict-Transport-Security
- Referrer-Policy
- Permissions-Policy

---

### seo-check.sh
**Purpose:** Comprehensive SEO monitoring
**Key Features:**
- robots.txt validation
- Sitemap verification
- HTTP header checks
- Staging protection verification
- Production optimization checks

**Commands:**
- check: Full SEO check
- staging: Verify staging protection
- production: Verify production optimization
- sitemap: Check sitemap.xml
- headers: Check HTTP headers

---

### badges.sh
**Purpose:** Manage GitLab CI/CD badges
**Key Features:**
- Badge creation for project READMEs
- Coverage badges
- Build status badges
- Pipeline badges
- Custom badge configuration

---

### email.sh
**Purpose:** Unified email setup, testing, and configuration
**Key Features:**
- Email configuration wizard
- SMTP testing
- Email send testing
- Configuration validation

---

### storage.sh
**Purpose:** Manage Backblaze B2 cloud storage
**Key Features:**
- Bucket management
- Backup upload
- Media storage for podcasts
- Access key management

---

### report.sh
**Purpose:** Run commands and report errors to GitLab
**Key Features:**
- Wrapper mode: Run command and offer to report on failure
- Direct report mode: Report without running command
- Output capture
- Pre-filled GitLab issue URLs
- Log attachment support
- Copy URL instead of opening browser (-c)

**Usage Modes:**
- Wrapper: ./report.sh backup.sh mysite
- Direct: ./report.sh --report "Error message"
- With logs: ./report.sh --report -a logfile

---

## Migration Commands

### migration.sh
**Purpose:** Handle site migrations from various sources to Drupal 11
**Key Features:**
- Multi-source support (Drupal 7/8/9, HTML, WordPress, Joomla, custom)
- Migration workflow: analyze → prepare → run → verify
- Content analysis
- Target site preparation
- Migration execution
- Verification tools

**Commands:**
- analyze: Analyze source site
- prepare: Set up target Drupal
- run: Execute migration
- verify: Verify success
- status: Show migration status

**Source Types:**
- drupal7: Drupal 7 (uses Migrate API)
- drupal8/9: Drupal 8/9 (upgrade path)
- html: Static HTML (migrate_source_html)
- wordpress: WordPress (migrate_wordpress)
- joomla: Joomla
- other: Custom migration

---

### migrate-secrets.sh
**Purpose:** Migrate to two-tier secrets architecture
**Key Features:**
- Infrastructure/data split migration
- Dry-run mode
- NWP root migration (--nwp)
- Site-specific migration (--site NAME)
- Bulk migration (--all)

**Two-Tier Architecture:**
- .secrets.yml: Infrastructure secrets (Linode, Cloudflare, GitLab)
- .secrets.data.yml: Data secrets (DB passwords, SSH keys, SMTP)

---

## Distributed Contribution Commands

### contribute.sh
**Purpose:** Submit contributions via merge request
**Key Features:**
- Auto-detect feature branch
- Auto-generate MR title from commits
- Draft MR support (--draft)
- Pre-submission testing
- Skip tests option (--no-tests)

**Workflow:**
1. Validate working tree
2. Run tests (unless --no-tests)
3. Push branch to remote
4. Create GitLab merge request
5. Display MR URL

---

### upstream.sh
**Purpose:** Sync local repository with upstream
**Key Features:**
- Upstream sync
- Status reporting
- Upstream configuration
- Configuration display

**Commands:**
- sync: Sync with upstream
- status: Show sync status
- configure: Configure upstream
- info: Show configuration

---

## Coder Management Commands

### coders.sh
**Purpose:** Interactive coder management TUI
**Key Features:**
- Auto-listing of all coders
- Onboarding status columns (GitLab, SSH, DNS, Server, Site)
- Arrow key navigation
- Bulk actions (delete, promote)
- Auto-sync from GitLab
- Detailed stats view
- Non-interactive list mode

---

### coder-setup.sh
**Purpose:** NS delegation for additional coders
**Key Features:**
- NS delegation for subdomains (coder.nwpcode.org)
- DNS autonomy via Linode
- Add/remove coder operations
- Note management

**Coder Gets:**
- NS delegation: <coder>.nwpcode.org → Linode nameservers
- Full DNS autonomy
- Ability to create: git.<coder>.nwpcode.org, nwp.<coder>.nwpcode.org

**Commands:**
- add <coder_name> [--notes "description"]
- remove <coder_name>

---

### bootstrap-coder.sh
**Purpose:** Automatically configure new coder's NWP installation
**Key Features:**
- Coder identity detection and validation
- cnwp.yml configuration from example
- Git user configuration
- SSH key setup for GitLab
- DNS and infrastructure verification
- Interactive and automated modes

**Modes:**
- Interactive: Guided setup
- Direct: ./bootstrap-coder.sh --coder john

---

### setup-ssh.sh
**Purpose:** Generate project-specific SSH keys
**Key Features:**
- keys/ directory creation (gitignored)
- nwp/nwp.pub keypair generation
- Install private key to ~/.ssh/nwp
- Public key display for Linode account
- Linode server listing from cnwp.yml

---

## AVC-Moodle Integration Commands

### avc-moodle-setup.sh
**Purpose:** Configure SSO integration between AVC and Moodle
**Key Features:**
- OAuth2-based authentication
- Role synchronization
- Badge display integration
- Configuration wizard

---

### avc-moodle-status.sh
**Purpose:** Display integration health dashboard
**Key Features:**
- SSO status
- Synchronization health
- User mapping status
- Configuration validation

---

### avc-moodle-sync.sh
**Purpose:** Manually trigger role/cohort synchronization
**Key Features:**
- Role sync between AVC and Moodle
- Cohort management
- User mapping updates
- Sync verification

---

### avc-moodle-test.sh
**Purpose:** Test OAuth2 SSO and integration functionality
**Key Features:**
- OAuth2 authentication testing
- Role sync testing
- Badge display testing
- Integration validation

---

## Podcast Hosting Command

### podcast.sh
**Purpose:** Automated Castopod podcast hosting setup
**Key Features:**
- Backblaze B2 bucket creation
- Application key generation
- Linode VPS provisioning with Docker
- Cloudflare DNS configuration
- Docker Compose configuration generation

**Prerequisites:**
- .secrets.yml with Linode, Cloudflare, B2 credentials
- SSH keys (via setup-ssh.sh)

**Orchestrates:**
1. Backblaze B2 bucket and key
2. Linode VPS with Docker
3. Cloudflare DNS
4. Docker Compose config

---

## Command Summary Statistics

**Total Commands:** 49

**By Category:**
- Core Lifecycle: 4 (install, setup, delete, uninstall)
- Site Management: 4 (status, doctor, verify, modify)
- Backup & Restore: 4 (backup, restore, rollback, schedule)
- Deployment: 7 (dev2stg, stg2live, stg2prod, live, produce, prod2stg, live2prod, live2stg)
- Content Sync: 3 (sync, import, copy)
- Testing: 4 (test, testos, test-nwp, run-tests)
- Utility: 8 (make, theme, security, security-check, seo-check, badges, email, storage, report)
- Migration: 2 (migration, migrate-secrets)
- Distributed Contribution: 2 (contribute, upstream)
- Coder Management: 4 (coders, coder-setup, bootstrap-coder, setup-ssh)
- AVC-Moodle Integration: 4 (avc-moodle-setup, avc-moodle-status, avc-moodle-sync, avc-moodle-test)
- Podcast Hosting: 1 (podcast)

**Commands with Multiple Verification Points:**
- install.sh: 6 verification points (drupal, moodle, gitlab, podcast, resume, migration)
- test-nwp.sh: 22+ test categories
- dev2stg.sh: 8 test types, 5 presets
- setup.sh: 19 components across 6 categories

**Commands with Sub-commands:**
- status.sh: health, info, delete, start, stop, restart
- verify.sh: report, check, details, verify, unverify, list, summary, reset
- migration.sh: analyze, prepare, run, verify, status
- security.sh: check, update, report
- seo-check.sh: check, staging, production, sitemap, headers
- storage.sh: (Backblaze B2 management)
- badges.sh: (GitLab badge management)
- email.sh: (Email management)
- rollback.sh: (Rollback management)
- theme.sh: build, watch, clean, install
- upstream.sh: sync, status, configure, info
- coder-setup.sh: add, remove

**Interactive TUI Commands:**
- setup.sh: Multi-page component selection
- status.sh: Site management with checkboxes
- verify.sh: Feature verification tracking
- modify.sh: Site option modification
- coders.sh: Coder management
- dev2stg.sh: Deployment options

**Commands with Auto-confirm Mode (-y):**
- delete.sh
- restore.sh
- dev2stg.sh
- sync.sh

**Commands with Resume/Step Support:**
- install.sh: Resume from step (s=N, --step=N, --resume)
- restore.sh: Resume from step (-s, --step=N)

**Commands with Multiple Recipes/Types:**
- install.sh: drupal, opensocial, moodle, gitlab, podcast
- test-nwp.sh: 22+ test categories
- migration.sh: drupal7/8/9, html, wordpress, joomla, other

---

## Command Naming Patterns

**Lifecycle Verbs:**
- install, setup, delete, uninstall

**State Management:**
- status, verify, doctor, modify

**Data Operations:**
- backup, restore, copy, sync, import

**Deployment Patterns:**
- <source>2<destination>: dev2stg, stg2prod, prod2stg, stg2live, live2prod, live2stg
- Provisioning: live, produce

**Testing Patterns:**
- test, testos, test-nwp, run-tests

**Integration Patterns:**
- <system1>-<system2>-<action>: avc-moodle-setup, avc-moodle-status, avc-moodle-sync, avc-moodle-test

**Management Patterns:**
- <resource>-<action>: coder-setup, setup-ssh, migrate-secrets
- <resource>.sh: coders, badges, email, storage, podcast, theme, security

---

## CLI Access

All commands are accessible via the unified CLI wrapper:

```bash
pl <command> [options]
pl1 <command> [options]  # Alternative name
pl2 <command> [options]  # Alternative name
```

Legacy direct access also supported:
```bash
./scripts/commands/<command>.sh [options]
./<command>.sh [options]  # Via symlinks in project root
```

---

## Documentation References

- Main README: `/home/rob/nwp/README.md`
- Roadmap: `/home/rob/nwp/docs/ROADMAP.md`
- Milestones: `/home/rob/nwp/docs/MILESTONES.md`
- Changelog: `/home/rob/nwp/CHANGELOG.md`
- ADRs: `/home/rob/nwp/docs/decisions/`
- Individual command help: `pl <command> --help`
