# NWP Improvement Proposal: Enhanced dev2stg Workflow

## Overview

This proposal outlines improvements to the NWP deployment pipeline, specifically the `dev2stg.sh` script, based on lessons learned from:
- **Pleasy** (`~/tmp/pleasy`) - Step-based recovery, config import resilience
- **Vortex** (`~/tmp/vortex`) - Multi-tier testing, router patterns, standardized output, doctor command
- **Current AVC architecture** - OpenSocial fork workflow

---

## Current AVC Architecture

### OpenSocial Fork Workflow

AVC is a specialized Drupal distribution based on **Open Social** (~12.4.0) with the following structure:

```
nwp/avc (GitLab Package)
├── html/                           # Webroot
│   ├── profiles/contrib/social/    # Open Social base
│   └── modules/custom/             # Symlinked from /avcgs/avc_profile/
│       ├── avc_core/               # Core functionality
│       ├── avc_member/             # Member management
│       ├── avc_group/              # Group functionality
│       ├── avc_asset/              # Asset management
│       ├── avc_notification/       # Notification system
│       ├── avc_guild/              # Guild/organization features
│       ├── avc_content/            # Content management
│       └── workflow_assignment/    # Custom workflow module
├── composer.json
└── private/
```

**Key Characteristics:**
- **Profile**: Custom `avc` profile (not standard `social`)
- **Package**: `nwp/avc:^0.2` via GitLab
- **External Module Storage**: Modules live in `/avcgs/avc_profile/` and are symlinked
- **Base Framework**: `goalgorilla/open_social:~12.4.0`

### Current Environment Flow

```
DEV (local: avc)
    ↓ [dev2stg.sh]
STG (local: avc_stg)
    ↓ [stg2prod.sh]
PROD (Linode: avc.nwpcode.org)
```

---

## Proposed dev2stg.sh Enhancements

### Core Philosophy

The enhanced `dev2stg.sh` should be **intelligent and adaptive**, capable of:
1. Auto-detecting what exists and what's needed
2. Suggesting an optimal plan based on current state
3. Allowing both automated (`-y`) and interactive (TUI) execution

### Proposed Workflow States

```
┌─────────────────────────────────────────────────────────────┐
│                    dev2stg.sh invoked                       │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ 1. STATE DETECTION                                          │
│    • Does _stg site exist?                                  │
│    • Is there a recent sanitized production backup?         │
│    • What's the age of the most recent backup?              │
│    • Is production accessible for fresh backup?             │
│    • What tests are available?                              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. PLAN GENERATION                                          │
│    Based on detected state, propose optimal path:           │
│    • Create staging site if missing                         │
│    • Use existing backup OR create fresh one                │
│    • Sync code and database                                 │
│    • Run tests (essential or full suite)                    │
└─────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
    ┌──────────────────┐           ┌──────────────────┐
    │   -y (auto)      │           │   TUI (default)  │
    │   Execute plan   │           │   Show options   │
    │   automatically  │           │   Allow changes  │
    └──────────────────┘           └──────────────────┘
```

### Detailed Step Breakdown

#### Phase 1: State Detection

```bash
detect_state() {
    local sitename="$1"
    local stg_name="${sitename}_stg"

    # Check staging site existence
    STG_EXISTS=$(site_exists "$stg_name")

    # Check for recent sanitized backups
    BACKUP_DIR="sitebackups/${sitename}/sanitized"
    RECENT_BACKUP=$(find_recent_backup "$BACKUP_DIR" 24)  # hours

    # Check production accessibility (if live site configured)
    PROD_ACCESSIBLE=$(check_prod_ssh "$sitename")

    # Inventory available tests
    TEST_SUITES=$(detect_test_suites "$sitename")
}
```

#### Phase 2: Staging Site Creation (if needed)

If the `_stg` site doesn't exist:

```bash
create_staging_site() {
    local sitename="$1"
    local stg_name="${sitename}_stg"

    # Option A: Clone from dev (quick, no prod data)
    # Option B: Create empty and populate from sanitized backup
    # Option C: Create from production backup

    echo "Creating staging site: $stg_name"

    # 1. Create DDEV configuration
    create_ddev_config "$stg_name" "staging"

    # 2. Copy codebase from dev
    rsync -av --exclude='.ddev' --exclude='vendor' \
          --exclude='node_modules' --exclude='*.sql*' \
          "${sitename}/" "${stg_name}/"

    # 3. Configure staging-specific settings
    configure_staging_environment "$stg_name"

    # 4. Start DDEV
    (cd "$stg_name" && ddev start)

    # 5. Populate database
    populate_staging_database "$stg_name"
}
```

#### Phase 3: Database Source Selection

Three options for staging database population:

```bash
select_database_source() {
    local sitename="$1"

    # Priority order:
    # 1. Recent sanitized production backup (< 24 hours old)
    # 2. Create fresh sanitized backup from production
    # 3. Clone from development database

    if [ -n "$RECENT_BACKUP" ]; then
        echo "OPTION A: Use existing sanitized backup"
        echo "  File: $RECENT_BACKUP"
        echo "  Age: $(backup_age_human "$RECENT_BACKUP")"
        DB_SOURCE="backup:$RECENT_BACKUP"

    elif [ "$PROD_ACCESSIBLE" = "true" ]; then
        echo "OPTION B: Create fresh sanitized backup from production"
        echo "  Production: $(get_live_domain "$sitename")"
        DB_SOURCE="production"

    else
        echo "OPTION C: Clone development database"
        echo "  Source: $sitename"
        DB_SOURCE="development"
    fi
}
```

#### Phase 4: Code Synchronization

```bash
sync_dev_to_stg() {
    local sitename="$1"
    local stg_name="${sitename}_stg"

    # Export config from dev
    (cd "$sitename" && ddev drush cex -y)

    # Rsync files (excluding environment-specific items)
    rsync -av --delete \
        --exclude='.ddev/' \
        --exclude='*/sites/default/settings.local.php' \
        --exclude='*/sites/default/files/' \
        --exclude='.git/' \
        --exclude='node_modules/' \
        --exclude='vendor/' \
        --exclude='private/' \
        "${sitename}/html/" "${stg_name}/html/"

    # Sync composer files
    cp "${sitename}/composer.json" "${stg_name}/"
    cp "${sitename}/composer.lock" "${stg_name}/"

    # Install dependencies (no-dev for staging)
    (cd "$stg_name" && ddev composer install --no-dev)
}
```

#### Phase 5: Database Update and Config Import

```bash
apply_updates() {
    local stg_name="$1"

    # Run database updates
    (cd "$stg_name" && ddev drush updatedb -y)

    # Import configuration (with retry for dependency handling)
    local max_attempts=3
    for i in $(seq 1 $max_attempts); do
        if (cd "$stg_name" && ddev drush cim -y); then
            echo "Config import successful on attempt $i"
            break
        fi
        echo "Config import attempt $i failed, retrying..."
    done

    # Clear caches
    (cd "$stg_name" && ddev drush cr)
}
```

#### Phase 6: Test Execution (Multi-Tier System)

Inspired by Vortex's four-tier testing architecture, NWP should support granular test selection:

```bash
# Test type definitions
declare -A TEST_TYPES=(
    ["phpunit"]="PHPUnit unit/integration tests"
    ["behat"]="Behat BDD scenario tests"
    ["phpstan"]="PHPStan static analysis"
    ["phpcs"]="PHP CodeSniffer style checks"
    ["eslint"]="JavaScript/TypeScript linting"
    ["stylelint"]="CSS/SCSS linting"
    ["security"]="Security vulnerability scan"
    ["accessibility"]="WCAG accessibility checks"
)

# Test presets
declare -A TEST_PRESETS=(
    ["quick"]="phpcs,eslint"                           # ~1 min - syntax only
    ["essential"]="phpunit,phpstan,phpcs"              # ~5 min - core quality
    ["functional"]="behat"                              # ~15 min - BDD scenarios
    ["full"]="phpunit,behat,phpstan,phpcs,eslint,stylelint,security"  # ~30 min
    ["security-only"]="security,phpstan"               # ~3 min - security focus
)

run_tests() {
    local stg_name="$1"
    local test_selection="$2"  # preset name OR comma-separated types

    # Check if it's a preset or custom selection
    if [[ -n "${TEST_PRESETS[$test_selection]}" ]]; then
        test_types="${TEST_PRESETS[$test_selection]}"
    else
        test_types="$test_selection"
    fi

    local failed=0
    for test_type in $(echo "$test_types" | tr ',' '\n'); do
        info "Running $test_type tests..."
        case "$test_type" in
            phpunit)
                (cd "$stg_name" && ddev exec vendor/bin/phpunit) || ((failed++))
                ;;
            behat)
                (cd "$stg_name" && ddev exec vendor/bin/behat --colors) || ((failed++))
                ;;
            phpstan)
                (cd "$stg_name" && ddev exec vendor/bin/phpstan analyse) || ((failed++))
                ;;
            phpcs)
                (cd "$stg_name" && ddev exec vendor/bin/phpcs) || ((failed++))
                ;;
            eslint)
                (cd "$stg_name" && ddev exec npm run lint:js) || ((failed++))
                ;;
            stylelint)
                (cd "$stg_name" && ddev exec npm run lint:css) || ((failed++))
                ;;
            security)
                (cd "$stg_name" && ddev drush pm:security) || ((failed++))
                ;;
            accessibility)
                (cd "$stg_name" && ddev exec npm run test:a11y) || ((failed++))
                ;;
        esac
    done

    return $failed
}
```

### Command-Line Interface

```
Usage: dev2stg.sh <sitename> [options]

Options:
  -y, --yes              Auto-confirm all prompts (CI/CD mode)
  -s, --step N           Start from step N (resume capability)
  -d, --debug            Enable debug output

Database Options:
  --use-backup FILE      Use specific backup file
  --fresh-backup         Force fresh backup from production
  --dev-db               Use development database (no production data)
  --sanitize             Ensure database is sanitized (default: true)
  --no-sanitize          Skip sanitization (use with caution)

Testing Options:
  -t, --test PRESET      Use a test preset:
                           quick      - Syntax checks only (~1 min)
                           essential  - PHPUnit + PHPStan + PHPCS (~5 min) [default with -y]
                           functional - Behat BDD scenarios (~15 min)
                           full       - All tests (~30 min)
                           security   - Security-focused checks (~3 min)
                           skip       - No tests
  -t, --test TYPE,TYPE   Run specific test types (comma-separated):
                           phpunit, behat, phpstan, phpcs, eslint,
                           stylelint, security, accessibility

Staging Creation:
  --create-stg           Create staging site if missing (default: prompt)
  --no-create-stg        Fail if staging doesn't exist

Examples:
  # Interactive mode with TUI
  ./dev2stg.sh avc

  # Fully automated (CI/CD)
  ./dev2stg.sh avc -y --fresh-backup -t essential

  # Resume from step 5
  ./dev2stg.sh avc -s 5

  # Use existing backup, full tests
  ./dev2stg.sh avc --use-backup sanitized-20260103.sql.gz -t full
```

### Interactive TUI Design

When run without `-y`, the script presents an interactive terminal UI:

```
╔══════════════════════════════════════════════════════════════════╗
║                    dev2stg Deployment Planner                     ║
╠══════════════════════════════════════════════════════════════════╣
║ Source: avc (development)                                         ║
║ Target: avc_stg (staging)                                         ║
╚══════════════════════════════════════════════════════════════════╝

━━━ Current State ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✓ Development site: Running (avc.ddev.site)
  ✓ Staging site: Exists but stopped
  ✓ Recent backup: sanitized-20260103T142355.sql.gz (2 hours ago)
  ✓ Production: Accessible (avc.nwpcode.org)
  ✓ Tests available: 30 features, 134 scenarios

━━━ Proposed Plan ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [1] Start staging DDEV
  [2] Export dev config
  [3] Sync code to staging
  [4] Use existing sanitized backup (recommended)
  [5] Run composer install --no-dev
  [6] Run database updates
  [7] Import configuration
  [8] Set production mode
  [9] Run essential tests
  [10] Display staging URL

━━━ Options ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [E] Execute plan as shown
  [D] Change database source
  [T] Change test level (current: essential)
  [S] Skip to step...
  [V] View step details
  [Q] Quit

Select option: _
```

**Database Source Sub-menu:**
```
━━━ Database Source ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [1] Use existing backup: sanitized-20260103T142355.sql.gz (2h ago) ★
  [2] Create fresh backup from production
  [3] Use development database (no prod data)
  [4] Select from backup history...
  [B] Back to main menu

★ = recommended
```

**Test Level Sub-menu:**
```
━━━ Test Selection ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Presets:
  [1] quick      (~1 min)  - PHPCS, ESLint syntax checks
  [2] essential  (~5 min)  - PHPUnit, PHPStan, PHPCS ★
  [3] functional (~15 min) - Behat BDD scenarios
  [4] full       (~30 min) - All test types
  [5] security   (~3 min)  - Security + static analysis
  [6] skip                 - No tests

Individual Tests (toggle with space, multi-select):
  [ ] phpunit       PHPUnit unit/integration tests
  [ ] behat         Behat BDD scenario tests
  [ ] phpstan       PHPStan static analysis
  [ ] phpcs         PHP CodeSniffer style checks
  [ ] eslint        JavaScript/TypeScript linting
  [ ] stylelint     CSS/SCSS linting
  [ ] security      Security vulnerability scan
  [ ] accessibility WCAG accessibility checks

  [C] Confirm selection
  [B] Back to main menu

★ = recommended
```

---

## Comparison with Pleasy and Vortex

| Feature | Current NWP | Pleasy | Vortex | Proposed NWP |
|---------|-------------|--------|--------|--------------|
| **Auto-create staging** | No | No | No | ✓ Yes |
| **Sanitized backup detection** | Manual | Manual | Timestamp cache | ✓ Auto-detect |
| **Multi-source DB download** | Single | Single | ✓ Router pattern | ✓ Router pattern |
| **TUI interface** | None | Step only | Installer wizard | ✓ Full TUI |
| **-y automation flag** | ✓ Yes | ✓ Yes | ✓ Yes | ✓ Yes |
| **Step resume (-s N)** | ✓ Yes | ✓ Yes | No | ✓ Enhanced |
| **Config import retry** | 1x | 3x | 1x | ✓ 3x (Pleasy) |
| **Multi-tier testing** | No | No | ✓ 4-tier | ✓ 8 test types |
| **Test presets** | No | No | No | ✓ 5 presets |
| **Doctor/preflight** | No | No | ✓ Yes | ✓ Yes (Vortex) |
| **Standardized output** | No | No | ✓ info/pass/fail | ✓ Adopted |
| **CI/CD caching** | No | No | ✓ Timestamp keys | ✓ Adopted |
| **Notification channels** | No | No | ✓ 6 channels | Future phase |

### Features Adopted from Pleasy

1. **Config Import Resilience**: Run `drush cim` up to 3 times to handle dependency ordering issues
2. **Step-Based Recovery**: Enhanced `-s N` flag for resuming failed deployments
3. **Debug Mode**: Verbose output with `-d` flag showing all operations
4. **Rsync Exclusions**: Comprehensive exclusion list protecting settings.php, files/, etc.

### Features Adopted from Vortex

1. **Multi-Tier Testing System**: 8 distinct test types with 5 presets (quick, essential, functional, full, security)
2. **Router Pattern for Database Sources**: Modular download-db dispatcher supporting multiple sources
3. **Standardized Output Formatting**: Consistent `info()`, `pass()`, `fail()`, `task()`, `note()` functions
4. **Doctor/Preflight Command**: System validation before operations (`./dev2stg.sh --preflight`)
5. **CI/CD Database Caching**: Timestamp-based cache keys with fallback strategy
6. **Maintenance Mode Management**: Automatic site locking during provisioning

### NWP Innovations Beyond Both

1. **Intelligent State Detection**: Automatic discovery of staging site, backups, and production access
2. **Auto-Create Staging**: Create `_stg` site on-the-fly if missing
3. **Integrated Planning TUI**: Interactive plan review and modification (not just prompts or wizard)
4. **Backup Age Intelligence**: Automatic selection based on backup freshness
5. **Combined Workflow**: Single script handles detection → creation → sync → test

---

## Implementation Phases

### Phase 1: Core Enhancements
- State detection functions
- Auto-create staging site capability
- Sanitized backup detection and selection
- Enhanced `-y` mode with intelligent defaults

### Phase 2: TUI Development
- Interactive menu system using bash select/dialog
- Real-time state display
- Plan modification interface
- Progress indicators during execution

### Phase 3: Test Integration
- Test suite detection
- Essential vs full test selection
- Test result reporting
- Failure handling (continue vs abort)

### Phase 4: Advanced Features
- Parallel rsync for large sites
- Incremental backup detection
- Rollback capability
- CI/CD webhook integration

---

## Vortex-Inspired Enhancements

### Standardized Output Formatting

Adopt Vortex's consistent, color-aware output system:

```bash
# lib/output.sh - Standardized output functions

# Detect color support
if [ "${TERM:-}" != "dumb" ] && command -v tput &>/dev/null && tput colors &>/dev/null; then
    COLOR_BLUE="\033[34m"
    COLOR_GREEN="\033[32m"
    COLOR_RED="\033[31m"
    COLOR_YELLOW="\033[33m"
    COLOR_RESET="\033[0m"
else
    COLOR_BLUE="" COLOR_GREEN="" COLOR_RED="" COLOR_YELLOW="" COLOR_RESET=""
fi

info()  { printf "${COLOR_BLUE}[INFO]${COLOR_RESET} %s\n" "$1"; }
pass()  { printf "${COLOR_GREEN}[ OK ]${COLOR_RESET} %s\n" "$1"; }
fail()  { printf "${COLOR_RED}[FAIL]${COLOR_RESET} %s\n" "$1"; }
warn()  { printf "${COLOR_YELLOW}[WARN]${COLOR_RESET} %s\n" "$1"; }
task()  { printf "  > %s\n" "$1"; }
note()  { printf "    %s\n" "$1"; }
```

**Usage in dev2stg.sh:**
```bash
info "Starting deployment: $sitename → ${sitename}_stg"
task "Exporting configuration from dev..."
pass "Configuration exported successfully"
task "Syncing files to staging..."
fail "Rsync failed with exit code 23"
note "Hint: Check disk space on target"
```

### Doctor/Preflight Command

Pre-deployment validation inspired by Vortex's doctor.sh:

```bash
# ./dev2stg.sh --preflight avc

preflight_check() {
    local sitename="$1"
    local stg_name="${sitename}_stg"
    local errors=0

    info "Running preflight checks for $sitename → $stg_name"

    # 1. DDEV availability
    task "Checking DDEV installation..."
    if command -v ddev &>/dev/null; then
        pass "DDEV $(ddev version | head -1)"
    else
        fail "DDEV not found"; ((errors++))
    fi

    # 2. Source site status
    task "Checking source site ($sitename)..."
    if (cd "$sitename" 2>/dev/null && ddev describe &>/dev/null); then
        pass "Source site running"
    else
        fail "Source site not running or not found"; ((errors++))
    fi

    # 3. Database connectivity
    task "Checking database connectivity..."
    if (cd "$sitename" && ddev drush sql:query "SELECT 1" &>/dev/null); then
        pass "Database accessible"
    else
        fail "Cannot connect to database"; ((errors++))
    fi

    # 4. Disk space
    task "Checking disk space..."
    local free_gb=$(df -BG . | awk 'NR==2 {print $4}' | tr -d 'G')
    if [ "$free_gb" -ge 5 ]; then
        pass "Disk space: ${free_gb}GB free"
    else
        warn "Low disk space: ${free_gb}GB free (recommend 5GB+)"
    fi

    # 5. Production accessibility (if configured)
    if has_live_config "$sitename"; then
        task "Checking production SSH access..."
        if check_prod_ssh "$sitename"; then
            pass "Production accessible"
        else
            warn "Production not accessible (backup sync unavailable)"
        fi
    fi

    # 6. Required tools
    for tool in rsync composer git; do
        task "Checking $tool..."
        if command -v "$tool" &>/dev/null; then
            pass "$tool available"
        else
            fail "$tool not found"; ((errors++))
        fi
    done

    echo ""
    if [ "$errors" -eq 0 ]; then
        pass "All preflight checks passed"
        return 0
    else
        fail "$errors preflight check(s) failed"
        return 1
    fi
}
```

### Multi-Source Database Router Pattern

Inspired by Vortex's download-db router:

```bash
# lib/database-router.sh

download_database() {
    local sitename="$1"
    local source="$2"  # auto | production | backup:FILE | development | url:URL

    case "$source" in
        auto)
            # Intelligent source selection
            if recent_backup_exists "$sitename"; then
                download_database "$sitename" "backup:$(get_recent_backup "$sitename")"
            elif prod_accessible "$sitename"; then
                download_database "$sitename" "production"
            else
                download_database "$sitename" "development"
            fi
            ;;

        production)
            info "Downloading from production..."
            download_db_production "$sitename"
            ;;

        backup:*)
            local file="${source#backup:}"
            info "Restoring from backup: $file"
            download_db_backup "$sitename" "$file"
            ;;

        development)
            info "Cloning development database..."
            download_db_development "$sitename"
            ;;

        url:*)
            local url="${source#url:}"
            info "Downloading from URL: $url"
            download_db_url "$sitename" "$url"
            ;;

        *)
            fail "Unknown database source: $source"
            return 1
            ;;
    esac
}

# Individual source handlers
download_db_production() {
    local sitename="$1"
    local live_config=$(get_live_config "$sitename")
    local ssh_host=$(echo "$live_config" | yq '.ssh_host')
    local ssh_user=$(echo "$live_config" | yq '.ssh_user')

    # Create sanitized backup on production
    ssh "${ssh_user}@${ssh_host}" "cd /var/www/${sitename} && drush sql:dump --gzip" \
        > "sitebackups/${sitename}/prod-$(date +%Y%m%dT%H%M%S).sql.gz"

    # Sanitize locally
    sanitize_database "$sitename"
}

download_db_backup() {
    local sitename="$1"
    local file="$2"

    if [[ "$file" == *.gz ]]; then
        gunzip -c "$file" | ddev drush sql:cli
    else
        ddev drush sql:cli < "$file"
    fi
}
```

---

## Database Sanitization Strategy

### Sanitization Rules

Based on GDPR compliance and development safety:

```bash
sanitize_database() {
    local db_file="$1"

    # 1. Truncate unnecessary tables
    ddev drush sql:query "TRUNCATE TABLE cache_*"
    ddev drush sql:query "TRUNCATE TABLE watchdog"
    ddev drush sql:query "TRUNCATE TABLE sessions"
    ddev drush sql:query "TRUNCATE TABLE flood"

    # 2. Anonymize user data
    ddev drush sql:query "
        UPDATE users_field_data
        SET mail = CONCAT('user', uid, '@example.com'),
            name = CONCAT('user', uid)
        WHERE uid > 1"

    # 3. Reset admin password
    ddev drush upwd admin admin

    # 4. Clear sensitive config
    ddev drush cdel system.mail
    ddev drush cdel smtp.settings

    # 5. Export sanitized database
    ddev drush sql:dump --gzip > "$db_file"
}
```

### Backup Naming Convention

```
sitebackups/<sitename>/sanitized/<timestamp>-<branch>-<commit>.sql.gz
```

Example: `sitebackups/avc/sanitized/20260103T142355-main-a1b2c3d.sql.gz`

---

## Recommended Final Implementation

### Script Structure

```
dev2stg.sh
├── lib/dev2stg/
│   ├── state.sh        # State detection functions
│   ├── staging.sh      # Staging site creation
│   ├── database.sh     # Database backup/restore
│   ├── sync.sh         # Code synchronization
│   ├── tests.sh        # Test suite integration
│   └── tui.sh          # Terminal UI components
```

### Key Recommendations

1. **Default to Safety**: Always sanitize production data by default
2. **Prefer Existing Resources**: Use recent backups before creating new ones (saves time)
3. **Essential Tests by Default**: Run critical tests in `-y` mode, skip in interactive
4. **Clear Progress Indication**: Show what step is running and percentage complete
5. **Graceful Failure Handling**: On error, save state for `-s N` resume
6. **Logging**: Write detailed log to `logs/dev2stg-<timestamp>.log`

### Example Automated CI/CD Usage

```yaml
# .gitlab-ci.yml
deploy_staging:
  script:
    - ./dev2stg.sh avc -y --fresh-backup -t essential
  only:
    - develop

deploy_staging_full_test:
  script:
    - ./dev2stg.sh avc -y --fresh-backup -t full
  only:
    - main
  when: manual
```

---

## Final Recommendations

Based on analysis of Pleasy, Vortex, and current NWP architecture:

### Priority 1: Core Workflow (Implement First)
1. **State Detection** - Auto-detect staging existence, backup freshness, production access
2. **Auto-Create Staging** - Create `_stg` site on-the-fly with proper DDEV configuration
3. **Database Router** - Unified source selection (production, backup, development, URL)
4. **Standardized Output** - Adopt Vortex's info/pass/fail/task/note formatting

### Priority 2: Testing Integration
1. **Multi-Tier Test System** - 8 test types (phpunit, behat, phpstan, phpcs, eslint, stylelint, security, accessibility)
2. **Test Presets** - quick, essential, functional, full, security-only
3. **CLI Integration** - `-t preset` or `-t type,type` syntax
4. **Test Result Summary** - Clear pass/fail counts with failure details

### Priority 3: User Experience
1. **TUI Interface** - Interactive plan review with modification options
2. **Doctor/Preflight** - Pre-deployment validation (`--preflight` flag)
3. **Step Resume** - Enhanced `-s N` with state persistence
4. **Progress Indicators** - Step count and percentage during execution

### Priority 4: Future Enhancements
1. **Notification Channels** - Slack, email, webhook on completion (adopt from Vortex)
2. **CI/CD Caching** - Timestamp-based backup cache keys for faster pipelines
3. **Rollback Capability** - Quick restore to pre-deployment state
4. **Parallel Operations** - Concurrent rsync for large sites

### What NOT to Adopt

From **Pleasy**:
- Tar-based production deployment (NWP's rsync approach is cleaner)
- Separate `sandb.sh` script (integrate sanitization into router)

From **Vortex**:
- Token-based templating (overkill for NWP's simpler structure)
- Docker image database embedding (DDEV handles this differently)
- Multi-hosting abstraction (NWP targets Linode specifically)

---

## Summary

This proposal enhances `dev2stg.sh` to be a comprehensive, intelligent deployment tool that:

1. **Automatically detects** what exists (staging site, backups, production access)
2. **Creates staging sites** on-the-fly if they don't exist
3. **Intelligently selects** the best database source via router pattern
4. **Integrates 8 test types** with 5 presets directly into the deployment workflow
5. **Supports both** fully automated (`-y`) and interactive (TUI) execution
6. **Adopts best practices** from Pleasy (retry logic, step resume) and Vortex (output formatting, doctor command, multi-tier testing)
7. **Adds NWP innovations** (intelligent state detection, auto-staging creation, backup age intelligence)

### Quick Reference: New Command Examples

```bash
# Interactive mode (shows TUI with all options)
./dev2stg.sh avc

# Automated with essential tests
./dev2stg.sh avc -y -t essential

# Specific test types only
./dev2stg.sh avc -y -t phpunit,phpstan

# Fresh production backup, full tests
./dev2stg.sh avc -y --fresh-backup -t full

# Quick syntax check before commit
./dev2stg.sh avc -y -t quick

# Pre-flight check only (no deployment)
./dev2stg.sh avc --preflight

# Resume from step 5 after fixing an error
./dev2stg.sh avc -s 5
```

The result is a deployment script that "just works" for most cases while providing full control when needed, combining the best of Pleasy's reliability, Vortex's polish, and NWP's intelligent automation.
