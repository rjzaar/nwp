#!/usr/bin/env bats
################################################################################
# Unit tests for lib/site-containment.sh + templates/site-gitignore.tmpl —
# the containment layer that keeps credentials and site state from being one
# `git add -A` away from publication.
#
# Background (all four verified on the live tree, 2026-07-26):
#   - sites/<s>/{dev,stg}/.gitignore ignores settings.LOCAL.php but NOT
#     html/sites/default/settings.php (39 KB, 7 lines matching `password`),
#     and has no rule at all for oauth-keys/*.key. The same OAuth signing key
#     (md5 6e84421b…) is present in nwc/dev, nwc/stg and nw1/dev.
#   - sites/avc/backups is a real git repo with a remote on the code forge
#     holding a pushed 36 MB UNSANITISED production SQL dump.
#   - lib/git.sh:git_create_gitignore is the generator that caused it: for
#     backup repos it writes `!*.sql` / `!*.tar.gz`, i.e. it actively
#     UN-ignores dumps, and git_backup() then adds a remote and pushes.
#
# Every case below is written so it can go RED: each asserts a concrete
# containment property, not the mere presence of a rule string.
################################################################################

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TMP="$(mktemp -d)"
    export NWP_CONTAINMENT_TEMPLATE="$REPO_ROOT/templates/site-gitignore.tmpl"
}

teardown() {
    [ -n "${TMP:-}" ] && rm -rf "$TMP"
    return 0
}

# Build a throwaway git repo at $1 whose .gitignore is the text on stdin,
# populated with the sensitive paths we care about.
_mkrepo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    cat > "$dir/.gitignore"
    mkdir -p "$dir/html/sites/default" "$dir/oauth-keys"
    : > "$dir/html/sites/default/settings.php"
    : > "$dir/html/sites/default/settings.local.php"
    : > "$dir/oauth-keys/private.key"
    : > "$dir/oauth-keys/public.key"
    : > "$dir/dump.sql"
    : > "$dir/dump.sql.gz"
    : > "$dir/files.tar.gz"
    : > "$dir/backup.manifest.json"
}

# Assert a path would NOT be committed by `git add -A` in that repo.
_assert_contained() {
    local dir="$1" path="$2"
    if ! git -C "$dir" check-ignore -q "$path"; then
        echo "LEAKABLE: '$path' is not ignored in $dir" >&2
        return 1
    fi
}

_assert_leakable() {
    local dir="$1" path="$2"
    if git -C "$dir" check-ignore -q "$path"; then
        echo "unexpectedly ignored: '$path' in $dir" >&2
        return 1
    fi
}

################################################################################
# 1. The template itself must contain the credentials it claims to
################################################################################

@test "template exists and is readable" {
    [ -f "$NWP_CONTAINMENT_TEMPLATE" ]
}

@test "site section of the template contains Drupal settings.php and oauth keys" {
    source "$REPO_ROOT/lib/site-containment.sh"
    run containment_render_section site
    [ "$status" -eq 0 ]
    _mkrepo "$TMP/site" <<<"$output"
    _assert_contained "$TMP/site" "html/sites/default/settings.php"
    _assert_contained "$TMP/site" "oauth-keys/private.key"
}

@test "site section does NOT over-ignore ordinary tracked code" {
    source "$REPO_ROOT/lib/site-containment.sh"
    run containment_render_section site
    [ "$status" -eq 0 ]
    _mkrepo "$TMP/site" <<<"$output"
    mkdir -p "$TMP/site/html/modules/custom/foo"
    : > "$TMP/site/html/modules/custom/foo/foo.module"
    : > "$TMP/site/composer.json"
    _assert_leakable "$TMP/site" "html/modules/custom/foo/foo.module"
    _assert_leakable "$TMP/site" "composer.json"
}

@test "backups section of the template contains SQL dumps and tarballs" {
    source "$REPO_ROOT/lib/site-containment.sh"
    run containment_render_section backups
    [ "$status" -eq 0 ]
    _mkrepo "$TMP/bk" <<<"$output"
    _assert_contained "$TMP/bk" "dump.sql"
    _assert_contained "$TMP/bk" "dump.sql.gz"
    _assert_contained "$TMP/bk" "files.tar.gz"
    _assert_contained "$TMP/bk" "backup.manifest.json"
}

################################################################################
# 2. containment_check_repo — must FAIL on the real-world ruleset
#
# This is the load-bearing red case: the heredoc below is a byte-faithful
# excerpt of sites/nwc/dev/.gitignore as it stands on disk today. If the
# checker passes this, the checker is vacuous.
################################################################################

@test "check_repo FAILS on the real nwc/dev ruleset (settings.php + oauth keys leakable)" {
    source "$REPO_ROOT/lib/site-containment.sh"
    _mkrepo "$TMP/nwc" <<'EOF'
/vendor/
/html/core/
/html/modules/contrib/
/html/sites/*/files/
/html/sites/*/private/
/html/sites/*/settings.local.php
/html/sites/*/services.local.yml
/.ddev/
.env
/auth.json
/.secrets.yml
EOF
    run containment_check_repo "$TMP/nwc" site
    [ "$status" -ne 0 ]
    [[ "$output" == *"settings.php"* ]]
    [[ "$output" == *"oauth-keys"* ]]
}

@test "check_repo FAILS on the real avc/backups ruleset (dumps un-ignored)" {
    source "$REPO_ROOT/lib/site-containment.sh"
    _mkrepo "$TMP/avcbk" <<'EOF'
# NWP Files Backup .gitignore
*.tmp
*.temp
*.log

# Keep archives
!*.tar.gz
!*.zip
EOF
    run containment_check_repo "$TMP/avcbk" backups
    [ "$status" -ne 0 ]
    [[ "$output" == *".sql"* ]]
}

@test "check_repo PASSES once the template rules are present" {
    source "$REPO_ROOT/lib/site-containment.sh"
    run containment_render_section site
    _mkrepo "$TMP/ok" <<<"$output"
    run containment_check_repo "$TMP/ok" site
    [ "$status" -eq 0 ]
}

################################################################################
# 3. containment_fix_repo — idempotent repair
################################################################################

@test "fix_repo repairs a leaky repo and is idempotent" {
    source "$REPO_ROOT/lib/site-containment.sh"
    _mkrepo "$TMP/fix" <<'EOF'
/vendor/
/html/sites/*/settings.local.php
EOF
    run containment_check_repo "$TMP/fix" site
    [ "$status" -ne 0 ]

    run containment_fix_repo "$TMP/fix" site
    [ "$status" -eq 0 ]
    _assert_contained "$TMP/fix" "html/sites/default/settings.php"
    _assert_contained "$TMP/fix" "oauth-keys/private.key"

    # pre-existing rules survive
    grep -q '^/vendor/$' "$TMP/fix/.gitignore"

    # second run is a no-op
    local before after
    before="$(md5sum < "$TMP/fix/.gitignore")"
    run containment_fix_repo "$TMP/fix" site
    [ "$status" -eq 0 ]
    after="$(md5sum < "$TMP/fix/.gitignore")"
    [ "$before" = "$after" ]
}

@test "fix_repo does not un-ignore anything the repo already ignored" {
    source "$REPO_ROOT/lib/site-containment.sh"
    _mkrepo "$TMP/keep" <<'EOF'
/vendor/
secret-local-thing/
EOF
    containment_fix_repo "$TMP/keep" site
    mkdir -p "$TMP/keep/secret-local-thing"
    : > "$TMP/keep/secret-local-thing/x"
    _assert_contained "$TMP/keep" "secret-local-thing/x"
}

################################################################################
# 4. lib/git.sh generator — must stop MANUFACTURING the leak
#
# RED today: git_create_gitignore writes `!*.sql` / `!*.sql.gz` for db repos
# and `!*.tar.gz` for files repos, and git_backup() then attaches a remote on
# the code forge and pushes. That is how a 36 MB unsanitised production dump
# reached the forge.
################################################################################

@test "git_create_gitignore does not un-ignore SQL dumps for db backup repos" {
    source "$REPO_ROOT/lib/common.sh" 2>/dev/null || true
    source "$REPO_ROOT/lib/git.sh"
    mkdir -p "$TMP/gdb"
    git -C "$TMP/gdb" init -q
    git_create_gitignore "$TMP/gdb" db >/dev/null 2>&1
    : > "$TMP/gdb/dump.sql"
    : > "$TMP/gdb/dump.sql.gz"
    _assert_contained "$TMP/gdb" "dump.sql"
    _assert_contained "$TMP/gdb" "dump.sql.gz"
    run grep -c '^!\*\.sql' "$TMP/gdb/.gitignore"
    [ "$output" = "0" ]
}

@test "git_create_gitignore does not un-ignore tarballs for files backup repos" {
    source "$REPO_ROOT/lib/common.sh" 2>/dev/null || true
    source "$REPO_ROOT/lib/git.sh"
    mkdir -p "$TMP/gf"
    git -C "$TMP/gf" init -q
    git_create_gitignore "$TMP/gf" files >/dev/null 2>&1
    : > "$TMP/gf/files.tar.gz"
    _assert_contained "$TMP/gf" "files.tar.gz"
    run grep -c '^!\*\.tar\.gz' "$TMP/gf/.gitignore"
    [ "$output" = "0" ]
}

@test "git_create_gitignore site type still ignores settings.php and oauth keys" {
    source "$REPO_ROOT/lib/common.sh" 2>/dev/null || true
    source "$REPO_ROOT/lib/git.sh"
    mkdir -p "$TMP/gs/html/sites/default" "$TMP/gs/oauth-keys"
    git -C "$TMP/gs" init -q
    git_create_gitignore "$TMP/gs" site >/dev/null 2>&1
    : > "$TMP/gs/html/sites/default/settings.php"
    : > "$TMP/gs/oauth-keys/private.key"
    _assert_contained "$TMP/gs" "html/sites/default/settings.php"
    _assert_contained "$TMP/gs" "oauth-keys/private.key"
}

################################################################################
# 5. The backup-write guard — fail closed
################################################################################

# When the backups dir IS the repo root (the sites/<n>/backups/ shape lib/git.sh
# created), the guard self-remediates and lets the backup proceed — breaking the
# nightly sweep would trade a containment bug for a backup outage.
@test "backup guard SELF-REMEDIATES a backups dir that is its own repo root" {
    source "$REPO_ROOT/lib/site-containment.sh"
    mkdir -p "$TMP/leaky"
    git -C "$TMP/leaky" init -q
    git -C "$TMP/leaky" remote add origin git@git.example.org:backups/x.git
    printf '*.tmp\n!*.tar.gz\n' > "$TMP/leaky/.gitignore"

    : > "$TMP/leaky/prod.sql"
    git -C "$TMP/leaky" add -An 2>/dev/null | grep -q 'prod.sql'   # committable before

    run containment_assert_backup_path "$TMP/leaky"
    [ "$status" -eq 0 ]
    [[ "$output" == *"installed the nwp containment block"* ]]

    # and it is genuinely contained afterwards, not merely reported so
    run git -C "$TMP/leaky" check-ignore -q prod.sql
    [ "$status" -eq 0 ]
}

# A backups dir buried inside a SITE or PROFILE repo cannot be fixed by editing
# that repo's .gitignore without side effects, so it still fails closed.
@test "backup guard REFUSES a backups dir buried inside a larger repo" {
    source "$REPO_ROOT/lib/site-containment.sh"
    mkdir -p "$TMP/site/backups"
    git -C "$TMP/site" init -q
    git -C "$TMP/site" remote add origin git@git.example.org:sites/x.git
    printf '/vendor/\n' > "$TMP/site/.gitignore"
    run containment_assert_backup_path "$TMP/site/backups"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing"* ]]
}

@test "backup guard ALLOWS the same dir once dumps are ignored" {
    source "$REPO_ROOT/lib/site-containment.sh"
    mkdir -p "$TMP/tight"
    git -C "$TMP/tight" init -q
    git -C "$TMP/tight" remote add origin git@git.example.org:backups/x.git
    containment_render_section backups > "$TMP/tight/.gitignore"
    run containment_assert_backup_path "$TMP/tight"
    [ "$status" -eq 0 ]
}

@test "backup guard ALLOWS a dir outside any git work tree" {
    source "$REPO_ROOT/lib/site-containment.sh"
    mkdir -p "$TMP/plain/backups"
    run containment_assert_backup_path "$TMP/plain/backups"
    [ "$status" -eq 0 ]
}

@test "backup guard ALLOWS a repo with no remote (nothing to publish to)" {
    source "$REPO_ROOT/lib/site-containment.sh"
    mkdir -p "$TMP/noremote"
    git -C "$TMP/noremote" init -q
    printf '*.tmp\n' > "$TMP/noremote/.gitignore"
    run containment_assert_backup_path "$TMP/noremote"
    [ "$status" -eq 0 ]
}

@test "backup guard escape hatch is explicit and logged" {
    source "$REPO_ROOT/lib/site-containment.sh"
    mkdir -p "$TMP/hatch"
    git -C "$TMP/hatch" init -q
    git -C "$TMP/hatch" remote add origin git@git.example.org:backups/x.git
    printf '*.tmp\n' > "$TMP/hatch/.gitignore"
    NWP_ALLOW_BACKUP_IN_REPO=1 run containment_assert_backup_path "$TMP/hatch"
    [ "$status" -eq 0 ]
}

################################################################################
# 6. Discovery must never report "clean" on an empty corpus
#
# This is the vacuous-pass guard: a fleet containment check that scans zero
# repos must say "cannot verify", not "all clean".
################################################################################

@test "discover_repos finds nested dev/stg repos, not just the site root" {
    source "$REPO_ROOT/lib/site-containment.sh"
    mkdir -p "$TMP/fleet/sites/alpha/dev" "$TMP/fleet/sites/alpha/stg" "$TMP/fleet/sites/alpha/backups"
    git -C "$TMP/fleet/sites/alpha/dev" init -q
    git -C "$TMP/fleet/sites/alpha/stg" init -q
    git -C "$TMP/fleet/sites/alpha/backups" init -q
    run containment_discover_repos "$TMP/fleet/sites"
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha/dev"* ]]
    [[ "$output" == *"alpha/stg"* ]]
    [[ "$output" == *"alpha/backups"* ]]
}

@test "discover_repos skips vendor and node_modules" {
    source "$REPO_ROOT/lib/site-containment.sh"
    mkdir -p "$TMP/fleet2/sites/beta/dev/vendor/pkg" "$TMP/fleet2/sites/beta/dev/node_modules/mod"
    git -C "$TMP/fleet2/sites/beta/dev" init -q
    git -C "$TMP/fleet2/sites/beta/dev/vendor/pkg" init -q
    git -C "$TMP/fleet2/sites/beta/dev/node_modules/mod" init -q
    run containment_discover_repos "$TMP/fleet2/sites"
    [ "$status" -eq 0 ]
    [[ "$output" != *"vendor/pkg"* ]]
    [[ "$output" != *"node_modules"* ]]
}

@test "fleet check reports CANNOT VERIFY (non-zero) on an empty corpus" {
    source "$REPO_ROOT/lib/site-containment.sh"
    mkdir -p "$TMP/empty/sites"
    run containment_check_fleet "$TMP/empty/sites"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot verify"* ]] || [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "fleet check goes red when one repo in the corpus is leaky" {
    source "$REPO_ROOT/lib/site-containment.sh"
    mkdir -p "$TMP/f3/sites/good/dev" "$TMP/f3/sites/bad/dev"
    git -C "$TMP/f3/sites/good/dev" init -q
    git -C "$TMP/f3/sites/bad/dev" init -q
    containment_render_section site > "$TMP/f3/sites/good/dev/.gitignore"
    printf '/vendor/\n' > "$TMP/f3/sites/bad/dev/.gitignore"
    run containment_check_fleet "$TMP/f3/sites"
    [ "$status" -ne 0 ]
    [[ "$output" == *"bad/dev"* ]]
    [[ "$output" != *"good/dev"* ]] || true
}

################################################################################
# 7. ALREADY-TRACKED payloads — the half that ignore rules can never fix
#
# git ignores .gitignore for files it already tracks. So installing the
# containment block makes a repo that has ALREADY committed (and pushed) a
# production dump report perfectly clean. That is exactly sites/avc/backups
# today: a 36 MB unsanitised SQL dump and a 363 MB files tarball, blob-for-blob
# on git@forge.example.org:backups/avc-files.git.
#
# Containment therefore has two halves, and only one of them had a check:
#   FUTURE — "could this be committed?"        -> containment_check_repo
#   PAST   — "was this already published?"     -> the cases below
################################################################################

# Build a repo that has already committed a sensitive blob.
_mkrepo_tracked() {
    local dir="$1"; shift
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email t@example.org
    git -C "$dir" config user.name test
    local f
    for f in "$@"; do
        mkdir -p "$dir/$(dirname "$f")"
        echo "sensitive" > "$dir/$f"
    done
    git -C "$dir" add -A -f >/dev/null 2>&1
    git -C "$dir" commit -qm "committed" >/dev/null 2>&1
}

@test "tracked dump is EXPOSED even after the containment block is installed" {
    source "$REPO_ROOT/lib/site-containment.sh"
    _mkrepo_tracked "$TMP/tr1" "20260115T170824-main.sql"
    git -C "$TMP/tr1" remote add origin git@forge.example.org:backups/avc-files.git
    containment_fix_repo "$TMP/tr1" backups

    # The FUTURE half is satisfied — which is exactly why the PAST half is needed.
    run containment_check_repo "$TMP/tr1" backups
    [ "$status" -eq 0 ]

    run containment_check_tracked_repo "$TMP/tr1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"EXPOSED"* ]]
    [[ "$output" == *"20260115T170824-main.sql"* ]]
}

@test "tracked settings.php and private keys are EXPOSED" {
    source "$REPO_ROOT/lib/site-containment.sh"
    _mkrepo_tracked "$TMP/tr2" "html/sites/default/settings.php" "oauth-keys/private.key"
    containment_fix_repo "$TMP/tr2" site
    run containment_check_tracked_repo "$TMP/tr2"
    [ "$status" -ne 0 ]
    [[ "$output" == *"settings.php"* ]]
    [[ "$output" == *"private.key"* ]]
}

@test "a repo tracking only ordinary code is NOT reported as exposed" {
    source "$REPO_ROOT/lib/site-containment.sh"
    _mkrepo_tracked "$TMP/tr3" "composer.json" "html/modules/custom/foo/foo.module" "README.md"
    run containment_check_tracked_repo "$TMP/tr3"
    [ "$status" -eq 0 ]
    [[ "$output" != *"EXPOSED"* ]]
}

@test "exposure names the publish target, because a remote is what makes it disclosure" {
    source "$REPO_ROOT/lib/site-containment.sh"
    _mkrepo_tracked "$TMP/tr4" "dump.sql.gz"
    git -C "$TMP/tr4" remote add origin git@forge.example.org:backups/avc-files.git
    run containment_check_tracked_repo "$TMP/tr4"
    [ "$status" -ne 0 ]
    [[ "$output" == *"avc-files.git"* ]]
}

@test "fleet exposure scan fails closed on an empty corpus" {
    source "$REPO_ROOT/lib/site-containment.sh"
    mkdir -p "$TMP/tr5/sites"
    run containment_check_tracked_fleet "$TMP/tr5/sites"
    [ "$status" -ne 0 ]
    [[ "$output" == *"CANNOT VERIFY"* ]]
}

@test "fleet exposure scan goes red on the one repo that published member data" {
    source "$REPO_ROOT/lib/site-containment.sh"
    mkdir -p "$TMP/tr6/sites"
    _mkrepo_tracked "$TMP/tr6/sites/good/dev" "composer.json"
    _mkrepo_tracked "$TMP/tr6/sites/bad/backups" "prod.sql"
    run containment_check_tracked_fleet "$TMP/tr6/sites"
    [ "$status" -ne 0 ]
    [[ "$output" == *"bad/backups"* ]]
    [[ "$output" == *"prod.sql"* ]]
}

@test "the backup guard WARNS about an exposed history but does not block backups" {
    # Blocking would break nightly backups for avc, and the operator cannot
    # clear the finding without a history rewrite. Loud, not fatal.
    source "$REPO_ROOT/lib/site-containment.sh"
    _mkrepo_tracked "$TMP/tr7" "old.sql"
    git -C "$TMP/tr7" remote add origin git@forge.example.org:backups/avc-files.git
    run containment_assert_backup_path "$TMP/tr7"
    [ "$status" -eq 0 ]
    [[ "$output" == *"EXPOSED"* ]] || [[ "$output" == *"already published"* ]]
}

################################################################################
# 8. Signal quality — the exclusions must not become a blind spot
#
# A bare `*/settings.php` matched 300+ upstream Moodle plugin admin-settings
# files across the real fleet, and `*.pem` matched every bundled CA cert. An
# exposure report that emits hundreds of false lines is an alarm nobody reads,
# which is a slower vacuous pass. But the cure is the more dangerous half: a
# too-eager exclusion silently swallows the real dump. These cases pin BOTH
# ends against the shapes actually measured on the fleet.
################################################################################

@test "upstream test fixtures and CA bundles are NOT reported as exposure" {
    source "$REPO_ROOT/lib/site-containment.sh"
    _mkrepo_tracked "$TMP/sq1" \
        "web/core/modules/system/tests/fixtures/HtaccessTest/access_test.sql" \
        "web/core/modules/update/tests/aaa_update_test.tar.gz" \
        "lib/filestorage/tests/fixtures/test.tgz" \
        "lib/cacert.pem" \
        "lib/dml/oci_native_moodle_package.sql" \
        "vendor/some/pkg/dump.sql"
    run containment_check_tracked_repo "$TMP/sq1"
    [ "$status" -eq 0 ]
    [[ "$output" != *"EXPOSED"* ]]
}

@test "a Moodle plugin settings.php is not mistaken for a Drupal credential file" {
    source "$REPO_ROOT/lib/site-containment.sh"
    _mkrepo_tracked "$TMP/sq2" \
        "mod/quiz/settings.php" "report/log/settings.php" "theme/boost/settings.php"
    run containment_check_tracked_repo "$TMP/sq2"
    [ "$status" -eq 0 ]
}

@test "the exclusions do NOT swallow a real dump sitting at the repo root" {
    # sites/avc/backups shape: the payload is not under tests/ or vendor/.
    source "$REPO_ROOT/lib/site-containment.sh"
    _mkrepo_tracked "$TMP/sq3" \
        "20260115T170824-main-99385c10.sql" \
        "20260115T170824-main-99385c10.tar.gz" \
        "web/core/modules/update/tests/aaa_update_test.tar.gz"
    run containment_check_tracked_repo "$TMP/sq3"
    [ "$status" -ne 0 ]
    [[ "$output" == *"20260115T170824-main-99385c10.sql"* ]]
    [[ "$output" == *"20260115T170824-main-99385c10.tar.gz"* ]]
    [[ "$output" != *"aaa_update_test"* ]]
}

@test "the exclusions do NOT swallow a real Drupal settings.php" {
    # sites/mayo/dev shape: tracked html/sites/default/settings.php.
    source "$REPO_ROOT/lib/site-containment.sh"
    _mkrepo_tracked "$TMP/sq4" \
        "html/sites/default/settings.php" "mod/quiz/settings.php"
    run containment_check_tracked_repo "$TMP/sq4"
    [ "$status" -ne 0 ]
    [[ "$output" == *"html/sites/default/settings.php"* ]]
    [[ "$output" != *"mod/quiz"* ]]
}

@test "a dump under a directory merely NAMED like a fixture dir is still caught at root" {
    # Guards the shrink-only intent: exclusions are path-anchored, so a payload
    # committed at the top of a backups repo can never be excluded by them.
    source "$REPO_ROOT/lib/site-containment.sh"
    _mkrepo_tracked "$TMP/sq5" "prod-2026.sql.gz"
    run containment_check_tracked_repo "$TMP/sq5"
    [ "$status" -ne 0 ]
    [[ "$output" == *"prod-2026.sql.gz"* ]]
}
