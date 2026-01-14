# NWP Implementation Plan - January 2026

**Based on:** NWP_DEEP_ANALYSIS_REEVALUATION.md
**Created:** 2026-01-14
**Status:** Ready for Implementation
**Total Estimated Effort:** ~25-30 hours

---

## Overview

This plan covers the remaining high-value items from the deep analysis re-evaluation:
- Security improvements (1.2, 1.3)
- Documentation cleanup (4.1, 4.2, 4.5)
- UX improvements (5.1, 5.5 - NO_COLOR and pl doctor only)

**Note:** Item 1.4 (Weak Default Passwords) was already addressed with better error handling.

---

## Phase 1: Security Hardening

### 1.1 Command Injection Review (1.2)
**Status:** Completed in Tier 1, verification recommended
**Effort:** 1 hour (verification only)

**Tasks:**
1. Verify setup-ssh.sh uses stdin for SSH key injection
2. Verify remote.sh properly quotes all variables
3. Run shellcheck on both files
4. Document security patterns in lib/README.md

**Files to Check:**
- `scripts/commands/setup-ssh.sh`
- `lib/remote.sh`

**Acceptance Criteria:**
- [ ] No unquoted variable expansions in command execution
- [ ] shellcheck passes with no SC2086/SC2091 warnings
- [ ] Security patterns documented

---

### 1.2 SSH Host Key Verification (1.3)
**Status:** TODO
**Effort:** 2-3 hours

**Current Behavior:** `StrictHostKeyChecking=accept-new` accepts new keys automatically.

**Implementation:**

**Step 1: Add User Warning** (30 minutes)
Add warning message to coder-setup.sh:
```bash
echo "⚠️  SSH Host Key Verification: Using 'accept-new' mode"
echo "    First connection will accept server fingerprint automatically"
echo "    This is convenient but vulnerable to MITM on first connection"
echo ""
echo "    For strict mode: export NWP_SSH_STRICT=1"
```

**Step 2: Implement Optional Strict Mode** (1.5 hours)
```bash
# In lib/ssh.sh or lib/remote.sh
get_ssh_host_key_checking() {
    if [ "${NWP_SSH_STRICT:-0}" = "1" ]; then
        echo "yes"
    else
        echo "accept-new"
    fi
}
```

**Step 3: Document Security Implications** (30 minutes)
- Add to docs/SECURITY.md (or create if missing)
- Explain threat model
- Document when to use strict mode

**Files to Modify:**
- `scripts/commands/coder-setup.sh`
- `lib/remote.sh` or create `lib/ssh.sh`
- `docs/SECURITY.md`

**Acceptance Criteria:**
- [ ] Warning displayed during first SSH connection setup
- [ ] NWP_SSH_STRICT=1 enables StrictHostKeyChecking=yes
- [ ] Security implications documented

---

## Phase 2: Documentation Quick Wins

### 2.1 Complete Documentation Indexing (4.1)
**Status:** Partial (docs/README.md exists)
**Effort:** 1-2 hours

**Current State:** 26 docs indexed, needs verification and updates.

**Tasks:**
1. Audit all files in docs/ directory
2. Verify every .md file is linked in docs/README.md
3. Update version number (currently shows v0.18.0, should be v0.20.0)
4. Add any missing documents
5. Organize by category (Getting Started, Commands, Architecture, etc.)

**Files to Modify:**
- `docs/README.md`

**Verification Command:**
```bash
# Find unlinked docs
for doc in docs/*.md; do
    basename="${doc##*/}"
    if ! grep -q "$basename" docs/README.md; then
        echo "MISSING: $basename"
    fi
done
```

**Acceptance Criteria:**
- [ ] All docs/*.md files are linked in docs/README.md
- [ ] Version number is current (v0.20.0+)
- [ ] Documents organized by logical category
- [ ] No orphaned documentation files

---

### 2.2 Review [PLANNED] Options (4.2)
**Status:** TODO
**Effort:** 1-2 hours

**Current State:** 77 [PLANNED] placeholder options remain in example.cnwp.yml

**Tasks:**
1. Audit all [PLANNED] markers in example.cnwp.yml
2. For each [PLANNED] option, determine:
   - Is it now implemented? → Remove [PLANNED] marker (option becomes active)
   - Is it partially implemented? → Mark as [EXPERIMENTAL]
   - Is it not started? → Keep [PLANNED] marker as-is
3. Add header comment explaining marker meanings
4. Ensure [PLANNED] options have sensible default values

**Files to Modify:**
- `example.cnwp.yml`

**Guidelines:**
- Keep [PLANNED] markers for future features - they serve as roadmap
- Only remove [PLANNED] when feature is fully functional
- Mark partially working features as [EXPERIMENTAL]
- Add explanatory comment at top of file:
```yaml
# Option markers:
#   [PLANNED] - Feature not yet implemented, placeholder for future
#   [EXPERIMENTAL] - Feature partially implemented, may change
#   (no marker) - Feature fully implemented and stable
```

**Acceptance Criteria:**
- [ ] All implemented features have [PLANNED] marker removed
- [ ] Partially implemented features marked [EXPERIMENTAL]
- [ ] Unimplemented features retain [PLANNED] marker
- [ ] Header comment explains marker meanings

---

### 2.3 Link Governance Document (4.5)
**Status:** TODO
**Effort:** 5-10 minutes

**Task:**
Add DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md to docs/README.md

**Location in docs/README.md:**
Under appropriate section (e.g., "Contributing" or "Governance")

**Entry to Add:**
```markdown
### Governance
- [Distributed Contribution Governance](DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md) - Security review process for contributions
```

**Files to Modify:**
- `docs/README.md`

**Acceptance Criteria:**
- [ ] DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md linked in docs/README.md
- [ ] Link is under an appropriate heading
- [ ] Brief description explains what the doc covers

---

## Phase 3: UX Improvements - NO_COLOR Support

### 3.1 Implement NO_COLOR Standard (5.5)
**Status:** TODO
**Effort:** 1-2 hours

**Background:** The NO_COLOR standard (https://no-color.org/) is widely adopted. When NO_COLOR environment variable is set (any value), CLI tools should disable color output.

**Implementation:**

**Step 1: Update lib/ui.sh** (45 minutes)
```bash
# At top of lib/ui.sh
should_use_color() {
    # NO_COLOR standard - if set (any value), disable color
    if [ -n "${NO_COLOR:-}" ]; then
        return 1
    fi
    # Also disable if not a terminal
    if [ ! -t 1 ]; then
        return 1
    fi
    return 0
}

# Update color variables
if should_use_color; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi
```

**Step 2: Verify All Color Usage** (30 minutes)
- Check all files that define colors
- Ensure they respect the central should_use_color function
- Update any hardcoded color codes

**Step 3: Add Documentation** (15 minutes)
- Document in README.md or pl --help
- Example: `NO_COLOR=1 pl status`

**Files to Modify:**
- `lib/ui.sh`
- Any other files with hardcoded color definitions
- `README.md` (add note about NO_COLOR support)

**Acceptance Criteria:**
- [ ] `NO_COLOR=1 pl status` produces no ANSI escape codes
- [ ] Normal usage still has colors
- [ ] Pipe to file disables colors automatically
- [ ] Documented in help/README

---

## Phase 4: Progress Indicators Enhancement

### 4.1 Standardize Progress Indicators (5.1)
**Status:** Partial (exists in 10 libraries)
**Effort:** 8-10 hours

**Current State:** Progress indicators exist but are inconsistent across commands.

**Implementation Phases:**

**Step 1: Audit Existing Progress Functions** (1 hour)
```bash
# Find existing progress implementations
grep -r "spinner\|progress\|show_step" lib/ scripts/
```

**Step 2: Create Standardized Progress API in lib/ui.sh** (2 hours)

```bash
# lib/ui.sh additions

# Simple spinner for background operations
# Usage: start_spinner "Installing Drupal..."
#        do_something
#        stop_spinner
start_spinner() {
    local msg="${1:-Working...}"
    local pid
    (
        local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local i=0
        while true; do
            printf "\r${BLUE}${spin:i++%${#spin}:1}${NC} %s" "$msg"
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
}

stop_spinner() {
    [ -n "${SPINNER_PID:-}" ] && kill "$SPINNER_PID" 2>/dev/null
    printf "\r\033[K"  # Clear line
    unset SPINNER_PID
}

# Step indicator for multi-step operations
# Usage: show_step 1 5 "Installing dependencies"
show_step() {
    local current=$1
    local total=$2
    local message=$3
    printf "${BLUE}[%d/%d]${NC} %s\n" "$current" "$total" "$message"
}

# Progress bar for known-length operations
# Usage: show_progress 45 100 "Downloading"
show_progress() {
    local current=$1
    local total=$2
    local message="${3:-Progress}"
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))
    printf "\r%s [%s%s] %d%%" "$message" \
        "$(printf '#%.0s' $(seq 1 $filled))" \
        "$(printf ' %.0s' $(seq 1 $empty))" \
        "$percent"
}
```

**Step 3: Identify High-Value Commands** (1 hour)
Commands that benefit most from progress indicators:
1. `pl install` - Long-running, many steps
2. `pl deploy` - Multi-step deployment
3. `pl backup` - Can take time for large sites
4. `pl restore` - Long restore operations
5. `pl update` - Drupal updates
6. `pl server-create` - API calls take time

**Step 4: Implement Progress in Priority Commands** (4-5 hours)
Add progress indicators to each identified command:
- Add `show_step` calls for major phases
- Add `start_spinner` for operations without visible output
- Ensure `stop_spinner` called on errors (trap cleanup)

**Files to Modify:**
- `lib/ui.sh` (core progress functions)
- `scripts/commands/install.sh`
- `scripts/commands/deploy.sh`
- `scripts/commands/backup.sh`
- `scripts/commands/restore.sh`
- `lib/drupal.sh` (install_drupal function)
- `lib/linode.sh` (server creation)

**Acceptance Criteria:**
- [ ] lib/ui.sh has standardized spinner, step, and progress functions
- [ ] Long-running commands show progress
- [ ] Users never see "hanging" commands
- [ ] Spinners cleaned up on error/interrupt (trap)
- [ ] NO_COLOR respected by progress indicators

---

## Phase 5: pl doctor Diagnostic Command

### 5.1 Implement pl doctor Command (5.5)
**Status:** TODO
**Effort:** 8-10 hours

**Purpose:** Diagnose common issues, check prerequisites, verify configuration.

**Implementation:**

**Step 1: Create Command Structure** (1 hour)
```bash
# scripts/commands/doctor.sh

#!/usr/bin/env bash
# NWP Doctor - Diagnostic and troubleshooting command

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/ui.sh"

show_help() {
    cat << 'EOF'
Usage: pl doctor [OPTIONS]

Diagnose common issues and verify NWP configuration.

Options:
    -v, --verbose    Show detailed output for all checks
    -q, --quiet      Only show errors
    -h, --help       Show this help message

Checks performed:
    - System prerequisites (Docker, DDEV, PHP, Composer)
    - Configuration files (cnwp.yml, secrets)
    - Network connectivity (API endpoints)
    - Permission issues
    - Common misconfigurations

EOF
}
```

**Step 2: Implement Prerequisite Checks** (2 hours)
```bash
check_prerequisites() {
    local errors=0

    print_header "Checking Prerequisites"

    # Docker
    if command -v docker &>/dev/null; then
        local docker_version=$(docker --version | grep -oP '\d+\.\d+\.\d+')
        print_success "Docker: $docker_version"
    else
        print_error "Docker: NOT INSTALLED"
        print_hint "Install from: https://docs.docker.com/get-docker/"
        ((errors++))
    fi

    # DDEV
    if command -v ddev &>/dev/null; then
        local ddev_version=$(ddev --version | head -1)
        print_success "DDEV: $ddev_version"
    else
        print_error "DDEV: NOT INSTALLED"
        print_hint "Install from: https://ddev.readthedocs.io/en/stable/"
        ((errors++))
    fi

    # PHP
    if command -v php &>/dev/null; then
        local php_version=$(php -v | head -1 | grep -oP '\d+\.\d+\.\d+')
        print_success "PHP: $php_version"
    else
        print_warning "PHP: NOT INSTALLED (optional for local development)"
    fi

    # Composer
    if command -v composer &>/dev/null; then
        local composer_version=$(composer --version | grep -oP '\d+\.\d+\.\d+')
        print_success "Composer: $composer_version"
    else
        print_warning "Composer: NOT INSTALLED (optional, DDEV has it)"
    fi

    # yq (optional but recommended)
    if command -v yq &>/dev/null; then
        local yq_version=$(yq --version 2>&1 | head -1)
        print_success "yq: $yq_version"
    else
        print_warning "yq: NOT INSTALLED (recommended for faster YAML parsing)"
        print_hint "Install from: https://github.com/mikefarah/yq"
    fi

    # git
    if command -v git &>/dev/null; then
        local git_version=$(git --version | grep -oP '\d+\.\d+\.\d+')
        print_success "Git: $git_version"
    else
        print_error "Git: NOT INSTALLED"
        ((errors++))
    fi

    return $errors
}
```

**Step 3: Implement Configuration Checks** (2 hours)
```bash
check_configuration() {
    local errors=0

    print_header "Checking Configuration"

    # cnwp.yml exists
    if [ -f "$PROJECT_ROOT/cnwp.yml" ]; then
        print_success "cnwp.yml: Found"

        # Validate YAML syntax
        if command -v yq &>/dev/null; then
            if yq eval '.' "$PROJECT_ROOT/cnwp.yml" &>/dev/null; then
                print_success "cnwp.yml: Valid YAML syntax"
            else
                print_error "cnwp.yml: Invalid YAML syntax"
                ((errors++))
            fi
        fi

        # Check for sites defined
        local site_count=$(yaml_get_site_names | wc -l)
        if [ "$site_count" -gt 0 ]; then
            print_success "Sites configured: $site_count"
        else
            print_warning "No sites configured in cnwp.yml"
        fi
    else
        print_error "cnwp.yml: NOT FOUND"
        print_hint "Copy example.cnwp.yml to cnwp.yml and configure"
        ((errors++))
    fi

    # .secrets.yml exists (infrastructure secrets)
    if [ -f "$PROJECT_ROOT/.secrets.yml" ]; then
        print_success ".secrets.yml: Found"
    else
        print_warning ".secrets.yml: NOT FOUND (needed for Linode/Cloudflare)"
    fi

    # Check sites directory
    if [ -d "$PROJECT_ROOT/sites" ]; then
        local installed_sites=$(ls -d "$PROJECT_ROOT/sites"/*/ 2>/dev/null | wc -l)
        print_success "Sites directory: $installed_sites site(s) installed"
    else
        print_warning "Sites directory: NOT FOUND (will be created on first install)"
    fi

    return $errors
}
```

**Step 4: Implement Network Checks** (1.5 hours)
```bash
check_network() {
    local errors=0

    print_header "Checking Network Connectivity"

    # Linode API
    if curl -sf --max-time 5 "https://api.linode.com/v4/regions" -o /dev/null; then
        print_success "Linode API: Reachable"
    else
        print_warning "Linode API: Unreachable (may affect server commands)"
    fi

    # Cloudflare API
    if curl -sf --max-time 5 "https://api.cloudflare.com/client/v4/zones" -o /dev/null 2>&1; then
        print_success "Cloudflare API: Reachable"
    else
        print_warning "Cloudflare API: Unreachable (may affect DNS commands)"
    fi

    # drupal.org
    if curl -sf --max-time 5 "https://www.drupal.org/" -o /dev/null; then
        print_success "drupal.org: Reachable"
    else
        print_warning "drupal.org: Unreachable (may affect Drupal downloads)"
    fi

    return $errors
}
```

**Step 5: Implement Common Issue Detection** (1.5 hours)
```bash
check_common_issues() {
    local errors=0

    print_header "Checking for Common Issues"

    # Docker running
    if docker info &>/dev/null; then
        print_success "Docker daemon: Running"
    else
        print_error "Docker daemon: NOT RUNNING"
        print_hint "Start Docker Desktop or run: sudo systemctl start docker"
        ((errors++))
    fi

    # DDEV running sites
    local running_sites=$(ddev list 2>/dev/null | grep -c "running" || echo 0)
    print_info "DDEV sites running: $running_sites"

    # Disk space
    local disk_free=$(df -h "$PROJECT_ROOT" | tail -1 | awk '{print $4}')
    local disk_percent=$(df -h "$PROJECT_ROOT" | tail -1 | awk '{print $5}' | tr -d '%')
    if [ "$disk_percent" -gt 90 ]; then
        print_warning "Disk space: ${disk_free} free (${disk_percent}% used)"
        print_hint "Consider freeing up disk space"
    else
        print_success "Disk space: ${disk_free} free"
    fi

    # Memory
    local mem_available=$(free -h | grep Mem | awk '{print $7}')
    print_info "Memory available: $mem_available"

    return $errors
}
```

**Step 6: Main Doctor Function** (1 hour)
```bash
main() {
    local verbose=0
    local quiet=0
    local total_errors=0

    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose) verbose=1; shift ;;
            -q|--quiet) quiet=1; shift ;;
            -h|--help) show_help; exit 0 ;;
            *) print_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║          NWP Doctor v0.20.0            ║"
    echo "╚════════════════════════════════════════╝"
    echo ""

    check_prerequisites || total_errors=$((total_errors + $?))
    echo ""
    check_configuration || total_errors=$((total_errors + $?))
    echo ""
    check_network || total_errors=$((total_errors + $?))
    echo ""
    check_common_issues || total_errors=$((total_errors + $?))

    echo ""
    print_header "Summary"

    if [ "$total_errors" -eq 0 ]; then
        print_success "All checks passed! NWP is ready to use."
        exit 0
    else
        print_error "$total_errors issue(s) found"
        print_hint "Fix the issues above and run 'pl doctor' again"
        exit 1
    fi
}

main "$@"
```

**Files to Create:**
- `scripts/commands/doctor.sh`

**Files to Modify:**
- `pl` (add doctor to command list)

**Acceptance Criteria:**
- [ ] `pl doctor` runs all checks
- [ ] Clear pass/fail status for each check
- [ ] Helpful hints for fixing issues
- [ ] Exit code 0 if all pass, 1 if any fail
- [ ] Works with NO_COLOR
- [ ] Documented in `pl --help`

---

## Implementation Schedule

| Phase | Items | Effort | Priority |
|-------|-------|--------|----------|
| **Phase 1** | Security (1.2, 1.3) | 3-4 hours | High |
| **Phase 2** | Documentation (4.1, 4.2, 4.5) | 3-5 hours | High |
| **Phase 3** | NO_COLOR (5.5) | 1-2 hours | Medium |
| **Phase 4** | Progress Indicators (5.1) | 8-10 hours | Medium |
| **Phase 5** | pl doctor (5.5) | 8-10 hours | Medium |
| **TOTAL** | | **23-31 hours** | |

---

## Recommended Order

1. **Phase 2.3** - Link Governance Doc (5 minutes) - Quick win
2. **Phase 3** - NO_COLOR Support (1-2 hours) - Foundation for other UX work
3. **Phase 2.1** - Documentation Indexing (1-2 hours) - Quick win
4. **Phase 2.2** - Clean [PLANNED] Options (2-3 hours) - User-facing improvement
5. **Phase 1** - Security Hardening (3-4 hours) - Important but not urgent
6. **Phase 5** - pl doctor (8-10 hours) - High value diagnostic tool
7. **Phase 4** - Progress Indicators (8-10 hours) - Can be done incrementally

---

## Success Metrics

After completing all phases:

- [ ] [PLANNED] markers reviewed; implemented features unmarked
- [ ] All documentation files linked and organized
- [ ] `NO_COLOR=1 pl <any>` produces no ANSI codes
- [ ] `pl doctor` diagnoses common issues
- [ ] Long-running commands show progress
- [ ] SSH security documented with optional strict mode

---

## Notes

### Items Explicitly Excluded

Per requirements, the following items from 5.5 are NOT included:
- `--json` output - No current use case (YAGNI)
- `--dry-run` flag - Complex to implement correctly, low ROI

### Item 1.4 Status

Weak Default Passwords (1.4) was already addressed with better error handling approach:
```bash
local moodle_admin_pass=$(get_secret "moodle.admin_password" "")
if [ -z "$moodle_admin_pass" ]; then
    print_error "Moodle admin password not configured in .secrets.data.yml"
    return 1
fi
```

---

*Plan created from NWP_DEEP_ANALYSIS_REEVALUATION.md*
*Ready for implementation*
