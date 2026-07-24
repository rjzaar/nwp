#!/usr/bin/env bats
# nwp/ops#68 — prod2stg must target the resolved F17/F23 staging project, not the
# flat v1 `sites/$SITENAME` path.
#
# BUG: `sanitize_staging_db "$SITENAME"` (bare name) made the sanitizer cd to the
# v2 PARENT dir (sites/<name>/, no DDEV). Post-hardening that fails closed and
# aborts the prod pull; pre-hardening it silently no-op'd, leaving RAW prod PII in
# stg. Every ddev step (import/updatedb/cim/cr/describe) had the same flat-path
# assumption. Fix: resolve STG_DIR once (v2: sites/<name>/stg, v1: sites/<name>-stg)
# and pass STG_REL (`<name>/stg`) — the segment the sanitizer's `cd "sites/$x"` needs.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/commands/prod2stg.sh"

@test "prod2stg resolves the staging project via resolve_project" {
  grep -Eq 'STG_DIR=\$\(resolve_project "\$BASE_NAME" "stg"\)' "$SCRIPT"
}

@test "prod2stg derives STG_REL as the sites/ segment for the sanitizer" {
  grep -Eq 'STG_REL="\$\{STG_DIR#"\$PROJECT_ROOT"/sites/\}"' "$SCRIPT"
}

@test "prod2stg passes the resolved STG_REL to sanitize_staging_db (not a bare name)" {
  grep -Eq 'sanitize_staging_db "\$STG_REL"' "$SCRIPT"
  # the bare-name call must be gone from CODE (ignore explanatory comments)
  run bash -c "grep -vE '^[[:space:]]*#' '$SCRIPT' | grep -Eq 'sanitize_staging_db \"\\\$SITENAME\"'"
  [ "$status" -ne 0 ]
}

@test "prod2stg no longer cd's ddev into the flat v1 site path" {
  run grep -Eq 'cd "(\$PROJECT_ROOT/)?sites/\$SITENAME"' "$SCRIPT"
  [ "$status" -ne 0 ]   # all ddev cwd's must go through \$STG_DIR
}

@test "prod2stg rsync destination is the resolved staging dir" {
  grep -Eq '"\$STG_DIR/"' "$SCRIPT"
}

@test "prod2stg fails closed when the staging dir cannot be resolved" {
  grep -Eq 'Cannot resolve staging directory' "$SCRIPT"
}
