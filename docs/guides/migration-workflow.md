# Migration Workflow Guide

**Status:** ACTIVE
**Last Updated:** 2026-01-14

Complete guide for migrating external sites to Drupal 11 using NWP's migration system.

## Overview

NWP provides a structured migration workflow for importing sites from various platforms including Drupal 7/8/9, WordPress, Joomla, and static HTML sites. The migration process uses Drupal's Migrate API with automated detection and preparation.

## Supported Platforms

- **Drupal 7** - EOL January 5, 2025 (uses Migrate Drupal)
- **Drupal 8/9** - Upgrade path
- **WordPress** - Uses migrate_wordpress
- **Joomla** - Custom migration
- **Static HTML** - Uses migrate_source_html
- **Custom** - Manual migration configuration

## Migration Workflow

### Step 1: Create Migration Stub

Create a site with migration purpose flag:

```bash
# Creates directory structure without full installation
pl install d oldsite -p=m
```

This creates:
```
sites/oldsite/
├── source/          # Place source site files here
├── database/        # Place database dump here
└── .migration.yml   # Migration configuration
```

### Step 2: Prepare Source Data

Copy source files and database:

```bash
# Copy source site files
cp -r /path/to/old-site/* sites/oldsite/source/

# Copy database dump
cp /path/to/database.sql sites/oldsite/database/
```

### Step 3: Analyze Source

Analyze the source to determine migration strategy:

```bash
pl migration analyze oldsite
```

Output:
```
═══════════════════════════════════════════════════════════════
  Migration Analysis: oldsite
═══════════════════════════════════════════════════════════════

Source Detection:
  Type:         Drupal 7
  Version:      7.98
  Database:     MySQL 5.7
  Site Name:    Old Company Site
  Users:        245
  Nodes:        1,234
  Files:        3.2 GB

Modules Detected:
  Content:      node, field, taxonomy, file
  Custom:       company_custom (needs manual migration)
  Contrib:      views, pathauto, token, ctools

Migration Strategy:
  1. Use Migrate Drupal 7 module
  2. Standard content migration (nodes, users, files)
  3. Manual migration needed for: company_custom
  4. Estimated time: 2-4 hours

Recommendations:
  - Install migrate_drupal, migrate_drupal_ui
  - Review custom module compatibility
  - Plan downtime window for production
```

### Step 4: Prepare Target Site

Set up Drupal 11 site with migration modules:

```bash
pl migration prepare oldsite
```

This process:
1. Installs Drupal 11
2. Installs migration modules (migrate_drupal, migrate_drupal_ui, migrate_tools)
3. Configures migration source database connection
4. Validates source compatibility
5. Generates migration manifest

Output:
```
═══════════════════════════════════════════════════════════════
  Migration Preparation: oldsite
═══════════════════════════════════════════════════════════════

[1/5] Install Drupal 11
✓ Drupal 11 installed

[2/5] Install migration modules
✓ migrate_drupal, migrate_drupal_ui, migrate_tools installed

[3/5] Configure source database
✓ Database connection configured

[4/5] Validate source
✓ Source compatible

[5/5] Generate manifest
✓ Migration manifest created

Migration ready:
  Source database: connected
  Migration UI: https://oldsite.ddev.site/upgrade
```

### Step 5: Run Migration

Execute the migration:

**Dry-run first (recommended):**
```bash
pl migration run oldsite --dry-run
```

**Execute migration:**
```bash
pl migration run oldsite
```

The migration runs in phases:
1. **User Migration** - Migrate user accounts
2. **Taxonomy Migration** - Migrate vocabularies and terms
3. **File Migration** - Migrate files and media
4. **Node Migration** - Migrate content nodes
5. **Menu Migration** - Migrate menu structures
6. **Configuration** - Import relevant configurations

Output:
```
═══════════════════════════════════════════════════════════════
  Running Migration: oldsite
═══════════════════════════════════════════════════════════════

[1/6] Migrate users
✓ 245 users migrated (3 skipped: admin, anonymous)

[2/6] Migrate taxonomy
✓ 15 vocabularies migrated
✓ 342 terms migrated

[3/6] Migrate files
✓ 1,856 files migrated (3.2 GB)

[4/6] Migrate nodes
✓ 1,234 nodes migrated
  - Article: 456
  - Page: 345
  - Custom: 433

[5/6] Migrate menus
✓ 4 menus migrated

[6/6] Import configuration
✓ Configuration imported

═══════════════════════════════════════════════════════════════
  Migration Complete
═══════════════════════════════════════════════════════════════

Site: https://oldsite.ddev.site
Results:
  Users:    245 migrated
  Content:  1,234 nodes
  Files:    3.2 GB
  Menus:    4 menus
```

### Step 6: Verify Migration

Verify completeness and integrity:

```bash
pl migration verify oldsite
```

Verification checks:
- User count matches
- Content count matches
- Files accessible
- Menu structure intact
- URL aliases working
- Custom functionality

Output:
```
═══════════════════════════════════════════════════════════════
  Migration Verification: oldsite
═══════════════════════════════════════════════════════════════

Content Verification:
  ✓ Users: 245/245 (100%)
  ✓ Nodes: 1,234/1,234 (100%)
  ✓ Files: 1,856/1,856 (100%)
  ✓ Terms: 342/342 (100%)

Integrity Checks:
  ✓ All files accessible
  ✓ Menu structure preserved
  ✓ URL aliases functional
  ⚠ Custom module migration needed

Issues Found:
  1. Custom module 'company_custom' not migrated (manual)
  2. 15 broken file references (review)

Next Steps:
  1. Manually migrate custom module
  2. Fix broken file references
  3. Test all functionality
  4. Deploy to production
```

## Platform-Specific Guides

### Drupal 7 Migration

**Important:** Drupal 7 reached EOL on January 5, 2025. No direct upgrade path exists - content must be migrated.

```bash
# Standard Drupal 7 migration
pl install d oldsite -p=m
# ... copy files and database ...
pl migration analyze oldsite
pl migration prepare oldsite
pl migration run oldsite
pl migration verify oldsite
```

**Common issues:**
- Custom field types need manual migration
- Custom modules require porting to Drupal 11
- Theme must be rebuilt for Drupal 11
- Contrib modules need Drupal 11 equivalents

### WordPress Migration

```bash
pl install d wp-site -p=m
# ... copy WordPress files and database ...
pl migration analyze wp-site
pl migration prepare wp-site
pl migration run wp-site
```

**What gets migrated:**
- Posts → Nodes (article)
- Pages → Nodes (page)
- Categories/Tags → Taxonomy
- Media library → Files
- Users → Users
- Comments → Comments

**Manual steps:**
- Custom post types need field mapping
- Shortcodes need replacement
- Plugins need Drupal module equivalents
- Theme rebuild required

### Static HTML Migration

```bash
pl install d static-site -p=m
# ... copy HTML files ...
pl migration analyze static-site
pl migration prepare static-site
pl migration run static-site
```

**Process:**
- HTML files parsed and converted to nodes
- Images and assets migrated to files
- Navigation extracted to menus
- Metadata preserved where possible

## Migration Best Practices

### Pre-Migration Checklist

- [ ] Backup source site
- [ ] Document custom functionality
- [ ] List required modules/plugins
- [ ] Identify custom code
- [ ] Test migration on subset of data
- [ ] Plan downtime window

### During Migration

- [ ] Run dry-run first
- [ ] Monitor migration progress
- [ ] Check for errors in logs
- [ ] Validate sample content
- [ ] Test file access
- [ ] Verify URL structure

### Post-Migration

- [ ] Full content review
- [ ] Functionality testing
- [ ] Performance testing
- [ ] SEO verification (redirects, meta tags)
- [ ] User acceptance testing
- [ ] Go-live plan

## Troubleshooting

### Migration Fails - Database Connection

**Symptom:**
```
ERROR: Cannot connect to source database
```

**Solution:**
- Check database credentials in `.migration.yml`
- Verify database dump imported correctly
- Test connection: `ddev mysql < database/dump.sql`

### Custom Module Migration

**Symptom:**
```
WARNING: Custom module 'mymodule' not migrated
```

**Solution:**
- Port module to Drupal 11
- Use Drupal Module Upgrader: `drupal-rector`
- Or rebuild functionality using Drupal 11 patterns
- Document custom migration steps

### File Migration Incomplete

**Symptom:**
```
WARNING: 150 files not migrated
```

**Solution:**
- Check file paths in source
- Verify file permissions
- Check disk space
- Manually copy missing files to `sites/default/files/`

### Performance Issues

**Symptom:**
```
Migration taking too long (> 10 hours)
```

**Solution:**
- Use `--batch` flag for large migrations
- Increase PHP memory limit
- Process in chunks (users, then content, then files)
- Use drush migrate commands directly for control

## Related Commands

- [install](../reference/commands/install.md) - Create migration stub
- [Migration Script Reference](../reference/commands/migration.md) - Full command reference

## See Also

- [Drupal Migrate API Documentation](https://www.drupal.org/docs/drupal-apis/migrate-api) - Official Migrate API docs
- [Migrate Tools](https://www.drupal.org/project/migrate_tools) - Drush commands for migrations
- [Migration Sites Tracking](./migration-sites-tracking.md) - Track multiple migration projects
