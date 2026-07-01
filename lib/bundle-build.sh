#!/bin/bash

################################################################################
# NWP Bundle Build Library
#
# F28 Phase 2: construct a signed deployment bundle in the F28 § 3.1 format.
#
# Bundle layout produced:
#
#   nwp-bundle-<site>-<commit>-<ts>.tar.gz
#   ├── manifest.json
#   ├── manifest.json.minisig
#   ├── payload/
#   │   ├── code/
#   │   ├── fixtures/          (optional, empty dir if not provided)
#   │   └── migrations/        (optional, empty dir if not provided)
#   └── scripts/
#       ├── pre-deploy.sh      (optional — defaults to a no-op)
#       ├── apply.sh           (required)
#       └── post-deploy.sh     (optional — defaults to a no-op)
#
# Deviation from F28 § 3.1: the spec says "manifest.yaml" but the
# implementation uses "manifest.json" because jq is available everywhere
# NWP runs and bash has no reliable YAML parser. bundle-verify.sh reads
# the same format.
#
# Source: source "$PROJECT_ROOT/lib/bundle-build.sh"
# Main entry point: bundle_build <site> <payload_dir> <scripts_dir> [OPTIONS]
#
# See F28 for the full architecture:
#   docs/proposals/F28-unified-pipeline.md
################################################################################

# Resolve NWP root if not already set
if [[ -z "${NWP_ROOT:-}" ]]; then
    NWP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Source dependencies if not already loaded
if ! declare -F minisign_check &>/dev/null; then
    # shellcheck source=lib/minisign.sh
    source "${NWP_ROOT}/lib/minisign.sh"
fi
# Deterministic tree hash — shared with the verifier (lib/bundle-hash.sh).
if ! declare -F bundle_tree_sha256 &>/dev/null; then
    # shellcheck source=lib/bundle-hash.sh
    source "${NWP_ROOT}/lib/bundle-hash.sh"
fi

BUNDLE_SCHEMA_VERSION=1

# Check for required external tools
# Returns: 0 if all present, 1 otherwise
bundle_check_tools() {
    local missing=()
    for tool in jq sha256sum tar; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        echo "ERROR: bundle build requires: ${missing[*]}" >&2
        return 1
    fi
    return 0
}

# bundle_tree_sha256 now lives in the shared lib/bundle-hash.sh (sourced above)
# so the AI-free verifier can reuse it without the rest of this builder.

# Get the NWP version from the pl script, or "unknown"
bundle_nwp_version() {
    local pl="${NWP_ROOT}/pl"
    if [[ -f "$pl" ]]; then
        grep -E '^NWP_VERSION=' "$pl" 2>/dev/null \
            | head -1 \
            | sed -E 's/^NWP_VERSION=["'"'"']?([^"'"'"']*)["'"'"']?$/\1/' \
            | head -c 32
        return 0
    fi
    echo "unknown"
}

# Get the git commit / branch for the source directory.
# Both functions echo the value or "unknown".
bundle_git_commit() {
    local src="$1"
    if [[ -d "${src}/.git" ]] || git -C "$src" rev-parse --git-dir &>/dev/null; then
        git -C "$src" rev-parse HEAD 2>/dev/null || echo "unknown"
    else
        # Fall back to NWP repo
        git -C "$NWP_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown"
    fi
}

bundle_git_branch() {
    local src="$1"
    if [[ -d "${src}/.git" ]] || git -C "$src" rev-parse --git-dir &>/dev/null; then
        git -C "$src" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"
    else
        git -C "$NWP_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"
    fi
}

# Build a bundle.
#
# Usage:
#   bundle_build <site> <payload_dir> <scripts_dir> [OPTIONS]
#
# Required args:
#   <site>         - site name (e.g. mayo, avc)
#   <payload_dir>  - directory containing code/, fixtures/, migrations/
#                    (fixtures/ and migrations/ are optional)
#   <scripts_dir>  - directory containing apply.sh (required) and
#                    optionally pre-deploy.sh and post-deploy.sh
#
# Options (set before calling, via env vars):
#   BUNDLE_OUTPUT_DIR   - where to write the bundle (default: $NWP_ROOT/dist)
#   BUNDLE_TARGETS      - space-separated list of prod hosts (default: empty)
#   BUNDLE_DEPENDENCIES - space-separated list of previous bundle ids
#                         (default: empty)
#   BUNDLE_NO_SIGN      - if "1", skip minisign signing (dev/test only)
#
# Echoes the absolute path of the built bundle on stdout on success.
# Returns 0 on success, non-zero on failure.
bundle_build() {
    local site="$1"
    local payload_src="$2"
    local scripts_src="$3"

    bundle_check_tools || return 1

    # Validate inputs
    if [[ -z "$site" ]]; then
        echo "ERROR: site name required" >&2
        return 2
    fi
    if [[ ! -d "$payload_src" ]]; then
        echo "ERROR: payload directory not found: $payload_src" >&2
        return 2
    fi
    if [[ ! -d "$payload_src/code" ]]; then
        echo "ERROR: payload directory must contain a code/ subdirectory: $payload_src" >&2
        return 2
    fi
    if [[ ! -d "$scripts_src" ]]; then
        echo "ERROR: scripts directory not found: $scripts_src" >&2
        return 2
    fi
    if [[ ! -f "$scripts_src/apply.sh" ]]; then
        echo "ERROR: scripts directory must contain apply.sh: $scripts_src" >&2
        return 2
    fi

    local output_dir="${BUNDLE_OUTPUT_DIR:-$NWP_ROOT/dist}"
    mkdir -p "$output_dir"

    # Resolve manifest inputs
    local commit branch
    commit=$(bundle_git_commit "$payload_src/code")
    branch=$(bundle_git_branch "$payload_src/code")
    local short_commit="${commit:0:8}"
    local ts
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    local nwp_version
    nwp_version=$(bundle_nwp_version)
    local built_at
    built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local built_by
    built_by=$(hostname -f 2>/dev/null || hostname)

    local bundle_name="nwp-bundle-${site}-${short_commit}-${ts}"
    local bundle_path="${output_dir}/${bundle_name}.tar.gz"

    # Work in a temp directory so partial builds do not litter $output_dir
    local work_dir
    work_dir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$work_dir'" EXIT

    local stage_dir="$work_dir/$bundle_name"
    mkdir -p "$stage_dir/payload/code" "$stage_dir/payload/fixtures" \
             "$stage_dir/payload/migrations" "$stage_dir/scripts"

    # Copy payload tree. code/ is required; the other two are optional.
    cp -a "$payload_src/code/." "$stage_dir/payload/code/" || {
        echo "ERROR: failed to copy payload code tree" >&2
        return 1
    }
    if [[ -d "$payload_src/fixtures" ]]; then
        cp -a "$payload_src/fixtures/." "$stage_dir/payload/fixtures/" || {
            echo "ERROR: failed to copy fixtures tree" >&2
            return 1
        }
    fi
    if [[ -d "$payload_src/migrations" ]]; then
        cp -a "$payload_src/migrations/." "$stage_dir/payload/migrations/" || {
            echo "ERROR: failed to copy migrations tree" >&2
            return 1
        }
    fi

    # Copy scripts. apply.sh is required; the pre/post are optional and
    # defaulted to an explicit no-op so the deploy runner always has
    # something to exec.
    cp "$scripts_src/apply.sh" "$stage_dir/scripts/apply.sh" || {
        echo "ERROR: failed to copy apply.sh" >&2
        return 1
    }
    if [[ -f "$scripts_src/pre-deploy.sh" ]]; then
        cp "$scripts_src/pre-deploy.sh" "$stage_dir/scripts/pre-deploy.sh"
    else
        printf '#!/bin/bash\n# F28 no-op pre-deploy stub\nexit 0\n' \
            > "$stage_dir/scripts/pre-deploy.sh"
    fi
    if [[ -f "$scripts_src/post-deploy.sh" ]]; then
        cp "$scripts_src/post-deploy.sh" "$stage_dir/scripts/post-deploy.sh"
    else
        printf '#!/bin/bash\n# F28 no-op post-deploy stub\nexit 0\n' \
            > "$stage_dir/scripts/post-deploy.sh"
    fi
    chmod +x "$stage_dir/scripts/"*.sh

    # Compute payload and scripts tree hashes
    local sha_payload sha_scripts
    sha_payload=$(bundle_tree_sha256 "$stage_dir/payload") || return 1
    sha_scripts=$(bundle_tree_sha256 "$stage_dir/scripts") || return 1

    # Targets + dependencies as JSON arrays
    local targets_json='[]'
    if [[ -n "${BUNDLE_TARGETS:-}" ]]; then
        targets_json=$(printf '%s\n' ${BUNDLE_TARGETS} | jq -R . | jq -s .)
    fi
    local deps_json='[]'
    if [[ -n "${BUNDLE_DEPENDENCIES:-}" ]]; then
        deps_json=$(printf '%s\n' ${BUNDLE_DEPENDENCIES} | jq -R . | jq -s .)
    fi

    # Signing key fingerprint (if the pubkey exists and minisign is around)
    local fingerprint="unknown"
    if minisign_keys_exist 2>/dev/null; then
        fingerprint=$(minisign_key_id 2>/dev/null || echo "unknown")
    fi

    # Build the manifest
    jq -n \
        --argjson schema "$BUNDLE_SCHEMA_VERSION" \
        --arg nwp_version "$nwp_version" \
        --arg site "$site" \
        --arg git_commit "$commit" \
        --arg git_branch "$branch" \
        --arg built_at "$built_at" \
        --arg built_by "$built_by" \
        --arg fingerprint "$fingerprint" \
        --argjson targets "$targets_json" \
        --arg sha_payload "$sha_payload" \
        --arg sha_scripts "$sha_scripts" \
        --argjson dependencies "$deps_json" \
        '{
            schema_version: $schema,
            nwp_version: $nwp_version,
            site: $site,
            git_commit: $git_commit,
            git_branch: $git_branch,
            built_at: $built_at,
            built_by: $built_by,
            signing_key_fingerprint: $fingerprint,
            targets: $targets,
            sha256_payload: $sha_payload,
            sha256_scripts: $sha_scripts,
            dependencies: $dependencies
        }' > "$stage_dir/manifest.json" || {
        echo "ERROR: failed to write manifest.json" >&2
        return 1
    }

    # Sign the manifest (unless explicitly disabled for dev/tests)
    if [[ "${BUNDLE_NO_SIGN:-0}" != "1" ]]; then
        if ! minisign_check 2>/dev/null; then
            echo "ERROR: minisign required for signing. Set BUNDLE_NO_SIGN=1 for dev builds." >&2
            return 1
        fi
        if ! minisign_keys_exist; then
            echo "ERROR: minisign keys not found. Run minisign_generate_keys or set BUNDLE_NO_SIGN=1." >&2
            return 1
        fi
        minisign_sign "$stage_dir/manifest.json" \
            "NWP bundle: ${site} ${short_commit} built ${built_at}" \
            >/dev/null || {
            echo "ERROR: minisign signing of manifest.json failed" >&2
            return 1
        }
    else
        # Dev-mode: write a placeholder so the shape is consistent for tests
        printf 'UNSIGNED DEV BUILD\n' > "$stage_dir/manifest.json.minisig"
    fi

    # Tar the whole staged bundle
    tar -C "$work_dir" -czf "$bundle_path" "$bundle_name" || {
        echo "ERROR: tar failed to create $bundle_path" >&2
        return 1
    }

    rm -rf "$work_dir"
    trap - EXIT

    echo "$bundle_path"
    return 0
}
