#!/usr/bin/env bats
# pl worktree — safe pruning of git worktrees, with a fate manifest.
#
# WHY THIS EXISTS: `git worktree list | wc -l` in ~/nwp was 90 and still
# climbing (103 by the time this test was written), 1.2 GB across the
# non-primary trees, of which only ~15 carried unmerged work. Nothing in the
# estate could enumerate — let alone safely reclaim — that. `pl branch
# stranded --prune-merged` prunes BRANCH REFS only; its own header records
# "77 worktrees" as a known unaddressed problem.
#
# THE DANGEROUS SHAPE: several agents hold UNCOMMITTED work in those trees at
# any moment. A tool that deletes working directories in that repo must be
# refuse-first. So the RED conditions below are about what must SURVIVE:
#
#   RED (test fails) if prune removes W2 (unmerged), W3 (dirty),
#                    W4 (untracked data payload), or the tree it is
#                    standing in; or if it deletes a branch ref.
#   GREEN            dry-run is the default, prints the manifest, touches
#                    nothing; --yes removes exactly W1.
#
# NEGATIVE CONTROL: "refuse everything" is the trivially safe implementation
# and it must NOT pass. `prune --yes removes exactly W1` and
# `dry-run manifest contains at least one REMOVE` are that control — a tool
# that never removes anything fails both.

setup() {
  REPO="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  PL="$REPO/pl"
  TEST_TMP=$(mktemp -d)
  GIT="git -c user.email=t@t -c user.name=t -c commit.gpgsign=false"

  # --- fixture repo with a real origin/main (the default base ref) ---------
  FIX="$TEST_TMP/repo"
  ORIGIN="$TEST_TMP/origin.git"
  mkdir -p "$FIX"
  $GIT init -q --bare -b main "$ORIGIN"
  $GIT init -q -b main "$FIX"
  echo "base" > "$FIX/file.txt"
  # backups/ is GITIGNORED — as it is in the real nwp tree. This is what makes
  # W4 a discriminating fixture: an ignored payload is invisible to the
  # untracked predicate AND to `git worktree remove`'s own refusal (git deletes
  # ignored files without complaint), so ONLY wt_payload can save it.
  echo "backups/" > "$FIX/.gitignore"
  $GIT -C "$FIX" add -A
  $GIT -C "$FIX" commit -q -m init
  $GIT -C "$FIX" remote add origin "$ORIGIN"
  $GIT -C "$FIX" push -q -u origin main

  # W1 — clean, fully merged: the ONLY tree that may be removed.
  $GIT -C "$FIX" worktree add -q -b wt1 "$TEST_TMP/w1" main

  # W2 — clean, but one commit main does not have.
  $GIT -C "$FIX" worktree add -q -b wt2 "$TEST_TMP/w2" main
  echo "unlanded work" > "$TEST_TMP/w2/new.txt"
  $GIT -C "$TEST_TMP/w2" add -A
  $GIT -C "$TEST_TMP/w2" commit -q -m "work that exists only here"

  # W3 — merged, but a tracked file is modified and uncommitted.
  $GIT -C "$FIX" worktree add -q -b wt3 "$TEST_TMP/w3" main
  echo "edited in place" >> "$TEST_TMP/w3/file.txt"

  # W4 — merged and clean of tracked changes, but holding a data payload.
  $GIT -C "$FIX" worktree add -q -b wt4 "$TEST_TMP/w4" main
  mkdir -p "$TEST_TMP/w4/backups"
  printf 'not really gzip' > "$TEST_TMP/w4/backups/x.sql.gz"

  BRANCHES_BEFORE=$($GIT -C "$FIX" branch --list | sed 's/^[*+ ] //' | sort)
}

teardown() {
  [ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"
}

_prune() { run "$PL" worktree prune --repo="$FIX" "$@"; }

# ---------------------------------------------------------------------------
# The verb exists and is registered
# ---------------------------------------------------------------------------

@test "pl registers a worktree verb" {
  run "$PL" commands
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^\s*worktree\b'
}

@test "pl worktree list enumerates every worktree of the target repo" {
  run "$PL" worktree list --repo="$FIX"
  [ "$status" -eq 0 ]
  for w in w1 w2 w3 w4; do
    echo "$output" | grep -q "$TEST_TMP/$w" || { echo "missing $w in:"; echo "$output"; return 1; }
  done
}

# ---------------------------------------------------------------------------
# Fate manifest — printed BEFORE anything is removed
# ---------------------------------------------------------------------------

@test "dry-run prints a fate manifest classifying all four worktrees" {
  _prune --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "FATE MANIFEST"
  echo "$output" | grep -E "REMOVE" | grep -q "$TEST_TMP/w1"
  echo "$output" | grep -E "KEEP\(unmerged\)" | grep -q "$TEST_TMP/w2"
  echo "$output" | grep -E "KEEP\(dirty\)"    | grep -q "$TEST_TMP/w3"
  echo "$output" | grep -E "KEEP\(payload\)"  | grep -q "$TEST_TMP/w4"
}

@test "NEGATIVE CONTROL: the manifest must contain a REMOVE (refuse-everything fails here)" {
  _prune --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "REMOVE"
}

@test "dry-run is the DEFAULT: bare 'prune' removes nothing" {
  _prune
  [ "$status" -eq 0 ]
  for w in w1 w2 w3 w4; do
    [ -d "$TEST_TMP/$w" ] || { echo "bare prune deleted $w"; return 1; }
  done
}

@test "dry-run removes nothing" {
  _prune --dry-run
  [ "$status" -eq 0 ]
  for w in w1 w2 w3 w4; do
    [ -d "$TEST_TMP/$w" ] || { echo "--dry-run deleted $w"; return 1; }
  done
  run bash -c "git -C '$FIX' worktree list | wc -l"
  [ "$output" -eq 5 ]   # primary + 4
}

# ---------------------------------------------------------------------------
# The removal path
# ---------------------------------------------------------------------------

@test "--yes removes exactly W1 and leaves W2-W4 standing" {
  _prune --yes
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_TMP/w1" ] || { echo "W1 (clean+merged) was NOT removed"; return 1; }
  [ -d "$TEST_TMP/w2" ]   || { echo "RED: removed W2 (unmerged commit)"; return 1; }
  [ -d "$TEST_TMP/w3" ]   || { echo "RED: removed W3 (uncommitted change)"; return 1; }
  [ -d "$TEST_TMP/w4" ]   || { echo "RED: removed W4 (data payload)"; return 1; }
}

@test "removing the checkout never removes the branch ref" {
  _prune --yes
  [ "$status" -eq 0 ]
  local after
  after=$(git -C "$FIX" branch --list | sed 's/^[*+ ] //' | sort)
  [ "$after" = "$BRANCHES_BEFORE" ] || {
    echo "branch refs changed:"; diff <(echo "$BRANCHES_BEFORE") <(echo "$after"); return 1; }
}

@test "git's own worktree registration is cleaned up after removal" {
  _prune --yes
  run bash -c "git -C '$FIX' worktree list | grep -c ."
  [ "$output" -eq 4 ]
}

# ---------------------------------------------------------------------------
# Self-protection
# ---------------------------------------------------------------------------

@test "refuses to saw off the branch it is sitting on (run from inside W1)" {
  run bash -c "cd '$TEST_TMP/w1' && '$PL' worktree prune --repo='$FIX' --yes"
  [ -d "$TEST_TMP/w1" ] || { echo "RED: pruned the worktree it was standing in"; return 1; }
  echo "$output" | grep -qE "KEEP\((current|self)\)"
}

@test "never removes the primary worktree" {
  _prune --dry-run
  echo "$output" | grep -E "KEEP\(primary\)" | grep -q "$FIX"
}

# ---------------------------------------------------------------------------
# Further refuse-predicates
# ---------------------------------------------------------------------------

@test "keeps a worktree holding untracked non-data files" {
  git -c user.email=t@t -c user.name=t -C "$FIX" worktree add -q -b wt5 "$TEST_TMP/w5" main
  echo scratch > "$TEST_TMP/w5/notes.md"
  _prune --dry-run
  echo "$output" | grep -E "KEEP\(untracked\)" | grep -q "$TEST_TMP/w5"
}

@test "keeps a detached-HEAD worktree (merged-ness is not computable)" {
  git -c user.email=t@t -c user.name=t -C "$FIX" worktree add -q --detach "$TEST_TMP/w6" main
  _prune --dry-run
  echo "$output" | grep -E "KEEP\(detached\)" | grep -q "$TEST_TMP/w6"
  _prune --yes
  [ -d "$TEST_TMP/w6" ]
}

@test "keeps a worktree whose branch has a stash entry" {
  git -c user.email=t@t -c user.name=t -C "$FIX" worktree add -q -b wt7 "$TEST_TMP/w7" main
  echo "half-done" >> "$TEST_TMP/w7/file.txt"
  git -c user.email=t@t -c user.name=t -C "$TEST_TMP/w7" stash push -q -m "wip"
  _prune --dry-run
  echo "$output" | grep -E "KEEP\(stash\)" | grep -q "$TEST_TMP/w7"
  _prune --yes
  [ -d "$TEST_TMP/w7" ]
}

@test "fails closed when the base ref cannot be resolved" {
  _prune --base=refs/heads/does-not-exist --yes
  [ "$status" -ne 0 ]
  # ...and says WHY. Without this the test is green against a missing
  # command ("Unknown command: worktree" also exits non-zero).
  echo "$output" | grep -qi "base ref"
  for w in w1 w2 w3 w4; do
    [ -d "$TEST_TMP/$w" ] || { echo "RED: removed $w with an unresolvable base"; return 1; }
  done
}

@test "a locked worktree is kept" {
  git -C "$FIX" worktree lock "$TEST_TMP/w1"
  _prune --yes
  [ "$status" -eq 0 ]
  echo "$output" | grep -E "KEEP\(locked\)" | grep -q "$TEST_TMP/w1"
  [ -d "$TEST_TMP/w1" ] || { echo "RED: removed a locked worktree"; return 1; }
  git -C "$FIX" worktree unlock "$TEST_TMP/w1"
}

# ---------------------------------------------------------------------------
# Contract + hygiene
# ---------------------------------------------------------------------------

@test "worktree.sh and lib/worktree-prune.sh are syntactically valid" {
  run bash -n "$REPO/scripts/commands/worktree.sh"
  [ "$status" -eq 0 ]
  run bash -n "$REPO/lib/worktree-prune.sh"
  [ "$status" -eq 0 ]
}

@test "the verb adopts the impact contract (renders a manifest, then confirms)" {
  grep -q 'lib/impact.sh' "$REPO/scripts/commands/worktree.sh"
  grep -qE '^[^#]*impact_render'  "$REPO/scripts/commands/worktree.sh"
  grep -qE '^[^#]*impact_confirm' "$REPO/scripts/commands/worktree.sh"
}

@test "the verb never deletes branch refs (no branch -D/-d in the source)" {
  # File-existence first: `! grep` over a missing file is green for the wrong
  # reason, which is precisely the vacuous-pass shape this suite exists to avoid.
  [ -f "$REPO/scripts/commands/worktree.sh" ]
  [ -f "$REPO/lib/worktree-prune.sh" ]
  ! grep -nE '^[^#]*git[^|]*branch[[:space:]]+-[dD]' "$REPO/scripts/commands/worktree.sh" "$REPO/lib/worktree-prune.sh"
}
