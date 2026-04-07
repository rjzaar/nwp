# coders

Interactive TUI for managing NWP coders with onboarding status tracking.

## Overview

The `coders` command provides a terminal user interface (TUI) for managing NWP contributors and coders. It displays onboarding status, contribution statistics, and provides bulk operations for promotion, modification, and deletion of coder accounts.

## Usage

```bash
pl coders [command]
```

## Commands

| Command | Description |
|---------|-------------|
| (none) | Launch interactive TUI |
| `list` | List all coders (non-interactive) |
| `sync` | Sync contribution stats from GitLab (non-interactive) |
| `help` | Show help message |

## TUI Controls

| Key | Action |
|-----|--------|
| Up/Down | Navigate coders list |
| Space | Select/deselect for bulk actions |
| Enter | View detailed stats for selected coder |
| M | Modify selected coder (role, status, notes) |
| P | Promote selected/marked coders |
| D | Delete selected/marked coders |
| A | Add new coder |
| S | Sync from GitLab (update contribution stats) |
| C | Check onboarding status (GL, DNS, etc.) |
| V | Verify DNS/infrastructure for selected coder |
| R | Reload data from configuration |
| H | Show help screen |
| O | Open documentation (Coder Onboarding Guide) |
| Q | Quit |

## Status Columns

The TUI displays onboarding progress across multiple steps:

| Column | Description | Check Method |
|--------|-------------|--------------|
| GL | GitLab user exists | GitLab API |
| GRP | GitLab group membership | GitLab API |
| SSH | SSH key registered on GitLab | GitLab API |
| NS | NS delegation configured | DNS query (dig NS) |
| DNS | A record resolves to IP | DNS query (dig A) |
| SRV | Server provisioned | Config or Linode API |
| SITE | Site accessible via HTTPS | HTTP request |

### Status Symbols

- **✓** (green) - Complete/OK
- **✗** (red) - Missing/Failed
- **?** (yellow) - Unknown/Checking
- **-** (dim) - Not required for role

## Role-based Requirements

Different coder roles have different onboarding requirements:

**Newcomer/Contributor:**
- GL + GRP + SSH required
- NS, DNS, SRV, SITE not required

**Core/Steward:**
- All steps required (GL, GRP, SSH, NS, DNS, SRV, SITE)

## Examples

### Launch interactive TUI
```bash
pl coders
```

### List all coders (CLI mode)
```bash
pl coders list
```

### Sync contribution stats from GitLab
```bash
pl coders sync
```

## Coder Roles

The system supports four coder roles with different access levels:

1. **Newcomer** (Level 0) - New contributors
2. **Contributor** (Level 30) - Regular contributors
3. **Core** (Level 40) - Core developers
4. **Steward** (Level 50) - Project stewards

## Features

- **Auto-listing**: Displays all coders on startup
- **Onboarding tracking**: Shows completion status across 7 steps
- **Arrow key navigation**: Full keyboard navigation
- **Bulk actions**: Select multiple coders for promotion/deletion
- **Auto-sync**: Fetches contribution stats from GitLab
- **Detailed stats view**: Shows commits, MRs, reviews with visual bars
- **Promotion workflow**: Track promotion path for each role

## Related Commands

- [coder-setup.sh](coder-setup.md) - Add/remove coders and configure infrastructure
- [upstream.sh](upstream.md) - Manage upstream repository connection
- [contribute.sh](contribute.md) - Submit contributions

## See Also

- [Coder Onboarding Guide](../../guides/coder-onboarding.md) - Complete onboarding instructions
- [Distributed Contribution Governance](../../governance/distributed-contribution-governance.md) - Governance model
- `nwp.yml` - Coder configuration file
