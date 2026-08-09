#!/usr/bin/env bats
#
# Acceptance tests for scripts/ci/lint-site-names.sh (ops#326) — the guard
# that keeps private site-instance names out of the engine's tracked tree.
#
# RED-THEN-GREEN record (all observed against the real tree, 2026-08-09,
# before the baseline was committed):
#   * real deny-list + no baseline      → EXIT=1, "ERROR: 440 new / 0 grown"
#   * planted new name in a fresh file  → EXIT=1, "NEW private-name
#     reference(s): docs/tmp-e2e-newname.md (1 match(es))"
#   * appended hit to a baselined file  → EXIT=1, "REFERENCES GREW:
#     .gitignore  1 -> 2 (shrink-only)"
#   * baseline row above reality        → EXIT=1, "REFERENCES SHRANK"
#   * no deny-list readable (worktree)  → EXIT=2, "CANNOT VERIFY"
#
# Every fixture name here is FICTIONAL (fxq / fxzed / fxm — the reserved fx*
# fixture namespace from the ops#326 design). This file is tracked, so a real
# denied name in it would be a finding against itself.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LINT="$PROJECT_ROOT/scripts/ci/lint-site-names.sh"
  FIX="$(mktemp -d)"
  unset NWP_SITE_NAME_DENYLIST NWP_SITE_NAME_ROOT NWP_SITE_NAME_BASELINE
  git -C "$FIX" init -q
  git -C "$FIX" config user.email fx@example.invalid
  git -C "$FIX" config user.name fx
  DENY="$FIX/deny.list"
  BASE="$FIX/baseline"
  printf 'fxq\nfxzed\n' > "$DENY"
}

teardown() {
  [ -n "${FIX:-}" ] && rm -rf "$FIX"
}

lint() {
  run bash "$LINT" --root="$FIX" --denylist="$DENY" --baseline="$BASE" "$@"
}

plant() { # plant <relpath> <content>
  mkdir -p "$FIX/$(dirname "$1")"
  printf '%s\n' "$2" > "$FIX/$1"
  git -C "$FIX" add "$1"
}

# ------------------------------------------------------------- detection ----

@test "site-names: a denied name in a tracked file is RED, naming file, line and name" {
  plant docs/note.md 'rollout plan for the fxq instance'
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"NEW private-name reference(s): docs/note.md"* ]]
  [[ "$output" == *"docs/note.md:1: matches denied name 'fxq'"* ]]
}

@test "site-names: a denied name in a tracked PATH alone is RED" {
  plant conf/fxq.conf 'server_name example.invalid;'
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"NEW private-name reference(s): conf/fxq.conf"* ]]
  [[ "$output" == *"(path): matches denied name 'fxq'"* ]]
}

@test "site-names: word-boundary — the name inside longer identifiers is NOT a hit" {
  # underscore is a word character; prefixed/suffixed forms are other words
  plant lib/tool.sh 'fxq_oauth2 prefxq fxqsuffix and FXQ stay clean'
  lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK — no new private-site-name references"* ]]
}

@test "site-names: an untracked file is not scanned (the lint guards the TREE)" {
  plant docs/clean.md 'nothing here'
  printf 'fxq\n' > "$FIX/scratch.txt"   # never git-added
  lint
  [ "$status" -eq 0 ]
}

@test "site-names: per-name exclude ERE from the deny-list discounts the measured FP context" {
  printf 'fxq\tmicrosoft-fxq\n' > "$DENY"
  plant docs/guide.md 'see the moodle-microsoft-fxq guide'
  lint
  [ "$status" -eq 0 ]
  plant docs/guide2.md 'the fxq vhost proper'
  lint
  [ "$status" -eq 1 ]
}

@test "site-names: minified assets are globally excluded" {
  plant static/app.min.js 'var a="fxq";'
  plant static/app.js 'var clean=1;'
  lint
  [ "$status" -eq 0 ]
}

# ------------------------------------------------------------ fail-closed ---

@test "site-names: NO deny-list readable is EXIT 2 CANNOT VERIFY, never a pass" {
  plant docs/x.md 'anything'
  run bash "$LINT" --root="$FIX" --baseline="$BASE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
  [[ "$output" == *"NWP_SITE_NAME_DENYLIST"* ]]
}

@test "site-names: an EMPTY deny-list is EXIT 2, not a green tick over nothing" {
  : > "$DENY"
  plant docs/x.md 'anything'
  lint
  [ "$status" -eq 2 ]
  [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "site-names: a malformed deny-list entry is EXIT 2 (unparseable policy is not enforced-less)" {
  printf 'Fxq(\n' > "$DENY"
  plant docs/x.md 'anything'
  lint
  [ "$status" -eq 2 ]
  [[ "$output" == *"malformed deny-list entry"* ]]
}

@test "site-names: outside a git checkout is EXIT 2" {
  NOGIT="$(mktemp -d)"
  run bash "$LINT" --root="$NOGIT" --denylist="$DENY" --baseline="$BASE"
  rm -rf "$NOGIT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a git checkout"* ]]
}

# --------------------------------------------------- baseline: shrink-only ---

@test "site-names: --update-baseline then check is GREEN, and the baseline is NAME-FREE" {
  plant docs/note.md 'the fxq and fxzed instances'
  bash "$LINT" --root="$FIX" --denylist="$DENY" --baseline="$BASE" --update-baseline
  lint
  [ "$status" -eq 0 ]
  # privacy: counts only — the denied names must not be written into the
  # tracked baseline (the deny-list must stay untracked to mean anything)
  ! grep -qw 'fxq' "$BASE"
  ! grep -qw 'fxzed' "$BASE"
  grep -q "docs/note.md	2" "$BASE"
}

@test "site-names: a GROWN count in a baselined file is RED (shrink-only)" {
  plant docs/note.md 'fxq once'
  bash "$LINT" --root="$FIX" --denylist="$DENY" --baseline="$BASE" --update-baseline
  plant docs/note.md 'fxq once
fxq twice'
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFERENCES GREW: docs/note.md  1 -> 2 (shrink-only)"* ]]
}

@test "site-names: equal-count SUBSTITUTION of one denied name for another stays baselined (documented failure mode)" {
  plant docs/note.md 'fxq here'
  bash "$LINT" --root="$FIX" --denylist="$DENY" --baseline="$BASE" --update-baseline
  plant docs/note.md 'fxzed here'
  lint
  [ "$status" -eq 0 ]
}

@test "site-names: a cleaned file with a lingering baseline row is RED (exactness both directions)" {
  plant docs/note.md 'fxq lives here'
  bash "$LINT" --root="$FIX" --denylist="$DENY" --baseline="$BASE" --update-baseline
  plant docs/note.md 'now clean'
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"STALE BASELINE ROW"* ]]
}

@test "site-names: a SHRUNK count is RED until the row is lowered" {
  plant docs/note.md 'fxq one
fxq two'
  bash "$LINT" --root="$FIX" --denylist="$DENY" --baseline="$BASE" --update-baseline
  plant docs/note.md 'fxq one'
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFERENCES SHRANK"* ]]
  [[ "$output" == *"docs/note.md  2 -> 1"* ]]
}

@test "site-names: --update-baseline preserves #= sticky decision comments" {
  plant docs/note.md 'fxq'
  bash "$LINT" --root="$FIX" --denylist="$DENY" --baseline="$BASE" --update-baseline
  printf '#= RECORDED DECISION: kept on purpose, see MR\n' >> "$BASE"
  bash "$LINT" --root="$FIX" --denylist="$DENY" --baseline="$BASE" --update-baseline
  grep -q '^#= RECORDED DECISION' "$BASE"
}

# ----------------------------------------------------- CI wiring, no drift ---

@test "site-names: .gitlab-ci.yml really calls this script (job and test cannot drift apart)" {
  grep -q 'lint:site-names:' "$PROJECT_ROOT/.gitlab-ci.yml"
  grep -q 'scripts/ci/lint-site-names.sh' "$PROJECT_ROOT/.gitlab-ci.yml"
}

@test "site-names: the committed baseline is exact against the real tree (when a deny-list is readable)" {
  if [ ! -r "$PROJECT_ROOT/private/site-names.deny" ] && [ -z "${NWP_SITE_NAME_DENYLIST:-}" ]; then
    # honesty: this is NOT a skip-to-green — without the private policy the
    # lint itself exits 2 CANNOT VERIFY, which is what CI surfaces. Assert
    # exactly that, so the absent-policy path is the tested path.
    run bash "$LINT" --root="$PROJECT_ROOT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
  else
    run bash "$LINT" --root="$PROJECT_ROOT"
    [ "$status" -eq 0 ]
  fi
}
