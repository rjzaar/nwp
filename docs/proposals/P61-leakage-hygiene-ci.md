# P61: Leakage Hygiene CI

**Status:** PROPOSED
**Created:** 2026-05-09
**Author:** Robert Karsten Zaar (with AI assistance)
**Priority:** High (must land before F33 / F34 / F32 commits become public; gates the public release)
**Depends On:** None (this proposal is the foundation)
**Breaking Changes:** No (additive; pre-commit hook + CI step)
**Estimated Effort:** ~4 phases; one weekend
**Architecture decision records:** [ADR-0021](../decisions/0021-public-only-repo-scope.md)

> **Why this proposal exists.** The public/private boundary specified by [ADR-0021](../decisions/0021-public-only-repo-scope.md) needs mechanical enforcement, not maintainer discipline. P61 installs a `gitleaks` pre-commit hook (locally; can be bypassed) plus a CI hard-fail step (cannot be bypassed) with a custom ruleset for operator-specific patterns. After P61 lands, no new commit to a public repo can introduce hostname / personal-name / hardcoded-path leakage without an explicit policy override.

---

## 1. Executive Summary

A `gitleaks` ruleset committed to the repo root (`.gitleaks.toml`) defines patterns that must not appear in committed files: literal hostnames bound by the operator's role manifest, hardcoded `/home/<username>/` paths, organisation names that belong only in the private overlay, plus the standard credential patterns from gitleaks defaults.

The ruleset is enforced at two layers:

- **Pre-commit hook** via the `pre-commit` framework (locally; offers fast feedback; bypassable with `--no-verify` for emergency).
- **CI hard-fail step** via GitLab CI / GitHub Actions (cannot be bypassed; merge to `main` is blocked on any finding).

Custom rules live in `.gitleaks.toml`; allowlist exceptions for legitimate references (template files, history archives, role-vocabulary documentation) live in `.gitleaksignore`. The infrastructure also supports the per-author audit recommended by the operator's separate copyright work: `bin/audit-authors.sh` enumerates non-operator authors in the git history and produces a classification template.

After P61 lands, every subsequent commit to the public repo is gated; the public-private boundary becomes mechanical.

## 2. Goals

- **G1.** A pre-commit hook runs on every `git commit` and refuses commits that match the ruleset.
- **G2.** CI fails the build on any push that introduces a match against the ruleset, blocking merge to `main`.
- **G3.** The custom ruleset covers all operator-specific identifiers documented in the role-label vocabulary (see [F34](F34-role-label-proposal-rewrite.md)) plus path/name patterns.
- **G4.** Allowlist exceptions are explicit, narrow, and easy to audit (`.gitleaksignore` + per-rule `path` filters).
- **G5.** A `bin/audit-authors.sh` enumerates non-operator authors for the per-author audit recommended in the operator's separate copyright work.
- **G6.** The pre-commit infrastructure is documented for contributors; copy-pasteable install steps in `CONTRIBUTING.md`.

## 3. Non-Goals

- This proposal does **not** retrospectively scrub existing history. The operator has elected to restart the public repository (single fresh commit); historical scrubbing becomes moot. Any future need for retrospective scrubbing is a separate operation using `git filter-repo`.
- This proposal does **not** define what the role labels are; that is [ADR-0020](../decisions/0020-tiered-architecture-model.md).
- This proposal does **not** rewrite existing proposals; that is [F34](F34-role-label-proposal-rewrite.md).
- This proposal does **not** itself remove the operator's per-site directories from the public repo; that is [F33](F33-repository-topology-refactor.md).

## 4. Architecture

### 4.1 The custom ruleset

`.gitleaks.toml` at the repo root extends the gitleaks defaults with operator-specific patterns:

```toml
# .gitleaks.toml — committed to the public NWP repository
title = "NWP leakage gate"

[extend]
useDefault = true   # inherits AWS / GCP / GitHub / Slack / etc. credential rules

[[rules]]
id = "operator-home-path"
description = "Hardcoded operator home directory leak"
regex = '''/home/[a-z][a-z0-9_-]+/'''
tags = ["leak", "path"]

[[rules]]
id = "internal-hostname-fqdn"
description = "Internal hostname (.home / .local / .tunnel) leak"
regex = '''\b[a-z][a-z0-9-]+\.(home|local|tunnel)\b'''
tags = ["leak", "hostname"]

[[rules]]
id = "internal-bare-hostname"
description = "Internal bare hostname leak (operator's role-bound names)"
# These are the literal hostnames bound to roles in the operator's instance manifest.
# When a contributor adds a new role-bound hostname, add it here.
regex = '''\b(mini|metabox|met|mons|carlo|mmt)\b'''
tags = ["leak", "hostname"]
# Limit scope to text-y files; adding to a hardcoded shell variable name will fire
path = '''(?i).*\.(md|markdown|rst|txt|yml|yaml|json|toml|sh|bash|py|php|js|ts|html)$'''

[[rules]]
id = "operator-organisation"
description = "Operator-specific organisation name leak"
# These names appear only in the private overlay; never in public artefacts.
# Adjust this list when the operator's private inventory changes.
regex = '''(?i)\b(mazenod|mazenod\s+college|oblate|omi)\b'''
tags = ["leak", "organisation"]

[[rules]]
id = "live-internal-domain"
description = "Live internal domain leak"
regex = '''\b\w+\.(ddev\.site|nwpcode\.org|mayostudios\.org)\b'''
tags = ["leak", "domain"]
# Allow the example domain
path = '''^(?!.*\b(example|placeholder|README)\b).*$'''
```

### 4.2 The allowlist

`.gitleaksignore` lists narrowly-scoped exceptions:

```
# .gitleaksignore — committed
# Format: <commit-sha>:<file-path>:<rule-id>:<line>
# Allowlist for files that legitimately reference the operator's identifiers.

# Role-vocabulary doc lists the canonical hostnames in a "do not use these in public" warning;
# the doc itself must reference them to explain the rule.
docs/reference/role-vocabulary.md:internal-bare-hostname

# History-archive notice in CHANGELOG.md mentions the pre-restart archive remote (one line).
CHANGELOG.md:operator-organisation
```

Allowlist entries are **per-file + per-rule**, never per-pattern; each entry includes a brief rationale comment. Reviewers can audit allowlist entries quickly.

### 4.3 Pre-commit hook

`.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.21.0
    hooks:
      - id: gitleaks
        args: ['protect', '--staged', '--config=.gitleaks.toml']
```

Installed by contributors via `pre-commit install` once after cloning. Documented in `CONTRIBUTING.md`.

### 4.4 CI hard-fail

`.gitlab-ci.yml` (the operator's primary CI) and `.github/workflows/leakage-check.yml` (for any contributor running GitHub mirrors) both include:

```yaml
# .gitlab-ci.yml fragment
leakage-check:
  stage: lint
  image: zricethezav/gitleaks:latest
  script:
    - gitleaks detect --source . --config=.gitleaks.toml --redact --verbose --exit-code 1
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == "main"
```

Merge to `main` is blocked on this job's success. The job is non-bypassable from the contributor side.

### 4.5 Per-author audit infrastructure

`bin/audit-authors.sh` enumerates non-operator authors in the git log and produces a classification template:

```bash
#!/usr/bin/env bash
# bin/audit-authors.sh — list non-operator authors and produce a classification template

OPERATOR_NAMES_REGEX='Robert Karsten Zaar|Rob Zaar|Robert Zaar|Robert K Zaar|rjzaar'

git log --all --format='%aN <%aE>' \
  | sort -u \
  | grep -vE "${OPERATOR_NAMES_REGEX}" \
  | while IFS= read -r author; do
    count=$(git log --all --author="${author%% <*}" --oneline | wc -l)
    echo "## ${author}"
    echo "Commits: ${count}"
    echo "Sample: $(git log --all --author="${author%% <*}" --oneline | head -3)"
    echo "Classification: [ ] (a) explicit acceptance  [ ] (b) de minimis  [ ] (c) gap"
    echo "---"
  done
```

Output is reviewable for the per-author audit recommended by the operator's separate copyright work.

## 5. Phases

### Phase 1 — Author and commit the ruleset

**Goal:** `.gitleaks.toml` and `.gitleaksignore` exist at the repo root.

**Tasks:**
- [ ] Author `.gitleaks.toml` with the rules in §4.1.
- [ ] Author `.gitleaksignore` with the initial allowlist in §4.2.
- [ ] Run `gitleaks detect` once locally against the current working tree; record findings.
- [ ] If findings exist: do not commit yet; coordinate with [F33](F33-repository-topology-refactor.md) and [F34](F34-role-label-proposal-rewrite.md) to clean the working tree first.

**Definition of done:** `gitleaks detect --source . --config=.gitleaks.toml` returns zero findings against the working tree.

### Phase 2 — Install pre-commit framework + hook

**Goal:** Local `git commit` invocations run `gitleaks protect --staged`.

**Tasks:**
- [ ] Author `.pre-commit-config.yaml` per §4.3.
- [ ] Run `pre-commit install` in the operator's working copy.
- [ ] Document the install procedure in `CONTRIBUTING.md` ("Before contributing, run `pip install pre-commit && pre-commit install`").
- [ ] Tests: stage a file with a hardcoded `/home/<username>/` path; confirm the pre-commit hook refuses the commit.

**Definition of done:** Pre-commit hook fires on staged changes; refuses leaky commits; `pre-commit run --all-files` against the current working tree passes.

### Phase 3 — Install CI hard-fail step

**Goal:** GitLab CI / GitHub Actions block merge to `main` on any leakage finding.

**Tasks:**
- [ ] Add the `leakage-check` job to `.gitlab-ci.yml` per §4.4.
- [ ] Add `.github/workflows/leakage-check.yml` for any GitHub mirror.
- [ ] Configure GitLab branch protection on `main` to require the `leakage-check` job to pass.
- [ ] Tests: push a branch that introduces a known violation; confirm the CI job fails and merge is blocked.

**Definition of done:** Merge to `main` is blocked on `leakage-check` success; the job runs in under two minutes.

### Phase 4 — Per-author audit infrastructure + CONTRIBUTING.md update

**Goal:** Contributor docs explain the gate and the audit infrastructure exists.

**Tasks:**
- [ ] Author `bin/audit-authors.sh` per §4.5.
- [ ] Author `CONTRIBUTING.md` section "Leakage Gate" explaining: what the gate does; how to install the pre-commit hook; what to do if the gate fires (legitimate examples need allowlist entries with rationale; otherwise the content needs rewriting).
- [ ] Author `CONTRIBUTING.md` section "License Acceptance" stating the dual `CC0-1.0 OR MIT` licence and the DCO `Signed-off-by` requirement (the operator's separate copyright work specifies the wording).
- [ ] Run `bin/audit-authors.sh` and store the output for the per-author audit follow-up.

**Definition of done:** A new contributor can read `CONTRIBUTING.md`, install the pre-commit hook, and submit a clean PR without leakage; the per-author audit output is in hand for the copyright follow-up.

## 6. Test plan

- **Pre-commit fires on staged leakage:** stage a file containing `/home/test-user/foo`, attempt commit, confirm refusal.
- **Pre-commit allows clean staged content:** stage a file with no matches, confirm commit succeeds.
- **CI fails on pushed leakage:** push a branch with a known leak, confirm `leakage-check` fails.
- **CI passes on clean push:** push a clean branch, confirm `leakage-check` succeeds.
- **Allowlist works:** add a legitimate reference to the role-vocabulary doc, confirm `gitleaks` reports it but does not fail (because allowlisted).
- **Audit script produces classification template:** run `bin/audit-authors.sh` against a checkout containing test commits from multiple authors; confirm output format matches the template.

## 7. Rollback plan

- **Phase 1 rollback:** `git rm .gitleaks.toml .gitleaksignore`. Subsequent commits are no longer gated; existing commits unaffected.
- **Phase 2 rollback:** `pre-commit uninstall`; or remove `.pre-commit-config.yaml`. Local commits no longer gated.
- **Phase 3 rollback:** remove the `leakage-check` job; relax branch protection. CI no longer enforces.
- **Phase 4 rollback:** revert `CONTRIBUTING.md` changes; delete `bin/audit-authors.sh`.

The gate is additive at every layer; rollback at any phase leaves the codebase in a working state.

## 8. Open questions

- **OQ-1.** Should the hostname rule cover only the operator's specific role-bound hostnames (current design) or apply more broadly to any short-token hostname? Current design is narrower (less false-positive churn); broader design catches more (more contributor friction). Recommendation: narrow ruleset, expand on demand.
- **OQ-2.** Should `.gitleaksignore` entries be commit-pinned (with a SHA) or path-pinned (any commit at that path)? Commit-pinning is more secure (an exception covers exactly one historical line); path-pinning is more maintainable. Recommendation: path-pinning, because the gate is forward-looking.
- **OQ-3.** Should the gate also run `trufflehog` for entropy-based detection? `trufflehog` catches things `gitleaks` doesn't but is slower. Recommendation: add as a weekly scheduled job, not a per-commit gate.

## 9. Phase status

| Phase | Status | Notes |
|---|---|---|
| 1 | Not started | — |
| 2 | Not started | — |
| 3 | Not started | — |
| 4 | Not started | — |

## 10. Related decisions and proposals

- [ADR-0021](../decisions/0021-public-only-repo-scope.md) — establishes the public/private scope this gate enforces.
- [F33](F33-repository-topology-refactor.md) — moves per-site directories to the private overlay; this gate ensures the move is not undone by future commits.
- [F34](F34-role-label-proposal-rewrite.md) — rewrites existing proposals; this gate ensures rewrites stay clean.
- The operator's separate copyright work (private; not referenced here by path) — supplies the dual-licence wording, the DCO text, and the per-author audit requirement that this proposal's infrastructure supports.
