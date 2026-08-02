#!/usr/bin/env bats
# Item 4 — `pl-surfaces-report-reality`.
#
# These tests exist because five oversight surfaces were STRUCTURALLY VACUOUS:
# they ran, printed a positive assertion, and could never produce a finding.
#
#   (a) check_uncommitted_work  `continue`d on every site (no site has
#       sites/<n>/.git in the v2 layout — repos live at sites/<n>/dev/.git)
#   (b) check_verification      queried `.status == "fail"`; the real schema
#       records `machine.state.verified: true|false`
#   (c) pl backup sweep         a site with NO backup at all exits 0
#   (d) rag-sync                dark for 8 nights; no check reports on the
#       oversight machinery's own liveness
#   (e) pl --help               31 of 96 commands undocumented; they resolve
#       only through the `*)` script-name fallback
#
# Every case below was run against the PRE-FIX tree and observed RED first.

setup() {
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  FIX="$(mktemp -d "${BATS_TMPDIR:-/tmp}/nwp-todo-fixture.XXXXXX")"
  export FIX REPO_ROOT
}

teardown() {
  [ -n "${FIX:-}" ] && [ -d "$FIX" ] && rm -rf "$FIX"
}

# Build a fixture tree that looks like a real v2 NWP root.
_mkfixture() {
  mkdir -p "$FIX/sites" "$FIX/lib" "$FIX/logs" "$FIX/private"
  cat > "$FIX/nwp.yml" <<'YML'
sites:
  fixsite:
    directory: sites/fixsite
settings:
  todo: {}
YML
}

# Run a todo-checks function inside the fixture root and echo TODO_ITEMS.
_run_check() {
  local func="$1"
  TODO_CHECKS_PROJECT_ROOT="$FIX" NWP_DIR="$FIX" PROJECT_ROOT="$FIX" \
  TODO_CONFIG_FILE="$FIX/nwp.yml" \
  bash -c '
    set -uo pipefail
    source "'"$REPO_ROOT"'/lib/project-resolver.sh" 2>/dev/null || true
    source "'"$REPO_ROOT"'/lib/todo-checks.sh"
    '"$func"' >/dev/null 2>&1 || true
    printf "%s\n" "${TODO_ITEMS[@]:-}"
  '
}

################################################################################
# (a) GWK — nested repos under sites/<n>/dev/.git must be seen
################################################################################

@test "GWK: a dirty nested repo at sites/<n>/dev/.git produces a todo item" {
  _mkfixture
  mkdir -p "$FIX/sites/fixsite/dev"
  cat > "$FIX/sites/fixsite/.nwp.yml" <<'YML'
schema: 2
project:
  name: fixsite
YML
  git -C "$FIX/sites/fixsite/dev" init -q
  git -C "$FIX/sites/fixsite/dev" config user.email t@t
  git -C "$FIX/sites/fixsite/dev" config user.name t
  echo "untracked" > "$FIX/sites/fixsite/dev/loose-file.txt"

  run _run_check check_uncommitted_work
  [ "$status" -eq 0 ]
  echo "OUTPUT: $output" >&2
  [[ "$output" == *'"category":"GWK"'* ]]
  [[ "$output" == *"fixsite"* ]]
}

@test "GWK: a stash in a nested repo produces its own todo item" {
  _mkfixture
  mkdir -p "$FIX/sites/fixsite/dev"
  cat > "$FIX/sites/fixsite/.nwp.yml" <<'YML'
schema: 2
project:
  name: fixsite
YML
  git -C "$FIX/sites/fixsite/dev" init -q
  git -C "$FIX/sites/fixsite/dev" config user.email t@t
  git -C "$FIX/sites/fixsite/dev" config user.name t
  echo one > "$FIX/sites/fixsite/dev/a.txt"
  git -C "$FIX/sites/fixsite/dev" add a.txt
  git -C "$FIX/sites/fixsite/dev" commit -qm init
  echo two > "$FIX/sites/fixsite/dev/a.txt"
  git -C "$FIX/sites/fixsite/dev" stash -q

  run _run_check check_uncommitted_work
  [ "$status" -eq 0 ]
  echo "OUTPUT: $output" >&2
  [[ "$output" == *"stash"* ]]
}

@test "GWK: a clean nested repo produces NO item (test can go green honestly)" {
  _mkfixture
  mkdir -p "$FIX/sites/fixsite/dev"
  cat > "$FIX/sites/fixsite/.nwp.yml" <<'YML'
schema: 2
YML
  git -C "$FIX/sites/fixsite/dev" init -q
  git -C "$FIX/sites/fixsite/dev" config user.email t@t
  git -C "$FIX/sites/fixsite/dev" config user.name t
  echo one > "$FIX/sites/fixsite/dev/a.txt"
  git -C "$FIX/sites/fixsite/dev" add a.txt
  git -C "$FIX/sites/fixsite/dev" commit -qm init

  run _run_check check_uncommitted_work
  [ "$status" -eq 0 ]
  [[ "$output" != *'"category":"GWK"'* ]]
}

################################################################################
# (b) VER — the real .verification.yml schema is machine.state.verified
################################################################################

@test "VER: one 'verified: false' entry produces a VER todo item" {
  _mkfixture
  cat > "$FIX/.verification.yml" <<'YML'
features:
  backup:
    machine:
      state:
        verified: false
        verified_at: "2026-01-02T00:00:00Z"
  restore:
    machine:
      state:
        verified: true
        verified_at: "2026-07-20T00:00:00Z"
YML
  run _run_check check_verification
  [ "$status" -eq 0 ]
  echo "OUTPUT: $output" >&2
  [[ "$output" == *'"category":"VER"'* ]]
}

@test "VER: an all-verified file produces NO item" {
  _mkfixture
  # Vacuous-green guard: the check must actually exist.
  run bash -c 'source "'"$REPO_ROOT"'/lib/todo-checks.sh"; declare -F check_verification'
  [ "$status" -eq 0 ]

  cat > "$FIX/.verification.yml" <<YML
features:
  backup:
    machine:
      state:
        verified: true
        verified_at: "$(date -u -d '-1 day' +%Y-%m-%dT%H:%M:%SZ)"
YML
  run _run_check check_verification
  [ "$status" -eq 0 ]
  [[ "$output" != *'"category":"VER"'* ]]
}

@test "VER: stale verification dates are surfaced even when everything passed" {
  _mkfixture
  cat > "$FIX/.verification.yml" <<'YML'
features:
  backup:
    machine:
      state:
        verified: true
        verified_at: "2025-01-01T00:00:00Z"
YML
  run _run_check check_verification
  [ "$status" -eq 0 ]
  echo "OUTPUT: $output" >&2
  [[ "$output" == *"stale"* ]]
}

################################################################################
# (c) backup sweep — "never backed up" must not exit 0
################################################################################

@test "sweep: a site that has NEVER been backed up makes 'pl backup sweep --dry-run' exit non-zero" {
  _mkfixture
  mkdir -p "$FIX/sites/fixsite/dev/.ddev" "$FIX/sites/fixsite/backups"
  cat > "$FIX/sites/fixsite/.nwp.yml" <<'YML'
schema: 2
YML
  run env NWP_DIR="$FIX" PROJECT_ROOT="$FIX" TODO_CONFIG_FILE="$FIX/nwp.yml" \
      bash "$REPO_ROOT/scripts/commands/backup.sh" sweep --dry-run
  echo "STATUS: $status" >&2
  echo "OUTPUT: $output" >&2
  [ "$status" -ne 0 ]
  [[ "$output" == *"never"* ]]
}

################################################################################
# (d) loop liveness — the oversight machinery must report on itself
################################################################################

@test "LOOP: a rag-sync log whose last completed run is 9 days old produces a HIGH item" {
  _mkfixture
  local old
  old=$(date -u -d '-9 days' +%FT%TZ)
  {
    printf '%s rag-sync start\n' "$old"
    printf '%s rag-sync done (pl rag exit=0)\n' "$old"
  } > "$FIX/logs/rag-sync.log"

  run _run_check check_rag_sync_freshness
  [ "$status" -eq 0 ]
  echo "OUTPUT: $output" >&2
  [[ "$output" == *'"priority":"high"'* ]]
  [[ "$output" == *"rag-sync"* ]]
}

@test "LOOP: a fresh rag-sync log produces NO item" {
  # ops#230: "fresh log" is no longer sufficient for silence — the check also
  # asserts that a schedule exists to produce the NEXT run. State it in the
  # fixture rather than inheriting the test machine's crontab.
  export NWP_OVERSIGHT_CRON=present
  _mkfixture
  # Guard against a VACUOUS green: assert the check exists before asserting it
  # stayed quiet. Without this, deleting the function makes this test pass.
  run bash -c 'source "'"$REPO_ROOT"'/lib/todo-checks.sh"; declare -F check_rag_sync_freshness'
  [ "$status" -eq 0 ]

  printf '%s rag-sync done (pl rag exit=0)\n' "$(date -u +%FT%TZ)" > "$FIX/logs/rag-sync.log"
  run _run_check check_rag_sync_freshness
  [ "$status" -eq 0 ]
  [[ "$output" != *"rag-sync"* ]]
}

@test "LOOP: a global kill-switch that has been set for days is reported, not silent" {
  _mkfixture
  touch -d '-8 days' "$FIX/.loop-paused"
  run _run_check check_loop_liveness
  [ "$status" -eq 0 ]
  echo "OUTPUT: $output" >&2
  [[ "$output" == *'"category":"LOOP"'* ]]
  [[ "$output" == *"disabled"* || "$output" == *"dark"* || "$output" == *"kill"* ]]
}

@test "LOOP: check_agent_loop_cap fails OPEN loudly (no token = 'health unknown' item)" {
  _mkfixture
  # No .secrets.yml at all in the fixture root -> previously a silent `return 0`.
  run _run_check check_agent_loop_cap
  [ "$status" -eq 0 ]
  echo "OUTPUT: $output" >&2
  [[ "$output" == *"unknown"* ]]
}

################################################################################
# (e) pl --help must document every command
################################################################################

@test "help: every scripts/commands/*.sh appears in 'pl --help' (bar an explicit internals allowlist)" {
  run bash -c '
    cd "'"$REPO_ROOT"'"
    H="$(./pl --help 2>/dev/null)"
    miss=0
    for f in scripts/commands/*.sh; do
      b="$(basename "$f" .sh)"
      # anchored: the generated section lists one command per line as "  <name>  ..."
      if ! printf "%s\n" "$H" | grep -qE "^[[:space:]]+${b}([[:space:]]|$)"; then
        echo "MISSING: $b"
        miss=$((miss+1))
      fi
    done
    echo "missing=$miss"
    [ "$miss" -eq 0 ]
  '
  echo "OUTPUT: $output" >&2
  [ "$status" -eq 0 ]
}

@test "help: 'pl commands' emits a machine-readable command list" {
  run bash -c 'cd "'"$REPO_ROOT"'" && ./pl commands --json'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"name"'* ]]
}

################################################################################
# Site-enumeration drift — three lists must agree, or say so
################################################################################

@test "DRIFT: a site on disk but absent from nwp.yml produces a drift item" {
  _mkfixture
  mkdir -p "$FIX/sites/ondisk-only"
  cat > "$FIX/sites/ondisk-only/.nwp.yml" <<'YML'
schema: 2
YML
  run _run_check check_site_registry_drift
  [ "$status" -eq 0 ]
  echo "OUTPUT: $output" >&2
  [[ "$output" == *"ondisk-only"* ]]
}

@test "DRIFT: a phantom nwp.yml entry with no directory produces a drift item" {
  _mkfixture
  cat > "$FIX/nwp.yml" <<'YML'
sites:
  phantom-site:
    directory: sites/phantom-site
settings:
  todo: {}
YML
  run _run_check check_site_registry_drift
  [ "$status" -eq 0 ]
  echo "OUTPUT: $output" >&2
  [[ "$output" == *"phantom-site"* ]]
}

################################################################################
# discover_repos — the primitive the GWK rewrite stands on
################################################################################

@test "discover_repos: finds nested repos and ignores vendor/node_modules" {
  _mkfixture
  mkdir -p "$FIX/sites/a/dev" "$FIX/sites/a/dev/vendor/pkg" "$FIX/sites/a/dev/html/profiles/custom/x" "$FIX/servers/s1"
  git -C "$FIX/sites/a/dev" init -q
  git -C "$FIX/sites/a/dev/vendor/pkg" init -q
  git -C "$FIX/sites/a/dev/html/profiles/custom/x" init -q
  git -C "$FIX/servers/s1" init -q

  run bash -c '
    NWP_DIR="'"$FIX"'" PROJECT_ROOT="'"$FIX"'" bash -c "
      source \"'"$REPO_ROOT"'/lib/project-resolver.sh\"
      discover_repos | sort
    "'
  echo "OUTPUT: $output" >&2
  [ "$status" -eq 0 ]
  [[ "$output" == *"sites/a/dev"* ]]
  [[ "$output" == *"profiles/custom/x"* ]]
  [[ "$output" == *"servers/s1"* ]]
  [[ "$output" != *"vendor/pkg"* ]]
}

################################################################################
# check_forge_freshness (D33 / ops#80) — cadence from the recorded stamp,
# never a live probe. Uses discover_servers when present; falls back to a
# servers/ listing.
################################################################################

_mkserver() {  # $1 = server name
  mkdir -p "$FIX/servers/$1"
  printf 'server: %s\n' "$1" > "$FIX/servers/$1/.nwp-server.yml"
}

@test "FORGE: a server never checked through pl produces a medium item" {
  _mkfixture
  _mkserver box1
  run _run_check check_forge_freshness
  [ "$status" -eq 0 ]
  [[ "$output" == *"never been checked"* ]]
  [[ "$output" == *"box1"* ]]
  [[ "$output" == *"pl server forge status box1"* ]]
}

@test "FORGE: a fresh stamp produces NO item (can go green honestly)" {
  _mkfixture
  _mkserver box1
  mkdir -p "$FIX/private/forge"
  printf '%s version=18.7.7 upgradable=0 key_expiry=9999999999\n' "$(date -u +%FT%TZ)" \
    > "$FIX/private/forge/box1.last-check"
  run _run_check check_forge_freshness
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s' "$output" | tr -d '[:space:]')" ]
}

@test "FORGE: a stamp older than the alert threshold is high" {
  _mkfixture
  _mkserver box1
  mkdir -p "$FIX/private/forge"
  # 60 days ago, well past the default 45-day alert.
  local old; old=$(date -u -d '60 days ago' +%FT%TZ)
  printf '%s version=18.7.7 upgradable=3 key_expiry=9999999999\n' "$old" \
    > "$FIX/private/forge/box1.last-check"
  run _run_check check_forge_freshness
  [ "$status" -eq 0 ]
  [[ "$output" == *"not checked in"* ]]
  [[ "$output" == *'"priority":"high"'* ]]
}

@test "FORGE: an expired apt key in the stamp is HIGH regardless of age" {
  _mkfixture
  _mkserver box1
  mkdir -p "$FIX/private/forge"
  # checked today, but the recorded key expiry is in the past.
  printf '%s version=18.7.7 upgradable=0 key_expiry=1000000000\n' "$(date -u +%FT%TZ)" \
    > "$FIX/private/forge/box1.last-check"
  run _run_check check_forge_freshness
  [ "$status" -eq 0 ]
  [[ "$output" == *"EXPIRED"* ]]
  [[ "$output" == *'"priority":"high"'* ]]
}

@test "FORGE: no servers configured → no items, no crash" {
  _mkfixture
  run _run_check check_forge_freshness
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s' "$output" | tr -d '[:space:]')" ]
}
