#!/usr/bin/env bats
# B7 — stale-branch sweep: the four provably-superseded branches must stay swept,
# and the content that superseded them must stay on main.
#
# Three branches were deleted from `origin` (and two twins from the `archive`
# remote) on 2026-07-26 because every line they carried is already on main:
#
#   pl-rollback-stdin-fix            (MR !10, CLOSED) -> lib/rollback-remote.sh
#   stg2live-drush-graceful          (MR !11, CLOSED) -> scripts/commands/stg2live.sh
#   chore/gitleaks-allowlist-issue-urls (MR !50, CLOSED) -> .gitleaks.toml
#
# This file has two jobs:
#
#   PART A (offline, always runs) — assert the superseding content is still
#     present. If any of these regress, the sweep's justification evaporates and
#     the deleted work would need resurrecting. These are the gates that had to
#     be GREEN before a single `git push --delete` was run.
#
#   PART B (needs the remote, skips cleanly offline) — assert the branches are
#     actually gone, and that nobody has re-pushed them.
#
# NEGATIVE CONTROLS are load-bearing here, because both halves of this file are
# the kind of test that a blind runner would pass for free:
#   - PART A would pass vacuously on an empty checkout, so each assertion is
#     mirrored against the pre-supersession commit (68430dc / its parent) to
#     prove it can go red.
#   - PART B ("branch X is absent") is trivially satisfied by a probe that can
#     see nothing at all. So every remote probe first has to FIND `main` on that
#     remote. No `main` => the probe is blind => skip, never pass.
#     "I cannot see" must not be reported as "all clear".

REPO="${BATS_TEST_DIRNAME}/../.."

# Commit that is the merge-base of both stranded rollback/stg2live branches, i.e.
# the tree as it was BEFORE MR !10 and MR !11's content reached main. Used as the
# negative control for PART A.
PRE_SUPERSESSION="68430dc"
# Commit that un-blinded the leakage gate; its first parent is .gitleaks.toml
# before the Decision-14 allowlist was carried forward.
GITLEAKS_UNBLIND="92cf069"

have_object() {
  git -C "$REPO" cat-file -e "${1}^{commit}" 2>/dev/null
}

# Probe a remote for branches. Echoes the ls-remote output. Returns non-zero if
# the remote is unreachable OR if it does not report a `main` head — either way
# the probe is blind and the caller must skip, not pass.
probe_remote() {
  local remote="$1" out
  out=$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10' \
        timeout 60 git -C "$REPO" ls-remote --heads "$remote" 2>/dev/null) || return 1
  grep -q 'refs/heads/main$' <<<"$out" || return 1
  printf '%s\n' "$out"
}

# Assert a branch is absent from an ls-remote listing.
#
# Deliberately NOT written as `! grep -q ...`: POSIX says `set -e` is IGNORED
# for a command whose status is inverted with `!`, so under bats a run of
# `! grep` lines silently reduces to "only the last one can fail the test".
# The first draft of this file had exactly that bug — two of the three swept
# branches were unasserted while the suite looked complete. Fail explicitly.
assert_head_absent() {
  local heads="$1" branch="$2"
  if grep -qE "refs/heads/${branch}\$" <<<"$heads"; then
    printf 'FAIL: refs/heads/%s is still present on the remote\n' "$branch" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# PART A — the superseding content is on main
# ---------------------------------------------------------------------------

@test "A1: rollback-remote.sh keeps stdin-safe ssh at every call site (supersedes pl-rollback-stdin-fix / MR !10)" {
  run bash -c "grep -c 'ssh -n -o BatchMode' '$REPO/lib/rollback-remote.sh'"
  [ "$status" -eq 0 ]
  # MR !10 fixed 5 call sites; main has 6 (a later one the branch never saw).
  [ "$output" -ge 5 ]
  # And no bare, stdin-eating ssh survives in this file.
  run grep -nE '(^|[^-])\bssh -o BatchMode' "$REPO/lib/rollback-remote.sh"
  [ "$status" -ne 0 ]
}

@test "A1-control: the same assertion goes RED on the pre-supersession commit" {
  have_object "$PRE_SUPERSESSION" || skip "shallow clone: $PRE_SUPERSESSION not present"
  run bash -c "git -C '$REPO' show ${PRE_SUPERSESSION}:lib/rollback-remote.sh | grep -c 'ssh -n -o BatchMode'"
  # grep -c prints 0 and exits 1 when there are no matches.
  [ "$output" -lt 5 ]
}

@test "A2: stg2live.sh keeps both drush-missing skip guards (supersedes stg2live-drush-graceful / MR !11)" {
  run bash -c "grep -c 'drush unavailable in staging' '$REPO/scripts/commands/stg2live.sh'"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
  # Both guards are attributed, so a future reader can trace them to the closed MR.
  run bash -c "grep -c 'MR !11' '$REPO/scripts/commands/stg2live.sh'"
  [ "$output" -eq 2 ]
}

@test "A2-control: the same assertion goes RED on the pre-supersession commit" {
  have_object "$PRE_SUPERSESSION" || skip "shallow clone: $PRE_SUPERSESSION not present"
  run bash -c "git -C '$REPO' show ${PRE_SUPERSESSION}:scripts/commands/stg2live.sh | grep -c 'drush unavailable in staging'"
  [ "$output" -ne 2 ]
}

@test "A3: .gitleaks.toml keeps the Decision-14 public-URL allowlist in every copy (supersedes chore/gitleaks-allowlist-issue-urls / MR !50)" {
  # Count only LIVE rule lines — the '''-quoted regex — never the explanatory
  # comment above each one. The first version of this assertion grepped the bare
  # substring `merge_requests|blob|tree`, which ALSO matched the two comment
  # lines, so it stayed GREEN with both real allowlist regexes deleted. A guard
  # that a comment can satisfy is not a guard. (Found by mutation during the
  # merge-queue review of this MR.)
  run bash -c "grep -c \"^[^#]*'''git.*merge_requests|blob|tree\" '$REPO/.gitleaks.toml'"
  [ "$status" -eq 0 ]
  # Duplicated per the SHARED-EXEMPTIONS rule documented at the top of the config.
  [ "$output" -ge 2 ]
}

@test "A4: chore/gitleaks-allowlist-issue-urls must never be resurrected — it is a NET REVERT" {
  # The branch predates the 2026-07-26 un-blinding (92cf069). Merging or
  # cherry-picking it would restore a top-level [allowlist] `paths` list, which
  # switches OFF the inherited AWS/GCP/GitHub/GitLab-PAT credential rules for
  # every exempted tree — the exact defect that commit fixed. Its one genuine
  # contribution (the Decision-14 regex) is already on main, asserted by A3.
  #
  # RULE 1 itself is enforced by tests/unit/test-leakage-gate.bats; this case
  # exists so the failure names the branch, and so the file cannot be quietly
  # rolled back to the stranded branch's shape without a test saying why.
  run bash -c "sed -n '/^\[allowlist\]/,/^\[\[/p' '$REPO/.gitleaks.toml' | grep -c '^paths'"
  [ "$output" -eq 0 ]
  run bash -c "grep -c 'RULE 1' '$REPO/.gitleaks.toml'"
  [ "$status" -eq 0 ]
}

@test "A4-control: the pre-un-blinding .gitleaks.toml DOES carry the top-level paths list" {
  have_object "${GITLEAKS_UNBLIND}^" || skip "shallow clone: ${GITLEAKS_UNBLIND}^ not present"
  run bash -c "git -C '$REPO' show ${GITLEAKS_UNBLIND}^:.gitleaks.toml | sed -n '/^\[allowlist\]/,/^\[\[/p' | grep -c '^paths'"
  [ "$output" -ge 1 ]
}

# ---------------------------------------------------------------------------
# PART B — the branches are gone and stay gone
# ---------------------------------------------------------------------------

@test "B1: swept branches are absent from origin (probe must see main first)" {
  local heads
  heads=$(probe_remote origin) || skip "origin unreachable or reported no main — probe is blind, not clear"

  # Negative control, asserted inside the test rather than trusted: the probe
  # sees a branch we know exists. If this fails the whole case is meaningless.
  grep -q 'refs/heads/main$' <<<"$heads"

  assert_head_absent "$heads" 'pl-rollback-stdin-fix'
  assert_head_absent "$heads" 'stg2live-drush-graceful'
  assert_head_absent "$heads" 'chore/gitleaks-allowlist-issue-urls'
}

@test "B2: archive twins are absent from the archive remote (probe must see main first)" {
  git -C "$REPO" remote | grep -qx archive || skip "no 'archive' remote configured"
  local heads
  heads=$(probe_remote archive) || skip "archive unreachable or reported no main — probe is blind, not clear"

  grep -q 'refs/heads/main$' <<<"$heads"

  assert_head_absent "$heads" 'pl-rollback-stdin-fix'
  assert_head_absent "$heads" 'stg2live-drush-graceful'
}

@test "B3: probe_remote refuses to report 'clear' for a remote it cannot reach" {
  # Direct exercise of the negative control itself: a bogus remote must make
  # probe_remote FAIL (-> the caller skips), never return an empty success that
  # the ! grep assertions above would happily read as "branch is gone".
  run probe_remote "file:///nonexistent-remote-$$-b7"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
