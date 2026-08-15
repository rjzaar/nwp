#!/usr/bin/env bash
#
# fetch-xterm.sh — (re)produce the vendored xterm.js files in this directory.
#
# The Sessions tab's terminal is xterm.js, vendored into the repo the same way
# htmx.min.js is (the console must not load third-party code from a CDN at
# runtime — mesh-only posture, and a CDN is a supply chain with no pin). This
# script is the provenance: pinned npm tarball versions, sha256-verified
# before a single byte is extracted, same doctrine as ensure-node.sh.
#
# Run it only to UPGRADE the pin: bump the versions + hashes below, run, and
# commit the changed outputs alongside the changed pins in one MR.
#
#   xterm.min.js      <- @xterm/xterm     package/lib/xterm.js   (minified UMD)
#   xterm.css         <- @xterm/xterm     package/css/xterm.css
#   addon-fit.min.js  <- @xterm/addon-fit package/lib/addon-fit.js
set -euo pipefail

XTERM_VERSION="5.5.0"
XTERM_SHA256="bd954fa721872170188cc5d7e83e88db3c83c9a18a4e8d24c2783d26491f59d2"
FIT_VERSION="0.10.0"
FIT_SHA256="917ac44972453d5eed52edc1e50260c76398ce48cf2290c2e60671102bba0b33"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() { # $1 name  $2 url  $3 sha256
    curl -sSfLo "$TMP/$1" "$2"
    echo "$3  $TMP/$1" | sha256sum -c - >/dev/null || {
        echo "REFUSING: $1 does not match its pinned sha256 — upstream changed or the download was tampered with" >&2
        exit 1
    }
}

fetch xterm.tgz "https://registry.npmjs.org/@xterm/xterm/-/xterm-${XTERM_VERSION}.tgz" "$XTERM_SHA256"
fetch fit.tgz   "https://registry.npmjs.org/@xterm/addon-fit/-/addon-fit-${FIT_VERSION}.tgz" "$FIT_SHA256"

tar -xzf "$TMP/xterm.tgz" -C "$TMP" package/lib/xterm.js package/css/xterm.css
tar -xzf "$TMP/fit.tgz"   -C "$TMP" --one-top-level=fit package/lib/addon-fit.js

install -m 0644 "$TMP/package/lib/xterm.js"          "$HERE/xterm.min.js"
install -m 0644 "$TMP/package/css/xterm.css"         "$HERE/xterm.css"
install -m 0644 "$TMP/fit/package/lib/addon-fit.js"  "$HERE/addon-fit.min.js"

echo "vendored: xterm ${XTERM_VERSION} + addon-fit ${FIT_VERSION} into $HERE"
