# F23: Separate NWP Core from Project Sites (SUPERSEDED v1)

> **SUPERSEDED:** This is the original v1 draft of F23.
> The active proposal is `docs/proposals/F23-project-separation.md` (v2),
> which expanded the plan to 10 phases and is now IMPLEMENTED through phase 8/10.
> Retained here for historical reference only.

**Status:** SUPERSEDED (by F23 v2, 2026-04-06)
**Created:** 2026-04-06
**Author:** Rob Zaar, Claude Opus 4.6
**Priority:** High (architectural)
**Depends On:** None
**Breaking Changes:** Yes (managed via expand-migrate-contract)
**Estimated Effort:** 80-120 hours across 7 phases

---

## 1. Executive Summary

### 1.1 Problem Statement

NWP currently operates as a monorepo where the core tooling (`pl` CLI, `lib/`, `scripts/`, `recipes/`) and all project-specific code (Drupal sites, Moodle sites, Python pipelines, Flutter apps, custom modules) live in a single git repository. This creates several problems:

1. **Tangled history.** Commits to the mass times Python scraper, the CathNet NLP pipeline, the Faith Formation Flutter app, and NWP core infrastructure are all interleaved in one git log. There is no way to see the history of a single project.

2. **Monolithic configuration.** A single `nwp.yml` file contains global settings, recipe definitions, site registrations, server configs, coder profiles, and per-project settings (mass_times, cathnet, etc.). Every project shares one config file.

3. **Deployment coupling.** Deploying changes to the mass times scraper requires working in the same repo as NWP core. A contributor working on CathNet has access to (and could accidentally modify) AVC deployment scripts.

4. **Git bloat.** The repo contains 31 site directories, many with full Drupal/Moodle codebases, vendor directories, and database backups. The `sites/` directory dominates the repo.

5. **No per-project access control.** A contributor granted access to one project has access to everything: all sites, all secrets, all infrastructure scripts.

6. **Project-specific code at root level.** The `mt/`, `cathnet/`, `fin/`, `email/`, `moodle_plugins/` directories at the NWP root are project-specific but live alongside core tooling, blurring the boundary between "NWP the tool" and "things managed by NWP."

### 1.2 Proposed Solution

Restructure NWP into a **core tool + independent project repos** architecture, following the pattern used by DDEV, Lando, Terraform, and Ansible:

- **NWP Core** becomes a standalone tool repo containing only `pl`, `lib/`, `scripts/`, `recipes/`, `templates/`, `docs/`, and `example.nwp.yml`
- **Each project** becomes its own git repo with its own `.nwp.yml` config file
- **The `pl` CLI** discovers projects via a hybrid of convention (marker file in current directory) and registry (`~/.nwp/projects.yml`)
- **Configuration** uses a layered override: global defaults -> project config -> local overrides -> CLI flags
- **Migration** follows the expand-migrate-contract pattern so nothing breaks during transition

### 1.3 Core Design Principles

1. **Tool and projects are separate concerns.** NWP is a deployment/hosting tool. The sites it manages are its users, not its source code.
2. **Convention over configuration.** A `.nwp.yml` file in a directory marks it as an NWP project, just as `.ddev/config.yaml` marks a DDEV project.
3. **Backwards compatible during transition.** The old `sites/` layout continues to work throughout migration. No "big bang" cutover.
4. **Each project is self-contained.** A project repo contains everything needed to install, develop, deploy, and back up that project.
5. **Shared code is distributed, not embedded.** Shared Drupal modules become Composer packages or separate repos, not directories in the NWP monorepo.

---

## 2. Current State Analysis

### 2.1 Repository Inventory

The NWP repo at `/home/rob/nwp/` currently contains:

| Category | Contents | Belongs To |
|----------|----------|-----------|
| **NWP Core** | `pl`, `lib/` (60+ scripts), `scripts/commands/` (57 scripts), `recipes/`, `templates/`, `docs/`, `tests/` | NWP tool |
| **Config** | `nwp.yml`, `example.nwp.yml`, `.secrets.yml`, `.secrets.data.yml` | NWP tool + all projects |
| **Drupal sites** | `sites/avc/`, `sites/dir1/`, `sites/mt/`, `sites/cathnet/`, `sites/cccrdf/` + staging variants | Individual projects |
| **Moodle site** | `sites/ss/`, `sites/ss_moodledata/` | SS project |
| **Test sites** | `sites/verify-test-*` (12+ directories) | NWP tool |
| **Drupal modules** | `modules/mass_times/`, `modules/cathnet/`, `modules/dir_search/`, `modules/avc_moodle/` | Individual projects |
| **Python pipelines** | `mt/` (mass times), `cathnet/` (NLP) | Individual projects |
| **Flutter app** | `sites/ss/faith_formation/` | SS/Faith Formation project |
| **Moodle plugins** | `moodle_plugins/auth/avc_oauth2/` | AVC+SS projects |
| **Utilities** | `fin/` (financial monitor), `email/` (email config) | Shared infrastructure |
| **Backups** | `sitebackups/` | Per-project data |

### 2.2 Configuration Coupling (nwp.yml)

The single `nwp.yml` currently holds 9 major sections:

| Section | Scope | Separable? |
|---------|-------|-----------|
| `settings.license` | Global | Global config |
| `settings.timezone` | Global | Global config |
| `settings.email` | Global | Global config |
| `settings.php`, `settings.database` | Global defaults | Global config |
| `settings.claude` | Global | Global config |
| `settings.mass_times` | MT project only | Per-project config |
| `settings.todo` | Global | Global config |
| `settings.verification` | Global | Global config |
| `settings.seo` | Global | Global config |
| `recipes.*` | Global templates | Global config |
| `sites.*` | Per-project | Per-project config |
| `other_coders` | Global | Global config |
| `linode.servers` | Global infrastructure | Global config |
| `import_defaults` | Global | Global config |

**Key finding:** Most settings are genuinely global (NWP tool config). Only `settings.mass_times`, `settings.cathnet` (future), and the `sites.*` entries are project-specific.

### 2.3 Script Coupling Analysis

**150+ locations** in scripts use the pattern `$PROJECT_ROOT/sites/$SITENAME`. Key functions:

| Function | Location | Purpose |
|----------|----------|---------|
| `get_site_path()` | lib/verify-runner.sh, lib/common.sh | Resolve site directory |
| `list_sites()` | lib/common.sh, scripts/commands/status.sh | List all registered sites |
| `yaml_get_all_sites()` | lib/yaml-write.sh | Get sites from nwp.yml |
| `yaml_add_site()` | lib/yaml-write.sh | Register new site |
| `yaml_remove_site()` | lib/yaml-write.sh | Unregister site |
| `get_site_field()` | lib/yaml-write.sh | Read per-site config |
| `validate_sitename()` | lib/common.sh | Validate site name |

**Critical path resolution pattern** (used everywhere):
```bash
site_path="$PROJECT_ROOT/sites/$SITENAME"
```

**Backup path pattern:**
```bash
backup_dir="$PROJECT_ROOT/sitebackups/$SITENAME"
```

**Only one hard-coded site name:** `avc` in `lib/verify-cross-validate.sh` (3 locations).

### 2.4 Project Independence Assessment

| Project | Own Git? | Own Build? | NWP Config Deps | Could Be Independent? |
|---------|----------|-----------|-----------------|----------------------|
| AVC (Drupal) | Yes (git.nwpcode.org:nwp/avc-project) | Composer | Recipe `avc`, site entry | Yes - already has own repo |
| DIR (Drupal) | No | Composer | Recipe `d`, site entry | Yes |
| MT (Drupal + Python) | No | Composer + pip | Recipe `mt`, `settings.mass_times`, site entry | Yes |
| CathNet (Drupal + Python) | No | Composer + pip | Recipe `d`, site entry | Yes |
| SS (Moodle) | Yes (tracks upstream) | Moodle core | Recipe `m`, site entry | Yes |
| Faith Formation (Flutter) | No | Flutter/Dart | None | Already independent |
| FIN Monitor | No | pip | `settings.email`, `linode.servers` | Yes, minimal config |

### 2.5 Cross-Project Dependencies

```
AVC (Drupal) <──OAuth2 SSO──> SS (Moodle)
     │                              │
     ├── avc_moodle module          ├── auth/avc_oauth2 plugin
     ├── Role sync via API          ├── Badge/course display
     └── Email reply system         └── Moodle Web Services
```

No other cross-project dependencies exist. MT, CathNet, DIR, and FIN are fully independent of each other.

---

## 3. Target Architecture

### 3.1 Overview

```
~/.nwp/                              # NWP global config (user-level)
    config.yml                       # Global settings (email, timezone, tokens, etc.)
    projects.yml                     # Registry of known project paths
    secrets.yml                      # Infrastructure secrets (Linode, Cloudflare, etc.)
    secrets.data.yml                 # Data secrets (production credentials)

/opt/nwp/  (or ~/nwp-core/)         # NWP Core Tool (its own git repo)
    pl                               # CLI entry point (on PATH via symlink)
    lib/                             # 60+ shared bash libraries
    scripts/commands/                # 57 command scripts
    recipes/                         # Recipe definitions (d, avc, os, m, gitlab, pod, mt)
    templates/                       # DDEV, env, docker templates
    docs/                            # Tool documentation & proposals
    tests/                           # Tool-level tests
    example.config.yml               # Template for ~/.nwp/config.yml
    CLAUDE.md
    CHANGELOG.md

~/projects/avc/                      # AVC Project (its own git repo)
    .nwp.yml                         # Project-level NWP config
    .nwp.local.yml                   # Per-developer overrides (gitignored)
    html/                            # Drupal webroot
    .ddev/                           # DDEV config
    modules/custom/avc_moodle/       # Project-specific modules
    composer.json
    backups/                         # Project-local backups

~/projects/mt/                       # Mass Times Project (its own git repo)
    .nwp.yml                         # Project config (recipe, domain, scraper settings)
    .nwp.local.yml                   # Per-developer overrides (gitignored)
    web/                             # Drupal webroot
    .ddev/                           # DDEV config
    modules/custom/mass_times/       # Drupal module
    pipeline/                        # Python scraper (was mt/src/)
    backups/                         # Project-local backups
    composer.json

~/projects/ss/                       # Moodle Project (its own git repo)
    .nwp.yml                         # Project config
    config.php                       # Moodle config
    moodledata/                      # Moodle data (or external)
    auth/avc_oauth2/                 # OAuth plugin
    faith_formation/                 # Flutter app (subdirectory or submodule)

~/projects/cathnet/                  # CathNet Project (its own git repo)
    .nwp.yml                         # Project config
    web/                             # Drupal webroot
    modules/custom/cathnet/          # Drupal module
    pipeline/                        # Python NLP pipeline (was cathnet/)
    backups/
```

### 3.2 Configuration Architecture

#### Layer 1: Global Defaults (`~/.nwp/config.yml`)

Contains settings that apply to all projects for this user:

```yaml
# ~/.nwp/config.yml
nwp_version: 0.30.0
nwp_path: /opt/nwp                    # Where NWP core is installed

settings:
  timezone: Australia/Melbourne
  email:
    domain: nwpcode.org
    admin_email: admin@nwpcode.org
    auto_configure: true
  php: "8.3"
  database: mariadb
  frontend:
    node_version: "20"
    build_tool: vite
    package_manager: npm
  seo:
    staging_noindex: true
    staging_robots_block: true
  verification:
    enabled: true
  todo:
    enabled: true

other_coders:
  nameservers: [...]
  coders:
    george: { ... }

linode:
  servers:
    nwpcode:
      ssh_host: 97.107.137.88
      ssh_key: ~/.ssh/nwp
      label: nwpcode
      domain: nwpcode.org

recipes:
  d:
    type: drupal
    source: "drupal/recommended-project:^10"
    webroot: web
    profile: standard
    # ... (all current recipe definitions)
  avc: { ... }
  os: { ... }
  m: { ... }
  mt: { ... }
  gitlab: { ... }
  pod: { ... }
```

#### Layer 2: Per-Project Config (`.nwp.yml` in project root)

Contains project-specific settings:

```yaml
# ~/projects/mt/.nwp.yml
project:
  name: mt
  recipe: mt
  environment: production
  created: "2026-03-15T10:00:00+11:00"
  purpose: indefinite

live:
  enabled: true
  domain: mt.nwpcode.org
  server_ip: 97.107.137.88
  linode_id: 12345
  type: drupal

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

vrt:
  pages: ["/", "/parishes", "/map"]
  threshold: 0.05
  viewport: "1920x1080"

backups:
  directory: ./backups           # Relative to project root
  schedule: "0 2 * * *"
```

#### Layer 3: Per-Developer Overrides (`.nwp.local.yml`, gitignored)

```yaml
# ~/projects/mt/.nwp.local.yml  (gitignored)
project:
  environment: development

live:
  enabled: false

mass_times:
  shadow_mode: true              # Don't sync to production
```

#### Layer 4: CLI Flags

```bash
pl backup --env=staging --sanitize
```

#### Config Resolution Order

```
CLI flags  >  .nwp.local.yml  >  .nwp.yml  >  ~/.nwp/config.yml  >  built-in defaults
```

### 3.3 Project Discovery

The `pl` CLI discovers projects using three mechanisms (in priority order):

#### 1. Current Directory (primary)

Walk up from `$PWD` looking for `.nwp.yml`:

```bash
find_project_root() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/.nwp.yml" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}
```

This allows:
```bash
cd ~/projects/mt
pl backup        # Knows it's the MT project from .nwp.yml
pl status        # Shows MT status
```

#### 2. Explicit Argument

```bash
pl backup mt                    # Looks up "mt" in registry
pl backup ~/projects/mt         # Absolute path
```

#### 3. Registry (`~/.nwp/projects.yml`)

```yaml
# ~/.nwp/projects.yml (auto-maintained)
projects:
  avc:
    path: /home/rob/projects/avc
    recipe: avc
    registered: "2026-04-10T10:00:00+10:00"
  mt:
    path: /home/rob/projects/mt
    recipe: mt
    registered: "2026-04-10T10:00:00+10:00"
  ss:
    path: /home/rob/projects/ss
    recipe: m
    registered: "2026-04-10T10:00:00+10:00"
```

Projects are auto-registered when `pl install` creates them or when `pl register` is run in a project directory. The registry enables cross-project commands:

```bash
pl status --all          # Shows all registered projects
pl backup --all          # Backs up all registered projects
pl list                  # Lists all registered projects
```

### 3.4 Secrets Architecture

Secrets move from the repo to `~/.nwp/`:

```
~/.nwp/
    secrets.yml              # Infrastructure secrets (was .secrets.yml)
    secrets.data.yml         # Data secrets (was .secrets.data.yml)
```

Per-project secrets (e.g., mass_times API keys) can live in either:
- `~/.nwp/secrets.yml` under a project-namespaced key
- A project-local `.secrets.yml` (gitignored)

### 3.5 Backup Architecture

Backups move from central `sitebackups/` to per-project:

```
# Old (centralized):
/home/rob/nwp/sitebackups/mt/20260401-main-abc123.sql.gz

# New (per-project):
~/projects/mt/backups/20260401-main-abc123.sql.gz
```

The backup directory is configurable in `.nwp.yml`:
```yaml
backups:
  directory: ./backups                    # Default: relative to project root
  # directory: /mnt/backups/mt           # Or absolute path
  # directory: ~/.nwp/backups/mt         # Or centralized
```

### 3.6 Module Distribution

Shared Drupal modules that currently live in `~/nwp/modules/` need a new home:

| Module | Used By | Strategy |
|--------|---------|----------|
| `mass_times` | MT only | Move into MT project repo |
| `cathnet` | CathNet only | Move into CathNet project repo |
| `dir_search` | DIR only | Move into DIR project repo |
| `avc_moodle` | AVC only | Move into AVC project repo |
| `avc_oauth2` (Moodle) | SS only | Move into SS project repo |

Since every module is used by exactly one project, the solution is simple: each module moves into its project. If a module were shared across projects, it would become a Composer package published to the GitLab package registry.

---

## 4. Implementation Plan

### Phase 1: Global Config Extraction (8-12 hours)

**Goal:** Create `~/.nwp/` directory with global config, without changing any existing behavior.

#### 4.1.1 Create `~/.nwp/` structure

```bash
mkdir -p ~/.nwp
```

#### 4.1.2 Create `~/.nwp/config.yml`

Extract global settings from `nwp.yml` into `~/.nwp/config.yml`:
- `settings.*` (except project-specific sections like `mass_times`)
- `recipes.*`
- `other_coders.*`
- `linode.*`
- `import_defaults.*`

#### 4.1.3 Create `~/.nwp/projects.yml`

Auto-generate from current `nwp.yml` sites section:

```bash
# Script: scripts/commands/migrate-config.sh
for site in $(yaml_get_all_sites "$NWP_DIR/nwp.yml"); do
    dir=$(get_site_field "$site" "directory" "$NWP_DIR/nwp.yml")
    recipe=$(get_site_field "$site" "recipe" "$NWP_DIR/nwp.yml")
    # Write to ~/.nwp/projects.yml
done
```

#### 4.1.4 Move secrets to `~/.nwp/`

```bash
cp "$NWP_DIR/.secrets.yml" ~/.nwp/secrets.yml
cp "$NWP_DIR/.secrets.data.yml" ~/.nwp/secrets.data.yml
# Keep originals as symlinks for backwards compat
ln -sf ~/.nwp/secrets.yml "$NWP_DIR/.secrets.yml"
ln -sf ~/.nwp/secrets.data.yml "$NWP_DIR/.secrets.data.yml"
```

#### 4.1.5 Update config reading functions

Modify `lib/yaml-write.sh` and `lib/common.sh` to check `~/.nwp/config.yml` as fallback:

```bash
get_config_file() {
    # Priority: local nwp.yml > project .nwp.yml > ~/.nwp/config.yml
    if [[ -f "$PROJECT_ROOT/nwp.yml" ]]; then
        echo "$PROJECT_ROOT/nwp.yml"          # Old-style (backwards compat)
    elif [[ -f "$PROJECT_ROOT/.nwp.yml" ]]; then
        echo "$PROJECT_ROOT/.nwp.yml"          # New-style per-project
    elif [[ -f "$HOME/.nwp/config.yml" ]]; then
        echo "$HOME/.nwp/config.yml"           # Global fallback
    fi
}
```

**Backwards compatibility:** The old `nwp.yml` at repo root continues to work. New config locations are additive.

**Files modified:**
- `lib/yaml-write.sh` — config file resolution
- `lib/common.sh` — `get_setting()` fallback chain
- `lib/install-common.sh` — `get_settings_value()` fallback chain
- New: `scripts/commands/migrate-config.sh`
- New: `~/.nwp/config.yml`, `~/.nwp/projects.yml`

---

### Phase 2: Project Discovery Engine (12-16 hours)

**Goal:** The `pl` CLI can find projects by walking up directories, by name from registry, or by explicit path.

#### 4.2.1 Implement `find_project_root()`

Add to `lib/common.sh`:

```bash
find_project_root() {
    local dir="${1:-$PWD}"
    while [[ "$dir" != "/" ]]; do
        # New-style: .nwp.yml marker
        if [[ -f "$dir/.nwp.yml" ]]; then
            echo "$dir"
            return 0
        fi
        # Old-style: nwp.yml with sites/ parent
        if [[ -f "$dir/../nwp.yml" ]] && [[ -d "$dir/.ddev" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}
```

#### 4.2.2 Implement project registry functions

Add to `lib/common.sh`:

```bash
registry_file="$HOME/.nwp/projects.yml"

register_project() {
    local name="$1" path="$2" recipe="$3"
    yq eval -i ".projects.$name.path = \"$path\"" "$registry_file"
    yq eval -i ".projects.$name.recipe = \"$recipe\"" "$registry_file"
    yq eval -i ".projects.$name.registered = \"$(date -Iseconds)\"" "$registry_file"
}

resolve_project() {
    local identifier="$1"
    # 1. Absolute path
    if [[ "$identifier" == /* ]] && [[ -f "$identifier/.nwp.yml" ]]; then
        echo "$identifier"; return 0
    fi
    # 2. Registry lookup
    local path
    path=$(yq eval ".projects.$identifier.path" "$registry_file" 2>/dev/null)
    if [[ -n "$path" ]] && [[ "$path" != "null" ]] && [[ -d "$path" ]]; then
        echo "$path"; return 0
    fi
    # 3. Legacy sites/ lookup
    if [[ -d "$NWP_DIR/sites/$identifier" ]]; then
        echo "$NWP_DIR/sites/$identifier"; return 0
    fi
    return 1
}

list_all_projects() {
    # Combine: registry + legacy sites/ scan
    local projects=()
    # From registry
    if [[ -f "$registry_file" ]]; then
        while IFS= read -r name; do
            [[ -n "$name" ]] && projects+=("$name")
        done < <(yq eval '.projects | keys[]' "$registry_file" 2>/dev/null)
    fi
    # From legacy nwp.yml
    if [[ -f "$NWP_DIR/nwp.yml" ]]; then
        while IFS= read -r name; do
            # Add if not already in list
            if [[ ! " ${projects[*]} " =~ " $name " ]]; then
                projects+=("$name")
            fi
        done < <(yaml_get_all_sites "$NWP_DIR/nwp.yml")
    fi
    printf '%s\n' "${projects[@]}"
}
```

#### 4.2.3 Update `pl` main script

Modify the site resolution logic in `pl` to use the new discovery chain:

```bash
# In pl, after parsing command and arguments:
if [[ -n "$SITENAME" ]]; then
    SITE_DIR=$(resolve_project "$SITENAME")
elif SITE_DIR=$(find_project_root); then
    SITENAME=$(basename "$SITE_DIR")
else
    # No project context - OK for global commands (list, status --all, setup)
    SITE_DIR=""
fi
```

#### 4.2.4 Add `pl register` and `pl unregister` commands

```bash
# pl register [name]
# Run from within a project directory to add it to the registry
pl register mt       # Registers current directory as "mt"

# pl unregister mt
# Removes from registry (does not delete files)
```

#### 4.2.5 Update `get_site_path()` everywhere

The critical change: replace all `$PROJECT_ROOT/sites/$SITENAME` patterns with `resolve_project()`:

```bash
# OLD:
site_path="$PROJECT_ROOT/sites/$SITENAME"

# NEW:
site_path=$(resolve_project "$SITENAME") || {
    print_error "Project '$SITENAME' not found"
    return 1
}
```

**This is the largest mechanical change** — approximately 150 locations across:
- `lib/common.sh`
- `lib/install-common.sh`
- `lib/install-drupal.sh`
- `lib/install-moodle.sh`
- `lib/verify-runner.sh`
- `lib/verify-scenarios.sh`
- `lib/verify-checkpoint.sh`
- `scripts/commands/install.sh`
- `scripts/commands/backup.sh`
- `scripts/commands/restore.sh`
- `scripts/commands/delete.sh`
- `scripts/commands/status.sh`
- `scripts/commands/dev2stg.sh`
- `scripts/commands/stg2live.sh`
- `scripts/commands/live2stg.sh`
- `scripts/commands/import.sh`
- `scripts/commands/modify.sh`
- `scripts/commands/verify.sh`
- `scripts/commands/todo.sh`
- And ~20 more scripts

**Files modified:** 40+ shell scripts
**New files:** `scripts/commands/register.sh`, `scripts/commands/unregister.sh`

---

### Phase 3: Per-Project `.nwp.yml` Support (10-14 hours)

**Goal:** Each project can have its own `.nwp.yml` that contains project-specific config. Config resolution merges global + project + local layers.

#### 4.3.1 Implement layered config resolution

Add to `lib/yaml-write.sh`:

```bash
# Resolve a config value through the layer chain
resolve_config() {
    local key_path="$1"
    local project_dir="$2"
    local default_value="${3:-}"

    # Layer 4: CLI environment (already handled by callers)

    # Layer 3: Project local overrides
    if [[ -f "$project_dir/.nwp.local.yml" ]]; then
        local val
        val=$(yq eval "$key_path" "$project_dir/.nwp.local.yml" 2>/dev/null)
        if [[ -n "$val" ]] && [[ "$val" != "null" ]]; then
            echo "$val"; return 0
        fi
    fi

    # Layer 2: Project config
    if [[ -f "$project_dir/.nwp.yml" ]]; then
        local val
        val=$(yq eval "$key_path" "$project_dir/.nwp.yml" 2>/dev/null)
        if [[ -n "$val" ]] && [[ "$val" != "null" ]]; then
            echo "$val"; return 0
        fi
    fi

    # Layer 1: Global config
    if [[ -f "$HOME/.nwp/config.yml" ]]; then
        local val
        val=$(yq eval "$key_path" "$HOME/.nwp/config.yml" 2>/dev/null)
        if [[ -n "$val" ]] && [[ "$val" != "null" ]]; then
            echo "$val"; return 0
        fi
    fi

    # Layer 0: Legacy nwp.yml (backwards compat)
    if [[ -f "$NWP_DIR/nwp.yml" ]]; then
        local val
        val=$(yq eval "$key_path" "$NWP_DIR/nwp.yml" 2>/dev/null)
        if [[ -n "$val" ]] && [[ "$val" != "null" ]]; then
            echo "$val"; return 0
        fi
    fi

    echo "$default_value"
}
```

#### 4.3.2 Define `.nwp.yml` schema

```yaml
# .nwp.yml schema for a Drupal project
project:
  name: mt                           # Required: project identifier
  recipe: mt                         # Required: recipe name from global config
  environment: production            # development | staging | production
  created: "2026-03-15T10:00:00+11:00"
  purpose: indefinite                # indefinite | testing | production

# Recipe overrides (override global recipe defaults)
recipe_overrides:
  php: "8.3"
  database: mariadb
  webroot: web
  install_modules:
    - geofield
    - paragraphs

# Live deployment config
live:
  enabled: true
  domain: mt.nwpcode.org
  server_ip: 97.107.137.88
  linode_id: 12345
  remote_path: /var/www/mt

# Project-specific settings (varies by project type)
# For MT:
mass_times:
  centre_lat: -37.8136
  centre_lng: 145.2280
  # ...

# For AVC:
moodle_integration:
  enabled: true
  moodle_site: ss
  moodle_url: https://ss.nwpcode.org
  # ...

# Backups
backups:
  directory: ./backups
  schedule: "0 2 * * *"

# Visual regression testing
vrt:
  pages: ["/", "/parishes"]
  threshold: 0.05

# Frontend
frontend:
  build_tool: vite
  node_version: "20"

# Email
email:
  enabled: true
  address: mt@nwpcode.org
```

#### 4.3.3 Update all `get_site_field()` callers

Replace calls to `get_site_field(site, field, config_file)` with `resolve_config()`:

```bash
# OLD:
domain=$(get_site_nested_field "$site" "live" "domain" "$config_file")

# NEW:
domain=$(resolve_config ".live.domain" "$SITE_DIR")
```

#### 4.3.4 Add `pl config show` command

Dumps the fully resolved config for the current project (merging all layers):

```bash
pl config show           # Shows resolved config for current project
pl config show --layer=project  # Shows only project .nwp.yml
pl config show --layer=global   # Shows only global config
pl config show --key=.live.domain  # Shows single resolved value
```

#### 4.3.5 Update `pl install` to create `.nwp.yml`

When installing a new project, generate `.nwp.yml` in the project directory:

```bash
# In install.sh, after site creation:
generate_project_config() {
    local project_dir="$1" name="$2" recipe="$3"
    cat > "$project_dir/.nwp.yml" <<YAML
project:
  name: $name
  recipe: $recipe
  environment: development
  created: "$(date -Iseconds)"
  purpose: indefinite
YAML
    # Also register in ~/.nwp/projects.yml
    register_project "$name" "$project_dir" "$recipe"
}
```

**Files modified:** `lib/yaml-write.sh`, `lib/common.sh`, `lib/install-common.sh`, `scripts/commands/install.sh`, all scripts using `get_site_field()`
**New files:** `scripts/commands/config.sh`

---

### Phase 4: Backup & Deployment Path Decoupling (8-10 hours)

**Goal:** Backups, deployment, and other path-dependent operations work with projects in any location.

#### 4.4.1 Backup path resolution

```bash
get_backup_dir() {
    local project_dir="$1"
    # Check project config
    local configured
    configured=$(resolve_config ".backups.directory" "$project_dir")
    if [[ -n "$configured" ]]; then
        # Resolve relative to project dir
        if [[ "$configured" == ./* ]]; then
            echo "$project_dir/${configured#./}"
        else
            echo "$configured"
        fi
        return 0
    fi
    # Legacy fallback
    local name
    name=$(basename "$project_dir")
    if [[ -d "$NWP_DIR/sitebackups/$name" ]]; then
        echo "$NWP_DIR/sitebackups/$name"
        return 0
    fi
    # Default
    echo "$project_dir/backups"
}
```

#### 4.4.2 Update backup.sh

Replace all `sitebackups/$sitename` references with `get_backup_dir()`.

#### 4.4.3 Update restore.sh

Same pattern — resolve backup directory from project config.

#### 4.4.4 Update deployment scripts

`dev2stg.sh`, `stg2live.sh`, `live2stg.sh`, `stg2prod.sh` — all need to resolve source and target project directories via `resolve_project()` instead of assuming `sites/`.

**Staging convention change:**
```bash
# OLD: sites/avc → sites/avc-stg (sibling in same directory)
# NEW: projects/avc → projects/avc-stg (sibling in same parent)
#  OR: Staging is a separate project with its own .nwp.yml

get_stg_dir() {
    local dev_dir="$1"
    local dev_name
    dev_name=$(basename "$dev_dir")
    local parent
    parent=$(dirname "$dev_dir")
    echo "$parent/${dev_name}-stg"
}
```

**Files modified:** `scripts/commands/backup.sh`, `scripts/commands/restore.sh`, `scripts/commands/dev2stg.sh`, `scripts/commands/stg2live.sh`, `scripts/commands/live2stg.sh`, `scripts/commands/stg2prod.sh`, `scripts/commands/rollback.sh`, `lib/safe-ops.sh`

---

### Phase 5: Extract Projects from Monorepo (20-30 hours)

**Goal:** Move each project into its own git repo with preserved history.

#### 4.5.1 Install `git-filter-repo`

```bash
pip install git-filter-repo
```

#### 4.5.2 Extract each project

For each project, use `git filter-repo` to extract its history:

**MT (Mass Times):**
```bash
git clone /home/rob/nwp /tmp/mt-extract
cd /tmp/mt-extract
git filter-repo \
    --path sites/mt/ \
    --path modules/mass_times/ \
    --path mt/ \
    --path-rename sites/mt/:. \
    --path-rename modules/mass_times/:modules/custom/mass_times/ \
    --path-rename mt/:pipeline/
```

**CathNet:**
```bash
git clone /home/rob/nwp /tmp/cathnet-extract
cd /tmp/cathnet-extract
git filter-repo \
    --path sites/cathnet/ \
    --path modules/cathnet/ \
    --path cathnet/ \
    --path-rename sites/cathnet/:. \
    --path-rename modules/cathnet/:modules/custom/cathnet/ \
    --path-rename cathnet/:pipeline/
```

**DIR:**
```bash
git clone /home/rob/nwp /tmp/dir-extract
cd /tmp/dir-extract
git filter-repo \
    --path sites/dir1/ \
    --path modules/dir_search/ \
    --path-rename sites/dir1/:. \
    --path-rename modules/dir_search/:modules/custom/dir_search/
```

**SS (Moodle) + Faith Formation:**
```bash
git clone /home/rob/nwp /tmp/ss-extract
cd /tmp/ss-extract
git filter-repo \
    --path sites/ss/ \
    --path moodle_plugins/ \
    --path-rename sites/ss/:. \
    --path-rename moodle_plugins/auth/avc_oauth2/:auth/avc_oauth2/
```

**AVC** already has its own repo at `git.nwpcode.org:nwp/avc-project`. It just needs:
- `.nwp.yml` added
- `avc_moodle` module moved in from `modules/avc_moodle/`

**FIN Monitor:**
```bash
git clone /home/rob/nwp /tmp/fin-extract
cd /tmp/fin-extract
git filter-repo --path fin/ --path-rename fin/:.
```

#### 4.5.3 Create repos on git.nwpcode.org

```bash
for project in mt cathnet dir ss fin; do
    ssh git@git.nwpcode.org "cd /opt/gitlab/data/repositories && \
        git init --bare nwp/${project}.git"
done
```

#### 4.5.4 Push extracted repos

```bash
cd /tmp/mt-extract
git remote add origin git@git.nwpcode.org:nwp/mt.git
git push -u origin main
```

#### 4.5.5 Generate `.nwp.yml` for each project

Create appropriate `.nwp.yml` files based on current `nwp.yml` site entries.

#### 4.5.6 Add `.nwp.local.yml` to `.gitignore` in each project

```bash
echo ".nwp.local.yml" >> .gitignore
```

---

### Phase 6: Clean NWP Core Repo (8-10 hours)

**Goal:** Remove project-specific code from the NWP core repo.

#### 4.6.1 Remove project directories

After verifying all projects are working independently:

```bash
# Remove from NWP repo (not immediately - keep during transition)
git rm -r sites/avc sites/avc-stg
git rm -r sites/dir1 sites/dir1-stg
git rm -r sites/mt
git rm -r sites/cathnet sites/cathnet-stg
git rm -r sites/ss sites/ss_moodledata
git rm -r sites/cccrdf
git rm -r modules/mass_times modules/cathnet modules/dir_search modules/avc_moodle
git rm -r mt/ cathnet/ fin/ moodle_plugins/
```

#### 4.6.2 Keep in NWP core

```
pl                              # CLI
lib/                            # All shared libraries
scripts/commands/               # All command scripts
recipes/                        # Recipe definitions (move to ~/.nwp/config.yml or keep here)
templates/                      # DDEV, env, docker templates
docs/                           # Tool documentation
tests/                          # Tool-level tests
sites/verify-test-*/            # Keep test sites (or move to a test harness)
example.config.yml              # Template for ~/.nwp/config.yml
CLAUDE.md
CHANGELOG.md
README.md
```

#### 4.6.3 Update `example.nwp.yml` → `example.config.yml`

Rename and restructure to reflect the new global config schema.

#### 4.6.4 Remove old `nwp.yml` support

After all projects are migrated, remove the backwards-compatibility code that reads `nwp.yml` from the repo root.

---

### Phase 7: Verification & Documentation (6-8 hours)

#### 4.7.1 Update verification system

- Test sites (`verify-test-*`) should be created as independent projects
- `verify-runner.sh` updated to use project discovery
- `.verification.yml` scenarios updated for new paths

#### 4.7.2 Update all documentation

- `README.md` — new getting started workflow
- `CLAUDE.md` — new project structure, new config paths
- `docs/` — update all guides for new layout
- Recipe documentation

#### 4.7.3 Migration script

Create `scripts/commands/migrate.sh` that automates the full migration:

```bash
pl migrate                     # Interactive migration wizard
pl migrate --project=mt        # Migrate single project
pl migrate --all               # Migrate all projects
pl migrate --verify            # Verify migration was successful
pl migrate --rollback=mt       # Undo migration for a project
```

#### 4.7.4 Run verification

```bash
pl verify --run --depth=thorough
```

---

## 5. Affected Scripts — Complete Inventory

### 5.1 Core Path Resolution (HIGH impact — must change)

| Script | Changes Required |
|--------|-----------------|
| `pl` | Site resolution via `find_project_root()` / `resolve_project()` |
| `lib/common.sh` | `get_site_path()`, `validate_sitename()`, `list_sites()` |
| `lib/yaml-write.sh` | All `yaml_*_site*()` functions, config file resolution |
| `lib/install-common.sh` | `get_settings_value()`, site directory creation |
| `lib/install-drupal.sh` | Site path, webroot resolution |
| `lib/install-moodle.sh` | Site path resolution |
| `lib/install-gitlab.sh` | Site path resolution |
| `lib/install-podcast.sh` | Site path resolution |

### 5.2 Command Scripts (MEDIUM impact — path updates)

| Script | Changes Required |
|--------|-----------------|
| `scripts/commands/install.sh` | Create project in resolved location, generate `.nwp.yml` |
| `scripts/commands/delete.sh` | Resolve project, unregister from registry |
| `scripts/commands/backup.sh` | Use `get_backup_dir()` |
| `scripts/commands/restore.sh` | Use `get_backup_dir()` |
| `scripts/commands/status.sh` | Use `list_all_projects()` |
| `scripts/commands/dev2stg.sh` | Resolve source/target via registry |
| `scripts/commands/stg2live.sh` | Read live config from `.nwp.yml` |
| `scripts/commands/live2stg.sh` | Same |
| `scripts/commands/stg2prod.sh` | Same |
| `scripts/commands/import.sh` | Register imported project |
| `scripts/commands/modify.sh` | Modify `.nwp.yml` instead of central config |
| `scripts/commands/sync.sh` | Path resolution |
| `scripts/commands/copy.sh` | Path resolution |
| `scripts/commands/rollback.sh` | Path + backup resolution |

### 5.3 Verification & Testing (MEDIUM impact)

| Script | Changes Required |
|--------|-----------------|
| `scripts/commands/verify.sh` | Test site creation as independent projects |
| `lib/verify-runner.sh` | Project discovery for test sites |
| `lib/verify-scenarios.sh` | Updated path patterns |
| `lib/verify-checkpoint.sh` | Updated path patterns |
| `lib/verify-cross-validate.sh` | Remove hard-coded `avc` reference |
| `scripts/commands/test.sh` | Path resolution |
| `scripts/commands/vrt.sh` | Path resolution |

### 5.4 Integration & Utility (LOW impact — minor updates)

| Script | Changes Required |
|--------|-----------------|
| `scripts/commands/todo.sh` | Read project-level todo config |
| `scripts/commands/security.sh` | Path resolution |
| `scripts/commands/email.sh` | Read email config from project `.nwp.yml` |
| `scripts/commands/coder-setup.sh` | Updated config paths |
| `scripts/commands/doctor.sh` | Check both old and new layouts |
| `scripts/commands/seo-check.sh` | Path resolution |
| `lib/frontend.sh` | Path resolution |
| `lib/ddev-generate.sh` | Path resolution |
| `lib/env-generate.sh` | Path resolution |
| `lib/avc-moodle.sh` | Read from project `.nwp.yml` |
| `lib/todo-checks.sh` | Updated config paths |
| `lib/remote.sh` | Path resolution |

### 5.5 New Scripts

| Script | Purpose |
|--------|---------|
| `scripts/commands/register.sh` | Register project in `~/.nwp/projects.yml` |
| `scripts/commands/unregister.sh` | Remove from registry |
| `scripts/commands/config.sh` | Show/edit resolved config |
| `scripts/commands/migrate.sh` | Migration wizard |
| `scripts/commands/migrate-config.sh` | Config migration helper |

---

## 6. Project Type Matrix

How each project type maps to the new architecture:

### 6.1 Drupal Projects (d, avc, os, dm, mt recipes)

```
~/projects/<name>/
    .nwp.yml                    # Project config
    .nwp.local.yml              # Local overrides (gitignored)
    .ddev/config.yaml           # DDEV config
    .gitignore
    composer.json
    composer.lock
    web/ or html/               # Webroot (per recipe)
        modules/custom/         # Project-specific modules
        themes/custom/          # Project-specific themes
        sites/default/
            settings.php
    config/                     # Drupal config export (if used)
    private/                    # Drupal private files
    backups/                    # Database/file backups
    .env                        # Environment variables
```

### 6.2 Moodle Projects (m recipe)

```
~/projects/<name>/
    .nwp.yml                    # Project config
    .nwp.local.yml              # Local overrides (gitignored)
    .ddev/config.yaml           # DDEV config
    config.php                  # Moodle config
    admin/                      # Moodle admin
    auth/                       # Auth plugins (including custom)
    mod/                        # Activity modules
    local/                      # Local plugins
    course/format/              # Course format plugins
    moodledata/                 # Moodle data (or symlink)
    backups/
```

### 6.3 Drupal + Pipeline Projects (mt, cathnet)

```
~/projects/<name>/
    .nwp.yml                    # Project config (includes pipeline settings)
    .nwp.local.yml              # Local overrides
    .ddev/config.yaml           # DDEV config (for Drupal)
    web/                        # Drupal webroot
        modules/custom/<name>/  # Drupal display module
    pipeline/                   # Python pipeline
        src/
        data/
        templates/
        tests/
        requirements.txt
        venv/
    scripts/                    # Project-specific scripts
        deploy-pipeline.sh
        setup-pipeline.sh
    backups/
    composer.json
```

### 6.4 Flutter/Mobile Projects

```
~/projects/<name>/
    .nwp.yml                    # Minimal project config (or none)
    lib/                        # Dart source
    test/                       # Dart tests
    assets/                     # Bundled assets
    pubspec.yaml
    android/
    ios/
    linux/
    macos/
    web/
```

### 6.5 Utility Projects (fin)

```
~/projects/<name>/
    .nwp.yml                    # Minimal config (email, schedule)
    src/                        # Source code
    requirements.txt
    scripts/
        deploy.sh
        setup.sh
```

---

## 7. Migration Path for Each Current Project

| Project | Current Location | Target Location | Git Strategy |
|---------|-----------------|----------------|-------------|
| AVC | `sites/avc/` (own repo) | `~/projects/avc/` | Already separate; add `.nwp.yml`, move `modules/avc_moodle/` in |
| AVC-STG | `sites/avc-stg/` | `~/projects/avc-stg/` | Clone of AVC repo; add `.nwp.yml` with `environment: staging` |
| DIR | `sites/dir1/` + `modules/dir_search/` | `~/projects/dir/` | `git filter-repo` extraction |
| MT | `sites/mt/` + `modules/mass_times/` + `mt/` | `~/projects/mt/` | `git filter-repo` extraction; merge 3 paths |
| CathNet | `sites/cathnet/` + `modules/cathnet/` + `cathnet/` | `~/projects/cathnet/` | `git filter-repo` extraction; merge 3 paths |
| SS | `sites/ss/` + `moodle_plugins/` | `~/projects/ss/` | `git filter-repo` extraction |
| Faith Formation | `sites/ss/faith_formation/` | `~/projects/faith-formation/` | `git filter-repo` extraction |
| FIN | `fin/` | `~/projects/fin/` | `git filter-repo` extraction |
| CCCRDF | `sites/cccrdf/` | `~/projects/cccrdf/` | `git filter-repo` extraction |

---

## 8. Risk Assessment

### 8.1 High Risk

| Risk | Mitigation |
|------|-----------|
| Breaking 150+ path references | Mechanical change with consistent pattern; grep-verifiable |
| Backup path migration | Keep old `sitebackups/` as symlink during transition |
| DDEV configuration breaks | DDEV is path-independent; `.ddev/config.yaml` uses relative paths |
| Secrets file relocation | Symlinks from old location to new during transition |
| Cross-project references (AVC-Moodle) | Both projects reference each other by URL, not filesystem path |

### 8.2 Medium Risk

| Risk | Mitigation |
|------|-----------|
| Config resolution performance (4 files per lookup) | Cache resolved config in memory per script invocation |
| Registry becoming stale | `pl doctor` checks registry against filesystem |
| Contributors confused by new layout | Clear migration docs; `pl migrate` wizard |

### 8.3 Low Risk

| Risk | Mitigation |
|------|-----------|
| Git history loss during extraction | `git filter-repo` preserves full history |
| CI/CD pipeline changes | `.gitlab-ci.yml` already per-project; NWP core has its own |
| Remote server paths | Remote paths (`/var/www/`) are already independent of local layout |

---

## 9. Success Criteria

- [ ] `pl install d mysite` creates a project at `~/projects/mysite/` with `.nwp.yml`
- [ ] `cd ~/projects/mysite && pl backup` works without specifying site name
- [ ] `pl status --all` lists projects from both registry and legacy locations
- [ ] `pl config show` displays fully resolved config for current project
- [ ] Each extracted project has its own git repo with preserved history
- [ ] NWP core repo contains zero project-specific code
- [ ] All 440+ verification tests pass with new layout
- [ ] Old `sites/` layout continues to work during transition (backwards compat)
- [ ] `pl migrate --project=mt` automates full migration for a single project
- [ ] No hard-coded site names remain in codebase (currently only `avc` in 3 places)
- [ ] `~/.nwp/config.yml` contains all global settings
- [ ] Per-project `.nwp.yml` contains all project-specific settings
- [ ] Secrets are in `~/.nwp/` not in the repo

---

## 10. Timeline

| Phase | Description | Effort | Dependencies |
|-------|-------------|--------|-------------|
| Phase 1 | Global config extraction | 8-12h | None |
| Phase 2 | Project discovery engine | 12-16h | Phase 1 |
| Phase 3 | Per-project `.nwp.yml` support | 10-14h | Phase 2 |
| Phase 4 | Backup & deployment path decoupling | 8-10h | Phase 2 |
| Phase 5 | Extract projects from monorepo | 20-30h | Phases 1-4 |
| Phase 6 | Clean NWP core repo | 8-10h | Phase 5 |
| Phase 7 | Verification & documentation | 6-8h | Phase 6 |
| **Total** | | **72-100h** | |

Phases 3 and 4 can run in parallel after Phase 2 is complete.

---

## 11. Worth-It Evaluation

### 11.1 Benefits

| Benefit | Impact |
|---------|--------|
| Per-project git history | Each project's history is clean and focused |
| Per-project access control | Contributors see only what they need |
| Independent deployment cycles | Update MT without touching AVC |
| Smaller repos | NWP core ~5MB; each project proportional to its size |
| Standard tooling pattern | Matches DDEV/Lando/Terraform mental model |
| Per-project CI/CD | Each project can have its own pipeline |
| Cleaner contributor onboarding | Clone one project, not the entire monorepo |
| Secrets isolation | Per-project secrets in per-project config |

### 11.2 Costs

| Cost | Impact |
|------|--------|
| 72-100 hours of development | Major time investment |
| Learning curve for new layout | One-time adjustment |
| Cross-project operations slightly more complex | Registry mitigates this |
| Migration period complexity | Temporary; expand-migrate-contract is well-proven |

### 11.3 Verdict

**Recommended.** The current monorepo was appropriate for the rapid prototyping phase (Dec 2025 - Apr 2026) where a single developer built everything. As the project matures — with proposals for contributor governance (F04), coder management (F15), and multiple independent projects (MT, CathNet, DIR, SS, Faith Formation) — the separation becomes essential for sustainable growth. The mechanical nature of the changes (consistent path patterns) makes the effort predictable and low-risk.

---

## 12. Appendix: Configuration Migration Map

### From `nwp.yml` to `~/.nwp/config.yml`

| Old Path | New Path | Notes |
|----------|----------|-------|
| `settings.license.*` | `settings.license.*` | Unchanged |
| `settings.timezone` | `settings.timezone` | Unchanged |
| `settings.cli_command` | `settings.cli_command` | Unchanged |
| `settings.claude.*` | `settings.claude.*` | Unchanged |
| `settings.database` | `settings.database` | Unchanged |
| `settings.php` | `settings.php` | Unchanged |
| `settings.frontend.*` | `settings.frontend.*` | Unchanged |
| `settings.url` | `settings.url` | Unchanged |
| `settings.email.*` | `settings.email.*` | Unchanged |
| `settings.php_settings.*` | `settings.php_settings.*` | Unchanged |
| `settings.gitlab.*` | `settings.gitlab.*` | Unchanged |
| `settings.environment.*` | `settings.environment.*` | Unchanged |
| `settings.services.*` | `settings.services.*` | Unchanged |
| `settings.seo.*` | `settings.seo.*` | Unchanged |
| `settings.verification.*` | `settings.verification.*` | Unchanged |
| `settings.todo.*` | `settings.todo.*` | Unchanged |
| `settings.delete_site_yml` | `settings.delete_project` | Renamed |
| `recipes.*` | `recipes.*` | Unchanged |
| `other_coders.*` | `other_coders.*` | Unchanged |
| `linode.*` | `linode.*` | Unchanged |
| `import_defaults.*` | `import_defaults.*` | Unchanged |

### From `nwp.yml` to per-project `.nwp.yml`

| Old Path | New Path | Notes |
|----------|----------|-------|
| `sites.<name>.recipe` | `project.recipe` | |
| `sites.<name>.directory` | (implicit: project root) | No longer needed |
| `sites.<name>.environment` | `project.environment` | |
| `sites.<name>.created` | `project.created` | |
| `sites.<name>.purpose` | `project.purpose` | |
| `sites.<name>.installed_modules[]` | `recipe_overrides.installed_modules[]` | |
| `sites.<name>.live.*` | `live.*` | |
| `sites.<name>.vrt.*` | `vrt.*` | |
| `sites.<name>.frontend.*` | `frontend.*` | |
| `sites.<name>.email.*` | `email.*` | |
| `sites.<name>.moodle_integration.*` | `moodle_integration.*` | |
| `sites.<name>.avc_integration.*` | `avc_integration.*` | |
| `settings.mass_times.*` | `mass_times.*` (in MT's `.nwp.yml`) | Project-specific |
