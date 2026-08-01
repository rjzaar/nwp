#!/usr/bin/env bats
# ops#174 — the tool_policy site-policy-handler invariant.
#
# ss.nwpcode.org published FIVE mandatory (optional=0), everyone-audience
# (audience=0) tool_policy documents while $CFG->sitepolicyhandler was '' — so
# core's default_handler was active, keyed on an equally empty $CFG->sitepolicy,
# and the documents were presented to nobody. Zero acceptance rows.
#
# These tests pin the VERDICT, which is the part that must not regress:
#   * armed handler                       -> OK
#   * unset handler + published documents -> GAP   (the live defect)
#   * unset handler + nothing visible     -> UNKNOWN, and UNKNOWN IS NOT A PASS
#
# Pure fixtures. NO ddev / ssh / network / secrets / live sites.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  source "${REPO_ROOT}/lib/ui.sh"
  source "${REPO_ROOT}/lib/moodle-policy.sh"

  # Verbatim shape of `admin/cli/cfg.php --component=local_nwc_copyright_sync`
  # on ss live, 2026-08-01 (tab-separated name/value pairs).
  SS_LISTING=$'policyid_aup\t7\npolicyid_beta_cc0\t9\npolicyid_copyright_notice\t8\npolicyid_privacy_policy\t6\npolicyid_site_terms\t5\ntoken_hash\tredacted\nversion\t2026070301'
}

# --- pointer counting --------------------------------------------------------

@test "pointer count: reads the five ss policyid_<slug> rows and ignores the rest" {
  run moodle_policy_pointer_count "$SS_LISTING"
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

@test "pointer count: an empty listing is 0, not an error" {
  run moodle_policy_pointer_count ""
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "pointer count: a listing with no policyid_ rows is 0" {
  run moodle_policy_pointer_count $'version\t2026070301\ntoken_hash\tredacted'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "pointer count: does not match a value that merely contains policyid_" {
  run moodle_policy_pointer_count $'note\tsee policyid_site_terms for detail'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# --- the verdict -------------------------------------------------------------

@test "verdict: armed handler is OK regardless of what is published" {
  run moodle_policy_verdict "tool_policy" 5
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]

  run moodle_policy_verdict "tool_policy" 0
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "verdict: the LIVE ss/ssc pre-fix state (handler '', 5 documents) is a GAP" {
  local pointers
  pointers="$(moodle_policy_pointer_count "$SS_LISTING")"
  run moodle_policy_verdict "" "$pointers"
  [ "$status" -eq 1 ]
  [ "$output" = "GAP" ]
}

@test "verdict: unset handler with nothing visible is UNKNOWN, NOT OK" {
  run moodle_policy_verdict "" 0
  [ "$status" -eq 3 ]
  [ "$output" = "UNKNOWN" ]
  # The vacuous-pass rule: this must never render as a pass.
  [ "$output" != "OK" ]
  [ "$status" -ne 0 ]
}

@test "verdict: some other handler with documents published is still a GAP" {
  run moodle_policy_verdict "some_other_plugin" 5
  [ "$status" -eq 1 ]
  [ "$output" = "GAP" ]
}

# --- explanation -------------------------------------------------------------

@test "explain: GAP says the documents are presented to nobody" {
  run moodle_policy_explain "GAP" "" 5
  [ "$status" -eq 1 ]
  [[ "$output" == *"presented to NOBODY"* ]]
  [[ "$output" == *"5 document(s)"* ]]
}

@test "explain: UNKNOWN states in words that it is not a pass" {
  run moodle_policy_explain "UNKNOWN" "" 0
  [ "$status" -eq 3 ]
  [[ "$output" == *"NOT a pass"* ]]
  [[ "$output" == *"cold policyid_<slug> pointer"* ]]
}

@test "explain: refuses an unrecognised verdict rather than inventing one" {
  run moodle_policy_explain "PROBABLY_FINE" "" 0
  [ "$status" -eq 2 ]
}

# --- the set/rollback command ------------------------------------------------

@test "set_cmd: arms tool_policy through Moodle's own admin/cli/cfg.php" {
  run moodle_policy_set_cmd "tool_policy"
  [ "$status" -eq 0 ]
  [ "$output" = "admin/cli/cfg.php --name=sitepolicyhandler --set=tool_policy" ]
}

@test "set_cmd: the rollback is --set= (empty value), never --unset" {
  # ss/ssc had a sitepolicyhandler ROW PRESENT with value '' before the change.
  # --unset deletes the row, which is a different state, so it is not offered.
  run moodle_policy_set_cmd ""
  [ "$status" -eq 0 ]
  [ "$output" = "admin/cli/cfg.php --name=sitepolicyhandler --set=" ]
  [[ "$output" != *"--unset"* ]]
}
