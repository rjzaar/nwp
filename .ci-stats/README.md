# `.ci-stats/` — adaptive-threshold storage

This directory is the home of the CI-stats data described in
[F36 §6.5](../docs/proposals/F36-comprehensive-codebase-improvements.md)
and the operations guide at
[docs/reference/ci-stats.md](../docs/reference/ci-stats.md).

## What lives here

| File | Branch | Tracked? | Purpose |
|---|---|---|---|
| `bootstrap.yml` | `main` | ✅ | Cold-start thresholds per metric (used when `n < CI_STATS_BOOTSTRAP_MIN`) |
| `<metric>.tsv` | `stats` only | ❌ on `main` (gitignored) | Rolling-window sample history |
| `README.md` | `main` | ✅ | This file |

The split is deliberate:

- **`bootstrap.yml` is content** — operator-tunable defaults that should
  be code-reviewed and version-controlled on `main`.
- **`<metric>.tsv` is data** — written on every measured CI run. It
  doesn't belong on `main` (would cause merge conflicts on every
  pipeline). It lives on a dedicated `stats` branch that one trusted
  runner pushes to.

`.gitignore` enforces this with `.ci-stats/*.tsv`.

## TSV format

One sample per row, tab-separated:

```
<ISO-8601 timestamp UTC>\t<commit-sha>\t<value>\t<outcome>
```

`<outcome>` is one of `success`, `failure`, `skip`, `bootstrap`. Only
`success` rows feed the p95 computation; the others are kept as audit
trail until the rolling-window trim drops them.

## CLI quick reference

```bash
./lib/ci-stats.sh record <metric> <value> [outcome]    # append a sample
./lib/ci-stats.sh p95    <metric>                      # echo p95 of last 20
./lib/ci-stats.sh band   <metric>                      # echo "low high"
./lib/ci-stats.sh check  <metric> <value> [warn|fail]  # in-band? warn or fail
./lib/ci-stats.sh n      <metric>                      # successful-sample count
./lib/ci-stats.sh help                                 # full usage
```

See `docs/reference/ci-stats.md` for the full operational model,
including how the `stats` branch is provisioned and how to fold new
metrics into existing CI jobs.
