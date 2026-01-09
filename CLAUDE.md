# Claude Code Instructions

This file provides specific instructions for Claude Code when working on this project.

## Critical: Protected Files

### cnwp.yml - NEVER COMMIT

The `cnwp.yml` file contains user-specific site configurations and **must never be committed to git**.

- **NEVER add cnwp.yml to git staging**
- **NEVER commit cnwp.yml**
- **NEVER include cnwp.yml in any commit**

If you need to make changes to the cnwp.yml schema or add new default options, make those changes to `example.cnwp.yml` instead.

### Why?

- `cnwp.yml` is in `.gitignore` for a reason
- Each user has their own local site configurations
- `example.cnwp.yml` serves as the template for new installations
- Users copy `example.cnwp.yml` to `cnwp.yml` and customize it

### Correct Workflow

1. New options, structure changes, documentation -> Edit `example.cnwp.yml`
2. User-specific site data -> Only in `cnwp.yml` (never committed)
3. When asked to update "the config", clarify: example.cnwp.yml for templates, cnwp.yml for user testing only

### Propagating Changes to cnwp.yml

When you make changes to `example.cnwp.yml` (adding new options, updating defaults, etc.), you **MUST** offer to update the user's `cnwp.yml` with the same changes:

1. After editing `example.cnwp.yml`, ask: "Would you like me to update your cnwp.yml with these changes?"
2. If yes, apply the changes to all relevant sections in `cnwp.yml`:
   - New recipe options -> Update all sites using that recipe
   - New settings -> Add to the settings section
   - New defaults -> Offer to apply to existing sites
3. Remember: You can READ and EDIT `cnwp.yml` - just never COMMIT it

## Two-Tier Secrets Architecture

NWP uses a two-tier secrets system that allows you to help with infrastructure while protecting user data:

### Files You CAN Read

| File | Contents | Why Safe |
|------|----------|----------|
| `.secrets.yml` | API tokens (Linode, Cloudflare, GitLab) | Infrastructure automation only |
| `.secrets.example.yml` | Template with empty values | No real credentials |
| `.env`, `.env.local` | Development settings | Local dev only |

### Files You CANNOT Read (Blocked by deny rules)

| File | Contents | Why Blocked |
|------|----------|-------------|
| `.secrets.data.yml` | Production DB, SSH, SMTP | Access to user data |
| `keys/prod_*` | Production SSH keys | Server access |
| `*.sql`, `*.sql.gz` | Database dumps | User data |
| `settings.php` | Drupal credentials | Production access |

### Using Secrets in Scripts

When helping with scripts, use the appropriate function:

```bash
# Infrastructure secrets (you can help with these)
token=$(get_infra_secret "linode.api_token" "")

# Data secrets (you should not access these)
db_pass=$(get_data_secret "production_database.password" "")
```

### Safe Operations

For operations needing data secrets, use proxy functions that return sanitized output:

```bash
source lib/safe-ops.sh

safe_server_status prod1    # Returns: Status, CPU, Memory (no credentials)
safe_db_status avc          # Returns: Table count, size (no actual data)
safe_security_check avc     # Returns: Update count (no credentials)
```

See `docs/DATA_SECURITY_BEST_PRACTICES.md` for the full security architecture.

## Other Protected Files

- `.env` files - Never commit environment secrets
- Any file in `.gitignore` - Respect the ignore patterns
- `.secrets.data.yml` - NEVER read, contains production credentials

## Project Structure

- `lib/` - Shared bash libraries
- `recipes/` - Recipe definitions (os, d, nwp, dm, etc.)
- `sites/` - All site installations go here (e.g., `sites/nwp/`, `sites/avc/`)
- `sites/*/html/` or `sites/*/web/` - Drupal webroot directories within each site
- `scripts/commands/` - All executable commands (accessed via `pl` CLI)
- `docs/` - Project documentation
  - `ROADMAP.md` - Pending proposals and future work
  - `MILESTONES.md` - Completed proposals and version history
  - `CHANGELOG.md` - Version changelog for releases
  - `decisions/` - Architecture Decision Records (ADRs)

## Release Tag Process

When the user asks to create a new release tag (e.g., "create tag v0.13"), follow this complete checklist:

### 1. Pre-Release Verification

- [ ] Run `./scripts/commands/test-nwp.sh` - ensure 98%+ pass rate
- [ ] Run `bash -n` syntax check on modified scripts in `scripts/commands/` and `lib/`
- [ ] Verify no uncommitted changes: `git status`
- [ ] Review git log since last tag: `git log $(git describe --tags --abbrev=0)..HEAD --oneline`

### 2. Version Updates

- [ ] Update version in `pl` script (NWP_VERSION variable)
- [ ] Update version in `example.cnwp.yml` if schema changed
- [ ] Update "Current Version" in `docs/ROADMAP.md`

### 3. Documentation Updates

- [ ] Review all modified `docs/*.md` files for accuracy
- [ ] Update "Last Updated" dates on modified docs
- [ ] Ensure README.md reflects current features
- [ ] Update CLAUDE.md if standing orders changed

### 4. Roadmap & Milestones

- [ ] Move completed proposals from `docs/ROADMAP.md` to `docs/MILESTONES.md`
- [ ] Update proposal statuses (PLANNED → IN PROGRESS → COMPLETE)
- [ ] Add any new proposals discovered during development
- [ ] Update success criteria checkboxes (mark completed items with [x])
- [ ] Update phase completion percentages

### 5. Changelog

- [ ] Create/update `CHANGELOG.md` in project root with:
  - Version number and date
  - New features (from completed proposals)
  - Bug fixes
  - Breaking changes (if any)
  - Migration notes (if needed)

### 6. Final Checks

- [ ] Ensure all significant changes from git log are documented
- [ ] Verify `example.cnwp.yml` matches current schema
- [ ] Check that new commands are documented in help text

### 7. Create Tag

```bash
# Create annotated tag with description
git tag -a v0.XX -m "Version 0.XX: Brief description of major changes"

# Push tag to remote
git push origin v0.XX
```

### 8. Post-Release

- [ ] Update any "Coming Soon" references to "Available"
- [ ] Create GitLab/GitHub release with changelog summary
- [ ] Announce release if significant

### Changelog Format

Use this format for `CHANGELOG.md` entries:

```markdown
## [v0.XX] - YYYY-MM-DD

### Added
- Feature description (P## reference if applicable)

### Changed
- Change description

### Fixed
- Bug fix description

### Breaking Changes
- Breaking change with migration path

### Migration Notes
- Steps users need to take when upgrading
```

### Version Numbering

NWP uses semantic-ish versioning:
- **v0.X** - Major feature releases (new proposals implemented)
- **v0.X.Y** - Bug fixes and minor improvements
- **v1.0** - Reserved for production-ready release
