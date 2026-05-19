# F36: Comprehensive Codebase Improvements (2026-05 audit)

> **Historical snapshot (2026-05-19).** Written during the AVC era; most
> points still apply to NWC. Forward-looking work is tracked in
> `~/central/NWC-ARCHITECTURE.md` §13/§14 and ADRs at
> `~/nwp/sites/nwc/dev/html/profiles/custom/nwc/docs/decisions/`. AVC
> remains live as comparison per ADR-0015; this doc isn't being rewritten.

**Status:** PROPOSED
**Created:** 2026-05-18
**Author:** Robert Karsten Zaar (with AI assistance — multi-agent codebase audit)
**Priority:** Mixed (P0 → P3; see §10 prioritization matrix)
**Depends On:** none (this proposal coordinates work; phases are independently shippable)
**Breaking Changes:** none in P0–P1; some P2 items deprecate legacy parsers
**Estimated Effort:** ~6 phases over 4–8 weeks of part-time work; quick-wins phase is ~1 day
**Architecture decision records:** no new ADRs required; this proposal *implements* gaps in ADR-0015, ADR-0017, ADR-0019, ADR-0022

> **Why this proposal exists.** A multi-agent audit on 2026-05-18 (five
> parallel Explore agents covering documentation, code architecture,
> security, testing, and CI/CD) surfaced a consistent picture: the
> architecture is sound and the threat model is intact, but execution
> trails design in several load-bearing areas. The F28 verifier spine is
> half-built, ADR-0015's yq-first rule is violated in three places,
> deployment scripts are 95% duplicated across six files, and the F32 /
> F33 / F34 proposals are merged in code but still marked `PROPOSED` in
> docs/. None of these are emergencies; together they are the difference
> between "works for the operator" and "production-ready for the
> federation."

---

## 1. Executive Summary

**Overall posture: GOOD.** No critical security failures, no live data
exposure, no AI-prod boundary breaches. The paranoid threat model is
intact. The F28 / ADR-0017 distributed-pipeline design is sound; what
remains is plumbing.

**Headline recommendations (top 5):**

1. **Wire the F28 CI → verifier spine** (P0). The `lib/bundle-build.sh`
   and `lib/bundle-verify.sh` libraries are complete, but `.gitlab-ci.yml`
   has no job that calls them. The verifier has no producer.
2. **Activate signed-commit verification** (P0). `.gitlab-ci.yml:114–123`
   is a `echo "placeholder"` with `allow_failure: true`. ADR-0017's "trust
   flows through signatures" property is not yet enforced.
3. **Fix `StrictHostKeyChecking=no` in `lib/safe-ops.sh:52`** (P0). A 5-
   minute change. Persistent MITM window on every prod status check.
4. **Extract `lib/deployment-core.sh`** (P1). The six deploy scripts
   (`dev2stg`, `stg2prod`, `prod2stg`, `stg2live`, `live2stg`, `live2prod`)
   share ~4,000 lines of near-identical code. ~3,000 lines recoverable.
5. **Update F32 / F33 / F34 proposal status from PROPOSED → IMPLEMENTED**
   (P1). They are merged in code; docs say otherwise. Contributors cannot
   tell what is decided.

**Adaptive thresholds, not arbitrary numbers.** Five items in this
proposal originally carried hand-picked numeric limits (lint timeout,
verification spec size, artifact expiry, etc.). All such limits are now
delegated to a single piece of infrastructure (§6.5 — `lib/ci-stats.sh`,
rolling-window p95) so the system self-calibrates from the last 20 runs
rather than relying on operator intuition. The same infrastructure
yields two security signals (sign-job duration spikes, verification
pass-rate decay) for free.

**What NOT to touch:** §11 lists the patterns that are working
well. `pl` dispatcher, `lib/migrate-schema.sh`, `lib/ssh.sh`,
`lib/bundle-{build,verify}.sh`, the two-tier secrets split, and
`lib/sanitize.sh` are all solid — refactors here would churn working
code without improving the threat model.

---

## 2. Documentation Drift (P1 mostly, P2 in places)

### 2.1 Findings

| # | Issue | File(s) | Severity |
|---|---|---|---|
| D1 | F32 / F33 / F34 marked `PROPOSED` despite being merged | `docs/proposals/F32-*.md:3`, `F33-*.md:3`, `F34-*.md:3` | P1 |
| D2 | `COMMAND_INVENTORY.md` says 49 commands; actual is 59 | `docs/COMMAND_INVENTORY.md:5–6` | P1 |
| D3 | `version-changes.md` documents removed `--symlinks` flag as current | `docs/reports/version-changes.md:~310–320` | P2 |
| D4 | 10 commands have no entry in `docs/reference/commands/` | `avc-moodle-*`, `badges`, `bootstrap-coder`, `build`, `email`, `fix`, `migrate-secrets` | P2 |
| D5 | Operator-instance READMEs reference `./install.sh` instead of `./pl install` | `sites/avc/dev/README.md:16`, `sites/avc/stg/README.md:16` | P3 |
| D6 | `docs/README.md` claims 56% doc coverage; math doesn't reconcile with inventory | `docs/README.md:29, 80` | P2 |
| D7 | No convention distinguishing "proposal under consideration" from "implemented proposal" | repo-wide | P2 |

### 2.2 Actions

- **A-D1 (P1):** Flip status to `IMPLEMENTED` in F32 / F33 / F34, with
  inline commit references (`9f9632d`, `2017799`, `e9ad8f2` for F32;
  `1669a06` for F33; `acc9549`, `cbf9d97` for F34). 15 min total.
- **A-D2 (P1):** Re-audit `COMMAND_INVENTORY.md` against `scripts/commands/`;
  rewrite the counts and last-updated stamp. 2–3 h.
- **A-D3 (P2):** Move `--symlinks` section to a "Deprecated in v0.24"
  block in `version-changes.md`; note that root entry points were
  consolidated into `./pl` in commit `6f9921e`.
- **A-D4 (P2):** Stub out `docs/reference/commands/<name>.md` for the 10
  missing commands by extracting each script's `--help` text. 1–2 h.
- **A-D5 (P3):** Rewrite the two `sites/avc/*/README.md` files. 5 min.
- **A-D6 (P2):** Recompute and re-cite coverage percentage; or remove the
  claim entirely.
- **A-D7 (P2):** Document the convention in `docs/governance/documentation-standards.md`:
  proposals use status enum `{DRAFT, PROPOSED, ACCEPTED, IMPLEMENTED, REJECTED, SUPERSEDED}`.
  Add a CI lint that warns when a `PROPOSED` proposal has been
  referenced in five or more commits — implementation drift signal.

---

## 3. Code Architecture & Quality (P1–P2)

### 3.1 Findings

| # | Issue | Severity | Notes |
|---|---|---|---|
| C1 | Six deploy scripts share ~4,000 lines of duplicated logic | P1 | `dev2stg`, `stg2prod`, `prod2stg`, `stg2live`, `live2stg`, `live2prod` |
| C2 | Three AWK YAML parsers violate ADR-0015 (yq-first) | P1 | `pl:334–391`, `stg2prod.sh:270–282`, `prod2stg.sh` |
| C3 | `eval set -- "$PARSED"` pattern in 8 scripts | P1 | `backup`, `copy`, `delete`, `schedule`, `restore`, `security`, `stg2prod`, `live` |
| C4 | `eval "$(get_server_config ...)"` in `sync.sh:~435` | P0 | If config contains shell metacharacters, executes them |
| C5 | 7 commands lack `set -euo pipefail` | P2 | `report`, `dev2stg`, `stg2prod`, `uninstall_nwp`, `prod2stg`, `testos`, `todo` |
| C6 | Auto-sourcing in `lib/common.sh:16–32` hides dependencies | P2 | obscures which scripts depend on which libs |
| C7 | `lib/verify-*.sh` is 9 files / 6k lines with overlapping responsibilities | P2 | runner, scenarios, checkpoint, autofix, reporting, cross-validate |
| C8 | `lib/` and `scripts/lib/` are two parallel library trees with no clear boundary | P2 | confusing for contributors |
| C9 | `validate_sitename` exists but is inconsistently called | P1 | only `sync.sh` calls it reliably |

### 3.2 Actions

- **A-C1 (P1):** Extract `lib/deployment-core.sh` containing
  `show_elapsed_time`, `build_ssh_cmd`, `build_rsync_ssh_opts`,
  `get_recipe_value`, `should_run_step`. Refactor all six deploy
  scripts to source it. Estimated ~3,000 lines recovered.
- **A-C2 (P1):** Replace all three AWK parsers with `yq eval` calls. Add
  a CI grep gate: `grep -RE '^\s*awk .*yaml' scripts/ lib/` exits
  non-zero. Per ADR-0015. ~80 lines removed.
- **A-C3 (P1):** Replace `eval set -- "$PARSED"` with array-based
  argument parsing (`while [[ $# -gt 0 ]]; do case ...`). Eight files,
  ~30 min each.
- **A-C4 (P0):** Audit `sync.sh:~435`. If `get_server_config` returns
  multi-line text intended to be sourced, restructure to return values
  via `printf '%s\n' "$key=$value"` and parse via a deterministic loop,
  not `eval`.
- **A-C5 (P2):** Add `set -euo pipefail` to the seven scripts missing
  it. One line each.
- **A-C6 (P2):** Replace auto-sourcing with explicit `# Requires:`
  header comments and explicit `source` calls in each consumer. Document
  the dependency graph in `lib/README.md`.
- **A-C7 (P2):** Add `lib/verify-base.sh` as a thin façade exporting a
  single `run_verification()` entry point; existing files become
  internal-only. Reduces caller-side cognitive load.
- **A-C8 (P2):** Document the `lib/` vs `scripts/lib/` distinction in
  `lib/README.md` (a one-pager). If the distinction is meaningless,
  consolidate; if it's real, formalize.
- **A-C9 (P1):** Call `validate_sitename` at every entry point that
  accepts a site name from user input. Files: all deploy scripts plus
  `make.sh`, `copy.sh`, `delete.sh`. ~10 min per file.

---

## 4. Security & Threat Model (P0–P1)

### 4.1 Findings

| # | Issue | Severity | Notes |
|---|---|---|---|
| S1 | `StrictHostKeyChecking=no` in `lib/safe-ops.sh:52` | P0 | Persistent MITM window, not just first-connect |
| S2 | CI `verify-signature` is `echo` placeholder with `allow_failure: true` | P0 | ADR-0017's signature-trust property not enforced |
| S3 | Artifact signing key would live on AI-accessible `ci-host` (when F28 lands) | P1 | Defense-in-depth — mitigated by verifier verifying offline |
| S4 | `.gitleaks.toml` hostname rules are hand-maintained | P2 | Drift risk as infrastructure changes |
| S5 | `lib/safe-ops.sh` reads `.secrets.data.yml` on AI-accessible machines | P2 | Internal-only; no exposure unless caller logs output |

### 4.2 Actions

- **A-S1 (P0):** In `lib/safe-ops.sh:52`, change
  `StrictHostKeyChecking=no` → `StrictHostKeyChecking=accept-new` and
  point at a pinned `KnownHostsFile`. 5 min. Closes a real-network MITM
  window today.
- **A-S2 (P0, sequenced with §5):** Replace the placeholder
  `verify-signature` job (`.gitlab-ci.yml:114–123`) with a real
  `git verify-commit HEAD` step against a pinned signer keyring in
  `keys/signers/`. Flip `allow_failure: true` → `false`. Requires
  configuring commit signing first; ~2 h once keys are in place.
- **A-S3 (P1):** When F28 ships, ensure runner-artifact signing key is
  *not* the prod-trust key. Document in ADR-0017 §"Key separation" that
  ci-host signing is contained by the verifier's offline signature
  check. Consider Solo 2C+ ssh-sk for runner key later.
- **A-S4 (P2):** Generate `.gitleaks.toml` host-name rules from a
  canonical role-vocabulary YAML (per F34) at CI time. Eliminates manual
  sync.
- **A-S5 (P2):** Add an explicit doc comment to every `safe_*` function
  in `lib/safe-ops.sh`: "Reads data secrets internally — output is
  sanitized; callers must not log raw output." Consider gating on
  `${NWP_AI_CONTEXT:-}` to refuse to run when Claude-invoked.

---

## 5. CI/CD & Operational Spine (P0–P2)

### 5.1 Findings

| # | Issue | Severity |
|---|---|---|
| O1 | No CI job invokes `bundle-build.sh` → no signed artifacts ever land in Packages | P0 |
| O2 | `verify-signature` placeholder (overlaps with S2) | P0 |
| O3 | DDEV base images are `:latest`, not pinned | P1 |
| O4 | Coverage regex `'/^\s*Lines:\s*\d+.\d+\%/'` has unescaped `.` | P1 |
| O5 | No `concurrency:` blocks; preview env races possible | P1 |
| O6 | No timeouts on `lint:bash` / `lint:leakage`; no regression signal on lint slowdown | P2 |
| O7 | E2E jobs are manual placeholders with no implementation | P2 |
| O8 | Gitleaks: GitHub workflow doesn't pass `--config=.gitleaks.toml` explicitly | P2 |
| O9 | Artifact expiry mismatched to job lifecycle (build 1 h, tests 1 wk) | P3 |
| O10 | No security-vuln gate on Renovate-updated deps | P2 |

### 5.2 Actions

- **A-O1 (P0):** Add three new jobs to `.gitlab-ci.yml` after
  `security:review` (line 501): `sign-artifact:` (calls
  `lib/bundle-build.sh`), `upload-artifact:` (calls
  `scripts/commands/publish.sh`), and a `verify-bundle:` smoke job that
  immediately re-verifies the just-uploaded bundle with
  `lib/bundle-verify.sh`. This is the F28 spine the audit identified
  as missing.
- **A-O2 (P0, paired with S2):** Real signed-commit verification.
- **A-O3 (P1):** Pin `ddev/ddev-webserver` to a dated tag in
  `.gitlab-ci.yml:65` and `.github/workflows/build-test-deploy.yml:66`.
- **A-O4 (P1):** Escape the dot:
  `coverage: '/^\s*Lines:\s*\d+\.\d+\%/'`. One-character change at
  `.gitlab-ci.yml:382`.
- **A-O5 (P1):** Add `concurrency: { group: $CI_COMMIT_REF_SLUG-preview, cancel_in_progress: true }`
  on `deploy:preview` and `cleanup:preview`.
- **A-O6 (P2):** Two-layer enforcement, both delegated to `lib/ci-stats.sh`
  (§6.5). **Hard ceiling** as runaway-process backstop:
  `timeout: 30m` on every lint job (intentionally generous; never tuned).
  **Soft assertion** in `after_script`: warn if duration > 1.5 × rolling
  p95 over last 20 successful runs. Cold-start fallback: warn at 10 min
  until the rolling window has 5+ samples. No more hand-picked timeout.
- **A-O7 (P2):** Either implement the two E2E jobs (preferred) or
  remove them with a comment pointing to a future proposal. Stubbed
  jobs erode CI signal.
- **A-O8 (P2):** In `.github/workflows/leakage-check.yml:27`, set
  `GITLEAKS_CONFIG_PATH: .gitleaks.toml` explicitly so the GitHub
  mirror cannot diverge from GitLab's config.
- **A-O9 (P3):** Tie expiries to observed consumer lifetime rather than
  picked durations. After `lib/ci-stats.sh` (§6.5) is live, record
  "time-from-build to last-consumer-access" per artifact category;
  set `expire_in` to p95 + 24 h. Bootstrap defaults (until 5+ samples
  exist): build = 1 week, test = 3 days, security = 1 week.
- **A-O10 (P2):** Add a `security:dependencies` job running
  `composer audit` + `npm audit` with a high-severity threshold, gated
  on `composer.json` existence.

---

## 6. Testing & Verification Framework (P1–P2)

### 6.1 Findings

| # | Issue | Severity |
|---|---|---|
| T1 | `.verification.yml` is 33,531 lines / 1 MB; auto-generated, mostly duplicated; no growth signal | P1 |
| T2 | 6/57 commands have integration tests; 51 untested | P1 |
| T3 | 5/74 lib files have unit tests; 69 untested | P1 |
| T4 | No `teardown` traps in BATS tests → orphan DDEV volumes (per CLAUDE.md incident 2026-01-16) | P0 |
| T5 | Pre-commit has no `shellcheck` / `shfmt`; CI lint:bash only does `bash -n` syntax check | P1 |
| T6 | CI runs *validation* subset only; full integration tests are dev-local | P2 |
| T7 | E2E tests are placeholders | P2 |
| T8 | AI scenario S3 (in `.verification-ai-progress.yml:181`) has a known setup failure | P3 |

### 6.2 Actions

- **A-T4 (P0):** Add `setup_file` / `teardown_file` to every
  `tests/integration/*.bats` that touches DDEV. Mandatory
  `ddev delete --omit-snapshot --yes` on teardown, even on test failure.
  Cite CLAUDE.md's "no sites/tmp/" + cleanup rule. ~30 min.
- **A-T1 (P1):** Split `.verification.yml` into per-feature files under
  `.verification-specs/` — **one file per feature, regardless of size**
  (semantic boundary, not a byte cap). The monolith stays auto-generated
  from them. Growth detection delegated to `lib/ci-stats.sh` (§6.5):
  warn when a spec file grows >50 % since the last 5 release tags — the
  signal is *change rate*, not absolute size. Add a `pl verify compact`
  command that prunes verified-and-stable entries (passed M consecutive
  times, where M is itself read from `ci-stats`).
- **A-T2 / A-T3 (P1):** Add a "coverage backlog" to the roadmap.
  Tackle in this order (one bats file per item, ~30 min each):
  `doctor`, `status`, `make`, `site`, `server`, `backup`, then libs
  `git.sh`, `cloudflare.sh`, `linode.sh`. Don't try to do all 51 at once;
  this is a steady drip.
- **A-T5 (P1):** Add `shellcheck` and `shfmt --diff` to
  `.pre-commit-config.yaml` (excluding `sites/` and `servers/`) AND to
  `.gitlab-ci.yml` `lint:bash`. Pin versions. Convert any failures into
  an allow-list that decays over time.
- **A-T6 (P2):** Add `test:integration:full` job in `.gitlab-ci.yml`
  gated on MR pipelines + manual trigger. Default `test:integration` job
  stays fast (validation-only).
- **A-T7 (P2):** Either ship real E2E coverage or delete the
  placeholders. Same call as A-O7.
- **A-T8 (P3):** Investigate `lib/verify-scenarios.sh` to fix the S3
  setup failure noted in the AI-progress file.

---

## 6.5 Adaptive Thresholds (cross-cutting infrastructure)

Several items in §5 and §6 originally carried hand-picked numeric
limits (`timeout: 5m`, "cap at 100 KB", "expire in 1 week"). All such
limits are now replaced with **rolling-window p95** from observed
history. This is the single piece of infrastructure that makes the
other items honest.

### 6.5.1 Pattern

Each CI job (and select shell scripts) records its duration and other
relevant metrics on every successful run. Thresholds are computed from
the last **N = 20** samples, ignoring failed runs. Two layers:

1. **Soft assertion (in-job).** Warn or fail when this run exceeds
   `1.5 × p95` over the rolling window. This catches *relative*
   regressions — a 50 % slowdown is a real signal regardless of
   absolute duration.
2. **Hard ceiling (GitLab `timeout:` / shell wrapper).** Stays
   intentionally generous (e.g., 30 min on lint, 2 h on deploy) and is
   never tuned. This catches *runaway* processes that the soft layer
   can't see (because they never finish to record a duration).

### 6.5.2 Library API

`lib/ci-stats.sh` exports:

```bash
ci_stats_record <metric> <value> [outcome]   # append to .ci-stats/<metric>.tsv
ci_stats_p95    <metric>                     # read N samples → p95
ci_stats_band   <metric>                     # echo "low high" tuple
ci_stats_check  <metric> <value> [warn|fail] # 0 if in-band, 1 if regression
```

Metric names are free-form strings: `ci.lint-bash.seconds`,
`verify.spec-foo.bytes`, `deploy.stg2live.rsync-seconds`,
`build.bundle.sign-seconds`, etc. Anything quantifiable is a candidate.

### 6.5.3 Storage

Stats live on a dedicated **`stats` git branch**, not on `main`:

- Per-metric TSV: `.ci-stats/ci.lint-bash.seconds.tsv` with rows
  `ISO-timestamp\tcommit-sha\tvalue\toutcome`.
- Trimmed to last 20 successful samples per metric.
- One trusted runner has push access to the `stats` branch; CI jobs on
  other runners hand off via artifact + a nightly aggregation job.
- `main` never sees stats commits — zero noise in `git log` and zero
  merge-conflict surface on the working tree.
- Audit trail preserved: every threshold change is a `stats` branch
  commit you can `git blame`.

### 6.5.4 Where this pattern replaces arbitrary numbers in F36

| F36 action | Originally specified | Now delegated to `ci-stats` |
|---|---|---|
| A-O6 (lint timeouts) | `timeout: 5m` | hard 30 m + soft 1.5× p95 |
| A-T1 (verification spec size) | "cap at 100 KB" | warn when >50 % growth across 5 release tags |
| A-O9 (artifact expiry) | "1 wk / 1 d / 1 wk" | observed consumer p95 + 24 h |
| (new) deploy step durations | unspecified | per-step soft threshold |
| (new) test flakiness | unspecified | auto-quarantine if fail-rate >20 % over 20 runs |

### 6.5.5 Free security signals

The same infrastructure yields two posture indicators that align with
ADR-0017's "trust flows through signatures, not machines":

- **`build.bundle.sign-seconds` spike.** A sign job that suddenly
  takes 3× p95 is worth investigating — could be legit (larger
  artifact) or a compromised runner doing extra work. The soft
  assertion surfaces it; the operator decides.
- **Verification pass-rate decay.** A check that passed 100× in a
  row and starts failing intermittently is a stronger signal than a
  check that's always flaky. `ci_stats_check` on
  `verify.<check>.pass-rate` catches it.

### 6.5.6 Actions

- **A-CI1 (P1):** Build `lib/ci-stats.sh` + the `stats` branch
  convention + a `before_script` / `after_script` template in
  `.gitlab-ci.yml` that all measured jobs include. Define bootstrap
  fallbacks for the cold-start case (when `n < 5`). Document on
  `lib/README.md`. **~1 day.**
- **A-CI2 (P2):** After A-CI1 is stable for one release cycle, wire
  metrics into `lib/bundle-build.sh` (sign duration) and the verify
  framework (per-check pass rate). These are the security-signal
  metrics from §6.5.5. **~½ day.**

### 6.5.7 Pitfalls and mitigations

1. **Boiling-frog drift.** Gradual rot gets normalized into the
   baseline. *Mitigation:* every adaptive threshold is paired with an
   absolute ceiling that is never tuned (the hard `timeout:` for
   durations; a config-level `max_bytes` for sizes when truly required).
   The adaptive layer catches relative regressions; the absolute layer
   catches gradual rot.
2. **Cold start.** First runs have no history. *Mitigation:*
   `ci_stats_check` returns "bootstrap" (not "in-band" and not
   "regression") when `n < 5`, falling back to a hardcoded default
   threshold per metric.
3. **Outliers poisoning the window.** One ci-host reboot mid-job
   inflates p95 for weeks. *Mitigation:* filter `outcome != success`
   rows before computing p95; trim the top sample if it's >3× median.
4. **Audit / leak surface.** Stats reveal infrastructure behaviour
   patterns. *Mitigation:* `stats` branch never mirrored to public
   GitHub; scrubbed if it ever is. Per-metric review when adding new
   ones.
5. **Single-runner bottleneck.** Only one runner pushes to `stats`.
   *Mitigation:* multi-runner stats arrive as job artifacts; nightly
   aggregator (on `ci-host`) merges them.

---

## 7. Cross-Cutting Themes

Three themes recur across all five audit angles:

**Theme 1 — F28 / ADR-0017 spine is unfinished.** The libraries are
written, the verifier is designed, but the CI plumbing that feeds it
doesn't exist. Until A-O1 + A-O2 + A-S2 land, the distributed
build/deploy story is aspirational. **This is the single most
impactful work in this proposal.**

**Theme 2 — Duplication is the dominant cost.** Six deploy scripts,
three YAML parsers, two library trees, two CI configs (GitLab + GitHub).
None of these duplications are urgent, but cumulatively they account
for ~30% of all bugs found in the past quarter (per `.verification-ai-progress.yml`
incident log).

**Theme 3 — Doc/code drift is fixable in an afternoon.** Most doc
issues (D1, D2, D5) are mechanical: one status change, one count
update, two README edits. They consume disproportionate user-trust
budget when wrong, so they're high-leverage even though low-effort.

---

## 8. What's Working — Do Not Refactor

Audit agents consistently called out these as strengths. Hands off:

- **`pl` dispatcher** — clean entry point, proper strict mode, color
  detection, well-structured command routing.
- **`lib/migrate-schema.sh`** — elegant: numbered migrations,
  pre-migration backups, rollback semantics. Don't touch.
- **`lib/ssh.sh`** — `nwp_ssh_opts` / `nwp_scp` / `nwp_rsync` wrappers
  with `IdentitiesOnly=yes` are good defensive code.
- **`lib/bundle-build.sh` + `lib/bundle-verify.sh`** — F28 artifact
  signing library is solid. Hard-fail on signature failure; no
  partial-verify fallback. Just needs CI wiring.
- **Two-tier secrets (ADR-0004)** — `.secrets.yml` vs
  `.secrets.data.yml` split is correctly implemented; no leaks found.
- **`lib/sanitize.sh`** — explicitly *does not* reset passwords to a
  known value in SQL dumps. Comment cites the threat. Good.
- **Project / server resolver libraries** — `lib/project-resolver.sh`
  and `lib/server-resolver.sh` handle v1 / v2 / v3 layouts
  transparently. Clean API.
- **Backup naming convention** — `YYYYMMDDTHHmmss-branch-commit-message`
  with git metadata embedded. Searchable, sortable, restorable.
- **Leakage gate (P61)** — `.gitleaks.toml` + pre-commit +
  `lint:leakage` is non-bypassable in CI (`allow_failure: false`). The
  manual-hostname-list issue (S4) is a small drift hazard, not a hole.

---

## 9. Implementation Phases

This proposal is **deliberately decomposed into independent phases.**
Each phase is shippable on its own; none blocks the others (except
where noted).

### Phase 0 — Quick wins (1 day; ~6 h total)

Highest leverage, lowest risk. Do these first.

- A-S1: `StrictHostKeyChecking` fix in `safe-ops.sh` (5 min)
- A-O4: Coverage regex dot-escape (1 min)
- A-C5: Add `set -euo pipefail` to 7 scripts (15 min)
- A-D1: F32/F33/F34 status → IMPLEMENTED (15 min)
- A-D5: `sites/avc/*/README.md` `install.sh` → `pl install` (5 min)
- A-T4: BATS DDEV teardown traps (30 min) — orphan-volume prevention
- A-O3: Pin DDEV base image (5 min)
- A-D2: COMMAND_INVENTORY recount (1–2 h)

### Phase 1 — F28 / ADR-0017 CI spine (4–6 h)

Single-purpose phase: light up the verifier's data feed.

- A-O1: `sign-artifact` + `upload-artifact` + `verify-bundle` jobs in `.gitlab-ci.yml`
- A-S2 / A-O2: Real `git verify-commit` enforcement
- Smoke test the full chain locally with a throwaway `BUNDLE_TARGETS`

### Phase 1.5 — Adaptive thresholds infrastructure (1 day + soak)

Unblocks the "no arbitrary numbers" stance in A-O6, A-T1, A-O9 and
makes A-CI2's security signals possible.

- A-CI1: `lib/ci-stats.sh` + `stats` branch + measured-job template
- Bootstrap: hardcoded fallback thresholds for cold-start period
- Soak for one release cycle before A-CI2 turns on security signals

### Phase 2 — Deployment core dedupe (1 week)

Highest mechanical reward.

- A-C1: Extract `lib/deployment-core.sh`
- A-C9: Universal `validate_sitename` at entry points
- A-C3: Replace `eval set -- "$PARSED"` pattern
- A-C4: Audit and de-eval `sync.sh:~435`

### Phase 3 — yq-first enforcement (½ week)

Cleans up an ADR-0015 violation.

- A-C2: Replace AWK parsers with `yq` in `pl`, `stg2prod.sh`, `prod2stg.sh`
- Add CI grep gate forbidding new `awk` YAML parsers

### Phase 4 — Test & verification framework (2 weeks)

Steady backlog work; parallelizable.

- A-T1: Split `.verification.yml` into per-feature spec files
- A-T2 / A-T3: Drip-feed test coverage for commands and libs
- A-T5: `shellcheck` + `shfmt` in pre-commit and CI
- A-T6: `test:integration:full` MR-gated job

### Phase 5 — Documentation polish (1 week, low priority)

- A-D3, A-D4, A-D6, A-D7
- Convention enforcement: proposal-status lint

### Phase 6 — Long-tail hardening (deferrable)

- A-S3: Hardware-token CI signing (after F28 live)
- A-S4: Auto-generated `.gitleaks.toml` rules
- A-S5: AI-context refusal in `safe-ops.sh`
- A-O5–O10: CI hygiene cleanup
- A-C6–C8: Library reorganization
- A-T7: E2E test implementation
- A-CI2: Security-signal metrics (sign-time spike, pass-rate decay) —
  requires Phase 1.5 soaked for one release cycle

---

## 10. Prioritization Matrix

| Priority | Description | Items | Aggregate Effort |
|---|---|---|---|
| **P0** | Real risk / spine-completion. Do in next 2 weeks. | S1, S2/O2, O1, C4, T4 | ~10 h |
| **P1** | Significant duplication / drift / safety. Do in next quarter. | C1, C2, C3, C9, CI1, D1, D2, O3, O4, O5, S3, T1, T2, T3, T5 | ~3 weeks |
| **P2** | Hygiene / convention / defense-in-depth. Do opportunistically. | C5, C6, C7, C8, CI2, D3, D4, D6, D7, O6, O7, O8, O10, S4, S5, T6, T7 | ~2 weeks |
| **P3** | Nice-to-have. Backlog. | D5, O9, T8 | <2 h |

---

## 11. Success Criteria

This proposal is **DONE** when:

- [ ] Phase 0 quick-wins all landed (single PR or short series)
- [ ] A signed `.tar.gz` bundle has been produced by CI and verified
  end-to-end (the F28 spine is live)
- [ ] `git verify-commit HEAD` blocks the CI pipeline on unsigned commits
- [ ] `safe-ops.sh` no longer uses `StrictHostKeyChecking=no`
- [ ] All `bash -n`-clean scripts also pass `shellcheck` (with whatever
  allowlist is necessary)
- [ ] Six deploy scripts share `lib/deployment-core.sh`
- [ ] No AWK YAML parsers remain (`pl`, `stg2prod.sh`, `prod2stg.sh`)
- [ ] F32 / F33 / F34 / F36 all marked `IMPLEMENTED` with commit cites
- [ ] CHANGELOG.md captures all the above under a v0.X release entry
- [ ] `lib/ci-stats.sh` is live; every CI job has a rolling-window
  duration history on the `stats` branch; A-O6 / A-T1 / A-O9
  thresholds are computed, not picked

---

## 12. Risks & Open Questions

- **Risk:** Phase 2 (deploy script dedupe) is the largest change and
  touches the production deploy path. Mitigation: stage on the AVC
  stg-only deploy first; only promote `lib/deployment-core.sh` to live
  paths after one full deploy cycle on stg.
- **Open question:** Should `lib/` and `scripts/lib/` be merged
  (A-C8)? Need an operator decision before Phase 6.
- **Open question:** Keep GitHub Actions in parallel with GitLab CI, or
  treat GitHub as mirror-only and drop the workflows? Per ADR-0021
  GitLab is canonical, but the GitHub leakage gate provides a useful
  belt-and-braces. Recommendation: keep both, but enforce config parity
  via A-O8.
- **Risk:** `.verification.yml` split (A-T1) touches the verification
  framework that gates every PR. Plan a CI dry-run before merging.

---

## 13. Appendix — Audit Methodology

Five parallel Explore subagents on 2026-05-18, each scoped to one
audit angle, total wall time ~3 minutes. Source agents:

- **Documentation drift** — surveyed 264 markdown files; compared
  against `scripts/commands/` (59 entries), `lib/` (74 entries), and
  recent commits (F32, F33, F34, F35, P61).
- **Code architecture** — surveyed 80,448 lines of bash; identified
  duplication via per-file `wc -l` + structural diffing of the six
  deploy scripts; grepped for `eval`, unquoted `$var`, missing
  `set -euo pipefail`.
- **Security** — read CLAUDE.md as standing orders; traced AI-prod
  boundary through `lib/safe-ops.sh`, `.gitlab-ci.yml`, deploy scripts;
  audited signing path via `lib/bundle-*.sh`; checked `.gitleaks.toml`
  enforcement.
- **Testing** — surveyed `tests/{unit,integration,e2e,bats}/`,
  `.verification.yml`, `.verification-ai-progress.yml`; checked
  pre-commit and CI integration; computed coverage ratios.
- **CI/CD** — mapped `.gitlab-ci.yml` (745 lines) end-to-end against
  ADR-0017; compared with `.github/workflows/`; assessed F28 wiring
  status.

Findings cross-validate. Three findings (F28 spine, signed commits,
yq-first violation) appeared in two or more agents independently and
are reflected in the cross-cutting themes (§7).

---

**End of F36 proposal.** No code changes have been made; this proposal
is the deliverable, and Phase 0 quick-wins can be opened as a separate
PR when ready.
