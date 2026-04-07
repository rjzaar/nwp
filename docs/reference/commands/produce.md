# produce

**Last Updated:** 2026-01-14

Provision production servers for NWP sites with custom domains, SSL, and backups.

## Overview

The `produce` command provisions dedicated production servers for sites, including Linode instance creation, custom domain configuration, Let's Encrypt SSL setup, and automated backup configuration. This is part of the development-to-production workflow.

## Synopsis

```bash
pl produce [options] <sitename>
```

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `-h, --help` | Show help message | - |
| `--delete` | Remove production server | - |
| `--type TYPE` | Linode instance type | g6-standard-2 |
| `--domain DOMAIN` | Custom domain for production | (auto-detect) |

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `sitename` | Yes | Site identifier for production provisioning |

## Examples

### Provision Production Server

```bash
pl produce mysite
```

Provisions a production server for `mysite` with default Linode type.

### Provision with Custom Domain

```bash
pl produce --domain mysite.com mysite
```

Provision production server and configure for `mysite.com`.

### Provision Larger Server

```bash
pl produce --type g6-standard-4 mysite
```

Provision with a larger Linode instance (4 GB RAM instead of 2 GB).

### Check Production Status

```bash
pl produce mysite
```

If production server already exists, shows current configuration and status.

### Remove Production Server (Planned)

```bash
pl produce --delete mysite
```

Display information about removing production server (manual deletion required).

## Production Workflow

The typical workflow for production deployment:

```bash
# 1. Develop locally
pl develop mysite

# 2. Deploy to staging
pl stage mysite

# 3. Test staging site
pl test mysite-stg

# 4. Provision production server
pl produce mysite

# 5. Deploy staging to production
pl stg2prod mysite

# 6. Verify production
curl https://mysite.com
```

## Linode Instance Types

Common Linode types for production:

| Type | vCPU | RAM | Storage | Monthly Cost |
|------|------|-----|---------|--------------|
| `g6-nanode-1` | 1 | 1 GB | 25 GB | $5 |
| `g6-standard-1` | 1 | 2 GB | 50 GB | $12 |
| `g6-standard-2` | 2 | 4 GB | 80 GB | $24 |
| `g6-standard-4` | 4 | 8 GB | 160 GB | $48 |
| `g6-standard-6` | 6 | 16 GB | 320 GB | $96 |

### Choosing Instance Type

- **Small sites (<1000 visitors/day)**: `g6-standard-1` or `g6-standard-2`
- **Medium sites (1000-10000 visitors/day)**: `g6-standard-4`
- **Large sites (>10000 visitors/day)**: `g6-standard-6` or higher
- **High traffic/media sites**: Consider dedicated CPU instances

## Provisioning Process (Planned)

When fully implemented, `produce` will:

### 1. Linode Instance Creation

- Create Linode via API
- Configure Ubuntu LTS
- Setup SSH keys
- Configure hostname
- Install base packages

### 2. DNS Configuration

- Create/update A record pointing to Linode IP
- Configure AAAA record (IPv6)
- Setup CNAME for www subdomain
- Configure MX records (if email enabled)

### 3. SSL Certificate

- Install Certbot
- Request Let's Encrypt certificate
- Configure auto-renewal
- Setup HTTPS redirect

### 4. Backup Configuration

- Enable Linode automatic backups
- Configure NWP backup schedule
- Setup off-site backup to B2
- Test restore procedure

### 5. Site Configuration

- Create site directory: `sites/<sitename>_prod`
- Configure web server (nginx/Apache)
- Setup PHP-FPM pool
- Configure database connection
- Update `nwp.yml` with production config

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success or status shown |
| 1 | Error (missing parameters, provisioning failed) |

## Prerequisites

- Linode account with API access
- API token in `.secrets.yml`
- Domain registered and DNS manageable
- Staging site tested and working
- Sufficient budget for Linode costs

## Configuration

Production configuration stored in `nwp.yml`:

```yaml
sites:
  mysite:
    recipe: d
    directory: sites/mysite
    prod:
      server_ip: "123.45.67.89"
      domain: "mysite.com"
      linode_id: "12345678"
      linode_type: "g6-standard-2"
      ssl: true
      backup_enabled: true
```

## Current Implementation Status

**Note:** Production provisioning is currently a **stub implementation**. The command shows:

1. Current production status (if already configured)
2. Manual setup instructions
3. Placeholder for future automation

### Manual Setup Required

Until full implementation:

```bash
# 1. Create Linode manually
# Visit: dashboard.linode.com

# 2. Add production config to nwp.yml
sites:
  mysite:
    prod:
      server_ip: "your-linode-ip"
      domain: "mysite.com"

# 3. Deploy to production
pl stg2prod mysite
```

## Troubleshooting

### Command Shows "Not Yet Implemented"

**Symptom:** Message indicates feature not implemented

**Solution:**
This is expected. Use manual provisioning:
1. Create Linode at dashboard.linode.com
2. Configure server manually
3. Add prod config to `nwp.yml`
4. Use `pl stg2prod` to deploy

### Cannot Determine Base Name

**Symptom:** Error about base name determination

**Solution:**
- Ensure site exists in `nwp.yml`
- Check site directory exists: `ls sites/<sitename>`
- Verify sitename spelling

### Production Config Not Recognized

**Symptom:** Command doesn't recognize existing production server

**Solution:**
```bash
# Verify nwp.yml structure
grep -A 5 "prod:" nwp.yml

# Ensure proper indentation (YAML sensitive)
# Should be:
#   mysite:
#     prod:
#       server_ip: "1.2.3.4"
```

## Best Practices

### Test in Staging First

```bash
# Always test staging before production provisioning
pl test mysite-stg
pl drush mysite-stg status
```

### Use Version Control

```bash
# Commit working staging before production
git add .
git commit -m "Prepare for production deployment"
git push
```

### Document Custom Configuration

Keep notes on any manual configuration:
- Firewall rules
- Custom DNS entries
- Third-party integrations
- API keys and credentials

### Plan for Scaling

Consider starting with smaller instance and scaling up:

```bash
# Start small
pl produce --type g6-standard-1 mysite

# Scale up later (requires manual Linode resize)
# Linode Console → Resize
```

### Enable Backups

Production servers should always have backups:

```yaml
sites:
  mysite:
    prod:
      backup_enabled: true
      backup_schedule:
        database: "0 2 * * *"    # Daily 2 AM
        full: "0 3 * * 0"        # Weekly Sunday 3 AM
```

## Security Considerations

### Production Isolation

- Production servers should be isolated from development
- Use separate SSH keys for production
- Restrict SSH access by IP when possible
- Disable root login over SSH

### SSL/TLS Configuration

- Use Let's Encrypt for free SSL certificates
- Enable HTTPS redirect for all traffic
- Configure HSTS headers
- Use TLS 1.2+ only

### Firewall Configuration

```bash
# Example UFW rules for production
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow http
sudo ufw allow https
sudo ufw enable
```

### Credential Management

- Never commit production credentials
- Store in `.secrets.data.yml` (git-ignored)
- Use strong database passwords
- Rotate credentials periodically

## Cost Estimation

### Monthly Costs (Typical)

```
Linode Instance (g6-standard-2):  $24.00/month
Backblaze B2 Storage (10 GB):      $0.05/month
Domain Registration (annual):     ~$12/year ($1/month)
Let's Encrypt SSL:                 Free
Total:                            ~$25/month
```

### Additional Costs

- **High traffic**: Bandwidth overage charges
- **Large storage**: Additional disk space
- **Email**: SMTP relay service if needed
- **Monitoring**: Uptime monitoring service
- **CDN**: CloudFlare or similar (optional)

## Future Enhancements

Planned features for `produce`:

- [ ] Automated Linode provisioning via API
- [ ] DNS automation (Linode DNS or Cloudflare)
- [ ] SSL certificate automation
- [ ] Backup configuration automation
- [ ] Load balancer support for high-traffic sites
- [ ] Multi-region deployment
- [ ] Kubernetes cluster provisioning
- [ ] Scaling recommendations based on analytics

## Notes

- Production servers are long-lived infrastructure
- Each site gets dedicated production directory: `sites/<sitename>_prod`
- Production configuration separate from staging
- Manual deletion required for Linode instances
- DNS changes may take 24-48 hours to propagate
- SSL certificate issuance may take a few minutes
- Production servers should use production recipe variant

## Related Commands

- [stage.sh](stage.md) - Deploy to staging
- [stg2prod.sh](stg2prod.md) - Deploy staging to production
- [live-deploy.sh](live-deploy.md) - Deploy to live environment
- [backup.sh](backup.md) - Backup production sites
- [storage.sh](storage.md) - Manage cloud storage for backups

## See Also

- [Production Deployment Guide](../../guides/production-deployment.md) - Complete production workflow
- [Linode Setup Guide](../../deployment/linode-setup.md) - Manual Linode configuration
- [SSL Certificate Setup](../../deployment/ssl-setup.md) - Let's Encrypt configuration
- [Production Checklist](../../deployment/production-checklist.md) - Pre-launch verification
- [Scaling Guide](../../guides/scaling-production.md) - Scaling production infrastructure
