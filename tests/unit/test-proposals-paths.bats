#!/usr/bin/env bats
# `pl proposals` — read the path per-site proposals are ACTUALLY at, and report
# an empty result instead of returning it as success.
#
# WHY THIS FILE EXISTS
# --------------------
# `pl proposals --sites` looked in `sites/<name>/docs/proposals/`, a directory
# that exists for no site and never has. Measured 2026-08-16 on the real tree:
#
#   pl proposals --sites   ->  header, no rows, exit 0
#
# while 200 files holding 55 distinct proposals sat in
# `sites/<site>/{dev,stg}/html/profiles/custom/<profile>/docs/proposals/` and
# `sites/<site>/{dev,stg}/docs/proposals/`. Exit 0 is what made it survive: a
# verb looking in the wrong place was indistinguishable from a tree with
# nothing in it.
#
# Cases 1-5 are RED against the pre-fix verb. Case 6 (root proposals still
# listed) is the regression guard and is green on both sides.

setup() {
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  CMD="${REPO_ROOT}/scripts/commands/proposals.sh"
  TEST_TMP=$(mktemp -d)
  FIX="${TEST_TMP}/tree"

  # -- the profile layout CLAUDE.md documents, present in dev AND stg --------
  local prof="html/profiles/custom/demo/docs/proposals"
  mkdir -p "${FIX}/sites/demo/dev/${prof}" "${FIX}/sites/demo/stg/${prof}"
  printf '# D01: The first thing\n\n**Status:** PROPOSED\n' \
    > "${FIX}/sites/demo/dev/${prof}/D01-first.md"
  printf '# D01: The first thing\n\n**Status:** PROPOSED\n' \
    > "${FIX}/sites/demo/stg/${prof}/D01-first.md"       # the dev/stg duplicate

  # -- the flat per-env layout (sites with no profile repo use this) ---------
  mkdir -p "${FIX}/sites/demo/dev/docs/proposals"
  printf '# D02: The second thing\n\n**Status:** IMPLEMENTED\n' \
    > "${FIX}/sites/demo/dev/docs/proposals/D02-second.md"

  # -- NOT a proposal: a Moodle preset bundle that contains a directory
  #    genuinely named `proposals`. A naive `find sites -name proposals` picks
  #    this up; the enumerated globs must not.
  mkdir -p "${FIX}/sites/demo/dev/mod/data/preset/somepreset/proposals"
  printf '# NOT-A-PROPOSAL\n' \
    > "${FIX}/sites/demo/dev/mod/data/preset/somepreset/proposals/nope.md"

  # -- root NWP proposals ---------------------------------------------------
  mkdir -p "${FIX}/docs/proposals"
  printf '# P99: A root proposal\n\n**Status:** PROPOSED\n' \
    > "${FIX}/docs/proposals/P99-root.md"

  export PROJECT_ROOT="${FIX}"
  export TEST_TMP FIX REPO_ROOT CMD
}

teardown() {
  [ -n "${TEST_TMP:-}" ] && rm -rf "${TEST_TMP}"
}

@test "--sites finds proposals in the profile layout (the 200 invisible files)" {
  run bash "$CMD" --sites
  [ "$status" -eq 0 ]
  [[ "$output" == *"D01-first"* ]]
}

@test "--sites finds proposals in the flat per-env layout too" {
  run bash "$CMD" --sites
  [ "$status" -eq 0 ]
  [[ "$output" == *"D02-second"* ]]
}

@test "dev and stg copies of one proposal collapse to a single row" {
  run bash "$CMD" --sites
  [ "$status" -eq 0 ]
  # exactly one D01 row, not two
  [ "$(printf '%s\n' "$output" | grep -c 'D01-first')" -eq 1 ]
  # and the two real proposals are both there
  [[ "$output" == *"2 proposal(s) listed across 1 site(s)"* ]]
}

@test "a Moodle preset directory named 'proposals' is not mistaken for one" {
  run bash "$CMD" --sites
  [ "$status" -eq 0 ]
  [[ "$output" != *"NOT-A-PROPOSAL"* ]]
  [[ "$output" != *"nope"* ]]
}

@test "finding nothing exits 2 and NAMES the paths searched" {
  rm -rf "${FIX}/sites/demo"
  mkdir -p "${FIX}/sites/empty"
  run bash "$CMD" --sites
  [ "$status" -eq 2 ]
  [[ "$output" == *"No proposals found"* ]]
  [[ "$output" == *"Paths searched"* ]]
  [[ "$output" == *"html/profiles/custom"* ]]
}

@test "a --status that matches nothing says so, and does not look like an empty tree" {
  run bash "$CMD" --sites --status=NO-SUCH-STATUS
  [ "$status" -eq 2 ]
  [[ "$output" == *"No proposals matched"* ]]
  [[ "$output" == *"2 proposal(s) were found"* ]]
}

@test "root proposals are still listed (regression guard)" {
  run bash "$CMD" --root
  [ "$status" -eq 0 ]
  [[ "$output" == *"P99-root"* ]]
  [[ "$output" == *"nwp-root"* ]]
}
