# F03: Visual Regression Testing

**Status:** IMPLEMENTED
**Created:** 2026-01-10
**Author:** Rob, Claude Opus 4.5
**Priority:** Low
**Estimated Effort:** 1-2 days
**Breaking Changes:** No - additive feature

---

## 1. Problem Statement

When updating Drupal themes, CSS, or template files, there is no automated way to detect
unintended visual changes. Manual visual comparison is error-prone and doesn't scale.

## 2. Proposed Solution

A `pl vrt` command that:
1. Captures baseline screenshots of configured pages using headless Chrome
2. Compares current state against baselines
3. Generates diff images highlighting changes
4. Reports pass/fail with configurable threshold

## 3. Usage

```bash
# Capture baseline screenshots
pl vrt baseline mysite

# Run comparison against baseline
pl vrt compare mysite

# Show diff report
pl vrt report mysite

# Update baseline (accept current as new baseline)
pl vrt accept mysite
```

## 4. Configuration

In nwp.yml:
```yaml
sites:
  mysite:
    vrt:
      pages:
        - url: /
          name: homepage
        - url: /user/login
          name: login
        - url: /node/1
          name: sample-content
      threshold: 0.1          # 0.1% pixel difference allowed
      viewport: 1920x1080
      mobile_viewport: 375x812
```

## 5. Implementation

Uses headless Chrome (via DDEV) for screenshot capture and ImageMagick for comparison.

## 6. Success Criteria

- [ ] `pl vrt baseline` captures screenshots
- [ ] `pl vrt compare` detects visual differences
- [ ] Configurable threshold for acceptable changes
- [ ] Works with DDEV sites
