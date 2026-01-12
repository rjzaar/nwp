# Documentation Standards

**Last Updated:** 2026-01-12

This document defines the standards and conventions for all documentation in the NWP project.

## Table of Contents

- [File Naming Conventions](#file-naming-conventions)
- [Folder Structure](#folder-structure)
- [Document Structure Requirements](#document-structure-requirements)
- [Markdown Style Guide](#markdown-style-guide)
- [Command Documentation Template](#command-documentation-template)
- [Cross-Reference Guidelines](#cross-reference-guidelines)
- [Status Labels](#status-labels)
- [Proposal Lifecycle](#proposal-lifecycle)
- [Documentation Review Checklist](#documentation-review-checklist)
- [See Also](#see-also)

## File Naming Conventions

### General Rules

- **Lowercase with hyphens**: Use `feature-name.md` for all standard documentation
- **Descriptive names**: Filenames should clearly indicate content (e.g., `database-backup-guide.md`)
- **No special characters**: Only letters, numbers, and hyphens
- **Avoid abbreviations**: Prefer `database` over `db`, `configuration` over `config`

### Exceptions

| Pattern | Example | Usage |
|---------|---------|-------|
| ADRs use numbers | `0001-decision-name.md` | Architecture Decision Records |
| Root files use UPPERCASE | `README.md`, `CHANGELOG.md`, `CLAUDE.md` | Project root documentation |
| Uppercase acronyms OK | `SSH-key-management.md` | When acronym is well-known |

### Examples

**Good:**
- `backup-restore-guide.md`
- `security-best-practices.md`
- `linode-deployment.md`
- `0005-secrets-architecture.md`

**Bad:**
- `BackupRestore.md` (CamelCase)
- `backup_restore.md` (underscores)
- `br-guide.md` (unclear abbreviation)
- `backup&restore.md` (special characters)

## Folder Structure

### Current Documentation Hierarchy

```
docs/
├── guides/                    # User-facing how-to guides
│   ├── getting-started.md
│   ├── backup-restore.md
│   └── ...
├── reference/                 # API and technical reference
│   ├── commands/              # Command documentation
│   │   ├── live-deploy.md
│   │   ├── db-import.md
│   │   └── ...
│   ├── recipe-format.md
│   └── secrets-api.md
├── deployment/                # Deployment guides
│   ├── linode-setup.md
│   ├── cloudflare-config.md
│   └── ...
├── testing/                   # Testing documentation
│   ├── test-suite-guide.md
│   └── integration-tests.md
├── security/                  # Security documentation
│   ├── security-model.md
│   ├── data-security-best-practices.md
│   └── ...
├── proposals/                 # Active feature proposals
│   ├── P14-enhanced-backup.md
│   ├── P15-recipe-validation.md
│   └── ...
├── governance/                # Project governance
│   ├── distributed-contribution-governance.md
│   ├── core-maintainer-guidelines.md
│   └── ...
├── projects/                  # Project-specific documentation
│   ├── avc-customizations.md
│   └── ...
├── reports/                   # Audit and implementation reports
│   ├── backup-security-audit.md
│   └── ...
├── decisions/                 # Architecture Decision Records (ADRs)
│   ├── 0001-two-tier-secrets.md
│   ├── 0002-recipe-system.md
│   └── ...
├── archive/                   # Historical documents
│   ├── deprecated-commands.md
│   └── ...
├── ROADMAP.md                 # Future work and proposals
├── MILESTONES.md              # Completed work history
├── CHANGELOG.md               # Version changelog
└── README.md                  # Documentation index
```

### Folder Purposes

| Folder | Purpose | Status |
|--------|---------|--------|
| `guides/` | Step-by-step tutorials for common tasks | ACTIVE |
| `reference/` | Technical reference documentation | ACTIVE |
| `reference/commands/` | Individual command documentation | ACTIVE |
| `deployment/` | Infrastructure and deployment guides | ACTIVE |
| `testing/` | Testing procedures and documentation | ACTIVE |
| `security/` | Security architecture and best practices | ACTIVE |
| `proposals/` | Active feature proposals under consideration | ACTIVE |
| `governance/` | Project governance and contribution guidelines | ACTIVE |
| `projects/` | Site-specific or project-specific docs | ACTIVE |
| `reports/` | Audit reports and implementation analyses | ACTIVE |
| `decisions/` | Permanent record of architectural decisions | ARCHIVED (immutable) |
| `archive/` | Deprecated or historical documentation | ARCHIVED |

### Placement Guidelines

**Where to put new documentation:**

- **How do I...?** → `guides/`
- **What does this command do?** → `reference/commands/`
- **How do I deploy to...?** → `deployment/`
- **How do I test...?** → `testing/`
- **Security architecture?** → `security/`
- **New feature proposal?** → `proposals/`
- **Governance or process?** → `governance/`
- **Site-specific info?** → `projects/`
- **Completed audit/review?** → `reports/`
- **Architecture decision?** → `decisions/`
- **Old/deprecated content?** → `archive/`

## Document Structure Requirements

### Mandatory Elements

Every documentation file must include:

1. **H1 Title** - Descriptive title matching the filename
2. **Last Updated Date** - Format: YYYY-MM-DD
3. **Brief Description** - 1-2 sentences explaining the document's purpose

### Optional but Recommended Elements

- **Table of Contents** - Required if document exceeds 200 lines
- **Status Label** - DRAFT, ACTIVE, or ARCHIVED (see Status Labels section)
- **Prerequisites Section** - What readers should know/have before reading
- **Examples Section** - Real-world usage examples
- **Troubleshooting Section** - Common issues and solutions
- **See Also Section** - Links to related documentation (always at end)

### Standard Template

```markdown
# Document Title

**Status:** ACTIVE
**Last Updated:** 2026-01-12

Brief description of what this document covers (1-2 sentences).

## Table of Contents

(Only include if document > 200 lines)

- [Section 1](#section-1)
- [Section 2](#section-2)

## Prerequisites

What readers should know or have installed before reading this document.

## Section 1

Content here...

## Section 2

Content here...

## Examples

Real-world examples of concepts in this document.

## Troubleshooting

Common issues and their solutions.

## See Also

- [Related Document 1](./related-doc-1.md)
- [Related Document 2](./related-doc-2.md)
```

## Markdown Style Guide

### Headers

- **Use ATX-style headers** (`#`, `##`, `###`) not underline style
- **One H1 per document** - The document title only
- **No skipping levels** - Don't jump from H2 to H4
- **Descriptive headers** - Headers should clearly describe section content

```markdown
# Document Title (H1 - once only)

## Major Section (H2)

### Subsection (H3)

#### Detail Section (H4)
```

### Spacing

- **One blank line between sections** - Consistent spacing improves readability
- **No trailing whitespace** - Remove trailing spaces at end of lines
- **Two blank lines before H2** - Optional, for visual separation

```markdown
## Section One

Content of section one.

## Section Two

Content of section two.
```

### Code Blocks

- **Always specify language** - Enables syntax highlighting
- **Use fenced blocks** (```) not indentation
- **Include examples** - Show real usage, not just syntax

```markdown
    ```bash
    pl live deploy avc
    ```

    ```yaml
    site:
      name: "my-site"
    ```

    ```php
    $config['system.site']['name'] = 'My Site';
    ```
```

### Lists

- **Unordered lists** - Use `-` for bullets (consistent with NWP style)
- **Ordered lists** - Use `1.`, `2.`, `3.` (auto-numbering not required)
- **Nested lists** - Indent 2 spaces for sub-items
- **Blank lines** - No blank lines between simple list items

```markdown
- First item
- Second item
  - Nested item
  - Another nested item
- Third item

1. First step
2. Second step
3. Third step
```

### Tables

- **Use pipe syntax** - Standard markdown tables
- **Align columns** - Use `:` for alignment (left, center, right)
- **Headers required** - Every table needs a header row
- **Keep simple** - Complex tables should be broken down or use alternative formats

```markdown
| Command | Description | Status |
|---------|-------------|--------|
| `pl backup` | Create backup | ACTIVE |
| `pl restore` | Restore backup | ACTIVE |

| Left | Center | Right |
|:-----|:------:|------:|
| Text | Text   | Text  |
```

### Links

- **Relative paths for internal docs** - Use `./` and `../` for navigation
- **Absolute URLs for external links** - Full URLs for external resources
- **Descriptive link text** - Avoid "click here" or "this link"
- **Reference style for repeated links** - Define once, use many times

```markdown
<!-- Internal docs -->
See the [Backup Guide](./guides/backup-restore.md) for details.

<!-- External links -->
Visit [Drupal.org](https://www.drupal.org/) for more information.

<!-- Reference style -->
See the [deployment guide][deploy] and [security model][security].

[deploy]: ./deployment/linode-setup.md
[security]: ./security/security-model.md
```

### Emphasis

- **Bold** - Use `**bold**` for emphasis or important terms
- **Italic** - Use `*italic*` for slight emphasis or variable names
- **Code** - Use `backticks` for commands, file paths, and code terms
- **Blockquotes** - Use `>` for important notes or warnings

```markdown
**Important:** Always backup before deploying.

The *site_name* parameter is required.

Run `pl backup create avc` to create a backup.

> **Warning:** This operation is destructive and cannot be undone.
```

### File Paths and Commands

- **Commands in code blocks** - Use backticks for inline commands
- **File paths in code format** - `/path/to/file` not path/to/file
- **Command examples in fenced blocks** - Multi-line examples use fenced blocks

```markdown
Run the `pl backup` command to create a backup.

Edit the `/home/rob/nwp/cnwp.yml` file.

To deploy:

    ```bash
    cd /home/rob/nwp
    pl live deploy avc
    ```
```

## Command Documentation Template

All commands in `scripts/commands/` should have corresponding documentation in `docs/reference/commands/`.

### Standard Command Documentation Template

```markdown
# Command Name

**Status:** ACTIVE
**Last Updated:** YYYY-MM-DD

Brief one-sentence description of what this command does.

## Synopsis

    ```bash
    pl command-name [options] <required-arg> [optional-arg]
    ```

## Description

Detailed description of what the command does, when to use it, and what it affects.

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `site_slug` | Yes | The site identifier (e.g., avc, nwp) |
| `environment` | No | Target environment (defaults to prod) |

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `--force` | Skip confirmation prompts | false |
| `--dry-run` | Show what would happen without executing | false |

## Examples

### Basic Usage

    ```bash
    pl command-name avc
    ```

### With Options

    ```bash
    pl command-name --force avc production
    ```

### Common Workflow

    ```bash
    # Step 1: Prepare
    pl prepare avc

    # Step 2: Execute command
    pl command-name avc

    # Step 3: Verify
    pl verify avc
    ```

## Output

Description of what output the command produces:

    ```
    Example output here
    Success: Operation completed
    ```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Missing required argument |

## Prerequisites

- Required tools or configurations
- Permissions needed
- State requirements (e.g., site must exist)

## Notes

- Important caveats
- Performance considerations
- Security implications

## Troubleshooting

### Common Issue 1

**Symptom:** Error message or behavior

**Solution:** How to fix it

### Common Issue 2

**Symptom:** Error message or behavior

**Solution:** How to fix it

## See Also

- [Related Command 1](./related-command-1.md)
- [Guide: Related Topic](../guides/related-topic.md)
- [Security: Related Security Concern](../security/related-security.md)
```

### Command Documentation Guidelines

1. **Keep Synopsis accurate** - Match actual command signature
2. **Document all options** - Even hidden or advanced options
3. **Show real examples** - Use actual site slugs (avc, nwp) in examples
4. **Explain exit codes** - Help with scripting and automation
5. **Include troubleshooting** - Address common errors
6. **Link to related docs** - Connect commands to guides and concepts

## Cross-Reference Guidelines

### When to Cross-Reference

Always link to related documentation when:

- Mentioning a command in a guide → Link to command reference
- Describing a concept defined elsewhere → Link to definition
- Referencing a security model → Link to security docs
- Discussing a proposal → Link to proposal document
- Citing an architectural decision → Link to ADR

### How to Link Between Documents

```markdown
<!-- From guides/ to reference/commands/ -->
See the [backup command](../reference/commands/backup.md) for details.

<!-- From reference/commands/ to guides/ -->
For a complete workflow, see the [Backup Guide](../../guides/backup-restore.md).

<!-- Within same folder -->
See [related document](./related-doc.md) for more information.

<!-- To root documents -->
See the [ROADMAP](../../ROADMAP.md) for future plans.
```

### Link Maintenance

- **Check links when moving files** - Update all references
- **Use relative paths** - Avoid absolute paths that break when moving
- **Document link changes in commits** - Help reviewers track reference updates
- **Run link checker** - Use `pl verify docs` (if implemented) to validate links

### Cross-Reference Best Practices

**Good cross-references:**
- "See the [Database Backup Guide](../guides/backup-restore.md#database-backups) for step-by-step instructions."
- "This implements the architecture defined in [ADR-0001](../decisions/0001-two-tier-secrets.md)."
- "For security implications, see [Data Security Best Practices](../security/data-security-best-practices.md)."

**Bad cross-references:**
- "See the backup guide" (no link)
- "See [here](../guides/backup-restore.md)" (non-descriptive link text)
- "See `/home/rob/nwp/docs/guides/backup-restore.md`" (absolute path)

## Status Labels

Use status labels to indicate the lifecycle stage of documentation.

### Status Definitions

| Status | Meaning | Usage |
|--------|---------|-------|
| **DRAFT** | Work in progress, not yet ready | New docs being written |
| **ACTIVE** | Current and maintained | All production documentation |
| **ARCHIVED** | Historical, no longer maintained | Deprecated features, old proposals |
| **IMMUTABLE** | Permanent historical record | ADRs (never modified after creation) |

### Where to Place Status

```markdown
# Document Title

**Status:** ACTIVE
**Last Updated:** 2026-01-12

Content begins here...
```

### Status Transition Rules

```
DRAFT → ACTIVE      # When doc is complete and reviewed
ACTIVE → ARCHIVED   # When feature is deprecated
ACTIVE → IMMUTABLE  # ADRs only, when decision is finalized

ARCHIVED ← (never) → ACTIVE  # Archived docs stay archived
IMMUTABLE           # Never transitions (permanent record)
```

### Status Labels by Folder

| Folder | Typical Status | Notes |
|--------|---------------|-------|
| `guides/` | ACTIVE or ARCHIVED | Archive when feature deprecated |
| `reference/` | ACTIVE or ARCHIVED | Archive with feature |
| `proposals/` | DRAFT or ACTIVE | Never ARCHIVED (move to archive/) |
| `decisions/` | IMMUTABLE | Never changed after creation |
| `archive/` | ARCHIVED | All docs here are archived |
| `governance/` | ACTIVE | Rarely archived |
| `security/` | ACTIVE | Security docs rarely deprecated |

## Proposal Lifecycle

Proposals move through a defined lifecycle from creation to completion or archival.

### Proposal States

1. **DRAFT** - Initial proposal being written
2. **ACTIVE** - Proposal accepted, work in progress or planned
3. **COMPLETE** - Implemented and documented
4. **SUPERSEDED** - Replaced by another proposal
5. **REJECTED** - Not accepted for implementation

### Proposal Movement

```
proposals/P14-feature.md (DRAFT)
    ↓ (approved)
proposals/P14-feature.md (ACTIVE)
    ↓ (implemented)
proposals/P14-feature.md (COMPLETE) → MILESTONES.md
    ↓ (documented)
archive/proposals/P14-feature.md (ARCHIVED)
```

### Lifecycle Steps

#### 1. Creation (DRAFT)

```markdown
# P14: Feature Name

**Status:** DRAFT
**Proposal Date:** 2026-01-12
**Target Version:** v0.19

## Summary

Brief description of proposed feature.

## Success Criteria

- [ ] Criterion 1
- [ ] Criterion 2
```

**Location:** `docs/proposals/P14-feature-name.md`

#### 2. Acceptance (ACTIVE)

- Update status to ACTIVE
- Add to ROADMAP.md
- Assign to milestone/version

**Location:** `docs/proposals/P14-feature-name.md` (stays in place)

#### 3. Implementation (IN PROGRESS)

- Check off success criteria as completed
- Update "Last Updated" date regularly
- Link to related commits/branches

**Location:** `docs/proposals/P14-feature-name.md` (stays in place)

#### 4. Completion

- Update status to COMPLETE
- Move entry from ROADMAP.md to MILESTONES.md
- Verify all success criteria checked

**Location:** Still `docs/proposals/P14-feature-name.md`

#### 5. Archival (ARCHIVED)

- Once documented in guides/reference, archive proposal
- Move to `docs/archive/proposals/P14-feature-name.md`
- Update status to ARCHIVED
- Link from MILESTONES.md to archived proposal

**Location:** `docs/archive/proposals/P14-feature-name.md`

### Special Cases

**Superseded Proposal:**
```markdown
# P12: Old Approach

**Status:** SUPERSEDED by [P15](./P15-new-approach.md)
**Last Updated:** 2026-01-12

This proposal has been superseded by P15 which provides a better solution.

[Original proposal content remains for historical reference]
```

Move to `docs/archive/proposals/P12-old-approach.md`

**Rejected Proposal:**
```markdown
# P11: Rejected Feature

**Status:** REJECTED
**Last Updated:** 2026-01-12
**Reason:** Does not align with project goals (see discussion in issue #123)

[Original proposal content remains for historical reference]
```

Move to `docs/archive/proposals/P11-rejected-feature.md`

## Documentation Review Checklist

Use this checklist when creating or reviewing documentation.

### Structure

- [ ] H1 title matches filename
- [ ] Last Updated date is current
- [ ] Status label is present and accurate
- [ ] Table of contents (if >200 lines)
- [ ] See Also section at end

### Content

- [ ] Purpose clearly stated in first paragraph
- [ ] All commands include examples
- [ ] Code blocks specify language
- [ ] File paths are absolute where appropriate
- [ ] Technical terms are defined or linked

### Style

- [ ] ATX-style headers used
- [ ] Consistent spacing (one blank line between sections)
- [ ] Lists use `-` for bullets
- [ ] Tables have headers and alignment
- [ ] No trailing whitespace

### Links

- [ ] Internal links use relative paths
- [ ] External links use full URLs
- [ ] Link text is descriptive
- [ ] All links have been tested
- [ ] Cross-references to related docs included

### Technical Accuracy

- [ ] Commands have been tested
- [ ] Examples produce expected output
- [ ] Prerequisites are accurate
- [ ] Exit codes are correct
- [ ] Troubleshooting steps work

### Maintenance

- [ ] Status reflects current state
- [ ] Deprecated content is archived
- [ ] Version numbers are current
- [ ] Related docs are updated

## See Also

- [Roadmap](governance/roadmap.md) - Future proposals and planning
- [Milestones](reports/milestones.md) - Completed proposals and version history
- [CHANGELOG.md](../CHANGELOG.md) - Version changelog for releases
- [CLAUDE.md](../CLAUDE.md) - AI assistant instructions and project guidelines
- [Distributed Contribution Governance](governance/distributed-contribution-governance.md) - Contribution guidelines
- [Architecture Decisions](decisions/) - Architecture Decision Records
