#!/usr/bin/env bats
# Programme item 9 — `moodle-ops-verbs`: five live Moodle instances must be
# administered through `pl`, not hand-ssh + tribal knowledge.
#
# ACCEPTANCE TESTS. Each one was run against the PRE-FIX tree and observed RED
# (see the MR description for the captured output). They cover, in order:
#
#   (a) `pl moodle cli`        — a Moodle twin of `pl drush`. The plan MUST carry
#                                the resolved php binary AND -d max_input_vars=5000,
#                                and MUST exit non-zero if either is missing.
#                                RED pre-fix: the verb did not exist at all, and
#                                `max_input_vars` appeared NOWHERE in
#                                lib/moodle-deploy.sh — so `pl moodle upgrade
#                                --apply` reproduced the ~6 min ss.nwpcode.org
#                                outage of 2026-07-26 (upgrade.php fails its env
#                                check and LEAVES MAINTENANCE MODE ON).
#   (b) `pl moodle maintenance`— there must always be a one-verb way OUT of
#                                maintenance mode. RED pre-fix: moodle_maintenance()
#                                existed at lib/moodle-deploy.sh:306 and was
#                                unreachable from the CLI.
#   (c) core patches           — a declared core patch that is NOT applied on the
#                                target must fail the deploy closed. RED pre-fix:
#                                no such concept; ssc's live front door
#                                (`redirect(new moodle_url('/local/browse/'))` in
#                                Moodle core index.php) existed only as an
#                                uncommitted working-tree diff.
#   (d) `pl moodle plugin drift`— version.php disagreement across copies must fail.
#                                RED pre-fix: verb absent; scripts/f26/moodle/
#                                auth_nwc is 2026071101/1.0.0 while every other
#                                copy (and live ssc) is 2026072400/1.2.0-draft.
#   (e) get_data_secret        — a 4-level dotted path must resolve. RED pre-fix:
#                                the 2-level awk returned the DEFAULT for
#                                `moodle.<site>.<tier>.db_password`, which is
#                                exactly what lib/moodle-promote.sh:101 passes,
#                                so moodle_write_config wrote an EMPTY dbpass.
#   (f) `pl doc-truth`         — must flag raw `ssh … drush` / `ssh … admin/cli`
#                                shapes in docs/guides/**. RED pre-fix: no rule.
#
# NO ssh, NO ddev, NO network, NO secrets: every case runs on throwaway fixtures.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  MOODLE="${REPO_ROOT}/scripts/commands/moodle.sh"
  export PROJECT_ROOT="${TEST_TMP}/nwp"
  mkdir -p "${PROJECT_ROOT}/sites/ssd/dev"

  # A fixture Moodle site with a live tier configured (bogus, unrouted IP —
  # nothing in these tests ever connects).
  cat > "${PROJECT_ROOT}/sites/ssd/.nwp.yml" <<'EOF'
schema_version: 2
project:
  name: ssd
  type: moodle
live:
  enabled: true
  domain: ssd.example.org
  server_ip: 203.0.113.11
  ssh_user: gitlab
  remote_path: /var/www/ssd
moodle:
  cli_php_version: "8.2"
  plugins:
    - path: auth/nwc
    - path: local/practice
EOF
}

teardown() { rm -rf "${TEST_TMP}"; }

# ── (a) pl moodle cli ────────────────────────────────────────────────────────

@test "a1: pl moodle cli dry-run prints a plan carrying the php binary" {
  run bash "$MOODLE" cli ssd --tier=live --dry-run -- admin/cli/purge_caches.php
  [ "$status" -eq 0 ]
  [[ "$output" == *"php8.2"* ]]
}

@test "a2: pl moodle cli dry-run plan carries -d max_input_vars=5000" {
  run bash "$MOODLE" cli ssd --tier=live --dry-run -- admin/cli/purge_caches.php
  [ "$status" -eq 0 ]
  [[ "$output" == *"max_input_vars=5000"* ]]
}

@test "a3: pl moodle cli SELF-ASSERTS — exits non-zero if the plan loses max_input_vars" {
  # The box gotcha is not documentation, it is an assertion: if the resolved
  # command does not carry the override, the verb must refuse rather than run a
  # command that leaves the site in maintenance mode.
  NWP_MOODLE_CLI_PHP_OPTS=" " run bash "$MOODLE" cli ssd --tier=live --dry-run -- admin/cli/purge_caches.php
  [ "$status" -ne 0 ]
  [[ "$output" == *"max_input_vars"* ]]
}

@test "a4: pl moodle cli SELF-ASSERTS — exits non-zero when no php binary resolves" {
  NWP_MOODLE_CLI_PHP_BIN=" " run bash "$MOODLE" cli ssd --tier=live --dry-run -- admin/cli/purge_caches.php
  [ "$status" -ne 0 ]
  # non-vacuous: must name the php binary, not just be an "unknown subcommand"
  [[ "$output" == *"php binary"* ]]
}

@test "a5: pl moodle cli is DRY-RUN by default on live (no --execute ⇒ nothing runs)" {
  run bash "$MOODLE" cli ssd --tier=live -- admin/cli/purge_caches.php
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
  [[ "$output" != *"completed on live"* ]]
}

@test "a6: pl moodle cli refuses a script path outside admin/cli" {
  # a non-cli path hits the generic containment arm…
  run bash "$MOODLE" cli ssd --tier=live --dry-run -- lib/upgrade.php
  [ "$status" -ne 0 ]
  [[ "$output" == *"admin/cli"* ]]
  # …and traversal is refused even earlier, by the '..' guard (ops#279 moved it
  # ahead of the shape check so a dotted path can never reach the plugin arm)
  run bash "$MOODLE" cli ssd --tier=live --dry-run -- ../../etc/passwd
  [ "$status" -ne 0 ]
  [[ "$output" == *".."* ]]
}

@test "a7: pl moodle cli refuses with no script given" {
  run bash "$MOODLE" cli ssd --tier=live --dry-run --
  [ "$status" -ne 0 ]
  [[ "$output" == *"No CLI script"* ]]
}

# ── (a8–a11) a DECLARED plugin's OWN cli/ dir — ops#279 ──────────────────────
# WHY: half the estate's Moodle CLI scripts do not live in admin/cli at all.
# `local/practice/cli/sync_practice_defs.php` is the ONLY way to populate the
# practice-checkpoint definitions, and refusing it pushed the 2026-08-07 ops#279
# runbook toward raw ssh — the exact idiom the standing order forbids and
# `lint:doc-truth`'s raw-remote-cli rule fails a guide for.
#
# Containment is NOT relaxed, it is re-stated: the plugin must be one the SITE
# ITSELF DECLARES in `.moodle.plugins[].path`, the dir must be that plugin's own
# `cli/`, and the leaf must be a bare `<name>.php`. A plugin the site does not
# run is not reachable, so this cannot become an arbitrary-file php runner.

@test "a8: pl moodle cli ACCEPTS a declared plugin's own cli/ script" {
  run bash "$MOODLE" cli ssd --tier=live --dry-run -- local/practice/cli/sync_practice_defs.php --from-db
  [ "$status" -eq 0 ]
  [[ "$output" == *"local/practice/cli/sync_practice_defs.php"* ]]
  # the box knowledge must still be carried — a second entry point is not a
  # second set of rules
  [[ "$output" == *"php8.2"* ]]
  [[ "$output" == *"max_input_vars=5000"* ]]
}

@test "a9: pl moodle cli REFUSES a cli/ script of a plugin the site does not declare" {
  run bash "$MOODLE" cli ssd --tier=live --dry-run -- local/evil/cli/pwn.php
  [ "$status" -ne 0 ]
  [[ "$output" == *"local/evil"* ]]
  [[ "$output" == *"declare"* ]]
}

@test "a10: pl moodle cli REFUSES traversal dressed as a plugin cli/ path" {
  run bash "$MOODLE" cli ssd --tier=live --dry-run -- local/practice/cli/../../../etc/passwd.php
  [ "$status" -ne 0 ]
  [[ "$output" == *".."* ]]
}

@test "a11: pl moodle cli REFUSES a declared plugin's NON-cli directory" {
  run bash "$MOODLE" cli ssd --tier=live --dry-run -- local/practice/classes/engine.php
  [ "$status" -ne 0 ]
  [[ "$output" == *"cli/"* ]]
}

# ── (a12–a13) -y/--yes — ops#279 ─────────────────────────────────────────────
# WHY: lib/impact.sh's no-TTY refusal says "and -y not given", but moodle.sh
# never parsed -y — so every live --apply from a non-interactive session (the
# operator-approved 2026-08-07 consent-arc deploy, any CI job) aborted with an
# error naming a flag that did not exist. delete.sh/cutover.sh already parse it.

@test "a12: pl moodle cli parses -y (the flag impact_confirm's own refusal names)" {
  run bash "$MOODLE" cli ssd --tier=live --dry-run -y -- admin/cli/purge_caches.php
  [ "$status" -eq 0 ]
  [[ "$output" != *"Unknown option"* ]]
}

@test "a13: pl moodle plugin deploy parses -y" {
  run bash "$MOODLE" plugin deploy ssd local/practice --tier=live -y
  [[ "$output" != *"Unknown option: -y"* ]]
}

# ── (b) pl moodle maintenance ────────────────────────────────────────────────

@test "b1: pl moodle maintenance off dry-run prints the disable command" {
  run bash "$MOODLE" maintenance ssd --tier=live off --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"maintenance.php"* ]]
  [[ "$output" == *"--disable"* ]]
}

@test "b2: pl moodle maintenance on dry-run prints the enable command" {
  run bash "$MOODLE" maintenance ssd --tier=live on --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"--enable"* ]]
}

@test "b3: pl moodle maintenance refuses an unknown action" {
  run bash "$MOODLE" maintenance ssd --tier=live sideways --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"on|off"* ]]
}

@test "b4: pl moodle maintenance OFF is allowed without --execute ceremony blocking recovery" {
  # Getting OUT of maintenance must never be harder than getting in.
  run bash "$MOODLE" maintenance ssd --tier=live off --dry-run
  [ "$status" -eq 0 ]
}

# ── (c) declared core patches ────────────────────────────────────────────────

@test "c1: a declared core patch that is NOT applied on the target fails closed" {
  local root="${TEST_TMP}/webroot"
  mkdir -p "${root}"
  echo "<?php // stock moodle index" > "${root}/index.php"
  cat > "${PROJECT_ROOT}/sites/ssd/core-patches.yml" <<'EOF'
core_patches:
  - id: ssd-index-browse-frontdoor
    file: index.php
    assert: "local/browse"
    why: "guest front door redirects to local_browse"
EOF
  run bash "$MOODLE" core-patch status ssd --root="${root}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING"* ]]
}

@test "c2: a declared core patch that IS applied passes" {
  local root="${TEST_TMP}/webroot2"
  mkdir -p "${root}"
  printf '<?php\nredirect(new moodle_url("/local/browse/"));\n' > "${root}/index.php"
  cat > "${PROJECT_ROOT}/sites/ssd/core-patches.yml" <<'EOF'
core_patches:
  - id: ssd-index-browse-frontdoor
    file: index.php
    assert: "local/browse"
    why: "guest front door redirects to local_browse"
EOF
  run bash "$MOODLE" core-patch status ssd --root="${root}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"APPLIED"* ]]
}

@test "c5: the CANONICAL declaration in the plugin-repo cache is found (not just the site-local one)" {
  # Rung 2 of the resolution order: sites/* is gitignored, so a declaration that
  # lives only there is the same disease as the unversioned patch it catches.
  local cache="${PROJECT_ROOT}/sites/ssd/.plugin-src/ss-moodle-plugins/core-patches"
  mkdir -p "${cache}"
  cat > "${cache}/ssd.yml" <<'EOF'
core_patches:
  - id: from-canonical-repo
    file: index.php
    assert: "local/browse"
    why: "canonical declaration, version-controlled in nwp/ss-moodle-plugins"
EOF
  local root="${TEST_TMP}/webroot5"
  mkdir -p "${root}"; echo "<?php // stock" > "${root}/index.php"
  run bash "$MOODLE" core-patch status ssd --root="${root}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"from-canonical-repo"* ]]
  [[ "$output" == *"MISSING"* ]]
}

@test "c4: plugin deploy REFUSES when a declared core patch cannot be verified on the target" {
  # The live host here is TEST-NET-3 (unroutable): the remote check comes back
  # UNREACHABLE, which must be treated as "cannot verify" ⇒ refuse, NOT as
  # "probably fine". Runs on --dry-run, so the refusal is visible without --apply.
  cat > "${PROJECT_ROOT}/sites/ssd/core-patches.yml" <<'EOF'
core_patches:
  - id: ssd-index-browse-frontdoor
    file: index.php
    assert: "local/browse"
    why: "guest front door redirects to local_browse"
EOF
  run bash "$MOODLE" plugin deploy ssd auth/nwc --tier=live --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"core patch"* ]]
}

@test "c3: no declared patches ⇒ core-patch status is a clean no-op, not a false green" {
  local root="${TEST_TMP}/webroot3"
  mkdir -p "${root}"; echo "<?php" > "${root}/index.php"
  run bash "$MOODLE" core-patch status ssd --root="${root}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no core patches declared"* ]]
}

# ── (d) pl moodle plugin drift ───────────────────────────────────────────────

@test "d1: plugin drift exits non-zero when two trees disagree on version" {
  mkdir -p "${TEST_TMP}/a/auth/nwc" "${TEST_TMP}/b/auth/nwc"
  echo '<?php $plugin->version = 2026071102;' > "${TEST_TMP}/a/auth/nwc/version.php"
  echo '<?php $plugin->version = 2026072400;' > "${TEST_TMP}/b/auth/nwc/version.php"
  run bash "$MOODLE" plugin drift ssd auth/nwc \
      --tree="${TEST_TMP}/a" --tree="${TEST_TMP}/b" --no-live
  [ "$status" -ne 0 ]
  [[ "$output" == *"DRIFT"* ]]
}

@test "d2: plugin drift exits zero when every tree agrees" {
  mkdir -p "${TEST_TMP}/c/auth/nwc" "${TEST_TMP}/d/auth/nwc"
  echo '<?php $plugin->version = 2026072400;' > "${TEST_TMP}/c/auth/nwc/version.php"
  echo '<?php $plugin->version = 2026072400;' > "${TEST_TMP}/d/auth/nwc/version.php"
  run bash "$MOODLE" plugin drift ssd auth/nwc \
      --tree="${TEST_TMP}/c" --tree="${TEST_TMP}/d" --no-live
  [ "$status" -eq 0 ]
}

@test "d3: plugin drift refuses to report clean when it saw fewer than 2 copies" {
  # 'no copies found' must not read as 'everything agrees' — the vacuous-pass class.
  mkdir -p "${TEST_TMP}/e"
  run bash "$MOODLE" plugin drift ssd auth/nwc --tree="${TEST_TMP}/e" --no-live
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot verify"* ]]
}

# ── (e) get_data_secret depth ────────────────────────────────────────────────

@test "e1: get_data_secret resolves a 4-level dotted path" {
  cat > "${PROJECT_ROOT}/.secrets.data.yml" <<'EOF'
moodle:
  ssc:
    stg:
      db_password: SENTINEL_VALUE_XYZ
EOF
  run bash -c "PROJECT_ROOT='${PROJECT_ROOT}' . '${REPO_ROOT}/lib/common.sh' >/dev/null 2>&1; get_data_secret 'moodle.ssc.stg.db_password' 'DEFAULT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SENTINEL_VALUE_XYZ"* ]]
}

@test "e2: get_data_secret still resolves a 2-level dotted path (no regression)" {
  cat > "${PROJECT_ROOT}/.secrets.data.yml" <<'EOF'
production_database:
  password: flat2level
EOF
  run bash -c "PROJECT_ROOT='${PROJECT_ROOT}' . '${REPO_ROOT}/lib/common.sh' >/dev/null 2>&1; get_data_secret 'production_database.password' 'DEFAULT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"flat2level"* ]]
}

@test "e3: get_data_secret distinguishes file-absent (2) from key-absent (3)" {
  run bash -c "PROJECT_ROOT='${PROJECT_ROOT}' . '${REPO_ROOT}/lib/common.sh' >/dev/null 2>&1; get_data_secret 'moodle.x.y.z' 'D' >/dev/null; echo \$?"
  [[ "$output" == *"2"* ]]
  cat > "${PROJECT_ROOT}/.secrets.data.yml" <<'EOF'
moodle:
  ssc:
    stg:
      db_password: S
EOF
  run bash -c "PROJECT_ROOT='${PROJECT_ROOT}' . '${REPO_ROOT}/lib/common.sh' >/dev/null 2>&1; get_data_secret 'moodle.nope.stg.db_password' 'D' >/dev/null; echo \$?"
  [[ "$output" == *"3"* ]]
}

@test "e4: moodle_write_config REFUSES to write an empty dbpass on a non-ddev tier" {
  local root="${TEST_TMP}/mroot"
  mkdir -p "${root}"
  echo "<?php \$plugin->version=2026010100;" > "${root}/version.php"
  cat > "${TEST_TMP}/site.yml" <<'EOF'
schema_version: 2
project:
  name: zzsite
  type: moodle
moodle:
  tiers:
    stg:
      wwwroot: https://zz.ddev.site
EOF
  run bash -c "PROJECT_ROOT='${PROJECT_ROOT}' . '${REPO_ROOT}/lib/ui.sh' >/dev/null 2>&1; . '${REPO_ROOT}/lib/common.sh' >/dev/null 2>&1; . '${REPO_ROOT}/lib/moodle-promote.sh' >/dev/null 2>&1; moodle_write_config '${root}' stg '${TEST_TMP}/site.yml'"
  [ "$status" -ne 0 ]
  [ ! -f "${root}/config.php" ]
}

@test "e5: moodle_write_config still writes when dbpass_ddev_default is set" {
  local root="${TEST_TMP}/mroot2"
  mkdir -p "${root}"
  echo "<?php \$plugin->version=2026010100;" > "${root}/version.php"
  cat > "${TEST_TMP}/site2.yml" <<'EOF'
schema_version: 2
project:
  name: zzsite
  type: moodle
moodle:
  tiers:
    dev:
      wwwroot: https://zz.ddev.site
      dbpass_ddev_default: true
EOF
  run bash -c "PROJECT_ROOT='${PROJECT_ROOT}' . '${REPO_ROOT}/lib/ui.sh' >/dev/null 2>&1; . '${REPO_ROOT}/lib/common.sh' >/dev/null 2>&1; . '${REPO_ROOT}/lib/moodle-promote.sh' >/dev/null 2>&1; moodle_write_config '${root}' dev '${TEST_TMP}/site2.yml'"
  [ "$status" -eq 0 ]
  [ -f "${root}/config.php" ]
}

# ── (f) pl doc-truth raw-remote-cli rule ─────────────────────────────────────

@test "f1: doc-truth flags a raw 'ssh … drush' line planted in a fixture guide" {
  mkdir -p "${PROJECT_ROOT}/docs/guides" "${PROJECT_ROOT}/docs/decisions"
  cat > "${PROJECT_ROOT}/docs/guides/fixture-guide.md" <<'EOF'
# Fixture guide

```bash
ssh gitlab@<prod-box> "cd /var/www/nwc && sudo -u www-data ./vendor/bin/drush cr"
```
EOF
  run bash "${REPO_ROOT}/scripts/commands/doc-truth.sh" --all
  [ "$status" -ne 0 ]
  [[ "$output" == *"raw-remote-cli"* ]]
}

@test "f2: doc-truth flags a raw 'ssh … admin/cli' line planted in a fixture guide" {
  mkdir -p "${PROJECT_ROOT}/docs/guides" "${PROJECT_ROOT}/docs/decisions"
  cat > "${PROJECT_ROOT}/docs/guides/fixture-guide2.md" <<'EOF'
# Fixture guide 2

```bash
ssh gitlab@<prod-box> "cd /var/www/ssc && sudo -u www-data php8.2 admin/cli/upgrade.php"
```
EOF
  run bash "${REPO_ROOT}/scripts/commands/doc-truth.sh" --all
  [ "$status" -ne 0 ]
  [[ "$output" == *"raw-remote-cli"* ]]
}

@test "f4: doc-truth catches the ALIAS evasion (a shell var holding the remote drush)" {
  # NWC-LIVE-DEPLOY-RUNBOOK does exactly this: it assigns the remote drush to $D
  # and then writes `ssh … "$D updatedb -y"`. A rule that only matches
  # `ssh … drush` reads that whole runbook as compliant — a gate a shell
  # variable defeats is a vacuous gate.
  mkdir -p "${PROJECT_ROOT}/docs/guides" "${PROJECT_ROOT}/docs/decisions"
  cat > "${PROJECT_ROOT}/docs/guides/fixture-guide4.md" <<'EOF'
# Fixture guide 4

```bash
D="sudo -u www-data /var/www/nwc/vendor/bin/drush --root=/var/www/nwc/html"
ssh gitlab@<prod-box> "$D updatedb -y"
```
EOF
  run bash "${REPO_ROOT}/scripts/commands/doc-truth.sh" --all
  [ "$status" -ne 0 ]
  [[ "$output" == *"raw-remote-cli"* ]]
  [[ "$output" == *"fixture-guide4.md"* ]]
}

@test "f3: doc-truth does NOT flag a pl-shaped command" {
  mkdir -p "${PROJECT_ROOT}/docs/guides" "${PROJECT_ROOT}/docs/decisions"
  cat > "${PROJECT_ROOT}/docs/guides/fixture-guide3.md" <<'EOF'
# Fixture guide 3

```bash
pl drush nwc --tier=live --execute -- cr
pl moodle cli ssc --tier=live --execute -- admin/cli/upgrade.php --non-interactive
```
EOF
  run bash "${REPO_ROOT}/scripts/commands/doc-truth.sh" --all
  [[ "$output" != *"raw-remote-cli|docs/guides/fixture-guide3.md"* ]]
}
