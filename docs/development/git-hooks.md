# Git Hooks

Git hooks run automatically at points in the git workflow. NWP uses the
[pre-commit](https://pre-commit.com) framework as the single entry point, so
there is exactly one installed hook file and everything else is declared in
`.pre-commit-config.yaml`.

## Installation

```bash
pipx install pre-commit    # once per machine
pre-commit install         # once per clone — writes .git/hooks/pre-commit
```

`.git/hooks/` is not tracked by git, so every fresh clone (and anyone who has
never run `pre-commit install`) has **no** hooks at all. `pre-commit install`
writes a small shim into `.git/hooks/pre-commit`; that shim dispatches to every
hook declared in `.pre-commit-config.yaml`. See CONTRIBUTING.md.

## What runs on commit

| Hook | What it does | Blocks the commit? |
|------|--------------|--------------------|
| `gitleaks` | Scans the staged diff against `.gitleaks.toml` (operator-specific identifiers + credential patterns) | Yes, on a hit |
| `syntax-gate` (`.hooks/pre-commit`) | Syntax-checks staged shell, bats and PHP | Yes, on a syntax error |

### syntax-gate — `.hooks/pre-commit`

Two rules, deliberately pulling in opposite directions:

- **Fail-closed on a real syntax error** in a file you are about to commit.
- **Fail-open when a linter is merely absent** — one skip line, exit 0.

| Staged file | Check | If the tool is missing |
|-------------|-------|------------------------|
| `*.sh`, `*.bash`, `pl`, extensionless files with a `sh`/`bash` shebang | `bash -n` | n/a — bash is always present |
| `*.bats` | `bats --count` (a `.bats` file is *not* valid bash, so `bash -n` would raise a false failure) | one skip line, commit proceeds |
| `*.php`, `*.module`, `*.inc`, `*.install`, `*.theme`, `*.profile`, `*.engine` | `php -l`, then `phpcs --standard=Drupal,DrupalPractice` | one skip line each, commit proceeds |
| PHP, **only in a real Drupal checkout** (`web/modules/custom` exists and `phpstan.neon` is present) | `phpstan analyse` | one skip line, commit proceeds |

It checks the **staged** content (`git show :path`), not the worktree — that is
what the commit will actually record — and reports the real repo-relative path
and line number, not the temporary file it used.

`phpcs`/`phpstan` are looked up on `PATH` first, then in `./vendor/bin`.

**Sample output** (a machine with no PHP toolchain, staging a `.php` file):

```
phpcs not installed — skipping Drupal coding-standard check.
Syntax checks passed.
```

**Sample failure:**

```
Shell syntax error: lib/broken.sh
  lib/broken.sh: line 4: syntax error: unexpected end of file
Pre-commit refused the commit: 1 file(s)/check(s) failed.
Fix the syntax above. --no-verify exists but also skips the leak gate.
```

Covered by `tests/unit/test-precommit-hook.bats`.

#### Why the fail-open rule is load-bearing

Until 2026-07 this hook hard-`exit 1`d whenever `phpcs` or `phpstan` was simply
not installed, and then ran `phpstan analyse --configuration=phpstan.neon`,
whose paths (`web/modules/custom`, `web/themes/custom`) do not exist in the NWP
tool repo. No commit staging a `.php` file could pass, on any machine without a
Drupal toolchain. The rational response was `git commit --no-verify` — which
also skips the gitleaks leak gate sitting next to it. A gate nobody can pass is
a gate nobody runs, and it silently takes the gate beside it down with it.

## Bypassing hooks

```bash
git commit --no-verify -m "..."
```

`--no-verify` disables **all** hooks, including the leak gate — it is not a way
to skip one noisy check. The CI leakage gate in `.gitlab-ci.yml` is not
bypassable, so anything `--no-verify` lets through is caught later and louder.

If you find yourself reaching for `--no-verify` routinely, the hook is wrong:
fix the hook (and add a case to `tests/unit/test-precommit-hook.bats`).

## Running hooks manually

```bash
pre-commit run --all-files                # every hook, every file
pre-commit run syntax-gate --all-files
bash .hooks/pre-commit                    # just the syntax gate, against the index
bash .hooks/pre-commit lib/foo.sh         # against explicit files (worktree content)
```

## Not installed (documented here historically, never implemented)

Earlier versions of this page described a `pre-commit` hook that blocked
committing `nwp.yml` and warned about stale "Last Updated" dates, plus a
`commit-msg` hook validating message length. **No such hooks exist in this
repository** — there is no code for them anywhere in the tree, and
`.git/hooks/commit-msg` is not installed. Those claims are removed rather than
reimplemented, so this page describes only what actually runs.

`nwp.yml` is protected by `.gitignore` (`**/nwp.yml`), not by a hook; committing
it requires an explicit `git add -f`.

## Troubleshooting

**Hooks do not run at all.** You have not run `pre-commit install` in this
clone. Check `cat .git/hooks/pre-commit` — it should be the generated pre-commit
shim. Worktrees share `.git/hooks` with their parent repository.

**`.hooks/pre-commit` is not executable.** `chmod +x .hooks/pre-commit` (the
`language: script` hook type runs the file directly).

**The gate refuses a file you believe is fine.** Reproduce it exactly:
`bash -n <file>`. If `bash -n` is happy and the hook is not, the hook has a bug
— that is a test case, not a `--no-verify`.

## Related Documentation

- [CONTRIBUTING.md](../../CONTRIBUTING.md) — install instructions and the leakage gate
- [CLAUDE.md](../../CLAUDE.md) — protected files and commit workflow
- [Developer Workflow](../guides/developer-workflow.md) — complete development lifecycle

---

Last Updated: 2026-07-26
