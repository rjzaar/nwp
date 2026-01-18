# P55: Opportunistic Human Verification

**Status:** PROPOSED
**Created:** 2026-01-18
**Author:** Rob, Claude Opus 4.5
**Priority:** Medium
**Depends On:** P50 (Unified Verification System)
**Estimated Effort:** 4-5 weeks
**Breaking Changes:** No - opt-in feature

---

## 1. Executive Summary

### 1.1 Problem Statement

P50's verification system has two modes:
1. **Machine verification** (`pl verify --run`) - automated but limited to what code can test
2. **Manual verification** (`pl verify`) - requires dedicated testing sessions

Neither captures the most valuable verification: **humans using NWP in real workflows**. When a developer runs `pl install d mysite` for actual work, that's a perfect opportunity to verify the install command—but we don't capture it.

Current auto-logging (P50) silently logs success but doesn't:
- Confirm the user thinks it worked correctly
- Capture issues when something seems wrong but exits 0
- Track who verified what
- Link failures to actionable bug reports

### 1.2 Proposed Solution

**Opportunistic Human Verification** - an opt-in system where designated testers receive interactive prompts after running commands, showing exactly what to verify:

```
$ pl backup mysite
✓ Backup complete: sitebackups/mysite/mysite-2026-01-18.sql.gz

┌──────────────────────────────────────────────────────────────────────────────┐
│  ℹ VERIFICATION NEEDED                                                       │
│                                                                              │
│  Command: pl backup mysite                                                   │
│  Item: "Full backup creates valid archive"                                   │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│  HOW TO VERIFY:                                                              │
│  1. Check backup file exists: ls -la ~/nwp/sitebackups/mysite/               │
│  2. Verify backup has content: gunzip -l sitebackups/mysite/*.sql.gz         │
│  3. Validate SQL structure: gunzip -c ... | head -20                         │
│  4. Check log for errors: cat ~/.logs/backup.log | tail -20                  │
├──────────────────────────────────────────────────────────────────────────────┤
│  Did all steps pass? [Y/n/s/d/?]                                             │
│                                                                              │
│  Y = Yes, all passed - mark verified     n = No - create bug report          │
│  s = Skip this session                   d = Don't ask for this command      │
└──────────────────────────────────────────────────────────────────────────────┘
```

**If something didn't work**, pressing `n` walks through a bug report workflow:
- Which verification step failed?
- What did you see instead?
- Auto-collects diagnostics (command output, environment, DDEV status)
- Creates local issue and optionally submits to GitLab

### 1.3 Key Benefits

| Benefit | Description |
|---------|-------------|
| **Organic verification** | Captures real-world usage without dedicated test sessions |
| **Bug discovery** | Catches "it exited 0 but didn't work right" issues |
| **Accountability** | Tracks who verified what, building trust |
| **Non-intrusive** | Only prompts for unverified items; respects user time |
| **Actionable reports** | Bug reports linked directly to verification items |

---

## 2. Tester Role System

### 2.1 Configuration

Add to `nwp.yml`:

```yaml
settings:
  verification:
    enabled: true

    # Tester prompt preferences (applies to all testers)
    tester_prompts:
      prompt_mode: "unverified"         # unverified | all | never
      prompt_timeout: 30                # Seconds before auto-skip (0 = no timeout)

      # Skip list (commands to never prompt for)
      skip_commands:
        - status                        # Read-only, doesn't need verification
        - doctor                        # Diagnostic, doesn't need verification

# Tester designation is stored per-coder (not in settings)
other_coders:
  coders:
    rob:
      added: 2024-01-01T00:00:00Z
      status: active
      email: rob@example.com
      tester: true                      # ← Tester status here
      verifications: 47
      bugs_reported: 5
```

### 2.2 Enabling Tester Mode

Tester status is managed through `pl coders`, not `pl verify`:

```bash
# Enable yourself as a tester
$ pl coders tester rob --enable
? Prompt for unverified commands only? [Y/n]: Y
✓ rob is now a tester. You'll receive verification prompts after commands.

# Or enable another coder
$ pl coders tester greg --enable
✓ greg is now a tester.

# The tester flag is stored in nwp.yml under coders
```

### 2.3 Tester Attribution

When a tester verifies an item, record their identity:

```yaml
# In .verification.yml
features:
  backup:
    checklist:
      - id: backup_0
        human:
          state:
            verified: true
            verified_at: "2026-01-18T14:30:00Z"
            verified_by: "Rob"
            verification_type: "opportunistic"  # vs "manual" or "auto-logged"
            context: "pl backup mysite"
```

### 2.4 Integration with `pl coders`

The `pl coders` command gains a **TST** (Tester) column to show which coders are designated as testers:

```bash
$ pl coders

┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ NWP CODER MANAGEMENT  3 coders                                                           │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│      NAME       ROLE     TST   GL   GRP   SSH   NS   DNS   SRV  SITE  COMMIT  MRs       │
│      ────────── ───────  ───  ────  ────  ────  ────  ────  ────  ────  ──────  ────     │
│      rob        admin    ✓    ✓     ✓     ✓     ✓     ✓     ✓     ✓     156    12       │
│      greg       dev      ✓    ✓     ✓     ✓     ✓     ✓     ✓     ✓     42     3        │
│      sarah      dev      -    ✓     ✓     ✓     -     -     -     -     8      1        │
│                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────┘

TST = Tester role enabled (receives verification prompts)
```

#### Coders Schema Update

```yaml
# In nwp.yml under other_coders.coders
coders:
  rob:
    added: 2024-01-01T00:00:00Z
    status: active
    email: rob@example.com
    tester: true                    # NEW: Tester designation
    verifications: 47               # NEW: Count of items verified
    bugs_reported: 5                # NEW: Count of bugs reported
    notes: "Project lead"

  greg:
    added: 2024-06-15T10:30:00Z
    status: active
    email: greg@example.com
    tester: true
    verifications: 23
    bugs_reported: 2
    notes: "Core contributor"

  sarah:
    added: 2025-01-10T14:00:00Z
    status: active
    email: sarah@example.com
    tester: false                   # Not a tester yet
    verifications: 0
    bugs_reported: 0
    notes: "New developer"
```

#### Enabling Tester Status via `pl coders`

```bash
# Enable tester role for a coder
$ pl coders tester greg --enable
✓ greg is now a tester. They will receive verification prompts.

# Disable tester role
$ pl coders tester greg --disable
✓ greg is no longer a tester.

# View tester statistics
$ pl coders tester --stats
┌────────────────────────────────────────────────────┐
│ Tester Statistics                                  │
├────────────────────────────────────────────────────┤
│ Active testers: 2 (rob, greg)                      │
│ Total verifications: 70                            │
│ Total bugs reported: 7                             │
│                                                    │
│ Top testers:                                       │
│   rob   - 47 verifications, 5 bugs                 │
│   greg  - 23 verifications, 2 bugs                 │
└────────────────────────────────────────────────────┘
```

---

## 3. Prompt Flow

### 3.1 Decision Tree

```
Command Executed
      │
      ▼
┌─────────────────────┐
│ Tester mode enabled?│──No──► Silent (current behavior)
└─────────────────────┘
      │Yes
      ▼
┌─────────────────────┐
│ Command in skip_list│──Yes──► Silent
└─────────────────────┘
      │No
      ▼
┌─────────────────────┐
│ Skipped this session│──Yes──► Silent
└─────────────────────┘
      │No
      ▼
┌─────────────────────┐
│ prompt_mode setting │
└─────────────────────┘
      │
      ├── "never" ──► Silent
      │
      ├── "all" ──► Show prompt
      │
      └── "unverified" ──► Check verification status
                                │
                    ┌───────────┴───────────┐
                    │                       │
              Already verified        Not verified
                    │                       │
                    ▼                       ▼
                 Silent              Show prompt
```

### 3.2 Prompt Interface

The prompt displays the full verification details from `.verification.yml` so the tester knows exactly what to check:

```bash
# After successful command
$ pl backup mysite
✓ Backup complete: sitebackups/mysite/mysite-2026-01-18.sql.gz

┌──────────────────────────────────────────────────────────────────────────────┐
│  ℹ VERIFICATION NEEDED                                                       │
│                                                                              │
│  Command: pl backup mysite                                                   │
│  Feature: backup                                                             │
│  Item: "Full backup creates valid archive"                                   │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│  HOW TO VERIFY:                                                              │
│                                                                              │
│  1. Check backup file exists:                                                │
│     ls -la ~/nwp/sitebackups/mysite/                                         │
│     (should show .sql.gz file with recent timestamp)                         │
│                                                                              │
│  2. Verify backup has content:                                               │
│     gunzip -l ~/nwp/sitebackups/mysite/*.sql.gz                              │
│     (compressed size should be > 0, uncompressed typically 1-50MB)           │
│                                                                              │
│  3. Validate SQL structure:                                                  │
│     gunzip -c ~/nwp/sitebackups/mysite/*.sql.gz | head -20                   │
│     (should show SQL statements starting with comments/DROP TABLE)           │
│                                                                              │
│  4. Check backup log for errors:                                             │
│     cat ~/.logs/backup.log | tail -20                                        │
│     (should show no ERROR lines)                                             │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│  Did all verification steps pass? [Y/n/s/d/?]                                │
│                                                                              │
│  Y = Yes, all steps passed - mark as verified                                │
│  n = No, something failed - create bug report                                │
│  s = Skip for this session                                                   │
│  d = Don't ask for this command again                                        │
│  ? = Show more help                                                          │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 3.3 Multi-Item Commands

Some commands may verify multiple items. Show all relevant items:

```bash
$ pl install d mysite
✓ Site installed successfully at sites/mysite

┌──────────────────────────────────────────────────────────────────────────────┐
│  ℹ VERIFICATION NEEDED (3 items)                                             │
│                                                                              │
│  Command: pl install d mysite                                                │
│  Feature: install                                                            │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│  ITEM 1/3: "Install creates working Drupal site"                             │
│                                                                              │
│  How to verify:                                                              │
│  1. Visit https://mysite.ddev.site in browser                                │
│  2. Should see Drupal homepage (not error page)                              │
│  3. Run: ddev drush status (should show "Drupal bootstrap: Successful")      │
│                                                                              │
│  Did this pass? [Y/n/s/?]                                                    │
├──────────────────────────────────────────────────────────────────────────────┤
│  ITEM 2/3: "Install registers site in nwp.yml"                               │
│                                                                              │
│  How to verify:                                                              │
│  1. Run: grep "mysite:" nwp.yml                                              │
│  2. Should show site entry with recipe, URL, and settings                    │
│                                                                              │
│  Did this pass? [Y/n/s/?]                                                    │
├──────────────────────────────────────────────────────────────────────────────┤
│  ITEM 3/3: "Install sets correct file permissions"                           │
│                                                                              │
│  How to verify:                                                              │
│  1. Run: ls -la sites/mysite/html/sites/default/                             │
│  2. settings.php should be 444 or 440 (read-only)                            │
│  3. files/ directory should be 755 and owned by www-data                     │
│                                                                              │
│  Did this pass? [Y/n/s/?]                                                    │
└──────────────────────────────────────────────────────────────────────────────┘

# After answering all items:
✓ Marked 3 items as verified. Thank you!
```

### 3.4 Bug Report Flow (When User Presses 'n')

```bash
# User presses 'n' on Item 1
┌──────────────────────────────────────────────────────────────────────────────┐
│  ✗ CREATING BUG REPORT                                                       │
│                                                                              │
│  Item: "Install creates working Drupal site"                                 │
│                                                                              │
│  Which verification step failed?                                             │
│  [1] Visit site in browser                                                   │
│  [2] Drupal bootstrap check                                                  │
│  [3] Other / multiple steps                                                  │
│                                                                              │
│  > 1                                                                         │
├──────────────────────────────────────────────────────────────────────────────┤
│  What did you see instead?                                                   │
│  (Describe the actual behavior - press Enter twice when done)                │
│                                                                              │
│  > The browser shows "502 Bad Gateway" error.                                │
│  > DDEV seems to be running but nginx isn't responding.                      │
│  >                                                                           │
├──────────────────────────────────────────────────────────────────────────────┤
│  Collecting diagnostics...                                                   │
│  ✓ Command output captured                                                   │
│  ✓ Environment info collected                                                │
│  ✓ DDEV status captured                                                      │
│  ✓ Site files checked                                                        │
├──────────────────────────────────────────────────────────────────────────────┤
│  Bug report created: NWP-20260118-143052                                     │
│                                                                              │
│  Submit to GitLab? [y/N] y                                                   │
│  ✓ Created: https://git.nwpcode.org/nwp/nwp/-/issues/47                      │
│                                                                              │
│  View locally: pl verify issues --show NWP-20260118-143052                   │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 3.5 Response Handling

| Response | Action |
|----------|--------|
| `Y` / `y` / Enter | Mark item as human-verified, record tester name |
| `n` / `N` | Launch bug report workflow |
| `s` | Skip for this session (add to session_skips) |
| `d` | Add to permanent skip_commands list |
| `?` | Show help text explaining the system |
| Timeout | Auto-skip (no verification recorded) |

---

## 4. Bug Report System

### 4.1 Overview

When a user reports something didn't work, create a structured bug report that:
1. Captures diagnostic information automatically
2. Asks the user what went wrong
3. Stores locally for tracking
4. Optionally submits to GitLab/GitHub
5. Links to the verification item for follow-up

### 4.2 Bug Report Schema

```yaml
# Stored in .logs/issues/NWP-YYYYMMDD-HHMMSS.yml
issue:
  id: "NWP-20260118-143052"
  created_at: "2026-01-18T14:30:52Z"
  status: "open"                      # open | investigating | resolved | wontfix

  # Reporter information
  reporter:
    name: "Rob"
    email: "rob@example.com"          # Optional

  # What failed
  command:
    full: "pl backup mysite"
    script: "backup.sh"
    args: ["mysite"]
    exit_code: 0                      # May have succeeded but not worked right
    duration_seconds: 12.4

  # Verification context
  verification:
    feature: "backup"
    item_id: "backup_0"
    item_text: "Full backup creates valid archive"
    was_verified: false

  # Environment snapshot
  environment:
    nwp_version: "0.15.2"
    os: "Ubuntu 22.04"
    shell: "bash 5.1.16"
    ddev_version: "1.23.0"
    docker_version: "24.0.7"
    pwd: "/home/rob/nwp"

  # User description
  description: |
    Backup file was created but it's empty (0 bytes).
    Expected a .sql.gz file with database contents.

  # Automatic diagnostics
  diagnostics:
    # Last 20 lines of command output (if captured)
    output_tail: |
      Creating backup for mysite...
      Dumping database...
      Compressing...
      Done: sitebackups/mysite/mysite-2026-01-18.sql.gz

    # Relevant file checks
    file_checks:
      - path: "sitebackups/mysite/mysite-2026-01-18.sql.gz"
        exists: true
        size_bytes: 0

    # Site status (if applicable)
    site_status:
      name: "mysite"
      running: true
      db_status: "connected"

  # Resolution tracking
  resolution:
    resolved_at: null
    resolved_by: null
    fix_commit: null
    notes: null

  # Links
  links:
    gitlab_issue: null                # URL if submitted to GitLab
    github_issue: null                # URL if submitted to GitHub
```

### 4.3 Bug Report Workflow

```
User presses 'n' (didn't work)
          │
          ▼
┌─────────────────────────────────────┐
│ 1. Collect automatic diagnostics    │
│    - Command details                │
│    - Environment info               │
│    - Output capture (if available)  │
│    - File checks                    │
└─────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────┐
│ 2. Ask user for description         │
│    "What went wrong?"               │
│    > [user types description]       │
└─────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────┐
│ 3. Save locally                     │
│    .logs/issues/NWP-YYYYMMDD-HH...  │
└─────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────┐
│ 4. Offer to submit upstream         │
│    "Submit to GitLab? [y/N]"        │
│                                     │
│    If yes → Create GitLab issue     │
│    If no  → Keep local only         │
└─────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────┐
│ 5. Link to verification item        │
│    Update .verification.yml with    │
│    issue reference                  │
└─────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────┐
│ 6. Display summary                  │
│    "Bug report created: NWP-..."    │
│    "View: pl verify issues"         │
└─────────────────────────────────────┘
```

### 4.4 Automatic Diagnostics

The bug report system automatically collects:

| Category | Information Collected |
|----------|----------------------|
| **Command** | Full command, script path, arguments, exit code, duration |
| **Environment** | NWP version, OS, shell, DDEV, Docker versions |
| **Output** | Last 50 lines of stdout/stderr (if captured) |
| **File checks** | Existence, size, permissions of expected output files |
| **Site status** | DDEV status, database connectivity (if site involved) |
| **Git state** | Current branch, last commit, dirty files count |

### 4.5 Upstream Submission

If the user opts to submit to GitLab/GitHub:

```bash
# GitLab issue creation
gh_or_gl_create_issue() {
    local issue_file="$1"
    local title="Bug: $(yq '.command.full' "$issue_file") - $(yq '.description' "$issue_file" | head -1)"
    local body=$(generate_issue_body "$issue_file")

    # Check which remote is configured
    if gitlab_configured; then
        glab issue create --title "$title" --description "$body" --label "bug,verification"
    elif github_configured; then
        gh issue create --title "$title" --body "$body" --label "bug,verification"
    else
        echo "No GitLab or GitHub CLI configured. Issue saved locally only."
    fi
}
```

**Issue body template:**

```markdown
## Bug Report from Opportunistic Verification

**Command:** `pl backup mysite`
**Exit Code:** 0 (appeared to succeed)
**NWP Version:** 0.15.2

### Description
Backup file was created but it's empty (0 bytes).
Expected a .sql.gz file with database contents.

### Verification Context
- **Feature:** backup
- **Item:** "Full backup creates valid archive"
- **Previously verified:** No

### Environment
- OS: Ubuntu 22.04
- DDEV: 1.23.0
- Docker: 24.0.7

### Diagnostics
<details>
<summary>Command output (last 50 lines)</summary>

```
Creating backup for mysite...
Dumping database...
Compressing...
Done: sitebackups/mysite/mysite-2026-01-18.sql.gz
```

</details>

<details>
<summary>File checks</summary>

| File | Exists | Size |
|------|--------|------|
| sitebackups/mysite/mysite-2026-01-18.sql.gz | Yes | 0 bytes |

</details>

---
*Generated by NWP Opportunistic Verification (P55)*
*Local issue ID: NWP-20260118-143052*
```

### 4.6 Issue Management Commands

```bash
# List all local issues
$ pl verify issues
┌────────────────────────────────────────────────────────────────┐
│ Open Issues (3)                                                │
├──────────────────┬─────────┬───────────────────────────────────┤
│ ID               │ Status  │ Description                       │
├──────────────────┼─────────┼───────────────────────────────────┤
│ NWP-20260118-143 │ open    │ Backup file empty (0 bytes)       │
│ NWP-20260117-091 │ open    │ Restore fails on large databases  │
│ NWP-20260115-162 │ invest. │ Copy doesn't preserve permissions │
└──────────────────┴─────────┴───────────────────────────────────┘

# View issue details
$ pl verify issues --show NWP-20260118-143052

# Resolve an issue
$ pl verify issues --resolve NWP-20260118-143052 --fix-commit abc123
? Resolution notes: Fixed in backup.sh - was missing -z flag for gzip
✓ Issue resolved and linked to commit abc123

# Submit local issue to GitLab
$ pl verify issues --submit NWP-20260118-143052
✓ Created GitLab issue: https://git.nwpcode.org/nwp/nwp/-/issues/47

# List issues for a specific feature
$ pl verify issues --feature backup
```

---

## 5. Verification Item Linking

### 5.1 Linking Issues to Items

When a bug report is created, update the verification item:

```yaml
# In .verification.yml
features:
  backup:
    checklist:
      - id: backup_0
        text: "Full backup creates valid archive"

        # Issues linked to this item
        issues:
          - id: "NWP-20260118-143052"
            status: "open"
            summary: "Backup file empty (0 bytes)"
            created_at: "2026-01-18T14:30:52Z"
            reporter: "Rob"

        # Item cannot be marked verified while issues are open
        human:
          state:
            verified: false
            blocked_by_issues: true
```

### 5.2 Verification Blocking

Items with open issues cannot be marked as verified:

```bash
$ pl verify mark backup_0 --verified
✗ Cannot verify: 1 open issue(s) linked to this item
  - NWP-20260118-143052: Backup file empty (0 bytes)

  Resolve issues first: pl verify issues --resolve NWP-20260118-143052
```

### 5.3 Issue Resolution Flow

```
Issue Created
     │
     ▼
┌──────────────┐
│ Status: open │
└──────────────┘
     │
     ▼ (developer investigates)
┌────────────────────┐
│ Status: investigating │
└────────────────────┘
     │
     ▼ (fix committed)
┌─────────────────┐
│ Status: resolved │◄── Link to fix commit
└─────────────────┘
     │
     ▼ (verification item unblocked)
┌─────────────────────────────────┐
│ Item can now be verified again  │
│ Next successful run will prompt │
└─────────────────────────────────┘
```

---

## 6. AI-Assisted Issue Resolution (`pl fix`)

### 6.1 Overview

The `pl fix` command provides a TUI interface for Claude to review and fix open issues. When a tester reports a bug, it enters the issue queue where Claude can systematically work through fixes.

### 6.2 TUI Interface

```bash
$ pl fix

┌──────────────────────────────────────────────────────────────────────────────┐
│  NWP ISSUE FIXER                                                     3 open  │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─ Open Issues ──────────────────────────────────────────────────────────┐  │
│  │                                                                        │  │
│  │  > [1] NWP-20260118-143052  backup     Backup file empty (0 bytes)    │  │
│  │    [2] NWP-20260117-091523  restore    Restore fails on large DBs     │  │
│  │    [3] NWP-20260115-162834  copy       Copy doesn't preserve perms    │  │
│  │                                                                        │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  [Enter] View & Fix   [s] Skip   [q] Quit   [?] Help                        │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 6.3 Issue Detail View

When Claude selects an issue to fix:

```bash
┌──────────────────────────────────────────────────────────────────────────────┐
│  ISSUE: NWP-20260118-143052                                          backup  │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Status: open                                                                │
│  Reporter: Rob                                                               │
│  Created: 2026-01-18 14:30:52                                                │
│                                                                              │
│  Command: pl backup mysite                                                   │
│  Exit Code: 0 (appeared to succeed)                                          │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│  DESCRIPTION:                                                                │
│                                                                              │
│  Backup file was created but it's empty (0 bytes).                           │
│  Expected a .sql.gz file with database contents.                             │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│  VERIFICATION STEP THAT FAILED:                                              │
│                                                                              │
│  Step 2: "Verify backup has content"                                         │
│  Command: gunzip -l ~/nwp/sitebackups/mysite/*.sql.gz                        │
│  Expected: compressed size > 0, uncompressed typically 1-50MB                │
│  Actual: 0 bytes                                                             │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│  DIAGNOSTICS:                                                                │
│                                                                              │
│  • File: sitebackups/mysite/mysite-2026-01-18.sql.gz                         │
│    Exists: Yes | Size: 0 bytes                                               │
│  • DDEV Status: running                                                      │
│  • Database: connected                                                       │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│  AFFECTED FILES:                                                             │
│                                                                              │
│  • scripts/commands/backup.sh (lines 257-380)                                │
│  • lib/sanitize.sh                                                           │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  [f] Fix this issue   [v] View affected files   [b] Back   [q] Quit          │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 6.4 Fix Workflow

When Claude presses `f` to fix:

```
Claude selects "Fix this issue"
          │
          ▼
┌─────────────────────────────────────┐
│ 1. Read affected files              │
│    - scripts/commands/backup.sh     │
│    - lib/sanitize.sh                │
└─────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────┐
│ 2. Analyze issue and diagnostics    │
│    - Command output                 │
│    - File checks                    │
│    - Error patterns                 │
└─────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────┐
│ 3. Implement fix                    │
│    - Edit affected files            │
│    - Test the fix locally           │
└─────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────┐
│ 4. Mark issue as fixed              │
│    - Update issue status            │
│    - Link to fix commit (if any)    │
│    - Add resolution notes           │
└─────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────┐
│ 5. Prompt: Test the fix?            │
│    - Run the original command       │
│    - Verify issue is resolved       │
└─────────────────────────────────────┘
```

### 6.5 Claude Marks Issue as Fixed

After implementing a fix, Claude updates the issue:

```bash
# Claude completes the fix and marks it resolved
┌──────────────────────────────────────────────────────────────────────────────┐
│  ✓ FIX IMPLEMENTED                                                           │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Issue: NWP-20260118-143052                                                  │
│  Status: open → fixed                                                        │
│                                                                              │
│  Files modified:                                                             │
│  • scripts/commands/backup.sh (+3 -1)                                        │
│                                                                              │
│  Resolution notes:                                                           │
│  Added -z flag to gzip command in backup_database() function.                │
│  The mysqldump output was being piped but gzip wasn't reading stdin.         │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Test the fix now? [Y/n]                                                     │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘

# If user tests and confirms:
✓ Issue NWP-20260118-143052 marked as resolved
✓ Verification item backup_0 unblocked

# Move to next issue or quit
```

### 6.6 Issue Status Transitions

```
┌──────────┐     ┌───────────────┐     ┌──────────┐     ┌──────────┐
│   open   │────►│ investigating │────►│  fixed   │────►│ verified │
└──────────┘     └───────────────┘     └──────────┘     └──────────┘
     │                   │                   │
     │                   │                   │
     ▼                   ▼                   ▼
┌──────────┐     ┌───────────────┐     ┌──────────┐
│ wontfix  │     │   duplicate   │     │ reopened │
└──────────┘     └───────────────┘     └──────────┘
```

| Status | Meaning |
|--------|---------|
| `open` | New issue, awaiting investigation |
| `investigating` | Claude or developer is looking at it |
| `fixed` | Fix implemented, awaiting verification |
| `verified` | Fix confirmed working by tester |
| `wontfix` | Won't be fixed (by design, out of scope) |
| `duplicate` | Same as another issue |
| `reopened` | Fix didn't work, issue reopened |

### 6.7 Command Options

```bash
# Launch TUI with all open issues
pl fix

# Fix a specific issue directly
pl fix NWP-20260118-143052

# List issues without TUI
pl fix --list

# Filter by feature
pl fix --feature backup

# Filter by status
pl fix --status investigating

# Show issues Claude has fixed
pl fix --fixed-by-claude
```

---

## 7. Integration with `pl todo`

### 7.1 Overview

Open issues automatically appear in the `pl todo` list, ensuring they're visible alongside other pending work.

### 7.2 Todo List Display

```bash
$ pl todo

┌──────────────────────────────────────────────────────────────────────────────┐
│  NWP TODO LIST                                                               │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ═══ BUGS (3 open issues) ═══════════════════════════════════════════════   │
│                                                                              │
│  [ ] NWP-20260118-143052: Backup file empty (0 bytes)                        │
│      Feature: backup | Reporter: Rob | pl fix NWP-20260118-143052            │
│                                                                              │
│  [ ] NWP-20260117-091523: Restore fails on large databases                   │
│      Feature: restore | Reporter: Rob | pl fix NWP-20260117-091523           │
│                                                                              │
│  [ ] NWP-20260115-162834: Copy doesn't preserve permissions                  │
│      Feature: copy | Reporter: Greg | pl fix NWP-20260115-162834             │
│                                                                              │
│  ═══ TASKS ══════════════════════════════════════════════════════════════   │
│                                                                              │
│  [ ] Update documentation for new backup flags                               │
│  [ ] Add unit tests for restore large DB handling                            │
│  [ ] Review PR #42: Permission preservation in copy                          │
│                                                                              │
│  ═══ VERIFICATION (12 items unverified) ═════════════════════════════════   │
│                                                                              │
│  [ ] backup_3: "Backup with sanitization removes sensitive data"             │
│  [ ] restore_4: "Restore preserves file permissions"                         │
│  [ ] ... (10 more - run `pl verify status` for full list)                    │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘

Quick actions:
  pl fix              - Fix bugs with Claude
  pl todo add "task"  - Add a task
  pl verify           - Run verification
```

### 7.3 Todo Categories

The `pl todo` command now has three categories:

| Category | Source | Priority |
|----------|--------|----------|
| **BUGS** | `.logs/issues/` (P55 issues) | High - shown first |
| **TASKS** | `.todo.yml` (manual tasks) | Medium |
| **VERIFICATION** | `.verification.yml` (unverified items) | Low - summary only |

### 7.4 Filtering Todo Items

```bash
# Show only bugs
pl todo --bugs

# Show only tasks
pl todo --tasks

# Show only verification items
pl todo --verify

# Show bugs for a specific feature
pl todo --bugs --feature backup

# Show all (expanded verification list)
pl todo --all
```

### 7.5 Adding Tasks from Issues

When viewing an issue, add related tasks:

```bash
$ pl fix NWP-20260118-143052 --add-task "Add unit test for empty backup detection"

✓ Task added to todo list
✓ Linked to issue NWP-20260118-143052
```

### 7.6 Completing Bugs via Todo

```bash
$ pl todo complete NWP-20260118-143052

This is a bug report. To complete it:
  1. Run: pl fix NWP-20260118-143052
  2. Implement the fix
  3. Test and verify

Open in pl fix? [Y/n]
```

### 7.7 Data Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           DATA SOURCES                                       │
├─────────────────┬─────────────────────┬─────────────────────────────────────┤
│ .logs/issues/   │ .todo.yml           │ .verification.yml                   │
│ (Bug Reports)   │ (Manual Tasks)      │ (Unverified Items)                  │
└────────┬────────┴──────────┬──────────┴──────────────────┬──────────────────┘
         │                   │                             │
         ▼                   ▼                             ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            pl todo                                           │
│                     (Unified Todo View)                                      │
└─────────────────────────────────────────────────────────────────────────────┘
         │
         │ Bugs can be fixed via:
         ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            pl fix                                            │
│                    (AI-Assisted Issue Fixer)                                 │
└─────────────────────────────────────────────────────────────────────────────┘
         │
         │ When fixed:
         ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  • Issue status → "fixed"                                                    │
│  • Removed from BUGS section in pl todo                                      │
│  • Verification item unblocked                                               │
│  • Next run of command will prompt for verification                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 8. Implementation

### 8.1 New Files

| File | Purpose |
|------|---------|
| `lib/verify-opportunistic.sh` | Core opportunistic verification logic |
| `lib/verify-issues.sh` | Bug report creation and management |
| `lib/verify-fix.sh` | AI-assisted issue fixing logic |
| `scripts/commands/fix.sh` | `pl fix` command implementation |
| `.logs/issues/` | Local issue storage directory |

### 8.2 Modified Files

| File | Changes |
|------|---------|
| `pl` | Add post-command hook for opportunistic prompts |
| `lib/verify-autolog.sh` | Integrate with opportunistic system |
| `scripts/commands/verify.sh` | Add issues subcommands |
| `scripts/commands/todo.sh` | Add BUGS category from issues |
| `scripts/commands/coders.sh` | Add TST column, `tester` subcommand, stats tracking |
| `example.nwp.yml` | Add tester configuration section, coders tester fields |
| `.verification.yml` | Add issues array to item schema |

### 8.3 Core Functions

```bash
# lib/verify-opportunistic.sh

# Check if opportunistic prompt should be shown
should_prompt_verification() {
    local command="$1"

    # Check tester mode enabled
    tester_enabled || return 1

    # Check not in skip list
    is_skipped_command "$command" && return 1

    # Check prompt mode
    local mode=$(get_prompt_mode)
    case "$mode" in
        never) return 1 ;;
        all) return 0 ;;
        unverified)
            local item=$(find_verification_item "$command")
            is_item_verified "$item" && return 1
            return 0
            ;;
    esac
}

# Show the verification prompt
prompt_verification() {
    local command="$1"
    local exit_code="$2"

    local item=$(find_verification_item "$command")
    local item_text=$(get_item_text "$item")

    echo ""
    echo "┌─────────────────────────────────────────────────────┐"
    echo "│  ℹ This command hasn't been verified yet.           │"
    echo "│                                                     │"
    echo "│  Command: $command"
    echo "│  Item: \"$item_text\""
    echo "│                                                     │"
    echo "│  Did it work correctly? [Y/n/s/d/?]                 │"
    echo "└─────────────────────────────────────────────────────┘"

    local response
    read -r -t "${PROMPT_TIMEOUT:-30}" response || response="timeout"

    case "$response" in
        Y|y|"")
            mark_item_verified "$item"
            echo "✓ Marked as verified. Thank you!"
            ;;
        n|N)
            create_bug_report "$command" "$exit_code" "$item"
            ;;
        s)
            add_session_skip "$command"
            echo "Skipped for this session."
            ;;
        d)
            add_permanent_skip "$command"
            echo "Won't ask for this command again."
            ;;
        "?")
            show_verification_help
            prompt_verification "$command" "$exit_code"  # Re-prompt
            ;;
        timeout)
            echo "Timed out, skipping."
            ;;
    esac
}
```

### 8.4 Integration Point (pl script)

```bash
# In pl script, after command execution

# Existing auto-logging
if type log_verification_if_enabled &>/dev/null; then
    log_verification_if_enabled "$script" "$exit_code"
fi

# NEW: Opportunistic verification prompt
if type should_prompt_verification &>/dev/null; then
    if should_prompt_verification "$script $*"; then
        prompt_verification "$script $*" "$exit_code"
    fi
fi
```

---

## 9. Implementation Phases

### Phase 1: Foundation (Week 1)
- [ ] Create `lib/verify-opportunistic.sh`
- [ ] Add tester configuration to `example.nwp.yml`
- [ ] Add tester fields to coders schema (`tester`, `verifications`, `bugs_reported`)
- [ ] Add TST column to `pl coders` display
- [ ] Implement `pl coders tester` subcommand
- [ ] Implement `should_prompt_verification()`
- [ ] Verification prompt with full `how_to_verify` details

### Phase 2: Bug Reports (Week 2)
- [ ] Create `lib/verify-issues.sh`
- [ ] Implement automatic diagnostics collection
- [ ] Local issue storage in `.logs/issues/`
- [ ] Issue management commands (`pl verify issues`)

### Phase 3: AI-Assisted Fixing (Week 3)
- [ ] Create `lib/verify-fix.sh`
- [ ] Create `scripts/commands/fix.sh`
- [ ] Implement TUI for issue selection
- [ ] Issue detail view with diagnostics
- [ ] Fix workflow with status transitions
- [ ] Claude marks issues as fixed

### Phase 4: Todo Integration (Week 4)
- [ ] Update `scripts/commands/todo.sh`
- [ ] Add BUGS category from `.logs/issues/`
- [ ] Implement filtering (`--bugs`, `--tasks`, `--verify`)
- [ ] Cross-linking between todo and fix commands

### Phase 5: Final Integration (Week 5)
- [ ] Hook into `pl` script
- [ ] Link issues to verification items
- [ ] Verification blocking for items with open issues
- [ ] GitLab/GitHub submission support
- [ ] End-to-end testing

---

## 10. Success Metrics

| Metric | Target |
|--------|--------|
| Tester adoption | 2+ active testers |
| Human verification rate | +20% coverage in first month |
| Bug discovery | 5+ issues found via opportunistic prompts |
| Prompt acceptance rate | >50% (users respond vs timeout) |
| Issue resolution rate | 80% of issues resolved within 2 weeks |
| `pl fix` usage | 90% of issues fixed via `pl fix` |
| Todo integration | Bugs visible in `pl todo` within 1 second of creation |

---

## 11. User Experience Considerations

### 11.1 Non-Intrusive Design

- **Only prompt for unverified items** - Once verified, no more prompts
- **Session skip** - User can silence prompts for current session
- **Permanent skip** - User can blacklist specific commands
- **Timeout** - Prompts auto-dismiss, don't block workflows
- **Quick responses** - Single keypress (Y/n/s/d)

### 11.2 Value Exchange

The system should feel like a fair exchange:
- User gives: 2 seconds to confirm something worked
- User gets: Bug reports handled, verification attribution, better NWP

### 11.3 Transparency

```bash
# User can see their verification contributions
$ pl verify contributions
┌────────────────────────────────────────────────────┐
│ Your Verification Contributions                    │
├────────────────────────────────────────────────────┤
│ Items verified: 23                                 │
│ Bugs reported: 3                                   │
│ Issues resolved: 2                                 │
│                                                    │
│ Recent:                                            │
│  ✓ backup_0 - "Full backup creates archive"       │
│  ✓ restore_1 - "Restore to new site works"        │
│  ⚠ copy_3 - Bug reported (NWP-20260118-143)      │
└────────────────────────────────────────────────────┘
```

---

## 12. Approval

| Role | Name | Date | Signature |
|------|------|------|-----------|
| Author | Claude Opus 4.5 | 2026-01-18 | |
| Requirements | Rob | 2026-01-18 | |
| Reviewer | | | |
| Approver | | | |

---

**End of Proposal**
