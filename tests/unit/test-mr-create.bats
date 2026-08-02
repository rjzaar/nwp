#!/usr/bin/env bats
#
# test-mr-create.bats — `pl mr create`, the other half of ops#216.
#
# WHY THE VERB EXISTS. Until 2026-08-03 every session opened its own merge
# request with a hand-rolled `curl POST /merge_requests`. Each one therefore
# also re-decided, from memory, whether what it had just written touched a
# CLAUDE.md sensitive path. `pl mr guard` exists precisely because remembering
# is the thing that fails — on 2026-08-01 a hold that had been remembered,
# recorded and written down was still lost.
#
# WHAT THESE CASES PIN. The offline half: every refusal, and the fact that each
# refusal is reached WITHOUT a token. That last property is the `verify_restic`
# lesson (2026-08-02) applied here — that command checked `command -v restic`
# before it checked its own flag, so an illegal argument was silently accepted
# on any host without restic. Whether an argument is legal is a property of the
# COMMAND. If these cases only passed on a machine that happens to hold a token,
# they would be asserting the machine.
#
# NEGATIVE CONTROLS throughout: a validator that refuses everything protects
# nothing, so each refusal is paired with an input that must get PAST it.

setup() {
  ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  MR="${ROOT}/scripts/commands/mr.sh"
  TMP="$BATS_TEST_TMPDIR/mrcreate"
  mkdir -p "$TMP"

  # HERMETIC. These cases must reach their verdict with no credentials at all;
  # if the ambient shell (or an MR pipeline) exports one, they would take a
  # different path here than they take on the runner.
  unset CI_MERGE_REQUEST_IID CI_MERGE_REQUEST_TARGET_BRANCH_NAME \
        CI_SERVER_HOST CI_PROJECT_ID CI_API_V4_URL \
        NWP_MR_TOKEN NWP_GITLAB_HOST GITLAB_TOKEN MR_HOLD_TOKEN
  export NWP_SECRETS_FILE="$TMP/no-secrets.yml"   # deliberately absent

  # A throwaway repo with a real 'origin' and a real remote-tracking ref, so
  # "did you push it?" is answered from git, not from a stub.
  UP="$TMP/upstream.git"; WORK="$TMP/work"
  git init -q --bare -b main "$UP"
  git init -q -b main "$WORK"
  git -C "$WORK" config user.email t@example.com
  git -C "$WORK" config user.name t
  git -C "$WORK" config commit.gpgsign false
  echo hi > "$WORK/a.txt"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m "base: the first commit"
  git -C "$WORK" remote add origin "$UP"
  git -C "$WORK" push -q -u origin main
}

_create() { ( cd "$WORK" && bash "$MR" create "$@" ) }

@test "create1: refuses an MR from a branch to itself" {
  run _create --target=main
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a review"* ]]
}

@test "create2: refuses a branch that was never pushed, and says how to push it" {
  git -C "$WORK" checkout -q -b feat/unpushed
  echo x >> "$WORK/a.txt"; git -C "$WORK" commit -qam "feat: something"
  run _create
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
  [[ "$output" == *"git push -u origin feat/unpushed"* ]]
}

@test "create3: refuses a detached HEAD rather than inventing a branch name" {
  git -C "$WORK" checkout -q --detach
  run _create
  [ "$status" -ne 0 ]
  [[ "$output" == *"detached HEAD"* || "$output" == *"--source=BRANCH"* ]]
}

@test "create4: refuses a --desc-file that does not exist" {
  git -C "$WORK" checkout -q -b feat/desc
  echo x >> "$WORK/a.txt"; git -C "$WORK" commit -qam "feat: desc"
  git -C "$WORK" push -q -u origin feat/desc
  run _create --desc-file="$TMP/nope.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such --desc-file"* ]]
}

@test "create5: NEGATIVE CONTROL — a pushed branch with valid args gets PAST validation" {
  # It must fail on the MISSING TOKEN, not on the arguments. Without this case
  # the four refusals above could all be one over-eager guard refusing anything.
  git -C "$WORK" checkout -q -b feat/ok
  echo x >> "$WORK/a.txt"; git -C "$WORK" commit -qam "feat: ok"
  git -C "$WORK" push -q -u origin feat/ok
  run _create
  [ "$status" -ne 0 ]
  [[ "$output" == *"no usable token"* ]]
  [[ "$output" != *"not a review"* ]]
  [[ "$output" != *"does not exist"* ]]
}

@test "create6: every argument refusal is reached WITHOUT a token" {
  # The verify_restic lesson, made checkable. If the token check ran first, this
  # would report the token error for a self-targeted MR and the argument bug
  # would be invisible on any machine that lacks a token — i.e. every runner.
  run _create --target=main
  [[ "$output" == *"not a review"* ]]
  [[ "$output" != *"no usable token"* ]]
}

@test "create7: an unpushed local commit on a pushed branch WARNS about what is reviewed" {
  # The MR reviews origin/<branch>. A local commit that was not pushed is not in
  # it, and silently reviewing less than the author thinks is a real hazard.
  git -C "$WORK" checkout -q -b feat/ahead
  echo x >> "$WORK/a.txt"; git -C "$WORK" commit -qam "feat: pushed"
  git -C "$WORK" push -q -u origin feat/ahead
  echo y >> "$WORK/a.txt"; git -C "$WORK" commit -qam "feat: NOT pushed"
  run _create
  [[ "$output" == *"not what is in your worktree"* ]]
}

@test "create8: --help is a help, not an attempt" {
  run _create --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: pl mr create"* ]]
}

@test "create9: pl mr --help advertises create" {
  run bash "$MR" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"pl mr create"* ]]
}
