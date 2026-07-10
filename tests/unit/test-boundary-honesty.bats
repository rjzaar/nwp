#!/usr/bin/env bats
# P74 Phase 1 — the boundary manifest-honesty test.
#
# The pair contract's `boundary:` block declares, per surface, a set of PRIVATE
# provider_symbols and the paths they may live in. This test fails if any such
# symbol is referenced (in NON-COMMENT production code, outside `tests/` dirs)
# from a file OUTSIDE that surface's declared paths — i.e. a boundary symbol
# grew a new cross-module tentacle that the manifest doesn't know about.
#
# Runs against the working tree. In nwp CI `sites/*` is gitignored so the nwc
# profile is absent and the check is trivially clean; on a dev workstation with
# the profile present it scans the canonical `sites/nwc` + `lib` roots.

setup() {
  export PROJECT_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  export NWP_PAIR_CONTRACT_DIR="${PROJECT_ROOT}/pairs"
  CONTRACT="${NWP_PAIR_CONTRACT_DIR}/ssc.pair-contract.yml"
  source "${PROJECT_ROOT}/lib/impact.sh"
  source "${PROJECT_ROOT}/lib/boundary.sh"
}

@test "every declared surface has at least one provider_symbol and one path" {
  local surface
  while IFS= read -r surface; do
    [ -n "$surface" ] || continue
    [ -n "$(boundary_symbols "$surface" "$CONTRACT")" ] || {
      echo "surface '$surface' has no provider_symbols"; return 1; }
    [ -n "$(boundary_paths "$surface" "$CONTRACT")" ] || {
      echo "surface '$surface' has no paths"; return 1; }
  done < <(boundary_surfaces "$CONTRACT")
}

@test "manifest is HONEST on the current tree (no symbol leaks outside declared paths)" {
  run boundary_honesty_violations "$CONTRACT"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    echo "manifest-honesty violations found:"
    echo "$output"
    return 1
  fi
}

@test "the honesty check DETECTS an injected leak (self-test of the detector)" {
  # Inject a fake production file that references a boundary symbol from outside
  # any declared path, then assert the detector flags it.
  local leakdir="${PROJECT_ROOT}/lib/__boundary_honesty_selftest"
  mkdir -p "$leakdir"
  cat > "${leakdir}/leak.php" <<'PHP'
<?php
// A real code edge (not a comment):
$x = new NwcOidcClaimsServiceProvider();
PHP
  run boundary_honesty_violations "$CONTRACT"
  rm -rf "$leakdir"
  [[ "$output" == *"NwcOidcClaimsServiceProvider"* ]]
  [[ "$output" == *"VIOLATION"* ]]
}

@test "a COMMENT-only reference outside declared paths is NOT a violation" {
  local cdir="${PROJECT_ROOT}/lib/__boundary_honesty_selftest_comment"
  mkdir -p "$cdir"
  cat > "${cdir}/note.php" <<'PHP'
<?php
// This mentions MoodleToolPolicySync in a comment only — must be ignored.
PHP
  run boundary_honesty_violations "$CONTRACT"
  rm -rf "$cdir"
  [[ "$output" != *"__boundary_honesty_selftest_comment"* ]]
}
