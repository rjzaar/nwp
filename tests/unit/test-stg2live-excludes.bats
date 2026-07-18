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

@test "the pre-rsync gitlab chown prunes oauth-keys (F1: never reassign the signing key)" {
  # The temporary 'chown -R gitlab:www-data' before rsync must NOT recurse into
  # oauth-keys/, or an aborted deploy leaves private.key unreadable by www-data
  # and SSO breaks. Enforce the find -path oauth-keys -prune form.
  run grep -E "find .*-path .*oauth-keys -prune -o -exec chown gitlab:www-data" "$CMD"
  [ "$status" -eq 0 ]
}

@test "no bare recursive 'chown -R gitlab:www-data' on the whole webroot remains" {
  # The old unguarded form is what created the F1 window; it must be gone.
  run grep -E "chown -R gitlab:www-data \\\$\{remote_path\}\"" "$CMD"
  [ "$status" -ne 0 ]
}
