# ADR-0003: Bash for Automation Scripts

**Status:** Accepted
**Date:** 2026-01-08
**Decision Makers:** Rob
**Related Issues:** N/A (foundational decision)

## Context

NWP needs a scripting language for automation, installation, and management tasks. Options include Bash, Python, Node.js, or PHP.

## Options Considered

### Option 1: Bash
- **Pros:**
  - Universal availability on Linux/macOS
  - Native integration with system commands
  - No runtime dependencies
  - Direct Docker, git, and CLI tool integration
  - Ops teams familiar with shell scripting
- **Cons:**
  - Complex logic becomes unwieldy
  - Error handling is verbose
  - Testing is more difficult

### Option 2: Python
- **Pros:**
  - Clean syntax for complex logic
  - Excellent testing frameworks
  - Rich standard library
- **Cons:**
  - Requires Python installation
  - Version compatibility issues (2 vs 3)
  - Shell command integration requires subprocess

### Option 3: Node.js
- **Pros:**
  - Modern async capabilities
  - NPM ecosystem
- **Cons:**
  - Heavy runtime for ops scripts
  - Less familiar to ops teams

## Decision

Use Bash for all NWP automation scripts, with functions organized in library files under `lib/`.

## Rationale

NWP scripts primarily orchestrate other tools (Docker, DDEV, git, Drush, curl). Bash provides the most direct integration with these tools without runtime dependencies. The `lib/` organization keeps scripts maintainable.

## Consequences

### Positive
- No additional dependencies to install
- Direct integration with all system tools
- Scripts work on any Linux/macOS system

### Negative
- Complex logic requires careful structuring
- Must follow style guidelines to maintain readability

### Neutral
- All scripts source common libraries from `lib/`
- Use shellcheck for linting

## Implementation Notes

- Common functions in `lib/common.sh`, `lib/ui.sh`, etc.
- Use `set -e` for error handling
- Quote all variables: `"$var"`
- Use `[[ ]]` for conditionals

## Review

**30-day review date:** 2026-02-08
**Review outcome:** Pending
