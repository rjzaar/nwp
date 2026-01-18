# GitLab Composer Package Registry

This guide explains how to use GitLab's built-in Composer Package Registry to host private Drupal profiles, modules, and themes. This enables proper dependency management for custom code like the AVC profile.

## Overview

GitLab's Package Registry provides a private Composer repository that:
- Hosts packages privately on your GitLab server
- Supports proper versioning with git tags
- Provides caching and faster installs than VCS repositories
- Integrates with CI/CD for automated publishing

## Prerequisites

1. **GitLab Server** - Set up via `./setup.sh` (select GitLab components)
2. **GitLab API Token** - Configured in `.secrets.yml`
3. **Valid composer.json** - In your package repository

## Quick Start

### 1. Setup (One-Time)

Run the NWP setup and select "GitLab Composer Registry":

```bash
./setup.sh
# Select: GitLab Composer Registry
```

This verifies your GitLab connection and shows usage instructions.

### 2. Prepare Your Package

Ensure your package has a valid `composer.json`:

```json
{
    "name": "rjzaar/avc_profile",
    "type": "drupal-profile",
    "description": "AV Commons - Collaborative workflow platform",
    "license": "GPL-2.0-or-later",
    "require": {
        "goalgorilla/open_social": "^12.4"
    }
}
```

**Important**: The `name` field must follow the `vendor/package` format.

### 3. Publish a Package

Create a git tag and publish:

```bash
# In your package directory
cd ~/avcgs
git tag v1.0.0
git push origin v1.0.0

# From NWP directory, publish to registry
cd ~/nwp
source lib/git.sh
gitlab_composer_publish "$HOME/avcgs" "v1.0.0" "root/avc"
```

**Output:**
```
[i] Publishing rjzaar/avc_profile (v1.0.0) to GitLab Package Registry...
[✓] Published rjzaar/avc_profile to GitLab Package Registry (ID: 42)
```

### 4. Use the Package

Add the GitLab repository to your project's `composer.json`:

```json
{
    "repositories": {
        "gitlab": {
            "type": "composer",
            "url": "https://git.nwpcode.org/api/v4/group/1/-/packages/composer/packages.json"
        }
    },
    "require": {
        "rjzaar/avc_profile": "^1.0"
    }
}
```

Then install:

```bash
composer require rjzaar/avc_profile:^1.0
```

## Available Functions

After sourcing `lib/git.sh`, these functions are available:

| Function | Description |
|----------|-------------|
| `gitlab_composer_publish` | Publish a package to the registry |
| `gitlab_composer_list` | List published packages |
| `gitlab_composer_configure_client` | Add registry to a project |
| `gitlab_composer_create_deploy_token` | Create read-only access token |
| `gitlab_composer_check` | Verify registry is accessible |
| `gitlab_composer_repo_url` | Get the repository URL |

### Function Details

#### gitlab_composer_publish

Publish a Composer package to GitLab Package Registry.

```bash
gitlab_composer_publish "/path/to/package" "tag-or-branch" ["project-path"]
```

**Parameters:**
- `path` - Path to package directory (must contain composer.json)
- `ref` - Git tag (e.g., "v1.0.0") or branch name (e.g., "main")
- `project-path` - Optional GitLab project path (e.g., "root/avc")

**Examples:**
```bash
# Publish a tagged version
gitlab_composer_publish "$HOME/avcgs" "v1.0.0" "root/avc"

# Publish from current branch (dev version)
gitlab_composer_publish "$HOME/avcgs" "main" "root/avc"
```

#### gitlab_composer_list

List packages in the registry.

```bash
# List all packages
gitlab_composer_list

# List packages for a specific project
gitlab_composer_list "root/avc"
```

#### gitlab_composer_configure_client

Configure a Composer project to use the GitLab registry.

```bash
gitlab_composer_configure_client "/path/to/project" "group-name"
```

This adds the repository to `composer.json` and configures authentication.

#### gitlab_composer_create_deploy_token

Create a read-only deploy token for CI/CD or other systems.

```bash
gitlab_composer_create_deploy_token "root/avc" "my-deploy-token"
```

**Important:** Save the token value - it's only shown once!

## Authentication

### Personal Access Token (Default)

The functions use the token from `.secrets.yml`:

```yaml
gitlab:
  api_token: "glpat-xxxxxxxxxxxxxxxxxxxx"
```

### Deploy Tokens (For CI/CD)

Create project-specific tokens with limited scope:

```bash
gitlab_composer_create_deploy_token "root/avc" "ci-read-packages"
```

Then use in `auth.json`:

```json
{
    "http-basic": {
        "git.nwpcode.org": {
            "username": "ci-read-packages",
            "password": "deploy-token-value"
        }
    }
}
```

### CI/CD Job Token

In GitLab CI pipelines, use `$CI_JOB_TOKEN`:

```yaml
before_script:
  - composer config http-basic.git.nwpcode.org gitlab-ci-token "$CI_JOB_TOKEN"
```

## CI/CD Integration

### Auto-Publish on Tag

Add to your package's `.gitlab-ci.yml`:

```yaml
stages:
  - test
  - publish

test:
  stage: test
  script:
    - composer install
    - composer test

publish:
  stage: publish
  script:
    - 'curl --fail-with-body --header "Job-Token: $CI_JOB_TOKEN" --data tag=$CI_COMMIT_TAG "${CI_API_V4_URL}/projects/$CI_PROJECT_ID/packages/composer"'
  rules:
    - if: $CI_COMMIT_TAG
```

This automatically publishes to the registry when you push a git tag.

### Consuming Packages in CI

```yaml
build:
  stage: build
  before_script:
    # Configure authentication
    - composer config http-basic.git.nwpcode.org gitlab-ci-token "$CI_JOB_TOKEN"
  script:
    - composer install
```

## Using with NWP Recipes

The AVC recipe in `example.nwp.yml` demonstrates GitLab Composer integration:

```yaml
recipes:
  avc:
    source: goalgorilla/social_template:dev-master
    profile: avc_profile
    webroot: html
    auto: y
    composer_repositories:
      gitlab:
        type: composer
        url: "${GITLAB_COMPOSER_URL}"
```

Set `GITLAB_COMPOSER_URL` in `.secrets.yml` or as an environment variable.

## Getting the Repository URL

The URL format is:
```
https://git.<domain>/api/v4/group/<GROUP_ID>/-/packages/composer/packages.json
```

Get your group ID:

```bash
source lib/git.sh
gitlab_get_group_id "root"  # Returns: 1
```

Or get the full URL:

```bash
gitlab_composer_repo_url "root"
# Returns: https://git.nwpcode.org/api/v4/group/1/-/packages/composer/packages.json
```

## Troubleshooting

### "Version is invalid" Error

GitLab requires valid semver versions. Ensure your git tag follows the format:
- `v1.0.0` (recommended)
- `1.0.0`
- `v1.0.0-beta1`

Invalid: `1.0.0.0`, `version-1`

### "Project not found" Error

Check the project path:

```bash
gitlab_get_project_id "root/avc"  # Should return a number
```

Verify the project exists in GitLab and you have access.

### "Unauthorized" Error

Verify your token:

```bash
gitlab_composer_check
```

Ensure the token has `api` scope for publishing or `read_api` for consuming.

### Package Not Found After Publishing

Packages are published at the group level. When consuming:

1. Use the **group** URL, not project URL
2. Ensure the group ID is correct
3. Wait a moment for the registry to update

```bash
# List packages to verify
gitlab_composer_list "root/avc"
```

## Best Practices

1. **Use semantic versioning** - Tag releases as `v1.0.0`, `v1.1.0`, etc.

2. **Publish from CI/CD** - Automate publishing when tags are pushed

3. **Use deploy tokens for consumers** - Don't share your personal access token

4. **Add auth.json to .gitignore** - Never commit authentication credentials

5. **Document dependencies** - List required packages in composer.json

## Security Considerations

- **Never commit tokens** - Use `.secrets.yml` or environment variables
- **Use minimal scopes** - Deploy tokens only need `read_package_registry`
- **Rotate tokens periodically** - Especially for production systems
- **Audit package access** - Review who can publish packages

## References

- [GitLab Composer Repository Documentation](https://docs.gitlab.com/user/packages/composer_repository/)
- [GitLab Package Registry API](https://docs.gitlab.com/api/packages/composer/)
- [Composer Repositories](https://getcomposer.org/doc/05-repositories.md)
