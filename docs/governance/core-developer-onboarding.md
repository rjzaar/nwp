# Core Developer Onboarding Proposal

A comprehensive proposal for streamlining the onboarding of new core developers to NWP, maximizing automation, and establishing clear access governance.

**Status:** PROPOSAL
**Created:** January 2026
**Related:** DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md, CODER_ONBOARDING.md, ROADMAP.md

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Current State Analysis](#current-state-analysis)
3. [Access Levels for Core Developers](#access-levels-for-core-developers)
4. [Trust Progression Model](#trust-progression-model)
5. [Automation Opportunities](#automation-opportunities)
6. [Developer Level Detection](#developer-level-detection)
7. [Coders Management TUI](#coders-management-tui)
8. [Core Developer Checklist](#core-developer-checklist)
9. [Implementation Plan](#implementation-plan)

---

## Executive Summary

This proposal establishes a streamlined, automated onboarding process for NWP core developers that:

- **Maximizes automation** of DNS, GitLab, and infrastructure provisioning
- **Defines clear access levels** with a trust progression model
- **Enables developer level detection** so local NWP code knows who's using it
- **Provides a TUI management interface** for administering all coders
- **Tracks contributions** across multiple dimensions (commits, reviews, docs, etc.)

**Key Innovations:**

1. **Developer Identity System**: Local NWP installation knows the developer's role and adjusts behavior accordingly
2. **Contribution Tracking**: Automated metrics on commits, reviews, issues, and documentation
3. **Self-Service Where Safe**: Automate what can be automated, require approval only where necessary

---

## Current State Analysis

### What Currently Exists (Strong Foundation)

#### 1. Automated Onboarding Infrastructure
- **`coder-setup.sh`** (693 lines) - Fully automates:
  - NS delegation via Cloudflare API for `<coder>.nwpcode.org`
  - GitLab user creation with group membership
  - Developer access level (30) assignment to `nwp` group
  - Config tracking in `nwp.yml`

#### 2. Comprehensive Documentation
- **`CODER_ONBOARDING.md`** (410 lines) - 10-step walkthrough
- **`DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md`** (1,223 lines) - Governance framework

#### 3. GitLab Integration Functions
Located in `lib/git.sh`:
- `gitlab_create_user()` - Creates user with temp password
- `gitlab_add_user_to_group()` - Adds to group with access level
- `gitlab_list_users()` - Lists all users

### Critical Gaps

| Gap | Current State | Proposed Solution |
|-----|---------------|-------------------|
| No self-service | Admin runs script manually | Web form + approval pipeline |
| Linode is manual | 6+ manual steps | Automated provisioning |
| No role definitions | Implicit understanding | Formal ROLES.md |
| Governance not active | Proposal document only | Implement ADR system |
| No offboarding | DNS removed only | Full access revocation |
| No level detection | Code doesn't know user | Developer identity config |

---

## Access Levels for Core Developers

### Resource Access Matrix

| Resource | Newcomer | Contributor | Core Dev | Steward |
|----------|----------|-------------|----------|---------|
| **GitLab Access Level** | N/A (fork) | Developer (30) | Maintainer (40) | Owner (50) |
| **GitLab Group: nwp** | N/A | Member | Member | Owner |
| **Merge to main** | No | No | Yes | Yes |
| **Code review** | No | Assigned | Assign others | All |
| **Own Linode** | No | Yes | Yes | Yes |
| **Subdomain delegation** | No | Yes | Yes | Yes |
| **GitHub canonical** | Fork only | Fork only | Write | Admin |
| **CI/CD variables** | No | No | Protected | All |
| **Secrets tier** | None | Infra only | Infra only | All |
| **Standing orders edit** | No | No | Propose | Approve |

### GitLab Access Level Reference

| Level | Name | Capabilities |
|-------|------|--------------|
| 10 | Guest | View issues, leave comments |
| 20 | Reporter | View code, create issues |
| 30 | Developer | Push to non-protected branches, create MRs |
| 40 | Maintainer | Push to protected branches, merge MRs, manage CI/CD |
| 50 | Owner | Full admin, delete project, manage members |

---

## Trust Progression Model

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DEVELOPER TRUST PROGRESSION                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  NEWCOMER          CONTRIBUTOR         CORE DEVELOPER        STEWARD       │
│  (Fork-based)      (Developer 30)      (Maintainer 40)       (Owner 50)    │
│                                                                             │
│  ┌─────────┐       ┌─────────┐         ┌─────────┐          ┌─────────┐    │
│  │  0 MRs  │──────▶│  5+ MRs │────────▶│ 50+ MRs │─────────▶│Appointed│    │
│  │  Start  │       │ 1 month │         │6+ months│          │ by vote │    │
│  └─────────┘       └─────────┘         └─────────┘          └─────────┘    │
│                                                                             │
│  Capabilities:     Capabilities:       Capabilities:        Capabilities:  │
│  - Fork & PR       - Direct push       - Merge to main      - All access   │
│  - Issue comments  - Feature branches  - Review others      - Arch decisions│
│  - Read docs       - Own subdomain     - CI/CD access       - Approve roles │
│                    - Linode server     - Release mgmt       - Standing orders│
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Promotion Criteria

#### Newcomer → Contributor
- 5+ merged PRs
- 1+ month active
- Positive review feedback
- Agrees to code of conduct
- **Action:** Admin runs `./coders.sh promote <name> contributor`

#### Contributor → Core Developer
- 50+ merged MRs
- 6+ months active
- Demonstrated code review capability
- Vouched by existing Core Developer
- **Action:** Admin runs `./coders.sh promote <name> core`

#### Core Developer → Steward
- Significant architectural contributions
- 1+ year as Core Developer
- Nominated by Steward, approved by vote
- **Action:** Requires governance vote

---

## Automation Opportunities

### 1. Linode Provisioning Automation

Add to `coder-setup.sh`:

```bash
cmd_provision() {
    local name="$1"
    local region="${2:-us-east}"
    local plan="${3:-g6-nanode-1}"

    # Create server
    linode-cli linodes create \
        --label "${name}-nwp" \
        --region "$region" \
        --type "$plan" \
        --image linode/ubuntu22.04 \
        --authorized_keys "$(get_coder_ssh_key "$name")"

    # Get IP
    local ip=$(linode-cli linodes list --label "${name}-nwp" --json | jq -r '.[0].ipv4[0]')

    # Create DNS zone
    linode-cli domains create --domain "${name}.nwpcode.org" --type master

    # Add DNS records
    local domain_id=$(linode-cli domains list --json | jq -r ".[] | select(.domain==\"${name}.nwpcode.org\") | .id")
    linode-cli domains records-create "$domain_id" --type A --name "" --target "$ip"
    linode-cli domains records-create "$domain_id" --type A --name "git" --target "$ip"
    linode-cli domains records-create "$domain_id" --type A --name "*" --target "$ip"

    # Bootstrap server
    ssh "root@$ip" 'bash -s' < scripts/bootstrap-coder-server.sh
}
```

### 2. Full Offboarding Cleanup

```bash
cmd_remove() {
    local name="$1"

    # Existing DNS removal...

    # GitLab cleanup
    gitlab_remove_user_from_group "$name" "nwp"
    gitlab_block_user "$name"

    # Update config
    remove_coder_from_config "$name"

    # Audit log
    log_offboarding "$name" "$(whoami)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Optional: Archive their contributions
    if confirm "Archive ${name}'s contribution history?"; then
        archive_coder_contributions "$name"
    fi
}
```

### 3. Self-Service Request Pipeline

```yaml
# .gitlab/onboarding-request.yml
stages:
  - request
  - approve
  - provision

request_access:
  stage: request
  script:
    - echo "Request from $CODER_NAME ($EMAIL)"
    - ./scripts/validate-request.sh "$CODER_NAME" "$EMAIL"
  rules:
    - if: $CI_PIPELINE_SOURCE == "trigger"

approve_access:
  stage: approve
  script:
    - ./coder-setup.sh add "$CODER_NAME" --email "$EMAIL" --fullname "$FULLNAME"
  when: manual
  needs: [request_access]

provision_infrastructure:
  stage: provision
  script:
    - ./coder-setup.sh provision "$CODER_NAME"
  when: manual
  needs: [approve_access]
```

---

## Developer Level Detection

### Overview

Enable NWP local installations to know the developer's role and adjust behavior accordingly.

### Implementation

#### 1. Developer Identity File

Each coder's NWP installation includes a developer identity file:

```yaml
# .nwp-developer.yml (in NWP root, gitignored)
developer:
  name: john
  email: john@example.com
  role: contributor  # newcomer, contributor, core, steward
  level: 30          # GitLab access level
  subdomain: john.nwpcode.org
  upstream: git.nwpcode.org

  # Auto-populated by sync
  registered: 2026-01-08
  last_sync: 2026-01-08T12:00:00Z

  # Contribution stats (synced from GitLab)
  contributions:
    commits: 47
    merge_requests: 12
    reviews: 8
    issues_created: 5
    issues_closed: 3
```

#### 2. Library Functions

```bash
# lib/developer.sh

# Get current developer role
get_developer_role() {
    local config="${PROJECT_ROOT}/.nwp-developer.yml"
    if [ -f "$config" ]; then
        yq -r '.developer.role // "unknown"' "$config"
    else
        echo "unknown"
    fi
}

# Get current developer level
get_developer_level() {
    local config="${PROJECT_ROOT}/.nwp-developer.yml"
    if [ -f "$config" ]; then
        yq -r '.developer.level // 0' "$config"
    else
        echo "0"
    fi
}

# Check if developer can perform action
can_developer() {
    local action="$1"
    local level=$(get_developer_level)

    case "$action" in
        "push_main")     [ "$level" -ge 40 ] ;;
        "merge")         [ "$level" -ge 40 ] ;;
        "review")        [ "$level" -ge 30 ] ;;
        "create_branch") [ "$level" -ge 30 ] ;;
        "view_secrets")  [ "$level" -ge 40 ] ;;
        *)               return 1 ;;
    esac
}

# Sync developer info from upstream
sync_developer_info() {
    local name=$(yq -r '.developer.name' "$config")
    local gitlab_url=$(get_gitlab_url)
    local token=$(get_gitlab_token)

    # Fetch from GitLab API
    local user_info=$(curl -s -H "PRIVATE-TOKEN: $token" \
        "https://${gitlab_url}/api/v4/users?username=${name}")

    # Update local config with contribution stats
    # ... implementation
}
```

#### 3. Role-Aware Commands

```bash
# Example: pl push (push to upstream)
cmd_push() {
    local role=$(get_developer_role)
    local branch=$(git branch --show-current)

    if [ "$branch" = "main" ]; then
        if ! can_developer "push_main"; then
            print_error "Your role ($role) cannot push directly to main"
            print_info "Create a feature branch and submit a merge request"
            return 1
        fi
    fi

    git push origin "$branch"
}
```

---

## Coders Management TUI

### Overview

A comprehensive interactive TUI for managing all coders, their access levels, and contributions. Features arrow-key navigation, bulk actions, auto-sync from GitLab, and detailed stats views.

### Main Interface

```
 NWP CODER MANAGEMENT   4 coders  Synced: 14:32:15  [2 selected]

   NAME            ROLE       STATUS   ADDED      COMMITS   MRs REVIEWS
   ─────────────── ────────── ──────── ────────── ──────── ────── ───────
 * [x] john        Contrib    active   2026-01-08       47     12       8
   [ ] alice       Core       active   2025-12-01      156     89      45
 * [x] bob         New        active   2026-01-05        3      1       0
   [ ] carol       Contrib    inactive 2025-11-15       28      7       3

───────────────────────────────────────────────────────────────────────────
 john - Contrib | 47 commits, 12 MRs | john.nwpcode.org
 ↑↓ Navigate  Space Select  Enter Details  Modify  Promote  Delete  Add  Sync  Quit
```

### Keyboard Controls

| Key | Action |
|-----|--------|
| **↑/↓** | Navigate up/down through coders |
| **PgUp/PgDn** | Jump 10 coders at a time |
| **Space** | Select/deselect coder for bulk actions |
| **Enter** | View detailed stats for current coder |
| **M** | Modify current coder (role, status, notes) |
| **P** | Promote selected coders (or current if none) |
| **D** | Delete selected coders (or current if none) |
| **A** | Add new coder |
| **S** | Sync contribution data from GitLab |
| **V** | Verify DNS and infrastructure |
| **R** | Reload data from config |
| **Q/Esc** | Quit |

### Detailed Stats View

Press **Enter** on any coder to see detailed statistics:

```
 CODER DETAILS: john

Identity
  Name:       john
  Role:       Contrib (level 30)
  Status:     active
  Registered: 2026-01-08
  Subdomain:  john.nwpcode.org

Contributions
  Commits:          47  ████████████████████████████████████████████████
  Merge Requests:   12  ████████████
  Reviews:           8  ████████

Promotion Path
  Current: Contributor
  Next:    Core Developer (requires 50+ MRs, 6+ months, vouched)

Actions
  [P] Promote    [M] Modify    [D] Delete    [V] Verify DNS

Press any key to return...
```

### Bulk Actions

Select multiple coders using **Space**, then:
- **P** - Promote all selected to a new role
- **D** - Delete all selected (with confirmation)

The header shows selection count: `[3 selected]`

### Auto-Sync from GitLab

- Automatically syncs on TUI launch
- Shows last sync time in header
- Press **S** to manually refresh
- Syncs: commits, merge requests, reviews

### Non-Interactive Commands

```bash
# Launch interactive TUI
./scripts/commands/coders.sh

# List all coders (non-interactive)
./scripts/commands/coders.sh list

# Sync from GitLab (non-interactive)
./scripts/commands/coders.sh sync

# Show help
./scripts/commands/coders.sh help
```

### Contribution Tracking Dimensions

| Dimension | Source | Metric |
|-----------|--------|--------|
| **Commits** | GitLab API | Total commits to any branch |
| **Merge Requests** | GitLab API | MRs created (merged, open, closed) |
| **Code Reviews** | GitLab API | MRs reviewed/approved |
| **Issues Created** | GitLab API | Issues opened |
| **Issues Resolved** | GitLab API | Issues closed by their commits |
| **Documentation** | Git log | Commits touching docs/ or *.md |
| **Tests Written** | Git log | Commits touching tests/ |
| **Time Active** | GitLab API | Days since first contribution |

---

## Core Developer Checklist

When onboarding a new core developer, ensure they have:

### Identity & Access
- [ ] GitLab account on git.nwpcode.org
- [ ] Added to `nwp` group with appropriate level
- [ ] SSH key registered in GitLab
- [ ] Email on distribution list (if applicable)
- [ ] `.nwp-developer.yml` configured locally

### Infrastructure
- [ ] NS delegation for `<name>.nwpcode.org`
- [ ] Own Linode account with API token
- [ ] Server provisioned and accessible
- [ ] DNS zone with A records configured
- [ ] SSL certificates obtained

### Configuration
- [ ] NWP cloned to server
- [ ] `nwp.yml` configured with their URL
- [ ] `.secrets.yml` with Linode token (infra only)
- [ ] First test site created successfully

### Governance
- [ ] Read CONTRIBUTING.md
- [ ] Read DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md
- [ ] Understands ADR process
- [ ] Knows where to find decision history
- [ ] Assigned first mentor/reviewer

---

## Implementation Plan

### Phase 1: Foundation (Week 1)
- [ ] Create `docs/decisions/` directory structure
- [ ] Create `docs/ROLES.md` with role matrix
- [ ] Create `CONTRIBUTING.md` as entry point
- [ ] Update CLAUDE.md with standing orders section
- [ ] Update ROADMAP.md with governance milestone

### Phase 2: Automation (Week 2)
- [ ] Add `provision` command to coder-setup.sh
- [ ] Add full offboarding to `remove` command
- [ ] Create `lib/developer.sh` for role detection
- [ ] Create `.nwp-developer.yml` schema

### Phase 3: TUI & Tracking (Week 3)
- [ ] Create `scripts/commands/coders.sh` TUI
- [ ] Implement contribution tracking via GitLab API
- [ ] Add promotion workflow
- [ ] Add sync functionality

### Phase 4: Self-Service (Future)
- [ ] Web form for onboarding requests
- [ ] GitLab CI pipeline for approval workflow
- [ ] Automated provisioning trigger
- [ ] Welcome email automation

---

## References

- [DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md](DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md) - Full governance framework
- [CODER_ONBOARDING.md](CODER_ONBOARDING.md) - Current onboarding guide
- [GitLab API Documentation](https://docs.gitlab.com/ee/api/) - For contribution tracking

---

*Proposal created: January 2026*
*Status: Ready for implementation*
