#!/usr/bin/env bats
# lib/migrations/site/003-site-class.sh — the class-key migration (NWP-ADR-0036).
#
# THE PROPERTY UNDER TEST: this migration GUESSES NOTHING. It writes the key as
# null (a visible unanswered question), never a value — because under NWP-ADR-0036 a
# class value is the assertion that switches the Art.9 consent gate's shape, and
# a machine may not make that assertion on no evidence. The handover that
# rescued this branch recorded that the migration shipped with NO test at all;
# these are that test.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  SITE_DIR="${TEST_TMP}/sites/m3site"
  mkdir -p "$SITE_DIR"
  CONFIG="${SITE_DIR}/.nwp.yml"

  # shellcheck source=/dev/null
  source "${REPO_ROOT}/lib/migrations/site/003-site-class.sh"
}

teardown() { rm -rf "$TEST_TMP"; }

@test "003 adds class as NULL (an unanswered question, not a default) and bumps schema to 3" {
  cat > "$CONFIG" <<'EOF'
schema_version: 2
project:
  name: m3site
EOF
  run migrate_002_to_003 "$SITE_DIR" "$CONFIG"
  [ "$status" -eq 0 ]

  [ "$(yq eval '.schema_version' "$CONFIG")" = "3" ]
  # the key must EXIST (a visible question) ...
  [ "$(yq eval 'has("class")' "$CONFIG")" = "true" ]
  # ... and its value must be null — never a guessed class
  [ "$(yq eval '.class' "$CONFIG")" = "null" ]
}

@test "003 leaves an already-declared class entirely alone" {
  cat > "$CONFIG" <<'EOF'
schema_version: 2
class: demo
EOF
  run migrate_002_to_003 "$SITE_DIR" "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$(yq eval '.class' "$CONFIG")" = "demo" ]
  [ "$(yq eval '.schema_version' "$CONFIG")" = "3" ]
}

@test "003 is idempotent: running it twice does not change the result" {
  cat > "$CONFIG" <<'EOF'
schema_version: 2
EOF
  migrate_002_to_003 "$SITE_DIR" "$CONFIG"
  first="$(cat "$CONFIG")"
  run migrate_002_to_003 "$SITE_DIR" "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$(cat "$CONFIG")" = "$first" ]
}

@test "003's null key resolves as UNDECLARED downstream (fails closed, not invalid)" {
  # The migrated file must read as "nobody has said yet" to lib/siteclass.sh —
  # not as an invalid class, and never as a permissive value.
  cat > "$CONFIG" <<'EOF'
schema_version: 2
EOF
  migrate_002_to_003 "$SITE_DIR" "$CONFIG"

  export PROJECT_ROOT="$TEST_TMP"
  export NWP_SITECLASS_DIR="${TEST_TMP}/classes"
  mkdir -p "$NWP_SITECLASS_DIR"
  cp "${REPO_ROOT}/classes/registry.yml" "${NWP_SITECLASS_DIR}/registry.yml"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/lib/siteclass.sh"

  run siteclass_of m3site
  [ "$status" -eq 1 ]
  [ "$output" = "undeclared" ]
}

@test "the shared runner applies 003 to a schema-2 site (end to end through _run_migrations)" {
  cat > "$CONFIG" <<'EOF'
schema_version: 2
EOF
  export NWP_DIR="$REPO_ROOT"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/lib/migrate-schema.sh"

  run _run_migrations "site" "m3site" "$CONFIG" 3 "$SITE_DIR"
  [ "$status" -eq 0 ]
  [ "$(yq eval '.schema_version' "$CONFIG")" = "3" ]
  [ "$(yq eval 'has("class")' "$CONFIG")" = "true" ]
  # the runner takes a pre-migration backup — the safety net must exist
  ls "${SITE_DIR}"/.nwp.yml.pre-migration-*.bak
}
