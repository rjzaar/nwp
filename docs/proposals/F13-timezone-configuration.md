# F13: Timezone Configuration

**Status:** IMPLEMENTED
**Created:** 2026-01-31
**Author:** Rob, Claude Opus 4.5
**Priority:** Medium
**Depends On:** None
**Breaking Changes:** No - additive feature

---

## 1. Executive Summary

### 1.1 Problem Statement

Timezone configuration is hardcoded across 14+ scripts in 3 different values (`America/New_York`, `Australia/Sydney`, `UTC`). There is no central configuration, making it impossible to change timezone behaviour without editing multiple files. Scripts that generate cron jobs, set server timezones, or display timestamps all make independent assumptions about what timezone to use.

**Current hardcoded timezones:**

| Timezone | Where | Count |
|---|---|---|
| `America/New_York` | Linode StackScripts, GitLab setup, renovate.json | 9 files |
| `Australia/Sydney` | fin-monitor cron and day-of-week check | 2 files |
| `UTC` | DDEV `.env.base`, test fixtures | 2 files |

### 1.2 Proposed Solution

Add a global default timezone setting to `nwp.yml` under `settings:` with per-site overrides under `sites:`. All scripts that need timezone information read from configuration using the existing YAML helper functions.

```
sites.<name>.timezone  →  settings.timezone  →  UTC (hardcoded default)
```

### 1.3 Key Benefits

| Benefit | Description |
|---------|-------------|
| Single source of truth | One place to set timezone for the entire NWP deployment |
| Per-site flexibility | Sites serving different regions can have different timezones |
| Consistent cron scheduling | All cron jobs use the configured timezone |
| Correct timestamps | Logs, backups, and status displays use the right timezone |
| Server provisioning | New Linode servers automatically get the correct timezone |

---

## 2. Configuration Schema

### 2.1 Global Default (settings section)

```yaml
settings:
  timezone: Australia/Sydney  # [ACTIVE] Default timezone for cron, scheduling, display
```

This value is used by:
- Server provisioning (Linode StackScripts)
- Cron job scheduling (backup, monitoring, fin-monitor)
- GitLab Rails configuration
- Timestamp display in status commands
- DDEV container timezone

### 2.2 Per-Site Override (sites section)

```yaml
sites:
  mysite:
    timezone: America/New_York  # [ACTIVE] Override settings.timezone for this site
```

Per-site timezone is used for:
- Drupal site timezone configuration during install
- Site-specific cron jobs (e.g. Drupal cron, cache clear)
- Backup scheduling for individual sites
- Status display for site-specific commands

### 2.3 No Recipe-Level Timezone

Recipes do not have timezone settings. Sites created from any recipe inherit the global `settings.timezone` default unless explicitly overridden per-site. Timezone is a deployment concern, not a recipe concern.

---

## 3. Inheritance Chain

```
┌─────────────────────────────────────────────────────────┐
│  SITE-LEVEL OVERRIDE                                    │
│  sites.<site_name>.timezone                             │
│  (via yaml_get_site_field)                              │
└─────────────────────────────────────────────────────────┘
                         ↓ (if not set)
┌─────────────────────────────────────────────────────────┐
│  GLOBAL DEFAULT                                         │
│  settings.timezone                                      │
│  (via yaml_get_setting)                                 │
└─────────────────────────────────────────────────────────┘
                         ↓ (if not set)
┌─────────────────────────────────────────────────────────┐
│  HARDCODED FALLBACK                                     │
│  UTC                                                    │
└─────────────────────────────────────────────────────────┘
```

---

## 4. Accessing Timezone in Scripts

Any NWP script can get the effective timezone using the existing YAML helper pattern:

### 4.1 For a Specific Site

```bash
# Get timezone for a site (falls back to global, then UTC)
get_site_timezone() {
    local site_name="$1"
    local config_file="${2:-$NWP_DIR/nwp.yml}"
    local tz

    tz=$(yaml_get_site_field "$site_name" "timezone" "$config_file" 2>/dev/null)
    if [[ -z "$tz" || "$tz" == "null" ]]; then
        tz=$(yaml_get_setting "timezone" "$config_file" 2>/dev/null)
    fi
    echo "${tz:-UTC}"
}
```

### 4.2 For Global/Server Operations

```bash
# Get global timezone (falls back to UTC)
get_default_timezone() {
    local config_file="${1:-$NWP_DIR/nwp.yml}"
    local tz
    tz=$(yaml_get_setting "timezone" "$config_file" 2>/dev/null)
    echo "${tz:-UTC}"
}
```

### 4.3 Usage Examples

```bash
# In cron generation
tz=$(get_default_timezone)
echo "CRON_TZ=$tz" >> /tmp/newcron

# In site status display
tz=$(get_site_timezone "$site_name")
echo "Current time: $(TZ=$tz date)"

# In Drupal install (site timezone)
tz=$(get_site_timezone "$site_name")
drush config:set system.date timezone.default "$tz"

# In server provisioning
tz=$(get_default_timezone)
timedatectl set-timezone "$tz"

# In backup scheduling
tz=$(get_default_timezone)
echo "# Backups run in $tz timezone"
```

---

## 5. Affected Scripts

### 5.1 Linode Server Provisioning (6 files)

All currently hardcode `America/New_York` as the default timezone:

| File | Line | Current | Change |
|---|---|---|---|
| `linode/linode_setup.sh` | 694 | `timezone: "America/New_York"` | Read from `settings.timezone` |
| `linode/linode_create_test_server.sh` | 160 | `timezone: "America/New_York"` | Read from `settings.timezone` |
| `linode/gitlab/gitlab_create_server.sh` | 285 | `timezone: "America/New_York"` | Read from `settings.timezone` |
| `linode/gitlab/gitlab_setup.sh` | 689 | `timezone: "America/New_York"` | Read from `settings.timezone` |
| `linode/gitlab/setup_gitlab_site.sh` | 287 | `timezone: "America/New_York"` | Read from `settings.timezone` |
| `linode/gitlab/gitlab_server_setup.sh` | 31 | UDF default `America/New_York` | Pass configured timezone to StackScript |

### 5.2 Server Setup Scripts (3 files)

These set the OS timezone via `timedatectl` using the UDF parameter:

| File | Line | Current | Change |
|---|---|---|---|
| `linode/linode_server_setup.sh` | 181 | `timedatectl set-timezone "$TIMEZONE"` | No change (already dynamic via UDF) |
| `linode/gitlab/gitlab_server_setup.sh` | 206 | `timedatectl set-timezone "$TIMEZONE"` | No change (already dynamic) |
| `linode/podcast_server_setup.sh` | 177 | `timedatectl set-timezone "$TIMEZONE"` | No change (already dynamic) |

The change for these is in the **calling scripts** that pass the timezone UDF value.

### 5.3 GitLab Configuration

| File | Line | Current | Change |
|---|---|---|---|
| `linode/gitlab/gitlab_server_setup.sh` | 280 | `gitlab_rails['time_zone'] = '$TIMEZONE'` | No change (already uses UDF variable) |

### 5.4 Financial Monitor (3 files)

| File | Line | Current | Change |
|---|---|---|---|
| `fin/fin-monitor.sh` | 513 | `TZ=Australia/Sydney date +%u` | Read from `fin-monitor.conf` |
| `fin/setup-fin-monitor.sh` | 217 | `CRON_TZ=Australia/Sydney` | Read from `fin-monitor.conf` |
| `fin/deploy-fin-monitor.sh` | — | Doesn't extract timezone | Read `settings.timezone`, write to conf |

### 5.5 Scheduling and Environment

| File | Line | Current | Change |
|---|---|---|---|
| `scripts/commands/schedule.sh` | 26-28 | Cron times with no TZ awareness | Add `CRON_TZ` to generated cron entries |
| `templates/env/.env.base` | 98 | `TZ=UTC` | Read from `settings.timezone` |
| `linode/server_scripts/nwp-cron.conf` | 31 | "All times are in server's local timezone" | Add `CRON_TZ` header |

### 5.6 Other

| File | Current | Change |
|---|---|---|
| `renovate.json` | `"timezone": "America/New_York"` | Manual update (JSON, not bash-readable) |
| `tests/fixtures/sample-site/.ddev/config.yaml` | `timezone: UTC` | Keep as-is (test fixture) |

---

## 6. Changes to nwp.yml

### 6.1 Add to settings section

```yaml
settings:
  # === TIMEZONE [ACTIVE] ===
  timezone: Australia/Sydney  # [ACTIVE] Default timezone for servers, cron, scheduling
                              # Used by: server provisioning, cron jobs, status display
                              # Override per-site in sites.<name>.timezone
                              # Valid values: any IANA timezone (e.g. Australia/Sydney, America/New_York, UTC)
```

### 6.2 Document in sites section (example.nwp.yml)

```yaml
sites:
  mysite:
    # timezone: America/New_York  # [ACTIVE] Override settings.timezone for this site
                                  # Affects: Drupal timezone, site cron, backup schedule
```

---

## 7. Implementation Phases

### Phase 1: Configuration and Documentation (this proposal)

1. Add `settings.timezone` to `nwp.yml` and `example.nwp.yml`
2. Create helper functions `get_default_timezone()` and `get_site_timezone()` in a shared library
3. Update `fin/deploy-fin-monitor.sh` to read timezone from nwp.yml
4. Update `fin/fin-monitor.sh` and `fin/setup-fin-monitor.sh` to use conf-based timezone
5. Redeploy fin-monitor

### Phase 2: Server Provisioning

6. Update 6 Linode setup/create scripts to read timezone from nwp.yml instead of hardcoding
7. Update `nwp-cron.conf` template with `CRON_TZ` header

### Phase 3: Scheduling and Sites

8. Update `schedule.sh` to include `CRON_TZ` in generated cron entries
9. Update `env-generate.sh` / `.env.base` to use configured timezone
10. Add timezone setting during Drupal site install (`drush config:set system.date timezone.default`)

---

## 8. Success Criteria

- [ ] `settings.timezone` documented in `nwp.yml` and `example.nwp.yml`
- [ ] `sites.<name>.timezone` per-site override documented in `example.nwp.yml`
- [ ] Helper functions available for any script to read timezone
- [ ] `fin-monitor` reads timezone from nwp.yml via deploy script
- [ ] Linode provisioning scripts read timezone from nwp.yml
- [ ] `schedule.sh` generated cron entries include `CRON_TZ`
- [ ] No hardcoded timezone values remain (except UTC fallback)
- [ ] `pl status` and similar commands can display site-appropriate time

---

## 9. Testing

```bash
# Verify timezone reads correctly
source lib/yaml-write.sh
get_default_timezone          # Should return Australia/Sydney
get_site_timezone "mysite"    # Should return site-specific or fall back to default

# Verify fin-monitor deploys with timezone
./fin/deploy-fin-monitor.sh --conf-only
grep TIMEZONE fin/fin-monitor.conf  # Should show configured timezone

# Verify cron uses correct timezone
ssh -i ~/.ssh/nwp gitlab@97.107.137.88 "crontab -l"  # Should show CRON_TZ=Australia/Sydney
```
