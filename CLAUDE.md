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

## Other Protected Files

- `.env` files - Never commit environment secrets
- Any file in `.gitignore` - Respect the ignore patterns

## Project Structure

- `lib/` - Shared bash libraries
- `recipes/` - Recipe definitions (os, d, nwp, dm, etc.)
- `*/html/` or `*/web/` - Drupal webroot directories
- Site directories are at the project root level (e.g., `nwp5/`, `avc/`)
