# ADR-0002: YAML-Based Configuration

**Status:** Accepted
**Date:** 2026-01-08
**Decision Makers:** Rob
**Related Issues:** N/A (foundational decision)

## Context

NWP needs a configuration format for site definitions, settings, and secrets. Options include JSON, YAML, TOML, INI, or environment variables.

## Options Considered

### Option 1: YAML
- **Pros:**
  - Human-readable and editable
  - Supports comments (unlike JSON)
  - Hierarchical structure fits our data model
  - Wide tooling support (yq, Python, etc.)
  - Already used by DDEV, Docker Compose, GitLab CI
- **Cons:**
  - Whitespace sensitivity can cause errors
  - Multiple parsing libraries with subtle differences

### Option 2: JSON
- **Pros:**
  - Universal support
  - Strict, unambiguous parsing
- **Cons:**
  - No comments
  - Verbose for nested structures
  - Less human-friendly to edit

### Option 3: Environment Variables
- **Pros:**
  - 12-factor app compatible
  - Easy secrets injection
- **Cons:**
  - Flat structure doesn't fit site hierarchies
  - Harder to version control configuration

## Decision

Use YAML for all NWP configuration files:
- `cnwp.yml` - Main site configuration
- `example.cnwp.yml` - Template configuration
- `.secrets.yml` - Infrastructure secrets
- `.secrets.data.yml` - Data secrets (separate file for security)

## Rationale

YAML's support for comments and hierarchical data makes it ideal for configuration that humans need to read and edit. Consistency with DDEV and GitLab CI reduces cognitive load.

## Consequences

### Positive
- Configuration files are self-documenting via comments
- Easy to understand site structure at a glance
- Consistent with ecosystem tools

### Negative
- Requires careful attention to indentation
- Need yq or similar for programmatic access

### Neutral
- All configuration parsing uses common functions in `lib/yaml-write.sh`

## Implementation Notes

- Use `yq` when available, fall back to awk for simple reads
- Always use `yaml_backup()` before modifying files
- Validate YAML syntax before committing changes

## Review

**30-day review date:** 2026-02-08
**Review outcome:** Pending
