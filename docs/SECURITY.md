# NWP Security Documentation

**Last Updated:** 2026-01-14
**Version:** 0.20.0+

This document describes NWP's security architecture, threat models, and best practices.

## Table of Contents

- [Overview](#overview)
- [SSH Security](#ssh-security)
- [Secrets Management](#secrets-management)
- [Command Injection Prevention](#command-injection-prevention)
- [Network Security](#network-security)
- [Best Practices](#best-practices)

---

## Overview

NWP implements defense-in-depth security with multiple layers:

1. **Input Validation** - All user input sanitized before use
2. **Proper Quoting** - Variables properly quoted to prevent injection
3. **Secrets Isolation** - Two-tier secrets system (infrastructure vs. data)
4. **SSH Controls** - Configurable host key verification
5. **Audit Logging** - Security-relevant actions logged

### Threat Model

NWP protects against:

- **Command Injection** - Malicious input executing arbitrary commands
- **Path Traversal** - Accessing files outside intended directories
- **Credential Exposure** - Secrets leaked in logs or version control
- **MITM Attacks** - Man-in-the-middle on SSH connections
- **Privilege Escalation** - Unauthorized access to production systems

---

## SSH Security

### Host Key Verification Modes

NWP supports two SSH host key verification modes:

#### 1. Accept-New Mode (Default)

**Setting:** `StrictHostKeyChecking=accept-new`

**Behavior:**
- First connection: Automatically accepts and saves host key
- Subsequent connections: Verifies against saved key
- Rejects if host key changes (prevents some MITM attacks)

**Security:**
- ✅ Protects against MITM after first connection
- ✅ Detects server key changes (compromise indicator)
- ❌ Vulnerable to MITM on first connection
- ✅ Convenient for development and testing

**Use When:**
- Local development environments
- Trusted networks
- Automated testing
- Convenience outweighs first-connection risk

#### 2. Strict Mode (High Security)

**Setting:** `export NWP_SSH_STRICT=1`

**Behavior:**
- Only connects to hosts with keys in `~/.ssh/known_hosts`
- Rejects any unknown host key
- Prevents all automatic key acceptance

**Security:**
- ✅ Maximum protection against MITM attacks
- ✅ Requires explicit trust for new hosts
- ✅ Recommended for production deployments
- ❌ Requires manual key management

**Use When:**
- Production deployments
- Untrusted networks
- Compliance requirements (SOC 2, PCI-DSS, etc.)
- Maximum security required

### Enabling Strict Mode

**Temporarily:**
```bash
export NWP_SSH_STRICT=1
./pl deploy prod
```

**Permanently (add to ~/.bashrc or ~/.zshrc):**
```bash
export NWP_SSH_STRICT=1
```

**For CI/CD:**
```yaml
# .gitlab-ci.yml
deploy:
  script:
    - export NWP_SSH_STRICT=1
    - ./pl deploy prod
```

### Managing Known Hosts in Strict Mode

When using `NWP_SSH_STRICT=1`, you must manually verify and add host keys:

**Method 1: ssh-keyscan (verify fingerprint separately)**
```bash
# Get host key fingerprint from server console/provider
ssh-keyscan -H your-server.com >> ~/.ssh/known_hosts

# Verify fingerprint matches
ssh-keygen -lf ~/.ssh/known_hosts | grep your-server.com
```

**Method 2: First connection with verification**
```bash
# Connect manually first time
ssh user@your-server.com
# Verify fingerprint against server console, then accept
# Subsequent NWP commands will use saved key
```

**Method 3: Provider-managed known_hosts**
```bash
# Some cloud providers offer verified host keys
curl https://provider.com/known_hosts >> ~/.ssh/known_hosts
```

### Security Warnings

NWP displays warnings when using accept-new mode:

```
⚠️  SSH Host Key Verification: Using 'accept-new' mode
    First connection will accept server fingerprint automatically
    This is convenient but vulnerable to MITM on first connection

    For strict mode: export NWP_SSH_STRICT=1
```

**To suppress warnings** (not recommended):
```bash
export NWP_SSH_QUIET=1  # Hides security warnings
```

### SSH Best Practices

1. **Use SSH keys, not passwords**
   ```bash
   ./pl setup-ssh  # Generates Ed25519 key pair
   ```

2. **Protect private keys**
   ```bash
   chmod 600 ~/.ssh/id_ed25519
   ```

3. **Use passphrases on keys**
   ```bash
   ssh-keygen -p -f ~/.ssh/id_ed25519  # Add/change passphrase
   ```

4. **Rotate keys regularly**
   ```bash
   ./pl setup-ssh --force  # Generate new key
   # Upload new public key to servers
   ```

5. **Audit authorized_keys**
   ```bash
   ./pl ssh prod "cat ~/.ssh/authorized_keys"
   # Remove any unrecognized keys
   ```

---

## Secrets Management

NWP uses a two-tier secrets system to protect user data while allowing AI assistance with infrastructure.

### Two-Tier Architecture

#### Tier 1: Infrastructure Secrets (.secrets.yml)

**Safe for AI/Claude to access**

Contains:
- Linode API tokens (server management only)
- Cloudflare API tokens (DNS management only)
- GitLab API tokens (repository access only)

These secrets cannot access user data, only infrastructure automation.

**Example:**
```yaml
cloudflare:
  api_token: "cf_token_here"  # Can only manage DNS
  zone_id: "zone_id_here"

linode:
  api_token: "linode_token_here"  # Can only create/manage servers

gitlab:
  api_token: "gitlab_token_here"  # Can only access repositories
```

#### Tier 2: Data Secrets (.secrets.data.yml)

**BLOCKED from AI/Claude access**

Contains:
- Production database credentials
- SSH private keys for production
- SMTP credentials
- Application secrets
- Any credential that accesses user data

**Example:**
```yaml
production_database:
  host: "prod-db.example.com"
  user: "drupal_prod"
  password: "REDACTED"  # Never show to AI

smtp:
  host: "smtp.example.com"
  password: "REDACTED"  # Never show to AI
```

### Using Secrets in Scripts

**Infrastructure secrets (safe to use with AI assistance):**
```bash
source lib/common.sh

token=$(get_infra_secret "linode.api_token" "")
if [ -z "$token" ]; then
    print_error "Linode API token not configured"
    exit 1
fi
```

**Data secrets (use carefully, never log):**
```bash
source lib/common.sh

db_pass=$(get_data_secret "production_database.password" "")
if [ -z "$db_pass" ]; then
    print_error "Database password not configured"
    exit 1
fi
# NEVER echo or log $db_pass
```

### Secrets Best Practices

1. **Never commit secrets to git**
   - `.secrets.yml` and `.secrets.data.yml` are in `.gitignore`
   - Use `example.secrets.yml` as template

2. **Use different secrets for dev/stg/prod**
   ```yaml
   development:
     database:
       password: "dev_password"

   production:
     database:
       password: "strong_prod_password"
   ```

3. **Rotate secrets regularly**
   - Update API tokens quarterly
   - Change database passwords after staff changes
   - Regenerate SSH keys annually

4. **Encrypt secrets at rest** (optional)
   ```bash
   # Use ansible-vault or similar
   ansible-vault encrypt .secrets.data.yml
   ```

5. **Audit secret access**
   ```bash
   grep "get_data_secret" scripts/**/*.sh lib/**/*.sh
   # Review which scripts access sensitive data
   ```

---

## Command Injection Prevention

### Security Patterns

NWP follows these patterns to prevent command injection:

#### 1. Always Quote Variables

**Bad (vulnerable):**
```bash
ssh_cmd="ssh -i $key_path"  # $key_path not quoted
$ssh_cmd user@host           # Command injection possible
```

**Good (safe):**
```bash
ssh_cmd=(ssh -i "$key_path")  # Array with quoted variable
"${ssh_cmd[@]}" user@host      # Safe expansion
```

#### 2. Use Arrays for Commands

**Bad (vulnerable):**
```bash
cmd="rsync -av $source $dest"
$cmd  # Word splitting issues
```

**Good (safe):**
```bash
cmd=(rsync -av "$source" "$dest")
"${cmd[@]}"  # Proper word splitting
```

#### 3. Validate Input Before Use

**Example:**
```bash
# Validate sitename contains only safe characters
if [[ ! "$sitename" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    print_error "Invalid sitename: contains unsafe characters"
    return 1
fi
```

#### 4. Use stdin for Untrusted Data

**Bad (vulnerable):**
```bash
ssh user@host "echo $untrusted_data >> file"  # Injection possible
```

**Good (safe):**
```bash
echo "$untrusted_data" | ssh user@host "cat >> file"  # Data via stdin
```

#### 5. YAML/AWK Injection Protection

**Critical Configuration File Protection:**

NWP's `cnwp.yml` is the central configuration file containing site definitions, server settings, and deployment configurations. AWK operations on this file require special protection to prevent data loss from edge cases, duplicate entries, or malformed input.

**The 5-Layer Protection System** (implemented in commits fb2f2603 and ea07e155):

1. **Line Count Tracking** - Store original file size before modification
   ```bash
   original_line_count=$(wc -l < cnwp.yml)
   ```

2. **mktemp for Atomic Writes** - Use secure temporary files instead of `.tmp`
   ```bash
   tmpfile=$(mktemp) || { echo "Failed to create temp file"; return 1; }
   ```

3. **Empty Output Detection** - Abort if AWK produces empty file
   ```bash
   if [ ! -s "$tmpfile" ]; then
       echo "ERROR: AWK operation produced empty file"
       rm -f "$tmpfile"
       return 1
   fi
   ```

4. **Sanity Checks** - Prevent suspiciously large deletions (>100 lines)
   ```bash
   new_line_count=$(wc -l < "$tmpfile")
   lines_removed=$((original_line_count - new_line_count))
   if [ "$lines_removed" -gt 100 ]; then
       echo "ERROR: Would remove $lines_removed lines (>100), aborting"
       rm -f "$tmpfile"
       return 1
   fi
   ```

5. **Atomic Move** - Only update cnwp.yml if all validations pass
   ```bash
   mv "$tmpfile" cnwp.yml || {
       echo "ERROR: Failed to update cnwp.yml"
       rm -f "$tmpfile"
       return 1
   }
   ```

**Applied to:**
- `lib/yaml-write.sh` - All YAML modification functions
- `scripts/commands/verify.sh` - Verification system cleanup and Linode server management
- Any script performing AWK operations on cnwp.yml

**Why This Matters:**

In January 2026, a duplicate entry bug in the verification system caused complete data loss of a user's cnwp.yml file. The AWK operation encountered duplicate site entries and produced an empty output, which was blindly written back to cnwp.yml, wiping all user configurations. The 5-layer protection system prevents this entire class of errors.

### Input Validation Rules

1. **Sitenames:** `^[a-zA-Z0-9._-]+$`
2. **Environments:** `^[a-zA-Z0-9._-]+$`
3. **Paths:** Must be absolute, no `..` components
4. **Emails:** Use proper email regex
5. **URLs:** Validate protocol and format

### Code Review Checklist

When reviewing shell scripts, check for:

- [ ] All variables in commands are quoted: `"$var"`
- [ ] Command arguments use arrays: `cmd=(...)`
- [ ] User input is validated before use
- [ ] No variables in eval or command substitution
- [ ] Untrusted data passed via stdin, not command line
- [ ] AWK operations on cnwp.yml use 5-layer protection system
- [ ] Shellcheck passes with no warnings

---

## Network Security

### TLS/SSL

NWP enforces HTTPS for all web traffic:

```yaml
# example.cnwp.yml
sites:
  mysite:
    dev:
      https: true           # Enforce HTTPS
      hsts: true            # HTTP Strict Transport Security
      tls_version: "1.3"    # Minimum TLS 1.3
```

### Firewall Rules

Recommended firewall configuration:

```bash
# Allow SSH (from trusted IPs only)
ufw allow from 1.2.3.4 to any port 22

# Allow HTTP/HTTPS
ufw allow 80/tcp
ufw allow 443/tcp

# Default deny
ufw default deny incoming
ufw default allow outgoing

# Enable
ufw enable
```

### Network Scanning

Audit open ports:

```bash
./pl server-scan prod
# Shows open ports, services, vulnerabilities
```

---

## Best Practices

### Development Workflow

1. **Never work directly on production**
   ```bash
   ./pl dev2stg    # Test on staging first
   ./pl stg2prod   # Deploy to production
   ```

2. **Use feature branches**
   ```bash
   git checkout -b feature/new-feature
   # Make changes
   git push origin feature/new-feature
   # Create merge request
   ```

3. **Test security changes**
   ```bash
   ./pl verify --run   # Run verification system
   # Verify 98%+ pass rate
   ```

### Production Deployments

1. **Enable strict SSH mode**
   ```bash
   export NWP_SSH_STRICT=1
   ```

2. **Use read-only monitoring**
   ```bash
   ./pl status prod  # Safe, read-only check
   ```

3. **Backup before changes**
   ```bash
   ./pl backup prod
   ./pl update prod
   ```

4. **Audit after deployment**
   ```bash
   ./pl security-check prod
   ```

### Compliance Considerations

For regulated environments:

1. **Enable audit logging**
   ```bash
   export NWP_AUDIT_LOG=/var/log/nwp/audit.log
   ```

2. **Use strict SSH mode**
   ```bash
   export NWP_SSH_STRICT=1
   ```

3. **Rotate credentials regularly**
   - SSH keys: Annually
   - API tokens: Quarterly
   - Database passwords: After staff changes

4. **Review access regularly**
   ```bash
   ./pl audit-access  # Show who has access
   ```

---

## Security Incident Response

If you suspect a security incident:

1. **Isolate affected systems**
   ```bash
   # Disable SSH access
   sudo ufw deny 22
   ```

2. **Preserve evidence**
   ```bash
   # Copy logs before investigation
   ./pl backup-logs prod
   ```

3. **Rotate all credentials**
   ```bash
   ./pl rotate-secrets --all
   ```

4. **Review access logs**
   ```bash
   ./pl audit-logs prod --since "24 hours ago"
   ```

5. **Report to team**
   - Document timeline
   - Identify affected data
   - Plan remediation

---

## Security Contacts

- **Security Issues:** Create private issue in GitLab
- **Vulnerabilities:** Email security@nwpcode.org
- **Urgent Incidents:** Use on-call rotation

---

## Additional Resources

- [OWASP Bash Security Cheatsheet](https://cheatsheetseries.owasp.org/cheatsheets/OS_Command_Injection_Defense_Cheat_Sheet.html)
- [SSH Security Best Practices](https://www.ssh.com/academy/ssh/security)
- [NWP Data Security Best Practices](DATA_SECURITY_BEST_PRACTICES.md)
- [Distributed Contribution Governance](DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md)

---

**Last Review:** 2026-01-14
**Next Review:** 2026-04-14 (quarterly)
