# NWP Developer Roles

This document defines the contributor roles, responsibilities, and access levels for the NWP project.

## Role Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           NWP CONTRIBUTOR ROLES                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   NEWCOMER              CONTRIBUTOR           CORE DEVELOPER    STEWARD    │
│   (Fork-based)          (Developer)           (Maintainer)      (Owner)    │
│                                                                             │
│   ┌──────────┐          ┌──────────┐          ┌──────────┐     ┌─────────┐ │
│   │ Anyone   │ ──────▶  │  5+ MRs  │ ───────▶ │ 50+ MRs  │ ──▶ │Appointed│ │
│   │          │          │ 1 month  │          │ 6 months │     │ by vote │ │
│   └──────────┘          └──────────┘          └──────────┘     └─────────┘ │
│                                                                             │
│   GitLab: N/A           GitLab: 30            GitLab: 40       GitLab: 50  │
│   (fork only)           (Developer)           (Maintainer)     (Owner)     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Newcomer (Fork-Based Contributor)

**GitLab Access Level:** N/A (uses GitHub/GitLab fork)

### How to Become
- Anyone can contribute via fork
- No formal registration required
- Follow CONTRIBUTING.md guidelines

### Capabilities
| Action | Allowed |
|--------|---------|
| Fork repository | Yes |
| Create pull requests | Yes |
| Comment on issues | Yes |
| View public documentation | Yes |
| Push to nwp/nwp | No |
| Review others' code | No |
| Own subdomain | No |

### Responsibilities
- Follow code of conduct
- Write clear PR descriptions
- Respond to review feedback
- Run tests before submitting

### Path to Contributor
1. Submit 5+ merged pull requests
2. Active for at least 1 month
3. Positive review feedback
4. Request promotion via issue or email

---

## Contributor

**GitLab Access Level:** 30 (Developer)

### How to Become
- Promoted from Newcomer by Core Developer or Steward
- Agrees to code of conduct
- Command: `./coders.sh promote <name> contributor`

### Capabilities
| Action | Allowed |
|--------|---------|
| Push to feature branches | Yes |
| Create merge requests | Yes |
| Be assigned issues | Yes |
| View CI/CD pipelines | Yes |
| Own subdomain (`<name>.nwpcode.org`) | Yes |
| Own Linode server | Yes |
| Merge to main | No |
| Approve others' MRs | No |
| Access protected variables | No |

### Responsibilities
- Create feature branches, not push to main
- Write tests for new code
- Follow coding standards
- Participate in code reviews (as reviewee)
- Keep subdomain infrastructure maintained

### Access Provisioned
- GitLab account on git.nwpcode.org
- Membership in `nwp` group (Developer level)
- NS delegation for `<name>.nwpcode.org`
- Listed in cnwp.yml `other_coders` section

### Path to Core Developer
1. 50+ merged MRs
2. Active for at least 6 months
3. Demonstrated ability to review code
4. Vouched by existing Core Developer
5. No significant revert history

---

## Core Developer

**GitLab Access Level:** 40 (Maintainer)

### How to Become
- Promoted from Contributor by Steward
- Proven track record of quality contributions
- Command: `./coders.sh promote <name> core`

### Capabilities
| Action | Allowed |
|--------|---------|
| All Contributor capabilities | Yes |
| Merge to main branch | Yes |
| Approve merge requests | Yes |
| Manage CI/CD pipelines | Yes |
| Access protected variables | Yes |
| Create releases | Yes |
| Push to GitHub canonical | Yes |
| Triage issues | Yes |
| Propose ADRs | Yes |
| Modify standing orders | Propose only |

### Responsibilities
- Review and merge Contributor PRs
- Maintain code quality standards
- Respond to issues in timely manner
- Mentor Contributors
- Participate in architectural discussions
- Document decisions in ADRs

### Access Provisioned
- GitLab Maintainer access
- GitHub write access to canonical repo
- Access to CI/CD protected variables
- Can approve sensitive path changes (with 2nd reviewer)

### Path to Steward
1. Significant architectural contributions
2. Active as Core Developer for 1+ year
3. Nominated by existing Steward
4. Approved by governance vote

---

## Steward

**GitLab Access Level:** 50 (Owner)

### How to Become
- Appointed by existing Stewards
- Requires governance vote
- Demonstrated leadership and vision

### Capabilities
| Action | Allowed |
|--------|---------|
| All Core Developer capabilities | Yes |
| Full admin access | Yes |
| Modify CLAUDE.md standing orders | Yes |
| Approve new Maintainers | Yes |
| Make architectural decisions | Yes |
| Emergency access to all systems | Yes |
| Delete/transfer repositories | Yes |
| Manage GitLab groups | Yes |

### Responsibilities
- Set project direction and vision
- Make final decisions on contested issues
- Approve promotions to Core Developer
- Maintain governance documentation
- Represent project externally
- Emergency incident response

### Access Provisioned
- GitLab Owner access to all groups
- GitHub Admin access
- Access to all secrets (both tiers)
- Infrastructure admin credentials

---

## Access Matrix

| Resource | Newcomer | Contributor | Core Dev | Steward |
|----------|----------|-------------|----------|---------|
| **GitLab Level** | N/A | 30 | 40 | 50 |
| **Push to main** | No | No | Yes | Yes |
| **Merge MRs** | No | No | Yes | Yes |
| **Create branches** | Fork only | Yes | Yes | Yes |
| **View pipelines** | PR only | Yes | Yes | Yes |
| **Protected vars** | No | No | Yes | Yes |
| **Own subdomain** | No | Yes | Yes | Yes |
| **GitHub access** | Fork | Fork | Write | Admin |
| **Secrets: Infra** | No | Yes | Yes | Yes |
| **Secrets: Data** | No | No | No | Yes |
| **Standing orders** | Read | Read | Propose | Modify |
| **ADR creation** | No | No | Yes | Yes |
| **Promote others** | No | No | Request | Approve |

---

## GitLab Access Levels Reference

| Level | Name | Key Permissions |
|-------|------|-----------------|
| 10 | Guest | View issues, comment |
| 20 | Reporter | View code, create issues, labels |
| 30 | Developer | Push branches, create MRs, run pipelines |
| 40 | Maintainer | Merge to protected, manage pipelines, edit project |
| 50 | Owner | Full admin, delete project, manage members |

---

## Coders Management TUI

Administrators can manage all coders through an interactive TUI:

```bash
./scripts/commands/coders.sh
```

**Features:**
- Auto-lists all coders with contribution stats on startup
- Arrow-key navigation (↑/↓)
- Bulk selection with Space for mass promote/delete
- Auto-sync from GitLab
- Detailed stats view with visual contribution bars

**Controls:**
| Key | Action |
|-----|--------|
| ↑/↓ | Navigate coders |
| Space | Select for bulk actions |
| Enter | View detailed stats |
| M | Modify role/status |
| P | Promote selected |
| D | Delete selected |
| S | Sync from GitLab |
| Q | Quit |

---

## Promotion Process

### Newcomer → Contributor
1. Developer opens issue requesting promotion
2. Core Developer reviews contribution history
3. If approved, Core Developer runs:
   ```bash
   ./scripts/commands/coder-setup.sh add <name> --email "email" --fullname "Name"
   ```
   Or use the TUI: `./scripts/commands/coders.sh` → **A** to add
4. Developer completes onboarding (see CODER_ONBOARDING.md)

### Contributor → Core Developer
1. Contributor opens issue requesting promotion
2. Existing Core Developer vouches for them
3. Steward reviews contribution stats in TUI (Enter for details)
4. If approved, use TUI: select coder → **P** → choose "core"
   Or command line:
   ```bash
   # Via TUI (recommended - also updates GitLab access)
   ./scripts/commands/coders.sh
   # Navigate to coder, press P, select "core"
   ```
5. GitHub access updated manually

### Core Developer → Steward
1. Nomination by existing Steward
2. Discussion period (2 weeks)
3. Vote by all Stewards (requires majority)
4. If approved, use TUI to promote to "steward"

---

## Offboarding

### Voluntary Departure
1. Developer notifies Steward
2. Transfer any owned issues/MRs
3. Use TUI: select coder → **D** → choose archive option
   Or command line:
   ```bash
   ./scripts/commands/coder-setup.sh remove <name> --archive
   ```
4. Contribution history archived automatically
5. Update documentation

### Involuntary Removal
Grounds for removal:
- Code of conduct violations
- Malicious activity
- Extended inactivity (12+ months without response)

Process:
1. Steward documents reasons
2. Notification to developer (if possible)
3. Immediate access revocation if security risk
4. Run: `./coders.sh remove <name> --archive`

---

## Role-Specific Onboarding Checklists

### New Contributor Checklist
- [ ] GitLab account created
- [ ] Added to nwp group (Developer)
- [ ] SSH key registered
- [ ] NS delegation configured
- [ ] Linode account created
- [ ] Server provisioned
- [ ] First site created
- [ ] Read CONTRIBUTING.md
- [ ] Joined communication channels

### New Core Developer Checklist
- [ ] All Contributor items
- [ ] GitLab upgraded to Maintainer
- [ ] GitHub write access granted
- [ ] Protected variable access confirmed
- [ ] Review guidelines read
- [ ] ADR process understood
- [ ] Mentorship assignment (if applicable)

### New Steward Checklist
- [ ] All Core Developer items
- [ ] GitLab Owner access
- [ ] GitHub Admin access
- [ ] Data secrets access
- [ ] Infrastructure credentials
- [ ] Governance documents reviewed
- [ ] Emergency procedures understood

---

## Related Documentation

- [CONTRIBUTING.md](../CONTRIBUTING.md) - How to contribute
- [CODER_ONBOARDING.md](CODER_ONBOARDING.md) - Detailed onboarding steps
- [DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md](DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md) - Full governance framework
- [docs/decisions/](decisions/) - Architecture Decision Records

---

*Last updated: January 2026*
