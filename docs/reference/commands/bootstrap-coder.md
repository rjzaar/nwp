# bootstrap-coder

**Last Updated:** 2026-01-14

Automatically configure a new coder's NWP installation with identity detection, validation, and infrastructure verification.

## Synopsis

```bash
pl bootstrap-coder [OPTIONS]
```

## Description

Automates the onboarding process for new coders by detecting or prompting for coder identity, validating it against GitLab and DNS infrastructure, and configuring the NWP installation accordingly.

This script streamlines the coder onboarding workflow by:
1. Detecting coder identity via GitLab SSH or interactive prompt
2. Validating identity against GitLab user accounts and DNS delegation
3. Configuring `cnwp.yml` with coder's subdomain
4. Setting up git global configuration
5. Verifying SSH keys for GitLab access
6. Checking infrastructure readiness (DNS, GitLab, etc.)
7. Registering CLI command for system-wide access

This eliminates manual configuration steps and ensures consistent setup across all coder environments.

## Arguments

No positional arguments required. All configuration is done via options or interactively.

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `--coder NAME` | Use specified coder name (skip detection) | - |
| `--dry-run` | Show what would be done without making changes | false |
| `-h, --help` | Show help message and exit | - |

## Examples

### Interactive Mode (Recommended)

```bash
pl bootstrap-coder
```

Runs the full interactive bootstrap process with identity detection.

### With Known Identity

```bash
pl bootstrap-coder --coder john
```

Skips detection and uses "john" as the coder identity.

### Dry Run

```bash
pl bootstrap-coder --dry-run
```

Shows what would be configured without making any changes (useful for testing).

## Bootstrap Process

The script performs these steps:

### Step 1: Identity Detection

Attempts to automatically detect coder identity using multiple methods:

**Method 1: GitLab SSH Authentication**
- Tests SSH connection to `git.<base-domain>`
- GitLab responds with: "Welcome to GitLab, @username!"
- Extracts username from response
- Prompts for confirmation

**Method 2: DNS Reverse Lookup**
- Gets server's public IP
- Placeholder for future DNS-based detection
- (Currently returns to interactive prompt)

**Method 3: Interactive Prompt**
- Prompts user to enter coder name
- Validates format (must start with letter, alphanumeric/underscore/hyphen only)
- Confirms entry

### Step 2: Identity Validation

Validates the detected or entered identity:

**GitLab Account Check:**
- Tests SSH connection to GitLab
- Queries GitLab API for username
- Reports whether account exists

**DNS Delegation Check:**
- Queries NS records for `<coder>.<base-domain>`
- Verifies nameserver delegation is configured
- Reports delegation status

**DNS A Record Check:**
- Queries A records for `<coder>.<base-domain>`
- Verifies domain resolves to an IP
- Reports resolved IP address

**Warnings vs. Errors:**
- All validation checks are informational
- Warnings don't prevent bootstrap (infrastructure may be pending)
- User can choose to continue despite warnings

### Step 3: NWP Configuration

Configures `cnwp.yml` with coder identity:

**Existing Configuration:**
- If `cnwp.yml` exists, checks if it already has correct identity
- If identity matches, skips reconfiguration
- If different, prompts to overwrite (with backup)

**New Configuration:**
- Copies `example.cnwp.yml` to `cnwp.yml`
- Sets `settings.url` to `<coder>.<base-domain>`
- Sets `settings.email.domain` to `<coder>.<base-domain>`
- Sets `settings.email.admin_email` to `admin@<coder>.<base-domain>`
- Uses `yq` if available, falls back to `sed`

**Secrets File:**
- Creates `.secrets.yml` from `.secrets.example.yml` if missing
- Reminds user to add Linode API token

### Step 4: Git Configuration

Sets up git global configuration:

**Checks Existing Config:**
- Reads current `user.name` and `user.email`
- If configured, prompts to keep or overwrite

**Sets Git Config:**
- `git config --global user.name "<coder-name>"`
- `git config --global user.email "git@<coder>.<base-domain>"`

### Step 5: Infrastructure Verification

Verifies infrastructure is ready:

**DNS Status:**
- Shows NS delegation servers (if propagated)
- Shows A record and IP (if configured)
- Warns if not yet configured

**GitLab Status:**
- Tests HTTPS connectivity to GitLab
- Reports reachability

**SSH Keys:**
- Checks for `~/.ssh/id_ed25519.pub` (preferred)
- Checks for `~/.ssh/id_rsa.pub` (fallback)
- Offers to generate if missing
- Reminds to add key to GitLab

### Step 6: CLI Registration

Registers a system-wide CLI command:

**Command Selection:**
- Tries to register command named after coder (e.g., `john`)
- If name conflicts, finds alternative (e.g., `nwp`, `pl`)
- Requires sudo for registration in `/usr/local/bin/`

**What it does:**
- Creates symlink in `/usr/local/bin/` to project's `pl` script
- Updates `cnwp.yml` with `settings.cli_command`
- Allows running NWP commands from anywhere

**Fallback:**
- If sudo unavailable, skips registration
- User can still use `./pl` from NWP directory

### Step 7: Next Steps Display

Shows actionable next steps for completing onboarding:
1. Add Linode API token to `.secrets.yml`
2. Add SSH key to GitLab
3. Configure DNS A records in Linode
4. Test GitLab SSH access
5. Create first site

## Output

### Successful Bootstrap

```
================================================================================
NWP Coder Identity Bootstrap
================================================================================

This script will configure your NWP installation with your coder identity

Base domain: nwpcode.org

[1/7] Detecting Coder Identity

Attempting GitLab SSH authentication...
✓ Detected from GitLab SSH: john
Use identity 'john'? [y/N]: y

[2/7] Validating Identity: john

Checking GitLab account...
✓ GitLab account exists for 'john'

Checking NS delegation...
✓ NS delegation configured for john.nwpcode.org

Checking DNS A records...
✓ DNS A record configured: john.nwpcode.org -> 192.0.2.100

[3/7] Configuring NWP Installation

✓ Configured cnwp.yml with identity: john
  Domain: john.nwpcode.org
✓ Created .secrets.yml from example
⚠ You'll need to add your Linode API token to .secrets.yml

[4/7] Configuring Git

Git already configured as: John Doe <john@example.com>
Keep existing git configuration? [y/N]: n
✓ Configured git as: john <git@john.nwpcode.org>

[5/7] Infrastructure Verification

DNS Status:
  ✓ NS delegation: ns1.linode.com. ns2.linode.com.
  ✓ A record: john.nwpcode.org -> 192.0.2.100

GitLab Status:
  ✓ GitLab reachable: https://git.nwpcode.org

SSH Keys:
  ✓ ED25519 key exists: /home/john/.ssh/id_ed25519.pub
  ⚠ Make sure to add your public key to GitLab!
  GitLab SSH Keys: https://git.nwpcode.org/-/profile/keys

[6/7] Registering CLI Command

✓ Registered CLI command: john
ℹ Use 'john' to run NWP commands from anywhere

[7/7] Bootstrap Complete!

✓ Your NWP installation is configured as: john
ℹ Subdomain: john.nwpcode.org

================================================================================
Next Steps
================================================================================

1. Add Linode API Token
   Edit: .secrets.yml
   Get token: https://cloud.linode.com/profile/tokens
   Permissions needed: Domains (Read/Write), Linodes (Read/Write)

2. Add SSH Key to GitLab
   Go to: https://git.nwpcode.org/-/profile/keys
   Your public key:
   ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbCdEfGhIjKlMnOpQrStUvWxYz git@john.nwpcode.org

3. Configure DNS A Records in Linode
   Go to: https://cloud.linode.com/domains
   Domain: john.nwpcode.org
   Add A records:
     @ (root)     -> Your server IP
     git          -> Your server IP
     * (wildcard) -> Your server IP
   See: docs/guides/coder-onboarding.md Step 6

4. Test Your Setup
   SSH to GitLab: ssh -T git@git.nwpcode.org
   Should see: Welcome to GitLab, @john!

5. Create Your First Site
   john install d mysite
   Access: https://mysite.john.nwpcode.org

Documentation:
  Onboarding: docs/guides/coder-onboarding.md
  Commands:   docs/reference/commands/README.md
```

### Bootstrap with Warnings

```
[2/7] Validating Identity: john

Checking GitLab account...
✓ GitLab account exists for 'john'

Checking NS delegation...
⚠ NS delegation not found for john.nwpcode.org
⚠ Contact administrator to run: ./coder-setup.sh add john
ℹ DNS propagation can take 24-48 hours

Checking DNS A records...
⚠ DNS A records not configured
ℹ You'll need to add these in Linode DNS Manager
ℹ See: docs/guides/coder-onboarding.md Step 6

⚠ Identity validation completed with warnings
ℹ You can still proceed - warnings are informational only

Continue with bootstrap? [y/N]:
```

### Dry Run Output

```
================================================================================
NWP Coder Identity Bootstrap
================================================================================

⚠ DRY-RUN MODE: No changes will be made

[3/7] Configuring NWP Installation

[DRY-RUN] Would create cnwp.yml from example
[DRY-RUN] Would set settings.url to: john.nwpcode.org
[DRY-RUN] Would create .secrets.yml from example

[4/7] Configuring Git

[DRY-RUN] Would set git config:
  user.name: john
  user.email: git@john.nwpcode.org

[6/7] Registering CLI Command

[DRY-RUN] Would register CLI command: john

⚠ DRY-RUN completed - no changes were made
ℹ Run without --dry-run to apply configuration
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Bootstrap completed successfully |
| 1 | Coder identity could not be determined |
| 1 | User cancelled bootstrap |

## Prerequisites

### Required
- NWP project cloned to local machine
- `example.cnwp.yml` exists
- `bash` shell

### Recommended
- Active internet connection (for GitLab/DNS checks)
- `yq` installed (falls back to `sed` if missing)
- `dig` for DNS checks
- `curl` for HTTP checks
- `ssh` for GitLab authentication

### Administrator Prerequisites (Before Running)
Administrator must have:
1. Created coder account in GitLab
2. Run `./coder-setup.sh add <coder-name>` to configure DNS delegation
3. Communicated base domain to coder

## Configuration Files

### cnwp.yml

Updated with coder identity:

```yaml
settings:
  url: john.nwpcode.org
  email:
    domain: john.nwpcode.org
    admin_email: admin@john.nwpcode.org
  cli_command: john
```

### .gitconfig

Git global configuration set:

```ini
[user]
    name = john
    email = git@john.nwpcode.org
```

### /usr/local/bin/<command>

Symlink created (requires sudo):
```bash
/usr/local/bin/john -> /home/john/nwp/pl
```

## Identity Detection Methods

### GitLab SSH Detection

**How it works:**
```bash
ssh -T git@git.nwpcode.org
# Response: "Welcome to GitLab, @john!"
# Extracts: "john"
```

**Requirements:**
- SSH key already added to GitLab
- SSH access to GitLab configured
- Network connectivity to GitLab

**Success rate:** High if SSH keys are pre-configured

### DNS Reverse Lookup

**How it works:**
```bash
# Get server public IP
curl ifconfig.me
# 192.0.2.100

# Look up which subdomain points to this IP
# (Would require querying all registered coders)
```

**Status:** Placeholder for future enhancement

**Success rate:** Not currently implemented

### Interactive Prompt

**How it works:**
- Prompts user directly: "Coder name:"
- Validates format
- User confirms

**Requirements:**
- User knows their coder name
- Coder name follows format rules

**Success rate:** 100% (always works)

## Troubleshooting

### GitLab SSH Detection Fails

**Symptom:**
```
Could not detect identity from GitLab SSH
(This is normal if you haven't added your SSH key yet)
```

**Solution:** This is expected if SSH keys aren't configured yet. The script will fall back to interactive prompt. Add SSH keys after bootstrap completes.

### Invalid Coder Name Format

**Symptom:**
```
Invalid coder name format
Must start with a letter and contain only alphanumeric, underscore, or hyphen
```

**Solution:** Coder names must:
- Start with a letter (a-z, A-Z)
- Contain only: letters, numbers, underscore, hyphen
- Examples: `john`, `jane-doe`, `bob_smith`, `alice123`

### cnwp.yml Already Configured

**Symptom:**
```
Existing cnwp.yml found
Overwrite with new configuration for 'john'? [y/N]:
```

**Solution:** Choose:
- `y` - Replace existing config (backs up to `cnwp.yml.backup.YYYYMMDD_HHMMSS`)
- `n` - Keep existing config (skip this step)

### GitLab Account Not Found

**Symptom:**
```
⚠ GitLab account not found for 'john'
You may need to:
  - Add your SSH key to GitLab
  - Contact administrator to verify your account was created
```

**Solution:**
1. Verify administrator created GitLab account
2. Check for typos in coder name
3. Contact administrator to confirm account creation
4. Continue bootstrap (you can add SSH key later)

### DNS Delegation Not Found

**Symptom:**
```
⚠ NS delegation not found for john.nwpcode.org
Contact administrator to run: ./coder-setup.sh add john
```

**Solution:**
1. Contact administrator to run delegation setup
2. Wait 24-48 hours for DNS propagation
3. Continue bootstrap (DNS will work once propagated)

### CLI Command Registration Failed

**Symptom:**
```
⚠ Could not register CLI command (requires sudo)
ℹ You can still use ./pl from the NWP directory
```

**Solution:**
- Run with sudo: `sudo ./scripts/commands/bootstrap-coder.sh`
- Or continue without CLI registration and use `./pl` from NWP directory

### SSH Key Doesn't Exist

**Symptom:**
```
⚠ No SSH key found
Generate SSH key pair now? [y/N]:
```

**Solution:** Choose:
- `y` - Script generates ED25519 key pair automatically
- `n` - Generate manually later: `ssh-keygen -t ed25519 -C "git@john.nwpcode.org"`

## Security Considerations

### SSH Key Generation
- Uses ED25519 algorithm (recommended modern standard)
- No passphrase by default (can add manually: `ssh-keygen -p`)
- Key comment set to `git@<coder>.<base-domain>`

### Git Configuration
- Email set to `git@<subdomain>` (not personal email)
- Name set to coder identity (not full name)
- Global configuration (affects all repositories)

### cnwp.yml Protection
- File is in `.gitignore` (never committed)
- Contains user-specific subdomain configuration
- Backed up before overwriting

### .secrets.yml
- Created from example template
- User must add API tokens manually
- Never committed to git (in `.gitignore`)

## Related Commands

- `./coder-setup.sh` - Administrator tool for registering coders
- `./setup-ssh.sh` - Manual SSH key generation
- CLI registration library: `/home/rob/nwp/lib/cli-register.sh`

## See Also

- [Coder Onboarding Guide](../../guides/coder-onboarding.md)
- [Coder Identity Bootstrap Proposal](../../proposals/CODER_IDENTITY_BOOTSTRAP.md)
- [CLI Registration System](../../decisions/cli-registration.md)
- GitLab SSH Keys: https://docs.gitlab.com/ee/user/ssh.html
