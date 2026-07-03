## Repo-specific testing conventions (MUST READ before writing tests)

This is a Drupal install profile (`profiles/custom/nwc/`). All custom
modules live at `profiles/custom/nwc/modules/nwc_features/<module>/`.
That nesting affects which PHPUnit base class will work:

- **Kernel tests (`KernelTestBase`) WORK** for profile-nested modules.
  They bypass Drupal's profile-extension filter. List modules in
  `static $modules`; they will be loaded.
- **BrowserTestBase / WebDriverTestBase tests DO NOT WORK** out of the
  box. Drupal's ExtensionDiscovery filters out modules under
  `profiles/custom/nwc/modules/` when the active test profile is
  `testing` (the BrowserTestBase default). Setting
  `protected $profile = 'nwc';` would fix discovery but triggers a
  full Open Social install per test — too slow, frequently flaky.

**Pattern:** for new tests, prefer `KernelTestBase` and assert on
service contracts via mocks (use `\Drupal\Core\DependencyInjection\ContainerBuilder`
+ `$this->createMock()`). Look at
`profiles/custom/nwc/modules/nwc_features/nwc_editorial/tests/src/Kernel/StateMachineTest.php`
as the reference template — it covers the editorial state machine
end-to-end without browser overhead.

**When you DO need a browser:** add a Behat scenario under
`profiles/custom/nwc/modules/nwc_features/<module>/tests/src/Behat/`
instead of a PHPUnit Functional test. Behat is configured at the
project root (`behat.yml.dist`) and runs against the live ddev site,
which has the nwc profile already installed.

**Other gotchas:**

- The Feedback entity has a `guild_id` reference to the contrib `group`
  module. Do NOT `installEntitySchema('feedback')` in a kernel test
  unless you also list `group` in `$modules` — and that drags in heavy
  dependencies. Prefer mock-based assertions on the service contract.
- All NWC entities reference the `user` entity type. Install user
  schema (`$this->installEntitySchema('user')`) before touching any
  entity that has an author/owner field.
- The `workflow_assignment` module is required by `nwc_core`; list
  both in `$modules` when testing modules that depend on nwc_core.

## Test commands (run before committing — these MUST pass)

Run BOTH of these. Behat is the user-visible safety net; PHPUnit Kernel
is the contract-level check. If the change touches a service or entity
type that's never user-facing, the Behat suite still has to be green
because something else on the site may exercise it. Skipping Behat is
the most common way the loop has shipped a regression.

```bash
# From inside the worktree (you are at the profile root):
PROFILE=$(pwd)

# 1. Kernel test on the changed module (substitute the module name):
ddev exec "cd /var/www/html && vendor/bin/phpunit -c /var/www/html/phpunit.xml \
  /var/www/html/html/profiles/custom/nwc/modules/nwc_features/<module>/tests/src/Kernel/"

# 2. Editorial baseline must remain green:
ddev exec "cd /var/www/html && vendor/bin/phpunit -c /var/www/html/phpunit.xml \
  /var/www/html/html/profiles/custom/nwc/modules/nwc_features/nwc_editorial/tests/src/Kernel/"

# 3. Behat suite — runs against the live ddev site. Required even when
#    the change looks "backend-only", because Behat covers the user flows
#    that real members will hit:
ddev exec "cd /var/www/html && vendor/bin/behat --config=behat.yml.dist --suite=nwc_editorial --no-progress"

# 4. If the changed module ships its own Behat scenarios, run those too:
ddev exec "cd /var/www/html && vendor/bin/behat --config=behat.yml.dist \
  /var/www/html/html/profiles/custom/nwc/modules/nwc_features/<module>/tests/src/Behat/ --no-progress"
```

If tests fail and the fix is unclear, write `AGENT-NOTE.md` explaining
what you tried and stop. Do NOT commit a known-broken test — the
reviewer will reject it anyway and the loop wastes a retry budget.

If Behat times out or can't find the suite (e.g. behat.yml.dist absent),
write that in `AGENT-NOTE.md` along with the PHPUnit results and let
the reviewer decide. Don't ship without at least an explicit note about
which level you got coverage at.
