#!/usr/bin/env bats
# nwp/ops#47 — lib/impact.sh: fate-manifest renderer + tiered confirmation.

setup() {
  source "${BATS_TEST_DIRNAME}/../../lib/impact.sh"
  impact_reset
}

@test "render prints only populated sections" {
  impact_delete "Files" "/x (1G)"
  run impact_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"WILL BE PERMANENTLY DELETED:"* ]]
  [[ "$output" == *"Files:"*"/x (1G)"* ]]
  [[ "$output" != *"WILL BE OVERWRITTEN"* ]]
  [[ "$output" != *"ARCHIVED"* ]]
  [[ "$output" != *"DATA-LOSS WARNINGS"* ]]
  [[ "$output" != *"NOT AFFECTED"* ]]
}

@test "all fates render under their own headings" {
  impact_delete    "DDEV" "x-dev — volumes: x-dev-mariadb"
  impact_overwrite "Database" "current DB replaced by backup b1"
  impact_archive   "Backups" "3 file(s) → sitebackups/x/"
  impact_keep      "Live server stays"
  impact_warn      "git repo dev: 2 unpushed commit(s)"
  run impact_render
  [[ "$output" == *"WILL BE PERMANENTLY DELETED:"* ]]
  [[ "$output" == *"WILL BE OVERWRITTEN:"* ]]
  [[ "$output" == *"ARCHIVED (kept, relocated):"* ]]
  [[ "$output" == *"DATA-LOSS WARNINGS:"* ]]
  [[ "$output" == *"⚠"*"unpushed"* ]]
  [[ "$output" == *"NOT AFFECTED:"* ]]
  [[ "$output" == *"• Live server stays"* ]]
}

@test "impact_reset clears a previous manifest" {
  impact_delete "Files" "/x"
  impact_reset
  run impact_render
  [[ "$output" != *"WILL BE PERMANENTLY DELETED"* ]]
}

@test "confirm standard: auto_confirm=true proceeds without prompt" {
  run impact_confirm standard "delete site 'x'" true
  [ "$status" -eq 0 ]
}

@test "confirm typed: auto_confirm=true proceeds without prompt" {
  run impact_confirm typed "x" true
  [ "$status" -eq 0 ]
}

@test "confirm fails closed with no TTY and no -y" {
  run bash -c 'source "'"${BATS_TEST_DIRNAME}"'/../../lib/impact.sh"; impact_confirm standard "delete x" false </dev/null'
  [ "$status" -ne 0 ]
  [[ "$output" == *"aborting"* ]]
}

@test "confirm standard: y proceeds, n aborts (scripted TTY)" {
  command -v script >/dev/null || skip "script(1) unavailable"
  run script -qec 'bash -c "source '"${BATS_TEST_DIRNAME}"'/../../lib/impact.sh; impact_confirm standard \"delete x\" false && echo PROCEEDED || echo ABORTED"' /dev/null <<< "y"
  [[ "$output" == *"PROCEEDED"* ]]
  run script -qec 'bash -c "source '"${BATS_TEST_DIRNAME}"'/../../lib/impact.sh; impact_confirm standard \"delete x\" false && echo PROCEEDED || echo ABORTED"' /dev/null <<< "n"
  [[ "$output" == *"ABORTED"* ]]
}

@test "confirm typed: exact name proceeds, mismatch aborts" {
  command -v script >/dev/null || skip "script(1) unavailable"
  run script -qec 'bash -c "source '"${BATS_TEST_DIRNAME}"'/../../lib/impact.sh; impact_confirm typed avc false && echo PROCEEDED || echo ABORTED"' /dev/null <<< "avc"
  [[ "$output" == *"PROCEEDED"* ]]
  run script -qec 'bash -c "source '"${BATS_TEST_DIRNAME}"'/../../lib/impact.sh; impact_confirm typed avc false && echo PROCEEDED || echo ABORTED"' /dev/null <<< "acv"
  [[ "$output" == *"ABORTED"* ]]
}
