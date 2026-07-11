#!/usr/bin/env bats
################################################################################
# Unit tests for scripts/commands/config.sh (pl config export|import, ops#79)
#
# Exercises the config-bundle contract: export collects exactly the config
# set (root nwp.yml + sites/*/.nwp.yml + servers/*/.nwp-server.yml) with a
# sha256 manifest; the deny-scan fail-closes on secret-looking content;
# import verifies member paths + checksums and refuses traversal/tampering.
#
# All work happens in BATS_TEST_TMPDIR via NWP_CONFIG_ROOT — the real repo
# tree is never read from or written to.
################################################################################

load ../helpers/test-helpers

setup() {
    test_setup
    CONFIG_CMD="${PROJECT_ROOT}/scripts/commands/config.sh"

    # Source fixture tree (the "dev machine")
    export FIXTURE_SRC="${TEST_TEMP_DIR}/src-tree"
    mkdir -p "$FIXTURE_SRC/sites/alpha" "$FIXTURE_SRC/sites/beta" "$FIXTURE_SRC/servers/one"
    printf 'version: "0.13"\nschema_version: 1\nsettings:\n  webserver: nginx-fpm\n' \
        > "$FIXTURE_SRC/nwp.yml"
    printf 'schema_version: 2\nproject:\n  name: alpha\n  recipe: nwp\n' \
        > "$FIXTURE_SRC/sites/alpha/.nwp.yml"
    printf 'schema_version: 2\nproject:\n  name: beta\n' \
        > "$FIXTURE_SRC/sites/beta/.nwp.yml"
    printf 'schema_version: 1\nname: one\nssh_user: deploy\n' \
        > "$FIXTURE_SRC/servers/one/.nwp-server.yml"

    # Destination fixture tree (the "ver box")
    export FIXTURE_DST="${TEST_TEMP_DIR}/dst-tree"
    mkdir -p "$FIXTURE_DST"

    export BUNDLE="${TEST_TEMP_DIR}/bundle.tgz"
}

teardown() {
    test_teardown
}

_export_bundle() {
    NWP_CONFIG_ROOT="$FIXTURE_SRC" "$CONFIG_CMD" export --out "$BUNDLE"
}

################################################################################
# export
################################################################################

@test "config export: tar contains exactly the expected members + manifest" {
    run _export_bundle
    [ "$status" -eq 0 ]
    [ -f "$BUNDLE" ]

    run tar -tzf "$BUNDLE"
    [ "$status" -eq 0 ]
    sorted=$(echo "$output" | sort)
    expected=$(printf '%s\n' \
        "bundle-manifest.json" \
        "nwp.yml" \
        "servers/one/.nwp-server.yml" \
        "sites/alpha/.nwp.yml" \
        "sites/beta/.nwp.yml" | sort)
    [ "$sorted" = "$expected" ]

    # 0600 perms — the bundle stays private
    perms=$(stat -c '%a' "$BUNDLE")
    [ "$perms" = "600" ]
}

@test "config export: manifest carries sha256 + schema versions" {
    run _export_bundle
    [ "$status" -eq 0 ]

    manifest=$(tar -xzOf "$BUNDLE" bundle-manifest.json)
    echo "$manifest" | grep -q '"created_utc"'
    echo "$manifest" | grep -q '"path": "nwp.yml"'
    real_sha=$(sha256sum "$FIXTURE_SRC/nwp.yml" | awk '{print $1}')
    echo "$manifest" | grep -q "$real_sha"
    # best-effort schema/version fields
    echo "$manifest" | grep -q '"version": "0.13"'
    echo "$manifest" | grep -q '"schema_version": "2"'
}

@test "config export: deny-scan refuses secret-looking content (fail-closed)" {
    # Build the token at runtime so no secret-shaped literal lands in this file
    printf 'schema_version: 2\napi_token: glpat-%s\n' "notarealtoken0000000" \
        > "$FIXTURE_SRC/sites/alpha/.nwp.yml"

    run _export_bundle
    [ "$status" -ne 0 ]
    [[ "$output" == *"Refusing export"* ]]
    [[ "$output" == *"sites/alpha/.nwp.yml"* ]]
    # Nothing written on refusal
    [ ! -f "$BUNDLE" ]
}

@test "config export: deny-scan refuses private-key content (fail-closed)" {
    printf 'schema_version: 1\nblob: |\n  -----BEGIN OPENSSH PRIVATE KEY-----\n' \
        > "$FIXTURE_SRC/servers/one/.nwp-server.yml"

    run _export_bundle
    [ "$status" -ne 0 ]
    [[ "$output" == *"Refusing export"* ]]
    [[ "$output" == *"servers/one/.nwp-server.yml"* ]]
    [ ! -f "$BUNDLE" ]
}

################################################################################
# import
################################################################################

@test "config import --dry-run: reports the plan and writes nothing" {
    run _export_bundle
    [ "$status" -eq 0 ]

    run env NWP_CONFIG_ROOT="$FIXTURE_DST" "$CONFIG_CMD" import "$BUNDLE" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dry run"* ]]
    [[ "$output" == *"nwp.yml"* ]]

    # Destination tree untouched
    count=$(find "$FIXTURE_DST" -type f | wc -l)
    [ "$count" -eq 0 ]
}

@test "config import: round-trips the fixture tree byte-for-byte" {
    run _export_bundle
    [ "$status" -eq 0 ]

    run env NWP_CONFIG_ROOT="$FIXTURE_DST" "$CONFIG_CMD" import "$BUNDLE"
    [ "$status" -eq 0 ]

    run diff -r "$FIXTURE_SRC" "$FIXTURE_DST"
    [ "$status" -eq 0 ]
}

@test "config import: overwrite backs up the existing file first" {
    run _export_bundle
    [ "$status" -eq 0 ]

    mkdir -p "$FIXTURE_DST/sites/alpha"
    printf 'schema_version: 2\nproject:\n  name: old-alpha\n' \
        > "$FIXTURE_DST/sites/alpha/.nwp.yml"

    run env NWP_CONFIG_ROOT="$FIXTURE_DST" "$CONFIG_CMD" import "$BUNDLE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 overwritten"* ]]

    bak=$(find "$FIXTURE_DST/sites/alpha" -name '.nwp.yml.pre-import-*.bak')
    [ -n "$bak" ]
    grep -q "old-alpha" "$bak"
    grep -q "recipe: nwp" "$FIXTURE_DST/sites/alpha/.nwp.yml"
}

@test "config import: refuses a tampered sha256" {
    run _export_bundle
    [ "$status" -eq 0 ]

    # Repack the bundle with one file altered but the original manifest
    repack="${TEST_TEMP_DIR}/repack"
    mkdir -p "$repack"
    tar -xzf "$BUNDLE" -C "$repack"
    printf 'schema_version: 2\nproject:\n  name: EVIL\n' > "$repack/sites/alpha/.nwp.yml"
    tampered="${TEST_TEMP_DIR}/tampered.tgz"
    (cd "$repack" && tar -czf "$tampered" bundle-manifest.json nwp.yml \
        sites/alpha/.nwp.yml sites/beta/.nwp.yml servers/one/.nwp-server.yml)

    run env NWP_CONFIG_ROOT="$FIXTURE_DST" "$CONFIG_CMD" import "$tampered"
    [ "$status" -ne 0 ]
    [[ "$output" == *"sha256 mismatch"* ]]
    count=$(find "$FIXTURE_DST" -type f | wc -l)
    [ "$count" -eq 0 ]
}

@test "config import: refuses a missing manifest" {
    run _export_bundle
    [ "$status" -eq 0 ]

    repack="${TEST_TEMP_DIR}/repack"
    mkdir -p "$repack"
    tar -xzf "$BUNDLE" -C "$repack"
    nomanifest="${TEST_TEMP_DIR}/nomanifest.tgz"
    (cd "$repack" && tar -czf "$nomanifest" nwp.yml sites/alpha/.nwp.yml)

    run env NWP_CONFIG_ROOT="$FIXTURE_DST" "$CONFIG_CMD" import "$nomanifest"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no bundle-manifest.json"* ]]
}

@test "config import: refuses a path-traversal member" {
    evil_src="${TEST_TEMP_DIR}/evil-src"
    mkdir -p "$evil_src"
    printf 'owned: true\n' > "$evil_src/evil.yml"
    evil="${TEST_TEMP_DIR}/evil.tgz"
    # GNU tar --transform stores the member under a traversal path
    tar -czf "$evil" -C "$evil_src" --transform='s|^evil.yml$|../evil.yml|' evil.yml

    # Confirm the crafted archive really carries the traversal member
    run tar -tzf "$evil"
    [[ "$output" == *"../evil.yml"* ]]

    run env NWP_CONFIG_ROOT="$FIXTURE_DST" "$CONFIG_CMD" import "$evil"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Refusing import"* ]]
    [ ! -f "${TEST_TEMP_DIR}/evil.yml" ]
    count=$(find "$FIXTURE_DST" -type f | wc -l)
    [ "$count" -eq 0 ]
}

@test "config import: refuses a member outside the allowed set" {
    run _export_bundle
    [ "$status" -eq 0 ]

    repack="${TEST_TEMP_DIR}/repack"
    mkdir -p "$repack"
    tar -xzf "$BUNDLE" -C "$repack"
    printf 'not-a-config\n' > "$repack/random.txt"
    rogue="${TEST_TEMP_DIR}/rogue.tgz"
    (cd "$repack" && tar -czf "$rogue" bundle-manifest.json nwp.yml random.txt)

    run env NWP_CONFIG_ROOT="$FIXTURE_DST" "$CONFIG_CMD" import "$rogue"
    [ "$status" -ne 0 ]
    [[ "$output" == *"outside the allowed set"* ]]
    [[ "$output" == *"random.txt"* ]]
}
