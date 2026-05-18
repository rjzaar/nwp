# F31: Repo-Wide Hardening and Modernization — security enforcement, bash correctness, test coverage, doc catchup, harness tightening, 2026 best-practice alignment

**Status:** PROPOSED
**Created:** 2026-04-17
**Author:** Robert Karsten Zaar (with AI assistance)
**Priority:** High (consolidates the 2026-Q2 audit findings into a single actionable plan; unblocks honest verification claims and closes verifier-boundary enforcement gaps)
**Depends On:** F21 (distributed pipeline — phases 1–3a done, Phase 5/6 pending), F28 (unified pipeline — proposed), F26 (OIDC — proposed)
**Breaking Changes:** No (all items are additive enforcement, test coverage, documentation, or refactors preserving existing public behavior)
**Supersedes / absorbs:** `YAML_PARSER_CONSOLIDATION.md` (Phase 8 Item 31 here), parts of `P60` data-hygiene work (Phase 4 Item 11)

---

## 1. Executive Summary

### 1.1 Problem Statement

A comprehensive 2026-Q2 audit of `$HOME/nwp` and the user's Claude Code harness identified 37 concrete issues plus 6 longer-horizon opportunities. The findings cluster into six categories:

1. **Stated security model vs. implementation drift.** CLAUDE.md declares "trust flows through signatures, not machines" and "two-person approval for sensitive paths." In practice: CI signature verification is a placeholder with `allow_failure: true`; sensitive-path approval is documented but not enforced by CODEOWNERS or branch protection; ADR-0017 (verifier offline-by-default) and ADR-0019 (verifier always-on with hardware token) are in direct conflict and neither is authoritative.

2. **Bash correctness footguns.** 62 of 71 `lib/*.sh` files lack `set -euo pipefail`, while `pl` itself uses it — this drift hides failure modes. 30+ instances of `cd $var` without `|| exit` span the library. One production-critical script (`lib/live-server-setup.sh:43`) has an unquoted variable subject to word-splitting.

3. **Security-critical code without test coverage.** The new bundle sign/verify pipeline (`lib/bundle-build.sh`, `lib/bundle-verify.sh`, `lib/minisign.sh`) has 8 unit tests but no round-trip or tamper-detection tests. The OIDC email sanitizer has 6 determinism tests but no integration test that exercises the full fixture flow. The migration framework has zero tests.

4. **"99.5% machine verified" is aspirational, not empirical.** The badge computes `verified / total = 514 / 569`, but 102 items are flagged `automatable:false && verified:true` (manual checklist items misclassified), 40 infrastructure-dependent items counted as passing without being testable locally. P60 documented this; the data has not been cleaned.

5. **Documentation lags shipped features.** F21 Phases 1–3a (Headscale, mirror-store runner, ai-host LLM) shipped without a deployment guide. ADR-0019 is not listed in `docs/decisions/index.md`. The OIDC email sanitizer (shipped 2026-03-26) has no canonical reference under `docs/deployment/`. `docs/guides/mayo-avc-integration.md` still says "❌ Sanitizer (wired in later)" weeks after it landed.

6. **External 2026 landscape drift.** GitLab has shipped three high-severity CVEs in 2026-Q1; Headscale 0.29 has a breaking ACL wildcard change; Moodle 5.1 changed document root to `public/` (NWP's ss deploy scripts assume flat `/var/www/ss/`); Nitrokey 3 has emerged as a documented backup to Solo 2C+ under the same Trussed firmware; Authelia offers a certified lightweight OIDC provider that may be a better fit for F26 than Drupal-as-IdP.

### 1.2 Proposed Solution

A 10-phase hardening and modernization plan, sequenced so each phase stands alone and unblocks the next:

1. **Phase 1 — Critical security gates.** Flip CI signing enforcement from `allow_failure:true` to blocking. Resolve the ADR-0017/0019 conflict. Implement CODEOWNERS + branch protection for sensitive paths. Repair `docs/decisions/index.md`.
2. **Phase 2 — Bash correctness sweep.** Add `set -euo pipefail` to all `lib/*.sh` that lack it. Fix every `cd $var` without a guard. Fix the `live-server-setup.sh:43` word-splitting bug.
3. **Phase 3 — Security-critical test coverage.** Add round-trip and tamper-detection tests for bundle sign/verify. Add an integration test for the OIDC email sanitizer. Add tests for the migration framework. Enable `02-backup-restore.bats` in CI.
4. **Phase 4 — Honest verification badge.** Clean P60 data issues (102 inconsistencies). Split the single "machine verified" number into category-specific percentages (Unit / Integration / Manual).
5. **Phase 5 — Shipped-feature documentation catchup.** Write the F21 Phases 1–3a deployment guide. Add ADR-0019 to the index. Create the canonical sanitizer reference under `docs/deployment/`. Update stale status claims in existing guides.
6. **Phase 6 — Proposal hygiene.** Move or renumber the three off-convention files (`nwp-deep-analysis.md`, `transcript-video-editing-proposal.md`, `YAML_PARSER_CONSOLIDATION.md`). Add a dependency-graph diagram to the roadmap showing F21→F26→F28→F29→F30.
7. **Phase 7 — Claude harness hardening.** Add pre-commit hook blocking `nwp.yml`. Add pre-commit warning on sensitive-path edits. Add a PreToolUse Claude Code hook denying bash access to prod paths. Delete redundant `claude-conversation-monitor.sh`. Annotate stale memory entries.
8. **Phase 8 — External dependency patching.** Verify GitLab ≥18.10.3. Plan Headscale 0.29 upgrade (wildcard ACL audit). Document Nitrokey 3 as backup in ADR-0019. Note Moodle 5.1 `public/` docroot implications for ss. Decide F26 IdP architecture (Drupal-as-IdP vs. Authelia). Evaluate ntfy as Gotify replacement.
9. **Phase 9 — Operational runbooks and CI lint.** Create `docs/runbooks/key-rotation.md`. Enable shellcheck and phpstan as blocking CI stages. Consolidate the duplicate YAML parser into `lib/yaml.sh` with test coverage.
10. **Phase 10 — Roadmap reorganization and polish.** Split the 1496-line `roadmap.md` into status + context files. Refresh `KNOWN_ISSUES.md`. Clean up the Claude Code allow-list bloat. Address remaining low-priority style items.

A separate "Watch and Evaluate" section lists six longer-horizon opportunities (SLSA L2-equivalent via in-toto, deploy-rs magic-rollback, Drupal Recipes, ShellSpec, bash-to-Python migration, F26 Authelia pivot) that are tracked but not committed in this proposal.

### 1.3 Design Rationale

- **Phases are ordered by blast-radius reduction, not by effort.** Phase 1 closes the widest-open security gaps (unsigned artifacts, unenforced CODEOWNERS, ambiguous verifier posture). Phase 2 prevents silent bash failures from masking incidents. Phase 3 stops security-critical code from merging without tests. Everything else builds on that foundation.
- **Each phase is independently shippable.** Gates between phases are soft — Phase 4 does not block Phase 5 — but within a phase the items are tightly coupled (e.g., flipping CI `allow_failure` only after minisign tests exist).
- **Items are numbered 1–37 globally, not restarted per phase.** This preserves traceability back to the 2026-Q2 audit findings. Each item maps one-to-one to an audit recommendation.
- **The proposal does not absorb F26's architectural decision.** Phase 8 Item 27 flags Authelia vs. Drupal-as-IdP as a decision point. If the decision goes toward Authelia, F26 is amended (not by F31); if it stays Drupal-as-IdP, F26 proceeds unchanged.
- **P60 data-hygiene work is absorbed here** (Phase 4) because the remediation is small and tightly coupled to Phase 1 Item 1 (honest CI gates). The badge-accuracy story should not spread across two proposals.

---

## 2. Current State (2026-04-17)

| Area | Status |
|------|--------|
| Signed-bundle pipeline | `lib/bundle-build.sh` + `lib/bundle-verify.sh` shipped (commit 77b16c1). CI verification is a placeholder with `allow_failure:true`. `BUNDLE_NO_SIGN=1` escape hatch exists in build script. |
| OIDC email sanitizer | `lib/sanitizers/oidc-email.sh` shipped (commit 77b16c1). 6 unit tests; no integration tests; referenced in `mayo-avc-integration.md` as "wired in later" despite having shipped. |
| `lib/*.sh` strict mode | 9 of 71 files use `set -euo pipefail`. `pl` entry point uses it. Dominant pattern in `lib/common.sh` is no strict mode. |
| `cd $var` guards | 30+ unguarded instances confirmed in `lib/sanitizers/mayo.sh:316`, `lib/database-router.sh:196`, `lib/preflight.sh:146`, and others. |
| Bundle test coverage | 8 tests in `tests/unit/test-bundle.bats`. Minisign verification marked optional. No round-trip or tamper-detection tests. |
| Migration framework tests | Zero. `lib/migrate-schema.sh` and `lib/migrations/{site,global,server}/` are uncovered. |
| Integration tests in CI | All gated on `ENABLE_DDEV_TESTS=true`, which is not set in `.github/workflows/build-test-deploy.yml`. |
| Verification badge | Claims 99.5% machine-verified. Actual category split: unit tests ~30% of workflows; integration disabled in CI; 102 documented data-consistency issues unfixed per P60. |
| ADR-0019 in index | Missing. `docs/decisions/index.md` does not list it; CLAUDE.md references it as authoritative. |
| Sanitizer docs under `docs/deployment/` | None. References scattered across `guides/production-site-integration.md`, `guides/mayo-avc-integration.md`, `guides/verifier-operations.md`. |
| F21 Phase 1–3a deployment guide | Not written. Only interim SSH port-forward pattern documented in `docs/guides/local-llm.md` (marked deprecated). |
| CODEOWNERS / branch protection | None. CLAUDE.md §239–252 lists sensitive paths advisory-only. |
| Claude Code harness | Two hooks active (`check-session-size.sh`, `play-chime.sh`). `claude-conversation-monitor.sh` present but unused and contains `pkill Claude` logic. No PreToolUse hook for prod-path denial. |
| GitLab self-hosted version | Unknown to this audit. March 2026 CVEs (CVSS 8.1 email-hijack, CVSS 7.7 GraphQL DoS) require ≥18.10.3 / ≥18.9.5 / ≥18.8.9. |
| Headscale version | Unknown. Current is 0.29 with breaking ACL wildcard change. |
| Off-convention proposal files | `nwp-deep-analysis.md` (2026-01-10, post-mortem in proposals/), `transcript-video-editing-proposal.md` (no F##), `YAML_PARSER_CONSOLIDATION.md` (uppercase, no F##). |
| roadmap.md | 1496 lines, 18 phases, ad-hoc numbering, mixes narrative and status tables. |
| KNOWN_ISSUES.md | Last updated 2026-01-20; says "65 failing tests" while current badge claims 99.5%. |

---

## 3. Audit Methodology

The findings in this proposal came from six parallel audits run on 2026-04-17:

1. **Bash code quality review** — 143 shell scripts, ~77K lines across `lib/` and `scripts/commands/`. Grep-based scan for strict-mode adoption, `cd` guards, word-splitting hazards, duplication, and test coverage.
2. **Documentation review** — 210 files under `docs/` checked for staleness, redundancy, missing operational guides for shipped features, ADR health, and proposal-format consistency.
3. **Proposal coherence review** — F21–F30 dependency graph analysis, threat-model compliance check, naming-convention audit, supersession chains.
4. **Security and infrastructure review** — ADR-0017/0018/0019 alignment, verifier boundary integrity, minisign enforcement, sanitizer fail-closed behavior, CI/CD exposure, key rotation runbook presence.
5. **Claude Code harness review** — `$HOME/.claude/settings.json`, `settings.local.json`, hooks, memory system, skills, plugin list, session size.
6. **Tests and verification audit** — BATS framework coverage, `.verification.yml` data integrity, badge computation, CI pipeline vs `pl verify` divergence, P50–P60 proposals delivered vs aspirational.

Plus **external best-practices research** on 12 topics covering minisign alternatives, hardware keys, Drupal 11/12, Moodle 5.x, self-hosted GitLab, Headscale, immutable deployment, Claude Code 2026 features, bash testing at scale, self-hosted observability, OIDC IdPs, and supply-chain attestation.

---

## 4. Phased Execution

Items are globally numbered 1–37 for traceability to the audit. Phase boundaries group items by coupling, not by effort.

### Phase 1 — Critical Security Gates

Goal: close the widest-open security gaps before anything else ships.

1. **Flip CI signature verification to blocking.** `.gitlab-ci.yml:114-123` has `allow_failure: true` with comment "flip to false once signing is live". Change to `false`. Gate `BUNDLE_NO_SIGN=1` in `lib/bundle-build.sh` behind an explicit test-mode env flag so it cannot be set in production. Depends on Phase 3 Item 7 landing first so the test suite proves the gate works. **Effort:** 30 min (after Item 7).

2. **Resolve ADR-0017 vs ADR-0019 conflict.** ADR-0017 (Accepted) says the verifier is offline-by-default; ADR-0019 (Proposed, one day later) says the verifier is an always-on Headscale peer. Pick one, mark the other Superseded or Rejected. If 0019 wins, every checkbox in its hardening checklist (aide, auditd, fail2ban, LUKS verify, unattended-upgrades scope) must land before the verifier goes online. **Effort:** decision + 2 hr if 0019 wins.

3. **Add CODEOWNERS and branch protection for sensitive paths.** CLAUDE.md §239–252 lists paths requiring two-person approval (`lib/auth*`, `lib/*secret*`, `lib/bundle*`, `lib/minisign*`, `lib/sanitize*`, `scripts/commands/live*`, `scripts/commands/stg2prod*`, `.gitlab-ci.yml`, `CLAUDE.md`, `keys/**`, `.env*`). Create `.gitlab/CODEOWNERS`; enable branch protection on `main` requiring CODEOWNER approval for matching paths. **Effort:** 1 hr.

13. **Add ADR-0019 to `docs/decisions/index.md`.** Currently missing; CLAUDE.md references it as authoritative. **Effort:** 5 min.

### Phase 2 — Bash Correctness Sweep

Goal: stop silent failures from masking incidents.

4. **Add `set -euo pipefail` to all `lib/*.sh` that lack it.** 62 of 71 files affected. Where a library intentionally needs looser handling (e.g., `lib/verify-runner.sh` continues on test failures), use scoped `set +e` blocks with comments explaining why. **Effort:** 2 hr.

5. **Fix every unguarded `cd $var`.** 30+ instances confirmed. Convert each to `cd "$var" || exit 1` or wrap in a function that returns on failure. Run shellcheck to catch further cases. **Effort:** 1 hr.

6. **Fix word-splitting bug in `lib/live-server-setup.sh:43`.** Production-critical script has `ssh $ssh_opts` unquoted. Convert to an array: `ssh "${ssh_opts[@]}"`. **Effort:** 5 min.

### Phase 3 — Security-Critical Test Coverage

Goal: no security-critical code merges without round-trip + tamper tests.

7. **Add bundle sign/verify round-trip tests.** Extend `tests/unit/test-bundle.bats` with: (a) sign a bundle and verify, (b) tamper with a byte and confirm verification fails, (c) remove the signature and confirm verification fails closed, (d) wrong-key verification fails closed. Remove the "minisign optional" caveat. **Effort:** 2 hr.

8. **Add OIDC email sanitizer integration test.** Create `tests/integration/test-oidc-sanitizer-fixture.bats`: seed a Drupal DB with known emails, run the sanitizer, assert no raw emails survive and that hashed outputs are consistent across runs. Gate on `ENABLE_DDEV_TESTS=true` but include in the Phase 3 Item 10 CI enablement. **Effort:** 2 hr.

9. **Add migration framework tests.** Create `tests/unit/test-migrate-schema.bats` covering global, server, and site migrations with rollback scenarios. `lib/migrations/{site,global,server}/` all uncovered today. **Effort:** 2 hr.

10. **Enable at least `02-backup-restore.bats` in CI.** Change gating in `.github/workflows/build-test-deploy.yml` to set `ENABLE_DDEV_TESTS=true` for PRs touching `lib/backup*`, `lib/restore*`, `scripts/commands/backup*`, `scripts/commands/restore*`, and on nightly runs. Accept ~10 min CI overhead. **Effort:** 4 hr (including DDEV-in-CI setup).

### Phase 4 — Honest Verification Badge

Goal: make the 99.5% claim survive scrutiny.

11. **Clean P60 data issues and split the badge.** Fix the 102 `automatable:false && verified:true` inconsistencies. Move the 40 infrastructure-dependent items into an `environment_dependent: true` category. Split the single `machine_verified` badge into three: `Unit Tests`, `Integration Tests`, `Manual Checklist`. Update `scripts/commands/badges.sh` and the README badge block. Absorbs P60 remediation; close P60 on completion. **Effort:** half day.

### Phase 5 — Shipped-Feature Documentation Catchup

Goal: close the gap between what shipped and what is documented.

12. **Write F21 Phases 1–3a deployment guide.** Create `docs/deployment/f21-build-deploy-pipeline.md` covering: Headscale bootstrap, ACL template, GitLab Runner on the mirror-store, ai-host LLM health probes, verifier bootstrap skeleton (Phase 5). Replace deprecated SSH port-forward pattern in `docs/guides/local-llm.md` with a pointer to the new guide. **Effort:** 3 hr.

14. **Create canonical sanitizer reference.** `docs/deployment/sanitization.md`, linking to per-site sanitizers (mayo, ss, avc) and the OIDC email module. Remove duplicated content from `guides/production-site-integration.md` and `guides/mayo-avc-integration.md`; leave pointers. **Effort:** 1 hr.

15. **Update stale status claims.** `docs/guides/mayo-avc-integration.md` says "❌ Sanitizer (drush sql:sanitize will be wired in later)" — the OIDC email sanitizer shipped 2026-03-26. Update. Audit other guides for similar drift while in there. **Effort:** 30 min (10 min for the known case, 20 for the sweep).

### Phase 6 — Proposal Hygiene

Goal: every proposal follows the naming convention, every dependency is visible.

16. **Triage off-convention proposal files.** Three files break `F##/P##/X##` naming:
    - `nwp-deep-analysis.md` (2026-01-10 post-mortem audit report, many recommendations already implemented) → move to `docs/archive/DEEP_ANALYSIS_2026-01-10.md` with a link from `docs/archive/README.md`.
    - `transcript-video-editing-proposal.md` → assign an F## if actively pursued, or move to `docs/experimental/` if not.
    - `YAML_PARSER_CONSOLIDATION.md` → absorb into Phase 9 Item 31 of this proposal; delete the standalone file with a redirect note.

    **Effort:** 30 min.

17. **Add dependency-graph diagram to roadmap.** The F21→F26→F28→F29→F30 dependency chain is currently only visible by reading each proposal. Add a mermaid or ASCII graph near the top of `docs/governance/roadmap.md` showing explicit edges. Makes F30's milestone-gate execution order (phases 1–5 before 6–10) visible at a glance. **Effort:** 1 hr.

### Phase 7 — Claude Code Harness Hardening

Goal: make AI-distrust enforcement deterministic, not documentation-based.

18. **Pre-commit hook blocking `nwp.yml` commits.** CLAUDE.md forbids it; hook enforces. `.git/hooks/pre-commit` rejects any `git diff --cached --name-only | grep -q '^nwp\.yml$'`. **Effort:** 30 min.

19. **Pre-commit warning on sensitive-path edits.** Same hook prints a red warning (not blocking) when diff touches `lib/auth*`, `lib/*secret*`, `lib/sanitize*`, `lib/bundle*`, `lib/minisign*`, `scripts/commands/live*`, `scripts/commands/stg2prod*`. Prompts for "yes, I reviewed this" confirmation. **Effort:** 20 min (extension of Item 18).

20. **PreToolUse Claude Code hook denying bash access to prod paths.** Per 2026 Claude Code guidance, PreToolUse hooks are deterministic. Deny any bash command referencing `keys/prod_*`, `.secrets.data.yml`, or known prod IPs (the public Linode IP and any entries in `.secrets.data.yml` that this user-level hook cannot read — use a public allowlist kept in plain files). Install in `$HOME/.claude/settings.json`. **Effort:** 1 hr.

21. **Delete `claude-conversation-monitor.sh`.** Unused, redundant with `check-session-size.sh`, contains a `pkill Claude` hazard. **Effort:** 5 min.

22. **Annotate stale memory entries.** The operator's per-project memory file for the ai-host LLM baseline (2026-04-09) cites F21 Phase 3a / X02 Phase 0 state that may have moved. Either refresh from current project state or add a "verify before citing — last confirmed 2026-04-09" banner. Audit MEMORY.md index for other >30-day-old entries referencing in-flight phases. **Effort:** 15 min.

### Phase 8 — External Dependency Patching

Goal: align with 2026-Q2 best-practice advisories.

23. **Verify `<gitlab-host>` GitLab version.** 2026-Q1 CVEs: CVSS 8.1 email-hijack (March), CVSS 7.7 GraphQL DoS (March), 2FA bypass (January), SSH DoS (January). Patched in 18.10.3 / 18.9.5 / 18.8.9. Also verify Runner is scoped (not instance-wide) and uses Docker executor, not shell. **Effort:** 1 hr (check + patch plan).

24. **Plan Headscale 0.29 upgrade.** Breaking change: wildcard `*` now resolves to CGNAT (100.64.0.0/10) instead of all IPs. Audit current ACL wildcards before upgrading. Evaluate the new SSH `check` action — would let us gate inter-node SSH (mirror-store↔ai-host) via OIDC with hardware-key step-up. **Effort:** research 1 hr, plan 2 hr.

25. **Evaluate ntfy as Gotify replacement.** ntfy now has first-party iOS (via APNs), richer ACLs, emoji, broader integration matrix. Same self-hosted-simple-push niche as Gotify; Apache-licensed. Decision only; implementation is a separate proposal if we switch. **Effort:** 30 min research.

26. **Document Nitrokey 3 as backup to Solo 2C+ in ADR-0019.** Same Trussed firmware (preserves CLAUDE.md's open-firmware rule), more active vendor, community-flagged concerns about Solokeys project health. Adds a documented fallback path before it's urgent. **Effort:** 15 min (single ADR paragraph).

27. **Decide F26 IdP architecture.** Drupal-as-OIDC-provider is a contrib module maintained outside core and re-implements functionality a dedicated IdP does better. Authelia is <30MB, YAML-driven, certified OIDC provider, Apache 2.0. Making Drupal and Moodle both OIDC *clients* of Authelia removes Drupal-as-IdP as a security-critical code path. Gather data; decide; if reversing, amend F26 (not by F31). **Effort:** 4 hr research + ADR.

28. **Note Moodle 5.1 `public/` docroot change for ss.** NWP memory asserts ss root is flat at `/var/www/ss/`. Moodle 5.1 moves the docroot to `public/`. Add a migration note to the F21/F29 pipeline for when ss upgrades past 5.0. Not urgent; document the gotcha now so it doesn't bite later. **Effort:** 15 min.

### Phase 9 — Operational Runbooks and CI Lint

Goal: every irreversible action has a runbook; every lint runs in CI.

29. **Create `docs/runbooks/key-rotation.md`.** Sections: (a) minisign key rotation (generate new, re-sign all published artifacts, update the verifier's public key); (b) Solo 2C+ loss recovery (enroll backup, revoke old prod SSH key, rotate WireGuard PSK); (c) Headscale auth key rotation; (d) GitLab PAT / deploy token rotation; (e) SSH host key rotation on new server provisioning (mayo1 baseline). ADR-0019 mentions this as a requirement but the runbook does not exist. **Effort:** half day.

30. **Enable shellcheck and phpstan as blocking CI stages.** `phpstan.neon` exists but is not in CI. Shellcheck is referenced in source comments but not enforced. Add stages to `.gitlab-ci.yml` and `.github/workflows/build-test-deploy.yml` that fail on high-severity issues. Baseline existing violations (fix or waive with documented reason). **Effort:** 2 hr (setup) + 2–4 hr (baseline).

31. **Consolidate the duplicate YAML parser into `lib/yaml.sh`.** `YAML_PARSER_CONSOLIDATION.md` documents the need; ~150 lines of near-identical AWK parsing is duplicated across `lib/common.sh`, `lib/install-common.sh`, `lib/linode.sh`, `lib/cloudflare.sh`, `lib/b2.sh`, `pl`, and at least one more. Create `lib/yaml.sh` with a tested API (`yaml_get`, `yaml_set`, `yaml_has`, `yaml_list_keys`). Add `tests/unit/test-yaml.bats` covering: empty values, quoted values, comments, arrays, multi-line scalars, malformed inputs. Migrate callers incrementally; preserve behavior exactly. Absorbs `YAML_PARSER_CONSOLIDATION.md`. **Effort:** 1 day.

### Phase 10 — Roadmap Reorganization and Polish

Goal: low-priority cleanup after the higher-blast-radius work lands.

32. **Split `roadmap.md` into status + context files.** 1496 lines mix live status tables with narrative. Split into `docs/governance/roadmap-status.md` (authoritative table, updated per release) and `docs/governance/roadmap-context.md` (prose rationale, force analysis, long-form reasoning). Keep per-proposal detail in `docs/proposals/`. Add cross-links. **Effort:** 3 hr.

33. **Refresh `KNOWN_ISSUES.md`.** Last updated 2026-01-20; says "65 failing tests" while badge claims 99.5%. Replace with current issues (if any) or mark "All tracked issues resolved as of 2026-04-17; see docs/proposals/ for active work." **Effort:** 15 min.

34. **Slim down Claude Code allow-list.** 383 entries in `$HOME/.claude/settings.local.json`, many are verbose bash fragments rather than tool+method patterns. Consolidate using the shipped `less-permission-prompts` skill. Expect ~50 entries after consolidation. **Effort:** 2 hr.

35. **Fix `cat file | grep` anti-patterns.** 17 instances in `lib/` and `pl`. Replace with direct `grep file`. Style only; no correctness issue. **Effort:** 30 min.

36. **Standardize `[ ]` vs `[[ ]]` in new code.** 1894 `[ ]` vs 884 `[[ ]]` across lib/. Don't mass-rewrite; add a shellcheck rule preferring `[[ ]]` for new files only. **Effort:** 10 min (shellcheck config only).

37. **Keep P52 visible as Rejected.** No action — current housekeeping pattern is correct. Noted here to prevent accidental archival in a future cleanup sweep. **Effort:** 0.

---

## 5. Watch and Evaluate (not committed in F31)

Six longer-horizon opportunities identified in the audit but not scoped into this proposal. Each becomes a separate F## proposal if/when committed.

- **SLSA L2-equivalent via in-toto JSON + CycloneDX SBOM, co-signed with the existing minisign key.** Preserves the offline-verifier boundary (no Fulcio/Rekor round-trip), gives supply-chain provenance without adopting the full Sigstore stack.
- **deploy-rs "magic rollback" pattern** — after the verifier pushes a bundle, self-verify reachability and auto-revert to previous symlink on failure. Directly applicable to NWP's atomic deploy model without adopting Nix.
- **Drupal core Recipes for the avc profile.** Drupal 11.2+ ships Recipes as the successor to install profiles. avc could be authored as a Recipe, composable across sites.
- **ShellSpec for new `lib/` function-level tests.** BATS's weak spot is function-level testing; ShellSpec does it natively. Don't migrate existing tests; adopt for new coverage only.
- **Bash-to-Python migration at the 77K-line scale.** Keep `pl` as bash orchestration, but state-machine code (resolvers, migration framework, server provisioning) would benefit from a typed language long-term. Python 3 is always present in NWP's target environments. Not urgent.
- **F26 Authelia pivot.** Tracked as Phase 8 Item 27 of F31 (decision only). If reversing, F26 is amended, not by F31.

---

## 6. Files To Create / Modify

**Created:**
- `.gitlab/CODEOWNERS` (Phase 1 Item 3)
- `docs/deployment/f21-build-deploy-pipeline.md` (Phase 5 Item 12)
- `docs/deployment/sanitization.md` (Phase 5 Item 14)
- `docs/runbooks/key-rotation.md` (Phase 9 Item 29)
- `docs/archive/DEEP_ANALYSIS_2026-01-10.md` (moved from `docs/proposals/nwp-deep-analysis.md`, Phase 6 Item 16)
- `docs/governance/roadmap-status.md` and `docs/governance/roadmap-context.md` (Phase 10 Item 32; original `roadmap.md` replaced)
- `lib/yaml.sh` (Phase 9 Item 31)
- `tests/integration/test-oidc-sanitizer-fixture.bats` (Phase 3 Item 8)
- `tests/unit/test-migrate-schema.bats` (Phase 3 Item 9)
- `tests/unit/test-yaml.bats` (Phase 9 Item 31)
- `.git/hooks/pre-commit` (Phase 7 Items 18, 19)
- PreToolUse hook entry in `~/.claude/settings.json` (Phase 7 Item 20)

**Modified:**
- `.gitlab-ci.yml` — `allow_failure:false` on signing; shellcheck + phpstan stages (Phase 1 Item 1, Phase 9 Item 30)
- `.github/workflows/build-test-deploy.yml` — enable `ENABLE_DDEV_TESTS=true` for relevant paths (Phase 3 Item 10)
- `lib/bundle-build.sh` — gate `BUNDLE_NO_SIGN` behind test-mode flag (Phase 1 Item 1)
- `lib/*.sh` — strict mode + `cd` guards (Phase 2 Items 4, 5)
- `lib/live-server-setup.sh` — quote `$ssh_opts` (Phase 2 Item 6)
- `tests/unit/test-bundle.bats` — round-trip + tamper tests (Phase 3 Item 7)
- `scripts/commands/badges.sh` — split badge categories (Phase 4 Item 11)
- `.verification.yml` — clean 102 data inconsistencies (Phase 4 Item 11)
- `docs/decisions/index.md` — add ADR-0019 (Phase 1 Item 13)
- `docs/decisions/0019-*.md` — document Nitrokey 3 fallback (Phase 8 Item 26)
- `docs/decisions/0017-*.md` or `0019-*.md` — resolve conflict with a Superseded/Rejected marker (Phase 1 Item 2)
- `docs/guides/mayo-avc-integration.md` — fix stale sanitizer status (Phase 5 Item 15)
- `docs/guides/local-llm.md` — redirect to F21 deployment guide (Phase 5 Item 12)
- `CLAUDE.md` — refresh sensitive-paths list if changes discovered during CODEOWNERS work (Phase 1 Item 3)
- `KNOWN_ISSUES.md` — refresh (Phase 10 Item 33)
- `~/.claude/settings.local.json` — allow-list slim-down (Phase 10 Item 34)
- Various `lib/*.sh` and `pl` — replace `cat file | grep` (Phase 10 Item 35)

**Deleted:**
- `~/.claude/hooks/claude-conversation-monitor.sh` (Phase 7 Item 21)
- `docs/proposals/YAML_PARSER_CONSOLIDATION.md` (absorbed; Phase 9 Item 31)
- `docs/proposals/nwp-deep-analysis.md` (moved to archive; Phase 6 Item 16)
- `docs/proposals/transcript-video-editing-proposal.md` (moved or renumbered; Phase 6 Item 16)

---

## 7. Verification Checklist

Phase 1:
- [ ] Item 1: `git grep 'allow_failure: true' .gitlab-ci.yml` returns nothing for signing-related jobs
- [ ] Item 1: `BUNDLE_NO_SIGN=1` refused in bundle-build.sh unless test-mode flag also set
- [ ] Item 2: One of ADR-0017 / ADR-0019 marked Superseded or Rejected; the other is the sole authority
- [ ] Item 2: If 0019 authoritative, every hardening-checklist item is checked
- [ ] Item 3: `.gitlab/CODEOWNERS` exists; branch protection enforces it on `main`
- [ ] Item 13: `docs/decisions/index.md` lists ADR-0019

Phase 2:
- [ ] Item 4: `grep -L 'set -euo pipefail' lib/*.sh` returns only the documented exceptions
- [ ] Item 5: Shellcheck SC2164 reports zero issues across `lib/` and `scripts/`
- [ ] Item 6: `shellcheck lib/live-server-setup.sh` is clean

Phase 3:
- [ ] Item 7: `tests/unit/test-bundle.bats` includes tamper-detection test; CI runs it
- [ ] Item 8: `tests/integration/test-oidc-sanitizer-fixture.bats` runs in CI on PR touching sanitizer code
- [ ] Item 9: `tests/unit/test-migrate-schema.bats` covers all three migration namespaces
- [ ] Item 10: CI runs `02-backup-restore.bats` on nightly + relevant PRs

Phase 4:
- [ ] Item 11: `.badges.json` has three separate categories; README displays all three
- [ ] Item 11: `.verification.yml` has zero `automatable:false && verified:true` pairs

Phase 5:
- [ ] Item 12: `docs/deployment/f21-build-deploy-pipeline.md` exists and is linked from roadmap
- [ ] Item 14: `docs/deployment/sanitization.md` exists; guides redirect to it
- [ ] Item 15: mayo-avc-integration.md sanitizer status corrected

Phase 6:
- [ ] Item 16: Three off-convention files resolved (archived or renumbered)
- [ ] Item 17: roadmap.md shows explicit dependency graph

Phase 7:
- [ ] Item 18: `.git/hooks/pre-commit` rejects `nwp.yml`; tested with a staged nwp.yml
- [ ] Item 19: Same hook prints warning on sensitive-path edit
- [ ] Item 20: `~/.claude/settings.json` PreToolUse hook denies bash on prod paths; tested with attempted command
- [ ] Item 21: `claude-conversation-monitor.sh` deleted
- [ ] Item 22: Memory index has no >30-day-old entries without a verify-before-use note

Phase 8:
- [ ] Item 23: GitLab on `<gitlab-host>` is ≥18.10.3; Runner is Docker-executor + scoped
- [ ] Item 24: Headscale upgrade plan written; ACL wildcard audit completed before upgrade
- [ ] Item 25: ntfy evaluation decision recorded (adopt / defer / reject)
- [ ] Item 26: ADR-0019 includes Nitrokey 3 backup path paragraph
- [ ] Item 27: F26 IdP decision recorded (Drupal-as-IdP / Authelia); F26 amended if reversing
- [ ] Item 28: Moodle 5.1 `public/` docroot gotcha noted in F21 or ss migration runbook

Phase 9:
- [ ] Item 29: `docs/runbooks/key-rotation.md` exists with all five sections
- [ ] Item 30: CI shellcheck stage is green or has documented waivers; same for phpstan
- [ ] Item 31: All callers use `lib/yaml.sh`; `YAML_PARSER_CONSOLIDATION.md` deleted; test-yaml.bats passes

Phase 10:
- [ ] Item 32: `roadmap-status.md` and `roadmap-context.md` exist; old monolith removed
- [ ] Item 33: `KNOWN_ISSUES.md` reflects reality on 2026-04-17 or later
- [ ] Item 34: `settings.local.json` allow-list is <100 entries
- [ ] Item 35: Zero `cat file | grep` patterns in `lib/` or `pl`
- [ ] Item 36: Shellcheck rule for `[[ ]]` preference on new files present

---

## 8. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Phase 1 Item 1 (flip CI signing to blocking) breaks in-flight MRs | Medium — existing MRs may not sign artifacts yet | Land Phase 3 Item 7 (round-trip tests) first; announce the flip in a pinned issue; give 48 hr for in-flight MRs to rebase |
| Phase 1 Item 2 (ADR-0017 vs 0019 decision) blocks verifier-dependent work | High — F28 deployment depends on which ADR wins | Set a hard decision deadline (1 week); if indecision persists, default to 0017 (offline-by-default) as the safer posture |
| Phase 2 Item 4 (add strict mode) exposes latent bugs that were silently ignored | Medium — tests may fail that previously passed | Run full test suite after each batch; fix or scope-limit strict mode as issues surface |
| Phase 3 Item 10 (enable DDEV in CI) slows CI by ~10 min | Low — acceptable trade-off | Limit trigger to `lib/backup*`, `lib/restore*` path filters; run full matrix nightly only |
| Phase 4 Item 11 (honest badge) makes the project "look worse" | Low — but honesty is the stated goal of P60 | Frame in changelog as "replacing one aspirational number with three measurable ones"; link to P60 for history |
| Phase 7 Item 20 (PreToolUse hook) blocks legitimate debugging | Medium — may hit false positives | Start with warn-mode (log + prompt) before switching to deny-mode; audit `~/.claude/prompts.log` for false positives over 1 week |
| Phase 9 Item 31 (YAML consolidation) introduces a regression | High — YAML parsing is load-bearing for `pl`, install scripts, and server provisioning | Migrate callers one at a time; keep the old inline parser as `_legacy_yaml_*` for one release cycle; tests must prove bit-for-bit output equivalence |
| Phase 8 Item 27 (F26 Authelia pivot) rewrites F26 mid-flight | Medium — F26 is PROPOSED, not in flight; low actual cost | Treat as a gate: decide before F26 Phase 1 starts. If F26 Phase 1 has started, defer decision and run F26 as designed |
| Phase 10 Item 32 (roadmap split) breaks external bookmarks | Low — few external links to the roadmap | Keep `roadmap.md` as a redirect stub pointing to both new files for one release |

---

## 9. Dependency Graph

```
Phase 1 (Security Gates)
  Item 1 (CI signing block) ────depends──> Phase 3 Item 7 (round-trip tests)
  Item 2 (ADR resolution)   ────gates────> F28 execution
  Item 3 (CODEOWNERS)       ────independent
  Item 13 (ADR index)       ────independent

Phase 2 (Bash Correctness)
  Items 4, 5, 6 ────independent of other phases; run in parallel

Phase 3 (Test Coverage)
  Item 7 ────unblocks Phase 1 Item 1
  Item 8 ────depends──> Phase 3 Item 10 (CI DDEV enablement)
  Item 9 ────independent
  Item 10 ────enables Items 8 and the future backup-restore assertions

Phase 4 (Honest Badge)
  Item 11 ────absorbs P60; depends on Phase 3 Items 7–10 so the new categories have real data

Phase 5 (Doc Catchup)
  Items 12, 14, 15 ────independent

Phase 6 (Proposal Hygiene)
  Items 16, 17 ────independent

Phase 7 (Claude Harness)
  Items 18, 19 ────share the same pre-commit hook
  Item 20 ────independent (Claude settings)
  Items 21, 22 ────housekeeping

Phase 8 (External Patching)
  Item 23 ────urgent; independent
  Item 24 ────gates any Headscale upgrade work
  Items 25, 26, 27, 28 ────independent research / decisions

Phase 9 (Runbooks + CI Lint)
  Item 29 ────independent
  Item 30 ────enables Phase 2 verification automatically
  Item 31 ────depends on Phase 2 (strict mode surfaces YAML parser bugs)

Phase 10 (Polish)
  Items 32–37 ────all independent; land opportunistically
```

External blocker: **Phase 8 Item 27** (F26 IdP decision) may amend F26; do not start F26 Phase 1 until Item 27 is recorded.

---

## 10. Acceptance

F31 is complete when:

- All 37 items in §4 have their verification-checklist boxes (§7) ticked.
- `.verification.yml` category split (Phase 4 Item 11) shows ≥95% unit, ≥70% integration, 100% manual-reviewed for categories labeled manual.
- CI signing gate is blocking in production (Phase 1 Item 1) with no `allow_failure: true` on security-gate jobs.
- CODEOWNERS (Phase 1 Item 3) is enforced on `main` for every path in CLAUDE.md §239–252.
- Runbook (Phase 9 Item 29) is rehearsed at least once (dry-run of minisign key rotation against a throwaway artifact).
- PreToolUse hook (Phase 7 Item 20) has been in warn-mode for ≥1 week with no false-positive blocks before switching to deny-mode.
- F31 itself moves to COMPLETE in `docs/reports/milestones.md` and is linked from the next release tag's CHANGELOG.

---

## 11. Relationship to Other Proposals

- **Absorbs:** `YAML_PARSER_CONSOLIDATION.md` (Phase 9 Item 31) and the outstanding P60 data-hygiene work (Phase 4 Item 11). Both should be marked SUPERSEDED BY F31 on F31 acceptance.
- **Unblocks:** F28 (Unified Pipeline) by resolving the ADR-0017/0019 conflict (Phase 1 Item 2) and by enforcing CI signing (Phase 1 Item 1). F30 (Content Federation) by enforcing the sensitive-path CODEOWNERS (Phase 1 Item 3), which every federation-content MR must pass through.
- **Gates:** F26 (OIDC) Phase 1 start — do not begin F26 until Phase 8 Item 27 IdP decision is recorded.
- **Does not conflict with:** F21, F29, X02, X03. Hardening is orthogonal to their implementation.
- **Recommended sequencing with in-flight work:** F31 Phases 1–3 run in parallel with F21 Phase 4+ and F29 Phase 6+. F31 Phase 8 Item 27 decision precedes F26 Phase 1. F31 Phase 9 Item 31 (YAML consolidation) precedes any further install-script additions to avoid piling on the duplicated parsers.
