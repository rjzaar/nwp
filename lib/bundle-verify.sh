#!/bin/bash

################################################################################
# NWP Bundle Verify Library
#
# F28 Phase 2: verify a signed bundle produced by lib/bundle-build.sh.
#
# Verification steps (all must pass):
#
#   1. The file exists and is a readable tarball.
#   2. Extracting reveals exactly one top-level directory with the expected
#      layout (manifest.json, payload/, scripts/, manifest.json.minisig).
#   3. manifest.json is valid JSON with the expected fields.
#   4. manifest.json.minisig verifies against the pinned public key.
#      (Skippable via BUNDLE_VERIFY_NO_SIG=1 for dev/tests — never on the
#       verifier host.)
#   5. The recomputed sha256 of payload/ matches manifest.sha256_payload.
#   6. The recomputed sha256 of scripts/ matches manifest.sha256_scripts.
#
# Any failure aborts verification with a non-zero return and a clear
# error on stderr. This is by design: the verifier never "partially verifies".
#
# Source: source "$PROJECT_ROOT/lib/bundle-verify.sh"
# Main entry points:
#   bundle_verify <bundle_path> [pubkey]
#   bundle_inspect <bundle_path>
#
# See F28 for the verification contract:
#   docs/proposals/F28-unified-pipeline.md § 3.3 step 4-5
################################################################################

if [[ -z "${NWP_ROOT:-}" ]]; then
    NWP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Source dependencies if not already loaded
if ! declare -F minisign_check &>/dev/null; then
    # shellcheck source=lib/minisign.sh
    source "${NWP_ROOT}/lib/minisign.sh"
fi
if ! declare -F bundle_tree_sha256 &>/dev/null; then
    # Only the shared tree-hash is needed — NOT the whole builder. This keeps the
    # AI-free nwp-server artifact minimal (it ships lib/bundle-hash.sh, never the
    # builder). See build/nwp-server.include.
    # shellcheck source=lib/bundle-hash.sh
    source "${NWP_ROOT}/lib/bundle-hash.sh"
fi

# Required manifest fields for schema version 1.
BUNDLE_REQUIRED_FIELDS=(
    schema_version
    nwp_version
    site
    git_commit
    git_branch
    built_at
    built_by
    signing_key_fingerprint
    targets
    sha256_payload
    sha256_scripts
    dependencies
)

# Print an error in the F28 abort style.
# Usage: bundle_abort <bundle_path> <step> <detail>
_bundle_abort() {
    local bundle_path="$1"
    local step="$2"
    local detail="$3"
    echo "" >&2
    echo "================================================================" >&2
    echo "  BUNDLE VERIFY FAILED — step: ${step}" >&2
    echo "================================================================" >&2
    echo "  Bundle: ${bundle_path}" >&2
    echo "  Error:  ${detail}" >&2
    echo "" >&2
    echo "  Per F28 § 3.3, this is a hard abort — no retry, no fallback." >&2
    echo "================================================================" >&2
    return 1
}

# Extract a bundle into a temp directory and echo the staged path.
# The caller is responsible for cleaning up the returned directory.
# Returns 0 on success.
_bundle_extract() {
    local bundle_path="$1"
    local work_dir
    work_dir=$(mktemp -d) || return 1

    if ! tar -C "$work_dir" -xzf "$bundle_path" 2>/dev/null; then
        rm -rf "$work_dir"
        return 1
    fi

    # Expect exactly one top-level directory
    local top_count top_dir
    top_count=$(find "$work_dir" -mindepth 1 -maxdepth 1 -type d | wc -l)
    if [[ "$top_count" -ne 1 ]]; then
        rm -rf "$work_dir"
        return 1
    fi
    top_dir=$(find "$work_dir" -mindepth 1 -maxdepth 1 -type d)

    echo "$top_dir"
    return 0
}

# Verify a bundle end-to-end.
#
# Usage:
#   bundle_verify <bundle_path> [pubkey_path]
#
# Environment overrides:
#   BUNDLE_VERIFY_NO_SIG=1   - skip minisign verification (dev/tests only;
#                              NEVER set on the verifier host)
#
# Returns 0 on success, non-zero on any verification failure.
bundle_verify() {
    local bundle_path="$1"
    local pubkey="${2:-${MINISIGN_PUBLIC_KEY:-}}"

    if [[ ! -f "$bundle_path" ]]; then
        _bundle_abort "$bundle_path" "file-check" "bundle not found"
        return 1
    fi

    # Step 1-2: extract and validate structure
    local staged
    staged=$(_bundle_extract "$bundle_path") || {
        _bundle_abort "$bundle_path" "extract" "tar extraction failed or multi-rooted archive"
        return 1
    }
    # shellcheck disable=SC2064
    trap "rm -rf '$(dirname "$staged")'" RETURN

    for required in manifest.json manifest.json.minisig payload scripts; do
        if [[ ! -e "$staged/$required" ]]; then
            _bundle_abort "$bundle_path" "layout" "missing $required"
            return 1
        fi
    done
    if [[ ! -d "$staged/payload" || ! -d "$staged/scripts" ]]; then
        _bundle_abort "$bundle_path" "layout" "payload/ and scripts/ must be directories"
        return 1
    fi
    if [[ ! -d "$staged/payload/code" ]]; then
        _bundle_abort "$bundle_path" "layout" "payload/code/ missing"
        return 1
    fi
    if [[ ! -f "$staged/scripts/apply.sh" ]]; then
        _bundle_abort "$bundle_path" "layout" "scripts/apply.sh missing"
        return 1
    fi

    # Step 3: manifest validity
    if ! jq -e . "$staged/manifest.json" >/dev/null 2>&1; then
        _bundle_abort "$bundle_path" "manifest-parse" "manifest.json is not valid JSON"
        return 1
    fi
    for field in "${BUNDLE_REQUIRED_FIELDS[@]}"; do
        if ! jq -e "has(\"$field\")" "$staged/manifest.json" >/dev/null 2>&1 \
           || [[ $(jq -r ".$field" "$staged/manifest.json") == "null" ]]; then
            _bundle_abort "$bundle_path" "manifest-schema" "missing field: $field"
            return 1
        fi
    done
    local schema
    schema=$(jq -r .schema_version "$staged/manifest.json")
    if [[ "$schema" != "1" ]]; then
        _bundle_abort "$bundle_path" "manifest-schema" "unsupported schema_version: $schema (expected 1)"
        return 1
    fi

    # Step 4: minisign verification
    if [[ "${BUNDLE_VERIFY_NO_SIG:-0}" != "1" ]]; then
        if ! minisign_check 2>/dev/null; then
            _bundle_abort "$bundle_path" "sig-tool" "minisign binary not available — cannot verify"
            return 1
        fi
        if [[ -z "$pubkey" || ! -f "$pubkey" ]]; then
            _bundle_abort "$bundle_path" "sig-pubkey" "pinned public key not found: ${pubkey:-<none>}"
            return 1
        fi
        if ! minisign_verify "$staged/manifest.json" "$pubkey" >/dev/null 2>&1; then
            _bundle_abort "$bundle_path" "signature" "minisign verification of manifest.json failed"
            return 1
        fi
    fi

    # Step 5: payload sha256
    local expected_payload actual_payload
    expected_payload=$(jq -r .sha256_payload "$staged/manifest.json")
    actual_payload=$(bundle_tree_sha256 "$staged/payload") || {
        _bundle_abort "$bundle_path" "payload-hash" "failed to hash payload/"
        return 1
    }
    if [[ "$expected_payload" != "$actual_payload" ]]; then
        _bundle_abort "$bundle_path" "payload-hash" \
            "sha256 mismatch — expected $expected_payload got $actual_payload"
        return 1
    fi

    # Step 6: scripts sha256
    local expected_scripts actual_scripts
    expected_scripts=$(jq -r .sha256_scripts "$staged/manifest.json")
    actual_scripts=$(bundle_tree_sha256 "$staged/scripts") || {
        _bundle_abort "$bundle_path" "scripts-hash" "failed to hash scripts/"
        return 1
    }
    if [[ "$expected_scripts" != "$actual_scripts" ]]; then
        _bundle_abort "$bundle_path" "scripts-hash" \
            "sha256 mismatch — expected $expected_scripts got $actual_scripts"
        return 1
    fi

    return 0
}

# Inspect a bundle and print its manifest. No signature verification.
# Usage: bundle_inspect <bundle_path>
bundle_inspect() {
    local bundle_path="$1"
    if [[ ! -f "$bundle_path" ]]; then
        echo "ERROR: bundle not found: $bundle_path" >&2
        return 1
    fi
    local staged
    staged=$(_bundle_extract "$bundle_path") || {
        echo "ERROR: could not extract $bundle_path" >&2
        return 1
    }
    # shellcheck disable=SC2064
    trap "rm -rf '$(dirname "$staged")'" RETURN

    if [[ ! -f "$staged/manifest.json" ]]; then
        echo "ERROR: no manifest.json in bundle" >&2
        return 1
    fi
    jq . "$staged/manifest.json"
    return 0
}
