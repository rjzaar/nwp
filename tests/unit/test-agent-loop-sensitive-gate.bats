#!/usr/bin/env bats
# ops#91 Half A — the agent-loop's fail-closed pre-push sensitive-path gate.
#
# WHY THIS FILE EXISTS
# --------------------
# The loop feeds a MEMBER-CONTROLLED issue body to `claude -p
# --dangerously-skip-permissions` (agent-loop.sh). The prompt's "HARD BOUNDARY"
# prose is advisory; SENSITIVE_PATH_RE is the only ENFORCED backstop between an
# autonomous agent and a pushed branch. Half A shipped that gate in 2026-07 and
# promised "+ bats" — the bats never landed, so for ~2 weeks the single enforced
# control on the loop had zero test coverage, and the NWP Console (whose whole
# authorisation layer lives under scripts/console/app/) was never in the pattern
# at all. This file pins both.
#
# WHAT IT TESTS
# -------------
# The pattern is extracted from the LIVE script, not copied here — a copy would
# drift and pass while the real gate rotted. Diffs are real git diffs against a
# real fixture repo, so the assertion runs the same
# `git diff --name-only | grep -En "$SENSITIVE_PATH_RE"` decision the gate runs.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LOOP_SH="$REPO_ROOT/scripts/agent-loop/agent-loop.sh"

  # Extract the live pattern. `eval` on exactly one assignment line, so the
  # test exercises the real regex, including its quoting.
  local assign
  assign="$(grep -m1 '^SENSITIVE_PATH_RE=' "$LOOP_SH" || true)"
  [ -n "$assign" ] || {
    echo "FATAL: no SENSITIVE_PATH_RE= assignment in $LOOP_SH" >&2
    return 1
  }
  eval "$assign"

  # A real repo so the diffs are real diffs.
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$FIXTURE"
  cd "$FIXTURE" || return 1
  git init -q .
  git config user.email a@b.c
  git config user.name t
  git commit -q --allow-empty -m base
  BASE="$(git rev-parse HEAD)"
}

# Commit files at the given paths, then return the gate's verdict the same way
# agent-loop.sh computes it: 0 = would push, 1 = would REFUSE.
gate_verdict() {
  local p
  for p in "$@"; do
    mkdir -p "$(dirname "$p")"
    printf 'agent-written content\n' >>"$p"
  done
  git add -A >/dev/null
  git commit -q -m 'agent change'

  local changed hits
  changed="$(git diff --name-only "$BASE" HEAD)"
  hits="$(printf '%s\n' "$changed" | grep -En "$SENSITIVE_PATH_RE" || true)"
  if [ -n "$hits" ]; then
    echo "REFUSED: $hits"
    return 1
  fi
  echo "ALLOWED: $changed"
  return 0
}

# --------------------------------------------------------------------------
# THE REGRESSION THIS FILE WAS WRITTEN FOR: the NWP Console.
# --------------------------------------------------------------------------

@test "gate REFUSES a diff touching the console's authorisation (app/authz.py)" {
  run gate_verdict scripts/console/app/authz.py
  [ "$status" -eq 1 ]
  [[ "$output" == REFUSED* ]]
}

@test "gate REFUSES the console action allowlist (app/actions.py)" {
  run gate_verdict scripts/console/app/actions.py
  [ "$status" -eq 1 ]
}

@test "gate REFUSES console passkey auth (app/webauthn_flow.py)" {
  run gate_verdict scripts/console/app/webauthn_flow.py
  [ "$status" -eq 1 ]
}

@test "gate REFUSES the console user store + audit log (app/store.py)" {
  run gate_verdict scripts/console/app/store.py
  [ "$status" -eq 1 ]
}

# main.py is where require()/current_user()/_set_session() and every per-route
# Depends(require(...)) actually live. Blocking authz.py while leaving main.py
# open would be a paper gate: an agent could downgrade a route from
# require("operator") to require("viewer") and never trip it.
@test "gate REFUSES the console route table + role enforcement (app/main.py)" {
  run gate_verdict scripts/console/app/main.py
  [ "$status" -eq 1 ]
}

@test "gate REFUSES the console's only subprocess spawner (app/runner.py)" {
  run gate_verdict scripts/console/app/runner.py
  [ "$status" -eq 1 ]
}

# quokka.py documents a structural invariant: "READ-ONLY by construction: this
# module has no import path to actions.py". An agent could add that import.
@test "gate REFUSES the Quokka chat pane (app/quokka.py)" {
  run gate_verdict scripts/console/app/quokka.py
  [ "$status" -eq 1 ]
}

# config.py holds secret_key() (session signing) and the GitLab/Gotify token
# file locations.
@test "gate REFUSES console config incl. session secret + token paths (app/config.py)" {
  run gate_verdict scripts/console/app/config.py
  [ "$status" -eq 1 ]
}

# Directory-level, NOT an enumeration of today's filenames: console v2 is
# actively adding modules (e.g. the multi-tenancy choke point app/scope.py).
# An enumerated list fails OPEN on every new module; the directory rule fails
# CLOSED. This test uses a file that does not exist in the tree today.
@test "gate REFUSES a console app module that does not exist yet (fail-closed on new modules)" {
  run gate_verdict scripts/console/app/scope.py
  [ "$status" -eq 1 ]
  run gate_verdict scripts/console/app/some_module_invented_tomorrow.py
  [ "$status" -eq 1 ]
}

@test "gate REFUSES the console deploy command (scripts/commands/console.sh)" {
  run gate_verdict scripts/commands/console.sh
  [ "$status" -eq 1 ]
}

@test "gate REFUSES the console rsync --delete divergence guard (lib/console-deploy.sh)" {
  run gate_verdict lib/console-deploy.sh
  [ "$status" -eq 1 ]
}

# static/ is "presentation" for CSS and icons, but JavaScript is executable
# code shipped to the browser: sw.js is a service worker (intercepts every
# request on the origin, persists beyond page load), webauthn.js drives the
# passkey ceremony, and htmx.min.js is vendored third-party code where a
# malicious swap is least likely to be caught by eye.
@test "gate REFUSES console client-side JavaScript (service worker, passkey driver, vendored lib)" {
  run gate_verdict scripts/console/static/sw.js
  [ "$status" -eq 1 ]
  run gate_verdict scripts/console/static/webauthn.js
  [ "$status" -eq 1 ]
  run gate_verdict scripts/console/static/htmx.min.js
  [ "$status" -eq 1 ]
  run gate_verdict scripts/console/static/invented-tomorrow.js
  [ "$status" -eq 1 ]
}

@test "gate REFUSES the console systemd unit and its dependency pins" {
  run gate_verdict scripts/console/nwp-console.service
  [ "$status" -eq 1 ]
  run gate_verdict scripts/console/requirements.txt
  [ "$status" -eq 1 ]
}

# --------------------------------------------------------------------------
# NEGATIVE CONTROLS — a gate that refuses everything is a gate that gets
# ripped out. These prove the pattern still discriminates.
# --------------------------------------------------------------------------

@test "NEGATIVE CONTROL: a benign console template text tweak is ALLOWED" {
  run gate_verdict scripts/console/templates/pane_fleet.html
  [ "$status" -eq 0 ]
  [[ "$output" == ALLOWED* ]]
}

@test "NEGATIVE CONTROL: console CSS and README are ALLOWED" {
  run gate_verdict scripts/console/static/style.css scripts/console/README.md
  [ "$status" -eq 0 ]
}

@test "NEGATIVE CONTROL: ordinary docs and site code are ALLOWED" {
  run gate_verdict docs/README.md
  [ "$status" -eq 0 ]
}

# --------------------------------------------------------------------------
# The pre-existing Half A coverage — never had a test either.
# --------------------------------------------------------------------------

@test "gate still REFUSES the original Half A paths" {
  local p
  for p in .gitlab-ci.yml lib/auth-helpers.sh lib/sanitizers/foo.sh \
           scripts/commands/live.sh scripts/commands/deploy-gate.sh \
           scripts/agent-loop/agent-loop.sh keys/id_thing .env.local \
           .secrets.yml deploy_ed25519 server.pem; do
    ( cd "$BATS_TEST_TMPDIR" && rm -rf r2 && mkdir r2 && cd r2 \
      && git init -q . && git config user.email a@b.c && git config user.name t \
      && git commit -q --allow-empty -m base \
      && mkdir -p "$(dirname "$p")" && echo x >"$p" && git add -A && git commit -q -m c \
      && git diff --name-only HEAD~1 HEAD | grep -Eq "$SENSITIVE_PATH_RE" ) \
      || { echo "REGRESSION: gate no longer blocks $p"; return 1; }
  done
}

# --------------------------------------------------------------------------
# Structural: the constant must actually be the thing the gate uses, and the
# refusal path must stay fail-closed.
# --------------------------------------------------------------------------

@test "the gate body uses SENSITIVE_PATH_RE (constant cannot drift from the gate)" {
  grep -q 'grep -En "\$SENSITIVE_PATH_RE"' "$LOOP_SH"
  # and there is no second, inlined copy of the old pattern left behind
  run grep -c 'gitleaks\\.toml' "$LOOP_SH"
  [ "$output" -eq 1 ]
}

@test "refusal path is fail-closed: no push, label pulled, comment posted, worktree kept" {
  # The refusal block runs BEFORE the push...
  local refuse_line push_line
  refuse_line="$(grep -n 'REFUSING PUSH' "$LOOP_SH" | head -1 | cut -d: -f1)"
  push_line="$(grep -n 'git push -u origin' "$LOOP_SH" | head -1 | cut -d: -f1)"
  [ -n "$refuse_line" ] && [ -n "$push_line" ]
  [ "$refuse_line" -lt "$push_line" ]

  # ...and the block itself pulls the label, comments, and `continue`s out
  # without removing the worktree (left for human inspection).
  local block
  block="$(sed -n "${refuse_line},$((refuse_line + 12))p" "$LOOP_SH")"
  grep -q 'remove_labels' <<<"$block"
  grep -q 'issues/${iid}/notes' <<<"$block"
  grep -q 'continue' <<<"$block"
  ! grep -q 'worktree remove' <<<"$block"
}

# Structural assertions can pass on dead code. This one EXECUTES the real gate
# block (sliced out of the live script, GitLab calls stubbed) against a real
# worktree whose diff touches scripts/console/app/authz.py, and asserts the
# four observable effects.
@test "BEHAVIOURAL: refusing a console/app diff pulls the label, comments, keeps the worktree, never pushes" {
  local harness="$BATS_TEST_TMPDIR/harness.sh"
  local calls="$BATS_TEST_TMPDIR/calls.log"

  {
    echo 'set -uo pipefail'
    grep -m1 '^SENSITIVE_PATH_RE=' "$LOOP_SH"
    cat <<'STUB'
LOG_FILE=/dev/null
pid=16; iid=99; processed=0
log() { printf 'LOG %s\n' "$*" >>"$CALLS"; }
gitlab_curl() { printf 'API %s %s %s\n' "$1" "$2" "$3" >>"$CALLS"; }
git() { printf 'GIT %s\n' "$*" >>"$CALLS"; command git "$@"; }
for _once in 1; do
STUB
    # the real block, verbatim
    sed -n '/---- ops#91 Half A/,/---- end ops#91 Half A gate ----/p' "$LOOP_SH"
    cat <<'STUB'
  printf 'REACHED_PUSH\n' >>"$CALLS"
  git push -u origin "$branch"
done
STUB
  } >"$harness"

  # A worktree whose diff touches the console's authorisation.
  mkdir -p scripts/console/app
  echo 'def role_allows(a,b): return True' >scripts/console/app/authz.py
  git add -A && git commit -q -m 'agent rewrote authz'

  CALLS="$calls" work_dir="$FIXTURE" head_main="$BASE" branch=agent-99 \
    bash "$harness"

  # 1. never pushed
  ! grep -q REACHED_PUSH "$calls"
  ! grep -q 'GIT push' "$calls"
  # 2. refusal logged, naming the offending file
  grep -q 'REFUSING PUSH' "$calls"
  grep -q 'authz.py' "$calls"
  # 3. agent-eligible pulled + comment posted
  grep -q 'API PUT .*issues/99.*remove_labels' "$calls"
  grep -q 'API POST .*issues/99/notes' "$calls"
  # 4. worktree left for inspection
  ! grep -q 'worktree remove' "$calls"
  [ -f "$FIXTURE/scripts/console/app/authz.py" ]
}

# The same harness must NOT refuse a benign change — otherwise assertion 1
# above would pass simply because the block always bails.
@test "BEHAVIOURAL negative control: a template-only diff reaches the push step" {
  local harness="$BATS_TEST_TMPDIR/h2.sh" calls="$BATS_TEST_TMPDIR/c2.log"
  {
    echo 'set -uo pipefail'
    grep -m1 '^SENSITIVE_PATH_RE=' "$LOOP_SH"
    cat <<'STUB'
LOG_FILE=/dev/null
pid=16; iid=99; processed=0
log() { printf 'LOG %s\n' "$*" >>"$CALLS"; }
gitlab_curl() { printf 'API %s %s %s\n' "$1" "$2" "$3" >>"$CALLS"; }
for _once in 1; do
STUB
    sed -n '/---- ops#91 Half A/,/---- end ops#91 Half A gate ----/p' "$LOOP_SH"
    printf 'REACHED_PUSH=1; printf "REACHED_PUSH\\n" >>"$CALLS"\ndone\n'
  } >"$harness"

  mkdir -p scripts/console/templates
  echo '<p>Fleet</p>' >scripts/console/templates/pane_fleet.html
  git add -A && git commit -q -m 'agent fixed a label'

  CALLS="$calls" work_dir="$FIXTURE" head_main="$BASE" bash "$harness"

  grep -q REACHED_PUSH "$calls"
  ! grep -q 'REFUSING PUSH' "$calls"
  ! grep -q remove_labels "$calls"
}

@test "agent-loop.sh is syntactically valid" {
  run bash -n "$LOOP_SH"
  [ "$status" -eq 0 ]
}
