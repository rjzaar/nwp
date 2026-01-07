# Working with Claude Securely

This guide explains how to use NWP with and without Claude Code, and how to safely share error information for debugging without compromising production user data.

## Running NWP Without Claude

NWP is a standalone shell script system. Claude Code is entirely optional - all commands work via interactive TUIs:

```bash
# Site management
./install.sh d mysite              # Create new Drupal site
./backup.sh mysite                 # Backup site
./restore.sh mysite                # Restore from backup
./delete.sh mysite                 # Remove site

# Import existing production site
./import.sh                        # Interactive mode
./import.sh --server=production    # Use specific server from cnwp.yml
./import.sh --ssh=root@example.com # Custom SSH connection

# Deployment
./dev2stg.sh mysite                # Deploy to staging
./stg2prod.sh mysite               # Deploy to production

# Re-sync with production
./sync.sh mysite                   # Pull fresh DB/files from origin
```

Claude is only useful for:
- Generating custom recipes
- Writing advanced deployment scripts
- Debugging complex issues (see below)

---

## Error Reporting with report.sh

The `report.sh` wrapper captures command failures and offers to report them to GitLab with automatic sanitization.

### Usage

**Wrapper mode** (catches failures):
```bash
./report.sh backup.sh mysite           # Run backup, offer to report on failure
./report.sh install.sh d mysite        # Run install with args
./report.sh -c backup.sh mysite        # Copy URL to clipboard instead of browser
```

**Direct report mode** (manual):
```bash
./report.sh --report "Error message"
./report.sh --report -s backup.sh "Description"
```

### How It Works

1. Runs your command while capturing output
2. If the command fails, prompts:
   ```
   Report this error? [y/N/c]
   ```
   - `y` = Open GitLab issue with pre-filled details
   - `N` = Just exit with error code
   - `c` = Continue (useful for batch operations)

### Automatic Sanitization

Before including output in the issue, report.sh redacts sensitive information:

| Pattern | Replacement |
|---------|-------------|
| Home directory paths | `~` |
| IP addresses | `[IP_REDACTED]` |
| Passwords in URLs (`:pass@`) | `:[PASS_REDACTED]@` |
| API tokens/keys | `[REDACTED]` |

Output is truncated to 3000 characters to fit URL limits.

### System Info Included

The generated issue includes safe diagnostic info:
- NWP version (git commit + branch)
- OS name/version
- DDEV version
- Docker version
- Bash version

---

## Safe Operations Library (safe-ops.sh)

The `lib/safe-ops.sh` library provides proxy functions that access production systems internally but only return sanitized summaries. These are safe for Claude to see.

### Available Functions

| Function | Input | Output (Sanitized) |
|----------|-------|-------------------|
| `safe_server_status <server>` | Server name | Status, uptime, load, memory, disk |
| `safe_site_status <site>` | Site name | DDEV status, Drupal version |
| `safe_db_status <site>` | Site name | Table count, size in MB, backup age |
| `safe_backup_list <site>` | Site name | Backup filenames and sizes (last 10) |
| `safe_backup_create <site>` | Site name | Instructions only (won't auto-run) |
| `safe_recent_errors <site>` | Site name | Error type/count summary (no messages) |
| `safe_security_check <site>` | Site name | Count of security updates needed |
| `safe_deploy <site> [env]` | Site + env | Instructions only (won't auto-deploy) |

### Usage

```bash
source lib/safe-ops.sh

safe_server_status prod1
# === Server: prod1 ===
# Status: running
# Uptime: up 45 days
# Load: 0.15 0.12 0.08
# Memory: 2.1G/8.0G
# Disk: 45G/100G (45% used)

safe_db_status mysite
# === Database: mysite ===
# Tables: 284
# Size: 156.23MB
# Last backup: 4h ago

safe_recent_errors mysite
# === Recent Errors: mysite ===
# Type | Severity | Count
# ------------------------
# php  | 3        | 12
```

### What's Protected

The functions internally use credentials from `.secrets.data.yml` (SSH keys, database passwords) but never expose them:

| Claude Sees | Protected |
|-------------|-----------|
| "Server: prod1" | Actual IP address |
| "Memory: 7.8G/8.0G" | SSH credentials |
| "Tables: 284" | Database password |
| "12 PHP errors" | Actual error messages (may contain user data) |
| "Size: 156MB" | Database contents |
| "3 security updates" | Specific module names (attack surface) |

---

## Workflow: Debugging Production Issues with Claude

### Step 1: Error Occurs on Production (No Claude)

```bash
# On production server or machine without Claude
./backup.sh mysite
# Error: Database connection failed
```

### Step 2: Capture Sanitized Error

Option A - Use report.sh wrapper:
```bash
./report.sh backup.sh mysite
# If it fails, press 'y' to generate GitLab issue URL
# Share the issue URL with your Claude-enabled environment
```

Option B - Copy the error manually:
```
Database connection failed for mysite.
Exit code 1.
```

### Step 3: Run Safe Diagnostics (On Dev Machine with Claude)

Claude can ask you to run safe_* functions to gather diagnostic info:

```bash
source lib/safe-ops.sh

# Check if server is reachable
safe_server_status prod1
# === Server: prod1 ===
# Status: running
# Memory: 7.8G/8.0G
# Disk: 95G/100G (95% used)

# Check database status
safe_db_status mysite
# === Database: mysite ===
# Tables: 284
# Size: 156.23MB
# Last backup: 72h ago

# Check for recent errors
safe_recent_errors mysite
# === Recent Errors: mysite ===
# Type | Severity | Count
# ------------------------
# php  | 3        | 847
```

### Step 4: Claude Diagnoses the Issue

Based on the sanitized output, Claude can identify problems:

> "The server has 95% disk usage and memory is nearly maxed out. The 847 PHP errors in 24 hours suggests something is logging excessively. Try clearing old logs and checking for a runaway process."

### What Makes This Secure

```bash
# What happens inside safe_db_status:
ssh -i "$ssh_key" user@host "SELECT COUNT(*) FROM tables..."
#     ^^^^^^^^^^^          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
#     Uses real key        Runs real query
#     (Claude can't see)   (Claude can't see)

# What Claude sees:
# "Tables: 284"
```

Claude helps debug by analyzing **system health metrics** without ever seeing:
- SSH credentials or keys
- Database passwords
- User emails or PII
- Actual error messages with user data
- Database dumps or contents

---

## Summary

| Scenario | Tool | Data Exposure |
|----------|------|---------------|
| Run NWP commands | Any script directly | None (no Claude involved) |
| Report errors to GitLab | `report.sh` | Auto-sanitized output |
| Share diagnostics with Claude | `safe_*` functions | Aggregate metrics only |
| Debug with Claude | Combine above | Zero production data exposed |

## Related Documentation

- `docs/DATA_SECURITY_BEST_PRACTICES.md` - Full security architecture
- `lib/sanitize.sh` - Database sanitization for imports
- `lib/safe-ops.sh` - Source code for safe operations
- `scripts/commands/report.sh` - Error reporter source
