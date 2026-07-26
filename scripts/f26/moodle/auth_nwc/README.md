# NOT a deployable plugin — a logic-test fixture

What remains here is **two files**, kept only so the CI-gated plain-PHP unit test
(`tests/unit/test-auth-logic.bats`) has something to run:

- `classes/uid_lock.php` — pure decision logic, **byte-identical** to the
  canonical copy in `nwp/ss-moodle-plugins:auth/nwc/classes/uid_lock.php`
  (verified 2026-07-26). Nothing about it is stale.
- `tests/uid_lock_logic_test.php` — the standalone runner for it.

Everything else that made this look like an installable Moodle plugin —
`version.php`, `auth.php`, `settings.php`, `db/events.php`,
`classes/observer.php`, `lang/` — has been **deleted** (programme item 9).

## Why they were deleted

This was the only `auth_nwc` copy committed to `nwp/nwp` and the only **stale**
one: `2026071101 / 1.0.0`, while the dev tree, the `.plugin-src` cache and **live
`ssc`** were all `2026072400 / 1.2.0-draft`. `auth.php`, `observer.php`,
`lang/en/auth_nwc.php` and `version.php` had diverged, and the canonical copy has
an entire Art.9 half this one never had (`classes/consent.php`,
`classes/guild_cohort_map.php`, `classes/privacy/`, `tests/consent_gate_test.php`,
`tests/consent_logic_test.php`).

Anyone reading `nwp/nwp` and deploying "the auth_nwc in the repo" would have
**downgraded live ssc and dropped the Art.9 consent gate**. Without `version.php`
and `auth.php` this directory can no longer be installed as a Moodle plugin at
all, so the trap is gone while the test coverage is kept.

Canonical source, deploy instructions and drift detection:
[../CANONICAL-SOURCE.md](../CANONICAL-SOURCE.md).
