# P56: Production Security Hardening

**Status:** PROPOSED
**Created:** 2026-01-18
**Author:** Rob, Claude Opus 4.5
**Priority:** Medium
**Depends On:** P54 (removes grep tests expecting this feature)
**Estimated Effort:** 1-2 weeks
**Breaking Changes:** No - additive feature

---

## 1. Executive Summary

### 1.1 Problem Statement

The verification tests expect `produce.sh` to handle security hardening:
```bash
grep -qE '(ufw|fail2ban|ssl|security)' scripts/commands/produce.sh
```

Currently only SSL (Let's Encrypt) is mentioned. UFW firewall and fail2ban intrusion prevention are **not implemented**.

### 1.2 Proposed Solution

Add security hardening features to `produce.sh` for production server provisioning:
1. UFW firewall configuration
2. Fail2ban intrusion prevention
3. SSL hardening (beyond basic Let's Encrypt)
4. Security headers for nginx

### 1.3 Key Benefits

| Benefit | Description |
|---------|-------------|
| Defense in depth | Multiple security layers |
| Automated setup | Consistent security across servers |
| Industry standards | OWASP-compliant configurations |
| SSL Labs A+ | Achievable score with hardening |

---

## 2. Proposed Features

### 2.1 UFW Firewall Configuration

```bash
setup_firewall() {
    local server_ip="$1"

    print_info "Configuring UFW firewall..."

    ssh "root@${server_ip}" << 'REMOTE_SCRIPT'
        # Install ufw if not present
        apt-get install -y ufw

        # Default policies
        ufw default deny incoming
        ufw default allow outgoing

        # Allow essential services
        ufw allow 22/tcp    # SSH
        ufw allow 80/tcp    # HTTP
        ufw allow 443/tcp   # HTTPS

        # Enable firewall
        ufw --force enable

        # Show status
        ufw status verbose
REMOTE_SCRIPT

    print_success "Firewall configured"
}
```

### 2.2 Fail2ban Integration

```bash
setup_fail2ban() {
    local server_ip="$1"

    print_info "Configuring fail2ban..."

    ssh "root@${server_ip}" << 'REMOTE_SCRIPT'
        # Install fail2ban
        apt-get install -y fail2ban

        # Create local jail config
        cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3

[nginx-http-auth]
enabled = true
port = http,https
filter = nginx-http-auth
logpath = /var/log/nginx/error.log

[nginx-botsearch]
enabled = true
port = http,https
filter = nginx-botsearch
logpath = /var/log/nginx/access.log
maxretry = 2
EOF

        # Restart fail2ban
        systemctl restart fail2ban
        systemctl enable fail2ban

        # Show status
        fail2ban-client status
REMOTE_SCRIPT

    print_success "Fail2ban configured"
}
```

### 2.3 SSL Hardening

```bash
harden_ssl() {
    local server_ip="$1"
    local domain="$2"

    print_info "Hardening SSL configuration..."

    ssh "root@${server_ip}" << REMOTE_SCRIPT
        # Generate strong DH parameters (if not exists)
        if [[ ! -f /etc/ssl/certs/dhparam.pem ]]; then
            openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048
        fi

        # Create security headers config
        cat > /etc/nginx/snippets/security-headers.conf << 'EOF'
# Security Headers
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline';" always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
EOF

        # Create SSL config
        cat > /etc/nginx/snippets/ssl-params.conf << 'EOF'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
ssl_prefer_server_ciphers off;
ssl_dhparam /etc/ssl/certs/dhparam.pem;
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:50m;
ssl_stapling on;
ssl_stapling_verify on;
EOF

        nginx -t && systemctl reload nginx
REMOTE_SCRIPT

    print_success "SSL hardened"
}
```

---

## 3. Integration into produce.sh

### 3.1 Main Workflow Addition

```bash
main() {
    # ... existing provisioning ...

    # Security hardening (new)
    if [[ "$SKIP_FIREWALL" != "true" ]]; then
        setup_firewall "$SERVER_IP"
    fi

    if [[ "$SKIP_FAIL2BAN" != "true" ]]; then
        setup_fail2ban "$SERVER_IP"
    fi

    if [[ "$SKIP_SSL_HARDENING" != "true" ]]; then
        harden_ssl "$SERVER_IP" "$DOMAIN"
    fi

    # ... rest of provisioning ...
}
```

### 3.2 CLI Options

| Flag | Description |
|------|-------------|
| `--no-firewall` | Skip UFW configuration |
| `--no-fail2ban` | Skip fail2ban setup |
| `--no-ssl-hardening` | Skip SSL hardening (use basic Let's Encrypt only) |
| `--security-only` | Only run security hardening (skip other provisioning) |

### 3.3 Example Usage

```bash
# Full provisioning with security
pl produce mysite

# Skip firewall (e.g., cloud provider handles it)
pl produce mysite --no-firewall

# Security hardening only on existing server
pl produce mysite --security-only
```

---

## 4. Verification

### 4.1 Machine Tests

```yaml
# Add to .verification.yml produce: section
- text: "Security hardening configured"
  machine:
    automatable: true
    checks:
      thorough:
        commands:
          - cmd: grep -qE '(ufw|fail2ban|ssl|security)' scripts/commands/produce.sh
            expect_exit: 0
          - cmd: grep -q 'setup_firewall' scripts/commands/produce.sh
            expect_exit: 0
          - cmd: grep -q 'setup_fail2ban' scripts/commands/produce.sh
            expect_exit: 0
```

### 4.2 Manual Verification

| Check | Command | Expected |
|-------|---------|----------|
| UFW status | `ssh root@server 'ufw status'` | Active, ports 22/80/443 |
| Fail2ban status | `ssh root@server 'fail2ban-client status'` | Jails active |
| SSL grade | SSL Labs test | A or A+ |
| Headers | `curl -I https://site.com` | Security headers present |

---

## 5. Success Criteria

- [ ] `grep -qE '(ufw|fail2ban|ssl|security)' produce.sh` passes
- [ ] UFW blocks unauthorized ports
- [ ] Fail2ban bans repeated failed login attempts
- [ ] SSL Labs test scores A or A+
- [ ] Security headers present in HTTP responses
- [ ] All features optional via CLI flags
- [ ] Documentation updated

---

## 6. Security Considerations

### 6.1 SSH Access Preservation

The UFW configuration must allow SSH (port 22) before enabling:
```bash
ufw allow 22/tcp    # MUST come before ufw enable
ufw --force enable  # --force prevents interactive prompt
```

### 6.2 Fail2ban Tuning

Default values balanced between security and usability:
- `bantime = 3600` (1 hour, not permanent)
- `maxretry = 3-5` (allows some mistakes)
- `findtime = 600` (10 minute window)

### 6.3 SSL Compatibility

TLSv1.2 minimum balances security vs compatibility:
- Drops TLSv1.0/1.1 (deprecated, insecure)
- Keeps TLSv1.2 for older clients
- Prefers TLSv1.3 when available

---

## 7. Developer SSH Key Management

### 7.1 Problem

Currently, when onboarding a new developer:
1. Admin runs `coder-setup.sh add john --email john@example.com`
2. Developer must manually add their SSH public key to GitLab profile
3. Admin can only verify the key exists via `pl coders` (SSH column Y/N)

There is no streamlined flow for the developer to submit their public key and the lead developer to approve and deploy it.

### 7.2 Proposed: SSH Key Onboarding via `coder-setup.sh`

**Enhancement to `coder-setup.sh add`:**

```bash
# Lead developer onboards new coder with SSH key in one command
pl coder-setup add john \
  --email john@example.com \
  --fullname "John Doe" \
  --ssh-key "ssh-ed25519 AAAA... john@laptop"

# Or from a file the developer sent (email, Slack, etc.)
pl coder-setup add john \
  --email john@example.com \
  --ssh-key-file /tmp/john_id_ed25519.pub
```

**What happens:**
1. GitLab account created (existing)
2. Added to nwp group (existing)
3. **NEW:** SSH public key registered to their GitLab account via `gitlab_add_user_ssh_key()`
4. **NEW:** SSH public key added to relevant server `authorized_keys` (optional, via `--deploy-to-servers`)
5. Developer can immediately `git clone` via SSH — no manual step needed

**Implementation:** ~30 lines in `coder-setup.sh` — the library function `gitlab_add_user_ssh_key()` already exists in `lib/git.sh`.

### 7.3 Developer Key Submission Flow

**Recommended workflow for new developers:**

```
Developer                          Lead Developer
─────────                          ──────────────
1. Generate keypair:
   ssh-keygen -t ed25519

2. Send public key to lead:
   cat ~/.ssh/id_ed25519.pub
   → email/Slack/secure channel  ──→  3. Receives public key

                                      4. Verify key fingerprint:
                                         ssh-keygen -lf /tmp/john.pub

                                      5. Onboard with key:
                                         pl coder-setup add john \
                                           --email john@example.com \
                                           --ssh-key-file /tmp/john.pub

                                      6. Optionally deploy to servers:
                                         pl coder-setup deploy-key john \
                                           --servers nwpcode,production

Developer receives credentials  ←──  7. Send GitLab credentials + confirmation

8. Clone immediately:
   git clone git@nwpcode.org:nwp/nwp.git
```

### 7.4 Server Key Deployment

For servers where the developer needs direct SSH access:

```bash
# Deploy a coder's key to specific servers
pl coder-setup deploy-key john --servers nwpcode,production

# What it does:
# 1. Reads john's public key from GitLab API
# 2. SSH to each server as current admin
# 3. Appends key to /home/<ssh_user>/.ssh/authorized_keys
# 4. Records deployment in nwp.yml under coders.john.server_keys
```

### 7.5 Key Revocation

When a developer leaves:

```bash
# Remove developer and revoke all keys
pl coder-setup remove john

# What it does:
# 1. Removes SSH keys from GitLab account
# 2. Removes keys from all servers where deployed
# 3. Blocks GitLab account
# 4. Updates nwp.yml (status: removed)
```

### 7.6 Annual Key Review

Once per year, the lead developer runs:

```bash
pl coder-setup key-audit

# Output:
# ┌─────────────────────────────────────────────────────┐
# │ SSH Key Audit - 2026-02-01                          │
# ├──────────┬──────────────┬────────────┬──────────────┤
# │ Coder    │ GitLab Key   │ Server Keys│ Last Active  │
# ├──────────┼──────────────┼────────────┼──────────────┤
# │ rob      │ ed25519 (2y) │ 3 servers  │ 2026-02-01   │
# │ greg     │ ed25519 (1y) │ 2 servers  │ 2026-01-15   │
# │ sarah    │ NONE         │ 0 servers  │ 2025-12-01   │
# └──────────┴──────────────┴────────────┴──────────────┘
#
# ⚠ sarah: No SSH key registered and inactive for 62 days
# ⚠ rob: Key is 2 years old, consider regenerating
```

---

## 8. Related Proposals

| Proposal | Relationship |
|----------|--------------|
| P54 | Removes grep test that expects this feature |
| P57 | Companion caching/performance proposal |
| P50 | Verification system this integrates with |
| F15 | SSH user management — per-developer keys and fail2ban overlap |
