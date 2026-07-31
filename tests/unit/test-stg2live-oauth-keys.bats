#!/usr/bin/env bats
# stg2live must never touch the simple_oauth signing keys — whatever they are called.
#
# THE DEFECT THIS GUARDS (found 2026-08-01 deploying live nwd):
# stg2live protected a directory literally named "oauth-keys" in two places — an
# rsync --exclude, and a `find … -path …/oauth-keys -prune` that keeps the
# pre-rsync chown away from it. The code comment is emphatic about why:
# private.key is 0600 www-data, so re-owning it to gitlab means www-data can no
# longer read it and EVERY OIDC/SSO login breaks.
#
# But "oauth-keys" is only the name ONE site uses. simple_oauth stores the path
# in config, and the fleet genuinely differs:
#     nwc -> /var/www/nwc/oauth-keys/private.key
#     nwd -> /var/www/nwd/keys/private.key
# So nwd got NONE of that protection: the deploy first failed outright (rsync
# could not opendir a 0700 www-data directory as the gitlab user), and had it
# got past that, the chown would have handed nwd's private.key to gitlab and
# taken down SSO for the demo pair — the exact outcome the comment describes.
#
# The fix asks Drupal where its keys are instead of assuming a name. These tests
# pin the three properties that matter: it asks, it protects what it is told,
# and when it cannot ask it protects EVERY name it knows rather than guessing.

setup() {
  REPO_ROOT="$( cd "${BATS_TEST_DIRNAME}/../.." && pwd )"
  S2L="${REPO_ROOT}/scripts/commands/stg2live.sh"
}

@test "the key directory is READ FROM simple_oauth, not hardcoded" {
  run grep -c 'drush cget simple_oauth.settings private_key' "$S2L"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "when simple_oauth cannot be read it protects BOTH known names (fail-safe)" {
  # An over-broad exclude leaves a stale directory behind. An under-broad one
  # deletes live signing keys. These are not symmetric, so the fallback must be
  # the superset.
  run bash -c "sed -n '/key_dirs=()/,/print_info \"\$key_dir_msg\"/p' '$S2L'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'key_dirs+=("oauth-keys" "keys")'* ]]
  [[ "$output" == *"fail-safe"* ]]
}

@test "the resolved key directory is added to the rsync excludes" {
  run bash -c "sed -n '/key_dirs=()/,/print_info \"\$key_dir_msg\"/p' '$S2L'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'excludes+=("--exclude=${_kd}")'* ]]
}

@test "the chown prune covers EVERY resolved key dir, not just the literal oauth-keys" {
  # This is the half that breaks SSO rather than merely failing the deploy: the
  # rsync exclude keeps the keys from being deleted, but only the prune keeps
  # them owned by www-data.
  run bash -c "sed -n '/Prune EVERY simple_oauth key directory/,/chown gitlab:www-data/p' '$S2L'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'for _kd in "${key_dirs[@]}"'* ]]
  [[ "$output" == *'-prune -o'* ]]
  # The old single-name form must be gone.
  run grep -c -- '-path ${remote_path}/oauth-keys -prune -o -exec' "$S2L"
  [ "$output" = "0" ]
}

@test "auth.json and the files/private trees are still excluded (no regression)" {
  for pat in '--exclude=auth.json' '--exclude=private' '--exclude=node_modules'; do
    run grep -c -- "$pat" "$S2L"
    [ "$output" -ge 1 ]
  done
}
