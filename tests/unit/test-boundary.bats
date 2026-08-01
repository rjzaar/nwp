#!/usr/bin/env bats
# P74 Phase 2 — the intersite change-impact classifier (lib/boundary.sh / pl impact).
#
# Feeds SYNTHETIC diffs via NWP_IMPACT_FILES (the test/CI hook) so every surface
# is exercised without a real git diff or the nwc profile repo being present.
# Touches no network, no site, no secrets.

setup() {
  export PROJECT_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  export NWP_PAIR_CONTRACT_DIR="${PROJECT_ROOT}/pairs"
  CONTRACT="${NWP_PAIR_CONTRACT_DIR}/ssc.pair-contract.yml"
  NWC="sites/nwc/dev/html/profiles/custom/nwc/modules/nwc_features"
  source "${PROJECT_ROOT}/lib/impact.sh"
  source "${PROJECT_ROOT}/lib/boundary.sh"
}

@test "contract exposes the 7 boundary surfaces" {
  run boundary_surfaces "$CONTRACT"
  [ "$status" -eq 0 ]
  [[ "$output" == *oauth_sso* ]]
  [[ "$output" == *copyright_sync* ]]
  [[ "$output" == *feedback_bridge* ]]
  [[ "$output" == *role_cohort_sync* ]]
  [[ "$output" == *badge_read* ]]
  [[ "$output" == *shared_salt* ]]
  [[ "$output" == *erasure* ]]   # ops#81 P0 — 7th surface (nwc→ssc RTBF erase)
  [ "$(boundary_surfaces "$CONTRACT" | wc -l)" -eq 7 ]
}

@test "BOUNDARY-TOUCHING: erasure (ops#81 consumer plugin glob fires)" {
  export NWP_IMPACT_FILES="moodle/local/nwc_erase/erase.php"
  boundary_classify main "$CONTRACT"
  [ "$BOUNDARY_CLASS" = "BOUNDARY-TOUCHING" ]
  [ "${BOUNDARY_SURFACES[0]}" = "erasure" ]
}

@test "INTERNAL: a diff touching no boundary path" {
  export NWP_IMPACT_FILES=$'README.md\nlib/ui.sh\ndocs/foo.md'
  boundary_classify main "$CONTRACT"
  [ "$BOUNDARY_CLASS" = "INTERNAL" ]
  [ "$BOUNDARY_UNCOMPUTABLE" -eq 0 ]
  [ "${#BOUNDARY_SURFACES[@]}" -eq 0 ]
}

@test "BOUNDARY-TOUCHING: shared_salt (in-repo path)" {
  export NWP_IMPACT_FILES="lib/sanitizers/oidc-email.sh"
  boundary_classify main "$CONTRACT"
  [ "$BOUNDARY_CLASS" = "BOUNDARY-TOUCHING" ]
  [ "${BOUNDARY_SURFACES[0]}" = "shared_salt" ]
}

@test "BOUNDARY-TOUCHING: shared_salt consumer side (moodle.sh)" {
  export NWP_IMPACT_FILES="lib/sanitizers/moodle.sh"
  boundary_classify main "$CONTRACT"
  [ "$BOUNDARY_CLASS" = "BOUNDARY-TOUCHING" ]
  [ "${BOUNDARY_SURFACES[0]}" = "shared_salt" ]
}

@test "BOUNDARY-TOUCHING: oauth_sso names the surface" {
  export NWP_IMPACT_FILES="${NWC}/nwc_oidc_claims/src/NwcOidcClaimsServiceProvider.php"
  boundary_classify main "$CONTRACT"
  [ "$BOUNDARY_CLASS" = "BOUNDARY-TOUCHING" ]
  [ "${BOUNDARY_SURFACES[0]}" = "oauth_sso" ]
}

@test "BOUNDARY-TOUCHING: copyright_sync" {
  export NWP_IMPACT_FILES="${NWC}/nwc_copyright/src/Service/MoodleToolPolicySync.php"
  boundary_classify main "$CONTRACT"
  [ "${BOUNDARY_SURFACES[0]}" = "copyright_sync" ]
}

@test "BOUNDARY-TOUCHING: feedback_bridge" {
  export NWP_IMPACT_FILES="${NWC}/nwc_feedback/src/Controller/CrossSiteFeedbackController.php"
  boundary_classify main "$CONTRACT"
  [ "${BOUNDARY_SURFACES[0]}" = "feedback_bridge" ]
}

@test "BOUNDARY-TOUCHING: role_cohort_sync (undeclared→now declared)" {
  export NWP_IMPACT_FILES="${NWC}/nwc_moodle/modules/nwc_moodle_sync/nwc_moodle_sync.module"
  boundary_classify main "$CONTRACT"
  [ "${BOUNDARY_SURFACES[0]}" = "role_cohort_sync" ]
}

@test "BOUNDARY-TOUCHING: badge_read (undeclared→now declared)" {
  export NWP_IMPACT_FILES="${NWC}/nwc_moodle/modules/nwc_moodle_data/nwc_moodle_data.module"
  boundary_classify main "$CONTRACT"
  [ "${BOUNDARY_SURFACES[0]}" = "badge_read" ]
}

@test "BOUNDARY-TOUCHING: consumer-side Moodle plugin glob fires" {
  export NWP_IMPACT_FILES="moodle/auth/oauth2/classes/foo.php"
  boundary_classify main "$CONTRACT"
  [ "${BOUNDARY_SURFACES[0]}" = "oauth_sso" ]
}

@test "multi-surface diff collects all touched surfaces in contract order" {
  export NWP_IMPACT_FILES=$"${NWC}/nwc_moodle/modules/nwc_moodle_sync/x.module"$'\n'"${NWC}/nwc_copyright/src/Service/MoodleToolPolicySync.php"$'\n'"README.md"
  boundary_classify main "$CONTRACT"
  [ "$BOUNDARY_CLASS" = "BOUNDARY-TOUCHING" ]
  [ "${#BOUNDARY_SURFACES[@]}" -eq 2 ]
  # Contract order: copyright_sync before role_cohort_sync.
  [ "${BOUNDARY_SURFACES[0]}" = "copyright_sync" ]
  [ "${BOUNDARY_SURFACES[1]}" = "role_cohort_sync" ]
}

@test "FAIL-SAFE CLOSED: uncomputable diff (bad base) ⇒ BOUNDARY" {
  unset NWP_IMPACT_FILES
  boundary_classify "no-such-ref-$$-xyz" "$CONTRACT"
  [ "$BOUNDARY_CLASS" = "BOUNDARY" ]
  [ "$BOUNDARY_UNCOMPUTABLE" -eq 1 ]
}

@test "JSON output is well-formed and reports the classification" {
  export NWP_IMPACT_FILES="lib/sanitizers/oidc-email.sh"
  boundary_classify main "$CONTRACT"
  run boundary_json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"classification":"BOUNDARY-TOUCHING"'* ]]
  [[ "$output" == *'"surfaces":["shared_salt"]'* ]]
  [[ "$output" == *'"uncomputable":false'* ]]
  # Valid JSON per yq.
  echo "$output" | yq e '.' - >/dev/null
}

@test "pl impact exits 0 even on a boundary-touching diff (classifies, never blocks)" {
  run env NWP_IMPACT_FILES="lib/sanitizers/oidc-email.sh" "${PROJECT_ROOT}/pl" impact --json
  [ "$status" -eq 0 ]
  [[ "$output" == *BOUNDARY-TOUCHING* ]]
}

################################################################################
# ops#165 — an unreadable contract must classify FAIL-SAFE CLOSED, not INTERNAL.
#
# boundary:classify ran on a runner with no yq for its whole life: the contract
# parsed to zero surfaces, so every diff — including one rewriting a declared
# provider path — classified INTERNAL, and the artifacted impact.json carried
# that false verdict. These cases pin the repaired behaviour and the CI flag
# that turns "could not classify" into a red job instead of a quiet non-answer.
################################################################################

@test "FAIL-SAFE CLOSED: missing contract file ⇒ BOUNDARY / uncomputable, not INTERNAL" {
  export NWP_IMPACT_FILES="README.md"
  boundary_classify main "${BATS_TEST_TMPDIR}/no-such-contract.yml"
  [ "$BOUNDARY_CLASS" = "BOUNDARY" ]
  [ "$BOUNDARY_UNCOMPUTABLE" -eq 1 ]
  [[ "$BOUNDARY_REASON" == *"unreadable"* ]]
}

@test "FAIL-SAFE CLOSED: no yq on PATH ⇒ BOUNDARY / uncomputable, even for a boundary-touching diff" {
  command -v yq >/dev/null || skip "needs yq present to prove the contrast"
  # Same diff twice: with yq it is BOUNDARY-TOUCHING; without yq the old code
  # said INTERNAL (the ops#165 false-green). Now it must say uncomputable.
  run env PATH=/usr/bin:/bin NWP_IMPACT_FILES="moodle/local/nwc_erase/erase.php" \
      bash -c "source '${PROJECT_ROOT}/lib/boundary.sh'; boundary_classify main '$CONTRACT'; echo \"\$BOUNDARY_CLASS/\$BOUNDARY_UNCOMPUTABLE\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"BOUNDARY/1"* ]]
}

@test "pl impact --fail-uncomputable: exit 2 when classification is fail-safe-closed" {
  run env PATH=/usr/bin:/bin NWP_IMPACT_FILES="README.md" \
      bash "${PROJECT_ROOT}/scripts/commands/impact.sh" --base=main --json --fail-uncomputable
  [ "$status" -eq 2 ]
  [[ "$output" == *'"uncomputable":true'* ]]
}

@test "pl impact --fail-uncomputable: exit 0 when classification computed (INTERNAL)" {
  command -v yq >/dev/null || skip "needs yq"
  run env NWP_IMPACT_FILES="README.md" \
      bash "${PROJECT_ROOT}/scripts/commands/impact.sh" --base=main --json --fail-uncomputable
  [ "$status" -eq 0 ]
  [[ "$output" == *'"classification":"INTERNAL"'* ]]
}

@test "honesty check without yq names the REAL blocker (not 'no surfaces declared')" {
  run env PATH=/usr/bin:/bin bash -c "source '${PROJECT_ROOT}/lib/boundary.sh'; boundary_honesty_check '$CONTRACT'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"yq is not on PATH"* ]]
}

# ---------------------------------------------------------------------------
# ops#196 — the two remaining FAIL-OPEN holes in boundary_contract_readable.
#
# !295 made this job BLOCKING, on the stated ground that the only red it can
# show is "this runner could not classify". That claim rested on
# boundary_contract_readable, which until now asked only `yq on PATH && file
# exists`. Measured on the real tree 2026-08-02, BEFORE this fix:
#
#   corrupt contract  → {"classification":"INTERNAL","uncomputable":false} exit 0
#   boundary: {}      → {"classification":"INTERNAL","uncomputable":false} exit 0
#
# Byte-identical to the verdict a genuinely internal diff gets. That is the
# pre-ops#165 defect ("parsed to zero surfaces ⇒ INTERNAL") surviving in two
# forms the ops#165 fix did not cover — and it is worse under a BLOCKING gate,
# because a green light now reads as positive assurance.
# ---------------------------------------------------------------------------

@test "FAIL-SAFE CLOSED: an UNPARSEABLE contract ⇒ BOUNDARY / uncomputable, not INTERNAL" {
  command -v yq >/dev/null || skip "needs yq to prove the parse itself fails"
  local bad="${BATS_TEST_TMPDIR}/corrupt.pair-contract.yml"
  printf 'boundary:\n  oauth_sso:\n   provider_paths: [\n' > "$bad"
  export NWP_IMPACT_FILES="README.md"
  boundary_classify main "$bad"
  [ "$BOUNDARY_CLASS" = "BOUNDARY" ]
  [ "$BOUNDARY_UNCOMPUTABLE" -eq 1 ]
  [[ "$BOUNDARY_REASON" == *"not parseable YAML"* ]]
}

@test "FAIL-SAFE CLOSED: a contract declaring ZERO surfaces ⇒ BOUNDARY / uncomputable" {
  command -v yq >/dev/null || skip "needs yq"
  local empty="${BATS_TEST_TMPDIR}/empty.pair-contract.yml"
  printf 'pair: ssc\nboundary: {}\n' > "$empty"
  export NWP_IMPACT_FILES="README.md"
  boundary_classify main "$empty"
  [ "$BOUNDARY_CLASS" = "BOUNDARY" ]
  [ "$BOUNDARY_UNCOMPUTABLE" -eq 1 ]
  [[ "$BOUNDARY_REASON" == *"no boundary: surfaces"* ]]
}

@test "pl impact --fail-uncomputable: an unparseable contract is exit 2, never a green INTERNAL" {
  command -v yq >/dev/null || skip "needs yq"
  local dir="${BATS_TEST_TMPDIR}/pairs-bad"
  mkdir -p "$dir"
  printf 'boundary:\n  oauth_sso:\n   provider_paths: [\n' > "$dir/ssc.pair-contract.yml"
  run env NWP_PAIR_CONTRACT_DIR="$dir" NWP_IMPACT_FILES="README.md" \
      bash "${PROJECT_ROOT}/scripts/commands/impact.sh" --base=main --json --fail-uncomputable
  [ "$status" -eq 2 ]
  [[ "$output" == *'"uncomputable":true'* ]]
  [[ "$output" != *'"classification":"INTERNAL"'* ]]
}

@test "boundary_unreadable_why distinguishes all four causes" {
  command -v yq >/dev/null || skip "needs yq"
  run boundary_unreadable_why "${BATS_TEST_TMPDIR}/nope.yml"
  [[ "$output" == *"does not exist"* ]]

  printf 'boundary:\n  x:\n   p: [\n' > "${BATS_TEST_TMPDIR}/c1.yml"
  run boundary_unreadable_why "${BATS_TEST_TMPDIR}/c1.yml"
  [[ "$output" == *"not parseable YAML"* ]]

  printf 'boundary: {}\n' > "${BATS_TEST_TMPDIR}/c2.yml"
  run boundary_unreadable_why "${BATS_TEST_TMPDIR}/c2.yml"
  [[ "$output" == *"no boundary: surfaces"* ]]

  run env PATH=/usr/bin:/bin bash -c "source '${PROJECT_ROOT}/lib/boundary.sh'; boundary_unreadable_why '$CONTRACT'"
  [[ "$output" == *"yq is not on PATH"* ]]
}

# POSITIVE CONTROL for the blocking flip: the gate must still be able to reach
# a real verdict on the real contract, both ways, or "no MR was blocked" would
# only mean "the probe cannot return positive" (see feedback-verify-before-asserting).
@test "the REAL contract still yields both verdicts — the gate is not vacuous" {
  command -v yq >/dev/null || skip "needs yq"
  export NWP_IMPACT_FILES="lib/sanitizers/oidc-email.sh"
  boundary_classify main "$CONTRACT"
  [ "$BOUNDARY_CLASS" = "BOUNDARY-TOUCHING" ]
  [ "$BOUNDARY_UNCOMPUTABLE" -eq 0 ]

  export NWP_IMPACT_FILES="README.md"
  boundary_classify main "$CONTRACT"
  [ "$BOUNDARY_CLASS" = "INTERNAL" ]
  [ "$BOUNDARY_UNCOMPUTABLE" -eq 0 ]
}
