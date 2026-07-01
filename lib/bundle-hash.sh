#!/bin/bash
################################################################################
# NWP Bundle Hash Library
#
# The deterministic tree-hash shared by the bundle BUILDER (lib/bundle-build.sh,
# build tier) and the bundle VERIFIER (lib/bundle-verify.sh). It is factored out
# so the AI-free `nwp-server` prod agent can VERIFY a bundle without dragging the
# whole builder onto a production host (build/nwp-server.include ships this file,
# not lib/bundle-build.sh). Pure: depends only on find/sort/xargs/sha256sum/awk.
#
# Source this file: source "$NWP_ROOT/lib/bundle-hash.sh"
################################################################################

# Compute a deterministic sha256 of a directory tree.
# Uses sorted file paths + per-file sha256 + a final sha256 over the
# concatenation so that the same tree always produces the same hash
# regardless of inode order or filesystem layout.
#
# Usage: bundle_tree_sha256 <dir>
bundle_tree_sha256() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        echo "ERROR: not a directory: $dir" >&2
        return 1
    fi
    # Use a subshell + find for stable ordering
    (
        cd "$dir" || exit 1
        find . -type f -print0 2>/dev/null \
            | LC_ALL=C sort -z \
            | xargs -0 sha256sum 2>/dev/null \
            | sha256sum \
            | awk '{print $1}'
    )
}
