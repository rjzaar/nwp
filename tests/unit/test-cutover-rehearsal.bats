#!/usr/bin/env bats
# scripts/commands/cutover.sh — STATIC assertions on run_rehearsal (the nwc
# un-fork REHEARSAL gate). These are source-level greps/awk over cutover.sh, not
# behavioural runs: the real rehearsal needs a live host + a DDEV container, so
# behaviour is exercised (with mocks) in test-cutover.bats. Here we lock in the
# two bugfixes so they can't silently regress:
#
#   BUG 1  the pulled live DB dump was NEVER imported into the stg scratch DB, so
#          updatedb ran against stg's OWN fresh DB, not the live member DB.
#   BUG 2  the rehearsal ran `pm:uninstall tracer nwp_lockdown` on stg, but the
#          new un-forked build ships no code for those modules, so drush aborts
#          "module does not exist" and the rehearsal fails-closed spuriously.
#
# The fix: import the dump (ddev import-db) between the dump-pull and updatedb,
# and DE-REGISTER the 2 modules at the DB level (system.schema + core.extension)
# tolerantly instead of pm:uninstall.

CUTOVER="${BATS_TEST_DIRNAME}/../../scripts/commands/cutover.sh"

# ── the source parses ────────────────────────────────────────────────────────

@test "cutover.sh is syntactically valid" {
  run bash -n "$CUTOVER"
  [ "$status" -eq 0 ]
}

# Extract the run_rehearsal function body (from its def to the next top-level
# `}` at column 0) so ordering assertions are scoped to the rehearsal.
_rehearsal_body() {
  awk '/^run_rehearsal\(\)/{f=1} f{print} f&&/^}/{exit}' "$CUTOVER"
}

# ── BUG 1: the pulled dump is imported into stg before updatedb ──────────────

@test "run_rehearsal imports the pulled live dump into the stg scratch DB" {
  _rehearsal_body | grep -Eq 'ddev[[:space:]]+import-db|import-db|import_db'
}

@test "the import happens BETWEEN the dump-pull and the updatedb (correct order)" {
  body="$(_rehearsal_body)"
  pull_ln="$(printf '%s\n' "$body"  | grep -n -- 'backup --remote' | head -1 | cut -d: -f1)"
  imp_ln="$(printf '%s\n'  "$body"  | grep -n -- 'import-db'       | head -1 | cut -d: -f1)"
  upd_ln="$(printf '%s\n'  "$body"  | grep -n -- 'updatedb -y'     | head -1 | cut -d: -f1)"
  [ -n "$pull_ln" ] && [ -n "$imp_ln" ] && [ -n "$upd_ln" ]
  [ "$pull_ln" -lt "$imp_ln" ]
  [ "$imp_ln"  -lt "$upd_ln" ]
}

@test "the imported dump is the newest sites/<site>/backups remote artifact" {
  _rehearsal_body | grep -Eq 'get_backup_dir|backups/'
  _rehearsal_body | grep -Eq -- '-remote-\*\.sql\.gz'
}

@test "the stg scratch surface is resolved with the same resolver --tier=stg uses" {
  _rehearsal_body | grep -Eq 'resolve_project[[:space:]]+"\$SITE"[[:space:]]+stg'
}

@test "a failed import fails the rehearsal closed (records failed, blocks execute)" {
  # the import is guarded and records a failed rehearsal on error
  _rehearsal_body | grep -Eq 'import-db.*\|\||if ! \(.*import-db'
  _rehearsal_body | grep -q 'record_rehearse "failed"'
}

# ── BUG 2: no pm:uninstall in the rehearsal; tolerant DB-level de-registration ─

@test "run_rehearsal does NOT pm:uninstall tracer/nwp_lockdown on the stg path" {
  ! _rehearsal_body | grep -Eq 'pm:uninstall[[:space:]]+tracer[[:space:]]+nwp_lockdown'
}

@test "the non-survivable modules are de-registered at the DB level instead" {
  # the de-registration idiom: drop from system.schema AND core.extension
  run grep -Eq "keyValue\\(\"system.schema\"\\)" "$CUTOVER"
  [ "$status" -eq 0 ]
  run grep -Eq "getEditable\\(\"core.extension\"\\)" "$CUTOVER"
  [ "$status" -eq 0 ]
  # via php:eval, never pm:uninstall, for these two
  run grep -q 'php:eval' "$CUTOVER"
  [ "$status" -eq 0 ]
}

@test "run_rehearsal invokes the de-registration helper (not pm:uninstall)" {
  _rehearsal_body | grep -q 'rehearsal_deregister_nonsurvivable'
}

@test "the de-registration is TOLERANT of an already-absent module" {
  # helper guards each removal with array_key_exists (absent = no-op) and the
  # call site swallows a non-zero (warn + continue), so a to-be-removed module
  # that is already gone never fails the rehearsal.
  run grep -q 'array_key_exists' "$CUTOVER"
  [ "$status" -eq 0 ]
  _rehearsal_body | grep -Eq 'rehearsal_deregister_nonsurvivable.*\|\||\\$'
  # the call site must not hard-abort on a non-zero de-registration
  run grep -Eq 'rehearsal_deregister_nonsurvivable "\$stg_dir" \\' "$CUTOVER"
  [ "$status" -eq 0 ]
  grep -A2 'rehearsal_deregister_nonsurvivable "\$stg_dir"' "$CUTOVER" | grep -q 'print_warning'
}

# ── the real gate survives: updatedb + hook-scan + fail-closed record ────────

@test "updatedb still runs on the stg scratch surface" {
  _rehearsal_body | grep -q -- 'drush "\$SITE" --tier=stg -- updatedb -y'
}

@test "the hook-failure scan is intact (fail/exception/error)" {
  _rehearsal_body | grep -Eq "grep -Eiq 'fail\\|exception\\|error'"
}

@test "the fail-closed record path is intact (record failed on any problem)" {
  # a non-zero updatedb AND a failing-hook string both record failed
  n="$(_rehearsal_body | grep -c 'record_rehearse "failed"')"
  [ "$n" -ge 3 ]
  _rehearsal_body | grep -q 'record_rehearse "passed"'
}

@test "the post-rehearsal 'rebuild stg' note is preserved" {
  _rehearsal_body | grep -q "pl dev2stg \$SITE --dev-db"
}
