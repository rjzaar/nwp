#!/usr/bin/env bats
# stg2live's rsync runs with --delete against the live webroot. Live-only
# runtime state generated on the host (oauth-keys/, auth.json) never exists in
# staging, so it MUST be in the exclude list or --delete removes it. Deleting
# oauth-keys/ breaks all OAuth/OIDC (SSO) logins on live. Regression guard.

CMD="${BATS_TEST_DIRNAME}/../../scripts/commands/stg2live.sh"

@test "stg2live excludes oauth-keys from the --delete rsync" {
  run grep -E '^\s*"--exclude=oauth-keys"' "$CMD"
  [ "$status" -eq 0 ]
}

@test "stg2live excludes auth.json from the --delete rsync" {
  run grep -E '^\s*"--exclude=auth.json"' "$CMD"
  [ "$status" -eq 0 ]
}

@test "the exclude additions sit inside the excludes array (before the rsync)" {
  # oauth-keys exclude must appear after the excludes=( opener and before the
  # rsync ... --delete invocation, i.e. it is actually wired into the array.
  run bash -c "awk '/local excludes=\(/{a=NR} /--exclude=oauth-keys/{o=NR} /rsync .*--delete/{r=NR} END{print (a && o && r && a<o && o<r) ? \"ok\" : \"bad\"}' '$CMD'"
  [ "$output" = "ok" ]
}
