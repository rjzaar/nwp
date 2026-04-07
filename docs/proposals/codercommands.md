# Plan: Analysis of Coder Commands (bootstrap-coder, coders, coder-setup)

## Question
Do we need all three coder commands? What should be done here?

## Analysis Summary

### The Three Commands Serve Distinct Purposes

| Command | Purpose | Target User | When Run |
|---------|---------|-------------|----------|
| **bootstrap-coder.sh** | Self-service onboarding | Individual coder | Once, on coder's own machine |
| **coders.sh** | Admin monitoring TUI | Project admin | Ongoing, from central location |
| **coder-setup.sh** | Infrastructure provisioning | Project admin | Before coder can start |

### Workflow Visualization

```
ADMIN WORKFLOW:
┌─────────────────────────────────────────────────────────────────┐
│  1. pl coder add greg                                           │
│     (coder-setup.sh creates DNS + GitLab account)               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  2. pl coders                                                   │
│     (coders.sh TUI shows greg with partial onboarding status)   │
└─────────────────────────────────────────────────────────────────┘

CODER WORKFLOW (on greg's machine):
┌─────────────────────────────────────────────────────────────────┐
│  3. pl bootstrap-coder                                          │
│     (bootstrap-coder.sh detects identity, configures local env) │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  4. Admin sees greg's status update in pl coders TUI            │
│     (All green checkmarks for GL, SSH, DNS, etc.)               │
└─────────────────────────────────────────────────────────────────┘
```

## Recommendation: Keep All Three, But Improve

### Do NOT Merge
The commands are **complementary, not redundant**:
- `bootstrap-coder` runs on the coder's machine (self-service)
- `coders` is the admin dashboard (monitoring)
- `coder-setup` is the admin provisioning tool (infrastructure)

Merging would conflate different user roles and contexts.

### Improvements to Consider

1. **Shared Libraries** - Extract duplicated functions to `/lib/`:
   - `lib/coder-validation.sh` - DNS/GitLab checks
   - `lib/coder-config.sh` - YAML parsing for coder data

2. **Unified CLI Entry** - Make `pl coder` a gateway to all three:
   ```bash
   pl coder add <name>       # → coder-setup.sh add
   pl coder remove <name>    # → coder-setup.sh remove
   pl coder bootstrap        # → bootstrap-coder.sh
   pl coder list             # → coders.sh list (non-TUI)
   pl coder manage           # → coders.sh (TUI)
   pl coder tester <name>    # → NEW: tester management
   ```

3. **Add Tester Support to coders.sh** - Per P55 proposal:
   - Add TST column to the TUI
   - Add `pl coders tester` subcommand
   - Track verifications/bugs_reported per coder

## Critical Security Finding: No Permission Enforcement

### How Admin Status Is Currently Determined

**Source of Truth: LOCAL nwp.yml ONLY**

Admin/steward status is determined solely from the local `nwp.yml` file:
```yaml
other_coders:
  coders:
    rob:
      role: steward    # ← This is the ONLY thing that makes someone admin
```

### Data Flow: Where Does `pl coders` Get Its Information?

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           DATA FLOW                                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   nwp.yml (PRIMARY)                      GitLab (SECONDARY)                  │
│   ─────────────────                      ─────────────────                   │
│                                                                              │
│   • Coder list      ◄────────────────    (manual add)                        │
│   • Role            ◄────────────────    (manual set)                        │
│   • Status          ◄────────────────    (manual set)                        │
│   • Added date      ◄────────────────    (manual set)                        │
│   • Commits         ◄───── SYNC ─────    GitLab API events                   │
│   • MRs             ◄───── SYNC ─────    GitLab API events                   │
│   • Reviews         ◄───── SYNC ─────    GitLab API events                   │
│                                                                              │
│   Role changes      ────── PUSH ─────►   GitLab group membership             │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Primary data source: `nwp.yml`** (line 46: `CONFIG_FILE="${PROJECT_ROOT}/nwp.yml"`)

| Data | Source | How Populated |
|------|--------|---------------|
| Coder list | nwp.yml | `yq '.other_coders.coders \| keys[]'` |
| Role | nwp.yml | Manual or via TUI modify |
| Status | nwp.yml | Manual or via TUI modify |
| Commits/MRs | nwp.yml | Fetched from GitLab, **saved to nwp.yml** |

**GitLab is used for:**
- ✅ Fetching contribution stats → **cached into nwp.yml**
- ✅ Verifying user exists (`check_gitlab_user()`)
- ✅ Checking group membership (`check_gitlab_group()`)
- ✅ Checking SSH keys (`check_gitlab_ssh()`)
- ✅ Pushing role changes TO GitLab (one-way sync)
- ❌ **NOT** determining who is admin
- ❌ **NOT** validating role changes
- ❌ **NOT** as a source of truth for permissions

**Role → GitLab Access Level mapping** (from `lib/git.sh`):
```
NWP Role      → GitLab Access Level
newcomer      → (not synced)
contributor   → 30 (Developer)
core          → 40 (Maintainer)
steward       → 50 (Owner)
```

### Can Someone Make Themselves Admin?

**YES - CRITICAL VULNERABILITY**

Anyone with shell access can:
```bash
# Method 1: Direct edit
vim nwp.yml  # Change role: contributor → role: steward

# Method 2: Use the TUI (no permission check)
pl coders    # Select self, press 'm', change role to steward

# Method 3: Use promotion function
pl coders    # Select self, press 'p', promote to steward
```

**What prevents self-promotion: NOTHING**

The only safeguard is audit logging:
```bash
# From coders.sh line 1052
echo "$(date) | PROMOTE | $name | -> $new_role | by $(whoami)" >> logs/promotions.log
```

### Privilege Escalation Attack

```bash
# Attacker scenario:
cd ~/nwp
sed -i 's/role: contributor/role: steward/' nwp.yml
pl coders sync  # Optional: sync elevated role to GitLab
# Attacker is now steward with full admin access
```

### The Real Fix: Use GitLab as Source of Truth

Checking local nwp.yml is insufficient because it can be edited. The fix must validate against GitLab:

```bash
# NEW: Get ACTUAL role from GitLab API, not local config
get_actual_gitlab_level() {
    local username="$1"
    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)
    local group_id=$(get_nwp_group_id)

    curl -s -H "PRIVATE-TOKEN: $token" \
        "https://${gitlab_url}/api/v4/groups/${group_id}/members/${username}" \
        | jq -r '.access_level // 0'
}

require_steward() {
    local current_user=$(git config user.name)
    local actual_level=$(get_actual_gitlab_level "$current_user")

    if [[ "$actual_level" -lt 50 ]]; then
        echo "Error: This operation requires GitLab Owner access (level 50)"
        echo "Your actual GitLab level: $actual_level"
        exit 1
    fi
}
```

### Operations by Permission Level

| Operation | Required GitLab Level |
|-----------|----------------------|
| View coders (read-only) | Any (0+) |
| View own stats | Any (0+) |
| Enable own tester status | Developer (30+) |
| Modify other's tester status | Maintainer (40+) |
| Promote/demote coders | Owner (50) |
| Delete coders | Owner (50) |
| Add new coders | Owner (50) |

### Summary

| Question | Current State | Required Fix |
|----------|--------------|--------------|
| Source of truth | Local nwp.yml | GitLab group membership |
| Self-promotion possible? | YES | Must check GitLab API |
| Authorization checks | None | Add `require_steward()` |
| What determines admin? | nwp.yml role field | GitLab access_level = 50 |

## Conclusion

**Keep all three commands.** They serve distinct, necessary purposes in the coder lifecycle. The tester functionality from P55 should be added to `coders.sh` since that's where coder attributes are managed.

**Critical: Add GitLab-based permission checks** before implementing P55 tester features, otherwise any coder could grant themselves tester privileges.
