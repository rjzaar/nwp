# GitLab Repository Migration Guide

This guide documents the migration of NWP repositories from `administrator/*` to `nwp/*` namespace.

## Overview

**Target State:**
- `nwp/nwp` - NWP codebase (mirrors to GitHub `rjzaar/nwp`)
- `nwp/avc` - AV Commons profile (mirrors to GitHub `rjzaar/avc`)
- `backups/*` - Site backup repositories (unchanged)

## Phase 1: Manual GitLab Migration

These steps require GitLab admin access on git.nwpcode.org.

### 1.1 Create the `nwp` Group

1. Log in to GitLab as admin
2. Navigate to: **Menu → Admin → Groups → New group**
3. Configure:
   - Group name: `NWP`
   - Group path: `nwp`
   - Visibility: Private
   - Description: `NWP code repositories`
4. Click **Create group**

### 1.2 Transfer administrator/nwp → nwp/nwp

1. Navigate to: `https://git.nwpcode.org/administrator/nwp`
2. Go to: **Settings → General → Advanced**
3. Scroll to: **Transfer project**
4. Select namespace: `nwp`
5. Type project name to confirm
6. Click **Transfer project**

### 1.3 Create or Transfer nwp/avc

**If avc/avc exists:**
1. Navigate to: `https://git.nwpcode.org/avc/avc`
2. Go to: **Settings → General → Advanced**
3. Transfer to `nwp` namespace

**If creating fresh:**
1. Navigate to: `https://git.nwpcode.org/nwp`
2. Click **New project**
3. Project name: `avc`
4. Visibility: Private
5. Click **Create project**

## Phase 2: Configure GitHub Mirroring

### 2.1 Get GitLab SSH Key

```bash
ssh git-server "sudo -u git cat /var/opt/gitlab/.ssh/id_ed25519.pub"
```

### 2.2 Add Deploy Key to GitHub

For each repository (rjzaar/nwp, rjzaar/avc):

1. Go to repository settings on GitHub
2. Navigate to: **Settings → Deploy keys**
3. Click **Add deploy key**
4. Title: `GitLab Mirror (git.nwpcode.org)`
5. Paste the SSH public key
6. **Check "Allow write access"**
7. Click **Add key**

### 2.3 Configure Push Mirrors in GitLab

For nwp/nwp:
1. Navigate to: `https://git.nwpcode.org/nwp/nwp/-/settings/repository`
2. Expand: **Mirroring repositories**
3. Git repository URL: `ssh://git@github.com/rjzaar/nwp.git`
4. Mirror direction: **Push**
5. Check: **Only mirror protected branches** (or leave unchecked for all branches)
6. Click **Mirror repository**

Repeat for nwp/avc → rjzaar/avc.

## Phase 3: Update Local Remotes

After the GitLab migration, update your local clone:

```bash
cd /home/rob/nwp
git remote set-url origin git@git.nwpcode.org:nwp/nwp.git
git fetch origin
```

For AVC (if separate clone):
```bash
cd /path/to/avc
git remote set-url origin git@git.nwpcode.org:nwp/avc.git
git fetch origin
```

## Phase 4: Update nwp.yml

After implementing the code changes, update your local `nwp.yml`:

```yaml
# Update profile_source in recipes.avc section
avc:
  profile_source: git@git.nwpcode.org:nwp/avc.git  # Changed from avc/avc
```

## Verification Checklist

- [ ] `nwp` group exists on GitLab
- [ ] `nwp/nwp` project exists and accessible
- [ ] `nwp/avc` project exists and accessible
- [ ] Deploy keys added to GitHub repos with write access
- [ ] Push mirror configured for nwp/nwp → rjzaar/nwp
- [ ] Push mirror configured for nwp/avc → rjzaar/avc
- [ ] Test push from GitLab mirrors to GitHub
- [ ] Local git remotes updated
- [ ] `nwp.yml` profile_source paths updated

## Troubleshooting

### Mirror push failing

1. Verify deploy key has write access on GitHub
2. Check SSH key is in GitLab's known_hosts:
   ```bash
   ssh git-server "sudo -u git ssh-keyscan github.com >> /var/opt/gitlab/.ssh/known_hosts"
   ```
3. Test SSH connection:
   ```bash
   ssh git-server "sudo -u git ssh -T git@github.com"
   ```

### Permission denied on transfer

- Ensure you're logged in as GitLab admin
- The target group (`nwp`) must exist before transfer
- You must have Owner role in both source and target namespaces

### Old URLs still working

GitLab automatically redirects from old paths after transfer, but update your remotes anyway for clarity.

## New GitLab Server Setup

When setting up a new GitLab server, the `nwp` and `backups` groups are created automatically during provisioning via `git/gitlab_server_setup.sh`. No manual group creation is needed for new servers.
