# Production Deployment Testing Guide

## Overview

Testing production deployment requires a careful, methodical approach to avoid disrupting live sites. This guide outlines safe testing strategies, mock environments, and best practices for validating production deployment scripts before using them on real production servers.

---

## Testing Strategies

### Strategy 1: Local Mock Production Environment (RECOMMENDED)

**Concept:** Create a local "production" site that mimics production conditions

**Implementation:**
```bash
# Create a mock production site locally
./copy.sh nwp4_stg nwp4_prod

# This gives you:
# - nwp4 (development)
# - nwp4_stg (staging)
# - nwp4_prod (mock production)
```

**Advantages:**
- ✅ Completely safe - no risk to real production
- ✅ Fast iteration and testing
- ✅ Can test multiple times without consequences
- ✅ Test rollback procedures safely

**Disadvantages:**
- ⚠️ Doesn't test SSH connectivity
- ⚠️ Doesn't test remote filesystem operations
- ⚠️ May miss production-specific issues

**Use Case:** Initial script development and logic testing

---

### Strategy 2: Remote Test Production Server

**Concept:** Use a separate remote server that mimics production

**Implementation:**
```bash
# Deploy to test production server
./stg2prod.sh nwp4_stg --target=test-prod.example.com
```

**Requirements:**
- Separate VPS or shared hosting account for testing
- Similar configuration to real production (PHP version, database, etc.)
- SSH access configured
- Can be destroyed and rebuilt

**Advantages:**
- ✅ Tests SSH connectivity
- ✅ Tests remote filesystem operations
- ✅ Tests real-world network conditions
- ✅ Tests permissions and ownership issues
- ✅ Can test DNS and SSL setup

**Disadvantages:**
- ⚠️ Costs money (VPS/hosting)
- ⚠️ Takes time to set up
- ⚠️ Still not "real" production

**Use Case:** Final testing before production deployment

---

### Strategy 3: Dry-Run Mode

**Concept:** Script shows what it would do without actually doing it

**Implementation:**
```bash
# Add --dry-run flag to any deployment script
./stg2prod.sh --dry-run nwp4_stg

# Output shows all commands that would be executed:
# [DRY-RUN] Would execute: ssh user@prod.example.com "cd /var/www && git pull"
# [DRY-RUN] Would execute: rsync -av ./files/ user@prod.example.com:/var/www/files/
# [DRY-RUN] Would execute: ssh user@prod.example.com "drush updb -y"
```

**Advantages:**
- ✅ Zero risk - nothing is actually executed
- ✅ Can run against real production to verify commands
- ✅ Helps validate SSH access and paths
- ✅ Good for documentation and review

**Disadvantages:**
- ⚠️ Doesn't catch all issues (file permissions, etc.)
- ⚠️ Requires implementation in script

**Use Case:** Pre-flight check before real deployment

---

### Strategy 4: Blue-Green Deployment Testing

**Concept:** Deploy to alternate production environment, then switch

**Implementation:**
```bash
# Production runs on /var/www/site (green)
# Deploy to /var/www/site-blue
./stg2prod.sh nwp4_stg --target=blue

# Test the blue deployment
curl https://blue.example.com

# If good, switch production to blue
./switch-production.sh blue

# Rollback if needed
./switch-production.sh green
```

**Advantages:**
- ✅ Zero downtime deployment
- ✅ Easy rollback
- ✅ Can test in production environment before switching

**Disadvantages:**
- ⚠️ Requires production server support
- ⚠️ More complex setup
- ⚠️ Database migrations are tricky

**Use Case:** Large production sites with zero-downtime requirements

---

## Recommended Testing Workflow

### Phase 1: Local Testing (Safe)

1. **Create mock environments**
   ```bash
   # Start with dev site (nwp4)
   ./copy.sh nwp4 nwp4_stg    # Create staging
   ./copy.sh nwp4_stg nwp4_prod  # Create mock production
   ```

2. **Test staging deployment**
   ```bash
   # Make changes in dev
   cd nwp4 && ddev drush en some_module

   # Deploy to staging
   ./dev2stg.sh -y nwp4

   # Verify staging
   ddev drush status --fields=bootstrap
   ```

3. **Test production deployment (local)**
   ```bash
   # Create stg2prod.sh (to be implemented)
   ./stg2prod.sh -y nwp4_stg

   # Verify mock production
   cd nwp4_prod && ddev drush status
   ```

4. **Test rollback**
   ```bash
   # Should restore previous state
   ./stg2prod.sh --rollback nwp4_prod
   ```

### Phase 2: Remote Test Server (Safer)

1. **Set up test production server**
   - Provision VPS or shared hosting account
   - Install same PHP, MySQL versions as production
   - Configure SSH key authentication
   - Add to `~/.ssh/config`

2. **Test remote deployment**
   ```bash
   # Deploy to test server
   ./stg2prod.sh nwp4_stg --prod-alias=testprod

   # Where testprod is defined in cnwp.yml:
   # prod_alias: user@test-prod.example.com:/var/www/site
   ```

3. **Verify remote deployment**
   ```bash
   # SSH to test server
   ssh user@test-prod.example.com
   cd /var/www/site
   drush status
   drush cst  # Check configuration
   ```

### Phase 3: Dry-Run on Real Production (Safest)

1. **Run dry-run mode**
   ```bash
   # Shows what would happen, doesn't execute
   ./stg2prod.sh --dry-run nwp4_stg

   # Review all commands that would be executed
   # Verify paths, permissions, commands
   ```

2. **Review with team**
   - Share dry-run output
   - Verify backup procedures
   - Confirm rollback plan

### Phase 4: Real Production (High Risk)

1. **Pre-deployment checklist**
   - [ ] Backup production database
   - [ ] Backup production files
   - [ ] Test backup restoration
   - [ ] Schedule maintenance window
   - [ ] Notify team
   - [ ] Have rollback plan ready

2. **Deploy to production**
   ```bash
   # Final backup
   ./backup-production.sh prod_site

   # Deploy
   ./stg2prod.sh -y nwp4_stg

   # Monitor for errors
   # Test critical functionality
   ```

3. **Post-deployment verification**
   - [ ] Site is accessible
   - [ ] Login works
   - [ ] Database is correct version
   - [ ] Configuration is imported
   - [ ] Cache is cleared
   - [ ] Cron is working
   - [ ] Email is working

---

## Dry-Run Mode Implementation

### Example Implementation in stg2prod.sh

```bash
#!/bin/bash

DRY_RUN=false

# Parse --dry-run flag
while getopts "n-:" opt; do
    case "$opt" in
        -)
            case "$OPTARG" in
                dry-run)
                    DRY_RUN=true
                    ;;
            esac
            ;;
    esac
done

# Wrapper for executing commands
execute_cmd() {
    local cmd="$1"

    if [ "$DRY_RUN" == "true" ]; then
        echo -e "${CYAN}[DRY-RUN]${NC} Would execute: $cmd"
    else
        eval "$cmd"
    fi
}

# Usage in script
execute_cmd "ssh $PROD_ALIAS 'cd /var/www && git pull'"
execute_cmd "rsync -av ./files/ $PROD_ALIAS/files/"
execute_cmd "ssh $PROD_ALIAS 'drush updb -y'"
```

---

## Testing Checklist

### Pre-Deployment Testing

**Local Environment:**
- [ ] Script runs without errors
- [ ] All flags and options work
- [ ] Help text is accurate
- [ ] Error messages are clear
- [ ] Backup creation works
- [ ] Rollback works
- [ ] Resume from step works

**Remote Environment (if applicable):**
- [ ] SSH connectivity works
- [ ] SSH key authentication works
- [ ] File permissions are correct
- [ ] Rsync transfers files correctly
- [ ] Remote drush commands work
- [ ] Database operations work
- [ ] Configuration import works

**Safety Features:**
- [ ] Confirmation prompts work
- [ ] Dry-run mode works
- [ ] Backup before deployment works
- [ ] Validation catches errors
- [ ] Rollback is tested and works

### Deployment Testing Scenarios

**Scenario 1: Clean Deployment**
- Fresh staging to production deployment
- No previous deployments
- Test initial setup

**Scenario 2: Update Deployment**
- Deploy changes to existing production
- Test configuration updates
- Test module updates
- Test database updates

**Scenario 3: Failed Deployment**
- Simulate network failure
- Simulate database error
- Simulate disk full
- Verify rollback works

**Scenario 4: Rollback**
- Deploy version 2
- Rollback to version 1
- Verify data integrity

**Scenario 5: Large Files**
- Deploy with large file directory
- Test rsync efficiency
- Test timeout handling

---

## Production Deployment Methods

### Method 1: Rsync-Based (Recommended for Most)

**How it works:**
```bash
# Sync files from staging to production
rsync -av --delete \
    --exclude='sites/*/files/' \
    --exclude='sites/*/settings*.php' \
    ./nwp4_stg/ \
    user@prod.example.com:/var/www/site/
```

**Advantages:**
- Fast (only transfers changes)
- Reliable
- Can exclude files
- Can do dry-run

**Testing:**
```bash
# Test with dry-run first
rsync -av --dry-run --delete \
    ./nwp4_stg/ \
    user@test-prod.example.com:/var/www/site/
```

---

### Method 2: Git-Based

**How it works:**
```bash
# Production pulls from git repository
ssh user@prod.example.com 'cd /var/www/site && git pull origin main'
```

**Advantages:**
- Version controlled
- Easy rollback (git revert)
- Audit trail
- Works with CI/CD

**Testing:**
```bash
# Test with separate branch first
ssh user@test-prod.example.com 'cd /var/www/site && git fetch && git checkout test-branch'
```

---

### Method 3: Tar-Based

**How it works:**
```bash
# Create tarball of staging
tar -czf deploy.tar.gz -C nwp4_stg .

# Upload to production
scp deploy.tar.gz user@prod.example.com:/tmp/

# Extract on production
ssh user@prod.example.com 'cd /var/www/site && tar -xzf /tmp/deploy.tar.gz'
```

**Advantages:**
- Single file transfer
- Atomic extraction
- Can verify checksum

**Testing:**
```bash
# Test extraction locally first
tar -czf test.tar.gz -C nwp4_stg .
mkdir test_extract
tar -xzf test.tar.gz -C test_extract
diff -r nwp4_stg test_extract
```

---

## Safety Features to Implement

### 1. Pre-Deployment Backup

```bash
backup_before_deploy() {
    local site=$1

    print_header "Pre-Deployment Backup"

    # Backup database
    ssh $PROD_ALIAS "drush sql-dump --gzip > /tmp/pre-deploy-$(date +%Y%m%d-%H%M%S).sql.gz"

    # Backup files (optional)
    ssh $PROD_ALIAS "tar -czf /tmp/pre-deploy-files-$(date +%Y%m%d-%H%M%S).tar.gz -C /var/www/site ."

    print_status "OK" "Pre-deployment backup completed"
}
```

### 2. Validation Before Deployment

```bash
validate_production() {
    local prod_alias=$1

    print_header "Validate Production Environment"

    # Check SSH connectivity
    if ! ssh -q $prod_alias "exit" 2>/dev/null; then
        print_error "Cannot connect to production via SSH"
        return 1
    fi

    # Check production site exists
    if ! ssh $prod_alias "test -d /var/www/site"; then
        print_error "Production site directory not found"
        return 1
    fi

    # Check drush is available
    if ! ssh $prod_alias "which drush" > /dev/null 2>&1; then
        print_error "Drush not available on production"
        return 1
    fi

    print_status "OK" "Production environment validated"
    return 0
}
```

### 3. Post-Deployment Verification

```bash
verify_deployment() {
    local prod_alias=$1

    print_header "Verify Deployment"

    # Check site is accessible
    if ! ssh $prod_alias "drush status --field=bootstrap" | grep -q "Successful"; then
        print_error "Site is not bootstrapping correctly"
        return 1
    fi

    # Check database is up to date
    if ssh $prod_alias "drush updatedb --dry-run" | grep -q "pending"; then
        print_error "Database updates are pending"
        return 1
    fi

    # Check configuration is in sync
    if ssh $prod_alias "drush config:status" | grep -q "differences"; then
        print_error "Configuration is out of sync"
        return 1
    fi

    print_status "OK" "Deployment verified successfully"
    return 0
}
```

### 4. Rollback Capability

```bash
rollback_deployment() {
    local prod_alias=$1
    local backup_file=$2

    print_header "Rolling Back Deployment"

    # Restore database
    if [ -f "$backup_file" ]; then
        ssh $prod_alias "gunzip < $backup_file | drush sqlc"
        print_status "OK" "Database restored"
    fi

    # Clear cache
    ssh $prod_alias "drush cr"

    print_status "OK" "Rollback completed"
}
```

---

## Configuration for Production Testing

### cnwp.yml Configuration

```yaml
# Production configuration examples
mysite:
  source: goalgorilla/social_template:dev-master
  profile: social
  webroot: html

  # Production aliases
  prod_alias: user@prod.example.com:/var/www/mysite
  prod_test_alias: user@test-prod.example.com:/var/www/mysite

  # Deployment method
  prod_method: rsync  # Options: rsync, git, tar

  # Git-based production (if prod_method: git)
  prod_gitrepo: git@github.com:myorg/mysite.git
  prod_gitbranch: production

  # Backup settings
  prod_backup_before_deploy: true
  prod_backup_retention: 10

  # Safety settings
  prod_require_confirmation: true
  prod_dry_run_first: true

  # Post-deployment
  prod_clear_cache: true
  prod_verify_deployment: true
```

### SSH Configuration (~/.ssh/config)

```
# Production server
Host prod
    HostName prod.example.com
    User deployuser
    IdentityFile ~/.ssh/id_rsa_production
    ForwardAgent yes

# Test production server
Host test-prod
    HostName test-prod.example.com
    User deployuser
    IdentityFile ~/.ssh/id_rsa_production
    ForwardAgent yes
```

---

## Real-World Testing Example

### Complete Testing Workflow

```bash
# ============================================
# PHASE 1: Local Testing (Safe)
# ============================================

# 1. Create mock production environment
./copy.sh nwp4_stg nwp4_prod
echo "✅ Mock production created"

# 2. Test deployment to mock production
./stg2prod.sh -y nwp4_stg
echo "✅ Local deployment tested"

# 3. Test rollback
./stg2prod.sh --rollback nwp4_prod
echo "✅ Rollback tested"

# ============================================
# PHASE 2: Remote Test Server (Safer)
# ============================================

# 1. Deploy to test production server
./stg2prod.sh nwp4_stg --prod-alias=test-prod
echo "✅ Remote deployment tested"

# 2. Verify deployment
ssh test-prod "drush status"
ssh test-prod "drush cst"
ssh test-prod "drush updatedb --dry-run"
echo "✅ Remote deployment verified"

# 3. Test rollback on remote
./stg2prod.sh --rollback test-prod
echo "✅ Remote rollback tested"

# ============================================
# PHASE 3: Dry-Run on Production (Safest)
# ============================================

# 1. Run dry-run to see what would happen
./stg2prod.sh --dry-run nwp4_stg > deploy-plan.txt
echo "✅ Dry-run completed, review deploy-plan.txt"

# 2. Review with team
cat deploy-plan.txt
echo "⚠️  Review all commands before proceeding"

# ============================================
# PHASE 4: Real Production (High Risk)
# ============================================

# 1. Final backup
./backup-production.sh prod
echo "✅ Production backed up"

# 2. Test backup restoration
./restore.sh -b prod prod_test_restore
echo "✅ Backup verified"

# 3. Deploy to production
./stg2prod.sh -y nwp4_stg
echo "✅ DEPLOYED TO PRODUCTION"

# 4. Verify production
curl -I https://prod.example.com | grep "HTTP/2 200"
echo "✅ Production verified"
```

---

## When Things Go Wrong

### Common Issues and Solutions

**Issue 1: SSH Connection Failed**
```bash
# Test SSH connectivity
ssh -v user@prod.example.com

# Check SSH key
ssh-add -l

# Test with password
ssh -o PubkeyAuthentication=no user@prod.example.com
```

**Issue 2: Permission Denied**
```bash
# Check remote permissions
ssh user@prod.example.com "ls -la /var/www/site"

# Fix permissions
ssh user@prod.example.com "chown -R www-data:www-data /var/www/site"
```

**Issue 3: Drush Not Found**
```bash
# Check drush location
ssh user@prod.example.com "which drush"

# Use full path
ssh user@prod.example.com "/usr/local/bin/drush status"
```

**Issue 4: Database Import Failed**
```bash
# Check database connectivity
ssh user@prod.example.com "drush sqlq 'SELECT 1'"

# Check database size
ssh user@prod.example.com "drush sqlq 'SELECT table_schema, SUM(data_length + index_length) / 1024 / 1024 AS \"Size (MB)\" FROM information_schema.TABLES GROUP BY table_schema'"
```

---

## Recommended Testing Timeline

### Week 1: Local Testing
- Implement stg2prod.sh basic functionality
- Test with mock production (nwp4_prod)
- Test all flags and options
- Implement rollback

### Week 2: Dry-Run Implementation
- Add --dry-run flag
- Test dry-run output
- Verify command accuracy

### Week 3: Remote Test Server
- Set up test production server
- Deploy to test server
- Verify all operations
- Test rollback on remote

### Week 4: Production Testing
- Run dry-run on production
- Review with team
- Deploy during maintenance window
- Monitor and verify

---

## Conclusion

**Key Principles:**
1. **Never test on production first** - Always use mock environments
2. **Always have a rollback plan** - Test rollback before deploying
3. **Use dry-run mode** - Review commands before executing
4. **Backup before deployment** - Always, no exceptions
5. **Verify after deployment** - Don't assume it worked
6. **Start small** - Test with low-risk sites first

**Testing Priority:**
1. 🟢 Local mock production (safest)
2. 🟡 Remote test server (safer)
3. 🟠 Dry-run on production (safe)
4. 🔴 Real production (high risk)

**Remember:** The goal is to find and fix issues before they affect production. Every minute spent testing saves hours of production downtime.

---

*Last Updated: 2024-12-22*
