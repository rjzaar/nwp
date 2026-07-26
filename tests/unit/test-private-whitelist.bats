#!/usr/bin/env bats
# The `private/` .gitignore block is defence-in-depth for operator-private
# handoff packs. Item 1 opened exactly two value-free exceptions in it, and an
# exception in an ignore file is the kind of change that is easy to widen by
# accident later. These assertions pin both directions: the two metadata
# artefacts ARE trackable, and everything else in private/ — including new
# files, new subdirectories and the registry itself — is still ignored.

setup() {
  REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  mkdir -p "${REPO}/private/zz-probe-subdir"
  : > "${REPO}/private/zz-probe-subdir/credentials.txt"
  : > "${REPO}/private/zz-probe-loose.md"
  : > "${REPO}/private/zz-probe-loose.yml"
}

teardown() {
  rm -rf "${REPO}/private/zz-probe-subdir" \
         "${REPO}/private/zz-probe-loose.md" \
         "${REPO}/private/zz-probe-loose.yml"
}

@test "private/: the token-consumer map is trackable" {
  : > "${REPO}/private/token-consumers.md"
  run git -C "$REPO" check-ignore -q private/token-consumers.md
  [ "$status" -ne 0 ]
}

@test "private/: rotation logs are trackable" {
  : > "${REPO}/private/rotation-2099-01.md"
  run git -C "$REPO" check-ignore -q private/rotation-2099-01.md
  local rc="$status"
  rm -f "${REPO}/private/rotation-2099-01.md"
  [ "$rc" -ne 0 ]
}

@test "private/: an arbitrary loose file is still ignored" {
  run git -C "$REPO" check-ignore -q private/zz-probe-loose.md
  [ "$status" -eq 0 ]
}

@test "private/: an arbitrary loose yaml is still ignored" {
  run git -C "$REPO" check-ignore -q private/zz-probe-loose.yml
  [ "$status" -eq 0 ]
}

@test "private/: subdirectory contents are still ignored" {
  run git -C "$REPO" check-ignore -q private/zz-probe-subdir/credentials.txt
  [ "$status" -eq 0 ]
}

@test "private/: the secrets registry itself is still ignored" {
  : > "${REPO}/private/zz-secrets-registry-probe.yml"
  run git -C "$REPO" check-ignore -q private/zz-secrets-registry-probe.yml
  local rc="$status"
  rm -f "${REPO}/private/zz-secrets-registry-probe.yml"
  [ "$rc" -eq 0 ]
}

@test "private/: git sees ONLY the two whitelisted artefact shapes" {
  # every path git reports under private/ must be one of the two exceptions —
  # if a future widening lets anything else through, this goes red.
  # -uall: without it git collapses an untracked tree to a single 'private/' entry
  run bash -c "git -C '$REPO' status --porcelain -uall private/ | awk '{print \$2}' \
               | grep -vE 'private/(token-consumers\.md|rotation-[0-9]{4}-[0-9]{2}\.md)$' || true"
  [ -z "$output" ]
}
