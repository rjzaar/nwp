# CI Stats — adaptive thresholds via rolling-window p95

**Library:** `lib/ci-stats.sh`
**Tests:** `tests/unit/test-ci-stats.bats` (29 BATS tests)
**Proposal:** [F36 §6.5](../proposals/F36-comprehensive-codebase-improvements.md)
**Status:** Library + tests landed (Phase 1.5). CI wiring is the soak phase.

---

## Why this exists

Several limits in NWP have historically been hand-picked numbers:
lint-job timeouts, verification-spec file sizes, CI artifact expiry,
deploy-step time budgets. Hand-picked numbers age badly — too small
and they trip on slow runners; too large and they don't catch
regressions until the user notices.

`ci-stats.sh` replaces those with **rolling-window p95** from observed
history. Each measured job records its duration on every successful
run; thresholds are computed from the last 20 samples.

Two layers of enforcement, deliberately:

1. **Soft assertion** (this library): warn or fail when a run exceeds
   `1.5 × p95`. This catches *relative* regressions — a 50 % slowdown
   is a real signal regardless of absolute duration.
2. **Hard ceiling** (GitLab `timeout:` / shell wrapper): stays
   intentionally generous (e.g., 30 min on lint, 2 h on deploy) and is
   never tuned. This catches *runaway* processes the soft layer can't
   see (they never finish to record a duration).

The library is the soft layer. The hard layer stays in `.gitlab-ci.yml`
as conservative `timeout:` values.

---

## Quick reference

```bash
# Record a sample (append to .ci-stats/<metric>.tsv, trim to last 20)
./lib/ci-stats.sh record <metric> <value> [outcome]

# Query: p95, sample count, operating band, threshold check
./lib/ci-stats.sh p95   <metric>
./lib/ci-stats.sh n     <metric>
./lib/ci-stats.sh band  <metric>        # echoes "low high"
./lib/ci-stats.sh check <metric> <value> [warn|fail]
```

Metric naming: `<area>.<job>.<unit>` — for example
`ci.lint-bash.seconds`, `build.bundle.sign-seconds`,
`verify.spec-foo.bytes`. Names must match `[a-z0-9._-]+`.

Outcomes: `success | failure | skip | bootstrap`. Only `success`
samples feed p95; the others are audit trail.

---

## Storage model

```
.ci-stats/
├── README.md               (on main — convention doc)
├── bootstrap.yml           (on main — cold-start thresholds)
└── <metric>.tsv            (on `stats` branch only — runtime samples)
```

The split is enforced by `.gitignore`: `bootstrap.yml` is tracked,
`*.tsv` is not (would cause merge conflicts on every CI run).

### TSV format

```
<ISO-8601 timestamp UTC>\t<commit-sha>\t<value>\t<outcome>
```

Each metric gets its own TSV. Rolling-window trim keeps the last 20
successful samples plus any same-window failures/skips as audit trail.

### Why a `stats` branch?

- **`main` never sees stats commits** — zero noise in `git log`, zero
  merge conflicts on the working tree.
- **Audit trail preserved** — every threshold change is a `stats`
  branch commit you can `git blame`.
- **One trusted runner pushes** — CI jobs on other runners hand off
  via job artifacts; a nightly aggregator on the trusted runner merges
  them into `stats`.

The `stats` branch is bootstrapped manually (see *Operations* below);
the library itself doesn't know about branches and only reads/writes
the local `.ci-stats/` directory.

---

## Computation details

### p95

The library sorts all `success` samples, optionally trims the maximum
if it's an outlier (more than `CI_STATS_OUTLIER_FACTOR × median`, with
n > 3 to avoid trimming tiny samples), and returns the value at index
`round(n × 0.95)`.

For small n (1–20 samples), p95 is essentially "approximately the max,
ignoring one extreme outlier." That's the intended behaviour — with a
small window we want to be sensitive to recent regressions, not
infinity-tolerant.

### Threshold

`threshold = p95 × CI_STATS_REGRESSION_FACTOR` (default 1.5).

A value ≤ threshold is "in-band." A value > threshold is a regression.

### Bootstrap fallback

When `n < CI_STATS_BOOTSTRAP_MIN` (default 5), the library uses the
hardcoded value from `.ci-stats/bootstrap.yml` instead of computing a
p95. If no bootstrap entry exists, `ci_stats_check` issues a warning
and returns 0 (lets the run through; doesn't break new metrics).

---

## Wiring into CI

### GitLab CI template

`.gitlab-ci.yml` defines a `.measured` anchor that any job can extend:

```yaml
.measured: &measured
  before_script:
    - export NWP_JOB_START=$(date +%s)
  after_script:
    - duration=$(($(date +%s) - ${NWP_JOB_START:-$(date +%s)}))
    - outcome="${CI_JOB_STATUS:-success}"
    - ./lib/ci-stats.sh record "ci.${CI_JOB_NAME}.seconds" "$duration" "$outcome" 2>/dev/null || true
    - ./lib/ci-stats.sh check  "ci.${CI_JOB_NAME}.seconds" "$duration" warn 2>/dev/null || true
```

Apply to a job by merging:

```yaml
lint:bash:
  <<: *measured
  stage: lint
  script:
    - find scripts lib -name "*.sh" -exec bash -n {} \;
```

**Note (Phase 1.5 soak period):** The template is defined but jobs
are not yet wired into it. The Phase 1.5 plan is to soak the library
in isolation for one release cycle, then start applying the template
job-by-job in Phase 2/3.

### Persistence to the `stats` branch

`after_script` writes locally. A separate stage uploads the TSVs as
GitLab artifacts; the trusted runner's nightly aggregator job pulls
those artifacts and commits them to the `stats` branch.

Persistence is **not yet wired**. Two acceptable interim options:

1. Store stats only in long-lived GitLab CI cache (lost on cache
   invalidation; no audit trail).
2. Skip persistence and rely on bootstrap thresholds until the trusted
   runner is configured.

---

## Operations

### Provisioning the `stats` branch

```bash
git checkout --orphan stats
git rm -rf .
mkdir .ci-stats
cat > .ci-stats/README.md <<'EOF'
# stats branch

This branch holds the rolling-window sample TSVs for ci-stats.sh.
Never merge into main. One runner pushes here; everyone else reads.
EOF
git add .ci-stats/README.md
git commit -m "stats: bootstrap"
git push -u origin stats
git checkout main
```

### Tuning bootstrap defaults

Edit `.ci-stats/bootstrap.yml`. Pick values comfortably above the
*observed* runtime (e.g., 2× typical duration). Once adaptive mode
kicks in (≥ 5 samples), the bootstrap entry stops being consulted.

### Adding a new measured metric

1. Pick a name: `<area>.<job>.<unit>`.
2. Add a bootstrap default to `.ci-stats/bootstrap.yml`.
3. Wire it into the producer (CI job, shell script, etc.) with
   `ci_stats_record` + `ci_stats_check`.
4. Soak for 5+ successful runs.
5. Adaptive mode takes over automatically.

---

## Tunables

All overridable via environment:

| Variable | Default | Meaning |
|---|---|---|
| `CI_STATS_DIR` | `<repo>/.ci-stats` | Override stats directory |
| `CI_STATS_WINDOW` | 20 | Rolling window size |
| `CI_STATS_REGRESSION_FACTOR` | 1.5 | Soft threshold = p95 × this |
| `CI_STATS_BOOTSTRAP_MIN` | 5 | Min samples before adaptive |
| `CI_STATS_OUTLIER_FACTOR` | 3 | Drop max sample if > this × median |

---

## Pitfalls and mitigations

1. **Boiling-frog drift.** Gradual rot gets normalized into the
   baseline. *Mitigation:* every adaptive threshold is paired with an
   absolute ceiling in `.gitlab-ci.yml` (the hard `timeout:`) that is
   never tuned. Adaptive catches relative regressions; absolute catches
   gradual rot.
2. **Cold start.** First runs have no history. *Mitigation:* bootstrap
   thresholds in `.ci-stats/bootstrap.yml`; `ci_stats_check` returns
   0-with-warning when neither history nor bootstrap is available.
3. **Outliers poisoning the window.** One ci-host reboot mid-job
   inflates p95 for weeks. *Mitigation:* p95 computation drops the
   maximum if it's > 3× the median (configurable via
   `CI_STATS_OUTLIER_FACTOR`).
4. **Audit / leak surface.** Stats reveal infrastructure behaviour
   patterns. *Mitigation:* the `stats` branch is never mirrored to
   public forks; scrubbed if it ever is.
5. **Single-runner bottleneck.** Only one runner pushes to `stats`.
   *Mitigation:* multi-runner stats arrive as job artifacts; nightly
   aggregator (on `ci-host`) merges them.

---

## Future security signals

Per F36 §6.5.5, the same infrastructure yields two free posture
indicators:

- **`build.bundle.sign-seconds` spike** — a sign job that suddenly
  takes 3× p95 is worth investigating (legit larger artifact, or a
  compromised runner doing extra work).
- **Verification pass-rate decay** — a check that passed 100× in a row
  and starts failing intermittently is a stronger signal than a check
  that's always flaky. `ci_stats_check` on
  `verify.<check>.pass-rate` catches it.

Both are deferred to F36 Phase 6 — depend on Phase 1.5 soaking
through one release cycle first.
