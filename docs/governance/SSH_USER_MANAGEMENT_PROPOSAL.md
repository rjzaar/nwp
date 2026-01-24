# F12: Comprehensive SSH User Management System

**Status:** PROPOSED | **Priority:** MEDIUM | **Effort:** Low (minimal) / High (full) | **Dependencies:** None

> **TL;DR:** Full proposal is over-engineered. Implement minimal version (~6 hours) instead of full version (~80 hours). See [Worth It Evaluation](#worth-it-evaluation).

## Problem Statement

NWP currently has **7 different approaches** to SSH user determination scattered across commands, leading to:
- Hardcoded user assumptions (`remote.sh` always uses `root`)
- Inconsistent behavior between commands
- No centralized SSH connection abstraction
- Manual server metadata tracking
- Security gaps (overly permissive sudo, no audit trail)

---

## Worth It Evaluation

Applying the Deep Analysis Re-Evaluation framework (YAGNI, 80/20, real vs hypothetical):

### What's Actually Causing Pain?

| Issue | Real Pain? | Frequency | Impact |
|-------|------------|-----------|--------|
| 7 different SSH patterns | Yes, but... | Rarely causes failures | Low - code works |
| Hardcoded `root` in remote.sh | Maybe | When using non-root servers | Medium |
| Hardcoded gitlab/root in live2stg.sh | Yes | Every shared→dedicated scenario | Medium |
| No audit trail | No | Zero security incidents | None |
| NOPASSWD:ALL sudo | No | No external contributors | None |
| Manual server tracking | Minor | Few servers to track | Low |

**Honest Assessment:** The 7 patterns exist, but they mostly work. The *actual* pain points are:
1. `live2stg.sh` hardcoded logic occasionally breaks
2. New server types require manual config hunting
3. Cognitive overhead when debugging SSH issues

### Applying YAGNI

| Proposed Feature | YAGNI Verdict | Reasoning |
|------------------|---------------|-----------|
| `get_ssh_user()` helper | **DO IT** | Solves real duplication, 2-4 hours |
| `ssh_exec()` wrapper | **MAYBE** | Nice abstraction, but scripts work fine |
| Auto-registration | **DON'T** | How many servers/year? 2-3? Manual is fine |
| Migration tooling | **DON'T** | Few servers exist, migrate manually |
| Two-tier sudo model | **DON'T** | No external contributors, no incidents |
| Audit logging | **DON'T** | Solving hypothetical security problem |
| Fail2ban | **MAYBE** | Already on servers? Check first |
| Per-developer keys | **DON'T** | 1-2 developers, shared key is fine |
| Key rotation policy | **DON'T** | Enterprise solution for solo developer |

### The 80/20 Version

**20% of effort that solves 80% of pain:**

1. **Create `get_ssh_user()` function** (2 hours)
   - Resolution chain: config field → parse user@host → recipe default → root
   - Add to `lib/ssh.sh`

2. **Fix the 2 hardcoded scripts** (1 hour)
   - `live2stg.sh:139-140` - use `get_ssh_user()`
   - `lib/remote.sh:99` - use `get_ssh_user()`

3. **Document the standard** (1 hour)
   - Recommend `ssh_user` field in configs
   - Update `example.nwp.yml` with examples

**Total: ~4 hours** vs **~80+ hours for full proposal**

### What NOT To Build

**Security Hardening (40+ hours) - DON'T:**
- No external contributors = no malicious sudo abuse risk
- NOPASSWD:ALL is fine for 1-2 trusted developers
- Audit logging is enterprise theater for a solo project
- Key rotation policy is over-engineering

**Migration Tooling (16+ hours) - DON'T:**
- How many servers exist? Probably < 10
- Manual migration takes 5 minutes per server
- Building tooling for 50 minutes of manual work

**Auto-Registration (8+ hours) - DON'T:**
- Creating ~2-3 servers per year
- Adding 4 lines to nwp.yml manually is fine
- Automation ROI is negative

### Revised Recommendation

| Component | Original Effort | Revised | Action |
|-----------|-----------------|---------|--------|
| Phase 1: Foundation | 2 weeks | **4 hours** | `get_ssh_user()` only |
| Phase 2: Auto-Registration | 1 week | **0** | Skip - manual is fine |
| Phase 3: Migration Tooling | 1 week | **0** | Skip - few servers |
| Phase 4: Update Scripts | 2 weeks | **1 hour** | Fix 2 scripts only |
| Phase 5: Security Hardening | 1 week | **0** | Skip - no threat model |
| Phase 6: Documentation | 1 week | **1 hour** | Brief section in existing docs |
| **TOTAL** | **8 weeks** | **~6 hours** | |

### Decision Framework

**Implement the minimal version (6 hours) IF:**
- [x] SSH user confusion has caused actual debugging time
- [x] The fix is simple and low-risk
- [x] No over-engineering creep

**Implement the full version (8 weeks) ONLY IF:**
- [ ] Adding external contributors who need restricted access
- [ ] Compliance requirements mandate audit logging
- [ ] Managing 20+ servers where automation pays off
- [ ] Security incident demonstrates need for hardening

### Conclusion

**The full proposal is over-engineered for NWP's current scale.**

The 7 SSH patterns are real but not causing significant pain. The security hardening solves hypothetical problems with no evidence of actual risk. The migration and auto-registration tooling has negative ROI given the small number of servers.

**Recommended path:**
1. Implement minimal version (6 hours): `get_ssh_user()` + fix 2 scripts + document
2. Revisit full proposal only if scaling to many contributors/servers
3. Move security hardening to "implement when needed" list

**Time saved by not over-engineering: ~74 hours**

---

## Research Findings

### How the `gitlab` User is Created

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
- Username: `gitlab` (default, configurable via UDF parameter `ssh_user`)
- Home: `/home/gitlab`
- Shell: `/bin/bash`
- Groups: `sudo`, `docker`
- SSH: Key from UDF parameter `$SSH_PUBKEY`
- Sudo: Passwordless via `/etc/sudoers.d/gitlab`

**Other Recipes:**
- NWP (LEMP): Creates `nwp` user (default) or custom user via UDF
- Podcast: Creates `podcast` user (default) via UDF
- All use identical user creation logic

### Current SSH User Patterns (7 Methods)

1. Parse from `linode.servers.ssh_host: user@ip` (combined field)
2. Separate `linode.servers.ssh_user` + `.ssh_host` fields (legacy)
3. Hardcoded by type: `shared→gitlab`, `dedicated→root` (live2stg.sh:139-140)
4. Dynamic fallback: Try gitlab, then root on connection failure
5. Parse from `deployment-info.txt` (podcast only)
6. Hardcoded root (remote.sh:99)
7. Manual override `--ssh=user@host`

### Security Gaps

- **Overly permissive sudo**: `NOPASSWD:ALL` grants root-equivalent access
- **Docker group = root**: Users in docker group have effective root access
- **No audit trail**: No logging of which user performed which action
- **Single shared key**: No per-developer keys for accountability
- **No key rotation**: Keys never expire

## Proposed Solution

### 1. Unified Configuration Schema

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
- Support legacy `user@host` combined format (parse user from it)
- Support separate `ssh_user`/`ssh_host` fields
- Default to `root` when unspecified

### 2. Centralized SSH Helper Functions

**Create `lib/ssh.sh` enhancements:**

```bash
# Get SSH user for any server or site
# Resolution order:
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
# Old way (scattered, hardcoded)
ssh root@$server_ip "systemctl restart nginx"

# New way (centralized, configured)
ssh_exec "$server_name" "systemctl restart nginx"
```

### 3. Auto-Registration After Server Creation

**Add to `lib/yaml-write.sh`:**

```bash
yaml_register_server(server_name, server_ip, ssh_user, linode_id, recipe, [domain])
```

**Integration points:**
- After `create_linode_instance()` in `lib/linode.sh`
- After podcast server creation in `scripts/commands/podcast.sh`
- When deploying to dedicated servers in `scripts/commands/live.sh`

**Result:** Servers automatically added to nwp.yml with complete metadata.

### 4. Recipe SSH User Specification

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

**Flow:** Recipe → StackScript UDF → User creation → Auto-registration

### 5. Security Hardening

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

1. **Linode LISH Console** - Always available, bypasses SSH
   - Access via Linode Cloud Manager or `ssh lish-us-east.linode.com`
   - Logs in as root with server root password
   - Not affected by SSH/sudo changes

2. **Admin User with Password** - Created during provisioning
   - Username: `admin` (or user's choice)
   - Password-required sudo for all commands
   - SSH access with separate key
   - For emergencies and manual server work

3. **Root Password Set** - Via StackScript, stored in password manager
   - Used for LISH console access
   - Not used for SSH (root SSH disabled)

**Add audit logging:**
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
- Fail2ban for SSH brute force protection
- Per-developer SSH keys (not shared key)
- SSH key rotation policy (90 days for developers, 60 for CI/CD)
- Rootless Docker for podcast servers (mitigate docker group risk)

## Implementation Phases

### Phase 1: Foundation
**Goal:** Add new functions without breaking anything

1. Create enhanced `lib/ssh.sh` with new helper functions
2. Add `yaml_register_server()` to `lib/yaml-write.sh`
3. Add `ssh_user` to recipe definitions in `example.nwp.yml`
4. Document new config schema
5. Write unit tests

**Deliverables:**
- New functions available
- All existing code still works
- Tests pass

### Phase 2: Auto-Registration
**Goal:** Servers auto-register with metadata

1. Add server registration to `lib/linode.sh:create_linode_instance()`
2. Add registration to `scripts/commands/podcast.sh`
3. Update `yaml_add_site_live()` to include `ssh_user` and `server_ref`
4. Test server creation and registration

**Deliverables:**
- New servers automatically added to nwp.yml
- Complete metadata captured

### Phase 3: Migration Tooling
**Goal:** Provide migration path for existing configs

1. Create `scripts/commands/migrate-ssh-config.sh`
2. Create `scripts/commands/server-audit.sh` for connection testing
3. Test migration on example configs

**Deliverables:**
- `pl migrate-ssh-config audit` shows current state
- `pl migrate-ssh-config --apply` auto-migrates
- `pl server-audit` detects actual SSH users

### Phase 4: Update Scripts
**Goal:** Migrate commands to use new helpers

**Priority order:**
1. `scripts/commands/live2stg.sh` - Remove hardcoded user logic (lines 139-140)
2. `scripts/commands/stg2live.sh` - Use new helpers
3. `lib/remote.sh` - Replace hardcoded root with `get_ssh_user()`
4. `scripts/commands/import.sh` - Update SSH connection logic
5. `scripts/commands/podcast.sh` - Already partially updated
6. All remaining scripts

**Per-script changes:**
```bash
# Before
SSH_USER="gitlab"
[ "$server_type" == "dedicated" ] && SSH_USER="root"

# After
SSH_USER=$(get_ssh_user "$sitename")
```

**Deliverables:**
- All scripts use centralized functions
- No hardcoded user assumptions
- Consistent behavior across all commands

### Phase 5: Security Hardening
**Goal:** Implement security best practices

1. Update StackScripts with two-tier user model:
   - `deploy` user with command-specific NOPASSWD (for automation)
   - `admin` user with password-required sudo (for emergency access)
   - Keep `gitlab`/`podcast` with NOPASSWD:ALL (package management needs)
2. Add auditd to all StackScripts
3. Add Fail2ban to StackScripts
4. Document emergency access procedures (LISH console, admin user)
5. Document SSH key rotation policy
6. Create per-developer key management guide

**Deliverables:**
- Two-tier user model in new servers
- Emergency access documented and tested
- Audit logging enabled
- Security documentation complete

### Phase 6: Documentation
**Goal:** Complete user-facing documentation

1. Write `docs/guides/ssh-management.md`
2. Write `docs/guides/ssh-config-migration.md`
3. Write `docs/security/ssh-best-practices.md`
4. Update `docs/reference/configuration/nwp-yml-schema.md`
5. Update all deployment guides

## Migration Strategy

### Detection & Fallback

New functions support multiple formats automatically:

1. Check `ssh_user` field (new standard)
2. Parse from `ssh_host: user@ip` (combined format)
3. Check `server_ref` → lookup user from referenced server
4. Type-based detection (gitlab, podcast, etc.)
5. Probe server (optional, enabled with `SSH_PROBE_USERS=1`)
6. Default to `root`

### Backward Compatibility

- Legacy `ssh_user` + `ssh_host` fields: Supported indefinitely
- Combined `user@host` format: Parsed automatically
- No explicit user: Defaults to `root` with warning
- Hardcoded assumptions in old scripts: Still work, updated gradually

### Timeline

- **Now - Month 2**: Both formats work, new format recommended
- **Month 2-3**: Deprecation warnings for legacy format
- **Month 3+**: Optional removal of legacy support (major version bump)

**Zero downtime guarantee:**
- All changes additive in Phase 1-3
- Migration is opt-in
- Fallback chain ensures connections always work
- Auto-migration with backup before v1.0

## Critical Files

### New Files
None - all enhancements go into existing files

### Modified Files (Priority Order)

| Priority | File | Changes | Complexity |
|----------|------|---------|------------|
| 1 | `lib/ssh.sh` | Add `get_ssh_user()`, `get_ssh_connection()`, `ssh_exec()`, `get_ssh_key()` | Medium |
| 2 | `lib/yaml-write.sh` | Add `yaml_register_server()` around line 1020 | Low |
| 3 | `example.nwp.yml` | Add `ssh_user` to recipes (lines 639-1096) and servers (lines 523-580) | Low |
| 4 | `scripts/commands/live2stg.sh` | Replace lines 139-140 with `get_ssh_user()` | Low |
| 5 | `lib/remote.sh` | Update `remote_exec()` to use new helpers | Low |
| 6 | `lib/linode.sh` | Add auto-registration after instance creation (around line 100) | Low |
| 7 | `scripts/commands/podcast.sh` | Add server registration | Low |
| 8 | `scripts/commands/import.sh` | Use new SSH helpers | Medium |
| 9 | `linode/linode_server_setup.sh` | Update sudo config (lines 79-109) | Medium |
| 10 | `linode/gitlab/gitlab_server_setup.sh` | Update sudo config (lines 102-132) | Medium |

### StackScripts Security Updates

**Files:** All StackScripts in `linode/`

**Changes:**
1. Replace `NOPASSWD:ALL` with command-specific sudo
2. Add auditd installation and configuration
3. Add Fail2ban for SSH protection
4. Add automatic security updates

## Verification

### Unit Tests
```bash
# Test SSH user resolution
test_get_ssh_user_from_server_config
test_get_ssh_user_from_site_config
test_get_ssh_user_from_server_ref
test_get_ssh_user_legacy_format
test_get_ssh_user_defaults_to_root

# Test connection strings
test_get_ssh_connection
test_get_ssh_key

# Test backward compatibility
test_legacy_ssh_user_plus_ssh_host
test_combined_user_at_host
test_missing_user_defaults_root
```

### Integration Tests
```bash
# Test actual SSH connections
test_ssh_exec_with_new_config
test_ssh_exec_with_legacy_config
test_import_command_with_new_config
test_stg2prod_with_new_config

# Test auto-registration
test_server_provision_and_register
test_podcast_install_registers_server
```

### Manual Testing
```bash
# 1. Test pl status servers
./pl status servers
# Expected: Shows all Linode instances

# 2. Test podcast server selection
./pl install pod test
# Expected: Offers existing nwpcode server with gitlab user

# 3. Test import with new config
./pl import --server=nwpcode test-import
# Expected: Connects as gitlab user

# 4. Test migration tool
./pl migrate-ssh-config audit
# Expected: Shows current config format status

# 5. Test server audit
./pl server-audit
# Expected: Shows SSH user for each server
```

## Success Criteria

### Functional
- [ ] Single function to get SSH user for any server/site
- [ ] SSH connections work consistently across all scripts
- [ ] Auto-registration captures complete server metadata
- [ ] Backward compatibility with existing configs
- [ ] Migration path from old to new format

### Security
- [ ] Command-specific sudo (no more NOPASSWD:ALL for deploy users)
- [ ] Audit logging for all sudo commands
- [ ] SSH key rotation policy documented
- [ ] Fail2ban protection on all servers

### Quality
- [ ] 95%+ test coverage for SSH helper functions
- [ ] Zero hardcoded SSH user assumptions in new code
- [ ] All existing scripts updated to use helpers
- [ ] Complete documentation

### Performance
- [ ] SSH user lookup < 100ms
- [ ] No degradation in SSH connection speed
- [ ] Auto-registration adds < 1s to server creation

## Emergency Recovery Procedures

### When SSH Access Fails

**Option 1: Linode LISH Console (Recommended)**
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
1. Linode Cloud Manager → Select instance → "Rescue" tab
2. Boot into Rescue Mode
3. Mount disk: `mount /dev/sda /mnt`
4. Chroot: `chroot /mnt`
5. Fix configuration
6. Reboot to normal mode

**Option 3: Admin User (If SSH Works)**
```bash
# SSH as admin user with password sudo
ssh -i ~/.ssh/admin admin@server

# Enter password when prompted for sudo
sudo vi /etc/sudoers.d/deploy
sudo systemctl restart sshd
```

### When Sudo Restrictions Break Something

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
1. Identify missing command from audit logs
2. Update StackScript sudoers template
3. Add to deploy user whitelist
4. Deploy fix to all servers via `pl server-update-sudo`

### When GitLab/Podcast Breaks

**Keep NOPASSWD:ALL for these users:**
- GitLab package management (`gitlab-ctl reconfigure`, etc.) requires unpredictable commands
- Docker Compose (podcast) needs various Docker commands
- Automation is core to these services, not optional

**If issue occurs:**
- LISH console as root still works
- Admin user still has full sudo
- These users are already in docker group (root-equivalent anyway)

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Breaking existing workflows | High | Extensive backward compatibility, fallback chain |
| SSH access lost | Critical | LISH console always available, admin user with password sudo |
| sudo restrictions break automation | Medium | Whitelist all required commands, test thoroughly, keep LISH access |
| Migration confusion | Medium | Clear docs, migration tool, deprecation warnings |
| Audit logging performance | Low | Auditd is lightweight, tested at scale |
| Password forgotten | Medium | Root password in password manager, LISH console, rescue mode |

---

*Proposal created: January 24, 2026*
