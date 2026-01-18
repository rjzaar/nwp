# Multi-Coder DNS Delegation

**Status:** Implemented

## Overview

Enable independent coders to manage their own subdomains under nwpcode.org using NS delegation. Each coder gets full DNS autonomy over their subdomain while the main account retains control of the root domain.

## Implementation

The following files implement this feature:

| File | Purpose |
|------|---------|
| `coder-setup.sh` | Main script to add/remove/list coders |
| `lib/cloudflare.sh` | NS record API functions |
| `example.nwp.yml` | Configuration template with `other_coders` section |
| `docs/CODER_ONBOARDING.md` | Comprehensive guide for new coders |

## Architecture

```
nwpcode.org (Main Account - Cloudflare/Linode DNS)
│
├── git.nwpcode.org          → Main GitLab
├── nwp.nwpcode.org          → Main NWP site
│
└── coder2.nwpcode.org       → NS delegation to coder2's nameservers
    ├── git.coder2.nwpcode.org   → Coder2's GitLab
    ├── nwp.coder2.nwpcode.org   → Coder2's NWP site
    └── *.coder2.nwpcode.org     → Coder2 controls all subdomains
```

## Setup Steps

### Step 1: Main Account Creates NS Delegation

The nwpcode.org DNS administrator adds NS records pointing the subdomain to Linode's nameservers:

```
coder2.nwpcode.org    NS    ns1.linode.com
coder2.nwpcode.org    NS    ns2.linode.com
coder2.nwpcode.org    NS    ns3.linode.com
coder2.nwpcode.org    NS    ns4.linode.com
coder2.nwpcode.org    NS    ns5.linode.com
```

**If using Cloudflare CLI:**
```bash
# Add NS records (repeat for ns1-ns5)
cloudflare dns create nwpcode.org --type NS --name coder2 --content ns1.linode.com
cloudflare dns create nwpcode.org --type NS --name coder2 --content ns2.linode.com
cloudflare dns create nwpcode.org --type NS --name coder2 --content ns3.linode.com
cloudflare dns create nwpcode.org --type NS --name coder2 --content ns4.linode.com
cloudflare dns create nwpcode.org --type NS --name coder2 --content ns5.linode.com
```

**If using Linode CLI:**
```bash
# Get domain ID first
linode-cli domains list

# Add NS records
linode-cli domains records-create [DOMAIN_ID] \
  --type NS --name coder2 --target ns1.linode.com
# ... repeat for ns2-ns5
```

### Step 2: Coder2 Creates Linode Account

1. Sign up at https://www.linode.com/
2. Generate API token: Account → API Tokens → Create Token
   - Label: `nwp-dns`
   - Expiry: As desired
   - Permissions: Domains (Read/Write), Linodes (Read/Write)
3. Save token securely

### Step 3: Coder2 Creates DNS Zone

**Via Linode Dashboard:**
1. Go to Domains → Create Domain
2. Domain: `coder2.nwpcode.org`
3. SOA Email: coder2's email
4. Insert Default Records: No (or select a Linode if desired)

**Via Linode CLI:**
```bash
linode-cli domains create \
  --domain coder2.nwpcode.org \
  --type master \
  --soa_email coder2@example.com
```

### Step 4: Coder2 Creates DNS Records

Once the zone exists, coder2 uses their API token to create records:

```bash
# Get the domain ID
DOMAIN_ID=$(linode-cli domains list --json | jq -r '.[] | select(.domain=="coder2.nwpcode.org") | .id')

# Create A record for main subdomain
linode-cli domains records-create $DOMAIN_ID \
  --type A --name "" --target [CODER2_SERVER_IP]

# Create A record for git
linode-cli domains records-create $DOMAIN_ID \
  --type A --name git --target [CODER2_SERVER_IP]

# Create wildcard for all sites
linode-cli domains records-create $DOMAIN_ID \
  --type A --name "*" --target [CODER2_SERVER_IP]
```

### Step 5: Coder2 Sets Up Server

Coder2 creates their Linode server and configures:

1. **GitLab** at git.coder2.nwpcode.org
2. **NWP sites** at *.coder2.nwpcode.org
3. **SSL certificates** via Let's Encrypt (works automatically with DNS delegation)

## Verification

### Test NS Delegation (after Step 1)
```bash
dig NS coder2.nwpcode.org
# Should return ns1-ns5.linode.com
```

### Test A Records (after Step 4)
```bash
dig A coder2.nwpcode.org
dig A git.coder2.nwpcode.org
# Should return coder2's server IP
```

## Timeline

| Step | Who | Action |
|------|-----|--------|
| 1 | Main Admin | Create NS delegation records |
| 2 | Coder2 | Create Linode account, get API token |
| 3 | Coder2 | Create DNS zone for subdomain |
| 4 | Coder2 | Create Linode server |
| 5 | Coder2 | Add DNS records pointing to server |
| 6 | Coder2 | Install GitLab, configure NWP |

## NWP Configuration for Coder2

Coder2's `.secrets.yml` would contain their own credentials:

```yaml
linode:
  api_token: "coder2_linode_token_here"

# No cloudflare needed - DNS managed via Linode
```

Coder2's `nwp.yml` would use their subdomain:

```yaml
settings:
  domain_suffix: "coder2.nwpcode.org"
  gitlab_host: "git.coder2.nwpcode.org"

sites:
  nwp:
    domain: "nwp.coder2.nwpcode.org"
    # ...
```

## Security Considerations

- Each coder has isolated API tokens (no shared credentials)
- Main account only delegates DNS, cannot access coder2's servers
- Coder2 cannot modify parent domain records
- SSL certificates are independently managed per coder

## Future Coders

To add coder3, coder4, etc., repeat the same process:
1. Main admin adds NS records for `coderN.nwpcode.org`
2. CoderN sets up their Linode account and DNS zone

## Questions to Resolve

1. **Naming convention:** `coder2` or use actual names/handles?
2. **DNS propagation:** Allow 24-48 hours for NS delegation to propagate globally
3. **Backup DNS:** Should coders use secondary DNS providers?
4. **Documentation:** Create onboarding guide for new coders?
