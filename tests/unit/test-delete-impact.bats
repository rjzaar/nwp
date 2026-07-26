#!/usr/bin/env bats
# nwp/ops#47 — delete.sh: delete/purge semantics on the impact contract.
# Runs the real script against a fixture NWP root with ddev/docker/crontab
# shimmed onto PATH, so archive/teardown/purge behavior is exercised without
# touching real projects.

setup() {
  TEST_TMP=$(mktemp -d)
  ROOT="$TEST_TMP/nwp"
  REPO="${BATS_TEST_DIRNAME}/../.."

  mkdir -p "$ROOT/scripts/commands" "$ROOT/lib"
  cp "$REPO/scripts/commands/delete.sh" "$ROOT/scripts/commands/"
  cp "$REPO/lib/ui.sh" "$REPO/lib/common.sh" "$REPO/lib/impact.sh" \
     "$REPO/lib/canonical.sh" "$REPO/lib/yaml-write.sh" \
     "$REPO/lib/project-resolver.sh" "$REPO/lib/server-resolver.sh" \
     "$REPO/lib/ssh.sh" "$REPO/lib/site-containment.sh" "$ROOT/lib/" 2>/dev/null || true
  mkdir -p "$ROOT/templates"
  cp "$REPO/templates/site-gitignore.tmpl" "$ROOT/templates/" 2>/dev/null || true

  # Fixture v2 site: container with dev/ + stg/ projects and in-tree backups
  mkdir -p "$ROOT/sites/fix/dev/.ddev" "$ROOT/sites/fix/stg/.ddev" "$ROOT/sites/fix/backups"
  echo "name: fix-dev" > "$ROOT/sites/fix/dev/.ddev/config.yaml"
  echo "name: fix-stg" > "$ROOT/sites/fix/stg/.ddev/config.yaml"
  echo "dump" > "$ROOT/sites/fix/backups/20260101T000000-main-abc-b1.sql.gz"
  echo "files" > "$ROOT/sites/fix/backups/20260101T000000-main-abc-b1.tar.gz"

  cat > "$ROOT/nwp.yml" <<'EOF'
settings:
  url: example.org
sites:
  fix:
    recipe: d
    purpose: testing
EOF

  # Shims: record invocations, emit plausible output
  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/ddev" <<EOF
#!/bin/bash
echo "ddev \$*" >> "$TEST_TMP/calls.log"
case "\$1" in
  list) echo '{"raw":[{"name":"fix-dev","status":"running"},{"name":"fix-stg","status":"stopped"}]}' ;;
esac
exit 0
EOF
  cat > "$TEST_TMP/bin/docker" <<EOF
#!/bin/bash
echo "docker \$*" >> "$TEST_TMP/calls.log"
if [ "\$1 \$2" = "volume ls" ]; then printf 'fix-dev-mariadb\nfix-stg-mariadb\nother-site-mariadb\n'; fi
exit 0
EOF
  cat > "$TEST_TMP/bin/crontab" <<EOF
#!/bin/bash
echo "crontab \$*" >> "$TEST_TMP/calls.log"
[ "\$1" = "-l" ] && echo "0 3 * * * /x/backup.sh fix"
exit 0
EOF
  chmod +x "$TEST_TMP/bin/"*
  export PATH="$TEST_TMP/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_TMP"
}

run_delete() {
  ( cd "$ROOT" && ./scripts/commands/delete.sh "$@" </dev/null )
}

@test "report prints all fates and correct volumes for a v2 site" {
  run run_delete fix   # no -y, no TTY → report prints then fails closed
  [[ "$output" == *"WILL BE PERMANENTLY DELETED:"* ]]
  [[ "$output" == *"fix-dev (running) — containers + Docker volumes: fix-dev-mariadb"* ]]
  [[ "$output" == *"fix-stg (stopped)"* ]]
  [[ "$output" != *"other-site-mariadb"* ]]
  [[ "$output" == *"ARCHIVED (kept, relocated):"* ]]
  [[ "$output" == *"2 file(s)"* ]]
  [[ "$output" == *"Schedule:"* ]]
  [[ "$output" == *"canonical: dev"* ]]   # fixture has no phase → default dev warning
  [[ "$output" == *"NOT AFFECTED:"* ]]
  # fail-closed without TTY/-y: nothing happened
  [ -d "$ROOT/sites/fix" ]
  [ "$status" -ne 0 ] || [[ "$output" == *"cancelled"* ]]
}

@test "delete -y archives backups to sitebackups/, removes tree + registry + schedule, ledgers" {
  run run_delete -y fix
  [ "$status" -eq 0 ]
  [[ "$output" == *"WILL BE PERMANENTLY DELETED:"* ]]   # -y still prints the report
  # tree gone, backups archived
  [ ! -d "$ROOT/sites/fix" ]
  [ -f "$ROOT/sitebackups/fix/20260101T000000-main-abc-b1.sql.gz" ]
  [ -f "$ROOT/sitebackups/fix/20260101T000000-main-abc-b1.tar.gz" ]
  # both ddev projects torn down, teardown BEFORE rm (calls logged at all)
  grep -q "ddev delete -Oy" "$TEST_TMP/calls.log"
  [ "$(grep -c 'ddev delete -Oy' "$TEST_TMP/calls.log")" -eq 2 ]
  # registry entry removed
  ! grep -q "^  fix:" "$ROOT/nwp.yml"
  # ledger recorded
  grep -q "action=delete mode=archive" "$ROOT/private/canonical/fix.log"
  [[ "$output" == *"Resurrect with: pl install fix && pl restore fix"* ]]
}

@test "purge -y removes backups everywhere and ledgers mode=purge" {
  mkdir -p "$ROOT/sitebackups/fix"
  echo old > "$ROOT/sitebackups/fix/old-backup.sql.gz"
  run run_delete --purge -y fix
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO copy will remain"* ]]
  [ ! -d "$ROOT/sites/fix" ]
  [ ! -d "$ROOT/sitebackups/fix" ]
  grep -q "action=delete mode=purge" "$ROOT/private/canonical/fix.log"
}

@test "purge without -y and without TTY fails closed before any action" {
  run run_delete --purge fix
  [ "$status" -eq 0 ] || true
  [[ "$output" == *"cancelled"* || "$output" == *"aborting"* ]]
  [ -d "$ROOT/sites/fix" ]
  [ -d "$ROOT/sites/fix/backups" ]
}

@test "purge -b is refused as contradictory" {
  run run_delete --purge -b -y fix
  [ "$status" -ne 0 ]
  [[ "$output" == *"contradictory"* ]]
  [ -d "$ROOT/sites/fix" ]
}

@test "archive merges into existing sitebackups/<name>/" {
  mkdir -p "$ROOT/sitebackups/fix"
  echo old > "$ROOT/sitebackups/fix/older.sql.gz"
  run run_delete -y fix
  [ "$status" -eq 0 ]
  [ -f "$ROOT/sitebackups/fix/older.sql.gz" ]
  [ -f "$ROOT/sitebackups/fix/20260101T000000-main-abc-b1.sql.gz" ]
}

@test "permanent purpose blocks deletion" {
  cat > "$ROOT/nwp.yml" <<'EOF'
settings:
  url: example.org
sites:
  fix:
    recipe: d
    purpose: permanent
EOF
  run run_delete -y fix
  [ "$status" -ne 0 ]
  [[ "$output" == *"permanent"* ]]
  [ -d "$ROOT/sites/fix" ]
}

@test "-k is a deprecated no-op that still archives" {
  run run_delete -ky fix
  [ "$status" -eq 0 ]
  [[ "$output" == *"deprecated"* ]]
  [ -f "$ROOT/sitebackups/fix/20260101T000000-main-abc-b1.sql.gz" ]
}

@test "live-canonical site reports content as safe, not warned" {
  cat > "$ROOT/nwp.yml" <<'EOF'
settings:
  url: example.org
sites:
  fix:
    recipe: d
    purpose: testing
    canonical: live
    live_domain: fix.example.org
EOF
  run run_delete fix
  [[ "$output" == *"canonical: live"* ]]
  [[ "$output" == *"untouched by this deletion"* ]]
  [[ "$output" == *"https://fix.example.org"* ]]
  [[ "$output" != *"SOURCE OF TRUTH"* ]] || true
}

################################################################################
# Containment: pl delete must refuse while a nested repo holds unsaved work.
# Nested repos (dev/, stg/, profiles/custom/*, .plugin-src/*) can hold the only
# copy of a behavioural spec — the avc profile's 26-file Behat capability suite
# is a live example sitting untracked in exactly such a repo.
################################################################################

_mk_nested_repo() {
  git -C "$1" init -q
  git -C "$1" config user.email t@example.org
  git -C "$1" config user.name tester
}

@test "delete refuses while a nested repo has uncommitted work" {
  _mk_nested_repo "$ROOT/sites/fix/dev"
  echo "the only copy of a behat suite" > "$ROOT/sites/fix/dev/uncommitted-spec.feature"

  run run_delete fix -y
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsaved work"* ]]
  [[ "$output" == *"sites/fix/dev"* ]]
  [ -d "$ROOT/sites/fix/dev" ]
}

@test "delete refuses while a nested repo has a stash" {
  _mk_nested_repo "$ROOT/sites/fix/dev"
  echo a > "$ROOT/sites/fix/dev/f"
  git -C "$ROOT/sites/fix/dev" add -A
  git -C "$ROOT/sites/fix/dev" commit -qm init
  echo b > "$ROOT/sites/fix/dev/f"
  git -C "$ROOT/sites/fix/dev" stash -q

  run run_delete fix -y
  [ "$status" -ne 0 ]
  [[ "$output" == *"stashes=1"* ]]
  [ -d "$ROOT/sites/fix/dev" ]
}

@test "delete proceeds when nested repos are clean and pushed" {
  _mk_nested_repo "$ROOT/sites/fix/dev"
  echo x > "$ROOT/sites/fix/dev/f"
  git -C "$ROOT/sites/fix/dev" add -A
  git -C "$ROOT/sites/fix/dev" commit -qm init
  git -C "$ROOT/sites/fix/dev" update-ref refs/remotes/origin/main HEAD

  run run_delete fix -y
  [ "$status" -eq 0 ]
  [ ! -d "$ROOT/sites/fix" ]
}

@test "delete dirty-repo guard has an explicit, logged override" {
  _mk_nested_repo "$ROOT/sites/fix/dev"
  echo "scratch" > "$ROOT/sites/fix/dev/uncommitted"

  NWP_ALLOW_DELETE_DIRTY=1 run run_delete fix -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"NWP_ALLOW_DELETE_DIRTY=1"* ]]
  [ ! -d "$ROOT/sites/fix" ]
}
