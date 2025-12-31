# NWP Email Infrastructure Proposal: Postfix with Full Authentication

**Document Version:** 1.0
**Date:** December 31, 2025
**Goal:** Achieve 10/10 mail-tester.com score for all NWP email

---

## Executive Summary

This proposal outlines setting up a complete email infrastructure on the NWP GitLab server using Postfix, enabling:
- GitLab notification emails (git@nwpcode.org)
- Per-site functional emails (nwp1@nwpcode.org, contact@sitename.nwpcode.org)
- Full email authentication (SPF, DKIM, DMARC) for maximum deliverability

### Architecture Overview

```
                                    ┌─────────────────────────────────┐
                                    │   git.nwpcode.org (GitLab)      │
                                    │                                 │
┌──────────────┐                    │  ┌─────────────────────────┐   │
│   Drupal     │──SMTP (587)───────▶│  │       Postfix           │   │
│   Sites      │                    │  │  (MTA - Send/Receive)   │   │
└──────────────┘                    │  └───────────┬─────────────┘   │
                                    │              │                 │
┌──────────────┐                    │  ┌───────────▼─────────────┐   │
│   GitLab     │──────────────────▶ │  │      OpenDKIM           │   │
│   App        │                    │  │   (DKIM Signing)        │   │
└──────────────┘                    │  └───────────┬─────────────┘   │
                                    │              │                 │
┌──────────────┐                    │  ┌───────────▼─────────────┐   │
│   External   │◀──────────────────▶│  │      Dovecot            │   │
│   Email      │                    │  │  (IMAP - Mailboxes)     │   │
└──────────────┘                    │  └─────────────────────────┘   │
                                    │                                 │
                                    └─────────────────────────────────┘

DNS Records (Linode):
├── SPF:   TXT  "v=spf1 ip4:97.107.137.88 -all"
├── DKIM:  TXT  default._domainkey.nwpcode.org
├── DMARC: TXT  _dmarc.nwpcode.org
└── PTR:   97.107.137.88 → git.nwpcode.org
```

---

## 10/10 Mail-Tester Score Requirements

| Requirement | Component | Status |
|-------------|-----------|--------|
| SPF Record | DNS TXT | Required |
| DKIM Signing | OpenDKIM | Required |
| DMARC Policy | DNS TXT | Required |
| Reverse DNS (PTR) | Linode rDNS | Required |
| FCrDNS Match | A record ↔ PTR | Required |
| HELO/Hostname Match | Postfix config | Required |
| Not on Blacklists | Clean IP | Required |
| Valid Message Content | SpamAssassin | Required |

---

## Numbered Proposal

### Phase 1: Core Email Infrastructure

#### E01: Install and Configure Postfix
**Priority:** HIGH | **Effort:** Medium | **Dependencies:** GitLab server running

Install Postfix as the Mail Transfer Agent (MTA) on the GitLab server.

**Installation:**
```bash
sudo apt update
sudo apt install postfix mailutils libsasl2-modules
```

**Key Configuration (`/etc/postfix/main.cf`):**
```conf
# Basic settings
myhostname = git.nwpcode.org
mydomain = nwpcode.org
myorigin = $mydomain
mydestination = $myhostname, localhost.$mydomain, localhost

# Network settings
inet_interfaces = all
inet_protocols = ipv4

# TLS settings
smtpd_tls_cert_file = /etc/letsencrypt/live/git.nwpcode.org/fullchain.pem
smtpd_tls_key_file = /etc/letsencrypt/live/git.nwpcode.org/privkey.pem
smtpd_use_tls = yes
smtpd_tls_security_level = may
smtp_tls_security_level = may

# Virtual mailbox settings (for multi-site support)
virtual_mailbox_domains = nwpcode.org
virtual_mailbox_base = /var/mail/vhosts
virtual_mailbox_maps = hash:/etc/postfix/vmailbox
virtual_alias_maps = hash:/etc/postfix/virtual
virtual_uid_maps = static:5000
virtual_gid_maps = static:5000

# SASL authentication
smtpd_sasl_auth_enable = yes
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_security_options = noanonymous
smtpd_recipient_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination

# Milter settings for DKIM
milter_protocol = 6
milter_default_action = accept
smtpd_milters = inet:localhost:8891
non_smtpd_milters = inet:localhost:8891
```

**Success Criteria:**
- [ ] Postfix installed and running
- [ ] Can send test email via command line
- [ ] TLS encryption working

---

#### E02: Configure SPF Record
**Priority:** HIGH | **Effort:** Low | **Dependencies:** E01, Linode DNS

SPF (Sender Policy Framework) specifies which servers can send email for your domain.

**DNS Record:**
```
Type: TXT
Name: @
Value: v=spf1 ip4:97.107.137.88 a mx -all
TTL: 300
```

**Explanation:**
- `v=spf1` - SPF version
- `ip4:97.107.137.88` - GitLab server IP authorized to send
- `a` - Allow IPs from A record
- `mx` - Allow IPs from MX records
- `-all` - Reject all other sources (strict)

**Linode API Command:**
```bash
linode-cli domains records-create $DOMAIN_ID \
  --type TXT \
  --name "@" \
  --target "v=spf1 ip4:97.107.137.88 a mx -all" \
  --ttl_sec 300
```

**Success Criteria:**
- [ ] SPF record visible via `dig TXT nwpcode.org`
- [ ] SPF check passes at mail-tester.com

---

#### E03: Install and Configure OpenDKIM
**Priority:** HIGH | **Effort:** Medium | **Dependencies:** E01

DKIM (DomainKeys Identified Mail) cryptographically signs outgoing emails.

**Installation:**
```bash
sudo apt install opendkim opendkim-tools
sudo usermod -aG opendkim postfix
```

**Configuration (`/etc/opendkim.conf`):**
```conf
AutoRestart             Yes
AutoRestartRate         10/1h
UMask                   002
Syslog                  yes
SyslogSuccess           Yes
LogWhy                  Yes

Canonicalization        relaxed/simple
ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
Mode                    sv
SignatureAlgorithm      rsa-sha256
Socket                  inet:8891@localhost
PidFile                 /run/opendkim/opendkim.pid
OversignHeaders         From

# Multi-domain support
SubDomains              yes
```

**Trusted Hosts (`/etc/opendkim/TrustedHosts`):**
```
127.0.0.1
localhost
*.nwpcode.org
```

**Generate DKIM Keys:**
```bash
sudo mkdir -p /etc/opendkim/keys/nwpcode.org
cd /etc/opendkim/keys/nwpcode.org
sudo opendkim-genkey -s default -d nwpcode.org -b 2048
sudo chown opendkim:opendkim default.private
```

**Key Table (`/etc/opendkim/KeyTable`):**
```
default._domainkey.nwpcode.org nwpcode.org:default:/etc/opendkim/keys/nwpcode.org/default.private
```

**Signing Table (`/etc/opendkim/SigningTable`):**
```
*@nwpcode.org default._domainkey.nwpcode.org
*@*.nwpcode.org default._domainkey.nwpcode.org
```

**DNS Record (from default.txt):**
```
Type: TXT
Name: default._domainkey
Value: v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkq...
TTL: 300
```

**Success Criteria:**
- [ ] OpenDKIM running and connected to Postfix
- [ ] DKIM record in DNS
- [ ] Outgoing emails have DKIM signature
- [ ] DKIM check passes at mail-tester.com

---

#### E04: Configure DMARC Record
**Priority:** HIGH | **Effort:** Low | **Dependencies:** E02, E03

DMARC tells receiving servers what to do with emails that fail SPF/DKIM.

**DNS Record:**
```
Type: TXT
Name: _dmarc
Value: v=DMARC1; p=quarantine; sp=quarantine; rua=mailto:dmarc@nwpcode.org; ruf=mailto:dmarc@nwpcode.org; adkim=r; aspf=r; pct=100
TTL: 300
```

**Explanation:**
- `v=DMARC1` - DMARC version
- `p=quarantine` - Quarantine emails that fail (start here, move to `reject` later)
- `sp=quarantine` - Same policy for subdomains
- `rua=mailto:dmarc@nwpcode.org` - Aggregate reports sent here
- `ruf=mailto:dmarc@nwpcode.org` - Forensic reports sent here
- `adkim=r` - Relaxed DKIM alignment
- `aspf=r` - Relaxed SPF alignment
- `pct=100` - Apply to 100% of emails

**Phased Rollout:**
1. Start with `p=none` (monitoring only)
2. After 2 weeks, move to `p=quarantine`
3. After 4 weeks, move to `p=reject`

**Success Criteria:**
- [ ] DMARC record in DNS
- [ ] Receiving DMARC reports
- [ ] DMARC check passes at mail-tester.com

---

#### E05: Configure Reverse DNS (PTR Record)
**Priority:** HIGH | **Effort:** Low | **Dependencies:** Linode account

Reverse DNS maps IP addresses back to hostnames.

**Requirements:**
1. Forward DNS: `git.nwpcode.org` → `97.107.137.88`
2. Reverse DNS: `97.107.137.88` → `git.nwpcode.org`
3. These MUST match (FCrDNS)

**Configuration via Linode Cloud Manager:**
1. Go to Linodes → Select GitLab server
2. Navigate to Network tab
3. Find the IP address (97.107.137.88)
4. Click "Edit rDNS"
5. Enter: `git.nwpcode.org`
6. Save

**Verification:**
```bash
# Check reverse DNS
dig -x 97.107.137.88 +short

# Check forward DNS
dig git.nwpcode.org +short

# Both should match
```

**Postfix Hostname Configuration:**
```bash
# /etc/hostname
git.nwpcode.org

# /etc/postfix/main.cf
myhostname = git.nwpcode.org
```

**Success Criteria:**
- [ ] PTR record resolves to git.nwpcode.org
- [ ] A record resolves to 97.107.137.88
- [ ] Forward and reverse match (FCrDNS)
- [ ] HELO matches PTR record

---

### Phase 2: Virtual Mailbox System

#### E06: Install and Configure Dovecot
**Priority:** MEDIUM | **Effort:** Medium | **Dependencies:** E01

Dovecot provides IMAP access and authentication for virtual mailboxes.

**Installation:**
```bash
sudo apt install dovecot-core dovecot-imapd dovecot-lmtpd
```

**Configuration (`/etc/dovecot/conf.d/10-mail.conf`):**
```conf
mail_location = maildir:/var/mail/vhosts/%d/%n
mail_privileged_group = mail
```

**Authentication (`/etc/dovecot/conf.d/10-auth.conf`):**
```conf
disable_plaintext_auth = yes
auth_mechanisms = plain login
!include auth-passwdfile.conf.ext
```

**Passwd File (`/etc/dovecot/conf.d/auth-passwdfile.conf.ext`):**
```conf
passdb {
  driver = passwd-file
  args = scheme=SHA512-CRYPT /etc/dovecot/users
}
userdb {
  driver = static
  args = uid=vmail gid=vmail home=/var/mail/vhosts/%d/%n
}
```

**Create vmail user:**
```bash
sudo groupadd -g 5000 vmail
sudo useradd -g vmail -u 5000 vmail -d /var/mail/vhosts -m
sudo mkdir -p /var/mail/vhosts/nwpcode.org
sudo chown -R vmail:vmail /var/mail/vhosts
```

**Success Criteria:**
- [ ] Dovecot running
- [ ] IMAP accessible on port 993 (TLS)
- [ ] Can authenticate and check mailbox

---

#### E07: Virtual Mailbox Configuration
**Priority:** MEDIUM | **Effort:** Low | **Dependencies:** E06

Configure virtual mailboxes for per-site email addresses.

**Virtual Mailbox Map (`/etc/postfix/vmailbox`):**
```
# GitLab system emails
git@nwpcode.org          nwpcode.org/git/
postmaster@nwpcode.org   nwpcode.org/postmaster/
dmarc@nwpcode.org        nwpcode.org/dmarc/

# Per-site emails
nwp1@nwpcode.org         nwpcode.org/nwp1/
nwp2@nwpcode.org         nwpcode.org/nwp2/
contact@nwp1.nwpcode.org nwpcode.org/nwp1-contact/
```

**Virtual Alias Map (`/etc/postfix/virtual`):**
```
# Catch-all for subdomains (optional)
@nwp1.nwpcode.org        nwp1@nwpcode.org
@nwp2.nwpcode.org        nwp2@nwpcode.org

# Aliases
admin@nwpcode.org        postmaster@nwpcode.org
abuse@nwpcode.org        postmaster@nwpcode.org
```

**User Credentials (`/etc/dovecot/users`):**
```
git@nwpcode.org:{SHA512-CRYPT}$6$randomsalt$hashedpassword
nwp1@nwpcode.org:{SHA512-CRYPT}$6$randomsalt$hashedpassword
```

**Generate password hash:**
```bash
doveadm pw -s SHA512-CRYPT
```

**Activate maps:**
```bash
sudo postmap /etc/postfix/vmailbox
sudo postmap /etc/postfix/virtual
sudo systemctl reload postfix
```

**Success Criteria:**
- [ ] Virtual mailboxes created
- [ ] Can receive email to virtual addresses
- [ ] Can send email from virtual addresses

---

#### E08: MX Record Configuration
**Priority:** MEDIUM | **Effort:** Low | **Dependencies:** E01

Configure MX record for receiving email.

**DNS Record:**
```
Type: MX
Name: @
Value: git.nwpcode.org
Priority: 10
TTL: 300
```

**For subdomains (wildcard or specific):**
```
Type: MX
Name: *.nwpcode.org (or nwp1, nwp2, etc.)
Value: git.nwpcode.org
Priority: 10
TTL: 300
```

**Success Criteria:**
- [ ] MX record visible via `dig MX nwpcode.org`
- [ ] External servers can deliver to nwpcode.org

---

### Phase 3: Integration

#### E09: GitLab Email Configuration
**Priority:** HIGH | **Effort:** Low | **Dependencies:** E01-E05

Configure GitLab to use local Postfix for sending emails.

**GitLab Configuration (`/etc/gitlab/gitlab.rb`):**
```ruby
# Outgoing email settings
gitlab_rails['gitlab_email_enabled'] = true
gitlab_rails['gitlab_email_from'] = 'git@nwpcode.org'
gitlab_rails['gitlab_email_display_name'] = 'NWP GitLab'
gitlab_rails['gitlab_email_reply_to'] = 'noreply@nwpcode.org'

# SMTP settings (local Postfix)
gitlab_rails['smtp_enable'] = true
gitlab_rails['smtp_address'] = "localhost"
gitlab_rails['smtp_port'] = 25
gitlab_rails['smtp_domain'] = "nwpcode.org"
gitlab_rails['smtp_tls'] = false
gitlab_rails['smtp_openssl_verify_mode'] = 'none'
gitlab_rails['smtp_enable_starttls_auto'] = false

# Incoming email (reply by email)
gitlab_rails['incoming_email_enabled'] = true
gitlab_rails['incoming_email_address'] = "incoming+%{key}@nwpcode.org"
gitlab_rails['incoming_email_email'] = "incoming@nwpcode.org"
gitlab_rails['incoming_email_password'] = "secure_password_here"
gitlab_rails['incoming_email_host'] = "localhost"
gitlab_rails['incoming_email_port'] = 143
gitlab_rails['incoming_email_ssl'] = false
gitlab_rails['incoming_email_mailbox_name'] = "inbox"
```

**Apply configuration:**
```bash
sudo gitlab-ctl reconfigure
```

**Test email:**
```bash
sudo gitlab-rails console
# In console:
Notify.test_email('your@email.com', 'Test Subject', 'Test Body').deliver_now
```

**Success Criteria:**
- [ ] GitLab can send notification emails
- [ ] GitLab can receive reply-by-email
- [ ] Emails pass authentication checks

---

#### E10: Drupal Site Email Configuration
**Priority:** MEDIUM | **Effort:** Low | **Dependencies:** E01-E07

Enable Drupal sites to send/receive email via the NWP mail server.

**Site-Specific Email Address:**
Each site gets its own email identity:
- Site: `nwp1.nwpcode.org`
- Email: `nwp1@nwpcode.org` or `contact@nwp1.nwpcode.org`

**Drupal Configuration (settings.php or via UI):**
```php
// Use SMTP module for outgoing mail
$config['smtp.settings']['smtp_on'] = TRUE;
$config['smtp.settings']['smtp_host'] = 'git.nwpcode.org';
$config['smtp.settings']['smtp_port'] = '587';
$config['smtp.settings']['smtp_protocol'] = 'tls';
$config['smtp.settings']['smtp_username'] = 'nwp1@nwpcode.org';
$config['smtp.settings']['smtp_password'] = 'site_specific_password';
$config['smtp.settings']['smtp_from'] = 'nwp1@nwpcode.org';
$config['smtp.settings']['smtp_fromname'] = 'NWP1 Site';
```

**Required Drupal Modules:**
```bash
ddev composer require drupal/smtp
ddev drush en smtp -y
```

**Automation Script (`email/add_site_email.sh`):**
```bash
#!/bin/bash
# Add email account for a new site
SITE=$1
PASSWORD=$(openssl rand -base64 16)

# Add to virtual mailbox
echo "${SITE}@nwpcode.org  nwpcode.org/${SITE}/" >> /etc/postfix/vmailbox
sudo postmap /etc/postfix/vmailbox

# Add to Dovecot users
HASH=$(doveadm pw -s SHA512-CRYPT -p "$PASSWORD")
echo "${SITE}@nwpcode.org:${HASH}" >> /etc/dovecot/users

# Create maildir
sudo mkdir -p /var/mail/vhosts/nwpcode.org/${SITE}
sudo chown -R vmail:vmail /var/mail/vhosts/nwpcode.org/${SITE}

echo "Created email: ${SITE}@nwpcode.org"
echo "Password: $PASSWORD"
```

**Success Criteria:**
- [ ] Each site can send email with its own identity
- [ ] Emails are DKIM-signed
- [ ] Sites can receive email (contact forms, etc.)

---

### Phase 4: Monitoring and Maintenance

#### E11: Email Monitoring and Testing
**Priority:** MEDIUM | **Effort:** Low | **Dependencies:** E01-E10

Set up monitoring to ensure email deliverability.

**Testing Tools:**
1. **mail-tester.com** - Comprehensive spam score
2. **learndmarc.com** - DMARC validation
3. **mxtoolbox.com** - DNS and blacklist checks

**Automated Testing Script (`email/test_email.sh`):**
```bash
#!/bin/bash
# Test email configuration and deliverability

echo "=== Email Configuration Test ==="

# Check SPF
echo -n "SPF: "
dig TXT nwpcode.org +short | grep -q "v=spf1" && echo "OK" || echo "MISSING"

# Check DKIM
echo -n "DKIM: "
dig TXT default._domainkey.nwpcode.org +short | grep -q "v=DKIM1" && echo "OK" || echo "MISSING"

# Check DMARC
echo -n "DMARC: "
dig TXT _dmarc.nwpcode.org +short | grep -q "v=DMARC1" && echo "OK" || echo "MISSING"

# Check MX
echo -n "MX: "
dig MX nwpcode.org +short | grep -q "git.nwpcode.org" && echo "OK" || echo "MISSING"

# Check PTR
echo -n "PTR: "
dig -x 97.107.137.88 +short | grep -q "git.nwpcode.org" && echo "OK" || echo "MISSING"

# Check services
echo -n "Postfix: "
systemctl is-active postfix > /dev/null && echo "RUNNING" || echo "STOPPED"

echo -n "OpenDKIM: "
systemctl is-active opendkim > /dev/null && echo "RUNNING" || echo "STOPPED"

echo -n "Dovecot: "
systemctl is-active dovecot > /dev/null && echo "RUNNING" || echo "STOPPED"

# Check blacklists
echo ""
echo "=== Blacklist Check ==="
IP="97.107.137.88"
for bl in zen.spamhaus.org bl.spamcop.net b.barracudacentral.org; do
    result=$(dig +short ${IP//./-}.$bl)
    if [ -z "$result" ]; then
        echo "$bl: CLEAN"
    else
        echo "$bl: LISTED ($result)"
    fi
done
```

**Monitoring Cron Job:**
```bash
# /etc/cron.daily/email-monitor
#!/bin/bash
/home/gitlab/email/test_email.sh > /var/log/email-monitor.log 2>&1
grep -q "MISSING\|STOPPED\|LISTED" /var/log/email-monitor.log && \
  mail -s "Email Monitor Alert" admin@nwpcode.org < /var/log/email-monitor.log
```

**Success Criteria:**
- [ ] All tests pass
- [ ] Alerts sent on failures
- [ ] Regular mail-tester checks show 10/10

---

#### E12: DKIM Key Rotation
**Priority:** LOW | **Effort:** Low | **Dependencies:** E03

Rotate DKIM keys periodically for security.

**Key Rotation Script (`email/rotate_dkim.sh`):**
```bash
#!/bin/bash
# Rotate DKIM keys monthly

DOMAIN="nwpcode.org"
NEW_SELECTOR=$(date +%Y%m)
KEY_DIR="/etc/opendkim/keys/$DOMAIN"

# Generate new key
cd $KEY_DIR
sudo opendkim-genkey -s $NEW_SELECTOR -d $DOMAIN -b 2048
sudo chown opendkim:opendkim ${NEW_SELECTOR}.private

# Update KeyTable
sed -i "s/default._domainkey/${NEW_SELECTOR}._domainkey/g" /etc/opendkim/KeyTable
sed -i "s/default.private/${NEW_SELECTOR}.private/g" /etc/opendkim/KeyTable

# Update SigningTable
sed -i "s/default._domainkey/${NEW_SELECTOR}._domainkey/g" /etc/opendkim/SigningTable

# Show new DNS record
echo "Add this DNS record:"
cat ${NEW_SELECTOR}.txt

# Restart OpenDKIM
sudo systemctl restart opendkim

echo "DKIM key rotated to selector: $NEW_SELECTOR"
echo "Update DNS and wait for propagation before removing old key"
```

**Rotation Schedule:**
```bash
# /etc/cron.monthly/dkim-rotate
/home/gitlab/email/rotate_dkim.sh | mail -s "DKIM Key Rotation" admin@nwpcode.org
```

**Success Criteria:**
- [ ] New key generated monthly
- [ ] Old key retained for 48 hours after DNS update
- [ ] No email disruption during rotation

---

## Implementation Priority Matrix

| Proposal | Priority | Effort | Dependencies | Phase |
|----------|----------|--------|--------------|-------|
| E01 | HIGH | Medium | GitLab server | 1 |
| E02 | HIGH | Low | E01, Linode DNS | 1 |
| E03 | HIGH | Medium | E01 | 1 |
| E04 | HIGH | Low | E02, E03 | 1 |
| E05 | HIGH | Low | Linode | 1 |
| E06 | MEDIUM | Medium | E01 | 2 |
| E07 | MEDIUM | Low | E06 | 2 |
| E08 | MEDIUM | Low | E01 | 2 |
| E09 | HIGH | Low | E01-E05 | 3 |
| E10 | MEDIUM | Low | E01-E07 | 3 |
| E11 | MEDIUM | Low | E01-E10 | 4 |
| E12 | LOW | Low | E03 | 4 |

---

## Configuration Summary

### DNS Records Required

| Type | Name | Value | Purpose |
|------|------|-------|---------|
| A | git | 97.107.137.88 | Mail server |
| MX | @ | git.nwpcode.org (pri 10) | Mail routing |
| TXT | @ | v=spf1 ip4:97.107.137.88 a mx -all | SPF |
| TXT | default._domainkey | v=DKIM1; k=rsa; p=... | DKIM |
| TXT | _dmarc | v=DMARC1; p=quarantine; ... | DMARC |
| PTR | 97.107.137.88 | git.nwpcode.org | Reverse DNS |

### Ports Required

| Port | Protocol | Service | Direction |
|------|----------|---------|-----------|
| 25 | TCP | SMTP | Inbound (receive) |
| 587 | TCP | Submission | Inbound (send with auth) |
| 993 | TCP | IMAPS | Inbound (mailbox access) |

### Files Created/Modified

| File | Purpose |
|------|---------|
| /etc/postfix/main.cf | Postfix configuration |
| /etc/postfix/vmailbox | Virtual mailbox map |
| /etc/postfix/virtual | Virtual aliases |
| /etc/opendkim.conf | OpenDKIM configuration |
| /etc/opendkim/KeyTable | DKIM key mapping |
| /etc/opendkim/SigningTable | DKIM signing rules |
| /etc/opendkim/TrustedHosts | Trusted hosts list |
| /etc/dovecot/users | Virtual user credentials |
| /etc/gitlab/gitlab.rb | GitLab email settings |

---

## Success Metrics

### Phase 1 Complete When:
- [ ] Postfix sending email successfully
- [ ] SPF, DKIM, DMARC all configured
- [ ] PTR record matches hostname
- [ ] mail-tester.com score ≥ 9/10

### Phase 2 Complete When:
- [ ] Virtual mailboxes working
- [ ] Can receive email at custom addresses
- [ ] IMAP access working

### Phase 3 Complete When:
- [ ] GitLab notifications working
- [ ] Drupal sites can send email
- [ ] All emails pass authentication

### Phase 4 Complete When:
- [ ] Monitoring in place
- [ ] Alerts configured
- [ ] DKIM rotation automated
- [ ] mail-tester.com score = 10/10

---

## References

### Documentation
- [LinuxBabe - SPF and DKIM with Postfix](https://www.linuxbabe.com/mail-server/setting-up-dkim-and-spf)
- [Linode - Configure SPF and DKIM](https://www.linode.com/docs/guides/configure-spf-and-dkim-in-postfix-on-debian-9/)
- [Linode - Configure rDNS](https://www.linode.com/docs/products/compute/compute-instances/guides/configure-rdns/)
- [GitLab - Postfix Setup](https://docs.gitlab.com/administration/reply_by_email_postfix_setup/)
- [Postfix - Virtual Mailbox](http://www.postfix.org/VIRTUAL_README.html)
- [Dovecot - Postfix Integration](https://doc.dovecot.org/main/howto/virtual/postfix.html)

### Testing Tools
- [mail-tester.com](https://www.mail-tester.com/) - Spam score checker
- [learndmarc.com](https://www.learndmarc.com/) - DMARC validator
- [mxtoolbox.com](https://mxtoolbox.com/) - DNS and blacklist checks
- [dmarcian.com](https://dmarcian.com/domain-checker/) - DMARC domain checker

---

*Document created: December 31, 2025*
*Status: PROPOSAL - Awaiting implementation*
