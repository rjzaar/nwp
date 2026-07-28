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

# Assert a pattern is ABSENT — and actually fail the test when it isn't.
#
# `! grep -q X "$f"` cannot fail a bats test. bash's errexit explicitly exempts
# "a command whose return value is being inverted with !", so every non-final
# `! grep` in a test body always passes, whatever the file contains. The most
# important claim this file makes — "the gate never reached the push" — was
# written exactly that way and was therefore asserting nothing. Verified
# against bats 1.10.0: a test body containing `! true` followed by `true`
# passes. Route negative assertions through this helper instead; it is a plain
# command, so errexit applies to it normally.
refute_in() {
  local file="$1" pattern="$2"
  if grep -q -- "$pattern" "$file" 2>/dev/null; then
    echo "REFUTE FAILED: '$pattern' is present in $file" >&2
    return 1
  fi
  return 0
}

# Same, for a string rather than a file.
refute_str() {
  local haystack="$1" pattern="$2"
  if grep -q -- "$pattern" <<<"$haystack"; then
    echo "REFUTE FAILED: '$pattern' is present in the given text" >&2
    return 1
  fi
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
# D1 — two gaps between the header's STATED intent and what the regex delivers.
# --------------------------------------------------------------------------

# The header justifies denying requirements.txt as "dependency pins on the host
# that holds the token — supply chain". requirements-dev.txt EXISTS ON DISK and
# is `pip install`-ed by the `test:console` CI job (scripts/ci/test-console.sh),
# i.e. it is a dependency file whose contents become code executed by a runner.
# `requirements\.txt$` never matched it, so the loop could rewrite it unreviewed.
@test "gate REFUSES the console's dev/CI dependency pins (requirements-dev.txt)" {
  run gate_verdict scripts/console/requirements-dev.txt
  [ "$status" -eq 1 ]
  [[ "$output" == REFUSED* ]]
}

# The header says "static/*.js is denied". `static/[^/]*\.js$` only denied files
# sitting DIRECTLY in static/ (today: htmx.min.js, webauthn.js, sw.js). The
# moment console v2 nests its JS — static/js/, static/vendor/ — the deny lapses
# silently. Same fail-closed reasoning as the app/ directory rule: a denylist
# that has to be remembered is a denylist that lapses.
@test "gate REFUSES console JavaScript nested under static/ (fail-closed on new subdirs)" {
  run gate_verdict scripts/console/static/js/app.js
  [ "$status" -eq 1 ]
  run gate_verdict scripts/console/static/vendor/some-lib.min.js
  [ "$status" -eq 1 ]
  run gate_verdict scripts/console/static/js/panes/fleet/invented-tomorrow.js
  [ "$status" -eq 1 ]
}

# NEGATIVE CONTROL FOR THE WIDENING ITSELF. `static/.*\.js$` is a broader
# pattern than `static/[^/]*\.js$`; a botched anchor (e.g. dropping the `$`, or
# `static/.*js`) would start swallowing style.css / templates / README and the
# gate would refuse everything — which reads as "passing" on every deny test
# above. These three MUST stay allowed, asserted explicitly per path so the
# widening is verified rather than assumed.
@test "NEGATIVE CONTROL for D1: widening static/*.js must not swallow CSS, templates or README" {
  run gate_verdict scripts/console/static/style.css
  [ "$status" -eq 0 ]
  [[ "$output" == ALLOWED* ]]
  run gate_verdict scripts/console/templates/base.html
  [ "$status" -eq 0 ]
  [[ "$output" == ALLOWED* ]]
  run gate_verdict scripts/console/README.md
  [ "$status" -eq 0 ]
  [[ "$output" == ALLOWED* ]]
}

# And the widening must not leak past static/: nested assets that are not JS,
# and JS outside static/, are unaffected by this change.
@test "NEGATIVE CONTROL for D1: non-JS nested assets and the icons stay ALLOWED" {
  run gate_verdict scripts/console/static/img/logo.svg
  [ "$status" -eq 0 ]
  run gate_verdict scripts/console/static/css/panes.css
  [ "$status" -eq 0 ]
  run gate_verdict scripts/console/static/icon.svg
  [ "$status" -eq 0 ]
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
  # `-z`: NUL-delimited records, so a path is matched whole and git never
  # C-quotes it (ops#151 F1). `-En` would reintroduce the quoting bypass.
  grep -q 'grep -zE "\$SENSITIVE_PATH_RE"' "$LOOP_SH"
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
  refute_str "$block" 'worktree remove'
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

  CALLS="$calls" work_dir="$FIXTURE" head_main="$BASE" gate_base="$BASE" \
    branch=agent-99 bash "$harness"

  # 1. never pushed
  refute_in "$calls" REACHED_PUSH
  refute_in "$calls" 'GIT push'
  # 2. refusal logged, naming the offending file
  grep -q 'REFUSING PUSH' "$calls"
  grep -q 'authz.py' "$calls"
  # 3. agent-eligible pulled + comment posted
  grep -q 'API PUT .*issues/99.*remove_labels' "$calls"
  grep -q 'API POST .*issues/99/notes' "$calls"
  # 4. worktree left for inspection
  refute_in "$calls" 'worktree remove'
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

  CALLS="$calls" work_dir="$FIXTURE" head_main="$BASE" gate_base="$BASE" \
    bash "$harness"

  grep -q REACHED_PUSH "$calls"
  refute_in "$calls" 'REFUSING PUSH'
  refute_in "$calls" remove_labels
}

# --------------------------------------------------------------------------
# A GATE THAT CANNOT SEE MUST REFUSE (ops#91 remaining).
#
# The gate's decision is `git diff --name-only <base> HEAD | grep -E <re>`.
# `grep` prints nothing both when the diff is clean AND when the diff is
# EMPTY — and the diff is empty whenever `git diff` itself failed. So a gate
# that only tests `-n "$sensitive_hits"` treats "I looked and saw nothing"
# and "I could not look" as the same answer, and pushes on both. That is
# fail-OPEN on exactly the input an attacker would want: a blind gate.
#
# This is not hypothetical hardening of a hypothetical failure. The agent
# under the gate is `claude -p --dangerously-skip-permissions` acting on a
# member-controlled issue body, and it runs INSIDE the worktree the diff is
# taken from — it can write .git/, exhaust the disk, or otherwise make the
# diff command fail, and every one of those outcomes currently ends in an
# unchecked `git push`.
#
# Empty-but-successful is refused for the same reason: the driver only
# reaches the gate after asserting HEAD != main, so a commit that changes no
# file is already an anomaly, not a normal clean diff.
# --------------------------------------------------------------------------

# Slice the live gate into a runnable harness with the GitLab calls stubbed.
# `git` is stubbed from $GIT_STUB so a test can make `git diff` fail.
_gate_harness() {
  local out="$1"
  {
    echo 'set -uo pipefail'
    grep -m1 '^SENSITIVE_PATH_RE=' "$LOOP_SH"
    cat <<'STUB'
LOG_FILE=/dev/null
pid=16; iid=99; processed=0
log() { printf 'LOG %s\n' "$*" >>"$CALLS"; }
gitlab_curl() { printf 'API %s %s %s\n' "$1" "$2" "$3" >>"$CALLS"; }
git() {
  if [ -n "${GIT_STUB:-}" ]; then "$GIT_STUB" "$@"; return $?; fi
  command git "$@"
}
# Lets a test make the sensitive-path SCAN itself fail (grep rc=2) without
# breaking any other grep the block might do. Keyed on the pattern, so it
# fires for both the old `grep -En "$RE"` and the new `grep -zE "$RE"` form.
grep() {
  if [ -n "${GREP_STUB_RC:-}" ]; then
    case "$*" in *gitleaks*) return "$GREP_STUB_RC" ;; esac
  fi
  command grep "$@"
}
for _once in 1; do
STUB
    sed -n '/---- ops#91 Half A/,/---- end ops#91 Half A gate ----/p' "$LOOP_SH"
    cat <<'STUB'
  printf 'REACHED_PUSH\n' >>"$CALLS"
done
STUB
  } >"$out"
}

@test "BEHAVIOURAL: a FAILING git diff must refuse the push (the gate must not fail open when blind)" {
  local harness="$BATS_TEST_TMPDIR/h3.sh" calls="$BATS_TEST_TMPDIR/c3.log"
  local stub="$BATS_TEST_TMPDIR/gitstub.sh"
  _gate_harness "$harness"

  # `git diff` fails the way a broken/hostile worktree makes it fail: non-zero
  # exit, nothing on stdout. Everything else behaves normally.
  cat >"$stub" <<'SH'
#!/usr/bin/env bash
# The gate now invokes git as `git -c core.quotePath=false diff …`, so the
# subcommand is not necessarily $1. Match it anywhere in the argv.
for a in "$@"; do [ "$a" = diff ] && exit 128; done
exec git "$@"
SH
  chmod +x "$stub"

  # A real, ordinary (benign) change — so the ONLY reason to refuse is blindness.
  mkdir -p docs
  echo 'a doc tweak' >docs/note.md
  git add -A && git commit -q -m 'agent edited a doc'

  CALLS="$calls" GIT_STUB="$stub" work_dir="$FIXTURE" head_main="$BASE" \
    gate_base="$BASE" branch=agent-99 bash "$harness"

  # The push must NOT be reached when the gate could not see the diff.
  refute_in "$calls" REACHED_PUSH
  grep -q 'REFUSING PUSH' "$calls"
  # ...and it must fail closed the same way: label pulled, comment posted,
  # worktree left for inspection.
  grep -q 'API PUT .*issues/99.*remove_labels' "$calls"
  grep -q 'API POST .*issues/99/notes' "$calls"
  refute_in "$calls" 'worktree remove'
}

@test "BEHAVIOURAL: an EMPTY diff must refuse the push (HEAD != main, so no files changed is an anomaly)" {
  local harness="$BATS_TEST_TMPDIR/h4.sh" calls="$BATS_TEST_TMPDIR/c4.log"
  local stub="$BATS_TEST_TMPDIR/gitstub2.sh"
  _gate_harness "$harness"

  # `git diff` succeeds but reports no changed files.
  cat >"$stub" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = diff ] && exit 0; done
exec git "$@"
SH
  chmod +x "$stub"

  mkdir -p docs
  echo 'a doc tweak' >docs/note2.md
  git add -A && git commit -q -m 'agent edited a doc'

  CALLS="$calls" GIT_STUB="$stub" work_dir="$FIXTURE" head_main="$BASE" \
    gate_base="$BASE" branch=agent-99 bash "$harness"

  refute_in "$calls" REACHED_PUSH
  grep -q 'REFUSING PUSH' "$calls"
  grep -q 'API PUT .*issues/99.*remove_labels' "$calls"
}

@test "NEGATIVE CONTROL: with git working normally, a benign diff still reaches the push" {
  # Without this, the two tests above would pass on a gate that refused
  # everything unconditionally.
  local harness="$BATS_TEST_TMPDIR/h5.sh" calls="$BATS_TEST_TMPDIR/c5.log"
  _gate_harness "$harness"

  mkdir -p docs
  echo 'a doc tweak' >docs/note3.md
  git add -A && git commit -q -m 'agent edited a doc'

  CALLS="$calls" work_dir="$FIXTURE" head_main="$BASE" gate_base="$BASE" \
    branch=agent-99 bash "$harness"

  grep -q REACHED_PUSH "$calls"
  refute_in "$calls" 'REFUSING PUSH'
  refute_in "$calls" remove_labels
}

@test "agent-loop.sh is syntactically valid" {
  run bash -n "$LOOP_SH"
  [ "$status" -eq 0 ]
}

# ==========================================================================
# ops#151 — two CONSTRUCTED bypasses of the (already fail-closed) gate.
#
# Both were built end-to-end against the merged gate, not imagined. Each test
# below was watched RED against the pre-fix script before the fix landed; the
# verbatim failing output is recorded in the MR. The negative controls above
# and below are what stop "refuse everything" from passing these.
# ==========================================================================

# --------------------------------------------------------------------------
# F1 — git C-QUOTES unusual paths, and the quote defeats every `(^|/)` anchor.
#
#   $ git diff --name-only
#   "scripts/console/app/authz\303\251.py"
#
# The leading `"` is what precedes `scripts`, so neither `^` nor `/` is there
# and SENSITIVE_PATH_RE does not match — the gate ALLOWS a rewrite of the
# console's authorisation module, which is the exact regression the file
# exists to prevent.
# --------------------------------------------------------------------------

@test "ops#151 F1: gate REFUSES a console/app path with a non-ASCII byte (git C-quoting must not defeat the anchors)" {
  local harness="$BATS_TEST_TMPDIR/h6.sh" calls="$BATS_TEST_TMPDIR/c6.log"
  _gate_harness "$harness"

  # é = \303\251 — enough to make git quote the whole path.
  mkdir -p scripts/console/app
  printf 'def role_allows(a,b): return True\n' >"scripts/console/app/authzé.py"
  git add -A && git commit -q -m 'agent rewrote authz under a non-ASCII name'

  # Prove the premise rather than assuming it: git really does quote this.
  run command git diff --name-only "$BASE" HEAD
  [[ "$output" == '"scripts/console/app/authz'* ]]

  CALLS="$calls" work_dir="$FIXTURE" head_main="$BASE" gate_base="$BASE" \
    branch=agent-99 bash "$harness"

  refute_in "$calls" REACHED_PUSH
  grep -q 'REFUSING PUSH' "$calls"
  grep -q 'API PUT .*issues/99.*remove_labels' "$calls"
}

@test "ops#151 F1: gate REFUSES a console/app path containing a NEWLINE (why -z, not just core.quotePath=false)" {
  # core.quotePath=false de-quotes the non-ASCII case but still emits
  # "scripts/console/app/a\nb.py" quoted for a newline — so quotePath alone
  # leaves the bypass open. -z closes it unconditionally. This test is the
  # reason the fix is -z and not the one-word config change.
  local harness="$BATS_TEST_TMPDIR/h7.sh" calls="$BATS_TEST_TMPDIR/c7.log"
  _gate_harness "$harness"

  mkdir -p scripts/console/app
  printf 'x\n' >"scripts/console/app/$(printf 'a\nb').py"
  git add -A && git commit -q -m 'agent used a newline in the path'

  # Premise: even with quotePath=false, git quotes a newline-bearing path.
  run command git -c core.quotePath=false diff --name-only "$BASE" HEAD
  [[ "$output" == *'"scripts/console/app/a\nb.py"'* ]]

  CALLS="$calls" work_dir="$FIXTURE" head_main="$BASE" gate_base="$BASE" \
    branch=agent-99 bash "$harness"

  refute_in "$calls" REACHED_PUSH
  grep -q 'REFUSING PUSH' "$calls"
}

@test "ops#151 F1 NEGATIVE CONTROL: a BENIGN non-ASCII path is still ALLOWED" {
  # Without this, F1 could be 'passed' by refusing every unusual filename.
  local harness="$BATS_TEST_TMPDIR/h8.sh" calls="$BATS_TEST_TMPDIR/c8.log"
  _gate_harness "$harness"

  mkdir -p docs
  printf 'notes\n' >"docs/résumé.md"
  git add -A && git commit -q -m 'agent added a doc with an accent'

  CALLS="$calls" work_dir="$FIXTURE" head_main="$BASE" gate_base="$BASE" \
    branch=agent-99 bash "$harness"

  grep -q REACHED_PUSH "$calls"
  refute_in "$calls" 'REFUSING PUSH'
  refute_in "$calls" remove_labels
}

# --------------------------------------------------------------------------
# F2 — the agent can MOVE THE DIFF BASE.
#
# A linked worktree shares the parent's ref store, so the agent (running with
# --dangerously-skip-permissions inside that worktree) can:
#     commit the sensitive change
#     git update-ref refs/heads/main <that sha>
#     commit a benign change on top
# `HEAD != main` still holds, `git diff main HEAD` shows only the benign file,
# and the branch that gets pushed carries the sensitive one.
# --------------------------------------------------------------------------

# Stage the full attack in a real parent repo + real linked worktree.
# Echoes: <pinned base> <main as the gate would re-read it> <worktree path>
_stage_refmove_attack() {
  local parent="$BATS_TEST_TMPDIR/parent" wt="$BATS_TEST_TMPDIR/attack-wt"
  mkdir -p "$parent"
  (
    cd "$parent"
    git init -q -b main .
    git config user.email a@b.c
    git config user.name t
    mkdir -p scripts/agent-loop docs
    echo original >scripts/agent-loop/agent-loop.sh
    echo hi >docs/readme.md
    git add -A
    git commit -q -m base
  ) >/dev/null

  # DRIVER: pin the base, then create the branch AT that pinned object.
  local pinned
  pinned="$(cd "$parent" && git rev-parse --verify 'main^{commit}')"
  (cd "$parent" && git worktree add -q "$wt" -b agent/issue-99 "$pinned") >/dev/null

  # AGENT, inside the worktree, using the shared ref store.
  (
    cd "$wt"
    git config user.email a@b.c
    git config user.name t
    echo 'BACKDOOR' >>scripts/agent-loop/agent-loop.sh
    git add -A
    git commit -q -m 'sensitive change'
    git update-ref refs/heads/main "$(git rev-parse HEAD)"
    echo benign >>docs/readme.md
    git add -A
    git commit -q -m 'benign change'
  ) >/dev/null

  local moved
  moved="$(cd "$parent" && git rev-parse main)"
  # The attack is only interesting if main actually moved.
  [ "$moved" != "$pinned" ] || return 1
  printf '%s %s %s\n' "$pinned" "$moved" "$wt"
}

@test "ops#151 F2: gate REFUSES when the agent moved refs/heads/main under it (diff base must be pinned)" {
  local harness="$BATS_TEST_TMPDIR/h9.sh" calls="$BATS_TEST_TMPDIR/c9.log"
  _gate_harness "$harness"

  local pinned moved wt
  read -r pinned moved wt < <(_stage_refmove_attack)
  [ -n "$wt" ]

  # head_main is what the OLD gate computed (a live read of the MOVED ref);
  # gate_base is the sha the driver pinned at worktree-creation time. Both are
  # exported so this same test runs against either version of the script — and
  # only the pinned-base version can refuse.
  CALLS="$calls" work_dir="$wt" head_main="$moved" gate_base="$pinned" \
    branch=agent-99 bash "$harness"

  refute_in "$calls" REACHED_PUSH
  grep -q 'REFUSING PUSH' "$calls"
  grep -q 'agent-loop.sh' "$calls"
  grep -q 'API PUT .*issues/99.*remove_labels' "$calls"
  refute_in "$calls" 'worktree remove'
}

@test "ops#151 F2: the driver pins the gate base BEFORE creating the worktree, and branches from it" {
  # The behavioural test above can only prove the gate honours \$gate_base.
  # This proves the driver sets it to something the agent cannot rewrite:
  # resolved before the worktree exists, and used as the branch start point so
  # the recorded base and the branch's real origin are the same object.
  local pin_line add_line
  pin_line="$(grep -n '^ *gate_base="\$(cd "\$local_path" && git rev-parse --verify' "$LOOP_SH" | head -1 | cut -d: -f1)"
  add_line="$(grep -n 'git worktree add "\$work_dir" -b "\$branch"' "$LOOP_SH" | head -1 | cut -d: -f1)"
  [ -n "$pin_line" ] && [ -n "$add_line" ]
  [ "$pin_line" -lt "$add_line" ]

  # The worktree starts at the pinned sha, not at whatever `main` is.
  grep -q 'git worktree add "\$work_dir" -b "\$branch" "\$gate_base"' "$LOOP_SH"

  # And the gate diffs against it.
  grep -q 'diff --name-only -z "\${gate_base}" HEAD' "$LOOP_SH"

  # gate_base is assigned exactly once in anger (plus its "" initialiser) and
  # never re-derived after the worktree exists — a second assignment later
  # would be a live ref read wearing the pinned variable's name.
  run grep -c '^ *gate_base=' "$LOOP_SH"
  [ "$output" -eq 2 ]

  # The old, movable base must be gone entirely.
  refute_in "$LOOP_SH" 'head_main'
}

# --------------------------------------------------------------------------
# F3 — `grep … || true` cannot tell rc=2 (grep ERRORED) from rc=1 (clean).
# The gate's own commit message condemns exactly this conflation for
# `git diff`; it survived one line further down for the scan itself.
# --------------------------------------------------------------------------

@test "ops#151 F3: a scan that ERRORS (grep rc=2) must refuse the push, not read as clean" {
  local harness="$BATS_TEST_TMPDIR/h10.sh" calls="$BATS_TEST_TMPDIR/c10.log"
  _gate_harness "$harness"

  # A real, ordinary, benign change — so the ONLY reason to refuse is that the
  # scan could not be performed.
  mkdir -p docs
  echo 'a doc tweak' >docs/note4.md
  git add -A && git commit -q -m 'agent edited a doc'

  CALLS="$calls" GREP_STUB_RC=2 work_dir="$FIXTURE" head_main="$BASE" \
    gate_base="$BASE" branch=agent-99 bash "$harness"

  refute_in "$calls" REACHED_PUSH
  grep -q 'REFUSING PUSH' "$calls"
  grep -q 'API PUT .*issues/99.*remove_labels' "$calls"
  grep -q 'API POST .*issues/99/notes' "$calls"
  refute_in "$calls" 'worktree remove'
}

@test "ops#151 F3 NEGATIVE CONTROL: rc=1 (genuinely clean) still reaches the push" {
  # Pins that the fix distinguishes 1 from 2 rather than refusing on any
  # non-zero, which would break every benign MR the loop opens.
  local harness="$BATS_TEST_TMPDIR/h11.sh" calls="$BATS_TEST_TMPDIR/c11.log"
  _gate_harness "$harness"

  mkdir -p docs
  echo 'a doc tweak' >docs/note5.md
  git add -A && git commit -q -m 'agent edited a doc'

  CALLS="$calls" GREP_STUB_RC=1 work_dir="$FIXTURE" head_main="$BASE" \
    gate_base="$BASE" branch=agent-99 bash "$harness"

  grep -q REACHED_PUSH "$calls"
  refute_in "$calls" 'REFUSING PUSH'
}

@test "ops#151 F3: the scan's exit code is treated as trichotomous (no bare '|| true' on the scan)" {
  # Structural backstop: `grep -zE "$SENSITIVE_PATH_RE" … || true` would make
  # the behavioural test above unreachable again.
  refute_in "$LOOP_SH" 'grep -zE "$SENSITIVE_PATH_RE" "$gate_diff" >"$gate_hits" 2>/dev/null || true'
  grep -q 'grep_rc != 0 && grep_rc != 1' "$LOOP_SH"
}
