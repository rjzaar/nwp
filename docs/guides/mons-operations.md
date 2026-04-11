# mons Operations Guide

> **Status:** ACTIVE (supersedes `mons-mayo-bootstrap.md` for production deploys)
> **F21 Phases:** 5 (mons bootstrap), 7 (signed artifacts), 8 (blue-green)
> **Last Updated:** 2026-04-10
>
> **Audience:** Rob, sitting at mons. Every command in this guide is
> something **you** type — Claude on dev cannot reach mons.

## What Changed Since the Bootstrap Guide

The bootstrap guide (`mons-mayo-bootstrap.md`) proved the trust path with
passphrase-protected SSH, HTTPS git pull, and rsync dry-run. This guide
replaces that with the production-grade pipeline:

| Bootstrap (old) | Operations (new) |
|-----------------|------------------|
| `git clone` from GitLab | Download **signed tarball** from GitLab Packages |
| No signature verification | **minisign** verification before any action |
| Public internet SSH | **WireGuard tunnel** (mons↔mayo1 only) |
| rsync dry-run | **Blue-green slot deploy** with atomic swap |
| Passphrase-only SSH key | Software ed25519 (Solo 2C+ ed25519-sk when available) |

## Prerequisites

Before your first production deploy, ensure:

- [ ] minisign installed: `sudo apt-get install -y minisign`
- [ ] WireGuard installed: `sudo apt-get install -y wireguard`
- [ ] NWP deploy public key at `~/.config/nwp-deploy.pub`
- [ ] mons-bot PAT at `~/.config/mayo-deploy.token` (chmod 600)
- [ ] SSH config entry for mayo1 (pointing to tunnel IP 10.99.0.2)
- [ ] WireGuard config at `/etc/wireguard/wg-mons.conf`
- [ ] `mons-say` installed (from bootstrap guide Step 7)
- [ ] Deploy scripts in `~/deploy-scripts/` (copied from NWP repo)

### One-Time Setup

**1. Install the NWP deploy public key:**

Get this from the dev session (it will read `~/nwp/keys/minisign/nwp-deploy.pub`):

```bash
mkdir -p ~/.config
cat > ~/.config/nwp-deploy.pub << 'EOF'
<paste the public key from dev>
EOF
chmod 644 ~/.config/nwp-deploy.pub
```

**2. Install the deploy token:**

Get the mons-bot PAT from the dev session:

```bash
umask 077
printf '%s\n' 'glpat-...' > ~/.config/mayo-deploy.token
chmod 600 ~/.config/mayo-deploy.token
```

**3. Install deploy scripts:**

```bash
mkdir -p ~/deploy-scripts
# Copy from NWP repo via USB or scp from dev
# Files needed:
#   mons-deploy.sh      — main deploy orchestrator
#   bluegreen-swap.sh   — slot swap (uploaded to mayo1 during deploy)
#   bluegreen-setup.sh  — one-time slot setup on mayo1
```

**4. Configure WireGuard:**

See `servers/mayo1/wireguard/README.md` for full setup. Summary:

```bash
# Generate mons keypair
wg genkey | sudo tee /etc/wireguard/mons-private.key | wg pubkey | sudo tee /etc/wireguard/mons-public.key
sudo chmod 600 /etc/wireguard/mons-private.key

# Install config (edit to insert real keys)
sudo cp wg-mons.conf.mons /etc/wireguard/wg-mons.conf
sudo vi /etc/wireguard/wg-mons.conf   # replace MONS_PRIVATE_KEY and MAYO1_PUBLIC_KEY
```

Exchange public keys with mayo1 out-of-band (USB stick, read aloud).

**5. First-time blue-green setup on mayo1:**

```bash
sudo wg-quick up wg-mons
scp ~/deploy-scripts/bluegreen-setup.sh mayo1:/tmp/
ssh mayo1 'sudo /tmp/bluegreen-setup.sh && rm /tmp/bluegreen-setup.sh'
```

This converts `/var/www/mayostudios.org` from a directory to a symlink
pointing to the `-blue` slot, with `-green` as the standby.

## Deploy Procedure

### Quick Reference

```bash
# 1. Bring mons online (phone hotspot)
# 2. Start tunnel
sudo wg-quick up wg-mons

# 3. Deploy (version comes from dev session)
~/deploy-scripts/mons-deploy.sh mayo <version>

# 4. Verify
ssh mayo1 'curl -sI http://127.0.0.1 -H "Host: mayostudios.org" | head -3'

# 5. Tear down tunnel
sudo wg-quick down wg-mons

# 6. Report
mons-say "deploy mayo <version> complete"
```

### Detailed Steps

#### Step 1: Bring Mons Online

Connect via phone hotspot or dedicated cellular modem. **Not** the home LAN,
**not** Headscale.

```bash
ip route get 1.1.1.1 | head -1         # verify internet
ping -c 2 git.nwpcode.org              # verify GitLab reachable
```

#### Step 2: Start WireGuard Tunnel

```bash
sudo wg-quick up wg-mons
ping -c 3 10.99.0.2                    # verify tunnel to mayo1
ssh -o ConnectTimeout=5 mayo1 hostname  # verify SSH over tunnel
```

#### Step 3: Run Deploy

The dev session will tell you the version string (e.g., `abc123-20260410-120000`):

```bash
~/deploy-scripts/mons-deploy.sh mayo <version>
```

What happens:
1. Downloads tarball + signature from GitLab Packages
2. Verifies minisign signature against `~/.config/nwp-deploy.pub`
3. Determines which slot (blue/green) is inactive
4. Uploads tarball to mayo1, extracts to inactive slot
5. Runs `drush updb` on the inactive slot
6. Atomic symlink swap (brief maintenance window)
7. Cache clear, smoke test
8. Auto-rollback if smoke test fails

#### Step 4: Verify

```bash
# From mons
ssh mayo1 'curl -sI http://127.0.0.1 -H "Host: mayostudios.org"' | head -5
ssh mayo1 'cd /var/www/mayostudios.org && sudo -u www-data ./vendor/bin/drush status --fields=drupal-version,install-profile'

# Also check from a browser on your phone: https://mayostudios.org
```

#### Step 5: Tear Down

```bash
sudo wg-quick down wg-mons
# Disconnect from internet
```

#### Step 6: Report

```bash
mons-say "deploy mayo <version> complete — smoke test passed"
# Or if something went wrong:
mons-say "deploy mayo <version> FAILED — rolled back, see below"
mons-say "<brief description of what happened>"
```

## Dry Run

To test the download and verification without deploying:

```bash
~/deploy-scripts/mons-deploy.sh mayo <version> --dry-run
```

This downloads the tarball, verifies the signature, then stops.

## Rollback

If a deploy goes wrong after the swap:

```bash
ssh mayo1 'sudo /var/www/bluegreen-swap.sh --site mayostudios.org --rollback -y'
```

This swaps back to the previous slot. The failed slot remains for investigation.

## Troubleshooting

**"minisign: Signature verification failed"**
The tarball was modified after signing, or the wrong public key is installed.
Do NOT deploy. Tell dev: `mons-say "signature verification failed for <version>"`.

**"WireGuard tunnel wg-mons is not up"**
Run `sudo wg-quick up wg-mons`. If it fails, check `/etc/wireguard/wg-mons.conf`.

**"Cannot SSH to mayo1"**
If mayo1's sshd has been rebound to the tunnel interface, you must use the
tunnel. Check: `ssh -v -o ConnectTimeout=5 mayo1`. If tunnel is down, try
the public IP temporarily: `ssh mayo@172.105.183.226`.

**"Smoke test failed — rolled back"**
The deploy script automatically rolled back. SSH to mayo1 and investigate
the failed slot:
```bash
ssh mayo1
ls -la /var/www/mayostudios.org        # shows which slot is live
# Check the OTHER slot's logs:
cd /var/www/mayostudios.org-{blue,green}  # whichever is NOT live
sudo -u www-data ./vendor/bin/drush watchdog:show --count=20
```

**"HTTP 503 after swap"**
Nginx is running but Drupal isn't responding. Check:
```bash
ssh mayo1 'cd /var/www/mayostudios.org && sudo -u www-data ./vendor/bin/drush status'
ssh mayo1 'sudo nginx -t && sudo systemctl status nginx'
```

## Security Reminders

- **Never put mons on Headscale.** The tunnel is one-to-one with mayo1 only.
- **Never run AI tooling on mons.** No Claude, no ollama, no LLM agents.
- **Never store production credentials beyond the SSH key.** No `.env`, no DB passwords.
- **Always verify signatures before deploying.** The deploy script does this automatically; never bypass it.
- **When Solo 2C+ arrives:** re-enroll SSH keys as `ed25519-sk` with `verify-required` and `resident` flags. Regenerate the minisign keypair on hardware. Update `~/.config/nwp-deploy.pub` on mons with the new public key.

## What Runs Where

| Step | Machine | Script |
|------|---------|--------|
| Build tarball | dev or met | `pl build mayo` |
| Sign tarball | dev or met | (part of `pl build`) |
| Publish to GitLab | dev or met | `pl publish mayo` |
| Download + verify | mons | `mons-deploy.sh` |
| Deploy to slot | mons → mayo1 | `mons-deploy.sh` (via SSH) |
| Swap slots | mayo1 | `bluegreen-swap.sh` |
| Sanitize DB | mayo1 | `lib/sanitizers/mayo.sh` |
