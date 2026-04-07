# F23: Project Separation — Self-Contained Sites Within NWP

**Status:** IMPLEMENTED (phases 1–8, 10) — Phase 9 (per-site git automation) DEFERRED
**Created:** 2026-04-06
**Author:** Rob Zaar, Claude Opus 4.6
**Priority:** High (architectural)
**Depends On:** None
**Breaking Changes:** Yes (managed via expand-migrate-contract)
**Estimated Effort:** 80-107 hours across 10 phases
**Supersedes:** F23 v1 — see `docs/archive/F23-project-separation-v1-superseded.md`

---

## 1. Executive Summary

### 1.1 Problem Statement

NWP currently mixes core tooling and project-specific code in a single repo with a flat layout:

1. **Project code scattered at root level.** `mt/`, `cathnet/`, `fin/`, `moodle_plugins/`, `modules/` all sit alongside `lib/`, `scripts/`, `pl` — blurring the boundary between NWP the tool and the projects it manages.

2. **Modules divorced from their sites.** `modules/mass_times/` is the Drupal module for the MT site, but it lives outside `sites/mt/`. Same for `modules/cathnet/`, `modules/dir_search/`, `modules/avc_moodle/`.

3. **Pipelines divorced from their sites.** The `mt/` Python scraper serves the MT site. The `cathnet/` NLP pipeline serves the CathNet site. Both live at the NWP root instead of inside their site folders.

4. **Backups divorced from their sites.** `sitebackups/avc/` is separate from `sites/avc/`. This makes it harder to back up or share a complete project.

5. **Monolithic config.** A single `nwp.yml` mixes global NWP settings with per-project settings (`settings.mass_times`, `sites.mt.live.*`, etc.).

6. **No per-site git.** Most sites can't have independent version control. Their history is tangled with NWP core and every other project.

7. **FIN monitor is homeless.** The financial monitor (`fin/`) is a managed project but has no site folder.

### 1.2 Proposed Solution

**Everything within `~/nwp/`.** No external config directories. One folder to back up and share.

- **Each project is fully self-contained** in `~/nwp/sites/<project>/` — its modules, pipelines, backups, proposals, and per-project config all live inside.
- **Per-site git is optional.** Production sites (`avc`, `ss`) keep their independent repos. Experimental sites (`cathnet`, `cccrdf`, `dir1`, `mt`, `fin`) remain untracked and are protected by F24's backup layer. The NWP parent repo `.gitignore`s all `sites/*/` contents regardless.
- **Per-site `.nwp.yml`** holds project-specific config. The root `nwp.yml` retains only global NWP settings.
- **`pl` discovers sites** by scanning `~/nwp/sites/*/` for `.nwp.yml` markers. No external registry needed.
- **AVC Coders Guild integration** provides automated `other_coders` provisioning via OAuth2 authentication + pull-based API sync.
- **Servers as infrastructure** in `~/nwp/servers/` — each server (e.g., `servers/nwpcode/`) is its own git repo with nginx configs, email setup, and provisioning scripts. Multiple servers supported.

### 1.3 Design Principles

1. **One folder to rule them all.** `~/nwp/` is the single canonical directory. Back it up and you have everything.
2. **Sites are self-contained.** Move `sites/mt/` to another machine and it carries everything: code, modules, pipeline, backups, proposals, config.
3. **Git is opt-in per site.** Production sites use independent repos; experimental sites rely on filesystem backups. No `.gitmodules`, no submodules.
4. **NWP core is clean.** After separation, `~/nwp/` root contains only the tool: `pl`, `lib/`, `scripts/`, `recipes/`, `templates/`, `docs/`, `tests/`, config files.
5. **Canonical remotes (when used).** Where a site has its own repo, the git.nwpcode.org remote holds the canonical version. Local copies can diverge. Nested module repos can have their own remotes.

---

## 2. Current State Analysis

### 2.1 What Lives Where Today

```
~/nwp/                                  # THE PROBLEM: everything mixed together
├── pl, lib/, scripts/, recipes/        # NWP Core (belongs here)
├── nwp.yml                             # Global + per-project config (mixed)
├── .secrets.yml, .secrets.data.yml     # Global secrets (belongs here)
├── docs/proposals/                     # NWP + project proposals (mixed)
│
├── sites/                              # Site installations
│   ├── avc/                            #   Has own .git ✓
│   ├── dir1/                           #   No own .git ✗
│   ├── mt/                             #   No own .git ✗
│   ├── cathnet/                        #   No own .git ✗
│   ├── ss/                             #   Tracks Moodle upstream .git
│   │   └── faith_formation/            #   Flutter app buried in Moodle site
│   └── verify-test-*/                  #   NWP test sites
│
├── modules/                            # PROBLEM: modules outside their sites
│   ├── mass_times/                     #   Belongs in sites/mt/
│   ├── cathnet/                        #   Belongs in sites/cathnet/
│   ├── dir_search/                     #   Belongs in sites/dir1/
│   └── avc_moodle/                     #   Belongs in sites/avc/
│
├── mt/                                 # PROBLEM: pipeline outside its site
│   └── src/, data/, templates/         #   Belongs in sites/mt/
│
├── cathnet/                            # PROBLEM: pipeline outside its site
│   └── src/, data/                     #   Belongs in sites/cathnet/
│
├── fin/                                # PROBLEM: not a site at all
│   └── fin-monitor.sh, deploy.sh       #   Should be sites/fin/
│
├── moodle_plugins/                     # PROBLEM: plugin outside its site
│   └── auth/avc_oauth2/               #   Belongs in sites/ss/
│
├── sitebackups/                        # PROBLEM: backups outside their sites
│   ├── avc/
│   ├── mt/
│   └── test/
│
├── email/                              # PROBLEM: server infra outside sites/server/
│
└── linode/, .secrets.yml               # Server config scattered at root
```

### 2.2 Additional Problem: The Shared Server

The Linode server (97.107.137.88 / nwpcode.org) hosts all live sites but has no "site" of its own. Its config is scattered:
- `linode.*` section in `nwp.yml`
- `email/` directory at NWP root
- nginx configs only exist on the server (not tracked)
- SSL, firewall, fail2ban configs only on server

Sites reference it via `live.server_ip` in their config, but there's no single place that represents "the server" as a managed entity.

### 2.3 What Needs to Move

| Source | Destination | Size |
|--------|------------|------|
| `modules/mass_times/` | `sites/mt/web/modules/custom/mass_times/` | 100KB |
| `mt/` (Python pipeline) | `sites/mt/pipeline/` | 215MB |
| `sitebackups/mt/` | `sites/mt/backups/` | varies |
| `docs/proposals/F16-*`, `F17-*` | `sites/mt/docs/proposals/` | 50KB |
| `modules/cathnet/` | `sites/cathnet/web/modules/custom/cathnet/` | 50KB |
| `cathnet/` (NLP pipeline) | `sites/cathnet/pipeline/` | 7.8GB |
| `docs/proposals/F18-*`, `F19-*`, `F21-*` | `sites/cathnet/docs/proposals/` | 100KB |
| `modules/dir_search/` | `sites/dir1/web/modules/custom/dir_search/` | 50KB |
| `modules/avc_moodle/` | `sites/avc/html/modules/custom/avc_moodle/` | 300KB |
| `moodle_plugins/auth/avc_oauth2/` | `sites/ss/auth/avc_oauth2/` | 50KB |
| `docs/proposals/F20-*` | `sites/ss/docs/proposals/` | 50KB |
| `fin/` | `sites/fin/` (new site) | 196MB |
| `email/` | `servers/nwpcode/email/` | 132KB |
| `linode/` | `servers/nwpcode/linode/` | varies |
| `nwp.yml` `linode.*` section | `servers/nwpcode/.nwp-server.yml` | — |
| `sitebackups/*/` | `sites/*/backups/` | varies |

### 2.4 Cross-Project Dependencies

```
                    ┌─────────────────────────┐
                    │   servers/nwpcode/       │
                    │   (97.107.137.88)        │
                    │   nginx, postfix, SSL    │
                    └──────────┬──────────────┘
                               │
              All live sites deploy here
                               │
     ┌──────────┬──────────┬───┴────┬──────────┐
     │          │          │        │          │
   AVC ←SSO→ SS(Moodle)  MT    CathNet     DIR
```

- AVC ↔ SS reference each other by **URL**, not filesystem path — no coupling to break
- All sites reference `servers/nwpcode/` for deployment config (IP, SSH, domain)
- Multiple servers supported: each coder can have their own server
- MT, CathNet, DIR, FIN are fully independent of each other

---

## 3. Target Architecture

### 3.1 Directory Layout

```
~/nwp/                                  # ONE FOLDER — backed up as a unit
├── pl                                  # CLI entry point
├── lib/                                # 60+ shared bash libraries
├── scripts/commands/                   # 57 command scripts
├── recipes/                            # Recipe definitions
├── templates/                          # DDEV, env, docker templates
├── docs/                               # NWP-only documentation
│   ├── proposals/                      #   NWP-only proposals (F23, etc.)
│   ├── decisions/                      #   Architecture Decision Records
│   └── ...                             #   Guides, governance, security
├── tests/                              # NWP tool-level tests
├── nwp.yml                             # Global NWP config (no per-site data)
├── example.nwp.yml                     # Template for new installations
├── .secrets.yml                        # Infrastructure secrets
├── .secrets.data.yml                   # Data secrets
├── CLAUDE.md, CHANGELOG.md, README.md
│
├── servers/                            # INFRASTRUCTURE (one dir per server)
│   ├── nwpcode/                        # ← Own .git repo
│   │   ├── .nwp-server.yml            #   Server config (IP, SSH, services)
│   │   ├── nginx/sites-available/     #   Tracked nginx vhost configs
│   │   ├── email/                     #   ← Moved from ~/nwp/email/
│   │   ├── ssl/, security/            #   Certbot, fail2ban, UFW
│   │   ├── scripts/deploy.sh          #   Push configs to server
│   │   └── backups/
│   └── george-dev/                     # ← Coder's provisioned server
│       └── .nwp-server.yml
│
└── sites/                              # ALL projects live here
    ├── avc/                            # ← Own .git repo
    │   ├── .nwp.yml                    #   Project config
    │   ├── .gitignore                  #   Ignores .nwp.local.yml, backups/, etc.
    │   ├── html/                       #   Drupal webroot
    │   │   ├── modules/custom/
    │   │   │   └── avc_moodle/         #   ← Moved from ~/nwp/modules/
    │   │   ├── profiles/custom/avc/    #   ← Can be nested .git
    │   │   │   ├── modules/            #   Profile modules
    │   │   │   └── themes/             #   Profile themes
    │   │   └── themes/custom/
    │   ├── .ddev/
    │   ├── backups/                    #   ← Moved from sitebackups/avc/
    │   ├── docs/proposals/             #   AVC-specific proposals
    │   └── composer.json
    │
    ├── mt/                             # ← Own .git repo
    │   ├── .nwp.yml                    #   Includes mass_times settings
    │   ├── web/                        #   Drupal webroot
    │   │   └── modules/custom/
    │   │       └── mass_times/         #   ← Moved from ~/nwp/modules/
    │   ├── pipeline/                   #   ← Moved from ~/nwp/mt/
    │   │   ├── src/
    │   │   ├── data/
    │   │   ├── templates/
    │   │   ├── tests/
    │   │   └── requirements.txt
    │   ├── scripts/                    #   Deploy/setup scripts
    │   ├── .ddev/
    │   ├── backups/
    │   ├── docs/proposals/             #   F16, F17 proposals
    │   └── composer.json
    │
    ├── cathnet/                        # ← Own .git repo
    │   ├── .nwp.yml
    │   ├── web/
    │   │   └── modules/custom/
    │   │       └── cathnet/            #   ← Moved from ~/nwp/modules/
    │   ├── pipeline/                   #   ← Moved from ~/nwp/cathnet/
    │   │   ├── src/
    │   │   ├── data/
    │   │   └── requirements-nlp.txt
    │   ├── .ddev/
    │   ├── backups/
    │   ├── docs/proposals/             #   F18, F19, F21 proposals
    │   └── composer.json
    │
    ├── dir1/                           # ← Own .git repo
    │   ├── .nwp.yml
    │   ├── web/
    │   │   └── modules/custom/
    │   │       └── dir_search/         #   ← Moved from ~/nwp/modules/
    │   ├── .ddev/
    │   ├── backups/
    │   └── composer.json
    │
    ├── ss/                             # ← Own .git repo
    │   ├── .nwp.yml
    │   ├── auth/avc_oauth2/            #   ← Moved from moodle_plugins/
    │   ├── course/format/tabbed/       #   Custom course format
    │   ├── faith_formation/            #   Flutter app (already here)
    │   ├── moodledata/                 #   Moodle data directory
    │   ├── backups/
    │   ├── docs/proposals/             #   F20 proposal
    │   └── config.php
    │
    ├── fin/                            # ← Own .git repo (NEW SITE)
    │   ├── .nwp.yml                    #   type: utility
    │   ├── pipeline/                   #   ← Moved from ~/nwp/fin/
    │   │   ├── fin-monitor.sh
    │   │   ├── deploy-fin-monitor.sh
    │   │   ├── setup-fin-monitor.sh
    │   │   └── requirements.txt
    │   ├── backups/
    │   └── docs/
    │
    ├── cccrdf/                         # ← Own .git repo
    │   ├── .nwp.yml
    │   └── ...
    │
    └── verify-test-*/                  # NWP test sites (ephemeral, no .git)
```

### 3.2 Nested Git Architecture

**Not every site needs its own git repo.** Production sites (avc, ss) have independent repos; experimental sites (cathnet, cccrdf, dir1, mt) stay filesystem-only and rely on F24's backup layer for protection. See Phase 7 for the full policy.

Regardless of whether a site has its own `.git/`, the NWP parent repo ignores all `sites/*/` contents:

```gitignore
# ~/nwp/.gitignore
# Site directories — managed independently (or not at all)
/sites/*
!/sites/.gitkeep
```

This way the parent repo is never polluted by site code, and sites that *do* have their own repo don't conflict with sites that don't.

Within a production site, modules/profiles can have their own nested git:

```
sites/avc/                              # Site git repo
├── .git/                               # Site-level git
├── .gitignore                          # Ignores nested repos, backups, etc.
│   # contents:
│   #   html/profiles/custom/avc/       # Nested profile repo
│   #   backups/
│   #   .nwp.local.yml
│   #   vendor/
│   #   .ddev/
├── html/
│   └── profiles/custom/avc/
│       ├── .git/                       # Profile-level git (nested)
│       ├── .gitignore
│       │   #   modules/avc_features/   # Could be its own nested repo too
│       ├── modules/
│       │   ├── avc_features/
│       │   │   └── .git/              # Module-level git (deeply nested)
│       │   └── custom/
│       └── themes/
```

**How this works:**
- Git naturally ignores subdirectories that have their own `.git/` when the parent `.gitignore` lists them
- Each level can push/pull to its own remote independently
- The remote (git.nwpcode.org) holds the **canonical** version
- Developers can modify their local copy; `git pull` from remote to get canonical updates
- No submodules, no `.gitmodules` file, no `git submodule update` commands

**Remote structure on git.nwpcode.org:**
```
nwp/nwp.git          # NWP core tool
nwp/avc.git          # AVC site (production — existing repo)
nwp/avc-profile.git  # AVC Drupal profile (nested within avc)
nwp/ss.git           # Moodle site (production — existing repo)
# cathnet, cccrdf, dir1, mt, fin: experimental — no remote, filesystem only
```

New production-grade sites can be added to the remote list as they stabilise. There is no requirement that every directory in `sites/` correspond to a remote.

### 3.3 Configuration Architecture

#### Global Config (`~/nwp/nwp.yml`) — NWP tool settings only

```yaml
# ~/nwp/nwp.yml  (NO per-site data)
settings:
  license: { ... }
  timezone: Australia/Melbourne
  cli_command: pl
  email:
    domain: nwpcode.org
    admin_email: admin@nwpcode.org
    auto_configure: true
  php: "8.3"
  database: mariadb
  claude: { ... }
  frontend: { ... }
  seo: { ... }
  verification: { ... }
  todo: { ... }

recipes:
  d: { ... }
  avc: { ... }
  os: { ... }
  m: { ... }
  mt: { ... }
  gitlab: { ... }
  pod: { ... }

other_coders:
  nameservers: [...]
  coders: { ... }              # Synced from AVC Coders Guild (see Section 5)

linode:
  servers: { ... }

import_defaults: { ... }
```

**Removed from nwp.yml:** `sites.*`, `settings.mass_times.*`, and all per-project settings.

#### Per-Project Config (`sites/<project>/.nwp.yml`)

```yaml
# ~/nwp/sites/mt/.nwp.yml
schema_version: 2                       # See Section 3.7 — bumped on breaking changes
nwp_version_created: "0.29.0"           # NWP version that created this file
nwp_version_updated: "0.31.0"           # NWP version that last touched it

project:
  name: mt
  type: drupal                          # drupal | moodle | utility | flutter
  recipe: mt
  environment: production
  created: "2026-03-15T10:00:00+11:00"
  purpose: indefinite

live:
  enabled: true
  domain: mt.nwpcode.org
  server_ip: 97.107.137.88
  linode_id: 12345
  remote_path: /var/www/mt

# Project-specific settings (was in nwp.yml settings.mass_times)
mass_times:
  centre_lat: -37.8136
  centre_lng: 145.2280
  radius_km: 20
  fallback_model: "claude-sonnet-4-5-20250514"
  max_monthly_llm_usd: 5
  tier3_daily_limit: 10
  alert_on_failure: true
  weekly_summary: true
  drupal_api_user: mass_times_sync

backups:
  directory: ./backups
  schedule: "0 2 * * *"

vrt:
  pages: ["/", "/parishes", "/map"]
  threshold: 0.05

email:
  enabled: true
  address: mt@nwpcode.org
```

#### Per-Developer Overrides (`sites/<project>/.nwp.local.yml`, gitignored)

```yaml
# ~/nwp/sites/mt/.nwp.local.yml
project:
  environment: development
live:
  enabled: false
mass_times:
  shadow_mode: true
```

#### Resolution Order

```
CLI flags  >  .nwp.local.yml  >  .nwp.yml  >  ~/nwp/nwp.yml  >  built-in defaults
```

All config files are within `~/nwp/`. Nothing external.

### 3.4 Project Discovery

`pl` discovers projects by scanning `~/nwp/sites/`:

```bash
discover_sites() {
    local sites_dir="$NWP_DIR/sites"
    for dir in "$sites_dir"/*/; do
        if [[ -f "$dir/.nwp.yml" ]]; then
            echo "$(basename "$dir")"
        fi
    done
}

resolve_project() {
    local identifier="$1"
    local site_dir="$NWP_DIR/sites/$identifier"

    # 1. Direct match in sites/
    if [[ -d "$site_dir" ]] && [[ -f "$site_dir/.nwp.yml" ]]; then
        echo "$site_dir"; return 0
    fi

    # 2. Legacy: site exists but no .nwp.yml yet (transition period)
    if [[ -d "$site_dir" ]] && [[ -d "$site_dir/.ddev" ]]; then
        echo "$site_dir"; return 0
    fi

    return 1
}

# Also support running from within a site directory:
find_project_from_cwd() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/.nwp.yml" ]] && [[ "$(dirname "$dir")" == */sites ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}
```

This enables:
```bash
cd ~/nwp/sites/mt
pl backup                # Knows it's MT from .nwp.yml in current directory

pl backup mt             # Explicit: resolves to ~/nwp/sites/mt/
pl status --all          # Scans ~/nwp/sites/*/.nwp.yml
```

### 3.5 Backup Architecture

Backups move inside each site:

```
# Old:
~/nwp/sitebackups/mt/20260401-main-abc123.sql.gz

# New:
~/nwp/sites/mt/backups/20260401-main-abc123.sql.gz
```

Where a site has its own git repo, `backups/` is gitignored (large binary data doesn't belong in version control). Because the directory lives inside `~/nwp/`, it's still captured by F24's restic-to-SSD backup regardless of git status.

### 3.6 Per-Site Proposals

Project-specific proposals move into their sites:

| Proposal | Current Location | New Location |
|----------|-----------------|-------------|
| F16, F17 (Mass Times) | `docs/proposals/` | `sites/mt/docs/proposals/` |
| F18, F19, F21 (CathNet) | `docs/proposals/` | `sites/cathnet/docs/proposals/` |
| F20 (Faith Formation) | `docs/proposals/` | `sites/ss/docs/proposals/` |
| F22 (Claude Code Web) | `docs/proposals/` | Stays in `docs/proposals/` (NWP infrastructure) |
| F23 (This proposal) | `docs/proposals/` | Stays in `docs/proposals/` (NWP infrastructure) |

NWP-level proposals (infrastructure, tool features) stay in `~/nwp/docs/proposals/`. When `pl` aggregates proposals across all projects, it scans `sites/*/docs/proposals/` plus the NWP-level directory.

### 3.7 Schema Versioning and Migration

`.nwp.yml` will evolve over time as NWP adds features, renames fields, restructures sections, or deprecates options. A site backed up under one NWP version may be restored or imported into a much newer NWP, and its `.nwp.yml` may be missing required fields or use obsolete structure. This section defines how that mismatch is detected and corrected.

#### 3.7.1 Schema Version Field

Every `.nwp.yml` carries a `schema_version` integer at the top level:

```yaml
schema_version: 2                       # Current schema version this file conforms to
nwp_version_created: "0.29.0"           # NWP version that created this file
nwp_version_updated: "0.31.0"           # NWP version that last modified it
```

| Field | Purpose |
|-------|---------|
| `schema_version` | Integer that increments on **breaking** schema changes (renamed fields, removed sections, restructured nesting). Used by migration logic to determine which migrations to apply. |
| `nwp_version_created` | NWP semver at creation. Informational — for debugging and changelog correlation. |
| `nwp_version_updated` | NWP semver of the last write. Informational. |

The same three fields appear in `~/nwp/nwp.yml` and `servers/*/.nwp-server.yml`. Each schema (project, global, server) has its own independent version counter.

#### 3.7.2 When Migrations Run

A migration is needed whenever NWP encounters a config file with `schema_version` lower than the current code expects. Triggers:

| Trigger | What Happens |
|---------|-------------|
| **`pl site import <path>`** | Importing an existing site directory. NWP checks `schema_version`, prompts to migrate if outdated. |
| **`pl rebuild`** (F24) | Restoring sites from backup. Migration runs automatically as part of restore. |
| **`pl doctor`** | Reports any sites with outdated schema, suggests `pl site migrate`. |
| **First run after `pl update`** | NWP itself was upgraded. Auto-checks all sites for schema lag, prompts. |
| **`pl site migrate <site>`** | Manual invocation. |
| **Any `pl` command on a site with old schema** | Read-only commands work (with warning); write commands refuse until migrated. |

#### 3.7.3 Migration Script Structure

Migrations live in `lib/migrations/site/` (one file per version step), inspired by Drupal `hook_update_N()` and Django/Rails migrations:

```
lib/migrations/
├── site/
│   ├── 001-initial.sh              # Bootstrap: schema_version absent → 1
│   ├── 002-rename-server-ip.sh     # 1 → 2: live.server_ip → live.server (named ref)
│   ├── 003-add-vrt-section.sh      # 2 → 3: add vrt: section with defaults
│   ├── 004-flatten-mass-times.sh   # 3 → 4: mass_times.* → settings.mass_times.*
│   └── ...
├── global/                          # Migrations for ~/nwp/nwp.yml
│   ├── 001-initial.sh
│   └── ...
└── server/                          # Migrations for servers/*/.nwp-server.yml
    ├── 001-initial.sh
    └── ...
```

Each migration is a small script that:
1. Reads the current `.nwp.yml`
2. Applies its transformation (using `yq` or a Python helper for safety)
3. Bumps `schema_version` to the new value
4. Updates `nwp_version_updated`
5. Writes atomically (write to temp, fsync, rename)

Example migration script:

```bash
#!/bin/bash
# lib/migrations/site/002-rename-server-ip.sh
# Migrate schema_version 1 → 2
# Change: live.server_ip (string IP) → live.server (server name)

migrate_001_to_002() {
    local site_dir="$1"
    local config="$site_dir/.nwp.yml"

    # Read old field
    local old_ip
    old_ip=$(yq eval '.live.server_ip // ""' "$config")

    if [[ -z "$old_ip" ]]; then
        # No live config — just bump version and exit
        yq eval -i '.schema_version = 2' "$config"
        return 0
    fi

    # Look up which server has this IP
    local server_name=""
    for server_dir in "$NWP_DIR"/servers/*/; do
        local server_ip
        server_ip=$(yq eval '.server.ip // ""' "$server_dir/.nwp-server.yml" 2>/dev/null)
        if [[ "$server_ip" == "$old_ip" ]]; then
            server_name=$(basename "$server_dir")
            break
        fi
    done

    if [[ -z "$server_name" ]]; then
        log_warning "Could not find server with IP $old_ip — leaving live.server unset"
        log_warning "Edit $config manually to set live.server: <name>"
        yq eval -i 'del(.live.server_ip)' "$config"
    else
        yq eval -i ".live.server = \"$server_name\" | del(.live.server_ip)" "$config"
        log_info "Migrated $site_dir: live.server_ip → live.server: $server_name"
    fi

    yq eval -i '.schema_version = 2' "$config"
    yq eval -i ".nwp_version_updated = \"$NWP_VERSION\"" "$config"
}
```

#### 3.7.4 Migration Runner

```bash
# scripts/commands/site.sh — pl site migrate subcommand

CURRENT_SITE_SCHEMA=4    # Bumped by NWP developers when adding migrations

migrate_site() {
    local site="$1"
    local site_dir="$NWP_DIR/sites/$site"
    local config="$site_dir/.nwp.yml"

    if [[ ! -f "$config" ]]; then
        log_error "No .nwp.yml found at $config"
        return 1
    fi

    local current_version
    current_version=$(yq eval '.schema_version // 0' "$config")

    if [[ "$current_version" -ge "$CURRENT_SITE_SCHEMA" ]]; then
        log_info "$site is up to date (schema $current_version)"
        return 0
    fi

    log_info "Migrating $site from schema $current_version → $CURRENT_SITE_SCHEMA"

    # Pre-migration backup
    cp "$config" "$config.pre-migration-$(date +%Y%m%dT%H%M%S).bak"

    # Apply each migration in sequence
    local from="$current_version"
    while [[ "$from" -lt "$CURRENT_SITE_SCHEMA" ]]; do
        local to=$((from + 1))
        local script
        script=$(printf "%s/lib/migrations/site/%03d-*.sh" "$NWP_DIR" "$to")
        script=$(ls $script 2>/dev/null | head -1)

        if [[ -z "$script" ]]; then
            log_error "Missing migration script for schema $from → $to"
            log_error "Restoring backup and aborting"
            mv "$config.pre-migration-"*.bak "$config"
            return 1
        fi

        log_info "  Applying $(basename "$script")..."
        # shellcheck source=/dev/null
        source "$script"
        if ! "migrate_$(printf "%03d" "$from")_to_$(printf "%03d" "$to")" "$site_dir"; then
            log_error "Migration $from → $to failed — restoring backup"
            mv "$config.pre-migration-"*.bak "$config"
            return 1
        fi

        from="$to"
    done

    log_success "$site migrated to schema $CURRENT_SITE_SCHEMA"
    log_info "Backup of original: $config.pre-migration-*.bak"
}
```

#### 3.7.5 Detecting Stale Schemas

`pl doctor` and most read commands warn:

```bash
pl status mt
# ⚠ Warning: sites/mt/.nwp.yml is at schema_version 2 (current: 4)
#   Run 'pl site migrate mt' to update.
#   Read-only commands will continue to work.
```

Write commands refuse until migrated:

```bash
pl backup mt
# ✗ Error: sites/mt/.nwp.yml is at schema_version 2 (current: 4)
#   Migration required before write operations.
#   Run 'pl site migrate mt' first.
```

This prevents writing data into an old-schema config that might conflict with new field semantics.

#### 3.7.6 Restoring an Old Backup Into New NWP

The full flow for the user's scenario — a site backed up under NWP 0.29 being restored into NWP 0.35:

```bash
# 1. User installs new NWP
git clone git@git.nwpcode.org:nwp/nwp.git ~/nwp
cd ~/nwp && ./setup.sh

# 2. User restores an old site (from F24 restic backup or manual copy)
pl rebuild --site mt
#   OR
cp -r /old-backup/sites/mt ~/nwp/sites/mt

# 3. NWP detects schema mismatch
pl doctor
# ⚠ sites/mt is at schema_version 2 (current: 4)

# 4. User runs migration
pl site migrate mt
# Migrating mt from schema 2 → 4
#   Applying 003-add-vrt-section.sh...
#   Applying 004-flatten-mass-times.sh...
# ✓ mt migrated to schema 4
# Backup of original: sites/mt/.nwp.yml.pre-migration-20260407T143022.bak

# 5. Site is now usable with new NWP
pl status mt
```

**Bulk migration:**

```bash
pl site migrate --all
# Scans sites/*/, migrates any with schema_version < CURRENT_SITE_SCHEMA
# Reports per-site success/failure summary
```

#### 3.7.7 Rules for NWP Developers Adding Migrations

When changing the `.nwp.yml` schema in a way that breaks backwards compatibility:

1. **Bump `CURRENT_SITE_SCHEMA`** in `scripts/commands/site.sh`
2. **Add migration script** at `lib/migrations/site/NNN-description.sh` where `NNN` matches the new version
3. **Migration must be idempotent** — running it twice produces the same result
4. **Migration must be reversible-by-restore** — the pre-migration backup is the rollback path
5. **Document the change** in CHANGELOG.md under a "Schema Migrations" subsection
6. **Update `example.nwp.yml`** to reflect the new schema with bumped `schema_version`
7. **Add a test** in `tests/migrations/` that creates an old-schema file, runs the migration, and asserts the result

**Non-breaking changes** (adding optional fields with defaults) do NOT need a migration — the resolver supplies defaults at read time.

#### 3.7.8 Schema Version History (Example)

A table maintained in `docs/reference/schema-versions.md`:

| Version | NWP Release | Change | Migration Script |
|---------|------------|--------|-----------------|
| 1 | 0.29 | Initial `.nwp.yml` introduced (F23) | `001-initial.sh` |
| 2 | 0.31 | `live.server_ip` → `live.server` (named ref to `servers/`) | `002-rename-server-ip.sh` |
| 3 | 0.32 | New `vrt:` section for visual regression config | `003-add-vrt-section.sh` |
| 4 | 0.33 | `mass_times.*` → `settings.mass_times.*` | `004-flatten-mass-times.sh` |

This table serves as both documentation and a sanity check that every version bump has a corresponding migration script.

---

## 4. Nested Git Strategy

### 4.1 The Pattern

This is standard practice in the Drupal ecosystem. A Drupal site repo contains a profile directory that has its own git, which contains module directories that have their own git. Each level's `.gitignore` excludes the nested repos.

```
Site repo (.git)
  └── .gitignore: "html/profiles/custom/avc/"
      └── Profile repo (.git)
          └── .gitignore: "modules/avc_features/"
              └── Module repo (.git)
```

**Why not submodules?**
- Submodules require `git submodule update --init --recursive` after clone
- Submodules create `.gitmodules` metadata that must be maintained
- Submodules pin to specific commits, creating constant merge friction
- Nested independent repos are simpler: just clone each repo into the right place

**Why not Composer path repos?**
- Composer path repos work for PHP dependencies but not for Python pipelines, Flutter apps, or shell scripts
- The nested git pattern works uniformly for all project types

### 4.2 Workflow (Production Sites)

This workflow applies only to sites that have their own git repo (currently `avc`, `ss`). Experimental sites are untracked — see §3.2 and Phase 7.

**Initial setup (for a developer):**
```bash
cd ~/nwp/sites
git clone git@git.nwpcode.org:nwp/avc.git
cd avc
# If there are nested repos (e.g., the avc Drupal profile):
git clone git@git.nwpcode.org:nwp/avc-profile.git html/profiles/custom/avc
```

**Daily work:**
```bash
cd ~/nwp/sites/avc
git add -A && git commit -m "Update Drupal config"
git push origin main

# Work on nested profile
cd html/profiles/custom/avc
git add -A && git commit -m "Update feature"
git push origin main
```

**Canonical updates:**
```bash
cd ~/nwp/sites/avc/html/profiles/custom/avc
git pull origin main    # Get latest canonical profile version
```

### 4.3 NWP Parent Repo .gitignore

The parent repo ignores everything inside `sites/` and `servers/` with a single blanket rule. This avoids having to enumerate every site (and keeps the ignore list stable as sites come and go):

```gitignore
# ~/nwp/.gitignore additions

# Site directories — managed independently or untracked (see F23 §3.2, Phase 7)
/sites/*
!/sites/.gitkeep

# Server directories — independent repos (see F23 §6)
/servers/*
!/servers/.gitkeep

# Auth tokens (never commit)
.auth.yml

# Legacy directories (removed after migration)
# modules/         — moved into sites (Phase 2)
# mt/              — moved to sites/mt/pipeline/ (Phase 3)
# cathnet/         — moved to sites/cathnet/pipeline/ (Phase 3)
# fin/             — moved to sites/fin/pipeline/ (Phase 3)
# moodle_plugins/  — moved to sites/ss/ (Phase 2)
# sitebackups/     — moved into sites/*/backups/ (Phase 4)
# email/           — moved to servers/nwpcode/email/ (Phase 8)
# linode/          — moved to servers/nwpcode/linode/ (Phase 8)
```

Note: `verify-test-*` sites are created and destroyed by `verify.sh` and live in `sites/`. Since `/sites/*` ignores them, the test runner manages them entirely via the filesystem, not via git — which is what it already does.

---

## 5. AVC Coders Guild → NWP `other_coders` Integration

### 5.1 Current State

Two disconnected systems:

| System | What It Manages | Where |
|--------|----------------|-------|
| **AVC Coders Guild** | Drupal group membership on the AVC site. Users join the guild, get roles (admin, facilitator, mentor, member) | AVC Drupal site |
| **NWP `other_coders`** | DNS delegation, GitLab accounts, SSH keys, server provisioning, contribution tracking | `nwp.yml` + `coder-setup.sh` + `coders.sh` |

Currently: A human manually runs `pl coder add george` to create a coder entry, separately from the user joining the AVC Coders Guild. No automated connection.

### 5.2 Two Problems to Solve

**Problem A: Identity.** How does a developer running NWP locally prove they are "george" on the AVC site? Currently there's no link between a local NWP coder and their AVC account.

**Problem B: Sync.** How does guild membership on AVC automatically update `other_coders` in `nwp.yml`? Currently this is a manual process.

### 5.3 Solution: OAuth2 Authentication + Pull-Based Sync

**Architecture:**

```
┌─────────────────────────────────────────────────────────┐
│  DEVELOPER AUTHENTICATION (Problem A)                    │
│                                                          │
│  Developer runs: pl auth login                           │
│    → Browser opens AVC OAuth2 authorize URL              │
│    → Developer logs into AVC (if not already)            │
│    → AVC shows: "NWP CLI wants to access your profile"  │
│    → Developer clicks Allow                              │
│    → Browser redirects to localhost:9876/callback         │
│    → pl receives auth code, exchanges for tokens         │
│    → OIDC ID token contains: username, email, guild roles│
│    → pl stores token at ~/nwp/.auth.yml (gitignored)    │
│    → Developer is now authenticated as their AVC identity│
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  MEMBERSHIP SYNC (Problem B)                             │
│                                                          │
│  NWP server cron (every 5 min): pl coders sync-guild     │
│    → Server queries AVC API with service account token   │
│    → GET /jsonapi/group_content/coders_guild_membership  │
│    → Receives current member list with roles              │
│    → Compares with nwp.yml other_coders                  │
│    → Adds new members, deactivates removed ones          │
│    → No inbound webhook endpoint needed                  │
└─────────────────────────────────────────────────────────┘
```

### 5.4 Developer Authentication: `pl auth login`

**Why OAuth2 Authorization Code flow?**
- Developer proves their AVC identity through the AVC site itself
- NWP never sees or stores AVC passwords
- Guild roles come from the OIDC token's `groups` claim
- Same protocol used for "Sign in with Google/GitHub"
- AVC already has Simple OAuth installed (for Moodle SSO)

**Flow:**

```bash
pl auth login
```

1. `pl` starts a temporary HTTP server on `localhost:9876`
2. Opens browser to:
   ```
   https://avc.nwpcode.org/oauth/authorize?
     client_id=nwp-cli&
     redirect_uri=http://localhost:9876/callback&
     response_type=code&
     scope=openid+profile+email&
     state=<random-csrf-token>&
     code_challenge=<PKCE-challenge>&
     code_challenge_method=S256
   ```
3. Developer authenticates on AVC site (or is already logged in)
4. AVC shows consent screen: "NWP CLI wants to access your profile. Allow?"
5. AVC redirects to `localhost:9876/callback?code=<auth-code>&state=<csrf-token>`
6. `pl` validates `state` parameter matches what it sent (CSRF protection)
7. `pl` exchanges auth code for tokens:
   ```bash
   curl -X POST https://avc.nwpcode.org/oauth/token \
     -d grant_type=authorization_code \
     -d code=$AUTH_CODE \
     -d redirect_uri=http://localhost:9876/callback \
     -d client_id=nwp-cli \
     -d code_verifier=$PKCE_VERIFIER
   ```
8. Response contains `access_token`, `refresh_token`, `id_token`
9. `pl` decodes ID token to get: `sub`, `preferred_username`, `email`, `groups`
10. Stores in `~/nwp/.auth.yml` (gitignored):
    ```yaml
    # ~/nwp/.auth.yml (GITIGNORED — never committed)
    auth:
      provider: avc.nwpcode.org
      username: george
      email: george@example.com
      guild_roles: [guild_member]
      access_token: eyJ...
      refresh_token: dGh...
      token_expiry: "2026-04-07T10:00:00Z"
      authenticated_at: "2026-04-06T10:00:00Z"
    ```

**Security measures:**
- **PKCE (Proof Key for Code Exchange):** Prevents authorization code interception — the code is useless without the code_verifier, which never leaves the developer's machine.
- **State parameter:** Prevents CSRF attacks on the callback.
- **localhost callback:** Token never passes through an external server.
- **Tokens stored locally:** `~/nwp/.auth.yml` is gitignored and mode 0600.
- **Token refresh:** `pl` automatically refreshes expired tokens using the refresh token. If the developer is removed from the guild, the refresh fails → `pl` marks auth as invalid.

**Subsequent commands use the authenticated identity:**

```bash
pl status           # Shows "Authenticated as: george (contributor)"
pl auth status      # Shows current auth state, token expiry, guild roles
pl auth logout      # Clears stored tokens
pl auth refresh     # Force-refreshes tokens and guild roles
```

### 5.5 Custom OIDC Claims Module (Drupal Side)

AVC already has Simple OAuth. Add a tiny module (~20 lines) to include guild roles in the OIDC response:

```php
// sites/avc/html/modules/custom/avc_oidc_claims/avc_oidc_claims.module

/**
 * Implements hook_simple_oauth_oidc_claims_alter().
 */
function avc_oidc_claims_simple_oauth_oidc_claims_alter(array &$claims, array &$context) {
  $account = $context['account'];
  $groups = [];

  $membership_loader = \Drupal::service('group.membership_loader');
  foreach ($membership_loader->loadByUser($account) as $membership) {
    $group = $membership->getGroup();
    $roles = array_map(fn($r) => $r->id(), $membership->getRoles());
    $groups[] = [
      'group' => $group->label(),
      'group_id' => $group->id(),
      'roles' => $roles,
    ];
  }

  $claims['groups'] = $groups;
  $claims['roles'] = $account->getRoles(TRUE);
}
```

**Also register the NWP CLI as an OAuth2 client** in AVC's Simple OAuth settings:
- Client ID: `nwp-cli`
- Client secret: (none — public client with PKCE)
- Redirect URI: `http://localhost:9876/callback`
- Scopes: `openid`, `profile`, `email`
- Grant type: Authorization Code

### 5.6 Server-Side Membership Sync: Pull-Based (Secure)

**Why pull, not webhooks?**

| Concern | Webhook (push) | API Polling (pull) |
|---------|---------------|-------------------|
| **Attack surface** | Exposes an HTTP endpoint that attackers can probe | Zero inbound surface — NWP initiates all connections |
| **Spoofing** | Must verify HMAC signatures | Impossible — NWP controls the request |
| **Replay attacks** | Must check timestamps | N/A |
| **Shell injection** | Risk if payload reaches bash | N/A — NWP constructs its own queries |
| **Complexity** | ~130 lines (receiver + nginx + signing) | ~60 lines (cron script) |
| **Latency** | Real-time | Up to 5 minutes (configurable) |
| **Reliability** | Must handle delivery failures, retries | Self-healing on every poll |

For guild membership changes, 5-minute latency is perfectly acceptable. The pull approach eliminates an entire class of security concerns.

**Implementation:**

```bash
# scripts/commands/coders.sh — add 'sync-guild' subcommand
# Runs on the NWP server via cron:
# */5 * * * * /opt/nwp/pl coders sync-guild

sync_guild() {
    local api_url="https://avc.nwpcode.org"
    local token
    token=$(get_infra_secret "avc.api_token" "")

    # 1. Fetch current guild members from AVC JSON:API
    local members_json
    members_json=$(curl -sf \
        -H "Authorization: Bearer $token" \
        "$api_url/jsonapi/group_content/coders-group_membership?include=entity_id" \
        2>/dev/null) || { log_error "Failed to fetch guild members"; return 1; }

    # 2. Parse with Python (safe — no shell interpolation of user data)
    python3 "$NWP_DIR/scripts/helpers/sync-guild-members.py" \
        --members-json "$members_json" \
        --config "$NWP_DIR/nwp.yml"
}
```

**Python sync script** (`scripts/helpers/sync-guild-members.py`):

```python
#!/usr/bin/env python3
"""Sync AVC Coders Guild membership to nwp.yml other_coders.

Security: All user-controlled data (usernames, emails) is validated
with strict regex before touching the YAML file. No shell commands
are constructed from user data.
"""
import json, re, sys
from datetime import datetime, timezone
from ruamel.yaml import YAML

USERNAME_RE = re.compile(r'^[a-zA-Z0-9_-]{1,64}$')
EMAIL_RE = re.compile(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$')

ROLE_MAP = {
    'guild_admin': 'core',
    'guild_facilitator': 'contributor',
    'guild_mentor': 'contributor',
    'guild_member': 'newcomer',
}

def sync(members_json: str, config_path: str):
    members = json.loads(members_json)
    yaml = YAML()
    yaml.preserve_quotes = True

    with open(config_path) as f:
        config = yaml.load(f)

    coders = config.setdefault('other_coders', {}).setdefault('coders', {})
    guild_usernames = set()

    for member in members.get('data', []):
        username = member.get('attributes', {}).get('name', '')
        email = member.get('attributes', {}).get('mail', '')
        guild_role = member.get('attributes', {}).get('group_role', 'guild_member')

        # Strict validation — reject anything unexpected
        if not USERNAME_RE.match(username):
            continue
        if email and not EMAIL_RE.match(email):
            continue

        guild_usernames.add(username)
        nwp_role = ROLE_MAP.get(guild_role, 'newcomer')

        if username not in coders:
            coders[username] = {
                'added': datetime.now(timezone.utc).isoformat(),
                'status': 'active',
                'email': email,
                'role': nwp_role,
                'source': 'avc_guild',
            }
        else:
            coders[username]['role'] = nwp_role
            coders[username]['status'] = 'active'

    # Deactivate coders no longer in guild (only those sourced from guild)
    for name, coder in coders.items():
        if coder.get('source') == 'avc_guild' and name not in guild_usernames:
            coder['status'] = 'inactive'

    with open(config_path, 'w') as f:
        yaml.dump(config, f)

if __name__ == '__main__':
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument('--members-json', required=True)
    p.add_argument('--config', required=True)
    args = p.parse_args()
    sync(args.members_json, args.config)
```

**Security properties:**
- **No inbound endpoints.** The NWP server never exposes a webhook URL.
- **No shell injection.** User data never enters shell commands — Python handles all YAML manipulation.
- **Strict input validation.** Usernames must match `^[a-zA-Z0-9_-]{1,64}$`. Emails are regex-validated. Anything else is silently skipped.
- **Source tagging.** Only coders with `source: avc_guild` are auto-managed. Manually-added coders are never touched.
- **Authenticated API calls.** The service account token is stored in `.secrets.yml` and used for bearer auth over HTTPS.
- **Self-healing.** Every poll cycle compares full membership — missed events are automatically corrected.

### 5.7 Role Mapping

| AVC Guild Role | NWP Role | GitLab Access | Capabilities |
|---------------|----------|--------------|-------------|
| `guild_admin` | `core` (40) | Maintainer | merge, release, admin |
| `guild_facilitator` | `contributor` (30) | Developer | push, feature branches, own subdomain |
| `guild_mentor` | `contributor` (30) | Developer | push, feature branches |
| `guild_member` | `newcomer` (0) | Reporter | fork-based contributions only |

### 5.8 Full Authentication Flow: From Guild to Code

```
1. User joins AVC Coders Guild (via AVC website)
   └── Guild role assigned: guild_member

2. Server-side sync (within 5 min):
   └── pl coders sync-guild
       └── Adds user to nwp.yml other_coders (role: newcomer, source: avc_guild)

3. Developer sets up local NWP:
   └── pl auth login
       └── Browser → AVC OAuth2 → Consent → Callback
       └── ID token proves: "I am george, I have guild_member role"
       └── Token stored in ~/nwp/.auth.yml

4. Developer uses authenticated NWP:
   └── pl coder-setup provision george
       └── Checks: george exists in other_coders with source: avc_guild ✓
       └── Checks: local auth matches george ✓
       └── Provisions: DNS delegation, GitLab account, SSH key

5. Token refresh (automatic, periodic):
   └── pl auth refresh
       └── If guild role changed → updates local auth + other_coders
       └── If removed from guild → refresh fails → marks inactive
```

---

## 6. Servers as Infrastructure

### 6.1 The Problem

The Linode server (97.107.137.88 / nwpcode.org) is shared infrastructure that all live sites depend on. Currently its configuration is scattered: `linode.*` in nwp.yml, `email/` at root, nginx configs only on the server itself (not version controlled), SSL/firewall configs untracked.

Additionally, NWP needs to support **multiple servers** — each coder can have their own server (`pl coder-setup provision`), and sites may eventually be distributed across servers.

### 6.2 Solution: `~/nwp/servers/` Directory

Servers get their own top-level directory (parallel to `sites/`), since they are a different kind of entity — infrastructure that sites run on, not projects themselves:

```
~/nwp/
├── sites/                              # Projects (Drupal, Moodle, utility)
│   ├── avc/
│   ├── mt/
│   └── ...
│
├── servers/                            # Infrastructure (one dir per server)
│   ├── nwpcode/                        # Primary production server
│   │   ├── .nwp-server.yml            # Server config
│   │   ├── .git/                       # Own git repo
│   │   ├── nginx/
│   │   │   ├── sites-available/
│   │   │   │   ├── mt.nwpcode.org.conf
│   │   │   │   ├── ss.nwpcode.org.conf
│   │   │   │   └── dir.nwpcode.org.conf
│   │   │   └── snippets/
│   │   ├── email/                      # ← Moved from ~/nwp/email/
│   │   │   ├── setup_email.sh
│   │   │   ├── add_site_email.sh
│   │   │   └── configure_reroute.sh
│   │   ├── ssl/                        # Certbot configs
│   │   ├── security/                   # fail2ban, UFW rules
│   │   ├── scripts/
│   │   │   ├── deploy.sh              # Push configs to server
│   │   │   └── setup.sh               # Initial provisioning
│   │   ├── backups/                    # Server-level backups
│   │   └── docs/
│   │
│   ├── george-dev/                     # A coder's development server
│   │   ├── .nwp-server.yml
│   │   ├── nginx/
│   │   └── scripts/
│   │
│   └── staging/                        # A dedicated staging server
│       ├── .nwp-server.yml
│       └── ...
```

### 6.3 Server Config (`.nwp-server.yml`)

Uses a different filename from `.nwp.yml` to clearly distinguish servers from sites:

```yaml
# ~/nwp/servers/nwpcode/.nwp-server.yml
schema_version: 1
nwp_version_created: "0.30.0"
nwp_version_updated: "0.30.0"

server:
  name: nwpcode
  ip: 97.107.137.88
  domain: nwpcode.org
  ssh_user: gitlab
  ssh_key: ~/.ssh/nwp_nwpcode           # User's ~/.ssh/ — standard location
  linode_id: 12345
  linode_label: nwpcode
  provider: linode
  region: ap-southeast

services:
  nginx: true
  postfix: true
  certbot: true
  fail2ban: true
  ufw: true
  redis: true

# Derived automatically by scanning sites/*/.nwp.yml
# (or listed explicitly for documentation)
hosted_sites:
  - mt.nwpcode.org
  - ss.nwpcode.org
  - dir.nwpcode.org
  - avc.nwpcode.org
  - cathnet.nwpcode.org
  - git.nwpcode.org
```

```yaml
# ~/nwp/servers/george-dev/.nwp-server.yml
schema_version: 1
nwp_version_created: "0.30.0"
nwp_version_updated: "0.30.0"

server:
  name: george-dev
  ip: 192.0.2.50
  domain: george.nwpcode.org
  ssh_user: george
  ssh_key: ~/.ssh/nwp_george_dev
  linode_id: 67890
  linode_label: george-dev
  provisioned_for: george               # Links to other_coders entry
```

**Path resolution:** SSH keys live in the user's `~/.ssh/` directory (standard OpenSSH location, enforced permissions, ssh-agent integration). `pl` just expands `~` and passes the path to `ssh -i`:

```bash
get_ssh_key_path() {
    local server_name="$1"
    local server_dir="$NWP_DIR/servers/$server_name"
    local key_ref
    key_ref=$(yq eval '.server.ssh_key' "$server_dir/.nwp-server.yml")
    # Expand ~ and return absolute path
    echo "${key_ref/#\~/$HOME}"
}
```

**Why keys stay in `~/.ssh/` and not in the server directory:**

SSH keys are user-level credentials, not project artifacts. Keeping them in `~/.ssh/` means OpenSSH enforces `StrictModes` permissions, `ssh-agent` works automatically, and the developer can `ssh nwpcode` directly without NWP-specific tooling. The server directory tracks *configuration* (nginx, email, scripts, server metadata); the credential that unlocks the server is user-scoped.

Backup of SSH keys is the user's responsibility and handled outside NWP (encrypted USB, password manager, hardware token, etc.). F24's backup strategy covers NWP state; it does not touch `~/.ssh/`.

### 6.4 How Sites Reference Servers

Each site's `.nwp.yml` names the server it deploys to:

```yaml
# ~/nwp/sites/mt/.nwp.yml
live:
  server: nwpcode                       # Name matches servers/nwpcode/
  domain: mt.nwpcode.org
  remote_path: /var/www/mt
```

`pl` resolves this by reading `servers/<name>/.nwp-server.yml`:

```bash
resolve_server() {
    local server_name="$1"
    local server_dir="$NWP_DIR/servers/$server_name"
    if [[ -f "$server_dir/.nwp-server.yml" ]]; then
        echo "$server_dir"
        return 0
    fi
    return 1
}

get_server_ip() {
    local server_name="$1"
    local server_dir=$(resolve_server "$server_name")
    yq eval '.server.ip' "$server_dir/.nwp-server.yml"
}

get_ssh_command() {
    local server_name="$1"
    local server_dir=$(resolve_server "$server_name")
    local ip=$(yq eval '.server.ip' "$server_dir/.nwp-server.yml")
    local user=$(yq eval '.server.ssh_user' "$server_dir/.nwp-server.yml")
    local key=$(get_ssh_key_path "$server_name")    # Expands ~ (Section 6.3)
    echo "ssh -i $key $user@$ip"
}
```

### 6.5 Multi-Server Commands

```bash
pl server list                          # Lists all servers in servers/
pl server status nwpcode                # Check server health
pl server status --all                  # Check all servers
pl server deploy nwpcode                # Push configs to nwpcode server
pl server deploy nwpcode --nginx        # Push only nginx configs
pl server deploy nwpcode --email        # Push only email configs
pl server provision george-dev          # Create new server for a coder
pl server backup nwpcode                # Pull server configs as backup
```

### 6.6 Server Discovery: Which Sites Are on Which Server?

`pl` can answer this in two directions:

```bash
# Which server hosts this site?
cd ~/nwp/sites/mt
pl server                               # "nwpcode (97.107.137.88)"

# Which sites are on this server?
pl server sites nwpcode                 # Scans sites/*/.nwp.yml for server: nwpcode
# Output:
#   mt.nwpcode.org    (sites/mt/)
#   ss.nwpcode.org    (sites/ss/)
#   dir.nwpcode.org   (sites/dir1/)
#   avc.nwpcode.org   (sites/avc/)
```

### 6.7 Migration: `linode.*` Section

The `linode.*` section currently in `nwp.yml` maps to `servers/`:

| Old (`nwp.yml`) | New (`servers/`) | Notes |
|-----------------|-----------------|-------|
| `linode.servers.nwpcode.ssh_host` | `servers/nwpcode/.nwp-server.yml` → `server.ip` | |
| `linode.servers.nwpcode.ssh_key` (path) | `servers/nwpcode/.nwp-server.yml` → `server.ssh_key` | **Path passes through unchanged** — key stays in `~/.ssh/` |
| `linode.servers.nwpcode.domain` | `servers/nwpcode/.nwp-server.yml` → `server.domain` | |
| `linode.servers.nwpcode.linode_id` | `servers/nwpcode/.nwp-server.yml` → `server.linode_id` | Most sensitive field |

The migration is a pure YAML restructure. No files move on disk — the SSH key stays wherever it already is (typically `~/.ssh/nwp` or similar), and the config just records that path. Users who want a per-server naming convention can rename their key (e.g., `~/.ssh/nwp` → `~/.ssh/nwp_nwpcode`) at their own pace.

```bash
migrate_server_ssh_key_path() {
    local server_name="$1"
    local old_key_path
    old_key_path=$(yq eval ".linode.servers.$server_name.ssh_key" "$NWP_DIR/nwp.yml")

    # Old config may store relative paths (resolved against $NWP_DIR).
    # Convert these to absolute or ~-prefixed so the new location is portable.
    if [[ "$old_key_path" != /* ]] && [[ "$old_key_path" != ~* ]]; then
        old_key_path="$NWP_DIR/$old_key_path"
    fi

    local server_dir="$NWP_DIR/servers/$server_name"
    yq eval -i ".server.ssh_key = \"$old_key_path\"" "$server_dir/.nwp-server.yml"

    log_success "Migrated SSH key reference for $server_name → $old_key_path"
}
```

During transition, `pl` checks both locations:

```bash
get_server_config() {
    local server_name="$1" field="$2"
    # Try new location
    if [[ -f "$NWP_DIR/servers/$server_name/.nwp-server.yml" ]]; then
        yq eval ".server.$field" "$NWP_DIR/servers/$server_name/.nwp-server.yml"
        return
    fi
    # Fall back to old nwp.yml
    yq eval ".linode.servers.$server_name.$field" "$NWP_DIR/nwp.yml" 2>/dev/null
}
```

### 6.8 NWP `.gitignore` for Servers

Like sites, each server directory is its own git repo. The parent NWP repo ignores the contents:

```gitignore
# ~/nwp/.gitignore
servers/*/
```

The server's own `.gitignore` protects the plaintext `.nwp-server.yml` while permitting nginx, email, and script files to be tracked:

```gitignore
# servers/nwpcode/.gitignore
.nwp-server.yml                 # Plaintext — gitignored; SOPS-encrypted version committed (see F24 §2)
backups/                        # Large
```

SSH keys are not in this directory — they live in `~/.ssh/` and are out of scope for the server repo entirely.

---

## 7. Additional Improvements

### 7.1 `pl` Command Improvements

**Context-aware commands** — when run from inside a site directory, no site name needed:

```bash
cd ~/nwp/sites/mt
pl backup            # Backs up MT (detected from .nwp.yml)
pl status            # Shows MT status
pl deploy            # Deploys MT
pl test              # Runs MT tests
```

**Cross-site aggregation:**

```bash
pl status --all      # Scans sites/*/.nwp.yml, shows all
pl backup --all      # Backs up all sites
pl proposals         # Aggregates docs/proposals/ + sites/*/docs/proposals/
```

### 7.2 Site Templates for New Projects

When running `pl install`, the tool should generate a complete self-contained site structure:

```bash
pl install mt my-parish-times
# Creates:
#   sites/my-parish-times/
#   sites/my-parish-times/.nwp.yml
#   sites/my-parish-times/.gitignore
#   sites/my-parish-times/backups/
#   sites/my-parish-times/docs/
#   sites/my-parish-times/web/        (Drupal webroot)
#   sites/my-parish-times/.ddev/
#   Initializes git repo
#   Registers in nwp.yml sites section (for backwards compat) or not
```

### 7.3 `pl doctor` Site Health Checks

Extend the doctor command to verify site self-containment:

```bash
pl doctor
# Checks:
# ✓ All sites have .nwp.yml
# ✓ All sites have backups/ directory
# ✗ modules/mass_times/ still exists at root (should be in sites/mt/)
# ✗ mt/ pipeline still at root (should be in sites/mt/pipeline/)
# ✓ No project-specific settings in global nwp.yml
# ✓ All site .gitignore files exclude backups/, .nwp.local.yml
```

### 7.4 Unified Proposal Viewer

```bash
pl proposals                    # Lists all proposals across NWP + all sites
pl proposals --site=mt          # Lists MT proposals only
pl proposals --status=proposed  # Filter by status
```

Scans:
- `~/nwp/docs/proposals/*.md`
- `~/nwp/sites/*/docs/proposals/*.md`

### 7.5 Secrets Per Site

Each site can have its own `.secrets.yml` for project-specific credentials. If the site has its own git repo, `.secrets.yml` is gitignored there; in either case the file is excluded from F24 restic backups in plaintext (and included only in SOPS-encrypted form):

```yaml
# ~/nwp/sites/mt/.secrets.yml (gitignored)
mass_times:
  claude_api_key: sk-ant-...
  google_places_api_key: AIza...
  drupal_api_password: ...
```

Global secrets (Linode, Cloudflare, GitLab tokens) remain in `~/nwp/.secrets.yml`.

### 7.6 FIN as a Proper Site

The financial monitor becomes `sites/fin/` with type `utility`:

```yaml
# ~/nwp/sites/fin/.nwp.yml
project:
  name: fin
  type: utility                 # No Drupal/Moodle — standalone scripts
  environment: production
  purpose: indefinite

live:
  enabled: true
  deploy_to: gitlab@97.107.137.88:~/fin/
  schedule: "*/30 * * * *"      # Run every 30 minutes

email:
  alert_to: admin@nwpcode.org
```

---

## 8. Implementation Plan

### Phase 1: Per-Site `.nwp.yml` Generation + Schema Framework (8-10 hours)

**Goal:** Create `.nwp.yml` files for all existing sites without moving anything, and establish the schema versioning infrastructure.

1. Write a script that extracts per-site data from `nwp.yml` into `sites/<site>/.nwp.yml`
2. For each site in `nwp.yml`, generate:
   - `schema_version: 1`, `nwp_version_created`, `nwp_version_updated`
   - `project.*` from site registration data
   - `live.*` from site live deployment data
   - Project-specific settings (e.g., `mass_times.*` for MT)
3. For sites that have their own git repo (`avc`, `ss`), add `.nwp.local.yml` and `backups/` to that repo's `.gitignore`. Experimental sites have no `.gitignore` to update.
4. Test that `pl` can read config from both locations
5. **Implement schema migration framework** (Section 3.7):
   - Create `lib/migrations/site/`, `lib/migrations/global/`, `lib/migrations/server/` directories
   - Implement `migrate_site()` runner with pre-migration backups
   - Implement `pl site migrate <site>` and `pl site migrate --all` commands
   - Add `001-initial.sh` baseline migration
   - Add schema version checks to `pl doctor`
   - Add stale-schema warnings/refusals to `pl` read/write commands

**No behavior changes for existing sites.** Just adds `.nwp.yml` files and migration infrastructure.

### Phase 2: Move Modules Into Sites (8-10 hours)

**Goal:** Each module lives inside its site.

| Move | From | To |
|------|------|-----|
| mass_times | `modules/mass_times/` | `sites/mt/web/modules/custom/mass_times/` |
| cathnet | `modules/cathnet/` | `sites/cathnet/web/modules/custom/cathnet/` |
| dir_search | `modules/dir_search/` | `sites/dir1/web/modules/custom/dir_search/` |
| avc_moodle | `modules/avc_moodle/` | `sites/avc/html/modules/custom/avc_moodle/` |
| avc_oauth2 | `moodle_plugins/auth/avc_oauth2/` | `sites/ss/auth/avc_oauth2/` |

After moving, update any deployment scripts that reference old paths. Remove empty `modules/` and `moodle_plugins/` directories.

### Phase 3: Move Pipelines Into Sites (6-8 hours)

**Goal:** Python pipelines live inside their sites.

| Move | From | To |
|------|------|-----|
| MT scraper | `mt/` | `sites/mt/pipeline/` |
| CathNet NLP | `cathnet/` | `sites/cathnet/pipeline/` |
| FIN monitor | `fin/` | `sites/fin/pipeline/` (new site) |

Update:
- `deploy-mass-times.sh` → reference `sites/mt/pipeline/`
- `mass-times.conf` generation → read from `sites/mt/.nwp.yml`
- `deploy-fin-monitor.sh` → reference `sites/fin/pipeline/`
- Python import paths (if any reference absolute paths)

Create `sites/fin/` as a new site with `.nwp.yml`.

### Phase 4: Move Backups Into Sites (4-6 hours)

**Goal:** Each site's backups live inside the site directory.

1. For each site, move `sitebackups/<site>/` → `sites/<site>/backups/`
2. Update `backup.sh` and `restore.sh` to use `get_backup_dir()`:
   ```bash
   get_backup_dir() {
       local site_dir="$1"
       echo "$site_dir/backups"
   }
   ```
3. For tracked sites (`avc`, `ss`), add `backups/` to that repo's `.gitignore`. Untracked sites need no change.
4. Remove empty `sitebackups/` directory

### Phase 5: Move Proposals Into Sites (2-3 hours)

**Goal:** Project-specific proposals live inside their sites.

| Proposals | Destination |
|-----------|------------|
| F16-mass-times-scraper.md, F17-mt-site-creation.md | `sites/mt/docs/proposals/` |
| F18-cathnet-acmc.md, F19-*.md, F21-*.md | `sites/cathnet/docs/proposals/` |
| F20-ss-faith-formation-app.md | `sites/ss/docs/proposals/` |

Keep NWP-level proposals (F03-F15, F22, F23, etc.) in `~/nwp/docs/proposals/`.

### Phase 6: Update Script Path Resolution (16-20 hours)

**Goal:** All scripts use the new path patterns.

This is the largest phase. Replace 150+ instances of `$PROJECT_ROOT/sites/$SITENAME` with `resolve_project()` which returns the full path. Key changes:

```bash
# OLD pattern:
site_path="$PROJECT_ROOT/sites/$SITENAME"
backup_dir="$PROJECT_ROOT/sitebackups/$SITENAME"

# NEW pattern:
site_path=$(resolve_project "$SITENAME")
backup_dir="$site_path/backups"
```

**Scripts to update** (grouped by priority):

**Critical path (must change):**
- `pl` — site resolution
- `lib/common.sh` — `get_site_path()`, `list_sites()`
- `lib/yaml-write.sh` — config file resolution, `resolve_config()`
- `lib/install-common.sh` — site creation path
- `scripts/commands/install.sh` — creates sites with `.nwp.yml`
- `scripts/commands/backup.sh` — uses `get_backup_dir()`
- `scripts/commands/restore.sh` — same
- `scripts/commands/status.sh` — scans `sites/*/.nwp.yml`
- `scripts/commands/delete.sh` — cleanup

**Deployment (must change):**
- `scripts/commands/dev2stg.sh`, `stg2live.sh`, `live2stg.sh`, `stg2prod.sh`

**Verification (must change):**
- `lib/verify-runner.sh`, `verify-scenarios.sh`, `verify-checkpoint.sh`
- `lib/verify-cross-validate.sh` — remove hard-coded `avc` reference
- `scripts/commands/verify.sh`

**Integration (minor updates):**
- `scripts/commands/todo.sh`, `security.sh`, `email.sh`, `modify.sh`, `sync.sh`
- `lib/avc-moodle.sh`, `frontend.sh`, `ddev-generate.sh`, `env-generate.sh`
- `lib/todo-checks.sh`, `remote.sh`, `safe-ops.sh`

### Phase 7: Parent `.gitignore` + Per-Site Repo Policy (2-4 hours)

**Goal:** Stop the parent NWP repo from tracking site contents. Document which sites get their own git repo and which don't.

**Policy (decided 2026-04-07):**

| Category | Has own git repo? | Example | Rationale |
|----------|-------------------|---------|-----------|
| **Production** | Yes — independent repo | `avc`, `ss` | Deployed to live servers; history matters; already have repos |
| **Experimental** | No — filesystem only | `cathnet`, `cccrdf`, `dir1`, `mt` | Scratch work; churn is high; version control would be noise; backed up via F24 |
| **Verify test** | No — generated | `verify-test-*` | Created and destroyed by test runs |
| **Generated scaffolds** | No | `tmp`, `latest` | Build artifacts |

**Steps:**

1. **Update NWP `.gitignore`** to ignore all `sites/*/` contents. The parent NWP repo tracks the directory existence (`sites/.gitkeep`) but not what's inside any site:
   ```gitignore
   # ~/nwp/.gitignore
   /sites/*
   !/sites/.gitkeep
   ```

2. **Confirm production sites keep their existing repos.** No new repos are created in this phase. `avc/` and `ss/` already have `.git/` — leave them alone.

3. **Experimental sites stay untracked.** `cathnet`, `cccrdf`, `dir1`, `mt` do not get `git init`. They are protected solely by F24's backup layer (restic snapshots to an attached SSD).

4. **`pl install` default:** when creating a new site, `pl install <recipe> <name>` does NOT init a git repo by default. An opt-in flag `--with-git [--remote <url>]` initializes one and optionally sets a remote. This keeps experimental sites friction-free.

5. **No history split.** Earlier drafts of this proposal contemplated using `git filter-repo` to extract historical commits per-site from the NWP repo. That plan is dropped — the production sites (avc, ss) already have their own long-lived histories, and the experimental sites don't need history at all.

### Phase 8: Server Infrastructure Migration (8-10 hours)

**Goal:** Server configs tracked in `servers/` directory.

1. Create `servers/nwpcode/` directory structure
2. Move `email/` → `servers/nwpcode/email/`
3. Move `linode/` → `servers/nwpcode/linode/`
4. Create `servers/nwpcode/.nwp-server.yml` from `nwp.yml` `linode.*` section
5. Run `migrate_server_ssh_key_path()` to carry the existing `ssh_key` path through to the new config (Section 6.7) — the key file itself is not moved; it stays in `~/.ssh/`
6. Export existing nginx configs from server into `servers/nwpcode/nginx/`
7. Implement `pl server list/status/deploy` commands (Section 6.5)
8. Update `stg2live.sh`, `live2stg.sh` to resolve server via `.nwp-server.yml`
9. Update site `.nwp.yml` files: replace `server_ip` with `server: nwpcode`
10. Init git repo, push to `git.nwpcode.org:nwp/nwpcode-server.git`

### Phase 9: OAuth2 Authentication + Guild Sync (10-14 hours)

**Goal:** Automated developer authentication and coder provisioning.

1. Implement `avc_oidc_claims` Drupal module on AVC site (Section 5.5)
2. Register NWP CLI as OAuth2 client in AVC Simple OAuth settings
3. Implement `pl auth login/status/logout/refresh` commands (Section 5.4)
4. Implement `scripts/helpers/sync-guild-members.py` pull-based sync (Section 5.6)
5. Add `sync-guild` subcommand to `scripts/commands/coders.sh`
6. Set up server cron for `pl coders sync-guild` (every 5 min)
7. Test full flow: guild join → sync → `pl auth login` → provision

### Phase 10: Verification + Documentation (6-8 hours)

**Goal:** Full system verification and documentation updates.

1. Update `pl doctor` for site self-containment checks (Section 7.3)
2. Implement `pl proposals` aggregation (Section 7.4)
3. Run `pl verify --run --depth=thorough`
4. Update documentation: README, CLAUDE.md, all affected guides
5. Verify all 440+ tests pass
6. Update ROADMAP.md and CHANGELOG.md

---

## 9. Affected Scripts — Complete Inventory

### 9.1 Core Path Resolution (HIGH impact)

| Script | Changes |
|--------|---------|
| `pl` | `find_project_from_cwd()`, `resolve_project()` |
| `lib/common.sh` | `get_site_path()` → `resolve_project()`, `list_sites()` → `discover_sites()` |
| `lib/yaml-write.sh` | `resolve_config()` layered reader, all `yaml_*_site*()` functions |
| `lib/install-common.sh` | Site creation path, `get_settings_value()` |
| `lib/install-drupal.sh` | Site/webroot path resolution |
| `lib/install-moodle.sh` | Site path resolution |

### 9.2 Commands (MEDIUM impact)

| Script | Changes |
|--------|---------|
| `install.sh` | Generate `.nwp.yml`, `.gitignore`, `backups/`, `docs/` |
| `delete.sh` | Resolve project path |
| `backup.sh` | `get_backup_dir()` → `$site_path/backups` |
| `restore.sh` | Same |
| `status.sh` | Scan `sites/*/.nwp.yml` |
| `dev2stg.sh` | Resolve source/target paths |
| `stg2live.sh` | Read live config from `.nwp.yml` |
| `live2stg.sh`, `stg2prod.sh` | Same |
| `import.sh` | Register with `.nwp.yml` |
| `modify.sh` | Write to `.nwp.yml` |
| `verify.sh` | Test site paths |

### 9.3 New Scripts / Modified

| Script | Purpose |
|--------|---------|
| `scripts/commands/config.sh` | `pl config show` — resolved config viewer |
| `scripts/commands/proposals.sh` | `pl proposals` — aggregate proposals |
| `scripts/helpers/sync-guild-members.py` | Pull-based AVC guild sync |
| `scripts/commands/auth.sh` | `pl auth login/status/logout/refresh` |
| `scripts/commands/server.sh` | `pl server list/status/deploy/provision` |
| `scripts/commands/migrate.sh` | Migration wizard for moving to new layout |

---

## 10. Project Type Matrix

### 10.1 Drupal Site (`sites/avc/`, `sites/dir1/`)

```
sites/<name>/
├── .nwp.yml
├── .nwp.local.yml              (gitignored)
├── .gitignore
├── .git/
├── html/ or web/               (webroot)
│   ├── modules/custom/         (project-specific, may have nested .git)
│   ├── profiles/custom/        (may have nested .git)
│   ├── themes/custom/
│   └── sites/default/settings.php
├── .ddev/config.yaml
├── composer.json
├── backups/                    (gitignored)
├── docs/proposals/
├── private/
└── .env
```

### 10.2 Drupal + Pipeline (`sites/mt/`, `sites/cathnet/`)

```
sites/<name>/
├── .nwp.yml                    (includes pipeline settings)
├── .git/
├── web/
│   └── modules/custom/<name>/
├── pipeline/                   (Python pipeline)
│   ├── src/
│   ├── data/
│   ├── templates/
│   ├── tests/
│   ├── requirements.txt
│   └── venv/                   (gitignored)
├── scripts/
│   ├── deploy-pipeline.sh
│   └── setup-pipeline.sh
├── .ddev/
├── backups/
├── docs/proposals/
└── composer.json
```

### 10.3 Moodle Site (`sites/ss/`)

```
sites/ss/
├── .nwp.yml
├── .git/
├── auth/avc_oauth2/            (custom auth plugin)
├── course/format/tabbed/       (custom course format)
├── faith_formation/            (Flutter app — may have nested .git)
├── moodledata/                 (gitignored, or symlink)
├── backups/
├── docs/proposals/
└── config.php
```

### 10.4 Utility Site (`sites/fin/`)

```
sites/fin/
├── .nwp.yml                    (type: utility)
├── .git/
├── pipeline/
│   ├── fin-monitor.sh
│   ├── deploy-fin-monitor.sh
│   ├── setup-fin-monitor.sh
│   └── requirements.txt
├── backups/
└── docs/
```

---

## 11. Migration Path for Each Project

| Project | Category | Steps | Notes |
|---------|----------|-------|-------|
| **AVC** | Production | 1. Create `.nwp.yml` 2. Move `modules/avc_moodle/` → `html/modules/custom/` 3. Move backups | Already has own git repo — leave it |
| **SS** | Production | 1. Create `.nwp.yml` 2. Move `moodle_plugins/auth/avc_oauth2/` → `auth/avc_oauth2/` 3. Move proposals 4. Move backups | Already has own git repo; Faith Formation already in place |
| **MT** | Experimental | 1. Create `.nwp.yml` 2. Move `modules/mass_times/` → `web/modules/custom/` 3. Move `mt/` → `pipeline/` 4. Move backups 5. Move proposals | No git init — backed up via F24 |
| **CathNet** | Experimental | Same pattern as MT | 7.8GB pipeline data; no git init |
| **DIR** | Experimental | 1. Create `.nwp.yml` 2. Move `modules/dir_search/` → `web/modules/custom/` 3. Move backups | Simple module move; no git init |
| **CCCRDF** | Experimental | 1. Create `.nwp.yml` | Minimal changes; no git init |
| **FIN** | Experimental | 1. Create `sites/fin/` 2. Move `fin/` → `sites/fin/pipeline/` 3. Create `.nwp.yml` | New site; no git init |
| **Server (nwpcode)** | Infrastructure | 1. Create `servers/nwpcode/` 2. Move `email/` → `servers/nwpcode/email/` 3. Move `linode/` → `servers/nwpcode/linode/` 4. Create `.nwp-server.yml` from `nwp.yml` 5. Migrate `ssh_key` path (key stays in `~/.ssh/`) 6. Export nginx configs from server 7. Init git | New directory; pull configs from live server |

---

## 12. Risk Assessment

### High Risk

| Risk | Mitigation |
|------|-----------|
| 150+ path reference changes | Mechanical, consistent pattern; grep-verifiable; can be done incrementally |
| Backup path migration | Move files physically; update scripts; `pl doctor` verifies |
| Pipeline import paths may break | Python relative imports should work; test each pipeline after move |

### Medium Risk

| Risk | Mitigation |
|------|-----------|
| DDEV configuration | DDEV uses relative paths — should work after move |
| Deployment scripts hardcode old paths | Update and test one project at a time |
| Large pipeline data for CathNet (7.8GB) | Excluded from F24 restic include list; site is untracked (experimental) |

### Low Risk

| Risk | Mitigation |
|------|-----------|
| Cross-project refs (AVC↔Moodle) | Communicate by URL, not filesystem |
| Remote server paths (`/var/www/`) | Independent of local layout |
| NWP test sites | Still created at `sites/verify-test-*`, managed by NWP |

---

## 13. Success Criteria

- [ ] Every site has a `.nwp.yml` file with `schema_version`, `nwp_version_created`, `nwp_version_updated`
- [ ] `pl site migrate <site>` upgrades old-schema configs to current version
- [ ] `pl site migrate --all` bulk-migrates every site
- [ ] Migration framework supports independent version counters for site, global, and server schemas
- [ ] Pre-migration backups (`.pre-migration-*.bak`) are created before any transformation
- [ ] `pl doctor` reports stale schemas; write commands refuse until migrated
- [ ] An old NWP 0.29 site backup can be dropped into a new NWP install and migrated cleanly
- [ ] No project-specific code exists at NWP root (no `modules/`, `mt/`, `cathnet/`, `fin/`, `moodle_plugins/`)
- [ ] No project-specific settings in global `nwp.yml` (no `settings.mass_times`, no `sites.*`)
- [ ] Each site's backups are in `sites/<site>/backups/`
- [ ] Each site's proposals are in `sites/<site>/docs/proposals/`
- [ ] `cd ~/nwp/sites/mt && pl backup` works (context-aware)
- [ ] `pl status --all` discovers all sites via `sites/*/.nwp.yml`
- [ ] `pl proposals` aggregates proposals from NWP + all sites
- [ ] Production sites (`avc`, `ss`) retain their existing independent git repos; experimental sites remain untracked and are protected by F24 backups
- [ ] FIN monitor exists as `sites/fin/` with `.nwp.yml`
- [ ] AVC Coders Guild changes propagate to `nwp.yml` `other_coders` via pull-based sync
- [ ] `pl auth login` authenticates developer via OAuth2 PKCE against AVC site
- [ ] `servers/nwpcode/` contains all server infrastructure (nginx, email, SSL, security)
- [ ] `pl server list` discovers all servers; `pl server status` reports health
- [ ] Sites reference servers by name (`server: nwpcode`), not by hardcoded IP
- [ ] `pl doctor` reports all sites as self-contained
- [ ] All 440+ verification tests pass
- [ ] Hard-coded `avc` reference in `verify-cross-validate.sh` removed
- [ ] Everything lives within `~/nwp/` — no `~/.nwp/` or external directories

---

## 14. Timeline

| Phase | Description | Effort | Dependencies |
|-------|-------------|--------|-------------|
| 1 | Per-site `.nwp.yml` generation + schema framework | 8-10h | None |
| 2 | Move modules into sites | 8-10h | Phase 1 |
| 3 | Move pipelines into sites | 6-8h | Phase 1 |
| 4 | Move backups into sites | 4-6h | Phase 1 |
| 5 | Move proposals into sites | 2-3h | Phase 1 |
| 6 | Update script path resolution | 16-20h | Phases 2-5 |
| 7 | Parent `.gitignore` + per-site repo policy | 2-4h | Phase 6 |
| 8 | Server infrastructure migration | 8-10h | Phase 1 |
| 9 | OAuth2 authentication + guild sync | 10-14h | Phase 7 |
| 10 | Verification + documentation | 6-8h | Phases 7-9 |
| **Total** | | **72-97h** | |

Phases 2, 3, 4, 5, 8 can run in parallel after Phase 1.

---

## 15. Worth-It Evaluation

### Benefits

| Benefit | Impact |
|---------|--------|
| Self-contained sites | Move/share/backup a single folder and get everything |
| Clean NWP root | Tool code clearly separated from project code |
| One backup target | `~/nwp/` contains everything — restic backs up all projects + tool |
| Per-site repo *when needed* | Production sites (avc, ss) keep their independent repos; experimental sites stay friction-free |
| Nested git flexibility | Production sites can track their own canonical version without polluting NWP history |
| AVC-driven provisioning | Joining the Coders Guild auto-provisions NWP access |
| Per-site proposals | Project documentation travels with the project |
| Multi-server support | Each coder can have their own server; sites can migrate between servers |
| Server configs version-controlled | nginx, email, SSL, security configs tracked in git, not just on the server |

### Costs

| Cost | Impact |
|------|--------|
| 72-97 hours of development | Significant but predictable effort |
| Initial AVC OIDC module (~20 lines PHP) | Small custom development |
| Transition period | Expand-migrate-contract handles this gracefully |

### Verdict

**Strongly recommended.** This restructuring achieves the goal of "one folder to back up" while making each project self-contained and independently version-controlled. The mechanical nature of the path changes makes the effort predictable. The AVC Coders Guild integration closes the gap between community membership and development access, turning what is currently a manual process into an automated pipeline.
