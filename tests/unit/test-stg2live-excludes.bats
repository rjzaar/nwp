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

@test "the pre-rsync gitlab chown prunes EVERY simple_oauth key dir (F1: never reassign the signing key)" {
  # The temporary 'chown -R gitlab:www-data' before rsync must NOT recurse into
  # the simple_oauth key directory, or an aborted deploy leaves private.key
  # unreadable by www-data and SSO breaks.
  #
  # This used to enforce the literal `-path .../oauth-keys -prune`. That pinned
  # ONE site's name for the directory: simple_oauth stores the path in config
  # and the fleet differs — nwc uses oauth-keys/, nwd uses keys/ — so nwd got
  # none of this protection and its deploy would have handed private.key to the
  # gitlab user (found 2026-08-01 deploying live nwd). The guarantee is
  # unchanged; what is asserted is now the general form, which is strictly
  # stronger: the prune is built from every directory resolved for the site.
  # Fixed-string matches: these assert exact shell text, and escaping it as a
  # regex twice over is how a guard ends up testing nothing.
  run grep -F 'for _kd in "${key_dirs[@]}"' "$CMD"
  [ "$status" -eq 0 ]
  run grep -F '_prune+=" -path ${remote_path}/${_kd} -prune -o"' "$CMD"
  [ "$status" -eq 0 ]
  run grep -F 'find ${remote_path}${_prune} -exec chown gitlab:www-data' "$CMD"
  [ "$status" -eq 0 ]
}

@test "the key directory is resolved from simple_oauth, never assumed" {
  # The root cause of the above: a hardcoded directory name.
  run grep -E "drush cget simple_oauth.settings private_key" "$CMD"
  [ "$status" -eq 0 ]
}

@test "no bare recursive 'chown -R gitlab:www-data' on the whole webroot remains" {
  # The old unguarded form is what created the F1 window; it must be gone.
  run grep -E "chown -R gitlab:www-data \\\$\{remote_path\}\"" "$CMD"
  [ "$status" -ne 0 ]
}
