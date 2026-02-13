# AVC Moodle Integration

This module provides comprehensive integration between AV Commons (Drupal/OpenSocial) and Moodle LMS.

## Features

### Single Sign-On (SSO)
- OAuth2-based authentication
- AVC members can log in to Moodle with their AVC credentials
- Automatic user provisioning in Moodle
- Secure token-based authentication (5-minute token lifetime)

### Role Synchronization
- Automatic sync of guild roles to Moodle cohorts
- Real-time updates when users join/leave guilds
- Configurable role mappings
- Cron-based full synchronization

### Badge & Course Completion Display
- Display Moodle badges on AVC user profiles
- Show course completion status
- Guild-level learning statistics
- Cached for performance

## Installation

### Via NWO (Recommended)

```bash
# Set up integration between AVC and Moodle sites
pl avc-moodle-setup avc ss

# This will:
# 1. Generate OAuth2 keys
# 2. Install required modules
# 3. Configure OAuth2 client and issuer
# 4. Test SSO flow
```

### Manual Installation

1. Install Simple OAuth module:
   ```bash
   composer require drupal/simple_oauth:^5.2
   drush en -y simple_oauth
   ```

2. Install AVC Moodle modules:
   ```bash
   drush en -y avc_moodle avc_moodle_oauth avc_moodle_sync avc_moodle_data
   ```

3. Generate OAuth2 keys:
   ```bash
   mkdir -p private/keys
   openssl genrsa -out private/keys/oauth_private.key 2048
   openssl rsa -in private/keys/oauth_private.key -pubout -out private/keys/oauth_public.key
   chmod 600 private/keys/oauth_private.key
   chmod 644 private/keys/oauth_public.key
   ```

4. Configure Simple OAuth:
   - Go to Configuration > Web Services > Simple OAuth
   - Set public key path: `/var/www/html/private/keys/oauth_public.key`
   - Set private key path: `/var/www/html/private/keys/oauth_private.key`
   - Set token expiration: 300 seconds

## Configuration

### AVC Configuration

1. Go to Configuration > AVC Moodle
2. Configure:
   - Moodle site URL
   - Web Services API token
   - Role mappings (guild role → Moodle role)
   - Sync interval
   - Cache settings

### Moodle Configuration

1. Enable Web Services:
   - Site administration > Advanced features > Enable web services

2. Create OAuth2 issuer:
   - Site administration > Server > OAuth 2 services
   - Add new issuer
   - Configure endpoints:
     - Issuer: https://avc.example.com
     - Authorize: /oauth/authorize
     - Token: /oauth/token
     - UserInfo: /oauth/userinfo

3. Enable authentication:
   - Site administration > Plugins > Authentication > Manage authentication
   - Enable "AVC OAuth2" authentication

## Submodules

### avc_moodle_oauth
OAuth2 provider endpoints for Moodle authentication.

**Endpoints:**
- `/oauth/userinfo` - Returns user information for authenticated users

**Configuration:**
- Extends Simple OAuth module
- Provides AVC-specific user data mapping

### avc_moodle_sync
Role and cohort synchronization from AVC to Moodle.

**Features:**
- Real-time sync on guild membership changes
- Hourly cron full sync
- Drush commands for manual sync
- Configurable role mappings

**Drush Commands:**
```bash
# Full sync
drush avc-moodle:sync --full

# Sync specific guild
drush avc-moodle:sync --guild=web-dev

# Sync specific user
drush avc-moodle:sync --user=123

# Dry run
drush avc-moodle:sync --full --dry-run
```

### avc_moodle_data
Badge and course completion display on AVC profiles.

**Features:**
- Badge display on user profiles
- Course completion progress bars
- Guild-level learning statistics
- Cached for performance (1-hour TTL)

**Blocks:**
- User Moodle Badges
- User Course Progress
- Guild Learning Statistics

## NWO Commands

### Setup Integration
```bash
pl avc-moodle-setup avc ss [--role-sync] [--badge-display]
```

### Check Status
```bash
pl avc-moodle-status avc ss
```

### Manual Sync
```bash
pl avc-moodle-sync avc ss --full
pl avc-moodle-sync avc ss --guild=web-dev
```

### Test Integration
```bash
pl avc-moodle-test avc ss
```

## Architecture

```
┌─────────────────────────────────────┐
│   AVC Drupal Site                    │
│                                      │
│  ┌────────────────────────────────┐ │
│  │ avc_moodle_oauth               │ │
│  │ - OAuth2 UserInfo endpoint     │ │
│  │ - User data mapping            │ │
│  └────────────────────────────────┘ │
│                                      │
│  ┌────────────────────────────────┐ │
│  │ avc_moodle_sync                │ │
│  │ - Guild membership tracking    │ │
│  │ - Moodle API client            │ │
│  │ - Role sync service            │ │
│  └────────────────────────────────┘ │
│                                      │
│  ┌────────────────────────────────┐ │
│  │ avc_moodle_data                │ │
│  │ - Badge fetching               │ │
│  │ - Course completion display    │ │
│  │ - Cache management             │ │
│  └────────────────────────────────┘ │
└──────────────┬───────────────────────┘
               │
               │ OAuth2 + Web Services
               │
┌──────────────▼───────────────────────┐
│   Moodle LMS                         │
│                                      │
│  - auth/avc_oauth2 (Authentication)  │
│  - local/cohortrole (Role mapping)   │
│  - Web Services API                  │
└──────────────────────────────────────┘
```

## Security

- OAuth2 keys stored outside webroot (`private/keys/`)
- Private key: 600 permissions (owner read/write only)
- Public key: 644 permissions
- 2048-bit RSA encryption
- 5-minute token lifetime
- HTTPS required for all OAuth communication

## Support

For issues or questions:
- NWO Documentation: `/home/rob/nwp/docs/`
- Integration Guide: `docs/NWO_MOODLE_SSO_IMPLEMENTATION.md`
- Proposal: `docs/AVC_MOODLE_INTEGRATION_PROPOSAL.md`

## License

GPL-2.0-or-later
