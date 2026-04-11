# WireGuard Tunnel: mons ↔ mayo1

F21 Phase 5: Dedicated one-to-one WireGuard tunnel between mons (deploy
machine) and mayo1 (production server). This is NOT part of the Headscale
mesh — mons must never join Headscale.

## Architecture

```
mons (10.99.0.1/32)  ←──WireGuard──→  mayo1 (10.99.0.2/32)
  └─ offline by default                  └─ sshd binds to 10.99.0.2 only
  └─ phone hotspot for deploys               (public SSH closed after cutover)
```

## Setup Steps

### On mayo1 (production server)

1. Install WireGuard:
   ```bash
   sudo apt-get install -y wireguard
   ```

2. Generate keypair:
   ```bash
   wg genkey | tee /etc/wireguard/mayo1-private.key | wg pubkey > /etc/wireguard/mayo1-public.key
   chmod 600 /etc/wireguard/mayo1-private.key
   ```

3. Install the config:
   ```bash
   sudo cp wg-mons.conf.mayo1 /etc/wireguard/wg-mons.conf
   # Edit: replace MAYO1_PRIVATE_KEY and MONS_PUBLIC_KEY with real values
   sudo systemctl enable --now wg-quick@wg-mons
   ```

4. After testing, rebind sshd to tunnel interface only:
   ```bash
   # In /etc/ssh/sshd_config, change:
   #   ListenAddress 0.0.0.0
   # to:
   #   ListenAddress 10.99.0.2
   #   ListenAddress 127.0.0.1
   sudo systemctl reload sshd
   ```

5. Update firewall:
   ```bash
   sudo ufw allow 51820/udp    # WireGuard
   sudo ufw delete allow 22    # Close public SSH (only after tunnel verified!)
   ```

### On mons (deploy machine)

1. Install WireGuard:
   ```bash
   sudo apt-get install -y wireguard
   ```

2. Generate keypair:
   ```bash
   wg genkey | tee /etc/wireguard/mons-private.key | wg pubkey > /etc/wireguard/mons-public.key
   chmod 600 /etc/wireguard/mons-private.key
   ```

3. Install the config:
   ```bash
   sudo cp wg-mons.conf.mons /etc/wireguard/wg-mons.conf
   # Edit: replace MONS_PRIVATE_KEY and MAYO1_PUBLIC_KEY with real values
   ```

4. Bring up the tunnel when deploying:
   ```bash
   sudo wg-quick up wg-mons
   # ... deploy ...
   sudo wg-quick down wg-mons
   ```

5. Update SSH config on mons:
   ```bash
   # In ~/.ssh/config, change mayo1 entry:
   Host mayo1
       User mayo
       Port 22
       Hostname 10.99.0.2          # tunnel address, not public IP
       IdentityFile ~/.ssh/opencat
       IdentitiesOnly yes
   ```

## Key Exchange

Keys must be exchanged out-of-band (USB stick, read aloud, etc.):

1. mayo1's public key → mons's config (Peer.PublicKey)
2. mons's public key → mayo1's config (Peer.PublicKey)

Never transmit private keys over the network.

## Testing

```bash
# On mons, with tunnel up:
ping -c 3 10.99.0.2
ssh -o ConnectTimeout=5 mayo1 hostname

# On mayo1:
sudo wg show wg-mons
```

## Rollback

If something goes wrong with sshd rebinding:

1. Access mayo1 via Linode's Lish console (out-of-band)
2. Restore sshd to listen on all interfaces:
   ```bash
   sudo sed -i 's/ListenAddress 10.99.0.2/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config
   sudo systemctl reload sshd
   ```
3. Re-allow public SSH: `sudo ufw allow 22`
