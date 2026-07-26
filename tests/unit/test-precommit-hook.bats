#!/usr/bin/env bats
# Acceptance tests for .hooks/pre-commit (item E: "the hook is unrunnable, so
# everyone uses --no-verify").
#
# WHY THIS FILE EXISTS
# --------------------
# .hooks/pre-commit was a Drupal-site hook living in a repo that is ~90% bash
# and has no web/ directory at all. It hard-`exit 1`d when phpcs or phpstan was
# merely ABSENT, and then ran `phpstan analyse --configuration=phpstan.neon`
# whose paths (web/modules/custom, web/themes/custom) do not exist here. So any
# commit that staged a .php file could not pass — the rational response is
# `--no-verify`, which also disables the gitleaks hook next to it. Meanwhile the
# thing this repo actually needs at commit time — a shell syntax check — did not
# exist.
#
# THE TWO LOAD-BEARING PROPERTIES, tested in both directions:
#   FAIL-OPEN on missing tooling  — absent phpcs/phpstan must NOT block a commit.
#   FAIL-CLOSED on real breakage  — a .sh with a syntax error MUST block it.
#
# NEGATIVE CONTROL: a hook that simply refused everything would satisfy the
# fail-closed tests, and a hook that simply exited 0 would satisfy the fail-open
# ones. Tests marked "negative control" exist so that neither degenerate hook
# can pass this file.
#
# The hook is exercised as a real git hook in a real throwaway repo, on the
# STAGED content (git show :path), because that — not the worktree — is what a
# commit will actually record.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  HOOK="$REPO_ROOT/.hooks/pre-commit"
  [ -f "$HOOK" ] || {
    echo "FATAL: no $HOOK" >&2
    return 1
  }

  FIXTURE="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$FIXTURE"
  cd "$FIXTURE" || return 1
  git init -q .
  git config user.email a@b.c
  git config user.name t
  git config commit.gpgsign false
  git commit -q --allow-empty -m base

  # A PATH with no phpcs/phpstan on it, so "tooling absent" is a fact of the
  # test environment and not an accident of the developer's machine.
  TOOLLESS_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$TOOLLESS_BIN"
  for t in git bash sh grep sed awk cat mktemp mkdir cp mv rm dirname basename tr head env install; do
    src="$(command -v "$t" 2>/dev/null)" && ln -sf "$src" "$TOOLLESS_BIN/$t"
  done
}

# Stage $1 with content from stdin.
stage() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat >"$path"
  git add -- "$path"
}

# Run the hook exactly as git would: cwd = repo root, no arguments.
# $1 = "with-php" to expose the real PATH, "toolless" for the stripped one.
run_hook() {
  local mode="${1:-toolless}"
  if [ "$mode" = "toolless" ]; then
    PATH="$TOOLLESS_BIN" NO_COLOR=1 bash "$HOOK"
  else
    NO_COLOR=1 bash "$HOOK"
  fi
}

# ---------------------------------------------------------------------------
# (a) FAIL-OPEN: absent PHP tooling must not block a commit. This is the exact
#     condition that made everyone reach for --no-verify.
# ---------------------------------------------------------------------------

@test "(a) staged valid .php commits cleanly when phpcs/phpstan are absent" {
  stage src/Thing.php <<'PHP'
<?php
function thing() {
  return 1;
}
PHP
  run run_hook toolless
  [ "$status" -eq 0 ]
  [[ "$output" == *phpcs* ]]
  [[ "$output" == *skip* || "$output" == *Skip* ]]
}

@test "(a2) the skip notice is ONE line, not a wall of noise" {
  stage src/Thing.php <<'PHP'
<?php
echo 1;
PHP
  run run_hook toolless
  [ "$status" -eq 0 ]
  # At most one line mentioning phpcs, and at most one mentioning phpstan.
  [ "$(printf '%s\n' "$output" | grep -ci 'phpcs' || true)" -le 1 ]
  [ "$(printf '%s\n' "$output" | grep -ci 'phpstan' || true)" -le 1 ]
}

@test "(a3) no phpstan path error: phpstan is not invoked without web/modules/custom" {
  stage src/Thing.php <<'PHP'
<?php
echo 1;
PHP
  run run_hook toolless
  [ "$status" -eq 0 ]
  [[ "$output" != *"web/modules/custom"* ]]
}

# ---------------------------------------------------------------------------
# (b) FAIL-CLOSED: the check this repo actually needs and did not have.
# ---------------------------------------------------------------------------

@test "(b) a staged .sh with a syntax error is REFUSED, naming file and line" {
  stage lib/broken.sh <<'SH'
#!/usr/bin/env bash
if true; then
  echo hi
SH
  run run_hook toolless
  [ "$status" -ne 0 ]
  [[ "$output" == *"lib/broken.sh"* ]]
  [[ "$output" == *line* ]]
  # The message must not leak the tmp path the syntax check used.
  [[ "$output" != *"/tmp/"*".sh: line"* || "$output" == *"lib/broken.sh: line"* ]]
}

@test "(b2) the pl launcher is syntax-checked despite having no .sh extension" {
  stage pl <<'SH'
#!/usr/bin/env bash
case "$1" in
  a) echo a ;;
SH
  run run_hook toolless
  [ "$status" -ne 0 ]
  [[ "$output" == *"pl"* ]]
}

@test "(b3) an extensionless shell script is caught by its shebang" {
  stage scripts/thing <<'SH'
#!/bin/bash
for i in 1 2 3; do
  echo "$i"
SH
  run run_hook toolless
  [ "$status" -ne 0 ]
  [[ "$output" == *"scripts/thing"* ]]
}

@test "(b4) the STAGED content is checked, not the worktree" {
  # Stage a broken version, then fix the worktree without staging it. The
  # commit would still record the broken blob, so the hook must refuse.
  stage lib/staged-broken.sh <<'SH'
#!/usr/bin/env bash
if true; then
  echo hi
SH
  cat >lib/staged-broken.sh <<'SH'
#!/usr/bin/env bash
echo fine
SH
  run run_hook toolless
  [ "$status" -ne 0 ]
  [[ "$output" == *"lib/staged-broken.sh"* ]]
}

@test "(b5) broken PHP is refused when php IS available (fail-closed on real breakage)" {
  command -v php >/dev/null || skip "no php on this machine"
  stage src/Broken.php <<'PHP'
<?php
function broken( {
PHP
  run run_hook with-php
  [ "$status" -ne 0 ]
  [[ "$output" == *"src/Broken.php"* ]]
}

@test "(b6) broken PHP does NOT block when php is absent (fail-open on tooling)" {
  stage src/Broken.php <<'PHP'
<?php
function broken( {
PHP
  run run_hook toolless
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# (c) + NEGATIVE CONTROLS: a hook that refuses everything must fail here.
# ---------------------------------------------------------------------------

@test "(c) a syntactically valid .sh commits cleanly" {
  stage lib/good.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if true; then
  echo hi
fi
SH
  run run_hook toolless
  [ "$status" -eq 0 ]
}

@test "(c2) negative control: a commit with no relevant files is allowed and quiet" {
  stage docs/notes.md <<'MD'
# notes
MD
  run run_hook toolless
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c . || true)" -le 3 ]
}

@test "(c3) negative control: every real .sh in lib/ passes the hook's own check" {
  # If the hook refused everything, this would fail. It also proves the check is
  # usable against this repo's actual code, not just toy fixtures.
  local f n=0
  while IFS= read -r f; do
    n=$((n + 1))
    install -D "$REPO_ROOT/$f" "$FIXTURE/$f"
    git add -- "$f"
  done < <(cd "$REPO_ROOT" && git ls-files 'lib/*.sh' | head -40)
  [ "$n" -gt 10 ]
  run run_hook toolless
  [ "$status" -eq 0 ]
}

@test "(c4) a deleted .sh does not break the hook" {
  stage lib/gone.sh <<'SH'
#!/usr/bin/env bash
echo hi
SH
  git commit -q -m add --no-verify
  git rm -q lib/gone.sh
  run run_hook toolless
  [ "$status" -eq 0 ]
}

@test "(c5) a mixed commit fails only because of the broken file" {
  stage lib/good2.sh <<'SH'
#!/usr/bin/env bash
echo ok
SH
  stage lib/bad2.sh <<'SH'
#!/usr/bin/env bash
while true; do
  echo x
SH
  run run_hook toolless
  [ "$status" -ne 0 ]
  [[ "$output" == *"lib/bad2.sh"* ]]
  # Must name the offender, not indict the innocent file.
  [[ "$output" != *"lib/good2.sh: line"* ]]
}

# ---------------------------------------------------------------------------
# (d) The hook is wired into pre-commit the way the config claims.
# ---------------------------------------------------------------------------

@test "(d) .pre-commit-config.yaml's hook entry exists and is executable" {
  local entry
  entry="$(grep -A6 'entry: .hooks/pre-commit' "$REPO_ROOT/.pre-commit-config.yaml" | head -1)"
  [ -n "$entry" ]
  [ -x "$HOOK" ]
}

@test "(d2) the hook runs on shell commits, not only PHP ones (config wiring)" {
  # types: [php] would mean a pure-bash commit never runs the hook at all,
  # which would make every shell test above unreachable in real life.
  run grep -A10 'entry: .hooks/pre-commit' "$REPO_ROOT/.pre-commit-config.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" != *"types: [php]"* ]]
}

@test "(d3) the hook itself is valid bash" {
  run bash -n "$HOOK"
  [ "$status" -eq 0 ]
}
