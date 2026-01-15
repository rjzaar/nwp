# Verification Execution Proposal
**Systematic Testing and Verification of All 553 Checklist Items**

**Version:** 1.0
**Date:** 2026-01-15
**Last Updated:** 2026-01-15
**Status:** PROPOSED
**Priority:** HIGH
**Estimated Effort:** 4-6 hours

---

## Executive Summary

The `.verification.yml` file contains 553 checklist items across 81 features, each with `how_to_verify` instructions and `related_docs` references. This proposal outlines a systematic approach to:

1. Execute each verification test following the `how_to_verify` instructions
2. Fix any errors or issues discovered during testing
3. Mark items as verified upon successful completion
4. Use multiple Sonnet agents in parallel to accelerate the process

**Key Principle:** Each agent works on a completely separate set of features to avoid conflicts.

---

## Problem Statement

### Current State

| Metric | Value |
|--------|-------|
| Total Features | 81 |
| Total Checklist Items | 553 |
| Items Verified | 0 (0%) |
| Items with how_to_verify | 553 (100%) |

### Goal

- Execute all 553 verification tests
- Fix any bugs or issues discovered
- Achieve 80%+ verification coverage
- Document any items that cannot be verified (missing prerequisites, etc.)

---

## Agent Architecture

### Parallel Agent Strategy

**Total Agents:** 5 Sonnet agents running in parallel

Each agent is assigned a **non-overlapping set of features** to prevent conflicts:

| Agent | Features | Items | Category Focus |
|-------|----------|-------|----------------|
| Agent 1 | 1-16 | 152 | Core Scripts (setup, install, live, backup, etc.) |
| Agent 2 | 17-32 | 71 | Deployment & Utilities (security, badges, etc.) |
| Agent 3 | 33-48 | 156 | Testing & Install (test*, lib_install_*, etc.) |
| Agent 4 | 49-64 | 90 | Core Libraries (lib_tui, lib_cloud*, etc.) |
| Agent 5 | 65-81 | 84 | Config, Services & Integrations |

### Conflict Prevention Rules

**CRITICAL: These rules MUST be followed to prevent conflicts**

1. **File Ownership**
   - `.verification.yml` - Only ONE agent writes at a time (see Coordination Protocol)
   - Code files - Agent only modifies files within their assigned features
   - Shared libraries - Coordinate via lock file before modifying

2. **Site Isolation**
   - Each agent creates test sites with unique names: `test-agent1-<feature>`, `test-agent2-<feature>`, etc.
   - Never use existing sites or shared test sites
   - Clean up test sites after verification

3. **Port Isolation**
   - DDEV automatically handles port allocation
   - If port conflict occurs, stop and restart DDEV

4. **Git Isolation**
   - Agents do NOT commit during testing
   - All commits happen in a final consolidation phase
   - Work is saved to temporary status files

---

## Coordination Protocol

### Lock File System

To prevent `.verification.yml` write conflicts:

```bash
# Lock file location
LOCK_FILE="/tmp/nwp-verify-lock"

# Before writing to .verification.yml
acquire_lock() {
    local agent_id="$1"
    local max_wait=60
    local waited=0

    while [[ -f "$LOCK_FILE" ]] && [[ $waited -lt $max_wait ]]; do
        sleep 2
        waited=$((waited + 2))
    done

    if [[ -f "$LOCK_FILE" ]]; then
        echo "ERROR: Could not acquire lock after ${max_wait}s"
        return 1
    fi

    echo "$agent_id:$(date +%s)" > "$LOCK_FILE"
    return 0
}

# After writing
release_lock() {
    rm -f "$LOCK_FILE"
}
```

### Status File System

Each agent maintains a separate status file:

```
/tmp/nwp-verify-agent1-status.json
/tmp/nwp-verify-agent2-status.json
...
```

Format:
```json
{
  "agent_id": "agent1",
  "started_at": "2026-01-15T10:00:00Z",
  "features_assigned": ["setup", "install", "status", ...],
  "features_completed": ["setup", "install"],
  "features_in_progress": "status",
  "items_verified": 45,
  "items_failed": 2,
  "items_skipped": 3,
  "errors": [
    {"feature": "backup", "item": 3, "error": "Site not running"}
  ]
}
```

---

## Execution Protocol

### Phase 1: Preparation (10 minutes)

**Orchestrator (Main Claude instance) performs:**

1. **Create feature assignments**
   ```bash
   # Extract feature list and divide among agents
   grep "^  [a-z_-]*:" .verification.yml | sed 's/://g' | sed 's/^  //' > /tmp/all-features.txt
   split -n l/5 /tmp/all-features.txt /tmp/agent-features-
   ```

2. **Create status directory**
   ```bash
   mkdir -p /tmp/nwp-verify-status
   ```

3. **Backup current state**
   ```bash
   cp .verification.yml /tmp/verification.yml.backup-$(date +%Y%m%d%H%M%S)
   ```

4. **Initialize lock file system**
   ```bash
   rm -f /tmp/nwp-verify-lock
   ```

### Phase 2: Parallel Verification (3-5 hours)

**Each agent receives these instructions:**

```
AGENT INSTRUCTIONS - Agent {N}

YOUR ASSIGNED FEATURES:
{list of features}

RULES:
1. Only work on YOUR assigned features - never touch others
2. Create test sites named: test-agent{N}-{feature}
3. Follow how_to_verify instructions exactly
4. Record results in /tmp/nwp-verify-agent{N}-status.json
5. Do NOT commit to git - save status only
6. If you encounter a blocking issue, skip and note it

PROCESS FOR EACH FEATURE:
1. Read the feature's checklist items from .verification.yml
2. For each item:
   a. Read the how_to_verify instructions
   b. Execute the test steps
   c. If SUCCESS: Mark verified in status file
   d. If FAILURE:
      - Try to fix the issue
      - If fixed, re-test and mark verified
      - If cannot fix, note error and skip
   e. If BLOCKED (missing prereq): Skip and note reason

MARKING ITEMS VERIFIED:
- Acquire lock before modifying .verification.yml
- Use: ./pl verify complete <feature> <item_number>
- Release lock immediately after

CLEANUP:
- Delete test sites: ddev delete -O test-agent{N}-*
- Update final status in status file

WHEN FINISHED:
- Set status to "completed" in status file
- Report summary of verified/failed/skipped items
```

### Phase 3: Consolidation (30 minutes)

**Orchestrator performs:**

1. **Collect all status files**
   ```bash
   cat /tmp/nwp-verify-agent*-status.json | jq -s '.'
   ```

2. **Generate summary report**
   - Total items verified
   - Total items failed (with reasons)
   - Total items skipped (with reasons)
   - Code fixes made

3. **Create consolidated commit**
   ```bash
   git add .verification.yml
   git add [any fixed files]
   git commit -m "Verify X items across Y features (Z% coverage)"
   ```

4. **Cleanup**
   ```bash
   rm -f /tmp/nwp-verify-lock
   rm -f /tmp/nwp-verify-agent*-status.json
   ```

---

## Error Handling

### Common Issues and Solutions

| Issue | Solution |
|-------|----------|
| **Site won't start** | `ddev restart`, check Docker, try different site name |
| **Port conflict** | `ddev poweroff && ddev start` |
| **Database error** | `ddev import-db` or recreate site |
| **Command not found** | Check PATH, source lib files |
| **Permission denied** | Check file permissions, run as correct user |
| **Lock timeout** | Check if other agent crashed, manually remove lock |
| **Test site exists** | Delete with `ddev delete -O <sitename>` |

### Agent Crash Recovery

If an agent crashes or times out:

1. **Check status file** - See what was completed
2. **Release any held lock** - `rm -f /tmp/nwp-verify-lock`
3. **Clean up test sites** - `ddev delete -O test-agent{N}-*`
4. **Resume or reassign** - Start new agent with remaining features

### Conflict Resolution

If two agents accidentally modify the same file:

1. **Stop both agents**
2. **Check git status** - Identify conflicting changes
3. **Manually merge** - Keep both sets of changes
4. **Reassign features** - Ensure no overlap
5. **Resume agents**

---

## Feature Assignments

### Agent 1: Core Scripts (Features 1-16) - 152 items

```
setup, install, status, modify, backup, restore, sync, copy,
delete, make, migration, import, live, produce, podcast, schedule
```

**Prerequisites:** DDEV running, test sites available
**Note:** Heaviest workload - includes `live` with 49 items and `install` with 24 items

### Agent 2: Deployment & Utilities (Features 17-32) - 71 items

```
security, setup_ssh, uninstall, badges, email, report, rollback,
storage, theme, contribute, coder_setup, coders, seo_check,
run_tests, upstream, migrate_secrets
```

**Prerequisites:** GitLab access (for badges), email config (for email)
**Note:** Lightest workload - mostly small utility commands

### Agent 3: Testing & Install Libraries (Features 33-48) - 156 items

```
security_check, verify, pl_cli, test_nwp, test, testos,
lib_cli_register, lib_ddev_generate, lib_developer, lib_env_generate,
lib_install_common, lib_install_drupal, lib_install_gitlab,
lib_install_moodle, lib_install_podcast, lib_install_steps
```

**Prerequisites:** DDEV, test sites for installation testing
**Note:** Heaviest workload - includes `testos` (19), install libs (58 combined)

### Agent 4: Core Libraries (Features 49-64) - 90 items

```
lib_live_server_setup, lib_terminal, lib_tui, lib_checkbox,
lib_yaml_write, lib_common, lib_ui, lib_git, lib_cloudflare,
lib_linode, lib_remote, lib_badges, lib_state, lib_database_router,
lib_testing, lib_preflight
```

**Prerequisites:** API tokens for cloud services (some tests)
**Note:** Moderate workload - includes `lib_live_server_setup` (11), `lib_linode` (10)

### Agent 5: Config, Services & Integrations (Features 65-81) - 84 items

```
lib_safe_ops, lib_sanitize, lib_import, lib_import_tui,
lib_server_scan, lib_frontend, config_example, config_secrets,
avc_moodle_setup, avc_moodle_status, avc_moodle_sync,
avc_moodle_test, bootstrap_coder, doctor, lib_avc_moodle,
lib_podcast, lib_ssh
```

**Prerequisites:** Moodle instance (for AVC Moodle tests)
**Note:** 17 features but moderate item count - `avc_moodle_setup` (11) is largest

---

## Verification Marking

### Using pl verify Commands

```bash
# Mark a specific checklist item as complete
./pl verify complete <feature> <item_number>

# Example: Mark backup item 1 as complete
./pl verify complete backup 1

# View current status
./pl verify details <feature>
```

### Manual YAML Updates (If Needed)

If pl verify commands fail, agents can update `.verification.yml` directly:

```yaml
# Change this:
      - text: "Test full backup"
        completed: false
        completed_by: null
        completed_at: null

# To this:
      - text: "Test full backup"
        completed: true
        completed_by: "claude-agent1"
        completed_at: "2026-01-15T12:00:00Z"
```

**IMPORTANT:** Always acquire lock before manual edits!

---

## Success Criteria

### Minimum Acceptance

- [ ] 80% of items verified (442/553)
- [ ] All critical features (setup, install, backup, restore) 100% verified
- [ ] All errors documented with clear descriptions
- [ ] No regressions introduced (existing tests still pass)

### Ideal Outcome

- [ ] 95%+ of items verified (525+/553)
- [ ] All discovered bugs fixed
- [ ] Skipped items have clear documentation of why
- [ ] Comprehensive report of verification results

### Metrics to Track

```bash
# After completion, run:
./pl verify summary

# Expected output:
# Verified: X (Y%)
# Unverified: Z
# Modified: 0
```

---

## Risk Mitigation

### Risk 1: Agent Conflicts

**Mitigation:**
- Strict feature assignment with no overlap
- Lock file system for shared resources
- Status files for coordination

**Recovery:**
- Manual merge of conflicting changes
- Restart affected agent with reduced scope

### Risk 2: Test Environment Issues

**Mitigation:**
- Each agent uses isolated test sites
- Unique naming convention prevents collisions
- DDEV handles port allocation

**Recovery:**
- `ddev poweroff && ddev start`
- Delete and recreate test sites
- Skip to next feature if persistent issues

### Risk 3: Long-Running Tests

**Mitigation:**
- Set timeout for each item (5 minutes max)
- Skip and note if exceeds timeout
- Prioritize quick tests first

**Recovery:**
- Mark as skipped with "timeout" reason
- Continue with next item

### Risk 4: Code Fixes Break Other Features

**Mitigation:**
- Run test suite after fixes: `./pl test-nwp`
- Small, focused fixes only
- Document all changes made

**Recovery:**
- Revert problematic fix
- Note issue for manual review

---

## Execution Checklist

### Before Starting

- [ ] All agents understand their feature assignments
- [ ] Lock file system is initialized
- [ ] Status directory created
- [ ] .verification.yml backed up
- [ ] Docker/DDEV running and healthy

### During Execution

- [ ] Monitor agent status files periodically
- [ ] Watch for lock file stuck (>5 minutes old)
- [ ] Check for crashed agents
- [ ] Ensure test sites are being cleaned up

### After Completion

- [ ] All status files collected
- [ ] Summary report generated
- [ ] Changes committed to git
- [ ] Test sites cleaned up
- [ ] Lock files removed

---

## Agent Launch Template

Use this template to launch each agent:

```
Launch Agent {N} for verification testing:

CONTEXT:
You are Agent {N} of 5 parallel verification agents.
Your job is to test and verify checklist items for your assigned features.

ASSIGNED FEATURES (DO NOT WORK ON ANY OTHERS):
{paste feature list}

STATUS FILE:
Write your progress to: /tmp/nwp-verify-agent{N}-status.json

LOCK FILE:
Before modifying .verification.yml:
1. Check /tmp/nwp-verify-lock exists
2. If exists, wait up to 60 seconds
3. Create lock file with your agent ID
4. Make changes
5. Remove lock file immediately

TEST SITE NAMING:
Use: test-a{N}-{feature} (e.g., test-a1-backup, test-a1-restore)

PROCESS:
1. For each feature in your list:
   a. Get checklist items from .verification.yml
   b. For each item, read how_to_verify
   c. Execute the verification steps
   d. Fix any issues found
   e. Mark as verified if successful
   f. Note in status file if skipped/failed
2. Clean up all test sites when done
3. Update final status

DO NOT:
- Commit to git
- Work on features not in your list
- Leave test sites running
- Hold the lock for more than 30 seconds

WHEN DONE:
Report: items verified, items failed, items skipped, any bugs fixed
```

---

## Appendix: Feature List Reference

```bash
# Generate current feature list:
grep "^  [a-z_-]*:" .verification.yml | sed 's/://g' | sed 's/^  //' | nl
```

### Complete Feature List (81 total)

| # | Feature | Agent | # | Feature | Agent |
|---|---------|-------|---|---------|-------|
| 1 | setup | 1 | 42 | lib_env_generate | 3 |
| 2 | install | 1 | 43 | lib_install_common | 3 |
| 3 | status | 1 | 44 | lib_install_drupal | 3 |
| 4 | modify | 1 | 45 | lib_install_gitlab | 3 |
| 5 | backup | 1 | 46 | lib_install_moodle | 3 |
| 6 | restore | 1 | 47 | lib_install_podcast | 3 |
| 7 | sync | 1 | 48 | lib_install_steps | 3 |
| 8 | copy | 1 | 49 | lib_live_server_setup | 4 |
| 9 | delete | 1 | 50 | lib_terminal | 4 |
| 10 | make | 1 | 51 | lib_tui | 4 |
| 11 | migration | 1 | 52 | lib_checkbox | 4 |
| 12 | import | 1 | 53 | lib_yaml_write | 4 |
| 13 | live | 1 | 54 | lib_common | 4 |
| 14 | produce | 1 | 55 | lib_ui | 4 |
| 15 | podcast | 1 | 56 | lib_git | 4 |
| 16 | schedule | 1 | 57 | lib_cloudflare | 4 |
| 17 | security | 2 | 58 | lib_linode | 4 |
| 18 | setup_ssh | 2 | 59 | lib_remote | 4 |
| 19 | uninstall | 2 | 60 | lib_badges | 4 |
| 20 | badges | 2 | 61 | lib_state | 4 |
| 21 | email | 2 | 62 | lib_database_router | 4 |
| 22 | report | 2 | 63 | lib_testing | 4 |
| 23 | rollback | 2 | 64 | lib_preflight | 4 |
| 24 | storage | 2 | 65 | lib_safe_ops | 5 |
| 25 | theme | 2 | 66 | lib_sanitize | 5 |
| 26 | contribute | 2 | 67 | lib_import | 5 |
| 27 | coder_setup | 2 | 68 | lib_import_tui | 5 |
| 28 | coders | 2 | 69 | lib_server_scan | 5 |
| 29 | seo_check | 2 | 70 | lib_frontend | 5 |
| 30 | run_tests | 2 | 71 | config_example | 5 |
| 31 | upstream | 2 | 72 | config_secrets | 5 |
| 32 | migrate_secrets | 2 | 73 | avc_moodle_setup | 5 |
| 33 | security_check | 3 | 74 | avc_moodle_status | 5 |
| 34 | verify | 3 | 75 | avc_moodle_sync | 5 |
| 35 | pl_cli | 3 | 76 | avc_moodle_test | 5 |
| 36 | test_nwp | 3 | 77 | bootstrap_coder | 5 |
| 37 | test | 3 | 78 | doctor | 5 |
| 38 | testos | 3 | 79 | lib_avc_moodle | 5 |
| 39 | lib_cli_register | 3 | 80 | lib_podcast | 5 |
| 40 | lib_ddev_generate | 3 | 81 | lib_ssh | 5 |
| 41 | lib_developer | 3 | | | |

### Items Per Feature (Top 20)

| Feature | Items | Feature | Items |
|---------|-------|---------|-------|
| live | 49 | lib_install_podcast | 8 |
| install | 24 | lib_install_gitlab | 8 |
| testos | 19 | lib_ddev_generate | 8 |
| lib_install_drupal | 16 | lib_cli_register | 8 |
| lib_install_common | 16 | bootstrap_coder | 8 |
| test | 13 | backup | 8 |
| lib_live_server_setup | 11 | lib_preflight | 7 |
| lib_developer | 11 | lib_env_generate | 7 |
| avc_moodle_setup | 11 | modify | 6 |
| lib_linode | 10 | security | 6 |
| lib_install_steps | 10 | restore | 6 |
| lib_install_moodle | 10 | sync | 6 |

---

## Workload Distribution

The item distribution is uneven due to feature groupings:

```
Agent 3 ████████████████████████████████ 156 (28%)
Agent 1 ██████████████████████████████   152 (28%)
Agent 4 ██████████████████              90 (16%)
Agent 5 █████████████████               84 (15%)
Agent 2 ██████████████                  71 (13%)
```

**Implication:** Agents 1 and 3 will take longer to complete. Consider:
- Launching Agents 2, 4, and 5 first, then reusing their instances for overflow
- Splitting heavy features (`live`, `install`, `testos`) into separate runs

---

## Quick Start

### One-Command Launch (Orchestrator)

```bash
# 1. Preparation
cd /home/rob/nwp
mkdir -p /tmp/nwp-verify-status
cp .verification.yml /tmp/verification.yml.backup-$(date +%Y%m%d%H%M%S)
rm -f /tmp/nwp-verify-lock

# 2. Launch all 5 agents in parallel in Claude Code:
# "Launch 5 verification agents in parallel following docs/VERIFICATION_EXECUTION_PROPOSAL.md"
```

### Manual Agent Launch

For each agent, provide these instructions:

```
You are verification Agent N. Read docs/VERIFICATION_EXECUTION_PROPOSAL.md fully.

Your features: [paste from Feature Assignments section]

Work through each feature's checklist items in .verification.yml.
Follow the how_to_verify instructions exactly.
Mark items complete with: ./pl verify complete <feature> <item_number>
Record progress to: /tmp/nwp-verify-agentN-status.json

When done, report: items verified, items failed, items skipped.
```

---

## Approval

**Prepared By:** Claude Opus 4.5
**Date:** 2026-01-15
**Status:** PROPOSED

**To Execute:**
1. Review and approve this proposal
2. Confirm agent assignments are acceptable
3. Ensure prerequisites are available (DDEV, API tokens, test sites)
4. Run Quick Start commands to launch verification

---

**END OF PROPOSAL**
