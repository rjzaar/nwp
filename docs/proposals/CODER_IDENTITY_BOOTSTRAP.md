# Coder Identity Bootstrap System

**Status:** PROPOSAL
**Created:** 2026-01-13
**Problem:** New coders must manually configure their identity in `nwp.yml`, which is error-prone and confusing
**Solution:** Automated identity bootstrap with multiple validation methods

---

## Executive Summary

The current system requires new coders to manually edit `nwp.yml` and set `settings.url` to their subdomain. This is error-prone and creates a disconnect between:
- The admin's registration (running `coder-setup.sh add john`)
- The coder's local configuration (manually editing `settings.url: john.nwpcode.org`)

**Proposed Solution:** An interactive bootstrap script that:
1. Automatically detects or prompts for the coder's identity
2. Validates against GitLab authentication
3. Configures `nwp.yml` with correct settings
4. Sets up git config, SSH, and other identity-related settings
5. Verifies DNS and infrastructure readiness

---

## Current System Problems

### 1. **Manual Configuration is Error-Prone**
```yaml
# Coder must manually edit this correctly:
settings:
  url: john.nwpcode.org  # Could misspell, forget, or misunderstand
```

### 2. **No Identity Validation**
- No verification that "john" is actually registered
- No check that DNS delegation exists
- No connection to GitLab account

### 3. **Unix Username Doesn't Matter**
- The Unix user can be `root`, `ubuntu`, `john`, or anything
- System doesn't use Unix username for identity
- Creates confusion about "who am I?"

### 4. **Multi-Step Manual Process**
From `docs/guides/coder-onboarding.md:243-258`, coder must:
1. Clone NWP
2. Copy `example.nwp.yml` to `nwp.yml`
3. Manually edit `settings.url`
4. Copy `.secrets.example.yml` to `.secrets.yml`
5. Add Linode token
6. Hope everything is spelled correctly

### 5. **No Automated Verification**
- No check that identity matches registration
- No validation that subdomain DNS works
- No confirmation that GitLab account exists

---

## Proposed Solution: Identity Bootstrap System

### Overview

A three-tiered identity detection system with automatic configuration:

```
┌──────────────────────────────────────────────────────────────┐
│                  IDENTITY BOOTSTRAP FLOW                     │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  1. DETECT (Auto)         2. VALIDATE          3. CONFIGURE │
│  ─────────────────        ────────────         ───────────  │
│  • GitLab SSH test        • GitLab API         • nwp.yml   │
│  • DNS reverse lookup     • Check registered   • git config │
│  • Interactive prompt     • Verify DNS exists  • SSH keys   │
│                                                              │
│  FALLBACK: Ask user       FALLBACK: Warn       FALLBACK:    │
│                           but continue         Manual        │
└──────────────────────────────────────────────────────────────┘
```

### Design Principles

1. **Automatic where possible** - Detect identity without asking
2. **Interactive when needed** - Clear prompts with validation
3. **Fail-safe** - Warn on issues but don't block
4. **Single command** - One bootstrap script does everything
5. **Idempotent** - Safe to run multiple times
6. **Transparent** - Show what's being detected/configured

---

## Implementation

### New Script: `scripts/commands/bootstrap-coder.sh`

#### Usage
```bash
# Fresh clone - interactive mode
cd /root/nwp
./scripts/commands/bootstrap-coder.sh

# With pre-known identity
./scripts/commands/bootstrap-coder.sh --coder john

# With onboarding token (future enhancement)
./scripts/commands/bootstrap-coder.sh --token john:abc123xyz
```

#### Bootstrap Flow

```bash
#!/bin/bash

################################################################################
# NWP Coder Identity Bootstrap
#
# Automatically configures a new coder's NWP installation with:
#   - Coder identity detection and validation
#   - nwp.yml configuration from example
#   - Git user configuration
#   - SSH key setup for GitLab
#   - DNS and infrastructure verification
#
# Usage:
#   ./bootstrap-coder.sh              # Interactive mode
#   ./bootstrap-coder.sh --coder john # With known identity
################################################################################

main() {
    print_header "NWP Coder Identity Bootstrap"

    # Step 1: Detect or prompt for identity
    local coder_name
    coder_name=$(detect_coder_identity "$@")

    if [ -z "$coder_name" ]; then
        fail "Could not determine coder identity"
    fi

    info "Coder identity: $coder_name"

    # Step 2: Validate identity
    validate_coder_identity "$coder_name"

    # Step 3: Configure NWP
    configure_nwp "$coder_name"

    # Step 4: Setup git
    setup_git_config "$coder_name"

    # Step 5: Verify infrastructure
    verify_infrastructure "$coder_name"

    # Step 6: Register CLI command
    register_cli_for_coder "$coder_name"

    print_success "Bootstrap complete! You are configured as: $coder_name"
    show_next_steps "$coder_name"
}

# Detect coder identity using multiple methods
detect_coder_identity() {
    local coder_name=""

    # Method 1: Check if --coder flag provided
    if [[ "$1" == "--coder" ]]; then
        coder_name="$2"
        info "Using provided identity: $coder_name"
        return 0
    fi

    # Method 2: Try GitLab SSH authentication
    info "Attempting GitLab SSH authentication..."
    coder_name=$(detect_from_gitlab_ssh)
    if [ -n "$coder_name" ]; then
        info "Detected from GitLab SSH: $coder_name"
        if confirm "Use identity '$coder_name'?"; then
            echo "$coder_name"
            return 0
        fi
    fi

    # Method 3: Try DNS reverse lookup
    info "Attempting DNS-based detection..."
    coder_name=$(detect_from_dns)
    if [ -n "$coder_name" ]; then
        info "Detected from DNS: $coder_name"
        if confirm "Use identity '$coder_name'?"; then
            echo "$coder_name"
            return 0
        fi
    fi

    # Method 4: Interactive prompt
    info "Please enter your registered coder name"
    info "(This should match the name the administrator registered)"
    echo ""
    read -p "Coder name: " coder_name

    # Validate format
    if [[ ! "$coder_name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        fail "Invalid coder name format (must start with letter, alphanumeric only)"
    fi

    echo "$coder_name"
}

# Detect coder from GitLab SSH (if they added their key already)
detect_from_gitlab_ssh() {
    local base_domain=$(get_base_domain_from_example)
    local gitlab_url="git.${base_domain}"

    # Test SSH connection
    local ssh_response
    ssh_response=$(ssh -T -o BatchMode=yes -o ConnectTimeout=5 \
        "git@${gitlab_url}" 2>&1 || true)

    # GitLab responds with: "Welcome to GitLab, @username!"
    if echo "$ssh_response" | grep -q "Welcome to GitLab"; then
        local username
        username=$(echo "$ssh_response" | grep -oP '@\K[a-zA-Z0-9_-]+' || true)
        echo "$username"
        return 0
    fi

    return 1
}

# Detect coder from DNS (which subdomain points to this server)
detect_from_dns() {
    local base_domain=$(get_base_domain_from_example)

    # Get this server's public IP
    local server_ip
    server_ip=$(curl -s ifconfig.me 2>/dev/null || \
                curl -s icanhazip.com 2>/dev/null || \
                curl -s ipecho.net/plain 2>/dev/null)

    if [ -z "$server_ip" ]; then
        return 1
    fi

    info "Server IP: $server_ip"

    # Check common coder patterns
    local potential_names=()

    # Try to find which subdomain resolves to this IP
    # This requires querying DNS for all registered coders or trying common names
    # For now, return empty (could be enhanced with admin API)

    return 1
}

# Validate coder identity against GitLab and admin registration
validate_coder_identity() {
    local coder_name="$1"
    local base_domain=$(get_base_domain_from_example)
    local gitlab_url="git.${base_domain}"
    local valid=true

    info "Validating identity: $coder_name"

    # Check 1: GitLab user exists
    info "  Checking GitLab account..."
    if check_gitlab_user_exists "$coder_name" "$gitlab_url"; then
        pass "GitLab account exists"
    else
        warn "GitLab account not found (you may need to add SSH key)"
        valid=false
    fi

    # Check 2: DNS delegation exists
    info "  Checking DNS delegation..."
    if check_ns_delegation "$coder_name" "$base_domain"; then
        pass "DNS delegation configured"
    else
        warn "NS delegation not found for ${coder_name}.${base_domain}"
        warn "Contact administrator to run: ./coder-setup.sh add $coder_name"
        valid=false
    fi

    # Check 3: DNS A records (if delegation exists)
    info "  Checking DNS A records..."
    if check_dns_a_record "$coder_name" "$base_domain"; then
        pass "DNS A records configured"
    else
        warn "DNS A records not configured (you'll need to set these up)"
        info "See: docs/guides/coder-onboarding.md Step 6"
    fi

    if ! $valid; then
        echo ""
        warn "Identity validation had warnings"
        if ! confirm "Continue anyway?"; then
            fail "Bootstrap cancelled"
        fi
    fi
}

# Configure nwp.yml with detected identity
configure_nwp() {
    local coder_name="$1"
    local base_domain=$(get_base_domain_from_example)

    info "Configuring NWP installation..."

    # Backup existing config if present
    if [ -f "nwp.yml" ]; then
        warn "Existing nwp.yml found"
        if ! confirm "Overwrite with new configuration?"; then
            info "Skipping nwp.yml configuration"
            return 0
        fi
        mv nwp.yml "nwp.yml.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    # Copy example and configure
    cp example.nwp.yml nwp.yml

    # Set identity in nwp.yml
    local subdomain="${coder_name}.${base_domain}"

    if command -v yq &>/dev/null; then
        yq -i ".settings.url = \"$subdomain\"" nwp.yml
        yq -i ".settings.email.domain = \"$subdomain\"" nwp.yml
        yq -i ".settings.email.admin_email = \"admin@${subdomain}\"" nwp.yml
    else
        # Fallback: sed
        sed -i "s/url: nwpcode.org/url: $subdomain/" nwp.yml
        sed -i "s/domain: nwpcode.org/domain: $subdomain/" nwp.yml
        sed -i "s/admin_email: admin@example.com/admin_email: admin@$subdomain/" nwp.yml
    fi

    pass "Configured nwp.yml with identity: $coder_name"

    # Setup .secrets.yml
    if [ ! -f ".secrets.yml" ]; then
        cp .secrets.example.yml .secrets.yml
        info "Created .secrets.yml from example"
        warn "You'll need to add your Linode API token to .secrets.yml"
    fi
}

# Setup git global config
setup_git_config() {
    local coder_name="$1"
    local subdomain="${coder_name}.$(get_base_domain_from_example)"

    info "Configuring git..."

    # Check if git user is already configured
    local current_name=$(git config --global user.name || echo "")
    local current_email=$(git config --global user.email || echo "")

    if [ -n "$current_name" ] && [ -n "$current_email" ]; then
        info "Git already configured as: $current_name <$current_email>"
        if ! confirm "Keep existing git configuration?"; then
            git config --global user.name "$coder_name"
            git config --global user.email "git@${subdomain}"
            pass "Updated git configuration"
        fi
    else
        git config --global user.name "$coder_name"
        git config --global user.email "git@${subdomain}"
        pass "Configured git as: $coder_name <git@${subdomain}>"
    fi
}

# Verify infrastructure readiness
verify_infrastructure() {
    local coder_name="$1"
    local base_domain=$(get_base_domain_from_example)
    local subdomain="${coder_name}.${base_domain}"

    print_header "Infrastructure Verification"

    # DNS checks
    info "DNS Status:"
    if dig NS "$subdomain" +short | grep -q linode.com; then
        pass "  NS delegation: OK"
    else
        warn "  NS delegation: Not propagated (may take 24-48 hours)"
    fi

    local server_ip=$(dig A "$subdomain" +short | head -1)
    if [ -n "$server_ip" ]; then
        pass "  A record: $subdomain -> $server_ip"
    else
        warn "  A record: Not configured (you'll need to add this)"
    fi

    # GitLab checks
    info "GitLab Status:"
    local gitlab_url="git.${base_domain}"
    if curl -sf "https://${gitlab_url}" >/dev/null 2>&1; then
        pass "  GitLab reachable: https://$gitlab_url"
    else
        warn "  GitLab not reachable: https://$gitlab_url"
    fi

    # SSH key check
    info "SSH Keys:"
    if [ -f "$HOME/.ssh/id_ed25519.pub" ] || [ -f "$HOME/.ssh/id_rsa.pub" ]; then
        pass "  SSH key pair exists"
        info "  Make sure to add your public key to GitLab!"
    else
        warn "  No SSH key found"
        if confirm "Generate SSH key pair?"; then
            ssh-keygen -t ed25519 -C "git@${subdomain}" -f "$HOME/.ssh/id_ed25519" -N ""
            pass "  Generated SSH key: $HOME/.ssh/id_ed25519"
            info "  Add this to GitLab: https://$gitlab_url/-/profile/keys"
            cat "$HOME/.ssh/id_ed25519.pub"
        fi
    fi
}

# Register CLI command for this NWP installation
register_cli_for_coder() {
    local coder_name="$1"

    info "Registering NWP CLI command..."

    # The coder's CLI should be named after them if possible
    local cli_command="$coder_name"

    # Check if that command is available
    if command -v "$cli_command" &>/dev/null; then
        # Fall back to pl, pl1, pl2, etc.
        cli_command=$(find_available_cli_command)
    fi

    if register_cli_command "$PROJECT_ROOT" "$cli_command"; then
        pass "Registered CLI command: $cli_command"
        info "Use '$cli_command' to run NWP commands from anywhere"
    else
        warn "Could not register CLI command (requires sudo)"
        info "You can use ./pl from this directory"
    fi
}

# Show next steps after bootstrap
show_next_steps() {
    local coder_name="$1"
    local base_domain=$(get_base_domain_from_example)
    local subdomain="${coder_name}.${base_domain}"

    print_header "Next Steps"

    echo "Your NWP installation is configured as: $coder_name"
    echo "Subdomain: $subdomain"
    echo ""
    echo "To complete setup:"
    echo ""
    echo "1. Add Linode API token to .secrets.yml"
    echo "   - Get token from: https://cloud.linode.com/profile/tokens"
    echo ""
    echo "2. Add SSH key to GitLab (if not done already)"
    echo "   - Go to: https://git.${base_domain}/-/profile/keys"
    echo "   - Add: $(cat $HOME/.ssh/id_ed25519.pub 2>/dev/null || echo 'Your SSH public key')"
    echo ""
    echo "3. Configure DNS A records in Linode"
    echo "   - Point $subdomain to your server IP"
    echo "   - See: docs/guides/coder-onboarding.md Step 6"
    echo ""
    echo "4. Create your first site"
    echo "   - Run: ./pl install d mysite"
    echo "   - Access: https://mysite.${subdomain}"
    echo ""
}

# Get base domain from example.nwp.yml
get_base_domain_from_example() {
    awk '/^settings:/,/^[a-z]/ {
        if ($1 == "url:" && $2 ~ /\./) {
            print $2
            exit
        }
    }' example.nwp.yml | tr -d '"' | head -1
}

# Check if GitLab user exists
check_gitlab_user_exists() {
    local username="$1"
    local gitlab_url="$2"

    # Try SSH test
    local ssh_response
    ssh_response=$(ssh -T -o BatchMode=yes -o ConnectTimeout=5 \
        "git@${gitlab_url}" 2>&1 || true)

    if echo "$ssh_response" | grep -q "Welcome to GitLab.*@${username}"; then
        return 0
    fi

    # Try HTTPS API (if accessible without auth)
    local api_response
    api_response=$(curl -sf "https://${gitlab_url}/api/v4/users?username=${username}" 2>/dev/null || echo "[]")

    if echo "$api_response" | grep -q "\"username\":\"${username}\""; then
        return 0
    fi

    return 1
}

# Check NS delegation
check_ns_delegation() {
    local name="$1"
    local base_domain="$2"
    local subdomain="${name}.${base_domain}"

    local ns=$(dig NS "$subdomain" +short +time=2 +tries=1 2>/dev/null | head -1)
    [ -n "$ns" ]
}

# Check DNS A record
check_dns_a_record() {
    local name="$1"
    local base_domain="$2"
    local subdomain="${name}.${base_domain}"

    local ip=$(dig A "$subdomain" +short +time=2 +tries=1 2>/dev/null | head -1)
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Simple confirmation prompt
confirm() {
    local prompt="$1"
    local response
    read -p "$prompt [y/N]: " response
    [[ "$response" =~ ^[yY]$ ]]
}

main "$@"
```

---

## Enhanced Features

### 1. GitLab SSH-Based Detection

When a coder adds their SSH key to GitLab and tests the connection:

```bash
$ ssh -T git@git.nwpcode.org
Welcome to GitLab, @john!
```

The bootstrap script can parse this response to automatically detect identity.

### 2. DNS Reverse Lookup

If the coder's server IP is already in DNS:

```bash
# Get server IP
server_ip=$(curl -s ifconfig.me)

# Check which subdomain points to this IP
# (Requires querying registered coders or pattern matching)
```

### 3. Onboarding Token (Future Enhancement)

Admin generates a signed token:

```bash
# Admin
./coder-setup.sh add john --generate-token

# Outputs:
Onboarding token: NWP_ONBOARD=john:1704067200:a8f3c9d1e2

# Coder
./bootstrap-coder.sh --token "john:1704067200:a8f3c9d1e2"
```

The token contains:
- Username
- Timestamp (expiry)
- HMAC signature (validates authenticity)

---

## Integration with Existing Scripts

### Update `coder-setup.sh`

Add option to generate onboarding instructions:

```bash
cmd_add() {
    # ... existing code ...

    # Generate onboarding command
    echo ""
    print_header "Onboarding Command"
    info "Send this command to $name:"
    echo ""
    echo "  git clone https://github.com/rjzaar/nwp.git"
    echo "  cd nwp"
    echo "  ./scripts/commands/bootstrap-coder.sh --coder $name"
    echo ""
    info "Or visit: https://git.${base_domain}/help/onboarding"
}
```

### Update `docs/guides/coder-onboarding.md`

Replace Steps 8-10 with:

```markdown
## Step 8: Bootstrap Your NWP Installation

SSH into your server and run the bootstrap script:

\`\`\`bash
cd /root/nwp
./scripts/commands/bootstrap-coder.sh
\`\`\`

The script will:
1. Detect your identity (if SSH key added to GitLab)
2. Validate your registration
3. Configure nwp.yml automatically
4. Setup git configuration
5. Verify DNS and infrastructure
6. Register CLI command

Follow the interactive prompts if identity cannot be auto-detected.
```

---

## Security Considerations

### SSH Key Verification

The GitLab SSH detection requires:
1. Coder has added their SSH key to GitLab
2. GitLab server is accessible
3. SSH connection succeeds

This provides strong authentication that the coder owns the identity.

### Token-Based Onboarding (Future)

Tokens should:
- Expire after 7 days
- Be single-use (mark as consumed)
- Include HMAC signature
- Not contain sensitive data

### Validation Warnings vs. Blocks

The script should:
- **Warn** if validation fails (don't block)
- **Explain** what's missing
- **Allow** proceeding with warnings
- **Log** bootstrap attempts for audit

---

## Testing Plan

### Test Scenarios

1. **Fresh coder with SSH key already added**
   - Should auto-detect from GitLab SSH
   - Should configure automatically
   - Should verify infrastructure

2. **Fresh coder without SSH key**
   - Should prompt for name
   - Should warn about SSH key
   - Should offer to generate key

3. **Coder with existing nwp.yml**
   - Should ask to backup/overwrite
   - Should preserve custom settings

4. **Invalid/unregistered coder name**
   - Should warn GitLab user not found
   - Should warn NS delegation not found
   - Should allow proceeding anyway

5. **Re-running bootstrap (idempotent)**
   - Should detect existing configuration
   - Should allow reconfiguration
   - Should not break anything

---

## Migration Path

### Phase 1: Create Bootstrap Script (v0.21)
- Implement `bootstrap-coder.sh`
- Add GitLab SSH detection
- Add interactive prompts
- Add validation checks

### Phase 2: Update Documentation (v0.21)
- Update `docs/guides/coder-onboarding.md`
- Add bootstrap examples
- Document troubleshooting

### Phase 3: Enhance Detection (v0.22)
- Add DNS reverse lookup
- Add token-based onboarding
- Add admin API for validation

### Phase 4: Full Automation (v0.23)
- One-command onboarding
- Admin dashboard integration
- Automated infrastructure provisioning

---

## Success Criteria

The system should:

1. ✅ **Reduce manual configuration errors** - No more misspelled subdomains
2. ✅ **Validate identity automatically** - Check against GitLab and DNS
3. ✅ **Single command setup** - `./bootstrap-coder.sh` does everything
4. ✅ **Clear feedback** - Show what's detected, what's missing, what to do
5. ✅ **Safe to re-run** - Idempotent, doesn't break existing config
6. ✅ **Comprehensive checks** - DNS, GitLab, SSH, infrastructure

---

## Open Questions

1. **Should we require SSH key before bootstrap?**
   - Pro: Strong authentication
   - Con: Extra step before starting

2. **Should we auto-provision Linode resources?**
   - Pro: Fully automated
   - Con: Requires Linode API token upfront

3. **How to handle coders on local machines (not servers)?**
   - DNS detection won't work
   - Need different flow?

4. **Should Unix username match coder name?**
   - Currently doesn't matter
   - Could enforce for consistency

---

## Related Work

- `scripts/commands/coder-setup.sh` - Admin adds coders
- `scripts/commands/coders.sh` - TUI for managing coders
- `docs/guides/coder-onboarding.md` - Onboarding documentation
- `lib/cli-register.sh` - CLI command registration
- `lib/git.sh` - GitLab API functions

---

## Conclusion

This proposal solves the identity configuration problem by:

1. **Automating detection** - Use GitLab SSH, DNS, or interactive prompts
2. **Validating against sources** - Check GitLab and DNS records
3. **Configuring automatically** - Set up nwp.yml, git, SSH correctly
4. **Providing clear feedback** - Show what's working, what needs attention
5. **Making it idempotent** - Safe to run multiple times

The bootstrap script bridges the gap between admin registration and coder setup, creating a seamless onboarding experience.
