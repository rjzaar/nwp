## Task shape: NWP config / tooling change

This repo is the **nwp meta repo** (bash tooling: `pl`, `scripts/commands/`,
`lib/`, `example.nwp.yml`). The issue describes a small, dev-repo-bounded
config or tooling fix (e.g. a missing default in `example.nwp.yml`, a wrong
flag in a `scripts/commands/*.sh` help text, a small resolver bug).

### Procedure

1. Make the smallest change that resolves the issue. Schema/template changes
   go in `example.nwp.yml` — NEVER create or edit `nwp.yml` (user-local,
   gitignored) or anything under `sites/`.
2. `bash -n` every shell script you touched — must be clean.
3. If the repo has a matching test (`tests/`, bats), run it for the touched
   command. Note in the commit body which check you ran.

### Hard boundaries (STOP + AGENT-NOTE.md instead of proceeding)

These paths require human review — if the fix seems to need them, do NOT
touch them; write `AGENT-NOTE.md` explaining why and stop:

- `.gitlab-ci.yml`, `.github/`, git hooks
- `lib/auth*`, anything matching `*secret*`, `keys/**`, `.env*`
- `scripts/commands/live*.sh`, `scripts/commands/prod*.sh` (prod deploy paths)
- `CLAUDE.md`, sanitizer scripts (`lib/sanitizers/`)
- adding/removing dependencies of any kind
