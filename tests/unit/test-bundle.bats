#!/usr/bin/env bats
################################################################################
# Unit tests for lib/bundle-build.sh and lib/bundle-verify.sh
#
# Exercises the F28 Phase 2 contract: build a bundle from a fixture tree,
# verify it round-trips, tamper with a file, and assert verification fails.
#
# minisign is optional for these tests — we run with BUNDLE_NO_SIGN=1 and
# BUNDLE_VERIFY_NO_SIG=1 so the manifest/sha256 path is exercised even on
# hosts without minisign installed. A separate test skips unless minisign
# is available.
################################################################################

load ../helpers/test-helpers

setup() {
    test_setup
    export NWP_ROOT="${PROJECT_ROOT}"
    # shellcheck source=/dev/null
    source "${PROJECT_ROOT}/lib/bundle-build.sh"
    # shellcheck source=/dev/null
    source "${PROJECT_ROOT}/lib/bundle-verify.sh"

    # Build a minimal fixture site tree
    export FIXTURE_SRC="${TEST_TEMP_DIR}/fixture-site"
    export FIXTURE_PAYLOAD="${FIXTURE_SRC}/payload"
    export FIXTURE_SCRIPTS="${FIXTURE_SRC}/scripts"
    mkdir -p "$FIXTURE_PAYLOAD/code" "$FIXTURE_PAYLOAD/fixtures" \
             "$FIXTURE_PAYLOAD/migrations" "$FIXTURE_SCRIPTS"
    echo "hello from test" > "$FIXTURE_PAYLOAD/code/index.php"
    echo "<?php return ['drupal'];" > "$FIXTURE_PAYLOAD/code/composer.json"
    echo "2026_04_12_0001_init.sql" > "$FIXTURE_PAYLOAD/migrations/0001-init.sql"
    printf '#!/bin/bash\necho pre\n' > "$FIXTURE_SCRIPTS/pre-deploy.sh"
    printf '#!/bin/bash\necho apply\n' > "$FIXTURE_SCRIPTS/apply.sh"
    printf '#!/bin/bash\necho post\n' > "$FIXTURE_SCRIPTS/post-deploy.sh"
    chmod +x "$FIXTURE_SCRIPTS/"*.sh

    export BUNDLE_OUTPUT_DIR="${TEST_TEMP_DIR}/dist"
    export BUNDLE_NO_SIGN=1
    export BUNDLE_VERIFY_NO_SIG=1
    export BUNDLE_TARGETS="mayo1 mayo2"
}

teardown() {
    test_teardown
}

################################################################################
# bundle_tree_sha256
################################################################################

@test "bundle_tree_sha256: same tree yields same hash" {
    mkdir -p "${TEST_TEMP_DIR}/t1"
    echo "a" > "${TEST_TEMP_DIR}/t1/a.txt"
    echo "b" > "${TEST_TEMP_DIR}/t1/b.txt"
    h1=$(bundle_tree_sha256 "${TEST_TEMP_DIR}/t1")
    h2=$(bundle_tree_sha256 "${TEST_TEMP_DIR}/t1")
    [ "$h1" = "$h2" ]
    [ -n "$h1" ]
}

@test "bundle_tree_sha256: mutation changes hash" {
    mkdir -p "${TEST_TEMP_DIR}/t1"
    echo "a" > "${TEST_TEMP_DIR}/t1/a.txt"
    h1=$(bundle_tree_sha256 "${TEST_TEMP_DIR}/t1")
    echo "z" > "${TEST_TEMP_DIR}/t1/a.txt"
    h2=$(bundle_tree_sha256 "${TEST_TEMP_DIR}/t1")
    [ "$h1" != "$h2" ]
}

@test "bundle_tree_sha256: two identical trees in different dirs match" {
    mkdir -p "${TEST_TEMP_DIR}/t1" "${TEST_TEMP_DIR}/t2"
    echo "a" > "${TEST_TEMP_DIR}/t1/a.txt"
    echo "a" > "${TEST_TEMP_DIR}/t2/a.txt"
    h1=$(bundle_tree_sha256 "${TEST_TEMP_DIR}/t1")
    h2=$(bundle_tree_sha256 "${TEST_TEMP_DIR}/t2")
    [ "$h1" = "$h2" ]
}

################################################################################
# bundle_build
################################################################################

@test "bundle_build: rejects missing site name" {
    run bundle_build "" "$FIXTURE_PAYLOAD" "$FIXTURE_SCRIPTS"
    [ "$status" -ne 0 ]
    [[ "$output" == *"site name required"* ]]
}

@test "bundle_build: rejects payload without code/" {
    mkdir -p "${TEST_TEMP_DIR}/bad-payload"
    run bundle_build "mayo" "${TEST_TEMP_DIR}/bad-payload" "$FIXTURE_SCRIPTS"
    [ "$status" -ne 0 ]
    [[ "$output" == *"code/ subdirectory"* ]]
}

@test "bundle_build: rejects scripts without apply.sh" {
    mkdir -p "${TEST_TEMP_DIR}/bad-scripts"
    run bundle_build "mayo" "$FIXTURE_PAYLOAD" "${TEST_TEMP_DIR}/bad-scripts"
    [ "$status" -ne 0 ]
    [[ "$output" == *"apply.sh"* ]]
}

@test "bundle_build: produces a tarball at the expected path" {
    run bundle_build "mayo" "$FIXTURE_PAYLOAD" "$FIXTURE_SCRIPTS"
    [ "$status" -eq 0 ]
    [ -f "$output" ]
    [[ "$output" == *"nwp-bundle-mayo-"* ]]
    [[ "$output" == *".tar.gz" ]]
}

@test "bundle_build: manifest carries all required fields" {
    bundle_path=$(bundle_build "mayo" "$FIXTURE_PAYLOAD" "$FIXTURE_SCRIPTS")
    [ -f "$bundle_path" ]

    # Extract and inspect
    stage="${TEST_TEMP_DIR}/extract"
    mkdir -p "$stage"
    tar -C "$stage" -xzf "$bundle_path"
    manifest=$(find "$stage" -name manifest.json | head -1)
    [ -f "$manifest" ]

    # Required fields present
    for field in schema_version nwp_version site git_commit git_branch \
                 built_at built_by signing_key_fingerprint targets \
                 sha256_payload sha256_scripts dependencies; do
        run jq -e "has(\"$field\")" "$manifest"
        [ "$status" -eq 0 ]
    done

    # Site and targets threaded through
    [ "$(jq -r .site "$manifest")" = "mayo" ]
    [ "$(jq -r '.targets | length' "$manifest")" = "2" ]
    [ "$(jq -r '.targets[0]' "$manifest")" = "mayo1" ]
}

@test "bundle_build: creates pre/post-deploy stubs when not provided" {
    rm "$FIXTURE_SCRIPTS/pre-deploy.sh" "$FIXTURE_SCRIPTS/post-deploy.sh"
    bundle_path=$(bundle_build "mayo" "$FIXTURE_PAYLOAD" "$FIXTURE_SCRIPTS")
    stage="${TEST_TEMP_DIR}/extract"
    mkdir -p "$stage"
    tar -C "$stage" -xzf "$bundle_path"
    pre=$(find "$stage" -name pre-deploy.sh | head -1)
    post=$(find "$stage" -name post-deploy.sh | head -1)
    [ -f "$pre" ]
    [ -f "$post" ]
    [[ "$(cat "$pre")" == *"no-op"* ]]
    [[ "$(cat "$post")" == *"no-op"* ]]
}

################################################################################
# bundle_verify (roundtrip and tamper detection)
################################################################################

@test "bundle_verify: clean bundle verifies successfully" {
    bundle_path=$(bundle_build "mayo" "$FIXTURE_PAYLOAD" "$FIXTURE_SCRIPTS")
    run bundle_verify "$bundle_path"
    [ "$status" -eq 0 ]
}

@test "bundle_verify: nonexistent bundle fails clean" {
    run bundle_verify "/nonexistent/bundle.tar.gz"
    [ "$status" -ne 0 ]
    [[ "$output" == *"file-check"* ]]
}

@test "bundle_verify: tampered payload fails sha256 check" {
    bundle_path=$(bundle_build "mayo" "$FIXTURE_PAYLOAD" "$FIXTURE_SCRIPTS")

    # Tamper: unpack, modify a payload file, re-pack with the SAME
    # top-level directory name, re-compress. The manifest's
    # sha256_payload must no longer match.
    work="${TEST_TEMP_DIR}/tamper"
    mkdir -p "$work"
    tar -C "$work" -xzf "$bundle_path"
    top=$(find "$work" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -1)
    echo "tampered content" > "${work}/${top}/payload/code/index.php"
    tar -C "$work" -czf "$bundle_path" "$top"

    run bundle_verify "$bundle_path"
    [ "$status" -ne 0 ]
    [[ "$output" == *"payload-hash"* ]]
    [[ "$output" == *"sha256 mismatch"* ]]
}

@test "bundle_verify: tampered scripts fails sha256 check" {
    bundle_path=$(bundle_build "mayo" "$FIXTURE_PAYLOAD" "$FIXTURE_SCRIPTS")

    work="${TEST_TEMP_DIR}/tamper"
    mkdir -p "$work"
    tar -C "$work" -xzf "$bundle_path"
    top=$(find "$work" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -1)
    echo "evil apply" > "${work}/${top}/scripts/apply.sh"
    tar -C "$work" -czf "$bundle_path" "$top"

    run bundle_verify "$bundle_path"
    [ "$status" -ne 0 ]
    [[ "$output" == *"scripts-hash"* ]]
}

@test "bundle_verify: missing manifest fails layout check" {
    bundle_path=$(bundle_build "mayo" "$FIXTURE_PAYLOAD" "$FIXTURE_SCRIPTS")

    work="${TEST_TEMP_DIR}/tamper"
    mkdir -p "$work"
    tar -C "$work" -xzf "$bundle_path"
    top=$(find "$work" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -1)
    rm "${work}/${top}/manifest.json"
    tar -C "$work" -czf "$bundle_path" "$top"

    run bundle_verify "$bundle_path"
    [ "$status" -ne 0 ]
    [[ "$output" == *"layout"* ]]
}

@test "bundle_verify: invalid manifest JSON fails parse check" {
    bundle_path=$(bundle_build "mayo" "$FIXTURE_PAYLOAD" "$FIXTURE_SCRIPTS")

    work="${TEST_TEMP_DIR}/tamper"
    mkdir -p "$work"
    tar -C "$work" -xzf "$bundle_path"
    top=$(find "$work" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -1)
    echo "not json" > "${work}/${top}/manifest.json"
    tar -C "$work" -czf "$bundle_path" "$top"

    run bundle_verify "$bundle_path"
    [ "$status" -ne 0 ]
    [[ "$output" == *"manifest-parse"* ]]
}

################################################################################
# bundle_inspect
################################################################################

@test "bundle_inspect: prints manifest JSON" {
    bundle_path=$(bundle_build "mayo" "$FIXTURE_PAYLOAD" "$FIXTURE_SCRIPTS")
    run bundle_inspect "$bundle_path"
    [ "$status" -eq 0 ]
    [[ "$output" == *"\"site\": \"mayo\""* ]]
    [[ "$output" == *"\"schema_version\": 1"* ]]
}
