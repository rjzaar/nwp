# F15: Comprehensive SSH User Management System

**Status:** IMPLEMENTED | **Priority:** MEDIUM | **Effort:** Low (minimal) / High (full) | **Dependencies:** None

> **TL;DR:** Full proposal was over-engineered. Implement practical version (~10 hours) covering all useful phases, skipping only two-tier sudo and audit logging (postponed until external contributors join). See [2. Worth It Evaluation](#2-worth-it-evaluation).

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Worth It Evaluation](#2-worth-it-evaluation)
   - 2.1 [What's Actually Causing Pain?](#21-whats-actually-causing-pain)
   - 2.2 [Applying YAGNI](#22-applying-yagni)
   - 2.3 [The 80/20 Version](#23-the-8020-version)
   - 2.4 [What NOT To Build](#24-what-not-to-build)
   - 2.5 [Revised Recommendation](#25-revised-recommendation)
   - 2.6 [Decision Framework](#26-decision-framework)
   - 2.7 [Conclusion](#27-conclusion)
3. [Research Findings](#3-research-findings)
   - 3.1 [How the gitlab User is Created](#31-how-the-gitlab-user-is-created)
   - 3.2 [Current SSH User Patterns (7 Methods)](#32-current-ssh-user-patterns-7-methods)
   - 3.3 [Security Gaps](#33-security-gaps)
4. [Proposed Solution](#4-proposed-solution)
   - 4.1 [Unified Configuration Schema](#41-unified-configuration-schema)
   - 4.2 [Centralized SSH Helper Functions](#42-centralized-ssh-helper-functions)
   - 4.3 [Auto-Registration After Server Creation](#43-auto-registration-after-server-creation)
   - 4.4 [Recipe SSH User Specification](#44-recipe-ssh-user-specification)
   - 4.5 [Security Hardening](#45-security-hardening)
5. [Implementation Phases](#5-implementation-phases)
   - 5.1 [Phase 1: Foundation](#51-phase-1-foundation)
   - 5.2 [Phase 2: Auto-Registration](#52-phase-2-auto-registration)
   - 5.3 [Phase 3: Migration Tooling](#53-phase-3-migration-tooling)
   - 5.4 [Phase 4: Update Scripts](#54-phase-4-update-scripts)
   - 5.5 [Phase 5: Security Hardening](#55-phase-5-security-hardening)
   - 5.6 [Phase 6: Documentation](#56-phase-6-documentation)
6. [Migration Strategy](#6-migration-strategy)
   - 6.1 [Detection & Fallback](#61-detection--fallback)
   - 6.2 [Backward Compatibility](#62-backward-compatibility)
   - 6.3 [Timeline](#63-timeline)
7. [Critical Files](#7-critical-files)
   - 7.1 [New Files](#71-new-files)
   - 7.2 [Modified Files](#72-modified-files-priority-order)
   - 7.3 [StackScripts Security Updates](#73-stackscripts-security-updates)
8. [Verification](#8-verification)
   - 8.1 [Unit Tests](#81-unit-tests)
   - 8.2 [Integration Tests](#82-integration-tests)
   - 8.3 [Manual Testing](#83-manual-testing)
9. [Success Criteria](#9-success-criteria)
   - 9.1 [Functional](#91-functional)
   - 9.2 [Security](#92-security)
   - 9.3 [Quality](#93-quality)
   - 9.4 [Performance](#94-performance)
10. [Emergency Recovery Procedures](#10-emergency-recovery-procedures)
    - 10.1 [When SSH Access Fails](#101-when-ssh-access-fails)
    - 10.2 [When Sudo Restrictions Break Something](#102-when-sudo-restrictions-break-something)
    - 10.3 [When GitLab/Podcast Breaks](#103-when-gitlabpodcast-breaks)
11. [Risks & Mitigations](#11-risks--mitigations)

---

## 1. Problem Statement

NWP currently has **7 different approaches** to SSH user determination scattered across commands (see [3.2](#32-current-ssh-user-patterns-7-methods)), leading to:

| # | Issue | Details |
|---|-------|---------|
| 1.1 | Hardcoded user assumptions | `remote.sh` always uses `root` |
| 1.2 | Inconsistent behavior | Different commands use different patterns |
| 1.3 | No centralized abstraction | SSH connection logic duplicated everywhere |
| 1.4 | Manual server tracking | No auto-registration of server metadata |
| 1.5 | Security gaps | Overly permissive sudo, no audit trail (see [3.3](#33-security-gaps)) |

---

## 2. Worth It Evaluation

Applying the Deep Analysis Re-Evaluation framework (YAGNI, 80/20, real vs hypothetical):

### 2.1 What's Actually Causing Pain?

| # | Issue | Real Pain? | Frequency | Impact | Ref |
|---|-------|------------|-----------|--------|-----|
| 2.1.1 | 7 different SSH patterns | Yes, but... | Rarely causes failures | Low - code works | [3.2](#32-current-ssh-user-patterns-7-methods) |
| 2.1.2 | Hardcoded `root` in remote.sh | Maybe | When using non-root servers | Medium | [3.2.6](#32-current-ssh-user-patterns-7-methods) |
| 2.1.3 | Hardcoded gitlab/root in live2stg.sh | Yes | Every shared→dedicated scenario | Medium | [3.2.3](#32-current-ssh-user-patterns-7-methods) |
| 2.1.4 | No audit trail | No | Zero security incidents | None | [3.3](#33-security-gaps) |
| 2.1.5 | NOPASSWD:ALL sudo | No | No external contributors | None | [3.3](#33-security-gaps) |
| 2.1.6 | Manual server tracking | Minor | Few servers to track | Low | [1.4](#1-problem-statement) |

**Honest Assessment:** The 7 patterns exist, but they mostly work. The *actual* pain points are:
1. `live2stg.sh` hardcoded logic occasionally breaks (2.1.3)
2. New server types require manual config hunting (2.1.6)
3. Cognitive overhead when debugging SSH issues (2.1.1)

### 2.2 Applying YAGNI

| # | Proposed Feature | YAGNI Verdict | Reasoning | Ref |
|---|------------------|---------------|-----------|-----|
| 2.2.1 | `get_ssh_user()` helper | **DO IT** | Solves real duplication, 2-4 hours | [4.2](#42-centralized-ssh-helper-functions) |
| 2.2.2 | `ssh_exec()` wrapper | **DO IT** | Small incremental effort once get_ssh_user exists | [4.2](#42-centralized-ssh-helper-functions) |
| 2.2.3 | Auto-registration | **DO IT** | Few lines at each integration point, data already available | [4.3](#43-auto-registration-after-server-creation) |
| 2.2.4 | Migration tooling | **DO IT** | Simple audit script, run once, ~1 hour | [5.3](#53-phase-3-migration-tooling) |
| 2.2.5 | Two-tier sudo model | **POSTPONED** | Implement when external contributors join | [4.5](#45-security-hardening) |
| 2.2.6 | Audit logging | **POSTPONED** | Implement when external contributors join | [4.5](#45-security-hardening) |
| 2.2.7 | Fail2ban | **DO IT** | ~20 lines in StackScripts, also covered by P56 | [4.5](#45-security-hardening) |
| 2.2.8 | Per-developer keys | **DO IT** | Essential for onboarding — see coder-setup.sh `--ssh-key` enhancement | [4.5](#45-security-hardening) |
| 2.2.9 | Key rotation policy | **ANNUAL** | Yearly review of active keys, not automated rotation | [4.5](#45-security-hardening) |

### 2.3 The Practical Version (~10 hours)

**Everything useful, nothing over-engineered:**

| # | Task | Effort | Details | Ref |
|---|------|--------|---------|-----|
| 2.3.1 | Create `get_ssh_user()` + `ssh_exec()` | 3 hours | Resolution chain: config → parse user@host → recipe → root. Add to `lib/ssh.sh` | [4.2](#42-centralized-ssh-helper-functions) |
| 2.3.2 | Add `ssh_user` to recipe definitions | 15 min | Add field to recipes in `example.nwp.yml` | [4.4](#44-recipe-ssh-user-specification) |
| 2.3.3 | Update ALL scripts using SSH | 2 hours | Replace all hardcoded patterns with `get_ssh_user()` | [5.4](#54-phase-4-update-scripts) |
| 2.3.4 | Auto-register servers after creation | 2 hours | Hook into `create_linode_instance()` and podcast creation | [5.2](#52-phase-2-auto-registration) |
| 2.3.5 | Migration audit command | 1 hour | `pl migrate-ssh-config audit` to show current state | [5.3](#53-phase-3-migration-tooling) |
| 2.3.6 | SSH key onboarding via coder-setup | 1 hour | Add `--ssh-key` flag to `coder-setup.sh add`, calls `gitlab_add_user_ssh_key()` | New |
| 2.3.7 | Documentation + emergency recovery | 1 hour | SSH management guide, config schema, extract emergency procedures | [5.6](#56-phase-6-documentation) |

**Total: ~10 hours** — everything useful from the original 80-hour proposal

### 2.4 What To Postpone

| # | Component | Effort | When To Implement | Ref |
|---|-----------|--------|-------------------|-----|
| 2.4.1 | Two-tier sudo model | 8+ hours | When external contributors start submitting code | [4.5](#45-security-hardening) |
| 2.4.2 | Audit logging (auditd) | 4+ hours | When external contributors start submitting code | [4.5](#45-security-hardening) |
| 2.4.3 | Automated key rotation | 8+ hours | Not needed — annual manual review sufficient at current scale | [4.5.6](#45-security-hardening) |

### 2.5 Revised Recommendation

| # | Component | Original Effort | Revised | Action | Ref |
|---|-----------|-----------------|---------|--------|-----|
| 2.5.1 | Phase 1: Foundation | 2 weeks | **3 hours** | `get_ssh_user()` + `ssh_exec()` + recipe fields | [5.1](#51-phase-1-foundation) |
| 2.5.2 | Phase 2: Auto-Registration | 1 week | **2 hours** | Hook into server creation, few lines each | [5.2](#52-phase-2-auto-registration) |
| 2.5.3 | Phase 3: Migration Tooling | 1 week | **1 hour** | Simple audit command, run once | [5.3](#53-phase-3-migration-tooling) |
| 2.5.4 | Phase 4: Update Scripts | 2 weeks | **2 hours** | Update all scripts, not just 2 | [5.4](#54-phase-4-update-scripts) |
| 2.5.5 | Phase 5: Security Hardening | 1 week | **1 hour** | Fail2ban in StackScripts only (P56 handles rest). Per-developer keys via coder-setup `--ssh-key`. Annual key review. Two-tier sudo and auditd **postponed**. | [5.5](#55-phase-5-security-hardening) |
| 2.5.6 | Phase 6: Documentation | 1 week | **1 hour** | SSH management guide + emergency recovery + config schema | [5.6](#56-phase-6-documentation) |
| | **TOTAL** | **8 weeks** | **~10 hours** | | |

### 2.6 Decision Framework

**Implement the minimal version (6 hours) IF:**
| # | Criterion | Met? |
|---|-----------|------|
| 2.6.1 | SSH user confusion has caused actual debugging time | [x] Yes |
| 2.6.2 | The fix is simple and low-risk | [x] Yes |
| 2.6.3 | No over-engineering creep | [x] Yes |

**Implement the full version (8 weeks) ONLY IF:**
| # | Criterion | Met? | Ref |
|---|-----------|------|-----|
| 2.6.4 | Adding external contributors who need restricted access | [ ] No | [4.5](#45-security-hardening) |
| 2.6.5 | Compliance requirements mandate audit logging | [ ] No | [4.5](#45-security-hardening) |
| 2.6.6 | Managing 20+ servers where automation pays off | [ ] No | [4.3](#43-auto-registration-after-server-creation) |
| 2.6.7 | Security incident demonstrates need for hardening | [ ] No | [4.5](#45-security-hardening) |

### 2.7 Conclusion

**The practical version (~10 hours) covers everything useful.**

All phases are now included at reduced scope: foundation, auto-registration, migration audit, full script updates, per-developer key onboarding, fail2ban, documentation. Only two-tier sudo and audit logging are postponed (implement when external contributors join).

**Recommended path:**
| # | Action | Ref |
|---|--------|-----|
| 2.7.1 | Implement practical version (10 hours): all phases at reduced scope | [2.3](#23-the-practical-version-10-hours) |
| 2.7.2 | Add `--ssh-key` to `coder-setup.sh add` for onboarding | [2.3.6](#23-the-practical-version-10-hours) |
| 2.7.3 | Annual SSH key review (check active keys, revoke departed devs) | [2.2.9](#22-applying-yagni) |
| 2.7.4 | Postpone two-tier sudo + auditd until external contributors join | [2.4](#24-what-to-postpone) |

**Time saved vs full proposal: ~70 hours**

---

## 3. Research Findings

### 3.1 How the gitlab User is Created

**Location:** `linode/gitlab/gitlab_server_setup.sh` (lines 105-132)

The gitlab user is created by the GitLab StackScript during first boot:

```bash
# Create user with consistent settings
useradd -m -s /bin/bash -G sudo gitlab
mkdir -p /home/gitlab/.ssh
echo "$SSH_PUBKEY" > /home/gitlab/.ssh/authorized_keys
chmod 600 /home/gitlab/.ssh/authorized_keys
chown -R gitlab:gitlab /home/gitlab/.ssh

# Passwordless sudo
echo "gitlab ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/gitlab

# Add to docker group (after Docker installation)
usermod -aG docker gitlab
```

**Key Details:**
| # | Property | Value |
|---|----------|-------|
| 3.1.1 | Username | `gitlab` (default, configurable via UDF parameter `ssh_user`) |
| 3.1.2 | Home | `/home/gitlab` |
| 3.1.3 | Shell | `/bin/bash` |
| 3.1.4 | Groups | `sudo`, `docker` |
| 3.1.5 | SSH | Key from UDF parameter `$SSH_PUBKEY` |
| 3.1.6 | Sudo | Passwordless via `/etc/sudoers.d/gitlab` |

**Other Recipes:**
| # | Recipe | Default User |
|---|--------|--------------|
| 3.1.7 | NWP (LEMP) | `nwp` (or custom via UDF) |
| 3.1.8 | Podcast | `podcast` (via UDF) |

All use identical user creation logic.

### 3.2 Current SSH User Patterns (7 Methods)

| # | Pattern | Location | Example |
|---|---------|----------|---------|
| 3.2.1 | Parse from combined field | `linode.servers.ssh_host: user@ip` | `gitlab@97.107.137.88` |
| 3.2.2 | Separate fields (legacy) | `linode.servers.ssh_user` + `.ssh_host` | `ssh_user: gitlab`, `ssh_host: 97.107.137.88` |
| 3.2.3 | Hardcoded by type | `live2stg.sh:139-140` | `shared→gitlab`, `dedicated→root` |
| 3.2.4 | Dynamic fallback | Various | Try gitlab, then root on failure |
| 3.2.5 | Parse from file | `deployment-info.txt` | Podcast only |
| 3.2.6 | Hardcoded root | `remote.sh:99` | Always `root` |
| 3.2.7 | Manual override | CLI flag | `--ssh=user@host` |

### 3.3 Security Gaps

| # | Gap | Risk Level | Notes |
|---|-----|------------|-------|
| 3.3.1 | Overly permissive sudo | Low* | `NOPASSWD:ALL` grants root-equivalent access |
| 3.3.2 | Docker group = root | Low* | Users in docker group have effective root access |
| 3.3.3 | No audit trail | Low* | No logging of which user performed which action |
| 3.3.4 | Single shared key | Low* | No per-developer keys for accountability |
| 3.3.5 | No key rotation | Low* | Keys never expire |

*Low risk because: 1-2 trusted developers, no external contributors (see [2.2.5-2.2.9](#22-applying-yagni))

---

## 4. Proposed Solution

> **Note:** Sections 4.3-4.5 are marked **DON'T** in [2.2](#22-applying-yagni). Included for reference if scaling triggers [2.6.4-2.6.7](#26-decision-framework).

### 4.1 Unified Configuration Schema

**Standardized server config:**
```yaml
linode:
  servers:
    nwpcode:
      ssh_host: 97.107.137.88         # Just IP (no user@)
      ssh_user: gitlab                # Explicit user field
      ssh_key: ~/.ssh/nwp
      ssh_port: 22
      label: "NWPCode GitLab"
      linode_id: 89322390             # Links to Linode instance
      domain: nwpcode.org             # Primary domain
      recipe: gitlab                  # Recipe used to provision
      created: 2026-01-23T10:00:00Z   # Creation timestamp
```

**Site live config enhancement:**
```yaml
sites:
  mysite:
    live:
      enabled: true
      domain: mysite.nwpcode.org
      server_ip: 97.107.137.88
      server_ref: nwpcode            # Reference to linode.servers entry
      ssh_user: gitlab               # Explicit user
      ssh_key: ~/.ssh/nwp
      path: /var/www/mysite
```

**Backward compatibility:**
| # | Format | Support |
|---|--------|---------|
| 4.1.1 | Legacy `user@host` combined format | Parse user from it |
| 4.1.2 | Separate `ssh_user`/`ssh_host` fields | Supported indefinitely |
| 4.1.3 | No explicit user | Default to `root` |

### 4.2 Centralized SSH Helper Functions

**Create `lib/ssh.sh` enhancements:**

```bash
# Get SSH user for any server or site
# Resolution order (see 6.1):
#   1. sites.*.live.ssh_user
#   2. linode.servers[server_ref].ssh_user
#   3. linode.servers.*.ssh_user
#   4. Parse from ssh_host if user@host format
#   5. Default to root
get_ssh_user(server_or_site, config_file)

# Get complete connection string
get_ssh_connection(server_or_site, config_file)  # Returns user@ip

# Get SSH key path
get_ssh_key(server_or_site, config_file)

# Execute SSH command with auto-retry fallback
ssh_exec(server_or_site, command, [--no-fallback])

# Test SSH connection
ssh_test_connection(user@host, key_path)
```

**Usage example:**
```bash
# Old way (scattered, hardcoded) - see 3.2.3, 3.2.6
ssh root@$server_ip "systemctl restart nginx"

# New way (centralized, configured)
ssh_exec "$server_name" "systemctl restart nginx"
```

### 4.3 Auto-Registration After Server Creation

> **YAGNI Verdict:** DON'T (see [2.2.3](#22-applying-yagni))

**Add to `lib/yaml-write.sh`:**

```bash
yaml_register_server(server_name, server_ip, ssh_user, linode_id, recipe, [domain])
```

**Integration points:**
| # | Location | Trigger |
|---|----------|---------|
| 4.3.1 | `lib/linode.sh` | After `create_linode_instance()` |
| 4.3.2 | `scripts/commands/podcast.sh` | After podcast server creation |
| 4.3.3 | `scripts/commands/live.sh` | When deploying to dedicated servers |

**Result:** Servers automatically added to nwp.yml with complete metadata.

### 4.4 Recipe SSH User Specification

**Add to recipe definitions:**
```yaml
recipes:
  nwp:
    source: nwp/avc-project
    ssh_user: nwp                    # Default user for this recipe

  gitlab:
    type: gitlab
    ssh_user: gitlab                 # GitLab requires 'gitlab' user

  pod:
    type: podcast
    ssh_user: podcast
```

**Flow:** Recipe → StackScript UDF → User creation → Auto-registration (4.3)

### 4.5 Security Hardening

> **YAGNI Verdict:** DON'T (see [2.2.5-2.2.9](#22-applying-yagni), [2.4.1](#24-what-not-to-build))

**Two-tier user model with emergency access:**

```bash
# Deployment user - command-specific NOPASSWD for automation
deploy ALL=(ALL) NOPASSWD: \
    /usr/bin/systemctl restart nginx, \
    /usr/bin/systemctl reload nginx, \
    /usr/bin/systemctl restart php8.2-fpm, \
    /usr/bin/chown -R www-data\:www-data /var/www/*, \
    /usr/bin/certbot renew, \
    /usr/bin/nginx -t

# Admin user - password-required sudo for emergency access
admin ALL=(ALL:ALL) ALL

# GitLab/Podcast users - keep NOPASSWD:ALL for package management
# (Can't predict all commands needed by gitlab-ctl, docker-compose, etc.)
gitlab ALL=(ALL) NOPASSWD:ALL
podcast ALL=(ALL) NOPASSWD:ALL
```

**Emergency Access Strategy:**
| # | Method | Access | Use Case |
|---|--------|--------|----------|
| 4.5.1 | Linode LISH Console | Root via console | SSH completely broken |
| 4.5.2 | Admin User | SSH + password sudo | Manual server work |
| 4.5.3 | Root Password | Via LISH | Emergency recovery |

See [10. Emergency Recovery Procedures](#10-emergency-recovery-procedures) for details.

**Audit logging:**
```bash
# Install auditd in StackScripts
apt-get install -y auditd audispd-plugins

# Log all sudo commands
cat > /etc/audit/rules.d/nwp.rules << 'EOF'
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -k sudo_commands
-w /etc/sudoers -p wa -k sudoers_changes
EOF
```

**Additional hardening:**
| # | Feature | Purpose |
|---|---------|---------|
| 4.5.4 | Fail2ban | SSH brute force protection |
| 4.5.5 | Per-developer SSH keys | Accountability |
| 4.5.6 | SSH key rotation policy | 90 days developers, 60 days CI/CD |
| 4.5.7 | Rootless Docker | Mitigate docker group risk |

---

## 5. Implementation Phases

> **Note:** Per [2.5](#25-revised-recommendation), only 5.1 (partial) and 5.4 (partial) recommended.

### 5.1 Phase 1: Foundation

> **Revised:** 4 hours instead of 2 weeks (see [2.5.1](#25-revised-recommendation))

**Goal:** Add new functions without breaking anything

| # | Task | Include in Minimal? |
|---|------|---------------------|
| 5.1.1 | Create `get_ssh_user()` in `lib/ssh.sh` | **YES** |
| 5.1.2 | Add `yaml_register_server()` to `lib/yaml-write.sh` | No (see 2.2.3) |
| 5.1.3 | Add `ssh_user` to recipe definitions in `example.nwp.yml` | **YES** |
| 5.1.4 | Document new config schema | **YES** |
| 5.1.5 | Write unit tests | **YES** (basic) |

### 5.2 Phase 2: Auto-Registration

> **YAGNI Verdict:** Skip entirely (see [2.2.3](#22-applying-yagni), [2.5.2](#25-revised-recommendation))

**Goal:** Servers auto-register with metadata

| # | Task |
|---|------|
| 5.2.1 | Add server registration to `lib/linode.sh:create_linode_instance()` |
| 5.2.2 | Add registration to `scripts/commands/podcast.sh` |
| 5.2.3 | Update `yaml_add_site_live()` to include `ssh_user` and `server_ref` |
| 5.2.4 | Test server creation and registration |

### 5.3 Phase 3: Migration Tooling

> **YAGNI Verdict:** Skip entirely (see [2.2.4](#22-applying-yagni), [2.5.3](#25-revised-recommendation))

**Goal:** Provide migration path for existing configs

| # | Task | Deliverable |
|---|------|-------------|
| 5.3.1 | Create `scripts/commands/migrate-ssh-config.sh` | `pl migrate-ssh-config audit` |
| 5.3.2 | Create `scripts/commands/server-audit.sh` | `pl server-audit` |
| 5.3.3 | Test migration on example configs | `pl migrate-ssh-config --apply` |

### 5.4 Phase 4: Update Scripts

> **Revised:** 1 hour instead of 2 weeks - fix 2 scripts only (see [2.5.4](#25-revised-recommendation))

**Goal:** Migrate commands to use new helpers

**Full version priority order:**
| # | File | Changes | Minimal? |
|---|------|---------|----------|
| 5.4.1 | `scripts/commands/live2stg.sh` | Replace lines 139-140 with `get_ssh_user()` | **YES** |
| 5.4.2 | `scripts/commands/stg2live.sh` | Use new helpers | No |
| 5.4.3 | `lib/remote.sh` | Replace hardcoded root (line 99) with `get_ssh_user()` | **YES** |
| 5.4.4 | `scripts/commands/import.sh` | Update SSH connection logic | No |
| 5.4.5 | `scripts/commands/podcast.sh` | Already partially updated | No |
| 5.4.6 | All remaining scripts | Use new helpers | No |

**Per-script changes:**
```bash
# Before (3.2.3)
SSH_USER="gitlab"
[ "$server_type" == "dedicated" ] && SSH_USER="root"

# After
SSH_USER=$(get_ssh_user "$sitename")
```

### 5.5 Phase 5: Security Hardening

> **YAGNI Verdict:** Skip entirely (see [2.4.1](#24-what-not-to-build), [2.5.5](#25-revised-recommendation))

**Goal:** Implement security best practices

| # | Task | Ref |
|---|------|-----|
| 5.5.1 | Update StackScripts with two-tier user model | [4.5](#45-security-hardening) |
| 5.5.2 | Add auditd to all StackScripts | [4.5](#45-security-hardening) |
| 5.5.3 | Add Fail2ban to StackScripts | [4.5.4](#45-security-hardening) |
| 5.5.4 | Document emergency access procedures | [10](#10-emergency-recovery-procedures) |
| 5.5.5 | Document SSH key rotation policy | [4.5.6](#45-security-hardening) |
| 5.5.6 | Create per-developer key management guide | [4.5.5](#45-security-hardening) |

### 5.6 Phase 6: Documentation

> **Revised:** 1 hour instead of 1 week (see [2.5.6](#25-revised-recommendation))

**Goal:** Complete user-facing documentation

| # | Task | Minimal? |
|---|------|----------|
| 5.6.1 | Write `docs/guides/ssh-management.md` | Brief section only |
| 5.6.2 | Write `docs/guides/ssh-config-migration.md` | No |
| 5.6.3 | Write `docs/security/ssh-best-practices.md` | No |
| 5.6.4 | Update `docs/reference/configuration/nwp-yml-schema.md` | **YES** |
| 5.6.5 | Update all deployment guides | No |

---

## 6. Migration Strategy

### 6.1 Detection & Fallback

New functions support multiple formats automatically:

| # | Step | Format | Ref |
|---|------|--------|-----|
| 6.1.1 | Check `ssh_user` field | New standard | [4.1](#41-unified-configuration-schema) |
| 6.1.2 | Parse from `ssh_host: user@ip` | Combined format | [3.2.1](#32-current-ssh-user-patterns-7-methods) |
| 6.1.3 | Check `server_ref` | Lookup from referenced server | [4.1](#41-unified-configuration-schema) |
| 6.1.4 | Type-based detection | gitlab, podcast, etc. | [3.1.7-3.1.8](#31-how-the-gitlab-user-is-created) |
| 6.1.5 | Probe server | Optional, `SSH_PROBE_USERS=1` | - |
| 6.1.6 | Default to `root` | Fallback | [4.1.3](#41-unified-configuration-schema) |

### 6.2 Backward Compatibility

| # | Format | Support Level |
|---|--------|---------------|
| 6.2.1 | Legacy `ssh_user` + `ssh_host` fields | Supported indefinitely |
| 6.2.2 | Combined `user@host` format | Parsed automatically |
| 6.2.3 | No explicit user | Defaults to `root` with warning |
| 6.2.4 | Hardcoded assumptions in old scripts | Still work, updated gradually |

### 6.3 Timeline

| # | Period | Status |
|---|--------|--------|
| 6.3.1 | Now - Month 2 | Both formats work, new format recommended |
| 6.3.2 | Month 2-3 | Deprecation warnings for legacy format |
| 6.3.3 | Month 3+ | Optional removal of legacy support (major version bump) |

**Zero downtime guarantee:**
- All changes additive in Phase 1-3 ([5.1-5.3](#5-implementation-phases))
- Migration is opt-in
- Fallback chain (6.1) ensures connections always work
- Auto-migration with backup before v1.0

---

## 7. Critical Files

### 7.1 New Files

None - all enhancements go into existing files

### 7.2 Modified Files (Priority Order)

| # | Priority | File | Changes | Complexity | Minimal? |
|---|----------|------|---------|------------|----------|
| 7.2.1 | 1 | `lib/ssh.sh` | Add `get_ssh_user()`, `get_ssh_connection()`, `ssh_exec()`, `get_ssh_key()` | Medium | **YES** (get_ssh_user only) |
| 7.2.2 | 2 | `lib/yaml-write.sh` | Add `yaml_register_server()` around line 1020 | Low | No |
| 7.2.3 | 3 | `example.nwp.yml` | Add `ssh_user` to recipes (lines 639-1096) and servers (lines 523-580) | Low | **YES** |
| 7.2.4 | 4 | `scripts/commands/live2stg.sh` | Replace lines 139-140 with `get_ssh_user()` | Low | **YES** |
| 7.2.5 | 5 | `lib/remote.sh` | Update `remote_exec()` to use new helpers | Low | **YES** |
| 7.2.6 | 6 | `lib/linode.sh` | Add auto-registration after instance creation (around line 100) | Low | No |
| 7.2.7 | 7 | `scripts/commands/podcast.sh` | Add server registration | Low | No |
| 7.2.8 | 8 | `scripts/commands/import.sh` | Use new SSH helpers | Medium | No |
| 7.2.9 | 9 | `linode/linode_server_setup.sh` | Update sudo config (lines 79-109) | Medium | No |
| 7.2.10 | 10 | `linode/gitlab/gitlab_server_setup.sh` | Update sudo config (lines 102-132) | Medium | No |

### 7.3 StackScripts Security Updates

> **YAGNI Verdict:** Skip (see [2.4.1](#24-what-not-to-build))

**Files:** All StackScripts in `linode/`

| # | Change | Ref |
|---|--------|-----|
| 7.3.1 | Replace `NOPASSWD:ALL` with command-specific sudo | [4.5](#45-security-hardening) |
| 7.3.2 | Add auditd installation and configuration | [4.5](#45-security-hardening) |
| 7.3.3 | Add Fail2ban for SSH protection | [4.5.4](#45-security-hardening) |
| 7.3.4 | Add automatic security updates | - |

---

## 8. Verification

### 8.1 Unit Tests

```bash
# Test SSH user resolution (for 4.2)
test_get_ssh_user_from_server_config      # 6.1.1
test_get_ssh_user_from_site_config        # 6.1.1
test_get_ssh_user_from_server_ref         # 6.1.3
test_get_ssh_user_legacy_format           # 6.1.2
test_get_ssh_user_defaults_to_root        # 6.1.6

# Test connection strings
test_get_ssh_connection
test_get_ssh_key

# Test backward compatibility (for 6.2)
test_legacy_ssh_user_plus_ssh_host        # 6.2.1
test_combined_user_at_host                # 6.2.2
test_missing_user_defaults_root           # 6.2.3
```

### 8.2 Integration Tests

```bash
# Test actual SSH connections
test_ssh_exec_with_new_config
test_ssh_exec_with_legacy_config
test_import_command_with_new_config
test_stg2prod_with_new_config

# Test auto-registration (skip per 2.2.3)
test_server_provision_and_register
test_podcast_install_registers_server
```

### 8.3 Manual Testing

| # | Test | Command | Expected |
|---|------|---------|----------|
| 8.3.1 | Server status | `./pl status servers` | Shows all Linode instances |
| 8.3.2 | Podcast server selection | `./pl install pod test` | Offers existing nwpcode server with gitlab user |
| 8.3.3 | Import with new config | `./pl import --server=nwpcode test-import` | Connects as gitlab user |
| 8.3.4 | Migration audit | `./pl migrate-ssh-config audit` | Shows current config format status |
| 8.3.5 | Server audit | `./pl server-audit` | Shows SSH user for each server |

---

## 9. Success Criteria

### 9.1 Functional

| # | Criterion | Minimal? | Ref |
|---|-----------|----------|-----|
| 9.1.1 | Single function to get SSH user for any server/site | **YES** | [4.2](#42-centralized-ssh-helper-functions) |
| 9.1.2 | SSH connections work consistently across all scripts | No | [5.4](#54-phase-4-update-scripts) |
| 9.1.3 | Auto-registration captures complete server metadata | No | [4.3](#43-auto-registration-after-server-creation) |
| 9.1.4 | Backward compatibility with existing configs | **YES** | [6.2](#62-backward-compatibility) |
| 9.1.5 | Migration path from old to new format | No | [5.3](#53-phase-3-migration-tooling) |

### 9.2 Security

> **YAGNI Verdict:** Skip all (see [2.4.1](#24-what-not-to-build))

| # | Criterion | Ref |
|---|-----------|-----|
| 9.2.1 | Command-specific sudo (no more NOPASSWD:ALL for deploy users) | [4.5](#45-security-hardening) |
| 9.2.2 | Audit logging for all sudo commands | [4.5](#45-security-hardening) |
| 9.2.3 | SSH key rotation policy documented | [4.5.6](#45-security-hardening) |
| 9.2.4 | Fail2ban protection on all servers | [4.5.4](#45-security-hardening) |

### 9.3 Quality

| # | Criterion | Minimal? |
|---|-----------|----------|
| 9.3.1 | 95%+ test coverage for SSH helper functions | No (basic tests only) |
| 9.3.2 | Zero hardcoded SSH user assumptions in new code | **YES** |
| 9.3.3 | All existing scripts updated to use helpers | No (2 scripts only) |
| 9.3.4 | Complete documentation | No (brief only) |

### 9.4 Performance

| # | Criterion | Minimal? |
|---|-----------|----------|
| 9.4.1 | SSH user lookup < 100ms | **YES** |
| 9.4.2 | No degradation in SSH connection speed | **YES** |
| 9.4.3 | Auto-registration adds < 1s to server creation | No (skipped) |

---

## 10. Emergency Recovery Procedures

> **Note:** Included for reference even though security hardening (4.5) is marked DON'T.

### 10.1 When SSH Access Fails

**Option 1: Linode LISH Console (Recommended)** - Ref: [4.5.1](#45-security-hardening)
```bash
# From local machine
ssh lish-us-east.linode.com

# At lish prompt, select your Linode
# Login with root password (set during provisioning)

# Fix issue as root
systemctl restart sshd
# or
vi /etc/ssh/sshd_config
# or
adduser newadmin
```

**Option 2: Linode Rescue Mode**
| # | Step |
|---|------|
| 10.1.1 | Linode Cloud Manager → Select instance → "Rescue" tab |
| 10.1.2 | Boot into Rescue Mode |
| 10.1.3 | Mount disk: `mount /dev/sda /mnt` |
| 10.1.4 | Chroot: `chroot /mnt` |
| 10.1.5 | Fix configuration |
| 10.1.6 | Reboot to normal mode |

**Option 3: Admin User (If SSH Works)** - Ref: [4.5.2](#45-security-hardening)
```bash
# SSH as admin user with password sudo
ssh -i ~/.ssh/admin admin@server

# Enter password when prompted for sudo
sudo vi /etc/sudoers.d/deploy
sudo systemctl restart sshd
```

### 10.2 When Sudo Restrictions Break Something

**Scenario:** Deploy automation fails because command not whitelisted

**Immediate Fix (via LISH or admin user):**
```bash
# Add missing command to deploy user sudoers
sudo vi /etc/sudoers.d/deploy
# Add: /path/to/missing/command

# Or temporarily grant broader access
sudo visudo /etc/sudoers.d/deploy-temp
# deploy ALL=(ALL) NOPASSWD:ALL
```

**Long-term Fix:**
| # | Step |
|---|------|
| 10.2.1 | Identify missing command from audit logs |
| 10.2.2 | Update StackScript sudoers template |
| 10.2.3 | Add to deploy user whitelist |
| 10.2.4 | Deploy fix to all servers via `pl server-update-sudo` |

### 10.3 When GitLab/Podcast Breaks

**Keep NOPASSWD:ALL for these users:**
- GitLab package management (`gitlab-ctl reconfigure`, etc.) requires unpredictable commands
- Docker Compose (podcast) needs various Docker commands
- Automation is core to these services, not optional

**If issue occurs:**
| # | Recovery Option | Ref |
|---|-----------------|-----|
| 10.3.1 | LISH console as root | [10.1](#101-when-ssh-access-fails) |
| 10.3.2 | Admin user with full sudo | [4.5.2](#45-security-hardening) |
| 10.3.3 | Note: These users are already in docker group (root-equivalent anyway) | [3.3.2](#33-security-gaps) |

---

## 11. Risks & Mitigations

| # | Risk | Impact | Mitigation | Ref |
|---|------|--------|------------|-----|
| 11.1 | Breaking existing workflows | High | Extensive backward compatibility, fallback chain | [6.1](#61-detection--fallback), [6.2](#62-backward-compatibility) |
| 11.2 | SSH access lost | Critical | LISH console always available, admin user with password sudo | [10.1](#101-when-ssh-access-fails) |
| 11.3 | sudo restrictions break automation | Medium | Whitelist all required commands, test thoroughly, keep LISH access | [10.2](#102-when-sudo-restrictions-break-something) |
| 11.4 | Migration confusion | Medium | Clear docs, migration tool, deprecation warnings | [5.3](#53-phase-3-migration-tooling), [6.3](#63-timeline) |
| 11.5 | Audit logging performance | Low | Auditd is lightweight, tested at scale | [4.5](#45-security-hardening) |
| 11.6 | Password forgotten | Medium | Root password in password manager, LISH console, rescue mode | [10.1](#101-when-ssh-access-fails) |

---

*Proposal created: January 24, 2026*
