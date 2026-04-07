# ADR-0001: Use DDEV for Local Development

**Status:** Accepted
**Date:** 2026-01-08
**Decision Makers:** Rob
**Related Issues:** N/A (foundational decision)

## Context

NWP needs a consistent local development environment for Drupal sites. Options include raw Docker, Docker Compose, Lando, DDEV, or native LAMP stacks.

## Options Considered

### Option 1: DDEV
- **Pros:**
  - Purpose-built for Drupal/PHP development
  - Simple configuration via `.ddev/config.yaml`
  - Built-in Drush, Composer, database management
  - Active community and Drupal core support
  - Cross-platform (Linux, macOS, Windows)
  - Handles SSL, routing, and networking
- **Cons:**
  - Additional abstraction layer
  - Learning curve for Docker-unfamiliar users

### Option 2: Raw Docker Compose
- **Pros:**
  - Maximum flexibility
  - No dependencies beyond Docker
- **Cons:**
  - Significant boilerplate for each project
  - Must manage networking, SSL, routing manually
  - Drupal-specific tooling not included

### Option 3: Lando
- **Pros:**
  - Similar to DDEV in purpose
  - Flexible configuration
- **Cons:**
  - Less Drupal-focused
  - Smaller community

## Decision

Use DDEV as the standard local development environment for all NWP sites.

## Rationale

DDEV provides the best balance of simplicity and power for Drupal development. It is officially recommended by the Drupal community and handles the complex parts of containerized development (SSL, routing, database access) automatically.

## Consequences

### Positive
- Consistent environment across all developers
- Simplified onboarding (one tool to learn)
- Built-in Drupal tooling reduces scripting needs

### Negative
- Dependency on DDEV project maintenance
- Some Docker expertise still needed for debugging

### Neutral
- All NWP scripts assume DDEV is available

## Implementation Notes

- DDEV configuration stored in `.ddev/` per site
- Global DDEV config in `~/.ddev/`
- NWP install scripts bootstrap DDEV automatically

## Review

**30-day review date:** 2026-02-08
**Review outcome:** Pending
