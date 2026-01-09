# Contributing to NWP

Welcome! We're glad you're interested in contributing to NWP. This document explains how to get started.

## Quick Start

### For Simple Contributions (Fork-Based)

Most contributors should use the fork-based workflow:

```bash
# 1. Fork the repository on GitHub
# 2. Clone your fork
git clone git@github.com:YOUR_USERNAME/nwp.git
cd nwp

# 3. Add upstream remote
git remote add upstream git@github.com:rjzaar/nwp.git

# 4. Create a feature branch
git checkout -b fix/your-fix-description

# 5. Make changes and commit
git add -A
git commit -m "Fix: description of your fix"

# 6. Push and create PR
git push origin fix/your-fix-description
# Then create PR via GitHub web interface
```

### For Core Development (Full Access)

If you need your own subdomain and GitLab access, see [docs/CODER_ONBOARDING.md](docs/CODER_ONBOARDING.md).

## Contribution Workflow

### 1. Find or Create an Issue

- Check existing issues before starting work
- For bugs: Create an issue with reproduction steps
- For features: Discuss in an issue before implementing

### 2. Branch Naming

Use descriptive branch names:
- `fix/issue-123-backup-path` - Bug fixes
- `feature/add-s3-support` - New features
- `docs/update-readme` - Documentation
- `refactor/cleanup-lib-common` - Refactoring

### 3. Commit Messages

Write clear commit messages:
```
Fix: Handle spaces in backup paths (#123)

- Quote all path variables in backup.sh
- Add test for paths with spaces
- Update documentation

Closes #123
```

### 4. Code Standards

- Run `shellcheck` on bash scripts
- Follow existing code style
- Add tests for new functionality
- Update documentation as needed

### 5. Pull Request Process

1. Ensure tests pass locally
2. Update CHANGES.md if applicable
3. Create PR with clear description
4. Respond to review feedback
5. Squash commits if requested

## Contributor Roles

| Role | Access | How to Get |
|------|--------|------------|
| **Newcomer** | Fork-based PRs | Anyone can start |
| **Contributor** | Push to branches, own subdomain | 5+ merged PRs |
| **Core Developer** | Merge to main, review others | 50+ merged PRs, 6+ months |
| **Steward** | Full admin, architecture decisions | Appointed by vote |

See [docs/ROLES.md](docs/ROLES.md) for full details.

## What to Contribute

### Good First Issues

Look for issues labeled `good first issue` or `help wanted`.

### Types of Contributions

- **Bug fixes** - Fix something broken
- **Documentation** - Improve docs, add examples
- **Tests** - Increase test coverage
- **Features** - New functionality (discuss first)
- **Recipes** - New installation recipes

### Areas Where Help is Needed

- Test coverage for existing scripts
- Documentation improvements
- Recipe development for new platforms
- CI/CD pipeline enhancements

## Code of Conduct

### Be Respectful
- Welcome newcomers
- Assume good intentions
- Give constructive feedback
- Disagree professionally

### Be Collaborative
- Share knowledge
- Help others learn
- Credit contributions
- Build on others' work

### Be Responsible
- Own your mistakes
- Fix what you break
- Test before submitting
- Document your work

## Decision Making

### Architecture Decision Records (ADRs)

Major decisions are documented in `docs/decisions/`:
- Browse existing decisions before proposing changes
- New architectural changes may require an ADR
- Check if your idea conflicts with previous decisions

### Governance

See [docs/DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md](docs/DISTRIBUTED_CONTRIBUTION_GOVERNANCE.md) for our full governance framework.

## Development Setup

### Prerequisites

- Docker and Docker Compose
- DDEV
- Git
- Bash 4+
- yq (optional, for YAML editing)

### Local Development

```bash
# Clone repository
git clone git@github.com:rjzaar/nwp.git
cd nwp

# Copy config templates
cp example.cnwp.yml cnwp.yml
cp .secrets.example.yml .secrets.yml

# Run setup
./scripts/commands/setup.sh

# Create a test site
./install.sh d testsite
```

### Running Tests

```bash
# Run all tests
./tests/run-tests.sh

# Run specific test
bats tests/backup.bats
```

## Getting Help

- **Documentation:** `docs/` folder
- **Issues:** [GitHub Issues](https://github.com/rjzaar/nwp/issues)
- **Questions:** Open a support issue

## Recognition

Contributors are recognized in:
- Git commit history
- CHANGES.md for significant contributions
- README.md contributors section (for major contributors)

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.

---

Thank you for contributing to NWP!
