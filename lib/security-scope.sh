#!/bin/bash
################################################################################
# lib/security-scope.sh — derive the EXACT package set that carries an advisory.
#
# WHY THIS EXISTS (2026-08-11, clearing the fleet-board REDs).
#
# `pl security update` updated `drupal/*` + `guzzlehttp/*` --with-dependencies.
# Those two globs are a hardcoded guess at where advisories live, and the guess
# was already wrong twice:
#
#   - `guzzlehttp/*` is in that list only because a 2026-07 fleet sweep found
#     four Guzzle advisories that `drupal/*` alone had missed. The fix was to
#     append the ecosystem that surprised us.
#   - On mayo, 3 of 15 advisories were `webonyx/graphql-php` — neither glob.
#     The command would have run, exited 0, and left them in place.
#
# A list that must be extended every time reality surprises it is not a scope,
# it is a memory of past surprises. Derive it from the measurement instead:
# `composer audit --format=json` already names every affected package, so the
# set cannot omit an ecosystem nobody thought of.
#
# THE FAIL-CLOSED PROPERTY IS THE POINT. The natural bug here is the
# swallowed-verdict shape from CLAUDE.md: if the audit output cannot be read,
# the package list comes back empty, the update becomes a no-op, and the command
# exits 0 looking exactly like "there was nothing to do". A site full of
# advisories would report success. So: unreadable, unparseable, or missing the
# `advisories` key ⇒ exit 2 CANNOT VERIFY, and callers must not proceed.
#
# Tests: tests/unit/test-security-scope.bats
################################################################################

# security_advisory_packages — read `composer audit --format=json` on stdin,
# print one affected package name per line.
#
#   exit 0  the document was understood; 0+ package names printed
#   exit 2  CANNOT VERIFY — the document could not be understood. NOT "clean".
security_advisory_packages() {
    python3 "${BASH_SOURCE[0]%/*}/security-scope.py"
}

# security_root_pinners — read `composer why <pkg>` on stdin, print the requirers
# that are ROOT requirements of $1/composer.json (i.e. the metapackages that pin
# the advisory package and must therefore be named for it to move at all).
#   exit 0  understood; 0+ names printed      exit 2  CANNOT VERIFY
security_root_pinners() {  # $1 = site path holding composer.json
    python3 "${BASH_SOURCE[0]%/*}/security-scope.py" --requirers --root-json "$1/composer.json"
}
