# Project Badges Template

Add these badges to your project's README.md for visibility into test health.

## Badge URLs

Replace `{gitlab_url}`, `{group}`, and `{project}` with your values.

### Pipeline Status
```markdown
[![Pipeline Status](https://{gitlab_url}/{group}/{project}/badges/main/pipeline.svg)](https://{gitlab_url}/{group}/{project}/-/pipelines)
```

### Coverage
```markdown
[![Coverage](https://{gitlab_url}/{group}/{project}/badges/main/coverage.svg)](https://{gitlab_url}/{group}/{project}/-/graphs/main/charts)
```

### Latest Release
```markdown
[![Latest Release](https://{gitlab_url}/{group}/{project}/-/badges/release.svg)](https://{gitlab_url}/{group}/{project}/-/releases)
```

## Example for NWP GitLab

If your GitLab is at `git.nwpcode.org` and project is `sites/mysite`:

```markdown
[![Pipeline Status](https://git.nwpcode.org/sites/mysite/badges/main/pipeline.svg)](https://git.nwpcode.org/sites/mysite/-/pipelines)
[![Coverage](https://git.nwpcode.org/sites/mysite/badges/main/coverage.svg)](https://git.nwpcode.org/sites/mysite/-/graphs/main/charts)
```

## Full README Header Template

```markdown
# My Drupal Site

[![Pipeline Status](https://git.nwpcode.org/sites/mysite/badges/main/pipeline.svg)](https://git.nwpcode.org/sites/mysite/-/pipelines)
[![Coverage](https://git.nwpcode.org/sites/mysite/badges/main/coverage.svg)](https://git.nwpcode.org/sites/mysite/-/graphs/main/charts)

## Description

Your site description here.

## Requirements

- PHP 8.2+
- Composer 2.x
- DDEV

## Installation

\`\`\`bash
git clone git@git.nwpcode.org:sites/mysite.git
cd mysite
ddev start
ddev composer install
\`\`\`

## Testing

\`\`\`bash
# All tests
ddev exec vendor/bin/phpunit

# Smoke tests only
ddev exec vendor/bin/behat --tags=@smoke

# Code quality
ddev exec vendor/bin/phpcs web/modules/custom
ddev exec vendor/bin/phpstan analyse
\`\`\`

## Deployment

See [NWP Documentation](https://github.com/rjzaar/nwp) for deployment instructions.
```

## Coverage Configuration

To enable coverage badges, ensure your `.gitlab-ci.yml` includes:

```yaml
phpunit:unit:
  coverage: '/^\s*Lines:\s*\d+.\d+\%/'
  artifacts:
    reports:
      coverage_report:
        coverage_format: cobertura
        path: reports/coverage.xml
```

## Coverage Threshold

Set minimum coverage in GitLab:
1. Go to Settings → CI/CD → General pipelines
2. Set "Test coverage parsing" regex: `^\s*Lines:\s*(\d+.\d+)\%`
3. Optionally set coverage threshold in pipeline settings
