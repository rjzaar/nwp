# NWP End-to-End (E2E) Tests

This directory contains end-to-end tests that provision real Linode instances to test complete NWP workflows.

## Overview

E2E tests provide full integration testing by:
1. Provisioning fresh Linode instances
2. Installing NWP from scratch
3. Running complete workflows (install, backup, deploy, etc.)
4. Cleaning up resources automatically

## Test Categories

### 1. Fresh Install Tests (`test-fresh-install.sh`)
- Test NWP installation on clean Ubuntu server
- Verify DDEV setup
- Test first site creation
- **Cost**: ~$0.01 per run (2 hour instance)

### 2. Production Deployment Tests (`test-production.sh`)
- Test staging → production deployment
- Test production → staging sync
- Test rollback scenarios
- **Cost**: ~$0.05 per run (2x instances, 3 hours)

### 3. Multi-Coder Tests (`test-multi-coder.sh`)
- Test multi-developer environment
- Test coder-setup.sh provisioning
- Test GitLab integration
- **Cost**: ~$0.10 per run (3x instances, 4 hours)

### 4. Disaster Recovery Tests (`test-disaster-recovery.sh`)
- Test backup/restore workflows
- Test data integrity
- Test recovery procedures
- **Cost**: ~$0.03 per run (2x instances, 2 hours)

## Prerequisites

### Required
- Linode API token in `.secrets.yml`:
  ```yaml
  linode:
    api_token: "your-token-here"
  ```
- SSH key at `~/.ssh/nwp` or configured in `.secrets.yml`

### Optional (for GitLab tests)
- GitLab API token
- GitLab instance URL

## Running E2E Tests

### Run all E2E tests
```bash
./scripts/commands/run-tests.sh -e
```

### Run specific E2E test
```bash
./tests/e2e/test-fresh-install.sh
```

### Run with cleanup disabled (for debugging)
```bash
CLEANUP=false ./tests/e2e/test-fresh-install.sh
```

### Run in CI
```bash
./scripts/commands/run-tests.sh --ci -e
```

## Test Structure

```
tests/e2e/
├── README.md                     # This file
├── helpers/
│   ├── linode-helpers.sh        # Linode provisioning helpers
│   ├── cleanup-helpers.sh       # Resource cleanup helpers
│   └── assertion-helpers.sh     # E2E-specific assertions
├── fixtures/
│   └── test-site-config.yml     # Test site configurations
├── test-fresh-install.sh        # Fresh install E2E tests
├── test-production.sh           # Production deployment tests
├── test-multi-coder.sh          # Multi-coder tests
└── test-disaster-recovery.sh    # Backup/restore tests
```

## Safety Features

### Automatic Cleanup
- All instances are tagged with `test-nwp-JOBID`
- Auto-cleanup runs after tests complete
- Cleanup also runs on failure
- Orphaned instances auto-delete after 8 hours

### Cost Controls
- Instance lifetime limits enforced
- Test timeout mechanisms
- Failed test cleanup
- Cost estimation before run

### Safeguards
- Dry-run mode available
- Test environment isolation
- No access to production secrets
- Read-only GitLab operations

## CI Integration

E2E tests run in GitLab CI on nightly schedules:

```yaml
e2e:fresh-install:
  stage: e2e
  script:
    - ./tests/e2e/test-fresh-install.sh
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
  after_script:
    - ./tests/e2e/helpers/cleanup-helpers.sh
```

## Cost Management

### Estimated Monthly Costs

| Test Type | Frequency | Instance Type | Duration | Monthly Cost |
|-----------|-----------|---------------|----------|--------------|
| Fresh Install | Nightly | Nanode ($5) | 2h | ~$5 |
| Production | Weekly | 2x Standard ($20) | 3h | ~$7 |
| Multi-coder | Weekly | 3x Mixed ($25) | 4h | ~$8 |
| Disaster Recovery | Weekly | 2x Nanode ($10) | 2h | ~$3 |
| **Total** | | | | **~$23/month** |

### Cost Optimization
- Use smallest viable instance types
- Implement strict timeouts
- Auto-cleanup orphaned instances
- Share instances across test suites when possible

## Debugging

### View test logs
```bash
tail -f .logs/e2e-test-*.log
```

### Keep test instances for inspection
```bash
CLEANUP=false ./tests/e2e/test-fresh-install.sh
```

### SSH to test instance
```bash
# Instance info is in .logs/e2e-test-*.log
ssh -i ~/.ssh/nwp root@<instance-ip>
```

### Manual cleanup
```bash
./tests/e2e/helpers/cleanup-helpers.sh --force
```

## Implementation Status

- [ ] Fresh install tests
- [ ] Production deployment tests
- [ ] Multi-coder tests
- [ ] Disaster recovery tests
- [ ] Linode helper library
- [ ] Cleanup automation
- [ ] CI integration
- [ ] Cost tracking

## Future Enhancements

1. **Parallel Test Execution**
   - Run multiple E2E tests in parallel
   - Instance pooling

2. **Test Recording**
   - Screen recording of tests
   - Automated screenshots
   - Failure artifact collection

3. **Performance Benchmarking**
   - Track deployment times
   - Database performance metrics
   - Resource usage tracking

4. **Multi-Region Testing**
   - Test cross-region deployments
   - Test failover scenarios
   - Test geo-distribution

## References

- [COMPREHENSIVE_TESTING_PROPOSAL.md](../../docs/COMPREHENSIVE_TESTING_PROPOSAL.md)
- [Linode API Documentation](https://www.linode.com/docs/api/)
- [NWP Testing Documentation](../../docs/TESTING.md)
