# Admin Guide: Developer Onboarding

A quick reference guide for NWP administrators to onboard new developers to GitLab and grant repository access.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Understanding GitLab Groups](#understanding-gitlab-groups)
3. [Onboarding Workflow](#onboarding-workflow)
4. [SSH Key Management](#ssh-key-management)
5. [User Management](#user-management)
6. [Group Management](#group-management)
7. [Troubleshooting](#troubleshooting)
8. [API Reference](#api-reference)
9. [Batch Operations](#batch-operations)

---

## Quick Start

### What You Need

Before onboarding a developer, collect:
- Developer's **full name**
- Developer's **email address**
- Developer's **SSH public key** (optional - they can add later)
- Desired **username** (alphanumeric, starts with letter)
- Target **GitLab group** (default: nwp)

### DNS Provider Setup (One-Time)

NWP supports two DNS providers for automated NS delegation:

**Option 1: Cloudflare** (if you're already using it)
```yaml
# .secrets.yml
cloudflare:
  api_token: "your_token"
  zone_id: "your_zone_id"
```

**Option 2: Linode DNS** (simpler, all-in-one)
```yaml
# .secrets.yml
linode:
  api_token: "your_token"
```

**Requirements for Linode DNS:**
- Base domain (e.g., `nwpcode.org`) must exist in Linode DNS Manager
- Domain nameservers should point to Linode: `ns1-5.linode.com`

**Without either:** NS delegation will be skipped (configure manually)

### Basic Onboarding (3 Steps)

```bash
# 1. Create GitLab user and add to group
pl coder-setup add <username> \
  --email "user@example.com" \
  --fullname "First Last" \
  --gitlab-group nwp
# This automatically creates NS delegation if DNS provider is configured

# 2. (Optional) Add their SSH key
# See "SSH Key Management" section below

# 3. Send credentials to developer
# The command output includes username, password, and login URL
```

That's it! The developer can now:
- Log into GitLab at `https://git.nwpcode.org`
- Clone repositories from the assigned group
- Push code changes

---

## Understanding GitLab Groups

### Available Groups

Check current groups:
```bash
pl coder-setup gitlab-users
```

Or list groups directly:
```bash
PROJECT_ROOT=/home/rob/nwp bash -c '
source lib/git.sh
gitlab_url=$(get_gitlab_url)
token=$(get_gitlab_token)
curl -s --header "PRIVATE-TOKEN: $token" \
  "https://${gitlab_url}/api/v4/groups" | \
  python3 -m json.tool | grep -E "\"name\"|\"id\"|\"path\""
'
```

### Common Groups

| Group | Purpose | Typical Members |
|-------|---------|-----------------|
| **nwp** | Main NWP codebase and infrastructure | Core developers, contributors |
| **avc** | AVC-specific projects | AVC team members |
| **backups** | Backup repositories | Admin only (restricted) |

### Access Levels

When adding users to groups, specify access level:

| Level | Name | Permissions |
|-------|------|-------------|
| 10 | Guest | View only |
| 20 | Reporter | Pull, create issues |
| 30 | Developer | Push to branches, create MRs |
| 40 | Maintainer | Merge, manage access |
| 50 | Owner | Full control |

**Default:** Developer (30) - recommended for most contributors

---

## Onboarding Workflow

### Standard Developer Onboarding

**Step 1: Create Account**

```bash
# Standard onboarding (works with or without Cloudflare)
pl coder-setup add john \
  --email "john@example.com" \
  --fullname "John Smith" \
  --gitlab-group nwp

# If Cloudflare is configured in .secrets.yml:
#   → Creates NS delegation for john.nwpcode.org
#   → Creates GitLab user
#
# If Cloudflare is NOT configured:
#   → Skips DNS setup (warns user)
#   → Creates GitLab user
#   → User can configure DNS manually later
```

**Step 2: Add SSH Key (Optional)**

If developer provides SSH key upfront:

```bash
PROJECT_ROOT=/home/rob/nwp bash -c '
source lib/git.sh
gitlab_url=$(get_gitlab_url)
token=$(get_gitlab_token)

# Get user ID
user_id=$(curl -s --header "PRIVATE-TOKEN: $token" \
  "https://${gitlab_url}/api/v4/users?username=john" | \
  grep -o "\"id\":[0-9]*" | head -1 | grep -o "[0-9]*")

# Add SSH key
curl -s --header "PRIVATE-TOKEN: $token" \
  --header "Content-Type: application/json" \
  --data "{
    \"title\": \"john-laptop\",
    \"key\": \"ssh-ed25519 AAAA... john@laptop\"
  }" \
  "https://${gitlab_url}/api/v4/users/${user_id}/keys"
'
```

**Step 3: Send Welcome Email**

Email template:
```
Subject: NWP GitLab Access - Welcome!

Hi [Name],

Your NWP GitLab account has been created:

• Username: [username]
• Password: [temporary_password]
• Login: https://git.nwpcode.org
• Group: [group_name]

Next steps:
1. Log in and change your password
2. Add your SSH key (Settings → SSH Keys)
3. Clone repositories: git clone git@git.nwpcode.org:[group]/[repo].git

Documentation:
- Developer Guide: docs/DEVELOPER_LIFECYCLE_GUIDE.md
- Coder Onboarding: docs/CODER_ONBOARDING.md

Questions? Reply to this email.

Welcome aboard!
```

### Project-Specific Access

If developer only needs access to specific projects (not entire group):

```bash
# 1. Create user without group
pl coder-setup add alice --email "alice@example.com" --no-gitlab

# 2. Manually add to specific projects via GitLab UI:
# Settings → Members → Invite member → alice → Developer
```

---

## SSH Key Management

### Option 1: Developer Adds Their Own (Recommended)

After login, developer:
1. Goes to Profile → SSH Keys
2. Pastes their public key
3. Tests: `ssh -T git@git.nwpcode.org`

**Pros:** Developer controls their keys, more secure
**Cons:** Requires extra step

### Option 2: Admin Adds Key (Fast Onboarding)

When you have the developer's SSH key upfront:

```bash
# Quick script to add SSH key
./scripts/gitlab-add-ssh-key.sh <username> "ssh-ed25519 AAAA... user@host"
```

Create this helper script:

```bash
#!/bin/bash
# scripts/gitlab-add-ssh-key.sh

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/lib/git.sh"
source "$PROJECT_ROOT/lib/ui.sh"

username="$1"
ssh_key="$2"
key_title="${3:-${username}-key}"

if [[ -z "$username" || -z "$ssh_key" ]]; then
    print_error "Usage: $0 <username> <ssh_public_key> [key_title]"
    exit 1
fi

gitlab_url=$(get_gitlab_url)
token=$(get_gitlab_token)

# Get user ID
user_id=$(curl -s --header "PRIVATE-TOKEN: $token" \
    "https://${gitlab_url}/api/v4/users?username=${username}" | \
    grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')

if [[ -z "$user_id" ]]; then
    print_error "User not found: $username"
    exit 1
fi

# Add SSH key
result=$(curl -s --header "PRIVATE-TOKEN: $token" \
    --header "Content-Type: application/json" \
    --data "{
        \"title\": \"${key_title}\",
        \"key\": \"${ssh_key}\"
    }" \
    "https://${gitlab_url}/api/v4/users/${user_id}/keys")

if echo "$result" | grep -q '"id":[0-9]*'; then
    key_id=$(echo "$result" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
    print_status "OK" "SSH key added for $username (ID: $key_id)"
else
    print_error "Failed to add SSH key"
    echo "$result"
    exit 1
fi
```

**Pros:** Faster onboarding, developer ready immediately
**Cons:** Admin handles sensitive keys (use secure channel)

---

## User Management

### List All Users

```bash
# Simple list
pl coder-setup gitlab-users

# Detailed information
PROJECT_ROOT=/home/rob/nwp bash -c '
source lib/git.sh
gitlab_url=$(get_gitlab_url)
token=$(get_gitlab_token)
curl -s --header "PRIVATE-TOKEN: $token" \
  "https://${gitlab_url}/api/v4/users" | \
  python3 -m json.tool
'
```

### Check User's Group Memberships

```bash
PROJECT_ROOT=/home/rob/nwp bash -c '
source lib/git.sh
gitlab_url=$(get_gitlab_url)
token=$(get_gitlab_token)

# Get user ID first
username="john"
user_id=$(curl -s --header "PRIVATE-TOKEN: $token" \
  "https://${gitlab_url}/api/v4/users?username=${username}" | \
  grep -o "\"id\":[0-9]*" | head -1 | grep -o "[0-9]*")

# Get memberships
curl -s --header "PRIVATE-TOKEN: $token" \
  "https://${gitlab_url}/api/v4/users/${user_id}/memberships" | \
  python3 -m json.tool
'
```

### Change User Access Level

```bash
# Promote to Maintainer (40)
PROJECT_ROOT=/home/rob/nwp bash -c '
source lib/git.sh
gitlab_url=$(get_gitlab_url)
token=$(get_gitlab_token)

username="john"
group_name="nwp"

# Get IDs
user_id=$(curl -s --header "PRIVATE-TOKEN: $token" \
  "https://${gitlab_url}/api/v4/users?username=${username}" | \
  grep -o "\"id\":[0-9]*" | head -1 | grep -o "[0-9]*")

group_id=$(curl -s --header "PRIVATE-TOKEN: $token" \
  "https://${gitlab_url}/api/v4/groups?search=${group_name}" | \
  grep -o "\"id\":[0-9]*" | head -1 | grep -o "[0-9]*")

# Update access level
curl -s -X PUT --header "PRIVATE-TOKEN: $token" \
  --header "Content-Type: application/json" \
  --data "{\"access_level\": 40}" \
  "https://${gitlab_url}/api/v4/groups/${group_id}/members/${user_id}"
'
```

### Block/Unblock User

```bash
# Block user (revoke all access)
PROJECT_ROOT=/home/rob/nwp bash -c '
source lib/git.sh
gitlab_url=$(get_gitlab_url)
token=$(get_gitlab_token)

username="john"
user_id=$(curl -s --header "PRIVATE-TOKEN: $token" \
  "https://${gitlab_url}/api/v4/users?username=${username}" | \
  grep -o "\"id\":[0-9]*" | head -1 | grep -o "[0-9]*")

curl -s -X POST --header "PRIVATE-TOKEN: $token" \
  "https://${gitlab_url}/api/v4/users/${user_id}/block"
'

# Unblock user
curl -s -X POST --header "PRIVATE-TOKEN: $token" \
  "https://${gitlab_url}/api/v4/users/${user_id}/unblock"
```

### Remove User (Offboarding)

```bash
# Full offboarding (removes DNS, GitLab access, config)
pl coder-setup remove john

# Keep GitLab access, remove DNS only
pl coder-setup remove john --keep-gitlab

# Archive contribution history before removal
pl coder-setup remove john --archive
```

---

## Group Management

### Create New Group

```bash
PROJECT_ROOT=/home/rob/nwp bash -c '
source lib/git.sh
gitlab_url=$(get_gitlab_url)
token=$(get_gitlab_token)

curl -s --header "PRIVATE-TOKEN: $token" \
  --header "Content-Type: application/json" \
  --data "{
    \"name\": \"Developers\",
    \"path\": \"developers\",
    \"description\": \"General development team\",
    \"visibility\": \"private\"
  }" \
  "https://${gitlab_url}/api/v4/groups"
'
```

### List Group Members

```bash
PROJECT_ROOT=/home/rob/nwp bash -c '
source lib/git.sh
gitlab_url=$(get_gitlab_url)
token=$(get_gitlab_token)

group_name="nwp"
group_id=$(curl -s --header "PRIVATE-TOKEN: $token" \
  "https://${gitlab_url}/api/v4/groups?search=${group_name}" | \
  grep -o "\"id\":[0-9]*" | head -1 | grep -o "[0-9]*")

curl -s --header "PRIVATE-TOKEN: $token" \
  "https://${gitlab_url}/api/v4/groups/${group_id}/members" | \
  python3 -m json.tool
'
```

### Add User to Additional Group

```bash
PROJECT_ROOT=/home/rob/nwp bash -c '
source lib/ui.sh
source lib/git.sh
gitlab_add_user_to_group john avc 30  # Developer access
'
```

### Remove User from Group

```bash
PROJECT_ROOT=/home/rob/nwp bash -c '
source lib/git.sh
gitlab_url=$(get_gitlab_url)
token=$(get_gitlab_token)

username="john"
group_name="avc"

# Get IDs
user_id=$(curl -s --header "PRIVATE-TOKEN: $token" \
  "https://${gitlab_url}/api/v4/users?username=${username}" | \
  grep -o "\"id\":[0-9]*" | head -1 | grep -o "[0-9]*")

group_id=$(curl -s --header "PRIVATE-TOKEN: $token" \
  "https://${gitlab_url}/api/v4/groups?search=${group_name}" | \
  grep -o "\"id\":[0-9]*" | head -1 | grep -o "[0-9]*")

# Remove from group
curl -s -X DELETE --header "PRIVATE-TOKEN: $token" \
  "https://${gitlab_url}/api/v4/groups/${group_id}/members/${user_id}"
'
```

---

## Troubleshooting

### "Group not found: developers"

**Problem:** Tried to add user to non-existent group

**Solution:**
```bash
# List available groups
pl coder-setup gitlab-users

# Or create the group first (see Group Management)

# Then add user to existing group
pl coder-setup add john --email "john@example.com" --gitlab-group nwp
```

### "Member already exists"

**Problem:** User already in group

**Solution:** This is fine - user already has access. Verify:
```bash
PROJECT_ROOT=/home/rob/nwp bash -c '
source lib/git.sh
gitlab_url=$(get_gitlab_url)
token=$(get_gitlab_token)
group_id=9  # nwp group ID

curl -s --header "PRIVATE-TOKEN: $token" \
  "https://${gitlab_url}/api/v4/groups/${group_id}/members" | \
  grep -A5 "\"username\":\"john\""
'
```

### User Can't Push to Repository

**Checklist:**
1. Verify user is in correct group: `pl coder-setup gitlab-users`
2. Check access level (should be ≥30 for push)
3. Verify SSH key: User runs `ssh -T git@git.nwpcode.org`
4. Check branch protection rules (may prevent direct push to main)

**Fix:**
```bash
# Promote to Developer if needed
# See "Change User Access Level" above
```

### GitLab API Authentication Failed

**Problem:** Can't run API commands

**Solution:** Check `.secrets.yml`:
```yaml
gitlab:
  api_token: "glpat-..."  # Must start with glpat-
```

Regenerate token:
1. Login to GitLab as admin
2. User Settings → Access Tokens
3. Create token with `api` scope
4. Update `.secrets.yml`

### SSH Key Rejected

**Problem:** "Permission denied (publickey)"

**Checklist:**
1. Key format: Must be `ssh-ed25519` or `ssh-rsa` + full key + comment
2. Key added to GitLab: Check user's SSH Keys settings
3. Test connection: `ssh -Tv git@git.nwpcode.org`

**Add key manually:**
```bash
# Via UI: GitLab → Profile → SSH Keys
# Or via API (see SSH Key Management)
```

---

## API Reference

### Quick API Snippets

All snippets require:
```bash
PROJECT_ROOT=/home/rob/nwp
source lib/git.sh
gitlab_url=$(get_gitlab_url)
token=$(get_gitlab_token)
```

#### Get User ID
```bash
username="john"
user_id=$(curl -s --header "PRIVATE-TOKEN: $token" \
  "https://${gitlab_url}/api/v4/users?username=${username}" | \
  grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
echo "User ID: $user_id"
```

#### Get Group ID
```bash
group_name="nwp"
group_id=$(curl -s --header "PRIVATE-TOKEN: $token" \
  "https://${gitlab_url}/api/v4/groups?search=${group_name}" | \
  grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
echo "Group ID: $group_id"
```

#### List User's SSH Keys
```bash
curl -s --header "PRIVATE-TOKEN: $token" \
  "https://${gitlab_url}/api/v4/users/${user_id}/keys" | \
  python3 -m json.tool
```

#### Create User
```bash
curl -s --header "PRIVATE-TOKEN: $token" \
  --header "Content-Type: application/json" \
  --data "{
    \"username\": \"newuser\",
    \"email\": \"new@example.com\",
    \"name\": \"New User\",
    \"password\": \"TempPassword123!\",
    \"reset_password\": true
  }" \
  "https://${gitlab_url}/api/v4/users"
```

### Complete API Documentation

GitLab API docs: `https://git.nwpcode.org/help/api/index.md`

Key endpoints:
- Users: `/api/v4/users`
- Groups: `/api/v4/groups`
- Projects: `/api/v4/projects`
- SSH Keys: `/api/v4/users/:id/keys`
- Group Members: `/api/v4/groups/:id/members`

---

## Batch Operations

### Onboard Multiple Developers

Create CSV file `developers.csv`:
```csv
username,email,fullname,group,ssh_key
john,john@example.com,John Smith,nwp,ssh-ed25519 AAAA...
jane,jane@example.com,Jane Doe,nwp,ssh-ed25519 AAAA...
bob,bob@example.com,Bob Johnson,avc,ssh-ed25519 AAAA...
```

Batch script:
```bash
#!/bin/bash
# scripts/batch-onboard.sh

while IFS=',' read -r username email fullname group ssh_key; do
    # Skip header
    [[ "$username" == "username" ]] && continue

    echo "Onboarding: $username ($email)"

    # Add user
    pl coder-setup add "$username" \
        --email "$email" \
        --fullname "$fullname" \
        --gitlab-group "$group"

    # Add SSH key if provided
    if [[ -n "$ssh_key" && "$ssh_key" != "ssh_key" ]]; then
        ./scripts/gitlab-add-ssh-key.sh "$username" "$ssh_key"
    fi

    echo "---"
done < developers.csv

echo "Batch onboarding complete!"
```

### Bulk Access Level Change

Promote all nwp group Developers to Maintainers:
```bash
#!/bin/bash
PROJECT_ROOT=/home/rob/nwp
source "$PROJECT_ROOT/lib/git.sh"

gitlab_url=$(get_gitlab_url)
token=$(get_gitlab_token)
group_id=9  # nwp group

# Get all members
members=$(curl -s --header "PRIVATE-TOKEN: $token" \
    "https://${gitlab_url}/api/v4/groups/${group_id}/members")

# Filter Developer (30) and promote to Maintainer (40)
echo "$members" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for member in data:
    if member['access_level'] == 30:
        print(member['id'])
" | while read user_id; do
    curl -s -X PUT --header "PRIVATE-TOKEN: $token" \
        --header "Content-Type: application/json" \
        --data '{"access_level": 40}' \
        "https://${gitlab_url}/api/v4/groups/${group_id}/members/${user_id}"
    echo "Promoted user ID: $user_id"
done
```

---

## Security Best Practices

### 1. SSH Key Management
- ✅ Require SSH keys for all developers (disable password auth)
- ✅ Use ED25519 keys (more secure than RSA)
- ✅ Verify key fingerprints before adding
- ❌ Never share private keys

### 2. Access Control
- ✅ Use principle of least privilege
- ✅ Start with Developer (30), promote as needed
- ✅ Regular access reviews (quarterly)
- ✅ Remove access immediately when developer leaves

### 3. API Token Security
- ✅ Store in `.secrets.yml` (never commit)
- ✅ Use scoped tokens (minimal permissions)
- ✅ Rotate tokens periodically (every 6 months)
- ✅ Audit token usage in GitLab admin panel

### 4. Password Policy
- ✅ Force password change on first login
- ✅ Require strong passwords (min 12 chars)
- ✅ Enable 2FA for maintainers/owners
- ❌ Never share passwords over unencrypted channels

---

## Automation Tips

### Slack/Email Notifications

Integrate with `coder-setup` to auto-notify:
```bash
# After successful onboarding
if pl coder-setup add "$username" --email "$email" --gitlab-group nwp; then
    # Send Slack notification
    curl -X POST -H 'Content-type: application/json' \
        --data "{\"text\":\"New developer onboarded: $username\"}" \
        $SLACK_WEBHOOK_URL
fi
```

### Pre-onboarding Checklist

Add to your workflow:
```bash
#!/bin/bash
# scripts/pre-onboard-check.sh

username="$1"
email="$2"

echo "Pre-onboarding checklist for: $username"
echo "=================================="

# Check username format
if [[ ! "$username" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
    echo "❌ Invalid username format"
    exit 1
fi
echo "✅ Username format valid"

# Check if user already exists
if pl coder-setup gitlab-users | grep -q "^$username "; then
    echo "❌ User already exists"
    exit 1
fi
echo "✅ Username available"

# Check email format
if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    echo "❌ Invalid email format"
    exit 1
fi
echo "✅ Email format valid"

echo "=================================="
echo "✅ Pre-onboarding checks passed"
echo "Ready to onboard: pl coder-setup add $username --email $email"
```

---

## Related Documentation

- [CODER_ONBOARDING.md](CODER_ONBOARDING.md) - User-facing onboarding guide
- [DEVELOPER_LIFECYCLE_GUIDE.md](DEVELOPER_LIFECYCLE_GUIDE.md) - Developer workflow
- [DATA_SECURITY_BEST_PRACTICES.md](DATA_SECURITY_BEST_PRACTICES.md) - Security architecture
- [GITLAB_COMPOSER.md](GITLAB_COMPOSER.md) - GitLab package registry

---

## Quick Decision Tree

**Need to onboard a developer?**

```
Do you have their SSH key?
├─ Yes → Use Option 2 (fast onboarding with SSH key)
└─ No  → Use Option 1 (they add SSH key after login)

Which group?
├─ Core contributor → nwp
├─ AVC team        → avc
└─ Project-specific → Create project-specific access

What access level?
├─ New contributor  → Developer (30)
├─ Trusted member   → Maintainer (40)
└─ Team lead        → Owner (50)

Need DNS subdomain?
├─ Yes, automate → Configure Cloudflare OR Linode in .secrets.yml
├─ Yes, manual   → Skip DNS provider config (configure manually later)
└─ No            → GitLab-only onboarding (no DNS needed)

Which DNS provider?
├─ Already using Cloudflare → Keep Cloudflare
├─ Using Linode for servers  → Use Linode DNS (simpler)
└─ Neither configured        → Manual DNS or add later
```

---

## Switching from Cloudflare to Linode DNS

If you want to simplify your stack by using Linode for both servers and DNS:

### Step 1: Create Domain in Linode

```bash
# Via Linode CLI
linode-cli domains create \
  --domain nwpcode.org \
  --type master \
  --soa_email admin@nwpcode.org

# Or via Linode Dashboard: https://cloud.linode.com/domains
```

### Step 2: Migrate Existing NS Delegations

If you already have coders with Cloudflare NS delegation:

```bash
# List current NS records for each coder
pl coder-setup list

# For each coder, you'll need to:
# 1. Create NS records in Linode manually or
# 2. Remove and re-add the coder (recreates NS delegation)
```

### Step 3: Update Nameservers at Registrar

Point your domain's nameservers to Linode:
```
ns1.linode.com
ns2.linode.com
ns3.linode.com
ns4.linode.com
ns5.linode.com
```

**Wait 24-48 hours** for DNS propagation.

### Step 4: Update .secrets.yml

Remove Cloudflare, keep only Linode:
```yaml
# .secrets.yml
linode:
  api_token: "your_linode_token"

# Remove or comment out:
# cloudflare:
#   api_token: "..."
#   zone_id: "..."
```

### Step 5: Test

```bash
# Verify Linode DNS is detected
pl coder-setup add testuser --dry-run --email "test@example.com"
# Should show: "Using Linode DNS"
```

---

## Changelog

| Date | Change |
|------|--------|
| 2026-01-09 | Added Linode DNS support as alternative to Cloudflare |
| 2026-01-08 | Initial version - covers GitLab user/group management |

---

**Questions?** Open an issue or contact the NWP administrator.
