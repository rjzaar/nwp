# Testing — Behat + PHPUnit on NWC

**Audience:** Coder, verifying that a PR's tests actually do their job.
**Status:** v1 — 2026-05-20.
**Read time:** 10 minutes.

The agent claims tests pass. CI claims tests pass. Your job is to know what "tests pass" *means* and to call out tests that don't actually test the change.

---

## 1. The two suites

NWC has two test suites. Both run on every PR, and both must be green before merge.

| Suite     | What it covers                                                 | Where it lives                                                                              | How long it takes |
|-----------|----------------------------------------------------------------|---------------------------------------------------------------------------------------------|-------------------|
| Behat     | End-to-end UI + API scenarios in Gherkin                       | `~/nwp/sites/nwc/dev/tests/behat/` and `profiles/.../<module>/tests/src/Behat/*.feature`    | 3–4 min full run  |
| PHPUnit   | Kernel + unit tests (no browser, real DB)                      | `profiles/.../<module>/tests/src/Kernel/*Test.php` and `tests/src/Unit/*Test.php`           | 1–2 min full run  |

Behat is the safety net for "does the user experience work". PHPUnit is the safety net for "does this service / entity / state machine behave correctly in isolation". The agent should add to whichever suite is appropriate for the change.

**Rule of thumb:** a state-machine change needs PHPUnit kernel coverage. A user-facing workflow change needs Behat coverage. A change that affects both needs both.

---

## 2. Running the suites

### From your laptop (recommended for review)

You don't need to run them every PR — CI does. But for tricky changes, run locally:

```bash
cd ~/nwp/sites/nwc/dev
git fetch origin
git checkout <pr-branch>
ddev start  # if not running
```

#### Behat (the editorial pipeline suite)

```bash
ddev exec "vendor/bin/behat --config=behat.yml.dist --suite=nwc_editorial"
```

You should see something like:

```
6 scenarios (6 passed)
24 steps (24 passed)
```

For the full set:

```bash
ddev exec "vendor/bin/behat --config=behat.yml.dist"
```

#### PHPUnit (kernel)

```bash
ddev exec "cd /var/www/html && vendor/bin/phpunit \
  --bootstrap=/var/www/html/html/core/tests/bootstrap.php \
  --no-configuration \
  /var/www/html/html/profiles/custom/nwc/modules/nwc_features/nwc_editorial/tests/src/Kernel/"
```

You should see something like:

```
OK (6 tests, 18 assertions)
```

For other modules, substitute the module path (e.g. `.../nwc_copyright/tests/src/Kernel/`).

### From CI (the canonical answer)

Each PR runs the GitLab CI job `test:behat-and-phpunit`. Click the green ✓ on the MR. If it's red, **do not approve regardless of what the agent says**. CI is the source of truth.

---

## 3. The Behat suites that exist

| Suite name              | What it covers                                                              |
|-------------------------|-----------------------------------------------------------------------------|
| `nwc_editorial`         | State machine + reviewer queue happy paths                                  |
| `nwc_feedback`          | Feedback widget → entity → GitLab issue (input side of agent loop)         |
| `nwc_copyright`         | Copyright clearance recording + cross-site policy sync                      |
| `nwc_trialing`          | Trial feedback A1–E3 classification + halt/escalate routing                 |
| `nwc_governance`        | Audit log writes for every state transition                                 |
| `nwc_oauth_bridge`      | OAuth SSO handshake (nwc Drupal → ssc Moodle)                               |

A PR that changes editorial behaviour should add at least one new scenario to `nwc_editorial`. If it doesn't, ask "where is this tested?" in your review comment.

---

## 4. Reading a test diff like a reviewer

### The single most important question

> If I removed the production code change but kept the test, would the test still pass?

If **yes**, the test does not actually test the change. Request changes.

Concrete example:

**Bad** — a test that always passes:
```php
public function testCopyrightGateBlocks(): void {
  // ...
  $rev = EditorialRevision::create(['state' => 'draft', ...]);
  $rev->save();
  $this->assertSame('draft', $rev->get('state')->value);
}
```
This asserts the literal value you just set. It would still pass if `EditorialStateService` were deleted entirely.

**Good** — a test that locks in the gate behaviour:
```php
public function testCopyrightGateBlocks(): void {
  // Revision in in_copyright_clearance, no clearance recorded
  $rev = EditorialRevision::create(['state' => 'in_copyright_clearance', ...]);
  $rev->save();
  $this->expectException(\RuntimeException::class);
  $this->container->get('nwc_editorial.state')->advance($rev, $user);
}
```
This *only* passes if the service actively rejects the advance. Remove the gate code → test fails.

### Behat equivalent

**Bad** — a scenario that exercises an unrelated path:
```gherkin
Scenario: Typo fix is fixed on the about page
  Given there is an "About" node with body "The site is amened"
  When I view "/about"
  Then I should see "amened"   # <-- testing the OLD text
```

**Good** — the scenario actually verifies the fix:
```gherkin
Scenario: About page reflects latest typo fix
  Given the polish-seeder has run on a clean install
  When I view "/about"
  Then I should see "amended"
  And I should not see "amened"
```

---

## 5. Coverage expectations by tier

| Tier | What you should see in the test diff                                                                                  |
|------|------------------------------------------------------------------------------------------------------------------------|
| T1   | Existing suites still green. New tests *welcome* but not required for pure typo / doc / CSS changes.                   |
| T2   | One or more new tests that fail before the fix + pass after. Agent must show both states (or link a fixed-issue MR).   |
| T3   | New PHPUnit kernel + new Behat coverage + an [ADR](./adrs.md) update if state machine touched.                          |

If you're not sure what tier the PR is, look at where it touches: see the [decision tree in architecture-brief.md §8](./architecture-brief.md#8-quick-decision-tree-for-unfamiliar-prs).

---

## 6. When tests are red

If CI is red on a PR you're reviewing:

1. **Click through to the CI job log.** GitLab UI → Pipeline → failed job → "Browse" the trace.
2. Find the first `FAIL` or `❌` line. That's usually the real failure; everything after may be cascading.
3. Decide:
   - **Real regression in the PR** → request changes, link the failing test name in your comment.
   - **Flaky / infrastructure issue** (db connect, ddev not starting) → comment "retrying CI" + click "Retry" on the job. If it fails again, it's not flaky.
   - **Pre-existing failure not caused by this PR** → still request changes ("this PR should not land on a red branch; agent must rebase or fix"). Don't approve red.

**Never merge a red PR.** Even if the failure looks unrelated. Especially if the agent says "it's unrelated".

---

## 7. The test infrastructure (just in case)

- **PHPUnit bootstrap:** `/var/www/html/html/core/tests/bootstrap.php` (Drupal core's bootstrap; nwc tests rely on it).
- **PHPUnit config:** `~/nwp/sites/nwc/dev/phpunit.xml` (registers the `nwc` test suite).
- **Behat config:** `~/nwp/sites/nwc/dev/behat.yml.dist` (registers each `nwc_*` suite).
- **SIMPLETEST_DB:** `mysql://db:db@db:3306/db` — the ddev `db` container. Kernel tests get a fresh schema per class via `installEntitySchema()`.
- **Test users / fixtures:** kernel tests build them inline (`EditorialArtifact::create([...])`). Behat scenarios use Drupal Extension's `@api` step set + custom contexts in `tests/behat/features/bootstrap/`.

If a test won't run locally and you're stuck, ping Rob — don't approve on faith.

---

## See also

- [pr-review-checklist.md](./pr-review-checklist.md) — when to demand a test
- [architecture-brief.md](./architecture-brief.md) — what's worth testing in this codebase
- [rollback-playbook.md](./rollback-playbook.md) — what to do if tests passed but prod breaks anyway
