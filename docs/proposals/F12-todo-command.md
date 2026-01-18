# F12: Unified Todo Command

**Status:** IMPLEMENTED
**Created:** 2026-01-17
**Updated:** 2026-01-17
**Author:** Claude Opus 4.5 (architectural design), Rob (requirements)
**Priority:** Medium
**Estimated Effort:** 3-4 weeks
**Breaking Changes:** None

> **Implementation Note:** F12 was fully implemented on 2026-01-17. The following files were created:
> - `scripts/commands/todo.sh` - Main command
> - `lib/todo-checks.sh` - 13 check functions
> - `lib/todo-tui.sh` - Interactive TUI mode
> - `lib/todo-notify.sh` - Notification functions
> - `lib/todo-autolog.sh` - Auto-resolution hooks
> - Configuration added to `example.nwp.yml` under `settings.todo`
> - Verification items added to `.verification.yml`

---

## 1. Executive Summary

### 1.1 Problem Statement

NWP manages multiple resources (sites, servers, tokens, backups) but lacks a unified view of pending tasks and maintenance items. Currently, users must manually check:

- GitLab issues
- Test instances that should be deleted
- API tokens needing rotation
- Orphaned/ghost sites
- Missing backups
- Security updates
- Verification failures

This leads to forgotten maintenance tasks, stale test instances consuming resources, and security risks from unrotated tokens.

### 1.2 Proposed Solution

Create a `pl todo` command that:

1. **Aggregates todos** from 13 different sources into a unified view
2. **Prioritizes items** by severity (high/medium/low)
3. **Provides TUI mode** for interactive management
4. **Supports notifications** via desktop and email
5. **Auto-resolves items** when conditions are met
6. **Runs on schedule** via cron for proactive maintenance alerts

### 1.3 Key Benefits

| Benefit | Description |
|---------|-------------|
| **Single pane of glass** | All maintenance tasks in one view |
| **Proactive alerts** | Notifications before issues become critical |
| **Resource cleanup** | Automatic detection of stale test instances |
| **Security hygiene** | Token rotation reminders |
| **Reduced cognitive load** | No need to remember multiple check commands |

---

## 2. Architecture

### 2.1 System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         pl todo                                  │
│                    UNIFIED TODO SYSTEM                           │
└──────────────────────────────┬──────────────────────────────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        ▼                      ▼                      ▼
┌───────────────┐    ┌───────────────────┐    ┌───────────────┐
│  TODO SOURCES │    │   TODO STORAGE    │    │   OUTPUTS     │
│               │    │                   │    │               │
│ - GitLab API  │    │ nwp.yml:         │    │ - CLI text    │
│ - nwp.yml    │    │   todo:           │    │ - TUI mode    │
│ - crontab     │    │     settings:     │    │ - Desktop     │
│ - filesystem  │    │     ignored:      │    │ - Email       │
│ - DDEV        │    │     tokens:       │    │ - Cron log    │
│ - git status  │    │                   │    │               │
│ - security.sh │    │ Cache:            │    │               │
│ - verify.sh   │    │ /tmp/nwp-todo-*   │    │               │
└───────────────┘    └───────────────────┘    └───────────────┘
```

### 2.2 Todo Categories

| ID | Category | Source | Priority | Auto-Resolve |
|----|----------|--------|----------|--------------|
| `GIT` | GitLab Issues | GitLab API | Medium | When closed |
| `TST` | Test Instances | nwp.yml purpose=testing | Medium | When deleted |
| `TOK` | Token Rotation | nwp.yml todo.tokens | Medium | When rotated |
| `ORP` | Orphaned Sites | .ddev vs nwp.yml | Low | When registered/deleted |
| `GHO` | Ghost Sites | DDEV registry | High | When cleaned |
| `INC` | Incomplete Installs | nwp.yml install_step | High | When completed |
| `BAK` | Missing Backups | backup timestamps | Medium | When backed up |
| `SCH` | Missing Schedules | crontab | Low | When scheduled |
| `SEC` | Security Updates | drush pm:security | High | When updated |
| `VER` | Verification Fails | .verification.yml | Low | When passing |
| `GWK` | Uncommitted Work | git status | Low | When committed |
| `DSK` | Disk Usage | df | Medium | When space freed |
| `SSL` | SSL Expiring | openssl | High | When renewed |

### 2.3 Priority Calculation

```
HIGH (action required within 24 hours):
  - Security updates available
  - SSL expiring < 7 days
  - Ghost sites (broken DDEV state)
  - Incomplete installations > 24 hours old

MEDIUM (action required within 7 days):
  - Token rotation due (> rotation_days setting)
  - Test instances > alert_days setting
  - Missing backups > backup_warn_days
  - Disk usage > warn_percent
  - GitLab issues assigned to user

LOW (informational):
  - Orphaned sites
  - Verification failures
  - Uncommitted work
  - Missing backup schedules
  - Test instances > warn_days but < alert_days
```

---

## 3. Configuration Schema

### 3.1 nwp.yml Settings

```yaml
todo:
  # ═══════════════════════════════════════════════════════════════
  # GENERAL SETTINGS
  # ═══════════════════════════════════════════════════════════════
  enabled: true                    # Master switch for todo system

  # ═══════════════════════════════════════════════════════════════
  # THRESHOLD SETTINGS
  # ═══════════════════════════════════════════════════════════════
  thresholds:
    test_instance_warn_days: 7     # Days before test site shows as todo
    test_instance_alert_days: 14   # Days before test site becomes HIGH priority
    token_rotation_days: 90        # Days before token rotation reminder
    backup_warn_days: 7            # Days without backup before warning
    disk_warn_percent: 80          # Disk usage percentage for warning
    disk_alert_percent: 90         # Disk usage percentage for HIGH priority
    ssl_warn_days: 30              # Days before SSL expiry for warning
    ssl_alert_days: 7              # Days before SSL expiry for HIGH priority
    incomplete_install_hours: 24   # Hours before incomplete install is HIGH

  # ═══════════════════════════════════════════════════════════════
  # AUTO-RESOLVE SETTINGS
  # ═══════════════════════════════════════════════════════════════
  auto_resolve:
    enabled: true                  # Enable auto-resolution of todos
    git_issues: true               # Auto-resolve when GitLab issue closed
    test_instances: true           # Auto-resolve when site deleted
    token_rotation: true           # Auto-resolve when token updated
    orphaned_sites: true           # Auto-resolve when registered or deleted
    ghost_sites: true              # Auto-resolve when ddev cleaned
    incomplete_installs: true      # Auto-resolve when install completes
    missing_backups: true          # Auto-resolve when backup runs
    missing_schedules: true        # Auto-resolve when schedule installed
    security_updates: true         # Auto-resolve when updates applied
    verification_fails: true       # Auto-resolve when tests pass
    uncommitted_work: true         # Auto-resolve when committed
    disk_usage: true               # Auto-resolve when space freed
    ssl_expiring: true             # Auto-resolve when renewed

  # ═══════════════════════════════════════════════════════════════
  # NOTIFICATION SETTINGS
  # ═══════════════════════════════════════════════════════════════
  notifications:
    enabled: false                 # Master switch for notifications

    desktop:
      enabled: false               # Desktop notifications (notify-send)
      min_priority: high           # Minimum priority to notify (high/medium/low)

    email:
      enabled: false               # Email notifications
      min_priority: high           # Minimum priority to email
      recipient: ""                # Email address for notifications
      smtp_profile: "default"      # SMTP profile from .secrets.yml

    # When to send notifications
    on_new_high: true              # Notify when new HIGH priority item
    on_schedule_run: true          # Include in scheduled run summary
    daily_digest: false            # Send daily digest of all items
    digest_time: "08:00"           # Time for daily digest (HH:MM)

  # ═══════════════════════════════════════════════════════════════
  # SCHEDULE SETTINGS
  # ═══════════════════════════════════════════════════════════════
  schedule:
    enabled: false                 # Enable scheduled todo checks
    cron: "0 8 * * *"              # Cron expression (default: 8 AM daily)
    log_file: "/var/log/nwp/todo.log"

  # ═══════════════════════════════════════════════════════════════
  # GITLAB INTEGRATION
  # ═══════════════════════════════════════════════════════════════
  gitlab:
    enabled: true                  # Check GitLab issues
    server: ""                     # GitLab server (default: from .secrets.yml)
    project_ids: []                # Specific projects to check (empty = all accessible)
    include_assigned: true         # Include issues assigned to you
    include_unassigned: false      # Include unassigned issues
    labels: []                     # Filter by labels (empty = all)
    exclude_labels:                # Exclude issues with these labels
      - "wontfix"
      - "on-hold"

  # ═══════════════════════════════════════════════════════════════
  # CATEGORY TOGGLES
  # ═══════════════════════════════════════════════════════════════
  categories:
    git_issues: true
    test_instances: true
    token_rotation: true
    orphaned_sites: true
    ghost_sites: true
    incomplete_installs: true
    missing_backups: true
    missing_schedules: true
    security_updates: true
    verification_fails: true
    uncommitted_work: true
    disk_usage: true
    ssl_expiring: true

  # ═══════════════════════════════════════════════════════════════
  # TOKEN TRACKING
  # ═══════════════════════════════════════════════════════════════
  tokens:
    linode:
      last_rotated: ""             # ISO8601 timestamp
      notes: ""
    cloudflare:
      last_rotated: ""
      notes: ""
    gitlab:
      last_rotated: ""
      notes: ""
    b2:
      last_rotated: ""
      notes: ""

  # ═══════════════════════════════════════════════════════════════
  # IGNORED ITEMS
  # ═══════════════════════════════════════════════════════════════
  ignored: []
  # Example ignored item:
  # - id: "ORP-001-oldsite"
  #   reason: "Keeping for reference"
  #   ignored_at: "2026-01-15T10:00:00Z"
  #   ignored_by: "rob"
  #   expires: ""                  # Optional: auto-unignore date
```

### 3.2 Default Settings in example.nwp.yml

The above schema will be added to `example.nwp.yml` with sensible defaults:
- All checks enabled
- Notifications disabled (opt-in)
- Schedule disabled (opt-in)
- Auto-resolve enabled
- 7-day test instance warning, 14-day alert
- 90-day token rotation
- 80% disk warning, 90% alert
- 30-day SSL warning, 7-day alert

---

## 4. Command Line Interface

### 4.1 Usage

```bash
pl todo [command] [options]

Commands:
  (none)              Interactive TUI mode (default)
  list                Text-based list view
  check               Run checks and show results
  resolve <id>        Mark a todo as resolved
  ignore <id>         Ignore a todo
  unignore <id>       Stop ignoring a todo
  refresh             Force refresh all checks (clear cache)
  schedule install    Install cron schedule for todo checks
  schedule remove     Remove cron schedule
  token <name>        Record token rotation (updates last_rotated)

Options:
  -a, --all           Show all details
  -c, --category=CAT  Filter by category (git,test,token,etc.)
  -p, --priority=PRI  Filter by priority (high,medium,low)
  -s, --site=SITE     Filter by site name
  -q, --quiet         Only show counts
  -j, --json          Output as JSON
  --no-cache          Skip cache, run fresh checks
  -h, --help          Show help
```

### 4.2 Example Commands

```bash
# Interactive TUI (default)
pl todo

# Text list view
pl todo list

# Show only high priority items
pl todo list --priority=high

# Show only security-related todos
pl todo list --category=security

# Mark a todo as resolved
pl todo resolve SEC-001

# Ignore an orphaned site (keeping intentionally)
pl todo ignore ORP-001 --reason="Archive site, keeping for reference"

# Record that Linode token was rotated
pl todo token linode

# Install scheduled checks
pl todo schedule install

# Force refresh (ignore cache)
pl todo refresh
```

### 4.3 Output Formats

#### Text Mode (pl todo list)

```
╔════════════════════════════════════════════════════════════════╗
║                      NWP Todo List                              ║
║                    2026-01-17 10:30:00                          ║
╚════════════════════════════════════════════════════════════════╝

HIGH PRIORITY (3 items)
────────────────────────────────────────────────────────────────────
  [SEC-001] Security update: drupal/core 10.3.1 → 10.3.2
            Site: avc | Run: pl security update avc

  [SSL-001] SSL certificate expires in 5 days
            Domain: nwpcode.org | Run: certbot renew

  [INC-001] Incomplete installation (step 4/9, 26 hours)
            Site: test-d-001 | Run: pl install -s=5 test-d-001

MEDIUM PRIORITY (2 items)
────────────────────────────────────────────────────────────────────
  [TOK-001] Token rotation due: linode (85 days old)
            Last rotated: 2025-10-24 | Threshold: 90 days

  [TST-001] Test instance is 12 days old
            Site: test-nwp | Purpose: testing | Created: 2026-01-05
            Run: pl delete test-nwp

LOW PRIORITY (4 items)
────────────────────────────────────────────────────────────────────
  [ORP-001] Orphaned site (has .ddev, not in config)
            Directory: sites/old-demo
            Run: pl todo ignore ORP-001 OR pl delete old-demo

  [VER-001] 2 verification tests failing
            Feature: backup/restore
            Run: pl verify --run --feature=backup

  [GWK-001] Uncommitted changes in site
            Site: avc | Files: 3 modified
            Run: cd sites/avc && git status

  [SCH-001] Site has no scheduled backups
            Site: ss
            Run: pl schedule install ss

════════════════════════════════════════════════════════════════════
Summary: 9 items total (3 high, 2 medium, 4 low)
         1 item ignored (use --show-ignored to display)

Run 'pl todo' for interactive mode or 'pl todo resolve <ID>'
```

#### TUI Mode (pl todo)

```
┌─ NWP Todo List ──────────────────────────────────────────────────┐
│                                                                   │
│  Filter: [All] [High] [Medium] [Low]     Sort: [Priority] [Date] │
│                                                                   │
│  ┌─ HIGH PRIORITY ─────────────────────────────────────────────┐ │
│  │ [x] SEC-001  Security update: drupal/core                   │ │
│  │ [ ] SSL-001  SSL expires in 5 days: nwpcode.org             │ │
│  │ [ ] INC-001  Incomplete install: test-d-001                 │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  ┌─ MEDIUM PRIORITY ───────────────────────────────────────────┐ │
│  │ [ ] TOK-001  Token rotation due: linode (85 days)           │ │
│  │ [ ] TST-001  Test instance: test-nwp (12 days old)          │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  ┌─ LOW PRIORITY ──────────────────────────────────────────────┐ │
│  │ [ ] ORP-001  Orphaned site: old-demo                        │ │
│  │ [ ] VER-001  Verification failing: backup (2 tests)         │ │
│  │ [ ] GWK-001  Uncommitted work: avc (3 files)                │ │
│  │ [ ] SCH-001  No backup schedule: ss                         │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
├───────────────────────────────────────────────────────────────────┤
│ [Enter] View Details  [Space] Select  [r] Resolve  [i] Ignore    │
│ [a] Select All        [f] Filter      [s] Sort     [q] Quit      │
└───────────────────────────────────────────────────────────────────┘
```

---

## 5. Implementation Details

### 5.1 File Structure

```
scripts/commands/
└── todo.sh              # Main command script (~800 lines)

lib/
├── todo-checks.sh       # Individual check functions (~600 lines)
├── todo-tui.sh          # TUI interface (~400 lines)
└── todo-notify.sh       # Notification functions (~200 lines)
```

### 5.2 Check Functions

```bash
# lib/todo-checks.sh

check_gitlab_issues()        # GitLab API query for open issues
check_test_instances()       # nwp.yml purpose=testing + created date
check_token_rotation()       # nwp.yml todo.tokens vs thresholds
check_orphaned_sites()       # Reuse from status.sh
check_ghost_sites()          # Reuse from status.sh
check_incomplete_installs()  # nwp.yml install_step analysis
check_missing_backups()      # Scan backup directories for timestamps
check_missing_schedules()    # Parse crontab for NWP entries
check_security_updates()     # Call security.sh check --all --quiet
check_verification()         # Parse .verification.yml for failures
check_uncommitted_work()     # git status in each site directory
check_disk_usage()           # df analysis against thresholds
check_ssl_expiry()           # openssl for live site domains
```

### 5.3 Caching Strategy

```bash
# Cache location
CACHE_DIR="/tmp/nwp-todo-cache"
CACHE_TTL=300  # 5 minutes default

# Per-check cache files
# /tmp/nwp-todo-cache/gitlab-issues.json
# /tmp/nwp-todo-cache/security-updates.json
# etc.

# Cache invalidation triggers:
# - Manual: pl todo refresh
# - Time-based: older than CACHE_TTL
# - Event-based: after pl delete, pl backup, etc.
```

### 5.4 Auto-Resolve Integration

Auto-resolution hooks into existing commands via lib/verify-autolog.sh pattern:

```bash
# In lib/todo-autolog.sh (new file)
# Sourced by pl wrapper after command execution

todo_check_auto_resolve() {
    local command="$1"
    local args="$2"
    local exit_code="$3"

    [[ "$exit_code" != "0" ]] && return

    case "$command" in
        delete)
            # Auto-resolve TST-* and ORP-* for deleted site
            todo_resolve_for_site "$args" "TST" "ORP"
            ;;
        backup)
            # Auto-resolve BAK-* for backed up site
            todo_resolve_for_site "$args" "BAK"
            ;;
        security)
            [[ "$args" == *"update"* ]] && todo_resolve_category "SEC"
            ;;
        schedule)
            [[ "$args" == *"install"* ]] && todo_resolve_for_site "${args##* }" "SCH"
            ;;
        verify)
            [[ "$args" == *"--run"* ]] && todo_refresh_verification
            ;;
    esac
}
```

### 5.5 Notification Implementation

```bash
# lib/todo-notify.sh

# Desktop notification (Linux)
notify_desktop() {
    local title="$1"
    local message="$2"
    local urgency="$3"  # low, normal, critical

    if command -v notify-send &>/dev/null; then
        notify-send -u "$urgency" "$title" "$message"
    fi
}

# Email notification
notify_email() {
    local subject="$1"
    local body="$2"
    local recipient
    recipient=$(get_todo_setting "notifications.email.recipient")

    # Use configured SMTP profile
    local smtp_profile
    smtp_profile=$(get_todo_setting "notifications.email.smtp_profile")

    send_email "$recipient" "$subject" "$body" "$smtp_profile"
}

# Scheduled run with notifications
todo_scheduled_run() {
    local results
    results=$(pl todo check --json)

    local high_count
    high_count=$(echo "$results" | jq '[.items[] | select(.priority=="high")] | length')

    if [[ "$high_count" -gt 0 ]]; then
        local notify_desktop
        notify_desktop=$(get_todo_setting "notifications.desktop.enabled")
        [[ "$notify_desktop" == "true" ]] && \
            notify_desktop "NWP Todo" "$high_count high priority items need attention" "critical"

        local notify_email
        notify_email=$(get_todo_setting "notifications.email.enabled")
        [[ "$notify_email" == "true" ]] && \
            notify_email "[NWP] $high_count high priority todos" "$(pl todo list --priority=high)"
    fi

    # Log results
    echo "[$(date -Iseconds)] Checked: $(echo "$results" | jq '.summary')" >> /var/log/nwp/todo.log
}
```

---

## 6. Integration Points

### 6.1 Existing Commands

| Command | Integration |
|---------|-------------|
| `pl delete` | Auto-resolve TST-*, ORP-* for deleted site |
| `pl backup` | Auto-resolve BAK-* for backed up site |
| `pl schedule install` | Auto-resolve SCH-* for scheduled site |
| `pl security update` | Auto-resolve SEC-* after update |
| `pl verify --run` | Refresh VER-* status |
| `pl install` | Auto-resolve INC-* on completion |
| `git commit` (in sites) | Auto-resolve GWK-* |

### 6.2 Existing Libraries

| Library | Usage |
|---------|-------|
| `lib/ui.sh` | Output formatting, colors |
| `lib/common.sh` | Validation, user input |
| `lib/yaml-write.sh` | nwp.yml read/write |
| `lib/linode.sh` | Token validation (optional) |
| `lib/checkbox.sh` | TUI checkbox selection |
| `lib/tui.sh` | TUI framework |
| `lib/verify-autolog.sh` | Pattern for auto-logging |

### 6.3 GitLab API Integration

```bash
# Uses existing .secrets.yml gitlab configuration
get_gitlab_issues() {
    local api_token
    api_token=$(get_infra_secret "gitlab.api_token" "")

    local server
    server=$(get_infra_secret "gitlab.server.domain" "")

    [[ -z "$api_token" || -z "$server" ]] && return 1

    # Get issues assigned to current user
    local user_id
    user_id=$(curl -s -H "PRIVATE-TOKEN: $api_token" \
        "https://$server/api/v4/user" | jq -r '.id')

    curl -s -H "PRIVATE-TOKEN: $api_token" \
        "https://$server/api/v4/issues?assignee_id=$user_id&state=opened"
}
```

---

## 7. Testing Plan

### 7.1 Unit Tests

| Test | Description |
|------|-------------|
| `test_check_test_instances` | Verify detection of old test sites |
| `test_check_token_rotation` | Verify token age calculation |
| `test_priority_calculation` | Verify priority assignment logic |
| `test_auto_resolve` | Verify auto-resolution triggers |
| `test_ignore_persist` | Verify ignored items persist across runs |
| `test_cache_invalidation` | Verify cache TTL and manual refresh |

### 7.2 Integration Tests

| Test | Description |
|------|-------------|
| `test_gitlab_integration` | Test with real GitLab API (if configured) |
| `test_full_check_cycle` | Run all checks, verify output format |
| `test_tui_navigation` | Test TUI keyboard navigation |
| `test_scheduled_run` | Test cron execution and logging |

### 7.3 Verification Items

Add to `.verification.yml`:

```yaml
todo:
  name: "Todo Command"
  items:
    - text: "pl todo shows test instances older than threshold"
      machine:
        checks:
          basic:
            command: "pl todo list --category=test --quiet"
            validates: exit_code
    - text: "pl todo resolve marks item as resolved"
      machine:
        checks:
          standard:
            command: "pl todo resolve TEST-ID && pl todo list --json | jq '.items[] | select(.id==\"TEST-ID\")'"
            validates: empty_output
    - text: "pl todo TUI launches without error"
      human:
        prompts:
          - "Run pl todo and verify TUI displays correctly"
          - "Navigate with arrow keys and select items"
```

---

## 8. Rollout Plan

### Phase 1: Core Implementation (Week 1-2)
- [ ] Create `scripts/commands/todo.sh`
- [ ] Create `lib/todo-checks.sh` with all check functions
- [ ] Add `todo` section to `example.nwp.yml`
- [ ] Implement text list mode (`pl todo list`)
- [ ] Implement resolve/ignore commands
- [ ] Add caching layer

### Phase 2: TUI Mode (Week 2-3)
- [ ] Create `lib/todo-tui.sh`
- [ ] Implement interactive checkbox interface
- [ ] Add filter and sort controls
- [ ] Add detail view for selected items
- [ ] Add bulk actions (resolve all, etc.)

### Phase 3: Notifications & Scheduling (Week 3-4)
- [ ] Create `lib/todo-notify.sh`
- [ ] Implement desktop notifications
- [ ] Implement email notifications
- [ ] Add cron schedule management
- [ ] Create `lib/todo-autolog.sh` for auto-resolution

### Phase 4: Integration & Testing (Week 4)
- [ ] Add auto-resolve hooks to existing commands
- [ ] Add verification items to `.verification.yml`
- [ ] Write unit and integration tests
- [ ] Update documentation
- [ ] Update `pl` help text

---

## 9. Documentation Updates

| File | Changes |
|------|---------|
| `CLAUDE.md` | Add todo command to release checklist |
| `docs/COMMAND_INVENTORY.md` | Add todo command documentation |
| `example.nwp.yml` | Add todo section with defaults |
| `README.md` | Mention todo command in features |
| `lib/README.md` | Document new todo libraries |

---

## 10. Future Enhancements

Not in scope for F12, but potential future additions:

- **F12.1**: Slack/Discord notifications
- **F12.2**: Web dashboard view
- **F12.3**: Custom todo items (user-defined tasks)
- **F12.4**: Todo dependencies (item A requires B first)
- **F12.5**: Team/multi-user todo sharing
- **F12.6**: GitHub integration (in addition to GitLab)

---

## 11. Decision Log

| Decision | Rationale |
|----------|-----------|
| GitLab only (not GitHub) | Primary git server is GitLab; GitHub can be added later |
| Auto-resolve opt-in per category | Gives users control over automation behavior |
| TUI as default mode | Matches existing pl status pattern |
| Caching with 5-min TTL | Balance freshness vs. performance |
| Notifications disabled by default | Opt-in to avoid unwanted alerts |
| Store config in nwp.yml | Single source of truth, familiar pattern |

---

## Appendix A: Complete Settings Reference

See Section 3.1 for the full `nwp.yml` schema with all settings documented.

## Appendix B: Category ID Format

```
<CATEGORY>-<SEQUENCE>[-<QUALIFIER>]

Examples:
  SEC-001              # First security update
  TST-001-testnwp      # Test instance "test-nwp"
  TOK-001-linode       # Linode token rotation
  ORP-001-olddemo      # Orphaned site "old-demo"
  GIT-042              # GitLab issue #42
```

---

**Last Updated:** 2026-01-17
