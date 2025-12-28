# GitLab Runner Guide

Complete guide for configuring and using GitLab Runners for CI/CD.

## What is GitLab Runner?

GitLab Runner is the agent that executes CI/CD jobs defined in `.gitlab-ci.yml` files. Think of it as the worker that actually runs your tests, builds, and deployments.

## Architecture

```
┌─────────────┐       ┌──────────────┐       ┌─────────────┐
│   GitLab    │ ─────>│ GitLab Runner│ ─────>│   Docker    │
│   Server    │<──────│   (Agent)    │<──────│ Container   │
└─────────────┘       └──────────────┘       └─────────────┘
  Manages jobs        Executes jobs        Provides isolated
                                           build environment
```

## Runner Installation

If you used `gitlab_create_server.sh`, the Runner is already installed. Verify:

```bash
ssh gitlab@YOUR_SERVER 'gitlab-runner --version'
```

### Manual Installation (if needed)

```bash
ssh gitlab@YOUR_SERVER
curl -L https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh | sudo bash
sudo apt-get install -y gitlab-runner
```

## Runner Registration

### Step 1: Get Registration Token

**For Instance-Wide Runners (Admin):**
1. Login to GitLab as admin
2. Go to: Admin Area (wrench icon) > CI/CD > Runners
3. Copy the registration token under "Register an instance runner"

**For Project-Specific Runners:**
1. Go to your project
2. Settings > CI/CD > Runners
3. Expand "Specific runners"
4. Copy the registration token

### Step 2: Register the Runner

SSH to your GitLab server and run:

```bash
ssh gitlab@YOUR_SERVER
cd gitlab-scripts
./gitlab-register-runner.sh --token YOUR_REGISTRATION_TOKEN
```

**With Custom Options:**
```bash
./gitlab-register-runner.sh \
  --url https://gitlab.example.com \
  --token glrt-ABC123... \
  --executor docker \
  --tags "docker,linux,build" \
  --name "main-runner"
```

### Step 3: Verify Registration

In GitLab UI:
- Admin Area > CI/CD > Runners
- You should see your runner listed with a green circle

On the server:
```bash
ssh gitlab@YOUR_SERVER 'sudo gitlab-runner list'
```

## Executor Types

### Docker Executor (Default - Recommended)

**Best for:** Most use cases
**Pros:**
- Isolated build environments
- Each job runs in a fresh container
- Easy dependency management
- Multiple language support

**How it works:**
1. GitLab sends job to Runner
2. Runner pulls Docker image
3. Job executes in container
4. Container is destroyed after job

**Example `.gitlab-ci.yml`:**
```yaml
test:
  image: node:18
  script:
    - npm install
    - npm test
```

### Shell Executor

**Best for:** Simple scripts, system-level tasks
**Pros:**
- Faster (no container overhead)
- Direct access to server resources
- Good for deployment scripts

**Cons:**
- No isolation between jobs
- Dependencies must be installed on host
- Security concerns if running untrusted code

**Example `.gitlab-ci.yml`:**
```yaml
deploy:
  tags:
    - shell
  script:
    - ./deploy.sh
```

### Kubernetes Executor

**Best for:** Large scale, already using Kubernetes
**Note:** Requires existing Kubernetes cluster (not covered in this guide)

## Runner Configuration

### Basic Configuration

Edit runner config:
```bash
ssh gitlab@YOUR_SERVER
sudo nano /etc/gitlab-runner/config.toml
```

**Example config:**
```toml
concurrent = 1  # Number of jobs to run simultaneously

[[runners]]
  name = "main-runner"
  url = "https://gitlab.example.com"
  token = "RUNNER_TOKEN"
  executor = "docker"
  [runners.docker]
    image = "alpine:latest"
    privileged = false
    volumes = ["/cache"]
```

### Increase Concurrent Jobs

For better performance on multi-core servers:

```toml
concurrent = 4  # Run up to 4 jobs at once
```

Restart runner:
```bash
sudo gitlab-runner restart
```

### Docker-in-Docker (DinD)

To build Docker images inside CI jobs:

```toml
[[runners]]
  [runners.docker]
    privileged = true  # Required for Docker-in-Docker
    volumes = ["/certs/client", "/cache"]
```

**Example job:**
```yaml
build-image:
  image: docker:latest
  services:
    - docker:dind
  script:
    - docker build -t myapp:latest .
    - docker push myapp:latest
```

## Tags and Job Routing

Tags determine which runner executes which jobs.

### Assign Tags to Runner

During registration:
```bash
./gitlab-register-runner.sh --tags "docker,linux,build,test"
```

Or edit config:
```toml
[[runners]]
  tags = ["docker", "linux", "build"]
```

### Use Tags in CI/CD

```yaml
unit-tests:
  tags:
    - docker
    - linux
  script:
    - npm test

deploy-production:
  tags:
    - shell
    - production
  script:
    - ./deploy.sh
```

**Best Practices:**
- Use specific tags for different environments (dev, staging, prod)
- Tag by capability (docker, kubernetes, shell)
- Tag by platform (linux, windows, macos)

## Multiple Runners

### Why Multiple Runners?

- **Separation:** Development vs Production
- **Performance:** Distribute load
- **Specialization:** Different executors for different jobs
- **Security:** Isolate sensitive deployments

### Register Additional Runners

```bash
# Register a production deployment runner
./gitlab-register-runner.sh \
  --token glrt-XYZ789... \
  --executor shell \
  --tags "shell,deploy,production" \
  --name "production-deployer"

# Register a build runner
./gitlab-register-runner.sh \
  --token glrt-ABC123... \
  --executor docker \
  --tags "docker,build" \
  --name "build-runner"
```

### List All Runners

```bash
sudo gitlab-runner list
```

## Common CI/CD Examples

### Node.js Project

```yaml
# .gitlab-ci.yml
image: node:18

stages:
  - test
  - build

test:
  stage: test
  script:
    - npm install
    - npm test
  tags:
    - docker

build:
  stage: build
  script:
    - npm install
    - npm run build
  artifacts:
    paths:
      - dist/
  tags:
    - docker
```

### Python Project

```yaml
# .gitlab-ci.yml
image: python:3.11

stages:
  - test
  - lint

test:
  stage: test
  script:
    - pip install -r requirements.txt
    - pytest
  tags:
    - docker

lint:
  stage: lint
  script:
    - pip install flake8
    - flake8 .
  tags:
    - docker
```

### Docker Build

```yaml
# .gitlab-ci.yml
build-docker:
  image: docker:latest
  services:
    - docker:dind
  script:
    - docker build -t myapp:$CI_COMMIT_SHA .
    - docker tag myapp:$CI_COMMIT_SHA myapp:latest
  tags:
    - docker
```

## Monitoring Runners

### Check Runner Status

```bash
ssh gitlab@YOUR_SERVER 'sudo gitlab-runner status'
```

### View Logs

```bash
ssh gitlab@YOUR_SERVER 'sudo journalctl -u gitlab-runner -f'
```

### GitLab UI

- Admin Area > CI/CD > Runners
- Green circle = online
- Gray circle = offline
- Click runner for details

## Troubleshooting

### Runner Not Picking Up Jobs

**Check runner status:**
```bash
sudo gitlab-runner verify
```

**Restart runner:**
```bash
sudo gitlab-runner restart
```

**Check job tags:**
- Job tags must match runner tags
- Or runner must accept untagged jobs

### Docker Executor Issues

**Permission denied:**
```bash
sudo usermod -aG docker gitlab-runner
sudo gitlab-runner restart
```

**Image pull errors:**
- Check internet connectivity
- Verify Docker Hub access
- Use `docker pull IMAGE` to test

### Jobs Stuck in "Pending"

**Causes:**
- No runners available
- Tag mismatch
- Runner offline
- Concurrent job limit reached

**Solutions:**
- Check runner status in UI
- Verify tags match
- Increase `concurrent` limit

## Security Best Practices

### 1. Separate Runners by Environment

```bash
# Development runner (less restrictive)
./gitlab-register-runner.sh \
  --tags "dev,test" \
  --name "dev-runner"

# Production runner (more restrictive)
./gitlab-register-runner.sh \
  --tags "prod,deploy" \
  --name "prod-runner" \
  --executor shell  # More control
```

### 2. Protected Runners

For production deployments:
1. Go to: Admin Area > CI/CD > Runners
2. Click on runner
3. Check "Protected"
4. Now only protected branches can use this runner

### 3. Locked Runners

For project-specific runners:
1. Settings > CI/CD > Runners
2. Click runner
3. Check "Lock to current projects"

### 4. Disable Privileged Mode

Unless Docker-in-Docker is needed:
```toml
[[runners]]
  [runners.docker]
    privileged = false
```

### 5. Limit Concurrent Jobs

Prevent resource exhaustion:
```toml
concurrent = 2  # Limit based on server resources
```

## Performance Optimization

### 1. Use Caching

```yaml
# .gitlab-ci.yml
test:
  cache:
    key: ${CI_COMMIT_REF_SLUG}
    paths:
      - node_modules/
  script:
    - npm install
    - npm test
```

### 2. Docker Layer Caching

Use registry for caching:
```yaml
build:
  image: docker:latest
  services:
    - docker:dind
  before_script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
  script:
    - docker pull $CI_REGISTRY_IMAGE:latest || true
    - docker build --cache-from $CI_REGISTRY_IMAGE:latest -t $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA .
    - docker push $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
```

### 3. Use Smaller Images

```yaml
# Instead of:
image: node:18

# Use alpine:
image: node:18-alpine
```

### 4. Parallel Jobs

```yaml
test:
  parallel: 4
  script:
    - npm test
```

## Upgrading Runners

### Check Current Version

```bash
ssh gitlab@YOUR_SERVER 'gitlab-runner --version'
```

### Upgrade Runner

```bash
ssh gitlab@YOUR_SERVER
sudo apt-get update
sudo apt-get install gitlab-runner
sudo gitlab-runner restart
```

## Unregistering Runners

### Remove Single Runner

```bash
ssh gitlab@YOUR_SERVER
sudo gitlab-runner unregister --name runner-name
```

### Remove All Runners

```bash
sudo gitlab-runner unregister --all-runners
```

## Advanced Topics

### Autoscaling Runners

For large-scale operations, GitLab Runner supports autoscaling with:
- Docker Machine
- Kubernetes
- AWS/GCP/Azure

**Note:** Beyond scope of this guide. See [GitLab Autoscale Documentation](https://docs.gitlab.com/runner/configuration/autoscale.html).

### Custom Executor

Create custom executors for specialized environments.

## Support Resources

- [GitLab Runner Documentation](https://docs.gitlab.com/runner/)
- [CI/CD Examples](https://docs.gitlab.com/ee/ci/examples/)
- [GitLab CI/CD Variables](https://docs.gitlab.com/ee/ci/variables/)
- [GitLab Runner Advanced Configuration](https://docs.gitlab.com/runner/configuration/advanced-configuration.html)
