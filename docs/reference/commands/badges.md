# badges

Dynamic GitLab CI/CD badges generation for project READMEs.

## Overview

The `badges` command manages GitLab CI/CD badges for project READMEs, providing visualization of build status, test coverage, and other metrics. It can generate badge URLs, markdown snippets, and automatically update README files with badges.

## Usage

```bash
pl badges <command> [options] <sitename>
```

## Commands

| Command | Description |
|---------|-------------|
| `show <sitename>` | Show all badge URLs for a site |
| `markdown <sitename>` | Generate markdown badge snippet |
| `add <sitename>` | Add badges to site's README.md |
| `update <sitename>` | Update existing badges in README |
| `coverage <sitename>` | Check test coverage threshold |

## Options

| Flag | Description |
|------|-------------|
| `--group <group>` | GitLab group (default: sites) |
| `--branch <branch>` | Git branch (default: main) |
| `--threshold <percent>` | Coverage threshold (default: 80) |

## Examples

### Show badge URLs
```bash
pl badges show mysite
```

### Generate markdown for dev branch
```bash
pl badges markdown mysite --branch=dev
```

### Add badges to README
```bash
pl badges add mysite
```

### Check 90% coverage threshold
```bash
pl badges coverage mysite --threshold=90
```

## Badge Types

The command generates badges for:

- **Pipeline Status**: Current CI/CD pipeline status
- **Test Coverage**: Code coverage percentage
- **Latest Release**: Most recent version tag
- **License**: Project license information

## Related Commands

- [test-nwp.sh](test-nwp.md) - Run tests that generate coverage data
- [status.sh](status.md) - Check overall site status

## See Also

- GitLab CI/CD Documentation
- Badge configuration in `.gitlab-ci.yml`
