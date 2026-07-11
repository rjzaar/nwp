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
